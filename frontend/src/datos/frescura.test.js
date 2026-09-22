// Pruebas con el runner nativo de Node (`npm test`): sin dependencias.
// Este archivo no lo importa ningún componente, así que Vite no lo empaqueta.
import { test } from "node:test";
import assert from "node:assert/strict";
import { minutosDesdeAperturaNY, senalAtrasada } from "./frescura.js";

// Septiembre: Nueva York en horario de verano (UTC-4).
const MARTES_11_NY = new Date("2026-09-22T15:00:00Z"); // 11:00 NY
const MARTES_0940_NY = new Date("2026-09-22T13:40:00Z"); // 9:40 NY
const SABADO_NY = new Date("2026-09-26T16:00:00Z");
const MARTES_NOCHE_NY = new Date("2026-09-23T01:00:00Z"); // 21:00 NY
const haceMin = (ahora, m) => new Date(ahora.getTime() - m * 60000).toISOString();

test("mercado NY: abierto entre semana, cerrado sábado y de noche", () => {
  assert.equal(minutosDesdeAperturaNY(MARTES_11_NY), 90);
  assert.equal(minutosDesdeAperturaNY(SABADO_NY), null);
  assert.equal(minutosDesdeAperturaNY(MARTES_NOCHE_NY), null);
});

test("cripto: atrasada a partir de 90 min, a cualquier hora", () => {
  assert.equal(senalAtrasada({ clase: "cripto", calculado_en: haceMin(SABADO_NY, 80) }, SABADO_NY), false);
  assert.equal(senalAtrasada({ clase: "cripto", calculado_en: haceMin(SABADO_NY, 120) }, SABADO_NY), true);
});

test("acción del viernes NO está atrasada en fin de semana ni de noche", () => {
  const viernes = "2026-09-25T20:00:00Z";
  assert.equal(senalAtrasada({ clase: "accion", calculado_en: viernes }, SABADO_NY), false);
  assert.equal(senalAtrasada({ clase: "accion", calculado_en: haceMin(MARTES_NOCHE_NY, 600) }, MARTES_NOCHE_NY), false);
});

test("acción: gracia tras la apertura, atrasada con mercado abierto y > 60 min", () => {
  assert.equal(senalAtrasada({ clase: "accion", calculado_en: haceMin(MARTES_0940_NY, 1000) }, MARTES_0940_NY), false);
  assert.equal(senalAtrasada({ clase: "accion", calculado_en: haceMin(MARTES_11_NY, 70) }, MARTES_11_NY), true);
  assert.equal(senalAtrasada({ clase: "accion", calculado_en: haceMin(MARTES_11_NY, 20) }, MARTES_11_NY), false);
});

test("sin fecha no se declara atrasada", () => {
  assert.equal(senalAtrasada({ clase: "cripto", calculado_en: null }, SABADO_NY), false);
});
