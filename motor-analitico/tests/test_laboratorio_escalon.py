"""
Entrada escalonada (doc fase-3/03, idea del dueño): media posición a la
entrada y la otra media en el stop previsto, con un stop nuevo debajo.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.estrategias import Agente  # noqa: E402
from laboratorio.motor import Entrada, simular  # noqa: E402
from tests.test_laboratorio import SIN_SPREAD, _df, _serie_aleatoria  # noqa: E402


class Escalonada:
    """Entra al cierre del día 0: segunda mitad a 95, stop a 90, objetivo 110."""
    nombre = "prueba"

    def preparar(self, df):
        return df

    def entrada(self, df, t):
        return Entrada(sl=90, tp=110, escalon=95) if t == 0 else None

    def actualizar(self, df, t, pos):
        return pos.sl, False


# Pérdida máxima por unidad: media de 100 a 90 (10) y media de 95 a 90 (5): 7,5.
MAXIMA = 0.5 * 10 + 0.5 * 5


def test_compra_la_segunda_mitad_en_el_escalon_y_sale_en_el_objetivo():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (99, 100, 94, 96), (96, 111, 95, 110)])
    [op] = simular(df, Escalonada(), SIN_SPREAD)
    assert op.escalonada == "completa" and op.motivo == "tp"
    assert op.r == pytest.approx((0.5 * 10 + 0.5 * 15) / MAXIMA)


def test_sin_segunda_mitad_es_media_posicion():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (101, 111, 99, 110)])
    [op] = simular(df, Escalonada(), SIN_SPREAD)
    assert op.escalonada == "media" and op.r == pytest.approx(0.5 * 10 / MAXIMA)


def test_con_las_dos_mitades_el_stop_es_una_r_entera():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (99, 100, 94, 95), (94, 95, 89, 90)])
    [op] = simular(df, Escalonada(), SIN_SPREAD)
    assert op.escalonada == "completa" and op.motivo == "sl" and op.r == pytest.approx(-1.0)


def test_si_abre_por_debajo_del_escalon_compra_en_la_apertura():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (93, 99, 92, 98), (98, 111, 97, 110)])
    [op] = simular(df, Escalonada(), SIN_SPREAD)
    assert op.escalonada == "completa"
    assert op.r == pytest.approx((0.5 * 10 + 0.5 * 17) / MAXIMA)


def test_el_mismo_dia_compra_y_salta_el_stop():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (99, 100, 88, 89)])
    [op] = simular(df, Escalonada(), SIN_SPREAD)
    assert op.escalonada == "completa" and op.motivo == "sl" and op.r == pytest.approx(-1.0)


def test_el_agente_escalona_siempre_o_solo_bajo_la_media_de_200():
    df = _serie_aleatoria()
    p = Agente().preparar(df)
    dias = range(200, len(df) - 1)
    siempre = [Agente(escalonar=1).entrada(p, t) for t in dias]
    solo_bajista = [(t, Agente(escalonar=2).entrada(p, t)) for t in dias]
    base = [Agente().entrada(p, t) for t in dias]
    assert any(siempre) and all((a is None) == (b is None) for a, b in zip(siempre, base))
    for t, a, b in zip(dias, siempre, base):
        if a:
            cierre = p["Close"].iloc[t]
            assert a.escalon == b.sl and a.sl == pytest.approx(b.sl - (cierre - b.sl)) and a.tp == b.tp
    for t, e in solo_bajista:
        if e:
            bajo = p["Close"].iloc[t] < p["SMA_200"].iloc[t]
            assert (e.escalon is not None) == bajo
