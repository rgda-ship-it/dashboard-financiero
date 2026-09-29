"""
Coherencia entre la guía de lectura y lo que el sistema hace (H-34).

Deuda técnica nº5 de la Fase 1: la guía (`frontend/src/guia.js`) explica
los umbrales con números escritos a mano, y nada impedía que alguien
cambiara un umbral del motor sin tocar el texto. Una guía que dice 6 %
cuando el motor corta en 5 % es peor que no tener guía: enseña a leer mal
la pantalla.

Estas pruebas LEEN los números del texto de la guía y comprueban que el
código se comporta así. Por eso cambiar un umbral en
`riesgo/apalancamiento.py` sin tocar `guia.js` —o al revés— pone el build
en rojo, que es el criterio de aceptación de H-34.

Lo que vive en PostgreSQL (los cinco límites del servidor, el corte
semanal, el umbral de las prácticas) se contrasta contra el texto de las
migraciones: es la única fuente que existe de esos números.
"""

import re
import sys
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(RAIZ / "motor-analitico"))

from riesgo.apalancamiento import calcular_apalancamiento  # noqa: E402
from riesgo.maquina_fases import ParametrosRiesgo  # noqa: E402

GUIA = (RAIZ / "frontend" / "src" / "guia.js").read_text(encoding="utf-8")
SQL_SIMULADOR = (RAIZ / "supabase" / "migrations" / "0011_simulador.sql").read_text(encoding="utf-8")
SQL_AGENTES = (RAIZ / "supabase" / "migrations" / "0013_agentes.sql").read_text(encoding="utf-8")


def _uno(patron: str, texto: str = GUIA) -> str:
    """El número que captura `patron`, exigiendo que aparezca UNA vez.
    Si la frase cambia de redacción, la prueba falla diciendo cuál: es
    mejor que dejar de comprobar en silencio."""
    hallados = re.findall(patron, texto)
    assert len(hallados) == 1, f"se esperaba una coincidencia de {patron!r}, hay {len(hallados)}"
    return hallados[0]


def _num(valor: str) -> float:
    return float(valor.replace(",", "."))


# ── Apalancamiento ──────────────────────────────────────────────────

def test_tramos_de_volatilidad_de_la_guia_son_los_del_motor():
    alta, media_desde, media_hasta, baja = _uno(
        r"alta ≥ (\d+) %\s+·\s+media (\d+)–(\d+) %\s+·\s+baja < (\d+) %")
    assert media_hasta == alta and baja == media_desde

    base_alta = re.findall(r"(\d+\.\d)×\s+si ATR % ≥ (\d+)", GUIA)
    base_baja = re.findall(r"(\d+\.\d)×\s+si ATR % < (\d+)", GUIA)
    assert len(base_alta) == 2 and len(base_baja) == 1
    (b_alta, u_alta), (b_media, u_media) = base_alta
    b_baja, u_baja = base_baja[0]
    assert u_alta == alta and u_media == media_desde == u_baja

    u_alta, u_media = float(u_alta), float(u_media)
    b_alta, b_media, b_baja = float(b_alta), float(b_media), float(b_baja)

    def base(atr):
        # Con confluencia baja no hay bonus: el recomendado ES la base.
        return calcular_apalancamiento(atr, "baja", 10.0, "alcista").recomendado

    # Cada umbral, justo en el borde y justo por debajo.
    assert base(u_alta) == b_alta
    assert base(u_alta - 0.01) == b_media
    assert base(u_media) == b_media
    assert base(u_media - 0.01) == b_baja


def test_bonus_de_confluencia_de_la_guia_es_el_del_motor():
    alta, media, baja = (_num(x) for x in _uno(
        r"ajuste = \+(\d\.\d)× alta · \+(\d\.\d)× media · \+(\d\.\d)× baja"))
    b_baja = _num(re.findall(r"(\d+\.\d)×\s+si ATR % < \d+", GUIA)[0])

    def rec(fuerza):
        return calcular_apalancamiento(1.0, fuerza, 10.0, "alcista").recomendado

    assert rec("alta") == b_baja + alta
    assert rec("media") == b_baja + media
    assert rec("baja") == b_baja + baja


def test_topes_duros_de_la_guia_son_los_de_la_maquina_de_fases():
    p = ParametrosRiesgo()
    assert _num(_uno(r"Fase 1 · Aceleración\s+→ tope duro (\d+)×")) == p.leverage_tope_fase1
    assert _num(_uno(r"Fase 2 · Consolidación\s+→ tope duro (\d+)×")) == p.leverage_tope_fase2
    # Y el tope que aplica el servidor (G1) es el mismo.
    assert "then 3.0 else 5.0" in SQL_SIMULADOR
    assert (p.leverage_tope_fase2, p.leverage_tope_fase1) == (3.0, 5.0)


def test_criterios_de_transicion_de_la_guia_son_los_de_la_maquina_de_fases():
    p = ParametrosRiesgo()
    assert _num(_uno(r"(\d+)× el capital inicial")) == p.multiplo_transicion
    assert -_num(_uno(r"−(\d+) % de caída desde el pico")) == p.drawdown_limite_pct
    assert int(_uno(r"u (\d+) operaciones cerradas")) == p.max_operaciones_fase1


# ── Los cinco límites del servidor (0011) ───────────────────────────

def test_limites_del_servidor_de_la_guia_son_los_de_rpc_abrir_orden():
    riesgo = _uno(r"riesgo por operación ≤ (\d+) % del equity")
    margen = _uno(r"margen comprometido total ≤ (\d+) % del equity")
    minutos = _uno(r"solo señales operables y de menos de (\d+) minutos")

    assert f"v_riesgo_pct > {riesgo} then" in SQL_SIMULADOR
    assert re.search(rf"margen_comprometido_max_pct numeric\(5, 2\) not null default {margen}\b", SQL_SIMULADOR)
    assert re.search(rf"antiguedad_senal_max_min\s+int not null default {minutos}\b", SQL_SIMULADOR)


# ── Agentes (0013) ──────────────────────────────────────────────────

def test_umbrales_del_corte_semanal_de_la_guia_son_los_de_la_migracion():
    validada = _num(_uno(r"validada\s+ratio ≥ (\d,\d+)"))
    aviso = _num(_uno(r"aviso\s+ratio ≥ (\d,\d+)"))
    deficiente = _num(_uno(r"deficiente\s+ratio < (\d,\d+)"))
    assert deficiente == aviso
    assert f"v_ratio >= {validada:.2f} then 'validada'" in SQL_AGENTES
    assert f"v_ratio >= {aviso:.2f} then 'aviso'" in SQL_AGENTES


def test_umbral_de_publicacion_de_practicas_de_la_guia_es_el_de_la_migracion():
    ops = _uno(r"se publica si:\s+≥ (\d+) operaciones")
    acierto = _num(_uno(r"≥ (\d+) % cerradas en objetivo")) / 100
    # Los dos lados: quien destila y el CHECK de la tabla (N11).
    assert f"having count(*) >= {ops}" in SQL_AGENTES
    assert f"::numeric / count(*) >= {acierto:.2f}" in SQL_AGENTES
    assert f"'ops')::int, 0) >= {ops}" in SQL_AGENTES
    assert f"confianza >= {acierto:.2f}" in SQL_AGENTES


@pytest.mark.parametrize("nombre, meta, riesgo, posiciones, rr, margen", [
    ("Prudencia", "2", "1,5", "3", "2,0", "40"),
    ("Cadencia", "5", "3,0", "2", "1,5", "55"),
    ("Audacia", "7", "5,0", "2", "1,2", "60"),
])
def test_tabla_de_perfiles_de_la_guia_es_la_semilla(nombre, meta, riesgo, posiciones, rr, margen):
    fila = _uno(rf"{nombre}\s+(\d+) %\s+(\d,\d) %\s+(\d+)\s+(\d,\d)\s+[a-z ]+?\s+(\d+) %")
    assert fila == (meta, riesgo, posiciones, rr, margen)

    semilla = re.search(rf"\('{nombre}', (\d+)\.00, '(\{{.*?\}})'\)", SQL_AGENTES, re.S)
    assert semilla, f"no se encontró la semilla de {nombre}"
    cuerpo = semilla.group(2)

    def campo(clave):
        return re.search(rf'"{clave}": ([\d.]+)', cuerpo).group(1)

    assert semilla.group(1) == meta
    assert float(campo("riesgo_pct_operacion")) == _num(riesgo)
    assert int(campo("max_posiciones_abiertas")) == int(posiciones)
    assert float(campo("rr_minimo")) == _num(rr)
    assert float(campo("margen_comprometido_max_pct")) == float(margen)


# ── Poder de trading (0014, D15) ────────────────────────────────────

SQL_PODER = (RAIZ / "supabase" / "migrations" / "0014_poder_trading.sql").read_text(encoding="utf-8")


def test_escalas_de_poder_de_trading_de_la_guia_son_las_de_la_migracion():
    def entero(texto):
        return int(texto.replace(".", ""))

    guia = [(entero(e), entero(p)) for e, p in
            re.findall(r"equity ≥\s+([\d.]+) \$\s+→\s+([\d.]+) \$", GUIA)]
    sql = [(int(e), int(p)) for e, p in
           re.findall(r"when p_equity >=\s+(\d+) then\s+(\d+)", SQL_PODER)]
    assert len(guia) == 8
    assert sorted(guia) == sorted(sql)
    # Y el tramo de abajo: 20 veces el equity en los dos sitios.
    assert "20 × equity" in GUIA and "p_equity * 20" in SQL_PODER
