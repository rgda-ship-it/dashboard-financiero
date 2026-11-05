"""
Criterio común del laboratorio frente al azar (doc fase-3/12, 2026-11-05).

Tres reglas fijadas ANTES de las pruebas siguientes:

1. **Cuenta global de pruebas** (`REGISTRO`). Cada idea probada, en
   cualquier modo (diario, contra el azar, por velas, hipótesis a mano),
   cuenta. El percentil exigido frente al azar sale de cuántas se probaron
   antes: `100 − 10 / √(1 + previas)`, redondeado hacia abajo y con techo
   de 99. Con 0 previas es 90 (lo de siempre); con 32, 98. Nunca llega a
   ser imposible, pero cada idea nueva cuesta más que la anterior.
   Una prueba nueva se añade aquí, en el commit que la fija, antes de
   ejecutarla: sin registro, `percentil_exigido` falla.
2. **El diseño también contra el azar**: la elegida tiene que superar en
   el diseño, como mínimo, a la mitad de las tiradas al azar
   (`PERCENTIL_DISENO_MIN`). Comprar caídas en los ETF pasó la validación
   estando en el percentil 4 en el diseño: eso es una ventaja que cambia de
   signo según la época, no una ventaja.
3. **Ventanas móviles** (*walk-forward*): el calendario se parte en
   `VENTANAS` bloques; para cada bloque desde el segundo se elige la mejor
   combinación de la rejilla con lo anterior (al menos 30 operaciones) y se
   mide en ese bloque. Lo medido fuera de muestra, encadenado, tiene que
   dar expectativa positiva, y la mitad de los bloques también.

Las pruebas que ya se hicieron conservan su veredicto, con el criterio
que tenían; si se repiten, se juzgan con este.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# (nombre, fecha, documento). Una entrada por IDEA, no por variante: las 72
# combinaciones de calidad y valor son una idea; las cuatro horas de
# `hora_cripto`, también. Reconstruido de los docs el 2026-11-05.
REGISTRO: list[tuple[str, str, str]] = [
    ("actual", "2026-10-10", "fase-2/06 §3.7"),
    ("tendencia", "2026-10-10", "fase-2/06 §3.7"),
    ("reversion", "2026-10-10", "fase-2/06 §3.7"),
    ("ruptura_volumen", "2026-10-11", "fase-2/06 §3.8"),
    ("ruptura_2r", "2026-10-11", "fase-2/06 §3.8"),
    ("retroceso", "2026-10-11", "fase-2/06 §3.8"),
    ("reversion_bollinger", "2026-10-11", "fase-2/06 §3.8"),
    ("momento", "2026-10-13", "fase-2/06 §3.11"),
    ("tendencia_corta", "2026-10-24", "fase-3/02"),
    ("confluencia_corta", "2026-10-24", "fase-3/02"),
    ("precio_min", "2026-10-24", "fase-3/02 §5"),
    ("objetivo_min_spread", "2026-10-24", "fase-3/02 §5"),
    ("stops_alternativos", "2026-10-25", "fase-3/03 §3"),
    ("escalonar", "2026-10-25", "fase-3/03 §3"),
    ("hipotesis_macd_positivo", "2026-10-26", "fase-3/01, hipotesis.yml"),
    ("filtros_adx", "2026-10-26", "fase-3/05 y fase-3/06 §2.1"),
    ("santo_grial", "2026-10-26", "fase-3/06 §2.2"),
    ("giro_adx_rsi", "2026-10-26", "fase-3/06 §2.2"),
    ("tendencia_adx_min", "2026-10-26", "fase-3/06 §2.3"),
    ("relajar_rr", "2026-10-26", "fase-3/07, 0051"),
    ("freno_choque", "2026-10-31", "fase-3/09 §6"),
    ("antes_de_resultados", "2026-10-31", "fase-3/09 §7"),
    ("calidad_valor", "2026-11-01", "fase-3/09 §8"),
    ("riesgo_abierto_por_mercado", "2026-11-02", "fase-3/07 §7, 0054"),
    ("rebote_caida", "2026-11-03", "fase-3/10"),
    ("ruptura_primera_hora", "2026-11-03", "fase-3/10 §6"),
    ("hueco_resultados", "2026-11-04", "fase-3/10 §7"),
    ("deriva_resultados", "2026-11-04", "fase-3/10 §8"),
    ("deriva_largos", "2026-11-04", "fase-3/10 §9"),
    ("rebote_fondo_bajista", "2026-11-04", "fase-3/11 §6"),
    ("caida_etf", "2026-11-05", "fase-3/11 §7"),
    ("hora_cripto", "2026-11-05", "fase-3/10 §10"),
]

PERCENTIL_TECHO = 99
PERCENTIL_DISENO_MIN = 50
VENTANAS = 5


def previas(nombre: str) -> int:
    """Cuántas ideas se probaron antes que `nombre`."""
    nombres = [r[0] for r in REGISTRO]
    if nombre not in nombres:
        raise KeyError(f"«{nombre}» no está en criterio.REGISTRO: regístrala en el commit que fija la prueba, "
                       "antes de ejecutarla")
    return nombres.index(nombre)


def percentil_por_previas(n: int) -> int:
    return min(PERCENTIL_TECHO, math.floor(100 - 10 / math.sqrt(1 + n)))


def percentil_exigido(nombre: str) -> int:
    return percentil_por_previas(previas(nombre))


@dataclass
class Movil:
    """Resultado de las ventanas móviles."""
    bloques: list[tuple[str, int, float | None]]   # (parámetros elegidos, operaciones, expectativa R)
    operaciones: int
    expectativa_r: float | None

    @property
    def positivos(self) -> int:
        return sum(1 for _, n, e in self.bloques if n and e is not None and e > 0)

    @property
    def aprueba(self) -> bool:
        con_ops = [b for b in self.bloques if b[1]]
        return (self.expectativa_r is not None and self.expectativa_r > 0
                and len(con_ops) > 0 and self.positivos * 2 >= len(con_ops))


def ventanas_moviles(por_parametros: dict, desde, hasta, minimo_ops: int = 30,
                     ventanas: int = VENTANAS) -> Movil:
    """`por_parametros`: {etiqueta: [operaciones]} de toda la rejilla sobre
    todo el calendario. Cada operación entra en el bloque de su fecha de
    entrada; la elección solo mira bloques anteriores (anclado: desde el
    principio)."""
    paso = (hasta - desde) / ventanas
    limites = [desde + paso * i for i in range(ventanas + 1)]
    bloques, fuera = [], []
    for k in range(1, ventanas):
        ini, fin = limites[k], limites[k + 1]
        mejor, mejor_e = None, None
        for etiqueta, ops in por_parametros.items():
            antes = [o.r for o in ops if o.fecha_entrada < ini]
            if len(antes) < minimo_ops:
                continue
            e = sum(antes) / len(antes)
            if mejor_e is None or e > mejor_e:
                mejor, mejor_e = etiqueta, e
        if mejor is None:
            bloques.append(("—", 0, None))
            continue
        dentro = [o.r for o in por_parametros[mejor]
                  if ini <= o.fecha_entrada and (o.fecha_entrada < fin or k == ventanas - 1)]
        fuera += dentro
        bloques.append((mejor, len(dentro), (sum(dentro) / len(dentro)) if dentro else None))
    return Movil(bloques, len(fuera), (sum(fuera) / len(fuera)) if fuera else None)
