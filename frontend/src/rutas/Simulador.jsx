import { useCallback, useEffect, useMemo, useState } from "react";
import Marca from "../components/ui/Marca.jsx";
import Panel from "../components/ui/Panel.jsx";
import Navegacion from "../components/Navegacion.jsx";
import MedidorConfluencia from "../components/ui/MedidorConfluencia.jsx";
import RielRiesgo from "../components/ui/RielRiesgo.jsx";
import BarraApalancamiento from "../components/ui/BarraApalancamiento.jsx";
import HelpDrawer from "../components/HelpDrawer.jsx";
import AvisoLegal from "../components/AvisoLegal.jsx";
import { IconoRefrescar, IconoCerrar, IconoAlerta } from "../components/ui/Iconos.jsx";
import {
  ESTADOS_CUENTA,
  FASES,
  MOTIVOS_CIERRE,
  SALDO_MAX,
  SALDO_MIN,
  TIPOS_MOVIMIENTO,
  RANGOS_CUENTA,
  abrirOrden,
  admiteFracciones,
  configurarCuenta,
  cerrarParcial,
  cerrarOrden,
  crearCuenta,
  leerCuenta,
  leerMovimientos,
  leerOrdenes,
  leerRecomendaciones,
  repartirSaldo,
} from "../datos/simulador.js";
import { consumoDelSaldo, pctDelSaldo, saldoLibre } from "../datos/saldoOperar.js";
import {
  claseSigno,
  formatearImporte,
  formatearMultiplicador,
  formatearPorcentaje,
  formatearPrecio,
  formatearTope,
  tiempoRelativo,
} from "../formato.js";

/**
 * Módulo Simulador (Sprint 5).
 *
 * TRES COSAS QUE ESTA PANTALLA NO HACE, Y SON LAS QUE LA DEFINEN
 *
 * 1. No calcula nada. El tamaño de la posición, el apalancamiento, el
 *    precio de liquidación y el P&L vienen de PostgreSQL. Si el navegador
 *    propusiera el tamaño, los guardarraíles G2 y G3 serían una sugerencia.
 * 2. No deja tocar los niveles. El usuario ajusta PRECIO DE ENTRADA y
 *    FECHA (requisito 6). El stop y el objetivo son del motor: editarlos
 *    convertiría el simulador en una hoja de cálculo con colores.
 * 3. No cierra posiciones. Eso lo hace el monitor cada minuto, solo. El
 *    botón de cerrar a mano existe para salir antes, no para vigilar.
 *
 * El refresco es por sondeo cada 30 s mientras haya posiciones abiertas.
 * Los cierres llegan además al registro de eventos por Realtime (H-32).
 */
const RELECTURA_MS = 30000;

// ── Declarar el saldo inicial ────────────────────────────────────────
function AltaDeCuenta({ alCrear, avisar }) {
  const [saldo, setSaldo] = useState("1000");
  const [ocupado, setOcupado] = useState(false);

  async function enviar(e) {
    e.preventDefault();
    const valor = Number(saldo);
    if (!Number.isFinite(valor) || valor < SALDO_MIN || valor > SALDO_MAX) {
      avisar(`El saldo inicial va de ${SALDO_MIN} a ${SALDO_MAX} dólares ficticios.`, "neg");
      return;
    }
    setOcupado(true);
    try {
      await crearCuenta(valor);
      avisar("Cuenta creada. El saldo es el primer apunte de tu libro mayor.", "ok");
      alCrear();
    } catch (error) {
      avisar(error.message, "neg");
    } finally {
      setOcupado(false);
    }
  }

  return (
    <form className="sim__alta" onSubmit={enviar}>
      <p className="sim__alta-texto">
        Declara el saldo con el que quieres empezar. <strong>Es dinero ficticio</strong>: este
        módulo no se conecta a ningún bróker, no mueve nada y no puede. Lo que simula es la
        disciplina —tamaño de posición, margen comprometido, stop y objetivo—, que es la parte
        que se aprende.
      </p>
      <div className="sim__alta-campos">
        <label className="field sim__campo">
          <span className="label">Saldo inicial ($)</span>
          <input
            type="number"
            min={SALDO_MIN}
            max={SALDO_MAX}
            step="50"
            value={saldo}
            onChange={(e) => setSaldo(e.target.value)}
            inputMode="decimal"
          />
        </label>
        <button type="submit" className="btn btn--accent" disabled={ocupado}>
          {ocupado ? "Creando…" : "Abrir cuenta de simulación"}
        </button>
      </div>
      <p className="sim__nota">
        Entre {SALDO_MIN} y {SALDO_MAX} $. Los agentes arrancan con 500 $, así que ese valor hace
        tus resultados comparables con los suyos.
      </p>
    </form>
  );
}

// ── Confirmación de orden ────────────────────────────────────────────
// Dos campos y solo dos. El resto de la ficha es de lectura: son los
// números que el servidor ya ha decidido y que el usuario acepta o no.
function Confirmacion({ fila, reparto, cuenta, alConfirmar, alCancelar, avisar }) {
  const [precio, setPrecio] = useState(String(Number(fila.precio_actual)));
  // La sugerida es la de su parte del reparto (0022); el usuario manda.
  // Las acciones van en unidades enteras.
  const sugerida = reparto?.cantidad ?? fila.cantidad;
  const [cantidad, setCantidad] = useState(sugerida != null ? String(Number(sugerida)) : "");
  const [fecha, setFecha] = useState(() => new Date().toISOString().slice(0, 16));
  const [ocupado, setOcupado] = useState(false);

  const precioNum = Number(precio);
  const tp = Number(fila.tp);
  const sl = Number(fila.sl);
  const encuadra = Number.isFinite(precioNum) && precioNum > sl && precioNum < tp;
  const rr = encuadra ? (tp - precioNum) / (precioNum - sl) : null;
  const fracciones = admiteFracciones(fila.clase);
  const cantidadNum = Number(cantidad);
  const cantidadValida =
    Number.isFinite(cantidadNum) && cantidadNum > 0 && (fracciones || Number.isInteger(cantidadNum));
  // Estimación para leer, no para decidir: el servidor recalcula el margen.
  const apal = Number(fila.apalancamiento);
  const margenEstimado = cantidadValida && apal > 0 ? (cantidadNum * precioNum) / apal : null;
  const tope = Number(cuenta?.leverage_tope);
  const consumoEstimado = consumoDelSaldo(margenEstimado, tope);
  const pctEstimado = pctDelSaldo(consumoEstimado, cuenta?.saldo_operar);
  const riesgoEstimado = cantidadValida && encuadra ? cantidadNum * (precioNum - sl) : null;

  async function enviar(e) {
    e.preventDefault();
    setOcupado(true);
    try {
      const r = await abrirOrden({
        cuentaId: fila.cuenta_id,
        senalId: fila.senal_id,
        precioEntrada: precioNum,
        fechaEntrada: new Date(fecha).toISOString(),
        cantidad: cantidadNum,
      });
      avisar(
        `Orden abierta en ${r.simbolo}: ${r.cantidad} unidades a ${formatearMultiplicador(
          Number(r.apalancamiento)
        )}x con ${formatearPrecio(Number(r.margen))} de margen.` +
          (r.apalancamiento_reducido
            ? " El apalancamiento se ha reducido para que la liquidación quede por debajo de tu stop."
            : ""),
        "ok"
      );
      alConfirmar();
    } catch (error) {
      avisar(error.message, "neg");
    } finally {
      setOcupado(false);
    }
  }

  return (
    <form className="sim__confirmar" onSubmit={enviar}>
      <div className="sim__confirmar-cabecera">
        <span className="sim__ticker">{fila.simbolo}</span>
        <span className="sim__confirmar-titulo">Confirmar entrada</span>
        <button type="button" className="btn btn--icon" onClick={alCancelar} title="Cancelar">
          <IconoCerrar />
          <span className="sr-only">Cancelar</span>
        </button>
      </div>

      <div className="sim__confirmar-campos">
        <label className="field sim__campo">
          <span className="label">Tu precio de entrada</span>
          <input
            type="number"
            step="any"
            min="0"
            value={precio}
            onChange={(e) => setPrecio(e.target.value)}
            inputMode="decimal"
          />
        </label>
        <label className="field sim__campo">
          <span className="label">{fracciones ? "Cantidad" : "Acciones (enteras)"}</span>
          <input
            type="number"
            step={fracciones ? "any" : "1"}
            min="0"
            value={cantidad}
            onChange={(e) => setCantidad(e.target.value)}
            inputMode={fracciones ? "decimal" : "numeric"}
          />
        </label>
        <label className="field sim__campo">
          <span className="label">Fecha de entrada</span>
          <input
            type="datetime-local"
            value={fecha}
            max={new Date().toISOString().slice(0, 16)}
            onChange={(e) => setFecha(e.target.value)}
          />
        </label>
      </div>

      {/* Los niveles NO son campos. Se muestran para que el usuario sepa
          qué está aceptando, no para que los negocie. */}
      <dl className="sim__ficha">
        <div>
          <dt>Stop</dt>
          <dd className="num neg">{formatearPrecio(sl)}</dd>
        </div>
        <div>
          <dt>Objetivo</dt>
          <dd className="num pos">{formatearPrecio(tp)}</dd>
        </div>
        <div>
          <dt>Riesgo/beneficio</dt>
          <dd className="num">{rr ? `${rr.toFixed(2)} : 1` : "—"}</dd>
        </div>
        <div>
          <dt>Su parte del reparto</dt>
          <dd className="num">
            {reparto?.parte != null ? formatearPrecio(Number(reparto.parte)) : "—"}
            <span className="sim__sub">
              {reparto ? `${sugerida ?? "—"} unidades sugeridas` : "márcala para incluirla en el reparto"}
            </span>
          </dd>
        </div>
        <div>
          <dt>Consume del saldo</dt>
          <dd className="num">
            {consumoEstimado != null ? formatearPrecio(consumoEstimado) : "—"}
            {pctEstimado != null && (
              <span className="sim__sub">
                {pctEstimado.toFixed(1)} % de {formatearPrecio(Number(cuenta.saldo_operar))}
              </span>
            )}
          </dd>
        </div>
        <div>
          <dt>Riesgo hasta el stop</dt>
          <dd className="num">
            {riesgoEstimado != null ? formatearPrecio(riesgoEstimado) : "—"}
            {riesgoEstimado != null && Number(fila.equity) > 0 && (
              <span className="sim__sub">
                {((riesgoEstimado / Number(fila.equity)) * 100).toFixed(1)} % del equity · máx 10 %
              </span>
            )}
          </dd>
        </div>
        <div>
          <dt>Margen con tu cantidad</dt>
          <dd className="num">
            {margenEstimado != null ? formatearPrecio(margenEstimado) : "—"}
            {fila.apalancamiento && (
              <span className="sim__sub">a {formatearMultiplicador(Number(fila.apalancamiento))}x</span>
            )}
          </dd>
        </div>
        <div>
          <dt>Liquidación</dt>
          <dd className="num">
            {fila.precio_liquidacion ? formatearPrecio(Number(fila.precio_liquidacion)) : "—"}
          </dd>
        </div>
      </dl>

      <p className="sim__nota">
        La cantidad sugerida es la parte de tu saldo para operar que le toca entre las que has
        marcado (más a 5× que a 4×, más a 4× que a 3×), salvo que tu riesgo por operación pida
        menos; puedes cambiarla. El servidor recalcula el margen e impone los límites: riesgo
        hasta el stop ≤ 10 % del equity y uso total ≤ tu máximo. El stop y el objetivo no se
        tocan: los fija el motor.
      </p>

      {cantidad !== "" && !cantidadValida && (
        <p className="sim__error" role="alert">
          <IconoAlerta size={14} />{" "}
          {fracciones
            ? "La cantidad tiene que ser mayor que cero."
            : "Las acciones se compran por unidades enteras."}
        </p>
      )}

      {!encuadra && (
        <p className="sim__error" role="alert">
          <IconoAlerta size={14} /> Con esa entrada los niveles no encuadran: tiene que quedar
          entre el stop ({formatearPrecio(sl)}) y el objetivo ({formatearPrecio(tp)}).
        </p>
      )}

      <div className="sim__confirmar-acciones">
        <button type="submit" className="btn btn--accent" disabled={ocupado || !encuadra || !cantidadValida}>
          {ocupado ? "Abriendo…" : "Abrir posición"}
        </button>
        <button type="button" className="btn" onClick={alCancelar}>
          Cancelar
        </button>
      </div>
    </form>
  );
}

// ── Por qué una sugerencia no se puede confirmar ─────────────────────
// La vista la marca confirmable solo si el dimensionado cabe Y su R:R
// llega al mínimo de la cuenta. Antes, el caso del R:R —el más frecuente—
// caía en un «no encuadra» que no decía nada.
function motivoNoConfirmable(r, cuenta) {
  const minimo = Number(cuenta?.ratio_rr_minimo);
  if (!r.motivo && r.ratio_rr != null && Number(r.ratio_rr) < minimo) {
    return `R:R ${Number(r.ratio_rr).toFixed(2)} por debajo del mínimo de tu cuenta (${minimo.toFixed(1)})`;
  }
  switch (r.motivo) {
    case "sin_operacion_liquidacion_antes_del_stop":
      return "el stop queda más lejos que la liquidación";
    case "margen_insuficiente":
      return "sin margen libre";
    case "stop_por_encima_del_precio":
      return "el stop está por encima del precio";
    case "cantidad_nula":
      return "tamaño demasiado pequeño";
    default:
      return "no encuadra";
  }
}

// ── Tus límites (0020, 0022) ─────────────────────────────────────────
// Los tres que son decisión del usuario. El apalancamiento no está: es la
// regla protegida nº1 y lo fija la fase. Y desde la 0022 tampoco el número
// de posiciones: cuántas abres lo decides al marcar sugerencias.
const CAMPOS_LIMITES = [
  { clave: "riesgoPct", columna: "riesgo_pct_operacion", etiqueta: "Riesgo por operación", sufijo: "% del equity" },
  { clave: "margenMaxPct", columna: "margen_comprometido_max_pct", etiqueta: "Uso máx. del saldo para operar", sufijo: "%" },
  { clave: "rrMinimo", columna: "ratio_rr_minimo", etiqueta: "R:R mínimo", sufijo: ": 1" },
];

function LimitesCuenta({ cuenta, alGuardar, avisar }) {
  const [valores, setValores] = useState(() =>
    Object.fromEntries(CAMPOS_LIMITES.map((c) => [c.clave, String(Number(cuenta[c.columna]))]))
  );
  const [ocupado, setOcupado] = useState(false);

  const fueraDeRango = CAMPOS_LIMITES.filter((c) => {
    const v = Number(valores[c.clave]);
    const r = RANGOS_CUENTA[c.clave];
    return !Number.isFinite(v) || v < r.min || v > r.max;
  });
  const usable = (Number(cuenta.saldo_operar) * Number(valores.margenMaxPct)) / 100;

  async function enviar(e) {
    e.preventDefault();
    setOcupado(true);
    try {
      await configurarCuenta(Object.fromEntries(CAMPOS_LIMITES.map((c) => [c.clave, Number(valores[c.clave])])));
      avisar("Límites guardados. Las sugerencias se recalculan con ellos.", "ok");
      alGuardar();
    } catch (error) {
      avisar(error.message, "neg");
    } finally {
      setOcupado(false);
    }
  }

  return (
    <form className="sim__limites" onSubmit={enviar}>
      <div className="sim__confirmar-campos">
        {CAMPOS_LIMITES.map((c) => {
          const r = RANGOS_CUENTA[c.clave];
          return (
            <label key={c.clave} className="field sim__campo">
              <span className="label">{c.etiqueta}</span>
              <input
                type="number"
                min={r.min}
                max={r.max}
                step={r.paso}
                value={valores[c.clave]}
                onChange={(e) => setValores((v) => ({ ...v, [c.clave]: e.target.value }))}
                inputMode="decimal"
              />
              <span className="sim__sub">
                {r.min}–{r.max} {c.sufijo}
              </span>
            </label>
          );
        })}
      </div>
      <p className="sim__nota">
        Con estos límites puedes usar{" "}
        <strong>{Number.isFinite(usable) ? formatearPrecio(usable) : "—"}</strong> de tu saldo para
        operar de {formatearPrecio(Number(cuenta.saldo_operar))}, repartidos entre las sugerencias
        que marques. El tope de apalancamiento no se ajusta: lo fija la fase de la cuenta. Si
        quieres dejar colchón, baja el uso máximo; lo que limita la pérdida es el riesgo por
        operación.
      </p>
      {fueraDeRango.length > 0 && (
        <p className="sim__error" role="alert">
          <IconoAlerta size={14} /> Fuera de rango: {fueraDeRango.map((c) => c.etiqueta.toLowerCase()).join(", ")}.
        </p>
      )}
      <div className="sim__confirmar-acciones">
        <button type="submit" className="btn btn--accent" disabled={ocupado || fueraDeRango.length > 0}>
          {ocupado ? "Guardando…" : "Guardar límites"}
        </button>
      </div>
    </form>
  );
}

// ── Cifra de la cabecera de cuenta ───────────────────────────────────
function Cifra({ etiqueta, valor, tono, nota }) {
  return (
    <div className="sim__cifra">
      <span className="label">{etiqueta}</span>
      <span className={`num sim__cifra-valor${tono ? ` ${tono}` : ""}`}>{valor}</span>
      {nota && <span className="sim__cifra-nota">{nota}</span>}
    </div>
  );
}

export default function Simulador() {
  const [cuenta, setCuenta] = useState(null);
  const [recomendaciones, setRecomendaciones] = useState([]);
  const [ordenes, setOrdenes] = useState([]);
  const [movimientos, setMovimientos] = useState([]);
  const [cargando, setCargando] = useState(true);
  const [aviso, setAviso] = useState(null);
  const [confirmando, setConfirmando] = useState(null);
  const [cerrando, setCerrando] = useState(null);
  const [seccionGuia, setSeccionGuia] = useState(null);
  const [ajustando, setAjustando] = useState(false);
  // Reparto (0022). Se guardan las DESMARCADAS y no las marcadas: así una
  // sugerencia nueva entra marcada en el reparto, y la que se abre
  // desaparece sola de la lista.
  const [desmarcadas, setDesmarcadas] = useState(() => new Set());
  const [reparto, setReparto] = useState({});
  const [abriendoLote, setAbriendoLote] = useState(false);

  const avisar = useCallback((texto, tono = "ok") => setAviso({ texto, tono }), []);

  const cargar = useCallback(async () => {
    try {
      const c = await leerCuenta();
      setCuenta(c);
      if (!c) {
        setRecomendaciones([]);
        setOrdenes([]);
        setMovimientos([]);
        return;
      }
      const [r, o, m] = await Promise.all([
        leerRecomendaciones(),
        leerOrdenes(),
        leerMovimientos(c.id),
      ]);
      setRecomendaciones(r ?? []);
      setOrdenes(o ?? []);
      setMovimientos(m ?? []);
    } catch (error) {
      avisar(error.message, "neg");
    } finally {
      setCargando(false);
    }
  }, [avisar]);

  useEffect(() => {
    cargar();
  }, [cargar]);

  // Sondeo mientras haya algo vivo que mirar. Sin posiciones abiertas no
  // hay nada que el monitor pueda cambiar, así que no se sondea: una
  // pestaña abierta toda la tarde no debe gastar lecturas por nada.
  const hayAbiertas = ordenes.some((o) => o.estado === "abierta");
  useEffect(() => {
    if (!hayAbiertas) return undefined;
    const id = setInterval(cargar, RELECTURA_MS);
    return () => clearInterval(id);
  }, [hayAbiertas, cargar]);

  const marcadas = useMemo(
    () => recomendaciones.filter((r) => r.confirmable && !desmarcadas.has(r.senal_id)),
    [recomendaciones, desmarcadas]
  );
  const claveMarcadas = marcadas.map((r) => r.senal_id).join(",");

  // El reparto lo calcula el servidor cada vez que cambian las marcadas o
  // la cuenta (una apertura, un cierre, el sondeo).
  useEffect(() => {
    if (!cuenta || cuenta.estado !== "activa") return undefined;
    let vigente = true;
    const ids = claveMarcadas ? claveMarcadas.split(",").map(Number) : [];
    repartirSaldo(ids)
      .then((filas) => {
        if (vigente) setReparto(Object.fromEntries((filas ?? []).map((f) => [f.senal_id, f])));
      })
      .catch((error) => vigente && avisar(error.message, "neg"));
    return () => {
      vigente = false;
    };
  }, [claveMarcadas, cuenta, avisar]);

  function alternarMarca(senalId) {
    setDesmarcadas((d) => {
      const n = new Set(d);
      if (n.has(senalId)) n.delete(senalId);
      else n.add(senalId);
      return n;
    });
  }

  const lote = marcadas.filter((r) => reparto[r.senal_id]?.cantidad && !reparto[r.senal_id]?.motivo);

  // Abre de una vez las marcadas, cada una con su parte. Una a una: el
  // reparto da la misma parte a cada una en cualquier orden de apertura, y
  // si una falla (un precio que se movió, una señal que caducó) las demás
  // siguen.
  async function abrirLote() {
    setAbriendoLote(true);
    const bien = [];
    const mal = [];
    for (const r of lote) {
      try {
        await abrirOrden({
          cuentaId: r.cuenta_id,
          senalId: r.senal_id,
          cantidad: Number(reparto[r.senal_id].cantidad),
        });
        bien.push(r.simbolo);
      } catch (error) {
        mal.push(`${r.simbolo}: ${error.message}`);
      }
    }
    avisar(
      (bien.length ? `Abiertas ${bien.length}: ${bien.join(", ")}.` : "No se abrió ninguna.") +
        (mal.length ? ` Rechazadas: ${mal.join(" · ")}` : ""),
      mal.length ? (bien.length ? "warn" : "neg") : "ok"
    );
    setAbriendoLote(false);
    await cargar();
  }

  const abiertas = useMemo(() => ordenes.filter((o) => o.estado === "abierta"), [ordenes]);
  const cerradas = useMemo(() => ordenes.filter((o) => o.estado === "cerrada"), [ordenes]);

  const pnlFlotante = abiertas.reduce((t, o) => t + Number(o.pnl_flotante ?? 0), 0);
  // Con cierres parciales, lo realizado de una orden es su resultado final
  // MÁS lo que ya se cerró por partes (también de las que siguen abiertas).
  const pnlRealizado =
    cerradas.reduce((t, o) => t + Number(o.pnl_bruto ?? 0), 0) +
    ordenes.reduce((t, o) => t + Number(o.pnl_parciales ?? 0), 0);

  const estado = cuenta ? ESTADOS_CUENTA[cuenta.estado] ?? { texto: cuenta.estado, tono: "" } : null;

  async function cerrar(orden) {
    setCerrando(orden.id);
    try {
      const r = await cerrarOrden(orden.id);
      avisar(
        r.cerrada
          ? `${orden.simbolo} cerrada a mano: ${formatearImporte(Number(r.pnl))}.`
          : "Esa orden ya estaba cerrada.",
        r.cerrada ? "ok" : "warn"
      );
      await cargar();
    } catch (error) {
      avisar(error.message, "neg");
    } finally {
      setCerrando(null);
    }
  }

  async function cerrarParte(orden, fraccion) {
    setCerrando(orden.id);
    try {
      const r = await cerrarParcial(orden.id, fraccion);
      avisar(
        r.cerrada
          ? `${orden.simbolo}: cerradas ${Number(r.cantidad_cerrada)} unidades por ${formatearImporte(
              Number(r.pnl)
            )}; liberados ${formatearPrecio(Number(r.margen_liberado))} de margen.`
          : "Esa orden ya estaba cerrada.",
        r.cerrada ? "ok" : "warn"
      );
      await cargar();
    } catch (error) {
      avisar(error.message, "neg");
    } finally {
      setCerrando(null);
    }
  }

  return (
    <div className="app">
      <header className="chrome">
        <div className="chrome__brand">
          <Marca />
          <div className="chrome__wordmark">
            <span className="chrome__title">Dashboard Financiero</span>
            <span className="chrome__subtitle">Simulador</span>
          </div>
        </div>
        <span className="chrome__rule" aria-hidden="true" />
      </header>

      <main className="main">
        <Navegacion />
        <AvisoLegal />

        {aviso && (
          <p className={`acceso__aviso acceso__aviso--${aviso.tono} sim__aviso`} role="status">
            {aviso.texto}
            <button type="button" className="enlace" onClick={() => setAviso(null)}>
              cerrar
            </button>
          </p>
        )}

        <div className="sim__cuerpo">
          <Panel
            titulo="Cuenta de simulación"
            meta={cuenta ? FASES[cuenta.fase] ?? cuenta.fase : "sin abrir"}
            alPedirAyuda={() => setSeccionGuia("simulador")}
            acciones={
              cuenta ? (
                <button type="button" className="btn btn--icon" onClick={cargar} title="Refrescar">
                  <IconoRefrescar />
                  <span className="sr-only">Refrescar</span>
                </button>
              ) : null
            }
            pie={
              cuenta ? (
                <>
                  <span className="label">Estado</span>
                  <span className={`sim__estado sim__estado--${estado.tono}`}>{estado.texto}</span>
                  <span className="sim__pie-sep" aria-hidden="true">
                    ·
                  </span>
                  <span className="label">Tope de la fase</span>
                  <span className="num sim__tope">
                    {formatearTope(Number(cuenta.leverage_tope))}x
                  </span>
                </>
              ) : null
            }
          >
            {cargando && !cuenta ? (
              <p className="sim__nota">Cargando…</p>
            ) : !cuenta ? (
              <AltaDeCuenta alCrear={cargar} avisar={avisar} />
            ) : (
              <>
                <div className="sim__cifras">
                  <Cifra
                    etiqueta="Equity"
                    valor={formatearPrecio(Number(cuenta.equity))}
                    nota="disponible + bloqueado + P&L flotante"
                  />
                  {/* 0022: la cifra con la que se piensa una operación. Lo
                      que consume cada posición se mide contra ella. */}
                  <Cifra
                    etiqueta="Saldo para operar"
                    valor={formatearPrecio(Number(cuenta.saldo_operar ?? 0))}
                    nota={
                      `equity × ${formatearTope(Number(cuenta.leverage_tope))} · en uso ` +
                      `${formatearPrecio(Number(cuenta.saldo_operar_en_uso ?? 0))} · libre ` +
                      `${formatearPrecio(saldoLibre(cuenta) ?? 0)}` +
                      (Number(cuenta.margen_comprometido_max_pct) < 100
                        ? ` (usas hasta el ${Number(cuenta.margen_comprometido_max_pct)} %)`
                        : "")
                    }
                  />
                  <Cifra
                    etiqueta="Disponible"
                    valor={formatearPrecio(Number(cuenta.saldo_disponible))}
                  />
                  {/* D15: dos cifras que no se sustituyen. El poder de
                      trading es lo que el bróker PERMITE por el saldo (hasta
                      20×, por escalas); el tope de la fase, al pie del panel,
                      es lo RECOMENDABLE y lo que el servidor impone. */}
                  <Cifra
                    etiqueta="Poder de trading"
                    valor={formatearPrecio(Number(cuenta.poder_trading ?? 0))}
                    nota={`escalas QuantFury · en uso ${formatearPrecio(Number(cuenta.nominal_abierto ?? 0))}`}
                  />
                  <Cifra
                    etiqueta="Margen bloqueado"
                    valor={formatearPrecio(Number(cuenta.saldo_bloqueado))}
                    nota={
                      cuenta.margen_comprometido_pct != null
                        ? `${cuenta.margen_comprometido_pct}% del equity · tope ${cuenta.margen_comprometido_max_pct}%`
                        : null
                    }
                  />
                  <Cifra
                    etiqueta="P&L flotante"
                    valor={formatearImporte(pnlFlotante)}
                    tono={claseSigno(pnlFlotante)}
                  />
                  <Cifra
                    etiqueta="P&L realizado"
                    valor={formatearImporte(pnlRealizado)}
                    tono={claseSigno(pnlRealizado)}
                    nota={`${cerradas.length} operaciones cerradas`}
                  />
                  <Cifra
                    etiqueta="Desde el máximo"
                    valor={formatearPorcentaje(Number(cuenta.drawdown_pct ?? 0))}
                    tono={claseSigno(Number(cuenta.drawdown_pct ?? 0))}
                    nota={`pico ${formatearPrecio(Number(cuenta.capital_maximo_alcanzado))}`}
                  />
                </div>

                <button
                  type="button"
                  className="enlace sim__ajustar"
                  onClick={() => setAjustando((v) => !v)}
                  aria-expanded={ajustando}
                >
                  {ajustando ? "Ocultar tus límites" : "Ajustar tus límites"}
                </button>
                {ajustando && cuenta.estado !== "game_over" && (
                  <LimitesCuenta
                    key={cuenta.actualizado_en}
                    cuenta={cuenta}
                    avisar={avisar}
                    alGuardar={() => {
                      setAjustando(false);
                      cargar();
                    }}
                  />
                )}

                {cuenta.estado === "game_over" && (
                  <p className="sim__error" role="status">
                    <IconoAlerta size={14} /> Game over: el equity llegó a cero. No se revierte —
                    reiniciar crea una cuenta nueva y conserva el histórico de este intento, que
                    es el dato que interesa.
                  </p>
                )}
                {cuenta.estado === "inoperante" && (
                  <p className="sim__error sim__error--aviso" role="status">
                    <IconoAlerta size={14} /> Queda saldo, pero no el suficiente para abrir una
                    posición que respete tu riesgo por operación. No es un game over: es ruina
                    técnica, y el sistema las distingue a propósito.
                  </p>
                )}
              </>
            )}
          </Panel>

          {cuenta && cuenta.estado === "activa" && (
            <Panel
              titulo="Entradas sugeridas"
              meta={
                recomendaciones.length
                  ? `${recomendaciones.length} de tu cartera · ${marcadas.length} en el reparto`
                  : "ninguna ahora mismo"
              }
              alPedirAyuda={() => setSeccionGuia("simulador")}
              flush={recomendaciones.length > 0}
            >
              {confirmando && (
                <Confirmacion
                  key={confirmando.senal_id}
                  fila={confirmando}
                  reparto={reparto[confirmando.senal_id]}
                  cuenta={cuenta}
                  avisar={avisar}
                  alCancelar={() => setConfirmando(null)}
                  alConfirmar={() => {
                    setConfirmando(null);
                    cargar();
                  }}
                />
              )}

              {recomendaciones.length === 0 ? (
                <p className="sim__nota">
                  Aquí aparecen las señales <strong>operables y recientes</strong> de los activos
                  que sigues, con el tamaño que le corresponde a tu cuenta. Si está vacío no es un
                  fallo: significa que ahora mismo el motor no encuadra ninguna operación en tu
                  universo, y no operar es una decisión válida.
                </p>
              ) : (
                <>
                <div className="sim__reparto">
                  <p className="sim__nota">
                    Marca las que quieres abrir: tu saldo libre,{" "}
                    <strong>{formatearPrecio(saldoLibre(cuenta) ?? 0)}</strong>, se reparte entre{" "}
                    {marcadas.length === 1 ? "esa" : `esas ${marcadas.length}`} según su
                    apalancamiento (una 5× recibe más que una 3×).
                  </p>
                  <button
                    type="button"
                    className="btn btn--accent"
                    disabled={abriendoLote || lote.length === 0}
                    onClick={abrirLote}
                  >
                    {abriendoLote
                      ? "Abriendo…"
                      : lote.length === 1
                        ? "Abrir la marcada"
                        : `Abrir las ${lote.length} marcadas`}
                  </button>
                </div>
                <table className="sim__tabla sim__tabla--sugeridas">
                  <thead>
                    <tr>
                      <th>
                        <span className="sr-only">Incluir en el reparto</span>
                      </th>
                      <th>Activo</th>
                      <th>Confluencia</th>
                      <th>Niveles</th>
                      <th>Peso</th>
                      <th className="num">R:R</th>
                      <th className="num">Del saldo</th>
                      <th className="num">Tamaño</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {recomendaciones.map((r) => {
                      const p = reparto[r.senal_id];
                      const marcada = r.confirmable && !desmarcadas.has(r.senal_id);
                      return (
                      <tr key={r.senal_id} className={marcada ? undefined : "sim__fila--fuera"}>
                        <td>
                          <input
                            type="checkbox"
                            checked={marcada}
                            disabled={!r.confirmable}
                            onChange={() => alternarMarca(r.senal_id)}
                            aria-label={`Incluir ${r.simbolo} en el reparto`}
                          />
                        </td>
                        <td>
                          <span className="sim__ticker">{r.simbolo}</span>
                          <span className="sim__sub">
                            {formatearPrecio(Number(r.precio_actual))} · hace {r.antiguedad_min} min
                          </span>
                        </td>
                        <td>
                          <MedidorConfluencia
                            direccion={r.direccion}
                            fuerza={r.fuerza}
                            apoyos={r.indicadores_alcistas}
                            total={r.indicadores_alcistas + r.indicadores_bajistas}
                          />
                        </td>
                        <td className="sim__celda-riel">
                          <RielRiesgo
                            inferior={Number(r.sl)}
                            superior={Number(r.tp)}
                            precio={Number(r.precio_actual)}
                            operable
                          />
                        </td>
                        <td>
                          <BarraApalancamiento
                            recomendado={Number(r.apalancamiento ?? r.leverage_recomendado)}
                            tope={Number(r.leverage_tope)}
                            referencia={Number(r.leverage_referencia_volatilidad)}
                            operable={r.confirmable}
                          />
                        </td>
                        <td className="num">
                          {r.ratio_rr != null ? Number(r.ratio_rr).toFixed(2) : "—"}
                        </td>
                        <td className="num">
                          {marcada && p ? (
                            <>
                              {formatearPrecio(Number(p.consumo ?? 0))}
                              <span className="sim__sub">
                                {(pctDelSaldo(p.consumo, cuenta.saldo_operar) ?? 0).toFixed(1)} % · parte{" "}
                                {formatearPrecio(Number(p.parte))}
                              </span>
                              {p.motivo ? (
                                <span className="sim__sub sim__sub--motivo">
                                  {motivoNoConfirmable(p, cuenta)}
                                </span>
                              ) : (
                                p.limitado_por_riesgo && (
                                  <span className="sim__sub">menos: lo limita tu riesgo</span>
                                )
                              )}
                            </>
                          ) : (
                            <span className="sim__sub">{r.confirmable ? "sin marcar" : "—"}</span>
                          )}
                        </td>
                        <td className="num">{marcada && p?.cantidad != null ? Number(p.cantidad) : "—"}</td>
                        <td>
                          {r.confirmable ? (
                            <button
                              type="button"
                              className="btn btn--accent"
                              onClick={() => setConfirmando(r)}
                            >
                              Confirmar
                            </button>
                          ) : (
                            <span className="sim__sub sim__sub--motivo">
                              {motivoNoConfirmable(r, cuenta)}
                            </span>
                          )}
                        </td>
                      </tr>
                      );
                    })}
                  </tbody>
                </table>
                </>
              )}
            </Panel>
          )}

          {cuenta && (
            <Panel
              titulo="Posiciones abiertas"
              meta={
                abiertas.length
                  ? `${abiertas.length} abiertas`
                  : "ninguna"
              }
              flush={abiertas.length > 0}
              pie={
                <span className="sim__nota sim__nota--pie">
                  El monitor revisa el precio cada minuto y cierra solo cuando toca un nivel. El
                  cierre se registra <strong>al nivel</strong>, salvo si la acción abre ya más allá
                  del stop tras un cierre de mercado: entonces sale al precio de apertura.
                </span>
              }
            >
              {abiertas.length === 0 ? (
                <p className="sim__nota">Sin posiciones abiertas.</p>
              ) : (
                <table className="sim__tabla">
                  <thead>
                    <tr>
                      <th>Activo</th>
                      <th className="num">Entrada</th>
                      <th className="num">Cantidad</th>
                      <th className="num">Del saldo</th>
                      <th className="num">Margen</th>
                      <th className="num">Stop / Objetivo</th>
                      <th className="num">Liquidación</th>
                      <th className="num">Precio</th>
                      <th className="num">P&L</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {abiertas.map((o) => (
                      <tr key={o.id}>
                        <td>
                          <span className="sim__ticker">{o.simbolo}</span>
                          <span className="sim__sub">{tiempoRelativo(o.fecha_entrada)}</span>
                        </td>
                        <td className="num">{formatearPrecio(Number(o.precio_entrada))}</td>
                        <td className="num">{Number(o.cantidad)}</td>
                        <td className="num">
                          {formatearPrecio(consumoDelSaldo(o.margen_comprometido, cuenta.leverage_tope) ?? 0)}
                          <span className="sim__sub">
                            {(
                              pctDelSaldo(
                                consumoDelSaldo(o.margen_comprometido, cuenta.leverage_tope),
                                cuenta.saldo_operar
                              ) ?? 0
                            ).toFixed(1)}{" "}
                            % · a {formatearMultiplicador(Number(o.apalancamiento))}x
                          </span>
                        </td>
                        <td className="num">{formatearPrecio(Number(o.margen_comprometido))}</td>
                        <td className="num">
                          <span className="neg">{formatearPrecio(Number(o.sl))}</span>
                          {" / "}
                          <span className="pos">{formatearPrecio(Number(o.tp))}</span>
                        </td>
                        <td className="num sim__liq">
                          {formatearPrecio(Number(o.precio_liquidacion))}
                        </td>
                        <td className="num">
                          {o.ultimo_precio != null ? formatearPrecio(Number(o.ultimo_precio)) : "—"}
                          <span className="sim__sub">{tiempoRelativo(o.ultimo_precio_en)}</span>
                        </td>
                        <td className={`num ${claseSigno(Number(o.pnl_flotante))}`}>
                          {o.pnl_flotante != null ? formatearImporte(Number(o.pnl_flotante)) : "—"}
                          {o.pnl_flotante_pct_margen != null && (
                            <span className="sim__sub">
                              {formatearPorcentaje(Number(o.pnl_flotante_pct_margen))} del margen
                            </span>
                          )}
                          {Number(o.pnl_parciales) !== 0 && (
                            <span className="sim__sub">
                              {formatearImporte(Number(o.pnl_parciales))} ya realizados
                            </span>
                          )}
                        </td>
                        <td>
                          <div className="sim__cierre">
                            {/* Cierre parcial (0016): libera esa parte del margen
                                para otra operación. Una acción se cierra por
                                unidades enteras. */}
                            {[0.25, 0.5, 0.75].map((f) => (
                              <button
                                key={f}
                                type="button"
                                className="btn sim__btn-parcial"
                                disabled={cerrando === o.id}
                                onClick={() => cerrarParte(o, f)}
                                title={`Cerrar el ${f * 100} % al precio de ahora`}
                              >
                                {f * 100}%
                              </button>
                            ))}
                            <button
                              type="button"
                              className="btn"
                              disabled={cerrando === o.id}
                              onClick={() => cerrar(o)}
                            >
                              {cerrando === o.id ? "Cerrando…" : "Cerrar"}
                            </button>
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </Panel>
          )}

          {cuenta && cerradas.length > 0 && (
            <Panel titulo="Histórico" meta={`${cerradas.length} operaciones`} flush>
              <table className="sim__tabla">
                <thead>
                  <tr>
                    <th>Activo</th>
                    <th className="num">Entrada</th>
                    <th className="num">Salida</th>
                    <th>Motivo</th>
                    <th className="num">Observado</th>
                    <th className="num">P&L</th>
                    <th>Cerrada</th>
                  </tr>
                </thead>
                <tbody>
                  {cerradas.map((o) => (
                    <tr key={o.id}>
                      <td>
                        <span className="sim__ticker">{o.simbolo}</span>
                      </td>
                      <td className="num">{formatearPrecio(Number(o.precio_entrada))}</td>
                      <td className="num">{formatearPrecio(Number(o.precio_salida))}</td>
                      <td>
                        <span className={`sim__motivo sim__motivo--${o.motivo_cierre}`}>
                          {MOTIVOS_CIERRE[o.motivo_cierre] ?? o.motivo_cierre}
                        </span>
                      </td>
                      {/* La diferencia entre el nivel y el precio que lo
                          disparó es el deslizamiento que este sistema aún
                          no modela. Se muestra para poder medirlo. */}
                      <td className="num sim__sub">
                        {o.precio_observado_cierre != null
                          ? formatearPrecio(Number(o.precio_observado_cierre))
                          : "—"}
                      </td>
                      <td className={`num ${claseSigno(Number(o.pnl_bruto) + Number(o.pnl_parciales ?? 0))}`}>
                        {formatearImporte(Number(o.pnl_bruto) + Number(o.pnl_parciales ?? 0))}
                        {Number(o.pnl_parciales) !== 0 && (
                          <span className="sim__sub">
                            {formatearImporte(Number(o.pnl_parciales))} en cierres parciales
                          </span>
                        )}
                        <span className="sim__sub">
                          {formatearPorcentaje(Number(o.pnl_pct))}
                        </span>
                      </td>
                      <td className="sim__sub">{tiempoRelativo(o.fecha_salida)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Panel>
          )}

          {cuenta && movimientos.length > 0 && (
            <Panel
              titulo="Libro mayor"
              meta={`${movimientos.length} últimos apuntes`}
              flush
              pie={
                <span className="sim__nota sim__nota--pie">
                  El saldo de arriba no es un número guardado: es la suma de estas líneas. No se
                  pueden editar ni borrar, ni desde aquí ni desde el servidor.
                </span>
              }
            >
              <table className="sim__tabla sim__tabla--libro">
                <thead>
                  <tr>
                    <th>Apunte</th>
                    <th className="num">Importe</th>
                    <th className="num">Disponible</th>
                    <th className="num">Bloqueado</th>
                    <th>Cuándo</th>
                  </tr>
                </thead>
                <tbody>
                  {movimientos.map((m) => (
                    <tr key={m.id}>
                      <td>
                        {TIPOS_MOVIMIENTO[m.tipo] ?? m.tipo}
                        {m.orden_id && <span className="sim__sub">orden #{m.orden_id}</span>}
                      </td>
                      <td className={`num ${claseSigno(Number(m.importe))}`}>
                        {formatearImporte(Number(m.importe))}
                      </td>
                      <td className="num">
                        {formatearPrecio(Number(m.saldo_disponible_resultante))}
                      </td>
                      <td className="num">
                        {formatearPrecio(Number(m.saldo_bloqueado_resultante))}
                      </td>
                      <td className="sim__sub">{tiempoRelativo(m.creado_en)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Panel>
          )}
        </div>
      </main>

      {seccionGuia && (
        <HelpDrawer seccionInicial={seccionGuia} alCerrar={() => setSeccionGuia(null)} />
      )}
    </div>
  );
}
