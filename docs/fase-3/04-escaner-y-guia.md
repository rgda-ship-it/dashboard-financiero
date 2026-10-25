# Fase 3 — El escáner dice qué hacer, y la guía, rehecha

> **Para qué sirve**: deja escrito qué cambió en el escáner y en la guía
> de lectura (petición del dueño, 2026-10-25). El escáner se había quedado
> en la Fase 1: enseñaba la lectura técnica pero no la decisión, y no
> reflejaba lo que cambió después (D21, spread, filtros de los agentes,
> solo largos).

---

## 1. El escáner

**Antes**: activo, confluencia, volatilidad, apalancamiento y un riel con
el soporte y la resistencia rotulados «SL» y «TP», aunque desde la D21 ya
no son el stop ni el objetivo.

**Ahora**, por columnas:

| Columna | Qué enseña |
|---|---|
| Activo | Igual. La fila lleva a la izquierda una marca del color del veredicto |
| **Qué hacer** | **Comprar**, **Esperar**, **No comprar** o **Sin datos**, con el motivo en una frase. Debajo, los agentes: en color los que la tomarían con sus filtros reales y tachados los que no |
| Confluencia | Igual |
| **Niveles** | Comprar hasta (precio con medio spread), stop y objetivo con el % que se pierde o se gana, y el R:R tras el spread |
| Volatilidad | Igual |
| Detalle | Indicadores, soporte y resistencia (ya sin rol), por qué estos niveles, por qué no la tomaría cada agente y el apalancamiento para el simulador |

Arriba, un resumen: cuántos para comprar, en espera y no comprar, y si la
bolsa de Nueva York está cerrada. El filtro «Solo alta» pasa a ser «Solo
para comprar», y la tabla se ordena por defecto con lo accionable primero.

**Las reglas del veredicto** (`frontend/src/datos/veredicto.js`, con sus
pruebas). No añaden ningún criterio: aplican los que ya usan el simulador
y los agentes, en este orden, y el motivo dice el primero que falla:

1. Sin datos fiables (error, suspendido) o sin volatilidad conocida → no se opera (regla protegida nº4).
2. Lectura bajista o sin dirección → no comprar (regla nº2; los cortos no tienen ventaja, doc 02).
3. Confluencia baja → esperar.
4. Con el spread medido (`v_spreads`, o el supuesto de la 0034), el R:R por debajo de 1,2 (el mínimo más permisivo de los agentes) → esperar. Si el spread se come el objetivo entero → no comprar.
5. Dato atrasado, o acción con la bolsa cerrada → esperar.
6. Si no → comprar.

Los filtros de cada agente se leen de `agentes.estrategia`, con los mismos
valores por defecto que `fn_parametros_agente`: clase, fuerza, origen de
los niveles, R:R mínimo y banda de ATR por clase. Tendencia cripto no
aparece: decide una vez al día con la vela cerrada y con otra regla
(ruptura y media de 200), que el escáner no calcula.

**Con los datos del sábado 25-10**: 0 para comprar, 10 en espera y 37 no
comprar. Las 15 criptos eran bajistas, la bolsa estaba cerrada, y varias
acciones alcistas tenían un R:R de 0,2 a 0,5 porque su resistencia está
muy cerca.

## 2. La guía

- **Sección nueva, «Cómo usarla»**: el recorrido de una decisión en cuatro
  pasos (el escáner dice qué hacer, los niveles dicen cuánto se arriesga,
  el simulador decide el tamaño, y los agentes y el laboratorio aprenden).
- **Escáner, rehecho** columna por columna, con las reglas del veredicto y
  la fórmula de los niveles con el spread. «Sesgo operativo» pasa a «Solo
  en largo», con el resultado de los cortos.
- **Sección nueva, «Cómo leer el laboratorio»**: qué es R, por qué un
  porcentaje alto de aciertos puede perder dinero, diseño y validación,
  el intervalo del 90 %, el percentil frente al azar (que no es un
  porcentaje de aciertos) y qué se ha descartado ya.
- **Correcciones**:
  - Prudencia ya no «solo opera acciones»: desde la D22 los tres operan
    acciones y cripto.
  - El trailing stop: el laboratorio sí lo prueba; el simulador no lo
    tiene.

Las fórmulas que comprueban las pruebas de coherencia
(`motor-analitico/tests/test_coherencia_guia.py`) se mantienen literales.
