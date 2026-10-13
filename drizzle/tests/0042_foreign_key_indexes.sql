-- Verifica que los índices de claves foráneas definidos en 0042 existan.
do $$
declare
  v_missing text;
begin
  with expected(table_name, index_name) as (values
    ('facturas','facturas_cuenta_id_idx'),
    ('caja_prestamos','caja_prestamos_empleado_id_idx'),
    ('recetas','recetas_insumo_id_idx'),
    ('inventario_movimientos','inventario_movimientos_insumo_id_idx'),
    ('comandas','comandas_cuenta_id_idx'),
    ('comandas','comandas_mesa_id_idx'),
    ('sugerencias_comanda','sugerencias_comanda_mesa_id_idx'),
    ('comanda_items','comanda_items_comanda_id_idx'),
    ('solicitudes_puesto','solicitudes_puesto_empleado_id_idx'),
    ('solicitudes_puesto','solicitudes_puesto_reviewed_by_idx'),
    ('audit_acciones','audit_acciones_comanda_id_idx'),
    ('audit_acciones','audit_acciones_cuenta_id_idx'),
    ('audit_acciones','audit_acciones_empleado_id_idx'),
    ('audit_acciones','audit_acciones_mesa_id_idx'),
    ('cuentas','cuentas_mesa_id_idx')
  )
  select string_agg(e.index_name, ', ' order by e.index_name)
  into v_missing
  from expected e
  where not exists (
    select 1 from pg_indexes p
    where p.schemaname='public' and p.tablename=e.table_name and p.indexname=e.index_name
  );
  if v_missing is not null then
    raise exception 'Faltan índices de FK de migración 0042: %', v_missing;
  end if;
end $$;
