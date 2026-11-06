# El flujo de órdenes como filtro de Tendencia cripto (2026-11-06)

> **Pregunta**: la pista del doc fase-3/15 §3. El flujo agresivo supera al
> azar pero solo deja +0,037 R. ¿Sumado como filtro a una estrategia que ya
> gana, Tendencia cripto, la mejora?
>
> **Datos**: velas de 1 hora del contado de Binance con el volumen de los
> compradores agresivos, agrupadas en días UTC (`binance.a_diarias`), de
> las 14 criptos del universo, del 2017-08-17 al 2026-10-31. Precio y flujo
> salen de la misma fuente. No toca producción ni a Tendencia cripto, que
> no se cambia mientras dure el experimento.

## 1. Qué se fijó antes de ejecutarla

Fijado y registrado en el commit `95ce6af`, antes de la primera ejecución:

- **La estrategia**: `tendencia` del laboratorio con los parámetros del
  agente (0037). Compra la ruptura del máximo de 20 días por encima de la
  media de 200, con stop a 2 ATR que sigue a 3 ATR. Sale al cerrar bajo el
  mínimo de 10 días.
- **El filtro** (`TendenciaFlujo`): la ruptura solo vale si la parte del
  volumen de los últimos 1 o 3 días que compraron los agresores supera su
  mediana (0,5) o su decil 90 (0,9) frente a los 30 días anteriores.
  Rejilla de cuatro, elegida en el diseño.
- **El azar** (`AzarTendenciaFlujo`): las **mismas rupturas**, quedándose
  con unas al azar en la proporción que deja pasar el filtro. Mide si el
  filtro elige mejor que quitar operaciones a ciegas. 100 tiradas.
- El informe enseña también la estrategia **sin filtro**.
- Una entrada en `criterio.REGISTRO`: pide el percentil 98.

## 2. Una corrección de método antes del veredicto

En la primera ejecución el azar hizo 98 operaciones en validación frente a
las 158 de la estrategia. La calibración de la frecuencia hacía una sola
corrección proporcional, y aquí se quedaba corta: el azar solo puede entrar
en días de ruptura, y una posición abierta tapa las siguientes. Se corrigió
para que repita la corrección hasta quedar a menos de un 5 %. Con eso el
azar hace 153 operaciones. La regla, la rejilla y el criterio no
cambiaron. En las pruebas anteriores la frecuencia ya salía igualada
(3.610 frente a 3.609 en el doc fase-3/15), y sus veredictos se mantienen.

## 3. Resultado

| | Diseño (2017–2024) | Validación (2024–2026) |
|---|---|---|
| Tendencia **sin filtro** | +0,656 R (288 ops) | +0,934 R (166 ops) |
| **Con el filtro elegido** (1 día, mediana) | +0,639 R (268 ops) | +0,978 R (158 ops) |
| Azar: las mismas rupturas, quitando las mismas a ciegas (mediana) | +0,672 R | +0,956 R (153 ops) |
| Percentil frente al azar | 22 (mínimo 50) | **66** (mínimo 98) |

Ventanas móviles: +0,686 R encadenado, 3 de 3 bloques positivos. Eso lo
pone Tendencia, no el filtro.

**Veredicto: ❌ el filtro no aporta.** Quita un 7 % de las rupturas, y las
que quita no son peores que las que deja. En el diseño, la estrategia
filtrada rinde algo menos que sin filtro. En la validación, algo más, pero
dentro de lo que da quitar operaciones al azar. Con el umbral más estricto
(decil 90) pasa lo mismo: en el diseño es peor que sin filtro.

**Por qué**: una ruptura del máximo de 20 días ya es un día de compras
fuertes, así que el flujo agresivo casi siempre está alto en esos días y no
añade información. Lo que el doc fase-3/15 encontró, un efecto pequeño a
24 horas, no se suma a una estrategia que mantiene 15 sesiones de media.

## 4. Qué queda

- `TendenciaFlujo`, `AzarTendenciaFlujo` y `binance.a_diarias` quedan en
  el laboratorio, con sus tests. Se ejecuta con `python -m
  laboratorio.intradia --estrategia tendencia_flujo_cripto`.
- Van 37 ideas registradas; la siguiente sigue pidiendo el percentil 98.
- Tendencia cripto sigue como está: +0,93 R sin filtro en esta validación
  con datos de Binance, en línea con los +0,913 R que espera el laboratorio
  con los de Yahoo (doc fase-3/12 §3.1).
- Del doc fase-3/13 §5 quedan el sentimiento de los directivos (Form 4 de
  EDGAR) y, si creas una clave gratuita, las noticias de Alpaca.
