begin;

alter table public.cuentas
  add column if not exists pagado numeric(10, 2) not null default 0,
  add column if not exists propina numeric(10, 2) not null default 0,
  add column if not exists efectivo numeric(10, 2) not null default 0,
  add column if not exists clip numeric(10, 2) not null default 0,
  add column if not exists propina_efectivo numeric(10, 2) not null default 0,
  add column if not exists propina_clip numeric(10, 2) not null default 0;

-- Una mesa puede tener más de una cuenta abierta (cuenta separada).
drop index if exists public.cuentas_una_abierta;

create table if not exists public.cortes_caja (
  id uuid primary key default gen_random_uuid(),
  fecha date not null,
  fondo numeric(10, 2) not null default 0,
  efectivo_sistema numeric(10, 2) not null default 0,
  clip_sistema numeric(10, 2) not null default 0,
  propinas numeric(10, 2) not null default 0,
  efectivo_contado numeric(10, 2) not null default 0,
  diferencia numeric(10, 2) not null default 0,
  notas text,
  es_prueba boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.cortes_caja enable row level security;

alter table public.audit_acciones drop constraint if exists audit_acciones_accion_check;
do $$
declare
  v_list text;
begin
  select string_agg(quote_literal(accion), ', ' order by accion)
  into v_list
  from (
    select distinct accion from public.audit_acciones
    union
    select unnest(array[
      'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
      'cobrar_cuenta', 'anular_cuenta', 'pago_parcial',
      'dividir_cuenta', 'mover_mesa', 'corte_caja',
      'entrada_empleado', 'salida_empleado',
      'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
      'aplicar_descuento', 'quitar_descuento',
      'cambio_nombre_admin', 'baja_empleado', 'eliminar_producto'
    ])
  ) acciones;
  execute format(
    'alter table public.audit_acciones add constraint audit_acciones_accion_check check (accion in (%s))',
    v_list
  );
end $$;

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
    'cobrar_cuenta', 'anular_cuenta', 'pago_parcial',
    'dividir_cuenta', 'mover_mesa', 'corte_caja',
    'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
    'aplicar_descuento', 'quitar_descuento',
    'cambio_nombre_admin', 'baja_empleado', 'eliminar_producto'
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

create or replace function public.refrescar_estado_mesa(p_mesa uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_abierta boolean;
  v_cobrar boolean;
begin
  select
    exists (select 1 from public.cuentas c where c.mesa_id = p_mesa and c.estado = 'abierta'),
    exists (select 1 from public.cuentas c where c.mesa_id = p_mesa and c.estado = 'por_cobrar')
  into v_abierta, v_cobrar;
  update public.mesas
  set estado = case
    when v_abierta then 'ocupada'
    when v_cobrar then 'por_cobrar'
    else 'disponible'
  end
  where id = p_mesa;
end;
$$;

-- Las comandas nuevas siguen cayendo en la cuenta abierta más vieja.
create or replace function public.enviar_comanda(
  p_mesa uuid, p_token text, p_items jsonb, p_mesero text default null, p_es_prueba boolean default false
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cuenta uuid;
  v_comanda uuid;
  v_comanda_es_prueba boolean;
  v_mesa_es_prueba boolean;
  v_owner uuid;
  v_precio numeric;
  v_subtotal numeric := 0;
  it jsonb;
begin
  if not public.tiene_rol(array['mesero', 'admin']::text[]) then
    raise exception 'No autorizado para enviar comandas';
  end if;
  if coalesce(trim(p_token), '') = ''
     or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Token e items válidos requeridos';
  end if;
  select m.es_prueba into v_mesa_es_prueba
  from public.mesas m where m.id = p_mesa and m.activa for update;
  if not found or v_mesa_es_prueba is distinct from coalesce(p_es_prueba, false) then
    raise exception 'La mesa no corresponde al modo de operación seleccionado';
  end if;
  select c.id, m.es_prueba into v_comanda, v_comanda_es_prueba
  from public.comandas c
  join public.mesas m on m.id = c.mesa_id
  where c.client_token = p_token;
  if v_comanda is not null then
    if v_comanda_es_prueba <> coalesce(p_es_prueba, false) then
      raise exception 'El token de comanda ya se usó en otro modo';
    end if;
    return v_comanda;
  end if;
  select r.user_id into v_owner from public.mesa_responsables r where r.mesa_id = p_mesa;
  if v_owner is distinct from v_user_id then
    raise exception 'Solo el responsable asignado puede enviar comandas a esta mesa';
  end if;
  select c.id into v_cuenta
  from public.cuentas c
  where c.mesa_id = p_mesa and c.estado in ('abierta', 'por_cobrar')
  order by c.abierta_at
  limit 1
  for update;
  if v_cuenta is null then
    insert into public.cuentas(mesa_id) values (p_mesa) returning id into v_cuenta;
  else
    update public.cuentas set estado = 'abierta' where id = v_cuenta;
  end if;
  insert into public.comandas(cuenta_id, mesa_id, client_token, mesero)
  values (
    v_cuenta, p_mesa, p_token,
    (select r.device_label from public.mesa_responsables r where r.mesa_id = p_mesa)
  )
  returning id into v_comanda;
  for it in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(it->>'producto_id', '') = ''
       or coalesce(it->>'nombre', '') = ''
       or coalesce((it->>'cantidad')::integer, 0) not between 1 and 99 then
      raise exception 'Artículo de comanda inválido';
    end if;
    v_precio := public.validar_item_comanda(
      it->>'producto_id', it->>'nombre', (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores', '[]'::jsonb)
    );
    insert into public.comanda_items(
      comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas
    ) values (
      v_comanda, it->>'producto_id', it->>'nombre', (it->>'cantidad')::integer, v_precio,
      coalesce(it->'modificadores', '[]'::jsonb), nullif(it->>'notas', '')
    );
    v_subtotal := v_subtotal + ((it->>'cantidad')::integer * v_precio);
  end loop;
  perform public.refrescar_estado_mesa(p_mesa);
  perform public.registrar_accion(
    'enviar_comanda', p_mesa, v_cuenta, v_comanda, v_subtotal,
    jsonb_build_object('items', jsonb_array_length(p_items), 'es_prueba', v_mesa_es_prueba)
  );
  return v_comanda;
end;
$$;

create or replace function public.pago_cuenta(
  p_cuenta uuid, p_metodo text, p_monto numeric, p_propina numeric default 0, p_es_prueba boolean default false
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_total numeric;
  v_saldo numeric;
  v_monto numeric;
  v_propina numeric := coalesce(p_propina, 0);
  v_pagado numeric;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para cobrar cuentas';
  end if;
  if p_metodo not in ('efectivo', 'clip') then
    raise exception 'Método de pago inválido';
  end if;
  if v_propina < 0 or v_propina > 100000 then
    raise exception 'Propina inválida';
  end if;
  select c.mesa_id, c.pagado into v_mesa, v_pagado
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
  v_saldo := greatest(v_total - coalesce(v_pagado, 0), 0);
  v_monto := coalesce(p_monto, v_saldo);
  if v_monto <= 0 or v_monto > v_saldo + 0.009 then
    raise exception 'El monto debe ser mayor a 0 y no pasar el saldo';
  end if;
  update public.cuentas
  set pagado = pagado + v_monto,
      propina = propina + v_propina,
      efectivo = efectivo + case when p_metodo = 'efectivo' then v_monto else 0 end,
      clip = clip + case when p_metodo = 'clip' then v_monto else 0 end,
      propina_efectivo = propina_efectivo + case when p_metodo = 'efectivo' then v_propina else 0 end,
      propina_clip = propina_clip + case when p_metodo = 'clip' then v_propina else 0 end
  where id = p_cuenta
  returning pagado into v_pagado;
  if v_pagado + 0.009 >= v_total then
    update public.cuentas
    set estado = 'pagada',
        metodo_pago = case
          when efectivo > 0 and clip > 0 then 'mixto'
          when clip > 0 then 'clip'
          else 'efectivo'
        end,
        total = v_total,
        descuento_total = greatest(
          (select coalesce(sum(i.cantidad * i.precio_unitario), 0)
           from public.comanda_items i
           join public.comandas co on co.id = i.comanda_id
           where co.cuenta_id = p_cuenta) - v_total, 0),
        cerrada_at = now(),
        fecha_operativa = (now() at time zone 'America/Monterrey')::date
    where id = p_cuenta;
    perform public.refrescar_estado_mesa(v_mesa);
  end if;
  perform public.registrar_accion(
    case when v_pagado + 0.009 >= v_total then 'cobrar_cuenta' else 'pago_parcial' end,
    v_mesa, p_cuenta, null, v_monto,
    jsonb_build_object('metodo_pago', p_metodo, 'propina', v_propina, 'saldo', greatest(v_total - v_pagado, 0))
  );
  return jsonb_build_object(
    'total', v_total,
    'pagado', v_pagado,
    'saldo', greatest(v_total - v_pagado, 0),
    'cerrada', v_pagado + 0.009 >= v_total
  );
end;
$$;

create or replace function public.cobrar_cuenta(
  p_cuenta uuid, p_metodo text, p_es_prueba boolean default false
)
returns numeric
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_result jsonb;
begin
  v_result := public.pago_cuenta(p_cuenta, p_metodo, null, 0, p_es_prueba);
  return (v_result->>'total')::numeric;
end;
$$;

create or replace function public.dividir_cuenta(
  p_cuenta uuid, p_items uuid[], p_es_prueba boolean default false
)
returns uuid
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_nueva uuid;
  v_comanda uuid;
  v_total int;
  v_marcados int;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para dividir cuentas';
  end if;
  if p_items is null or cardinality(p_items) = 0 then
    raise exception 'Selecciona al menos un artículo';
  end if;
  select c.mesa_id into v_mesa
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta and c.estado in ('abierta', 'por_cobrar')
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_mesa is null then
    raise exception 'Cuenta no disponible para dividir';
  end if;
  if coalesce((select pagado from public.cuentas where id = p_cuenta), 0) > 0 then
    raise exception 'No se puede separar una cuenta que ya tiene abonos';
  end if;
  select count(*) into v_total
  from public.comanda_items i
  join public.comandas co on co.id = i.comanda_id
  where co.cuenta_id = p_cuenta;
  select count(*) into v_marcados
  from public.comanda_items i
  join public.comandas co on co.id = i.comanda_id
  where co.cuenta_id = p_cuenta and i.id = any(p_items);
  if v_marcados <> cardinality(p_items) then
    raise exception 'Hay artículos que no pertenecen a esta cuenta';
  end if;
  if v_marcados >= v_total then
    raise exception 'Deja al menos un artículo en la cuenta original';
  end if;
  insert into public.cuentas(mesa_id) values (v_mesa) returning id into v_nueva;
  insert into public.comandas(cuenta_id, mesa_id, client_token, estado, mesero)
  values (v_nueva, v_mesa, 'split-' || gen_random_uuid()::text, 'listo', 'Caja')
  returning id into v_comanda;
  update public.comanda_items set comanda_id = v_comanda where id = any(p_items);
  delete from public.comandas co
  where co.cuenta_id = p_cuenta
    and not exists (select 1 from public.comanda_items i where i.comanda_id = co.id);
  perform public.registrar_accion(
    'dividir_cuenta', v_mesa, v_nueva, v_comanda, null,
    jsonb_build_object('origen', p_cuenta, 'articulos', v_marcados)
  );
  return v_nueva;
end;
$$;

create or replace function public.mover_cuenta(
  p_cuenta uuid, p_mesa uuid, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_origen uuid;
  v_ok boolean;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para mover cuentas';
  end if;
  select c.mesa_id into v_origen
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta and c.estado in ('abierta', 'por_cobrar')
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_origen is null then
    raise exception 'Cuenta no disponible para mover';
  end if;
  if v_origen = p_mesa then
    raise exception 'La cuenta ya está en esa mesa';
  end if;
  select m.activa and m.es_prueba = coalesce(p_es_prueba, false)
    and not exists (
      select 1 from public.cuentas c
      where c.mesa_id = m.id and c.estado in ('abierta', 'por_cobrar')
    )
  into v_ok
  from public.mesas m
  where m.id = p_mesa
  for update;
  if not coalesce(v_ok, false) then
    raise exception 'La mesa destino no está libre en este modo';
  end if;
  update public.cuentas set mesa_id = p_mesa where id = p_cuenta;
  update public.comandas set mesa_id = p_mesa where cuenta_id = p_cuenta;
  perform public.refrescar_estado_mesa(v_origen);
  perform public.refrescar_estado_mesa(p_mesa);
  perform public.registrar_accion(
    'mover_mesa', p_mesa, p_cuenta, null, null,
    jsonb_build_object('origen', v_origen)
  );
end;
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
  -- Cuentas cobradas antes de esta migración solo tienen metodo_pago.
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
  v_diff := p_contado - (p_fondo + v_efectivo + v_propina);
  insert into public.cortes_caja(
    fecha, fondo, efectivo_sistema, clip_sistema, propinas, efectivo_contado, diferencia, notas, es_prueba
  ) values (
    p_fecha, p_fondo, v_efectivo, v_clip, v_propina, p_contado, v_diff, nullif(trim(coalesce(p_notas, '')), ''), p_es_prueba
  ) returning id into v_id;
  perform public.registrar_accion(
    'corte_caja', null, null, null, v_diff,
    jsonb_build_object('fecha', p_fecha, 'fondo', p_fondo, 'contado', p_contado, 'es_prueba', p_es_prueba)
  );
  return jsonb_build_object(
    'id', v_id, 'efectivo', v_efectivo, 'clip', v_clip,
    'propina_efectivo', v_propina, 'esperado', p_fondo + v_efectivo + v_propina, 'diferencia', v_diff
  );
end;
$$;

create or replace function public.anular_cuenta(
  p_cuenta uuid, p_motivo text, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_total numeric;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para anular cuentas';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Motivo requerido';
  end if;
  select coalesce(sum(i.cantidad * i.precio_unitario), 0) into v_total
  from public.comanda_items i
  join public.comandas c on c.id = i.comanda_id
  where c.cuenta_id = p_cuenta;
  update public.cuentas c
  set estado = 'anulada', motivo_anulacion = trim(p_motivo),
      cerrada_at = now(),
      fecha_operativa = (now() at time zone 'America/Monterrey')::date
  from public.mesas m
  where c.id = p_cuenta and c.mesa_id = m.id
    and m.es_prueba = coalesce(p_es_prueba, false)
    and c.estado in ('abierta', 'por_cobrar')
  returning c.mesa_id into v_mesa;
  if v_mesa is null then
    raise exception 'Cuenta no anulable en el modo seleccionado';
  end if;
  perform public.refrescar_estado_mesa(v_mesa);
  perform public.registrar_accion(
    'anular_cuenta', v_mesa, p_cuenta, null, v_total,
    jsonb_build_object('motivo', trim(p_motivo), 'es_prueba', coalesce(p_es_prueba, false))
  );
end;
$$;

revoke all on function public.refrescar_estado_mesa(uuid) from public, anon, authenticated;
revoke all on function public.pago_cuenta(uuid, text, numeric, numeric, boolean) from public, anon, authenticated;
revoke all on function public.dividir_cuenta(uuid, uuid[], boolean) from public, anon, authenticated;
revoke all on function public.mover_cuenta(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.registrar_corte(date, numeric, numeric, text, boolean) from public, anon, authenticated;
grant execute on function public.pago_cuenta(uuid, text, numeric, numeric, boolean) to authenticated;
grant execute on function public.dividir_cuenta(uuid, uuid[], boolean) to authenticated;
grant execute on function public.mover_cuenta(uuid, uuid, boolean) to authenticated;
grant execute on function public.registrar_corte(date, numeric, numeric, text, boolean) to authenticated;

commit;
