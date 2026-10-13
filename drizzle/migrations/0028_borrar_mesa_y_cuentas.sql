begin;

create or replace function public.admin_eliminar_cuenta(p_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar cuentas';
  end if;
  select mesa_id into v_mesa from public.cuentas where id = p_id for update;
  if v_mesa is null then
    raise exception 'Cuenta no encontrada';
  end if;
  delete from public.comanda_items i
  using public.comandas co
  where i.comanda_id = co.id and co.cuenta_id = p_id;
  delete from public.comandas where cuenta_id = p_id;
  delete from public.cuentas where id = p_id;
  if not exists (
    select 1 from public.cuentas c
    where c.mesa_id = v_mesa and c.estado in ('abierta', 'por_cobrar')
  ) then
    delete from public.mesa_responsables where mesa_id = v_mesa;
    update public.mesas set estado = 'disponible' where id = v_mesa;
  end if;
  perform public.registrar_accion(
    'anular_cuenta', v_mesa, p_id, null, null,
    jsonb_build_object('eliminada', true)
  );
end;
$$;

create or replace function public.admin_eliminar_mesa(p_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar mesas';
  end if;
  select nombre into v_nombre from public.mesas where id = p_id for update;
  if v_nombre is null then
    raise exception 'Mesa no encontrada';
  end if;

  delete from public.comanda_items i
  using public.comandas co
  where i.comanda_id = co.id
    and (
      co.mesa_id = p_id
      or co.cuenta_id in (select c.id from public.cuentas c where c.mesa_id = p_id)
    );
  delete from public.comandas
  where mesa_id = p_id
     or cuenta_id in (select id from public.cuentas where mesa_id = p_id);
  delete from public.cuentas where mesa_id = p_id;
  delete from public.mesa_responsables where mesa_id = p_id;
  begin
    delete from public.sugerencias_comanda where mesa_id = p_id;
  exception when undefined_table then
    null;
  end;
  delete from public.mesas where id = p_id;

  perform public.registrar_accion(
    'editar_mesa', null, null, null, null,
    jsonb_build_object('nombre', v_nombre, 'eliminada', true, 'con_cuentas', true)
  );
end;
$$;

revoke all on function public.admin_eliminar_cuenta(uuid) from public, anon, authenticated;
revoke all on function public.admin_eliminar_mesa(uuid) from public, anon, authenticated;
grant execute on function public.admin_eliminar_cuenta(uuid) to authenticated;
grant execute on function public.admin_eliminar_mesa(uuid) to authenticated;

commit;
