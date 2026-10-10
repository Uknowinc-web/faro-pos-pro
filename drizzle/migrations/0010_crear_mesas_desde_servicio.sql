begin;

drop policy if exists "caja puede crear mesas" on public.mesas;
revoke insert on public.mesas from public, anon, authenticated;

create or replace function public.crear_mesa(
  p_nombre text,
  p_es_prueba boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_es_prueba boolean := coalesce(p_es_prueba, false);
  v_orden integer;
  v_mesa_id uuid;
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    raise exception 'Solo el personal de servicio autorizado puede agregar mesas';
  end if;
  if char_length(v_nombre) not between 1 and 80 then
    raise exception 'El nombre de la mesa debe tener entre 1 y 80 caracteres';
  end if;
  if v_es_prueba and lower(v_nombre) not like 'prueba · %' then
    v_nombre := 'PRUEBA · ' || v_nombre;
  end if;
  perform pg_advisory_xact_lock(hashtext(lower(v_nombre)));
  if exists (
    select 1
    from public.mesas m
    where lower(m.nombre) = lower(v_nombre)
  ) then
    raise exception 'Ya existe una mesa con ese nombre';
  end if;

  select coalesce(max(m.orden), 0) + 1
  into v_orden
  from public.mesas m
  where m.es_prueba = v_es_prueba;

  begin
    insert into public.mesas(nombre, orden, es_prueba)
    values (v_nombre, v_orden, v_es_prueba)
    returning id into v_mesa_id;
  exception
    when unique_violation then
      raise exception 'Ya existe una mesa con ese nombre';
  end;

  return v_mesa_id;
end;
$$;

revoke all on function public.crear_mesa(text, boolean)
  from public, anon, authenticated;
grant execute on function public.crear_mesa(text, boolean)
  to authenticated;

commit;
