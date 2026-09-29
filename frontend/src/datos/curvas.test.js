import { test } from "node:test";
import assert from "node:assert/strict";
import { construirSeries, diasHastaObjetivo, dominio, escalaLog, marcasEje } from "./curvas.js";

test("los días hasta el millón son los del doc 03 §1.1", () => {
  assert.equal(diasHastaObjetivo(500, 1_000_000, 2), 384);
  assert.equal(diasHastaObjetivo(500, 1_000_000, 5), 156);
  assert.equal(diasHastaObjetivo(500, 1_000_000, 7), 113);
  assert.equal(diasHastaObjetivo(2_000_000, 1_000_000, 7), 0);
  assert.equal(diasHastaObjetivo(0, 1_000_000, 7), null);
});

test("la serie usa solo la cuenta vigente y el equity vivo para hoy", () => {
  const ranking = [{ agente_id: 1, nombre: "Prudencia", cuenta_id: 20, hoy_fecha: "2026-09-29", equity: 512 }];
  const curvas = [
    { agente_id: 1, cuenta_id: 10, fecha: "2026-09-01", saldo_cierre: 0, saldo_apertura: 3, saldo_teorico: 510 },
    { agente_id: 1, cuenta_id: 20, fecha: "2026-09-29", saldo_cierre: null, saldo_apertura: 505, saldo_teorico: 520 },
    { agente_id: 1, cuenta_id: 20, fecha: "2026-09-28", saldo_cierre: 505, saldo_apertura: 500, saldo_teorico: 510 },
  ];
  const [s] = construirSeries(curvas, ranking);
  assert.deepEqual(s.puntos.map((p) => [p.fecha, p.real]), [
    ["2026-09-28", 505],
    ["2026-09-29", 512],
  ]);
});

test("en escala log, una meta constante es una recta", () => {
  const y = escalaLog(500, 500 * 1.07 ** 10, 100);
  const puntos = [0, 5, 10].map((n) => y(500 * 1.07 ** n));
  assert.ok(Math.abs(puntos[0] - 100) < 1e-9 && Math.abs(puntos[2]) < 1e-9);
  assert.ok(Math.abs(puntos[1] - 50) < 1e-9);
});

test("marcas: 1-2-5 con rango amplio, pasos redondos con rango estrecho", () => {
  assert.deepEqual(marcasEje(300, 6000), [500, 1000, 2000, 5000]);
  assert.deepEqual(marcasEje(480, 540), [480, 500, 520, 540]);
  assert.deepEqual(marcasEje(0, 10), []);
});

test("un dominio plano se abre para que las líneas no queden pegadas", () => {
  const [min, max] = dominio([{ puntos: [{ real: 500, teorica: 500 }] }]);
  assert.ok(min < 490 && max > 510);
});
