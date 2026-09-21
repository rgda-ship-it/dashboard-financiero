import { supabase, supabaseConfigurado } from "../supabase.js";

/**
 * Lectura de señales desde PostgreSQL.
 *
 * Este módulo es la frontera entre la interfaz y la base de datos, y
 * existe para que los componentes NO cambien: `ScannerTable.jsx`,
 * `MetricsStrip.jsx` y `formato.js` siguen recibiendo exactamente la
 * misma forma de objeto que devolvía `GET /api/scanner/signals`.
 *
 * El cambio de fondo de la Fase 2 es de dirección: el motor ya no
 * responde a la pregunta del navegador, sino que escribe en `senales` y
 * el navegador lee una vista. Ninguna petición del navegador toca
 * yahoo.com ni coingecko.com — que es el requisito 2, verificable en la
 * pestaña de red.
 */

// Correspondencia de nombres. Solo dos columnas cambian de nombre
// respecto al payload de /internal/scan: el resto es idéntico, porque la
// tabla `senales` se diseñó como ese payload persistido.
function aFilaDeEscaner(fila) {
  return {
    ticker: fila.simbolo,
    nombre: fila.nombre,
    clase: fila.clase,
    precio_actual: fila.precio_actual,
    resumen_confluencia: fila.resumen_confluencia,
    fuerza: fila.fuerza,
    indicadores_alcistas: fila.indicadores_alcistas,
    indicadores_bajistas: fila.indicadores_bajistas,
    direccion: fila.direccion,
    sesgo_operativo: fila.sesgo_operativo,
    operable: fila.operable,
    senales: fila.senales_detalle ?? [],
    atr_pct: fila.atr_pct,
    leverage_motivo: fila.leverage_motivo,
    leverage_tope: fila.leverage_tope,
    leverage_recomendado: fila.leverage_recomendado,
    leverage_referencia_volatilidad: fila.leverage_referencia_volatilidad,
    sl: fila.sl,
    tp: fila.tp,
    soporte: fila.soporte,
    resistencia: fila.resistencia,
    niveles_origen: fila.niveles_origen,
    // Campos nuevos de la Fase 2, disponibles para el simulador del
    // Sprint 5 sin tener que volver a tocar esta capa.
    ratio_rr: fila.ratio_rr,
    calculado_en: fila.calculado_en,
    version_motor: fila.version_motor,
  };
}

// A partir de esta antigüedad, el dato se presenta como añejo. Coherente
// con la cadencia del ETL: acciones cada 30 min, cripto cada hora.
const MINUTOS_PARA_ANEJO = 90;

export async function leerSenalesVigentes() {
  if (!supabaseConfigurado) {
    return {
      senales: [],
      calculadoEn: null,
      anejo: false,
      aviso:
        "Falta la configuración de Supabase (VITE_SUPABASE_URL y " +
        "VITE_SUPABASE_ANON_KEY). En local van en el .env de la raíz.",
      error: null,
    };
  }

  const { data, error } = await supabase
    .from("senales_vigentes")
    .select("*")
    .eq("estado_activo", "activo")
    .order("simbolo", { ascending: true });

  if (error) {
    return {
      senales: [],
      calculadoEn: null,
      anejo: false,
      aviso: null,
      error: error.message,
    };
  }

  const senales = (data ?? []).map(aFilaDeEscaner);

  // Antigüedad del dato: la de la señal MÁS VIEJA del conjunto, no la de
  // la más reciente. Con la más reciente, un solo activo actualizado
  // haría parecer fresco un escáner entero congelado.
  const marcas = senales
    .map((s) => (s.calculado_en ? Date.parse(s.calculado_en) : null))
    .filter((t) => Number.isFinite(t));

  const masAntigua = marcas.length ? Math.min(...marcas) : null;
  const anejo =
    masAntigua !== null && Date.now() - masAntigua > MINUTOS_PARA_ANEJO * 60 * 1000;

  // Un conjunto vacío tiene DOS causas posibles y el usuario merece
  // saber cuál: que el ETL no haya corrido todavía, o que las políticas
  // de acceso aún no le concedan lectura (llegan en el Sprint 3, H-14).
  // Desde el cliente no se pueden distinguir —RLS sin política devuelve
  // un 200 con cero filas, no un error—, así que se nombran las dos.
  const aviso = senales.length
    ? null
    : "Sin señales todavía. O el ETL no ha hecho su primera pasada, o tu " +
      "usuario aún no tiene concedida la lectura del catálogo (las " +
      "políticas de acceso llegan con el módulo de autenticación).";

  return {
    senales,
    calculadoEn: masAntigua ? new Date(masAntigua).toISOString() : null,
    anejo,
    aviso,
    error: null,
  };
}
