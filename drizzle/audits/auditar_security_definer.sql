-- Auditoría de solo lectura para funciones SECURITY DEFINER y tablas RLS.
-- Ejecutar en Supabase SQL Editor; no crea ni modifica objetos.
-- Revisar cada resultado manualmente: heurísticas de texto no sustituyen una revisión de seguridad.

-- 1) Funciones SECURITY DEFINER, propietario, search_path, EXECUTE y señales de autorización.
with funcs as (
  select p.oid, n.nspname as schema_name, p.proname, p.proowner,
         pg_get_userbyid(p.proowner) as owner_name,
         pg_get_function_identity_arguments(p.oid) as identity_args,
         p.proconfig,
         pg_get_functiondef(p.oid) as definition,
         coalesce(p.proacl, acldefault('f', p.proowner)) as acl
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
)
select f.schema_name,
       f.proname,
       f.identity_args,
       f.owner_name,
       coalesce((select string_agg(c, ', ' order by c)
                 from unnest(f.proconfig) c where c like 'search_path=%'), '(search_path no fijado)') as search_path,
       coalesce((select string_agg(distinct r.rolname || ':' || x.privilege_type, ', ' order by r.rolname || ':' || x.privilege_type)
                 from unnest(f.acl) a
                 cross join lateral aclexplode(array[a]) x
                 left join pg_roles r on r.oid = x.grantee
                 where x.privilege_type = 'EXECUTE'
                   and (x.grantee = 0 or r.rolname in ('anon','authenticated','service_role'))),
                '(sin EXECUTE directo detectado para PUBLIC/roles API)') as api_execute_grants,
       (f.definition ilike '%tiene_rol(%') as mentions_tiene_rol,
       (f.definition ilike '%auth.uid()%') as mentions_auth_uid,
       (f.definition ilike '%auth.jwt()%') as mentions_auth_jwt,
       (f.definition ilike '%pin_texto%') as references_plaintext_pin,
       f.definition
from funcs f
order by f.proname, f.identity_args;

-- 2) Tablas con RLS activado pero sin políticas: validar si son intencionales.
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as force_rls
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','p')
  and c.relrowsecurity
  and not exists (
    select 1 from pg_policy pol where pol.polrelid = c.oid
  )
order by c.relname;

-- 3) Privilegios directos sobre foreign tables en public.
select c.relname as foreign_table,
       grantee.rolname as grantee,
       x.privilege_type,
       x.is_grantable
from pg_foreign_table ft
join pg_class c on c.oid = ft.ftrelid
join pg_namespace n on n.oid = c.relnamespace
cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x
left join pg_roles grantee on grantee.oid = x.grantee
where n.nspname = 'public'
order by c.relname, grantee.rolname, x.privilege_type;
