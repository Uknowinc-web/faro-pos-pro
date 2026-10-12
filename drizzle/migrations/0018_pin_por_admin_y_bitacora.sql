begin;

-- ---------------------------------------------------------------------------
-- PIN asignado solo por administración: la solicitud ya no recibe ningún PIN.
-- ---------------------------------------------------------------------------
alter table public.empleados alter column pin_hash drop not null;
update public.solicitudes_puesto set pin_texto = null where pin_texto is not null;

drop function if exists public.solicitar_acceso_puesto(text, text, text, text);

create or replace function public.solicitar_acceso_puesto(
  p_role text,
  p_device_label text,
  p_empleado_nombre text default null
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
    if exists (select 1 from public.empleados e
               where e.activo and e.puesto = p_role
                 and lower(trim(e.nombre)) = lower(v_nombre))
       or exists (select 1 from public.solicitudes_puesto s
                  where s.status = 'pending' and s.role = p_role
                    and lower(trim(s.empleado_nombre)) = lower(v_nombre)) then
      raise exception 'Ese nombre ya está en uso en esta área. Ingresa otro nombre';
    end if;
    insert into public.solicitudes_puesto(user_id, role, device_label, empleado_nombre)
    values (v_user_id, p_role, trim(p_device_label), v_nombre)
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
set search_path = pg_catalog, public
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
    if v_empleado is null and v_request.empleado_nombre is not null then
      if exists (select 1 from public.empleados e
                 where e.activo and e.puesto = v_request.role
                   and lower(trim(e.nombre)) = lower(trim(v_request.empleado_nombre))) then
        raise exception 'Ya hay un empleado activo con ese nombre en esta área. Rechaza la solicitud para que ingrese otro nombre';
      end if;
      insert into public.empleados(nombre, puesto, pin_hash, pin_texto, activo)
      values (v_request.empleado_nombre, v_request.role, null, null, true)
      returning id into v_empleado;
    elsif v_empleado is not null then
      if exists (
        select 1 from public.empleados e
        where e.id = v_empleado and not e.activo
          and exists (select 1 from public.empleados o
                      where o.activo and o.id <> e.id and o.puesto = e.puesto
                        and lower(trim(o.nombre)) = lower(trim(e.nombre)))
      ) then
        raise exception 'Ya hay un empleado activo con ese nombre en esta área';
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

-- El aparato consulta si su empleado ya tiene PIN (sin revelarlo).
create or replace function public.empleado_aparato()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_row record;
begin
  if auth.uid() is null then raise exception 'Sesión requerida'; end if;
  select e.nombre, e.pin_hash is not null as tiene_pin
  into v_row
  from public.solicitudes_puesto s join public.empleados e on e.id = s.empleado_id
  where s.user_id = auth.uid();
  if not found then return null; end if;
  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- Nombre visible de cada administrador
-- ---------------------------------------------------------------------------
create table if not exists public.admin_perfiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null check (char_length(trim(nombre)) between 1 and 60),
  actualizado_at timestamptz not null default now()
);
create unique index if not exists admin_perfiles_nombre_uk
  on public.admin_perfiles (lower(trim(nombre)));
alter table public.admin_perfiles enable row level security;
revoke all on public.admin_perfiles from public, anon, authenticated;

create or replace function public.perfil_admin()
returns text
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración';
  end if;
  return (select p.nombre from public.admin_perfiles p where p.user_id = auth.uid());
end;
$$;

create or replace function public.guardar_perfil_admin(p_nombre text)
returns text
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración';
  end if;
  if char_length(v_nombre) not between 1 and 60 then
    raise exception 'Escribe un nombre de 1 a 60 caracteres';
  end if;
  begin
    insert into public.admin_perfiles(user_id, nombre) values (auth.uid(), v_nombre)
    on conflict (user_id) do update set nombre = excluded.nombre, actualizado_at = now();
  exception when unique_violation then
    raise exception 'Ya hay un administrador con ese nombre. Elige otro';
  end;
  return v_nombre;
end;
$$;

-- ---------------------------------------------------------------------------
-- Bitácora: responsable guardado en cada registro y consulta por periodo
-- ---------------------------------------------------------------------------
alter table public.audit_acciones add column if not exists responsable text;

create or replace function public.audit_asignar_responsable()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.responsable is null then
    new.responsable := nullif(trim(coalesce(new.detalle->>'empleado', '')), '');
  end if;
  return new;
end;
$$;

drop trigger if exists audit_asignar_responsable_trg on public.audit_acciones;
create trigger audit_asignar_responsable_trg
  before insert on public.audit_acciones
  for each row execute function public.audit_asignar_responsable();

update public.audit_acciones
set responsable = nullif(trim(coalesce(detalle->>'empleado', '')), '')
where responsable is null;

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
    'cobrar_cuenta', 'anular_cuenta', 'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado'
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

create or replace function public.auditoria_rango(
  p_desde date default null,
  p_hasta date default null,
  p_limite integer default 500
)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_hoy date := (now() at time zone 'America/Monterrey')::date;
  v_desde date := coalesce(p_desde, date '2000-01-01');
  v_hasta date := coalesce(p_hasta, v_hoy);
  v_limite integer := greatest(1, least(coalesce(p_limite, 500), 1000));
  v_total bigint;
  v_rows jsonb;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar la bitácora';
  end if;
  select count(*) into v_total from public.audit_acciones a
  where a.fecha_operativa between v_desde and v_hasta;
  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.created_at desc), '[]'::jsonb)
  into v_rows
  from (
    select a.id, a.created_at, a.fecha_operativa, a.user_id, a.device_label, a.role,
           a.accion, a.mesa_id, a.cuenta_id, a.comanda_id, a.monto, a.detalle,
           a.responsable, m.nombre as mesa_nombre
    from public.audit_acciones a
    left join public.mesas m on m.id = a.mesa_id
    where a.fecha_operativa between v_desde and v_hasta
    order by a.created_at desc
    limit v_limite
  ) t;
  return jsonb_build_object(
    'primera_fecha', (select min(a.fecha_operativa) from public.audit_acciones a),
    'hoy', v_hoy,
    'total', v_total,
    'acciones', v_rows
  );
end;
$$;

revoke all on function public.solicitar_acceso_puesto(text, text, text) from public, anon, authenticated;
revoke all on function public.resolver_solicitud_puesto(uuid, boolean) from public, anon, authenticated;
revoke all on function public.empleado_aparato() from public, anon, authenticated;
revoke all on function public.perfil_admin() from public, anon, authenticated;
revoke all on function public.guardar_perfil_admin(text) from public, anon, authenticated;
revoke all on function public.registrar_accion(text, uuid, uuid, uuid, numeric, jsonb) from public, anon, authenticated;
revoke all on function public.auditoria_rango(date, date, integer) from public, anon, authenticated;
revoke all on function public.audit_asignar_responsable() from public, anon, authenticated;
grant execute on function public.solicitar_acceso_puesto(text, text, text) to authenticated;
grant execute on function public.resolver_solicitud_puesto(uuid, boolean) to authenticated;
grant execute on function public.empleado_aparato() to authenticated;
grant execute on function public.perfil_admin() to authenticated;
grant execute on function public.guardar_perfil_admin(text) to authenticated;
grant execute on function public.auditoria_rango(date, date, integer) to authenticated;

commit;
