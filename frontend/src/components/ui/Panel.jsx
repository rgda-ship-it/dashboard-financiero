import { IconoAyuda } from "./Iconos.jsx";

/**
 * Contenedor canónico de la interfaz. Todo bloque de contenido vive dentro
 * de un Panel: mismo borde, mismo filo de acento, misma cabecera. Es lo que
 * hace que tres módulos muy distintos se lean como un solo instrumento.
 *
 * `alPedirAyuda` añade el icono de guía en la cabecera. La ayuda se ofrece
 * donde surge la duda, no solo en un menú global.
 */
export default function Panel({
  titulo,
  meta,
  acciones,
  alPedirAyuda,
  flush = false,
  pie,
  children,
}) {
  return (
    <section className="panel">
      <header className="panel__head">
        <span className="panel__eyebrow" aria-hidden="true" />
        <h2 className="panel__title">{titulo}</h2>
        {meta && <p className="panel__meta">{meta}</p>}

        {(acciones || alPedirAyuda) && (
          <div className="panel__actions">
            {acciones}
            {alPedirAyuda && (
              <button
                type="button"
                className="btn btn--icon"
                onClick={alPedirAyuda}
                title={`Cómo leer: ${titulo}`}
              >
                <IconoAyuda />
                <span className="sr-only">Cómo leer: {titulo}</span>
              </button>
            )}
          </div>
        )}
      </header>

      <div className={flush ? "panel__body panel__body--flush" : "panel__body"}>
        {children}
      </div>

      {pie && <footer className="panel__foot">{pie}</footer>}
    </section>
  );
}
