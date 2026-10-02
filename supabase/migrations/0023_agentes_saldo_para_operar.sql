-- ─────────────────────────────────────────────────────────────────────
-- 0023 — Los agentes operan con el saldo para operar (D17, 2026-10-02).
--
-- La 0022 cambió la cuenta del usuario: saldo para operar = equity × tope
-- de la fase, cada posición se lee por lo que consume (margen × tope) y el
-- saldo se reparte entre las sugerencias marcadas, ponderado por
-- apalancamiento. El dueño pidió lo mismo para los agentes, con tres
-- decisiones:
--
--   1. LOS TRES USAN HASTA EL 100 % DEL SALDO PARA OPERAR. Lo que limita un
--      perfil no es cuánto saldo toca, sino el riesgo que asume para
--      llegar a su meta (Prudencia 2 %, Cadencia 5 %, Audacia 7 % diario) y
--      su riesgo por operación. `fn_parametros_agente` impone 100 %.
--   2. CUÁNTAS MARCA LO DECIDE EL AGENTE, SEGÚN SU EXIGENCIA. Ordena sus
--      candidatas por rendimiento sobre el saldo (apalancamiento × recorrido
--      al objetivo) y prueba a marcar 1, 2, 3…; reparte el saldo libre
--      entre las marcadas en proporción a su apalancamiento, y se queda con
--        · el mayor número cuya ganancia en objetivo cubre lo que le falta
--          de la meta (le falta poco → reparte y arriesga menos en cada una),
--        · o, si ninguno la cubre, el de mayor ganancia potencial (mucha
--          exigencia → concentra en lo que más rinde, típicamente la 5×).
--      G4 desaparece también para los agentes. La cuarentena sigue siendo
--      «una posición a la vez».
--   3. ABRE TODAS SUS MARCADAS EN EL MISMO CICLO, cada una con su parte.
--
-- Determinista como siempre: con el mismo estado, la misma decisión.
--
-- Lo que se retira: el parámetro aprendido `reparto` (cupo | concentrado).
-- Las decisiones de reparto se siguen registrando y resolviendo, ahora con
-- el modo de la exigencia ('cubre_meta' | 'maxima_ganancia'), como
-- evidencia para un ajuste futuro. La rotación y la toma parcial no cambian,
-- salvo que se rota cuando el saldo está lleno (antes, sin «hueco»).
-- ─────────────────────────────────────────────────────────────────────

-- Las estrategias guardadas dicen lo que se aplica: margen 100 y reparto
-- por exigencia. El trigger de versiones sube su versión y el de
-- sincronización escribe el margen en sus cuentas.
update public.agentes
   set estrategia = estrategia || jsonb_build_object('margen_comprometido_max_pct', 100,
                                                     'reparto', 'exigencia');


-- ═════════════════════════════════════════════════════════════════════
-- Parámetros: margen 100 y reparto por exigencia, impuestos
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_parametros_agente(p_agente public.agentes)
returns jsonb
language plpgsql immutable
as $$
declare
    v jsonb;
begin
    v := jsonb_build_object(
            'riesgo_pct_operacion', 2.0,
            'max_posiciones_abiertas', 1,
            'rr_minimo', 1.5,
            'fuerzas_admitidas', jsonb_build_array('alta'),
            'clases_admitidas', jsonb_build_array('accion', 'cripto'),
            'niveles_origen_admitidos', jsonb_build_array('estructura', 'atr'),
            'apalancamiento_maximo_propio', 5.0,
            'margen_comprometido_max_pct', 100.0,
            'atr_pct_min', null,
            'atr_pct_max', null,
            'antiguedad_senal_max_min', 90,
            -- 0016: reparto por cupo, sin rotación y sin toma parcial, salvo
            -- que la estrategia diga otra cosa.
            -- 0023: el reparto lo decide la exigencia del día.
            'reparto', 'exigencia',
            'rotacion_umbral', null,
            'tp_parcial', null)
         || (p_agente.estrategia - 'practicas_adoptadas' - 'version' - 'modo_conservacion');

    -- 0023 (D17): los tres usan hasta el 100 % de su saldo para operar.
    -- Lo que diferencia a un perfil es su meta y su riesgo por operación,
    -- no cuánto saldo puede tocar. Se impone aquí, después de la mezcla,
    -- para que ninguna estrategia lo cambie.
    v := v || jsonb_build_object('margen_comprometido_max_pct', 100.0,
                                 'reparto', 'exigencia');

    if p_agente.riesgo_reducido then
        v := jsonb_set(v, '{riesgo_pct_operacion}',
                       to_jsonb(round((v ->> 'riesgo_pct_operacion')::numeric / 2, 2)));
    end if;
    if p_agente.estado = 'cuarentena'
       or (p_agente.estado = 'pausado' and p_agente.estado_previo = 'cuarentena') then
        v := v || jsonb_build_object('max_posiciones_abiertas', 1,
                                     'fuerzas_admitidas', jsonb_build_array('alta'));
    end if;
    return v;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Apertura sin G4 (la de la 0021 sin ese bloque)
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

    v_precio := coalesce(p_precio_entrada, v_senal.precio_actual);
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

-- ═════════════════════════════════════════════════════════════════════
-- La decisión: la de la 0016 con el reparto por exigencia
-- ═════════════════════════════════════════════════════════════════════
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
    if v_cuarentena and v_abiertas >= 1 then
        v_sin_hueco := 'sin_hueco';
    elsif v_libre < 10 then
        v_sin_hueco := 'saldo_lleno';
    end if;

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
               d.motivo as motivo_dim,
               least(coalesce(u.leverage_recomendado, v_tope), v_propio, v_tope) as lev_pedido
          from u
          cross join lateral public.fn_dimensionar_posicion(
               v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
               u.precio_actual, u.sl, v_riesgo,
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
               'descarte', case when motivo_dim is not null then 'dimensionado:' || motivo_dim
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
            select c, orden, sum((c ->> 'apalancamiento')::numeric) over () as suma
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
                   (mk.c ->> 'precio')::numeric, (mk.c ->> 'sl')::numeric, v_riesgo,
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

-- ═════════════════════════════════════════════════════════════════════
-- El ciclo: abre todas las marcadas
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_ciclo_agente(p_agente_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag       public.agentes;
    v_cuenta   bigint;
    v_dia      public.agente_dias;
    v_go       jsonb;
    v_dec      jsonb;
    v_c        jsonb;
    v_res      jsonb;
    v_rech     jsonb := '[]'::jsonb;
    v_hoy      date := (now() at time zone 'UTC')::date;
    v_salida   jsonb;
    v_parc     int := 0;
    v_rot      jsonb;
    v_decision bigint;
    v_ordenes  jsonb := '[]'::jsonb;
    v_r        jsonb;
begin
    select * into v_ag from public.agentes where id = p_agente_id for update;
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    if v_cuenta is null then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'sin_cuenta');
    end if;

    v_dia := public.fn_sincronizar_dia_agente(p_agente_id, v_cuenta);

    v_go := public.rpc_evaluar_game_over(v_cuenta);
    if v_go ->> 'estado' = 'game_over' then
        if v_ag.estado <> 'game_over' then
            update public.agentes set estado = 'game_over', estado_previo = null,
                                      game_over_en = now() where id = p_agente_id;
        end if;
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'game_over');
    end if;

    if v_ag.estado not in ('activo', 'cuarentena') then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'agente_' || v_ag.estado);
    end if;

    -- 0016: gestionar lo abierto ANTES de decidir. Una toma parcial libera
    -- margen que la decisión de este mismo ciclo puede usar.
    v_parc := public.fn_agente_tomas_parciales(p_agente_id);

    if not v_dia.operable then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'dia_no_operable',
                                  'tomas_parciales', v_parc);
    end if;
    if v_go ->> 'estado' = 'inoperante' then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'cuenta_inoperante');
    end if;

    v_dec := public.fn_decidir_agente(p_agente_id);

    -- ── Rotación: cerrar la más débil y volver a decidir ────────────
    if v_dec ->> 'accion' = 'rotar' then
        v_rot := v_dec -> 'rotacion';
        v_res := public.rpc_cerrar_orden((v_rot ->> 'cerrar_orden_id')::bigint,
                                         (v_rot ->> 'precio')::numeric, 'rotacion',
                                         (v_rot ->> 'precio')::numeric);
        insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
        values (p_agente_id, 'rotacion', (v_rot ->> 'cerrar_orden_id')::bigint,
                jsonb_build_object('umbral', v_rot -> 'umbral'),
                v_rot || jsonb_build_object('pnl_al_cerrar', v_res -> 'pnl'))
        returning id into v_decision;
        v_dec := public.fn_decidir_agente(p_agente_id)
                 || jsonb_build_object('tras_rotar', v_rot);
        v_res := null;
    end if;

    -- 0023: abre TODAS sus marcadas en el mismo ciclo, cada una con su
    -- parte del reparto. Si el servidor rechaza una, siguen las demás.
    if v_dec ->> 'accion' = 'abrir' then
        for v_c in select c from jsonb_array_elements(v_dec -> 'marcadas') c
        loop
            begin
                v_r := public.rpc_abrir_orden(
                    v_cuenta, (v_c ->> 'senal_id')::bigint, null, null,
                    (v_c ->> 'apalancamiento_pedido')::numeric,
                    (v_dec #>> '{parametros,riesgo_pct_operacion}')::numeric,
                    'agente',
                    (v_dec - 'parametros' - 'accion' - 'marcadas')
                        || jsonb_build_object('elegido', v_c, 'marcadas', v_dec -> 'marcadas',
                                              'rechazos_servidor', v_rech,
                                              'parametros', v_dec -> 'parametros'),
                    (v_c ->> 'cantidad')::numeric);
                v_ordenes := v_ordenes || v_r;
                insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
                values (p_agente_id, 'reparto', (v_r ->> 'orden_id')::bigint,
                        jsonb_build_object('reparto', 'exigencia',
                                           'modo', v_dec #> '{reparto,modo}',
                                           'marcadas', v_dec #> '{reparto,marcadas}'),
                        jsonb_build_object('margen', v_r -> 'margen',
                                           'deficit', v_dec #> '{reparto,deficit}'));
            exception when others then
                v_rech := v_rech || jsonb_build_object('simbolo', v_c ->> 'simbolo', 'motivo', sqlerrm);
            end;
        end loop;

        if jsonb_array_length(v_ordenes) > 0 then
            v_res := v_ordenes -> 0;
            if v_decision is not null then
                update public.agente_decisiones
                   set orden_nueva_id = (v_res ->> 'orden_id')::bigint
                 where id = v_decision;
            end if;
        end if;
    end if;

    update public.agente_dias d set
        ciclos = ciclos + 1,
        ciclos_con_universo  = ciclos_con_universo + case when coalesce((v_dec ->> 'frescas')::int, 0) > 0 then 1 else 0 end,
        ciclos_sin_alcistas  = ciclos_sin_alcistas + case when coalesce((v_dec ->> 'sin_alcistas')::boolean, false) then 1 else 0 end,
        ciclos_sin_candidatos = ciclos_sin_candidatos
                                + case when v_dec ->> 'accion' = 'sin_candidatos'
                                         or (v_dec ->> 'accion' = 'abrir' and v_res is null) then 1 else 0 end,
        descartes = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
                        select k, sum(v)::int as v from (
                            select key as k, value::int as v from jsonb_each_text(d.descartes)
                            union all
                            select key, value::int from jsonb_each_text(coalesce(v_dec -> 'descartes_por_motivo', '{}'))
                             where key <> 'candidata') t group by k) s),
        cumplido = cumplido or v_dec ->> 'accion' = 'meta_cumplida',
        ultimo_ciclo_en = now(),
        ultima_decision = jsonb_build_object('accion', v_dec ->> 'accion',
                                             'orden', v_res, 'ordenes', v_ordenes, 'rechazos', v_rech,
                                             'rotacion', v_rot, 'tomas_parciales', v_parc,
                                             'deficit', v_dec -> 'deficit_pendiente',
                                             'candidatos', v_dec -> 'candidatos_evaluados')
     where agente_id = p_agente_id and fecha = v_hoy;

    perform public.fn_disparadores_backlog(p_agente_id, v_dec);

    if exists (select 1 from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
                where c.agente_id = p_agente_id and o.estado = 'cerrada'
                  and o.fecha_salida > coalesce(v_ag.destilado_en, '-infinity'::timestamptz)) then
        perform public.fn_destilar_practicas(p_agente_id);
    end if;

    -- Aprender: con decisiones resueltas suficientes, mover un parámetro.
    perform public.fn_ajustar_parametros(p_agente_id);

    v_salida := jsonb_build_object('agente', v_ag.nombre, 'accion', v_dec ->> 'accion',
                                   'candidatos', v_dec -> 'candidatos_evaluados');
    if v_rot is not null then
        v_salida := v_salida || jsonb_build_object('rotacion', v_rot);
    end if;
    if v_parc > 0 then
        v_salida := v_salida || jsonb_build_object('tomas_parciales', v_parc);
    end if;
    if v_res is not null then
        v_salida := v_salida || jsonb_build_object('orden', v_res, 'ordenes', v_ordenes);
    end if;
    if jsonb_array_length(v_rech) > 0 then
        v_salida := v_salida || jsonb_build_object('rechazos', v_rech);
    end if;
    return v_salida;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Ajuste de parámetros sin el de reparto
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_ajustar_parametros(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_desde   timestamptz;
    v_n       int;
    v_media   numeric;
    v_nuevo   jsonb;
    v_propio  numeric;
    v_otro    numeric;
    v_n_otro  int;
    v_modo    text;
    v_cambios int := 0;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    v_p := public.fn_parametros_agente(v_ag);

    -- ── Rotación ────────────────────────────────────────────────────
    if v_p ->> 'rotacion_umbral' is not null then
        select coalesce(max(creado_en), '-infinity') into v_desde
          from public.agente_ajustes where agente_id = p_agente_id and tipo = 'rotacion';
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'rotacion' and resuelta_en > v_desde;
        if v_n >= 10 and v_media <> 0 then
            v_nuevo := to_jsonb(case when v_media < 0
                                     then least(3.0, (v_p ->> 'rotacion_umbral')::numeric + 0.2)
                                     else greatest(1.1, (v_p ->> 'rotacion_umbral')::numeric - 0.1) end);
            if v_nuevo <> v_p -> 'rotacion_umbral' then
                insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
                values (p_agente_id, 'rotacion', v_p -> 'rotacion_umbral', v_nuevo,
                        jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
                update public.agentes set estrategia = jsonb_set(estrategia, '{rotacion_umbral}', v_nuevo)
                 where id = p_agente_id;
                v_cambios := v_cambios + 1;
            end if;
        end if;
    end if;

    -- ── Toma parcial ────────────────────────────────────────────────
    select coalesce(max(creado_en), '-infinity') into v_desde
      from public.agente_ajustes where agente_id = p_agente_id and tipo = 'parcial';
    if jsonb_typeof(v_p -> 'tp_parcial') = 'object' then
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'parcial' and resuelta_en > v_desde;
        if v_n >= 10 and v_media < 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'parcial', v_p -> 'tp_parcial', 'null'::jsonb,
                    jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{tp_parcial}', 'null'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    else
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id <> p_agente_id and tipo = 'parcial' and resuelta_en > v_desde;
        if v_n >= 10 and v_media > 0 then
            v_nuevo := jsonb_build_object('recorrido', 0.5, 'fraccion', 0.5, 'mover_stop', false);
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'parcial', 'null'::jsonb, v_nuevo,
                    jsonb_build_object('decisiones_de_otros', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{tp_parcial}', v_nuevo)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    end if;

    -- ── Reparto: retirado en la 0023 ────────────────────────────────
    -- Ya no se elige entre «cupo» y «concentrado»: cuánto se reparte lo
    -- decide la exigencia de cada día. Las decisiones de reparto se siguen
    -- registrando y resolviendo (retorno sobre el margen) como evidencia.

    if v_cambios > 0 then
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'agente',
                v_ag.nombre || ' ajusta su estrategia con lo aprendido',
                jsonb_build_object('ajustes', v_cambios));
    end if;
    return v_cambios;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- v_operaciones_agentes: lo que consume cada operación del saldo para operar
-- ═════════════════════════════════════════════════════════════════════
-- La de la 0016 con dos columnas al final (lo único que admite CREATE OR
-- REPLACE VIEW): lo que la operación consume del saldo para operar de su
-- cuenta (margen × tope de la fase) y ese saldo, para leerlo en %.
create or replace view public.v_operaciones_agentes
with (security_invoker = true) as
    select o.id, o.cuenta_id, g.id as agente_id, g.nombre as agente,
           o.activo_id, o.senal_id, o.estado, o.origen,
           o.precio_entrada, o.fecha_entrada, o.cantidad, o.apalancamiento,
           o.nominal, o.margen_comprometido, o.tp, o.sl, o.precio_liquidacion,
           o.precio_salida, o.fecha_salida, o.motivo_cierre, o.precio_observado_cierre,
           o.pnl_bruto, o.pnl_pct, o.racional, o.creado_en, o.precio_max_visto,
           a.simbolo, a.clase, a.nombre, a.ultimo_precio, a.ultimo_precio_en,
           case when o.estado = 'abierta' and a.ultimo_precio is not null
                then round(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                    -o.margen_comprometido), 2)
           end as pnl_flotante,
           o.pnl_parciales, o.parcial_hecho, o.sl_original,
           round(o.margen_comprometido * public.fn_tope_fase(c.fase), 2) as consumo_saldo,
           ce.saldo_operar
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id and c.agente_id is not null
      join public.agentes g on g.id = c.agente_id
      join public.activos a on a.id = o.activo_id
      left join public.v_cuentas_equity ce on ce.id = c.id;
