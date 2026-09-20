/**
 * Sanitización de archivos de cartera (CSV/Excel).
 *
 * Implementa los vectores de ataque identificados en el pentesting de
 * Sprint 4:
 *  - CSV injection (fórmulas ejecutables)
 *  - Extensión falsificada (valida contenido real, no solo el nombre)
 *  - Límite de tamaño
 *  - Solo se extraen las columnas esperadas (minimización de datos, DPO)
 */

import { parse } from "csv-parse/sync";

const TAMANO_MAXIMO_BYTES = 5 * 1024 * 1024; // 5 MB
const COLUMNAS_ESPERADAS = ["Ticker", "Precio de Compra", "Monto"];

// Caracteres que, al inicio de una celda, pueden ejecutarse como fórmula
// en Excel/Sheets al reabrir un CSV exportado (CSV injection clásico).
const PREFIJOS_FORMULA_PELIGROSOS = ["=", "+", "-", "@"];

export class ErrorArchivoInvalido extends Error {}

function neutralizarCeldaSospechosa(valor) {
  if (typeof valor !== "string") return valor;
  const primero = valor.trimStart()[0];
  if (PREFIJOS_FORMULA_PELIGROSOS.includes(primero)) {
    // Se antepone un apóstrofe para forzar interpretación como texto plano,
    // igual que hacen las herramientas ofimáticas al "limpiar" CSV.
    return `'${valor}`;
  }
  return valor;
}

function validarTipoRealDelArchivo(buffer) {
  // Validación mínima de contenido: un CSV/XLSX real no debería empezar
  // con encabezados de ejecutables/binarios comunes. Esto es un chequeo
  // básico adicional a la validación de mimetype de multer, no un
  // reemplazo de un antivirus real.
  const firmasProhibidas = [
    Buffer.from([0x4d, 0x5a]), // .exe / .dll (MZ header)
  ];
  for (const firma of firmasProhibidas) {
    if (buffer.subarray(0, firma.length).equals(firma)) {
      throw new ErrorArchivoInvalido(
        "El archivo no parece ser un CSV/Excel válido (firma binaria sospechosa)."
      );
    }
  }
}

/**
 * Parsea y sanitiza un buffer CSV, devolviendo solo las filas y columnas
 * esperadas. Filas inválidas se excluyen y se reportan, no rompen el resto
 * del archivo (caso de prueba QA #3).
 */
export function parsearYSanitizarCSV(buffer) {
  if (buffer.length > TAMANO_MAXIMO_BYTES) {
    throw new ErrorArchivoInvalido(
      `Archivo supera el tamaño máximo permitido (${TAMANO_MAXIMO_BYTES / 1024 / 1024} MB).`
    );
  }

  validarTipoRealDelArchivo(buffer);

  let registros;
  try {
    registros = parse(buffer, {
      columns: true,
      skip_empty_lines: true,
      trim: true,
    });
  } catch (err) {
    throw new ErrorArchivoInvalido(
      "No se pudo interpretar el archivo como CSV. Verifica encabezados y formato."
    );
  }

  const columnasPresentes = registros.length > 0 ? Object.keys(registros[0]) : [];
  const faltantes = COLUMNAS_ESPERADAS.filter((c) => !columnasPresentes.includes(c));
  if (faltantes.length > 0) {
    throw new ErrorArchivoInvalido(
      `Formato no reconocido — encabezados requeridos: ${COLUMNAS_ESPERADAS.join(", ")}. ` +
        `Faltantes: ${faltantes.join(", ")}`
    );
  }

  const posicionesValidas = [];
  const filasExcluidas = [];

  for (const [indice, fila] of registros.entries()) {
    // Minimización de datos: solo se conservan las 3 columnas esperadas,
    // cualquier otra columna del archivo se descarta explícitamente aquí.
    const ticker = neutralizarCeldaSospechosa(fila["Ticker"]);
    const precioCompraRaw = neutralizarCeldaSospechosa(fila["Precio de Compra"]);
    const montoRaw = neutralizarCeldaSospechosa(fila["Monto"]);

    const precioCompra = normalizarNumero(precioCompraRaw);
    const monto = normalizarNumero(montoRaw);

    if (!ticker || precioCompra === null || monto === null) {
      filasExcluidas.push({
        fila: indice + 1,
        motivo: "datos incompletos o no numéricos (el decimal va con punto: 184.72)",
      });
      continue;
    }

    posicionesValidas.push({
      ticker: String(ticker).trim().toUpperCase(),
      precioCompra,
      monto,
    });
  }

  return { posicionesValidas, filasExcluidas };
}

/**
 * Formato numérico del CSV: el punto es SIEMPRE el separador decimal
 * (decisión del dueño del proyecto, 2026-09-19).
 *
 * Antes este parser asumía formato es-ES: borraba todos los puntos como
 * millares y convertía la coma en decimal, así que "184.72" se leía como
 * 18472 — la fila se aceptaba como válida con el precio multiplicado por
 * 100 y nada avisaba.
 *
 * Ahora la coma solo se admite como separador de millares bien agrupado
 * ("1,200.50"). Cualquier otro uso —sobre todo una coma decimal como
 * "184,72"— invalida la fila en vez de adivinar: un número ambiguo acaba
 * en `filasExcluidas`, nunca se reinterpreta en silencio.
 */
const PATRON_MILLARES = /^-?\d{1,3}(,\d{3})+(\.\d+)?$/;
// Tras limpiar, solo se acepta un decimal plano. Deja fuera lo que
// Number() aceptaría pero nadie escribe en una cartera: "1e3", "0x10",
// "Infinity", o "5." y ".5".
const PATRON_DECIMAL = /^-?\d+(\.\d+)?$/;

function normalizarNumero(valor) {
  if (valor === undefined || valor === null || valor === "") return null;
  let limpio = String(valor)
    .replace(/^'/, "") // por si quedó el apóstrofe de neutralización
    .replace(/[$€]/g, "")
    .trim();

  if (limpio.includes(",")) {
    if (!PATRON_MILLARES.test(limpio)) return null;
    limpio = limpio.replace(/,/g, "");
  }

  if (!PATRON_DECIMAL.test(limpio)) return null;
  return Number(limpio);
}
