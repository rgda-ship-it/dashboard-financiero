-- ─────────────────────────────────────────────────────────────────────
-- 0045 — Salud del sistema (Fase 3, entrega 1; doc fase-3/00 §3).
--
-- La revisión del 2026-10-24 encontró dos fallos que nadie vio a tiempo,
-- porque el sistema no los contaba en ningún sitio:
--
--   1. Desde el 23-10 a las 19:07 UTC GitHub responde 401 («Bad
--      credentials») a cada disparo del ETL: el token `github_pat_altas`
--      de Vault ha caducado. `fn_disparar_workflow` lanza la petición con
--      pg_net, que es asíncrono, y apuntaba «disparado» sin mirar la
--      respuesta. Solo quedaban los `schedule` de respaldo de GitHub (dos
--      pasadas de cripto en 12 horas).
--   2. Del 19 al 20-10 el ciclo de Cadencia falló 8 veces seguidas, y el
--      de Prudencia 2, porque la toma parcial intentaba cerrar el 50 % de
--      una posición de 1 acción de AMZN. `fn_cerrar_parcial` lanza la
--      excepción (bien, para el usuario), y el ciclo entero del agente se
--      deshacía: ni entradas, ni salidas por deterioro, ni rotaciones.
--
-- Lo que cambia:
--   · La toma parcial del agente se salta la posición que no se puede
--     partir en unidades enteras (`fn_parcial_divisible`). La posición
--     sigue entera hacia su objetivo o su stop, como si no tuviera toma
--     parcial; el stop tampoco se mueve. Es un arreglo, no un cambio de
--     estrategia: el grupo de control no cambia de reglas.
--   · Cada disparo guarda el id de su petición de pg_net. En la pasada
--     siguiente, `fn_revisar_despachos` lee la respuesta: si no es 2xx,
--     deja un evento `fallo` (uno por episodio, no uno por pasada) y,
--     cuando vuelve a funcionar, un evento `etl` que lo dice.
--   · `rpc_salud_sistema()` (solo admin): disparos del ETL y su última
--     respuesta, frescura de las señales por clase y fallos de ciclo de
--     cada agente en 24 h. Es lo que pinta el panel «Salud del sistema».
--   · El rol de solo lectura `analista_lectura` (lo creó el dueño a
--     mano, no existe en la CI ni en otro proyecto) lee todas las tablas
--     y vistas de `public`, también las que se creen después, y ejecuta
--     las funciones no volátiles que esas vistas usan. Hasta ahora no
--     podía leer 9 objetos (entre ellos `v_comparativa_agentes` y
--     `agente_decisiones_diarias`) y `scripts/revision_agentes.sql` no
--     corría con él. Una función estable no puede escribir, y la sesión
--     de `scripts/consultar.py` es de solo lectura.
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- 1. Toma parcial: solo si la posición se puede partir
-- ═════════════════════════════════════════════════════════════════════
-- Misma regla que `fn_cerrar_parcial`: una acción se cierra por unidades
-- enteras, hacia abajo, y tiene que quedar al menos una.
create function public.fn_parcial_divisible(p_clase text, p_cantidad numeric, p_fraccion numeric)
returns boolean
language sql immutable
as $$
    select case when p_clase = 'accion'
                then floor(p_cantidad * p_fraccion) >= 1 and floor(p_cantidad * p_fraccion) < p_cantidad
                else round(p_cantidad * p_fraccion, 8) > 0 end
$$;

create or replace function public.fn_agente_tomas_parciales(p_agente_id bigint)
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
        -- 0045: 1 acción no se parte. Antes `fn_cerrar_parcial` lanzaba y
        -- deshacía el ciclo entero del agente.
        continue when not public.fn_parcial_divisible(v_o.clase, v_o.cantidad, (v_tp ->> 'fraccion')::numeric);

        v_nivel := v_o.precio_entrada + (v_tp ->> 'recorrido')::numeric * (v_o.tp - v_o.precio_entrada);
        -- 0034: se compara con el precio de venta, como el monitor.
        continue when public.fn_precio_venta(v_o.activo_id, v_o.precio_vivo) < v_nivel
                   or public.fn_precio_venta(v_o.activo_id, v_o.precio_vivo) >= v_o.tp;

        -- Al NIVEL, no al precio observado (misma disciplina que M3).
        v_res := public.fn_cerrar_parcial(v_o.id, (v_tp ->> 'fraccion')::numeric, v_nivel,
                                          'tp_parcial', v_o.precio_vivo);
        continue when not coalesce((v_res ->> 'cerrada')::boolean, false);

        if coalesce((v_tp ->> 'mover_stop')::boolean, false) then
            -- «Stop a la entrada»: 5 puntos básicos por debajo, porque el
            -- CHECK de `ordenes` exige sl < entrada (ver cabecera de 0016).
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

revoke execute on function public.fn_parcial_divisible(text, numeric, numeric) from public, anon;

-- ═════════════════════════════════════════════════════════════════════
-- 2. Disparos del ETL: mirar la respuesta
-- ═════════════════════════════════════════════════════════════════════
alter table public.control_despachos
    add column peticion_id    bigint,
    add column estado_http    int,
    add column respuesta      text,
    add column fallando_desde timestamptz;

comment on column public.control_despachos.peticion_id is
    'Id de la petición de pg_net del último disparo (net._http_response.id). Lo lee fn_revisar_despachos.';
comment on column public.control_despachos.estado_http is
    'Código HTTP de la respuesta al último disparo; null mientras no se ha revisado y 0 si no respondió a tiempo.';
comment on column public.control_despachos.fallando_desde is
    'Desde cuándo fallan los disparos de este workflow; null si el último fue bien.';

create or replace function public.fn_disparar_workflow(p_workflow text, p_intervalo_min interval)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_token    text;
    v_ultimo   timestamptz;
    v_peticion bigint;
begin
    if p_workflow not in ('etl-cripto.yml', 'etl-acciones.yml') then
        raise exception 'Workflow no admitido: %', p_workflow using errcode = '22023';
    end if;
    if to_regclass('vault.decrypted_secrets') is null
       or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
        return 'sin_infraestructura';
    end if;

    select ultimo into v_ultimo from public.control_despachos where clave = p_workflow for update;
    if v_ultimo is not null and v_ultimo > now() - p_intervalo_min then
        return 'reciente';
    end if;

    execute $q$select decrypted_secret from vault.decrypted_secrets
               where name = 'github_pat_altas' limit 1$q$
       into v_token;
    if v_token is null then
        return 'sin_token';
    end if;

    execute format($q$select net.http_post(
                 url     := 'https://api.github.com/repos/rgda-ship-it/dashboard-financiero/actions/workflows/%s/dispatches',
                 body    := '{"ref":"master"}'::jsonb,
                 headers := jsonb_build_object(
                              'Authorization', 'Bearer ' || $1,
                              'Accept', 'application/vnd.github+json',
                              'X-GitHub-Api-Version', '2022-11-28',
                              'User-Agent', 'dashboard-financiero'),
                 timeout_milliseconds := 5000)$q$, p_workflow)
      into v_peticion
      using v_token;

    -- 0045: la respuesta llega después (pg_net es asíncrono). La revisa
    -- `fn_revisar_despachos` en la pasada siguiente; `fallando_desde` se
    -- conserva hasta que un disparo vaya bien.
    insert into public.control_despachos (clave, ultimo, peticion_id)
    values (p_workflow, now(), v_peticion)
    on conflict (clave) do update
       set ultimo = excluded.ultimo, peticion_id = excluded.peticion_id,
           estado_http = null, respuesta = null;
    return 'disparado';
end;
$$;

create function public.fn_revisar_despachos()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_d       record;
    v_estado  int;
    v_timeout boolean;
    v_texto   text;
    v_motivo  text;
    v_filas   int;
    v_ok      boolean;
    v_nombre  text;
    v_n       int := 0;
begin
    -- En la CI no hay pg_net: la prueba crea su propia `net._http_response`.
    if to_regclass('net._http_response') is null then
        return 0;
    end if;

    for v_d in select * from public.control_despachos
                where peticion_id is not null and estado_http is null
                for update
    loop
        execute 'select status_code, timed_out, coalesce(error_msg, content::text)
                   from net._http_response where id = $1'
           into v_estado, v_timeout, v_texto
          using v_d.peticion_id;
        get diagnostics v_filas = row_count;
        -- Aún sin respuesta (o pg_net ya la purgó, a las 6 h): el disparo
        -- siguiente la sustituye.
        continue when v_filas = 0;

        v_ok := v_estado between 200 and 299;
        v_motivo := null;
        if not v_ok then
            begin
                v_motivo := v_texto::jsonb ->> 'message';
            exception when others then
                v_motivo := left(v_texto, 200);
            end;
        end if;

        update public.control_despachos
           set estado_http    = coalesce(v_estado, 0),
               respuesta      = case when v_ok then null else left(v_texto, 500) end,
               fallando_desde = case when v_ok then null else coalesce(fallando_desde, v_d.ultimo) end
         where clave = v_d.clave;
        v_n := v_n + 1;

        v_nombre := case v_d.clave when 'etl-acciones.yml' then 'El ETL de acciones'
                                   when 'etl-cripto.yml'   then 'El ETL de cripto'
                                   else v_d.clave end;
        if not v_ok and v_d.fallando_desde is null then
            insert into public.eventos_sistema (tipo, mensaje, datos)
            values ('fallo',
                    format('%s no se pudo lanzar: GitHub respondió %s%s.%s', v_nombre,
                           coalesce(v_estado::text, 'nada en 5 s'),
                           coalesce(' (' || v_motivo || ')', ''),
                           case when v_estado = 401
                                then ' El token github_pat_altas de Vault ha caducado o se ha revocado: renuévalo (RUNBOOK-sprint-4, «Renovación»).'
                                else '' end),
                    jsonb_build_object('donde', 'disparar ' || v_d.clave, 'estado_http', v_estado,
                                       'error', v_motivo, 'peticion_id', v_d.peticion_id));
        elsif v_ok and v_d.fallando_desde is not null then
            insert into public.eventos_sistema (tipo, mensaje, datos)
            values ('etl',
                    format('%s vuelve a lanzarse (fallaba desde el %s UTC)', v_nombre,
                           to_char(v_d.fallando_desde at time zone 'UTC', 'DD-MM HH24:MI')),
                    jsonb_build_object('donde', 'disparar ' || v_d.clave, 'recuperado', true,
                                       'fallando_desde', v_d.fallando_desde));
        end if;
    end loop;
    return v_n;
end;
$$;

-- Lo que llama `pg_cron`. Primero mira cómo fue el disparo anterior.
create or replace function public.fn_programar_etl()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ahora timestamptz := now();
    v_rev   int;
begin
    v_rev := public.fn_revisar_despachos();
    return jsonb_build_object(
        'revisados', v_rev,
        'cripto', case when public.fn_etl_toca('cripto', v_ahora)
                       then public.fn_disparar_workflow('etl-cripto.yml', interval '50 minutes')
                       else 'fuera_de_ventana' end,
        -- Solo en los minutos 7 y 37: la tarea corre dos veces por hora
        -- pero el cripto va una. El intervalo de 20 min es el cinturón.
        'accion', case when public.fn_etl_toca('accion', v_ahora)
                       then public.fn_disparar_workflow('etl-acciones.yml', interval '20 minutes')
                       else 'fuera_de_ventana' end);
end;
$$;

revoke execute on function public.fn_revisar_despachos() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- 3. Salud del sistema, para el panel de administración
-- ═════════════════════════════════════════════════════════════════════
create function public.rpc_salud_sistema()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador ve la salud del sistema.' using errcode = '42501';
    end if;

    return jsonb_build_object(
        'generado_en', now(),
        'despachos', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'workflow', d.clave, 'ultimo', d.ultimo, 'estado_http', d.estado_http,
                       'respuesta', d.respuesta, 'fallando_desde', d.fallando_desde)
                     order by d.clave), '[]'::jsonb)
              from public.control_despachos d
             where d.clave in ('etl-acciones.yml', 'etl-cripto.yml')),
        'senales', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'clase', x.clase, 'activos', x.activos, 'con_senal', x.con_senal,
                       'ultima', x.ultima, 'primera', x.primera)
                     order by x.clase), '[]'::jsonb)
              from (select a.clase, count(*) as activos, count(s.calculado_en) as con_senal,
                           max(s.calculado_en) as ultima, min(s.calculado_en) as primera
                      from public.activos a
                      left join public.senales_vigentes s on s.activo_id = a.id
                     where a.estado = 'activo'
                     group by a.clase) x),
        'agentes', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'agente_id', g.id, 'nombre', g.nombre, 'estado', g.estado,
                       'fallos_24h', f.n, 'ultimo_fallo', f.ultimo, 'ultimo_mensaje', f.mensaje,
                       'en_fallo', f.ultimo is not null and f.ultimo > coalesce(r.ultimo, '-infinity'::timestamptz))
                     order by g.id), '[]'::jsonb)
              from public.agentes g
              left join lateral (
                    select count(*) filter (where e.creado_en > now() - interval '24 hours') as n,
                           max(e.creado_en) as ultimo,
                           (array_agg(e.mensaje order by e.id desc))[1] as mensaje
                      from public.eventos_sistema e
                     where e.agente_id = g.id and e.tipo = 'fallo'
                       and e.creado_en > now() - interval '7 days') f on true
              left join lateral (
                    select max(e.creado_en) as ultimo
                      from public.eventos_sistema e
                     where e.agente_id = g.id and e.tipo = 'agente'
                       and e.datos ->> 'recuperado' = 'true') r on true),
        'fallos_sistema_24h', (
            select count(*) from public.eventos_sistema
             where agente_id is null and tipo = 'fallo' and creado_en > now() - interval '24 hours'));
end;
$$;

revoke execute on function public.rpc_salud_sistema() from public, anon;
grant  execute on function public.rpc_salud_sistema() to authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- 4. El rol de solo lectura lee todo `public`
-- ═════════════════════════════════════════════════════════════════════
do $lectura$
declare
    v_f regprocedure;
begin
    if not exists (select 1 from pg_roles where rolname = 'analista_lectura') then
        return;
    end if;
    grant usage on schema public to analista_lectura;
    grant select on all tables in schema public to analista_lectura;
    -- Lo que creen las migraciones siguientes (las aplica el mismo rol).
    alter default privileges in schema public grant select on tables to analista_lectura;
    -- Solo las funciones no volátiles: no pueden escribir.
    for v_f in select p.oid::regprocedure
                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.prokind = 'f' and p.provolatile in ('i', 's')
    loop
        execute format('grant execute on function %s to analista_lectura', v_f);
    end loop;
end
$lectura$;
