# Estado del proyecto y lista de control

> **Última actualización**: 2026-10-11 (0037 implementada)
> **Para qué sirve**: retomar el trabajo en un chat nuevo sin perder
> contexto. Dice qué está hecho, qué está en curso, qué viene después, qué
> hace falta para hacerlo y por qué algunas cosas esperan.
> **Cómo mantenerlo**: quien cierre una tarea (dueño o Claude) la marca
> aquí en el mismo PR y añade la entrada en el `CHANGELOG.md`.

---

## 1. Cómo retomar en otro chat

Pega esto al empezar: *«Lee `docs/ESTADO.md` y continúa por el primer
punto ⏭️ de la lista de control»*.

**Orden de lectura** (de lo más reciente a lo más general):

1. Este documento.
2. [`fase-2/07-agente-tendencia-cripto.md`](fase-2/07-agente-tendencia-cripto.md): lo siguiente que se construye.
3. [`fase-2/06-laboratorio-y-agentes-con-ventaja.md`](fase-2/06-laboratorio-y-agentes-con-ventaja.md): el laboratorio y su veredicto.
4. [`fase-2/05-agentes-conscientes-del-tiempo.md`](fase-2/05-agentes-conscientes-del-tiempo.md): las mejoras a los agentes con metas.
5. [`../CHANGELOG.md`](../CHANGELOG.md): la bitácora, entrada por entrada.
6. [`fase-2/03-logica-de-agentes.md`](fase-2/03-logica-de-agentes.md) (guardarraíles G1–G6, monitor M1–M4) y [`fase-2/04-sprint-backlog.md`](fase-2/04-sprint-backlog.md) (decisiones D1–D24).

**Cómo trabajamos**:

| Paso | Quién | Cómo |
|---|---|---|
| Cambios de código y migraciones | Claude | Rama de trabajo, PR y merge a `master` |
| Aplicar migraciones en producción | Dueño | `scripts/aplicar-migraciones.cmd` |
| Consultar producción | Dueño | Pega el SQL en el editor SQL de Supabase y sube el CSV al chat. Claude no tiene acceso directo a producción. Para copiar SQL largo, usar la URL *raw* de GitHub (las copias parciales dieron errores de sintaxis) |
| Laboratorio | Claude | Lanza `laboratorio.yml` en GitHub Actions y lee el informe del job |
| Pruebas | Claude | `motor-analitico`: `python -m pytest -q` (202 en verde). SQL: `supabase/pruebas/01_invariantes.sql` (I1–I89), en la CI de migraciones. En local se aplican sobre un PostgreSQL 16 desde cero (migraciones, invariantes, concurrencia y cuadre) |

**Reglas que no se saltan**:

- Nunca se pegan en el chat tokens, claves ni contraseñas. Las consultas
  van con el rol de solo lectura `analista_lectura`.
- Los agentes actuales **no se tocan mientras dure el experimento** (son el
  grupo de control, §3).
- Los parámetros de una estrategia validada no se cambian sin repetir el
  laboratorio y la prueba de robustez.

---

## 2. La situación en una página

- **Hay tres agentes con metas diarias**: Prudencia (2 %), Cadencia (5 %) y
  Audacia (7 %). Entre el 2026-10-10 y el 2026-10-11 se corrigió lo que
  los hacía perder por diseño:
  - stops dentro del ruido y objetivos inalcanzables (D21);
  - votos contradictorios;
  - cripto bloqueada (D22);
  - huecos sin modelar (M3');
  - spread ignorado (D23);
  - riesgo abierto sin límite (G6).
- **Las metas son inalcanzables de forma sostenida**: 2 % diario compuesto
  son × 147 al año. Las señales actuales **no tienen ventaja demostrada**:
  en el laboratorio, la estrategia «actual» queda en +0,14 R en acciones,
  con un intervalo que incluye el cero.
- **Decisión del dueño (doc 06)**: los tres agentes siguen como **grupo de
  control** y se crean agentes nuevos, uno por cada estrategia con ventaja.
- **El laboratorio** (velas diarias de 5 años, sin mirar el futuro, con
  spread y huecos) probó tres estrategias. **Solo tendencia en cripto
  pasó**, y la prueba de robustez la dejó en «real pero no demostrada»: sin
  zcash, el intervalo incluye el cero.
- **Decisión D24 (2026-10-11)**: se crea el **agente experimental
  «Tendencia cripto»**, con criterio de retirada fijado de antemano (doc 07
  §6). **Implementado en la 0037; falta aplicarlo y activarlo.**

---

## 3. Lista de control

**Leyenda**:

| Símbolo | Significado |
|---|---|
| ✅ | Hecho y aplicado en producción |
| 🔄 | En curso |
| ⏭️ | Lo siguiente: sin bloqueos, se puede empezar ya |
| 🗓️ | Previsto: se hará después de lo anterior |
| ⏸️ | En espera, con el motivo |
| 👤 | Lo tiene que hacer o decidir el dueño |
| ❌ | Descartado, con el motivo |

### 3.1 Agente experimental «Tendencia cripto» (doc 07)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Decisión D24: crearlo como experimental (opción A) | Dueño, 2026-10-11 |
| ✅ | Diseño: reglas, traducción al simulador, tamaño, criterio de retirada | Doc 07 |
| ✅ 👤 | **Migración 0037** (detalle en doc 07 §4.10), aplicada y agente activado el 2026-10-11 | Lo que incluye (doc 07 §4): <br>• `agentes.tipo` (metas / estrategia), con `objetivo_diario_pct` opcional; <br>• `ordenes.tp` opcional; <br>• `fn_subir_stop`; <br>• motivo de cierre `regla`; <br>• `fn_decidir_tendencia`; <br>• cron horario de 01:20 a 07:20 UTC (el ETL de las 00:07 puede no traer aún el punto de las 00:00, por eso hay 60 min de margen); <br>• alta del agente en `pausado`. <br>Revisado todo lo que lee `tp`: el monitor y la estimación de la 0031 toleran el nulo, y las tomas parciales, la rotación y el deterioro solo corren en el ciclo de los agentes con metas |
| ✅ | Invariante I86 de la 0037 | Cubre: <br>• la entrada a 2 ATR con el 1 % de riesgo y sin objetivo; <br>• una sola decisión por vela; <br>• que el stop solo sube y nunca supera el precio de venta; <br>• la salida por regla; <br>• que el monitor no cierra por objetivo, pero sí por stop; <br>• G6; <br>• que los bucles con metas no lo recorren; <br>• la pausa por caída. <br>Pasan las 86 invariantes, la concurrencia y el cuadre |
| ✅ | Hora del ETL de cripto | Corre a los :07 de cada hora y rota las criptos sin posición. Por eso la decisión corre cada hora de 01:20 a 07:20 UTC, y cada activo se decide una vez, cuando ya tiene la vela de ayer (doc 07 §4.6) |
| ✅ | Laboratorio de cartera (`laboratorio/cartera.py`, modo `cartera`) | Una sola cuenta con el 1 %, G6, a 1×, con caja y prioridad por fuerza de la ruptura, igual que el agente. Con un activo y sin G6 reproduce las operaciones del motor (prueba de paridad) |
| ✅ | Ensayo sobre producción (`scripts/ensayo_tendencia.sql`), 2026-10-11 | Las 14 criptos tienen 29 días con rango real y 200 cierres. El token de maxlinear no tiene 200 cierres. Hoy no entraría en ninguna: 3 están bajo su media de 200 y 11 sin ruptura |
| ✅ | 0038: precio fresco para la decisión diaria | Sin posición, una cripto solo recibía precio del ETL horario. Si el ETL tardaba, la decisión de las :20 lo encontraba viejo y el agente podía pasar el día sin entrar. Ahora el monitor pide también el universo del agente de 01:00 a 07:59 UTC (I87) |
| ✅ 👤 | Umbral de pausa por caída: **35 %** (decidido el 2026-10-11) | Migración 0039 e invariante I88. El laboratorio de cartera cae hasta un 26 % ganando; con el 15 % de la 0037 se habría pausado en plena racha |
| ⏭️ 👤 | **Aplicar la 0039 junto con la 0038** | Las dos antes de las 01:20 UTC si es posible |
| ⏭️ 👤 | **Aplicar la 0038 antes de las 01:20 UTC** | Si no da tiempo, el agente decide igual. Solo corre el riesgo de registrar `sin_precio` si el ETL se retrasa |
| 🗓️ | Comprobar que 5 $ de riesgo dan una cantidad operable en cada cripto | Con 500 $ de saldo y un 1 % de riesgo |
| ✅ | Frontend: tarjeta sin meta diaria, con expectativa en R y criterio de retirada; racional de la ruptura; guía | El color `--agente-4` está pendiente de validar con el comprobador de paletas |
| ⏭️ 👤 | **Aplicar la 0037 con `scripts/aplicar-migraciones.cmd` y activar «Tendencia cripto» desde /admin** | La primera decisión llega a la mañana siguiente, entre las 01:20 y las 07:20 UTC |
| ⏭️ 👤 | Antes de la primera decisión: ensayo de solo lectura con `scripts/ensayo_tendencia.sql` | Muestra qué haría hoy con cada cripto (entrar, sin señal, sin datos) y con qué stop. Sirve para detectar a tiempo las criptos sin velas suficientes |
| ⏭️ 👤 | Al día siguiente de activarlo, comprobar que decidió | `select a.simbolo, d.accion, d.datos from agente_decisiones_diarias d join activos a on a.id = d.activo_id order by d.decidido_en desc` y `select * from v_agentes_estrategia`. Que no haya muchos `sin_vela` ni `sin_datos`: indicarían que faltan velas con rango real |
| 🗓️ | Revisión de las primeras 5 operaciones frente al laboratorio en las mismas fechas | Es para encontrar errores, no para juzgar la ventaja |
| 🗓️ | **Veredicto a las 30 operaciones** (unos 6–7 meses) | Por debajo de 0 R se retira. Entre 0 y +0,10 R, se observa hasta 60. Por encima de +0,10 R, queda validado en vivo. Si la caída supera el 35 %, se pausa y se revisa |
| 👤 | Decisiones abiertas con valor por defecto (doc 07 §8) | Saldo inicial (500 $ por defecto) y visibilidad para los usuarios (visible por defecto) |

### 3.2 Laboratorio de estrategias (doc 06)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Motor causal, métricas, veredicto, workflow `laboratorio.yml` | PR #40 |
| ✅ | Primera ronda: actual, tendencia, reversión (5 años, 43 activos) | Solo pasa tendencia en cripto. [Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38132253307) |
| ✅ | Prueba de robustez (`robustez.py`, modo `robustez` del workflow) | PR #41. Cumple 3 de 4 criterios. [Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38132842239) |
| ✅ | Laboratorio a 10 años | Tendencia en cripto, reforzada: +1,09 R, IC [+0,57, +1,70], 203 operaciones en validación. En acciones, +0,12 R con el intervalo incluyendo el cero: sigue sin agente (doc 06 §3.7). [Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38135711624) |
| 🗓️ | Ideas nuevas para acciones (ninguna pasa hoy) | Candidatas: <br>• momento relativo (comprar los más fuertes del universo y rotar cada mes); <br>• tendencia con filtro de régimen del S&P 500. <br>Cada idea se escribe como estrategia nueva en `estrategias.py`, con su prueba de causalidad |
| 🗓️ | Validación por ventanas móviles (*walk-forward*) | Más exigente que el corte 70/30. Útil cuando haya más de una candidata |
| ⏸️ | Ampliar el universo cripto de producción con las del top de 2021 que funcionaron (XLM, NEAR, HBAR…) | **Esperamos** porque elegirlas por su resultado repite el sesgo de supervivencia. Se decide con el veredicto del agente |

### 3.3 Agentes con metas: mejoras del doc 05 (grupo de control)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Diagnóstico de 11 días | `scripts/diagnostico_agentes*.sql` |
| ✅ | Puntos 1 y 2: niveles alcanzables (D21), votos del RSI, G6 | 0030 |
| ✅ | Entrega A: medir el tiempo (calendario de mercados, horizonte estimado, huecos, régimen, autodiagnóstico semanal) | 0031 |
| ✅ | Entrega D: cripto prudente (D22) y 6 criptos nuevas | 0032 |
| ✅ | M3': huecos reales en el simulador | 0033 |
| ✅ | Spread (D23) y spread observado | 0034 y 0035 |
| ✅ | «Ampliar el universo» solo cuenta los ciclos con alcistas descartadas | 0036 |
| ⏭️ 👤 | **Lunes 12-10, a partir de las 00:17 UTC: revisar el primer autodiagnóstico semanal** | El dueño pasa el resultado de `select * from agente_backlog order by creado_en desc limit 20`. Hay que ver si las peticiones tienen sentido |
| ⏭️ 👤 | **Tras el primer día de bolsa: revisar `v_spreads`** | `select * from v_spreads`. Comprueba que se registra el spread observado y que el percentil 90 no queda por debajo del configurado |
| 🗓️ 👤 | Comprobar que los agentes operan cripto el fin de semana | Con `scripts/diagnostico_agentes_editor.sql` tras un fin de semana completo con la 0032 aplicada |
| ⏸️ | Entrega C: noches y fines de semana caso a caso (§5.4) | **Esperamos** por tres razones: <br>• los agentes con metas son el grupo de control, y cambiarlos a mitad del experimento ensucia la comparación; <br>• sin ventaja demostrada, afinar *cuándo* operar solo cambia la velocidad a la que se pierde; <br>• necesita semanas de datos en `v_huecos_activos`. <br>Se retoma si el dueño lo decide o cuando acabe el experimento |
| ⏸️ | Entrega B: aporte por sesión, horizonte máximo (10, 5 y 3 sesiones, ya decidido) y revisión al cumplirse el horizonte | **Esperamos** por las mismas razones que la C. Además, es el cambio más profundo y gana con horizontes ya medidos (lleva la 0031 desde el 10-10) |
| ⏸️ | Entrega E: calibración y vigencia de las prácticas (§9) | **Esperamos** a tener datos: necesita semanas de horizontes y resultados observados. Es la primera candidata a retomar, porque mejora la honestidad del aprendizaje sin cambiar la estrategia |
| ❌ | Descartar operaciones porque no caben en la ventana del día | El dueño: «no podemos tener solo una visión inmediata» (doc 05 §5.2) |
| ❌ | Presupuesto de pérdida diario | Decisión del dueño (doc 05 §8.1) |

### 3.4 Después del experimento

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Panel comparativo (0040, `v_comparativa_agentes`) | Los cuatro agentes con las mismas medidas: <br>• expectativa en R, con los cierres parciales; <br>• R total; <br>• aciertos; <br>• factor de beneficio; <br>• rentabilidad y caída. <br>Se miden en todo el histórico y «desde el experimento» (el alta de Tendencia cripto). Panel «Comparativa» en Agentes. Invariante I89 |
| 👤 | **Aplicar la 0040** | Solo añade una vista; no cambia ninguna decisión |
| ⏸️ | Agente de cartera que combine estrategias con ventaja | **Esperamos** a tener al menos dos estrategias con ventaja. Hoy hay media |
| ⏸️ | Capa narrativa con LLM para el informe semanal (doc 05 §10.2) | **Esperamos** porque tiene un coste por uso que hoy el proyecto no tiene. Decide el dueño |

---

## 4. Datos útiles

| Qué | Dónde |
|---|---|
| Migración más reciente | `0040_comparativa_agentes.sql`. La siguiente es la 0041 |
| Decisiones numeradas | D1–D24 (`fase-2/04-sprint-backlog.md`). D21 niveles, D22 cripto prudente, D23 spread, D24 agente experimental |
| Guardarraíles | G1–G6 (`fase-2/03-logica-de-agentes.md` §4) |
| Reglas del monitor | M1–M4 y M3' (doc 03) |
| Spread pesimista (QuantFury) | Acciones 0,03 $; AMCR 0,10 $; BTC 5 $; ETH 0,10 $; resto de cripto 0,10 %. Nunca baja del configurado aunque el observado sea menor |
| Lanzar el laboratorio | Actions → `laboratorio` → *Run workflow*. Modo `laboratorio` (estrategias, periodo) o `robustez` (estrategia, clase) |
| Activos sin datos en Yahoo | SPCX, el token de maxlinear (suspendido en la 0032), LUNA1-USD y MATIC-USD |
