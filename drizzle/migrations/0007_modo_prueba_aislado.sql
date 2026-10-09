begin;

alter table public.mesas
  add column if not exists es_prueba boolean not null default false;

insert into public.mesas (nombre, orden, es_prueba)
select 'PRUEBA · Mesa ' || n, 200 + n, true
from generate_series(1, 12) as n
on conflict (nombre) do nothing;

insert into public.mesas (nombre, orden, es_prueba)
values ('PRUEBA · Para llevar', 299, true)
on conflict (nombre) do nothing;

drop function if exists public.enviar_comanda(uuid, text, jsonb, text);

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
  v_cuenta uuid;
  v_comanda uuid;
  v_comanda_es_prueba boolean;
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
  if not exists (
    select 1 from public.mesas
    where id = p_mesa and activa and es_prueba = coalesce(p_es_prueba, false)
  ) then
    raise exception 'La mesa no corresponde al modo de operación seleccionado';
  end if;

  select c.id, m.es_prueba
  into v_comanda, v_comanda_es_prueba
  from public.comandas c
  join public.mesas m on m.id = c.mesa_id
  where c.client_token = p_token;
  if v_comanda is not null then
    if v_comanda_es_prueba <> coalesce(p_es_prueba, false) then
      raise exception 'El token de comanda ya se usó en otro modo';
    end if;
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
  values (v_cuenta, p_mesa, p_token, auth.jwt()->>'email')
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
      comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas
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

revoke all on function public.enviar_comanda(uuid, text, jsonb, text, boolean)
  from public, anon, authenticated;
grant execute on function public.enviar_comanda(uuid, text, jsonb, text, boolean)
  to authenticated;

commit;
