"""
Cálculo de apalancamiento recomendado, siempre acotado por un tope duro.

Regla acordada con el equipo (validada por el Analista Cuantitativo tras
descartar 20x por inviabilidad matemática, no por preferencia):
- El tope duro NUNCA es superable, sin importar la señal.
- El recomendado se calcula según volatilidad (ATR%) y fuerza de confluencia,
  pero jamás puede exceder el tope.

Además (especificación «dirección de la señal», §3.1/§3.2): el bonus por
confluencia premia la alineación de indicadores EN LA DIRECCIÓN de la
operación implícita, y este terminal solo encuadra operaciones en largo.
Por eso, con lectura bajista o neutral no se emite número operable: se
devuelve `recomendado = None` más una `referencia_volatilidad` (la base de
volatilidad, sin bonus) que es justo el insumo que necesitaría un
dimensionador de cortos, sin fingir un setup que el motor no calcula.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass
class ResultadoApalancamiento:
    tope: float
    recomendado: float | None  # None ⟺ el motor no encuadra operación
    motivo: str
    referencia_volatilidad: float  # SIEMPRE presente: solo volatilidad, sin bonus


# La dirección de la confluencia (lectura de mercado) se traduce al sesgo
# operativo (qué encuadra el sistema). Hoy es 1:1, pero son conceptos
# distintos y se desacoplarán en cuanto se habiliten cortos: por eso el
# mapeo vive explícito en vez de comparar `direccion == "alcista"` suelto.
_SESGO_POR_DIRECCION = {
    "alcista": "largo",
    "bajista": "corto",
    "neutral": "sin_sesgo",
}


def calcular_apalancamiento(
    atr_pct: float,
    fuerza_confluencia: str,  # "baja" | "media" | "alta"
    tope_duro: float,
    direccion: str,  # "alcista" | "bajista" | "neutral"
) -> ResultadoApalancamiento:
    """
    atr_pct: ATR expresado como % del precio (volatilidad relativa).
    fuerza_confluencia: resultado de `evaluar_confluencia().fuerza`.
    tope_duro: constante protegida del sistema (5x en Fase 1, 3x en Fase 2).
    direccion: dirección dominante de la confluencia. Parámetro OBLIGATORIO
        y deliberadamente SIN valor por defecto: un `direccion="alcista"`
        implícito reintroduciría en silencio, en cualquier llamador nuevo,
        exactamente el defecto que esta firma existe para cerrar.
    """
    # `tope_duro` tiene que ser un número utilizable: un NaN pasaría el
    # `<= 0` (toda comparación con NaN es falsa) y acabaría emitiendo un
    # `leverage_tope: null` en el payload, que el contrato prohíbe.
    if not math.isfinite(tope_duro) or tope_duro <= 0:
        raise ValueError("El tope duro de apalancamiento debe ser positivo.")

    sesgo_operativo = _SESGO_POR_DIRECCION.get(direccion, "sin_sesgo")

    # Volatilidad desconocida: se resuelve ANTES de los tramos porque toda
    # comparación con NaN es falsa y el flujo caería en el `else` final,
    # es decir en "volatilidad baja" — el tramo más generoso. El modo
    # degradado apuntaba al riesgo máximo sobre un activo del que no se
    # conoce la volatilidad; ahora degrada hacia el mínimo y lo dice.
    if not math.isfinite(atr_pct):
        referencia = _acotar(1.0, tope_duro)
        return ResultadoApalancamiento(
            tope=tope_duro,
            recomendado=None,
            motivo="volatilidad no disponible — sin apalancamiento operable",
            referencia_volatilidad=round(referencia, 1),
        )

    # Base según volatilidad: a mayor ATR%, menor apalancamiento base.
    # Estos rangos son deliberadamente conservadores — la volatilidad
    # pesa más que la señal técnica en el cálculo (caso de prueba #6 de QA).
    if atr_pct >= 6:
        base = 1.0
        motivo_vol = "volatilidad alta"
    elif atr_pct >= 3:
        base = min(2.0, tope_duro)
        motivo_vol = "volatilidad media"
    else:
        base = min(3.0, tope_duro)
        motivo_vol = "volatilidad baja"

    # La referencia de volatilidad es la base SIN bonus de confluencia, y
    # se somete al mismo clamp que el recomendado (regla protegida nº1).
    referencia = round(_acotar(base, tope_duro), 1)

    # Ajuste por confluencia: solo puede subir el recomendado dentro del tope,
    # nunca superarlo.
    ajuste_confluencia = {"baja": 0.0, "media": 1.0, "alta": 2.0}.get(
        fuerza_confluencia, 0.0
    )

    if sesgo_operativo != "largo":
        # Lectura bajista o sin dirección dominante: no hay operación que
        # dimensionar, así que no se emite número operable. El motivo lleva
        # la referencia para que la UI pueda explicar el `null` en vez de
        # dejar que se lea como "fallo del proveedor".
        if sesgo_operativo == "corto":
            motivo = (
                "confluencia bajista — el motor no emite apalancamiento "
                f"operable; referencia por {motivo_vol}: {referencia:.1f}x"
            )
        else:
            motivo = (
                "sin confluencia direccional — el motor no emite apalancamiento "
                f"operable; referencia por {motivo_vol}: {referencia:.1f}x"
            )
        return ResultadoApalancamiento(
            tope=tope_duro,
            recomendado=None,
            motivo=motivo,
            referencia_volatilidad=referencia,
        )

    recomendado = _acotar(base + ajuste_confluencia, tope_duro)

    if ajuste_confluencia == 0.0 and atr_pct >= 6:
        motivo = f"{motivo_vol}, sin confluencia — apalancamiento mínimo"
    else:
        motivo = f"{motivo_vol}, confluencia {fuerza_confluencia}"

    return ResultadoApalancamiento(
        tope=tope_duro,
        recomendado=round(recomendado, 1),
        motivo=motivo,
        referencia_volatilidad=referencia,
    )


def _acotar(valor: float, tope_duro: float) -> float:
    """Suelo de 1x y clamp estricto al tope duro, EN ESE ORDEN.

    El orden importa: con el suelo aplicado después del clamp, un tope
    configurado por debajo de 1,0x (p. ej. LEVERAGE_HARD_CAP_FASE1=0.5,
    que pasa la validación por ser positivo) devolvía 1.0 — el doble del
    tope duro, rompiendo la regla protegida nº1 del README. Aplicando el
    `min(..., tope_duro)` al final, esta línea sigue siendo la que
    garantiza que nada exceda el tope, sin importar el resto del cálculo.
    """
    valor = max(valor, 1.0)  # nunca por debajo de 1x
    return min(valor, tope_duro)
