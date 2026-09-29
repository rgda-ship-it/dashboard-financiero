import { useEffect, useState, useCallback, useRef } from "react";
import { leerSenalesVigentes } from "./datos/senales.js";
import { supabase } from "./supabase.js";

/**
 * El backend Express de la Fase 1 sigue sirviendo el diagnóstico de
 * cartera, pero solo existe en localhost. Con `VITE_API_BASE` sin definir,
 * ese panel se declara pendiente de migración en vez de intentar una
 * conexión que va a fallar. Los eventos ya no pasan por él: llegan por
 * Supabase Realtime desde el Sprint 6 (H-32).
 */
const API_BASE = import.meta.env.VITE_API_BASE || null;

// Con el backend local de la Fase 1 disponible, el escáner conserva su
// panel de diagnóstico de cartera (semáforo de salud y rotación, que
// calcula el motor Python). En la nube, la cartera vive en /cartera.
export const modoLocal = Boolean(API_BASE);

const PENDIENTE_MIGRACION =
  "Módulo pendiente de migración a la nube. En local, arranca el backend " +
  "Node y define VITE_API_BASE en el .env de la raíz.";

export function useEscaner() {
  const [senales, setSenales] = useState([]);
  const [desdeCache, setDesdeCache] = useState(false);
  const [mensaje, setMensaje] = useState(null);
  const [ultimaActualizacion, setUltimaActualizacion] = useState(null);
  const [cargando, setCargando] = useState(true);
  const [refrescando, setRefrescando] = useState(false);
  const [error, setError] = useState(null);

  const cargar = useCallback(async () => {
    setRefrescando(true);
    try {
      const resultado = await leerSenalesVigentes();
      setSenales(resultado.senales);
      // `desdeCache` pasa a significar "el dato es añejo". Se reutiliza el
      // campo a propósito: StatusBar y ScannerTable ya saben pintar ese
      // estado con su propio tratamiento visual, y en la Fase 1 significaba
      // exactamente lo mismo — que lo que se ve no es de ahora mismo.
      setDesdeCache(resultado.anejo);
      setMensaje(resultado.aviso);
      setUltimaActualizacion(resultado.calculadoEn);
      setError(resultado.error);
    } catch (err) {
      setError(err.message);
    } finally {
      setCargando(false);
      setRefrescando(false);
    }
  }, []);

  useEffect(() => {
    cargar();
    // Cadencia de RELECTURA, no de escaneo. Es una diferencia de fondo
    // respecto a la Fase 1: antes cada refresco disparaba llamadas a
    // Yahoo y CoinGecko desde el navegador y había que espaciarlas para
    // no chocar con sus rate limits. Ahora quien habla con los
    // proveedores es el ETL programado, y esto solo relee una tabla.
    const intervalo = setInterval(cargar, 2 * 60 * 1000);
    return () => clearInterval(intervalo);
  }, [cargar]);

  return {
    senales,
    desdeCache,
    mensaje,
    ultimaActualizacion,
    cargando,
    refrescando,
    error,
    refrescar: cargar,
  };
}

const MAX_EVENTOS = 50;

const aEvento = (fila) => ({
  id: fila.id,
  tipo: fila.tipo,
  mensaje: fila.mensaje,
  agenteId: fila.agente_id,
  timestamp: fila.creado_en,
});

/**
 * Registro de eventos del sistema (H-32).
 *
 * Hasta el Sprint 5 vivía en `localStorage` y llegaba por el WebSocket del
 * Express de localhost, que en la nube no existe. Ahora vive en
 * `eventos_sistema` y llega por Supabase Realtime: sobrevive al cierre de
 * sesión y se ve igual en otro dispositivo.
 *
 * Quién recibe qué lo decide la RLS de la tabla, que Realtime respeta: los
 * eventos globales (proveedor, agentes) llegan a todo aprobado; los de un
 * usuario, solo a él. Esta capa no filtra nada.
 *
 * «Limpiar» ya no borra: los eventos globales son de todos. Mueve la marca
 * de lectura del perfil (`rpc_vaciar_eventos`) y la vista `v_mis_eventos`
 * devuelve solo lo posterior, en cualquier dispositivo.
 */
export function useEventLog() {
  const [eventos, setEventos] = useState([]);
  const [conectado, setConectado] = useState(false);

  useEffect(() => {
    if (!supabase) {
      setEventos([
        {
          tipo: "sys",
          mensaje: "[SYS] Falta la configuración de Supabase: no hay registro de eventos.",
          timestamp: new Date().toISOString(),
        },
      ]);
      return undefined;
    }

    let vivo = true;
    // Los que lleguen mientras se lee el histórico no se pierden: se
    // fusionan por id al terminar la lectura.
    const agregar = (nuevos) =>
      setEventos((prev) => {
        const porId = new Map(prev.map((e) => [e.id, e]));
        nuevos.forEach((e) => porId.set(e.id, e));
        return [...porId.values()]
          .sort((a, b) => (a.id ?? 0) - (b.id ?? 0))
          .slice(-MAX_EVENTOS);
      });

    supabase
      .from("v_mis_eventos")
      .select("id, tipo, mensaje, agente_id, creado_en")
      .order("id", { ascending: false })
      .limit(MAX_EVENTOS)
      .then(({ data }) => {
        if (vivo && data) agregar(data.map(aEvento));
      });

    const canal = supabase
      .channel("eventos-sistema")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "eventos_sistema" },
        (cambio) => agregar([aEvento(cambio.new)])
      )
      .subscribe((estado) => {
        if (vivo) setConectado(estado === "SUBSCRIBED");
      });

    return () => {
      vivo = false;
      supabase.removeChannel(canal);
    };
  }, []);

  const limpiarEventos = useCallback(async () => {
    setEventos([]);
    if (supabase) await supabase.rpc("rpc_vaciar_eventos");
  }, []);

  return { eventos, conectado, limpiarEventos };
}

export function useCartera() {
  const [diagnosticos, setDiagnosticos] = useState([]);
  const [resumenCarga, setResumenCarga] = useState(null);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState(null);
  // Se guarda para poder reintentar el diagnóstico sin volver a pedir el
  // archivo, y para mostrar en la UI qué se está analizando.
  const nombreArchivo = useRef(null);

  const analizar = useCallback(async () => {
    if (!API_BASE) throw new Error(PENDIENTE_MIGRACION);
    const resp = await fetch(`${API_BASE}/portfolio/analyze`, {
      credentials: "include",
    });
    if (!resp.ok) throw new Error(`Error ${resp.status} al analizar cartera`);
    const data = await resp.json();
    setDiagnosticos(data.diagnosticos || []);
  }, []);

  const subirArchivo = useCallback(
    async (archivo, guardarPersistente) => {
      setCargando(true);
      setError(null);

      if (!API_BASE) {
        setError(PENDIENTE_MIGRACION);
        setCargando(false);
        return;
      }

      const formData = new FormData();
      formData.append("archivo", archivo);
      formData.append("guardarPersistente", String(guardarPersistente));

      try {
        const respUpload = await fetch(`${API_BASE}/portfolio/upload`, {
          method: "POST",
          credentials: "include", // necesario para que viaje la cookie de sesión
          body: formData,
        });
        if (!respUpload.ok) {
          const detalle = await respUpload.json().catch(() => ({}));
          throw new Error(detalle.error || `Error ${respUpload.status} al cargar el archivo`);
        }

        const resumen = await respUpload.json().catch(() => ({}));
        nombreArchivo.current = archivo.name;
        setResumenCarga({
          nombre: archivo.name,
          posicionesCargadas: resumen.posicionesCargadas ?? null,
          filasExcluidas: resumen.filasExcluidas ?? [],
          persistido: Boolean(resumen.persistido),
        });

        await analizar();
      } catch (err) {
        setError(err.message);
      } finally {
        setCargando(false);
      }
    },
    [analizar]
  );

  /**
   * Restaura la cartera persistida en una sesión anterior. El endpoint ya
   * existía (`GET /api/portfolio/restore`) pero no tenía control visual —
   * era uno de los pendientes conocidos del README.
   */
  const restaurarCartera = useCallback(async () => {
    if (!API_BASE) return setError(PENDIENTE_MIGRACION);
    setCargando(true);
    setError(null);
    try {
      const resp = await fetch(`${API_BASE}/portfolio/restore`, {
        credentials: "include",
      });
      if (!resp.ok) {
        const detalle = await resp.json().catch(() => ({}));
        throw new Error(detalle.error || `Error ${resp.status} al restaurar la cartera`);
      }
      const data = await resp.json();
      setResumenCarga({
        nombre: "cartera guardada",
        posicionesCargadas: data.posicionesRestauradas ?? null,
        filasExcluidas: [],
        persistido: true,
      });
      await analizar();
    } catch (err) {
      setError(err.message);
    } finally {
      setCargando(false);
    }
  }, [analizar]);

  /**
   * Borrado REAL de la cartera: vacía la sesión en memoria y hace un
   * DELETE físico en PostgreSQL, nunca un soft-delete (derecho de
   * supresión, regla protegida nº8). No tiene vuelta atrás, así que la
   * interfaz exige una confirmación explícita antes de llamar aquí.
   */
  const borrarCartera = useCallback(async () => {
    if (!API_BASE) {
      setError(PENDIENTE_MIGRACION);
      return false;
    }
    setCargando(true);
    setError(null);
    try {
      const resp = await fetch(`${API_BASE}/portfolio`, {
        method: "DELETE",
        credentials: "include",
      });
      // 204 No Content es la respuesta esperada: no hay cuerpo que leer.
      if (!resp.ok) {
        const detalle = await resp.json().catch(() => ({}));
        throw new Error(detalle.error || `Error ${resp.status} al borrar la cartera`);
      }
      setDiagnosticos([]);
      setResumenCarga(null);
      nombreArchivo.current = null;
      return true;
    } catch (err) {
      setError(err.message);
      return false;
    } finally {
      setCargando(false);
    }
  }, []);

  return {
    diagnosticos,
    resumenCarga,
    cargando,
    error,
    subirArchivo,
    restaurarCartera,
    borrarCartera,
  };
}
