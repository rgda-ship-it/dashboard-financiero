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

/** Salud del sistema (0045, solo admin): disparos del ETL, señales y ciclos. */
export const leerSalud = () => llamar(supabase.rpc("rpc_salud_sistema"));

export const leerRanking = () =>
  llamar(supabase.from("v_ranking_agentes").select("*").order("agente_id"));

/** Agentes de estrategia (0037): expectativa en R y criterio de retirada. */
export const leerEstrategias = () =>
  llamar(supabase.from("v_agentes_estrategia").select("*").order("agente_id"));

/** Las mismas medidas para todos los agentes (0040): el experimento. */
export const leerComparativa = () =>
  llamar(supabase.from("v_comparativa_agentes").select("*").order("agente_id"));

export const leerCurvas = () =>
  llamar(
    supabase
      .from("v_curva_agentes")
      .select("agente_id, nombre, cuenta_id, fecha, operable, cumplido, saldo_apertura, saldo_cierre, saldo_teorico")
      .order("fecha")
  );

/** Cuántas operaciones trae la pantalla de Agentes: las más recientes. */
export const LIMITE_OPERACIONES = 200;

export const leerOperaciones = (limite = LIMITE_OPERACIONES) =>
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
  "Tendencia cripto": "var(--agente-4)",
};
export const colorDe = (nombre) => COLOR_AGENTE[nombre] ?? "var(--tx-3)";

export const ESTADOS_AGENTE = {
  activo: { texto: "operando", tono: "ok" },
  cuarentena: { texto: "cuarentena", tono: "warn" },
  pausado: { texto: "en pausa", tono: "neutro" },
  game_over: { texto: "game over", tono: "neg" },
};

/** Criterio del doc 07 §6 para un agente de estrategia (v_agentes_estrategia). */
export const CRITERIOS_ESTRATEGIA = {
  arranque: { texto: "arranque", tono: "neutro", nota: "menos de 5 operaciones: se revisa que opere como en el laboratorio" },
  en_prueba: { texto: "en prueba", tono: "neutro", nota: "se juzga a las 30 operaciones cerradas" },
  observacion: { texto: "en observación", tono: "warn", nota: "entre 0 y +0,10 R: sigue hasta 60 operaciones" },
  validado: { texto: "validado en vivo", tono: "ok", nota: "más de +0,10 R por operación" },
  retirar: { texto: "retirada", tono: "neg", nota: "expectativa por debajo del criterio: queda en pausa" },
  caida: { texto: "pausa por caída", tono: "neg", nota: "más de un 35 % por debajo de su máximo" },
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
  tras_stop: "stop reciente (espera)",
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
