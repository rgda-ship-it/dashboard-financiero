import { test } from "node:test";
import assert from "node:assert/strict";
import { agrupar, conCabeceras, grupoDe } from "./grupos.js";

const AGENTES = [
  { agente_id: 1, nombre: "Prudencia", tipo: "metas" },
  { agente_id: 4, nombre: "Tendencia cripto", tipo: "estrategia" },
  { agente_id: 5, nombre: "Prudencia v2", tipo: "metas" },
  { agente_id: 3, nombre: "Audacia", tipo: "metas" },
  { agente_id: 8, nombre: "Cartera (vara)", tipo: "cartera" },
];

test("cada agente cae en su grupo por tipo y nombre", () => {
  assert.deepEqual(AGENTES.map(grupoDe), ["control", "estrategia", "v2", "control", "cartera"]);
});

test("el grupo que trae la vista manda sobre el deducido", () => {
  assert.equal(grupoDe({ nombre: "Prudencia", tipo: "metas", grupo: "v2" }), "v2");
});

test("los grupos salen en orden fijo y sin vacíos", () => {
  const grupos = agrupar(AGENTES.slice(0, 4));
  assert.deepEqual(grupos.map((g) => g.id), ["control", "v2", "estrategia"]);
  assert.deepEqual(grupos[0].filas.map((f) => f.nombre), ["Prudencia", "Audacia"]);
});

test("un grupo desconocido no se pierde", () => {
  const grupos = agrupar([{ nombre: "Raro", grupo: "nuevo" }]);
  assert.deepEqual(grupos.map((g) => g.id), ["otros"]);
});

test("solo la primera fila de cada grupo lleva cabecera", () => {
  const filas = conCabeceras(AGENTES);
  assert.deepEqual(
    filas.map((f) => f.fila.nombre),
    ["Prudencia", "Audacia", "Prudencia v2", "Tendencia cripto", "Cartera (vara)"]
  );
  assert.deepEqual(
    filas.map((f) => f.cabecera?.id ?? null),
    ["control", null, "v2", "estrategia", "cartera"]
  );
});
