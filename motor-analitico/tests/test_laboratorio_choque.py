"""
Doc fase-3/09 §4.1: freno por choque de mercado. Tras un desplome de
bitcoin (ese día o el anterior), no se abren posiciones de cripto.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.datos import con_mercado  # noqa: E402
from laboratorio.estrategias import CONDICIONES, FILTROS_LABORATORIO, Agente, Tendencia, cumple  # noqa: E402
from tests.test_laboratorio import _serie_aleatoria  # noqa: E402


def _mercado(df, caidas: dict[int, float]):
    """Un «bitcoin» plano salvo los días indicados, que caen ese %."""
    cierres = np.ones(len(df)) * 100.0
    for t, pct in caidas.items():
        cierres[t:] *= 1 + pct / 100
    return pd.DataFrame({"Close": cierres}, index=df.index)


def test_con_mercado_da_la_peor_variacion_de_ese_dia_y_el_anterior():
    df = _serie_aleatoria(n=50)
    p = con_mercado(df, _mercado(df, {10: -6.0}))
    assert round(p["MERCADO_RET"].iloc[10], 6) == -6.0
    assert round(p["MERCADO_PEOR_2"].iloc[10], 6) == -6.0
    assert round(p["MERCADO_PEOR_2"].iloc[11], 6) == -6.0
    assert p["MERCADO_PEOR_2"].iloc[12] == 0.0
    # Sin dato del mercado ese día: NaN, y el filtro no bloquea.
    hueco = con_mercado(df, _mercado(df, {}).iloc[20:])
    assert np.isnan(hueco["MERCADO_PEOR_2"].iloc[5])
    assert cumple(hueco.iloc[5], "sin_choque_5", FILTROS_LABORATORIO)


def test_sin_choque_bloquea_segun_el_umbral_y_sin_columna_no_actua():
    todos = {**CONDICIONES, **FILTROS_LABORATORIO}
    fila = pd.Series({"MERCADO_PEOR_2": -4.5})
    assert not cumple(fila, "sin_choque_3", todos) and not cumple(fila, "sin_choque_4", todos)
    assert cumple(fila, "sin_choque_5", todos) and cumple(fila, "sin_choque_7", todos)
    # Acciones (sin columna de mercado): el freno no existe.
    assert cumple(pd.Series({"Close": 10.0}), "sin_choque_3", todos)


def test_el_freno_solo_quita_las_entradas_de_los_dias_de_choque():
    df = _serie_aleatoria()
    caidas = {t: -8.0 for t in range(210, len(df), 15)}
    df = con_mercado(df, _mercado(df, caidas))
    dias = range(220, len(df) - 1)
    choque = {t for t in dias if df["MERCADO_PEOR_2"].iloc[t] <= -5}

    for base, frenada in ((Agente(), Agente(filtro="sin_choque_5")),
                          (Tendencia(), Tendencia(filtro="sin_choque_5"))):
        pb, pf = base.preparar(df), frenada.preparar(df)
        todas = {t for t in dias if base.entrada(pb, t)}
        quedan = {t for t in dias if frenada.entrada(pf, t)}
        assert quedan == todas - choque
