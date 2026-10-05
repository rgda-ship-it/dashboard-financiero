/**
 * Paginación en el cliente: la tabla de operaciones de los agentes ya
 * trae hasta 200 filas y pintarlas todas hacía la pantalla interminable.
 */

/** La página pedida, acotada a las que existen (al filtrar puede sobrar). */
export function paginar(filas, pagina, porPagina) {
  const paginas = Math.max(1, Math.ceil(filas.length / porPagina));
  const actual = Math.min(Math.max(1, pagina), paginas);
  const desde = (actual - 1) * porPagina;
  return {
    filas: filas.slice(desde, desde + porPagina),
    pagina: actual,
    paginas,
    desde: filas.length === 0 ? 0 : desde + 1,
    hasta: Math.min(desde + porPagina, filas.length),
  };
}
