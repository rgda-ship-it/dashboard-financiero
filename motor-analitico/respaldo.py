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
   experimento (cuentas, órdenes, libro mayor, agentes y todo lo que
   aprenden). Precios e indicadores quedan fuera: son los grandes y se
   regeneran desde los proveedores; de `senales` solo se copian las que
   justifican una orden (`v_senales_evidencia`), sin las que las órdenes no
   se podrían restaurar. Sale un JSON por tabla, que
   `scripts/restaurar_respaldo.py` vuelve a cargar.
3. RETENCIÓN de `senales` (doc 02 §6.1): sin podar, la tabla alcanza
   ~600 MB en un año y el tier gratuito da 500 MB. Y de los avisos de
   `eventos_sistema` de más de 180 días (0018).

Hasta el 2026-09-30 el respaldo no incluía NADA del simulador ni de los
agentes: el experimento, que es lo único que no se regenera. La prueba
`test_toda_tabla_tiene_destino` lee las migraciones y falla si una tabla
nueva no está ni respaldada, ni declarada regenerable, ni excluida con su
motivo, para que no vuelva a pasar.
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
#
# El valor es la CLAVE PRIMARIA, y se usa para ordenar al paginar: sin un
# orden estable, `limit`/`offset` puede repetir o saltarse filas entre
# páginas. (PostgREST no admite ordenar por posición, `order=1`: lo
# interpreta como una columna llamada "1" y responde 42703.)
TABLAS = {
    # Gobierno y catálogo
    "perfiles": "id",
    "carteras": "id",
    "activos": "id",
    "cartera_activos": "cartera_id,activo_id",
    "posiciones_reales": "id",
    "registro_consentimiento": "id",
    "solicitudes_activo": "id",
    "auditoria_admin": "id",
    "catalogo_coingecko": "id",
    # Calendario de mercados (0031): lo siembra la migración, pero los
    # festivos se actualizan a mano cada año y no deben perderse.
    "mercados": "clave",
    # Experimento: simulador y agentes (desde 0018). `senales` aquí son
    # solo las que justifican una orden (ver FUENTES).
    "senales": "id",
    "agentes": "id",
    "agente_estrategia_versiones": "agente_id,version",
    "cuentas_simulacion": "id",
    "ordenes": "id",
    "movimientos_saldo": "id",
    "ordenes_parciales": "id",
    "agente_dias": "agente_id,fecha",
    "agente_semanas": "agente_id,semana_iso",
    "mejores_practicas": "id",
    "mp_adopciones": "id",
    "mp_valoraciones": "practica_id,agente_id",
    "agente_backlog": "id",
    "agente_backlog_ocurrencias": "backlog_id,agente_id,fecha",
    "agente_decisiones": "id",
    "agente_ajustes": "id",
    # Al final: apunta a agentes y a usuarios.
    "eventos_sistema": "id",
}

# De dónde se LEE cada tabla, si no es de ella misma.
FUENTES = {"senales": "v_senales_evidencia"}

# Columnas generadas: se respaldan (se leen) pero no se pueden escribir, así
# que la restauración las quita antes del upsert.
COLUMNAS_GENERADAS = {"ordenes": ["nominal"], "senales": ["ratio_rr"]}

# Regenerables desde los proveedores: no se respaldan (pesan y se
# reconstruyen). Se listan aquí para que quede escrito POR QUÉ faltan.
REGENERABLES = ["precios_diarios", "indicadores_diarios"]

# Fontanería sin valor de negocio: colas y contadores de minutos.
NO_RESPALDADAS = {
    "monitor_peticiones": "cola de peticiones de precio del monitor; se purga sola a diario",
    "control_despachos": "marca del último disparo de cada workflow",
    "limites_uso": "contadores por minuto del límite de uso",
}

PAGINA = 1000


def descargar(cliente: ClienteSupabase, tabla: str, clave: str) -> list[dict]:
    """Trae la tabla entera paginando: PostgREST limita cada respuesta."""
    filas: list[dict] = []
    while True:
        lote = cliente.seleccionar(
            tabla,
            {"select": "*", "order": clave, "limit": PAGINA, "offset": len(filas)},
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
    fallos: list[str] = []
    for tabla, clave in TABLAS.items():
        try:
            filas = descargar(cliente, FUENTES.get(tabla, tabla), clave)
        except ErrorEscritura as exc:
            # Un respaldo incompleto que termina en verde es peor que no
            # tenerlo: el job se pone en rojo al final.
            fallos.append(tabla)
            resumen.append(f"| `{tabla}` | ERROR: {str(exc)[:120]} |")
            continue
        with open(f"{destino}/{tabla}.json", "w", encoding="utf-8") as f:
            json.dump(filas, f, ensure_ascii=False, indent=1, default=str)
        total += len(filas)
        resumen.append(f"| `{tabla}` | {len(filas)} |")
    with open(f"{destino}/_manifiesto.json", "w", encoding="utf-8") as f:
        json.dump(
            {
                "creado_en": datetime.now(timezone.utc).isoformat(),
                "tablas": list(TABLAS),
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
    try:
        eventos = cliente.rpc("fn_retencion_eventos")
    except ErrorEscritura as exc:
        print(f"::error::La retención de eventos falló: {exc}")
        return 1
    resumen.append("")
    resumen.append("**Retención de `eventos_sistema`**")
    resumen.append("")
    resumen.append("```json")
    resumen.append(json.dumps(eventos, ensure_ascii=False))
    resumen.append("```")

    if fallos:
        resumen.append("")
        resumen.append(f"**Respaldo INCOMPLETO**: {', '.join(fallos)}.")

    texto = "\n".join(resumen)
    print(texto)
    ruta = os.environ.get("GITHUB_STEP_SUMMARY")
    if ruta:
        with open(ruta, "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    if fallos:
        print(f"::error::No se pudieron respaldar: {', '.join(fallos)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
