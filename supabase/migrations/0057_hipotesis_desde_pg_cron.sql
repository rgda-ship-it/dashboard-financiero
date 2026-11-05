-- ─────────────────────────────────────────────────────────────────────
-- 0057 — Cabos sueltos de fiabilidad (doc fase-3/08 §4.6, 2026-11-05).
--
--   1. `hipotesis.yml` se dispara desde `pg_cron`, como el ETL. El
--      `schedule` de GitHub llegó el 26-10 con 5 horas de retraso. La
--      tarea `hipotesis-agentes` corre los lunes a las 02:00 UTC (después
--      del autodiagnóstico de las 00:17, que deja las hipótesis
--      `propuesta`) y lanza el workflow con `fn_disparar_workflow`, que
--      ahora lo admite. El `schedule` de GitHub se queda de respaldo a las
--      06:00: si el disparo de las 02:00 ya las probó, no encuentra nada
--      pendiente. El resultado del disparo lo revisa `fn_revisar_despachos`
--      como el de los ETL, y sale en el panel de salud.
--   2. El rol de lectura ve `cron.job` (solo los metadatos de las tareas
--      programadas): así se comprueba que una tarea existe y está activa
--      sin la URL de administrador.
--
-- No cambia cómo operan los agentes ni el ETL.
-- ─────────────────────────────────────────────────────────────────────

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
    if p_workflow not in ('etl-cripto.yml', 'etl-acciones.yml', 'hipotesis.yml') then
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

revoke execute on function public.fn_disparar_workflow(text, interval) from public, anon, authenticated;

do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('hipotesis-agentes', '0 2 * * 1',
                    $c$select public.fn_disparar_workflow('hipotesis.yml', interval '6 days')$c$)$q$;
    end if;
end
$cron$;

do $lectura$
begin
    if exists (select 1 from pg_roles where rolname = 'analista_lectura')
       and to_regclass('cron.job') is not null then
        grant usage on schema cron to analista_lectura;
        grant select on cron.job to analista_lectura;
    end if;
end
$lectura$;
