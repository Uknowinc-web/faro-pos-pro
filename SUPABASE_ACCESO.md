# Acceso y aprobación de aparatos

El personal no necesita correo ni contraseña. Cada aparato crea una identidad
anónima individual de Supabase al solicitar acceso; esa identidad no puede leer
ni operar el POS mientras el administrador no la apruebe. La aprobación asigna
al UID concreto un único rol de puesto. RLS y las RPC siguen comprobando ese
rol en PostgreSQL. Los códigos se generan y validan en Supabase; solo una
cuenta administradora puede consultarlos en el panel privado. Un código
identifica el puesto, pero no concede permisos: cada dispositivo requiere
aprobación explícita.

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
12. `drizzle/migrations/0011_codigos_puesto_solo_administracion.sql`.
13. `drizzle/migrations/0012_panel_admin_operacion.sql`.
14. `drizzle/migrations/0013_admin_jornada_y_empleados.sql`.
15. `drizzle/migrations/0014_bebidas_postres_y_opciones.sql`.
16. `drizzle/migrations/0015_orden_automatico_de_mesas.sql`.
17. `drizzle/migrations/0016_registro_empleado_con_pin.sql`.
18. `drizzle/migrations/0017_pin_por_area_y_responsables.sql`.
19. `drizzle/migrations/0018_pin_por_admin_y_bitacora.sql`.
20. `drizzle/migrations/0019_descuentos_promociones_y_ventas.sql`.

La migración 0011 ya se aplicó en el proyecto Supabase de producción. Se
generaron tres códigos aleatorios y se verificó que los RPC existan y que ni
`anon` ni `authenticated` puedan leer directamente la tabla. Consulta y
comparte los códigos desde el panel de administración una vez que la nueva
versión esté desplegada.

La migración **0012** añade el panel de operación en vivo y la bitácora por
dispositivo. Hay que ejecutarla en el SQL Editor antes de usar las pestañas
Operación y Bitácora de [`admin-accesos.html`](./admin-accesos.html). Crea
`audit_acciones`, instrumenta cobros/anulaciones/comandas/reclamos, permite a
`admin` leer `mesa_responsables`, expone `panel_operacion_vivo` y
`listar_auditoria_admin`, y añade `audit_acciones` a Realtime. Tras aplicarla,
confirma en **Database → Publications → supabase_realtime** que la tabla
aparezca (si el `ALTER PUBLICATION` fallara por ya existir, no hace falta
repetirlo).

La migración **0013** agrega la pestaña **Gestión** al panel: catálogo de
productos y precios, mesas activas/inactivas, edición de artículos en cuentas
abiertas, administración de empleados/PIN, entradas y salidas, y ventas por
mesero. El PIN se almacena como hash; cada empleado solo puede tener un turno
abierto a la vez y debe coincidir con el puesto autorizado del aparato. La
migración también valida en el servidor los turnos de meseros, caja y cocina,
atribuye comandas a su mesero y publica el catálogo para actualizar el POS.
Ejecuta 0013 después de 0012 y antes de desplegar la nueva versión de
[`faro-pos-pro.html`](./faro-pos-pro.html) y [`admin-accesos.html`](./admin-accesos.html).
No despliegues el HTML nuevo antes de aplicar la migración: el inicio de turno
por PIN y las operaciones ya requieren sus funciones y tablas.

La migración **0014** separa la categoría "Postres y Bebidas" en **Postres** y
**Bebidas**, renombra los productos compartidos a "Horchata y cebada" y "ToniCol
y Titan", y hace que el servidor exija el sabor del agua de sabor, la bebida y
el tamaño (1 L o 1/2 L a mitad de precio) de horchata/cebada, y ToniCol o Titan.
Ejecútala después de 0013 y antes de desplegar la versión del POS que usa esas
opciones: el POS nuevo envía los nuevos nombres y modificadores, que el servidor
anterior rechazaría.

La migración **0015** elimina el orden manual de las mesas: `admin_guardar_mesa`
asigna a cada mesa nueva la posición siguiente dentro de su modo (prueba u
operación) y conserva la posición al editarla. Ejecútala después de 0014.

La migración **0016** cambia el registro de empleados: al solicitar acceso, cada
persona escribe su nombre y elige su PIN (4–8 dígitos, único entre empleados
activos). Al autorizar, el administrador crea al empleado y lo vincula al
aparato; puede ver el PIN, el aparato y el estado del turno. El PIN legible se
guarda en `pin_texto`, sin acceso directo (RLS cerrado) y solo lo devuelven las
RPC de administración. Los empleados anteriores no tienen PIN visible hasta
asignarles uno nuevo. También agrega `caja_editar_articulo_cuenta` para que Caja
cambie cantidades o quite artículos de cuentas abiertas. Ejecútala después de 0015.

La migración **0017** limita la unicidad de nombre y PIN a cada área (un mesero y un cocinero pueden compartirlos; dos del mismo puesto no), hace que el PIN se busque solo entre empleados del puesto del aparato y registra el correo de cada administrador como responsable en la bitácora. Ejecútala después de 0016.

La migración **0018** hace que el PIN lo asigne solo administración (la solicitud ya no lo recibe; sin PIN el POS muestra "Administración aún no te asigna un PIN"), impide nombres repetidos dentro de la misma área, crea `admin_perfiles` (nombre de bitácora por administrador), guarda `responsable` en `audit_acciones` y agrega `auditoria_rango` para filtrar por día, mes o año. Ejecútala después de 0017.

La migración **0019** agrega descuentos (`admin_aplicar_descuento`, por artículo o cuenta, en monto o porcentaje, solo administración y con registro en bitácora), la categoría «Promociones» para ofertas y combos (`admin_guardar_promocion`), `admin_productos_vendidos` y hace que `cobrar_cuenta` guarde el total con descuento. Ejecútala después de 0018.

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
La 0012 registra auditoría por dispositivo y alimenta el panel administrativo
de corte, piso, cocina y bitácora.

### Probar el panel de operación (0012)

1. Con cuenta `admin`, abre `admin-accesos.html` e inicia sesión.
2. En **Operación**, confirma corte del día (Monterrey), mesas con mesero y
   orden, y colas de cocina; alterna **Modo prueba** y verifica aislamiento.
3. Desde aparatos aprobados: reclamar mesa, enviar comanda, pasar a preparación,
   cobrar y anular. En **Bitácora** deben aparecer dispositivo, rol, acción y
   monto cuando aplique.
4. Con un usuario no admin (o anónimo), `panel_operacion_vivo` y
   `listar_auditoria_admin` deben fallar por autorización.
5. Después de aplicar 0013, crea un empleado de prueba y verifica que su PIN
   inicie/cierre turno en un aparato aprobado del puesto correcto; un PIN
   erróneo y un segundo turno simultáneo deben rechazarse.
6. Cambia el precio de un producto y confirma que el POS lo actualiza y que
   PostgreSQL rechaza el precio anterior. Edita una cuenta abierta y valida
   que el nuevo total coincida al cobrar.
7. Confirma entradas/salidas en Gestión y que las ventas de las comandas
   pagadas se atribuyan al mesero que inició el turno.

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
   (por ejemplo, `Tablet cocina`) y el código del puesto que te comparta
   administración.
2. Supabase crea una identidad anónima única y la pantalla muestra que espera
   aprobación. Aún no puede consultar mesas, cuentas, comandas ni ejecutar RPC.
3. Desde tu dispositivo, abre el panel de administración e inicia sesión con
   tu cuenta administradora.
4. Comprueba el nombre y puesto de la solicitud con el aparato físico. Aprueba
   únicamente el dispositivo correcto. La aprobación queda fija a ese UID y
   puesto; el personal no vuelve a ingresar correo.
5. El aparato entra automáticamente al POS. Al recargar la liga vuelve a pedir
   su código. Su sesión y puesto quedan guardados en ese navegador.

Si alguien borra los datos del navegador, cambia de perfil o reinstala el
navegador, Supabase crea otro UID y se requiere una nueva aprobación. Usa
**Revocar acceso** en el panel si se pierde o reemplaza un aparato; la identidad
revocada pierde el rol del servidor aunque todavía conserve su sesión local.

## Seguridad que permanece activa

- El rol del puesto es una asignación por UID, no una decisión basada solo en
  el código ni en datos locales del navegador.
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
