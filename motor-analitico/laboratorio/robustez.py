#!/usr/bin/env python3
"""
Prueba de robustez de una estrategia que pasó el laboratorio (doc 06 §3.7).

    python -m laboratorio.robustez --estrategia tendencia --clase cripto --periodo 5y

Un aprobado en el laboratorio puede ser suerte. Esta prueba busca las tres
formas habituales de engañarse:

  · Concentración: ¿lo explica un solo activo o un solo año?
  · Ajuste: ¿solo funciona con esos parámetros exactos?
  · Supervivencia y correlación: ¿se sostiene con activos elegidos con la
    información de ENTONCES, con costes peores y contando los meses (no las
    operaciones) como apuestas independientes?

Escribe `robustez.md` en la carpeta de salida y, en GitHub Actions, en el
resumen del job.
"""

from __future__ import annotations

import argparse
import itertools
import os
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pandas as pd  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.datos import CRIPTO_TOP_2021, cargar, spread_de, universo, universo_nombrado  # noqa: E402
from laboratorio.ejecutar import _fmt  # noqa: E402
from laboratorio.estrategias import ESTRATEGIAS  # noqa: E402
from laboratorio.motor import Operacion, simular  # noqa: E402

from laboratorio.ejecutar import CABECERA as CAB  # noqa: E402

# Rejilla de parámetros por estrategia: cada combinación es una variante.
REJILLAS = {
    "tendencia": {"ruptura": (10, 15, 20, 30, 55), "sigue_atr": (2.5, 3.0, 4.0), "stop_atr": (1.5, 2.0, 3.0)},
    "reversion": {"umbral_rsi": (5, 10, 20), "dias_max": (3, 5, 10), "stop_atr": (2.0, 3.0, 4.0)},
    "actual": {"rr_minimo": (1.0, 1.2, 1.5, 2.0)},
    "retroceso": {"objetivo_r": (1.5, 2.0, 3.0)},
    "ruptura_volumen": {"factor_volumen": (1.2, 1.5, 2.0), "ruptura": (20, 30, 55)},
    "ruptura_2r": {"objetivo_r": (1.5, 2.0, 3.0), "ruptura": (20, 30, 55)},
    "reversion_bollinger": {"adx_max": (15, 20, 25), "dias_max": (5, 10, 15)},
}


def _variante(nombre: str, params: dict):
    if nombre in ("tendencia", "ruptura_volumen", "ruptura_2r") and "ruptura" in params:
        params = {**params, "salida": max(5, params["ruptura"] // 2)}
    return ESTRATEGIAS[nombre](**params)


def _correr(datos: dict, estrategia, factor_spread: float = 1.0) -> list[Operacion]:
    ops: list[Operacion] = []
    for (simbolo, clase), df in datos.items():
        base = spread_de(simbolo, clase)
        spread = base if factor_spread == 1.0 else (lambda p, b=base: b(p) * factor_spread)
        ops += simular(df, estrategia, spread, simbolo, clase)
    return ops


def _tabla(filas: list[tuple[str, metricas.Medidas | None]], primera: str = "Tramo") -> list[str]:
    lineas = ["| " + " | ".join([primera] + CAB) + " |", "|" + "---|" * (len(CAB) + 1)]
    lineas += [f"| {etq} | " + " | ".join(_fmt(m)) + " |" for etq, m in filas]
    return lineas + [""]


def _sello(diseno, validacion) -> str:
    ok, motivos = metricas.veredicto(metricas.medir(diseno), metricas.medir(validacion))
    return "✅" if ok else "❌ " + "; ".join(motivos)


def por_grupo(ops: list[Operacion], clave) -> list[tuple[str, int, float, float]]:
    """[(grupo, operaciones, expectativa R, R total)] ordenado por R total."""
    grupos = defaultdict(list)
    for o in ops:
        grupos[clave(o)].append(o.r)
    filas = [(g, len(r), sum(r) / len(r), sum(r)) for g, r in grupos.items()]
    return sorted(filas, key=lambda f: f[3], reverse=True)


def informe(nombre: str, clase: str, datos: dict, datos_2021: dict, corte: pd.Timestamp) -> str:
    base = ESTRATEGIAS[nombre]()
    ops = _correr(datos, base)
    diseno, validacion = metricas.partir(ops, corte)
    md, mv = metricas.medir(diseno), metricas.medir(validacion)
    ic_meses = metricas.ic90_por_meses(validacion)
    activos = sorted({s for s, _ in datos})
    lineas = [
        f"# Robustez: {nombre} en {clase}",
        "",
        f"{len(activos)} activos. Diseño hasta el {corte:%Y-%m-%d}; validación desde entonces. "
        "Mismas reglas de ejecución y spread que el laboratorio.",
        "",
        "## 1. Referencia (parámetros por defecto)",
        "",
        f"Veredicto: {_sello(diseno, validacion)}",
        "",
    ]
    lineas += _tabla([("Diseño", md), ("**Validación**", mv)])
    if ic_meses:
        lineas += [f"**Correlación.** Remuestreando meses enteros (no operaciones sueltas), el intervalo "
                   f"del 90 % de la validación es [{ic_meses[0]:+.2f}, {ic_meses[1]:+.2f}] R "
                   f"({'sigue por encima de cero' if ic_meses[0] > 0 else '**incluye el cero**'}).", ""]

    # 2. Concentración por activo.
    total_r = sum(o.r for o in ops) or 1.0
    lineas += ["## 2. ¿Lo explica un solo activo?", "",
               "Todo el histórico, ordenado por R total.", "",
               "| Activo | Ops | Expectativa (R) | R total | % del total | R total en validación |", "|---|---|---|---|---|---|"]
    r_val = {g: rt for g, _, _, rt in por_grupo(validacion, lambda o: o.activo)}
    filas_activo = por_grupo(ops, lambda o: o.activo)
    for g, n, e, rt in filas_activo:
        lineas.append(f"| {g} | {n} | {e:+.3f} | {rt:+.1f} | {rt / total_r * 100:.0f} % | {r_val.get(g, 0.0):+.1f} |")
    positivos = sum(1 for _, _, e, _ in filas_activo if e > 0)
    lineas += ["", f"{positivos} de {len(filas_activo)} activos con expectativa positiva.", ""]

    lineas += ["Quitando los mejores activos (por R total en todo el histórico):", ""]
    filas = []
    for k in (1, 2, 3):
        fuera = {g for g, *_ in filas_activo[:k]}
        d = [o for o in diseno if o.activo not in fuera]
        v = [o for o in validacion if o.activo not in fuera]
        filas.append((f"Sin {', '.join(sorted(fuera))}", metricas.medir(v), _sello(d, v)))
    lineas += ["| Validación | " + " | ".join(CAB) + " | Veredicto |", "|" + "---|" * (len(CAB) + 2)]
    lineas += [f"| {etq} | " + " | ".join(_fmt(m)) + f" | {s} |" for etq, m, s in filas] + [""]

    # 3. Concentración por año.
    lineas += ["## 3. ¿Lo explica un solo año?", "",
               "| Año | Ops | Expectativa (R) | R total |", "|---|---|---|---|"]
    for g, n, e, rt in sorted(por_grupo(ops, lambda o: o.fecha_salida.year)):
        lineas.append(f"| {g} | {n} | {e:+.3f} | {rt:+.1f} |")
    lineas.append("")

    # 4. Sensibilidad a los parámetros.
    rejilla = REJILLAS.get(nombre, {})
    claves = list(rejilla)
    combinaciones = [dict(zip(claves, vals)) for vals in itertools.product(*rejilla.values())]
    lineas += ["## 4. ¿Solo funciona con estos parámetros?", "",
               f"{len(combinaciones)} variantes; cada una se juzga en validación con el mismo criterio.", "",
               "| " + " | ".join(claves) + " | Ops | Expectativa (R) | IC 90 % | F. beneficio | Veredicto |",
               "|" + "---|" * (len(claves) + 5)]
    pasan = positivas = 0
    for params in combinaciones:
        o = _correr(datos, _variante(nombre, params))
        d, v = metricas.partir(o, corte)
        m = metricas.medir(v)
        ok, _ = metricas.veredicto(metricas.medir(d), m)
        pasan += ok
        positivas += bool(m and m.expectativa_r > 0)
        celdas = _fmt(m)
        lineas.append("| " + " | ".join(str(params[k]) for k in claves)
                      + f" | {celdas[0]} | {celdas[2]} | {celdas[3]} | {celdas[5]} | {'✅' if ok else '❌'} |")
    lineas += ["", f"**{pasan} de {len(combinaciones)} variantes pasan; "
               f"{positivas} de {len(combinaciones)} tienen expectativa positiva en validación.**", ""]

    # 5. Costes peores.
    caros = _correr(datos, base, factor_spread=3.0)
    d3, v3 = metricas.partir(caros, corte)
    lineas += ["## 5. ¿Aguanta un spread tres veces peor?", "",
               f"Veredicto: {_sello(d3, v3)}", ""]
    lineas += _tabla([("Diseño", metricas.medir(d3)), ("**Validación**", metricas.medir(v3))])

    # 6. Supervivencia.
    if datos_2021:
        o21 = _correr(datos_2021, base)
        d21, v21 = metricas.partir(o21, corte)
        lineas += ["## 6. ¿Funciona con activos elegidos en 2021?", "",
                   "El universo actual se eligió hoy, entre los que sobrevivieron. Estas son las criptos del "
                   "top de capitalización de octubre de 2021 que no están en él, incluidas las que luego se "
                   "hundieron. La estrategia no se diseñó con ellas, así que todo el histórico cuenta como "
                   f"fuera de muestra ({len(datos_2021)} activos con datos).", "",
                   f"Veredicto en validación: {_sello(d21, v21)}", ""]
        lineas += _tabla([("Todo el histórico", metricas.medir(o21)), ("Diseño", metricas.medir(d21)),
                          ("**Validación**", metricas.medir(v21))])
        lineas += ["| Activo | Ops | Expectativa (R) | R total |", "|---|---|---|---|"]
        lineas += [f"| {g} | {n} | {e:+.3f} | {rt:+.1f} |" for g, n, e, rt in por_grupo(o21, lambda o: o.activo)]
        lineas.append("")
    return "\n".join(lineas)


def _cargar_todos(activos, periodo) -> tuple[dict, list]:
    datos, sin_datos = {}, []
    for simbolo, clase in activos:
        df = cargar(simbolo, clase, periodo)
        if df is None or len(df) < 260:
            sin_datos.append(simbolo)
        else:
            datos[(simbolo, clase)] = df
    return datos, sin_datos


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategia", default="tendencia")
    p.add_argument("--clase", default="cripto", choices=("cripto", "accion"))
    p.add_argument("--periodo", default="5y")
    p.add_argument("--salida", default="laboratorio_salida")
    p.add_argument("--universo", default="activo", choices=("activo", "sp100"))
    a = p.parse_args()

    activos, _ = universo_nombrado(a.universo)
    datos, sin_datos = _cargar_todos([x for x in activos if x[1] == a.clase], a.periodo)
    if not datos:
        print("Sin datos: nada que medir.")
        return 1
    datos_2021, sin_2021 = (_cargar_todos([(t, "cripto") for t in CRIPTO_TOP_2021], a.periodo)
                            if a.clase == "cripto" else ({}, []))
    desde = min(df.index[0] for df in datos.values())
    hasta = max(df.index[-1] for df in datos.values())
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO

    texto = informe(a.estrategia, a.clase, datos, datos_2021, corte)
    if sin_datos or sin_2021:
        texto += f"\nSin datos de Yahoo: {', '.join(sin_datos + sin_2021)}.\n"

    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "robustez.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
