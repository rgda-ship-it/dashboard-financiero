#!/usr/bin/env python3
"""
Refresco semanal de la copia local de /coins/list de CoinGecko (H-19).

UNA sola llamada por semana (~17.000 monedas). Con esa copia la base de
datos resuelve y valida criptos al instante y sin gastar cuota: buscar
«cardano» o rechazar «no-existe» no toca CoinGecko.

Lo ejecuta el workflow keep-alive.
"""

from __future__ import annotations

import os
import sys

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from escritor_supabase import ClienteSupabase  # noqa: E402

URL = "https://api.coingecko.com/api/v3/coins/list"
LOTE = 1000


def filas_catalogo(monedas: list[dict]) -> list[dict]:
    """Normaliza y descarta entradas incompletas o duplicadas."""
    vistas: set[str] = set()
    filas = []
    for m in monedas:
        cid = (m.get("id") or "").strip().lower()
        simbolo = (m.get("symbol") or "").strip().lower()
        nombre = (m.get("name") or "").strip()
        if not cid or not simbolo or not nombre or cid in vistas:
            continue
        vistas.add(cid)
        filas.append({"id": cid, "simbolo": simbolo[:40], "nombre": nombre[:200]})
    return filas


def main() -> int:
    resp = requests.get(URL, timeout=60)
    resp.raise_for_status()
    filas = filas_catalogo(resp.json())
    if len(filas) < 1000:
        # Una respuesta anómala no debe vaciar ni degradar el catálogo.
        print(f"Respuesta sospechosa de CoinGecko ({len(filas)} monedas). No se actualiza.")
        return 1
    cliente = ClienteSupabase.desde_entorno()
    for i in range(0, len(filas), LOTE):
        cliente.upsert("catalogo_coingecko", filas[i : i + LOTE], "id")
    print(f"Catálogo de CoinGecko actualizado: {len(filas)} monedas.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
