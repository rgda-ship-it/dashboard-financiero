"""
Medidas y veredicto del laboratorio (doc 06 §3.4 y §3.5).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from laboratorio.motor import Operacion

# Criterio de «tiene ventaja», sobre el tramo de VALIDACIÓN (doc 06 §3.5).
MIN_OPERACIONES = 30
MIN_EXPECTATIVA_R = 0.10
MIN_FACTOR_BENEFICIO = 1.2
RIESGO_POR_OPERACION = 0.01      # para la caída máxima
TRAMO_DISENO = 0.70              # el 70 % inicial del calendario diseña; el resto valida


@dataclass
class Medidas:
    operaciones: int
    aciertos_pct: float
    expectativa_r: float
    expectativa_pct: float
    ganancia_media_r: float
    perdida_media_r: float
    factor_beneficio: float
    caida_maxima_pct: float
    dias_medios: float
    t: float
    ic90: tuple[float, float]
    racha_perdidas: int = 0          # peor racha de pérdidas seguidas (manual §7.4)
    coste_pct: float = 0.0           # spread pagado ÷ beneficio bruto antes de costes, en %


def medir(ops: list[Operacion], semilla: int = 7) -> Medidas | None:
    if not ops:
        return None
    r = np.array([o.r for o in ops], dtype=float)
    pct = np.array([o.pct for o in ops], dtype=float)
    ganadas, perdidas = r[r > 0], r[r <= 0]
    perdido = -perdidas.sum()
    factor = float(ganadas.sum() / perdido) if perdido > 0 else math.inf

    # Caída máxima con un riesgo fijo por operación, en orden de salida.
    capital, pico, caida = 1.0, 1.0, 0.0
    for o in sorted(ops, key=lambda x: x.fecha_salida):
        capital *= max(1 + RIESGO_POR_OPERACION * o.r, 0)
        pico = max(pico, capital)
        caida = max(caida, (pico - capital) / pico)

    n = len(r)
    desv = float(r.std(ddof=1)) if n > 1 else 0.0
    t = float(r.mean() / (desv / math.sqrt(n))) if desv > 0 else 0.0
    rng = np.random.default_rng(semilla)
    medias = rng.choice(r, size=(2000, n), replace=True).mean(axis=1)
    ic = (float(np.quantile(medias, 0.05)), float(np.quantile(medias, 0.95)))

    racha = peor = 0
    for o in sorted(ops, key=lambda x: x.fecha_salida):
        racha = racha + 1 if o.r <= 0 else 0
        peor = max(peor, racha)
    costes = np.array([getattr(o, "coste_r", 0.0) for o in ops], dtype=float)
    bruto = np.clip(r + costes, 0, None).sum()

    return Medidas(
        racha_perdidas=peor,
        coste_pct=float(costes.sum() / bruto * 100) if bruto > 0 else 0.0,
        operaciones=n,
        aciertos_pct=float((r > 0).mean() * 100),
        expectativa_r=float(r.mean()),
        expectativa_pct=float(pct.mean()),
        ganancia_media_r=float(ganadas.mean()) if len(ganadas) else 0.0,
        perdida_media_r=float(perdidas.mean()) if len(perdidas) else 0.0,
        factor_beneficio=factor,
        caida_maxima_pct=caida * 100,
        dias_medios=float(np.mean([o.dias for o in ops])),
        t=t,
        ic90=ic,
    )


def ic90_por_meses(ops: list[Operacion], semilla: int = 7) -> tuple[float, float] | None:
    """Intervalo del 90 % de la expectativa en R remuestreando MESES enteros
    en vez de operaciones sueltas. Las operaciones de un mismo mes (sobre
    todo en cripto, que se mueve en bloque) no son apuestas independientes:
    remuestrear meses respeta esa correlación y da un intervalo más honesto."""
    if not ops:
        return None
    meses: dict = {}
    for o in ops:
        clave = (o.fecha_salida.year, o.fecha_salida.month)
        suma, n = meses.get(clave, (0.0, 0))
        meses[clave] = (suma + o.r, n + 1)
    sumas = np.array([v[0] for v in meses.values()])
    cuentas = np.array([v[1] for v in meses.values()])
    rng = np.random.default_rng(semilla)
    idx = rng.integers(0, len(sumas), size=(2000, len(sumas)))
    medias = sumas[idx].sum(axis=1) / cuentas[idx].sum(axis=1)
    return float(np.quantile(medias, 0.05)), float(np.quantile(medias, 0.95))


def partir(ops: list[Operacion], corte) -> tuple[list[Operacion], list[Operacion]]:
    """(diseño, validación) según la fecha de entrada."""
    return ([o for o in ops if o.fecha_entrada < corte],
            [o for o in ops if o.fecha_entrada >= corte])


def veredicto(diseno: Medidas | None, validacion: Medidas | None) -> tuple[bool, list[str]]:
    """¿Tiene ventaja? Y, si no, por qué no."""
    motivos = []
    if validacion is None or validacion.operaciones < MIN_OPERACIONES:
        n = 0 if validacion is None else validacion.operaciones
        return False, [f"solo {n} operaciones en validación (mínimo {MIN_OPERACIONES})"]
    if validacion.expectativa_r <= MIN_EXPECTATIVA_R:
        motivos.append(f"expectativa {validacion.expectativa_r:+.3f} R (mínimo +{MIN_EXPECTATIVA_R} R)")
    if validacion.ic90[0] <= 0:
        motivos.append(f"el intervalo del 90 % incluye el cero ({validacion.ic90[0]:+.3f} R)")
    if validacion.factor_beneficio <= MIN_FACTOR_BENEFICIO:
        motivos.append(f"factor de beneficio {validacion.factor_beneficio:.2f} (mínimo {MIN_FACTOR_BENEFICIO})")
    if (diseno is not None and diseno.expectativa_r > 0
            and validacion.expectativa_r < diseno.expectativa_r / 3):
        motivos.append("en validación rinde menos de un tercio que en diseño (posible ajuste al ruido)")
    return (not motivos), motivos
