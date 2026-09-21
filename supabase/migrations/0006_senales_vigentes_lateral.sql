-- ─────────────────────────────────────────────────────────────────────
-- 0006 — `senales_vigentes` lee UNA fila por activo, no la tabla entera.
--
-- H-08 (Sprint 2). Medido con volumen sintético de un año —150 activos,
-- 20 señales/día en los últimos 30 días y 3/día en los 13 meses
-- anteriores: 265.650 filas, 83 MB—, la versión con DISTINCT ON:
--
--   Unique -> Merge Join -> Index Scan senales_activo_fecha_idx
--   rows=265650 · shared hit=266.985 buffers · 227 ms (caché caliente)
--
-- DISTINCT ON no sabe «saltar» dentro del índice: recorre todas las
-- señales de cada activo para quedarse con la primera. El coste crece
-- con la HISTORIA, no con el universo, y el escáner lo paga en cada
-- relectura (cada 2 minutos por pestaña abierta).
--
-- Con LATERAL + LIMIT 1, PostgreSQL baja una vez por activo al índice
-- (activo_id, calculado_en desc) y lee una sola fila. Mismo resultado,
-- coste proporcional al número de activos. Medición tras el cambio en
-- docs/fase-2/04-sprint-backlog.md, H-08.
--
-- Mismas columnas y mismo orden que la versión anterior (s.*, simbolo,
-- clase, nombre, estado_activo), por eso vale CREATE OR REPLACE y el
-- frontend no cambia. security_invoker se vuelve a fijar explícitamente
-- (I13): una vista recreada sin él se saltaría la RLS.
-- ─────────────────────────────────────────────────────────────────────

create or replace view public.senales_vigentes
with (security_invoker = true) as
    select s.*,
           a.simbolo,
           a.clase,
           a.nombre,
           a.estado as estado_activo
      from public.activos a
      cross join lateral (
            select *
              from public.senales s1
             where s1.activo_id = a.id
             order by s1.calculado_en desc
             limit 1
      ) s;

comment on view public.senales_vigentes is
  'Última señal de cada activo. LATERAL + LIMIT 1 sobre senales_activo_fecha_idx: una lectura de índice por activo (0006, H-08).';
