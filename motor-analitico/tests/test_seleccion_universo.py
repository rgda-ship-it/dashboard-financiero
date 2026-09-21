import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from seleccion_universo import seleccionar

AHORA = datetime(2026, 9, 22, 15, 0, tzinfo=timezone.utc)


def _hace(minutos):
    return (AHORA - timedelta(minutes=minutos)).isoformat()


def _dentro_de(minutos):
    return (AHORA + timedelta(minutes=minutos)).isoformat()


def _activo(i, simbolo, clase="cripto", estado="activo", ultimo=None, espera=None):
    return {"id": i, "simbolo": simbolo, "clase": clase, "estado": estado,
            "ultimo_etl_en": ultimo, "proximo_intento_en": espera}


def _simbolos(filas):
    return [f["simbolo"] for f in filas]


def test_invalido_nunca_entra():
    r = seleccionar([_activo(1, "zzzz", estado="invalido")], AHORA)
    assert r.procesar == [] and r.en_espera == [] and r.frescos == []


def test_suspendido_se_reintenta_cuando_vence_su_espera():
    """EL FALLO DEL SPRINT 1: la consulta solo pedía 'activo' y
    'pendiente_backfill', así que un activo suspendido no volvía nunca."""
    r = seleccionar([_activo(1, "bitcoin", estado="suspendido", ultimo=_hace(400), espera=_hace(1))], AHORA)
    assert _simbolos(r.procesar) == ["bitcoin"]


def test_suspendido_espera_mientras_no_vence():
    r = seleccionar([_activo(1, "bitcoin", estado="suspendido", espera=_dentro_de(60))], AHORA)
    assert r.procesar == [] and _simbolos(r.en_espera) == ["bitcoin"]


def test_segunda_pasada_seguida_no_gasta_cuota():
    """Criterio de H-09 reformulado: dos ejecuciones seguidas, la segunda
    no llama al proveedor, porque todo se procesó hace un momento."""
    universo = [_activo(1, "bitcoin", ultimo=_hace(2)), _activo(2, "IBM", clase="accion", ultimo=_hace(2))]
    r = seleccionar(universo, AHORA)
    assert r.procesar == []
    assert len(r.frescos) == 2


def test_la_pasada_programada_siguiente_si_refresca():
    """Y a la vez el precio no se congela: una pasada una cadencia después
    vuelve a consultar. La regla original ('si la vela de hoy existe, no
    se llama') habría dejado el precio fijo todo el día."""
    r = seleccionar([_activo(1, "bitcoin", ultimo=_hace(60)), _activo(2, "IBM", clase="accion", ultimo=_hace(30))], AHORA)
    assert sorted(_simbolos(r.procesar)) == ["IBM", "bitcoin"]


def test_un_cron_retrasado_no_hace_saltar_al_siguiente():
    """GitHub retrasa a veces los cron 10-15 min. Si la pasada de las 14:00
    corrió a las 14:15, la de las 15:00 llega 45 min después y NO puede
    caer en la ventana de frescura de cripto."""
    r = seleccionar([_activo(1, "bitcoin", ultimo=_hace(45))], AHORA)
    assert _simbolos(r.procesar) == ["bitcoin"]


def test_forzar_ignora_la_frescura_pero_no_el_backoff():
    universo = [_activo(1, "bitcoin", ultimo=_hace(2)), _activo(2, "solana", espera=_dentro_de(30))]
    r = seleccionar(universo, AHORA, ignorar_frescura=True)
    assert _simbolos(r.procesar) == ["bitcoin"]
    assert _simbolos(r.en_espera) == ["solana"]


def test_pendiente_de_backfill_nunca_es_fresco():
    r = seleccionar([_activo(1, "NVDA", clase="accion", estado="pendiente_backfill", ultimo=_hace(1))], AHORA)
    assert _simbolos(r.procesar) == ["NVDA"]


def test_posicion_abierta_primero_ignorando_frescura_y_tope():
    """Un TP o un SL vigilándose no puede depender de un precio de hace
    horas: el activo con posición entra siempre, aunque esté fresco y
    aunque el tope ya esté lleno."""
    universo = [_activo(i, f"c{i}", ultimo=_hace(300 - i)) for i in range(1, 8)]
    universo.append(_activo(99, "vigilada", ultimo=_hace(1)))
    r = seleccionar(universo, AHORA, ids_con_posicion={99}, tope=1)
    assert _simbolos(r.procesar) == ["vigilada"]
    assert len(r.fuera_de_tope) == 7


def test_rotacion_del_mas_antiguo_al_mas_reciente_y_nulos_primero():
    universo = [
        _activo(1, "reciente", ultimo=_hace(40)),
        _activo(2, "nunca", ultimo=None),
        _activo(3, "vieja", ultimo=_hace(500)),
        _activo(4, "media", ultimo=_hace(100)),
    ]
    r = seleccionar(universo, AHORA, tope=3)
    assert _simbolos(r.procesar) == ["nunca", "vieja", "media"]
    assert _simbolos(r.fuera_de_tope) == ["reciente"]


def test_veinte_criptos_una_pasada_procesa_como_mucho_seis():
    """Criterio de H-10 con el universo máximo (D7: 20 criptos globales),
    sin necesidad de tener 20 criptos reales en el catálogo."""
    universo = [_activo(i, f"cripto{i:02d}", ultimo=_hace(60 + i)) for i in range(20)]
    r = seleccionar(universo, AHORA, tope=6)
    assert len(r.procesar) == 6
    assert len(r.fuera_de_tope) == 14


def test_el_orden_de_entrada_no_influye():
    universo = [_activo(i, s, ultimo=None) for i, s in enumerate(["b", "a", "c"])]
    r1 = seleccionar(universo, AHORA)
    r2 = seleccionar(list(reversed(universo)), AHORA)
    assert _simbolos(r1.procesar) == _simbolos(r2.procesar) == ["a", "b", "c"]


if __name__ == "__main__":
    tests = [v for k, v in dict(globals()).items() if k.startswith("test_")]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
