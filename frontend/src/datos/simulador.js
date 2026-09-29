import { supabase } from "../supabase.js";

/**
 * Simulador en la nube (Sprint 5).
 *
 * Igual que `cartera.js`: ni un cálculo de negocio vive aquí. El tamaño de
 * la posición, el apalancamiento, el precio de liquidación y el P&L los
 * decide PostgreSQL, porque el servidor no puede fiarse de un número que
 * venga del navegador — sería regalarle los guardarraíles G2 y G3 a
 * cualquiera con la consola abierta.
 *
 * Lo único que esta capa aporta es traducir los errores de PostgreSQL a
 * frases legibles. Los mensajes de los guardarraíles ya vienen redactados
 * desde la base de datos para mostrarse tal cual.
 */

function mensajeDe(error) {
  if (!error) return null;
  // P0001 = raise exception de nuestras funciones; 22023 = parámetro no
  // válido; 42501 = permiso. En los tres el texto está escrito para el
  // usuario.
  if (["P0001", "22023", "P0002", "42501"].includes(error.code)) return error.message;
  // 23505 = índice único: la única carrera que el usuario puede provocar
  // desde la interfaz es abrir dos veces el mismo activo a la vez.
  if (error.code === "23505") return "Ya tienes una posición abierta en ese activo.";
  return `Error de la base de datos: ${error.message}`;
}

async function llamar(consulta) {
  const { data, error } = await consulta;
  if (error) throw new Error(mensajeDe(error));
  return data;
}

/** La cuenta del usuario, con el equity calculado al precio de ahora.
 *  `null` si todavía no ha declarado saldo.
 *
 *  El filtro por usuario NO es redundante con la RLS: desde el Sprint 6
 *  todo aprobado lee también las cuentas de los agentes (requisito 10), y
 *  un administrador lee todas. Sin él, «la última cuenta visible» sería la
 *  de Audacia para quien aún no ha abierto la suya. */
export async function leerCuenta() {
  const { data } = await supabase.auth.getSession();
  const uid = data.session?.user?.id;
  if (!uid) return null;
  const filas = await llamar(
    supabase
      .from("v_cuentas_equity")
      .select("*")
      .eq("usuario_id", uid)
      .order("id", { ascending: false })
      .limit(1)
  );
  return filas?.[0] ?? null;
}

export const crearCuenta = (saldoInicial) =>
  llamar(supabase.rpc("rpc_crear_cuenta_simulacion", { p_saldo_inicial: saldoInicial }));

/** Entradas sugeridas: señales operables y frescas de su cartera, con el
 *  tamaño que el dimensionado propone para SU cuenta. */
export const leerRecomendaciones = () =>
  llamar(
    supabase
      .from("v_recomendaciones_usuario")
      .select("*")
      .order("ratio_rr", { ascending: false })
  );

export const leerOrdenes = () =>
  llamar(supabase.from("v_mis_ordenes").select("*").order("id", { ascending: false }));

/**
 * Confirmar una orden. El usuario ajusta PRECIO y FECHA (requisito 6) y
 * nada más: los niveles son del motor, y el tamaño lo calcula el servidor.
 */
export const abrirOrden = ({ cuentaId, senalId, precioEntrada, fechaEntrada }) =>
  llamar(
    supabase.rpc("rpc_abrir_orden", {
      p_cuenta_id: cuentaId,
      p_senal_id: senalId,
      p_precio_entrada: precioEntrada ?? null,
      p_fecha_entrada: fechaEntrada ?? null,
      p_apalancamiento: null,
      p_riesgo_pct: null,
      p_origen: "recomendacion",
    })
  );

/** Cierre a mano. El precio lo pone el servidor: es el último del mercado,
 *  y si está añejo se niega a cerrar (la misma regla M4 del monitor). */
export const cerrarOrden = (ordenId) =>
  llamar(supabase.rpc("rpc_cerrar_manual", { p_orden_id: ordenId }));

/** El libro mayor. Se muestra porque el saldo de esta pantalla no es un
 *  número guardado: es la suma de estas líneas. */
export const leerMovimientos = (cuentaId, limite = 40) =>
  llamar(
    supabase
      .from("movimientos_saldo")
      .select("id, orden_id, tipo, importe, saldo_disponible_resultante, saldo_bloqueado_resultante, creado_en")
      // Por cuenta: un administrador lee el libro mayor de todas.
      .eq("cuenta_id", cuentaId)
      .order("id", { ascending: false })
      .limit(limite)
  );

export const TIPOS_MOVIMIENTO = {
  deposito_inicial: "Saldo inicial",
  bloqueo_margen: "Margen bloqueado",
  liberacion_margen: "Margen liberado",
  resultado_operacion: "Resultado",
  ajuste_manual: "Ajuste",
};

export const MOTIVOS_CIERRE = {
  tp: "objetivo",
  sl: "stop",
  liquidacion: "liquidación",
  manual: "a mano",
  caducidad: "caducidad",
};

export const FASES = {
  fase_1_aceleracion: "Fase 1 · aceleración",
  fase_2_consolidacion: "Fase 2 · consolidación",
};

export const ESTADOS_CUENTA = {
  activa: { texto: "activa", tono: "ok" },
  pausada: { texto: "pausada", tono: "warn" },
  inoperante: { texto: "inoperante", tono: "warn" },
  game_over: { texto: "game over", tono: "neg" },
};

/** Límites de `rpc_crear_cuenta_simulacion`. Aquí solo para poder avisar
 *  antes de la llamada; quien los impone es la base de datos. */
export const SALDO_MIN = 100;
export const SALDO_MAX = 10000;
