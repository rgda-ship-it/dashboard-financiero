"""
Pruebas del dimensionado de posición (H-23, doc 03 §5.3).

Los CASOS son los mismos que verifica la invariante I33 contra
`public.fn_dimensionar_posicion`. Duplicarlos es deliberado: el cálculo
vive en Python (para el ciclo de agentes) y en SQL (porque el servidor no
puede fiarse del tamaño que le manda un cliente), y dos implementaciones
que no se comparan contra los mismos números acaban divergiendo.
"""

import sys
from decimal import Decimal
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from riesgo.dimensionado import (  # noqa: E402
    Dimension,
    SinOperacion,
    dimensionar_posicion,
    piso_a_un_decimal,
    precio_de_liquidacion,
    riesgo_real,
)

# Cuenta canónica: 1.000 $ libres, riesgo del 2 % (20 $ por operación),
# tope de margen comprometido del 60 %, Fase 1 (tope 5x).
CUENTA = dict(
    equity=1000,
    saldo_disponible=1000,
    saldo_bloqueado=0,
    riesgo_pct=2,
    margen_comprometido_max_pct=60,
    tope_fase=5,
)


def test_el_tamano_sale_del_riesgo_y_no_del_saldo():
    """Stop al 10 %: nominal 200 $ para que tocarlo cueste 20 $."""
    d = dimensionar_posicion(**CUENTA, precio=100, sl=90, leverage_recomendado=5)

    assert d.apalancamiento == Decimal("5")
    assert d.margen == Decimal("40.00")
    assert d.cantidad == Decimal("2")
    assert d.nominal == Decimal("200.00")
    # Lo que de verdad importa: tocar el stop cuesta exactamente el riesgo
    # declarado, ni un céntimo más.
    assert riesgo_real(d, 100, 90) == Decimal("20.00")
    assert d.apalancamiento_reducido is False


def test_la_liquidacion_queda_por_debajo_del_stop_cuando_no_hay_ajuste():
    d = dimensionar_posicion(**CUENTA, precio=100, sl=90, leverage_recomendado=5)
    assert d.precio_liquidacion == Decimal("80")
    assert d.precio_liquidacion < Decimal("90")


def test_baja_el_apalancamiento_cuando_la_liquidacion_adelanta_al_stop():
    """EL CASO QUE JUSTIFICA EL MÓDULO.

    Stop al 25 %: a 5x la liquidación caería en 80, por ENCIMA del stop de
    75. Abrir así significa que la pérdida real es el margen entero (40 $)
    y no los 20 $ declarados. El apalancamiento baja a 3,9x — 1/0,25 = 4,0
    menos un decimal — y la liquidación queda en 74,36.
    """
    d = dimensionar_posicion(**CUENTA, precio=100, sl=75, leverage_recomendado=5)

    assert d.apalancamiento == Decimal("3.9")
    assert d.apalancamiento_reducido is True
    assert d.precio_liquidacion < Decimal("75")
    # Y el riesgo sigue sin superar el declarado.
    assert riesgo_real(d, 100, 75) <= Decimal("20")


def test_sin_operacion_cuando_ni_a_1x_la_liquidacion_queda_por_debajo():
    """Stop al 99 %: no hay apalancamiento >= 1 que lo respete. Se devuelve
    «sin operación» en vez de una orden cuyo riesgo está mal declarado."""
    with pytest.raises(SinOperacion) as error:
        dimensionar_posicion(**CUENTA, precio=100, sl=1, leverage_recomendado=5)
    assert error.value.motivo == "sin_operacion_liquidacion_antes_del_stop"


def test_el_tope_de_la_fase_manda_sobre_el_del_motor():
    """G1. En Fase 2 el tope es 3x aunque el motor recomiende 5x y la
    estrategia del agente permita 4x."""
    d = dimensionar_posicion(
        **{**CUENTA, "tope_fase": 3},
        precio=100,
        sl=90,
        leverage_recomendado=5,
        apalancamiento_maximo_propio=4,
    )
    assert d.apalancamiento == Decimal("3")
    # Mismo riesgo, más margen: bajar el apalancamiento no cambia cuánto se
    # arriesga, cambia cuánto capital hay que inmovilizar para arriesgarlo.
    assert d.margen == Decimal("66.66")
    assert riesgo_real(d, 100, 90) <= Decimal("20")


def test_el_apalancamiento_propio_del_agente_tambien_recorta():
    d = dimensionar_posicion(
        **CUENTA, precio=100, sl=90, leverage_recomendado=5, apalancamiento_maximo_propio=2
    )
    assert d.apalancamiento == Decimal("2")


def test_el_tope_de_margen_comprometido_recorta_el_tamano():
    """G3. Con 550 $ ya bloqueados y un tope del 60 % (600 $), solo quedan
    50 $ libres, así que el margen no puede ser los 40 $ del cálculo... y
    aquí sí cabe. Con 580 $ bloqueados, en cambio, el margen se recorta."""
    d = dimensionar_posicion(
        **{**CUENTA, "saldo_disponible": 420, "saldo_bloqueado": 580},
        precio=100,
        sl=90,
        leverage_recomendado=5,
    )
    assert d.margen == Decimal("20.00")  # 60 % de 1.000 menos 580 ya bloqueados
    # Y el riesgo real es MENOR que el declarado: el tope recorta, nunca
    # infla. Un dimensionado que subiera el riesgo para «aprovechar» el
    # hueco sería exactamente el bug que G3 evita.
    assert riesgo_real(d, 100, 90) < Decimal("20")


def test_sin_margen_libre_no_hay_operacion():
    with pytest.raises(SinOperacion) as error:
        dimensionar_posicion(
            **{**CUENTA, "saldo_disponible": 400, "saldo_bloqueado": 600},
            precio=100,
            sl=90,
            leverage_recomendado=5,
        )
    assert error.value.motivo == "margen_insuficiente"


def test_el_saldo_disponible_es_un_tope_y_se_deja_un_5_por_ciento():
    """Con 30 $ disponibles el margen no puede ser 40, y tampoco 30: se
    reserva un 5 % para que el precio que confirme el usuario pueda diferir
    del de la señal sin romper el CHECK de la base de datos."""
    d = dimensionar_posicion(
        **{**CUENTA, "saldo_disponible": 30}, precio=100, sl=90, leverage_recomendado=5
    )
    assert d.margen == Decimal("28.50")


def test_un_stop_por_encima_del_precio_no_es_una_operacion():
    with pytest.raises(SinOperacion) as error:
        dimensionar_posicion(**CUENTA, precio=100, sl=110, leverage_recomendado=5)
    assert error.value.motivo == "stop_por_encima_del_precio"


def test_una_cuenta_sin_equity_no_dimensiona():
    with pytest.raises(SinOperacion) as error:
        dimensionar_posicion(
            **{**CUENTA, "equity": 0, "saldo_disponible": 0}, precio=100, sl=90
        )
    assert error.value.motivo == "equity_agotado"


def test_sin_leverage_recomendado_se_usa_el_tope_de_la_fase():
    """Una señal operable siempre trae `leverage_recomendado`, pero el
    ciclo del agente puede querer dimensionar sin él para comparar."""
    d = dimensionar_posicion(**CUENTA, precio=100, sl=90)
    assert d.apalancamiento == Decimal("5")


def test_el_piso_a_un_decimal_no_redondea_hacia_arriba():
    assert piso_a_un_decimal(Decimal("3.99")) == Decimal("3.9")
    assert piso_a_un_decimal(Decimal("4.0")) == Decimal("4.0")


def test_a_un_apalancamiento_de_1x_no_hay_liquidacion():
    assert precio_de_liquidacion(100, 1) == Decimal("0")


def test_el_riesgo_nunca_supera_el_declarado_en_un_barrido_de_stops():
    """La afirmación general, sobre 40 combinaciones de stop y tope.

    Un test por caso concreto demuestra que los casos concretos funcionan;
    este demuestra la propiedad que el módulo promete, que es lo que de
    verdad protege al experimento de un bug de riesgo.
    """
    for stop_pct in range(1, 41):  # stop del 1 % al 40 % por debajo
        sl = Decimal(100) - Decimal(stop_pct)
        try:
            d = dimensionar_posicion(**CUENTA, precio=100, sl=sl, leverage_recomendado=5)
        except SinOperacion:
            continue
        assert isinstance(d, Dimension)
        # Riesgo declarado: 20 $. Nunca más, con un céntimo de tolerancia
        # por el redondeo de la cantidad.
        assert riesgo_real(d, 100, sl) <= Decimal("20.01"), f"stop {stop_pct}%"
        # Y la liquidación nunca por ENCIMA del stop: si lo estuviera, el
        # riesgo real sería el margen entero y no el calculado.
        #
        # El caso de igualdad existe y es correcto: con un stop al 20 % y
        # 5x, la liquidación cae exactamente en el stop. El monitor cierra
        # por `liquidacion` (regla M1, que se evalúa primero) al mismo
        # precio al que habría cerrado por `sl`, y la pérdida es idéntica
        # —el margen entero, que aquí ES el riesgo declarado—. Bajar el
        # apalancamiento en ese punto no protegería de nada; por eso el
        # ajuste del paso 6 usa `>` y no `>=`.
        assert d.precio_liquidacion <= sl, f"stop {stop_pct}%"
        # El margen nunca por encima de lo que la cuenta puede comprometer.
        assert d.margen <= Decimal("600"), f"stop {stop_pct}%"
