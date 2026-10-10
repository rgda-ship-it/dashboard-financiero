-- ─────────────────────────────────────────────────────────────────────
-- Diagnóstico de los agentes (solo lectura, 2026-10-10).
--
-- Responde a tres preguntas con datos de producción:
--   1. ¿Por qué no operan cripto, sobre todo el fin de semana?
--   2. ¿Por qué tantos cierres en stop y ninguno en objetivo?
--   3. ¿Por qué se cierran tantas posiciones por deterioro?
--
-- CÓMO USARLO: pegar entero en el SQL Editor de Supabase, ejecutar y
-- pulsar «Download CSV» (o «Export → CSV»). Es UNA sola consulta: devuelve
-- una fila por sección, con el detalle en la columna `datos` (jsonb).
--
-- No escribe nada: solo SELECT. Cada sección va en su propio CTE para que
-- se pueda ejecutar suelta si alguna falla.
-- ─────────────────────────────────────────────────────────────────────

with
ag as (
    select a.id as agente_id, a.nombre as agente, c.id as cuenta_id
      from public.agentes a
      join public.cuentas_simulacion c on c.agente_id = a.id
),
inicio as (
    select coalesce(min(fecha), current_date - 14) as desde from public.agente_dias
),
ord as (
    select o.id, ag.agente, a.simbolo, a.clase, o.estado, o.motivo_cierre,
           o.fecha_entrada, o.fecha_salida, o.precio_entrada, o.precio_salida,
           o.tp, o.sl, coalesce(o.sl_original, o.sl) as sl0, o.precio_max_visto,
           o.precio_max_post_cierre, o.apalancamiento, o.margen_comprometido,
           o.pnl_bruto, o.pnl_parciales, o.parcial_hecho,
           s.atr_pct as atr_entrada, s.fuerza as fuerza_entrada, s.niveles_origen,
           s.indicadores_alcistas as alc, s.indicadores_bajistas as baj,
           s.ratio_rr as rr_senal, s.calculado_en as senal_calculada_en,
           (select jsonb_agg((d ->> 'nombre') || ':' || (d ->> 'direccion'))
              from jsonb_array_elements(coalesce(s.senales_detalle, '[]'::jsonb)) d) as votos,
           (o.precio_entrada - coalesce(o.sl_original, o.sl)) / o.precio_entrada * 100 as dist_sl_pct,
           (o.tp - o.precio_entrada) / o.precio_entrada * 100 as dist_tp_pct,
           extract(epoch from coalesce(o.fecha_salida, now()) - o.fecha_entrada) / 3600 as horas,
           case when o.precio_max_visto is not null
                then (o.precio_max_visto - o.precio_entrada) / (o.tp - o.precio_entrada) end as avance_max_tp,
           o.racional
      from public.ordenes o
      join ag on ag.cuenta_id = o.cuenta_id
      join public.activos a on a.id = o.activo_id
      left join public.senales s on s.id = o.senal_id
     where o.estado in ('abierta', 'cerrada')
),

-- 1 · Estado y parámetros efectivos de cada agente ────────────────────
s_agentes as (
    select 'agentes'::text as seccion, count(*)::int as n,
           jsonb_agg(jsonb_build_object(
               'agente', a.nombre, 'estado', a.estado, 'version', a.version_estrategia,
               'objetivo_diario_pct', a.objetivo_diario_pct,
               'riesgo_reducido', a.riesgo_reducido,
               'equity', round(public.fn_equity(c.id), 2),
               'saldo_disponible', c.saldo_disponible, 'saldo_bloqueado', c.saldo_bloqueado,
               'fase', c.fase,
               'parametros', public.fn_parametros_agente(a)) order by a.id) as datos
      from public.agentes a
      join public.cuentas_simulacion c on c.agente_id = a.id and c.estado <> 'game_over'
),

-- 2 · Cierres por motivo: geometría de la entrada y recorrido ─────────
s_cierres as (
    select 'cierres_por_motivo'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.agente, t.clase, t.motivo)
      from (select agente, clase, coalesce(motivo_cierre, 'ABIERTA') as motivo,
                   count(*) as n,
                   round(sum(pnl_bruto + pnl_parciales), 2) as pnl_total,
                   round(avg(pnl_bruto + pnl_parciales), 2) as pnl_medio,
                   round(percentile_cont(0.5) within group (order by horas)::numeric, 1) as horas_mediana,
                   round(avg(dist_sl_pct), 3) as dist_sl_pct_media,
                   round(avg(dist_tp_pct), 3) as dist_tp_pct_media,
                   round(avg(dist_sl_pct / nullif(atr_entrada, 0)), 3) as dist_sl_en_atr,
                   round(avg(dist_tp_pct / nullif(atr_entrada, 0)), 3) as dist_tp_en_atr,
                   round(avg(rr_senal), 2) as rr_medio,
                   round(avg(avance_max_tp), 3) as avance_max_tp_medio,
                   count(*) filter (where avance_max_tp >= 0.8) as llegaron_80pct_tp,
                   count(*) filter (where dist_sl_pct / nullif(atr_entrada, 0) < 0.25) as stop_menor_025_atr
              from ord group by 1, 2, 3) t
),

-- 3 · Todas las operaciones de los agentes, una por una ───────────────
s_operaciones as (
    select 'operaciones'::text, count(*)::int,
           jsonb_agg(jsonb_build_object(
               'id', id, 'agente', agente, 'simbolo', simbolo, 'clase', clase,
               'entrada', fecha_entrada, 'salida', fecha_salida, 'motivo', motivo_cierre,
               'dow_entrada', extract(isodow from fecha_entrada at time zone 'America/New_York'),
               'hora_ny_entrada', to_char(fecha_entrada at time zone 'America/New_York', 'HH24:MI'),
               'p_entrada', precio_entrada, 'sl0', sl0, 'sl', sl, 'tp', tp,
               'p_salida', precio_salida, 'p_max', precio_max_visto, 'p_max_post', precio_max_post_cierre,
               'lev', apalancamiento, 'margen', margen_comprometido,
               'pnl', pnl_bruto, 'pnl_parc', pnl_parciales,
               'atr', atr_entrada, 'fuerza', fuerza_entrada, 'origen', niveles_origen,
               'alc', alc, 'baj', baj, 'rr', rr_senal, 'votos', votos,
               'senal_edad_min', round(extract(epoch from fecha_entrada - senal_calculada_en) / 60),
               'modo_reparto', racional #>> '{reparto,modo}',
               'deficit', racional -> 'deficit_pendiente') order by id)
      from ord
),

-- 4 · Salidas por deterioro: qué voto se perdió y si sirvió ───────────
s_deterioro as (
    select 'deterioro'::text, count(*)::int,
           jsonb_agg(jsonb_build_object(
               'orden_id', d.orden_id, 'agente', g.nombre, 'creada', d.creado_en,
               'motivo', d.datos ->> 'motivo', 'simbolo', d.datos ->> 'simbolo',
               'fuerza_entrada', d.datos ->> 'fuerza_entrada', 'fuerza_nueva', d.datos ->> 'fuerza_nueva',
               'pnl_al_cerrar', d.datos -> 'pnl_al_cerrar', 'efecto', d.efecto,
               'resultado', d.resultado,
               'votos_entrada', (select jsonb_agg((x ->> 'nombre') || ':' || (x ->> 'direccion'))
                                   from jsonb_array_elements(coalesce(se.senales_detalle, '[]'::jsonb)) x),
               'votos_nuevos', (select jsonb_agg((x ->> 'nombre') || ':' || (x ->> 'direccion'))
                                  from jsonb_array_elements(coalesce(sn.senales_detalle, '[]'::jsonb)) x))
               order by d.id)
      from public.agente_decisiones d
      join public.agentes g on g.id = d.agente_id
      left join public.ordenes o on o.id = d.orden_id
      left join public.senales se on se.id = o.senal_id
      left join public.senales sn on sn.id = case when jsonb_typeof(d.datos -> 'senal_nueva') = 'number'
                                                  then (d.datos ->> 'senal_nueva')::bigint end
     where d.tipo = 'deterioro'
),

-- 5 · Resumen de decisiones aprendidas (rotación, parcial, reparto…) ──
s_decisiones as (
    select 'decisiones_resumen'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.agente, t.tipo)
      from (select g.nombre as agente, d.tipo, count(*) as n,
                   count(*) filter (where d.resuelta_en is not null) as resueltas,
                   round(avg(d.efecto), 4) as efecto_medio,
                   count(*) filter (where d.efecto > 0) as positivas,
                   count(*) filter (where d.efecto < 0) as negativas
              from public.agente_decisiones d join public.agentes g on g.id = d.agente_id
             group by 1, 2) t
),

-- 6 · Cada día de cada agente ─────────────────────────────────────────
s_dias as (
    select 'dias'::text, count(*)::int,
           jsonb_agg(jsonb_build_object(
               'agente', g.nombre, 'fecha', d.fecha, 'dow', extract(isodow from d.fecha),
               'operable', d.operable, 'cumplido', d.cumplido,
               'saldo_apertura', d.saldo_apertura, 'saldo_cierre', d.saldo_cierre,
               'objetivo', d.objetivo_importe, 'pnl_realizado', d.pnl_realizado,
               'ops_abiertas', d.ops_abiertas, 'ops_cerradas', d.ops_cerradas,
               'ops_tp', d.ops_tp, 'ops_sl', d.ops_sl,
               'ciclos', d.ciclos, 'ciclos_con_universo', d.ciclos_con_universo,
               'ciclos_sin_candidatos', d.ciclos_sin_candidatos,
               'descartes', d.descartes,
               'ultima_accion', d.ultima_decision ->> 'accion',
               'ultima_decision', d.ultima_decision) order by g.id, d.fecha)
      from public.agente_dias d join public.agentes g on g.id = d.agente_id
),

-- 7 · Fin de semana: saldo atrapado en acciones ───────────────────────
-- Para cada sábado y domingo, y para cada hora UTC, las posiciones abiertas
-- en ese instante por clase y el margen que bloquean.
s_finde as (
    select 'fin_de_semana_bloqueo'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.agente, t.instante)
      from (select ag.agente, h.instante,
                   to_char(h.instante, 'Dy') as dia,
                   count(o.id) filter (where a.clase = 'accion') as abiertas_accion,
                   count(o.id) filter (where a.clase = 'cripto') as abiertas_cripto,
                   round(coalesce(sum(o.margen_comprometido) filter (where a.clase = 'accion'), 0), 2) as margen_accion,
                   round(coalesce(sum(o.margen_comprometido) filter (where a.clase = 'cripto'), 0), 2) as margen_cripto
              from ag
              cross join inicio
              cross join lateral generate_series(inicio.desde::timestamptz, now(), interval '6 hours') h(instante)
              left join public.ordenes o
                     on o.cuenta_id = ag.cuenta_id
                    and o.fecha_entrada <= h.instante
                    and (o.fecha_salida is null or o.fecha_salida > h.instante)
                    and o.estado in ('abierta', 'cerrada')
              left join public.activos a on a.id = o.activo_id
             where extract(isodow from h.instante) in (6, 7)
             group by 1, 2) t
),

-- 8 · Señales cripto: el primer filtro de cada agente que las tumba ───
-- Mismo orden que fn_universo_agente (sin antigüedad, posición abierta ni
-- prácticas, que dependen del instante).
crip as (
    select s.*, a.simbolo
      from public.senales s join public.activos a on a.id = s.activo_id
     where a.clase = 'cripto'
       and s.calculado_en >= (select desde from inicio)
),
s_cripto_filtro as (
    select 'cripto_primer_filtro'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.agente, t.n desc)
      from (select g.nombre as agente, m.motivo, count(*) as n,
                   count(distinct crip.simbolo) as simbolos,
                   jsonb_agg(distinct crip.simbolo) as cuales
              from public.agentes g
              cross join lateral (select public.fn_parametros_agente(g) as p) pp
              join crip on pp.p -> 'clases_admitidas' ? 'cripto'
              cross join lateral (select case
                   when not (crip.indicadores_alcistas > crip.indicadores_bajistas) then 'direccion'
                   when not crip.operable and crip.atr_pct is null then 'sin_atr'
                   when not crip.operable then 'no_operable'
                   when not (pp.p -> 'fuerzas_admitidas' ? coalesce(crip.fuerza, '')) then 'fuerza'
                   when not (pp.p -> 'niveles_origen_admitidos' ? coalesce(crip.niveles_origen, '')) then 'niveles_origen'
                   when crip.ratio_rr is null or crip.ratio_rr < (pp.p ->> 'rr_minimo')::numeric then 'rr'
                   when pp.p ->> 'atr_pct_min' is not null
                        and (crip.atr_pct is null or crip.atr_pct < (pp.p ->> 'atr_pct_min')::numeric) then 'atr_bajo'
                   when pp.p ->> 'atr_pct_max' is not null
                        and (crip.atr_pct is null or crip.atr_pct > (pp.p ->> 'atr_pct_max')::numeric) then 'atr_alto'
                   else 'PASA' end as motivo) m
             group by 1, 2) t
),

-- 9 · Señales cripto: perfil por símbolo ──────────────────────────────
s_cripto_perfil as (
    select 'cripto_perfil'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.simbolo)
      from (select simbolo, count(*) as senales,
                   count(*) filter (where direccion = 'alcista') as alcistas,
                   count(*) filter (where direccion = 'bajista') as bajistas,
                   count(*) filter (where operable) as operables,
                   count(*) filter (where fuerza = 'alta') as f_alta,
                   count(*) filter (where fuerza = 'media') as f_media,
                   round(avg(atr_pct), 2) as atr_medio,
                   round(min(atr_pct), 2) as atr_min, round(max(atr_pct), 2) as atr_max,
                   round(avg(ratio_rr) filter (where operable), 2) as rr_medio_operables,
                   round(avg(leverage_recomendado) filter (where operable), 2) as lev_medio,
                   min(calculado_en) as primera, max(calculado_en) as ultima
              from crip group by simbolo) t
),

-- 10 · Frescura de las señales cripto (huecos del ETL) ────────────────
s_cripto_frescura as (
    select 'cripto_frescura'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.simbolo)
      from (select simbolo, count(*) as huecos,
                   round(avg(gap_min)) as hueco_medio_min,
                   round(max(gap_min)) as hueco_max_min,
                   count(*) filter (where gap_min > 90) as huecos_mayores_90min,
                   count(*) filter (where gap_min > 90 and extract(isodow from calculado_en) in (6, 7)) as huecos_90_finde
              from (select simbolo, calculado_en,
                           extract(epoch from calculado_en - lag(calculado_en)
                                   over (partition by activo_id order by calculado_en)) / 60 as gap_min
                      from crip) x
             where gap_min is not null
             group by simbolo) t
),

-- 11 · ¿Llegó alguna cripto a ser candidata en una decisión de abrir? ─
s_cripto_racional as (
    select 'cripto_en_decisiones'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.agente, t.n desc)
      from (select o.agente, coalesce(c ->> 'descarte', 'valida') as descarte,
                   count(*) as n, jsonb_agg(distinct c ->> 'simbolo') as simbolos,
                   round(avg((c ->> 'rendimiento')::numeric), 4) as rendimiento_medio,
                   round(avg((c ->> 'apalancamiento')::numeric), 2) as lev_medio
              from ord o
              cross join lateral jsonb_array_elements(coalesce(o.racional -> 'candidatos', '[]'::jsonb)) c
             where c ->> 'clase' = 'cripto'
             group by 1, 2) t
),

-- 12 · Avisos de fallo y peticiones del backlog ───────────────────────
s_eventos as (
    select 'eventos_por_tipo'::text, count(*)::int,
           jsonb_agg(to_jsonb(t) order by t.n desc)
      from (select tipo, left(mensaje, 120) as mensaje, count(*) as n,
                   min(creado_en) as primero, max(creado_en) as ultimo
              from public.eventos_sistema
             where creado_en >= (select desde from inicio)
               and tipo not in ('orden_cerrada', 'etl')
             group by 1, 2
             order by 3 desc limit 60) t
),
s_backlog as (
    select 'backlog'::text, count(*)::int,
           jsonb_agg(jsonb_build_object('titulo', titulo, 'tipo', tipo, 'estado', estado,
                                        'ocurrencias', ocurrencias, 'creado', creado_en,
                                        'resolucion', resolucion) order by ocurrencias desc)
      from public.agente_backlog
)

select * from s_agentes
union all select * from s_cierres
union all select * from s_operaciones
union all select * from s_deterioro
union all select * from s_decisiones
union all select * from s_dias
union all select * from s_finde
union all select * from s_cripto_filtro
union all select * from s_cripto_perfil
union all select * from s_cripto_frescura
union all select * from s_cripto_racional
union all select * from s_eventos
union all select * from s_backlog;
