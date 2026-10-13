begin;

alter table public.catalogo_productos
  add column if not exists vigente_desde date,
  add column if not exists vigente_hasta date;

-- El mesero solo ve promociones dentro de su vigencia.
create or replace function public.listar_catalogo_pos()
returns table (
  id text, nombre text, categoria text, precio numeric,
  permite_mezcla boolean, extra_tripa_principal numeric,
  permite_queso boolean, extra_queso numeric, descripcion text
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_hoy date := (now() at time zone 'America/Monterrey')::date;
begin
  if not public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar el catálogo';
  end if;
  return query
  select p.id, p.nombre, p.categoria, p.precio,
         p.permite_mezcla, p.extra_tripa_principal, p.permite_queso, p.extra_queso,
         p.descripcion
  from public.catalogo_productos p
  where p.activo
    and (
      p.categoria <> 'Promociones'
      or (
        (p.vigente_desde is null or p.vigente_desde <= v_hoy)
        and (p.vigente_hasta is null or p.vigente_hasta >= v_hoy)
      )
    )
  order by p.categoria, p.nombre;
end;
$$;

drop function if exists public.admin_listar_catalogo();
create function public.admin_listar_catalogo()
returns table (
  id text, nombre text, categoria text, precio numeric, activo boolean,
  permite_mezcla boolean, permite_queso boolean, descripcion text,
  vigente_desde date, vigente_hasta date
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar el catálogo completo';
  end if;
  return query
  select p.id, p.nombre, p.categoria, p.precio, p.activo,
         p.permite_mezcla, p.permite_queso, p.descripcion,
         p.vigente_desde, p.vigente_hasta
  from public.catalogo_productos p
  order by p.categoria, p.nombre;
end;
$$;

drop function if exists public.admin_guardar_promocion(text, text, numeric, text, boolean);
create or replace function public.admin_guardar_promocion(
  p_id text, p_nombre text, p_precio numeric, p_descripcion text, p_activo boolean,
  p_desde date default null, p_hasta date default null
)
returns text
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_id text := nullif(trim(coalesce(p_id, '')), '');
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_desc text := nullif(trim(coalesce(p_descripcion, '')), '');
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar promociones';
  end if;
  if char_length(v_nombre) not between 1 and 100
     or p_precio is null or p_precio < 0 or p_precio > 100000
     or char_length(coalesce(v_desc, '')) > 300 then
    raise exception 'Datos de promoción inválidos';
  end if;
  if p_desde is not null and p_hasta is not null and p_hasta < p_desde then
    raise exception 'La fecha final no puede ser anterior a la inicial';
  end if;
  if v_id is null then
    v_id := 'promo-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  elsif v_id !~ '^promo-[a-z0-9-]{2,58}$'
        or not exists (select 1 from public.catalogo_productos p where p.id = v_id and p.categoria = 'Promociones') then
    raise exception 'Promoción no encontrada';
  end if;
  insert into public.catalogo_productos(
    id, nombre, categoria, precio, activo, descripcion, vigente_desde, vigente_hasta
  )
  values (v_id, v_nombre, 'Promociones', p_precio, coalesce(p_activo, true), v_desc, p_desde, p_hasta)
  on conflict (id) do update
  set nombre = excluded.nombre, precio = excluded.precio, activo = excluded.activo,
      descripcion = excluded.descripcion, vigente_desde = excluded.vigente_desde,
      vigente_hasta = excluded.vigente_hasta, updated_at = now();
  perform public.registrar_accion(
    'editar_producto', null, null, null, p_precio,
    jsonb_build_object('producto_id', v_id, 'nombre', v_nombre, 'promocion', true, 'activo', p_activo)
  );
  return v_id;
end;
$$;

create or replace function public.admin_eliminar_mesa(p_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_usada boolean;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar mesas';
  end if;
  select nombre into v_nombre from public.mesas where id = p_id;
  if v_nombre is null then
    raise exception 'Mesa no encontrada';
  end if;
  if exists (
    select 1 from public.cuentas
    where mesa_id = p_id and estado in ('abierta', 'por_cobrar')
  ) then
    raise exception 'La mesa tiene una cuenta abierta. Ciérrala primero.';
  end if;
  select exists (select 1 from public.cuentas where mesa_id = p_id) into v_usada;
  if v_usada then
    update public.mesas set activa = false where id = p_id;
  else
    delete from public.mesas where id = p_id;
  end if;
  perform public.registrar_accion(
    'editar_mesa', p_id, null, null, null,
    jsonb_build_object('nombre', v_nombre, 'eliminada', true, 'ocultada', v_usada)
  );
end;
$$;

revoke all on function public.admin_guardar_promocion(text, text, numeric, text, boolean, date, date) from public, anon, authenticated;
revoke all on function public.admin_eliminar_mesa(uuid) from public, anon, authenticated;
grant execute on function public.admin_guardar_promocion(text, text, numeric, text, boolean, date, date) to authenticated;
grant execute on function public.admin_eliminar_mesa(uuid) to authenticated;

commit;
