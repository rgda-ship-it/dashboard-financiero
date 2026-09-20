"""
Conector de datos de criptomonedas vía CoinGecko (API pública, tier gratuito).

A diferencia de yfinance, CoinGecko es una API oficial y estable — pero
igualmente se aísla como adaptador para mantener el mismo patrón en todo
el sistema y poder añadir otro proveedor de cripto en el futuro sin tocar
el resto del motor analítico.

POR QUÉ NO SE USA SIMPLEMENTE /ohlc
-----------------------------------
Esta es la pregunta que se hará quien lea este archivo dentro de seis
meses, así que queda contestada aquí y no en un commit perdido.

`/coins/{id}/ohlc` es el endpoint obvio: devuelve OHLC de verdad en una
sola llamada. El problema es su granularidad, que NO es configurable sin
plan de pago: la documentación fija "1-2 días → 30 min", "3-30 días →
4 horas" y "31 días en adelante → 4 DÍAS". El parámetro `interval=daily`
existe, pero está reservado a suscriptores de pago.

Pidiendo `days=180` (lo que hacía este conector) salían 45 velas de 4
días cada una, y eso rompía tres cosas a la vez:

1. Escala temporal. "RSI 14" pasaba a significar 56 días de calendario y
   la EMA lenta del MACD 26, 104 días — mientras que en acciones seguían
   siendo 14 y 26 sesiones. Los umbrales (30/70 del RSI, los tramos de
   ATR% de riesgo/apalancamiento.py) están calibrados sobre velas
   diarias, así que se estaban aplicando a otra distribución.
2. ATR inflado. El rango verdadero escala con la raíz del tiempo: el
   ATR% de BTC salía ~2x el real (5,66 % frente a 2,77 %), lo que metía
   a la moneda en un tramo de volatilidad más alto del que le toca.
3. Precio desfasado hasta 4 días. El timestamp de /ohlc es la hora de
   CIERRE de la vela, así que `Close.iloc[-1]` era el cierre de la
   última vela de 4 días ya completa. Se llegaron a medir 3,4 días y un
   7,2 % de desfase contra el precio vivo, y ese número alimentaba el
   P&L de cartera y los niveles técnicos.

Además /ohlc no trae volumen, así que el indicador de volumen relativo
de cripto quedaba siempre en NaN.

La solución (ver docs/propuesta-velas-ventanas.md §3.1) es reconstruir la
vela diaria con las DOS llamadas que el tier sin clave sí permite:

  C1  /market_chart?days=365&interval=daily  → cierres diarios a las
      00:00 UTC, precio vivo y volumen de 24 h.
  C2  /ohlc?days=30                          → velas de 4 h, que se
      agregan a máximo/mínimo/apertura del día.

Cuesta una llamada más por moneda, pero devuelve la escala diaria en los
dos mercados. Lo que NO se hace es inventar máximos y mínimos para los
~336 días que quedan fuera del alcance de C2: esas filas salen con
High/Low en NaN a propósito, y `indicadores/tecnicos.py` calcula el ATR y
el soporte/resistencia solo sobre el tramo con máximos y mínimos reales.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from datetime import datetime

import numpy as np
import pandas as pd
import requests

logger = logging.getLogger(__name__)

BASE_URL = "https://api.coingecko.com/api/v3"

# Rate limit del tier gratuito de CoinGecko (API pública sin clave): ronda
# las 10-15 req/min, no las 40 que permitía el 1.5 s anterior. Con el valor
# viejo el escáner agotaba la cuota a mitad del universo cripto y el último
# ticker (solana) volvía siempre como 429 Too Many Requests.
SEGUNDOS_ENTRE_LLAMADAS = 6.0

# Reintentos ante 429. CoinGecko a veces manda cabecera Retry-After; si no
# está, se hace backoff exponencial sobre el intervalo base.
MAX_REINTENTOS_429 = 3

# Parámetros de las dos llamadas de velas. NO son configurables a
# propósito: los fija la documentación del proveedor, no una preferencia.
#   365 → máximo de historia sin clave ("restricted to the past 365 days")
#         y, por encima de 90 días, granularidad diaria a las 00:00 UTC.
#    30 → máximo que todavía devuelve velas de 4 h. Con 31 o más, /ohlc
#         vuelve a agregar de 4 en 4 días y se pierde todo lo ganado.
DIAS_MARKET_CHART = 365
DIAS_OHLC_4H = 30

# Velas de 4 h que tiene un día UTC completo (04:00, 08:00, 12:00, 16:00,
# 20:00 y el cierre de las 00:00 del día siguiente).
VELAS_4H_POR_DIA = 6

# TTL de caché, uno por endpoint porque envejecen a ritmos distintos.
# C1 lleva el precio vivo, así que es lo que marca el desfase que ve el
# usuario; CoinGecko refresca market_chart cada ~30 s, pero el frontend
# solo repinta cada 5 min y 15 min de TTL dejan el desfase muy por debajo
# de los 4 DÍAS que había antes. C2 solo aporta velas de 4 h ya cerradas:
# volver a pedirlo antes de que cierre la siguiente no aporta un dato
# nuevo, y ahorrar esa llamada es lo que mantiene el escaneo en frío
# dentro del rate limit sin clave.
TTL_CACHE_MARKET_CHART_SEG = 900.0
TTL_CACHE_OHLC_4H_SEG = 3600.0

TTL_CACHE_FUNDAMENTALES_SEG = 300.0


@dataclass
class DatosOHLCV:
    ticker: str
    datos: pd.DataFrame
    obtenido_en: datetime
    fuente: str = "coingecko"


def _dia_utc_de_cierre(timestamp_ms: int) -> pd.Timestamp:
    """Día UTC al que pertenece una muestra cuyo timestamp es su CIERRE.

    Las dos series de CoinGecko datan sus puntos por hora de cierre, no de
    apertura. Eso hace que un timestamp exactamente a las 00:00 sea el
    cierre del día ANTERIOR, no la apertura del que empieza: el punto
    diario de `2026-09-20 00:00` es el cierre del 19, igual que la vela de
    4 h que cierra a `2026-09-20 00:00` es la última del 19.

    Cualquier otro timestamp (el punto vivo de C1, o las velas de 4 h de
    hoy) pertenece al día que está en curso, es decir al suyo propio.
    Tratar los dos casos con la misma regla es lo que permite que C1 y C2
    encajen en la misma rejilla de días sin desplazarse una respecto de la
    otra.
    """
    instante = pd.Timestamp(timestamp_ms, unit="ms", tz="UTC")
    dia = instante.normalize()
    if instante == dia:
        dia = dia - pd.Timedelta(days=1)
    # El resto del motor trabaja con índices sin zona horaria (es lo que
    # devolvía el conector antes); la zona ya cumplió su función al decidir
    # a qué día UTC cae cada punto.
    return dia.tz_localize(None)


def construir_velas_diarias(market_chart: dict, ohlc_4h: list) -> pd.DataFrame:
    """Funde las dos respuestas de CoinGecko en un OHLCV diario.

    Función PURA y sin red a propósito: es la pieza con lógica de verdad
    de este conector (la que decide a qué día va cada punto y qué se deja
    en NaN), así que tiene que poder probarse con fixtures sintéticas sin
    tocar la API. `obtener_ohlcv` solo se ocupa de traer los insumos.

    Devuelve un frame con índice diario UTC y columnas
    Open/High/Low/Close/Volume. Las filas anteriores al alcance de C2
    llevan High/Low en NaN: son días de los que SÍ se conoce el cierre y
    el volumen, pero NO el recorrido intradía. Rellenarlos con el cierre
    (High = Low = Close) daría un rango verdadero de cero y hundiría el
    ATR, que es justo la medida que protege la regla de apalancamiento.
    """
    precios = (market_chart or {}).get("prices") or []
    volumenes = (market_chart or {}).get("total_volumes") or []
    if not precios:
        raise ValueError("market_chart sin serie de precios utilizable")

    # Un dict por día: las series vienen en orden ascendente, así que si
    # dos puntos cayeran en el mismo día gana el más reciente. Es lo que
    # hace que el punto vivo mande sobre cualquier muestra previa de hoy.
    cierres: dict[pd.Timestamp, float] = {}
    for punto in precios:
        cierres[_dia_utc_de_cierre(punto[0])] = float(punto[1])

    volumen_por_dia: dict[pd.Timestamp, float] = {}
    for punto in volumenes:
        volumen_por_dia[_dia_utc_de_cierre(punto[0])] = float(punto[1])

    # --- Agregación de las velas de 4 h a máximo/mínimo/apertura del día ---
    agregado: dict[pd.Timestamp, dict] = {}
    for vela in ohlc_4h or []:
        dia = _dia_utc_de_cierre(vela[0])
        apertura, maximo, minimo = float(vela[1]), float(vela[2]), float(vela[3])
        acumulado = agregado.get(dia)
        if acumulado is None:
            # La primera vela que se ve de un día es la más temprana (la
            # lista viene ordenada), así que su apertura es la del día.
            agregado[dia] = {
                "Open": apertura,
                "High": maximo,
                "Low": minimo,
                "velas": 1,
            }
        else:
            acumulado["High"] = max(acumulado["High"], maximo)
            acumulado["Low"] = min(acumulado["Low"], minimo)
            acumulado["velas"] += 1

    # El día más antiguo de C2 casi siempre llega cortado: la ventana de 30
    # días empieza a media jornada, así que ese día trae 2 o 3 velas y su
    # "máximo" solo cubre unas horas. Se descarta entero — un rango parcial
    # presentado como rango diario subestima la volatilidad, y subestimar
    # la volatilidad se traduce en MÁS apalancamiento (lo contrario de lo
    # que protege la regla 4). Los demás días sí se aceptan aunque estén
    # incompletos: el de hoy lo está siempre, y no hay forma de conocer el
    # rango del día en curso más que con las velas que ya cerraron.
    if agregado:
        dia_mas_antiguo = min(agregado)
        if agregado[dia_mas_antiguo]["velas"] < VELAS_4H_POR_DIA:
            del agregado[dia_mas_antiguo]

    dias = sorted(cierres)
    marco = pd.DataFrame(index=pd.DatetimeIndex(dias, name="timestamp"))
    marco["Open"] = [agregado[d]["Open"] if d in agregado else np.nan for d in dias]
    marco["High"] = [agregado[d]["High"] if d in agregado else np.nan for d in dias]
    marco["Low"] = [agregado[d]["Low"] if d in agregado else np.nan for d in dias]
    marco["Close"] = [cierres[d] for d in dias]
    marco["Volume"] = [volumen_por_dia.get(d, np.nan) for d in dias]

    # El cierre viene de C1 y el rango de C2, que son dos series distintas
    # (y para el día en curso, dos instantes distintos). Sin esta costura
    # una vela podía quedar con Close por encima de su propio High, que es
    # una vela imposible y rompe cualquier lectura de rango verdadero.
    # np.maximum/np.minimum propagan NaN, así que los días sin velas de 4 h
    # siguen sin máximo ni mínimo en vez de heredar el cierre.
    marco["High"] = np.maximum(marco["High"], marco["Close"])
    marco["Low"] = np.minimum(marco["Low"], marco["Close"])

    # Apertura de los días fuera del alcance de C2: el cierre del día
    # anterior, que en un mercado 24/7 sin huecos es exactamente donde
    # abre. La primera fila se queda sin apertura porque no hay día
    # anterior del que tomarla; ningún indicador lee Open, así que no se
    # inventa un valor solo por rellenar la columna.
    marco["Open"] = marco["Open"].fillna(marco["Close"].shift(1))

    return marco


class ConectorCriptoCoinGecko:
    def __init__(self) -> None:
        self._ultima_llamada: float = 0.0
        # FastAPI atiende los endpoints síncronos en un threadpool, así que
        # dos escaneos concurrentes podían pisarse el rate limiter y disparar
        # llamadas en paralelo. El lock serializa el acceso a CoinGecko y
        # protege la caché.
        self._lock = threading.RLock()
        self._cache: dict[str, tuple[float, object]] = {}

    def _esperar_rate_limit(self) -> None:
        transcurrido = time.monotonic() - self._ultima_llamada
        if transcurrido < SEGUNDOS_ENTRE_LLAMADAS:
            time.sleep(SEGUNDOS_ENTRE_LLAMADAS - transcurrido)
        self._ultima_llamada = time.monotonic()

    def _desde_cache(self, clave: str, ttl: float):
        entrada = self._cache.get(clave)
        if entrada is None:
            return None
        guardado_en, valor = entrada
        if time.monotonic() - guardado_en > ttl:
            return None
        logger.debug("CoinGecko: %s servido desde caché", clave)
        return valor

    def _guardar_en_cache(self, clave: str, valor) -> None:
        self._cache[clave] = (time.monotonic(), valor)

    def _get(self, url: str, params: dict, descripcion: str) -> object:
        """GET contra CoinGecko respetando el rate limit y reintentando
        ante 429. Cualquier otro error de red se propaga tal cual."""
        for intento in range(MAX_REINTENTOS_429 + 1):
            self._esperar_rate_limit()
            try:
                resp = requests.get(url, params=params, timeout=10)
                resp.raise_for_status()
                return resp.json()
            except requests.HTTPError as exc:
                agotado = intento == MAX_REINTENTOS_429
                if exc.response is None or exc.response.status_code != 429 or agotado:
                    logger.warning("Fallo al consultar CoinGecko (%s): %s", descripcion, exc)
                    raise
                espera = self._espera_tras_429(exc.response, intento)
                logger.info(
                    "CoinGecko devolvió 429 en %s; reintento %d/%d en %.1f s",
                    descripcion, intento + 1, MAX_REINTENTOS_429, espera,
                )
                time.sleep(espera)
            except requests.RequestException as exc:
                logger.warning("Fallo al consultar CoinGecko (%s): %s", descripcion, exc)
                raise
        raise AssertionError("inalcanzable")  # pragma: no cover

    @staticmethod
    def _espera_tras_429(respuesta: requests.Response, intento: int) -> float:
        cabecera = respuesta.headers.get("Retry-After")
        if cabecera:
            try:
                return max(float(cabecera), SEGUNDOS_ENTRE_LLAMADAS)
            except ValueError:
                pass  # Retry-After como fecha HTTP: se ignora y se usa backoff
        return SEGUNDOS_ENTRE_LLAMADAS * (2 ** intento)

    def _market_chart_diario(self, coin_id: str) -> dict:
        """C1: cierres diarios a las 00:00 UTC, precio vivo y volumen."""
        clave = f"mc:{coin_id}:{DIAS_MARKET_CHART}"
        with self._lock:
            cacheado = self._desde_cache(clave, TTL_CACHE_MARKET_CHART_SEG)
            if cacheado is not None:
                return cacheado

            crudo = self._get(
                f"{BASE_URL}/coins/{coin_id}/market_chart",
                {
                    "vs_currency": "usd",
                    "days": DIAS_MARKET_CHART,
                    "interval": "daily",
                },
                f"market_chart de {coin_id}",
            )
            if not crudo or not crudo.get("prices"):
                raise ValueError(f"Ticker cripto no reconocido o sin datos: {coin_id}")

            self._guardar_en_cache(clave, crudo)
            return crudo

    def _ohlc_4h(self, coin_id: str) -> list:
        """C2: velas de 4 h de los últimos 30 días (máximos y mínimos)."""
        clave = f"ohlc4h:{coin_id}:{DIAS_OHLC_4H}"
        with self._lock:
            cacheado = self._desde_cache(clave, TTL_CACHE_OHLC_4H_SEG)
            if cacheado is not None:
                return cacheado

            crudo = self._get(
                f"{BASE_URL}/coins/{coin_id}/ohlc",
                {"vs_currency": "usd", "days": DIAS_OHLC_4H},
                f"ohlc de 4 h de {coin_id}",
            )
            if not crudo:
                raise ValueError(f"Ticker cripto no reconocido o sin datos: {coin_id}")

            self._guardar_en_cache(clave, crudo)
            return crudo

    def obtener_ohlcv(self, coin_id: str) -> DatosOHLCV:
        """coin_id es el id de CoinGecko (ej. 'bitcoin', no 'BTC').

        Ya no acepta un número de días: los dos valores que se piden
        (365 y 30) los fija la documentación del proveedor y cambiarlos
        degrada la granularidad en silencio — ver el docstring del módulo.

        Si cualquiera de las dos llamadas falla tras sus reintentos, la
        excepción se PROPAGA y el ticker sale del escaneo como
        `{ticker, error}`. Deliberadamente no se devuelve un frame a
        medias: el README distingue «sin dato» de «sin operación», y un
        fallo del proveedor tiene que verse como fallo, no como una fila
        no operable que el usuario leería como una decisión del motor.
        """
        market_chart = self._market_chart_diario(coin_id)
        ohlc_4h = self._ohlc_4h(coin_id)

        # El frame se reconstruye en cada llamada en vez de cachearse ya
        # montado: las dos piezas tienen TTL distinto (15 y 60 min), así
        # que cachear el resultado obligaría a un tercer TTL que taparía
        # el refresco del precio vivo que aporta C1.
        df = construir_velas_diarias(market_chart, ohlc_4h)

        return DatosOHLCV(ticker=coin_id, datos=df, obtenido_en=datetime.utcnow())

    def obtener_fundamentales(self, coin_id: str) -> dict:
        """Métricas fundamentales básicas disponibles en el tier gratuito."""
        clave = f"fundamentales:{coin_id}"
        with self._lock:
            cacheado = self._desde_cache(clave, TTL_CACHE_FUNDAMENTALES_SEG)
            if cacheado is not None:
                return cacheado

            info = self._get(
                f"{BASE_URL}/coins/{coin_id}",
                {
                    "localization": "false",
                    "tickers": "false",
                    "community_data": "false",
                    "developer_data": "false",
                },
                f"fundamentales de {coin_id}",
            )

            datos_mercado = info.get("market_data", {})
            fundamentales = {
                "market_cap": datos_mercado.get("market_cap", {}).get("usd"),
                "volumen_24h": datos_mercado.get("total_volume", {}).get("usd"),
                "variacion_market_cap_24h": datos_mercado.get(
                    "market_cap_change_percentage_24h"
                ),
            }
            self._guardar_en_cache(clave, fundamentales)
            return fundamentales
