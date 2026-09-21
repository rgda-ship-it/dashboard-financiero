-- ─────────────────────────────────────────────────────────────────────
-- Lo mínimo que Supabase aporta y un PostgreSQL limpio no tiene.
--
-- Se usa SOLO en la CI y en pruebas locales contra un Postgres vanilla.
-- Nunca se aplica a un proyecto de Supabase real: allí `auth.users` y
-- los tres roles ya existen, y ejecutar esto los pisaría.
-- ─────────────────────────────────────────────────────────────────────

create schema if not exists auth;
create schema if not exists extensions;

-- Solo la columna que el esquema del dashboard referencia. No se imita
-- el resto de auth.users: si algún día una migración necesitara otra
-- columna de esa tabla, es mejor que la prueba falle de forma ruidosa a
-- que pase con un doble incompleto.
create table if not exists auth.users (
    id uuid primary key default gen_random_uuid()
);

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role;
    end if;
end $$;
