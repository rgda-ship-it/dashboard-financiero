import { NavLink } from "react-router-dom";
import { useSesion } from "../auth/sesion.jsx";

/**
 * Navegación entre módulos.
 *
 * La Fase 1 era una sola pantalla y no necesitaba router. La Fase 2 tiene
 * seis módulos, así que necesita uno — y necesita decir la verdad sobre
 * cuáles existen ya: un enlace que lleva a una pantalla vacía es peor que
 * un enlace marcado como pendiente.
 *
 * `sprint` es el sprint que entrega cada módulo. Se muestra como
 * distintivo hasta que el módulo esté listo, así que la propia interfaz
 * documenta el estado del proyecto mientras se construye.
 */
const MODULOS = [
  { ruta: "/", etiqueta: "Escáner", listo: true },
  { ruta: "/cartera", etiqueta: "Cartera", listo: true },
  { ruta: "/simulador", etiqueta: "Simulador", listo: true },
  { ruta: "/agentes", etiqueta: "Agentes", sprint: 6 },
  // Solo aparece para administradores (la RLS lo cierra igualmente).
  { ruta: "/admin", etiqueta: "Admin", listo: true, soloAdmin: true },
];

export default function Navegacion() {
  const { sesion, esAdmin, cerrarSesion } = useSesion();
  const modulos = MODULOS.filter((m) => !m.soloAdmin || esAdmin);

  return (
    <nav className="nav" aria-label="Módulos">
      {modulos.map((modulo) => (
        <NavLink
          key={modulo.ruta}
          to={modulo.ruta}
          end={modulo.ruta === "/"}
          className={({ isActive }) =>
            `nav__enlace${isActive ? " is-activa" : ""}${modulo.listo ? "" : " nav__enlace--pendiente"}`
          }
        >
          {modulo.etiqueta}
          {!modulo.listo && (
            <span className="nav__sprint" aria-label={`Previsto para el sprint ${modulo.sprint}`}>
              S{modulo.sprint}
            </span>
          )}
        </NavLink>
      ))}

      {sesion && (
        <div className="nav__usuario">
          <span className="nav__email" title={sesion.user.email}>{sesion.user.email}</span>
          <button type="button" className="btn" onClick={cerrarSesion}>Salir</button>
        </div>
      )}
    </nav>
  );
}
