# Fase 3 — El hackeo a Binance (29-10) y los datos fundamentales

> **Para qué sirve**: deja constancia de la caída de cripto del 29-10, que
> no vino de ningún indicador sino de un suceso (el hackeo a Binance), y
> de cómo la vivieron los agentes. Y responde al dueño: ¿se pueden
> incorporar datos fundamentales gratis?
> **Método**: velas diarias y órdenes de producción en solo lectura, del 25
> al 31-10. Lo que se cuenta del hackeo viene del informe que aportó el
> dueño (no lo hemos verificado por otra fuente); los movimientos de
> precio sí son nuestros datos.
> **Fecha**: 2026-10-31.

---

## 1. Qué pasó

Según el informe del dueño, el 29-10 se consolidó un robo de unos
6.300 M$ a Binance (una billetera caliente vaciada mediante una
delegación EIP-7702). Binance suspendió retiros y depósitos; Tether y
Circle congelaron parte de los fondos y Binance anunció que cubría las
pérdidas con fondos propios y el SAFU.

**En nuestros datos** (cierre diario del 29-10 frente al del 28-10):

| Cripto | 29-10 | 30-10 |
|---|---|---|
| bitcoin | −4,2 % | −0,8 % |
| ethereum | −4,6 % | −0,3 % |
| binancecoin | **−8,2 %** | +0,9 % |
| chainlink, polkadot | −10,2 %, −10,1 % | +8,0 %, +7,2 % |
| avalanche, cardano, litecoin, zcash, ripple, solana, dogecoin, bitcoin-cash | entre −5,3 % y −8,1 % | entre −0,8 % y +7,5 % |
| **tron** | **+6,9 %** | −6,7 % (y −4,1 % el 31) |

- **Todo el universo cripto cayó a la vez**, salvo tron, que subió el
  mismo día y lo devolvió los dos siguientes.
- **La caída fue a última hora del 29-10 (UTC)**: los stops saltaron entre
  las 20:37 y las 20:46.
- **Las acciones apenas lo notaron**: de media +0,5 % el 29-10 y −2,0 % el
  30-10.
- **El sistema funcionó**: ni un `fallo` en `eventos_sistema` del 29 al
  31-10; el ETL y el monitor de órdenes siguieron en marcha.

## 2. Cómo les fue a los agentes

| Agente | Activo | Entrada | Salida | Resultado |
|---|---|---|---|---|
| Audacia | zcash | 22-10 | 29-10 16:11, **objetivo**, antes de la caída | +14,72 $ |
| Cadencia | binancecoin | 26-10 | 29-10 20:46, stop | −6,76 $ |
| Cadencia | ripple | 27-10 | 29-10 20:37, stop | −8,80 $ |
| Prudencia | ripple | 27-10 | 29-10 20:37, stop | −6,18 $ |
| Cadencia | tron | 29-10 09:20 | 29-10 21:15, **objetivo** | +8,83 $ |
| **Tendencia cripto** | **tron** | 30-10 01:20 | 30-10 05:18, stop | **−5,00 $ (−1 R)** |
| Cadencia | tron | 30-10 06:10 | 31-10 00:13, stop | −14,57 $ |
| Prudencia | tron | 30-10 06:10 | 31-10 00:13, stop | −7,75 $ |

Lo que enseña:

1. **Los stops hicieron su trabajo**: las tres posiciones atrapadas
   salieron a su stop, por −21,74 $ entre las tres, sin pérdidas mayores
   que el riesgo previsto. Ojo: el simulador cierra **al nivel** del stop
   (M3), y en cripto no hay huecos de apertura. Con Binance parado y los
   spreads abiertos, un exchange real podría haber ejecutado peor.
2. **La correlación es lo que de verdad pesa**: cuando cae todo a la vez,
   tener varias criptos no diversifica. Lo que limita el daño es el
   riesgo abierto por clase (G6 y cripto prudente, D22), no el número
   de activos.
3. **La primera operación de Tendencia cripto fue una ruptura falsa
   en pleno suceso**: tron rompió su máximo de 20 días justo el día
   en que todo lo demás caía. Entró a la 01:20 del 30-10 y salió por el stop
   cuatro horas después. Es lo que se espera de una estrategia de
   tendencia (muchas pérdidas pequeñas, pocas ganancias grandes). Una sola
   operación no dice nada de su ventaja; sí es la primera de las 5 de la
   revisión inicial frente al laboratorio (ESTADO §3.1).
4. **Prudencia y Cadencia también entraron en ese rebote de tron** y
   perdieron 22,32 $ entre las dos. Ningún indicador técnico distingue un
   rebote causado por un suceso.

## 3. Lo que no es del hackeo, pero pasó a la vez

**Prudencia apagó sola la salida por deterioro el 29-10 a las 13:40**,
dos días antes de que se aplicara la 0052, que congela estos ajustes. Es
el ajuste que el doc 08 preveía. La evidencia mezclaba reglas:

| Decisiones | Cuántas | Efecto medio |
|---|---|---|
| De antes de la 0043 (bastaba una lectura) | 7 | −2,05 $ |
| De después de la 0043 (dos lecturas, la regla de hoy) | 3 | **+4,04 $** |
| Total con el que decidió | 10 | −0,22 $ |

Con la regla vigente, la salida por deterioro de Prudencia **ganaba**
(la cuarta posterior, resuelta esa misma tarde, −2,08 $, deja la media en
+2,51 $). Desde el 29-10 **ninguno de los tres agentes con metas sale por
deterioro**. **Decidido** (dueño, 2026-10-31): se vuelve a encender (0053). Los dos
del 15-10 se quedan como están.

## 4. ¿Se pueden usar datos fundamentales gratis?

Sí, con matices. Hay que separar tres cosas.

### 4.1 Lo que ningún dato habría evitado

Un hackeo no se anuncia en los balances ni en los indicadores. Lo que sí
se puede hacer es **reaccionar** a un choque y **limitar** cuánto duele:

- **Freno por choque de mercado** (solo precios, sin datos nuevos): si
  bitcoin cae más de un X % en el día, no se abren posiciones de cripto
  durante N horas. Se puede probar ya en el laboratorio con 10 años de
  velas diarias, contra el azar, como cualquier filtro. El 30-10 habría
  evitado las tres entradas en tron.
- **Riesgo por clase**: ya existe (G6, D22). Este episodio no pide cambiarlo.

### 4.2 Acciones: fundamentales gratuitos y comprobables

| Fuente | Qué da | Coste | Sirve para el laboratorio |
|---|---|---|---|
| **SEC EDGAR** (`data.sec.gov`, XBRL) | Ingresos, beneficio, deuda, caja, acciones en circulación… de cada informe trimestral y anual, **con la fecha en que se publicó** | Gratis, sin clave (pide un `User-Agent` y como mucho 10 peticiones por segundo) | **Sí**: la fecha de publicación permite usar en cada día solo lo que se sabía entonces, sin mirar el futuro. Solo empresas que presentan en la SEC (las 32 de NYSE y Nasdaq, salvo extranjeras que presenten 20-F) |
| **Fechas de resultados** (EDGAR 10-Q/10-K/8-K, o `yfinance`) | Cuándo publica cada empresa | Gratis | **Sí**: el filtro más barato y probable: no entrar (o salir) antes de resultados, cuando el precio da saltos que ningún stop protege (la 0033 ya cobra esos huecos) |
| `yfinance` (`Ticker.info`, estados financieros) | PER, capitalización, márgenes; solo los últimos 4–5 trimestres | Gratis, no oficial | No: solo da el presente, y probar con él miraría el futuro |
| Financial Modeling Prep, Alpha Vantage | Lo mismo, más cómodo | Capa gratuita con clave y 25–250 peticiones al día | Prescindibles: EDGAR da lo mismo sin límites prácticos |

### 4.3 Cripto: no hay balances; hay otras cosas

| Fuente | Qué da | Coste |
|---|---|---|
| CoinGecko (ya es nuestro proveedor) | Capitalización, volumen, oferta | Gratis; el histórico de la capa gratuita llega a un año |
| DefiLlama | TVL por cadena y protocolo, flujos de stablecoins | Gratis, sin clave (su lista de hackeos hay que comprobar si sigue en la API gratuita) |
| Índice de miedo y codicia (alternative.me) | Un número diario de sentimiento, desde 2018 | Gratis, sin clave |

Son útiles como **contexto** (el escáner podría enseñarlos), pero como
señal para operar tienen poca historia o mucho ruido. Lo primero que hay
que probar en cripto es el freno por choque del §4.1, que solo usa
precios.

### 4.4 Cómo encaja con el experimento

- **Nada de esto cambia a los agentes con metas** hasta el final
  (2027-04-30): son el grupo de control.
- **Sí se puede probar ya en el laboratorio**, como cualquier hipótesis:
  mejora ≥ +0,05 R, IC90 por encima de cero, ≥ 30 operaciones y percentil
  ≥ 90 frente al azar.
- Coste: 0 €. EDGAR se descarga una vez por trimestre; el freno no
  necesita datos nuevos.

## 5. Propuesta, por orden

| # | Qué | Datos | Esfuerzo |
|---|---|---|---|
| 1 | ~~**Freno por choque de mercado** en cripto, en el laboratorio~~ | Ninguno nuevo | Hecho: **refutado** (§6) |
| 2 | **No entrar antes de resultados** en acciones, en el laboratorio | Fechas de EDGAR | Pequeño |
| 3 | **Calidad y valor** (rentabilidad, deuda, beneficio/precio) en acciones, en el laboratorio | EDGAR XBRL con fecha de publicación | Medio: descarga, tabla y alineación por fecha |
| 4 | Miedo y codicia y TVL **como contexto** en el escáner | alternative.me, DefiLlama | Pequeño; no decide nada |

Lo que pase el laboratorio se guarda para el final del experimento, como
los tres cambios validados que ya esperan.

## 6. Resultado: el freno por choque, en el laboratorio (2026-10-31)

**Qué se probó**: no abrir posiciones de cripto si bitcoin cayó más de un
3, 5 o 7 % en el día, con una pausa de 2 días (ese día y el siguiente) o
de 5. Sobre las 14 criptos de producción, a 10 y 5 años, en Tendencia
cripto y en los tres agentes con metas con sus estrategias de hoy
(Prudencia en su versión 10). Criterio de siempre: mejora ≥ +0,05 R, IC90
sin el cero, ≥ 30 operaciones y percentil ≥ 90 frente al azar.
Código: `datos.con_mercado` y los filtros `sin_choque_3/4/5/7`.

**Veredicto: refutado en todas las variantes.** Ninguna mejora la
expectativa en validación en +0,05 R con el intervalo por encima de cero.

| Quién | Lo mejor que dio | Por qué no vale |
|---|---|---|
| Tendencia cripto | 10 años, −5 %, 5 días: +0,87 R frente a +0,86 R | No cambia nada: una ruptura del máximo de 20 días casi nunca coincide con un desplome. A 10 años, con −3 % y 2 días, las que quitaría ganaban **+1,43 R**: el freno le quita rupturas buenas |
| Prudencia | 10 años, −5 %, 2 días: −0,10 R frente a −0,12 R | +0,02 R, y sigue en negativo |
| Cadencia | — | Menos de 30 operaciones de cripto en validación |
| Audacia | 10 años, −3 %, 5 días: +0,00 R frente a −0,09 R | Mejora, pero el intervalo incluye el cero y solo supera al 55 % del azar; a 5 años, la misma variante empeora (−0,01 R frente a +0,05 R) |

**La pista que queda**: en los agentes con metas, las entradas que el
freno bloquea (umbral −5 %) son claramente peores que el resto en todo el
periodo: −0,31 frente a −0,06 R en Prudencia y −0,33 frente a +0,05 R en
Audacia (percentil 98–99 frente a quitar las mismas al azar). Comprar un
retroceso justo después de un desplome sale mal. Pero no se traduce en
mejora en la validación: con el freno, el agente compra el mismo retroceso
unos días después, y el resultado es parecido. Es coherente con todo lo
anterior: sus entradas no tienen ventaja, y quitar una parte no la crea.

**El 30-10**: con −3 % y 2 días, el freno habría evitado las tres
entradas en tron (bitcoin cayó un 4,2 % el 29-10); con −5 %, ninguna. Un
caso que el freno habría salvado no compensa lo que quita en diez años.

**Conclusión**: no se propone. El freno queda en el laboratorio (los
filtros `sin_choque_*`) por si una estrategia futura lo necesita. El
riesgo de un suceso como el hackeo se sigue gestionando con el stop y el
riesgo por clase (G6, D22).

