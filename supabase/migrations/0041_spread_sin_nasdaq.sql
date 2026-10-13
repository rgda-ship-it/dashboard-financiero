-- ─────────────────────────────────────────────────────────────────────
-- 0041 — Fuera las medidas de spread de los valores de Nasdaq (2026-10-13).
--
-- La primera sesión medida (2026-10-12) mostró que el precio de compra y
-- de venta que da Yahoo para las acciones de Nasdaq no es el libro real:
--   • AMZN 260,78 / 267,77, SPCX 160,03 / 163,97 y el ask de AAPL y MSFT
--     idénticos en las 12 medidas del día, y AMZN otra vez igual en el
--     premercado del 13: una cotización congelada.
--   • Spreads del 1–2,7 % (AAPL 6,96 $, AMZN 6,99 $, MSFT 5,86 $,
--     NVDA 2,88 $, SPCX 3,94 $) en valores cuyo spread real es de
--     céntimos. Como la 0035 cobra el mayor entre lo configurado y lo
--     observado, los agentes con metas pagaban ese spread.
--   • CSCO, KMB, UAL, QFIN y CCOI sin ninguna medida válida, y TROW, AGNC
--     y TSLA con muy pocas.
-- Los 19 valores de NYSE dan datos coherentes, que cambian en cada medida.
--
-- Desde ahora el ETL no mide en Nasdaq (`BOLSAS_SIN_LIBRO_FIABLE` en el
-- conector de Yahoo): ahí se cobra el configurado (0,03 $), que en estos
-- valores tan líquidos ya es pesimista. Esta migración borra lo que ya se
-- guardó, para que deje de cobrarse hoy y no dentro de 30 días.
-- ─────────────────────────────────────────────────────────────────────

with nasdaq as (
    select id from public.activos
     where clase = 'accion'
       and simbolo in ('AAPL', 'AMZN', 'MSFT', 'NVDA', 'SPCX', 'TSLA', 'CSCO',
                       'KMB', 'UAL', 'TROW', 'AGNC', 'QFIN', 'CCOI')
), borradas as (
    delete from public.spreads_observados s using nasdaq n where s.activo_id = n.id
)
update public.activos a
   set spread_observado = null, spread_observado_n = 0, spread_observado_en = now()
  from nasdaq n
 where a.id = n.id;
