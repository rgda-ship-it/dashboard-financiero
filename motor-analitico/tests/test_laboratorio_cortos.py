"""
Cortos en el laboratorio (doc fase-3/02): las reglas de ejecución del motor
al revés, la financiación del corto y las estrategias bajistas.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.datos import financiacion_de  # noqa: E402
from laboratorio.estrategias import AzarCorto, ConfluenciaCorta, TendenciaCorta  # noqa: E402
from laboratorio.motor import Entrada, Parcial, simular  # noqa: E402
from tests.test_laboratorio import SIN_SPREAD, _df  # noqa: E402


class CortoUnaVez:
    """Vende en corto una vez, al cierre del día 0."""
    nombre = "prueba"

    def __init__(self, sl=105, tp=None, parcial=None, sigue=None):
        self.sl, self.tp, self.parcial, self.sigue = sl, tp, parcial, sigue

    def preparar(self, df):
        return df

    def entrada(self, df, t):
        return Entrada(self.sl, self.tp, parcial=self.parcial, lado="corto") if t == 0 else None

    def actualizar(self, df, t, pos):
        if self.sigue is None:
            return pos.sl, False
        return pos.mejor_cierre + self.sigue, False


def test_vende_al_precio_de_venta_y_recompra_en_el_objetivo():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (99, 100, 94, 95)])
    [op] = simular(df, CortoUnaVez(sl=105, tp=95), lambda p: 0.2)
    assert op.lado == "corto" and op.precio_entrada == pytest.approx(99.9)
    assert op.motivo == "tp" and op.precio_salida == 95
    assert op.r > 0 and op.riesgo == pytest.approx(105 - 99.9)


def test_el_stop_se_compara_con_el_precio_de_compra_y_gana_el_empate():
    # Máximo 104,95: el intermedio no toca 105, la compra (spread 0,2) sí.
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 104.95, 90, 100)])
    [op] = simular(df, CortoUnaVez(sl=105, tp=95), lambda p: 0.2)
    assert op.motivo == "sl" and op.precio_salida == 105


def test_un_hueco_por_encima_del_stop_sale_a_la_apertura():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (110, 112, 109, 111)])
    [op] = simular(df, CortoUnaVez(sl=105), SIN_SPREAD)
    assert op.motivo == "hueco" and op.precio_salida == 110
    assert op.r == pytest.approx(-2.0)


def test_si_ya_abre_por_encima_del_stop_no_hay_corto():
    df = _df([(100, 101, 99, 100), (106, 107, 105, 106), (106, 107, 105, 106)])
    assert simular(df, CortoUnaVez(sl=105), SIN_SPREAD) == []


def test_la_financiacion_se_cobra_por_dia_natural():
    # Entra el 2 de enero a 100 y sale por fin el 11: 9 días al 36,5 % anual
    # son 0,9 por unidad, que suben la recompra.
    filas = [(100, 101, 99, 100)] * 11
    df = _df(filas)
    [sin] = simular(df, CortoUnaVez(sl=110), SIN_SPREAD)
    [con] = simular(df, CortoUnaVez(sl=110), SIN_SPREAD, financiacion_corto_pct=36.5)
    assert sin.precio_salida == 100 and con.precio_salida == pytest.approx(100.9)
    assert con.r == pytest.approx(-0.09) and con.coste_r == pytest.approx(0.09)


def test_la_financiacion_no_toca_los_largos():
    class LargoUnaVez(CortoUnaVez):
        def entrada(self, df, t):
            return Entrada(90) if t == 0 else None

    df = _df([(100, 101, 99, 100)] * 11)
    [op] = simular(df, LargoUnaVez(), SIN_SPREAD, financiacion_corto_pct=36.5)
    assert op.precio_salida == 100


def test_el_stop_del_corto_solo_baja():
    # El mejor cierre baja a 94 y el stop le sigue a 3: 97. Después sube el
    # precio y el stop no se mueve.
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (96, 97, 93, 94), (95, 96, 94, 95), (96, 98, 95, 97.5)])
    [op] = simular(df, CortoUnaVez(sl=105, sigue=3), SIN_SPREAD)
    assert op.motivo == "sl" and op.precio_salida == 97


def test_parcial_en_corto():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (99, 100, 89, 92), (92, 93, 79, 80)])
    [op] = simular(df, CortoUnaVez(sl=110, tp=80, parcial=Parcial(0.5, 0.5)), SIN_SPREAD)
    assert op.parcial and op.motivo == "tp"
    assert op.precio_salida == pytest.approx(0.5 * 90 + 0.5 * 80)
    assert op.r == pytest.approx(1.5)


def _bajista(n=700, semilla=11):
    rng = np.random.default_rng(semilla)
    cierres = 100 * np.exp(np.cumsum(rng.normal(-0.0015, 0.02, n)))
    aperturas = np.r_[cierres[0], cierres[:-1]] * np.exp(rng.normal(0, 0.004, n))
    altos = np.maximum(aperturas, cierres) * np.exp(np.abs(rng.normal(0, 0.008, n)))
    bajos = np.minimum(aperturas, cierres) * np.exp(-np.abs(rng.normal(0, 0.008, n)))
    return _df(list(zip(aperturas, altos, bajos, cierres)))


@pytest.mark.parametrize("estrategia", [TendenciaCorta(), AzarCorto(probabilidad=0.1), ConfluenciaCorta()])
def test_las_estrategias_bajistas_venden_en_corto_en_un_mercado_que_cae(estrategia):
    ops = simular(_bajista(), estrategia, lambda p: p * 0.001, financiacion_corto_pct=8)
    assert ops and all(o.lado == "corto" and o.riesgo > 0 for o in ops)
    assert all(o.sl_inicial > o.precio_entrada for o in ops)


def test_la_confluencia_corta_pone_el_objetivo_debajo_y_el_stop_encima():
    df = _bajista()
    e = ConfluenciaCorta()
    p = e.preparar(df)
    entradas = [(t, e.entrada(p, t)) for t in range(200, len(df) - 1)]
    entradas = [(t, x) for t, x in entradas if x]
    assert entradas
    for t, x in entradas:
        cierre = p["Close"].iloc[t]
        assert x.tp < cierre < x.sl and (cierre - x.tp) / (x.sl - cierre) >= e.rr_minimo - 1e-9


def test_el_azar_corto_cambia_con_la_semilla():
    df = _bajista()
    a = [o.fecha_entrada for o in simular(df, AzarCorto(probabilidad=0.1, semilla=1), SIN_SPREAD)]
    b = [o.fecha_entrada for o in simular(df, AzarCorto(probabilidad=0.1, semilla=2), SIN_SPREAD)]
    assert a and b and a != b


def test_la_financiacion_supuesta_por_clase():
    assert financiacion_de("accion") == 8.0 and financiacion_de("cripto") == 15.0
    assert financiacion_de("otra") == 0.0


def test_el_corto_mide_en_r_igual_que_el_largo():
    # Mismo recorrido, lados opuestos: el mismo resultado en R.
    df_baja = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 100.5, 89, 90)])
    df_sube = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 111, 99.5, 110)])

    class Largo(CortoUnaVez):
        def entrada(self, df, t):
            return Entrada(95, 110) if t == 0 else None

    [corto] = simular(df_baja, CortoUnaVez(sl=105, tp=90), SIN_SPREAD)
    [largo] = simular(df_sube, Largo(), SIN_SPREAD)
    assert corto.r == pytest.approx(largo.r) == pytest.approx(2.0)
    assert corto.pct == pytest.approx(largo.pct)
    assert isinstance(corto.fecha_salida, pd.Timestamp)
