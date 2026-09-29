/**
 * Cálculos de presentación de la vista de agentes, sin dependencias para
 * poder probarlos con `node --test` (igual que `frescura.js`).
 *
 * Nada de esto decide una operación: son la forma de DIBUJAR lo que la base
 * de datos ya calculó. La curva teórica, por ejemplo, llega hecha desde
 * `v_curva_agentes`; aquí solo se ordena y se coloca en pantalla.
 */

/** Días que faltan para el objetivo final si se cumpliera la meta cada día
 *  operable: n = ln(objetivo / equity) / ln(1 + p). Es la cifra del doc 03
 *  §1.1 (384 / 156 / 113 días desde 500 $), recalculada desde el equity de hoy. */
export function diasHastaObjetivo(equity, objetivo, metaPct) {
  const e = Number(equity);
  const o = Number(objetivo);
  const p = Number(metaPct) / 100;
  if (!(e > 0) || !(o > 0) || !(p > 0)) return null;
  if (e >= o) return 0;
  return Math.ceil(Math.log(o / e) / Math.log(1 + p));
}

/**
 * Una serie por agente con su curva real y la teórica, solo de su cuenta
 * VIGENTE: tras un reinicio, la cuenta vieja es otra historia y mezclarla
 * dibujaría un salto que no ocurrió.
 *
 * El punto de hoy aún no tiene `saldo_cierre`: se usa el equity vivo del
 * marcador, que es lo que el día vale ahora mismo.
 */
export function construirSeries(curvas, ranking) {
  return (ranking ?? []).map((agente) => {
    const filas = (curvas ?? [])
      .filter((c) => c.agente_id === agente.agente_id && c.cuenta_id === agente.cuenta_id)
      .sort((a, b) => (a.fecha < b.fecha ? -1 : 1));
    const puntos = filas.map((c) => ({
      fecha: c.fecha,
      real: Number(
        c.saldo_cierre ?? (c.fecha === agente.hoy_fecha ? agente.equity : c.saldo_apertura)
      ),
      teorica: Number(c.saldo_teorico),
      cumplido: c.cumplido,
      operable: c.operable,
    }));
    return { agenteId: agente.agente_id, nombre: agente.nombre, puntos };
  });
}

/** Todas las fechas presentes, ordenadas y sin repetir. */
export function fechasDe(series) {
  return [...new Set(series.flatMap((s) => s.puntos.map((p) => p.fecha)))].sort();
}

/**
 * Escala logarítmica en y. Es la forma honesta de mirar interés compuesto:
 * una meta diaria constante es una RECTA en escala log, así que la curva
 * teórica se lee de un vistazo y la real se separa de ella en proporción,
 * no en dólares. En escala lineal, 500 × 1,07^n aplasta a las otras dos
 * contra el eje en pocas semanas.
 */
export function escalaLog(min, max, alto, margen = 0) {
  const a = Math.log(min);
  const b = Math.log(max);
  const rango = b - a || 1;
  return (v) => margen + (alto - 2 * margen) * (1 - (Math.log(v) - a) / rango);
}

/** Dominio del eje y con un respiro del 4 % por arriba y por abajo. */
export function dominio(series) {
  const valores = series
    .flatMap((s) => s.puntos.flatMap((p) => [p.real, p.teorica]))
    .filter((v) => Number.isFinite(v) && v > 0);
  if (valores.length === 0) return [100, 1000];
  let min = Math.min(...valores);
  let max = Math.max(...valores);
  if (max / min < 1.02) {
    min *= 0.98;
    max *= 1.02;
  }
  return [min / 1.04, max * 1.04];
}

/**
 * Marcas del eje. Con un rango amplio (×3 o más), las de una escala log
 * clásica —1, 2, 5 por década—; con un rango estrecho, que es lo normal en
 * las primeras semanas, pasos lineales «redondos», porque 1-2-5 dejaría el
 * eje sin ninguna marca entre 480 y 540.
 */
export function marcasEje(min, max, objetivo = 5) {
  if (!(min > 0) || !(max > min)) return [];
  if (max / min >= 3) {
    const marcas = [];
    for (let d = Math.floor(Math.log10(min)); d <= Math.ceil(Math.log10(max)); d += 1) {
      for (const m of [1, 2, 5]) {
        const v = m * 10 ** d;
        if (v >= min && v <= max) marcas.push(v);
      }
    }
    return marcas;
  }
  const bruto = (max - min) / objetivo;
  const potencia = 10 ** Math.floor(Math.log10(bruto));
  const paso = [1, 2, 2.5, 5, 10].map((f) => f * potencia).find((p) => p >= bruto) ?? bruto;
  const marcas = [];
  for (let v = Math.ceil(min / paso) * paso; v <= max; v += paso) {
    marcas.push(Number(v.toFixed(6)));
  }
  return marcas;
}
