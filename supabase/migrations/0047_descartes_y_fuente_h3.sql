-- ─────────────────────────────────────────────────────────────────────
-- 0047 — Qué descartan los agentes, y la fuente H3 (Fase 3, I4; doc
-- fase-3/01 §3).
--
-- Hasta aquí un agente solo contaba sus descartes por motivo
-- (`agente_dias.descartes`): sabía que había quitado 1.400 señales por
-- fuerza, pero no cuáles. Sin eso no se puede preguntar si un filtro le
-- quita más de lo que le protege.
--
--   · `agente_descartes`: en cada ciclo, las señales que el agente
--     descartó por un filtro de SU PERFIL (fuerza, origen de los niveles,
--     R:R, ATR alto o bajo). Una fila por agente, activo, día y motivo: la
--     primera vez del día, con el precio y los datos de la señal. Los
--     descartes por dirección, sesión o antigüedad no dicen nada del
--     perfil y no se guardan. Se conservan 120 días.
--   · H3 en `fn_generar_hipotesis`: un motivo con al menos 30 descartes en
--     5 activos cuya subida media en 5 sesiones (en ATR, intervalo del
--     90 %) supera en 0,25 ATR a la de su universo esos mismos días.
--     Propone relajar ese filtro: R:R mínimo 0,2 más bajo, una fuerza
--     menos, el tope de ATR × 1,5 o el suelo × 0,5. El origen de los
--     niveles no lo modela el laboratorio: queda `no_ejecutable`.
--
-- Orden de las fuentes: H1, H2, H3, H4. Sigue siendo una por semana.
-- ─────────────────────────────────────────────────────────────────────

create table public.agente_descartes (
    agente_id  bigint not null references public.agentes(id) on delete cascade,
    activo_id  bigint not null references public.activos(id) on delete cascade,
    fecha      date not null,
    motivo     text not null check (motivo in ('fuerza', 'niveles_origen', 'rr', 'atr_alto', 'atr_bajo')),
    senal_id   bigint,
    precio     numeric(20, 8),
    fuerza     text,
    ratio_rr   numeric,
    atr_pct    numeric,
    creado_en  timestamptz not null default now(),
    primary key (agente_id, activo_id, fecha, motivo)
);

comment on table public.agente_descartes is
    'Señales que cada agente descartó por un filtro de su perfil: una por agente, activo, día y motivo (0047, fuente H3).';

create index agente_descartes_fecha on public.agente_descartes (fecha);

alter table public.agente_descartes enable row level security;
create policy agente_descartes_aprobados on public.agente_descartes
    for select to authenticated using (public.es_usuario_aprobado());
revoke insert, update, delete on public.agente_descartes from authenticated;
revoke all on public.agente_descartes from anon;

create function public.fn_registrar_descartes(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag        public.agentes;
    v_p         jsonb;
    v_cuenta    bigint;
    v_practicas jsonb;
    v_hoy       date := (now() at time zone 'UTC')::date;
    v_n         int;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    if not found or v_ag.tipo <> 'metas' or v_ag.estado not in ('activo', 'cuarentena') then
        return 0;
    end if;
    v_p := public.fn_parametros_agente(v_ag);
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    -- Las mismas prácticas que aplica `fn_decidir_agente`.
    select coalesce(jsonb_agg(jsonb_build_object('c', p.condiciones, 's', p.sentido) order by p.id), '[]'::jsonb)
      into v_practicas
      from public.mp_adopciones ad
      join public.mejores_practicas p on p.id = ad.practica_id
     where ad.agente_id = p_agente_id and ad.abandonada_en is null
       and p.estado in ('propuesta', 'validada');

    insert into public.agente_descartes (agente_id, activo_id, fecha, motivo, senal_id, precio, fuerza, ratio_rr, atr_pct)
    select p_agente_id, u.activo_id, v_hoy, u.motivo, u.senal_id, u.precio_actual, u.fuerza, u.ratio_rr, u.atr_pct
      from public.fn_universo_agente(v_p, v_cuenta, v_practicas) u
     where u.motivo in ('fuerza', 'niveles_origen', 'rr', 'atr_alto', 'atr_bajo')
    on conflict do nothing;
    get diagnostics v_n = row_count;

    -- Retención: 120 días bastan para la ventana de 90 de la H3.
    delete from public.agente_descartes where agente_id = p_agente_id and fecha < v_hoy - 120;
    return v_n;
end;
$$;

revoke execute on function public.fn_registrar_descartes(bigint) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- El ciclo de los agentes registra sus descartes
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

            -- 0047: qué señales descartó por su perfil (fuente H3). Si
            -- falla, avisa, pero el ciclo del agente ya está hecho.
            begin
                perform public.fn_registrar_descartes(v_id);
            exception when others then
                get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
                perform public.fn_registrar_fallo(v_id, 'registrar descartes', v_err, v_cod, v_ctx);
            end;

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

-- ═════════════════════════════════════════════════════════════════════
-- El generador, con la H3 entre la H2 y la H4
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_generar_hipotesis(p_agente_id bigint)
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

    -- ── H3 · Descartes que subieron (0047) ──────────────────────────
    -- Señales que el agente descartó por un filtro de su perfil y lo que
    -- hicieron en las 5 sesiones siguientes, en ATR, frente a lo que hizo
    -- su universo esos mismos días. Si el filtro quitaba, con claridad, lo
    -- que más subía, propone relajarlo.
    if v_origen is null then
        for v_r in
            with u as (
                select c.activo_id, c.fecha, c.atr_en_5
                  from public.v_condiciones_dia c
                 where c.fecha >= v_desde and c.cierre_5 is not null and c.atr_14 > 0
                   and v_clases ? c.clase),
            base as (select avg(atr_en_5) as media from u),
            d as (
                select ds.motivo, ds.activo_id, ds.fecha, a.simbolo, a.clase, u.atr_en_5
                  from public.agente_descartes ds
                  join u on u.activo_id = ds.activo_id and u.fecha = ds.fecha
                  join public.activos a on a.id = ds.activo_id
                 where ds.agente_id = p_agente_id and ds.fecha >= v_desde)
            select d.motivo, count(*) as n, count(distinct d.activo_id) as activos,
                   avg(d.atr_en_5) as media, (select media from base) as media_base,
                   avg(d.atr_en_5) - 1.645 * stddev_samp(d.atr_en_5) / sqrt(count(*)::numeric) as ic_bajo,
                   mode() within group (order by d.clase) as clase,
                   (select jsonb_agg(jsonb_build_object('simbolo', e.simbolo, 'fecha', e.fecha, 'atr_en_5', e.atr_en_5)
                                     order by e.atr_en_5 desc)
                      from (select * from d d2 where d2.motivo = d.motivo order by d2.atr_en_5 desc limit 10) e) as ejemplos
              from d
             group by d.motivo
            having count(*) >= 30 and count(distinct d.activo_id) >= 5
               and avg(d.atr_en_5) - 1.645 * stddev_samp(d.atr_en_5) / sqrt(count(*)::numeric)
                   > (select media from base) + 0.25
             order by avg(d.atr_en_5) - (select media from base) desc
        loop
            v_clave := 'descarte:' || v_r.motivo;
            continue when public.fn_hipotesis_repetida(p_agente_id, v_clave);
            v_cambio := case v_r.motivo
                when 'rr' then jsonb_build_object('rr_minimo',
                                   greatest(1.0, round((v_p ->> 'rr_minimo')::numeric - 0.2, 2)))
                when 'fuerza' then jsonb_build_object('fuerza_minima',
                                   case when v_p -> 'fuerzas_admitidas' ? 'media' then 1 else 2 end)
                when 'atr_alto' then jsonb_build_object('atr_max',
                                   round(coalesce((public.fn_param_clase(v_p, v_r.clase, 'atr_pct_max') #>> '{}')::numeric, 0) * 1.5, 1))
                when 'atr_bajo' then jsonb_build_object('atr_min',
                                   round(coalesce((public.fn_param_clase(v_p, v_r.clase, 'atr_pct_min') #>> '{}')::numeric, 0) * 0.5, 1))
                else jsonb_build_object(v_r.motivo, 'relajar') end;
            v_origen := 'descarte';
            v_clases := jsonb_build_array(v_r.clase);
            v_texto := format('Las %s señales que descarté por «%s» subieron de media %s ATR en 5 sesiones, frente a %s ATR de mi universo esos días (%s activos). El filtro me quita más de lo que me protege: relajarlo debería mejorar mi expectativa.',
                              v_r.n, v_r.motivo, round(v_r.media, 2), round(v_r.media_base, 2), v_r.activos);
            v_evid := jsonb_build_object('motivo', v_r.motivo, 'descartes', v_r.n, 'activos', v_r.activos,
                                         'atr_en_5_medio', round(v_r.media, 3), 'atr_en_5_universo', round(v_r.media_base, 3),
                                         'ic90_bajo', round(v_r.ic_bajo, 3), 'ejemplos', v_r.ejemplos, 'desde', v_desde);
            if v_r.motivo = 'niveles_origen' then
                -- El laboratorio no distingue el origen de los niveles (estructura
                -- o ATR): queda anotada.
                v_estado := 'no_ejecutable';
                v_resol := 'El laboratorio no modela el origen de los niveles (doc fase-3/01 §5).';
            end if;
            exit;
        end loop;
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
