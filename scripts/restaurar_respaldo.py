#!/usr/bin/env python3
"""
Restaura un respaldo semanal (los JSON que deja el workflow keep-alive).

No se usa en el día a día: existe para que el respaldo signifique algo.
El tier gratuito de Supabase no da recuperación a un punto en el tiempo,
así que esta es la vuelta atrás disponible para las tablas que NO se
pueden regenerar desde los proveedores.

Uso:
    # descomprime el artefacto del workflow en ./respaldo
    SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
        python scripts/restaurar_respaldo.py respaldo --aplicar

Sin `--aplicar` solo dice qué haría. Escribe con UPSERT por clave
primaria: una fila que ya exista se actualiza, no se duplica.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "motor-analitico"))

from escritor_supabase import ClienteSupabase  # noqa: E402
# TABLAS es {tabla: clave primaria}, en orden de dependencias.
from respaldo import TABLAS  # noqa: E402

LOTE = 500


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    carpeta = sys.argv[1]
    aplicar = "--aplicar" in sys.argv
    cliente = ClienteSupabase.desde_entorno() if aplicar else None

    for tabla in TABLAS:
        ruta = os.path.join(carpeta, f"{tabla}.json")
        if not os.path.exists(ruta):
            print(f"- {tabla}: sin fichero, se omite")
            continue
        with open(ruta, encoding="utf-8") as f:
            filas = json.load(f)
        print(f"- {tabla}: {len(filas)} filas" + ("" if aplicar else " (simulación)"))
        if not aplicar or not filas:
            continue
        for i in range(0, len(filas), LOTE):
            cliente.upsert(tabla, filas[i : i + LOTE], TABLAS[tabla])

    if not aplicar:
        print("\nNada escrito. Repite con --aplicar para restaurar de verdad.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
