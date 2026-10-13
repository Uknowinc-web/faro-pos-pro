begin;

alter table public.admin_perfiles
  add column if not exists cambios_nombre integer not null default 0;

update public.admin_perfiles p
set cambios_nombre = coalesce((
  select count(*)::integer
  from public.audit_acciones a
  where a.user_id = p.user_id
    and a.accion = 'cambio_nombre_admin'
    and coalesce(a.detalle->>'anterior', '') <> ''
), 0);

create or replace function public.cupo_nombre_admin()
returns integer
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_cambios integer;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración';
  end if;
  select cambios_nombre into v_cambios
  from public.admin_perfiles
  where user_id = auth.uid();
  if v_cambios is null then
    return 2;
  end if;
  return greatest(0, 2 - v_cambios);
end;
$$;

create or replace function public.guardar_perfil_admin(p_nombre text)
returns text
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_anterior text;
  v_cambios integer;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración';
  end if;
  if char_length(v_nombre) not between 1 and 60 then
    raise exception 'Escribe un nombre de 1 a 60 caracteres';
  end if;
  select nombre, cambios_nombre into v_anterior, v_cambios
  from public.admin_perfiles
  where user_id = auth.uid()
  for update;
  if v_anterior is not distinct from v_nombre then
    return v_nombre;
  end if;
  if v_anterior is not null and coalesce(v_cambios, 0) >= 2 then
    raise exception 'Este nombre ya no se puede cambiar. Usaste los 2 cambios permitidos';
  end if;
  begin
    insert into public.admin_perfiles(user_id, nombre, cambios_nombre)
    values (auth.uid(), v_nombre, 0)
    on conflict (user_id) do update
      set nombre = excluded.nombre,
          actualizado_at = now(),
          cambios_nombre = public.admin_perfiles.cambios_nombre + 1;
  exception when unique_violation then
    raise exception 'Ya hay un administrador con ese nombre. Elige otro';
  end;
  insert into public.audit_acciones(
    user_id, device_label, role, accion, detalle, responsable
  ) values (
    auth.uid(), 'Administración', 'admin', 'cambio_nombre_admin',
    jsonb_build_object('anterior', coalesce(v_anterior, ''), 'nuevo', v_nombre),
    v_nombre
  );
  return v_nombre;
end;
$$;

revoke all on function public.cupo_nombre_admin() from public, anon, authenticated;
revoke all on function public.guardar_perfil_admin(text) from public, anon, authenticated;
grant execute on function public.cupo_nombre_admin() to authenticated;
grant execute on function public.guardar_perfil_admin(text) to authenticated;

commit;
