# Mejoras de las recomendaciones y agentes v2 (2026-11-05)

> **Qué pidió el dueño** (2026-11-05): aplicar las recomendaciones que se
> puedan, fijar ya cómo se juzgarán los agentes con valores de expectativa
> salidos de los experimentos y, con todo eso dentro, crear una versión 2
> de Prudencia, Cadencia y Audacia. Desde el primer día, las v2 operan
> con un criterio fijado de antemano.
>
> **El grupo de control no se toca**: las v2 son agentes nuevos, con su
> propia cuenta. Prudencia, Cadencia y Audacia siguen como están hasta el
> final del experimento.

Este documento crece por tandas, una por PR.

## 1. El criterio del laboratorio (recomendaciones 7, 8, 10 y 11)

Fijado **antes** de las pruebas siguientes, en `laboratorio/criterio.py`.
Lo aplican el modo por velas (`intradia.py`) y el modo contra el azar
(`contra_azar.py`). Las pruebas ya hechas conservan su veredicto, con el
criterio que tenían en su momento; si se repiten, se juzgan con este.

| Regla | Antes | Ahora |
|---|---|---|
| Percentil exigido frente al azar | 90 + un punto por cada prueba **del mismo modo** | `100 − 10 / √(1 + previas)`, con las previas de **todos los modos** (techo 99) |
| El diseño | No se comparaba con el azar | La elegida supera en el diseño al menos a la mitad de las tiradas |
| Ventanas móviles | No había | 5 bloques. En cada bloque desde el segundo, se elige con lo anterior y se mide ahí. Lo encadenado tiene que ser positivo, y también al menos la mitad de los bloques |
| Sesgo de supervivencia | Lo avisaba el doc, a mano | El informe avisa cuando una estrategia que compra caídas se prueba en el universo activo, el S&P 100 o las medianas |
| Registro | Una cuenta por modo | `criterio.REGISTRO`, una entrada por **idea** (no por variante). Una prueba sin registrar no se puede juzgar: se registra en el commit que la fija |

**Por qué**:

- **La cuenta global**: van 32 ideas probadas. Contadas por modo, la
  siguiente prueba por velas habría pedido el percentil 98, pero la
  siguiente diaria solo el 90. La fórmula nunca llega a ser imposible: con
  32 previas pide 98; con 100, 99. Para separar el 98 del 99 hacen falta
  100 tiradas al azar.
- **El diseño**: comprar caídas en los ETF pasó la validación en el
  percentil 96, pero en el diseño estaba en el 4. Una ventaja que cambia
  de signo según la época no sirve para operar mañana. Con este criterio
  no habría pasado.
- **Las ventanas móviles**: un único corte 70/30 juzga un solo periodo. Con
  bloques se ve si lo elegido con el pasado sigue funcionando en cada
  periodo siguiente.

El registro, reconstruido de los docs (32 ideas, del 2026-10-10 al
2026-11-05), está en `criterio.REGISTRO`, con la fecha y el documento de
cada una.

## 2. Los índices como vara (recomendación 13)

El dueño dio de alta el **S&P 500 (`^GSPC`) y el Nasdaq 100 (`^NDX`)** el
2026-11-05 a las 18:54 UTC, con dos años de cierres diarios. Entraron como
acciones activas, y eso tenía dos efectos:

- **La vara los contaba** como dos acciones más: las acciones pasaron de
  33 activos a 35.
- **Los agentes podían comprarlos** en cuanto el escáner les diera una
  señal operable. Esa tarde la señal era neutral y no hubo órdenes.

La **0058** los deja solo de referencia:

| Pieza | Qué hace |
|---|---|
| `activos.referencia` | Columna generada: verdadera para todo símbolo de Yahoo que empieza por «^» |
| `senales_vigentes.estado_activo` | Vale `referencia`. El universo de los agentes pide `activo`, así que ya no los ve; tampoco sus descartes ni el autodiagnóstico |
| `ordenes` | Un disparador rechaza cualquier orden sobre un índice, de agente o del simulador |
| `v_referencia_mercado` | Los índices salen de «universo» y «acciones» y entran como varas propias: `sp500` y `nasdaq100` |
| Escáner | Los enseña con el veredicto «Índice: sirve para comparar con el mercado; no se opera» |

El ETL los sigue leyendo: precios e indicadores diarios al día. Son la
serie que necesita la fuerza relativa frente al mercado, el siguiente
indicador pendiente.
