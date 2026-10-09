create table if not exists public.staff_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('mesero', 'cocina', 'caja', 'admin')),
  created_at timestamptz not null default now()
);

alter table public.staff_roles enable row level security;

revoke all on public.staff_roles from public, anon, authenticated;
grant select on public.staff_roles to authenticated;

create or replace function public.tiene_rol(p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select exists (
    select 1
    from public.staff_roles sr
    where sr.user_id = (select auth.uid())
      and sr.role = any(p_roles)
      and (select auth.jwt()->>'is_anonymous') is distinct from 'true'
  );
$$;

revoke all on function public.tiene_rol(text[]) from public, anon, authenticated;
grant execute on function public.tiene_rol(text[]) to authenticated;

do $$
declare
  policy_row record;
begin
  for policy_row in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = any(array['staff_roles', 'mesas', 'cuentas', 'comandas', 'comanda_items'])
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      policy_row.policyname, policy_row.schemaname, policy_row.tablename
    );
  end loop;
end;
$$;

create policy "personal puede consultar roles propios"
  on public.staff_roles for select to authenticated
  using (user_id = (select auth.uid()));
create policy "administradores pueden consultar roles"
  on public.staff_roles for select to authenticated
  using (public.tiene_rol(array['admin']::text[]));

create policy "personal puede consultar mesas"
  on public.mesas for select to authenticated
  using (public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[]));
create policy "caja puede crear mesas"
  on public.mesas for insert to authenticated
  with check (public.tiene_rol(array['caja', 'admin']::text[]));

create policy "personal puede consultar cuentas"
  on public.cuentas for select to authenticated
  using (public.tiene_rol(array['mesero', 'caja', 'admin']::text[]));
create policy "personal puede consultar comandas"
  on public.comandas for select to authenticated
  using (public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[]));
create policy "personal puede consultar articulos"
  on public.comanda_items for select to authenticated
  using (public.tiene_rol(array['mesero', 'cocina', 'caja', 'admin']::text[]));

revoke all on public.mesas, public.cuentas, public.comandas, public.comanda_items
  from public, anon, authenticated;
grant select on public.mesas, public.cuentas, public.comandas, public.comanda_items
  to authenticated;
grant insert on public.mesas to authenticated;
revoke all on sequence public.comanda_numero_seq from public, anon, authenticated;
grant all on public.mesas, public.cuentas, public.comandas, public.comanda_items
  to service_role;

create or replace function public.enviar_comanda(
  p_mesa uuid,
  p_token text,
  p_items jsonb,
  p_mesero text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_cuenta uuid;
  v_comanda uuid;
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
  if not exists (select 1 from public.mesas where id = p_mesa and activa) then
    raise exception 'Mesa no disponible';
  end if;

  select id into v_comanda
  from public.comandas
  where client_token = p_token;
  if v_comanda is not null then
    return v_comanda;
  end if;

  select id into v_cuenta
  from public.cuentas
  where mesa_id = p_mesa and estado in ('abierta', 'por_cobrar')
  for update;
  if v_cuenta is null then
    insert into public.cuentas(mesa_id) values (p_mesa) returning id into v_cuenta;
  else
    update public.cuentas set estado = 'abierta' where id = v_cuenta;
  end if;

  insert into public.comandas(cuenta_id, mesa_id, client_token, mesero)
  values (v_cuenta, p_mesa, p_token, p_mesero)
  returning id into v_comanda;

  for it in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(it->>'producto_id', '') = ''
       or coalesce(it->>'nombre', '') = ''
       or coalesce((it->>'cantidad')::integer, 0) < 1
       or coalesce((it->>'precio_unitario')::numeric, -1) < 0 then
      raise exception 'Artículo de comanda inválido';
    end if;
    insert into public.comanda_items(
      comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas
    )
    values (
      v_comanda, it->>'producto_id', it->>'nombre',
      (it->>'cantidad')::integer, (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores', '[]'::jsonb), nullif(it->>'notas', '')
    );
  end loop;

  update public.mesas set estado = 'ocupada' where id = p_mesa;
  return v_comanda;
end;
$$;

create or replace function public.solicitar_cuenta(p_cuenta uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para solicitar cuenta';
  end if;
  update public.cuentas
  set estado = 'por_cobrar'
  where id = p_cuenta and estado = 'abierta'
  returning mesa_id into v_mesa;
  if v_mesa is null then
    raise exception 'Cuenta no disponible';
  end if;
  update public.mesas set estado = 'por_cobrar' where id = v_mesa;
end;
$$;

create or replace function public.cobrar_cuenta(p_cuenta uuid, p_metodo text)
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
  select mesa_id into v_mesa
  from public.cuentas
  where id = p_cuenta and estado in ('abierta', 'por_cobrar')
  for update;
  if v_mesa is null then
    raise exception 'Cuenta no disponible para cobro';
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
  return v_total;
end;
$$;

create or replace function public.anular_cuenta(p_cuenta uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para anular cuentas';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Motivo requerido';
  end if;
  update public.cuentas
  set estado = 'anulada', motivo_anulacion = trim(p_motivo), cerrada_at = now(),
      fecha_operativa = (now() at time zone 'America/Monterrey')::date
  where id = p_cuenta and estado in ('abierta', 'por_cobrar')
  returning mesa_id into v_mesa;
  if v_mesa is null then
    raise exception 'Cuenta no anulable';
  end if;
  update public.mesas set estado = 'disponible' where id = v_mesa;
end;
$$;

create or replace function public.actualizar_estado_comanda(p_comanda uuid, p_estado text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['cocina', 'admin']::text[]) then
    raise exception 'No autorizado para actualizar comandas';
  end if;
  if p_estado not in ('preparacion', 'listo') then
    raise exception 'Estado de comanda inválido';
  end if;
  update public.comandas
  set estado = p_estado
  where id = p_comanda
    and ((estado = 'pendiente' and p_estado = 'preparacion')
      or (estado = 'preparacion' and p_estado = 'listo'));
  if not found then
    raise exception 'La comanda no está disponible para ese cambio';
  end if;
end;
$$;

revoke all on function public.enviar_comanda(uuid, text, jsonb, text)
  from public, anon, authenticated;
revoke all on function public.solicitar_cuenta(uuid)
  from public, anon, authenticated;
revoke all on function public.cobrar_cuenta(uuid, text)
  from public, anon, authenticated;
revoke all on function public.anular_cuenta(uuid, text)
  from public, anon, authenticated;
revoke all on function public.actualizar_estado_comanda(uuid, text)
  from public, anon, authenticated;
grant execute on function public.enviar_comanda(uuid, text, jsonb, text) to authenticated;
grant execute on function public.solicitar_cuenta(uuid) to authenticated;
grant execute on function public.cobrar_cuenta(uuid, text) to authenticated;
grant execute on function public.anular_cuenta(uuid, text) to authenticated;
grant execute on function public.actualizar_estado_comanda(uuid, text) to authenticated;
