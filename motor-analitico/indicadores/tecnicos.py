"""
Indicadores técnicos y lógica de confluencia.

Construido sobre `pandas-ta` (librería open source), tal como se acordó
con la restricción de usar únicamente herramientas de licencia libre.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

import numpy as np

# pandas-ta 0.3.14b0 (sin actualizar desde 2021) todavía hace
# `from numpy import NaN as npNaN` en su __init__. numpy>=2.0 eliminó ese
# alias (solo queda `numpy.nan` en minúscula), así que importar pandas_ta
# con un numpy moderno rompe con `ImportError: cannot import name 'NaN'`
# — y como este módulo se importa desde servicio_interno.py, ese error
# tira abajo el arranque completo de uvicorn (por eso el escáner nunca
# consigue conectarse, aunque el token esté bien configurado). Se
# restaura el alias antes de importar pandas_ta en vez de fijar una
# versión vieja de numpy, que también usan pandas y el resto del motor.
if not hasattr(np, "NaN"):
    np.NaN = np.nan

import pandas as pd
import pandas_ta as ta


class Direccion(str, Enum):
    ALCISTA = "alcista"
    BAJISTA = "bajista"
    NEUTRAL = "neutral"


@dataclass
class SenalIndicador:
    nombre: str
    direccion: Direccion
    detalle: str


@dataclass
class ResultadoConfluencia:
    senales: list[SenalIndicador]
    indicadores_alcistas: int
    indicadores_bajistas: int
    fuerza: str  # "baja" | "media" | "alta"
    resumen: str


def calcular_indicadores(df: pd.DataFrame) -> pd.DataFrame:
    """Añade columnas de indicadores técnicos al DataFrame OHLCV.

    Espera columnas: Open, High, Low, Close (nombres de yfinance/
    normalizador). "Volume" es OPCIONAL: el endpoint /ohlc de CoinGecko no
    devuelve volumen, así que los DataFrames de cripto llegan sin esa
    columna. No muta el DataFrame original.
    """
    resultado = df.copy()

    resultado["SMA_50"] = ta.sma(resultado["Close"], length=50)
    resultado["SMA_200"] = ta.sma(resultado["Close"], length=200)
    resultado["RSI_14"] = ta.rsi(resultado["Close"], length=14)

    macd = ta.macd(resultado["Close"])
    if macd is not None:
        resultado = resultado.join(macd)

    bbands = ta.bbands(resultado["Close"], length=20)
    if bbands is not None:
        resultado = resultado.join(bbands)

    resultado["ATR_14"] = ta.atr(
        resultado["High"], resultado["Low"], resultado["Close"], length=14
    )

    # CoinGecko sirve /ohlc como [timestamp, open, high, low, close] — sin
    # volumen. Aquí se accedía a resultado["Volume"] sin comprobar que
    # existiera, así que TODOS los tickers cripto del escáner morían con
    # KeyError: 'Volume' y llegaban al frontend como
    # {"ticker": ..., "error": "fallo de datos: 'Volume'"}.
    # El volumen solo confirma la dirección dominante (ver
    # evaluar_confluencia), nunca la decide, así que su ausencia se degrada
    # a NaN — evaluar_confluencia ya descarta el indicador con pd.notna()
    # y el resto de la confluencia sigue siendo válida.
    if "Volume" in resultado.columns:
        resultado["Volumen_relativo"] = (
            resultado["Volume"] / resultado["Volume"].rolling(20).mean()
        )
    else:
        resultado["Volumen_relativo"] = np.nan

    return resultado


def evaluar_confluencia(df_con_indicadores: pd.DataFrame) -> ResultadoConfluencia:
    """Evalúa la última fila del DataFrame (más reciente) y pondera
    cuántos indicadores coinciden en la misma dirección.

    Nunca dispara una señal por un solo indicador aislado — es la
    lógica de "confluencia" acordada con Compliance/Risk Manager.
    """
    ultima = df_con_indicadores.iloc[-1]
    senales: list[SenalIndicador] = []

    # --- Cruce de medias móviles ---
    if pd.notna(ultima.get("SMA_50")) and pd.notna(ultima.get("SMA_200")):
        if ultima["SMA_50"] > ultima["SMA_200"]:
            senales.append(
                SenalIndicador("cruce_medias", Direccion.ALCISTA, "SMA 50 > SMA 200")
            )
        elif ultima["SMA_50"] < ultima["SMA_200"]:
            senales.append(
                SenalIndicador("cruce_medias", Direccion.BAJISTA, "SMA 50 < SMA 200")
            )

    # --- RSI ---
    rsi = ultima.get("RSI_14")
    if pd.notna(rsi):
        if rsi < 30:
            senales.append(
                SenalIndicador("rsi", Direccion.ALCISTA, f"RSI en sobreventa ({rsi:.1f})")
            )
        elif rsi > 70:
            senales.append(
                SenalIndicador("rsi", Direccion.BAJISTA, f"RSI en sobrecompra ({rsi:.1f})")
            )

    # --- MACD (columna típica: MACDh_12_26_9 = histograma) ---
    macd_hist_col = next(
        (c for c in df_con_indicadores.columns if c.startswith("MACDh_")), None
    )
    if macd_hist_col and pd.notna(ultima.get(macd_hist_col)):
        hist = ultima[macd_hist_col]
        direccion = Direccion.ALCISTA if hist > 0 else Direccion.BAJISTA
        senales.append(SenalIndicador("macd", direccion, f"Histograma MACD {hist:.3f}"))

    # --- Volumen relativo (confirma, no dirige) ---
    vol_rel = ultima.get("Volumen_relativo")
    if pd.notna(vol_rel) and vol_rel > 1.5:
        # El volumen alto confirma la dirección dominante entre las señales ya vistas.
        alcistas_previas = sum(1 for s in senales if s.direccion == Direccion.ALCISTA)
        bajistas_previas = sum(1 for s in senales if s.direccion == Direccion.BAJISTA)
        if alcistas_previas > bajistas_previas:
            senales.append(
                SenalIndicador("volumen", Direccion.ALCISTA, f"Volumen {vol_rel:.1f}x el promedio")
            )
        elif bajistas_previas > alcistas_previas:
            senales.append(
                SenalIndicador("volumen", Direccion.BAJISTA, f"Volumen {vol_rel:.1f}x el promedio")
            )

    alcistas = sum(1 for s in senales if s.direccion == Direccion.ALCISTA)
    bajistas = sum(1 for s in senales if s.direccion == Direccion.BAJISTA)

    total_direccional = alcistas + bajistas
    if total_direccional == 0:
        fuerza = "baja"
    elif max(alcistas, bajistas) >= 3:
        fuerza = "alta"
    elif max(alcistas, bajistas) == 2:
        fuerza = "media"
    else:
        fuerza = "baja"

    if alcistas > bajistas:
        resumen = f"Confluencia alcista ({alcistas}/{len(senales)} indicadores)"
    elif bajistas > alcistas:
        resumen = f"Confluencia bajista ({bajistas}/{len(senales)} indicadores)"
    else:
        resumen = "Sin confluencia clara"

    return ResultadoConfluencia(
        senales=senales,
        indicadores_alcistas=alcistas,
        indicadores_bajistas=bajistas,
        fuerza=fuerza,
        resumen=resumen,
    )


def calcular_soporte_resistencia(
    df_con_indicadores: pd.DataFrame, ventana: int = 20
) -> tuple[float, float]:
    """Niveles técnicos genéricos del activo (soporte/resistencia por
    máximos/mínimos locales recientes). Usados como TP/SL genéricos —
    NUNCA derivados del monto invertido por un usuario específico.
    """
    recientes = df_con_indicadores.tail(ventana)
    soporte = float(recientes["Low"].min())
    resistencia = float(recientes["High"].max())
    return soporte, resistencia


def calcular_tp_sl_por_atr(
    precio_actual: float, atr: float, multiplo: float = 2.0
) -> tuple[float, float]:
    """Fallback cuando no hay soporte/resistencia claros: TP/SL basados
    en volatilidad (ATR)."""
    sl = precio_actual - (multiplo * atr)
    tp = precio_actual + (multiplo * atr)
    return sl, tp
