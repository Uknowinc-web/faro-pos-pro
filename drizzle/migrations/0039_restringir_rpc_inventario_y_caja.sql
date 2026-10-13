-- 0039: restringe RPC de lectura y evita invocacion directa del consumo de inventario.
-- Los clientes usan el rol PostgreSQL "authenticated", incluso cuando la identidad
-- de Supabase es anonima; por ello cada RPC sensible valida tambien el rol de Faro.
begin;

create or replace function public.caja_fondo_del_dia(
  p_fecha date,
  p_es_prueba boolean default false
)
returns numeric
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_monto numeric;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar el fondo de caja';
  end if;

  select f.monto into v_monto
  from public.caja_fondo f
  where f.fecha = p_fecha
    and f.es_prueba = coalesce(p_es_prueba, false);

  return coalesce(v_monto, 2000);
end;
$$;

create or replace function public.caja_listar_empleados()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar empleados desde caja';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id,
      'nombre', e.nombre,
      'puesto', e.puesto
    ) order by e.nombre), '[]'::jsonb)
    from public.empleados e
    where e.activo
  );
end;
$$;

create or replace function public.caja_listar_prestamos(
  p_fecha date,
  p_es_prueba boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar prestamos de caja';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id,
      'empleado', p.empleado_nombre,
      'monto', p.monto,
      'fecha', p.fecha,
      'nota', p.nota,
      'liquidado_fecha', p.liquidado_fecha
    ) order by p.fecha desc, p.created_at desc), '[]'::jsonb)
    from public.caja_prestamos p
    where p.es_prueba = coalesce(p_es_prueba, false)
      and (
        p.liquidado_fecha is null
        or p.fecha = p_fecha
        or p.liquidado_fecha = p_fecha
      )
  );
end;
$$;

create or replace function public.caja_listar_gastos(
  p_fecha date,
  p_es_prueba boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar gastos de caja';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', g.id,
      'concepto', g.concepto,
      'categoria', g.categoria,
      'monto', g.monto,
      'fecha', g.fecha
    ) order by g.created_at desc), '[]'::jsonb)
    from public.caja_gastos g
    where g.fecha = p_fecha
      and g.es_prueba = coalesce(p_es_prueba, false)
  );
end;
$$;

create or replace function public.listar_insumos()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administracion puede consultar insumos';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id,
      'nombre', i.nombre,
      'unidad', i.unidad,
      'existencia', i.existencia,
      'minimo', i.minimo,
      'costo', i.costo,
      'bajo', i.existencia <= i.minimo,
      'valor', round(i.existencia * i.costo, 2)
    ) order by i.nombre), '[]'::jsonb)
    from public.insumos i
    where i.activo
  );
end;
$$;

create or replace function public.listar_recetas()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administracion puede consultar recetas';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'producto_id', r.producto_id,
      'producto', p.nombre,
      'insumo_id', r.insumo_id,
      'insumo', i.nombre,
      'cantidad', r.cantidad,
      'unidad', i.unidad
    ) order by p.nombre, i.nombre), '[]'::jsonb)
    from public.recetas r
    join public.catalogo_productos p on p.id = r.producto_id
    join public.insumos i on i.id = r.insumo_id
  );
end;
$$;

create or replace function public.listar_movimientos()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administracion puede consultar movimientos de inventario';
  end if;

  return (
    select coalesce(jsonb_agg(row_to_json(m)), '[]'::jsonb)
    from (
      select
        mv.tipo,
        mv.cantidad,
        mv.existencia_despues,
        mv.motivo,
        mv.created_at,
        i.nombre as insumo,
        i.unidad
      from public.inventario_movimientos mv
      left join public.insumos i on i.id = mv.insumo_id
      order by mv.created_at desc
      limit 40
    ) m
  );
end;
$$;

-- Estas dos lecturas se usan tambien desde el POS para indicar variantes agotadas.
-- Se permite consultar existencias solo a aparatos que ya tienen un rol de Faro.
create or replace function public.listar_inventario()
returns table (
  producto_id text,
  nombre text,
  existencia numeric,
  minimo numeric,
  unidad text,
  activo boolean
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar inventario del POS';
  end if;

  return query
  select
    p.id,
    p.nombre,
    case
      when exists (
        select 1
        from public.recetas r
        where r.producto_id = p.id
      ) then (
        select min(floor(i.existencia / nullif(r.cantidad, 0)))
        from public.recetas r
        join public.insumos i on i.id = r.insumo_id
        where r.producto_id = p.id
      )
      else inv.existencia
    end,
    coalesce(inv.minimo, 0),
    coalesce(inv.unidad, 'pza'),
    p.activo
  from public.catalogo_productos p
  left join public.inventario inv on inv.producto_id = p.id
  where p.categoria not ilike '%barra%'
    and p.nombre not ilike '%barista%'
  order by p.categoria, p.nombre;
end;
$$;

create or replace function public.listar_inventario_variantes()
returns table (
  producto_id text,
  nombre text,
  variante text,
  existencia numeric
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[]) then
    raise exception 'No autorizado para consultar inventario por variante';
  end if;

  return query
  select v.producto_id, p.nombre, v.variante, v.existencia
  from public.inventario_variante v
  join public.catalogo_productos p on p.id = v.producto_id
  order by p.nombre, v.variante;
end;
$$;

-- Solo el trigger de venta debe invocar esta funcion interna.
-- Los clientes no deben descontar inventario llamando la RPC directamente.
revoke all on function public.descontar_producto(text, numeric, jsonb)
  from public, anon, authenticated;

revoke all on function public.caja_fondo_del_dia(date, boolean)
  from public, anon, authenticated;
revoke all on function public.caja_listar_empleados()
  from public, anon, authenticated;
revoke all on function public.caja_listar_prestamos(date, boolean)
  from public, anon, authenticated;
revoke all on function public.caja_listar_gastos(date, boolean)
  from public, anon, authenticated;
revoke all on function public.listar_insumos()
  from public, anon, authenticated;
revoke all on function public.listar_recetas()
  from public, anon, authenticated;
revoke all on function public.listar_movimientos()
  from public, anon, authenticated;
revoke all on function public.listar_inventario()
  from public, anon, authenticated;
revoke all on function public.listar_inventario_variantes()
  from public, anon, authenticated;

-- PostgREST necesita EXECUTE en authenticated para llamar una RPC. El rol de
-- negocio se valida dentro de cada funcion antes de leer datos sensibles.
grant execute on function public.caja_fondo_del_dia(date, boolean) to authenticated;
grant execute on function public.caja_listar_empleados() to authenticated;
grant execute on function public.caja_listar_prestamos(date, boolean) to authenticated;
grant execute on function public.caja_listar_gastos(date, boolean) to authenticated;
grant execute on function public.listar_insumos() to authenticated;
grant execute on function public.listar_recetas() to authenticated;
grant execute on function public.listar_movimientos() to authenticated;
grant execute on function public.listar_inventario() to authenticated;
grant execute on function public.listar_inventario_variantes() to authenticated;

commit;
