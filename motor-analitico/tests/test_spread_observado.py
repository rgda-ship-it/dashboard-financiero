"""
Medición del spread real de las acciones (0035).

El ETL guarda, en sesión regular, el precio de compra y de venta que da
Yahoo. Todo es de mejor esfuerzo: nada de esto puede tumbar una pasada ni
marcar un activo como fallido. Sin red: el conector y el cliente son dobles.
"""

import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import etl  # noqa: E402
import servicio_interno  # noqa: E402
from conectores import yahoo_finance  # noqa: E402
from escritor_supabase import ErrorEscritura  # noqa: E402
from ventana_mercado import en_sesion_regular  # noqa: E402

# Miércoles 14 de octubre de 2026 a las 11:00 de Nueva York (15:00 UTC).
EN_SESION = datetime(2026, 10, 14, 15, 0, tzinfo=timezone.utc)
SABADO = datetime(2026, 10, 10, 15, 0, tzinfo=timezone.utc)
POSTMERCADO = datetime(2026, 10, 14, 20, 10, tzinfo=timezone.utc)  # 16:10 NY
APERTURA = datetime(2026, 10, 14, 13, 31, tzinfo=timezone.utc)     # 9:31 NY

ACTIVO = {"id": 7, "simbolo": "AGNC", "clase": "accion"}


class ClienteFalso:
    def __init__(self, falla=False):
        self.filas = []
        self.falla = falla

    def insertar(self, tabla, filas):
        if self.falla:
            raise ErrorEscritura("INSERT spreads_observados: 404 relation does not exist")
        self.filas.append((tabla, filas))


class ConectorFalso:
    def __init__(self, cotizacion):
        self.cotizacion = cotizacion
        self.llamadas = 0

    def obtener_cotizacion(self, ticker):
        self.llamadas += 1
        return self.cotizacion


def _con_conector(cotizacion, fn):
    original = servicio_interno.conector_acciones
    conector = ConectorFalso(cotizacion)
    servicio_interno.conector_acciones = conector
    try:
        return fn(), conector
    finally:
        servicio_interno.conector_acciones = original


def test_la_franja_de_medida_es_la_sesion_regular_sin_subastas():
    assert en_sesion_regular(EN_SESION)
    assert not en_sesion_regular(SABADO)
    assert not en_sesion_regular(POSTMERCADO)
    assert not en_sesion_regular(APERTURA)


def test_en_sesion_guarda_compra_y_venta():
    cliente = ClienteFalso()
    guardado, _ = _con_conector({"bid": 8.67, "ask": 8.68},
                                lambda: etl.registrar_spread(cliente, ACTIVO, EN_SESION))
    assert guardado
    assert cliente.filas == [("spreads_observados", [{"activo_id": 7, "bid": 8.67, "ask": 8.68}])]


def test_fuera_de_sesion_ni_siquiera_pregunta_a_yahoo():
    cliente = ClienteFalso()
    guardado, conector = _con_conector({"bid": 8.67, "ask": 8.68},
                                       lambda: etl.registrar_spread(cliente, ACTIVO, SABADO))
    assert not guardado and conector.llamadas == 0 and cliente.filas == []


def test_sin_cotizacion_no_guarda():
    cliente = ClienteFalso()
    guardado, _ = _con_conector(None, lambda: etl.registrar_spread(cliente, ACTIVO, EN_SESION))
    assert not guardado and cliente.filas == []


def test_un_spread_absurdo_no_se_guarda():
    cliente = ClienteFalso()
    guardado, _ = _con_conector({"bid": 8.0, "ask": 9.0},
                                lambda: etl.registrar_spread(cliente, ACTIVO, EN_SESION))
    assert not guardado and cliente.filas == []


def test_si_la_tabla_aun_no_existe_la_pasada_sigue():
    # El código llega a master antes de que se aplique la migración.
    cliente = ClienteFalso(falla=True)
    guardado, _ = _con_conector({"bid": 8.67, "ask": 8.68},
                                lambda: etl.registrar_spread(cliente, ACTIVO, EN_SESION))
    assert not guardado


def test_el_conector_descarta_cotizaciones_sin_sentido(monkeypatch):
    casos = [
        ({"bid": 8.67, "ask": 8.68}, {"bid": 8.67, "ask": 8.68}),
        ({"bid": 0, "ask": 8.68}, None),
        ({"bid": 8.69, "ask": 8.68}, None),
        ({"bid": None, "ask": 8.68}, None),
        ({}, None),
    ]
    for info, esperado in casos:
        class TickerFalso:
            def __init__(self, _ticker, info=info):
                self.info = info
        monkeypatch.setattr(yahoo_finance.yf, "Ticker", TickerFalso)
        assert yahoo_finance.ConectorAccionesYahoo().obtener_cotizacion("AGNC") == esperado


def test_si_yahoo_falla_el_conector_devuelve_none(monkeypatch):
    class TickerQueFalla:
        def __init__(self, _ticker):
            pass

        @property
        def info(self):
            raise RuntimeError("Too Many Requests")

    monkeypatch.setattr(yahoo_finance.yf, "Ticker", TickerQueFalla)
    assert yahoo_finance.ConectorAccionesYahoo().obtener_cotizacion("AGNC") is None
