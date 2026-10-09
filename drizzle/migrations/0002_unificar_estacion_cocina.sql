do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'comanda_items'
      and column_name = 'estacion'
  ) then
    update public.comanda_items
    set estacion = 'cocina'
    where estacion <> 'cocina';
  end if;
end $$;

alter table public.comanda_items
  drop column if exists estacion;

update public.mesas
set nombre = 'Mesa retirada ' || left(id::text, 8),
    activa = false
where lower(nombre) = 'barra';
