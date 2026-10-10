# E. Agentes conscientes del tiempo

> **Autor**: Analista Cuantitativo / Risk Manager (equipo virtual)
> **Fecha**: 2026-10-10
> **Estado**: **Propuesta para el dueño**. Nada de esto está implementado.
> Las preguntas abiertas del §8 deciden el alcance de la primera entrega.
> **Contexto**: diagnóstico de 11 días en producción
> (`scripts/diagnostico_agentes.sql`) y D21 (0030), que deja el stop y el
> objetivo a una distancia alcanzable. Este documento es el paso
> siguiente: que el agente decida sabiendo **cuánto tiempo tiene** y
> **cuánto tardará** cada operación.

---

## 1. El problema, en una frase

Hoy un agente abre una posición, la deja correr hasta el stop o el
objetivo, y **no sabe ni cuánto tardará en llegar ni si eso le sirve para
su meta de hoy o de esta semana**. Tampoco sabe que el viernes a las 16:00
las acciones cierran hasta el lunes, ni que la cripto sigue abierta.

Los datos lo confirman:

| Síntoma | Dato |
|---|---|
| Ninguna meta diaria cumplida | 0 de 36 días agente |
| Objetivos que no se alcanzan en el horizonte del agente | Objetivo medio a ~8 ATR; mejor recorrido medio, 0,35 ATR (corregido en D21) |
| Saldo atrapado el fin de semana | 3–4 oct.: Audacia con 485 $ de ~496 $ en acciones, `saldo_lleno` las 48 h |
| La prudencia se traducía en no operar | Prudencia, «sin candidatos» casi todos los ciclos; Cadencia, ninguna cripto real por su tope de ATR |
| Ninguna cripto real pasó los filtros | 2.701 señales: 2.106 caen por dirección, 280 por R:R, 269 por fuerza |

---

## 2. Principios

1. **El tiempo es un recurso con fecha de caducidad.** Cada mercado tiene
   ventanas. Una operación que necesita tres sesiones no sirve para la meta
   de hoy, y una de acciones abierta el viernes a las 15:30 queda expuesta
   dos días y medio a un hueco de apertura.
2. **Prudencia es cuánto se arriesga, no si se opera.** La respuesta
   prudente a una señal mediocre es una posición pequeña, no ninguna.
   Los límites duros (G1–G5, solo largos) no cambian.
3. **La meta orienta, el riesgo manda.** Ir por detrás de la meta puede
   cambiar **qué** se busca (más operaciones, otro mercado, horizontes más
   cortos), nunca subir el riesgo por operación por encima de su tope.
   Doblar la apuesta para recuperar es la forma más rápida de un Game Over.
4. **Toda estimación se mide contra lo que pasó.** Si el agente estima que
   una operación tarda 2 sesiones, se guarda esa cifra y se compara con lo
   que tardó. Sin esa medida, el modelo de tiempo es una opinión.
5. **Determinista y multi-mercado desde el primer día.** Nada de «si es
   cripto…» en el código: los mercados se describen en una tabla, para
   que añadir uno en una fase futura sea añadir una fila.

---

## 3. El calendario de mercados

### 3.1 Tabla `mercados`

| Columna | Ejemplo acciones EE. UU. | Ejemplo cripto |
|---|---|---|
| `clave` | `nyse` | `cripto` |
| `clases` | `{accion}` | `{cripto}` |
| `zona_horaria` | `America/New_York` | `UTC` |
| `sesiones` (jsonb) | lun–vie 09:30–16:00 | todos los días 00:00–24:00 |
| `festivos` (date[]) | calendario NYSE del año | — |
| `riesgo_hueco` | alto (noche y fin de semana) | bajo (continuo) |

Hoy esa información está repartida y duplicada en `fn_mercado_abierto`,
`fn_etl_toca`, `fn_mercado_para_clases` y `ventana_mercado.py`, y ninguna
conoce los festivos. Pasa a vivir en un solo sitio.

### 3.2 Lo que el agente puede preguntar

```
tiempo_restante_sesion(mercado, ahora)    → minutos hasta el cierre de hoy
proxima_apertura(mercado, ahora)          → cuándo vuelve a abrir
horas_operables(mercado, desde, hasta)    → horas de mercado en un intervalo
cruza_cierre(mercado, ahora, horizonte)   → ¿la operación pasa una noche o un fin de semana?
```

Con eso el agente conoce, en cada ciclo:

- **cuánto le queda del día** en cada mercado que admite;
- **cuánto le queda de la semana** (el corte es el lunes 00:07 UTC);
- **qué mercados abren o cierran** antes de que acabe su horizonte.

---

## 4. Cuánto tarda una operación

### 4.1 Estimación de partida

Con el stop a `b` ATR y el objetivo a `a` ATR (tras D21: `b` entre 1 y 2,
`a` hasta 2), y suponiendo que el precio no tiene tendencia (no presumimos
ventaja que no esté medida):

```
sesiones_esperadas ≈ a × b / k²        (k ≈ 1: un ATR por sesión)
p_objetivo         ≈ b / (a + b)       (sin ventaja: lo que da el azar)
```

Ejemplos: objetivo a 2 ATR y stop a 1 ATR → unas 2 sesiones y una
probabilidad de partida del 33 %. Objetivo a 1 ATR y stop a 1 ATR → 1
sesión y 50 %.

Son **estimaciones de partida**, no verdades. El §4.2 las corrige con lo
que el agente vaya viendo.

### 4.2 Calibración con la historia propia

Cada orden guarda al abrir su `horizonte_estimado` y su `p_estimada`. Al
cerrar se comparan con el tiempo real y con el resultado. Por grupo
(mercado, tramo de ATR, fuerza), con suficientes operaciones, el agente
sustituye la estimación de partida por la observada: es el mismo mecanismo
de decisión juzgada contra su contrafactual que ya usan la rotación y el
deterioro (0016, 0024).

Para medir el recorrido en el tiempo hace falta un dato que hoy no se
guarda: **cuándo** se alcanzó el mejor precio (`precio_max_visto_en`), y el
peor (`precio_min_visto`, `precio_min_visto_en`). Es barato: lo actualiza
el monitor que ya corre cada minuto.

---

## 5. Cómo decide un agente consciente del tiempo

### 5.1 Contribución esperada, no R:R

El orden de candidatos deja de ser «mayor R:R primero» y pasa a ser
**cuánto aporta a la meta por hora de capital comprometido**:

```
valor_esperado = p × ganancia_objetivo − (1 − p) × pérdida_stop
aporte_por_hora = valor_esperado / horizonte_estimado_horas
```

Mientras no haya ventaja medida, `p` sale del §4 y el valor esperado ronda
cero: el orden lo deciden el horizonte y la calidad de la señal (§6), y
eso es honesto. En cuanto la calibración muestre grupos con ventaja,
suben solos.

### 5.2 Filtro de ventana

Una candidata se descarta (motivo nuevo: `fuera_de_ventana`) si su
horizonte estimado **no cabe** en lo que queda de su mercado, salvo que el
agente acepte pasar la noche (§5.4). Un viernes a las 15:00, una operación
de acciones de 2 sesiones no cabe; una de cripto, sí.

### 5.3 Stop por tiempo

Una posición que ha consumido el doble de su horizonte estimado sin
recorrer la mitad del camino al objetivo se cierra (motivo `tiempo`). Es
capital parado que podría estar en otra operación, y la salida por
deterioro ya demostró que cerrar a tiempo ahorra: en 20 de 22 casos
resueltos, cerrar fue mejor que aguantar.

### 5.4 Fin de sesión y fin de semana

Treinta minutos antes del cierre de un mercado con `riesgo_hueco` alto, el
agente revisa cada posición abierta en él:

- **La mantiene** si su valor esperado sigue siendo positivo y la pérdida
  posible por un hueco de apertura (estimada como el stop más 1 ATR de
  hueco) cabe en su presupuesto de riesgo diario.
- **La cierra o la reduce** si no cabe, o si es viernes y hay candidatas
  en un mercado abierto el fin de semana con mejor aporte por hora. Esto
  es lo que el dueño echó en falta: liberar saldo para la cripto.

El viernes el listón es más alto que entre semana: el hueco del lunes
llega después de 65 horas sin poder salir.

### 5.5 La meta diaria y la semanal

```
meta_semana       = saldo_lunes × ((1 + meta_diaria)^dias_operables − 1)
falta_semana      = meta_semana − pnl_realizado_semana
ritmo_necesario   = falta_semana / horas_operables_restantes_semana
```

Lo que hace el agente con eso:

- **Si va por delante**, el modo conservación de hoy (N9) se extiende:
  puede dar el día por bueno con lo que ya lleva de la semana.
- **Si va por detrás**, prioriza horizontes más cortos y mercados abiertos
  (más intentos en el tiempo que queda), **no** más riesgo por operación.
  El riesgo por operación sigue topado por su perfil y por G2.
- **Presupuesto de pérdida diario** (nuevo y necesario): si las pérdidas
  realizadas del día alcanzan un límite, no abre nada más ese día. Hoy no
  existe ningún freno así. Propuesta: 3 × su riesgo por operación.

Cada ciclo deja en `ultima_decision` la meta de la semana, lo que falta,
el ritmo necesario y el tiempo restante por mercado. Así se ve en
pantalla **por qué** decide lo que decide.

---

## 6. Prudencia como tamaño (punto 3)

### 6.1 Calidad de la entrada en vez de filtros que lo tumban todo

Hoy cada criterio es un sí o un no. Una señal con fuerza media, R:R de 1,4
y ATR del 2,5 % queda fuera de Cadencia por una décima de ATR. La
propuesta separa dos cosas:

- **Límites duros, que no se tocan**: los guardarraíles G1–G5, solo largos
  (dirección alcista), volatilidad conocida, precio fresco.
- **Calidad, que gradúa el tamaño**: fuerza, R:R, ATR respecto al perfil
  del agente, coincidencia con prácticas validadas, antigüedad de la
  señal. Dan una puntuación de 0 a 1 que **multiplica el riesgo por
  operación** (por ejemplo, entre 0,25× y 1×).

Una entrada mediocre se toma pequeña; una buena, con el riesgo completo
del perfil. El aprendizaje mide si la puntuación predice el resultado y
ajusta los pesos, igual que hoy ajusta la rotación.

### 6.2 Perfiles por mercado

El ATR de una cripto tranquila (BTC, 2,2–2,8 %) es el de una acción
volátil. Un único corte de ATR para las dos clases deja la cripto fuera de
Cadencia sin que nadie lo haya decidido. Cada perfil pasa a tener sus
rangos **por mercado**, y el ATR se mide también contra la propia historia
del activo (percentil), no solo en valor absoluto.

Prudencia puede operar cripto con su riesgo reducido (por ejemplo, la
mitad) y las mismas exigencias de estructura. Prudente, pero presente.

### 6.3 Universo cripto

De los 20 huecos de cripto, solo 8 son criptos líquidas reales (BTC, ETH,
BNB, SOL, XRP, ADA, DOGE, ZEC). El resto eran tokens que replican acciones
y ya están suspendidos. Propuesta: llenar los huecos con criptos líquidas
(LTC, LINK, AVAX, DOT, TRX, BCH…), dentro del límite de CoinGecko.

---

## 7. Entregas propuestas

| Entrega | Qué incluye | Cambia el comportamiento |
|---|---|---|
| **A. Medir** | Tabla `mercados` con festivos; funciones de tiempo; `horizonte_estimado`, `p_estimada` y `precio_max/min_visto_en` en cada orden; meta semanal y ritmo en `ultima_decision` | No: solo registra y muestra |
| **B. Entrar con tiempo** | Orden por aporte por hora, filtro de ventana, stop por tiempo, presupuesto de pérdida diario | Sí |
| **C. Cierres de sesión** | Revisión antes del cierre, política de noche y fin de semana, liberar saldo para la cripto | Sí |
| **D. Prudencia como tamaño** | Puntuación de calidad, riesgo graduado, perfiles por mercado, universo cripto | Sí |
| **E. Calibración** | Sustituir las estimaciones de partida por las observadas por grupo | Sí, a medida que hay datos |

A es la base de todo y no tiene riesgo: conviene que corra una semana
antes de B, para que B arranque con horizontes medidos y no supuestos.

---

## 8. Preguntas para el dueño

1. **Presupuesto de pérdida diario.** ¿3 × el riesgo por operación de cada
   agente (con el riesgo reducido de hoy: Prudencia 2,25 %, Cadencia 4,5 %,
   Audacia 7,5 % del saldo)? ¿Otra cifra?
2. **Noches y fines de semana en acciones.** ¿Se permite mantener
   posiciones si caben en el presupuesto de riesgo (§5.4), o los agentes
   cierran siempre las acciones antes del fin de semana?
3. **Ir por detrás de la meta semanal.** Confirmar que solo cambia qué se
   busca y nunca sube el riesgo por operación (§5.5).
4. **Prudencia en cripto.** ¿Con la mitad de su riesgo, o prefieres otra
   proporción?
5. **Orden de entrega.** ¿A → B → C → D, o adelantar D (cripto) a C?
