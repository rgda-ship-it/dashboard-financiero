"""
Doc fase-3/06: lo que faltaba del ADX. Filtros del laboratorio (+DI/−DI,
pendiente, tope de 40), la ruptura con ADX y las estrategias del documento
del dueño (Santo Grial y giro ADX + RSI), con su referencia al azar.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.estrategias import (  # noqa: E402
    CONDICIONES, FILTROS_LABORATORIO, Agente, AzarGiro, AzarGrial, GiroAdxRsi, SantoGrial, Tendencia, cumple,
)
from tests.test_laboratorio import _serie_aleatoria  # noqa: E402


def test_los_filtros_del_laboratorio_no_entran_en_el_catalogo_de_sql():
    assert not set(FILTROS_LABORATORIO) & set(CONDICIONES)
    fila = pd.Series({"DMP_14": 25.0, "DMN_14": 15.0, "ADX_14": 35.0, "ADX_14_HACE_3": 30.0})
    todos = {**CONDICIONES, **FILTROS_LABORATORIO}
    assert cumple(fila, "di_alcista+adx_subiendo+adx_no_agotado+adx_20_40", todos)
    agotado = fila.copy(); agotado["ADX_14"] = 45.0
    assert not cumple(agotado, "adx_no_agotado", todos) and not cumple(agotado, "adx_20_40", todos)


def test_el_filtro_de_direccion_solo_quita_entradas():
    df = _serie_aleatoria()
    prep = Agente().preparar(df)
    assert {"DMP_14", "DMN_14", "ADX_14_HACE_3"} <= set(prep.columns)
    dias = range(200, len(df) - 1)
    todas = {t for t in dias if Agente().entrada(prep, t)}
    alcistas = {t for t in dias if Agente(filtro="di_alcista").entrada(prep, t)}
    assert alcistas <= todas
    assert all(prep["DMP_14"].iloc[t] > prep["DMN_14"].iloc[t] for t in alcistas)


def test_la_ruptura_con_adx_es_un_subconjunto_de_la_ruptura():
    df = _serie_aleatoria()
    base, con_adx = Tendencia(), Tendencia(adx_min=20)
    pb, pa = base.preparar(df), con_adx.preparar(df)
    dias = range(220, len(df) - 1)
    rupturas = {t for t in dias if base.entrada(pb, t)}
    filtradas = {t for t in dias if con_adx.entrada(pa, t)}
    assert filtradas <= rupturas
    assert all(pa["ADX_14"].iloc[t] > 20 and pa["ADX_14"].iloc[t] > pa["ADX_14"].iloc[t - 3] for t in filtradas)


def _tendencia_con_retroceso():
    """Subida limpia (ADX alto, +DI sobre −DI), un retroceso hasta la EMA de
    20 y la reanudación."""
    subida = np.linspace(100, 160, 80)
    retroceso = np.linspace(160, 148, 6)
    reanuda = np.linspace(149, 170, 15)
    cierres = np.r_[subida, retroceso, reanuda]
    idx = pd.date_range("2024-01-01", periods=len(cierres), freq="D")
    return pd.DataFrame({"Open": cierres - 0.2, "High": cierres + 1.0, "Low": cierres - 1.0,
                         "Close": cierres, "Volume": 1e6}, index=idx)


def test_el_santo_grial_compra_el_primer_toque_de_la_media_tras_romper_su_maximo():
    e = SantoGrial()
    df = e.preparar(_tendencia_con_retroceso())
    toques = np.flatnonzero(df["TOQUE"].to_numpy())
    assert len(toques) == 1, toques
    k = toques[0]
    assert df["ADX_14"].iloc[k] > 30 and df["DMP_14"].iloc[k] > df["DMN_14"].iloc[k]
    assert df["Low"].iloc[k] <= df["EMA_20"].iloc[k]
    entradas = [t for t in range(60, len(df)) if e.entrada(df, t)]
    assert entradas and entradas[0] > k
    t = entradas[0]
    ent = e.entrada(df, t)
    # La orden baja con cada vela: se dispara al superar el máximo de la anterior.
    assert df["Close"].iloc[t] > df["High"].iloc[t - 1]
    assert ent.sl < df["Low"].iloc[k: t].min() and ent.tp == df["MAX_IMPULSO"].iloc[k] > df["Close"].iloc[t]
    # Un solo toque por episodio: no vuelve a entrar.
    assert entradas == [t]


def test_las_referencias_al_azar_respetan_su_contexto():
    df = _serie_aleatoria()
    grial = AzarGrial(probabilidad=0.5)
    pg = grial.preparar(df)
    assert all(pg["CONTEXTO"].iloc[t] for t in range(60, len(df)) if grial.entrada(pg, t))
    giro = AzarGiro(probabilidad=0.5)
    pr = giro.preparar(df)
    assert all(pr["RSI_14"].iloc[t] < 35 for t in range(30, len(df)) if giro.entrada(pr, t))


def test_el_giro_exige_climax_y_que_el_adx_deje_de_subir():
    df = _serie_aleatoria()
    e = GiroAdxRsi(adx_min=25)
    p = e.preparar(df)
    for t in range(30, len(df)):
        ent = e.entrada(p, t)
        if ent:
            assert p["CLIMAX"].iloc[t] >= 1 and p["ADX_14"].iloc[t] < p["ADX_14"].iloc[t - 1]
            assert p["Close"].iloc[t] > p["High"].iloc[t - 1]
            assert abs((ent.tp - p["Close"].iloc[t]) - 2 * (p["Close"].iloc[t] - ent.sl)) < 1e-9
