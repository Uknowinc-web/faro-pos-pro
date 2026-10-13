begin;

alter table public.cuentas
  add column if not exists clip_referencia text;

drop function if exists public.pago_cuenta(uuid, text, numeric, numeric, boolean);

create or replace function public.pago_cuenta(
  p_cuenta uuid,
  p_metodo text,
  p_monto numeric,
  p_propina numeric default 0,
  p_es_prueba boolean default false,
  p_referencia text default null
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
  v_referencia text := nullif(trim(coalesce(p_referencia, '')), '');
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para cobrar cuentas';
  end if;
  if p_metodo not in ('efectivo', 'clip') then
    raise exception 'Método de pago inválido';
  end if;
  if p_metodo = 'clip' and v_referencia is null then
    raise exception 'Escribe la referencia del Clip';
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
      propina_clip = propina_clip + case when p_metodo = 'clip' then v_propina else 0 end,
      clip_referencia = case when p_metodo = 'clip' then v_referencia else clip_referencia end
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
    jsonb_build_object(
      'metodo_pago', p_metodo,
      'propina', v_propina,
      'referencia', v_referencia,
      'saldo', greatest(v_total - v_pagado, 0)
    )
  );
  return jsonb_build_object(
    'total', v_total,
    'pagado', v_pagado,
    'saldo', greatest(v_total - v_pagado, 0),
    'cerrada', v_pagado + 0.009 >= v_total
  );
end;
$$;

create or replace function public.caja_aplicar_descuento(
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
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para aplicar descuentos';
  end if;
  if v_motivo is null then
    raise exception 'Escribe el motivo del descuento';
  end if;
  if not v_quitar then
    if p_tipo not in ('monto', 'porcentaje') or p_valor <= 0
       or (p_tipo = 'porcentaje' and p_valor > 100) or p_valor > 100000 then
      raise exception 'Descuento inválido';
    end if;
  end if;
  select c.mesa_id into v_mesa
  from public.cuentas c
  where c.id = p_cuenta and c.estado in ('abierta', 'por_cobrar')
  for update;
  if v_mesa is null then
    raise exception 'La cuenta ya no está abierta';
  end if;
  if p_item is not null then
    select i.cantidad * i.precio_unitario, i.nombre into v_base, v_nombre
    from public.comanda_items i
    join public.comandas co on co.id = i.comanda_id
    where i.id = p_item and co.cuenta_id = p_cuenta
    for update of i;
    if v_base is null then
      raise exception 'Artículo no encontrado en la cuenta';
    end if;
    if p_tipo = 'monto' and p_valor > v_base then
      raise exception 'El descuento supera el importe del artículo';
    end if;
    v_monto := public.calcular_descuento(v_base, p_tipo, p_valor);
    update public.comanda_items
    set descuento_tipo = p_tipo, descuento_valor = p_valor
    where id = p_item;
  else
    v_base := public.cuenta_subtotal_neto(p_cuenta);
    if p_tipo = 'monto' and p_valor > v_base then
      raise exception 'El descuento supera el total de la cuenta';
    end if;
    v_monto := public.calcular_descuento(v_base, p_tipo, p_valor);
    update public.cuentas
    set descuento_tipo = p_tipo, descuento_valor = p_valor
    where id = p_cuenta;
  end if;
  perform public.registrar_accion(
    'aplicar_descuento', v_mesa, p_cuenta, null, v_monto,
    jsonb_build_object('tipo', p_tipo, 'valor', p_valor, 'motivo', v_motivo, 'articulo', v_nombre, 'origen', 'caja')
  );
  return public.cuenta_total(p_cuenta);
end;
$$;

create or replace function public.devolver_cuenta(
  p_cuenta uuid, p_motivo text, p_es_prueba boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_mesa uuid;
  v_total numeric;
  v_motivo text := nullif(trim(coalesce(p_motivo, '')), '');
begin
  if not public.tiene_rol(array['caja', 'admin']::text[]) then
    raise exception 'No autorizado para devolver cuentas';
  end if;
  if v_motivo is null then
    raise exception 'Escribe el motivo de la devolución';
  end if;
  select c.mesa_id, c.total into v_mesa, v_total
  from public.cuentas c
  join public.mesas m on m.id = c.mesa_id
  where c.id = p_cuenta
    and c.estado = 'pagada'
    and m.es_prueba = coalesce(p_es_prueba, false)
  for update of c;
  if v_mesa is null then
    raise exception 'Solo se puede devolver una cuenta ya cobrada';
  end if;
  update public.cuentas
  set estado = 'anulada',
      motivo_anulacion = 'Devolución: ' || v_motivo,
      cerrada_at = now()
  where id = p_cuenta;
  perform public.refrescar_estado_mesa(v_mesa);
  perform public.registrar_accion(
    'anular_cuenta', v_mesa, p_cuenta, null, v_total,
    jsonb_build_object('devolucion', true, 'motivo', v_motivo)
  );
end;
$$;

revoke all on function public.pago_cuenta(uuid, text, numeric, numeric, boolean, text) from public, anon, authenticated;
revoke all on function public.caja_aplicar_descuento(uuid, uuid, text, numeric, text) from public, anon, authenticated;
revoke all on function public.devolver_cuenta(uuid, text, boolean) from public, anon, authenticated;
grant execute on function public.pago_cuenta(uuid, text, numeric, numeric, boolean, text) to authenticated;
grant execute on function public.caja_aplicar_descuento(uuid, uuid, text, numeric, text) to authenticated;
grant execute on function public.devolver_cuenta(uuid, text, boolean) to authenticated;

commit;
