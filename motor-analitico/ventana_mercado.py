"""
¿Está abierta la bolsa estadounidense?

Vive en su propio fichero por la misma razón que `riesgo/rotacion.py` se
separó de `servicio_interno.py` en la Fase 1, y con las mismas palabras
de su docstring: "esta es lógica de negocio pura (fácil de testear sin
levantar el servicio web)". Dejar esta función dentro de `etl.py`
obligaría a importar FastAPI, yfinance y los conectores solo para
comprobar si el sábado cuenta como día de mercado.
"""

from __future__ import annotations

from datetime import datetime, time, timezone
from zoneinfo import ZoneInfo

BOLSA_NY = ZoneInfo("America/New_York")
APERTURA_NY = time(9, 30)
# Media hora más allá del cierre (16:00) para que la última pasada del día
# capture la vela ya cerrada. Sin ese margen, el cierre del día solo
# entraría en la tabla a la mañana siguiente.
CIERRE_NY = time(16, 30)


def mercado_abierto(ahora: datetime | None = None) -> bool:
    """¿Se puede escanear acciones ahora mismo?

    La decisión se toma en hora de Nueva York y NO en el cron del
    workflow. Los cron de GitHub Actions se evalúan en UTC y no entienden
    el horario de verano: una ventana fija en UTC acierta seis meses al
    año y se desplaza una hora los otros seis, dejando el escáner sin
    actualizar en la apertura o perdiéndose el cierre.

    La estrategia es la contraria: el workflow programa una ventana ANCHA
    en UTC y esta función descarta las pasadas que caen fuera de sesión.
    Una pasada descartada termina en segundos y apenas consume cuota.

    Los festivos NO se contemplan a propósito: en un día festivo yfinance
    devuelve la última sesión válida, así que la pasada reescribe la misma
    vela por `UPSERT`. Es idempotente y no cuesta nada, y mantener un
    calendario de festivos de NYSE sería más código que el que ahorra.
    """
    ahora = ahora or datetime.now(timezone.utc)

    # Un datetime sin zona se interpreta como UTC: es lo que devuelve
    # `datetime.utcnow()`, que es lo que usa el resto del motor.
    if ahora.tzinfo is None:
        ahora = ahora.replace(tzinfo=timezone.utc)

    local = ahora.astimezone(BOLSA_NY)

    # 5 = sábado, 6 = domingo.
    if local.weekday() >= 5:
        return False

    return APERTURA_NY <= local.time() <= CIERRE_NY
