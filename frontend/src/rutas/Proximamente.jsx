import Marca from "../components/ui/Marca.jsx";
import Panel from "../components/ui/Panel.jsx";
import Navegacion from "../components/Navegacion.jsx";

/**
 * Pantalla de un módulo que todavía no existe.
 *
 * No es un relleno: es la alternativa honesta a un enlace roto o a una
 * pantalla en blanco. Dice qué va a haber aquí, en qué sprint y de qué
 * depende, que es exactamente lo que alguien que abre la aplicación a
 * mitad de construcción necesita saber.
 */
export default function Proximamente({ titulo, sprint, descripcion, historias }) {
  return (
    <div className="shell">
      <header className="chrome">
        <div className="chrome__brand">
          <Marca />
          <div className="chrome__wordmark">
            <span className="chrome__title">Dashboard Financiero</span>
            <span className="chrome__subtitle">{titulo}</span>
          </div>
        </div>
        <span className="chrome__rule" aria-hidden="true" />
      </header>

      <main className="main">
        <Navegacion />

        <Panel titulo={titulo} meta={`Previsto para el Sprint ${sprint}`}>
          <p className="prosa">{descripcion}</p>
          {historias?.length > 0 && (
            <>
              <p className="prosa prosa--etiqueta">Historias que lo entregan</p>
              <ul className="prosa prosa--lista">
                {historias.map((h) => (
                  <li key={h}>{h}</li>
                ))}
              </ul>
            </>
          )}
        </Panel>
      </main>
    </div>
  );
}
