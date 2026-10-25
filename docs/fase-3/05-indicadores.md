# Fase 3 — ADX y media de 20: indicadores nuevos

> **Para qué sirve**: responde a la pregunta del dueño (2026-10-25):
> ¿hay más indicadores que pudiéramos añadir? Se empezó por los dos más
> baratos y con mejor pista: el **ADX** (fuerza de la tendencia) y la
> **distancia a la media de 20** (sobreextensión).
> **Método**: no votan en la confluencia, porque votar cambia qué se
> compra, y eso solo se decide con el laboratorio. Entran en el
> **catálogo de condiciones**, que comparten la fuente H2 de las
> hipótesis (cada lunes, cada agente mira si alguna condición habría
> anticipado las subidas que se perdió) y el laboratorio.

---

## 1. Qué se añadió

| Condición | Regla |
|---|---|
| `adx_fuerte` | ADX(14) ≥ 25 |
| `adx_debil` | ADX(14) < 20 |
| `cerca_media_20` | cierre entre la media de 20 y 1 ATR por encima |
| `sobreextendido` | cierre a más de 2 ATR por encima de la media de 20 |
| `no_sobreextendido` | cierre a 2 ATR o menos por encima de la media de 20 |

- **Motor** (`indicadores/tecnicos.py`): `SMA_20` y `ADX_14`. El ADX se
  calcula como el ATR: solo sobre velas con máximo y mínimo reales, así
  que en cripto (30 días de rango real) sale para los últimos días o no
  sale.
- **0049**: `indicadores_diarios.sma_20` y `adx_14`, `v_condiciones_dia`
  con las cinco condiciones y el generador de hipótesis con el catálogo
  ampliado. Invariante I99.
- **Laboratorio**: el catálogo `CONDICIONES` y un parámetro nuevo,
  `filtro`: entra SOLO si se cumple. `condicion` es lo contrario: entra
  TAMBIÉN si se cumple. Una prueba exige que el catálogo de SQL (la vista
  y el generador) y el de Python tengan los mismos nombres.
- **El ETL** empezará a escribir el ADX y la media de 20 en el PR
  siguiente a aplicar la 0049. Escribirlos antes haría fallar el ETL.

## 2. Ronda del laboratorio

Cada agente con su estrategia real, 45 activos de producción, y el
criterio de las hipótesis: mejora de +0,05 R, intervalo del 90 % por
encima de cero y percentil ≥ 90 frente a 20 tiradas al azar.

**A 5 años:**

| Filtro | Prudencia (−0,04 R) | Cadencia (+0,01 R) | Audacia (+0,20 R) |
|---|---|---|---|
| Solo con tendencia fuerte (ADX ≥ 25) | +0,00 R, 65 ops ❌ | +0,19 R, 21 ops ❌ (pocas) | +0,23 R, 65 ops ❌ (p90, IC con el cero) |
| No sobreextendido | sin efecto ❌ | sin efecto ❌ | sin efecto ❌ |
| Cerca de la media de 20 | 1 operación ❌ | 4 operaciones ❌ | 6 operaciones ❌ |

**A 10 años**, solo con tendencia fuerte:

| | Prudencia | Cadencia | Audacia |
|---|---|---|---|
| Agente actual | −0,02 R, 222 ops | +0,04 R, 93 ops | +0,06 R, 231 ops |
| Con ADX ≥ 25 | +0,00 R, 113 ops ❌ (p55) | **+0,33 R, 39 ops ✅** (IC [+0,06, +0,61], p90) | −0,01 R, 114 ops ❌ (p50) |

## 3. Lo que enseña: los agentes compran retrocesos

Los filtros de sobreextensión no cambian nada, y «cerca de la media de 20»
deja casi sin entradas. Medido en 10 acciones y 5 años: **el 97 % de las
entradas están por debajo de su media de 20**, con una mediana de 0,67 ATR
por debajo. Solo un 3 % entra entre la media y 1 ATR por encima, y
ninguna más arriba.

La causa es el R:R mínimo. Con el objetivo en la resistencia de 20 velas
y el stop en el soporte, solo hay R:R suficiente cuando el precio está en
la parte baja de su rango. Así, un sistema que lee la confluencia como
tendencia **compra, en la práctica, retrocesos dentro de una tendencia**.
No es un fallo, pero conviene saberlo:
- el riesgo de «comprar lo que ya subió demasiado» no existe en estos
  agentes, y por eso esos filtros no aportan;
- su riesgo es el contrario: comprar algo que cae y sigue cayendo, que es
  lo que mide la salida por deterioro.

## 4. Qué se decide

- **El ADX ayuda a Cadencia, no a los otros dos.** «Cadencia solo con
  ADX ≥ 25» pasa a 10 años (+0,04 → +0,33 R, IC [+0,06, +0,61]) y apunta
  igual a 5 (+0,01 → +0,19 R, con solo 21 operaciones). En Prudencia no
  cambia nada, y a Audacia la empeora. Encaja con lo que se vio en los
  stops (doc 03): Cadencia opera lo tranquilo y mejora cuando se le exige
  una tendencia clara. Cautelas: son pocas operaciones (39 y 21), filtrar
  por ADX deja menos de la mitad de las entradas, y en esta tanda se han
  hecho 12 pruebas. Cadencia es grupo de control: **se guarda para el
  final del experimento**, como los otros dos cambios validados, y se
  revisa entonces con los datos reales.
- **El ADX queda en el catálogo** para que la H2 lo proponga si aparece en
  las subidas perdidas, y en el laboratorio como `filtro=adx_fuerte`.
- **La sobreextensión no hace falta** con estas reglas: queda en el
  catálogo, pero no hay nada que filtrar.
- **Lo siguiente de la lista** (doc de la pregunta, 2026-10-25): fuerza
  relativa frente al mercado y ancho de Bollinger. La fuerza relativa
  necesita la serie del índice (S&P 500, bitcoin) en el motor.
