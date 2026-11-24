-- Auditoría integral del 2026-11-21 (docs/fase-4/01-auditoria-integral.md).
-- SOLO LECTURA:  python scripts/consultar.py -f scripts/auditoria_2026-11-21.sql
-- Datos desde el 2026-10-17 (0043), la regla práctica de CRONOLOGIA.md §1.

-- A1 · ¿Cuánto regala el monitor al cerrar un stop al nivel exacto?
-- Stops en sesión (sin hueco): diferencia entre el stop y el precio que el
-- monitor vio al cerrar, en R. Positivo = el simulador cobró más de lo que
-- había en el mercado.
select a.nombre as agente, act.clase,
       count(*) as stops,
       round(avg((o.precio_salida - o.precio_observado_cierre)
                 / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0)), 3) as regalo_medio_r,
       round(max((o.precio_salida - o.precio_observado_cierre)
                 / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0)), 3) as regalo_max_r
  from ordenes o
  join cuentas_simulacion c on c.id = o.cuenta_id
  join agentes a on a.id = c.agente_id
  join activos act on act.id = o.activo_id
 where o.motivo_cierre = 'sl'
   and not coalesce(o.cierre_por_hueco, false)
   and o.fecha_salida >= '2026-10-17'
   and o.precio_observado_cierre is not null
 group by 1, 2
 order by 1, 2;

-- A2 · Resultado por motivo de cierre y agente (R sobre el stop inicial).
select a.nombre as agente, o.motivo_cierre,
       count(*) as cierres,
       round(avg((o.precio_salida - o.precio_entrada)
                 / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0)), 3) as r_medio
  from ordenes o
  join cuentas_simulacion c on c.id = o.cuenta_id
  join agentes a on a.id = c.agente_id
 where o.estado = 'cerrada' and o.fecha_entrada >= '2026-10-17'
 group by 1, 2
 order by 1, 2;

-- A3 · Rotaciones: ¿se cerraban posiciones que luego llegaban al objetivo?
-- `precio_max_post_cierre` no se rellena en las rotadas (comprobado el
-- 24-11): se miran las velas diarias posteriores y qué tocan antes, el
-- objetivo o el stop inicial.
select a.nombre as agente, o.id, act.simbolo, o.fecha_salida::date as salida,
       round((o.precio_salida - o.precio_entrada)
             / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0), 2) as r_al_rotar,
       round((o.tp - o.precio_entrada)
             / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0), 2) as r_del_objetivo,
       min(p.fecha) filter (where p.maximo >= o.tp) as llega_al_objetivo,
       min(p.fecha) filter (where p.minimo <= coalesce(o.sl_original, o.sl)) as llega_al_stop
  from ordenes o
  join cuentas_simulacion c on c.id = o.cuenta_id
  join agentes a on a.id = c.agente_id
  join activos act on act.id = o.activo_id
  left join precios_diarios p on p.activo_id = o.activo_id and p.fecha > o.fecha_salida::date
 where o.motivo_cierre = 'rotacion' and o.fecha_entrada >= '2026-10-17'
 group by 1, 2, 3, 4, 5, 6
 order by 1, 4;

-- A4 · Apalancamiento real de cada orden frente al tope de 5× (0055).
select a.nombre as agente,
       count(*) as ordenes,
       max(o.apalancamiento) as apalancamiento_max,
       count(*) filter (where o.apalancamiento > 5) as por_encima_de_5x
  from ordenes o
  join cuentas_simulacion c on c.id = o.cuenta_id
  join agentes a on a.id = c.agente_id
 where o.fecha_entrada >= '2026-11-02 21:48'
 group by 1
 order by 1;
