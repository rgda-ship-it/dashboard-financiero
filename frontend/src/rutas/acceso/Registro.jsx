import { useState } from "react";
import { Link } from "react-router-dom";
import PantallaAcceso, { Aviso, Campo } from "./PantallaAcceso.jsx";
import { supabase } from "../../supabase.js";
import { traducirError } from "../../auth/sesion.jsx";

const MIN_CLAVE = 8;

export default function Registro() {
  const [email, setEmail] = useState("");
  const [clave, setClave] = useState("");
  const [repetida, setRepetida] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);
  const [hecho, setHecho] = useState(false);

  async function registrar(e) {
    e.preventDefault();
    setError(null);
    if (clave.length < MIN_CLAVE) return setError(`La contraseña debe tener al menos ${MIN_CLAVE} caracteres.`);
    if (clave !== repetida) return setError("Las dos contraseñas no coinciden.");

    setEnviando(true);
    const { error: err } = await supabase.auth.signUp({
      email: email.trim(),
      password: clave,
      // El enlace del correo de confirmación vuelve a esta misma web.
      options: { emailRedirectTo: `${window.location.origin}/login` },
    });
    setEnviando(false);
    if (err) return setError(traducirError(err));
    setHecho(true);
  }

  if (hecho) {
    return (
      <PantallaAcceso titulo="Revisa tu correo" pie={<Link to="/login">Ir a iniciar sesión</Link>}>
        <p className="prosa">
          Te hemos enviado un enlace a <strong>{email.trim()}</strong> para confirmar la dirección.
          Si no aparece en unos minutos, mira en la carpeta de spam.
        </p>
        <p className="prosa">
          Después de confirmarla, tu solicitud queda <strong>pendiente</strong> hasta que un
          administrador la apruebe. Hasta entonces no verás datos de mercado.
        </p>
      </PantallaAcceso>
    );
  }

  return (
    <PantallaAcceso
      titulo="Solicitar acceso"
      subtitulo="Cada cuenta nueva la revisa un administrador antes de dar acceso a los datos."
      pie={<>¿Ya tienes cuenta? <Link to="/login">Inicia sesión</Link></>}
    >
      <form className="acceso__form" onSubmit={registrar}>
        <Campo etiqueta="Correo" type="email" autoComplete="email" required
               value={email} onChange={(e) => setEmail(e.target.value)} />
        <Campo etiqueta={`Contraseña (mínimo ${MIN_CLAVE})`} type="password" autoComplete="new-password"
               required minLength={MIN_CLAVE} value={clave} onChange={(e) => setClave(e.target.value)} />
        <Campo etiqueta="Repite la contraseña" type="password" autoComplete="new-password" required
               value={repetida} onChange={(e) => setRepetida(e.target.value)} />
        <Aviso>{error}</Aviso>
        <button type="submit" className="btn btn--accent acceso__boton" disabled={enviando}>
          {enviando ? "Enviando…" : "Crear cuenta"}
        </button>
      </form>
    </PantallaAcceso>
  );
}
