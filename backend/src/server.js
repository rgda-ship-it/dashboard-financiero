// Debe ir PRIMERO: carga el .env de la raíz antes de que cualquier otro
// módulo lea process.env al evaluarse (ver cargarEnv.js).
import "./cargarEnv.js";

import express from "express";
import cors from "cors";
import session from "express-session";
import rateLimit from "express-rate-limit";
import http from "node:http";

import escanerRouter from "./routes/escaner.js";
import portfolioRouter from "./routes/portfolio.js";
import { iniciarWebSocket } from "./services/websocket.js";

const app = express();
const PORT = process.env.API_PORT || 3000;

app.use(cors({ origin: "http://localhost:5173", credentials: true }));
app.use(express.json());

// Sesión en memoria — suficiente para un backend de un solo usuario en
// localhost (ver nota en persistenciaCartera.js). Sin esto, req.session
// no existe y el flujo de carga/diagnóstico de cartera nunca funciona,
// porque cada request HTTP llega con un objeto req nuevo.
if (!process.env.SESSION_SECRET) {
  throw new Error(
    "SESSION_SECRET no está configurada en .env. Genera una con: " +
      'python3 -c "import secrets; print(secrets.token_hex(32))"'
  );
}
app.use(
  session({
    secret: process.env.SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      sameSite: "lax",
      secure: false, // localhost por HTTP — poner true si se sirve por HTTPS
      maxAge: 24 * 60 * 60 * 1000, // 24h
    },
  })
);

// Rate limiting — recomendación de Ciberseguridad Sprint 1: incluso siendo
// uso personal, protege contra un fallo del propio frontend que reintente
// sin control, o contra scraping si el sistema se expone alguna vez.
const limitadorGeneral = rateLimit({
  windowMs: 60 * 1000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
});
app.use(limitadorGeneral);

app.get("/api/health", (req, res) => {
  res.json({ estado: "ok", timestamp: new Date().toISOString() });
});

app.use("/api/scanner", escanerRouter);
app.use("/api/portfolio", portfolioRouter);

app.use((err, req, res, next) => {
  console.error("[ERROR]", err);
  res.status(500).json({ error: "Error interno del servidor." });
});

// Se usa un servidor HTTP crudo (no app.listen directo) para que Express
// y el WebSocket compartan el mismo puerto, tal como definió el Arquitecto.
const servidorHttp = http.createServer(app);
iniciarWebSocket(servidorHttp);

servidorHttp.listen(PORT, () => {
  console.log(`[SYS] Backend escuchando en http://localhost:${PORT}`);
});
