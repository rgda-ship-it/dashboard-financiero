/**
 * Qué hacer con un activo del escáner (Fase 3, doc fase-3/04).
 *
 * El escáner de la Fase 1 enseñaba la lectura técnica, pero no la
 * decisión. Esta función la reconstruye con las mismas reglas que aplican
 * el simulador y los agentes, en este orden:
 *
 *   1. Sin datos fiables (error, suspendido, sin volatilidad) → no se opera
 *      (regla protegida nº4).
 *   2. Solo largos (regla nº2): una lectura bajista o sin dirección no se
 *      opera. Los cortos se probaron en el laboratorio y no tienen ventaja
 *      (doc fase-3/02).
 *   3. Confluencia baja → esperar.
 *   4. Con el SPREAD: se compra al precio de compra (intermedio + medio
 *      spread) y el stop salta al de venta. Si el R:R que queda no llega al
 *      mínimo más permisivo de los agentes, esperar.
 *   5. Dato atrasado o bolsa cerrada → esperar a la próxima lectura.
 *   6. Si no, comprar: hasta qué precio, con qué stop y qué objetivo.
 *
 * Y, aparte, qué agentes la tomarían con sus filtros (fuerza, origen de los
 * niveles, R:R mínimo y banda de ATR por clase), que es lo que de verdad
 * decide el sistema. Aquí no se decide nada nuevo: se explica.
 */

// El R:R mínimo más permisivo de los agentes con metas (Audacia, 1,2).
export const RR_MINIMO = 1.2;

// Spread supuesto de la 0034 cuando no hay uno medido para el activo.
const SPREAD_ACCION = 0.03;
const SPREAD_CRIPTO_PCT = 0.1;
const SPREAD_CRIPTO_FIJO = { bitcoin: 5, ethereum: 0.1 };

// Los parámetros por defecto de `fn_parametros_agente` (0024).
const POR_DEFECTO = {
  rr_minimo: 1.5,
  fuerzas_admitidas: ["alta"],
  clases_admitidas: ["accion", "cripto"],
  niveles_origen_admitidos: ["estructura", "atr"],
  atr_pct_min: null,
  atr_pct_max: null,
};

export function spreadDe(senal, medido) {
  if (Number.isFinite(medido) && medido > 0) return medido;
  if (senal.clase === "cripto") {
    return SPREAD_CRIPTO_FIJO[senal.ticker] ?? (senal.precio_actual * SPREAD_CRIPTO_PCT) / 100;
  }
  return SPREAD_ACCION;
}

/** Los filtros efectivos de un agente con metas, como los aplica la base de datos. */
export function parametrosAgente(estrategia) {
  const p = { ...POR_DEFECTO, ...(estrategia ?? {}) };
  return p;
}

function paramClase(p, clase, clave) {
  const propio = p.por_clase?.[clase];
  return propio && clave in propio ? propio[clave] : p[clave];
}

/** ¿La tomaría este agente? Devuelve null si sí, o el motivo si no. */
export function motivoAgente(estrategia, senal, rr) {
  const p = parametrosAgente(estrategia);
  if (!p.clases_admitidas.includes(senal.clase)) return "no opera esta clase";
  if (!p.fuerzas_admitidas.includes(senal.fuerza)) return `pide fuerza ${p.fuerzas_admitidas.join(" o ")}`;
  if (senal.niveles_origen && !p.niveles_origen_admitidos.includes(senal.niveles_origen))
    return "niveles por ATR, no por estructura";
  if (!Number.isFinite(rr) || rr < p.rr_minimo) return `pide R:R ≥ ${p.rr_minimo}`;
  const min = paramClase(p, senal.clase, "atr_pct_min");
  const max = paramClase(p, senal.clase, "atr_pct_max");
  if (min != null && !(senal.atr_pct >= min)) return `pide ATR ≥ ${min} %`;
  if (max != null && !(senal.atr_pct <= max)) return `pide ATR ≤ ${max} %`;
  return null;
}

/**
 * @param senal  fila del escáner (senales.js)
 * @param opciones { spread: número medido o null, agentes: [{nombre, tipo, estado, estrategia}],
 *                   bolsaAbierta: bool }
 * @returns {{ accion: "comprar"|"esperar"|"no_comprar"|"sin_datos", titulo, motivo,
 *            compra, stop, objetivo, riesgoPct, gananciaPct, rr, agentes: [{nombre, motivo}] }}
 */
export function veredicto(senal, { spread = null, agentes = [], bolsaAbierta = true } = {}) {
  const base = { compra: null, stop: null, objetivo: null, riesgoPct: null, gananciaPct: null, rr: null, agentes: [] };
  if (senal.error || !Number.isFinite(senal.precio_actual)) {
    return { ...base, accion: "sin_datos", titulo: "Sin datos", motivo: "El proveedor no dio datos de este activo." };
  }
  if (senal.suspendido) {
    return { ...base, accion: "sin_datos", titulo: "Sin datos", motivo: "Suspendido por fallos del proveedor: la lectura no es fiable." };
  }
  if (!Number.isFinite(senal.atr_pct)) {
    return { ...base, accion: "no_comprar", titulo: "No operar", motivo: "Sin volatilidad conocida no se calcula el riesgo: no se opera." };
  }
  if (senal.direccion !== "alcista") {
    return {
      ...base,
      accion: "no_comprar",
      titulo: "No comprar",
      motivo:
        senal.direccion === "bajista"
          ? "La lectura es bajista. El sistema solo opera en largo: vender en corto se probó y no tiene ventaja."
          : "Sin dirección clara: ni comprar ni vender.",
    };
  }
  if (!senal.operable || !Number.isFinite(senal.sl) || !Number.isFinite(senal.tp)) {
    return { ...base, accion: "no_comprar", titulo: "No operar", motivo: "El motor no encuadra ninguna operación con esta lectura." };
  }

  const s = spreadDe(senal, spread);
  const compra = senal.precio_actual + s / 2;
  const riesgo = compra - senal.sl;
  const ganancia = senal.tp - compra;
  const rr = riesgo > 0 ? ganancia / riesgo : NaN;
  const niveles = {
    compra,
    stop: senal.sl,
    objetivo: senal.tp,
    riesgoPct: (riesgo / compra) * 100,
    gananciaPct: (ganancia / compra) * 100,
    rr,
  };
  const deAgentes = agentes
    .filter((a) => a.tipo === "metas" && a.estado !== "game_over")
    .map((a) => ({ nombre: a.nombre, motivo: motivoAgente(a.estrategia, senal, rr) }));
  const conAgentes = { ...base, ...niveles, agentes: deAgentes };

  if (senal.fuerza === "baja") {
    return { ...conAgentes, accion: "esperar", titulo: "Esperar", motivo: "Alcista, pero con un solo indicador a favor: confluencia débil." };
  }
  if (!(ganancia > 0)) {
    return { ...conAgentes, accion: "no_comprar", titulo: "No comprar", motivo: "Con el spread, el precio de compra ya está en el objetivo: no queda recorrido." };
  }
  if (!(rr >= RR_MINIMO)) {
    return {
      ...conAgentes,
      accion: "esperar",
      titulo: "Esperar",
      motivo: `Arriesga más de lo que puede ganar: R:R ${rr.toFixed(2)} tras el spread (mínimo ${RR_MINIMO}).`,
    };
  }
  if (senal.atrasada) {
    return { ...conAgentes, accion: "esperar", titulo: "Esperar", motivo: "El dato está atrasado: espera a la próxima lectura." };
  }
  if (senal.clase !== "cripto" && !bolsaAbierta) {
    return {
      ...conAgentes,
      accion: "esperar",
      titulo: "Bolsa cerrada",
      motivo: "Es la lectura del último cierre. Vuelve a mirarla con la bolsa abierta: el precio de apertura puede cambiarla.",
    };
  }
  return {
    ...conAgentes,
    accion: "comprar",
    titulo: "Comprar",
    motivo: `Alcista con confluencia ${senal.fuerza}. Arriesga ${niveles.riesgoPct.toFixed(1)} % para ganar ${niveles.gananciaPct.toFixed(1)} %.`,
  };
}

// Orden del escáner: lo accionable primero.
export const RANGO_ACCION = { comprar: 0, esperar: 1, no_comprar: 2, sin_datos: 3 };
