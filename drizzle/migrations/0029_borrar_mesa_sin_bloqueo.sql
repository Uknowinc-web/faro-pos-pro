begin;

create or replace function public.admin_eliminar_mesa(p_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  rec record;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar mesas';
  end if;
  select nombre into v_nombre from public.mesas where id = p_id for update;
  if v_nombre is null then
    raise exception 'Mesa no encontrada';
  end if;

  for rec in
    select n.nspname as schema, c.relname as tabla, a.attname as columna,
           a.attnotnull as requerida, f.confrelid::regclass::text as padre
    from pg_constraint f
    join pg_class c on c.oid = f.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum = f.conkey[1]
    where f.contype = 'f'
      and f.confrelid in (
        'public.mesas'::regclass, 'public.cuentas'::regclass,
        'public.comandas'::regclass, 'public.comanda_items'::regclass
      )
      and n.nspname = 'public'
      and c.relname not in ('mesas', 'cuentas', 'comandas', 'comanda_items')
  loop
    if rec.padre in ('mesas', 'public.mesas') then
      if rec.requerida then
        execute format('delete from %I.%I where %I = $1', rec.schema, rec.tabla, rec.columna) using p_id;
      else
        execute format('update %I.%I set %I = null where %I = $1', rec.schema, rec.tabla, rec.columna, rec.columna) using p_id;
      end if;
    elsif rec.padre in ('cuentas', 'public.cuentas') then
      if rec.requerida then
        execute format('delete from %I.%I where %I in (select id from public.cuentas where mesa_id = $1)', rec.schema, rec.tabla, rec.columna) using p_id;
      else
        execute format('update %I.%I set %I = null where %I in (select id from public.cuentas where mesa_id = $1)', rec.schema, rec.tabla, rec.columna, rec.columna) using p_id;
      end if;
    elsif rec.padre in ('comandas', 'public.comandas') then
      if rec.requerida then
        execute format(
          'delete from %I.%I where %I in (
             select id from public.comandas
             where mesa_id = $1 or cuenta_id in (select id from public.cuentas where mesa_id = $1)
           )',
          rec.schema, rec.tabla, rec.columna
        ) using p_id;
      else
        execute format(
          'update %I.%I set %I = null where %I in (
             select id from public.comandas
             where mesa_id = $1 or cuenta_id in (select id from public.cuentas where mesa_id = $1)
           )',
          rec.schema, rec.tabla, rec.columna, rec.columna
        ) using p_id;
      end if;
    elsif rec.padre in ('comanda_items', 'public.comanda_items') then
      if rec.requerida then
        execute format(
          'delete from %I.%I where %I in (
             select i.id from public.comanda_items i
             join public.comandas co on co.id = i.comanda_id
             where co.mesa_id = $1 or co.cuenta_id in (select id from public.cuentas where mesa_id = $1)
           )',
          rec.schema, rec.tabla, rec.columna
        ) using p_id;
      else
        execute format(
          'update %I.%I set %I = null where %I in (
             select i.id from public.comanda_items i
             join public.comandas co on co.id = i.comanda_id
             where co.mesa_id = $1 or co.cuenta_id in (select id from public.cuentas where mesa_id = $1)
           )',
          rec.schema, rec.tabla, rec.columna, rec.columna
        ) using p_id;
      end if;
    end if;
  end loop;

  delete from public.comanda_items i
  using public.comandas co
  where i.comanda_id = co.id
    and (
      co.mesa_id = p_id
      or co.cuenta_id in (select id from public.cuentas where mesa_id = p_id)
    );
  delete from public.comandas
  where mesa_id = p_id
     or cuenta_id in (select id from public.cuentas where mesa_id = p_id);
  delete from public.cuentas where mesa_id = p_id;
  delete from public.mesa_responsables where mesa_id = p_id;
  delete from public.mesas where id = p_id;

  perform public.registrar_accion(
    'editar_mesa', null, null, null, null,
    jsonb_build_object('nombre', v_nombre, 'eliminada', true)
  );
end;
$$;

revoke all on function public.admin_eliminar_mesa(uuid) from public, anon, authenticated;
grant execute on function public.admin_eliminar_mesa(uuid) to authenticated;

commit;
