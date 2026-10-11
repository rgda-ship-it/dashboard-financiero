-- ─────────────────────────────────────────────────────────────────────
-- 0037 — Agente experimental «Tendencia cripto» (D24, doc 07)
--        (2026-10-11).
--
-- La única estrategia que pasó el laboratorio (doc 06 §3.7): ruptura del
-- máximo de 20 días sobre la media de 200, stop inicial a 2 ATR que sube
-- con el precio (3 ATR bajo el mejor cierre), salida al cerrar bajo el
-- mínimo de 10 días y SIN objetivo. Exactamente los parámetros probados:
-- cambiarlos invalida lo medido.
--
-- Es un agente de un tipo nuevo (`tipo = 'estrategia'`): sin meta diaria,
-- riesgo fijo del 1 % por operación, una decisión al día por activo con
-- la vela diaria cerrada, y criterio de retirada fijado de antemano. Los
-- tres agentes con metas (grupo de control) no cambian: sus bucles solo
-- recorren `tipo = 'metas'`.
--
-- Qué añade:
--   1. `agentes.tipo`; `objetivo_diario_pct` solo en los agentes con metas.
--   2. Órdenes sin objetivo (`tp` opcional); sin objetivo, el stop puede
--      quedar por encima de la entrada (stop que sigue). Motivo de cierre
--      `regla`, que vende a mercado al precio de venta.
--   3. `fn_subir_stop`: el stop solo sube, y nunca por encima del precio
--      de venta (la herramienta «trailing stop» que el backlog preveía).
--   4. `fn_abrir_orden_estrategia`: abre con el stop de la estrategia, sin
--      objetivo, a 1× y con el 1 % de riesgo. Mismos guardarraíles G2, G3
--      y G6 (trigger) que el resto; G5 aquí es «precio fresco y activo
--      activo», porque la señal es la vela, no la del motor.
--   5. `fn_indicadores_tendencia`: SMA 200, ATR 14 (Wilder, con los días
--      con rango real), máximo de 20 y mínimo de 10, desde
--      `precios_diarios`.
--   6. `fn_decidir_tendencia` y `fn_ciclo_estrategias`: cada hora de 01:20
--      a 07:20 UTC; cada activo se decide una vez al día, en la primera
--      pasada en que el ETL ya escribió su vela de ayer. Registro en
--      `agente_decisiones_diarias`.
--   7. `v_agentes_estrategia` (expectativa en R y criterio del doc 07 §6)
--      y la pausa automática al cumplirse el criterio de retirada.
--   8. El agente «Tendencia cripto», en pausa, con 500 $.
-- ─────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════
-- 1. Tipo de agente
-- ═════════════════════════════════════════════════════════════════════
alter table public.agentes
    add column tipo text not null default 'metas' check (tipo in ('metas', 'estrategia'));

alter table public.agentes alter column objetivo_diario_pct drop not null;
alter table public.agentes
    add constraint agentes_meta_segun_tipo
    check ((tipo = 'metas') = (objetivo_diario_pct is not null));

comment on column public.agentes.tipo is
  'metas: persigue una meta diaria (Prudencia, Cadencia, Audacia; grupo de control). estrategia: aplica una estrategia validada en el laboratorio, sin meta diaria (doc 07, D24).';


-- ═════════════════════════════════════════════════════════════════════
-- 2. Órdenes sin objetivo, stop que sigue y cierre por regla
-- ═════════════════════════════════════════════════════════════════════
alter table public.ordenes alter column tp drop not null;
alter table public.ordenes drop constraint orden_niveles_coherentes;
-- Con objetivo, lo de siempre. Sin objetivo (estrategia de tendencia),
-- el stop puede subir por encima de la entrada: es lo que protege la
-- ganancia. La entrada con el stop por debajo la impone quien abre.
alter table public.ordenes add constraint orden_niveles_coherentes
    check ((tp is not null and tp > precio_entrada and sl < precio_entrada)
           or (tp is null and sl > 0));

alter table public.ordenes drop constraint ordenes_motivo_cierre_check;
alter table public.ordenes add constraint ordenes_motivo_cierre_check
    check (motivo_cierre in ('tp', 'sl', 'liquidacion', 'manual', 'caducidad', 'rotacion', 'deterioro', 'regla'));

comment on column public.ordenes.tp is
  'Objetivo. NULL en las órdenes de una estrategia sin objetivo (tendencia, 0037): salen por stop o por regla.';

-- rpc_cerrar_orden: `regla` es una salida a mercado, como `deterioro`.
create or replace function public.rpc_cerrar_orden(
    p_orden_id bigint, p_precio_salida numeric, p_motivo text, p_precio_observado numeric default null)
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

    -- 0034: una salida a mercado (a mano, por deterioro, por rotación y,
    -- desde la 0037, por regla) vende al precio de VENTA: el intermedio
    -- menos medio spread. Las salidas por nivel (stop, objetivo,
    -- liquidación) ya traen el precio de ejecución.
    v_ejec := case when p_motivo in ('manual', 'deterioro', 'rotacion', 'regla')
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

-- (rpc_cerrar_orden solo lo ejecuta el servidor desde la 0011: ningún
-- usuario puede cerrar «por regla».)


-- ═════════════════════════════════════════════════════════════════════
-- 3. Subir el stop
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_subir_stop(p_orden_id bigint, p_nuevo_sl numeric, p_motivo jsonb default '{}'::jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_o     public.ordenes;
    v_venta numeric;
begin
    select * into v_o from public.ordenes where id = p_orden_id for update;
    if not found or v_o.estado <> 'abierta' then
        return false;
    end if;
    -- Solo sube.
    if p_nuevo_sl is null or round(p_nuevo_sl, 8) <= v_o.sl then
        return false;
    end if;
    -- Nunca por encima de lo que hoy se cobraría vendiendo: eso no es un
    -- stop, es un cierre, y lo decide quien llama.
    select public.fn_precio_venta(a.id, a.ultimo_precio) into v_venta
      from public.activos a where a.id = v_o.activo_id;
    if v_venta is null or round(p_nuevo_sl, 8) >= v_venta then
        raise exception 'El stop nuevo (%) no queda por debajo del precio de venta (%).',
              round(p_nuevo_sl, 8), v_venta using errcode = 'P0001';
    end if;

    update public.ordenes
       set sl = round(p_nuevo_sl, 8),
           sl_original = coalesce(sl_original, v_o.sl),
           racional = coalesce(racional, '{}'::jsonb)
                      || jsonb_build_object('stops',
                             coalesce(racional -> 'stops', '[]'::jsonb)
                             || jsonb_build_array(jsonb_build_object('en', now(), 'de', v_o.sl,
                                                                     'a', round(p_nuevo_sl, 8))
                                                  || coalesce(p_motivo, '{}'::jsonb))),
           actualizado_en = now()
     where id = p_orden_id;
    return true;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 4. Abrir con el stop de la estrategia, sin objetivo
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_abrir_orden_estrategia(
    p_cuenta_id bigint, p_activo_id bigint, p_sl numeric, p_riesgo_pct numeric, p_racional jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuenta   public.cuentas_simulacion;
    v_a        public.activos;
    v_precio   numeric;
    v_equity   numeric;
    v_cantidad numeric;
    v_margen   numeric;
    v_tope_g3  numeric;
    v_orden    bigint;
    v_sl       numeric := round(p_sl, 8);
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found or v_cuenta.agente_id is null then
        raise exception 'La cuenta % no es de un agente.', p_cuenta_id using errcode = '42501';
    end if;
    if v_cuenta.estado <> 'activa' then
        raise exception 'La cuenta está en estado «%»: no admite operaciones nuevas.', v_cuenta.estado
              using errcode = 'P0001';
    end if;

    -- G5 de una estrategia de velas: activo activo y precio fresco.
    select * into v_a from public.activos where id = p_activo_id;
    if not found or v_a.estado <> 'activo' then
        raise exception 'El activo % no está activo.', coalesce(v_a.simbolo, p_activo_id::text) using errcode = 'P0001';
    end if;
    if v_a.ultimo_precio is null
       or v_a.ultimo_precio_en < now() - make_interval(mins => public.fn_frescura_precio_min(v_a.clase)) then
        raise exception 'El precio de % no es fresco.', v_a.simbolo using errcode = 'P0001';
    end if;
    if exists (select 1 from public.ordenes
                where cuenta_id = p_cuenta_id and activo_id = p_activo_id and estado = 'abierta') then
        raise exception 'Ya tienes una posición abierta en %.', v_a.simbolo using errcode = 'P0001';
    end if;

    v_precio := public.fn_precio_compra(p_activo_id, v_a.ultimo_precio);
    if v_sl is null or v_sl <= 0 or v_sl >= v_precio then
        raise exception 'El stop (%) tiene que quedar por debajo del precio de compra (%).', v_sl, v_precio
              using errcode = 'P0001';
    end if;

    -- G2
    if p_riesgo_pct is null or p_riesgo_pct <= 0 or p_riesgo_pct > 10 then
        raise exception 'El riesgo por operación debe estar entre 0 y 10 %% del equity. Recibido: %', p_riesgo_pct
              using errcode = 'P0001';
    end if;
    v_equity := public.fn_equity(p_cuenta_id);
    if v_equity < 10 then
        raise exception 'Equity de % $: por debajo del margen mínimo de 10 $ no se abre nada.', round(v_equity, 2)
              using errcode = 'P0001';
    end if;

    -- Tamaño: el riesgo declarado, a 1× (sin apalancamiento: es lo que se
    -- midió en el laboratorio). Si el saldo libre no llega, se compra lo
    -- que cabe: el riesgo queda por debajo del declarado, nunca por encima.
    v_cantidad := trunc(v_equity * p_riesgo_pct / 100 / (v_precio - v_sl), 8);
    v_tope_g3  := least(v_cuenta.saldo_disponible,
                        v_equity * v_cuenta.margen_comprometido_max_pct / 100 - v_cuenta.saldo_bloqueado);
    if ceil(v_cantidad * v_precio * 100) / 100 > v_tope_g3 then
        v_cantidad := trunc(greatest(v_tope_g3 - 0.01, 0) / v_precio, 8);
    end if;
    v_margen := ceil(v_cantidad * v_precio * 100) / 100;
    -- El mismo mínimo que los agentes con metas: por debajo de 10 $ no se
    -- abre (doc 04, Sprint 6).
    if v_cantidad <= 0 or v_margen < 10 then
        raise exception 'Posición de % $ en %: por debajo del mínimo de 10 $.', v_margen, v_a.simbolo
              using errcode = 'P0001';
    end if;
    if v_cantidad * (v_precio - v_sl) > v_equity * 10 / 100 + 0.01 then
        raise exception 'El riesgo de esta orden supera el 10 %% del equity.' using errcode = 'P0001';
    end if;

    -- G6 lo impone el trigger `ordenes_g6_riesgo_abierto`.
    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, sl_original, precio_liquidacion, racional)
    values (p_cuenta_id, p_activo_id, null, 'agente', v_precio, now(),
            v_cantidad, 1, v_margen, null, v_sl, v_sl, 0, p_racional)
    returning id into v_orden;

    perform public.fn_registrar_movimiento(p_cuenta_id, v_orden, 'bloqueo_margen', -v_margen, v_margen);

    return jsonb_build_object('orden_id', v_orden, 'simbolo', v_a.simbolo, 'cantidad', v_cantidad,
                              'precio_entrada', v_precio, 'sl', v_sl, 'margen', v_margen,
                              'riesgo', round(v_cantidad * (v_precio - v_sl), 2),
                              'riesgo_pct', round(v_cantidad * (v_precio - v_sl) * 100 / v_equity, 3));
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 5. Indicadores de la estrategia, desde las velas diarias
-- ═════════════════════════════════════════════════════════════════════
-- Mismas definiciones que `laboratorio/estrategias.py` (Tendencia):
--   sma          media de los últimos 200 cierres, incluido el del día
--   max_ruptura  máximo de los 20 días ANTERIORES (sin contar el día)
--   min_salida   mínimo de los 10 días anteriores
--   atr          ATR 14 de Wilder (como pandas-ta). En cripto solo los
--                últimos ~30 días tienen máximo y mínimo reales: se
--                siembra con la media de los 14 primeros rangos y se
--                suaviza con los demás. Aproximación aceptada (doc 07 §3).
-- Un dato que falta devuelve null en su campo: la decisión no lo inventa.
create function public.fn_indicadores_tendencia(p_activo_id bigint, p_fecha date, p_p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
    v_sma_n  int := coalesce((p_p ->> 'sma_fondo')::int, 200);
    v_rup    int := coalesce((p_p ->> 'ruptura')::int, 20);
    v_sal    int := coalesce((p_p ->> 'salida')::int, 10);
    v_atr_n  int := coalesce((p_p ->> 'atr_periodo')::int, 14);
    v_cierre numeric;
    v_real   boolean;
    v_sma    numeric;
    v_n      int;
    v_max    numeric;
    v_nmax   int;
    v_min    numeric;
    v_nmin   int;
    v_atr    numeric;
    v_tr     numeric;
    v_suma   numeric := 0;
    v_k      int := 0;
    v_prev   numeric;
    v_r      record;
begin
    select cierre, rango_real into v_cierre, v_real
      from public.precios_diarios where activo_id = p_activo_id and fecha = p_fecha;
    if v_cierre is null then
        return jsonb_build_object('fecha', p_fecha, 'error', 'sin_vela');
    end if;

    select avg(cierre), count(*) into v_sma, v_n
      from (select cierre from public.precios_diarios
             where activo_id = p_activo_id and fecha <= p_fecha
             order by fecha desc limit v_sma_n) s;
    if v_n < v_sma_n then v_sma := null; end if;

    select max(maximo), count(*) filter (where rango_real and maximo is not null)
      into v_max, v_nmax
      from public.precios_diarios
     where activo_id = p_activo_id and fecha between p_fecha - v_rup and p_fecha - 1;
    if v_nmax < v_rup then v_max := null; end if;

    select min(minimo), count(*) filter (where rango_real and minimo is not null)
      into v_min, v_nmin
      from public.precios_diarios
     where activo_id = p_activo_id and fecha between p_fecha - v_sal and p_fecha - 1;
    if v_nmin < v_sal then v_min := null; end if;

    for v_r in select fecha, maximo, minimo, cierre, rango_real
                 from public.precios_diarios
                where activo_id = p_activo_id and fecha between p_fecha - 60 and p_fecha
                order by fecha
    loop
        if v_r.rango_real and v_r.maximo is not null and v_r.minimo is not null and v_prev is not null then
            v_tr := greatest(v_r.maximo - v_r.minimo, abs(v_r.maximo - v_prev), abs(v_r.minimo - v_prev));
            v_k := v_k + 1;
            if v_k <= v_atr_n then
                v_suma := v_suma + v_tr;
                if v_k = v_atr_n then v_atr := v_suma / v_atr_n; end if;
            else
                v_atr := (v_atr * (v_atr_n - 1) + v_tr) / v_atr_n;
            end if;
        end if;
        v_prev := v_r.cierre;
    end loop;
    if not coalesce(v_real, false) then v_atr := null; end if;

    return jsonb_build_object('fecha', p_fecha, 'cierre', v_cierre,
                              'sma', round(v_sma, 8), 'atr', round(v_atr, 8),
                              'max_ruptura', v_max, 'min_salida', v_min,
                              'rangos', v_k);
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 6. Decisión diaria
-- ═════════════════════════════════════════════════════════════════════
create table public.agente_decisiones_diarias (
    agente_id   bigint not null references public.agentes(id) on delete cascade,
    activo_id   bigint not null references public.activos(id) on delete cascade,
    -- La vela con la que se decidió (la de ayer, en UTC).
    fecha_vela  date not null,
    accion      text not null check (accion in (
                    'entrar', 'sin_senal', 'mantener', 'subir_stop', 'salir_regla',
                    'salir_stop', 'descartada', 'sin_datos', 'sin_vela', 'sin_precio')),
    orden_id    bigint references public.ordenes(id) on delete set null,
    datos       jsonb not null default '{}'::jsonb,
    decidido_en timestamptz not null default now(),
    primary key (agente_id, activo_id, fecha_vela)
);

comment on table public.agente_decisiones_diarias is
  'Una fila por agente de estrategia, activo y vela diaria (0037): qué decidió y con qué indicadores. La clave impide decidir dos veces sobre la misma vela.';

create function public.fn_decidir_tendencia(p_agente_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_cuenta  bigint;
    v_go      jsonb;
    v_hoy     date := (now() at time zone 'UTC')::date;
    v_ayer    date := (now() at time zone 'UTC')::date - 1;
    v_listo   timestamptz;
    v_ultima  boolean;
    v_a       record;
    v_o       public.ordenes;
    v_ind     jsonb;
    v_cierre  numeric;
    v_atr     numeric;
    v_venta   numeric;
    v_compra  numeric;
    v_mejor   numeric;
    v_nuevo   numeric;
    v_sl      numeric;
    v_cand    jsonb := '[]'::jsonb;
    v_c       jsonb;
    v_r       jsonb;
    v_cuenta_acciones jsonb := '{}'::jsonb;
begin
    select * into v_ag from public.agentes where id = p_agente_id for update;
    if not found or v_ag.tipo <> 'estrategia' then
        raise exception 'El agente % no es de estrategia.', p_agente_id using errcode = '22023';
    end if;
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    if v_cuenta is null then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'sin_cuenta');
    end if;

    v_go := public.rpc_evaluar_game_over(v_cuenta);
    if v_go ->> 'estado' = 'game_over' then
        if v_ag.estado <> 'game_over' then
            update public.agentes set estado = 'game_over', estado_previo = null, game_over_en = now()
             where id = p_agente_id;
        end if;
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'game_over');
    end if;
    if v_ag.estado <> 'activo' then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'agente_' || v_ag.estado);
    end if;

    v_p := public.fn_parametros_agente(v_ag);
    if v_p ->> 'regla' is distinct from 'tendencia' then
        raise exception 'Regla de estrategia desconocida: %', v_p ->> 'regla' using errcode = '22023';
    end if;
    -- La vela de ayer está cerrada cuando el ETL pasó por el activo después
    -- de medianoche con margen (el punto diario de las 00:00 de CoinGecko
    -- tarda en aparecer). En la última pasada del día, lo que falta queda
    -- registrado en vez de esperar para siempre.
    v_listo  := (v_hoy::timestamp at time zone 'UTC')
                + make_interval(mins => coalesce((v_p ->> 'margen_etl_min')::int, 60));
    v_ultima := now() >= (v_hoy::timestamp at time zone 'UTC')
                + make_interval(hours => coalesce((v_p ->> 'hora_limite_utc')::int, 7));

    for v_a in
        select a.* from public.activos a
         where a.estado = 'activo'
           and a.clase in (select jsonb_array_elements_text(v_p -> 'clases_admitidas'))
         order by a.simbolo
    loop
        continue when exists (select 1 from public.agente_decisiones_diarias
                               where agente_id = p_agente_id and activo_id = v_a.id and fecha_vela = v_ayer);

        if v_a.ultimo_etl_en is null or v_a.ultimo_etl_en < v_listo
           or not exists (select 1 from public.precios_diarios where activo_id = v_a.id and fecha = v_ayer) then
            if v_ultima then
                insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
                values (p_agente_id, v_a.id, v_ayer, 'sin_vela',
                        jsonb_build_object('ultimo_etl_en', v_a.ultimo_etl_en));
            end if;
            continue;
        end if;
        if v_a.ultimo_precio is null
           or v_a.ultimo_precio_en < now() - make_interval(mins => public.fn_frescura_precio_min(v_a.clase)) then
            if v_ultima then
                insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
                values (p_agente_id, v_a.id, v_ayer, 'sin_precio',
                        jsonb_build_object('ultimo_precio_en', v_a.ultimo_precio_en));
            end if;
            continue;
        end if;

        v_ind    := public.fn_indicadores_tendencia(v_a.id, v_ayer, v_p);
        v_cierre := (v_ind ->> 'cierre')::numeric;
        v_atr    := (v_ind ->> 'atr')::numeric;
        v_venta  := public.fn_precio_venta(v_a.id, v_a.ultimo_precio);
        v_compra := public.fn_precio_compra(v_a.id, v_a.ultimo_precio);

        select * into v_o from public.ordenes
         where cuenta_id = v_cuenta and activo_id = v_a.id and estado = 'abierta';

        if found then
            -- ── Gestionar lo abierto ──────────────────────────────────
            if (v_ind ->> 'min_salida') is not null and v_cierre < (v_ind ->> 'min_salida')::numeric then
                -- Cerró bajo el mínimo de 10 días: se vende a mercado.
                v_r := public.rpc_cerrar_orden(v_o.id, v_a.ultimo_precio, 'regla', v_a.ultimo_precio);
                insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
                values (p_agente_id, v_a.id, v_ayer, 'salir_regla', v_o.id, v_ind || jsonb_build_object('cierre_orden', v_r));
                continue;
            end if;

            select max(cierre) into v_mejor from public.precios_diarios
             where activo_id = v_a.id
               and fecha between (v_o.fecha_entrada at time zone 'UTC')::date and v_ayer;
            v_nuevo := case when v_mejor is not null and v_atr is not null
                            then round(v_mejor - (v_p ->> 'sigue_atr')::numeric * v_atr, 8) end;

            if v_nuevo is not null and v_nuevo > v_o.sl then
                if v_nuevo >= v_venta then
                    -- El stop que toca ya está por encima del precio: el
                    -- laboratorio sale a la apertura (hueco). Aquí, ahora.
                    v_r := public.rpc_cerrar_orden(v_o.id, v_venta, 'sl', v_a.ultimo_precio);
                    update public.ordenes set cierre_por_hueco = true where id = v_o.id;
                    insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
                    values (p_agente_id, v_a.id, v_ayer, 'salir_stop', v_o.id,
                            v_ind || jsonb_build_object('mejor_cierre', v_mejor, 'stop', v_nuevo, 'cierre_orden', v_r));
                else
                    perform public.fn_subir_stop(v_o.id, v_nuevo,
                                                 jsonb_build_object('mejor_cierre', v_mejor, 'atr', v_atr));
                    insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
                    values (p_agente_id, v_a.id, v_ayer, 'subir_stop', v_o.id,
                            v_ind || jsonb_build_object('mejor_cierre', v_mejor, 'de', v_o.sl, 'a', v_nuevo));
                end if;
            else
                insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
                values (p_agente_id, v_a.id, v_ayer, 'mantener', v_o.id,
                        v_ind || jsonb_build_object('mejor_cierre', v_mejor, 'stop', v_o.sl));
            end if;
            continue;
        end if;

        -- ── Buscar entrada ────────────────────────────────────────────
        if (v_ind ->> 'sma') is null or v_atr is null or (v_ind ->> 'max_ruptura') is null then
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
            values (p_agente_id, v_a.id, v_ayer, 'sin_datos', v_ind);
            continue;
        end if;
        if not (v_cierre > (v_ind ->> 'sma')::numeric and v_cierre > (v_ind ->> 'max_ruptura')::numeric) then
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
            values (p_agente_id, v_a.id, v_ayer, 'sin_senal', v_ind);
            continue;
        end if;
        v_sl := round(v_cierre - (v_p ->> 'stop_atr')::numeric * v_atr, 8);
        -- Como en el laboratorio: si ya abre por debajo del stop, la
        -- operación no existe.
        if not (v_venta > v_sl and v_compra > v_sl) then
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
            values (p_agente_id, v_a.id, v_ayer, 'descartada',
                    v_ind || jsonb_build_object('motivo', 'abre_bajo_el_stop', 'sl', v_sl, 'precio_venta', v_venta));
            continue;
        end if;
        v_cand := v_cand || jsonb_build_object(
            'activo_id', v_a.id, 'simbolo', v_a.simbolo, 'sl', v_sl,
            'fuerza', round((v_cierre - (v_ind ->> 'max_ruptura')::numeric) / v_atr, 4),
            'indicadores', v_ind);
    end loop;

    -- ── Abrir: primero la ruptura más fuerte (medida en ATR) ──────────
    -- Si G6 (riesgo abierto) o el saldo no dejan, queda registrada como
    -- descartada con el motivo.
    for v_c in select c from jsonb_array_elements(v_cand) c order by (c ->> 'fuerza')::numeric desc
    loop
        begin
            v_r := public.fn_abrir_orden_estrategia(
                v_cuenta, (v_c ->> 'activo_id')::bigint, (v_c ->> 'sl')::numeric,
                (v_p ->> 'riesgo_pct_operacion')::numeric,
                jsonb_build_object('regla', 'tendencia', 'version_estrategia', v_ag.version_estrategia,
                                   'parametros', v_p - 'clases_admitidas',
                                   'vela', v_ayer, 'fuerza', v_c -> 'fuerza',
                                   'indicadores', v_c -> 'indicadores',
                                   'equity', public.fn_equity(v_cuenta)));
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
            values (p_agente_id, (v_c ->> 'activo_id')::bigint, v_ayer, 'entrar', (v_r ->> 'orden_id')::bigint,
                    (v_c -> 'indicadores') || jsonb_build_object('orden', v_r, 'fuerza', v_c -> 'fuerza'));
        exception when others then
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
            values (p_agente_id, (v_c ->> 'activo_id')::bigint, v_ayer, 'descartada',
                    (v_c -> 'indicadores') || jsonb_build_object('motivo', sqlerrm, 'sl', v_c -> 'sl',
                                                                 'fuerza', v_c -> 'fuerza'));
        end;
    end loop;

    select coalesce(jsonb_object_agg(accion, n), '{}'::jsonb) into v_cuenta_acciones
      from (select accion, count(*) as n from public.agente_decisiones_diarias
             where agente_id = p_agente_id and fecha_vela = v_ayer group by accion) s;
    return jsonb_build_object('agente', v_ag.nombre, 'vela', v_ayer, 'acciones', v_cuenta_acciones);
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 7. Medidas, criterio de retirada (doc 07 §6) y ciclo
-- ═════════════════════════════════════════════════════════════════════
-- R de cada orden cerrada: resultado ÷ riesgo inicial (con el stop con el
-- que se abrió, `sl_original`).
create view public.v_agentes_estrategia
with (security_invoker = true) as
    select g.id as agente_id, g.nombre, g.estado, g.estrategia ->> 'regla' as regla,
           ce.id as cuenta_id, ce.equity, ce.drawdown_pct, ce.posiciones_abiertas,
           coalesce(o.cerradas, 0) as cerradas,
           o.expectativa_r, o.r_total, o.aciertos_pct, o.mejor_r, o.peor_r,
           coalesce(o.en_regla, 0) as en_regla, coalesce(o.en_sl, 0) as en_sl,
           o.dias_medios,
           case
               when coalesce(ce.drawdown_pct, 0) <= -15 then 'caida'
               when coalesce(o.cerradas, 0) < 5 then 'arranque'
               when o.cerradas < 30 then 'en_prueba'
               when o.expectativa_r < 0 then 'retirar'
               when o.expectativa_r <= 0.10 and o.cerradas < 60 then 'observacion'
               when o.expectativa_r <= 0.10 then 'retirar'
               else 'validado'
           end as criterio,
           (select max(fecha_vela) from public.agente_decisiones_diarias d where d.agente_id = g.id) as ultima_vela
      from public.agentes g
      left join public.v_cuentas_equity ce on ce.id = public.fn_cuenta_agente(g.id)
      left join lateral (
          select count(*) as cerradas,
                 round(avg(r), 4) as expectativa_r,
                 round(sum(r), 2) as r_total,
                 round(100.0 * count(*) filter (where r > 0) / nullif(count(*), 0), 1) as aciertos_pct,
                 round(max(r), 2) as mejor_r, round(min(r), 2) as peor_r,
                 count(*) filter (where motivo_cierre = 'regla') as en_regla,
                 count(*) filter (where motivo_cierre in ('sl', 'liquidacion')) as en_sl,
                 round(avg(extract(epoch from fecha_salida - fecha_entrada) / 86400)::numeric, 1) as dias_medios
            from (select x.*, x.pnl_bruto / nullif(x.cantidad * (x.precio_entrada - coalesce(x.sl_original, x.sl)), 0) as r
                    from public.ordenes x
                   where x.cuenta_id = ce.id and x.estado = 'cerrada') t
      ) o on true
     where g.tipo = 'estrategia';

comment on view public.v_agentes_estrategia is
  'Agentes de estrategia (0037): expectativa en R y criterio del doc 07 §6. arranque (< 5 cerradas), en_prueba (< 30), observacion (0..+0,10 R hasta 60), validado (> +0,10 R), retirar, caida (drawdown ≤ −15 %).';

create function public.fn_ciclo_estrategias()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag   record;
    v_out  jsonb := '[]'::jsonb;
    v_err  text;
    v_cod  text;
    v_ctx  text;
begin
    for v_ag in select g.id, g.nombre, e.criterio, e.cerradas, e.expectativa_r, e.drawdown_pct
                  from public.agentes g left join public.v_agentes_estrategia e on e.agente_id = g.id
                 where g.tipo = 'estrategia' order by g.id
    loop
        begin
            -- El criterio de retirada se fijó de antemano: se aplica solo.
            if v_ag.criterio in ('retirar', 'caida')
               and exists (select 1 from public.agentes where id = v_ag.id and estado = 'activo') then
                update public.agentes set estado = 'pausado', estado_previo = 'activo' where id = v_ag.id;
                insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
                values (v_ag.id, 'agente',
                        v_ag.nombre || case when v_ag.criterio = 'caida'
                                            then ' queda en pausa: la caída desde el máximo pasó del 15 %'
                                            else ' queda en pausa: cumple el criterio de retirada' end,
                        jsonb_build_object('criterio', v_ag.criterio, 'cerradas', v_ag.cerradas,
                                           'expectativa_r', v_ag.expectativa_r, 'drawdown_pct', v_ag.drawdown_pct));
            end if;
            v_out := v_out || public.fn_decidir_tendencia(v_ag.id);
        exception when others then
            get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
            v_out := v_out || jsonb_build_object('agente_id', v_ag.id, 'error', v_err);
            perform public.fn_registrar_fallo(v_ag.id, 'decisión diaria', v_err, v_cod, v_ctx);
        end;
    end loop;
    return v_out;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- Los bucles de los agentes con metas solo recorren `tipo = 'metas'`
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_ciclo_agentes()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id   bigint;
    v_out  jsonb := '[]'::jsonb;
    v_err  text;
    v_cod  text;
    v_ctx  text;
    v_ultimo_ok timestamptz;
begin
    -- Los pasos globales, protegidos: si fallan, se avisa y el ciclo de
    -- cada agente sigue (con los precios y las decisiones de la vuelta
    -- anterior).
    begin
        perform public.fn_agentes_observar_precios();
    exception when others then
        get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
        perform public.fn_registrar_fallo(null, 'observar precios', v_err, v_cod, v_ctx);
        raise warning 'observar precios falló: %', v_err;
    end;
    begin
        perform public.fn_resolver_decisiones();
    exception when others then
        get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
        perform public.fn_registrar_fallo(null, 'resolver decisiones', v_err, v_cod, v_ctx);
        raise warning 'resolver decisiones falló: %', v_err;
    end;

    -- 0037: los agentes de estrategia deciden una vez al día en su propio
    -- ciclo (`fn_ciclo_estrategias`).
    for v_id in select id from public.agentes where tipo = 'metas' order by id
    loop
        begin
            v_out := v_out || public.fn_ciclo_agente(v_id);

            -- Si su último aviso de fallo es posterior a su última
            -- recuperación, decir que vuelve a funcionar.
            select max(creado_en) into v_ultimo_ok from public.eventos_sistema
             where agente_id = v_id and tipo = 'agente' and datos ->> 'recuperado' = 'true';
            if exists (select 1 from public.eventos_sistema
                        where agente_id = v_id and tipo = 'fallo'
                          and creado_en > coalesce(v_ultimo_ok, '-infinity'::timestamptz)) then
                insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
                select v_id, 'agente', nombre || ' vuelve a completar su ciclo',
                       jsonb_build_object('recuperado', true)
                  from public.agentes where id = v_id;
            end if;
        exception when others then
            get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
            v_out := v_out || jsonb_build_object('agente_id', v_id, 'error', v_err);
            perform public.fn_registrar_fallo(v_id, 'ciclo del agente', v_err, v_cod, v_ctx);
            raise warning 'ciclo del agente % falló: %', v_id, v_err;
        end;
    end loop;
    return v_out;
end;
$$;

create or replace function public.fn_corte_semanal(p_lunes date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_lunes date := coalesce(p_lunes,
                             date_trunc('week', (now() at time zone 'UTC')::date)::date - 7);
    v_id    bigint;
    v_out   jsonb := '[]'::jsonb;
begin
    if extract(isodow from v_lunes) <> 1 then
        raise exception 'El corte se hace por semanas ISO: % no es lunes', v_lunes using errcode = '22023';
    end if;
    -- 0037: el corte mide la meta semanal; los agentes de estrategia no tienen.
    for v_id in select id from public.agentes where tipo = 'metas' order by id
    loop
        begin
            v_out := v_out || public.fn_corte_semanal_agente(v_id, v_lunes);
        exception when others then
            v_out := v_out || jsonb_build_object('agente_id', v_id, 'error', sqlerrm);
            raise warning 'corte del agente % falló: %', v_id, sqlerrm;
        end;
    end loop;
    return v_out;
end;
$$;

create or replace function public.fn_autodiagnostico_agentes()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag  record;
    v_out jsonb := '{}'::jsonb;
begin
    -- 0037: el autodiagnóstico mira metas, objetivos y saldo atrapado; el
    -- agente de estrategia se juzga con su criterio (v_agentes_estrategia).
    for v_ag in select id, nombre from public.agentes
                 where estado <> 'game_over' and tipo = 'metas' order by id loop
        begin
            v_out := v_out || jsonb_build_object(v_ag.nombre, public.fn_autodiagnostico_agente(v_ag.id));
        exception when others then
            -- Un agente que falla no frena a los demás, y deja aviso (0025).
            insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
            values (v_ag.id, 'fallo', v_ag.nombre || ': el autodiagnóstico falló',
                    jsonb_build_object('error', sqlerrm, 'codigo', sqlstate));
        end;
    end loop;
    return v_out;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- El marcador muestra el tipo
-- ═════════════════════════════════════════════════════════════════════
create or replace view public.v_ranking_agentes
with (security_invoker = true) as
 SELECT a.id AS agente_id,
    a.nombre,
    a.objetivo_diario_pct,
    a.objetivo_final,
    a.estado,
    a.estado_previo,
    a.riesgo_reducido,
    a.version_estrategia,
    a.estrategia,
    a.game_over_en,
    ce.id AS cuenta_id,
    ce.saldo_inicial,
    ce.saldo_disponible,
    ce.saldo_bloqueado,
    ce.equity,
    ce.pnl_no_realizado,
    ce.drawdown_pct,
    ce.fase,
    ce.leverage_tope,
    ce.posiciones_abiertas,
    ce.margen_comprometido_pct,
    ce.estado AS estado_cuenta,
    ce.capital_maximo_alcanzado,
    ce.riesgo_pct_operacion,
    round(((ce.equity * (100)::numeric) / NULLIF(a.objetivo_final, (0)::numeric)), 4) AS pct_hacia_objetivo,
    r.racha,
    h.fecha AS hoy_fecha,
    h.objetivo_importe AS hoy_objetivo,
    h.cumplido AS hoy_cumplido,
    h.operable AS hoy_operable,
    h.ultima_decision,
    h.ultimo_ciclo_en,
    ( SELECT fn_pnl_realizado_dia(ce.id, ((now() AT TIME ZONE 'UTC'::text))::date) AS fn_pnl_realizado_dia) AS hoy_pnl,
    s.semana_iso AS ultima_semana,
    s.veredicto AS ultimo_veredicto,
    o.cerradas,
    o.en_tp,
    o.en_sl,
    a.tipo
   FROM (((((agentes a
     LEFT JOIN v_cuentas_equity ce ON ((ce.id = fn_cuenta_agente(a.id))))
     LEFT JOIN LATERAL ( SELECT count(*) AS racha
           FROM agente_dias d
          WHERE ((d.agente_id = a.id) AND d.operable AND (d.cerrado_en IS NOT NULL) AND (d.fecha > COALESCE(( SELECT max(d2.fecha) AS max
                   FROM agente_dias d2
                  WHERE ((d2.agente_id = a.id) AND d2.operable AND (d2.cerrado_en IS NOT NULL) AND (NOT d2.cumplido))), '-infinity'::date)))) r ON (true))
     LEFT JOIN agente_dias h ON (((h.agente_id = a.id) AND (h.fecha = ((now() AT TIME ZONE 'UTC'::text))::date))))
     LEFT JOIN LATERAL ( SELECT w.semana_iso,
            w.veredicto
           FROM agente_semanas w
          WHERE (w.agente_id = a.id)
          ORDER BY w.fecha_inicio DESC
         LIMIT 1) s ON (true))
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE (o_1.estado = 'cerrada'::text)) AS cerradas,
            count(*) FILTER (WHERE (o_1.motivo_cierre = 'tp'::text)) AS en_tp,
            count(*) FILTER (WHERE (o_1.motivo_cierre = ANY (ARRAY['sl'::text, 'liquidacion'::text]))) AS en_sl
           FROM ordenes o_1
          WHERE (o_1.cuenta_id = ce.id)) o ON (true));


-- ═════════════════════════════════════════════════════════════════════
-- 8. El agente
-- ═════════════════════════════════════════════════════════════════════
-- Parámetros de `Tendencia()` en laboratorio/estrategias.py. No se tocan
-- sin repetir laboratorio y robustez (doc 07 §2).
insert into public.agentes (nombre, tipo, objetivo_diario_pct, saldo_inicial, estado, estrategia)
values ('Tendencia cripto', 'estrategia', null, 500, 'pausado',
        jsonb_build_object(
            'regla', 'tendencia',
            'clases_admitidas', jsonb_build_array('cripto'),
            'riesgo_pct_operacion', 1.0,
            'sma_fondo', 200, 'ruptura', 20, 'salida', 10,
            'stop_atr', 2.0, 'sigue_atr', 3.0, 'atr_periodo', 14,
            'margen_etl_min', 60, 'hora_limite_utc', 7,
            -- Lo que lee fn_parametros_agente para sincronizar la cuenta.
            'max_posiciones_abiertas', 10, 'rr_minimo', 1.0,
            'apalancamiento_maximo_propio', 1.0,
            'salida_deterioro', false));

select public.fn_crear_cuenta_agente(id) from public.agentes where nombre = 'Tendencia cripto';


-- ═════════════════════════════════════════════════════════════════════
-- RLS, privilegios y programación
-- ═════════════════════════════════════════════════════════════════════
alter table public.agente_decisiones_diarias enable row level security;
create policy agente_decisiones_diarias_aprobados on public.agente_decisiones_diarias
    for select to authenticated using (public.es_usuario_aprobado());
revoke insert, update, delete on public.agente_decisiones_diarias from authenticated;
revoke all on public.agente_decisiones_diarias from anon;

revoke execute on function public.fn_subir_stop(bigint, numeric, jsonb)                          from public, anon, authenticated;
revoke execute on function public.fn_abrir_orden_estrategia(bigint, bigint, numeric, numeric, jsonb) from public, anon, authenticated;
revoke execute on function public.fn_indicadores_tendencia(bigint, date, jsonb)                  from public, anon, authenticated;
revoke execute on function public.fn_decidir_tendencia(bigint)                                   from public, anon, authenticated;
revoke execute on function public.fn_ciclo_estrategias()                                         from public, anon, authenticated;

-- Cada hora de 01:20 a 07:20 UTC: el ETL de cripto corre a los :07 y rota
-- las criptos sin posición, así que no todas tienen la vela de ayer en la
-- primera pasada (doc 07 §4.6).
do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('decision-estrategias', '20 1-7 * * *',
                                        'select public.fn_ciclo_estrategias()')$q$;
        raise notice 'decision-estrategias programado cada hora de 01:20 a 07:20 UTC';
    else
        raise notice 'pg_cron no disponible: la decisión diaria no queda programada (esperado en la CI)';
    end if;
end
$cron$;
