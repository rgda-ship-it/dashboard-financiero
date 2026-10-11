-- Ensayo del agente «Tendencia cripto» (0037) sobre los datos de producción.
-- Solo lectura: calcula, para cada cripto activa, los indicadores con la
-- vela de ayer y lo que decidiría el agente. No abre ni cierra nada.
-- Pegar entero en el editor SQL de Supabase (copiar desde la URL raw).
select a.simbolo,
       (x.ind ->> 'cierre')::numeric                         as cierre,
       round((x.ind ->> 'sma')::numeric, 4)                  as media_200,
       (x.ind ->> 'max_ruptura')::numeric                    as maximo_20,
       (x.ind ->> 'min_salida')::numeric                     as minimo_10,
       round((x.ind ->> 'atr')::numeric, 4)                  as atr_14,
       (x.ind ->> 'rangos')::int                             as dias_con_rango,
       case
           when x.ind ->> 'error' is not null then 'sin vela de ayer'
           when x.ind ->> 'sma' is null then 'sin datos: faltan 200 cierres'
           when x.ind ->> 'atr' is null then 'sin datos: falta ATR (rango real)'
           when x.ind ->> 'max_ruptura' is null then 'sin datos: faltan 20 días con rango real'
           when (x.ind ->> 'cierre')::numeric > (x.ind ->> 'sma')::numeric
            and (x.ind ->> 'cierre')::numeric > (x.ind ->> 'max_ruptura')::numeric then 'ENTRARÍA'
           when (x.ind ->> 'cierre')::numeric <= (x.ind ->> 'sma')::numeric then 'sin señal: bajo la media de 200'
           else 'sin señal: no rompe el máximo de 20'
       end                                                   as decision,
       round((x.ind ->> 'cierre')::numeric - 2 * (x.ind ->> 'atr')::numeric, 8) as stop_inicial,
       a.ultimo_etl_en >= ((now() at time zone 'UTC')::date::timestamp at time zone 'UTC') + interval '60 minutes'
                                                             as vela_lista,
       a.ultimo_precio_en > now() - interval '15 minutes'    as precio_fresco
  from public.activos a
  join public.agentes g on g.nombre = 'Tendencia cripto'
  cross join lateral (select public.fn_indicadores_tendencia(
                                 a.id, (now() at time zone 'UTC')::date - 1, g.estrategia) as ind) x
 where a.clase = 'cripto' and a.estado = 'activo'
 order by decision, a.simbolo;
