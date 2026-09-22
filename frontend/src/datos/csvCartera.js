/**
 * Lectura del CSV de cartera EN EL NAVEGADOR (Sprint 4 · H-21).
 *
 * Porta las reglas de `backend/src/middleware/sanitizacionArchivos.js`
 * de la Fase 1, con una diferencia de fondo: el fichero NUNCA sale del
 * navegador. Al servidor (rpc_importar_posiciones) solo llegan filas en
 * JSON, y allí se vuelven a validar todas, porque el cliente no es de
 * fiar. Así un binario disfrazado de .csv no puede llegar a la base de
 * datos por construcción.
 *
 * Se valida por CONTENIDO, no por la extensión ni por el tipo MIME que
 * declara el navegador (deuda técnica nº7 de la Fase 1).
 */

export const TAMANO_MAXIMO_BYTES = 5 * 1024 * 1024;
export const COLUMNAS = ["Ticker", "Precio de Compra", "Monto"];

export class ErrorArchivo extends Error {}

// Firmas de ficheros que no son texto: ejecutable (MZ), ZIP/XLSX (PK),
// PDF, ELF. Y cualquier byte NUL, que un CSV de texto no contiene.
const FIRMAS_BINARIAS = [
  [0x4d, 0x5a],
  [0x50, 0x4b, 0x03, 0x04],
  [0x25, 0x50, 0x44, 0x46],
  [0x7f, 0x45, 0x4c, 0x46],
];

export function validarContenido(bytes) {
  if (bytes.length === 0) throw new ErrorArchivo("El archivo está vacío.");
  if (bytes.length > TAMANO_MAXIMO_BYTES) {
    throw new ErrorArchivo("El archivo supera el tamaño máximo (5 MB).");
  }
  for (const firma of FIRMAS_BINARIAS) {
    if (firma.every((b, i) => bytes[i] === b)) {
      throw new ErrorArchivo(
        "El archivo no es un CSV de texto (por su contenido parece un ejecutable, un ZIP/Excel o un PDF)."
      );
    }
  }
  const muestra = bytes.subarray(0, 8192);
  if (muestra.includes(0)) {
    throw new ErrorArchivo("El archivo no es un CSV de texto (contiene datos binarios).");
  }
}

/** CSV mínimo con comillas dobles (RFC 4180). Devuelve filas de celdas. */
export function parsearCSV(texto) {
  const filas = [];
  let fila = [];
  let celda = "";
  let entreComillas = false;

  for (let i = 0; i < texto.length; i++) {
    const c = texto[i];
    if (entreComillas) {
      if (c === '"') {
        if (texto[i + 1] === '"') {
          celda += '"';
          i++;
        } else {
          entreComillas = false;
        }
      } else {
        celda += c;
      }
    } else if (c === '"') {
      entreComillas = true;
    } else if (c === ",") {
      fila.push(celda);
      celda = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && texto[i + 1] === "\n") i++;
      fila.push(celda);
      filas.push(fila);
      fila = [];
      celda = "";
    } else {
      celda += c;
    }
  }
  if (celda !== "" || fila.length) {
    fila.push(celda);
    filas.push(fila);
  }
  return filas.filter((f) => f.some((v) => v.trim() !== ""));
}

// Formato numérico de la Fase 1 (decisión del dueño, 2026-09-19): punto
// decimal SIEMPRE; la coma solo como millares bien agrupados. Un número
// ambiguo («184,72») invalida la fila en vez de reinterpretarse.
const PATRON_MILLARES = /^-?\d{1,3}(,\d{3})+(\.\d+)?$/;
const PATRON_DECIMAL = /^-?\d+(\.\d+)?$/;

export function normalizarNumero(valor) {
  if (valor === undefined || valor === null) return null;
  let limpio = String(valor).replace(/[$€]/g, "").trim();
  if (limpio === "") return null;
  if (limpio.includes(",")) {
    if (!PATRON_MILLARES.test(limpio)) return null;
    limpio = limpio.replace(/,/g, "");
  }
  if (!PATRON_DECIMAL.test(limpio)) return null;
  return limpio;
}

/**
 * bytes (Uint8Array) → { filas, excluidas }.
 * `filas` va tal cual a rpc_importar_posiciones; `excluidas` son las que
 * ya se descartan aquí, con su motivo y su número de fila (1 = primera
 * fila de datos, como en la Fase 1).
 */
export function leerCartera(bytes) {
  validarContenido(bytes);

  let texto = new TextDecoder("utf-8").decode(bytes);
  if (texto.charCodeAt(0) === 0xfeff) texto = texto.slice(1);

  const tabla = parsearCSV(texto);
  if (tabla.length === 0) throw new ErrorArchivo("El archivo no tiene filas.");

  const cabecera = tabla[0].map((c) => c.trim().toLowerCase());
  const indices = COLUMNAS.map((col) => cabecera.indexOf(col.toLowerCase()));
  const faltan = COLUMNAS.filter((_, i) => indices[i] === -1);
  if (faltan.length) {
    throw new ErrorArchivo(
      `Formato no reconocido: faltan las columnas ${faltan.join(", ")}. ` +
        `Encabezados requeridos: ${COLUMNAS.join(", ")}.`
    );
  }

  const filas = [];
  const excluidas = [];
  tabla.slice(1).forEach((celdas, i) => {
    const numero = i + 1;
    // Más celdas que encabezados: casi siempre una coma decimal sin
    // comillas («AAPL,184,72,10»), que desplazaría las columnas y se
    // leería como precio 184 y monto 72. Se excluye en vez de adivinar.
    if (celdas.length > tabla[0].length) {
      excluidas.push({
        fila: numero,
        motivo: "más columnas que encabezados (¿una coma decimal? el decimal va con punto: 184.72)",
      });
      return;
    }
    // Minimización de datos (DPO, Fase 1): solo las tres columnas.
    const ticker = (celdas[indices[0]] ?? "").trim();
    const precio = normalizarNumero(celdas[indices[1]]);
    const monto = normalizarNumero(celdas[indices[2]]);
    if (!ticker || precio === null || monto === null) {
      excluidas.push({
        fila: numero,
        motivo: "datos incompletos o no numéricos (el decimal va con punto: 184.72)",
      });
      return;
    }
    // El ticker viaja tal cual: si tiene forma de fórmula (=, +, -, @) la
    // base de datos lo excluye con su motivo. Nunca se guarda.
    filas.push({ fila: numero, ticker, precio_compra: precio, monto });
  });

  if (filas.length > 500) throw new ErrorArchivo("Máximo 500 posiciones por archivo.");
  return { filas, excluidas };
}
