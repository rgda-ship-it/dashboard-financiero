#!/usr/bin/env python3
"""
ETL del motor analítico: escanea el universo y escribe en PostgreSQL.

Este fichero es el punto de entrada que invocan los workflows de GitHub
Actions. Sustituye al servidor FastAPI como forma de ejecutar el motor,
pero NO sustituye a `servicio_interno.py`: lo importa y reutiliza su
`_escanear_ticker()` tal cual.

Esa reutilización es deliberada y es la razón de que la decisión D2 ("el
motor no se toca") se pueda cumplir de verdad. Todo el conocimiento
delicado —la siembra del ATR sobre las velas con rango real, el suelo de
1x antes del min() del tope duro, el sesgo solo-largo, el modo degradado
cuando falta volatilidad— sigue viviendo en un solo sitio y con sus 69
pruebas encima. Aquí solo se decide QUÉ tickers escanear, CUÁNDO parar y
DÓNDE guardar el resultado.

Uso:
    python etl.py --clase accion              # pasada de acciones
    python etl.py --clase cripto --max 6      # pasada de cripto, con techo
    python etl.py --simbolo NVDA              # backfill de un activo nuevo
    python etl.py --clase accion --forzar     # ignora el horario de mercado
"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from datetime import datetime, timedelta, timezone

# El import de servicio_interno tiene que ir después de resolver la raíz
# del proyecto, igual que hacen los tests.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import servicio_interno  # noqa: E402
from conectores.yahoo_finance import ErrorEsquemaInesperado  # noqa: E402
from escritor_supabase import (  # noqa: E402
    ClienteSupabase,
    ErrorEscritura,
    fila_indicadores,
    fila_senal,
    filas_precios,
)
from indicadores.tecnicos import calcular_indicadores  # noqa: E402
from ventana_mercado import mercado_abierto  # noqa: E402

# Tras 3 fallos seguidos, el activo pasa a 'suspendido' y deja de
# consumir cuota en cada pasada.
FALLOS_PARA_SUSPENDER = 3


# ─────────────────────────────────────────────────────────────────────────
# Una sola llamada al proveedor por ticker y pasada
# ─────────────────────────────────────────────────────────────────────────
def _memoizar_ohlcv():
    """Envuelve `servicio_interno._obtener_ohlcv` en una caché de pasada.

    POR QUÉ ES NECESARIO: el ETL necesita el DataFrame de velas DOS veces
    —una para escribir `precios_diarios` y otra dentro de
    `_escanear_ticker()`— y `_obtener_ohlcv` es lo que llama al proveedor.
    Sin esta caché, cada cripto costaría CUATRO peticiones a CoinGecko en
    vez de dos.

    Ese error exacto ya ocurrió en la Fase 1 y está documentado en el
    CHANGELOG: `_escanear_ticker` pedía OHLCV y fundamentales juntos y
    descartaba los segundos, lo que duplicaba las llamadas y disparaba el
    429 en el último ticker del universo. No se va a repetir por la puerta
    de atrás del ETL.

    Se envuelve el atributo del MÓDULO en vez de tocar su código, porque
    `_escanear_ticker` resuelve `_obtener_ohlcv` como global del módulo:
    la sustitución es transparente y no cambia ni una línea del motor.
    """
    original = servicio_interno._obtener_ohlcv
    cache: dict[str, object] = {}

    def envuelto(ticker: str):
        clave = ticker.lower()
        if clave not in cache:
            cache[clave] = original(ticker)
        return cache[clave]

    servicio_interno._obtener_ohlcv = envuelto
    return cache


def _registrar_cripto_del_catalogo(activos: list[dict]) -> None:
    """Enseña al motor las criptos que vienen de la base de datos.

    `servicio_interno.IDS_CRIPTO` es un diccionario hardcodeado con las
    tres monedas de la Fase 1, y `_es_cripto()` lo consulta para decidir
    qué conector usar. En la Fase 2 el universo lo gobierna la tabla
    `activos`, así que se amplía el diccionario antes de escanear.

    Es aditivo: no borra las tres entradas originales ni cambia la lógica
    de `_es_cripto`. Cuando se retire el diccionario del código (H-17),
    esta función desaparece con él.
    """
    for activo in activos:
        if activo["clase"] == "cripto":
            servicio_interno.IDS_CRIPTO[activo["simbolo"].lower()] = activo["id_proveedor"]


# ─────────────────────────────────────────────────────────────────────────
# Selección del universo de la pasada
# ─────────────────────────────────────────────────────────────────────────
def seleccionar_activos(
    cliente: ClienteSupabase, clase: str | None, simbolo: str | None, tope: int | None
) -> list[dict]:
    """Decide qué activos entran en esta pasada.

    Para cripto el orden NO es arbitrario: es la priorización que hace que
    el presupuesto de cuota cuadre (doc 02 §6.2). Cada moneda cuesta dos
    llamadas con 6 s de espaciado, así que recorrer 20 criptos en cada
    pasada serían ~4 minutos y 2.880 min/mes — por encima de los 2.000 del
    tier gratuito de GitHub Actions.

    Prioridad:
      1. Activos con una posición abierta. Un TP o un SL vigilándose no
         puede depender de un precio de hace tres horas.
      2. El resto, por antigüedad de `ultimo_etl_en` (los nulos primero).
    """
    campos = "id,simbolo,clase,proveedor,id_proveedor,estado,intentos"

    if simbolo:
        filas = cliente.seleccionar(
            "activos", {"select": campos, "simbolo": f"eq.{simbolo}"}
        )
        if not filas:
            raise SystemExit(f"El símbolo {simbolo} no está en el catálogo.")
        return filas

    params = {
        "select": campos,
        "estado": "in.(activo,pendiente_backfill)",
        "order": "ultimo_etl_en.asc.nullsfirst",
    }
    if clase:
        params["clase"] = f"eq.{clase}"

    candidatos = cliente.seleccionar("activos", params)

    # Backoff: no se reintenta antes de la hora marcada.
    ahora = datetime.now(timezone.utc)
    pendientes = cliente.seleccionar(
        "activos", {"select": "id,proximo_intento_en", "proximo_intento_en": "not.is.null"}
    )
    espera = {
        f["id"]: f["proximo_intento_en"]
        for f in pendientes
        if f.get("proximo_intento_en")
    }
    candidatos = [
        a
        for a in candidatos
        if a["id"] not in espera
        or datetime.fromisoformat(espera[a["id"]].replace("Z", "+00:00")) <= ahora
    ]

    if tope:
        con_posicion = _ids_con_posicion_abierta(cliente)
        prioritarios = [a for a in candidatos if a["id"] in con_posicion]
        resto = [a for a in candidatos if a["id"] not in con_posicion]
        candidatos = prioritarios + resto[: max(0, tope - len(prioritarios))]

    return candidatos


def _ids_con_posicion_abierta(cliente: ClienteSupabase) -> set[int]:
    """Activos con una orden abierta.

    `ordenes` no existe hasta el Sprint 5. Un 404 de PostgREST aquí no es
    un fallo: significa que todavía no hay simulador, así que no hay nada
    que priorizar. Se devuelve el conjunto vacío en vez de tumbar el ETL.
    """
    try:
        filas = cliente.seleccionar(
            "ordenes", {"select": "activo_id", "estado": "eq.abierta"}
        )
    except ErrorEscritura:
        return set()
    return {f["activo_id"] for f in filas}


# ─────────────────────────────────────────────────────────────────────────
# Pasada
# ─────────────────────────────────────────────────────────────────────────
def procesar_activo(
    cliente: ClienteSupabase, activo: dict, version_motor: str
) -> tuple[str, str]:
    """Escanea y escribe un activo. Devuelve (resultado, detalle).

    El fallo de un activo NUNCA aborta la pasada, por el mismo criterio
    con el que `/internal/scan` devolvía `{"ticker": t, "error": ...}` en
    vez de romper: un ticker roto no puede dejar sin datos a los otros
    veintitrés.
    """
    simbolo = activo["simbolo"]
    activo_id = activo["id"]

    try:
        datos = servicio_interno._obtener_ohlcv(simbolo)

        precios = filas_precios(activo_id, datos, getattr(datos, "fuente", "yfinance"))
        cliente.upsert("precios_diarios", precios, "activo_id,fecha")

        # `_escanear_ticker` reutiliza la caché de la pasada, así que aquí
        # no hay una segunda llamada al proveedor.
        escaneo = servicio_interno._escanear_ticker(simbolo)

        if "error" in escaneo:
            raise ValueError(escaneo["error"])

        indicadores = fila_indicadores(
            activo_id, calcular_indicadores(datos.datos), version_motor
        )
        if indicadores:
            cliente.upsert("indicadores_diarios", [indicadores], "activo_id,fecha")

        cliente.insertar("senales", [fila_senal(activo_id, escaneo, version_motor)])

        ahora = datetime.now(timezone.utc).isoformat()
        cambios = {
            "estado": "activo",
            "ultimo_precio": escaneo.get("precio_actual"),
            "ultimo_precio_en": ahora,
            "ultimo_etl_en": ahora,
            "intentos": 0,
            "proximo_intento_en": None,
            "ultimo_error": None,
        }
        if activo["estado"] == "pendiente_backfill":
            cambios["primer_backfill_en"] = ahora

        cliente.actualizar("activos", {"id": f"eq.{activo_id}"}, cambios)

        con_rango = sum(1 for f in precios if f["rango_real"])
        detalle = (
            f"{len(precios)} velas ({con_rango} con rango real), "
            f"{'operable' if escaneo.get('operable') else 'no operable'}"
        )
        if activo["estado"] == "pendiente_backfill":
            _evento(cliente, "activo_listo", f"[SYS] {simbolo} listo: {detalle}", {"simbolo": simbolo})
        return "ok", detalle

    except ErrorEscritura:
        # Un fallo de escritura no es culpa del activo: se propaga para que
        # el job termine en rojo. Marcar el activo como roto ocultaría un
        # problema de infraestructura detrás de un problema de datos.
        raise

    except (ErrorEsquemaInesperado, ValueError) as exc:
        return _marcar_fallo(cliente, activo, str(exc), definitivo=isinstance(exc, ValueError))

    except Exception as exc:  # fallo de red o del proveedor
        return _marcar_fallo(cliente, activo, f"fallo de datos: {exc}")


def _marcar_fallo(
    cliente: ClienteSupabase, activo: dict, mensaje: str, definitivo: bool = False
) -> tuple[str, str]:
    """Aplica backoff y, si procede, cambia el estado del activo.

    Dos salidas distintas a propósito:
      · 'invalido' es TERMINAL y se reserva para cuando el proveedor
        rechaza el símbolo ("Ticker no reconocido o sin datos"). No se
        reintenta nunca más: seguir pidiendo un ticker fantasma en cada
        pasada es cuota tirada.
      · 'suspendido' es reversible y se aplica tras 3 fallos seguidos de
        red o de esquema. Vuelve a 'activo' en cuanto una pasada funcione.
    """
    intentos = int(activo.get("intentos") or 0) + 1
    simbolo = activo["simbolo"]

    no_reconocido = definitivo and "no reconocido" in mensaje.lower()

    if no_reconocido:
        estado = "invalido"
        proximo = None
    elif intentos >= FALLOS_PARA_SUSPENDER:
        estado = "suspendido"
        proximo = (datetime.now(timezone.utc) + timedelta(hours=6)).isoformat()
    else:
        estado = activo["estado"]
        # Backoff exponencial: 2, 4, 8 minutos.
        proximo = (
            datetime.now(timezone.utc) + timedelta(minutes=2**intentos)
        ).isoformat()

    cliente.actualizar(
        "activos",
        {"id": f"eq.{activo['id']}"},
        {
            "estado": estado,
            "intentos": intentos,
            "proximo_intento_en": proximo,
            "ultimo_error": mensaje[:500],
        },
    )

    _evento(
        cliente,
        "proveedor",
        f"[SYS] {simbolo}: {mensaje[:200]}",
        {"simbolo": simbolo, "estado": estado, "intentos": intentos},
    )
    return estado if estado in ("invalido", "suspendido") else "fallo", mensaje[:200]


def _evento(cliente: ClienteSupabase, tipo: str, mensaje: str, datos: dict) -> None:
    """Deja constancia en `eventos_sistema`. Nunca hace fallar la pasada."""
    try:
        cliente.insertar(
            "eventos_sistema", [{"tipo": tipo, "mensaje": mensaje, "datos": datos}]
        )
    except ErrorEscritura:
        pass


# ─────────────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(description="ETL del motor analítico")
    parser.add_argument("--clase", choices=["accion", "cripto"], default=None)
    parser.add_argument("--simbolo", default=None, help="Backfill de un solo activo")
    parser.add_argument("--max", type=int, default=None, dest="tope")
    parser.add_argument(
        "--forzar",
        action="store_true",
        help="Ignora el horario de mercado (para un backfill manual)",
    )
    args = parser.parse_args()

    version_motor = os.environ.get("VERSION_MOTOR", "desconocida")
    resumen: list[str] = []

    def emitir_resumen():
        ruta = os.environ.get("GITHUB_STEP_SUMMARY")
        texto = "\n".join(resumen)
        print(texto)
        if ruta:
            with open(ruta, "a", encoding="utf-8") as f:
                f.write(texto + "\n")

    # Salida temprana: mercado cerrado. Barata a propósito — es lo que
    # permite programar una ventana UTC ancha sin pagarla en minutos.
    if args.clase == "accion" and not args.simbolo and not args.forzar:
        if not mercado_abierto():
            resumen.append("### ETL acciones — omitido")
            resumen.append("")
            resumen.append(
                "Bolsa de Nueva York cerrada. La pasada termina sin consultar "
                "a ningún proveedor."
            )
            emitir_resumen()
            return 0

    cliente = ClienteSupabase.desde_entorno()
    activos = seleccionar_activos(cliente, args.clase, args.simbolo, args.tope)

    if not activos:
        resumen.append("### ETL — sin activos que procesar")
        emitir_resumen()
        return 0

    _registrar_cripto_del_catalogo(activos)
    _memoizar_ohlcv()

    etiqueta = args.simbolo or args.clase or "todo el universo"
    inicio = datetime.now(timezone.utc)
    conteo = {"ok": 0, "fallo": 0, "suspendido": 0, "invalido": 0}
    lineas: list[str] = []

    for activo in activos:
        try:
            resultado, detalle = procesar_activo(cliente, activo, version_motor)
        except ErrorEscritura as exc:
            resumen.append(f"### ETL {etiqueta} — FALLO DE ESCRITURA")
            resumen.append("")
            resumen.append(f"```\n{exc}\n```")
            emitir_resumen()
            return 1
        except Exception:  # cualquier cosa inesperada del motor
            resultado, detalle = "fallo", traceback.format_exc(limit=2)[:200]

        conteo[resultado] = conteo.get(resultado, 0) + 1
        icono = {"ok": "ok", "fallo": "fallo", "suspendido": "susp", "invalido": "inv"}[resultado]
        lineas.append(f"| `{activo['simbolo']}` | {icono} | {detalle} |")

    duracion = (datetime.now(timezone.utc) - inicio).total_seconds()

    resumen.append(f"### ETL {etiqueta}")
    resumen.append("")
    resumen.append(
        f"- Activos procesados: **{len(activos)}** "
        f"(ok {conteo['ok']} · fallo {conteo['fallo']} · "
        f"suspendidos {conteo['suspendido']} · inválidos {conteo['invalido']})"
    )
    resumen.append(f"- Duración: **{duracion:.0f}s**")
    resumen.append(f"- Versión del motor: `{version_motor}`")
    resumen.append("")
    resumen.append("| Activo | Resultado | Detalle |")
    resumen.append("|---|---|---|")
    resumen.extend(lineas)
    emitir_resumen()

    # El job termina en rojo solo si NINGÚN activo salió bien: que falle
    # uno es normal (un proveedor gratuito no oficial falla), que fallen
    # todos es una caída.
    return 0 if conteo["ok"] > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
