begin;

-- ---------------------------------------------------------------------------
-- Promociones y combos: productos del catálogo con categoría propia
-- ---------------------------------------------------------------------------
alter table public.catalogo_productos add column if not exists descripcion text;

do $$
declare
  v_constraint text;
begin
  for v_constraint in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.catalogo_productos'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%categoria%'
  loop
    execute format('alter table public.catalogo_productos drop constraint %I', v_constraint);
  end loop;
end;
$$;
alter table public.catalogo_productos add constraint catalogo_productos_categoria_check
  check (categoria in (
    'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
    'Tortas', 'Postres', 'Bebidas', 'Promociones'
  ));

drop function if exists public.listar_catalogo_pos();
create function public.listar_catalogo_pos()
returns table (
  id text, nombre text, categoria text, precio numeric,
  permite_mezcla boolean, extra_tripa_principal numeric,
  permite_queso boolean, extra_queso numeric, descripcion text
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
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
  order by p.categoria, p.nombre;
end;
$$;

drop function if exists public.admin_listar_catalogo();
create function public.admin_listar_catalogo()
returns table (
  id text, nombre text, categoria text, precio numeric, activo boolean,
  permite_mezcla boolean, permite_queso boolean, descripcion text
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
         p.permite_mezcla, p.permite_queso, p.descripcion
  from public.catalogo_productos p
  order by p.categoria, p.nombre;
end;
$$;

create or replace function public.admin_guardar_promocion(
  p_id text, p_nombre text, p_precio numeric, p_descripcion text, p_activo boolean
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
  if v_id is null then
    v_id := 'promo-' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  elsif v_id !~ '^promo-[a-z0-9-]{2,58}$'
        or not exists (select 1 from public.catalogo_productos p where p.id = v_id and p.categoria = 'Promociones') then
    raise exception 'Promoción no encontrada';
  end if;
  insert into public.catalogo_productos(id, nombre, categoria, precio, activo, descripcion)
  values (v_id, v_nombre, 'Promociones', p_precio, coalesce(p_activo, true), v_desc)
  on conflict (id) do update
  set nombre = excluded.nombre, precio = excluded.precio, activo = excluded.activo,
      descripcion = excluded.descripcion, updated_at = now();
  perform public.registrar_accion(
    'editar_producto', null, null, null, p_precio,
    jsonb_build_object('producto_id', v_id, 'nombre', v_nombre, 'promocion', true, 'activo', p_activo)
  );
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Descuentos por artículo o por cuenta (solo administración)
-- ---------------------------------------------------------------------------
alter table public.comanda_items
  add column if not exists descuento_tipo text check (descuento_tipo in ('monto', 'porcentaje')),
  add column if not exists descuento_valor numeric(10, 2) check (descuento_valor >= 0);
alter table public.cuentas
  add column if not exists descuento_tipo text check (descuento_tipo in ('monto', 'porcentaje')),
  add column if not exists descuento_valor numeric(10, 2) check (descuento_valor >= 0),
  add column if not exists descuento_total numeric(10, 2) not null default 0;

alter table public.audit_acciones drop constraint audit_acciones_accion_check;
alter table public.audit_acciones add constraint audit_acciones_accion_check
  check (accion in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta', 'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
    'aplicar_descuento', 'quitar_descuento'
  ));

create or replace function public.calcular_descuento(p_base numeric, p_tipo text, p_valor numeric)
returns numeric
language sql immutable
as $$
  select case
    when p_tipo is null or p_valor is null then 0
    when p_tipo = 'porcentaje' then round(greatest(p_base, 0) * least(p_valor, 100) / 100, 2)
    else least(p_valor, greatest(p_base, 0))
  end
$$;

create or replace function public.cuenta_subtotal_neto(p_cuenta uuid)
returns numeric
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select coalesce(sum(
    greatest(i.cantidad * i.precio_unitario
      - public.calcular_descuento(i.cantidad * i.precio_unitario, i.descuento_tipo, i.descuento_valor), 0)
  ), 0)
  from public.comanda_items i
  join public.comandas c on c.id = i.comanda_id
  where c.cuenta_id = p_cuenta
$$;

create or replace function public.cuenta_total(p_cuenta uuid)
returns numeric
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select n.neto - public.calcular_descuento(n.neto, cu.descuento_tipo, cu.descuento_valor)
  from public.cuentas cu
  cross join lateral (select public.cuenta_subtotal_neto(cu.id) as neto) n
  where cu.id = p_cuenta
$$;

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
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
    'aplicar_descuento', 'quitar_descuento'
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

create or replace function public.admin_aplicar_descuento(
  p_cuenta uuid, p_item uuid, p_tipo text, p_valor numeric, p_motivo text default null
)
returns numeric
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_base numeric;
  v_nombre text;
  v_quitar boolean := p_tipo is null or coalesce(p_valor, 0) = 0;
  v_monto numeric := 0;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede aplicar descuentos';
  end if;
  if not v_quitar then
    if p_tipo not in ('monto', 'porcentaje') or p_valor < 0
       or (p_tipo = 'porcentaje' and p_valor > 100) or p_valor > 100000 then
      raise exception 'Descuento inválido';
    end if;
  end if;
  if char_length(coalesce(v_motivo, '')) > 200 then
    raise exception 'El motivo es demasiado largo';
  end if;
  select c.mesa_id into v_mesa
  from public.cuentas c
  where c.id = p_cuenta and c.estado in ('abierta', 'por_cobrar')
  for update;
  if v_mesa is null then raise exception 'La cuenta ya no está abierta'; end if;

  if p_item is not null then
    select i.cantidad * i.precio_unitario, i.nombre into v_base, v_nombre
    from public.comanda_items i join public.comandas co on co.id = i.comanda_id
    where i.id = p_item and co.cuenta_id = p_cuenta
    for update of i;
    if v_base is null then raise exception 'Artículo no encontrado en la cuenta'; end if;
    if not v_quitar then
      if p_tipo = 'monto' and p_valor > v_base then
        raise exception 'El descuento supera el importe del artículo';
      end if;
      v_monto := public.calcular_descuento(v_base, p_tipo, p_valor);
    end if;
    update public.comanda_items
    set descuento_tipo = case when v_quitar then null else p_tipo end,
        descuento_valor = case when v_quitar then null else p_valor end
    where id = p_item;
  else
    v_base := public.cuenta_subtotal_neto(p_cuenta);
    if not v_quitar then
      if p_tipo = 'monto' and p_valor > v_base then
        raise exception 'El descuento supera el total de la cuenta';
      end if;
      v_monto := public.calcular_descuento(v_base, p_tipo, p_valor);
    end if;
    update public.cuentas
    set descuento_tipo = case when v_quitar then null else p_tipo end,
        descuento_valor = case when v_quitar then null else p_valor end
    where id = p_cuenta;
  end if;

  perform public.registrar_accion(
    case when v_quitar then 'quitar_descuento' else 'aplicar_descuento' end,
    v_mesa, p_cuenta, null, v_monto,
    jsonb_build_object(
      'alcance', case when p_item is null then 'cuenta' else 'articulo' end,
      'articulo', v_nombre, 'tipo', p_tipo, 'valor', p_valor, 'motivo', v_motivo
    )
  );
  return public.cuenta_total(p_cuenta);
end;
$$;

create or replace function public.cobrar_cuenta(
  p_cuenta uuid,
  p_metodo text,
  p_es_prueba boolean default false
)
returns numeric
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_total numeric;
  v_bruto numeric;
  v_mesa uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para cobrar cuentas';
  end if;
  if p_metodo not in ('efectivo', 'clip') then
    raise exception 'Método de pago inválido';
  end if;

  select c.mesa_id into v_mesa
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta
    and c.estado in ('abierta', 'por_cobrar')
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_mesa is null then
    raise exception 'Cuenta no disponible para cobro en el modo seleccionado';
  end if;

  v_total := public.cuenta_total(p_cuenta);
  select coalesce(sum(i.cantidad * i.precio_unitario), 0) into v_bruto
  from public.comanda_items i
  join public.comandas c on c.id = i.comanda_id
  where c.cuenta_id = p_cuenta;
  update public.cuentas
  set estado = 'pagada', metodo_pago = p_metodo, total = v_total,
      descuento_total = greatest(v_bruto - v_total, 0),
      cerrada_at = now(),
      fecha_operativa = (now() at time zone 'America/Monterrey')::date
  where id = p_cuenta;
  update public.mesas set estado = 'disponible' where id = v_mesa;

  perform public.registrar_accion(
    'cobrar_cuenta', v_mesa, p_cuenta, null, v_total,
    jsonb_build_object(
      'metodo_pago', p_metodo,
      'descuento', greatest(v_bruto - v_total, 0),
      'es_prueba', coalesce(p_es_prueba, false)
    )
  );
  return v_total;
end;
$$;

create or replace function public.admin_listar_cuentas_abiertas(p_es_prueba boolean default false)
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar cuentas';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'mesa_id', m.id, 'mesa', m.nombre, 'estado', c.estado,
      'descuento_tipo', c.descuento_tipo, 'descuento_valor', c.descuento_valor,
      'total', public.cuenta_total(c.id),
      'comandas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', co.id, 'numero', co.numero, 'mesero', co.mesero,
          'items', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', i.id, 'producto_id', i.producto_id, 'nombre', i.nombre,
              'cantidad', i.cantidad, 'precio', i.precio_unitario,
              'modificadores', i.modificadores,
              'descuento_tipo', i.descuento_tipo, 'descuento_valor', i.descuento_valor
            ) order by i.id)
            from public.comanda_items i where i.comanda_id = co.id
          ), '[]'::jsonb)
        ) order by co.created_at)
        from public.comandas co where co.cuenta_id = c.id
      ), '[]'::jsonb)
    ) order by m.orden, m.nombre)
    from public.cuentas c join public.mesas m on m.id = c.mesa_id
    where c.estado in ('abierta', 'por_cobrar')
      and m.es_prueba = coalesce(p_es_prueba, false)
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Productos más vendidos (cuentas pagadas)
-- ---------------------------------------------------------------------------
create or replace function public.admin_productos_vendidos(
  p_desde date default null, p_hasta date default null, p_es_prueba boolean default false
)
returns table (nombre text, cantidad bigint, importe numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar ventas';
  end if;
  return query
  select i.nombre, sum(i.cantidad)::bigint,
         sum(greatest(i.cantidad * i.precio_unitario
           - public.calcular_descuento(i.cantidad * i.precio_unitario, i.descuento_tipo, i.descuento_valor), 0))
  from public.comanda_items i
  join public.comandas co on co.id = i.comanda_id
  join public.cuentas c on c.id = co.cuenta_id
  join public.mesas m on m.id = c.mesa_id
  where c.estado = 'pagada'
    and m.es_prueba = coalesce(p_es_prueba, false)
    and c.fecha_operativa between coalesce(p_desde, date '2000-01-01') and coalesce(p_hasta, date '2999-12-31')
  group by i.nombre
  order by sum(i.cantidad) desc, i.nombre
  limit 20;
end;
$$;

revoke all on function public.calcular_descuento(numeric, text, numeric) from public, anon, authenticated;
revoke all on function public.cuenta_subtotal_neto(uuid) from public, anon, authenticated;
revoke all on function public.cuenta_total(uuid) from public, anon, authenticated;
revoke all on function public.listar_catalogo_pos() from public, anon, authenticated;
revoke all on function public.admin_listar_catalogo() from public, anon, authenticated;
revoke all on function public.admin_guardar_promocion(text, text, numeric, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_aplicar_descuento(uuid, uuid, text, numeric, text) from public, anon, authenticated;
revoke all on function public.admin_productos_vendidos(date, date, boolean) from public, anon, authenticated;
revoke all on function public.registrar_accion(text, uuid, uuid, uuid, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.listar_catalogo_pos() to authenticated;
grant execute on function public.admin_listar_catalogo() to authenticated;
grant execute on function public.admin_guardar_promocion(text, text, numeric, text, boolean) to authenticated;
grant execute on function public.admin_aplicar_descuento(uuid, uuid, text, numeric, text) to authenticated;
grant execute on function public.admin_productos_vendidos(date, date, boolean) to authenticated;

commit;
