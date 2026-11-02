-- ─────────────────────────────────────────────────────────────────────
-- 0054 — Dos peticiones del backlog revisadas el 2-11 (doc fase-3/07 §7).
--
--   · «Ampliar mi riesgo abierto por mercado» (Prudencia, 120 descartes por
--     `riesgo_clase_lleno` en una semana, casi todos el 28-10 con ripple
--     abierta). Probado en el laboratorio con una cuenta para acciones y
--     cripto y los límites de producción: con 2× o 3× su riesgo en cripto
--     a la vez, en vez de 1×, entra en más cripto y acaba peor, en todo el
--     periodo y en validación, a 10 y a 5 años. Sus cripto valen −0,12 a
--     −0,19 R en validación. → rechazada.
--   · «Mi saldo queda atrapado con la bolsa cerrada» (Audacia, 39 ciclos).
--     Pide vender acciones antes del cierre para tener saldo para cripto
--     por la noche. Sería cerrar operaciones a medias cada tarde, pagando
--     el spread, por candidatas que quizá no aparezcan; la rotación ya
--     libera saldo al abrir la bolsa (el 2-11, NLY → bitcoin-cash en el
--     mismo ciclo). → rechazada.
--
-- Las dos tocan reglas del grupo de control: como «El filtro X…» (0051),
-- rechazadas no se reabren mientras las consecuencias estén suspendidas.
-- Las ocurrencias y la evidencia se siguen actualizando.
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.fn_registrar_backlog(
    p_agente_id bigint, p_tipo text, p_clave text, p_titulo text,
    p_descripcion text, p_justificacion text, p_evidencia jsonb, p_prioridad int)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id    bigint;
    v_hoy   date := (now() at time zone 'UTC')::date;
    v_nuevo boolean := false;
begin
    insert into public.agente_backlog
        (agente_id, tipo, titulo, descripcion, justificacion, evidencia,
         clave_deduplicacion, agentes_solicitantes, prioridad_sugerida)
    values (p_agente_id, p_tipo, p_titulo, p_descripcion, p_justificacion, p_evidencia,
            p_clave, array[p_agente_id], p_prioridad)
    on conflict (tipo, clave_deduplicacion) do nothing
    returning id into v_id;

    if v_id is not null then
        v_nuevo := true;
        insert into public.agente_backlog_ocurrencias (backlog_id, agente_id, fecha)
        values (v_id, p_agente_id, v_hoy);
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'backlog_nuevo',
                (select nombre from public.agentes where id = p_agente_id) || ' pide: ' || p_titulo,
                jsonb_build_object('backlog_id', v_id, 'tipo', p_tipo, 'clave', p_clave));
        return true;
    end if;

    select id into v_id from public.agente_backlog
     where tipo = p_tipo and clave_deduplicacion = p_clave;

    insert into public.agente_backlog_ocurrencias (backlog_id, agente_id, fecha)
    values (v_id, p_agente_id, v_hoy)
    on conflict do nothing;
    if found then
        -- 0029: una ocurrencia nueva reabre lo que se dio por resuelto. La
        -- resolución anterior se conserva detrás de la marca de reapertura.
        -- 0044: salvo la meta y la semana deficiente de un agente con las
        -- consecuencias semanales suspendidas (0042): se sabe y se decidió
        -- que no se alcanzan, así que no se reabren cada lunes.
        -- 0051: tampoco «El filtro X me deja sin operar»: durante el
        -- experimento las reglas no cambian, y el filtro se prueba en el
        -- laboratorio (fuente H3 de las hipótesis).
        -- 0054: ni «Ampliar mi riesgo…» ni «Mi saldo queda atrapado…», por
        -- lo mismo.
        if exists (select 1 from public.agente_backlog
                    where id = v_id and estado in ('implementado', 'rechazado'))
           and not ((p_clave like 'diagnostico:meta:%' or p_clave like 'ajuste_regla:semana_deficiente:%'
                     or p_clave like 'diagnostico:filtro:%' or p_clave like 'diagnostico:riesgo\_%'
                     or p_clave like 'diagnostico:saldo_atrapado:%')
                    and exists (select 1 from public.agentes
                                 where id = p_agente_id and not consecuencias_semanales)) then
            update public.agente_backlog
               set resolucion = format('Reabierta el %s por una ocurrencia nueva (%s). Antes, %s: %s',
                                       v_hoy, (select nombre from public.agentes where id = p_agente_id),
                                       estado, coalesce(resolucion, 'sin resolución')),
                   estado = 'nuevo'
             where id = v_id;
            insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
            values (p_agente_id, 'backlog_nuevo',
                    (select nombre from public.agentes where id = p_agente_id) || ' vuelve a pedir: ' || p_titulo,
                    jsonb_build_object('backlog_id', v_id, 'tipo', p_tipo, 'clave', p_clave, 'reabierta', true));
        end if;
        update public.agente_backlog
           set ocurrencias = ocurrencias + 1,
               agentes_solicitantes = case when p_agente_id = any(agentes_solicitantes)
                                           then agentes_solicitantes
                                           else agentes_solicitantes || p_agente_id end,
               evidencia = p_evidencia,
               -- 0044: la descripción es la de la última ocurrencia, como la
               -- evidencia (antes se quedaba en la primera: «W40» con
               -- evidencia de W41).
               descripcion = p_descripcion,
               actualizado_en = now()
         where id = v_id;
    end if;
    return false;
end;
$$;

update public.agente_backlog
   set estado = 'rechazado',
       resolucion = 'Probado en el laboratorio (doc fase-3/07 §7, 0054): con 2× o 3× tu riesgo en cripto a la vez, '
                 || 'en vez de 1×, entras en más cripto y acabas peor, en todo el periodo y en validación, a 10 y a '
                 || '5 años. Tus operaciones cripto valen −0,12 a −0,19 R en validación: el límite te protege. '
                 || 'Revisado el 2026-11-02.',
       revisado_en = now(), actualizado_en = now()
 where clave_deduplicacion like 'diagnostico:riesgo\_clase\_lleno:%'
   and estado in ('nuevo', 'en_revision');

update public.agente_backlog
   set estado = 'rechazado',
       resolucion = 'Vender acciones antes del cierre para tener saldo para cripto sería cerrar operaciones a medias '
                 || 'cada tarde, pagando el spread, por candidatas que quizá no aparezcan. La rotación ya libera saldo '
                 || 'al abrir la bolsa (el 2-11, NLY → bitcoin-cash en el mismo ciclo). Las reglas del grupo de '
                 || 'control no cambian durante el experimento. Revisado el 2026-11-02 (0054).',
       revisado_en = now(), actualizado_en = now()
 where clave_deduplicacion like 'diagnostico:saldo\_atrapado:%'
   and estado in ('nuevo', 'en_revision');
