# Fase 3 — Modo de 1 hora: rebote en cripto y ruptura de la primera hora

> **Para qué sirve**: responde a la idea del dueño del 2026-11-03:
> «pocas posiciones, en momentos concretos, que den una ganancia rápida».
> El laboratorio solo veía velas diarias; aquí se le añade un modo de 1
> hora y se prueba la primera de esas ideas.
> **Método**: velas de 1 hora de Yahoo de las 14 criptos del universo, del
> **2024-11-04 al 2026-11-03** (lo máximo que da Yahoo: 730 días). Diseño
> hasta el 2026-03-29; validación desde ahí. Spread de la 0034. No usa
> datos de producción ni toca a los agentes.
> **Fecha**: 2026-11-03.

---

## 1. El modo de 1 hora

`laboratorio/intradia.py`. El motor es el de siempre: trabaja por velas,
así que con velas horarias cada fila es una hora y las reglas de ejecución
no cambian (señal al cierre de la hora, entrada en la apertura de la
siguiente con medio spread, el stop gana el empate, salida en hueco).

- `datos.cargar(…, intervalo="1h")`: velas horarias en UTC.
- `metricas.medir(…, barras_mes=…)`: cuántas velas son un mes. El informe
  no da el «por mes en cartera»: con operaciones de pocas horas,
  encadenarlas como si se estuviera siempre dentro da cifras irreales (la
  primera pasada decía +15 % al mes con una expectativa de −0,005 R).
- Las estrategias de 1 hora tienen su propio registro: el laboratorio
  diario no las corre.
- En GitHub Actions: `laboratorio.yml`, modo `intradia`.

Cómo se juzga una estrategia (fijado antes de mirar los datos):

1. Una rejilla pequeña sobre el tramo de **diseño** (70 %). Se elige la
   combinación de mejor expectativa con al menos 30 operaciones.
2. Esa, y solo esa, se juzga en **validación** con el criterio del
   laboratorio (≥ 30 operaciones, > +0,10 R, IC 90 % sin el cero, factor
   de beneficio > 1,2).
3. **Frente al azar**: las mismas salidas entrando a horas al azar con la
   misma frecuencia, en 20 tiradas. Tiene que superar al 90 %.

## 2. La hipótesis: rebote tras una caída brusca

`rebote_caida`. Al cierre de una hora, si el precio está a *k* ATR de
1 hora (ATR de 48 horas) por debajo del máximo de las últimas 6 horas, se
compra en la apertura siguiente. Stop y objetivo a 2 ATR; si no toca
ninguno, se sale a las *H* horas. La rejilla: *k* = 4, 6 u 8 y *H* = 6,
12 o 24.

La pregunta viene del freno por choque (doc fase-3/09 §6): los agentes
compraban el mismo retroceso días después; quizá la ganancia estaba en
las primeras horas.

## 3. Resultado: no hay ventaja

| | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto |
|---|---|---|---|---|---|
| Diseño, mejor combinación (*k* = 8, *H* = 6) | 303 | +0,019 R | −0,067 – +0,104 | 53 % | 12 % |
| **Validación** | 49 | **−0,005 R** | −0,210 – +0,188 | 55 % | 25 % |
| Azar con las mismas salidas (validación, mediana de 20) | 107 | −0,081 R | p5–p95: −0,191 – +0,070 | | |

- La elegida supera al azar en el 80 % de las tiradas (mínimo, 90 %).
- Las caídas más pequeñas (4 y 6 ATR) pierden en diseño en las seis
  combinaciones (−0,09 a −0,13 R). En validación, toda la rejilla está
  entre −0,04 y +0,02 R: **nada se acerca al +0,10 R**.
- Cuanto más extrema la caída, algo mejor (8 ATR es la única que no
  pierde en diseño), pero son pocas operaciones y el intervalo es muy
  ancho.

## 4. Lo que enseña para las ideas rápidas

- **El spread pesa el doble.** Entrar y salir en pocas horas con stops de
  2 ATR horarios cuesta, de media, **unos −0,08 R por operación** (es lo
  que pierde el azar, que no tiene ventaja ni desventaja). En diario, las
  reversiones pagaban un 7–12 % del bruto; aquí, el 12–25 %. Para ganar
  hay que superar ese listón antes de tener ventaja.
- **Un desplome en cripto no rebota de forma fiable en las horas
  siguientes**, igual que no rebotaba en los días siguientes.

## 5. Qué queda

Las otras ideas propuestas el 2026-11-03, todas con el mismo modo y el
mismo criterio:

1. ~~Ruptura del rango de la primera hora en acciones~~: probada en el §6,
   sin ventaja.
2. ~~El hueco del día de resultados~~: probado en el §7, sin ventaja.
3. **Horas de más movimiento en cripto** frente al resto del día.

Cada prueba nueva sube el percentil exigido: probar mucho no regala
validaciones. Y aunque alguna validara, en producción las señales llegan
con hasta 90 minutos de retraso, así que operar por horas necesitaría un
ETL más frecuente.

---

## 6. Segunda prueba: ruptura de la primera hora en acciones (2026-11-03)

> **Método**: velas de 1 hora de Yahoo de las 21 acciones del universo
> (la semilla de la 0003), del **2023-12-06 al 2026-11-03** (en acciones,
> Yahoo da casi 3 años). Diseño hasta el 2025-12-19; validación desde ahí.
> Spread de 0,03 $. Segunda prueba del modo: el percentil exigido sube a 91.

`ruptura_primera_hora`. La primera vela de la sesión (9:30–10:30) marca un
máximo y un mínimo. El **primer** cierre de una hora por encima de ese
máximo, entre las 10:30 y las 13:30, compra en la apertura siguiente.
Nunca pasa la noche: sale en la apertura de la última vela (15:30). Una
entrada al día como mucho, y solo en sesiones completas. La rejilla: stop
en el mínimo de la primera hora o en la mitad del rango; objetivo a 1R o
2R, o ninguno.

La referencia al azar entra a una hora al azar del mismo tramo, con un
stop **del mismo tamaño** (el rango o su mitad), el mismo objetivo y la
misma salida: lo único que quita es la condición de romper el máximo.

| | Ops | Neto | Coste (spread) | Antes de costes |
|---|---|---|---|---|
| Diseño, mejor combinación (stop en el mínimo, sin objetivo) | 3.401 | −0,057 R | 0,061 R | +0,003 R |
| **Validación** | 1.317 | **−0,023 R** | 0,050 R | +0,027 R |
| Azar con las mismas salidas (validación) | 1.316 | −0,063 R (mediana) | 0,064 R | −0,008 R |

- **Pierde dinero en las seis combinaciones**, en diseño y en validación.
  El IC 90 % de la elegida en validación es −0,043 – −0,005 R.
- **Supera al azar en el 100 % de las tiradas**, pero es menos mala que el
  azar, no una ventaja: el +0,03 R que añade la ruptura no paga el
  spread.
- El spread se lleva el 29–37 % del bruto (en diario, las reversiones
  pagaban el 7–12 %): 0,03 $ por operación pesa mucho frente a un stop
  del tamaño del rango de una hora.
- Por acción, en validación: de +0,09 R (WFC) a −0,16 R (AGNC), 14 de
  21 negativas. Elegir las buenas sería mirar el resultado.

**Conclusión de las dos pruebas**: con los costes de QuantFury, las ideas
de pocas horas parten con unos −0,05 a −0,08 R por operación en contra.
Las dos que se han probado añaden algo frente al azar (la ruptura, más),
pero no lo suficiente. Lo que queda (§5) tendría que mover bastante más que
eso, como el hueco del día de resultados, que suele ser de varios ATR.

---

## 7. Tercera prueba: el hueco del día de resultados (2026-11-04)

> **Método**: velas de 1 hora de Yahoo de las **101 acciones del S&P 100**
> con fechas de resultados en Yahoo, del **2023-12-07 al 2026-11-04**.
> Diseño hasta el 2025-12-20; validación desde ahí. Con las 21 acciones del
> universo activo habría unos 250 días de resultados en tres años, pocos
> para validar. Spread de 0,03 $. Tercera prueba del modo: el percentil
> exigido sube a 92.

`hueco_resultados`. Solo se opera en la sesión que reacciona a unos
resultados (`datos.cargar_resultados`). Si abre con un hueco de al menos
`hueco_atr` ATR diarios sobre el cierre anterior y la primera hora cierra a
favor del hueco, se entra en la apertura de las 10:30 **en la dirección del
hueco** (en corto si baja). El stop va en el otro extremo de la primera
hora y no hay objetivo. La rejilla:
- hueco de 0,5, 1 o 2 ATR;
- salida a las 15:30 del mismo día, o de la quinta sesión, para dejar
  correr la deriva tras los resultados.

La referencia al azar entra un día cualquiera a las 10:30, en la dirección
de la primera hora, con el mismo stop y la misma salida: mide si el día de
resultados aporta algo sobre seguir a la primera hora un día normal.

| | Ops | Neto | IC 90 % |
|---|---|---|---|
| Diseño, mejor combinación (hueco de 2 ATR, 5 sesiones) | 163 | +0,125 R | −0,074 – +0,337 |
| **Validación** | 57 | **+0,106 R** | −0,234 – +0,486 |
| Azar con las mismas salidas (validación) | 85 | −0,150 R (mediana) | p5 – p95: −0,506 – +0,306 |

- **No valida**: el IC 90 % incluye el cero y supera al azar en el 90 %
  de las tiradas, por debajo del 92 % exigido. Con 57 operaciones en
  validación, el resultado es demasiado ruidoso para afirmar nada.
- **Dentro del día pierde siempre**: las tres versiones de salida a las
  15:30 dan de −0,03 a −0,07 R en validación. Lo positivo es dejarla
  correr cinco sesiones, y solo en diseño se ve con claridad: en
  validación, con huecos de 0,5 ATR ya pierde (−0,09 R).
- **El spread deja de ser el problema**: se lleva el 3–6 % del bruto,
  porque un stop del tamaño de la primera hora de un día de resultados es
  ancho. Lo que falla aquí es la señal, no el coste.

**Lo que sugiere**: la idea con algo de vida no es rápida. Es la deriva
de varios días tras unos resultados con hueco, que se mide mejor con velas
diarias: con 10 años de historia habría unas tres veces más días de
resultados que aquí. No se ha probado; queda como idea para el laboratorio
diario.
