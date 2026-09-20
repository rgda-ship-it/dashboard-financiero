import { useMemo } from "react";
import {
  formatearImporte,
  claseSigno,
  esOperable,
  formatearMultiplicador,
  formatearTope,
} from "../formato.js";
import { IconoAyuda } from "./ui/Iconos.jsx";

/**
 * Franja de KPIs. Cuatro cifras que responden, en el orden en que un
 * analista se las pregunta: ¿el escaneo salió bien?, ¿hay algo que mirar?,
 * ¿cuánto riesgo permite el sistema?, ¿cómo está lo que ya tengo?
 *
 * Todos los valores se derivan de datos ya presentes en pantalla — esta
 * franja no dispara ni una petición extra.
 */

function Tile({ etiqueta, valor, unidad, sub, progreso = 0, tono = "", alPedirAyuda }) {
  return (
    <article className="tile">
      <p className="tile__label label">
        {etiqueta}
        {alPedirAyuda && (
          <button
            type="button"
            className="tile__ayuda"
            onClick={alPedirAyuda}
            title={`Cómo se calcula: ${etiqueta}`}
          >
            <IconoAyuda size={13} />
            <span className="sr-only">Cómo se calcula: {etiqueta}</span>
          </button>
        )}
      </p>
      <p className="tile__value">
        {valor}
        {unidad && <span className="tile__unit">{unidad}</span>}
      </p>
      <p className="tile__sub">{sub}</p>
      <div className={`tile__meter${tono ? ` tile__meter--${tono}` : ""}`}>
        <i style={{ width: `${Math.min(100, Math.max(0, progreso * 100))}%` }} />
      </div>
    </article>
  );
}

export default function MetricsStrip({ senales, cargando, diagnosticos, alPedirAyuda }) {
  const m = useMemo(() => {
    const validas = senales.filter((s) => !s.error);
    const conError = senales.length - validas.length;
    const altas = validas.filter((s) => s.fuerza === "alta").length;

    // Solo promedia filas operables. Las bajistas y las neutrales llegan
    // con `leverage_recomendado: null` justamente porque su número no
    // significaba nada: incluirlas ensuciaba la media con cifras que el
    // motor ya no respalda.
    const operables = validas.filter(
      (s) => esOperable(s) && Number.isFinite(s.leverage_recomendado)
    );
    const levMedio = operables.length
      ? operables.reduce((acc, s) => acc + s.leverage_recomendado, 0) / operables.length
      : null;
    // El tope duro es una constante del sistema: todas las señales traen el
    // mismo valor, así que basta con leer la primera que lo tenga.
    const tope = validas.find((s) => Number.isFinite(s.leverage_tope))?.leverage_tope ?? null;

    const pnlTotal = diagnosticos.reduce((acc, d) => acc + (d.pnlAbsoluto ?? 0), 0);
    const enRojo = diagnosticos.filter((d) => d.nivelSalud === "rojo").length;

    return { validas, conError, altas, operables, levMedio, tope, pnlTotal, enRojo };
  }, [senales, diagnosticos]);

  if (cargando) {
    return (
      <div className="metrics">
        {[0, 1, 2, 3].map((i) => (
          <article key={i} className="tile">
            <div className="skeleton" style={{ width: "45%", height: 11 }} />
            <div className="skeleton" style={{ width: "60%", height: 30 }} />
            <div className="skeleton" style={{ width: "80%", height: 11 }} />
            <div className="tile__meter" />
          </article>
        ))}
      </div>
    );
  }

  const total = senales.length || 1;

  return (
    <div className="metrics">
      <Tile
        etiqueta="Universo escaneado"
        alPedirAyuda={alPedirAyuda}
        valor={m.validas.length}
        unidad={`/ ${senales.length}`}
        sub={m.conError ? `${m.conError} sin datos del proveedor` : "todos los activos respondieron"}
        progreso={m.validas.length / total}
        tono={m.conError ? "brass" : ""}
      />

      <Tile
        etiqueta="Confluencia alta"
        alPedirAyuda={alPedirAyuda}
        valor={m.altas}
        unidad={m.validas.length ? `/ ${m.validas.length}` : ""}
        sub={m.altas ? "señales con 3 o más indicadores alineados" : "ninguna señal alcanza fuerza alta"}
        progreso={m.validas.length ? m.altas / m.validas.length : 0}
        tono={m.altas ? "pos" : ""}
      />

      <Tile
        etiqueta="Apalancamiento medio"
        alPedirAyuda={alPedirAyuda}
        valor={formatearMultiplicador(m.levMedio)}
        unidad="x"
        sub={
          m.levMedio !== null
            ? `${m.operables.length} de ${m.validas.length} señales operables · tope ${formatearTope(m.tope)}x`
            : m.validas.length
              ? `ninguna señal operable · tope ${formatearTope(m.tope)}x`
              : "sin señales válidas"
        }
        progreso={m.levMedio !== null && m.tope ? m.levMedio / m.tope : 0}
        tono="brass"
      />

      <Tile
        etiqueta="P&L de cartera"
        alPedirAyuda={alPedirAyuda}
        valor={
          diagnosticos.length ? (
            <span className={claseSigno(m.pnlTotal)}>{formatearImporte(m.pnlTotal)}</span>
          ) : (
            "—"
          )
        }
        sub={
          diagnosticos.length
            ? `${diagnosticos.length} posiciones · ${m.enRojo} en deterioro`
            : "carga un CSV para el diagnóstico"
        }
        progreso={diagnosticos.length ? 1 - m.enRojo / diagnosticos.length : 0}
        tono={diagnosticos.length ? claseSigno(m.pnlTotal).replace("dim", "") : ""}
      />
    </div>
  );
}
