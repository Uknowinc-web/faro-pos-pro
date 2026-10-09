begin;

create or replace function public.validar_item_comanda(
  p_producto_id text,
  p_nombre text,
  p_precio numeric,
  p_modificadores jsonb
)
returns numeric
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_precio numeric;
  v_tripa_extra numeric := 0;
  v_carnes_principales integer := 0;
  v_carne_principal text;
  v_carnes_extra integer := 0;
  v_queso integer := 0;
  v_modificadores integer := 0;
begin
  select producto.nombre, producto.precio
  into v_nombre, v_precio
  from (values
    ('taco-maiz', 'Taco maíz', 40::numeric, 5::numeric, true, true),
    ('taco-harina', 'Taco harina', 42::numeric, 5::numeric, true, true),
    ('quesadilla-maiz', 'Quesadilla maíz', 65::numeric, 10::numeric, true, false),
    ('quesadilla-harina', 'Quesadilla harina', 95::numeric, 10::numeric, true, false),
    ('vampiro', 'Vampiro', 75::numeric, 10::numeric, true, false),
    ('chorreada', 'Chorreada', 80::numeric, 10::numeric, true, false),
    ('costra', 'Costra de queso', 100::numeric, 0::numeric, false, false),
    ('gaonera', 'Gaonera', 75::numeric, 0::numeric, false, false),
    ('chilaca', 'Taco de Chile chilaca', 80::numeric, 0::numeric, false, false),
    ('papa-especial', 'Papa asada especial', 180::numeric, 10::numeric, true, false),
    ('papa-sencilla', 'Papa sencilla', 130::numeric, 0::numeric, false, false),
    ('charros-especiales', 'Charros especiales', 75::numeric, 0::numeric, false, false),
    ('charros-sencillos', 'Charros sencillos', 55::numeric, 0::numeric, false, false),
    ('torta', 'Torta', 130::numeric, 10::numeric, true, false),
    ('hamburguesa', 'Hamburguesa', 125::numeric, 0::numeric, false, false),
    ('quesagloria', 'Quesagloria', 100::numeric, 0::numeric, false, false),
    ('agua-natural', 'Agua natural', 15::numeric, 0::numeric, false, false),
    ('agua-sabor', 'Agua de sabor 1L', 45::numeric, 0::numeric, false, false),
    ('horchata', 'Horchata y cebada 1L', 50::numeric, 0::numeric, false, false),
    ('topo-chico', 'Topo Chico', 35::numeric, 0::numeric, false, false),
    ('toni-col', 'ToniCol', 55::numeric, 0::numeric, false, false)
  ) as producto(id, nombre, precio, extra_tripa, mixeable, permite_queso)
  where producto.id = p_producto_id;

  if v_nombre is null or p_nombre is distinct from v_nombre then
    raise exception 'Producto inválido o fuera del catálogo';
  end if;
  if p_modificadores is null or jsonb_typeof(p_modificadores) is distinct from 'array' then
    raise exception 'Modificadores inválidos';
  end if;

  v_modificadores := jsonb_array_length(p_modificadores);
  if v_modificadores > 0 then
    if exists (
      select 1
      from jsonb_array_elements_text(p_modificadores) as modifier(value)
      where modifier.value not in (
        'Asada', 'Pastor', 'Tripa', '+ Asada', '+ Pastor', '+ Tripa', 'Con queso'
      )
    ) then
      raise exception 'Modificador inválido';
    end if;
    if (
      select count(distinct modifier.value)
      from jsonb_array_elements_text(p_modificadores) as modifier(value)
    ) <> v_modificadores then
      raise exception 'No se permiten modificadores duplicados';
    end if;
  end if;

  if (select producto.mixeable
      from (values
        ('taco-maiz', true), ('taco-harina', true), ('quesadilla-maiz', true),
        ('quesadilla-harina', true), ('vampiro', true), ('chorreada', true),
        ('papa-especial', true), ('torta', true)
      ) as producto(id, mixeable)
      where producto.id = p_producto_id) then
    select count(*) filter (where modifier.value in ('Asada', 'Pastor', 'Tripa')),
           min(modifier.value) filter (where modifier.value in ('Asada', 'Pastor', 'Tripa')),
           count(*) filter (where modifier.value in ('+ Asada', '+ Pastor', '+ Tripa')),
           count(*) filter (where modifier.value = 'Con queso')
    into v_carnes_principales, v_carne_principal, v_carnes_extra, v_queso
    from jsonb_array_elements_text(p_modificadores) as modifier(value);

    if v_carnes_principales <> 1 then
      raise exception 'Selecciona exactamente una carne principal';
    end if;
    if exists (
      select 1
      from jsonb_array_elements_text(p_modificadores) as modifier(value)
      where modifier.value = '+ ' || v_carne_principal
    ) then
      raise exception 'La carne principal no puede repetirse como extra';
    end if;
    if v_queso > 0 and p_producto_id not in ('taco-maiz', 'taco-harina') then
      raise exception 'El queso extra solo está disponible en tacos';
    end if;
    if v_carne_principal = 'Tripa' then
      v_precio := v_precio + case when p_producto_id in ('taco-maiz', 'taco-harina') then 5 else 10 end;
    end if;
    v_precio := v_precio + (v_carnes_extra * 10) + (v_queso * 5);
  elsif v_modificadores > 0 then
    raise exception 'Este producto no acepta modificadores';
  end if;

  if p_precio is distinct from v_precio then
    raise exception 'El precio enviado no coincide con el catálogo vigente';
  end if;
  return v_precio;
end;
$$;

revoke all on function public.validar_item_comanda(text, text, numeric, jsonb)
  from public, anon, authenticated;

create or replace function public.enviar_comanda(
  p_mesa uuid,
  p_token text,
  p_items jsonb,
  p_mesero text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_cuenta uuid;
  v_comanda uuid;
  v_precio numeric;
  it jsonb;
begin
  if not public.tiene_rol(array['mesero', 'admin']::text[]) then
    raise exception 'No autorizado para enviar comandas';
  end if;
  if coalesce(trim(p_token), '') = ''
     or jsonb_typeof(p_items) is distinct from 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Token e items válidos requeridos';
  end if;
  if not exists (select 1 from public.mesas where id = p_mesa and activa) then
    raise exception 'Mesa no disponible';
  end if;

  select id into v_comanda
  from public.comandas
  where client_token = p_token;
  if v_comanda is not null then
    return v_comanda;
  end if;

  select id into v_cuenta
  from public.cuentas
  where mesa_id = p_mesa and estado in ('abierta', 'por_cobrar')
  for update;
  if v_cuenta is null then
    insert into public.cuentas(mesa_id) values (p_mesa) returning id into v_cuenta;
  else
    update public.cuentas set estado = 'abierta' where id = v_cuenta;
  end if;

  insert into public.comandas(cuenta_id, mesa_id, client_token, mesero)
  values (v_cuenta, p_mesa, p_token, auth.jwt()->>'email')
  returning id into v_comanda;

  for it in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(it->>'producto_id', '') = ''
       or coalesce(it->>'nombre', '') = ''
       or coalesce((it->>'cantidad')::integer, 0) not between 1 and 99 then
      raise exception 'Artículo de comanda inválido';
    end if;
    v_precio := public.validar_item_comanda(
      it->>'producto_id',
      it->>'nombre',
      (it->>'precio_unitario')::numeric,
      coalesce(it->'modificadores', '[]'::jsonb)
    );
    insert into public.comanda_items(
      comanda_id, producto_id, nombre, cantidad, precio_unitario, modificadores, notas
    )
    values (
      v_comanda, it->>'producto_id', it->>'nombre',
      (it->>'cantidad')::integer, v_precio,
      coalesce(it->'modificadores', '[]'::jsonb), nullif(it->>'notas', '')
    );
  end loop;

  update public.mesas set estado = 'ocupada' where id = p_mesa;
  return v_comanda;
end;
$$;

revoke all on function public.enviar_comanda(uuid, text, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.enviar_comanda(uuid, text, jsonb, text)
  to authenticated;

commit;
