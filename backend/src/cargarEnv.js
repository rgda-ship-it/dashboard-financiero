/**
 * Carga el .env COMPARTIDO de la raíz del proyecto.
 *
 * El README (§0) define un único .env en la raíz: el
 * ANALYTICS_SERVICE_INTERNAL_TOKEN es "token compartido entre backend y
 * motor analítico". Pero `import "dotenv/config"` resuelve el archivo
 * relativo a process.cwd(), que es backend/ al correr `npm start` desde
 * ahí — así que Node cargaba un backend/.env duplicado en vez del de la
 * raíz. Los dos archivos tenían tokens distintos, y como servicio_interno.py
 * sí lee el de la raíz, TODAS las llamadas al motor analítico morían con
 * 401 "Token interno inválido" y el dashboard quedaba sin datos.
 *
 * Resolviendo la ruta desde este archivo, el cwd deja de importar y vuelve
 * a haber una única fuente de verdad.
 *
 * IMPORTANTE: este módulo debe importarse ANTES que cualquier otro que lea
 * process.env en su cuerpo de módulo (p. ej. services/clienteMotorAnalitico.js,
 * que fija el token en una const al cargarse). Los imports de ESM se evalúan
 * en orden, así que basta con dejarlo primero en server.js.
 */

import path from "node:path";
import { fileURLToPath } from "node:url";
import dotenv from "dotenv";

const RAIZ_PROYECTO = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../.."
);

dotenv.config({ path: path.join(RAIZ_PROYECTO, ".env") });
