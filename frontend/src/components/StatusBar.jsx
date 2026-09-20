import { useEffect, useState } from "react";
import Marca from "./ui/Marca.jsx";
import Chip from "./ui/Chip.jsx";
import { IconoRefrescar, IconoAyuda } from "./ui/Iconos.jsx";
import { tiempoRelativo } from "../formato.js";

/**
 * Barra superior: identidad a la izquierda, salud del sistema a la derecha.
 *
 * Es lo único fijo en pantalla, así que solo puede contener lo que el
 * analista necesita saber en todo momento: si los datos son de ahora o de
 * caché, si el stream de eventos está vivo, y cuándo fue el último escaneo.
 */
export default function StatusBar({ escaner, streamConectado, alAbrirGuia }) {
  // El "hace N min" tiene que envejecer solo: sin este tick se congelaría
  // en el valor que tenía al renderizar.
  const [, refrescarReloj] = useState(0);
  useEffect(() => {
    const id = setInterval(() => refrescarReloj((n) => n + 1), 30000);
    return () => clearInterval(id);
  }, []);

  const datos = escaner.error
    ? { valor: "sin conexión", tono: "neg", vivo: false }
    : escaner.desdeCache
      ? { valor: "caché", tono: "warn", vivo: false }
      : { valor: "en vivo", tono: "neutro", vivo: true };

  return (
    <header className="chrome">
      <div className="chrome__brand">
        <Marca />
        <div className="chrome__wordmark">
          <span className="chrome__title">Dashboard Financiero</span>
          <span className="chrome__subtitle">Terminal personal · localhost</span>
        </div>
      </div>

      <span className="chrome__rule" aria-hidden="true" />

      <div className="chrome__status">
        <Chip etiqueta="Datos" valor={datos.valor} tono={datos.tono} vivo={datos.vivo} />
        <Chip
          etiqueta="Stream"
          valor={streamConectado ? "activo" : "reconectando"}
          tono={streamConectado ? "neutro" : "warn"}
          vivo={streamConectado}
        />
        <Chip etiqueta="Escaneo" valor={tiempoRelativo(escaner.ultimaActualizacion)} />

        <button
          type="button"
          className={`btn btn--icon${escaner.refrescando ? " is-girando" : ""}`}
          onClick={escaner.refrescar}
          disabled={escaner.refrescando}
          title="Volver a escanear el universo"
        >
          <IconoRefrescar />
          <span className="sr-only">Volver a escanear</span>
        </button>

        <button type="button" className="btn" onClick={() => alAbrirGuia()}>
          <IconoAyuda size={14} />
          Guía
        </button>
      </div>
    </header>
  );
}
