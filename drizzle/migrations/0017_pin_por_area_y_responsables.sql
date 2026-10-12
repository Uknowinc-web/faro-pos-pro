begin;

-- Nombre y PIN únicos solo dentro de la misma área; áreas distintas pueden repetirlos.
drop index if exists public.empleados_pin_texto_activo_uk;
create unique index if not exists empleados_puesto_pin_activo_uk
  on public.empleados (puesto, pin_texto) where activo and pin_texto is not null;

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
    if exists (select 1 from public.empleados e
               where e.activo and e.puesto = p_role and e.pin_texto = p_pin) then
      raise exception 'Ese PIN ya está en uso en esta área. Elige otro';
    end if;
    if exists (select 1 from public.empleados e
               where e.activo and e.puesto = p_role
                 and lower(trim(e.nombre)) = lower(v_nombre)) then
      raise exception 'Ya hay un empleado con ese nombre en esta área. Agrega tu apellido';
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
      if exists (select 1 from public.empleados e
                 where e.activo and e.puesto = v_request.role and e.pin_texto = v_request.pin_texto) then
        raise exception 'El PIN elegido ya lo usa otro empleado activo de esta área. Rechaza la solicitud para que elija otro';
      end if;
      if exists (select 1 from public.empleados e
                 where e.activo and e.puesto = v_request.role
                   and lower(trim(e.nombre)) = lower(trim(v_request.empleado_nombre))) then
        raise exception 'Ya hay un empleado activo con ese nombre en esta área. Rechaza la solicitud para que agregue su apellido';
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
                      where o.activo and o.id <> e.id and o.puesto = e.puesto
                        and o.pin_texto = e.pin_texto)
      ) then
        raise exception 'El PIN de este empleado ya lo usa otro empleado activo de su área';
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
  if coalesce(p_activo, false) then
    if v_pin_final is not null and exists (
      select 1 from public.empleados e
      where e.id is distinct from p_id and e.activo and e.puesto = p_puesto
        and e.pin_texto = v_pin_final
    ) then
      raise exception 'Ese PIN ya está asignado a otro empleado activo de esta área';
    end if;
    if v_pin is not null and exists (
      select 1 from public.empleados e
      where e.id is distinct from p_id and e.activo and e.puesto = p_puesto
        and crypt(v_pin, e.pin_hash) = e.pin_hash
    ) then
      raise exception 'Ese PIN ya está asignado a otro empleado activo de esta área';
    end if;
    if exists (
      select 1 from public.empleados e
      where e.id is distinct from p_id and e.activo and e.puesto = p_puesto
        and lower(trim(e.nombre)) = lower(v_nombre)
    ) then
      raise exception 'Ya hay un empleado activo con ese nombre en esta área';
    end if;
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

-- El PIN se busca solo entre empleados del puesto del aparato.
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
  delete from public.intentos_pin_empleado where user_id = v_user;
  return jsonb_build_object(
    'ok', true, 'id', v_employee.id, 'nombre', v_employee.nombre, 'puesto', v_employee.puesto,
    'asistencia_id', v_shift.id, 'entrada_at', v_shift.entrada_at
  );
end;
$$;

-- Cada administrador queda identificado por su correo en la bitácora.
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
  v_empleado_nombre text;
  v_email text := nullif(auth.jwt()->>'email', '');
  v_detalle jsonb := coalesce(p_detalle, '{}'::jsonb);
begin
  if v_user_id is null then return; end if;
  if p_accion not in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta', 'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado'
  ) then raise exception 'Acción de auditoría inválida'; end if;
  select sr.role into v_role from public.staff_roles sr where sr.user_id = v_user_id;
  if v_role is null then return; end if;
  if v_role = 'admin' then
    v_empleado_nombre := coalesce(v_email, 'Administrador ' || left(v_user_id::text, 8));
    v_label := 'Administración';
  else
    select a.empleado_id, e.nombre into v_empleado, v_empleado_nombre
    from public.asistencias a
    join public.empleados e on e.id = a.empleado_id
    where a.user_id = v_user_id and a.salida_at is null;
    v_label := coalesce(
      nullif(trim((select s.device_label from public.solicitudes_puesto s where s.user_id = v_user_id)), ''),
      initcap(v_role) || ' ' || left(v_user_id::text, 8)
    );
  end if;
  if v_empleado_nombre is not null then
    v_detalle := v_detalle || jsonb_build_object('empleado', v_empleado_nombre);
  end if;
  insert into public.audit_acciones(
    user_id, device_label, role, accion, empleado_id,
    mesa_id, cuenta_id, comanda_id, monto, detalle
  ) values (
    v_user_id, v_label, v_role, p_accion, v_empleado,
    p_mesa_id, p_cuenta_id, p_comanda_id, p_monto, v_detalle
  );
end;
$$;

commit;
