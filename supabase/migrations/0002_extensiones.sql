-- ─────────────────────────────────────────────────────────────────────
-- 0002 — Extensiones de PostgreSQL.
--
-- Separadas de 0000 y 0001 a propósito: son lo ÚNICO del esquema que
-- necesita un PostgreSQL de Supabase y no vale un PostgreSQL cualquiera.
--
-- Esa separación es lo que permite que `.github/workflows/migraciones.yml`
-- aplique el resto del esquema desde cero sobre un Postgres limpio en
-- cada pull request. Y esa puerta importa más de lo normal en este
-- proyecto: el tier gratuito de Supabase da dos proyectos activos, uno
-- lo ocupa otra aplicación y el otro es producción del dashboard, así
-- que NO HAY PROYECTO DE STAGING. Cada migración que se mergea va a
-- producción sin escala intermedia, y la única validación automática es
-- la de la CI.
--
-- Si esta migración falla al aplicarse, habilita las dos extensiones
-- desde el panel del proyecto (Database -> Extensions) y vuelve a
-- lanzar `supabase db push`.
-- ─────────────────────────────────────────────────────────────────────

-- pg_cron dispara el monitor de órdenes (cada minuto) y el ciclo de
-- agentes (cada 5 min). Es la pieza que sustituye al cron de Vercel,
-- cuyo plan Hobby está limitado a UNA ejecución diaria — inútil para
-- vigilar un Take Profit.
create extension if not exists pg_cron;

-- pg_net permite que un job de SQL llame por HTTP a una Edge Function.
-- Sin él, pg_cron solo podría ejecutar SQL, y el monitor necesita pedir
-- el precio vivo.
create extension if not exists pg_net with schema extensions;
