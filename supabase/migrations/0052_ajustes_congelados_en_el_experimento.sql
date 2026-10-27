-- ─────────────────────────────────────────────────────────────────────
-- 0052 — Ajustes automáticos congelados durante el experimento
-- (2026-10-27; doc fase-3/08 §4.2, decisión del dueño).
--
-- Desde la 0016 (y la 0024), con 10 decisiones resueltas de un tipo cada
-- agente con metas cambia solo su umbral de rotación, su toma parcial o su
-- salida por deterioro. Eso mueve al grupo de control, que no debe cambiar
-- de reglas mientras dura el experimento: el 15-10 Audacia y Cadencia
-- apagaron la salida por deterioro, y el 27-10 Prudencia estaba a dos
-- salidas de apagarla (8 de 10, efecto medio negativo) y Cadencia a dos
-- rotaciones de bajar su umbral de 1,5 a 1,4.
--
-- Ahora fn_ajustar_parametros no cambia nada en un agente con
-- `consecuencias_semanales = false` (el mismo interruptor que suspende la
-- cuarentena, 0042). Las decisiones se siguen registrando y resolviendo:
-- al acabar el experimento, el ajuste usa toda esa evidencia.
-- Los dos ajustes del 15-10 se quedan como están (deshacerlos también
-- sería cambiar las reglas).
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.fn_ajustar_parametros(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_desde   timestamptz;
    v_n       int;
    v_media   numeric;
    v_nuevo   jsonb;
    v_propio  numeric;
    v_otro    numeric;
    v_n_otro  int;
    v_modo    text;
    v_cambios int := 0;
begin
    select * into v_ag from public.agentes where id = p_agente_id;

    -- 0052: congelado mientras dura el experimento. Las decisiones se
    -- siguen registrando y resolviendo; al volver las consecuencias
    -- (`consecuencias_semanales = true`) se ajusta con toda esa evidencia.
    if not v_ag.consecuencias_semanales then
        return 0;
    end if;

    v_p := public.fn_parametros_agente(v_ag);

    -- ── Rotación ────────────────────────────────────────────────────
    if v_p ->> 'rotacion_umbral' is not null then
        select coalesce(max(creado_en), '-infinity') into v_desde
          from public.agente_ajustes where agente_id = p_agente_id and tipo = 'rotacion';
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'rotacion' and resuelta_en > v_desde;
        if v_n >= 10 and v_media <> 0 then
            v_nuevo := to_jsonb(case when v_media < 0
                                     then least(3.0, (v_p ->> 'rotacion_umbral')::numeric + 0.2)
                                     else greatest(1.1, (v_p ->> 'rotacion_umbral')::numeric - 0.1) end);
            if v_nuevo <> v_p -> 'rotacion_umbral' then
                insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
                values (p_agente_id, 'rotacion', v_p -> 'rotacion_umbral', v_nuevo,
                        jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
                update public.agentes set estrategia = jsonb_set(estrategia, '{rotacion_umbral}', v_nuevo)
                 where id = p_agente_id;
                v_cambios := v_cambios + 1;
            end if;
        end if;
    end if;

    -- ── Toma parcial ────────────────────────────────────────────────
    select coalesce(max(creado_en), '-infinity') into v_desde
      from public.agente_ajustes where agente_id = p_agente_id and tipo = 'parcial';
    if jsonb_typeof(v_p -> 'tp_parcial') = 'object' then
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'parcial' and resuelta_en > v_desde;
        if v_n >= 10 and v_media < 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'parcial', v_p -> 'tp_parcial', 'null'::jsonb,
                    jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{tp_parcial}', 'null'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    else
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id <> p_agente_id and tipo = 'parcial' and resuelta_en > v_desde;
        if v_n >= 10 and v_media > 0 then
            v_nuevo := jsonb_build_object('recorrido', 0.5, 'fraccion', 0.5, 'mover_stop', false);
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'parcial', 'null'::jsonb, v_nuevo,
                    jsonb_build_object('decisiones_de_otros', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{tp_parcial}', v_nuevo)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    end if;

    -- ── Salida por deterioro (0024) ─────────────────────────────────
    -- Como la toma parcial: si la usa y le cuesta dinero, la apaga; si la
    -- tiene apagada y a los demás les funciona, la vuelve a encender.
    select coalesce(max(creado_en), '-infinity') into v_desde
      from public.agente_ajustes where agente_id = p_agente_id and tipo = 'deterioro';
    if coalesce((v_p ->> 'salida_deterioro')::boolean, true) then
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'deterioro' and resuelta_en > v_desde;
        if v_n >= 10 and v_media < 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'deterioro', 'true'::jsonb, 'false'::jsonb,
                    jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{salida_deterioro}', 'false'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    else
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id <> p_agente_id and tipo = 'deterioro' and resuelta_en > v_desde;
        if v_n >= 10 and v_media > 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'deterioro', 'false'::jsonb, 'true'::jsonb,
                    jsonb_build_object('decisiones_de_otros', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{salida_deterioro}', 'true'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    end if;

    -- ── Reparto: retirado en la 0023 ────────────────────────────────
    -- Ya no se elige entre «cupo» y «concentrado»: cuánto se reparte lo
    -- decide la exigencia de cada día. Las decisiones de reparto se siguen
    -- registrando y resolviendo (retorno sobre el margen) como evidencia.

    if v_cambios > 0 then
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'agente',
                v_ag.nombre || ' ajusta su estrategia con lo aprendido',
                jsonb_build_object('ajustes', v_cambios));
    end if;
    return v_cambios;
end;
$$;
