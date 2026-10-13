begin;

-- Quita cualquier producto de barra. No hay barista.
delete from public.catalogo_productos p
where (p.categoria ilike '%barra%' or p.nombre ilike '%barista%' or p.nombre ilike '%barra%')
  and not exists (select 1 from public.comanda_items i where i.producto_id = p.id);
update public.catalogo_productos
set activo = false
where categoria ilike '%barra%' or nombre ilike '%barista%' or nombre ilike '%barra%';

create table if not exists public.inventario (
  producto_id text primary key references public.catalogo_productos(id) on delete cascade,
  existencia numeric(12, 2),
  minimo numeric(12, 2) not null default 0,
  unidad text not null default 'pza',
  actualizado_at timestamptz not null default now()
);
alter table public.inventario enable row level security;

create table if not exists public.facturas (
  id uuid primary key default gen_random_uuid(),
  folio text not null unique,
  cuenta_id uuid references public.cuentas(id) on delete set null,
  receptor text not null,
  rfc text,
  total numeric(12, 2) not null,
  detalle jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.facturas enable row level security;

create or replace function public.listar_meseros_turno()
returns table (user_id uuid, nombre text)
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select a.user_id, coalesce(e.nombre, s.device_label, 'Mesero')
  from public.asistencias a
  join public.empleados e on e.id = a.empleado_id
  join public.staff_roles sr on sr.user_id = a.user_id and sr.role = 'mesero'
  left join public.solicitudes_puesto s on s.user_id = a.user_id
  where a.salida_at is null
    and e.activo
    and e.puesto = 'mesero';
$$;

create or replace function public.pasar_mesa(
  p_mesa uuid, p_destino uuid, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid := auth.uid();
  v_owner uuid;
  v_nombre text;
begin
  if not public.tiene_rol(array['mesero', 'admin']::text[]) then
    raise exception 'No autorizado para pasar la mesa';
  end if;
  if p_destino = v_user then
    raise exception 'La mesa ya está en este aparato';
  end if;
  if not exists (select 1 from public.listar_meseros_turno() m where m.user_id = p_destino) then
    raise exception 'Ese mesero no está en turno';
  end if;
  select r.user_id into v_owner from public.mesa_responsables r where r.mesa_id = p_mesa for update;
  if v_owner is null then
    raise exception 'La mesa no tiene responsable';
  end if;
  if public.tiene_rol(array['mesero']::text[]) and v_owner is distinct from v_user
     and not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo quien tiene la mesa puede pasarla';
  end if;
  select nombre into v_nombre from public.listar_meseros_turno() where user_id = p_destino;
  update public.mesa_responsables
  set user_id = p_destino, device_label = v_nombre
  where mesa_id = p_mesa;
  perform public.registrar_accion(
    'mover_mesa', p_mesa, null, null, null,
    jsonb_build_object('destino', v_nombre, 'es_prueba', p_es_prueba)
  );
end;
$$;

create or replace function public.mesero_corregir_articulo(
  p_item uuid, p_cantidad integer, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_user uuid := auth.uid();
  v_mesa uuid;
  v_cuenta uuid;
  v_owner uuid;
  v_comanda uuid;
begin
  if not public.tiene_rol(array['mesero', 'caja', 'admin']::text[]) then
    raise exception 'No autorizado para corregir la comanda';
  end if;
  if p_cantidad < 0 or p_cantidad > 99 then
    raise exception 'Cantidad inválida';
  end if;
  select co.mesa_id, co.cuenta_id, co.id into v_mesa, v_cuenta, v_comanda
  from public.comanda_items i
  join public.comandas co on co.id = i.comanda_id
  join public.cuentas c on c.id = co.cuenta_id
  join public.mesas m on m.id = co.mesa_id
  where i.id = p_item
    and c.estado in ('abierta', 'por_cobrar')
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of i;
  if v_mesa is null then
    raise exception 'Ese artículo ya no se puede corregir';
  end if;
  select r.user_id into v_owner from public.mesa_responsables r where r.mesa_id = v_mesa;
  if public.tiene_rol(array['mesero']::text[])
     and not public.tiene_rol(array['caja', 'admin']::text[])
     and v_owner is distinct from v_user then
    raise exception 'Solo quien tiene la mesa puede corregir lo enviado';
  end if;
  if p_cantidad = 0 then
    delete from public.comanda_items where id = p_item;
  else
    update public.comanda_items set cantidad = p_cantidad where id = p_item;
  end if;
  delete from public.comandas co
  where co.id = v_comanda
    and not exists (select 1 from public.comanda_items i where i.comanda_id = co.id);
  perform public.refrescar_estado_mesa(v_mesa);
  perform public.registrar_accion(
    'editar_comanda', v_mesa, v_cuenta, v_comanda, null,
    jsonb_build_object('item', p_item, 'cantidad', p_cantidad)
  );
end;
$$;

create or replace function public.cocina_rechazar_articulo(
  p_item uuid, p_motivo text, p_agotar boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_cuenta uuid;
  v_producto text;
  v_nombre text;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.tiene_rol(array['cocina', 'admin']::text[]) then
    raise exception 'Solo cocina puede rechazar un platillo';
  end if;
  if v_motivo is null then
    raise exception 'Escribe el motivo';
  end if;
  select co.mesa_id, co.cuenta_id, i.producto_id, i.nombre
    into v_mesa, v_cuenta, v_producto, v_nombre
  from public.comanda_items i
  join public.comandas co on co.id = i.comanda_id
  where i.id = p_item
  for update of i;
  if v_mesa is null then
    raise exception 'El platillo ya no está en cocina';
  end if;
  delete from public.comanda_items where id = p_item;
  if p_agotar and v_producto is not null then
    update public.catalogo_productos set activo = false where id = v_producto;
    insert into public.inventario(producto_id, existencia, actualizado_at)
    values (v_producto, 0, now())
    on conflict (producto_id) do update
      set existencia = 0, actualizado_at = now();
  end if;
  perform public.refrescar_estado_mesa(v_mesa);
  perform public.registrar_accion(
    'editar_comanda', v_mesa, v_cuenta, null, null,
    jsonb_build_object('rechazo', v_nombre, 'motivo', v_motivo, 'agotado', coalesce(p_agotar, false))
  );
end;
$$;

create or replace function public.caja_agregar_articulo(
  p_cuenta uuid, p_producto text, p_cantidad integer,
  p_notas text default null, p_modificadores jsonb default '[]'::jsonb,
  p_es_prueba boolean default false
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_nombre text;
  v_precio numeric;
  v_comanda uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'Solo caja puede agregar un producto olvidado';
  end if;
  if p_cantidad < 1 or p_cantidad > 99 then
    raise exception 'Cantidad inválida';
  end if;
  select c.mesa_id into v_mesa
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta
    and c.estado in ('abierta', 'por_cobrar')
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_mesa is null then
    raise exception 'La cuenta ya no está abierta';
  end if;
  select p.nombre, p.precio into v_nombre, v_precio
  from public.catalogo_productos p
  where p.id = p_producto and p.activo
    and p.categoria not ilike '%barra%';
  if v_nombre is null then
    raise exception 'Ese producto no está disponible';
  end if;
  insert into public.comandas(cuenta_id, mesa_id, client_token, estado, mesero)
  values (p_cuenta, v_mesa, 'caja-' || gen_random_uuid()::text, 'pendiente', 'Caja')
  returning id into v_comanda;
  insert into public.comanda_items(
    comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas
  ) values (
    v_comanda, p_producto, v_nombre, p_cantidad, v_precio,
    coalesce(p_modificadores, '[]'::jsonb), nullif(trim(coalesce(p_notas, '')), '')
  );
  update public.inventario
  set existencia = greatest(existencia - p_cantidad, 0), actualizado_at = now()
  where producto_id = p_producto and existencia is not null;
  update public.mesas set estado = 'ocupada' where id = v_mesa;
  perform public.registrar_accion(
    'editar_comanda', v_mesa, p_cuenta, v_comanda, p_cantidad * v_precio,
    jsonb_build_object('agregado', v_nombre, 'cantidad', p_cantidad, 'origen', 'caja')
  );
  return v_comanda;
end;
$$;

create or replace function public.listar_inventario()
returns table (producto_id text, nombre text, existencia numeric, minimo numeric, unidad text, activo boolean)
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select p.id, p.nombre, i.existencia, coalesce(i.minimo, 0), coalesce(i.unidad, 'pza'), p.activo
  from public.catalogo_productos p
  left join public.inventario i on i.producto_id = p.id
  where p.categoria not ilike '%barra%'
    and p.nombre not ilike '%barista%'
  order by p.categoria, p.nombre;
$$;

create or replace function public.admin_guardar_inventario(
  p_producto text, p_existencia numeric, p_minimo numeric default 0, p_unidad text default 'pza'
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración controla el inventario';
  end if;
  if p_existencia < 0 or coalesce(p_minimo, 0) < 0 then
    raise exception 'La existencia no puede ser negativa';
  end if;
  insert into public.inventario(producto_id, existencia, minimo, unidad, actualizado_at)
  values (p_producto, p_existencia, coalesce(p_minimo, 0), coalesce(nullif(trim(p_unidad), ''), 'pza'), now())
  on conflict (producto_id) do update
    set existencia = excluded.existencia,
        minimo = excluded.minimo,
        unidad = excluded.unidad,
        actualizado_at = now();
  if p_existencia = 0 then
    update public.catalogo_productos set activo = false where id = p_producto;
  end if;
  perform public.registrar_accion(
    'editar_producto', null, null, null, p_existencia,
    jsonb_build_object('inventario', p_producto, 'existencia', p_existencia)
  );
end;
$$;

create sequence if not exists public.folio_factura;

create or replace function public.crear_factura(
  p_cuenta uuid, p_receptor text, p_rfc text default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_total numeric;
  v_mesa text;
  v_folio text;
  v_id uuid;
  v_detalle jsonb;
  v_receptor text := nullif(trim(coalesce(p_receptor, '')), '');
begin
  if not public.tiene_rol(array['admin', 'caja']::text[]) then
    raise exception 'No autorizado para emitir la nota';
  end if;
  if v_receptor is null then
    raise exception 'Escribe el nombre de quien recibe la nota';
  end if;
  select public.cuenta_total(c.id), m.nombre into v_total, v_mesa
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta;
  if v_mesa is null then
    raise exception 'Cuenta no encontrada';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'nombre', i.nombre, 'cantidad', i.cantidad, 'precio', i.precio_unitario
  )), '[]'::jsonb) into v_detalle
  from public.comanda_items i
  join public.comandas co on co.id = i.comanda_id
  where co.cuenta_id = p_cuenta;
  v_folio := 'F' || to_char(now() at time zone 'America/Monterrey', 'YYMMDD') || '-' || lpad(nextval('public.folio_factura')::text, 4, '0');
  insert into public.facturas(folio, cuenta_id, receptor, rfc, total, detalle)
  values (v_folio, p_cuenta, v_receptor, nullif(upper(trim(coalesce(p_rfc, ''))), ''), coalesce(v_total, 0),
          jsonb_build_object('mesa', v_mesa, 'items', v_detalle))
  returning id into v_id;
  perform public.registrar_accion(
    'editar_comanda', null, p_cuenta, null, v_total,
    jsonb_build_object('factura', v_folio, 'receptor', v_receptor)
  );
  return jsonb_build_object('id', v_id, 'folio', v_folio, 'total', v_total, 'mesa', v_mesa, 'items', v_detalle);
end;
$$;

revoke all on function public.listar_meseros_turno() from public, anon, authenticated;
revoke all on function public.pasar_mesa(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.mesero_corregir_articulo(uuid, integer, boolean) from public, anon, authenticated;
revoke all on function public.cocina_rechazar_articulo(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.caja_agregar_articulo(uuid, text, integer, text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.listar_inventario() from public, anon, authenticated;
revoke all on function public.admin_guardar_inventario(text, numeric, numeric, text) from public, anon, authenticated;
revoke all on function public.crear_factura(uuid, text, text) from public, anon, authenticated;
grant execute on function public.listar_meseros_turno() to authenticated;
grant execute on function public.pasar_mesa(uuid, uuid, boolean) to authenticated;
grant execute on function public.mesero_corregir_articulo(uuid, integer, boolean) to authenticated;
grant execute on function public.cocina_rechazar_articulo(uuid, text, boolean) to authenticated;
grant execute on function public.caja_agregar_articulo(uuid, text, integer, text, jsonb, boolean) to authenticated;
grant execute on function public.listar_inventario() to authenticated;
grant execute on function public.admin_guardar_inventario(text, numeric, numeric, text) to authenticated;
grant execute on function public.crear_factura(uuid, text, text) to authenticated;

commit;
