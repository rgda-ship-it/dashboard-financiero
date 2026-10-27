# Fase 3 — Qué falta para que el dashboard y los agentes cumplan sus objetivos

> **Para qué sirve**: responde al dueño (2026-10-27): con todo ordenado,
> ¿qué nos falta? Separa lo que es **técnico** (se puede construir) de lo
> que es **una decisión** (ningún código lo resuelve), y propone un orden.
> **Método**: datos de producción en solo lectura **desde el 2026-10-10**
> (0030) salvo que se diga otra cosa (ver `../CRONOLOGIA.md`), resultados
> del laboratorio (docs fase-2/06 y fase-3/02 a 07) y el estado de
> `../ESTADO.md`.
> **Fecha**: 2026-10-27.

---

## 1. Resumen

1. **Los agentes con metas no pueden cumplir su objetivo, y no es un
   fallo técnico.** Una meta del 2–7 % diario compuesto exige una ventaja
   que ninguna señal ha demostrado. Lo que falta es **decidir qué objetivo
   deben tener**; con el actual, el sistema seguirá «fallando» siempre.
2. **El experimento no tiene fecha de fin** y depende de que Tendencia
   cripto haga 30 operaciones. En 15 días ha hecho 0: el mercado cripto
   está bajista. Falta un tope de tiempo y un criterio para el grupo de
   control.
3. **El grupo de control no está congelado**: los ajustes automáticos
   siguen activos y ya cambiaron a dos agentes (15-10). Hay que congelarlos
   o aceptarlo por escrito.
4. **Faltan operaciones para poder juzgar**: con la dispersión real
   (1,1–1,6 R por operación), demostrar +0,1 R exige unas 400 operaciones
   por agente; al ritmo de hoy son más de 15 meses. Solo una ventaja
   grande (+0,3 R) se vería en 2–3 meses.
5. **El dashboard no mide lo que recomienda**: el escáner dice «Comprar»,
   pero nadie sabe si esas recomendaciones ganan. Tampoco hay una
   referencia de mercado (comprar y mantener) con la que comparar a los
   agentes.
6. **En acciones no hay ninguna estrategia con ventaja** frente al azar, y
   en cripto la que hay (tendencia, y el Santo Grial) depende de haber
   elegido hoy las criptos que sobrevivieron.

## 2. Los objetivos, tal como se definieron

| Pieza | Objetivo | Dónde |
|---|---|---|
| Dashboard | Terminal personal: escanear un universo, recomendar apalancamiento dentro de un tope y diagnosticar la cartera, a coste 0 | `README.md` |
| Agentes con metas | Cumplir la meta diaria (2, 5 y 7 %) con interés compuesto hasta el objetivo final (1.000.000 $) | doc fase-2/03 |
| Experimento | Saber si alguna estrategia tiene **ventaja demostrada**; los agentes con metas, como grupo de control | doc fase-2/06 §2, D24 |
| Tendencia cripto | Veredicto a las 30 operaciones: retirar, observar o validar | doc fase-2/07 §6 |
| Agentes investigadores | Que los agentes propongan cambios con su evidencia y el laboratorio los pruebe | doc fase-3/01 |
| Fase 3 | Que todo lo que corre solo sea fiable y que los fallos se vean el mismo día | doc fase-3/00 §3 |

## 3. Dónde estamos (2026-10-27)

| Medida | Prudencia | Cadencia | Audacia | Tendencia cripto |
|---|---|---|---|---|
| Rentabilidad desde el alta (29-09) | +4,3 % | −2,0 % | −15,7 % | 0 % |
| Desde el experimento (11-10): R total, cierres | +2,74 R, 10 | −0,98 R, 4 | −0,55 R, 9 | 0 operaciones |
| Lo que exigiría su meta en 20 sesiones | ×1,49 | ×2,65 | ×3,87 | — |
| Expectativa en el laboratorio, 10 años | −0,02 R | +0,04 R | +0,07 R | +0,86 R (cripto) |
| Entradas por semana desde el 12-10 | 1–7 | 0–5 | 6–7 | — |
| Saldo libre para operar | 437 $ | 179 $ | **0,92 $** | 500 $ |

Mercado en el mismo periodo (desde el 12-10, cierre a cierre): las 32
acciones del universo, −0,5 % de media; las 15 criptos, −6,3 %; bitcoin,
−2,5 %. Prudencia va por delante de comprar y mantener; Cadencia y
Audacia, por detrás. Con 4–10 cierres, nada de esto es significativo.

**Fiabilidad**: hecha (Fase 3, E1–E3). ETL en verde desde el 24-10, panel
de salud, credenciales con aviso, revisión de los lunes en una consulta,
Administración ordenada y documentación con lo vigente separado de lo
histórico.

## 4. Lo que falta, por objetivo

Cada brecha dice si es **técnica** (🔧, se construye) o una **decisión**
(👤, la toma el dueño), y lo que propongo.

### 4.1 Agentes con metas: el objetivo no es alcanzable

- **El dato**: con la expectativa del laboratorio (de −0,02 a +0,07 R) y
  un 1,5–5 % de riesgo por operación, el rendimiento esperado por
  operación está entre −0,03 % (Prudencia) y +0,35 % (Audacia) del
  capital. Audacia, la mejor, necesitaría unas **20 operaciones al día**
  para su 7 %; Cadencia, unas 40 para su 5 %; Prudencia, con expectativa
  negativa, ninguna cantidad basta. Hacen una al día como mucho. El doc fase-2/05 ya lo concluyó: la meta diaria es
  inalcanzable por diseño.
- **Qué falta** 👤: decidir qué deben perseguir. Opciones:
  1. **Mantenerlos como grupo de control tal cual** hasta el final del
     experimento (lo decidido hoy). Su valor es de comparación, no de
     resultado.
  2. **Cambiar la vara de medir** al acabar el experimento: expectativa
     en R positiva y demostrada, caída máxima acotada y batir a comprar y
     mantener su universo. Las metas diarias pasarían a ser informativas.
  3. **Retirarlos** al final del experimento y quedarse solo con agentes
     de estrategia (como Tendencia cripto).
- **Recomendación**: la 1 hasta el final y después la 2. Mientras, que el
  dashboard enseñe la expectativa y la comparación con el mercado antes
  que la meta (§4.5), para que la pantalla no diga cada día «meta no
  cumplida» de algo que se sabe imposible.

### 4.2 El experimento: sin fecha de fin y con un control que se mueve

- **Sin fecha de fin** 👤: el veredicto llega a las 30 operaciones de
  Tendencia cripto, «unos 6–7 meses» según el laboratorio (≈ 50 al año en
  14 criptos). Pero en un mercado bajista no entra: en 15 días, 0. Si
  sigue así, el experimento no acaba nunca, y con él quedan en espera las
  Entregas B, C y E, los tres cambios validados y el agente de cartera.
  **Decidido** (dueño, 2026-10-27): tope el **2027-04-30**. Si para
  entonces no hay 30 operaciones, se juzga con las que haya y con el
  laboratorio de ese periodo.
- **El control se mueve solo** 🔧👤: los ajustes automáticos de la 0016
  siguen activos. El 15-10, Audacia y Cadencia apagaron la salida por
  deterioro; la de Cadencia se apoyó sobre todo en salidas de antes de la
  0043, cuando bastaba una lectura. Eso contradice el principio 2 de la
  Fase 3 («el grupo de control no cambia de reglas»).
  **Decidido** (dueño, 2026-10-27; 0052): congelar los ajustes automáticos mientras
  `consecuencias_semanales = false` (una migración pequeña con su
  invariante, I102), y dejar los dos del 15-10 como están, documentados
  en `CRONOLOGIA.md`: volver atrás también es cambiar las reglas.

### 4.3 Juzgar requiere más operaciones de las que hay

- **El dato**: con una desviación de 1,1–1,6 R por operación, el
  intervalo del 90 % deja de incluir el cero cuando
  n ≥ (1,645 × σ / E)². Para E = +0,1 R son **≈ 330–700 operaciones**;
  para +0,3 R, ≈ 40–80. Los agentes hacen unas 25 entradas al mes.
- **Qué falta** 🔧: asumirlo en cómo se lee el panel. Propuesta: que la
  comparativa enseñe, junto a la expectativa, **cuántas operaciones faltan
  para poder concluir algo** con la desviación observada. Así se evita
  leer como tendencia lo que es ruido de 10 cierres.
- **Y el laboratorio no ve lo intradía** 🔧: la concordancia con las
  reglas de hoy es del 55–69 %, y lo que falta es el R:R que el agente
  encuentra durante la sesión y al cierre ya no está. Las hipótesis sobre
  la entrada se prueban, por tanto, sobre un agente algo distinto.
  **Propuesta**: un modo intradía del laboratorio con velas de 1 hora
  (Yahoo da 2 años). Es caro; solo merece la pena si alguna hipótesis de
  entrada se queda en el límite.

### 4.4 Encontrar una ventaja

- **Acciones**: nada supera al azar (actual, ruptura con volumen, momento,
  retroceso, Santo Grial, filtros de ADX, R:R). Quedan dos líneas sin
  probar 🔧:
  1. **Fuerza relativa frente al mercado** (ya prevista): necesita la
     serie del S&P 500 en el motor. Es también la referencia del §4.5.
  2. **Datos fundamentales** (calidad y valor), contra el azar y en un
     universo sin sesgo de supervivencia (los ETF).
- **Cripto**: la ventaja depende del universo elegido hoy 👤. Antes de un
  segundo agente cripto (el Santo Grial), mejor esperar al veredicto de
  Tendencia cripto, que es la misma apuesta.
- **Validación más exigente** 🔧: el *walk-forward* (ventanas móviles)
  sigue pendiente. Útil cuando haya una candidata seria.

### 4.5 El dashboard como herramienta de decisión

- **El escáner no se mide** 🔧: da «Comprar / Esperar / No comprar» con
  niveles, pero no sabemos si los «Comprar» ganan. Con las señales
  históricas y `precios_diarios` se puede medir: qué pasó a 5, 10 y 20
  sesiones de cada «Comprar», frente a los «No comprar» y al azar. Es
  barato (una vista y una sección en la revisión de los lunes), y es lo
  que dice si el escáner sirve para operar de verdad.
- **No hay referencia de mercado** 🔧: la comparativa de agentes no tiene
  un «comprar y mantener» del universo (acciones, cripto y bitcoin) desde
  la misma fecha. Sin ella no se sabe si un agente aporta algo o solo
  sigue al mercado. Propuesta: una fila de referencia en
  `v_comparativa_agentes` y en la pantalla de Agentes.
- **Lo que el dueño ve primero** 🔧: la pantalla de Agentes abre con la
  meta diaria y el progreso hacia el millón. Propuesta: que abra con la
  expectativa, la referencia de mercado y «operaciones que faltan para
  concluir».
- **Avisos fuera del dashboard** 👤: hoy se decidió que no. Con el panel
  de salud y la revisión de los lunes es suficiente mientras el dueño
  entre a diario; si no, un correo semanal con la revisión sería lo
  mínimo.

### 4.6 Fiabilidad: cabos sueltos

Pequeños, todos técnicos 🔧:

- **`hipotesis.yml` depende del `schedule` de GitHub**, que el 26-10 llegó
  con 5 horas de retraso. Dispararlo desde `pg_cron`, como el ETL (la
  función ya existe; solo admite los dos ETL).
- **El rol de lectura no ve `cron.job`**: no se puede comprobar que una
  tarea programada existe y está activa. Darle `select` sobre `cron.job`
  (solo lectura de metadatos).
- **Datos**: Yahoo da cotizaciones congeladas en Nasdaq (el spread no se
  mide ahí) y en cripto solo hay 30 días con rango real, así que el ATR y
  el ADX de cripto en producción son ruidosos. Aceptable mientras sea
  gratis; anotado.
- **Audacia sin saldo libre** (0,92 $ con 4 posiciones): con un 5 % de
  riesgo por operación y stops estrechos, el margen de cuatro posiciones
  agota el saldo. Es su diseño, no un fallo, pero conviene que el panel lo
  diga (ya lo dice la tarjeta «Para operar»).

## 5. Orden propuesto

| # | Qué | Tipo | Coste | Por qué ahora |
|---|---|---|---|---|
| 1 | Decidir el **tope de fecha del experimento** y qué pasa con los agentes con metas al acabar (§4.1, §4.2) | 👤 | — | Todo lo demás espera a esto |
| 2 | **Congelar los ajustes automáticos** durante el experimento (§4.2) | 🔧 | 1 migración | Cada día que pasa el control puede moverse otra vez |
| 3 | **Referencia de mercado** en la comparativa y en Agentes (§4.5) | 🔧 | 1 migración + pantalla | Sin ella no se puede juzgar a nadie |
| 4 | **Medir el escáner** (§4.5) | 🔧 | 1 vista + revisión | Dice si el dashboard sirve para operar |
| 5 | «Operaciones que faltan para concluir» en la comparativa (§4.3) | 🔧 | pequeño | Evita leer ruido como tendencia |
| 6 | `hipotesis.yml` desde `pg_cron`; `cron.job` legible (§4.6) | 🔧 | pequeño | Fiabilidad |
| 7 | **Fuerza relativa** en el laboratorio (§4.4) | 🔧 | medio | Siguiente línea de ventaja en acciones; reutiliza la serie del punto 3 |
| 8 | Fundamentales y *walk-forward* (§4.4) | 🔧 | grande | Cuando lo anterior esté |

Los puntos 2 a 6 los puedo hacer sin decisiones del dueño, salvo el 2,
que cambia (a mejor) el comportamiento del grupo de control y conviene
que lo apruebe.
