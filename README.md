# Tacos El Faro
Sistema POS y KDS para taquería El Faro (Monterrey, N.L.).

## Contenido del Repositorio
- `src/routes/mesero.tsx`: Terminal móvil para meseros (toma rápida de comandas, sin precios en pantalla, modificadores dinámicos).
- `src/routes/cocina.tsx`: KDS en tiempo real para todas las comandas, incluidas bebidas, con alertas sonoras y estados (Pendiente, En preparación, Listo).
- `src/routes/caja.tsx`: Panel de cobro (Efectivo / Clip), anulación con motivo y corte de caja diario en zona horaria Monterrey.
- `src/lib/catalogo.ts`: Catálogo de productos, modificadores de carne y cálculo de precios con los cargos documentados.
- `src/test/catalogo.test.ts`: Pruebas unitarias de integridad del catálogo y cálculo de precios.
- `drizzle/migrations/0000_migration.sql`: Esquema inicial PostgreSQL / Supabase, sin acceso concedido a usuarios anónimos.
- `drizzle/migrations/0001_desactivar_mesa_barra.sql`: Agrega el indicador de mesa activa y desactiva el registro anterior sin borrar historial.
- `drizzle/migrations/0002_unificar_estacion_cocina.sql`: Mueve las comandas históricas a Cocina, elimina el campo de estación y archiva la mesa anterior.
- `drizzle/migrations/0003_restringir_acceso_a_personal.sql`: Cierra permisos anónimos, aplica RLS por rol y protege operaciones con RPC autenticadas.
- `drizzle/migrations/0004_validar_precios_en_servidor.sql`: Verifica catálogo, modificadores y precios antes de aceptar una comanda.
- `drizzle/migrations/0005_restringir_consulta_de_caja.sql`: Evita que mesero y cocina lean cuentas o datos de caja.
- `drizzle/migrations/0006_aprobar_puestos_sin_correo.sql`: Añade solicitudes de aparato y aprobación/revocación administrativa por rol.
- `drizzle/migrations/0007_modo_prueba_aislado.sql`: Separa las mesas y comandas de ensayo de las mesas/ventas reales.
- `drizzle/migrations/0008_validar_modo_en_operaciones.sql`: Valida el modo también en operaciones de cocina y caja en el servidor.
- `drizzle/migrations/0009_responsable_de_mesa_y_sugerencias.sql`: Asigna cada mesa al primer mesero que la abre; protege el envío y añade sugerencias con aceptación/rechazo en tiempo real.
- `drizzle/migrations/0010_crear_mesas_desde_servicio.sql`: Permite al personal de servicio agregar mesas mediante una operación validada por el servidor.
- `drizzle/migrations/0011_codigos_puesto_solo_administracion.sql`: Genera códigos aleatorios de puesto, los valida en Supabase y limita su consulta a administración.
- `CHECKLIST_PILOTO_HOY.md`: Recorrido de pruebas por puesto, casos de aceptación y registro de incidencias.
- `QR_PUESTOS.html` y `QR_MESERO.svg`, `QR_COCINA.svg`, `QR_CAJA.svg`: Hoja imprimible y QR por aparato; los tres abren el mismo enlace.
- `admin-accesos.html`: Panel autenticado para aprobar, rechazar y revocar aparatos.
- `SUPABASE_ACCESO.md`: Pasos para configurar el administrador, aprobar aparatos y verificar el acceso privado.
- `MANUAL_TECNICO.md`: Documentación técnica detallada de la arquitectura, configuración de base de datos y despliegue.
- `GUIA_DE_ACCION.md`: Plan priorizado para pasar del prototipo local a una aplicación segura y lista para operar.

## Estado del código

Este clon no incluye el manifiesto de dependencias ni toda la configuración y los módulos de arranque de la aplicación React. Esa parte no puede instalarse ni compilarse tal como está; el HTML estático sí puede servirse directamente en Vercel.

El HTML independiente usa Supabase Auth, valida el rol y ejecuta las operaciones mediante RPC protegidas. Los aparatos solicitan acceso sin correo y el administrador lo aprueba explícitamente; la solicitud pendiente no puede leer ni operar el POS. Las pantallas React del clon siguen sin inicio de sesión. Consulta [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md).

## Aplicación HTML conectada

Abre `https://faro-pos-pro.vercel.app/` en los dispositivos (redirige a `faro-pos-pro.html`). Cada QR contiene ese mismo enlace. Para la primera vinculación, el equipo indica un nombre y solicita a administración el código de su puesto. La persona administradora revisa y autoriza cada dispositivo desde `https://faro-pos-pro.vercel.app/admin-accesos.html`; en ese panel también puede consultar los códigos. La identidad del dispositivo no obtiene permisos hasta que se autoriza; las operaciones siguen protegidas por Supabase Auth y RLS.

Al volver a la aplicación desde otra pantalla, los datos se actualizan y las operaciones se bloquean mientras estén desactualizados o no haya conexión. El personal de servicio puede consultar mesas, comandas y artículos, y agregar mesas; no puede consultar cuentas. Cocina consulta comandas y artículos, mientras que caja consulta las cuentas. Los borradores de servicio se conservan en el navegador. Los pagos con Clip se registran en el POS y también deben cobrarse en la terminal.

Las migraciones 0006–0008 ya se aplicaron en Supabase y Anonymous Sign-Ins está habilitado. Supabase también requiere habilitar el registro de usuarios para crear identidades anónimas; esto permite registros por correo, pero no concede acceso al POS sin autorización y rol. La aplicación y el panel de administración están publicados en `faro-pos-pro.vercel.app`. Antes de empezar, confirma que la cuenta administradora tiene el rol `admin` y completa las pruebas de aceptación de [CHECKLIST_PILOTO_HOY.md](./CHECKLIST_PILOTO_HOY.md). El HTML inicia en modo de prueba y el servidor separa las mesas de ensayo de las reales.

Las migraciones 0009 y 0010 ya se aplicaron en el proyecto Faro de Supabase y se verificaron sus tablas, RPC, RLS, permisos y suscripciones Realtime. La 0009 asigna cada mesa al primer mesero que la abre y permite sugerencias con aprobación del responsable. La 0010 permite agregar mesas desde el área de servicio y bloquea las inserciones directas en la tabla. La versión actualizada del HTML ya se desplegó en Vercel; falta probar la operación con los aparatos autorizados antes de usar ventas reales. Consulta [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md) y [CHECKLIST_PILOTO_HOY.md](./CHECKLIST_PILOTO_HOY.md).

## Descarga como ZIP
Puedes descargar este repositorio completo en archivo ZIP haciendo clic en el botón verde **Code -> Download ZIP** en GitHub.
