# Security

## Versión vigente

La aplicación en uso es el HTML estático publicado en:

- https://tacos-el-faro.vercel.app/
- https://tacos-el-faro.vercel.app/admin-accesos.html

La liga `faro-pos-pro.vercel.app` no está activa.

## Reportar un problema

Avísalo en privado al dueño del repositorio. No abras un issue público que contenga contraseñas, PIN, códigos de puesto, claves de Supabase o datos de clientes.

## Qué no debe estar en el repositorio

- La clave `service_role` de Supabase.
- La contraseña de PostgreSQL.
- Códigos de recuperación de GitHub.
- PIN de empleados o códigos de puesto.

La clave pública (publishable / anon) sí puede ir en el HTML. No concede acceso a datos: el acceso lo dan la aprobación del aparato, el rol y el PIN, validados en Supabase con RLS.
