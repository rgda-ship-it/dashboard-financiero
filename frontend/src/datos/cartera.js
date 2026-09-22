import { supabase } from "../supabase.js";

/**
 * Cartera del usuario en la nube (Sprint 4).
 *
 * Toda escritura pasa por RPC: la base de datos aplica las cuotas (D7),
 * valida los símbolos y decide si hay que pedir un alta. Esta capa solo
 * traduce los errores de PostgreSQL a mensajes legibles; los de cuota ya
 * vienen redactados desde la BD para mostrarse tal cual (H-18).
 */

function mensajeDe(error) {
  if (!error) return null;
  // P0001 = raise exception de nuestras funciones; 22023 = parámetro no
  // válido. En los dos el texto está escrito para el usuario.
  if (["P0001", "22023", "P0002", "42501"].includes(error.code)) return error.message;
  return `Error de la base de datos: ${error.message}`;
}

async function llamar(consulta) {
  const { data, error } = await consulta;
  if (error) throw new Error(mensajeDe(error));
  return data;
}

export const leerMiCartera = () =>
  llamar(supabase.from("v_mi_cartera").select("*").order("simbolo"));

export const leerSolicitudes = () =>
  llamar(
    supabase
      .from("solicitudes_activo")
      .select("id, simbolo, estado, mensaje, creado_en, actualizado_en")
      .neq("estado", "resuelta")
      .gte("creado_en", new Date(Date.now() - 7 * 86400000).toISOString())
      .order("creado_en", { ascending: false })
  );

export const buscarActivo = (consulta) =>
  llamar(supabase.rpc("rpc_buscar_activo", { p_consulta: consulta }));

export const seguirActivo = (activoId) =>
  llamar(supabase.rpc("rpc_seguir_activo", { p_activo_id: activoId }));

export const dejarActivo = (activoId) =>
  llamar(supabase.rpc("rpc_dejar_activo", { p_activo_id: activoId }));

export const solicitarActivo = (clase, identificador) =>
  llamar(supabase.rpc("rpc_solicitar_activo", { p_clase: clase, p_identificador: identificador }));

export const leerPosiciones = () =>
  llamar(supabase.from("v_mis_posiciones").select("*").order("ticker"));

export const importarPosiciones = (filas) =>
  llamar(supabase.rpc("rpc_importar_posiciones", { p_filas: filas }));

export const borrarPosiciones = () => llamar(supabase.rpc("rpc_borrar_posiciones"));

/** ¿Parece un símbolo bursátil? Mismo patrón que valida la BD. */
export const pareceAccion = (texto) => /^[A-Z0-9^][A-Z0-9.=^-]{0,14}$/.test(texto.trim().toUpperCase());
