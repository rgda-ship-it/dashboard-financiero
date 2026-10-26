# F. Laboratorio de estrategias y agentes con ventaja

> **Vigencia (revisada el 2026-10-27)**: **Vigente.** El método del laboratorio y el criterio de ventaja (superar al azar) siguen siendo los de hoy.

> **Autor**: Analista Cuantitativo / Risk Manager (equipo virtual)
> **Fecha**: 2026-10-11
> **Estado**: **Aprobada por el dueño** y ejecutada. Laboratorio, primera
> ronda y prueba de robustez hechos (§3.7). Resultado: un agente
> experimental, «Tendencia cripto» (D24, doc 07). Pendientes en
> [`../ESTADO.md`](../ESTADO.md) §3.2.
> **Contexto**: doc 05 y la conclusión del dueño tras D21–D23: las
> correcciones hacen el sistema más honesto, pero no lo acercan a sus metas.

---

## 1. El diagnóstico, en dos frases

1. **Las metas diarias son inalcanzables de forma sostenida**: 2 % al día
   compuesto son × 147 al año; 5 %, × 220.000; 7 %, × 26 millones. Los
   mejores fondos ganan un 20–30 % anual. Perseguirlas a cualquier precio
   empuja a concentrar riesgo y acelera la ruina.
2. **No sabemos si las señales tienen ventaja, y lo poco medido dice que
   no**: 71 de 96 decisiones de entrada resueltas, negativas. Sin
   expectativa positiva después de costes, ninguna mejora de tamaño,
   tiempo o prudencia gana: solo cambia la velocidad de la pérdida.

Y hoy cada idea se prueba en vivo, a un ciclo cada 5 minutos: semanas por
idea, con muestras (3 operaciones por práctica) que no prueban nada.

---

## 2. La decisión del dueño

- **Los tres agentes actuales siguen como están**, persiguiendo sus metas:
  son el **grupo de control**.
- **Agentes nuevos**, uno por cada estrategia que **demuestre ventaja en el
  laboratorio**, con otro objetivo: maximizar la ganancia esperada después
  de costes con un límite de riesgo. Mismo simulador, mismo spread, mismos
  huecos, mismos guardarraíles, mismo saldo inicial de 500 $: la
  comparación es limpia.
- Ninguna estrategia sin ventaja demostrada recibe un agente.

---

## 3. El laboratorio

### 3.1 Qué hace

Reproduce el histórico **día a día, sin mirar el futuro**, con las mismas
reglas de ejecución que el simulador:

| Regla | En el laboratorio |
|---|---|
| Señal | Con los datos **hasta el cierre del día t**; se entra en la apertura de t + 1 |
| Precio de entrada | Apertura de t + 1 **más medio spread** (D23) |
| Stop y objetivo | Se comprueban con el máximo y el mínimo de cada día siguiente, al **precio de venta** |
| Mismo día toca stop y objetivo | Gana el stop (M2, lado conservador) |
| Hueco de apertura más allá del stop | Sale a la apertura, no al stop (M3') |
| Spread | Los valores de la 0034: 0,03 $ por acción, BTC 5 $, ETH 0,10 $, resto de cripto 0,10 % |

### 3.2 Datos

- **Acciones**: velas diarias de Yahoo, los últimos años disponibles.
- **Cripto**: velas diarias de Yahoo (`BTC-USD`, `ETH-USD`…), que traen
  máximo y mínimo para todo el histórico (CoinGecko gratis solo da 30 días
  de máximos y mínimos).
- **Universo**: el catálogo activo de producción (si el laboratorio tiene
  acceso a la base de datos) o una lista dada.

### 3.3 Dónde corre

En **GitHub Actions** (`laboratorio.yml`), lanzado a mano: tiene acceso a
Yahoo y a la base de datos. El informe sale en el resumen del job y las
operaciones en un CSV descargable. Claude puede lanzarlo y leer el
resultado.

### 3.4 Qué mide

Por estrategia, por clase de activo y en total:

| Medida | Para qué |
|---|---|
| Operaciones | Sin muestra no hay conclusión |
| % de aciertos, ganancia y pérdida media | Forma de la estrategia |
| **Expectativa por operación**, en R (múltiplos del riesgo) y en % | **La medida central**: ¿gana dinero cada operación, de media, después de costes? |
| Factor de beneficio | Ganado ÷ perdido |
| Caída máxima | Con un riesgo fijo del 1 % por operación |
| Días medios por operación | Horizonte real |
| **t de la expectativa** e intervalo por bootstrap | ¿Es ventaja o suerte? |

### 3.5 Cuándo una estrategia «tiene ventaja»

Se divide el histórico: **70 % para diseñar, 30 % final para validar**,
sin tocar la estrategia entre medias. Pasa si, **en el tramo de
validación**:

1. al menos **30 operaciones**;
2. **expectativa > 0,10 R** después de spread;
3. el **intervalo de confianza del 90 %** de la expectativa **por encima de
   cero**;
4. factor de beneficio > 1,2;
5. y en el tramo de diseño no era peor que en el de validación por un
   margen enorme (señal de que se ajustó al ruido).

Son exigentes a propósito: es preferible no tener agente a tener uno que
pierde con buena cara.

### 3.6 Las estrategias de la primera ronda

| Estrategia | Mercado | Entrada | Salida |
|---|---|---|---|
| **Actual** | Ambos | La de hoy: confluencia alcista media/alta, niveles acotados en ATR (D21) | Stop o objetivo |
| **Tendencia** | Cripto (y acciones, para comparar) | Cierre por encima del máximo de 20 días, con el precio sobre su media de 200 | Stop inicial a 2 ATR, que sube con el precio (3 ATR bajo el mejor cierre); o cierre bajo el mínimo de 10 días |
| **Reversión** | Acciones (y cripto, para comparar) | RSI de 2 días < 10 con el precio sobre su media de 200 | Cierre por encima de su media de 5 días, o a los 5 días; stop a 3 ATR |

La «Actual» es la referencia: dice cuánto vale lo que ya tenemos.

### 3.7 Primera ronda y prueba de robustez

Resultado de la primera ronda (5 años, 43 activos): solo **tendencia en
cripto** pasa el §3.5 (validación: 79 operaciones, +0,69 R, IC 90 %
[+0,06, +1,44], factor 2,39, sin desplome frente al diseño). Ninguna pasa en
acciones; la actual queda en +0,14 R con el intervalo incluyendo el cero.

Un aprobado justo puede ser suerte, así que antes de crear un agente se
somete a una prueba de robustez (`laboratorio/robustez.py`, modo
`robustez` del workflow):

1. **Correlación**: intervalo remuestreando meses enteros, no operaciones.
2. **Concentración por activo**: R de cada uno y veredicto quitando los 1,
   2 y 3 mejores.
3. **Concentración por año.**
4. **Parámetros**: rejilla de variantes (en tendencia, ruptura 10–55 días,
   stop que sigue a 2,5–4 ATR y stop inicial a 1,5–3 ATR); una ventaja real
   aparece en la mayoría, no solo en la elegida.
5. **Costes**: spread tres veces peor.
6. **Supervivencia**: las criptos del top de octubre de 2021 que no están en
   el universo, incluidas las que se hundieron (Terra, FTX…); para la
   estrategia son datos nunca vistos.

Se crea el agente si la referencia sigue en pie con el intervalo por meses,
no depende de un activo, la mayoría de variantes tiene expectativa positiva
y en el universo de 2021 la expectativa es positiva.

**Resultado (2026-10-11)**: cumple 3 de 4.

| Prueba | Resultado |
|---|---|
| Intervalo por meses | [+0,02, +1,49] R ✅ |
| Concentración por activo | ❌ zcash da ~46 de los ~54 R de la validación; sin ella, +0,13 R con el intervalo incluyendo el cero. 13 de 14 criptos con expectativa positiva |
| Concentración por año | 2024 aporta 169 de 216 R; 2022, −7 R con solo 10 operaciones (el filtro de la media de 200 la mantuvo fuera) |
| Parámetros | 45 de 45 variantes positivas en validación; 18 pasan el criterio completo, todas con ruptura ≥ 20 días ✅ |
| Spread × 3 | +0,63 R, intervalo [−0,02, +1,43] |
| Criptos del top de 2021 | +0,65 R en 5 años ✅; +0,09 R en el tramo de validación |

Lectura: ventaja real pero no demostrada, con forma de «pocas ganancias
enormes».

**Con 10 años de histórico (2026-10-11)**, validación desde 2023-10, tres años:

| Estrategia | Acciones (validación) | Cripto (validación) |
|---|---|---|
| Actual | +0,13 R, IC [−0,04, +0,30] ❌ | −0,11 R ❌ |
| **Tendencia** | +0,12 R, IC [−0,03, +0,29], factor 1,24 ❌ (por poco; en diseño +0,17 R con IC > 0) | **+1,09 R, IC [+0,57, +1,70], 203 operaciones, factor 3,11 ✅** |
| Reversión | +0,01 R ❌ | +0,01 R ❌ |

Tendencia en cripto sale reforzada: más operaciones y un intervalo muy por
encima de cero. Ojo: el universo cripto se eligió hoy, así que a 10 años el
sesgo de supervivencia pesa más que a 5 (solana o avalanche no existían en
2016). En acciones, tendencia ronda +0,12–0,17 R de forma estable, pero no
llega al criterio: sigue sin agente. El dueño eligió la opción A, un **agente experimental** con
criterio de retirada fijado de antemano (D24, doc 07), en lugar de seguir
solo en el laboratorio.

### 3.8 Segunda ronda: las estrategias del manual

El dueño aportó un «Manual práctico de estrategias de trading» (2026-10-11)
con cinco estrategias. Así se tradujeron:

| Del manual | En el laboratorio | Qué pregunta responde |
|---|---|---|
| §2.2 Rupturas | Ya era **tendencia** (la de Tendencia cripto) | — |
| §2.2 Ruptura con volumen | **ruptura_volumen**: tendencia, solo si el volumen del día supera 1,5 × su media de 20 | ¿El filtro mejora la ruptura o solo le quita operaciones? |
| §2.2 y §3.4 Objetivo fijado de antemano | **ruptura_2r**: la misma ruptura, con objetivo a 2R y el stop quieto | ¿Fijar el objetivo, como aconseja el manual, es mejor o peor que el stop que sigue sin objetivo? |
| §2.1 y §3 Swing con retroceso | **retroceso**, en velas diarias (el manual usa 4 h): <br>• contexto: cierre sobre la media de 50, que sube, y media de 20 sobre la de 50; <br>• retroceso que toca la media de 20; <br>• entrada cuando el cierre supera el máximo de ayer; <br>• stop bajo el mínimo de 5 días y objetivo a 2R; <br>• sale si cierra bajo la media de 50 | ¿Comprar el retroceso es mejor que comprar la ruptura? |
| §2.3 Reversión con contexto | **reversion_bollinger**: <br>• solo con ADX 14 < 20 (mercado lateral); <br>• ayer cerró bajo la banda inferior y hoy dentro (rechazo del extremo); <br>• objetivo en la media; <br>• salida a los 10 días | ¿Le faltaba a «reversion» el contexto y la confirmación? |
| §2.4 Intradía con VWAP | No se prueba | Necesita velas de minutos con volumen, y no hay histórico suficiente. El agente no decide a esa velocidad, y el spread se come el recorrido intradía |
| §2.5 Derivados (funding, interés abierto) | No se prueba ahora | Necesita una fuente de datos nueva, y QuantFury no opera perpetuos. Queda como posible filtro de Tendencia cripto más adelante |

Métricas nuevas que pide el manual (§7.4), en todas las estrategias:
- la peor racha de pérdidas seguidas;
- los costes (spread) como porcentaje del beneficio bruto;
- la expectativa en validación según el régimen al dar la señal (ADX 14 ≥ 25 = tendencia; si no, rango).

**Resultado (10 años, validación desde 2023-10)**:

| Estrategia | Acciones | Cripto |
|---|---|---|
| tendencia | +0,11 R ❌ | +1,09 R ✅ |
| **ruptura_volumen** | **+0,29 R, IC [+0,04, +0,57], 175 ops, factor 1,60 ✅** | +1,13 R ✅ |
| ruptura_2r | +0,10 R ❌ | +0,30 R ✅ |
| retroceso | +0,01 R ❌ | +0,28 R ✅ |
| reversion_bollinger | −0,13 R ❌ | +0,09 R ❌ |

Lecturas:
- **El volumen es lo que le faltaba a la ruptura en acciones.** Es la primera candidata en acciones.
- **Fijar el objetivo a 2R (consejo del manual) hunde la ruptura en cripto**: pasa de +1,09 R a +0,30 R. Confirma el stop que sigue sin objetivo.
- **En cripto, el volumen no mejora a tendencia**: +1,13 R frente a +1,09 R, con menos operaciones. Tendencia cripto no se toca.
- **La reversión falla también con el contexto del manual.**
- **Régimen**: las rupturas rinden más cuando la señal llega con ADX bajo (en ruptura_volumen, +0,89 R frente a +0,34 R). Romper una consolidación da más recorrido que sumarse a una tendencia ya extendida.
- **Costes**: entre el 1 % y el 5 % del beneficio bruto en las estrategias lentas, y entre el 7 % y el 12 % en las reversiones.

**Robustez de ruptura_volumen en acciones** (10 años; [informe](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38163452436)):

| Prueba | Resultado |
|---|---|
| Intervalo por meses | [+0,02, +0,57] ✅ |
| Concentración por activo | Sin TSLA, sigue pasando ✅ (+0,27 R); sin TSLA y NVDA, el intervalo incluye el cero. **Solo 12 de 29 acciones con expectativa positiva**: gana en las de crecimiento o *momentum* (TSLA, NVDA, PBR, QFIN, AAPL…) y pierde en las defensivas (AMCR, O, HRL, KMB, CLX…) |
| Por año | 6 de 10 años positivos; alterna |
| Parámetros | 9 de 9 positivas y 5 de 9 pasan ✅ (el volumen a 2× deja pocas operaciones) |
| Spread × 3 | ✅ +0,26 R |
| Supervivencia | No se puede medir igual que en cripto. El universo de acciones también se eligió hoy |

Lectura: **pasa los criterios formales, pero con márgenes justos y poca amplitud**.
Gana en un subconjunto de acciones, lo que puede ser una ventaja real (las
rupturas funcionan en valores con tendencia) o una selección afortunada.

**Advertencia de método** (el mismo manual, §7.2, «selección oportunista»):
con siete estrategias, alguna puede pasar por suerte. Una ganadora nueva no
recibe agente sin superar antes la prueba de robustez (§3.7).

### 3.9 Amplitud en acciones: el S&P 100

Para decidir si `ruptura_volumen` en acciones es una ventaja real o una
selección afortunada de 29 valores, se prueba en el S&P 100 (`--universo
sp100`, 102 valores con su sector). El informe añade la expectativa por
sector y cuántos valores ganan.

El sesgo de supervivencia sigue ahí, porque es la composición de hoy. Lo
que mide es la amplitud de la ventaja.

### 3.10 Referencia al azar: ¿señal o viento a favor?

**azar** usa las mismas salidas y el mismo filtro de fondo que tendencia,
pero entra en días al azar (un 5 %). Responde a una pregunta que el
criterio del §3.5 no hace: si comprar **cualquier** día de tendencia
alcista, con un buen stop, ya «tiene ventaja», lo que gana no es la señal.
Una estrategia solo aporta si supera claramente a su referencia al azar
en el mismo universo.

**Resultado (10 años, validación desde 2023-10; [S&P 100](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38166123443), [universo propio](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38165652250))**:

| Universo | azar | tendencia | ruptura_volumen |
|---|---|---|---|
| S&P 100 (102 acciones) | **+0,28 R** [+0,21, +0,36] | +0,26 R | +0,27 R [+0,16, +0,39] |
| Acciones propias (29) | +0,07 R ❌ | +0,12 R ❌ | +0,29 R |
| Cripto (14) | **+0,65 R** [+0,25, +1,14] | +1,09 R [+0,57, +1,70] | +1,13 R |

**Conclusiones**:
1. **En acciones, la señal de ruptura no aporta nada.** En el universo
   amplio, entrar en días al azar rinde lo mismo que la ruptura, con o sin
   volumen. Lo que «gana» es estar comprado en acciones que suben, con un
   stop que sigue al precio, en una década alcista y con el S&P 100 de hoy,
   que son las supervivientes. La ventaja de ruptura_volumen en nuestras 29
   acciones (+0,29 frente a +0,07 R) no se reproduce con 102 acciones: muy
   probablemente fue suerte de un universo pequeño. Su robustez en el
   S&P 100 (9 de 9 variantes, 64 de 101 valores, sin los 3 mejores sigue
   pasando) era real, pero medía ese viento a favor, no la señal.
   **No se crea agente de acciones.**
2. **En cripto, la mayor parte de la ventaja de Tendencia tampoco es la
   señal.** El sistema de salidas, con el filtro de la media de 200, el stop
   que sigue y ningún objetivo, ya da +0,65 R entrando al azar. La ruptura
   añade unos +0,45 R, pero los intervalos se solapan, así que esa parte no
   está demostrada. El agente Tendencia cripto sigue: lo que se prueba en
   vivo es el sistema completo, y la parte más sólida de ese sistema son
   justo sus salidas.
3. **Lo que de verdad funciona en todo lo probado es la forma de salir**:
   cortar las pérdidas con un stop, dejar correr las ganancias con un stop
   que sube y no fijar objetivo. Es justo lo contrario de lo que hacían
   los agentes con metas, con objetivo cercano y stop fijo.
4. **Nuevo requisito del criterio (§3.5)**: una estrategia tiene ventaja de
   señal solo si, en validación, supera a su referencia al azar en el mismo
   universo y con intervalos que no se solapen. Sin eso, lo que mide es el
   mercado.

### 3.11 Momento relativo: ¿elegir las más fuertes aporta algo?

La referencia al azar del §3.10 deja una sola vía para tener ventaja de
señal en acciones: que importe **qué** acción se elige frente a las
demás, no **cuándo** se entra. Es el momento relativo, la anomalía más
documentada en los estudios académicos.

**Las estrategias** (`estrategias.py`):
- **momento**: el primer día de bolsa de cada mes clasifica el universo de
  su clase por la rentabilidad de 12 meses sin el último (12-1). Entra en
  las `top` primeras y las mantiene mientras sigan entre las `mantener`
  primeras (el doble). Stop de catástrofe fijo a 5 ATR, sin objetivo: la
  salida normal es la rotación.
- **azar_momento**: las mismas reglas, pero con una clasificación al azar
  entre los mismos activos. Tiene semilla, porque una sola tirada es muy
  ruidosa.

Son estrategias **cruzadas**: la clasificación de un activo depende de los
demás. Se calcula antes, para todos a la vez y de forma causal
(`anadir_rangos`), y llega al motor como una columna.

**Dos problemas de medida, y sus arreglos**:
1. **La R por operación no sirve aquí.** El momento mantiene cada posición
   de 3 a 4 veces más tiempo que su azar (90–170 sesiones frente a 23–47),
   y la R crece con el tiempo en cartera. Por eso da +0,68 R frente a
   +0,17 R en el S&P 100 aunque elija casi igual. La medida justa es el
   **rendimiento por mes en cartera** (columna «% / mes», nueva en todos
   los informes).
2. **Una sola tirada del azar no sirve de vara.** En el S&P 100, la
   validación de `azar_momento` va de +0,06 a +1,28 % al mes según la
   semilla. El modo nuevo **`contra_azar`** compara la estrategia con 30
   tiradas, y exige superar al 90 % de ellas en validación.

**El universo sin sesgo de supervivencia**: `--universo etf`, con los 9 ETF
de sectores de SPDR y 10 ETF de países de iShares, todos de 1996–2000.
Se pueden elegir con la información de entonces, y el histórico cubre
2000–2002 y 2008. En el S&P 100 de hoy, el momento sale favorecido justo
por el sesgo: PLTR, que entró en el índice por haber subido, explica la
mitad de la R de validación.

**Resultado** (rendimiento por mes en cartera; percentil frente a 30
tiradas al azar). [ETF, 4 primeras, en CI](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/38383102154);
el resto, en local con el mismo código:

| Universo | top | Diseño: momento / azar (mediana) | Supera | Validación: momento / azar (mediana) | Supera |
|---|---|---|---|---|---|
| ETF (19, desde 1996) | **4** | +0,62 / +0,25 % | 100 % | +0,65 / +0,73 % | **33 %** ❌ |
| ETF | 2 | +0,44 / +0,15 % | 90 % | +1,12 / +0,73 % | 93 % |
| S&P 100 (sesgado) | **10** | +1,14 / +0,87 % | 90 % | +1,54 / +1,20 % | **73 %** ❌ |
| S&P 100 | 5 | +2,07 / +0,79 % | 100 % | +2,44 / +1,20 % | 93 % |
| Acciones propias (29) | **10** | +0,21 / +0,27 % | **37 %** ❌ | +1,31 / −0,10 % | 100 % |

En negrita, la configuración fijada de antemano.

**Conclusiones**:
1. **La configuración fijada de antemano no aporta selección en ningún
   universo.** En cada uno falla en uno de los dos tramos, y en los ETF,
   el único universo sin sesgo, la validación queda por debajo de la
   mediana del azar.
2. **Las carteras concentradas (las 2 o las 5 mejores) pasan en los dos
   tramos**, pero se han elegido después de ver los resultados. Con cinco
   configuraciones probadas y un listón del 90 %, que alguna pase por
   suerte es lo esperable. Es una hipótesis, no un resultado.
3. **No se crea agente de acciones.** Si se quiere seguir, la variante
   concentrada se fija ahora (ETF, 2 primeras, 12-1, stop a 5 ATR) y se
   juzga con datos que todavía no existen: en vivo, o con el histórico que
   se vaya acumulando. Sería el mismo criterio que el de Tendencia cripto.
4. **Para toda estrategia que mantenga las posiciones durante tiempos
   distintos de su referencia**, el criterio del §3.5 se aplica con el
   rendimiento por mes en cartera y contra la distribución de tiradas, no
   con la R por operación ni con una sola tirada.

---

## 4. Lo que viene después

1. **Laboratorio** con las tres estrategias. ✅ Hecho, con la prueba de robustez (§3.7).
2. **Un agente por cada estrategia que pase** el §3.5 (el primero, experimental: «Tendencia cripto», doc 07), de un tipo nuevo:
   comparte simulador, monitor, spread y guardarraíles, pero decide con su
   propia función (ganancia esperada con límite de riesgo, tamaño según la
   ventaja medida) y sin meta diaria que perseguir.
3. **Panel comparativo**: agentes nuevos frente a agentes con metas, con
   las mismas medidas. ✅ Hecho en la 0040 (`v_comparativa_agentes`).
4. Más adelante, un **agente de cartera** que combine las estrategias con
   ventaja y reparta el riesgo entre ellas.
