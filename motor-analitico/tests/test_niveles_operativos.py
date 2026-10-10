"""
Niveles operativos acotados en ATR y RSI extremo que no vota contra el
MACD (2026-10-10).

Medido en producción sobre 113 operaciones de los agentes: stops a
0,1–0,2 ATR del precio (R:R de ~200, el precio apoyado en el mínimo de 20
días), objetivos a ~8 ATR que ninguna operación alcanzó, y el 58 % de las
entradas con el RSI en sobreventa contado como alcista mientras el MACD
seguía bajista.
"""

from __future__ import annotations

import math

import numpy as np
import pandas as pd
import pytest

from indicadores.tecnicos import (
    SL_MAX_ATR,
    SL_MIN_ATR,
    TP_MAX_ATR,
    TP_MIN_ATR,
    Direccion,
    calcular_niveles_operativos,
    evaluar_confluencia,
)


# ---------------------------------------------------------------------------
# Niveles
# ---------------------------------------------------------------------------

def test_stop_pegado_al_soporte_se_aleja_a_un_atr():
    # El caso de producción: precio a 0,1 % del mínimo de 20 días.
    sl, tp = calcular_niveles_operativos(100.0, 99.9, 118.0, 2.0)
    assert sl == pytest.approx(100.0 - SL_MIN_ATR * 2.0)


def test_objetivo_lejano_se_acerca_a_dos_atr():
    sl, tp = calcular_niveles_operativos(100.0, 99.9, 118.0, 2.0)
    assert tp == pytest.approx(100.0 + TP_MAX_ATR * 2.0)


def test_el_rr_de_200_desaparece():
    # Antes: (118 - 100) / (100 - 99.9) = 180. Ahora, como mucho 2.
    sl, tp = calcular_niveles_operativos(100.0, 99.9, 118.0, 2.0)
    rr = (tp - 100.0) / (100.0 - sl)
    assert rr == pytest.approx(TP_MAX_ATR / SL_MIN_ATR)


def test_estructura_dentro_de_los_topes_se_respeta():
    # Soporte a 1,5 ATR y resistencia a 1,2 ATR: mandan los niveles reales.
    sl, tp = calcular_niveles_operativos(100.0, 97.0, 102.4, 2.0)
    assert sl == pytest.approx(97.0)
    assert tp == pytest.approx(102.4)


def test_soporte_muy_lejano_se_corta_a_dos_atr():
    sl, _ = calcular_niveles_operativos(100.0, 80.0, 104.0, 2.0)
    assert sl == pytest.approx(100.0 - SL_MAX_ATR * 2.0)


def test_el_objetivo_nunca_pasa_de_la_resistencia_si_queda_recorrido():
    for resistencia in (100.5 + 0.1 * i for i in range(40)):
        _, tp = calcular_niveles_operativos(100.0, 98.0, resistencia, 2.0)
        if resistencia - 100.0 >= TP_MIN_ATR * 2.0:
            assert tp <= resistencia + 1e-9


def test_precio_en_la_resistencia_da_un_rr_que_cualquier_filtro_descarta():
    sl, tp = calcular_niveles_operativos(100.0, 98.0, 100.0, 2.0)
    assert sl < 100.0 < tp
    assert (tp - 100.0) / (100.0 - sl) <= TP_MIN_ATR / SL_MIN_ATR


def test_siempre_encuadran_el_precio_y_el_stop_es_positivo():
    rng = np.random.default_rng(7)
    for _ in range(2000):
        precio = float(rng.uniform(0.01, 1000))
        atr = precio * float(rng.uniform(0.001, 0.6))
        soporte = precio * float(rng.uniform(0.3, 1.2))
        resistencia = precio * float(rng.uniform(0.8, 1.7))
        sl, tp = calcular_niveles_operativos(precio, soporte, resistencia, atr)
        assert 0 < sl < precio < tp
        assert (tp - precio) / (precio - sl) <= TP_MAX_ATR / SL_MIN_ATR + 1e-9


# ---------------------------------------------------------------------------
# RSI extremo frente al MACD
# ---------------------------------------------------------------------------

def _fila(rsi: float, macd_hist: float, sma50=110.0, sma200=100.0) -> pd.DataFrame:
    return pd.DataFrame([{
        "Close": 100.0, "SMA_50": sma50, "SMA_200": sma200,
        "RSI_14": rsi, "MACDh_12_26_9": macd_hist, "Volumen_relativo": 1.0,
    }])


def _votos(c):
    return {s.nombre: s.direccion for s in c.senales}


def test_sobreventa_con_macd_bajista_no_vota():
    # El patrón de 65 de las 113 entradas: medias alcistas, MACD bajista,
    # RSI < 30. Antes 2 contra 1 («media», alcista); ahora 1 contra 1.
    c = evaluar_confluencia(_fila(rsi=25.0, macd_hist=-0.5))
    assert _votos(c)["rsi"] == Direccion.NEUTRAL
    assert (c.indicadores_alcistas, c.indicadores_bajistas) == (1, 1)
    assert c.resumen == "Sin confluencia clara"


def test_sobreventa_con_macd_alcista_sigue_votando():
    c = evaluar_confluencia(_fila(rsi=25.0, macd_hist=0.5))
    assert _votos(c)["rsi"] == Direccion.ALCISTA
    assert (c.indicadores_alcistas, c.indicadores_bajistas) == (3, 0)
    assert c.fuerza == "alta"


def test_sobrecompra_con_macd_alcista_no_vota():
    c = evaluar_confluencia(_fila(rsi=78.0, macd_hist=0.5))
    assert _votos(c)["rsi"] == Direccion.NEUTRAL
    assert (c.indicadores_alcistas, c.indicadores_bajistas) == (2, 0)


def test_sobrecompra_con_macd_bajista_sigue_votando():
    c = evaluar_confluencia(_fila(rsi=78.0, macd_hist=-0.5))
    assert _votos(c)["rsi"] == Direccion.BAJISTA


def test_sin_macd_el_rsi_vota_como_siempre():
    c = evaluar_confluencia(_fila(rsi=25.0, macd_hist=math.nan))
    assert _votos(c)["rsi"] == Direccion.ALCISTA
    assert "macd" not in _votos(c)


def test_el_orden_del_detalle_no_cambia():
    c = evaluar_confluencia(_fila(rsi=25.0, macd_hist=-0.5))
    assert [s.nombre for s in c.senales] == ["cruce_medias", "rsi", "macd"]
