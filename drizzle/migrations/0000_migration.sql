
create table public.mesas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  orden int not null default 100,
  estado text not null default 'disponible',
  created_at timestamptz not null default now()
);
create table public.cuentas (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas(id) on delete cascade,
  estado text not null default 'abierta',
  metodo_pago text,
  total numeric(10,2),
  motivo_anulacion text,
  fecha_operativa date,
  abierta_at timestamptz not null default now(),
  cerrada_at timestamptz
);
create unique index cuentas_una_abierta on public.cuentas(mesa_id) where estado in ('abierta','por_cobrar');
create sequence public.comanda_numero_seq;
create table public.comandas (
  id uuid primary key default gen_random_uuid(),
  numero int not null default nextval('public.comanda_numero_seq'),
  cuenta_id uuid not null references public.cuentas(id) on delete cascade,
  mesa_id uuid not null references public.mesas(id) on delete cascade,
  client_token text not null unique,
  estado text not null default 'pendiente',
  mesero text,
  created_at timestamptz not null default now()
);
create table public.comanda_items (
  id uuid primary key default gen_random_uuid(),
  comanda_id uuid not null references public.comandas(id) on delete cascade,
  producto_id text not null,
  nombre text not null,
  cantidad int not null default 1,
  precio_unitario numeric(10,2) not null,
  modificadores jsonb not null default '[]',
  notas text,
  estacion text not null default 'cocina'
);

grant select, insert, update, delete on public.mesas, public.cuentas, public.comandas, public.comanda_items to anon, authenticated;
grant all on public.mesas, public.cuentas, public.comandas, public.comanda_items to service_role;
grant usage on sequence public.comanda_numero_seq to anon, authenticated;

alter table public.mesas enable row level security;
alter table public.cuentas enable row level security;
alter table public.comandas enable row level security;
alter table public.comanda_items enable row level security;
create policy "staff all" on public.mesas for all using (true) with check (true);
create policy "staff all" on public.cuentas for all using (true) with check (true);
create policy "staff all" on public.comandas for all using (true) with check (true);
create policy "staff all" on public.comanda_items for all using (true) with check (true);

insert into public.mesas (nombre, orden) values ('Barra',0),
('Mesa 1',1),('Mesa 2',2),('Mesa 3',3),('Mesa 4',4),('Mesa 5',5),('Mesa 6',6),
('Mesa 7',7),('Mesa 8',8),('Mesa 9',9),('Mesa 10',10),('Mesa 11',11),('Mesa 12',12),('Para Llevar',99);

create or replace function public.enviar_comanda(p_mesa uuid, p_token text, p_items jsonb, p_mesero text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_cuenta uuid; v_comanda uuid; it jsonb;
begin
  select id into v_comanda from comandas where client_token = p_token;
  if v_comanda is not null then return v_comanda; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Comanda vacía'; end if;
  select id into v_cuenta from cuentas where mesa_id = p_mesa and estado in ('abierta','por_cobrar') for update;
  if v_cuenta is null then
    insert into cuentas(mesa_id) values (p_mesa) returning id into v_cuenta;
  else
    update cuentas set estado='abierta' where id=v_cuenta;
  end if;
  insert into comandas(cuenta_id, mesa_id, client_token, mesero) values (v_cuenta, p_mesa, p_token, p_mesero) returning id into v_comanda;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into comanda_items(comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas, estacion)
    values (v_comanda, it->>'producto_id', it->>'nombre', greatest((it->>'cantidad')::int,1), (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores','[]'::jsonb), nullif(it->>'notas',''), coalesce(it->>'estacion','cocina'));
  end loop;
  update mesas set estado='ocupada' where id=p_mesa;
  return v_comanda;
end $$;

create or replace function public.solicitar_cuenta(p_cuenta uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update cuentas set estado='por_cobrar' where id=p_cuenta and estado='abierta';
  update mesas set estado='por_cobrar' where id=(select mesa_id from cuentas where id=p_cuenta);
end $$;

create or replace function public.cobrar_cuenta(p_cuenta uuid, p_metodo text) returns numeric language plpgsql security definer set search_path=public as $$
declare v_total numeric; v_mesa uuid;
begin
  if p_metodo not in ('efectivo','clip') then raise exception 'Método inválido'; end if;
  select mesa_id into v_mesa from cuentas where id=p_cuenta and estado in ('abierta','por_cobrar') for update;
  if v_mesa is null then raise exception 'Cuenta no disponible para cobro'; end if;
  select coalesce(sum(i.cantidad*i.precio_unitario),0) into v_total from comanda_items i join comandas c on c.id=i.comanda_id where c.cuenta_id=p_cuenta;
  update cuentas set estado='pagada', metodo_pago=p_metodo, total=v_total, cerrada_at=now(),
    fecha_operativa=(now() at time zone 'America/Monterrey')::date where id=p_cuenta;
  update mesas set estado='disponible' where id=v_mesa;
  return v_total;
end $$;

create or replace function public.anular_cuenta(p_cuenta uuid, p_motivo text) returns void language plpgsql security definer set search_path=public as $$
declare v_mesa uuid;
begin
  if coalesce(trim(p_motivo),'')='' then raise exception 'Motivo requerido'; end if;
  select mesa_id into v_mesa from cuentas where id=p_cuenta and estado in ('abierta','por_cobrar');
  if v_mesa is null then raise exception 'Cuenta no anulable'; end if;
  update cuentas set estado='anulada', motivo_anulacion=p_motivo, cerrada_at=now(),
    fecha_operativa=(now() at time zone 'America/Monterrey')::date where id=p_cuenta;
  update mesas set estado='disponible' where id=v_mesa;
end $$;

grant execute on function public.enviar_comanda, public.solicitar_cuenta, public.cobrar_cuenta, public.anular_cuenta to anon, authenticated;

alter publication supabase_realtime add table public.mesas, public.cuentas, public.comandas, public.comanda_items;
