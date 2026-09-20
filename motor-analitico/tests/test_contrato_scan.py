import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pandas as pd

import servicio_interno

# El tope se fija aquí para que el contrato no dependa del .env de la
# máquina: LEVERAGE_HARD_CAP_FASE1 es configurable y este test verifica la
# forma del payload, no la configuración local.
servicio_interno.LEVERAGE_TOPE_FASE1 = 5.0


class DatosSinteticos:
    """Mismo contrato mínimo que devuelven los conectores: un `.datos`
    con el DataFrame OHLCV. Evita tocar Yahoo/CoinGecko en los tests."""

    def __init__(self, df):
        self.datos = df


def _df_de_cierres(cierres):
    # Sin columna Volume, como los DataFrames de cripto: así el indicador
    # de volumen no vota y los conteos quedan bajo control.
    return pd.DataFrame(
        [{"Open": c, "High": c * 1.01, "Low": c * 0.99, "Close": c} for c in cierres]
    )


def _serie(n, deriva, amplitud, base):
    """Serie oscilante con deriva: la deriva decide el cruce de medias y la
    fase de la oscilación decide el signo del histograma MACD, dejando el
    RSI en su banda neutra (30-70). Con eso se fuerza cada combinación de
    conteos sin inventar indicadores."""
    return [base + deriva * i + amplitud * math.sin(i / 8.0) for i in range(n)]


# 246 velas con deriva alcista: cruce de medias alcista + MACD alcista.
DF_LARGO = _df_de_cierres(_serie(246, 0.15, 8.0, 100.0))
# 244 velas: mismo cruce alcista, pero el MACD todavía no ha girado.
DF_NEUTRAL = _df_de_cierres(_serie(244, 0.15, 8.0, 100.0))
# Reflejo exacto del caso largo: cruce bajista + MACD bajista.
DF_CORTO = _df_de_cierres(_serie(246, -0.15, -8.0, 200.0))


def _df_ventana_plana():
    """Las últimas 20 velas sin ningún recorrido: soporte == resistencia,
    así que la ventana de estructura no describe nada y debe entrar el
    fallback por ATR."""
    df = _df_de_cierres(_serie(246, 0.15, 8.0, 100.0))
    plano = float(df["Close"].iloc[-21])
    for columna in ("Open", "High", "Low", "Close"):
        df.loc[df.index[-20:], columna] = plano
    return df


def escanear_con(df) -> dict:
    original = servicio_interno._obtener_ohlcv
    try:
        servicio_interno._obtener_ohlcv = lambda ticker: DatosSinteticos(df)
        return servicio_interno._escanear_ticker("TEST")
    finally:
        servicio_interno._obtener_ohlcv = original


def test_confluencia_bajista_no_emite_numeros_operables():
    d = escanear_con(DF_CORTO)
    assert d["indicadores_alcistas"] == 0 and d["indicadores_bajistas"] == 2, d["senales"]
    assert d["sesgo_operativo"] == "corto"
    assert d["operable"] is False
    assert d["leverage_recomendado"] is None
    assert d["sl"] is None
    assert d["tp"] is None
    # El dato técnico sigue siendo válido en cualquier dirección: lo único
    # que pierde es el rol operativo.
    assert d["soporte"] is not None
    assert d["resistencia"] is not None


def test_confluencia_alcista_asigna_roles_a_los_niveles():
    d = escanear_con(DF_LARGO)
    assert d["indicadores_alcistas"] == 2 and d["indicadores_bajistas"] == 0, d["senales"]
    assert d["sesgo_operativo"] == "largo"
    assert d["operable"] is True
    assert d["sl"] == d["soporte"]
    assert d["tp"] == d["resistencia"]


def test_empate_es_sin_sesgo_y_no_dimensiona():
    d = escanear_con(DF_NEUTRAL)
    assert d["indicadores_alcistas"] == 1 and d["indicadores_bajistas"] == 1, d["senales"]
    assert d["sesgo_operativo"] == "sin_sesgo"
    assert d["direccion"] == "neutral"
    assert d["leverage_recomendado"] is None


def test_el_tope_siempre_viaja_en_el_payload():
    # El tope es una constante del sistema, no una lectura de mercado: la
    # UI dibuja el remache de latón en TODAS las filas, también en las que
    # no llevan número operable.
    for df in (DF_CORTO, DF_LARGO, DF_NEUTRAL):
        d = escanear_con(df)
        assert d["leverage_tope"] == 5.0


def test_la_referencia_de_volatilidad_siempre_esta_presente():
    for df in (DF_CORTO, DF_LARGO, DF_NEUTRAL):
        d = escanear_con(df)
        assert d["leverage_referencia_volatilidad"] is not None


def test_ventana_sin_estructura_cae_al_fallback_por_atr():
    d = escanear_con(_df_ventana_plana())
    assert d["niveles_origen"] == "atr"
    assert d["resistencia"] > d["soporte"]


def test_el_payload_es_json_valido_y_sin_nan():
    for df in (DF_CORTO, DF_LARGO, DF_NEUTRAL, _df_ventana_plana()):
        crudo = json.dumps(escanear_con(df))
        # Un NaN se serializa como el literal `NaN`, que JSON.parse()
        # rechaza — y tumbaría el escáner completo, no solo esta fila.
        assert "NaN" not in crudo
        assert "Infinity" not in crudo


def test_invariantes_del_contrato_en_cada_item_sin_error():
    sesgo_esperado = {"alcista": "largo", "bajista": "corto", "neutral": "sin_sesgo"}
    for df in (DF_CORTO, DF_LARGO, DF_NEUTRAL, _df_ventana_plana()):
        d = escanear_con(df)
        assert "error" not in d
        assert d["operable"] == (d["leverage_recomendado"] is not None)
        assert d["operable"] == (d["sl"] is not None)
        assert d["operable"] == (d["tp"] is not None)
        assert d["leverage_recomendado"] is None or (
            1.0 <= d["leverage_recomendado"] <= d["leverage_tope"]
        )
        assert 1.0 <= d["leverage_referencia_volatilidad"] <= d["leverage_tope"]
        assert d["soporte"] is not None and d["resistencia"] is not None
        assert d["resistencia"] > d["soporte"]
        assert d["sl"] is None or (d["sl"] == d["soporte"] and d["tp"] == d["resistencia"])
        assert d["sesgo_operativo"] == sesgo_esperado[d["direccion"]]
        assert d["niveles_origen"] in ("estructura", "atr")


if __name__ == "__main__":
    tests = [
        test_confluencia_bajista_no_emite_numeros_operables,
        test_confluencia_alcista_asigna_roles_a_los_niveles,
        test_empate_es_sin_sesgo_y_no_dimensiona,
        test_el_tope_siempre_viaja_en_el_payload,
        test_la_referencia_de_volatilidad_siempre_esta_presente,
        test_ventana_sin_estructura_cae_al_fallback_por_atr,
        test_el_payload_es_json_valido_y_sin_nan,
        test_invariantes_del_contrato_en_cada_item_sin_error,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
