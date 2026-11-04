#!/usr/bin/env python3
"""
Modo de 1 hora del laboratorio (doc fase-3/08 §4.3; doc fase-3/10).

    python -m laboratorio.intradia --estrategia rebote_caida --semillas 20
    python -m laboratorio.intradia --estrategia ruptura_primera_hora
    python -m laboratorio.intradia --estrategia hueco_resultados

El motor es el mismo que el diario: trabaja por VELAS, no por días, así que
con velas de 1 hora cada fila es una hora. Las reglas de ejecución no
cambian: la señal al cierre de la hora t, la entrada en la apertura de
t + 1 con medio spread, stop y objetivo con el máximo y el mínimo de cada
hora, el stop gana el empate. Yahoo da unos 730 días de velas horarias.

Qué prueba: «pocas entradas, en momentos concretos, para una ganancia
rápida» (idea del dueño, 2026-11-03): el rebote tras una caída brusca en
cripto (`ReboteCaida`), la ruptura de la primera hora en acciones
(`RupturaPrimeraHora`) y el hueco del día de resultados (`HuecoResultados`).
La deriva tras resultados (`DerivaResultados`) usa el mismo método con velas
diarias (`CARGA`).
Cómo se juzga:

  1. Una rejilla pequeña, fijada antes de mirar los datos, sobre el tramo
     de DISEÑO (el 70 % inicial del calendario). Se elige la combinación
     de mejor expectativa con al menos 30 operaciones.
  2. Esa combinación, y solo esa, se juzga en VALIDACIÓN (el 30 % final)
     con el criterio del laboratorio (`metricas.veredicto`).
  3. Frente al azar: las MISMAS salidas entrando a horas al azar con la
     misma frecuencia, en `--semillas` tiradas. Aporta si en validación
     supera al 90 % de ellas, más un punto por cada prueba anterior de este
     modo (`PRUEBAS_PREVIAS`): probar mucho no regala validaciones.

Las estrategias de 1 hora no están en `estrategias.ESTRATEGIAS`: el
laboratorio diario las correría con velas diarias.

Escribe `intradia.md` en la carpeta de salida y, en GitHub Actions, en el
resumen del job.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import os
import pickle
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.datos import (cargar, cargar_resultados, financiacion_de, spread_de,  # noqa: E402
                               universo_nombrado)
from laboratorio.estrategias import _atr  # noqa: E402
from laboratorio.motor import Entrada, Posicion, simular  # noqa: E402

PERCENTIL_MINIMO = 90
BARRAS_MES = {"cripto": 24 * 30, "accion": 7 * 21}   # velas de 1 hora en un mes
PERIODO = "730d"                                     # lo máximo que da Yahoo en 1 hora


class ReboteCaida:
    """Rebote tras una caída brusca (doc fase-3/10 §2). Al cierre de una
    hora, si el precio está `caida_atr` ATR de 1 hora por debajo del máximo
    de las últimas `ventana` horas, se compra en la apertura siguiente.
    Stop a `stop_atr` ATR y objetivo a `objetivo_atr` ATR del cierre de la
    señal; si no toca ninguno, se sale a las `horas` horas.

    El ATR es el de `atr_n` horas e incluye las de la caída: es causal, y
    tras un desplome el stop queda más ancho, como lo pondría el agente."""

    nombre = "rebote_caida"

    def __init__(self, caida_atr: float = 6.0, ventana: int = 6, atr_n: int = 48,
                 stop_atr: float = 2.0, objetivo_atr: float = 2.0, horas: int = 12):
        self.caida_atr, self.ventana, self.atr_n = caida_atr, ventana, atr_n
        self.stop_atr, self.objetivo_atr, self.horas = stop_atr, objetivo_atr, horas

    @classmethod
    def precalcular(cls, df: pd.DataFrame) -> pd.DataFrame:
        """Lo que no depende de la rejilla: se calcula una vez."""
        out = df.copy()
        out["ATR_H"] = _atr(df, cls().atr_n)
        return out

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy() if "ATR_H" in df.columns else self.precalcular(df)
        maximo = out["High"].rolling(self.ventana, min_periods=self.ventana).max()
        out["CAIDA_ATR"] = (maximo - out["Close"]) / out["ATR_H"]
        return out

    def _niveles(self, df: pd.DataFrame, t: int) -> Entrada | None:
        atr = df["ATR_H"].iloc[t]
        if pd.isna(atr) or atr <= 0:
            return None
        c = float(df["Close"].iloc[t])
        return Entrada(sl=c - self.stop_atr * float(atr), tp=c + self.objetivo_atr * float(atr))

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        caida = df["CAIDA_ATR"].iloc[t]
        if pd.isna(caida) or caida < self.caida_atr:
            return None
        return self._niveles(df, t)

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion):
        # Salida por tiempo: tras `horas` velas abierta, en la apertura siguiente.
        return pos.sl, t - pos.indice_entrada >= self.horas - 1


class AzarRebote(ReboteCaida):
    """La referencia de `ReboteCaida`: las mismas salidas (stop, objetivo y
    tiempo en ATR de 1 hora), entrando a horas al azar con probabilidad
    `probabilidad`. Determinista y causal: depende de la semilla, la hora y
    el cierre de esa hora."""

    nombre = "azar_rebote"

    def __init__(self, probabilidad: float = 0.01, semilla: int = 0, **kw):
        super().__init__(**kw)
        self.probabilidad, self.semilla = probabilidad, semilla

    def entrada(self, df, t):
        clave = f"{self.semilla}-{df.index[t].value}-{float(df['Close'].iloc[t]):.6f}".encode()
        if int(hashlib.md5(clave).hexdigest()[:8], 16) / 0xFFFFFFFF >= self.probabilidad:
            return None
        return self._niveles(df, t)


class RupturaPrimeraHora:
    """Ruptura del rango de la primera hora en acciones (doc fase-3/10 §6).
    La primera vela de la sesión (9:30–10:30 de Nueva York) marca un
    máximo y un mínimo. El PRIMER cierre de una hora por encima de ese
    máximo, entre las 10:30 y las 13:30, compra en la apertura siguiente.

    · Stop: el mínimo de la primera hora (`stop="rango"`) o la mitad del
      rango (`stop="mitad"`).
    · Objetivo: `objetivo_r` veces el riesgo (0 = sin objetivo).
    · Nunca pasa la noche: sale en la apertura de la última vela (15:30).
    · Una entrada al día como mucho, y solo en sesiones completas (7 velas;
      las sesiones cortas están en el calendario de la bolsa)."""

    nombre = "ruptura_primera_hora"
    ULTIMA_SENAL = 4        # la vela de las 13:30: entra a las 14:30 como tarde
    SALIDA = 5              # al cierre de la vela de las 14:30, sale a las 15:30

    def __init__(self, stop: str = "rango", objetivo_r: float = 0.0):
        self.stop, self.objetivo_r = stop, objetivo_r
        self._dias: set = set()

    @classmethod
    def precalcular(cls, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy()
        dia = out.index.normalize()
        g = out.groupby(dia)
        out["N_DIA"] = g.cumcount()
        out["VELAS_DIA"] = g["Close"].transform("size")
        out["MAX_1H"] = g["High"].transform("first")
        out["MIN_1H"] = g["Low"].transform("first")
        # ¿Algún cierre anterior de la sesión estaba ya por encima del máximo?
        encima = (out["Close"] > out["MAX_1H"]).astype(int)
        out["YA_ROTO"] = encima.groupby(dia).cummax().groupby(dia).shift(1).fillna(0).astype(bool)
        return out

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        self._dias = set()      # una simulación por activo
        return df.copy() if "N_DIA" in df.columns else self.precalcular(df)

    def _elegible(self, df: pd.DataFrame, t: int) -> bool:
        fila = df.iloc[t]
        return bool(fila["VELAS_DIA"] == 7 and 1 <= fila["N_DIA"] <= self.ULTIMA_SENAL
                    and df.index[t].normalize() not in self._dias)

    def _riesgo(self, df: pd.DataFrame, t: int) -> float:
        rango = float(df["MAX_1H"].iloc[t] - df["MIN_1H"].iloc[t])
        return rango if self.stop == "rango" else rango / 2

    def _con_objetivo(self, df: pd.DataFrame, t: int, c: float, sl: float) -> Entrada:
        # El día se marca al dar la señal: si el stop salta en la misma hora
        # de la entrada, `actualizar` no llega a llamarse.
        self._dias.add(df.index[t].normalize())
        return Entrada(sl=sl, tp=c + self.objetivo_r * (c - sl) if self.objetivo_r > 0 else None)

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        if not self._elegible(df, t):
            return None
        fila = df.iloc[t]
        c = float(fila["Close"])
        if c <= fila["MAX_1H"] or fila["YA_ROTO"]:
            return None
        sl = float(fila["MIN_1H"]) if self.stop == "rango" else float(fila["MAX_1H"] + fila["MIN_1H"]) / 2
        return self._con_objetivo(df, t, c, sl)

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion):
        return pos.sl, bool(df["N_DIA"].iloc[t] >= self.SALIDA)


class AzarPrimeraHora(RupturaPrimeraHora):
    """La referencia de `RupturaPrimeraHora`: entra a una hora al azar del
    mismo tramo (10:30–13:30), con un stop del MISMO tamaño (el rango de la
    primera hora o su mitad, bajo el cierre), el mismo objetivo en R y la
    misma salida. Lo único que cambia es que no hace falta romper el
    máximo."""

    nombre = "azar_primera_hora"

    def __init__(self, probabilidad: float = 0.1, semilla: int = 0, **kw):
        super().__init__(**kw)
        self.probabilidad, self.semilla = probabilidad, semilla

    def entrada(self, df, t):
        if not self._elegible(df, t):
            return None
        clave = f"{self.semilla}-{df.index[t].value}-{float(df['Close'].iloc[t]):.6f}".encode()
        if int(hashlib.md5(clave).hexdigest()[:8], 16) / 0xFFFFFFFF >= self.probabilidad:
            return None
        riesgo = self._riesgo(df, t)
        if not riesgo > 0:
            return None
        c = float(df["Close"].iloc[t])
        return self._con_objetivo(df, t, c, c - riesgo)


class HuecoResultados:
    """El hueco del día de resultados (doc fase-3/10 §7). En la sesión que
    reacciona a unos resultados (`datos.cargar_resultados`), si abre con un
    hueco de al menos `hueco_atr` ATR diarios sobre el cierre anterior y la
    primera hora cierra a favor del hueco, se entra en la apertura de las
    10:30 en la dirección del hueco: en largo si sube, en corto si baja.

    · Stop: el otro extremo de la primera hora (el mínimo en largo, el
      máximo en corto).
    · Sin objetivo. Sale en la apertura de la última vela (15:30) de la
      sesión `sesiones`-ésima contando la de la entrada: 1 = el mismo día;
      más = deja correr la deriva tras los resultados.
    · El ATR diario es el de las `ATR_N` sesiones anteriores, con velas
      diarias hechas con las de 1 hora; solo sesiones completas (7 velas)."""

    nombre = "hueco_resultados"
    SALIDA = 5              # al cierre de la vela de las 14:30, sale a las 15:30
    ATR_N = 14

    def __init__(self, hueco_atr: float = 1.0, sesiones: int = 1):
        self.hueco_atr, self.sesiones = hueco_atr, sesiones

    @classmethod
    def precalcular(cls, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy()
        dia = out.index.normalize()
        g = out.groupby(dia)
        out["N_DIA"] = g.cumcount()
        out["VELAS_DIA"] = g["Close"].transform("size")
        diario = pd.DataFrame({"Open": g["Open"].first(), "High": g["High"].max(),
                               "Low": g["Low"].min(), "Close": g["Close"].last()})
        previo = diario["Close"].shift(1)
        rango = pd.concat([diario["High"] - diario["Low"], (diario["High"] - previo).abs(),
                           (diario["Low"] - previo).abs()], axis=1).max(axis=1)
        # El ATR de las sesiones ANTERIORES: a la apertura de hoy ya se sabe.
        atr = rango.rolling(cls.ATR_N, min_periods=cls.ATR_N).mean().shift(1)
        out["HUECO_ATR"] = ((diario["Open"] - previo) / atr).reindex(dia).to_numpy()
        out["SESION"] = pd.Series(np.arange(len(diario)), index=diario.index).reindex(dia).to_numpy()
        if "DIA_RESULTADOS" not in out.columns:
            out["DIA_RESULTADOS"] = False
        return out

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        return df.copy() if "HUECO_ATR" in df.columns else self.precalcular(df)

    def _elegible(self, df: pd.DataFrame, t: int) -> bool:
        fila = df.iloc[t]
        return bool(fila["N_DIA"] == 0 and fila["VELAS_DIA"] == 7 and not pd.isna(fila["HUECO_ATR"]))

    @staticmethod
    def _niveles(df: pd.DataFrame, t: int, lado: str) -> Entrada | None:
        fila = df.iloc[t]
        if not fila["High"] > fila["Low"]:
            return None
        return Entrada(sl=float(fila["Low"] if lado == "largo" else fila["High"]), lado=lado)

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        if not self._elegible(df, t) or not df["DIA_RESULTADOS"].iloc[t]:
            return None
        fila = df.iloc[t]
        hueco = float(fila["HUECO_ATR"])
        if hueco >= self.hueco_atr and fila["Close"] >= fila["Open"]:
            return self._niveles(df, t, "largo")
        if hueco <= -self.hueco_atr and fila["Close"] <= fila["Open"]:
            return self._niveles(df, t, "corto")
        return None

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion):
        transcurridas = df["SESION"].iloc[t] - df["SESION"].iloc[pos.indice_entrada]
        return pos.sl, bool(transcurridas >= self.sesiones - 1 and df["N_DIA"].iloc[t] >= self.SALIDA)


class AzarHueco(HuecoResultados):
    """La referencia de `HuecoResultados`: un día cualquiera al azar (haya
    resultados o no, sin mirar el hueco), en la dirección de la primera
    hora, con el mismo stop y la misma salida. Mide si el día de resultados
    con hueco aporta algo sobre seguir a la primera hora un día normal."""

    nombre = "azar_hueco"

    def __init__(self, probabilidad: float = 0.01, semilla: int = 0, **kw):
        super().__init__(**kw)
        self.probabilidad, self.semilla = probabilidad, semilla

    def entrada(self, df, t):
        if not self._elegible(df, t):
            return None
        clave = f"{self.semilla}-{df.index[t].value}-{float(df['Close'].iloc[t]):.6f}".encode()
        if int(hashlib.md5(clave).hexdigest()[:8], 16) / 0xFFFFFFFF >= self.probabilidad:
            return None
        return self._niveles(df, t, "largo" if df["Close"].iloc[t] >= df["Open"].iloc[t] else "corto")


def con_dia_resultados(df: pd.DataFrame, reaccion: pd.DatetimeIndex) -> pd.DataFrame:
    """Marca DIA_RESULTADOS en las velas de las sesiones que reaccionan a
    unos resultados."""
    out = df.copy()
    out["DIA_RESULTADOS"] = out.index.normalize().isin(reaccion)
    return out


class DerivaResultados:
    """La deriva tras unos resultados con hueco, con velas DIARIAS (doc
    fase-3/10 §8). Es lo único con algo de vida del §7, que con velas de 1
    hora no tenía casos para validar. Al cierre de la sesión que reacciona
    a unos resultados, si abrió con un hueco de al menos `hueco_atr` ATR
    (el de 14 sesiones, hasta la víspera) y cerró a favor del hueco, se
    entra en la apertura siguiente en la dirección del hueco.

    · Stop: el otro extremo de la sesión de resultados (el mínimo en
      largo, el máximo en corto). Sin objetivo.
    · Sale en la apertura siguiente a `sesiones` sesiones dentro."""

    nombre = "deriva_resultados"

    def __init__(self, hueco_atr: float = 1.0, sesiones: int = 10):
        self.hueco_atr, self.sesiones = hueco_atr, sesiones

    @classmethod
    def precalcular(cls, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy()
        atr = _atr(df, 14).shift(1)
        out["HUECO_ATR"] = (out["Open"] - out["Close"].shift(1)) / atr
        if "DIA_RESULTADOS" not in out.columns:
            out["DIA_RESULTADOS"] = False
        return out

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        return df.copy() if "HUECO_ATR" in df.columns else self.precalcular(df)

    def _elegible(self, df: pd.DataFrame, t: int) -> bool:
        return not pd.isna(df["HUECO_ATR"].iloc[t])

    _niveles = staticmethod(HuecoResultados._niveles)
    entrada = HuecoResultados.entrada

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion):
        return pos.sl, t - pos.indice_entrada >= self.sesiones - 1


class AzarDeriva(DerivaResultados):
    """La referencia de `DerivaResultados`: un día cualquiera al azar, en la
    dirección de esa sesión, con el mismo stop y la misma salida."""

    nombre = "azar_deriva"

    def __init__(self, probabilidad: float = 0.01, semilla: int = 0, **kw):
        super().__init__(**kw)
        self.probabilidad, self.semilla = probabilidad, semilla

    entrada = AzarHueco.entrada


# (estrategia, su referencia al azar, clase de activo)
ESTRATEGIAS_1H = {"rebote_caida": (ReboteCaida, AzarRebote, "cripto"),
                  "ruptura_primera_hora": (RupturaPrimeraHora, AzarPrimeraHora, "accion"),
                  "hueco_resultados": (HuecoResultados, AzarHueco, "accion"),
                  "deriva_resultados": (DerivaResultados, AzarDeriva, "accion")}

# De dónde salen los activos y si hacen falta los días de resultados. Con
# las 21 acciones del universo activo hay unos 250 días de resultados en
# tres años, pocos para validar: el hueco usa el S&P 100. La deriva usa el
# mismo método con velas diarias de 10 años.
CARGA = {"hueco_resultados": {"universo": "sp100", "resultados": True},
         "deriva_resultados": {"universo": "sp100", "resultados": True, "intervalo": "1d", "periodo": "10y"}}

# La rejilla de cada estrategia, fijada ANTES de mirar los datos (doc
# fase-3/10 §2 y §6), toda sobre el tramo de diseño.
REJILLAS = {"rebote_caida": {"caida_atr": (4.0, 6.0, 8.0), "horas": (6, 12, 24)},
            "ruptura_primera_hora": {"stop": ("rango", "mitad"), "objetivo_r": (0.0, 1.0, 2.0)},
            "hueco_resultados": {"hueco_atr": (0.5, 1.0, 2.0), "sesiones": (1, 5)},
            "deriva_resultados": {"hueco_atr": (0.5, 1.0, 2.0), "sesiones": (5, 10, 20)}}

# Pruebas de este modo hechas antes de cada estrategia: el percentil exigido
# frente al azar sube un punto por cada una.
PRUEBAS_PREVIAS = {"rebote_caida": 0, "ruptura_primera_hora": 1, "hueco_resultados": 2,
                   "deriva_resultados": 3}


def operar(datos: dict, estrategia) -> list:
    return [o for (s, c), df in datos.items()
            for o in simular(df, estrategia, spread_de(s, c), s, c, financiacion_corto_pct=financiacion_de(c))]


def barras_mes(clase: str, intervalo: str = "1h") -> int:
    return 21 if intervalo == "1d" else BARRAS_MES[clase]


def medir(ops: list, clase: str, intervalo: str = "1h") -> metricas.Medidas | None:
    return metricas.medir(ops, barras_mes=barras_mes(clase, intervalo))


def _fila(nombre: str, m: metricas.Medidas | None, unidad: str = "h") -> str:
    if m is None:
        return f"| {nombre} | 0 | — | — | — | — | — |"
    return (f"| {nombre} | {m.operaciones} | {m.expectativa_r:+.3f} R | {m.ic90[0]:+.3f} – {m.ic90[1]:+.3f} | "
            f"{m.aciertos_pct:.0f} % | {m.coste_pct:.0f} % | {m.dias_medios:.1f} {unidad} |")


def informe(nombre: str, datos: dict, semillas: int = 20) -> str:
    base, azar, clase = ESTRATEGIAS_1H[nombre]
    intervalo = CARGA.get(nombre, {}).get("intervalo", "1h")
    unidad, vela = ("ses.", "diarias") if intervalo == "1d" else ("h", "de 1 hora")
    minimo = PERCENTIL_MINIMO + PRUEBAS_PREVIAS[nombre]
    desde = min(df.index[0] for df in datos.values())
    hasta = max(df.index[-1] for df in datos.values())
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO
    rejilla = REJILLAS[nombre]
    claves = list(rejilla)

    datos = {k: base.precalcular(df) for k, df in datos.items()}

    resultados = {}
    for valores in itertools.product(*(rejilla[k] for k in claves)):
        params = dict(zip(claves, valores))
        ops = operar(datos, base(**params))
        d, v = metricas.partir(ops, corte)
        resultados[valores] = (params, ops, medir(d, clase, intervalo), medir(v, clase, intervalo))

    candidatas = [r for r in resultados.values() if r[2] is not None and r[2].operaciones >= metricas.MIN_OPERACIONES]
    lineas = [
        f"# Laboratorio por velas: {nombre} (velas {vela})",
        "",
        f"{len(datos)} activos de {clase}, velas {vela} del {desde:%Y-%m-%d} al {hasta:%Y-%m-%d}. "
        f"Diseño hasta el {corte:%Y-%m-%d %H:%M}; validación desde ahí. Spread de la 0034 en cada entrada y salida.",
        "",
        "## Rejilla en diseño (aquí se elige)",
        "",
        "| Parámetros | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto | Duración |",
        "|---|---|---|---|---|---|---|",
    ]
    for params, _, d, _ in resultados.values():
        lineas.append(_fila(", ".join(f"{k}={v}" for k, v in params.items()), d, unidad))
    if not candidatas:
        lineas += ["", "❌ **Ninguna combinación llega a 30 operaciones en diseño.**"]
        return "\n".join(lineas)

    params, ops, d, v = max(candidatas, key=lambda r: r[2].expectativa_r)
    elegida = ", ".join(f"{k}={x}" for k, x in params.items())
    ok, motivos = metricas.veredicto(d, v)
    _, val_ops = metricas.partir(ops, corte)
    ic_meses = metricas.ic90_por_meses(val_ops)

    # Azar con la misma frecuencia de entrada: una primera estimación por
    # hora en que se podía entrar, ajustada con una tirada de prueba para que
    # dé las mismas operaciones (cada estrategia limita cuándo puede entrar).
    barras = sum(len(df) for df in datos.values())
    horas_abiertas = sum(o.dias + 1 for o in ops)
    probabilidad = len(ops) / max(barras - horas_abiertas, 1)
    prueba = len(operar(datos, azar(probabilidad=probabilidad, semilla=10_000, **params)))
    if prueba:
        probabilidad = min(probabilidad * len(ops) / prueba, 1.0)
    tiradas = []
    for s in range(semillas):
        _, av = metricas.partir(operar(datos, azar(probabilidad=probabilidad, semilla=s, **params)), corte)
        m = medir(av, clase, intervalo)
        if m is not None:
            tiradas.append(m)
    az = np.array([m.expectativa_r for m in tiradas])
    pct = float((az < v.expectativa_r).mean() * 100) if v is not None and len(az) else 0.0
    supera = pct >= minimo

    lineas += [
        "",
        f"## Validación de la elegida ({elegida})",
        "",
        "| Tramo | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto | Duración |",
        "|---|---|---|---|---|---|---|",
        _fila("Diseño", d, unidad),
        _fila("**Validación**", v, unidad),
    ]
    if ic_meses is not None:
        lineas += ["", f"IC 90 % remuestreando meses (las operaciones de un mismo mes no son independientes): "
                       f"{ic_meses[0]:+.3f} – {ic_meses[1]:+.3f} R."]
    if v is not None:
        # Sin el «por mes en cartera»: con operaciones de pocas horas, encadenar
        # sus rendimientos como si se estuviera siempre dentro da cifras irreales.
        lineas += [f"Factor de beneficio {v.factor_beneficio:.2f}."]
    lineas += [
        "",
        f"## Frente a {len(tiradas)} tiradas al azar (mismas salidas, probabilidad {probabilidad:.4f} por vela)",
        "",
    ]
    if len(az):
        lineas += [f"Azar en validación: mediana {np.median(az):+.3f} R, p5 – p95 {np.quantile(az, 0.05):+.3f} – "
                   f"{np.quantile(az, 0.95):+.3f} R, {np.median([m.operaciones for m in tiradas]):.0f} operaciones. "
                   f"La elegida supera al **{pct:.0f} %** (mínimo {minimo} %).", ""]
    lineas += ["## Validación de toda la rejilla (solo para ver; no elige)", "",
               "| Parámetros | Ops | Expectativa | IC 90 % | Aciertos | Coste / bruto | Duración |",
               "|---|---|---|---|---|---|---|"]
    for p_, _, _, vv in resultados.values():
        lineas.append(_fila(", ".join(f"{k}={x}" for k, x in p_.items()), vv, unidad))

    lineas += ["", "## Veredicto", ""]
    if ok and supera:
        lineas.append("✅ **tiene ventaja y supera al azar** en validación.")
    else:
        if not ok:
            lineas += [f"- {m}" for m in motivos]
        if not supera:
            lineas.append(f"- no supera al azar: percentil {pct:.0f} (mínimo {minimo})")
        lineas += ["", "❌ **no tiene ventaja**."]
        if supera and v is not None and v.expectativa_r <= 0:
            # Superar al azar perdiendo dinero es ser menos malo, no tener ventaja.
            lineas += ["", f"⚠️ Supera al azar, pero pierde dinero ({v.expectativa_r:+.3f} R en validación): "
                           "es menos mala que el azar, no una ventaja."]
    return "\n".join(lineas)


def cargar_1h(clase: str, cache: Path | None = None, universo: str = "activo",
              resultados: bool = False, intervalo: str = "1h", periodo: str = PERIODO) -> dict:
    """Velas (de 1 hora por defecto) de una clase en un universo (`datos.universo_nombrado`;
    el activo, en local y sin acceso a la base de datos, es la semilla de la
    0003 y las criptos de la 0032). Con `resultados`, marca los días de
    resultados y deja fuera las acciones de las que Yahoo no da fechas."""
    if cache is not None and cache.exists():
        return pickle.loads(cache.read_bytes())
    datos = {}
    activos, _ = universo_nombrado(universo)
    for simbolo, c in activos:
        if c != clase:
            continue
        df = cargar(simbolo, clase, periodo, intervalo=intervalo)
        if df is None or len(df) < barras_mes(clase, intervalo) * 2:
            continue
        if resultados:
            reaccion = cargar_resultados(simbolo)
            if reaccion is None or not len(reaccion):
                continue
            df = con_dia_resultados(df, reaccion)
        datos[(simbolo, clase)] = df
    if cache is not None:
        cache.write_bytes(pickle.dumps(datos))
    return datos


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--estrategia", default="rebote_caida", choices=ESTRATEGIAS_1H)
    p.add_argument("--semillas", type=int, default=20)
    p.add_argument("--salida", default="laboratorio_salida")
    p.add_argument("--cache", default="", help="pickle con las velas, para repetir sin descargar")
    a = p.parse_args()

    datos = cargar_1h(ESTRATEGIAS_1H[a.estrategia][2], Path(a.cache) if a.cache else None,
                      **CARGA.get(a.estrategia, {}))
    if not datos:
        print("Sin datos: nada que medir.")
        return 1
    texto = informe(a.estrategia, datos, a.semillas)
    salida = Path(a.salida)
    salida.mkdir(parents=True, exist_ok=True)
    (salida / "intradia.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
