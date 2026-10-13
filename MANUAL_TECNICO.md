# Tacos El Faro — Manual técnico

## 1. Dónde está el sistema

- **Código:** este repositorio (`Uknowinc-web/faro-pos-pro`).
- **App en uso:** https://tacos-el-faro.vercel.app/
- **Panel:** https://tacos-el-faro.vercel.app/admin-accesos.html
- **Base:** proyecto Supabase Faro.

La aplicación es HTML estático (`faro-pos-pro.html` y `admin-accesos.html`).
No hay build de React que mantener. El catálogo y las reglas de precio viven en
PostgreSQL (`catalogo_productos` y la función `validar_item_comanda`), no en un
archivo de TypeScript.

## 2. Esquema y seguridad

Las migraciones vigentes están en `drizzle/migrations`. En una base nueva,
ejecutar las migraciones disponibles **0000 a 0039 en orden**. En una base ya migrada, identificar primero las migraciones aplicadas y ejecutar solo las pendientes.

Resumen:

- **0003** cierra permisos a `anon`, define roles y protege las RPC.
- **0004** verifica producto, modificadores y precio en el servidor.
- **0005** limita las cuentas a caja y admin.
- **0006** solicitudes de aparato y aprobación sin correo.
- **0007–0008** modo de prueba aislado y validado en cada operación.
- **0009** responsable de mesa y sugerencias.
- **0010** crear mesas desde servicio.
- **0011** códigos de puesto solo visibles por admin.
- **0012** operación en vivo y bitácora.
- **0013** catálogo editable, PIN, asistencia, ventas por mesero.
- **0014** Postres y Bebidas separados; opciones de bebidas.
- **0015** orden automático de mesas.
- **0016–0018** PIN y bitácora con responsable.
- **0019** descuentos y promociones.
- **0020** eliminar dispositivo.
- **0021** torta y hamburguesa en Especiales; papa especial sin mezcla; costra
  de queso (+$15) solo en Gaonera.
- **0022** separa aparato y empleado. Aprobar un aparato no crea persona.
- **0023–0029** añaden administración de catálogo/empleados y operaciones de mesas/cuentas.
- **0030** añade referencias de Clip, pagos parciales, descuentos y devoluciones.
- **0031–0033** añaden operaciones de servicio, inventario de ingredientes y ajustes de caja/propinas.
- **0034–0037** añaden horario, controles administrativos y asistencia diaria.
- **0038** agrega inventario por variante/sabor.
- **0039** endurece las RPC de caja e inventario y elimina la ejecución directa del auxiliar de descuento.

**No uses fragmentos SQL sueltos para desplegar.** La fuente es cada archivo de
migración. Pasos detallados en [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md).

## 3. Flujo de un aparato

1. Abre https://tacos-el-faro.vercel.app/.
2. Indica el nombre del aparato (no de la persona) y el código de puesto.
3. Supabase crea una identidad anónima sin permisos.
4. Admin aprueba el aparato en el panel. Eso no crea un empleado.
5. El empleado, dado de alta en el panel con PIN, inicia turno en cualquier aparato de su área.

Los QR de [`QR_PUESTOS.html`](./QR_PUESTOS.html) solo abren la liga. No contienen
códigos ni roles.

Cada puesto muestra **Modo operación** o **Modo de prueba**. Los ensayos usan
mesas `PRUEBA · ...` y no deben mezclarse con tickets reales.

## 4. Entidades principales

El esquema inicial (0000) crea `mesas`, `cuentas`, `comandas` y
`comanda_items`, con RLS y RPC protegidas. Las migraciones posteriores añaden
catalogo, empleados, bitácora, descuentos y las validaciones de precio.

Para crear o actualizar una base, usa los archivos de migración completos, no
resúmenes.

## 5. Reglas de precio (servidor)

Definidas en `validar_item_comanda` (actualizada en 0021):

- Cada carne agregada después de la principal suma $10.
- La tripa como principal suma su recargo una sola vez ($5 en tacos, $10 en los
  demás que permiten mezcla).
- El queso en tacos suma $5.
- Mezcla permitida solo en los productos marcados (`permite_mezcla`). La papa
  especial ya no la permite (0021).
- Costra de queso (+$15) solo en Gaonera.
- Agua de sabor exige un sabor. Horchata/cebada exige tipo y tamaño. ToniCol
  exige ToniCol o Titan.

Si el precio que envía el navegador no coincide con el calculado, el servidor
rechaza la comanda.

## 6. Endurecimiento de permisos RPC

La migración `0039_restringir_rpc_inventario_y_caja.sql` corrige un riesgo: un usuario anónimo de Supabase Auth usa el rol SQL `authenticated`, por lo que conceder EXECUTE a ese rol no demuestra que sea un empleado autorizado. Las RPC protegidas por 0039 comprueban `tiene_rol(...)` antes de consultar datos sensibles.

La función `descontar_producto` es un auxiliar interno del trigger de consumo de inventario. La migración 0039 revoca su ejecución directa a `anon` y `authenticated`; el trigger debe seguir siendo el camino previsto para el descuento. Ejecuta `drizzle/tests/0039_rpc_permissions.sql` en una base de pruebas y comprueba que el trigger siga funcionando tras la corrección.

Esto no reemplaza una auditoría completa de todas las funciones `SECURITY DEFINER`. Toda función privilegiada nueva debe validar su rol de negocio dentro de la función y fijar un `search_path` seguro.
