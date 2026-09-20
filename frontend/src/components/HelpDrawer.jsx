import { useEffect, useRef, useState } from "react";
import { IconoCerrar, IconoDescargar } from "./ui/Iconos.jsx";
import { SECCIONES } from "../guia.js";
import { ENCABEZADOS, FILAS_MODELO, descargarCSVModelo } from "../plantillaCartera.js";

/**
 * Guía de lectura.
 *
 * Se abre desde la barra superior o desde el icono de ayuda de cualquier
 * panel; en ese segundo caso salta directamente a la sección del panel
 * desde el que se pidió, que es lo que hace que la ayuda sirva en el
 * momento en que surge la duda y no cinco minutos después.
 */

function Plantilla() {
  return (
    <div className="plantilla">
      <div className="plantilla__scroll">
        <table className="plantilla__tabla">
          <thead>
            <tr>
              {ENCABEZADOS.map((h) => (
                <th key={h}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {FILAS_MODELO.map((fila) => (
              <tr key={fila[0]}>
                {fila.map((celda, i) => (
                  <td key={i}>{celda}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <ul className="plantilla__reglas">
        <li>
          Los encabezados deben coincidir exactamente: <code>Ticker</code>,{" "}
          <code>Precio de Compra</code> y <code>Monto</code>. Cualquier otra columna del
          archivo se descarta al cargarlo.
        </li>
        <li>
          El separador decimal es siempre el punto: <code>184.72</code>. La coma solo se
          admite para agrupar millares (<code>1,200.50</code>). Una fila con coma decimal,
          como <code>184,72</code>, se excluye y se te informa — nunca se reinterpreta.
        </li>
        <li>
          Para cripto usa el identificador del universo del escáner (<code>BITCOIN</code>,{" "}
          <code>ETHEREUM</code>, <code>SOLANA</code>), no el símbolo corto.
        </li>
        <li>
          Máximo 5 MB. Una fila con datos incompletos o no numéricos se excluye y se te
          informa cuál y por qué; nunca invalida el resto del archivo.
        </li>
      </ul>

      <div className="plantilla__acciones">
        <button type="button" className="btn btn--accent" onClick={descargarCSVModelo}>
          <IconoDescargar />
          Descargar CSV modelo
        </button>
        <span>cartera-modelo.csv · 3 posiciones de ejemplo</span>
      </div>
    </div>
  );
}

export default function HelpDrawer({ seccionInicial, alCerrar }) {
  const cerrarRef = useRef(null);
  const cuerpoRef = useRef(null);
  const [activa, setActiva] = useState(seccionInicial ?? SECCIONES[0].id);

  // Esc cierra y el foco entra en el panel: sin esto, tabular seguiría
  // recorriendo el dashboard que quedó detrás del overlay.
  useEffect(() => {
    cerrarRef.current?.focus();
    const alPulsar = (e) => {
      if (e.key === "Escape") alCerrar();
    };
    document.addEventListener("keydown", alPulsar);

    const desbordeOriginal = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    return () => {
      document.removeEventListener("keydown", alPulsar);
      document.body.style.overflow = desbordeOriginal;
    };
  }, [alCerrar]);

  // Salto a la sección pedida desde el panel de origen. Instantáneo a
  // propósito: el contenedor tiene scroll suave para la navegación por el
  // índice, pero animar 2,000 px al abrir se siente como una espera, no
  // como una transición.
  useEffect(() => {
    if (!seccionInicial) return;
    document
      .getElementById(`guia-${seccionInicial}`)
      ?.scrollIntoView({ block: "start", behavior: "instant" });
  }, [seccionInicial]);

  // El índice se ilumina solo según lo que se está leyendo.
  useEffect(() => {
    const observador = new IntersectionObserver(
      (entradas) => {
        const visible = entradas
          .filter((e) => e.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
        if (visible) setActiva(visible.target.dataset.seccion);
      },
      { root: cuerpoRef.current, rootMargin: "0px 0px -70% 0px", threshold: 0 }
    );

    cuerpoRef.current
      ?.querySelectorAll(".guia__seccion")
      .forEach((nodo) => observador.observe(nodo));

    return () => observador.disconnect();
  }, []);

  function irA(id) {
    setActiva(id);
    document.getElementById(`guia-${id}`)?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  return (
    <>
      <div className="overlay" onClick={alCerrar} />

      <aside
        className="drawer"
        role="dialog"
        aria-modal="true"
        aria-label="Guía de lectura del dashboard"
      >
        <header className="drawer__head">
          <h2 className="drawer__title">
            Guía de lectura
            <span>Qué mide cada cifra, con qué fórmula y cómo interpretarla</span>
          </h2>
          <button
            type="button"
            ref={cerrarRef}
            className="btn btn--icon drawer__close"
            onClick={alCerrar}
            title="Cerrar la guía (Esc)"
          >
            <IconoCerrar />
            <span className="sr-only">Cerrar la guía</span>
          </button>
        </header>

        <nav className="drawer__nav" aria-label="Secciones de la guía">
          {SECCIONES.map((s) => (
            <button
              key={s.id}
              type="button"
              aria-current={activa === s.id}
              onClick={() => irA(s.id)}
            >
              {s.titulo}
            </button>
          ))}
        </nav>

        <div className="drawer__body" ref={cuerpoRef}>
          {SECCIONES.map((seccion) => (
            <section
              key={seccion.id}
              id={`guia-${seccion.id}`}
              data-seccion={seccion.id}
              className="guia__seccion"
            >
              <h3 className="guia__titulo">{seccion.titulo}</h3>
              <p className="guia__resumen">{seccion.resumen}</p>

              {seccion.tipo === "plantilla" ? (
                <Plantilla />
              ) : (
                <div className="guia__items">
                  {seccion.items.map((item) => (
                    <article key={item.termino} className="guia__item">
                      <h4 className="guia__termino">{item.termino}</h4>
                      {item.formula && <pre className="formula">{item.formula}</pre>}
                      <p className="guia__lectura">{item.lectura}</p>
                      {item.nota && <p className="guia__nota">{item.nota}</p>}
                    </article>
                  ))}
                </div>
              )}
            </section>
          ))}
        </div>

        <footer className="drawer__foot">
          Las fórmulas están transcritas del motor analítico. Uso personal: nada de esto es
          una recomendación de inversión.
        </footer>
      </aside>
    </>
  );
}
