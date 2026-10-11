"""
Las estrategias de la primera ronda del laboratorio (doc 06 §3.6).

Todas las columnas que añaden son CAUSALES: la fila t solo depende de las
filas anteriores o de ella misma. `test_laboratorio.py` lo comprueba
recalculando sobre el histórico truncado.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pandas_ta as ta

from indicadores.tecnicos import (
    calcular_indicadores,
    calcular_niveles_operativos,
    calcular_soporte_resistencia,
    evaluar_confluencia,
)
from laboratorio.motor import Entrada, Posicion


def _atr(df: pd.DataFrame, n: int = 14) -> pd.Series:
    serie = ta.atr(df["High"], df["Low"], df["Close"], length=n)
    return serie if serie is not None else pd.Series(np.nan, index=df.index)


class Actual:
    """La de hoy: confluencia alcista media o alta y niveles acotados en
    ATR (D21), con el R:R mínimo más permisivo de los agentes (Audacia)."""

    nombre = "actual"

    def __init__(self, rr_minimo: float = 1.2):
        self.rr_minimo = rr_minimo

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        return calcular_indicadores(df)

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        ventana = df.iloc[: t + 1]
        if len(ventana) < 200:
            return None
        conf = evaluar_confluencia(ventana)
        if not (conf.indicadores_alcistas > conf.indicadores_bajistas
                and conf.fuerza in ("media", "alta")):
            return None
        precio = float(df["Close"].iloc[t])
        atr = df["ATR_14"].iloc[t]
        if pd.isna(atr) or atr <= 0:
            return None
        soporte, resistencia = calcular_soporte_resistencia(ventana)
        if (pd.isna(soporte) or pd.isna(resistencia) or resistencia - soporte < atr):
            soporte, resistencia = precio - 2 * atr, precio + 2 * atr
        sl, tp = calcular_niveles_operativos(precio, float(soporte), float(resistencia), float(atr))
        if (tp - precio) / (precio - sl) < self.rr_minimo:
            return None
        return Entrada(sl=sl, tp=tp)

    def actualizar(self, df, t, pos: Posicion):
        return pos.sl, False


class Tendencia:
    """Ruptura del máximo de 20 días a favor de la tendencia de fondo, con
    stop que sigue al precio. Sin objetivo: deja correr lo que funciona."""

    nombre = "tendencia"

    def __init__(self, ruptura: int = 20, salida: int = 10, stop_atr: float = 2.0, sigue_atr: float = 3.0):
        self.ruptura, self.salida = ruptura, salida
        self.stop_atr, self.sigue_atr = stop_atr, sigue_atr

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.copy()
        df["SMA_200"] = df["Close"].rolling(200).mean()
        df["ATR_14"] = _atr(df)
        df["MAX_RUPTURA"] = df["High"].rolling(self.ruptura).max().shift(1)
        df["MIN_SALIDA"] = df["Low"].rolling(self.salida).min().shift(1)
        return df

    def entrada(self, df, t):
        fila = df.iloc[t]
        if any(pd.isna(fila[k]) for k in ("SMA_200", "ATR_14", "MAX_RUPTURA")):
            return None
        if fila["Close"] > fila["MAX_RUPTURA"] and fila["Close"] > fila["SMA_200"]:
            return Entrada(sl=float(fila["Close"] - self.stop_atr * fila["ATR_14"]))
        return None

    def actualizar(self, df, t, pos: Posicion):
        fila = df.iloc[t]
        sigue = pos.mejor_cierre - self.sigue_atr * fila["ATR_14"] if not pd.isna(fila["ATR_14"]) else pos.sl
        salir = not pd.isna(fila["MIN_SALIDA"]) and fila["Close"] < fila["MIN_SALIDA"]
        return float(sigue), bool(salir)


class Reversion:
    """Sobreventa de muy corto plazo (RSI de 2 días) dentro de una tendencia
    alcista de fondo. Sale en cuanto el precio recupera su media corta."""

    nombre = "reversion"

    def __init__(self, umbral_rsi: float = 10, dias_max: int = 5, stop_atr: float = 3.0):
        self.umbral_rsi, self.dias_max, self.stop_atr = umbral_rsi, dias_max, stop_atr

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.copy()
        df["SMA_200"] = df["Close"].rolling(200).mean()
        df["SMA_5"] = df["Close"].rolling(5).mean()
        rsi = ta.rsi(df["Close"], length=2)
        df["RSI_2"] = rsi if rsi is not None else np.nan
        df["ATR_14"] = _atr(df)
        return df

    def entrada(self, df, t):
        fila = df.iloc[t]
        if any(pd.isna(fila[k]) for k in ("SMA_200", "RSI_2", "ATR_14")):
            return None
        if fila["Close"] > fila["SMA_200"] and fila["RSI_2"] < self.umbral_rsi:
            return Entrada(sl=float(fila["Close"] - self.stop_atr * fila["ATR_14"]))
        return None

    def actualizar(self, df, t, pos: Posicion):
        fila = df.iloc[t]
        dias = t - pos.indice_entrada + 1
        salir = (not pd.isna(fila["SMA_5"]) and fila["Close"] > fila["SMA_5"]) or dias >= self.dias_max
        return pos.sl, bool(salir)


ESTRATEGIAS = {"actual": Actual, "tendencia": Tendencia, "reversion": Reversion}
