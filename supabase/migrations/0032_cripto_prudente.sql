-- ─────────────────────────────────────────────────────────────────────
-- 0032 — Cripto prudente: prudencia como tamaño, perfiles por mercado y
-- universo cripto real (doc 05 §6, entrega D, 2026-10-10).
--
-- En 11 días ninguna cripto real pasó los filtros de los agentes: Prudencia
-- no admitía cripto, el tope de ATR de Cadencia (2,3 %) dejaba fuera
-- incluso a BTC, y de los 20 huecos de cripto solo 8 eran criptos
-- líquidas. El dueño: «la opción de ser prudente no puede ser no operar».
--
--   1. PERFILES POR MERCADO. `estrategia.por_clase.<clase>` puede
--      sobrescribir, para un mercado, el rango de ATR y dos parámetros
--      nuevos (`fn_param_clase`):
--        · riesgo_atr_ref       el riesgo por operación se escala por
--                               min(1, ref / ATR del activo): una cripto
--                               el doble de volátil que la referencia del
--                               perfil se toma con la mitad de riesgo;
--        · riesgo_abierto_mult  lo que arriesgan a la vez sus posiciones de
--                               ese mercado no pasa de este múltiplo de su
--                               riesgo por operación (las criptos caen
--                               juntas con BTC).
--   2. LOS TRES OPERAN CRIPTO, cada uno a su manera:
--        Prudencia  admite cripto. ATR ≤ 12 %, riesgo × min(1, 3 / ATR)
--                   (su propio techo de ATR en acciones), y en cripto como
--                   mucho 1 × su riesgo a la vez. BTC con el riesgo
--                   completo, ADA con la mitad, ZEC no llega al margen
--                   mínimo.
--        Cadencia   cripto tranquila: ATR ≤ 4 %, riesgo × min(1, 2,3 / ATR),
--                   cripto como mucho 2 × su riesgo a la vez.
--        Audacia    cripto con recorrido: ATR ≥ 4 %, sin escalar (busca
--                   volatilidad; el motor ya le baja el apalancamiento), y
--                   cripto como mucho 2 × su riesgo a la vez.
--      El corte de 4 % separa Cadencia y Audacia en cripto como el de
--      2,3 % las separa en acciones (D19).
--   3. SI NO BASTA, LO PIDEN. Una candidata que queda fuera solo por estos
--      límites deja el descarte `riesgo_escalado` o `riesgo_clase_lleno`, y
--      el autodiagnóstico semanal abre una petición («Ampliar mi riesgo…»)
--      cuando se repite. Nada se amplía solo.
--   4. UNIVERSO CRIPTO REAL. Entran seis criptos líquidas (LTC, LINK, AVAX,
--      DOT, TRX, BCH) como pendientes de backfill: el ETL de cripto las
--      procesa en su próxima pasada. Sale el token que replica la acción de
--      MaxLinear, como los de la 0029, si nadie lo sigue ni tiene posición.
--      Quedan 14 criptos, dentro del tope de 20 de CoinGecko.
--
-- Lo que NO cambia: solo largos y dominancia estricta (reglas protegidas),
-- G1–G6, y el filtro de dirección. Casi el 80 % de las señales cripto de
-- estos días no eran alcistas: esta entrega no inventa candidatas, deja de
-- descartar por perfil las que sí lo son.
-- ─────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════
-- Parámetros por mercado
-- ═════════════════════════════════════════════════════════════════════
-- El valor de `p_clave` para un mercado: el de `por_clase.<clase>` si lo
-- define (también un null explícito, que quita el límite), si no el
-- general.
create function public.fn_param_clase(p_params jsonb, p_clase text, p_clave text)
returns jsonb
language sql immutable
as $$
    select case when coalesce(p_params -> 'por_clase' -> p_clase, '{}'::jsonb) ? p_clave
                then p_params -> 'por_clase' -> p_clase -> p_clave
                else p_params -> p_clave end
$$;

-- Factor por el que se multiplica el riesgo de una candidata: min(1,
-- referencia / ATR). Sin referencia, o sin ATR, 1.
create function public.fn_factor_riesgo(p_params jsonb, p_clase text, p_atr_pct numeric)
returns numeric
language sql immutable
as $$
    select case when (public.fn_param_clase(p_params, p_clase, 'riesgo_atr_ref') #>> '{}') is null
                     or p_atr_pct is null or p_atr_pct <= 0 then 1
                else round(least(1, (public.fn_param_clase(p_params, p_clase, 'riesgo_atr_ref') #>> '{}')::numeric
                                    / p_atr_pct), 4) end
$$;

-- Lo que arriesgan ahora las posiciones abiertas de una cuenta en una clase.
create function public.fn_riesgo_abierto_clase(p_cuenta_id bigint, p_clase text)
returns numeric
language sql stable
as $$
    select coalesce(sum(greatest(o.cantidad * (o.precio_entrada - o.sl), 0)), 0)
      from public.ordenes o join public.activos a on a.id = o.activo_id
     where o.cuenta_id = p_cuenta_id and o.estado = 'abierta' and a.clase = p_clase
$$;

revoke execute on function public.fn_param_clase(jsonb, text, text)          from public, anon, authenticated;
revoke execute on function public.fn_factor_riesgo(jsonb, text, numeric)     from public, anon, authenticated;
revoke execute on function public.fn_riesgo_abierto_clase(bigint, text)      from public, anon, authenticated;


-- ═════════════════════════════════════════════════════════════════════
-- Perfiles: los tres operan cripto
-- ═════════════════════════════════════════════════════════════════════
-- El trigger de versiones sube la versión de cada estrategia.
update public.agentes
   set estrategia = estrategia
       || '{"clases_admitidas": ["accion", "cripto"]}'::jsonb
       || '{"por_clase": {"cripto": {"atr_pct_max": 12, "riesgo_atr_ref": 3, "riesgo_abierto_mult": 1}}}'::jsonb
 where nombre = 'Prudencia';

update public.agentes
   set estrategia = estrategia
       || '{"por_clase": {"cripto": {"atr_pct_max": 4, "riesgo_atr_ref": 2.3, "riesgo_abierto_mult": 2}}}'::jsonb
 where nombre = 'Cadencia';

update public.agentes
   set estrategia = estrategia
       || '{"por_clase": {"cripto": {"atr_pct_min": 4, "riesgo_abierto_mult": 2}}}'::jsonb
 where nombre = 'Audacia';


-- ═════════════════════════════════════════════════════════════════════
-- Universo cripto real
-- ═════════════════════════════════════════════════════════════════════
do $universo$
declare
    v_altas       jsonb;
    v_suspendidos jsonb;
begin
    with altas as (
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, nombre)
        values ('litecoin',     'cripto', 'coingecko', 'litecoin',     'Litecoin'),
               ('chainlink',    'cripto', 'coingecko', 'chainlink',    'Chainlink'),
               ('avalanche-2',  'cripto', 'coingecko', 'avalanche-2',  'Avalanche'),
               ('polkadot',     'cripto', 'coingecko', 'polkadot',     'Polkadot'),
               ('tron',         'cripto', 'coingecko', 'tron',         'TRON'),
               ('bitcoin-cash', 'cripto', 'coingecko', 'bitcoin-cash', 'Bitcoin Cash')
        on conflict (simbolo) do nothing
        returning simbolo)
    select jsonb_agg(simbolo order by simbolo) into v_altas from altas;

    with s as (
        update public.activos a set estado = 'suspendido'
         where a.clase = 'cripto'
           and a.simbolo = 'maxlinear-robinhood-tokenized-stock'
           and a.estado <> 'suspendido'
           and a.seguidores = 0
           and not exists (select 1 from public.ordenes o
                            where o.activo_id = a.id and o.estado = 'abierta')
        returning a.simbolo)
    select jsonb_agg(simbolo order by simbolo) into v_suspendidos from s;

    insert into public.eventos_sistema (tipo, mensaje, datos)
    values ('sys', 'Cripto prudente: los tres agentes operan cripto y el universo suma criptos líquidas',
            jsonb_build_object('migracion', '0032', 'altas', v_altas, 'suspendidos', v_suspendidos));
end
$universo$;


-- ═════════════════════════════════════════════════════════════════════
-- El universo, la decisión y el autodiagnóstico, con los parámetros por
-- mercado (las de la 0029, 0030 y 0031 con los cambios marcados «0032»)
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_umbrales_autodiagnostico()
returns jsonb
language sql immutable
as $$
    select jsonb_build_object(
        'ventana_ordenes_dias', 14, 'ventana_dias', 7,
        'objetivos_min_cierres', 15,
        'stop_min_ordenes', 10, 'stop_mediana_atr', 0.5,
        'votos_min_ordenes', 10, 'votos_pct_contradictorias', 50,
        'filtro_min_descartes', 200, 'filtro_pct', 80,
        'saldo_atrapado_ciclos', 36,
        'metas_min_dias', 3,
        'practica_min_ops', 5,
        -- 0032: candidata × ciclo; 120 son unas 10 horas de una candidata
        -- fuera solo por el límite prudente.
        'riesgo_prudente_descartes', 120)
$$;

create or replace function public.fn_universo_agente(p_params jsonb, p_cuenta_id bigint, p_practicas jsonb)
returns table (
    senal_id bigint, activo_id bigint, simbolo text, clase text, fuerza text,
    niveles_origen text, ratio_rr numeric, atr_pct numeric, precio_actual numeric,
    sl numeric, tp numeric, leverage_recomendado numeric,
    alcistas int, bajistas int, antiguedad_min int, motivo text)
language sql stable
as $$
    select s.id, s.activo_id, s.simbolo, s.clase, s.fuerza, s.niveles_origen,
           s.ratio_rr, s.atr_pct, s.precio_actual, s.sl, s.tp, s.leverage_recomendado,
           s.indicadores_alcistas, s.indicadores_bajistas, x.antiguedad_min,
           case
               when x.antiguedad_min > (p_params ->> 'antiguedad_senal_max_min')::int
                    then case when s.clase = 'accion' and public.fn_esperando_apertura(now())
                                   then 'fuera_de_sesion'   -- 0029: aún sin la primera lectura de la sesión
                              when s.clase = 'cripto' or public.fn_mercado_abierto(now())
                                   then 'antiguedad' else 'fuera_de_sesion' end
               when not (s.indicadores_alcistas > s.indicadores_bajistas) then 'direccion'
               when not s.operable and s.atr_pct is null then 'sin_atr'
               when not s.operable then 'no_operable'
               when not (p_params -> 'fuerzas_admitidas' ? coalesce(s.fuerza, '')) then 'fuerza'
               when not (p_params -> 'niveles_origen_admitidos' ? coalesce(s.niveles_origen, '')) then 'niveles_origen'
               when s.ratio_rr is null or s.ratio_rr < (p_params ->> 'rr_minimo')::numeric then 'rr'
               -- 0032: el rango de ATR puede ser distinto por mercado.
               when public.fn_param_clase(p_params, s.clase, 'atr_pct_min') #>> '{}' is not null
                    and (s.atr_pct is null
                         or s.atr_pct < (public.fn_param_clase(p_params, s.clase, 'atr_pct_min') #>> '{}')::numeric) then 'atr_bajo'
               when public.fn_param_clase(p_params, s.clase, 'atr_pct_max') #>> '{}' is not null
                    and (s.atr_pct is null
                         or s.atr_pct > (public.fn_param_clase(p_params, s.clase, 'atr_pct_max') #>> '{}')::numeric) then 'atr_alto'
               when exists (select 1 from public.ordenes o
                             where o.cuenta_id = p_cuenta_id and o.activo_id = s.activo_id
                               and o.estado = 'abierta') then 'posicion_abierta'
               when exists (select 1 from jsonb_array_elements(coalesce(p_practicas, '[]'::jsonb)) e
                             where case when coalesce(e ->> 's', 'exigir') = 'evitar'
                                        then public.fn_cumple_condiciones(
                                                 e -> 'c', s.clase, s.fuerza, s.niveles_origen, s.atr_pct, s.ratio_rr)
                                        else not public.fn_cumple_condiciones(
                                                 coalesce(e -> 'c', e), s.clase, s.fuerza, s.niveles_origen,
                                                 s.atr_pct, s.ratio_rr) end)
                    then 'practica'
           end
      from public.senales_vigentes s
      cross join lateral (
           select round(extract(epoch from now() - s.calculado_en) / 60)::int as antiguedad_min) x
     where s.estado_activo = 'activo'
       and p_params -> 'clases_admitidas' ? s.clase
$$;

create or replace function public.fn_decidir_agente(p_agente_id bigint)
returns jsonb
language plpgsql stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag         public.agentes;
    v_p          jsonb;
    v_cuenta     public.cuentas_simulacion;
    v_hoy        date := (now() at time zone 'UTC')::date;
    v_equity     numeric;
    v_objetivo   numeric;
    v_logrado    numeric;
    v_deficit    numeric;
    v_abiertas   int;
    v_margen_pct numeric;
    v_tope       numeric;
    v_propio     numeric;
    v_riesgo     numeric;
    v_libre      numeric;
    v_libre_pct  numeric;
    v_cuarentena boolean;
    v_validas    int;
    v_k          int;
    v_set        jsonb;
    v_gan        numeric;
    v_ok         boolean;
    v_cubre_k    int;
    v_mejor_k    int;
    v_mejor_g    numeric;
    v_evals      jsonb := '[]'::jsonb;
    v_marcadas   jsonb;
    v_practicas  jsonb;
    v_ids_pract  jsonb;
    v_base       jsonb;
    v_universo   int;
    v_frescas    int;
    v_sin_alc    boolean;
    v_antes      int;
    v_cands      jsonb;
    v_descartes  jsonb;
    v_top3       jsonb;
    v_sin_hueco  text;
    v_mejor      jsonb;
    v_debil      record;
    v_abierto    numeric;
    v_heat_max   numeric;
    v_heat_libre_pct numeric;
    v_heat_clase jsonb := '{}'::jsonb;
    v_clase      text;
    v_mult       numeric;
    v_extra      jsonb;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    select * into v_cuenta from public.cuentas_simulacion where id = public.fn_cuenta_agente(p_agente_id);
    v_p := public.fn_parametros_agente(v_ag);

    v_equity := public.fn_equity(v_cuenta.id);
    select objetivo_importe into v_objetivo from public.agente_dias
     where agente_id = p_agente_id and fecha = v_hoy;
    v_objetivo := coalesce(v_objetivo, round(v_equity * v_ag.objetivo_diario_pct / 100, 2));
    v_logrado  := public.fn_pnl_realizado_dia(v_cuenta.id, v_hoy);
    v_deficit  := v_objetivo - v_logrado;

    v_base := jsonb_build_object(
        'agente', v_ag.nombre, 'cuenta_id', v_cuenta.id,
        'version_estrategia', v_ag.version_estrategia,
        'equity', round(v_equity, 2), 'objetivo_importe', v_objetivo,
        'logrado', v_logrado, 'deficit_pendiente', round(v_deficit, 2));

    -- N9: meta cumplida ⇒ modo conservación. Tampoco se rota: rotar es
    -- abrir algo nuevo.
    if v_deficit <= 0 then
        return v_base || jsonb_build_object('accion', 'meta_cumplida');
    end if;

    select count(*) into v_abiertas
      from public.ordenes where cuenta_id = v_cuenta.id and estado = 'abierta';
    -- 0023: sin G4. Lo libre es el margen que deja G3 (el 100 % del
    -- equity) y, como mucho, el disponible. Con menos de 10 $ de margen
    -- libre no cabe ninguna posición: el saldo para operar está lleno.
    -- La cuarentena sigue siendo «una posición a la vez».
    v_cuarentena := v_ag.estado = 'cuarentena';
    v_libre := greatest(least(v_equity * (v_p ->> 'margen_comprometido_max_pct')::numeric / 100
                              - v_cuenta.saldo_bloqueado,
                              v_cuenta.saldo_disponible), 0);
    v_libre_pct := case when v_equity > 0 then v_libre * 100 / v_equity else 0 end;
    -- 0030 · Riesgo abierto total: lo que arriesgan a la vez sus
    -- posiciones abiertas no pasa de 4 × su riesgo por operación. Con
    -- menos de un cuarto de riesgo libre no cabe ninguna posición útil.
    v_abierto  := public.fn_riesgo_abierto(v_cuenta.id);
    v_heat_max := v_equity * (v_p ->> 'riesgo_pct_operacion')::numeric
                  * public.fn_multiplo_riesgo_abierto() / 100;
    v_heat_libre_pct := case when v_equity > 0
                             then greatest(v_heat_max - v_abierto, 0) * 100 / v_equity else 0 end;
    if v_cuarentena and v_abiertas >= 1 then
        v_sin_hueco := 'sin_hueco';
    elsif v_libre < 10 then
        v_sin_hueco := 'saldo_lleno';
    elsif v_heat_libre_pct < (v_p ->> 'riesgo_pct_operacion')::numeric * 0.25 then
        v_sin_hueco := 'riesgo_lleno';
    end if;

    -- 0032 · Riesgo abierto por mercado: lo que arriesgan a la vez sus
    -- posiciones de una clase (p. ej. cripto, que se mueve en bloque con
    -- BTC) no pasa de `riesgo_abierto_mult` × su riesgo por operación.
    for v_clase in select jsonb_array_elements_text(v_p -> 'clases_admitidas') loop
        v_mult := (public.fn_param_clase(v_p, v_clase, 'riesgo_abierto_mult') #>> '{}')::numeric;
        if v_mult is not null and v_equity > 0 then
            v_heat_clase := v_heat_clase || jsonb_build_object(v_clase,
                greatest(v_equity * (v_p ->> 'riesgo_pct_operacion')::numeric * v_mult / 100
                         - public.fn_riesgo_abierto_clase(v_cuenta.id, v_clase), 0) * 100 / v_equity);
        end if;
    end loop;

    select coalesce(jsonb_agg(jsonb_build_object('c', p.condiciones, 's', p.sentido) order by p.id), '[]'::jsonb),
           coalesce(jsonb_agg(p.id order by p.id), '[]'::jsonb)
      into v_practicas, v_ids_pract
      from public.mp_adopciones ad
      join public.mejores_practicas p on p.id = ad.practica_id
     where ad.agente_id = p_agente_id and ad.abandonada_en is null
       and p.estado in ('propuesta', 'validada');

    v_tope   := public.fn_tope_fase(v_cuenta.fase);
    v_propio := (v_p ->> 'apalancamiento_maximo_propio')::numeric;
    v_riesgo := (v_p ->> 'riesgo_pct_operacion')::numeric;

    with u as (
        select * from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
    ),
    dim as (
        select u.*, d.cantidad, d.apalancamiento, d.margen, d.precio_liquidacion,
               d.motivo as motivo_dim, f.factor,
               least(coalesce(u.leverage_recomendado, v_tope), v_propio, v_tope) as lev_pedido
          from u
          -- 0032: prudencia como tamaño. El riesgo se escala por la
          -- volatilidad respecto a la referencia del perfil en ese mercado.
          cross join lateral (select public.fn_factor_riesgo(v_p, u.clase, u.atr_pct) as factor) f
          cross join lateral public.fn_dimensionar_posicion(
               v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
               u.precio_actual, u.sl, v_riesgo * f.factor,
               (v_p ->> 'margen_comprometido_max_pct')::numeric,
               least(coalesce(u.leverage_recomendado, v_tope), v_propio, v_tope),
               v_propio, v_tope, null, u.clase = 'accion') d
         where u.motivo is null
    ),
    ordenados as (
        select dim.*,
               row_number() over (order by ratio_rr desc,
                                           public.fn_rango_fuerza(fuerza) desc,
                                           (alcistas - bajistas) desc,
                                           simbolo asc) as puesto
          from dim
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'senal_id', senal_id, 'activo_id', activo_id, 'simbolo', simbolo,
               'clase', clase, 'fuerza', fuerza, 'niveles_origen', niveles_origen,
               'ratio_rr', round(ratio_rr, 4), 'atr_pct', atr_pct,
               'dominancia_neta', alcistas - bajistas, 'puesto', puesto,
               'apalancamiento_pedido', lev_pedido,
               'apalancamiento', apalancamiento, 'margen', margen,
               'cantidad', cantidad, 'precio_liquidacion', round(precio_liquidacion, 8),
               'precio', precio_actual, 'sl', sl, 'tp', tp,
               -- 0023: lo que rinde cada dólar de saldo para operar si
               -- toca el objetivo. Ordena qué se marca primero.
               'rendimiento', round(coalesce(apalancamiento, 0) * (tp - precio_actual) / precio_actual, 6),
               'factor_riesgo', factor,
               'descarte', case when (v_heat_clase ->> clase)::numeric
                                     < (v_p ->> 'riesgo_pct_operacion')::numeric * 0.25 then 'riesgo_clase_lleno'
                                when motivo_dim is not null then 'dimensionado:' || motivo_dim
                                when margen < 10 and factor < 1 then 'riesgo_escalado'
                                when margen < 10 then 'margen_minimo' end)
               order by puesto), '[]'::jsonb)
      into v_cands
      from ordenados;

    select count(*),
           count(*) filter (where motivo is distinct from 'fuera_de_sesion'
                              and motivo is distinct from 'antiguedad'),
           count(*) filter (where motivo is null or motivo = 'practica')
      into v_universo, v_frescas, v_antes
      from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas);

    select v_frescas > 0 and bool_and(motivo = 'direccion')
      into v_sin_alc
      from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
     where motivo is distinct from 'fuera_de_sesion' and motivo is distinct from 'antiguedad';

    select coalesce(jsonb_object_agg(m, n), '{}'::jsonb) into v_descartes
      from (select coalesce(motivo, 'candidata') as m, count(*) as n
              from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
             group by 1) t;
    -- 0032: los límites prudentes también cuentan como descarte, para que
    -- el agente pueda pedir que se amplíen con evidencia.
    select coalesce(jsonb_object_agg(d, n), '{}'::jsonb) into v_extra
      from (select c ->> 'descarte' as d, count(*) as n
              from jsonb_array_elements(v_cands) c
             where c ->> 'descarte' in ('riesgo_escalado', 'riesgo_clase_lleno')
             group by 1) t;
    v_descartes := v_descartes || v_extra;

    select coalesce(jsonb_agg(jsonb_build_object(
               'simbolo', simbolo, 'motivo', motivo, 'ratio_rr', round(ratio_rr, 4),
               'fuerza', fuerza) order by ratio_rr desc nulls last, simbolo), '[]'::jsonb)
      into v_top3
      from (select * from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
             where motivo is not null
               and motivo not in ('fuera_de_sesion', 'antiguedad')
             order by ratio_rr desc nulls last, simbolo
             limit 3) t;

    v_base := v_base || jsonb_build_object(
        'candidatos_evaluados', jsonb_array_length(v_cands),
        'candidatos_antes_practicas', v_antes,
        'candidatos', v_cands,
        'descartados_top3', v_top3,
        'descartes_por_motivo', v_descartes,
        'practicas_aplicadas', v_ids_pract,
        'universo', v_universo,
        'frescas', v_frescas,
        'sin_alcistas', coalesce(v_sin_alc, false),
        'saldo_libre', round(v_libre * v_tope, 2),
        'riesgo_abierto', round(v_abierto, 2),
        'riesgo_abierto_max', round(v_heat_max, 2),
        'parametros', v_p);

    -- ── Sin hueco: ¿merece la pena rotar? ───────────────────────────
    if v_sin_hueco is not null then
        if v_p ->> 'rotacion_umbral' is null then
            return v_base || jsonb_build_object('accion', v_sin_hueco, 'abiertas', v_abiertas);
        end if;

        -- La mejor señal que entraría si hubiera sitio: se ignoran los
        -- descartes por margen (al rotar se libera) pero no los de riesgo.
        select c into v_mejor
          from jsonb_array_elements(v_cands) c
         where c ->> 'descarte' is null
            or c ->> 'descarte' in ('dimensionado:margen_insuficiente', 'margen_minimo')
         order by (c ->> 'puesto')::int
         limit 1;

        -- La posición más débil: la de menor R:R restante al precio de
        -- ahora, con precio FRESCO (M4) y abierta hace más de 30 minutos,
        -- para que una orden recién abierta no se cierre por ruido.
        select m.id, m.simbolo, m.precio_vivo, m.tp, m.sl, m.cantidad,
               (m.tp - m.precio_vivo) / (m.precio_vivo - m.sl) as rr_restante
          into v_debil
          from public.v_ordenes_abiertas_monitor m
          join public.ordenes o on o.id = m.id
         where m.cuenta_id = v_cuenta.id
           and m.precio_vivo > m.sl and m.precio_vivo < m.tp
           and o.fecha_entrada < now() - interval '30 minutes'
         order by (m.tp - m.precio_vivo) / (m.precio_vivo - m.sl), m.id
         limit 1;

        if v_mejor is not null and v_debil.id is not null
           and (v_mejor ->> 'ratio_rr')::numeric
               >= (v_p ->> 'rotacion_umbral')::numeric * v_debil.rr_restante then
            return v_base || jsonb_build_object(
                'accion', 'rotar',
                'rotacion', jsonb_build_object(
                    'cerrar_orden_id', v_debil.id, 'cerrar_simbolo', v_debil.simbolo,
                    'precio', v_debil.precio_vivo, 'tp', v_debil.tp, 'sl', v_debil.sl,
                    'cantidad', v_debil.cantidad,
                    'rr_restante', round(v_debil.rr_restante, 4),
                    'umbral', (v_p ->> 'rotacion_umbral')::numeric,
                    'candidato', v_mejor));
        end if;
        return v_base || jsonb_build_object(
            'accion', v_sin_hueco, 'abiertas', v_abiertas,
            'rotacion_evaluada', jsonb_build_object(
                'mejor_rr', v_mejor -> 'ratio_rr',
                'debil_rr_restante', round(v_debil.rr_restante, 4),
                'umbral', v_p -> 'rotacion_umbral'));
    end if;

    -- ── 0023 · Qué marca: el reparto por exigencia ──────────────────
    -- Las válidas se ordenan por rendimiento sobre el saldo (las 5× con
    -- recorrido, primero) y se prueba a marcar 1, 2, 3… Para cada k, el
    -- saldo libre se reparte entre las k en proporción a su apalancamiento
    -- y cada una se dimensiona con esa parte como techo (el riesgo por
    -- operación sigue mandando). Se elige:
    --   · el MAYOR k cuya ganancia en objetivo cubre lo que falta de la
    --     meta: si falta poco, reparte y arriesga menos en cada una;
    --   · si ningún k la cubre, el de MÁS ganancia potencial: con mucha
    --     exigencia, concentra en lo que más rinde.
    -- Un k solo vale si todas sus marcadas caben (≥ 10 $ de margen y sin
    -- motivo del dimensionado). En cuarentena, como mucho una.
    select count(*) into v_validas
      from jsonb_array_elements(v_cands) c where c ->> 'descarte' is null;
    if v_validas = 0 then
        return v_base || jsonb_build_object('accion', 'sin_candidatos');
    end if;

    for v_k in 1 .. case when v_cuarentena then 1 else v_validas end loop
        with m as (
            select c, row_number() over (order by (c ->> 'rendimiento')::numeric desc,
                                                  (c ->> 'puesto')::int) as orden
              from jsonb_array_elements(v_cands) c
             where c ->> 'descarte' is null
        ),
        mk as (
            select c, orden, sum((c ->> 'apalancamiento')::numeric) over () as suma,
                   count(*) over (partition by c ->> 'clase') as kc
              from m where orden <= v_k
        ),
        d as (
            select mk.c, mk.orden, x.apalancamiento, x.motivo,
                   (mk.c ->> 'precio')::numeric as precio,
                   v_libre_pct * (mk.c ->> 'apalancamiento')::numeric / mk.suma as cupo,
                   -- Criptos truncadas (no redondeadas): ver rpc_repartir_saldo.
                   case when mk.c ->> 'clase' = 'accion' or x.cantidad is null then x.cantidad
                        else trunc(x.margen * x.apalancamiento / (mk.c ->> 'precio')::numeric, 8) end as cantidad,
                   x.margen as margen_dim
              from mk
              cross join lateral public.fn_dimensionar_posicion(
                   v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
                   (mk.c ->> 'precio')::numeric, (mk.c ->> 'sl')::numeric,
                   -- 0030: entre las k marcadas no arriesgan más que el
                   -- riesgo abierto que queda libre.
                   -- 0032: escalado por volatilidad y, si su mercado tiene
                   -- tope propio, sin pasar del riesgo libre de ese mercado
                   -- repartido entre sus marcadas (least ignora el nulo).
                   least(v_riesgo * (mk.c ->> 'factor_riesgo')::numeric, v_heat_libre_pct / v_k,
                         (v_heat_clase ->> (mk.c ->> 'clase'))::numeric / mk.kc),
                   (v_p ->> 'margen_comprometido_max_pct')::numeric,
                   (mk.c ->> 'apalancamiento_pedido')::numeric, v_propio, v_tope,
                   v_libre_pct * (mk.c ->> 'apalancamiento')::numeric / mk.suma,
                   mk.c ->> 'clase' = 'accion') x
        ),
        f as (
            select d.*, case when d.c ->> 'clase' = 'accion' or d.cantidad is null then d.margen_dim
                             else ceil(d.cantidad * d.precio / d.apalancamiento * 100) / 100 end as margen
              from d
        )
        select jsonb_agg((f.c - 'descarte') || jsonb_build_object(
                   'cantidad', f.cantidad, 'apalancamiento', f.apalancamiento, 'margen', f.margen,
                   'parte', round(v_equity * f.cupo / 100 * v_tope, 2),
                   'consumo', round(f.margen * v_tope, 2),
                   'ganancia_objetivo', round(f.cantidad * ((f.c ->> 'tp')::numeric - f.precio), 2),
                   'riesgo_stop', round(f.cantidad * (f.precio - (f.c ->> 'sl')::numeric), 2))
                   order by f.orden),
               sum(f.cantidad * ((f.c ->> 'tp')::numeric - f.precio)),
               bool_and(f.motivo is null and f.cantidad > 0 and f.margen >= 10)
          into v_set, v_gan, v_ok
          from f;

        v_evals := v_evals || jsonb_build_object('marcadas', v_k, 'valido', v_ok,
                                                 'ganancia_objetivo', round(v_gan, 2));
        continue when not coalesce(v_ok, false);
        if v_gan >= v_deficit then
            v_cubre_k := v_k;
            v_marcadas := v_set;
        end if;
        if v_mejor_g is null or v_gan > v_mejor_g then
            v_mejor_g := v_gan;
            v_mejor_k := v_k;
            if v_cubre_k is null then
                v_marcadas := v_set;
            end if;
        end if;
    end loop;

    if v_marcadas is null then
        return v_base || jsonb_build_object('accion', 'sin_candidatos',
                                            'reparto', jsonb_build_object('evaluado', v_evals));
    end if;
    return v_base || jsonb_build_object(
        'accion', 'abrir',
        'marcadas', v_marcadas,
        'reparto', jsonb_build_object(
            'modo', case when v_cubre_k is not null then 'cubre_meta' else 'maxima_ganancia' end,
            'marcadas', jsonb_array_length(v_marcadas),
            'deficit', round(v_deficit, 2),
            'ganancia_objetivo', (select round(sum((x ->> 'ganancia_objetivo')::numeric), 2)
                                    from jsonb_array_elements(v_marcadas) x),
            'evaluado', v_evals));
end;
$$;

create or replace function public.fn_autodiagnostico_agente(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    u        jsonb := public.fn_umbrales_autodiagnostico();
    v_ag     public.agentes;
    v_desde  timestamptz;
    v_dias   date;
    v_n      int := 0;
    v_r      record;
    v_sufijo text;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    v_sufijo := ':agente_' || p_agente_id;
    v_desde  := now() - ((u ->> 'ventana_ordenes_dias') || ' days')::interval;
    -- Las operaciones de antes de la 0030 (D21) se abrieron con los niveles
    -- viejos: pedir otra vez lo que ya se corrigió solo haría ruido, y el
    -- backlog lo reabriría cada semana. La ventana empieza, como pronto,
    -- cuando se aplicó la 0030.
    v_desde  := greatest(v_desde, coalesce(
                    (select max(creado_en) from public.eventos_sistema
                      where tipo = 'sys' and datos ->> 'migracion' = '0030'), '-infinity'::timestamptz));
    v_dias   := (now() at time zone 'UTC')::date - (u ->> 'ventana_dias')::int;

    -- a. Objetivos que no se alcanzan.
    select count(*) as cierres,
           count(*) filter (where o.motivo_cierre = 'tp') as tp,
           count(*) filter (where o.motivo_cierre in ('sl', 'liquidacion')) as sl,
           round((percentile_cont(0.5) within group (order by
               case when o.precio_max_visto is not null
                    then (o.precio_max_visto - o.precio_entrada) / (o.tp - o.precio_entrada) end))::numeric, 3)
               as avance_mediano,
           jsonb_agg(o.id order by o.id) as ordenes
      into v_r
      from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
     where c.agente_id = p_agente_id and o.estado = 'cerrada'
       and o.motivo_cierre in ('tp', 'sl', 'liquidacion') and o.fecha_salida >= v_desde;
    if v_r.cierres >= (u ->> 'objetivos_min_cierres')::int and v_r.tp = 0 then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:objetivos' || v_sufijo,
            'Mis objetivos no se alcanzan',
            format('%s cierres en 14 días, ninguno en el objetivo y %s en el stop. Mediana del camino recorrido hacia el objetivo: %s.',
                   v_r.cierres, v_r.sl, coalesce(v_r.avance_mediano::text, 'sin dato')),
            'Si ninguna operación llega al objetivo, el objetivo no es una salida real: revisar a qué distancia se pone y en cuánto tiempo se alcanza.',
            jsonb_build_object('cierres', v_r.cierres, 'tp', v_r.tp, 'sl', v_r.sl,
                               'avance_mediano', v_r.avance_mediano, 'ordenes', v_r.ordenes), 2);
        v_n := v_n + 1;
    end if;

    -- b. Stops dentro del ruido.
    select count(*) as n,
           round((percentile_cont(0.5) within group (order by
               ((o.precio_entrada - coalesce(o.sl_original, o.sl)) / o.precio_entrada * 100) / s.atr_pct))::numeric, 3)
               as mediana_atr,
           jsonb_agg(o.id order by o.id) as ordenes
      into v_r
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.senales s on s.id = o.senal_id
     where c.agente_id = p_agente_id and o.fecha_entrada >= v_desde and s.atr_pct > 0;
    if v_r.n >= (u ->> 'stop_min_ordenes')::int and v_r.mediana_atr < (u ->> 'stop_mediana_atr')::numeric then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:stops' || v_sufijo,
            'Mis stops están dentro del ruido',
            format('Mediana de la distancia al stop: %s ATR en %s entradas. Un día típico se mueve 1 ATR.', v_r.mediana_atr, v_r.n),
            'Un stop a menos de medio ATR lo salta el ruido de la propia sesión.',
            jsonb_build_object('entradas', v_r.n, 'mediana_atr', v_r.mediana_atr, 'ordenes', v_r.ordenes), 2);
        v_n := v_n + 1;
    end if;

    -- c. Entradas con votos en contra.
    select count(*) as n,
           count(*) filter (where s.indicadores_bajistas > 0) as contradictorias,
           jsonb_agg(o.id order by o.id) filter (where s.indicadores_bajistas > 0) as ordenes
      into v_r
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.senales s on s.id = o.senal_id
     where c.agente_id = p_agente_id and o.fecha_entrada >= v_desde;
    if v_r.n >= (u ->> 'votos_min_ordenes')::int
       and v_r.contradictorias * 100 >= v_r.n * (u ->> 'votos_pct_contradictorias')::numeric then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:votos' || v_sufijo,
            'Entro con señales que se contradicen',
            format('%s de %s entradas tenían al menos un indicador en contra.', v_r.contradictorias, v_r.n),
            'Una señal que se contradice es una apuesta, no una confluencia.',
            jsonb_build_object('entradas', v_r.n, 'contradictorias', v_r.contradictorias, 'ordenes', v_r.ordenes), 3);
        v_n := v_n + 1;
    end if;

    -- d. Un solo filtro tumba casi todas las candidatas. No cuentan los
    --    descartes que no son del perfil: mercado cerrado, señal añeja,
    --    posición ya abierta, ni la dirección (solo largos es una regla
    --    protegida y ya tiene su propio disparador).
    with d as (
        select key as motivo, sum(value::int) as n
          from public.agente_dias ad, jsonb_each_text(ad.descartes)
         where ad.agente_id = p_agente_id and ad.fecha >= v_dias
           and key not in ('fuera_de_sesion', 'antiguedad', 'posicion_abierta', 'direccion', 'candidata',
                           'riesgo_escalado', 'riesgo_clase_lleno')
         group by key
    )
    select (select motivo from d order by n desc, motivo limit 1) as motivo,
           (select max(n) from d) as top, (select sum(n) from d) as total,
           (select jsonb_object_agg(motivo, n) from d) as reparto
      into v_r;
    if v_r.total >= (u ->> 'filtro_min_descartes')::int
       and v_r.top * 100 >= v_r.total * (u ->> 'filtro_pct')::numeric then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla',
            'diagnostico:filtro:' || v_r.motivo || v_sufijo,
            'El filtro «' || v_r.motivo || '» me deja sin operar',
            format('En 7 días, el %s %% de mis descartes (%s de %s) fueron por «%s».',
                   round(v_r.top * 100.0 / v_r.total), v_r.top, v_r.total, v_r.motivo),
            'Prudente no puede ser no operar: un único criterio que lo descarta casi todo merece revisarse, o graduarse en tamaño en vez de excluir.',
            jsonb_build_object('motivo', v_r.motivo, 'descartes', v_r.reparto, 'desde', v_dias), 3);
        v_n := v_n + 1;
    end if;

    -- e. Saldo atrapado con candidatas esperando.
    select coalesce(sum(ad.ciclos_saldo_atrapado), 0) as ciclos,
           jsonb_agg(jsonb_build_object('fecha', ad.fecha, 'ciclos', ad.ciclos_saldo_atrapado) order by ad.fecha)
               filter (where ad.ciclos_saldo_atrapado > 0) as dias
      into v_r
      from public.agente_dias ad
     where ad.agente_id = p_agente_id and ad.fecha >= v_dias;
    if v_r.ciclos >= (u ->> 'saldo_atrapado_ciclos')::int then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:saldo_atrapado' || v_sufijo,
            'Mi saldo queda atrapado con la bolsa cerrada',
            format('%s ciclos (unas %s horas) con el saldo lleno, candidatas esperando y posiciones de acciones que no se podían cerrar.',
                   v_r.ciclos, round(v_r.ciclos * 5 / 60.0, 1)),
            'Antes del cierre habría que evaluar si mantener las acciones compensa frente a lo que ofrecen los mercados que siguen abiertos.',
            jsonb_build_object('ciclos', v_r.ciclos, 'dias', v_r.dias), 2);
        v_n := v_n + 1;
    end if;

    -- f. Ninguna meta diaria cumplida.
    select count(*) filter (where ad.operable) as operables,
           count(*) filter (where ad.operable and ad.cumplido) as cumplidos,
           round(max(ad.rendimiento_pct), 3) as mejor_dia_pct,
           (select round(percentile_cont(0.5) within group (order by s.atr_pct)::numeric, 2)
              from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
              join public.senales s on s.id = o.senal_id
             where c.agente_id = p_agente_id and o.fecha_entrada >= v_desde) as atr_mediano
      into v_r
      from public.agente_dias ad
     where ad.agente_id = p_agente_id and ad.fecha >= v_dias and ad.fecha < (now() at time zone 'UTC')::date;
    if v_r.operables >= (u ->> 'metas_min_dias')::int and v_r.cumplidos = 0 then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:meta' || v_sufijo,
            'Mi meta diaria no es alcanzable con mi perfil',
            format('0 de %s días operables con la meta del %s %% cumplida. Mejor día: %s %%. ATR mediano de mis entradas: %s %%.',
                   v_r.operables, v_ag.objetivo_diario_pct, coalesce(v_r.mejor_dia_pct::text, 'sin dato'),
                   coalesce(v_r.atr_mediano::text, 'sin dato')),
            'Si la meta exige más movimiento del que da el mercado que opero, o cambio de perfil o cambio de meta.',
            jsonb_build_object('dias_operables', v_r.operables, 'cumplidos', 0,
                               'meta_pct', v_ag.objetivo_diario_pct, 'mejor_dia_pct', v_r.mejor_dia_pct,
                               'atr_mediano', v_r.atr_mediano), 2);
        v_n := v_n + 1;
    end if;

    -- g. Prácticas adoptadas que empeoran ahora.
    for v_r in
        select ad.practica_id, p.titulo, count(o.id) as ops, round(avg(o.pnl_pct), 4) as pnl_medio,
               jsonb_agg(o.id order by o.id) as ordenes
          from public.mp_adopciones ad
          join public.mejores_practicas p on p.id = ad.practica_id
          join public.cuentas_simulacion c on c.agente_id = ad.agente_id
          join public.ordenes o on o.cuenta_id = c.id and o.estado = 'cerrada'
                               and o.fecha_entrada >= greatest(ad.adoptada_en, v_desde)
         where ad.agente_id = p_agente_id and ad.abandonada_en is null
         group by ad.practica_id, p.titulo
        having count(o.id) >= (u ->> 'practica_min_ops')::int and avg(o.pnl_pct) < 0
    loop
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla',
            'diagnostico:practica:' || v_r.practica_id || v_sufijo,
            'La práctica «' || v_r.titulo || '» ya no me funciona',
            format('%s operaciones en 14 días con la práctica aplicada y un P&L medio del %s %%.', v_r.ops, v_r.pnl_medio),
            'Una práctica que funcionó puede haber sido situacional: si el mercado ha cambiado, seguirla es seguir un error.',
            jsonb_build_object('practica_id', v_r.practica_id, 'ops', v_r.ops, 'pnl_medio_pct', v_r.pnl_medio,
                               'ordenes', v_r.ordenes), 3);
        v_n := v_n + 1;
    end loop;

    -- h. 0032 · Los límites prudentes dejan fuera demasiadas candidatas: el
    --    agente pide que se amplíen. Nada se amplía solo; decide el humano.
    for v_r in
        select (regexp_match(key, '^riesgo_(escalado|clase_lleno)$'))[1] as limite, sum(value::int) as n
          from public.agente_dias ad, jsonb_each_text(ad.descartes)
         where ad.agente_id = p_agente_id and ad.fecha >= v_dias
           and key in ('riesgo_escalado', 'riesgo_clase_lleno')
         group by key
        having sum(value::int) >= (u ->> 'riesgo_prudente_descartes')::int
    loop
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla',
            'diagnostico:riesgo_' || v_r.limite || v_sufijo,
            case v_r.limite when 'escalado' then 'Ampliar mi riesgo en los activos volátiles'
                            else 'Ampliar mi riesgo abierto por mercado' end,
            format('En 7 días, %s veces una candidata quedó fuera solo por mi límite prudente («%s»): con el riesgo reducido por volatilidad no llegaba al margen mínimo de 10 $, o el riesgo abierto de su mercado estaba lleno.',
                   v_r.n, v_r.limite),
            'Ser prudente es arriesgar menos, no dejar de operar. Si el límite deja fuera candidatas de forma repetida, quizá es demasiado estricto para mi saldo.',
            jsonb_build_object('limite', v_r.limite, 'candidatas_ciclo', v_r.n, 'desde', v_dias,
                               'parametros', public.fn_parametros_agente(v_ag) -> 'por_clase'), 3);
        v_n := v_n + 1;
    end loop;

    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'agente',
            v_ag.nombre || case when v_n = 0 then ' revisa su semana: nada que pedir'
                                else format(' revisa su semana y pide %s cambios', v_n) end,
            jsonb_build_object('autodiagnostico', v_n));
    return v_n;
end;
$$;
