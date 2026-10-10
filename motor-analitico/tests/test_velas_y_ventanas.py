"""
Casos de prueba de la propuesta "velas y ventanas históricas coherentes"
(docs/propuesta-velas-ventanas.md §7).

Cubre las tres piezas del cambio: la reconstrucción de la vela diaria de
cripto a partir de las dos llamadas sin clave a CoinGecko, el ATR y el
soporte/resistencia calculados solo sobre velas con máximo y mínimo
reales, y la ventana histórica de acciones.

SIN RED y SIN pytest, como el resto de la suite: las respuestas de
CoinGecko se generan aquí como fixtures sintéticas y el conector se
prueba con dobles de `requests` y del reloj.
"""

import inspect
import json
import logging
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np
import pandas as pd
import requests

import servicio_interno
from conectores import coingecko
from conectores.coingecko import ConectorCriptoCoinGecko, construir_velas_diarias
from conectores.yahoo_finance import ConectorAccionesYahoo
from indicadores.tecnicos import (
    LONGITUD_ATR,
    VENTANA_SOPORTE_RESISTENCIA,
    ResultadoConfluencia,
    calcular_indicadores,
    calcular_soporte_resistencia,
    evaluar_confluencia,
    ta,
)
from riesgo.rotacion import mejor_oportunidad_del_escaneo
from riesgo.salud_posicion import PosicionCargada, calcular_diagnostico

# El tope se fija aquí por el mismo motivo que en test_contrato_scan.py:
# LEVERAGE_HARD_CAP_FASE1 es configurable por .env y estos casos verifican
# el cálculo, no la configuración de la máquina.
servicio_interno.LEVERAGE_TOPE_FASE1 = 5.0


# ---------------------------------------------------------------------------
# Fixtures sintéticas de las dos respuestas de CoinGecko
# ---------------------------------------------------------------------------

# Día de referencia. Fijo y no `hoy` para que los casos no cambien de
# resultado según cuándo se ejecuten.
DIA_HOY = pd.Timestamp("2026-09-20", tz="UTC")
PUNTOS_DIARIOS = 365
VELAS_4H = 180


def _ms(ts: pd.Timestamp) -> int:
    return int(ts.timestamp() * 1000)


def _nivel(i: float) -> float:
    """Serie de precios suave y determinista alrededor de 100."""
    return 100.0 + 0.05 * i + 3.0 * math.sin(i / 7.0)


def _market_chart_sintetico() -> dict:
    """365 puntos diarios a las 00:00 UTC más el punto vivo de hoy.

    Réplica de la forma real verificada contra la API: el punto de
    `D+1 00:00` es el CIERRE del día D, y el último punto es el precio
    vivo, con hora intradía.
    """
    precios, volumenes = [], []
    for i in range(PUNTOS_DIARIOS):
        # Del día -364 al día 0, todos a las 00:00: cierres de los días
        # -365 a -1.
        ts = _ms(DIA_HOY - pd.Timedelta(days=PUNTOS_DIARIOS - 1 - i))
        precios.append([ts, _nivel(i)])
        volumenes.append([ts, 1.0e9 * (1.0 + 0.1 * math.sin(i / 5.0))])

    vivo = _ms(DIA_HOY + pd.Timedelta(hours=9, minutes=22))
    precios.append([vivo, _nivel(PUNTOS_DIARIOS) + 1.5])
    volumenes.append([vivo, 1.23e9])
    return {"prices": precios, "total_volumes": volumenes}


def _ohlc_4h_sintetico(maximo_inyectado: tuple[pd.Timestamp, float] | None = None) -> list:
    """180 velas de 4 h, con la misma rejilla que devuelve CoinGecko.

    Verificado contra la API real: la ventana de 30 días arranca a media
    jornada (primer cierre a las 16:00 del día -30, es decir 3 velas para
    ese día, que por eso se descarta) y termina en la última vela ya
    cerrada de hoy.
    """
    primer_cierre = DIA_HOY - pd.Timedelta(days=30) + pd.Timedelta(hours=16)
    velas = []
    for k in range(VELAS_4H):
        cierre_ts = primer_cierre + pd.Timedelta(hours=4 * k)
        # Nivel aproximado del día al que pertenece la vela.
        i = PUNTOS_DIARIOS - 1 - (DIA_HOY - cierre_ts.normalize()).days
        nivel = _nivel(i)
        apertura = nivel
        maximo = nivel * 1.01
        minimo = nivel * 0.99
        cierre = nivel * 1.002
        if maximo_inyectado is not None and cierre_ts == maximo_inyectado[0]:
            maximo = maximo_inyectado[1]
        velas.append([_ms(cierre_ts), apertura, maximo, minimo, cierre])
    return velas


MC = _market_chart_sintetico()
OHLC = _ohlc_4h_sintetico()
DF_CRIPTO = construir_velas_diarias(MC, OHLC)


def _dia(ts_ms: int) -> pd.Timestamp:
    """Mismo criterio de cierre que el conector, para poder afirmar sobre
    el día de un punto sin reimplementar la regla al revés."""
    return coingecko._dia_utc_de_cierre(ts_ms)


# ---------------------------------------------------------------------------
# §7-1 a §7-6 — reconstrucción de la vela diaria
# ---------------------------------------------------------------------------

def test_01_forma_del_frame_reconstruido():
    df = DF_CRIPTO
    assert len(df) == 366, len(df)
    assert df.index.is_unique
    assert df.index.is_monotonic_increasing
    # Índice diario: todos los saltos de exactamente un día.
    saltos = set(df.index.to_series().diff().dropna().unique())
    assert saltos == {pd.Timedelta(days=1)}, saltos
    # La última fila es el día del punto vivo, no el del último cierre.
    assert df.index[-1] == DIA_HOY.tz_localize(None)


def test_02_close_es_el_punto_de_c1_del_dia_siguiente():
    df = DF_CRIPTO
    # Un punto cualquiera de la serie diaria, no el último.
    ts_ms, precio = MC["prices"][200]
    dia = _dia(ts_ms)
    assert df.loc[dia, "Close"] == precio
    # Y el último cierre es el precio vivo, no el del último día cerrado:
    # ese desfase de hasta 4 días es justo lo que corrige el cambio.
    assert df["Close"].iloc[-1] == MC["prices"][-1][1]


def test_03_volumen_presente_en_todas_las_filas():
    df = DF_CRIPTO
    assert df["Volume"].notna().all()
    ts_ms, volumen = MC["total_volumes"][200]
    assert df.loc[_dia(ts_ms), "Volume"] == volumen


def test_04_las_velas_de_4h_se_asignan_al_dia_que_cierran():
    # Una vela que cierra a D+1 00:00 es la ÚLTIMA de D, no la primera de
    # D+1: si la regla se invirtiera, el máximo se correría un día entero.
    dia = (DIA_HOY - pd.Timedelta(days=15)).tz_localize(None)
    cierre_frontera = DIA_HOY - pd.Timedelta(days=14)
    df = construir_velas_diarias(MC, _ohlc_4h_sintetico((cierre_frontera, 999.0)))
    assert df.loc[dia, "High"] == 999.0
    assert df.loc[dia + pd.Timedelta(days=1), "High"] != 999.0


def test_05_dias_sin_velas_de_4h_quedan_en_nan_sin_fabricar_nada():
    df = DF_CRIPTO
    # El día más antiguo de C2 llega con 3 velas (arranca a las 16:00):
    # incompleto, así que se descarta entero.
    dia_incompleto = (DIA_HOY - pd.Timedelta(days=30)).tz_localize(None)
    assert pd.isna(df.loc[dia_incompleto, "High"])
    assert pd.isna(df.loc[dia_incompleto, "Low"])
    assert int(df["High"].notna().sum()) == 30, int(df["High"].notna().sum())
    assert int(df["High"].isna().sum()) == 336, int(df["High"].isna().sum())
    assert int(df["Low"].notna().sum()) == 30


def test_06_las_velas_con_rango_real_son_coherentes():
    df = DF_CRIPTO
    validas = df.dropna(subset=["High", "Low"])
    assert len(validas) == 30
    for dia, fila in validas.iterrows():
        tope = max(fila["Open"], fila["Close"])
        suelo = min(fila["Open"], fila["Close"])
        assert fila["High"] >= tope, (dia, fila["High"], tope)
        assert fila["Low"] <= suelo, (dia, fila["Low"], suelo)
    # La vela viva tiene que contener el precio vivo: su Close viene de C1
    # y su rango de C2, dos series distintas.
    viva = df.iloc[-1]
    vivo = MC["prices"][-1][1]
    assert viva["High"] >= vivo >= viva["Low"]


# ---------------------------------------------------------------------------
# §7-7 a §7-10 — ATR y soporte/resistencia sobre el rango real
# ---------------------------------------------------------------------------

def _frame_acciones(n: int) -> pd.DataFrame:
    cierres = [_nivel(i) for i in range(n)]
    return pd.DataFrame(
        {
            "Open": cierres,
            "High": [c * 1.012 for c in cierres],
            "Low": [c * 0.988 for c in cierres],
            "Close": cierres,
            "Volume": [1.0e6 + 1000.0 * (i % 7) for i in range(n)],
        }
    )


def test_07_regresion_en_acciones_el_atr_no_cambia():
    # Sin NaN en High/Low el subconjunto ES el frame entero, así que el
    # resultado tiene que ser idéntico al del cálculo de siempre.
    df = _frame_acciones(502)
    calculado = calcular_indicadores(df)["ATR_14"]
    referencia = ta.atr(df["High"], df["Low"], df["Close"], length=LONGITUD_ATR)
    assert calculado.notna().sum() == referencia.notna().sum()
    assert np.allclose(
        calculado.to_numpy(dtype=float),
        referencia.to_numpy(dtype=float),
        equal_nan=True,
    )


def _frame_mixto(filas: int, con_rango: int) -> pd.DataFrame:
    """Frame al estilo cripto: todas las filas con cierre y volumen, pero
    solo las `con_rango` últimas con máximo y mínimo."""
    df = _frame_acciones(filas)
    sin_rango = filas - con_rango
    df.loc[df.index[:sin_rango], ["High", "Low"]] = np.nan
    return df


def test_08_el_atr_se_calcula_solo_sobre_el_subconjunto_con_rango():
    df = _frame_mixto(366, 30)
    atr = calcular_indicadores(df)["ATR_14"]
    # 30 filas de subconjunto y longitud 14: 17 valores emitidos.
    assert int(atr.notna().sum()) == 17, int(atr.notna().sum())
    # Y las 336 filas sin rango real siguen sin ATR, no heredan ninguno.
    assert atr.iloc[:336].isna().all()

    subconjunto = df.dropna(subset=["High", "Low"])
    referencia = ta.atr(
        subconjunto["High"], subconjunto["Low"], subconjunto["Close"], length=LONGITUD_ATR
    )
    assert abs(float(atr.iloc[-1]) - float(referencia.iloc[-1])) < 1e-9

    # La prueba de que esto importa: sobre el frame entero pandas-ta
    # siembra la media de Wilder con NaN y devuelve OTRO número.
    ingenuo = ta.atr(df["High"], df["Low"], df["Close"], length=LONGITUD_ATR)
    assert abs(float(ingenuo.iloc[-1]) - float(atr.iloc[-1])) > 1e-6


def test_09_sin_rango_suficiente_la_fila_deja_de_ser_operable():
    # 14 filas con máximo y mínimo: no alcanza para una media de Wilder.
    df = _frame_mixto(366, LONGITUD_ATR)
    indicadores = calcular_indicadores(df)
    assert pd.isna(indicadores["ATR_14"].iloc[-1])

    d = _escanear_con(df)
    assert d["operable"] is False
    assert d["leverage_recomendado"] is None
    assert "volatilidad no disponible" in d["leverage_motivo"], d["leverage_motivo"]
    # Regla 4: degrada hacia el riesgo mínimo, nunca hacia el máximo.
    assert d["leverage_referencia_volatilidad"] == 1.0


def test_10_soporte_resistencia_con_huecos_cae_al_fallback_por_atr():
    df = calcular_indicadores(_frame_acciones(366))
    df.loc[df.index[-5], "High"] = np.nan  # un hueco dentro de la ventana
    soporte, resistencia = calcular_soporte_resistencia(df)
    assert math.isnan(soporte) and math.isnan(resistencia)

    # Una ventana más corta disfrazada de 20 velas es peor que declarar el
    # origen: `_niveles_tecnicos` tiene que decir "atr".
    _, _, origen = servicio_interno._niveles_tecnicos(
        df, float(df["Close"].iloc[-1]), float(df["ATR_14"].iloc[-1])
    )
    assert origen == "atr"


def test_10b_ventana_completa_sigue_dando_estructura():
    # Contraprueba del caso anterior: sin huecos, la ventana de 20 velas
    # se usa tal cual y el origen sigue siendo "estructura".
    df = calcular_indicadores(_frame_acciones(366))
    soporte, resistencia = calcular_soporte_resistencia(df)
    ventana = df.tail(VENTANA_SOPORTE_RESISTENCIA)
    assert soporte == float(ventana["Low"].min())
    assert resistencia == float(ventana["High"].max())


# ---------------------------------------------------------------------------
# §7-11 a §7-14 — efecto aguas abajo en confluencia, apalancamiento y contrato
# ---------------------------------------------------------------------------

class _DatosSinteticos:
    def __init__(self, df):
        self.datos = df


def _escanear_con(df) -> dict:
    original = servicio_interno._obtener_ohlcv
    try:
        servicio_interno._obtener_ohlcv = lambda ticker: _DatosSinteticos(df)
        return servicio_interno._escanear_ticker("TEST")
    finally:
        servicio_interno._obtener_ohlcv = original


def _serie(n, deriva, amplitud, base, fase=0.0):
    """Misma serie oscilante con deriva que usa test_contrato_scan.py: la
    deriva decide el cruce de medias y la fase de la oscilación decide el
    signo del histograma MACD, con el RSI en su banda neutra.

    `fase` se añade aquí porque estos casos usan series mucho más largas
    (366 velas frente a 246) y en el extremo de esa serie la oscilación
    cae en una pendiente que dispara el RSI a sobrecompra. Desplazar la
    fase coloca el último punto en la banda neutra del RSI, que es lo que
    hace falta para aislar el voto de las OTRAS tres señales."""
    return [base + deriva * i + amplitud * math.sin(i / 8.0 + fase) for i in range(n)]


def _frame_cripto_alcista(con_volumen: bool) -> pd.DataFrame:
    """366 velas diarias con deriva alcista y rango estrecho (ATR% < 3).

    Es la forma que tiene ahora un frame de cripto: 366 días de cierre y,
    para este caso, rango real en todos ellos. La fase deja el RSI en su
    banda neutra (≈59) para que los tres votos alcistas vengan del cruce,
    del MACD y del volumen, sin que el RSI meta un voto bajista de
    sobrecompra que enturbiaría el conteo.
    """
    cierres = _serie(366, 0.15, 8.0, 100.0, fase=4.0)
    datos = {
        "Open": cierres,
        "High": [c * 1.005 for c in cierres],
        "Low": [c * 0.995 for c in cierres],
        "Close": cierres,
    }
    if con_volumen:
        # Volumen plano salvo la última vela, a 3x la media de 20.
        volumen = [1.0e9] * 366
        volumen[-1] = 3.0e9
        datos["Volume"] = volumen
    return pd.DataFrame(datos)


def test_11_con_366_velas_el_cruce_de_medias_por_fin_vota():
    # Con la ventana vieja (45 velas de 4 días en cripto, 126 sesiones en
    # acciones) la SMA 200 no tenía UN SOLO valor válido y `cruce_medias`
    # no se emitía nunca en ningún mercado.
    df = calcular_indicadores(_frame_cripto_alcista(con_volumen=False))
    assert pd.notna(df["SMA_200"].iloc[-1])
    assert int(df["SMA_200"].notna().sum()) == 167, int(df["SMA_200"].notna().sum())

    confluencia = evaluar_confluencia(df)
    nombres = [s.nombre for s in confluencia.senales]
    assert "cruce_medias" in nombres, nombres


def test_12_fuerza_alta_alcanzable_y_topada_en_5x():
    df = _frame_cripto_alcista(con_volumen=True)
    confluencia = evaluar_confluencia(calcular_indicadores(df))
    assert confluencia.indicadores_alcistas == 3, [
        (s.nombre, s.direccion.value) for s in confluencia.senales
    ]
    assert confluencia.indicadores_bajistas == 0
    # D2: "alta" pasa a ser alcanzable. La definición de `fuerza` no se
    # toca — lo que cambia es que cripto ya tiene tres votantes posibles.
    assert confluencia.fuerza == "alta"

    d = _escanear_con(df)
    assert d["atr_pct"] < 3.0, d["atr_pct"]
    assert d["operable"] is True
    # Tope de Fase 1: el remache de latón. Nunca por encima (regla 1).
    assert d["leverage_recomendado"] == 5.0
    assert d["leverage_recomendado"] == d["leverage_tope"]


def test_13_el_tope_duro_recorta_la_misma_fila_en_fase_2():
    df = _frame_cripto_alcista(con_volumen=True)
    original = servicio_interno.LEVERAGE_TOPE_FASE1
    try:
        servicio_interno.LEVERAGE_TOPE_FASE1 = 3.0
        d = _escanear_con(df)
    finally:
        servicio_interno.LEVERAGE_TOPE_FASE1 = original
    # Misma señal que el caso 12 (3/0, "alta", ATR% < 3) pero con el tope
    # bajado: el min() manda sobre cualquier bonus de confluencia.
    assert d["leverage_recomendado"] == 3.0
    assert d["leverage_tope"] == 3.0


def _invariantes_universales(d: dict) -> None:
    """Invariantes de test_contrato_scan.py:131-147 que valen para
    CUALQUIER ítem sin error, incluido el degradado por falta de
    volatilidad."""
    sesgo_esperado = {"alcista": "largo", "bajista": "corto", "neutral": "sin_sesgo"}
    assert "error" not in d
    assert d["operable"] == (d["leverage_recomendado"] is not None)
    assert d["operable"] == (d["sl"] is not None)
    assert d["operable"] == (d["tp"] is not None)
    assert d["leverage_recomendado"] is None or (
        1.0 <= d["leverage_recomendado"] <= d["leverage_tope"]
    )
    assert 1.0 <= d["leverage_referencia_volatilidad"] <= d["leverage_tope"]
    # Desde el 2026-10-10 sl/tp ya no son soporte/resistencia: se anclan a
    # ellos y se acotan en ATR. Lo que el contrato exige es que encuadren
    # el precio y que el objetivo no pase de la resistencia salvo con el
    # mínimo de 0,5 ATR (precio ya en la resistencia).
    if d["sl"] is not None:
        assert d["sl"] < d["precio_actual"] < d["tp"]
    assert d["sesgo_operativo"] == sesgo_esperado[d["direccion"]]
    assert d["niveles_origen"] in ("estructura", "atr")


def test_14_el_contrato_se_mantiene_en_los_tres_casos_nuevos():
    casos = {
        "cruce_valido": _frame_cripto_alcista(con_volumen=False),
        "fuerza_alta": _frame_cripto_alcista(con_volumen=True),
        "sin_volatilidad": _frame_mixto(366, LONGITUD_ATR),
    }
    for nombre, df in casos.items():
        d = _escanear_con(df)
        crudo = json.dumps(d)
        # Un NaN se serializa como el literal `NaN`, que JSON.parse()
        # rechaza — y tumbaría el escáner completo, no solo esta fila.
        assert "NaN" not in crudo, nombre
        assert "Infinity" not in crudo, nombre
        _invariantes_universales(d)

    # Los niveles solo son exigibles cuando hay volatilidad utilizable:
    # sin ATR no hay ni ventana de estructura ni fallback, y el contrato
    # emite nulos antes que un rango inventado.
    for nombre in ("cruce_valido", "fuerza_alta"):
        d = _escanear_con(casos[nombre])
        assert d["soporte"] is not None and d["resistencia"] is not None, nombre
        assert d["resistencia"] > d["soporte"], nombre

    degradado = _escanear_con(casos["sin_volatilidad"])
    assert degradado["soporte"] is None and degradado["resistencia"] is None
    assert degradado["niveles_origen"] == "atr"


# ---------------------------------------------------------------------------
# §7-15 y §7-16 — rotación y salud con el tercer votante activo
# ---------------------------------------------------------------------------

def _frame_rsi_sobreventa_en_tendencia_bajista() -> pd.DataFrame:
    """Cruce bajista + MACD bajista + RSI en sobreventa: 1 alcista y 2
    bajistas. Es la trampa de §5.4 — la `fuerza` sale "media" por el lado
    BAJISTA, y solo el filtro de dominancia estricta la excluye."""
    cierres = _serie(350, -0.15, -8.0, 200.0)
    ultimo = cierres[-1]
    # Caída final abrupta para meter el RSI por debajo de 30 sin tocar el
    # signo del MACD ni el orden de las medias.
    cierres += [ultimo * (0.975 ** (i + 1)) for i in range(16)]
    return pd.DataFrame(
        [{"Open": c, "High": c * 1.01, "Low": c * 0.99, "Close": c} for c in cierres]
    )


def test_15_un_alcista_y_dos_bajistas_nunca_es_destino_de_rotacion():
    d = _escanear_con(_frame_rsi_sobreventa_en_tendencia_bajista())
    detalle = d["senales"]
    # Desde el 2026-10-10 la sobreventa con el MACD bajista no vota: se
    # muestra como neutral. Era 1 contra 2; ahora es 0 contra 2.
    assert d["indicadores_alcistas"] == 0, detalle
    assert d["indicadores_bajistas"] == 2, detalle
    rsi = next(s for s in detalle if s["nombre"] == "rsi")
    assert rsi["direccion"] == "neutral" and "sin voto" in rsi["detalle"], rsi
    assert d["fuerza"] == "media", detalle  # "media" la da el lado bajista
    assert d["direccion"] == "bajista"

    # `rotacion.py:54` lo dejaría pasar por fuerza; lo excluye la
    # dominancia estricta de `:61`. La trampa sigue cerrada de extremo a
    # extremo, no solo con fixtures a mano.
    assert mejor_oportunidad_del_escaneo([d], ticker_excluir="X") is None


def _confluencia(alcistas: int, bajistas: int) -> ResultadoConfluencia:
    fuerza = "alta" if max(alcistas, bajistas) >= 3 else (
        "media" if max(alcistas, bajistas) == 2 else "baja"
    )
    return ResultadoConfluencia(
        senales=[], indicadores_alcistas=alcistas, indicadores_bajistas=bajistas,
        fuerza=fuerza, resumen="",
    )


def test_16_el_tercer_votante_mueve_la_salud_de_la_posicion():
    posicion = PosicionCargada(ticker="X", precio_compra=100.0, monto_invertido=0.0)

    # Antes: MACD alcista y nada más → 1/0 → verde. Ahora el cruce bajista
    # también vota → 1/1 → empate, y con capital YA EXPUESTO el empate
    # mantiene la vigilancia (`>=` de salud_posicion.py).
    ambar = calcular_diagnostico(posicion, 100.0, _confluencia(1, 1), False)
    assert ambar.nivel_salud.value == "ambar"

    # Y el rojo pasa a ser alcanzable en acciones: 0/2 técnico más EPS
    # negativo.
    rojo = calcular_diagnostico(posicion, 100.0, _confluencia(0, 2), True)
    assert rojo.nivel_salud.value == "rojo"


# ---------------------------------------------------------------------------
# §7-17 a §7-19 — conector: llamadas, caché, errores y ventana de acciones
# ---------------------------------------------------------------------------

class _Reloj:
    """Doble de `time`. `sleep` adelanta el reloj en vez de esperar, así
    que el espaciado de 6 s entre llamadas se respeta en la lógica sin
    que el test tarde 6 s de verdad."""

    def __init__(self) -> None:
        self.t = 0.0

    def monotonic(self) -> float:
        return self.t

    def sleep(self, segundos: float) -> None:
        self.t += segundos


class _RespuestaDoble:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code
        self.headers: dict[str, str] = {}

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(f"{self.status_code}", response=self)


class _RequestsDoble:
    # `_get` referencia estas dos clases en sus `except`, así que el doble
    # tiene que exponerlas tal cual.
    HTTPError = requests.HTTPError
    RequestException = requests.RequestException

    def __init__(self, manejador):
        self._manejador = manejador
        self.llamadas: list[tuple[str, dict]] = []

    def get(self, url, params=None, timeout=None):
        self.llamadas.append((url, dict(params or {})))
        return self._manejador(url, params)


def _manejador_ok(url, params):
    if url.endswith("/market_chart"):
        return _RespuestaDoble(MC)
    if url.endswith("/ohlc"):
        return _RespuestaDoble(OHLC)
    raise AssertionError(f"URL inesperada: {url}")


def _con_dobles(manejador):
    """Sustituye `requests` y `time` dentro del módulo del conector."""
    reloj = _Reloj()
    doble = _RequestsDoble(manejador)
    originales = (coingecko.requests, coingecko.time)
    coingecko.requests = doble
    coingecko.time = reloj
    return doble, reloj, originales


def _restaurar(originales):
    coingecko.requests, coingecko.time = originales


def test_17_dos_llamadas_en_frio_y_caches_con_ttl_independientes():
    doble, reloj, originales = _con_dobles(_manejador_ok)
    try:
        conector = ConectorCriptoCoinGecko()

        # --- En frío: exactamente C1 y C2, con los parámetros de §3.1 ---
        datos = conector.obtener_ohlcv("bitcoin")
        assert len(doble.llamadas) == 2, doble.llamadas
        assert doble.llamadas[0] == (
            "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart",
            {"vs_currency": "usd", "days": 365, "interval": "daily"},
        )
        assert doble.llamadas[1] == (
            "https://api.coingecko.com/api/v3/coins/bitcoin/ohlc",
            {"vs_currency": "usd", "days": 30},
        )
        assert len(datos.datos) == 366
        assert datos.fuente == "coingecko"

        # --- Dentro de los dos TTL: ni una llamada ---
        doble.llamadas.clear()
        conector.obtener_ohlcv("bitcoin")
        assert doble.llamadas == []

        # --- A los 16 min vence C1 (15 min) pero no C2 (60 min) ---
        doble.llamadas.clear()
        reloj.t = 960.0
        conector.obtener_ohlcv("bitcoin")
        assert len(doble.llamadas) == 1, doble.llamadas
        assert doble.llamadas[0][0].endswith("/market_chart")

        # --- A los 61 min vencen las dos ---
        doble.llamadas.clear()
        reloj.t = 3660.0
        conector.obtener_ohlcv("bitcoin")
        assert len(doble.llamadas) == 2, doble.llamadas
    finally:
        _restaurar(originales)


def test_18_si_falla_la_llamada_de_4h_el_ticker_sale_como_error():
    def manejador(url, params):
        if url.endswith("/market_chart"):
            return _RespuestaDoble(MC)
        return _RespuestaDoble(None, status_code=500)

    doble, _reloj, originales = _con_dobles(manejador)
    # El 500 es el resultado ESPERADO aquí: su logger.warning solo
    # ensuciaría la salida PASS/FAIL del runner.
    logging.getLogger("conectores.coingecko").setLevel(logging.CRITICAL)
    try:
        conector = ConectorCriptoCoinGecko()
        try:
            conector.obtener_ohlcv("bitcoin")
        except requests.HTTPError:
            pass
        else:
            raise AssertionError("obtener_ohlcv debía propagar el HTTPError")
        # D6: un 500 no se reintenta (solo se reintenta el 429), así que
        # son 2 GET y ni un frame a medias.
        assert len(doble.llamadas) == 2, doble.llamadas
    finally:
        _restaurar(originales)

    # Y en el escaneo eso se ve como error DE TICKER, no como fila no
    # operable: "sin dato" y "sin operación" son cosas distintas.
    original = servicio_interno._obtener_ohlcv

    def _falla(ticker):
        raise requests.HTTPError("500")

    try:
        servicio_interno._obtener_ohlcv = _falla
        resultados = []
        try:
            resultados.append(servicio_interno._escanear_ticker("bitcoin"))
        except Exception as exc:
            resultados.append({"ticker": "bitcoin", "error": f"fallo de datos: {exc}"})
    finally:
        servicio_interno._obtener_ohlcv = original
    assert "error" in resultados[0]
    assert "operable" not in resultados[0]


def test_19_la_ventana_de_acciones_es_de_dos_anos():
    firma = inspect.signature(ConectorAccionesYahoo.obtener_ohlcv)
    assert firma.parameters["periodo"].default == "2y"
    assert firma.parameters["intervalo"].default == "1d"


def test_20_los_frames_de_contrato_no_cambian_de_camino():
    # Los frames de test_contrato_scan.py no tienen NaN en High/Low, así
    # que el subconjunto del ATR es el frame entero y su resultado es
    # idéntico al de antes del cambio. Es la razón por la que los 47 casos
    # existentes siguen pasando sin tocarse.
    import test_contrato_scan as contrato

    for df in (contrato.DF_LARGO, contrato.DF_NEUTRAL, contrato.DF_CORTO):
        assert df["High"].notna().all() and df["Low"].notna().all()
        calculado = calcular_indicadores(df)["ATR_14"]
        referencia = ta.atr(df["High"], df["Low"], df["Close"], length=LONGITUD_ATR)
        assert np.allclose(
            calculado.to_numpy(dtype=float),
            referencia.to_numpy(dtype=float),
            equal_nan=True,
        )


def test_21_el_conector_no_acepta_ya_un_numero_de_dias():
    # Los dos valores (365 y 30) los fija la documentación del proveedor:
    # dejarlos configurables invitaba a volver a days=180 y a las velas de
    # 4 días sin que nada fallara de forma visible.
    firma = inspect.signature(ConectorCriptoCoinGecko.obtener_ohlcv)
    assert list(firma.parameters) == ["self", "coin_id"], list(firma.parameters)


if __name__ == "__main__":
    tests = [
        test_01_forma_del_frame_reconstruido,
        test_02_close_es_el_punto_de_c1_del_dia_siguiente,
        test_03_volumen_presente_en_todas_las_filas,
        test_04_las_velas_de_4h_se_asignan_al_dia_que_cierran,
        test_05_dias_sin_velas_de_4h_quedan_en_nan_sin_fabricar_nada,
        test_06_las_velas_con_rango_real_son_coherentes,
        test_07_regresion_en_acciones_el_atr_no_cambia,
        test_08_el_atr_se_calcula_solo_sobre_el_subconjunto_con_rango,
        test_09_sin_rango_suficiente_la_fila_deja_de_ser_operable,
        test_10_soporte_resistencia_con_huecos_cae_al_fallback_por_atr,
        test_10b_ventana_completa_sigue_dando_estructura,
        test_11_con_366_velas_el_cruce_de_medias_por_fin_vota,
        test_12_fuerza_alta_alcanzable_y_topada_en_5x,
        test_13_el_tope_duro_recorta_la_misma_fila_en_fase_2,
        test_14_el_contrato_se_mantiene_en_los_tres_casos_nuevos,
        test_15_un_alcista_y_dos_bajistas_nunca_es_destino_de_rotacion,
        test_16_el_tercer_votante_mueve_la_salud_de_la_posicion,
        test_17_dos_llamadas_en_frio_y_caches_con_ttl_independientes,
        test_18_si_falla_la_llamada_de_4h_el_ticker_sale_como_error,
        test_19_la_ventana_de_acciones_es_de_dos_anos,
        test_20_los_frames_de_contrato_no_cambian_de_camino,
        test_21_el_conector_no_acepta_ya_un_numero_de_dias,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")



# ── ATR en la madrugada UTC (2026-09-30) ────────────────────────────

def test_en_la_madrugada_se_usa_el_atr_de_ayer():
    """Entre las 00:00 y las 04:00 UTC el día en curso no tiene ninguna vela
    de 4 h cerrada: su ATR es NaN y dejaba todas las criptos no operables."""
    serie = pd.Series([2.1, 2.2, np.nan])
    assert servicio_interno.atr_vigente(serie) == 2.2


def test_con_el_atr_de_hoy_se_usa_el_de_hoy():
    assert servicio_interno.atr_vigente(pd.Series([2.1, 2.2, 2.3])) == 2.3


def test_si_faltan_dos_dias_no_se_inventa_volatilidad():
    # Ya no es la madrugada: es un problema de datos, y la regla nº4 tiene
    # que degradar al mínimo.
    assert math.isnan(servicio_interno.atr_vigente(pd.Series([2.1, np.nan, np.nan])))
    assert math.isnan(servicio_interno.atr_vigente(pd.Series([], dtype="float64")))


def test_la_vela_del_dia_sin_velas_de_4h_cerradas_da_atr_nan_en_la_ultima_fila():
    """El caso real, de punta a punta: sin velas de 4 h del día en curso, la
    última fila no tiene rango y su ATR es NaN; el de la penúltima sí existe."""
    market_chart = _market_chart_sintetico()
    ultimo_dia = pd.Timestamp(market_chart["prices"][-1][0], unit="ms", tz="UTC").normalize()
    velas = [v for v in _ohlc_4h_sintetico()
             if pd.Timestamp(v[0], unit="ms", tz="UTC").normalize() < ultimo_dia]
    marco = construir_velas_diarias(market_chart, velas)
    atr = calcular_indicadores(marco)["ATR_14"]
    assert math.isnan(atr.iloc[-1])
    assert math.isfinite(servicio_interno.atr_vigente(atr))
