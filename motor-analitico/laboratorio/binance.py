"""
Ficheros públicos de Binance (`data.binance.vision`) para el laboratorio
(doc fase-3/13 §5.2; doc fase-3/15). Sin clave y sin el API en vivo: son
zips estáticos que se descargan desde cualquier sitio.

- `velas(simbolo)`: velas de 1 hora del contado (USDT), con el volumen que
  compraron los agresores (`Taker`), desde que cotiza el par (2017–2020).
  Un zip por mes.
- `libro(simbolo)`: la profundidad del libro del futuro perpetuo
  (`bookDepth`), una foto cada ~30 s con lo acumulado a ±1…5 % del precio,
  resumida por horas. Desde el 2023-01-01. Un zip por día (~0,5 MB), así
  que se resume al descargar y solo se guarda el resumen.

Las horas quedan en UTC, sin zona, con la hora de APERTURA de la vela.
"""

from __future__ import annotations

import io
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import numpy as np
import pandas as pd

from laboratorio.datos import CRIPTO_YAHOO

BASE = "https://data.binance.vision/data"
AGENTE = "dashboard-financiero-laboratorio"
BANDAS = (1, 5)


def par(simbolo: str) -> str | None:
    """«bitcoin» → «BTCUSDT»."""
    t = CRIPTO_YAHOO.get(simbolo)
    return None if t is None else t.removesuffix("-USD") + "USDT"


def _bajar(url: str) -> bytes | None:
    try:
        with urlopen(Request(url, headers={"User-Agent": AGENTE}), timeout=60) as r:
            return r.read()
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def _csv_de_zip(contenido: bytes) -> pd.DataFrame:
    with zipfile.ZipFile(io.BytesIO(contenido)) as z:
        with z.open(z.namelist()[0]) as f:
            return pd.read_csv(f, header=None)


def leer_velas(crudo: pd.DataFrame) -> pd.DataFrame:
    """Las columnas del csv de velas de Binance → Open…Volume y Taker. Desde
    2025 el contado da los tiempos en microsegundos; antes, en milisegundos.
    Algunos ficheros traen cabecera."""
    crudo = crudo[pd.to_numeric(crudo[0], errors="coerce").notna()].astype(float)
    t = crudo[0].to_numpy()
    t = np.where(t > 1e14, t / 1000, t)
    df = pd.DataFrame({"Open": crudo[1].to_numpy(), "High": crudo[2].to_numpy(), "Low": crudo[3].to_numpy(),
                       "Close": crudo[4].to_numpy(), "Volume": crudo[5].to_numpy(), "Taker": crudo[9].to_numpy()},
                      index=pd.to_datetime(t, unit="ms"))
    return df[~df.index.duplicated()].sort_index()


def resumir_libro(crudo: pd.DataFrame, bandas=BANDAS) -> pd.DataFrame:
    """Un csv de `bookDepth` (timestamp, percentage, depth, notional) → por
    hora, la media del desequilibrio `(compra − venta) / (compra + venta)`
    con el nominal acumulado hasta ±`banda` %: `OBI_1`, `OBI_5`. La hora es
    la de apertura: lo de las 10:00–10:59 va a las 10:00."""
    crudo = crudo.copy()
    crudo["timestamp"] = pd.to_datetime(crudo["timestamp"])
    p = crudo.pivot_table(index="timestamp", columns="percentage", values="notional", aggfunc="last")
    out = {}
    for b in bandas:
        if -b not in p.columns or b not in p.columns:
            continue
        compra, venta = p[-b], p[b]
        out[f"OBI_{b}"] = (compra - venta) / (compra + venta)
    obi = pd.DataFrame(out, index=p.index)
    return obi.groupby(obi.index.floor("h")).mean()


def velas(simbolo: str, cache: Path | None = None, desde: str = "2017-08",
          hasta: str | None = None) -> pd.DataFrame | None:
    s = par(simbolo)
    if s is None:
        return None
    f = None if cache is None else cache / f"velas_{s}.pkl"
    if f is not None and f.exists():
        return pd.read_pickle(f)
    meses = pd.period_range(desde, hasta or pd.Timestamp.utcnow().strftime("%Y-%m"), freq="M")[:-1]
    urls = [f"{BASE}/spot/monthly/klines/{s}/1h/{s}-1h-{m}.zip" for m in meses]
    with ThreadPoolExecutor(8) as ex:
        trozos = [_csv_de_zip(c) for c in ex.map(_bajar, urls) if c]
    if not trozos:
        return None
    df = leer_velas(pd.concat(trozos, ignore_index=True))
    if f is not None:
        f.parent.mkdir(parents=True, exist_ok=True)
        df.to_pickle(f)
    return df


def _libro_de_un_dia(url: str) -> pd.DataFrame | None:
    c = _bajar(url)
    if not c:
        return None
    with zipfile.ZipFile(io.BytesIO(c)) as z:
        with z.open(z.namelist()[0]) as fh:
            return resumir_libro(pd.read_csv(fh))


def libro(simbolo: str, cache: Path | None = None, desde: str = "2023-01-01",
          hasta: str | None = None) -> pd.DataFrame | None:
    s = par(simbolo)
    if s is None:
        return None
    f = None if cache is None else cache / f"libro_{s}.pkl"
    if f is not None and f.exists():
        return pd.read_pickle(f)
    dias = pd.date_range(desde, hasta or (pd.Timestamp.utcnow().normalize().tz_localize(None) - pd.Timedelta(days=2)))
    urls = [f"{BASE}/futures/um/daily/bookDepth/{s}/{s}-bookDepth-{d:%Y-%m-%d}.zip" for d in dias]
    with ThreadPoolExecutor(16) as ex:
        trozos = [t for t in ex.map(_libro_de_un_dia, urls) if t is not None and len(t)]
    if not trozos:
        return None
    df = pd.concat(trozos).sort_index()
    df = df[~df.index.duplicated()]
    if f is not None:
        f.parent.mkdir(parents=True, exist_ok=True)
        df.to_pickle(f)
    return df
