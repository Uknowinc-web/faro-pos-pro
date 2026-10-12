begin;

-- Separa "Postres y Bebidas" en dos categorías.
do $$
declare
  v_constraint text;
begin
  for v_constraint in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.catalogo_productos'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%categoria%'
  loop
    execute format('alter table public.catalogo_productos drop constraint %I', v_constraint);
  end loop;
end;
$$;

update public.catalogo_productos
set categoria = case when id = 'quesagloria' then 'Postres' else 'Bebidas' end,
    updated_at = now()
where categoria = 'Postres y Bebidas';

alter table public.catalogo_productos add constraint catalogo_productos_categoria_check
  check (categoria in (
    'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
    'Tortas', 'Postres', 'Bebidas'
  ));

-- Horchata/cebada y ToniCol/Titan comparten botón; el tamaño y la variante se eligen al ordenar.
update public.catalogo_productos
set nombre = 'Horchata y cebada', updated_at = now()
where id = 'horchata' and nombre = 'Horchata y cebada 1L';

update public.catalogo_productos
set nombre = 'ToniCol y Titan', updated_at = now()
where id = 'toni-col' and nombre = 'ToniCol';

create or replace function public.admin_guardar_producto(
  p_id text, p_nombre text, p_categoria text, p_precio numeric, p_activo boolean
)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede editar productos';
  end if;
  if coalesce(p_id, '') !~ '^[a-z0-9-]{2,64}$'
     or char_length(v_nombre) not between 1 and 100
     or p_categoria is null
     or p_categoria not in (
       'Tacos', 'Quesadillas', 'Especiales', 'Papas y Frijoles',
       'Tortas', 'Postres', 'Bebidas'
     )
     or p_precio is null or p_precio < 0 or p_precio > 100000 then
    raise exception 'Datos de producto inválidos';
  end if;
  insert into public.catalogo_productos(id, nombre, categoria, precio, activo)
  values (p_id, v_nombre, p_categoria, p_precio, coalesce(p_activo, true))
  on conflict (id) do update
  set nombre = excluded.nombre,
      categoria = excluded.categoria,
      precio = excluded.precio,
      activo = excluded.activo,
      updated_at = now();
  perform public.registrar_accion(
    'editar_producto', null, null, null, p_precio,
    jsonb_build_object('producto_id', p_id, 'nombre', v_nombre, 'activo', p_activo)
  );
end;
$$;

create or replace function public.validar_item_comanda(
  p_producto_id text, p_nombre text, p_precio numeric, p_modificadores jsonb
)
returns numeric
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_producto public.catalogo_productos%rowtype;
  v_precio numeric;
  v_principal text;
  v_principales integer;
  v_extras integer;
  v_queso integer;
  v_cantidad integer;
  v_en_grupo integer;
begin
  select * into v_producto
  from public.catalogo_productos
  where id = p_producto_id and activo;
  if not found or p_nombre is distinct from v_producto.nombre then
    raise exception 'Producto inválido o fuera del catálogo activo';
  end if;
  if p_modificadores is null or jsonb_typeof(p_modificadores) is distinct from 'array' then
    raise exception 'Modificadores inválidos';
  end if;

  v_cantidad := jsonb_array_length(p_modificadores);
  if v_cantidad > 0 and exists (
    select 1 from jsonb_array_elements_text(p_modificadores) m(value)
    where m.value not in (
      'Asada', 'Pastor', 'Tripa', '+ Asada', '+ Pastor', '+ Tripa', 'Con queso',
      'Jamaica', 'Limón', 'Pepino limón', 'Tamarindo', 'Piña', 'Mango', 'Sandía',
      'Horchata', 'Cebada', '1 L', '1/2 L', 'ToniCol', 'Titan'
    )
  ) then
    raise exception 'Modificador inválido';
  end if;
  if (select count(distinct m.value) from jsonb_array_elements_text(p_modificadores) m(value))
       <> v_cantidad then
    raise exception 'No se permiten modificadores duplicados';
  end if;

  v_precio := v_producto.precio;
  if v_producto.permite_mezcla then
    select count(*) filter (where m.value in ('Asada', 'Pastor', 'Tripa')),
           min(m.value) filter (where m.value in ('Asada', 'Pastor', 'Tripa')),
           count(*) filter (where m.value in ('+ Asada', '+ Pastor', '+ Tripa')),
           count(*) filter (where m.value = 'Con queso')
    into v_principales, v_principal, v_extras, v_queso
    from jsonb_array_elements_text(p_modificadores) m(value);

    if v_principales <> 1 then
      raise exception 'Selecciona exactamente una carne principal';
    end if;
    if v_cantidad <> v_principales + v_extras + v_queso then
      raise exception 'Modificador inválido para este producto';
    end if;
    if exists (
      select 1 from jsonb_array_elements_text(p_modificadores) m(value)
      where m.value = '+ ' || v_principal
    ) then
      raise exception 'La carne principal no puede repetirse como extra';
    end if;
    if v_queso > 0 and not v_producto.permite_queso then
      raise exception 'Este producto no acepta queso extra';
    end if;
    if v_principal = 'Tripa' then
      v_precio := v_precio + v_producto.extra_tripa_principal;
    end if;
    v_precio := v_precio + (v_extras * 10) + (v_queso * v_producto.extra_queso);
  elsif v_producto.id = 'agua-sabor' then
    select count(*) into v_en_grupo
    from jsonb_array_elements_text(p_modificadores) m(value)
    where m.value in ('Jamaica', 'Limón', 'Pepino limón', 'Tamarindo', 'Piña', 'Mango', 'Sandía');
    if v_cantidad <> 1 or v_en_grupo <> 1 then
      raise exception 'Selecciona un sabor válido';
    end if;
  elsif v_producto.id = 'horchata' then
    select count(*) into v_en_grupo
    from jsonb_array_elements_text(p_modificadores) m(value)
    where m.value in ('Horchata', 'Cebada');
    if v_en_grupo <> 1 or not exists (
      select 1 from jsonb_array_elements_text(p_modificadores) m(value)
      where m.value in ('1 L', '1/2 L')
    ) or v_cantidad <> 2 then
      raise exception 'Selecciona horchata o cebada y el tamaño';
    end if;
    if p_modificadores ? '1/2 L' then
      v_precio := v_precio / 2;
    end if;
  elsif v_producto.id = 'toni-col' then
    select count(*) into v_en_grupo
    from jsonb_array_elements_text(p_modificadores) m(value)
    where m.value in ('ToniCol', 'Titan');
    if v_cantidad <> 1 or v_en_grupo <> 1 then
      raise exception 'Selecciona ToniCol o Titan';
    end if;
  elsif v_cantidad > 0 then
    raise exception 'Este producto no acepta modificadores';
  end if;

  if p_precio is distinct from v_precio then
    raise exception 'El precio enviado no coincide con el catálogo vigente';
  end if;
  return v_precio;
end;
$$;

revoke all on function public.admin_guardar_producto(text, text, text, numeric, boolean) from public, anon, authenticated;
revoke all on function public.validar_item_comanda(text, text, numeric, jsonb) from public, anon, authenticated;
grant execute on function public.admin_guardar_producto(text, text, text, numeric, boolean) to authenticated;

commit;
