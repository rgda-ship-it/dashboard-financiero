# Fase 3 — Lo que faltaba del ADX

> **Para qué sirve**: responde al documento que trajo el dueño el
> 2026-10-26 («Estrategias de trading avanzadas con ADX»). Comparado con la
> 0049 (doc fase-3/05), solo teníamos el **nivel** del ADX (≥ 25 y < 20).
> Faltaban la **dirección** (+DI/−DI), la **pendiente**, el **tope de 40**
> («tendencia madura, no abrir»), el **Santo Grial** de Raschke, la media
> de 200 con ADX y el **giro ADX + RSI**.
> **Método**: todo en el laboratorio, sin tocar producción. El criterio de
> siempre: tramo de validación (el 30 % final), intervalo del 90 % por
> encima de cero, al menos 30 operaciones y superar al 90 % de 20 tiradas
> al azar con el mismo contexto y las mismas salidas. Solo largos: los
> cortos no tienen ventaja (doc fase-3/02) y la regla protegida nº2 sigue.

---

## 1. Qué se añadió (solo laboratorio)

| Pieza | Regla |
|---|---|
| `di_alcista` | +DI(14) > −DI(14) |
| `adx_subiendo` | ADX(14) mayor que hace 3 días |
| `adx_no_agotado` | ADX(14) ≤ 40 |
| `adx_20_40` | 20 ≤ ADX(14) ≤ 40 |
| `santo_grial` | ADX > 30 con +DI > −DI; primer toque de la EMA de 20 desde que el ADX cruzó 30; compra al superar el máximo de la vela anterior (la orden baja con cada vela, hasta 10 días); stop bajo el mínimo desde el toque; objetivo en el máximo del impulso |
| `giro_adx_rsi` | RSI(14) < 30 con ADX > 45 en los últimos 3 días; hoy el ADX baja y el cierre supera el máximo de ayer; stop bajo el mínimo de 5 días; objetivo a 2R o salida con el RSI en 50 |
| `tendencia` con `adx_min` | la ruptura del agente Tendencia cripto, solo si el ADX supera `adx_min` y sube |

- Los cuatro filtros viven en `FILTROS_LABORATORIO`, aparte del catálogo
  `CONDICIONES`: producción no guarda +DI/−DI y el catálogo tiene que ser
  el mismo en SQL y en Python. Si alguno validara, se subiría allí.
- Referencias al azar: `azar_grial` (días al azar con ADX > 30 y +DI >
  −DI, mismos niveles) y `azar_giro` (días al azar con RSI < 35, mismas
  salidas).
- Aproximación: con velas diarias, la orden de compra en el máximo
  (*buy stop*) se modela como un cierre por encima y la compra en la
  apertura siguiente, igual que `retroceso`.

## 2. Resultados

### 2.1 Filtros sobre los tres agentes con metas (45 activos de producción)

**Ninguno pasa, ni a 5 ni a 10 años.** Validación:

| Filtro | Prudencia 10 a (−0,02 R) | Cadencia 10 a (+0,04 R) | Audacia 10 a (+0,07 R) |
|---|---|---|---|
| `di_alcista` | 15 ops | 12 ops | +0,07 R, 30 ops |
| `adx_subiendo` | +0,03 R, 88 ops (p70) | +0,11 R, 36 ops (p50) | −0,07 R (p30) |
| `adx_no_agotado` | −0,05 R (p25) | +0,04 R (p80) | +0,03 R (p60) |
| `adx_20_40` | −0,07 R (p25) | +0,06 R (p80) | −0,01 R (p40) |
| `adx_fuerte+di_alcista` | 1 op | 0 ops | 5 ops |
| `adx_fuerte+adx_subiendo` | +0,06 R (p75) | +0,33 R, 20 ops | −0,11 R (p25) |

A 5 años, lo mismo: nada mejora más de +0,05 R con 30 operaciones y el
intervalo sobre cero.

- **+DI/−DI deja a los agentes casi sin entradas** (de 100–230 a 0–30).
  Confirma lo del doc 05: compran **retrocesos**, y en un retroceso domina
  −DI.
- **«No abrir con el ADX por encima de 40» empeora** a Prudencia y a
  Audacia: esas entradas no eran peores que las demás.
- **El ADX subiendo** solo apunta en Cadencia, con pocas operaciones (36 y
  20), como el `adx_fuerte` del doc 05. Nada nuevo que añadir a lo ya
  guardado («Cadencia solo con ADX ≥ 25», para el final del experimento).

### 2.2 Las estrategias del documento, a 10 años

| Estrategia · universo | Diseño | Validación | Azar (mediana) | Supera al | Pasa |
|---|---|---|---|---|---|
| Santo Grial · acciones de producción | −0,27 R, 228 ops | +0,02 R, 109 ops | +0,08 R | 35 % | ❌ |
| Santo Grial · S&P 100 | +0,03 R, 787 ops | +0,12 R, 397 ops, IC [+0,01, +0,22] | +0,03 R | 85 % | ❌ |
| **Santo Grial · cripto** | **+0,21 R**, 184 ops | **+0,40 R**, 98 ops, IC [+0,20, +0,61] | +0,06 R | **100 %** | ✅ |
| Giro ADX+RSI · acciones de producción | +0,05 R, 48 ops | −0,00 R, 30 ops | +0,22 R | 30 % | ❌ |
| Giro ADX+RSI · S&P 100 | +0,28 R, 112 ops | +0,16 R, 43 ops | +0,23 R | 35 % | ❌ |
| Giro ADX+RSI · cripto | +0,21 R, 41 ops | −0,12 R, 18 ops | +0,07 R | 30 % | ❌ |

- **El giro ADX + RSI no aporta**: comprar en sobreventa al azar con las
  mismas salidas rinde igual o más. El clímax del ADX no añade nada, y la
  combinación se da muy pocas veces.
- **El Santo Grial pasa en cripto** y roza el aprobado en el S&P 100. En
  acciones de producción, no. Ver §3.

### 2.3 Tendencia cripto con ADX (la «media de 200 + ADX > 20 subiendo»)

| Validación | 10 años | 5 años |
|---|---|---|
| Tendencia, la regla del agente | **+0,86 R**, 197 ops, IC [+0,38, +1,37] | **+0,67 R**, 77 ops |
| Con ADX > 20 y subiendo | +0,60 R, 146 ops | +0,11 R, 67 ops |
| Con ADX > 25 y subiendo | +0,49 R, 116 ops | +0,19 R, 52 ops |

**El filtro empeora a Tendencia cripto.** El ADX llega tarde y deja fuera
las primeras rupturas, que son las mejores: es el retraso que el propio
documento advierte. La regla del agente no se toca (además, está fijada
hasta su veredicto, doc 07 §6).

## 3. El Santo Grial en cripto: robustez

`python -m laboratorio.robustez --estrategia santo_grial --clase cripto --periodo 10y`
(14 criptos de producción; validación desde el 2023-10-26):

| Prueba | Resultado |
|---|---|
| Referencia | ✅ +0,40 R, 98 ops, IC [+0,18, +0,62]; remuestreando meses, [+0,12, +0,67] |
| ¿Un solo activo? | ✅ 12 de 14 positivos; sin los tres mejores (tron, litecoin, chainlink) sigue en +0,22 R, IC [+0,01, +0,46] |
| ¿Un solo año? | ✅ positivo en 7 de 10 años; pierde en 2018, 2022 y 2023 (mercado bajista) |
| ¿Solo con estos parámetros? | ✅ 7 de 9 variantes pasan (ADX 25–35, espera 5–15) y las 9 son positivas |
| ¿Spread tres veces peor? | ✅ +0,38 R |
| **¿Con las criptos del top de 2021?** | ❌ **−0,14 R en validación** (154 ops, IC [−0,30, +0,03]); todo el histórico, +0,04 R |

**Es el mismo resultado que dio Tendencia cripto**: real en el universo de
hoy, pero no se sostiene con criptos elegidas con la información de
entonces. Con las que luego se hundieron (FTT, MANA, VET, NEAR, HBAR…),
comprar el retroceso de una tendencia fuerte pierde: la tendencia se
rompe en vez de reanudarse. Parte de la ventaja es haber elegido hoy las
que sobrevivieron.

Frente a Tendencia cripto, el Grial rinde la mitad por operación (+0,40
frente a +0,86 R) y tiene menos caída (7 % frente a más del 20 %).

## 4. Qué se decide

- **No hay ningún filtro de ADX que adoptar** en los agentes con metas.
  Los cuatro filtros quedan en el laboratorio (`FILTROS_LABORATORIO`) y no
  suben al catálogo de producción.
- **La regla de Tendencia cripto no cambia**: el filtro de ADX la empeora.
- **El giro ADX + RSI queda descartado.**
- **El Santo Grial en cripto: real pero no demostrado**, como Tendencia
  cripto. No se crea un agente ahora. Si el dueño quisiera un segundo
  experimento en vivo, sería el candidato, con un criterio de retirada
  fijado de antemano como el del doc 07 §6. Por defecto, no: antes hay
  que ver el veredicto de Tendencia cripto (30 operaciones), que es la
  misma apuesta (que el universo cripto de hoy siga en tendencia).
- **La lección del documento que sí se confirma** es la advertencia
  final: el ADX va rezagado y no sirve como gatillo. En nuestros agentes,
  que compran retrocesos, tampoco sirve como filtro.
