# Fase 3 — E3: revisión del backlog de los agentes (2026-10-26)

> **Para qué sirve**: responde a las 5 peticiones abiertas de los agentes
> con metas. Durante el experimento sus reglas no cambian (son el grupo de
> control): una petición se responde con datos y, si el laboratorio
> valida algo, se guarda para el final, como «Audacia sin acciones de
> menos de 10 $» y «Cadencia solo con ADX ≥ 25».
> **Resultado**: 4 rechazadas y 1 implementada, en la migración 0051, con
> dos cambios en los disparadores para que no se reabran por lo mismo.

---

## 1. «El filtro «rr» me deja sin operar» (Prudencia, Cadencia y Audacia)

El 83–86 % de sus descartes de la semana fueron por R:R: la señal es
alcista, pero el objetivo (la resistencia) queda demasiado cerca del
stop.

**Prueba en el laboratorio**: cada agente con su estrategia real, 45
activos de producción, el criterio de las hipótesis (mejora ≥ +0,05 R,
intervalo del 90 % sobre cero, percentil ≥ 90 frente a 20 tiradas al
azar). Validación:

| Agente | R:R | 5 años | 10 años |
|---|---|---|---|
| Prudencia | **1,5 (hoy)** | −0,03 R, 116 ops | −0,02 R, 222 ops |
| | 1,3 | −0,02 R, 133 ops | −0,00 R, 263 ops |
| | 1,2 | +0,01 R, 147 ops | +0,01 R, 302 ops |
| | 1,0 | −0,03 R, 270 ops | −0,02 R, 681 ops |
| Cadencia | **1,3 (hoy)** | +0,01 R, 49 ops | +0,04 R, 93 ops |
| | 1,2 | −0,02 R, 54 ops | +0,05 R, 110 ops |
| | 1,1 | −0,02 R, 58 ops | +0,02 R, 121 ops |
| | 1,0 | +0,01 R, 108 ops | +0,05 R, 261 ops |
| Audacia | **1,2 (hoy)** | +0,22 R, 117 ops | +0,07 R, 231 ops |
| | 1,1 | +0,24 R, 127 ops | +0,09 R, 251 ops |
| | 1,0 | +0,14 R, 201 ops | +0,04 R, 466 ops |
| | 0,8 | +0,10 R, 255 ops | +0,06 R, 585 ops |

**Ninguna variante pasa.** Bajar el R:R multiplica las operaciones (hasta
×3), pero las que deja pasar valen unos 0 R: la expectativa se queda
donde estaba o baja. Lo más cercano es Audacia a 1,1 (+0,02 R, por debajo
del +0,05 exigido).

Más operaciones con la misma expectativa sí darían más R total si esa
expectativa fuera positiva, pero en ningún agente está demostrada (el
intervalo incluye el cero). Sería más exposición a algo sin ventaja.
Además, el R:R es lo que les hace comprar retrocesos (doc fase-3/05), y
es la pieza que más cambia qué compran.

**Respuesta**: rechazada, con el dato. No se reabre cada lunes mientras
dure el experimento (0051); la ocurrencia y la evidencia se siguen
anotando, y la fuente H3 de las hipótesis puede volver a proponerlo.

## 2. «Ampliar el universo de activos» (60 ocurrencias, los tres)

Se rechazó en la 0044 con un disparador más exigente (24 ciclos y 3
descartes del perfil por ciclo), y volvió a saltar casi todos los días
del 17 al 26-10. El motivo: entre el 85 y el 95 % de esos descartes del
perfil son por R:R. Por ejemplo, el lunes 26, Audacia: 1.056 de 1.156.

No faltan activos alcistas: los que hay no dan R:R. Es la petición
anterior contada dos veces. Ampliar el universo cripto sigue en espera
por el sesgo de supervivencia (doc 06), y en acciones nada indica que
más valores con el mismo perfil cambien la expectativa.

**Respuesta**: rechazada. **Cambio** (0051): no salta si un solo filtro
explica el 80 % de los descartes del perfil, porque entonces ya lo pide
«El filtro X me deja sin operar». Invariante I101.

## 3. «Señales más frecuentes» (37 ocurrencias, nunca revisada)

Descartes por señal de más de 90 minutos con el mercado abierto:

| Periodo | Descartes por día (cada agente) | Causa |
|---|---|---|
| 29-09 a 08-10 | de 500 a 1.100 | El ETL solo refrescaba los activos que alguien seguía |
| 09-10 | 60–70 | Se aplica la 0029: refresca todo el catálogo |
| 10-10 a 22-10 | 0 (5 el 21-10) | — |
| 23 y 24-10 | 650 y 1.570 | Token de GitHub caducado: el ETL no se lanzaba |
| 25 y 26-10 | 0 | Token renovado |

**Respuesta**: implementada (0029). El disparador se queda como está:
ahora es un buen detector de caídas del ETL, y la 0045 y la 0050 vigilan
la causa del único episodio posterior.

## 4. Para la próxima revisión

- Las 3 hipótesis del lunes 26 (MACD positivo) quedaron refutadas; las
  del lunes 2-11 las generará la H1–H4 con una semana más de descartes
  (la H3 necesita una semana anterior con la que comparar).
- La concordancia del laboratorio con Cadencia (12 %) y Audacia (23 %) es
  baja: mientras lo sea, sus veredictos describen más al laboratorio que
  al agente. Es la tarea siguiente de la lista.
