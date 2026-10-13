begin;

create table if not exists public.inventario_variante (
  producto_id text not null references public.catalogo_productos(id) on delete cascade,
  variante text not null,
  existencia numeric(12, 2),
  actualizado_at timestamptz not null default now(),
  primary key (producto_id, variante)
);

alter table public.inventario_variante enable row level security;

insert into public.inventario_variante(producto_id, variante)
select distinct p.id, v.variante
from public.catalogo_productos p
join (
  values
    ('agua-sabor', 'Agua de sabor 1L', 'Limón'),
    ('agua-sabor', 'Agua de sabor 1L', 'Pepino/limón'),
    ('agua-sabor', 'Agua de sabor 1L', 'Jamaica'),
    ('agua-sabor', 'Agua de sabor 1L', 'Tamarindo'),
    ('agua-sabor', 'Agua de sabor 1L', 'Mango'),
    ('agua-sabor', 'Agua de sabor 1L', 'Piña'),
    ('agua-sabor', 'Agua de sabor 1L', 'Sandía'),
    ('horchata', 'Horchata y cebada', 'Horchata'),
    ('horchata', 'Horchata y cebada', 'Cebada'),
    ('toni-col', 'ToniCol y Titan', 'ToniCol'),
    ('toni-col', 'ToniCol y Titan', 'Titan')
) as v(id, nombre, variante)
  on p.id = v.id or lower(p.nombre) = lower(v.nombre)
on conflict (producto_id, variante) do nothing;

update public.inventario i
set existencia = null, actualizado_at = now()
where i.producto_id in (select producto_id from public.inventario_variante);

create or replace function public.listar_inventario_variantes()
returns table (producto_id text, nombre text, variante text, existencia numeric)
language sql stable security definer
set search_path = pg_catalog, public
as $$
  select v.producto_id, p.nombre, v.variante, v.existencia
  from public.inventario_variante v
  join public.catalogo_productos p on p.id = v.producto_id
  order by p.nombre, v.variante;
$$;

create or replace function public.admin_guardar_inventario_variante(
  p_producto text, p_variante text, p_existencia numeric
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración controla el inventario';
  end if;
  if p_existencia is null or p_existencia < 0 then
    raise exception 'La existencia no puede ser negativa';
  end if;
  update public.inventario_variante
  set existencia = p_existencia, actualizado_at = now()
  where producto_id = p_producto and variante = p_variante;
  if not found then
    raise exception 'Ese sabor no está en el inventario';
  end if;
end;
$$;

drop function if exists public.descontar_producto(text, numeric);

create function public.descontar_producto(
  p_producto text, p_delta numeric, p_mods jsonb default '[]'::jsonb
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_variante text;
  v_hay numeric;
begin
  if p_delta = 0 or p_producto is null then
    return;
  end if;
  if exists (select 1 from public.inventario_variante where producto_id = p_producto) then
    select v.variante, v.existencia into v_variante, v_hay
    from public.inventario_variante v
    where v.producto_id = p_producto
      and v.variante in (
        select case txt
          when 'Pepino limón' then 'Pepino/limón'
          else txt
        end
        from jsonb_array_elements_text(coalesce(p_mods, '[]'::jsonb)) as txt
      )
    limit 1;
    if v_variante is null or v_hay is null then
      return;
    end if;
    if p_delta > 0 and v_hay < p_delta then
      raise exception 'Se acabó %', v_variante;
    end if;
    update public.inventario_variante
    set existencia = existencia - p_delta, actualizado_at = now()
    where producto_id = p_producto and variante = v_variante;
    return;
  end if;
  if exists (select 1 from public.recetas r where r.producto_id = p_producto) then
    update public.insumos i
    set existencia = i.existencia - (p_delta * r.cantidad)
    from public.recetas r
    where r.producto_id = p_producto and r.insumo_id = i.id;
    insert into public.inventario_movimientos(insumo_id, producto_id, tipo, cantidad, existencia_despues, motivo)
    select r.insumo_id, p_producto, 'venta', -(p_delta * r.cantidad), i.existencia, 'Venta de platillo'
    from public.recetas r
    join public.insumos i on i.id = r.insumo_id
    where r.producto_id = p_producto;
  else
    update public.inventario
    set existencia = existencia - p_delta, actualizado_at = now()
    where producto_id = p_producto and existencia is not null;
  end if;
end;
$$;

create or replace function public.aplicar_consumo_receta()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.descontar_producto(new.producto_id, new.cantidad, new.modificadores);
  elsif tg_op = 'DELETE' then
    perform public.descontar_producto(old.producto_id, -old.cantidad, old.modificadores);
  elsif new.producto_id is distinct from old.producto_id
     or new.modificadores is distinct from old.modificadores then
    perform public.descontar_producto(old.producto_id, -old.cantidad, old.modificadores);
    perform public.descontar_producto(new.producto_id, new.cantidad, new.modificadores);
  elsif new.cantidad is distinct from old.cantidad then
    perform public.descontar_producto(new.producto_id, new.cantidad - old.cantidad, new.modificadores);
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function public.listar_inventario_variantes() from public, anon, authenticated;
revoke all on function public.admin_guardar_inventario_variante(text, text, numeric) from public, anon, authenticated;
revoke all on function public.descontar_producto(text, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.listar_inventario_variantes() to authenticated;
grant execute on function public.admin_guardar_inventario_variante(text, text, numeric) to authenticated;
grant execute on function public.descontar_producto(text, numeric, jsonb) to authenticated;

commit;
