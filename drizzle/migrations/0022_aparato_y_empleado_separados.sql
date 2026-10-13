begin;

-- Aparato y empleado son cosas distintas.
-- Aprobar un aparato solo le da el puesto. El empleado se crea en el panel, con PIN.

drop function if exists public.solicitar_acceso_puesto(text, text, text, text);
drop function if exists public.solicitar_acceso_puesto(text, text, text);

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
    raise exception 'Se requiere una identidad anonima de aparato';
  end if;
  if p_role is null or p_role not in ('mesero', 'cocina', 'caja') then
    raise exception 'Puesto no valido';
  end if;
  if char_length(trim(coalesce(p_device_label, ''))) not between 1 and 80 then
    raise exception 'Escribe un nombre de aparato de 1 a 80 caracteres';
  end if;

  select role into v_role from public.staff_roles where user_id = v_user_id;
  if v_role is not null then
    if v_role <> p_role then
      raise exception 'El aparato ya esta autorizado para otro puesto';
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
    set device_label = trim(p_device_label),
        empleado_nombre = null,
        pin_texto = null
    where user_id = v_user_id;
  end if;
  return v_status;
end;
$$;

-- Aprobar solo autoriza el aparato. No crea empleado.
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
    raise exception 'Solo administracion puede resolver solicitudes';
  end if;

  select * into v_request
  from public.solicitudes_puesto
  where user_id = p_user_id
  for update;
  if not found or (
    v_request.status <> 'pending'
    and not (p_approve and v_request.status in ('rejected', 'revoked'))
  ) then
    raise exception 'La solicitud ya no esta pendiente';
  end if;

  if p_approve then
    insert into public.staff_roles(user_id, role)
    values (v_request.user_id, v_request.role)
    on conflict (user_id) do nothing;
    update public.solicitudes_puesto
    set status = 'approved',
        reviewed_at = now(),
        reviewed_by = auth.uid(),
        empleado_id = null,
        empleado_nombre = null,
        pin_texto = null
    where user_id = p_user_id;
  else
    update public.asistencias
    set salida_at = coalesce(salida_at, now())
    where user_id = p_user_id and salida_at is null;
    delete from public.intentos_pin_empleado where user_id = p_user_id;
    delete from public.staff_roles
    where user_id = p_user_id and role in ('mesero', 'cocina', 'caja');
    delete from auth.users
    where id = p_user_id and is_anonymous = true;
  end if;
end;
$$;

create or replace function public.admin_limpiar_aparatos_huerfanos()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_ids uuid[];
  v_count integer;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administracion puede limpiar aparatos';
  end if;

  select array_agg(u.id) into v_ids
  from auth.users u
  where u.is_anonymous = true
    and not exists (select 1 from public.staff_roles sr where sr.user_id = u.id)
    and not exists (
      select 1 from public.solicitudes_puesto s
      where s.user_id = u.id and s.status = 'pending'
    );

  if v_ids is null then
    return 0;
  end if;

  update public.asistencias
  set salida_at = coalesce(salida_at, now())
  where user_id = any(v_ids) and salida_at is null;

  delete from public.intentos_pin_empleado where user_id = any(v_ids);
  delete from public.staff_roles
  where user_id = any(v_ids) and role in ('mesero', 'cocina', 'caja');
  delete from auth.users where id = any(v_ids) and is_anonymous = true;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.solicitar_acceso_puesto(text, text) from public, anon, authenticated;
revoke all on function public.resolver_solicitud_puesto(uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_limpiar_aparatos_huerfanos() from public, anon, authenticated;

grant execute on function public.solicitar_acceso_puesto(text, text) to authenticated;
grant execute on function public.resolver_solicitud_puesto(uuid, boolean) to authenticated;
grant execute on function public.admin_limpiar_aparatos_huerfanos() to authenticated;

commit;
