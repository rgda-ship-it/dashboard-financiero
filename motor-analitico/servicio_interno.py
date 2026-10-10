"""
Servicio interno FastAPI: expone el motor analítico Python a Node.js.

Solo debe ser accesible desde la red interna/localhost — nunca expuesto
directamente a internet. La autenticación por token interno es una
segunda capa de defensa, no la única.
"""

from __future__ import annotations

import math
import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

# El .env vive en la raíz del proyecto (un nivel arriba de motor-analitico/),
# no acá — a diferencia del backend Node (que carga "dotenv/config" solo),
# este servicio no cargaba ningún .env y siempre veía las variables de
# entorno vacías (por ejemplo ANALYTICS_SERVICE_INTERNAL_TOKEN), lo que
# hacía fallar la verificación de token en cada request desde Node.
load_dotenv(Path(__file__).resolve().parent.parent / ".env")

from conectores.yahoo_finance import ConectorAccionesYahoo, ErrorEsquemaInesperado
from conectores.coingecko import ConectorCriptoCoinGecko
from indicadores.tecnicos import (
    calcular_indicadores,
    evaluar_confluencia,
    calcular_niveles_operativos,
    calcular_soporte_resistencia,
    calcular_tp_sl_por_atr,
)
from riesgo.apalancamiento import calcular_apalancamiento
from riesgo.rotacion import mejor_oportunidad_del_escaneo
from riesgo.salud_posicion import (
    PosicionCargada,
    calcular_diagnostico,
    evaluar_deterioro_fundamental,
)

app = FastAPI(title="Motor Analítico — Dashboard Financiero Personal")

conector_acciones = ConectorAccionesYahoo()
conector_cripto = ConectorCriptoCoinGecko()

INTERNAL_TOKEN = os.environ.get("ANALYTICS_SERVICE_INTERNAL_TOKEN", "")
LEVERAGE_TOPE_FASE1 = float(os.environ.get("LEVERAGE_HARD_CAP_FASE1", "5"))

# Mapeo simple símbolo -> id de CoinGecko para el universo soportado.
IDS_CRIPTO = {"bitcoin": "bitcoin", "ethereum": "ethereum", "solana": "solana"}

# Caché del último escaneo general. Se usa ÚNICAMENTE para leer sugerencias
# de rotación ya calculadas por el escáner — el diagnóstico de cartera NUNCA
# dispara un cálculo nuevo a partir de la posición del usuario (regla del
# Modo Diagnóstico, checklist del Risk Manager punto #6/#7).
_ultimo_escaneo: list[dict] = []


def _verificar_token(x_internal_token: str | None) -> None:
    if not INTERNAL_TOKEN or x_internal_token != INTERNAL_TOKEN:
        raise HTTPException(status_code=401, detail="Token interno inválido.")


class SolicitudEscaneo(BaseModel):
    tickers: list[str]


class SolicitudAnalisisPosicion(BaseModel):
    ticker: str
    precio_compra: float
    # Deliberadamente NO incluye monto invertido — ver riesgo/salud_posicion.py


def _es_cripto(ticker: str) -> bool:
    return ticker.lower() in IDS_CRIPTO


def _obtener_ohlcv(ticker: str):
    """Solo precios. Separado a propósito de los fundamentales: pedirlos
    juntos obligaba a gastar una llamada de API extra por ticker incluso
    cuando el llamador solo necesitaba velas."""
    if _es_cripto(ticker):
        return conector_cripto.obtener_ohlcv(IDS_CRIPTO[ticker.lower()])
    return conector_acciones.obtener_ohlcv(ticker)


def _obtener_fundamentales(ticker: str) -> dict:
    if _es_cripto(ticker):
        return conector_cripto.obtener_fundamentales(IDS_CRIPTO[ticker.lower()])
    return conector_acciones.obtener_fundamentales(ticker)


# Decimales con los que se emiten precio y niveles: los de la base de datos
# (`numeric(20, 8)` en `senales` y `ordenes`). Hasta el 2026-10-01 se
# redondeaba a 2, y en una cripto de céntimos eso movía el stop y el
# objetivo: Cardano a 0,35 $ con el stop en 0,3349 quedaba en 0,33, y el
# R:R, el tamaño y la liquidación se calculaban sobre niveles que no eran
# los del motor. En acciones de dólares, 8 decimales no cambian nada.
DECIMALES_PRECIO = 8


def _precio(valor):
    return round(valor, DECIMALES_PRECIO)


def atr_vigente(serie_atr):
    """El ATR con el que se decide hoy.

    Normalmente el de la última fila. La excepción es la madrugada UTC en
    cripto: CoinGecko fecha cada vela de 4 h por su CIERRE, así que entre
    las 00:00 y las 04:00 el día en curso todavía no tiene ninguna vela
    cerrada, su fila no tiene máximo ni mínimo reales y su ATR es NaN. Hasta
    el 2026-09-30 eso dejaba TODAS las criptos «sin volatilidad» —y por la
    regla protegida nº4, no operables— unas cuatro horas cada noche; los
    agentes lo denunciaron en su backlog («Volatilidad de bitcoin», etc.).

    Solo se mira UN día atrás: el ATR es una media de 14 días y el de ayer
    describe la volatilidad igual de bien que el de hoy a medio hacer. Si
    faltan los dos últimos, ya no es la madrugada sino un problema de datos,
    y se devuelve NaN para que la regla nº4 degrade al mínimo.
    """
    def valido(v) -> bool:
        return v is not None and math.isfinite(float(v))

    if len(serie_atr) == 0:
        return float("nan")
    if valido(serie_atr.iloc[-1]):
        return serie_atr.iloc[-1]
    if len(serie_atr) >= 2 and valido(serie_atr.iloc[-2]):
        return serie_atr.iloc[-2]
    return float("nan")


def _obtener_ohlcv_y_fundamentales(ticker: str):
    return _obtener_ohlcv(ticker), _obtener_fundamentales(ticker)


def _direccion_confluencia(confluencia) -> str:
    """Dirección dominante de la confluencia.

    El motor ya cuenta indicadores alcistas y bajistas por separado; sin
    exponer cuál de los dos domina, el frontend tendría que deducirlo
    parseando el texto de `resumen` — frágil y atado al idioma.
    """
    if confluencia.indicadores_alcistas > confluencia.indicadores_bajistas:
        return "alcista"
    if confluencia.indicadores_bajistas > confluencia.indicadores_alcistas:
        return "bajista"
    return "neutral"


# Lectura de mercado (`direccion`) -> sesgo operativo (qué encuadra el
# sistema). Hoy coinciden 1:1, pero son conceptos distintos: `direccion`
# describe el mercado, `sesgo_operativo` describe qué está el motor
# dispuesto a dimensionar. Se desacoplarán en cuanto se habiliten cortos.
SESGO_POR_DIRECCION = {
    "alcista": "largo",
    "bajista": "corto",
    "neutral": "sin_sesgo",
}


def _num(valor):
    """Degrada NaN/inf a None.

    Un NaN se serializa como el literal `NaN`, que no es JSON válido:
    `JSON.parse()` lo rechaza y tumbaría el escáner completo en el
    frontend, no solo el ticker afectado. Con None el cliente ya sabe
    mostrar un guion.
    """
    try:
        numero = float(valor)
    except (TypeError, ValueError):
        return None
    return numero if math.isfinite(numero) else None


def _escanear_ticker(ticker: str) -> dict:
    """Escanea un único ticker. Función compartida por /internal/scan y
    por la lógica de sugerencia de rotación del diagnóstico de cartera."""
    # El escaneo es puramente técnico: no usa ni un solo campo fundamental
    # (el deterioro fundamental solo se evalúa en /internal/analyze-position).
    # Antes se llamaba a _obtener_ohlcv_y_fundamentales() y se descartaba el
    # segundo valor con `datos, _ =`, lo que DUPLICABA las llamadas a la API
    # por ticker: 6 requests a CoinGecko para escanear 3 criptos en vez de 3.
    # Eso era lo que disparaba el 429 Too Many Requests en el último ticker
    # del universo (solana), y de paso pagaba el coste de yf.Ticker().info
    # —una llamada lenta— en cada acción escaneada.
    datos = _obtener_ohlcv(ticker)
    df_indicadores = calcular_indicadores(datos.datos)
    confluencia = evaluar_confluencia(df_indicadores)

    # Todo lo que venga del proveedor entra por _num(): un NaN en Close o en
    # ATR_14 (series demasiado cortas) no puede propagarse a las comparaciones
    # ni al JSON.
    atr = _num(atr_vigente(df_indicadores["ATR_14"]))
    precio_actual = _num(df_indicadores["Close"].iloc[-1])

    # Volatilidad relativa. La guarda `if precio_actual` de antes era
    # verdadera con un precio NaN (NaN es truthy), así que atr_pct quedaba
    # NaN y, como toda comparación con NaN es falsa, el cálculo de
    # apalancamiento caía en el tramo "volatilidad baja" — el más generoso —
    # sobre un activo de volatilidad DESCONOCIDA. Aquí se emite NaN de forma
    # explícita y calcular_apalancamiento lo trata como tramo degradado.
    # Un ATR de 0 exacto (serie sin ningún recorrido) tampoco es una medida
    # de volatilidad utilizable: se trata igual que su ausencia.
    if atr is not None and atr > 0 and precio_actual:
        atr_pct = (atr / precio_actual) * 100
    else:
        atr_pct = float("nan")

    direccion = _direccion_confluencia(confluencia)
    sesgo_operativo = SESGO_POR_DIRECCION[direccion]

    leverage = calcular_apalancamiento(
        atr_pct, confluencia.fuerza, LEVERAGE_TOPE_FASE1, direccion
    )

    soporte, resistencia, niveles_origen = _niveles_tecnicos(
        df_indicadores, precio_actual, atr
    )

    # `operable` es el único booleano que la UI necesita mirar para decidir
    # si la fila lleva números operables. Los niveles entran en la condición
    # porque sin ellos no hay SL/TP que asignar, y el contrato exige que
    # leverage_recomendado, sl y tp sean nulos o no nulos los tres a la vez.
    operable = (
        leverage.recomendado is not None
        and soporte is not None
        and resistencia is not None
    )

    # Los niveles técnicos se emiten SIEMPRE y sin rol operativo. sl/tp solo
    # cuando el sistema encuadra la operación, y desde el 2026-10-10 ya no
    # son el mismo número: se anclan al soporte y la resistencia pero se
    # acotan en ATR (`calcular_niveles_operativos`), para que el stop no
    # quede dentro del ruido de una sesión ni el objetivo a semanas de
    # distancia. Con operable, el ATR es positivo: sin él no hay
    # apalancamiento recomendado.
    # No se invierten los roles en un sesgo corto: emitir un setup de corto
    # completo justo después de negarse a apalancarlo sería incoherente y,
    # sin modelo de coste de préstamo ni funding, engañoso.
    sl = tp = None
    if operable:
        sl, tp = calcular_niveles_operativos(precio_actual, soporte, resistencia, atr)
        sl, tp = _precio(sl), _precio(tp)
    return {
        "ticker": ticker,
        "precio_actual": _num(_precio(precio_actual)) if precio_actual is not None else None,
        "resumen_confluencia": confluencia.resumen,
        "fuerza": confluencia.fuerza,
        "indicadores_alcistas": confluencia.indicadores_alcistas,
        "indicadores_bajistas": confluencia.indicadores_bajistas,
        "direccion": direccion,
        "sesgo_operativo": sesgo_operativo,
        "operable": operable,
        # Las señales individuales ya están calculadas aquí dentro: exponerlas
        # cuesta cero llamadas extra y permite que la terminal muestre POR QUÉ
        # una confluencia es lo que es, en vez de solo su veredicto.
        "senales": [
            {"nombre": s.nombre, "direccion": s.direccion.value, "detalle": s.detalle}
            for s in confluencia.senales
        ],
        "atr_pct": _num(atr_pct),
        "leverage_motivo": leverage.motivo,
        # Los cuatro campos numéricos de apalancamiento y niveles pasan por
        # _num(): un NaN se serializa como el literal `NaN`, que no es JSON
        # válido y tumbaría el JSON.parse() de TODO el escáner, no solo del
        # ticker afectado.
        "leverage_tope": _num(leverage.tope),
        "leverage_recomendado": _num(leverage.recomendado) if operable else None,
        "leverage_referencia_volatilidad": _num(leverage.referencia_volatilidad),
        "sl": sl,
        "tp": tp,
        "soporte": soporte,
        "resistencia": resistencia,
        "niveles_origen": niveles_origen,
    }


def _niveles_tecnicos(
    df_indicadores, precio_actual: float | None, atr: float | None
) -> tuple[float | None, float | None, str]:
    """Soporte y resistencia del activo, con fallback por ATR.

    Devuelve `(soporte, resistencia, origen)`. Son niveles técnicos puros,
    sin rol operativo: quien decide si además son SL/TP es el llamador,
    según el sesgo operativo.

    El fallback usa `calcular_tp_sl_por_atr()`, cuya salida hay que leer
    aquí como `(nivel_inferior, nivel_superior)` y no como (sl, tp): es
    simétrica alrededor del precio, luego direccionalmente neutra, que es
    exactamente lo que soporte/resistencia necesitan. Se dispara cuando la
    ventana de 20 velas no describe estructura, es decir cuando es más
    estrecha que un ATR: eso no es un rango, es ruido.
    """
    soporte, resistencia = calcular_soporte_resistencia(df_indicadores)
    soporte = _num(soporte)
    resistencia = _num(resistencia)

    hay_estructura = (
        soporte is not None
        and resistencia is not None
        and resistencia - soporte > 0
        and (atr is None or resistencia - soporte >= atr)
    )
    if hay_estructura:
        return _precio(soporte), _precio(resistencia), "estructura"

    # Sin ATR utilizable no hay forma de construir el fallback: se devuelven
    # nulos antes que un rango inventado. El origen sigue siendo "atr"
    # porque describe la rama que se intentó, no un valor emitido.
    if atr is None or atr <= 0 or precio_actual is None:
        return None, None, "atr"

    inferior, superior = calcular_tp_sl_por_atr(precio_actual, atr, 2.0)
    return _precio(inferior), _precio(superior), "atr"


@app.post("/internal/scan")
def escanear(solicitud: SolicitudEscaneo, x_internal_token: str | None = Header(None)):
    global _ultimo_escaneo
    _verificar_token(x_internal_token)

    resultados = []
    for ticker in solicitud.tickers:
        try:
            resultados.append(_escanear_ticker(ticker))
        except (ErrorEsquemaInesperado, ValueError) as exc:
            resultados.append({"ticker": ticker, "error": str(exc)})
        except Exception as exc:  # fallo de red/proveedor puntual
            resultados.append({"ticker": ticker, "error": f"fallo de datos: {exc}"})

    # Se guarda solo el resultado del escaneo general — nunca se recalcula
    # nada aquí en función de una cartera de usuario.
    _ultimo_escaneo = resultados
    return resultados





@app.post("/internal/analyze-position")
def analizar_posicion(
    solicitud: SolicitudAnalisisPosicion, x_internal_token: str | None = Header(None)
):
    _verificar_token(x_internal_token)

    try:
        datos, fundamentales_actuales = _obtener_ohlcv_y_fundamentales(solicitud.ticker)
        df_indicadores = calcular_indicadores(datos.datos)
        confluencia = evaluar_confluencia(df_indicadores)
        precio_actual = float(df_indicadores["Close"].iloc[-1])

        deterioro_fundamental = evaluar_deterioro_fundamental(
            fundamentales_actuales, fundamentales_en_compra=None
        )

        # Nota: PosicionCargada requiere monto_invertido en el dataclass,
        # pero aquí se pasa 0 porque este endpoint interno nunca lo usa
        # para nada más que el cálculo de PnL — y ese cálculo lo hace
        # Node.js localmente con el monto real, no este servicio.
        posicion = PosicionCargada(
            ticker=solicitud.ticker,
            precio_compra=solicitud.precio_compra,
            monto_invertido=0,
        )
        diagnostico = calcular_diagnostico(
            posicion, precio_actual, confluencia, deterioro_fundamental
        )

        sugerencia_rotacion = None
        if diagnostico.nivel_salud.value == "rojo":
            # Solo se consulta el caché del último escaneo general — el
            # ticker en deterioro y su monto invertido NUNCA participan
            # en este cálculo (regla del Modo Diagnóstico).
            sugerencia_rotacion = mejor_oportunidad_del_escaneo(
                _ultimo_escaneo, ticker_excluir=solicitud.ticker
            )

        return {
            "precio_actual": _precio(precio_actual),
            "nivel_salud": diagnostico.nivel_salud.value,
            "mensaje": diagnostico.mensaje,
            "sugerencia_rotacion": sugerencia_rotacion,
        }
    except (ErrorEsquemaInesperado, ValueError) as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Fallo de datos: {exc}")
