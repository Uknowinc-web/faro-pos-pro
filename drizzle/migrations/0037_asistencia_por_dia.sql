begin;

-- Una asistencia por persona y día. Se conservan las que ya estaban abiertas.
delete from public.asistencias a
where a.salida_at is not null
  and exists (
    select 1
    from public.asistencias b
    where b.empleado_id = a.empleado_id
      and b.id <> a.id
      and (b.entrada_at at time zone 'America/Monterrey')::date
        = (a.entrada_at at time zone 'America/Monterrey')::date
      and (
        b.salida_at is null
        or b.entrada_at < a.entrada_at
        or (b.entrada_at = a.entrada_at and b.id < a.id)
      )
  );

create unique index if not exists asistencias_empleado_dia_uk
  on public.asistencias (
    empleado_id,
    ((entrada_at at time zone 'America/Monterrey')::date)
  );

create or replace function public.admin_listar_asistencia(p_fecha date default null)
returns table (
  id uuid, empleado_id uuid, nombre text, puesto text,
  entrada_at timestamptz, salida_at timestamptz
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Monterrey')::date);
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar asistencia';
  end if;
  return query
  select
    (array_agg(a.id order by a.entrada_at))[1],
    e.id,
    e.nombre,
    (array_agg(a.puesto order by a.entrada_at desc))[1],
    min(a.entrada_at),
    case when bool_or(a.salida_at is null) then null else max(a.salida_at) end
  from public.asistencias a
  join public.empleados e on e.id = a.empleado_id
  where (a.entrada_at at time zone 'America/Monterrey')::date = v_fecha
  group by e.id, e.nombre
  order by min(a.entrada_at);
end;
$$;

create or replace function public.iniciar_turno_empleado(p_pin text)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_role text;
  v_employee public.empleados%rowtype;
  v_shift public.asistencias%rowtype;
  v_attempt public.intentos_pin_empleado%rowtype;
  v_hoy date := (now() at time zone 'America/Monterrey')::date;
begin
  if v_user is null or not public.tiene_rol(array['mesero', 'caja', 'cocina']::text[]) then
    raise exception 'Se requiere un dispositivo autorizado';
  end if;
  select role into v_role from public.staff_roles where user_id = v_user;
  select * into v_attempt from public.intentos_pin_empleado where user_id = v_user for update;
  if v_attempt.bloqueado_hasta > now() then
    return jsonb_build_object(
      'ok', false,
      'error', 'Demasiados intentos. Espera unos minutos antes de volver a intentar'
    );
  end if;
  select * into v_employee from public.empleados
  where activo and puesto = v_role and crypt(coalesce(p_pin, ''), pin_hash) = pin_hash
  limit 1 for update;
  if not found then
    insert into public.intentos_pin_empleado as pin_attempt(user_id, intentos, bloqueado_hasta)
    values (v_user, 1, null)
    on conflict (user_id) do update
    set intentos = case when pin_attempt.bloqueado_hasta < now()
                         then 1 else pin_attempt.intentos + 1 end,
        bloqueado_hasta = case
          when pin_attempt.bloqueado_hasta < now() then null
          when pin_attempt.intentos >= 4 then now() + interval '10 minutes'
          else null
        end;
    return jsonb_build_object(
      'ok', false,
      'error', 'PIN incorrecto o no corresponde a este puesto'
    );
  end if;

  select * into v_shift from public.asistencias
  where empleado_id = v_employee.id and salida_at is null for update;
  if found and v_shift.user_id <> v_user then
    raise exception 'Este empleado ya tiene un turno abierto en otro dispositivo';
  elsif not found then
    if exists (select 1 from public.asistencias where user_id = v_user and salida_at is null) then
      raise exception 'Registra la salida del turno anterior en este dispositivo';
    end if;
    select * into v_shift from public.asistencias
    where empleado_id = v_employee.id
      and (entrada_at at time zone 'America/Monterrey')::date = v_hoy
    order by entrada_at
    limit 1
    for update;
    if found then
      update public.asistencias
      set salida_at = null, user_id = v_user, puesto = v_employee.puesto
      where id = v_shift.id
      returning * into v_shift;
    else
      insert into public.asistencias(empleado_id, user_id, puesto)
      values (v_employee.id, v_user, v_employee.puesto)
      returning * into v_shift;
      insert into public.audit_acciones(
        user_id, device_label, role, accion, empleado_id, detalle
      )
      select v_user, coalesce(nullif(trim(sp.device_label), ''), 'Dispositivo'),
             v_role, 'entrada_empleado', v_employee.id,
             jsonb_build_object('empleado', v_employee.nombre)
      from public.solicitudes_puesto sp where sp.user_id = v_user;
    end if;
  end if;
  delete from public.intentos_pin_empleado where user_id = v_user;
  return jsonb_build_object(
    'ok', true, 'id', v_employee.id, 'nombre', v_employee.nombre, 'puesto', v_employee.puesto,
    'asistencia_id', v_shift.id, 'entrada_at', v_shift.entrada_at
  );
end;
$$;

revoke all on function public.admin_listar_asistencia(date) from public, anon, authenticated;
revoke all on function public.iniciar_turno_empleado(text) from public, anon, authenticated;
grant execute on function public.admin_listar_asistencia(date) to authenticated;
grant execute on function public.iniciar_turno_empleado(text) to authenticated;

commit;
