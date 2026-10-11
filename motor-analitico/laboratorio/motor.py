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

Una posición por activo y estrategia a la vez. El laboratorio mide la
ventaja de una regla de entrada y salida, no la gestión de una cartera.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Protocol

import pandas as pd


@dataclass
class Entrada:
    """Lo que propone una estrategia al cierre del día t."""
    sl: float
    tp: float | None = None


@dataclass
class Posicion:
    entrada: float          # precio de compra (con medio spread)
    sl: float
    sl_inicial: float
    tp: float | None
    fecha_senal: pd.Timestamp
    fecha_entrada: pd.Timestamp
    indice_entrada: int
    mejor_cierre: float
    salir_en_apertura: bool = False
    datos: dict = field(default_factory=dict)


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
    coste_r: float = 0.0    # spread pagado (entrada + salida), en R
    regimen: str = ""       # régimen al dar la señal (columna REGIMEN), si lo hay

    @property
    def riesgo(self) -> float:
        return self.precio_entrada - self.sl_inicial

    @property
    def r(self) -> float:
        """Resultado en múltiplos del riesgo inicial (R)."""
        return (self.precio_salida - self.precio_entrada) / self.riesgo

    @property
    def pct(self) -> float:
        return (self.precio_salida / self.precio_entrada - 1) * 100


class Estrategia(Protocol):
    nombre: str

    def preparar(self, df: pd.DataFrame) -> pd.DataFrame:
        """Añade columnas CAUSALES (cada fila solo depende de las anteriores)."""

    def entrada(self, df: pd.DataFrame, t: int) -> Entrada | None:
        """¿Se entra mañana? Solo puede leer filas <= t."""

    def actualizar(self, df: pd.DataFrame, t: int, pos: Posicion) -> tuple[float, bool]:
        """Al cierre de t con la posición abierta: (nuevo stop, salir mañana).
        El stop nunca baja: el motor se queda con el mayor."""


Spread = Callable[[float], float]   # precio -> spread completo en $


def simular(df: pd.DataFrame, estrategia: Estrategia, spread: Spread,
            activo: str = "", clase: str = "", inicio: int = 0) -> list[Operacion]:
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
        riesgo = pos.entrada - pos.sl_inicial
        coste = pos.datos.get("coste_entrada", 0.0) + spread(precio) / 2
        regimen = ""
        if regimenes is not None and pos.fecha_senal in regimenes.index:
            regimen = str(regimenes.loc[pos.fecha_senal])
        ops.append(Operacion(
            activo=activo, clase=clase, estrategia=estrategia.nombre,
            fecha_senal=pos.fecha_senal, fecha_entrada=pos.fecha_entrada,
            fecha_salida=fechas[t], precio_entrada=pos.entrada,
            sl_inicial=pos.sl_inicial, tp=pos.tp, precio_salida=precio,
            motivo=motivo, dias=t - pos.indice_entrada,
            coste_r=coste / riesgo if riesgo > 0 else 0.0, regimen=regimen))
        pos = None

    for t in range(inicio, n):
        if any(pd.isna(x) for x in (o[t], h[t], l[t], c[t])):
            continue

        # 1. Entrada pendiente de ayer, en la apertura de hoy.
        if pos is None and pendiente is not None:
            t_senal, ent = pendiente
            pendiente = None
            precio = compra(o[t])
            # Si hoy ya abre fuera de sus niveles, la operación no existe.
            if venta(o[t]) > ent.sl and (ent.tp is None or venta(o[t]) < ent.tp) and precio > ent.sl:
                pos = Posicion(entrada=precio, sl=ent.sl, sl_inicial=ent.sl, tp=ent.tp,
                               fecha_senal=fechas[t_senal], fecha_entrada=fechas[t],
                               indice_entrada=t, mejor_cierre=c[t],
                               datos={"coste_entrada": spread(o[t]) / 2})
                entra_hoy = True
            else:
                entra_hoy = False
        else:
            entra_hoy = False

        # 2. Con la posición abierta: salida por regla, hueco, stop, objetivo.
        if pos is not None:
            if pos.salir_en_apertura and not entra_hoy:
                cerrar(t, venta(o[t]), "regla")
            else:
                v_open, v_low, v_high = venta(o[t]), venta(l[t]), venta(h[t])
                if not entra_hoy and v_open <= pos.sl:
                    cerrar(t, v_open, "hueco")                 # M3'
                elif v_low <= pos.sl:
                    cerrar(t, pos.sl, "sl")                    # M2: el stop gana el empate
                elif pos.tp is not None and v_high >= pos.tp:
                    cerrar(t, pos.tp, "tp")

        # 3. Al cierre: la estrategia gestiona lo abierto o busca entrada.
        if pos is not None:
            pos.mejor_cierre = max(pos.mejor_cierre, c[t])
            nuevo_sl, salir = estrategia.actualizar(df, t, pos)
            pos.sl = max(pos.sl, nuevo_sl)
            pos.salir_en_apertura = salir
        elif t < n - 1:
            ent = estrategia.entrada(df, t)
            if ent is not None and ent.sl < c[t]:
                pendiente = (t, ent)

    if pos is not None:
        cerrar(n - 1, venta(c[n - 1]), "fin")
    return ops
