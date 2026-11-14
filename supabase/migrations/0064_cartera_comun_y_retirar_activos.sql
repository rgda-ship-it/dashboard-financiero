-- ─────────────────────────────────────────────────────────────────────
-- 0064 — La cartera es de todos, y un activo se puede retirar
-- (decisión del dueño, 2026-11-14).
--
-- Hasta ahora cada usuario veía en Cartera y en el escáner solo los
-- activos que él seguía, y solo podía operar esos en el simulador. Pero
-- el catálogo ya era común desde la 0029: el ETL procesa todo lo activo,
-- lo siga alguien o no, y los agentes operan todo lo activo. El filtro por
-- usuario solo escondía parte de lo que el sistema lleva.
--
-- Y quitar un activo de la cartera propia no lo sacaba de ningún sitio:
-- seguía activo, en el ETL y en el universo de los agentes. No había
-- forma de retirarlo sin una migración (0028, 0029).
--
-- Ahora:
-- 1. Cartera y escáner enseñan a todos los usuarios aprobados todo lo
--    que el sistema lleva: lo activo, lo pendiente de su primera carga y
--    lo suspendido que alguien sigue (lo mismo que procesa el ETL).
-- 2. En el simulador se opera cualquier activo activo, se siga o no.
-- 3. `rpc_retirar_activo`, solo para administradores: saca un activo de
--    la cartera de todos. Queda suspendido y sin seguidores, fuera del
--    ETL, del escáner y del universo de los agentes. No borra el
--    histórico; si alguien lo vuelve a añadir, vuelve a entrar.
-- 4. Se retiran los dos ETF tokenizados dados de alta por error el 14-11.
--
-- Lo que sigue siendo de cada uno: sus posiciones importadas
-- (`v_mis_posiciones`), sus cuentas del simulador y sus órdenes.
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. Cartera y escáner, comunes ────────────────────────────────────
create or replace view public.v_escaner_usuario
with (security_invoker = true) as
    select sv.*
      from public.senales_vigentes sv
      join public.activos a on a.id = sv.activo_id
     where a.estado in ('activo', 'pendiente_backfill')
        or (a.estado = 'suspendido' and a.seguidores > 0);

comment on view public.v_escaner_usuario is
  'El escáner: la última señal de todo lo que el sistema lleva (0064). Antes, solo lo que seguía quien consultaba.';

create or replace view public.v_mi_cartera
with (security_invoker = true) as
    select a.id as activo_id, a.simbolo, a.clase, a.nombre, a.estado,
           a.ultimo_precio, a.ultimo_precio_en, a.ultimo_etl_en,
           a.primer_backfill_en, a.ultimo_error, a.seguidores,
           upper(coalesce(cg.simbolo, a.simbolo)) as ticker,
           a.creado_en as anadido_en
      from public.activos a
      left join public.catalogo_coingecko cg on a.clase = 'cripto' and cg.id = a.id_proveedor
     where a.estado in ('activo', 'pendiente_backfill')
        or (a.estado = 'suspendido' and a.seguidores > 0);

comment on view public.v_mi_cartera is
  'La cartera común (0064): todo lo que el sistema lleva, para cualquier usuario aprobado. Conserva el nombre por el frontend.';

-- ── 2. El simulador opera cualquier activo activo ────────────────────
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
    v_escala     numeric;
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

    -- 0064: la cartera es común. Ya no se exige que el usuario siga el
    -- activo: basta con que esté activo, que se comprueba arriba.

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
    -- 0055: el tope de la fase se mide sobre la BASE del saldo para operar
    -- (saldo inicial o el último escalón alcanzado), no sobre el equity.
    -- Con pérdidas, cada orden admite algo más de apalancamiento; con
    -- ganancias que no llegan al escalón, algo menos.
    v_escala := public.fn_escala_operar(public.fn_base_operar(v_cuenta.id), v_cuenta.fase, public.fn_equity(p_cuenta_id));
    v_tope   := public.fn_tope_cuenta(public.fn_base_operar(v_cuenta.id), v_cuenta.fase, public.fn_equity(p_cuenta_id));
    if p_apalancamiento is not null and p_apalancamiento > v_tope then
        raise exception 'Apalancamiento %x rechazado: el tope de tu cuenta es %x (%x de la % sobre una base de % $).',
              p_apalancamiento, v_tope, public.fn_tope_fase(v_cuenta.fase), replace(v_cuenta.fase, '_', ' '),
              public.fn_base_operar(v_cuenta.id)
              using errcode = 'P0001';
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
        coalesce(p_apalancamiento, public.fn_escalar_apalancamiento(v_senal.leverage_recomendado, v_escala)),
        p_apalancamiento, v_tope,
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
            coalesce(p_apalancamiento, public.fn_escalar_apalancamiento(v_senal.leverage_recomendado, v_escala),
                     v_tope), v_tope));
end;
$$;

-- ── 3. Retirar un activo de la cartera de todos ──────────────────────
alter table public.auditoria_admin drop constraint auditoria_admin_accion_check;
alter table public.auditoria_admin add constraint auditoria_admin_accion_check check (accion in (
    'aprobar_usuario', 'rechazar_usuario', 'suspender_usuario', 'revertir_fase',
    'resolver_backlog', 'reiniciar_agente', 'cambiar_estado_agente', 'resolver_hipotesis',
    'renovar_credencial', 'aportar_saldo', 'retirar_activo'));

create function public.fn_retirar_activo(p_activo_id bigint, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_a        public.activos;
    v_abiertas int;
    v_quitadas int;
begin
    select * into v_a from public.activos where id = p_activo_id for update;
    if not found then
        raise exception 'El activo % no existe', p_activo_id using errcode = 'P0002';
    end if;
    if v_a.referencia or v_a.solo_cartera then
        raise exception '% es una referencia o una clase de activo de las carteras: no se retira.', v_a.simbolo
              using errcode = 'P0001';
    end if;
    select count(*) into v_abiertas from public.ordenes where activo_id = p_activo_id and estado = 'abierta';
    if v_abiertas > 0 then
        raise exception '% tiene % posiciones abiertas: ciérralas antes de retirarlo.', v_a.simbolo, v_abiertas
              using errcode = 'P0001';
    end if;

    delete from public.cartera_activos where activo_id = p_activo_id;
    get diagnostics v_quitadas = row_count;
    update public.activos set estado = 'suspendido' where id = p_activo_id and estado <> 'invalido';

    insert into public.eventos_sistema (tipo, mensaje, datos)
    values ('sys', v_a.simbolo || ' se retira de la cartera',
            jsonb_build_object('activo_id', p_activo_id, 'estado_antes', v_a.estado,
                               'carteras_quitadas', v_quitadas, 'motivo', p_motivo));
    return jsonb_build_object('activo_id', p_activo_id, 'simbolo', v_a.simbolo, 'carteras_quitadas', v_quitadas);
end;
$$;

create function public.rpc_retirar_activo(p_activo_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_r jsonb;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador puede retirar un activo de la cartera.' using errcode = '42501';
    end if;
    v_r := public.fn_retirar_activo(p_activo_id, 'administrador');
    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), 'retirar_activo', 'activo', p_activo_id::text, v_r);
    return v_r;
end;
$$;

revoke execute on function public.fn_retirar_activo(bigint, text) from public, anon, authenticated;
revoke execute on function public.rpc_retirar_activo(bigint)      from public, anon;
grant  execute on function public.rpc_retirar_activo(bigint)      to authenticated;

-- ── 4. Los dos ETF tokenizados dados de alta por error (14-11) ───────
-- El dueño buscaba SPY y VNQ de Yahoo. Ningún agente abrió nada en ellos.
-- Si tuvieran una posición abierta, la migración falla en vez de cerrarla
-- por su cuenta.
select public.fn_retirar_activo(id, '0064: alta por error, se buscaba el ETF de Yahoo')
  from public.activos
 where clase = 'cripto'
   and simbolo in ('state-street-spdr-s-p-500-etf-trust-dinari-tokenized-etf',
                   'vanguard-real-estate-etf-rstock')
   and estado <> 'suspendido';
