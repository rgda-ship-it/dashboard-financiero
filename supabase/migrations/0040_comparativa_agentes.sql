-- ─────────────────────────────────────────────────────────────────────
-- 0040 — Panel comparativo: agentes de estrategia frente al grupo de
--        control (doc 06 §4.3, 2026-10-11).
--
-- La pregunta del experimento es si «Tendencia cripto» lo hace mejor que
-- los agentes con metas. Para contestarla hacen falta las MISMAS medidas
-- para los cuatro, y la principal no puede ser el porcentaje ganado (los
-- agentes con metas usan apalancamiento y riesgos distintos), sino la
-- expectativa por operación en R: resultado ÷ riesgo inicial.
--
-- El riesgo inicial de una orden se reconstruye igual para todos:
--   cantidad inicial = cantidad que queda + lo cerrado en parciales
--   stop inicial     = sl_original si el stop se movió; si no, sl
--   resultado        = pnl_bruto + pnl_parciales
--
-- Dos ventanas: todo el histórico de la cuenta vigente y «desde el
-- experimento» (el alta del primer agente de estrategia), que es la
-- comparación limpia: mismo mercado, mismas semanas.
-- ─────────────────────────────────────────────────────────────────────

create view public.v_comparativa_agentes
with (security_invoker = true) as
with inicio as (
    select min(creado_en) as desde from public.agentes where tipo = 'estrategia'
), ops as (
    select c.agente_id, o.fecha_entrada,
           o.pnl_bruto + o.pnl_parciales as pnl,
           (o.pnl_bruto + o.pnl_parciales)
             / nullif((o.cantidad + coalesce(p.cantidad, 0))
                      * (o.precio_entrada - coalesce(o.sl_original, o.sl)), 0) as r
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      left join lateral (select sum(x.cantidad) as cantidad
                           from public.ordenes_parciales x where x.orden_id = o.id) p on true
     where c.agente_id is not null
       and o.estado = 'cerrada'
       and c.id = public.fn_cuenta_agente(c.agente_id)
       and o.precio_entrada > coalesce(o.sl_original, o.sl)
)
select g.id as agente_id, g.nombre, g.tipo, g.estado,
       g.objetivo_diario_pct,
       ce.saldo_inicial, ce.equity,
       round((ce.equity / nullif(ce.saldo_inicial, 0) - 1) * 100, 2) as rentabilidad_pct,
       ce.drawdown_pct,
       ce.posiciones_abiertas,
       -- Todo el histórico de la cuenta vigente.
       count(o.r) as cerradas,
       round(avg(o.r), 4) as expectativa_r,
       round(sum(o.r), 2) as r_total,
       round(100.0 * count(*) filter (where o.r > 0) / nullif(count(o.r), 0), 1) as aciertos_pct,
       round(sum(o.r) filter (where o.r > 0) / nullif(-sum(o.r) filter (where o.r <= 0), 0), 2) as factor_beneficio,
       round(sum(o.pnl), 2) as pnl,
       -- Desde el experimento.
       i.desde as experimento_desde,
       count(o.r) filter (where o.fecha_entrada >= i.desde) as cerradas_exp,
       round(avg(o.r) filter (where o.fecha_entrada >= i.desde), 4) as expectativa_r_exp,
       round(sum(o.r) filter (where o.fecha_entrada >= i.desde), 2) as r_total_exp,
       round(sum(o.pnl) filter (where o.fecha_entrada >= i.desde), 2) as pnl_exp
  from public.agentes g
  cross join inicio i
  left join public.v_cuentas_equity ce on ce.id = public.fn_cuenta_agente(g.id)
  left join ops o on o.agente_id = g.id
 group by g.id, g.nombre, g.tipo, g.estado, g.objetivo_diario_pct, ce.saldo_inicial, ce.equity,
          ce.drawdown_pct, ce.posiciones_abiertas, i.desde;

comment on view public.v_comparativa_agentes is
  'Las mismas medidas para todos los agentes (0040): expectativa en R (resultado ÷ riesgo inicial, con parciales), aciertos, factor de beneficio y P&L, en todo el histórico y desde el alta del primer agente de estrategia.';
