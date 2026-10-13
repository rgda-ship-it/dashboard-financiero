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
from laboratorio.datos import UNIVERSOS, cargar, spread_de, universo, universo_nombrado  # noqa: E402
from laboratorio.estrategias import ESTRATEGIAS, anadir_rangos  # noqa: E402
from laboratorio.motor import simular  # noqa: E402


# Columnas de _fmt, en el mismo orden.
CABECERA = ["Ops", "Aciertos", "Expectativa (R)", "IC 90 %", "Media %", "F. beneficio", "Caída máx.",
            "Días", "% / mes", "Racha −", "Costes"]


def _fmt(m: metricas.Medidas | None) -> list[str]:
    if m is None:
        return ["0"] + ["—"] * (len(CABECERA) - 1)
    fb = "∞" if math.isinf(m.factor_beneficio) else f"{m.factor_beneficio:.2f}"
    return [str(m.operaciones), f"{m.aciertos_pct:.0f} %", f"{m.expectativa_r:+.3f}",
            f"[{m.ic90[0]:+.2f}, {m.ic90[1]:+.2f}]", f"{m.expectativa_pct:+.2f} %", fb,
            f"{m.caida_maxima_pct:.1f} %", f"{m.dias_medios:.1f}", f"{m.mes_pct:+.2f} %", str(m.racha_perdidas),
            f"{m.coste_pct:.0f} %"]


def crear(nombre: str, parametros: str = ""):
    """Una estrategia con los parámetros «nombre=valor,…» que admita; los
    que no admite se ignoran, para poder pasar los mismos a varias."""
    import inspect
    clase = ESTRATEGIAS[nombre]
    admitidos = set()
    for c in clase.__mro__:
        if "__init__" in vars(c):
            admitidos |= set(inspect.signature(c.__init__).parameters) - {"self", "kw"}
    params = {}
    for par in filter(None, parametros.split(",")):
        k, v = par.split("=")
        if k.strip() in admitidos:
            v = v.strip()
            params[k.strip()] = int(v) if v.lstrip("-").isdigit() else float(v)
    return clase(**params)


def con_regimen(df: pd.DataFrame) -> pd.DataFrame:
    """Añade REGIMEN (manual §1.4): «tendencia» con ADX 14 ≥ 25, «rango» si
    no. Causal: el ADX de cada día solo usa ese día y los anteriores."""
    import pandas_ta as ta
    adx = ta.adx(df["High"], df["Low"], df["Close"], length=14)
    df = df.copy()
    df["REGIMEN"] = "sin_dato"
    if adx is not None:
        df.loc[adx["ADX_14"] >= 25, "REGIMEN"] = "tendencia"
        df.loc[adx["ADX_14"] < 25, "REGIMEN"] = "rango"
    return df


def informe(ops_por_estrategia: dict, corte: pd.Timestamp, desde, hasta, n_activos: int, sin_datos: list,
            sectores: dict | None = None) -> str:
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
    cab = ["Tramo"] + CABECERA
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
            if clase == "todas":
                partes = []
                for reg in ("tendencia", "rango"):
                    m = metricas.medir([o for o in validacion if o.regimen == reg])
                    partes.append(f"{reg}: {m.operaciones} ops, {m.expectativa_r:+.3f} R" if m else f"{reg}: 0 ops")
                lineas += ["Validación por régimen al dar la señal (ADX 14 ≥ 25 = tendencia): " + "; ".join(partes) + ".", ""]
        if sectores:
            lineas += por_sector(ops, sectores, corte)
    if sin_datos:
        lineas += [f"Sin datos de Yahoo: {', '.join(sin_datos)}.", ""]
    return "\n".join(lineas)


def por_sector(ops: list, sectores: dict, corte: pd.Timestamp) -> list[str]:
    """Amplitud (doc 06 §3.9): expectativa por sector y cuántos valores de
    cada uno ganan."""
    lineas = ["Por sector (todo el histórico y validación):", "",
              "| Sector | Valores | Valores con E > 0 | Ops | Expectativa (R) | Ops validación | Expectativa validación (R) |",
              "|---|---|---|---|---|---|---|"]
    for sector in sorted(set(sectores.values())):
        sel = [o for o in ops if sectores.get(o.activo) == sector]
        if not sel:
            continue
        por_activo: dict = {}
        for o in sel:
            por_activo.setdefault(o.activo, []).append(o.r)
        positivos = sum(1 for r in por_activo.values() if sum(r) > 0)
        val = [o for o in sel if o.fecha_entrada >= corte]
        e = sum(o.r for o in sel) / len(sel)
        ev = f"{sum(o.r for o in val) / len(val):+.3f}" if val else "—"
        lineas.append(f"| {sector} | {len(por_activo)} | {positivos} | {len(sel)} | {e:+.3f} | {len(val)} | {ev} |")
    por_activo = {}
    for o in ops:
        por_activo.setdefault(o.activo, []).append(o.r)
    positivos = sum(1 for r in por_activo.values() if sum(r) > 0)
    lineas += ["", f"**{positivos} de {len(por_activo)} valores con expectativa positiva en todo el histórico.**", ""]
    return lineas


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategias", default=",".join(ESTRATEGIAS))
    p.add_argument("--periodo", default="5y")
    p.add_argument("--salida", default="laboratorio_salida")
    p.add_argument("--activos", default="", help="simbolo:clase separados por comas (por defecto, el universo)")
    p.add_argument("--universo", default="activo", choices=UNIVERSOS)
    p.add_argument("--parametros", default="", help="nombre=valor separados por comas, para las estrategias que los admitan")
    a = p.parse_args()

    activos, sectores = universo_nombrado(a.universo)
    if a.activos:
        activos = [tuple(x.split(":")) for x in a.activos.split(",") if x]
    estrategias = [crear(n, a.parametros) for n in a.estrategias.split(",") if n]
    ops_por_estrategia = {e.nombre: [] for e in estrategias}
    desde, hasta, sin_datos, n = None, None, [], 0

    # Primero todos los datos: las estrategias cruzadas (momento) clasifican
    # cada activo frente a los demás de su clase en cada fecha.
    datos = {}
    for simbolo, clase in activos:
        df = cargar(simbolo, clase, a.periodo)
        if df is None or len(df) < 260:
            sin_datos.append(simbolo)
            continue
        datos[(simbolo, clase)] = con_regimen(df)
        n += 1
        desde = df.index[0] if desde is None else min(desde, df.index[0])
        hasta = df.index[-1] if hasta is None else max(hasta, df.index[-1])
        print(f"  {simbolo:<14} {len(df)} velas")
    for e in estrategias:
        for (simbolo, clase), df in anadir_rangos(datos, e).items():
            ops_por_estrategia[e.nombre] += simular(df, e, spread_de(simbolo, clase), simbolo, clase)

    if n == 0:
        print("Sin datos: nada que medir.")
        return 1
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO
    texto = informe(ops_por_estrategia, corte, desde, hasta, n, sin_datos, sectores)

    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "informe.md").write_text(texto, encoding="utf-8")
    with open(salida / "operaciones.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["estrategia", "activo", "clase", "fecha_senal", "fecha_entrada", "fecha_salida",
                    "precio_entrada", "sl_inicial", "tp", "precio_salida", "motivo", "dias", "r", "pct", "coste_r",
                    "regimen", "tramo"])
        for nombre, ops in ops_por_estrategia.items():
            for o in ops:
                w.writerow([nombre, o.activo, o.clase, o.fecha_senal.date(), o.fecha_entrada.date(),
                            o.fecha_salida.date(), round(o.precio_entrada, 6), round(o.sl_inicial, 6),
                            "" if o.tp is None else round(o.tp, 6), round(o.precio_salida, 6), o.motivo,
                            o.dias, round(o.r, 4), round(o.pct, 4), round(o.coste_r, 4), o.regimen,
                            "diseno" if o.fecha_entrada < corte else "validacion"])
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
