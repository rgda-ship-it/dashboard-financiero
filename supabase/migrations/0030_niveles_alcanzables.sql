-- ─────────────────────────────────────────────────────────────────────
-- 0030 — Niveles alcanzables y señales que no se contradicen (D21,
-- 2026-10-10).
--
-- Diagnóstico de 11 días en producción (113 operaciones de los agentes,
-- scripts/diagnostico_agentes.sql):
--
--   · 53 cierres en stop y NINGUNO en objetivo. Ninguna operación llegó
--     ni al 80 % del camino; la mediana del mejor recorrido fue 0,35 ATR.
--   · El stop era el mínimo de 20 velas y el objetivo el máximo. Al
--     ordenar por R:R, los agentes elegían el precio apoyado en el mínimo:
--     stops a 0,1–0,2 ATR (R:R de ~200) que saltaban en horas, y objetivos
--     a ~8 ATR que no se alcanzan en el horizonte de un agente.
--   · 65 de las 113 entradas contaban el RSI en sobreventa como alcista
--     con el MACD bajista (47 acabaron en el stop).
--
-- Lo que cambia en el MOTOR (motor-analitico, no aquí):
--   1. SL y TP se anclan al soporte y la resistencia pero se acotan en
--      ATR: el stop entre 1 y 2 ATR del precio, el objetivo como mucho a
--      2 ATR (y al menos a 0,5). El R:R pasa a ir de 0,25 a 2.
--   2. El RSI extremo solo vota si el MACD no lo contradice.
--
-- Lo que cambia AQUÍ, por coherencia con lo anterior:
--   a. R:R mínimo de los agentes en la escala nueva. Con un R:R máximo de
--      2, el 2,0 de Prudencia solo lo cumpliría una señal con el soporte a
--      exactamente 1 ATR y la resistencia a 2 o más: ser prudente no puede
--      ser no operar. Prudencia 2,0 → 1,5 y Cadencia 1,5 → 1,3; Audacia
--      sigue en 1,2. La prudencia de Prudencia sigue en su riesgo por
--      operación, su tope de 3×, solo acciones, solo estructura y ATR ≤ 3.
--   b. Las prácticas con condición de R:R se archivan y sus adopciones se
--      abandonan: se destilaron sobre la escala vieja (tramo «alto» = R:R
--      ≥ 2,5, que ahora no existe) y su tramo «medio» descartaría justo
--      las mejores señales de la escala nueva. La destilación conserva el
--      estado «archivada» si la misma firma vuelve a salir de órdenes
--      antiguas (0021, `on conflict`).
--
--   c. Riesgo abierto total (G6, aprobado por el dueño): lo que arriesgan
--      a la vez las posiciones abiertas de un agente no pasa de 4 × su
--      riesgo por operación. Lo respeta la decisión (motivo nuevo
--      `riesgo_lleno`) y lo impone un trigger al insertar la orden.
--
-- Las posiciones abiertas conservan sus niveles: se abrieron con ellos.
-- Cada stop pasa a costar lo que declara el agente (su riesgo por
-- operación): con el stop a 1 ATR el tamaño ya no lo limita el saldo,
-- sino el riesgo. Antes, con stops a 0,1 % del precio, cada stop costaba
-- céntimos porque la posición topaba con el saldo mucho antes.
-- ─────────────────────────────────────────────────────────────────────

-- a. R:R mínimo en la escala nueva. El trigger de versiones sube la
-- versión de cada estrategia y el de sincronización lo lleva a su cuenta.
update public.agentes
   set estrategia = jsonb_set(estrategia, '{rr_minimo}', '1.5'::jsonb)
 where nombre = 'Prudencia';

update public.agentes
   set estrategia = jsonb_set(estrategia, '{rr_minimo}', '1.3'::jsonb)
 where nombre = 'Cadencia';

-- b. Prácticas sobre la escala vieja de R:R.
do $practicas$
declare
    v_archivadas int;
    v_abandonos  int;
    v_ag         bigint;
begin
    with archivadas as (
        update public.mejores_practicas
           set estado = 'archivada', actualizado_en = now()
         where condiciones ? 'ratio_rr'
           and estado in ('propuesta', 'validada')
        returning id
    )
    select count(*) into v_archivadas from archivadas;

    with abandonos as (
        update public.mp_adopciones ad
           set abandonada_en = now()
          from public.mejores_practicas p
         where p.id = ad.practica_id
           and p.condiciones ? 'ratio_rr'
           and ad.abandonada_en is null
        returning ad.agente_id
    )
    select count(*) into v_abandonos from abandonos;

    for v_ag in select id from public.agentes loop
        perform public.fn_espejar_practicas(v_ag);
    end loop;

    insert into public.eventos_sistema (tipo, mensaje, datos)
    values ('sys',
            'Niveles acotados en ATR: R:R mínimo de los agentes en la escala nueva y prácticas de R:R archivadas',
            jsonb_build_object('migracion', '0030', 'practicas_archivadas', v_archivadas,
                               'adopciones_abandonadas', v_abandonos,
                               'rr_minimo', jsonb_build_object('Prudencia', 1.5, 'Cadencia', 1.3,
                                                               'Audacia', 1.2)));
end
$practicas$;

-- ═════════════════════════════════════════════════════════════════════
-- c. Riesgo abierto total (aprobado por el dueño el 2026-10-10)
-- ═════════════════════════════════════════════════════════════════════
-- Con stops a 1–2 ATR cada stop cuesta el riesgo completo por operación,
-- y el reparto abre varias posiciones en el mismo ciclo: Audacia con 5
-- arriesgaría a la vez el 12,5 % de su saldo, en activos que suelen caer
-- juntos. No es un límite de pérdida diaria (el dueño lo descartó): limita
-- lo que está en juego A LA VEZ y se libera al cerrar o al mover el stop.
--
-- Lo impone la decisión (no propone lo que no cabe) y, como todo
-- guardarraíl, también PostgreSQL al insertar la orden (G6): el agente
-- propone, la base de datos dispone.

create function public.fn_multiplo_riesgo_abierto()
returns numeric
language sql immutable
as $$ select 4.0 $$;

comment on function public.fn_multiplo_riesgo_abierto() is
  'G6 (0030): el riesgo abierto de un agente no pasa de este múltiplo de su riesgo por operación.';

-- Lo que perdería la cuenta si todas sus posiciones abiertas tocaran el
-- stop ahora. Un stop movido a la entrada (toma parcial) ya no arriesga.
create function public.fn_riesgo_abierto(p_cuenta_id bigint)
returns numeric
language sql stable
as $$
    select coalesce(sum(greatest(o.cantidad * (o.precio_entrada - o.sl), 0)), 0)
      from public.ordenes o
     where o.cuenta_id = p_cuenta_id and o.estado = 'abierta'
$$;

create function public.fn_g6_riesgo_abierto()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_equity  numeric;
    v_max     numeric;
    v_abierto numeric;
    v_nuevo   numeric;
begin
    select a.* into v_ag
      from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id
     where c.id = new.cuenta_id;
    if not found then
        return new;      -- cuentas de usuario: no aplica
    end if;

    v_equity  := public.fn_equity(new.cuenta_id);
    v_max     := v_equity * (public.fn_parametros_agente(v_ag) ->> 'riesgo_pct_operacion')::numeric
                 * public.fn_multiplo_riesgo_abierto() / 100;
    v_abierto := public.fn_riesgo_abierto(new.cuenta_id);
    v_nuevo   := greatest(new.cantidad * (new.precio_entrada - new.sl), 0);

    if v_abierto + v_nuevo > v_max + 0.01 then
        raise exception 'G6: con esta orden el riesgo abierto sería % $, por encima de % $ (% × el riesgo por operación).',
              round(v_abierto + v_nuevo, 2), round(v_max, 2), public.fn_multiplo_riesgo_abierto()
              using errcode = 'P0001';
    end if;
    return new;
end;
$$;

create trigger ordenes_g6_riesgo_abierto
    before insert on public.ordenes
    for each row when (new.estado = 'abierta')
    execute function public.fn_g6_riesgo_abierto();

revoke execute on function public.fn_multiplo_riesgo_abierto() from public, anon, authenticated;
revoke execute on function public.fn_riesgo_abierto(bigint)   from public, anon, authenticated;
revoke execute on function public.fn_g6_riesgo_abierto()      from public, anon, authenticated;

-- La decisión: la de la 0023 con el riesgo abierto. Nuevo motivo para no
-- abrir, `riesgo_lleno`, que como `saldo_lleno` permite rotar.
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
                   (mk.c ->> 'precio')::numeric, (mk.c ->> 'sl')::numeric,
                   -- 0030: entre las k marcadas no arriesgan más que el
                   -- riesgo abierto que queda libre.
                   least(v_riesgo, v_heat_libre_pct / v_k),
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
