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
from laboratorio.motor import Entrada, Parcial, Posicion


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


# ─────────────────────────────────────────────────────────────────────
# Momento relativo (doc 06 §3.11): la ventaja, si la hay, está en QUÉ
# acción se elige frente a las demás, no en CUÁNDO se entra. Es lo que la
# referencia al azar de §3.10 no puede imitar.
#
# Estas estrategias son CRUZADAS: su entrada depende de la clasificación
# del activo frente al resto del universo en cada fecha. El motor opera
# un activo cada vez, así que la clasificación se calcula antes, para
# todos a la vez (`anadir_rangos`), y llega a cada activo como una columna.
# ─────────────────────────────────────────────────────────────────────

class Momento:
    """Cada mes (primera sesión), clasifica el universo de su clase por la
    rentabilidad de los últimos 12 meses sin el último (12-1, el momento
    clásico: el último mes tiende a revertir). Entra en las `top` primeras y
    las mantiene mientras sigan entre las `mantener` primeras; si caen más
    abajo, sale al mes siguiente. Stop de catástrofe a `stop_atr` ATR, fijo:
    la salida normal es la rotación, no el stop. Sin objetivo."""

    nombre = "momento"
    cruzada = True

    def __init__(self, mirar: int = 252, saltar: int = 21, top: int = 10, mantener: int = 20,
                 stop_atr: float = 5.0):
        self.mirar, self.saltar = mirar, saltar
        self.top, self.mantener, self.stop_atr = top, mantener, stop_atr

    @property
    def columna(self) -> str:
        return f"RANGO_{self.nombre}"

    def puntuar(self, df: pd.DataFrame) -> pd.Series:
        """Puntuación causal de cada día; mayor es mejor. NaN = no compite."""
        return df["Close"].shift(self.saltar) / df["Close"].shift(self.mirar) - 1

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.copy()
        df["ATR_14"] = _atr(df)
        meses = df.index.to_period("M")
        df["REBALANCEO"] = np.r_[False, meses[1:] != meses[:-1]]
        if self.columna not in df.columns:
            df[self.columna] = np.nan
        return df

    def entrada(self, df, t):
        f = df.iloc[t]
        if not f["REBALANCEO"] or pd.isna(f[self.columna]) or pd.isna(f["ATR_14"]) or f["ATR_14"] <= 0:
            return None
        if f[self.columna] > self.top:
            return None
        return Entrada(sl=float(f["Close"] - self.stop_atr * f["ATR_14"]))

    def actualizar(self, df, t, pos: Posicion):
        f = df.iloc[t]
        salir = bool(f["REBALANCEO"] and (pd.isna(f[self.columna]) or f[self.columna] > self.mantener))
        return pos.sl, salir


class AzarMomento(Momento):
    """Referencia del momento: las MISMAS reglas (rotación mensual, `top`,
    `mantener`, stop), pero clasificando por una puntuación al azar entre
    los mismos activos que compiten. Si el momento no supera a esto, elegir
    por fuerza relativa no aporta nada frente a elegir a ciegas en el
    mismo universo y con el mismo viento a favor.

    El azar es determinista y causal: depende solo de la fecha, del cierre
    de ese día y de la `semilla`. Una sola tirada es ruidosa: para juzgar
    el momento hay que compararlo con muchas semillas (doc 06 §3.11)."""

    nombre = "azar_momento"

    def __init__(self, semilla: int = 0, **kw):
        super().__init__(**kw)
        self.semilla = semilla

    def puntuar(self, df: pd.DataFrame) -> pd.Series:
        base = super().puntuar(df)
        azar = [int(hashlib.md5(f"{self.semilla}-{i.value}-{c:.6f}".encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
                for i, c in zip(df.index, df["Close"].astype(float))]
        return pd.Series(azar, index=df.index).where(base.notna())


def anadir_rangos(datos: dict, estrategia) -> dict:
    """{(simbolo, clase): df} con la columna de rango de una estrategia
    cruzada: 1 = la mejor puntuación de su clase ese día. Causal: el rango
    del día t solo usa las puntuaciones del día t, que solo usan datos
    hasta t. Las estrategias que no son cruzadas devuelven `datos` tal cual."""
    if not getattr(estrategia, "cruzada", False):
        return datos
    salida = {}
    for clase in sorted({c for _, c in datos}):
        claves = [k for k in datos if k[1] == clase]
        puntos = pd.DataFrame({k[0]: estrategia.puntuar(datos[k]) for k in claves})
        rangos = puntos.rank(axis=1, ascending=False, method="first")
        for k in claves:
            df = datos[k].copy()
            df[estrategia.columna] = rangos[k[0]].reindex(df.index)
            salida[k] = df
    return salida


# ---------------------------------------------------------------------------
# Fase 3 (doc fase-3/01 §5): los agentes con metas, como operan de verdad
# ---------------------------------------------------------------------------

# Condiciones de entrada que una hipótesis puede añadir. El catálogo es el
# MISMO que `fn_condiciones_dia` en SQL (0046): lo que la fuente H2 mide en
# producción es lo que el laboratorio sabe probar.
CONDICIONES = {
    "sobre_sma50": lambda f: f["Close"] > f["SMA_50"],
    "sobre_sma200": lambda f: f["Close"] > f["SMA_200"],
    "cruce_medias": lambda f: f["SMA_50"] > f["SMA_200"],
    "macd_positivo": lambda f: f["MACD_HIST"] > 0,
    "rsi_50_70": lambda f: 50 <= f["RSI_14"] <= 70,
    "rsi_bajo_35": lambda f: f["RSI_14"] < 35,
    "ruptura_20": lambda f: f["Close"] > f["MAX_20"],
    "volumen_alto": lambda f: f["Volumen_relativo"] > 1.5,
}

_RANGO_FUERZA = {"baja": 1, "media": 2, "alta": 3}


def cumple(fila: pd.Series, condicion: str) -> bool:
    """¿Cumple la fila todas las condiciones de «a+b»? Sin dato, no (una
    comparación con NaN es falsa). Un nombre fuera del catálogo es un error."""
    nombres = [n for n in condicion.split("+") if n]
    return bool(nombres) and all(bool(CONDICIONES[n](fila)) for n in nombres)


class Agente(Actual):
    """Lo que hace un agente con metas, con cada pieza encendible:

    · entrada de `Actual` (confluencia alcista media o alta, niveles en ATR)
      con su R:R mínimo y su banda de volatilidad (`atr_min`, `atr_max`, en
      % del precio; 0 = sin límite);
    · `condicion`: entra TAMBIÉN cuando se cumple una condición del
      catálogo (fuente H2), con los mismos niveles y filtros;
    · `deterioro`: sale en la apertura siguiente tras DOS cierres seguidos
      con la señal peor que al entrar (0043): menos indicadores alcistas
      que bajistas, o menos fuerza;
    · `parcial_recorrido` > 0: toma parcial de `parcial_fraccion` y, con
      `parcial_mover`, stop a la entrada;
    · `sigue_atr` > 0: stop que sigue al mejor cierre a esa distancia en ATR.

    Lo que no reproduce (doc fase-3/01 §5): la rotación y el reparto, que
    dependen de la cartera entera, y la cadencia intradía (aquí, un día es
    una lectura)."""

    nombre = "agente"

    def __init__(self, rr_minimo: float = 1.2, atr_min: float = 0.0, atr_max: float = 0.0,
                 condicion: str = "", deterioro: int = 0, parcial_recorrido: float = 0.0,
                 parcial_fraccion: float = 0.5, parcial_mover: int = 0, sigue_atr: float = 0.0):
        super().__init__(rr_minimo=rr_minimo)
        self.atr_min, self.atr_max = atr_min, atr_max
        self.condicion = str(condicion or "")
        self.deterioro = bool(deterioro)
        self.parcial = (Parcial(parcial_recorrido, parcial_fraccion, bool(parcial_mover))
                        if parcial_recorrido > 0 else None)
        self.sigue_atr = sigue_atr

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        df = super().preparar(df)
        hist = next((c for c in df.columns if c.startswith("MACDh_")), None)
        df["MACD_HIST"] = df[hist] if hist else np.nan
        df["MAX_20"] = df["High"].rolling(20).max().shift(1)
        return df

    def _confluencia(self, df: pd.DataFrame, t: int):
        return evaluar_confluencia(df.iloc[: t + 1])

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        if t < 199:
            return None
        fila = df.iloc[t]
        precio, atr = float(fila["Close"]), fila["ATR_14"]
        if pd.isna(atr) or atr <= 0:
            return None
        atr_pct = atr / precio * 100
        if (self.atr_min and atr_pct < self.atr_min) or (self.atr_max and atr_pct > self.atr_max):
            return None
        conf = self._confluencia(df, t)
        por_confluencia = (conf.indicadores_alcistas > conf.indicadores_bajistas
                           and conf.fuerza in ("media", "alta"))
        if not por_confluencia and not (self.condicion and cumple(fila, self.condicion)):
            return None
        soporte, resistencia = calcular_soporte_resistencia(df.iloc[: t + 1])
        if (pd.isna(soporte) or pd.isna(resistencia) or resistencia - soporte < atr):
            soporte, resistencia = precio - 2 * atr, precio + 2 * atr
        sl, tp = calcular_niveles_operativos(precio, float(soporte), float(resistencia), float(atr))
        if (tp - precio) / (precio - sl) < self.rr_minimo:
            return None
        return Entrada(sl=sl, tp=tp, parcial=self.parcial,
                       datos={"fuerza_entrada": conf.fuerza if por_confluencia else "baja"})

    def actualizar(self, df, t, pos: Posicion):
        sl = pos.sl
        if self.sigue_atr > 0 and not pd.isna(df["ATR_14"].iloc[t]):
            sl = max(sl, pos.mejor_cierre - self.sigue_atr * float(df["ATR_14"].iloc[t]))
        if not self.deterioro:
            return sl, False
        conf = self._confluencia(df, t)
        peor = (conf.indicadores_alcistas <= conf.indicadores_bajistas
                or _RANGO_FUERZA[conf.fuerza] < _RANGO_FUERZA[pos.datos.get("fuerza_entrada", "baja")])
        dos_seguidas = peor and pos.datos.get("deterioro_previo", False)
        pos.datos["deterioro_previo"] = peor
        return sl, dos_seguidas


ESTRATEGIAS = {"actual": Actual, "tendencia": Tendencia, "reversion": Reversion,
               "retroceso": Retroceso, "ruptura_volumen": RupturaVolumen,
               "ruptura_2r": Ruptura2R, "reversion_bollinger": ReversionBollinger,
               "azar": Azar, "momento": Momento, "azar_momento": AzarMomento,
               "agente": Agente}
