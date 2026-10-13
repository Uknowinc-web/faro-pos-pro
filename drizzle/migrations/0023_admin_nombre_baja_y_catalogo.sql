begin;

-- ---------------------------------------------------------------------------
-- Nombre de admin: queda registro del cambio (antes / después).
-- ---------------------------------------------------------------------------
alter table public.audit_acciones drop constraint if exists audit_acciones_accion_check;
alter table public.audit_acciones add constraint audit_acciones_accion_check
  check (accion in (
    'enviar_comanda', 'reclamar_mesa', 'actualizar_comanda',
    'cobrar_cuenta', 'anular_cuenta',
    'entrada_empleado', 'salida_empleado',
    'editar_producto', 'editar_mesa', 'editar_comanda', 'editar_empleado',
    'cambio_nombre_admin', 'baja_empleado', 'eliminar_producto'
  ));

create or replace function public.guardar_perfil_admin(p_nombre text)
returns text
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text := trim(coalesce(p_nombre, ''));
  v_anterior text;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración';
  end if;
  if char_length(v_nombre) not between 1 and 60 then
    raise exception 'Escribe un nombre de 1 a 60 caracteres';
  end if;
  select nombre into v_anterior from public.admin_perfiles where user_id = auth.uid();
  if v_anterior is not distinct from v_nombre then
    return v_nombre;
  end if;
  begin
    insert into public.admin_perfiles(user_id, nombre) values (auth.uid(), v_nombre)
    on conflict (user_id) do update set nombre = excluded.nombre, actualizado_at = now();
  exception when unique_violation then
    raise exception 'Ya hay un administrador con ese nombre. Elige otro';
  end;
  insert into public.audit_acciones(
    user_id, device_label, role, accion, detalle, responsable
  ) values (
    auth.uid(), 'Administración', 'admin', 'cambio_nombre_admin',
    jsonb_build_object('anterior', coalesce(v_anterior, ''), 'nuevo', v_nombre),
    v_nombre
  );
  return v_nombre;
end;
$$;

-- ---------------------------------------------------------------------------
-- Producto: personalizable o fijo. Se puede eliminar del menú.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_guardar_producto(text, text, text, numeric, boolean);

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
       'Tortas', 'Postres', 'Bebidas', 'Promociones'
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

create or replace function public.admin_eliminar_producto(p_id text)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_usado boolean;
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede eliminar productos';
  end if;
  select nombre into v_nombre from public.catalogo_productos where id = p_id;
  if not found then
    raise exception 'Producto no encontrado';
  end if;
  select exists (
    select 1 from public.comanda_items where producto_id = p_id
  ) into v_usado;
  if v_usado then
    update public.catalogo_productos set activo = false, updated_at = now() where id = p_id;
  else
    delete from public.catalogo_productos where id = p_id;
  end if;
  insert into public.audit_acciones(
    user_id, device_label, role, accion, detalle, responsable
  )
  select auth.uid(), 'Administración', 'admin', 'eliminar_producto',
         jsonb_build_object('producto_id', p_id, 'nombre', v_nombre, 'borrado', not v_usado),
         coalesce((select nombre from public.admin_perfiles where user_id = auth.uid()), 'Administrador');
end;
$$;

-- ---------------------------------------------------------------------------
-- Baja de empleado: cierra turno, libera mesas, desactiva.
-- ---------------------------------------------------------------------------
create or replace function public.admin_dar_baja_empleado(p_id uuid)
returns void
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_nombre text;
  v_devices uuid[];
begin
  if not public.tiene_rol(array['admin']::text[]) then
    raise exception 'Solo administración puede dar de baja empleados';
  end if;
  select nombre into v_nombre from public.empleados where id = p_id;
  if not found then
    raise exception 'Empleado no encontrado';
  end if;

  select array_agg(distinct a.user_id) into v_devices
  from public.asistencias a
  where a.empleado_id = p_id and a.salida_at is null;

  update public.asistencias
  set salida_at = now()
  where empleado_id = p_id and salida_at is null;

  if v_devices is not null then
    delete from public.mesa_responsables where user_id = any(v_devices);
  end if;

  update public.empleados
  set activo = false, pin_texto = null, pin_hash = null, actualizado_at = now()
  where id = p_id;

  insert into public.audit_acciones(
    user_id, device_label, role, accion, empleado_id, detalle, responsable
  )
  select auth.uid(), 'Administración', 'admin', 'baja_empleado', p_id,
         jsonb_build_object('empleado', v_nombre, 'mesas_liberadas', coalesce(array_length(v_devices, 1), 0)),
         coalesce((select nombre from public.admin_perfiles where user_id = auth.uid()), 'Administrador');
end;
$$;

revoke all on function public.guardar_perfil_admin(text) from public, anon, authenticated;
revoke all on function public.admin_guardar_producto(text, text, text, numeric, boolean, boolean, boolean) from public, anon, authenticated;
revoke all on function public.admin_eliminar_producto(text) from public, anon, authenticated;
revoke all on function public.admin_dar_baja_empleado(uuid) from public, anon, authenticated;

grant execute on function public.guardar_perfil_admin(text) to authenticated;
grant execute on function public.admin_guardar_producto(text, text, text, numeric, boolean, boolean, boolean) to authenticated;
grant execute on function public.admin_eliminar_producto(text) to authenticated;
grant execute on function public.admin_dar_baja_empleado(uuid) to authenticated;

commit;
