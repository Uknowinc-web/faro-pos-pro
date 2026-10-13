begin;

-- No devolver nunca el PIN en texto claro desde RPC administrativas.
-- Se conservan nombres/tipos de columnas para compatibilidad con el panel existente.
create or replace function public.admin_listar_empleados()
returns table (
  id uuid, nombre text, puesto text, activo boolean,
  asistencia_id uuid, entrada_at timestamptz, user_id uuid,
  pin text, aparato text, ultima_entrada_at timestamptz
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar empleados';
  end if;
  return query
  select e.id, e.nombre, e.puesto, e.activo, a.id, a.entrada_at, a.user_id,
         null::text,
         (select s.device_label from public.solicitudes_puesto s where s.empleado_id = e.id limit 1),
         (select max(h.entrada_at) from public.asistencias h where h.empleado_id = e.id)
  from public.empleados e
  left join public.asistencias a on a.empleado_id = e.id and a.salida_at is null
  order by e.activo desc, e.puesto, e.nombre;
end;
$$;

create or replace function public.listar_solicitudes_puesto()
returns table (
  user_id uuid,
  requested_role text,
  device_label text,
  requested_at timestamptz,
  status text,
  reviewed_at timestamptz,
  empleado_id uuid,
  empleado_nombre text,
  pin text,
  empleado_activo boolean,
  en_turno boolean,
  entrada_at timestamptz
)
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar solicitudes';
  end if;

  return query
  select s.user_id, s.role, s.device_label, s.requested_at, s.status, s.reviewed_at,
         s.empleado_id, coalesce(e.nombre, s.empleado_nombre),
         null::text, e.activo,
         a.id is not null, a.entrada_at
  from public.solicitudes_puesto s
  left join public.empleados e on e.id = s.empleado_id
  left join public.asistencias a on a.empleado_id = e.id and a.salida_at is null
  order by (s.status = 'pending') desc, s.requested_at desc;
end;
$$;

commit;
