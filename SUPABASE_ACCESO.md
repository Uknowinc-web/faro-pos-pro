# Acceso y aprobación de aparatos

Liga del POS: https://tacos-el-faro.vercel.app/
Panel: https://tacos-el-faro.vercel.app/admin-accesos.html

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
obtienen acceso al POS sin un rol autorizado.

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
21. `drizzle/migrations/0020_eliminar_dispositivo.sql`.
22. `drizzle/migrations/0021_menu_especiales_y_gaonera.sql`.

Si la base ya tiene algunas aplicadas, ejecuta solo las que faltan, en orden.
No reejecutes una migración ya aplicada.

La migración 0011 ya se aplicó en el proyecto Supabase de producción. Se
generaron tres códigos aleatorios y se verificó que los RPC existan y que ni
`anon` ni `authenticated` puedan leer directamente la tabla. Consulta y
comparte los códigos desde el panel de administración.

La migración **0012** añade el panel de operación en vivo y la bitácora por
dispositivo. Crea `audit_acciones`, instrumenta cobros/anulaciones/comandas,
expone `panel_operacion_vivo` y `listar_auditoria_admin`, y añade
`audit_acciones` a Realtime. Tras aplicarla, confirma en **Database →
Publications → supabase_realtime** que la tabla aparezca.

La migración **0013** agrega la pestaña **Gestión**: catálogo, mesas, edición de
artículos en cuentas abiertas, empleados/PIN, asistencia y ventas por mesero.
El PIN de autenticación se valida con hash; las migraciones anteriores también conservan un campo `pin_texto` para administración. Eliminarlo requiere una actualización coordinada del panel y queda como mejora pendiente. Ejecuta 0013 después de 0012 y antes de usar el HTML que pide PIN.

La migración **0014** separa Postres y Bebidas y exige sabor de agua, tamaño de
horchata/cebada y ToniCol o Titan.

La migración **0015** asigna el orden de las mesas automáticamente.

La migración **0016** cambia el registro de empleados y permite a Caja editar
artículos de cuentas abiertas.

La migración **0017** limita la unicidad de nombre y PIN a cada área.

La migración **0018** hace que el PIN lo asigne solo administración y guarda el
responsable en la bitácora.

La migración **0019** agrega descuentos, promociones y productos más vendidos.

La migración **0020** permite eliminar un dispositivo desde Accesos.

La migración **0021** mueve torta y hamburguesa a Especiales, quita la mezcla
de la papa especial y permite costra de queso (+$15) solo en Gaonera.

## Configurar Authentication

En **Supabase Dashboard → Authentication → Sign In / Providers**:

1. Habilitar **Anonymous Sign-Ins**. Crea identidades técnicas para los
   aparatos; no concede permisos de datos.
2. El correo y la contraseña solo se usan en el panel privado de administración.
3. La aplicación debe servirse por HTTPS.

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

Abre https://tacos-el-faro.vercel.app/admin-accesos.html e inicia sesión con esa
cuenta. Solo una cuenta cuyo rol en `staff_roles` sea `admin` puede ver,
aprobar, rechazar o revocar aparatos. No uses esa sesión para operar en un
aparato de trabajo.

## Aprobar cada aparato

1. En el aparato de trabajo, abre https://tacos-el-faro.vercel.app/ y escribe un
   nombre reconocible (por ejemplo, `Tablet cocina`) y el código del puesto.
2. Supabase crea una identidad anónima y la pantalla espera aprobación. Aún no
   puede consultar mesas, cuentas, comandas ni ejecutar RPC.
3. Desde tu dispositivo, abre el panel e inicia sesión con la cuenta admin.
4. Comprueba el nombre y puesto de la solicitud con el aparato físico. Aprueba
   únicamente el dispositivo correcto.
5. El aparato entra al POS. Al recargar vuelve a pedir su código.

Si alguien borra los datos del navegador, Supabase crea otro UID y se requiere
una nueva aprobación. Usa **Revocar acceso** si se pierde o reemplaza un aparato.

## Seguridad que permanece activa

- El rol del puesto es una asignación por UID, no una decisión basada solo en
  el código ni en datos locales del navegador.
- Una identidad anónima sin fila autorizada en `staff_roles` no recibe datos.
- El panel verifica `admin` tanto en la interfaz como en las RPC.
- La migración 0004 valida catálogo, modificadores y precios en el servidor.
- Las migraciones 0007–0008 separan las mesas de ensayo de las reales.
- Mesero no consulta cuentas; cocina solo actualiza estados permitidos.

La clave `publishable` (o la clave pública heredada `anon`) puede estar en el
navegador. **Nunca** coloques `service_role`, claves secretas ni la contraseña
de PostgreSQL en Vercel, en el HTML o en el repositorio.

## Verificación posterior

En SQL Editor:

```sql
select
  has_table_privilege('anon', 'public.mesas', 'select') as anon_lee_mesas,
  has_table_privilege('anon', 'public.cuentas', 'select') as anon_lee_cuentas,
  has_table_privilege('anon', 'public.solicitudes_puesto', 'select') as anon_lee_solicitudes;
```

Los tres deben ser `false`.

## Permisos por puesto

| Rol | Lecturas | Operaciones |
| --- | --- | --- |
| `mesero` | Mesas, comandas y artículos | Enviar comanda |
| `cocina` | Mesas, comandas y artículos | Avanzar comandas pendiente → preparación → listo |
| `caja` | Mesas, cuentas, comandas y artículos | Solicitar cuenta, cobrar y anular |
| `admin` | Todas las lecturas | Todas las operaciones y administrar aparatos |


## Migraciones posteriores a 0021

El repositorio contiene migraciones hasta `0039`. Si Supabase no está actualizado, revisa y aplica, en orden, solo las que falten:

- `0022_aparato_y_empleado_separados.sql`
- `0023_admin_nombre_baja_y_catalogo.sql`
- `0024_cerrar_mesa_y_vigencia.sql`
- `0025_servicio_turno.sql`
- `0026_soltar_mesa_sin_orden.sql`
- `0027_quitar_comanda_y_mesa.sql`
- `0028_borrar_mesa_y_cuentas.sql`
- `0029_borrar_mesa_sin_bloqueo.sql`
- `0030_caja_cambio_descuento_devolucion.sql`
- `0031_servicio_inventario_factura.sql`
- `0032_caja_inventario_real.sql`
- `0033_propinas_fuera_de_caja.sql`
- `0034_horario_ingreso_empleados.sql`
- `0035_limite_nombre_admin.sql`
- `0036_quitar_categoria_tortas.sql`
- `0037_asistencia_por_dia.sql`
- `0038_inventario_por_sabor.sql`
- `0039_restringir_rpc_inventario_y_caja.sql`

**No ejecutes de nuevo una migración ya aplicada.** La 0039 cambia permisos de funciones existentes; pruébala primero en staging o en una copia de la base.

### Verificar la corrección 0039

Después de aplicar 0039 en una base de pruebas, ejecuta `drizzle/tests/0039_rpc_permissions.sql`. La prueba usa un UID ficticio sin rol de Faro, comprueba que las RPC sensibles devuelvan error de autorización y valida que `authenticated` y `anon` no puedan ejecutar directamente `descontar_producto`. Termina con `ROLLBACK`.

En la consulta de privilegios, es esperado que `authenticated_puede_ejecutar` siga en `true` para las RPC protegidas internamente por rol, pero estas deben rechazar identidades sin autorización de Faro. Para `descontar_producto`, tanto `anon_puede_ejecutar` como `authenticated_puede_ejecutar` deben ser `false`.
