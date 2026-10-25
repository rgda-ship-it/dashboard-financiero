import { test } from "node:test";
import assert from "node:assert/strict";
import { motivoAgente, spreadDe, veredicto, RANGO_ACCION } from "./veredicto.js";

const base = {
  ticker: "AMZN",
  clase: "accion",
  precio_actual: 100,
  direccion: "alcista",
  fuerza: "media",
  operable: true,
  atr_pct: 2,
  sl: 97,
  tp: 104,
  niveles_origen: "estructura",
};

const PRUDENCIA = {
  nombre: "Prudencia",
  tipo: "metas",
  estado: "activo",
  estrategia: { rr_minimo: 1.5, fuerzas_admitidas: ["media", "alta"], atr_pct_max: 3, niveles_origen_admitidos: ["estructura"],
                por_clase: { cripto: { atr_pct_max: 12 } } },
};
const AUDACIA = {
  nombre: "Audacia",
  tipo: "metas",
  estado: "activo",
  estrategia: { rr_minimo: 1.2, fuerzas_admitidas: ["media", "alta"], atr_pct_min: 2.3 },
};

test("comprar: alcista, fuerza media, R:R con spread suficiente y bolsa abierta", () => {
  const v = veredicto(base, { agentes: [PRUDENCIA, AUDACIA] });
  assert.equal(v.accion, "comprar");
  assert.ok(Math.abs(v.compra - 100.015) < 1e-9);
  assert.ok(v.rr > 1.3 && v.rr < 1.34);
  assert.deepEqual(v.agentes.map((a) => [a.nombre, a.motivo]), [
    ["Prudencia", "pide R:R ≥ 1.5"],
    ["Audacia", "pide ATR ≥ 2.3 %"],
  ]);
});

test("solo largos: una lectura bajista nunca es comprar", () => {
  const v = veredicto({ ...base, direccion: "bajista" });
  assert.equal(v.accion, "no_comprar");
  assert.match(v.motivo, /solo opera en largo/);
});

test("confluencia baja: esperar", () => {
  assert.equal(veredicto({ ...base, fuerza: "baja" }).accion, "esperar");
});

test("el spread puede dejar el R:R por debajo del mínimo", () => {
  // Sin spread: 4 / 3 = 1,33. Con 1 $ de spread medido: 3,5 / 3,5 = 1.
  const v = veredicto(base, { spread: 1 });
  assert.equal(v.accion, "esperar");
  assert.match(v.motivo, /R:R 1\.00/);
});

test("el spread puede comerse el objetivo entero", () => {
  assert.equal(veredicto({ ...base, tp: 100.01 }).accion, "no_comprar");
});

test("bolsa cerrada: las acciones esperan, la cripto no", () => {
  assert.equal(veredicto(base, { bolsaAbierta: false }).accion, "esperar");
  assert.equal(veredicto({ ...base, clase: "cripto", ticker: "solana" }, { bolsaAbierta: false }).accion, "comprar");
});

test("sin datos fiables no se opera", () => {
  assert.equal(veredicto({ ...base, error: "fallo" }).accion, "sin_datos");
  assert.equal(veredicto({ ...base, suspendido: true }).accion, "sin_datos");
  assert.equal(veredicto({ ...base, atr_pct: null }).accion, "no_comprar");
  assert.equal(veredicto({ ...base, atrasada: true }).accion, "esperar");
});

test("los filtros de cada agente, con el ATR por clase", () => {
  const cripto = { ...base, clase: "cripto", ticker: "solana", atr_pct: 5 };
  assert.equal(motivoAgente(PRUDENCIA.estrategia, cripto, 2), null);
  assert.equal(motivoAgente(PRUDENCIA.estrategia, { ...base, atr_pct: 5 }, 2), "pide ATR ≤ 3 %");
  assert.equal(motivoAgente(PRUDENCIA.estrategia, { ...base, niveles_origen: "atr" }, 2), "niveles por ATR, no por estructura");
  assert.equal(motivoAgente({}, base, 2), "pide fuerza alta");
});

test("el spread supuesto por clase", () => {
  assert.equal(spreadDe(base, null), 0.03);
  assert.equal(spreadDe({ ...base, clase: "cripto", ticker: "bitcoin" }, null), 5);
  assert.ok(Math.abs(spreadDe({ ...base, clase: "cripto", ticker: "solana" }, null) - 0.1) < 1e-9);
  assert.equal(spreadDe(base, 0.5), 0.5);
});

test("lo accionable va primero", () => {
  assert.ok(RANGO_ACCION.comprar < RANGO_ACCION.esperar && RANGO_ACCION.esperar < RANGO_ACCION.no_comprar);
});
