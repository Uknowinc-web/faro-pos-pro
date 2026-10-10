# Acceso y aprobación de aparatos

El personal no necesita correo ni contraseña. Cada aparato crea una identidad
anónima individual de Supabase al solicitar acceso; esa identidad no puede leer
ni operar el POS mientras el administrador no la apruebe. La aprobación asigna
al UID concreto un único rol de puesto. RLS y las RPC siguen comprobando ese
rol en PostgreSQL: los PIN `101`, `202` y `303` solo identifican mesero, cocina
y caja, respectivamente, y no son credenciales de servidor.

## Estado del proyecto conectado

En el proyecto Supabase utilizado para el piloto, las migraciones 0006–0008 ya
se aplicaron y se verificaron la tabla de solicitudes, las 13 mesas de prueba y
las RPC con validación de modo. **Anonymous Sign-Ins** y **Allow new users to
sign up** están habilitados para permitir el acceso de los dispositivos. La
opción general de registro también permite crear cuentas por correo; estas no
obtienen acceso al POS sin un rol autorizado. Supabase recomienda añadir CAPTCHA
a los accesos anónimos para reducir abuso y crecimiento de usuarios; intégralo
antes de habilitarlo.

## Aplicar migraciones

En el SQL Editor del proyecto Supabase, ejecutar una vez y en orden:

1. `drizzle/migrations/0000_migration.sql` (solo en una base nueva).
2. `drizzle/migrations/0001_desactivar_mesa_barra.sql`.
3. `drizzle/migrations/0002_unificar_estacion_cocina.sql`.
4. `drizzle/migrations/0003_restringir_acceso_a_personal.sql`.
5. `drizzle/migrations/0004_validar_precios_en_servidor.sql`.
6. `drizzle/migrations/0005_restringir_consulta_de_caja.sql`.
7. `drizzle/migrations/0006_aprobar_puestos_sin_correo.sql`.
8. `drizzle/migrations/0007_modo_prueba_aislado.sql`.
9. `drizzle/migrations/0008_validar_modo_en_operaciones.sql`.
10. `drizzle/migrations/0009_responsable_de_mesa_y_sugerencias.sql`.
11. `drizzle/migrations/0010_crear_mesas_desde_servicio.sql`.

En el proyecto Faro conectado, 0009 y 0010 ya se aplicaron en ese orden desde el
SQL Editor. Se verificó que existan las tablas y RPC, que RLS esté habilitado en
las tablas nuevas, que ambas tablas estén en `supabase_realtime`, que el puesto
`authenticated` pueda ejecutar `crear_mesa` y que ya no tenga inserción directa
en `mesas`. Antes de desplegar la versión del HTML que las utiliza, completar
las pruebas de aceptación con aparatos autorizados. Para repetir estos cambios
en otra base, hacer un respaldo antes de migrar. El repositorio no incluye un
runner de migraciones; el SQL Editor es el procedimiento manual. La 0006 habilita solicitudes de aparato y aprobación
administrativa; no concede acceso a los aparatos pendientes. La 0007 crea
mesas reservadas `PRUEBA · ...` y obliga a que el servidor rechace una comanda
que intente enviar una mesa de prueba como venta real o viceversa. La 0008
aplica la misma validación al estado de cocina y a todas las operaciones de
caja, para impedir que el cliente use un identificador de otro modo.
La 0009 asigna atómicamente cada mesa al primer mesero que la abre y exige que
solo él envíe comandas. Otro mesero puede mandar una sugerencia de artículos;
el responsable la acepta o rechaza. Al cobrar o anular la cuenta se libera al
responsable de la mesa y se rechazan sugerencias pendientes.
La 0010 permite agregar mesas únicamente a personal de servicio autorizado; la
función valida el nombre y asigna automáticamente el área de prueba u operación.

## Configurar Authentication

En **Supabase Dashboard → Authentication → Sign In / Providers**:

1. Habilitar **Anonymous Sign-Ins**. Esto permite crear identidades técnicas
   individuales para los aparatos, no concede permisos de datos.
2. Mantener deshabilitado **Allow new users to sign up** si se desea. La
   creación de identidades anónimas se controla por separado en el proveedor.
3. No habilitar proveedores públicos de correo para el personal. El correo y
   contraseña solo se usan en el panel privado de administración.
4. Revisa los límites de tasa de Authentication. Si activas CAPTCHA para
   Anonymous Sign-Ins, integra su token en la aplicación antes de habilitarlo;
   las solicitudes pendientes no leen datos, pero un CAPTCHA sin integrar
   bloquearía el acceso de los aparatos.

La aplicación necesita que el sitio esté servido por HTTPS para operar de
forma segura.

## Preparar tu cuenta administradora

La cuenta del Dashboard de Supabase no es automáticamente una cuenta de Faro
POS. Crea o confirma una cuenta Auth que tú controles en
**Authentication → Users**, copia su UUID y asígnale el rol `admin` una sola vez
desde SQL Editor:

```sql
insert into public.staff_roles (user_id, role)
values ('UUID-DE-TU-CUENTA-AUTH', 'admin')
on conflict (user_id) do update set role = excluded.role;
```

Abre `https://faro-pos-pro.vercel.app/admin-accesos.html` e inicia sesión con esa
cuenta. Solo una cuenta cuyo rol en `staff_roles` sea `admin` puede ver,
aprobar, rechazar o revocar aparatos. No uses esa sesión para operar en un
aparato de trabajo.

## Aprobar cada aparato

1. En el aparato de trabajo, abre la liga normal y escribe un nombre reconocible
   (por ejemplo, `Tablet cocina`) y el PIN del puesto.
2. Supabase crea una identidad anónima única y la pantalla muestra que espera
   aprobación. Aún no puede consultar mesas, cuentas, comandas ni ejecutar RPC.
3. Desde tu dispositivo, abre el panel de administración e inicia sesión con
   tu cuenta administradora.
4. Comprueba el nombre y puesto de la solicitud con el aparato físico. Aprueba
   únicamente el dispositivo correcto. La aprobación queda fija a ese UID y
   puesto; el personal no vuelve a ingresar correo.
5. El aparato entra automáticamente al POS. Al recargar la liga vuelve a pedir
   su PIN. Su sesión y puesto quedan guardados en ese navegador.

Si alguien borra los datos del navegador, cambia de perfil o reinstala el
navegador, Supabase crea otro UID y se requiere una nueva aprobación. Usa
**Revocar acceso** en el panel si se pierde o reemplaza un aparato; la identidad
revocada pierde el rol del servidor aunque todavía conserve su sesión local.

## Seguridad que permanece activa

- El rol del puesto es una asignación por UID, no una decisión basada en el PIN
  ni en datos locales del navegador.
- Una identidad anónima sin fila autorizada en `staff_roles` no recibe datos ni
  puede ejecutar operaciones de negocio. Solo puede registrar su solicitud
  pendiente, que tampoco incluye credenciales ni información del POS.
- El panel verifica `admin` tanto en la interfaz como en las RPC. El navegador
  no contiene claves privilegiadas.
- La migración 0003 retira los permisos de tablas y RPC al rol PostgreSQL `anon`;
  la identidad anónima de Supabase obtiene un JWT `authenticated`, pero solo
  adquiere las políticas del puesto después de una aprobación explícita.
- La migración 0004 valida catálogo, modificadores y precios en el servidor.
  La 0005 limita la lectura de cuentas a caja y administración.
- Las migraciones 0007–0008 separan las mesas de ensayo, filtran cuentas/comandas
  por modo y hacen que el servidor rechace operaciones en mesas del modo opuesto.
- Mesero no consulta cuentas; cocina solo actualiza estados permitidos; todas
  las operaciones vuelven a comprobar el rol en PostgreSQL.

La clave `publishable` (o la clave pública heredada `anon`) puede estar en el
navegador. **Nunca** coloques `service_role`, claves secretas ni la contraseña
de PostgreSQL en Vercel como variables `VITE_*`, en el HTML o en el repositorio.

## Verificación posterior

En SQL Editor, las consultas del rol PostgreSQL `anon` deben seguir devolviendo
`false`; la tabla de solicitudes tampoco debe tener acceso directo:

```sql
select
  has_table_privilege('anon', 'public.mesas', 'select') as anon_lee_mesas,
  has_table_privilege('anon', 'public.cuentas', 'select') as anon_lee_cuentas,
  has_table_privilege('anon', 'public.solicitudes_puesto', 'select') as anon_lee_solicitudes,
  has_function_privilege('anon', 'public.enviar_comanda(uuid,text,jsonb,text,boolean)', 'execute') as anon_envia_comanda,
  has_function_privilege('anon', 'public.resolver_solicitud_puesto(uuid,boolean)', 'execute') as anon_aprueba;
```

Prueba el flujo completo: una identidad de aparato sin aprobar no debe leer
datos ni operar; la solicitud debe aparecer únicamente en el panel de admin;
aprobada, solo debe ver el área y los datos de su rol; rechazada o revocada no
debe operar. Repetir la prueba para mesero, cocina y caja.

## Permisos por puesto

| Rol | Lecturas | Operaciones |
| --- | --- | --- |
| `mesero` | Mesas, comandas y artículos | Enviar comanda |
| `cocina` | Mesas, comandas y artículos | Avanzar comandas pendiente → preparación → listo |
| `caja` | Mesas, cuentas, comandas y artículos | Crear mesa, solicitar cuenta, cobrar y anular |
| `admin` | Todas las lecturas | Todas las operaciones anteriores y administrar aparatos |
