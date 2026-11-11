// A qué corresponde cada agente (doc fase-4/00 §6). La ventana de agentes
// los separa por grupo: quien mira tiene que saber qué es experimento, qué
// es su control y qué es la vara.
//
// Si la vista trae `grupo` (migración posterior), manda ese; mientras, se
// deduce del tipo y del nombre: las v2 se llaman como su original más «v2».

export const GRUPOS = [
  {
    id: "control",
    titulo: "Grupo de control",
    nota: "Persiguen una meta diaria. Sus reglas no se tocan hasta el final del experimento.",
  },
  {
    id: "v2",
    titulo: "Versiones 2",
    nota: "Su original más un filtro que salió del laboratorio. Se juzgan con un criterio fijado de antemano.",
  },
  {
    id: "estrategia",
    titulo: "Estrategias del laboratorio",
    nota: "Una regla que pasó el laboratorio, sin meta diaria.",
  },
  {
    id: "cartera",
    titulo: "Carteras",
    nota: "Compran clases de activo enteras y deciden una vez al mes. La vara es comprar y no hacer nada.",
  },
];

const OTROS = { id: "otros", titulo: "Otros", nota: "" };

export function grupoDe(a) {
  if (a?.grupo) return a.grupo;
  if (a?.tipo === "cartera") return "cartera";
  if (a?.tipo === "estrategia") return "estrategia";
  return /\sv\d+$/i.test(a?.nombre ?? "") ? "v2" : "control";
}

/** [{ id, titulo, nota, filas }] en el orden de GRUPOS, sin grupos vacíos. */
export function agrupar(filas = []) {
  const conocidos = new Set(GRUPOS.map((g) => g.id));
  return [...GRUPOS, OTROS]
    .map((g) => ({
      ...g,
      filas: filas.filter((f) => {
        const id = grupoDe(f);
        return g.id === "otros" ? !conocidos.has(id) : id === g.id;
      }),
    }))
    .filter((g) => g.filas.length > 0);
}

/** Las filas en orden de grupo; la primera de cada uno lleva `cabecera`. */
export function conCabeceras(filas = []) {
  return agrupar(filas).flatMap((g) =>
    g.filas.map((fila, i) => ({ fila, cabecera: i === 0 ? { id: g.id, titulo: g.titulo, nota: g.nota } : null }))
  );
}
