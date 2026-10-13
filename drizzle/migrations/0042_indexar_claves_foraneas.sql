begin;

-- Índices para claves foráneas detectadas sin índice cuyo primer campo sea la FK.
-- Son índices no únicos; no cambian la semántica ni los datos de negocio.
create index if not exists facturas_cuenta_id_idx on public.facturas (cuenta_id);
create index if not exists caja_prestamos_empleado_id_idx on public.caja_prestamos (empleado_id);
create index if not exists recetas_insumo_id_idx on public.recetas (insumo_id);
create index if not exists inventario_movimientos_insumo_id_idx on public.inventario_movimientos (insumo_id);
create index if not exists comandas_cuenta_id_idx on public.comandas (cuenta_id);
create index if not exists comandas_mesa_id_idx on public.comandas (mesa_id);
create index if not exists sugerencias_comanda_mesa_id_idx on public.sugerencias_comanda (mesa_id);
create index if not exists comanda_items_comanda_id_idx on public.comanda_items (comanda_id);
create index if not exists solicitudes_puesto_empleado_id_idx on public.solicitudes_puesto (empleado_id);
create index if not exists solicitudes_puesto_reviewed_by_idx on public.solicitudes_puesto (reviewed_by);
create index if not exists audit_acciones_comanda_id_idx on public.audit_acciones (comanda_id);
create index if not exists audit_acciones_cuenta_id_idx on public.audit_acciones (cuenta_id);
create index if not exists audit_acciones_empleado_id_idx on public.audit_acciones (empleado_id);
create index if not exists audit_acciones_mesa_id_idx on public.audit_acciones (mesa_id);
create index if not exists cuentas_mesa_id_idx on public.cuentas (mesa_id);

commit;
