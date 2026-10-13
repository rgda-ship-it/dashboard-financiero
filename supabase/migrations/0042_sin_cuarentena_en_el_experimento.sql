-- ─────────────────────────────────────────────────────────────────────
-- 0042 — Los agentes con metas salen de la cuarentena (2026-10-13).
--
-- Las semanas W40 y W41 fueron deficientes (0 días con la meta cumplida),
-- así que por la regla del doc 03 §6.2 los tres agentes con metas
-- quedaron con el riesgo a la mitad y, desde el 12-10, en cuarentena:
-- una posición a la vez y solo señales de fuerza alta. El lunes 12
-- descartaron unas 1.400 señales cada uno por «fuerza», y no abren nada
-- desde el 09-10.
--
-- Las metas no se alcanzan por diseño (doc 05: 2 % diario son × 147 al
-- año), así que cada semana sale deficiente y la cuarentena es
-- permanente. Con ella no se puede ver el efecto de las mejoras de las
-- 0030–0036 (niveles en ATR, G6, cripto prudente, huecos, spread), que
-- se midieron con los agentes operando normalmente. Decisión del dueño:
--   1. Los tres vuelven a `activo` y con el riesgo completo.
--   2. Mientras dure el experimento, el corte semanal sigue calculando la
--      nota, guardándola y abriendo su entrada en el backlog, pero no
--      reduce el riesgo ni pone en cuarentena: `consecuencias_semanales`
--      queda en false para los agentes con metas. Al acabar el
--      experimento basta con volver a ponerla en true.
-- Las reglas de decisión de los agentes no cambian.
-- ─────────────────────────────────────────────────────────────────────

alter table public.agentes
    add column consecuencias_semanales boolean not null default true;

comment on column public.agentes.consecuencias_semanales is
  'Si el corte semanal aplica sus consecuencias (riesgo a la mitad tras una deficiente, cuarentena tras dos). La nota se calcula siempre. False en los agentes con metas durante el experimento (0042).';

create or replace function public.fn_corte_semanal_agente(p_agente_id bigint, p_lunes date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag        public.agentes;
    v_semana    text := to_char(p_lunes, 'IYYY-"W"IW');
    v_fin       date := p_lunes + 6;
    v_ops       int;
    v_cumpl     int;
    v_ratio     numeric;
    v_ver       text;
    v_ini       numeric;
    v_fin_saldo numeric;
    v_dd        numeric;
    v_accion    jsonb := '{}'::jsonb;
    v_previa    text;
    v_pract     bigint;
    v_puede     boolean;
    v_penaliza  boolean;
    v_f         date;
    v_cuenta    bigint;
begin
    select * into v_ag from public.agentes where id = p_agente_id for update;
    if exists (select 1 from public.agente_semanas where agente_id = p_agente_id and semana_iso = v_semana) then
        return jsonb_build_object('agente', v_ag.nombre, 'semana', v_semana, 'ya_evaluada', true);
    end if;

    -- Los días de la semana que ningún ciclo cerró se cierran ahora.
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    for v_f in select fecha from public.agente_dias
                where agente_id = p_agente_id and fecha <= v_fin and cerrado_en is null
                  and fecha < (now() at time zone 'UTC')::date
                order by fecha
    loop
        perform public.fn_cerrar_dia_agente(p_agente_id, v_f, public.fn_equity(v_cuenta));
    end loop;

    -- N10: el denominador son los días OPERABLES, nunca 7.
    select count(*) filter (where operable),
           count(*) filter (where operable and cumplido),
           (array_agg(saldo_apertura order by fecha))[1],
           (array_agg(coalesce(saldo_cierre, saldo_apertura) order by fecha desc))[1]
      into v_ops, v_cumpl, v_ini, v_fin_saldo
      from public.agente_dias
     where agente_id = p_agente_id and fecha between p_lunes and v_fin;

    select min((coalesce(saldo_cierre, saldo_apertura) / nullif(pico, 0) - 1) * 100) into v_dd
      from (select saldo_cierre, saldo_apertura,
                   max(greatest(saldo_apertura, coalesce(saldo_cierre, 0)))
                       over (order by fecha rows between unbounded preceding and current row) as pico
              from public.agente_dias
             where agente_id = p_agente_id and fecha between p_lunes and v_fin) t;

    if v_ops = 0 then
        v_ver := 'sin_datos';
    else
        v_ratio := round(v_cumpl::numeric / v_ops, 4);
        v_ver := case when v_ratio >= 0.70 then 'validada'
                      when v_ratio >= 0.40 then 'aviso'
                      else 'deficiente' end;
    end if;

    -- Un agente en pausa o en Game Over recibe nota pero no cambia de
    -- estado: sacarlo de la pausa desde aquí sería un arranque que no ha
    -- decidido nadie.
    v_puede := v_ag.estado in ('activo', 'cuarentena');
    -- 0042: durante el experimento, la nota no reduce el riesgo ni pone
    -- en cuarentena (agentes.consecuencias_semanales).
    v_penaliza := v_ag.consecuencias_semanales;

    -- ── Consecuencias (doc 03 §6.2) ──────────────────────────────────
    if v_ver = 'validada' then
        update public.agentes set riesgo_reducido = false,
               estado = case when estado = 'cuarentena' then 'activo' else estado end
         where id = p_agente_id;
        v_accion := jsonb_build_object('riesgo_restaurado', v_ag.riesgo_reducido,
                                       'sale_de_cuarentena', v_ag.estado = 'cuarentena',
                                       'practicas_destiladas', public.fn_destilar_practicas(p_agente_id));
    elsif v_ver in ('aviso', 'deficiente') then
        v_pract := public.fn_adoptar_practica(p_agente_id);
        v_accion := jsonb_build_object('practica_adoptada', v_pract);
    end if;

    if v_ver = 'deficiente' then
        if v_penaliza then
            update public.agentes set riesgo_reducido = true where id = p_agente_id;
        end if;
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla',
            'ajuste_regla:semana_deficiente:agente_' || p_agente_id,
            'Revisar la estrategia de ' || v_ag.nombre,
            format('Semana %s deficiente: %s de %s días operables cumplidos.', v_semana, v_cumpl, v_ops),
            'Una semana por debajo del 40 % de cumplimiento reduce el riesgo a la mitad; si se repite, cuarentena.',
            jsonb_build_object('semana', v_semana, 'dias_operables', v_ops, 'dias_cumplidos', v_cumpl,
                               'ratio', v_ratio, 'saldo_inicio', v_ini, 'saldo_fin', v_fin_saldo), 3);
        v_accion := v_accion || case when v_penaliza
                                     then jsonb_build_object('riesgo_reducido', true)
                                     else jsonb_build_object('consecuencias_suspendidas', true) end;

        select veredicto into v_previa from public.agente_semanas
         where agente_id = p_agente_id and fecha_inicio = p_lunes - 7;
        if v_previa = 'deficiente' and v_puede and v_penaliza then
            update public.agentes set estado = 'cuarentena' where id = p_agente_id;
            v_accion := v_accion || jsonb_build_object('cuarentena', true);
        end if;
    end if;

    v_accion := v_accion || jsonb_build_object('adopciones_evaluadas', public.fn_evaluar_adopciones(p_agente_id));

    insert into public.agente_semanas
        (agente_id, semana_iso, fecha_inicio, fecha_fin, dias_operables, dias_cumplidos,
         ratio_cumplimiento, veredicto, saldo_inicio, saldo_fin, rendimiento_semanal_pct,
         drawdown_semanal_pct, accion_correctiva)
    values (p_agente_id, v_semana, p_lunes, v_fin, v_ops, v_cumpl, v_ratio, v_ver,
            v_ini, v_fin_saldo,
            case when v_ini > 0 then round((v_fin_saldo / v_ini - 1) * 100, 4) end,
            round(v_dd, 4), v_accion);

    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'corte_semanal',
            format('%s · semana %s: %s (%s/%s días)', v_ag.nombre, v_semana,
                   replace(v_ver, '_', ' '), v_cumpl, v_ops),
            jsonb_build_object('semana', v_semana, 'veredicto', v_ver, 'ratio', v_ratio,
                               'accion_correctiva', v_accion));

    return jsonb_build_object('agente', v_ag.nombre, 'semana', v_semana, 'veredicto', v_ver,
                              'dias_operables', v_ops, 'dias_cumplidos', v_cumpl,
                              'accion_correctiva', v_accion);
end;
$$;

-- Liberación. Un agente pausado desde la cuarentena vuelve a la pausa
-- normal: al reanudarlo, queda activo. El trigger de la cuenta recoge el
-- riesgo y las posiciones.
do $liberar$
declare
    v_liberados jsonb;
begin
    with antes as (
        select id, nombre, estado, estado_previo, riesgo_reducido
          from public.agentes where tipo = 'metas'
    ), cambio as (
        update public.agentes a
           set consecuencias_semanales = false,
               riesgo_reducido = false,
               estado = case when a.estado = 'cuarentena' then 'activo' else a.estado end,
               estado_previo = case when a.estado_previo = 'cuarentena' then 'activo' else a.estado_previo end
          from antes
         where a.id = antes.id
        returning a.id
    )
    select coalesce(jsonb_agg(jsonb_build_object('agente', antes.nombre, 'estado', antes.estado,
                                                 'riesgo_reducido', antes.riesgo_reducido)
                              order by antes.id), '[]'::jsonb)
      into v_liberados
      from antes join cambio on cambio.id = antes.id;

    insert into public.eventos_sistema (tipo, mensaje, datos)
    values ('sys',
            'Agentes con metas fuera de la cuarentena y con el riesgo completo; el corte semanal no aplica consecuencias durante el experimento',
            jsonb_build_object('migracion', '0042', 'antes', v_liberados));
end
$liberar$;
