/**
 * La referencia de mercado de la comparativa (0056): comprar y mantener el
 * universo desde el alta de los agentes con metas y desde el experimento.
 * Sin dependencias, para poder probarla sin Supabase.
 */

/** Las filas de referencia de la comparativa: la rentabilidad desde el alta
 *  y desde el experimento de cada vara, en un orden fijo. */
export const ORDEN_REFERENCIA = ["universo", "acciones", "cripto", "bitcoin"];
export function filasReferencia(vista) {
  return ORDEN_REFERENCIA.map((referencia) => {
    const de = (ventana) => (vista ?? []).find((v) => v.referencia === referencia && v.ventana === ventana);
    const alta = de("alta");
    const exp = de("experimento");
    if (!alta && !exp) return null;
    return {
      referencia,
      activos: alta?.activos ?? exp?.activos,
      hasta: alta?.hasta ?? exp?.hasta,
      rentabilidad_pct: alta?.rentabilidad_pct ?? null,
      rentabilidad_exp_pct: exp?.rentabilidad_pct ?? null,
    };
  }).filter(Boolean);
}

/**
 * Cuántas operaciones hacen falta para que el intervalo del 90 % de la
 * expectativa deje de incluir el cero, con la desviación observada:
 * n ≥ (1,645 × σ / E)² (doc fase-3/08 §4.3). Evita leer como tendencia lo
 * que es ruido de diez cierres.
 *
 * @returns null sin datos (menos de 2 cierres); si no,
 *          { necesarias, faltan } con `necesarias = Infinity` cuando la
 *          expectativa es cero.
 */
export function paraConcluir(cerradas, expectativa, desviacion) {
  const n = Number(cerradas);
  const e = Math.abs(Number(expectativa));
  const s = Number(desviacion);
  if (!(n >= 2) || !Number.isFinite(e) || !Number.isFinite(s) || desviacion == null) return null;
  if (e < 1e-6) return { necesarias: Infinity, faltan: Infinity };
  const necesarias = Math.ceil(((1.645 * s) / e) ** 2);
  return { necesarias, faltan: Math.max(0, necesarias - n) };
}

/** El texto corto de `paraConcluir` para la comparativa. */
export function textoConcluir(c) {
  if (!c) return null;
  if (!Number.isFinite(c.faltan)) return "expectativa 0: no se concluye";
  if (c.faltan === 0) return "ya se puede concluir";
  return c.faltan > 1000 ? "faltan más de 1.000" : `faltan ${c.faltan.toLocaleString("es-ES")} para concluir`;
}
