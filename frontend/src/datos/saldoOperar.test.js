import { test } from "node:test";
import assert from "node:assert/strict";
import { consumoDelSaldo, pctDelSaldo, saldoLibre } from "./saldoOperar.js";

test("a 5× una posición consume su nominal; a 3×, más", () => {
  // 500 $ nominales a 5× bloquean 100 $ de margen: 500 $ del saldo.
  assert.equal(consumoDelSaldo(100, 5), 500);
  // 300 $ nominales a 3× bloquean también 100 $: consumen lo mismo.
  assert.equal(consumoDelSaldo(100, 5), consumoDelSaldo(300 / 3, 5));
  // En Fase 2 el saldo es equity × 3, y el consumo, margen × 3.
  assert.equal(consumoDelSaldo(100, 3), 300);
});

test("el ejemplo del dueño: 500 $ en Fase 1, cinco posiciones de 500 $", () => {
  const saldo = 500 * 5;
  assert.equal(pctDelSaldo(consumoDelSaldo(100, 5), saldo), 20);
  assert.equal(saldoLibre({ saldo_operar_max: saldo, saldo_operar_en_uso: 5 * 500 }), 0);
});

test("sin datos no se inventa nada, y lo libre nunca es negativo", () => {
  assert.equal(consumoDelSaldo(null, 5), null);
  assert.equal(consumoDelSaldo(100, 0), null);
  assert.equal(pctDelSaldo(100, 0), null);
  assert.equal(saldoLibre(null), null);
  assert.equal(saldoLibre({ saldo_operar_max: 2000, saldo_operar_en_uso: 2400 }), 0);
});
