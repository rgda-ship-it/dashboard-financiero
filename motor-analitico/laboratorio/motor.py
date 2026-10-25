"""
Motor del laboratorio: reproduce el histórico día a día, sin mirar el
futuro, con las mismas reglas de ejecución que el simulador (doc 06 §3.1).

    · La señal se calcula con los datos HASTA el cierre del día t.
    · Se entra en la apertura de t + 1, al precio de COMPRA (+ medio spread).
    · Stop y objetivo se comprueban con el máximo y el mínimo de cada día,
      al precio de VENTA (− medio spread).
    · Si un mismo día pudo tocar los dos, gana el stop (M2).
    · Si el día abre ya más allá del stop, se sale a la apertura (M3').
    · Una salida por regla (la decide la estrategia al cierre) se ejecuta
      en la apertura siguiente.
    · Toma parcial (fase 3, doc 01 §5): si el día llega al nivel, se vende
      esa fracción AL NIVEL, como el agente. El stop gana el empate; si el
      mismo día llega también al objetivo, primero va la parcial. Mover el
      stop a la entrada vale desde el día siguiente.
    · Cortos (fase 3, doc fase-3/02): la misma disciplina al revés. Se entra
      al precio de VENTA y se sale al de COMPRA; el stop está por encima y
      el objetivo por debajo; el hueco es abrir por ENCIMA del stop. Cada
      día natural abierto cuesta la financiación del corto
      (`financiacion_corto_pct`, anual), que se suma al precio de salida.
    · Entrada escalonada (doc fase-3/03, idea del dueño): con `escalon`, se
      compra la MITAD en la apertura y la otra mitad si el precio de compra
      baja hasta `escalon` (o en la apertura, si abre por debajo); el stop
      de la posición es `sl`, por debajo del escalón. El resultado en R se
      mide contra la pérdida máxima (las dos mitades compradas y el stop),
      y si la segunda mitad no llega, la operación es de media posición.

Una posición por activo y estrategia a la vez. El laboratorio mide la
ventaja de una regla de entrada y salida, no la gestión de una cartera.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Protocol

import pandas as pd


@dataclass
class Parcial:
    """Toma parcial del agente: al `recorrido` del camino hasta el objetivo
    vende la `fraccion`, y con `mover_stop` sube el stop a la entrada."""
    recorrido: float
    fraccion: float
    mover_stop: bool = False


@dataclass
class Entrada:
    """Lo que propone una estrategia al cierre del día t."""
    sl: float
    tp: float | None = None
    parcial: Parcial | None = None
    datos: dict = field(default_factory=dict)   # pasa a Posicion.datos
    lado: str = "largo"                         # largo | corto
    escalon: float | None = None                # compra la segunda mitad aquí (solo en largo)


@dataclass
class Posicion:
    entrada: float          # precio de compra en largo, de venta en corto (con medio spread)
    sl: float
    sl_inicial: float
    tp: float | None
    fecha_senal: pd.Timestamp
    fecha_entrada: pd.Timestamp
    indice_entrada: int
    mejor_cierre: float     # el mayor cierre en largo, el menor en corto
    salir_en_apertura: bool = False
    datos: dict = field(default_factory=dict)
    parcial: Parcial | None = None
    precio_parcial: float | None = None     # a qué precio se cerró la parcial
    lado: str = "largo"
    escalon: float | None = None
    precio_segunda: float | None = None     # a qué precio se compró la segunda mitad


@dataclass
class Operacion:
    activo: str
    clase: str
    estrategia: str
    fecha_senal: pd.Timestamp
    fecha_entrada: pd.Timestamp
    fecha_salida: pd.Timestamp
    precio_entrada: float
    sl_inicial: float
    tp: float | None
    precio_salida: float
    motivo: str             # sl | tp | hueco | regla | fin
    dias: int
    coste_r: float = 0.0    # spread pagado (entrada + salida) y financiación, en R
    regimen: str = ""       # régimen al dar la señal (columna REGIMEN), si lo hay
    parcial: bool = False   # hubo toma parcial: `precio_salida` es la media ponderada
    lado: str = "largo"     # en corto, `precio_salida` ya incluye la financiación
    r_fijo: float | None = None     # entrada escalonada: R contra la pérdida máxima
    pct_fijo: float | None = None
    escalonada: str = ""    # "" | media (solo la primera mitad) | completa

    @property
    def signo(self) -> int:
        return 1 if self.lado == "largo" else -1

    @property
    def riesgo(self) -> float:
        return self.signo * (self.precio_entrada - self.sl_inicial)

    @property
    def r(self) -> float:
        """Resultado en múltiplos del riesgo inicial (R)."""
        if self.r_fijo is not None:
            return self.r_fijo
        return self.signo * (self.precio_salida - self.precio_entrada) / self.riesgo

    @property
    def pct(self) -> float:
        if self.pct_fijo is not None:
            return self.pct_fijo
        return self.signo * (self.precio_salida / self.precio_entrada - 1) * 100


class Estrategia(Protocol):
    nombre: str

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        """Añade columnas CAUSALES (cada fila solo depende de las anteriores)."""

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        """¿Se entra mañana? Solo puede leer filas <= t."""

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion) -> tuple[float, bool]:
        """Al cierre de t con la posición abierta: (nuevo stop, salir mañana).
        El stop nunca se aleja: el motor se queda con el más ajustado (el
        mayor en largo, el menor en corto)."""


Spread = Callable[[float], float]   # precio -> spread completo en $


def simular(df: pd.DataFrame, estrategia: Estrategia, spread: Spread,
            activo: str = "", clase: str = "", inicio: int = 0,
            financiacion_corto_pct: float = 0.0) -> list[Operacion]:
    """Opera un activo de principio a fin con una estrategia."""
    regimenes = df["REGIMEN"] if "REGIMEN" in df.columns else None
    df = estrategia.preparar(df)
    o, h, l, c = (df[col].to_numpy(dtype=float) for col in ("Open", "High", "Low", "Close"))
    fechas = df.index
    n = len(df)
    ops: list[Operacion] = []
    pos: Posicion | None = None
    pendiente: tuple[int, Entrada] | None = None

    def venta(precio: float) -> float:
        return max(precio - spread(precio) / 2, precio / 2)

    def compra(precio: float) -> float:
        return precio + spread(precio) / 2

    def cerrar(t: int, precio: float, motivo: str) -> None:
        nonlocal pos
        corto = pos.lado == "corto"
        riesgo = (pos.sl_inicial - pos.entrada) if corto else (pos.entrada - pos.sl_inicial)
        coste = pos.datos.get("coste_entrada", 0.0) + spread(precio) / 2
        if pos.precio_parcial is not None:
            # Una sola operación con la salida media: la parte cerrada en la
            # parcial a su nivel, el resto a la salida final.
            f = pos.parcial.fraccion
            precio = f * pos.precio_parcial + (1 - f) * precio
        if corto and financiacion_corto_pct:
            # Financiación del corto por día NATURAL abierto, sobre el nominal
            # de entrada. Se paga al recomprar: sube el precio de salida.
            dias = (fechas[t] - pos.fecha_entrada).days
            financiacion = pos.entrada * financiacion_corto_pct / 100 * dias / 365
            precio += financiacion
            coste += financiacion
        regimen = ""
        if regimenes is not None and pos.fecha_senal in regimenes.index:
            regimen = str(regimenes.loc[pos.fecha_senal])
        r_fijo = pct_fijo = None
        escalonada = ""
        if pos.escalon is not None:
            # Media posición a la entrada y, si llegó, media al escalón.
            maxima = 0.5 * (pos.entrada - pos.sl_inicial) + 0.5 * (pos.escalon - pos.sl_inicial)
            pnl = 0.5 * (precio - pos.entrada)
            invertido = 0.5 * pos.entrada
            coste = pos.datos.get("coste_entrada", 0.0) * 0.5 + spread(precio) / 2 * 0.5
            if pos.precio_segunda is not None:
                pnl += 0.5 * (precio - pos.precio_segunda)
                invertido += 0.5 * pos.precio_segunda
                coste += pos.datos.get("coste_segunda", 0.0) * 0.5 + spread(precio) / 2 * 0.5
            r_fijo, pct_fijo = pnl / maxima, pnl / invertido * 100
            riesgo = maxima
            escalonada = "completa" if pos.precio_segunda is not None else "media"
        ops.append(Operacion(
            activo=activo, clase=clase, estrategia=estrategia.nombre,
            fecha_senal=pos.fecha_senal, fecha_entrada=pos.fecha_entrada,
            fecha_salida=fechas[t], precio_entrada=pos.entrada,
            sl_inicial=pos.sl_inicial, tp=pos.tp, precio_salida=precio,
            motivo=motivo, dias=t - pos.indice_entrada,
            coste_r=coste / riesgo if riesgo > 0 else 0.0, regimen=regimen,
            parcial=pos.precio_parcial is not None, lado=pos.lado,
            r_fijo=r_fijo, pct_fijo=pct_fijo, escalonada=escalonada))
        pos = None

    for t in range(inicio, n):
        if any(pd.isna(x) for x in (o[t], h[t], l[t], c[t])):
            continue

        # 1. Entrada pendiente de ayer, en la apertura de hoy.
        entra_hoy = False
        if pos is None and pendiente is not None:
            t_senal, ent = pendiente
            pendiente = None
            if ent.lado == "corto":
                # Se vende al precio de venta; para cerrar habría que recomprar
                # al de compra, que tiene que quedar entre objetivo y stop.
                precio = venta(o[t])
                valida = (compra(o[t]) < ent.sl and (ent.tp is None or compra(o[t]) > ent.tp)
                          and precio < ent.sl)
            else:
                precio = compra(o[t])
                # Si hoy ya abre fuera de sus niveles, la operación no existe.
                valida = (venta(o[t]) > ent.sl and (ent.tp is None or venta(o[t]) < ent.tp)
                          and precio > ent.sl)
            if valida:
                pos = Posicion(entrada=precio, sl=ent.sl, sl_inicial=ent.sl, tp=ent.tp,
                               fecha_senal=fechas[t_senal], fecha_entrada=fechas[t],
                               indice_entrada=t, mejor_cierre=c[t],
                               datos={**ent.datos, "coste_entrada": spread(o[t]) / 2},
                               parcial=ent.parcial if ent.tp is not None else None, lado=ent.lado,
                               escalon=ent.escalon if ent.lado == "largo" and ent.escalon is not None
                               and ent.sl < ent.escalon < precio else None)
                entra_hoy = True

        # 2. Con la posición abierta: salida por regla, hueco, stop, objetivo.
        if pos is not None and pos.lado == "corto":
            if pos.salir_en_apertura and not entra_hoy:
                cerrar(t, compra(o[t]), "regla")
            else:
                c_open, c_low, c_high = compra(o[t]), compra(l[t]), compra(h[t])
                if not entra_hoy and c_open >= pos.sl:
                    cerrar(t, c_open, "hueco")                 # M3', al revés
                elif c_high >= pos.sl:
                    cerrar(t, pos.sl, "sl")                    # M2: el stop gana el empate
                else:
                    if pos.parcial is not None and pos.precio_parcial is None:
                        nivel = pos.entrada - pos.parcial.recorrido * (pos.entrada - pos.tp)
                        if c_low <= nivel:
                            pos.precio_parcial = nivel
                            if pos.parcial.mover_stop:
                                pos.sl = min(pos.sl, pos.entrada * 1.0005)
                    if pos.tp is not None and c_low <= pos.tp:
                        cerrar(t, pos.tp, "tp")
        elif pos is not None:
            if pos.salir_en_apertura and not entra_hoy:
                cerrar(t, venta(o[t]), "regla")
            else:
                # Entrada escalonada: la segunda mitad, antes de mirar el stop
                # (que está por debajo del escalón). Si el mismo día baja hasta
                # el stop, también salta: el stop gana el empate.
                if pos.escalon is not None and pos.precio_segunda is None and compra(l[t]) <= pos.escalon:
                    abre = o[t] if not entra_hoy else pos.escalon
                    pos.precio_segunda = min(compra(abre), pos.escalon)
                    pos.datos["coste_segunda"] = spread(pos.precio_segunda) / 2
                v_open, v_low, v_high = venta(o[t]), venta(l[t]), venta(h[t])
                if not entra_hoy and v_open <= pos.sl:
                    cerrar(t, v_open, "hueco")                 # M3'
                elif v_low <= pos.sl:
                    cerrar(t, pos.sl, "sl")                    # M2: el stop gana el empate
                else:
                    if pos.parcial is not None and pos.precio_parcial is None:
                        nivel = pos.entrada + pos.parcial.recorrido * (pos.tp - pos.entrada)
                        if v_high >= nivel:
                            pos.precio_parcial = nivel
                            if pos.parcial.mover_stop:
                                pos.sl = max(pos.sl, pos.entrada * 0.9995)
                    if pos.tp is not None and v_high >= pos.tp:
                        cerrar(t, pos.tp, "tp")

        # 3. Al cierre: la estrategia gestiona lo abierto o busca entrada.
        if pos is not None:
            if pos.lado == "corto":
                pos.mejor_cierre = min(pos.mejor_cierre, c[t])
                nuevo_sl, salir = estrategia.actualizar(df, t, pos)
                pos.sl = min(pos.sl, nuevo_sl)
            else:
                pos.mejor_cierre = max(pos.mejor_cierre, c[t])
                nuevo_sl, salir = estrategia.actualizar(df, t, pos)
                pos.sl = max(pos.sl, nuevo_sl)
            pos.salir_en_apertura = salir
        elif t < n - 1:
            ent = estrategia.entrada(df, t)
            if ent is not None and ((ent.lado == "corto" and ent.sl > c[t])
                                    or (ent.lado != "corto" and ent.sl < c[t])):
                pendiente = (t, ent)

    if pos is not None:
        cerrar(n - 1, compra(c[n - 1]) if pos.lado == "corto" else venta(c[n - 1]), "fin")
    return ops
