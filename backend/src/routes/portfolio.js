import { Router } from "express";
import multer from "multer";
import {
  parsearYSanitizarCSV,
  ErrorArchivoInvalido,
} from "../middleware/sanitizacionArchivos.js";
import { analizarPosicion } from "../services/clienteMotorAnalitico.js";
import {
  guardarCarteraCifrada,
  obtenerCarteraDescifrada,
  borrarCarteraReal,
  registrarConsentimiento,
} from "../services/persistenciaCartera.js";
import { emitirDeterioro } from "../services/websocket.js";

const router = Router();

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 5 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const tiposPermitidos = ["text/csv", "application/vnd.ms-excel"];
    if (!tiposPermitidos.includes(file.mimetype)) {
      return cb(new ErrorArchivoInvalido("Tipo de archivo no permitido."));
    }
    cb(null, true);
  },
});

/**
 * Carga de cartera. Devuelve las posiciones válidas ya sanitizadas y
 * cualquier fila excluida con su motivo — nunca rompe por una fila mala.
 *
 * `guardarPersistente` controla si se persiste (requiere que el usuario
 * haya marcado el consentimiento correspondiente en el frontend).
 */
router.post("/upload", upload.single("archivo"), async (req, res) => {
  if (!req.file) {
    return res.status(400).json({ error: "No se recibió ningún archivo." });
  }

  try {
    const { posicionesValidas, filasExcluidas } = parsearYSanitizarCSV(
      req.file.buffer
    );

    if (posicionesValidas.length === 0) {
      return res.status(422).json({
        error: "El archivo no contiene posiciones válidas.",
        filasExcluidas,
      });
    }

    const guardarPersistente = req.body.guardarPersistente === "true";

    req.session = req.session || {};
    req.session.posicionesCartera = posicionesValidas;

    if (guardarPersistente) {
      // Cifrado por posición (Ticker/Precio/Monto) antes de tocar la DB —
      // ver checklist de auditoría de cifrado, Sprint 4.
      await guardarCarteraCifrada(posicionesValidas);
      await registrarConsentimiento("persistencia_cartera", true);
    }

    res.json({
      posicionesCargadas: posicionesValidas.length,
      filasExcluidas,
      persistido: guardarPersistente,
    });
  } catch (err) {
    if (err instanceof ErrorArchivoInvalido) {
      return res.status(422).json({ error: err.message });
    }
    res.status(500).json({ error: "Error inesperado al procesar el archivo." });
  }
});

/**
 * Diagnóstico de las posiciones cargadas.
 *
 * REGLA NO NEGOCIABLE: `analizarPosicion` nunca recibe el monto invertido.
 * El monto solo se usa aquí, localmente, para calcular P&L informativo.
 */
router.get("/analyze", async (req, res) => {
  const posiciones = req.session?.posicionesCartera;

  if (!posiciones || posiciones.length === 0) {
    return res.status(404).json({ error: "No hay una cartera cargada en esta sesión." });
  }

  try {
    const diagnosticos = await Promise.all(
      posiciones.map(async (posicion) => {
        const analisis = await analizarPosicion({
          ticker: posicion.ticker,
          precioCompra: posicion.precioCompra,
        });

        const pnlPct =
          ((analisis.precio_actual - posicion.precioCompra) / posicion.precioCompra) * 100;
        const pnlAbsoluto = posicion.monto * (pnlPct / 100);

        if (analisis.nivel_salud === "rojo") {
          emitirDeterioro(posicion.ticker, analisis.mensaje);
        }

        return {
          ticker: posicion.ticker,
          precioActual: analisis.precio_actual,
          pnlPct: Number(pnlPct.toFixed(2)),
          pnlAbsoluto: Number(pnlAbsoluto.toFixed(2)),
          nivelSalud: analisis.nivel_salud,
          mensaje: analisis.mensaje,
          // Si hay deterioro confirmado, se muestra una sugerencia de
          // rotación que usa el TP/SL genérico del activo destino — el
          // MISMO que ve cualquier usuario del escáner general, nunca
          // recalculado en función de `posicion.monto`.
          sugerenciaRotacion: analisis.sugerencia_rotacion ?? null,
        };
      })
    );

    res.json({ diagnosticos });
  } catch (err) {
    res.status(503).json({
      error: "No se pudo completar el diagnóstico de cartera.",
      detalle: err.message,
    });
  }
});

/**
 * Restaura una cartera previamente guardada (consentimiento de persistencia
 * otorgado en una sesión anterior). Descifra en memoria, nunca en la
 * respuesta se exponen los valores cifrados crudos de la DB.
 */
router.get("/restore", async (req, res) => {
  try {
    const posiciones = await obtenerCarteraDescifrada();
    if (posiciones.length === 0) {
      return res.status(404).json({ error: "No hay una cartera persistida guardada." });
    }
    req.session = req.session || {};
    req.session.posicionesCartera = posiciones;
    res.json({ posicionesRestauradas: posiciones.length });
  } catch (err) {
    res.status(500).json({ error: "No se pudo restaurar la cartera.", detalle: err.message });
  }
});

router.delete("/", async (req, res) => {
  if (req.session) {
    delete req.session.posicionesCartera;
  }

  try {
    // Borrado REAL (no soft-delete) en la base de datos, además de la
    // sesión en memoria — derecho de supresión RGPD, DPO Sprint 1.
    await borrarCarteraReal();
    res.status(204).send();
  } catch (err) {
    res.status(500).json({ error: "No se pudo completar el borrado.", detalle: err.message });
  }
});

export default router;
