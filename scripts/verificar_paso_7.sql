-- ─────────────────────────────────────────────────────────────────────
-- Verificación del paso 7 del runbook: ¿el ETL escribió de verdad?
--
-- Pégalo ENTERO en el SQL Editor del panel de Supabase y ejecútalo.
-- Devuelve una tabla con una fila por comprobación y su veredicto. No
-- modifica nada: son solo lecturas.
--
-- Está pensado para distinguir tres situaciones que desde fuera parecen
-- iguales ("no veo datos"):
--   · el ETL nunca corrió         -> los 24 activos siguen 'pendiente_backfill'
--   · corrió pero falló           -> activos 'suspendido' con ultimo_error
--   · corrió bien                 -> 24 'activo', señales, velas, indicadores
-- ─────────────────────────────────────────────────────────────────────

with
a as (select * from public.activos),
cripto_rango as (
    select a.simbolo,
           count(*) filter (where p.rango_real)     as con_rango,
           count(*) filter (where not p.rango_real) as reconstruidas
      from public.precios_diarios p
      join public.activos a on a.id = p.activo_id
     where a.clase = 'cripto'
     group by a.simbolo
)
select * from (

    select 1 as n, 'Activos en el catálogo' as comprobacion,
           '24' as esperado,
           (select count(*) from a)::text as obtenido,
           case when (select count(*) from a) = 24 then 'OK' else 'FALLO' end as veredicto

    union all
    select 2, 'Activos procesados por el ETL (estado activo)',
           '24',
           (select count(*) from a where estado = 'activo')::text,
           case when (select count(*) from a where estado = 'activo') = 24 then 'OK'
                when (select count(*) from a where estado = 'activo') = 0  then 'FALLO: el ETL no ha corrido nunca'
                else 'PARCIAL' end

    union all
    select 3, 'Activos aún pendientes de backfill',
           '0',
           (select count(*) from a where estado = 'pendiente_backfill')::text,
           case when (select count(*) from a where estado = 'pendiente_backfill') = 0 then 'OK'
                else 'FALLO: ' || (select string_agg(simbolo, ', ' order by simbolo)
                                     from a where estado = 'pendiente_backfill') end

    union all
    select 4, 'Activos suspendidos o inválidos',
           '0',
           (select count(*) from a where estado in ('suspendido','invalido'))::text,
           case when (select count(*) from a where estado in ('suspendido','invalido')) = 0 then 'OK'
                else 'REVISAR: ' || (select string_agg(simbolo || ' [' || coalesce(left(ultimo_error, 60),'') || ']', ' | ')
                                       from a where estado in ('suspendido','invalido')) end

    union all
    select 5, 'Señales escritas',
           '>= 24',
           (select count(*) from public.senales)::text,
           case when (select count(*) from public.senales) >= 24 then 'OK'
                when (select count(*) from public.senales) = 0 then 'FALLO: no hay ninguna señal'
                else 'PARCIAL' end

    union all
    select 6, 'Activos con al menos una señal',
           '24',
           (select count(distinct activo_id) from public.senales)::text,
           case when (select count(distinct activo_id) from public.senales) = 24 then 'OK' else 'PARCIAL' end

    union all
    select 7, 'Señales operables (con SL/TP/apalancamiento)',
           'informativo',
           (select count(*) from public.senales_vigentes where operable)::text
             || ' de ' || (select count(*) from public.senales_vigentes)::text,
           'INFO: depende del mercado de hoy'

    union all
    select 8, 'Velas diarias de acciones (~500 por acción)',
           '~10.500',
           (select count(*) from public.precios_diarios p join a on a.id = p.activo_id
             where a.clase = 'accion')::text,
           case when (select count(*) from public.precios_diarios p join a on a.id = p.activo_id
                       where a.clase = 'accion') > 9000 then 'OK' else 'REVISAR' end

    union all
    select 9, 'Acciones: todas sus velas con rango real',
           'todas',
           (select count(*) filter (where not p.rango_real) from public.precios_diarios p
              join a on a.id = p.activo_id where a.clase = 'accion')::text || ' sin rango',
           case when (select count(*) filter (where not p.rango_real) from public.precios_diarios p
                        join a on a.id = p.activo_id where a.clase = 'accion') = 0
                then 'OK' else 'FALLO: yfinance siempre trae máximo y mínimo' end

    union all
    -- LA COMPROBACIÓN QUE MÁS IMPORTA. Si una cripto sale con todas sus
    -- velas con rango real, el ATR se está calculando sobre velas sin
    -- recorrido intradía: es el bug que infló el ATR de BTC un 16 %.
    select 10, 'Cripto: ~30 velas con rango real y el resto reconstruidas',
           '~30 / cientos',
           coalesce((select string_agg(simbolo || ' ' || con_rango || '/' || reconstruidas, '  ' order by simbolo)
                       from cripto_rango), 'sin velas de cripto'),
           case when not exists (select 1 from cripto_rango) then 'FALLO: no hay velas de cripto'
                when exists (select 1 from cripto_rango where reconstruidas = 0) then 'FALLO: rango_real mal propagado'
                when exists (select 1 from cripto_rango where con_rango not between 20 and 40) then 'REVISAR'
                else 'OK' end

    union all
    select 11, 'Indicadores diarios en caché',
           '24',
           (select count(distinct activo_id) from public.indicadores_diarios)::text,
           case when (select count(distinct activo_id) from public.indicadores_diarios) = 24 then 'OK' else 'PARCIAL' end

    union all
    select 12, 'Acciones con SMA 200 calculada (necesita 2 años de velas)',
           '21',
           (select count(*) from public.indicadores_diarios i join a on a.id = i.activo_id
             where a.clase = 'accion' and i.sma_200 is not null)::text,
           case when (select count(*) from public.indicadores_diarios i join a on a.id = i.activo_id
                       where a.clase = 'accion' and i.sma_200 is not null) = 21 then 'OK' else 'REVISAR' end

    union all
    select 13, 'Última pasada del ETL',
           'reciente',
           coalesce(to_char((select max(ultimo_etl_en) from a) at time zone 'Europe/Paris',
                            'YYYY-MM-DD HH24:MI') || ' (hora de París)', 'nunca'),
           case when (select max(ultimo_etl_en) from a) is null then 'FALLO: el ETL no ha corrido nunca'
                else 'INFO' end

    union all
    select 14, 'Errores de proveedor registrados',
           '0',
           (select count(*) from public.eventos_sistema where tipo = 'proveedor')::text,
           case when (select count(*) from public.eventos_sistema where tipo = 'proveedor') = 0 then 'OK'
                else 'REVISAR: ' || (select string_agg(left(mensaje, 70), ' | ')
                                       from (select mensaje from public.eventos_sistema
                                              where tipo = 'proveedor'
                                              order by creado_en desc limit 3) m) end

    union all
    select 15, 'Versión del motor que escribió las señales',
           'un hash de commit',
           coalesce((select string_agg(distinct left(version_motor, 12), ', ') from public.senales), '—'),
           case when exists (select 1 from public.senales where version_motor in ('desconocida','local'))
                then 'AVISO: señales escritas desde local, no desde Actions'
                else 'INFO' end

) r
order by n;
