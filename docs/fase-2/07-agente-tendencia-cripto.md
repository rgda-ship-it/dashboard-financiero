# G. Agente experimental «Tendencia cripto»

> **Autor**: Analista Cuantitativo / Risk Manager (equipo virtual)
> **Fecha**: 2026-10-11
> **Estado**: **Aprobado por el dueño (D24, opción A)**. Diseño cerrado;
> implementación pendiente (migración 0037). La lista de control está en
> [`../ESTADO.md`](../ESTADO.md).
> **Contexto**: el laboratorio (doc 06 §3.7) encontró una sola estrategia
> con ventaja, tendencia en cripto, y la prueba de robustez la dejó en
> «real pero no demostrada». Este documento dice cómo llevarla al
> simulador para comprobarla en vivo y cuándo retirarla.

---

## 1. Por qué un agente experimental y no uno «validado»

El doc 06 §2 dice que solo recibe agente una estrategia con ventaja
demostrada. Tendencia cripto pasó el laboratorio, pero la prueba de
robustez cumplió **3 de 4** criterios:

| Criterio (doc 06 §3.7) | Resultado | ¿Cumple? |
|---|---|---|
| La referencia sigue en pie con el intervalo por meses (correlación) | [+0,02, +1,49] R | ✅ |
| No depende de un activo | **Sin zcash, +0,13 R y el intervalo incluye el cero**; zcash da ~46 de los ~54 R de la validación | ❌ |
| La mayoría de variantes de parámetros, positivas | 45 de 45 positivas (18 pasan el criterio completo) | ✅ |
| Positiva con las criptos del top de 2021 (supervivencia) | +0,65 R en 5 años; +0,09 R en el tramo de validación | ✅ (justo) |

Otras señales: 13 de 14 criptos del universo con expectativa positiva;
2024 aporta 169 de 216 R; con spread ×3 la validación se queda en
+0,63 R pero el intervalo roza el cero (−0,02).

**Lectura**: hay algo real (gana en casi todas las monedas, en todas las
variantes y en monedas que nunca vio), pero su forma es «pocas ganancias
enormes», y cinco años no bastan para separar la ventaja de la suerte de
haber cogido zcash y 2024. Fuera de esas rachas, la expectativa ronda
+0,1 R.

**Decisión D24 (dueño, 2026-10-11)**: crearlo como **agente experimental**
en el simulador, con un criterio de retirada fijado de antemano (§6). El
dinero es simulado, así que el coste de equivocarse es bajo, y operar en
vivo es la única validación que el histórico no puede dar.

---

## 2. La estrategia, exactamente como se probó

Es `Tendencia` de `motor-analitico/laboratorio/estrategias.py` con sus
parámetros por defecto. **No se cambian**: cualquier ajuste invalida lo
medido y obliga a repetir laboratorio y robustez.

| Pieza | Regla | Parámetro |
|---|---|---|
| Filtro de fondo | Cierre diario > media de 200 cierres | `sma_fondo = 200` |
| Entrada | Cierre diario > máximo de los 20 días anteriores (sin contar hoy) | `ruptura = 20` |
| Stop inicial | Cierre − 2 ATR(14) | `stop_atr = 2.0` |
| Stop que sigue | Mejor cierre desde la entrada − 3 ATR(14); **nunca baja** | `sigue_atr = 3.0` |
| Salida por regla | Cierre diario < mínimo de los 10 días anteriores → vender en la siguiente decisión | `salida = 10` |
| Objetivo | **Ninguno**: deja correr lo que funciona | — |
| Universo | Las criptos activas del catálogo (14 hoy, zcash incluida) | — |
| Una posición por activo | Sí | — |

Se mantiene zcash. Quitarla ahora, sabiendo que fue la mejor, sería elegir
con el diario de mañana: el mismo sesgo que la prueba de supervivencia
intenta evitar.

---

## 3. Del laboratorio al simulador

El laboratorio trabaja con velas diarias; el simulador, con precios cada
pocos minutos. La traducción:

| Laboratorio | Simulador | Nota |
|---|---|---|
| Señal al cierre del día t | **Una decisión al día por activo**, después del cierre diario de cripto (00:00 UTC), en cuanto el ETL haya escrito la vela de ayer de ese activo en `precios_diarios` | Cron propio cada hora de 00:20 a 06:20 UTC; cada activo se decide una sola vez al día. No el ciclo de 5 min de los agentes con metas |
| Entrada en la apertura de t + 1 + medio spread | Orden a mercado en esa decisión, al precio de compra (`fn_precio_compra`, D23) | Mismo precio en la práctica: la apertura de t + 1 es el precio de las 00:00 |
| Stop con el mínimo del día | El monitor (`fn_monitorear_ordenes`, cada minuto) con el precio de venta; huecos con M3' | Igual o más fino que en el laboratorio |
| Stop que sigue, al cierre | La decisión diaria **sube** `sl` de cada orden abierta si el nuevo es mayor | Requiere una función nueva (§4) |
| Salida por regla en la apertura siguiente | La decisión diaria cierra a mercado (`rpc_cerrar_orden`, precio de venta) | Motivo de cierre nuevo: `regla` |
| ATR, máximo de 20 y mínimo de 10 con máximos y mínimos reales | `precios_diarios`: en cripto solo los **últimos 30 días** tienen máximo y mínimo reales (`rango_real`) | Basta: ATR(14), máx. 20 y mín. 10 caben en 30 días. La media de 200 usa solo cierres |
| Velas de Yahoo | Velas de CoinGecko | Cierres casi iguales; máximos y mínimos pueden diferir algo. Riesgo aceptado (§7) |

---

## 4. Lo que hay que construir (migración 0037)

Propuesta técnica para el siguiente chat. Los nombres son orientativos.

1. **Tipo de agente.** Columna `agentes.tipo` (`metas` | `estrategia`).
   Los agentes con metas no cambian. En `estrategia`,
   `objetivo_diario_pct` no aplica: o se hace opcional (hoy es `not null`
   y `> 0`) o se le da un valor nominal ignorado. Preferible opcional con
   un `check` por tipo, para que el panel no muestre una meta falsa.
2. **Órdenes sin objetivo.** Hoy `ordenes.tp` es `not null` con
   `tp > precio_entrada`. Hacerlo opcional (`tp is null or tp > precio_entrada`)
   y revisar todo lo que lo lee: monitor, tomas parciales, rotación,
   deterioro, estimación de horizonte (0031), `v_coste_spread`, R:R, el
   frontend. Alternativa sin tocar el esquema: un `tp` lejano (p. ej. 100×);
   es más rápido pero ensucia las medidas de R:R y horizonte. Recomendado:
   opcional.
3. **Subir el stop.** `fn_subir_stop(orden_id, nuevo_sl)`: solo sube,
   nunca por encima del precio de venta actual, deja rastro en el
   racional. Es la herramienta «trailing stop» que el backlog autónomo ya
   preveía (`nueva_herramienta:trailing_stop`, 0013/0029).
4. **Motivo de cierre `regla`.** Ampliar el `check` de `motivo_cierre`.
5. **Decisión diaria.** `fn_decidir_tendencia(agente_id)`:
   - Calcula SMA200, ATR14, máx. 20 y mín. 10 desde `precios_diarios`.
   - Para cada orden abierta: sube el stop (§2) o cierra por regla.
   - Para cada cripto sin posición que cumple la entrada: abre con el
     tamaño del §5.
   - Registra la decisión en `agente_decisiones`, con los descartes y su
     motivo, como los demás agentes.
6. **Cron** `decision-tendencia` cada hora de 00:20 a 06:20 UTC
   (`20 0-6 * * *`). El ETL de cripto corre a los :07 de cada hora, pero
   **no refresca todas las criptos en cada pasada**: las que tienen una
   posición abierta van en todas y el resto rota por antigüedad
   (`etl-cripto.yml`). Por eso cada activo se decide en la primera pasada
   en que ya tiene la vela de ayer, y una sola vez al día. Si a las 06:20
   sigue sin ella, se registra como descarte `sin_vela`. Las posiciones
   abiertas, que son las urgentes (stop que sigue, salida por regla), se
   refrescan en la primera pasada.
7. **Alta del agente** «Tendencia cripto», en estado `pausado`, con saldo
   inicial de 500 $ como los demás. El dueño lo activa desde /admin.
8. **Invariantes** nuevas en `supabase/pruebas/01_invariantes.sql`: el
   stop nunca baja; sin objetivo, el monitor no cierra por `tp`; entrada
   solo con ruptura y SMA200; cierre por regla; tamaño del 1 %; G6
   respetado.
9. **Frontend**: el agente aparece en la vista de agentes sin meta diaria;
   muestra expectativa en R, operaciones y el criterio de retirada (§6).

---

## 5. Tamaño y guardarraíles

- **Riesgo por operación: 1 % del equity** (como en la caída máxima del
  laboratorio): `cantidad = 0,01 × equity / (precio_compra − sl)`.
- **Sin meta que perseguir**: ni sube el riesgo por ir por detrás ni lo
  baja por ir por delante.
- **G1–G3 y G5** se aplican igual (los valida `rpc_abrir_orden`).
- **G6 (riesgo abierto ≤ 4 × riesgo por operación)**: con 1 %, como máximo
  4 % del equity en juego a la vez. `fn_riesgo_abierto` ya cuenta solo lo
  que queda por debajo de la entrada, así que cuando el stop que sigue
  pasa del precio de entrada la posición deja de consumir riesgo y caben
  más. Es justo lo que pide una estrategia de tendencia.
- **Prioridad cuando no caben todas**: la ruptura más fuerte (cierre sobre
  el máximo de 20, medido en ATR). Hay que añadirla también al laboratorio
  para medirla; hoy el laboratorio abre todas.
- **Saldo mínimo**: con 500 $ y un 1 % de riesgo, se arriesgan 5 $ por
  operación. Hay que comprobar que la cantidad resultante supera el mínimo
  operable de cada cripto.

---

## 6. Cómo se evalúa y cuándo se retira

Fijado **antes** de empezar, para no moverlo según el resultado.

| Momento | Qué se mira | Decisión |
|---|---|---|
| Primeras 5 operaciones | Que entra, sube el stop y sale como en el laboratorio (comparando con `laboratorio` sobre las mismas fechas) | Corregir errores; **no** juzgar la ventaja |
| Cada lunes | Expectativa en R, operaciones, caída máxima, comparada con el grupo de control | Solo informar |
| **30 operaciones cerradas** | Expectativa en R y su intervalo | **Expectativa < 0 → se pausa y se retira.** Entre 0 y +0,10 R → sigue en observación hasta 60. > +0,10 R → pasa a «validado en vivo» |
| Caída máxima > 15 % del equity | — | Se pausa y se revisa (en el laboratorio la peor fue del 6,8 % en validación y del 16,8 % en diseño) |

**Cuánto tarda**: el laboratorio dio unas 79 operaciones en 18 meses
sobre 14 criptos, unas **4–5 al mes**. Las 30 operaciones llegarán en
**6–7 meses**, y antes si el mercado cripto es alcista. Es lento a
propósito: la estrategia no opera cuando el mercado está bajo su media de
200 días (en 2022 hizo 10 operaciones en todo el año).

---

## 7. Riesgos conocidos

| Riesgo | Mitigación |
|---|---|
| La ventaja dependía de zcash y de 2024 | Criterio de retirada del §6; panel con R por activo |
| El régimen cambia (mercado bajista largo) | Lo esperado es que casi no opere; no es un fallo. El §6 cuenta operaciones, no días |
| Velas de CoinGecko frente a las de Yahoo | En las primeras 5 operaciones, comparar entradas y salidas con el laboratorio sobre las mismas fechas |
| Huecos de rango real en `precios_diarios` (ETL caído) | La decisión diaria descarta el activo si faltan velas con rango real en los últimos 20 días y lo registra |
| Cambios de parámetros «para mejorar» | Prohibidos sin repetir laboratorio y robustez (§2) |

---

## 8. Decisiones abiertas del dueño

Ninguna bloquea la implementación; tienen valor por defecto.

1. **Saldo inicial**: 500 $ como los demás (por defecto) o más para evitar
   el problema del mínimo operable.
2. **Visibilidad**: que los usuarios vean el agente desde el principio
   (por defecto) o solo /admin hasta las primeras 5 operaciones.
