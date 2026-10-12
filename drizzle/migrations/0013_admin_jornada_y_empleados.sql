begin;

create extension if not exists pgcrypto with schema extensions;

create table public.catalogo_productos (
  id text primary key check (id ~ '^[a-z0-9-]{2,64}$'),
  nombre text not null check (char_length(trim(nombre)) between 1 and 100),
  categoria text not null check (categoria in (
    'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
    'Tortas', 'Postres y Bebidas'
  )),
  precio numeric(10, 2) not null check (precio between 0 and 100000),
  activo boolean not null default true,
  permite_mezcla boolean not null default false,
  extra_tripa_principal numeric(10, 2) not null default 0,
  permite_queso boolean not null default false,
  extra_queso numeric(10, 2) not null default 0,
  updated_at timestamptz not null default now()
);

insert into public.catalogo_productos
  (id, nombre, categoria, precio, permite_mezcla, extra_tripa_principal, permite_queso, extra_queso)
values
  ('taco-maiz', 'Taco maíz', 'Tacos', 40, true, 5, true, 5),
  ('taco-harina', 'Taco harina', 'Tacos', 42, true, 5, true, 5),
  ('quesadilla-maiz', 'Quesadilla maíz', 'Quesadillas', 65, true, 10, false, 0),
  ('quesadilla-harina', 'Quesadilla harina', 'Quesadillas', 95, true, 10, false, 0),
  ('vampiro', 'Vampiro', 'Especiales', 75, true, 10, false, 0),
  ('chorreada', 'Chorreada', 'Especiales', 80, true, 10, false, 0),
  ('costra', 'Costra de queso', 'Especiales', 100, false, 0, false, 0),
  ('gaonera', 'Gaonera', 'Especiales', 75, false, 0, false, 0),
  ('chilaca', 'Taco de Chile chilaca', 'Especiales', 80, false, 0, false, 0),
  ('papa-especial', 'Papa asada especial', 'Papas y Frijoles', 180, true, 10, false, 0),
  ('papa-sencilla', 'Papa sencilla', 'Papas y Frijoles', 130, false, 0, false, 0),
  ('charros-especiales', 'Charros especiales', 'Papas y Frijoles', 75, false, 0, false, 0),
  ('charros-sencillos', 'Charros sencillos', 'Papas y Frijoles', 55, false, 0, false, 0),
  ('torta', 'Torta', 'Tortas', 130, true, 10, false, 0),
  ('hamburguesa', 'Hamburguesa', 'Tortas', 125, false, 0, false, 0),
  ('quesagloria', 'Quesagloria', 'Postres y Bebidas', 100, false, 0, false, 0),
  ('agua-natural', 'Agua natural', 'Postres y Bebidas', 15, false, 0, false, 0),
  ('agua-sabor', 'Agua de sabor 1L', 'Postres y Bebidas', 45, false, 0, false, 0),
  ('horchata', 'Horchata y cebada 1L', 'Postres y Bebidas', 50, false, 0, false, 0),
  ('topo-chico', 'Topo Chico', 'Postres y Bebidas', 35, false, 0, false, 0),
  ('toni-col', 'ToniCol', 'Postres y Bebidas', 55, false, 0, false, 0)
on conflict (id) do nothing;

alter table public.catalogo_productos enable row level security;
revoke all on public.catalogo_productos from public, anon, authenticated;
grant select on public.catalogo_productos to authenticated;
create policy personal_consulta_catalogo_activo
  on public.catalogo_productos for select to authenticated
  using (
    activo and public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[])
  );

create table public.empleados (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (char_length(trim(nombre)) between 1 and 80),
  puesto text not null check (puesto in ('mesero', 'caja', 'cocina')),
  pin_hash text not null,
  activo boolean not null default true,
  creado_at timestamptz not null default now(),
  actualizado_at timestamptz not null default now()
);

create table public.asistencias (
  id uuid primary key default gen_random_uuid(),
  empleado_id uuid not null references public.empleados(id),
  user_id uuid not null references auth.users(id),
  puesto text not null check (puesto in ('mesero', 'caja', 'cocina')),
  entrada_at timestamptz not null default now(),
  salida_at timestamptz
);

create unique index asistencias_empleado_turno_abierto
  on public.asistencias(empleado_id) where salida_at is null;
create unique index asistencias_aparato_turno_abierto
  on public.asistencias(user_id) where salida_at is null;
create index asistencias_fecha_entrada_idx
  on public.asistencias(entrada_at desc);

alter table public.asistencias enable row level security;
alter table public.empleados enable row level security;
revoke all on public.asistencias, public.empleados from public, anon, authenticated;

alter table public.comandas add column mesero_id uuid references public.empleados(id) on delete set null;
alter table public.audit_acciones add column empleado_id uuid references public.empleados(id) on delete set null;
create index comandas_mesero_id_idx on public.comandas(mesero_id);

alter table public.audit_acciones drop constraint audit_acciones_accion_check;
alter table public.audit_acciones add constraint audit_acciones_accion_check
  check (accion in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta',
    'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado'
  ));

create table public.intentos_pin_empleado (
  user_id uuid primary key references auth.users(id) on delete cascade,
  intentos integer not null default 0,
  bloqueado_hasta timestamptz
);
alter table public.intentos_pin_empleado enable row level security;
revoke all on public.intentos_pin_empleado from public, anon, authenticated;

create or replace function public.listar_catalogo_pos()
returns table (
  id text, nombre text, categoria text, precio numeric,
  permite_mezcla boolean, extra_tripa_principal numeric,
  permite_queso boolean, extra_queso numeric
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
         p.permite_mezcla, p.extra_tripa_principal, p.permite_queso, p.extra_queso
  from public.catalogo_productos p
  where p.activo
  order by p.categoria, p.nombre;
end;
$$;

create or replace function public.admin_listar_catalogo()
returns table (
  id text, nombre text, categoria text, precio numeric, activo boolean,
  permite_mezcla boolean, permite_queso boolean
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
         p.permite_mezcla, p.permite_queso
  from public.catalogo_productos p
  order by p.categoria, p.nombre;
end;
$$;

create or replace function public.validar_item_comanda(
  p_producto_id text, p_nombre text, p_precio numeric, p_modificadores jsonb
)
returns numeric
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_producto public.catalogo_productos%rowtype;
  v_precio numeric;
  v_principal text;
  v_principales integer;
  v_extras integer;
  v_queso integer;
  v_cantidad integer;
begin
  select * into v_producto
  from public.catalogo_productos
  where id = p_producto_id and activo;
  if not found or p_nombre is distinct from v_producto.nombre then
    raise exception 'Producto inválido o fuera del catálogo activo';
  end if;
  if p_modificadores is null or jsonb_typeof(p_modificadores) is distinct from 'array' then
    raise exception 'Modificadores inválidos';
  end if;

  v_cantidad := jsonb_array_length(p_modificadores);
  if v_cantidad > 0 and exists (
    select 1 from jsonb_array_elements_text(p_modificadores) m(value)
    where m.value not in ('Asada', 'Pastor', 'Tripa', '+ Asada', '+ Pastor', '+ Tripa', 'Con queso')
  ) then
    raise exception 'Modificador inválido';
  end if;
  if (select count(distinct m.value) from jsonb_array_elements_text(p_modificadores) m(value))
       <> v_cantidad then
    raise exception 'No se permiten modificadores duplicados';
  end if;

  v_precio := v_producto.precio;
  if v_producto.permite_mezcla then
    select count(*) filter (where m.value in ('Asada', 'Pastor', 'Tripa')),
           min(m.value) filter (where m.value in ('Asada', 'Pastor', 'Tripa')),
           count(*) filter (where m.value in ('+ Asada', '+ Pastor', '+ Tripa')),
           count(*) filter (where m.value = 'Con queso')
    into v_principales, v_principal, v_extras, v_queso
    from jsonb_array_elements_text(p_modificadores) m(value);

    if v_principales <> 1 then
      raise exception 'Selecciona exactamente una carne principal';
    end if;
    if exists (
      select 1 from jsonb_array_elements_text(p_modificadores) m(value)
      where m.value = '+ ' || v_principal
    ) then
      raise exception 'La carne principal no puede repetirse como extra';
    end if;
    if v_queso > 0 and not v_producto.permite_queso then
      raise exception 'Este producto no acepta queso extra';
    end if;
    if v_principal = 'Tripa' then
      v_precio := v_precio + v_producto.extra_tripa_principal;
    end if;
    v_precio := v_precio + (v_extras * 10) + (v_queso * v_producto.extra_queso);
  elsif v_cantidad > 0 then
    raise exception 'Este producto no acepta modificadores';
  end if;

  if p_precio is distinct from v_precio then
    raise exception 'El precio enviado no coincide con el catálogo vigente';
  end if;
  return v_precio;
end;
$$;

create or replace function public.admin_guardar_producto(
  p_id text, p_nombre text, p_categoria text, p_precio numeric, p_activo boolean
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar productos';
  end if;
  if coalesce(p_id, '') !~ '^[a-z0-9-]{2,64}$'
     or char_length(v_nombre) not between 1 and 100
     or p_categoria is null
     or p_categoria not in (
       'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
       'Tortas', 'Postres y Bebidas'
     )
     or p_precio is null or p_precio < 0 or p_precio > 100000 then
    raise exception 'Datos de producto inválidos';
  end if;
  insert into public.catalogo_productos(id, nombre, categoria, precio, activo)
  values (p_id, v_nombre, p_categoria, p_precio, coalesce(p_activo, true))
  on conflict (id) do update
  set nombre = excluded.nombre,
      categoria = excluded.categoria,
      precio = excluded.precio,
      activo = excluded.activo,
      updated_at = now();
  perform public.registrar_accion(
    'editar_producto', null, null, null, p_precio,
    jsonb_build_object('producto_id', p_id, 'nombre', v_nombre, 'activo', p_activo)
  );
end;
$$;

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
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar mesas';
  end if;
  if char_length(v_nombre) not between 1 and 80
     or p_orden is null or p_orden not between 0 and 999 then
    raise exception 'Nombre u orden de mesa inválidos';
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
    insert into public.mesas(nombre, orden, activa, es_prueba)
    values (v_nombre, p_orden, coalesce(p_activa, true), coalesce(p_es_prueba, false))
    returning id into v_id;
  else
    update public.mesas
    set nombre = v_nombre, orden = p_orden, activa = coalesce(p_activa, false)
    where id = p_id and es_prueba = coalesce(p_es_prueba, false);
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
    jsonb_build_object('nombre', v_nombre, 'orden', p_orden, 'activa', p_activa)
  );
  return v_id;
end;
$$;

create or replace function public.admin_guardar_empleado(
  p_id uuid, p_nombre text, p_puesto text, p_pin text, p_activo boolean
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_id uuid := p_id;
  v_nombre text := trim(coalesce(p_nombre, ''));
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar empleados';
  end if;
  if char_length(v_nombre) not between 1 and 80 or p_puesto is null
     or p_puesto not in ('mesero', 'caja', 'cocina') then
    raise exception 'Nombre o puesto de empleado inválido';
  end if;
  if p_id is null and coalesce(p_pin, '') !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN debe tener entre 4 y 8 dígitos';
  end if;
  if p_pin is not null and p_pin <> '' and p_pin !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN debe tener entre 4 y 8 dígitos';
  end if;
  if p_id is not null and coalesce(p_activo, false) and coalesce(p_pin, '') = ''
     and exists (select 1 from public.empleados e where e.id = p_id and not e.activo) then
    raise exception 'Asigna un PIN nuevo para reactivar al empleado';
  end if;
  if coalesce(p_pin, '') <> '' and exists (
    select 1 from public.empleados e
    where e.id is distinct from p_id and e.activo
      and crypt(p_pin, e.pin_hash) = e.pin_hash
  ) then
    raise exception 'Ese PIN ya está asignado a otro empleado activo';
  end if;

  if p_id is null then
    insert into public.empleados(nombre, puesto, pin_hash, activo)
    values (v_nombre, p_puesto, crypt(p_pin, gen_salt('bf', 10)), coalesce(p_activo, true))
    returning id into v_id;
  else
    update public.empleados
    set nombre = v_nombre, puesto = p_puesto, activo = coalesce(p_activo, false),
        pin_hash = case when coalesce(p_pin, '') = '' then pin_hash else crypt(p_pin, gen_salt('bf', 10)) end,
        actualizado_at = now()
    where id = p_id;
    if not found then raise exception 'Empleado no encontrado'; end if;
    if exists (
      select 1 from public.asistencias a
      where a.empleado_id = p_id and a.salida_at is null and a.puesto <> p_puesto
    ) then
      raise exception 'Registra la salida antes de cambiar el puesto del empleado';
    end if;
    if not coalesce(p_activo, false) and exists (
      select 1 from public.asistencias a where a.empleado_id = p_id and a.salida_at is null
    ) then
      raise exception 'Registra la salida del empleado antes de desactivarlo';
    end if;
  end if;
  perform public.registrar_accion(
    'editar_empleado', null, null, null, null,
    jsonb_build_object('empleado_id', v_id, 'nombre', v_nombre, 'puesto', p_puesto, 'activo', p_activo)
  );
  return v_id;
end;
$$;

create or replace function public.admin_listar_empleados()
returns table (
  id uuid, nombre text, puesto text, activo boolean,
  asistencia_id uuid, entrada_at timestamptz, user_id uuid
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar empleados';
  end if;
  return query
  select e.id, e.nombre, e.puesto, e.activo, a.id, a.entrada_at, a.user_id
  from public.empleados e
  left join public.asistencias a on a.empleado_id = e.id and a.salida_at is null
  order by e.activo desc, e.nombre;
end;
$$;

create or replace function public.admin_listar_asistencia(p_fecha date default null)
returns table (
  id uuid, empleado_id uuid, nombre text, puesto text,
  entrada_at timestamptz, salida_at timestamptz
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Monterrey')::date);
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar asistencia';
  end if;
  return query
  select a.id, e.id, e.nombre, a.puesto, a.entrada_at, a.salida_at
  from public.asistencias a join public.empleados e on e.id = a.empleado_id
  where (a.entrada_at at time zone 'America/Monterrey')::date = v_fecha
  order by a.entrada_at desc;
end;
$$;

create or replace function public.iniciar_turno_empleado(p_pin text)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_role text;
  v_employee public.empleados%rowtype;
  v_shift public.asistencias%rowtype;
  v_attempt public.intentos_pin_empleado%rowtype;
begin
  if v_user is null or not public.tiene_rol(array['mesero', 'caja', 'cocina']::text[]) then
    raise exception 'Se requiere un dispositivo autorizado';
  end if;
  select role into v_role from public.staff_roles where user_id = v_user;
  select * into v_attempt from public.intentos_pin_empleado where user_id = v_user for update;
  if v_attempt.bloqueado_hasta > now() then
    return jsonb_build_object(
      'ok', false,
      'error', 'Demasiados intentos. Espera unos minutos antes de volver a intentar'
    );
  end if;
  select * into v_employee from public.empleados
  where activo and crypt(coalesce(p_pin, ''), pin_hash) = pin_hash
  limit 1 for update;
  if not found or v_employee.puesto <> v_role then
    insert into public.intentos_pin_empleado as pin_attempt(user_id, intentos, bloqueado_hasta)
    values (v_user, 1, null)
    on conflict (user_id) do update
    set intentos = case when pin_attempt.bloqueado_hasta < now()
                         then 1 else pin_attempt.intentos + 1 end,
        bloqueado_hasta = case
          when pin_attempt.bloqueado_hasta < now() then null
          when pin_attempt.intentos >= 4 then now() + interval '10 minutes'
          else null
        end;
    return jsonb_build_object(
      'ok', false,
      'error', 'PIN incorrecto o no corresponde a este puesto'
    );
  end if;

  select * into v_shift from public.asistencias
  where empleado_id = v_employee.id and salida_at is null for update;
  if found and v_shift.user_id <> v_user then
    raise exception 'Este empleado ya tiene un turno abierto en otro dispositivo';
  elsif not found then
    if exists (select 1 from public.asistencias where user_id = v_user and salida_at is null) then
      raise exception 'Registra la salida del turno anterior en este dispositivo';
    end if;
    insert into public.asistencias(empleado_id, user_id, puesto)
    values (v_employee.id, v_user, v_employee.puesto)
    returning * into v_shift;
    insert into public.audit_acciones(
      user_id, device_label, role, accion, empleado_id, detalle
    )
    select v_user, coalesce(nullif(trim(sp.device_label), ''), 'Dispositivo'),
           v_role, 'entrada_empleado', v_employee.id,
           jsonb_build_object('empleado', v_employee.nombre)
    from public.solicitudes_puesto sp where sp.user_id = v_user;
  end if;
  delete from public.intentos_pin_empleado where user_id = v_user;
  return jsonb_build_object(
    'ok', true, 'id', v_employee.id, 'nombre', v_employee.nombre, 'puesto', v_employee.puesto,
    'asistencia_id', v_shift.id, 'entrada_at', v_shift.entrada_at
  );
end;
$$;

create or replace function public.turno_empleado_actual()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_row record;
begin
  if auth.uid() is null then raise exception 'Sesión requerida'; end if;
  select e.id, e.nombre, e.puesto, a.id as asistencia_id, a.entrada_at
  into v_row
  from public.asistencias a join public.empleados e on e.id = a.empleado_id
  where a.user_id = auth.uid() and a.salida_at is null and e.activo;
  if not found then return null; end if;
  return to_jsonb(v_row);
end;
$$;

create or replace function public.cerrar_turno_empleado()
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_shift public.asistencias%rowtype;
  v_employee public.empleados%rowtype;
  v_device text;
begin
  select * into v_shift from public.asistencias
  where user_id = auth.uid() and salida_at is null for update;
  if not found then raise exception 'No hay un turno abierto en este dispositivo'; end if;
  select * into v_employee from public.empleados where id = v_shift.empleado_id;
  select coalesce(nullif(trim(device_label), ''), 'Dispositivo') into v_device
  from public.solicitudes_puesto where user_id = auth.uid();
  insert into public.audit_acciones(user_id, device_label, role, accion, empleado_id, detalle)
  values (auth.uid(), coalesce(v_device, 'Dispositivo'), v_shift.puesto, 'salida_empleado',
          v_employee.id, jsonb_build_object('empleado', v_employee.nombre));
  update public.asistencias set salida_at = now() where id = v_shift.id;
end;
$$;

create or replace function public.admin_ventas_por_mesero(p_fecha date default null, p_es_prueba boolean default false)
returns table (empleado_id uuid, nombre text, cuentas bigint, venta numeric)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Monterrey')::date);
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar ventas por mesero';
  end if;
  return query
  select e.id, e.nombre, count(distinct case when m.id is not null then c.id end),
         coalesce(sum(i.cantidad * i.precio_unitario), 0)::numeric
  from public.empleados e
  left join public.comandas co on co.mesero_id = e.id
  left join public.cuentas c on c.id = co.cuenta_id
    and c.estado = 'pagada' and c.fecha_operativa = v_fecha
  left join public.mesas m on m.id = c.mesa_id and m.es_prueba = coalesce(p_es_prueba, false)
  left join public.comanda_items i on i.comanda_id = co.id and m.id is not null
  where e.puesto = 'mesero'
  group by e.id, e.nombre
  order by 4 desc, e.nombre;
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
      'comandas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', co.id, 'numero', co.numero, 'mesero', co.mesero,
          'items', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', i.id, 'producto_id', i.producto_id, 'nombre', i.nombre,
              'cantidad', i.cantidad, 'precio', i.precio_unitario,
              'modificadores', i.modificadores
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

create or replace function public.admin_editar_articulo_cuenta(
  p_cuenta uuid, p_item uuid, p_producto_id text, p_cantidad integer,
  p_modificadores jsonb, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_comanda uuid;
  v_mesa uuid;
  v_producto public.catalogo_productos%rowtype;
  v_precio numeric;
  v_item public.comanda_items%rowtype;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar cuentas';
  end if;
  select c.mesa_id into v_mesa
  from public.cuentas c join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta and c.estado in ('abierta', 'por_cobrar')
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_mesa is null then raise exception 'La cuenta ya no está abierta'; end if;

  if p_item is not null then
    select i.* into v_item
    from public.comanda_items i join public.comandas co on co.id = i.comanda_id
    where i.id = p_item and co.cuenta_id = p_cuenta for update of i;
    if not found then raise exception 'Artículo no encontrado en la cuenta'; end if;
    if p_cantidad = 0 then
      delete from public.comanda_items where id = p_item;
    elsif p_cantidad between 1 and 99 then
      update public.comanda_items
      set cantidad = p_cantidad
      where id = p_item;
    else
      raise exception 'Cantidad inválida';
    end if;
  else
    if p_cantidad not between 1 and 99 then raise exception 'Cantidad inválida'; end if;
    select * into v_producto from public.catalogo_productos
    where id = p_producto_id and activo;
    if not found then raise exception 'Producto inactivo o no disponible'; end if;
    v_precio := public.validar_item_comanda(
      v_producto.id, v_producto.nombre, v_producto.precio, coalesce(p_modificadores, '[]'::jsonb)
    );
    insert into public.comandas(cuenta_id, mesa_id, client_token, mesero)
    values (p_cuenta, v_mesa, gen_random_uuid()::text, 'Administración')
    returning id into v_comanda;
    insert into public.comanda_items(
      comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores
    ) values (
      v_comanda, v_producto.id, v_producto.nombre, p_cantidad, v_precio,
      coalesce(p_modificadores, '[]'::jsonb)
    );
  end if;
  perform public.registrar_accion(
    'editar_comanda', v_mesa, p_cuenta, null, null,
    jsonb_build_object('articulo_id', p_item, 'producto_id', p_producto_id, 'cantidad', p_cantidad)
  );
end;
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
  v_empleado_nombre text;
  v_detalle jsonb := coalesce(p_detalle, '{}'::jsonb);
begin
  if v_user_id is null then return; end if;
  if p_accion not in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta', 'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado'
  ) then raise exception 'Acción de auditoría inválida'; end if;
  select sr.role into v_role from public.staff_roles sr where sr.user_id = v_user_id;
  if v_role is null then return; end if;
  select a.empleado_id, e.nombre into v_empleado, v_empleado_nombre
  from public.asistencias a
  join public.empleados e on e.id = a.empleado_id
  where a.user_id = v_user_id and a.salida_at is null;
  if v_empleado_nombre is not null then
    v_detalle := v_detalle || jsonb_build_object('empleado', v_empleado_nombre);
  end if;
  v_label := coalesce(
    nullif(trim((select s.device_label from public.solicitudes_puesto s where s.user_id = v_user_id)), ''),
    case when v_role = 'admin' then 'Administración' end,
    nullif(auth.jwt()->>'email', ''),
    initcap(v_role) || ' ' || left(v_user_id::text, 8)
  );
  insert into public.audit_acciones(
    user_id, device_label, role, accion, empleado_id,
    mesa_id, cuenta_id, comanda_id, monto, detalle
  ) values (
    v_user_id, v_label, v_role, p_accion, v_empleado,
    p_mesa_id, p_cuenta_id, p_comanda_id, p_monto, v_detalle
  );
end;
$$;

create or replace function public.validar_turno_operativo()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_role text;
  v_employee public.empleados%rowtype;
begin
  select role into v_role from public.staff_roles where user_id = auth.uid();
  if v_role = 'admin' then return new; end if;
  select e.* into v_employee
  from public.asistencias a join public.empleados e on e.id = a.empleado_id
  where a.user_id = auth.uid() and a.salida_at is null and e.activo
  for update of a;
  if not found or v_employee.puesto <> v_role then
    raise exception 'Registra tu entrada con PIN antes de operar';
  end if;
  if tg_table_name = 'comandas' and tg_op = 'INSERT' then
    if v_role <> 'mesero' then raise exception 'Solo meseros pueden enviar comandas'; end if;
    new.mesero_id := v_employee.id;
  elsif tg_table_name = 'comandas' and tg_op = 'UPDATE' then
    if v_role <> 'cocina' then raise exception 'Solo cocina puede actualizar comandas'; end if;
  elsif tg_table_name = 'cuentas' then
    if new.estado = 'abierta' and v_role <> 'mesero' then
      raise exception 'Solo meseros pueden reabrir una cuenta para agregar artículos';
    elsif new.estado <> 'abierta' and v_role <> 'caja' then
      raise exception 'Solo caja puede solicitar, cobrar o anular cuentas';
    end if;
  elsif tg_table_name = 'mesa_responsables' and v_role <> 'mesero' then
    raise exception 'Solo meseros pueden asignarse mesas';
  end if;
  return new;
end;
$$;

create trigger comandas_turno_requerido
before insert or update of estado on public.comandas
for each row execute function public.validar_turno_operativo();
create trigger cuentas_turno_requerido
before update of estado on public.cuentas
for each row
execute function public.validar_turno_operativo();
create trigger mesa_responsables_turno_requerido
before insert on public.mesa_responsables
for each row execute function public.validar_turno_operativo();

revoke all on function public.listar_catalogo_pos() from public, anon, authenticated;
revoke all on function public.admin_listar_catalogo() from public, anon, authenticated;
revoke all on function public.admin_guardar_producto(text, text, text, numeric, boolean) from public, anon, authenticated;
revoke all on function public.admin_guardar_mesa(uuid, text, integer, boolean, boolean) from public, anon, authenticated;
revoke all on function public.admin_guardar_empleado(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_listar_empleados() from public, anon, authenticated;
revoke all on function public.admin_listar_asistencia(date) from public, anon, authenticated;
revoke all on function public.iniciar_turno_empleado(text) from public, anon, authenticated;
revoke all on function public.turno_empleado_actual() from public, anon, authenticated;
revoke all on function public.cerrar_turno_empleado() from public, anon, authenticated;
revoke all on function public.admin_ventas_por_mesero(date, boolean) from public, anon, authenticated;
revoke all on function public.admin_listar_cuentas_abiertas(boolean) from public, anon, authenticated;
revoke all on function public.admin_editar_articulo_cuenta(uuid, uuid, text, integer, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.registrar_accion(text, uuid, uuid, uuid, numeric, jsonb) from public, anon, authenticated;
revoke all on function public.validar_item_comanda(text, text, numeric, jsonb) from public, anon, authenticated;
revoke all on function public.validar_turno_operativo() from public, anon, authenticated;

grant execute on function public.listar_catalogo_pos() to authenticated;
grant execute on function public.admin_listar_catalogo() to authenticated;
grant execute on function public.admin_guardar_producto(text, text, text, numeric, boolean) to authenticated;
grant execute on function public.admin_guardar_mesa(uuid, text, integer, boolean, boolean) to authenticated;
grant execute on function public.admin_guardar_empleado(uuid, text, text, text, boolean) to authenticated;
grant execute on function public.admin_listar_empleados() to authenticated;
grant execute on function public.admin_listar_asistencia(date) to authenticated;
grant execute on function public.iniciar_turno_empleado(text) to authenticated;
grant execute on function public.turno_empleado_actual() to authenticated;
grant execute on function public.cerrar_turno_empleado() to authenticated;
grant execute on function public.admin_ventas_por_mesero(date, boolean) to authenticated;
grant execute on function public.admin_listar_cuentas_abiertas(boolean) to authenticated;
grant execute on function public.admin_editar_articulo_cuenta(uuid, uuid, text, integer, jsonb, boolean) to authenticated;

alter publication supabase_realtime add table public.catalogo_productos;

commit;
