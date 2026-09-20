"""
Score de salud de una posición cargada por el usuario (Portfolio Health
Selector — Modo Diagnóstico).

REGLA DE DISEÑO NO NEGOCIABLE (checklist del Risk Manager, punto #6):
Este módulo NUNCA recibe ni usa el campo `monto_invertido` para calcular
nada relacionado con "cuánto capital mover". El monto solo se usa para
mostrar P&L informativo al propio usuario sobre su posición actual.
Los niveles de TP/SL que se muestran para un posible activo de rotación
son SIEMPRE los mismos que el escáner general calcula para ese activo —
nunca se recalculan en función de esta posición.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from indicadores.tecnicos import ResultadoConfluencia


class NivelSalud(str, Enum):
    VERDE = "verde"
    AMBAR = "ambar"
    ROJO = "rojo"


@dataclass
class PosicionCargada:
    ticker: str
    precio_compra: float
    monto_invertido: float  # SOLO para mostrar P&L — ver docstring del módulo


@dataclass
class DiagnosticoPosicion:
    ticker: str
    precio_actual: float
    pnl_pct: float
    pnl_absoluto: float  # informativo, derivado del monto del usuario
    nivel_salud: NivelSalud
    mensaje: str


def calcular_pnl(posicion: PosicionCargada, precio_actual: float) -> tuple[float, float]:
    """P&L informativo. Este es el ÚNICO uso permitido de `monto_invertido`
    en todo el módulo."""
    pnl_pct = ((precio_actual - posicion.precio_compra) / posicion.precio_compra) * 100
    pnl_absoluto = posicion.monto_invertido * (pnl_pct / 100)
    return pnl_pct, pnl_absoluto


def evaluar_deterioro_tecnico(confluencia: ResultadoConfluencia) -> int:
    """Cuenta señales de deterioro técnico (0, 1, o 2+) a partir de la
    misma confluencia que ya calcula el escáner general — no se inventa
    lógica nueva para el diagnóstico de cartera.

    El conteo solo vale como deterioro si los bajistas IGUALAN O SUPERAN a
    los alcistas: con 3 alcistas y 2 bajistas la lectura dominante es
    alcista y contar los 2 bajistas en crudo diagnosticaba deterioro sobre
    una confluencia alcista.

    El `>=` es deliberado y no debe "corregirse" a `>` para igualarlo al de
    riesgo/rotacion.py: allí se compromete capital NUEVO y el empate
    excluye; aquí hay capital YA EXPUESTO y el empate mantiene la
    vigilancia. Ambas resuelven hacia la prudencia, cada una en su
    dirección. Los umbrales (>= 2 / >= 1) y los mensajes no cambian.
    """
    if confluencia.indicadores_bajistas >= confluencia.indicadores_alcistas:
        return confluencia.indicadores_bajistas
    return 0


def evaluar_deterioro_fundamental(
    fundamentales_actuales: dict, fundamentales_en_compra: dict | None
) -> bool:
    """True si los fundamentales empeoraron de forma relevante.
    Si no hay fundamentales históricos de referencia (posición cargada
    sin ese dato), se evalúa solo el estado actual de forma conservadora.
    """
    eps_actual = fundamentales_actuales.get("eps")
    if eps_actual is not None and eps_actual < 0:
        return True

    if fundamentales_en_compra:
        eps_previo = fundamentales_en_compra.get("eps")
        if eps_actual is not None and eps_previo is not None and eps_previo > 0:
            caida_pct = ((eps_actual - eps_previo) / eps_previo) * 100
            if caida_pct <= -20:
                return True

    return False


def calcular_diagnostico(
    posicion: PosicionCargada,
    precio_actual: float,
    confluencia: ResultadoConfluencia,
    deterioro_fundamental: bool,
) -> DiagnosticoPosicion:
    pnl_pct, pnl_absoluto = calcular_pnl(posicion, precio_actual)

    senales_deterioro_tecnico = evaluar_deterioro_tecnico(confluencia)

    if senales_deterioro_tecnico >= 2 and deterioro_fundamental:
        nivel = NivelSalud.ROJO
        mensaje = "Deterioro estructural confirmado en tendencia y fundamentales"
    elif senales_deterioro_tecnico >= 1 or deterioro_fundamental:
        nivel = NivelSalud.AMBAR
        mensaje = "Se detectan señales tempranas de deterioro técnico"
    else:
        nivel = NivelSalud.VERDE
        mensaje = "Sin señales de deterioro estructural detectadas"

    return DiagnosticoPosicion(
        ticker=posicion.ticker,
        precio_actual=precio_actual,
        pnl_pct=round(pnl_pct, 2),
        pnl_absoluto=round(pnl_absoluto, 2),
        nivel_salud=nivel,
        mensaje=mensaje,
    )
