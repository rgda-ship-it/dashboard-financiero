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

import numpy as np
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


def cargar_resultados(simbolo: str) -> pd.DatetimeIndex | None:
    """Días en que el precio de una acción reacciona a sus resultados (doc
    fase-3/09 §4.2), de Yahoo: el mismo día si los publica antes del
    mediodía de Nueva York; el siguiente si los publica después del cierre.
    Las fechas se anuncian semanas antes, así que usar la próxima no mira
    el futuro. None si Yahoo no las da (ETF, cripto)."""
    import yfinance as yf

    try:
        fechas = yf.Ticker(simbolo).get_earnings_dates(limit=100)
    except Exception as exc:  # noqa: BLE001
        print(f"  [datos] resultados de {simbolo}: {exc}")
        return None
    if fechas is None or fechas.empty:
        return None
    hora = fechas.index.tz_convert("America/New_York")
    dias = hora.tz_localize(None).normalize() + pd.to_timedelta((hora.hour >= 12).astype(int), unit="D")
    return pd.DatetimeIndex(sorted(set(dias)))


def con_resultados(df: pd.DataFrame, reaccion: pd.DatetimeIndex | None) -> pd.DataFrame:
    """Añade SESIONES_A_RESULTADOS: cuántas sesiones faltan desde cada día
    hasta la primera que reacciona a unos resultados posteriores (1 = la
    sesión siguiente, la de la entrada). NaN si no hay ninguna conocida."""
    df = df.copy()
    sesiones = np.full(len(df), np.nan)
    if reaccion is not None and len(reaccion):
        # Posición de la primera sesión en o tras cada día de reacción.
        posiciones = np.unique(df.index.searchsorted(reaccion))
        posiciones = posiciones[posiciones < len(df)]
        siguiente = np.searchsorted(posiciones, np.arange(len(df)), side="right")
        validas = siguiente < len(posiciones)
        sesiones[validas] = posiciones[siguiente[validas]] - np.arange(len(df))[validas]
    df["SESIONES_A_RESULTADOS"] = sesiones
    return df


# Fundamentales de SEC EDGAR (doc fase-3/09 §4.2): los datos XBRL de cada
# informe con la fecha en que se presentó, para usar cada día solo lo que se
# sabía entonces. La SEC pide un User-Agent con un correo de contacto; se lee
# de SEC_USER_AGENT para que no quede en el repo.
EDGAR_TICKERS = "https://www.sec.gov/files/company_tickers.json"
EDGAR_HECHOS = "https://data.sec.gov/api/xbrl/companyfacts/CIK{:010d}.json"
# Conceptos de us-gaap por orden de preferencia.
CONCEPTOS_BENEFICIO = ("NetIncomeLoss", "ProfitLoss", "NetIncomeLossAvailableToCommonStockholdersBasic")
CONCEPTOS_PATRIMONIO = ("StockholdersEquity",
                        "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest")


def _edgar_json(url: str):
    import json
    import urllib.request

    agente = os.environ.get("SEC_USER_AGENT")
    if not agente:
        raise RuntimeError("Falta SEC_USER_AGENT (p. ej. «dashboard-financiero correo@ejemplo.com»)")
    peticion = urllib.request.Request(url, headers={"User-Agent": agente, "Accept-Encoding": "identity"})
    with urllib.request.urlopen(peticion, timeout=60) as r:
        return json.loads(r.read())


def ciks_edgar() -> dict[str, int]:
    """Ticker → CIK de la SEC (BRK-B se escribe igual que en Yahoo)."""
    return {f["ticker"]: int(f["cik_str"]) for f in _edgar_json(EDGAR_TICKERS).values()}


def cargar_hechos_edgar(simbolo: str, ciks: dict[str, int]) -> dict | None:
    """Los hechos XBRL de una empresa, o None si no presenta en la SEC."""
    import time

    if simbolo not in ciks:
        return None
    time.sleep(0.15)  # la SEC admite 10 peticiones por segundo
    try:
        return _edgar_json(EDGAR_HECHOS.format(ciks[simbolo]))
    except Exception as exc:  # noqa: BLE001
        print(f"  [datos] EDGAR de {simbolo}: {exc}")
        return None


def _hechos(hechos: dict, taxonomia: str, conceptos: tuple[str, ...], unidad: str) -> pd.DataFrame:
    """Los valores del primer concepto que exista, cada periodo con el valor
    de la PRIMERA vez que se presentó (lo que se sabía entonces; las
    reexpresiones posteriores mirarían el futuro). Conocido = el día
    siguiente a la presentación."""
    for c in conceptos:
        filas = hechos.get("facts", {}).get(taxonomia, {}).get(c, {}).get("units", {}).get(unidad)
        if filas:
            df = pd.DataFrame(filas)
            df["end"] = pd.to_datetime(df["end"])
            df["start"] = pd.to_datetime(df["start"]) if "start" in df else pd.NaT
            df["conocido"] = pd.to_datetime(df["filed"]) + pd.Timedelta(days=1)
            # Varias clases de acciones en la misma presentación se suman.
            df = df.groupby(["start", "end", "conocido"], dropna=False, as_index=False)["val"].sum()
            return df.sort_values("conocido").drop_duplicates(["start", "end"]).reset_index(drop=True)
    return pd.DataFrame(columns=["start", "end", "conocido", "val"])


def _trimestres(flujo: pd.DataFrame) -> pd.DataFrame:
    """Trimestres (≈ 90 días) de un concepto de flujo. El cuarto, que los
    10-K no dan suelto, sale del anual menos los tres anteriores."""
    dias = (flujo["end"] - flujo["start"]).dt.days
    q = flujo[dias.between(80, 100)][["start", "end", "conocido", "val"]]
    for _, a in flujo[dias.between(350, 380)].iterrows():
        if (q["end"] == a["end"]).any():
            continue
        previos = q[(q["start"] >= a["start"] - pd.Timedelta(days=10)) & (q["end"] < a["end"])]
        if len(previos) == 3:
            q = pd.concat([q, pd.DataFrame([{
                "start": previos["end"].max(), "end": a["end"],
                "conocido": max(a["conocido"], previos["conocido"].max()),
                "val": a["val"] - previos["val"].sum()}])], ignore_index=True)
    return q.sort_values("end").reset_index(drop=True)


def _a_lo_conocido(sucesos: pd.DataFrame, nombre: str) -> pd.Series:
    """Serie por día de conocimiento con el valor del periodo más reciente
    conocido hasta entonces (un dato tardío de un periodo viejo no pisa
    uno nuevo)."""
    if sucesos.empty:
        return pd.Series(dtype=float, name=nombre)
    s = sucesos.sort_values(["conocido", "end"])
    previo = s["end"].cummax().shift(1)
    s = s[previo.isna() | (s["end"] > previo)]
    return s.groupby("conocido")["val"].last().rename(nombre)


def fundamentales_edgar(hechos: dict | None) -> pd.DataFrame | None:
    """Por día de conocimiento: BENEFICIO_12M (los últimos cuatro trimestres
    seguidos), ACTIVOS, PASIVOS, PATRIMONIO, ACCIONES y ACCIONES_FIN (la
    fecha del recuento, para ajustar desdoblamientos posteriores). None si no
    hay datos de us-gaap (empresas extranjeras con IFRS)."""
    if not hechos or "us-gaap" not in hechos.get("facts", {}):
        return None
    q = _trimestres(_hechos(hechos, "us-gaap", CONCEPTOS_BENEFICIO, "USD"))
    doce = []
    for i in range(3, len(q)):
        cuatro = q.iloc[i - 3:i + 1]
        if 250 <= (cuatro["end"].iloc[-1] - cuatro["end"].iloc[0]).days <= 300:
            doce.append({"end": cuatro["end"].iloc[-1], "conocido": cuatro["conocido"].max(),
                         "val": cuatro["val"].sum()})
    activos = _hechos(hechos, "us-gaap", ("Assets",), "USD")
    patrimonio = _hechos(hechos, "us-gaap", CONCEPTOS_PATRIMONIO, "USD")
    pasivos = _hechos(hechos, "us-gaap", ("Liabilities",), "USD")
    if pasivos.empty:
        # Muchos bancos no dan el pasivo total: pasivo + patrimonio − patrimonio.
        total = _hechos(hechos, "us-gaap", ("LiabilitiesAndStockholdersEquity",), "USD")
        pasivos = total.merge(patrimonio[["end", "val"]], on="end", suffixes=("", "_p"))
        pasivos["val"] = pasivos["val"] - pasivos["val_p"]
    acciones = _hechos(hechos, "dei", ("EntityCommonStockSharesOutstanding",), "shares")
    series = [
        _a_lo_conocido(pd.DataFrame(doce, columns=["end", "conocido", "val"]), "BENEFICIO_12M"),
        _a_lo_conocido(activos, "ACTIVOS"),
        _a_lo_conocido(pasivos, "PASIVOS"),
        _a_lo_conocido(patrimonio, "PATRIMONIO"),
        _a_lo_conocido(acciones, "ACCIONES"),
        _a_lo_conocido(acciones.assign(val=acciones["end"]), "ACCIONES_FIN"),
    ]
    out = pd.concat(series, axis=1).sort_index().ffill()
    return None if out.empty else out


def con_fundamentales(df: pd.DataFrame, fund: pd.DataFrame | None, cierre: pd.Series | None = None,
                      splits: pd.Series | None = None) -> pd.DataFrame:
    """Añade, en %, ROA (beneficio de 12 meses / activos), ROE (/ patrimonio,
    si es positivo), DEUDA (pasivos / activos) y BENEFICIO_PRECIO (beneficio
    / capitalización), con lo conocido cada día. `cierre` es el precio sin
    ajustar por dividendos (por defecto Close) y `splits` los desdoblamientos
    de Yahoo: las acciones de cada informe se llevan a la base de hoy, que es
    la del precio. NaN donde no hay datos."""
    df = df.copy()
    cols = ("ROA", "ROE", "DEUDA", "BENEFICIO_PRECIO")
    if fund is None or fund.empty:
        for c in cols:
            df[c] = np.nan
        return df
    f = fund.reindex(fund.index.union(df.index)).ffill().reindex(df.index)
    with np.errstate(divide="ignore", invalid="ignore"):
        df["ROA"] = 100 * f["BENEFICIO_12M"] / f["ACTIVOS"]
        df["ROE"] = (100 * f["BENEFICIO_12M"] / f["PATRIMONIO"]).where(f["PATRIMONIO"] > 0)
        df["DEUDA"] = 100 * f["PASIVOS"] / f["ACTIVOS"]
        factor = pd.Series(1.0, index=df.index)
        if splits is not None and len(splits):
            s = splits[splits > 0].copy()
            s.index = pd.to_datetime(s.index).tz_localize(None) if getattr(s.index, "tz", None) else pd.to_datetime(s.index)
            fin = pd.to_datetime(f["ACCIONES_FIN"])
            factor = fin.map(lambda d: float(s[s.index > d].prod()) if pd.notna(d) else np.nan)
        precio = (df["Close"] if cierre is None else cierre.reindex(df.index))
        df["BENEFICIO_PRECIO"] = 100 * f["BENEFICIO_12M"] / (precio * f["ACCIONES"] * factor)
        # Un valor absurdo es un recuento de acciones en otra base (BRK-B lo
        # da en equivalentes de clase A): mejor sin dato que un dato falso.
        df["BENEFICIO_PRECIO"] = df["BENEFICIO_PRECIO"].where(df["BENEFICIO_PRECIO"].abs() <= 50)
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
