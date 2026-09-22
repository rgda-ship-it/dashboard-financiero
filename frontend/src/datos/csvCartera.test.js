import { test } from "node:test";
import assert from "node:assert/strict";
import { leerCartera, parsearCSV, normalizarNumero, ErrorArchivo } from "./csvCartera.js";

const bytes = (texto) => new TextEncoder().encode(texto);

test("CSV válido con BOM, comillas y millares", () => {
  const { filas, excluidas } = leerCartera(
    bytes('﻿Ticker,Precio de Compra,Monto\r\nNVDA,156.20,"5,000"\r\nbitcoin,95300.00,2500\r\n')
  );
  assert.deepEqual(excluidas, []);
  assert.deepEqual(filas, [
    { fila: 1, ticker: "NVDA", precio_compra: "156.20", monto: "5000" },
    { fila: 2, ticker: "bitcoin", precio_compra: "95300.00", monto: "2500" },
  ]);
});

test("coma decimal y celdas vacías se excluyen con motivo, sin romper la carga", () => {
  const { filas, excluidas } = leerCartera(
    bytes("Ticker,Precio de Compra,Monto\nAAPL,184,72,10\nMSFT,,10\nIBM,200.5,10\n")
  );
  assert.equal(filas.length, 1);
  assert.deepEqual(excluidas.map((e) => e.fila), [1, 2]);
});

test("un .exe renombrado a .csv se rechaza por contenido", () => {
  const exe = new Uint8Array([0x4d, 0x5a, 0x90, 0x00, 0x03, 0x00]);
  assert.throws(() => leerCartera(exe), ErrorArchivo);
});

test("un Excel (ZIP) o un fichero con bytes nulos se rechazan", () => {
  assert.throws(() => leerCartera(new Uint8Array([0x50, 0x4b, 0x03, 0x04, 1, 2])), ErrorArchivo);
  assert.throws(() => leerCartera(bytes("Ticker,Precio de Compra,Monto\n\u0000")), ErrorArchivo);
});

test("faltan columnas → error explicativo", () => {
  assert.throws(() => leerCartera(bytes("Simbolo,Precio\nNVDA,1\n")), /faltan las columnas/);
});

test("la fórmula viaja como texto y la decide el servidor; las comillas escapadas se respetan", () => {
  const { filas } = leerCartera(bytes('Ticker,Precio de Compra,Monto\n"=1+1",10,1\n'));
  assert.equal(filas[0].ticker, "=1+1");
  assert.deepEqual(parsearCSV('a,"b ""c"""\n'), [["a", 'b "c"']]);
});

test("normalizarNumero sigue la regla de la Fase 1", () => {
  assert.equal(normalizarNumero("1,200.50"), "1200.50");
  assert.equal(normalizarNumero("$184.72"), "184.72");
  assert.equal(normalizarNumero("184,72"), null);
  assert.equal(normalizarNumero("1e3"), null);
  assert.equal(normalizarNumero(".5"), null);
});
