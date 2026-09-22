"""
Adaptador de salida del motor analítico: lo que antes devolvía FastAPI,
ahora se escribe en PostgreSQL.

Este módulo NO contiene lógica de análisis. Si aparece aquí un cálculo de
indicador, de apalancamiento o de nivel técnico, está en el fichero
equivocado — la regla de ubicación del README es explícita: la lógica de
análisis vive en `indicadores/` y `riesgo/`.

Se habla con PostgREST usando `requests`, que YA es una dependencia del
motor (requirements.txt). Se descartó el SDK oficial de Supabase a
propósito: añadir una dependencia nueva al entorno donde corren los 69
tests de la Fase 1 es un riesgo gratuito, y aquí solo hacen falta cuatro
verbos HTTP.

El cambio de fondo respecto a la Fase 1 es de dirección: el motor deja de
RESPONDER a peticiones y pasa a ESCRIBIR. El circuit breaker en memoria
de backend/src/services/circuitBreaker.js ya no hace falta, porque el
"último dato válido" no es una variable de un proceso vivo: es la propia
tabla `senales` con su `calculado_en`.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from datetime import datetime, timezone

import pandas as pd
import requests

TIEMPO_ESPERA_SEG = 30


class ErrorEscritura(RuntimeError):
    """Fallo al escribir en Supabase. Nunca se silencia: si el ETL no
    puede escribir, terminar en verde sería mentir."""


def _num(valor):
    """Degrada NaN/inf a None.

    Misma función y mismo motivo que `_num` en servicio_interno.py: un NaN
    se serializa como el literal `NaN`, que no es JSON válido. Allí
    tumbaba el `JSON.parse()` del escáner entero; aquí haría que PostgREST
    rechazara el lote completo, no solo la fila afectada.
    """
    if valor is None:
        return None
    try:
        numero = float(valor)
    except (TypeError, ValueError):
        return None
    return numero if math.isfinite(numero) else None


@dataclass
class ClienteSupabase:
    """Cliente mínimo de PostgREST con la clave de servicio.

    ADVERTENCIA: `clave_servicio` ELUDE ROW LEVEL SECURITY por diseño.
    Solo debe existir en los secretos de GitHub Actions y en los de las
    Edge Functions. Nunca en el frontend, nunca en un fichero versionado.
    """

    url: str
    clave_servicio: str

    @classmethod
    def desde_entorno(cls) -> "ClienteSupabase":
        url = os.environ.get("SUPABASE_URL", "").rstrip("/")
        clave = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
        if not url or not clave:
            raise ErrorEscritura(
                "Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY. En local van "
                "en el .env de la raíz; en CI, en los secretos del repositorio."
            )
        return cls(url=url, clave_servicio=clave)

    # ── Plomería ────────────────────────────────────────────────────────
    @property
    def _base(self) -> str:
        return f"{self.url}/rest/v1"

    def _cabeceras(self, extra: dict | None = None) -> dict:
        cabeceras = {
            "apikey": self.clave_servicio,
            "Authorization": f"Bearer {self.clave_servicio}",
            "Content-Type": "application/json",
        }
        if extra:
            cabeceras.update(extra)
        return cabeceras

    def _comprobar(self, respuesta: requests.Response, descripcion: str):
        if respuesta.status_code >= 400:
            # El cuerpo de error de PostgREST es informativo y NO contiene
            # la clave, así que se propaga entero: el mensaje "violates
            # check constraint senales_contrato_operable" es exactamente
            # lo que un dev necesita leer.
            raise ErrorEscritura(
                f"{descripcion}: {respuesta.status_code} {respuesta.text[:600]}"
            )
        if not respuesta.content:
            return None
        try:
            return respuesta.json()
        except ValueError:
            return None

    # ── Verbos ──────────────────────────────────────────────────────────
    def seleccionar(self, tabla: str, params: dict | None = None) -> list[dict]:
        resp = requests.get(
            f"{self._base}/{tabla}",
            headers=self._cabeceras(),
            params=params or {},
            timeout=TIEMPO_ESPERA_SEG,
        )
        return self._comprobar(resp, f"SELECT {tabla}") or []

    def insertar(self, tabla: str, filas: list[dict]) -> None:
        if not filas:
            return
        resp = requests.post(
            f"{self._base}/{tabla}",
            headers=self._cabeceras({"Prefer": "return=minimal"}),
            json=filas,
            timeout=TIEMPO_ESPERA_SEG,
        )
        self._comprobar(resp, f"INSERT {tabla} ({len(filas)} filas)")

    def upsert(self, tabla: str, filas: list[dict], claves: str) -> None:
        """UPSERT en lote. `claves` son las columnas del ON CONFLICT.

        En lote y no fila a fila porque una pasada de ETL con 2 años de
        velas son ~500 filas por activo: 500 peticiones HTTP por ticker
        agotarían el tiempo del job antes que la cuota de nadie.
        """
        if not filas:
            return
        resp = requests.post(
            f"{self._base}/{tabla}",
            headers=self._cabeceras(
                {"Prefer": "resolution=merge-duplicates,return=minimal"}
            ),
            params={"on_conflict": claves},
            json=filas,
            timeout=TIEMPO_ESPERA_SEG * 3,
        )
        self._comprobar(resp, f"UPSERT {tabla} ({len(filas)} filas)")

    def actualizar(self, tabla: str, filtro: dict, cambios: dict) -> None:
        resp = requests.patch(
            f"{self._base}/{tabla}",
            headers=self._cabeceras({"Prefer": "return=minimal"}),
            params=filtro,
            json=cambios,
            timeout=TIEMPO_ESPERA_SEG,
        )
        self._comprobar(resp, f"UPDATE {tabla}")

    def rpc(self, funcion: str, argumentos: dict | None = None):
        """Llama a una función de PostgreSQL expuesta por PostgREST.

        Las del workflow de altas (`fn_tomar_solicitudes`,
        `fn_resolver_alta`) solo las puede ejecutar service_role: la
        invariante I23 impide que `authenticated` las alcance.
        """
        resp = requests.post(
            f"{self._base}/rpc/{funcion}",
            headers=self._cabeceras(),
            json=argumentos or {},
            timeout=TIEMPO_ESPERA_SEG,
        )
        return self._comprobar(resp, f"RPC {funcion}")


# ── Traductores: objetos del motor -> filas de PostgreSQL ──────────────

def filas_precios(activo_id: int, datos, fuente: str) -> list[dict]:
    """Convierte el DataFrame de un conector en filas de `precios_diarios`.

    AQUÍ VIVE LA DECISIÓN MÁS DELICADA DEL ETL: el valor de `rango_real`.

    Los dos conectores devuelven el mismo contrato (índice diario,
    columnas Open/High/Low/Close/Volume), pero con una asimetría
    deliberada que el conector de CoinGecko documenta en
    `construir_velas_diarias`: las filas fuera del alcance de la llamada a
    /ohlc llevan High y Low en NaN. No es un hueco de datos, es una
    afirmación: de ese día se conoce el cierre y el volumen, pero NO el
    recorrido intradía. Rellenarlos con el cierre daría rango cero y
    hundiría el ATR, que es la medida que sostiene la regla de
    apalancamiento.

    Por eso `rango_real` NO se deduce del proveedor sino de si esa fila
    concreta tiene máximo y mínimo. Una cripto tiene, en la misma tabla,
    ~30 filas con rango real y cientos sin él.
    """
    marco: pd.DataFrame = datos.datos
    filas: list[dict] = []

    for indice, vela in marco.iterrows():
        maximo = _num(vela.get("High"))
        minimo = _num(vela.get("Low"))
        cierre = _num(vela.get("Close"))

        # Sin cierre no hay vela: es la única columna que todos los
        # indicadores leen y la tabla la declara NOT NULL.
        if cierre is None:
            continue

        rango_real = maximo is not None and minimo is not None

        if fuente == "yfinance":
            origen = "yahoo"
        else:
            origen = "coingecko_ohlc" if rango_real else "coingecko_market_chart"

        filas.append(
            {
                "activo_id": activo_id,
                "fecha": pd.Timestamp(indice).date().isoformat(),
                "apertura": _num(vela.get("Open")),
                "maximo": maximo,
                "minimo": minimo,
                "cierre": cierre,
                "volumen": _num(vela.get("Volume")),
                "rango_real": rango_real,
                "origen": origen,
            }
        )

    return filas


def fila_indicadores(activo_id: int, df_indicadores, version_motor: str) -> dict | None:
    """Última fila calculada de indicadores, para la caché diaria."""
    if df_indicadores is None or df_indicadores.empty:
        return None

    ultima = df_indicadores.iloc[-1]

    def col(nombre):
        return _num(ultima.get(nombre)) if nombre in df_indicadores.columns else None

    def col_por_prefijo(prefijo):
        """Las columnas del MACD llevan los periodos en el nombre
        (MACD_12_26_9, MACDh_12_26_9, MACDs_12_26_9) y ese sufijo depende
        de los parámetros con que pandas-ta las genere. `tecnicos.py` ya
        las busca por prefijo en `evaluar_confluencia` por ese mismo
        motivo; aquí se hace igual para no acoplar la escritura a unos
        periodos concretos.

        El prefijo se compara de forma EXACTA hasta el guion bajo, porque
        "MACD_" también sería prefijo de "MACDh_" si se comparara sin él.
        """
        for nombre in df_indicadores.columns:
            if nombre.startswith(prefijo):
                return _num(ultima.get(nombre))
        return None

    return {
        "activo_id": activo_id,
        "fecha": pd.Timestamp(df_indicadores.index[-1]).date().isoformat(),
        "sma_50": col("SMA_50"),
        "sma_200": col("SMA_200"),
        "rsi_14": col("RSI_14"),
        "macd": col_por_prefijo("MACD_"),
        "macd_signal": col_por_prefijo("MACDs_"),
        "macd_hist": col_por_prefijo("MACDh_"),
        "atr_14": col("ATR_14"),
        "version_motor": version_motor,
    }


def fila_senal(activo_id: int, escaneo: dict, version_motor: str) -> dict:
    """Traduce el payload de `_escanear_ticker()` a una fila de `senales`.

    Correspondencia 1:1 con el contrato que verifica
    tests/test_contrato_scan.py. No se renombra ni se reinterpreta ningún
    campo: `operable`, `leverage_recomendado`, `sl` y `tp` llegan tal cual
    y el CHECK `senales_contrato_operable` de la base de datos vuelve a
    comprobar entre ellos la misma invariante que el test comprueba en
    Python. Dos redes independientes sobre la misma regla.
    """
    operable = bool(escaneo.get("operable"))

    return {
        "activo_id": activo_id,
        "calculado_en": datetime.now(timezone.utc).isoformat(),
        "precio_actual": _num(escaneo.get("precio_actual")),
        "direccion": escaneo.get("direccion"),
        "sesgo_operativo": escaneo.get("sesgo_operativo"),
        "fuerza": escaneo.get("fuerza"),
        "indicadores_alcistas": int(escaneo.get("indicadores_alcistas") or 0),
        "indicadores_bajistas": int(escaneo.get("indicadores_bajistas") or 0),
        "resumen_confluencia": escaneo.get("resumen_confluencia"),
        "senales_detalle": escaneo.get("senales"),
        "operable": operable,
        "atr_pct": _num(escaneo.get("atr_pct")),
        "leverage_tope": _num(escaneo.get("leverage_tope")),
        # Los tres campos del contrato: nulos o no nulos LOS TRES a la vez.
        # No se fuerza nada aquí; se copia lo que el motor decidió, que ya
        # cumple la invariante.
        "leverage_recomendado": _num(escaneo.get("leverage_recomendado")) if operable else None,
        "sl": _num(escaneo.get("sl")) if operable else None,
        "tp": _num(escaneo.get("tp")) if operable else None,
        "leverage_referencia_volatilidad": _num(escaneo.get("leverage_referencia_volatilidad")),
        "leverage_motivo": escaneo.get("leverage_motivo"),
        # Niveles técnicos: SIEMPRE se emiten, sin rol operativo.
        "soporte": _num(escaneo.get("soporte")),
        "resistencia": _num(escaneo.get("resistencia")),
        "niveles_origen": escaneo.get("niveles_origen"),
        "version_motor": version_motor,
    }
