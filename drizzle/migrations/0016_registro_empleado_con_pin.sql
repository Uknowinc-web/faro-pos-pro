begin;

-- PIN legible: solo lo lee el administrador mediante RPC (RLS cerrado en las tablas).
alter table public.empleados add column if not exists pin_texto text
  check (pin_texto is null or pin_texto ~ '^[0-9]{4,8}$');
create unique index if not exists empleados_pin_texto_activo_uk
  on public.empleados (pin_texto) where activo and pin_texto is not null;

alter table public.solicitudes_puesto
  add column if not exists empleado_nombre text
    check (empleado_nombre is null or char_length(trim(empleado_nombre)) between 1 and 80),
  add column if not exists pin_texto text
    check (pin_texto is null or pin_texto ~ '^[0-9]{4,8}$'),
  add column if not exists empleado_id uuid references public.empleados(id);

-- ---------------------------------------------------------------------------
-- Solicitud: el empleado elige nombre y PIN antes de ser autorizado
-- ---------------------------------------------------------------------------
drop function if exists public.solicitar_acceso_puesto(text, text);

create or replace function public.solicitar_acceso_puesto(
  p_role text,
  p_device_label text,
  p_empleado_nombre text default null,
  p_pin text default null
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_status text;
  v_nombre text := trim(coalesce(p_empleado_nombre, ''));
begin
  if v_user_id is null
     or (select auth.jwt()->>'is_anonymous') is distinct from 'true' then
    raise exception 'Se requiere una identidad anónima de aparato';
  end if;
  if p_role is null or p_role not in ('mesero', 'cocina', 'caja') then
    raise exception 'Puesto no válido';
  end if;
  if char_length(trim(coalesce(p_device_label, ''))) not between 1 and 80 then
    raise exception 'Escribe un nombre de aparato de 1 a 80 caracteres';
  end if;

  select role into v_role from public.staff_roles where user_id = v_user_id;
  if v_role is not null then
    if v_role <> p_role then
      raise exception 'El aparato ya está autorizado para otro puesto';
    end if;
    return 'approved';
  end if;

  if not exists (select 1 from public.solicitudes_puesto where user_id = v_user_id) then
    if char_length(v_nombre) not between 1 and 80 then
      raise exception 'Escribe tu nombre (máximo 80 caracteres)';
    end if;
    if coalesce(p_pin, '') !~ '^[0-9]{4,8}$' then
      raise exception 'El PIN debe tener entre 4 y 8 dígitos';
    end if;
    if exists (select 1 from public.empleados e where e.activo and e.pin_texto = p_pin) then
      raise exception 'Ese PIN ya está en uso. Elige otro';
    end if;
    insert into public.solicitudes_puesto(user_id, role, device_label, empleado_nombre, pin_texto)
    values (v_user_id, p_role, trim(p_device_label), v_nombre, p_pin)
    on conflict (user_id) do nothing;
  end if;

  select role, status into v_role, v_status
  from public.solicitudes_puesto
  where user_id = v_user_id
  for update;
  if not found then
    raise exception 'No se pudo guardar la solicitud del aparato';
  end if;
  if v_role <> p_role then
    raise exception 'Ya existe una solicitud para otro puesto en este aparato';
  end if;
  if v_status = 'pending' then
    update public.solicitudes_puesto
    set device_label = trim(p_device_label)
    where user_id = v_user_id;
  end if;
  return v_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- Aprobación: crea al empleado con el PIN elegido y lo vincula al aparato
-- ---------------------------------------------------------------------------
create or replace function public.resolver_solicitud_puesto(
  p_user_id uuid,
  p_approve boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_request public.solicitudes_puesto%rowtype;
  v_empleado uuid;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede resolver solicitudes';
  end if;

  select * into v_request
  from public.solicitudes_puesto
  where user_id = p_user_id
  for update;
  if not found or (
    v_request.status <> 'pending'
    and not (p_approve and v_request.status in ('rejected', 'revoked'))
  ) then
    raise exception 'La solicitud ya no está pendiente';
  end if;

  if p_approve then
    v_empleado := v_request.empleado_id;
    if v_empleado is null and v_request.pin_texto is not null then
      if exists (select 1 from public.empleados e where e.activo and e.pin_texto = v_request.pin_texto) then
        raise exception 'El PIN elegido ya lo usa otro empleado activo. Rechaza la solicitud para que elija otro';
      end if;
      insert into public.empleados(nombre, puesto, pin_hash, pin_texto, activo)
      values (v_request.empleado_nombre, v_request.role,
              crypt(v_request.pin_texto, gen_salt('bf', 10)), v_request.pin_texto, true)
      returning id into v_empleado;
    elsif v_empleado is not null then
      if exists (
        select 1 from public.empleados e
        where e.id = v_empleado and not e.activo and e.pin_texto is not null
          and exists (select 1 from public.empleados o
                      where o.activo and o.id <> e.id and o.pin_texto = e.pin_texto)
      ) then
        raise exception 'El PIN de este empleado ya lo usa otro empleado activo';
      end if;
      update public.empleados set activo = true, actualizado_at = now() where id = v_empleado;
    end if;
    insert into public.staff_roles(user_id, role)
    values (v_request.user_id, v_request.role)
    on conflict (user_id) do nothing;
    update public.solicitudes_puesto
    set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid(), empleado_id = v_empleado
    where user_id = p_user_id;
  else
    update public.solicitudes_puesto
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
    where user_id = p_user_id;
  end if;
end;
$$;

drop function if exists public.listar_solicitudes_puesto();
create or replace function public.listar_solicitudes_puesto()
returns table (
  user_id uuid,
  requested_role text,
  device_label text,
  requested_at timestamptz,
  status text,
  reviewed_at timestamptz,
  empleado_id uuid,
  empleado_nombre text,
  pin text,
  empleado_activo boolean,
  en_turno boolean,
  entrada_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar solicitudes';
  end if;

  return query
  select s.user_id, s.role, s.device_label, s.requested_at, s.status, s.reviewed_at,
         s.empleado_id, coalesce(e.nombre, s.empleado_nombre),
         coalesce(e.pin_texto, s.pin_texto), e.activo,
         a.id is not null, a.entrada_at
  from public.solicitudes_puesto s
  left join public.empleados e on e.id = s.empleado_id
  left join public.asistencias a on a.empleado_id = e.id and a.salida_at is null
  order by (s.status = 'pending') desc, s.requested_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- Empleados: PIN visible para administración y unicidad entre activos
-- ---------------------------------------------------------------------------
create or replace function public.admin_guardar_empleado(
  p_id uuid, p_nombre text, p_puesto text, p_pin text, p_activo boolean
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_id uuid := p_id;
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_pin text := nullif(p_pin, '');
  v_pin_final text;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar empleados';
  end if;
  if char_length(v_nombre) not between 1 and 80 or p_puesto is null
     or p_puesto not in ('mesero', 'caja', 'cocina') then
    raise exception 'Nombre o puesto de empleado inválido';
  end if;
  if v_pin is not null and v_pin !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN debe tener entre 4 y 8 dígitos';
  end if;
  if p_id is null and v_pin is null then
    raise exception 'El PIN debe tener entre 4 y 8 dígitos';
  end if;
  if p_id is not null and coalesce(p_activo, false) and v_pin is null
     and exists (select 1 from public.empleados e where e.id = p_id and not e.activo) then
    raise exception 'Asigna un PIN nuevo para reactivar al empleado';
  end if;
  if p_id is not null then
    select coalesce(v_pin, e.pin_texto) into v_pin_final from public.empleados e where e.id = p_id;
    if not found then raise exception 'Empleado no encontrado'; end if;
  else
    v_pin_final := v_pin;
  end if;
  if coalesce(p_activo, false) and v_pin_final is not null and exists (
    select 1 from public.empleados e
    where e.id is distinct from p_id and e.activo and e.pin_texto = v_pin_final
  ) then
    raise exception 'Ese PIN ya está asignado a otro empleado activo';
  end if;
  if v_pin is not null and exists (
    select 1 from public.empleados e
    where e.id is distinct from p_id and e.activo and crypt(v_pin, e.pin_hash) = e.pin_hash
  ) then
    raise exception 'Ese PIN ya está asignado a otro empleado activo';
  end if;

  if p_id is null then
    insert into public.empleados(nombre, puesto, pin_hash, pin_texto, activo)
    values (v_nombre, p_puesto, crypt(v_pin, gen_salt('bf', 10)), v_pin, coalesce(p_activo, true))
    returning id into v_id;
  else
    if exists (
      select 1 from public.asistencias a
      where a.empleado_id = p_id and a.salida_at is null and a.puesto <> p_puesto
    ) then
      raise exception 'Registra la salida antes de cambiar el puesto del empleado';
    end if;
    if not coalesce(p_activo, false) and exists (
      select 1 from public.asistencias a where a.empleado_id = p_id and a.salida_at is null
    ) then
      raise exception 'Registra la salida del empleado antes de desactivarlo';
    end if;
    update public.empleados
    set nombre = v_nombre, puesto = p_puesto, activo = coalesce(p_activo, false),
        pin_hash = case when v_pin is null then pin_hash else crypt(v_pin, gen_salt('bf', 10)) end,
        pin_texto = v_pin_final,
        actualizado_at = now()
    where id = p_id;
  end if;
  perform public.registrar_accion(
    'editar_empleado', null, null, null, null,
    jsonb_build_object('empleado_id', v_id, 'nombre', v_nombre, 'puesto', p_puesto, 'activo', p_activo)
  );
  return v_id;
end;
$$;

drop function if exists public.admin_listar_empleados();
create or replace function public.admin_listar_empleados()
returns table (
  id uuid, nombre text, puesto text, activo boolean,
  asistencia_id uuid, entrada_at timestamptz, user_id uuid,
  pin text, aparato text, ultima_entrada_at timestamptz
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar empleados';
  end if;
  return query
  select e.id, e.nombre, e.puesto, e.activo, a.id, a.entrada_at, a.user_id,
         e.pin_texto,
         (select s.device_label from public.solicitudes_puesto s where s.empleado_id = e.id limit 1),
         (select max(h.entrada_at) from public.asistencias h where h.empleado_id = e.id)
  from public.empleados e
  left join public.asistencias a on a.empleado_id = e.id and a.salida_at is null
  order by e.activo desc, e.puesto, e.nombre;
end;
$$;

-- ---------------------------------------------------------------------------
-- Caja: modificar cuentas abiertas (cantidad o quitar artículos)
-- ---------------------------------------------------------------------------
create or replace function public.caja_editar_articulo_cuenta(
  p_cuenta uuid, p_item uuid, p_cantidad integer
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
begin
  if not public.tiene_rol(array['caja']::text[]) then
    raise exception 'Solo Caja puede modificar cuentas';
  end if;
  if not exists (
    select 1 from public.asistencias a
    where a.user_id = auth.uid() and a.salida_at is null and a.puesto = 'caja'
  ) then
    raise exception 'Inicia tu turno con tu PIN para modificar cuentas';
  end if;
  if p_cantidad is null or p_cantidad not between 0 and 99 then
    raise exception 'Cantidad inválida';
  end if;
  select c.mesa_id into v_mesa
  from public.cuentas c
  where c.id = p_cuenta and c.estado in ('abierta', 'por_cobrar')
  for update;
  if v_mesa is null then raise exception 'La cuenta ya no está abierta'; end if;
  if not exists (
    select 1 from public.comanda_items i join public.comandas co on co.id = i.comanda_id
    where i.id = p_item and co.cuenta_id = p_cuenta for update of i
  ) then
    raise exception 'Artículo no encontrado en la cuenta';
  end if;
  if p_cantidad = 0 then
    delete from public.comanda_items where id = p_item;
  else
    update public.comanda_items set cantidad = p_cantidad where id = p_item;
  end if;
  perform public.registrar_accion(
    'editar_comanda', v_mesa, p_cuenta, null, null,
    jsonb_build_object('articulo_id', p_item, 'cantidad', p_cantidad)
  );
end;
$$;

revoke all on function public.solicitar_acceso_puesto(text, text, text, text) from public, anon, authenticated;
revoke all on function public.listar_solicitudes_puesto() from public, anon, authenticated;
revoke all on function public.resolver_solicitud_puesto(uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_guardar_empleado(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_listar_empleados() from public, anon, authenticated;
revoke all on function public.caja_editar_articulo_cuenta(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function public.solicitar_acceso_puesto(text, text, text, text) to authenticated;
grant execute on function public.listar_solicitudes_puesto() to authenticated;
grant execute on function public.resolver_solicitud_puesto(uuid, boolean) to authenticated;
grant execute on function public.admin_guardar_empleado(uuid, text, text, text, boolean) to authenticated;
grant execute on function public.admin_listar_empleados() to authenticated;
grant execute on function public.caja_editar_articulo_cuenta(uuid, uuid, integer) to authenticated;

commit;
