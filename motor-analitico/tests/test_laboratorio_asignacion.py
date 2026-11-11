"""La exposición mensual contra comprar y mantener (doc fase-4/00)."""

import numpy as np
import pandas as pd

from laboratorio import asignacion, criterio


def _datos(cierres: list[float], simbolo: str = "SPY") -> dict:
    """Un mes de 20 sesiones por cada cierre: todo el mes al mismo precio."""
    dias = pd.bdate_range("2010-01-01", periods=1, freq="B")
    filas, fechas = [], []
    mes = pd.Period("2010-01", "M")
    for c in cierres:
        for d in pd.bdate_range(mes.start_time, mes.end_time)[:20]:
            fechas.append(d)
            filas.append({"Open": c, "High": c, "Low": c, "Close": c, "Volume": 1})
        mes += 1
    del dias
    return {(simbolo, "accion"): pd.DataFrame(filas, index=pd.DatetimeIndex(fechas))}


def test_las_tres_pruebas_estan_registradas():
    for prueba in asignacion.PRUEBAS:
        assert criterio.percentil_exigido(prueba) >= 98


def test_la_tendencia_decide_con_el_mes_anterior():
    # Sube 12 meses, se hunde en el 13 y sigue abajo.
    datos = _datos([100 + i for i in range(12)] + [50, 50, 50])
    _, cierres, _ = asignacion.mensual(datos)
    pesos = asignacion.pesos_tendencia(cierres, 10)["SPY"]
    # El mes de la caída todavía está dentro: no pudo verla antes.
    assert pesos.iloc[12] == 1.0
    # Al mes siguiente ya está fuera.
    assert pesos.iloc[13] == 0.0
    # Sin media todavía, fuera.
    assert pesos.iloc[5] == 0.0


def test_mantener_rinde_como_el_activo_menos_la_entrada():
    datos = _datos([100, 110, 121, 133.1])
    aperturas, cierres, _ = asignacion.mensual(datos)
    netos = asignacion.simular(aperturas, asignacion.pesos_mantener(cierres), {"SPY": "accion"})
    assert len(netos) == 3
    # Primer mes: +10 % menos medio spread de 0,03 $ sobre 100 $.
    assert abs(netos.iloc[0] - (0.10 - 0.015 / 100)) < 1e-9
    # Después no opera: sin coste.
    assert abs(netos.iloc[1] - 0.10) < 1e-9


def test_fuera_del_mercado_no_gana_ni_pierde():
    datos = _datos([100, 50, 25, 10])
    aperturas, cierres, _ = asignacion.mensual(datos)
    netos = asignacion.simular(aperturas, asignacion.pesos_mantener(cierres) * 0, {"SPY": "accion"})
    assert (netos == 0).all()


def test_desplazar_conserva_la_exposicion():
    pesos = pd.DataFrame({"A": [1, 1, 0, 0, 0, 1, 0, 1] * 5, "B": [0, 1] * 20}, dtype=float)
    rng = np.random.default_rng(1)
    movido = asignacion.desplazar(pesos, rng, juntos=False)
    assert np.allclose(movido.sum(), pesos.sum())
    assert not movido.equals(pesos)
    junto = asignacion.desplazar(pesos, rng, juntos=True)
    assert np.allclose(junto.sum(axis=1).sort_values().to_numpy(), pesos.sum(axis=1).sort_values().to_numpy())


def test_la_volatilidad_reduce_tras_un_mes_agitado():
    rng = np.random.default_rng(0)
    fechas = pd.bdate_range("2010-01-01", "2012-12-31")
    ruido = rng.normal(0, 0.005, len(fechas))
    agitado = (fechas >= "2012-06-01") & (fechas < "2012-07-01")
    ruido[agitado] *= 6
    precio = 100 * np.cumprod(1 + ruido)
    df = pd.DataFrame({"Open": precio, "High": precio, "Low": precio, "Close": precio, "Volume": 1}, index=fechas)
    _, cierres, diarios = asignacion.mensual({("SPY", "accion"): df})
    pesos = asignacion.pesos_volatilidad(cierres, diarios, 21)["SPY"]
    assert pesos[pd.Period("2012-06", "M")] > 0.6      # aún no lo ha visto
    assert pesos[pd.Period("2012-07", "M")] < 0.4      # reduce al mes siguiente
    assert pesos.max() <= 1.0
