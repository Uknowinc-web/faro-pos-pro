# Guía de acción — Tacos El Faro

## Objetivo

Tener un punto de venta confiable: comandas coordinadas entre mesero, cocina y
caja, precios correctos, ventas auditables y acceso protegido.

## Decisión vigente

La aplicación en uso es [`faro-pos-pro.html`](./faro-pos-pro.html) más el panel
[`admin-accesos.html`](./admin-accesos.html). Están publicados en:

- https://tacos-el-faro.vercel.app/
- https://tacos-el-faro.vercel.app/admin-accesos.html

La liga `faro-pos-pro.vercel.app` no existe. No usarla.

**No usar para ventas reales hasta cerrar los pendientes P0 y P1** de
[CHECKLIST_PILOTO_HOY.md](./CHECKLIST_PILOTO_HOY.md).

## Qué ya está hecho

- HTML conectado a Supabase Auth, con aprobación de aparatos y PIN.
- Migraciones 0000–0021 en el repositorio (aplicar las pendientes en Supabase).
- Modo de prueba aislado: las mesas `PRUEBA · ...` no entran al corte real.
- Validación de precios en el servidor (0004, 0014, 0021).
- Panel de administración con operación, catálogo, empleados y bitácora.

## Pendientes antes de ventas reales

### P0 — no operar sin esto

- [ ] Confirmar que las migraciones 0012–0021 están aplicadas en Supabase.
- [ ] Entrar al panel y ver la lista de solicitudes sin errores.
- [ ] Aprobar un aparato de mesero, uno de cocina y uno de caja.
- [ ] Recorrido completo en modo de prueba: enviar, preparar, marcar listo,
  solicitar cuenta, cobrar (efectivo y simular Clip).
- [ ] Confirmar que un aparato no aprobado no ve datos.
- [ ] Confirmar que el corte de operación no incluye tickets de prueba.

### P1 — antes de confiar en el corte

- [ ] Probar reintento de comanda: no debe duplicarse.
- [ ] Probar pérdida de Wi-Fi: no debe permitir enviar ni cobrar.
- [ ] Definir si Clip es solo registro manual (hoy lo es) o integración real.
- [ ] Configurar respaldo de Supabase y probar una restauración.
- [ ] Conciliar un corte de prueba contra un registro manual.

### P2 — salida formal

- [ ] Capacitar a cada puesto.
- [ ] Documentar qué hacer si se cae la red o hay un cobro duplicado.
- [ ] Autorizar modo operación solo después de que el responsable del restaurante
  apruebe el piloto.

## Criterio de no-go

No operar ventas reales si falta cualquiera de estos: RLS verificada, precio
validado en servidor, corte conciliable, respaldo recuperable, y confirmación de
que la liga que se usa es https://tacos-el-faro.vercel.app/.
