import { useCallback, useEffect, useState } from "react";
import StatusBar from "./components/StatusBar.jsx";
import MetricsStrip from "./components/MetricsStrip.jsx";
import ScannerTable from "./components/ScannerTable.jsx";
import PortfolioPanel from "./components/PortfolioPanel.jsx";
import EventLog from "./components/EventLog.jsx";
import HelpDrawer from "./components/HelpDrawer.jsx";
import { useEscaner, useCartera, useEventLog } from "./useApi.js";

/**
 * Armazón de la terminal.
 *
 * Dos zonas con jerarquías distintas: a la izquierda lo que se consulta y
 * se opera (escáner y cartera), a la derecha lo que simplemente ocurre
 * (el stream de eventos, fijo mientras se hace scroll). Arriba, la franja
 * de KPIs resume las dos en cuatro cifras.
 *
 * La guía de lectura se abre desde aquí porque cualquier panel puede
 * pedirla, cada uno apuntando a su propia sección.
 */
export default function App() {
  const escaner = useEscaner();
  const cartera = useCartera();
  const eventLog = useEventLog();

  // null = cerrada; si no, el id de la sección por la que abrirla.
  const [seccionGuia, setSeccionGuia] = useState(null);

  const abrirGuia = useCallback((seccion = "escaner") => setSeccionGuia(seccion), []);
  const cerrarGuia = useCallback(() => setSeccionGuia(null), []);

  // "?" abre la guía, salvo mientras se escribe en un campo.
  useEffect(() => {
    function alPulsar(e) {
      if (e.key !== "?" || e.metaKey || e.ctrlKey) return;
      const activo = document.activeElement?.tagName;
      if (activo === "INPUT" || activo === "TEXTAREA") return;
      setSeccionGuia((prev) => prev ?? "escaner");
    }
    document.addEventListener("keydown", alPulsar);
    return () => document.removeEventListener("keydown", alPulsar);
  }, []);

  return (
    <div className="shell">
      <StatusBar
        escaner={escaner}
        streamConectado={eventLog.conectado}
        alAbrirGuia={abrirGuia}
      />

      <main className="main">
        <MetricsStrip
          senales={escaner.senales}
          cargando={escaner.cargando}
          diagnosticos={cartera.diagnosticos}
          alPedirAyuda={() => abrirGuia("kpis")}
        />

        <div className="workspace">
          <div className="workspace__primary">
            <ScannerTable
              senales={escaner.senales}
              desdeCache={escaner.desdeCache}
              mensaje={escaner.mensaje}
              cargando={escaner.cargando}
              error={escaner.error}
              alPedirAyuda={() => abrirGuia("escaner")}
            />

            <PortfolioPanel
              diagnosticos={cartera.diagnosticos}
              resumenCarga={cartera.resumenCarga}
              cargando={cartera.cargando}
              error={cartera.error}
              subirArchivo={cartera.subirArchivo}
              restaurarCartera={cartera.restaurarCartera}
              borrarCartera={cartera.borrarCartera}
              alPedirAyuda={() => abrirGuia("cartera")}
              alPedirPlantilla={() => abrirGuia("plantilla")}
            />
          </div>

          <aside className="workspace__aside">
            <EventLog
              eventos={eventLog.eventos}
              conectado={eventLog.conectado}
              alLimpiar={eventLog.limpiarEventos}
              alPedirAyuda={() => abrirGuia("eventos")}
            />
          </aside>
        </div>

        <footer className="footnote">
          <span>Uso personal · no constituye recomendación de inversión</span>
          <span>Fuentes: Yahoo Finance (no oficial) · CoinGecko (tier gratuito)</span>
          <button type="button" className="footnote__enlace" onClick={() => abrirGuia("limites")}>
            Límites conocidos de los datos
          </button>
        </footer>
      </main>

      {seccionGuia && <HelpDrawer seccionInicial={seccionGuia} alCerrar={cerrarGuia} />}
    </div>
  );
}
