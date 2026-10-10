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
