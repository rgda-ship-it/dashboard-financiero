/**
 * Cifrado de campos sensibles de la cartera (precio de compra, monto).
 *
 * AES-256-GCM: cifrado autenticado — además de ocultar el valor, detecta
 * si el dato cifrado fue alterado. La clave NUNCA vive en la misma base
 * de datos que el dato cifrado (checklist de auditoría, Sprint 4, punto #2)
 * — sale exclusivamente de `PORTFOLIO_ENCRYPTION_KEY` en `.env`.
 */

import crypto from "node:crypto";

const ALGORITMO = "aes-256-gcm";

function obtenerClave() {
  const claveHex = process.env.PORTFOLIO_ENCRYPTION_KEY;
  if (!claveHex || claveHex === "cambiar_esto_por_una_clave_generada") {
    throw new Error(
      "PORTFOLIO_ENCRYPTION_KEY no está configurada. " +
        "Genera una con: python -c \"import secrets; print(secrets.token_hex(32))\""
    );
  }
  const clave = Buffer.from(claveHex, "hex");
  if (clave.length !== 32) {
    throw new Error("PORTFOLIO_ENCRYPTION_KEY debe ser una clave de 32 bytes en hex.");
  }
  return clave;
}

/**
 * Cifra un valor numérico. Devuelve un string serializado listo para
 * guardar en una columna de texto: "iv:tag:ciphertext" en hex.
 */
export function cifrarNumero(valor) {
  const clave = obtenerClave();
  const iv = crypto.randomBytes(12); // recomendado para GCM
  const cipher = crypto.createCipheriv(ALGORITMO, clave, iv);

  const texto = String(valor);
  const cifrado = Buffer.concat([cipher.update(texto, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();

  return [iv.toString("hex"), tag.toString("hex"), cifrado.toString("hex")].join(":");
}

export function descifrarNumero(valorCifrado) {
  const clave = obtenerClave();
  const [ivHex, tagHex, cifradoHex] = valorCifrado.split(":");
  if (!ivHex || !tagHex || !cifradoHex) {
    throw new Error("Formato de dato cifrado inválido.");
  }

  const iv = Buffer.from(ivHex, "hex");
  const tag = Buffer.from(tagHex, "hex");
  const cifrado = Buffer.from(cifradoHex, "hex");

  const decipher = crypto.createDecipheriv(ALGORITMO, clave, iv);
  decipher.setAuthTag(tag);

  const descifrado = Buffer.concat([decipher.update(cifrado), decipher.final()]);
  return Number(descifrado.toString("utf8"));
}
