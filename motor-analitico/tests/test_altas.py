"""
altas.py con un cliente falso: qué pide a la BD y cómo resuelve cada
solicitud. Sin red.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import altas  # noqa: E402
from catalogo_cripto import filas_catalogo  # noqa: E402


class ClienteFalso:
    def __init__(self, solicitudes):
        self.solicitudes = solicitudes
        self.llamadas = []

    def rpc(self, funcion, argumentos=None):
        self.llamadas.append((funcion, argumentos))
        if funcion == "fn_tomar_solicitudes":
            return self.solicitudes
        return None


def test_un_simbolo_pedido_por_dos_se_valida_una_vez():
    cliente = ClienteFalso([
        {"id": 1, "simbolo": "NVDA", "usuario_id": "a"},
        {"id": 2, "simbolo": "NVDA", "usuario_id": "b"},
    ])
    validados = []

    def validar(s):
        validados.append(s)
        return True, None

    altas.procesar_solicitudes(cliente, validar)
    assert validados == ["NVDA"]
    resueltas = [a for f, a in cliente.llamadas if f == "fn_resolver_alta"]
    assert resueltas == [{"p_simbolo": "NVDA", "p_ok": True, "p_mensaje": None}]


def test_simbolo_desconocido_se_rechaza_con_motivo():
    cliente = ClienteFalso([{"id": 1, "simbolo": "ZZZZ", "usuario_id": "a"}])
    altas.procesar_solicitudes(cliente, lambda s: (False, "Yahoo Finance no reconoce «ZZZZ»."))
    (_, args), = [x for x in cliente.llamadas if x[0] == "fn_resolver_alta"]
    assert args["p_ok"] is False and "ZZZZ" in args["p_mensaje"]


def test_fallo_del_proveedor_no_rompe_las_demas():
    cliente = ClienteFalso([
        {"id": 1, "simbolo": "AAA", "usuario_id": "a"},
        {"id": 2, "simbolo": "BBB", "usuario_id": "a"},
    ])

    def validar(s):
        if s == "AAA":
            raise ConnectionError("timeout")
        return True, None

    altas.procesar_solicitudes(cliente, validar)
    args = {a["p_simbolo"]: a for f, a in cliente.llamadas if f == "fn_resolver_alta"}
    assert args["AAA"]["p_ok"] is False and "temporal" in args["AAA"]["p_mensaje"]
    assert args["BBB"]["p_ok"] is True


def test_sin_solicitudes_no_se_valida_nada():
    cliente = ClienteFalso([])
    altas.procesar_solicitudes(cliente, lambda s: (_ for _ in ()).throw(AssertionError("no debía llamar")))
    assert [f for f, _ in cliente.llamadas] == ["fn_tomar_solicitudes"]


def test_catalogo_normaliza_y_descarta_incompletas():
    filas = filas_catalogo([
        {"id": "Bitcoin", "symbol": "BTC", "name": "Bitcoin"},
        {"id": "bitcoin", "symbol": "btc", "name": "Duplicado"},
        {"id": "", "symbol": "x", "name": "Sin id"},
        {"id": "sin-simbolo", "symbol": "", "name": "Nada"},
    ])
    assert filas == [{"id": "bitcoin", "simbolo": "btc", "nombre": "Bitcoin"}]
