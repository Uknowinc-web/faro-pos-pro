-- Segunda capa de endurecimiento: funciones internas y search_path.
-- Los triggers ejecutan sus funciones sin requerir EXECUTE del rol de la sesión.
REVOKE EXECUTE ON FUNCTION public.aplicar_consumo_receta() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;

-- La función es aritmética pura; fijar search_path elimina la advertencia del linter.
ALTER FUNCTION public.calcular_descuento(numeric, text, numeric)
  SET search_path = pg_catalog, public;
