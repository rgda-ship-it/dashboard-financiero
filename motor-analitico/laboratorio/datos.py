"""
Datos del laboratorio: velas diarias de Yahoo para acciones y cripto, y el
universo (doc 06 §3.2).

La cripto también viene de Yahoo (`BTC-USD`…) porque trae máximo y mínimo
de todo el histórico; CoinGecko gratis solo los da para 30 días.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pandas as pd

RAIZ = Path(__file__).resolve().parents[2]

# Id de CoinGecko → ticker de Yahoo.
CRIPTO_YAHOO = {
    "bitcoin": "BTC-USD", "ethereum": "ETH-USD", "solana": "SOL-USD",
    "binancecoin": "BNB-USD", "ripple": "XRP-USD", "cardano": "ADA-USD",
    "dogecoin": "DOGE-USD", "zcash": "ZEC-USD", "litecoin": "LTC-USD",
    "chainlink": "LINK-USD", "avalanche-2": "AVAX-USD", "polkadot": "DOT-USD",
    "tron": "TRX-USD", "bitcoin-cash": "BCH-USD",
}

# Spread de la 0034 (escenario pesimista de QuantFury).
SPREAD_ACCION_ABS = 0.03
SPREAD_CRIPTO_PCT = 0.10
SPREAD_CRIPTO_ABS = {"bitcoin": 5.0, "ethereum": 0.10}


def spread_de(simbolo: str, clase: str):
    """Función precio → spread completo en $ para un activo."""
    if clase == "accion":
        return lambda precio: SPREAD_ACCION_ABS
    if simbolo in SPREAD_CRIPTO_ABS:
        fijo = SPREAD_CRIPTO_ABS[simbolo]
        return lambda precio: fijo
    return lambda precio: precio * SPREAD_CRIPTO_PCT / 100


def universo() -> list[tuple[str, str]]:
    """[(simbolo, clase)] del catálogo activo de producción si hay acceso a
    la base de datos; si no, la semilla de la 0003 más las criptos de la 0032."""
    if os.environ.get("SUPABASE_URL") and os.environ.get("SUPABASE_SERVICE_ROLE_KEY"):
        from escritor_supabase import ClienteSupabase
        filas = ClienteSupabase.desde_entorno().seleccionar(
            "activos", {"select": "simbolo,clase", "estado": "eq.activo", "order": "clase,simbolo"})
        return [(f["simbolo"], f["clase"]) for f in filas]

    semilla = (RAIZ / "supabase" / "migrations" / "0003_semilla_universo_fase1.sql").read_text(encoding="utf-8")
    acciones = re.findall(r"\('([A-Z.\-]+)',\s*'accion',\s*'yahoo'", semilla)
    return [(s, "accion") for s in acciones] + [(c, "cripto") for c in CRIPTO_YAHOO]


def ticker_yahoo(simbolo: str, clase: str) -> str | None:
    return simbolo if clase == "accion" else CRIPTO_YAHOO.get(simbolo)


def cargar(simbolo: str, clase: str, periodo: str = "5y") -> pd.DataFrame | None:
    """Velas diarias OHLCV, o None si Yahoo no las da."""
    import yfinance as yf

    ticker = ticker_yahoo(simbolo, clase)
    if ticker is None:
        return None
    try:
        df = yf.Ticker(ticker).history(period=periodo, interval="1d", auto_adjust=True)
    except Exception as exc:  # noqa: BLE001
        print(f"  [datos] {simbolo}: {exc}")
        return None
    if df is None or df.empty or not {"Open", "High", "Low", "Close"} <= set(df.columns):
        return None
    df = df[["Open", "High", "Low", "Close", "Volume"]].dropna(subset=["Open", "High", "Low", "Close"])
    df.index = pd.to_datetime(df.index).tz_localize(None)
    return df
