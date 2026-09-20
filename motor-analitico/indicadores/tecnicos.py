"""
Indicadores técnicos y lógica de confluencia.

Construido sobre `pandas-ta` (librería open source), tal como se acordó
con la restricción de usar únicamente herramientas de licencia libre.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

import numpy as np

# pandas-ta 0.4.71b0 (la versión fijada en requirements.txt) todavía hace
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


# Longitudes de ventana, expresadas en VELAS y no en días de calendario.
# Velas diarias: sesiones en acciones, días UTC en cripto. Esa es la
# equivalencia que hace comparables los umbrales entre las dos clases de
# activo — el 30/70 del RSI, el 14 de Wilder y los tramos de ATR% de
# riesgo/apalancamiento.py están calibrados sobre N observaciones, no
# sobre N días naturales. Estirar la ventana de cripto a 20 velas para
# "igualar" 14 sesiones cambiaría la distribución del indicador y
# obligaría a tener umbrales distintos por clase de activo.
VENTANA_SOPORTE_RESISTENCIA = 20
LONGITUD_ATR = 14


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


def _atr_sobre_maximos_y_minimos_reales(marco: pd.DataFrame) -> pd.Series:
    """ATR de Wilder calculado SOLO sobre las filas con High y Low reales.

    El conector de cripto entrega un frame mixto: ~366 días con cierre y
    volumen, pero solo los ~30 últimos con máximo y mínimo (las velas de
    4 h de CoinGecko no llegan más atrás). Pasar ese frame entero a
    `ta.atr` da un número mal, no un número con menos datos:

    pandas-ta 0.4.71b0 siembra la media de Wilder con la SMA de las 14
    primeras POSICIONES del frame (`presma`), que en el frame fusionado
    son justo las NaN, y su `rma` no aplica `min_periods`. El resultado
    es una media que arranca sin semilla y arrastra ese sesgo. Medido
    sobre BTC: 2.618 (3,21 % del precio) con el frame entero frente a
    2.253 (2,77 %) con el subconjunto — y esos dos valores caen en
    TRAMOS DE VOLATILIDAD DISTINTOS de riesgo/apalancamiento.py (medio
    frente a bajo), así que la diferencia no es cosmética: cambia el
    apalancamiento que ve el usuario.

    En acciones el subconjunto es el frame entero, así que el resultado
    es idéntico al de siempre.
    """
    hay_rango_real = marco["High"].notna() & marco["Low"].notna()
    subconjunto = marco.loc[hay_rango_real]

    # Con 14 filas o menos no hay ATR de Wilder: solo saldría la semilla
    # SMA sin un solo paso de suavizado. Antes que emitir esa cifra como
    # si fuera volatilidad medida, se declara ausente — y el modo
    # degradado de la regla 4 (apalancamiento al mínimo, fila no
    # operable) hace el resto.
    serie = pd.Series(np.nan, index=marco.index, dtype="float64")
    if len(subconjunto) <= LONGITUD_ATR:
        return serie

    atr = ta.atr(
        subconjunto["High"],
        subconjunto["Low"],
        subconjunto["Close"],
        length=LONGITUD_ATR,
    )
    if atr is None:
        return serie

    # Reinserción POSICIONAL y no por índice: el frame de cripto se indexa
    # por día UTC, pero los frames sintéticos de los tests usan un
    # RangeIndex, y un `reindex` por etiquetas rompería con cualquier
    # índice duplicado que llegue de un proveedor. Las posiciones son las
    # mismas que se extrajeron, así que no hay ambigüedad posible.
    serie.iloc[np.flatnonzero(hay_rango_real.to_numpy())] = atr.to_numpy()
    return serie


def calcular_indicadores(df: pd.DataFrame) -> pd.DataFrame:
    """Añade columnas de indicadores técnicos al DataFrame OHLCV.

    Espera columnas: Open, High, Low, Close (nombres de yfinance/
    normalizador). "Volume" es OPCIONAL y se degrada a NaN si falta.
    Desde que el conector de cripto reconstruye la vela diaria con
    /market_chart, las dos clases de activo SÍ traen volumen; la rama sin
    volumen se conserva por si un proveedor futuro no lo expone.

    High y Low pueden venir con NaN en las filas más antiguas (cripto):
    ver `_atr_sobre_maximos_y_minimos_reales`. No muta el DataFrame
    original.
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

    resultado["ATR_14"] = _atr_sobre_maximos_y_minimos_reales(resultado)

    # Históricamente CoinGecko servía /ohlc como [timestamp, open, high,
    # low, close] — sin volumen. Aquí se accedía a resultado["Volume"] sin
    # comprobar que existiera, así que TODOS los tickers cripto del
    # escáner morían con KeyError: 'Volume' y llegaban al frontend como
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
    df_con_indicadores: pd.DataFrame, ventana: int = VENTANA_SOPORTE_RESISTENCIA
) -> tuple[float, float]:
    """Niveles técnicos genéricos del activo (soporte/resistencia por
    máximos/mínimos locales recientes). Usados como TP/SL genéricos —
    NUNCA derivados del monto invertido por un usuario específico.

    La ventana son 20 VELAS: 20 sesiones en acciones, 20 días UTC en
    cripto.

    Si a alguna vela de la ventana le falta el máximo o el mínimo, se
    devuelve (nan, nan) en vez de un nivel. `.min()`/`.max()` de pandas
    saltan los NaN en silencio, así que una ventana con huecos habría
    devuelto el rango de las velas que sí tienen dato — es decir, una
    ventana MÁS CORTA que 20 presentada como si fueran 20. El llamador
    (`_niveles_tecnicos`) lee el nan y cae al fallback por ATR, que al
    menos declara su origen.
    """
    recientes = df_con_indicadores.tail(ventana)
    if recientes["High"].isna().any() or recientes["Low"].isna().any():
        return float("nan"), float("nan")

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
