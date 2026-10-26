import { useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
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

// ── Salud del sistema (0045, 0050) ───────────────────────────────────
// Lo que el 2026-10-24 nadie vio a tiempo: GitHub rechazando los disparos
// del ETL y un ciclo de agente fallando un día entero. Todo sale de
// `rpc_salud_sistema`, que solo responde a un admin. Se parte en tres
// paneles: los datos (ETL y señales), los ciclos y las credenciales.
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
const caducaPronto = (c) => c.caduca_en != null && c.dias <= DIAS_AVISO;

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
        {caducaPronto(c) && <p className="admin__meta">Cómo renovarla: {c.renovar}</p>}
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

/** Cuántas cosas de la salud necesitan atención (para el resumen y las metas). */
function problemasDeSalud(salud) {
  if (!salud) return { datos: 0, ciclos: 0, credenciales: 0, total: 0 };
  const datos = (salud.despachos ?? []).filter((d) => d.fallando_desde).length;
  const ciclos = (salud.agentes ?? []).filter((a) => a.en_fallo).length;
  const credenciales = (salud.credenciales ?? []).filter(caducaPronto).length;
  return { datos, ciclos, credenciales, total: datos + ciclos + credenciales };
}

function SeccionSistema({ salud, ocupado, alRenovar }) {
  if (!salud) {
    return (
      <Panel titulo="Salud del sistema" flush>
        <p className="prosa admin__vacio">No se pudo leer la salud del sistema (¿falta aplicar la 0045?).</p>
      </Panel>
    );
  }
  const p = problemasDeSalud(salud);
  return (
    <>
      <Panel titulo="Datos: ETL y señales" flush meta={p.datos ? `${p.datos} con fallos` : "todo responde"}>
        <ul className="admin__lista">
          {(salud.despachos ?? []).map((d) => (
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
        </ul>
      </Panel>

      <Panel titulo="Ciclos de los agentes" flush meta={p.ciclos ? `${p.ciclos} fallando` : "sin fallos ahora"}>
        <ul className="admin__lista">
          {(salud.agentes ?? []).map((a) => (
            <FilaSalud
              key={a.agente_id}
              titulo={
                <>
                  <span className="ag__punto" style={{ background: colorDe(a.nombre) }} aria-hidden="true" />
                  {a.nombre}
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
        </ul>
      </Panel>

      <Panel
        titulo="Credenciales"
        flush
        meta={p.credenciales ? `${p.credenciales} caducan en ${DIAS_AVISO} días o menos` : "ninguna caduca pronto · solo la fecha, nunca el valor"}
      >
        <ul className="admin__lista">
          {(salud.credenciales ?? []).map((c) => (
            <FilaCredencial key={c.nombre} c={c} ocupado={ocupado} alRenovar={alRenovar} />
          ))}
        </ul>
      </Panel>
    </>
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

// ── Organización de la pantalla ──────────────────────────────────────
// Arriba, lo que espera una decisión del admin; debajo, una pestaña por
// tema. La pestaña va en la URL (`?seccion=`) para poder enlazarla. Las
// listas abren con lo que pide acción; lo cerrado queda a un clic.
const SECCIONES = [
  { id: "sistema", texto: "Sistema" },
  { id: "agentes", texto: "Agentes" },
  { id: "investigacion", texto: "Investigación" },
  { id: "usuarios", texto: "Usuarios" },
  { id: "auditoria", texto: "Auditoría" },
];

const HIPOTESIS_POR_REVISAR = ["validada", "propuesta", "en_prueba", "no_ejecutable"];
const BACKLOG_ABIERTO = ["nuevo", "en_revision", "aceptado"];

function Segmentado({ opciones, valor, alCambiar, etiqueta, rol = "group" }) {
  return (
    <div className="segmented" role={rol} aria-label={etiqueta}>
      {opciones.map((o) => (
        <button key={o.id} type="button" className="segmented__opt"
                role={rol === "tablist" ? "tab" : undefined}
                aria-pressed={valor === o.id}
                aria-selected={rol === "tablist" ? valor === o.id : undefined}
                onClick={() => alCambiar(o.id)}>
          {o.texto}
        </button>
      ))}
    </div>
  );
}

function Pendiente({ titulo, n, detalle, tono, alAbrir }) {
  return (
    <button type="button" className={`admin__pendiente${n ? ` admin__pendiente--${tono}` : ""}`} onClick={alAbrir}>
      <span className="admin__pendiente-n num">{n}</span>
      <span className="admin__pendiente-titulo">{titulo}</span>
      <span className="admin__pendiente-detalle">{detalle}</span>
    </button>
  );
}

/** A quién o a qué se refiere una fila de la auditoría. */
function objetivoAuditoria(a, emailDe) {
  if (a.detalle?.email) return a.detalle.email;
  if (a.detalle?.agente) return a.detalle.agente;
  if (a.objetivo_tipo === "agente_backlog") return `la petición #${a.objetivo_id}`;
  if (a.objetivo_tipo === "agente_hipotesis") return `la hipótesis #${a.objetivo_id}`;
  if (a.objetivo_tipo === "credenciales") return a.objetivo_id;
  if (a.objetivo_tipo === "cuentas_simulacion") return `la cuenta #${a.objetivo_id}`;
  return emailDe(a.objetivo_id);
}

export default function Admin() {
  const { perfil } = useSesion();
  const [params, setParams] = useSearchParams();
  const seccion = SECCIONES.some((s) => s.id === params.get("seccion")) ? params.get("seccion") : "sistema";
  const irA = (id) => setParams({ seccion: id }, { replace: true });

  const [usuarios, setUsuarios] = useState([]);
  const [auditoria, setAuditoria] = useState([]);
  const [agentes, setAgentes] = useState([]);
  const [backlog, setBacklog] = useState([]);
  const [salud, setSalud] = useState(null);
  const [hipotesis, setHipotesis] = useState([]);
  const [filtro, setFiltro] = useState("pendiente");
  const [verHipotesis, setVerHipotesis] = useState("revisar");
  const [verBacklog, setVerBacklog] = useState("abiertas");
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
        .limit(50),
    ]);
    if (u.error || a.error) setError((u.error ?? a.error).message);
    setUsuarios(u.data ?? []);
    setAuditoria(a.data ?? []);
    try {
      const [ag, bl, sa, hi] = await Promise.all([leerRanking(), leerBacklog(),
        // Sin la 0045 aplicada el RPC no existe: la pestaña lo dice, el resto sale.
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

  const hipVisibles = hipotesis.filter((h) =>
    verHipotesis === "todas" ? true
      : verHipotesis === "revisar" ? HIPOTESIS_POR_REVISAR.includes(h.estado)
      : !HIPOTESIS_POR_REVISAR.includes(h.estado));
  const backVisibles = backlog.filter((b) =>
    verBacklog === "todas" ? true
      : verBacklog === "abiertas" ? BACKLOG_ABIERTO.includes(b.estado)
      : !BACKLOG_ABIERTO.includes(b.estado));

  const p = problemasDeSalud(salud);
  const validadas = hipotesis.filter((h) => h.estado === "validada").length;
  const nuevas = backlog.filter((b) => b.estado === "nuevo").length;
  const pendientes = conteo("pendiente");
  const parados = agentes.filter((a) => a.estado === "pausado" || a.estado === "game_over").length;

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

        <Panel titulo="Pendiente de ti" meta={cargando ? "cargando…" : "pulsa una tarjeta para ir a su sección"}>
          <div className="admin__resumen">
            <Pendiente titulo="Salud del sistema" n={p.total} tono="neg"
                       detalle={p.total ? `${p.datos} datos · ${p.ciclos} ciclos · ${p.credenciales} credenciales` : "todo responde"}
                       alAbrir={() => irA("sistema")} />
            <Pendiente titulo="Hipótesis validadas" n={validadas} tono="warn"
                       detalle={validadas ? "adoptar o archivar" : "nada que adoptar"}
                       alAbrir={() => { setVerHipotesis("revisar"); irA("investigacion"); }} />
            <Pendiente titulo="Peticiones nuevas" n={nuevas} tono="warn"
                       detalle={nuevas ? "responder con datos" : "backlog al día"}
                       alAbrir={() => { setVerBacklog("abiertas"); irA("investigacion"); }} />
            <Pendiente titulo="Solicitudes de acceso" n={pendientes} tono="warn"
                       detalle={pendientes ? "aprobar o rechazar" : "ninguna pendiente"}
                       alAbrir={() => { setFiltro("pendiente"); irA("usuarios"); }} />
            <Pendiente titulo="Agentes parados" n={parados} tono="warn"
                       detalle={parados ? "en pausa o en Game Over" : "todos en marcha"}
                       alAbrir={() => irA("agentes")} />
          </div>
        </Panel>

        {error && <p className="acceso__aviso acceso__aviso--neg admin__error" role="alert">{error}</p>}

        <div className="admin__secciones">
          <Segmentado opciones={SECCIONES} valor={seccion} alCambiar={irA} etiqueta="Secciones de administración" rol="tablist" />
        </div>

        {seccion === "sistema" && (
          <SeccionSistema
            salud={salud}
            ocupado={ocupado}
            alRenovar={(nombre, fecha) => ejecutarAgente(() => renovarCredencial(nombre, fecha))}
          />
        )}

        {seccion === "agentes" && (
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
        )}

        {seccion === "investigacion" && (
          <>
            <Panel
              titulo="Lo que investigan los agentes"
              flush
              meta={`${validadas} validadas por revisar · adoptar solo lo validado`}
            >
              <div className="toolbar">
                <Segmentado
                  etiqueta="Filtrar hipótesis"
                  valor={verHipotesis}
                  alCambiar={setVerHipotesis}
                  opciones={[
                    { id: "revisar", texto: `En curso (${hipotesis.filter((h) => HIPOTESIS_POR_REVISAR.includes(h.estado)).length})` },
                    { id: "cerradas", texto: `Cerradas (${hipotesis.filter((h) => !HIPOTESIS_POR_REVISAR.includes(h.estado)).length})` },
                    { id: "todas", texto: "Todas" },
                  ]}
                />
              </div>
              {hipVisibles.length === 0 ? (
                <p className="prosa admin__vacio">
                  {!hipotesis.length ? "Ningún agente ha propuesto todavía una hipótesis."
                    : verHipotesis === "revisar" ? "Ninguna hipótesis en curso: las resueltas están en «Cerradas»."
                    : "Nada en este estado."}
                </p>
              ) : (
                <ul className="admin__lista">
                  {hipVisibles.map((h) => (
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
              meta={`${nuevas} nuevas · por ocurrencias × agentes · durante el experimento las reglas no cambian`}
            >
              <div className="toolbar">
                <Segmentado
                  etiqueta="Filtrar peticiones"
                  valor={verBacklog}
                  alCambiar={setVerBacklog}
                  opciones={[
                    { id: "abiertas", texto: `Abiertas (${backlog.filter((b) => BACKLOG_ABIERTO.includes(b.estado)).length})` },
                    { id: "cerradas", texto: `Cerradas (${backlog.filter((b) => !BACKLOG_ABIERTO.includes(b.estado)).length})` },
                    { id: "todas", texto: "Todas" },
                  ]}
                />
              </div>
              {backVisibles.length === 0 ? (
                <p className="prosa admin__vacio">
                  {!backlog.length ? "Ningún agente ha pedido nada todavía."
                    : verBacklog === "abiertas" ? "Ninguna petición abierta: las respondidas están en «Cerradas»."
                    : "Nada en este estado."}
                </p>
              ) : (
                <ul className="admin__lista">
                  {backVisibles.map((b) => (
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
          </>
        )}

        {seccion === "usuarios" && (
          <Panel
            titulo="Solicitudes de acceso"
            flush
            meta={cargando ? "cargando…" : `${pendientes} pendientes · ${usuarios.length} cuentas`}
          >
            <div className="toolbar">
              <Segmentado opciones={FILTROS.map((f) => ({ id: f.id, texto: f.texto }))} valor={filtro}
                          alCambiar={setFiltro} etiqueta="Filtrar por estado" />
            </div>
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
        )}

        {seccion === "auditoria" && (
          <Panel titulo="Auditoría" meta="últimas 50 acciones de administración" flush>
            {auditoria.length === 0 ? (
              <p className="prosa admin__vacio">Todavía no hay acciones registradas.</p>
            ) : (
              <ul className="admin__auditoria">
                {auditoria.map((a) => (
                  <li key={a.id}>
                    <span className="admin__hora">{fechaHora(a.creado_en)}</span>
                    <span>
                      {emailDe(a.actor_id)} {ACCIONES[a.accion] ?? a.accion}{" "}
                      <strong>{objetivoAuditoria(a, emailDe)}</strong>
                      {a.detalle?.de !== undefined && a.detalle?.a !== undefined && (
                        <> ({a.detalle.de ?? "—"} → {a.detalle.a ?? "no caduca"})</>
                      )}
                      {(a.detalle?.motivo || a.detalle?.resolucion) && <> — «{a.detalle.motivo ?? a.detalle.resolucion}»</>}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        )}
      </main>
    </div>
  );
}
