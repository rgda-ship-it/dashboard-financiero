import { useEffect } from "react";
import { Navigate } from "react-router-dom";
import PantallaAcceso from "./PantallaAcceso.jsx";
import { useSesion } from "../../auth/sesion.jsx";

// El usuario pendiente no tiene que recargar para entrar cuando lo
// aprueban: esta pantalla vuelve a leer SU perfil (lo único que la RLS
// le deja leer) cada pocos segundos. Es una fila por consulta.
const CADA_MS = 15000;

const TEXTOS = {
  pendiente: {
    titulo: "Solicitud pendiente",
    cuerpo:
      "Tu cuenta está creada y el correo confirmado. Falta que un administrador apruebe el acceso. " +
      "Esta página se actualiza sola: en cuanto te aprueben, entrarás al dashboard sin hacer nada.",
  },
  rechazado: {
    titulo: "Solicitud rechazada",
    cuerpo: "Un administrador ha rechazado el acceso de esta cuenta.",
  },
  suspendido: {
    titulo: "Acceso suspendido",
    cuerpo:
      "Un administrador ha suspendido el acceso de esta cuenta. Tus datos se conservan; " +
      "solo está bloqueada la lectura mientras dure la suspensión.",
  },
};

export default function Pendiente() {
  const { sesion, perfil, cargando, aprobado, recargarPerfil, cerrarSesion } = useSesion();

  useEffect(() => {
    if (!sesion || aprobado) return undefined;
    const id = setInterval(recargarPerfil, CADA_MS);
    return () => clearInterval(id);
  }, [sesion, aprobado, recargarPerfil]);

  if (!cargando && !sesion) return <Navigate to="/login" replace />;
  if (aprobado) return <Navigate to="/" replace />;

  const texto = TEXTOS[perfil?.estado] ?? TEXTOS.pendiente;

  return (
    <PantallaAcceso
      titulo={texto.titulo}
      pie={
        <button type="button" className="btn" onClick={cerrarSesion}>
          Cerrar sesión
        </button>
      }
    >
      <p className="prosa">{texto.cuerpo}</p>
      {perfil?.motivo_estado && perfil.estado !== "pendiente" && (
        <p className="prosa">
          <span className="acceso__etiqueta">Motivo</span>
          <br />
          {perfil.motivo_estado}
        </p>
      )}
      <dl className="acceso__datos">
        <dt>Cuenta</dt>
        <dd>{perfil?.email ?? sesion?.user?.email ?? "—"}</dd>
        <dt>Estado</dt>
        <dd className={`acceso__estado acceso__estado--${perfil?.estado ?? "pendiente"}`}>
          {perfil?.estado ?? "pendiente"}
        </dd>
      </dl>
    </PantallaAcceso>
  );
}
