import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Marca from "../components/ui/Marca.jsx";
import Panel from "../components/ui/Panel.jsx";
import Navegacion from "../components/Navegacion.jsx";
import { IconoBuscar, IconoSubir, IconoDescargar, IconoBorrar } from "../components/ui/Iconos.jsx";
import { useSesion } from "../auth/sesion.jsx";
import {
  buscarActivo,
  dejarActivo,
  leerMiCartera,
  leerPosiciones,
  leerSolicitudes,
  importarPosiciones,
  borrarPosiciones,
  pareceAccion,
  seguirActivo,
  solicitarActivo,
} from "../datos/cartera.js";
import { leerCartera } from "../datos/csvCartera.js";
import { descargarCSVModelo } from "../plantillaCartera.js";
import {
  claseSigno,
  formatearImporte,
  formatearPorcentaje,
  formatearPrecio,
  tiempoRelativo,
} from "../formato.js";

/**
 * Módulo Cartera (Sprint 4).
 *
 * Arriba, lo que sigues: el escáner solo muestra esto. Abajo, las
 * posiciones que declaras tener, importadas por CSV.
 */
const LIMITE_PERSONAL = 25; // D7 — la BD es quien lo impone; esto solo lo muestra.
const RELECTURA_MS = 10000; // mientras algo se está dando de alta

const ESTADOS = {
  activo: { texto: "al día", tono: "ok" },
  pendiente_backfill: { texto: "aprovisionando…", tono: "warn" },
  suspendido: { texto: "suspendido", tono: "neg" },
  invalido: { texto: "no reconocido", tono: "neg" },
};

function Estado({ estado }) {
  const e = ESTADOS[estado] ?? { texto: estado, tono: "" };
  return <span className={`cartera__estado cartera__estado--${e.tono}`}>{e.texto}</span>;
}

// ── Buscador ─────────────────────────────────────────────────────────
function Buscador({ alCambiar, avisar }) {
  const [texto, setTexto] = useState("");
  const [resultados, setResultados] = useState([]);
  const [buscando, setBuscando] = useState(false);
  const [ocupado, setOcupado] = useState(null);

  useEffect(() => {
    const q = texto.trim();
    if (!q) {
      setResultados([]);
      return undefined;
    }
    const id = setTimeout(async () => {
      setBuscando(true);
      try {
        setResultados(await buscarActivo(q));
      } catch (e) {
        avisar(e.message, "neg");
      } finally {
        setBuscando(false);
      }
    }, 250);
    return () => clearTimeout(id);
  }, [texto, avisar]);

  async function ejecutar(clave, accion, exito) {
    setOcupado(clave);
    try {
      const r = await accion();
      avisar(typeof exito === "function" ? exito(r) : exito, "ok");
      setTexto("");
      alCambiar();
    } catch (e) {
      avisar(e.message, "neg");
    } finally {
      setOcupado(null);
    }
  }

  const q = texto.trim();
  const exacto = resultados.some(
    (r) => r.origen === "catalogo" && r.simbolo.toUpperCase() === q.toUpperCase()
  );
  const ofrecerAccion = q && pareceAccion(q) && !exacto;

  return (
    <div className="buscador">
      <label className="field buscador__campo">
        <IconoBuscar />
        <input
          value={texto}
          onChange={(e) => setTexto(e.target.value)}
          placeholder="Busca una acción (NVDA) o una cripto (cardano, ADA)…"
          aria-label="Buscar activo"
        />
      </label>

      {q && (
        <ul className="buscador__lista">
          {resultados.map((r) => {
            const clave = `${r.origen}-${r.simbolo}`;
            return (
              <li key={clave} className="buscador__item">
                <span className="buscador__ticker">{r.ticker}</span>
                <span className="buscador__nombre">
                  {r.nombre ?? r.simbolo}
                  <span className="buscador__origen">
                    {r.origen === "catalogo"
                      ? r.clase === "cripto" ? "cripto · en el catálogo" : "acción · en el catálogo"
                      : "cripto · nueva (CoinGecko)"}
                  </span>
                </span>
                {r.seguido ? (
                  <span className="buscador__ya">en tu cartera</span>
                ) : (
                  <button
                    type="button"
                    className="btn btn--accent"
                    disabled={ocupado !== null}
                    onClick={() =>
                      r.origen === "catalogo"
                        ? ejecutar(clave, () => seguirActivo(r.activo_id), `${r.ticker} añadido a tu cartera.`)
                        : ejecutar(
                            clave,
                            () => solicitarActivo("cripto", r.simbolo),
                            `${r.ticker} añadido: descargando su histórico (1-3 minutos).`
                          )
                    }
                  >
                    {ocupado === clave ? "Añadiendo…" : "Añadir"}
                  </button>
                )}
              </li>
            );
          })}

          {ofrecerAccion && (
            <li className="buscador__item buscador__item--nueva">
              <span className="buscador__ticker">{q.toUpperCase()}</span>
              <span className="buscador__nombre">
                Buscar la acción «{q.toUpperCase()}» en Yahoo Finance
                <span className="buscador__origen">se comprueba y se descarga su histórico en 1-3 minutos</span>
              </span>
              <button
                type="button"
                className="btn"
                disabled={ocupado !== null}
                onClick={() =>
                  ejecutar("accion", () => solicitarActivo("accion", q), (r) =>
                    r.estado === "seguido"
                      ? `${q.toUpperCase()} añadido a tu cartera.`
                      : `Comprobando ${q.toUpperCase()} en Yahoo Finance…`
                  )
                }
              >
                {ocupado === "accion" ? "Enviando…" : "Añadir"}
              </button>
            </li>
          )}

          {!buscando && resultados.length === 0 && !ofrecerAccion && (
            <li className="buscador__vacio">Sin resultados para «{q}».</li>
          )}
        </ul>
      )}
    </div>
  );
}

// ── Importación CSV ──────────────────────────────────────────────────
function Importacion({ alTerminar, avisar }) {
  const inputRef = useRef(null);
  const [arrastrando, setArrastrando] = useState(false);
  const [procesando, setProcesando] = useState(false);
  const [resultado, setResultado] = useState(null);

  async function procesar(archivo) {
    if (!archivo) return;
    setProcesando(true);
    setResultado(null);
    try {
      const bytes = new Uint8Array(await archivo.arrayBuffer());
      const { filas, excluidas } = leerCartera(bytes);
      const r = filas.length
        ? await importarPosiciones(filas)
        : { importadas: 0, excluidas: [], sin_catalogo: [] };
      const todas = [...excluidas, ...(r.excluidas ?? [])].sort((a, b) => a.fila - b.fila);
      setResultado({ ...r, excluidas: todas, nombre: archivo.name });
      alTerminar();
    } catch (e) {
      avisar(e.message, "neg");
    } finally {
      setProcesando(false);
      if (inputRef.current) inputRef.current.value = "";
    }
  }

  return (
    <>
      {/* Decisión D3, dicha ANTES de que el usuario suelte el fichero. */}
      <p className="cartera__advertencia">
        <strong>Los importes se guardan sin cifrar.</strong> Este sistema asume que ninguna cifra
        es dinero real. No importes datos de patrimonio real. Importar <em>reemplaza</em> las
        posiciones que tuvieras cargadas.
      </p>

      <div className="intake">
        <button
          type="button"
          className={`drop${arrastrando ? " drop--over" : ""}`}
          disabled={procesando}
          onClick={() => inputRef.current?.click()}
          onDragOver={(e) => {
            e.preventDefault();
            setArrastrando(true);
          }}
          onDragLeave={() => setArrastrando(false)}
          onDrop={(e) => {
            e.preventDefault();
            setArrastrando(false);
            procesar(e.dataTransfer.files?.[0]);
          }}
        >
          <span className="drop__icon">
            <IconoSubir />
          </span>
          <span>
            <span className="drop__title">
              {procesando ? "Procesando archivo…" : "Arrastra tu CSV o haz clic para elegirlo"}
            </span>
            <span className="drop__hint">
              Encabezados: <code>Ticker</code>, <code>Precio de Compra</code>, <code>Monto</code>.
              Decimales con punto (<code>184.72</code>). Máximo 5 MB y 500 filas. El archivo se lee
              en tu navegador; al servidor solo llegan las filas.
            </span>
          </span>
          <input ref={inputRef} type="file" accept=".csv,text/csv" hidden
                 onChange={(e) => procesar(e.target.files?.[0])} />
        </button>

        <div className="intake__side">
          <button type="button" className="btn" onClick={descargarCSVModelo}>
            <IconoDescargar size={14} />
            Plantilla cartera-modelo.csv
          </button>
        </div>
      </div>

      {resultado && (
        <div className="cartera__resultado" role="status">
          <p>
            <strong>{resultado.importadas}</strong> posiciones importadas de {resultado.nombre}
            {resultado.excluidas.length > 0 && <>; {resultado.excluidas.length} filas excluidas</>}.
          </p>
          {resultado.excluidas.length > 0 && (
            <ul className="cartera__excluidas">
              {resultado.excluidas.map((e) => (
                <li key={`${e.fila}-${e.motivo}`}>Fila {e.fila}: {e.motivo}</li>
              ))}
            </ul>
          )}
          {resultado.sin_catalogo?.length > 0 && (
            <p className="cartera__nota">
              Sin análisis todavía (no están en el catálogo): {resultado.sin_catalogo.join(", ")}.
              Búscalos arriba y añádelos a tu cartera para ver su precio y su P&L.
            </p>
          )}
        </div>
      )}
    </>
  );
}

// ── Pantalla ─────────────────────────────────────────────────────────
export default function Cartera() {
  const { esAdmin } = useSesion();
  const [activos, setActivos] = useState([]);
  const [solicitudes, setSolicitudes] = useState([]);
  const [posiciones, setPosiciones] = useState([]);
  const [cargando, setCargando] = useState(true);
  const [aviso, setAviso] = useState(null);
  const [confirmandoBorrado, setConfirmandoBorrado] = useState(false);

  const avisar = useCallback((texto, tono = "ok") => setAviso({ texto, tono }), []);

  const cargar = useCallback(async () => {
    try {
      const [a, s, p] = await Promise.all([leerMiCartera(), leerSolicitudes(), leerPosiciones()]);
      setActivos(a);
      setSolicitudes(s);
      setPosiciones(p);
    } catch (e) {
      avisar(e.message, "neg");
    } finally {
      setCargando(false);
    }
  }, [avisar]);

  useEffect(() => {
    cargar();
  }, [cargar]);

  // Mientras algo se da de alta, se relee sola: la fila pasa de
  // «aprovisionando» a «al día» sin recargar (Realtime llega en H-32).
  const hayPendientes =
    activos.some((a) => a.estado === "pendiente_backfill") ||
    solicitudes.some((s) => s.estado === "pendiente" || s.estado === "procesando");
  useEffect(() => {
    if (!hayPendientes) return undefined;
    const id = setInterval(cargar, RELECTURA_MS);
    return () => clearInterval(id);
  }, [hayPendientes, cargar]);

  async function quitar(a) {
    try {
      await dejarActivo(a.activo_id);
      avisar(`${a.ticker} ya no está en tu cartera. Su histórico se conserva.`, "ok");
      cargar();
    } catch (e) {
      avisar(e.message, "neg");
    }
  }

  async function borrarTodo() {
    try {
      await borrarPosiciones();
      setConfirmandoBorrado(false);
      avisar("Posiciones borradas.", "ok");
      cargar();
    } catch (e) {
      avisar(e.message, "neg");
    }
  }

  const pnlTotal = useMemo(() => posiciones.reduce((s, p) => s + (Number(p.pnl) || 0), 0), [posiciones]);
  const cuota = esAdmin ? `${activos.length} activos · sin tope personal (admin)` : `${activos.length} / ${LIMITE_PERSONAL} activos`;

  return (
    <div className="shell">
      <header className="chrome">
        <div className="chrome__brand">
          <Marca />
          <div className="chrome__wordmark">
            <span className="chrome__title">Dashboard Financiero</span>
            <span className="chrome__subtitle">Cartera</span>
          </div>
        </div>
        <span className="chrome__rule" aria-hidden="true" />
      </header>

      <main className="main">
        <Navegacion />

        {aviso && (
          <p className={`acceso__aviso acceso__aviso--${aviso.tono} cartera__aviso`} role="status">
            {aviso.texto}
            <button type="button" className="enlace" onClick={() => setAviso(null)}>cerrar</button>
          </p>
        )}

        <Panel titulo="Lo que sigues" meta={cargando ? "cargando…" : cuota} flush>
          <div className="cartera__cuerpo">
            <Buscador alCambiar={cargar} avisar={avisar} />
          </div>

          {solicitudes.length > 0 && (
            <ul className="cartera__solicitudes">
              {solicitudes.map((s) => (
                <li key={s.id}>
                  <span className="buscador__ticker">{s.simbolo}</span>
                  {s.estado === "pendiente" || s.estado === "procesando" ? (
                    <span className="cartera__estado cartera__estado--warn">comprobando en Yahoo Finance…</span>
                  ) : (
                    <span className="cartera__estado cartera__estado--neg">{s.mensaje ?? s.estado}</span>
                  )}
                  <span className="cartera__cuando">{tiempoRelativo(s.creado_en)}</span>
                </li>
              ))}
            </ul>
          )}

          {!cargando && activos.length === 0 ? (
            <p className="prosa cartera__vacio">
              Tu cartera está vacía. Busca arriba cualquier acción o criptomoneda: el escáner solo
              analiza lo que sigues.
            </p>
          ) : (
            <table className="cartera__tabla">
              <thead>
                <tr>
                  <th>Activo</th>
                  <th>Estado</th>
                  <th className="num">Último precio</th>
                  <th>Actualizado</th>
                  <th aria-label="Acciones" />
                </tr>
              </thead>
              <tbody>
                {activos.map((a) => (
                  <tr key={a.activo_id}>
                    <td>
                      <span className="buscador__ticker">{a.ticker}</span>
                      <span className="cartera__nombre">{a.nombre ?? (a.clase === "cripto" ? a.simbolo : "")}</span>
                    </td>
                    <td>
                      <Estado estado={a.estado} />
                      {a.estado === "suspendido" && a.ultimo_error && (
                        <span className="cartera__error" title={a.ultimo_error}>{a.ultimo_error}</span>
                      )}
                    </td>
                    <td className="num">{a.ultimo_precio != null ? formatearPrecio(Number(a.ultimo_precio)) : "—"}</td>
                    <td className="cartera__cuando">{a.ultimo_etl_en ? tiempoRelativo(a.ultimo_etl_en) : "—"}</td>
                    <td className="cartera__accion">
                      <button type="button" className="btn" onClick={() => quitar(a)}>Quitar</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Panel>

        <Panel
          titulo="Posiciones importadas"
          meta={posiciones.length ? `${posiciones.length} posiciones` : null}
          pie={
            posiciones.length > 0 ? (
              <>
                <span className="label">P&L total</span>
                <span className={`num ${claseSigno(pnlTotal)}`} style={{ fontWeight: 500 }}>
                  {formatearImporte(pnlTotal)}
                </span>
              </>
            ) : null
          }
        >
          <Importacion alTerminar={cargar} avisar={avisar} />

          {posiciones.length > 0 && (
            <>
              <table className="cartera__tabla cartera__tabla--posiciones">
                <thead>
                  <tr>
                    <th>Ticker</th>
                    <th className="num">Precio de compra</th>
                    <th className="num">Monto</th>
                    <th className="num">Precio actual</th>
                    <th className="num">P&L</th>
                  </tr>
                </thead>
                <tbody>
                  {posiciones.map((p) => (
                    <tr key={p.id}>
                      <td><span className="buscador__ticker">{p.ticker}</span></td>
                      <td className="num">{formatearPrecio(Number(p.precio_compra))}</td>
                      <td className="num">{formatearPrecio(Number(p.monto))}</td>
                      <td className="num">{p.precio_actual != null ? formatearPrecio(Number(p.precio_actual)) : "sin análisis"}</td>
                      <td className={`num ${claseSigno(Number(p.pnl))}`}>
                        {p.pnl != null ? `${formatearImporte(Number(p.pnl))} (${formatearPorcentaje(Number(p.pnl_pct))})` : "—"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>

              <div className="cartera__borrar">
                {confirmandoBorrado ? (
                  <>
                    <span>¿Borrar todas tus posiciones importadas? Lo que sigues no se toca.</span>
                    <button type="button" className="btn btn--peligro" onClick={borrarTodo}>
                      <IconoBorrar size={14} /> Borrar
                    </button>
                    <button type="button" className="btn" onClick={() => setConfirmandoBorrado(false)}>Cancelar</button>
                  </>
                ) : (
                  <button type="button" className="enlace enlace--peligro" onClick={() => setConfirmandoBorrado(true)}>
                    Borrar posiciones importadas
                  </button>
                )}
              </div>
            </>
          )}
        </Panel>
      </main>
    </div>
  );
}
