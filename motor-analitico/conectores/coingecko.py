"""
Conector de datos de criptomonedas vía CoinGecko (API pública, tier gratuito).

A diferencia de yfinance, CoinGecko es una API oficial y estable — pero
igualmente se aísla como adaptador para mantener el mismo patrón en todo
el sistema y poder añadir otro proveedor de cripto en el futuro sin tocar
el resto del motor analítico.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from datetime import datetime

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

# TTL de caché. Las velas de /ohlc con days=180 vienen agregadas de 4 días:
# volver a pedirlas en cada escaneo no aporta ni un dato nuevo. Los
# fundamentales (market cap, volumen 24 h) sí se mueven, pero unos minutos
# de desfase son irrelevantes para lo que el motor decide con ellos.
TTL_CACHE_OHLCV_SEG = 900.0
TTL_CACHE_FUNDAMENTALES_SEG = 300.0


@dataclass
class DatosOHLCV:
    ticker: str
    datos: pd.DataFrame
    obtenido_en: datetime
    fuente: str = "coingecko"


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

    def obtener_ohlcv(self, coin_id: str, dias: int = 180) -> DatosOHLCV:
        """coin_id es el id de CoinGecko (ej. 'bitcoin', no 'BTC')."""
        clave = f"ohlcv:{coin_id}:{dias}"
        with self._lock:
            cacheado = self._desde_cache(clave, TTL_CACHE_OHLCV_SEG)
            if cacheado is not None:
                return cacheado

            crudo = self._get(
                f"{BASE_URL}/coins/{coin_id}/ohlc",
                {"vs_currency": "usd", "days": dias},
                f"ohlc de {coin_id}",
            )

        if not crudo:
            raise ValueError(f"Ticker cripto no reconocido o sin datos: {coin_id}")

        # OJO: /ohlc devuelve [timestamp, open, high, low, close]. CoinGecko
        # NO expone volumen en este endpoint, así que este DataFrame sale
        # deliberadamente sin columna "Volume" — calcular_indicadores() lo
        # contempla y omite el indicador de volumen para cripto.
        df = pd.DataFrame(crudo, columns=["timestamp", "Open", "High", "Low", "Close"])
        df["timestamp"] = pd.to_datetime(df["timestamp"], unit="ms")
        df = df.set_index("timestamp")

        resultado = DatosOHLCV(ticker=coin_id, datos=df, obtenido_en=datetime.utcnow())
        with self._lock:
            self._guardar_en_cache(clave, resultado)
        return resultado

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
