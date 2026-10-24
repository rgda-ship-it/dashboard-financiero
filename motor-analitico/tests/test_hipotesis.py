"""
Fase 3, I3 (doc fase-3/01 §5): la prueba automática de las hipótesis y la
concordancia del laboratorio con producción.
"""

import sys
from datetime import date
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio import hipotesis  # noqa: E402
from laboratorio.concordancia import emparejar, medir  # noqa: E402
from tests.test_laboratorio import _serie_aleatoria  # noqa: E402

CRITERIO = {"mejora_r_min": 0.05, "ic90_sin_cero": True, "percentil_azar_min": 90, "pruebas_previas": 0}


def _m(ops, exp, ic_bajo=0.05):
    return SimpleNamespace(operaciones=ops, expectativa_r=exp, ic90=(ic_bajo, exp + 0.3))


# ---------------------------------------------------------------------------
# Veredicto
# ---------------------------------------------------------------------------

def test_el_percentil_exigido_sube_con_las_pruebas_y_tiene_techo():
    assert hipotesis.percentil_exigido(CRITERIO) == 90
    assert hipotesis.percentil_exigido({**CRITERIO, "pruebas_previas": 4}) == 94
    assert hipotesis.percentil_exigido({**CRITERIO, "pruebas_previas": 40}) == 99


def test_valida_con_mejora_intervalo_y_azar():
    ok, motivos, det = hipotesis.juzgar(_m(80, 0.10), _m(60, 0.30), [0.0] * 19 + [0.5], CRITERIO)
    assert ok and not motivos and det["percentil_azar"] == 95


def test_refuta_sin_muestra():
    ok, motivos, _ = hipotesis.juzgar(_m(80, 0.10), _m(12, 0.90), [0.0] * 20, CRITERIO)
    assert not ok and "solo 12 operaciones" in motivos[0]


def test_refuta_sin_mejora_suficiente():
    ok, motivos, _ = hipotesis.juzgar(_m(80, 0.28), _m(60, 0.30), [0.0] * 20, CRITERIO)
    assert not ok and any("mejora" in m for m in motivos)


def test_refuta_si_el_intervalo_incluye_el_cero():
    ok, motivos, _ = hipotesis.juzgar(_m(80, 0.0), _m(60, 0.30, ic_bajo=-0.05), [0.0] * 20, CRITERIO)
    assert not ok and any("intervalo" in m for m in motivos)


def test_refuta_si_no_supera_al_azar_exigido():
    azar = [0.0] * 17 + [0.5] * 3          # supera al 85 %
    ok, motivos, _ = hipotesis.juzgar(_m(80, 0.10), _m(60, 0.30), azar, CRITERIO)
    assert not ok and any("tiradas al azar" in m for m in motivos)
    # Con pruebas previas el listón sube aunque el resultado sea el mismo.
    azar = [0.0] * 19 + [0.5]              # supera al 95 %
    assert hipotesis.juzgar(_m(80, 0.10), _m(60, 0.30), azar, CRITERIO)[0]
    assert not hipotesis.juzgar(_m(80, 0.10), _m(60, 0.30), azar, {**CRITERIO, "pruebas_previas": 6})[0]


# ---------------------------------------------------------------------------
# probar
# ---------------------------------------------------------------------------

AGENTE = {"rr_minimo": 1.2, "atr_pct_min": None, "atr_pct_max": None, "tp_parcial": None,
          "salida_deterioro": True, "clases_admitidas": ["accion"], "version": 3}


def _hip(cambio, clases=("accion",)):
    return {"id": 1, "enunciado": "e", "criterio": CRITERIO,
            "experimento": {"cambio": cambio, "clases": list(clases), "periodo": "5y"}}


def test_un_cambio_que_el_laboratorio_no_modela_no_se_ejecuta():
    estado, res = hipotesis.probar(_hip({"rotacion": 0}), AGENTE, {("X", "accion"): _serie_aleatoria()})
    assert estado == "no_ejecutable" and "rotacion" in res["motivos"][0]


def test_sin_velas_de_la_clase_no_se_ejecuta():
    estado, _ = hipotesis.probar(_hip({"deterioro": 0}, clases=("cripto",)), AGENTE,
                                 {("X", "accion"): _serie_aleatoria()})
    assert estado == "no_ejecutable"


def test_probar_de_principio_a_fin():
    datos = {("X", "accion"): _serie_aleatoria(semilla=3), ("Y", "accion"): _serie_aleatoria(semilla=5)}
    estado, res = hipotesis.probar(_hip({"deterioro": 0}), AGENTE, datos, semillas=3)
    assert estado in ("validada", "refutada")
    assert res["veredicto"] == estado and res["activos"] == 2
    assert res["agente_actual"]["operaciones"] > 0 and res["con_cambio"]["operaciones"] > 0
    assert res["version_estrategia_probada"] == 3
    assert 0 < res["probabilidad_azar"] < 1


# ---------------------------------------------------------------------------
# Concordancia
# ---------------------------------------------------------------------------

def test_emparejar_con_holgura_y_una_sola_vez():
    reales = [date(2026, 10, 13), date(2026, 10, 14), date(2026, 10, 20)]
    lab = [date(2026, 10, 12), date(2026, 10, 30)]
    # El 12 empareja con el 13 (un día antes); el 14 ya no lo tiene; el 20, nada.
    assert emparejar(reales, lab) == (1, 1)
    # Un día después todavía cuenta; dos no.
    assert emparejar([date(2026, 10, 13)], [date(2026, 10, 14)]) == (1, 1)
    assert emparejar([date(2026, 10, 13)], [date(2026, 10, 15)]) == (0, 0)


def test_medir_avisa_si_la_concordancia_es_baja():
    m = medir({("A", "accion"): [date(2026, 10, 13), date(2026, 10, 20)]},
              {("A", "accion"): [date(2026, 10, 13)], ("B", "accion"): [date(2026, 10, 14)]})
    assert (m["reales"], m["reales_con_gemela"], m["laboratorio"], m["laboratorio_con_real"]) == (2, 1, 2, 1)
    assert m["pct_reales"] == 50.0 and "baja" not in m["texto"]
    assert "baja" in medir({("A", "accion"): [date(2026, 10, 13)]}, {})["texto"]


# ---------------------------------------------------------------------------
# El flujo completo, con un cliente de Supabase falso
# ---------------------------------------------------------------------------

class ClienteFalso:
    def __init__(self):
        self.actualizaciones, self.insertados = [], []

    def seleccionar(self, tabla, params=None):
        if tabla == "agente_hipotesis":
            return [{"id": 7, "agente_id": 1, "enunciado": "Sin deterioro", "criterio": CRITERIO,
                     "experimento": {"cambio": {"deterioro": 0}, "clases": ["accion"], "periodo": "5y"}}]
        if tabla == "agentes":
            return [{"id": 1, "nombre": "Prudencia", "estrategia": AGENTE, "version_estrategia": 3,
                     "creado_en": "2025-06-01T00:00:00+00:00"}]
        if tabla == "cuentas_simulacion":
            return [{"id": 10}]
        if tabla == "activos":
            return [{"id": 100, "simbolo": "X", "clase": "accion"}]
        if tabla == "ordenes":
            return [{"activo_id": 100, "fecha_entrada": "2026-01-05T14:30:00+00:00"}]
        return []

    def actualizar(self, tabla, filtro, cambios):
        self.actualizaciones.append((tabla, filtro, cambios))

    def insertar(self, tabla, filas):
        self.insertados.append((tabla, filas))


def test_main_prueba_escribe_el_veredicto_y_avisa(monkeypatch, tmp_path):
    import escritor_supabase

    cliente = ClienteFalso()
    monkeypatch.setattr(escritor_supabase.ClienteSupabase, "desde_entorno", classmethod(lambda cls: cliente))
    monkeypatch.setattr(hipotesis, "cargar_datos", lambda clases, periodo="5y": {("X", "accion"): _serie_aleatoria()})
    monkeypatch.setattr(sys, "argv", ["hipotesis", "--semillas", "2"])
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    assert hipotesis.main() == 0

    estados = [c["estado"] for t, f, c in cliente.actualizaciones if t == "agente_hipotesis"]
    assert estados[0] == "en_prueba" and estados[-1] in ("validada", "refutada")
    final = cliente.actualizaciones[-1][2]
    assert final["resultado"]["concordancia"]["reales"] == 1
    assert cliente.insertados and cliente.insertados[0][0] == "eventos_sistema"
    assert (tmp_path / "laboratorio_salida" / "hipotesis.md").exists()


def test_main_sin_hipotesis_no_hace_nada(monkeypatch):
    import escritor_supabase

    cliente = ClienteFalso()
    cliente.seleccionar = lambda tabla, params=None: []
    monkeypatch.setattr(escritor_supabase.ClienteSupabase, "desde_entorno", classmethod(lambda cls: cliente))
    monkeypatch.setattr(sys, "argv", ["hipotesis"])
    assert hipotesis.main() == 0 and not cliente.actualizaciones


@pytest.mark.parametrize("cambio", [{"condicion": "macd_positivo"}, {"parcial_recorrido": 0.5, "parcial_mover": 1},
                                    {"sigue_atr": 2}])
def test_los_cambios_de_las_fuentes_se_ejecutan(cambio):
    estado, _ = hipotesis.probar(_hip(cambio), AGENTE, {("X", "accion"): _serie_aleatoria()}, semillas=1)
    assert estado in ("validada", "refutada")
