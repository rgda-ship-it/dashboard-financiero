"""
Tests directos de los casos de prueba definidos en Sprint 4 (QA + Quant).
Cada test está numerado igual que en el backlog para trazabilidad.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from riesgo.maquina_fases import (
    CriterioTransicion,
    Fase,
    MaquinaFases,
    ParametrosRiesgo,
)


def _maquina_default(capital_inicial: float = 500.0) -> MaquinaFases:
    return MaquinaFases(capital_inicial=capital_inicial)


def test_caso_1_transicion_por_multiplo():
    m = _maquina_default(500.0)
    evento = m.registrar_operacion_cerrada(capital_resultante=1500.0)  # exactamente 3x
    assert evento is not None
    assert evento.criterio == CriterioTransicion.MULTIPLO_CAPITAL
    assert m.fase_actual == Fase.FASE_2_CONSOLIDACION


def test_caso_2_drawdown_medido_desde_el_pico_no_desde_inicial():
    m = _maquina_default(500.0)
    # Sube a 2.5x (no toca el múltiplo de 3x)
    m.registrar_operacion_cerrada(capital_resultante=1250.0)
    assert m.fase_actual == Fase.FASE_1_ACELERACION
    assert m.capital_maximo_alcanzado == 1250.0

    # Cae -30% desde el pico de 1250 -> 875.0, NO desde el inicial de 500
    evento = m.registrar_operacion_cerrada(capital_resultante=875.0)
    assert evento is not None
    assert evento.criterio == CriterioTransicion.DRAWDOWN_MAXIMO
    assert m.fase_actual == Fase.FASE_2_CONSOLIDACION


def test_caso_3_revaluacion_por_conteo_de_operaciones():
    m = _maquina_default(500.0)
    # 7 operaciones que no mueven mucho el capital ni generan drawdown
    for _ in range(7):
        m.registrar_operacion_cerrada(capital_resultante=m.capital_actual * 1.01)
    assert m.fase_actual == Fase.FASE_1_ACELERACION

    # Operación número 8 -> debe forzar revaluación
    evento = m.registrar_operacion_cerrada(capital_resultante=m.capital_actual * 1.01)
    assert evento is not None
    assert evento.criterio == CriterioTransicion.REVALUACION_OPERACIONES


def test_caso_4_no_doble_disparo_en_la_misma_operacion():
    m = _maquina_default(500.0)
    # Forzamos que multiplo Y drawdown se cumplan en la misma llamada:
    # subir directo a 3x y que ese mismo valor sea, a la vez, el pico
    # (drawdown 0% en este punto, así que solo debe disparar multiplo).
    evento = m.registrar_operacion_cerrada(capital_resultante=1500.0)
    assert evento is not None
    assert len(m.eventos) == 1  # un único evento registrado


def test_caso_5_fase2_no_regresa_automaticamente_a_fase1():
    m = _maquina_default(500.0)
    m.registrar_operacion_cerrada(capital_resultante=1500.0)  # -> Fase 2
    assert m.fase_actual == Fase.FASE_2_CONSOLIDACION

    # El capital sigue creciendo muy por encima de 3x estando en Fase 2
    evento = m.registrar_operacion_cerrada(capital_resultante=5000.0)
    assert evento is None  # ningún evento automático
    assert m.fase_actual == Fase.FASE_2_CONSOLIDACION  # sigue en Fase 2


def test_reversion_manual_requiere_confirmacion_explicita():
    m = _maquina_default(500.0)
    m.registrar_operacion_cerrada(capital_resultante=1500.0)  # -> Fase 2

    try:
        m.revertir_a_fase1_manualmente(confirmacion_explicita=False)
        assert False, "Debió lanzar PermissionError sin confirmación"
    except PermissionError:
        pass

    evento = m.revertir_a_fase1_manualmente(confirmacion_explicita=True)
    assert evento.criterio == CriterioTransicion.MANUAL
    assert m.fase_actual == Fase.FASE_1_ACELERACION


def test_leverage_tope_cambia_segun_fase():
    parametros = ParametrosRiesgo(leverage_tope_fase1=5.0, leverage_tope_fase2=3.0)
    m = MaquinaFases(capital_inicial=500.0, parametros=parametros)
    assert m.leverage_tope_actual == 5.0

    m.registrar_operacion_cerrada(capital_resultante=1500.0)  # -> Fase 2
    assert m.leverage_tope_actual == 3.0


if __name__ == "__main__":
    tests = [
        test_caso_1_transicion_por_multiplo,
        test_caso_2_drawdown_medido_desde_el_pico_no_desde_inicial,
        test_caso_3_revaluacion_por_conteo_de_operaciones,
        test_caso_4_no_doble_disparo_en_la_misma_operacion,
        test_caso_5_fase2_no_regresa_automaticamente_a_fase1,
        test_reversion_manual_requiere_confirmacion_explicita,
        test_leverage_tope_cambia_segun_fase,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
