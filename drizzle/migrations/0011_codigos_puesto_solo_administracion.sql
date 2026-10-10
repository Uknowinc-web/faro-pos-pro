begin;

create table if not exists public.codigos_puesto (
  role text primary key check (role in ('mesero', 'cocina', 'caja')),
  code text not null unique check (code ~ '^[0-9a-f]{8}$')
);

alter table public.codigos_puesto enable row level security;
revoke all on public.codigos_puesto from public, anon, authenticated;

insert into public.codigos_puesto (role, code)
select puestos.role, substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)
from (values ('mesero'), ('cocina'), ('caja')) as puestos(role)
on conflict (role) do nothing;

create or replace function public.validar_codigo_puesto(p_code text)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_role text;
begin
  if auth.uid() is null
     or (select auth.jwt()->>'is_anonymous') is distinct from 'true' then
    raise exception 'Se requiere una identidad anónima de aparato';
  end if;

  select c.role into v_role
  from public.codigos_puesto c
  where c.code = lower(trim(coalesce(p_code, '')))
    and trim(coalesce(p_code, '')) ~* '^[0-9a-f]{8}$';
  return v_role;
end;
$$;

create or replace function public.listar_codigos_puesto()
returns table (role text, code text)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede consultar los códigos de puesto';
  end if;

  return query
  select c.role, c.code
  from public.codigos_puesto c
  order by case c.role when 'mesero' then 1 when 'cocina' then 2 else 3 end;
end;
$$;

revoke all on function public.validar_codigo_puesto(text)
  from public, anon, authenticated;
revoke all on function public.listar_codigos_puesto()
  from public, anon, authenticated;
grant execute on function public.validar_codigo_puesto(text) to authenticated;
grant execute on function public.listar_codigos_puesto() to authenticated;

commit;
