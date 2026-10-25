-- ─────────────────────────────────────────────────────────────────────
-- Revisión del comportamiento de los agentes desde el 2026-10-09: la
-- semana anterior a la 0042 (cuarentena) y lo que ha pasado después.
--
-- Una sola consulta y una sola tabla (el editor de Supabase solo devuelve
-- el resultado de la última sentencia), de solo lectura. Columnas:
--   seccion  1_estado | 2_comparativa | 3_dias | 4_ordenes | 5_tendencia | 6_stops
--   agente   nombre del agente
--   clave    fecha, símbolo u orden, según la sección
--   detalle  JSON con los datos
-- Para cambiar la fecha de inicio, editar `desde` en la primera CTE.
-- ─────────────────────────────────────────────────────────────────────
with
p as (select date '2026-10-09' as desde),
ag as (
    select a.id, a.nombre, a.tipo, c.id as cuenta_id
      from public.agentes a
      join public.cuentas_simulacion c on c.id = public.fn_cuenta_agente(a.id)
),
ord as (
    select ag.nombre, o.id, a.simbolo, a.clase, o.estado, o.motivo_cierre,
           o.fecha_entrada, o.fecha_salida, o.precio_entrada, o.precio_salida,
           coalesce(o.sl_original, o.sl) as sl0, o.sl, o.tp,
           o.pnl_bruto + coalesce(o.pnl_parciales, 0) as pnl,
           (o.pnl_bruto + coalesce(o.pnl_parciales, 0))
             / nullif((o.cantidad + coalesce(pa.cantidad, 0))
                      * (o.precio_entrada - coalesce(o.sl_original, o.sl)), 0) as r,
           round((o.precio_entrada - coalesce(o.sl_original, o.sl)) / o.precio_entrada * 100, 2) as dist_sl_pct,
           round((o.tp - o.precio_entrada) / o.precio_entrada * 100, 2) as dist_tp_pct,
           round(extract(epoch from coalesce(o.fecha_salida, now()) - o.fecha_entrada) / 3600, 1) as horas,
           o.margen_comprometido
      from public.ordenes o
      join ag on ag.cuenta_id = o.cuenta_id
      join public.activos a on a.id = o.activo_id
      left join lateral (select sum(x.cantidad) as cantidad
                           from public.ordenes_parciales x where x.orden_id = o.id) pa on true
     where o.estado in ('abierta', 'cerrada')
       and (o.fecha_entrada >= (select desde from p) or o.fecha_salida >= (select desde from p)
            or o.estado = 'abierta')
)
select '1_estado' as seccion, a.nombre as agente, a.tipo as clave,
       jsonb_build_object('estado', a.estado, 'riesgo_reducido', a.riesgo_reducido,
                          'consecuencias_semanales', a.consecuencias_semanales,
                          'equity', round(public.fn_equity(ag.cuenta_id), 2),
                          'saldo_disponible', c.saldo_disponible, 'saldo_bloqueado', c.saldo_bloqueado,
                          'riesgo_pct_operacion', c.riesgo_pct_operacion,
                          'max_posiciones', c.max_posiciones_abiertas)::text as detalle
  from public.agentes a
  join ag on ag.id = a.id
  join public.cuentas_simulacion c on c.id = ag.cuenta_id

union all
select '2_comparativa', v.nombre, 'todo / experimento',
       (to_jsonb(v) - 'agente_id' - 'nombre')::text
  from public.v_comparativa_agentes v

union all
select '3_dias', ag.nombre, d.fecha::text,
       jsonb_build_object('operable', d.operable, 'cumplido', d.cumplido,
                          'rend_pct', d.rendimiento_pct, 'apertura', d.saldo_apertura,
                          'cierre', d.saldo_cierre, 'pnl', d.pnl_realizado,
                          'abiertas', d.ops_abiertas, 'cerradas', d.ops_cerradas,
                          'tp', d.ops_tp, 'sl', d.ops_sl, 'descartes', d.descartes)::text
  from public.agente_dias d
  join ag on ag.id = d.agente_id
 where d.fecha >= (select desde from p)

union all
select '4_ordenes', o.nombre, o.fecha_entrada::date || ' ' || o.simbolo || ' #' || o.id,
       jsonb_build_object('clase', o.clase, 'estado', o.estado, 'motivo', o.motivo_cierre,
                          'entrada', o.fecha_entrada, 'salida', o.fecha_salida,
                          'precio_entrada', o.precio_entrada, 'precio_salida', o.precio_salida,
                          'sl_inicial', o.sl0, 'sl', o.sl, 'tp', o.tp,
                          'dist_sl_pct', o.dist_sl_pct, 'dist_tp_pct', o.dist_tp_pct,
                          'pnl', round(o.pnl, 2), 'r', round(o.r, 3), 'horas', o.horas,
                          'margen', o.margen_comprometido)::text
  from ord o

union all
select '5_tendencia', ag.nombre, d.fecha_vela::text,
       jsonb_object_agg(d.accion, d.n)::text
  from (select agente_id, fecha_vela, accion, count(*) as n
          from public.agente_decisiones_diarias
         where fecha_vela >= (select desde from p)
         group by agente_id, fecha_vela, accion) d
  join ag on ag.id = d.agente_id
 group by ag.nombre, d.fecha_vela

union all
-- 0048: qué pasó después de cada stop. Solo cuentan para la regla de hoy
-- los de entradas desde la 0030 (10-10): antes, el stop iba a 0,1 ATR.
select '6_stops', coalesce(s.agente, 'usuario'),
       case when s.fecha_entrada >= timestamptz '2026-10-10' then 'desde la 0030' else 'antes de la 0030' end
         || ' · ' || coalesce(s.evento, 'pendiente'),
       jsonb_build_object('stops', count(*), 'r_real', round(avg(s.r_real), 3),
                          'caida_r', round(avg(s.caida_r), 3), 'rebote_r', round(avg(s.rebote_r), 3))::text
  from public.v_seguimiento_stops s
 where s.fecha_salida >= (select desde from p)
 group by s.agente, s.fecha_entrada >= timestamptz '2026-10-10', s.evento

order by 1, 2, 3;
