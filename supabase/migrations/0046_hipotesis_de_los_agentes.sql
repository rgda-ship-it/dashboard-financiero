-- ─────────────────────────────────────────────────────────────────────
-- 0046 — Los agentes proponen hipótesis (Fase 3, I1; doc fase-3/01).
--
-- La meta diaria no hacía que los agentes aprendieran: lo que «pedían»
-- salía de siete plantillas escritas de antemano, y la evidencia que
-- produce cada decisión no la usaba nadie. Desde aquí, cada lunes, cada
-- agente con metas propone como mucho UNA hipótesis sacada de su propia
-- evidencia, con el experimento que la pondría a prueba y el criterio
-- para juzgarla, fijados antes de ver el resultado:
--
--   · H1 · Decisiones que cuestan: un tipo de decisión (deterioro, toma
--     parcial, rotación) con al menos 20 resueltas en 90 días y un efecto
--     medio negativo cuyo intervalo del 90 % no incluye el cero.
--   · H2 · Movimientos perdidos: subidas de 3 ATR o más en 5 sesiones en
--     su universo en las que no entró. Busca la condición del catálogo
--     (o el par de condiciones) que se cumplía al empezar la mayoría de
--     ellas y pocos días en general.
--   · H4 · Plantillas medibles: «cierre parcial» y «trailing stop» del
--     backlog, convertidas en un experimento.
--
-- Nada de esto cambia cómo operan: son el grupo de control. La prueba en
-- el laboratorio llega en la I3 (`hipotesis.yml`); hasta entonces las
-- hipótesis quedan `propuesta`. El catálogo de condiciones es el mismo
-- que `CONDICIONES` en `motor-analitico/laboratorio/estrategias.py`.
-- ─────────────────────────────────────────────────────────────────────

create table public.agente_hipotesis (
    id             bigserial primary key,
    agente_id      bigint not null references public.agentes(id) on delete cascade,
    origen         text not null check (origen in ('decision', 'movimiento', 'descarte', 'plantilla', 'llm')),
    clave          text not null,
    semana         date not null,
    enunciado      text not null,
    evidencia      jsonb not null,
    experimento    jsonb not null,
    criterio       jsonb not null,
    estado         text not null default 'propuesta' check (estado in (
                       'propuesta', 'en_prueba', 'validada', 'refutada', 'no_ejecutable',
                       'adoptada', 'archivada')),
    resultado      jsonb,
    informe_url    text,
    resolucion     text,
    revisado_por   uuid,
    revisado_en    timestamptz,
    creado_en      timestamptz not null default now(),
    actualizado_en timestamptz not null default now()
);

comment on table public.agente_hipotesis is
    'Lo que cada agente propone probar, con su evidencia, el experimento y el criterio fijado antes del resultado (doc fase-3/01 §4).';

-- Una por agente y semana: el freno a la búsqueda a ciegas.
create unique index agente_hipotesis_una_por_semana on public.agente_hipotesis (agente_id, semana);
-- La misma idea no se propone dos veces mientras siga viva.
create unique index agente_hipotesis_viva on public.agente_hipotesis (agente_id, clave)
    where estado in ('propuesta', 'en_prueba', 'validada', 'no_ejecutable', 'adoptada');

alter table public.agente_hipotesis enable row level security;
create policy agente_hipotesis_aprobados on public.agente_hipotesis
    for select to authenticated using (public.es_usuario_aprobado());
revoke insert, update, delete on public.agente_hipotesis from authenticated;
revoke all on public.agente_hipotesis from anon;

alter table public.auditoria_admin drop constraint auditoria_admin_accion_check;
alter table public.auditoria_admin add constraint auditoria_admin_accion_check check (accion in (
    'aprobar_usuario', 'rechazar_usuario', 'suspender_usuario', 'revertir_fase',
    'resolver_backlog', 'reiniciar_agente', 'cambiar_estado_agente', 'resolver_hipotesis'));

-- ═════════════════════════════════════════════════════════════════════
-- Condiciones del catálogo y movimientos, por activo y día
-- ═════════════════════════════════════════════════════════════════════
-- Mismas definiciones que el laboratorio: máximo de los 20 días ANTERIORES
-- y volumen relativo a la media de 20 días que incluye el de hoy.
-- «movimiento»: el cierre 5 sesiones después supera al de hoy en 3 ATR.
create view public.v_condiciones_dia
with (security_invoker = true) as
with d as (
    select p.activo_id, a.clase, a.simbolo, p.fecha, p.cierre, i.atr_14, i.sma_50, i.sma_200,
           i.rsi_14, i.macd_hist,
           -- Solo máximos reales (ver v_velas_con_rango): en cripto, las
           -- velas reconstruidas no tienen rango.
           max(case when p.rango_real then p.maximo end) over w20_previos as max_20,
           p.volumen / nullif(avg(p.volumen) over w20, 0) as vol_rel,
           lead(p.cierre, 5) over w as cierre_5,
           lead(p.fecha, 5) over w as fecha_5
      from public.precios_diarios p
      join public.activos a on a.id = p.activo_id
      join public.indicadores_diarios i on i.activo_id = p.activo_id and i.fecha = p.fecha
    window w as (partition by p.activo_id order by p.fecha),
           w20 as (partition by p.activo_id order by p.fecha rows between 19 preceding and current row),
           w20_previos as (partition by p.activo_id order by p.fecha rows between 20 preceding and 1 preceding)
)
select activo_id, clase, simbolo, fecha, cierre, atr_14, cierre_5, fecha_5,
       round((cierre_5 - cierre) / nullif(atr_14, 0), 2) as atr_en_5,
       coalesce((cierre_5 - cierre) / nullif(atr_14, 0) >= 3, false) as movimiento,
       array_remove(array[
           case when cierre > sma_50 then 'sobre_sma50' end,
           case when cierre > sma_200 then 'sobre_sma200' end,
           case when sma_50 > sma_200 then 'cruce_medias' end,
           case when macd_hist > 0 then 'macd_positivo' end,
           case when rsi_14 between 50 and 70 then 'rsi_50_70' end,
           case when rsi_14 < 35 then 'rsi_bajo_35' end,
           case when cierre > max_20 then 'ruptura_20' end,
           case when vol_rel > 1.5 then 'volumen_alto' end], null) as condiciones
  from d;

comment on view public.v_condiciones_dia is
    'Condiciones del catálogo de hipótesis (las mismas que CONDICIONES del laboratorio) y si empezó un movimiento de 3 ATR en 5 sesiones.';

grant select on public.v_condiciones_dia to authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- El generador
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_generar_hipotesis(p_agente_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_semana  date := date_trunc('week', now() at time zone 'UTC')::date;
    v_desde   date;
    v_previas int;
    v_crit    jsonb;
    v_r       record;
    v_c       record;
    v_id      bigint;
    v_origen  text;
    v_clave   text;
    v_texto   text;
    v_evid    jsonb;
    v_cambio  jsonb;
    v_clases  jsonb;
    v_estado  text := 'propuesta';
    v_resol   text;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    if not found or v_ag.tipo <> 'metas' then
        return null;
    end if;
    if exists (select 1 from public.agente_hipotesis where agente_id = p_agente_id and semana = v_semana) then
        return null;
    end if;
    v_p := public.fn_parametros_agente(v_ag);
    v_clases := coalesce(v_p -> 'clases_admitidas', '[]'::jsonb);
    v_desde := greatest(v_ag.creado_en::date, (now() at time zone 'UTC')::date - 90);

    -- El percentil exigido frente al azar sube con las pruebas acumuladas
    -- de todos los agentes (doc fase-3/01 §5): lo aplica la I3.
    select count(*) into v_previas from public.agente_hipotesis
     where estado in ('en_prueba', 'validada', 'refutada', 'adoptada');
    v_crit := jsonb_build_object('mejora_r_min', 0.05, 'ic90_sin_cero', true,
                                 'percentil_azar_min', 90, 'pruebas_previas', v_previas);

    -- ── H1 · Decisiones que cuestan ─────────────────────────────────
    -- El deterioro cambió de regla en la 0043: lo de antes no cuenta.
    for v_r in
        select d.tipo, count(*) as n, avg(d.efecto) as media, sum(d.efecto) as total,
               avg(d.efecto) + 1.645 * stddev_samp(d.efecto) / sqrt(count(*)::numeric) as ic_alto,
               avg(d.efecto) / nullif(stddev_samp(d.efecto) / sqrt(count(*)::numeric), 0) as t,
               (array_agg(d.id order by d.id desc))[1:30] as ids
          from public.agente_decisiones d
         where d.agente_id = p_agente_id and d.resuelta_en is not null and d.efecto is not null
           and d.tipo in ('deterioro', 'parcial', 'rotacion')
           and d.creado_en >= greatest(now() - interval '90 days',
                                       case when d.tipo = 'deterioro' then timestamptz '2026-10-17 13:30+00'
                                            else '-infinity'::timestamptz end)
         group by d.tipo
        having count(*) >= 20
           and avg(d.efecto) + 1.645 * stddev_samp(d.efecto) / sqrt(count(*)::numeric) < 0
         order by t
    loop
        v_clave := 'decision:' || v_r.tipo;
        continue when public.fn_hipotesis_repetida(p_agente_id, v_clave);
        v_origen := 'decision';
        v_cambio := case v_r.tipo when 'deterioro' then '{"deterioro": 0}'::jsonb
                                  when 'parcial'   then '{"parcial_recorrido": 0}'::jsonb
                                  else '{"rotacion": 0}'::jsonb end;
        v_texto := format('Mis %s me cuestan %s $ de media frente a no hacerlas (%s decisiones, %s $ en total). Sin ellas, mi expectativa en R debería mejorar.',
                          case v_r.tipo when 'deterioro' then 'salidas por deterioro'
                                        when 'parcial' then 'tomas parciales' else 'rotaciones' end,
                          round(v_r.media, 2), v_r.n, round(v_r.total, 2));
        v_evid := jsonb_build_object('tipo', v_r.tipo, 'decisiones', v_r.n, 'efecto_medio', round(v_r.media, 4),
                                     'efecto_total', round(v_r.total, 2), 'ic90_alto', round(v_r.ic_alto, 4),
                                     'ids', to_jsonb(v_r.ids), 'desde', v_desde);
        if v_r.tipo = 'rotacion' then
            -- La rotación depende de la cartera entera y el laboratorio no la
            -- modela (doc fase-3/01 §5): queda anotada, no se puede probar.
            v_estado := 'no_ejecutable';
            v_resol := 'El laboratorio no reproduce la rotación todavía (doc fase-3/01 §5).';
        end if;
        exit;
    end loop;

    -- ── H2 · Movimientos perdidos ───────────────────────────────────
    if v_origen is null then
        create temporary table if not exists hip_dias (
            activo_id bigint, clase text, simbolo text, fecha date, atr_en_5 numeric,
            condiciones text[], inicio boolean, entro boolean) on commit drop;
        truncate hip_dias;
        insert into hip_dias
        select c.activo_id, c.clase, c.simbolo, c.fecha, c.atr_en_5, c.condiciones,
               c.movimiento and not coalesce(lag(c.movimiento) over (partition by c.activo_id order by c.fecha), false),
               exists (select 1 from public.ordenes o join public.cuentas_simulacion cs on cs.id = o.cuenta_id
                        where cs.agente_id = p_agente_id and o.activo_id = c.activo_id
                          and o.fecha_entrada::date between c.fecha and c.fecha_5)
          from public.v_condiciones_dia c
          join public.activos a on a.id = c.activo_id and a.estado = 'activo'
         where c.fecha >= v_desde and c.cierre_5 is not null and c.atr_14 > 0
           and v_clases ? c.clase;

        if (select count(*) from hip_dias where inicio and not entro) >= 5
           and (select count(distinct activo_id) from hip_dias where inicio and not entro) >= 3 then
            for v_c in
                with cat(n) as (values ('sobre_sma50'), ('sobre_sma200'), ('cruce_medias'), ('macd_positivo'),
                                       ('rsi_50_70'), ('rsi_bajo_35'), ('ruptura_20'), ('volumen_alto')),
                cand as (select array[n] as cond from cat
                         union all
                         select array[x.n, y.n] from cat x join cat y on x.n < y.n),
                st as (select k.cond,
                              avg((h.condiciones @> k.cond)::int) filter (where h.inicio and not h.entro) as soporte,
                              avg((h.condiciones @> k.cond)::int) as frecuencia
                         from cand k cross join hip_dias h
                        group by k.cond),
                -- Soporte entre movimientos frente a frecuencia en todos los días.
                lift as (select st.*, soporte / nullif(frecuencia, 0) as lift from st)
                select l.cond, l.soporte, l.frecuencia
                  from lift l
                 where l.soporte >= 0.6 and l.frecuencia <= 0.5 and l.lift >= 1.5
                   -- Un par solo si es más selectivo que cada una de sus dos
                   -- condiciones: si no, es la misma idea con ruido.
                   and (cardinality(l.cond) = 1
                        or l.lift > 1.0001 * (select max(x.lift) from lift x
                                               where cardinality(x.cond) = 1 and x.cond <@ l.cond))
                 order by l.lift desc, cardinality(l.cond), l.cond
            loop
                v_clave := 'movimiento:' || array_to_string(v_c.cond, '+');
                continue when public.fn_hipotesis_repetida(p_agente_id, v_clave);
                v_origen := 'movimiento';
                v_cambio := jsonb_build_object('condicion', array_to_string(v_c.cond, '+'));
                select jsonb_build_object(
                           'condicion', array_to_string(v_c.cond, '+'),
                           'movimientos_perdidos', count(*),
                           'activos', count(distinct activo_id),
                           'soporte', round(v_c.soporte, 2), 'frecuencia', round(v_c.frecuencia, 2),
                           'desde', v_desde,
                           'ejemplos', (select jsonb_agg(jsonb_build_object('simbolo', e.simbolo, 'fecha', e.fecha,
                                                                            'atr_en_5', e.atr_en_5)
                                                         order by e.fecha desc)
                                          from (select * from hip_dias where inicio and not entro
                                                 order by fecha desc limit 20) e)),
                       format('Me perdí %s subidas de 3 ATR o más en 5 sesiones (%s activos). «%s» se cumplía al empezar el %s %% de ellas y solo el %s %% de los días: entrando también con esa condición las habría visto.',
                              count(*), count(distinct activo_id), array_to_string(v_c.cond, ' y '),
                              round(v_c.soporte * 100), round(v_c.frecuencia * 100)),
                       jsonb_build_array(mode() within group (order by clase))
                  into v_evid, v_texto, v_clases
                  from hip_dias where inicio and not entro;
                exit;
            end loop;
        end if;
    end if;

    -- ── H4 · Plantillas medibles ────────────────────────────────────
    if v_origen is null then
        for v_r in
            select b.id, b.clave_deduplicacion as clave, b.evidencia, b.ocurrencias
              from public.agente_backlog b
             where b.clave_deduplicacion in ('nueva_herramienta:cierre_parcial', 'nueva_herramienta:trailing_stop')
               and p_agente_id = any(b.agentes_solicitantes) and b.estado in ('nuevo', 'en_revision')
             order by b.ocurrencias desc, b.id
        loop
            continue when v_r.clave = 'nueva_herramienta:cierre_parcial'
                      and jsonb_typeof(v_p -> 'tp_parcial') = 'object';
            v_clave := 'plantilla:' || split_part(v_r.clave, ':', 2);
            continue when public.fn_hipotesis_repetida(p_agente_id, v_clave);
            v_origen := 'plantilla';
            if v_r.clave = 'nueva_herramienta:cierre_parcial' then
                v_cambio := '{"parcial_recorrido": 0.5, "parcial_fraccion": 0.5, "parcial_mover": 1}';
                v_texto := 'Varias operaciones llegaron cerca del objetivo y acabaron en el stop: con una toma parcial al 50 % del camino y el stop a la entrada, mi expectativa debería mejorar.';
            else
                v_cambio := '{"sigue_atr": 2}';
                v_texto := 'Varias operaciones siguieron subiendo después de tocar mi objetivo: con un stop que siga al precio a 2 ATR, mi expectativa debería mejorar.';
            end if;
            v_evid := v_r.evidencia || jsonb_build_object('backlog_id', v_r.id, 'ocurrencias', v_r.ocurrencias);
            exit;
        end loop;
    end if;

    if v_origen is null then
        return null;
    end if;

    insert into public.agente_hipotesis
        (agente_id, origen, clave, semana, enunciado, evidencia, experimento, criterio, estado, resolucion)
    values (p_agente_id, v_origen, v_clave, v_semana, v_texto, v_evid,
            jsonb_build_object('modo', 'comparar', 'estrategia', 'agente', 'agente', v_ag.nombre,
                               'version_estrategia', v_ag.version_estrategia, 'cambio', v_cambio,
                               'clases', v_clases, 'periodo', '5y', 'universo', 'activo'),
            v_crit, v_estado, v_resol)
    returning id into v_id;

    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'agente', v_ag.nombre || ' propone probar: ' || v_texto,
            jsonb_build_object('hipotesis_id', v_id, 'origen', v_origen, 'clave', v_clave));
    return v_id;
end;
$$;

-- ¿Ya la propuso y sigue viva, o se refutó o archivó hace menos de 8
-- semanas? Entonces no se repite.
create function public.fn_hipotesis_repetida(p_agente_id bigint, p_clave text)
returns boolean
language sql stable
security definer
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.agente_hipotesis
         where agente_id = p_agente_id and clave = p_clave
           and (estado in ('propuesta', 'en_prueba', 'validada', 'no_ejecutable', 'adoptada')
                or actualizado_en > now() - interval '8 weeks'))
$$;

revoke execute on function public.fn_generar_hipotesis(bigint) from public, anon, authenticated;
revoke execute on function public.fn_hipotesis_repetida(bigint, text) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- Cada lunes, con el autodiagnóstico
-- ═════════════════════════════════════════════════════════════════════
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
        -- 0046: y propone su hipótesis de la semana, aparte.
        begin
            perform public.fn_generar_hipotesis(v_ag.id);
        exception when others then
            insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
            values (v_ag.id, 'fallo', v_ag.nombre || ': la hipótesis de la semana falló',
                    jsonb_build_object('error', sqlerrm, 'codigo', sqlstate));
        end;
    end loop;
    return v_out;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Lectura y revisión
-- ═════════════════════════════════════════════════════════════════════
create view public.v_hipotesis_agentes
with (security_invoker = true) as
    select h.id, h.agente_id, a.nombre, h.origen, h.clave, h.semana, h.enunciado, h.evidencia,
           h.experimento, h.criterio, h.estado, h.resultado, h.informe_url, h.resolucion,
           h.revisado_en, h.creado_en, h.actualizado_en
      from public.agente_hipotesis h
      join public.agentes a on a.id = h.agente_id;

grant select on public.v_hipotesis_agentes to authenticated;

-- El dueño adopta una hipótesis validada (será un agente experimental o
-- un cambio al acabar el experimento) o archiva cualquiera, explicando
-- por qué.
create function public.rpc_revisar_hipotesis(p_id bigint, p_estado text, p_resolucion text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_previo text;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador revisa las hipótesis de los agentes.' using errcode = '42501';
    end if;
    if p_estado not in ('adoptada', 'archivada') then
        raise exception 'Estado no válido: %', p_estado using errcode = '22023';
    end if;
    if p_estado = 'archivada' and nullif(btrim(coalesce(p_resolucion, '')), '') is null then
        raise exception 'Archivar exige explicar por qué.' using errcode = '22023';
    end if;

    select estado into v_previo from public.agente_hipotesis where id = p_id for update;
    if not found then
        raise exception 'La hipótesis % no existe', p_id using errcode = 'P0002';
    end if;
    if p_estado = 'adoptada' and v_previo <> 'validada' then
        raise exception 'Solo se adopta una hipótesis que el laboratorio validó (está «%»).', v_previo
              using errcode = 'P0001';
    end if;

    update public.agente_hipotesis
       set estado = p_estado, resolucion = coalesce(nullif(btrim(coalesce(p_resolucion, '')), ''), resolucion),
           revisado_por = auth.uid(), revisado_en = now(), actualizado_en = now()
     where id = p_id;

    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), 'resolver_hipotesis', 'agente_hipotesis', p_id::text,
            jsonb_build_object('de', v_previo, 'a', p_estado, 'resolucion', p_resolucion));
    return jsonb_build_object('id', p_id, 'estado', p_estado);
end;
$$;

revoke execute on function public.rpc_revisar_hipotesis(bigint, text, text) from public, anon;
grant  execute on function public.rpc_revisar_hipotesis(bigint, text, text) to authenticated;
