import { test } from "node:test";
import assert from "node:assert/strict";
import { ofrecerAccion } from "./buscador.js";

const cripto = { origen: "catalogo", clase: "cripto", simbolo: "spcx" };
const nueva = { origen: "coingecko", clase: "cripto", simbolo: "spcx" };
const accion = { origen: "catalogo", clase: "accion", simbolo: "SPCX" };

test("una cripto con el mismo ticker no oculta la acción", () => {
  assert.equal(ofrecerAccion("SPCX", [cripto]), true);
  assert.equal(ofrecerAccion("spcx", [nueva]), true);
});

test("la acción ya en el catálogo sí la oculta", () => {
  assert.equal(ofrecerAccion("spcx", [cripto, accion]), false);
});

test("lo que no parece un ticker no se ofrece", () => {
  assert.equal(ofrecerAccion("", []), false);
  assert.equal(ofrecerAccion("cardano ada", []), false);
});
