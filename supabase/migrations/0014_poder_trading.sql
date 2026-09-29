-- ─────────────────────────────────────────────────────────────────────
-- 0014 — Poder de trading por escalas, como QuantFury (decisión D15).
--
-- D15 (2026-09-29) — DOS CIFRAS DISTINTAS, Y NINGUNA SUSTITUYE A LA OTRA.
--
--   · El TOPE DE APALANCAMIENTO (5× en Fase 1, 3× en Fase 2) es la regla
--     de lo que es RECOMENDABLE operar. Es la regla protegida nº1 y no
--     cambia: G1, el CHECK de `ordenes` y la máquina de fases siguen igual.
--   · El PODER DE TRADING es lo que el bróker PERMITE por el saldo de la
--     cuenta: hasta 20×, por escalas de equity. Es la capacidad, no la
--     recomendación.
--
--   Escalas del dueño (QuantFury):
--
--       equity ≥     1.000 $  →     20.000 $
--       equity ≥     2.000 $  →     40.000 $
--       equity ≥     5.000 $  →    100.000 $
--       equity ≥    10.000 $  →    200.000 $
--       equity ≥    15.000 $  →    300.000 $
--       equity ≥    20.000 $  →    400.000 $
--       equity ≥    25.000 $  →    500.000 $
--       equity ≥    50.000 $  →  1.000.000 $
--
--   Por debajo de 1.000 $ se aplica 20× sobre el equity (500 $ → 10.000 $,
--   el ejemplo del dueño). Por encima de 50.000 $ la tabla no dice más, así
--   que el poder se queda en 1.000.000 $: es el último valor conocido y no
--   se inventa un tramo.
--
-- POR QUÉ NO HAY UN GUARDARRAÍL NUEVO EN `rpc_abrir_orden`
--
--   Con el tope de 5× y el de margen comprometido (60 % como máximo), el
--   nominal abierto de una cuenta no puede pasar de 3× su equity; el poder
--   de trading empieza en 20×. Una comprobación que no puede dispararse no
--   protege nada y sí añade un sitio más donde equivocarse. Si algún día el
--   tope de apalancamiento subiera, ESTE sería el límite que habría que
--   imponer — la invariante I54 deja escrita la relación.
-- ─────────────────────────────────────────────────────────────────────

-- Pura: sin tablas y sin SECURITY DEFINER, así que se concede a
-- `authenticated` para que las vistas con security_invoker la usen (regla
-- de la 0012).
create function public.fn_poder_trading(p_equity numeric)
returns numeric
language sql immutable
as $$
    select case
        when p_equity is null or p_equity <= 0 then 0
        when p_equity >= 50000 then 1000000
        when p_equity >= 25000 then 500000
        when p_equity >= 20000 then 400000
        when p_equity >= 15000 then 300000
        when p_equity >= 10000 then 200000
        when p_equity >=  5000 then 100000
        when p_equity >=  2000 then  40000
        when p_equity >=  1000 then  20000
        else round(p_equity * 20, 2)
    end::numeric
$$;

comment on function public.fn_poder_trading(numeric) is
  'D15: poder de trading por escalas de equity (QuantFury, hasta 20×). Capacidad del bróker, NO recomendación: el tope operable sigue siendo fn_tope_fase().';

revoke execute on function public.fn_poder_trading(numeric) from public, anon;
grant  execute on function public.fn_poder_trading(numeric) to authenticated;

-- La misma vista de la 0011 con dos columnas más AL FINAL (es lo único
-- que admite CREATE OR REPLACE VIEW): el poder de trading y el nominal
-- que la cuenta tiene abierto, para ver cuánto de ese poder se usa.
create or replace view public.v_cuentas_equity
with (security_invoker = true) as
    select c.*,
           coalesce(p.pnl_no_realizado, 0) as pnl_no_realizado,
           c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0) as equity,
           coalesce(p.posiciones_abiertas, 0) as posiciones_abiertas,
           public.fn_tope_fase(c.fase) as leverage_tope,
           case when c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0) > 0
                then round(c.saldo_bloqueado * 100
                           / (c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)), 2)
           end as margen_comprometido_pct,
           case when c.capital_maximo_alcanzado > 0
                then round((c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)
                            - c.capital_maximo_alcanzado) * 100 / c.capital_maximo_alcanzado, 2)
           end as drawdown_pct,
           public.fn_poder_trading(
               c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)) as poder_trading,
           coalesce(p.nominal_abierto, 0) as nominal_abierto
      from public.cuentas_simulacion c
      left join lateral (
           select sum(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                               -o.margen_comprometido)) as pnl_no_realizado,
                  count(*) as posiciones_abiertas,
                  sum(o.nominal) as nominal_abierto
             from public.ordenes o
             join public.activos a on a.id = o.activo_id
            where o.cuenta_id = c.id and o.estado = 'abierta'
              and a.ultimo_precio is not null
      ) p on true;
