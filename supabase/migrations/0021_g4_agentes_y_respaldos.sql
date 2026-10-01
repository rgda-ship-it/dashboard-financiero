-- ─────────────────────────────────────────────────────────────────────
-- 0021 — G4 solo para los agentes, y prácticas que se respaldan en vez
-- de duplicarse (2026-10-01).
--
-- 1. G4 («posiciones abiertas ≤ máximo») ESTORBABA EN LA CUENTA DEL
--    USUARIO. Con tres posiciones de acciones no se podía abrir una cripto,
--    y el mensaje («tres posiciones en el mismo mercado…») afirmaba algo que
--    no comprobaba: contaba todas. Desde la 0016 lo que reparte el capital
--    es el cupo (margen máx ÷ posiciones) y lo que acota la exposición es
--    G3 (margen total) y G2 (riesgo por operación). Así que en una cuenta de
--    usuario `max_posiciones_abiertas` pasa a ser SOLO el divisor del
--    reparto («repartir el margen en N posiciones»), y G4 se aplica solo a
--    los agentes, donde forma parte de su perfil y sostiene la rotación.
--
-- 2. LA MISMA PRÁCTICA, PUBLICADA DOS VECES. Cada agente destilaba la suya
--    aunque otro ya hubiera publicado la misma firma (Cadencia y Audacia).
--    Ahora el segundo la RESPALDA (`fn_respaldar_practica`): suma su
--    evidencia en `resultado_observado.respaldos`, se recalcula la
--    confianza con las operaciones de todos, cuenta como valoración +1 y el
--    agente queda en `coautores`. Los duplicados que ya existían se funden
--    en el más antiguo, y sus adopciones activas se trasladan a él.
-- ─────────────────────────────────────────────────────────────────────

comment on column public.cuentas_simulacion.max_posiciones_abiertas is
  'Agentes: G4, máximo de posiciones abiertas a la vez. Usuarios (desde 0021): solo el divisor del cupo sugerido (margen máx ÷ posiciones); no limita cuántas se abren.';

alter table public.mejores_practicas add column coautores bigint[] not null default '{}';

-- ═════════════════════════════════════════════════════════════════════
-- Respaldo de una práctica ajena
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_respaldar_practica(p_practica_id bigint, p_agente_id bigint, p_stats jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_p     public.mejores_practicas;
    v_r     jsonb;
    v_ops   numeric;
    v_ok    numeric;
    v_nuevo boolean;
    v_nom   text;
begin
    select * into v_p from public.mejores_practicas where id = p_practica_id for update;
    v_nuevo := not (p_agente_id = any(v_p.coautores));

    -- La evidencia del autor queda arriba, como siempre; la de cada
    -- respaldo, en `respaldos`, por agente (se sobrescribe al destilar de
    -- nuevo, no se acumula dos veces).
    -- (jsonb_set no crea la clave intermedia `respaldos` si aún no existe.)
    v_r := coalesce(v_p.resultado_observado, '{}'::jsonb)
           || jsonb_build_object('respaldos',
                  coalesce(v_p.resultado_observado -> 'respaldos', '{}'::jsonb)
                  || jsonb_build_object(p_agente_id::text, p_stats));

    -- Confianza sobre TODAS las operaciones: las del autor y las de cada
    -- respaldo. Para «evitar» cuenta el acierto del stop; para «exigir», el
    -- del objetivo (mismo criterio que la destilación).
    select sum((x ->> 'ops')::numeric),
           sum((x ->> case when v_p.sentido = 'evitar' then 'sl' else 'tp' end)::numeric)
      into v_ops, v_ok
      from (select v_r - 'respaldos' as x
            union all
            select value from jsonb_each(v_r -> 'respaldos')) t;

    update public.mejores_practicas
       set resultado_observado = v_r,
           coautores = case when v_nuevo then coautores || p_agente_id else coautores end,
           confianza = round(v_ok / nullif(v_ops, 0), 3),
           estado = case when v_ops >= 10 and estado = 'propuesta' then 'validada' else estado end,
           actualizado_en = now()
     where id = p_practica_id;

    if v_nuevo then
        perform public.fn_valorar_practica(p_practica_id, p_agente_id, 1::smallint,
            'Respaldo: la destiló por su cuenta con la misma firma');
        select nombre into v_nom from public.agentes where id = p_agente_id;
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'practica', v_nom || ' respalda una práctica que ya existía',
                jsonb_build_object('practica_id', p_practica_id));
    end if;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- rpc_abrir_orden: la de la 0016 con el bloque G4 condicionado
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

    -- ── G4 · Solo para los agentes (0021) ───────────────────────────
    -- En una cuenta de usuario el número de posiciones ya no es un límite:
    -- con el cupo (margen ÷ posiciones) y el tope de margen comprometido
    -- (G3), lo que acota la exposición es el margen, no el recuento. Para
    -- un agente sigue siendo parte de su perfil: su rotación se apoya en
    -- «no hay hueco». El mensaje antiguo decía «en el mismo mercado» sin
    -- comprobarlo; contaba todas las posiciones.
    select count(*) into v_abiertas
      from public.ordenes where cuenta_id = p_cuenta_id and estado = 'abierta';
    if v_cuenta.agente_id is not null and v_abiertas >= v_cuenta.max_posiciones_abiertas then
        raise exception 'El agente ya tiene % posiciones abiertas (máximo % en su perfil).',
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

-- ═════════════════════════════════════════════════════════════════════
-- Destilación: la de la 0016, respaldando en vez de duplicar
-- ═════════════════════════════════════════════════════════════════════
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
    v_firma text;
    v_ajena public.mejores_practicas;
    v_stats jsonb;
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
        v_firma := case when v_evita then 'evitar|' else '' end
                   || concat_ws('|', v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr);
        v_stats := jsonb_build_object('ops', v_g.ops, 'tp', v_g.tp, 'sl', v_g.sl,
                                      'pnl_medio_pct', v_g.pnl_medio_pct, 'rr_medio', v_g.rr_medio,
                                      'ordenes', v_g.ordenes);

        -- 0021 · Si OTRO agente ya publicó esta misma firma, no se duplica:
        -- se RESPALDA. La evidencia se suma, la confianza se recalcula con
        -- las operaciones de todos, el respaldo cuenta como una valoración
        -- a favor y el agente queda como coautor. Dos agentes que llegan
        -- por su cuenta a la misma regla son la mejor evidencia de que
        -- funciona; dos filas iguales solo la dividían.
        select * into v_ajena from public.mejores_practicas
         where firma = v_firma and sentido = v_g.sentido
           and agente_autor_id <> p_agente_id
           and estado in ('propuesta', 'validada')
         order by id limit 1;
        if v_ajena.id is not null then
            perform public.fn_respaldar_practica(v_ajena.id, p_agente_id, v_stats);
            v_n := v_n + 1;
            continue;
        end if;

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

-- Adoptar: ni las propias ni las que el agente ya respalda como coautor.
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
       and not (p_agente_id = any(p.coautores))
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

-- ═════════════════════════════════════════════════════════════════════
-- Fundir los duplicados que ya existían
-- ═════════════════════════════════════════════════════════════════════
-- Una función y no un bloque suelto, para que la invariante I65 la pueda
-- ejercitar con duplicados de verdad (en la CI, al migrar, no hay ninguno).
create function public.fn_fundir_practicas_duplicadas()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_d    record;
    v_prin bigint;
    v_ad   record;
    v_n    int := 0;
begin
    for v_d in
        select p.id, p.agente_autor_id, p.firma, p.sentido, p.resultado_observado,
               first_value(p.id) over (partition by p.firma, p.sentido order by p.id) as principal
          from public.mejores_practicas p
         where p.estado in ('propuesta', 'validada')
    loop
        continue when v_d.id = v_d.principal;
        v_prin := v_d.principal;
        -- La evidencia del duplicado pasa a ser un respaldo del principal.
        perform public.fn_respaldar_practica(v_prin, v_d.agente_autor_id, v_d.resultado_observado - 'respaldos');

        -- Sus adopciones activas se trasladan, salvo que el adoptante ya
        -- sea autor o coautor del principal, o ya lo tenga adoptado.
        for v_ad in select * from public.mp_adopciones
                     where practica_id = v_d.id and abandonada_en is null
        loop
            if exists (select 1 from public.mejores_practicas p
                        where p.id = v_prin
                          and (p.agente_autor_id = v_ad.agente_id or v_ad.agente_id = any(p.coautores)))
               or exists (select 1 from public.mp_adopciones x
                           where x.practica_id = v_prin and x.agente_id = v_ad.agente_id
                             and x.abandonada_en is null) then
                update public.mp_adopciones
                   set abandonada_en = now(),
                       resultado = coalesce(resultado, '{}'::jsonb) || '{"motivo": "fundida_en_otra_practica"}'
                 where id = v_ad.id;
            else
                update public.mp_adopciones set practica_id = v_prin where id = v_ad.id;
            end if;
            perform public.fn_espejar_practicas(v_ad.agente_id);
        end loop;

        update public.mejores_practicas
           set estado = 'archivada',
               contexto = contexto || format(' (Fundida en la práctica #%s, 0021.)', v_prin),
               actualizado_en = now()
         where id = v_d.id;
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$;

select public.fn_fundir_practicas_duplicadas();

-- La vista de lectura, con los coautores AL FINAL.
create or replace view public.v_practicas_ranking
with (security_invoker = true) as
    select p.id, p.agente_autor_id, g.nombre as autor, p.titulo, p.contexto, p.regla,
           p.condiciones, p.resultado_observado, p.confianza, p.estado, p.creado_en, p.actualizado_en,
           coalesce(v.puntos, 0) as valoracion, coalesce(v.votos, 0) as votos,
           coalesce(ad.activas, 0) as adopciones_activas, coalesce(ad.total, 0) as adopciones,
           ad.adoptantes, p.sentido,
           (select array_agg(g3.nombre order by g3.id) from public.agentes g3
             where g3.id = any(p.coautores)) as coautores
      from public.mejores_practicas p
      join public.agentes g on g.id = p.agente_autor_id
      left join lateral (select sum(valoracion) as puntos, count(*) as votos
                           from public.mp_valoraciones where practica_id = p.id) v on true
      left join lateral (select count(*) filter (where abandonada_en is null) as activas,
                                count(*) as total,
                                array_agg(distinct g2.nombre) as adoptantes
                           from public.mp_adopciones x join public.agentes g2 on g2.id = x.agente_id
                          where x.practica_id = p.id) ad on true
     order by (p.estado in ('refutada', 'archivada')), coalesce(v.puntos, 0) desc, p.confianza desc, p.id;

revoke execute on function public.fn_respaldar_practica(bigint, bigint, jsonb) from public, anon, authenticated;
revoke execute on function public.fn_fundir_practicas_duplicadas()          from public, anon, authenticated;
