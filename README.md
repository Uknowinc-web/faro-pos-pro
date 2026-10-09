# Faro POS Pro (Tacos el Faro)
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

Abre `https://faro-pos-pro.vercel.app/` en los tres aparatos (redirige a la aplicación `faro-pos-pro.html`). Cada QR contiene ese mismo enlace. La primera vez, el equipo solicita el nombre del aparato y el PIN del puesto: mesero `101`, cocina `202`, caja `303`. Después, tú apruebas la solicitud desde `https://faro-pos-pro.vercel.app/admin-accesos.html` con tu cuenta administradora. El aparato queda ligado a su rol y el personal ya no necesita correo; al recargar la liga solo introduce el PIN. La identidad técnica del aparato no tiene permisos hasta que se aprueba y las operaciones siguen protegidas por Supabase Auth y RLS.

Al volver a la app desde otra aplicación, sincroniza con Supabase y bloquea el envío mientras los datos estén desactualizados o no haya conexión. Mesero no consulta cuentas, cocina no ve menú ni caja, y solo caja puede consultar cuentas. Los borradores del mesero se conservan en el navegador. Clip se registra manualmente: también hay que cobrar en la terminal.

Las migraciones 0006–0008 ya se aplicaron en Supabase y Anonymous Sign-Ins está habilitado; el registro público por correo sigue apagado. La aplicación y el panel de administración están publicados en `faro-pos-pro.vercel.app`. Antes de empezar, confirma que tu cuenta administradora tiene el rol `admin` y completa las pruebas de aceptación de [CHECKLIST_PILOTO_HOY.md](./CHECKLIST_PILOTO_HOY.md). El HTML inicia en modo prueba y el servidor valida que ninguna operación cruce entre mesas de ensayo y reales. El piloto no equivale a autorización para ventas reales.

## Descarga como ZIP
Puedes descargar este repositorio completo en archivo ZIP haciendo clic en el botón verde **Code -> Download ZIP** en GitHub.
