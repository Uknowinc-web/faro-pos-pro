begin;

create table if not exists public.caja_fondo (
  fecha date not null,
  es_prueba boolean not null default false,
  monto numeric(12, 2) not null default 2000,
  primary key (fecha, es_prueba)
);

create table if not exists public.caja_prestamos (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid references public.empleados(id) on delete set null,
  empleado_nombre text not null,
  monto numeric(12, 2) not null check (monto > 0),
  fecha date not null,
  nota text,
  es_prueba boolean not null default false,
  liquidado_fecha date,
  created_at timestamptz not null default now()
);

create table if not exists public.caja_gastos (
  id uuid primary key default gen_random_uuid(),
  concepto text not null,
  categoria text not null,
  monto numeric(12, 2) not null check (monto > 0),
  fecha date not null,
  es_prueba boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.cortes_caja
  add column if not exists gastos numeric(12, 2) not null default 0,
  add column if not exists prestamos numeric(12, 2) not null default 0,
  add column if not exists prestamos_cobrados numeric(12, 2) not null default 0;

create table if not exists public.insumos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  unidad text not null default 'kg',
  existencia numeric(14, 3) not null default 0,
  minimo numeric(14, 3) not null default 0,
  costo numeric(12, 2) not null default 0,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.recetas (
  producto_id text not null references public.catalogo_productos(id) on delete cascade,
  insumo_id uuid not null references public.insumos(id) on delete cascade,
  cantidad numeric(14, 3) not null check (cantidad > 0),
  primary key (producto_id, insumo_id)
);

create table if not exists public.inventario_movimientos (
  id uuid primary key default gen_random_uuid(),
  insumo_id uuid references public.insumos(id) on delete set null,
  producto_id text,
  tipo text not null check (tipo in ('compra', 'merma', 'ajuste', 'salida', 'venta')),
  cantidad numeric(14, 3) not null,
  existencia_despues numeric(14, 3),
  costo numeric(12, 2),
  motivo text,
  created_at timestamptz not null default now()
);

alter table public.caja_fondo enable row level security;
alter table public.caja_prestamos enable row level security;
alter table public.caja_gastos enable row level security;
alter table public.insumos enable row level security;
alter table public.recetas enable row level security;
alter table public.inventario_movimientos enable row level security;

insert into public.insumos(nombre, unidad, minimo) values
  ('Carne asada', 'kg', 2),
  ('Carne pastor', 'kg', 2),
  ('Tripa', 'kg', 1),
  ('Tortilla de maíz', 'kg', 3),
  ('Tortilla de harina', 'kg', 2),
  ('Queso', 'kg', 1),
  ('Cebolla', 'kg', 1),
  ('Cilantro', 'kg', 0.5),
  ('Frijoles', 'kg', 2),
  ('Papa', 'kg', 2),
  ('Aceite', 'litro', 1),
  ('Salsa', 'litro', 1)
on conflict (nombre) do nothing;

create or replace function public.caja_fondo_del_dia(p_fecha date, p_es_prueba boolean default false)
returns numeric
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select coalesce(
    (select monto from public.caja_fondo where fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false)),
    2000
  );
$$;

create or replace function public.caja_guardar_fondo(p_fecha date, p_monto numeric, p_es_prueba boolean default false)
returns numeric
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para el fondo de caja';
  end if;
  if p_monto < 0 or p_monto > 1000000 then
    raise exception 'Fondo inválido';
  end if;
  insert into public.caja_fondo(fecha, es_prueba, monto)
  values (p_fecha, coalesce(p_es_prueba, false), p_monto)
  on conflict (fecha, es_prueba) do update set monto = excluded.monto;
  return p_monto;
end;
$$;

create or replace function public.caja_listar_empleados()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'nombre', e.nombre, 'puesto', e.puesto
  ) order by e.nombre), '[]'::jsonb)
  from public.empleados e
  where e.activo;
$$;

create or replace function public.caja_registrar_prestamo(
  p_empleado uuid, p_monto numeric, p_fecha date, p_nota text default null, p_es_prueba boolean default false
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_id uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para registrar préstamos';
  end if;
  if p_monto <= 0 or p_monto > 100000 then
    raise exception 'Cantidad de préstamo inválida';
  end if;
  select nombre into v_nombre from public.empleados where id = p_empleado and activo;
  if v_nombre is null then
    raise exception 'Elige un empleado activo';
  end if;
  insert into public.caja_prestamos(empleado_id, empleado_nombre, monto, fecha, nota, es_prueba)
  values (p_empleado, v_nombre, p_monto, coalesce(p_fecha, (now() at time zone 'America/Monterrey')::date), nullif(trim(coalesce(p_nota, '')), ''), coalesce(p_es_prueba, false))
  returning id into v_id;
  perform public.registrar_accion('corte_caja', null, null, null, p_monto,
    jsonb_build_object('prestamo', v_nombre, 'fecha', p_fecha));
  return v_id;
end;
$$;

create or replace function public.caja_liquidar_prestamo(p_id uuid, p_fecha date default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_monto numeric;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado';
  end if;
  update public.caja_prestamos
  set liquidado_fecha = coalesce(p_fecha, (now() at time zone 'America/Monterrey')::date)
  where id = p_id and liquidado_fecha is null
  returning empleado_nombre, monto into v_nombre, v_monto;
  if v_nombre is null then
    raise exception 'Ese préstamo ya estaba cobrado o no existe';
  end if;
  perform public.registrar_accion('corte_caja', null, null, null, v_monto,
    jsonb_build_object('prestamo_cobrado', v_nombre));
end;
$$;

create or replace function public.caja_listar_prestamos(p_fecha date, p_es_prueba boolean default false)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public
as $$
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
    );
$$;

create or replace function public.caja_registrar_gasto(
  p_concepto text, p_monto numeric, p_fecha date, p_categoria text, p_es_prueba boolean default false
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_concepto text := nullif(trim(coalesce(p_concepto, '')), '');
  v_categoria text := lower(trim(coalesce(p_categoria, 'otro')));
  v_id uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para registrar gastos';
  end if;
  if v_concepto is null or p_monto <= 0 or p_monto > 100000 then
    raise exception 'Escribe el concepto y un monto válido';
  end if;
  if v_categoria not in ('insumos', 'servicios', 'limpieza', 'nomina', 'otro') then
    v_categoria := 'otro';
  end if;
  insert into public.caja_gastos(concepto, categoria, monto, fecha, es_prueba)
  values (v_concepto, v_categoria, p_monto, coalesce(p_fecha, (now() at time zone 'America/Monterrey')::date), coalesce(p_es_prueba, false))
  returning id into v_id;
  perform public.registrar_accion('corte_caja', null, null, null, p_monto,
    jsonb_build_object('gasto', v_concepto, 'categoria', v_categoria));
  return v_id;
end;
$$;

create or replace function public.caja_listar_gastos(p_fecha date, p_es_prueba boolean default false)
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id, 'concepto', g.concepto, 'categoria', g.categoria, 'monto', g.monto, 'fecha', g.fecha
  ) order by g.created_at desc), '[]'::jsonb)
  from public.caja_gastos g
  where g.fecha = p_fecha and g.es_prueba = coalesce(p_es_prueba, false);
$$;

create or replace function public.registrar_corte(
  p_fecha date, p_fondo numeric, p_contado numeric, p_notas text default null, p_es_prueba boolean default false
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_efectivo numeric;
  v_clip numeric;
  v_propina numeric;
  v_gastos numeric;
  v_prestamos numeric;
  v_cobrados numeric;
  v_esperado numeric;
  v_diff numeric;
  v_id uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para hacer corte';
  end if;
  if p_fondo < 0 or p_contado < 0 or p_fondo > 1000000 or p_contado > 1000000 then
    raise exception 'Montos de corte inválidos';
  end if;
  select
    coalesce(sum(c.efectivo), 0),
    coalesce(sum(c.clip), 0),
    coalesce(sum(c.propina_efectivo), 0)
  into v_efectivo, v_clip, v_propina
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.estado = 'pagada'
    and c.fecha_operativa = p_fecha
    and m.es_prueba = coalesce(p_es_prueba, false);
  v_efectivo := v_efectivo + coalesce((
    select sum(c.total) from public.cuentas c
    join public.mesas m on m.id = c.mesa_id
    where c.estado = 'pagada' and c.fecha_operativa = p_fecha
      and m.es_prueba = coalesce(p_es_prueba, false)
      and c.efectivo = 0 and c.clip = 0 and c.metodo_pago = 'efectivo'
  ), 0);
  v_clip := v_clip + coalesce((
    select sum(c.total) from public.cuentas c
    join public.mesas m on m.id = c.mesa_id
    where c.estado = 'pagada' and c.fecha_operativa = p_fecha
      and m.es_prueba = coalesce(p_es_prueba, false)
      and c.efectivo = 0 and c.clip = 0 and c.metodo_pago = 'clip'
  ), 0);
  select coalesce(sum(monto), 0) into v_gastos
  from public.caja_gastos
  where fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false);
  select coalesce(sum(monto), 0) into v_prestamos
  from public.caja_prestamos
  where fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false);
  select coalesce(sum(monto), 0) into v_cobrados
  from public.caja_prestamos
  where liquidado_fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false);
  v_esperado := p_fondo + v_efectivo + v_propina - v_gastos - v_prestamos + v_cobrados;
  v_diff := p_contado - v_esperado;
  insert into public.cortes_caja(
    fecha, fondo, efectivo_sistema, clip_sistema, propinas, efectivo_contado, diferencia, notas, es_prueba,
    gastos, prestamos, prestamos_cobrados
  ) values (
    p_fecha, p_fondo, v_efectivo, v_clip, v_propina, p_contado, v_diff,
    nullif(trim(coalesce(p_notas, '')), ''), p_es_prueba, v_gastos, v_prestamos, v_cobrados
  ) returning id into v_id;
  perform public.caja_guardar_fondo(p_fecha, p_fondo, p_es_prueba);
  perform public.registrar_accion(
    'corte_caja', null, null, null, v_diff,
    jsonb_build_object('fecha', p_fecha, 'fondo', p_fondo, 'contado', p_contado, 'esperado', v_esperado, 'es_prueba', p_es_prueba)
  );
  return jsonb_build_object(
    'id', v_id, 'efectivo', v_efectivo, 'clip', v_clip,
    'propina_efectivo', v_propina, 'gastos', v_gastos,
    'prestamos', v_prestamos, 'prestamos_cobrados', v_cobrados,
    'esperado', v_esperado, 'diferencia', v_diff
  );
end;
$$;

create or replace function public.listar_insumos()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id, 'nombre', i.nombre, 'unidad', i.unidad,
    'existencia', i.existencia, 'minimo', i.minimo, 'costo', i.costo,
    'bajo', i.existencia <= i.minimo, 'valor', round(i.existencia * i.costo, 2)
  ) order by i.nombre), '[]'::jsonb)
  from public.insumos i
  where i.activo;
$$;

create or replace function public.admin_guardar_insumo(
  p_nombre text, p_unidad text, p_minimo numeric, p_costo numeric, p_existencia numeric default null
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := nullif(trim(coalesce(p_nombre, '')), '');
  v_id uuid;
  v_unidad text := lower(trim(coalesce(p_unidad, 'kg')));
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración registra insumos';
  end if;
  if v_nombre is null then
    raise exception 'Escribe el nombre del insumo';
  end if;
  if v_unidad not in ('kg', 'g', 'pza', 'litro', 'ml', 'caja') then
    raise exception 'Unidad no reconocida';
  end if;
  insert into public.insumos(nombre, unidad, minimo, costo, existencia)
  values (v_nombre, v_unidad, greatest(coalesce(p_minimo, 0), 0), greatest(coalesce(p_costo, 0), 0), coalesce(p_existencia, 0))
  on conflict (nombre) do update
    set unidad = excluded.unidad,
        minimo = excluded.minimo,
        costo = excluded.costo,
        existencia = coalesce(p_existencia, public.insumos.existencia)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_movimiento_inventario(
  p_insumo uuid, p_tipo text, p_cantidad numeric, p_motivo text, p_costo numeric default null
)
returns numeric
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_actual numeric;
  v_nueva numeric;
  v_costo numeric;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración mueve inventario';
  end if;
  if p_tipo not in ('compra', 'merma', 'ajuste', 'salida') or p_cantidad is null then
    raise exception 'Movimiento inválido';
  end if;
  select existencia, costo into v_actual, v_costo
  from public.insumos where id = p_insumo and activo for update;
  if v_actual is null then
    raise exception 'Insumo no encontrado';
  end if;
  if p_tipo = 'ajuste' then
    v_nueva := p_cantidad;
  elsif p_tipo = 'compra' then
    if p_cantidad <= 0 then raise exception 'La compra tiene que ser mayor a cero'; end if;
    if p_costo is not null and p_costo >= 0 and (v_actual + p_cantidad) > 0 then
      v_costo := ((greatest(v_actual, 0) * v_costo) + (p_cantidad * p_costo)) / (greatest(v_actual, 0) + p_cantidad);
    end if;
    v_nueva := v_actual + p_cantidad;
  else
    if p_cantidad <= 0 then raise exception 'La cantidad tiene que ser mayor a cero'; end if;
    v_nueva := v_actual - p_cantidad;
  end if;
  update public.insumos set existencia = v_nueva, costo = coalesce(v_costo, costo) where id = p_insumo;
  insert into public.inventario_movimientos(insumo_id, tipo, cantidad, existencia_despues, costo, motivo)
  values (p_insumo, p_tipo, case when p_tipo in ('merma', 'salida') then -p_cantidad else p_cantidad end, v_nueva, p_costo, nullif(trim(coalesce(p_motivo, '')), ''));
  perform public.registrar_accion('editar_producto', null, null, null, v_nueva,
    jsonb_build_object('insumo', p_insumo, 'tipo', p_tipo, 'cantidad', p_cantidad, 'motivo', p_motivo));
  return v_nueva;
end;
$$;

create or replace function public.admin_guardar_receta(p_producto text, p_insumo uuid, p_cantidad numeric)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración arma recetas';
  end if;
  if coalesce(p_cantidad, 0) <= 0 then
    delete from public.recetas where producto_id = p_producto and insumo_id = p_insumo;
    return;
  end if;
  insert into public.recetas(producto_id, insumo_id, cantidad)
  values (p_producto, p_insumo, p_cantidad)
  on conflict (producto_id, insumo_id) do update set cantidad = excluded.cantidad;
end;
$$;

create or replace function public.listar_recetas()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public
as $$
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
  join public.insumos i on i.id = r.insumo_id;
$$;

create or replace function public.listar_movimientos()
returns jsonb
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select coalesce(jsonb_agg(row_to_json(m)), '[]'::jsonb)
  from (
    select mv.tipo, mv.cantidad, mv.existencia_despues, mv.motivo, mv.created_at, i.nombre as insumo, i.unidad
    from public.inventario_movimientos mv
    left join public.insumos i on i.id = mv.insumo_id
    order by mv.created_at desc
    limit 40
  ) m;
$$;

create or replace function public.listar_inventario()
returns table (producto_id text, nombre text, existencia numeric, minimo numeric, unidad text, activo boolean)
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select p.id, p.nombre,
    case
      when exists (select 1 from public.recetas r where r.producto_id = p.id)
        then (
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
$$;

create or replace function public.aplicar_consumo_receta()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_delta numeric := 0;
  v_producto text;
begin
  if tg_op = 'INSERT' then
    perform public.descontar_producto(new.producto_id, new.cantidad);
  elsif tg_op = 'DELETE' then
    perform public.descontar_producto(old.producto_id, -old.cantidad);
  elsif new.producto_id is distinct from old.producto_id then
    perform public.descontar_producto(old.producto_id, -old.cantidad);
    perform public.descontar_producto(new.producto_id, new.cantidad);
  elsif new.cantidad is distinct from old.cantidad then
    perform public.descontar_producto(new.producto_id, new.cantidad - old.cantidad);
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function public.descontar_producto(p_producto text, p_delta numeric)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if p_delta = 0 or p_producto is null then
    return;
  end if;
  if exists (select 1 from public.recetas r where r.producto_id = p_producto) then
    update public.insumos i
    set existencia = i.existencia - (p_delta * r.cantidad)
    from public.recetas r
    where r.producto_id = p_producto and r.insumo_id = i.id;
    insert into public.inventario_movimientos(insumo_id, producto_id, tipo, cantidad, existencia_despues, motivo)
    select r.insumo_id, p_producto, 'venta', -(p_delta * r.cantidad), i.existencia, 'Venta de platillo'
    from public.recetas r
    join public.insumos i on i.id = r.insumo_id
    where r.producto_id = p_producto;
  else
    update public.inventario
    set existencia = existencia - p_delta, actualizado_at = now()
    where producto_id = p_producto and existencia is not null;
  end if;
end;
$$;

drop trigger if exists consumir_receta_al_vender on public.comanda_items;
create trigger consumir_receta_al_vender
after insert or update or delete on public.comanda_items
for each row execute function public.aplicar_consumo_receta();

revoke all on function public.caja_fondo_del_dia(date, boolean) from public, anon, authenticated;
revoke all on function public.caja_guardar_fondo(date, numeric, boolean) from public, anon, authenticated;
revoke all on function public.caja_listar_empleados() from public, anon, authenticated;
revoke all on function public.caja_registrar_prestamo(uuid, numeric, date, text, boolean) from public, anon, authenticated;
revoke all on function public.caja_liquidar_prestamo(uuid, date) from public, anon, authenticated;
revoke all on function public.caja_listar_prestamos(date, boolean) from public, anon, authenticated;
revoke all on function public.caja_registrar_gasto(text, numeric, date, text, boolean) from public, anon, authenticated;
revoke all on function public.caja_listar_gastos(date, boolean) from public, anon, authenticated;
revoke all on function public.listar_insumos() from public, anon, authenticated;
revoke all on function public.admin_guardar_insumo(text, text, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.admin_movimiento_inventario(uuid, text, numeric, text, numeric) from public, anon, authenticated;
revoke all on function public.admin_guardar_receta(text, uuid, numeric) from public, anon, authenticated;
revoke all on function public.listar_recetas() from public, anon, authenticated;
revoke all on function public.listar_movimientos() from public, anon, authenticated;
grant execute on function public.caja_fondo_del_dia(date, boolean) to authenticated;
grant execute on function public.caja_guardar_fondo(date, numeric, boolean) to authenticated;
grant execute on function public.caja_listar_empleados() to authenticated;
grant execute on function public.caja_registrar_prestamo(uuid, numeric, date, text, boolean) to authenticated;
grant execute on function public.caja_liquidar_prestamo(uuid, date) to authenticated;
grant execute on function public.caja_listar_prestamos(date, boolean) to authenticated;
grant execute on function public.caja_registrar_gasto(text, numeric, date, text, boolean) to authenticated;
grant execute on function public.caja_listar_gastos(date, boolean) to authenticated;
grant execute on function public.listar_insumos() to authenticated;
grant execute on function public.admin_guardar_insumo(text, text, numeric, numeric, numeric) to authenticated;
grant execute on function public.admin_movimiento_inventario(uuid, text, numeric, text, numeric) to authenticated;
grant execute on function public.admin_guardar_receta(text, uuid, numeric) to authenticated;
grant execute on function public.listar_recetas() to authenticated;
grant execute on function public.listar_movimientos() to authenticated;

commit;
