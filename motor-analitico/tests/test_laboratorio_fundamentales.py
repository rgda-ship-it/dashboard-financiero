"""
Doc fase-3/09 §4.2: calidad y valor con SEC EDGAR. Cada día se usa solo lo
que se había presentado hasta el día anterior, sin reexpresiones.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.datos import con_fundamentales, fundamentales_edgar  # noqa: E402
from laboratorio.estrategias import CONDICIONES, FILTROS_LABORATORIO, cumple  # noqa: E402


def _flujo(start, end, val, filed):
    return {"start": start, "end": end, "val": val, "filed": filed}


def _instante(end, val, filed):
    return {"end": end, "val": val, "filed": filed}


def _hechos(pasivos=True):
    beneficio = [
        _flujo("2023-01-01", "2023-03-31", 10, "2023-05-01"),
        _flujo("2023-04-01", "2023-06-30", 20, "2023-08-01"),
        _flujo("2023-07-01", "2023-09-30", 30, "2023-11-01"),
        _flujo("2023-01-01", "2023-12-31", 100, "2024-02-15"),   # el cuarto sale de aquí: 40
        _flujo("2023-01-01", "2023-03-31", 999, "2024-05-01"),   # reexpresión: no se sabía
        _flujo("2024-01-01", "2024-03-31", 15, "2024-05-01"),
    ]
    gaap = {
        "NetIncomeLoss": {"units": {"USD": beneficio}},
        "Assets": {"units": {"USD": [_instante("2023-12-31", 1000, "2024-02-15")]}},
        "StockholdersEquity": {"units": {"USD": [_instante("2023-12-31", 400, "2024-02-15")]}},
    }
    if pasivos:
        gaap["Liabilities"] = {"units": {"USD": [_instante("2023-12-31", 600, "2024-02-15")]}}
    else:
        gaap["LiabilitiesAndStockholdersEquity"] = {
            "units": {"USD": [_instante("2023-12-31", 1000, "2024-02-15")]}}
    dei = {"EntityCommonStockSharesOutstanding": {
        "units": {"shares": [_instante("2024-02-01", 10, "2024-02-15")]}}}
    return {"facts": {"us-gaap": gaap, "dei": dei}}


def _velas(cierre=100.0):
    idx = pd.bdate_range("2024-02-01", "2024-06-28")
    return pd.DataFrame({"Close": np.full(len(idx), cierre)}, index=idx)


def test_doce_meses_con_lo_conocido_y_sin_reexpresiones():
    f = fundamentales_edgar(_hechos())
    df = con_fundamentales(_velas(), f)
    # El día de la presentación aún no se sabe; al siguiente, sí.
    assert np.isnan(df.loc["2024-02-15", "ROA"])
    d = df.loc["2024-02-16"]
    assert (d["ROA"], d["ROE"], d["DEUDA"], d["BENEFICIO_PRECIO"]) == (10.0, 25.0, 60.0, 10.0)
    # Q2 + Q3 + Q4 derivado + Q1 nuevo; el 999 reexpresado no entra.
    assert df.loc["2024-05-02", "ROA"] == 10.5
    assert df.loc["2024-05-01", "ROA"] == 10.0


def test_bancos_sin_pasivo_total_y_empresas_sin_us_gaap():
    df = con_fundamentales(_velas(), fundamentales_edgar(_hechos(pasivos=False)))
    assert df.loc["2024-02-16", "DEUDA"] == 60.0
    assert fundamentales_edgar({"facts": {"ifrs-full": {}}}) is None
    vacio = con_fundamentales(_velas(), None)
    assert vacio[["ROA", "ROE", "DEUDA", "BENEFICIO_PRECIO"]].isna().all().all()


def test_desdoblamientos_y_valores_absurdos():
    f = fundamentales_edgar(_hechos())
    # Un 2×1 el 1-3, posterior al recuento: el precio de Yahoo ya viene a
    # la mitad, y las acciones del informe se duplican.
    splits = pd.Series([2.0], index=pd.DatetimeIndex(["2024-03-01"]))
    df = con_fundamentales(_velas(50.0), f, splits=splits)
    assert df.loc["2024-02-16", "BENEFICIO_PRECIO"] == 10.0
    # Acciones en otra base (BRK-B): sin dato antes que un dato falso.
    absurdo = con_fundamentales(_velas(0.5), f)
    assert np.isnan(absurdo.loc["2024-02-16", "BENEFICIO_PRECIO"])


def test_filtros_de_calidad_y_valor():
    todos = {**CONDICIONES, **FILTROS_LABORATORIO}
    buena = pd.Series({"ROA": 12.0, "ROE": 20.0, "DEUDA": 40.0, "BENEFICIO_PRECIO": 6.0})
    mala = pd.Series({"ROA": -1.0, "ROE": 5.0, "DEUDA": 80.0, "BENEFICIO_PRECIO": 2.0})
    for filtro in ("calidad_roa_0", "calidad_roa_5", "calidad_roa_10", "calidad_roe_15",
                   "deuda_60", "valor_bp_3", "valor_bp_5", "calidad_y_valor"):
        assert cumple(buena, filtro, todos) and not cumple(mala, filtro, todos)
        # Sin datos (cripto, ETF, extranjeras): el filtro no existe.
        assert cumple(pd.Series({"Close": 10.0}), filtro, todos)
        assert cumple(pd.Series({"ROA": np.nan, "DEUDA": np.nan}), filtro, todos)
