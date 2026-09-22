import { useCallback, useEffect, useMemo, useState } from "react";
import Marca from "../components/ui/Marca.jsx";
import Panel from "../components/ui/Panel.jsx";
import Navegacion from "../components/Navegacion.jsx";
import { supabase } from "../supabase.js";
import { useSesion } from "../auth/sesion.jsx";
import { tiempoRelativo } from "../formato.js";

const fechaHora = (iso) =>
  new Date(iso).toLocaleString("es-ES", { dateStyle: "short", timeStyle: "short" });

/**
 * Panel de administración (H-15).
 *
 * Todo lo que cambia un estado pasa por un RPC que comprueba es_admin()
 * dentro de la base de datos y deja fila en auditoria_admin. Esta pantalla
 * solo decide qué botones ofrecer; si alguien los fuerza sin ser admin,
 * el RPC responde «permiso denegado».
 */
const FILTROS = [
  { id: "pendiente", texto: "Pendientes" },
  { id: "aprobado", texto: "Aprobados" },
  { id: "suspendido", texto: "Suspendidos" },
  { id: "rechazado", texto: "Rechazados" },
  { id: "todos", texto: "Todos" },
];

const ACCIONES = {
  aprobar_usuario: "aprobó a",
  rechazar_usuario: "rechazó a",
  suspender_usuario: "suspendió a",
};

function FilaUsuario({ usuario, esYo, ocupado, alAprobar, alCambiar }) {
  // null | "rechazar" | "suspender": qué acción con motivo se está escribiendo.
  const [pidiendo, setPidiendo] = useState(null);
  const [motivo, setMotivo] = useState("");

  const puedeAprobar = usuario.estado !== "aprobado";
  const puedeRechazar = usuario.estado === "pendiente";
  const puedeSuspender = usuario.estado === "aprobado" && !esYo;

  function confirmar(e) {
    e.preventDefault();
    alCambiar(usuario.id, pidiendo, motivo.trim());
    setPidiendo(null);
    setMotivo("");
  }

  return (
    <li className="admin__fila">
      <div className="admin__quien">
        <p className="admin__email">
          {usuario.email}
          {usuario.rol === "admin" && <span className="nav__sprint">admin</span>}
          {esYo && <span className="admin__yo">tú</span>}
        </p>
        <p className="admin__meta">
          <span className={`acceso__estado acceso__estado--${usuario.estado}`}>{usuario.estado}</span>
          {" · "}registrado {tiempoRelativo(usuario.creado_en)}
          {usuario.motivo_estado && <> · motivo: {usuario.motivo_estado}</>}
        </p>
      </div>

      {pidiendo ? (
        <form className="admin__motivo" onSubmit={confirmar}>
          <input
            className="acceso__input"
            autoFocus
            required
            placeholder={`Motivo para ${pidiendo === "rechazar" ? "rechazar" : "suspender"} (obligatorio)`}
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
          />
          <button type="submit" className="btn btn--peligro" disabled={ocupado || !motivo.trim()}>
            Confirmar
          </button>
          <button type="button" className="btn" onClick={() => setPidiendo(null)}>
            Cancelar
          </button>
        </form>
      ) : (
        <div className="admin__acciones">
          {puedeAprobar && (
            <button type="button" className="btn btn--accent" disabled={ocupado} onClick={() => alAprobar(usuario.id)}>
              {usuario.estado === "pendiente" ? "Aprobar" : "Reactivar"}
            </button>
          )}
          {puedeRechazar && (
            <button type="button" className="btn" disabled={ocupado} onClick={() => setPidiendo("rechazar")}>
              Rechazar
            </button>
          )}
          {puedeSuspender && (
            <button type="button" className="btn btn--peligro" disabled={ocupado} onClick={() => setPidiendo("suspender")}>
              Suspender
            </button>
          )}
        </div>
      )}
    </li>
  );
}

export default function Admin() {
  const { perfil } = useSesion();
  const [usuarios, setUsuarios] = useState([]);
  const [auditoria, setAuditoria] = useState([]);
  const [filtro, setFiltro] = useState("pendiente");
  const [cargando, setCargando] = useState(true);
  const [ocupado, setOcupado] = useState(false);
  const [error, setError] = useState(null);

  const cargar = useCallback(async () => {
    const [u, a] = await Promise.all([
      supabase.from("perfiles")
        .select("id, email, rol, estado, motivo_estado, creado_en, aprobado_en")
        .order("creado_en", { ascending: false }),
      supabase.from("auditoria_admin")
        .select("id, actor_id, accion, objetivo_id, detalle, creado_en")
        .order("creado_en", { ascending: false })
        .limit(20),
    ]);
    if (u.error || a.error) setError((u.error ?? a.error).message);
    setUsuarios(u.data ?? []);
    setAuditoria(a.data ?? []);
    setCargando(false);
  }, []);

  useEffect(() => {
    cargar();
  }, [cargar]);

  async function ejecutar(llamada) {
    setOcupado(true);
    setError(null);
    const { error: err } = await llamada;
    setOcupado(false);
    if (err) setError(err.message);
    await cargar();
  }

  const aprobar = (id) => ejecutar(supabase.rpc("rpc_aprobar_usuario", { p_usuario: id }));
  const cambiar = (id, accion, motivo) =>
    ejecutar(
      supabase.rpc(accion === "rechazar" ? "rpc_rechazar_usuario" : "rpc_suspender_usuario", {
        p_usuario: id,
        p_motivo: motivo,
      })
    );

  const visibles = useMemo(
    () => (filtro === "todos" ? usuarios : usuarios.filter((u) => u.estado === filtro)),
    [usuarios, filtro]
  );
  const conteo = (estado) => usuarios.filter((u) => u.estado === estado).length;
  const emailDe = (id) => usuarios.find((u) => u.id === id)?.email ?? "usuario borrado";

  return (
    <div className="shell">
      <header className="chrome">
        <div className="chrome__brand">
          <Marca />
          <div className="chrome__wordmark">
            <span className="chrome__title">Dashboard Financiero</span>
            <span className="chrome__subtitle">Administración</span>
          </div>
        </div>
        <span className="chrome__rule" aria-hidden="true" />
      </header>

      <main className="main">
        <Navegacion />

        <Panel
          titulo="Solicitudes de acceso"
          flush
          meta={cargando ? "cargando…" : `${conteo("pendiente")} pendientes · ${usuarios.length} cuentas`}
        >
          <div className="toolbar">
            <div className="segmented" role="group" aria-label="Filtrar por estado">
              {FILTROS.map((f) => (
                <button key={f.id} type="button" className="segmented__opt"
                        aria-pressed={filtro === f.id} onClick={() => setFiltro(f.id)}>
                  {f.texto}
                </button>
              ))}
            </div>
          </div>

          {error && <p className="acceso__aviso acceso__aviso--neg admin__error" role="alert">{error}</p>}

          {!cargando && visibles.length === 0 ? (
            <p className="prosa admin__vacio">No hay cuentas en este estado.</p>
          ) : (
            <ul className="admin__lista">
              {visibles.map((u) => (
                <FilaUsuario key={u.id} usuario={u} esYo={u.id === perfil?.id}
                             ocupado={ocupado} alAprobar={aprobar} alCambiar={cambiar} />
              ))}
            </ul>
          )}
        </Panel>

        <Panel titulo="Auditoría" meta="últimas 20 acciones de administración" flush>
          {auditoria.length === 0 ? (
            <p className="prosa admin__vacio">Todavía no hay acciones registradas.</p>
          ) : (
            <ul className="admin__auditoria">
              {auditoria.map((a) => (
                <li key={a.id}>
                  <span className="admin__hora">{fechaHora(a.creado_en)}</span>
                  <span>
                    {emailDe(a.actor_id)} {ACCIONES[a.accion] ?? a.accion}{" "}
                    <strong>{a.detalle?.email ?? emailDe(a.objetivo_id)}</strong>
                    {a.detalle?.motivo && <> — «{a.detalle.motivo}»</>}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </Panel>
      </main>
    </div>
  );
}
