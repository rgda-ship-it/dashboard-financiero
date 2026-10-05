/**
 * Reglas puras del buscador de la cartera (sin red, para poder probarlas).
 */

/** ¿Parece un símbolo bursátil? Mismo patrón que valida la BD. */
export const pareceAccion = (texto) => /^[A-Z0-9^][A-Z0-9.=^-]{0,14}$/.test(texto.trim().toUpperCase());

/**
 * ¿Se ofrece «Buscar la acción en Yahoo Finance»?
 *
 * Solo la oculta una ACCIÓN del catálogo con ese mismo símbolo. Una cripto
 * con el mismo ticker no cuenta: con la cripto `spcx` en el catálogo, la
 * acción SPCX no se podía añadir (2026-10-05). En la BD no chocan: las
 * acciones se guardan en mayúsculas y las criptos en minúsculas.
 */
export const ofrecerAccion = (texto, resultados) => {
  const q = texto.trim();
  if (!q || !pareceAccion(q)) return false;
  return !resultados.some(
    (r) => r.origen === "catalogo" && r.clase === "accion" && r.simbolo.toUpperCase() === q.toUpperCase()
  );
};
