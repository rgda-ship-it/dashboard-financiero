"""
Máquina de estados del modelo de riesgo por fases.

Reglas acordadas con el usuario (checklist de validación del Risk Manager,
Sprint 4):
1. Transición Fase1 -> Fase2: gana el PRIMER criterio que se cumpla entre
   (a) múltiplo de 3x sobre capital inicial, (b) drawdown de -30% desde el
   máximo alcanzado, (c) 8 operaciones cerradas en Fase 1.
2. El drawdown se mide desde el pico de capital alcanzado, NUNCA desde el
   capital inicial (caso de prueba #2 de QA).
3. Fase2 -> Fase1 SIEMPRE requiere una acción manual explícita con
   confirmación. Nunca ocurre por evaluación automática (caso de prueba #5).
4. Un evento de transición nunca se dispara dos veces por la misma causa
   (caso de prueba #4).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class Fase(str, Enum):
    FASE_1_ACELERACION = "fase_1_aceleracion"
    FASE_2_CONSOLIDACION = "fase_2_consolidacion"


class CriterioTransicion(str, Enum):
    MULTIPLO_CAPITAL = "multiplo_capital"
    DRAWDOWN_MAXIMO = "drawdown_maximo"
    REVALUACION_OPERACIONES = "revaluacion_operaciones"
    MANUAL = "manual"


@dataclass
class EventoTransicion:
    fase_anterior: Fase
    fase_nueva: Fase
    criterio: CriterioTransicion
    detalle: str
    timestamp: datetime = field(default_factory=datetime.utcnow)


@dataclass
class ParametrosRiesgo:
    multiplo_transicion: float = 3.0
    drawdown_limite_pct: float = -30.0
    max_operaciones_fase1: int = 8
    leverage_tope_fase1: float = 5.0
    leverage_tope_fase2: float = 3.0


class MaquinaFases:
    """Máquina de estados con un único estado activo por instancia
    (una instancia por usuario/cuenta en el sistema real)."""

    def __init__(
        self,
        capital_inicial: float,
        parametros: ParametrosRiesgo | None = None,
    ) -> None:
        if capital_inicial <= 0:
            raise ValueError("El capital inicial debe ser positivo.")

        self.capital_inicial = capital_inicial
        self.parametros = parametros or ParametrosRiesgo()

        self.fase_actual = Fase.FASE_1_ACELERACION
        self.capital_actual = capital_inicial
        self.capital_maximo_alcanzado = capital_inicial
        self.operaciones_en_fase_actual = 0
        self.eventos: list[EventoTransicion] = []

    @property
    def leverage_tope_actual(self) -> float:
        return (
            self.parametros.leverage_tope_fase1
            if self.fase_actual == Fase.FASE_1_ACELERACION
            else self.parametros.leverage_tope_fase2
        )

    def registrar_operacion_cerrada(self, capital_resultante: float) -> EventoTransicion | None:
        """Actualiza el capital tras cerrar una operación y evalúa si
        corresponde una transición automática. Devuelve el evento si
        se disparó, o None si no hubo cambio de fase.
        """
        self.capital_actual = capital_resultante
        self.capital_maximo_alcanzado = max(
            self.capital_maximo_alcanzado, capital_resultante
        )

        if self.fase_actual == Fase.FASE_2_CONSOLIDACION:
            # Regla dura: Fase 2 nunca vuelve a Fase 1 automáticamente,
            # sin importar cuánto crezca el capital desde aquí.
            self.operaciones_en_fase_actual += 1
            return None

        self.operaciones_en_fase_actual += 1

        return self._evaluar_transicion_a_fase2()

    def _evaluar_transicion_a_fase2(self) -> EventoTransicion | None:
        """Evalúa los tres criterios en orden y dispara el primero que
        se cumpla. Un solo evento por llamada — evita doble disparo si
        dos criterios se cumplen en la misma operación (caso #4 de QA).
        """
        drawdown_pct = self._calcular_drawdown_pct()

        if drawdown_pct <= self.parametros.drawdown_limite_pct:
            return self._transicionar(
                CriterioTransicion.DRAWDOWN_MAXIMO,
                f"Drawdown de {drawdown_pct:.1f}% desde el máximo alcanzado "
                f"(límite: {self.parametros.drawdown_limite_pct}%)",
            )

        multiplo_actual = self.capital_actual / self.capital_inicial
        if multiplo_actual >= self.parametros.multiplo_transicion:
            return self._transicionar(
                CriterioTransicion.MULTIPLO_CAPITAL,
                f"Capital alcanzó {multiplo_actual:.2f}x el inicial "
                f"(umbral: {self.parametros.multiplo_transicion}x)",
            )

        if self.operaciones_en_fase_actual >= self.parametros.max_operaciones_fase1:
            return self._transicionar(
                CriterioTransicion.REVALUACION_OPERACIONES,
                f"Revaluación tras {self.operaciones_en_fase_actual} operaciones "
                f"en Fase 1 (umbral: {self.parametros.max_operaciones_fase1})",
            )

        return None

    def _calcular_drawdown_pct(self) -> float:
        """Drawdown medido SIEMPRE desde el pico de capital alcanzado,
        nunca desde el capital inicial. Este es el punto más propenso a
        bugs identificado por el Risk Manager (checklist #4)."""
        if self.capital_maximo_alcanzado == 0:
            return 0.0
        return (
            (self.capital_actual - self.capital_maximo_alcanzado)
            / self.capital_maximo_alcanzado
        ) * 100

    def _transicionar(
        self, criterio: CriterioTransicion, detalle: str
    ) -> EventoTransicion:
        evento = EventoTransicion(
            fase_anterior=self.fase_actual,
            fase_nueva=Fase.FASE_2_CONSOLIDACION,
            criterio=criterio,
            detalle=detalle,
        )
        self.fase_actual = Fase.FASE_2_CONSOLIDACION
        self.operaciones_en_fase_actual = 0
        self.eventos.append(evento)
        return evento

    def revertir_a_fase1_manualmente(self, confirmacion_explicita: bool) -> EventoTransicion:
        """Único camino de regreso a Fase 1. Requiere `confirmacion_explicita`
        en True — el llamador (API) es responsable de haber obtenido esa
        confirmación real del usuario antes de invocar este método.
        """
        if not confirmacion_explicita:
            raise PermissionError(
                "Regreso a Fase 1 requiere confirmación explícita del usuario. "
                "Nunca ocurre automáticamente."
            )

        evento = EventoTransicion(
            fase_anterior=self.fase_actual,
            fase_nueva=Fase.FASE_1_ACELERACION,
            criterio=CriterioTransicion.MANUAL,
            detalle="Reversión manual confirmada por el usuario",
        )
        self.fase_actual = Fase.FASE_1_ACELERACION
        self.capital_maximo_alcanzado = self.capital_actual
        self.operaciones_en_fase_actual = 0
        self.eventos.append(evento)
        return evento
