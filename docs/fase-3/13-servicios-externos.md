# Servicios externos de la guía del dueño: ¿factibles y viables? (2026-11-06)

> **Pregunta del dueño**: la «Guía de implementación: trading algorítmico
> avanzado (IA + multi-activo)» propone sentimiento de noticias (Finnhub,
> Alpha Vantage, NewsAPI), indicadores de microestructura (desequilibrio
> del libro, mapas de liquidez, perfil de volumen), ejecución con
> Interactive Brokers o Alpaca y una decisión por IA. ¿Se puede y merece la
> pena meterlo en el sistema?
>
> **Fuentes**: páginas oficiales de cada servicio, leídas el 2026-11-06.
> Las de Finnhub, con el navegador, porque su texto se genera con
> JavaScript. El catálogo público de Binance (`data.binance.vision`),
> consultado directamente, con un día de muestra descargado. No se ha
> creado ninguna cuenta ni se ha usado ninguna clave.

## 1. Las dos varas

Un servicio es **factible** si funciona con lo que tenemos: coste 0, la
base de datos de Supabase, el ETL en GitHub Actions y agentes que deciden
cada 5 minutos con señales de hasta 90 minutos. Es **viable** si además
puede ganar algo. Y en este proyecto eso se demuestra de una sola manera:
pasando el laboratorio con su criterio fijado (doc fase-3/12 §1). Van 32
ideas probadas y la siguiente pide superar al 98 % del azar, también en
el diseño y en las ventanas móviles. **Sin histórico no hay prueba**, y
sin prueba nada entra en un agente.

## 2. Veredicto por pieza

| Pieza de la guía | Factible gratis | Histórico para probarlo | Veredicto |
|---|---|---|---|
| Alpha Vantage, sentimiento de noticias | ❌ `NEWS_SENTIMENT` es **de pago** y la clave gratuita da 25 peticiones al día, no 5 por minuto como dice la guía | De pago | ❌ No, gratis no funciona |
| Finnhub, sentimiento de noticias | ❌ «News Sentiment» y «Social Sentiment» son **Premium** | — | ❌ No |
| Finnhub, noticias de empresa | ✅ 60 llamadas por minuto, solo uso personal, solo Norteamérica | **1 año** | ⚠️ Corto para el laboratorio; solo para mostrar titulares |
| Finnhub, sentimiento de directivos (MSPR) | ✅ No figura como Premium | Desde 2015 | 🔬 Probable; es Form 4 de la SEC, que ya leemos con EDGAR |
| NewsAPI.org | ❌ Plan gratuito solo para desarrollo, prohibido en producción, 24 h de retraso y 1 mes de búsqueda. El de pago cuesta 449 $ al mes | 1 mes | ❌ No |
| Alpaca News (Benzinga) | ⚠️ Probable, con cuenta gratuita y 200 llamadas por minuto, pero hay que confirmarlo con una clave | Desde 2015 | 🔬 La única fuente de noticias por activo con histórico largo |
| GDELT (no está en la guía) | ✅ Libre y sin clave | Desde 2015 | 🔬 Tono de la prensa mundial; ruidoso y no siempre por activo |
| Desequilibrio del libro, **cripto** | ✅ Binance publica gratis la profundidad del libro de futuros (`bookDepth`) | **Desde el 2023-01-01**, cada 30 s, unos 1.000 pares | 🔬 Se puede probar |
| Flujo de órdenes, **cripto** | ✅ Operaciones de contado con el lado comprador o vendedor (`aggTrades`) | Desde 2017 | 🔬 Se puede probar |
| Desequilibrio del libro, **acciones** | ❌ El plan gratuito de Alpaca solo da IEX (unos pocos % del volumen) y sin libro | — | ❌ No gratis |
| Mapas de liquidez | ❌ Necesitan el libro completo, orden a orden | — | ❌ No |
| Perfil de volumen | ✅ Se calcula con las velas que ya tenemos | 10 años o más | 🔬 Se puede probar ya |
| Interactive Brokers | ❌ La cuenta de simulación exige una cuenta real **aprobada y con fondos**, y el API necesita TWS o IB Gateway encendido | — | ❌ No ahora |
| Alpaca, ejecución en simulación | ✅ Cuenta solo de simulación para cualquiera, en todo el mundo, con 100.000 $ ficticios; acciones de EE. UU. y cripto | — | ⚠️ Factible, aporta poco (§4) |
| Decisión por IA («compra si el sentimiento > 0,35») | ✅ Técnicamente | Depende de la fuente | ❌ Así, no: es una regla sin probar y vende en corto |

🔬 = factible gratis y con histórico: **candidata al laboratorio**, nada más.

## 3. Lo que la guía da por hecho y no se cumple

- **Los servicios ya no son gratis donde importa**. El sentimiento ya
  calculado (Alpha Vantage, Finnhub) es de pago, y NewsAPI prohíbe el
  uso en producción. El ejemplo de código de Alpha Vantage fallaría con
  una clave gratuita.
- **«Los indicadores avanzados ignoran RSI y MACD»**. El desequilibrio
  del libro predice segundos o minutos. Nuestros agentes deciden cada 5
  minutos, con señales de hasta 90, y en el modo de 1 hora el spread ya se
  come entre el 10 y el 28 % del bruto (doc fase-3/10). A la escala en que
  operamos, la señal de microestructura llega tarde y cara. Puede servir
  agregada (la hora, el día), y eso es justo lo que hay que probar.
- **La ejecución no es el cuello de botella**. QuantFury, el bróker del
  dueño, solo tiene aplicación móvil y no he encontrado API pública. Los
  agentes operan en nuestro simulador, que ya cobra el spread observado y
  los huecos reales (0033–0035). Conectar Alpaca o IBKR no acerca nada a
  operar en QuantFury.
- **La decisión por IA vende en corto**. Los cortos no tienen ventaja en
  el laboratorio (doc fase-3/02), y la regla protegida nº2 dice solo
  largos.
- **«1–2 meses de simulación»**. Con 30 cierres no se distingue nada:
  demostrar +0,10 R pide de 270 a 780 operaciones (doc fase-3/12 §3.3).

## 4. Alpaca para ejecutar: por qué aporta poco

Es lo más fácil de montar (registro con correo y una clave de
simulación), pero:

- su simulación rellena al precio de IEX y no modela el spread de
  QuantFury, así que mediría peor que nuestro simulador lo que nos
  importa;
- duplica el libro mayor: dos saldos que pueden discrepar, y una clave
  más que custodiar;
- con cuenta real, las acciones de EE. UU. desde fuera piden un trámite
  aparte. Y lo de cambiar de bróker es decisión del dueño, no técnica.

**Recomendación**: no, salvo que el dueño quiera cambiar de bróker. En
ese caso, primero lo de §5.

## 5. Qué propongo, por orden

1. **Perfil de volumen en el laboratorio**, con las velas diarias que ya
   hay. Sin claves y sin coste. Por ejemplo: comprar el primer toque del
   nivel de más volumen de los últimos N días, frente al azar. Se fija y
   se registra antes de ejecutarla.
2. **Desequilibrio del libro y flujo de órdenes en cripto**, con
   `bookDepth` (2023–2026) y `aggTrades`, en velas de 1 hora y diarias.
   Las 14 criptos del universo tienen futuro perpetuo en Binance. Una
   idea por prueba, registrada antes. Dos avisos:
   - son menos de 3 años, así que el diseño y la validación quedan
     cortos;
   - el ETL corre en GitHub, en EE. UU., y el API en vivo de Binance
     restringe esas ubicaciones. Si validara, habría que leer el libro
     desde otro sitio (por ejemplo, desde Supabase). Los ficheros
     históricos sí se descargan.
3. **Sentimiento de directivos (Form 4)**, con EDGAR, que ya usamos. Es
   la única señal «de sentimiento» con 10 años de histórico gratis.
4. **Noticias por activo con Alpaca News**: solo si el dueño crea una
   cuenta gratuita de Alpaca y guarda la clave como secreto. Primero, una
   comprobación de cuánto histórico da de verdad; después, sentimiento
   calculado aquí con un modelo abierto (FinBERT, sin coste por uso),
   probado en el laboratorio.
5. **No**: Alpha Vantage, el sentimiento de Finnhub, NewsAPI, el libro de
   acciones, los mapas de liquidez, IBKR, ni la regla de «comprar con
   sentimiento > 0,35». Tampoco un LLM que decida operaciones: la I5
   (que un LLM proponga hipótesis, no que opere) sigue esperando la
   decisión del dueño sobre el coste.

Todo lo de §5 son pruebas de laboratorio. Ninguna toca el grupo de control
ni las v2. Si alguna pasara, iría a un agente nuevo, como Tendencia
cripto.

## 6. Fuentes

- Alpha Vantage: [documentación](https://www.alphavantage.co/documentation/) («Market News & Sentiment», marcada *Premium*) y [plan de pago](https://www.alphavantage.co/premium/) («25 API requests per day»).
- Finnhub: [precios](https://finnhub.io/pricing) y documentación de [News Sentiment](https://finnhub.io/docs/api/news-sentiment) (Premium), [Company News](https://finnhub.io/docs/api/company-news) («Free Tier: 1 year of historical news») e [Insider Sentiment](https://finnhub.io/docs/api/insider-sentiment).
- NewsAPI: [precios](https://newsapi.org/pricing).
- Alpaca: [Market Data API](https://docs.alpaca.markets/docs/about-market-data-api), [Paper Trading](https://docs.alpaca.markets/docs/paper-trading) y [Historical News Data](https://docs.alpaca.markets/docs/historical-news-data); el histórico de noticias desde 2015 lo da [su anuncio de la News API](https://alpaca.markets/blog/introducing-news-api-for-real-time-fiancial-news/).
- Interactive Brokers: [limitaciones de la simulación en el TWS API](https://www.interactivebrokers.com/docs/tws-api/doc/notes-limitations/limitations/paper-trading) y [base de conocimiento](https://ibkb.interactivebrokers.com/node/566).
- Binance: [binance-public-data](https://github.com/binance/binance-public-data) y el catálogo de `data.binance.vision` (`data/futures/um/daily/bookDepth/`, primer fichero de BTCUSDT el 2023-01-01).
- GDELT y sentimiento: [un intento de backtest con GDELT](https://realtime.bearblog.dev/backtesting/) y [BBVA Research sobre China](https://www.bbvaresearch.com/en/publicaciones/measuring-news-media-sentiment-using-big-data-for-chinese-stock-markets).
