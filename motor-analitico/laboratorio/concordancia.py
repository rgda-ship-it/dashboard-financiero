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
"""

from __future__ import annotations

from datetime import date, timedelta

import pandas as pd

from laboratorio.agentes import parametros_de_agente
from laboratorio.datos import spread_de
from laboratorio.estrategias import Agente
from laboratorio.motor import simular

ANTES, DESPUES = 3, 1   # holgura en días naturales: fines de semana y la señal del cierre anterior


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


def medir(reales_por_activo: dict, lab_por_activo: dict) -> dict:
    """Agrega `emparejar` sobre todos los activos del universo del agente."""
    reales = con_gemela = lab = lab_con_real = 0
    for activo in set(reales_por_activo) | set(lab_por_activo):
        r, l_ = reales_por_activo.get(activo, []), lab_por_activo.get(activo, [])
        a, b = emparejar(r, l_)
        reales, con_gemela, lab, lab_con_real = reales + len(r), con_gemela + a, lab + len(l_), lab_con_real + b
    pct = round(100 * con_gemela / reales, 1) if reales else None
    pct_lab = round(100 * lab_con_real / lab, 1) if lab else None
    texto = (f"{con_gemela} de {reales} entradas reales tienen su gemela en el laboratorio"
             f" ({pct if pct is not None else '—'} %); {lab_con_real} de {lab} entradas del laboratorio"
             f" tienen una real ({pct_lab if pct_lab is not None else '—'} %).")
    if pct is not None and pct < 50:
        texto += " Concordancia baja: el veredicto describe al laboratorio más que al agente."
    return {"reales": reales, "reales_con_gemela": con_gemela, "pct_reales": pct,
            "laboratorio": lab, "laboratorio_con_real": lab_con_real, "pct_laboratorio": pct_lab,
            "texto": texto}


def concordancia_agente(cliente, agente: dict, datos: dict) -> dict:
    """Entradas reales del agente desde que existe frente a las de la
    estrategia `agente` con sus parámetros, en el mismo periodo."""
    alta = pd.Timestamp(agente["creado_en"])
    desde = (alta.tz_convert(None) if alta.tzinfo else alta).normalize()
    clases = set((agente.get("estrategia") or {}).get("clases_admitidas") or ["accion", "cripto"])
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
        if clave and clave in datos:
            reales.setdefault(clave, []).append(pd.Timestamp(o["fecha_entrada"]).date())

    lab: dict = {}
    for (simbolo, clase), df in datos.items():
        if clase not in clases:
            continue
        estrategia = Agente(**parametros_de_agente(agente.get("estrategia") or {}, clase))
        for op in simular(df, estrategia, spread_de(simbolo, clase), simbolo, clase):
            if op.fecha_entrada >= desde:
                lab.setdefault((simbolo, clase), []).append(op.fecha_entrada.date())
    return medir(reales, lab)
