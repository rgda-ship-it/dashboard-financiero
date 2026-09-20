"""
Selección de la mejor oportunidad de rotación a partir de un escaneo
general ya calculado.

Separado de `servicio_interno.py` deliberadamente: esta es lógica de
negocio pura (fácil de testear sin levantar el servicio web), y además
dependía de que quede clara la regla de diseño: esta función NUNCA
recibe el monto invertido por el usuario ni recalcula nada — solo lee
resultados de escaneo ya calculados para el universo general.
"""

from __future__ import annotations

# Rango numérico de la fuerza, para poder ordenar por ella. No se toca la
# definición de `fuerza` (vive en indicadores/tecnicos.py): aquí solo se
# le da un orden. "baja" no aparece porque nunca llega a ser candidata.
_RANGO_FUERZA = {"alta": 2, "media": 1}


def _proporcion_alcista(resultado: dict) -> float:
    """Alcistas sobre el total de señales emitidas para ese activo.

    Normaliza la asimetría de datos entre acciones y cripto: una cripto con
    2 de 2 señales alineadas está mejor alineada que una acción con 2 de 3,
    aunque ambas tengan la misma `fuerza`. Sin esto, el desempate acababa
    dependiendo del orden de la lista que envía el backend.
    """
    alcistas = resultado.get("indicadores_alcistas", 0)
    senales = resultado.get("senales")
    if isinstance(senales, list):
        return alcistas / max(1, len(senales))
    # Un escaneo servido desde la caché del circuit breaker puede venir de
    # una versión anterior del motor y no traer `senales`: se degrada al
    # total direccional en vez de fallar. Por eso todo aquí usa .get().
    bajistas = resultado.get("indicadores_bajistas", 0)
    return alcistas / max(1, alcistas + bajistas)


def mejor_oportunidad_del_escaneo(
    resultados_escaneo: list[dict], ticker_excluir: str
) -> dict | None:
    """
    resultados_escaneo: salida cruda de `/internal/scan` (lista de dicts
        con ticker, fuerza, indicadores_alcistas, indicadores_bajistas,
        senales, resumen_confluencia, tp, sl).
    ticker_excluir: el ticker en deterioro — nunca se sugiere rotar hacia
        sí mismo.
    """
    candidatos = [
        r
        for r in resultados_escaneo
        if "error" not in r
        and r["ticker"] != ticker_excluir
        and r.get("fuerza") in ("media", "alta")
        # Dominancia ESTRICTA, no conteo absoluto: el único llamador es un
        # diagnóstico en rojo, y proponer un destino cuya lectura dominante
        # es bajista (o un empate) convierte un aviso de riesgo en riesgo
        # nuevo. El empate excluye porque aquí se compromete capital NUEVO
        # (en salud_posicion.py, con capital ya expuesto, el empate manda
        # al lado contrario: mantiene la vigilancia).
        and r.get("indicadores_alcistas", 0) > r.get("indicadores_bajistas", 0)
    ]
    if not candidatos:
        # Sin candidatos NO se relaja ningún criterio: "sin sugerencia" es
        # una salida de primera clase del contrato. Se prefiere el silencio
        # a una sugerencia que el propio motor no sostiene.
        return None

    # `max()` devolvía el primer máximo, así que un empate lo ganaba quien
    # llegara antes en la lista — y las acciones van primero (escaner.js).
    # Orden determinista por 4 claves: las tres primeras descendentes, la
    # cuarta (ticker) ascendente para que el resultado no dependa nunca del
    # orden de entrada.
    mejor = sorted(
        candidatos,
        key=lambda r: (
            -(r.get("indicadores_alcistas", 0) - r.get("indicadores_bajistas", 0)),
            -_RANGO_FUERZA.get(r.get("fuerza"), 0),
            -_proporcion_alcista(r),
            r["ticker"],
        ),
    )[0]

    # Las 4 claves de salida son regla protegida: nada del activo de origen
    # (y mucho menos su monto invertido) puede viajar en este diccionario.
    # `tp` y `sl` son no nulos por construcción: solo entran candidatos con
    # dominancia alcista, es decir sesgo operativo "largo".
    return {
        "ticker": mejor["ticker"],
        "resumen_confluencia": mejor["resumen_confluencia"],
        "tp": mejor["tp"],
        "sl": mejor["sl"],
    }
