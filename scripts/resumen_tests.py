#!/usr/bin/env python3
"""
Resumen legible de la suite del motor analítico para el job summary de
GitHub Actions.

Vive como fichero propio y no como heredoc dentro del YAML a propósito:
un script de Python incrustado en un bloque `run:` de un workflow es
imposible de probar en local y se rompe por indentación sin que nadie se
entere hasta que la CI falla.

Además comprueba el CONTEO de casos, no solo que no haya fallos: si un
fichero de test deja de recolectarse —un `import` roto, un renombrado—
pytest termina en verde con menos pruebas, y eso es indistinguible del
éxito si solo se mira el código de salida.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Cota inferior del tamaño de la suite.
#
#   69  = los casos que la Fase 1 dejó en verde (CHANGELOG 2026-09-20).
#   +21 = los del Sprint 1: 12 de escritor_supabase, 9 de ventana_mercado.
#
# Si este número sube porque se añaden pruebas, actualízalo aquí. Si la
# suite recolecta MENOS, es un fallo aunque todo esté en verde.
CASOS_FASE_1 = 69
CASOS_ESPERADOS = 90


def main() -> int:
    informe = Path(sys.argv[1] if len(sys.argv) > 1 else "resultados.xml")

    if not informe.exists():
        print("### Suite del motor analítico\n")
        print("No se generó el informe: la suite no llegó a ejecutarse.")
        return 1

    raiz = ET.parse(informe).getroot()
    suite = raiz if raiz.tag == "testsuite" else raiz[0]

    total = int(suite.get("tests", 0))
    fallos = int(suite.get("failures", 0))
    errores = int(suite.get("errors", 0))
    omitidos = int(suite.get("skipped", 0))
    duracion = float(suite.get("time", 0))

    print("### Suite del motor analítico\n")
    print(f"- Casos ejecutados: **{total}** (esperados: {CASOS_ESPERADOS})")
    print(f"- Fallos: **{fallos}** · Errores: **{errores}** · Omitidos: {omitidos}")
    print(f"- Duración: {duracion:.1f}s\n")

    salida = 0

    if fallos or errores:
        print("> Hay pruebas en rojo. Revisa el log del paso anterior.")
        salida = 1

    if total < CASOS_ESPERADOS:
        print(
            f"> **Se recolectaron menos casos de los esperados** "
            f"({total} < {CASOS_ESPERADOS}). Probablemente un fichero de test "
            f"dejó de importarse: pytest termina en verde con menos pruebas, "
            f"y eso no es un éxito."
        )
        if total < CASOS_FASE_1:
            print(
                f">\n> Además se ha bajado por debajo de los {CASOS_FASE_1} "
                f"casos heredados de la Fase 1, que son los que protegen las "
                f"ocho reglas de riesgo del README."
            )
        salida = 1

    return salida


if __name__ == "__main__":
    sys.exit(main())
