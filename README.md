# Tacos El Faro

Sistema POS y KDS para la taquería El Faro (Monterrey, N.L.).

**Liga viva:** https://tacos-el-faro.vercel.app/

Panel de administración: https://tacos-el-faro.vercel.app/admin-accesos.html

> La liga antigua `faro-pos-pro.vercel.app` no existe (404). No usarla.

## Qué es este repositorio

Una sola aplicación:

| Archivo | Qué hace |
|---|---|
| `faro-pos-pro.html` | App de mesero, cocina y caja. Habla con Supabase. |
| `admin-accesos.html` | Panel: aprobar aparatos, catálogo, mesas, empleados, PIN, bitácora. |
| `index.html` | Redirige a `faro-pos-pro.html`. |
| `drizzle/migrations/` | Esquema de la base (0000 a 0039). Aplicar solo las pendientes y en orden. |
| `QR_PUESTOS.html` + `QR_*.svg` | Accesos imprimibles. Los tres QR abren la misma liga viva. |

La fuente de verdad de precios y reglas es la tabla `catalogo_productos` en Supabase, validada por las migraciones (sobre todo 0004, 0014 y 0021). El HTML no calcula precios de forma definitiva: el servidor los verifica.

## Migraciones (en orden)

- `0000` esquema inicial.
- `0001` indicador de mesa activa.
- `0002` unificar estación de cocina.
- `0003` cerrar acceso anónimo, RLS por rol, RPC autenticadas.
- `0004` validar catálogo, modificadores y precio en el servidor.
- `0005` mesero y cocina no leen cuentas.
- `0006` solicitudes de aparato y aprobación sin correo.
- `0007` modo de prueba aislado.
- `0008` validar modo en operaciones de cocina y caja.
- `0009` responsable de mesa y sugerencias.
- `0010` crear mesas desde servicio.
- `0011` códigos de puesto solo visibles por administración.
- `0012` operación en vivo y bitácora.
- `0013` catálogo editable, PIN, asistencia, ventas por mesero.
- `0014` Postres y Bebidas separados; sabores, tamaño, ToniCol/Titan.
- `0015` orden automático de mesas.
- `0016` registro de empleado con PIN; caja puede editar cuentas abiertas.
- `0017` nombre y PIN únicos por área.
- `0018` el PIN lo asigna solo administración; bitácora con responsable.
- `0019` descuentos, promociones y productos más vendidos.
- `0020` eliminar dispositivo desde Accesos.
- `0021` torta y hamburguesa en Especiales; papa especial sin mezcla; costra de queso (+15) solo en Gaonera.
- `0022` separa aparato y empleado; aprobar un aparato no crea un empleado.
- `0023` administración de productos, nombre y baja de empleado.
- `0024` cierre de mesa y vigencia de promociones.
- `0025` operaciones de servicio, turnos y cuentas.
- `0026` liberar mesas sin comanda.
- `0027–0029` operaciones administrativas sobre comandas, cuentas y mesas.
- `0030` referencias de Clip, cobros parciales, descuentos y devoluciones.
- `0031–0033` servicio, inventario de ingredientes y ajustes de caja/propinas.
- `0034–0037` horario, controles administrativos y asistencia diaria.
- `0038` inventario por variante/sabor.
- `0039` controles de rol para RPC de caja/inventario y revocación de ejecución directa de la función interna de descuento.

Detalle de cómo aplicarlas: [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md).

## Cómo se usa

1. En el aparato, abre https://tacos-el-faro.vercel.app/ (o escanea un QR de `QR_PUESTOS.html`).
2. Indica el nombre del aparato y el código de puesto que te da administración.
3. Administración aprueba el aparato en el panel.
4. El empleado inicia turno con su PIN.

La app abre en **modo de prueba**. Las mesas de ensayo se llaman `PRUEBA · ...` y no entran al corte real. No pases a modo operación hasta completar [CHECKLIST_PILOTO_HOY.md](./CHECKLIST_PILOTO_HOY.md).

Los pagos con Clip se registran en el POS y deben cobrarse también en la terminal.

## Documentación

- [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md) — migraciones, cuenta admin, aprobación de aparatos.
- [CHECKLIST_PILOTO_HOY.md](./CHECKLIST_PILOTO_HOY.md) — pruebas por puesto antes de ventas reales.
- [GUIA_DE_ACCION.md](./GUIA_DE_ACCION.md) — pendientes para salir a producción.
- [MANUAL_TECNICO.md](./MANUAL_TECNICO.md) — arquitectura y esquema.
- [SECURITY.md](./SECURITY.md) — qué no subir y cómo reportar.
- [PLAN_MEJORAS_PRIORIDAD.md](./PLAN_MEJORAS_PRIORIDAD.md) — plan de endurecimiento y secuencia de mejoras.

## Flujo de cambios

```
editas en la carpeta local faro-pos-pro
  → git commit
  → git push
  → Vercel publica en tacos-el-faro.vercel.app
  → pruebas en esa liga
```

Una sola carpeta. Una sola liga. No editar el HTML dentro de Vercel a mano.
