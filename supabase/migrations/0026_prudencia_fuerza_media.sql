-- ─────────────────────────────────────────────────────────────────────
-- 0026 — Prudencia admite la fuerza media (D18, 2026-10-05).
--
-- Prudencia pidió por el backlog «Revisar la estrategia de Prudencia»
-- tras una semana deficiente, y desde el 2026-10-02 pasa los ciclos «sin
-- candidatos». Se midió en producción, sobre los 7 días anteriores, qué
-- filtro la deja fuera (señales de acciones alcistas y operables):
--
--   833 señales · pasan fuerza alta 38 · estructura 833 · R:R ≥ 2 472 ·
--   ATR ≤ 3 % 638 · pasan todo 32 (HRL, NLY y KMB, todas el 29-09 al 01-10)
--   fallan SOLO por la fuerza: 388 · solo por R:R, ATR o estructura: 0
--
-- El cuello de botella es la fuerza: «alta» exige que 3 indicadores voten
-- en la misma dirección, y eso es raro (38 de 833). Las 32 que pasaron sí
-- se operaron (los descartes por `posicion_abierta` de esos días eran
-- ella misma con la posición ya abierta): el resto de los filtros y el
-- dimensionado funcionan. Con fuerza media habría tenido 9 símbolos en la
-- semana en vez de 3. Su balance con solo «alta» (HRL +6,96 $ y cuatro
-- de NLY casi planas) no basta para defender la exigencia.
--
-- Decisión del dueño: Prudencia admite `media` y `alta`. Lo que la sigue
-- haciendo prudente no cambia: solo acciones, niveles de estructura,
-- R:R ≥ 2, ATR ≤ 3 %, como mucho 3× y un 1,5 % de riesgo por operación.
--
-- Lo que se descartó, con datos, en la misma revisión:
--   · Un filtro de distancia mínima al stop (en ATR). Los stops pegados
--     al precio (< 0,25 ATR) saltan a menudo, pero pierden céntimos y
--     sumaron +29,76 $ en la semana; los de stop «sano» (≥ 0,5 ATR),
--     −21,64 $. Filtrarlos habría quitado lo que ganó.
--   · Cambiar el disparador de `sesgo_corto`. El mercado que lee el motor
--     no es bajista (17–29 % de señales bajistas en acciones, ≤ 10 % en
--     cripto, ninguna bajista fuerte), así que no pedir cortos es coherente.
--
-- Solo cambia la estrategia guardada: el trigger de versiones sube su
-- versión y deja la anterior en `agente_estrategia_versiones`.
-- ─────────────────────────────────────────────────────────────────────

update public.agentes
   set estrategia = jsonb_set(estrategia, '{fuerzas_admitidas}', '["media", "alta"]'::jsonb)
 where nombre = 'Prudencia';

-- La petición queda atendida, con el porqué en la resolución. Si vuelve a
-- tener una semana deficiente, la misma clave suma ocurrencias.
update public.agente_backlog
   set estado = 'implementado',
       resolucion = '0026 (D18): Prudencia admite fuerza media. El filtro de fuerza alta '
                 || 'dejaba fuera 388 de 833 señales que pasaban todo lo demás.',
       revisado_en = now(),
       actualizado_en = now()
 where clave_deduplicacion = 'ajuste_regla:semana_deficiente:agente_'
                             || (select id from public.agentes where nombre = 'Prudencia')
   and estado in ('nuevo', 'en_revision');
