begin;

create table public.mesa_responsables (
  mesa_id uuid primary key references public.mesas(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_label text not null,
  assigned_at timestamptz not null default now()
);

create index mesa_responsables_user_id_idx
  on public.mesa_responsables(user_id);

create table public.sugerencias_comanda (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas(id) on delete cascade,
  requester_id uuid not null references auth.users(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  es_prueba boolean not null,
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  estado text not null default 'pending'
    check (estado in ('pending', 'accepted', 'rejected')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz
);

create index sugerencias_comanda_owner_pending_idx
  on public.sugerencias_comanda(owner_id, requested_at)
  where estado = 'pending';
create index sugerencias_comanda_requester_idx
  on public.sugerencias_comanda(requester_id, requested_at desc);

alter table public.mesa_responsables enable row level security;
alter table public.sugerencias_comanda enable row level security;
revoke all on public.mesa_responsables, public.sugerencias_comanda
  from public, anon, authenticated;
grant select on public.mesa_responsables, public.sugerencias_comanda
  to authenticated;

create policy meseros_ven_responsables_de_mesa
  on public.mesa_responsables for select to authenticated
  using (public.tiene_rol(array['mesero']::text[]));
create policy meseros_ven_sus_sugerencias
  on public.sugerencias_comanda for select to authenticated
  using (
    public.tiene_rol(array['mesero']::text[])
    and (owner_id = (select auth.uid()) or requester_id = (select auth.uid()))
  );

create function public.reclamar_mesa(
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
  on conflict (mesa_id) do nothing;

  return query
  select r.user_id, r.device_label, r.assigned_at, r.user_id = v_user_id
  from public.mesa_responsables r
  where r.mesa_id = p_mesa;
end;
$$;

create function public.listar_responsables_mesa(p_es_prueba boolean default false)
returns table (
  mesa_id uuid,
  responsable_id uuid,
  responsable_nombre text,
  asignada_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    raise exception 'Solo un mesero autorizado puede consultar responsables';
  end if;

  return query
  select r.mesa_id, r.user_id, r.device_label, r.assigned_at
  from public.mesa_responsables r
  join public.mesas m on m.id = r.mesa_id
  where m.activa and m.es_prueba = coalesce(p_es_prueba, false);
end;
$$;

create function public.listar_sugerencias_comanda(p_es_prueba boolean default false)
returns table (
  id uuid,
  mesa_id uuid,
  owner_id uuid,
  requester_id uuid,
  requester_nombre text,
  items jsonb,
  estado text,
  requested_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    raise exception 'Solo un mesero autorizado puede consultar sugerencias';
  end if;

  return query
  select s.id, s.mesa_id, s.owner_id, s.requester_id,
         coalesce(nullif(trim(requester.device_label), ''),
                  nullif(requester_user.email, ''),
                  'Mesero ' || left(s.requester_id::text, 8)),
         s.items, s.estado, s.requested_at
  from public.sugerencias_comanda s
  join public.mesas m on m.id = s.mesa_id
  left join public.solicitudes_puesto requester
    on requester.user_id = s.requester_id
  left join auth.users requester_user
    on requester_user.id = s.requester_id
  where m.activa
    and s.es_prueba = coalesce(p_es_prueba, false)
    and (s.owner_id = auth.uid()
      or (s.requester_id = auth.uid() and s.estado <> 'pending'))
  order by s.requested_at desc;
end;
$$;

create function public.solicitar_sugerencia_comanda(
  p_mesa uuid,
  p_items jsonb,
  p_es_prueba boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_mode boolean;
  v_owner uuid;
  v_suggestion uuid;
  v_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_price numeric;
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    raise exception 'Solo un mesero autorizado puede sugerir artículos';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) not between 1 and 30 then
    raise exception 'La sugerencia debe contener entre 1 y 30 artículos';
  end if;

  select m.es_prueba into v_mode
  from public.mesas m
  where m.id = p_mesa and m.activa
  for update;
  if not found or v_mode is distinct from coalesce(p_es_prueba, false) then
    raise exception 'La mesa no está disponible en el modo seleccionado';
  end if;

  select r.user_id into v_owner
  from public.mesa_responsables r
  where r.mesa_id = p_mesa;
  if v_owner is null then
    raise exception 'La mesa no tiene responsable todavía; vuelve a abrirla para asignártela';
  end if;
  if v_owner = v_user_id then
    raise exception 'Eres responsable de esta mesa; envía la comanda directamente';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(v_item->>'producto_id', '') = ''
       or coalesce(v_item->>'nombre', '') = ''
       or coalesce((v_item->>'cantidad')::integer, 0) not between 1 and 99 then
      raise exception 'Artículo sugerido inválido';
    end if;
    v_price := public.validar_item_comanda(
      v_item->>'producto_id',
      v_item->>'nombre',
      (v_item->>'precio_unitario')::numeric,
      coalesce(v_item->'modificadores', '[]'::jsonb)
    );
    v_items := v_items || jsonb_build_array(
      jsonb_set(v_item, '{precio_unitario}', to_jsonb(v_price), true)
    );
  end loop;

  insert into public.sugerencias_comanda(
    mesa_id, requester_id, owner_id, es_prueba, items
  )
  values (p_mesa, v_user_id, v_owner, v_mode, v_items)
  returning id into v_suggestion;
  return v_suggestion;
end;
$$;

create function public.responder_sugerencia_comanda(
  p_sugerencia uuid,
  p_aceptar boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_mesa uuid;
  v_owner uuid;
  v_mode boolean;
  v_items jsonb;
  v_item jsonb;
  v_cuenta uuid;
  v_comanda uuid;
begin
  if not public.tiene_rol(array['mesero']::text[]) then
    raise exception 'Solo un mesero autorizado puede responder sugerencias';
  end if;

  select s.mesa_id into v_mesa
  from public.sugerencias_comanda s
  where s.id = p_sugerencia;
  if v_mesa is null then
    raise exception 'La sugerencia ya no está disponible';
  end if;

  select m.es_prueba into v_mode
  from public.mesas m
  where m.id = v_mesa and m.activa
  for update;
  if not found then
    raise exception 'La mesa ya no está disponible';
  end if;

  select s.owner_id, s.es_prueba, s.items
  into v_owner, v_mode, v_items
  from public.sugerencias_comanda s
  where s.id = p_sugerencia and s.mesa_id = v_mesa
  for update;
  if not found or v_owner <> v_user_id then
    raise exception 'Solo el responsable actual puede responder esta sugerencia';
  end if;

  perform 1 from public.mesa_responsables r
  where r.mesa_id = v_mesa and r.user_id = v_user_id
  for update;
  if not found then
    raise exception 'Ya no eres responsable de esta mesa';
  end if;
  if exists (
    select 1 from public.mesas m
    where m.id = v_mesa and m.es_prueba <> v_mode
  ) then
    raise exception 'La sugerencia no corresponde al modo actual';
  end if;
  if not exists (
    select 1 from public.sugerencias_comanda s
    where s.id = p_sugerencia and s.estado = 'pending'
  ) then
    raise exception 'La sugerencia ya fue respondida';
  end if;

  if p_aceptar then
    select c.id into v_cuenta
    from public.cuentas c
    where c.mesa_id = v_mesa and c.estado in ('abierta', 'por_cobrar')
    for update;
    if v_cuenta is null then
      insert into public.cuentas(mesa_id)
      values (v_mesa) returning id into v_cuenta;
    else
      update public.cuentas set estado = 'abierta' where id = v_cuenta;
    end if;

    insert into public.comandas(cuenta_id, mesa_id, client_token, mesero)
    values (v_cuenta, v_mesa, 'sugerencia:' || p_sugerencia::text,
            (select r.device_label from public.mesa_responsables r where r.mesa_id = v_mesa))
    returning id into v_comanda;

    for v_item in select value from jsonb_array_elements(v_items)
    loop
      insert into public.comanda_items(
        comanda_id, producto_id, nombre, cantidad, precio_unitario,
        modificadores, notas
      )
      values (
        v_comanda,
        v_item->>'producto_id',
        v_item->>'nombre',
        (v_item->>'cantidad')::integer,
        (v_item->>'precio_unitario')::numeric,
        coalesce(v_item->'modificadores', '[]'::jsonb),
        nullif(v_item->>'notas', '')
      );
    end loop;
    update public.mesas set estado = 'ocupada' where id = v_mesa;
  end if;

  update public.sugerencias_comanda
  set estado = case when p_aceptar then 'accepted' else 'rejected' end,
      decided_at = now()
  where id = p_sugerencia;
end;
$$;

create function public.liberar_responsable_mesa_cerrada()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.estado in ('pagada', 'anulada')
     and old.estado is distinct from new.estado then
    delete from public.mesa_responsables
    where mesa_id = new.mesa_id;
    update public.sugerencias_comanda
    set estado = 'rejected', decided_at = now()
    where mesa_id = new.mesa_id and estado = 'pending';
  end if;
  return new;
end;
$$;

create trigger cuentas_liberar_responsable_mesa
after update of estado on public.cuentas
for each row execute function public.liberar_responsable_mesa_cerrada();

drop function if exists public.enviar_comanda(uuid, text, jsonb, text, boolean);

create function public.enviar_comanda(
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
  end loop;

  update public.mesas set estado = 'ocupada' where id = p_mesa;
  return v_comanda;
end;
$$;

revoke all on function public.reclamar_mesa(uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.listar_responsables_mesa(boolean)
  from public, anon, authenticated;
revoke all on function public.listar_sugerencias_comanda(boolean)
  from public, anon, authenticated;
revoke all on function public.solicitar_sugerencia_comanda(uuid, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function public.responder_sugerencia_comanda(uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.liberar_responsable_mesa_cerrada()
  from public, anon, authenticated;
revoke all on function public.enviar_comanda(uuid, text, jsonb, text, boolean)
  from public, anon, authenticated;

grant execute on function public.reclamar_mesa(uuid, boolean) to authenticated;
grant execute on function public.listar_responsables_mesa(boolean) to authenticated;
grant execute on function public.listar_sugerencias_comanda(boolean) to authenticated;
grant execute on function public.solicitar_sugerencia_comanda(uuid, jsonb, boolean)
  to authenticated;
grant execute on function public.responder_sugerencia_comanda(uuid, boolean)
  to authenticated;
grant execute on function public.enviar_comanda(uuid, text, jsonb, text, boolean)
  to authenticated;

alter publication supabase_realtime
  add table public.mesa_responsables, public.sugerencias_comanda;

commit;
