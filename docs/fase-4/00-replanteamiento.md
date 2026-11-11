# Replanteamiento: de buscar señales a decidir la exposición (2026-11-11)

> **Vigencia**: vigente.
>
> **Qué pidió el dueño** (2026-11-10): replantear la idea de partida.
> Tras repasar tantas estrategias de las que se usan para operar, todos
> los resultados son negativos y solo Prudencia suma (8 $). La sospecha:
> que el error esté en el planteamiento base y el proyecto dé vueltas en
> un círculo que no le deja evolucionar.
>
> **Nada de esto toca a los agentes**: el grupo de control y las v2
> siguen como están hasta el final del experimento. Todo es laboratorio.

## 1. El diagnóstico

**La sospecha es correcta, y el proyecto ya tenía los datos.**

1. **Las reglas que operan tienen expectativa cero a 10 años**
   (`v_veredicto_agentes`, fijado el 5-11): Prudencia −0,04 R por
   operación, Cadencia −0,15 R, Audacia +0,06 R. Producción hace lo que
   predice el laboratorio: Prudencia −0,07 R en 21 cierres, Cadencia
   −0,39 R en 11, Audacia −0,06 R en 18 (datos desde el 11-10, a día
   10-11). Los 8 $ de Prudencia y el −28 % de Audacia son el mismo cero,
   con más o menos riesgo.
2. **Van 38 ideas probadas** (`criterio.REGISTRO`) y todas son de la misma
   familia: una señal sobre el precio, el volumen, el libro o un dato
   público, que dice **cuándo entrar** en un activo, con un stop, a plazo
   de horas o días, y medida en R por operación. Ninguna supera al azar
   de forma demostrada.
3. **Lo que sí se encontró no era una señal** (fase-2/06 §3.10): entrar
   en días al azar en el S&P 100 con un stop que sigue al precio da
   +0,28 R, lo mismo que la ruptura. En cripto, +0,65 R al azar. Lo que
   gana es **estar comprado** en un mercado que sube y **salir bien**, no
   acertar la entrada.
4. **Elegir qué comprar tampoco** (momento relativo, fase-2/06 §3.11): la
   configuración fijada no superó al azar en ningún universo.

**El círculo**: revisión del lunes → un filtro o una señal nueva → el
laboratorio dice que no → otra señal. El laboratorio funciona; lo que no
cambia es la pregunta.

## 2. La pregunta nueva

Si lo único que rinde es estar comprado, la pregunta deja de ser «¿cuándo
entro?» y pasa a ser:

> **Con una cartera que ya está comprada, ¿mejora decidir cuánta llevar?**

Cambia tres cosas a la vez:

| | Hasta ahora | Fase 4 |
|---|---|---|
| Qué se decide | Entrar o no en cada activo, cada 5 minutos | Cuánta exposición lleva la cartera, una vez al mes |
| Cómo se mide | R por operación | La cartera entera: rentabilidad anual, volatilidad y caída máxima |
| Contra qué | Metas diarias; el azar | **Comprar y mantener** la misma cartera |

**Lo que hay que saber antes de mirar ningún resultado**: comprar y
mantener rinde lo que rinde el mercado. A largo plazo es un dígito alto al
año en bolsa, con caídas del 30–50 % por el camino. Ninguna regla de esta
fase aspira a más rentabilidad que eso: aspiran a una rentabilidad
parecida **con menos caída**. Si el objetivo del proyecto es ganar más que
el mercado, esta fase no lo va a dar; nada de lo probado lo ha dado.

## 3. Las tres pruebas, fijadas antes de ejecutarlas

Las tres están en `criterio.REGISTRO` desde el commit que las fija. El
código es `laboratorio/asignacion.py`.

| Prueba | Cartera | Regla, una vez al mes |
|---|---|---|
| `tendencia_clases` | Cinco clases de activo a partes iguales: bolsa de EE. UU. (SPY), bolsa desarrollada sin EE. UU. (EFA), bonos del Tesoro a 7–10 años (IEF), inmobiliario (VNQ) y materias primas (DBC) | Cada clase lleva su 20 % si cerró el mes sobre su media de 10 meses; si no, ese 20 % queda en caja |
| `volatilidad_objetivo_clases` | La misma | La cartera entera se reduce cuando su volatilidad de las últimas 21 sesiones supera la mediana de lo visto hasta ese día: exposición = mín(1, mediana / reciente). Sin apalancamiento |
| `tendencia_bitcoin` | Solo bitcoin | Dentro si cerró el mes sobre su media de 10 meses; si no, en caja |

**Por qué estas y no otras**:

- Son las dos reglas de exposición con más respaldo fuera del proyecto: la
  media de 10 meses sobre clases de activo (Faber, 2007) y reducir cuando
  sube la volatilidad (Moreira y Muir, 2017).
- **La cartera se puede elegir con la información de 2006**: son las cinco
  clases del estudio de Faber, cada una con su ETF líquido más antiguo.
  Ninguna está por lo que hizo después. El histórico empieza en 2006 (el
  de DBC) y cubre 2008, 2020 y 2022.
- **Bitcoin** es la versión del agente que ya opera, Tendencia cripto,
  vista como cartera y contra mantener. Desde 2014.
- **No se repite el momento relativo** (elegir las más fuertes): ya se
  probó y no pasó.

**Ejecución** (la misma prudencia que el resto del laboratorio):

- La decisión usa solo cierres hasta el último día del mes anterior.
- Se ejecuta en la apertura de la primera sesión del mes.
- Cada cambio de peso paga medio spread (el de la 0034).
- La caja rinde un 0 %. Es pesimista: de 2023 a 2025 pagaba un 4–5 %.
- El primer 70 % del calendario es diseño; el resto, validación.

**La referencia al azar**: la misma serie de exposición de cada activo,
desplazada un número de meses al azar, 200 veces. Conserva cuánto tiempo
está dentro y cuántas veces cambia; solo rompe **cuándo**. Si la regla no
la supera, lo que hace es llevar menos cartera, y eso se consigue sin
regla.

**Criterio**. La regla mejora a comprar y mantener si cumple todo:

1. En validación, su Sharpe supera al **98 %** de los desplazamientos (el
   percentil que exige la cuenta global, con 38 ideas previas), y en el
   diseño, al menos al 50 %.
2. Su Sharpe es mayor que el de mantener en los dos tramos.
3. En validación, su caída máxima es menor que la de mantener.
4. En validación, su rentabilidad es positiva.
5. La mayoría de la rejilla (medias de 6, 8, 10 y 12 meses; ventanas de
   21, 42 y 63 sesiones) tiene mejor Sharpe que mantener en validación.

El Sharpe es la rentabilidad media entre la volatilidad, sin tipo libre de
riesgo.

## 4. Resultados

Pendientes: se ejecutan después del commit que fija lo anterior.
