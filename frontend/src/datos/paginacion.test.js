import { test } from "node:test";
import assert from "node:assert/strict";
import { paginar } from "./paginacion.js";

const filas = Array.from({ length: 45 }, (_, i) => i + 1);

test("parte en páginas y dice qué tramo se ve", () => {
  const p = paginar(filas, 2, 20);
  assert.deepEqual(p.filas, filas.slice(20, 40));
  assert.equal(p.paginas, 3);
  assert.equal(p.desde, 21);
  assert.equal(p.hasta, 40);
  assert.deepEqual(paginar(filas, 3, 20).filas, [41, 42, 43, 44, 45]);
});

test("una página que ya no existe se acota a la última", () => {
  const p = paginar(filas.slice(0, 5), 3, 20);
  assert.equal(p.pagina, 1);
  assert.deepEqual(p.filas, [1, 2, 3, 4, 5]);
});

test("sin filas hay una página vacía", () => {
  const p = paginar([], 1, 20);
  assert.deepEqual([p.pagina, p.paginas, p.desde, p.hasta, p.filas.length], [1, 1, 0, 0, 0]);
});
