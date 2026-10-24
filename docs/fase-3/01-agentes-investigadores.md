# Fase 3 — Agentes investigadores

> **Para qué sirve**: rediseñar el papel de los agentes para que sean el
> medio por el que el sistema evoluciona. Hoy esa evolución ocurre fuera,
> en el chat con Claude.
> **Decisión del dueño (2026-10-24)**: se hace en dos pasos. Primero una
> versión determinista, sin coste y sin tocar cómo operan los agentes,
> con el formato pensado para que después pueda proponer hipótesis un
> modelo de lenguaje (LLM).
> **Datos**: producción a 24-10, con `scripts/consultar.py`.

---

## 1. El problema

La meta diaria se puso para darles un motivo: con un objetivo y
conocimiento financiero, el agente interpretaría mejor las señales y
empezaría a pedir cosas (un indicador, un ajuste). Eso no ocurre, por tres
razones:

1. **Un agente no razona: ejecuta reglas en SQL.** La meta solo cambia
   algo si un mecanismo une «me falta X» con «hago Y». El único que hay es
   el reparto por exigencia: cuanto más lejos de la meta, más arriesga.
   Eso lo hace operar más agresivo, no aprender.
2. **Lo que «pide» está escrito de antemano.** `fn_disparadores_backlog`
   tiene siete plantillas («ampliar el universo», «señales más
   frecuentes», «volatilidad de X»…). Un agente solo puede pedir lo que se
   previó que pediría. En toda su vida han salido 15 peticiones, todas de
   esas plantillas.
3. **La evidencia existe, pero nadie la convierte en propuestas.** Cada
   decisión se mide contra lo que habría pasado sin ella:

   | Decisión | Resueltas | Efecto medio | Efecto total | Con efecto positivo |
   |---|---|---|---|---|
   | Salida por deterioro (antes de la 0043) | 44 | −2,86 $ | −125,7 $ | 26 |
   | Toma parcial | 5 | −1,99 $ | −10,0 $ | 0 |
   | Rotación | 11 | +5,49 $ | +60,4 $ | 9 |

   El «efecto» del reparto no está en la tabla porque no es un
   contrafactual: es el retorno de la operación sobre su margen, en %. Por
   eso tampoco sirve para la fuente H1.

   Las salidas por deterioro costaban dinero desde el principio. No lo
   pidió ningún agente: lo vimos en el chat y se corrigió en la 0043. Hay
   más material sin usar. Desde el 1 de septiembre, 6 acciones han subido
   3 ATR o más en 5 sesiones en 17 ventanas, y los agentes solo entraron
   en 3. Nadie pregunta qué habría visto esos movimientos.

## 2. La idea

**Los agentes siguen operando igual** (son el grupo de control, ESTADO §1),
y se les añade una capa de investigación:

```
evidencia propia ──► hipótesis ──► experimento en el laboratorio ──► veredicto ──► el dueño decide
(decisiones,          (qué cambiar,   (contra la referencia            (validada /    (agente experimental
 movimientos,          dónde, cómo     al azar, criterio               refutada)      nuevo, o cambio al
 descartes)            medirlo)        fijado antes)                                  acabar el experimento)
```

La meta cobra otro sentido: lo que el agente persigue es **encontrar
cambios que mejoren su expectativa en R**, y lo que pide llega con
evidencia y con un resultado de laboratorio, no como una plantilla.

Lo que no cambia:

- Ninguna hipótesis toca a un agente que opera. Una hipótesis validada se
  convierte, si el dueño quiere, en un agente experimental nuevo (como
  Tendencia cripto) o en un cambio para cuando acabe el experimento.
- Los criterios del laboratorio siguen igual: sin mirar el futuro, con
  spread y huecos, corte de entrenamiento y validación, y superar a la
  referencia al azar (doc 06 §3.10).

## 3. De dónde salen las hipótesis (paso 1, determinista)

| Fuente | Qué mira | Hipótesis que genera | Datos |
|---|---|---|---|
| **H1 · Decisiones que cuestan** | Un tipo de decisión (deterioro, toma parcial o rotación) con al menos 20 resueltas en 90 días y un efecto medio negativo cuyo intervalo del 90 % (aproximación normal) no incluye el cero. Del deterioro solo cuenta lo posterior a la 0043, que cambió la regla | «Sin esta decisión, o con este parámetro, mi expectativa mejora» | `agente_decisiones` (ya existe) |
| **H2 · Movimientos perdidos** | Subidas de 3 ATR o más en 5 sesiones en activos de su universo en las que no entró. Para cada una, qué indicadores daban señal el día de partida y cuáles no | «Con el indicador X, o el umbral Y, habría entrado en estos movimientos sin entrar en otros peores» | `precios_diarios`, `indicadores_diarios`, `senales.senales_detalle` (ya existen) |
| **H3 · Descartes que subieron** | Señales que el agente descartó por un filtro de su perfil (fuerza, origen de los niveles, R:R, ATR alto o bajo) y lo que subieron en las 5 sesiones siguientes, en ATR, frente a su universo esos mismos días. Salta con al menos 30 descartes en 5 activos y una subida media cuyo intervalo del 90 % supera en 0,25 ATR a la del universo | «Este filtro me quita más de lo que me protege». Propone relajarlo: R:R mínimo 0,2 más bajo, una fuerza menos, el tope de ATR × 1,5 o el suelo × 0,5 | `agente_descartes` (0047): una fila por agente, activo, día y motivo, en cada ciclo |
| **H4 · Las plantillas de hoy** | Las siete del backlog | Las dos que se pueden medir en el laboratorio («cierre parcial» y «trailing stop») pasan además a ser hipótesis. Las otras cinco piden datos o infraestructura («ampliar el universo», «volatilidad de X», «señales más frecuentes», que es la cadencia del ETL…): siguen en el backlog, que es su sitio | `fn_disparadores_backlog` |

Cada generador corre en el corte semanal (lunes) y como mucho deja **una
hipótesis por agente y semana**: la de evidencia más fuerte. Es el freno a
la búsqueda a ciegas: si se prueban cien variantes, alguna sale bien por
azar. Las que no se prueban esperan su turno.

## 4. El contrato de una hipótesis

Tabla nueva `agente_hipotesis`. Es el formato común para las fuentes
deterministas y, en el paso 2, para el LLM:

| Campo | Qué es |
|---|---|
| `agente_id`, `origen` | Quién la propone y de dónde sale: `decision`, `movimiento`, `descarte`, `plantilla` o `llm` |
| `enunciado` | En una frase, lo que se cree. Por ejemplo, «Sin salida por deterioro, mi expectativa sube de −0,05 R a ≥ +0,05 R» |
| `evidencia` | JSON con lo que la respalda: las decisiones, los movimientos o los descartes, con fechas |
| `experimento` | JSON con lo que lanza el laboratorio: modo (`laboratorio`, `contra_azar`…), estrategia base, `parametros`, universo, clase y periodo. **Solo admite piezas que el laboratorio sabe ejecutar** |
| `criterio` | Fijado al crearla, antes de ver el resultado: mejora mínima en R en validación, intervalo sin el cero y percentil frente al azar |
| `estado` | `propuesta` → `en_prueba` → `validada` / `refutada` / `no_ejecutable` → `adoptada` / `archivada` (las dos últimas las decide el dueño) |
| `resultado`, `informe_url` | Las métricas del laboratorio y el enlace al job de Actions |

Una hipótesis que pide algo que el laboratorio no tiene (un indicador
nuevo) queda `no_ejecutable` y abre una petición `nueva_herramienta` en el
backlog. Esa sí la implementa Claude.

## 5. Cómo se prueban

- **Workflow `hipotesis.yml` (hecho en la I3)**: los lunes a las 02:00
  UTC, después del autodiagnóstico, lee hasta 3 hipótesis en `propuesta`
  y las prueba con `laboratorio/hipotesis.py`:
  1. El agente tal como opera frente al agente con el cambio, en el tramo
     de validación (el 30 % final de 5 años) del universo activo de sus
     clases.
  2. La referencia al azar (`AzarAgente`): el agente con el cambio
     entrando en días al azar con su misma frecuencia, en 20 tiradas.
  3. El veredicto con el criterio guardado. Exige al menos 30 operaciones,
     una mejora mínima en R, el intervalo del 90 % por encima de cero y el
     percentil frente al azar.

  Escribe el resultado, el estado y el enlace al informe, deja un evento
  del agente y se puede lanzar a mano para una hipótesis concreta. Usa la
  clave de servicio, como el ETL.
- **Requisito del laboratorio (hecho en la I2)**: la estrategia `agente`
  reproduce a un agente con metas con cada pieza encendible: banda de
  volatilidad, deterioro en dos lecturas, toma parcial (el motor la admite
  ahora), stop que sigue y condición de entrada del catálogo.
  `laboratorio/agentes.py` traduce la estrategia de producción a esos
  parámetros. **No reproduce** la rotación ni el reparto (dependen de la
  cartera entera) ni la cadencia intradía: en el laboratorio, un día es una
  lectura. Por eso una hipótesis sobre la rotación queda `no_ejecutable`.
- **Concordancia con producción (hecho en la I3)**: no es posible una
  paridad exacta con las operaciones reales, porque los agentes deciden
  cada 30 minutos y el laboratorio, al cierre. `laboratorio/concordancia.py`
  mide qué entradas reales tienen su gemela en el laboratorio (mismo
  activo, entre 3 días antes y 1 después) y cuántas del laboratorio no
  tienen una real. Va en el resultado de cada hipótesis y, por debajo del
  50 %, avisa de que el veredicto describe al laboratorio más que al
  agente.
- **Límite de pruebas**: como mucho 3 por semana (una por agente). El
  número de pruebas acumuladas se guarda en el criterio, y el percentil
  exigido frente al azar sube **un punto por cada prueba anterior**, hasta
  99. Así, probar mucho no regala validaciones.
- **Primera prueba real (2026-10-24, sin escribir en la base)**: la
  hipótesis que la H2 propondrá a Prudencia, «entrar también con el MACD
  positivo» en acciones, queda **refutada**. Su expectativa en validación
  baja de +0,10 R a +0,006 R (de 53 a 120 operaciones), y solo supera al
  65 % de las tiradas al azar (se exige el 90 %). Tardó 24 segundos con 21
  acciones.

## 6. Dónde se ve

- **Agentes → «Lo que investiga»**: por agente, sus hipótesis con su
  evidencia, el estado y el resultado del laboratorio. Sustituye a la
  sección de peticiones del backlog para lo que sea medible.
- **Administración**: adoptar o archivar una hipótesis validada, con
  auditoría, como el backlog de hoy.
- **El progreso del agente** deja de ser solo «días con la meta
  cumplida». También cuenta las hipótesis propuestas, probadas y validadas.

## 7. Paso 2: el LLM

Lo que aporta el LLM es lo que el paso 1 no puede: ideas que nadie ha
programado («el MACD semanal confirma estas rupturas», «estas pérdidas se
concentran el día antes de resultados»).

- **Entrada**: el paquete de evidencia semanal de cada agente (lo mismo
  que usan H1–H3, resumido) y el catálogo de piezas del laboratorio.
- **Salida**: hipótesis en el mismo contrato (§4), validadas contra un
  esquema JSON. Si no cumplen el esquema, no entran.
- **Filtro**: pasan por el mismo laboratorio y el mismo límite de pruebas.
  El LLM propone; no decide ni opera.
- **Coste**: una llamada por agente y semana. Se mide en una prueba antes
  de activarlo. Sería el primer coste recurrente del proyecto, así que lo
  decide el dueño (ESTADO §3.4, «Capa narrativa con LLM»). La clave
  viviría como secreto de GitHub Actions, no en la base de datos.

## 8. Entregas

| Entrega | Qué | Depende de |
|---|---|---|
| **I1 · Hipótesis y fuentes H1, H2 y H4** ✅ | 0046: `agente_hipotesis`, `v_condiciones_dia`, `fn_generar_hipotesis` en el autodiagnóstico de los lunes, `rpc_revisar_hipotesis`, pestaña «Investigan» en Agentes y revisión en Administración. Invariante I96 | — |
| **I2 · Laboratorio que reproduce a los agentes** ✅ | Estrategia `agente`, toma parcial en el motor, catálogo `CONDICIONES` (el mismo que la 0046) y `laboratorio/agentes.py`. 15 pruebas nuevas | — |
| **I3 · Prueba automática** ✅ | `hipotesis.yml`, `laboratorio/hipotesis.py` (veredicto y percentil creciente), `AzarAgente`, `laboratorio/concordancia.py` y el resultado en las pestañas de Agentes y Administración. La estrategia `agente` precalcula confluencia y niveles para que las tiradas al azar sean rápidas. 18 pruebas nuevas | I1 e I2 |
| **I4 · Registro de descartes y H3** ✅ | 0047: `agente_descartes` (120 días, en cada ciclo), `fn_registrar_descartes` y la H3 en el generador. En el laboratorio, `fuerza_minima`. Invariante I97 | I1 |
| **I5 · LLM** | Proveedor de hipótesis con el mismo contrato | I3 y la decisión del dueño |

## 9. Decisiones abiertas

| Decisión | Por defecto |
|---|---|
| ¿Una hipótesis por agente y semana? | Sí. Se puede subir cuando haya más historial de pruebas |
| Criterio de validación | Mejora de al menos +0,05 R en validación, intervalo sin el cero, y percentil ≥ 90 frente a 30 tiradas al azar (sube con las pruebas acumuladas) |
| ¿Tendencia cripto también investiga? | No mientras dure su experimento: cambiarle las reglas invalidaría su veredicto. Sí se le puede generar H2 como información |
| ¿Qué hacer con la meta diaria? | Se mantiene en los agentes con metas (grupo de control). Los agentes nuevos no la llevan |
