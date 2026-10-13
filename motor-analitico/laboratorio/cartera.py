#!/usr/bin/env python3
"""
La estrategia con las restricciones del agente real (doc 07 §5).

    python -m laboratorio.cartera --estrategia tendencia --clase cripto --periodo 10y

El laboratorio (`motor.py`) mide cada señal por separado: abre todas. El
agente no puede: tiene un saldo, arriesga el 1 % del equity por operación,
como mucho 4 × eso abierto a la vez (G6), a 1× (no compra más de lo que
tiene en caja) y, cuando no caben todas, entra primero en la ruptura más
fuerte (medida en ATR). Aquí se simulan todos los activos a la vez con una
sola cuenta para ver si la ventaja sobrevive a esas restricciones y cuánto
crece el saldo, con qué caídas.

Mismas reglas de ejecución que `motor.py`: entrada en la apertura siguiente
al precio de compra, stop con el mínimo del día al precio de venta, huecos
a la apertura, salida por regla en la apertura siguiente.
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.datos import cargar, spread_de, universo  # noqa: E402
from laboratorio.estrategias import ESTRATEGIAS, anadir_rangos  # noqa: E402
from laboratorio.motor import Operacion  # noqa: E402


@dataclass
class _Pos:
    cantidad: float
    entrada: float
    sl: float
    sl_inicial: float
    mejor: float
    fecha_senal: pd.Timestamp
    fecha_entrada: pd.Timestamp
    dia_entrada: int
    salir: bool = False


@dataclass
class Resultado:
    operaciones: list[Operacion]
    equity: pd.Series            # al cierre de cada día
    descartadas: int             # señales que no cupieron (G6 o caja)


def simular_cartera(datos: dict, estrategia, saldo: float = 500.0, riesgo_pct: float = 1.0,
                    multiplo_g6: float | None = 4.0, desde: pd.Timestamp | None = None) -> Resultado:
    """Una cuenta para todos los activos. `multiplo_g6=None` quita G6."""
    prep, spreads = {}, {}
    for (simbolo, clase), df in anadir_rangos(datos, estrategia).items():
        d = estrategia.preparar(df)
        prep[simbolo] = d
        spreads[simbolo] = (clase, spread_de(simbolo, clase))
    fechas = sorted(set().union(*[d.index for d in prep.values()]))
    if desde is not None:
        fechas = [f for f in fechas if f >= desde]

    def compra(s, p):
        return p + spreads[s][1](p) / 2

    def venta(s, p):
        return max(p - spreads[s][1](p) / 2, p / 2)

    caja = saldo
    pos: dict[str, _Pos] = {}
    pendientes: list[tuple[float, str, pd.Timestamp, float]] = []   # (fuerza, simbolo, fecha señal, sl)
    ops: list[Operacion] = []
    curva = {}
    ultimo_cierre: dict[str, float] = {}
    descartadas = 0

    def equity_marcado():
        return caja + sum(p.cantidad * venta(s, ultimo_cierre.get(s, p.entrada)) for s, p in pos.items())

    def riesgo_abierto():
        return sum(max(p.cantidad * (p.entrada - p.sl), 0) for p in pos.values())

    def cerrar(s, fecha, precio, motivo, i):
        nonlocal caja
        p = pos.pop(s)
        caja += p.cantidad * precio
        ops.append(Operacion(s, spreads[s][0], estrategia.nombre, p.fecha_senal, p.fecha_entrada, fecha,
                             p.entrada, p.sl_inicial, None, precio, motivo, i - p.dia_entrada))

    for i, fecha in enumerate(fechas):
        filas = {s: d.loc[fecha] for s, d in prep.items() if fecha in d.index}
        entradas_hoy = set()

        # 1. Entradas pendientes, de la ruptura más fuerte a la más débil.
        eq = equity_marcado()
        for fuerza, s, f_senal, sl in sorted(pendientes, reverse=True):
            fila = filas.get(s)
            if fila is None or s in pos or pd.isna(fila["Open"]):
                continue
            o = float(fila["Open"])
            precio = compra(s, o)
            if not (venta(s, o) > sl and precio > sl):
                continue
            cantidad = eq * riesgo_pct / 100 / (precio - sl)
            if multiplo_g6 is not None:
                libre = eq * riesgo_pct / 100 * multiplo_g6 - riesgo_abierto()
                if cantidad * (precio - sl) > libre + 1e-9:
                    descartadas += 1
                    continue
            cantidad = min(cantidad, caja / precio)
            if cantidad * precio < 10:          # mínimo de 10 $ del simulador
                descartadas += 1
                continue
            caja -= cantidad * precio
            pos[s] = _Pos(cantidad, precio, sl, sl, float(fila["Close"]), f_senal, fecha, i)
            entradas_hoy.add(s)
        pendientes = []

        # 2. Lo abierto: regla, hueco, stop.
        for s in list(pos):
            fila = filas.get(s)
            if fila is None or pd.isna(fila["Open"]):
                continue
            p = pos[s]
            o, l = float(fila["Open"]), float(fila["Low"])
            if p.salir and s not in entradas_hoy:
                cerrar(s, fecha, venta(s, o), "regla", i)
            elif s not in entradas_hoy and venta(s, o) <= p.sl:
                cerrar(s, fecha, venta(s, o), "hueco", i)
            elif venta(s, l) <= p.sl:
                cerrar(s, fecha, p.sl, "sl", i)

        # 3. Al cierre: gestionar y buscar señales.
        for s, fila in filas.items():
            if pd.isna(fila["Close"]):
                continue
            ultimo_cierre[s] = float(fila["Close"])
            t = prep[s].index.get_loc(fecha)
            if s in pos:
                p = pos[s]
                p.mejor = max(p.mejor, float(fila["Close"]))
                nuevo, salir = estrategia.actualizar(prep[s], t, p)
                p.sl = max(p.sl, nuevo)
                p.salir = salir
            elif i < len(fechas) - 1:
                ent = estrategia.entrada(prep[s], t)
                if ent is not None and ent.sl < float(fila["Close"]):
                    atr = float(fila.get("ATR_14", np.nan))
                    fuerza = ((float(fila["Close"]) - float(fila.get("MAX_RUPTURA", fila["Close"]))) / atr
                              if atr and atr > 0 else 0.0)
                    if getattr(estrategia, "cruzada", False):
                        fuerza = -float(fila[estrategia.columna])   # el rango 1 primero
                    pendientes.append((fuerza, s, fecha, ent.sl))
        curva[fecha] = equity_marcado()

    for s in list(pos):
        cerrar(s, fechas[-1], venta(s, ultimo_cierre[s]), "fin", len(fechas) - 1)
    return Resultado(ops, pd.Series(curva, dtype=float), descartadas)


# ``motor.Posicion`` expone ``mejor_cierre`` e ``indice_entrada``; las
# estrategias los leen en ``actualizar``.
_Pos.mejor_cierre = property(lambda self: self.mejor)
_Pos.indice_entrada = property(lambda self: self.dia_entrada)


def resumen_curva(curva: pd.Series) -> dict:
    if curva.empty:
        return {}
    anos = max((curva.index[-1] - curva.index[0]).days / 365.25, 1e-9)
    caida = float((curva / curva.cummax() - 1).min() * 100)
    return {"inicial": float(curva.iloc[0]), "final": float(curva.iloc[-1]),
            "anual_pct": float(((curva.iloc[-1] / curva.iloc[0]) ** (1 / anos) - 1) * 100),
            "caida_max_pct": caida, "anos": anos}


def informe(datos: dict, nombre: str, corte: pd.Timestamp, saldo: float) -> str:
    lineas = [f"# Cartera: {nombre} con las restricciones del agente", "",
              f"{len(datos)} activos, una sola cuenta de {saldo:.0f} $, 1 % de riesgo por operación, a 1×, "
              "prioridad a la ruptura más fuerte. Validación desde el "
              f"{corte:%Y-%m-%d}.", "",
              "| Escenario | Tramo | Ops | Expectativa (R) | IC 90 % | F. beneficio | Saldo final | Anual | Caída máx. | No cupieron |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for etiqueta, g6 in (("Agente (G6 = 4 × 1 %)", 4.0), ("Sin G6 (solo caja)", None)):
        for tramo, desde in (("Todo", None), ("**Validación**", corte)):
            res = simular_cartera(datos, ESTRATEGIAS[nombre](), saldo, 1.0, g6, desde)
            m = metricas.medir(res.operaciones)
            c = resumen_curva(res.equity)
            if m is None:
                lineas.append(f"| {etiqueta} | {tramo} | 0 | — | — | — | — | — | — | {res.descartadas} |")
                continue
            fb = "∞" if m.factor_beneficio == float("inf") else f"{m.factor_beneficio:.2f}"
            lineas.append(f"| {etiqueta} | {tramo} | {m.operaciones} | {m.expectativa_r:+.3f} | "
                          f"[{m.ic90[0]:+.2f}, {m.ic90[1]:+.2f}] | {fb} | {c['final']:,.0f} $ | "
                          f"{c['anual_pct']:+.1f} % | {c['caida_max_pct']:.1f} % | {res.descartadas} |")
    lineas += ["", "«Validación» empieza con el saldo inicial en la fecha de corte: es lo que habría hecho el agente "
               "en el tramo que no se usó para diseñar.", ""]
    return "\n".join(lineas)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategia", default="tendencia")
    p.add_argument("--clase", default="cripto", choices=("cripto", "accion"))
    p.add_argument("--periodo", default="5y")
    p.add_argument("--saldo", type=float, default=500.0)
    p.add_argument("--salida", default="laboratorio_salida")
    a = p.parse_args()

    datos = {}
    for simbolo, clase in universo():
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
    texto = informe(datos, a.estrategia, corte, a.saldo)

    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "cartera.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
