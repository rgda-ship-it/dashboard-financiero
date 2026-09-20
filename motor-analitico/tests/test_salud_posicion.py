import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from indicadores.tecnicos import ResultadoConfluencia
from riesgo.salud_posicion import (
    PosicionCargada,
    calcular_diagnostico,
    evaluar_deterioro_tecnico,
)


def confluencia(alcistas: int, bajistas: int) -> ResultadoConfluencia:
    """Confluencia sintética: solo importan los dos conteos, que es lo
    único que mira el diagnóstico de salud."""
    total = alcistas + bajistas
    if total == 0 or max(alcistas, bajistas) == 1:
        fuerza = "baja"
    elif max(alcistas, bajistas) == 2:
        fuerza = "media"
    else:
        fuerza = "alta"
    return ResultadoConfluencia(
        senales=[],
        indicadores_alcistas=alcistas,
        indicadores_bajistas=bajistas,
        fuerza=fuerza,
        resumen="sintética",
    )


def diagnosticar(alcistas, bajistas, deterioro_fundamental, monto=1000.0):
    posicion = PosicionCargada(ticker="TEST", precio_compra=100.0, monto_invertido=monto)
    return calcular_diagnostico(
        posicion, 110.0, confluencia(alcistas, bajistas), deterioro_fundamental
    )


def test_dos_bajistas_sin_alcistas_y_deterioro_fundamental_es_rojo():
    assert diagnosticar(0, 2, True).nivel_salud.value == "rojo"


def test_dominancia_alcista_no_tapa_el_deterioro_fundamental():
    # El caso 24 de la especificación esperaba "verde" aquí, pero se
    # contradecía con su propia restricción de §3.2 (fila 6): el cambio
    # aprobado toca ÚNICAMENTE lo que devuelve evaluar_deterioro_tecnico(),
    # y los umbrales >= 2 / >= 1 se conservan literales. Con a=3 / b=2 el
    # deterioro técnico ya es 0, pero la rama de ámbar es
    # `senales >= 1 OR deterioro_fundamental`, así que el flag fundamental
    # dispara ámbar por sí solo.
    #
    # Se resuelve a favor del comportamiento actual, no del caso 24: que la
    # dominancia alcista silenciara un EPS negativo sería tapar deterioro
    # fundamental con momento técnico, justo lo que este diagnóstico existe
    # para evitar. La confluencia decide el deterioro TÉCNICO; no tiene
    # autoridad para anular el fundamental.
    assert diagnosticar(3, 2, True).nivel_salud.value == "ambar"
    # Y sin el flag fundamental, la misma confluencia sí queda en verde:
    # es la parte del caso 24 que sí se sostiene.
    assert diagnosticar(3, 2, False).nivel_salud.value == "verde"


def test_empate_mantiene_la_vigilancia_sobre_capital_ya_expuesto():
    # El >= de salud (frente al > de rotación) es deliberado: aquí hay
    # capital YA expuesto, así que el empate no se descarta.
    assert diagnosticar(2, 2, True).nivel_salud.value == "rojo"


def test_dominancia_alcista_sin_deterioro_fundamental_es_verde():
    # Antes daba ámbar: se contaba el único bajista en crudo aunque la
    # lectura dominante fuese alcista.
    assert diagnosticar(2, 1, False).nivel_salud.value == "verde"


def test_un_bajista_sin_alcistas_sigue_siendo_ambar():
    assert diagnosticar(0, 1, False).nivel_salud.value == "ambar"


def test_sin_senales_es_verde():
    assert diagnosticar(0, 0, False).nivel_salud.value == "verde"


def test_el_monto_invertido_no_participa_en_el_nivel_de_salud():
    # Regla de diseño no negociable: el monto solo alimenta el P&L
    # informativo, nunca una rama de decisión.
    escenarios = [(0, 2, True), (3, 2, True), (2, 2, True), (2, 1, False),
                  (0, 1, False), (0, 0, False)]
    for alcistas, bajistas, fundamental in escenarios:
        pequeno = diagnosticar(alcistas, bajistas, fundamental, monto=1.0)
        grande = diagnosticar(alcistas, bajistas, fundamental, monto=1_000_000.0)
        assert pequeno.nivel_salud == grande.nivel_salud, (alcistas, bajistas, fundamental)
        assert pequeno.mensaje == grande.mensaje
        # El monto sí cambia el P&L absoluto, que es su único uso permitido.
        assert pequeno.pnl_absoluto != grande.pnl_absoluto


def test_evaluar_deterioro_tecnico_devuelve_cero_con_dominancia_alcista():
    assert evaluar_deterioro_tecnico(confluencia(3, 2)) == 0
    assert evaluar_deterioro_tecnico(confluencia(2, 2)) == 2
    assert evaluar_deterioro_tecnico(confluencia(0, 2)) == 2
    assert evaluar_deterioro_tecnico(confluencia(0, 0)) == 0


if __name__ == "__main__":
    tests = [
        test_dos_bajistas_sin_alcistas_y_deterioro_fundamental_es_rojo,
        test_dominancia_alcista_no_tapa_el_deterioro_fundamental,
        test_empate_mantiene_la_vigilancia_sobre_capital_ya_expuesto,
        test_dominancia_alcista_sin_deterioro_fundamental_es_verde,
        test_un_bajista_sin_alcistas_sigue_siendo_ambar,
        test_sin_senales_es_verde,
        test_el_monto_invertido_no_participa_en_el_nivel_de_salud,
        test_evaluar_deterioro_tecnico_devuelve_cero_con_dominancia_alcista,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
