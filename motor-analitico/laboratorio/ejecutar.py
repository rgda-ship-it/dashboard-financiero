#!/usr/bin/env python3
"""
Ejecuta el laboratorio y escribe el informe (doc 06).

    python -m laboratorio.ejecutar --estrategias actual,tendencia,reversion --periodo 5y

Escribe `informe.md` y `operaciones.csv` en la carpeta de salida y, en
GitHub Actions, el informe en el resumen del job.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pandas as pd  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.datos import cargar, spread_de, universo  # noqa: E402
from laboratorio.estrategias import ESTRATEGIAS  # noqa: E402
from laboratorio.motor import simular  # noqa: E402


def _fmt(m: metricas.Medidas | None) -> list[str]:
    if m is None:
        return ["0"] + ["—"] * 7
    fb = "∞" if math.isinf(m.factor_beneficio) else f"{m.factor_beneficio:.2f}"
    return [str(m.operaciones), f"{m.aciertos_pct:.0f} %", f"{m.expectativa_r:+.3f}",
            f"[{m.ic90[0]:+.2f}, {m.ic90[1]:+.2f}]", f"{m.expectativa_pct:+.2f} %", fb,
            f"{m.caida_maxima_pct:.1f} %", f"{m.dias_medios:.1f}"]


def informe(ops_por_estrategia: dict, corte: pd.Timestamp, desde, hasta, n_activos: int, sin_datos: list) -> str:
    lineas = [
        "# Laboratorio de estrategias",
        "",
        f"Histórico del {desde:%Y-%m-%d} al {hasta:%Y-%m-%d}, {n_activos} activos. "
        f"Diseño hasta el {corte:%Y-%m-%d}; **validación** desde entonces. "
        "Spread pesimista de la 0034; huecos al precio de apertura; empate stop/objetivo → stop.",
        "",
        "Criterio de ventaja (en validación): ≥ 30 operaciones, expectativa > +0,10 R, "
        "intervalo del 90 % por encima de cero, factor de beneficio > 1,2 y sin desplome frente al diseño.",
        "",
    ]
    cab = ["Tramo", "Ops", "Aciertos", "Expectativa (R)", "IC 90 %", "Media %", "F. beneficio", "Caída máx.", "Días"]
    for nombre, ops in ops_por_estrategia.items():
        lineas += [f"## {nombre}", ""]
        for clase in ("todas", "accion", "cripto"):
            sel = ops if clase == "todas" else [o for o in ops if o.clase == clase]
            diseno, validacion = metricas.partir(sel, corte)
            md, mv = metricas.medir(diseno), metricas.medir(validacion)
            ok, motivos = metricas.veredicto(md, mv)
            titulo = {"todas": "Todas", "accion": "Acciones", "cripto": "Cripto"}[clase]
            lineas += [f"**{titulo}** — " + ("✅ **tiene ventaja**" if ok else "❌ sin ventaja: " + "; ".join(motivos)), ""]
            lineas += ["| " + " | ".join(cab) + " |", "|" + "---|" * len(cab)]
            lineas += ["| Diseño | " + " | ".join(_fmt(md)) + " |",
                       "| **Validación** | " + " | ".join(_fmt(mv)) + " |", ""]
    if sin_datos:
        lineas += [f"Sin datos de Yahoo: {', '.join(sin_datos)}.", ""]
    return "\n".join(lineas)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategias", default="actual,tendencia,reversion")
    p.add_argument("--periodo", default="5y")
    p.add_argument("--salida", default="laboratorio_salida")
    p.add_argument("--activos", default="", help="simbolo:clase separados por comas (por defecto, el universo)")
    a = p.parse_args()

    activos = ([tuple(x.split(":")) for x in a.activos.split(",") if x] if a.activos else universo())
    estrategias = [ESTRATEGIAS[n]() for n in a.estrategias.split(",") if n]
    ops_por_estrategia = {e.nombre: [] for e in estrategias}
    desde, hasta, sin_datos, n = None, None, [], 0

    for simbolo, clase in activos:
        df = cargar(simbolo, clase, a.periodo)
        if df is None or len(df) < 260:
            sin_datos.append(simbolo)
            continue
        n += 1
        desde = df.index[0] if desde is None else min(desde, df.index[0])
        hasta = df.index[-1] if hasta is None else max(hasta, df.index[-1])
        for e in estrategias:
            ops_por_estrategia[e.nombre] += simular(df, e, spread_de(simbolo, clase), simbolo, clase)
        print(f"  {simbolo:<14} {len(df)} velas")

    if n == 0:
        print("Sin datos: nada que medir.")
        return 1
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO
    texto = informe(ops_por_estrategia, corte, desde, hasta, n, sin_datos)

    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "informe.md").write_text(texto, encoding="utf-8")
    with open(salida / "operaciones.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["estrategia", "activo", "clase", "fecha_senal", "fecha_entrada", "fecha_salida",
                    "precio_entrada", "sl_inicial", "tp", "precio_salida", "motivo", "dias", "r", "pct", "tramo"])
        for nombre, ops in ops_por_estrategia.items():
            for o in ops:
                w.writerow([nombre, o.activo, o.clase, o.fecha_senal.date(), o.fecha_entrada.date(),
                            o.fecha_salida.date(), round(o.precio_entrada, 6), round(o.sl_inicial, 6),
                            "" if o.tp is None else round(o.tp, 6), round(o.precio_salida, 6), o.motivo,
                            o.dias, round(o.r, 4), round(o.pct, 4),
                            "diseno" if o.fecha_entrada < corte else "validacion"])
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
