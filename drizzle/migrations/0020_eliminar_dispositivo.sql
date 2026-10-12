create or replace function public.admin_eliminar_dispositivo(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar dispositivos';
  end if;
  if not exists (select 1 from public.solicitudes_puesto where user_id = p_user_id) then
    raise exception 'El dispositivo no existe';
  end if;

  update public.asistencias set salida_at = now()
  where user_id = p_user_id and salida_at is null;

  delete from public.staff_roles
  where user_id = p_user_id and role in ('mesero', 'cocina', 'caja');

  delete from public.solicitudes_puesto where user_id = p_user_id;
end;
$$;

revoke all on function public.admin_eliminar_dispositivo(uuid) from public, anon, authenticated;
grant execute on function public.admin_eliminar_dispositivo(uuid) to authenticated;

notify pgrst, 'reload schema';
