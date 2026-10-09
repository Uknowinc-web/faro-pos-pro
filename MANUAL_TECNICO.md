# Smart Restaurant Pro — Faro POS Pro (Tacos el Faro)
**Código fuente, arquitectura técnica, esquema SQL y manual de despliegue**

---

## 1. Opciones para descargar el proyecto

Tienes dos maneras directas de obtener el código completo del proyecto:

### Opción A (Recomendada): Descarga directa desde Lovable
1. En el editor de Lovable de tu proyecto **Faro POS Pro** (arriba a la derecha o en el menú del proyecto), haz clic en el botón de **GitHub / Código**.
2. Puedes conectarlo con tu cuenta de GitHub para sincronizar el repositorio completo o descargar el código fuente en archivo comprimido con todas las dependencias y configuración.

---

## 2. Esquema de Base de Datos y Funciones SQL (`0000_migration.sql`)

A continuación tienes el script DDL completo para PostgreSQL / Supabase, incluyendo tablas, restricciones, secuencias y las funciones RPC atómicas (`enviar_comanda`, `cobrar_cuenta`, `anular_cuenta`):

```sql
-- TABLA: Mesas
create table public.mesas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  orden int not null default 100,
  estado text not null default 'disponible',
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
  notas text,
  estacion text not null default 'cocina'
);

-- PERMISOS Y SEGURIDAD RLS
grant select, insert, update, delete on public.mesas, public.cuentas, public.comandas, public.comanda_items to anon, authenticated;
grant all on public.mesas, public.cuentas, public.comandas, public.comanda_items to service_role;
grant usage on sequence public.comanda_numero_seq to anon, authenticated;

alter table public.mesas enable row level security;
alter table public.cuentas enable row level security;
alter table public.comandas enable row level security;
alter table public.comanda_items enable row level security;
create policy "staff all" on public.mesas for all using (true) with check (true);
create policy "staff all" on public.cuentas for all using (true) with check (true);
create policy "staff all" on public.comandas for all using (true) with check (true);
create policy "staff all" on public.comanda_items for all using (true) with check (true);

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
    insert into comanda_items(comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas, estacion)
    values (v_comanda, it->>'producto_id', it->>'nombre', greatest((it->>'cantidad')::int,1), (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores','[]'::jsonb), nullif(it->>'notas',''), coalesce(it->>'estacion','cocina'));
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
```

---

## 3. Catálogo y Fórmulas de Cálculo (`src/lib/catalogo.ts`)

```typescript
export type Estacion = "cocina" | "barra";
export type ModSeleccionado = { grupo: string; nombre: string; extra: number };

export const CARNES = ["Asada", "Pastor", "Tripa"] as const;

export type Producto = {
  id: string;
  nombre: string;
  categoria: string;
  precio: number;
  estacion: Estacion;
  mixeable?: boolean;
  extraTripaPrincipal?: number;
  admiteQueso?: boolean;
  gaonera?: boolean;
};

export const CATEGORIAS = ["Tacos", "Quesadillas", "Especiales", "Papas y Frijoles", "Tortas", "Postres y Bebidas"] as const;

export const PRODUCTOS: Producto[] = [
  { id: "taco-maiz", nombre: "Taco maíz", categoria: "Tacos", precio: 40, estacion: "cocina", mixeable: true, extraTripaPrincipal: 5, admiteQueso: true },
  { id: "taco-harina", nombre: "Taco harina", categoria: "Tacos", precio: 42, estacion: "cocina", mixeable: true, extraTripaPrincipal: 5, admiteQueso: true },
  { id: "quesadilla-maiz", nombre: "Quesadilla maíz", categoria: "Quesadillas", precio: 65, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "quesadilla-harina", nombre: "Quesadilla harina", categoria: "Quesadillas", precio: 95, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "vampiro", nombre: "Vampiro", categoria: "Especiales", precio: 75, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "chorreada", nombre: "Chorreada", categoria: "Especiales", precio: 80, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "costra", nombre: "Costra de queso", categoria: "Especiales", precio: 100, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "gaonera", nombre: "Gaonera", categoria: "Especiales", precio: 75, estacion: "cocina", gaonera: true },
  { id: "chilaca", nombre: "Taco de Chile chilaca", categoria: "Especiales", precio: 80, estacion: "cocina" },
  { id: "papa-especial", nombre: "Papa asada especial", categoria: "Papas y Frijoles", precio: 180, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "papa-sencilla", nombre: "Papa sencilla", categoria: "Papas y Frijoles", precio: 130, estacion: "cocina" },
  { id: "charros-especiales", nombre: "Charros especiales", categoria: "Papas y Frijoles", precio: 75, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "charros-sencillos", nombre: "Charros sencillos", categoria: "Papas y Frijoles", precio: 55, estacion: "cocina" },
  { id: "torta", nombre: "Torta", categoria: "Tortas", precio: 130, estacion: "cocina", mixeable: true, extraTripaPrincipal: 10 },
  { id: "hamburguesa", nombre: "Hamburguesa", categoria: "Tortas", precio: 125, estacion: "cocina" },
  { id: "quesagloria", nombre: "Quesagloria", categoria: "Postres y Bebidas", precio: 100, estacion: "cocina" },
  { id: "agua-natural", nombre: "Agua natural", categoria: "Postres y Bebidas", precio: 15, estacion: "barra" },
  { id: "agua-sabor", nombre: "Agua de sabor 1L", categoria: "Postres y Bebidas", precio: 45, estacion: "barra" },
  { id: "horchata", nombre: "Horchata y cebada 1L", categoria: "Postres y Bebidas", precio: 50, estacion: "barra" },
  { id: "topo-chico", nombre: "Topo Chico", categoria: "Postres y Bebidas", precio: 35, estacion: "barra" },
  { id: "toni-col", nombre: "ToniCol", categoria: "Postres y Bebidas", precio: 55, estacion: "barra" },
];

export const NOTAS_RAPIDAS = ["Con todo", "Natural", "Sin salsa de tomate", "Sin lechuga", "Sin frijoles", "Bien cocida"];

export function precioUnitario(p: Producto, mods: ModSeleccionado[]): number {
  return p.precio + mods.reduce((s, m) => s + m.extra, 0);
}

export const mxn = (n: number) =>
  new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN" }).format(n);

export function hoyMonterrey(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Monterrey" }).format(new Date());
}

export const horaMty = (iso: string) =>
  new Intl.DateTimeFormat("es-MX", { timeZone: "America/Monterrey", hour: "2-digit", minute: "2-digit" }).format(new Date(iso));
```
