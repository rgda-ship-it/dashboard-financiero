import { useCallback, useEffect, useMemo, useState } from "react";
import Marca from "../components/ui/Marca.jsx";
import Panel from "../components/ui/Panel.jsx";
import Chip from "../components/ui/Chip.jsx";
import Navegacion from "../components/Navegacion.jsx";
import { supabase } from "../supabase.js";
import { useSesion } from "../auth/sesion.jsx";
import { formatearPrecio, tiempoRelativo } from "../formato.js";
import {
  ESTADOS_AGENTE,
  ESTADOS_BACKLOG,
  TIPOS_BACKLOG,
  cambiarEstadoAgente,
  colorDe,
  revertirFase,
  leerBacklog,
  leerRanking,
  leerSalud,
  renovarCredencial,
  leerHipotesis,
  revisarHipotesis,
  ESTADOS_HIPOTESIS,
  ORIGENES_HIPOTESIS,
  cambioLegible,
  resultadoLegible,
  reiniciarAgente,
  revisarBacklog,
} from "../datos/agentes.js";

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
  revertir_fase: "revirtió a Fase 1 la cuenta",
  cambiar_estado_agente: "cambió el estado de",
  reiniciar_agente: "reinició a",
  resolver_backlog: "resolvió la petición",
  resolver_hipotesis: "resolvió la hipótesis",
  renovar_credencial: "anotó la renovación de",
};

// ── Agentes (Sprint 6, D13) ──────────────────────────────────────────
// Nacen en pausa: ponerlos en marcha es una decisión humana y queda
// auditada. Reiniciar tras un Game Over crea una cuenta NUEVA (N14).
function FilaAgente({ a, ocupado, alCambiar, alReiniciar, alRevertir }) {
  const [confirmando, setConfirmando] = useState(false);
  const [revirtiendo, setRevirtiendo] = useState(false);
  const estado = ESTADOS_AGENTE[a.estado] ?? { texto: a.estado };
  return (
    <li className="admin__fila">
      <div className="admin__quien">
        <p className="admin__email">
          <span className="ag__punto" style={{ background: colorDe(a.nombre) }} aria-hidden="true" />
          {a.nombre} ·{" "}
          {a.objetivo_diario_pct != null ? `${Number(a.objetivo_diario_pct)} % diario` : "sin meta diaria (estrategia)"}
        </p>
        <p className="admin__meta">
          {estado.texto}
          {a.estado_previo === "cuarentena" && " (vuelve a cuarentena al reanudar)"}
          {" · "}equity {a.equity != null ? formatearPrecio(Number(a.equity)) : "—"}
          {" · "}cuenta #{a.cuenta_id}
          {" · "}
          {a.fase === "fase_2_consolidacion" ? "Fase 2 (tope 3×)" : "Fase 1 (tope 5×)"}
        </p>
      </div>
      <div className="admin__acciones">
        {a.estado === "pausado" && (
          <button type="button" className="btn btn--accent" disabled={ocupado}
                  onClick={() => alCambiar(a.agente_id, "activo")}>
            Poner en marcha
          </button>
        )}
        {(a.estado === "activo" || a.estado === "cuarentena") && (
          <button type="button" className="btn" disabled={ocupado}
                  onClick={() => alCambiar(a.agente_id, "pausado")}>
            Pausar
          </button>
        )}
        {/* Regla protegida nº5: de Fase 2 no se vuelve sola. Volverá a Fase 2
            con el primer criterio que cumpla (8 cierres, −30 %, 3×). */}
        {a.fase === "fase_2_consolidacion" && a.estado !== "game_over" &&
          (revirtiendo ? (
            <>
              <button
                type="button"
                className="btn btn--peligro"
                disabled={ocupado}
                onClick={() => {
                  setRevirtiendo(false);
                  alRevertir(a.cuenta_id);
                }}
              >
                Confirmar: volver a Fase 1 (5×)
              </button>
              <button type="button" className="btn" onClick={() => setRevirtiendo(false)}>
                Cancelar
              </button>
            </>
          ) : (
            <button type="button" className="btn" disabled={ocupado} onClick={() => setRevirtiendo(true)}>
              Volver a Fase 1
            </button>
          ))}
        {a.estado === "game_over" &&
          (confirmando ? (
            <>
              <button
                type="button"
                className="btn btn--peligro"
                disabled={ocupado}
                onClick={() => {
                  setConfirmando(false);
                  alReiniciar(a.agente_id);
                }}
              >
                Confirmar: cuenta nueva de 500 $
              </button>
              <button type="button" className="btn" onClick={() => setConfirmando(false)}>
                Cancelar
              </button>
            </>
          ) : (
            <button type="button" className="btn" disabled={ocupado} onClick={() => setConfirmando(true)}>
              Reiniciar
            </button>
          ))}
      </div>
    </li>
  );
}

// ── Hipótesis de los agentes (0046) ──────────────────────────────────
// Adoptar solo se puede lo que el laboratorio validó (lo comprueba el
// RPC); archivar, cualquiera, explicando por qué.
const HIPOTESIS_CERRADAS = ["adoptada", "archivada"];

function FilaHipotesis({ h, ocupado, alRevisar }) {
  const [archivando, setArchivando] = useState(false);
  const [motivo, setMotivo] = useState("");

  function archivar(e) {
    e.preventDefault();
    alRevisar(h.id, "archivada", motivo.trim());
    setArchivando(false);
    setMotivo("");
  }

  return (
    <li className="admin__fila">
      <div className="admin__quien">
        <p className="admin__email">
          <span className="ag__punto" style={{ background: colorDe(h.nombre) }} aria-hidden="true" />
          {h.nombre} · <span className="ag__etiqueta">{ORIGENES_HIPOTESIS[h.origen] ?? h.origen}</span>
        </p>
        <p className="admin__meta">{h.enunciado}</p>
        <p className="admin__meta">
          semana del {h.semana} · {cambioLegible(h.experimento?.cambio)} · {ESTADOS_HIPOTESIS[h.estado] ?? h.estado}
          {h.resolucion && <> · «{h.resolucion}»</>}
        </p>
        {h.resultado && <p className="admin__meta">Laboratorio: {resultadoLegible(h.resultado)}</p>}
      </div>
      {archivando ? (
        <form className="admin__motivo" onSubmit={archivar}>
          <input
            className="acceso__input"
            autoFocus
            required
            placeholder="Por qué se archiva (obligatorio)"
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
          />
          <button type="submit" className="btn btn--peligro" disabled={ocupado || !motivo.trim()}>
            Archivar
          </button>
          <button type="button" className="btn" onClick={() => setArchivando(false)}>
            Cancelar
          </button>
        </form>
      ) : (
        !HIPOTESIS_CERRADAS.includes(h.estado) && (
          <div className="admin__acciones">
            {h.estado === "validada" && (
              <button type="button" className="btn btn--accent" disabled={ocupado}
                      onClick={() => alRevisar(h.id, "adoptada")}>
                Adoptar
              </button>
            )}
            <button type="button" className="btn" disabled={ocupado} onClick={() => setArchivando(true)}>
              Archivar
            </button>
          </div>
        )
      )}
    </li>
  );
}

// ── Salud del sistema (0045) ─────────────────────────────────────────
// Lo que el 2026-10-24 nadie vio a tiempo: GitHub rechazando los disparos
// del ETL y un ciclo de agente fallando un día entero. Todo sale de
// `rpc_salud_sistema`, que solo responde a un admin.
const NOMBRE_WORKFLOW = { "etl-acciones.yml": "ETL de acciones", "etl-cripto.yml": "ETL de cripto" };
const NOMBRE_CLASE = { accion: "Señales de acciones", cripto: "Señales de cripto" };

function FilaSalud({ titulo, chip, detalle }) {
  return (
    <li className="admin__fila">
      <div className="admin__quien">
        <p className="admin__email">{titulo}</p>
        {detalle && <p className="admin__meta">{detalle}</p>}
      </div>
      {chip}
    </li>
  );
}

// 0050: cuándo caduca cada secreto. A 14 días se avisa; tras renovarlo,
// el admin anota la nueva fecha aquí y los avisos se rearman.
const DIAS_AVISO = 14;
const fechaCorta = (dia) => new Date(`${dia}T00:00:00`).toLocaleDateString("es-ES");

function chipCredencial(c) {
  if (c.caduca_en == null) return <Chip etiqueta="Caduca" valor="no caduca" />;
  if (c.dias <= 0) return <Chip etiqueta="Caduca" valor="caducada" tono="neg" />;
  if (c.dias <= DIAS_AVISO) return <Chip etiqueta="Caduca" valor={`en ${c.dias} días`} tono="warn" />;
  return <Chip etiqueta="Caduca" valor={fechaCorta(c.caduca_en)} />;
}

function FilaCredencial({ c, ocupado, alRenovar }) {
  const [abierta, setAbierta] = useState(false);
  const [fecha, setFecha] = useState("");

  function guardar(e) {
    e.preventDefault();
    alRenovar(c.nombre, fecha);
    setAbierta(false);
    setFecha("");
  }

  return (
    <li className="admin__fila">
      <div className="admin__quien">
        <p className="admin__email">{c.nombre}</p>
        <p className="admin__meta">
          {c.donde} · {c.para_que}
          {c.renovada_en && <> · renovada {tiempoRelativo(c.renovada_en)}</>}
        </p>
        {c.caduca_en != null && c.dias <= DIAS_AVISO && <p className="admin__meta">Cómo renovarla: {c.renovar}</p>}
      </div>
      {abierta ? (
        <form className="admin__motivo" onSubmit={guardar}>
          <input
            className="acceso__input"
            type="date"
            autoFocus
            aria-label="Nueva fecha de caducidad (vacía si ya no caduca)"
            value={fecha}
            onChange={(e) => setFecha(e.target.value)}
          />
          <button type="submit" className="btn btn--accent" disabled={ocupado}>
            Guardar
          </button>
          <button type="button" className="btn" onClick={() => setAbierta(false)}>
            Cancelar
          </button>
        </form>
      ) : (
        <div className="admin__acciones">
          {chipCredencial(c)}
          <button type="button" className="btn" disabled={ocupado} onClick={() => setAbierta(true)}>
            Renovada
          </button>
        </div>
      )}
    </li>
  );
}

function PanelSalud({ salud, ocupado, alRenovar }) {
  if (!salud) return null;
  const despachos = salud.despachos ?? [];
  const agentes = salud.agentes ?? [];
  const credenciales = salud.credenciales ?? [];
  const problemas =
    despachos.filter((d) => d.fallando_desde).length +
    agentes.filter((a) => a.en_fallo).length +
    credenciales.filter((c) => c.caduca_en != null && c.dias <= DIAS_AVISO).length;

  return (
    <Panel
      titulo="Salud del sistema"
      flush
      meta={problemas ? `${problemas} con fallos` : "todo responde"}
    >
      <ul className="admin__lista">
        {despachos.map((d) => (
          <FilaSalud
            key={d.workflow}
            titulo={NOMBRE_WORKFLOW[d.workflow] ?? d.workflow}
            chip={
              d.fallando_desde ? (
                <Chip etiqueta="GitHub" valor={`falla · ${d.estado_http ?? "sin respuesta"}`} tono="neg" />
              ) : (
                <Chip etiqueta="GitHub" valor={d.estado_http ? `responde ${d.estado_http}` : "sin revisar"} />
              )
            }
            detalle={
              d.fallando_desde
                ? `Falla desde ${fechaHora(d.fallando_desde)}${d.estado_http === 401 ? " · el token github_pat_altas de Vault ha caducado: renuévalo (RUNBOOK-sprint-4)" : ""}`
                : `Último disparo ${tiempoRelativo(d.ultimo)}`
            }
          />
        ))}
        {(salud.senales ?? []).map((s) => (
          <FilaSalud
            key={s.clase}
            titulo={NOMBRE_CLASE[s.clase] ?? s.clase}
            chip={<Chip etiqueta="Última" valor={tiempoRelativo(s.ultima)} />}
            detalle={`${s.con_senal} de ${s.activos} activos con señal · la más vieja ${tiempoRelativo(s.primera)}`}
          />
        ))}
        {agentes.map((a) => (
          <FilaSalud
            key={a.agente_id}
            titulo={
              <>
                <span className="ag__punto" style={{ background: colorDe(a.nombre) }} aria-hidden="true" />
                Ciclo de {a.nombre}
              </>
            }
            chip={
              a.en_fallo ? (
                <Chip etiqueta="Ciclo" valor="fallando" tono="neg" />
              ) : (
                <Chip etiqueta="Ciclo" valor={a.fallos_24h ? `${a.fallos_24h} fallos en 24 h` : "sin fallos"}
                      tono={a.fallos_24h ? "warn" : "neutro"} />
              )
            }
            detalle={a.ultimo_fallo ? `Último fallo ${tiempoRelativo(a.ultimo_fallo)}: ${a.ultimo_mensaje}` : null}
          />
        ))}
        {credenciales.map((c) => (
          <FilaCredencial key={c.nombre} c={c} ocupado={ocupado} alRenovar={alRenovar} />
        ))}
      </ul>
    </Panel>
  );
}

// ── Backlog de los agentes (H-30) ────────────────────────────────────
function FilaBacklog({ b, ocupado, alRevisar }) {
  const [rechazando, setRechazando] = useState(false);
  const [motivo, setMotivo] = useState("");
  const abierta = ["nuevo", "en_revision", "aceptado"].includes(b.estado);

  function rechazar(e) {
    e.preventDefault();
    alRevisar(b.id, "rechazado", motivo.trim());
    setRechazando(false);
    setMotivo("");
  }

  return (
    <li className="admin__fila">
      <div className="admin__quien">
        <p className="admin__email">
          <span className="ag__etiqueta">{TIPOS_BACKLOG[b.tipo] ?? b.tipo}</span> {b.titulo}
        </p>
        <p className="admin__meta">
          prioridad {b.prioridad} · {b.ocurrencias} ocurrencias · {(b.solicitantes ?? []).join(", ")}
          {" · "}
          {ESTADOS_BACKLOG[b.estado] ?? b.estado}
          {b.resolucion && <> · «{b.resolucion}»</>}
        </p>
        <p className="admin__meta">{b.descripcion}</p>
      </div>
      {rechazando ? (
        <form className="admin__motivo" onSubmit={rechazar}>
          <input
            className="acceso__input"
            autoFocus
            required
            placeholder="Por qué se rechaza (obligatorio)"
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
          />
          <button type="submit" className="btn btn--peligro" disabled={ocupado || !motivo.trim()}>
            Rechazar
          </button>
          <button type="button" className="btn" onClick={() => setRechazando(false)}>
            Cancelar
          </button>
        </form>
      ) : (
        abierta && (
          <div className="admin__acciones">
            {b.estado === "nuevo" && (
              <button type="button" className="btn" disabled={ocupado} onClick={() => alRevisar(b.id, "en_revision")}>
                En revisión
              </button>
            )}
            {b.estado !== "aceptado" && (
              <button type="button" className="btn btn--accent" disabled={ocupado}
                      onClick={() => alRevisar(b.id, "aceptado")}>
                Aceptar
              </button>
            )}
            {b.estado === "aceptado" && (
              <button type="button" className="btn btn--accent" disabled={ocupado}
                      onClick={() => alRevisar(b.id, "implementado")}>
                Marcar implementado
              </button>
            )}
            <button type="button" className="btn" disabled={ocupado} onClick={() => setRechazando(true)}>
              Rechazar
            </button>
          </div>
        )
      )}
    </li>
  );
}

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
  const [agentes, setAgentes] = useState([]);
  const [backlog, setBacklog] = useState([]);
  const [salud, setSalud] = useState(null);
  const [hipotesis, setHipotesis] = useState([]);
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
        .select("id, actor_id, accion, objetivo_tipo, objetivo_id, detalle, creado_en")
        .order("creado_en", { ascending: false })
        .limit(20),
    ]);
    if (u.error || a.error) setError((u.error ?? a.error).message);
    setUsuarios(u.data ?? []);
    setAuditoria(a.data ?? []);
    try {
      const [ag, bl, sa, hi] = await Promise.all([leerRanking(), leerBacklog(),
        // Sin la 0045 aplicada el RPC no existe: el panel no sale, el resto sí.
        leerSalud().catch(() => null),
        leerHipotesis()]);
      setAgentes(ag ?? []);
      setBacklog(bl ?? []);
      setSalud(sa);
      setHipotesis(hi ?? []);
    } catch (err) {
      setError(err.message);
    }
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

  // Los RPC de agentes lanzan con el mensaje ya redactado.
  async function ejecutarAgente(promesa) {
    setOcupado(true);
    setError(null);
    try {
      await promesa();
    } catch (err) {
      setError(err.message);
    }
    setOcupado(false);
    await cargar();
  }

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

        <PanelSalud
          salud={salud}
          ocupado={ocupado}
          alRenovar={(nombre, fecha) => ejecutarAgente(() => renovarCredencial(nombre, fecha))}
        />

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

        <Panel titulo="Agentes" flush meta="nacen en pausa · ponerlos en marcha queda auditado">
          <ul className="admin__lista">
            {agentes.map((a) => (
              <FilaAgente
                key={a.agente_id}
                a={a}
                ocupado={ocupado}
                alCambiar={(id, estado) => ejecutarAgente(() => cambiarEstadoAgente(id, estado))}
                alReiniciar={(id) => ejecutarAgente(() => reiniciarAgente(id))}
                alRevertir={(cuentaId) => ejecutarAgente(() => revertirFase(cuentaId))}
              />
            ))}
          </ul>
        </Panel>

        <Panel
          titulo="Lo que investigan los agentes"
          flush
          meta={`${hipotesis.filter((h) => h.estado === "validada").length} validadas por revisar · adoptar solo lo validado`}
        >
          {hipotesis.length === 0 ? (
            <p className="prosa admin__vacio">Ningún agente ha propuesto todavía una hipótesis.</p>
          ) : (
            <ul className="admin__lista">
              {hipotesis.map((h) => (
                <FilaHipotesis
                  key={h.id}
                  h={h}
                  ocupado={ocupado}
                  alRevisar={(id, estado, resolucion) =>
                    ejecutarAgente(() => revisarHipotesis(id, estado, resolucion))
                  }
                />
              ))}
            </ul>
          )}
        </Panel>

        <Panel
          titulo="Lo que piden los agentes"
          flush
          meta={`${backlog.filter((b) => b.estado === "nuevo").length} nuevas · por ocurrencias × agentes`}
        >
          {backlog.length === 0 ? (
            <p className="prosa admin__vacio">Ningún agente ha pedido nada todavía.</p>
          ) : (
            <ul className="admin__lista">
              {backlog.map((b) => (
                <FilaBacklog
                  key={b.id}
                  b={b}
                  ocupado={ocupado}
                  alRevisar={(id, estado, resolucion) =>
                    ejecutarAgente(() => revisarBacklog(id, estado, resolucion))
                  }
                />
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
                    <strong>
                      {a.detalle?.email ??
                        a.detalle?.agente ??
                        (a.objetivo_tipo === "agente_backlog" ? `#${a.objetivo_id}` : emailDe(a.objetivo_id))}
                    </strong>
                    {a.detalle?.de && a.detalle?.a && <> ({a.detalle.de} → {a.detalle.a})</>}
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
