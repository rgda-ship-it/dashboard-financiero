import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import PantallaAcceso, { Aviso, Campo } from "./PantallaAcceso.jsx";
import { supabase } from "../../supabase.js";
import { traducirError, useSesion } from "../../auth/sesion.jsx";

/**
 * Destino del enlace de recuperación. supabase-js lee el token del enlace
 * al cargar (detectSessionInUrl) y abre una sesión temporal con la que se
 * puede fijar la contraseña nueva.
 */
export default function NuevaContrasena() {
  const { sesion, cargando, terminarRecuperacion } = useSesion();
  const [clave, setClave] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);
  const navegar = useNavigate();

  async function guardar(e) {
    e.preventDefault();
    if (clave.length < 8) return setError("La contraseña debe tener al menos 8 caracteres.");
    setEnviando(true);
    setError(null);
    const { error: err } = await supabase.auth.updateUser({ password: clave });
    setEnviando(false);
    if (err) return setError(traducirError(err));
    terminarRecuperacion();
    navegar("/", { replace: true });
  }

  if (!cargando && !sesion) {
    return (
      <PantallaAcceso titulo="Enlace no válido" pie={<Link to="/recuperar">Pedir un enlace nuevo</Link>}>
        <p className="prosa">El enlace ha caducado o ya se usó. Pide uno nuevo.</p>
      </PantallaAcceso>
    );
  }

  return (
    <PantallaAcceso titulo="Elige una contraseña nueva">
      <form className="acceso__form" onSubmit={guardar}>
        <Campo etiqueta="Contraseña nueva (mínimo 8)" type="password" autoComplete="new-password"
               required minLength={8} value={clave} onChange={(e) => setClave(e.target.value)} />
        <Aviso>{error}</Aviso>
        <button type="submit" className="btn btn--accent acceso__boton" disabled={enviando || cargando}>
          {enviando ? "Guardando…" : "Guardar contraseña"}
        </button>
      </form>
    </PantallaAcceso>
  );
}
