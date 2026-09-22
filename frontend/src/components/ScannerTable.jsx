import { useMemo, useState } from "react";
import Panel from "./ui/Panel.jsx";
import MedidorConfluencia from "./ui/MedidorConfluencia.jsx";
import BarraApalancamiento from "./ui/BarraApalancamiento.jsx";
import RielRiesgo from "./ui/RielRiesgo.jsx";
import { IconoBuscar, IconoCaret, IconoAlerta, IconoRadar } from "./ui/Iconos.jsx";
import {
  esCripto,
  simboloVisible,
  formatearPrecio,
  direccionConfluencia,
  tramoVolatilidad,
  segmentosDeFuerza,
  formatearMagnitudPct,
  esOperable,
  nivelesTecnicos,
  formatearMultiplicador,
  formatearTope,
  tiempoRelativo,
} from "../formato.js";

const FILTROS = [
  { id: "todos", texto: "Todos" },
  { id: "acciones", texto: "Acciones" },
  { id: "cripto", texto: "Cripto" },
];

const COLUMNAS = [
  { id: "ticker", texto: "Activo", numerica: false },
  { id: "fuerza", texto: "Confluencia", numerica: false },
  { id: "atr", texto: "Volatilidad", numerica: true },
  { id: "leverage", texto: "Apalancamiento", numerica: true },
];

function valorDeOrden(senal, campo) {
  if (campo === "ticker") return simboloVisible(senal.ticker);
  if (campo === "fuerza") return segmentosDeFuerza(senal.fuerza);
  if (campo === "atr") return senal.atr_pct ?? -1;
  if (campo === "leverage") return senal.leverage_recomendado ?? -1;
  return 0;
}

function FilasEsqueleto() {
  return Array.from({ length: 6 }, (_, i) => (
    <tr key={i}>
      <td colSpan={6}>
        <div className="skeleton" style={{ height: 30, opacity: 1 - i * 0.13 }} />
      </td>
    </tr>
  ));
}

/** Una fila del escáner, más su detalle desplegable. */
function FilaSenal({ senal, abierta, alAbrir }) {
  const cripto = esCripto(senal.ticker, senal.clase);
  const direccion = direccionConfluencia(senal);
  const apoyos =
    direccion === "bajista" ? senal.indicadores_bajistas : senal.indicadores_alcistas;
  const totalIndicadores = Array.isArray(senal.senales) ? senal.senales.length : undefined;
  // Se ramifica por `operable`, nunca por la dirección: el motor puede
  // marcar una lectura alcista como no operable si le faltó volatilidad.
  const operable = esOperable(senal);
  const niveles = nivelesTecnicos(senal);

  return (
    <>
      <tr className={`row${abierta ? " row--abierta" : ""}`}>
        <td>
          <div className="asset">
            <span className={`asset__kind${cripto ? " asset__kind--cripto" : ""}`}>
              {cripto ? "CRP" : "EQ"}
            </span>
            <div>
              <p className="asset__ticker">{simboloVisible(senal.ticker)}</p>
              <p className="asset__price">{formatearPrecio(senal.precio_actual)}</p>
              {senal.suspendido ? (
                <p className="asset__aviso" title="Tres fallos seguidos del proveedor. El ETL lo reintenta con espera creciente; se muestra la última lectura válida.">
                  suspendido · {tiempoRelativo(senal.calculado_en)}
                </p>
              ) : senal.atrasada ? (
                <p className="asset__aviso" title="Debería haberse recalculado ya. Se muestra la última lectura válida.">
                  atrasado · {tiempoRelativo(senal.calculado_en)}
                </p>
              ) : null}
            </div>
          </div>
        </td>

        <td>
          <MedidorConfluencia
            direccion={direccion}
            fuerza={senal.fuerza}
            apoyos={apoyos}
            total={totalIndicadores}
            nota={operable ? null : "sin operación encuadrada"}
          />
        </td>

        <td>
          <div className="vol">
            <p className="vol__val">{formatearMagnitudPct(senal.atr_pct)}</p>
            <p className="vol__tag">{tramoVolatilidad(senal.atr_pct)}</p>
          </div>
        </td>

        <td>
          <BarraApalancamiento
            recomendado={senal.leverage_recomendado}
            tope={senal.leverage_tope}
            referencia={senal.leverage_referencia_volatilidad}
            operable={operable}
          />
        </td>

        <td>
          <RielRiesgo
            inferior={niveles.inferior}
            superior={niveles.superior}
            precio={senal.precio_actual}
            operable={operable}
          />
        </td>

        <td style={{ width: 44 }}>
          <button
            type="button"
            className="btn btn--icon"
            onClick={alAbrir}
            aria-expanded={abierta}
            title={abierta ? "Ocultar detalle" : "Ver detalle de la señal"}
          >
            <IconoCaret style={{ transform: abierta ? "rotate(180deg)" : "none" }} />
            <span className="sr-only">Detalle de {simboloVisible(senal.ticker)}</span>
          </button>
        </td>
      </tr>

      {abierta && (
        <tr className="detail">
          <td colSpan={6}>
            <div className="detail__box">
              <div className="detail__col">
                <p className="label">Indicadores evaluados</p>
                {Array.isArray(senal.senales) && senal.senales.length > 0 ? (
                  <div className="signals">
                    {senal.senales.map((s) => (
                      <span key={s.nombre} className={`signal signal--${s.direccion}`}>
                        <b>{s.nombre.replace(/_/g, " ")}</b>
                        <span>{s.detalle}</span>
                      </span>
                    ))}
                  </div>
                ) : (
                  <p className="detail__motivo">{senal.resumen_confluencia}</p>
                )}
              </div>

              <div className="detail__col">
                <p className="label">Criterio de apalancamiento</p>
                <p className="detail__motivo">
                  {senal.leverage_motivo ?? "—"}
                  {operable && Number.isFinite(senal.leverage_recomendado) && (
                    <>
                      <br />
                      Recomendado <strong>{formatearMultiplicador(senal.leverage_recomendado)}x</strong>{" "}
                      sobre un tope duro de <strong>{formatearTope(senal.leverage_tope)}x</strong>,
                      que el motor nunca supera.
                    </>
                  )}
                </p>
                <p className="detail__motivo dim">
                  Niveles{" "}
                  {senal.niveles_origen === "atr"
                    ? "por volatilidad (ATR), sin estructura clara en la ventana"
                    : "por estructura: mínimos y máximos de las últimas 20 velas"}
                  <br />
                  Origen: {cripto ? `CoinGecko · ${senal.ticker}` : `Yahoo Finance · ${senal.ticker}`}
                </p>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

export default function ScannerTable({
  senales,
  desdeCache,
  mensaje,
  cargando,
  error,
  alPedirAyuda,
}) {
  const [filtro, setFiltro] = useState("todos");
  const [busqueda, setBusqueda] = useState("");
  const [soloAltas, setSoloAltas] = useState(false);
  // Por defecto se ordena por fuerza de confluencia descendente: es la
  // pregunta que trae al analista a esta tabla.
  const [orden, setOrden] = useState({ campo: "fuerza", dir: "desc" });
  const [abierta, setAbierta] = useState(null);

  const visibles = useMemo(() => {
    const termino = busqueda.trim().toLowerCase();

    const filtradas = senales.filter((s) => {
      const cripto = esCripto(s.ticker, s.clase);
      if (filtro === "cripto" && !cripto) return false;
      if (filtro === "acciones" && cripto) return false;
      if (soloAltas && s.fuerza !== "alta") return false;
      if (termino && !`${s.ticker} ${simboloVisible(s.ticker)}`.toLowerCase().includes(termino)) {
        return false;
      }
      return true;
    });

    // Las filas con error se ordenan aparte y siempre van al final: no
    // compiten con las señales reales por la atención del analista.
    const ok = filtradas.filter((s) => !s.error);
    const fallidas = filtradas.filter((s) => s.error);

    ok.sort((a, b) => {
      const va = valorDeOrden(a, orden.campo);
      const vb = valorDeOrden(b, orden.campo);
      const cmp = typeof va === "string" ? va.localeCompare(vb) : va - vb;
      return orden.dir === "asc" ? cmp : -cmp;
    });

    return [...ok, ...fallidas];
  }, [senales, filtro, busqueda, soloAltas, orden]);

  function alternarOrden(campo) {
    setOrden((prev) =>
      prev.campo === campo
        ? { campo, dir: prev.dir === "asc" ? "desc" : "asc" }
        : { campo, dir: campo === "ticker" ? "asc" : "desc" }
    );
  }

  const hayCripto = visibles.some((s) => esCripto(s.ticker, s.clase) && !s.error);

  return (
    <Panel
      titulo="Escáner de mercado"
      alPedirAyuda={alPedirAyuda}
      meta={mensaje ?? (desdeCache ? "sirviendo la última lectura válida" : null)}
      flush
      pie={
        hayCripto ? (
          <span>
            La vela diaria de cripto se reconstruye a partir de dos fuentes de CoinGecko, que no
            sirve velas diarias con máximo y mínimo reales en su tier gratuito. Solo los últimos
            30 días tienen rango real, así que el ATR de una cripto es más ruidoso que el de una
            acción y puede moverla de tramo de volatilidad.
          </span>
        ) : null
      }
    >
      <div className="toolbar">
        <div className="segmented" role="group" aria-label="Filtrar por tipo de activo">
          {FILTROS.map((f) => (
            <button
              key={f.id}
              type="button"
              className="segmented__opt"
              aria-pressed={filtro === f.id}
              onClick={() => setFiltro(f.id)}
            >
              {f.texto}
            </button>
          ))}
        </div>

        <div className="segmented">
          <button
            type="button"
            className="segmented__opt"
            role="switch"
            aria-checked={soloAltas}
            aria-pressed={soloAltas}
            onClick={() => setSoloAltas((v) => !v)}
          >
            Solo alta
          </button>
        </div>

        <label className="field">
          <IconoBuscar />
          <span className="sr-only">Buscar activo</span>
          <input
            type="search"
            value={busqueda}
            placeholder="Buscar activo"
            onChange={(e) => setBusqueda(e.target.value)}
          />
        </label>

        <span className="toolbar__spacer" />
        <span className="toolbar__count num">
          {visibles.length} de {senales.length}
        </span>
      </div>

      {error ? (
        <div style={{ padding: "var(--sp-4)" }}>
          <p className="notice">
            <IconoAlerta />
            <span>
              {error}. El motor analítico (puerto 8001) y el backend (puerto 3000) tienen que
              estar corriendo para que el escáner reciba señales.
            </span>
          </p>
        </div>
      ) : (
        <div className="tbl-wrap">
          <table className="tbl">
            <thead>
              <tr>
                {COLUMNAS.map((c) => (
                  <th key={c.id} className={c.numerica ? "is-num" : undefined}>
                    <button
                      type="button"
                      className="tbl__sort"
                      data-activo={String(orden.campo === c.id)}
                      data-orden={orden.campo === c.id ? orden.dir : undefined}
                      onClick={() => alternarOrden(c.id)}
                    >
                      {c.texto}
                      <IconoCaret />
                    </button>
                  </th>
                ))}
                <th>Riesgo / objetivo</th>
                <th>
                  <span className="sr-only">Detalle</span>
                </th>
              </tr>
            </thead>

            <tbody>
              {cargando && <FilasEsqueleto />}

              {!cargando && visibles.length === 0 && (
                <tr>
                  <td colSpan={6}>
                    <div className="empty">
                      <IconoRadar />
                      <strong>Ningún activo coincide con el filtro</strong>
                      <span>Limpia la búsqueda o vuelve a “Todos” para ver el universo completo.</span>
                    </div>
                  </td>
                </tr>
              )}

              {!cargando &&
                visibles.map((s) =>
                  s.error ? (
                    <tr key={s.ticker} className="row row--error">
                      <td>
                        <div className="asset">
                          <span
                            className={`asset__kind${esCripto(s.ticker, s.clase) ? " asset__kind--cripto" : ""}`}
                          >
                            {esCripto(s.ticker, s.clase) ? "CRP" : "EQ"}
                          </span>
                          <div>
                            <p className="asset__ticker">{simboloVisible(s.ticker)}</p>
                            <p className="asset__price">sin datos</p>
                          </div>
                        </div>
                      </td>
                      <td colSpan={5}>
                        <p className="conf__text neg">{s.error}</p>
                      </td>
                    </tr>
                  ) : (
                    <FilaSenal
                      key={s.ticker}
                      senal={s}
                      abierta={abierta === s.ticker}
                      alAbrir={() => setAbierta((prev) => (prev === s.ticker ? null : s.ticker))}
                    />
                  )
                )}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
}
