import { useState } from "react";
import { Link } from "react-router-dom";
import PantallaAcceso, { Aviso, Campo } from "./PantallaAcceso.jsx";
import { supabase } from "../../supabase.js";
import { traducirError } from "../../auth/sesion.jsx";

export default function Recuperar() {
  const [email, setEmail] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);
  const [hecho, setHecho] = useState(false);

  async function enviar(e) {
    e.preventDefault();
    setEnviando(true);
    setError(null);
    const { error: err } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/nueva-contrasena`,
    });
    setEnviando(false);
    if (err) return setError(traducirError(err));
    setHecho(true);
  }

  return (
    <PantallaAcceso titulo="Recuperar la contraseña" pie={<Link to="/login">Volver a iniciar sesión</Link>}>
      {hecho ? (
        // Mismo mensaje exista o no la cuenta: no se revela quién está registrado.
        <p className="prosa">
          Si existe una cuenta con <strong>{email.trim()}</strong>, recibirás un enlace para elegir
          una contraseña nueva. Revisa también la carpeta de spam.
        </p>
      ) : (
        <form className="acceso__form" onSubmit={enviar}>
          <Campo etiqueta="Correo" type="email" autoComplete="email" required
                 value={email} onChange={(e) => setEmail(e.target.value)} />
          <Aviso>{error}</Aviso>
          <button type="submit" className="btn btn--accent acceso__boton" disabled={enviando}>
            {enviando ? "Enviando…" : "Enviar enlace"}
          </button>
        </form>
      )}
    </PantallaAcceso>
  );
}
