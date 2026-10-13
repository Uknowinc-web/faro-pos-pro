begin;

delete from public.catalogo_productos p
where p.categoria = 'Tortas'
  and not exists (
    select 1 from public.comanda_items i where i.producto_id = p.id
  );

update public.catalogo_productos
set activo = false, updated_at = now()
where categoria = 'Tortas';

do $$
declare
  v_constraint text;
begin
  if exists (select 1 from public.catalogo_productos where categoria = 'Tortas') then
    return;
  end if;
  for v_constraint in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.catalogo_productos'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%categoria%'
  loop
    execute format('alter table public.catalogo_productos drop constraint %I', v_constraint);
  end loop;
  alter table public.catalogo_productos add constraint catalogo_productos_categoria_check
    check (categoria in (
      'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
      'Postres', 'Bebidas', 'Promociones'
    ));
end;
$$;

create or replace function public.admin_guardar_producto(
  p_id text, p_nombre text, p_categoria text, p_precio numeric, p_activo boolean,
  p_permite_mezcla boolean default false, p_permite_queso boolean default false
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_mezcla boolean := coalesce(p_permite_mezcla, false);
  v_queso boolean := coalesce(p_permite_queso, false);
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar productos';
  end if;
  if coalesce(p_id, '') !~ '^[a-z0-9-]{2,64}$'
     or char_length(v_nombre) not between 1 and 100
     or p_categoria is null
     or p_categoria not in (
       'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
       'Postres', 'Bebidas', 'Promociones'
     )
     or p_precio is null or p_precio < 0 or p_precio > 100000 then
    raise exception 'Datos de producto inválidos';
  end if;
  if p_categoria in ('Postres', 'Bebidas', 'Promociones') then
    v_mezcla := false;
    v_queso := false;
  end if;
  if not v_mezcla then
    v_queso := false;
  end if;
  insert into public.catalogo_productos(
    id, nombre, categoria, precio, activo, permite_mezcla, permite_queso,
    extra_tripa_principal, extra_queso
  )
  values (
    p_id, v_nombre, p_categoria, p_precio, coalesce(p_activo, true),
    v_mezcla, v_queso,
    case when v_mezcla then 5 else 0 end,
    case when v_queso then 5 else 0 end
  )
  on conflict (id) do update
  set nombre = excluded.nombre,
      categoria = excluded.categoria,
      precio = excluded.precio,
      activo = excluded.activo,
      permite_mezcla = excluded.permite_mezcla,
      permite_queso = excluded.permite_queso,
      extra_tripa_principal = excluded.extra_tripa_principal,
      extra_queso = excluded.extra_queso,
      updated_at = now();
  perform public.registrar_accion(
    'editar_producto', null, null, null, p_precio,
    jsonb_build_object(
      'producto_id', p_id, 'nombre', v_nombre, 'activo', p_activo,
      'personalizable', v_mezcla
    )
  );
end;
$$;

revoke all on function public.admin_guardar_producto(text, text, text, numeric, boolean, boolean, boolean) from public, anon, authenticated;
grant execute on function public.admin_guardar_producto(text, text, text, numeric, boolean, boolean, boolean) to authenticated;

commit;
