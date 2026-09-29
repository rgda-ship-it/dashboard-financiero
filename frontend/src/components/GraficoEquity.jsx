import { useEffect, useMemo, useRef, useState } from "react";
import { colorDe } from "../datos/agentes.js";
import { dominio, escalaLog, fechasDe, marcasEje } from "../datos/curvas.js";
import { formatearPrecio } from "../formato.js";

/**
 * Equity de los tres agentes frente a su curva teórica (H-31).
 *
 * Decisiones de forma, en orden de importancia:
 *
 * · UN solo eje y, logarítmico. Una meta diaria constante es una recta en
 *   escala log: la teórica se lee de un vistazo y la distancia de la real
 *   a ella es proporcional, no en dólares. En escala lineal, la teórica de
 *   Audacia aplasta a todo lo demás contra el eje en pocas semanas.
 * · Real y teórica se distinguen por TRAZO, no por color: continua la
 *   real, discontinua la teórica, del mismo tono del agente. El color es
 *   identidad del agente y nada más — el verde y el rojo son de mercado.
 * · Leyenda siempre, y además etiqueta directa al final de cada curva
 *   real: con tres series, la identidad nunca depende solo del color.
 * · Cruceta con tooltip al pasar el ratón, y una vista de tabla.
 */
// El ancho se MIDE y se dibuja en píxeles: con un viewBox fijo que se
// estira, el texto de los ejes crecería con la pantalla.
const ANCHO_INICIAL = 720;
const ALTO = 260;
const M = { arriba: 12, abajo: 26, izq: 56, der: 84 };

const fechaCorta = (iso) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("es-ES", {
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });

const cifraEje = (v) =>
  v >= 1_000_000
    ? `${(v / 1_000_000).toLocaleString("es-ES", { maximumFractionDigits: 1 })} M`
    : v >= 10_000
      ? `${Math.round(v / 1000).toLocaleString("es-ES")} k`
      : Math.round(v).toLocaleString("es-ES");

export default function GraficoEquity({ series }) {
  const [enTabla, setEnTabla] = useState(false);
  const [foco, setFoco] = useState(null);
  const svgRef = useRef(null);
  const lienzoRef = useRef(null);
  const [ancho, setAncho] = useState(ANCHO_INICIAL);

  const hayDatos = series.some((s) => s.puntos.length > 0);
  // Depende de `hayDatos` y `enTabla` porque son lo que monta o desmonta
  // el lienzo: sin ellos el observador se quedaría enganchado a nada.
  useEffect(() => {
    const nodo = lienzoRef.current;
    if (!nodo) return undefined;
    const medir = (w) => setAncho(Math.max(260, Math.round(w)));
    // Medición inmediata: el primer dibujo ya sale al ancho real.
    medir(nodo.getBoundingClientRect().width);
    if (typeof ResizeObserver === "undefined") return undefined;
    const obs = new ResizeObserver(([e]) => medir(e.contentRect.width));
    obs.observe(nodo);
    return () => obs.disconnect();
  }, [hayDatos, enTabla]);

  const fechas = useMemo(() => fechasDe(series), [series]);
  const [min, max] = useMemo(() => dominio(series), [series]);
  const marcas = useMemo(() => marcasEje(min, max), [min, max]);

  const altoPlot = ALTO - M.arriba - M.abajo;
  const anchoPlot = ancho - M.izq - M.der;
  const yLog = escalaLog(min, max, altoPlot);
  const y = (v) => M.arriba + yLog(v);
  const x = (fecha) => {
    const i = fechas.indexOf(fecha);
    return M.izq + (fechas.length <= 1 ? anchoPlot / 2 : (i / (fechas.length - 1)) * anchoPlot);
  };

  const trazo = (puntos, campo) =>
    puntos
      .filter((p) => Number.isFinite(p[campo]) && p[campo] > 0)
      .map((p, i) => `${i === 0 ? "M" : "L"}${x(p.fecha).toFixed(1)},${y(p[campo]).toFixed(1)}`)
      .join(" ");

  function alMover(e) {
    if (!fechas.length || !svgRef.current) return;
    const caja = svgRef.current.getBoundingClientRect();
    const px = ((e.clientX - caja.left) / caja.width) * ancho;
    const t = fechas.length <= 1 ? 0 : (px - M.izq) / anchoPlot;
    const i = Math.max(0, Math.min(fechas.length - 1, Math.round(t * (fechas.length - 1))));
    setFoco(fechas[i]);
  }

  if (!fechas.length) {
    return (
      <p className="sim__nota">
        Todavía no hay días registrados. La curva aparece con el primer ciclo de los agentes,
        aunque estén en pausa: su saldo también es un dato.
      </p>
    );
  }

  // Etiquetas directas: al final de cada curva real, separadas si chocan.
  const finales = series
    .map((s) => {
      const u = s.puntos[s.puntos.length - 1];
      return u ? { nombre: s.nombre, y: y(u.real) } : null;
    })
    .filter(Boolean)
    .sort((a, b) => a.y - b.y);
  for (let i = 1; i < finales.length; i += 1) {
    if (finales[i].y - finales[i - 1].y < 13) finales[i].y = finales[i - 1].y + 13;
  }

  const enFoco = foco
    ? series.map((s) => ({ nombre: s.nombre, p: s.puntos.find((p) => p.fecha === foco) }))
    : [];
  const xFoco = foco ? x(foco) : null;

  return (
    <div className="graf">
      <div className="graf__cabecera">
        <ul className="graf__leyenda" aria-label="Leyenda">
          {series.map((s) => (
            <li key={s.agenteId}>
              <span className="graf__muestra" style={{ background: colorDe(s.nombre) }} aria-hidden="true" />
              {s.nombre}
            </li>
          ))}
          <li className="graf__leyenda-trazo">
            <svg width="22" height="8" aria-hidden="true">
              <line x1="0" y1="4" x2="22" y2="4" className="graf__muestra-linea" />
            </svg>
            real
          </li>
          <li className="graf__leyenda-trazo">
            <svg width="22" height="8" aria-hidden="true">
              <line x1="0" y1="4" x2="22" y2="4" className="graf__muestra-linea graf__muestra-linea--teorica" />
            </svg>
            teórica · meta cada día
          </li>
        </ul>
        <button type="button" className="enlace" onClick={() => setEnTabla((v) => !v)}>
          {enTabla ? "Ver gráfico" : "Ver como tabla"}
        </button>
      </div>

      {enTabla ? (
        <div className="graf__tabla-envoltura">
          <table className="sim__tabla">
            <thead>
              <tr>
                <th>Día</th>
                {series.map((s) => (
                  <th key={s.agenteId} className="num">
                    {s.nombre} · real / teórica
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {[...fechas].reverse().map((f) => (
                <tr key={f}>
                  <td>{fechaCorta(f)}</td>
                  {series.map((s) => {
                    const p = s.puntos.find((q) => q.fecha === f);
                    return (
                      <td key={s.agenteId} className="num">
                        {p ? `${formatearPrecio(p.real)} / ${formatearPrecio(p.teorica)}` : "—"}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="graf__lienzo" ref={lienzoRef}>
          <svg
            ref={svgRef}
            viewBox={`0 0 ${ancho} ${ALTO}`}
            width={ancho}
            height={ALTO}
            className="graf__svg"
            role="img"
            aria-label="Equity de cada agente frente a su curva teórica, en escala logarítmica"
            onMouseMove={alMover}
            onMouseLeave={() => setFoco(null)}
          >
            {marcas.map((v) => (
              <g key={v}>
                <line x1={M.izq} x2={ancho - M.der} y1={y(v)} y2={y(v)} className="graf__rejilla" />
                <text x={M.izq - 8} y={y(v)} className="graf__eje" textAnchor="end" dominantBaseline="middle">
                  {cifraEje(v)}
                </text>
              </g>
            ))}
            <text x={M.izq} y={ALTO - 6} className="graf__eje">{fechaCorta(fechas[0])}</text>
            {fechas.length > 1 && (
              <text x={ancho - M.der} y={ALTO - 6} className="graf__eje" textAnchor="end">
                {fechaCorta(fechas[fechas.length - 1])}
              </text>
            )}

            {series.map((s) => (
              <g key={s.agenteId} style={{ color: colorDe(s.nombre) }}>
                <path d={trazo(s.puntos, "teorica")} className="graf__linea graf__linea--teorica" />
                <path d={trazo(s.puntos, "real")} className="graf__linea" />
                {s.puntos.length === 1 && (
                  <circle cx={x(s.puntos[0].fecha)} cy={y(s.puntos[0].real)} r="4" className="graf__punto" />
                )}
              </g>
            ))}

            {finales.map((f) => (
              <text key={f.nombre} x={ancho - M.der + 8} y={f.y} className="graf__etiqueta" dominantBaseline="middle">
                {f.nombre}
              </text>
            ))}

            {xFoco != null && (
              <g>
                <line x1={xFoco} x2={xFoco} y1={M.arriba} y2={ALTO - M.abajo} className="graf__cruceta" />
                {enFoco.map(({ nombre, p }) =>
                  p ? (
                    <circle
                      key={nombre}
                      cx={xFoco}
                      cy={y(p.real)}
                      r="4"
                      className="graf__punto"
                      style={{ color: colorDe(nombre) }}
                    />
                  ) : null
                )}
              </g>
            )}
            {/* Superficie de captura: más grande que las líneas, para que el
                tooltip no dependa de apuntar a un trazo de 2 px. */}
            <rect x={M.izq} y={M.arriba} width={anchoPlot} height={altoPlot} className="graf__captura" />
          </svg>

          {foco && (
            <div
              className="graf__tooltip"
              style={{ left: `${(xFoco / ancho) * 100}%` }}
              role="status"
            >
              <p className="graf__tooltip-fecha">{fechaCorta(foco)}</p>
              {enFoco.map(({ nombre, p }) =>
                p ? (
                  <p key={nombre} className="graf__tooltip-fila">
                    <span className="graf__muestra" style={{ background: colorDe(nombre) }} aria-hidden="true" />
                    <span className="graf__tooltip-nombre">{nombre}</span>
                    <span className="num">{formatearPrecio(p.real)}</span>
                    <span className="num graf__tooltip-teorica">{formatearPrecio(p.teorica)}</span>
                  </p>
                ) : null
              )}
            </div>
          )}
        </div>
      )}
      <p className="graf__nota">
        Escala logarítmica: la meta cumplida cada día es una recta. La teórica solo avanza en días
        operables — el fin de semana, la de Prudencia no crece.
      </p>
    </div>
  );
}
