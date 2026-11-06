# Compras de directivos (Form 4) en el laboratorio (2026-11-06)

> **Pregunta**: la tercera prueba del doc fase-3/13 §5.3. Cuando los
> directivos de una empresa compran sus propias acciones con su dinero,
> ¿la acción sube más que un día cualquiera?
>
> **Datos**: los «Insider Transactions Data Sets» trimestrales de la SEC
> (2014 T1 – 2026 T4), descargados el 2026-11-06 con `SEC_USER_AGENT`
> (`laboratorio/form4.py`). Velas diarias ajustadas de Yahoo del S&P 100,
> del 2016-11-07 al 2026-11-06 (101 acciones; BK sin datos). No toca
> producción ni los agentes.

## 1. Qué se fijó antes de ejecutarla

Fijado y registrado en el commit `a16906e`, antes de la primera descarga:

- **Qué cuenta**: compras en el mercado abierto (Form 4, código `P`,
  adquisición) de 10.000 $ o más por presentación. Quedan fuera las
  opciones, los planes, los regalos y las ventas.
- **Cuándo se sabe**: por la fecha de **presentación**. Solo cuenta lo
  presentado hasta el día anterior, porque un Form 4 de la tarde no se
  conoce al cierre.
- **Entrada**: al cierre del día en que el número de directivos distintos
  comprando en los 30 días anteriores llega a 1 o a 2 (`minimo`). Compra en
  la apertura siguiente (`CompraDirectivos`).
- **Salida**: stop a 3 ATR, sin objetivo; sale a las 20 o 60 sesiones.
- **El azar** (`AzarDirectivos`): un día cualquiera de las mismas
  acciones, con las mismas salidas. 100 tiradas. Al ser las mismas
  acciones, el sesgo de supervivencia del S&P 100 pesa igual en las dos.
- Una entrada en `criterio.REGISTRO`: pide el percentil 98.

## 2. Resultado

| | Diseño (2016–2023) | Validación (2023–2026) |
|---|---|---|
| Elegida: 2 directivos, 60 sesiones | **+0,682 R** (101 ops) | **+0,302 R** (32 ops), IC 90 % −0,103 – +0,704 |
| Azar, mismas acciones (mediana) | +0,320 R | +0,323 R (46 ops) |
| Percentil frente al azar | **99** (mínimo 50) ✅ | **46** (mínimo 98) |

Ventanas móviles: +0,443 R encadenado, 3 de 4 bloques positivos; el
último, −0,150 R con 19 operaciones.

**Veredicto: ❌ sin ventaja.** En el diseño parecía muy buena: el doble que
el azar y por encima de 99 de cada 100 tiradas. En la validación cae a lo
mismo que comprar cualquier día de esas acciones. Además, el intervalo
incluye el cero.

Lo que hay que leer con cuidado:
- **Pocas señales**. En el S&P 100 los directivos casi nunca compran:
  unas 2.100 compras por trimestre en todo EE. UU., y muy pocas en las
  grandes. Con dos directivos hay 32 operaciones en tres años, muy poco
  para separar +0,30 R de +0,68 R.
- **El azar ya gana +0,32 R**. Mantener 60 sesiones una acción que hoy
  sigue en el S&P 100 sale bien por sí solo (supervivencia y mercado
  alcista). La señal de los directivos tiene que ganar a eso, y en la
  validación no lo hace.
- La literatura (compras de directivos en empresas pequeñas, sobre todo)
  no se ve aquí, en las grandes. Podría verse en acciones medianas o
  pequeñas, pero eso sería otra idea y otra entrada en el registro, y no
  son las que operan los agentes.

## 3. Qué queda

- `laboratorio/form4.py` (lee los data sets trimestrales y cuenta los
  compradores distintos sin mirar el futuro), `CompraDirectivos` y
  `AzarDirectivos` quedan en el laboratorio, con sus tests. Se ejecuta con
  `SEC_USER_AGENT=... python -m laboratorio.intradia --estrategia
  compras_directivos`.
- Van 38 ideas registradas; la siguiente sigue pidiendo el percentil 98.
- Del doc fase-3/13 §5 solo queda la cuarta prueba, las noticias de Alpaca
  con FinBERT. Necesita que crees una cuenta gratuita en Alpaca y guardes
  la clave como secreto. Sin eso no se puede empezar.
