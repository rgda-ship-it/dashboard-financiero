/**
 * Formateo y clasificación para la capa visual.
 *
 * Todo lo que aquí se hace es presentación: ni un solo cálculo de negocio
 * vive en este archivo. Las cifras llegan ya redondeadas desde el motor
 * analítico — esto solo decide cómo se leen.
 */

// El universo cripto del escáner viaja como id de CoinGecko ("bitcoin"),
// no como símbolo. Se muestra el símbolo, que es lo que el analista lee,
// y el id crudo queda visible en el detalle de la fila.
const SIMBOLO_CRIPTO = {
  bitcoin: "BTC",
  ethereum: "ETH",
  solana: "SOL",
};

// `clase` viene de la base de datos (`activos.clase`) y es la fuente de
// verdad: el catálogo es dinámico y una cripto nueva no está en la tabla
// de arriba. La tabla solo queda como respaldo y para el símbolo visible.
export function esCripto(ticker, clase) {
  if (clase) return clase === "cripto";
  return Object.prototype.hasOwnProperty.call(SIMBOLO_CRIPTO, String(ticker).toLowerCase());
}

export function simboloVisible(ticker) {
  const clave = String(ticker).toLowerCase();
  return SIMBOLO_CRIPTO[clave] ?? String(ticker).toUpperCase();
}

// Formato numérico de TODA la interfaz: punto decimal y coma de millares
// ($1,234.56). Es la misma convención que exige el CSV de cartera
// (decisión del dueño, 2026-09-19): lo que el usuario escribe al cargar y
// lo que lee en pantalla tienen que coincidir. Se usa en-US solo como
// vehículo de ese formato; los textos siguen en español.
//
// `useGrouping: "always"` se mantiene explícito: garantiza que un precio
// de cuatro cifras se agrupe igual que uno de seis en la misma columna.
const LOCALE_NUMEROS = "en-US";

const numero = new Intl.NumberFormat(LOCALE_NUMEROS, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
  useGrouping: "always",
});

const numeroCompacto = new Intl.NumberFormat(LOCALE_NUMEROS, {
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
  useGrouping: "always",
});

/** Precio en USD. Por encima de 1,000 se sueltan los decimales: en una
 *  columna densa, "108,412" se compara mejor que "108,412.37". */
export function formatearPrecio(valor) {
  if (!Number.isFinite(valor)) return "—";
  const abs = Math.abs(valor);
  if (abs >= 1000) return `$${numeroCompacto.format(valor)}`;
  return `$${numero.format(valor)}`;
}

export function formatearImporte(valor) {
  if (!Number.isFinite(valor)) return "—";
  const signo = valor > 0 ? "+" : valor < 0 ? "−" : "";
  return `${signo}$${numero.format(Math.abs(valor))}`;
}

const porcentaje = new Intl.NumberFormat(LOCALE_NUMEROS, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

export function formatearPorcentaje(valor) {
  if (!Number.isFinite(valor)) return "—";
  const signo = valor > 0 ? "+" : valor < 0 ? "−" : "";
  return `${signo}${porcentaje.format(Math.abs(valor))}%`;
}

const multiplicador = new Intl.NumberFormat(LOCALE_NUMEROS, {
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
});

const multiplicadorEntero = new Intl.NumberFormat(LOCALE_NUMEROS, {
  maximumFractionDigits: 1,
});

/** Apalancamiento: siempre con un decimal, para que 4.0× y 3.5× se
 *  comparen en columna sin que el punto baile. */
export function formatearMultiplicador(valor) {
  if (!Number.isFinite(valor)) return "—";
  return multiplicador.format(valor);
}

/** El tope duro es una constante redonda: 5× se lee mejor que 5.0×. */
export function formatearTope(valor) {
  if (!Number.isFinite(valor)) return "—";
  return multiplicadorEntero.format(valor);
}

/** Porcentaje sin signo, para magnitudes que nunca son negativas (ATR). */
export function formatearMagnitudPct(valor) {
  if (!Number.isFinite(valor)) return "—";
  return `${porcentaje.format(valor)}%`;
}

export function claseSigno(valor) {
  if (!Number.isFinite(valor) || valor === 0) return "dim";
  return valor > 0 ? "pos" : "neg";
}

/** "hace 3 min" — la referencia temporal que importa en un escáner que se
 *  refresca solo cada 5 minutos. */
export function tiempoRelativo(fecha) {
  if (!fecha) return "—";
  const ms = Date.now() - new Date(fecha).getTime();
  if (!Number.isFinite(ms)) return "—";
  const seg = Math.max(0, Math.round(ms / 1000));
  if (seg < 45) return "hace instantes";
  const min = Math.round(seg / 60);
  if (min < 60) return `hace ${min} min`;
  const horas = Math.round(min / 60);
  if (horas < 24) return `hace ${horas} h`;
  return `hace ${Math.round(horas / 24)} d`;
}

export function horaCorta(iso) {
  const fecha = iso ? new Date(iso) : new Date();
  if (Number.isNaN(fecha.getTime())) return "--:--:--";
  return fecha.toLocaleTimeString("es-ES", { hour12: false });
}

/** Traduce la fuerza de confluencia del motor a segmentos encendidos. */
export function segmentosDeFuerza(fuerza) {
  if (fuerza === "alta") return 3;
  if (fuerza === "media") return 2;
  if (fuerza === "baja") return 1;
  return 0;
}

/**
 * Dirección de la confluencia. El motor la envía en `direccion`; si esa
 * versión del motor todavía no está corriendo, se deduce del resumen en
 * texto para no dejar la fila sin color.
 */
export function direccionConfluencia(senal) {
  if (senal.direccion) return senal.direccion;
  const resumen = String(senal.resumen_confluencia ?? "").toLowerCase();
  if (resumen.includes("alcista")) return "alcista";
  if (resumen.includes("bajista")) return "bajista";
  return "neutral";
}

const SESGO_POR_DIRECCION = {
  alcista: "largo",
  bajista: "corto",
  neutral: "sin_sesgo",
};

/**
 * Sesgo operativo: qué encuadra el sistema como operación, que NO es lo
 * mismo que la lectura de mercado (`direccion`). Hoy coinciden 1:1, pero
 * son conceptos distintos y el motor los envía por separado.
 *
 * Si el campo no viene —por ejemplo cuando el circuit breaker sirve un
 * escaneo cacheado por una versión anterior del motor— se reconstruye
 * desde la dirección en vez de dejar la fila sin tratamiento.
 */
export function sesgoOperativo(senal) {
  return senal.sesgo_operativo ?? SESGO_POR_DIRECCION[direccionConfluencia(senal)];
}

/**
 * Si el motor emite números operables para esta fila.
 *
 * Se ramifica por `operable` y NUNCA por `sesgo_operativo === "largo"`:
 * en modo degradado (ATR o precio no disponibles) el motor manda
 * `operable: false` aunque la lectura sea alcista. Son dos preguntas
 * distintas y solo esta decide si hay cifras que mostrar.
 */
export function esOperable(senal) {
  if (typeof senal.operable === "boolean") return senal.operable;
  // Payload sin el campo: se reconstruye con el criterio nuevo para que un
  // escaneo viejo en caché no muestre un apalancamiento sobre una lectura
  // bajista, que es justo lo que este cambio elimina.
  return sesgoOperativo(senal) === "largo" && Number.isFinite(senal.leverage_recomendado);
}

/**
 * Niveles técnicos de la fila. `soporte`/`resistencia` son los campos
 * nuevos, sin rol operativo; `sl`/`tp` solo existen cuando hay sesgo
 * largo. En un payload anterior solo llegaban `sl`/`tp`, así que sirven
 * de respaldo.
 */
export function nivelesTecnicos(senal) {
  return {
    inferior: senal.soporte ?? senal.sl ?? null,
    superior: senal.resistencia ?? senal.tp ?? null,
  };
}

/** Etiqueta de volatilidad coherente con los tramos de `apalancamiento.py`. */
export function tramoVolatilidad(atrPct) {
  if (!Number.isFinite(atrPct)) return "—";
  if (atrPct >= 6) return "alta";
  if (atrPct >= 3) return "media";
  return "baja";
}

export function etiquetaSalud(nivel) {
  if (nivel === "verde") return "Saludable";
  if (nivel === "ambar") return "Vigilar";
  if (nivel === "rojo") return "Deterioro";
  return "Sin dato";
}
