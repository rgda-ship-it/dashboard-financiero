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
   | Reparto | 133 | −0,70 $ | −93,2 $ | 40 |
   | Toma parcial | 5 | −1,99 $ | −10,0 $ | 0 |
   | Rotación | 11 | +5,49 $ | +60,4 $ | 9 |

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
| **H1 · Decisiones que cuestan** | Un tipo de decisión con al menos 20 resueltas y un efecto medio negativo cuyo intervalo (bootstrap, 90 %) no incluye el cero | «Sin esta decisión, o con este parámetro, mi expectativa mejora» | `agente_decisiones` (ya existe) |
| **H2 · Movimientos perdidos** | Subidas de 3 ATR o más en 5 sesiones en activos de su universo en las que no entró. Para cada una, qué indicadores daban señal el día de partida y cuáles no | «Con el indicador X, o el umbral Y, habría entrado en estos movimientos sin entrar en otros peores» | `precios_diarios`, `indicadores_diarios`, `senales.senales_detalle` (ya existen) |
| **H3 · Descartes que subieron** | Señales que el agente descartó por un filtro concreto (R:R, ATR alto, fuerza, dirección) y qué hicieron en las 5 sesiones siguientes | «Este filtro me quita más de lo que me protege» | **Falta**: hoy solo se guarda el recuento por motivo (`agente_dias.descartes`), no qué señal se descartó |
| **H4 · Las plantillas de hoy** | Las siete del backlog | Las que se pueden medir pasan a ser hipótesis («señales más frecuentes» → «bajar la fuerza mínima»). Las que no, se retiran | `fn_disparadores_backlog` |

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

- **Workflow `hipotesis.yml`**: los lunes, después del corte semanal, lee
  las hipótesis en `propuesta`, ejecuta el laboratorio con su
  `experimento` y escribe el `resultado` y el veredicto según el
  `criterio`. Usa la clave de servicio, como el ETL.
- **Requisito del laboratorio**: hoy `Actual` reproduce las entradas de
  los agentes con metas, pero no sus salidas (deterioro, toma parcial,
  rotación, reparto). Para probar H1, el laboratorio tiene que modelarlas
  con parámetros que se puedan encender y apagar, y una prueba de paridad
  que compare el laboratorio con las operaciones reales en las mismas
  fechas (como la de `cartera.py`).
- **Límite de pruebas**: como mucho 3 por semana (una por agente). El
  número de pruebas acumuladas se guarda, y el percentil exigido frente al
  azar sube con él. Así, probar mucho no regala validaciones.

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
| **I1 · Hipótesis y fuentes H1, H2 y H4** | Tabla `agente_hipotesis`, generadores en el corte semanal, retirada de las plantillas no medibles, panel «Lo que investiga» (sin laboratorio todavía: estado `propuesta`). Invariantes | — |
| **I2 · Laboratorio que reproduce a los agentes** | Salidas por deterioro, toma parcial y rotación en `Actual`, con parámetros y prueba de paridad | — (en paralelo con I1) |
| **I3 · Prueba automática** | `hipotesis.yml`, veredicto, límite de pruebas y panel con resultados | I1 e I2 |
| **I4 · Registro de descartes y H3** | Guardar qué señal se descartó y por qué (con retención, como los eventos) | I1 |
| **I5 · LLM** | Proveedor de hipótesis con el mismo contrato | I3 y la decisión del dueño |

## 9. Decisiones abiertas

| Decisión | Por defecto |
|---|---|
| ¿Una hipótesis por agente y semana? | Sí. Se puede subir cuando haya más historial de pruebas |
| Criterio de validación | Mejora de al menos +0,05 R en validación, intervalo sin el cero, y percentil ≥ 90 frente a 30 tiradas al azar (sube con las pruebas acumuladas) |
| ¿Tendencia cripto también investiga? | No mientras dure su experimento: cambiarle las reglas invalidaría su veredicto. Sí se le puede generar H2 como información |
| ¿Qué hacer con la meta diaria? | Se mantiene en los agentes con metas (grupo de control). Los agentes nuevos no la llevan |
