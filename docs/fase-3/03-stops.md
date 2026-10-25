# Fase 3 — Los stops: qué salvan, qué cortan y si promediar ayuda

> **Para qué sirve**: responde a dos preguntas del dueño (2026-10-25).
> Una: ¿qué porcentaje de los stops salva de una pérdida mayor y cuál
> corta una ganancia posterior, y debe cambiar el cálculo del stop?
> Otra: ¿ayuda abrir la mitad y comprar la otra mitad en el stop previsto,
> sobre todo en mercado bajista?
> **Conclusión**: el stop actual hace su trabajo. Salva bastante más de lo
> que corta, y ni ensancharlo ni promediar mejora a los agentes en general.
> Los stops más anchos apuntan a mejorar a Prudencia y a Cadencia, pero
> no se sostienen a 10 años: es una pista, no un cambio validado (§4).

---

## 1. Cómo se calcula hoy el stop (D21, 0030)

El stop va al soporte de 20 velas, pero a no menos de 1 ATR ni a más de
2 ATR del precio. El objetivo va a la resistencia, como mucho a 2 ATR
(`indicadores/tecnicos.py`, `calcular_niveles_operativos`). Antes de la
0030 el stop quedaba a 0,1–0,2 ATR, dentro del ruido.

## 2. Qué pasa después de un stop

**En producción no se puede medir todavía.** De los 90 stops con datos
posteriores, 88 son de antes de la 0030, con stops a 0,1 ATR, que no son
la regla de hoy. Con la regla actual solo hay 2. La base sigue el precio
después de una salida por objetivo (`precio_max_post_cierre`), pero no
después de un stop.

**En el laboratorio**, con la estrategia de cada agente, 45 activos y 5
años de velas, se clasifica cada stop por lo que pasó en las 10 sesiones
siguientes:
- **salvó una pérdida mayor**: el precio cayó otro riesgo entero por debajo de la salida;
- **cortó una ganancia**: el precio llegó al objetivo original;
- **ni una ni otra**.

| Agente | Stops | Salvó | Cortó una ganancia | Ni una ni otra | Con el stop | Sin el stop* |
|---|---|---|---|---|---|---|
| Prudencia | 149 | **58 %** | 21 % | 20 % | −0,60 R | −0,78 R |
| Cadencia | 90 | **68 %** | 12 % | 20 % | −0,77 R | −1,13 R |
| Audacia | 177 | **52 %** | 11 % | 37 % | −1,01 R | −0,96 R |

\* Sin el stop: la posición se mantiene hasta el objetivo, hasta un stop
al doble de distancia o hasta 10 sesiones.

**Lectura**: por cada stop que corta una ganancia, hay entre 3 y 6 que
evitan una pérdida mayor. En Prudencia y Cadencia el stop ahorra entre
0,2 y 0,4 R por operación; en Audacia es neutro.

**A 10 años** (290, 168 y 344 stops) el reparto se mantiene: salvan el 59,
el 66 y el 48 %; cortan una ganancia el 18, el 13 y el 10 %.

## 3. Reglas alternativas y la entrada escalonada

Con el criterio de las hipótesis: mejora de al menos +0,05 R en
validación, intervalo del 90 % por encima de cero, y percentil ≥ 90
frente a 20 tiradas al azar. «Actual» es el agente tal como opera.

| Variante | Prudencia (actual −0,04 R) | Cadencia (actual +0,00 R) | Audacia (actual +0,20 R) |
|---|---|---|---|
| Stop 0,5–1,5 ATR (más estrecho) | +0,02 R ❌ | −0,02 R ❌ | +0,09 R ❌ |
| Stop 1,5–2,5 ATR, objetivo hasta 3 | +0,10 R ❌ (IC con el cero) | −0,12 R ❌ | +0,11 R ❌ |
| **Stop 2–3 ATR, objetivo hasta 4** | **+0,19 R ✅** (73 ops, IC [+0,01, +0,36], p100) | +0,03 R ❌ | +0,09 R ❌ |
| Solo objetivo hasta 3 ATR | +0,00 R ❌ | −0,05 R ❌ | +0,17 R ❌ |
| Escalonar siempre | −0,02 R ❌ | −0,03 R ❌ | +0,01 R ❌ |
| Escalonar solo bajo la media de 200 | +0,03 R ❌ | +0,08 R ❌ (IC con el cero) | +0,11 R ❌ |

**Comprobación a 10 años** de las dos que más se acercaron:

| Variante | Prudencia | Cadencia | Audacia |
|---|---|---|---|
| Stop 2–3 ATR, objetivo hasta 4 | −0,02 → +0,09 R ❌ (IC [−0,02, +0,19]) | +0,04 → +0,16 R ❌ (IC [−0,05, +0,36], p95) | +0,07 → +0,01 R ❌ |
| Escalonar solo bajo la media de 200 | −0,02 → +0,04 R ❌ | +0,04 → +0,11 R ❌ | +0,07 → +0,03 R ❌ |

Para poder probarlo, el laboratorio admite ahora:
- `sl_min_atr`, `sl_max_atr` y `tp_max_atr` en la estrategia `agente` (producción sigue con 1, 2 y 2);
- la **entrada escalonada** en el motor (`escalon`) y `escalonar` en `agente`.

La entrada escalonada compra media posición a la entrada y la otra media
al llegar al stop previsto, con un stop nuevo a la misma distancia por
debajo. Su R se mide contra la pérdida máxima: las dos mitades compradas
y el stop nuevo, 1,5 veces el riesgo de una entrada normal.

## 4. Qué se decide

- **No se cambia la regla general del stop.** Ensanchar el stop solo
  ayuda a Prudencia; a Audacia la empeora (de +0,20 a +0,09 R), y en
  Cadencia no hay diferencia clara. Una regla general que empeora a un
  agente no es una mejora.
- **Stops de 2 a 3 ATR con objetivo hasta 4 ATR, en Prudencia y
  Cadencia: una pista, no un cambio.** A 5 años pasa en Prudencia
  (−0,04 → +0,19 R); a 10 años, en los dos agentes, mejora pero con el
  intervalo incluyendo el cero. Encaja con su perfil: operan lo tranquilo,
  donde un stop de 1–2 ATR queda cerca del ruido. Se probaron 27 variantes
  (las de este documento y las del doc 02 §5), así que una que pasa en un
  periodo y no en el otro no basta. Queda como candidata a hipótesis
  cuando haya operaciones reales con la regla de la 0030.
- **Promediar a la baja no aporta**, ni siempre ni solo en tendencia
  bajista. Sube el porcentaje de aciertos (del 44–48 % al 52–60 %),
  porque muchas operaciones que habrían tocado el stop se recuperan desde
  el precio medio. Pero las que no se recuperan pierden 1,5 veces el
  riesgo, y la expectativa no mejora en ningún agente. Es el mismo patrón
  que el agente contrario del doc 02: más aciertos no es ganar.
- **En producción, desde la 0048**: cada orden cerrada por stop se sigue
  con las velas de las 10 sesiones siguientes, con la misma regla que el
  laboratorio (`post_stop_evento`: corto, salvo, ambiguo o ninguno), y se
  lee en `v_seguimiento_stops` y en la sección `6_stops` de
  `scripts/revision_agentes.sql`. Solo los stops de entradas desde la 0030
  (10-10) juzgan la regla de hoy: los anteriores iban a 0,1 ATR y casi
  todos dan «salvo» porque su riesgo era diminuto. Una simulación de solo
  lectura antes de aplicarla: 60 de los 64 stops de los agentes en los
  últimos 30 días saldrían «salvo» y 4 pendientes, casi todos de antes de
  la 0030.
