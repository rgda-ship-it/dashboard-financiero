# Estado del proyecto y lista de control

> **Última actualización**: 2026-10-27 (documentación reordenada: `SISTEMA-HOY.md` y `CRONOLOGIA.md`; Administración en pestañas)
> **Para qué sirve**: retomar el trabajo sin perder contexto. Arriba, lo
> abierto (lo siguiente, lo previsto, lo que espera y por qué); abajo, lo
> hecho. Cómo funciona el sistema hoy está en
> [`SISTEMA-HOY.md`](SISTEMA-HOY.md); desde cuándo son comparables los
> datos, en [`CRONOLOGIA.md`](CRONOLOGIA.md).
> **Cómo mantenerlo**: quien cierre una tarea (dueño o Claude) la mueve al
> §4 en el mismo PR y añade la entrada en el `CHANGELOG.md`.

---

## 1. Cómo retomar en otro chat

Pega esto al empezar: *«Lee `docs/README.md` y `docs/ESTADO.md` y
continúa por el primer punto ⏭️»*.

**Orden de lectura**:

1. [`SISTEMA-HOY.md`](SISTEMA-HOY.md): las reglas vigentes de cada agente y las tareas programadas.
2. Este documento: lo abierto (§3).
3. [`CRONOLOGIA.md`](CRONOLOGIA.md): **antes de analizar datos**, desde qué fecha son comparables.
4. El documento de diseño del tema que toque: el índice, con la vigencia de cada uno, está en [`README.md`](README.md).
5. [`../CHANGELOG.md`](../CHANGELOG.md): la bitácora, entrada por entrada.

**Cómo trabajamos**:

| Paso | Quién | Cómo |
|---|---|---|
| Cambios de código y migraciones | Claude | Rama de trabajo, PR, CI en verde y merge a `master` |
| Aplicar migraciones en producción | Dueño | `scripts/aplicar-migraciones.cmd` |
| Consultar producción | Claude | `scripts/consultar.py` con `SUPABASE_DB_URL_LECTURA` del `.env` (rol `analista_lectura`, sesión en solo lectura). Claude no usa la URL de administrador |
| Revisión de los lunes | Claude o dueño | `python scripts/consultar.py -f scripts/revision_agentes.sql` (fase-3/07 §6) |
| Laboratorio | Claude | `laboratorio.yml` en GitHub Actions, o en local con Python 3.12 |
| Pruebas | Claude | `motor-analitico`: `python -m pytest -q` (330 en verde). SQL: `supabase/pruebas/01_invariantes.sql` (I1–I112), en la CI de migraciones; en local, sobre PostgreSQL 15 en Docker. Frontend: `npm test` y `vite build` |

**Reglas que no se saltan**:

- Nunca se pegan en el chat tokens, claves ni contraseñas.
- Los agentes con metas **no se cambian a mano mientras dure el
  experimento** (grupo de control). Sus ajustes automáticos están
  congelados desde la 0052 (`CRONOLOGIA.md` §4).
- Los parámetros de una estrategia validada no se cambian sin repetir el
  laboratorio y la prueba de robustez.
- Un análisis de datos de producción dice desde qué fecha los toma
  (`CRONOLOGIA.md` §1).

---

## 2. La situación en una página (2026-10-27)

- **El experimento corre desde el 2026-10-11**: tres agentes con metas
  como grupo de control (Prudencia, Cadencia y Audacia) y un agente
  experimental, **Tendencia cripto**, con la única estrategia que pasó el
  laboratorio.
- **Resultados desde el inicio del experimento** (26-10): Prudencia
  +2,74 R en 10 cierres; Cadencia −0,98 R en 4; Audacia −0,55 R en 9.
  Tendencia cripto, 0 operaciones: ninguna cripto ha roto su máximo de 20
  días estando sobre su media de 200 (la más cerca, zcash, a 1,6 ATR).
- **Las metas diarias son inalcanzables por diseño** (doc fase-2/05) y las
  señales de los agentes con metas **no tienen ventaja demostrada**: en el
  laboratorio rinden entre −0,02 y +0,07 R a 10 años.
- **El laboratorio**: en acciones, nada ha superado a entrar al azar con
  las mismas salidas. En cripto, la tendencia (y el Santo Grial) funcionan
  con el universo de hoy, pero no con las criptos del top de 2021: «real
  pero no demostrada». Tres cambios validados esperan al final del
  experimento: Audacia sin acciones de menos de 10 $, Cadencia solo con
  ADX ≥ 25 (con pocas operaciones) y volver a poner
  `consecuencias_semanales = true`.
- **Los agentes investigan**: cada lunes proponen una hipótesis y el
  laboratorio la prueba. Las tres primeras (MACD positivo) se refutaron.
  Su backlog está revisado y respondido (0051).
- **Fiabilidad (Fase 3)**: panel «Salud del sistema» (ETL, señales, ciclos
  y credenciales), revisión de los lunes en una consulta y Administración
  organizada en pestañas. El ETL va en verde desde el 24-10.

---

## 3. Lo abierto

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

Lo que está hecho y aplicado está en el §4, con el mismo orden por bloques.

### 3.00 Fase 4: replanteamiento (doc fase-4/00)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ⏭️ 👤 | Dar de alta SPY, EFA, IEF, VNQ y DBC | Antes, comprobar que el broker los ofrece. Con la 0062 ya aplicada nacen como solo de cartera y el grupo de control no los ve. Las carteras empiezan solas en la primera sesión del mes siguiente a tener los cinco con 10 meses de historia |
| 🗓️ | Primera decisión de las carteras | Que las dos compren las cinco clases el mismo día (unos 100 $ cada una), que ningún otro agente vea los ETF y que la vara «Cinco clases de activo» aparezca en la comparativa |
| ⏸️ | Ideas nuevas de entrada en el laboratorio | Cerrada la búsqueda hasta que acabe el experimento (decisión del dueño, 2026-11-11; doc fase-4/00 §7). Van 41 ideas |
| ✅ 👤 | Aplicar la 0062 (aplicada el 2026-11-12 a las 06:58 UTC) | Comprobado: «Cartera sin tocar» y «Cartera con tendencia» activas, con su cuenta de 500 $ y sin ninguna decisión todavía (esperan a los cinco ETF, que aún no están dados de alta). `decision-carteras` programada y activa. Las funciones nuevas y la excepción de G6, en su sitio. El universo sigue en 48 activos y las varas no cambian |
| ✅ 👤 | Qué se hace con el replanteamiento (doc fase-4/00 §6 y §7), 2026-11-11 | A, B y C a la vez, conviviendo con el experimento: vara viva, cartera con tendencia y búsqueda de señales cerrada. La ventana de agentes separa cada grupo |
| ❌ | Exposición mensual contra comprar y mantener (doc fase-4/00), 2026-11-11 | Sin demostrar: `tendencia_clases`, `volatilidad_objetivo_clases` y `tendencia_bitcoin` cumplen cinco condiciones de seis (mejor Sharpe que mantener en los dos tramos, menos caída, rejilla) y fallan la del azar: percentiles 91, 87 y 85 en validación, con el 98 exigido. Mantener las cinco clases: +4,4 % anual y −44 % de caída (2007–2020), +9,7 % y −16 % (2020–2026). Con tendencia: +3,2 % y −13 %; +7,3 % y −7 % |

### 3.0 Fase 3 (doc fase-3/00)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ 👤 | Qué pasa con los agentes con metas al acabar el experimento (doc fase-3/08 §4.1) | Se juzgan con el criterio fijado de la 0059 (doc fase-3/12 §3): expectativa en R, intervalo, caída máxima y batir a su vara; la meta diaria queda informativa |
| 🗓️ | Volver a medir el escáner con más datos (sección `9b_escaner` de la revisión) | El 2026-11-05, con 35 «Comprar» de acciones (10-10 → 10-29), −0,19 % a 5 sesiones frente a +0,38 % de media; muy pocos casos y solapados para concluir |
| 🗓️ | Lunes 16-11: que nadie adopte ni evalúe prácticas en el corte | Con la 0061 aplicada, ningún agente del experimento debería tener adopciones nuevas ni veredictos el 16-11. Tendencia cripto sí puede (sus consecuencias siguen activas). Y que las v2 vuelvan a abrir cripto |
| 🗓️ | Stops de 2 a 3 ATR con objetivo hasta 4 en Prudencia y Cadencia: una pista, no un cambio | Pasa a 5 años en Prudencia (−0,04 → +0,19 R), pero a 10 años mejora sin demostrarse en los dos (Prudencia +0,09 R, Cadencia +0,16 R; el intervalo incluye el cero). Se reevalúa con operaciones reales con la regla de la 0030 |
| 🗓️ | Revisar los stops con la regla de la 0030 cuando haya unos 30 (7 el 26-10: 3 «salvo» y 4 pendientes) | Comparar con el laboratorio (salva el 52–68 %, corta el 11–21 %). Con eso se reevalúa la pista de los stops anchos en Prudencia y Cadencia |
| 🗓️ | Siguientes indicadores: fuerza relativa frente al mercado y ancho de Bollinger | La fuerza relativa necesita la serie del índice (S&P 500, bitcoin) en el motor |
| 👤 | ¿Segundo experimento en vivo con el Santo Grial en cripto? | Por defecto, no: es la misma apuesta que Tendencia cripto (que el universo de hoy siga en tendencia). Se reconsidera con su veredicto |
| 👤 | Otros mercados (doc fase-3/00, E9) | Previsto desde la 0019, sin fecha. Primero saber qué mercados permite QuantFury |
| 👤 | Decisiones abiertas con valor por defecto (doc fase-3/00 §5 y fase-3/01 §9) | Espera tras salir por deterioro y límite de stops por activo: no, mientras dure el experimento. Avisos fuera del dashboard: no, de momento |
| ⏸️ 👤 | «Audacia sin acciones de menos de 10 $»: se guarda para el final del experimento (decisión del dueño, 2026-10-25) | Validada en el laboratorio (+0,30 → +0,39 R), pero recalculada el 2026-11-05 con el universo de hoy solo mejora en la validación (doc fase-3/12 §3.3). En vivo, en Audacia v2 |
| ⏸️ | «Cadencia solo con ADX ≥ 25»: se guarda para el final del experimento | Validada a 10 años y en la misma dirección a 5, con pocas operaciones (39 y 21). Recalculada el 2026-11-05: −0,49 R en el diseño, +0,32 en la validación (doc fase-3/12 §3.3). En vivo, en Cadencia v2 |
| ⏸️ 👤 | I5: hipótesis propuestas por un LLM | **Esperamos** a la I3 y a la decisión del dueño sobre el coste |

### 3.0 bis Agentes v2 (doc fase-3/12 §4)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| 🗓️ | Primeras operaciones de las v2: que entran y salen como su original, salvo sus filtros | Que Audacia v2 descarte acciones de menos de 10 $ (`precio_bajo`) y Cadencia v2 las de ADX < 25 (`adx`); que las tres registren sus decisiones. **Hasta el 9-11 lo hacían** (Cadencia v2 descartó por `adx`); desde ese día la práctica 60 les cierra las cripto y no abren nada (revisión del 9-11). La 0061 lo corrige desde el 10-11 a las 15:11 UTC |
| 🗓️ | Veredicto de cada v2 a los 30 cierres (Agentes → Veredicto) | Criterio fijado en la 0060. El laboratorio espera −0,041, −0,175 y +0,054 R |
| ✅ 👤 | Qué llevan las v2 (decisión del dueño, 2026-11-05) | Prudencia v2, sus reglas en cuenta limpia; Cadencia v2 con ADX ≥ 25 y Audacia v2 sin acciones de menos de 10 $, como prueba en vivo; ajustes congelados; 500 $ y saldo ampliable |

### 3.1 Agente experimental «Tendencia cripto» (doc 07)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| 🗓️ | Revisión de las primeras 5 operaciones frente al laboratorio en las mismas fechas (1 de 5: tron, 30-10, −1 R) | Es para encontrar errores, no para juzgar la ventaja |
| 🗓️ | **Veredicto a las 30 operaciones** (unos 6–7 meses) o el **2027-04-30**, lo que llegue antes | Por debajo de 0 R se retira. Entre 0 y +0,10 R, se observa hasta 60. Por encima de +0,10 R, queda validado en vivo. Si la caída supera el 35 %, se pausa y se revisa |
| 👤 | Decisiones abiertas con valor por defecto (doc 07 §8) | Saldo inicial (500 $ por defecto) y visibilidad para los usuarios (visible por defecto) |

### 3.2 Laboratorio de estrategias (doc 06)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Servicios de la guía del dueño (doc fase-3/13), 2026-11-06 | Sin coste no hay sentimiento ya calculado: Alpha Vantage y Finnhub lo cobran, y NewsAPI no admite producción. IBKR pide una cuenta real con fondos; Alpaca para ejecutar aporta poco. Se pueden probar: el perfil de volumen (velas que ya hay), el libro y el flujo de órdenes en cripto (Binance, `bookDepth` desde 2023), el sentimiento de directivos (Form 4) y las noticias de Alpaca (con una clave gratuita del dueño) |
| ❌ | Perfil de volumen (doc fase-3/14), 2026-11-06 | Sin ventaja: comprar el primer toque del nivel con más volumen da −0,051 R en los ETF (1996–2026) y +0,099 R en cripto (2014–2026) en validación, en el percentil 0 y 3 frente a comprar cualquier día por encima del nivel (mínimo 98). Dos ideas más en el registro (34) |
| ❌ | Flujo de órdenes y libro en cripto (doc fase-3/15), 2026-11-06 | Con los ficheros públicos de Binance (`laboratorio/binance.py`). El libro (±1 y ±5 %, 2023–2026) no anticipa nada: −0,020 R en validación, percentil 80. El flujo agresivo (24 h, 2017–2026) es lo primero que supera al azar en validación (100), en el diseño (90) y en las ventanas móviles, pero deja +0,037 R (mínimo +0,10) con factor 1,09: real y demasiado pequeño. 36 ideas registradas |
| ❌ | El flujo de órdenes como filtro de Tendencia cripto (doc fase-3/16), 2026-11-06 | No aporta: con el filtro, +0,978 R en validación frente a +0,934 R sin él y +0,956 R quitando las mismas rupturas al azar (percentil 66; en el diseño, 22). Una ruptura ya es un día de compras fuertes. Corregida la calibración de la frecuencia del azar (repite hasta quedar a un 5 %). 37 ideas registradas |
| ❌ | Compras de directivos, Form 4 (doc fase-3/17), 2026-11-06 | Sin ventaja: con 2 directivos comprando en 30 días y 60 sesiones, +0,682 R en el diseño (percentil 99) pero +0,302 R en validación con 32 operaciones, igual que el azar en las mismas acciones (+0,323 R, percentil 46). En el S&P 100 los directivos casi no compran. `laboratorio/form4.py`, con `SEC_USER_AGENT`. 38 ideas registradas |
| 👤 | ¿Noticias por activo con Alpaca News? (doc fase-3/13 §5.4) | Lo último del doc fase-3/13. Necesita una cuenta gratuita de Alpaca del dueño y su clave como secreto; sin eso no se empieza |
| 🗓️ | Otras ideas para acciones | El momento (§3.11), las fechas de resultados y calidad y valor (doc fase-3/09 §7–8) ya se probaron. Pista para el final: Audacia con `valor_bp_3` |
| ❌ | Comprar cripto a una hora fija (doc fase-3/10 §10), 2026-11-05 | Fijada antes de ejecutarla. 14 criptos, 2024-11 → 2026-11: la elegida (20:00 UTC, 8 horas) da +0,021 R en diseño y −0,068 R en validación, peor que el azar (percentil 0, mínimo 97). Ninguna hora se aparta del azar. Con ella se cierra el modo de 1 hora: ninguna de sus cuatro ideas tiene ventaja |
| ✅ 👤 | Aplicar la 0061 (aplicada el 2026-11-10 a las 15:11 UTC) | Comprobado: las dos funciones llevan la guarda de `consecuencias_semanales`. Las v2 dejaron la 60 y llevan las de su original, en `mp_adopciones` y en `practicas_adoptadas`: Prudencia v2 y Cadencia v2, la 89 y la 110; Audacia v2, la 97 (versión 3 las tres). El grupo de control sigue igual (versiones 12, 11 y 9). Un evento por cada v2 |
| ✅ 👤 | Aplicar la 0058, la 0059 y la 0060 (aplicadas el 2026-11-05, las v2 a las 20:34 UTC) | Comprobado: ^GSPC y ^NDX salen como `referencia` y ningún agente los ve; la vara de acciones vuelve a 33 activos y aparecen S&P 500 (−3,6 % desde el alta) y Nasdaq 100 (−11,4 %). `v_veredicto_agentes` responde: los siete en `pocas_operaciones` (Prudencia 16 cierres, Audacia 14, Cadencia 9) y los cuatro con cierres, como espera el laboratorio. Las v2, con su cuenta de 500 $; en el primer ciclo (20:35) Prudencia v2 abrió ripple, ethereum y BAC, y Audacia v2 ripple y ethereum. Los filtros `precio_bajo` y `adx` aún no han tenido caso: lo de hoy cae antes por dirección o R:R |
| ✅ | Veredicto fijado de antemano (doc fase-3/12 §3, 0059), 2026-11-05 | Lo que espera el laboratorio a 10 años con las reglas de hoy: Prudencia −0,041 R, Cadencia −0,154 R, Audacia +0,064 R, Tendencia cripto +0,913 R. Umbrales de Tendencia cripto para todos (30 cierres, +0,10 R, IC sin el cero, batir a la vara, caída máxima del 35 %). Demostrar +0,10 R pide de 270 a 780 cierres: no se llega antes del 2027-04-30 |
| ✅ | «Faltan X para concluir», desde el experimento y no desde el alta (recomendación 3) | La σ de antes de la 0030 inflaba la cuenta (Cadencia 8,1 R desde el alta, 1,2 desde el experimento) |
| ✅ | Series del S&P 500 y del Nasdaq 100 (doc fase-3/12 §2, 0058), 2026-11-05 | Las dio de alta el dueño; la 0058 las deja solo de referencia. Falta usarlas para la fuerza relativa |
| ✅ | Criterio común del laboratorio (doc fase-3/12 §1), 2026-11-05 | Fijado antes de las pruebas siguientes: <br>• cuenta global de pruebas (32 ideas; la siguiente pide el percentil 98); <br>• el diseño también contra el azar (al menos la mitad); <br>• ventanas móviles de 5 bloques; <br>• aviso de sesgo de supervivencia al comprar caídas. <br>`laboratorio/criterio.py`, en el modo por velas y en el contra el azar |
| 👤 | ¿Experimento en vivo con el momento concentrado? | Configuración fijada ya (ETF, las 2 primeras, 12-1, stop a 5 ATR), juzgada con datos futuros, como Tendencia cripto. Habría que confirmar antes que QuantFury permite operar esos ETF. Por defecto, no se hace |
| ⏸️ | Ampliar el universo cripto de producción con las del top de 2021 que funcionaron (XLM, NEAR, HBAR…) | **Esperamos** porque elegirlas por su resultado repite el sesgo de supervivencia. Se decide con el veredicto del agente |

### 3.3 Agentes con metas: mejoras del doc 05 (grupo de control)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ⏸️ | Entrega C: noches y fines de semana caso a caso (§5.4) | **Esperamos** por tres razones: <br>• los agentes con metas son el grupo de control, y cambiarlos a mitad del experimento ensucia la comparación; <br>• sin ventaja demostrada, afinar *cuándo* operar solo cambia la velocidad a la que se pierde; <br>• necesita semanas de datos en `v_huecos_activos`. <br>Se retoma si el dueño lo decide o cuando acabe el experimento |
| ⏸️ | Entrega B: aporte por sesión, horizonte máximo (10, 5 y 3 sesiones, ya decidido) y revisión al cumplirse el horizonte | **Esperamos** por las mismas razones que la C. Además, es el cambio más profundo y gana con horizontes ya medidos (lleva la 0031 desde el 10-10) |
| ⏸️ | Entrega E: calibración y vigencia de las prácticas (§9) | **Esperamos** a tener datos: necesita semanas de horizontes y resultados observados. Es la primera candidata a retomar, porque mejora la honestidad del aprendizaje sin cambiar la estrategia |

### 3.4 Después del experimento

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ⏸️ | Agente de cartera que combine estrategias con ventaja | **Esperamos** a tener al menos dos estrategias con ventaja. Hoy hay media |
| ⏸️ | Capa narrativa con LLM para el informe semanal (doc 05 §10.2) | **Esperamos** porque tiene un coste por uso que hoy el proyecto no tiene. Decide el dueño |

---

## 4. Hecho

El registro de lo cerrado, por bloques. ✅ hecho y aplicado; ❌ descartado, con el motivo.

### 4.0 Fase 3 (doc fase-3/00)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Apalancamiento de las órdenes con la 0055 (comprobado el 2026-11-05) | Una orden de agente desde la 0055: Cadencia, ripple, 4-11, a 3,2× (la señal pide 3,0× × 500 / 463,78 = 3,23×, al decimal hacia abajo), liquidación a 0,872 bajo el stop de 1,20. Topes de hoy: Prudencia 4,8× (Fase 1 desde la reversión manual del 5-11), Cadencia 5,2×, Audacia 5,5×. Todo como la fórmula |
| ✅ | Medir el escáner (doc fase-3/08 §4.5): sección `9b_escaner` en la revisión de los lunes | Veredicto de cada activo y día desde la 0030 y lo que hizo el precio a 5 y 10 sesiones, frente a la media |
| ✅ | Referencia de mercado y «operaciones que faltan para concluir» en la comparativa (0056, doc fase-3/08 §4.3 y §4.5) | Aplicada el 2026-11-05. Desde el 29-09 y con el precio de las 17:00 UTC del 5-11 (día de caída fuerte): acciones −0,4 %, criptos −20,0 %, bitcoin −9,4 %, todo el universo −6,5 %. Con el cierre del 4-11 eran +3,7 %, −15,2 % y −4,2 %: la vara usa el último precio, igual que el equity de los agentes |
| ✅ | `hipotesis.yml` desde `pg_cron` y `cron.job` legible para el rol de lectura (0057, doc fase-3/08 §4.6) | Aplicada el 2026-11-05: `hipotesis-agentes` activo en `cron.job`, lunes 02:00 UTC. El primer disparo será el 9-11 |
| ✅ 👤 | Aplicar la 0055 (aplicada el 2026-11-02 a las 21:48) | Comprobado: base 500 $ en las cuatro cuentas de agente; saldo para operar 1.500 $ (Prudencia, Fase 2) y 2.500 $ (Cadencia, Audacia y Tendencia cripto); tope por orden 2,9×, 5,3× y 6,1×; `CHECK` a 20×. Los ciclos siguen sin fallos |
| ✅ 👤 | Aplicar la 0054 (aplicada el 2026-11-02 a las 21:48) | Comprobado: las dos peticiones, rechazadas con su resolución |
| ✅ | Saldo para operar con base fija y escalones (D25, decisión del dueño, 2026-11-02; 0055) | Base × tope de la fase, con la base en el saldo inicial o el último escalón de la 0014, que nunca baja. El tope se mide sobre la base (regla protegida nº1 reformulada): con 415 $ Audacia admite 6,0× por orden. Para los tres agentes y el simulador. Cambia el grupo de control a mitad del experimento: corte en `CRONOLOGIA.md` |
| ❌ | Comprar el rebote con fondo bajista, S&P 100 a 10 años (doc fase-3/11 §6), 2026-11-04 | Fijada antes de ejecutarla. Gana +0,327 R en validación (837 ops, IC +0,22 – +0,45), pero comprar cualquier día de una caída da lo mismo (+0,331 R de mediana): percentil 47, mínimo 95. Lo que gana es el sesgo de supervivencia del S&P 100; el giro del MACD no aporta |
| ⚠️ | Comprar caídas en los ETF, sin sesgo de supervivencia, 1996–2026 (doc fase-3/11 §7), 2026-11-05 | Fijada antes de ejecutarla. **Pasa el criterio**: +0,158 R en validación (2017–2026, 789 ops, IC +0,09 – +0,23), percentil 96 frente a largos un día cualquiera (mínimo 96; 98 con otras 100 semillas). Pero en el diseño (1996–2017) quedó por debajo del azar (percentil 4): no es estable. No se toca nada; la regla «solo comprar en tendencia alcista» queda en duda y se guarda para el final del experimento |
| ✅ | Lecturas «sin dirección» del escáner (doc fase-3/11), 2026-11-04 | No hay fallo en O: empata 1 a 1 (medias 50/200 bajistas, MACD alcista). Así están 31 de los 48 activos; desde la 0030 rondan el 66–69 % de las lecturas. A 10 años, la dirección del escáner no anticipa las 20 sesiones siguientes. El escáner explica ahora qué indicadores empatan; la confluencia del motor no se toca (grupo de control) |
| ❌ | Largos tras un hueco al alza de resultados, fuera de la muestra: 95 medianas del S&P 400 a 10 años (doc fase-3/10 §9), 2026-11-04 | Fijada antes de ejecutarla. +0,029 R en diseño (146 ops) y +0,247 R en validación (71 ops), pero los largos al azar dan +0,078 R de mediana y la supera solo el 63 % de las tiradas (mínimo 94 %). Lo del S&P 100 no se lleva a otras acciones |
| ❌ | Deriva tras resultados con hueco, velas diarias, S&P 100 a 10 años (doc fase-3/10 §8), 2026-11-04 | Casi: hueco de 2 ATR y 20 sesiones da +0,434 R en diseño y +0,226 R en validación (212 ops), pero el IC 90 % toca el cero (−0,003) y supera al azar en el 90 % (mínimo 93 %). Lo pone el lado largo |
| ❌ | Hueco del día de resultados con velas de 1 hora, S&P 100 (doc fase-3/10 §7), 2026-11-04 | Dentro del día pierde en las tres versiones. Dejándolo correr cinco sesiones tras un hueco de 2 ATR da +0,106 R en validación, pero con 57 operaciones el IC 90 % incluye el cero y supera al azar solo en el 90 % (mínimo 92 %) |
| ❌ | Ruptura de la primera hora en acciones con velas de 1 hora (doc fase-3/10 §6), 2026-11-03 | Pierde en las seis combinaciones: la elegida da −0,023 R en validación (1.317 ops). Supera al azar en el 100 %, pero antes de costes solo gana +0,03 R y el spread se lleva 0,05 R: menos mala que el azar, no una ventaja |
| ❌ | Rebote tras una caída brusca en cripto con velas de 1 hora (doc fase-3/10), 2026-11-03 | Sin ventaja: lo mejor del diseño (caída de 8 ATR, salida a las 6 h) da −0,005 R en validación (49 ops) y supera al azar solo en el 80 %. Entrar y salir en horas cuesta unos −0,08 R de spread por operación. El modo de 1 hora (`laboratorio/intradia.py`, modo `intradia` de `laboratorio.yml`) queda para las otras ideas rápidas |
| ❌ | «Ampliar mi riesgo abierto por mercado» (Prudencia) y «Mi saldo queda atrapado con la bolsa cerrada» (Audacia), 2026-11-02 (doc fase-3/07 §7, 0054) | Prudencia con 2× o 3× su riesgo en cripto, en vez de 1×, entra en más cripto y acaba peor en todos los tramos (sus cripto valen −0,12 a −0,19 R en validación). Vender acciones antes del cierre para Audacia sería cerrar operaciones a medias cada tarde; la rotación ya libera saldo al abrir. Rechazadas no se reabren durante el experimento |
| ✅ 👤 | Prácticas congeladas durante el experimento (decisión del dueño, 2026-11-10; 0061) | `fn_adoptar_practica` y `fn_evaluar_adopciones` no hacen nada mientras `consecuencias_semanales = false`. Las v2 dejan la 60 y llevan las prácticas activas de su original. Las del grupo de control (89, 97 y 110) se quedan: quitarlas también sería cambiarle las reglas. Invariante I111; la I48 enciende las consecuencias un momento para probar la adopción |
| ✅ | Revisión del lunes 9-11 (datos del 3 al 10-11; las v2, desde el 5-11) | **Ninguna hipótesis, y es correcto**: la H3 ya se puede medir (82–84 descartes por `rr` por agente) y esos descartes bajaron −0,33 a −0,51 ATR frente a −0,23 del universo: el filtro protege. **Hallazgo**: el corte semanal adopta prácticas sin congelar; el grupo de control lleva la 89, la 97 y la 110 (versiones 12, 11 y 9, sin efecto todavía) y las v2 la 60, que les cierra las cripto desde el 9-11. Salud en verde; Audacia pasó sola a Fase 2 el 8-11 |
| ✅ | Revisión del lunes 2-11 (datos del 26-10 al 2-11, con la 0043, la 0052 y la 0053; el 2-11 a medio día) | **Ninguna hipótesis, y es correcto**: el generador corrió a las 00:17 UTC sin fallos, pero ninguna vía llegaba a su mínimo. H1: como mucho 8 decisiones resueltas por tipo (hacen falta 20). H2: 10–12 subidas perdidas por agente, pero solo `macd_positivo` tiene soporte, con un lift de 1,34–1,46 (hace falta 1,5) y ya refutada hace menos de 8 semanas. H3: 19–21 descartes por `rr` con 5 sesiones vistas (hacen falta 30), y **bajaron** −0,5 a −1,2 ATR frente a −0,13 del universo: el filtro protege. H4: sin peticiones de plantilla. Salud en verde. NLY de Audacia salió por rotación tras 14 días (+0,56 R) y liberó margen para bitcoin-cash y zcash |
| ❌ | Calidad y valor en acciones con SEC EDGAR (doc fase-3/09 §8), 2026-11-01 | No robusto: 7 de 72 pruebas validan, todas con filtros de valor y casi todas en el S&P 100, pero en el tramo de diseño (2017–2023) el mismo filtro empeora a Prudencia y Cadencia, y en las acciones de producción solo valida una vez. Poca deuda casi siempre empeora. La carga de EDGAR (con `SEC_USER_AGENT`) y los filtros quedan en el laboratorio |
| ❌ | No entrar antes de resultados en acciones (doc fase-3/09 §7), 2026-10-31 | Refutado en las 36 variantes (3, 5, 10 y 15 sesiones; tres agentes; producción a 10 y 5 años y S&P 100). Lo más cerca, Cadencia con 5 sesiones: +0,05 R justo por debajo del mínimo. A Audacia los resultados le favorecen. Los filtros `sin_resultados_*` quedan en el laboratorio |
| ❌ | Freno por choque de mercado en cripto (doc fase-3/09 §6), 2026-10-31 | Refutado: no abrir cripto tras caer bitcoin un 3, 5 o 7 % (pausa de 2 o 5 días) no mejora a nadie en validación. A Tendencia cripto no le cambia nada; en los agentes con metas, lo que quita es peor que el resto, pero compran el mismo retroceso días después. Los filtros `sin_choque_*` quedan en el laboratorio |
| ✅ 👤 | Aplicar la 0053 (aplicada el 2026-10-31) | Comprobado: Prudencia vuelve a salir por deterioro (versión 10) y el ajuste manual está registrado |
| ✅ 👤 | Aplicar la 0052 (aplicada el 2026-10-31) | Comprobado: `fn_ajustar_parametros` ya mira `consecuencias_semanales` |
| ✅ | Documentar el hackeo a Binance del 29-10 (doc fase-3/09, `CRONOLOGIA.md` §5) | Todo cripto cayó a la vez; los stops salieron a su nivel; la primera operación de Tendencia cripto fue una ruptura falsa de tron en pleno suceso |
| ✅ 👤 | Congelar los ajustes automáticos durante el experimento (decisión del dueño, 2026-10-27; 0052) | `fn_ajustar_parametros` no cambia nada mientras `consecuencias_semanales = false`; las decisiones se siguen registrando y resolviendo, y al acabar se ajusta con toda la evidencia. Los dos ajustes del 15-10 se quedan. Ese día Prudencia estaba a 2 salidas de apagar el deterioro (8 de 10, efecto medio negativo) y Cadencia a 2 rotaciones de bajar el umbral a 1,4 |
| ✅ 👤 | Tope de fecha del experimento: **2027-04-30** (decisión del dueño, 2026-10-27) | El experimento acaba a las 30 operaciones de Tendencia cripto o el 2027-04-30, lo que llegue antes. Si no hay 30, se juzga con las que haya y con el laboratorio de ese periodo (doc fase-3/08 §4.2) |
| ✅ | Diagnóstico del comportamiento del 13 al 24-10 | Doc fase-3/00 §2: 7 problemas (P1–P7) |
| ✅ 👤 | Renovar el token `github_pat_altas` de Vault (renovado el 2026-10-24) | Comprobado: GitHub responde 204 desde el disparo de las 13:07 UTC y el ETL de cripto vuelve a correr cada hora. Caducó el 23-10 (GitHub respondía 401). Sin él no corre el ETL desde la BD: el lunes no habría señales de acciones ni precio fresco para las posiciones de acciones. Nuevo token *fine-grained* con **1 año** de caducidad y solo Actions: Read and write; `vault.update_secret` como dice `RUNBOOK-sprint-4.md` («Renovación») |
| ✅ 👤 | Aplicar la 0045 (E1, salud del sistema; aplicada el 2026-10-24) | Incluye: <br>• la toma parcial se salta la posición que no se parte en unidades enteras (I93); <br>• cada disparo del ETL guarda su petición y la pasada siguiente lee la respuesta: un `fallo` por episodio y un `etl` al recuperarse (I94); <br>• `rpc_salud_sistema` y el panel «Salud del sistema» en Administración; <br>• `analista_lectura` lee todo `public`, también lo que se cree después, y ejecuta las funciones no volátiles (I95) |
| ✅ | Comprobar la 0045 (2026-10-24) | Las 24 vistas se leen con `analista_lectura` (antes fallaban 11), también `v_comparativa_agentes` y `agente_decisiones_diarias`. El disparo de cripto de las 15:07 UTC guarda su petición y GitHub respondió 204; su `estado_http` lo rellena la pasada siguiente. El 401 del 23–24-10 no deja evento: aquellos disparos son anteriores a la 0045. Falta ver el panel «Salud del sistema» en el navegador (lo abre el dueño, con su sesión de admin) |
| ✅ | E2: caducidad de las credenciales en el panel de salud, con aviso 14 días antes (0050) | Tabla `credenciales` con el inventario (solo metadatos, nunca el valor): de las 5, solo caducan `github_pat_altas` (24-10-2027) y la clave anónima (2036). `fn_revisar_credenciales` a diario a las 07:00 UTC: un `sys` a 14 días o menos y un `fallo` al caducar, uno por nivel y fecha. Botón «Renovada» en el panel para anotar la nueva fecha (`rpc_credencial_renovada`, auditado). Invariante I100 |
| ✅ 👤 | Aplicar la 0050 (aplicada y comprobada el 2026-10-26) | Las 5 credenciales en producción; `github_pat_altas` caduca el 24-10-2027 (363 días) y la clave anónima en 2036. `fn_revisar_credenciales`, `rpc_credencial_renovada` y `rpc_salud_sistema` con credenciales, comprobados. La tarea de pg_cron no se puede ver con `analista_lectura` (no lee `cron.job`). Falta que el dueño mire el panel y confirme en GitHub la fecha del token |
| ✅ | E3: revisión del backlog (doc fase-3/07, 0051), 2026-10-26 | 5 peticiones: 3 × «El filtro rr me deja sin operar», **rechazadas con el laboratorio** (bajar el R:R da hasta el triple de operaciones, pero ninguna variante mejora la expectativa, a 5 ni a 10 años); «Ampliar el universo», rechazada (el 85–95 % de sus descartes eran por R:R: la misma petición contada dos veces); «Señales más frecuentes», implementada (0029; solo volvió con el token caducado). Ya no saltan por lo mismo: el universo no salta si un filtro explica el 80 % de los descartes, y el filtro rechazado no se reabre durante el experimento. Invariante I101 |
| ✅ 👤 | Aplicar la 0051 (aplicada y comprobada el 2026-10-26) | Las 5 peticiones cerradas con su resolución; el disparador nuevo de «Ampliar el universo», en producción |
| ✅ | Revisión semanal guiada (doc fase-3/07 §6), 2026-10-26 | `scripts/revision_agentes.sql` es la consulta de los lunes: últimos 7 días, con salud del sistema (ETL, frescura, fallos, credenciales), lo cerca que está cada cripto de la ruptura, hipótesis con su concordancia, backlog y descartes. Funciona con `analista_lectura`. La tabla de qué mirar está en el doc |
| ✅ 👤 | Agentes investigadores: diseño (doc fase-3/01), decidido el 2026-10-24 | La meta diaria no les hace aprender: no razonan y solo piden lo que está en 7 plantillas. Pasan a proponer hipótesis a partir de su propia evidencia, el laboratorio las prueba y el dueño decide. Dos pasos: primero determinista, sin coste y sin tocar cómo operan; después, un LLM con el mismo contrato |
| ✅ | I1: hipótesis de los agentes (0046) | Incluye: <br>• `agente_hipotesis`, con tres fuentes: H1 (decisiones que cuestan), H2 (movimientos perdidos) y H4 (cierre parcial y trailing stop del backlog); <br>• una por agente y semana, en el autodiagnóstico de los lunes; <br>• pestaña «Investigan» en Agentes y revisión en Administración. <br>Invariante I96. Con los datos del 24-10, la H2 propondría a los tres «entrar también con el MACD positivo»: se cumplía en el 75–78 % de sus 8–9 movimientos perdidos, frente al 40 % de los días. La H1 aún no salta: tras la 0043 solo hay 1 deterioro resuelto |
| ✅ 👤 | Aplicar la 0046 (aplicada y comprobada el 2026-10-24) | Tabla y vistas nuevas en producción y legibles con `analista_lectura`; el generador está enganchado al autodiagnóstico de los lunes. Simulación de solo lectura con los datos de hoy: H2 propondría a los tres «entrar también con el MACD positivo» en acciones (Prudencia y Cadencia 8 movimientos perdidos en 6 activos, Audacia 9 en 7; soporte 75–78 %, frecuencia 40 %). H1 no salta (ningún tipo llega a 20 decisiones resueltas) ni H4 (no hay peticiones de cierre parcial ni de trailing stop) |
| ✅ | Revisar las primeras hipótesis (lunes 26-10) | Una por agente, a las 00:17 UTC, con su evento «… propone probar»: H2 «entrar también con el MACD positivo» (Prudencia y Cadencia, 8 movimientos perdidos en 6 activos; Audacia, 9 en 7; soporte 75–78 %, frecuencia 39 %). Coincide con la simulación del 24-10 |
| ✅ | I2: el laboratorio reproduce a los agentes | Estrategia `agente`: banda de volatilidad, deterioro en dos lecturas, toma parcial, stop que sigue y condición del catálogo. El motor admite la toma parcial, y `laboratorio/agentes.py` traduce la estrategia de producción. No reproduce la rotación ni el reparto. 250 pruebas del motor en verde |
| ✅ | I3: prueba automática con `hipotesis.yml` y concordancia con producción | Los lunes a las 02:00 UTC, el agente actual frente al agente con el cambio, y 20 tiradas al azar con las mismas salidas. El percentil exigido sube un punto por prueba anterior. Escribe el veredicto y deja un evento del agente. Pasada real, sin escribir: «entrar también con el MACD positivo» queda refutada para Prudencia (+0,10 R → +0,006 R; percentil 65 frente al 90 exigido) |
| ✅ | Revisar la primera pasada de `hipotesis.yml` (lunes 26-10) | El `schedule` de las 02:00 llegó a las 07:08 UTC (retraso de GitHub), pero funcionó. Las tres **refutadas**, con el [informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/40283959627) y su evento: Prudencia −0,04 R (percentil 75), Cadencia −0,09 R (40) y Audacia −0,25 R (80), frente a +0,05 R y percentil 90 exigidos. **Concordancia**: Prudencia 50 %, pero Audacia 23 % y Cadencia 12 % de sus entradas reales tienen gemela en el laboratorio: en esos dos el veredicto describe más al laboratorio que al agente |
| ✅ | Por qué el laboratorio reproducía tan pocas entradas de Cadencia y Audacia (doc fase-3/07 §5), 2026-10-26 | **Fallo de la medida**: contaba desde el alta, y el 80 % de sus entradas eran de antes de la 0030 o con otros parámetros. Con las reglas de hoy: Prudencia 55 %, Audacia 69 %, Cadencia 33 % (6 entradas). Lo que falta es R:R encontrado durante la sesión, que con velas diarias no se ve. `concordancia.py` mide ahora desde las reglas vigentes y avisa con menos de 20 entradas |
| ✅ | I4: registro de descartes y H3 (0047) | `agente_descartes`: en cada ciclo, una fila por agente, activo, día y motivo, para los filtros del perfil (fuerza, origen de los niveles, R:R y ATR alto o bajo); se conservan 120 días. La H3 propone relajar el filtro cuyos descartes subieron claramente más que su universo. En el laboratorio, `fuerza_minima`. Invariante I97 |
| ✅ 👤 | Aplicar la 0047 (aplicada el 2026-10-24) | Registra descartes desde el 24-10: 52 hasta el 26-10, casi todos por `rr` (40 en 11 activos; además `atr_alto` 5, `niveles_origen` 4 y `atr_bajo` 3). La H3 aún no salta: compara contra la semana anterior y no hay base. El mismo lunes los tres agentes piden «El filtro «rr» me deja sin operar» (backlog, para la E3) |
| ✅ 👤 | Cortos en el laboratorio (doc fase-3/02), 2026-10-24 | **Sin ventaja.** `tendencia_corta` se queda en +0,04 R a 5 años y −0,26 R a 10, y no supera al azar. `confluencia_corta`, lo que harían los agentes, pierde entre 0,29 y 0,38 R. Operar al revés que Audacia daría unos +7 $ con spread y financiación, no +84,78 $. En el laboratorio, su contraria acierta el 52–68 %, pero pierde. La regla protegida nº2 se mantiene |
| ✅ | Excluir acciones baratas u objetivo mínimo frente al spread, en el laboratorio (doc fase-3/02 §5) | El objetivo frente al spread no actúa. Sin las acciones de menos de 10 $, **Audacia mejora de +0,30 a +0,39 R** (IC [+0,11, +0,70], supera a todas las tiradas al azar). Prudencia y Cadencia, no. Es una de 9 variantes probadas |
| ✅ | Los stops: qué salvan y qué cortan; stops alternativos y entrada escalonada (doc fase-3/03), 2026-10-25 | En el laboratorio, por cada stop que corta una ganancia hay de 3 a 6 que evitan una pérdida mayor (Prudencia 58/21 %, Cadencia 68/12 %, Audacia 52/11 %). No cambia la regla general: ensanchar el stop apunta a ayudar a Prudencia y Cadencia (sin demostrarse a 10 años) y empeora a Audacia. Promediar a la baja sube los aciertos pero no la expectativa, en ningún agente |
| ✅ | Seguir el precio después de cada stop (0048) | Velas de las 10 sesiones siguientes, con la regla del laboratorio: `post_stop_evento` (corto, salvo, ambiguo o ninguno) y `v_seguimiento_stops`. `fn_seguir_stops`, cada hora a los :45; al aplicarse rellena los stops de los últimos 30 días. Sección `6_stops` en `scripts/revision_agentes.sql`, que separa los de antes y después de la 0030. Invariante I98 |
| ✅ 👤 | Aplicar la 0048 (aplicada y comprobada el 2026-10-25) | La primera pasada (08:01 UTC) revisó 98 stops de los últimos 30 días, como en la simulación previa: entre los agentes, 60 «salvo» y 4 pendientes, casi todos de antes de la 0030, con stops a 0,1 ATR (caída posterior media de 11 a 28 R, que solo dice que su riesgo era diminuto). Con la regla de la 0030 hay 5: 2 «salvo» de Audacia y 3 pendientes. La sección `6_stops` de la revisión funciona con el rol de lectura |
| ✅ | El escáner dice qué hacer; guía rehecha (doc fase-3/04), 2026-10-25 | Veredicto por activo (Comprar, Esperar, No comprar, Sin datos) con su motivo, niveles con el spread y qué agentes la tomarían. Guía: «Cómo usarla», «Cómo leer el laboratorio» y el escáner reescrito |
| ✅ | ADX y media de 20 en el catálogo de condiciones (0049, doc fase-3/05) | No votan en la confluencia: entran en el catálogo de la H2 y del laboratorio (`filtro` y `condicion`). Hallazgo: el 97 % de las entradas de los agentes están por debajo de su media de 20 (compran retrocesos, por el R:R mínimo), así que los filtros de sobreextensión no aportan. El ADX ≥ 25 ayuda a Cadencia (a 10 años, +0,04 → +0,33 R, IC [+0,06, +0,61], 39 operaciones) y no a Prudencia ni a Audacia. Invariante I99 y prueba de que los catálogos de SQL y Python coinciden |
| ✅ 👤 | Aplicar la 0049 (aplicada el 2026-10-25) y que el ETL escriba `sma_20` y `adx_14` | Columnas, vista y generador comprobados en producción. Comprobado el 26-10: 47 de 47 filas con `sma_20` y 46 con `adx_14` (falta maxlinear, que no tiene historial). En cripto el ADX sale con solo 30 días de rango real, así que es más ruidoso |
| ✅ | Lo que faltaba del ADX, según el documento del dueño (doc fase-3/06), 2026-10-26 | Solo en el laboratorio. **Ningún filtro pasa** en los agentes (+DI/−DI los deja sin entradas porque compran retrocesos; el tope de 40 y la «zona 20–40» empeoran). El ADX **empeora a Tendencia cripto** (+0,86 → +0,60 R a 10 años). El giro ADX + RSI no supera al azar. El **Santo Grial pasa en cripto** (+0,40 R, IC [+0,20, +0,61], supera a todas las tiradas al azar) y 5 de 6 pruebas de robustez, pero **falla con las criptos del top de 2021** (−0,14 R): real pero no demostrado, como Tendencia cripto |

### 4.1 Agente experimental «Tendencia cripto» (doc 07)

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

### 4.2 Laboratorio de estrategias (doc 06)

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Motor causal, métricas, veredicto, workflow `laboratorio.yml` | PR #40 |
| ✅ | Primera ronda: actual, tendencia, reversión (5 años, 43 activos) | Solo pasa tendencia en cripto. [Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38132253307) |
| ✅ | Prueba de robustez (`robustez.py`, modo `robustez` del workflow) | PR #41. Cumple 3 de 4 criterios. [Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38132842239) |
| ✅ | Laboratorio a 10 años | Tendencia en cripto, reforzada: +1,09 R, IC [+0,57, +1,70], 203 operaciones en validación. En acciones, +0,12 R con el intervalo incluyendo el cero: sigue sin agente (doc 06 §3.7). [Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38135711624) |
| ✅ | Segunda ronda: estrategias del manual del dueño (doc 06 §3.8) | **ruptura_volumen en acciones** pasa: +0,29 R en validación. También pasa la robustez formal, pero con márgenes justos y solo 12 de 29 acciones positivas. El resto no aporta: <br>• el objetivo a 2R empeora la ruptura en cripto; <br>• la reversión con Bollinger falla. <br>[Informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38163243913) |
| ✅ | Ruptura con volumen en acciones: amplitud (S&P 100) y referencia al azar (doc 06 §3.9–3.10) | **No se crea agente de acciones.** En el S&P 100, entrar al azar con las mismas salidas rinde lo mismo que la ruptura (+0,28 frente a +0,27 R): la «ventaja» es el mercado alcista con supervivientes, no la señal. En cripto, el azar da +0,65 R frente a +1,09 R de tendencia: la mayor parte de la ventaja de Tendencia cripto está en sus salidas. Desde ahora el criterio exige superar a la referencia al azar |
| ✅ | Momento relativo en acciones (doc 06 §3.11), 2026-10-13 | **No aporta selección frente al azar** con la configuración fijada de antemano (las 4 o 10 primeras, 12-1), en ningún universo. En los 19 ETF sin sesgo de supervivencia, la validación queda en el percentil 33 de 30 tiradas al azar. Solo las carteras muy concentradas (2 o 5) pasan, pero se eligieron tras ver los datos. **No se crea agente de acciones.** Herramientas nuevas: el modo `contra_azar`, la medida «% / mes» y `--universo etf` |

### 4.3 Agentes con metas: mejoras del doc 05 (grupo de control)

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
| ❌ | Descartar operaciones porque no caben en la ventana del día | El dueño: «no podemos tener solo una visión inmediata» (doc 05 §5.2) |
| ❌ | Presupuesto de pérdida diario | Decisión del dueño (doc 05 §8.1) |

### 4.4 Después del experimento

| Estado | Tarea | Qué hace falta / notas |
|---|---|---|
| ✅ | Panel comparativo (0040, `v_comparativa_agentes`) | Los cuatro agentes con las mismas medidas: <br>• expectativa en R, con los cierres parciales; <br>• R total; <br>• aciertos; <br>• factor de beneficio; <br>• rentabilidad y caída. <br>Se miden en todo el histórico y «desde el experimento» (el alta de Tendencia cripto). Panel «Comparativa» en Agentes. Invariante I89 |

---

## 5. Datos útiles

| Qué | Dónde |
|---|---|
| Migración más reciente | `0053_prudencia_vuelve_a_salir_por_deterioro.sql`. La siguiente es la 0054 |
| Decisiones numeradas | D1–D25 (`fase-2/04-sprint-backlog.md`). D21 niveles, D22 cripto prudente, D23 spread, D24 agente experimental, D25 saldo para operar con base fija (0055) |
| Guardarraíles | G1–G6 (`fase-2/03-logica-de-agentes.md` §4) |
| Reglas del monitor | M1–M4 y M3' (doc 03) |
| Spread pesimista (QuantFury) | Acciones 0,03 $; AMCR 0,10 $; BTC 5 $; ETH 0,10 $; resto de cripto 0,10 %. Nunca baja del configurado aunque el observado sea menor |
| Lanzar el laboratorio | Actions → `laboratorio` → *Run workflow*. Modo `laboratorio` (estrategias, periodo) o `robustez` (estrategia, clase) |
| Activos sin datos en Yahoo | SPCX, el token de maxlinear (suspendido en la 0032), LUNA1-USD y MATIC-USD |
