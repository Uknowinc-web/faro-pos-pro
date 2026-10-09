begin;

create table if not exists public.solicitudes_puesto (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('mesero', 'cocina', 'caja')),
  device_label text not null check (char_length(device_label) between 1 and 80),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'revoked')),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);

alter table public.solicitudes_puesto enable row level security;
revoke all on public.solicitudes_puesto from public, anon, authenticated;

create or replace function public.tiene_rol(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.staff_roles sr
    where sr.user_id = (select auth.uid())
      and sr.role = any(p_roles)
  );
$$;

revoke all on function public.tiene_rol(text[]) from public, anon, authenticated;
grant execute on function public.tiene_rol(text[]) to authenticated;

create or replace function public.solicitar_acceso_puesto(
  p_role text,
  p_device_label text
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

  select role into v_role
  from public.staff_roles
  where user_id = v_user_id;
  if v_role is not null then
    if v_role <> p_role then
      raise exception 'El aparato ya está autorizado para otro puesto';
    end if;
    return 'approved';
  end if;

  insert into public.solicitudes_puesto(user_id, role, device_label)
  values (v_user_id, p_role, trim(p_device_label))
  on conflict (user_id) do nothing;

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

create or replace function public.listar_solicitudes_puesto()
returns table (
  user_id uuid,
  requested_role text,
  device_label text,
  requested_at timestamptz,
  status text,
  reviewed_at timestamptz
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
  select s.user_id, s.role, s.device_label, s.requested_at, s.status, s.reviewed_at
  from public.solicitudes_puesto s
  order by (s.status = 'pending') desc, s.requested_at desc;
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
    insert into public.staff_roles(user_id, role)
    values (v_request.user_id, v_request.role);
    update public.solicitudes_puesto
    set status = 'approved', reviewed_at = now(), reviewed_by = auth.uid()
    where user_id = p_user_id;
  else
    update public.solicitudes_puesto
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid()
    where user_id = p_user_id;
  end if;
end;
$$;

create or replace function public.revocar_acceso_puesto(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede revocar puestos';
  end if;

  update public.solicitudes_puesto
  set status = 'revoked', reviewed_at = now(), reviewed_by = auth.uid()
  where user_id = p_user_id and status = 'approved';
  if not found then
    raise exception 'El aparato no tiene un acceso aprobado';
  end if;

  delete from public.staff_roles
  where user_id = p_user_id and role in ('mesero', 'cocina', 'caja');
end;
$$;

revoke all on function public.solicitar_acceso_puesto(text, text)
  from public, anon, authenticated;
revoke all on function public.listar_solicitudes_puesto()
  from public, anon, authenticated;
revoke all on function public.resolver_solicitud_puesto(uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.revocar_acceso_puesto(uuid)
  from public, anon, authenticated;

grant execute on function public.solicitar_acceso_puesto(text, text) to authenticated;
grant execute on function public.listar_solicitudes_puesto() to authenticated;
grant execute on function public.resolver_solicitud_puesto(uuid, boolean) to authenticated;
grant execute on function public.revocar_acceso_puesto(uuid) to authenticated;

commit;
