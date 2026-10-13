begin;

-- Quita asignaciones viejas que no tienen pedido. La mesa vuelve a piso limpio.
delete from public.mesa_responsables r
where not exists (
  select 1
  from public.cuentas c
  join public.comandas co on co.cuenta_id = c.id
  join public.comanda_items i on i.comanda_id = co.id
  where c.mesa_id = r.mesa_id
    and c.estado in ('abierta', 'por_cobrar')
);

delete from public.cuentas c
where c.estado in ('abierta', 'por_cobrar')
  and not exists (
    select 1
    from public.comandas co
    join public.comanda_items i on i.comanda_id = co.id
    where co.cuenta_id = c.id
  );

update public.mesas m
set estado = 'disponible'
where not exists (
  select 1 from public.cuentas c
  where c.mesa_id = m.id and c.estado in ('abierta', 'por_cobrar')
);

alter table public.audit_acciones drop constraint if exists audit_acciones_accion_check;
do $$
declare
  v_list text;
begin
  select string_agg(quote_literal(accion), ', ' order by accion)
  into v_list
  from (
    select distinct accion from public.audit_acciones
    union
    select unnest(array[
      'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
      'cobrar_cuenta', 'anular_cuenta', 'pago_parcial',
      'dividir_cuenta', 'mover_mesa', 'corte_caja', 'soltar_mesa',
      'entrada_empleado', 'salida_empleado',
      'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
      'aplicar_descuento', 'quitar_descuento',
      'cambio_nombre_admin', 'baja_empleado', 'eliminar_producto'
    ])
  ) acciones;
  execute format(
    'alter table public.audit_acciones add constraint audit_acciones_accion_check check (accion in (%s))',
    v_list
  );
end $$;

create or replace function public.registrar_accion(
  p_accion text, p_mesa_id uuid default null, p_cuenta_id uuid default null,
  p_comanda_id uuid default null, p_monto numeric default null,
  p_detalle jsonb default '{}'::jsonb
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_label text;
  v_empleado uuid;
  v_responsable text;
  v_detalle jsonb := coalesce(p_detalle, '{}'::jsonb);
begin
  if v_user_id is null then return; end if;
  if p_accion not in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta', 'pago_parcial',
    'dividir_cuenta', 'mover_mesa', 'corte_caja', 'soltar_mesa',
    'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
    'aplicar_descuento', 'quitar_descuento',
    'cambio_nombre_admin', 'baja_empleado', 'eliminar_producto'
  ) then raise exception 'Acción de auditoría inválida'; end if;
  select sr.role into v_role from public.staff_roles sr where sr.user_id = v_user_id;
  if v_role is null then return; end if;
  if v_role = 'admin' then
    select p.nombre into v_responsable from public.admin_perfiles p where p.user_id = v_user_id;
    v_responsable := coalesce(v_responsable, 'Administrador sin nombre');
    v_label := 'Administración';
  else
    select a.empleado_id, e.nombre into v_empleado, v_responsable
    from public.asistencias a
    join public.empleados e on e.id = a.empleado_id
    where a.user_id = v_user_id and a.salida_at is null;
    v_label := coalesce(
      nullif(trim((select s.device_label from public.solicitudes_puesto s where s.user_id = v_user_id)), ''),
      initcap(v_role) || ' ' || left(v_user_id::text, 8)
    );
  end if;
  if v_responsable is not null then
    v_detalle := v_detalle || jsonb_build_object('empleado', v_responsable);
  end if;
  insert into public.audit_acciones(
    user_id, device_label, role, accion, empleado_id,
    mesa_id, cuenta_id, comanda_id, monto, detalle, responsable
  ) values (
    v_user_id, v_label, v_role, p_accion, v_empleado,
    p_mesa_id, p_cuenta_id, p_comanda_id, p_monto, v_detalle, v_responsable
  );
end;
$$;

create or replace function public.mesa_tiene_pedido(p_mesa uuid)
returns boolean
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.cuentas c
    join public.comandas co on co.cuenta_id = c.id
    join public.comanda_items i on i.comanda_id = co.id
    where c.mesa_id = p_mesa
      and c.estado in ('abierta', 'por_cobrar')
  );
$$;

create or replace function public.soltar_mesa_sin_orden(
  p_mesa uuid, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid := auth.uid();
  v_owner uuid;
  v_mode boolean;
begin
  if not public.tiene_rol(array['mesero', 'admin']::text[]) then
    raise exception 'No autorizado para soltar la mesa';
  end if;
  select m.es_prueba into v_mode
  from public.mesas m
  where m.id = p_mesa and m.activa
  for update;
  if not found or v_mode is distinct from coalesce(p_es_prueba, false) then
    raise exception 'La mesa no está en el modo seleccionado';
  end if;
  if public.mesa_tiene_pedido(p_mesa) then
    raise exception 'Esta mesa ya tiene un pedido. Sigue a nombre de quien lo envió.';
  end if;
  select r.user_id into v_owner from public.mesa_responsables r where r.mesa_id = p_mesa;
  if v_owner is null then
    return;
  end if;
  if public.tiene_rol(array['mesero']::text[]) and not public.tiene_rol(array['admin']::text[])
     and v_owner is distinct from v_user then
    raise exception 'Solo puedes soltar una mesa que está a tu nombre';
  end if;
  delete from public.cuentas c
  where c.mesa_id = p_mesa
    and c.estado in ('abierta', 'por_cobrar')
    and not exists (
      select 1 from public.comandas co
      join public.comanda_items i on i.comanda_id = co.id
      where co.cuenta_id = c.id
    );
  delete from public.mesa_responsables where mesa_id = p_mesa;
  update public.mesas set estado = 'disponible' where id = p_mesa
    and not exists (
      select 1 from public.cuentas c
      where c.mesa_id = p_mesa and c.estado in ('abierta', 'por_cobrar')
    );
  perform public.registrar_accion(
    'soltar_mesa', p_mesa, null, null, null,
    jsonb_build_object('es_prueba', v_mode)
  );
end;
$$;

create or replace function public.soltar_mesas_sin_orden(p_es_prueba boolean default false)
returns integer
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid := auth.uid();
  v_mesa uuid;
  v_total integer := 0;
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    return 0;
  end if;
  for v_mesa in
    select r.mesa_id
    from public.mesa_responsables r
    join public.mesas m on m.id = r.mesa_id
    where r.user_id = v_user
      and m.es_prueba = coalesce(p_es_prueba, false)
      and not public.mesa_tiene_pedido(r.mesa_id)
  loop
    perform public.soltar_mesa_sin_orden(v_mesa, p_es_prueba);
    v_total := v_total + 1;
  end loop;
  return v_total;
end;
$$;

create or replace function public.admin_mesas_sin_orden(p_es_prueba boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar mesas sin pedido';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'mesa_id', m.id,
      'nombre', m.nombre,
      'responsable', r.device_label
    ) order by m.orden, m.nombre)
    from public.mesas m
    join public.mesa_responsables r on r.mesa_id = m.id
    where m.activa
      and m.es_prueba = coalesce(p_es_prueba, false)
      and not public.mesa_tiene_pedido(m.id)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.mesa_tiene_pedido(uuid) from public, anon, authenticated;
revoke all on function public.soltar_mesa_sin_orden(uuid, boolean) from public, anon, authenticated;
revoke all on function public.soltar_mesas_sin_orden(boolean) from public, anon, authenticated;
revoke all on function public.admin_mesas_sin_orden(boolean) from public, anon, authenticated;
grant execute on function public.soltar_mesa_sin_orden(uuid, boolean) to authenticated;
grant execute on function public.soltar_mesas_sin_orden(boolean) to authenticated;
grant execute on function public.admin_mesas_sin_orden(boolean) to authenticated;

commit;
