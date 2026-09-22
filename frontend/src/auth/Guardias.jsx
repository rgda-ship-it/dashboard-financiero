import { Navigate, useLocation } from "react-router-dom";
import { useSesion } from "./sesion.jsx";
import PantallaAcceso from "../rutas/acceso/PantallaAcceso.jsx";
import { supabaseConfigurado } from "../supabase.js";

/**
 * Guardias de ruta.
 *
 * Son COMODIDAD, no seguridad: deciden qué pantalla ver. Lo que un token
 * puede leer lo decide la RLS del servidor. Un usuario que se salte esta
 * guardia a mano recibe exactamente cero filas.
 */
function Cargando() {
  return (
    <PantallaAcceso titulo="Comprobando tu sesión">
      <div className="skeleton" style={{ height: 14, width: "60%" }} />
    </PantallaAcceso>
  );
}

export function RequiereAprobado({ children }) {
  const { sesion, perfil, cargando, aprobado } = useSesion();
  const ubicacion = useLocation();

  if (!supabaseConfigurado) return children; // la propia pantalla explica qué falta
  if (cargando) return <Cargando />;
  if (!sesion) return <Navigate to="/login" replace state={{ desde: ubicacion.pathname }} />;
  if (!perfil) return <Cargando />;
  if (!aprobado) return <Navigate to="/pendiente" replace />;
  return children;
}

export function RequiereAdmin({ children }) {
  const { esAdmin } = useSesion();
  return (
    <RequiereAprobado>{esAdmin ? children : <Navigate to="/" replace />}</RequiereAprobado>
  );
}

/** Para /login y /registro: con sesión ya abierta no tiene sentido verlas. */
export function SoloSinSesion({ children }) {
  const { sesion, cargando, recuperando } = useSesion();
  if (cargando) return <Cargando />;
  if (sesion && !recuperando) return <Navigate to="/" replace />;
  return children;
}
