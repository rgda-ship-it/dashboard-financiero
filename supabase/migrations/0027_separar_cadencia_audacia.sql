-- ─────────────────────────────────────────────────────────────────────
-- 0027 — Cadencia y Audacia se separan por volatilidad (D19, 2026-10-05).
--
-- Cadencia y Audacia abrían las mismas órdenes en el mismo minuto (O, NLY,
-- AGNC, KMB, BAC, FLO, QFIN…): solo cambiaba el tamaño. Sus filtros casi
-- coincidían —fuerza media o alta, acciones y cripto, cualquier origen de
-- niveles— y el único que debía separarlas, el ATR ≥ 1,5 % de Audacia, no
-- filtra nada: casi toda acción tiene un ATR entre el 2 y el 2,5 %. Medido
-- en producción (14 días): cada día, TODAS las candidatas de Cadencia eran
-- también de Audacia. Con el reparto de la 0023 las dos marcan casi todas
-- sus candidatas, así que el experimento comparaba lo mismo dos veces.
--
-- El doc 03 §3.1 ya decía en qué se diferencian: Audacia «necesita
-- recorrido» (ATR alto) y para Cadencia la volatilidad es «indiferente».
-- Ahora el ATR las separa con un corte común:
--
--   Cadencia  atr_pct_max 2,3   (lo tranquilo)
--   Audacia   atr_pct_min 2,3   (lo que se mueve)
--
-- El corte sale de probar 2,0 · 2,2 · 2,3 · 2,4 · 2,5 · 3,0 sobre los 10
-- días de bolsa de esas dos semanas. Entre 2,2 y 2,4 las dos tienen al
-- menos 2 símbolos candidatos todos los días; en 2,0 Cadencia se queda
-- corta 4 días y en 2,5 Audacia 3 (en 3,0, 6). Con 2,3: Cadencia 5,1
-- símbolos de media, Audacia 4,1.
--
-- Un ATR exactamente igual a 2,3000 entra en las dos (los filtros son
-- `>` y `<` estrictos para descartar): con 4 decimales es despreciable.
-- Las posiciones abiertas no cambian: el filtro solo decide entradas.
-- Prudencia (ATR ≤ 3 %, solo acciones y criterios más estrictos) sigue
-- compartiendo terreno con Cadencia y en parte con Audacia.
-- ─────────────────────────────────────────────────────────────────────

update public.agentes
   set estrategia = estrategia || '{"atr_pct_max": 2.3}'::jsonb
 where nombre = 'Cadencia';

update public.agentes
   set estrategia = estrategia || '{"atr_pct_min": 2.3}'::jsonb
 where nombre = 'Audacia';
