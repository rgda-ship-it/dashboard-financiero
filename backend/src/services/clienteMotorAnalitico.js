/**
 * Cliente hacia el motor analítico Python (servicio interno).
 *
 * Node.js nunca ejecuta lógica de análisis técnico directamente — solo
 * orquesta y sirve. Esta es la única puerta de entrada al servicio Python,
 * tal como definió el Arquitecto en el contrato de interfaz.
 */

const ANALYTICS_HOST = process.env.ANALYTICS_SERVICE_HOST || "localhost";
const ANALYTICS_PORT = process.env.ANALYTICS_SERVICE_PORT || 8001;
const ANALYTICS_TOKEN = process.env.ANALYTICS_SERVICE_INTERNAL_TOKEN;

const BASE_URL = `http://${ANALYTICS_HOST}:${ANALYTICS_PORT}`;

async function llamarServicioInterno(path, payload) {
  const resp = await fetch(`${BASE_URL}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Internal-Token": ANALYTICS_TOKEN,
    },
    body: JSON.stringify(payload),
  });

  if (!resp.ok) {
    const texto = await resp.text().catch(() => "");
    throw new Error(
      `Motor analítico respondió ${resp.status}: ${texto || "sin detalle"}`
    );
  }

  return resp.json();
}

export async function ejecutarEscaneo(tickers) {
  return llamarServicioInterno("/internal/scan", { tickers });
}

export async function analizarPosicion({ ticker, precioCompra }) {
  return llamarServicioInterno("/internal/analyze-position", {
    ticker,
    precio_compra: precioCompra,
    // Nota deliberada: NO se envía el monto invertido a este endpoint.
    // El monto se usa solo en Node.js para calcular P&L informativo,
    // nunca llega al motor de decisión de rotación (regla del Modo
    // Diagnóstico, checklist del Risk Manager punto #6).
  });
}
