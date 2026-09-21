/**
 * ¿Está atrasado este dato?
 *
 * La pregunta tiene respuesta distinta por clase de activo, y en la
 * Fase 2 inicial se respondía igual para todos (90 min sobre la señal más
 * vieja del escáner). Eso fallaba de dos maneras:
 *
 *  · Un solo activo atrasado marcaba como «caché» el escáner entero.
 *  · Con la bolsa cerrada —noches, fines de semana— las acciones NO se
 *    recalculan (el ETL respeta la ventana de mercado), así que parecían
 *    atrasadas 60 horas cada lunes aunque el dato fuese el último posible.
 *
 * Regla actual:
 *  · cripto: mercado 24/7, ETL horario → atrasada si pasa de 90 min.
 *  · acción: solo puede estar atrasada con Nueva York ABIERTO y después
 *    de la primera pasada del día (el ETL corre a :00 y :30); entonces,
 *    más de 60 min sin recalcular es un fallo real.
 *
 * Festivos de NYSE: no se modelan aquí (sí en `ventana_mercado.py` del
 * motor, que es quien decide si llamar). Un festivo entre semana puede
 * marcar las acciones como atrasadas; es un falso positivo visible y
 * honesto, no uno que oculte un fallo.
 */

export const MINUTOS_ANEJO = { cripto: 90, accion: 60 };

// Apertura 9:30, cierre 16:00, hora de Nueva York.
const APERTURA_MIN = 9 * 60 + 30;
const CIERRE_MIN = 16 * 60;
// Margen tras la apertura antes de exigir un dato del día: la primera
// pasada del ETL puede caer hasta 30 min después y tardar unos minutos.
const GRACIA_APERTURA_MIN = 45;

const partesNY = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** Minutos transcurridos desde la apertura de NY, o null si está cerrado. */
export function minutosDesdeAperturaNY(ahora = new Date()) {
  const p = Object.fromEntries(partesNY.formatToParts(ahora).map((x) => [x.type, x.value]));
  if (p.weekday === "Sat" || p.weekday === "Sun") return null;
  const minutoDia = Number(p.hour) * 60 + Number(p.minute);
  if (minutoDia < APERTURA_MIN || minutoDia >= CIERRE_MIN) return null;
  return minutoDia - APERTURA_MIN;
}

export function esClaseCripto(clase) {
  return clase === "cripto";
}

/**
 * true si la señal debería haberse recalculado ya y no lo ha hecho.
 * `senal` necesita `clase` y `calculado_en`.
 */
export function senalAtrasada(senal, ahora = new Date()) {
  const t = senal?.calculado_en ? Date.parse(senal.calculado_en) : NaN;
  if (!Number.isFinite(t)) return false;
  const edadMin = (ahora.getTime() - t) / 60000;

  if (esClaseCripto(senal.clase)) return edadMin > MINUTOS_ANEJO.cripto;

  const desdeApertura = minutosDesdeAperturaNY(ahora);
  if (desdeApertura === null || desdeApertura < GRACIA_APERTURA_MIN) return false;
  return edadMin > MINUTOS_ANEJO.accion;
}
