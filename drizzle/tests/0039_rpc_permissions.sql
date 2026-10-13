-- Smoke tests for migration 0039.
-- Run in Supabase SQL Editor against a TEST/STAGING database after 0039.
-- The transaction is rolled back. It uses a made-up anonymous Auth identity
-- without a row in public.staff_roles and should never touch production data.
begin;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-4111-8111-111111111111', true);
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated","is_anonymous":true}',
  true
);

do $$
declare
  v_sql text;
begin
  foreach v_sql in array array[
    'select * from public.listar_inventario()',
    'select * from public.listar_inventario_variantes()',
    'select public.listar_insumos()',
    'select public.listar_recetas()',
    'select public.listar_movimientos()',
    'select public.caja_fondo_del_dia(current_date, false)',
    'select public.caja_listar_empleados()',
    'select public.caja_listar_prestamos(current_date, false)',
    'select public.caja_listar_gastos(current_date, false)'
  ]
  loop
    begin
      execute v_sql;
      raise exception 'TEST FAILED: una identidad anonima sin rol pudo ejecutar: %', v_sql;
    exception
      when sqlstate 'P0001' then
        if sqlerrm like 'TEST FAILED:%' then
          raise;
        end if;
        if sqlerrm not like 'No autorizado%'
          and sqlerrm not like 'Solo administracion%'
          and sqlerrm not like 'Solo administración%' then
          raise;
        end if;
    end;
  end loop;

  if has_function_privilege(
    'authenticated',
    'public.descontar_producto(text,numeric,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'TEST FAILED: authenticated conserva EXECUTE en descontar_producto';
  end if;

  if has_function_privilege(
    'anon',
    'public.descontar_producto(text,numeric,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'TEST FAILED: anon conserva EXECUTE en descontar_producto';
  end if;
end;
$$;

rollback;
