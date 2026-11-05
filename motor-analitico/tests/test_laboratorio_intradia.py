"""
Modo de 1 hora del laboratorio (doc fase-3/10): el rebote tras una caída
brusca, su referencia al azar y las medidas por mes con velas horarias.
Sin red: series sintéticas.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from laboratorio import metricas  # noqa: E402
from laboratorio.intradia import (AzarHueco, AzarPrimeraHora, AzarRebote, HuecoResultados, ReboteCaida,  # noqa: E402
                                  AzarDeriva, DerivaResultados, RupturaPrimeraHora, con_dia_resultados, informe)
from laboratorio.motor import simular  # noqa: E402

SIN_SPREAD = lambda precio: 0.0  # noqa: E731


def _horas(cierres, rango=0.5):
    idx = pd.date_range("2025-01-01", periods=len(cierres), freq="h")
    c = np.asarray(cierres, dtype=float)
    o = np.concatenate([[c[0]], c[:-1]])
    return pd.DataFrame({"Open": o, "High": np.maximum(o, c) + rango, "Low": np.minimum(o, c) - rango,
                         "Close": c, "Volume": 1e6}, index=idx)


def _con_caida(n=200, en=120, caida=12.0):
    """100 plano con una caída de `caida` $ en tres horas a partir de `en`."""
    cierres = np.full(n, 100.0)
    for i, paso in enumerate((caida / 3, caida / 3, caida / 3)):
        cierres[en + i:] -= paso
    return _horas(cierres)


def test_la_caida_es_causal_y_dispara_al_cierre_de_la_hora():
    df = _con_caida()
    e = ReboteCaida(caida_atr=4.0, atr_n=24)
    p = e.preparar(df)
    señales = [t for t in range(len(p)) if e.entrada(p, t) is not None]
    assert señales and señales[0] >= 120
    # Truncar el histórico no cambia la columna (causal).
    corta = e.preparar(df.iloc[:125])
    assert np.allclose(corta["CAIDA_ATR"].dropna(), p["CAIDA_ATR"].iloc[:125].dropna())


def test_sale_por_tiempo_a_las_horas_fijadas():
    df = _con_caida()
    ops = simular(df, ReboteCaida(caida_atr=4.0, atr_n=24, stop_atr=50, objetivo_atr=50, horas=6), SIN_SPREAD)
    assert ops
    assert ops[0].motivo == "regla" and ops[0].dias == 6
    assert ops[0].fecha_entrada - ops[0].fecha_senal == pd.Timedelta(hours=1)


def test_el_objetivo_cierra_el_rebote():
    cierres = np.full(200, 100.0)
    cierres[120:] -= 12
    cierres[124:] += 8            # rebota con fuerza
    df = _horas(cierres)
    ops = simular(df, ReboteCaida(caida_atr=4.0, atr_n=24, stop_atr=2, objetivo_atr=1, horas=24), SIN_SPREAD)
    assert any(o.motivo == "tp" and o.r > 0 for o in ops)


def test_el_azar_usa_las_mismas_salidas_y_es_determinista():
    df = _horas(100 + np.cumsum(np.random.default_rng(1).normal(0, 0.3, 600)))
    a = simular(df, AzarRebote(probabilidad=0.05, semilla=3, atr_n=24, horas=6), SIN_SPREAD)
    b = simular(df, AzarRebote(probabilidad=0.05, semilla=3, atr_n=24, horas=6), SIN_SPREAD)
    c = simular(df, AzarRebote(probabilidad=0.05, semilla=4, atr_n=24, horas=6), SIN_SPREAD)
    assert a and [o.fecha_entrada for o in a] == [o.fecha_entrada for o in b]
    assert [o.fecha_entrada for o in a] != [o.fecha_entrada for o in c]
    assert all(o.dias <= 6 for o in a)


def test_el_mes_en_velas_de_1_hora():
    df = _horas(np.linspace(100, 110, 300))
    ops = simular(df, AzarRebote(probabilidad=0.05, semilla=0, atr_n=24, horas=6), SIN_SPREAD)
    diario, horario = metricas.medir(ops), metricas.medir(ops, barras_mes=720)
    assert horario.mes_pct > diario.mes_pct > 0


def test_el_informe_elige_en_diseno_y_compara_con_el_azar():
    rng = np.random.default_rng(5)
    datos = {}
    for i in range(3):
        cierres = 100 + np.cumsum(rng.normal(0, 0.4, 3000))
        for en in range(200, 3000, 60):           # caídas frecuentes para tener operaciones
            cierres[en:] -= 6
        datos[(f"x{i}", "cripto")] = _horas(cierres - cierres.min() + 50)
    texto = informe("rebote_caida", datos, semillas=3)
    assert "Rejilla en diseño" in texto and "Veredicto" in texto


def _sesiones(dias):
    """Sesiones de 7 velas (14:30–20:30 UTC). `dias` es una lista de listas
    de 7 tuplas (apertura, máximo, mínimo, cierre)."""
    filas, idx = [], []
    for d, velas in enumerate(dias):
        for h, vela in enumerate(velas):
            idx.append(pd.Timestamp("2025-03-03 14:30") + pd.Timedelta(days=d, hours=h))
            filas.append(vela)
    return pd.DataFrame(filas, columns=["Open", "High", "Low", "Close"], index=pd.DatetimeIndex(idx)).assign(Volume=1e6)


PLANA = [(100, 100.5, 99.5, 100)] * 7


def test_la_ruptura_compra_tras_el_primer_cierre_sobre_el_maximo_y_sale_antes_del_cierre():
    dia = [(100, 101, 99, 100), (100, 100.8, 99.8, 100.5), (100.5, 101.6, 100.4, 101.5),
           (101.5, 102, 101, 101.8), (101.8, 102.5, 101.5, 102), (102, 102.4, 101.8, 102.2),
           (102.2, 102.6, 102, 102.4)]
    df = _sesiones([PLANA, dia, PLANA])
    ops = simular(df, RupturaPrimeraHora(stop="rango"), SIN_SPREAD)
    assert len(ops) == 1
    o = ops[0]
    assert o.fecha_senal.hour == 16 and o.fecha_entrada.hour == 17     # cierre de las 11:30, entra a las 12:30
    assert o.sl_inicial == 99 and o.precio_entrada == 101.5
    assert o.motivo == "regla" and o.fecha_salida.hour == 20             # sale en la apertura de las 15:30
    assert o.fecha_salida.normalize() == o.fecha_entrada.normalize()


def test_la_ruptura_no_entra_dos_veces_ni_si_ya_estaba_rota_ni_en_sesiones_cortas():
    dia = [(100, 101, 99, 100), (100, 102, 100, 101.5), (101.5, 101.6, 100.2, 100.5),
           (100.5, 101.8, 100.4, 101.6), (101.6, 101.7, 101.4, 101.5), (101.5, 101.6, 101.4, 101.5),
           (101.5, 101.6, 101.4, 101.5)]
    ops = simular(_sesiones([PLANA, dia]), RupturaPrimeraHora(stop="mitad", objetivo_r=1), SIN_SPREAD)
    assert len(ops) == 1 and ops[0].sl_inicial == 100        # la mitad del rango 99–101
    corta = _sesiones([PLANA, dia]).iloc[:-2]                 # la segunda sesión, de 5 velas
    assert simular(corta, RupturaPrimeraHora(), SIN_SPREAD) == []


def test_el_azar_de_la_primera_hora_usa_el_mismo_tamano_de_stop_y_la_misma_salida():
    rng = np.random.default_rng(2)
    dias = []
    for _ in range(40):
        c = 100 + np.cumsum(rng.normal(0, 0.3, 7))
        dias.append([(x, x + 0.4, x - 0.4, x + 0.1) for x in c])
    df = _sesiones(dias)
    ops = simular(df, AzarPrimeraHora(probabilidad=0.5, semilla=1, stop="rango"), SIN_SPREAD)
    assert ops
    for o in ops:
        assert o.fecha_salida.normalize() == o.fecha_entrada.normalize()
        assert 15 <= o.fecha_entrada.hour <= 19
    assert len({o.fecha_entrada.normalize() for o in ops}) == len(ops)   # una al día


def _con_resultados(hueco, primera, resto, previas=15):
    """`previas` sesiones planas (ATR diario 1 $, cierre 100) y una de
    resultados que abre en 100 + `hueco` con la primera vela `primera`."""
    o = 100 + hueco
    dia = [primera] + [resto] * 6
    df = _sesiones([PLANA] * previas + [dia, [resto] * 7])
    return con_dia_resultados(df, pd.DatetimeIndex([df.index[previas * 7].normalize()])), o


def test_el_hueco_al_alza_compra_a_las_10_30_con_stop_en_el_minimo_y_sale_el_mismo_dia():
    df, _ = _con_resultados(2, (102, 103, 101.5, 102.8), (102.8, 103.2, 102.6, 103))
    ops = simular(df, HuecoResultados(hueco_atr=1.0), SIN_SPREAD)
    assert len(ops) == 1
    o = ops[0]
    assert o.lado == "largo" and o.sl_inicial == 101.5 and o.precio_entrada == 102.8
    assert o.fecha_entrada.hour == 15 and o.fecha_salida.hour == 20 and o.motivo == "regla"
    assert o.fecha_salida.normalize() == o.fecha_entrada.normalize()
    # Hueco más pequeño que el exigido, o sin resultados: no entra.
    assert simular(df, HuecoResultados(hueco_atr=3.0), SIN_SPREAD) == []
    assert simular(df.assign(DIA_RESULTADOS=False), HuecoResultados(hueco_atr=1.0), SIN_SPREAD) == []


def test_el_hueco_a_la_baja_vende_en_corto_y_puede_dejar_correr_varias_sesiones():
    df, _ = _con_resultados(-2, (98, 98.5, 97, 97.2), (97.2, 97.4, 96.8, 97))
    ops = simular(df, HuecoResultados(hueco_atr=1.0, sesiones=2), SIN_SPREAD)
    assert len(ops) == 1
    o = ops[0]
    assert o.lado == "corto" and o.sl_inicial == 98.5
    assert o.fecha_salida.normalize() - o.fecha_entrada.normalize() == pd.Timedelta(days=1)
    assert o.fecha_salida.hour == 20
    # La primera hora en contra del hueco anula la señal.
    contra, _ = _con_resultados(-2, (98, 99, 97.8, 98.9), (98.9, 99.1, 98.7, 99))
    assert simular(contra, HuecoResultados(hueco_atr=1.0), SIN_SPREAD) == []


def test_el_azar_del_hueco_entra_cualquier_dia_a_las_10_30_en_la_direccion_de_la_primera_hora():
    rng = np.random.default_rng(3)
    dias = []
    for _ in range(60):
        c = 100 + np.cumsum(rng.normal(0, 0.3, 7))
        dias.append([(x, x + 0.4, x - 0.4, x + rng.choice([-0.1, 0.1])) for x in c])
    df = _sesiones(dias)
    ops = simular(df, AzarHueco(probabilidad=0.5, semilla=1), SIN_SPREAD)
    assert ops and ops == simular(df, AzarHueco(probabilidad=0.5, semilla=1), SIN_SPREAD)
    for o in ops:
        assert o.fecha_entrada.hour == 15 and o.fecha_salida.normalize() == o.fecha_entrada.normalize()
        assert o.motivo != "regla" or o.fecha_salida.hour == 20
        primera = df.loc[o.fecha_senal]
        assert o.lado == ("largo" if primera["Close"] >= primera["Open"] else "corto")


def _diaria(velas):
    idx = pd.bdate_range("2024-01-01", periods=len(velas))
    return pd.DataFrame(velas, columns=["Open", "High", "Low", "Close"], index=idx).assign(Volume=1e6)


def test_la_deriva_entra_al_dia_siguiente_en_la_direccion_del_hueco_y_sale_a_las_n_sesiones():
    plana = [(100, 100.5, 99.5, 100)] * 20
    sube = plana + [(102, 104, 101.5, 103.5)] + [(103.5, 104, 103, 103.8)] * 12
    df = con_dia_resultados(_diaria(sube), pd.DatetimeIndex([_diaria(sube).index[20]]))
    ops = simular(df, DerivaResultados(hueco_atr=1.0, sesiones=5), SIN_SPREAD)
    assert len(ops) == 1
    o = ops[0]
    assert o.lado == "largo" and o.sl_inicial == 101.5 and o.precio_entrada == 103.5
    assert o.fecha_entrada == df.index[21] and o.fecha_salida == df.index[26] and o.motivo == "regla"
    baja = plana + [(98, 98.5, 96, 96.5)] + [(96.5, 97, 96, 96.2)] * 12
    df = con_dia_resultados(_diaria(baja), pd.DatetimeIndex([_diaria(baja).index[20]]))
    ops = simular(df, DerivaResultados(hueco_atr=1.0, sesiones=5), SIN_SPREAD)
    assert len(ops) == 1 and ops[0].lado == "corto" and ops[0].sl_inicial == 98.5
    # Sin resultados, o con la sesión cerrando en contra del hueco, no entra.
    assert simular(df.assign(DIA_RESULTADOS=False), DerivaResultados(hueco_atr=1.0), SIN_SPREAD) == []
    contra = plana + [(98, 99.5, 97.5, 99.2)] + [(99, 99.5, 98.5, 99)] * 12
    df = con_dia_resultados(_diaria(contra), pd.DatetimeIndex([_diaria(contra).index[20]]))
    assert simular(df, DerivaResultados(hueco_atr=1.0), SIN_SPREAD) == []


def test_el_azar_de_la_deriva_sigue_a_la_sesion_con_la_misma_salida():
    rng = np.random.default_rng(4)
    c = 100 + np.cumsum(rng.normal(0, 1, 300))
    o = np.concatenate([[c[0]], c[:-1]]) + rng.normal(0, 0.3, 300)
    df = _diaria(np.column_stack([o, np.maximum(o, c) + 0.5, np.minimum(o, c) - 0.5, c]))
    ops = simular(df, AzarDeriva(probabilidad=0.2, semilla=2, sesiones=5), SIN_SPREAD)
    assert ops
    for op in ops:
        senal = df.loc[op.fecha_senal]
        assert op.lado == ("largo" if senal["Close"] >= senal["Open"] else "corto")
        assert op.sl_inicial == (senal["Low"] if op.lado == "largo" else senal["High"])
        assert df.index.get_loc(op.fecha_salida) - df.index.get_loc(op.fecha_entrada) <= 5


def test_la_deriva_en_largo_ignora_los_huecos_a_la_baja_y_su_azar_solo_compra_dias_al_alza():
    from laboratorio.intradia import AzarDerivaLargos, DerivaLargos
    plana = [(100, 100.5, 99.5, 100)] * 20
    for velas, esperadas in ((plana + [(103, 105, 102.5, 104.5)] + [(104.5, 105, 104, 104.8)] * 25, 1),
                             (plana + [(97, 97.5, 95, 95.5)] + [(95.5, 96, 95, 95.2)] * 25, 0)):
        df = con_dia_resultados(_diaria(velas), pd.DatetimeIndex([_diaria(velas).index[20]]))
        ops = simular(df, DerivaLargos(), SIN_SPREAD)
        assert len(ops) == esperadas and all(o.lado == "largo" for o in ops)
    rng = np.random.default_rng(5)
    c = 100 + np.cumsum(rng.normal(0, 1, 300))
    o = np.concatenate([[c[0]], c[:-1]]) + rng.normal(0, 0.3, 300)
    df = _diaria(np.column_stack([o, np.maximum(o, c) + 0.5, np.minimum(o, c) - 0.5, c]))
    ops = simular(df, AzarDerivaLargos(probabilidad=0.3, semilla=1), SIN_SPREAD)
    assert ops and all(op.lado == "largo" for op in ops)
    assert all(df.loc[op.fecha_senal, "Close"] >= df.loc[op.fecha_senal, "Open"] for op in ops)


def test_el_rebote_con_fondo_bajista_compra_al_girar_el_macd_y_su_azar_solo_en_caidas():
    from laboratorio.intradia import AzarFondoBajista, ReboteFondoBajista
    # 250 sesiones de caída y 60 de rebote: medias bajistas y un giro del MACD.
    c = np.concatenate([np.linspace(150, 100, 250), np.linspace(100, 112, 60)])
    c = c + np.sin(np.arange(len(c)) / 3)
    o = np.concatenate([[c[0]], c[:-1]])
    df = _diaria(np.column_stack([o, np.maximum(o, c) + 0.5, np.minimum(o, c) - 0.5, c]))
    pre = ReboteFondoBajista.precalcular(df)
    ops = simular(df, ReboteFondoBajista(stop_atr=3.0, sesiones=10), SIN_SPREAD)
    assert ops
    for op in ops:
        fila = pre.loc[op.fecha_senal]
        assert fila["FONDO_BAJISTA"] and fila["GIRO_MACD"]
        assert abs(op.sl_inicial - (fila["Close"] - 3.0 * fila["ATR_D"])) < 1e-9
        assert df.index.get_loc(op.fecha_salida) - df.index.get_loc(op.fecha_entrada) <= 10
    azar = simular(df, AzarFondoBajista(probabilidad=0.2, semilla=3, sesiones=10), SIN_SPREAD)
    assert azar and all(pre.loc[op.fecha_senal, "FONDO_BAJISTA"] for op in azar)


def test_la_caida_etf_compra_cualquier_dia_de_caida_y_su_azar_cualquier_dia():
    from laboratorio.intradia import AzarCualquierDia, CaidaEtf
    c = np.concatenate([np.linspace(150, 100, 250), np.linspace(100, 140, 150)])
    c = c + np.sin(np.arange(len(c)) / 3)
    o = np.concatenate([[c[0]], c[:-1]])
    df = _diaria(np.column_stack([o, np.maximum(o, c) + 0.5, np.minimum(o, c) - 0.5, c]))
    pre = CaidaEtf.precalcular(df)
    ops = simular(df, CaidaEtf(stop_atr=3.0, sesiones=10), SIN_SPREAD)
    assert ops and all(pre.loc[op.fecha_senal, "FONDO_BAJISTA"] for op in ops)
    assert all(df.index.get_loc(op.fecha_salida) - df.index.get_loc(op.fecha_entrada) <= 10 for op in ops)
    azar = simular(df, AzarCualquierDia(probabilidad=0.3, semilla=2, sesiones=10), SIN_SPREAD)
    assert any(pre.loc[op.fecha_senal, "FONDO_BAJISTA"] for op in azar)
    assert any(not pre.loc[op.fecha_senal, "FONDO_BAJISTA"] for op in azar)


def test_la_hora_cripto_compra_solo_en_su_hora_y_sale_a_las_n_horas():
    from laboratorio.intradia import AzarHoraCripto, HoraCripto
    n = 24 * 12
    rng = np.random.default_rng(7)
    c = 100 + np.cumsum(rng.normal(0, 0.3, n))
    o = np.concatenate([[c[0]], c[:-1]])
    idx = pd.date_range("2026-01-01", periods=n, freq="h")
    df = pd.DataFrame({"Open": o, "High": np.maximum(o, c) + 0.2, "Low": np.minimum(o, c) - 0.2,
                       "Close": c, "Volume": 1.0}, index=idx)
    ops = simular(df, HoraCripto(hora=13, horas=4), SIN_SPREAD)
    assert ops and all(op.fecha_entrada.hour == 13 for op in ops)
    assert all(df.index.get_loc(op.fecha_salida) - df.index.get_loc(op.fecha_entrada) <= 4 for op in ops)
    azar = simular(df, AzarHoraCripto(probabilidad=0.2, semilla=1, horas=4), SIN_SPREAD)
    assert len({op.fecha_entrada.hour for op in azar}) > 5
