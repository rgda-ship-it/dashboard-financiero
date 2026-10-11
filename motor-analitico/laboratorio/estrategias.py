"""
Las estrategias de la primera ronda del laboratorio (doc 06 §3.6).

Todas las columnas que añaden son CAUSALES: la fila t solo depende de las
filas anteriores o de ella misma. `test_laboratorio.py` lo comprueba
recalculando sobre el histórico truncado.
"""

from __future__ import annotations

import hashlib

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


# ─────────────────────────────────────────────────────────────────────
# Segunda ronda (doc 06 §3.8): las estrategias del «Manual práctico de
# estrategias de trading» que se pueden probar con velas diarias.
# ─────────────────────────────────────────────────────────────────────

def _adx(df: pd.DataFrame, n: int = 14) -> pd.Series:
    serie = ta.adx(df["High"], df["Low"], df["Close"], length=n)
    if serie is None:
        return pd.Series(np.nan, index=df.index)
    return serie[f"ADX_{n}"]


class Retroceso:
    """Manual §2.1 y §3: swing tendencial, comprando el RETROCESO y no la
    ruptura. Contexto: cierre sobre la media de 50, con pendiente positiva
    (más alta que hace 10 días) y la de 20 sobre la de 50. Retroceso: en los
    últimos 3 días el mínimo tocó la media de 20. Confirmación: el cierre
    supera el máximo del día anterior. Stop bajo el mínimo de 5 días (y al
    menos a 1 ATR); objetivo a 2R (§3.4). Sale también si cierra bajo la
    media de 50 (la estructura se rompió)."""

    nombre = "retroceso"

    def __init__(self, objetivo_r: float = 2.0):
        self.objetivo_r = objetivo_r

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.copy()
        df["SMA_20"] = df["Close"].rolling(20).mean()
        df["SMA_50"] = df["Close"].rolling(50).mean()
        df["ATR_14"] = _atr(df)
        df["TOCO_20"] = (df["Low"] <= df["SMA_20"]).astype(float).rolling(3).max()
        df["MIN_5"] = df["Low"].rolling(5).min()
        return df

    def entrada(self, df, t):
        if t < 60:
            return None
        f, ayer = df.iloc[t], df.iloc[t - 1]
        if any(pd.isna(f[k]) for k in ("SMA_20", "SMA_50", "ATR_14", "TOCO_20", "MIN_5")):
            return None
        tendencia = (f["Close"] > f["SMA_50"] and f["SMA_50"] > df["SMA_50"].iloc[t - 10]
                     and f["SMA_20"] > f["SMA_50"])
        if not (tendencia and f["TOCO_20"] >= 1 and f["Close"] > ayer["High"]):
            return None
        sl = float(min(f["MIN_5"] - 0.25 * f["ATR_14"], f["Close"] - f["ATR_14"]))
        return Entrada(sl=sl, tp=float(f["Close"] + self.objetivo_r * (f["Close"] - sl)))

    def actualizar(self, df, t, pos: Posicion):
        f = df.iloc[t]
        return pos.sl, bool(not pd.isna(f["SMA_50"]) and f["Close"] < f["SMA_50"])


class RupturaVolumen(Tendencia):
    """Manual §2.2: la ruptura de Tendencia, pero solo si el volumen del día
    de la ruptura supera 1,5 veces su media de 20 días."""

    nombre = "ruptura_volumen"

    def __init__(self, factor_volumen: float = 1.5, **kw):
        super().__init__(**kw)
        self.factor_volumen = factor_volumen

    def preparar(self, df):
        df = super().preparar(df)
        df["VOL_MEDIO"] = df["Volume"].rolling(20).mean().shift(1)
        return df

    def entrada(self, df, t):
        ent = super().entrada(df, t)
        f = df.iloc[t]
        if ent is None or pd.isna(f["VOL_MEDIO"]) or f["VOL_MEDIO"] <= 0:
            return None
        return ent if f["Volume"] > self.factor_volumen * f["VOL_MEDIO"] else None


class Ruptura2R(Tendencia):
    """Manual §2.2 y §3.4: la misma ruptura, con el objetivo fijado de
    antemano a 2R y el stop quieto. Mide el consejo del manual frente a lo
    que hace Tendencia (sin objetivo, stop que sigue)."""

    nombre = "ruptura_2r"

    def __init__(self, objetivo_r: float = 2.0, **kw):
        super().__init__(**kw)
        self.objetivo_r = objetivo_r

    def entrada(self, df, t):
        ent = super().entrada(df, t)
        if ent is None:
            return None
        c = float(df["Close"].iloc[t])
        return Entrada(sl=ent.sl, tp=c + self.objetivo_r * (c - ent.sl))

    def actualizar(self, df, t, pos: Posicion):
        return pos.sl, False


class ReversionBollinger:
    """Manual §2.3, con lo que le faltaba a «reversion»: solo en mercado
    lateral (ADX 14 < 20), y no basta con estar en el extremo: ayer cerró
    bajo la banda inferior de Bollinger (20, 2) y hoy vuelve a cerrar dentro
    (rechazo del extremo). Stop bajo el mínimo de 3 días; objetivo en la
    media (la banda central). Sale a los 10 días si no llegó."""

    nombre = "reversion_bollinger"

    def __init__(self, adx_max: float = 20, dias_max: int = 10):
        self.adx_max, self.dias_max = adx_max, dias_max

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.copy()
        media = df["Close"].rolling(20).mean()
        desv = df["Close"].rolling(20).std(ddof=0)
        df["BB_MEDIA"], df["BB_INF"] = media, media - 2 * desv
        df["ADX_14"] = _adx(df)
        df["ATR_14"] = _atr(df)
        df["MIN_3"] = df["Low"].rolling(3).min()
        return df

    def entrada(self, df, t):
        if t < 1:
            return None
        f, ayer = df.iloc[t], df.iloc[t - 1]
        if any(pd.isna(x) for x in (f["BB_INF"], ayer["BB_INF"], f["ADX_14"], f["ATR_14"], f["MIN_3"])):
            return None
        if not (f["ADX_14"] < self.adx_max and ayer["Close"] < ayer["BB_INF"] and f["Close"] > f["BB_INF"]):
            return None
        if f["BB_MEDIA"] <= f["Close"]:
            return None
        return Entrada(sl=float(f["MIN_3"] - 0.25 * f["ATR_14"]), tp=float(f["BB_MEDIA"]))

    def actualizar(self, df, t, pos: Posicion):
        return pos.sl, (t - pos.indice_entrada + 1) >= self.dias_max


class Azar(Tendencia):
    """Referencia (doc 06 §3.10): las MISMAS salidas y el mismo filtro de
    fondo que tendencia (cierre sobre la media de 200, stop a 2 ATR que
    sigue a 3 ATR, salida bajo el mínimo de 10), pero entrando en días al
    azar (un 5 % de los días). Si esto también «tiene ventaja», lo que gana
    no es la señal, sino estar comprado en tendencia alcista con un buen
    stop, y el viento a favor del mercado.

    El azar es determinista y causal: depende solo de la fecha y del cierre
    de ese día, así que no cambia al truncar el histórico."""

    nombre = "azar"

    def __init__(self, probabilidad: float = 0.05, **kw):
        super().__init__(**kw)
        self.probabilidad = probabilidad

    def entrada(self, df, t):
        fila = df.iloc[t]
        if any(pd.isna(fila[k]) for k in ("SMA_200", "ATR_14")) or fila["Close"] <= fila["SMA_200"]:
            return None
        semilla = f"{df.index[t].value}-{float(fila['Close']):.6f}".encode()
        if int(hashlib.md5(semilla).hexdigest()[:8], 16) / 0xFFFFFFFF >= self.probabilidad:
            return None
        return Entrada(sl=float(fila["Close"] - self.stop_atr * fila["ATR_14"]))


ESTRATEGIAS = {"actual": Actual, "tendencia": Tendencia, "reversion": Reversion,
               "retroceso": Retroceso, "ruptura_volumen": RupturaVolumen,
               "ruptura_2r": Ruptura2R, "reversion_bollinger": ReversionBollinger,
               "azar": Azar}
