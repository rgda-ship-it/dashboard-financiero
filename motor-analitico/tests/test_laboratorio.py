"""
Laboratorio de estrategias (doc 06): reglas de ejecución, causalidad,
medidas y veredicto. Sin red: series sintéticas.
"""

import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from laboratorio import metricas  # noqa: E402
from laboratorio.estrategias import ESTRATEGIAS  # noqa: E402
from laboratorio.motor import Entrada, Operacion, simular  # noqa: E402

SIN_SPREAD = lambda precio: 0.0  # noqa: E731


def _df(filas):
    idx = pd.date_range("2025-01-01", periods=len(filas), freq="D")
    return pd.DataFrame(filas, columns=["Open", "High", "Low", "Close"], index=idx).assign(Volume=1e6)


class UnaVez:
    """Entra una sola vez, al cierre del día `dia`, con los niveles dados."""
    nombre = "prueba"

    def __init__(self, dia, sl, tp=None, salir_tras=None):
        self.dia, self.sl, self.tp, self.salir_tras = dia, sl, tp, salir_tras

    def preparar(self, df):
        return df

    def entrada(self, df, t):
        return Entrada(self.sl, self.tp) if t == self.dia else None

    def actualizar(self, df, t, pos):
        salir = self.salir_tras is not None and t - pos.indice_entrada + 1 >= self.salir_tras
        return pos.sl, salir


# ---------------------------------------------------------------------------
# Reglas de ejecución
# ---------------------------------------------------------------------------

def test_entra_en_la_apertura_siguiente_con_medio_spread_y_sale_al_objetivo():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (101, 106, 100, 105)])
    [op] = simular(df, UnaVez(0, sl=95, tp=104), lambda p: 0.2)
    assert op.precio_entrada == pytest.approx(100.1)
    assert op.motivo == "tp" and op.precio_salida == 104


def test_si_un_dia_toca_stop_y_objetivo_gana_el_stop():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 110, 90, 100)])
    [op] = simular(df, UnaVez(0, sl=95, tp=104), SIN_SPREAD)
    assert op.motivo == "sl" and op.precio_salida == 95


def test_un_hueco_mas_alla_del_stop_sale_a_la_apertura():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (90, 91, 88, 89)])
    [op] = simular(df, UnaVez(0, sl=95, tp=110), SIN_SPREAD)
    assert op.motivo == "hueco" and op.precio_salida == 90
    assert op.r == pytest.approx(-2.0)


def test_el_stop_se_compara_con_el_precio_de_venta():
    # Mínimo 95,05: el intermedio no toca 95, pero la venta (con 0,2 de
    # spread) sí: 94,95.
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 101, 95.05, 100)])
    [op] = simular(df, UnaVez(0, sl=95, tp=110), lambda p: 0.2)
    assert op.motivo == "sl"


def test_la_salida_por_regla_se_ejecuta_en_la_apertura_siguiente():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (102, 103, 101, 102), (103, 104, 102, 103)])
    [op] = simular(df, UnaVez(0, sl=90, salir_tras=1), SIN_SPREAD)
    assert op.motivo == "regla" and op.precio_salida == 102 and op.fecha_salida == df.index[2]


def test_si_ya_abre_por_debajo_del_stop_no_hay_operacion():
    df = _df([(100, 101, 99, 100), (94, 95, 93, 94), (94, 95, 93, 94)])
    assert simular(df, UnaVez(0, sl=95, tp=110), SIN_SPREAD) == []


def test_lo_abierto_al_final_se_cierra_al_ultimo_cierre():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (101, 102, 100, 101)])
    [op] = simular(df, UnaVez(0, sl=90), SIN_SPREAD)
    assert op.motivo == "fin" and op.precio_salida == 101


# ---------------------------------------------------------------------------
# Causalidad: ninguna estrategia mira el futuro
# ---------------------------------------------------------------------------

def _serie_aleatoria(n=700, semilla=3):
    rng = np.random.default_rng(semilla)
    cierres = 100 * np.exp(np.cumsum(rng.normal(0.0004, 0.02, n)))
    aperturas = np.r_[cierres[0], cierres[:-1]] * np.exp(rng.normal(0, 0.004, n))
    altos = np.maximum(aperturas, cierres) * np.exp(np.abs(rng.normal(0, 0.008, n)))
    bajos = np.minimum(aperturas, cierres) * np.exp(-np.abs(rng.normal(0, 0.008, n)))
    df = _df(list(zip(aperturas, altos, bajos, cierres)))
    df["Volume"] = rng.uniform(5e5, 2e6, n)
    return df


@pytest.mark.parametrize("nombre", sorted(ESTRATEGIAS))
def test_las_senales_no_cambian_si_se_quita_el_futuro(nombre):
    df = _serie_aleatoria()
    estrategia = ESTRATEGIAS[nombre]()
    completo = estrategia.preparar(df)
    for t in range(220, len(df) - 1, 37):
        truncado = estrategia.preparar(df.iloc[: t + 1])
        a, b = estrategia.entrada(completo, t), estrategia.entrada(truncado, t)
        assert (a is None) == (b is None), (nombre, t)
        if a is not None:
            assert a.sl == pytest.approx(b.sl) and (a.tp is None) == (b.tp is None), (nombre, t)


@pytest.mark.parametrize("nombre", sorted(ESTRATEGIAS))
def test_cada_estrategia_opera_de_principio_a_fin(nombre):
    ops = simular(_serie_aleatoria(), ESTRATEGIAS[nombre](), lambda p: p * 0.001)
    assert all(o.sl_inicial < o.precio_entrada for o in ops)
    assert all(o.fecha_entrada > o.fecha_senal and o.fecha_salida >= o.fecha_entrada for o in ops)


# ---------------------------------------------------------------------------
# Medidas y veredicto
# ---------------------------------------------------------------------------

def _op(r, dia=0, dias=1):
    fecha = pd.Timestamp("2025-01-01") + pd.Timedelta(days=dia)
    return Operacion("X", "accion", "p", fecha, fecha, fecha + pd.Timedelta(days=dias),
                     100.0, 99.0, None, 100.0 + r, "sl", dias)


def test_las_medidas_de_una_muestra_conocida():
    m = metricas.medir([_op(2), _op(-1), _op(2), _op(-1)])
    assert m.operaciones == 4 and m.aciertos_pct == 50
    assert m.expectativa_r == pytest.approx(0.5)
    assert m.factor_beneficio == pytest.approx(2.0)
    assert m.ganancia_media_r == pytest.approx(2) and m.perdida_media_r == pytest.approx(-1)
    assert m.caida_maxima_pct == pytest.approx(1.0, abs=0.01)


def test_veredicto_exige_muestra_ventaja_y_confianza():
    pocas = metricas.medir([_op(1, i) for i in range(10)])
    assert metricas.veredicto(None, pocas)[0] is False

    rng = np.random.default_rng(1)
    con_ventaja = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([2.0, -1.0], 200, p=[0.5, 0.5]))])
    ok, motivos = metricas.veredicto(con_ventaja, con_ventaja)
    assert ok, motivos

    sin_ventaja = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([1.0, -1.0], 200))])
    ok, motivos = metricas.veredicto(None, sin_ventaja)
    assert not ok and motivos


def test_veredicto_detecta_el_desplome_frente_al_diseno():
    rng = np.random.default_rng(2)
    diseno = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([3.0, -1.0], 200))])
    validacion = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([1.3, -1.0], 400, p=[0.5, 0.5]))])
    ok, motivos = metricas.veredicto(diseno, validacion)
    assert not ok and any("tercio" in m for m in motivos)
