alter table public.mesas
  add column if not exists activa boolean not null default true;

update public.mesas
set activa = false
where lower(nombre) = 'barra';
