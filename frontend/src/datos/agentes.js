import { supabase } from "../supabase.js";

/**
 * Agentes (Sprint 6).
 *
 * Igual que `simulador.js`: aquí no se decide nada. Lo que un agente
 * elige, cuánto arriesga y cuándo cierra lo decide PostgreSQL. Esta capa
 * lee vistas y llama a los tres RPC de administración, que comprueban
 * `es_admin()` dentro de la base de datos.
 */

function mensajeDe(error) {
  if (!error) return null;
  if (["P0001", "22023", "P0002", "42501"].includes(error.code)) return error.message;
  return `Error de la base de datos: ${error.message}`;
}

async function llamar(consulta) {
  const { data, error } = await consulta;
  if (error) throw new Error(mensajeDe(error));
  return data;
}

export const leerRanking = () =>
  llamar(supabase.from("v_ranking_agentes").select("*").order("agente_id"));

export const leerCurvas = () =>
  llamar(
    supabase
      .from("v_curva_agentes")
      .select("agente_id, nombre, cuenta_id, fecha, operable, cumplido, saldo_apertura, saldo_cierre, saldo_teorico")
      .order("fecha")
  );

export const leerOperaciones = (limite = 200) =>
  llamar(
    supabase
      .from("v_operaciones_agentes")
      .select("*")
      .order("id", { ascending: false })
      .limit(limite)
  );

export const leerBacklog = () =>
  llamar(supabase.from("v_backlog_priorizado").select("*"));

export const leerPracticas = () =>
  llamar(supabase.from("v_practicas_ranking").select("*"));

/** Decisiones juzgadas contra su contrafactual, y los ajustes que motivaron
 *  (0016). */
export const leerDecisiones = (limite = 60) =>
  llamar(
    supabase.from("v_decisiones_agentes").select("*").order("id", { ascending: false }).limit(limite)
  );

export const leerAjustes = () =>
  llamar(supabase.from("v_ajustes_agentes").select("*").order("id", { ascending: false }).limit(30));

export const TIPOS_DECISION = {
  rotacion: "rotación",
  parcial: "toma parcial",
  reparto: "reparto",
  deterioro: "salida por deterioro",
};

/** Por qué una salida por deterioro (0024): qué cambió en la señal. */
export const MOTIVOS_DETERIORO = {
  direccion: "dejó de ser alcista",
  no_operable: "dejó de ser operable",
  fuerza: "perdió fuerza",
};

export const leerSemanas = () =>
  llamar(
    supabase
      .from("agente_semanas")
      .select("agente_id, semana_iso, veredicto, dias_operables, dias_cumplidos, ratio_cumplimiento, accion_correctiva")
      .order("fecha_inicio", { ascending: false })
      .limit(30)
  );

// ── Administración ──────────────────────────────────────────────────
export const cambiarEstadoAgente = (agenteId, estado) =>
  llamar(supabase.rpc("rpc_cambiar_estado_agente", { p_agente_id: agenteId, p_estado: estado }));

export const reiniciarAgente = (agenteId) =>
  llamar(supabase.rpc("rpc_reiniciar_agente", { p_agente_id: agenteId, p_confirmacion: true }));

/** Única vuelta a Fase 1 (regla protegida nº5): de admin, con confirmación
 *  y auditada. La cuenta volverá a Fase 2 con el primer criterio que cumpla. */
export const revertirFase = (cuentaId) =>
  llamar(supabase.rpc("rpc_revertir_fase_manual", { p_cuenta_id: cuentaId, p_confirmacion: true }));

export const revisarBacklog = (id, estado, resolucion) =>
  llamar(
    supabase.rpc("rpc_revisar_backlog", { p_id: id, p_estado: estado, p_resolucion: resolucion ?? null })
  );

// ── Vocabulario de la interfaz ──────────────────────────────────────

/** Color de identidad de cada agente. Validado con el comprobador de
 *  paletas sobre la superficie oscura (todos los pares: CVD ΔE ≥ 8,4,
 *  visión normal ≥ 16,2). Ni verde ni rojo: son de mercado. Los valores
 *  viven en `tokens.css`; aquí solo el nombre del token. */
export const COLOR_AGENTE = {
  Prudencia: "var(--agente-1)",
  Cadencia: "var(--agente-2)",
  Audacia: "var(--agente-3)",
};
export const colorDe = (nombre) => COLOR_AGENTE[nombre] ?? "var(--tx-3)";

export const ESTADOS_AGENTE = {
  activo: { texto: "operando", tono: "ok" },
  cuarentena: { texto: "cuarentena", tono: "warn" },
  pausado: { texto: "en pausa", tono: "neutro" },
  game_over: { texto: "game over", tono: "neg" },
};

export const VEREDICTOS = {
  validada: { texto: "validada", tono: "ok" },
  aviso: { texto: "aviso", tono: "warn" },
  deficiente: { texto: "deficiente", tono: "neg" },
  sin_datos: { texto: "sin datos", tono: "neutro" },
};

export const MOTIVOS_DESCARTE = {
  antiguedad: "señal añeja",
  fuera_de_sesion: "bolsa cerrada",
  direccion: "sin dominancia alcista",
  sin_atr: "sin volatilidad",
  no_operable: "no operable",
  fuerza: "fuerza insuficiente",
  niveles_origen: "origen de niveles",
  rr: "R:R bajo",
  atr_bajo: "ATR bajo",
  atr_alto: "ATR alto",
  posicion_abierta: "ya abierta",
  practica: "no cumple una práctica",
  margen_minimo: "margen < 10 $",
};

export const ACCIONES_CICLO = {
  abrir: "abrió posición",
  meta_cumplida: "meta cumplida · conserva",
  sin_hueco: "en cuarentena: ya tiene su posición",
  margen_lleno: "margen al tope",
  // 0023: sin G4, lo que impide abrir más es el saldo para operar.
  saldo_lleno: "saldo para operar lleno",
  sin_candidatos: "sin candidatos",
};

export const TIPOS_BACKLOG = {
  nueva_herramienta: "herramienta",
  nuevo_dato: "dato",
  ajuste_regla: "regla",
  nuevo_activo: "activo",
  reversion_fase: "fase",
  sesgo_corto: "cortos",
};

export const ESTADOS_BACKLOG = {
  nuevo: "nuevo",
  en_revision: "en revisión",
  aceptado: "aceptado",
  rechazado: "rechazado",
  implementado: "implementado",
};
