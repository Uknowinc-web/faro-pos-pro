begin;

-- El orden de las mesas ya no lo captura administración: una mesa nueva queda al
-- final de su modo (prueba u operación) y al editar se conserva su posición.
create or replace function public.admin_guardar_mesa(
  p_id uuid, p_nombre text, p_orden integer, p_activa boolean, p_es_prueba boolean
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_id uuid := p_id;
  v_orden integer;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar mesas';
  end if;
  if char_length(v_nombre) not between 1 and 80 then
    raise exception 'Nombre de mesa inválido';
  end if;
  if coalesce(p_es_prueba, false) and lower(v_nombre) not like 'prueba · %' then
    v_nombre := 'PRUEBA · ' || v_nombre;
  end if;
  if exists (
    select 1 from public.mesas m
    where lower(m.nombre) = lower(v_nombre) and m.id is distinct from p_id
  ) then
    raise exception 'Ya existe una mesa con ese nombre';
  end if;
  if p_id is null then
    lock table public.mesas in share row exclusive mode;
    select least(coalesce(max(m.orden), 0) + 1, 999)
    into v_orden
    from public.mesas m
    where m.es_prueba = coalesce(p_es_prueba, false);
    insert into public.mesas(nombre, orden, activa, es_prueba)
    values (v_nombre, v_orden, coalesce(p_activa, true), coalesce(p_es_prueba, false))
    returning id into v_id;
  else
    update public.mesas
    set nombre = v_nombre, activa = coalesce(p_activa, false)
    where id = p_id and es_prueba = coalesce(p_es_prueba, false)
    returning orden into v_orden;
    if not found then raise exception 'Mesa no disponible en este modo'; end if;
    if not coalesce(p_activa, false) and exists (
      select 1 from public.cuentas c
      where c.mesa_id = p_id and c.estado in ('abierta', 'por_cobrar')
    ) then
      raise exception 'No se puede desactivar una mesa con cuenta abierta';
    end if;
    if not coalesce(p_activa, false) and exists (
      select 1 from public.mesa_responsables r where r.mesa_id = p_id
    ) then
      raise exception 'No se puede desactivar una mesa asignada a un mesero';
    end if;
  end if;
  perform public.registrar_accion(
    'editar_mesa', v_id, null, null, null,
    jsonb_build_object('nombre', v_nombre, 'orden', v_orden, 'activa', p_activa)
  );
  return v_id;
end;
$$;

revoke all on function public.admin_guardar_mesa(uuid, text, integer, boolean, boolean) from public, anon, authenticated;
grant execute on function public.admin_guardar_mesa(uuid, text, integer, boolean, boolean) to authenticated;

commit;
