#!/usr/bin/env python3
"""
Consulta de SOLO LECTURA a producción, para que Claude revise los datos
sin pasar por el editor de Supabase.

    python scripts/consultar.py "select * from v_comparativa_agentes"
    python scripts/consultar.py -f scripts/revision_agentes.sql
    python scripts/consultar.py -f consulta.sql -o salida.csv

Lee SOLO `SUPABASE_DB_URL_LECTURA` del `.env` de la raíz (rol
`analista_lectura`), nunca la URL de administrador, y abre la sesión en
modo `read only`: aunque el rol tuviera permisos de escritura, la sesión
no podría usarlos. Escribe el resultado en CSV (por defecto, en pantalla).

Necesita `psycopg` (scripts/requirements-consultas.txt).
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
VARIABLE = "SUPABASE_DB_URL_LECTURA"


def url_lectura() -> str:
    import os
    if os.environ.get(VARIABLE):
        return os.environ[VARIABLE]
    env = RAIZ / ".env"
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            clave, _, valor = linea.partition("=")
            if clave.strip() == VARIABLE and valor.strip():
                return valor.strip().strip('"').strip("'")
    sys.exit(f"Falta {VARIABLE} en el entorno o en {env}.")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("sql", nargs="?", help="la consulta (o usa -f)")
    p.add_argument("-f", "--fichero", help="fichero .sql con la consulta")
    p.add_argument("-o", "--salida", help="CSV de salida (por defecto, la pantalla)")
    p.add_argument("--max-filas", type=int, default=5000)
    a = p.parse_args()
    if not a.sql and not a.fichero:
        p.error("falta la consulta")
    sql = Path(a.fichero).read_text(encoding="utf-8") if a.fichero else a.sql

    import psycopg
    with psycopg.connect(url_lectura(), connect_timeout=15) as cx:
        cx.read_only = True
        with cx.cursor() as cur:
            cur.execute("set statement_timeout = '60s'")
            cur.execute(sql)
            if cur.description is None:
                print("(sin resultado)")
                return 0
            cabecera = [c.name for c in cur.description]
            filas = cur.fetchmany(a.max_filas)

    destino = open(a.salida, "w", newline="", encoding="utf-8") if a.salida else sys.stdout
    try:
        w = csv.writer(destino)
        w.writerow(cabecera)
        w.writerows(filas)
    finally:
        if a.salida:
            destino.close()
    if len(filas) == a.max_filas:
        print(f"(cortado en {a.max_filas} filas)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
