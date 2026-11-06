# Flujo de órdenes y libro en cripto, en el laboratorio (2026-11-06)

> **Pregunta**: la segunda prueba que propone el doc fase-3/13 §5.2. ¿Las
> compras agresivas o un libro cargado del lado comprador anticipan las
> horas siguientes en cripto, a la escala en que operamos?
>
> **Datos**: ficheros públicos de Binance (`data.binance.vision`),
> descargados el 2026-11-06 sin clave (`laboratorio/binance.py`):
> - velas de 1 hora del contado en USDT de las 14 criptos del universo, con
>   el volumen de los compradores agresivos, desde que cotiza cada par
>   (2017-08 para BTC y ETH; 2020 para SOL, DOT y AVAX) hasta el
>   2026-10-31;
> - la profundidad del libro del perpetuo (`bookDepth`), una foto cada ~30
>   s, del 2023-01-01 al 2026-11-04, resumida por horas. Son unos 19.000
>   ficheros diarios; se tardó 42 minutos en bajarlos y resumirlos.
>
> No toca producción ni los agentes.

## 1. Qué se fijó antes de ejecutarlas

Fijado y registrado en el commit `7a24ebe`, antes de la primera ejecución:

- **Flujo de órdenes** (`flujo_ordenes_cripto`, `FlujoOrdenes`): la parte
  del volumen de las últimas 4 o 24 horas que compraron los agresores
  (las órdenes que cruzan el spread para comprar). Compra cuando queda en
  su decil alto frente a las 720 horas (30 días) anteriores del mismo
  activo.
- **Desequilibrio del libro** (`libro_cripto`, `LibroCripto`): la media en
  la hora de `(compra − venta) / (compra + venta)`, con el nominal
  acumulado hasta ±1 o ±5 % del precio. Es el OBI de la guía del dueño.
  Compra cuando queda en su decil alto, igual que el flujo.
- **Las dos**: entrada en la apertura de la hora siguiente; stop a 3 ATR de
  1 hora (48 horas) del cierre, sin objetivo; salida a las 8 o 24 horas.
  Spread de la 0034 en cada entrada y salida. Rejilla de cuatro, elegida en
  el diseño (el 70 % inicial).
- **El azar**: comprar a cualquier hora en la que la medida exista, con las
  mismas salidas y la misma frecuencia. 100 tiradas.
- **Dos entradas en `criterio.REGISTRO`**: las dos piden superar al 98 %
  del azar.

## 2. Resultado

| | Flujo de órdenes (2017–2026) | Libro (2023–2026) |
|---|---|---|
| Elegida en el diseño | 24 horas de flujo, salida a las 24 h | banda ±5 %, salida a las 24 h |
| Diseño | +0,029 R (6.568 ops) | −0,012 R (5.580 ops) |
| **Validación** | **+0,037 R** (3.609 ops), IC 90 % +0,005 – +0,070; por meses −0,019 – +0,100 | **−0,020 R** (2.140 ops), IC 90 % −0,056 – +0,019 |
| Azar en validación (mediana) | −0,010 R | −0,035 R |
| Percentil frente al azar, validación | **100** (mínimo 98) ✅ | 80 (mínimo 98) |
| Percentil frente al azar, diseño | **90** (mínimo 50) ✅ | 2 (mínimo 50) |
| Ventanas móviles | +0,029 R encadenado, 2 de 4 bloques ✅ | −0,015 R, 1 de 4 |
| Factor de beneficio | 1,09 (mínimo 1,2) | 0,95 |
| **Veredicto** | ❌ sin ventaja **suficiente** | ❌ sin ventaja |

### El libro: nada

Un libro cargado del lado comprador no anticipa las horas siguientes.
Todas las combinaciones pierden en el diseño y en la validación. Es lo que
avisaba el doc fase-3/13 §3: el desequilibrio predice segundos o minutos,
y a la escala de horas ya está en el precio.

### El flujo de órdenes: la primera señal que supera al azar en todo

Es la primera idea del laboratorio, de 36, que pasa los tres filtros
frente al azar: validación, diseño y ventanas móviles. Cuando en las
últimas 24 horas los compradores agresivos han sido inusualmente muchos,
las 24 horas siguientes salen mejor que a cualquier hora: unos +0,05 R más
que el azar, con 3.609 operaciones.

**Pero no llega al criterio de ventaja.** Deja +0,037 R por operación,
frente al mínimo de +0,10 R. El factor de beneficio es 1,09, y si se
remuestrean meses el intervalo incluye el cero. Es un efecto que
probablemente existe, pero es demasiado pequeño para pagar el riesgo y
las rachas.

Dos cautelas más:
- las 14 criptos son las que hoy siguen arriba, el mismo sesgo de
  supervivencia que en el doc fase-3/14;
- el precio es el de Binance; QuantFury cobra el spread de la 0034, que ya
  está descontado (es el 7 % del bruto).

## 3. Qué queda

- `laboratorio/binance.py` (velas con el volumen agresivo, y el libro
  resumido por horas), `FlujoOrdenes`, `LibroCripto` y sus azares quedan
  en el laboratorio, con sus tests. Se ejecutan con `python -m
  laboratorio.intradia --estrategia flujo_ordenes_cripto` (o
  `libro_cripto`), o en el modo `intradia` de `laboratorio.yml`.
- Van 36 ideas registradas; la siguiente sigue pidiendo el percentil 98.
- **Pista, no conclusión**: el flujo agresivo como *filtro* de otra
  estrategia con ventaja (por ejemplo, Tendencia cripto, +0,91 R a 10
  años) podría sumar lo que solo no alcanza. Sería otra idea, registrada
  antes de probarla, y no tocaría a ningún agente mientras dure el
  experimento.
- Siguiente del doc fase-3/13 §5: el sentimiento de los directivos con el
  Form 4 de EDGAR.
