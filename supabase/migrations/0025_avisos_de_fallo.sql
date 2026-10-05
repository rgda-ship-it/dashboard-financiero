-- ─────────────────────────────────────────────────────────────────────
-- 0025 — Un ciclo de agente que falla deja aviso (2026-10-05).
--
-- `fn_ciclo_agentes` captura el error de cada agente para que uno roto no
-- pare a los demás, pero solo emitía un `raise warning`, que no se guarda
-- en ningún sitio: el agente dejaba de operar y de comunicar sin que nada
-- lo dijera. El dueño lo notó como «hace rato que no piden nada» y hubo
-- que ir al SQL Editor para saber si funcionaban (funcionaban: estaban
-- callados porque no tenían nada nuevo que hacer).
--
-- Ahora:
--   · el fallo de un agente deja un evento `fallo` con el error, su código
--     y dónde ocurrió, como mucho uno por hora por agente y error (el
--     ciclo corre cada 5 minutos: sin eso serían 12 avisos por hora);
--   · cuando vuelve a completar un ciclo tras un fallo, un evento lo dice;
--   · los dos pasos globales —observar precios y resolver decisiones— van
--     también protegidos: hasta ahora un error en ellos tumbaba el ciclo
--     de los tres agentes a la vez, y solo `cron.job_run_details` lo veía.
-- ─────────────────────────────────────────────────────────────────────

alter table public.eventos_sistema drop constraint eventos_sistema_tipo_check;
alter table public.eventos_sistema add constraint eventos_sistema_tipo_check check (tipo in (
    'sys', 'cambio_fase', 'deterioro', 'proveedor', 'orden_cerrada', 'game_over',
    'corte_semanal', 'backlog_nuevo', 'activo_listo', 'etl', 'practica', 'agente', 'fallo'));

create function public.fn_registrar_fallo(
    p_agente_id bigint, p_donde text, p_error text, p_codigo text, p_contexto text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_nombre text;
begin
    -- El mismo error en el mismo sitio, una vez por hora.
    if exists (select 1 from public.eventos_sistema
                where tipo = 'fallo'
                  and agente_id is not distinct from p_agente_id
                  and datos ->> 'donde' = p_donde
                  and datos ->> 'error' = p_error
                  and creado_en > now() - interval '1 hour') then
        return false;
    end if;
    select nombre into v_nombre from public.agentes where id = p_agente_id;
    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'fallo',
            case when p_agente_id is null
                 then format('El ciclo de los agentes falló al %s: %s', p_donde, p_error)
                 else format('El ciclo de %s falló: %s', coalesce(v_nombre, 'agente ' || p_agente_id), p_error) end,
            jsonb_build_object('donde', p_donde, 'error', p_error, 'codigo', p_codigo,
                               'contexto', left(p_contexto, 2000)));
    return true;
end;
$$;

revoke execute on function public.fn_registrar_fallo(bigint, text, text, text, text) from public, anon, authenticated;

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

    for v_id in select id from public.agentes order by id
    loop
        begin
            v_out := v_out || public.fn_ciclo_agente(v_id);

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
