import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ventana_mercado import mercado_abierto

# Todas las fechas son miércoles, para aislar el efecto de la hora del
# efecto del día de la semana.
MIERCOLES_VERANO = "2026-07-15"   # horario de verano en NY (EDT, UTC-4)
MIERCOLES_INVIERNO = "2026-01-14"  # horario estándar (EST, UTC-5)


def _utc(fecha: str, hora: str) -> datetime:
    return datetime.fromisoformat(f"{fecha}T{hora}:00+00:00")


def test_sabado_cerrado():
    # 2026-07-18 es sábado, a media sesión en hora de NY.
    assert mercado_abierto(_utc("2026-07-18", "17:00")) is False


def test_domingo_cerrado():
    assert mercado_abierto(_utc("2026-07-19", "17:00")) is False


def test_media_sesion_abierto():
    # 14:00 UTC = 10:00 NY en verano.
    assert mercado_abierto(_utc(MIERCOLES_VERANO, "14:00")) is True


def test_antes_de_la_apertura_cerrado():
    # 13:00 UTC = 09:00 NY en verano: media hora antes de abrir.
    assert mercado_abierto(_utc(MIERCOLES_VERANO, "13:00")) is False


def test_apertura_exacta_abierto():
    # 13:30 UTC = 09:30 NY en verano: el minuto de la campana.
    assert mercado_abierto(_utc(MIERCOLES_VERANO, "13:30")) is True


def test_margen_tras_el_cierre_sigue_abierto():
    """La ventana llega hasta las 16:30 NY, media hora más allá del cierre.

    Sin ese margen, la vela del día ya cerrada solo entraría en la tabla a
    la mañana siguiente: la última pasada de la sesión caería justo antes
    de las 16:00 y leería una vela todavía en curso.
    """
    # 20:15 UTC = 16:15 NY en verano.
    assert mercado_abierto(_utc(MIERCOLES_VERANO, "20:15")) is True


def test_bien_pasado_el_cierre_cerrado():
    # 21:00 UTC = 17:00 NY en verano.
    assert mercado_abierto(_utc(MIERCOLES_VERANO, "21:00")) is False


def test_el_horario_de_verano_cambia_la_respuesta_a_la_misma_hora_utc():
    """EL CASO QUE JUSTIFICA QUE ESTA FUNCIÓN EXISTA.

    Las 14:00 UTC son las 10:00 en Nueva York en verano (mercado abierto)
    y las 09:00 en invierno (mercado cerrado). Un cron de GitHub Actions
    solo entiende UTC, así que una ventana fija acertaría seis meses al
    año y se desplazaría una hora los otros seis.

    Si este test se pusiera en rojo, significaría que alguien ha sustituido
    la conversión de zona por una comparación en UTC — y el efecto sería
    invisible hasta el siguiente cambio de hora.
    """
    assert mercado_abierto(_utc(MIERCOLES_VERANO, "14:00")) is True
    assert mercado_abierto(_utc(MIERCOLES_INVIERNO, "14:00")) is False
    # Y la simétrica: a las 20:30 UTC el invierno SÍ está en sesión
    # (15:30 NY) y el verano ya no (16:30 es el límite, 21:00 no).
    assert mercado_abierto(_utc(MIERCOLES_INVIERNO, "20:30")) is True


def test_datetime_sin_zona_se_interpreta_como_utc():
    """`datetime.utcnow()` devuelve un naive, y es lo que usa el resto del
    motor (`obtenido_en` en los dos conectores). Tratarlo como hora local
    del runner daría un resultado distinto en cada máquina."""
    naive = datetime(2026, 7, 15, 14, 0)
    consciente = datetime(2026, 7, 15, 14, 0, tzinfo=timezone.utc)
    assert mercado_abierto(naive) == mercado_abierto(consciente) is True


if __name__ == "__main__":
    tests = [
        test_sabado_cerrado,
        test_domingo_cerrado,
        test_media_sesion_abierto,
        test_antes_de_la_apertura_cerrado,
        test_apertura_exacta_abierto,
        test_margen_tras_el_cierre_sigue_abierto,
        test_bien_pasado_el_cierre_cerrado,
        test_el_horario_de_verano_cambia_la_respuesta_a_la_misma_hora_utc,
        test_datetime_sin_zona_se_interpreta_como_utc,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
