"""
Fase 3, I2 (doc fase-3/01 §5): el laboratorio reproduce las salidas de los
agentes con metas: toma parcial, deterioro en dos lecturas, stop que sigue
y condiciones de entrada del catálogo que comparte con SQL (0046).
"""

import sys
from pathlib import Path
from types import SimpleNamespace

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio.agentes import como_texto, parametros_de_agente  # noqa: E402
from laboratorio.ejecutar import crear  # noqa: E402
from laboratorio.estrategias import CONDICIONES, Agente, cumple  # noqa: E402
from laboratorio.motor import Entrada, Parcial, Posicion, simular  # noqa: E402
from tests.test_laboratorio import SIN_SPREAD, _df, _serie_aleatoria  # noqa: E402


class ConParcial:
    """Entra una vez al cierre del día 0 con stop 90, objetivo 120 y toma
    parcial de la mitad al 50 % del recorrido (110)."""
    nombre = "prueba"

    def __init__(self, mover_stop=False):
        self.parcial = Parcial(0.5, 0.5, mover_stop)

    def preparar(self, df):
        return df

    def entrada(self, df, t):
        return Entrada(90, 120, parcial=self.parcial) if t == 0 else None

    def actualizar(self, df, t, pos):
        return pos.sl, False


# ---------------------------------------------------------------------------
# Toma parcial en el motor
# ---------------------------------------------------------------------------

def test_la_parcial_vende_al_nivel_y_el_resto_sale_por_el_objetivo():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 111, 99, 108), (108, 121, 107, 118)])
    [op] = simular(df, ConParcial(), SIN_SPREAD)
    assert op.parcial and op.motivo == "tp"
    assert op.precio_salida == pytest.approx(0.5 * 110 + 0.5 * 120)
    assert op.r == pytest.approx(1.5)


def test_con_mover_stop_el_resto_sale_en_la_entrada():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 111, 99, 108), (108, 108, 95, 96)])
    [op] = simular(df, ConParcial(mover_stop=True), SIN_SPREAD)
    assert op.motivo == "sl"
    assert op.precio_salida == pytest.approx(0.5 * 110 + 0.5 * 100 * 0.9995)


def test_sin_mover_stop_el_resto_llega_al_stop_original():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 111, 99, 108), (108, 108, 89, 90)])
    [op] = simular(df, ConParcial(), SIN_SPREAD)
    assert op.precio_salida == pytest.approx(0.5 * 110 + 0.5 * 90)


def test_si_el_dia_toca_el_stop_no_hay_parcial():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 112, 89, 100)])
    [op] = simular(df, ConParcial(), SIN_SPREAD)
    assert op.motivo == "sl" and not op.parcial and op.precio_salida == 90


def test_parcial_y_objetivo_el_mismo_dia():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 125, 99, 121)])
    [op] = simular(df, ConParcial(), SIN_SPREAD)
    assert op.parcial and op.motivo == "tp"
    assert op.precio_salida == pytest.approx(115)


# ---------------------------------------------------------------------------
# Estrategia `agente`
# ---------------------------------------------------------------------------

def _conf(alcistas, bajistas, fuerza):
    return SimpleNamespace(indicadores_alcistas=alcistas, indicadores_bajistas=bajistas, fuerza=fuerza)


def _pos(fuerza="media"):
    return Posicion(entrada=100, sl=95, sl_inicial=95, tp=110, fecha_senal=pd.Timestamp("2025-01-01"),
                    fecha_entrada=pd.Timestamp("2025-01-02"), indice_entrada=1, mejor_cierre=100,
                    datos={"fuerza_entrada": fuerza})


def test_el_deterioro_pide_dos_lecturas_seguidas(monkeypatch):
    agente = Agente(deterioro=1)
    lecturas = iter([_conf(1, 2, "media"), _conf(3, 0, "alta"), _conf(1, 2, "media"), _conf(2, 2, "baja")])
    monkeypatch.setattr(agente, "_confluencia", lambda df, t: next(lecturas))
    df = pd.DataFrame({"ATR_14": [1.0] * 5})
    pos = _pos()
    salidas = [agente.actualizar(df, t, pos)[1] for t in range(4)]
    assert salidas == [False, False, False, True]


def test_menos_fuerza_que_al_entrar_es_deterioro(monkeypatch):
    agente = Agente(deterioro=1)
    monkeypatch.setattr(agente, "_confluencia", lambda df, t: _conf(2, 0, "media"))
    df = pd.DataFrame({"ATR_14": [1.0] * 3})
    pos = _pos("alta")
    assert [agente.actualizar(df, t, pos)[1] for t in range(2)] == [False, True]


def test_sin_deterioro_nunca_sale_por_regla():
    ops = simular(_serie_aleatoria(), Agente(), lambda p: p * 0.001)
    assert ops and all(o.motivo in ("sl", "tp", "hueco", "fin") for o in ops)


def test_el_stop_que_sigue_nunca_baja(monkeypatch):
    agente = Agente(sigue_atr=2)
    df = pd.DataFrame({"ATR_14": [1.0, 1.0]})
    pos = _pos()
    pos.mejor_cierre = 104
    assert agente.actualizar(df, 0, pos)[0] == 102
    pos.sl, pos.mejor_cierre = 103, 104
    assert agente.actualizar(df, 1, pos)[0] == 103


def test_la_banda_de_volatilidad_filtra_entradas():
    df = _serie_aleatoria()
    todas = simular(df, Agente(), SIN_SPREAD)
    ninguna = simular(df, Agente(atr_max=0.01), SIN_SPREAD)
    assert todas and not ninguna


def test_una_condicion_anade_entradas_sin_quitar_ninguna():
    df = _serie_aleatoria()
    base = Agente().preparar(df)
    con = Agente(condicion="sobre_sma50")
    sin = Agente()
    dias_sin = {t for t in range(200, len(df) - 1) if sin.entrada(base, t)}
    dias_con = {t for t in range(200, len(df) - 1) if con.entrada(base, t)}
    assert dias_sin <= dias_con and len(dias_con) > len(dias_sin)


def test_el_catalogo_de_condiciones():
    fila = pd.Series({"Close": 105, "SMA_50": 100, "SMA_200": 110, "MACD_HIST": 0.5, "RSI_14": 60,
                      "MAX_20": 104, "Volumen_relativo": 2.0})
    assert cumple(fila, "sobre_sma50+macd_positivo+rsi_50_70+ruptura_20+volumen_alto")
    assert not cumple(fila, "sobre_sma200") and not cumple(fila, "cruce_medias")
    assert not cumple(fila.drop("RSI_14").reindex(fila.index), "rsi_bajo_35")
    assert not cumple(fila, "")
    with pytest.raises(KeyError):
        cumple(fila, "inventada")
    # El mismo catálogo que fn_condiciones_dia (0046).
    assert set(CONDICIONES) == {"sobre_sma50", "sobre_sma200", "cruce_medias", "macd_positivo",
                                "rsi_50_70", "rsi_bajo_35", "ruptura_20", "volumen_alto"}


def test_la_fuerza_minima_decide_que_confluencia_entra(monkeypatch):
    df = _serie_aleatoria()
    prep = Agente().preparar(df)
    dias = range(200, len(df) - 1)
    def entradas(f):
        return {t for t in dias if Agente(fuerza_minima=f).entrada(prep, t)}
    solo_alta, media, baja = entradas(3), entradas(2), entradas(1)
    assert solo_alta <= media <= baja and len(baja) > len(solo_alta)


def test_crear_admite_texto_para_la_condicion():
    a = crear("agente", "condicion=macd_positivo+ruptura_20,deterioro=1,top=4")
    assert a.condicion == "macd_positivo+ruptura_20" and a.deterioro


# ---------------------------------------------------------------------------
# De la estrategia de producción a los parámetros
# ---------------------------------------------------------------------------

PRUDENCIA = {"rr_minimo": 1.5, "atr_pct_max": 3.0, "atr_pct_min": None, "fuerzas_admitidas": ["media", "alta"],
             "tp_parcial": {"fraccion": 0.5, "recorrido": 0.5, "mover_stop": True},
             "por_clase": {"cripto": {"atr_pct_max": 12}}}
AUDACIA = {"rr_minimo": 1.2, "atr_pct_min": 2.3, "atr_pct_max": None, "tp_parcial": None,
           "salida_deterioro": False, "por_clase": {"cripto": {"atr_pct_min": 4}}}


def test_parametros_de_prudencia_y_audacia():
    assert parametros_de_agente(PRUDENCIA, "accion") == {
        "rr_minimo": 1.5, "atr_min": 0.0, "atr_max": 3.0, "deterioro": 1, "fuerza_minima": 2,
        "parcial_recorrido": 0.5, "parcial_fraccion": 0.5, "parcial_mover": 1}
    assert parametros_de_agente(PRUDENCIA, "cripto")["atr_max"] == 12
    assert parametros_de_agente(AUDACIA, "accion") == {
        "rr_minimo": 1.2, "atr_min": 2.3, "atr_max": 0.0, "deterioro": 0}
    assert parametros_de_agente(AUDACIA, "cripto")["atr_min"] == 4


def test_los_parametros_llegan_enteros_a_la_estrategia():
    a = crear("agente", como_texto(parametros_de_agente(PRUDENCIA, "accion")))
    assert a.rr_minimo == 1.5 and a.atr_max == 3.0 and a.deterioro
    assert a.parcial == Parcial(0.5, 0.5, True)


def test_el_precio_minimo_y_el_objetivo_frente_al_spread_filtran_entradas():
    from laboratorio.datos import con_spread

    df = con_spread(_serie_aleatoria(), "X", "accion")
    dias = range(200, len(df) - 1)

    def entradas(agente, datos=df):
        p = agente.preparar(datos)
        return {t for t in dias if agente.entrada(p, t)}

    todas = entradas(Agente())
    assert todas and not entradas(Agente(precio_min=1e9))
    # Con un spread de 0,03 $ en acciones de ~100 $, 10 spreads son 0,30 $:
    # casi todos los objetivos pasan; 10.000 spreads (300 $), ninguno.
    assert entradas(Agente(objetivo_min_spread=10)) <= todas
    assert not entradas(Agente(objetivo_min_spread=10_000))
    # Sin la columna SPREAD el filtro no actúa.
    assert entradas(Agente(objetivo_min_spread=10_000), _serie_aleatoria()) == todas
