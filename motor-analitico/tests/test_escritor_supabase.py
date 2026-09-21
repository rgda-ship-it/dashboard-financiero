"""
Pruebas del adaptador de salida hacia PostgreSQL.

Ninguna toca la red ni Supabase: se prueban las funciones puras que
traducen los objetos del motor a filas de base de datos. Es el mismo
criterio de `test_contrato_scan.py`, que sustituye el conector por un
doble y verifica invariantes sobre series sintéticas.

Lo que se protege aquí es la costura más frágil de la Fase 2: que
`rango_real` llegue correcto a la tabla. Si esa columna se pierde o se
calcula mal, el ATR de cripto vuelve a inflarse un 16 % y con él sube el
apalancamiento recomendado — un fallo que no rompe nada de forma visible.
"""

import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from escritor_supabase import _num, fila_indicadores, fila_senal, filas_precios

# Valores que el CHECK de `precios_diarios.origen` admite. Si alguien
# añade un origen nuevo en el código y no en la migración, PostgREST
# rechaza el lote entero; este conjunto lo detecta antes.
ORIGENES_VALIDOS = {"yahoo", "coingecko_market_chart", "coingecko_ohlc"}


class DobleOHLCV:
    """Doble del dataclass DatosOHLCV que devuelven los dos conectores."""

    def __init__(self, datos, fuente):
        self.ticker = "TEST"
        self.datos = datos
        self.fuente = fuente


def _marco_acciones():
    """Como lo devuelve yfinance: siempre con máximo y mínimo reales."""
    indice = pd.date_range("2026-09-14", periods=3, freq="D")
    return pd.DataFrame(
        {
            "Open": [100.0, 101.0, 102.0],
            "High": [103.0, 104.0, 105.0],
            "Low": [99.0, 100.0, 101.0],
            "Close": [102.0, 103.0, 104.0],
            "Volume": [1000.0, 1100.0, 1200.0],
        },
        index=indice,
    )


def _marco_cripto():
    """Como lo devuelve `construir_velas_diarias`: las filas fuera del
    alcance de /ohlc llevan High y Low en NaN. No es un hueco de datos —
    es la afirmación de que de ese día se conoce el cierre pero NO el
    recorrido intradía."""
    indice = pd.date_range("2026-09-14", periods=4, freq="D")
    return pd.DataFrame(
        {
            "Open": [np.nan, 100.0, 101.0, 102.0],
            "High": [np.nan, np.nan, 105.0, 106.0],
            "Low": [np.nan, np.nan, 100.0, 101.0],
            "Close": [100.0, 101.0, 103.0, 104.0],
            "Volume": [500.0, 600.0, 700.0, 800.0],
        },
        index=indice,
    )


# ── _num ────────────────────────────────────────────────────────────────
def test_num_degrada_nan_e_infinito_a_none():
    assert _num(float("nan")) is None
    assert _num(float("inf")) is None
    assert _num(float("-inf")) is None
    assert _num(np.nan) is None
    assert _num(None) is None
    assert _num("no soy un numero") is None
    assert _num(3.5) == 3.5
    assert _num(0) == 0.0  # el cero es un valor, no una ausencia


# ── filas_precios ───────────────────────────────────────────────────────
def test_acciones_todas_las_velas_con_rango_real():
    filas = filas_precios(7, DobleOHLCV(_marco_acciones(), "yfinance"), "yfinance")
    assert len(filas) == 3
    assert all(f["rango_real"] is True for f in filas)
    assert all(f["origen"] == "yahoo" for f in filas)
    assert all(f["activo_id"] == 7 for f in filas)


def test_cripto_distingue_las_velas_reconstruidas_de_las_reales():
    """EL TEST CENTRAL DE ESTE FICHERO.

    De las 4 velas de cripto, 2 tienen máximo y mínimo reales (vienen de
    /ohlc a 4 h) y 2 no (solo cierre, de /market_chart). La columna
    `rango_real` tiene que separarlas una por una: no se deduce del
    proveedor, se deduce de la fila.
    """
    filas = filas_precios(9, DobleOHLCV(_marco_cripto(), "coingecko"), "coingecko")
    assert len(filas) == 4

    reales = [f for f in filas if f["rango_real"]]
    reconstruidas = [f for f in filas if not f["rango_real"]]

    assert len(reales) == 2, "deberían ser 2 velas con rango real"
    assert len(reconstruidas) == 2, "deberían ser 2 velas reconstruidas"

    # Y cada grupo declara su origen, que es lo que permite auditar de
    # qué llamada de CoinGecko salió cada dato meses después.
    assert all(f["origen"] == "coingecko_ohlc" for f in reales)
    assert all(f["origen"] == "coingecko_market_chart" for f in reconstruidas)

    # Las reconstruidas NO heredan el cierre como máximo/mínimo: eso daría
    # un rango verdadero de cero y hundiría el ATR.
    assert all(f["maximo"] is None and f["minimo"] is None for f in reconstruidas)


def test_una_vela_sin_cierre_se_descarta():
    """`cierre` es NOT NULL en la tabla y es la única columna que todos
    los indicadores leen. Una fila sin cierre no es una vela."""
    marco = _marco_acciones()
    marco.loc[marco.index[1], "Close"] = np.nan
    filas = filas_precios(1, DobleOHLCV(marco, "yfinance"), "yfinance")
    assert len(filas) == 2


def test_ninguna_fila_de_precios_contiene_nan():
    """Un NaN se serializa como el literal `NaN`, que no es JSON válido:
    PostgREST rechazaría el lote COMPLETO, no solo la fila afectada."""
    for marco, fuente in ((_marco_acciones(), "yfinance"), (_marco_cripto(), "coingecko")):
        for fila in filas_precios(1, DobleOHLCV(marco, fuente), fuente):
            for clave, valor in fila.items():
                if isinstance(valor, float):
                    assert math.isfinite(valor), f"{clave} llegó como {valor}"


def test_el_origen_siempre_es_un_valor_que_la_tabla_admite():
    for marco, fuente in ((_marco_acciones(), "yfinance"), (_marco_cripto(), "coingecko")):
        for fila in filas_precios(1, DobleOHLCV(marco, fuente), fuente):
            assert fila["origen"] in ORIGENES_VALIDOS


# ── fila_senal ──────────────────────────────────────────────────────────
ESCANEO_OPERABLE = {
    "ticker": "IBM",
    "precio_actual": 100.0,
    "direccion": "alcista",
    "sesgo_operativo": "largo",
    "fuerza": "alta",
    "indicadores_alcistas": 4,
    "indicadores_bajistas": 1,
    "resumen_confluencia": "Confluencia alcista (4/5)",
    "senales": [{"nombre": "rsi", "direccion": "alcista", "detalle": "RSI 62"}],
    "operable": True,
    "atr_pct": 2.1,
    "leverage_tope": 5.0,
    "leverage_recomendado": 5.0,
    "leverage_referencia_volatilidad": 3.0,
    "leverage_motivo": "volatilidad baja, confluencia alta",
    "soporte": 92.0,
    "resistencia": 118.0,
    "sl": 92.0,
    "tp": 118.0,
    "niveles_origen": "estructura",
}


def test_senal_operable_lleva_los_tres_campos():
    fila = fila_senal(3, ESCANEO_OPERABLE, "abc1234")
    assert fila["operable"] is True
    assert fila["leverage_recomendado"] == 5.0
    assert fila["sl"] == 92.0
    assert fila["tp"] == 118.0
    assert fila["version_motor"] == "abc1234"


def test_senal_no_operable_anula_los_tres_campos_aunque_lleguen_con_valor():
    """Defensa en profundidad del contrato.

    El motor ya garantiza la coherencia, y el CHECK
    `senales_contrato_operable` la vuelve a exigir en la base de datos.
    Esta función es la tercera red: si algún día un payload llegara con
    `operable: false` y un `tp` con valor, aquí se anula en vez de
    provocar el rechazo del lote entero.
    """
    escaneo = dict(ESCANEO_OPERABLE, operable=False)
    fila = fila_senal(3, escaneo, "abc1234")
    assert fila["operable"] is False
    assert fila["leverage_recomendado"] is None
    assert fila["sl"] is None
    assert fila["tp"] is None
    # Los niveles técnicos SÍ se conservan: son direccionalmente neutros
    # y se emiten siempre (regla protegida nº2).
    assert fila["soporte"] == 92.0
    assert fila["resistencia"] == 118.0


def test_senal_con_volatilidad_ausente_no_propaga_nan():
    escaneo = dict(
        ESCANEO_OPERABLE,
        operable=False,
        atr_pct=float("nan"),
        leverage_recomendado=None,
        sl=None,
        tp=None,
    )
    fila = fila_senal(3, escaneo, "abc1234")
    assert fila["atr_pct"] is None
    assert fila["leverage_referencia_volatilidad"] == 3.0


# ── fila_indicadores ────────────────────────────────────────────────────
def test_indicadores_localiza_las_columnas_del_macd_por_prefijo():
    """Las columnas del MACD llevan los periodos en el nombre, y el sufijo
    depende de los parámetros con que pandas-ta las genere. `tecnicos.py`
    ya las busca por prefijo; aquí se comprueba que `MACD_` no capture
    por error a `MACDh_`, que es el error obvio al hacerlo con startswith.
    """
    indice = pd.date_range("2026-09-14", periods=2, freq="D")
    df = pd.DataFrame(
        {
            "SMA_50": [10.0, 11.0],
            "SMA_200": [9.0, 9.5],
            "RSI_14": [55.0, 62.0],
            "MACD_12_26_9": [1.0, 1.5],
            "MACDh_12_26_9": [0.2, 0.3],
            "MACDs_12_26_9": [0.8, 1.2],
            "ATR_14": [2.0, 2.2],
        },
        index=indice,
    )
    fila = fila_indicadores(5, df, "abc1234")
    assert fila["macd"] == 1.5
    assert fila["macd_hist"] == 0.3
    assert fila["macd_signal"] == 1.2
    assert fila["atr_14"] == 2.2
    assert fila["fecha"] == "2026-09-15"


def test_indicadores_sin_columnas_de_macd_devuelve_nulos_sin_romper():
    indice = pd.date_range("2026-09-14", periods=1, freq="D")
    df = pd.DataFrame({"SMA_50": [10.0], "ATR_14": [1.0]}, index=indice)
    fila = fila_indicadores(5, df, "abc1234")
    assert fila["macd"] is None
    assert fila["rsi_14"] is None
    assert fila["atr_14"] == 1.0


def test_indicadores_con_marco_vacio_devuelve_none():
    assert fila_indicadores(5, pd.DataFrame(), "abc1234") is None
    assert fila_indicadores(5, None, "abc1234") is None


if __name__ == "__main__":
    tests = [
        test_num_degrada_nan_e_infinito_a_none,
        test_acciones_todas_las_velas_con_rango_real,
        test_cripto_distingue_las_velas_reconstruidas_de_las_reales,
        test_una_vela_sin_cierre_se_descarta,
        test_ninguna_fila_de_precios_contiene_nan,
        test_el_origen_siempre_es_un_valor_que_la_tabla_admite,
        test_senal_operable_lleva_los_tres_campos,
        test_senal_no_operable_anula_los_tres_campos_aunque_lleguen_con_valor,
        test_senal_con_volatilidad_ausente_no_propaga_nan,
        test_indicadores_localiza_las_columnas_del_macd_por_prefijo,
        test_indicadores_sin_columnas_de_macd_devuelve_nulos_sin_romper,
        test_indicadores_con_marco_vacio_devuelve_none,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
