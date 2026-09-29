-- ─────────────────────────────────────────────────────────────────────
-- 0015 — El ETL lo dispara Supabase, no el `schedule` de GitHub.
--
-- QUÉ PASABA (medido el 2026-09-29 con `gh run list`)
--
--   etl-cripto, programado cada hora:          corrió cada 3-7 horas.
--   etl-acciones, cada 30 min en sesión (18/día): unas 3 al día, y alguna
--   hasta tres horas tarde (una del 25 arrancó a las 23:59 UTC, con la
--   bolsa cerrada).
--
--   Todas terminaron bien: el problema es que casi nunca EMPEZABAN.
--   GitHub no garantiza los `schedule` — con carga los retrasa o los
--   descarta, sobre todo en repositorios privados del plan gratuito y en
--   las horas en punto, que es justo donde estaban los nuestros.
--
--   Desde el Sprint 6 esto dejó de ser un dato atrasado en pantalla: los
--   agentes solo aceptan señales de menos de 90 minutos, así que con este
--   ritmo casi nunca tenían ninguna.
--
-- LA SOLUCIÓN
--
--   `pg_cron` sí es puntual (el monitor y el ciclo de agentes corren a su
--   minuto). Una tarea suya llama a la API de GitHub con `workflow_dispatch`
--   —que GitHub arranca en segundos, no lo trata como un `schedule`— con el
--   mismo token de Vault que ya usa el alta de activos (`github_pat_altas`,
--   Actions: write sobre este repositorio). Sin secretos nuevos.
--
--     cripto   : cada hora, a los 7 minutos (lejos de la hora en punto).
--     acciones : a los 7 y a los 37 de cada hora, SOLO con Nueva York
--                abierto (misma ventana que `ventana_mercado.py`).
--
--   Los `schedule` de GitHub se quedan como red de seguridad, espaciados:
--   si llegan a correr detrás de un disparo, `seleccion_universo.py` ve los
--   activos frescos y la pasada termina sin llamar a ningún proveedor.
-- ─────────────────────────────────────────────────────────────────────

-- ¿Toca disparar el ETL de esta clase en este momento? Pura, para poder
-- probarla con instantes fijos: una invariante que dependiera de la hora
-- a la que corre la CI no sería una invariante.
create function public.fn_etl_toca(p_clase text, p_momento timestamptz)
returns boolean
language sql immutable
as $$
    select case p_clase
        when 'cripto' then true
        -- Misma ventana que `fn_mercado_abierto` (y que ventana_mercado.py),
        -- escrita aquí porque aquella es STABLE y esta tiene que ser pura.
        when 'accion' then
            extract(isodow from p_momento at time zone 'America/New_York') between 1 and 5
            and (p_momento at time zone 'America/New_York')::time between '09:30' and '16:30'
        else false
    end
$$;

-- Dispara un workflow por `workflow_dispatch`. Mismo patrón que
-- `fn_disparar_altas` (0010), generalizado al nombre del workflow; aquella
-- no se toca. `control_despachos` evita dos disparos seguidos del mismo
-- workflow si `pg_cron` solapara pasadas.
create function public.fn_disparar_workflow(p_workflow text, p_intervalo_min interval)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_token  text;
    v_ultimo timestamptz;
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
      using v_token;

    insert into public.control_despachos (clave, ultimo) values (p_workflow, now())
    on conflict (clave) do update set ultimo = excluded.ultimo;
    return 'disparado';
end;
$$;

-- Lo que llama `pg_cron`.
create function public.fn_programar_etl()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ahora timestamptz := now();
begin
    return jsonb_build_object(
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

revoke execute on function public.fn_etl_toca(text, timestamptz)              from public, anon, authenticated;
revoke execute on function public.fn_disparar_workflow(text, interval)        from public, anon, authenticated;
revoke execute on function public.fn_programar_etl()                          from public, anon, authenticated;
grant  execute on function public.fn_programar_etl()                          to service_role;

-- Dos tareas y no una, porque el cripto va cada hora y las acciones cada
-- media: la de los :07 dispara las dos clases, la de los :37 solo tiene
-- efecto en acciones (el cripto responde 'reciente' por su intervalo).
do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('etl-disparo', '7,37 * * * *',
                                        'select public.fn_programar_etl()')$q$;
        raise notice 'etl-disparo programado a los :07 y :37 de cada hora';
    else
        raise notice 'pg_cron no disponible: el ETL no queda programado desde la BD (esperado en la CI)';
    end if;
end
$cron$;
