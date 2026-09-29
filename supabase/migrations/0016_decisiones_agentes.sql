-- ─────────────────────────────────────────────────────────────────────
-- 0016 — Reparto del capital, cierres parciales, rotación y agentes que
-- aprenden de cada decisión (D16, 2026-09-29).
--
-- QUÉ PIDIÓ EL DUEÑO, Y POR QUÉ
--
--   «Una sola posición se lleva todo el margen.» El tamaño sale del riesgo
--   (nominal = riesgo ÷ distancia al stop): con un stop cercano, una orden
--   pide un 80 % de margen, el tope de G3 (60 %) la recorta a 60 y no
--   queda hueco para otra. No había tope POR posición.
--
--   Y más allá del arreglo: que el usuario pueda elegir la cantidad, que
--   exista el cierre parcial, que los agentes puedan cerrar una posición
--   para entrar en otra mejor, y que aprendan también de los errores y de
--   cada operación, no solo del veredicto semanal.
--
-- LO QUE AÑADE
--
--   1. CUPO POR POSICIÓN = margen máx ÷ nº máx de posiciones. Es la
--      RECOMENDACIÓN del sistema (60 % ÷ 3 = 20 % del equity en una cuenta
--      por defecto). No es un límite duro para el usuario: puede escribir
--      la cantidad que quiera, y el servidor solo impone G1-G5.
--   2. CANTIDAD A MANO en `rpc_abrir_orden` (`p_cantidad`).
--   3. CIERRE PARCIAL (`rpc_cerrar_parcial` para el usuario,
--      `fn_cerrar_parcial` para el servidor): libera la parte proporcional
--      del margen y deja sus dos apuntes en el libro mayor.
--   4. TRES PARÁMETROS NUEVOS en la estrategia de cada agente:
--        reparto          'cupo' | 'concentrado'
--        rotacion_umbral  cerrar la posición más débil si el R:R de la
--                         mejor señal es ≥ umbral × el R:R RESTANTE de
--                         aquella (null = no rota)
--        tp_parcial       {recorrido, fraccion, mover_stop} | null
--   5. PRÁCTICAS «A EVITAR»: la destilación publica también las firmas que
--      pierden (≥ 3 ops, ≥ 66 % en stop, P&L medio < 0) como filtro de
--      exclusión. De los errores también se aprende.
--   6. DECISIONES JUZGADAS CONTRA SU CONTRAFACTUAL (`agente_decisiones`):
--      cada rotación, toma parcial y apertura se resuelve comparando lo que
--      pasó con lo que habría pasado sin ella, y cada 10 decisiones
--      resueltas el agente mueve su parámetro un paso (`agente_ajustes`).
--
-- DESVIACIONES Y LÍMITES, ANOTADOS
--
--   · «Stop a la entrada» se escribe como entrada × (1 − 0,05 %): el CHECK
--     de `ordenes` exige sl < entrada, y es la condición que sostiene que
--     solo haya largos. Cinco puntos básicos no cambian la lectura.
--   · El contrafactual de una rotación se observa con el `ultimo_precio`
--     que el ciclo ve cada 5 minutos, no con velas: si el precio tocó el
--     objetivo y volvió entre dos lecturas, no se ve. Se asume, y a los 7
--     días sin tocar ningún nivel se valora al precio de ese momento.
--   · El P&L realizado del día pasa a salir del LIBRO MAYOR (apuntes
--     `resultado_operacion`), no de `ordenes.pnl_bruto`: con cierres
--     parciales, el `pnl_bruto` de una orden solo cubre lo que quedaba al
--     cerrarla, y la meta diaria (N8) contaría de menos.
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- Esquema
-- ═════════════════════════════════════════════════════════════════════

alter table public.ordenes drop constraint ordenes_motivo_cierre_check;
alter table public.ordenes add constraint ordenes_motivo_cierre_check
    check (motivo_cierre in ('tp', 'sl', 'liquidacion', 'manual', 'caducidad', 'rotacion'));

-- Lo que la orden ya realizó en cierres parciales. `pnl_bruto` sigue
-- siendo el resultado de lo que quedaba al cerrarla; el total es la suma.
alter table public.ordenes add column pnl_parciales numeric(20, 2) not null default 0;
alter table public.ordenes add column parcial_hecho boolean not null default false;
-- El stop con el que se abrió, si una toma parcial lo movió.
alter table public.ordenes add column sl_original numeric(20, 8);

create table public.ordenes_parciales (
    id                bigserial primary key,
    orden_id          bigint not null references public.ordenes(id) on delete cascade,
    cantidad          numeric(24, 8) not null check (cantidad > 0),
    precio            numeric(20, 8) not null,
    precio_observado  numeric(20, 8),
    margen_liberado   numeric(20, 2) not null,
    pnl               numeric(20, 2) not null,
    motivo            text not null check (motivo in ('manual', 'tp_parcial')),
    creado_en         timestamptz not null default now()
);
create index ordenes_parciales_orden_idx on public.ordenes_parciales (orden_id);

alter table public.mejores_practicas add column sentido text not null default 'exigir'
    check (sentido in ('exigir', 'evitar'));

-- Cada decisión de un agente que se puede juzgar después.
create table public.agente_decisiones (
    id             bigserial primary key,
    agente_id      bigint not null references public.agentes(id) on delete cascade,
    tipo           text not null check (tipo in ('rotacion', 'parcial', 'reparto')),
    orden_id       bigint references public.ordenes(id) on delete cascade,
    orden_nueva_id bigint references public.ordenes(id) on delete set null,
    parametro      jsonb not null,
    datos          jsonb not null default '{}'::jsonb,
    resultado      jsonb,
    -- Positivo = la decisión ACERTÓ frente a su contrafactual, en dólares
    -- (rotación, parcial) o en % de retorno sobre el margen (reparto).
    efecto         numeric(20, 4),
    creado_en      timestamptz not null default now(),
    resuelta_en    timestamptz
);
create index agente_decisiones_pendientes_idx on public.agente_decisiones (tipo) where resuelta_en is null;
create index agente_decisiones_agente_idx on public.agente_decisiones (agente_id, tipo, resuelta_en);

-- Cada cambio de parámetro con la evidencia que lo motivó.
create table public.agente_ajustes (
    id         bigserial primary key,
    agente_id  bigint not null references public.agentes(id) on delete cascade,
    tipo       text not null check (tipo in ('rotacion', 'parcial', 'reparto')),
    de         jsonb,
    a          jsonb,
    evidencia  jsonb not null check (jsonb_typeof(evidencia) = 'object' and evidencia <> '{}'::jsonb),
    creado_en  timestamptz not null default now()
);

-- ═════════════════════════════════════════════════════════════════════
-- Parámetros: los tres nuevos, con valores por defecto neutros
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
            'margen_comprometido_max_pct', 40.0,
            'atr_pct_min', null,
            'atr_pct_max', null,
            'antiguedad_senal_max_min', 90,
            -- 0016: reparto por cupo, sin rotación y sin toma parcial, salvo
            -- que la estrategia diga otra cosa.
            'reparto', 'cupo',
            'rotacion_umbral', null,
            'tp_parcial', null)
         || (p_agente.estrategia - 'practicas_adoptadas' - 'version' - 'modo_conservacion');

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
-- Dimensionado con cupo por posición
--
-- Una firma nueva (un parámetro más, con valor por defecto) exige borrar
-- la anterior: con las dos, una llamada de diez argumentos sería ambigua.
-- El CASCADE se lleva `v_recomendaciones_usuario`, que se recrea abajo.
-- Las llamadas de diez argumentos de `rpc_abrir_orden` siguen valiendo:
-- el undécimo tiene valor por defecto y sin él el cálculo es el de antes.
-- ═════════════════════════════════════════════════════════════════════
drop function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) cascade;

create function public.fn_dimensionar_posicion(
    p_equity                numeric,
    p_saldo_disponible      numeric,
    p_saldo_bloqueado       numeric,
    p_precio                numeric,
    p_sl                    numeric,
    p_riesgo_pct            numeric,
    p_margen_max_pct        numeric,
    p_leverage_recomendado  numeric,
    p_leverage_propio       numeric,
    p_tope_fase             numeric,
    p_cupo_pct              numeric default null,
    p_unidades_enteras      boolean default false,
    out cantidad            numeric,
    out apalancamiento      numeric,
    out margen              numeric,
    out precio_liquidacion  numeric,
    out motivo              text)
language plpgsql immutable
as $$
declare
    v_riesgo_max   numeric;
    v_distancia    numeric;
    v_nominal      numeric;
    v_margen_libre numeric;
begin
    v_riesgo_max := p_equity * p_riesgo_pct / 100;

    v_distancia := (p_precio - p_sl) / p_precio;
    if v_distancia <= 0 then
        motivo := 'stop_por_encima_del_precio';
        return;
    end if;

    v_nominal := v_riesgo_max / v_distancia;

    apalancamiento := least(coalesce(p_leverage_recomendado, p_tope_fase),
                            coalesce(p_leverage_propio, p_tope_fase),
                            p_tope_fase);
    if apalancamiento < 1 then
        motivo := 'apalancamiento_bajo_uno';
        return;
    end if;

    precio_liquidacion := p_precio * (1 - 1 / apalancamiento);
    if precio_liquidacion > p_sl then
        apalancamiento := public.fn_piso_decimal(1 / v_distancia) - 0.1;
        if apalancamiento < 1.0 then
            motivo := 'sin_operacion_liquidacion_antes_del_stop';
            return;
        end if;
        precio_liquidacion := p_precio * (1 - 1 / apalancamiento);
    end if;

    -- 5. Topes por saldo, por margen total comprometido (G3) y, desde la
    --    0016, por CUPO de la posición: con él, una sola orden ya no puede
    --    llevarse todo el margen que admite la cuenta.
    v_margen_libre := p_equity * p_margen_max_pct / 100 - p_saldo_bloqueado;
    margen := least(v_nominal / apalancamiento,
                    p_saldo_disponible * 0.95,
                    v_margen_libre,
                    coalesce(p_equity * p_cupo_pct / 100, v_nominal / apalancamiento));
    margen := floor(margen * 100) / 100;
    if margen <= 0 then
        motivo := 'margen_insuficiente';
        return;
    end if;

    -- Las acciones no se compran por fracciones; las criptos sí. Con
    -- unidades enteras se redondea HACIA ABAJO (hacia arriba se pasaría de
    -- los topes) y el margen se recalcula para esas unidades.
    if p_unidades_enteras then
        cantidad := floor(margen * apalancamiento / p_precio);
        if cantidad < 1 then
            motivo := 'cantidad_nula';
            return;
        end if;
        margen := ceil(cantidad * p_precio / apalancamiento * 100) / 100;
    else
        cantidad := round(margen * apalancamiento / p_precio, 8);
    end if;
    if cantidad <= 0 then
        motivo := 'cantidad_nula';
        return;
    end if;
    motivo := null;
end;
$$;

grant  execute on function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, boolean)
    to authenticated;
revoke execute on function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, boolean)
    from public, anon;

-- Cupo recomendado de una cuenta: su margen máximo repartido entre sus
-- posiciones posibles. Pura.
create function public.fn_cupo_pct(p_margen_max_pct numeric, p_max_posiciones int)
returns numeric
language sql immutable
as $$ select round(p_margen_max_pct / greatest(p_max_posiciones, 1), 2) $$;

grant  execute on function public.fn_cupo_pct(numeric, int) to authenticated;
revoke execute on function public.fn_cupo_pct(numeric, int) from public, anon;

-- La vista de la 0011, ahora con el cupo: la RECOMENDACIÓN del sistema.
create view public.v_recomendaciones_usuario
with (security_invoker = true) as
    select e.activo_id, e.simbolo, e.clase, e.nombre, e.senal_id,
           e.precio_actual, e.tp, e.sl, e.ratio_rr, e.fuerza, e.direccion,
           e.atr_pct, e.leverage_recomendado, e.leverage_tope,
           e.leverage_referencia_volatilidad, e.leverage_motivo, e.niveles_origen,
           e.soporte, e.resistencia, e.indicadores_alcistas, e.indicadores_bajistas,
           e.resumen_confluencia, e.calculado_en, e.antiguedad_min,
           e.cuenta_id, e.riesgo_pct_operacion, e.equity,
           d.cantidad, d.apalancamiento, d.margen, d.precio_liquidacion, d.motivo,
           (d.motivo is null and e.ratio_rr >= e.ratio_rr_minimo) as confirmable,
           e.cupo_pct
      from (
           select sv.activo_id, sv.simbolo, sv.clase, sv.nombre, sv.id as senal_id,
                  sv.precio_actual, sv.tp, sv.sl, sv.ratio_rr, sv.fuerza, sv.direccion,
                  sv.atr_pct, sv.leverage_recomendado, sv.leverage_tope,
                  sv.leverage_referencia_volatilidad, sv.leverage_motivo, sv.niveles_origen,
                  sv.soporte, sv.resistencia, sv.indicadores_alcistas, sv.indicadores_bajistas,
                  sv.resumen_confluencia, sv.calculado_en,
                  round(extract(epoch from now() - sv.calculado_en) / 60)::int as antiguedad_min,
                  ce.id as cuenta_id, ce.riesgo_pct_operacion, ce.equity,
                  ce.saldo_disponible, ce.saldo_bloqueado, ce.margen_comprometido_max_pct,
                  ce.ratio_rr_minimo, ce.fase,
                  public.fn_cupo_pct(ce.margen_comprometido_max_pct, ce.max_posiciones_abiertas) as cupo_pct
             from public.v_escaner_usuario sv
             join public.v_cuentas_equity ce on ce.usuario_id = auth.uid() and ce.estado = 'activa'
            where sv.operable
              and sv.estado_activo = 'activo'
              and sv.calculado_en > now() - (ce.antiguedad_senal_max_min || ' minutes')::interval
              and not exists (select 1 from public.ordenes o
                               where o.cuenta_id = ce.id and o.activo_id = sv.activo_id
                                 and o.estado = 'abierta')
      ) e
      cross join lateral public.fn_dimensionar_posicion(
           e.equity, e.saldo_disponible, e.saldo_bloqueado,
           e.precio_actual, e.sl, e.riesgo_pct_operacion, e.margen_comprometido_max_pct,
           e.leverage_recomendado, null, public.fn_tope_fase(e.fase), e.cupo_pct,
           e.clase = 'accion') d;

-- ═════════════════════════════════════════════════════════════════════
-- Apertura con cantidad a mano
--
-- Firma nueva (`p_cantidad` al final): se borra la anterior. Todo lo
-- demás es la función de la 0011 sin cambios salvo el bloque marcado.
-- ═════════════════════════════════════════════════════════════════════
drop function public.rpc_abrir_orden(bigint, bigint, numeric, timestamptz, numeric, numeric, text, jsonb);

create function public.rpc_abrir_orden(
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

    -- ── G4 ──────────────────────────────────────────────────────────
    select count(*) into v_abiertas
      from public.ordenes where cuenta_id = p_cuenta_id and estado = 'abierta';
    if v_abiertas >= v_cuenta.max_posiciones_abiertas then
        raise exception 'Ya tienes % posiciones abiertas (máximo %). Tres posiciones en el mismo mercado son una sola apuesta con tres nombres.',
              v_abiertas, v_cuenta.max_posiciones_abiertas using errcode = 'P0001';
    end if;
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

revoke execute on function public.rpc_abrir_orden(bigint, bigint, numeric, timestamptz, numeric, numeric, text, jsonb, numeric)
    from public, anon;
grant  execute on function public.rpc_abrir_orden(bigint, bigint, numeric, timestamptz, numeric, numeric, text, jsonb, numeric)
    to authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- Cierre parcial
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_cerrar_parcial(
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
begin
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

    v_pnl := round(v_cant * (p_precio - v_orden.precio_entrada), 2);
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
    values (p_orden_id, v_cant, p_precio, coalesce(p_observado, p_precio), v_margen, v_pnl, p_motivo);

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
                               'fraccion', round(v_cant / v_orden.cantidad, 4), 'precio', p_precio, 'pnl', v_pnl));

    perform public.rpc_evaluar_fase(v_orden.cuenta_id);
    perform public.rpc_evaluar_game_over(v_orden.cuenta_id);

    return jsonb_build_object('cerrada', true, 'parcial', true, 'cantidad_cerrada', v_cant,
                              'margen_liberado', v_margen, 'pnl', v_pnl,
                              'cantidad_restante', v_orden.cantidad - v_cant);
end;
$$;

-- El del navegador: su orden, al precio vivo, con la regla M4 de frescura.
create function public.rpc_cerrar_parcial(p_orden_id bigint, p_fraccion numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid    uuid := public.fn_exigir_aprobado();
    v_precio numeric;
    v_clase  text;
    v_edad   int;
begin
    if not exists (select 1 from public.ordenes o
                     join public.cuentas_simulacion c on c.id = o.cuenta_id
                    where o.id = p_orden_id and c.usuario_id = v_uid) then
        raise exception 'Esa orden no es tuya.' using errcode = '42501';
    end if;

    select a.ultimo_precio, a.clase,
           round(extract(epoch from now() - a.ultimo_precio_en) / 60)::int
      into v_precio, v_clase, v_edad
      from public.ordenes o join public.activos a on a.id = o.activo_id
     where o.id = p_orden_id;

    if v_precio is null then
        raise exception 'No hay precio para ese activo: no se puede cerrar a ciegas.' using errcode = 'P0001';
    end if;
    if v_edad > public.fn_frescura_precio_min(v_clase) then
        raise exception 'El último precio es de hace % minutos: espera a que se actualice.', v_edad
              using errcode = 'P0001';
    end if;

    return public.fn_cerrar_parcial(p_orden_id, p_fraccion, v_precio, 'manual', v_precio);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- P&L realizado del día desde el LIBRO MAYOR (ver cabecera)
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_pnl_realizado_dia(p_cuenta_id bigint, p_fecha date)
returns numeric
language sql stable
as $$
    select coalesce(sum(importe), 0)
      from public.movimientos_saldo
     where cuenta_id = p_cuenta_id and tipo = 'resultado_operacion'
       and (creado_en at time zone 'UTC')::date = p_fecha
$$;

-- `v_ranking_agentes` usa lo anterior con security_invoker: sin esto, un
-- aprobado no leería el libro mayor de los agentes y su P&L de hoy saldría
-- en cero. Los agentes ya eran públicos para los aprobados (requisito 10).
create policy movimientos_de_agentes on public.movimientos_saldo
    for select to authenticated
    using (public.es_usuario_aprobado()
           and cuenta_id in (select id from public.cuentas_simulacion where agente_id is not null));

-- ═════════════════════════════════════════════════════════════════════
-- Prácticas «a evitar»
-- ═════════════════════════════════════════════════════════════════════

-- Una práctica «evitar» solo quita candidatos, así que es adoptable por
-- cualquiera que opere su clase; una «exigir» tiene que poder cumplirse.
create function public.fn_practica_adoptable(p_params jsonb, p_c jsonb, p_sentido text)
returns boolean
language sql immutable
as $$
    select case when p_sentido = 'evitar'
                then p_c ->> 'clase' is null or p_params -> 'clases_admitidas' ? (p_c ->> 'clase')
                else public.fn_practica_compatible(p_params, p_c) end
$$;

-- Los elementos de `p_practicas` pasan a ser `{"c": condiciones, "s":
-- sentido}`. Un objeto sin `c` se sigue leyendo como condiciones a exigir.
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
                    then case when s.clase = 'cripto' or public.fn_mercado_abierto(now())
                              then 'antiguedad' else 'fuera_de_sesion' end
               when not (s.indicadores_alcistas > s.indicadores_bajistas) then 'direccion'
               when not s.operable and s.atr_pct is null then 'sin_atr'
               when not s.operable then 'no_operable'
               when not (p_params -> 'fuerzas_admitidas' ? coalesce(s.fuerza, '')) then 'fuerza'
               when not (p_params -> 'niveles_origen_admitidos' ? coalesce(s.niveles_origen, '')) then 'niveles_origen'
               when s.ratio_rr is null or s.ratio_rr < (p_params ->> 'rr_minimo')::numeric then 'rr'
               when p_params ->> 'atr_pct_min' is not null
                    and (s.atr_pct is null or s.atr_pct < (p_params ->> 'atr_pct_min')::numeric) then 'atr_bajo'
               when p_params ->> 'atr_pct_max' is not null
                    and (s.atr_pct is null or s.atr_pct > (p_params ->> 'atr_pct_max')::numeric) then 'atr_alto'
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

create or replace function public.fn_adoptar_practica(p_agente_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag public.agentes;
    v_id bigint;
begin
    select * into v_ag from public.agentes where id = p_agente_id;

    select p.id into v_id
      from public.mejores_practicas p
      left join lateral (select coalesce(sum(valoracion), 0) as puntos
                           from public.mp_valoraciones v where v.practica_id = p.id) v on true
     where p.estado in ('propuesta', 'validada')
       and p.agente_autor_id <> p_agente_id
       and not exists (select 1 from public.mp_adopciones ad
                        where ad.practica_id = p.id and ad.agente_id = p_agente_id)
       and public.fn_practica_adoptable(public.fn_parametros_agente(v_ag), p.condiciones, p.sentido)
     order by v.puntos desc, p.confianza desc,
              (p.resultado_observado ->> 'ops')::int desc, p.id
     limit 1;

    if v_id is null then return null; end if;

    insert into public.mp_adopciones (practica_id, agente_id) values (v_id, p_agente_id);
    perform public.fn_espejar_practicas(p_agente_id);
    return v_id;
end;
$$;

-- Destilación de lo que funciona Y de lo que falla.
create or replace function public.fn_destilar_practicas(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag    public.agentes;
    v_g     record;
    v_n     int := 0;
    v_id    bigint;
    v_nueva boolean;
    v_evita boolean;
begin
    select * into v_ag from public.agentes where id = p_agente_id;

    for v_g in
        with base as (
            select o.id, o.motivo_cierre, o.pnl_pct, s.ratio_rr,
                   a.clase, s.fuerza, s.niveles_origen,
                   case when s.atr_pct < 3 then 'bajo' when s.atr_pct < 6 then 'medio' else 'alto' end as tramo_atr,
                   case when s.ratio_rr < 1.5 then 'bajo' when s.ratio_rr < 2.5 then 'medio' else 'alto' end as tramo_rr
              from public.ordenes o
              join public.cuentas_simulacion c on c.id = o.cuenta_id
              join public.senales s on s.id = o.senal_id
              join public.activos a on a.id = o.activo_id
             where c.agente_id = p_agente_id and o.estado = 'cerrada'
               -- Una rotación la decidió el agente, no el mercado: no
               -- cuenta como acierto ni como error de la firma.
               and o.motivo_cierre <> 'rotacion'
               and s.atr_pct is not null and s.ratio_rr is not null and s.fuerza is not null
               and s.niveles_origen is not null
        ),
        grupos as (
            select clase, fuerza, niveles_origen, tramo_atr, tramo_rr,
                   count(*) as ops,
                   count(*) filter (where motivo_cierre = 'tp') as tp,
                   count(*) filter (where motivo_cierre in ('sl', 'liquidacion')) as sl,
                   round(avg(pnl_pct), 4) as pnl_medio_pct,
                   round(avg(ratio_rr), 4) as rr_medio,
                   jsonb_agg(id order by id) as ordenes
              from base
             group by clase, fuerza, niveles_origen, tramo_atr, tramo_rr
            having count(*) >= 3
        )
        select *,
               case when tp::numeric / ops >= 0.66 and pnl_medio_pct > 0 then 'exigir'
                    when sl::numeric / ops >= 0.66 and pnl_medio_pct < 0 then 'evitar' end as sentido
          from grupos
         where (tp::numeric / ops >= 0.66 and pnl_medio_pct > 0)
            or (sl::numeric / ops >= 0.66 and pnl_medio_pct < 0)
    loop
        v_evita := v_g.sentido = 'evitar';
        insert into public.mejores_practicas
            (agente_autor_id, firma, titulo, contexto, regla, condiciones,
             resultado_observado, confianza, estado, sentido)
        values (
            p_agente_id,
            case when v_evita then 'evitar|' else '' end
                || concat_ws('|', v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr),
            case when v_evita then 'Evitar: ' else '' end
                || format('%s de fuerza %s con niveles de %s, ATR %s y R:R %s',
                          initcap(v_g.clase), v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr),
            format('%s cerró %s operaciones con esta firma: %s en objetivo, %s en stop, %s %% de media.',
                   v_ag.nombre, v_g.ops, v_g.tp, v_g.sl, v_g.pnl_medio_pct),
            case when v_evita
                 then format('En %s, NO entrar con fuerza %s, niveles de %s, ATR %s y R:R %s.',
                             v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr)
                 else format('En %s, exigir fuerza %s, niveles de %s, ATR %s y R:R %s antes de entrar.',
                             v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr) end,
            jsonb_strip_nulls(jsonb_build_object(
                'clase', v_g.clase,
                'fuerza', jsonb_build_array(v_g.fuerza),
                'niveles_origen', v_g.niveles_origen,
                'atr_pct', case v_g.tramo_atr
                               when 'bajo'  then jsonb_build_object('max', 3)
                               when 'medio' then jsonb_build_object('min', 3, 'max', 6)
                               else jsonb_build_object('min', 6) end,
                'ratio_rr', case v_g.tramo_rr
                               when 'bajo'  then jsonb_build_object('max', 1.5)
                               when 'medio' then jsonb_build_object('min', 1.5, 'max', 2.5)
                               else jsonb_build_object('min', 2.5) end)),
            jsonb_build_object('ops', v_g.ops, 'tp', v_g.tp, 'sl', v_g.sl,
                               'pnl_medio_pct', v_g.pnl_medio_pct, 'rr_medio', v_g.rr_medio,
                               'ordenes', v_g.ordenes),
            round((case when v_evita then v_g.sl else v_g.tp end)::numeric / v_g.ops, 3),
            case when v_g.ops >= 10 then 'validada' else 'propuesta' end,
            v_g.sentido)
        on conflict (agente_autor_id, firma) do update set
            resultado_observado = excluded.resultado_observado,
            contexto = excluded.contexto,
            confianza = excluded.confianza,
            estado = case when mejores_practicas.estado in ('refutada', 'archivada')
                          then mejores_practicas.estado else excluded.estado end,
            actualizado_en = now()
        returning id, (xmax = 0) into v_id, v_nueva;

        if v_nueva then
            insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
            values (p_agente_id, 'practica',
                    v_ag.nombre || case when v_evita then ' publica un error a evitar'
                                        else ' publica una práctica' end,
                    jsonb_build_object('practica_id', v_id, 'sentido', v_g.sentido));
        end if;
        v_n := v_n + 1;
    end loop;

    update public.agentes set destilado_en = now() where id = p_agente_id;
    return v_n;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- La decisión: cupo, cantidad y rotación
--
-- Mismo contrato que la 0013 (sin efectos, determinista). Cambios:
--   · el universo se evalúa ANTES de mirar si hay hueco, porque la
--     rotación necesita saber qué se dejaría pasar;
--   · el dimensionado recibe el cupo si la estrategia reparte;
--   · sin hueco o sin margen, y con rotación activa, compara la mejor
--     señal con el R:R RESTANTE de la posición más débil.
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
    v_cupo       numeric;
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
    v_margen_pct := case when v_equity > 0 then v_cuenta.saldo_bloqueado / v_equity * 100 else 100 end;
    if v_abiertas >= (v_p ->> 'max_posiciones_abiertas')::int then
        v_sin_hueco := 'sin_hueco';
    elsif v_margen_pct >= (v_p ->> 'margen_comprometido_max_pct')::numeric then
        v_sin_hueco := 'margen_lleno';
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
    -- 0016: el cupo, si la estrategia reparte.
    v_cupo   := case when v_p ->> 'reparto' = 'cupo'
                     then public.fn_cupo_pct((v_p ->> 'margen_comprometido_max_pct')::numeric,
                                             (v_p ->> 'max_posiciones_abiertas')::int) end;

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
               v_propio, v_tope, v_cupo, u.clase = 'accion') d
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
        'reparto', v_p -> 'reparto',
        'cupo_pct', v_cupo,
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

    if not exists (select 1 from jsonb_array_elements(v_cands) c where c ->> 'descarte' is null) then
        return v_base || jsonb_build_object('accion', 'sin_candidatos');
    end if;
    return v_base || jsonb_build_object('accion', 'abrir');
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Toma parcial automática de los agentes
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_agente_tomas_parciales(p_agente_id bigint)
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
        continue when v_o.precio_vivo < v_nivel or v_o.precio_vivo >= v_o.tp;

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

-- ═════════════════════════════════════════════════════════════════════
-- El ciclo, con rotación, tomas parciales y registro de decisiones
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

    if v_dec ->> 'accion' = 'abrir' then
        for v_c in select c from jsonb_array_elements(v_dec -> 'candidatos') c
                    where c ->> 'descarte' is null
                    order by (c ->> 'puesto')::int
        loop
            begin
                v_res := public.rpc_abrir_orden(
                    v_cuenta, (v_c ->> 'senal_id')::bigint, null, null,
                    (v_c ->> 'apalancamiento_pedido')::numeric,
                    (v_dec #>> '{parametros,riesgo_pct_operacion}')::numeric,
                    'agente',
                    (v_dec - 'parametros' - 'accion')
                        || jsonb_build_object('elegido', v_c, 'rechazos_servidor', v_rech,
                                              'parametros', v_dec -> 'parametros'),
                    -- 0016: el agente manda SU cantidad (con cupo o sin él).
                    (v_c ->> 'cantidad')::numeric);
                exit;
            exception when others then
                v_rech := v_rech || jsonb_build_object('simbolo', v_c ->> 'simbolo', 'motivo', sqlerrm);
                v_res := null;
            end;
        end loop;

        if v_res is not null then
            insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
            values (p_agente_id, 'reparto', (v_res ->> 'orden_id')::bigint,
                    jsonb_build_object('reparto', v_dec #> '{parametros,reparto}',
                                       'cupo_pct', v_dec -> 'cupo_pct'),
                    jsonb_build_object('margen', v_res -> 'margen'));
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
                                             'orden', v_res, 'rechazos', v_rech,
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
        v_salida := v_salida || jsonb_build_object('orden', v_res);
    end if;
    if jsonb_array_length(v_rech) > 0 then
        v_salida := v_salida || jsonb_build_object('rechazos', v_rech);
    end if;
    return v_salida;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Resolver decisiones contra su contrafactual
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_resolver_decisiones()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_d     record;
    v_o     public.ordenes;
    v_b     public.ordenes;
    v_a     public.activos;
    v_cf    numeric;
    v_pnl_b numeric;
    v_n     int := 0;
begin
    for v_d in select * from public.agente_decisiones where resuelta_en is null order by id
    loop
        select * into v_o from public.ordenes where id = v_d.orden_id;
        if not found then continue; end if;

        if v_d.tipo = 'reparto' then
            -- Retorno sobre el margen con el que se abrió: la moneda común
            -- para comparar concentrar con repartir.
            continue when v_o.estado <> 'cerrada';
            update public.agente_decisiones
               set efecto = round((v_o.pnl_bruto + v_o.pnl_parciales) * 100
                                  / nullif((v_d.datos ->> 'margen')::numeric, 0), 4),
                   resultado = jsonb_build_object('pnl_total', v_o.pnl_bruto + v_o.pnl_parciales,
                                                  'motivo_cierre', v_o.motivo_cierre),
                   resuelta_en = now()
             where id = v_d.id;
            v_n := v_n + 1;

        elsif v_d.tipo = 'parcial' then
            -- Sin la parcial, esa cantidad habría salido al precio final de
            -- la orden. Positivo = la parcial se adelantó a algo peor.
            continue when v_o.estado <> 'cerrada';
            update public.agente_decisiones
               set efecto = round((v_d.datos ->> 'cantidad_cerrada')::numeric
                                  * ((v_d.datos ->> 'precio_parcial')::numeric - v_o.precio_salida), 4),
                   resultado = jsonb_build_object('precio_salida', v_o.precio_salida,
                                                  'motivo_cierre', v_o.motivo_cierre),
                   resuelta_en = now()
             where id = v_d.id;
            v_n := v_n + 1;

        elsif v_d.tipo = 'rotacion' then
            -- Contrafactual de la cerrada: ¿qué habría hecho después? Se
            -- fija la primera vez que el precio toca un nivel, o a los 7
            -- días al precio de ese momento (ver cabecera).
            v_cf := (v_d.resultado ->> 'contrafactual')::numeric;
            if v_cf is null then
                select * into v_a from public.activos where id = v_o.activo_id;
                if v_a.ultimo_precio_en > v_d.creado_en then
                    v_cf := case
                        when v_a.ultimo_precio >= (v_d.datos ->> 'tp')::numeric
                            then (v_d.datos ->> 'cantidad')::numeric
                                 * ((v_d.datos ->> 'tp')::numeric - (v_d.datos ->> 'precio')::numeric)
                        when v_a.ultimo_precio <= (v_d.datos ->> 'sl')::numeric
                            then (v_d.datos ->> 'cantidad')::numeric
                                 * ((v_d.datos ->> 'sl')::numeric - (v_d.datos ->> 'precio')::numeric)
                        when v_d.creado_en < now() - interval '7 days'
                            then (v_d.datos ->> 'cantidad')::numeric
                                 * (v_a.ultimo_precio - (v_d.datos ->> 'precio')::numeric)
                    end;
                end if;
                if v_cf is not null then
                    update public.agente_decisiones
                       set resultado = coalesce(resultado, '{}'::jsonb)
                                       || jsonb_build_object('contrafactual', round(v_cf, 4))
                     where id = v_d.id;
                end if;
            end if;

            -- Lo que dio la nueva. Si no llegó a abrirse, cero.
            v_pnl_b := null;
            if v_d.orden_nueva_id is null then
                v_pnl_b := 0;
            else
                select * into v_b from public.ordenes where id = v_d.orden_nueva_id;
                if v_b.estado = 'cerrada' then
                    v_pnl_b := v_b.pnl_bruto + v_b.pnl_parciales;
                end if;
            end if;

            if v_cf is not null and v_pnl_b is not null then
                update public.agente_decisiones
                   set efecto = round(v_pnl_b - v_cf, 4),
                       resultado = coalesce(resultado, '{}'::jsonb)
                                   || jsonb_build_object('pnl_nueva', v_pnl_b),
                       resuelta_en = now()
                 where id = v_d.id;
                v_n := v_n + 1;
            end if;
        end if;
    end loop;
    return v_n;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Aprender: mover un parámetro, un paso, con evidencia
--
-- Cada regla mira solo las decisiones resueltas DESPUÉS de su último
-- ajuste del mismo tipo, así que cada cambio se apoya en evidencia nueva
-- y un parámetro no se mueve dos veces por los mismos datos.
--
--   rotación  (propia)      10 resueltas: media < 0 → umbral + 0,2 (máx 3)
--                                         media > 0 → umbral − 0,1 (mín 1,1)
--   parcial   (propia)      si la usa y 10 resueltas con media < 0 → la quita
--             (compartida)  si no la usa y 10 resueltas de OTROS con media
--                           > 0 → la adopta: mitad al 50 %, stop sin mover
--   reparto   (compartida)  10 resueltas de cada modo: si el otro rinde más
--                           que el suyo en un 10 % de su valor absoluto,
--                           cambia de modo
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_ajustar_parametros(p_agente_id bigint)
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

    -- ── Reparto ─────────────────────────────────────────────────────
    select coalesce(max(creado_en), '-infinity') into v_desde
      from public.agente_ajustes where agente_id = p_agente_id and tipo = 'reparto';
    v_modo := v_p ->> 'reparto';
    select count(*) filter (where parametro ->> 'reparto' = v_modo),
           avg(efecto) filter (where parametro ->> 'reparto' = v_modo),
           count(*) filter (where parametro ->> 'reparto' <> v_modo),
           avg(efecto) filter (where parametro ->> 'reparto' <> v_modo)
      into v_n, v_propio, v_n_otro, v_otro
      from public.agente_decisiones
     where tipo = 'reparto' and resuelta_en > v_desde;
    if v_n >= 10 and v_n_otro >= 10 and v_otro > v_propio + abs(v_propio) * 0.1 then
        v_nuevo := to_jsonb(case when v_modo = 'cupo' then 'concentrado' else 'cupo' end);
        insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
        values (p_agente_id, 'reparto', to_jsonb(v_modo), v_nuevo,
                jsonb_build_object('retorno_medio_propio_pct', round(v_propio, 4), 'decisiones_propio', v_n,
                                   'retorno_medio_otro_pct', round(v_otro, 4), 'decisiones_otro', v_n_otro));
        update public.agentes set estrategia = jsonb_set(estrategia, '{reparto}', v_nuevo)
         where id = p_agente_id;
        v_cambios := v_cambios + 1;
    end if;

    if v_cambios > 0 then
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'agente',
                v_ag.nombre || ' ajusta su estrategia con lo aprendido',
                jsonb_build_object('ajustes', v_cambios));
    end if;
    return v_cambios;
end;
$$;

-- El ciclo global resuelve primero las decisiones pendientes, para que
-- el ajuste de cada agente vea la evidencia más reciente.
create or replace function public.fn_ciclo_agentes()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id  bigint;
    v_out jsonb := '[]'::jsonb;
begin
    perform public.fn_agentes_observar_precios();
    perform public.fn_resolver_decisiones();
    for v_id in select id from public.agentes order by id
    loop
        begin
            v_out := v_out || public.fn_ciclo_agente(v_id);
        exception when others then
            v_out := v_out || jsonb_build_object('agente_id', v_id, 'error', sqlerrm);
            raise warning 'ciclo del agente % falló: %', v_id, sqlerrm;
        end;
    end loop;
    return v_out;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Semilla: los parámetros nuevos de cada perfil
--
--              reparto       rotación   toma parcial
--   Prudencia  cupo          ≥ 2,0×     mitad al 50 %, stop a la entrada
--   Cadencia   cupo          ≥ 1,5×     mitad al 50 %, stop sin mover
--   Audacia    concentrado   ≥ 1,2×     ninguna
--
-- Cambiar la estrategia sube su versión y la copia a la cuenta (triggers
-- de la 0013).
-- ═════════════════════════════════════════════════════════════════════
update public.agentes set estrategia = estrategia || jsonb_build_object(
    'reparto', 'cupo', 'rotacion_umbral', 2.0,
    'tp_parcial', jsonb_build_object('recorrido', 0.5, 'fraccion', 0.5, 'mover_stop', true))
 where nombre = 'Prudencia';
update public.agentes set estrategia = estrategia || jsonb_build_object(
    'reparto', 'cupo', 'rotacion_umbral', 1.5,
    'tp_parcial', jsonb_build_object('recorrido', 0.5, 'fraccion', 0.5, 'mover_stop', false))
 where nombre = 'Cadencia';
update public.agentes set estrategia = estrategia || jsonb_build_object(
    'reparto', 'concentrado', 'rotacion_umbral', 1.2, 'tp_parcial', null)
 where nombre = 'Audacia';

-- ═════════════════════════════════════════════════════════════════════
-- Vistas: las de la 0011/0013 con columnas nuevas AL FINAL, y dos nuevas
-- ═════════════════════════════════════════════════════════════════════
create or replace view public.v_mis_ordenes
with (security_invoker = true) as
    select o.id, o.cuenta_id, o.activo_id, o.senal_id, o.estado, o.origen,
           o.precio_entrada, o.fecha_entrada, o.cantidad, o.apalancamiento,
           o.nominal, o.margen_comprometido, o.tp, o.sl, o.precio_liquidacion,
           o.precio_salida, o.fecha_salida, o.motivo_cierre, o.precio_observado_cierre,
           o.pnl_bruto, o.pnl_pct, o.racional, o.creado_en,
           a.simbolo, a.clase, a.nombre, a.ultimo_precio, a.ultimo_precio_en,
           case when o.estado = 'abierta' and a.ultimo_precio is not null
                then round(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                    -o.margen_comprometido), 2)
           end as pnl_flotante,
           case when o.estado = 'abierta' and a.ultimo_precio is not null and o.margen_comprometido > 0
                then round(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                    -o.margen_comprometido) * 100 / o.margen_comprometido, 2)
           end as pnl_flotante_pct_margen,
           o.pnl_parciales, o.parcial_hecho, o.sl_original
      from public.ordenes o
      join public.activos a on a.id = o.activo_id
     where o.cuenta_id in (select id from public.cuentas_simulacion where usuario_id = auth.uid());

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
           o.pnl_parciales, o.parcial_hecho, o.sl_original
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id and c.agente_id is not null
      join public.agentes g on g.id = c.agente_id
      join public.activos a on a.id = o.activo_id;

create or replace view public.v_practicas_ranking
with (security_invoker = true) as
    select p.id, p.agente_autor_id, g.nombre as autor, p.titulo, p.contexto, p.regla,
           p.condiciones, p.resultado_observado, p.confianza, p.estado, p.creado_en, p.actualizado_en,
           coalesce(v.puntos, 0) as valoracion, coalesce(v.votos, 0) as votos,
           coalesce(ad.activas, 0) as adopciones_activas, coalesce(ad.total, 0) as adopciones,
           ad.adoptantes, p.sentido
      from public.mejores_practicas p
      join public.agentes g on g.id = p.agente_autor_id
      left join lateral (select sum(valoracion) as puntos, count(*) as votos
                           from public.mp_valoraciones where practica_id = p.id) v on true
      left join lateral (select count(*) filter (where abandonada_en is null) as activas,
                                count(*) as total,
                                array_agg(distinct g2.nombre) as adoptantes
                           from public.mp_adopciones x join public.agentes g2 on g2.id = x.agente_id
                          where x.practica_id = p.id) ad on true
     order by (p.estado = 'refutada'), coalesce(v.puntos, 0) desc, p.confianza desc, p.id;

create view public.v_decisiones_agentes
with (security_invoker = true) as
    select d.id, d.agente_id, g.nombre as agente, d.tipo, d.orden_id, d.orden_nueva_id,
           d.parametro, d.datos, d.resultado, d.efecto, d.creado_en, d.resuelta_en,
           a.simbolo
      from public.agente_decisiones d
      join public.agentes g on g.id = d.agente_id
      left join public.ordenes o on o.id = d.orden_id
      left join public.activos a on a.id = o.activo_id;

create view public.v_ajustes_agentes
with (security_invoker = true) as
    select j.id, j.agente_id, g.nombre as agente, j.tipo, j.de, j.a, j.evidencia, j.creado_en
      from public.agente_ajustes j
      join public.agentes g on g.id = j.agente_id;

-- ═════════════════════════════════════════════════════════════════════
-- RLS y privilegios
-- ═════════════════════════════════════════════════════════════════════
alter table public.ordenes_parciales  enable row level security;
alter table public.agente_decisiones  enable row level security;
alter table public.agente_ajustes     enable row level security;

create policy ordenes_parciales_propias on public.ordenes_parciales
    for select to authenticated
    using (public.es_usuario_aprobado()
           and orden_id in (select o.id from public.ordenes o
                              join public.cuentas_simulacion c on c.id = o.cuenta_id
                             where c.usuario_id = auth.uid() or c.agente_id is not null));
create policy agente_decisiones_aprobados on public.agente_decisiones
    for select to authenticated using (public.es_usuario_aprobado());
create policy agente_ajustes_aprobados on public.agente_ajustes
    for select to authenticated using (public.es_usuario_aprobado());

revoke insert, update, delete on public.ordenes_parciales, public.agente_decisiones,
       public.agente_ajustes from authenticated;
revoke all on public.ordenes_parciales, public.agente_decisiones, public.agente_ajustes from anon;

revoke execute on function public.fn_cerrar_parcial(bigint, numeric, numeric, text, numeric) from public, anon, authenticated;
revoke execute on function public.fn_practica_adoptable(jsonb, jsonb, text)   from public, anon, authenticated;
revoke execute on function public.fn_agente_tomas_parciales(bigint)           from public, anon, authenticated;
revoke execute on function public.fn_resolver_decisiones()                    from public, anon, authenticated;
revoke execute on function public.fn_ajustar_parametros(bigint)               from public, anon, authenticated;
revoke execute on function public.rpc_cerrar_parcial(bigint, numeric)         from public, anon;
grant  execute on function public.rpc_cerrar_parcial(bigint, numeric)         to authenticated;
