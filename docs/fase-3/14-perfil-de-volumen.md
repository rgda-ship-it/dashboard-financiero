# Perfil de volumen en el laboratorio (2026-11-06)

> **Pregunta**: la primera prueba que propone el doc fase-3/13 §5.1. ¿El
> nivel de precio donde más se ha negociado hace de soporte, y comprar
> cuando el precio vuelve a él da ventaja?
>
> **Datos**: velas diarias ajustadas de Yahoo, descargadas el 2026-11-06.
> Los 19 ETF del universo `etf`, del 1996-03-18 al 2026-11-06, sin sesgo
> de supervivencia. Las 14 criptos del universo activo, del 2014-09-17 al
> 2026-11-06. No toca producción ni los agentes.

## 1. Qué se fijó antes de ejecutarla

Fijado y registrado en el commit `e102c45`, antes de la primera ejecución:

- **El nivel (POC)**: el precio con más volumen de las `dias` sesiones
  anteriores. El rango de esas sesiones se parte en 40 tramos de precio, y
  el volumen de cada sesión se reparte entre los tramos que cubre
  (`intradia.nivel_de_mas_volumen`). No usa la vela del día.
- **Entrada**: al cierre del primer día en que el mínimo toca el POC y el
  cierre queda por encima, viniendo de arriba (el día anterior tuvo el
  mínimo y el cierre por encima). Compra en la apertura siguiente
  (`PerfilVolumen`).
- **Salida**: stop a 2 ATR del cierre, sin objetivo; sale a las `sesiones`
  sesiones.
- **Rejilla**: `dias` 20 o 60 y `sesiones` 5 o 20, cuatro combinaciones,
  elegidas en el diseño (el 70 % inicial).
- **El azar** (`AzarPerfil`): comprar un día cualquiera que cierre por
  encima del POC, con las mismas salidas y la misma frecuencia. Así mide
  si el **toque** aporta algo sobre estar por encima del nivel. 100
  tiradas.
- **Dos pruebas en `criterio.REGISTRO`** (`perfil_volumen` y
  `perfil_volumen_cripto`): la misma regla en dos clases cuenta doble,
  porque bastaría con que pasara una. Las dos piden superar al 98 % del
  azar.

## 2. Resultado

| | ETF (1996–2026) | Cripto (2014–2026) |
|---|---|---|
| Elegida en el diseño | 60 días, 20 sesiones | 20 días, 20 sesiones |
| Diseño | +0,011 R (982 ops) | +0,465 R (248 ops) |
| **Validación** | **−0,051 R** (428 ops), IC 90 % −0,153 – +0,056 | **+0,099 R** (192 ops), IC 90 % −0,097 – +0,312 |
| Azar en validación (mediana) | +0,086 R | +0,329 R |
| Percentil frente al azar, validación | **0** (mínimo 98) | **3** (mínimo 98) |
| Percentil frente al azar, diseño | 13 (mínimo 50) | 10 (mínimo 50) |
| Ventanas móviles | −0,050 R, 0 de 4 bloques positivos | +0,185 R, 2 de 3 |
| **Veredicto** | ❌ sin ventaja | ❌ sin ventaja |

**Las dos fallan todos los filtros frente al azar.** En cripto la
expectativa es positiva, pero comprar cualquier día por encima del nivel
da el triple: lo que gana es la tendencia alcista de cripto en el
periodo (y el sesgo de supervivencia del universo: las 14 son las que hoy
siguen arriba), no el toque. En los ETF, el toque es peor que el azar en
los 4 bloques de las ventanas móviles.

Lo que se ve en los datos: **el toque del nivel es un retroceso, y en
ambas clases el retroceso hasta el POC sale peor que una entrada
cualquiera en la misma situación**. El nivel no frena la caída lo
bastante como para compensar.

## 3. Qué queda

- El código (`nivel_de_mas_volumen`, `PerfilVolumen`, `AzarPerfil`) queda
  en el laboratorio, con sus tests, y se puede volver a ejecutar con
  `python -m laboratorio.intradia --estrategia perfil_volumen` (o
  `perfil_volumen_cripto`), o en el modo `intradia` de `laboratorio.yml`.
- Van 34 ideas registradas; la siguiente sigue pidiendo el percentil 98.
- Siguiente del doc fase-3/13 §5: el desequilibrio del libro y el flujo de
  órdenes en cripto, con los ficheros de Binance (`bookDepth` desde el
  2023-01-01). Es otra idea y otra entrada en el registro.
- Nada de esto cambia a los agentes ni al grupo de control.
