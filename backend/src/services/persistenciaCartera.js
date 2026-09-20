/**
 * Persistencia de cartera del Portfolio Health Selector.
 *
 * Solo se invoca cuando el usuario marcó explícitamente el consentimiento
 * de guardado (checkbox opcional, desmarcado por defecto — DPO Sprint 1).
 * Uso de un solo usuario local: no hay `user_id` porque el sistema corre
 * en localhost para una sola persona: si en el futuro se soporta más de
 * un usuario, esta es la primera tabla que necesita esa columna.
 */

import pg from "pg";
import { cifrarNumero, descifrarNumero } from "./cifrado.js";

const { Pool } = pg;

let pool;

function obtenerPool() {
  if (!pool) {
    pool = new Pool({
      host: process.env.DB_HOST,
      port: process.env.DB_PORT,
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
    });
  }
  return pool;
}

export async function registrarConsentimiento(tipo, otorgado) {
  const db = obtenerPool();
  await db.query(
    "INSERT INTO registro_consentimiento (tipo, otorgado) VALUES ($1, $2)",
    [tipo, otorgado]
  );
}

/**
 * Guarda la cartera cifrada. Reemplaza cualquier cartera previa guardada
 * (un usuario local, una cartera activa a la vez) en una única transacción.
 */
export async function guardarCarteraCifrada(posiciones) {
  const db = obtenerPool();
  const cliente = await db.connect();

  try {
    await cliente.query("BEGIN");
    await cliente.query("DELETE FROM cartera_posiciones");

    for (const posicion of posiciones) {
      await cliente.query(
        `INSERT INTO cartera_posiciones (ticker, precio_compra_cifrado, monto_cifrado)
         VALUES ($1, $2, $3)`,
        [
          posicion.ticker,
          cifrarNumero(posicion.precioCompra),
          cifrarNumero(posicion.monto),
        ]
      );
    }

    await cliente.query("COMMIT");
  } catch (err) {
    await cliente.query("ROLLBACK");
    throw err;
  } finally {
    cliente.release();
  }
}

export async function obtenerCarteraDescifrada() {
  const db = obtenerPool();
  const { rows } = await db.query(
    "SELECT ticker, precio_compra_cifrado, monto_cifrado FROM cartera_posiciones"
  );

  return rows.map((fila) => ({
    ticker: fila.ticker,
    precioCompra: descifrarNumero(fila.precio_compra_cifrado),
    monto: descifrarNumero(fila.monto_cifrado),
  }));
}

/**
 * Borrado REAL (no soft-delete) — derecho de supresión RGPD, DPO Sprint 1.
 * Se usa DELETE físico, nunca una columna "activo = false".
 */
export async function borrarCarteraReal() {
  const db = obtenerPool();
  await db.query("DELETE FROM cartera_posiciones");
  await registrarConsentimiento("persistencia_cartera", false);
}
