begin;

-- Comandas vacías o de una cuenta ya cerrada no deben seguir en cocina ni marcar la mesa.
delete from public.comandas c
where c.estado in ('pendiente', 'preparacion')
  and not exists (
    select 1 from public.comanda_items i where i.comanda_id = c.id
  );

update public.comandas c
set estado = 'listo'
where c.estado in ('pendiente', 'preparacion')
  and not exists (
    select 1 from public.cuentas cu
    where cu.id = c.cuenta_id and cu.estado in ('abierta', 'por_cobrar')
  );

delete from public.cuentas c
where c.estado in ('abierta', 'por_cobrar')
  and not exists (
    select 1
    from public.comandas co
    join public.comanda_items i on i.comanda_id = co.id
    where co.cuenta_id = c.id
  );

delete from public.mesa_responsables r
where not exists (
  select 1
  from public.cuentas c
  join public.comandas co on co.cuenta_id = c.id
  join public.comanda_items i on i.comanda_id = co.id
  where c.mesa_id = r.mesa_id
    and c.estado in ('abierta', 'por_cobrar')
);

update public.mesas m
set estado = 'disponible'
where not exists (
  select 1 from public.cuentas c
  where c.mesa_id = m.id and c.estado in ('abierta', 'por_cobrar')
);

create or replace function public.admin_eliminar_mesa(p_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_usada boolean;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar mesas';
  end if;
  select nombre into v_nombre from public.mesas where id = p_id for update;
  if v_nombre is null then
    raise exception 'Mesa no encontrada';
  end if;

  delete from public.comandas c
  where c.mesa_id = p_id
    and c.estado in ('pendiente', 'preparacion')
    and not exists (select 1 from public.comanda_items i where i.comanda_id = c.id);

  delete from public.cuentas c
  where c.mesa_id = p_id
    and c.estado in ('abierta', 'por_cobrar')
    and not exists (
      select 1 from public.comandas co
      join public.comanda_items i on i.comanda_id = co.id
      where co.cuenta_id = c.id
    );

  if exists (
    select 1 from public.cuentas
    where mesa_id = p_id and estado in ('abierta', 'por_cobrar')
  ) then
    raise exception 'La mesa tiene un pedido abierto. Ciérralo en caja antes de borrarla.';
  end if;

  delete from public.mesa_responsables where mesa_id = p_id;
  select exists (select 1 from public.cuentas where mesa_id = p_id) into v_usada;
  if v_usada then
    update public.mesas set activa = false, estado = 'disponible' where id = p_id;
  else
    delete from public.mesas where id = p_id;
  end if;
  perform public.registrar_accion(
    'editar_mesa', p_id, null, null, null,
    jsonb_build_object('nombre', v_nombre, 'eliminada', true, 'ocultada', v_usada)
  );
end;
$$;

create or replace function public.admin_quitar_comanda(p_comanda uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_cuenta uuid;
  v_items integer;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede quitar una comanda';
  end if;
  select c.mesa_id, c.cuenta_id into v_mesa, v_cuenta
  from public.comandas c
  where c.id = p_comanda
  for update;
  if v_mesa is null then
    raise exception 'Comanda no encontrada';
  end if;
  select count(*) into v_items from public.comanda_items i where i.comanda_id = p_comanda;
  if v_items = 0 then
    delete from public.comandas where id = p_comanda;
  else
    update public.comandas set estado = 'listo' where id = p_comanda;
  end if;
  delete from public.cuentas c
  where c.id = v_cuenta
    and c.estado in ('abierta', 'por_cobrar')
    and not exists (
      select 1 from public.comandas co
      join public.comanda_items i on i.comanda_id = co.id
      where co.cuenta_id = c.id
    );
  if not exists (
    select 1 from public.cuentas c
    where c.mesa_id = v_mesa and c.estado in ('abierta', 'por_cobrar')
  ) then
    delete from public.mesa_responsables where mesa_id = v_mesa;
    update public.mesas set estado = 'disponible' where id = v_mesa;
  end if;
  perform public.registrar_accion(
    'actualizar_comanda', v_mesa, v_cuenta, p_comanda, null,
    jsonb_build_object('estado_nuevo', 'lista', 'vacia', v_items = 0, 'quitada_por_admin', true)
  );
end;
$$;

revoke all on function public.admin_eliminar_mesa(uuid) from public, anon, authenticated;
revoke all on function public.admin_quitar_comanda(uuid) from public, anon, authenticated;
grant execute on function public.admin_eliminar_mesa(uuid) to authenticated;
grant execute on function public.admin_quitar_comanda(uuid) to authenticated;

commit;
