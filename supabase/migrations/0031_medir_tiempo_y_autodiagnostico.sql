-- ─────────────────────────────────────────────────────────────────────
-- 0031 — Entrega A: medir el tiempo y que los agentes pidan su propio
-- diagnóstico (doc 05, 2026-10-10).
--
-- NO CAMBIA NINGUNA DECISIÓN. Registra, muestra y pide. Es la base de las
-- entregas siguientes (cripto prudente, noches y fines de semana caso a
-- caso, aporte por sesión), que necesitan estos datos medidos y no
-- supuestos.
--
--   1. CALENDARIO DE MERCADOS en una tabla (`mercados`), con festivos de
--      la NYSE 2026–2027, y funciones para preguntarle: ¿está abierto?,
--      ¿cuánto le queda?, ¿cuándo vuelve a abrir?, ¿cuántas sesiones hay
--      entre dos fechas? Añadir un mercado en una fase futura es añadir
--      una fila. (Las funciones de siempre —fn_mercado_abierto y
--      compañía— no se tocan todavía: cambiarlas cambiaría decisiones.)
--   2. CADA ORDEN NACE CON SU ESTIMACIÓN: horizonte en sesiones y
--      probabilidad de llegar al objetivo, a partir de las distancias en
--      ATR (doc 05 §4.1: sesiones ≈ a × b, p ≈ b / (a + b), sin presumir
--      ventaja). Y con el régimen de mercado del momento.
--   3. EL RECORRIDO SE MIDE EN EL TIEMPO: mejor y peor precio visto, y
--      cuándo. Hasta hoy solo se guardaba el mejor, sin fecha.
--   4. HUECOS DE APERTURA MEDIDOS por activo (`v_huecos_activos`), en % y
--      en ATR, separando los lunes: es el dato de la evaluación de noches
--      y fines de semana (doc 05 §5.4).
--   5. CADA PRÁCTICA GUARDA EL RÉGIMEN DE MERCADO en que se publicó (doc
--      05 §9): proporción de señales alcistas y ATR medio por clase, y la
--      tendencia de BTC.
--   6. PLAN DE LA SEMANA visible (`v_agentes_plan`): meta de la semana, lo
--      que falta, el ritmo necesario por sesión y el tiempo que le queda a
--      cada mercado del agente.
--   7. AUTODIAGNÓSTICO SEMANAL (doc 05 §10): los lunes, después del corte,
--      cada agente mide sus propias operaciones y abre una petición en el
--      backlog, con la evidencia, cuando algo cruza su umbral. Lo que esta
--      vez descubrió una revisión externa lo habría pedido él.
-- ─────────────────────────────────────────────────────────────────────


-- ═════════════════════════════════════════════════════════════════════
-- 1. Calendario de mercados
-- ═════════════════════════════════════════════════════════════════════
create table public.mercados (
    clave         text primary key,
    nombre        text not null,
    clases        text[] not null,
    zona_horaria  text not null,
    dias_semana   int[] not null,          -- isodow: 1 = lunes … 7 = domingo
    apertura      time not null,
    cierre        time not null,           -- '24:00' = abierto hasta medianoche
    festivos      date[] not null default '{}',
    riesgo_hueco  text not null check (riesgo_hueco in ('alto', 'bajo')),
    creado_en     timestamptz not null default now()
);

comment on table public.mercados is
  'Calendario de cada mercado (0031). Las medias sesiones (p. ej. el día después de Acción de Gracias) no se modelan todavía: cuentan como sesión completa.';

insert into public.mercados (clave, nombre, clases, zona_horaria, dias_semana, apertura, cierre, festivos, riesgo_hueco) values
    ('nyse', 'Bolsa de Nueva York', '{accion}', 'America/New_York', '{1,2,3,4,5}', '09:30', '16:00',
     '{2026-01-01,2026-01-19,2026-02-16,2026-04-03,2026-05-25,2026-06-19,2026-07-03,2026-09-07,2026-11-26,2026-12-25,
       2027-01-01,2027-01-18,2027-02-15,2027-03-26,2027-05-31,2027-06-18,2027-07-05,2027-09-06,2027-11-25,2027-12-24}',
     'alto'),
    ('cripto', 'Cripto', '{cripto}', 'UTC', '{1,2,3,4,5,6,7}', '00:00', '24:00', '{}', 'bajo');

alter table public.mercados enable row level security;
create policy mercados_lectura on public.mercados
    for select to authenticated using (true);
grant select on public.mercados to authenticated;

-- El mercado de una clase de activo.
create function public.fn_mercado_de_clase(p_clase text)
returns text
language sql stable
as $$
    select clave from public.mercados where p_clase = any(clases) order by clave limit 1
$$;

-- ¿Es este día (en la hora local del mercado) un día de sesión?
create function public.fn_dia_de_sesion(p_mercado text, p_dia date)
returns boolean
language sql stable
as $$
    select coalesce((select extract(isodow from p_dia)::int = any(m.dias_semana)
                            and not (p_dia = any(m.festivos))
                       from public.mercados m where m.clave = p_mercado), false)
$$;

-- ¿Está abierto el mercado en este instante?
create function public.fn_sesion_abierta(p_mercado text, p_momento timestamptz default now())
returns boolean
language sql stable
as $$
    select coalesce((
        select public.fn_dia_de_sesion(m.clave, (p_momento at time zone m.zona_horaria)::date)
           and (p_momento at time zone m.zona_horaria)::time >= m.apertura
           and (m.cierre = '24:00' or (p_momento at time zone m.zona_horaria)::time < m.cierre)
          from public.mercados m where m.clave = p_mercado), false)
$$;

-- Minutos que le quedan a la sesión en curso (0 si está cerrado). En un
-- mercado continuo, lo que queda hasta el final del día UTC.
create function public.fn_minutos_restantes_sesion(p_mercado text, p_momento timestamptz default now())
returns int
language sql stable
as $$
    select case when public.fn_sesion_abierta(p_mercado, p_momento) then
               (select floor(extract(epoch from
                    ((p_momento at time zone m.zona_horaria)::date + m.cierre) at time zone m.zona_horaria
                    - p_momento) / 60)::int
                  from public.mercados m where m.clave = p_mercado)
           else 0 end
$$;

-- Cuándo abre la próxima sesión (o este instante, si está abierto).
create function public.fn_proxima_apertura(p_mercado text, p_momento timestamptz default now())
returns timestamptz
language plpgsql stable
as $$
declare
    v_m     public.mercados;
    v_local timestamp;
    v_dia   date;
begin
    if public.fn_sesion_abierta(p_mercado, p_momento) then
        return p_momento;
    end if;
    select * into v_m from public.mercados where clave = p_mercado;
    if not found then return null; end if;
    v_local := p_momento at time zone v_m.zona_horaria;
    for i in 0 .. 14 loop
        v_dia := v_local::date + i;
        if public.fn_dia_de_sesion(p_mercado, v_dia)
           and (i > 0 or v_local::time < v_m.apertura) then
            return (v_dia + v_m.apertura) at time zone v_m.zona_horaria;
        end if;
    end loop;
    return null;
end;
$$;

-- Sesiones entre dos fechas, ambas incluidas.
create function public.fn_sesiones_entre(p_mercado text, p_desde date, p_hasta date)
returns int
language sql stable
as $$
    select count(*)::int
      from generate_series(p_desde, p_hasta, interval '1 day') d
     where public.fn_dia_de_sesion(p_mercado, d::date)
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 5. Régimen de mercado (va antes porque lo usan las órdenes)
-- ═════════════════════════════════════════════════════════════════════
-- Foto del mercado que ve el motor: por clase, cuántas señales frescas son
-- alcistas o bajistas y su ATR medio; y la tendencia de fondo de BTC (su
-- cruce de medias). Es lo que permitirá saber si una práctica se aprendió
-- en un mercado parecido al de hoy.
create function public.fn_regimen_mercado()
returns jsonb
language sql stable
as $$
    select jsonb_build_object(
        'calculado_en', now(),
        'clases', coalesce((
            select jsonb_object_agg(clase, datos) from (
                select s.clase, jsonb_build_object(
                           'senales', count(*),
                           'pct_alcistas', round(100.0 * count(*) filter (where s.direccion = 'alcista') / count(*), 1),
                           'pct_bajistas', round(100.0 * count(*) filter (where s.direccion = 'bajista') / count(*), 1),
                           'atr_medio', round(avg(s.atr_pct), 2)) as datos
                  from public.senales_vigentes s
                 where s.estado_activo = 'activo' and s.calculado_en > now() - interval '1 day'
                 group by s.clase) t), '{}'::jsonb),
        'btc_tendencia', (
            select d ->> 'direccion'
              from public.senales_vigentes s
              cross join lateral jsonb_array_elements(coalesce(s.senales_detalle, '[]'::jsonb)) d
             where s.simbolo = 'bitcoin' and d ->> 'nombre' = 'cruce_medias'
             limit 1))
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 2 y 3. Estimación y recorrido de cada orden
-- ═════════════════════════════════════════════════════════════════════
alter table public.ordenes
    add column horizonte_estimado_sesiones numeric(8, 2),
    add column p_estimada                  numeric(5, 4),
    add column precio_max_visto_en         timestamptz,
    add column precio_min_visto            numeric(20, 8),
    add column precio_min_visto_en         timestamptz,
    add column regimen                     jsonb;

comment on column public.ordenes.horizonte_estimado_sesiones is
  'Sesiones que se estimaba que tardaría en resolverse al abrirla: a × b, con a y b las distancias al objetivo y al stop en ATR (doc 05 §4.1). Se compara con lo que tardó.';
comment on column public.ordenes.p_estimada is
  'Probabilidad estimada al abrir de llegar al objetivo antes que al stop, sin presumir ventaja: b / (a + b).';

create function public.fn_estimar_orden()
returns trigger
language plpgsql
as $$
declare
    v_atr_pct numeric;
    v_atr     numeric;
    v_a       numeric;
    v_b       numeric;
begin
    if new.senal_id is not null then
        select atr_pct into v_atr_pct from public.senales where id = new.senal_id;
        if v_atr_pct > 0 then
            v_atr := v_atr_pct / 100 * new.precio_entrada;
            v_a := (new.tp - new.precio_entrada) / v_atr;
            v_b := (new.precio_entrada - new.sl) / v_atr;
            if v_a > 0 and v_b > 0 then
                new.horizonte_estimado_sesiones := round(least(v_a * v_b, 999999), 2);
                new.p_estimada := round(v_b / (v_a + v_b), 4);
            end if;
        end if;
    end if;
    new.regimen := coalesce(new.regimen, public.fn_regimen_mercado());
    return new;
end;
$$;

create trigger ordenes_estimar
    before insert on public.ordenes
    for each row execute function public.fn_estimar_orden();

-- Observar precios: mejor y peor precio visto, con su momento.
create or replace function public.fn_agentes_observar_precios()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_a int; v_b int; v_c int;
begin
    update public.ordenes o
       set precio_max_visto = a.ultimo_precio,
           precio_max_visto_en = coalesce(a.ultimo_precio_en, now())
      from public.activos a, public.cuentas_simulacion c
     where a.id = o.activo_id and c.id = o.cuenta_id and c.agente_id is not null
       and o.estado = 'abierta' and a.ultimo_precio is not null
       and a.ultimo_precio > coalesce(o.precio_max_visto, o.precio_entrada);
    get diagnostics v_a = row_count;

    -- 0031: también el peor, para medir cuánto se acercó al stop y cuándo.
    update public.ordenes o
       set precio_min_visto = a.ultimo_precio,
           precio_min_visto_en = coalesce(a.ultimo_precio_en, now())
      from public.activos a, public.cuentas_simulacion c
     where a.id = o.activo_id and c.id = o.cuenta_id and c.agente_id is not null
       and o.estado = 'abierta' and a.ultimo_precio is not null
       and a.ultimo_precio < coalesce(o.precio_min_visto, o.precio_entrada);
    get diagnostics v_c = row_count;

    update public.ordenes o
       set precio_max_post_cierre = greatest(coalesce(o.precio_max_post_cierre, 0), a.ultimo_precio)
      from public.activos a, public.cuentas_simulacion c
     where a.id = o.activo_id and c.id = o.cuenta_id and c.agente_id is not null
       and o.motivo_cierre = 'tp' and o.fecha_salida > now() - interval '24 hours'
       and a.ultimo_precio_en > o.fecha_salida
       and a.ultimo_precio > coalesce(o.precio_max_post_cierre, 0);
    get diagnostics v_b = row_count;
    return v_a + v_b + v_c;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 4. Huecos de apertura medidos
-- ═════════════════════════════════════════════════════════════════════
-- Últimos 120 días de velas diarias de acciones: lo que abrió cada sesión
-- frente al cierre anterior, en % y en ATR (el ATR medio de sus señales de
-- los últimos 30 días). Lo que importa es la caída: el percentil 90 del
-- hueco a la baja, en general y los lunes, que llegan tras 65 horas sin
-- poder salir. La cripto no tiene huecos: cotiza sin pausa.
create view public.v_huecos_activos
with (security_invoker = true) as
    with velas as (
        select p.activo_id, p.fecha, p.apertura,
               lag(p.cierre) over (partition by p.activo_id order by p.fecha) as cierre_previo
          from public.precios_diarios p
          join public.activos a on a.id = p.activo_id and a.clase = 'accion'
         where p.fecha > current_date - 120
    ),
    huecos as (
        select activo_id, fecha,
               (apertura - cierre_previo) / cierre_previo * 100 as hueco_pct
          from velas
         where apertura is not null and cierre_previo > 0
    ),
    atr as (
        select activo_id, avg(atr_pct) as atr_pct
          from public.senales
         where calculado_en > now() - interval '30 days' and atr_pct > 0
         group by activo_id
    )
    select a.id as activo_id, a.simbolo,
           count(*) as sesiones,
           round(atr.atr_pct, 3) as atr_pct,
           round(percentile_cont(0.9) within group (order by greatest(-h.hueco_pct, 0))::numeric, 3)
               as caida_p90_pct,
           round(max(greatest(-h.hueco_pct, 0)), 3) as caida_max_pct,
           round((percentile_cont(0.9) within group (order by greatest(-h.hueco_pct, 0)))::numeric
                 / nullif(atr.atr_pct, 0), 3) as caida_p90_atr,
           count(*) filter (where extract(isodow from h.fecha) = 1) as lunes,
           round((percentile_cont(0.9) within group (order by greatest(-h.hueco_pct, 0))
                     filter (where extract(isodow from h.fecha) = 1))::numeric, 3) as caida_p90_lunes_pct,
           round((percentile_cont(0.9) within group (order by greatest(-h.hueco_pct, 0))
                     filter (where extract(isodow from h.fecha) = 1))::numeric
                 / nullif(atr.atr_pct, 0), 3) as caida_p90_lunes_atr
      from huecos h
      join public.activos a on a.id = h.activo_id
      left join atr on atr.activo_id = h.activo_id
     group by a.id, a.simbolo, atr.atr_pct;

comment on view public.v_huecos_activos is
  'Huecos de apertura de las acciones (0031): percentil 90 y máximo de la caída frente al cierre anterior, en % y en ATR, en general y los lunes. Insumo de la evaluación de noches y fines de semana (doc 05 §5.4).';


-- ═════════════════════════════════════════════════════════════════════
-- 5 (bis). Cada práctica guarda su régimen de mercado
-- ═════════════════════════════════════════════════════════════════════
alter table public.mejores_practicas add column regimen jsonb;

comment on column public.mejores_practicas.regimen is
  'Régimen de mercado cuando se publicó (0031): base para saber si una práctica fue situacional (doc 05 §9).';

create function public.fn_practica_regimen()
returns trigger
language plpgsql
as $$
begin
    new.regimen := coalesce(new.regimen, public.fn_regimen_mercado());
    return new;
end;
$$;

create trigger mejores_practicas_regimen
    before insert on public.mejores_practicas
    for each row execute function public.fn_practica_regimen();


-- ═════════════════════════════════════════════════════════════════════
-- 6. El plan de la semana, visible
-- ═════════════════════════════════════════════════════════════════════
-- Las sesiones de la semana son las del mercado del agente con más días
-- (con cripto, 7; solo acciones, las de la NYSE menos festivos). El P&L de
-- la semana es el realizado de los días cerrados más el de hoy.
create view public.v_agentes_plan
with (security_invoker = true) as
    with base as (
        select g.id as agente_id, g.nombre, g.estado, g.objetivo_diario_pct, c.id as cuenta_id,
               date_trunc('week', now() at time zone 'UTC')::date as lunes,
               (now() at time zone 'UTC')::date as hoy,
               array(select distinct public.fn_mercado_de_clase(x)
                       from jsonb_array_elements_text(
                            coalesce(g.estrategia -> 'clases_admitidas', '["accion", "cripto"]'::jsonb)) x) as mercados
          from public.agentes g
          join public.cuentas_simulacion c on c.agente_id = g.id and c.estado <> 'game_over'
    ),
    semana as (
        select b.*,
               (select max(public.fn_sesiones_entre(m, b.lunes, b.lunes + 6)) from unnest(b.mercados) m) as sesiones_semana,
               (select max(public.fn_sesiones_entre(m, b.hoy, b.lunes + 6)) from unnest(b.mercados) m) as sesiones_restantes,
               (select d.saldo_apertura from public.agente_dias d
                 where d.agente_id = b.agente_id and d.fecha between b.lunes and b.lunes + 6
                 order by d.fecha limit 1) as saldo_lunes,
               coalesce((select sum(d.pnl_realizado) from public.agente_dias d
                          where d.agente_id = b.agente_id and d.fecha >= b.lunes and d.fecha < b.hoy), 0)
                 + public.fn_pnl_realizado_dia(b.cuenta_id, b.hoy) as pnl_semana
          from base b
    ),
    meta as (
        select s.*,
               round(s.saldo_lunes * (power(1 + s.objetivo_diario_pct / 100, s.sesiones_semana) - 1), 2) as meta_semana
          from semana s
    )
    select m.agente_id, m.nombre, m.estado, m.lunes, m.objetivo_diario_pct,
           m.saldo_lunes, m.sesiones_semana, m.sesiones_restantes,
           m.meta_semana, round(m.pnl_semana, 2) as pnl_semana,
           round(m.meta_semana - m.pnl_semana, 2) as falta_semana,
           round((m.meta_semana - m.pnl_semana) / greatest(m.sesiones_restantes, 1), 2) as ritmo_por_sesion,
           (select jsonb_agg(jsonb_build_object(
                       'mercado', mk, 'abierto', public.fn_sesion_abierta(mk),
                       'minutos_restantes', public.fn_minutos_restantes_sesion(mk),
                       'proxima_apertura', public.fn_proxima_apertura(mk)) order by mk)
              from unnest(m.mercados) mk) as mercados
      from meta m;

comment on view public.v_agentes_plan is
  'Plan de la semana de cada agente (0031): meta compuesta sobre las sesiones de su mercado, P&L realizado, lo que falta, el ritmo necesario por sesión y el tiempo de cada mercado. Solo informa: no decide.';


-- ═════════════════════════════════════════════════════════════════════
-- 7. Autodiagnóstico semanal
-- ═════════════════════════════════════════════════════════════════════
-- Ciclos con el saldo (o el riesgo) lleno, con candidatas esperando,
-- mientras sus posiciones de acciones no se pueden cerrar porque la bolsa
-- está cerrada. Es el «saldo atrapado» del fin de semana del 3–4 oct.
alter table public.agente_dias
    add column ciclos_saldo_atrapado int not null default 0;

comment on column public.agente_dias.ciclos_saldo_atrapado is
  'Ciclos con saldo o riesgo lleno y candidatas esperando, con posiciones de acciones abiertas y la bolsa cerrada (0031).';

create function public.fn_contar_saldo_atrapado()
returns trigger
language plpgsql
as $$
begin
    if new.ciclos = old.ciclos + 1
       and new.ultima_decision ->> 'accion' in ('saldo_lleno', 'riesgo_lleno')
       and coalesce((new.ultima_decision ->> 'candidatos')::int, 0) > 0
       and not public.fn_sesion_abierta('nyse')
       and exists (select 1 from public.ordenes o join public.activos a on a.id = o.activo_id
                    where o.cuenta_id = new.cuenta_id and o.estado = 'abierta' and a.clase = 'accion') then
        new.ciclos_saldo_atrapado := old.ciclos_saldo_atrapado + 1;
    end if;
    return new;
end;
$$;

create trigger agente_dias_saldo_atrapado
    before update of ciclos on public.agente_dias
    for each row execute function public.fn_contar_saldo_atrapado();

-- Los umbrales, en un solo sitio (doc 05 §10.2).
create function public.fn_umbrales_autodiagnostico()
returns jsonb
language sql immutable
as $$
    select jsonb_build_object(
        'ventana_ordenes_dias', 14, 'ventana_dias', 7,
        'objetivos_min_cierres', 15,
        'stop_min_ordenes', 10, 'stop_mediana_atr', 0.5,
        'votos_min_ordenes', 10, 'votos_pct_contradictorias', 50,
        'filtro_min_descartes', 200, 'filtro_pct', 80,
        'saldo_atrapado_ciclos', 36,
        'metas_min_dias', 3,
        'practica_min_ops', 5)
$$;

create function public.fn_autodiagnostico_agente(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    u        jsonb := public.fn_umbrales_autodiagnostico();
    v_ag     public.agentes;
    v_desde  timestamptz;
    v_dias   date;
    v_n      int := 0;
    v_r      record;
    v_sufijo text;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    v_sufijo := ':agente_' || p_agente_id;
    v_desde  := now() - ((u ->> 'ventana_ordenes_dias') || ' days')::interval;
    -- Las operaciones de antes de la 0030 (D21) se abrieron con los niveles
    -- viejos: pedir otra vez lo que ya se corrigió solo haría ruido, y el
    -- backlog lo reabriría cada semana. La ventana empieza, como pronto,
    -- cuando se aplicó la 0030.
    v_desde  := greatest(v_desde, coalesce(
                    (select max(creado_en) from public.eventos_sistema
                      where tipo = 'sys' and datos ->> 'migracion' = '0030'), '-infinity'::timestamptz));
    v_dias   := (now() at time zone 'UTC')::date - (u ->> 'ventana_dias')::int;

    -- a. Objetivos que no se alcanzan.
    select count(*) as cierres,
           count(*) filter (where o.motivo_cierre = 'tp') as tp,
           count(*) filter (where o.motivo_cierre in ('sl', 'liquidacion')) as sl,
           round((percentile_cont(0.5) within group (order by
               case when o.precio_max_visto is not null
                    then (o.precio_max_visto - o.precio_entrada) / (o.tp - o.precio_entrada) end))::numeric, 3)
               as avance_mediano,
           jsonb_agg(o.id order by o.id) as ordenes
      into v_r
      from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
     where c.agente_id = p_agente_id and o.estado = 'cerrada'
       and o.motivo_cierre in ('tp', 'sl', 'liquidacion') and o.fecha_salida >= v_desde;
    if v_r.cierres >= (u ->> 'objetivos_min_cierres')::int and v_r.tp = 0 then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:objetivos' || v_sufijo,
            'Mis objetivos no se alcanzan',
            format('%s cierres en 14 días, ninguno en el objetivo y %s en el stop. Mediana del camino recorrido hacia el objetivo: %s.',
                   v_r.cierres, v_r.sl, coalesce(v_r.avance_mediano::text, 'sin dato')),
            'Si ninguna operación llega al objetivo, el objetivo no es una salida real: revisar a qué distancia se pone y en cuánto tiempo se alcanza.',
            jsonb_build_object('cierres', v_r.cierres, 'tp', v_r.tp, 'sl', v_r.sl,
                               'avance_mediano', v_r.avance_mediano, 'ordenes', v_r.ordenes), 2);
        v_n := v_n + 1;
    end if;

    -- b. Stops dentro del ruido.
    select count(*) as n,
           round((percentile_cont(0.5) within group (order by
               ((o.precio_entrada - coalesce(o.sl_original, o.sl)) / o.precio_entrada * 100) / s.atr_pct))::numeric, 3)
               as mediana_atr,
           jsonb_agg(o.id order by o.id) as ordenes
      into v_r
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.senales s on s.id = o.senal_id
     where c.agente_id = p_agente_id and o.fecha_entrada >= v_desde and s.atr_pct > 0;
    if v_r.n >= (u ->> 'stop_min_ordenes')::int and v_r.mediana_atr < (u ->> 'stop_mediana_atr')::numeric then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:stops' || v_sufijo,
            'Mis stops están dentro del ruido',
            format('Mediana de la distancia al stop: %s ATR en %s entradas. Un día típico se mueve 1 ATR.', v_r.mediana_atr, v_r.n),
            'Un stop a menos de medio ATR lo salta el ruido de la propia sesión.',
            jsonb_build_object('entradas', v_r.n, 'mediana_atr', v_r.mediana_atr, 'ordenes', v_r.ordenes), 2);
        v_n := v_n + 1;
    end if;

    -- c. Entradas con votos en contra.
    select count(*) as n,
           count(*) filter (where s.indicadores_bajistas > 0) as contradictorias,
           jsonb_agg(o.id order by o.id) filter (where s.indicadores_bajistas > 0) as ordenes
      into v_r
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.senales s on s.id = o.senal_id
     where c.agente_id = p_agente_id and o.fecha_entrada >= v_desde;
    if v_r.n >= (u ->> 'votos_min_ordenes')::int
       and v_r.contradictorias * 100 >= v_r.n * (u ->> 'votos_pct_contradictorias')::numeric then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:votos' || v_sufijo,
            'Entro con señales que se contradicen',
            format('%s de %s entradas tenían al menos un indicador en contra.', v_r.contradictorias, v_r.n),
            'Una señal que se contradice es una apuesta, no una confluencia.',
            jsonb_build_object('entradas', v_r.n, 'contradictorias', v_r.contradictorias, 'ordenes', v_r.ordenes), 3);
        v_n := v_n + 1;
    end if;

    -- d. Un solo filtro tumba casi todas las candidatas. No cuentan los
    --    descartes que no son del perfil: mercado cerrado, señal añeja,
    --    posición ya abierta, ni la dirección (solo largos es una regla
    --    protegida y ya tiene su propio disparador).
    with d as (
        select key as motivo, sum(value::int) as n
          from public.agente_dias ad, jsonb_each_text(ad.descartes)
         where ad.agente_id = p_agente_id and ad.fecha >= v_dias
           and key not in ('fuera_de_sesion', 'antiguedad', 'posicion_abierta', 'direccion', 'candidata')
         group by key
    )
    select (select motivo from d order by n desc, motivo limit 1) as motivo,
           (select max(n) from d) as top, (select sum(n) from d) as total,
           (select jsonb_object_agg(motivo, n) from d) as reparto
      into v_r;
    if v_r.total >= (u ->> 'filtro_min_descartes')::int
       and v_r.top * 100 >= v_r.total * (u ->> 'filtro_pct')::numeric then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla',
            'diagnostico:filtro:' || v_r.motivo || v_sufijo,
            'El filtro «' || v_r.motivo || '» me deja sin operar',
            format('En 7 días, el %s %% de mis descartes (%s de %s) fueron por «%s».',
                   round(v_r.top * 100.0 / v_r.total), v_r.top, v_r.total, v_r.motivo),
            'Prudente no puede ser no operar: un único criterio que lo descarta casi todo merece revisarse, o graduarse en tamaño en vez de excluir.',
            jsonb_build_object('motivo', v_r.motivo, 'descartes', v_r.reparto, 'desde', v_dias), 3);
        v_n := v_n + 1;
    end if;

    -- e. Saldo atrapado con candidatas esperando.
    select coalesce(sum(ad.ciclos_saldo_atrapado), 0) as ciclos,
           jsonb_agg(jsonb_build_object('fecha', ad.fecha, 'ciclos', ad.ciclos_saldo_atrapado) order by ad.fecha)
               filter (where ad.ciclos_saldo_atrapado > 0) as dias
      into v_r
      from public.agente_dias ad
     where ad.agente_id = p_agente_id and ad.fecha >= v_dias;
    if v_r.ciclos >= (u ->> 'saldo_atrapado_ciclos')::int then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:saldo_atrapado' || v_sufijo,
            'Mi saldo queda atrapado con la bolsa cerrada',
            format('%s ciclos (unas %s horas) con el saldo lleno, candidatas esperando y posiciones de acciones que no se podían cerrar.',
                   v_r.ciclos, round(v_r.ciclos * 5 / 60.0, 1)),
            'Antes del cierre habría que evaluar si mantener las acciones compensa frente a lo que ofrecen los mercados que siguen abiertos.',
            jsonb_build_object('ciclos', v_r.ciclos, 'dias', v_r.dias), 2);
        v_n := v_n + 1;
    end if;

    -- f. Ninguna meta diaria cumplida.
    select count(*) filter (where ad.operable) as operables,
           count(*) filter (where ad.operable and ad.cumplido) as cumplidos,
           round(max(ad.rendimiento_pct), 3) as mejor_dia_pct,
           (select round(percentile_cont(0.5) within group (order by s.atr_pct)::numeric, 2)
              from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
              join public.senales s on s.id = o.senal_id
             where c.agente_id = p_agente_id and o.fecha_entrada >= v_desde) as atr_mediano
      into v_r
      from public.agente_dias ad
     where ad.agente_id = p_agente_id and ad.fecha >= v_dias and ad.fecha < (now() at time zone 'UTC')::date;
    if v_r.operables >= (u ->> 'metas_min_dias')::int and v_r.cumplidos = 0 then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'diagnostico:meta' || v_sufijo,
            'Mi meta diaria no es alcanzable con mi perfil',
            format('0 de %s días operables con la meta del %s %% cumplida. Mejor día: %s %%. ATR mediano de mis entradas: %s %%.',
                   v_r.operables, v_ag.objetivo_diario_pct, coalesce(v_r.mejor_dia_pct::text, 'sin dato'),
                   coalesce(v_r.atr_mediano::text, 'sin dato')),
            'Si la meta exige más movimiento del que da el mercado que opero, o cambio de perfil o cambio de meta.',
            jsonb_build_object('dias_operables', v_r.operables, 'cumplidos', 0,
                               'meta_pct', v_ag.objetivo_diario_pct, 'mejor_dia_pct', v_r.mejor_dia_pct,
                               'atr_mediano', v_r.atr_mediano), 2);
        v_n := v_n + 1;
    end if;

    -- g. Prácticas adoptadas que empeoran ahora.
    for v_r in
        select ad.practica_id, p.titulo, count(o.id) as ops, round(avg(o.pnl_pct), 4) as pnl_medio,
               jsonb_agg(o.id order by o.id) as ordenes
          from public.mp_adopciones ad
          join public.mejores_practicas p on p.id = ad.practica_id
          join public.cuentas_simulacion c on c.agente_id = ad.agente_id
          join public.ordenes o on o.cuenta_id = c.id and o.estado = 'cerrada'
                               and o.fecha_entrada >= greatest(ad.adoptada_en, v_desde)
         where ad.agente_id = p_agente_id and ad.abandonada_en is null
         group by ad.practica_id, p.titulo
        having count(o.id) >= (u ->> 'practica_min_ops')::int and avg(o.pnl_pct) < 0
    loop
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla',
            'diagnostico:practica:' || v_r.practica_id || v_sufijo,
            'La práctica «' || v_r.titulo || '» ya no me funciona',
            format('%s operaciones en 14 días con la práctica aplicada y un P&L medio del %s %%.', v_r.ops, v_r.pnl_medio),
            'Una práctica que funcionó puede haber sido situacional: si el mercado ha cambiado, seguirla es seguir un error.',
            jsonb_build_object('practica_id', v_r.practica_id, 'ops', v_r.ops, 'pnl_medio_pct', v_r.pnl_medio,
                               'ordenes', v_r.ordenes), 3);
        v_n := v_n + 1;
    end loop;

    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'agente',
            v_ag.nombre || case when v_n = 0 then ' revisa su semana: nada que pedir'
                                else format(' revisa su semana y pide %s cambios', v_n) end,
            jsonb_build_object('autodiagnostico', v_n));
    return v_n;
end;
$$;

create function public.fn_autodiagnostico_agentes()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag  record;
    v_out jsonb := '{}'::jsonb;
begin
    for v_ag in select id, nombre from public.agentes where estado <> 'game_over' order by id loop
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

-- Lunes 00:17 UTC: diez minutos después del corte semanal (00:07).
do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('autodiagnostico-agentes', '17 0 * * 1',
                                        'select public.fn_autodiagnostico_agentes()')$q$;
        raise notice 'autodiagnostico-agentes programado los lunes a las 00:17 UTC';
    else
        raise notice 'pg_cron no disponible: el autodiagnóstico no queda programado (esperado en la CI)';
    end if;
end
$cron$;


-- ═════════════════════════════════════════════════════════════════════
-- Permisos
-- ═════════════════════════════════════════════════════════════════════
-- Las funciones de tiempo y de régimen no tocan datos de nadie: las
-- vistas (security_invoker) las llaman con el rol de quien consulta.
revoke execute on function public.fn_mercado_de_clase(text)                         from public, anon;
revoke execute on function public.fn_dia_de_sesion(text, date)                      from public, anon;
revoke execute on function public.fn_sesion_abierta(text, timestamptz)              from public, anon;
revoke execute on function public.fn_minutos_restantes_sesion(text, timestamptz)    from public, anon;
revoke execute on function public.fn_proxima_apertura(text, timestamptz)            from public, anon;
revoke execute on function public.fn_sesiones_entre(text, date, date)               from public, anon;
revoke execute on function public.fn_regimen_mercado()                              from public, anon;
grant  execute on function public.fn_mercado_de_clase(text)                         to authenticated;
grant  execute on function public.fn_dia_de_sesion(text, date)                      to authenticated;
grant  execute on function public.fn_sesion_abierta(text, timestamptz)              to authenticated;
grant  execute on function public.fn_minutos_restantes_sesion(text, timestamptz)    to authenticated;
grant  execute on function public.fn_proxima_apertura(text, timestamptz)            to authenticated;
grant  execute on function public.fn_sesiones_entre(text, date, date)               to authenticated;
grant  execute on function public.fn_regimen_mercado()                              to authenticated;

revoke execute on function public.fn_estimar_orden()                 from public, anon, authenticated;
revoke execute on function public.fn_practica_regimen()              from public, anon, authenticated;
revoke execute on function public.fn_contar_saldo_atrapado()         from public, anon, authenticated;
revoke execute on function public.fn_umbrales_autodiagnostico()      from public, anon, authenticated;
revoke execute on function public.fn_autodiagnostico_agente(bigint)  from public, anon, authenticated;
revoke execute on function public.fn_autodiagnostico_agentes()       from public, anon, authenticated;
grant  execute on function public.fn_autodiagnostico_agentes()       to service_role;
