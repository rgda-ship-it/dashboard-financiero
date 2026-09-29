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

-- ── Sprint 3: lo que las políticas y los triggers de 0007 necesitan ──
-- Dos columnas más de auth.users: el trigger de alta lee el correo y la
-- promoción del admin inicial exige que esté confirmado.
alter table auth.users add column if not exists email text;
alter table auth.users add column if not exists email_confirmed_at timestamptz;

-- auth.uid() como la define Supabase: el `sub` del JWT de la petición.
-- Las pruebas simulan una petición con
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub": "<uuid>"}';
create or replace function auth.uid()
returns uuid
language sql stable
as $$
    -- El `nullif(…, '')` interior es el de la definición real: tras un
    -- `set_config('request.jwt.claims', '', …)` —lo que hace
    -- `pg_temp.como_dueno()`— el ajuste existe pero vacío, y sin él el
    -- cast a jsonb revienta. Pasa de verdad en el ciclo de agentes, que
    -- llama a `rpc_abrir_orden` sin JWT.
    select nullif(
        coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                 nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'),
        '')::uuid
$$;

grant usage on schema auth   to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Supabase concede por defecto todo sobre public a los tres roles y deja
-- que RLS decida. Se imita para que las pruebas midan la RLS y los
-- REVOKE de las migraciones, no la ausencia de GRANT de un Postgres pelado.
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
