"""
De la estrategia de un agente (la columna `agentes.estrategia`) a los
parámetros de la estrategia `agente` del laboratorio (doc fase-3/01 §5).

Una hipótesis cambia UNA pieza sobre esta base: el laboratorio compara el
agente tal como opera con el agente con ese cambio.
"""

from __future__ import annotations


def parametros_de_agente(estrategia: dict, clase: str) -> dict:
    """Los parámetros de `Agente` que reproducen a ese agente en esa clase.

    `por_clase` (0032) pisa la banda de volatilidad en cripto. Lo que el
    laboratorio no modela (reparto, rotación, riesgo, posiciones) no sale."""
    propia = {**estrategia, **(estrategia.get("por_clase") or {}).get(clase, {})}
    p = {
        "rr_minimo": float(propia.get("rr_minimo") or 1.2),
        "atr_min": float(propia.get("atr_pct_min") or 0),
        "atr_max": float(propia.get("atr_pct_max") or 0),
        "deterioro": int(bool(propia.get("salida_deterioro", True))),
    }
    tp = propia.get("tp_parcial")
    if isinstance(tp, dict):
        p["parcial_recorrido"] = float(tp.get("recorrido", 0))
        p["parcial_fraccion"] = float(tp.get("fraccion", 0.5))
        p["parcial_mover"] = int(bool(tp.get("mover_stop")))
    return p


def como_texto(parametros: dict) -> str:
    """«nombre=valor,…», el formato de `--parametros` del laboratorio."""
    return ",".join(f"{k}={v}" for k, v in parametros.items())
