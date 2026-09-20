import { useRef, useState } from "react";
import Panel from "./ui/Panel.jsx";
import {
  IconoSubir,
  IconoRestaurar,
  IconoAlerta,
  IconoCartera,
  IconoDescargar,
} from "./ui/Iconos.jsx";
import {
  simboloVisible,
  formatearPrecio,
  formatearImporte,
  formatearPorcentaje,
  claseSigno,
  etiquetaSalud,
} from "../formato.js";

/**
 * Diagnóstico de cartera.
 *
 * La zona de carga acepta arrastrar y soltar además del clic, y el
 * consentimiento de persistencia se pide como una decisión explícita y
 * legible — no como una casilla suelta debajo del botón.
 */
export default function PortfolioPanel({
  diagnosticos,
  resumenCarga,
  cargando,
  error,
  subirArchivo,
  restaurarCartera,
  alPedirAyuda,
  alPedirPlantilla,
}) {
  const inputRef = useRef(null);
  const [guardarPersistente, setGuardarPersistente] = useState(false);
  const [arrastrando, setArrastrando] = useState(false);

  function entregar(archivo) {
    if (archivo) subirArchivo(archivo, guardarPersistente);
  }

  function alSoltar(e) {
    e.preventDefault();
    setArrastrando(false);
    entregar(e.dataTransfer.files?.[0]);
  }

  const pnlTotal = diagnosticos.reduce((acc, d) => acc + (d.pnlAbsoluto ?? 0), 0);

  return (
    <Panel
      titulo="Diagnóstico de cartera"
      alPedirAyuda={alPedirAyuda}
      meta={
        resumenCarga
          ? [
              Number.isFinite(resumenCarga.posicionesCargadas)
                ? `${resumenCarga.posicionesCargadas} posiciones`
                : null,
              resumenCarga.nombre,
            ]
              .filter(Boolean)
              .join(" · ")
          : null
      }
      pie={
        diagnosticos.length > 0 ? (
          <>
            <span className="label">P&L total</span>
            <span className={`num ${claseSigno(pnlTotal)}`} style={{ fontWeight: 500 }}>
              {formatearImporte(pnlTotal)}
            </span>
            <span style={{ marginLeft: "auto" }}>
              El monto invertido nunca sale de tu equipo: solo se usa aquí para calcular el P&L.
            </span>
          </>
        ) : null
      }
    >
      <div className="intake">
        <button
          type="button"
          className={`drop${arrastrando ? " drop--over" : ""}`}
          disabled={cargando}
          onClick={() => inputRef.current?.click()}
          onDragOver={(e) => {
            e.preventDefault();
            setArrastrando(true);
          }}
          onDragLeave={() => setArrastrando(false)}
          onDrop={alSoltar}
        >
          <span className="drop__icon">
            <IconoSubir />
          </span>
          <span>
            <span className="drop__title">
              {cargando ? "Procesando archivo…" : "Arrastra tu CSV o haz clic para elegirlo"}
            </span>
            <span className="drop__hint">
              Encabezados requeridos: <code>Ticker</code>, <code>Precio de Compra</code>,{" "}
              <code>Monto</code>. Decimales con punto (<code>184.72</code>). Máximo 5 MB. Las
              filas incompletas se descartan e informan.
            </span>
          </span>
          <input
            ref={inputRef}
            type="file"
            accept=".csv"
            hidden
            onChange={(e) => entregar(e.target.files?.[0])}
          />
        </button>

        <div className="intake__side">
          <label className="switch">
            <input
              type="checkbox"
              checked={guardarPersistente}
              onChange={(e) => setGuardarPersistente(e.target.checked)}
            />
            <span className="switch__track">
              <span className="switch__thumb" />
            </span>
            <span className="switch__text">
              <strong>Guardar para futuras sesiones</strong>
              <span>Se cifra con AES-256-GCM antes de tocar la base de datos.</span>
            </span>
          </label>

          <button
            type="button"
            className="btn"
            onClick={restaurarCartera}
            disabled={cargando}
          >
            <IconoRestaurar />
            Restaurar cartera guardada
          </button>

          <button type="button" className="enlace" onClick={alPedirPlantilla}>
            <IconoDescargar />
            Ver formato y descargar CSV modelo
          </button>
        </div>
      </div>

      {error && (
        <p className="notice" style={{ marginTop: "var(--sp-4)" }}>
          <IconoAlerta />
          <span>{error}</span>
        </p>
      )}

      {resumenCarga?.filasExcluidas?.length > 0 && (
        <p className="detail__motivo" style={{ marginTop: "var(--sp-3)" }}>
          {resumenCarga.filasExcluidas.length} fila(s) excluidas del archivo:{" "}
          {resumenCarga.filasExcluidas.map((f) => `#${f.fila} (${f.motivo})`).join(", ")}.
        </p>
      )}

      {diagnosticos.length === 0 && !error && (
        <div className="empty">
          <IconoCartera />
          <strong>Sin cartera cargada en esta sesión</strong>
          <span>
            El diagnóstico compara cada posición contra su confluencia actual y, solo si detecta
            deterioro, propone una rotación con los niveles genéricos del escáner.
          </span>
        </div>
      )}

      {diagnosticos.length > 0 && (
        <div className="tbl-wrap" style={{ marginTop: "var(--sp-4)" }}>
          <table className="tbl" style={{ minWidth: 700 }}>
            <thead>
              <tr>
                <th>Posición</th>
                <th className="is-num">P&L</th>
                <th>Salud</th>
                <th>Rotación sugerida</th>
              </tr>
            </thead>
            <tbody>
              {diagnosticos.map((d) => (
                <tr key={d.ticker} className="row">
                  <td>
                    <div className="asset">
                      <div>
                        <p className="asset__ticker">{simboloVisible(d.ticker)}</p>
                        <p className="asset__price">{formatearPrecio(d.precioActual)}</p>
                      </div>
                    </div>
                  </td>

                  <td>
                    <div className="pnl">
                      <span className={`pnl__pct ${claseSigno(d.pnlPct)}`}>
                        {formatearPorcentaje(d.pnlPct)}
                      </span>
                      <span className="pnl__abs">{formatearImporte(d.pnlAbsoluto)}</span>
                    </div>
                  </td>

                  <td>
                    <div className="health">
                      <span className={`state state--${d.nivelSalud}`}>
                        {etiquetaSalud(d.nivelSalud)}
                      </span>
                      <p className="health__msg">{d.mensaje}</p>
                    </div>
                  </td>

                  <td>
                    {d.sugerenciaRotacion ? (
                      <div className="rot">
                        <span className="rot__lead">Rotar a</span>
                        <span className="rot__ticker">
                          {simboloVisible(d.sugerenciaRotacion.ticker)}
                        </span>
                        <span className="rot__levels">
                          TP {formatearPrecio(d.sugerenciaRotacion.tp)} · SL{" "}
                          {formatearPrecio(d.sugerenciaRotacion.sl)}
                        </span>
                      </div>
                    ) : (
                      <span className="rot--vacia">Sin rotación sugerida</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
}
