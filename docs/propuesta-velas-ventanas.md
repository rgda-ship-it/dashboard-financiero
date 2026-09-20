# Propuesta: velas y ventanas históricas coherentes entre acciones y cripto

**Autor:** Especialista en Indicadores Técnicos · **Fecha:** 2026-09-19 · **Estado:** propuesta, pendiente de decisión del dueño
**Alcance:** `motor-analitico/conectores/`, `motor-analitico/indicadores/tecnicos.py` y documentación. No toca umbrales de riesgo. Sí cambia el apalancamiento que ve el usuario, y eso queda cuantificado en §5.

Rutas relativas a `motor-analitico/` salvo indicación. Las comprobaciones empíricas se hicieron el 2026-09-19 hacia las 09:22 UTC con 4 peticiones sin clave a CoinGecko (todas 200 OK, espaciadas 13 s) y con Python de solo lectura sobre el `.venv` del proyecto. No se levantó ningún servicio.

---

## 1. Diagnóstico verificado

### 1.1 Lo que el código hace hoy

| # | Afirmación | Evidencia |
|---|---|---|
| a | Cripto pide `/coins/{id}/ohlc` con `days=180` | `conectores/coingecko.py:115` (`dias: int = 180`), `:123-127` |
| b | El DataFrame de cripto sale sin `Volume` | `conectores/coingecko.py:132-136` |
| c | Caché de velas de 15 min y de fundamentales de 5 min, 6 s entre llamadas y 3 reintentos ante 429 respetando `Retry-After` | `coingecko.py:29`, `:33`, `:39-40`, `:61-65`, `:105-113` |
| d | Acciones piden `period="6mo"`, `interval="1d"` | `conectores/yahoo_finance.py:48-53` |
| e | Indicadores: SMA 50/200, RSI 14, MACD 12/26/9, Bollinger 20, ATR 14 y volumen relativo 20 | `indicadores/tecnicos.py:63-65`, `:67-69`, `:71-73`, `:75-77`, `:88-93` |
| f | `cruce_medias` solo se emite si SMA 50 y SMA 200 no son NaN en la última fila | `tecnicos.py:109-117` |
| g | `fuerza` se calcula por conteo absoluto: ≥3 da alta, 2 da media, el resto baja | `tecnicos.py:158-166` |
| h | El volumen solo confirma una dominancia que ya existe | `tecnicos.py:141-153` |
| i | Soporte y resistencia salen de `tail(20)` de mínimos y máximos | `tecnicos.py:184-194`; se llama sin argumentos en `servicio_interno.py:248` |
| j | El escaneo siempre usa el tope de Fase 1 (5 por defecto) | `servicio_interno.py:48`, `:175-177` |
| k | Tramos de ATR% (≥6 → 1,0×; ≥3 → 2,0×; <3 → 3,0×) y bonus (media +1,0×, alta +2,0×) | `riesgo/apalancamiento.py:84-92`, `:100-102`, `:126` |
| l | Rotación exige dominancia estricta `alcistas > bajistas` | `riesgo/rotacion.py:61` |
| m | Salud cuenta bajistas si `bajistas >= alcistas` | `riesgo/salud_posicion.py:69-71` |
| n | 47 tests en verde (12 + 8 + 7 + 12 + 8) | los ejecuté hoy: 47 PASS y 0 FAIL |

### 1.2 Los cuatro puntos del planteamiento

| Punto | Veredicto | Detalle |
|---|---|---|
| 1. `/ohlc?days=180` da velas de 4 días | **Confirmado**, con dos precisiones | En vivo salieron 45 velas separadas exactamente 4 días (2026-03-24 → 2026-09-16), y la documentación lo confirma: *"31 days and beyond: 4 days"* ([docs `/ohlc`](https://docs.coingecko.com/v3.0.1/reference/coins-id-ohlc)). **Precisión A:** "4 veces más lenta" vale para el horizonte de RSI y MACD (RSI 14 = 56 días, EMA lenta del MACD 26 = 104 días), pero el ATR% escala con la raíz del tiempo, no de forma lineal. En BTC medí ATR% = 5,66 con velas de 4 días frente a 2,77 con velas diarias: un factor 2,04 ≈ √4. Por eso el apalancamiento de cripto hoy sale **infravalorado**, no inflado (ver §5). **Precisión B, no estaba en el planteamiento:** `precio_actual` de cripto es el cierre de la última vela de 4 días **completa**. El timestamp de `/ohlc` es el *"close time"* de la vela (misma URL). Hoy a las 09:22 UTC la última vela cerraba el 2026-09-16 a las 00:00, así que el motor mostraba 75.590 USD cuando el precio vivo era 81.455 USD: **3,4 días y un 7,2 % de desfase**. Hoy el desfase va de 0 a 4 días, y afecta a `atr_pct`, a los niveles y al P&L de cartera (`servicio_interno.py:157`, `:304`). |
| 2. `6mo` da ~126 velas y SMA 200 no se calcula | **Confirmado** | Con 126 velas sintéticas, SMA_200 no tiene ningún valor válido (§8). `cruce_medias` no se emite nunca, ni en acciones ni en cripto. |
| 3. S/R: 20 sesiones frente a ~80 días | **Confirmado** | En vivo la ventana de BTC empezaba en la vela que cierra el 2026-07-02: cubre unos 80 días y mide un 32,2 % del precio (57.779–82.108). Con velas diarias la misma ventana mide un 8,7 % (75.038–82.108). |
| 4. Cripto nunca llega a "alta" | **Confirmado**, con matiz | Cripto tiene como mucho RSI y MACD, así que su máximo es "media", y además solo con RSI < 30 y MACD > 0 a la vez (o RSI > 70 con MACD ≤ 0). Acciones sí pueden llegar a "alta" hoy, pero solo con RSI < 30, MACDh > 0 y volumen > 1,5× simultáneamente. La asimetría real es 3 votos posibles frente a 2, como ya corrigió el CHANGELOG (líneas 338-341). |
| Contexto: "universo fijo NVDA, AAPL, MSFT, TSLA" | **Inexacto** | El universo real está en `backend/src/routes/escaner.js:9-10`: **21 acciones** (`O, QFIN, GM, UAL, BAC, F, EWY, CLX, AMCR, TROW, NLY, KMB, IBM, WFC, MO, SSTK, HRL, CSCO, AGNC, CCOI, FLO`) y 3 cripto. NVDA, AAPL, MSFT y TSLA solo aparecen en fixtures de tests (`tests/test_rotacion.py:11-20`). Esto importa para el presupuesto de llamadas: son 21 llamadas a yfinance por escaneo, no 4. |
| Hallazgo lateral | Informativo | El comentario de `tecnicos.py:15` habla de pandas-ta 0.3.14b0, pero en el `.venv` está instalada la **0.4.71b0**. En esa versión `ta.atr` siembra la media de Wilder con la SMA de las 14 primeras posiciones (`presma`) y `rma` no aplica `min_periods`. Eso importa en §3.3: si el ATR se calcula sobre una serie con máximos y mínimos NaN al principio, sale sin semilla y sesgado. TA-Lib no está instalado. |

---

## 2. Recomendación

**Velas diarias en los dos mercados, ventanas definidas en velas y no en días de calendario, y sin cambiar la definición de `fuerza`.**

- **Cripto:** CoinGecko gratis no ofrece OHLC diario real. El parámetro `interval=daily` de `/ohlc` es solo para planes de pago, y la clave Demo tampoco lo habilita. Propongo construir la vela diaria a partir de dos llamadas sin clave por moneda:
  - `/market_chart?days=365&interval=daily` aporta 365 cierres diarios a las 00:00 UTC, el precio vivo y el volumen de 24 h.
  - `/ohlc?days=30` aporta velas de 4 h, que se agregan a máximo, mínimo y apertura diarios de los últimos 30 días.
  - ATR y soporte/resistencia se calculan solo sobre las filas con máximo y mínimo reales. Nunca se inventan.
- **Acciones:** pasar a `period="2y"`.

Con esto, "RSI 14", "ATR 14" y "20 velas" significan en ambos mercados 14 o 20 **periodos diarios de negociación**. Las dos clases de activo tienen los mismos cuatro indicadores posibles (tres votantes y el volumen como confirmador), así que la asimetría desaparece y normalizar `fuerza` deja de hacer falta. Normalizarla ahora solo la aflojaría.

**El coste de riesgo hay que aceptarlo de forma explícita:**
1. "Alta" pasa a ser alcanzable, y con ATR% < 3 eso da **5,0×, el tope de Fase 1**.
2. El ATR% de cripto baja aproximadamente a la mitad al corregir la escala. BTC pasa del tramo "volatilidad media" (base 2,0×) al de "volatilidad baja" (base 3,0×).
3. A cambio, `cruce_medias` neutraliza las lecturas a contratendencia. En los últimos 167 días de BTC quitó **todos** los días operables (ver §5).

---

## 3. Especificación técnica

### 3.1 Conector de cripto (`conectores/coingecko.py`)

| Llamada | Endpoint | Parámetros exactos | Qué aporta | Clave de caché | TTL |
|---|---|---|---|---|---|
| C1 | `GET /coins/{id}/market_chart` | `vs_currency=usd`, `days=365`, `interval=daily` | `prices`: 366 puntos (365 a las 00:00 UTC más el punto vivo); `total_volumes`: los mismos timestamps | `mc:{id}:365` | **900 s** (15 min) |
| C2 | `GET /coins/{id}/ohlc` | `vs_currency=usd`, `days=30` | 180 velas de 4 h, con timestamp = hora de cierre (00, 04, 08…) | `ohlc4h:{id}:30` | **3600 s** (60 min) |

Base documental de cada parámetro:
- `days=365` es el máximo de historia en Demo y sin clave: *"restricted to the past 365 days"* ([market_chart](https://docs.coingecko.com/v3.0.1/reference/coins-id-market-chart)). Por encima de 90 días la granularidad es diaria a las 00:00 UTC (misma URL). `interval=daily` está disponible para todos los usuarios ([market_chart/range](https://docs.coingecko.com/v3.0.1/reference/coins-id-market-chart-range)). Verificado en vivo: 366 puntos, 364 saltos de exactamente 1 día y un último punto vivo (09:22:20).
- `days=30` es el máximo que todavía devuelve velas de 4 h: *"3–30 days: 4 hours"* ([docs `/ohlc`](https://docs.coingecko.com/v3.0.1/reference/coins-id-ohlc)). Verificado en vivo: 180 velas, 179 saltos de exactamente 4 h. Con 31 días o más vuelve la vela de 4 días.

**Construcción de la vela diaria.** Debe ir en una función pura, sin red, para poder testearla: `construir_velas_diarias(market_chart: dict, ohlc_4h: list) -> pd.DataFrame`.

| Campo de la vela del día UTC `D` | Regla |
|---|---|
| Índice | `D` (fecha UTC normalizada) |
| `Close` | Precio de C1 con timestamp `D+1 00:00`. Para el día en curso, el precio vivo, es decir el último punto de C1. Verifiqué que el punto diario de C1 coincide exactamente con la muestra horaria de las 00:00 del `market_chart` horario: diferencia 0,0 % en 89 días. |
| `Volume` | `total_volumes` de C1 en el mismo timestamp que `Close`. Es volumen agregado de 24 h móviles. El punto vivo es también de 24 h completas, así que no hay sesgo de vela parcial. |
| `High` / `Low` | Máximo y mínimo de las velas de 4 h de C2 cuyo cierre cae en `(D 00:00, D+1 00:00]`, es decir cierres de `D 04:00` a `D+1 00:00`: 6 velas. Luego `High = max(High, Close)` y `Low = min(Low, Close)`, porque el cierre viene de otra serie y la vela tiene que quedar consistente. |
| `Open` | `Open` de la primera vela de 4 h del día. Si el día no tiene velas de 4 h: `Close` del día anterior. `Open` no lo usa ningún indicador. |
| Días sin velas de 4 h (≈ 336 filas más antiguas) | `High` y `Low` quedan en **NaN**, sin fabricar nada. |
| Primer día de C2 incompleto (menos de 6 velas, el más antiguo) | Se descarta: su `High`/`Low` queda en NaN. Los demás días se aceptan aunque tengan menos de 6 velas: el de hoy, y el de ayer entre las 00:00 y las 00:35 UTC, que es cuando CoinGecko publica el día cerrado. |
| Resultado esperado | ≈ 366 filas, ≈ 30 con `High`/`Low` reales (en vivo: 30, desde 2026-08-21), la última fila es hoy y `Close[-1]` es el precio vivo |

**Errores.** Si C1 o C2 fallan tras los reintentos, `obtener_ohlcv` **propaga la excepción** y el ticker sale como `{ticker, error}` (`servicio_interno.py:280-283`). No se devuelve un frame sin máximos y mínimos. El README separa "sin dato" de "sin operación", y un fallo del proveedor tiene que verse como fallo, no como "no operable".

**Firma.** `obtener_ohlcv(coin_id: str) -> DatosOHLCV`. Se retira el parámetro `dias`: sus dos valores están fijados por la documentación y no son configurables. `servicio_interno.py:84` no cambia.

### 3.2 Conector de acciones (`conectores/yahoo_finance.py`)

| Parámetro | Hoy | Propuesta | Motivo |
|---|---|---|---|
| `periodo` | `"6mo"` (~126 velas) | **`"2y"`** (~502 velas) | Deja 303 valores válidos de SMA 200 y más de 400 de convergencia para las EMA (§8). `"1y"` (~251) deja solo 52, y un par de festivos o una suspensión los acercan al límite. `"2y"` es un valor válido según el docstring de `yfinance 1.7.0` instalado (*"Valid periods: 1d,5d,1mo,3mo,6mo,1y,2y,5y,10y,ytd,max"*). |
| `intervalo` | `"1d"` | `"1d"` | Sin cambio |
| Llamadas | 1 por ticker | 1 por ticker | Solo crece el tamaño de la respuesta |

### 3.3 `indicadores/tecnicos.py`

| Elemento | Hoy | Propuesta |
|---|---|---|
| SMA 50 / SMA 200 | `ta.sma(Close)` | Sin cambio |
| RSI 14, MACD 12/26/9, Bollinger 20 | sobre `Close` | Sin cambio |
| **ATR 14** | `ta.atr(High, Low, Close)` sobre el frame entero (`:75-77`) | Calcularlo sobre el subconjunto `High.notna() & Low.notna()` y reindexarlo al frame completo (NaN fuera del subconjunto). Si el subconjunto tiene ≤ 14 filas, `ATR_14 = NaN`, lo que activa el modo degradado de la regla 4. En acciones el subconjunto es el frame entero, así que el resultado es idéntico al de hoy (test §7-6). **Por qué es obligatorio:** con el frame fusionado de BTC, el ATR ingenuo da 2.618 (3,21 %, tramo medio, referencia 2,0×), mientras que el del subconjunto da 2.253 (2,77 %, tramo bajo, referencia 3,0×). La diferencia sale de que pandas-ta 0.4.71b0 calcula la semilla `presma` sobre las 14 primeras **posiciones**, que en el frame fusionado son NaN, y la media arranca sin semilla. |
| Volumen relativo 20 | NaN si no hay `Volume` | Sin cambio en el código. Cripto pasa a tener `Volume`. |
| **`calcular_soporte_resistencia`** | `tail(20)` y `.min()`/`.max()`, que ignoran NaN en silencio | Si alguna fila de `tail(ventana)` tiene `High` o `Low` NaN, devolver `(nan, nan)`. Así `_niveles_tecnicos` cae al fallback por ATR (`servicio_interno.py:252-268`) en vez de describir una ventana más corta sin decirlo. |
| Constantes | Literales | `VENTANA_SOPORTE_RESISTENCIA = 20` y `LONGITUD_ATR = 14`, en velas, con un comentario que diga "velas diarias: sesiones en acciones, días UTC en cripto" |
| `evaluar_confluencia` / `fuerza` | `:98-181` | **Sin cambio.** Ver §5.1. |
| Comentario de `:15` | Cita pandas-ta 0.3.14b0 | Actualizarlo a la versión realmente instalada. Es cosmético, pero el cambio del ATR depende del comportamiento de la 0.4.x. |

### 3.4 Coherencia temporal: ventanas en velas, no en calendario

| Ventana | Acciones (velas = sesiones) | Cripto (velas = días UTC) | Calendario equivalente acc. / cripto |
|---|---|---|---|
| RSI 14 | 14 | 14 | ≈ 20 d / 14 d |
| ATR 14 | 14 | 14 | ≈ 20 d / 14 d |
| MACD 12/26/9 | 12/26/9 | 12/26/9 | ≈ 36 d / 26 d (EMA lenta) |
| Bollinger 20, volumen 20, S/R 20 | 20 | 20 | ≈ 28 d / 20 d |
| SMA 50 / SMA 200 | 50 / 200 | 50 / 200 | ≈ 70 d / 280 d frente a 50 d / 200 d |

**Por qué en velas:**
1. Umbrales y longitudes están calibrados por observación, no por día de calendario. El 30/70 del RSI, el 14 de Wilder y el 2σ de Bollinger suponen N observaciones. Estirar la longitud (RSI 20 en cripto para igualar 14 sesiones × 7/5) comprime el RSI hacia 50 y obligaría a recalibrar 30/70 solo para cripto.
2. La guía define el ATR% como "cuánto se mueve el activo en un día típico" (`frontend/src/guia.js:51`) y los tramos de `apalancamiento.py:84-92` se aplican a esa cifra. Lo que tiene que ser igual en los dos mercados es **la duración de la vela**: un periodo diario de negociación. El número de días de calendario de la ventana no es lo que importa.
3. En cripto los fines de semana son negociación real y con riesgo real. Quitarlos para imitar la semana de 5 días tiraría 2/7 de los datos. En acciones, el hueco del fin de semana ya entra en el rango verdadero del lunes.
4. Es la convención del sector: en cualquier plataforma, la SMA 200 de BTC son 200 velas diarias.

**Asimetría residual, que documento pero no corrijo:** a igualdad de ATR% diario, una posición cripto mantenida N días de calendario acumula 7 movimientos por semana frente a 5, es decir √(7/5) ≈ 1,18× más riesgo por unidad de tiempo de calendario. Compensarlo cambiaría una regla de riesgo, así que es la decisión D3 de §9.

---

## 4. Alternativas descartadas

| # | Alternativa | Motivo del descarte |
|---|---|---|
| A1 | Mantener `/ohlc?days=180` y normalizar `fuerza` por la proporción de indicadores disponibles | No arregla la escala temporal: RSI, MACD y ATR seguirían en velas de 4 días, y el precio seguiría hasta 4 días desfasado. Además aflojaría el criterio: con 2 de 2, cripto pasaría a "alta" y recibiría +2,0× apoyada en dos indicadores de escala distinta a la que muestra la interfaz. |
| A2 | `/ohlc?days=365` | Sigue dando velas de 4 días (*"31 days and beyond: 4 days"*). Unas 91 velas: la SMA 50 se calcularía, pero equivaldría a 200 días y la SMA 200 seguiría sin calcularse. Mezcla escalas. |
| A3 | Pedir una clave Demo | **No da velas diarias.** *"Paid plan subscribers can use `interval=daily`"* en `/ohlc` ([referencia Pro](https://docs.coingecko.com/reference/coins-id-ohlc)). La clave Demo solo mejora el rate limit (*"100 calls/min"*, [rate limits](https://docs.coingecko.com/docs/common-errors-rate-limit)) y mantiene el tope de 365 días. Solo tendría sentido si el universo cripto crece (§6). |
| A4 | Plan de pago Basic (35 USD/mes, [precios](https://www.coingecko.com/en/api/pricing)) con `/ohlc?interval=daily` | Contradice "sin costos de licencia" (README:7). Y aun pagando, el diario de `/ohlc` solo llega a `days=180` (misma referencia Pro): 180 velas, que no alcanzan para la SMA 200 sin llamadas adicionales. |
| A5 | Reconstruir OHLC desde `market_chart?days=90` horario | En los 29 días comparables, el rango diario sacado de muestras horarias es la **mediana 0,80** del rango sacado de velas de 4 h (percentil 10: 0,74; mínimo: 0,53). Subestimar el rango da un ATR más bajo y **más apalancamiento**, lo contrario del espíritu de la regla 4. Además cubre solo 90 días, así que necesitaría C1 igualmente. |
| A6 | Solo cierres diarios (C1) y ATR "cierre a cierre" | El rango verdadero sin máximos ni mínimos subestima la volatilidad (mismo problema que A5, peor). El S/R sobre cierres ignora las mechas. |
| A7 | C1 + C2 + horario de 90 días (3 llamadas) para tener 90 días de máximos y mínimos | Mejoraría la convergencia del ATR (ver §8: error mediano 1,6 % con 30 filas frente a ≈ 0 con 60), pero rellenaría los días 31-90 con el rango horario sesgado de A5. Y sube a 9 llamadas en frío. No compensa. |
| A8 | Ventanas en tiempo de calendario (cripto: RSI 20, ATR 20, SMA 70/280, S/R 28) | Ver §3.4, punto 1. Cambia la distribución estadística del indicador y obligaría a tener umbrales distintos por clase de activo. |
| A9 | Cambiar de proveedor de cripto a un exchange (p. ej. Kraken `/public/OHLC`, `interval=1440`, *"up to 720 of the most recent entries"*, sin autenticación y con volumen, [docs Kraken](https://docs.kraken.com/api/docs/rest-api/get-ohlc-data/)) | **Técnicamente superior:** máximo y mínimo reales de 720 días con una sola llamada. Queda fuera de este encargo porque el marco es "cripto vía CoinGecko": sería un segundo adaptador, un mapeo de pares (`bitcoin→XBTUSD`…) y precio y volumen de un solo exchange en lugar de agregados. No verifiqué su rate limit. Lo dejo como decisión D4. |

---

## 5. Impacto aguas abajo

### 5.1 `fuerza`: la asimetría desaparece y no hay que normalizar

| | Hoy acciones | Hoy cripto | Propuesta, ambas |
|---|---|---|---|
| Votantes posibles | RSI, MACD | RSI, MACD | cruce, RSI, MACD |
| Confirmador | volumen | — | volumen |
| Máximo por lado | 3 | 2 | 4 |
| ¿"Alta" alcanzable? | Rara vez (RSI < 30, MACDh > 0 y volumen > 1,5× a la vez) | **Nunca** | Sí: p. ej. cruce + MACD + volumen |

**No recomiendo normalizar.** Con el mismo conjunto de indicadores en los dos mercados, el conteo absoluto vuelve a ser comparable. Normalizar por proporción daría "alta" con 2 de 2, que es más laxo que hoy. La tercera clave de rotación, `_proporcion_alcista` (`rotacion.py:20-36`), sigue siendo válida como desempate.

### 5.2 Apalancamiento. Tabla del recomendado con sesgo largo y tope de Fase 1 = 5

| ATR% \ fuerza | baja | media | alta |
|---|---|---|---|
| < 3 (base 3,0) | 3,0 | 4,0 | **5,0 = tope** |
| 3–6 (base 2,0) | 2,0 | 3,0 | 4,0 |
| ≥ 6 (base 1,0) | 1,0 | 2,0 | 3,0 |

Fuente: `apalancamiento.py:84-102`, `:126`, `:151-152`. En Fase 2 (tope 3) todo queda recortado a 3,0 por el `min()`.

**Ejemplos numéricos**

| Caso | Hoy | Propuesta | Efecto sobre el usuario |
|---|---|---|---|
| **BTC real, 2026-09-19** (datos en vivo pasados por `_escanear_ticker` con un doble) | Precio 75.590 (desfasado 7,2 %). Señales: MACD +1.763,8 → 1/0 alcista, fuerza baja, ATR% 5,66 (vela de 4 días) → **2,0× operable**. SL 57.779 (−23,6 %), TP 82.108 | Precio 81.455. Señales: cruce alcista (SMA 50 = 72.844 > SMA 200 = 70.453) y MACD −153,8 → 1/1 **neutral, no operable**. ATR% 2,77 → referencia **3,0×** (antes 2,0×). Sop./Res. 75.038 / 82.108 (−7,9 % / +0,8 %) | El RSI pasa de 53,8 a 64,7 y **el MACD cambia de signo**: la señal operable de hoy era un artefacto de la escala de 4 días. |
| Acción hipotética, ATR% 2,1, MACD alcista y volumen 1,8×, cruce alcista | 2/0 media → **4,0×** | 3/0 alta → **5,0×** (tope) | +1,0×, y la fila toca el remache de latón |
| Acción hipotética, ATR% 2,1, MACD alcista, cruce bajista | 1/0 baja → **3,0× operable** | 1/1 neutral → **no operable** (referencia 3,0×) | Deja de ofrecerse una operación a contratendencia |
| Cripto hipotética con ATR% diario 2,8 (≈ 5,6 en velas de 4 días), cruce + MACD alcistas | Máximo realista 2,0× (base 2,0, fuerza baja) | 2/0 media → **4,0×**; con volumen > 1,5×, 3/0 alta → **5,0×** | Hasta +3,0× sobre lo que el usuario ve hoy. Es el efecto más grande de la propuesta. |

**Mitigante que el usuario también verá:** el SL (soporte) se acerca mucho al precio. En BTC pasa del −23,6 % al −7,9 %. Con 2,0× y un SL al −23,6 %, la pérdida hasta el stop es ≈ 47 % del margen. Con un hipotético 4,0× y SL al −7,9 %, es ≈ 32 %. **El apalancamiento sube, pero la pérdida hasta el stop no sube en proporción.** Aun así es un cambio de regla de riesgo de facto y lo dejo como decisiones D1 y D2.

**Frecuencia medida (BTC, 167 días con SMA 200 válida, velas diarias con y sin `cruce_medias`):**

| Dirección / fuerza | Sin cruce (RSI + MACD + volumen) | Con cruce |
|---|---|---|
| alcista / baja | 75 | 0 |
| alcista / media | 3 | 0 |
| bajista / baja | 65 | 0 |
| bajista / media | 1 | 69 |
| bajista / alta | 0 | 8 |
| neutral / baja | 23 | 90 |
| **Días operables (sesgo largo)** | **78** | **0** |

En ese periodo BTC estuvo casi siempre con SMA 50 < SMA 200. El cruce convirtió las 78 lecturas alcistas del MACD, todas a contratendencia, en empates neutrales. Es una sola serie y un solo régimen de mercado: sirve para ver la dirección del efecto, no como estimación general.

**`MACDh == 0` vota bajista** (`tecnicos.py:137`). Fuera de alcance, pero su peso cambia: con tres votantes, un histograma exactamente en 0 ya no decide la dirección él solo, aunque sí puede empatar un cruce alcista y dejar la fila neutral. No lo resuelvo.

### 5.3 Salud de la posición (`salud_posicion.py:69-71`, `:105-113`)

| Señales | Hoy | Propuesta |
|---|---|---|
| MACD alcista; cruce bajista | 1/0 → deterioro 0 → **verde** | 1/1 → empate, `>=` → deterioro 1 → **ámbar** |
| MACD bajista; cruce bajista; EPS < 0 | 0/1 → **ámbar** | 0/2 → **rojo**, y se dispara la sugerencia de rotación |
| MACD bajista; cruce alcista | 0/1 → ámbar | 1/1 → ámbar (sin cambio) |
| MACD alcista; cruce alcista | verde | verde |
| Cualquier cripto | ámbar como máximo | Ámbar como máximo: sin cambio. Sin EPS, `evaluar_deterioro_fundamental` (`:81-83`) nunca es True. |

Efecto: más ámbar, y rojo alcanzable en acciones en tendencia bajista con EPS negativo. En BTC, 69 + 8 de 167 días quedarían con deterioro ≥ 2, pero sin llegar a rojo por ser cripto.

### 5.4 Rotación (`rotacion.py:49-62`)

- **Nuevos candidatos:** cruce + MACD alcistas → 2/0 media → entra. Hoy, 1/0 baja, no entraba.
- **Trampa latente: sigue cerrada.** RSI < 30 (alcista) con cruce y MACD bajistas da 1/2, fuerza "media" por el lado bajista. `rotacion.py:54` lo dejaría pasar por fuerza, pero `rotacion.py:61` (`indicadores_alcistas > indicadores_bajistas`) lo excluye. Si además el volumen confirma lo bajista (1/3, "alta"), también queda excluido. Ya lo cubre `tests/test_rotacion.py:77` (`test_un_alcista_y_dos_bajistas_no_es_candidato`), y en §7 añado la versión generada de extremo a extremo.
- Cripto sigue sin poder ser **origen** de una rotación (nunca llega a rojo), pero sí puede ser **destino** en igualdad de condiciones con las acciones.

### 5.5 Soporte y resistencia

| | Hoy acciones | Hoy cripto | Propuesta |
|---|---|---|---|
| Cobertura de 20 velas | 20 sesiones (≈ 28 días de calendario) | ≈ 80 días | 20 sesiones / 20 días |
| BTC, ancho del rango | — | 32,2 % | 8,7 % |
| Fallback por ATR (`servicio_interno.py:252-268`) | rango < 1 ATR | más raro (ventana ancha) | Algo más frecuente en cripto: la ventana es más estrecha, aunque el ATR también baja aproximadamente a la mitad. En BTC no se activa: rango 7.070 frente a ATR 2.253. |

---

## 6. Presupuesto de llamadas y caché

Supuestos: el frontend refresca cada 5 min (`frontend/src/useApi.js:39`), hay 3 cripto y 21 acciones (`escaner.js:9-10`), y el espaciado es de 6 s (`coingecko.py:29`).

| Concepto | Hoy | Propuesta |
|---|---|---|
| Llamadas CoinGecko por escaneo en frío | 3 (`/ohlc` ×3) | **6** (C1 ×3 + C2 ×3) |
| Duración mínima del bloque cripto en frío | ≈ 12 s + latencia | **≈ 30 s + latencia** |
| Pico por minuto | ≤ 10 (limitado por los 6 s) | ≤ 10 (sin cambio) |
| TTL de velas | 15 min | C1: **15 min** (es el precio vivo; la documentación cachea `market_chart` cada 30 s). C2: **60 min** (solo añade velas de 4 h completas; la documentación actualiza `/ohlc` cada 15 min) |
| Llamadas por hora en régimen (12 escaneos/h) | 12 | **15** (C1: 4 × 3 = 12; C2: 1 × 3 = 3) |
| Desfase máximo de `precio_actual` en cripto | **hasta 4 días** | **≤ 15 min** |
| Llamadas a yfinance por escaneo | 21 (6mo) | 21 (2y, respuesta más grande) |
| `/internal/analyze-position` cripto | OHLC cacheado + 1 de fundamentales | Igual |
| ¿Cabe sin clave? | Sí | **Sí.** La documentación sin clave da *"~10–30 calls/min (dynamic)"* ([keyless](https://docs.coingecko.com/docs/keyless-public-api)). El artículo de soporte, según el resultado de búsqueda, cita 5-15/min ([soporte](https://support.coingecko.com/hc/en-us/articles/4538771776153-What-is-the-rate-limit-for-CoinGecko-API-public-plan)). En la franja baja (5/min) puede aparecer algún 429, y lo absorbe el reintento con `Retry-After` (`coingecko.py:83-113`). |
| ¿Cuándo pedir clave Demo? | — | Solo si `UNIVERSO_CRIPTO` pasa de unas 5 monedas: 10 llamadas en frío son más de 1 min de espaciado |

---

## 7. Casos de prueba (sin red, estilo `assert` más runner en `__main__`)

Fixtures: un `market_chart` sintético con 365 puntos diarios a las 00:00 UTC más un punto vivo a las 09:22 del último día, y un `ohlc_4h` sintético con 180 velas (cierres a las 12:00, 16:00… del día −30 hasta las 08:00 de hoy). Ambos se generan en el propio test, sin guardar ficheros.

1. `construir_velas_diarias(mc, ohlc)` → `len(df) == 366`. El índice es diario, único y creciente, y `df.index[-1]` es el día del punto vivo.
2. Vela `D` → `df.loc[D, "Close"]` es igual al precio de `mc` en `D+1 00:00`, y `df["Close"].iloc[-1]` es el precio vivo.
3. `df["Volume"].notna().all()` y `df.loc[D, "Volume"]` es el `total_volumes` de `D+1 00:00`.
4. Las velas de 4 h con cierre `D 04:00 … D+1 00:00` se asignan al día `D`. Con una vela de máximo 999 cerrando a `D+1 00:00`, `df.loc[D, "High"] == 999` y `df.loc[D+1, "High"] != 999`.
5. El primer día de `ohlc` tiene 3 velas (incompleto) → ese día tiene `High`/`Low` NaN. `df["High"].notna().sum() == 30` y `df["High"].isna().sum() == 336`: nada fabricado.
6. En toda fila con `High` válido: `High >= max(Open, Close)` y `Low <= min(Open, Close)`. En la fila viva, `High >= precio vivo >= Low`.
7. **Regresión en acciones:** con un frame sintético de 502 filas sin NaN, `calcular_indicadores(df)["ATR_14"]` es igual, elemento a elemento, a `ta.atr(High, Low, Close, 14)` sobre el frame completo.
8. **ATR sobre el subconjunto:** con un frame de 366 filas y `High`/`Low` NaN en las 336 primeras → `ATR_14.notna().sum() == 17` y el último valor es igual, con tolerancia de 1e-9, a `ta.atr` sobre `df.dropna(subset=["High","Low"])`.
9. Con menos de 15 filas con máximo y mínimo reales → `ATR_14` NaN en la última fila → `_escanear_ticker` con un doble da `operable is False`, `leverage_recomendado is None` y un `leverage_motivo` que contiene "volatilidad no disponible" (regla 4).
10. `calcular_soporte_resistencia(df)` con algún NaN en `tail(20)` de `High` → devuelve NaN en los dos valores → `_niveles_tecnicos` devuelve `niveles_origen == "atr"`.
11. Con 366 filas y deriva alcista (reutilizando `_serie` de `test_contrato_scan.py:34`) → `SMA_200` tiene valor en la última fila y hay una señal `cruce_medias` en `senales`.
12. Frame de cripto sintético con volumen (el último valor, 3× la media) y cruce + MACD alcistas → `fuerza == "alta"`, `indicadores_alcistas == 3`. Con ATR% < 3 → `leverage_recomendado == 5.0 == leverage_tope`, nunca mayor.
13. El mismo caso con `LEVERAGE_TOPE_FASE1 = 3.0` → `leverage_recomendado == 3.0` (regla 1).
14. Contrato: los casos 11, 12 y 9 pasados por `_escanear_ticker` → `json.dumps` sin `NaN` ni `Infinity`, y se cumplen las invariantes de `test_contrato_scan.py:131-147`.
15. Rotación de extremo a extremo: un payload generado con RSI < 30, cruce bajista y MACD bajista (1/2, "media") → `mejor_oportunidad_del_escaneo([payload], "X") is None`.
16. Salud: `confluencia(1, 1)` sin deterioro fundamental → "ámbar"; `confluencia(0, 2)` con deterioro fundamental → "rojo". Documenta el escenario cruce + MACD de §5.3.
17. Conector con `requests.get` y `time.sleep` sustituidos por dobles → en frío `obtener_ohlcv("bitcoin")` hace **exactamente 2** GET, con URLs y `params` idénticos a los de §3.1. Una segunda llamada dentro del TTL hace 0 GET. Al avanzar el reloj 16 min (doble de `time.monotonic`) hace 1 GET (solo C1). A los 61 min, 2 GET.
18. El doble de C2 lanza `HTTPError` 500 → `obtener_ohlcv` propaga la excepción, sin devolver un frame.
19. `inspect.signature(ConectorAccionesYahoo.obtener_ohlcv).parameters["periodo"].default == "2y"`.
20. Los 47 casos actuales siguen pasando sin tocarse. Los frames de `test_contrato_scan.py` no tienen NaN, así que el camino del ATR no cambia para ellos.

---

## 8. Arranque en frío y calentamiento

Número de valores válidos (no NaN) por indicador, medido con series sintéticas pasadas por `calcular_indicadores` real:

| Indicador | Hoy acciones (6mo, 126) | Hoy cripto (4 días, 45) | **Propuesta acciones (2y, ≈502)** | **Propuesta cripto (366 cierres; 30 con máx./mín.)** |
|---|---|---|---|---|
| SMA 50 | 77 | 0 | **453** | **317** |
| SMA 200 | **0** | **0** | **303** | **167** |
| RSI 14 | 125 | 44 | 501 | 365 |
| MACDh 12/26/9 | 93 | 12 | 469 | 333 |
| Bollinger 20 | 107 | 26 | 483 | 347 |
| ATR 14 | 113 | 32 | 489 | **17** (sobre el subconjunto) |
| Volumen relativo 20 | 107 | **0** | 483 | **347** |
| Ventanas S/R de 20 completas | 107 | 26 | 483 | **11** |

**Válido no es lo mismo que convergido.** pandas-ta 0.4.71b0 emite RSI desde la segunda vela y la media de Wilder no tiene `min_periods`. Medí el error del último valor frente a una serie de 3000 velas:

| N velas | Error RSI (puntos) | Error MACDh (% del ATR) | Error ATR |
|---|---|---|---|
| 45 (cripto hoy) | 0,77 | 6,1 % | 0,4 % |
| 126 | 0,002 | 0,002 % | ≈ 0 |
| 366 / 502 | 0,000 | 0,000 % | ≈ 0 |
| ATR con **30** filas (cripto propuesta), 300 series | — | — | mediana **1,6 %**, p90 4,0 %, máx. 6,8 % |

El ATR de cripto con 30 filas tiene ruido de estimación (no sesgo) del orden del 2-4 %. Solo importa cuando el ATR% está pegado a un umbral de tramo (3 % o 6 %). BTC hoy está en 2,77 %. Aceptarlo es parte de la decisión D1.

---

## 9. Cambios de documentación

| Archivo | Entrada | Qué queda desactualizado |
|---|---|---|
| `frontend/src/guia.js:169-172` | "Cripto se apoya en menos indicadores" | Falso tras el cambio. Sustituir por: "Las velas de cripto son días UTC y sus máximos y mínimos vienen de velas de 4 h de los últimos 30 días; el volumen es agregado entre exchanges." |
| `guia.js:175-178` | "El cruce de medias hoy no aporta" | Eliminar la entrada o sustituirla por: "Las ventanas se cuentan en velas: 20 velas son 20 sesiones en acciones (~4 semanas) y 20 días en cripto." |
| `guia.js:181-184` | "Una posición cripto nunca llega a «rojo»" | Sigue siendo cierta. Sin cambio. |
| `guia.js:190` | "Fuentes no oficiales" | Añadir que el escaneo en frío de cripto hace 2 peticiones por moneda |
| `guia.js:27-29` | "Confluencia" | El texto "los tres segmentos, cuántos indicadores la sostienen" es impreciso: los segmentos codifican la fuerza (`MedidorConfluencia.jsx:8`) y ahora puede haber 4 indicadores |
| `guia.js:41-45` | "Los cuatro indicadores" | "Volumen relativo · volumen / media de 20 sesiones": en cripto son 20 días de volumen de 24 h. El cruce de medias pasa a votar de verdad. |
| `guia.js:48-51` | "Volatilidad (ATR %)" | Pasa a ser cierta también para cripto. Añadir la nota de √(7/5) si se decide D3. |
| `guia.js:64` | Riel S/R, "últimos 20 mínimos" | Añadir "velas diarias en ambos mercados" |
| `guia.js:84-87` | "Confluencia alta: casi siempre 0 o 1" | Revisar: con el cruce activo, "alta" deja de ser excepcional |
| `frontend/src/components/MetricsStrip.jsx:109` | "señales con 3 indicadores alineados" | Debe decir "3 o más" (el máximo pasa a 4) |
| `README.md:403-408` | Rate limits y caché | Actualizar a 2 llamadas por cripto, TTL 15/60 min y ≈ 10 s por cripto nueva en frío |
| `README.md:409-414` | Pendiente de `/ohlc` con 4 días | Eliminarlo: queda resuelto |
| `tecnicos.py:15`, `coingecko.py:35-38` y `:132-135` | Comentarios | Hablan de `/ohlc?days=180` y de que "no hay volumen". Actualizar en el mismo commit. |
| `CHANGELOG.md:155-157` | "Para cripto el riel cubre ~80 días" | Cerrarla con referencia a la nueva entrada |
| `CHANGELOG.md:318-345` | "CoinGecko devuelve velas de 4 días" (2026-08-27) | Cerrarla: se opta por ampliar ventanas, no por normalizar `fuerza` |
| `CHANGELOG.md` | Entrada nueva | Debe registrar el desfase de hasta 4 días de `precio_actual` en cripto (no documentado hasta ahora), el cambio de ATR% de cripto (≈ ÷2) y que "alta" pasa a ser alcanzable, con la tabla de §5.2 |

---

## 10. Riesgos y decisiones que quedan para el dueño

| # | Decisión | Mi recomendación | Qué pasa si se rechaza |
|---|---|---|---|
| **D1** | Aceptar que el ATR% de cripto baja aproximadamente a la mitad (corrección de escala) y que, con ello, la base de apalancamiento de BTC pasa de 2,0× a 3,0×, con hasta 5,0× si la confluencia acompaña | Aceptarlo: el valor actual es un artefacto de la vela de 4 días y contradice la propia guía ("un día típico") | Mantener cripto en velas de 4 días, con todo lo de §1 (precio desfasado incluido) |
| **D2** | Aceptar que la fuerza "alta" pasa a ser alcanzable en acciones y en cripto, y que eso produce filas en **5,0×, el tope de Fase 1** | Aceptarlo sin normalizar | Opción conservadora: exigir ≥ 3 **votantes** para "alta" (sin contar el volumen), o limitar el bonus de "alta" a +1,0×. Las dos son cambios de regla de riesgo y habría que especificarlas aparte. |
| **D3** | Compensar el riesgo por tiempo de calendario de cripto (ATR% × √(7/5) ≈ 1,18 solo para decidir el tramo) | No hacerlo en este cambio. Documentarlo. | — |
| **D4** | Segundo proveedor (Kraken OHLC diario: 720 velas, máx./mín. reales, 1 llamada) frente a la reconstrucción CoinGecko 4h + diario | Quedarse con CoinGecko ahora. Reevaluar si el ruido del ATR con 30 filas (§8) molesta en la práctica o si crece el universo. | — |
| **D5** | Pedir clave Demo de CoinGecko | **No hace falta**: no aporta velas diarias (A3). Solo si el universo cripto pasa de ~5 monedas. | — |
| **D6** | Fallo de C2: error de ticker o fila degradada | Error de ticker (§3.1) | Fila no operable con "volatilidad no disponible". Es seguro por la regla 4, pero se confunde con "sin operación". |
| **D7** | Aceptar ≈ 30 s de escaneo en frío para cripto (hoy ≈ 12 s) | Aceptarlo. El refresco es cada 5 min y el régimen estable está cacheado. | — |

**Riesgos técnicos residuales**
- **Ruido del ATR con 30 filas** (mediana 1,6 %, p90 4 %). Puede mover una cripto de tramo cuando está pegada al 3 % o al 6 %.
- **Máximos y mínimos de 4 h:** son el rango de las velas de 4 h que agrega CoinGecko, no el de un exchange concreto. Puede subestimar algo el rango verdadero, y ese sesgo empujaría hacia más apalancamiento. No es cuantificable sin una fuente de referencia.
- **Rate limit dinámico** (5-30/min según la fuente). El reintento lo absorbe, pero un escaneo en frío en hora punta puede tardar más de 30 s.
- **pandas-ta sin fijar** (`requirements.txt:3` pide `>=0.3.14b0` y está instalada la 0.4.71b0). El cálculo del ATR sobre el subconjunto depende de que la semilla `presma` se tome por posición. Conviene fijar la versión o, como mínimo, el test §7-8 lo detectará si cambia.
- **El cambio de señales es inmediato y visible:** en BTC, el mismo día, la fila pasa de "alcista 2,0× operable" a "neutral no operable". Conviene avisarlo en el CHANGELOG y en el registro de eventos del día del despliegue, para que no se lea como un fallo.
