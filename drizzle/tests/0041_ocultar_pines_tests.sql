-- Smoke tests estáticos para la migración 0041.
-- Ejecutar después de 0041 en una base de pruebas. No modifica datos.
do $$
declare
  v_employee_def text;
  v_request_def text;
begin
  select pg_get_functiondef('public.admin_listar_empleados()'::regprocedure)
    into v_employee_def;
  select pg_get_functiondef('public.listar_solicitudes_puesto()'::regprocedure)
    into v_request_def;

  if v_employee_def is null or position('null::text' in lower(v_employee_def)) = 0 then
    raise exception 'admin_listar_empleados debe devolver PIN nulo';
  end if;
  if v_request_def is null or position('null::text' in lower(v_request_def)) = 0 then
    raise exception 'listar_solicitudes_puesto debe devolver PIN nulo';
  end if;
  if position('e.pin_texto' in lower(v_employee_def)) > 0 then
    raise exception 'admin_listar_empleados aún referencia pin_texto en su definición';
  end if;
  if position('s.pin_texto' in lower(v_request_def)) > 0
     or position('e.pin_texto' in lower(v_request_def)) > 0 then
    raise exception 'listar_solicitudes_puesto aún referencia PIN legible';
  end if;
end $$;
