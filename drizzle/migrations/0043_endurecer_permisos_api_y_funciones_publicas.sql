-- Faro POS Pro: endurecimiento de permisos SQL en producción.
-- Las operaciones de negocio se exponen mediante RPC con validación de rol.
-- Se conservan los privilegios SELECT existentes; se elimina DML directo y
-- privilegios estructurales de los roles de API en tablas del esquema public.

DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname = 'public'
  LOOP
    EXECUTE format(
      'REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE %I.%I FROM anon, authenticated',
      t.schemaname, t.tablename
    );
  END LOOP;
END
$$;

-- Evita que futuras tablas creadas por postgres hereden automáticamente
-- privilegios de escritura/alteración para roles expuestos por la API.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES
  FROM anon, authenticated;

-- Funciones internas o administrativas que no deben ser invocables como anon.
REVOKE EXECUTE ON FUNCTION public.admin_listar_catalogo() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.aplicar_consumo_receta() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon;

-- Reduce el riesgo de que futuras funciones públicas sean ejecutables por
-- cualquier rol por defecto. Las migraciones deben conceder EXECUTE de forma explícita.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
