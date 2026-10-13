"""
Laboratorio de estrategias (doc 06): reglas de ejecución, causalidad,
medidas y veredicto. Sin red: series sintéticas.
"""

import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from laboratorio import metricas  # noqa: E402
from laboratorio.estrategias import ESTRATEGIAS  # noqa: E402
from laboratorio.motor import Entrada, Operacion, Posicion, simular  # noqa: E402

SIN_SPREAD = lambda precio: 0.0  # noqa: E731


def _df(filas):
    idx = pd.date_range("2025-01-01", periods=len(filas), freq="D")
    return pd.DataFrame(filas, columns=["Open", "High", "Low", "Close"], index=idx).assign(Volume=1e6)


class UnaVez:
    """Entra una sola vez, al cierre del día `dia`, con los niveles dados."""
    nombre = "prueba"

    def __init__(self, dia, sl, tp=None, salir_tras=None):
        self.dia, self.sl, self.tp, self.salir_tras = dia, sl, tp, salir_tras

    def preparar(self, df):
        return df

    def entrada(self, df, t):
        return Entrada(self.sl, self.tp) if t == self.dia else None

    def actualizar(self, df, t, pos):
        salir = self.salir_tras is not None and t - pos.indice_entrada + 1 >= self.salir_tras
        return pos.sl, salir


# ---------------------------------------------------------------------------
# Reglas de ejecución
# ---------------------------------------------------------------------------

def test_entra_en_la_apertura_siguiente_con_medio_spread_y_sale_al_objetivo():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (101, 106, 100, 105)])
    [op] = simular(df, UnaVez(0, sl=95, tp=104), lambda p: 0.2)
    assert op.precio_entrada == pytest.approx(100.1)
    assert op.motivo == "tp" and op.precio_salida == 104


def test_si_un_dia_toca_stop_y_objetivo_gana_el_stop():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 110, 90, 100)])
    [op] = simular(df, UnaVez(0, sl=95, tp=104), SIN_SPREAD)
    assert op.motivo == "sl" and op.precio_salida == 95


def test_un_hueco_mas_alla_del_stop_sale_a_la_apertura():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (90, 91, 88, 89)])
    [op] = simular(df, UnaVez(0, sl=95, tp=110), SIN_SPREAD)
    assert op.motivo == "hueco" and op.precio_salida == 90
    assert op.r == pytest.approx(-2.0)


def test_el_stop_se_compara_con_el_precio_de_venta():
    # Mínimo 95,05: el intermedio no toca 95, pero la venta (con 0,2 de
    # spread) sí: 94,95.
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (100, 101, 95.05, 100)])
    [op] = simular(df, UnaVez(0, sl=95, tp=110), lambda p: 0.2)
    assert op.motivo == "sl"


def test_la_salida_por_regla_se_ejecuta_en_la_apertura_siguiente():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (102, 103, 101, 102), (103, 104, 102, 103)])
    [op] = simular(df, UnaVez(0, sl=90, salir_tras=1), SIN_SPREAD)
    assert op.motivo == "regla" and op.precio_salida == 102 and op.fecha_salida == df.index[2]


def test_si_ya_abre_por_debajo_del_stop_no_hay_operacion():
    df = _df([(100, 101, 99, 100), (94, 95, 93, 94), (94, 95, 93, 94)])
    assert simular(df, UnaVez(0, sl=95, tp=110), SIN_SPREAD) == []


def test_lo_abierto_al_final_se_cierra_al_ultimo_cierre():
    df = _df([(100, 101, 99, 100), (100, 101, 99, 100), (101, 102, 100, 101)])
    [op] = simular(df, UnaVez(0, sl=90), SIN_SPREAD)
    assert op.motivo == "fin" and op.precio_salida == 101


# ---------------------------------------------------------------------------
# Causalidad: ninguna estrategia mira el futuro
# ---------------------------------------------------------------------------

def _serie_aleatoria(n=700, semilla=3):
    rng = np.random.default_rng(semilla)
    cierres = 100 * np.exp(np.cumsum(rng.normal(0.0004, 0.02, n)))
    aperturas = np.r_[cierres[0], cierres[:-1]] * np.exp(rng.normal(0, 0.004, n))
    altos = np.maximum(aperturas, cierres) * np.exp(np.abs(rng.normal(0, 0.008, n)))
    bajos = np.minimum(aperturas, cierres) * np.exp(-np.abs(rng.normal(0, 0.008, n)))
    df = _df(list(zip(aperturas, altos, bajos, cierres)))
    df["Volume"] = rng.uniform(5e5, 2e6, n)
    return df


@pytest.mark.parametrize("nombre", sorted(ESTRATEGIAS))
def test_las_senales_no_cambian_si_se_quita_el_futuro(nombre):
    df = _serie_aleatoria()
    estrategia = ESTRATEGIAS[nombre]()
    completo = estrategia.preparar(df)
    for t in range(220, len(df) - 1, 37):
        truncado = estrategia.preparar(df.iloc[: t + 1])
        a, b = estrategia.entrada(completo, t), estrategia.entrada(truncado, t)
        assert (a is None) == (b is None), (nombre, t)
        if a is not None:
            assert a.sl == pytest.approx(b.sl) and (a.tp is None) == (b.tp is None), (nombre, t)


@pytest.mark.parametrize("nombre", sorted(ESTRATEGIAS))
def test_cada_estrategia_opera_de_principio_a_fin(nombre):
    ops = simular(_serie_aleatoria(), ESTRATEGIAS[nombre](), lambda p: p * 0.001)
    assert all(o.sl_inicial < o.precio_entrada for o in ops)
    assert all(o.fecha_entrada > o.fecha_senal and o.fecha_salida >= o.fecha_entrada for o in ops)


# ---------------------------------------------------------------------------
# Medidas y veredicto
# ---------------------------------------------------------------------------

def _op(r, dia=0, dias=1):
    fecha = pd.Timestamp("2025-01-01") + pd.Timedelta(days=dia)
    return Operacion("X", "accion", "p", fecha, fecha, fecha + pd.Timedelta(days=dias),
                     100.0, 99.0, None, 100.0 + r, "sl", dias)


def test_las_medidas_de_una_muestra_conocida():
    m = metricas.medir([_op(2), _op(-1), _op(2), _op(-1)])
    assert m.operaciones == 4 and m.aciertos_pct == 50
    assert m.expectativa_r == pytest.approx(0.5)
    assert m.factor_beneficio == pytest.approx(2.0)
    assert m.ganancia_media_r == pytest.approx(2) and m.perdida_media_r == pytest.approx(-1)
    assert m.caida_maxima_pct == pytest.approx(1.0, abs=0.01)


def test_veredicto_exige_muestra_ventaja_y_confianza():
    pocas = metricas.medir([_op(1, i) for i in range(10)])
    assert metricas.veredicto(None, pocas)[0] is False

    rng = np.random.default_rng(1)
    con_ventaja = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([2.0, -1.0], 200, p=[0.5, 0.5]))])
    ok, motivos = metricas.veredicto(con_ventaja, con_ventaja)
    assert ok, motivos

    sin_ventaja = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([1.0, -1.0], 200))])
    ok, motivos = metricas.veredicto(None, sin_ventaja)
    assert not ok and motivos


def test_veredicto_detecta_el_desplome_frente_al_diseno():
    rng = np.random.default_rng(2)
    diseno = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([3.0, -1.0], 200))])
    validacion = metricas.medir([_op(r, i) for i, r in enumerate(rng.choice([1.3, -1.0], 400, p=[0.5, 0.5]))])
    ok, motivos = metricas.veredicto(diseno, validacion)
    assert not ok and any("tercio" in m for m in motivos)


# ---------------------------------------------------------------------------
# Robustez (doc 06 §3.7)
# ---------------------------------------------------------------------------

def test_ic_por_meses_es_mas_ancho_si_las_operaciones_van_en_bloque():
    # Mismas 120 operaciones: en bloques de 10 por mes del mismo signo, o
    # repartidas. Remuestrear meses debe dar un intervalo más ancho en bloque.
    rng = np.random.default_rng(4)
    signos = rng.choice([2.0, -1.0], 12)
    en_bloque = [_op(s, dia=30 * m + i) for m, s in enumerate(signos) for i in range(10)]
    repartidas = [_op(r, dia=3 * i) for i, r in enumerate(np.repeat(signos, 10)[rng.permutation(120)])]
    a, b = metricas.ic90_por_meses(en_bloque), metricas.ic90_por_meses(repartidas)
    assert (a[1] - a[0]) > (b[1] - b[0])
    assert metricas.ic90_por_meses([]) is None


def test_el_informe_de_robustez_cubre_todas_las_pruebas():
    from laboratorio import robustez
    datos = {(f"S{i}", "cripto"): _serie_aleatoria(n=500, semilla=i) for i in range(3)}
    extra = {("X-USD", "cripto"): _serie_aleatoria(n=500, semilla=9)}
    indice = datos[("S0", "cripto")].index
    corte = indice[0] + (indice[-1] - indice[0]) * 0.7
    texto = robustez.informe("reversion", "cripto", datos, extra, corte)
    for seccion in ("## 1.", "## 2.", "## 3.", "## 4.", "## 5.", "## 6.", "27 variantes", "X-USD"):
        assert seccion in texto, seccion


def test_las_criptos_de_2021_se_piden_tal_cual_a_yahoo():
    from laboratorio.datos import ticker_yahoo
    assert ticker_yahoo("FTT-USD", "cripto") == "FTT-USD"
    assert ticker_yahoo("bitcoin", "cripto") == "BTC-USD"
    assert ticker_yahoo("desconocida", "cripto") is None


# ---------------------------------------------------------------------------
# Cartera con las restricciones del agente (doc 07 §5)
# ---------------------------------------------------------------------------

def test_la_cartera_con_un_activo_y_sin_g6_opera_igual_que_el_motor():
    from laboratorio.cartera import simular_cartera
    df = _serie_aleatoria(n=900, semilla=5)
    estrategia = ESTRATEGIAS["tendencia"]()
    sueltas = simular(df, estrategia, lambda p: p * 0.001, "S", "cripto")
    res = simular_cartera({("S", "cripto"): df}, ESTRATEGIAS["tendencia"](), saldo=1e6, multiplo_g6=None)
    clave = lambda o: (o.fecha_entrada, o.fecha_salida, o.motivo, round(o.precio_salida, 6))  # noqa: E731
    assert [clave(o) for o in res.operaciones] == [clave(o) for o in sueltas]


def test_g6_deja_fuera_senales_y_la_curva_cuadra():
    from laboratorio.cartera import simular_cartera
    datos = {(f"S{i}", "cripto"): _serie_aleatoria(n=900, semilla=10 + i) for i in range(6)}
    libre = simular_cartera(datos, ESTRATEGIAS["tendencia"](), multiplo_g6=None)
    apretado = simular_cartera(datos, ESTRATEGIAS["tendencia"](), multiplo_g6=1.0)
    assert apretado.descartadas > 0
    assert len(apretado.operaciones) < len(libre.operaciones)
    assert (apretado.equity > 0).all()


# ---------------------------------------------------------------------------
# Segunda ronda (doc 06 §3.8): métricas del manual
# ---------------------------------------------------------------------------

def test_racha_de_perdidas_y_costes_sobre_el_bruto():
    ops = [_op(r, dia=i) for i, r in enumerate([1, -1, -1, -1, 2, -1, -1])]
    for o in ops:
        o.coste_r = 0.1
    m = metricas.medir(ops)
    assert m.racha_perdidas == 3
    # Bruto antes de costes: (1 + 0,1) + (2 + 0,1) = 3,2; costes 0,7 → 21,9 %.
    assert m.coste_pct == pytest.approx(0.7 / 3.2 * 100)


def test_el_motor_anota_regimen_y_coste_de_cada_operacion():
    from laboratorio.ejecutar import con_regimen
    df = con_regimen(_serie_aleatoria(n=900, semilla=6))
    ops = simular(df, ESTRATEGIAS["tendencia"](), lambda p: 0.5, "S", "cripto")
    assert ops and all(o.regimen in ("tendencia", "rango", "sin_dato") for o in ops)
    assert all(o.coste_r == pytest.approx(0.5 / (o.precio_entrada - o.sl_inicial)) for o in ops)


def test_el_informe_incluye_las_estrategias_nuevas_y_el_regimen():
    from laboratorio.ejecutar import con_regimen, informe
    df = con_regimen(_serie_aleatoria(n=900, semilla=8))
    ops = {n: simular(df, E(), lambda p: p * 0.001, "S", "cripto") for n, E in ESTRATEGIAS.items()}
    texto = informe(ops, df.index[600], df.index[0], df.index[-1], 1, [])
    for n in ESTRATEGIAS:
        assert f"## {n}" in texto
    assert "por régimen" in texto and "Racha" in texto


def test_el_informe_desglosa_por_sector_y_cuenta_valores_ganadores():
    from laboratorio.datos import universo_nombrado
    from laboratorio.ejecutar import por_sector
    activos, sectores = universo_nombrado("sp100")
    assert len(activos) >= 100 and sectores["NVDA"] == "Tecnología" and sectores["KO"] == "Consumo defensivo"
    ops = [_op(2, 0), _op(-1, 1), _op(1, 2)]
    ops[0].activo, ops[1].activo, ops[2].activo = "NVDA", "KO", "KO"
    texto = "\n".join(por_sector(ops, sectores, pd.Timestamp("2025-01-02")))
    assert "| Tecnología | 1 | 1 | 1 | +2.000 |" in texto
    assert "| Consumo defensivo | 1 | 0 | 2 | +0.000 |" in texto
    assert "1 de 2 valores" in texto


# ---------------------------------------------------------------------------
# Momento relativo (doc 06 §3.11): estrategias cruzadas
# ---------------------------------------------------------------------------

def _universo_aleatorio(n=700, activos=6):
    return {(f"S{i}", "accion"): _serie_aleatoria(n=n, semilla=40 + i) for i in range(activos)}


@pytest.mark.parametrize("nombre", ["momento", "azar_momento"])
def test_el_rango_entre_activos_no_cambia_si_se_quita_el_futuro(nombre):
    from laboratorio.estrategias import anadir_rangos
    datos = _universo_aleatorio()
    e = ESTRATEGIAS[nombre]()
    completo = anadir_rangos(datos, e)
    for t in range(260, 699, 53):
        truncado = anadir_rangos({k: df.iloc[: t + 1] for k, df in datos.items()}, e)
        for k in datos:
            a, b = completo[k][e.columna].iloc[t], truncado[k][e.columna].iloc[t]
            assert (pd.isna(a) and pd.isna(b)) or a == b, (nombre, k, t)
            pa, pb = e.preparar(completo[k]), e.preparar(truncado[k])
            assert (e.entrada(pa, t) is None) == (e.entrada(pb, t) is None), (nombre, k, t)


def test_el_rango_es_por_clase_y_solo_compiten_los_que_tienen_historia():
    from laboratorio.estrategias import anadir_rangos
    datos = _universo_aleatorio(activos=4)
    datos[("C0", "cripto")] = _serie_aleatoria(n=700, semilla=99)
    e = ESTRATEGIAS["azar_momento"]()
    con = anadir_rangos(datos, e)
    # Los primeros 252 días no hay momento de 12 meses: nadie compite.
    assert all(con[k][e.columna].iloc[:252].isna().all() for k in con)
    fila = pd.Series({k: con[k][e.columna].iloc[500] for k in con if k[1] == "accion"})
    assert sorted(fila) == [1, 2, 3, 4]
    # La única cripto compite sola en su clase.
    assert con[("C0", "cripto")][e.columna].iloc[500] == 1


def test_el_momento_entra_en_las_primeras_y_rota_al_caer():
    e = ESTRATEGIAS["momento"](top=2, mantener=4)
    df = e.preparar(_serie_aleatoria(n=120))
    rebalanceos = np.flatnonzero(df["REBALANCEO"].to_numpy())
    assert len(rebalanceos) >= 3
    assert all(df.index[t].month != df.index[t - 1].month for t in rebalanceos)
    t1, t2 = rebalanceos[1], rebalanceos[2]
    df.loc[df.index[t1], e.columna] = 2          # entre las 2 primeras: entra
    df.loc[df.index[t1 + 1], e.columna] = 1      # no es día de rebalanceo: no entra
    assert e.entrada(df, t1) is not None and e.entrada(df, t1 + 1) is None
    ent = e.entrada(df, t1)
    assert ent.tp is None and ent.sl == pytest.approx(df["Close"].iloc[t1] - 5 * df["ATR_14"].iloc[t1])

    pos = Posicion(entrada=df["Close"].iloc[t1], sl=ent.sl, sl_inicial=ent.sl, tp=None,
                   fecha_senal=df.index[t1], fecha_entrada=df.index[t1 + 1],
                   indice_entrada=t1 + 1, mejor_cierre=df["Close"].iloc[t1])
    df.loc[df.index[t2], e.columna] = 4          # sigue entre las 4: mantiene
    assert e.actualizar(df, t2, pos) == (ent.sl, False)
    df.loc[df.index[t2], e.columna] = 5          # cae fuera: sale a la apertura siguiente
    assert e.actualizar(df, t2, pos) == (ent.sl, True)
    df.loc[df.index[t2 + 1], e.columna] = 9      # fuera de rebalanceo no se mira
    assert e.actualizar(df, t2 + 1, pos) == (ent.sl, False)


def test_el_momento_opera_el_universo_de_principio_a_fin():
    from laboratorio.estrategias import anadir_rangos
    datos = _universo_aleatorio()
    for nombre in ("momento", "azar_momento"):
        e = ESTRATEGIAS[nombre](top=2, mantener=3)
        ops = [o for (s, c), df in anadir_rangos(datos, e).items()
               for o in simular(df, e, lambda p: p * 0.001, s, c)]
        assert ops, nombre
        assert all(o.fecha_entrada > o.fecha_senal for o in ops)
        assert {o.motivo for o in ops} <= {"regla", "sl", "hueco", "fin"}
        # En cada rebalanceo, como mucho `top` entradas nuevas.
        por_fecha = pd.Series([o.fecha_senal for o in ops]).value_counts()
        assert por_fecha.max() <= 2


def test_el_informe_de_robustez_del_momento_cubre_su_rejilla():
    from laboratorio import robustez
    datos = _universo_aleatorio(n=600, activos=5)
    indice = datos[("S0", "accion")].index
    corte = indice[0] + (indice[-1] - indice[0]) * 0.7
    texto = robustez.informe("momento", "accion", datos, {}, corte)
    assert "18 variantes" in texto and "## 5." in texto
