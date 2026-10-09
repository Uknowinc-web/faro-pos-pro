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
- `QR_PUESTOS.html` y `QR_MESERO.svg`, `QR_COCINA.svg`, `QR_CAJA.svg`: Hoja imprimible y QR por aparato; los tres abren el mismo enlace.
- `SUPABASE_ACCESO.md`: Pasos de configuración, alta de personal y verificación de acceso privado.
- `MANUAL_TECNICO.md`: Documentación técnica detallada de la arquitectura, configuración de base de datos y despliegue.
- `GUIA_DE_ACCION.md`: Plan priorizado para pasar del prototipo local a una aplicación segura y lista para operar.

## Estado del código

Este clon no incluye el manifiesto de dependencias ni toda la configuración y los módulos de arranque de la aplicación React. Esa parte no puede instalarse ni compilarse tal como está; el HTML estático sí puede servirse directamente en Vercel.

La base de datos está configurada con acceso privado y el HTML independiente usa Supabase Auth, valida el rol y ejecuta las operaciones mediante RPC protegidas. Aún se necesitan cuentas de personal con rol asignado y pruebas positivas por rol antes de operar. Las pantallas React del clon siguen sin inicio de sesión. Consulta [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md).

## Aplicación HTML conectada

Abre `https://faro-pos.vercel.app/` en los tres aparatos. Cada QR contiene ese mismo enlace. Al iniciar, el equipo pide el código del puesto: mesero `101`, cocina `202`, caja `303`. La primera vez, un administrador debe vincular el aparato con una cuenta Supabase del rol correspondiente; después la sesión queda en ese navegador y el personal solo introduce su código. El aparato se fija al rol, y recargar la liga vuelve a pedir el código. Los códigos solo desbloquean la interfaz local: Supabase Auth y RLS siguen autorizando cada operación y no hay registro público ni acceso anónimo.

Al volver a la app desde otra aplicación, sincroniza con Supabase y bloquea el envío mientras los datos estén desactualizados o no haya conexión. Mesero no consulta cuentas, cocina no ve menú ni caja, y solo caja puede consultar cuentas. Los borradores del mesero se conservan en el navegador. Clip se registra manualmente: también hay que cobrar en la terminal.

El proyecto de Vercel sigue sin conexión a Git y aún no se ha publicado esta versión. Antes de operar, hay que crear cuentas con rol, probar cada flujo y ensayar el corte de caja. Consulta [GUIA_DE_ACCION.md](./GUIA_DE_ACCION.md).

## Descarga como ZIP
Puedes descargar este repositorio completo en archivo ZIP haciendo clic en el botón verde **Code -> Download ZIP** en GitHub.
