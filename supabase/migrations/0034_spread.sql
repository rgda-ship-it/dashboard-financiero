-- ─────────────────────────────────────────────────────────────────────
-- 0034 — El spread: se compra al precio de compra y se vende al de venta
-- (D23, escenario pesimista elegido por el dueño, 2026-10-11).
--
-- Hasta hoy el simulador usaba un único precio por activo (el último de
-- Yahoo o de CoinGecko) y entraba y salía a ese precio: el spread no
-- existía. Todo resultado era optimista, y más en las operaciones de poco
-- recorrido y en las salidas a mercado (deterioro, rotación), que pagan el
-- spread dos veces.
--
-- Plataforma de referencia: QuantFury (el dueño). Sin comisiones y sin
-- financiación por mantener posiciones apalancadas: solo el spread.
--
--   · Acciones: «entre 0,01 y 0,03 $ por acción» → 0,03 $ (pesimista).
--     En una acción de 10 $ es un 0,3 %: nada despreciable.
--   · Cripto: el libro mayorista. BTC «entre 1 y 5 $» → 5 $; ETH «unos
--     centavos» → 0,10 $. El resto, sin dato: 0,10 % del precio, un
--     supuesto deliberadamente pesimista que el dueño puede bajar.
--
-- Los valores viven en la tabla `mercados` (por defecto del mercado) y en
-- `activos` (por activo, si se conoce). Se cambian con un UPDATE: nada de
-- esto está en el código.
--
-- DÓNDE SE PAGA. Solo al ejecutar, con el precio intermedio p y el spread s:
--   compra = p + s/2         venta = p − s/2
--   · al abrir sin precio a mano (agentes y recomendaciones): a la compra;
--   · el monitor dispara stop, objetivo y liquidación con el precio de
--     venta (una posición larga se cierra vendiendo) y un hueco sale a la
--     venta;
--   · las salidas a mercado (a mano, deterioro, rotación) y la toma
--     parcial a mano, a la venta;
--   · el agente dimensiona al precio de compra y descarta lo que con el
--     spread ya no llega a su R:R mínimo (`rr_con_spread`).
-- Las posiciones abiertas se siguen VALORANDO al precio intermedio: es lo
-- que muestran los proveedores, y el medio spread de la salida se paga al
-- salir.
-- ─────────────────────────────────────────────────────────────────────

alter table public.mercados
    add column spread_abs numeric(20, 8) not null default 0 check (spread_abs >= 0),
    add column spread_pct numeric(8, 4)  not null default 0 check (spread_pct >= 0);

comment on column public.mercados.spread_abs is
  'Spread por defecto del mercado en dólares por unidad (0034). Se usa el mayor de spread_abs y precio × spread_pct.';
comment on column public.mercados.spread_pct is
  'Spread por defecto del mercado en % del precio (0034).';

alter table public.activos
    add column spread_abs numeric(20, 8) check (spread_abs >= 0),
    add column spread_pct numeric(8, 4)  check (spread_pct >= 0);

comment on column public.activos.spread_abs is
  'Spread de este activo en dólares por unidad, si se conoce (0034). Si spread_abs o spread_pct están definidos, mandan sobre los del mercado.';

update public.mercados set spread_abs = 0.03, spread_pct = 0    where clave = 'nyse';
update public.mercados set spread_abs = 0,    spread_pct = 0.10 where clave = 'cripto';
update public.activos  set spread_abs = 5,    spread_pct = 0    where simbolo = 'bitcoin';
update public.activos  set spread_abs = 0.10, spread_pct = 0    where simbolo = 'ethereum';

-- El spread completo, en dólares por unidad, de un activo a un precio.
create function public.fn_spread(p_activo_id bigint, p_precio numeric)
returns numeric
language sql stable
as $$
    select case when a.spread_abs is not null or a.spread_pct is not null
                then greatest(coalesce(a.spread_abs, 0), p_precio * coalesce(a.spread_pct, 0) / 100)
                else greatest(coalesce(m.spread_abs, 0), p_precio * coalesce(m.spread_pct, 0) / 100) end
      from public.activos a
      left join public.mercados m on m.clave = public.fn_mercado_de_clase(a.clase)
     where a.id = p_activo_id
$$;

create function public.fn_precio_compra(p_activo_id bigint, p_precio numeric)
returns numeric
language sql stable
as $$ select round(p_precio + coalesce(public.fn_spread(p_activo_id, p_precio), 0) / 2, 8) $$;

-- Nunca por debajo de la mitad del intermedio: un spread mal escrito no
-- puede convertir una venta en un regalo.
create function public.fn_precio_venta(p_activo_id bigint, p_precio numeric)
returns numeric
language sql stable
as $$ select round(greatest(p_precio - coalesce(public.fn_spread(p_activo_id, p_precio), 0) / 2, p_precio / 2), 8) $$;

revoke execute on function public.fn_spread(bigint, numeric)         from public, anon;
revoke execute on function public.fn_precio_compra(bigint, numeric)  from public, anon;
revoke execute on function public.fn_precio_venta(bigint, numeric)   from public, anon;
grant  execute on function public.fn_spread(bigint, numeric)         to authenticated;
grant  execute on function public.fn_precio_compra(bigint, numeric)  to authenticated;
grant  execute on function public.fn_precio_venta(bigint, numeric)   to authenticated;

-- Cuánto costó el spread en cada orden cerrada: la entrada frente al
-- intermedio de su señal, y la salida frente al precio observado.
create view public.v_coste_spread
with (security_invoker = true) as
    select o.id as orden_id, o.cuenta_id, a.simbolo, a.clase, o.estado, o.motivo_cierre,
           round(o.cantidad * greatest(o.precio_entrada - s.precio_actual, 0), 2) as coste_entrada,
           case when o.estado = 'cerrada'
                then round(o.cantidad * greatest(o.precio_observado_cierre - o.precio_salida, 0), 2) end as coste_salida
      from public.ordenes o
      join public.activos a on a.id = o.activo_id
      left join public.senales s on s.id = o.senal_id
     where o.creado_en >= (select coalesce(max(creado_en), '-infinity'::timestamptz)
                             from public.eventos_sistema where tipo = 'sys' and datos ->> 'migracion' = '0034');

comment on view public.v_coste_spread is
  'Coste del spread por orden desde la 0034: la entrada frente al precio intermedio de su señal y, si está cerrada, la salida frente al precio observado. En una salida por nivel (stop, objetivo) el coste de salida es la distancia entre el precio que la disparó y el nivel.';

insert into public.eventos_sistema (tipo, mensaje, datos)
values ('sys', 'Spread: se compra al precio de compra y se vende al de venta (escenario pesimista)',
        jsonb_build_object('migracion', '0034',
                           'acciones_spread_abs', 0.03, 'cripto_spread_pct', 0.10,
                           'bitcoin_spread_abs', 5, 'ethereum_spread_abs', 0.10));


-- ═════════════════════════════════════════════════════════════════════
-- Las funciones que ejecutan, con el spread (las de la 0011, 0016, 0023,
-- 0032 y 0033 con los cambios marcados «0034»)
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.rpc_abrir_orden(
    p_cuenta_id      bigint,
    p_senal_id       bigint,
    p_precio_entrada numeric default null,
    p_fecha_entrada  timestamptz default null,
    p_apalancamiento numeric default null,
    p_riesgo_pct     numeric default null,
    p_origen         text default 'recomendacion',
    p_racional       jsonb default null,
    p_cantidad       numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid        uuid := auth.uid();
    v_cuenta     public.cuentas_simulacion;
    v_senal      record;
    v_equity     numeric;
    v_tope       numeric;
    v_precio     numeric;
    v_fecha      timestamptz;
    v_riesgo_pct numeric;
    v_rr         numeric;
    v_abiertas   int;
    v_dim        record;
    v_cantidad   numeric;
    v_margen     numeric;
    v_orden      bigint;
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id using errcode = '42501';
    end if;

    if v_cuenta.usuario_id is not null then
        if v_uid is null or v_uid <> v_cuenta.usuario_id or not public.es_usuario_aprobado() then
            raise exception 'Esa cuenta no es tuya.' using errcode = '42501';
        end if;
    elsif v_uid is not null then
        raise exception 'Las cuentas de agente solo las opera el servidor.' using errcode = '42501';
    end if;

    if v_cuenta.estado <> 'activa' then
        raise exception 'La cuenta está en estado «%»: no admite operaciones nuevas.', v_cuenta.estado
              using errcode = 'P0001';
    end if;
    if p_origen not in ('recomendacion', 'manual', 'agente') then
        raise exception 'Origen no válido: %', p_origen using errcode = '22023';
    end if;

    -- ── G5 ──────────────────────────────────────────────────────────
    select s.id, s.activo_id, s.operable, s.precio_actual, s.tp, s.sl,
           s.leverage_recomendado, s.calculado_en, a.clase, a.simbolo,
           a.estado as estado_activo,
           round(extract(epoch from now() - s.calculado_en) / 60)::int as antiguedad_min
      into v_senal
      from public.senales s join public.activos a on a.id = s.activo_id
     where s.id = p_senal_id;
    if not found then
        raise exception 'La señal % no existe', p_senal_id using errcode = '22023';
    end if;
    if not v_senal.operable then
        raise exception 'La señal de % no es operable: el motor no encuadra ninguna operación con ella.',
              v_senal.simbolo using errcode = 'P0001';
    end if;
    if v_senal.antiguedad_min > v_cuenta.antiguedad_senal_max_min then
        raise exception 'La señal de % es de hace % minutos (máximo %): pide un escaneo nuevo.',
              v_senal.simbolo, v_senal.antiguedad_min, v_cuenta.antiguedad_senal_max_min
              using errcode = 'P0001';
    end if;
    if v_senal.estado_activo <> 'activo' then
        raise exception 'El activo % está en estado «%»: sus datos no son fiables ahora mismo.',
              v_senal.simbolo, v_senal.estado_activo using errcode = 'P0001';
    end if;

    if v_cuenta.usuario_id is not null
       and not exists (select 1 from public.cartera_activos ca
                         join public.carteras c on c.id = ca.cartera_id
                        where c.usuario_id = v_cuenta.usuario_id
                          and ca.activo_id = v_senal.activo_id) then
        raise exception 'No sigues %: añádelo a tu cartera antes de operarlo.', v_senal.simbolo
              using errcode = 'P0001';
    end if;

    -- ── G4 · retirado también para los agentes (0023, D17) ──────────
    -- Cuántas posiciones abre un agente lo decide su reparto por exigencia
    -- (`fn_decidir_agente`); lo que acota la exposición, para él igual que
    -- para el usuario, es el riesgo por operación (G2) y el saldo para
    -- operar (G3). La cuarentena («una posición») la impone la decisión.
    if exists (select 1 from public.ordenes
                where cuenta_id = p_cuenta_id and activo_id = v_senal.activo_id
                  and estado = 'abierta') then
        raise exception 'Ya tienes una posición abierta en %.', v_senal.simbolo
              using errcode = 'P0001';
    end if;

    -- 0034: sin precio a mano se compra al precio de COMPRA (el intermedio
    -- más medio spread), no al intermedio.
    v_precio := coalesce(p_precio_entrada, public.fn_precio_compra(v_senal.activo_id, v_senal.precio_actual));
    v_fecha  := coalesce(p_fecha_entrada, now());
    if v_precio is null or v_precio <= 0 then
        raise exception 'El precio de entrada debe ser mayor que cero.' using errcode = '22023';
    end if;
    if v_fecha > now() then
        raise exception 'La fecha de entrada no puede estar en el futuro.' using errcode = '22023';
    end if;
    if v_fecha < now() - interval '30 days' then
        raise exception 'La fecha de entrada no puede tener más de 30 días.' using errcode = '22023';
    end if;
    if not (v_senal.tp > v_precio and v_senal.sl < v_precio) then
        raise exception 'Con una entrada de % los niveles no encuadran: el objetivo está en % y el stop en %.',
              round(v_precio, 8), round(v_senal.tp, 8), round(v_senal.sl, 8)
              using errcode = 'P0001';
    end if;

    v_rr := (v_senal.tp - v_precio) / (v_precio - v_senal.sl);
    if v_rr < v_cuenta.ratio_rr_minimo then
        raise exception 'Relación riesgo/beneficio de %: por debajo del mínimo de % que exige tu cuenta.',
              round(v_rr, 2), v_cuenta.ratio_rr_minimo using errcode = 'P0001';
    end if;

    -- ── G1 ──────────────────────────────────────────────────────────
    v_tope := public.fn_tope_fase(v_cuenta.fase);
    if p_apalancamiento is not null and p_apalancamiento > v_tope then
        raise exception 'Apalancamiento %x rechazado: el tope de la % es %x.',
              p_apalancamiento, replace(v_cuenta.fase, '_', ' '), v_tope using errcode = 'P0001';
    end if;
    if p_apalancamiento is not null and p_apalancamiento < 1 then
        raise exception 'El apalancamiento mínimo es 1x.' using errcode = '22023';
    end if;

    -- ── G2 ──────────────────────────────────────────────────────────
    v_riesgo_pct := coalesce(p_riesgo_pct, v_cuenta.riesgo_pct_operacion);
    if v_riesgo_pct <= 0 or v_riesgo_pct > 10 then
        raise exception 'El riesgo por operación debe estar entre 0 y 10 %% del equity. Recibido: %',
              v_riesgo_pct using errcode = 'P0001';
    end if;

    v_equity := public.fn_equity(p_cuenta_id);
    if v_equity < 10 then
        raise exception 'Equity de % $: por debajo del margen mínimo de 10 $ no se abre nada.',
              round(v_equity, 2) using errcode = 'P0001';
    end if;

    select * into v_dim from public.fn_dimensionar_posicion(
        v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
        v_precio, v_senal.sl, v_riesgo_pct, v_cuenta.margen_comprometido_max_pct,
        coalesce(p_apalancamiento, v_senal.leverage_recomendado), p_apalancamiento, v_tope,
        null, v_senal.clase = 'accion');

    -- El apalancamiento lo decide siempre el dimensionado (G1 y N4), también
    -- con cantidad a mano: esos dos motivos no tienen arreglo cambiando el
    -- tamaño. Los de margen sí, así que con cantidad a mano no se lanzan
    -- aquí: los juzgan las comprobaciones independientes de abajo.
    if v_dim.motivo = 'sin_operacion_liquidacion_antes_del_stop' then
        raise exception 'El stop queda por debajo del precio de liquidación incluso a 1x: esta operación no se puede abrir con el riesgo declarado.'
              using errcode = 'P0001';
    elsif v_dim.motivo in ('stop_por_encima_del_precio', 'apalancamiento_bajo_uno') then
        raise exception 'El dimensionado no encuadra la operación (%).', v_dim.motivo
              using errcode = 'P0001';
    elsif p_cantidad is null and v_dim.motivo = 'margen_insuficiente' then
        raise exception 'No queda margen libre: tienes % $ disponibles y el tope de margen comprometido de tu cuenta es el % %% del equity.',
              round(v_cuenta.saldo_disponible, 2), v_cuenta.margen_comprometido_max_pct
              using errcode = 'P0001';
    elsif p_cantidad is null and v_dim.motivo is not null then
        raise exception 'El dimensionado no encuadra la operación (%).', v_dim.motivo
              using errcode = 'P0001';
    end if;

    -- ── 0016 · Cantidad a mano ──────────────────────────────────────
    -- El usuario (o el agente, que siempre manda la suya) decide cuánto;
    -- el margen se deduce con el apalancamiento que fijó el dimensionado, y
    -- se redondea HACIA ARRIBA: con el céntimo de menos, el margen no
    -- cubriría el nominal.
    if p_cantidad is not null then
        if p_cantidad <= 0 then
            raise exception 'La cantidad debe ser mayor que cero.' using errcode = '22023';
        end if;
        -- Las acciones no admiten fracciones (las criptos sí).
        if v_senal.clase = 'accion' and p_cantidad <> trunc(p_cantidad) then
            raise exception 'Las acciones se compran por unidades enteras: % no es un número entero.',
                  p_cantidad using errcode = '22023';
        end if;
        v_cantidad := round(p_cantidad, 8);
        v_margen   := ceil(v_cantidad * v_precio / v_dim.apalancamiento * 100) / 100;
    else
        v_cantidad := v_dim.cantidad;
        v_margen   := v_dim.margen;
    end if;

    -- ── G3 · comprobación independiente ─────────────────────────────
    if v_margen > v_cuenta.saldo_disponible then
        raise exception 'Margen de % $ por encima del saldo disponible (% $).',
              v_margen, round(v_cuenta.saldo_disponible, 2) using errcode = 'P0001';
    end if;
    if v_cuenta.saldo_bloqueado + v_margen
       > v_equity * v_cuenta.margen_comprometido_max_pct / 100 + 0.01 then
        raise exception 'Con esta orden el margen comprometido sería % $, por encima del % %% del equity que admite tu cuenta.',
              round(v_cuenta.saldo_bloqueado + v_margen, 2),
              v_cuenta.margen_comprometido_max_pct using errcode = 'P0001';
    end if;
    -- G2, sobre el tamaño final y no sobre la intención.
    if v_cantidad * (v_precio - v_senal.sl) > v_equity * 10 / 100 + 0.01 then
        raise exception 'El riesgo de esta orden (% $) supera el 10 %% del equity: reduce la cantidad.',
              round(v_cantidad * (v_precio - v_senal.sl), 2) using errcode = 'P0001';
    end if;

    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion, racional)
    values (p_cuenta_id, v_senal.activo_id, p_senal_id, p_origen, v_precio, v_fecha,
            v_cantidad, v_dim.apalancamiento, v_margen,
            v_senal.tp, v_senal.sl, round(v_dim.precio_liquidacion, 8), p_racional)
    returning id into v_orden;

    perform public.fn_registrar_movimiento(
        p_cuenta_id, v_orden, 'bloqueo_margen', -v_margen, v_margen);

    return jsonb_build_object(
        'orden_id', v_orden, 'simbolo', v_senal.simbolo,
        'cantidad', v_cantidad, 'apalancamiento', v_dim.apalancamiento,
        'margen', v_margen, 'precio_entrada', v_precio,
        'precio_liquidacion', round(v_dim.precio_liquidacion, 8),
        'tp', v_senal.tp, 'sl', v_senal.sl, 'ratio_rr', round(v_rr, 4),
        'cantidad_a_mano', p_cantidad is not null,
        'apalancamiento_reducido', v_dim.apalancamiento < least(
            coalesce(p_apalancamiento, v_senal.leverage_recomendado, v_tope), v_tope));
end;
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
        -- 0034: el agente dimensiona al precio al que de verdad compraría.
        select x.*, public.fn_precio_compra(x.activo_id, x.precio_actual) as precio_compra
          from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas) x
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
               u.precio_compra, u.sl, v_riesgo * f.factor,
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
               'precio', precio_compra, 'precio_medio', precio_actual, 'sl', sl, 'tp', tp,
               -- 0023: lo que rinde cada dólar de saldo para operar si
               -- toca el objetivo. Ordena qué se marca primero.
               'rendimiento', round(coalesce(apalancamiento, 0) * (tp - precio_compra) / precio_compra, 6),
               'factor_riesgo', factor,
               'descarte', case when (v_heat_clase ->> clase)::numeric
                                     < (v_p ->> 'riesgo_pct_operacion')::numeric * 0.25 then 'riesgo_clase_lleno'
                                -- 0034: con el spread pagado, el R:R real puede
                                -- quedar por debajo del mínimo del perfil.
                                when tp <= precio_compra or sl >= precio_compra
                                     or (tp - precio_compra) / (precio_compra - sl)
                                        < (v_p ->> 'rr_minimo')::numeric then 'rr_con_spread'
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

create or replace function public.rpc_cerrar_orden(
    p_orden_id         bigint,
    p_precio_salida    numeric,
    p_motivo           text,
    p_precio_observado numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_orden    public.ordenes;
    v_cuenta   public.cuentas_simulacion;
    v_pnl      numeric(20, 2);
    v_pnl_pct  numeric(10, 4);
    v_simbolo  text;
    v_ejec     numeric;
begin
    -- Bloqueo pesimista: si dos pasadas del monitor entran a la vez, la
    -- segunda espera aquí y al continuar encuentra estado <> 'abierta'.
    select * into v_orden from public.ordenes where id = p_orden_id for update;
    if not found then
        raise exception 'La orden % no existe', p_orden_id;
    end if;

    -- Idempotencia. NO es un error: en un monitor concurrente encontrarse
    -- una orden ya cerrada es el caso normal. Si esto lanzara, el registro
    -- se llenaría de errores falsos y el verdadero se perdería.
    if v_orden.estado <> 'abierta' then
        return jsonb_build_object(
            'cerrada', false,
            'motivo', 'la orden ya estaba en estado ' || v_orden.estado);
    end if;

    select * into v_cuenta from public.cuentas_simulacion
     where id = v_orden.cuenta_id for update;

    -- 0034: una salida a mercado (a mano, por deterioro o por rotación)
    -- vende al precio de VENTA: el intermedio menos medio spread. Las
    -- salidas por nivel (stop, objetivo, liquidación) ya traen el precio
    -- de ejecución: el monitor las dispara con el precio de venta.
    v_ejec := case when p_motivo in ('manual', 'deterioro', 'rotacion')
                   then public.fn_precio_venta(v_orden.activo_id, p_precio_salida)
                   else p_precio_salida end;

    v_pnl := round(v_orden.cantidad * (v_ejec - v_orden.precio_entrada), 2);
    v_pnl_pct := round(
        ((v_ejec - v_orden.precio_entrada) / v_orden.precio_entrada) * 100, 4);

    -- El margen no puede perder más de lo comprometido: por debajo de eso
    -- hay liquidación, no deuda. Sin este clamp, un hueco de mercado
    -- dejaría el saldo en negativo, el CHECK (saldo_disponible >= 0)
    -- abortaría la transacción, y la orden quedaría abierta PARA SIEMPRE:
    -- el peor fallo posible en un monitor automático.
    if v_pnl < -v_orden.margen_comprometido then
        v_pnl := -v_orden.margen_comprometido;
    end if;

    update public.ordenes set
        estado = 'cerrada',
        precio_salida = v_ejec,
        fecha_salida = now(),
        motivo_cierre = p_motivo,
        precio_observado_cierre = coalesce(p_precio_observado, p_precio_salida),
        pnl_bruto = v_pnl,
        pnl_pct = v_pnl_pct,
        actualizado_en = now()
      where id = p_orden_id and estado = 'abierta';   -- cinturón y tirantes

    if not found then
        raise exception 'Carrera detectada al cerrar la orden %', p_orden_id;
    end if;

    -- DOS apuntes, no uno: liberar el margen y aplicar el resultado son
    -- hechos económicos distintos. Fusionarlos en un movimiento neto hace
    -- imposible reconstruir cuánto margen estuvo comprometido y cuándo,
    -- que es justo lo que se necesita para auditar el riesgo.
    perform public.fn_registrar_movimiento(
        v_orden.cuenta_id, p_orden_id, 'liberacion_margen',
        v_orden.margen_comprometido, -v_orden.margen_comprometido);
    perform public.fn_registrar_movimiento(
        v_orden.cuenta_id, p_orden_id, 'resultado_operacion', v_pnl, 0);

    update public.cuentas_simulacion
       set operaciones_en_fase = operaciones_en_fase + 1, actualizado_en = now()
     where id = v_orden.cuenta_id;

    select simbolo into v_simbolo from public.activos where id = v_orden.activo_id;
    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (v_cuenta.usuario_id, 'orden_cerrada',
            format('%s cerrada por %s: %s $', v_simbolo, p_motivo, v_pnl),
            jsonb_build_object('orden_id', p_orden_id, 'cuenta_id', v_orden.cuenta_id,
                               'simbolo', v_simbolo, 'motivo', p_motivo,
                               'precio_salida', v_ejec,
                               'precio_observado', coalesce(p_precio_observado, p_precio_salida),
                               'pnl', v_pnl, 'pnl_pct', v_pnl_pct));

    -- Máquina de fases y Game Over, en ese orden.
    perform public.rpc_evaluar_fase(v_orden.cuenta_id);
    perform public.rpc_evaluar_game_over(v_orden.cuenta_id);

    return jsonb_build_object('cerrada', true, 'pnl', v_pnl, 'pnl_pct', v_pnl_pct,
                              'saldo_disponible',
                              (select saldo_disponible from public.cuentas_simulacion
                                where id = v_orden.cuenta_id));
end;
$$;

create or replace function public.fn_cerrar_parcial(
    p_orden_id bigint, p_fraccion numeric, p_precio numeric, p_motivo text, p_observado numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_orden    public.ordenes;
    v_cuenta   public.cuentas_simulacion;
    v_cant     numeric;
    v_margen   numeric(20, 2);
    v_pnl      numeric(20, 2);
    v_simbolo  text;
    v_precio   numeric := p_precio;
begin
    -- 0034: una toma parcial a mano vende al precio de venta. La del
    -- agente (`tp_parcial`) va a su nivel, como un objetivo.
    if p_motivo = 'manual' then
        select public.fn_precio_venta(activo_id, p_precio) into v_precio from public.ordenes where id = p_orden_id;
    end if;
    if p_fraccion is null or p_fraccion <= 0 or p_fraccion >= 1 then
        raise exception 'La fracción a cerrar va entre 0 y 1, sin incluirlos (para cerrar todo, cierra la posición).'
              using errcode = '22023';
    end if;

    -- Mismo bloqueo que `rpc_cerrar_orden`: si el monitor cierra la orden
    -- a la vez, uno espera al otro y el segundo ve el estado real.
    select * into v_orden from public.ordenes where id = p_orden_id for update;
    if not found then
        raise exception 'La orden % no existe', p_orden_id;
    end if;
    if v_orden.estado <> 'abierta' then
        return jsonb_build_object('cerrada', false, 'motivo', 'la orden ya estaba en estado ' || v_orden.estado);
    end if;

    select * into v_cuenta from public.cuentas_simulacion where id = v_orden.cuenta_id for update;

    -- Una acción se cierra por unidades enteras, hacia abajo; y la
    -- fracción REAL (la de esas unidades) es la que reparte el margen.
    if exists (select 1 from public.activos where id = v_orden.activo_id and clase = 'accion') then
        v_cant := floor(v_orden.cantidad * p_fraccion);
        if v_cant < 1 or v_cant >= v_orden.cantidad then
            raise exception 'Con % acciones no se puede cerrar el % %% en unidades enteras: ciérrala entera o elige otra fracción.',
                  v_orden.cantidad, round(p_fraccion * 100) using errcode = 'P0001';
        end if;
    else
        v_cant := round(v_orden.cantidad * p_fraccion, 8);
    end if;
    v_margen := round(v_orden.margen_comprometido * v_cant / v_orden.cantidad, 2);
    if v_cant <= 0 or v_margen <= 0 or v_orden.margen_comprometido - v_margen <= 0 then
        raise exception 'La posición es demasiado pequeña para cerrarla en parte: ciérrala entera.'
              using errcode = 'P0001';
    end if;

    v_pnl := round(v_cant * (v_precio - v_orden.precio_entrada), 2);
    -- Mismo clamp que el cierre completo: esa parte no pierde más que su margen.
    if v_pnl < -v_margen then
        v_pnl := -v_margen;
    end if;

    update public.ordenes
       set cantidad = cantidad - v_cant,
           margen_comprometido = margen_comprometido - v_margen,
           pnl_parciales = pnl_parciales + v_pnl,
           parcial_hecho = true,
           actualizado_en = now()
     where id = p_orden_id;

    insert into public.ordenes_parciales
        (orden_id, cantidad, precio, precio_observado, margen_liberado, pnl, motivo)
    values (p_orden_id, v_cant, v_precio, coalesce(p_observado, v_precio), v_margen, v_pnl, p_motivo);

    -- Los mismos DOS apuntes que un cierre completo, por la parte cerrada.
    perform public.fn_registrar_movimiento(
        v_orden.cuenta_id, p_orden_id, 'liberacion_margen', v_margen, -v_margen);
    perform public.fn_registrar_movimiento(
        v_orden.cuenta_id, p_orden_id, 'resultado_operacion', v_pnl, 0);

    select simbolo into v_simbolo from public.activos where id = v_orden.activo_id;
    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (v_cuenta.usuario_id, 'orden_cerrada',
            format('%s: cierre parcial del %s %% por %s: %s $', v_simbolo,
                   round(p_fraccion * 100), p_motivo, v_pnl),
            jsonb_build_object('orden_id', p_orden_id, 'cuenta_id', v_orden.cuenta_id,
                               'simbolo', v_simbolo, 'motivo', p_motivo, 'parcial', true,
                               'fraccion', round(v_cant / v_orden.cantidad, 4), 'precio', v_precio, 'pnl', v_pnl));

    perform public.rpc_evaluar_fase(v_orden.cuenta_id);
    perform public.rpc_evaluar_game_over(v_orden.cuenta_id);

    return jsonb_build_object('cerrada', true, 'parcial', true, 'cantidad_cerrada', v_cant,
                              'margen_liberado', v_margen, 'pnl', v_pnl,
                              'cantidad_restante', v_orden.cantidad - v_cant);
end;
$$;

create or replace function public.fn_monitorear_ordenes()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_orden    record;
    v_liq      int := 0;
    v_sl       int := 0;
    v_tp       int := 0;
    v_huecos   int := 0;
    v_vistas   int := 0;
    v_hueco    boolean;
    v_venta    numeric;
begin
    for v_orden in select * from public.v_ordenes_abiertas_monitor
    loop
        v_vistas := v_vistas + 1;
        -- 0034: una posición larga se cierra VENDIENDO: los niveles se
        -- comparan con el precio de venta, no con el intermedio.
        v_venta := public.fn_precio_venta(v_orden.activo_id, v_orden.precio_vivo);

        if v_venta <= v_orden.precio_liquidacion then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.precio_liquidacion, 'liquidacion', v_orden.precio_vivo);
            v_liq := v_liq + 1;

        elsif v_venta <= v_orden.sl then
            -- M3': con el mercado cerrado entre medias no había a quién
            -- venderle al nivel del stop. Se sale al precio del hueco.
            v_hueco := public.fn_hubo_cierre(
                public.fn_mercado_de_clase(v_orden.clase),
                coalesce(v_orden.ultima_observacion_en, v_orden.fecha_entrada),
                v_orden.ultimo_precio_en);
            if v_hueco then
                perform public.rpc_cerrar_orden(
                    v_orden.id, v_venta, 'sl', v_orden.precio_vivo);
                update public.ordenes set cierre_por_hueco = true where id = v_orden.id;
                v_huecos := v_huecos + 1;
            else
                perform public.rpc_cerrar_orden(
                    v_orden.id, v_orden.sl, 'sl', v_orden.precio_vivo);
            end if;
            v_sl := v_sl + 1;

        elsif v_venta >= v_orden.tp then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.tp, 'tp', v_orden.precio_vivo);
            v_tp := v_tp + 1;

        else
            -- 0033: sigue abierta. Se anota con qué precio se vio, para que
            -- la próxima pasada sepa si entre medias cerró el mercado.
            update public.ordenes
               set ultima_observacion_en = v_orden.ultimo_precio_en
             where id = v_orden.id
               and ultima_observacion_en is distinct from v_orden.ultimo_precio_en;
        end if;
    end loop;

    return jsonb_build_object('evaluadas', v_vistas, 'liquidacion', v_liq,
                              'sl', v_sl, 'tp', v_tp, 'sl_por_hueco', v_huecos);
end;
$$;

create or replace function public.fn_agente_tomas_parciales(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag    public.agentes;
    v_tp    jsonb;
    v_o     record;
    v_nivel numeric;
    v_res   jsonb;
    v_n     int := 0;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    v_tp := public.fn_parametros_agente(v_ag) -> 'tp_parcial';
    if v_tp is null or jsonb_typeof(v_tp) <> 'object' then
        return 0;
    end if;

    -- Solo con precio fresco (la vista del monitor ya aplica M4).
    for v_o in select m.*, o.parcial_hecho
                 from public.v_ordenes_abiertas_monitor m
                 join public.ordenes o on o.id = m.id
                 join public.cuentas_simulacion c on c.id = m.cuenta_id
                where c.agente_id = p_agente_id and not o.parcial_hecho
                order by m.id
    loop
        v_nivel := v_o.precio_entrada + (v_tp ->> 'recorrido')::numeric * (v_o.tp - v_o.precio_entrada);
        -- 0034: se compara con el precio de venta, como el monitor.
        continue when public.fn_precio_venta(v_o.activo_id, v_o.precio_vivo) < v_nivel
                   or public.fn_precio_venta(v_o.activo_id, v_o.precio_vivo) >= v_o.tp;

        -- Al NIVEL, no al precio observado (misma disciplina que M3).
        v_res := public.fn_cerrar_parcial(v_o.id, (v_tp ->> 'fraccion')::numeric, v_nivel,
                                          'tp_parcial', v_o.precio_vivo);
        continue when not coalesce((v_res ->> 'cerrada')::boolean, false);

        if coalesce((v_tp ->> 'mover_stop')::boolean, false) then
            -- «Stop a la entrada»: 5 puntos básicos por debajo, porque el
            -- CHECK de `ordenes` exige sl < entrada (ver cabecera).
            update public.ordenes
               set sl_original = coalesce(sl_original, sl),
                   sl = round(precio_entrada * 0.9995, 8),
                   actualizado_en = now()
             where id = v_o.id and sl < round(precio_entrada * 0.9995, 8);
        end if;

        insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
        values (p_agente_id, 'parcial', v_o.id, v_tp,
                jsonb_build_object('precio_parcial', v_nivel,
                                   'cantidad_cerrada', v_res -> 'cantidad_cerrada',
                                   'pnl_parcial', v_res -> 'pnl'));
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$;
