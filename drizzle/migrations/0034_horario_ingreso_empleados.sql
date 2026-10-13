begin;

create table if not exists public.acceso_empleados (
  id integer primary key default 1 check (id = 1),
  abierto boolean not null default true,
  usa_horario boolean not null default false,
  abre time not null default time '10:00',
  cierra time not null default time '23:00',
  actualizado_at timestamptz not null default now()
);
alter table public.acceso_empleados enable row level security;
insert into public.acceso_empleados(id) values (1) on conflict (id) do nothing;

create or replace function public.ingreso_empleados_estado()
returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog, public
as $$
declare
  v public.acceso_empleados%rowtype;
  v_ahora time;
  v_en_horario boolean;
  v_motivo text := '';
  v_abierto boolean := true;
begin
  select * into v from public.acceso_empleados where id = 1;
  if v.id is null then
    return jsonb_build_object('abierto', true, 'interruptor', true, 'usa_horario', false, 'abre', '10:00', 'cierra', '23:00', 'motivo', '');
  end if;
  v_ahora := (now() at time zone 'America/Monterrey')::time;
  if v.cierra > v.abre then
    v_en_horario := v_ahora >= v.abre and v_ahora < v.cierra;
  else
    v_en_horario := v_ahora >= v.abre or v_ahora < v.cierra;
  end if;
  if not v.abierto then
    v_abierto := false;
    v_motivo := 'Administración cerró el ingreso de empleados.';
  elsif v.usa_horario and not v_en_horario then
    v_abierto := false;
    v_motivo := 'Fuera de horario. El ingreso de empleados es de '
      || to_char(v.abre, 'HH24:MI') || ' a ' || to_char(v.cierra, 'HH24:MI') || '.';
  end if;
  return jsonb_build_object(
    'abierto', v_abierto,
    'interruptor', v.abierto,
    'usa_horario', v.usa_horario,
    'abre', to_char(v.abre, 'HH24:MI'),
    'cierra', to_char(v.cierra, 'HH24:MI'),
    'motivo', v_motivo
  );
end;
$$;

create or replace function public.admin_guardar_acceso_empleados(
  p_abierto boolean, p_usa_horario boolean, p_abre text, p_cierra text
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_abre time;
  v_cierra time;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración controla el ingreso';
  end if;
  begin
    v_abre := p_abre::time;
    v_cierra := p_cierra::time;
  exception when others then
    raise exception 'Escribe el horario en formato HH:MM';
  end;
  if v_abre = v_cierra then
    raise exception 'La hora de apertura y la de cierre no pueden ser iguales';
  end if;
  update public.acceso_empleados
  set abierto = coalesce(p_abierto, true),
      usa_horario = coalesce(p_usa_horario, false),
      abre = v_abre,
      cierra = v_cierra,
      actualizado_at = now()
  where id = 1;
  perform public.registrar_accion(
    'editar_empleado', null, null, null, null,
    jsonb_build_object('ingreso_abierto', p_abierto, 'usa_horario', p_usa_horario, 'abre', p_abre, 'cierra', p_cierra)
  );
  return public.ingreso_empleados_estado();
end;
$$;

create or replace function public.bloquear_si_ingreso_cerrado()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v jsonb;
begin
  if public.tiene_rol(array['admin']::text[]) then
    return coalesce(new, old);
  end if;
  v := public.ingreso_empleados_estado();
  if coalesce((v->>'abierto')::boolean, true) then
    return coalesce(new, old);
  end if;
  raise exception '%', coalesce(nullif(v->>'motivo', ''), 'El ingreso de empleados está cerrado');
end;
$$;

drop trigger if exists ingreso_cerrado_asistencia on public.asistencias;
create trigger ingreso_cerrado_asistencia
before insert on public.asistencias
for each row execute function public.bloquear_si_ingreso_cerrado();

drop trigger if exists ingreso_cerrado_comanda on public.comandas;
create trigger ingreso_cerrado_comanda
before insert or update on public.comandas
for each row execute function public.bloquear_si_ingreso_cerrado();

drop trigger if exists ingreso_cerrado_item on public.comanda_items;
create trigger ingreso_cerrado_item
before insert or update or delete on public.comanda_items
for each row execute function public.bloquear_si_ingreso_cerrado();

drop trigger if exists ingreso_cerrado_cuenta on public.cuentas;
create trigger ingreso_cerrado_cuenta
before update on public.cuentas
for each row execute function public.bloquear_si_ingreso_cerrado();

revoke all on function public.ingreso_empleados_estado() from public, anon, authenticated;
revoke all on function public.admin_guardar_acceso_empleados(boolean, boolean, text, text) from public, anon, authenticated;
revoke all on function public.bloquear_si_ingreso_cerrado() from public, anon, authenticated;
grant execute on function public.ingreso_empleados_estado() to authenticated;
grant execute on function public.admin_guardar_acceso_empleados(boolean, boolean, text, text) to authenticated;

commit;
