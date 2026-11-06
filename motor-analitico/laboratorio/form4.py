"""
Compras de los directivos en bolsa, del Form 4 de la SEC (doc fase-3/13
§5.3; doc fase-3/17). Sale de los «Insider Transactions Data Sets» que la
SEC publica cada trimestre desde 2006: un zip con las tablas de todos los
Form 3, 4 y 5 presentados.

Solo cuentan las compras en el mercado abierto (código de transacción
`P`, adquisición `A`) de al menos `VALOR_MINIMO` $: es lo que un directivo
hace con su dinero, a diferencia de las opciones, los planes o los
regalos. La fecha que vale es la de PRESENTACIÓN, no la de la operación:
es cuando se supo.

La SEC pide un User-Agent con un correo de contacto; se lee de
SEC_USER_AGENT y no queda en el repo.
"""

from __future__ import annotations

import io
import os
import time
import zipfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pandas as pd

URL = "https://www.sec.gov/files/structureddata/data/insider-transactions-data-sets/{}q{}_form345.zip"
VALOR_MINIMO = 10_000.0


def _bajar(url: str) -> bytes | None:
    agente = os.environ.get("SEC_USER_AGENT")
    if not agente:
        raise RuntimeError("Falta SEC_USER_AGENT (p. ej. «dashboard-financiero correo@ejemplo.com»)")
    time.sleep(0.2)   # la SEC admite 10 peticiones por segundo
    try:
        with urlopen(Request(url, headers={"User-Agent": agente}), timeout=300) as r:
            return r.read()
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def _fecha(serie: pd.Series) -> pd.Series:
    """Las fechas de los data sets vienen como «02-JAN-2024»."""
    f = pd.to_datetime(serie, format="%d-%b-%Y", errors="coerce")
    return f.fillna(pd.to_datetime(serie, errors="coerce"))


def leer_trimestre(contenido: bytes) -> pd.DataFrame:
    """El zip de un trimestre → una fila por compra en el mercado abierto:
    simbolo, presentada (fecha), propietario (CIK) y valor ($)."""
    with zipfile.ZipFile(io.BytesIO(contenido)) as z:
        nombres = {Path(n).name.upper(): n for n in z.namelist()}

        def tabla(nombre, columnas):
            with z.open(nombres[nombre]) as f:
                return pd.read_csv(f, sep="\t", usecols=columnas, dtype=str, quoting=3, on_bad_lines="skip")

        sub = tabla("SUBMISSION.TSV", ["ACCESSION_NUMBER", "FILING_DATE", "DOCUMENT_TYPE", "ISSUERTRADINGSYMBOL"])
        dueno = tabla("REPORTINGOWNER.TSV", ["ACCESSION_NUMBER", "RPTOWNERCIK"])
        tr = tabla("NONDERIV_TRANS.TSV", ["ACCESSION_NUMBER", "TRANS_CODE", "TRANS_ACQUIRED_DISP_CD",
                                          "TRANS_SHARES", "TRANS_PRICEPERSHARE"])
    return compras_de_tablas(sub, dueno, tr)


def compras_de_tablas(sub: pd.DataFrame, dueno: pd.DataFrame, tr: pd.DataFrame) -> pd.DataFrame:
    sub = sub[sub["DOCUMENT_TYPE"].isin(["4", "4/A"])]
    tr = tr[(tr["TRANS_CODE"] == "P") & (tr["TRANS_ACQUIRED_DISP_CD"] == "A")].copy()
    tr["valor"] = pd.to_numeric(tr["TRANS_SHARES"], errors="coerce") * pd.to_numeric(tr["TRANS_PRICEPERSHARE"],
                                                                                     errors="coerce")
    tr = tr.groupby("ACCESSION_NUMBER", as_index=False)["valor"].sum()
    tr = tr[tr["valor"] >= VALOR_MINIMO]
    # Un Form 4 puede tener varios propietarios (p. ej. un fondo y su gestor): cuenta el primero.
    dueno = dueno.drop_duplicates("ACCESSION_NUMBER")
    out = tr.merge(sub, on="ACCESSION_NUMBER").merge(dueno, on="ACCESSION_NUMBER")
    simbolo = out["ISSUERTRADINGSYMBOL"].fillna("").str.strip().str.upper().str.replace(".", "-", regex=False)
    return pd.DataFrame({"simbolo": simbolo, "presentada": _fecha(out["FILING_DATE"]),
                         "propietario": out["RPTOWNERCIK"], "valor": out["valor"]}).dropna(subset=["presentada"])


def compras(desde: int = 2014, cache: Path | None = None) -> pd.DataFrame:
    """Todas las compras de directivos desde `desde`, un zip por trimestre."""
    hoy = pd.Timestamp.today()
    trozos = []
    for ano in range(desde, hoy.year + 1):
        for q in range(1, 5):
            if pd.Timestamp(year=ano, month=3 * q, day=1) > hoy:
                break
            f = None if cache is None else cache / f"form4_{ano}q{q}.pkl"
            if f is not None and f.exists():
                trozos.append(pd.read_pickle(f))
                continue
            c = _bajar(URL.format(ano, q))
            if c is None:
                continue
            t = leer_trimestre(c)
            if f is not None:
                f.parent.mkdir(parents=True, exist_ok=True)
                t.to_pickle(f)
            trozos.append(t)
    return pd.concat(trozos, ignore_index=True) if trozos else pd.DataFrame(
        columns=["simbolo", "presentada", "propietario", "valor"])


def compradores_por_dia(df: pd.DataFrame, suyas: pd.DataFrame, dias: int = 30) -> pd.Series:
    """Para cada sesión t, cuántos directivos DISTINTOS presentaron una compra
    en los `dias` días naturales anteriores, contando solo lo presentado
    hasta el día ANTES de t: un Form 4 de la tarde de t no se sabe al cierre
    de t."""
    out = pd.Series(0, index=df.index, dtype=int)
    if suyas is None or not len(suyas):
        return out
    fechas = pd.to_datetime(suyas["presentada"]).dt.normalize().to_numpy()
    duenos = suyas["propietario"].to_numpy()
    for i, t in enumerate(df.index.normalize()):
        dentro = (fechas < t.to_datetime64()) & (fechas >= (t - pd.Timedelta(days=dias)).to_datetime64())
        if dentro.any():
            out.iloc[i] = len(set(duenos[dentro]))
    return out
