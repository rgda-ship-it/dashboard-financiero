"""
Doc fase-3/09 §4.2: no entrar antes de resultados. El precio da un salto
el día que reacciona a unos resultados, y ningún stop lo protege.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.datos import con_resultados  # noqa: E402
from laboratorio.estrategias import CONDICIONES, FILTROS_LABORATORIO, Agente, cumple  # noqa: E402
from tests.test_laboratorio import _serie_aleatoria  # noqa: E402


def test_cuenta_las_sesiones_hasta_la_proxima_reaccion():
    idx = pd.bdate_range("2024-01-01", periods=10)          # lun 1 … vie 12
    df = pd.DataFrame({"Close": np.arange(10.0)}, index=idx)
    # Una reacción en sábado cuenta desde el lunes siguiente (posición 5).
    p = con_resultados(df, pd.DatetimeIndex(["2024-01-06", "2024-01-11"]))
    assert list(p["SESIONES_A_RESULTADOS"].iloc[:5]) == [5, 4, 3, 2, 1]
    # El mismo día de la reacción ya no cuenta: la siguiente es la del 11.
    assert list(p["SESIONES_A_RESULTADOS"].iloc[5:8]) == [3, 2, 1]
    assert np.isnan(p["SESIONES_A_RESULTADOS"].iloc[8:]).all()
    assert np.isnan(con_resultados(df, None)["SESIONES_A_RESULTADOS"]).all()


def test_sin_resultados_bloquea_si_caen_dentro_de_la_ventana():
    todos = {**CONDICIONES, **FILTROS_LABORATORIO}
    assert not cumple(pd.Series({"SESIONES_A_RESULTADOS": 1.0}), "sin_resultados_3", todos)
    assert not cumple(pd.Series({"SESIONES_A_RESULTADOS": 3.0}), "sin_resultados_3", todos)
    assert cumple(pd.Series({"SESIONES_A_RESULTADOS": 4.0}), "sin_resultados_3", todos)
    assert cumple(pd.Series({"SESIONES_A_RESULTADOS": np.nan}), "sin_resultados_10", todos)
    # Cripto y ETF (sin columna): el filtro no existe.
    assert cumple(pd.Series({"Close": 10.0}), "sin_resultados_10", todos)


def test_el_filtro_solo_quita_las_entradas_previas_a_resultados():
    df = _serie_aleatoria()
    reaccion = pd.DatetimeIndex(df.index[210::60])
    df = con_resultados(df, reaccion)
    dias = range(200, len(df) - 1)
    cerca = {t for t in dias if 1 <= df["SESIONES_A_RESULTADOS"].iloc[t] <= 5}
    base, filtrado = Agente(), Agente(filtro="sin_resultados_5")
    pb, pf = base.preparar(df), filtrado.preparar(df)
    todas = {t for t in dias if base.entrada(pb, t)}
    assert {t for t in dias if filtrado.entrada(pf, t)} == todas - cerca
