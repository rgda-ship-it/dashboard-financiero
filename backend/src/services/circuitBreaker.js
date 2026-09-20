/**
 * Circuit breaker simple: si un servicio falla repetidamente, deja de
 * insistir y sirve el último dato válido en caché, en vez de romper el
 * escaneo completo (riesgo identificado por el Data Engineer, Sprint 2).
 */

const UMBRAL_FALLOS_CONSECUTIVOS = 3;
const TIEMPO_ENFRIAMIENTO_MS = 60_000; // 1 minuto antes de reintentar

class CircuitBreaker {
  constructor(nombre) {
    this.nombre = nombre;
    this.fallosConsecutivos = 0;
    this.abierto = false;
    this.ultimoFalloEn = null;
    this.ultimoDatoValido = null;
    this.ultimaActualizacionValida = null;
  }

  estaAbierto() {
    if (!this.abierto) return false;
    const tiempoTranscurrido = Date.now() - this.ultimoFalloEn;
    if (tiempoTranscurrido > TIEMPO_ENFRIAMIENTO_MS) {
      // Permite un intento de "media apertura" tras el enfriamiento.
      this.abierto = false;
      return false;
    }
    return true;
  }

  async ejecutar(fn) {
    if (this.estaAbierto()) {
      return this._resultadoDesdeCache(
        `${this.nombre}: circuito abierto, sirviendo caché.`
      );
    }

    try {
      const resultado = await fn();
      this.fallosConsecutivos = 0;
      this.ultimoDatoValido = resultado;
      this.ultimaActualizacionValida = new Date();
      return { ok: true, datos: resultado, desdeCache: false };
    } catch (err) {
      this.fallosConsecutivos += 1;
      this.ultimoFalloEn = Date.now();

      if (this.fallosConsecutivos >= UMBRAL_FALLOS_CONSECUTIVOS) {
        this.abierto = true;
      }

      if (this.ultimoDatoValido !== null) {
        return this._resultadoDesdeCache(
          `${this.nombre}: fallo (${err.message}), sirviendo caché.`
        );
      }

      throw err;
    }
  }

  _resultadoDesdeCache(mensaje) {
    return {
      ok: true,
      datos: this.ultimoDatoValido,
      desdeCache: true,
      mensaje,
      ultimaActualizacionValida: this.ultimaActualizacionValida,
    };
  }
}

const registrosCircuitBreaker = new Map();

export function obtenerCircuitBreaker(nombre) {
  if (!registrosCircuitBreaker.has(nombre)) {
    registrosCircuitBreaker.set(nombre, new CircuitBreaker(nombre));
  }
  return registrosCircuitBreaker.get(nombre);
}
