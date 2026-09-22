"""
Cableado entre etl.py y seleccion_universo.py, con un cliente falso.

`test_seleccion_universo.py` prueba las reglas; este prueba que etl.py
las usa bien: qué pide a la base de datos, que un backfill se salta las
reglas, y que la tabla `ordenes` inexistente (hasta el Sprint 5) no
rompe la pasada. Sin red: el cliente es un doble en memoria.

Importa etl.py de verdad, así que también detecta un import roto — el
tipo de fallo que en la Fase 1 hacía que pytest recolectara menos casos
sin ponerse en rojo.
"""

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import etl  # noqa: E402
from escritor_supabase import ErrorEscritura  # noqa: E402

AHORA = datetime.now(timezone.utc)


class ClienteFalso:
    def __init__(self, activos, ordenes=None):
        self.activos = activos
        self.ordenes = ordenes  # None = la tabla no existe (antes del Sprint 5)
        self.consultas = []

    def seleccionar(self, tabla, params=None):
        self.consultas.append((tabla, dict(params or {})))
        if tabla == "ordenes":
            if self.ordenes is None:
                raise ErrorEscritura("SELECT ordenes: 404 relation does not exist")
            return self.ordenes
        filas = self.activos
        params = params or {}
        if "simbolo" in params:
            filas = [a for a in filas if a["simbolo"] == params["simbolo"].removeprefix("eq.")]
        if "clase" in params:
            filas = [a for a in filas if a["clase"] == params["clase"].removeprefix("eq.")]
        if "estado" in params:
            permitidos = params["estado"].removeprefix("in.(").rstrip(")").split(",")
            filas = [a for a in filas if a["estado"] in permitidos]
        return filas


def _a(i, simbolo, clase="cripto", estado="activo", hace_min=None, espera_min=None):
    return {
        "id": i, "simbolo": simbolo, "clase": clase, "estado": estado,
        "proveedor": "coingecko", "id_proveedor": simbolo, "intentos": 0,
        "ultimo_etl_en": (AHORA - timedelta(minutes=hace_min)).isoformat() if hace_min is not None else None,
        "proximo_intento_en": (AHORA + timedelta(minutes=espera_min)).isoformat() if espera_min is not None else None,
    }


def test_la_consulta_incluye_suspendidos():
    cliente = ClienteFalso([_a(1, "bitcoin", estado="suspendido", hace_min=500)])
    sel = etl.seleccionar_activos(cliente, "cripto", None, 6)
    params = next(p for t, p in cliente.consultas if t == "activos")
    assert "suspendido" in params["estado"]
    assert [a["simbolo"] for a in sel.procesar] == ["bitcoin"]


def test_sin_tabla_ordenes_la_pasada_no_se_rompe():
    """Hasta el Sprint 5 no existe `ordenes`. El 404 de PostgREST significa
    'todavía no hay simulador', no 'el ETL ha fallado'."""
    cliente = ClienteFalso([_a(1, "bitcoin", hace_min=90)], ordenes=None)
    sel = etl.seleccionar_activos(cliente, "cripto", None, 6)
    assert [a["simbolo"] for a in sel.procesar] == ["bitcoin"]


def test_con_posicion_abierta_se_prioriza():
    cliente = ClienteFalso(
        [_a(1, "bitcoin", hace_min=500), _a(2, "solana", hace_min=1)],
        ordenes=[{"activo_id": 2}],
    )
    sel = etl.seleccionar_activos(cliente, "cripto", None, 1)
    assert [a["simbolo"] for a in sel.procesar] == ["solana"]


def test_backfill_se_salta_frescura_y_backoff():
    """Alguien acaba de pedir el activo: lo quiere ahora."""
    cliente = ClienteFalso([_a(1, "NVDA", clase="accion", hace_min=1, espera_min=60)])
    sel = etl.seleccionar_activos(cliente, None, "NVDA", None)
    assert [a["simbolo"] for a in sel.procesar] == ["NVDA"]


def test_forzar_ignora_frescura():
    cliente = ClienteFalso([_a(1, "IBM", clase="accion", hace_min=2)])
    assert etl.seleccionar_activos(cliente, "accion", None, None).procesar == []
    assert len(etl.seleccionar_activos(cliente, "accion", None, None, ignorar_frescura=True).procesar) == 1


if __name__ == "__main__":
    tests = [v for k, v in dict(globals()).items() if k.startswith("test_")]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
