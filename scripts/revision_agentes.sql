-- ─────────────────────────────────────────────────────────────────────
-- Revisión de los lunes (E3, doc fase-3/07 §6): todo lo que hay que mirar
-- cada semana, en una sola consulta de solo lectura.
--
--     python scripts/consultar.py -f scripts/revision_agentes.sql
--
-- Una sola consulta y una sola tabla (el editor de Supabase solo devuelve
-- el resultado de la última sentencia). Funciona con `analista_lectura`:
-- no llama a `rpc_salud_sistema` (solo admin), lee sus mismas tablas.
-- Columnas:
--   seccion  0_salud | 1_estado | 2_comparativa | 3_dias | 4_ordenes
--            | 5_tendencia | 5b_tendencia_cerca | 6_stops | 7_hipotesis
--            | 8_backlog | 9_descartes
--   agente   nombre del agente (o «sistema»)
--   clave    fecha, símbolo u orden, según la sección
--   detalle  JSON con los datos
-- Por defecto, los últimos 7 días. Para otro periodo, editar `desde` en
-- la primera CTE (p. ej. date '2026-10-09').
-- ─────────────────────────────────────────────────────────────────────
with
p as (select current_date - 7 as desde),
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
-- 0045: lo mismo que el panel «Salud del sistema». Un `fallando_desde`
-- no nulo, una clase con señales viejas o fallos en la semana son lo
-- primero que hay que mirar.
select '0_salud' as seccion, 'sistema' as agente, 'etl ' || d.clave as clave,
       jsonb_build_object('ultimo_disparo', d.ultimo, 'estado_http', d.estado_http,
                          'fallando_desde', d.fallando_desde)::text as detalle
  from public.control_despachos d
 where d.clave in ('etl-acciones.yml', 'etl-cripto.yml')

union all
select '0_salud', 'sistema', 'señales ' || a.clase,
       jsonb_build_object('activos', count(*), 'con_senal', count(s.calculado_en),
                          'ultima', max(s.calculado_en), 'la_mas_vieja', min(s.calculado_en))::text
  from public.activos a
  left join public.senales_vigentes s on s.activo_id = a.id
 where a.estado = 'activo'
 group by a.clase

union all
select '0_salud', coalesce(g.nombre, 'sistema'), 'fallos de la semana',
       jsonb_build_object('fallos', count(*), 'ultimo', max(e.creado_en),
                          'ultimo_mensaje', (array_agg(e.mensaje order by e.id desc))[1])::text
  from public.eventos_sistema e
  left join public.agentes g on g.id = e.agente_id
 where e.tipo = 'fallo' and e.creado_en >= (select desde from p)
 group by g.nombre

union all
-- 0050: solo las que caducan en menos de 60 días (o ya caducaron).
select '0_salud', 'sistema', 'credencial ' || c.nombre,
       jsonb_build_object('caduca_en', c.caduca_en, 'dias', c.caduca_en - current_date,
                          'donde', c.donde, 'renovar', c.renovar)::text
  from public.credenciales c
 where c.caduca_en is not null and c.caduca_en - current_date < 60

union all
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
-- Tendencia cripto (doc 07): con la última vela decidida, lo cerca que
-- está cada cripto de entrar. Entra con el cierre sobre la media de 200 y
-- sobre el máximo de la ruptura; `atr_a_ruptura` es cuánto le falta.
select '5b_tendencia_cerca', ag.nombre, a.simbolo,
       jsonb_build_object('fecha_vela', d.fecha_vela, 'accion', d.accion,
                          'sobre_media_200', (d.datos ->> 'cierre')::numeric > (d.datos ->> 'sma')::numeric,
                          'atr_a_ruptura', round(((d.datos ->> 'max_ruptura')::numeric - (d.datos ->> 'cierre')::numeric)
                                                 / nullif((d.datos ->> 'atr')::numeric, 0), 2),
                          'cierre', d.datos -> 'cierre', 'max_ruptura', d.datos -> 'max_ruptura')::text
  from public.agente_decisiones_diarias d
  join ag on ag.id = d.agente_id
  join public.activos a on a.id = d.activo_id
 where d.fecha_vela = (select max(fecha_vela) from public.agente_decisiones_diarias x
                        where x.agente_id = d.agente_id)

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

union all
-- 0046: las hipótesis de la semana y su veredicto. Ojo a la concordancia:
-- con menos de 20 entradas reales el veredicto es orientativo.
select '7_hipotesis', ag.nombre, h.semana || ' #' || h.id,
       jsonb_build_object('enunciado', left(h.enunciado, 140), 'estado', h.estado,
                          'cambio', h.experimento -> 'cambio',
                          'mejora_r', h.resultado -> 'mejora_r', 'percentil_azar', h.resultado -> 'percentil_azar',
                          'motivos', h.resultado -> 'motivos',
                          'concordancia', h.resultado #>> '{concordancia,texto}',
                          'informe', h.informe_url)::text
  from public.agente_hipotesis h
  join ag on ag.id = h.agente_id
 where h.creado_en >= (select desde from p) or h.actualizado_en >= (select desde from p)

union all
-- El backlog: lo abierto, y lo que pidieron (aunque esté cerrado) esta semana.
select '8_backlog', coalesce((select string_agg(x.nombre, ', ') from public.agentes x
                               where x.id = any(b.agentes_solicitantes)), '—'),
       b.estado || ' · ' || b.titulo,
       jsonb_build_object('id', b.id, 'ocurrencias', b.ocurrencias,
                          'descripcion', b.descripcion, 'resolucion', left(b.resolucion, 160),
                          'actualizado_en', b.actualizado_en)::text
  from public.agente_backlog b
 where b.estado in ('nuevo', 'en_revision') or b.actualizado_en >= (select desde from p)

union all
-- 0047: por qué no entraron. Los motivos que dominan son los candidatos a
-- la fuente H3 (y a «El filtro X me deja sin operar»).
select '9_descartes', ag.nombre, d.motivo,
       -- Una fila de `agente_descartes` es un activo y un día, no un ciclo.
       jsonb_build_object('activo_dias', count(*), 'activos', count(distinct d.activo_id),
                          'dias', count(distinct d.fecha))::text
  from public.agente_descartes d
  join ag on ag.id = d.agente_id
 where d.fecha >= (select desde from p)
 group by ag.nombre, d.motivo

order by 1, 2, 3;
