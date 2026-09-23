"""respaldo.py con un cliente falso: paginación, ficheros y retención."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import respaldo  # noqa: E402


class ClienteFalso:
    def __init__(self, datos):
        self.datos = datos
        self.rpcs = []
        self.consultas = []

    def seleccionar(self, tabla, params=None):
        params = params or {}
        self.consultas.append(params)
        filas = self.datos.get(tabla, [])
        desde = int(params.get("offset", 0))
        hasta = desde + int(params.get("limit", 1000))
        return filas[desde:hasta]

    def rpc(self, funcion, argumentos=None):
        self.rpcs.append(funcion)
        return {"borradas": 0, "comprimidas": 0}


def test_descargar_pagina_hasta_el_final_ordenando_por_la_clave():
    cliente = ClienteFalso({"activos": [{"id": i} for i in range(2500)]})
    respaldo.PAGINA = 1000
    assert len(respaldo.descargar(cliente, "activos", "id")) == 2500
    # Sin un orden estable, limit/offset puede repetir o saltarse filas.
    # PostgREST tampoco admite `order=1` (lo lee como columna "1": 42703).
    assert all(p.get("order") == "id" for p in cliente.consultas)


def test_las_tablas_regenerables_no_se_respaldan():
    for tabla in respaldo.REGENERABLES:
        assert tabla not in respaldo.TABLAS


def test_main_escribe_un_json_por_tabla_y_poda(tmp_path, monkeypatch):
    cliente = ClienteFalso({"perfiles": [{"id": "a", "email": "a@b.c"}], "activos": [{"id": 1}]})
    monkeypatch.setattr(respaldo.ClienteSupabase, "desde_entorno", classmethod(lambda cls: cliente))
    monkeypatch.chdir(tmp_path)
    assert respaldo.main() == 0

    assert cliente.rpcs == ["fn_retencion_senales"]
    perfiles = json.loads((tmp_path / "respaldo" / "perfiles.json").read_text("utf-8"))
    assert perfiles == [{"id": "a", "email": "a@b.c"}]
    manifiesto = json.loads((tmp_path / "respaldo" / "_manifiesto.json").read_text("utf-8"))
    assert manifiesto["no_respaldadas_por_regenerables"] == respaldo.REGENERABLES
    assert (tmp_path / "respaldo" / "senales.json").exists() is False


def test_una_tabla_que_falla_pone_el_respaldo_en_rojo(tmp_path, monkeypatch):
    """Un respaldo incompleto en verde es peor que no tenerlo."""

    class Parcial(ClienteFalso):
        def seleccionar(self, tabla, params=None):
            if tabla == "carteras":
                raise respaldo.ErrorEscritura("SELECT carteras: 400 column does not exist")
            return super().seleccionar(tabla, params)

    cliente = Parcial({"activos": [{"id": 1}], "perfiles": [{"id": "a"}]})
    monkeypatch.setattr(respaldo.ClienteSupabase, "desde_entorno", classmethod(lambda cls: cliente))
    monkeypatch.chdir(tmp_path)
    assert respaldo.main() == 1
    assert (tmp_path / "respaldo" / "perfiles.json").exists()


def test_un_proyecto_pausado_pone_el_job_en_rojo(monkeypatch):
    class Caido(ClienteFalso):
        def seleccionar(self, tabla, params=None):
            raise respaldo.ErrorEscritura("SELECT activos: 503")

    monkeypatch.setattr(
        respaldo.ClienteSupabase, "desde_entorno", classmethod(lambda cls: Caido({}))
    )
    assert respaldo.main() == 1
