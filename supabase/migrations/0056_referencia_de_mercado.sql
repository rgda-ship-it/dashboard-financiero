-- ─────────────────────────────────────────────────────────────────────
-- 0056 — Referencia de mercado: comprar y mantener el universo
--        (doc fase-3/08 §4.5, 2026-11-05).
--
-- La comparativa de agentes (0040) no decía si un agente aporta algo o
-- solo sigue al mercado. Esta vista da lo que habría hecho comprar y
-- mantener, a partes iguales y sin apalancamiento, desde las mismas
-- fechas que los agentes:
--
--   universo  todos los activos activos (acciones y criptos), como operan
--             los agentes con metas
--   acciones  las acciones activas del universo
--   cripto    las criptos activas
--   bitcoin   solo bitcoin
--
-- Dos ventanas: desde el alta de los agentes con metas (29-09) y desde el
-- experimento (alta del primer agente de estrategia, 11-10). Cada activo
-- entra con el primer cierre desde esa fecha, solo si lo hay en los 4
-- días siguientes (un activo dado de alta después no cuenta), y sale con
-- su último cierre. Sin costes ni spread: es la vara, no una cuenta.
--
-- Y la comparativa (0040) suma al final la desviación de la R por
-- operación, con la que la pantalla dice cuántas operaciones faltan para
-- poder concluir algo (doc fase-3/08 §4.3): n ≥ (1,645 × σ / E)².
--
-- No cambia nada del grupo de control: solo lee.
-- ─────────────────────────────────────────────────────────────────────

create view public.v_referencia_mercado
with (security_invoker = true) as
with ventanas as (
    select 'alta'::text as ventana, min(creado_en)::date as desde
      from public.agentes where tipo = 'metas'
    union all
    select 'experimento', min(creado_en)::date
      from public.agentes where tipo = 'estrategia'
), grupos as (
    select a.id as activo_id, g.referencia
      from public.activos a
      cross join lateral (values ('universo'),
                                 (case a.clase when 'accion' then 'acciones' else 'cripto' end),
                                 (case when a.simbolo = 'bitcoin' then 'bitcoin' end)) g(referencia)
     where a.estado = 'activo' and g.referencia is not null
), extremos as (
    select v.ventana, v.desde, gr.referencia, ini.cierre as c0, fin.fecha as f1, fin.cierre as c1
      from ventanas v
      cross join grupos gr
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = gr.activo_id and p.fecha >= v.desde
                     order by p.fecha limit 1) ini on true
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = gr.activo_id
                     order by p.fecha desc limit 1) fin on true
     where v.desde is not null and ini.fecha <= v.desde + 4 and ini.cierre > 0
)
select referencia, ventana, desde, max(f1) as hasta, count(*) as activos,
       round(avg(c1 / c0 - 1) * 100, 2) as rentabilidad_pct
  from extremos
 group by referencia, ventana, desde;

comment on view public.v_referencia_mercado is
  'Comprar y mantener el universo a partes iguales (todo, acciones, cripto y bitcoin), sin apalancamiento ni costes, desde el alta de los agentes con metas y desde el experimento (0056). La vara de la comparativa de agentes.';

grant select on public.v_referencia_mercado to authenticated;

do $lectura$
begin
    if exists (select 1 from pg_roles where rolname = 'analista_lectura') then
        grant select on public.v_referencia_mercado to analista_lectura;
    end if;
end
$lectura$;

-- ── La comparativa, con la desviación de la R al final ───────────────
create or replace view public.v_comparativa_agentes
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
       round(sum(o.pnl) filter (where o.fecha_entrada >= i.desde), 2) as pnl_exp,
       -- 0056, al final: la desviación de la R por operación, para saber
       -- cuántas operaciones hacen falta antes de concluir (fase-3/08 §4.3).
       round(stddev_samp(o.r), 4) as desviacion_r,
       round(stddev_samp(o.r) filter (where o.fecha_entrada >= i.desde), 4) as desviacion_r_exp
  from public.agentes g
  cross join inicio i
  left join public.v_cuentas_equity ce on ce.id = public.fn_cuenta_agente(g.id)
  left join ops o on o.agente_id = g.id
 group by g.id, g.nombre, g.tipo, g.estado, g.objetivo_diario_pct, ce.saldo_inicial, ce.equity,
          ce.drawdown_pct, ce.posiciones_abiertas, i.desde;
