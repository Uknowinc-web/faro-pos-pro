# Plan de mejoras por prioridad — Faro POS Pro

Fecha de auditoría: 13 de octubre de 2026.
Alcance: revisión estática del repositorio. La base Supabase y el despliegue Vercel no fueron inspeccionados directamente; probar cada migración en staging antes de producción.

## Estado de esta entrega

### P0 — Permisos de RPC de caja e inventario
- [x] Añadir migración 0039_restringir_rpc_inventario_y_caja.sql.
- [x] Añadir prueba SQL de permisos en drizzle/tests/0039_rpc_permissions.sql.
- [x] Actualizar README, manual técnico, guía de acción y checklist.
- [ ] Probar la migración en staging.
- [ ] Verificar privilegios efectivos en Supabase después de aplicarla.
- [ ] Confirmar que el trigger de inventario sigue descontando existencias correctamente.

Riesgo abordado: varias RPC SECURITY DEFINER permitían invocaciones por el rol SQL authenticated sin validar dentro de la función el rol operativo de Faro. Los usuarios anónimos de Supabase Auth también usan authenticated. Además, el auxiliar descontar_producto tenía EXECUTE concedido a authenticated.

La migración 0039 protege las consultas de inventario del POS para puestos autorizados; restringe fondo, empleados, préstamos y gastos de caja a caja/admin; restringe insumos, recetas y movimientos a admin; y revoca la ejecución directa de descontar_producto a anon y authenticated.

## Siguientes prioridades

### P1 — Eliminar PIN legible
Problema: migraciones anteriores mantienen pin_hash y pin_texto.
1. Cambiar el panel para mostrar solo PIN enmascarado y ofrecer restablecimiento, no consulta.
2. Eliminar pin_texto de las respuestas de las RPC administrativas y las solicitudes.
3. Migrar la unicidad para soportarse con hash/identificador seguro y eliminar el campo legible en una migración coordinada.
4. Probar altas, bajas, reactivaciones, cambios de puesto e inicio de turno.

### P1 — Idempotencia y libro de pagos
Problema: la cuenta acumula totales y dispone de una única referencia Clip; los reintentos tras una respuesta de red perdida complican la conciliación.
1. Crear tabla de pagos append-only: ID de operación, cuenta, método, importe, propina, referencia externa, usuario/dispositivo, fecha y estado.
2. Exigir clave de idempotencia por solicitud y aplicar una restricción única en PostgreSQL.
3. Mantener soporte para pagos parciales y mixtos y alinear el corte con el nuevo libro.
4. Probar reintentos con la misma clave, cobros concurrentes y devolución. No afirmar que Clip se procesó en terminal: el POS actualmente registra el pago manualmente.

### P1 — Auditar todas las funciones SECURITY DEFINER
Crear un inventario con firma, propietario, search_path, privilegios EXECUTE, validación de tiene_rol, datos que retorna y quién la invoca. Revisar especialmente asistencia, operaciones de caja, préstamos, administración y borrados. No confiar en botones ocultos en HTML.

### P1 — Trazabilidad e integridad del inventario
- Registrar entradas, ventas, mermas, ajustes, devoluciones y correcciones por producto y variante.
- Guardar usuario, fecha, motivo, cantidad anterior y posterior.
- Evitar existencias negativas bajo concurrencia mediante bloqueos y actualización condicional transaccional.
- Definir si stock NULL significa “sin control” o “sin conteo inicial”; mostrar esa diferencia explícitamente.
- Probar que editar o borrar una línea de comanda revierta y aplique el consumo exactamente una vez.

### P1 — Pruebas automáticas antes de cada despliegue
- Pruebas SQL de RLS/RPC para anon, dispositivo no aprobado, mesero, cocina, caja y admin.
- Pruebas de flujo mesero → cocina → caja → corte.
- Pruebas de precios, modificadores y aislamiento del modo de prueba.
- Pruebas de reintentos, pérdida de red y operaciones concurrentes.
- Instalar migraciones desde cero en una base temporal y actualizar desde un esquema anterior conocido.
- Bloquear la promoción a producción cuando fallen pruebas críticas.

### P2 — Mantenibilidad
- Separar gradualmente el JavaScript, CSS y HTML del POS y el panel; evitar una reescritura total al inicio.
- Versionar coordinadamente HTML y Service Worker y probar cómo se actualizan los dispositivos.
- Documentar caída de red, conciliación de caja, restauración de Supabase y cierre de turno.
- Mantener el README, manual, checklist y secuencia de migraciones sincronizados.

## Secuencia de despliegue recomendada
1. Hacer respaldo verificable y aplicar 0039 en staging.
2. Ejecutar drizzle/tests/0039_rpc_permissions.sql y probar el consumo de inventario con una comanda de prueba.
3. Comparar los privilegios efectivos antes/después y probar los roles mesero/cocina/caja/admin.
4. Aplicar 0039 en producción en una ventana controlada y comprobar los flujos básicos en modo prueba.
5. Tratar eliminación de PIN legible y libro de pagos como migraciones independientes con pruebas y compatibilidad histórica.
6. Completar auditoría de SECURITY DEFINER y CI de integración antes de autorizar ventas reales.

## Criterios de aceptación de 0039
- Una identidad Auth sin fila autorizada en staff_roles recibe un error de autorización al llamar las RPC protegidas.
- anon y authenticated no tienen EXECUTE en public.descontar_producto(text,numeric,jsonb).
- El trigger de consumo sigue descontando las variantes y los ingredientes al insertar/modificar/borrar líneas.
- Los puestos autorizados siguen consultando disponibilidad de stock del POS.
- Recetas, movimientos, gastos, préstamos y fondo no se exponen a puestos que no corresponden.
- Caja, modo de prueba y corte siguen funcionando sin contaminar ventas reales.
