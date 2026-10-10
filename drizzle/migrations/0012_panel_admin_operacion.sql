begin;

-- Bitácora de acciones por dispositivo para el panel de administración.
create table public.audit_acciones (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  fecha_operativa date not null
    default ((now() at time zone 'America/Monterrey')::date),
  user_id uuid references auth.users(id) on delete set null,
  device_label text not null,
  role text not null
    check (role in ('mesero', 'cocina', 'caja', 'admin')),
  accion text not null
    check (accion in (
      'enviar_comanda',
      'reclamar_mesa',
      'actualizar_comanda',
      'cobrar_cuenta',
      'anular_cuenta'
    )),
  mesa_id uuid references public.mesas(id) on delete set null,
  cuenta_id uuid references public.cuentas(id) on delete set null,
  comanda_id uuid references public.comandas(id) on delete set null,
  monto numeric(10, 2),
  detalle jsonb not null default '{}'::jsonb
);

create index audit_acciones_fecha_created_idx
  on public.audit_acciones(fecha_operativa, created_at desc);
create index audit_acciones_user_created_idx
  on public.audit_acciones(user_id, created_at desc);

alter table public.audit_acciones enable row level security;
revoke all on public.audit_acciones from public, anon, authenticated;
grant select on public.audit_acciones to authenticated;

create policy administradores_ven_auditoria
  on public.audit_acciones for select to authenticated
  using (public.tiene_rol(array['admin']::text[]));

create policy administradores_ven_responsables_de_mesa
  on public.mesa_responsables for select to authenticated
  using (public.tiene_rol(array['admin']::text[]));

-- Registra una acción del actor autenticado (solo vía security definer).
create function public.registrar_accion(
  p_accion text,
  p_mesa_id uuid default null,
  p_cuenta_id uuid default null,
  p_comanda_id uuid default null,
  p_monto numeric default null,
  p_detalle jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_label text;
begin
  if v_user_id is null then
    return;
  end if;
  if p_accion not in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta'
  ) then
    raise exception 'Acción de auditoría inválida';
  end if;

  select sr.role into v_role
  from public.staff_roles sr
  where sr.user_id = v_user_id;

  if v_role is null then
    return;
  end if;

  v_label := coalesce(
    nullif(trim((
      select s.device_label
      from public.solicitudes_puesto s
      where s.user_id = v_user_id
    )), ''),
    case when v_role = 'admin' then 'Administración' else null end,
    nullif(auth.jwt()->>'email', ''),
    initcap(v_role) || ' ' || left(v_user_id::text, 8)
  );

  insert into public.audit_acciones(
    user_id, device_label, role, accion,
    mesa_id, cuenta_id, comanda_id, monto, detalle
  )
  values (
    v_user_id, v_label, v_role, p_accion,
    p_mesa_id, p_cuenta_id, p_comanda_id, p_monto,
    coalesce(p_detalle, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.registrar_accion(text, uuid, uuid, uuid, numeric, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Instrumentar RPC operativas
-- ---------------------------------------------------------------------------

create or replace function public.reclamar_mesa(
  p_mesa uuid,
  p_es_prueba boolean default false
)
returns table (
  responsable_id uuid,
  responsable_nombre text,
  asignada_at timestamptz,
  es_responsable boolean
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_mode boolean;
  v_label text;
  v_claimed uuid;
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    raise exception 'Solo un mesero autorizado puede abrir una mesa';
  end if;

  select m.es_prueba into v_mode
  from public.mesas m
  where m.id = p_mesa and m.activa
  for update;
  if not found or v_mode is distinct from coalesce(p_es_prueba, false) then
    raise exception 'La mesa no está disponible en el modo seleccionado';
  end if;

  v_label := coalesce(
    (select nullif(trim(s.device_label), '')
     from public.solicitudes_puesto s where s.user_id = v_user_id),
    nullif(auth.jwt()->>'email', ''),
    'Mesero ' || left(v_user_id::text, 8)
  );

  insert into public.mesa_responsables(mesa_id, user_id, device_label)
  values (p_mesa, v_user_id, v_label)
  on conflict (mesa_id) do nothing
  returning mesa_id into v_claimed;

  if v_claimed is not null then
    perform public.registrar_accion(
      'reclamar_mesa',
      p_mesa,
      null,
      null,
      null,
      jsonb_build_object('device_label', v_label, 'es_prueba', v_mode)
    );
  end if;

  return query
  select r.user_id, r.device_label, r.assigned_at, r.user_id = v_user_id
  from public.mesa_responsables r
  where r.mesa_id = p_mesa;
end;
$$;

create or replace function public.enviar_comanda(
  p_mesa uuid,
  p_token text,
  p_items jsonb,
  p_mesero text default null,
  p_es_prueba boolean default false
)
returns uuid
language plpgsql
security definer
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
  from public.mesas m
  where m.id = p_mesa and m.activa
  for update;
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

  select r.user_id into v_owner
  from public.mesa_responsables r
  where r.mesa_id = p_mesa;
  if v_owner is distinct from v_user_id then
    raise exception 'Solo el responsable asignado puede enviar comandas a esta mesa';
  end if;

  select c.id into v_cuenta
  from public.cuentas c
  where c.mesa_id = p_mesa and c.estado in ('abierta', 'por_cobrar')
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
      it->>'producto_id',
      it->>'nombre',
      (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores', '[]'::jsonb)
    );
    insert into public.comanda_items(
      comanda_id, producto_id, nombre, cantidad, precio_unitario,
      modificadores, notas
    )
    values (
      v_comanda, it->>'producto_id', it->>'nombre',
      (it->>'cantidad')::integer, v_precio,
      coalesce(it->'modificadores', '[]'::jsonb), nullif(it->>'notas', '')
    );
    v_subtotal := v_subtotal + ((it->>'cantidad')::integer * v_precio);
  end loop;

  update public.mesas set estado = 'ocupada' where id = p_mesa;

  perform public.registrar_accion(
    'enviar_comanda',
    p_mesa,
    v_cuenta,
    v_comanda,
    v_subtotal,
    jsonb_build_object(
      'items', jsonb_array_length(p_items),
      'es_prueba', v_mesa_es_prueba
    )
  );

  return v_comanda;
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

  select coalesce(sum(i.cantidad * i.precio_unitario), 0) into v_total
  from public.comanda_items i
  join public.comandas c on c.id = i.comanda_id
  where c.cuenta_id = p_cuenta;
  update public.cuentas
  set estado = 'pagada', metodo_pago = p_metodo, total = v_total,
      cerrada_at = now(),
      fecha_operativa = (now() at time zone 'America/Monterrey')::date
  where id = p_cuenta;
  update public.mesas set estado = 'disponible' where id = v_mesa;

  perform public.registrar_accion(
    'cobrar_cuenta',
    v_mesa,
    p_cuenta,
    null,
    v_total,
    jsonb_build_object(
      'metodo_pago', p_metodo,
      'es_prueba', coalesce(p_es_prueba, false)
    )
  );

  return v_total;
end;
$$;

create or replace function public.anular_cuenta(
  p_cuenta uuid,
  p_motivo text,
  p_es_prueba boolean default false
)
returns void
language plpgsql
security definer
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
  where c.id = p_cuenta
    and c.mesa_id = m.id
    and m.es_prueba = coalesce(p_es_prueba, false)
    and c.estado in ('abierta', 'por_cobrar')
  returning c.mesa_id into v_mesa;
  if v_mesa is null then
    raise exception 'Cuenta no anulable en el modo seleccionado';
  end if;
  update public.mesas set estado = 'disponible' where id = v_mesa;

  perform public.registrar_accion(
    'anular_cuenta',
    v_mesa,
    p_cuenta,
    null,
    v_total,
    jsonb_build_object(
      'motivo', trim(p_motivo),
      'es_prueba', coalesce(p_es_prueba, false)
    )
  );
end;
$$;

create or replace function public.actualizar_estado_comanda(
  p_comanda uuid,
  p_estado text,
  p_es_prueba boolean default false
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_cuenta uuid;
  v_prev text;
begin
  if not public.tiene_rol(array['cocina', 'admin']::text[]) then
    raise exception 'No autorizado para actualizar comandas';
  end if;
  if p_estado not in ('preparacion', 'listo') then
    raise exception 'Estado de comanda inválido';
  end if;

  select c.mesa_id, c.cuenta_id, c.estado
  into v_mesa, v_cuenta, v_prev
  from public.comandas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_comanda
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_mesa is null then
    raise exception 'La comanda no está disponible para ese cambio en el modo seleccionado';
  end if;
  if not (
    (v_prev = 'pendiente' and p_estado = 'preparacion')
    or (v_prev = 'preparacion' and p_estado = 'listo')
  ) then
    raise exception 'La comanda no está disponible para ese cambio en el modo seleccionado';
  end if;

  update public.comandas
  set estado = p_estado
  where id = p_comanda;

  perform public.registrar_accion(
    'actualizar_comanda',
    v_mesa,
    v_cuenta,
    p_comanda,
    null,
    jsonb_build_object(
      'estado_anterior', v_prev,
      'estado_nuevo', p_estado,
      'es_prueba', coalesce(p_es_prueba, false)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Panel de operación en vivo (solo admin)
-- ---------------------------------------------------------------------------

create or replace function public.panel_operacion_vivo(
  p_es_prueba boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_fecha date := (now() at time zone 'America/Monterrey')::date;
  v_mode boolean := coalesce(p_es_prueba, false);
  v_corte jsonb;
  v_piso jsonb;
  v_cocina jsonb;
  v_dispositivos jsonb;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar el panel de operación';
  end if;

  select jsonb_build_object(
    'efectivo', coalesce(sum(c.total) filter (where c.estado = 'pagada' and c.metodo_pago = 'efectivo'), 0),
    'clip', coalesce(sum(c.total) filter (where c.estado = 'pagada' and c.metodo_pago = 'clip'), 0),
    'total', coalesce(sum(c.total) filter (where c.estado = 'pagada'), 0),
    'tickets_pagados', count(*) filter (where c.estado = 'pagada'),
    'tickets_anulados', count(*) filter (where c.estado = 'anulada')
  )
  into v_corte
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.fecha_operativa = v_fecha
    and m.es_prueba = v_mode
    and c.estado in ('pagada', 'anulada');

  select coalesce(jsonb_agg(row_data order by orden, nombre), '[]'::jsonb)
  into v_piso
  from (
    select
      m.orden,
      m.nombre,
      jsonb_build_object(
        'mesa_id', m.id,
        'nombre', m.nombre,
        'estado', m.estado,
        'responsable', r.device_label,
        'responsable_id', r.user_id,
        'cuenta_id', cu.id,
        'cuenta_estado', cu.estado,
        'subtotal', coalesce((
          select sum(i.cantidad * i.precio_unitario)
          from public.comanda_items i
          join public.comandas co on co.id = i.comanda_id
          where co.cuenta_id = cu.id
        ), 0),
        'items', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'nombre', i.nombre,
              'cantidad', i.cantidad,
              'precio_unitario', i.precio_unitario,
              'notas', i.notas
            )
            order by i.nombre
          )
          from public.comanda_items i
          join public.comandas co on co.id = i.comanda_id
          where co.cuenta_id = cu.id
        ), '[]'::jsonb)
      ) as row_data
    from public.mesas m
    left join public.mesa_responsables r on r.mesa_id = m.id
    left join public.cuentas cu
      on cu.mesa_id = m.id and cu.estado in ('abierta', 'por_cobrar')
    where m.activa
      and m.es_prueba = v_mode
      and (m.estado <> 'disponible' or r.mesa_id is not null or cu.id is not null)
  ) piso;

  select jsonb_build_object(
    'pendiente', coalesce((
      select jsonb_agg(ticket order by created_at)
      from (
        select jsonb_build_object(
          'comanda_id', c.id,
          'numero', c.numero,
          'mesa', m.nombre,
          'mesa_id', m.id,
          'estado', c.estado,
          'created_at', c.created_at,
          'mesero', c.mesero,
          'items', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'nombre', i.nombre,
                'cantidad', i.cantidad,
                'notas', i.notas
              )
              order by i.nombre
            )
            from public.comanda_items i
            where i.comanda_id = c.id
          ), '[]'::jsonb)
        ) as ticket,
        c.created_at
        from public.comandas c
        join public.mesas m on m.id = c.mesa_id
        where m.activa and m.es_prueba = v_mode and c.estado = 'pendiente'
      ) t
    ), '[]'::jsonb),
    'preparacion', coalesce((
      select jsonb_agg(ticket order by created_at)
      from (
        select jsonb_build_object(
          'comanda_id', c.id,
          'numero', c.numero,
          'mesa', m.nombre,
          'mesa_id', m.id,
          'estado', c.estado,
          'created_at', c.created_at,
          'mesero', c.mesero,
          'items', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'nombre', i.nombre,
                'cantidad', i.cantidad,
                'notas', i.notas
              )
              order by i.nombre
            )
            from public.comanda_items i
            where i.comanda_id = c.id
          ), '[]'::jsonb)
        ) as ticket,
        c.created_at
        from public.comandas c
        join public.mesas m on m.id = c.mesa_id
        where m.activa and m.es_prueba = v_mode and c.estado = 'preparacion'
      ) t
    ), '[]'::jsonb)
  )
  into v_cocina;

  select coalesce(jsonb_agg(dev order by role, device_label), '[]'::jsonb)
  into v_dispositivos
  from (
    select jsonb_build_object(
      'user_id', sr.user_id,
      'role', sr.role,
      'device_label', coalesce(
        nullif(trim(sp.device_label), ''),
        case when sr.role = 'admin' then 'Administración' else initcap(sr.role) end
      ),
      'ultima_accion', (
        select jsonb_build_object(
          'accion', a.accion,
          'created_at', a.created_at,
          'monto', a.monto
        )
        from public.audit_acciones a
        where a.user_id = sr.user_id
        order by a.created_at desc
        limit 1
      )
    ) as dev,
    sr.role,
    coalesce(nullif(trim(sp.device_label), ''), sr.role) as device_label
    from public.staff_roles sr
    join public.solicitudes_puesto sp on sp.user_id = sr.user_id
    where sr.role in ('mesero', 'cocina', 'caja')
      and sp.status = 'approved'
  ) d;

  return jsonb_build_object(
    'fecha_operativa', v_fecha,
    'es_prueba', v_mode,
    'corte', coalesce(v_corte, jsonb_build_object(
      'efectivo', 0, 'clip', 0, 'total', 0,
      'tickets_pagados', 0, 'tickets_anulados', 0
    )),
    'piso', coalesce(v_piso, '[]'::jsonb),
    'cocina', coalesce(v_cocina, jsonb_build_object(
      'pendiente', '[]'::jsonb,
      'preparacion', '[]'::jsonb
    )),
    'dispositivos_activos', coalesce(v_dispositivos, '[]'::jsonb)
  );
end;
$$;

create or replace function public.listar_auditoria_admin(
  p_fecha date default null,
  p_limite integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_fecha date := coalesce(
    p_fecha,
    (now() at time zone 'America/Monterrey')::date
  );
  v_limite integer := greatest(1, least(coalesce(p_limite, 100), 500));
  v_rows jsonb;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar la bitácora';
  end if;

  select coalesce(jsonb_agg(row_to_json(t)::jsonb), '[]'::jsonb)
  into v_rows
  from (
    select
      a.id,
      a.created_at,
      a.fecha_operativa,
      a.user_id,
      a.device_label,
      a.role,
      a.accion,
      a.mesa_id,
      a.cuenta_id,
      a.comanda_id,
      a.monto,
      a.detalle,
      m.nombre as mesa_nombre
    from public.audit_acciones a
    left join public.mesas m on m.id = a.mesa_id
    where a.fecha_operativa = v_fecha
    order by a.created_at desc
    limit v_limite
  ) t;

  return jsonb_build_object(
    'fecha_operativa', v_fecha,
    'acciones', coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.panel_operacion_vivo(boolean)
  from public, anon, authenticated;
revoke all on function public.listar_auditoria_admin(date, integer)
  from public, anon, authenticated;

grant execute on function public.panel_operacion_vivo(boolean) to authenticated;
grant execute on function public.listar_auditoria_admin(date, integer) to authenticated;

alter publication supabase_realtime add table public.audit_acciones;

commit;
