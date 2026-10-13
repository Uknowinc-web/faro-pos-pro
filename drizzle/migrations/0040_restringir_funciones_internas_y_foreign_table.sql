-- 0040: reduce la superficie de ejecución pública y fija search_path.
-- No cambia datos operativos ni modifica las políticas de acceso de las tablas.
begin;

-- La función valida admin dentro de su cuerpo; no debe ser invocable por anon.
revoke all on function public.admin_listar_catalogo() from public, anon;
grant execute on function public.admin_listar_catalogo() to authenticated, service_role;

-- Solo se ejecuta desde el trigger consumir_receta_al_vender.
-- Revocar EXECUTE a clientes no impide que el trigger existente se dispare.
revoke all on function public.aplicar_consumo_receta() from public, anon, authenticated;

-- Función de evento DDL, no una RPC de aplicación.
revoke all on function public.rls_auto_enable() from public, anon, authenticated, service_role;

-- Esta función solo usa operaciones built-in; fija un search_path inmutable.
alter function public.calcular_descuento(numeric, text, numeric)
  set search_path = pg_catalog;

-- Foreign table de integración sin referencias en el código del POS.
-- Retirar acceso directo a los roles expuestos por la API; conservar propietario.
revoke all on foreign table public."usersSegur" from public, anon, authenticated;

commit;
