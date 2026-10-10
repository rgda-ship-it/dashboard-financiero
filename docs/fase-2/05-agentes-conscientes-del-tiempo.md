# E. Agentes conscientes del tiempo

> **Autor**: Analista Cuantitativo / Risk Manager (equipo virtual)
> **Fecha**: 2026-10-10
> **Estado**: **Propuesta revisada con las respuestas del dueño**. Entregas A (0031) y D (0032) hechas; el resto, sin implementar.
> Las decisiones del dueño están en el §8.
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

> **Revisado tras las respuestas del dueño (2026-10-10).** La primera
> versión descartaba las entradas que no cabían en el tiempo que le
> quedaba al mercado y cerraba por tiempo de forma mecánica. Era una
> visión inmediata: una entrada que no cubre la meta de hoy puede cubrir
> la de mañana, y entrar ahora al mejor precio es mejor que entrar mañana
> a uno peor. Ninguna de las dos reglas descarta ni cierra ya por sí sola:
> las dos pasan a ser **evaluaciones**.

### 5.1 Aporte a la trayectoria de metas, no R:R

El orden de candidatos deja de ser «mayor R:R primero» y pasa a ser
**cuánto aporta a las metas por cada sesión que compromete el capital**:

```
valor_esperado     = p × ganancia_objetivo − (1 − p) × pérdida_stop − coste_hueco
aporte_por_sesion  = valor_esperado / horizonte_estimado_sesiones
```

El aporte no se mide contra la meta de hoy, sino contra la **trayectoria
de metas** del agente: lo que falta hoy, lo que falta en los días
siguientes de la semana y la de la semana siguiente. Una operación de 3
sesiones que cierra el miércoles cuenta para la meta del miércoles.

`coste_hueco` es cero si la operación no cruza ningún cierre de mercado y,
si lo cruza, la pérdida esperada por un hueco de apertura medido en ese
activo (§5.4). Mientras no haya ventaja medida, `p` sale del §4 y el valor
esperado ronda cero: el orden lo deciden el horizonte, el hueco y la
calidad de la señal (§6), y eso es honesto. En cuanto la calibración
muestre grupos con ventaja, suben solos.

### 5.2 Horizonte de planificación (sustituye al «filtro de ventana»)

No se descarta una entrada por no caber en lo que queda de sesión. Compite
por su aporte por sesión, con su coste de hueco si pasa la noche o el fin
de semana. El único límite duro es un **horizonte máximo** por agente, para
que el capital no quede inmovilizado sin fecha. Propuesta de partida:
Prudencia 10 sesiones, Cadencia 5, Audacia 3. Audacia necesita más
rotación para su 7 % diario; Prudencia puede esperar.

### 5.3 Revisión al cumplirse el horizonte (sustituye al «stop por tiempo»)

Cuando una posición alcanza su horizonte estimado, se **reevalúa como si
fuera una entrada nueva**: con el precio y la señal de ahora se recalculan
su valor esperado, su horizonte restante y su aporte por sesión.

- Se mantiene si su aporte restante supera al de la mejor alternativa para
  ese capital.
- Si no, se cierra (motivo `tiempo`).

Es la comparación que ya hace la rotación (0016), extendida a cualquier
momento en que una posición agote su horizonte, y juzgada igual contra su
contrafactual.

### 5.4 Noches y fines de semana: caso a caso

No hay regla fija (respuesta 2 del dueño). Antes del cierre de un mercado
con hueco, el agente decide para cada posición **mantener, reducir o
cerrar**, comparando:

```
mantener  = valor_esperado_restante − coste_hueco
liberar   = aporte de la mejor alternativa en los mercados que siguen
            abiertos, durante el tiempo que dura el cierre
```

Con estos datos:

| Factor | De dónde sale |
|---|---|
| **Mercado:** riesgo de hueco del activo | Huecos medidos en `precios_diarios`: apertura frente al cierre anterior, en ATR, separando lunes y resto de días |
| **Posición:** distancia al stop y al objetivo, progreso, señal vigente | La orden y la señal de ahora |
| **Saldo:** cuánto hay libre y qué candidatas esperan en los mercados abiertos | El reparto del propio ciclo |
| **Metas:** dónde está el agente en la semana | §5.5. Por delante: proteger lo ganado. Por detrás: no renunciar a la oportunidad |

Es una decisión registrada (`cierre_sesion`) y juzgada contra lo que habría
pasado sin ella, así que el agente aprende de cada fin de semana.

**Requisito previo: que el simulador modele los huecos.** Hoy la regla M3
cierra **al nivel** del stop aunque el lunes la acción abra muy por debajo:
en el simulador, un fin de semana no tiene riesgo de hueco. Con eso, un
agente que aprende de sus resultados aprendería a mantenerlo todo
siempre. Propuesta (M3'): si el primer precio fresco después de un cierre
de mercado ya está más allá del stop, la orden se cierra a ese precio, como
haría un bróker. Afecta también a las simulaciones de los usuarios.

### 5.5 La meta diaria y la semanal

```
meta_semana       = saldo_lunes × ((1 + meta_diaria)^dias_operables − 1)
falta_semana      = meta_semana − pnl_realizado_semana
ritmo_necesario   = falta_semana / sesiones_operables_restantes_semana
```

Lo que hace el agente con eso:

- **Si va por delante**, el modo conservación de hoy (N9) se extiende:
  puede dar el día por bueno con lo que ya lleva de la semana.
- **Si va por detrás**, cambia **qué** busca (horizontes más cortos,
  mercados abiertos, más intentos), **nunca** el riesgo por operación
  (respuesta 3 del dueño, confirmada).
- **Sin presupuesto de pérdida diario** (respuesta 1 del dueño).

**Riesgo abierto total (pendiente de decisión, §8).** No es un límite de
pérdida diaria: limita cuánto está en juego **a la vez**, no cuánto se ha
perdido hoy, y se libera en cuanto se cierra una posición. Hace falta por
el punto 1 (D21): cada stop cuesta ahora el riesgo completo por operación
y el reparto abre varias posiciones en el mismo ciclo. Audacia con 5
posiciones arriesga el 12,5 % de su saldo a la vez, en activos que suelen
caer juntos. Antes de D21, con stops a 0,1 %, ese riesgo era de céntimos.

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

### 6.3 Prudencia en cripto: el cálculo (respuesta 4 del dueño)

El dimensionado ya iguala el riesgo en dólares, sea cual sea la
volatilidad: el stop está a 1–2 ATR y el tamaño sale de él. Lo que la
cripto añade son colas más gordas y que todas se mueven con BTC. Por eso
el ajuste prudente tiene dos piezas:

**1. Riesgo por operación escalado por volatilidad**, tomando como
referencia el propio techo de ATR de Prudencia en acciones (3 %):

```
riesgo_cripto = riesgo_prudencia × min(1, 3 % / ATR_activo)
                (no entra si el factor baja de 0,25, es decir, ATR > 12 %)
```

| Activo (ATR medio medido) | Factor | Riesgo con el reducido de hoy (0,75 %) | Riesgo en $ (saldo 509 $) | Margen resultante |
|---|---|---|---|---|
| BTC (2,5 %) | 1,00 | 0,75 % | 3,82 $ | ≈ 51 $ |
| ETH (3,1 %) | 0,97 | 0,73 % | 3,70 $ | ≈ 40 $ |
| SOL (4,0 %) | 0,75 | 0,56 % | 2,86 $ | ≈ 24 $ |
| XRP (5,1 %) | 0,59 | 0,44 % | 2,25 $ | ≈ 15 $ |
| ADA (6,0 %) | 0,50 | 0,38 % | 1,91 $ | ≈ 16 $ |
| ZEC (9,3 %) | 0,32 | 0,24 % | 1,23 $ | ≈ 7 $ → **no llega al mínimo de 10 $** |

(Stop a 1 ATR, fuerza media; apalancamiento del motor con el tope de 3× de Prudencia. Margen = riesgo ÷ distancia al stop ÷ apalancamiento.)

**2. Riesgo abierto en cripto ≤ 1 × su riesgo por operación**: la suma de
lo que arriesgan sus posiciones cripto abiertas no pasa de una posición
completa. Dos criptos abiertas son casi la misma apuesta.

**Si no basta, lo pide.** Cuando en 5 días operables al menos 10
candidatas cripto quedan fuera **solo** por estos dos límites (margen por
debajo de 10 $ o riesgo cripto lleno), Prudencia abre una petición en el
backlog («Ampliar el riesgo en cripto»), con las señales concretas y el
riesgo que habrían necesitado. Decide el administrador; nada se amplía
solo. El mismo patrón sirve para cualquier límite de perfil que tumbe
candidatas de forma repetida.

### 6.4 Universo cripto

De los 20 huecos de cripto, solo 8 son criptos líquidas reales (BTC, ETH,
BNB, SOL, XRP, ADA, DOGE, ZEC). El resto eran tokens que replican acciones
y ya están suspendidos. Propuesta: llenar los huecos con criptos líquidas
(LTC, LINK, AVAX, DOT, TRX, BCH…), dentro del límite de CoinGecko.

---

## 7. Entregas propuestas, en el orden recomendado

| # | Entrega | Qué incluye | Cambia el comportamiento |
|---|---|---|---|
| 0 | **Puntos 1 y 2** (D21) | Hechos, con el riesgo abierto total (G6); falta unirlos | Sí |
| 1 | **A. Medir** (hecha, 0031) | Tabla `mercados` con festivos; funciones de tiempo; horizonte y `p` estimados en cada orden; `precio_max/min_visto_en`; huecos medidos por activo; meta semanal y ritmo en `ultima_decision`; régimen de mercado de cada práctica (§9); autodiagnóstico semanal al backlog (§10) | No: registra, muestra y pide |
| 2 | **D. Cripto prudente** (hecha, 0032) | Perfiles por mercado, el cálculo del §6.3 con su petición al backlog, universo cripto | Sí |
| 3 | **M3' (hecha, 0033) + C. Noches y fines de semana** | Huecos reales en el simulador y la evaluación caso a caso del §5.4 | Sí |
| 4 | **B. Aporte por sesión** | Orden por aporte a la trayectoria de metas, horizonte máximo, revisión al cumplirse el horizonte, calidad que gradúa el tamaño | Sí |
| 5 | **E. Calibración** | Sustituir las estimaciones de partida por las observadas por grupo; evaluación continua y vigencia de las prácticas (§9) | Sí, a medida que hay datos |

Por qué este orden:

- **A primero**: no cambia ninguna decisión y todo lo demás necesita sus
  datos. Lo ideal es que corra una semana antes de B.
- **D antes que C**: liberar saldo el viernes no sirve si no hay cripto
  que comprar. El 10 de octubre había 177 $ libres y ninguna candidata.
  D se puede hacer en paralelo con A.
- **M3' junto con C**: sin huecos reales, la evaluación del fin de semana
  aprendería que mantener siempre sale gratis.
- **B al final**: es el cambio más profundo y el que más gana con
  horizontes ya medidos.

---

## 8. Decisiones del dueño

Decidido (2026-10-10):

1. **Sin presupuesto de pérdida diario.**
2. **Noches y fines de semana, caso a caso** (§5.4), nunca una regla fija.
3. **Ir por detrás de la meta nunca sube el riesgo por operación.**
4. **Prudencia en cripto**: cálculo prudente del §6.3; si no basta, lo
   pide por el backlog.
5. **Orden**: el recomendado en el §7.
6. **Riesgo abierto total ≤ 4 × el riesgo por operación** (§5.5). Ya
   implementado en la 0030 como G6, junto con los puntos 1 y 2.
7. **Huecos reales en el simulador (M3')**, también para los usuarios.
8. **Horizonte máximo**: Prudencia 10 sesiones, Cadencia 5, Audacia 3.

---

## 9. Prácticas con fecha de caducidad

### 9.1 El problema que señala el dueño

Una práctica validada y respaldada puede haber sido **situacional**: lo que
funcionó en un mercado alcista y tranquilo puede dejar de funcionar cuando
el mercado cambia. Revisado el código, el sistema hoy no lo detecta:

| Pieza | Lo que hace hoy | Por qué no basta |
|---|---|---|
| Evaluación de una adopción (`fn_evaluar_adopciones`) | A las 2 semanas, con 5 operaciones, compara el rendimiento antes y después **una sola vez** | Si sale «mejoró» o «neutro», **no se vuelve a evaluar nunca**: la práctica se aplica para siempre |
| Estadística de la práctica | Suma toda la historia, sin pesar lo reciente | Diez aciertos de hace un mes pesan igual que diez fallos de esta semana |
| Estado `validada` | Solo se pierde si **dos** adopciones salen «empeoró» | Una práctica que solo adopta un agente no se puede refutar nunca |
| Contexto de mercado | No se guarda | No se sabe en qué mercado se aprendió ni si el de hoy se le parece |

### 9.2 Propuesta

1. **Evaluación continua, no única.** Cada semana, cada adopción viva se
   reevalúa sobre una ventana móvil (las últimas 4 semanas). Si empeora,
   se abandona aunque antes hubiera mejorado.
2. **Contrafactual de verdad.** Hoy se compara «antes» con «después», y
   entre medias cambian el mercado y la estrategia. Mejor comparar lo que
   la práctica dejó fuera con lo que dejó pasar en el mismo periodo: los
   descartes por `practica` quedan registrados en cada decisión, y lo que
   habría hecho cada señal descartada se calcula como en la rotación.
3. **Vigencia.** Una práctica sin operaciones nuevas que la respalden en 4
   semanas pasa a `en_revision`: deja de aplicarse y de ofrecerse hasta
   que vuelva a tener evidencia reciente. La que la tiene recupera su
   estado sola.
4. **Contexto al publicarla.** Se guarda el régimen de mercado del momento
   (proporción de señales alcistas, ATR medio del universo, tendencia de
   BTC y del S&P 500). Una práctica solo se aplica cuando el régimen
   actual se parece al de su evidencia.
5. **Refutación con un solo agente.** Si quien la adoptó acumula evidencia
   reciente en contra con suficientes operaciones, basta para suspenderla
   para él, sin esperar a un segundo agente.

Encaja en la entrega A (guardar el régimen de mercado) y en la E
(calibración y evaluación continua).

---

## 10. Que los agentes propongan su propio diagnóstico

### 10.1 La pregunta del dueño

> «La mayoría del análisis que estamos realizando ahora, ¿no debieron ser
> propuesta de los agentes?»

Sí. El diseño lo pretendía (el backlog autónomo, doc 03 §8), pero sus
disparadores solo miran la **infraestructura** y nunca la **calidad de los
resultados**. En 11 días los agentes pidieron 12 cosas: señales más
frecuentes (falso positivo), ampliar el universo, volatilidad de 6
criptos, revisar el umbral de fase y, tras la semana deficiente, «revisar
mi estrategia» sin ningún análisis detrás. Ninguna petición decía «llevo
53 stops y ningún objetivo».

Y los dos disparadores que sí miraban los resultados **no podían saltar
nunca**: «cierre parcial» exige operaciones que lleguen al 80 % del camino
al objetivo, y «trailing stop», cierres en objetivo. Con los niveles de
antes no hubo ninguno de los dos.

Hay un límite que conviene decir claro: son deterministas. Solo pueden
detectar lo que alguien ha escrito como disparador. Llamarlos
«operadores expertos» no les da criterio: les da un nombre.

### 10.2 Propuesta: autodiagnóstico semanal

En el corte semanal, cada agente ejecuta sobre sus propias operaciones las
mismas medidas que `scripts/diagnostico_agentes.sql`, y abre una petición
en el backlog, con la evidencia, cuando una cruza su umbral:

| Medida | Umbral de partida | Petición |
|---|---|---|
| Cierres en objetivo | 0 de ≥ 15 cierres | «Mis objetivos no se alcanzan», con la distribución del mejor recorrido |
| Distancia al stop | Mediana < 0,5 ATR | «Mis stops están dentro del ruido» |
| Votos contradictorios | ≥ 50 % de entradas con algún voto en contra | «Entro con señales que se contradicen» |
| Concentración de descartes | Un solo filtro tumba ≥ 80 % de las candidatas | «El filtro X me deja sin operar», con lo que habría pasado |
| Saldo parado | Saldo lleno en un mercado cerrado mientras otro abierto tenía candidatas | «Mi saldo queda atrapado», con las horas y las candidatas perdidas |
| Metas | 0 días cumplidos en la semana | «Mi meta no es alcanzable con mi perfil», con el movimiento que exige frente al ATR real |
| Prácticas | Una adoptada que empeora en la ventana reciente | «La práctica X ya no funciona» (§9) |

Así, lo que esta vez descubrió una revisión externa lo habría pedido el
propio agente en su primer corte semanal.

Más adelante, la **capa narrativa** (doc 03 §2, hoy apagada) podría
redactar ese informe semanal en prosa y proponer hipótesis para que el
humano las revise. Sin decidir nunca: el agente sigue siendo determinista
y reproducible. Tendría un coste por uso que hoy el proyecto no tiene, y
es decisión del dueño.

Encaja en la entrega A: son las mismas medidas que ya hay que registrar.
