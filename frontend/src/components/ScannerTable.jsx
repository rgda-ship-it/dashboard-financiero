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
import { minutosDesdeAperturaNY } from "../datos/frescura.js";
import { colorDe } from "../datos/agentes.js";
import { RANGO_ACCION, RR_MINIMO, veredicto } from "../datos/veredicto.js";

const FILTROS = [
  { id: "todos", texto: "Todos" },
  { id: "acciones", texto: "Acciones" },
  { id: "cripto", texto: "Cripto" },
];

const COLUMNAS = [
  { id: "ticker", texto: "Activo", numerica: false },
  { id: "accion", texto: "Qué hacer", numerica: false },
  { id: "fuerza", texto: "Confluencia", numerica: false },
  { id: "rr", texto: "Niveles", numerica: false },
  { id: "atr", texto: "Volatilidad", numerica: true },
];

function valorDeOrden(fila, campo) {
  const { senal, v } = fila;
  if (campo === "ticker") return simboloVisible(senal.ticker);
  // Lo accionable primero y, dentro de cada grupo, la confluencia más fuerte.
  if (campo === "accion") return -(RANGO_ACCION[v.accion] * 10 - segmentosDeFuerza(senal.fuerza));
  if (campo === "fuerza") return segmentosDeFuerza(senal.fuerza);
  if (campo === "rr") return Number.isFinite(v.rr) ? v.rr : -1;
  if (campo === "atr") return senal.atr_pct ?? -1;
  return 0;
}

const pct = (x) => `${x >= 0 ? "+" : "−"}${Math.abs(x).toFixed(1)} %`;

function FilasEsqueleto() {
  return Array.from({ length: 6 }, (_, i) => (
    <tr key={i}>
      <td colSpan={6}>
        <div className="skeleton" style={{ height: 30, opacity: 1 - i * 0.13 }} />
      </td>
    </tr>
  ));
}

/** El veredicto: qué hacer, en una palabra y una frase. */
function QueHacer({ v }) {
  return (
    <div className={`veredicto veredicto--${v.accion}`}>
      <span className="veredicto__accion">{v.titulo}</span>
      <span className="veredicto__motivo">{v.motivo}</span>
    </div>
  );
}

/** Comprar hasta, stop y objetivo, con lo que se arriesga y se gana. */
function Niveles({ v }) {
  if (!Number.isFinite(v.compra)) return <span className="niveles__vacio">—</span>;
  return (
    <dl className="niveles">
      <div>
        <dt>Comprar hasta</dt>
        <dd>{formatearPrecio(v.compra)}</dd>
      </div>
      <div>
        <dt>Stop</dt>
        <dd className="neg">
          {formatearPrecio(v.stop)} <small>{pct(-v.riesgoPct)}</small>
        </dd>
      </div>
      <div>
        <dt>Objetivo</dt>
        <dd className="pos">
          {formatearPrecio(v.objetivo)} <small>{pct(v.gananciaPct)}</small>
        </dd>
      </div>
      <div>
        <dt>R:R</dt>
        <dd className={v.rr >= RR_MINIMO ? undefined : "warn"}>{Number.isFinite(v.rr) ? v.rr.toFixed(2) : "—"}</dd>
      </div>
    </dl>
  );
}

/** Qué agentes la tomarían, y por qué no los demás. */
function Agentes({ v }) {
  if (!v.agentes.length) return null;
  return (
    <div className="quien">
      {v.agentes.map((a) => (
        <span
          key={a.nombre}
          className={`quien__agente${a.motivo ? " quien__agente--no" : ""}`}
          title={a.motivo ? `${a.nombre} no la tomaría: ${a.motivo}` : `${a.nombre} la tomaría`}
        >
          <span className="ag__punto" style={{ background: colorDe(a.nombre) }} aria-hidden="true" />
          {a.nombre}
          {a.motivo ? <span className="sr-only">: no, {a.motivo}</span> : <span className="sr-only">: sí</span>}
        </span>
      ))}
    </div>
  );
}

/** Una fila del escáner, más su detalle desplegable. */
function FilaSenal({ senal, v, abierta, alAbrir }) {
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
      <tr className={`row row--${v.accion}${abierta ? " row--abierta" : ""}`}>
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

        <td className="col-que-hacer">
          <QueHacer v={v} />
          <Agentes v={v} />
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
          <Niveles v={v} />
        </td>

        <td>
          <div className="vol">
            <p className="vol__val">{formatearMagnitudPct(senal.atr_pct)}</p>
            <p className="vol__tag">{tramoVolatilidad(senal.atr_pct)}</p>
          </div>
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
                <p className="label">Soporte y resistencia de 20 velas</p>
                {/* Soporte y resistencia, sin rol: desde la D21 el stop y el
                    objetivo ya no coinciden con ellos (están en «Niveles»). */}
                <RielRiesgo
                  inferior={niveles.inferior}
                  superior={niveles.superior}
                  precio={senal.precio_actual}
                  operable={false}
                />
              </div>

              <div className="detail__col">
                <p className="label">Por qué estos niveles</p>
                <p className="detail__motivo">
                  El stop va al soporte, pero a no menos de 1 ATR ni a más de 2 del precio; el
                  objetivo, a la resistencia, como mucho a 2 ATR (D21). Se compra al precio de
                  compra (el intermedio más medio spread
                  {Number.isFinite(senal.spread_cobrado) ? `, ${formatearPrecio(senal.spread_cobrado)} medido` : ", supuesto"}
                  ) y el stop salta al de venta.
                </p>
                <p className="detail__motivo dim">
                  Niveles{" "}
                  {senal.niveles_origen === "atr"
                    ? "por volatilidad (ATR), sin estructura clara en la ventana"
                    : "por estructura: mínimos y máximos de las últimas 20 velas"}
                  {" · "}Origen: {cripto ? `CoinGecko · ${senal.ticker}` : `Yahoo Finance · ${senal.ticker}`}
                </p>
                {v.agentes.some((a) => a.motivo) && (
                  <>
                    <p className="label">Por qué no la tomarían</p>
                    <p className="detail__motivo">
                      {v.agentes.filter((a) => a.motivo).map((a) => `${a.nombre}: ${a.motivo}`).join(" · ")}
                    </p>
                  </>
                )}
              </div>

              <div className="detail__col">
                <p className="label">Apalancamiento (simulador)</p>
                <BarraApalancamiento
                  recomendado={senal.leverage_recomendado}
                  tope={senal.leverage_tope}
                  referencia={senal.leverage_referencia_volatilidad}
                  operable={operable}
                />
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
  agentes = [],
  desdeCache,
  mensaje,
  cargando,
  error,
  alPedirAyuda,
}) {
  const [filtro, setFiltro] = useState("todos");
  const [busqueda, setBusqueda] = useState("");
  const [soloComprar, setSoloComprar] = useState(false);
  // Por defecto, lo que se puede comprar primero.
  const [orden, setOrden] = useState({ campo: "accion", dir: "desc" });
  const [abierta, setAbierta] = useState(null);

  const bolsaAbierta = minutosDesdeAperturaNY() !== null;

  const filas = useMemo(
    () =>
      senales.map((senal) => ({
        senal,
        v: veredicto(senal, { spread: senal.spread_cobrado, agentes, bolsaAbierta }),
      })),
    [senales, agentes, bolsaAbierta]
  );

  const cuentas = useMemo(() => {
    const c = { comprar: 0, esperar: 0, no_comprar: 0, sin_datos: 0 };
    filas.forEach((f) => (c[f.v.accion] += 1));
    return c;
  }, [filas]);

  const visibles = useMemo(() => {
    const termino = busqueda.trim().toLowerCase();

    const filtradas = filas.filter(({ senal: s, v }) => {
      const cripto = esCripto(s.ticker, s.clase);
      if (filtro === "cripto" && !cripto) return false;
      if (filtro === "acciones" && cripto) return false;
      if (soloComprar && v.accion !== "comprar") return false;
      if (termino && !`${s.ticker} ${simboloVisible(s.ticker)}`.toLowerCase().includes(termino)) {
        return false;
      }
      return true;
    });

    // Las filas con error se ordenan aparte y siempre van al final: no
    // compiten con las señales reales por la atención del analista.
    const ok = filtradas.filter((f) => !f.senal.error);
    const fallidas = filtradas.filter((f) => f.senal.error);

    ok.sort((a, b) => {
      const va = valorDeOrden(a, orden.campo);
      const vb = valorDeOrden(b, orden.campo);
      const cmp = typeof va === "string" ? va.localeCompare(vb) : va - vb;
      return orden.dir === "asc" ? cmp : -cmp;
    });

    return [...ok, ...fallidas];
  }, [filas, filtro, busqueda, soloComprar, orden]);

  function alternarOrden(campo) {
    setOrden((prev) =>
      prev.campo === campo
        ? { campo, dir: prev.dir === "asc" ? "desc" : "asc" }
        : { campo, dir: campo === "ticker" ? "asc" : "desc" }
    );
  }

  const hayCripto = visibles.some((f) => esCripto(f.senal.ticker, f.senal.clase) && !f.senal.error);

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
      {!cargando && !error && senales.length > 0 && (
        <div className="resumen-veredictos" aria-live="polite">
          <span className="veredicto__accion veredicto--comprar">{cuentas.comprar} para comprar</span>
          <span className="veredicto__accion veredicto--esperar">{cuentas.esperar} en espera</span>
          <span className="veredicto__accion veredicto--no_comprar">{cuentas.no_comprar} no comprar</span>
          {!bolsaAbierta && <span className="resumen-veredictos__nota">Bolsa de Nueva York cerrada: las acciones esperan a la apertura.</span>}
        </div>
      )}

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
            aria-checked={soloComprar}
            aria-pressed={soloComprar}
            onClick={() => setSoloComprar((v) => !v)}
          >
            Solo para comprar
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
            <span>{error}. No se han podido leer las señales de la base de datos.</span>
          </p>
        </div>
      ) : (
        <div className="tbl-wrap">
          <table className="tbl tbl--escaner">
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
                      <strong>{soloComprar ? "Ahora mismo no hay nada para comprar" : "Ningún activo coincide con el filtro"}</strong>
                      <span>
                        {soloComprar
                          ? "Ningún activo cumple todas las condiciones. Quita «Solo para comprar» para ver qué falta en cada uno."
                          : "Limpia la búsqueda o vuelve a “Todos” para ver el universo completo."}
                      </span>
                    </div>
                  </td>
                </tr>
              )}

              {!cargando &&
                visibles.map(({ senal: s, v }) =>
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
                      v={v}
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
