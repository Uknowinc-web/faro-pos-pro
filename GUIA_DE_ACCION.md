# Guía de acción — Faro POS Pro

## Objetivo

Convertir el prototipo actual en un punto de venta confiable para Tacos el Faro,
con comandas coordinadas entre meseros, cocina y caja, precios correctos,
ventas auditables y acceso protegido.

## Decisión inmediata

El archivo [`faro-pos-pro.html`](./faro-pos-pro.html) conecta Supabase Auth y
requiere un rol aprobado en el servidor. Cada aparato abre la misma liga y pide
su nombre y PIN (`101` mesero, `202` cocina, `303` caja). La primera vez, el
administrador aprueba el aparato desde [`admin-accesos.html`](./admin-accesos.html);
el personal no inicia sesión con correo. Los PIN identifican el puesto, pero no
autorizan datos por sí mismos. Las migraciones 0006–0008 ya están aplicadas en
Supabase y Anonymous Sign-Ins está habilitado; el registro público por correo
sigue apagado. La versión HTML ya está publicada en
`https://faro-pos-pro.vercel.app/`. Falta asignar/verificar el rol `admin` y
validar la aprobación con aparatos reales.
**No usarlo para ventas reales hasta cerrar los pendientes P0 y P1.**

Este clon no contiene `package.json` ni la configuración necesaria para compilar
la aplicación React; el HTML es por ahora la única interfaz conectada.

## Plan de trabajo por prioridad

### 1. Recuperar una base de código ejecutable — P0

- [ ] Obtener del repositorio de origen una copia completa con manifiesto de
  dependencias, lockfile, configuración de compilación, cliente Supabase,
  componentes, hooks y rutas.
- [ ] Integrar esa copia sin sobrescribir el catálogo corregido, las pruebas ni
  la versión HTML de este trabajo.
- [ ] Documentar las variables de entorno necesarias; mantener las credenciales
  fuera del código y del repositorio.
- [ ] Instalar dependencias y ejecutar instalación reproducible, comprobación de
  tipos, pruebas y compilación.

**Terminado cuando:** otro desarrollador puede clonar el proyecto, instalarlo y
compilarlo siguiendo únicamente las instrucciones del README.

### 2. Cerrar el acceso público antes de conectar la aplicación — P0

- [x] Preparar la migración 0003 con permisos cerrados a `anon`, RLS por rol
  (`mesero`, `cocina`, `caja`, `admin`) y comprobaciones de rol en RPC.
- [x] Enrutar el cambio de estado de cocina por una RPC que valida transiciones
  permitidas y rechaza otros roles.
- [x] Aplicar las migraciones 0000–0003 en el proyecto Supabase real y verificar los
  permisos con las consultas de [`SUPABASE_ACCESO.md`](./SUPABASE_ACCESO.md).
- [x] Mantener deshabilitado el registro público de cuentas con correo.
- [x] Implementar solicitudes de acceso de aparato sin correo y un panel de
  aprobación/revocación administrativa en la versión HTML.
- [x] Añadir PIN de puesto que fija la interfaz del aparato y vuelve a pedirlo
  al recargar la liga; el PIN no sustituye la asignación de rol en Supabase.
- [x] Aplicar las migraciones 0006–0008 y habilitar Anonymous Sign-Ins para
  identidades técnicas sin permisos previos.
- [x] Aplicar 0009 y 0010 en Supabase y comprobar tablas, RPC, RLS, permisos y
  suscripciones Realtime.
- [x] Desplegar la versión del HTML que usa estas migraciones en Vercel.
- [ ] Probar el flujo completo con tres aparatos de servicio, Caja y Cocina.
- [ ] Crear tu cuenta administradora Auth y asignarle `admin` siguiendo
  [`SUPABASE_ACCESO.md`](./SUPABASE_ACCESO.md).
- [ ] Probar solicitud pendiente, aprobación, rechazo y revocación con aparatos
  de mesero, cocina y caja; confirmar que el pendiente no lee datos.

**Terminado cuando:** una identidad de aparato sin aprobación no puede leer ni
modificar datos, el administrador puede aprobar/revocar y cada rol pasa pruebas
de autorización positivas y negativas. No operar ventas antes de verificarlo.

### 3. Definir catálogo y precios en un único lugar — P0

- [ ] Confirmar como catálogo vigente los precios de
  [`../precios-el-faro.xlsx`](../precios-el-faro.xlsx) y respaldar los cambios en
  el repositorio, no solo en un archivo local.
- [ ] Mantener en la aplicación y en el servidor las reglas aprobadas:
  - Solo tacos, quesadillas, vampiro, chorreada, papa asada especial y torta
    permiten mezclar carnes.
  - Cada carne adicional después de la principal suma $10.
  - La tripa suma el recargo de carne principal una sola vez: $5 en tacos y $10
    en los otros productos mixteables.
  - El queso en tacos suma $5.
- [x] Preparar la migración 0004 para verificar el producto, modificadores y
  precio en el servidor, sin confiar en el precio enviado por el navegador.
- [x] Aplicar la migración 0004 en Supabase y probar precios válidos e inválidos
  (mezclas, queso, modificadores no permitidos y precio alterado).
- [x] Aplicar la migración 0005: mesero y cocina no pueden consultar cuentas.
- [ ] Confirmar cualquier precio que difiera entre el menú aprobado, la hoja de
  cálculo y la aplicación antes de cargarlo.

**Terminado cuando:** pruebas unitarias y de integración verifican los ejemplos
de mezcla, precios base, recargos y productos que no admiten mezcla.

### 4. Completar y proteger el flujo de servicio — P1

- [ ] Garantizar que enviar varias veces la misma comanda por reintentos no
  duplique la venta y que operaciones concurrentes no creen dos cuentas abiertas
  para la misma mesa.
- [ ] Mantener estados por artículo para que una comanda con varios productos
  conserve visibles los que aún están pendientes de preparación.
- [ ] Implementar y probar división de cuentas si se requiere en operación. El
  README anterior la anunciaba, pero no está disponible en la pantalla actual.
- [ ] Definir el procedimiento de reimpresión de cuenta. En la versión HTML solo
  está disponible la impresión del navegador.
- [ ] Aclarar si Clip será un registro manual o una integración real con
  terminal; la pantalla actual no procesa pagos.
- [ ] Guardar auditoría de cambios de estado, cobros y anulaciones con usuario,
  fecha, motivo y monto.

**Terminado cuando:** casos de uso normales, reintentos, errores de red y
operaciones concurrentes conservan una cuenta y un total correctos, con historial
consultable.

### 5. Establecer respaldo, pruebas y monitoreo — P1

- [ ] Crear pruebas unitarias para precios y reglas de negocio.
- [ ] Crear pruebas de integración para RPC, RLS, cobro, anulación y cambios de
  estado en PostgreSQL/Supabase.
- [ ] Crear pruebas de navegador para mesero → cocina → caja → corte.
- [ ] Configurar respaldo automático de la base de datos y ensayar su
  restauración antes de la salida a producción.
- [ ] Registrar errores operativos de forma observable, sin mostrar mensajes de
  éxito cuando falla una operación.

**Terminado cuando:** CI pasa todas las pruebas y existe un procedimiento
verificado para recuperar los datos.

### 6. Piloto y salida a producción — P2

- [ ] Publicar primero en un entorno de prueba separado del proyecto real.
- [ ] Cargar mesas y catálogo aprobados; comparar tickets y cortes con una caja
  manual durante un piloto controlado.
- [ ] Capacitar a cada rol y documentar qué hacer ante caída de red, corrección
  de una comanda, cobro duplicado o anulación.
- [ ] Autorizar producción solo después de aprobar seguridad, pruebas, respaldos,
  precios y conciliación de pagos.

**Terminado cuando:** el responsable del restaurante aprueba el piloto, el corte
cuadra contra los comprobantes y el personal conoce el procedimiento de
contingencia.

## Uso seguro de la versión HTML

Abrir `faro-pos-pro.html` en un navegador con internet, solicitar acceso con el
nombre del aparato y su PIN, y aprobarlo en el panel de administración. La hoja imprimible de QR está en
[`QR_PUESTOS.html`](./QR_PUESTOS.html); los tres códigos QR abren el mismo URL.
El panel requiere iniciar sesión con la cuenta administradora del POS. Al volver
desde otra app, los datos se sincronizan y el envío queda bloqueado
hasta que la sincronización tenga éxito. Los borradores se conservan en el
navegador; comandas y cuentas se guardan en Supabase. “Clip registrado” solo
registra el método de pago: confirmar el cobro directamente en la terminal.

## Estado actual conocido

- El catálogo y el cálculo de mezclas fueron restaurados y corregidos en
  [`src/lib/catalogo.ts`](./src/lib/catalogo.ts); las pruebas están en
  [`src/test/catalogo.test.ts`](./src/test/catalogo.test.ts).
- La versión HTML conectada está en
  [`faro-pos-pro.html`](./faro-pos-pro.html); muestra el acceso de personal y
  sincroniza datos con Supabase. Aún requiere pruebas con usuarios reales de
  cada rol.
- No fue posible ejecutar pruebas ni compilar la aplicación React porque faltan
  `package.json`, dependencias y archivos de configuración, y el entorno actual
  no tiene Node.js.
- La migración
  [`0003_restringir_acceso_a_personal.sql`](./drizzle/migrations/0003_restringir_acceso_a_personal.sql)
  está aplicada y el acceso anónimo fue comprobado como denegado. Aún no hay
  usuarios con roles asignados y el proyecto Vercel no está conectado al código
  de trabajo.
- La migración 0004 está aplicada; se probaron siete precios válidos de mezcla
  y queso, y se comprobó el rechazo de un precio alterado y de un modificador
  no permitido.
- La migración 0005 está aplicada. No hay todavía cuentas de personal vinculadas
  a los aparatos y el proyecto Vercel sigue pendiente de conexión al repositorio.
- El código local añade la migración 0006 y `admin-accesos.html`; todavía deben
  aplicarse en Supabase y desplegarse antes de pedir/aprobar aparatos sin correo.
- El código añade modo de prueba aislado y la migración 0007; es requisito antes
  de generar tickets de ensayo en la base compartida.
- La migración 0008 valida el modo de prueba también al cambiar estados, marcar
  cuentas, cobrar o anular. El HTML abre en modo prueba por defecto para reducir
  el riesgo de operar sobre mesas reales accidentalmente.
- En Supabase ya están aplicadas las migraciones 0006–0008, hay 13 mesas
  reservadas de prueba y Anonymous Sign-Ins está habilitado; el registro público
  por correo permanece apagado. Vercel publica la aplicación en
  `https://faro-pos-pro.vercel.app/`; queda pendiente asignar/verificar `admin`
  y completar las pruebas de aceptación antes de considerar operativo el piloto.

## Criterio de no-go

No operar ventas reales si falta cualquiera de estos elementos: autenticación y
RLS verificadas, precio calculado/validado en servidor, corte conciliable,
respaldo recuperable y confirmación de que la aplicación probada es la versión
que se desplegará.
