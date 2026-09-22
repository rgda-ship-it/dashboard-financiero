import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { supabase, supabaseConfigurado } from "../supabase.js";

/**
 * Sesión y perfil del usuario.
 *
 * Dos cosas distintas que la interfaz necesita a la vez:
 *   · la SESIÓN de Supabase Auth — «sabemos quién eres»;
 *   · el PERFIL en `public.perfiles` — «¿te han dejado pasar?».
 *
 * Un registro con el correo confirmado tiene sesión pero su perfil está
 * `pendiente`. La interfaz lo manda a /pendiente, pero eso es cortesía:
 * la puerta de verdad es Row Level Security, que a ese token le devuelve
 * cero filas aunque llame a la API a mano (invariantes I17–I21).
 */
const ContextoSesion = createContext(null);

export function ProveedorSesion({ children }) {
  const [sesion, setSesion] = useState(null);
  const [perfil, setPerfil] = useState(null);
  const [cargando, setCargando] = useState(supabaseConfigurado);
  const [recuperando, setRecuperando] = useState(false);

  const cargarPerfil = useCallback(async (usuarioId) => {
    if (!usuarioId) {
      setPerfil(null);
      return null;
    }
    const { data } = await supabase
      .from("perfiles")
      .select("id, email, nombre, rol, estado, motivo_estado, creado_en")
      .eq("id", usuarioId)
      .maybeSingle();
    setPerfil(data ?? null);
    return data ?? null;
  }, []);

  useEffect(() => {
    if (!supabaseConfigurado) return undefined;
    let vivo = true;

    supabase.auth.getSession().then(async ({ data }) => {
      if (!vivo) return;
      setSesion(data.session);
      await cargarPerfil(data.session?.user?.id);
      if (vivo) setCargando(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((evento, nueva) => {
      setSesion(nueva);
      if (evento === "PASSWORD_RECOVERY") setRecuperando(true);
      // Fuera del callback: supabase-js desaconseja esperar dentro de él.
      setTimeout(() => cargarPerfil(nueva?.user?.id), 0);
    });

    return () => {
      vivo = false;
      sub.subscription.unsubscribe();
    };
  }, [cargarPerfil]);

  const cerrarSesion = useCallback(async () => {
    await supabase.auth.signOut();
    setPerfil(null);
  }, []);

  const valor = {
    sesion,
    perfil,
    cargando,
    recuperando,
    terminarRecuperacion: () => setRecuperando(false),
    aprobado: perfil?.estado === "aprobado",
    esAdmin: perfil?.estado === "aprobado" && perfil?.rol === "admin",
    recargarPerfil: () => cargarPerfil(sesion?.user?.id),
    cerrarSesion,
  };

  return <ContextoSesion.Provider value={valor}>{children}</ContextoSesion.Provider>;
}

export function useSesion() {
  const ctx = useContext(ContextoSesion);
  if (!ctx) throw new Error("useSesion fuera de <ProveedorSesion>");
  return ctx;
}

/**
 * Supabase Auth responde en inglés. Los mensajes que un usuario puede
 * provocar se traducen; el resto se muestran tal cual antes que ocultarlos.
 */
const TRADUCCIONES = [
  [/invalid login credentials/i, "Correo o contraseña incorrectos."],
  [/email not confirmed/i, "Todavía no has confirmado tu correo. Revisa tu bandeja de entrada (y la de spam)."],
  [/user already registered/i, "Ya existe una cuenta con ese correo. Inicia sesión o recupera la contraseña."],
  [/password should be at least (\d+)/i, (m) => `La contraseña debe tener al menos ${m[1]} caracteres.`],
  [/rate limit|too many/i, "Demasiados intentos seguidos. Espera unos minutos y vuelve a probar."],
  [/unable to validate email|invalid email/i, "Ese correo no parece válido."],
  [/same.*password|different from the old/i, "La nueva contraseña tiene que ser distinta de la anterior."],
];

export function traducirError(error) {
  const texto = error?.message ?? String(error ?? "");
  for (const [patron, traduccion] of TRADUCCIONES) {
    const m = texto.match(patron);
    if (m) return typeof traduccion === "function" ? traduccion(m) : traduccion;
  }
  return texto;
}
