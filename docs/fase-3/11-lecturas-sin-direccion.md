# Lecturas «sin dirección»: el caso de O (2026-11-04)

> **Pregunta del dueño**: Realty Income (O) ha subido casi un 10 % y el
> escáner dice «Sin dirección clara: ni comprar ni vender». ¿Se nos escapa
> algo?
>
> **Datos**: producción (`senales`, `senales_vigentes`) del 2026-09-21 al
> 2026-11-04, con la regla de confluencia vigente desde la 0030 (el RSI
> extremo no vota contra el MACD, 2026-10-10); y velas diarias ajustadas de
> Yahoo del 2016-11 al 2026-11 para la medición de 10 años.

## 1. Qué pasa con O

**Los datos y el cálculo están bien.** La última lectura (2026-11-04
20:58 UTC) da 59,29 $, el mismo cierre que Yahoo, y los indicadores
coinciden con los recalculados aparte:

| Indicador | Valor | Voto |
|---|---|---|
| Medias 50 / 200 | 56,81 / 60,19 | **bajista** (la de 50 bajo la de 200) |
| MACD (histograma) | +0,43 | **alcista** |
| RSI 14 | 67,9 | ninguno (vota por debajo de 30 o por encima de 70) |
| Volumen relativo | 1,28× | ninguno (confirma desde 1,5×) |

Un voto a cada lado: **empate**, y el empate es «sin dirección». Lleva así
todos los días desde el 2026-10-21 (de 56,03 a 59,29 $ en producción).

**La subida, medida con precios ajustados por dividendos**: +5,8 % en 5
sesiones, +7,5 % en 10 y +9,7 % en un mes. Es un rebote dentro de una
caída: O ha bajado de 65 a 53 $ en el último año y sigue por debajo de su
media de 200 sesiones (60,19 $). Para que el escáner lo cuente como
alcista, la media de 50 tiene que cruzar la de 200, y eso llega meses
después del giro.

## 2. Lo que sí se escapa: dos de cada tres lecturas son un empate

En la lectura vigente del 2026-11-04, **31 de los 48 activos** (21 acciones
y 10 criptos) están en el mismo empate 1 a 1 entre las medias y el MACD.
En las acciones, 14 como O (rebote con fondo bajista) y 7 al revés
(retroceso con fondo alcista); en cripto, 9 de las 10 al revés.

| Semana | Lecturas sin dirección | Alcistas | Lecturas |
|---|---|---|---|
| 2026-09-21 | 37 % | 47 % | 148 |
| 2026-09-28 | 58 % | 30 % | 577 |
| 2026-10-05 | 58 % | 35 % | 3.900 |
| 2026-10-12 | 68 % | 22 % | 4.762 |
| 2026-10-19 | 69 % | 19 % | 4.449 |
| 2026-10-26 | 67 % | 24 % | 4.851 |
| 2026-11-02 | 66 % | 21 % | 2.472 |

El salto de la semana del 12-10 coincide con la 0030: desde entonces un
RSI extremo ya no vota contra el MACD, así que en la práctica solo votan
dos indicadores y empatan a menudo. No es un fallo: es lo que hace la
regla.

## 3. ¿Esos empates esconden oportunidades? Medición a 10 años

Se reprodujeron día a día los votos de `evaluar_confluencia` y se midió el
rendimiento de las **20 sesiones siguientes**, sin costes. «Exceso» es lo
que da cada lectura por encima de la media de la propia acción (quita que
unas acciones suban más que otras). Los días se solapan: no son
observaciones independientes, así que esto describe, no valida.

**S&P 100 (101 acciones, 2017-08 → 2026-10)**:

| Lectura | Días | A 20 sesiones | Exceso | Suben |
|---|---|---|---|---|
| Sin dirección: medias alcistas, MACD bajista | 35 % | +1,36 % | −0,02 | 57 % |
| Alcista 2-0 | 28 % | +0,99 % | −0,40 | 56 % |
| **Sin dirección: medias bajistas, MACD alcista (O hoy)** | 20 % | **+1,66 %** | **+0,39** | 58 % |
| Bajista 0-2 | 12 % | +1,63 % | +0,35 | 59 % |
| Alcista 3-0 | 2 % | +1,36 % | −0,14 | 57 % |
| Todos los días | | +1,35 % | | |

**Las 31 acciones activas de producción** (2017-08 → 2026-10) dan lo
mismo: alcista 2-0, +0,97 % (exceso −0,34); como O, +1,50 % (+0,50);
bajista 0-2, +1,50 % (+0,51).

Lo que dice:

- **La dirección del escáner no anticipa las 20 sesiones siguientes.** Una
  lectura alcista rinde algo **menos** que la media de la acción, y una
  bajista algo más. Encaja con el laboratorio: la estrategia `actual` se
  quedó en +0,14 R con el intervalo incluyendo el cero (doc fase-2/06).
- **El estado de O no es peor que el «alcista», sino algo mejor**: unas
  4 o 5 décimas por encima de la media de la acción en 20 sesiones. Es
  poco frente a lo que se mueve una acción en un mes, antes de costes, y
  con días solapados. No es una ventaja validada; sería la hipótesis para
  una prueba en el laboratorio.
- Lo que se escapa, por tanto, no es O en concreto. Es que la etiqueta
  «sin dirección» cubre dos situaciones distintas, y el escáner no decía
  cuál era.

## 4. Qué cambia

- **El escáner explica el empate** (`frontend/src/datos/veredicto.js`,
  `motivoSinDireccion`). Para O: «Empate: el precio rebota (MACD
  alcista), pero la tendencia de fondo sigue bajista (media de 50 bajo la
  de 200)…». Para el caso contrario, que la tendencia de fondo es alcista
  y el impulso se ha girado a la baja.
- **No se toca la confluencia del motor.** Decide qué toman Prudencia,
  Cadencia y Audacia, que son el grupo de control y no se cambian a mano
  mientras dure el experimento.

## 5. Qué queda

- **Prueba en el laboratorio: comprar el rebote con fondo bajista**
  (medias 50/200 bajistas y MACD que se gira al alza), fijada de antemano
  y contra su azar, con 10 años de velas diarias. Es la sexta prueba de
  esta tanda, así que el percentil exigido sería el 95. La medición del §3
  apunta más a una reversión a un mes que a una tendencia: las lecturas
  bajistas también rinden por encima de la media.

## 6. La prueba: comprar el rebote con fondo bajista (2026-11-04)

> **Fijada antes de mirar los datos** (este apartado se escribió y se
> guardó en un commit antes de ejecutar la prueba).

**Qué se prueba**: `rebote_fondo_bajista`. Al cierre del día en que el
histograma del MACD pasa a positivo con la media de 50 por debajo de la de
200 (el momento en que una acción entra en el estado de O), compra en la
apertura siguiente. Stop a 1,5 o 3 ATR del cierre, sin objetivo, salida a
las 10 o 20 sesiones: cuatro combinaciones, elegidas en el diseño.

**Dónde**: el S&P 100 con velas diarias de 10 años (`laboratorio/intradia.py`,
con el mismo método de la fase-3/10), spread de 0,03 $.

**Referencia**: 100 tiradas de largos un día cualquiera **con la media de
50 bajo la de 200**, sin esperar al giro, con el mismo stop y la misma
salida. En acciones que hoy siguen en el S&P 100, comprar en una caída ya
tiende a salir bien (sesgo de supervivencia), así que lo que se mide es si
el giro del MACD aporta algo sobre eso.

**Criterio** (el del laboratorio, sin cambios): en validación (el 30 %
final), ≥ 30 operaciones, > +0,10 R, IC 90 % por encima de cero, factor de
beneficio > 1,2 y al menos un tercio del diseño; y superar al azar en al
menos el **95 %** de las tiradas (sexta prueba del modo).

### Resultado: gana, pero lo mismo que comprar cualquier día de una caída

101 acciones, del **2016-11-07 al 2026-11-04**; diseño hasta el 2023-11-05.

| | Ops | Neto | IC 90 % |
|---|---|---|---|
| Diseño, mejor combinación (stop a 1,5 ATR, 20 sesiones) | 1.840 | +0,244 R | +0,178 – +0,309 |
| **Validación** | 837 | **+0,327 R** | +0,216 – +0,445 |
| Largos al azar en caídas (validación, 100 tiradas) | 651 | **+0,331 R** (mediana) | p5 – p95: +0,239 – +0,452 |

- **Por sí sola pasaría el criterio**: +0,33 R en validación, IC 90 % por
  encima de cero (también remuestreando meses: +0,09 – +0,57), factor de
  beneficio 1,54, y las cuatro combinaciones ganan en los dos tramos.
- **Pero no supera al azar**: percentil 47 (mínimo 95). Comprar **cualquier
  día** con la media de 50 bajo la de 200 da lo mismo, +0,33 R. El giro del
  MACD no aporta nada.
- **Lo que gana es comprar caídas en acciones que hoy están en el S&P 100.**
  Son las que se recuperaron: las que cayeron y no volvieron ya no están en
  la lista. Es el sesgo de supervivencia, y no se puede operar, porque no
  se sabe de antemano qué acción en caída va a seguir en el índice.

**Conclusión**: en el estado de O no se escapa una ventaja. Y queda una
lección para el laboratorio: en el S&P 100 o en las medianas de hoy, una
estrategia que compra caídas siempre se juzga contra largos al azar **en
caídas**, nunca solo contra el cero. Para saber si comprar caídas funciona
de verdad hace falta un universo sin sesgo de supervivencia (por ejemplo,
los ETF del laboratorio). Es la prueba del §7.

## 7. La prueba: comprar caídas en los ETF (2026-11-05)

> **Fijada antes de mirar los datos** (este apartado se escribió y se
> guardó en un commit antes de ejecutar la prueba).

**Pregunta**: el §6 dejó claro que en el S&P 100 de hoy comprar cualquier
día de una caída gana (+0,33 R), pero no se sabe si por la caída o por
el sesgo de supervivencia. En un universo sin ese sesgo, ¿comprar en una
caída rinde más que comprar un día cualquiera?

**Qué se prueba**: `caida_etf`. Al cierre de cualquier día con la media de
50 por debajo de la de 200, si no hay posición abierta en ese ETF, compra
en la apertura siguiente. Stop a 1,5 o 3 ATR del cierre, sin objetivo,
salida a las 10 o 20 sesiones: las mismas cuatro combinaciones del §6,
elegidas en el diseño. Sin esperar al giro del MACD: lo que se mide es la
caída misma.

**Dónde**: los 19 ETF del laboratorio (`--universo etf`: 9 de sectores de
SPDR y 10 de países de iShares, todos de 1996–2000, doc fase-2/06 §3.11),
con **todo el histórico** de velas diarias de Yahoo, que cubre 2000–2002 y
2008. Mismo método (`laboratorio/intradia.py`, doc fase-3/10), spread de
0,03 $.

**Referencia**: 100 tiradas de largos **un día cualquiera**, haya caída o
no, con el mismo stop y la misma salida. Las dos mantienen las posiciones
el mismo tiempo, así que la R por operación es comparable (fase-2/06 §3.11,
conclusión 4).

**Criterio** (el del laboratorio, sin cambios): en validación (el 30 %
final), ≥ 30 operaciones, > +0,10 R, IC 90 % por encima de cero, factor de
beneficio > 1,2 y al menos un tercio del diseño; y superar al azar en al
menos el **96 %** de las tiradas (séptima prueba del modo).

**Qué se haría con el resultado**: nada en los agentes ni en el escáner
mientras dure el experimento. Si pasa, la regla «solo comprar en
tendencia alcista» que implica la confluencia quedaría en duda y se
guardaría para el final del experimento. Si no pasa, comprar caídas queda
descartado como ventaja en sí, también en las acciones.

### Resultado: pasa el criterio, pero solo en los últimos nueve años

19 ETF, del **1996-03-18 al 2026-11-04**; diseño hasta el 2017-08-26,
validación desde ahí. Elegida en el diseño: stop a 3 ATR, 20 sesiones.

| | Ops | Neto | IC 90 % |
|---|---|---|---|
| Diseño (1996–2017) | 1.885 | +0,017 R | −0,022 – +0,055 |
| **Validación (2017–2026)** | 789 | **+0,158 R** | +0,094 – +0,228 |
| Largos un día cualquiera (validación, 100 tiradas) | 855 | +0,096 R (mediana) | p5 – p95: +0,049 – +0,156 |

- **Pasa el criterio fijado**: +0,158 R en validación, IC 90 % por encima de
  cero (remuestreando meses, +0,007 – +0,312), factor de beneficio 1,41,
  y supera al **96 %** de las tiradas (mínimo 96). Las cuatro
  combinaciones ganan en validación.
- **Pero en el diseño no**: de 1996 a 2017 comprar en una caída dio
  +0,017 R, por **debajo** de comprar un día cualquiera (+0,050 R de
  mediana; percentil **4** frente al azar). En esos años, que incluyen
  2000–2002 y 2008, las caídas siguieron cayendo. La ventaja aparece solo
  en el tramo de validación.

Comprobaciones aparte, descriptivas (no cambian el veredicto):

- **Otras 100 semillas del azar**: percentil 98 (con las 200 juntas, 97).
  No es la suerte de las tiradas.
- **No depende de un año**: sin 2020 ni 2022, +0,185 R frente a +0,128 R
  del azar. Por años de validación, gana al azar en 7 de 10 (2019 por muy
  poco) y pierde en 2017 (7 operaciones), 2021 y 2024.
- **No depende de un ETF**: gana en 16 de los 19; los que más aportan son
  EWZ, XLV, XLP y XLI, y pierden EWJ, EWH y EWY.

**Conclusión**: en un universo sin sesgo de supervivencia, comprar en una
caída ha rendido más que comprar un día cualquiera **desde 2017**, y ha
pasado el criterio fijado. No es una ventaja estable: en los 21 años
anteriores rindió menos que el azar. Lo que hay es un cambio de régimen
(desde 2017 las caídas se han recuperado más deprisa) o una casualidad
del tramo, y con estos datos no se puede distinguir entre los dos.

Lo que se hace, como se fijó antes de ejecutarla:

- **Nada en los agentes ni en el escáner** mientras dure el experimento.
- **Se guarda para el final**: la regla implícita de la confluencia,
  «solo comprar con la tendencia de fondo alcista», queda en duda en los
  ETF desde 2017. En las acciones del S&P 100 no se puede saber, por el
  sesgo de supervivencia (§6).
- **Lección para el criterio**: el veredicto del laboratorio pide que la
  validación sea al menos un tercio del diseño, pero no mira si en el
  diseño ya superaba al azar. Aquí no lo superaba. Si se cambia, será
  para las pruebas siguientes y fijado antes: no se aplica a esta.
