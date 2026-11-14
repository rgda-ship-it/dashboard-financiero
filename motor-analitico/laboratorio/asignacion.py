#!/usr/bin/env python3
"""
Cuánta exposición llevar, medida como cartera y contra comprar y mantener
(doc fase-4/00).

    python -m laboratorio.asignacion --prueba tendencia_clases

Todo lo probado hasta la fase 3 busca CUÁNDO entrar en un activo y se mide
en R por operación. Aquí la pregunta es otra: con una cartera que ya está
comprada, ¿mejora decidir una vez al mes cuánta llevar? Se mide la cartera
entera, mes a mes, contra la misma cartera sin tocar (la vara).

Reglas de ejecución:
- La decisión del mes usa solo cierres hasta el último día del mes anterior.
- Se ejecuta en la apertura de la primera sesión del mes; el rendimiento del
  mes va de esa apertura a la primera del mes siguiente.
- Cada cambio de peso paga medio spread (el de la 0034).
- Lo que no está invertido queda en caja al 0 %: es pesimista, porque la
  caja real paga interés.

La referencia al azar: la misma serie de exposición de cada activo,
desplazada en el tiempo un número de meses al azar. Conserva cuánto tiempo
está dentro y cuántas veces cambia; solo rompe el momento en que lo hace.
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

from laboratorio import criterio, metricas  # noqa: E402
from laboratorio.datos import cargar, spread_de  # noqa: E402

# Las cinco clases de activo de Faber (2007), cada una con el ETF líquido
# más antiguo. Se pueden elegir con la información de 2006: ninguna está
# aquí por lo que hizo después.
CLASES = [("SPY", "accion"), ("EFA", "accion"), ("IEF", "accion"), ("VNQ", "accion"), ("DBC", "accion")]
BITCOIN = [("bitcoin", "cripto")]
# Lo que ofrece el broker (2026-11-14): no tiene EFA ni DBC, ni otro ETF de
# bolsa desarrollada o de materias primas amplias. Quedan bolsa de EE. UU.,
# bonos, inmobiliario y oro (GLD, de 2004). Elegida por disponibilidad, no
# por resultados, pero después de ver los de las cinco clases.
CLASES_BROKER = [("SPY", "accion"), ("IEF", "accion"), ("VNQ", "accion"), ("GLD", "accion")]

# Meses de historia antes del primer mes medido: los de la media más larga
# de la rejilla, para que todas las variantes y la vara compartan calendario.
CALENTAMIENTO = 12

# prueba → (activos, regla, parámetro fijado de antemano, rejilla de robustez)
PRUEBAS = {
    "tendencia_clases": (CLASES, "tendencia", 10, (6, 8, 10, 12)),
    "volatilidad_objetivo_clases": (CLASES, "volatilidad", 21, (21, 42, 63)),
    "tendencia_bitcoin": (BITCOIN, "tendencia", 10, (6, 8, 10, 12)),
    "tendencia_clases_broker": (CLASES_BROKER, "tendencia", 10, (6, 8, 10, 12)),
}


@dataclass
class Medida:
    meses: int
    anual_pct: float          # rentabilidad anual compuesta
    volatilidad_pct: float
    sharpe: float             # sin tipo libre de riesgo
    caida_max_pct: float
    exposicion_pct: float


def mensual(datos: dict) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    """(apertura de la primera sesión, cierre de la última, rendimientos
    diarios) con una columna por activo. Los dos primeros, por mes."""
    ap, ci, di = {}, {}, {}
    for (simbolo, _), df in datos.items():
        mes = df.index.to_period("M")
        ap[simbolo] = df["Open"].groupby(mes).first()
        ci[simbolo] = df["Close"].groupby(mes).last()
        di[simbolo] = df["Close"].pct_change()
    return pd.DataFrame(ap).dropna(), pd.DataFrame(ci).dropna(), pd.DataFrame(di).dropna()


def pesos_mantener(cierres: pd.DataFrame) -> pd.DataFrame:
    return pd.DataFrame(1.0 / cierres.shape[1], index=cierres.index, columns=cierres.columns)


def pesos_tendencia(cierres: pd.DataFrame, meses: int) -> pd.DataFrame:
    """Cada activo lleva su parte si cerró el mes anterior sobre su media de
    `meses` cierres mensuales; si no, esa parte queda en caja."""
    dentro = (cierres > cierres.rolling(meses).mean()).shift(1)
    return dentro.where(dentro.notna(), False).astype(float) / cierres.shape[1]


def pesos_volatilidad(cierres: pd.DataFrame, diarios: pd.DataFrame, ventana: int) -> pd.DataFrame:
    """La cartera entera, reducida cuando su volatilidad reciente supera la
    habitual: exposición = min(1, mediana de lo visto hasta entonces /
    volatilidad de las últimas `ventana` sesiones). Sin apalancamiento."""
    vol = diarios.mean(axis=1).rolling(ventana).std()
    al_cierre = vol.groupby(vol.index.to_period("M")).last().reindex(cierres.index)
    habitual = al_cierre.expanding(min_periods=CALENTAMIENTO - 1).median()
    exposicion = (habitual / al_cierre).clip(upper=1.0).shift(1).fillna(0.0)
    return pd.DataFrame({c: exposicion / cierres.shape[1] for c in cierres.columns})


def simular(aperturas: pd.DataFrame, pesos: pd.DataFrame, clases: dict[str, str]) -> pd.Series:
    """Rendimiento neto de cada mes. El último mes del calendario no tiene
    apertura siguiente y queda fuera."""
    rend = (aperturas.shift(-1) / aperturas - 1).iloc[:-1]
    spreads = {s: spread_de(s, clases[s]) for s in aperturas.columns}
    deriva = np.zeros(aperturas.shape[1])
    netos = []
    for mes, r in rend.iterrows():
        w = pesos.loc[mes].to_numpy()
        precio = aperturas.loc[mes]
        medio = np.array([spreads[s](precio[s]) / 2 / precio[s] for s in aperturas.columns])
        coste = float((np.abs(w - deriva) * medio).sum())
        bruto = float((w * r.to_numpy()).sum())
        netos.append(bruto - coste)
        deriva = w * (1 + r.to_numpy()) / (1 + bruto)
    return pd.Series(netos, index=rend.index)


def medir(netos: pd.Series, pesos: pd.DataFrame) -> Medida | None:
    if len(netos) < 12 or netos.std() == 0:
        return None
    valor = (1 + netos).cumprod()
    caida = float((1 - valor / valor.cummax().clip(lower=1.0)).max() * 100)
    return Medida(
        meses=len(netos),
        anual_pct=float((valor.iloc[-1] ** (12 / len(netos)) - 1) * 100),
        volatilidad_pct=float(netos.std() * np.sqrt(12) * 100),
        sharpe=float(netos.mean() / netos.std() * np.sqrt(12)),
        caida_max_pct=caida,
        exposicion_pct=float(pesos.reindex(netos.index).sum(axis=1).mean() * 100),
    )


def desplazar(pesos: pd.DataFrame, rng: np.random.Generator, juntos: bool) -> pd.DataFrame:
    """La misma exposición, movida en el tiempo: cada columna gira un número
    de meses al azar (todas el mismo si la regla decide la cartera entera)."""
    n = len(pesos)
    margen = min(6, max(1, n // 4))

    def giro() -> int:
        return int(rng.integers(margen, n - margen + 1))

    k = giro()
    return pd.DataFrame({c: np.roll(pesos[c].to_numpy(), k if juntos else giro()) for c in pesos.columns},
                        index=pesos.index)


def _pesos(regla: str, parametro: int, cierres, diarios) -> pd.DataFrame:
    if regla == "tendencia":
        return pesos_tendencia(cierres, parametro)
    return pesos_volatilidad(cierres, diarios, parametro)


def _tramos(netos: pd.Series, pesos: pd.DataFrame, corte) -> tuple[Medida | None, Medida | None]:
    antes = netos[netos.index.to_timestamp() < corte]
    despues = netos[netos.index.to_timestamp() >= corte]
    return medir(antes, pesos), medir(despues, pesos)


def _fila(nombre: str, m: Medida | None) -> str:
    if m is None:
        return f"| {nombre} | — | — | — | — | — |"
    return (f"| {nombre} | {m.anual_pct:+.1f} % | {m.volatilidad_pct:.1f} % | {m.sharpe:.2f} | "
            f"−{m.caida_max_pct:.1f} % | {m.exposicion_pct:.0f} % |")


def informe(prueba: str, datos: dict, tiradas: int = 200, semilla: int = 0) -> tuple[str, bool]:
    activos, regla, fijado, rejilla = PRUEBAS[prueba]
    minimo = criterio.percentil_exigido(prueba)
    clases = {s: c for s, c in datos}
    aperturas, cierres, diarios = mensual(datos)
    meses = aperturas.index.intersection(cierres.index)[CALENTAMIENTO:]

    def correr(pesos: pd.DataFrame) -> tuple[pd.Series, pd.DataFrame]:
        p = pesos.reindex(meses)
        return simular(aperturas.reindex(meses), p, clases), p

    desde, hasta = meses[0].to_timestamp(), meses[-1].to_timestamp()
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO

    vara_n, vara_p = correr(pesos_mantener(cierres))
    prop_n, prop_p = correr(_pesos(regla, fijado, cierres, diarios))
    vara = _tramos(vara_n, vara_p, corte)
    prop = _tramos(prop_n, prop_p, corte)

    rng = np.random.default_rng(semilla)
    azar = []
    for _ in range(tiradas):
        p = desplazar(prop_p, rng, juntos=regla == "volatilidad")
        azar.append(_tramos(simular(aperturas.reindex(meses), p, clases), p, corte))

    lineas = [
        f"# {prueba}: la exposición de cada mes, contra comprar y mantener",
        "",
        f"{', '.join(s for s, _ in datos)}. Meses medidos: {meses[0]} → {meses[-2]}. "
        f"Validación desde {corte:%Y-%m}. Parámetro fijado: {fijado}.",
        "",
        f"Criterio: en validación, Sharpe por encima del {minimo} % de {tiradas} desplazamientos al azar "
        f"({criterio.previas(prueba)} ideas probadas antes) y del {criterio.PERCENTIL_DISENO_MIN} % en el diseño; "
        "Sharpe mayor que el de mantener en los dos tramos; en validación, caída máxima menor que la de "
        "mantener y rentabilidad positiva; y la mayoría de la rejilla con mejor Sharpe que mantener en validación.",
        "",
    ]
    percentiles = []
    for i, tramo in enumerate(("Diseño", "Validación")):
        az = np.array([t[i].sharpe for t in azar if t[i] is not None])
        pct = float((az < prop[i].sharpe).mean() * 100) if prop[i] is not None and len(az) else None
        percentiles.append(pct)
        lineas += [
            f"## {tramo}",
            "",
            "| | Anual | Volatilidad | Sharpe | Caída máxima | Exposición media |",
            "|---|---|---|---|---|---|",
            _fila("Mantener (vara)", vara[i]),
            _fila(f"**{prueba}**", prop[i]),
            "",
        ]
        if pct is not None:
            lineas += [f"Sharpe de los desplazamientos al azar: mediana {np.median(az):.2f}, "
                       f"p5–p95 {np.quantile(az, 0.05):.2f} – {np.quantile(az, 0.95):.2f}. "
                       f"La regla supera al **{pct:.0f} %**.", ""]

    lineas += ["## Rejilla (validación)", "",
               "| Parámetro | Anual | Volatilidad | Sharpe | Caída máxima | Exposición media |", "|---|---|---|---|---|---|"]
    mejores = 0
    for valor in rejilla:
        n, p = correr(_pesos(regla, valor, cierres, diarios))
        m = _tramos(n, p, corte)[1]
        lineas.append(_fila(str(valor), m))
        mejores += int(m is not None and vara[1] is not None and m.sharpe > vara[1].sharpe)
    lineas += ["", f"{mejores} de {len(rejilla)} con mejor Sharpe que mantener.", ""]

    # Por bloques: informativo, para ver si la diferencia es de una sola época.
    lineas += ["## Por bloques", "", "| Bloque | Mantener | Regla | Caída máx. mantener | Caída máx. regla |",
               "|---|---|---|---|---|"]
    paso = (hasta - desde) / criterio.VENTANAS
    for k in range(criterio.VENTANAS):
        ini, fin = desde + paso * k, desde + paso * (k + 1)
        t = vara_n.index.to_timestamp()
        sel = (t >= ini) & ((t < fin) | (k == criterio.VENTANAS - 1))
        mv, mp = medir(vara_n[sel], vara_p), medir(prop_n[sel], prop_p)
        if mv and mp:
            lineas.append(f"| {ini:%Y-%m} → {fin:%Y-%m} | {mv.anual_pct:+.1f} % | {mp.anual_pct:+.1f} % | "
                          f"−{mv.caida_max_pct:.1f} % | −{mp.caida_max_pct:.1f} % |")

    condiciones = [
        ("Sharpe en validación sobre el percentil exigido", percentiles[1] is not None and percentiles[1] >= minimo),
        ("Sharpe en el diseño sobre la mitad del azar",
         percentiles[0] is not None and percentiles[0] >= criterio.PERCENTIL_DISENO_MIN),
        ("Mejor Sharpe que mantener en los dos tramos",
         all(prop[i] and vara[i] and prop[i].sharpe > vara[i].sharpe for i in (0, 1))),
        ("Menos caída que mantener en validación",
         bool(prop[1] and vara[1] and prop[1].caida_max_pct < vara[1].caida_max_pct)),
        ("Rentabilidad positiva en validación", bool(prop[1] and prop[1].anual_pct > 0)),
        ("Mayoría de la rejilla", mejores * 2 > len(rejilla)),
    ]
    aprueba = all(ok for _, ok in condiciones)
    lineas += ["", "## Veredicto", ""] + [f"- {'✅' if ok else '❌'} {texto}" for texto, ok in condiciones]
    lineas += ["", "✅ **mejora a comprar y mantener**" if aprueba else "❌ **no mejora a comprar y mantener**", ""]
    return "\n".join(lineas), aprueba


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--prueba", required=True, choices=tuple(PRUEBAS))
    p.add_argument("--tiradas", type=int, default=200)
    p.add_argument("--salida", default="laboratorio_salida")
    a = p.parse_args()

    datos = {}
    for simbolo, clase in PRUEBAS[a.prueba][0]:
        df = cargar(simbolo, clase, "max")
        if df is None:
            print(f"Sin datos de {simbolo}: nada que medir.")
            return 1
        datos[(simbolo, clase)] = df
    texto, _ = informe(a.prueba, datos, a.tiradas)
    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / f"asignacion_{a.prueba}.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
