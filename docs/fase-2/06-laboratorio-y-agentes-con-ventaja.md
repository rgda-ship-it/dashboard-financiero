# F. Laboratorio de estrategias y agentes con ventaja

> **Autor**: Analista Cuantitativo / Risk Manager (equipo virtual)
> **Fecha**: 2026-10-11
> **Estado**: **Aprobada por el dueño** y ejecutada. Laboratorio, primera
> ronda y prueba de robustez hechos (§3.7). Resultado: un agente
> experimental, «Tendencia cripto» (D24, doc 07). Pendientes en
> [`../ESTADO.md`](../ESTADO.md) §3.2.
> **Contexto**: doc 05 y la conclusión del dueño tras D21–D23: las
> correcciones hacen el sistema más honesto, pero no lo acercan a sus metas.

---

## 1. El diagnóstico, en dos frases

1. **Las metas diarias son inalcanzables de forma sostenida**: 2 % al día
   compuesto son × 147 al año; 5 %, × 220.000; 7 %, × 26 millones. Los
   mejores fondos ganan un 20–30 % anual. Perseguirlas a cualquier precio
   empuja a concentrar riesgo y acelera la ruina.
2. **No sabemos si las señales tienen ventaja, y lo poco medido dice que
   no**: 71 de 96 decisiones de entrada resueltas, negativas. Sin
   expectativa positiva después de costes, ninguna mejora de tamaño,
   tiempo o prudencia gana: solo cambia la velocidad de la pérdida.

Y hoy cada idea se prueba en vivo, a un ciclo cada 5 minutos: semanas por
idea, con muestras (3 operaciones por práctica) que no prueban nada.

---

## 2. La decisión del dueño

- **Los tres agentes actuales siguen como están**, persiguiendo sus metas:
  son el **grupo de control**.
- **Agentes nuevos**, uno por cada estrategia que **demuestre ventaja en el
  laboratorio**, con otro objetivo: maximizar la ganancia esperada después
  de costes con un límite de riesgo. Mismo simulador, mismo spread, mismos
  huecos, mismos guardarraíles, mismo saldo inicial de 500 $: la
  comparación es limpia.
- Ninguna estrategia sin ventaja demostrada recibe un agente.

---

## 3. El laboratorio

### 3.1 Qué hace

Reproduce el histórico **día a día, sin mirar el futuro**, con las mismas
reglas de ejecución que el simulador:

| Regla | En el laboratorio |
|---|---|
| Señal | Con los datos **hasta el cierre del día t**; se entra en la apertura de t + 1 |
| Precio de entrada | Apertura de t + 1 **más medio spread** (D23) |
| Stop y objetivo | Se comprueban con el máximo y el mínimo de cada día siguiente, al **precio de venta** |
| Mismo día toca stop y objetivo | Gana el stop (M2, lado conservador) |
| Hueco de apertura más allá del stop | Sale a la apertura, no al stop (M3') |
| Spread | Los valores de la 0034: 0,03 $ por acción, BTC 5 $, ETH 0,10 $, resto de cripto 0,10 % |

### 3.2 Datos

- **Acciones**: velas diarias de Yahoo, los últimos años disponibles.
- **Cripto**: velas diarias de Yahoo (`BTC-USD`, `ETH-USD`…), que traen
  máximo y mínimo para todo el histórico (CoinGecko gratis solo da 30 días
  de máximos y mínimos).
- **Universo**: el catálogo activo de producción (si el laboratorio tiene
  acceso a la base de datos) o una lista dada.

### 3.3 Dónde corre

En **GitHub Actions** (`laboratorio.yml`), lanzado a mano: tiene acceso a
Yahoo y a la base de datos. El informe sale en el resumen del job y las
operaciones en un CSV descargable. Claude puede lanzarlo y leer el
resultado.

### 3.4 Qué mide

Por estrategia, por clase de activo y en total:

| Medida | Para qué |
|---|---|
| Operaciones | Sin muestra no hay conclusión |
| % de aciertos, ganancia y pérdida media | Forma de la estrategia |
| **Expectativa por operación**, en R (múltiplos del riesgo) y en % | **La medida central**: ¿gana dinero cada operación, de media, después de costes? |
| Factor de beneficio | Ganado ÷ perdido |
| Caída máxima | Con un riesgo fijo del 1 % por operación |
| Días medios por operación | Horizonte real |
| **t de la expectativa** e intervalo por bootstrap | ¿Es ventaja o suerte? |

### 3.5 Cuándo una estrategia «tiene ventaja»

Se divide el histórico: **70 % para diseñar, 30 % final para validar**,
sin tocar la estrategia entre medias. Pasa si, **en el tramo de
validación**:

1. al menos **30 operaciones**;
2. **expectativa > 0,10 R** después de spread;
3. el **intervalo de confianza del 90 %** de la expectativa **por encima de
   cero**;
4. factor de beneficio > 1,2;
5. y en el tramo de diseño no era peor que en el de validación por un
   margen enorme (señal de que se ajustó al ruido).

Son exigentes a propósito: es preferible no tener agente a tener uno que
pierde con buena cara.

### 3.6 Las estrategias de la primera ronda

| Estrategia | Mercado | Entrada | Salida |
|---|---|---|---|
| **Actual** | Ambos | La de hoy: confluencia alcista media/alta, niveles acotados en ATR (D21) | Stop o objetivo |
| **Tendencia** | Cripto (y acciones, para comparar) | Cierre por encima del máximo de 20 días, con el precio sobre su media de 200 | Stop inicial a 2 ATR, que sube con el precio (3 ATR bajo el mejor cierre); o cierre bajo el mínimo de 10 días |
| **Reversión** | Acciones (y cripto, para comparar) | RSI de 2 días < 10 con el precio sobre su media de 200 | Cierre por encima de su media de 5 días, o a los 5 días; stop a 3 ATR |

La «Actual» es la referencia: dice cuánto vale lo que ya tenemos.

### 3.7 Primera ronda y prueba de robustez

Resultado de la primera ronda (5 años, 43 activos): solo **tendencia en
cripto** pasa el §3.5 (validación: 79 operaciones, +0,69 R, IC 90 %
[+0,06, +1,44], factor 2,39, sin desplome frente al diseño). Ninguna pasa en
acciones; la actual queda en +0,14 R con el intervalo incluyendo el cero.

Un aprobado justo puede ser suerte, así que antes de crear un agente se
somete a una prueba de robustez (`laboratorio/robustez.py`, modo
`robustez` del workflow):

1. **Correlación**: intervalo remuestreando meses enteros, no operaciones.
2. **Concentración por activo**: R de cada uno y veredicto quitando los 1,
   2 y 3 mejores.
3. **Concentración por año.**
4. **Parámetros**: rejilla de variantes (en tendencia, ruptura 10–55 días,
   stop que sigue a 2,5–4 ATR y stop inicial a 1,5–3 ATR); una ventaja real
   aparece en la mayoría, no solo en la elegida.
5. **Costes**: spread tres veces peor.
6. **Supervivencia**: las criptos del top de octubre de 2021 que no están en
   el universo, incluidas las que se hundieron (Terra, FTX…); para la
   estrategia son datos nunca vistos.

Se crea el agente si la referencia sigue en pie con el intervalo por meses,
no depende de un activo, la mayoría de variantes tiene expectativa positiva
y en el universo de 2021 la expectativa es positiva.

**Resultado (2026-10-11)**: cumple 3 de 4.

| Prueba | Resultado |
|---|---|
| Intervalo por meses | [+0,02, +1,49] R ✅ |
| Concentración por activo | ❌ zcash da ~46 de los ~54 R de la validación; sin ella, +0,13 R con el intervalo incluyendo el cero. 13 de 14 criptos con expectativa positiva |
| Concentración por año | 2024 aporta 169 de 216 R; 2022, −7 R con solo 10 operaciones (el filtro de la media de 200 la mantuvo fuera) |
| Parámetros | 45 de 45 variantes positivas en validación; 18 pasan el criterio completo, todas con ruptura ≥ 20 días ✅ |
| Spread × 3 | +0,63 R, intervalo [−0,02, +1,43] |
| Criptos del top de 2021 | +0,65 R en 5 años ✅; +0,09 R en el tramo de validación |

Lectura: ventaja real pero no demostrada, con forma de «pocas ganancias
enormes».

**Con 10 años de histórico (2026-10-11)**, validación desde 2023-10, tres años:

| Estrategia | Acciones (validación) | Cripto (validación) |
|---|---|---|
| Actual | +0,13 R, IC [−0,04, +0,30] ❌ | −0,11 R ❌ |
| **Tendencia** | +0,12 R, IC [−0,03, +0,29], factor 1,24 ❌ (por poco; en diseño +0,17 R con IC > 0) | **+1,09 R, IC [+0,57, +1,70], 203 operaciones, factor 3,11 ✅** |
| Reversión | +0,01 R ❌ | +0,01 R ❌ |

Tendencia en cripto sale reforzada: más operaciones y un intervalo muy por
encima de cero. Ojo: el universo cripto se eligió hoy, así que a 10 años el
sesgo de supervivencia pesa más que a 5 (solana o avalanche no existían en
2016). En acciones, tendencia ronda +0,12–0,17 R de forma estable, pero no
llega al criterio: sigue sin agente. El dueño eligió la opción A, un **agente experimental** con
criterio de retirada fijado de antemano (D24, doc 07), en lugar de seguir
solo en el laboratorio.

---

## 4. Lo que viene después

1. **Laboratorio** con las tres estrategias. ✅ Hecho, con la prueba de robustez (§3.7).
2. **Un agente por cada estrategia que pase** el §3.5 (el primero, experimental: «Tendencia cripto», doc 07), de un tipo nuevo:
   comparte simulador, monitor, spread y guardarraíles, pero decide con su
   propia función (ganancia esperada con límite de riesgo, tamaño según la
   ventaja medida) y sin meta diaria que perseguir.
3. **Panel comparativo**: agentes nuevos frente a agentes con metas, con
   las mismas medidas. ✅ Hecho en la 0040 (`v_comparativa_agentes`).
4. Más adelante, un **agente de cartera** que combine las estrategias con
   ventaja y reparta el riesgo entre ellas.
