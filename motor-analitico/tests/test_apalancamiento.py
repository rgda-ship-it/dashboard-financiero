import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from riesgo.apalancamiento import calcular_apalancamiento

# Firma bajo prueba: calcular_apalancamiento(atr_pct, fuerza, tope_duro, direccion).
# El 4.º parámetro es obligatorio a propósito: sin valor por defecto, ningún
# llamador nuevo puede volver a calcular apalancamiento ciego a la dirección.


def test_alcista_con_confluencia_media_suma_el_bonus():
    r = calcular_apalancamiento(2.4, "media", 5.0, "alcista")
    assert r.recomendado == 4.0
    assert r.referencia_volatilidad == 3.0
    assert r.tope == 5.0


def test_bajista_no_emite_numero_operable_pero_si_referencia():
    r = calcular_apalancamiento(2.4, "media", 5.0, "bajista")
    assert r.recomendado is None
    # La referencia es la base de volatilidad SIN bonus: es el insumo que
    # necesitaría un dimensionador de cortos, no una recomendación.
    assert r.referencia_volatilidad == 3.0
    assert "bajista" in r.motivo
    assert "3.0x" in r.motivo


def test_bajista_con_confluencia_alta_tampoco_recibe_bonus():
    # El bonus de +2,0x premia la alineación de indicadores en la dirección
    # de la operación implícita: sobre una lectura bajista nunca se aplica.
    r = calcular_apalancamiento(2.4, "alta", 5.0, "bajista")
    assert r.recomendado is None


def test_neutral_no_emite_numero_operable():
    r = calcular_apalancamiento(1.9, "baja", 5.0, "neutral")
    assert r.recomendado is None
    assert r.referencia_volatilidad == 3.0
    assert "sin confluencia direccional" in r.motivo


def test_alcista_con_fuerza_baja_si_emite_numero():
    # La fuerza baja ya comunica "señal no confirmada" por sí sola, y el
    # bonus de confluencia aquí ya es 0: la dirección es coherente con el
    # riel, así que el número se emite.
    r = calcular_apalancamiento(1.9, "baja", 5.0, "alcista")
    assert r.recomendado == 3.0


def test_volatilidad_alta_sin_confluencia_cae_al_minimo():
    r = calcular_apalancamiento(7.2, "baja", 5.0, "alcista")
    assert r.recomendado == 1.0
    assert r.motivo == "volatilidad alta, sin confluencia — apalancamiento mínimo"


def test_el_tope_duro_no_se_supera_con_bonus_maximo():
    # base 3,0 + bonus 2,0 = 5,0, recortado al tope de 3,0.
    r = calcular_apalancamiento(0.5, "alta", 3.0, "alcista")
    assert r.recomendado == 3.0


def test_clamp_exacto_en_el_tope():
    r = calcular_apalancamiento(0.5, "alta", 5.0, "alcista")
    assert r.recomendado == 5.0


def test_tope_no_positivo_lanza_valueerror():
    try:
        calcular_apalancamiento(0.0, "alta", 0.0, "alcista")
    except ValueError:
        return
    raise AssertionError("Se esperaba ValueError con tope_duro = 0")


def test_tope_por_debajo_de_1x_sigue_siendo_infranqueable():
    # Regla protegida nº1 del README: el tope duro NUNCA es superable.
    # Con el suelo de 1,0x aplicado después del clamp, un tope de 0,5x
    # (valor positivo, luego válido) devolvía 1.0 — el doble del tope.
    r = calcular_apalancamiento(2.0, "alta", 0.5, "alcista")
    assert r.recomendado is not None
    assert r.recomendado <= 0.5


def test_volatilidad_no_disponible_degrada_al_minimo():
    # Toda comparación con NaN es falsa, así que el cálculo caía en el
    # tramo "volatilidad baja" —el más generoso— sobre un activo del que
    # no se conoce la volatilidad. El modo degradado debe apuntar al
    # mínimo y decirlo.
    r = calcular_apalancamiento(float("nan"), "media", 5.0, "alcista")
    assert r.recomendado is None
    assert r.referencia_volatilidad == 1.0
    assert "volatilidad no disponible" in r.motivo


def test_invariante_del_tope_en_todas_las_combinaciones():
    combinaciones = [
        (2.4, "media", 5.0, "alcista"),
        (2.4, "media", 5.0, "bajista"),
        (2.4, "alta", 5.0, "bajista"),
        (1.9, "baja", 5.0, "neutral"),
        (1.9, "baja", 5.0, "alcista"),
        (7.2, "baja", 5.0, "alcista"),
        (0.5, "alta", 3.0, "alcista"),
        (0.5, "alta", 5.0, "alcista"),
    ]
    for atr_pct, fuerza, tope, direccion in combinaciones:
        r = calcular_apalancamiento(atr_pct, fuerza, tope, direccion)
        assert r.recomendado is None or r.recomendado <= tope, (atr_pct, fuerza, tope, direccion)
        # La referencia se somete exactamente al mismo clamp.
        assert math.isfinite(r.referencia_volatilidad)
        assert 1.0 <= r.referencia_volatilidad <= tope, (atr_pct, fuerza, tope, direccion)


if __name__ == "__main__":
    tests = [
        test_alcista_con_confluencia_media_suma_el_bonus,
        test_bajista_no_emite_numero_operable_pero_si_referencia,
        test_bajista_con_confluencia_alta_tampoco_recibe_bonus,
        test_neutral_no_emite_numero_operable,
        test_alcista_con_fuerza_baja_si_emite_numero,
        test_volatilidad_alta_sin_confluencia_cae_al_minimo,
        test_el_tope_duro_no_se_supera_con_bonus_maximo,
        test_clamp_exacto_en_el_tope,
        test_tope_no_positivo_lanza_valueerror,
        test_tope_por_debajo_de_1x_sigue_siendo_infranqueable,
        test_volatilidad_no_disponible_degrada_al_minimo,
        test_invariante_del_tope_en_todas_las_combinaciones,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
