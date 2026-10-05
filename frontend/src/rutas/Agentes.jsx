import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Marca from "../components/ui/Marca.jsx";
import Panel from "../components/ui/Panel.jsx";
import Navegacion from "../components/Navegacion.jsx";
import HelpDrawer from "../components/HelpDrawer.jsx";
import AvisoLegal from "../components/AvisoLegal.jsx";
import GraficoEquity from "../components/GraficoEquity.jsx";
import { IconoCaret, IconoRefrescar } from "../components/ui/Iconos.jsx";
import { supabase } from "../supabase.js";
import {
  ACCIONES_CICLO,
  ESTADOS_AGENTE,
  ESTADOS_BACKLOG,
  MOTIVOS_DESCARTE,
  TIPOS_BACKLOG,
  VEREDICTOS,
  colorDe,
  TIPOS_DECISION,
  MOTIVOS_DETERIORO,
  LIMITE_OPERACIONES,
  leerAjustes,
  leerBacklog,
  leerCurvas,
  leerDecisiones,
  leerOperaciones,
  leerPracticas,
  leerRanking,
} from "../datos/agentes.js";
import { construirSeries, diasHastaObjetivo } from "../datos/curvas.js";
import { FASES, MOTIVOS_CIERRE } from "../datos/simulador.js";
import { paginar } from "../datos/paginacion.js";
import {
  claseSigno,
  formatearImporte,
  formatearMultiplicador,
  formatearPorcentaje,
  formatearPrecio,
  tiempoRelativo,
} from "../formato.js";

/**
 * Módulo Agentes (Sprint 6, H-31) — requisito 10: ver qué hacen los
 * agentes y por qué.
 *
 * Igual que el simulador, esta pantalla no calcula nada que importe: el
 * marcador, las curvas, el racional y el backlog vienen de vistas. Lo
 * único que se calcula aquí son los días teóricos hasta el millón, que es
 * una cifra de lectura.
 *
 * Se actualiza por Realtime: cada evento etiquetado con un agente (un
 * cierre, una apertura, un corte, una práctica) dispara una relectura. Sin
 * sondeo: si no pasa nada, no se lee nada.
 */
const RELECTURA_TRAS_EVENTO_MS = 1200;

// Filas por página en la tabla de operaciones.
const OPERACIONES_POR_PAGINA = 20;

function Tono({ tono, children }) {
  return <span className={`ag__tono ag__tono--${tono}`}>{children}</span>;
}

// ── Marcador ─────────────────────────────────────────────────────────
// Progreso hacia el millón en escala LOGARÍTMICA: en lineal, 1.000 $ sobre
// 1.000.000 es un 0,1 % de barra y la barra no dice nada durante meses.
function progresoLog(equity, inicial, objetivo) {
  const e = Number(equity);
  const i = Number(inicial);
  const o = Number(objetivo);
  if (!(e > 0 && i > 0 && o > i)) return 0;
  return Math.max(0, Math.min(1, Math.log(e / i) / Math.log(o / i)));
}

// Los parámetros de la 0016, tal como están HOY: los mueve el propio
// agente con lo que aprende (pestaña «Decisiones»). Desde la 0023 el
// reparto no es un parámetro: lo decide cada día su exigencia.
function parametrosLegibles(e) {
  if (!e) return "";
  const reparto =
    "reparte según su exigencia" +
    (e.salida_deterioro === false ? " · no cierra por deterioro" : " · cierra si la señal se deteriora");
  const rota = e.rotacion_umbral != null ? `rota si ≥ ${Number(e.rotacion_umbral)}×` : "no rota";
  const tp = e.tp_parcial
    ? `parcial ${e.tp_parcial.fraccion * 100} % al ${e.tp_parcial.recorrido * 100} %` +
      (e.tp_parcial.mover_stop ? ", stop a la entrada" : "")
    : "sin parciales";
  return `${reparto} · ${rota} · ${tp}`;
}

function TarjetaAgente({ a }) {
  const estado = ESTADOS_AGENTE[a.estado] ?? { texto: a.estado, tono: "neutro" };
  const veredicto = a.ultimo_veredicto ? VEREDICTOS[a.ultimo_veredicto] : null;
  const dias = diasHastaObjetivo(a.equity, a.objetivo_final, a.objetivo_diario_pct);
  const progreso = progresoLog(a.equity, a.saldo_inicial, a.objetivo_final);
  const accion = a.ultima_decision?.accion;

  return (
    <article className="ag__tarjeta" style={{ "--color-agente": colorDe(a.nombre) }}>
      <header className="ag__tarjeta-cabecera">
        <span className="ag__nombre">{a.nombre}</span>
        <span className="ag__meta num">{Number(a.objetivo_diario_pct)} % diario</span>
        <Tono tono={estado.tono}>{estado.texto}</Tono>
      </header>

      <p className="ag__equity num">{a.equity != null ? formatearPrecio(Number(a.equity)) : "—"}</p>
      <div
        className="ag__progreso"
        role="meter"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(progreso * 100)}
        aria-label="Progreso hacia el objetivo final, en escala logarítmica"
      >
        <span style={{ width: `${progreso * 100}%` }} />
      </div>
      <p className="ag__sub">
        <span className="num">{a.pct_hacia_objetivo != null ? `${Number(a.pct_hacia_objetivo).toLocaleString("es-ES", { maximumFractionDigits: 3 })} %` : "—"}</span>{" "}
        de {formatearPrecio(Number(a.objetivo_final))}
        {dias != null && <> · {dias} días de meta cumplida por delante</>}
      </p>

      <dl className="ag__cifras">
        <div>
          <dt>Hoy</dt>
          <dd className="num">
            <span className={claseSigno(Number(a.hoy_pnl ?? 0))}>{formatearImporte(Number(a.hoy_pnl ?? 0))}</span>
            {a.hoy_objetivo != null && <span className="ag__de"> de {formatearPrecio(Number(a.hoy_objetivo))}</span>}
          </dd>
        </div>
        <div>
          <dt>Racha</dt>
          <dd className="num">{a.racha ?? 0} días</dd>
        </div>
        <div>
          <dt>Desde el máximo</dt>
          <dd className={`num ${claseSigno(Number(a.drawdown_pct ?? 0))}`}>
            {formatearPorcentaje(Number(a.drawdown_pct ?? 0))}
          </dd>
        </div>
        <div>
          <dt>Operaciones</dt>
          <dd className="num">
            {a.cerradas ?? 0}
            <span className="ag__de"> · {a.en_tp ?? 0} obj / {a.en_sl ?? 0} stop</span>
          </dd>
        </div>
        <div>
          <dt>Abiertas</dt>
          <dd className="num">{a.posiciones_abiertas ?? 0}</dd>
        </div>
        <div>
          <dt>Último corte</dt>
          <dd>
            {veredicto ? (
              <Tono tono={veredicto.tono}>{veredicto.texto}</Tono>
            ) : (
              <span className="ag__de">sin cortes aún</span>
            )}
          </dd>
        </div>
      </dl>

      <footer className="ag__pie">
        <span>{FASES[a.fase] ?? a.fase} · tope {formatearMultiplicador(Number(a.leverage_tope))}x</span>
        <span>riesgo {Number(a.riesgo_pct_operacion)} %{a.riesgo_reducido ? " (reducido)" : ""}</span>
        <span>{parametrosLegibles(a.estrategia)}</span>
        {a.hoy_cumplido && <span className="ag__cumplido">meta de hoy cumplida</span>}
        {accion && a.ultimo_ciclo_en && (
          <span>
            {ACCIONES_CICLO[accion] ?? accion} · {tiempoRelativo(a.ultimo_ciclo_en)}
          </span>
        )}
      </footer>
    </article>
  );
}

// ── Racional de una orden ────────────────────────────────────────────
function Racional({ r, o }) {
  if (!r) return <p className="detail__motivo">Esta orden no guarda racional.</p>;
  // Riesgo con el que se abrió frente al que declara la estrategia. Solo
  // supera lo declarado por el mínimo de una acción entera (0017), y nunca
  // el 10 % del equity (G2).
  const stop = Number(o?.sl_original ?? o?.sl);
  const cantidadInicial = Number(r.elegido?.cantidad ?? o?.cantidad);
  const riesgo = o ? cantidadInicial * (Number(o.precio_entrada) - stop) : null;
  const riesgoPct = riesgo != null && Number(r.equity) > 0 ? (riesgo / Number(r.equity)) * 100 : null;
  const declarado = Number(r.parametros?.riesgo_pct_operacion);
  const elegido = r.elegido ?? {};
  const descartes = Object.entries(r.descartes_por_motivo ?? {}).filter(([m]) => m !== "candidata");
  return (
    <div className="detail__box">
      <div className="detail__col">
        <p className="label">Por qué esta</p>
        {r.reparto && typeof r.reparto === "object" ? (
          // 0023: el agente marca según su exigencia y abre todas a la vez.
          <>
            <p className="detail__motivo">
              Faltaban <strong>{formatearPrecio(Number(r.deficit_pendiente))}</strong> para la meta de{" "}
              {formatearPrecio(Number(r.objetivo_importe))}. De <strong>{r.candidatos_evaluados}</strong>{" "}
              candidatos
              {r.candidatos_antes_practicas !== r.candidatos_evaluados &&
                ` (${r.candidatos_antes_practicas} antes de aplicar sus prácticas)`}{" "}
              marcó <strong>{r.reparto.marcadas}</strong>
              {r.marcadas?.length > 0 && ` (${r.marcadas.map((m) => m.simbolo).join(", ")})`}:{" "}
              {r.reparto.modo === "cubre_meta"
                ? `las que más reparten sin dejar de cubrir la meta si llegan al objetivo (${formatearPrecio(
                    Number(r.reparto.ganancia_objetivo)
                  )}).`
                : `ninguna combinación cubría la meta, así que concentró en la de más ganancia (${formatearPrecio(
                    Number(r.reparto.ganancia_objetivo)
                  )} en objetivo).`}
            </p>
            <p className="detail__motivo">
              A esta le tocó una parte de {formatearPrecio(Number(elegido.parte))} de{" "}
              {formatearPrecio(Number(r.saldo_libre))} libres (peso{" "}
              {formatearMultiplicador(Number(elegido.apalancamiento))}x) y consume{" "}
              {formatearPrecio(Number(elegido.consumo))} del saldo para operar. Estrategia v
              {r.version_estrategia}
              {r.practicas_aplicadas?.length > 0 && `, con las prácticas ${r.practicas_aplicadas.map((p) => `#${p}`).join(", ")}`}.
            </p>
          </>
        ) : (
          <>
            <p className="detail__motivo">
              Faltaban <strong>{formatearPrecio(Number(r.deficit_pendiente))}</strong> para la meta de{" "}
              {formatearPrecio(Number(r.objetivo_importe))} con un equity de{" "}
              {formatearPrecio(Number(r.equity))}. De <strong>{r.candidatos_evaluados}</strong>{" "}
              candidatos
              {r.candidatos_antes_practicas !== r.candidatos_evaluados &&
                ` (${r.candidatos_antes_practicas} antes de aplicar sus prácticas)`}
              , fue la primera por R:R ({Number(elegido.ratio_rr).toFixed(2)}), fuerza {elegido.fuerza} y
              dominancia neta {elegido.dominancia_neta}.
            </p>
            <p className="detail__motivo">
              Pidió {formatearMultiplicador(Number(elegido.apalancamiento_pedido))}x y el dimensionado dio{" "}
              {formatearMultiplicador(Number(elegido.apalancamiento))}x con{" "}
              {formatearPrecio(Number(elegido.margen))} de margen. Estrategia v{r.version_estrategia}
              {r.practicas_aplicadas?.length > 0 && `, con las prácticas ${r.practicas_aplicadas.map((p) => `#${p}`).join(", ")}`}.
            </p>
          </>
        )}
        {riesgoPct != null && Number.isFinite(riesgoPct) && (
          <p className="detail__motivo">
            Riesgo hasta el stop al abrir: {formatearPrecio(riesgo)} ({riesgoPct.toFixed(1)} % del equity;
            declara {declarado} %).
            {riesgoPct > declarado + 0.05 &&
              " Por encima de lo declarado porque su riesgo no llegaba para una acción entera: compró una, dentro del 10 % que admite el servidor."}
          </p>
        )}
        {r.rechazos_servidor?.length > 0 && (
          <p className="detail__motivo">
            Antes, el servidor rechazó:{" "}
            {r.rechazos_servidor.map((x) => `${x.simbolo} (${x.motivo})`).join("; ")}.
          </p>
        )}
      </div>
      <div className="detail__col">
        <p className="label">Qué descartó</p>
        {r.descartados_top3?.length > 0 ? (
          <ul className="ag__descartes">
            {r.descartados_top3.map((d) => (
              <li key={d.simbolo}>
                <span className="sim__ticker">{d.simbolo}</span>
                <span className="ag__de">
                  {MOTIVOS_DESCARTE[d.motivo] ?? d.motivo}
                  {d.ratio_rr != null && ` · R:R ${Number(d.ratio_rr).toFixed(2)}`}
                </span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="detail__motivo">Nada que descartar: era la única señal fresca.</p>
        )}
        {descartes.length > 0 && (
          <p className="detail__motivo">
            Universo: {descartes.map(([m, n]) => `${n} ${MOTIVOS_DESCARTE[m] ?? m}`).join(" · ")}.
          </p>
        )}
      </div>
    </div>
  );
}

function FilaOperacion({ o, abierta, alAbrir }) {
  const parciales = Number(o.pnl_parciales ?? 0);
  const pnl = o.estado === "abierta" ? o.pnl_flotante : Number(o.pnl_bruto) + parciales;
  return (
    <>
      <tr className={`row${abierta ? " row--abierta" : ""}`}>
        <td>
          <span className="ag__punto" style={{ background: colorDe(o.agente) }} aria-hidden="true" />
          {o.agente}
        </td>
        <td>
          <span className="sim__ticker">{o.simbolo}</span>
          <span className="sim__sub">{tiempoRelativo(o.fecha_entrada)}</span>
        </td>
        <td className="num">{formatearPrecio(Number(o.precio_entrada))}</td>
        <td className="num">
          {o.consumo_saldo != null ? formatearPrecio(Number(o.consumo_saldo)) : "—"}
          <span className="sim__sub">
            {o.estado === "abierta" && Number(o.saldo_operar) > 0
              ? `${((Number(o.consumo_saldo) / Number(o.saldo_operar)) * 100).toFixed(1)} % · `
              : ""}
            a {formatearMultiplicador(Number(o.apalancamiento))}x
          </span>
        </td>
        <td className="num">
          <span className="neg">{formatearPrecio(Number(o.sl))}</span>
          {" / "}
          <span className="pos">{formatearPrecio(Number(o.tp))}</span>
        </td>
        <td>
          {o.estado === "abierta" ? (
            <span className="ag__de">abierta</span>
          ) : (
            <span className={`sim__motivo sim__motivo--${o.motivo_cierre}`}>
              {MOTIVOS_CIERRE[o.motivo_cierre] ?? o.motivo_cierre}
            </span>
          )}
        </td>
        <td className={`num ${claseSigno(Number(pnl))}`}>
          {pnl != null ? formatearImporte(Number(pnl)) : "—"}
          {o.estado === "cerrada" && <span className="sim__sub">{formatearPorcentaje(Number(o.pnl_pct))}</span>}
          {parciales !== 0 && <span className="sim__sub">{formatearImporte(parciales)} en parciales</span>}
        </td>
        <td style={{ width: 44 }}>
          <button
            type="button"
            className="btn btn--icon"
            onClick={alAbrir}
            aria-expanded={abierta}
            title={abierta ? "Ocultar el racional" : "Por qué la eligió"}
          >
            <IconoCaret style={{ transform: abierta ? "rotate(180deg)" : "none" }} />
            <span className="sr-only">Racional de la orden {o.id}</span>
          </button>
        </td>
      </tr>
      {abierta && (
        <tr className="detail">
          <td colSpan={8}>
            <Racional r={o.racional} o={o} />
          </td>
        </tr>
      )}
    </>
  );
}

// ── Pestañas de lectura ──────────────────────────────────────────────
function TablaBacklog({ filas }) {
  if (filas.length === 0) {
    return (
      <p className="sim__nota">
        Ningún agente ha pedido nada todavía. Cada petición nace de un disparador que observa una
        limitación real y llega con su evidencia; sin ella, la base de datos no la admite.
      </p>
    );
  }
  return (
    <table className="sim__tabla">
      <thead>
        <tr>
          <th className="num">Prioridad</th>
          <th>Petición</th>
          <th>Quién</th>
          <th className="num">Ocurrencias</th>
          <th>Estado</th>
        </tr>
      </thead>
      <tbody>
        {filas.map((b) => (
          <tr key={b.id}>
            <td className="num">{b.prioridad}</td>
            <td>
              <span className="ag__etiqueta">{TIPOS_BACKLOG[b.tipo] ?? b.tipo}</span> {b.titulo}
              <span className="sim__sub">{b.descripcion}</span>
              {b.resolucion && <span className="sim__sub">Resolución: {b.resolucion}</span>}
            </td>
            <td>{(b.solicitantes ?? []).join(", ")}</td>
            <td className="num">{b.ocurrencias}</td>
            <td>{ESTADOS_BACKLOG[b.estado] ?? b.estado}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function TablaPracticas({ filas }) {
  if (filas.length === 0) {
    return (
      <p className="sim__nota">
        Aún no hay prácticas. Un agente publica una cuando reúne al menos tres operaciones con la
        misma firma, dos de cada tres en objetivo y P&amp;L medio positivo.
      </p>
    );
  }
  return (
    <table className="sim__tabla">
      <thead>
        <tr>
          <th>Práctica</th>
          <th>Autor</th>
          <th className="num">Respaldo</th>
          <th className="num">Valoración</th>
          <th>Adoptada por</th>
          <th>Estado</th>
        </tr>
      </thead>
      <tbody>
        {filas.map((p) => (
          <tr key={p.id} className={p.estado === "refutada" ? "ag__refutada" : undefined}>
            <td>
              {p.sentido === "evitar" && <span className="ag__etiqueta ag__etiqueta--evitar">evitar</span>}
              {p.titulo}
              <span className="sim__sub">{p.regla}</span>
            </td>
            <td>
              {p.autor}
              {p.coautores?.length > 0 && <span className="sim__sub">respaldada por {p.coautores.join(", ")}</span>}
            </td>
            <td className="num">
              {p.resultado_observado?.ops} ops · {Math.round(Number(p.confianza) * 100)} %
            </td>
            <td className="num">
              {p.valoracion > 0 ? `+${p.valoracion}` : p.valoracion}
              <span className="sim__sub">{p.votos} votos</span>
            </td>
            <td>{(p.adoptantes ?? []).filter(Boolean).join(", ") || "—"}</td>
            <td>{p.estado}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function TablaDecisiones({ decisiones, ajustes }) {
  return (
    <>
      {ajustes.length > 0 && (
        <table className="sim__tabla">
          <thead>
            <tr>
              <th>Ajuste</th>
              <th>Agente</th>
              <th>De → a</th>
              <th>Evidencia</th>
              <th>Cuándo</th>
            </tr>
          </thead>
          <tbody>
            {ajustes.map((j) => (
              <tr key={j.id}>
                <td>{TIPOS_DECISION[j.tipo] ?? j.tipo}</td>
                <td>{j.agente}</td>
                <td className="num">
                  {JSON.stringify(j.de)} → {JSON.stringify(j.a)}
                </td>
                <td className="sim__sub">
                  {Object.entries(j.evidencia ?? {})
                    .map(([k, v]) => `${k.replace(/_/g, " ")}: ${v}`)
                    .join(" · ")}
                </td>
                <td className="sim__sub">{tiempoRelativo(j.creado_en)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {decisiones.length === 0 ? (
        <p className="sim__nota">
          Todavía no hay decisiones juzgadas. Cada rotación, toma parcial y apertura se compara con lo
          que habría pasado sin ella; con 10 resueltas de un tipo, el agente mueve su parámetro un paso.
        </p>
      ) : (
        <table className="sim__tabla">
          <thead>
            <tr>
              <th>Decisión</th>
              <th>Agente</th>
              <th>Activo</th>
              <th className="num">Efecto</th>
              <th>Estado</th>
            </tr>
          </thead>
          <tbody>
            {decisiones.map((d) => (
              <tr key={d.id}>
                <td>
                  {TIPOS_DECISION[d.tipo] ?? d.tipo}
                  {d.tipo === "reparto" && (
                    <span className="sim__sub">
                      {d.parametro?.modo
                        ? `${d.parametro.modo === "cubre_meta" ? "cubre la meta" : "máxima ganancia"} · ${d.parametro.marcadas} marcadas`
                        : d.parametro?.reparto}
                    </span>
                  )}
                  {d.tipo === "deterioro" && d.datos?.motivo && (
                    <span className="sim__sub">
                      {MOTIVOS_DETERIORO[d.datos.motivo] ?? d.datos.motivo}
                      {d.datos.fuerza_entrada && d.datos.fuerza_nueva && d.datos.motivo === "fuerza"
                        ? ` (${d.datos.fuerza_entrada} → ${d.datos.fuerza_nueva})`
                        : ""}
                    </span>
                  )}
                  {d.tipo === "rotacion" && d.datos?.candidato && (
                    <span className="sim__sub">
                      por {d.datos.candidato.simbolo} (R:R {Number(d.datos.candidato.ratio_rr).toFixed(2)} frente a{" "}
                      {Number(d.datos.rr_restante).toFixed(2)} restante)
                    </span>
                  )}
                </td>
                <td>{d.agente}</td>
                <td>{d.simbolo ?? "—"}</td>
                {/* En dólares para rotación y parcial; en % sobre el margen
                    para reparto. Positivo = la decisión acertó. */}
                <td className={`num ${d.efecto != null ? claseSigno(Number(d.efecto)) : ""}`}>
                  {d.efecto == null
                    ? "—"
                    : d.tipo === "reparto"
                      ? formatearPorcentaje(Number(d.efecto))
                      : formatearImporte(Number(d.efecto))}
                </td>
                <td className="sim__sub">
                  {d.resuelta_en ? `resuelta ${tiempoRelativo(d.resuelta_en)}` : "pendiente"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

// ── Pantalla ─────────────────────────────────────────────────────────
export default function Agentes() {
  const [ranking, setRanking] = useState([]);
  const [curvas, setCurvas] = useState([]);
  const [operaciones, setOperaciones] = useState([]);
  const [backlog, setBacklog] = useState([]);
  const [practicas, setPracticas] = useState([]);
  const [decisiones, setDecisiones] = useState([]);
  const [ajustes, setAjustes] = useState([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState(null);
  const [enVivo, setEnVivo] = useState(false);
  const [filtroAgente, setFiltroAgente] = useState("todos");
  const [filtroEstado, setFiltroEstado] = useState("todas");
  const [filtroMotivo, setFiltroMotivo] = useState("todos");
  const [abierta, setAbierta] = useState(null);
  const [pagina, setPagina] = useState(1);
  const [pestana, setPestana] = useState("backlog");
  const [seccionGuia, setSeccionGuia] = useState(null);
  const temporizador = useRef(null);

  const cargar = useCallback(async () => {
    try {
      const [r, c, o, b, p, d, j] = await Promise.all([
        leerRanking(),
        leerCurvas(),
        leerOperaciones(),
        leerBacklog(),
        leerPracticas(),
        leerDecisiones(),
        leerAjustes(),
      ]);
      setRanking(r ?? []);
      setCurvas(c ?? []);
      setOperaciones(o ?? []);
      setBacklog(b ?? []);
      setPracticas(p ?? []);
      setDecisiones(d ?? []);
      setAjustes(j ?? []);
      setError(null);
    } catch (err) {
      setError(err.message);
    } finally {
      setCargando(false);
    }
  }, []);

  useEffect(() => {
    cargar();
  }, [cargar]);

  // Realtime: un evento de agente es la señal de que algo cambió. Se
  // agrupan los que llegan juntos (un cierre deja varios) en una sola
  // relectura.
  useEffect(() => {
    if (!supabase) return undefined;
    const canal = supabase
      .channel("agentes-eventos")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "eventos_sistema" },
        (cambio) => {
          if (cambio.new?.agente_id == null) return;
          clearTimeout(temporizador.current);
          temporizador.current = setTimeout(cargar, RELECTURA_TRAS_EVENTO_MS);
        }
      )
      .subscribe((estado) => setEnVivo(estado === "SUBSCRIBED"));
    return () => {
      clearTimeout(temporizador.current);
      supabase.removeChannel(canal);
    };
  }, [cargar]);

  const series = useMemo(() => construirSeries(curvas, ranking), [curvas, ranking]);

  const motivos = useMemo(
    () => [...new Set(operaciones.map((o) => o.motivo_cierre).filter(Boolean))],
    [operaciones]
  );
  const visibles = useMemo(
    () =>
      operaciones.filter(
        (o) =>
          (filtroAgente === "todos" || o.agente === filtroAgente) &&
          (filtroEstado === "todas" || o.estado === filtroEstado) &&
          (filtroMotivo === "todos" || o.motivo_cierre === filtroMotivo)
      ),
    [operaciones, filtroAgente, filtroEstado, filtroMotivo]
  );
  // Un filtro nuevo empieza por la primera página.
  useEffect(() => setPagina(1), [filtroAgente, filtroEstado, filtroMotivo]);
  const pag = paginar(visibles, pagina, OPERACIONES_POR_PAGINA);

  const pausados = ranking.filter((a) => a.estado === "pausado").length;

  return (
    <div className="app">
      <header className="chrome">
        <div className="chrome__brand">
          <Marca />
          <div className="chrome__wordmark">
            <span className="chrome__title">Dashboard Financiero</span>
            <span className="chrome__subtitle">Agentes</span>
          </div>
        </div>
        <span className="chrome__rule" aria-hidden="true" />
      </header>

      <main className="main">
        <Navegacion />
        <AvisoLegal />

        {error && (
          <p className="acceso__aviso acceso__aviso--neg sim__aviso" role="alert">
            {error}
          </p>
        )}

        <div className="sim__cuerpo">
          <Panel
            titulo="Marcador"
            meta={
              cargando
                ? "cargando…"
                : pausados === ranking.length && ranking.length > 0
                  ? "los tres en pausa: los pone en marcha un administrador"
                  : "500 $ ficticios cada uno, hacia 1.000.000 $"
            }
            alPedirAyuda={() => setSeccionGuia("agentes")}
            acciones={
              <>
                <span className={`ag__vivo${enVivo ? " is-vivo" : ""}`}>
                  {enVivo ? "en vivo" : "sin conexión"}
                </span>
                <button type="button" className="btn btn--icon" onClick={cargar} title="Refrescar">
                  <IconoRefrescar />
                  <span className="sr-only">Refrescar</span>
                </button>
              </>
            }
          >
            <div className="ag__marcador">
              {ranking.map((a) => (
                <TarjetaAgente key={a.agente_id} a={a} />
              ))}
            </div>
          </Panel>

          <Panel
            titulo="Equity frente a la meta"
            meta="real y teórica por agente · escala logarítmica"
            alPedirAyuda={() => setSeccionGuia("agentes")}
          >
            <GraficoEquity series={series} />
          </Panel>

          <Panel
            titulo="Operaciones"
            meta={`${visibles.length} de ${operaciones.length}${
              operaciones.length >= LIMITE_OPERACIONES ? " (las más recientes)" : ""
            }`}
            flush
            pie={
              <>
                <span className="sim__nota sim__nota--pie">
                  Despliega una fila para leer por qué el agente eligió esa operación y qué descartó.
                </span>
                {pag.paginas > 1 && (
                  <nav className="ag__paginas" aria-label="Páginas de operaciones">
                    <button
                      type="button"
                      className="btn"
                      disabled={pag.pagina === 1}
                      onClick={() => setPagina(pag.pagina - 1)}
                    >
                      ‹ Más recientes
                    </button>
                    <span className="ag__paginas-tramo">
                      {pag.desde}–{pag.hasta} de {visibles.length}
                    </span>
                    <button
                      type="button"
                      className="btn"
                      disabled={pag.pagina === pag.paginas}
                      onClick={() => setPagina(pag.pagina + 1)}
                    >
                      Anteriores ›
                    </button>
                  </nav>
                )}
              </>
            }
          >
            <div className="toolbar">
              <div className="segmented" role="group" aria-label="Filtrar por agente">
                {["todos", ...ranking.map((a) => a.nombre)].map((n) => (
                  <button
                    key={n}
                    type="button"
                    className="segmented__opt"
                    aria-pressed={filtroAgente === n}
                    onClick={() => setFiltroAgente(n)}
                  >
                    {n === "todos" ? "Todos" : n}
                  </button>
                ))}
              </div>
              <div className="segmented" role="group" aria-label="Filtrar por estado">
                {[
                  ["todas", "Todas"],
                  ["abierta", "Abiertas"],
                  ["cerrada", "Cerradas"],
                ].map(([id, texto]) => (
                  <button
                    key={id}
                    type="button"
                    className="segmented__opt"
                    aria-pressed={filtroEstado === id}
                    onClick={() => setFiltroEstado(id)}
                  >
                    {texto}
                  </button>
                ))}
              </div>
              <label className="ag__select">
                <span className="label">Motivo de cierre</span>
                <select value={filtroMotivo} onChange={(e) => setFiltroMotivo(e.target.value)}>
                  <option value="todos">todos</option>
                  {motivos.map((m) => (
                    <option key={m} value={m}>
                      {MOTIVOS_CIERRE[m] ?? m}
                    </option>
                  ))}
                </select>
              </label>
            </div>

            {visibles.length === 0 ? (
              <p className="prosa admin__vacio">
                {operaciones.length === 0
                  ? "Todavía no hay operaciones de agentes."
                  : "Ninguna operación con estos filtros."}
              </p>
            ) : (
              <table className="sim__tabla">
                <thead>
                  <tr>
                    <th>Agente</th>
                    <th>Activo</th>
                    <th className="num">Entrada</th>
                    <th className="num">Del saldo</th>
                    <th className="num">Stop / Objetivo</th>
                    <th>Cierre</th>
                    <th className="num">P&amp;L</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {pag.filas.map((o) => (
                    <FilaOperacion
                      key={o.id}
                      o={o}
                      abierta={abierta === o.id}
                      alAbrir={() => setAbierta((v) => (v === o.id ? null : o.id))}
                    />
                  ))}
                </tbody>
              </table>
            )}
          </Panel>

          <Panel
            titulo={
              pestana === "backlog"
                ? "Lo que piden los agentes"
                : pestana === "practicas"
                  ? "Prácticas compartidas"
                  : "Decisiones y lo que aprendieron"
            }
            meta={
              pestana === "backlog"
                ? "ordenado por ocurrencias × agentes que lo piden"
                : pestana === "practicas"
                  ? "ordenadas por efecto medido · también los errores a evitar"
                  : "cada decisión frente a lo que habría pasado sin ella"
            }
            flush
            alPedirAyuda={() => setSeccionGuia("agentes")}
          >
            <div className="toolbar">
              <div className="segmented" role="tablist" aria-label="Tablas de los agentes">
                {[
                  ["backlog", `Backlog (${backlog.length})`],
                  ["practicas", `Prácticas (${practicas.length})`],
                  ["decisiones", `Decisiones (${decisiones.length})`],
                ].map(([id, texto]) => (
                  <button
                    key={id}
                    type="button"
                    role="tab"
                    className="segmented__opt"
                    aria-pressed={pestana === id}
                    aria-selected={pestana === id}
                    onClick={() => setPestana(id)}
                  >
                    {texto}
                  </button>
                ))}
              </div>
            </div>
            {pestana === "backlog" ? (
              <TablaBacklog filas={backlog} />
            ) : pestana === "practicas" ? (
              <TablaPracticas filas={practicas} />
            ) : (
              <TablaDecisiones decisiones={decisiones} ajustes={ajustes} />
            )}
          </Panel>
        </div>
      </main>

      {seccionGuia && (
        <HelpDrawer seccionInicial={seccionGuia} alCerrar={() => setSeccionGuia(null)} />
      )}
    </div>
  );
}
