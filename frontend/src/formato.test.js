import { test } from "node:test";
import assert from "node:assert/strict";
import { decimalesDePrecio, formatearPrecio } from "./formato.js";

test("por encima de 1 $ los precios van con 2 decimales", () => {
  assert.equal(formatearPrecio(184.5), "$184.50");
  assert.equal(formatearPrecio(108412.37), "$108,412");
});

test("por debajo de 1 $ se ven los decimales que mueven el precio", () => {
  assert.equal(formatearPrecio(0.334912), "$0.3349");
  assert.equal(formatearPrecio(0.10234), "$0.1023");
  assert.equal(formatearPrecio(0.0000123456), "$0.00001235");
  assert.equal(decimalesDePrecio(0.5), 4);
  assert.equal(decimalesDePrecio(0.0000001), 8);
});
