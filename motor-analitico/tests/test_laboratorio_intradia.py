"""
Modo de 1 hora del laboratorio (doc fase-3/10): el rebote tras una caída
brusca, su referencia al azar y las medidas por mes con velas horarias.
Sin red: series sintéticas.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio import metricas  # noqa: E402
from laboratorio.intradia import AzarRebote, ReboteCaida, informe  # noqa: E402
from laboratorio.motor import simular  # noqa: E402

SIN_SPREAD = lambda precio: 0.0  # noqa: E731


def _horas(cierres, rango=0.5):
    idx = pd.date_range("2025-01-01", periods=len(cierres), freq="h")
    c = np.asarray(cierres, dtype=float)
    o = np.concatenate([[c[0]], c[:-1]])
    return pd.DataFrame({"Open": o, "High": np.maximum(o, c) + rango, "Low": np.minimum(o, c) - rango,
                         "Close": c, "Volume": 1e6}, index=idx)


def _con_caida(n=200, en=120, caida=12.0):
    """100 plano con una caída de `caida` $ en tres horas a partir de `en`."""
    cierres = np.full(n, 100.0)
    for i, paso in enumerate((caida / 3, caida / 3, caida / 3)):
        cierres[en + i:] -= paso
    return _horas(cierres)


def test_la_caida_es_causal_y_dispara_al_cierre_de_la_hora():
    df = _con_caida()
    e = ReboteCaida(caida_atr=4.0, atr_n=24)
    p = e.preparar(df)
    señales = [t for t in range(len(p)) if e.entrada(p, t) is not None]
    assert señales and señales[0] >= 120
    # Truncar el histórico no cambia la columna (causal).
    corta = e.preparar(df.iloc[:125])
    assert np.allclose(corta["CAIDA_ATR"].dropna(), p["CAIDA_ATR"].iloc[:125].dropna())


def test_sale_por_tiempo_a_las_horas_fijadas():
    df = _con_caida()
    ops = simular(df, ReboteCaida(caida_atr=4.0, atr_n=24, stop_atr=50, objetivo_atr=50, horas=6), SIN_SPREAD)
    assert ops
    assert ops[0].motivo == "regla" and ops[0].dias == 6
    assert ops[0].fecha_entrada - ops[0].fecha_senal == pd.Timedelta(hours=1)


def test_el_objetivo_cierra_el_rebote():
    cierres = np.full(200, 100.0)
    cierres[120:] -= 12
    cierres[124:] += 8            # rebota con fuerza
    df = _horas(cierres)
    ops = simular(df, ReboteCaida(caida_atr=4.0, atr_n=24, stop_atr=2, objetivo_atr=1, horas=24), SIN_SPREAD)
    assert any(o.motivo == "tp" and o.r > 0 for o in ops)


def test_el_azar_usa_las_mismas_salidas_y_es_determinista():
    df = _horas(100 + np.cumsum(np.random.default_rng(1).normal(0, 0.3, 600)))
    a = simular(df, AzarRebote(probabilidad=0.05, semilla=3, atr_n=24, horas=6), SIN_SPREAD)
    b = simular(df, AzarRebote(probabilidad=0.05, semilla=3, atr_n=24, horas=6), SIN_SPREAD)
    c = simular(df, AzarRebote(probabilidad=0.05, semilla=4, atr_n=24, horas=6), SIN_SPREAD)
    assert a and [o.fecha_entrada for o in a] == [o.fecha_entrada for o in b]
    assert [o.fecha_entrada for o in a] != [o.fecha_entrada for o in c]
    assert all(o.dias <= 6 for o in a)


def test_el_mes_en_velas_de_1_hora():
    df = _horas(np.linspace(100, 110, 300))
    ops = simular(df, AzarRebote(probabilidad=0.05, semilla=0, atr_n=24, horas=6), SIN_SPREAD)
    diario, horario = metricas.medir(ops), metricas.medir(ops, barras_mes=720)
    assert horario.mes_pct > diario.mes_pct > 0


def test_el_informe_elige_en_diseno_y_compara_con_el_azar():
    rng = np.random.default_rng(5)
    datos = {}
    for i in range(3):
        cierres = 100 + np.cumsum(rng.normal(0, 0.4, 3000))
        for en in range(200, 3000, 60):           # caídas frecuentes para tener operaciones
            cierres[en:] -= 6
        datos[(f"x{i}", "cripto")] = _horas(cierres - cierres.min() + 50)
    texto = informe("rebote_caida", datos, "cripto", semillas=3)
    assert "Rejilla en diseño" in texto and "Veredicto" in texto
