"""
Conector de datos de acciones vía yfinance.

yfinance NO es una API oficial de Yahoo — es una librería que interpreta
datos públicos de su web. Por eso este módulo está aislado como un
"adaptador": todo el resto del sistema depende de la interfaz
`ConectorAcciones`, nunca de yfinance directamente. Si yfinance se rompe,
solo hay que reemplazar este archivo.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime

import pandas as pd
import yfinance as yf

logger = logging.getLogger(__name__)

# Columnas que este sistema espera de cualquier conector de acciones.
# Si yfinance cambia su esquema, la validación de abajo debe fallar
# de forma ruidosa en vez de dejar pasar datos incorrectos en silencio.
COLUMNAS_ESPERADAS = {"Open", "High", "Low", "Close", "Volume"}


@dataclass
class DatosOHLCV:
    ticker: str
    datos: pd.DataFrame  # índice datetime, columnas Open/High/Low/Close/Volume
    obtenido_en: datetime
    fuente: str = "yfinance"


class ErrorEsquemaInesperado(Exception):
    """Se lanza cuando yfinance devuelve un formato distinto al esperado.

    Este es el riesgo más peligroso identificado por el equipo de QA:
    un cambio silencioso de esquema que no rompe el sistema pero
    contamina los cálculos con datos mal interpretados.
    """


class ConectorAccionesYahoo:
    """Adaptador de acciones sobre yfinance. Ver docstring del módulo."""

    # "6mo" daba ~126 sesiones y con eso la SMA 200 NO tenía un solo valor
    # válido: `cruce_medias` no se emitía nunca, ni en acciones ni en
    # cripto, así que el indicador estaba en el código pero no votaba. Con
    # "2y" (~502 sesiones) quedan ~303 valores de SMA 200 y más de 400 de
    # convergencia para las EMA del MACD. "1y" (~251) dejaría solo ~52, y
    # un par de festivos o una suspensión los acercan al límite. Solo
    # crece el tamaño de la respuesta: sigue siendo 1 llamada por ticker.
    def obtener_ohlcv(
        self, ticker: str, periodo: str = "2y", intervalo: str = "1d"
    ) -> DatosOHLCV:
        try:
            activo = yf.Ticker(ticker)
            df = activo.history(period=periodo, interval=intervalo)
        except Exception as exc:  # cualquier fallo de red/parseo de yfinance
            logger.warning("Fallo al consultar yfinance para %s: %s", ticker, exc)
            raise

        if df.empty:
            raise ValueError(f"Ticker no reconocido o sin datos: {ticker}")

        self._validar_esquema(df, ticker)

        return DatosOHLCV(ticker=ticker, datos=df, obtenido_en=datetime.utcnow())

    def obtener_fundamentales(self, ticker: str) -> dict:
        """Métricas fundamentales básicas disponibles gratuitamente."""
        try:
            info = yf.Ticker(ticker).info
        except Exception as exc:
            logger.warning("Fallo al obtener fundamentales de %s: %s", ticker, exc)
            raise

        # Extracción defensiva: cualquier campo puede faltar sin previo aviso.
        return {
            "pe_ratio": info.get("trailingPE"),
            "eps": info.get("trailingEps"),
            "crecimiento_ingresos": info.get("revenueGrowth"),
            "market_cap": info.get("marketCap"),
        }

    def obtener_moneda(self, ticker: str) -> str | None:
        """Moneda en la que cotiza el ticker según Yahoo (p. ej. «USD»,
        «JPY», «GBp» para peniques de Londres). None si no la declara.

        `fast_info` primero porque es una llamada ligera; `info` como
        respaldo, porque algunos tickers solo la traen ahí.
        """
        try:
            moneda = yf.Ticker(ticker).fast_info.get("currency")
        except Exception as exc:  # noqa: BLE001 — se intenta la otra vía
            logger.warning("fast_info sin moneda para %s: %s", ticker, exc)
            moneda = None
        if not moneda:
            try:
                moneda = yf.Ticker(ticker).info.get("currency")
            except Exception as exc:  # noqa: BLE001
                logger.warning("info sin moneda para %s: %s", ticker, exc)
                return None
        return moneda or None

    @staticmethod
    def _validar_esquema(df: pd.DataFrame, ticker: str) -> None:
        columnas_presentes = set(df.columns)
        faltantes = COLUMNAS_ESPERADAS - columnas_presentes
        if faltantes:
            raise ErrorEsquemaInesperado(
                f"yfinance devolvió un esquema inesperado para {ticker}. "
                f"Columnas faltantes: {faltantes}. "
                "Posible cambio estructural en yfinance — revisar el conector."
            )
