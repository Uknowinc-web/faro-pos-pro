begin;

drop function if exists public.solicitar_cuenta(uuid);
drop function if exists public.cobrar_cuenta(uuid, text);
drop function if exists public.anular_cuenta(uuid, text);
drop function if exists public.actualizar_estado_comanda(uuid, text);

create function public.solicitar_cuenta(
  p_cuenta uuid,
  p_es_prueba boolean default false
)
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

  update public.cuentas c
  set estado = 'por_cobrar'
  from public.mesas m
  where c.id = p_cuenta
    and c.mesa_id = m.id
    and m.es_prueba = coalesce(p_es_prueba, false)
    and c.estado = 'abierta'
  returning c.mesa_id into v_mesa;
  if v_mesa is null then
    raise exception 'Cuenta no disponible en el modo seleccionado';
  end if;
  update public.mesas set estado = 'por_cobrar' where id = v_mesa;
end;
$$;

create function public.cobrar_cuenta(
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
  return v_total;
end;
$$;

create function public.anular_cuenta(
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
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para anular cuentas';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Motivo requerido';
  end if;

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
end;
$$;

create function public.actualizar_estado_comanda(
  p_comanda uuid,
  p_estado text,
  p_es_prueba boolean default false
)
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

  update public.comandas c
  set estado = p_estado
  where c.id = p_comanda
    and exists (
      select 1
      from public.mesas m
      where m.id = c.mesa_id
        and m.es_prueba = coalesce(p_es_prueba, false)
    )
    and ((c.estado = 'pendiente' and p_estado = 'preparacion')
      or (c.estado = 'preparacion' and p_estado = 'listo'));
  if not found then
    raise exception 'La comanda no está disponible para ese cambio en el modo seleccionado';
  end if;
end;
$$;

revoke all on function public.solicitar_cuenta(uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.cobrar_cuenta(uuid, text, boolean)
  from public, anon, authenticated;
revoke all on function public.anular_cuenta(uuid, text, boolean)
  from public, anon, authenticated;
revoke all on function public.actualizar_estado_comanda(uuid, text, boolean)
  from public, anon, authenticated;

grant execute on function public.solicitar_cuenta(uuid, boolean) to authenticated;
grant execute on function public.cobrar_cuenta(uuid, text, boolean) to authenticated;
grant execute on function public.anular_cuenta(uuid, text, boolean) to authenticated;
grant execute on function public.actualizar_estado_comanda(uuid, text, boolean)
  to authenticated;

commit;
