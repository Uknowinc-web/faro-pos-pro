# Smart Restaurant Pro — Faro POS Pro (Tacos el Faro)
**Código fuente, arquitectura técnica, esquema SQL y manual de despliegue**

---

## 1. Opciones para descargar el proyecto

Tienes dos maneras directas de obtener el código completo del proyecto:

### Opción A (Recomendada): Descarga directa desde Lovable
1. En el editor de Lovable de tu proyecto **Faro POS Pro** (arriba a la derecha o en el menú del proyecto), haz clic en el botón de **GitHub / Código**.
2. Puedes conectarlo con tu cuenta de GitHub para sincronizar el repositorio completo o descargar el código fuente en archivo comprimido con todas las dependencias y configuración.

---

## 2. Esquema y seguridad de base de datos

Las migraciones SQL vigentes están en `drizzle/migrations`. En una base nueva,
ejecutar 0000–0010 en orden; en una base ya migrada, ejecutar únicamente las
pendientes. La 0003 cierra permisos directos al rol PostgreSQL `anon`, define
roles y restringe las consultas y operaciones RPC. La 0004 verifica catálogo,
modificadores y precio en PostgreSQL. La 0005 limita las cuentas al rol de caja
y administración. La 0006 permite solicitar acceso con una identidad técnica
de aparato sin permisos; solo una cuenta `admin` puede asignarle un puesto. La
0007 crea mesas de ensayo aisladas y filtra por modo para que no afecten el corte.
0008 exige que cada cambio de estado, solicitud de cuenta, cobro y anulación
coincida con el modo de la mesa en el servidor; el HTML inicia en modo prueba.
0009 asigna de forma atómica un responsable por mesa, comprueba ese responsable
en el servidor antes de enviar comandas y habilita sugerencias persistentes que
el responsable debe aceptar o rechazar. La asignación termina cuando caja cobra
o anula la cuenta. 0010 permite que personal de servicio autorizado agregue
mesas mediante una RPC y revoca la inserción directa a la tabla.

**No uses los fragmentos SQL históricos de esta sección como mecanismo de
despliegue.** La autorización canónica está en
[`0003_restringir_acceso_a_personal.sql`](./drizzle/migrations/0003_restringir_acceso_a_personal.sql);
[`0004_validar_precios_en_servidor.sql`](./drizzle/migrations/0004_validar_precios_en_servidor.sql) y
[`0005_restringir_consulta_de_caja.sql`](./drizzle/migrations/0005_restringir_consulta_de_caja.sql),
[`0006_aprobar_puestos_sin_correo.sql`](./drizzle/migrations/0006_aprobar_puestos_sin_correo.sql) y
[`0007_modo_prueba_aislado.sql`](./drizzle/migrations/0007_modo_prueba_aislado.sql) y
[`0008_validar_modo_en_operaciones.sql`](./drizzle/migrations/0008_validar_modo_en_operaciones.sql) y
[`0009_responsable_de_mesa_y_sugerencias.sql`](./drizzle/migrations/0009_responsable_de_mesa_y_sugerencias.sql) y
[`0010_crear_mesas_desde_servicio.sql`](./drizzle/migrations/0010_crear_mesas_desde_servicio.sql).
Consulta [SUPABASE_ACCESO.md](./SUPABASE_ACCESO.md) para aplicar migraciones,
configurar la cuenta `admin`, aprobar aparatos y comprobar que el rol de base
`anon` no tenga permisos.

La versión de puesto se abre con la misma liga en cada aparato. El PIN (`101`,
`202` o `303`) bloquea la interfaz en un rol fijo; no es una credencial del
servidor. El aparato crea una identidad anónima individual sin permisos y espera
la aprobación de una cuenta `admin` en [`admin-accesos.html`](./admin-accesos.html).
Una vez aprobada la identidad, el personal solo ingresa el PIN al abrir o
recargar la liga. Los tres QR están en [`QR_PUESTOS.html`](./QR_PUESTOS.html) y
contienen el mismo enlace.

Cada puesto muestra claramente **Modo operación** o **Modo de prueba**. Los
ensayos usan mesas `PRUEBA · ...` y no deben mezclarse con tickets, pagos o
cortes reales. El modo queda guardado por aparato; confirmar cuidadosamente
antes de cambiarlo.

El siguiente esquema resume las entidades principales; para crear o actualizar
una base utiliza los archivos de migración completos.

```sql
-- TABLA: Mesas
create table public.mesas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  orden int not null default 100,
  estado text not null default 'disponible',
  activa boolean not null default true,
  created_at timestamptz not null default now()
);

-- TABLA: Cuentas
create table public.cuentas (
  id uuid primary key default gen_random_uuid(),
  mesa_id uuid not null references public.mesas(id) on delete cascade,
  estado text not null default 'abierta',
  metodo_pago text,
  total numeric(10,2),
  motivo_anulacion text,
  fecha_operativa date,
  abierta_at timestamptz not null default now(),
  cerrada_at timestamptz
);
create unique index cuentas_una_abierta on public.cuentas(mesa_id) where estado in ('abierta','por_cobrar');

-- SECUENCIA Y TABLA: Comandas
create sequence public.comanda_numero_seq;
create table public.comandas (
  id uuid primary key default gen_random_uuid(),
  numero int not null default nextval('public.comanda_numero_seq'),
  cuenta_id uuid not null references public.cuentas(id) on delete cascade,
  mesa_id uuid not null references public.mesas(id) on delete cascade,
  client_token text not null unique,
  estado text not null default 'pendiente',
  mesero text,
  created_at timestamptz not null default now()
);

-- TABLA: Líneas de comanda con snapshot de precio
create table public.comanda_items (
  id uuid primary key default gen_random_uuid(),
  comanda_id uuid not null references public.comandas(id) on delete cascade,
  producto_id text not null,
  nombre text not null,
  cantidad int not null default 1,
  precio_unitario numeric(10,2) not null,
  modificadores jsonb not null default '[]',
  notas text
);

-- PERMISOS Y SEGURIDAD RLS
grant all on public.mesas, public.cuentas, public.comandas, public.comanda_items to service_role;
revoke all on public.mesas, public.cuentas, public.comandas, public.comanda_items from public, anon, authenticated;
revoke all on sequence public.comanda_numero_seq from public, anon, authenticated;

alter table public.mesas enable row level security;
alter table public.cuentas enable row level security;
alter table public.comandas enable row level security;
alter table public.comanda_items enable row level security;
-- Las políticas de acceso privado se crean en la migración 0003.

-- MESAS INICIALES (Mesa 1 a 12 y Para Llevar)
insert into public.mesas (nombre, orden) values
('Mesa 1',1),('Mesa 2',2),('Mesa 3',3),('Mesa 4',4),('Mesa 5',5),('Mesa 6',6),
('Mesa 7',7),('Mesa 8',8),('Mesa 9',9),('Mesa 10',10),('Mesa 11',11),('Mesa 12',12),('Para Llevar',99);

-- FUNCIÓN RPC: Enviar comanda
create or replace function public.enviar_comanda(p_mesa uuid, p_token text, p_items jsonb, p_mesero text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_cuenta uuid; v_comanda uuid; it jsonb;
begin
  select id into v_comanda from comandas where client_token = p_token;
  if v_comanda is not null then return v_comanda; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Comanda vacía'; end if;
  select id into v_cuenta from cuentas where mesa_id = p_mesa and estado in ('abierta','por_cobrar') for update;
  if v_cuenta is null then
    insert into cuentas(mesa_id) values (p_mesa) returning id into v_cuenta;
  else
    update cuentas set estado='abierta' where id=v_cuenta;
  end if;
  insert into comandas(cuenta_id, mesa_id, client_token, mesero) values (v_cuenta, p_mesa, p_token, p_mesero) returning id into v_comanda;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into comanda_items(comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas)
    values (v_comanda, it->>'producto_id', it->>'nombre', greatest((it->>'cantidad')::int,1), (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores','[]'::jsonb), nullif(it->>'notas',''));
  end loop;
  update mesas set estado='ocupada' where id=p_mesa;
  return v_comanda;
end $$;

-- FUNCIÓN RPC: Solicitar cuenta (marcar por cobrar)
create or replace function public.solicitar_cuenta(p_cuenta uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update cuentas set estado='por_cobrar' where id=p_cuenta and estado='abierta';
  update mesas set estado='por_cobrar' where id=(select mesa_id from cuentas where id=p_cuenta);
end $$;

-- FUNCIÓN RPC: Cobrar cuenta (Efectivo / Clip con zona horaria de Monterrey)
create or replace function public.cobrar_cuenta(p_cuenta uuid, p_metodo text) returns void language plpgsql security definer set search_path=public as $$
declare v_total numeric(10,2); v_mesa uuid;
begin
  select coalesce(sum(ci.cantidad * ci.precio_unitario),0), c.mesa_id
    into v_total, v_mesa
    from comandas k
    join comanda_items ci on ci.comanda_id = k.id
    join cuentas c on c.id = k.cuenta_id
   where k.cuenta_id = p_cuenta
   group by c.mesa_id;
  update cuentas
     set estado='pagada', metodo_pago=p_metodo, total=v_total, cerrada_at=now(),
         fecha_operativa=(now() at time zone 'America/Monterrey')::date
   where id=p_cuenta;
  update mesas set estado='disponible' where id=v_mesa;
end $$;

-- FUNCIÓN RPC: Anular cuenta
create or replace function public.anular_cuenta(p_cuenta uuid, p_motivo text) returns void language plpgsql security definer set search_path=public as $$
declare v_mesa uuid;
begin
  select mesa_id into v_mesa from cuentas where id=p_cuenta;
  update cuentas set estado='anulada', motivo_anulacion=p_motivo, cerrada_at=now(),
         fecha_operativa=(now() at time zone 'America/Monterrey')::date
   where id=p_cuenta;
  update mesas set estado='disponible' where id=v_mesa;
end $$;

-- Estas funciones históricas no se exponen. La migración 0003 las reemplaza
-- por versiones que validan rol y concede ejecución solo a authenticated.
revoke all on function public.enviar_comanda(uuid, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.solicitar_cuenta(uuid) from public, anon, authenticated;
revoke all on function public.cobrar_cuenta(uuid, text) from public, anon, authenticated;
revoke all on function public.anular_cuenta(uuid, text) from public, anon, authenticated;
```

---

## 3. Catálogo y Fórmulas de Cálculo (`src/lib/catalogo.ts`)

La implementación vigente del catálogo, los precios y los modificadores está en
[`src/lib/catalogo.ts`](./src/lib/catalogo.ts). Ese archivo también proporciona
las funciones de precio unitario y formato de moneda/horario que usan las
pantallas. Las pruebas unitarias del catálogo están en
[`src/test/catalogo.test.ts`](./src/test/catalogo.test.ts).

Los precios y cargos corresponden a la lista de precios:

- Cada carne agregada después de la principal suma $10.
- La tripa suma el cargo de carne principal una sola vez: $5 para tacos y $10
  para quesadillas, vampiro, chorreada, papa especial y torta. La tripa agregada
  como ingrediente secundario no vuelve a cobrar ese cargo.
- El queso en tacos suma $5.
- Solo tacos, quesadillas, vampiro, chorreada, papa asada especial y torta
  permiten mezclar carnes.

Por ejemplo, la torta de asada cuesta $130 y con una carne agregada cuesta
$140. Una torta con principal de tripa y dos carnes agregadas cuesta $160.
