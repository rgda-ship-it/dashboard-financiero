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

## 3. El veredicto, fijado de antemano (recomendaciones 1, 2 y 3)

**Qué pidió el dueño**: fijar valores de expectativa calculados con los
experimentos. La 0059 los guarda en `agente_veredicto_criterio`, una fila
por agente. **No se pueden cambiar ni borrar**: un disparador lo impide,
porque cambiar el criterio a mitad sería mover la portería.
`v_veredicto_agentes` da el estado de cada agente, y la pantalla lo
enseña en Agentes → Veredicto.

### 3.1 Lo que espera el laboratorio

Velas diarias de Yahoo del 2016-11-05 al 2026-11-05, sobre el universo
de producción del 2026-11-05 sin índices (45 de los 48 activos tienen
260 sesiones o más). Cada agente, con su estrategia de hoy (versiones 11,
10 y 9). Se guarda la cifra de **los 10 años enteros**, que es lo que se
espera en vivo:

| Agente | Expectativa | σ de la R | Operaciones | Diseño (2016–2023) | Validación (2023–2026) |
|---|---|---|---|---|---|
| Prudencia | **−0,041 R** | 1,71 | 595 | −0,063 R | −0,006 R |
| Cadencia | **−0,154 R** | 2,06 | 273 | −0,258 R | +0,034 R |
| Audacia | **+0,064 R** | 1,44 | 594 | +0,060 R | +0,069 R |
| Tendencia cripto | **+0,913 R** | 4,11 | 507 | — | — |

Tendencia cripto usa la estrategia `tendencia`, sin la cartera. Su doc
(fase-2/07 §6) da +1,03 R con la cartera; su criterio no cambia.

### 3.2 Los umbrales

Son los de Tendencia cripto (doc fase-2/07 §6) y el laboratorio (doc
fase-2/06 §3.5), iguales para todos:

| Estado | Cuándo |
|---|---|
| `pocas_operaciones` | Menos de 30 cierres desde `desde` |
| `pausar` | La caída desde el máximo pasa del 35 % |
| `retirar` | Expectativa negativa con 30 cierres o más |
| `validado` | Expectativa ≥ +0,10 R, el intervalo del 90 % por encima de cero y más rentable que su vara desde su comienzo |
| `sin_ventaja` | A los 60 cierres, sin validar |
| `observar` | Todo lo demás |

**Concordancia**: si la expectativa en vivo se sale de lo que espera el
laboratorio (su cifra ± 1,645 σ / √n), el agente opera distinto de lo
que se probó. Eso se revisa antes de concluir nada.

**Desde cuándo**:

- **Grupo de control**: cuenta sus cierres desde el experimento (el alta
  de Tendencia cripto, ya con las reglas de la 0030). Compara su
  rentabilidad desde el alta con la vara del universo desde el alta.
- **Tendencia cripto y las v2**: todo desde su propio comienzo. Su vara
  es la de su universo.

### 3.3 Lo que esto implica (y conviene saber ya)

- **El laboratorio no espera que el grupo de control pase**: Prudencia y
  Cadencia, con expectativa negativa; Audacia, positiva pero por debajo
  de +0,10 R.
- **Demostrar +0,10 R exige muchos cierres**. Con σ ≈ 1,0–1,7 R, el
  intervalo del 90 % deja de incluir el cero hacia las
  (1,645 × σ / 0,10)² = **270–780 operaciones**. Al ritmo de hoy, de 0 a 7
  entradas por semana, no se llega antes del 2027-04-30. Con 60 cierres
  solo se valida una expectativa de unos **+0,2 a +0,35 R**. Por eso
  «sin ventaja» a los 60 no quiere decir «perdedor»: quiere decir que no
  se demostró.
- **La comparativa concluye ahora desde el experimento** (recomendación
  3). El «faltan X para concluir» usa los cierres y la σ desde el 11-10.
  Antes de la 0030 los stops estaban a 0,1 ATR, y la σ de Cadencia (8,1 R
  desde el alta, 1,2 desde el experimento) no decía nada de las reglas de
  hoy.
- **Los dos cambios «validados» ya no pasan el criterio nuevo**.
  Recalculados con el universo de hoy, Cadencia con ADX ≥ 25 da −0,490 R
  en el diseño y +0,316 en la validación (sin el filtro, −0,258 y +0,034).
  Audacia sin acciones de menos de 10 $ (las criptos baratas siguen, como
  en la prueba original) da +0,033 y +0,085 (sin el cambio, +0,060 y
  +0,069). Solo mejoran en la validación. El dueño decidió
  (2026-11-05) que las v2 los lleven igualmente, como prueba en vivo
  juzgada con este criterio (§4).

## 4. Prudencia v2, Cadencia v2 y Audacia v2 (0060)

**Decidido por el dueño** (2026-11-05):

- Prudencia v2 con las reglas de Prudencia, en una cuenta limpia.
- Cadencia v2 y Audacia v2 con sus cambios «validados», como prueba en
  vivo, aunque ya no pasen el criterio nuevo (§3.3).
- Las tres con los ajustes automáticos y las consecuencias congeladas.
- 500 $ cada una, con la posibilidad de añadirles saldo.

| | Prudencia v2 | Cadencia v2 | Audacia v2 |
|---|---|---|---|
| Deriva de | Prudencia (versión 11) | Cadencia (versión 10) | Audacia (versión 9) |
| Cambio | Ninguno | Solo con ADX(14) ≥ 25 (`adx_min`) | Sin acciones de menos de 10 $ (`precio_min_accion`); las criptos baratas siguen |
| Lo que espera el laboratorio (10 años) | −0,041 R (σ 1,71) | −0,175 R (σ 3,08, 105 ops) | +0,054 R (σ 1,44) |
| Ajustes y consecuencias | Congelados | Congelados | Congelados |
| Saldo inicial | 500 $ | 500 $ | 500 $ |
| Vara | Universo, desde su alta | Universo, desde su alta | Universo, desde su alta |

**Cómo funcionan**:

- **Son agentes con metas** (`tipo = 'metas'`): las mueve el mismo ciclo
  de cada 5 minutos, con las mismas reglas comunes (SISTEMA-HOY §2.1).
  Arrancan en marcha al aplicar la 0060.
- **Los filtros nuevos** están en `fn_universo_agente`, después de la
  banda de ATR: `precio_bajo` y `adx`. El ADX es el del último día de
  `indicadores_diarios`. El grupo de control no lleva esas claves, así que
  para él la función da lo mismo que antes.
- **`agentes.grupo_control`** marca a Prudencia, Cadencia y Audacia, y
  **`agentes.deriva_de`**, el original de cada v2.
- **El laboratorio las reproduce** (`agentes.parametros_de_agente`
  traduce `precio_min_accion` y `adx_min`): sus hipótesis de los lunes se
  prueban con sus reglas reales.
- **El escáner** dice si Audacia v2 tomaría la señal teniendo en cuenta el
  precio. El ADX de Cadencia v2 no viene en la señal: ese filtro lo
  aplica la base de datos, y en el escáner Cadencia v2 puede salir como
  «la tomaría».

**Añadir saldo** (`rpc_aportar_saldo_agente`, Administración → Agentes):

- Solo un administrador, solo fuera del grupo de control, de 10 a
  100.000 $.
- Apunte `aportacion` en el libro mayor. Sube también el saldo inicial de
  la cuenta, que pasa a ser la suma de lo aportado: la rentabilidad se
  mide sobre todo el capital y la base para operar (0055) crece con él.
- Queda en `auditoria_admin` y como evento del agente.
- El cuadre del libro mayor cuenta la aportación como un depósito más.
- **Efecto que conviene saber**: si se aporta en mitad de un día, la meta
  diaria de ese día cuenta la aportación como ganancia. La meta ya es
  informativa (§3); la expectativa en R y el veredicto no se ven
  afectados. Pasar de 1.000 $ puede llevar la cuenta a Fase 2 (tope 3×)
  con la regla de siempre.

**Cuándo se sabrá algo**: con 30 cierres, el veredicto dice si se retiran
o siguen en observación (§3.2). Para validar hace falta una expectativa
claramente mayor que la del laboratorio (§3.3).
