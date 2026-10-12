begin;

update public.catalogo_productos
set categoria = 'Especiales', updated_at = now()
where id in ('hamburguesa', 'torta');

-- La papa asada especial se agrega sin personalizar.
update public.catalogo_productos
set permite_mezcla = false, updated_at = now()
where id = 'papa-especial';

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
      'Horchata', 'Cebada', '1 L', '1/2 L', 'ToniCol', 'Titan', 'Costra de queso'
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
  elsif v_producto.id = 'gaonera' then
    if v_cantidad > 1 or (v_cantidad = 1 and not p_modificadores ? 'Costra de queso') then
      raise exception 'Modificador inválido para este producto';
    end if;
    if v_cantidad = 1 then
      v_precio := v_precio + 15;
    end if;
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

revoke all on function public.validar_item_comanda(text, text, numeric, jsonb) from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';
