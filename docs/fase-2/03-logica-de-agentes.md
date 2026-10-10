# C. Lógica de los agentes y reglas de negocio

> **Autor**: Analista Cuantitativo / Risk Manager (equipo virtual), con Backend Developer
> **Fecha**: 2026-09-20
> **Estado**: Propuesta
> **Destinatario**: Backend Developer — este documento es la especificación
> ejecutable. Si algo aquí es ambiguo, es un bug de este documento.

---

## 1. Análisis de viabilidad: qué piden de verdad las metas de 2 %, 5 % y 7 %

Antes de escribir una línea de pseudocódigo hay que poner los números sobre
la mesa, porque condicionan todo el diseño.

### 1.1 Cuánto tarda cada agente en llegar al millón

Partiendo de 500 $ con interés compuesto diario, hasta 1.000.000 $ (un factor
de 2.000×):

| Agente | Meta diaria | Días necesarios | En meses de mercado |
|--------|-------------|-----------------|---------------------|
| **Prudencia** | 2 % | **384 días** | ~18,3 meses |
| **Cadencia** | 5 % | **156 días** | ~7,4 meses |
| **Audacia** | 7 % | **113 días** | ~5,3 meses |

`n = ln(2000) / ln(1 + p)`. No son cifras aproximadas: es la trayectoria
exacta si **todos** los días se cumple la meta.

### 1.2 Qué movimiento del subyacente exige cada meta

Aquí está el problema real. Con el tope duro de 5× de la Fase 1 y el
guardarraíl de no comprometer más del 60 % del saldo (§4), el movimiento
favorable que el activo tiene que hacer **en un día** es:

| Meta diaria | A 5× con 100 % comprometido | A 5× con 60 % comprometido | A 3× (Fase 2) con 60 % |
|-------------|------------------------------|----------------------------|-------------------------|
| 2 % | 0,40 % | **0,67 %** | 1,11 % |
| 5 % | 1,00 % | **1,67 %** | 2,78 % |
| 7 % | 1,40 % | **2,33 %** | 3,89 % |

Lectura honesta de esta tabla:

- **Prudencia (2 %)** pide un 0,67 % diario. Alcanzable con regularidad en
  acciones con confluencia alta. Es una meta exigente pero no fantasiosa.
- **Cadencia (5 %)** pide un 1,67 % diario. Es el ATR% típico de una acción
  volátil o de una cripto tranquila: **hay que acertar la dirección casi
  siempre**, no solo capturar el rango.
- **Audacia (7 %)** pide un 2,33 % diario sostenido. Solo el bloque cripto
  tiene ese recorrido con regularidad, y ni siquiera todos los días. Con el
  ATR% de BTC en 2,61 y el de ETH en 3,65 (cifras medidas en el CHANGELOG
  tras corregir la vela diaria), **Audacia necesita capturar casi el ATR
  entero, en la dirección correcta, cada día.**

### 1.3 La trampa que el diseño tiene que cerrar

Si un agente puede comprometer el 100 % de su saldo en una sola operación, la
estrategia matemáticamente óptima para Audacia es **apostarlo todo cada
día**: maximiza la probabilidad de tocar el 7 %, y el coste de fallar (Game
Over) es simétrico al coste de no cumplir la meta repetidamente. Un agente
racional sin guardarraíles se arruina en la primera semana, y el experimento
no produce ningún dato interesante — solo tres tumbas.

De ahí los guardarraíles duros de §4. **No son una concesión a la prudencia:
son lo que hace que el experimento dure lo suficiente para generar datos.**

### 1.4 La tensión estructural con la máquina de fases

`maquina_fases.py` transiciona a Fase 2 cuando el capital alcanza **3× el
inicial** — es decir, a los 1.500 $. En Fase 2 el tope de apalancamiento baja
de 5× a 3×.

| Agente | Días hasta 1.500 $ | Qué pasa entonces |
|--------|--------------------|--------------------|
| Prudencia (2 %) | ~56 días | Tope 5× → 3×. La meta pasa a exigir 1,11 % diario |
| Cadencia (5 %) | ~23 días | Tope 5× → 3×. La meta pasa a exigir 2,78 % diario |
| Audacia (7 %) | ~17 días | Tope 5× → 3×. La meta pasa a exigir **3,89 % diario** |

Y la regla protegida nº5 es explícita: **volver a Fase 1 exige acción manual
del humano**. Ningún agente puede revertirse a sí mismo.

Esto significa que los tres agentes, si tienen éxito, **se estrangulan a sí
mismos entre las semanas 3 y 8**. No es un fallo del diseño: es el modelo de
riesgo de la Fase 1 haciendo exactamente lo que se diseñó para hacer —
frenar la aceleración cuando el capital ha crecido.

**Decisión de diseño**: no se toca. El agente detecta la situación, abre una
entrada en `agente_backlog` de tipo `reversion_fase` con la evidencia
numérica, y sigue operando bajo el tope nuevo. La frecuencia con que los tres
agentes pidan esa reversión, y el rendimiento que logren bajo 3×, es el dato
que debe informar si la Fase 3 cambia el umbral. Es el bucle del requisito 8
funcionando sobre el problema más real que tiene el sistema.

---

## 2. Arquitectura del agente: determinista, con capa narrativa opcional

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                    CICLO DE AGENTE (cada 5 min)                  │
  │                                                                  │
  │   ENTRADA (todo de la BD, cero llamadas a APIs externas)         │
  │   · senales_vigentes         · agente_dias (fila de hoy)         │
  │   · cuentas_simulacion       · mejores_practicas adoptadas       │
  │   · ordenes abiertas         · agentes.estrategia (jsonb)        │
  │                       │                                          │
  │                       ▼                                          │
  │   ┌────────────────────────────────────────────┐                 │
  │   │  MOTOR DETERMINISTA  (TypeScript, Edge Fn) │                 │
  │   │  1. sincronizar_dia()                      │                 │
  │   │  2. comprobar_game_over()                  │                 │
  │   │  3. calcular_deficit()                     │                 │
  │   │  4. filtrar_candidatos()                   │                 │
  │   │  5. ordenar_candidatos()                   │                 │
  │   │  6. dimensionar_posicion()                 │                 │
  │   │  7. rpc_abrir_orden()                      │                 │
  │   │  8. detectar_disparadores_backlog()        │                 │
  │   │  9. destilar_practica() (tras un cierre)   │                 │
  │   └───────────────────┬────────────────────────┘                 │
  │                       │ decisión ya tomada                       │
  │                       ▼                                          │
  │   ┌────────────────────────────────────────────┐                 │
  │   │  CAPA NARRATIVA (OPCIONAL, apagada)        │                 │
  │   │  Redacta `ordenes.racional` en prosa y el  │                 │
  │   │  texto de agente_backlog. NUNCA decide.    │                 │
  │   └────────────────────────────────────────────┘                 │
  └──────────────────────────────────────────────────────────────────┘
```

**Por qué determinista** (decisión D4): un agente cuyo cerebro es un LLM no
es reproducible. Si Audacia pierde el 40 % en una semana, con un motor
determinista se puede reejecutar el mismo periodo con el mismo estado y ver
exactamente dónde se rompió; con un LLM, no. Y el coste 0 se mantiene sin
asteriscos.

La capa narrativa, si algún día se enciende, **recibe la decisión ya tomada**
y solo la redacta. No puede vetar, no puede sugerir otro activo, no puede
cambiar el tamaño. Su salida va a un campo de texto, nunca a un campo
numérico.

---

## 3. Los tres agentes

### 3.1 Perfiles

| | **Prudencia** | **Cadencia** | **Audacia** |
|---|---|---|---|
| Meta diaria | 2 % | 5 % | 7 % |
| Saldo inicial | 500 $ | 500 $ | 500 $ |
| Riesgo por operación | 1,5 % del equity | 3,0 % | 5,0 % |
| Máx. posiciones abiertas | 3 | 2 | 2 |
| R:R mínimo exigido | 1,5 (2,0 hasta la 0030, D21) | 1,3 (1,5 hasta la 0030) | 1,2 |
| Fuerza de confluencia mínima | `media` o `alta` (solo `alta` hasta la 0026, D18) | `media` o `alta` | `media` o `alta` |
| Apalancamiento | `min(recomendado, 3)` — se autolimita | `recomendado` | `recomendado` (el tope) |
| Preferencia de volatilidad | ATR% bajo (< 3) | ATR% ≤ 2,3 (indiferente hasta la 0027, D19) | ATR% ≥ 2,3 — necesita recorrido (≥ 1,5 hasta la 0027) |
| Origen de niveles | solo `estructura` | `estructura` o `atr` | cualquiera |
| Margen total comprometido máx. | 40 % del equity | 55 % | 60 % |
| Carácter | Espera el setup perfecto; pocos días operables, alta tasa de acierto | El término medio; opera casi todos los días | Necesita el recorrido de cripto; el que más probablemente haga Game Over |

Las diferencias **no son cosméticas**: cambian qué señales pasan el filtro,
cuánto se arriesga y cuántas posiciones conviven. Si los tres agentes
compartieran parámetros y solo cambiara el número de la meta, los tres
abrirían las mismas órdenes y el experimento no compararía nada.

### 3.2 Esquema de `agentes.estrategia` (jsonb)

Este es el contrato que el motor lee. **Todo parámetro operativo vive aquí**,
nunca en código ni en variables de entorno (resuelve la deuda técnica nº3 de
la Fase 1).

```json
{
  "riesgo_pct_operacion": 5.0,
  "max_posiciones_abiertas": 2,
  "rr_minimo": 1.2,
  "fuerzas_admitidas": ["media", "alta"],
  "clases_admitidas": ["accion", "cripto"],
  "niveles_origen_admitidos": ["estructura", "atr"],
  "apalancamiento_maximo_propio": 5.0,
  "margen_comprometido_max_pct": 60.0,
  "atr_pct_min": 1.5,
  "atr_pct_max": null,
  "antiguedad_senal_max_min": 90,
  "modo_conservacion": {
    "activo": true,
    "accion": "no_abrir_nuevas"
  },
  "practicas_adoptadas": [12, 27],
  "version": 1
}
```

Un cambio en este objeto incrementa `agentes.version_estrategia` y queda
registrado, de modo que `ordenes.racional` pueda apuntar a la versión bajo la
que se decidió cada operación.

---

## 4. Guardarraíles duros — inviolables por cualquier agente

Estos límites los impone PostgreSQL (`rpc_abrir_orden`; G6, un trigger sobre `ordenes` desde la 0030), **no el
código del agente**. Un agente con un bug, una estrategia adoptada con un
valor absurdo o una llamada manual no pueden saltárselos.

| # | Guardarraíl | Valor | Por qué |
|---|-------------|-------|---------|
| G1 | Apalancamiento ≤ tope de la fase de la cuenta | 5× (Fase 1) / 3× (Fase 2) | Regla protegida nº1 de la Fase 1, ahora también `CHECK` en la BD |
| G2 | Riesgo por operación ≤ 10 % del equity | 10 % | Sin esto, Audacia apuesta el saldo entero el primer día (§1.3) |
| G3 | Margen total comprometido ≤ `margen_comprometido_max_pct` | 100 % en los agentes (0023) y por defecto en una cuenta de usuario (0022); antes, 40–60 % según agente | Garantiza que siempre quede saldo libre para el siguiente día. Un agente con el 100 % comprometido no puede operar aunque aparezca el mejor setup del mes. En una cuenta de usuario es «qué parte del saldo para operar quieres usar» (D17) |
| G4 | Posiciones abiertas simultáneas ≤ `max_posiciones_abiertas` | 2–3 | Limita la correlación: tres posiciones en cripto en un mercado que cae son una sola apuesta con tres nombres. Solo agentes desde la 0021; **retirado en la 0023**: cuántas abre un agente lo decide su reparto por exigencia, y solo la cuarentena lo limita a una |
| G5 | Solo señales con `operable = true` y antigüedad ≤ `antiguedad_senal_max_min` | 90 min | Regla protegida nº4: sin volatilidad conocida no se opera. Y una señal de ayer no describe el mercado de hoy |
| G6 | Riesgo abierto total de un agente ≤ 4 × su riesgo por operación (0030, D21) | Prudencia 3 %, Cadencia 6 %, Audacia 10 % del equity con el riesgo reducido de hoy | Con el stop a 1–2 ATR cada stop cuesta el riesgo completo, y el reparto abre varias a la vez en activos que caen juntos. No limita lo perdido en el día: lo que está en juego a la vez. Trigger en `ordenes` |

> **G2 y G3 son la diferencia entre un experimento y un sorteo.** Merece la
> pena entender el efecto combinado: con riesgo del 5 % por operación y
> máximo 60 % de margen comprometido, Audacia necesita **20 pérdidas
> consecutivas** para llegar a cero. Eso le da tiempo a generar entradas de
> `agente_backlog`, escribir prácticas y pasar varios cortes semanales antes
> de morir — que es exactamente lo que hace valioso el experimento.

---

## 5. El ciclo del agente, paso a paso

### 5.1 Pseudocódigo principal

```
FUNCIÓN ciclo_agente(agente):

  // ── 1. Sincronizar el día ─────────────────────────────────────────
  hoy := fecha_actual_UTC()
  dia := obtener_o_crear(agente_dias, agente.id, hoy)

  SI dia.es_nuevo ENTONCES
      // El interés compuesto vive aquí: la base del objetivo de hoy es
      // el saldo con el que hoy AMANECE, no el saldo inicial ni una
      // curva teórica. Si ayer se perdió, hoy la meta es más pequeña
      // en términos absolutos — y esa es la definición de "sobre el
      // saldo compuesto actual".
      dia.saldo_apertura    := equity_actual(agente.cuenta)
      dia.objetivo_importe  := dia.saldo_apertura * agente.objetivo_diario_pct / 100
      dia.operable          := hay_mercado_hoy(agente.estrategia.clases_admitidas)
      cerrar_dia_anterior(agente)          // ver 5.2
  FIN SI

  // ── 2. Game Over antes que nada ───────────────────────────────────
  SI evaluar_game_over(agente.cuenta) ENTONCES
      registrar_evento('game_over', agente)
      agente.estado := 'game_over'
      RETORNAR
  FIN SI

  SI agente.estado NO EN ('activo', 'cuarentena') ENTONCES RETORNAR
  SI NO dia.operable ENTONCES RETORNAR

  // ── 3. ¿Cuánto falta para la meta de hoy? ─────────────────────────
  logrado := SUMA(ordenes.pnl_bruto)
             DONDE cuenta = agente.cuenta
               Y estado = 'cerrada'
               Y fecha_salida::date = hoy

  deficit := dia.objetivo_importe - logrado

  SI deficit <= 0 ENTONCES
      // Meta cumplida. MODO CONSERVACIÓN: no se abren posiciones nuevas.
      // Esta regla es lo que convierte la meta en un objetivo y no en un
      // suelo del que seguir tirando. Sin ella, un agente que cumple el
      // 7 % a las 10:00 sigue operando hasta perderlo.
      dia.cumplido := verdadero
      RETORNAR
  FIN SI

  // ── 4. ¿Hay hueco para otra posición? ─────────────────────────────
  abiertas := CONTAR(ordenes abiertas de agente.cuenta)
  SI abiertas >= estrategia.max_posiciones_abiertas ENTONCES RETORNAR

  margen_usado_pct := cuenta.saldo_bloqueado / equity_actual * 100
  SI margen_usado_pct >= estrategia.margen_comprometido_max_pct ENTONCES RETORNAR

  // ── 5. Filtrar candidatos (todo desde senales_vigentes) ───────────
  candidatos := senales_vigentes
      DONDE operable = verdadero
        Y AHORA() - calculado_en <= estrategia.antiguedad_senal_max_min
        Y fuerza EN estrategia.fuerzas_admitidas
        Y activo.clase EN estrategia.clases_admitidas
        Y activo.estado = 'activo'
        Y niveles_origen EN estrategia.niveles_origen_admitidos
        Y ratio_rr >= estrategia.rr_minimo
        // Regla protegida nº3: dominancia ESTRICTA. Aquí se compromete
        // capital NUEVO, así que el empate excluye — igual que en
        // riesgo/rotacion.py.
        Y indicadores_alcistas > indicadores_bajistas
        Y atr_pct ENTRE estrategia.atr_pct_min Y estrategia.atr_pct_max
        Y activo_id NO EN (activos con orden abierta de esta cuenta)

  // ── 6. Aplicar las prácticas adoptadas ────────────────────────────
  PARA CADA practica EN practicas_adoptadas(agente):
      candidatos := candidatos DONDE cumple_condiciones(practica.condiciones)
  FIN PARA

  SI candidatos ESTÁ VACÍO ENTONCES
      // "Sin candidatos" es una salida de primera clase, igual que en
      // rotacion.py: no se relaja ningún criterio para forzar una
      // operación. Pero SÍ se registra, porque tres días seguidos sin
      // candidatos es exactamente el disparador de una entrada de backlog.
      registrar_sin_candidatos(agente, hoy, motivos_de_descarte)
      RETORNAR
  FIN SI

  // ── 7. Ordenar de forma determinista ──────────────────────────────
  // Cuatro claves. La cuarta (símbolo, ascendente) existe por la misma
  // razón que en rotacion.py: sin ella, un empate lo gana quien llegue
  // antes en la lista, y el resultado depende del orden de la consulta.
  mejor := ORDENAR candidatos POR
             ratio_rr                                    DESC,
             rango_fuerza(fuerza)                        DESC,
             (indicadores_alcistas - indicadores_bajistas) DESC,
             simbolo                                     ASC
           TOMAR 1

  // ── 8. Dimensionar ────────────────────────────────────────────────
  tamaño := dimensionar_posicion(agente, mejor, deficit)
  SI tamaño.margen < MARGEN_MINIMO (10 $) ENTONCES
      // Ruina técnica: queda saldo, pero no el suficiente para una
      // posición con sentido. No es Game Over (el saldo no es 0), pero
      // tampoco es operativo.
      cuenta.estado := 'inoperante'
      RETORNAR
  FIN SI

  // ── 9. Abrir ──────────────────────────────────────────────────────
  // El RPC vuelve a validar TODO (guardarraíles G1-G5). El agente
  // propone; PostgreSQL dispone.
  resultado := rpc_abrir_orden(
      cuenta        = agente.cuenta,
      activo        = mejor.activo_id,
      senal         = mejor.id,
      precio        = mejor.precio_actual,
      apalancamiento= tamaño.apalancamiento,
      cantidad      = tamaño.cantidad,
      racional      = {
          deficit_pendiente: deficit,
          candidatos_evaluados: LONGITUD(candidatos),
          descartados_top3: [...],
          practicas_aplicadas: practicas_adoptadas(agente),
          version_estrategia: agente.version_estrategia
      })

  // ── 10. Disparadores de backlog ───────────────────────────────────
  detectar_disparadores_backlog(agente)     // ver §7
```

### 5.2 Cierre del día y el interés compuesto

```
FUNCIÓN cerrar_dia_anterior(agente):
  ayer := agente_dias DONDE fecha = hoy - 1 día Y cerrado_en ES NULO
  SI ayer NO EXISTE ENTONCES RETORNAR

  ayer.saldo_cierre     := equity_actual(agente.cuenta)
  ayer.pnl_realizado    := SUMA(pnl_bruto de órdenes cerradas ayer)
  ayer.rendimiento_pct  := (ayer.saldo_cierre / ayer.saldo_apertura - 1) * 100
  ayer.cumplido         := (ayer.pnl_realizado >= ayer.objetivo_importe)
  ayer.cerrado_en       := AHORA()
```

**El mecanismo del interés compuesto es esta única línea**:
`dia.saldo_apertura := equity_actual()`, evaluada al amanecer de cada día.
No hay fórmula de capitalización en ninguna parte, porque no hace falta: el
saldo real **es** el capital compuesto. La curva teórica
`500 × (1+p)^n` se calcula solo para dibujarla junto a la real en la vista
de agentes, como referencia visual.

**Decisión importante**: `cumplido` se mide sobre **P&L realizado**, no sobre
la variación del equity. Si se midiera sobre el equity, un agente con una
posición abierta flotando a favor «cumpliría» la meta sin haber cerrado nada,
y al día siguiente la posición podría revertir. Solo cuenta el dinero que
volvió a la cuenta.

### 5.3 Dimensionado de posición

Pieza nueva de la Fase 2. La Fase 1 calcula apalancamiento y niveles, pero
**nunca calcula cuántas unidades comprar** — no le hacía falta, porque no
operaba. Va en `motor-analitico/riesgo/dimensionado.py` por la regla de
ubicación del README, y se replica en TypeScript solo si el ciclo de agentes
la necesita en la Edge Function.

```
FUNCIÓN dimensionar_posicion(agente, senal, deficit):
  equity := equity_actual(agente.cuenta)

  // 1. Cuánto estoy dispuesto a PERDER en esta operación.
  riesgo_max := equity * estrategia.riesgo_pct_operacion / 100

  // 2. Distancia relativa al stop. Es lo que convierte el riesgo en tamaño.
  distancia_sl := (senal.precio_actual - senal.sl) / senal.precio_actual
  SI distancia_sl <= 0 ENTONCES ERROR  // el CHECK de la BD ya lo impide

  // 3. Nominal que hace que tocar el SL cueste exactamente riesgo_max.
  nominal := riesgo_max / distancia_sl

  // 4. Apalancamiento: el del motor, acotado por el propio del agente y
  //    por el tope de la fase. Tres clamps, el último manda.
  apalancamiento := MIN(senal.leverage_recomendado,
                        estrategia.apalancamiento_maximo_propio,
                        tope_de_fase(agente.cuenta))

  margen := nominal / apalancamiento

  // 5. Clamp por saldo disponible y por margen total comprometido (G3).
  margen_libre := equity * estrategia.margen_comprometido_max_pct / 100
                  - cuenta.saldo_bloqueado
  margen := MIN(margen, cuenta.saldo_disponible * 0.95, margen_libre)

  // 6. La liquidación puede llegar ANTES que el stop. Ver §5.4: si pasa,
  //    el riesgo real es el margen entero, no riesgo_max.
  precio_liquidacion := senal.precio_actual * (1 - 1/apalancamiento)
  SI precio_liquidacion > senal.sl ENTONCES
      // El stop está más lejos que la liquidación: el apalancamiento es
      // demasiado alto para este stop. Se BAJA el apalancamiento hasta que
      // la liquidación quede por debajo del SL, en vez de aceptar una
      // operación cuyo riesgo real no es el declarado.
      apalancamiento := SUELO_A_UN_DECIMAL(1 / distancia_sl) - 0.1
      SI apalancamiento < 1.0 ENTONCES RETORNAR SIN_OPERACIÓN
      margen := nominal / apalancamiento
      RECALCULAR precio_liquidacion
  FIN SI

  cantidad := (margen * apalancamiento) / senal.precio_actual

  RETORNAR { cantidad, apalancamiento, margen, precio_liquidacion }
```

> **El paso 6 es el que un dev no escribiría por su cuenta.** El requisito
> original habla de TP y SL, pero con apalancamiento existe un tercer nivel
> que no se declara: el precio al que el margen se agota. A 5×, una caída del
> 20 % liquida la posición. Si el SL está a un 25 % por debajo de la entrada
> —perfectamente posible con un activo volátil y niveles de origen `atr`— la
> posición se liquida **antes** de tocar el stop, y la pérdida real es el
> 100 % del margen en vez del 5 % del equity que el agente creía arriesgar.
> Bajar el apalancamiento en vez de aceptar la operación es coherente con la
> regla protegida nº4: ante ambigüedad de riesgo, se degrada hacia el mínimo.

### 5.4 Motor de monitoreo (requisito 6, último punto)

Corre en PostgreSQL vía `pg_cron` cada minuto. Es el componente más simple y
el que más bugs sutiles admite.

```
FUNCIÓN monitor_ordenes():
  // Solo órdenes cuyo precio de referencia es FRESCO. Un precio del
  // viernes por la tarde congelado en la tabla cerraría posiciones todo
  // el fin de semana contra un mercado que no existe (riesgo R8).
  PARA CADA orden EN v_ordenes_abiertas_monitor:   // filtra ultimo_precio_en

      p := orden.precio_vivo

      // ── Orden de evaluación: PRIMERO lo que destruye capital ──────
      // Con un único precio spot no se puede saber si en el minuto
      // transcurrido se tocó antes el TP o el SL. Ante la ambigüedad se
      // resuelve SIEMPRE hacia el lado conservador, que es la misma
      // disciplina que la regla protegida nº4 de la Fase 1.

      SI p <= orden.precio_liquidacion ENTONCES
          rpc_cerrar_orden(orden, orden.precio_liquidacion, 'liquidacion', p)

      SINO SI p <= orden.sl ENTONCES
          // Se cierra AL NIVEL, no al precio observado. Si el precio se
          // desplomó un 3 % por debajo del stop entre dos pasadas,
          // premiar o castigar al agente por ese hueco sería simular
          // una ejecución que el sistema no modela. El precio observado
          // se guarda aparte para poder medir el deslizamiento más tarde.
          rpc_cerrar_orden(orden, orden.sl, 'sl', p)

      SINO SI p >= orden.tp ENTONCES
          rpc_cerrar_orden(orden, orden.tp, 'tp', p)
      FIN SI
  FIN PARA
```

Las cuatro reglas del monitor, para que ningún dev las reinvente:

| Regla | Qué dice | Qué pasa si se ignora |
|-------|----------|----------------------|
| **M1 — Liquidación primero** | Se evalúa antes que el SL | Un agente a 5× registraría pérdidas menores que las reales |
| **M2 — Empate al lado conservador** | Si el intervalo pudo tocar ambos, gana el SL | Los resultados del experimento serían optimistas de forma sistemática |
| **M3 — Cierre al nivel, no al precio observado** | `precio_salida = sl` o `tp`; el observado va a otra columna | El P&L dependería del azar del muestreo, no de la estrategia |
| **M4 — Precio fresco obligatorio** | Antigüedad > 15 min → no se evalúa | Se cerrarían posiciones el fin de semana contra precios congelados |

Y la regla de integridad, que es de la base de datos y no del monitor:
`rpc_cerrar_orden` es **idempotente**. Dos pasadas concurrentes sobre la
misma orden no la cierran dos veces ni acreditan el P&L dos veces (doc A §8).

### 5.5 Game Over y ruina técnica

```
FUNCIÓN evaluar_game_over(cuenta):
  equity := saldo_disponible + saldo_bloqueado + pnl_no_realizado

  SI equity <= 0 ENTONCES
      cuenta.estado := 'game_over'
      cerrar_todas_las_posiciones(cuenta, motivo = 'liquidacion')
      RETORNAR verdadero
  FIN SI

  // Ruina técnica: queda dinero, pero no el suficiente para abrir una
  // posición que respete el riesgo por operación. No es Game Over, y
  // distinguirlo importa: un agente 'inoperante' con 8 $ NO ha fallado
  // igual que uno con 0 $, y el experimento debe poder diferenciarlos.
  SI equity < MARGEN_MINIMO (10 $) Y NO HAY posiciones abiertas ENTONCES
      cuenta.estado := 'inoperante'
      RETORNAR falso
  FIN SI

  RETORNAR falso
```

**Un Game Over es terminal y no se revierte automáticamente.** Reiniciar un
agente es una acción de administrador (`rpc_reiniciar_agente`), queda en
`auditoria_admin`, y crea una **cuenta nueva** en vez de resetear la
existente — así el histórico del intento fallido se conserva entero, que es
el dato más valioso del experimento.

---

## 6. Corte semanal de evaluación

### 6.1 Cómo se mide

Domingos 23:59 UTC, `pg_cron` → Edge Function `corte-semanal`.

```
FUNCIÓN corte_semanal(agente, semana_iso):
  dias := agente_dias DONDE semana = semana_iso

  // EL DENOMINADOR ES `dias_operables`, NO 7.
  dias_operables := CONTAR(dias DONDE operable = verdadero)
  dias_cumplidos := CONTAR(dias DONDE operable Y cumplido)

  SI dias_operables = 0 ENTONCES
      veredicto := 'sin_datos'     // semana de vacaciones de mercado
      RETORNAR
  FIN SI

  ratio := dias_cumplidos / dias_operables

  veredicto := CASO
      ratio >= 0.70 ENTONCES 'validada'
      ratio >= 0.40 ENTONCES 'aviso'
      SI NO               'deficiente'

  aplicar_accion_correctiva(agente, veredicto)
```

> **Por qué el denominador no puede ser 7.** Prudencia opera solo acciones,
> y el mercado americano cierra sábados, domingos y festivos. Con denominador
> 7, su mejor semana posible sería 5/7 = 0,71 — justo en el filo de
> `validada`, y cualquier festivo la hundiría a 4/7 = 0,57, es decir `aviso`,
> **sin haber hecho nada mal**. El agente sería penalizado por el calendario.
> Con `dias_operables` como denominador, Prudencia se mide sobre sus 5 días
> reales y Audacia (que opera cripto) sobre 7. Cada uno contra su propio
> universo.

### 6.2 Acción correctiva — el corte con consecuencias

Un corte semanal que solo emite un veredicto es un informe. Para que sea un
mecanismo de control, cada veredicto tiene una consecuencia mecánica:

| Veredicto | Ratio | Consecuencia |
|-----------|-------|--------------|
| **`validada`** | ≥ 0,70 | Nada cambia. Además, el agente **destila una práctica** a partir de sus operaciones ganadoras de la semana y la publica en `mejores_practicas` (§7.1) |
| **`aviso`** | 0,40 – 0,69 | El agente **lee** las prácticas mejor valoradas que no sean suyas y **adopta una**. Los parámetros de riesgo no se tocan. `version_estrategia` sube |
| **`deficiente`** | < 0,40 | Igual que `aviso`, **más**: `riesgo_pct_operacion` se reduce a la mitad durante la semana siguiente y se abre una entrada en `agente_backlog` con el análisis del fallo |
| **2× `deficiente` seguidas** | — | `agentes.estado := 'cuarentena'`. Solo opera señales de `fuerza = 'alta'` y `max_posiciones_abiertas = 1` hasta obtener una semana `validada` |

La reducción del riesgo tras una semana deficiente es lo que convierte el
Game Over de un final probable en uno **posible pero costoso de alcanzar**:
el agente que va mal arriesga menos, así que tarda más en morir y tiene más
oportunidades de corregir. Es el mismo espíritu que la transición a Fase 2 de
`maquina_fases.py` — frenar cuando las cosas van mal — aplicado en la
dimensión semanal.

---

## 7. Aprendizaje colaborativo: cómo se escriben y se leen las prácticas

El riesgo obvio del requisito 9 es que la tabla se llene de prosa que nadie
consume. El diseño lo evita con una regla: **una práctica solo existe si es
un predicado ejecutable sobre `senales`**, y solo se publica si tiene
evidencia numérica.

### 7.1 Escritura — destilación, no opinión

```
FUNCIÓN destilar_practica(agente):
  // Se agrupan las operaciones cerradas del agente por "firma de
  // condiciones": la combinación de rasgos que describía la señal.
  grupos := ordenes cerradas DEL agente
            AGRUPADAS POR firma(clase, fuerza, tramo_atr, niveles_origen,
                                tramo_rr)

  PARA CADA grupo CON al_menos(3 operaciones):
      tasa_exito := ops_tp / ops_totales
      SI tasa_exito >= 0.66 Y pnl_medio_pct > 0 ENTONCES
          publicar_o_actualizar(mejores_practicas, {
            condiciones: firma_a_predicado(grupo.firma),
            resultado_observado: { ops, tp, sl, pnl_medio_pct, rr_medio },
            confianza: tasa_exito,
            estado: SI ops >= 10 ENTONCES 'validada' SI NO 'propuesta'
          })
      FIN SI
  FIN PARA
```

Ejemplo real de lo que produciría:

```json
{
  "titulo": "Cripto con estructura y ATR% bajo aguanta el TP",
  "regla": "En cripto, exigir niveles de origen 'estructura' y ATR% < 3 antes de entrar.",
  "condiciones": {
    "clase": "cripto",
    "fuerza": ["alta"],
    "niveles_origen": "estructura",
    "atr_pct": { "max": 3.0 },
    "ratio_rr": { "min": 1.8 }
  },
  "resultado_observado": { "ops": 7, "tp": 6, "sl": 1, "pnl_medio_pct": 3.4, "rr_medio": 2.1 },
  "confianza": 0.857,
  "estado": "propuesta"
}
```

El campo `condiciones` es lo que otro agente **aplica como filtro** en el
paso 6 de su ciclo. La prosa de `titulo` y `regla` es para el humano que mira
la pantalla; la máquina consume el JSON.

### 7.2 Lectura — con medición del efecto

Adoptar una práctica no es gratis ni definitivo:

```
FUNCIÓN adoptar_practica(agente, practica):
  INSERTAR EN mp_adopciones { practica, agente, adoptada_en: AHORA() }
  AÑADIR practica.id A estrategia.practicas_adoptadas
  agente.version_estrategia += 1

// Y dos semanas después:
FUNCIÓN evaluar_adopciones(agente):
  PARA CADA adopcion ACTIVA CON al_menos(5 operaciones):
      antes   := rendimiento_medio(agente, ANTES de adopcion.adoptada_en)
      despues := rendimiento_medio(agente, DESDE adopcion.adoptada_en)

      adopcion.veredicto := CASO
          despues > antes * 1.1  ENTONCES 'mejoro'
          despues < antes * 0.9  ENTONCES 'empeoro'
          SI NO                        'neutro'

      SI adopcion.veredicto = 'empeoro' ENTONCES
          abandonar(agente, adopcion.practica)
          valorar(agente, practica, -1)
          SI practica tiene ≥2 adopciones con 'empeoro' ENTONCES
              practica.estado := 'refutada'     // deja de ofrecerse a nadie
          FIN SI
      SI NO SI adopcion.veredicto = 'mejoro' ENTONCES
          valorar(agente, practica, +1)
      FIN SI
  FIN PARA
```

Esto es lo que separa un tablón de anuncios de un sistema de aprendizaje: las
prácticas que no funcionan **se retiran solas**, y el ranking que ven los
agentes está ordenado por efecto medido, no por antigüedad.

---

## 8. Backlog autónomo: cuándo escribe un agente

Los agentes no «se inventan» peticiones. Cada entrada de `agente_backlog`
nace de un **disparador determinista** que observa una limitación real del
sistema. Esto es lo que hace que la tabla merezca revisarse.

| Disparador | Condición | Tipo | `clave_deduplicacion` |
|------------|-----------|------|----------------------|
| **Sin candidatos por dirección** | ≥ 3 días seguidos en que todos los descartes fueron por `direccion = 'bajista'` | `sesgo_corto` | `sesgo_corto:global` |
| **Universo insuficiente** | ≥ 5 ciclos sin ningún candidato porque la cartera del agente no tiene activos que pasen el filtro | `nuevo_activo` | `nuevo_activo:universo` |
| **Tope de fase estrangulando** | La cuenta está en `fase_2_consolidacion` y el objetivo diario exige un movimiento > 3 % del subyacente (§1.4) | `reversion_fase` | `reversion_fase:cuenta_{id}` |
| **Volatilidad no disponible** | El mismo activo devuelve `operable = false` por falta de ATR ≥ 5 veces | `nuevo_dato` | `nuevo_dato:atr:{simbolo}` |
| **Cierre parcial** | ≥ 3 operaciones que tocaron el 80 % del recorrido al TP y después retrocedieron al SL | `nueva_herramienta` | `nueva_herramienta:cierre_parcial` |
| **Trailing stop** | ≥ 3 operaciones cerradas en TP cuyo precio siguió subiendo > 2 % en las 24 h siguientes | `nueva_herramienta` | `nueva_herramienta:trailing_stop` |
| **Señal añeja** | ≥ 10 descartes por `antiguedad_senal_max_min` superada | `ajuste_regla` | `ajuste_regla:cadencia_etl` |

Cada inserción lleva `evidencia jsonb` con los identificadores de las órdenes
o los días concretos que la sostienen. **Sin evidencia el `INSERT` se
rechaza** (`CHECK (jsonb_typeof(evidencia) = 'object' AND evidencia <> '{}')`):
una petición sin datos es una opinión, y este sistema no recoge opiniones de
agentes.

Y cuando un segundo agente dispara la misma clave, no se inserta una fila
nueva: se incrementa `ocurrencias` y se añade su id a `agentes_solicitantes`.
La vista `v_backlog_priorizado` ordena por
`ocurrencias × cardinalidad(agentes_solicitantes)`, así que **una petición
que los tres agentes repiten cien veces sube sola a lo más alto de la
lista.**

---

## 9. Resumen de reglas de negocio nuevas que la Fase 2 introduce

Para el CHANGELOG y para la guía de lectura (`guia.js` debe reflejarlas, por
la DoD nº5):

| # | Regla | Dónde vive |
|---|-------|------------|
| N1 | El saldo es derivado; el libro mayor `movimientos_saldo` es la verdad | Doc A §5.2 |
| N2 | Toda orden lleva TP y SL obligatorios: no existe posición sin gestión de riesgo | `CHECK` en `ordenes` |
| N3 | El R:R mínimo filtra candidatos; la Fase 1 emitía niveles sin comprobar que mereciera la pena | `senales.ratio_rr` + filtro del agente |
| N15 | SL y TP se anclan al soporte y la resistencia pero se acotan en ATR: stop entre 1 y 2 ATR del precio, objetivo como mucho a 2 ATR. El R:R va de 0,25 a 2 (D21) | `indicadores/tecnicos.py` · `calcular_niveles_operativos` |
| N16 | Un RSI extremo solo vota si el MACD no lo contradice (D21) | `indicadores/tecnicos.py` · `evaluar_confluencia` |
| N4 | La liquidación se evalúa antes que el stop, y si queda por encima del SL se **baja** el apalancamiento | §5.3 paso 6, §5.4 regla M1 |
| N5 | Ante ambigüedad TP/SL en el mismo intervalo, gana el SL | §5.4 regla M2 |
| N6 | El cierre se registra al nivel, no al precio observado | §5.4 regla M3 |
| N7 | Un precio con más de 15 minutos no cierra posiciones | §5.4 regla M4 |
| N8 | El objetivo diario se mide sobre **P&L realizado**, no sobre el equity flotante | §5.2 |
| N9 | Meta cumplida ⇒ modo conservación: no se abren posiciones nuevas ese día | §5.1 paso 3 |
| N10 | El corte semanal se mide sobre **días operables**, no sobre 7 | §6.1 |
| N11 | Una práctica solo se publica con ≥ 3 operaciones y ≥ 66 % de acierto | §7.1 |
| N12 | Una práctica con 2 adopciones fallidas pasa a `refutada` y deja de ofrecerse | §7.2 |
| N13 | Una entrada de backlog sin evidencia no se inserta | §8 |
| N14 | Un Game Over no se revierte: reiniciar crea una cuenta nueva y conserva el histórico | §5.5 |
