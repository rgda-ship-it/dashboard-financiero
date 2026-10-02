/**
 * Saldo para operar (0022, D17). Lecturas, no decisiones: el reparto y el
 * tamaño los calcula PostgreSQL (`rpc_repartir_saldo`, `rpc_abrir_orden`).
 * Esto solo traduce el margen de una posición a la pregunta que importa:
 * qué parte del saldo para operar se lleva.
 *
 *   saldo para operar = equity × tope de la fase
 *   consumo           = margen × tope de la fase
 *
 * A 5× el consumo es el nominal; a 3× es más que el nominal, porque esos
 * dólares bloquean más margen.
 */

const finito = (v) => (Number.isFinite(v) ? v : null);
// `Number(null)` es 0: un margen que no ha llegado no consume 0 $.
const numero = (v) => (v == null || v === "" ? NaN : Number(v));

/** Lo que una posición consume del saldo para operar, en dólares. */
export function consumoDelSaldo(margen, tope) {
  const m = numero(margen);
  const t = numero(tope);
  if (!Number.isFinite(m) || !Number.isFinite(t) || t <= 0) return null;
  return finito(m * t);
}

/** Ese consumo como % del saldo para operar. */
export function pctDelSaldo(importe, saldoOperar) {
  const i = numero(importe);
  const s = numero(saldoOperar);
  if (!Number.isFinite(i) || !Number.isFinite(s) || s <= 0) return null;
  return finito((i / s) * 100);
}

/** Lo que queda por usar: lo que G3 deja usar menos lo que ya consumen
 *  las abiertas. Nunca negativo (con pérdidas flotantes el equity, y con
 *  él el saldo, puede caer por debajo de lo ya consumido). */
export function saldoLibre(cuenta) {
  if (!cuenta) return null;
  const max = numero(cuenta.saldo_operar_max);
  const uso = numero(cuenta.saldo_operar_en_uso);
  if (!Number.isFinite(max) || !Number.isFinite(uso)) return null;
  return Math.max(max - uso, 0);
}
