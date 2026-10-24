# Fase 3 — Cortos en el laboratorio

> **Para qué sirve**: deja el resultado de probar las operaciones en
> corto antes de tocar el simulador y la regla protegida nº2 (decisión del
> dueño, 2026-10-24: «primero en el laboratorio, con coste de financiación
> y contra el azar»). También responde a una pregunta del mismo día:
> ¿no sería una estrategia operar al revés que Audacia?
> **Conclusión**: **no hay ventaja en corto**, ni con las señales de
> tendencia, ni con la confluencia de los agentes, ni haciendo lo contrario
> que Audacia. La regla protegida nº2 se mantiene y el simulador no cambia.

---

## 1. Qué se añadió al laboratorio

- **El motor opera en corto**, con la misma disciplina al revés:
  - se vende al precio de venta y se recompra al de compra;
  - el stop está por encima y el objetivo por debajo, y el stop gana el empate;
  - el hueco es abrir por encima del stop;
  - el stop solo baja.
- **La financiación del corto**: cada día natural abierto cuesta un % anual
  sobre el nominal, que se suma al precio de recompra. **Es un supuesto
  pesimista, no la tarifa de QuantFury**, que no tenemos:
  - acciones, 8 % anual (tipo de interés más el margen del broker y el
    préstamo del título);
  - cripto, 15 % anual (lo que suelen pagar los cortos en los perpetuos
    cuando el mercado cae).

  Está en `laboratorio/datos.py` (`FINANCIACION_CORTO_PCT`).
- **Cuatro estrategias**, todas espejo de algo ya probado en largo:

| Estrategia | Qué hace | Espejo de |
|---|---|---|
| `tendencia_corta` | Rotura del mínimo de 20 días con el cierre bajo la media de 200; stop a 2 ATR por encima que baja siguiendo al mejor cierre a 3 ATR; salida si cierra sobre el máximo de 10 | `tendencia`, la que tiene ventaja en cripto en largo |
| `azar_corto` | Las mismas salidas y el mismo filtro de fondo, entrando en corto en días al azar | `azar` (doc 06 §3.10) |
| `confluencia_corta` | Confluencia bajista media o alta, con los niveles de la D21 sobre el precio reflejado | `actual`: lo que harían los agentes si pudieran vender en corto |
| `agente_contrario` | Vende en corto cuando el agente compraría, con el stop en su objetivo y el objetivo en su stop | Audacia (§3) |

- `contra_azar` admite `--clase` (antes solo medía acciones) y avisa
  cuando una estrategia supera al azar **perdiendo dinero**: ser menos mala
  que el azar no es una ventaja.

## 2. Resultados

Universo activo de producción (31 acciones y 14 criptos), en el tramo de
validación (el 30 % final), con el spread de la 0034, los huecos y la
financiación.

| Estrategia | 5 años: validación | 10 años: validación | Veredicto |
|---|---|---|---|
| `tendencia` (largo, referencia) | +0,38 R, IC [+0,11, +0,68] | +0,40 R, IC [+0,21, +0,61] | ✅ |
| `tendencia_corta` | +0,04 R, IC [−0,12, +0,20] | **−0,26 R**, IC [−0,35, −0,17] | ❌ |
| `azar_corto` | −0,01 R | −0,16 R | ❌ |
| `confluencia_corta` | **−0,38 R**, IC [−0,57, −0,19] | **−0,29 R** | ❌ |

Informes: [5 años](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/40121770405),
[10 años](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/40122017993).

**Frente a 30 tiradas al azar** (`tendencia_corta`, 5 años, % al mes en cartera):

| Clase | Diseño | Validación | Supera al azar en validación | Informe |
|---|---|---|---|---|
| Cripto | −5,40 % (azar −4,21 %) | −0,54 % (azar −1,08 %) | 77 % ❌ | [enlace](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/40122149852) |
| Acciones | −2,75 % (azar −2,25 %) | −0,67 % (azar −1,51 %) | 90 %, **pero pierde dinero** | [enlace](https://github.com/rgda-ship-it/dashboard-financiero/actions/runs/40121779046) |

**¿Es la financiación lo que la mata?** En parte sí, pero no es lo
decisivo. Sin financiación, `tendencia_corta` llega a +0,22 R en la
validación de 5 años, pero en el diseño, que incluye el mercado bajista
de 2022, pierde 0,19 R. A 10 años pierde en los dos tramos. No hay una
señal estable que el coste estropee: la señal no aguanta por sí sola.

**Lectura**: el diseño de 5 años contiene todo 2022, el año en que un
corto debería brillar, y aun así `tendencia_corta` pierde ahí más que
entrar en corto al azar en cripto. Un mercado que sube a largo plazo
castiga al corto con stop ajustado: los rebotes de los mercados bajistas
saltan los stops.

## 3. ¿Y si Audacia hubiera operado al revés?

La pregunta del dueño era: con sus pérdidas, operar al contrario que el
escáner habría ganado casi 90 $, más que Prudencia. El número sin costes
es exacto: Audacia pierde 84,78 $ en 55 operaciones, así que al revés y
sin costes se ganarían 84,78 $. Pero el corto pagaría su propio spread y
la financiación:

| Agente | Resultado real | Spread que pagó | Lo que movió el precio | Al revés, con spread y financiación |
|---|---|---|---|---|
| Audacia | −84,78 $ (25 % de aciertos) | 16,02 $ (9 de 55 operaciones) | −68,76 $ | **+6,85 $** |
| Cadencia | −10,17 $ | 2,73 $ (4 de 61) | −7,44 $ | −37,96 $ |
| Prudencia | +21,78 $ | 8,05 $ (10 de 20) | +29,83 $ | −42,06 $ |

El spread solo se cobra desde la 0034 (11-10): las operaciones anteriores
no lo pagaron. Al revés, en cambio, se le aplica a todas con la regla de
hoy (0,03 $ por acción, 0,1 % en cripto, y lo observado cuando la orden lo
tiene), más la financiación del §1. Audacia al revés ganaría unos 7 $ en
55 operaciones, 0,12 $ por operación: nada que distinguir del ruido.

**Corrección (2026-10-24)**: una primera versión de esta tabla aplicaba el
spread a las 55 operaciones como si todas lo hubieran pagado, y concluía
que más de la mitad de las pérdidas de Audacia eran spread. No es así:
pagó 16,02 $, una quinta parte. Con la regla de hoy aplicada a todo su
historial, el spread sí habría sido de unos 56 $.

**En el laboratorio** (`agente_contrario` con los parámetros de Audacia,
universo de respaldo de 35 activos):

| | 5 años: validación | 10 años: validación |
|---|---|---|
| Audacia (`agente`) | +0,17 R, 42 % de aciertos | −0,04 R, 37 % de aciertos |
| Lo contrario | **−0,13 R, 58 % de aciertos** | **−0,02 R, 63 % de aciertos** |

Lo contrario acierta más, entre el 52 y el 68 % según la clase, pero
pierde. Su objetivo está donde Audacia tenía el stop (cerca) y su stop
donde Audacia tenía el objetivo (lejos): gana poco muchas veces y pierde
mucho pocas. **Un porcentaje alto de aciertos no es ganar**: lo que cuenta
es la expectativa en R, que reúne aciertos y tamaño de las ganancias y las
pérdidas.

**Sobre el «90 %»** de los informes: no es un porcentaje de aciertos. Es
el **percentil frente al azar**: la estrategia rinde más que 90 de cada
100 tiradas al azar con las mismas reglas de salida. Es el criterio para
decir que la señal aporta algo que no aporta entrar en cualquier día.

## 4. Qué se decide

- **La regla protegida nº2 se mantiene**: no se abren cortos en el
  simulador ni en los agentes.
- **No se crea un agente contrario.**
- **Lo que reabriría la pregunta**: una estrategia bajista que pase el
  laboratorio y el azar en los dos tramos y en las dos clases. Por
  ejemplo, una que solo opere con el mercado en régimen bajista (ADX y
  media de 200 a la baja en el índice), que aún no se ha probado. Las
  herramientas ya están: `lado="corto"` en el motor y `--clase` en
  `contra_azar`.
- **No se tocan los agentes**: son el grupo de control (§5).

## 5. Excluir acciones baratas o exigir un objetivo frente al spread

Pregunta del dueño (2026-10-24): ¿mejoraría cada agente sin las acciones
de menos de 10 $, o exigiendo que el objetivo valga al menos N veces el
spread? Se probó con la estrategia `agente` y los parámetros reales de
cada uno (`precio_min` y `objetivo_min_spread`, nuevos), 45 activos del
universo de producción, 5 años, y el criterio de las hipótesis: mejora de
+0,05 R, intervalo por encima de cero y percentil ≥ 90 frente a 20
tiradas al azar.

| Agente | Sin acciones < 10 $ (solo acciones) | Objetivo ≥ 10 spreads | Objetivo ≥ 20 spreads |
|---|---|---|---|
| Prudencia | ❌ +0,07 → +0,05 R (p75) | ❌ sin efecto | ❌ −0,04 → −0,05 R |
| Cadencia | ❌ +0,03 → +0,00 R (p60) | ❌ sin efecto | ❌ +0,01 → −0,05 R |
| **Audacia** | ✅ **+0,30 → +0,39 R** (68 operaciones, IC [+0,11, +0,70], p100) | ❌ +0,21 R, IC con el cero | ❌ +0,21 → +0,19 R |

- **El objetivo frente al spread casi no actúa**: con niveles de 2 a 5 ATR,
  el objetivo ya vale muchas veces el spread. Descartado.
- **El precio mínimo solo ayuda a Audacia**, que es la que opera más
  acciones baratas por su suelo de volatilidad (ATR ≥ 2,3 %). En
  producción apunta en la misma dirección, con muy pocos datos: desde la
  0034, sus 3 operaciones de menos de 10 $ dejaron −42,60 $, y sus 6 de
  10 $ o más, +4,82 $.
- **Ojo con las pruebas múltiples: se probaron 9 variantes y pasa una**. El intervalo de esa
  una queda lejos del cero, y supera a todas las tiradas al azar, pero
  sigue siendo una de nueve.
- **No se aplica a Audacia**: es parte del grupo de control (ESTADO §1).
  Queda como cambio validado para cuando acabe el experimento o, si el
  dueño lo prefiere, como base de un agente experimental nuevo.
