import { supabase, supabaseConfigurado } from "../supabase.js";
import { senalAtrasada } from "./frescura.js";

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
    // Estado del activo en el catálogo. Un activo `suspendido` (tres
    // fallos seguidos del proveedor) SIGUE en el escáner con su última
    // lectura y un aviso: hacerlo desaparecer escondía el fallo.
    estado_activo: fila.estado_activo,
  };
}

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
    .in("estado_activo", ["activo", "suspendido"])
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

  const ahora = new Date();
  const senales = (data ?? []).map((fila) => {
    const s = aFilaDeEscaner(fila);
    s.suspendido = s.estado_activo === "suspendido";
    // Un suspendido no «se atrasa»: se sabe por qué no se actualiza, y
    // la fila ya lo dice. Contarlo aquí volvería a teñir todo el escáner.
    s.atrasada = !s.suspendido && senalAtrasada(s, ahora);
    return s;
  });

  // La marca global es la señal más vieja de los activos que DEBERÍAN
  // estar al día (no suspendidos). Con la más reciente, un solo activo
  // actualizado haría parecer fresco un escáner entero congelado.
  const enServicio = senales.filter((s) => !s.suspendido);
  const marcas = enServicio
    .map((s) => (s.calculado_en ? Date.parse(s.calculado_en) : null))
    .filter((t) => Number.isFinite(t));
  const masAntigua = marcas.length ? Math.min(...marcas) : null;

  const atrasadas = enServicio.filter((s) => s.atrasada).length;
  const suspendidos = senales.length - enServicio.length;
  const anejo = atrasadas > 0;

  // Con la autenticación del Sprint 3, a esta pantalla solo llega un
  // usuario aprobado, así que un conjunto vacío ya no puede ser «la RLS
  // no te deja leer»: es que el ETL aún no ha escrito.
  const partes = [];
  if (atrasadas) partes.push(`${atrasadas} ${atrasadas === 1 ? "activo" : "activos"} con dato atrasado`);
  if (suspendidos) partes.push(`${suspendidos} ${suspendidos === 1 ? "suspendido" : "suspendidos"} por fallos del proveedor`);
  const aviso = senales.length
    ? partes.length
      ? partes.join(" · ")
      : null
    : "Sin señales todavía: el ETL no ha hecho su primera pasada.";

  return {
    senales,
    calculadoEn: masAntigua ? new Date(masAntigua).toISOString() : null,
    anejo,
    aviso,
    error: null,
  };
}
