#!/usr/bin/env python3
"""
Altas de activos nuevos (Sprint 4 · H-19 / H-20).

Lo dispara la base de datos (pg_net → API de GitHub → workflow `altas`)
en cuanto un usuario pide un activo que el catálogo no conocía, y además
corre al principio de cada pasada horaria de cripto como red de
seguridad si el disparo no llega.

Dos trabajos, en este orden:

1. **Solicitudes de acciones.** Yahoo no publica una lista de símbolos
   que se pueda copiar, así que una acción nueva se valida descargando
   sus velas. Esa descarga ES el backfill: si sale bien, las velas ya
   están en la caché de la pasada y el paso 2 no vuelve a llamar. Si Yahoo
   no reconoce el símbolo, la solicitud se rechaza con el motivo y NO se
   crea fila en `activos`.

2. **Backfill de lo pendiente.** Todo activo `pendiente_backfill` con
   seguidores (acciones recién validadas y criptos que la BD ya creó al
   validarlas contra la copia de CoinGecko) pasa por el mismo
   `procesar_activo` del ETL: precios, indicadores, señal y estado
   `activo`.

Dos ejecuciones a la vez no se pisan: `fn_tomar_solicitudes()` reparte
con FOR UPDATE SKIP LOCKED y el workflow tiene `concurrency`.

Uso:
    python altas.py
"""

from __future__ import annotations

import os
import sys
import traceback
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import etl  # noqa: E402
import servicio_interno  # noqa: E402
from escritor_supabase import ClienteSupabase, ErrorEscritura  # noqa: E402


def validar_accion(simbolo: str) -> tuple[bool, str | None]:
    """Descarga las velas de una acción. (True, None) si existe.

    La descarga queda en la caché de la pasada (`etl._memoizar_ohlcv`), así
    que el backfill posterior no repite la llamada.
    """
    try:
        servicio_interno._obtener_ohlcv(simbolo)
        return True, None
    except ValueError as exc:
        if "no reconocido" in str(exc).lower():
            return False, f"Yahoo Finance no reconoce «{simbolo}»."
        return False, f"Yahoo Finance no devolvió datos de «{simbolo}»: {exc}"


def procesar_solicitudes(cliente: ClienteSupabase, validar=validar_accion) -> list[str]:
    """Paso 1. Devuelve líneas para el resumen del job."""
    lineas: list[str] = []
    solicitudes = cliente.rpc("fn_tomar_solicitudes") or []
    simbolos = sorted({s["simbolo"] for s in solicitudes})
    for simbolo in simbolos:
        try:
            ok, mensaje = validar(simbolo)
        except Exception as exc:  # red, esquema… se reintenta en la siguiente
            ok, mensaje = False, f"Fallo temporal del proveedor: {exc}"
        cliente.rpc(
            "fn_resolver_alta",
            {"p_simbolo": simbolo, "p_ok": ok, "p_mensaje": mensaje},
        )
        lineas.append(f"| `{simbolo}` | {'validado' if ok else 'rechazado'} | {mensaje or ''} |")
    return lineas


def pendientes_de_backfill(cliente: ClienteSupabase) -> list[dict]:
    campos = "id,simbolo,clase,proveedor,id_proveedor,estado,intentos,ultimo_etl_en,proximo_intento_en"
    return cliente.seleccionar(
        "activos",
        {"select": campos, "estado": "eq.pendiente_backfill", "seguidores": "gt.0"},
    )


def main() -> int:
    version_motor = os.environ.get("VERSION_MOTOR", "desconocida")
    cliente = ClienteSupabase.desde_entorno()
    etl._memoizar_ohlcv()
    inicio = datetime.now(timezone.utc)

    resumen = ["### Altas de activos", ""]
    lineas_sol = procesar_solicitudes(cliente)

    pendientes = pendientes_de_backfill(cliente)
    etl._registrar_cripto_del_catalogo(pendientes)
    lineas_bf: list[str] = []
    ok = 0
    for activo in pendientes:
        try:
            resultado, detalle = etl.procesar_activo(cliente, activo, version_motor)
        except ErrorEscritura:
            raise
        except Exception:
            resultado, detalle = "fallo", traceback.format_exc(limit=2)[:200]
        ok += resultado == "ok"
        lineas_bf.append(f"| `{activo['simbolo']}` | {resultado} | {detalle} |")

    duracion = (datetime.now(timezone.utc) - inicio).total_seconds()
    if not lineas_sol and not lineas_bf:
        resumen.append("Nada pendiente. Ninguna llamada a proveedores.")
    if lineas_sol:
        resumen += ["**Solicitudes**", "", "| Símbolo | Resultado | Detalle |", "|---|---|---|", *lineas_sol, ""]
    if lineas_bf:
        resumen += ["**Backfill**", "", "| Activo | Resultado | Detalle |", "|---|---|---|", *lineas_bf, ""]
    resumen.append(f"- Duración: **{duracion:.0f}s**")

    texto = "\n".join(resumen)
    print(texto)
    ruta = os.environ.get("GITHUB_STEP_SUMMARY")
    if ruta:
        with open(ruta, "a", encoding="utf-8") as f:
            f.write(texto + "\n")

    # En rojo solo si había backfills y no salió ninguno.
    return 1 if lineas_bf and ok == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
