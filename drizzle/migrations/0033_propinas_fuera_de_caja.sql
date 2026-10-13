begin;

-- Las propinas siguen registradas en la cuenta, pero no forman parte del efectivo esperado.

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
  v_gastos numeric;
  v_prestamos numeric;
  v_cobrados numeric;
  v_esperado numeric;
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
  select coalesce(sum(monto), 0) into v_gastos
  from public.caja_gastos
  where fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false);
  select coalesce(sum(monto), 0) into v_prestamos
  from public.caja_prestamos
  where fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false);
  select coalesce(sum(monto), 0) into v_cobrados
  from public.caja_prestamos
  where liquidado_fecha = p_fecha and es_prueba = coalesce(p_es_prueba, false);
  v_esperado := p_fondo + v_efectivo - v_gastos - v_prestamos + v_cobrados;
  v_diff := p_contado - v_esperado;
  insert into public.cortes_caja(
    fecha, fondo, efectivo_sistema, clip_sistema, propinas, efectivo_contado, diferencia, notas, es_prueba,
    gastos, prestamos, prestamos_cobrados
  ) values (
    p_fecha, p_fondo, v_efectivo, v_clip, v_propina, p_contado, v_diff,
    nullif(trim(coalesce(p_notas, '')), ''), p_es_prueba, v_gastos, v_prestamos, v_cobrados
  ) returning id into v_id;
  perform public.caja_guardar_fondo(p_fecha, p_fondo, p_es_prueba);
  perform public.registrar_accion(
    'corte_caja', null, null, null, v_diff,
    jsonb_build_object('fecha', p_fecha, 'fondo', p_fondo, 'contado', p_contado, 'esperado', v_esperado, 'es_prueba', p_es_prueba)
  );
  return jsonb_build_object(
    'id', v_id, 'efectivo', v_efectivo, 'clip', v_clip,
    'propina_efectivo', v_propina, 'gastos', v_gastos,
    'prestamos', v_prestamos, 'prestamos_cobrados', v_cobrados,
    'esperado', v_esperado, 'diferencia', v_diff
  );
end;
$$;

commit;
