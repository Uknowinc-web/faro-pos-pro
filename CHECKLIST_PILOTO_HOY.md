# Checklist del piloto funcional

## Antes de invitar al personal

- [x] Desplegar el HTML del POS y `admin-accesos.html` por HTTPS en
  `https://faro-pos-pro.vercel.app/`.
- [x] En Supabase, aplicar en orden las migraciones 0006, 0007 y 0008.
- [x] Habilitar **Anonymous Sign-Ins**; mantener apagado el registro público de
  usuarios por correo.
- [ ] Crear/verificar la cuenta Auth administradora y asignarle `admin` en
  `staff_roles`.
- [ ] Entrar en `https://faro-pos-pro.vercel.app/admin-accesos.html` y confirmar que
  la lista de solicitudes se carga sin errores.
- [ ] Acordar quién aprueba los equipos y cómo reconocer su nombre físico.
- [ ] En cada dispositivo, confirmar fecha/hora correctas, Wi-Fi estable y que
  el navegador no está en modo incógnito.

No probar con cobros reales ni elegir **Modo operación** para generar pedidos
durante este recorrido. La banda amarilla **MODO DE PRUEBA ACTIVO** debe verse
antes de enviar cualquier comanda de ensayo.

## Recorrido por puesto

### Mesero

- [ ] Introducir un código incorrecto y confirmar que sigue bloqueado.
- [ ] Solicitar acceso con nombre reconocible y PIN `101`.
- [ ] Antes de aprobar, comprobar que aparece en administración como pendiente
  y que no se muestra menú, mesas ni datos de operación.
- [ ] Aprobar el equipo correcto; comprobar que entra sin pedir correo.
- [ ] Confirmar que aparece **MODO DE PRUEBA ACTIVO** (es el modo inicial seguro).
- [ ] En una mesa `PRUEBA · ...`, enviar un producto simple y después una mezcla.
- [ ] Confirmar que el producto, modificadores, cantidad y total se muestran
  correctamente en la pantalla de cocina.

### Cocina

- [ ] Solicitar acceso con un nombre reconocible y PIN `202`; aprobar el equipo.
- [ ] Confirmar que no muestra caja ni menú de mesero.
- [ ] Confirmar que aparece **MODO DE PRUEBA ACTIVO** y recibir las comandas que envió mesero.
- [ ] Pasar una comanda a preparación y después a lista.
- [ ] Confirmar que aparece el estado actualizado en la pantalla del mesero.

### Caja

- [ ] Solicitar acceso con un nombre reconocible y PIN `303`; aprobar el equipo.
- [ ] Confirmar que en modo de prueba solo aparecen las mesas/cuentas `PRUEBA`.
- [ ] Marcar la cuenta por cobrar y probar pago de efectivo simulado.
- [ ] Crear otra comanda de prueba y probar **Simular Clip**. No usar la terminal:
  el botón solo cambia el estado de la cuenta de ensayo.
- [ ] Confirmar que el total y conteo de prueba cambian en el corte de prueba.
- [ ] En administración, revocar temporalmente un aparato de prueba; al
  sincronizar, confirmar que vuelve al bloqueo. Reactivarlo solo si se seguirá
  usando ese aparato.

## No contaminación de operación real

- [ ] Cambiar a modo operación solo para comprobar que aparecen mesas reales;
  no enviar pedidos, solicitar cuentas, cobrar ni anular.
- [ ] Volver inmediatamente a modo de prueba y confirmar que ya no aparecen
  mesas de operación real.
- [ ] Verificar en caja que el corte de operación no incluya tickets de prueba.
- [ ] Revisar en el SQL Editor que las mesas de ensayo estén marcadas y que
  producción no contenga registros de prueba:

```sql
select nombre, estado, activa, es_prueba
from public.mesas
where es_prueba
order by orden;

select m.nombre, c.estado, c.total, c.fecha_operativa
from public.cuentas c
join public.mesas m on m.id = c.mesa_id
where m.es_prueba
order by c.abierta_at desc;
```

Para retirar **solo** los pedidos y cuentas de ensayo después del piloto:

```sql
delete from public.cuentas c
using public.mesas m
where c.mesa_id = m.id
  and m.es_prueba;

update public.mesas
set estado = 'disponible'
where es_prueba;
```

No ejecutar consultas de borrado sobre `cuentas`, `comandas` o `mesas` sin el
filtro `es_prueba`.

## Pruebas de continuidad

- [ ] Recargar cada dispositivo: debe solicitar PIN y conservar el puesto fijo.
- [ ] Al volver desde otra aplicación, esperar la sincronización antes de enviar.
- [ ] Desconectar Wi-Fi: no debe permitir enviar, cambiar estado, marcar por
  cobrar, cobrar ni anular hasta sincronizar de nuevo.
- [ ] Restablecer Wi-Fi y volver a la aplicación; confirmar que carga los cambios
  hechos desde otro dispositivo.
- [ ] Probar envío de una comanda con cantidad múltiple y una nota para cocina.
- [ ] Confirmar que los precios se aceptan para productos válidos y se rechazan
  si se intenta manipular el precio en una petición de red.

## Registro de incidencias

Para cada fallo, apuntar: hora, puesto, modo (prueba/operación), pasos, esperado,
observado y captura sin mostrar contraseñas ni información de clientes.

Prioridad sugerida:

- **P0:** datos/ventas de otro puesto, cobro incorrecto, pedido perdido o acceso
  de un dispositivo no aprobado. Detener el piloto.
- **P1:** una operación principal no se puede completar o no se sincroniza.
- **P2:** mensajes confusos, pasos innecesarios o visualización difícil.

Al finalizar, revisar los P0/P1 antes de pasar a un turno real. El sitio sigue
siendo un piloto; no sustituir el registro manual hasta conciliar el corte y
autorizar formalmente la salida.
