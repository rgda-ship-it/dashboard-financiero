/**
 * WebSocket del sistema: transmite en tiempo real los eventos que antes
 * solo se mostraban al recargar — cambios de fase, deterioro detectado,
 * estado del circuit breaker. Reemplaza las notificaciones/disclaimers
 * del diseño original por el EventLog de la terminal (Sprint 3).
 */

import { WebSocketServer } from "ws";

let wss;
const clientesConectados = new Set();

export function iniciarWebSocket(servidorHttp) {
  wss = new WebSocketServer({ server: servidorHttp, path: "/ws/events" });

  wss.on("connection", (socket) => {
    clientesConectados.add(socket);
    socket.send(JSON.stringify({ tipo: "sys", mensaje: "[SYS] Conectado al stream de eventos." }));

    socket.on("close", () => clientesConectados.delete(socket));
  });

  console.log("[SYS] WebSocket de eventos activo en /ws/events");
}

/**
 * Emite un evento a todos los clientes conectados. Si el WebSocket aún no
 * se inicializó (ej. en tests), no falla — simplemente no emite nada.
 */
export function emitirEvento(tipo, mensaje, datosAdicionales = {}) {
  if (!wss) return;

  const payload = JSON.stringify({
    tipo,
    mensaje,
    timestamp: new Date().toISOString(),
    ...datosAdicionales,
  });

  for (const socket of clientesConectados) {
    if (socket.readyState === socket.OPEN) {
      socket.send(payload);
    }
  }
}

// Helpers específicos para los tipos de evento ya definidos en el proyecto.
export function emitirCambioFase(evento) {
  emitirEvento("cambio_fase", `[SYS] ${evento.detalle}`, {
    faseAnterior: evento.fase_anterior,
    faseNueva: evento.fase_nueva,
    criterio: evento.criterio,
  });
}

export function emitirDeterioro(ticker, mensaje) {
  emitirEvento("deterioro", `[LOG] ${ticker}: ${mensaje}`, { ticker });
}

export function emitirEstadoProveedor(nombreProveedor, mensaje) {
  emitirEvento("proveedor", `[SYS] ${mensaje}`, { proveedor: nombreProveedor });
}
