import { test } from "node:test";
import assert from "node:assert/strict";
import { filasReferencia } from "./comparativa.js";

test("la referencia junta las dos ventanas de cada vara, en orden fijo", () => {
  const vista = [
    { referencia: "cripto", ventana: "alta", activos: 15, hasta: "2026-11-05", rentabilidad_pct: -15.21 },
    { referencia: "acciones", ventana: "experimento", activos: 33, hasta: "2026-11-04", rentabilidad_pct: 2.79 },
    { referencia: "acciones", ventana: "alta", activos: 33, hasta: "2026-11-04", rentabilidad_pct: 3.7 },
  ];
  const filas = filasReferencia(vista);
  assert.deepEqual(filas.map((f) => f.referencia), ["acciones", "cripto"]);
  assert.equal(filas[0].rentabilidad_pct, 3.7);
  assert.equal(filas[0].rentabilidad_exp_pct, 2.79);
  assert.equal(filas[1].rentabilidad_exp_pct, null);
});

test("sin la vista (migración sin aplicar) no hay filas de referencia", () => {
  assert.deepEqual(filasReferencia([]), []);
  assert.deepEqual(filasReferencia(null), []);
});

test("operaciones que faltan para concluir: n ≥ (1,645 × σ / E)²", async () => {
  const { paraConcluir, textoConcluir } = await import("./comparativa.js");
  // Cadencia el 2026-11-05: 58 cierres, +0,328 R, σ 3,44 → 298 necesarias.
  assert.deepEqual(paraConcluir(58, 0.328, 3.44), { necesarias: 298, faltan: 240 });
  assert.equal(textoConcluir(paraConcluir(58, 0.328, 3.44)), "faltan 240 para concluir");
  assert.equal(textoConcluir(paraConcluir(25, 0, 1.04)), "expectativa 0: no se concluye");
  assert.equal(textoConcluir(paraConcluir(400, 0.5, 1)), "ya se puede concluir");
  assert.equal(paraConcluir(1, -1, null), null);
});

test("los índices (0058) van entre las acciones y las criptos", () => {
  const vista = [
    { referencia: "nasdaq100", ventana: "alta", activos: 1, hasta: "2026-11-05", rentabilidad_pct: 1.2 },
    { referencia: "cripto", ventana: "alta", activos: 15, hasta: "2026-11-05", rentabilidad_pct: -20 },
    { referencia: "sp500", ventana: "alta", activos: 1, hasta: "2026-11-05", rentabilidad_pct: 0.5 },
    { referencia: "acciones", ventana: "alta", activos: 33, hasta: "2026-11-05", rentabilidad_pct: -0.4 },
  ];
  assert.deepEqual(filasReferencia(vista).map((f) => f.referencia), ["acciones", "sp500", "nasdaq100", "cripto"]);
});

test("el veredicto dice lo que falta en una frase", async () => {
  const { textoVeredicto, textoConcordancia, ESTADO_VEREDICTO } = await import("./comparativa.js");
  assert.equal(textoVeredicto({ estado: "pocas_operaciones", cerradas: 12, operaciones_min: 30 }), "12 de 30 cierres para juzgar");
  assert.equal(textoVeredicto({ estado: "pausar", drawdown_pct: -36.5, caida_max_pct: 35 }), "caída de 36,5 % (tope 35 %)");
  assert.equal(textoConcordancia({ concuerda_lab: null }), null);
  assert.match(textoConcordancia({ concuerda_lab: false }), /revisar/);
  for (const e of ["pocas_operaciones", "observar", "validado", "sin_ventaja", "retirar", "pausar"]) {
    assert.ok(ESTADO_VEREDICTO[e]);
  }
});
