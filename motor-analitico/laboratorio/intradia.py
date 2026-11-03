#!/usr/bin/env python3
"""
Modo de 1 hora del laboratorio (doc fase-3/08 §4.3; doc fase-3/10).

    python -m laboratorio.intradia --estrategia rebote_caida --semillas 20

El motor es el mismo que el diario: trabaja por VELAS, no por días, así que
con velas de 1 hora cada fila es una hora. Las reglas de ejecución no
cambian: la señal al cierre de la hora t, la entrada en la apertura de
t + 1 con medio spread, stop y objetivo con el máximo y el mínimo de cada
hora, el stop gana el empate. Yahoo da unos 730 días de velas horarias.

Qué prueba: «pocas entradas, en momentos concretos, para una ganancia
rápida» (idea del dueño, 2026-11-03). La primera es el rebote tras una
caída brusca en cripto (`ReboteCaida`). Cómo se juzga:

  1. Una rejilla pequeña, fijada antes de mirar los datos, sobre el tramo
     de DISEÑO (el 70 % inicial del calendario). Se elige la combinación
     de mejor expectativa con al menos 30 operaciones.
  2. Esa combinación, y solo esa, se juzga en VALIDACIÓN (el 30 % final)
     con el criterio del laboratorio (`metricas.veredicto`).
  3. Frente al azar: las MISMAS salidas entrando a horas al azar con la
     misma frecuencia (`AzarRebote`), en `--semillas` tiradas. Aporta si en
     validación supera al 90 % de ellas.

Las estrategias de 1 hora no están en `estrategias.ESTRATEGIAS`: el
laboratorio diario las correría con velas diarias.

Escribe `intradia.md` en la carpeta de salida y, en GitHub Actions, en el
resumen del job.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import os
import pickle
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.datos import CRIPTO_YAHOO, cargar, spread_de  # noqa: E402
from laboratorio.estrategias import _atr  # noqa: E402
from laboratorio.motor import Entrada, Posicion, simular  # noqa: E402

PERCENTIL_MINIMO = 90
BARRAS_MES = {"cripto": 24 * 30, "accion": 7 * 21}   # velas de 1 hora en un mes
PERIODO = "730d"                                     # lo máximo que da Yahoo en 1 hora


class ReboteCaida:
    """Rebote tras una caída brusca (doc fase-3/10 §2). Al cierre de una
    hora, si el precio está `caida_atr` ATR de 1 hora por debajo del máximo
    de las últimas `ventana` horas, se compra en la apertura siguiente.
    Stop a `stop_atr` ATR y objetivo a `objetivo_atr` ATR del cierre de la
    señal; si no toca ninguno, se sale a las `horas` horas.

    El ATR es el de `atr_n` horas e incluye las de la caída: es causal, y
    tras un desplome el stop queda más ancho, como lo pondría el agente."""

    nombre = "rebote_caida"

    def __init__(self, caida_atr: float = 6.0, ventana: int = 6, atr_n: int = 48,
                 stop_atr: float = 2.0, objetivo_atr: float = 2.0, horas: int = 12):
        self.caida_atr, self.ventana, self.atr_n = caida_atr, ventana, atr_n
        self.stop_atr, self.objetivo_atr, self.horas = stop_atr, objetivo_atr, horas

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy()
        if "ATR_H" not in out.columns:      # el runner lo calcula una vez para toda la rejilla
            out["ATR_H"] = _atr(df, self.atr_n)
        maximo = out["High"].rolling(self.ventana, min_periods=self.ventana).max()
        out["CAIDA_ATR"] = (maximo - out["Close"]) / out["ATR_H"]
        return out

    def _niveles(self, df: pd.DataFrame, t: int) -> Entrada | None:
        atr = df["ATR_H"].iloc[t]
        if pd.isna(atr) or atr <= 0:
            return None
        c = float(df["Close"].iloc[t])
        return Entrada(sl=c - self.stop_atr * float(atr), tp=c + self.objetivo_atr * float(atr))

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        caida = df["CAIDA_ATR"].iloc[t]
        if pd.isna(caida) or caida < self.caida_atr:
            return None
        return self._niveles(df, t)

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion):
        # Salida por tiempo: tras `horas` velas abierta, en la apertura siguiente.
        return pos.sl, t - pos.indice_entrada >= self.horas - 1


class AzarRebote(ReboteCaida):
    """La referencia de `ReboteCaida`: las mismas salidas (stop, objetivo y
    tiempo en ATR de 1 hora), entrando a horas al azar con probabilidad
    `probabilidad`. Determinista y causal: depende de la semilla, la hora y
    el cierre de esa hora."""

    nombre = "azar_rebote"

    def __init__(self, probabilidad: float = 0.01, semilla: int = 0, **kw):
        super().__init__(**kw)
        self.probabilidad, self.semilla = probabilidad, semilla

    def entrada(self, df, t):
        clave = f"{self.semilla}-{df.index[t].value}-{float(df['Close'].iloc[t]):.6f}".encode()
        if int(hashlib.md5(clave).hexdigest()[:8], 16) / 0xFFFFFFFF >= self.probabilidad:
            return None
        return self._niveles(df, t)


ESTRATEGIAS_1H = {"rebote_caida": (ReboteCaida, AzarRebote)}

# La rejilla de cada estrategia, fijada ANTES de mirar los datos (doc
# fase-3/10 §2): 9 combinaciones, todas sobre el tramo de diseño.
REJILLAS = {"rebote_caida": {"caida_atr": (4.0, 6.0, 8.0), "horas": (6, 12, 24)}}


def operar(datos: dict, estrategia) -> list:
    return [o for (s, c), df in datos.items()
            for o in simular(df, estrategia, spread_de(s, c), s, c)]


def medir(ops: list, clase: str) -> metricas.Medidas | None:
    return metricas.medir(ops, barras_mes=BARRAS_MES[clase])


def _fila(nombre: str, m: metricas.Medidas | None) -> str:
    if m is None:
        return f"| {nombre} | 0 | — | — | — | — | — |"
    return (f"| {nombre} | {m.operaciones} | {m.expectativa_r:+.3f} R | {m.ic90[0]:+.3f} – {m.ic90[1]:+.3f} | "
            f"{m.aciertos_pct:.0f} % | {m.coste_pct:.0f} % | {m.dias_medios:.1f} h |")


def informe(nombre: str, datos: dict, clase: str, semillas: int = 20) -> str:
    base, azar = ESTRATEGIAS_1H[nombre]
    desde = min(df.index[0] for df in datos.values())
    hasta = max(df.index[-1] for df in datos.values())
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO
    rejilla = REJILLAS[nombre]
    claves = list(rejilla)

    # El ATR no depende de la rejilla: se calcula una vez.
    datos = {k: base().preparar(df)[["Open", "High", "Low", "Close", "Volume", "ATR_H"]] for k, df in datos.items()}

    filas, resultados = [], {}
    for valores in itertools.product(*(rejilla[k] for k in claves)):
        params = dict(zip(claves, valores))
        ops = operar(datos, base(**params))
        d, v = metricas.partir(ops, corte)
        resultados[valores] = (params, ops, medir(d, clase), medir(v, clase))

    candidatas = [r for r in resultados.values() if r[2] is not None and r[2].operaciones >= metricas.MIN_OPERACIONES]
    lineas = [
        f"# Modo de 1 hora: {nombre}",
        "",
        f"{len(datos)} activos de {clase}, velas de 1 hora del {desde:%Y-%m-%d} al {hasta:%Y-%m-%d}. "
        f"Diseño hasta el {corte:%Y-%m-%d %H:%M}; validación desde ahí. Spread de la 0034 en cada entrada y salida.",
        "",
        "## Rejilla en diseño (aquí se elige)",
        "",
        "| Parámetros | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto | Duración |",
        "|---|---|---|---|---|---|---|",
    ]
    for params, _, d, _ in resultados.values():
        lineas.append(_fila(", ".join(f"{k}={v}" for k, v in params.items()), d))
    if not candidatas:
        lineas += ["", "❌ **Ninguna combinación llega a 30 operaciones en diseño.**"]
        return "\n".join(lineas)

    params, ops, d, v = max(candidatas, key=lambda r: r[2].expectativa_r)
    elegida = ", ".join(f"{k}={x}" for k, x in params.items())
    ok, motivos = metricas.veredicto(d, v)
    _, val_ops = metricas.partir(ops, corte)
    ic_meses = metricas.ic90_por_meses(val_ops)

    # Azar con la misma frecuencia de entrada: una posición a la vez, así
    # que la probabilidad se mide sobre las horas en que se podía entrar.
    barras = sum(len(df) for df in datos.values())
    horas_abiertas = sum(o.dias + 1 for o in ops)
    probabilidad = len(ops) / max(barras - horas_abiertas, 1)
    tiradas = []
    for s in range(semillas):
        _, av = metricas.partir(operar(datos, azar(probabilidad=probabilidad, semilla=s, **params)), corte)
        m = medir(av, clase)
        if m is not None:
            tiradas.append(m)
    az = np.array([m.expectativa_r for m in tiradas])
    pct = float((az < v.expectativa_r).mean() * 100) if v is not None and len(az) else 0.0
    supera = pct >= PERCENTIL_MINIMO

    lineas += [
        "",
        f"## Validación de la elegida ({elegida})",
        "",
        "| Tramo | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto | Duración |",
        "|---|---|---|---|---|---|---|",
        _fila("Diseño", d),
        _fila("**Validación**", v),
    ]
    if ic_meses is not None:
        lineas += ["", f"IC 90 % remuestreando meses (las caídas de cripto llegan en bloque): "
                       f"{ic_meses[0]:+.3f} – {ic_meses[1]:+.3f} R."]
    if v is not None:
        # Sin el «por mes en cartera»: con operaciones de pocas horas, encadenar
        # sus rendimientos como si se estuviera siempre dentro da cifras irreales.
        lineas += [f"Factor de beneficio {v.factor_beneficio:.2f}."]
    lineas += [
        "",
        f"## Frente a {len(tiradas)} tiradas al azar (mismas salidas, probabilidad {probabilidad:.4f} por hora)",
        "",
    ]
    if len(az):
        lineas += [f"Azar en validación: mediana {np.median(az):+.3f} R, p5 – p95 {np.quantile(az, 0.05):+.3f} – "
                   f"{np.quantile(az, 0.95):+.3f} R, {np.median([m.operaciones for m in tiradas]):.0f} operaciones. "
                   f"La elegida supera al **{pct:.0f} %** (mínimo {PERCENTIL_MINIMO} %).", ""]
    lineas += ["## Validación de toda la rejilla (solo para ver; no elige)", "",
               "| Parámetros | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto | Duración |",
               "|---|---|---|---|---|---|---|"]
    for p_, _, _, vv in resultados.values():
        lineas.append(_fila(", ".join(f"{k}={x}" for k, x in p_.items()), vv))

    lineas += ["", "## Veredicto", ""]
    if ok and supera:
        lineas.append("✅ **tiene ventaja y supera al azar** en validación.")
    else:
        if not ok:
            lineas += [f"- {m}" for m in motivos]
        if not supera:
            lineas.append(f"- no supera al azar: percentil {pct:.0f} (mínimo {PERCENTIL_MINIMO})")
        lineas += ["", "❌ **no tiene ventaja**."]
    return "\n".join(lineas)


def cargar_cripto(cache: Path | None = None) -> dict:
    if cache is not None and cache.exists():
        return pickle.loads(cache.read_bytes())
    datos = {}
    for simbolo in CRIPTO_YAHOO:
        df = cargar(simbolo, "cripto", PERIODO, intervalo="1h")
        if df is not None and len(df) >= 24 * 60:
            datos[(simbolo, "cripto")] = df
    if cache is not None:
        cache.write_bytes(pickle.dumps(datos))
    return datos


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategia", default="rebote_caida", choices=ESTRATEGIAS_1H)
    p.add_argument("--semillas", type=int, default=20)
    p.add_argument("--salida", default="laboratorio_salida")
    p.add_argument("--cache", default="", help="pickle con las velas, para repetir sin descargar")
    a = p.parse_args()

    datos = cargar_cripto(Path(a.cache) if a.cache else None)
    if not datos:
        print("Sin datos: nada que medir.")
        return 1
    texto = informe(a.estrategia, datos, "cripto", a.semillas)
    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "intradia.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
