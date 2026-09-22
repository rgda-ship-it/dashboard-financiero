import { useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import PantallaAcceso, { Aviso, Campo } from "./PantallaAcceso.jsx";
import { supabase, supabaseConfigurado } from "../../supabase.js";
import { traducirError } from "../../auth/sesion.jsx";

export default function Login() {
  const [email, setEmail] = useState("");
  const [clave, setClave] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);
  const navegar = useNavigate();
  const ubicacion = useLocation();

  async function entrar(e) {
    e.preventDefault();
    setEnviando(true);
    setError(null);
    const { error: err } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password: clave,
    });
    setEnviando(false);
    if (err) return setError(traducirError(err));
    navegar(ubicacion.state?.desde ?? "/", { replace: true });
  }

  return (
    <PantallaAcceso
      titulo="Iniciar sesión"
      pie={
        <>
          <Link to="/registro">Crear una cuenta</Link>
          <span aria-hidden="true">·</span>
          <Link to="/recuperar">He olvidado la contraseña</Link>
        </>
      }
    >
      {!supabaseConfigurado && (
        <Aviso>Falta la configuración de Supabase (VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY).</Aviso>
      )}
      <form className="acceso__form" onSubmit={entrar}>
        <Campo etiqueta="Correo" type="email" autoComplete="email" required
               value={email} onChange={(e) => setEmail(e.target.value)} />
        <Campo etiqueta="Contraseña" type="password" autoComplete="current-password" required
               value={clave} onChange={(e) => setClave(e.target.value)} />
        <Aviso>{error}</Aviso>
        <button type="submit" className="btn btn--accent acceso__boton" disabled={enviando || !supabaseConfigurado}>
          {enviando ? "Entrando…" : "Entrar"}
        </button>
      </form>
    </PantallaAcceso>
  );
}
