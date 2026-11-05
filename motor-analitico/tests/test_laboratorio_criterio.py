"""
Criterio común del laboratorio (doc fase-3/12): cuenta global de pruebas,
el diseño contra el azar y las ventanas móviles. Sin red.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio import criterio  # noqa: E402
from laboratorio.motor import Operacion  # noqa: E402


def test_el_percentil_sube_con_las_pruebas_previas_sin_volverse_imposible():
    assert criterio.percentil_por_previas(0) == 90
    assert criterio.percentil_por_previas(3) == 95
    assert criterio.percentil_por_previas(32) == 98
    assert criterio.percentil_por_previas(10_000) == 99
    seguidos = [criterio.percentil_por_previas(n) for n in range(200)]
    assert seguidos == sorted(seguidos)


def test_una_prueba_sin_registrar_no_se_puede_juzgar():
    with pytest.raises(KeyError, match="regístrala"):
        criterio.percentil_exigido("idea_sin_registrar")
    assert criterio.previas("actual") == 0
    assert criterio.percentil_exigido("hora_cripto") == 98


def test_el_registro_no_repite_nombres_y_va_en_orden_de_fecha():
    nombres = [r[0] for r in criterio.REGISTRO]
    assert len(nombres) == len(set(nombres))
    fechas = [r[1] for r in criterio.REGISTRO]
    assert fechas == sorted(fechas)


def _op(fecha, r):
    f = pd.Timestamp(fecha)
    return Operacion(activo="X", clase="accion", estrategia="t", fecha_senal=f, fecha_entrada=f,
                     fecha_salida=f, precio_entrada=100, sl_inicial=99, tp=None, precio_salida=100 + r,
                     motivo="regla", dias=1)


def test_las_ventanas_moviles_eligen_con_el_pasado_y_miden_en_el_bloque():
    fechas = pd.date_range("2020-01-01", "2024-12-31", freq="D")
    # «buena» gana hasta 2022 y luego pierde; «estable» siempre gana poco.
    buena = [_op(f, 1.0 if f.year <= 2022 else -1.0) for f in fechas]
    estable = [_op(f, 0.1) for f in fechas]
    m = criterio.ventanas_moviles({"buena": buena, "estable": estable}, fechas[0], fechas[-1])
    assert len(m.bloques) == criterio.VENTANAS - 1
    # Con lo anterior se elige «buena» siempre (su media del pasado es mayor
    # mientras le queda historia ganadora) y los bloques de 2023–2024 pierden.
    assert m.bloques[0][0] == "buena" and m.bloques[0][2] == pytest.approx(1.0)
    assert m.bloques[-1][2] < 0
    assert m.operaciones == sum(b[1] for b in m.bloques)
    assert m.operaciones < len(buena)   # el primer bloque no se mide


def test_ventanas_moviles_sin_operaciones_suficientes_no_aprueban():
    fechas = pd.date_range("2020-01-01", periods=10, freq="D")
    m = criterio.ventanas_moviles({"a": [_op(f, 1.0) for f in fechas]}, fechas[0], fechas[-1])
    assert m.expectativa_r is None and not m.aprueba


def test_el_informe_por_velas_mide_el_diseno_y_las_ventanas_moviles(monkeypatch):
    from laboratorio import intradia
    n = 24 * 120
    rng = np.random.default_rng(3)
    datos = {}
    for k in range(2):
        c = 100 + np.cumsum(rng.normal(0, 0.3, n))
        o = np.concatenate([[c[0]], c[:-1]])
        idx = pd.date_range("2026-01-01", periods=n, freq="h")
        datos[(f"x{k}", "cripto")] = pd.DataFrame({"Open": o, "High": np.maximum(o, c) + 0.2,
                                                   "Low": np.minimum(o, c) - 0.2, "Close": c, "Volume": 1.0},
                                                  index=idx)
    monkeypatch.setattr(intradia, "spread_de", lambda s, c: (lambda p: 0.0))
    texto = intradia.informe("hora_cripto", datos, semillas=3)
    assert "Ventanas móviles" in texto
    assert "Azar en diseño" in texto
    assert "mínimo 98 %, con 31 ideas probadas antes" in texto
