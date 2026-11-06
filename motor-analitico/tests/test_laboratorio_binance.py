"""
Ficheros de Binance y las dos ideas de microestructura en cripto (doc
fase-3/15): flujo de órdenes y desequilibrio del libro. Sin red.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio import binance  # noqa: E402
from laboratorio.intradia import AzarFlujo, AzarLibro, FlujoOrdenes, LibroCripto  # noqa: E402
from laboratorio.motor import simular  # noqa: E402

SIN_SPREAD = lambda precio: 0.0  # noqa: E731


def test_el_par_de_binance_sale_del_ticker_de_yahoo():
    assert binance.par("bitcoin") == "BTCUSDT"
    assert binance.par("avalanche-2") == "AVAXUSDT"
    assert binance.par("no-existe") is None


def test_las_velas_aceptan_milisegundos_microsegundos_y_cabecera():
    fila = lambda t: [t, 1, 2, 0.5, 1.5, 10, t + 1, 15, 3, 6, 9, 0]  # noqa: E731
    crudo = pd.DataFrame([["open_time"] + [""] * 11,
                          fila(1704067200000),               # 2024-01-01 00:00, en ms
                          fila(1735689600000000),            # 2025-01-01 00:00, en µs
                          fila(1704067200000)])              # duplicada
    df = binance.leer_velas(crudo)
    assert list(df.index) == [pd.Timestamp("2024-01-01"), pd.Timestamp("2025-01-01")]
    assert df["Taker"].iloc[0] == 6 and df["Volume"].iloc[0] == 10


def test_el_libro_se_resume_por_hora_con_el_desequilibrio_de_cada_banda():
    filas = []
    for ts, compra in (("2024-01-01 10:00:10", 300.0), ("2024-01-01 10:30:10", 100.0), ("2024-01-01 11:00:10", 100.0)):
        for b in (1, 5):
            filas += [(ts, -b, 1.0, compra * b), (ts, b, 1.0, 100.0 * b)]
    out = binance.resumir_libro(pd.DataFrame(filas, columns=["timestamp", "percentage", "depth", "notional"]))
    # 10:00 → la media de (300−100)/400 = 0,5 y 0; 11:00 → 0.
    assert list(out.index) == [pd.Timestamp("2024-01-01 10:00"), pd.Timestamp("2024-01-01 11:00")]
    assert abs(out.loc["2024-01-01 10:00", "OBI_1"] - 0.25) < 1e-12
    assert abs(out.loc["2024-01-01 10:00", "OBI_5"] - 0.25) < 1e-12
    assert out.loc["2024-01-01 11:00", "OBI_1"] == 0


def _horas(n=2000, semilla=3):
    rng = np.random.default_rng(semilla)
    c = 100 + np.cumsum(rng.normal(0, 0.3, n))
    o = np.concatenate([[c[0]], c[:-1]])
    idx = pd.date_range("2024-01-01", periods=n, freq="h")
    vol = np.full(n, 100.0)
    taker = rng.uniform(40, 60, n)
    return pd.DataFrame({"Open": o, "High": np.maximum(o, c) + 0.2, "Low": np.minimum(o, c) - 0.2, "Close": c,
                         "Volume": vol, "Taker": taker}, index=idx)


def test_el_flujo_compra_en_su_decil_alto_y_es_causal():
    df = _horas()
    df.loc[df.index[1500], "Taker"] = 99.0           # una hora de compras agresivas
    pre = FlujoOrdenes.precalcular(df)
    assert pre["FLUJO_ALTO_4"].iloc[:360].sum() == 0  # sin 15 días de historia, no hay umbral
    assert pre["FLUJO_ALTO_4"].iloc[1500]
    corta = FlujoOrdenes.precalcular(df.iloc[:1501])
    assert (corta["FLUJO_ALTO_4"] == pre["FLUJO_ALTO_4"].iloc[:1501]).all()
    ops = simular(df, FlujoOrdenes(ventana=4, horas=8, stop_atr=50), SIN_SPREAD)
    assert ops and all(pre.loc[op.fecha_senal, "FLUJO_ALTO_4"] for op in ops)
    assert all(op.motivo == "regla" and op.dias == 8 for op in ops)
    assert all(op.fecha_entrada - op.fecha_senal == pd.Timedelta(hours=1) for op in ops)


def test_el_libro_compra_en_su_decil_alto_y_el_azar_solo_con_libro():
    df = _horas()
    rng = np.random.default_rng(1)
    df["OBI_1"] = rng.normal(0, 0.1, len(df))
    df["OBI_5"] = rng.normal(0, 0.1, len(df))
    df.loc[df.index[:200], ["OBI_1", "OBI_5"]] = np.nan
    pre = LibroCripto.precalcular(df)
    ops = simular(df, LibroCripto(banda=1, horas=8), SIN_SPREAD)
    assert ops and all(pre.loc[op.fecha_senal, "OBI_ALTO_1"] for op in ops)
    azar = simular(df, AzarLibro(probabilidad=0.2, semilla=2, banda=5, horas=8), SIN_SPREAD)
    assert azar and all(op.fecha_senal >= df.index[200] for op in azar)
    azar_f = simular(df, AzarFlujo(probabilidad=0.2, semilla=2, ventana=24, horas=8), SIN_SPREAD)
    assert azar_f and all(op.fecha_senal >= df.index[23] for op in azar_f)
