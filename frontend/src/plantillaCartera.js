/**
 * Plantilla CSV de cartera.
 *
 * Las tres columnas son exactamente las que exige
 * `backend/src/middleware/sanitizacionArchivos.js`; cualquier otra se
 * descarta al cargar (minimización de datos). Los números van con punto
 * decimal, que es el único formato que acepta el backend: una coma solo
 * se admite como separador de millares bien agrupado ("1,200.50").
 *
 * Sin BOM a propósito: el parser del backend no lo consume, así que un
 * BOM convertiría el primer encabezado en "\uFEFFTicker" y la carga
 * fallaría con "Formato no reconocido".
 */

const FILAS_EJEMPLO = [
  ["NVDA", "156.20", "5000"],
  ["AAPL", "221.40", "3000"],
  ["BITCOIN", "95300.00", "2500"],
];

export const ENCABEZADOS = ["Ticker", "Precio de Compra", "Monto"];

export function construirCSVModelo() {
  // Sin comillas: con punto decimal ningún valor contiene el separador
  // del CSV, así que el archivo queda legible tal cual en cualquier editor.
  const lineas = [ENCABEZADOS.join(","), ...FILAS_EJEMPLO.map((fila) => fila.join(","))];
  return `${lineas.join("\r\n")}\r\n`;
}

export function descargarCSVModelo() {
  const blob = new Blob([construirCSVModelo()], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const enlace = document.createElement("a");
  enlace.href = url;
  enlace.download = "cartera-modelo.csv";
  document.body.appendChild(enlace);
  enlace.click();
  enlace.remove();
  // Sin revoke, el blob queda retenido en memoria hasta recargar la página.
  URL.revokeObjectURL(url);
}

export const FILAS_MODELO = FILAS_EJEMPLO;
