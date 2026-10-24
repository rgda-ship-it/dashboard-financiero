# Estado del proyecto y lista de control

> **Última actualización**: 2026-10-24 (diagnóstico y arranque de la Fase 3; 0045: salud del sistema)
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
2. [`fase-3/00-diagnostico-y-plan.md`](fase-3/00-diagnostico-y-plan.md): el diagnóstico del 2026-10-24 y el plan de la Fase 3; [`fase-3/01-agentes-investigadores.md`](fase-3/01-agentes-investigadores.md): los agentes como medio para evolucionar el sistema.
3. [`fase-2/07-agente-tendencia-cripto.md`](fase-2/07-agente-tendencia-cripto.md): el agente experimental.
4. [`fase-2/06-laboratorio-y-agentes-con-ventaja.md`](fase-2/06-laboratorio-y-agentes-con-ventaja.md): el laboratorio y su veredicto.
5. [`fase-2/05-agentes-conscientes-del-tiempo.md`](fase-2/05-agentes-conscientes-del-tiempo.md): las mejoras a los agentes con metas.
6. [`../CHANGELOG.md`](../CHANGELOG.md): la bitácora, entrada por entrada.
7. [`fase-2/03-logica-de-agentes.md`](fase-2/03-logica-de-agentes.md) (guardarraíles G1–G6, monitor M1–M4) y [`fase-2/04-sprint-backlog.md`](fase-2/04-sprint-backlog.md) (decisiones D1–D24).

**Cómo trabajamos**:

| Paso | Quién | Cómo |
|---|---|---|
| Cambios de código y migraciones | Claude | Rama de trabajo, PR y merge a `master` |
| Aplicar migraciones en producción | Dueño | `scripts/aplicar-migraciones.cmd` |
| Consultar producción | Claude | `scripts/consultar.py` con `SUPABASE_DB_URL_LECTURA` del `.env` (rol `analista_lectura`, pooler `aws-1-eu-west-1`, sesión en solo lectura). Claude no usa la URL de administrador. Si hace falta, el dueño puede seguir con el editor SQL de Supabase y la URL *raw* de GitHub |
| Laboratorio | Claude | Lanza `laboratorio.yml` en GitHub Actions y lee el informe del job |
| Pruebas | Claude | `motor-analitico`: `python -m pytest -q` (268 en verde). SQL: `supabase/pruebas/01_invariantes.sql` (I1–I96), en la CI de migraciones. En local se aplican sobre un PostgreSQL 16 desde cero (migraciones, invariantes, concurrencia y cuadre) |

**Reglas que no se saltan**:

- Nunca se pegan en el chat tokens, claves ni contraseñas. Las consultas
  van con el rol de solo lectura `analista_lectura`.
- Los agentes actuales **no se tocan mientras dure el experimento** (son el
  grupo de control, §3).
- Los parámetros de una estrategia validada no se cambian sin repetir el
  laboratorio y la prueba de robustez.

---

## 2. La situación en una página

- **Fase 3 (desde el 2026-10-24)**: mantener el sistema fiable mientras
  corre el experimento. El diagnóstico encontró que **el ETL no se lanza
  desde el 23-10 a las 19:07 UTC** (GitHub responde 401: el token de Vault
  ha caducado) y que la toma parcial de 1 acción deshacía el ciclo del
  agente. La 0045 arregla lo segundo y hace visibles los dos (panel «Salud
  del sistema»). El token lo renueva el dueño (doc fase-3/00 §4).
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

### 3.0 Fase 3 (doc fase-3/00)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Diagnóstico del comportamiento del 13 al 24-10 | Doc fase-3/00 §2: 7 problemas (P1–P7) |
| ✅ 👤 | Renovar el token `github_pat_altas` de Vault (renovado el 2026-10-24) | Comprobado: GitHub responde 204 desde el disparo de las 13:07 UTC y el ETL de cripto vuelve a correr cada hora. Caducó el 23-10 (GitHub respondía 401). Sin él no corre el ETL desde la BD: el lunes no habría señales de acciones ni precio fresco para las posiciones de acciones. Nuevo token *fine-grained* con **1 año** de caducidad y solo Actions: Read and write; `vault.update_secret` como dice `RUNBOOK-sprint-4.md` («Renovación») |
| ✅ 👤 | Aplicar la 0045 (E1, salud del sistema; aplicada el 2026-10-24) | Incluye: <br>• la toma parcial se salta la posición que no se parte en unidades enteras (I93); <br>• cada disparo del ETL guarda su petición y la pasada siguiente lee la respuesta: un `fallo` por episodio y un `etl` al recuperarse (I94); <br>• `rpc_salud_sistema` y el panel «Salud del sistema» en Administración; <br>• `analista_lectura` lee todo `public`, también lo que se cree después, y ejecuta las funciones no volátiles (I95) |
| ✅ | Comprobar la 0045 (2026-10-24) | Las 24 vistas se leen con `analista_lectura` (antes fallaban 11), también `v_comparativa_agentes` y `agente_decisiones_diarias`. El disparo de cripto de las 15:07 UTC guarda su petición y GitHub respondió 204; su `estado_http` lo rellena la pasada siguiente. El 401 del 23–24-10 no deja evento: aquellos disparos son anteriores a la 0045. Falta ver el panel «Salud del sistema» en el navegador (lo abre el dueño, con su sesión de admin) |
| ⏭️ | E2: caducidad de las credenciales en el panel de salud, con aviso 14 días antes | Tras la 0045 |
| 🗓️ | E3: revisión semanal guiada y backlog («Ampliar el universo» se reabrió el 19 y el 23-10; «Señales más frecuentes» nunca se revisó) | Tras la 0045 |
| ✅ 👤 | Agentes investigadores: diseño (doc fase-3/01), decidido el 2026-10-24 | La meta diaria no les hace aprender: no razonan y solo piden lo que está en 7 plantillas. Pasan a proponer hipótesis a partir de su propia evidencia, el laboratorio las prueba y el dueño decide. Dos pasos: primero determinista, sin coste y sin tocar cómo operan; después, un LLM con el mismo contrato |
| ✅ | I1: hipótesis de los agentes (0046) | Incluye: <br>• `agente_hipotesis`, con tres fuentes: H1 (decisiones que cuestan), H2 (movimientos perdidos) y H4 (cierre parcial y trailing stop del backlog); <br>• una por agente y semana, en el autodiagnóstico de los lunes; <br>• pestaña «Investigan» en Agentes y revisión en Administración. <br>Invariante I96. Con los datos del 24-10, la H2 propondría a los tres «entrar también con el MACD positivo»: se cumplía en el 75–78 % de sus 8–9 movimientos perdidos, frente al 40 % de los días. La H1 aún no salta: tras la 0043 solo hay 1 deterioro resuelto |
| ✅ 👤 | Aplicar la 0046 (aplicada y comprobada el 2026-10-24) | Tabla y vistas nuevas en producción y legibles con `analista_lectura`; el generador está enganchado al autodiagnóstico de los lunes. Simulación de solo lectura con los datos de hoy: H2 propondría a los tres «entrar también con el MACD positivo» en acciones (Prudencia y Cadencia 8 movimientos perdidos en 6 activos, Audacia 9 en 7; soporte 75–78 %, frecuencia 40 %). H1 no salta (ningún tipo llega a 20 decisiones resueltas) ni H4 (no hay peticiones de cierre parcial ni de trailing stop) |
| 🗓️ | Revisar las primeras hipótesis (lunes 26-10, tras las 00:17 UTC) | Que haya una por agente, con la evidencia y el experimento esperados, y el evento «… propone probar» |
| ✅ | I2: el laboratorio reproduce a los agentes | Estrategia `agente`: banda de volatilidad, deterioro en dos lecturas, toma parcial, stop que sigue y condición del catálogo. El motor admite la toma parcial, y `laboratorio/agentes.py` traduce la estrategia de producción. No reproduce la rotación ni el reparto. 250 pruebas del motor en verde |
| ✅ | I3: prueba automática con `hipotesis.yml` y concordancia con producción | Los lunes a las 02:00 UTC, el agente actual frente al agente con el cambio, y 20 tiradas al azar con las mismas salidas. El percentil exigido sube un punto por prueba anterior. Escribe el veredicto y deja un evento del agente. Pasada real, sin escribir: «entrar también con el MACD positivo» queda refutada para Prudencia (+0,10 R → +0,006 R; percentil 65 frente al 90 exigido) |
| 🗓️ | Revisar la primera pasada de `hipotesis.yml` (lunes 26-10, tras las 02:00 UTC) | Que las 3 hipótesis queden `validada` o `refutada`, con el informe enlazado, y ver la concordancia de cada agente. Si el `schedule` de GitHub no llega, lanzarlo a mano desde Actions |
| 🗓️ | I4: registro de descartes y H3 | Doc fase-3/01 §8 |
| ⏸️ 👤 | I5: hipótesis propuestas por un LLM | **Esperamos** a la I3 y a la decisión del dueño sobre el coste |
| 👤 | Decisiones abiertas con valor por defecto (doc fase-3/00 §5 y fase-3/01 §9) | Espera tras salir por deterioro y límite de stops por activo: no, mientras dure el experimento. Avisos fuera del dashboard: no, de momento |

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
| ✅ | Comprobar que 5 $ de riesgo dan una cantidad operable en cada cripto | Con los ATR del 2026-10-12, a 2 ATR, todas pasan el mínimo de 10 $: de 25 $ (zcash, stop al 20 %) a 235 $ (tron, stop al 2 %) |
| ✅ | Frontend: tarjeta sin meta diaria, con expectativa en R y criterio de retirada; racional de la ruptura; guía | El color `--agente-4` está pendiente de validar con el comprobador de paletas |
| ✅ 👤 | Aplicar las 0037–0040 y activar «Tendencia cripto» | Aplicadas con `scripts/aplicar-migraciones.cmd`, que aplica todas las pendientes; el agente decide desde el 2026-10-12 |
| ✅ | Al día siguiente de activarlo, comprobar que decidió (revisado el 2026-10-13) | Dos mañanas (velas del 11 y del 12): las 14 criptos con datos, `sin_senal`, de forma coherente (3 bajo su media de 200 y 11 sin ruptura). maxlinear, `sin_vela` y luego `sin_datos` (no tiene 200 cierres). Ningún `sin_precio`. Consultas: `select a.simbolo, d.accion, d.datos from agente_decisiones_diarias d join activos a on a.id = d.activo_id order by d.decidido_en desc` y `select * from v_agentes_estrategia`. Que no haya muchos `sin_vela` ni `sin_datos`: indicarían que faltan velas con rango real |
| ✅ | Revisar sus decisiones diarias (2026-10-24, con el acceso de la 0045) | Del 12 al 23-10, todos los días: 14 criptos `sin_senal` y maxlinear `sin_datos`. Ningún `sin_vela` ni `sin_precio`, ni siquiera con el ETL caído del 23-10. Con la vela del 23: 4 bajo su media de 200 (bitcoin-cash, cardano, dogecoin, tron) y 10 por encima pero sin ruptura; las más cerca, bitcoin (81.102 frente a un máximo de 86.949) y zcash (1.181 frente a 1.381). No entrar es lo correcto |
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
| ✅ | Segunda ronda: estrategias del manual del dueño (doc 06 §3.8) | **ruptura_volumen en acciones** pasa: +0,29 R en validación. También pasa la robustez formal, pero con márgenes justos y solo 12 de 29 acciones positivas. El resto no aporta: <br>• el objetivo a 2R empeora la ruptura en cripto; <br>• la reversión con Bollinger falla. <br>[Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38163243913) |
| ✅ | Ruptura con volumen en acciones: amplitud (S&P 100) y referencia al azar (doc 06 §3.9–3.10) | **No se crea agente de acciones.** En el S&P 100, entrar al azar con las mismas salidas rinde lo mismo que la ruptura (+0,28 frente a +0,27 R): la «ventaja» es el mercado alcista con supervivientes, no la señal. En cripto, el azar da +0,65 R frente a +1,09 R de tendencia: la mayor parte de la ventaja de Tendencia cripto está en sus salidas. Desde ahora el criterio exige superar a la referencia al azar |
| ✅ | Momento relativo en acciones (doc 06 §3.11), 2026-10-13 | **No aporta selección frente al azar** con la configuración fijada de antemano (las 4 o 10 primeras, 12-1), en ningún universo. En los 19 ETF sin sesgo de supervivencia, la validación queda en el percentil 33 de 30 tiradas al azar. Solo las carteras muy concentradas (2 o 5) pasan, pero se eligieron tras ver los datos. **No se crea agente de acciones.** Herramientas nuevas: el modo `contra_azar`, la medida «% / mes» y `--universo etf` |
| 👤 | ¿Experimento en vivo con el momento concentrado? | Configuración fijada ya (ETF, las 2 primeras, 12-1, stop a 5 ATR), juzgada con datos futuros, como Tendencia cripto. Habría que confirmar antes que QuantFury permite operar esos ETF. Por defecto, no se hace |
| 🗓️ | Otras ideas para acciones | Solo datos fundamentales (calidad, valor), siempre contra la distribución de tiradas al azar. El momento ya se probó (§3.11) |
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
| ✅ | Revisar el primer autodiagnóstico semanal (2026-10-13) | Las peticiones tienen sentido: los tres agentes dicen que su meta no es alcanzable (0 días cumplidos; mejor día 0,44 %, 1,75 % y 2,47 % frente a metas del 2, 5 y 7 %). Es la conclusión del doc 05. W40 y W41 fueron deficientes: por la regla del doc 03 §6.2, los tres pasan a cuarentena (es el comportamiento previsto del grupo de control). Dos detalles: el «ATR mediano de mis entradas» sale «sin dato» en los tres, y al reabrirse una entrada se actualiza la evidencia (W41) pero no la descripción (W40) |
| ✅ | Averiguar por qué el ATR mediano sale «sin dato» | No es un fallo: las señales sí tienen `atr_pct`. La ventana del autodiagnóstico empieza, como pronto, cuando se aplicó la 0030 (el 10-10), y la última entrada de los agentes con metas es del viernes 09-10. Solo falla el texto: «sin dato» quiere decir «sin entradas desde la 0030» |
| ✅ | Comprobar por qué los agentes con metas no abren nada desde el 09-10 | Por la cuarentena: el lunes 12 cada uno descartó unas 1.400 señales por «fuerza» (solo admite la alta) |
| ✅ 👤 | 0042: los agentes con metas salen de la cuarentena (decisión del dueño, 2026-10-13) | Las metas no se cumplen nunca, así que la cuarentena sería permanente y no dejaría ver el efecto de las 0030–0036. Vuelven a `activo` y con el riesgo completo. Mientras dure el experimento, el corte semanal sigue calculando la nota y abriendo su entrada en el backlog, pero sin consecuencias (`agentes.consecuencias_semanales = false`). Invariante I90. Al acabar el experimento, volver a ponerla en true |
| ✅ 👤 | Aplicar la 0042 (aplicada el 2026-10-13) | Prudencia, Cadencia y Audacia quedan `activo`, con `riesgo_reducido = false` y `consecuencias_semanales = false` |
| ✅ | Comprobar que los agentes con metas vuelven a abrir posiciones (revisión del 2026-10-17) | Sí, desde el 13-10. Los niveles de la 0030 funcionan (stops del 2–5 %, 7 objetivos alcanzados) y ya operan valores de Nasdaq. Dos fallos, corregidos en la 0043: la salida por deterioro vendía por una sola lectura (7 de 16 cierres, unos −0,4 R de media) y volvían a entrar en un valor que acababa de tocar el stop (QFIN) |
| ✅ 👤 | Aplicar la 0043 (aplicada el 2026-10-17) | Deterioro confirmado en dos lecturas seguidas; 48 h sin volver a un activo tras su stop (`espera_tras_stop_horas`). Invariante I91. Aplicada a las 10 salidas por deterioro del 12 al 14 de octubre, habría evitado 7. Según el contrafactual de cada decisión, esas 7 costaron unos 135 $; las 3 que seguirían saliendo, unos 10 $ |
| ✅ 👤 | Dar `bypassrls` a `analista_lectura` (2026-10-17) | Claude ya consulta producción con `scripts/consultar.py`. Las funciones con `revoke` (como `fn_rango_fuerza`) no se pueden ejecutar con ese rol: hay que escribir su lógica en la propia consulta |
| ✅ | Revisar la 0043 tras una semana (2026-10-24) | Funciona: 4 salidas por deterioro desde la 0043, todas de Prudencia, a −0,29 R de media, frente a 9 en los cuatro días anteriores; F evitó un stop. La espera de 48 h se respeta (QFIN volvió a las 48 h y 2 min). Sin cambios (doc fase-3/00 §2.3) |
| ✅ | Revisar el backlog de los agentes (2026-10-17) | 7 peticiones abiertas: 3 «meta no alcanzable» (rechazadas: se sabe y se mantiene el grupo de control), 3 «semana deficiente» (implementadas en la 0042) y «Ampliar el universo» (rechazada: falso positivo de un sábado flojo en cripto). Se cierran en la 0044 |
| ✅ 👤 | Aplicar la 0044 (aplicada el 2026-10-17) | Cierra las 7 peticiones. «Ampliar el universo» exige 24 ciclos y 3 descartes del perfil por ciclo. La meta y la semana deficiente no se reabren mientras las consecuencias estén suspendidas. La descripción sigue a la última ocurrencia. Invariante I92 |
| ✅ | Revisar `v_spreads` tras el primer día de bolsa (2026-10-13) | En NYSE (19 valores), las medidas son coherentes. En Nasdaq (13 valores), Yahoo da una cotización congelada: spreads del 1–2,7 % en AAPL, AMZN, MSFT, NVDA y SPCX, y casi ninguna medida en el resto. Se cobraban a los agentes con metas. Arreglo en la 0041 |
| ✅ 👤 | Aplicar la 0041 (aplicada el 2026-10-13) | Borra las medidas de Nasdaq y deja de cobrarlas. El ETL ya no mide en Nasdaq desde el merge del PR |
| ✅ | Comprobar que los agentes miran cripto el fin de semana (2026-10-17) | Sí: los fines de semana del 10–11 y del 17 sus descartes son de cripto (`direccion`). No abrieron nada porque ninguna cripto era alcista, no por un fallo |
| ⏸️ | Entrega C: noches y fines de semana caso a caso (§5.4) | **Esperamos** por tres razones: <br>• los agentes con metas son el grupo de control, y cambiarlos a mitad del experimento ensucia la comparación; <br>• sin ventaja demostrada, afinar *cuándo* operar solo cambia la velocidad a la que se pierde; <br>• necesita semanas de datos en `v_huecos_activos`. <br>Se retoma si el dueño lo decide o cuando acabe el experimento |
| ⏸️ | Entrega B: aporte por sesión, horizonte máximo (10, 5 y 3 sesiones, ya decidido) y revisión al cumplirse el horizonte | **Esperamos** por las mismas razones que la C. Además, es el cambio más profundo y gana con horizontes ya medidos (lleva la 0031 desde el 10-10) |
| ⏸️ | Entrega E: calibración y vigencia de las prácticas (§9) | **Esperamos** a tener datos: necesita semanas de horizontes y resultados observados. Es la primera candidata a retomar, porque mejora la honestidad del aprendizaje sin cambiar la estrategia |
| ❌ | Descartar operaciones porque no caben en la ventana del día | El dueño: «no podemos tener solo una visión inmediata» (doc 05 §5.2) |
| ❌ | Presupuesto de pérdida diario | Decisión del dueño (doc 05 §8.1) |

### 3.4 Después del experimento

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Panel comparativo (0040, `v_comparativa_agentes`) | Los cuatro agentes con las mismas medidas: <br>• expectativa en R, con los cierres parciales; <br>• R total; <br>• aciertos; <br>• factor de beneficio; <br>• rentabilidad y caída. <br>Se miden en todo el histórico y «desde el experimento» (el alta de Tendencia cripto). Panel «Comparativa» en Agentes. Invariante I89 |
| ⏸️ | Agente de cartera que combine estrategias con ventaja | **Esperamos** a tener al menos dos estrategias con ventaja. Hoy hay media |
| ⏸️ | Capa narrativa con LLM para el informe semanal (doc 05 §10.2) | **Esperamos** porque tiene un coste por uso que hoy el proyecto no tiene. Decide el dueño |

---

## 4. Datos útiles

| Qué | Dónde |
|---|---|
| Migración más reciente | `0046_hipotesis_de_los_agentes.sql`. La siguiente es la 0047 |
| Decisiones numeradas | D1–D24 (`fase-2/04-sprint-backlog.md`). D21 niveles, D22 cripto prudente, D23 spread, D24 agente experimental |
| Guardarraíles | G1–G6 (`fase-2/03-logica-de-agentes.md` §4) |
| Reglas del monitor | M1–M4 y M3' (doc 03) |
| Spread pesimista (QuantFury) | Acciones 0,03 $; AMCR 0,10 $; BTC 5 $; ETH 0,10 $; resto de cripto 0,10 %. Nunca baja del configurado aunque el observado sea menor |
| Lanzar el laboratorio | Actions → `laboratorio` → *Run workflow*. Modo `laboratorio` (estrategias, periodo) o `robustez` (estrategia, clase) |
| Activos sin datos en Yahoo | SPCX, el token de maxlinear (suspendido en la 0032), LUNA1-USD y MATIC-USD |
