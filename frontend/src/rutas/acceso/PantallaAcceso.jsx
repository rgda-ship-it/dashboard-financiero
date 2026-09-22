import Marca from "../../components/ui/Marca.jsx";

/** Marco común de las pantallas de acceso: marca arriba, un panel centrado. */
export default function PantallaAcceso({ titulo, subtitulo, children, pie }) {
  return (
    <div className="acceso">
      <div className="acceso__marca">
        <Marca />
        <div className="chrome__wordmark">
          <span className="chrome__title">Dashboard Financiero</span>
          <span className="chrome__subtitle">Terminal personal · acceso</span>
        </div>
      </div>

      <section className="panel acceso__panel">
        <header className="panel__head">
          <span className="panel__eyebrow" aria-hidden="true" />
          <h1 className="panel__title">{titulo}</h1>
        </header>
        <div className="acceso__cuerpo">
          {subtitulo && <p className="prosa">{subtitulo}</p>}
          {children}
        </div>
      </section>

      {pie && <div className="acceso__pie">{pie}</div>}
    </div>
  );
}

export function Campo({ etiqueta, ...props }) {
  return (
    <label className="acceso__campo">
      <span className="acceso__etiqueta">{etiqueta}</span>
      <input className="acceso__input" {...props} />
    </label>
  );
}

export function Aviso({ tono = "neg", children }) {
  if (!children) return null;
  return (
    <p className={`acceso__aviso acceso__aviso--${tono}`} role={tono === "neg" ? "alert" : "status"}>
      {children}
    </p>
  );
}
