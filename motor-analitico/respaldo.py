#!/usr/bin/env python3
"""
Latido semanal, respaldo y retención — por la API REST (sin psql).

POR QUÉ NO USA psql: la cadena de conexión directa de Supabase
(`db.<ref>.supabase.co`) solo resuelve por IPv6 y los runners de GitHub
Actions son IPv4: `Network is unreachable`. La alternativa era el Session
pooler, que obliga a guardar la contraseña de la base de datos en un
secreto más. Decisión del dueño (2026-09-22): usar la MISMA vía que el
ETL —PostgREST con la clave de servicio— y no tener esa contraseña en
ninguna parte.

Tres trabajos:

1. LATIDO. Supabase pausa un proyecto tras ~1 semana de baja actividad.
   Una lectura basta para detectar que sigue vivo y fallar ruidosamente
   si no lo está.
2. RESPALDO de lo irreemplazable: gobierno (quién está aprobado) y
   experimento. Las tablas de precios, indicadores y señales quedan
   fuera: son las grandes y se regeneran desde los proveedores. Sale un
   JSON por tabla, que `scripts/restaurar_respaldo.py` vuelve a cargar.
3. RETENCIÓN de `senales` (doc 02 §6.1): sin podar, la tabla alcanza
   ~600 MB en un año y el tier gratuito da 500 MB.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from escritor_supabase import ClienteSupabase, ErrorEscritura  # noqa: E402

# Orden de restauración: las dependencias primero (una cartera necesita su
# perfil). `restaurar_respaldo.py` respeta este mismo orden.
TABLAS = [
    "perfiles",
    "carteras",
    "activos",
    "cartera_activos",
    "posiciones_reales",
    "registro_consentimiento",
    "solicitudes_activo",
    "auditoria_admin",
    "eventos_sistema",
    "catalogo_coingecko",
]

# Regenerables desde los proveedores: no se respaldan (pesan y se
# reconstruyen). Se listan aquí para que quede escrito POR QUÉ faltan.
REGENERABLES = ["precios_diarios", "indicadores_diarios", "senales"]

PAGINA = 1000


def descargar(cliente: ClienteSupabase, tabla: str) -> list[dict]:
    """Trae la tabla entera paginando: PostgREST limita cada respuesta."""
    filas: list[dict] = []
    while True:
        lote = cliente.seleccionar(
            tabla,
            {"select": "*", "order": "1", "limit": PAGINA, "offset": len(filas)},
        )
        filas.extend(lote)
        if len(lote) < PAGINA:
            return filas


def main() -> int:
    cliente = ClienteSupabase.desde_entorno()
    resumen = ["### Latido semanal", ""]

    # ── 1. Latido ────────────────────────────────────────────────────
    try:
        cliente.seleccionar("activos", {"select": "id", "limit": 1})
    except ErrorEscritura as exc:
        print(f"::error::El proyecto de Supabase no responde. Puede estar pausado. {exc}")
        return 1
    resumen.append("Proyecto despierto.")
    resumen.append("")

    # ── 2. Respaldo ──────────────────────────────────────────────────
    destino = "respaldo"
    os.makedirs(destino, exist_ok=True)
    resumen.append("| Tabla | Filas respaldadas |")
    resumen.append("|---|---|")
    total = 0
    for tabla in TABLAS:
        try:
            filas = descargar(cliente, tabla)
        except ErrorEscritura as exc:
            resumen.append(f"| `{tabla}` | ERROR: {str(exc)[:80]} |")
            continue
        with open(f"{destino}/{tabla}.json", "w", encoding="utf-8") as f:
            json.dump(filas, f, ensure_ascii=False, indent=1, default=str)
        total += len(filas)
        resumen.append(f"| `{tabla}` | {len(filas)} |")
    with open(f"{destino}/_manifiesto.json", "w", encoding="utf-8") as f:
        json.dump(
            {
                "creado_en": datetime.now(timezone.utc).isoformat(),
                "tablas": TABLAS,
                "no_respaldadas_por_regenerables": REGENERABLES,
                "filas_totales": total,
            },
            f,
            ensure_ascii=False,
            indent=1,
        )
    resumen.append("")
    resumen.append(f"Total: **{total}** filas. Restaurar: `scripts/restaurar_respaldo.py`.")
    resumen.append("")

    # ── 3. Retención ─────────────────────────────────────────────────
    try:
        podado = cliente.rpc("fn_retencion_senales")
    except ErrorEscritura as exc:
        print(f"::error::La retención de señales falló: {exc}")
        return 1
    resumen.append("**Retención de `senales`**")
    resumen.append("")
    resumen.append("```json")
    resumen.append(json.dumps(podado, ensure_ascii=False))
    resumen.append("```")

    texto = "\n".join(resumen)
    print(texto)
    ruta = os.environ.get("GITHUB_STEP_SUMMARY")
    if ruta:
        with open(ruta, "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
