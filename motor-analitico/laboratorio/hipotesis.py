#!/usr/bin/env python3
"""
Prueba automática de las hipótesis de los agentes (doc fase-3/01 §5, I3).

    python -m laboratorio.hipotesis              # las `propuesta`, como mucho 3
    python -m laboratorio.hipotesis --id 12      # una concreta (también si ya se probó)

Para cada hipótesis:

  1. El agente TAL COMO OPERA (su estrategia de producción traducida por
     `agentes.parametros_de_agente`) y el agente CON EL CAMBIO, sobre el
     universo activo de sus clases y 5 años de velas.
  2. En el tramo de validación (el 30 % final, como el laboratorio), la
     expectativa en R de los dos.
  3. La referencia al azar: el agente con el cambio entrando en días al
     azar con su misma frecuencia (`AzarAgente`), en `--semillas` tiradas.
  4. El veredicto con el criterio que se fijó al crear la hipótesis: al
     menos 30 operaciones, mejora mínima en R, intervalo del 90 % por encima
     de cero y percentil frente al azar. El percentil exigido sube un punto
     por cada prueba anterior (hasta 99): probar mucho no regala validaciones.

Escribe el resultado en `agente_hipotesis` (estado, resultado, informe) y
deja un evento del agente. También mide la concordancia de cada agente con
producción (`concordancia.py`). Lee y escribe con la clave de servicio.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from laboratorio import metricas  # noqa: E402
from laboratorio.agentes import parametros_de_agente  # noqa: E402
from laboratorio.concordancia import concordancia_agente  # noqa: E402
from laboratorio.datos import cargar, con_spread, spread_de, universo  # noqa: E402
from laboratorio.estrategias import Agente, AzarAgente  # noqa: E402
from laboratorio.motor import simular  # noqa: E402

SEMILLAS = 20
PERCENTIL_TECHO = 99
# Lo que admite la estrategia `agente`: un cambio con otra clave (p. ej. la
# rotación) no se puede probar todavía.
CAMBIOS_ADMITIDOS = {"rr_minimo", "atr_min", "atr_max", "condicion", "deterioro",
                     "parcial_recorrido", "parcial_fraccion", "parcial_mover", "sigue_atr", "fuerza_minima",
                     "precio_min", "objetivo_min_spread", "sl_min_atr", "sl_max_atr", "tp_max_atr",
                     "escalonar", "filtro"}


def percentil_exigido(criterio: dict) -> int:
    base = int(criterio.get("percentil_azar_min", 90))
    return min(PERCENTIL_TECHO, base + int(criterio.get("pruebas_previas", 0)))


def _resumen(m: metricas.Medidas | None) -> dict | None:
    if m is None:
        return None
    return {"operaciones": m.operaciones, "expectativa_r": round(m.expectativa_r, 4),
            "ic90": [round(m.ic90[0], 4), round(m.ic90[1], 4)], "aciertos_pct": round(m.aciertos_pct, 1),
            "factor_beneficio": None if not np.isfinite(m.factor_beneficio) else round(m.factor_beneficio, 3),
            "coste_pct": round(m.coste_pct, 1)}


class _Preparada:
    """Una estrategia `agente` con sus columnas ya calculadas. La
    confluencia y los niveles solo dependen del R:R y de la banda de
    volatilidad: el agente actual, el cambio y las tiradas al azar los
    comparten y no hace falta recalcularlos en cada simulación."""

    def __init__(self, estrategia, preparado):
        self.estrategia, self.preparado = estrategia, preparado
        self.nombre = estrategia.nombre

    def preparar(self, df):
        return self.preparado

    def entrada(self, df, t):
        return self.estrategia.entrada(df, t)

    def actualizar(self, df, t, pos):
        return self.estrategia.actualizar(df, t, pos)


class _Cache:
    def __init__(self, datos: dict):
        self.datos = {k: con_spread(df, *k) for k, df in datos.items()}
        self.columnas = {}

    def preparado(self, clave_activo, estrategia):
        clave = (clave_activo, estrategia.rr_minimo, estrategia.atr_min, estrategia.atr_max,
                 estrategia.precio_min, estrategia.objetivo_min_spread,
                 estrategia.sl_min_atr, estrategia.sl_max_atr, estrategia.tp_max_atr)
        if clave not in self.columnas:
            self.columnas[clave] = estrategia.preparar(self.datos[clave_activo])
        return self.columnas[clave]

    def operar(self, crear_estrategia) -> list:
        """Todas las operaciones de una estrategia (se crea una por clase)."""
        ops = []
        for (simbolo, clase) in self.datos:
            e = crear_estrategia(clase)
            ops += simular(self.datos[(simbolo, clase)], _Preparada(e, self.preparado((simbolo, clase), e)),
                           spread_de(simbolo, clase), simbolo, clase)
        return ops

    def frecuencia(self, crear_estrategia) -> float:
        """Fracción de los días con niveles válidos en los que la estrategia
        quiere entrar: la probabilidad que usa su referencia al azar."""
        entradas = elegibles = 0
        for clave_activo in self.datos:
            e = crear_estrategia(clave_activo[1])
            p = self.preparado(clave_activo, e)
            for t in range(199, len(p) - 1):
                if not np.isnan(p["NIVEL_SL"].iloc[t]):
                    elegibles += 1
                    entradas += e.entrada(p, t) is not None
        return entradas / elegibles if elegibles else 0.0


def juzgar(base, variante, azar: list[float], criterio: dict) -> tuple[bool, list[str], dict]:
    """Veredicto sobre las medidas de validación. Devuelve (validada,
    motivos si no, detalle)."""
    exigido = percentil_exigido(criterio)
    motivos = []
    if variante is None or variante.operaciones < metricas.MIN_OPERACIONES:
        n = 0 if variante is None else variante.operaciones
        motivos.append(f"solo {n} operaciones en validación con el cambio (mínimo {metricas.MIN_OPERACIONES})")
        return False, motivos, {"percentil_exigido": exigido}
    mejora = variante.expectativa_r - (base.expectativa_r if base else 0.0)
    if mejora < float(criterio.get("mejora_r_min", 0.05)):
        motivos.append(f"mejora de {mejora:+.3f} R frente al agente actual (mínimo +{criterio.get('mejora_r_min', 0.05)} R)")
    if criterio.get("ic90_sin_cero", True) and variante.ic90[0] <= 0:
        motivos.append(f"el intervalo del 90 % incluye el cero ({variante.ic90[0]:+.3f} R)")
    az = np.array([a for a in azar if a is not None])
    percentil = float((az < variante.expectativa_r).mean() * 100) if len(az) else 0.0
    if percentil < exigido:
        motivos.append(f"supera al {percentil:.0f} % de las tiradas al azar (exigido {exigido} %)")
    detalle = {"mejora_r": round(mejora, 4), "percentil_azar": round(percentil, 1), "percentil_exigido": exigido,
               "azar": {"tiradas": int(len(az)),
                        "mediana": round(float(np.median(az)), 4) if len(az) else None,
                        "p5": round(float(np.quantile(az, 0.05)), 4) if len(az) else None,
                        "p95": round(float(np.quantile(az, 0.95)), 4) if len(az) else None}}
    return not motivos, motivos, detalle


def probar(hipotesis: dict, estrategia: dict, datos: dict, semillas: int = SEMILLAS) -> tuple[str, dict]:
    """(estado, resultado) de una hipótesis sobre `datos` {(simbolo, clase): df}."""
    exp = hipotesis["experimento"]
    cambio = exp.get("cambio") or {}
    fuera = set(cambio) - CAMBIOS_ADMITIDOS
    if fuera:
        return "no_ejecutable", {"motivos": [f"el laboratorio no modela: {', '.join(sorted(fuera))}"]}
    clases = set(exp.get("clases") or [])
    datos = {k: v for k, v in datos.items() if not clases or k[1] in clases}
    if not datos:
        return "no_ejecutable", {"motivos": ["sin velas para las clases del experimento"]}

    def base(clase):
        return Agente(**parametros_de_agente(estrategia, clase))

    def con_cambio(clase):
        return Agente(**{**parametros_de_agente(estrategia, clase), **cambio})

    desde = min(df.index[0] for df in datos.values())
    hasta = max(df.index[-1] for df in datos.values())
    corte = desde + (hasta - desde) * metricas.TRAMO_DISENO

    cache = _Cache(datos)
    _, val_base = metricas.partir(cache.operar(base), corte)
    _, val_var = metricas.partir(cache.operar(con_cambio), corte)
    m_base, m_var = metricas.medir(val_base), metricas.medir(val_var)

    probabilidad = cache.frecuencia(con_cambio)
    azar = []
    for s in range(semillas):
        def azar_s(clase, s=s):
            return AzarAgente(probabilidad=probabilidad, semilla=s,
                              **{**parametros_de_agente(estrategia, clase), **cambio})
        _, val = metricas.partir(cache.operar(azar_s), corte)
        m = metricas.medir(val)
        azar.append(m.expectativa_r if m else None)

    validada, motivos, detalle = juzgar(m_base, m_var, azar, hipotesis.get("criterio") or {})
    resultado = {
        "veredicto": "validada" if validada else "refutada", "motivos": motivos,
        "agente_actual": _resumen(m_base), "con_cambio": _resumen(m_var), **detalle,
        "probabilidad_azar": round(probabilidad, 4), "activos": len(datos),
        "validacion_desde": f"{corte:%Y-%m-%d}", "periodo": exp.get("periodo", "5y"),
        "version_estrategia_probada": estrategia.get("version"),
        "probada_en": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    return ("validada" if validada else "refutada"), resultado


def texto_informe(nombre: str, hip: dict, estado: str, res: dict) -> str:
    lineas = [f"## {nombre} · hipótesis #{hip['id']}", "", hip["enunciado"], ""]
    if estado == "no_ejecutable":
        return "\n".join(lineas + [f"⚪ **no ejecutable**: {'; '.join(res['motivos'])}", ""])
    a, c = res.get("agente_actual") or {}, res.get("con_cambio") or {}
    lineas += [
        f"Validación desde el {res['validacion_desde']}, {res['activos']} activos.", "",
        "| | Operaciones | Expectativa (R) | IC 90 % |", "|---|---|---|---|",
        f"| Agente actual | {a.get('operaciones', 0)} | {a.get('expectativa_r', 0):+.3f} | {a.get('ic90', ['—', '—'])} |",
        f"| Con el cambio | {c.get('operaciones', 0)} | {c.get('expectativa_r', 0):+.3f} | {c.get('ic90', ['—', '—'])} |",
        "",
        f"Frente al azar: supera al {res.get('percentil_azar', 0):.0f} % de {res.get('azar', {}).get('tiradas', 0)} tiradas "
        f"(exigido {res.get('percentil_exigido')} %).", "",
        "✅ **validada**" if estado == "validada" else "❌ **refutada**: " + "; ".join(res["motivos"]), "",
    ]
    conc = res.get("concordancia")
    if conc:
        lineas += [f"Concordancia con producción: {conc['texto']}", ""]
    return "\n".join(lineas)


def cargar_datos(clases: set[str], periodo: str = "5y") -> dict:
    datos = {}
    for simbolo, clase in universo():
        if clase not in clases:
            continue
        df = cargar(simbolo, clase, periodo)
        if df is not None and len(df) >= 260:
            datos[(simbolo, clase)] = df
    return datos


def main() -> int:
    from escritor_supabase import ClienteSupabase

    p = argparse.ArgumentParser()
    p.add_argument("--id", type=int, help="probar solo esta hipótesis")
    p.add_argument("--maximo", type=int, default=3)
    p.add_argument("--semillas", type=int, default=SEMILLAS)
    a = p.parse_args()

    cliente = ClienteSupabase.desde_entorno()
    filtro = {"select": "*", "order": "id", "limit": str(a.maximo)}
    filtro.update({"id": f"eq.{a.id}"} if a.id else {"estado": "eq.propuesta"})
    hipotesis = cliente.seleccionar("agente_hipotesis", filtro)
    if not hipotesis:
        print("No hay hipótesis que probar.")
        return 0
    agentes = {f["id"]: f for f in cliente.seleccionar(
        "agentes", {"select": "id,nombre,estrategia,version_estrategia,creado_en"})}
    clases = {c for h in hipotesis for c in (h["experimento"].get("clases") or ["accion", "cripto"])}
    datos = cargar_datos(clases)
    url = None
    if os.environ.get("GITHUB_RUN_ID"):
        url = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
               f"{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}")

    textos, concordancias = ["# Hipótesis de los agentes", ""], {}
    for hip in hipotesis:
        ag = agentes[hip["agente_id"]]
        estrategia = {**(ag["estrategia"] or {}), "version": ag["version_estrategia"]}
        cliente.actualizar("agente_hipotesis", {"id": f"eq.{hip['id']}"},
                           {"estado": "en_prueba", "actualizado_en": datetime.now(timezone.utc).isoformat()})
        try:
            estado, resultado = probar(hip, estrategia, datos, a.semillas)
        except Exception as exc:  # noqa: BLE001
            # Que una hipótesis rota no deje las demás sin probar; vuelve a
            # `propuesta` para la próxima pasada.
            print(f"  hipótesis #{hip['id']}: {exc}")
            cliente.actualizar("agente_hipotesis", {"id": f"eq.{hip['id']}"}, {"estado": "propuesta"})
            continue
        if ag["id"] not in concordancias:
            concordancias[ag["id"]] = concordancia_agente(cliente, ag, datos)
        resultado["concordancia"] = concordancias[ag["id"]]
        cliente.actualizar("agente_hipotesis", {"id": f"eq.{hip['id']}"}, {
            "estado": estado, "resultado": resultado, "informe_url": url,
            "actualizado_en": datetime.now(timezone.utc).isoformat()})
        cliente.insertar("eventos_sistema", [{
            "agente_id": ag["id"], "tipo": "agente",
            "mensaje": f"{ag['nombre']}: el laboratorio {'valida' if estado == 'validada' else 'refuta' if estado == 'refutada' else 'no puede probar'} "
                       f"su hipótesis «{hip['enunciado'][:120]}»",
            "datos": {"hipotesis_id": hip["id"], "estado": estado}}])
        textos.append(texto_informe(ag["nombre"], hip, estado, resultado))

    texto = "\n".join(textos)
    salida = Path("laboratorio_salida")
    salida.mkdir(exist_ok=True)
    (salida / "hipotesis.md").write_text(texto, encoding="utf-8")
    print(texto)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(texto + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
