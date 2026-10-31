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


# Financiación de un corto, % anual sobre el nominal, por día natural.
# SUPUESTO PESIMISTA, no la tarifa de QuantFury (no está publicada en el
# proyecto): acciones, tipo de interés más un margen de broker y el coste
# del préstamo del título; cripto, la financiación de los perpetuos, que en
# mercados bajistas suelen pagar los cortos. Se puede cambiar con
# `--financiacion` en el laboratorio.
FINANCIACION_CORTO_PCT = {"accion": 8.0, "cripto": 15.0}


def financiacion_de(clase: str) -> float:
    return FINANCIACION_CORTO_PCT.get(clase, 0.0)


def con_spread(df: pd.DataFrame, simbolo: str, clase: str) -> pd.DataFrame:
    """Añade SPREAD: el spread completo en $ al cierre de cada día, para las
    estrategias que filtran por él (`objetivo_min_spread`)."""
    df = df.copy()
    df["SPREAD"] = df["Close"].map(spread_de(simbolo, clase))
    return df


def con_mercado(df: pd.DataFrame, mercado: pd.DataFrame) -> pd.DataFrame:
    """Añade lo que hizo el mercado (doc fase-3/09 §4.1; en cripto, bitcoin)
    cada día: MERCADO_RET, su variación del cierre en %, y MERCADO_PEOR_2, la
    peor de ese día y el anterior. Un día sin dato del mercado queda en NaN
    y los filtros de choque no lo bloquean."""
    df = df.copy()
    ret = mercado["Close"].pct_change() * 100
    df["MERCADO_RET"] = ret.reindex(df.index)
    df["MERCADO_PEOR_2"] = ret.rolling(2).min().reindex(df.index)
    return df


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


# Criptos del top de capitalización de octubre de 2021 que NO están en el
# universo: un grupo elegido con la información de entonces, con las que
# luego se hundieron o desaparecieron (Terra, FTX…). Sirve para medir el
# sesgo de supervivencia de un universo elegido hoy (robustez.py).
CRIPTO_TOP_2021 = (
    "SHIB-USD", "LUNA1-USD", "LUNC-USD", "UNI7083-USD", "ALGO-USD", "MATIC-USD",
    "XLM-USD", "AXS-USD", "ATOM-USD", "VET-USD", "ICP-USD", "FIL-USD",
    "ETC-USD", "FTT-USD", "THETA-USD", "XTZ-USD", "EGLD-USD", "HBAR-USD",
    "MANA-USD", "SAND-USD", "EOS-USD", "AAVE-USD", "CRO-USD", "NEAR-USD", "KSM-USD",
)


# Universo amplio para medir la AMPLITUD de una estrategia de acciones
# (doc 06 §3.9): el S&P 100, con su sector. Ojo: es la composición de hoy,
# así que el sesgo de supervivencia sigue ahí; lo que mide es si la
# ventaja aparece en muchos valores y sectores o solo en unos pocos.
SP100_SECTOR = {
    **{t: "Tecnología" for t in "AAPL ACN ADBE AMD AVGO CRM CSCO IBM INTC INTU MSFT NOW NVDA ORCL PLTR QCOM TXN".split()},
    **{t: "Comunicación" for t in "CHTR CMCSA DIS GOOGL META NFLX T TMUS VZ".split()},
    **{t: "Consumo cíclico" for t in "AMZN BKNG F GM HD LOW MCD NKE SBUX TGT TSLA".split()},
    **{t: "Consumo defensivo" for t in "CL COST KO MDLZ MO PEP PG PM WMT".split()},
    **{t: "Salud" for t in "ABBV ABT AMGN BMY CVS DHR GILD ISRG JNJ LLY MDT MRK PFE TMO UNH".split()},
    **{t: "Financiero" for t in "AIG AXP BAC BK BLK BRK-B C COF GS JPM MA MET MS PYPL SCHW USB V WFC".split()},
    **{t: "Industrial" for t in "BA CAT DE EMR FDX GD GE HON LMT MMM RTX UBER UNP UPS".split()},
    **{t: "Energía" for t in "COP CVX XOM".split()},
    **{t: "Servicios públicos" for t in "DUK NEE SO".split()},
    **{t: "Inmobiliario" for t in "AMT SPG".split()},
    **{t: "Materiales" for t in "LIN".split()},
}


# Universo SIN sesgo de supervivencia para las estrategias cruzadas (doc
# 06 §3.11): los 9 ETF de sectores de SPDR (desde 1998) y 10 ETF de países
# de iShares (desde 1996–2000). Se pueden elegir con la información de
# 2000: ninguno está aquí por haber subido después. Cubre 2000–2002 y 2008.
ETF_GRUPO = {
    **{t: "Sector EE. UU." for t in "XLB XLE XLF XLI XLK XLP XLU XLV XLY".split()},
    **{t: "País" for t in "EWJ EWG EWU EWC EWA EWZ EWY EWT EWH EWW".split()},
}

UNIVERSOS = ("activo", "sp100", "etf")


def universo_nombrado(nombre: str) -> tuple[list[tuple[str, str]], dict[str, str]]:
    """(activos, sector por símbolo) de un universo con nombre."""
    if nombre == "sp100":
        return [(t, "accion") for t in SP100_SECTOR], dict(SP100_SECTOR)
    if nombre == "etf":
        return [(t, "accion") for t in ETF_GRUPO], dict(ETF_GRUPO)
    return universo(), {}


def ticker_yahoo(simbolo: str, clase: str) -> str | None:
    if clase == "accion" or simbolo.endswith("-USD"):
        return simbolo
    return CRIPTO_YAHOO.get(simbolo)


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
