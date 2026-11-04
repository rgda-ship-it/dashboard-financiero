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

### Resultado

*(pendiente)*
