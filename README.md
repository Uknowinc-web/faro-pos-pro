# Faro POS Pro (Tacos el Faro)
Sistema POS y KDS para taquería El Faro (Monterrey, N.L.).

## Contenido del Repositorio
- `src/routes/mesero.tsx`: Terminal móvil para meseros (toma rápida de comandas, sin precios en pantalla, modificadores dinámicos).
- `src/routes/cocina.tsx`: KDS en tiempo real con alertas sonoras, estados (Pendiente, En preparación, Listo) y ordenamiento por urgencia.
- `src/routes/caja.tsx`: Panel de cobro atómico (Efectivo / Tarjeta Clip), separación de cuentas, reimpresión y corte de caja diario en zona horaria Monterrey.
- `src/lib/catalogo.ts`: Catálogo de productos, fórmulas de carnes mixeables, extras de tripa y costra, y cálculo exacto de precios.
- `drizzle/migrations/0000_migration.sql`: Esquema SQL completo para PostgreSQL / Supabase, incluyendo tablas `mesas`, `cuentas`, `comandas`, `comanda_items`, políticas RLS y funciones transaccionales atómicas (`enviar_comanda`, `cobrar_cuenta`, `anular_cuenta`).
- `MANUAL_TECNICO.md`: Documentación técnica detallada de la arquitectura, configuración de base de datos y despliegue.

## Descarga como ZIP
Puedes descargar este repositorio completo en archivo ZIP haciendo clic en el botón verde **Code -> Download ZIP** en GitHub.
