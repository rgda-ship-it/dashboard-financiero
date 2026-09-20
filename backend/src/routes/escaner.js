import { Router } from "express";
import { ejecutarEscaneo } from "../services/clienteMotorAnalitico.js";
import { obtenerCircuitBreaker } from "../services/circuitBreaker.js";

const router = Router();

// Universo de activos del escáner. En una versión posterior esto puede
// venir de configuración/DB — se deja como constante simple por ahora.
const UNIVERSO_ACCIONES = ["O", "QFIN", "GM", "UAL","BAC", "F", "EWY", "CLX", "AMCR", "TROW", "NLY", "KMB", "IBM", "WFC", "MO", "SSTK", "HRL", "CSCO", "AGNC", "CCOI", "FLO"];
const UNIVERSO_CRIPTO = ["bitcoin", "ethereum", "solana"];

router.get("/signals", async (req, res) => {
  const breaker = obtenerCircuitBreaker("motor-analitico:scan");

  try {
    const resultado = await breaker.ejecutar(() =>
      ejecutarEscaneo([...UNIVERSO_ACCIONES, ...UNIVERSO_CRIPTO])
    );

    res.json({
      senales: resultado.datos,
      desdeCache: resultado.desdeCache,
      mensaje: resultado.mensaje ?? null,
      ultimaActualizacion: resultado.ultimaActualizacionValida ?? new Date(),
    });
  } catch (err) {
    res.status(503).json({
      error: "Motor analítico no disponible y sin datos en caché.",
      detalle: err.message,
    });
  }
});

export default router;
