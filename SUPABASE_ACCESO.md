# Acceso privado a Supabase

La autorización se impone en PostgreSQL; ocultar botones o proteger solo las
rutas del navegador no protege los datos. La migración
[`0003_restringir_acceso_a_personal.sql`](./drizzle/migrations/0003_restringir_acceso_a_personal.sql)
retira el acceso de `anon`, requiere un JWT autenticado y asigna permisos por rol.
La función de autorización también rechaza los JWT de usuarios anónimos de
Supabase Auth, aunque tengan una sesión y un UID.

## Aplicar migraciones

En el SQL Editor del proyecto Supabase, ejecutar una vez y en orden:

1. `drizzle/migrations/0000_migration.sql` (solo en una base nueva).
2. `drizzle/migrations/0001_desactivar_mesa_barra.sql`.
3. `drizzle/migrations/0002_unificar_estacion_cocina.sql`.
4. `drizzle/migrations/0003_restringir_acceso_a_personal.sql`.
5. `drizzle/migrations/0004_validar_precios_en_servidor.sql`.
6. `drizzle/migrations/0005_restringir_consulta_de_caja.sql`.

Si la base ya existe y las migraciones 0000–0002 ya se aplicaron, ejecutar solo
las migraciones que aún no se hayan aplicado (en este proyecto: 0004 y 0005).
Hacer un respaldo antes de migrar. El repositorio no incluye un runner
de migraciones configurado, así que el SQL Editor es el procedimiento manual.
La 0004 comprueba IDs, nombres, modificadores y precios de cada artículo en el
servidor; rechaza precios manipulados antes de insertar la comanda.

La 0003 elimina todas las políticas previas de estas tablas y las reemplaza;
la 0005 limita la lectura de cuentas a `caja` y `admin`. Mesero obtiene el
estado de mesas y sus comandas sin consultar `cuentas`.
Por ello, se debe revisar cualquier política adicional propia que se quiera
conservar y recrearla con las mismas comprobaciones de rol. `anon` no recibe
permisos de tablas, secuencias ni funciones RPC. Personal autenticado solo
puede leer las tablas necesarias para su flujo; las escrituras pasan por RPC
que vuelve a comprobar el rol. Cocina cambia estados mediante
`actualizar_estado_comanda`.

## Deshabilitar cuentas anónimas y altas públicas

En Supabase Dashboard:

1. En **Authentication → Sign In / Providers**, deshabilitar el proveedor
   **Anonymous Sign-Ins**.
2. En **Authentication → Settings** (o **Configuration → Auth**, según la
   versión del Dashboard), deshabilitar **Allow new users to sign up**.
3. Crear o invitar únicamente cuentas del personal desde Authentication.
   No habilitar registro abierto para hacer funcionar el POS.
4. Asignar el rol de cada persona siguiendo la sección correspondiente abajo.
   El HTML conectado contiene inicio y cierre de sesión; las pantallas React del
   clon todavía no implementan autenticación.
5. Antes de operar, probar la pantalla HTML con una cuenta por rol y verificar
   que cada usuario solo vea sus áreas y complete las operaciones permitidas.

Los códigos locales 101, 202 y 303 no son autenticación ni sustituyen a
Supabase Auth. Cada aparato debe vincularse una sola vez con una cuenta del rol
correspondiente; el PIN solo abre su interfaz fija en ese navegador. No iniciar
sesión con una cuenta `admin` en los aparatos de trabajo.

La clave `publishable` (o la clave pública heredada `anon`) de Supabase es un
identificador para el cliente web, no una sesión ni una autorización. Puede
estar en el navegador únicamente porque RLS y los permisos de esta migración
cierran el acceso no autenticado. **Nunca** colocar `service_role`, claves
secretas ni la contraseña de PostgreSQL en Vercel como variables `VITE_*`, en
el HTML o en el repositorio. Las credenciales privilegiadas solo se usan en
entornos confiables de servidor/administración.

## Asignar un rol al personal

Cada usuario necesita exactamente un rol (`mesero`, `cocina`, `caja` o
`admin`). Tras crear la cuenta desde Dashboard, copiar su UUID desde la lista
de usuarios y ejecutar en el SQL Editor, sustituyendo el UUID:

```sql
insert into public.staff_roles (user_id, role)
values ('00000000-0000-0000-0000-000000000000', 'mesero')
on conflict (user_id) do update set role = excluded.role;
```

Este alta se hace con el SQL Editor como administrador del proyecto; no existe
una política para que el usuario se asigne o cambie su propio rol. Cambiar
`mesero` por el rol correspondiente. Para revocar acceso:

```sql
delete from public.staff_roles
where user_id = '00000000-0000-0000-0000-000000000000';
```

## Comprobación después de migrar

Ejecutar estas consultas en SQL Editor. Las cuatro comprobaciones de permisos
para `anon` deben ser `false`; también debe haber cero políticas cuyo rol
incluya `anon` en las tablas protegidas:

```sql
select
  has_table_privilege('anon', 'public.mesas', 'select') as anon_lee_mesas,
  has_table_privilege('anon', 'public.cuentas', 'select') as anon_lee_cuentas,
  has_function_privilege('anon', 'public.enviar_comanda(uuid,text,jsonb,text)', 'execute') as anon_envia_comanda,
  has_function_privilege('anon', 'public.cobrar_cuenta(uuid,text)', 'execute') as anon_cobra;

select schemaname, tablename, policyname, roles, cmd
from pg_policies
where schemaname = 'public'
  and tablename in ('staff_roles', 'mesas', 'cuentas', 'comandas', 'comanda_items')
  and 'anon' = any(roles);
```

Después comprobar cada flujo iniciando sesión con usuarios asignados a cada rol:
mesero envía; cocina prepara y marca lista; caja cobra/anula y consulta el corte.
Un usuario autenticado sin fila en `staff_roles` también debe recibir cero filas
y no poder ejecutar operaciones. Repetir las mismas peticiones sin sesión:
deben rechazarse.

## Permisos previstos

| Rol | Lecturas | Operaciones |
| --- | --- | --- |
| `mesero` | Mesas, comandas y artículos | Enviar comanda |
| `cocina` | Mesas, comandas y artículos | Avanzar comandas pendiente → preparación → listo |
| `caja` | Mesas, cuentas, comandas y artículos | Crear mesa, solicitar cuenta, cobrar y anular |
| `admin` | Todas las lecturas | Todas las operaciones anteriores |

La migración no incorpora una pantalla de administración de roles. Las cuentas
y roles se administran desde Supabase Dashboard y SQL Editor.
