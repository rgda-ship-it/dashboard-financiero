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

Pensado para un proyecto VACÍO (recién migrado): el libro mayor
(`movimientos_saldo`) es append-only y su trigger rechaza actualizar un
apunte que ya exista. Los usuarios de `auth.users` tienen que existir antes
(se recrean desde Supabase Auth), porque `perfiles` apunta a ellos.

Al terminar reajusta las secuencias (`fn_reajustar_secuencias`, 0018): sin
eso, el primer INSERT nuevo chocaría con un id restaurado.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "motor-analitico"))

from escritor_supabase import ClienteSupabase  # noqa: E402
# TABLAS es {tabla: clave primaria}, en orden de dependencias.
from respaldo import COLUMNAS_GENERADAS, TABLAS  # noqa: E402

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
        # Una columna generada no admite valor: se quita antes de escribir.
        quitar = COLUMNAS_GENERADAS.get(tabla, [])
        if quitar:
            filas = [{k: v for k, v in f.items() if k not in quitar} for f in filas]
        for i in range(0, len(filas), LOTE):
            cliente.upsert(tabla, filas[i : i + LOTE], TABLAS[tabla])

    if aplicar:
        print(f"- secuencias reajustadas: {cliente.rpc('fn_reajustar_secuencias')}")

    if not aplicar:
        print("\nNada escrito. Repite con --aplicar para restaurar de verdad.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
