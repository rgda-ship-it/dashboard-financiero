"""
Concordancia del laboratorio con producción (doc fase-3/01 §5, I3).

Una paridad exacta no es posible: los agentes deciden cada 30 minutos con
señales intradía, reparten el saldo y rotan; el laboratorio decide al
cierre, activo por activo. Lo que sí se puede medir es si el laboratorio
ENTRA DONDE ENTRA EL AGENTE: qué entradas reales tienen su gemela en el
laboratorio (mismo activo, entrada del laboratorio entre 3 días antes y 1
después) y cuántas entradas del laboratorio no tienen una real. Si la
concordancia es baja, los veredictos sobre las hipótesis dicen poco del
agente de verdad, y el informe lo avisa.

Solo cuentan las entradas reales hechas con las reglas que el laboratorio
reproduce (doc fase-3/07 §5): desde la 0030, que cambió en el código cómo
se calculan el stop y el objetivo, y desde la primera versión de la
estrategia con los mismos parámetros que la de hoy. Hasta el 26-10 se
contaba todo el histórico: el 80 % de las entradas reales de Cadencia y
Audacia eran de reglas anteriores, y la concordancia salía del 12 y el
23 % cuando, con las reglas de hoy, es del 33 y el 69 %.
"""

from __future__ import annotations

from datetime import date, timedelta

import pandas as pd

from laboratorio.agentes import parametros_de_agente
from laboratorio.datos import spread_de
from laboratorio.estrategias import Agente
from laboratorio.motor import simular

ANTES, DESPUES = 3, 1   # holgura en días naturales: fines de semana y la señal del cierre anterior

# La 0030 (D21) se aplicó el 2026-10-10 a las 21:31 UTC: desde entonces el
# stop y el objetivo se acotan en ATR como en `calcular_niveles_operativos`.
REGLAS_DESDE = pd.Timestamp("2026-10-10 21:31")

# Lo que decide DÓNDE entra el agente. Un cambio en las salidas (p. ej.
# apagar el deterioro, como Cadencia y Audacia el 15-10) no corta el
# periodo: la concordancia mide entradas.
CLAVES_ENTRADA = ("rr_minimo", "atr_min", "atr_max", "fuerza_minima")


def _entrada(estrategia: dict, clase: str) -> dict:
    p = parametros_de_agente(estrategia or {}, clase)
    return {k: p.get(k) for k in CLAVES_ENTRADA}


def _naive(ts) -> pd.Timestamp:
    t = pd.Timestamp(ts)
    return t.tz_convert(None) if t.tzinfo else t


def desde_reglas_vigentes(alta, versiones: list[dict], clases) -> pd.Timestamp:
    """Desde cuándo opera el agente con las reglas que el laboratorio
    reproduce: lo más tarde de su alta, la 0030 y la primera de las
    versiones seguidas (hacia atrás desde la última) cuyos parámetros de
    entrada son los de la versión vigente."""
    desde = max(_naive(alta), REGLAS_DESDE)
    if not versiones:
        return desde
    orden = sorted(versiones, key=lambda v: v["version"])
    vigente = {c: _entrada(orden[-1].get("estrategia"), c) for c in clases}
    primera = orden[-1]
    for v in reversed(orden):
        if {c: _entrada(v.get("estrategia"), c) for c in clases} != vigente:
            break
        primera = v
    return max(desde, _naive(primera["creado_en"]))


def emparejar(reales: list[date], lab: list[date]) -> tuple[int, int]:
    """(entradas reales con gemela en el laboratorio, entradas del
    laboratorio con gemela real). Cada entrada se empareja una sola vez,
    con la más cercana."""
    libres = sorted(lab)
    reales_con = 0
    usados = set()
    for d in sorted(reales):
        candidatos = [(abs((x - d).days), i) for i, x in enumerate(libres)
                      if i not in usados and d - timedelta(days=ANTES) <= x <= d + timedelta(days=DESPUES)]
        if candidatos:
            usados.add(min(candidatos)[1])
            reales_con += 1
    return reales_con, len(usados)


def medir(reales_por_activo: dict, lab_por_activo: dict, desde=None) -> dict:
    """Agrega `emparejar` sobre todos los activos del universo del agente."""
    reales = con_gemela = lab = lab_con_real = 0
    for activo in set(reales_por_activo) | set(lab_por_activo):
        r, l_ = reales_por_activo.get(activo, []), lab_por_activo.get(activo, [])
        a, b = emparejar(r, l_)
        reales, con_gemela, lab, lab_con_real = reales + len(r), con_gemela + a, lab + len(l_), lab_con_real + b
    pct = round(100 * con_gemela / reales, 1) if reales else None
    pct_lab = round(100 * lab_con_real / lab, 1) if lab else None
    texto = (f"{f'Desde el {desde:%d-%m-%Y}, ' if desde is not None else ''}"
             f"{con_gemela} de {reales} entradas reales tienen su gemela en el laboratorio"
             f" ({pct if pct is not None else '—'} %); {lab_con_real} de {lab} entradas del laboratorio"
             f" tienen una real ({pct_lab if pct_lab is not None else '—'} %).")
    if pct is not None and pct < 50:
        texto += " Concordancia baja: el veredicto describe al laboratorio más que al agente."
    if reales and reales < 20:
        texto += f" Solo {reales} entradas reales con las reglas de hoy: la medida aún es orientativa."
    return {"reales": reales, "reales_con_gemela": con_gemela, "pct_reales": pct,
            "laboratorio": lab, "laboratorio_con_real": lab_con_real, "pct_laboratorio": pct_lab,
            "desde": None if desde is None else f"{desde:%Y-%m-%d}", "texto": texto}


def concordancia_agente(cliente, agente: dict, datos: dict) -> dict:
    """Entradas reales del agente con las reglas de hoy frente a las de la
    estrategia `agente` con sus parámetros, en el mismo periodo."""
    clases = set((agente.get("estrategia") or {}).get("clases_admitidas") or ["accion", "cripto"])
    versiones = cliente.seleccionar("agente_estrategia_versiones", {
        "select": "version,estrategia,creado_en", "agente_id": f"eq.{agente['id']}"})
    desde = desde_reglas_vigentes(agente["creado_en"], versiones or [], sorted(clases))
    cuentas = [str(f["id"]) for f in cliente.seleccionar(
        "cuentas_simulacion", {"select": "id", "agente_id": f"eq.{agente['id']}"})]
    if not cuentas:
        return medir({}, {})
    activos = {f["id"]: (f["simbolo"], f["clase"]) for f in cliente.seleccionar(
        "activos", {"select": "id,simbolo,clase"})}
    ordenes = cliente.seleccionar("ordenes", {
        "select": "activo_id,fecha_entrada", "cuenta_id": f"in.({','.join(cuentas)})",
        "estado": "in.(abierta,cerrada)"})

    reales: dict = {}
    for o in ordenes:
        clave = activos.get(o["activo_id"])
        if clave and clave in datos and _naive(o["fecha_entrada"]) >= desde:
            reales.setdefault(clave, []).append(_naive(o["fecha_entrada"]).date())

    lab: dict = {}
    for (simbolo, clase), df in datos.items():
        if clase not in clases:
            continue
        estrategia = Agente(**parametros_de_agente(agente.get("estrategia") or {}, clase))
        for op in simular(df, estrategia, spread_de(simbolo, clase), simbolo, clase):
            if op.fecha_entrada >= desde.normalize():
                lab.setdefault((simbolo, clase), []).append(op.fecha_entrada.date())
    return medir(reales, lab, desde)
