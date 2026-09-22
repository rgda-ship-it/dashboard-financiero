import { useEffect, useState, useCallback, useRef } from "react";
import { leerSenalesVigentes } from "./datos/senales.js";

/**
 * El backend Express de la Fase 1 sigue sirviendo la cartera y el stream
 * de eventos, pero solo existe en localhost. En la nube no hay ningún
 * proceso Node escuchando, así que estas dos URL son opcionales:
 *
 *   · cartera  -> se migra a Edge Functions y RPC en el Sprint 4 (H-21)
 *   · eventos  -> se migra a Supabase Realtime en el Sprint 6 (H-32)
 *
 * Con `VITE_API_BASE` sin definir, los dos módulos se declaran pendientes
 * de migración en la interfaz en vez de intentar una conexión que va a
 * fallar. Un panel que dice "pendiente del Sprint 4" informa; un panel
 * que reintenta contra localhost cada pocos segundos, no.
 */
const API_BASE = import.meta.env.VITE_API_BASE || null;
const WS_URL = import.meta.env.VITE_WS_URL || null;

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

const CLAVE_EVENTOS = "dashboard-financiero:eventos";
const MAX_EVENTOS = 50;

/**
 * El registro solo vive en el navegador, nunca en el servidor: son avisos
 * de sistema, no datos de cartera, así que no hay nada que cifrar ni que
 * persistir en PostgreSQL por ellos.
 *
 * Cada acceso va protegido porque `localStorage` puede lanzar —ventana
 * privada, almacenamiento bloqueado por el navegador— y quedarse sin
 * historial nunca debe impedir que el panel se monte.
 */
function leerEventosGuardados() {
  try {
    const crudo = window.localStorage.getItem(CLAVE_EVENTOS);
    if (!crudo) return [];
    const guardados = JSON.parse(crudo);
    return Array.isArray(guardados) ? guardados.slice(-MAX_EVENTOS) : [];
  } catch {
    return [];
  }
}

function guardarEventos(eventos) {
  try {
    window.localStorage.setItem(CLAVE_EVENTOS, JSON.stringify(eventos));
  } catch {
    // Sin espacio o sin permiso: el stream en memoria sigue funcionando.
  }
}

export function useEventLog() {
  // Lazy initializer: se lee una sola vez, al montar, y no en cada render.
  const [eventos, setEventos] = useState(leerEventosGuardados);
  const [conectado, setConectado] = useState(false);

  useEffect(() => {
    let socket;
    let temporizador;
    let intentos = 0;
    let montado = true;
    let caidaAnunciada = false;

    // Sin WebSocket configurado no hay nada a lo que conectarse: el
    // servidor de eventos vive en el Express de localhost. Se deja un
    // aviso en el propio stream y se sale, en vez de abrir un bucle de
    // reconexión contra una URL que no existe.
    if (!WS_URL) {
      setEventos((prev) =>
        prev.length
          ? prev
          : [
              {
                tipo: "sys",
                mensaje: `[SYS] ${PENDIENTE_MIGRACION}`,
                timestamp: new Date().toISOString(),
              },
            ]
      );
      return undefined;
    }

    const agregar = (evento) =>
      setEventos((prev) => {
        const siguientes = [...prev, evento].slice(-MAX_EVENTOS);
        guardarEventos(siguientes);
        return siguientes;
      });

    function conectar() {
      socket = new WebSocket(WS_URL);

      socket.onopen = () => {
        intentos = 0;
        caidaAnunciada = false;
        setConectado(true);
      };

      socket.onmessage = (mensaje) => {
        try {
          agregar(JSON.parse(mensaje.data));
        } catch {
          // Un frame corrupto no debe tumbar el panel de eventos.
        }
      };

      socket.onerror = () => socket.close();

      socket.onclose = () => {
        if (!montado) return;
        setConectado(false);
        if (!caidaAnunciada) {
          caidaAnunciada = true;
          agregar({
            tipo: "sys",
            mensaje: "[SYS] Stream interrumpido — reintentando conexión.",
            timestamp: new Date().toISOString(),
          });
        }
        // Backoff exponencial hasta 30 s: reiniciar el backend en la otra
        // terminal no debe convertirse en una tormenta de reconexiones.
        const espera = Math.min(30000, 1000 * 2 ** intentos);
        intentos += 1;
        temporizador = setTimeout(conectar, espera);
      };
    }

    conectar();

    return () => {
      montado = false;
      clearTimeout(temporizador);
      socket?.close();
    };
  }, []);

  const limpiarEventos = useCallback(() => {
    setEventos([]);
    guardarEventos([]);
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
