#!/usr/bin/env python3
"""
Una estrategia cruzada frente a MUCHAS tiradas de su referencia al azar
(doc 06 §3.11).

    python -m laboratorio.contra_azar --estrategia momento --universo etf --periodo max --parametros top=4,mantener=8

La referencia al azar de una sola semilla es ruidosa: en el S&P 100 su
validación va de +0,06 a +1,28 % al mes según la tirada. Aquí la
estrategia se compara con la distribución de `--semillas` tiradas, con las
mismas reglas y el mismo universo, y con la medida por mes en cartera: la
R por operación favorece a la que mantiene más tiempo, y el momento
mantiene de 3 a 4 veces más que su azar.

Escribe `contra_azar.md` en la carpeta de salida y, en GitHub Actions, en
el resumen del job.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.datos import UNIVERSOS, cargar, financiacion_de, spread_de, universo_nombrado  # noqa: E402
from laboratorio.ejecutar import crear  # noqa: E402
from laboratorio.estrategias import anadir_rangos  # noqa: E402
from laboratorio.motor import simular  # noqa: E402

# Una estrategia aporta selección si supera, en validación, a este
# porcentaje de las tiradas al azar (el equivalente a un contraste
# unilateral al 10 %).
PERCENTIL_MINIMO = 90

# La referencia al azar de cada estrategia cruzada: mismas reglas, otra puntuación.
REFERENCIAS = {"momento": "azar_momento", "tendencia_corta": "azar_corto"}


def mes_por_tramo(datos: dict, estrategia, corte) -> tuple[float | None, float | None]:
    """(% / mes en diseño, % / mes en validación)."""
    ops = [o for (s, c), df in anadir_rangos(datos, estrategia).items()
           for o in simular(df, estrategia, spread_de(s, c), s, c,
                            financiacion_corto_pct=financiacion_de(c))]
    d, v = metricas.partir(ops, corte)
    md, mv = metricas.medir(d), metricas.medir(v)
    return (md.mes_pct if md else None), (mv.mes_pct if mv else None)


def informe(nombre: str, datos: dict, corte, parametros: str = "", semillas: int = 30) -> str:
    referencia = REFERENCIAS[nombre]
    propia = mes_por_tramo(datos, crear(nombre, parametros), corte)
    tiradas = []
    for s in range(semillas):
        e = crear(referencia, parametros)
        e.semilla = s
        tiradas.append(mes_por_tramo(datos, e, corte))
    lineas = [
        f"# {nombre} frente a {semillas} tiradas de {referencia}",
        "",
        f"{len(datos)} activos. Validación desde el {corte:%Y-%m-%d}. Parámetros: {parametros or 'por defecto'}. "
        "Medida: rendimiento por mes (21 sesiones) en cartera.",
        "",
        f"Criterio: aporta selección si en validación supera al {PERCENTIL_MINIMO} % de las tiradas.",
        "",
        "| Tramo | Estrategia | Azar: mediana | Azar: p5 – p95 | Supera al |",
        "|---|---|---|---|---|",
    ]
    veredicto, en_validacion = None, None
    for i, tramo in enumerate(("Diseño", "**Validación**")):
        az = np.array([t[i] for t in tiradas if t[i] is not None])
        if propia[i] is None or not len(az):
            lineas.append(f"| {tramo} | — | — | — | — |")
            continue
        pct = float((az < propia[i]).mean() * 100)
        lineas.append(f"| {tramo} | {propia[i]:+.2f} % | {np.median(az):+.2f} % | "
                      f"{np.quantile(az, 0.05):+.2f} – {np.quantile(az, 0.95):+.2f} % | {pct:.0f} % |")
        if i == 1:
            veredicto, en_validacion = pct >= PERCENTIL_MINIMO, propia[i]
    lineas += ["", "✅ **aporta selección**" if veredicto else "❌ **no aporta selección frente al azar**", ""]
    if veredicto and en_validacion is not None and en_validacion <= 0:
        # Superar al azar perdiendo dinero es ser menos malo, no tener ventaja
        # (cortos en acciones, doc fase-3/02).
        lineas += [f"⚠️ **Pero pierde dinero** ({en_validacion:+.2f} % al mes en validación): "
                   "es menos mala que el azar, no una ventaja.", ""]
    return "\n".join(lineas)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategia", default="momento")
    p.add_argument("--universo", default="etf", choices=UNIVERSOS)
    p.add_argument("--periodo", default="max")
    p.add_argument("--parametros", default="")
    p.add_argument("--semillas", type=int, default=30)
    p.add_argument("--salida", default="laboratorio_salida")
    p.add_argument("--clase", default="accion", choices=("accion", "cripto"))
    a = p.parse_args()

    activos, _ = universo_nombrado(a.universo)
    datos = {}
    for simbolo, clase in activos:
        if clase != a.clase:
            continue
        df = cargar(simbolo, clase, a.periodo)
        if df is not None and len(df) >= 260:
            datos[(simbolo, clase)] = df
    if not datos:
        print("Sin datos: nada que medir.")
        return 1
    desde = min(df.index[0] for df in datos.values())
    hasta = max(df.index[-1] for df in datos.values())
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO

    texto = informe(a.estrategia, datos, corte, a.parametros, a.semillas)
    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "contra_azar.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
