-- Smoke tests for migration 0040.
-- Run in TEST/STAGING after migration 0040.
begin;

do $$
begin
  if has_function_privilege('anon', 'public.admin_listar_catalogo()', 'EXECUTE') then
    raise exception 'TEST FAILED: anon conserva EXECUTE en admin_listar_catalogo';
  end if;

  if has_function_privilege('authenticated', 'public.admin_listar_catalogo()', 'EXECUTE') is false then
    raise exception 'TEST FAILED: authenticated perdió EXECUTE en admin_listar_catalogo';
  end if;

  if has_function_privilege('anon', 'public.aplicar_consumo_receta()', 'EXECUTE') then
    raise exception 'TEST FAILED: anon conserva EXECUTE en aplicar_consumo_receta';
  end if;

  if has_function_privilege('authenticated', 'public.aplicar_consumo_receta()', 'EXECUTE') then
    raise exception 'TEST FAILED: authenticated conserva EXECUTE en aplicar_consumo_receta';
  end if;

  if has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE') then
    raise exception 'TEST FAILED: anon conserva EXECUTE en rls_auto_enable';
  end if;

  if has_function_privilege('authenticated', 'public.rls_auto_enable()', 'EXECUTE') then
    raise exception 'TEST FAILED: authenticated conserva EXECUTE en rls_auto_enable';
  end if;

  if has_table_privilege('anon', 'public."usersSegur"', 'SELECT') then
    raise exception 'TEST FAILED: anon conserva SELECT en usersSegur';
  end if;

  if has_table_privilege('authenticated', 'public."usersSegur"', 'SELECT') then
    raise exception 'TEST FAILED: authenticated conserva SELECT en usersSegur';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'calcular_descuento'
      and p.proconfig @> array['search_path=pg_catalog']
  ) then
    raise exception 'TEST FAILED: calcular_descuento no fija search_path';
  end if;
end;
$$;

rollback;
