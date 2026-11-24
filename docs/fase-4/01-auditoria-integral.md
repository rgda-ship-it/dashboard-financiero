# Auditoría integral: del requisito al código (2026-11-21)

> **Vigencia**: foto de ese día.
>
> **Para qué sirve**: revisar cada proceso en tres capas: el **requisito o
> la decisión** (¿tenía sentido y con qué evidencia?), el **diseño** (¿la
> regla hace lo que se decidió?) y la **implementación** (¿el código hace
> lo que dice la regla?).
>
> **Método**: lectura del código en `master` (`00b2a65`): laboratorio
> (`motor.py`, `asignacion.py`, `contra_azar.py`, `criterio.py`,
> `datos.py`, `agentes.py`, `concordancia.py`), conectores, indicadores y
> la última definición de cada función de agentes y simulador en
> `supabase/migrations/` (`fn_decidir_agente` de la 0055,
> `fn_monitorear_ordenes` de la 0034, `fn_ciclo_agente` de la 0024,
> `v_ordenes_abiertas_monitor` de la 0033, funciones de base de la 0055).
>
> **Lo que NO se hizo**: no se consultó producción (la red de esa sesión
> no llega a Supabase); las consultas están en
> `scripts/auditoria_2026-11-21.sql` y **se lanzaron el 2026-11-24**: los
> resultados, en el §7, que corrige el §1 punto 3 y el C2. Tampoco se ejecutaron los tests ni el
> laboratorio. Las definiciones vigentes se dedujeron de la última
> migración que crea cada función, no se leyeron en la base de datos.
>
> Leyenda: **[comprobado]** en el código · **[hipótesis]** pendiente de
> datos · **[decisión]** le toca al dueño.

---

## 1. En una página

1. **El laboratorio parece honesto.** No se ha encontrado fuga del futuro
   ni en el motor diario ni en la cartera mensual. La conclusión «no hay
   ventaja en la entrada» se sostiene en lo revisado.
2. **El problema está antes del código, en los requisitos.** Las metas
   diarias no son solo inalcanzables: **gobiernan** qué compra el agente y
   con cuánto apalancamiento. El grupo de control se ha tocado varias
   veces. El tope duro de 5× ya no es un tope duro. Y el veredicto de los
   agentes se mide contra un laboratorio que no los reproduce.
3. **El simulador regala algo en los stops de acciones.** El monitor ve un
   precio cada ~30 minutos y, si está por debajo del stop, cierra **al
   stop**, no al precio que vio. Cuánto regala lo dirá la consulta A1.
   *(24-11, §7: en acciones casi nada, +0,02 R; en cripto, +0,08 R por
   stop, por encima del umbral de 0,05.)*
4. **El criterio frente al azar depende del orden** en que se prueban las
   ideas. Con otra regla igual de razonable, una de las pruebas de la
   fase 4 habría pasado.
5. **Tres sospechas del marco anterior eran falsas**: hay calendario con
   festivos (0031), la rotación sí paga el spread (0034) y, según la
   información pública, Quantfury no cobra por el apalancamiento (§5).

---

## 2. Capa 1: requisitos y decisiones

### R1 · El objetivo: «señales que den beneficio» [decisión]

- **Evidencia del proyecto**: 42 ideas sin ventaja frente al azar; entrar
  al azar con un stop que sigue al precio rinde lo mismo que las señales.
- **Juicio**: con datos diarios gratuitos, solo largos y spread minorista,
  el requisito tal como está escrito no tiene respaldo en ningún dato del
  proyecto. Mantenerlo como objetivo es lo que produce el círculo descrito
  en fase-4/00 §1.
- **Propuesta**: escribir el objetivo con algo medible y alcanzable. Por
  ejemplo, «rentabilidad parecida a comprar y mantener, con menos caída y
  sin errores de ejecución» (opción D de fase-4/00).

### R2 · Las metas diarias del 2, 5 y 7 % [comprobado]

- **Qué se decidió**: metas diarias como objetivo de los agentes, que
  luego se reconocieron inalcanzables por diseño (fase-2/05: 0 de 36 días
  cumplidos).
- **Qué hace el código** (`fn_decidir_agente`, 0055):
  - Si la meta está cubierta, el agente deja de abrir ese día (N9).
  - Si no, prueba repartos de 1, 2, 3… candidatas ordenadas por
    `rendimiento = apalancamiento × recorrido hasta el objetivo`. Elige el
    mayor reparto que cubra la meta y, **si ninguno la cubre, el de más
    ganancia potencial**, que es el de más apalancamiento.
- **Juicio**: la meta no es una métrica informativa. Es una entrada del
  motor de decisión que lo empuja hacia más apalancamiento justo cuando va
  peor, porque con pérdidas el déficit del día crece. El riesgo por stop
  sigue acotado (riesgo por operación y G6), así que no es una martingala,
  pero sí sesga la selección hacia lo más apalancado en vez de hacia lo
  mejor.
- **Propuesta**: al acabar el experimento, que la meta deje de entrar en
  la decisión. En el laboratorio ya se puede medir cuánto cuesta este sesgo.

### R3 · «El grupo de control no se toca» [comprobado en los documentos]

- **Qué se ha tocado** desde el 11-10: dos ajustes automáticos (15-10),
  otro el 29-10 deshecho por la 0053 (decisión del dueño), el saldo y el
  apalancamiento de cada orden (0055, decisión del dueño, a mitad del
  experimento), la congelación de prácticas (0061) y el universo (MXL en
  lugar del token, 17-11).
- **Qué puede responder**: con unos 20 cierres por agente, separar
  +0,1 R de 0 R con una dispersión cercana a 1 R exige del orden de 800
  operaciones. Las v2, además, hacen lo mismo que su original: sus filtros
  no han actuado ni una vez (ESTADO §3.0 bis).
- **Juicio**: no es un grupo de control en sentido estricto y casi con
  seguridad acabará el 2027-04-30 en «no concluyente». Mantenerlo congelado
  bloquea cambios ya validados sin dar a cambio una respuesta.
- **Propuesta** [decisión]: escribir ahora qué pregunta responde el
  experimento y con cuántas operaciones. Si no hay respuesta posible,
  cerrarlo antes y pasar lo validado.

### R4 · El tope duro de 5× [comprobado]

- **Requisito original**: tope duro de 5× en la Fase 1, con el
  apalancamiento recomendado aparte.
- **Qué hace el código** (0055): `fn_escala_operar = base / equity` (con
  techo de 20×). Cada tope se multiplica por esa escala. Con 500 $ de base
  y 300 $ de equity, el tope de la fase pasa a 5 × 1,67 = **8,3× sobre el
  equity real**. La restricción de la tabla subió de 5× a 20×.
- **Juicio**: el riesgo por stop no cambia, pero el requisito «tope duro
  de 5×» ya no se cumple tras pérdidas. Puede que se decidiera sabiéndolo.
  El documento de la 0055 no lo expresa así.
- **Propuesta** [decisión]: reconfirmarlo con la consulta A4 delante.

### R5 · El veredicto de los agentes (0059) [comprobado]

- **Qué se decidió**: juzgar a cada agente contra «lo que espera el
  laboratorio».
- **Qué reproduce el laboratorio**: entradas y salidas de un activo
  decididas al cierre. **No** reproduce el reparto, la rotación, las metas
  ni la decisión intradía (`agentes.py`, `concordancia.py`). La
  concordancia de entradas es del 33 % en Cadencia y del 69 % en Audacia.
- **Juicio**: se compara a un agente con la expectativa de otro sistema
  que solo se le parece en parte. Si el agente se aleja de esa
  expectativa, no se sabrá si es azar o la parte que no se modela.
- **Propuesta**: juzgar a los agentes contra su vara y contra el azar en
  vivo (la misma exposición con entradas al azar), no contra el
  laboratorio.

### R6 · El listón frente al azar crece con el orden [comprobado]

- **Regla** (`criterio.py`): percentil exigido = `100 − 10/√(1+previas)`.
  La primera idea necesitaba el 90 % y la 33.ª en adelante, el 98 %.
- **Consecuencia**: la misma prueba da veredictos distintos según cuándo
  se haga. `tendencia_clases` salió en el 91 %: probada la primera, habría
  pasado. No equivale a una corrección estándar por pruebas múltiples
  (Bonferroni o Benjamini-Hochberg sobre todas a la vez).
- **Juicio**: protege contra el sobreajuste, que es lo importante, pero de
  forma arbitraria. No es motivo para bajar el listón a posteriori.
- **Propuesta**: fijar para lo que venga una regla que no dependa del
  orden (p. ej. Benjamini-Hochberg sobre todas las pruebas registradas) y
  publicar los veredictos de antes con las dos reglas, sin cambiar ninguno.

### R7 · La caja rinde 0 % en el laboratorio de la fase 4 [hipótesis]

- **Supuesto**: la caja no rinde (fase-4/00 §3), «pesimista».
- **Lo público de Quantfury**: la caja en dólares cobra el tipo de la
  Reserva Federal más 0,5 puntos (ver §5; hay que confirmarlo en la app).
- **Efecto**: penaliza justo a las reglas que pasan tiempo en caja frente
  a mantener. Con un ~30 % del tiempo en caja al 4–5 % son del orden de
  +1,3 puntos al año. A `tendencia_clases_broker` (4,8 % frente a 8,3 %)
  probablemente no le basta. Tampoco lo modela el simulador.
- **Propuesta**: repetir la fase 4 con la caja al tipo del broker
  (mirando el pasado, el tipo de cada mes). Es una nueva prueba que va al
  registro.

### R8 · Universo elegido hoy y solo largos [comprobado; ya conocido]

El propio proyecto lo mide (`CRIPTO_TOP_2021`, ETF desde 2000). Sin
cambios: está bien documentado.

---

## 3. Capas 2 y 3: diseño e implementación

### C1 · El motor del laboratorio, sin fuga del futuro [comprobado]

Señal al cierre de t, entrada en la apertura de t+1 con medio spread, el
stop gana el empate, salida por hueco a la apertura, parcial al nivel.
Las estrategias leen `df.iloc[: t + 1]`. En la cartera mensual, la
decisión usa el cierre del mes anterior (`shift(1)`) y se ejecuta en la
apertura del mes. Los precios están ajustados en el laboratorio
(`auto_adjust=True`) y en producción (el valor por defecto de yfinance).

**Falta**: la prueba de mutación (cambiar las velas futuras y comprobar
que las decisiones pasadas no cambian), para no depender de leer código.

### C2 · Los stops de acciones se ejecutan al nivel exacto [comprobado]

- `v_ordenes_abiertas_monitor` usa `activos.ultimo_precio`, que en
  acciones escribe el ETL a :07 y :37.
- `fn_monitorear_ordenes` (0034): si el precio de venta visto ≤ stop y no
  ha cerrado el mercado entre medias, cierra **a `sl`**, no al precio visto.
- **Efecto**: entre dos lecturas, una acción puede caer bastante por debajo
  del stop y el simulador la vende al stop. Es optimista, sobre todo en lo
  volátil (MXL entró con un ATR del 14 %). En cripto el precio se pide
  cada minuto y el efecto es menor. *(24-11, §7 A1: al revés; en cripto
  regala +0,08 R por stop y en acciones +0,02.)*
- **Propuesta**: cerrar a `least(sl, precio de venta visto)`. Cambia el
  simulador del grupo de control, así que va al final del experimento, y
  antes A1 dice si importa.

### C3 · Producción decide con la vela del día a medias [comprobado]

El ETL calcula la señal con la vela diaria en curso. El laboratorio, con
la vela cerrada. Una señal intradía puede aparecer y desaparecer en el
mismo día. Es la razón principal de la concordancia baja (lo reconoce la
cabecera de `concordancia.py`) y refuerza R5.

### C4 · Dos fuentes de cripto [comprobado; efecto, hipótesis]

- Laboratorio: velas de Yahoo, con máximos y mínimos de todo el histórico.
- Producción: cierre de CoinGecko a las 00:00 UTC más el rango de las
  velas de 4 h de los últimos 30 días; antes, sin máximo ni mínimo.
- Quantfury ejecuta a precio de Binance o Coinbase; CoinGecko es un precio
  agregado.
- **Efecto** [comprobado el cálculo; el efecto, hipótesis]: el ADX(14)
  de cripto se calcula solo sobre las ~30 filas con rango real (lo dice
  `tecnicos.py`); con el suavizado de Wilder eso apenas da su primer valor
  y no ha convergido, así que el filtro de Cadencia v2 (ADX ≥ 25) en
  cripto no mide lo mismo que en el laboratorio. El soporte y la
  resistencia (20 velas) y el ATR(14) sí caben.
- **Propuesta**: velas de producción de las klines públicas de Binance
  (gratis, con rango real de todo el histórico). Es otra fuente para el
  grupo de control: al final del experimento.

### C5 · La rotación cierra la que menos R:R le queda [comprobado]

`rr_restante = (tp − precio) / (precio − sl)`: cuanto más cerca del
objetivo, más pequeño. La rotación cierra, por tanto, la posición que va
ganando, con el spread pagado (sí lo paga desde la 0034). Junto con el
objetivo acotado a 2 ATR y la toma parcial, corta a los ganadores, lo
contrario de lo que el laboratorio encontró que paga. A3 dice cuántas
llegaron al objetivo después.

### C6 · El spread de acciones [comprobado]

- Laboratorio: 0,03 $ fijos en todas las acciones; a 50 $ es un 0,06 %, a
  5 $ un 0,6 %.
- Producción: el spread de Nasdaq no se cobra (0041).
- **Efecto**: en Nasdaq producción es más optimista que el laboratorio.
  Quantfury cobra el spread real del exchange, que no es cero.

---

## 4. Lo que hay que mirar en producción

`python scripts/consultar.py -f scripts/auditoria_2026-11-21.sql`, desde
el 17-10.

| Consulta | Qué responde | Si sale mal |
|---|---|---|
| A1 | Cuánto regala el monitor en los stops de sesión, en R | Por encima de ~0,05 R de media, los resultados en vivo son mejores que la realidad |
| A2 | R medio por motivo de cierre y agente | Dónde se pierde: stop, deterioro, rotación o fin |
| A3 | R al rotar y cuántas rotadas llegaron después al objetivo | Si muchas llegan, la rotación cuesta dinero |
| A4 | Apalancamiento real desde la 0055 y cuántas órdenes pasan de 5× | Si las hay, R4 deja de ser teórico |

A3 usaba `precio_max_post_cierre`, que no se rellena en las rotadas; desde
el 24-11 mira las velas diarias posteriores.

---

## 5. Correcciones al marco del 2026-11-21

| Lo que decía el marco | Lo que hay |
|---|---|
| «Calendario NYSE con festivos» como mejora pendiente | Existe: tabla `mercados` con festivos (0031) |
| «Sin financiación» como coste ausente | Según la información pública de Quantfury no hay comisiones ni coste por el apalancamiento, y la caja en dólares cobra intereses. No es un coste que falte; lo que falta es el rendimiento de la caja (R7). Las fuentes consultadas no son su web oficial: confirmarlo en la app |
| Sospecha de que la rotación no pagaba spread | La paga: `rpc_cerrar_orden` aplica el precio de venta a rotación, deterioro y cierre manual (0034) |
| «Unificar el ajuste de precios» | Ya es coherente: ajustados en los dos lados |
| La latencia como causa descartada | Se mantiene |

---

## 6. Propuestas, por orden

| # | Qué | Capa | Cuándo |
|---|---|---|---|
| 1 | Reescribir el objetivo del proyecto con algo medible (R1) | Requisito | Ya [decisión] |
| 2 | Decidir qué pregunta responde el experimento y con cuántas operaciones; si ninguna, cerrarlo antes (R3) | Decisión | Ya [decisión] |
| 3 | Lanzar A1–A4 | Datos | Hecho el 24-11 (§7) |
| 4 | Reconfirmar el tope de 5× con A4 delante (R4) | Requisito | Ya [decisión] |
| 5 | Prueba de mutación anti fuga del futuro en el laboratorio (C1) | Implementación | Ya |
| 6 | Laboratorio: las reglas de los agentes sin objetivo acotado, con stop que sigue al precio y sin rotación (C5) | Diseño | Ya (es de salida, no de entrada) |
| 7 | Fase 4 con la caja al tipo del broker (R7) | Diseño | Ya |
| 8 | Regla frente al azar que no dependa del orden, solo para lo que venga (R6) | Decisión | Ya |
| 9 | Juzgar a los agentes contra su vara y el azar en vivo, no contra el laboratorio (R5) | Decisión | Al final, o antes si se decide 2 |
| 10 | Monitor: cerrar a `least(sl, precio visto)`; velas de cripto de Binance; quitar las metas de la decisión (C2, C4, R2) | Implementación | Al final del experimento |

---

## 7. Resultados en producción (2026-11-24)

> **Método**: `scripts/auditoria_2026-11-21.sql` con `analista_lectura`,
> datos desde el 2026-10-17 (0043) hasta el 24-11 a las 20:00 UTC; A4,
> desde la 0055 (2-11 a las 21:48). Las v2 repiten muchas operaciones de
> su original, así que los recuentos no son independientes.

### A1 · El regalo de los stops: pequeño en acciones, no en cripto

| Clase | Stops en sesión | Regalo medio | En dólares | Riesgo de esos stops |
|---|---|---|---|---|
| Acciones | 11 | +0,021 R | 3,59 $ | 133,68 $ |
| Cripto | 21 | **+0,077 R** | 16,57 $ | 251,19 $ |

- Por agente, en cripto, de +0,066 R (Audacia, Prudencia) a +0,149 R
  (Prudencia v2, 2 stops); el mayor, +0,42 R en un stop de Cadencia.
- **Al revés de lo que suponía el C2**: el efecto está en cripto, no en
  acciones. El monitor tampoco mira cripto cada minuto: las salidas caen a
  :08, :13, :18… cada pocos minutos a media hora, y en 24 horas sin cierre
  la cripto se mueve más entre lecturas.
- Se mide contra el precio intermedio visto. El monitor compara el stop con
  el precio de **venta** (medio spread por debajo), así que el regalo real
  es algo mayor: unas centésimas de R.
- **Juicio**: en cripto, por encima del umbral de ~0,05 R. Con unos 0,08 R
  por stop y 21 de los 37 cierres de cripto a stop, el resultado en
  vivo de cripto es unos 0,04 R por operación mejor que la realidad. No
  cambia ningún veredicto de hoy (todos están por debajo de cero), pero la
  propuesta 10 (`least(sl, precio de venta visto)`) gana respaldo.

### A2 · Dónde se pierde

| Agente | Stop | Deterioro | Objetivo | Rotación |
|---|---|---|---|---|
| Prudencia | 5 · −0,80 | **13 · −0,17** | — | — |
| Prudencia v2 | 2 · −1,00 | 5 · −0,06 | — | — |
| Cadencia | 7 · −1,00 | — | 1 · +1,32 | — |
| Audacia | 12 · −1,09 | — | 3 · +1,61 | 2 · +0,78 |
| Audacia v2 | 7 · −1,00 | — | — | — |
| Tendencia cripto | 1 · −1,00 | — | — | — |

Cierres y R medio sobre el stop inicial, sin contar las tomas parciales
(por eso el BAC de Cadencia cuenta −1,00 y no −0,10). Prudencia pierde sobre
todo por deterioro, poco cada vez; los demás, a su stop, con 4 objetivos en
total. Audacia pasa de −1 R en los stops por los huecos: de los 5 cierres por
hueco desde el 17-10, todos de acciones y a −1,21 R de media, 4 son suyos
y 1 de Audacia v2.

### A3 · Las dos rotadas llegaron después al objetivo

| Orden | Rotada | R al rotar | R del objetivo | Llega al objetivo | Llega al stop |
|---|---|---|---|---|---|
| AGNC #178 (Audacia) | 23-10 | +0,99 | +1,82 | 05-11 | 12-11 |
| NLY #177 (Audacia) | 02-11 | +0,56 | +1,90 | 04-11 | 12-11 |

Las dos tocaron su objetivo antes que su stop: la rotación dejó unos 0,8 y
1,3 R. Con dos casos es una anécdota, no una medida (y con la posición
abierta, el deterioro u otra rotación podrían haberla cerrado antes). Apoya
la propuesta 6 sin probarla.

### A4 · Por encima de 5×: dos órdenes de Audacia

Desde la 0055, el apalancamiento máximo fue de 5,6× (Audacia), 4,3×
(Audacia v2), 3,2× (Cadencia), 3,0× (Prudencia v2) y 2,9× (Prudencia).
Las dos por encima de 5× son de Audacia el 23-11, ripple y solana a 5,6×,
con el equity en 266 $ sobre una base de 500 $. Cada una arriesga 13,28 $,
el 5 % del equity: el riesgo por stop sigue acotado, como decía el R4, pero
**el tope de 5× ya no es teórico**. Reconfirmarlo es la propuesta 4.

### Lo que cambió desde el 21-11

El R3 decía que los filtros de las v2 no habían actuado nunca. El de
Audacia v2 actuó el 18-11: no entró en QFIN (4,80 $), que Audacia cerró a
su stop (revisión del 23-11). El de Cadencia v2 sigue sin actuar.
