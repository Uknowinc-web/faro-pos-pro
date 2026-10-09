begin;

drop policy if exists "personal puede consultar cuentas" on public.cuentas;

create policy "caja y administradores pueden consultar cuentas"
  on public.cuentas for select to authenticated
  using (public.tiene_rol(array['caja', 'admin']::text[]));

commit;
