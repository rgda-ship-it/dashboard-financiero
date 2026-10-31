# Cronología: cuándo cambiaron las reglas

> **Para qué sirve**: antes de sacar conclusiones de los datos de
> producción, mirar aquí **desde qué fecha son comparables**. Una y otra
> vez hemos encontrado «fallos» que eran datos de reglas anteriores: los
> stops a 0,1 ATR de antes de la 0030, la concordancia del laboratorio
> medida desde el alta, las señales añejas de antes de la 0029…
> **Regla práctica**: para juzgar a un agente con metas, usa solo datos
> **desde el 2026-10-17** (0043) y, si miras salidas por deterioro, desde
> el **15-10** separa a Cadencia y Audacia (lo apagaron solas), y Prudencia
> no salió por deterioro entre el **29-10** y la 0053. Para
> Tendencia cripto, desde el **12-10**.
> **Cómo mantenerlo**: cada migración que cambie cómo opera un agente, el
> ETL o el simulador añade aquí su fila, en el mismo PR. Las
> intervenciones manuales y los ajustes automáticos, también.
> Horas en UTC. La fecha es la de aplicación en producción; si no consta
> la hora, la del día.

---

## 1. Fechas de corte para analizar datos

Lo más importante de este documento. Cada fila dice qué datos de antes
**no** se pueden mezclar con los de después.

| Desde | Qué cambió | No mezclar con lo anterior |
|---|---|---|
| 2026-09-29 12:07 | Los tres agentes con metas, en marcha (0013) | — |
| 2026-10-02 | Saldo para operar (0022–0023): sin tope de posiciones (G4 fuera) | Número de posiciones abiertas |
| 2026-10-02 | Salida por deterioro de la señal (0024), con una sola lectura | Cierres por deterioro |
| 2026-10-05 | Prudencia admite fuerza media (0026); Cadencia y Audacia se separan por volatilidad (0027) | Entradas de Prudencia, Cadencia y Audacia |
| **2026-10-06** | El ETL refresca todo el catálogo activo (0029) | Descartes por señal añeja (antes, cientos al día) |
| **2026-10-10 21:31** | **0030 (D21)**: stop y objetivo acotados en ATR (stop entre 1 y 2 ATR), el RSI no vota contra el MACD, riesgo abierto total (G6); R:R mínimo nuevo (Prudencia 2,0 → 1,5, Cadencia 1,5 → 1,3) | **Todo**: stops a 0,1 ATR antes, R de las órdenes, entradas, concordancia del laboratorio |
| 2026-10-10 | 0031–0033: horizonte estimado, autodiagnóstico semanal, cripto prudente (D22), huecos reales en el simulador (M3') | Tamaño en cripto; cierres con hueco |
| 2026-10-10 / 10-11 | 0034–0036: el spread se cobra (D23) y se mide | Precio de entrada y salida, P&L |
| 2026-10-09 → 10-13 | **Cuarentena** de los tres: solo fuerza alta, una posición; casi no operan | Frecuencia de entradas |
| 2026-10-12 | Tendencia cripto decide (0037–0040); pausa por caída al 35 % (0039) | — (nace aquí) |
| 2026-10-13 | 0041: el spread de Nasdaq no se mide ni se cobra (Yahoo daba cotizaciones congeladas) | Spread de AAPL, AMZN, MSFT, NVDA, SPCX |
| 2026-10-13 | 0042: fuera de la cuarentena; `consecuencias_semanales = false` durante el experimento | Notas semanales con consecuencias |
| 2026-10-15 13:40 | **Ajuste automático**: Audacia apaga la salida por deterioro (17 decisiones, −0,66 de efecto medio) | Cierres de Audacia |
| 2026-10-15 19:40 | **Ajuste automático**: Cadencia apaga la salida por deterioro (16 decisiones, −0,11) | Cierres de Cadencia |
| **2026-10-17** | 0043: deterioro confirmado en **dos** lecturas; 48 h sin volver a un activo tras su stop | Cierres por deterioro (solo Prudencia lo usa ya); reentradas tras stop |
| 2026-10-17 | 0044: disparadores del backlog más exigentes | Ocurrencias del backlog |
| 2026-10-24 | 0045: la toma parcial se salta la posición de 1 acción (antes deshacía el ciclo) | Fallos de ciclo |
| 2026-10-24 | 0046–0047: hipótesis semanales y registro de descartes | — (nacen aquí) |
| 2026-10-25 | 0048–0049: seguimiento tras el stop; ADX y media de 20 (el ETL los escribe desde ese día) | — |
| 2026-10-29 13:40 | **Ajuste automático**: Prudencia apaga la salida por deterioro (10 decisiones, −0,22; 7 de antes de la 0043). Desde aquí ninguno de los tres sale por deterioro | Cierres de Prudencia |
| 2026-10-29 | **Hackeo a Binance**: todo cripto cae entre un 4 y un 10 % en el día, salvo tron (ver §5) | Resultados de cripto de esos días |
| 2026-10-31 | 0052: ajustes automáticos congelados mientras `consecuencias_semanales = false` | — (las reglas dejan de moverse solas) |
| Al aplicarla | 0053: Prudencia vuelve a salir por deterioro (decisión del dueño; deshace el ajuste del 29-10) | Cierres de Prudencia entre el 29-10 y la 0053 |
| 2026-10-26 | 0050–0051: credenciales; backlog revisado | Backlog: «Ampliar el universo» ya no salta por el R:R |

## 2. Incidentes que dejan huecos en los datos

| Desde → hasta | Qué pasó | Efecto |
|---|---|---|
| hasta 2026-10-06 | El ETL solo refrescaba los activos que alguien seguía | Señales congeladas en 4 activos; descartes por antigüedad |
| 2026-10-19 → 10-20 | La toma parcial de 1 acción de AMZN deshacía el ciclo (8 fallos de Cadencia, 2 de Prudencia) | Ciclos sin entradas ni salidas esas horas |
| **2026-10-23 19:07 → 10-24 13:07** | Token de GitHub caducado (401): el ETL no se lanzaba desde la base de datos | Señales viejas; 650 y 1.570 descartes por antigüedad; sin decisiones de acciones frescas |

## 3. Intervenciones manuales

| Fecha | Quién | Qué |
|---|---|---|
| 09-30, 10-02, 10-05, 10-07, 10-08, 10-12, 10-15, 10-22, 10-24 | Admin | **Reversión manual a Fase 1** (tope 5×): 12 veces, sobre las cuentas 4 (Prudencia, 1), 5 (Cadencia, 6) y 6 (Audacia, 5). Cada una cambia el apalancamiento máximo de esa cuenta hasta que vuelve sola a Fase 2 |
| 2026-10-11 11:23 | Dueño | Pone en marcha a Tendencia cripto |
| 2026-10-26 | Dueño | `github_pat_altas` anotado como «no caduca» |
| Al aplicar la 0053 | Dueño | Prudencia vuelve a salir por deterioro (deshace su ajuste automático del 29-10) |

## 4. Mecanismos que cambian las reglas solos

Aunque el grupo de control no se toca a mano durante el experimento, hay
tres cosas que **pueden cambiar** su comportamiento sin que nadie lo decida:

1. **Ajustes automáticos (0016, 0024)**: con 10 decisiones resueltas de
   un tipo, el agente cambia por su cuenta la rotación, la toma parcial,
   el reparto o la salida por deterioro, según su efecto medio. Quedan en
   `agente_ajustes` y suben la versión de la estrategia. Hasta hoy, solo
   los dos del 15-10 y el del 29-10 (deshecho a mano por la 0053). **Congelados desde la 0052** (31-10) mientras
   `consecuencias_semanales = false`: vuelven al acabar el experimento.
2. **Fase 1 / Fase 2**: una cuenta pasa sola a Fase 2 (tope 3×) al cumplir
   su criterio, y vuelve a Fase 1 solo a mano (regla protegida nº5).
3. **Pausa por caída** de Tendencia cripto (35 %, 0039).

Para saber con qué reglas operaba un agente en una fecha:
`select * from agente_estrategia_versiones where agente_id = … order by version`
y `select * from agente_ajustes order by creado_en`.

## 5. Sucesos de mercado

Movimientos que no vienen de ningún indicador. No son fallos del sistema,
pero explican resultados que, sin contexto, parecerían de una regla.

| Fecha | Suceso | Efecto en nuestros datos |
|---|---|---|
| 2026-10-29 (tarde, UTC) | Hackeo a Binance, unos 6.300 M$ según el informe del dueño (doc fase-3/09) | bitcoin −4,2 %, ethereum −4,6 %, binancecoin −8,2 %, el resto de cripto entre −5 y −10 %; tron +6,9 % y lo devuelve en dos días. Tres stops de cripto (−21,74 $) y, el 30-10, tres entradas en el rebote de tron, todas a su stop (la primera operación de Tendencia cripto, −1 R). Acciones: +0,5 % el 29-10 y −2,0 % el 30-10 de media |
