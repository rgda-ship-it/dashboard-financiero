import { createClient } from "@supabase/supabase-js";

/**
 * Cliente único de Supabase para todo el frontend.
 *
 * SOLO se usa la `anon key`, que es PÚBLICA POR DISEÑO: viaja en el
 * bundle y cualquiera puede leerla. Lo que decide qué datos devuelve no
 * es la clave, es Row Level Security en el servidor.
 *
 * La `service_role key` NUNCA entra aquí. Elude RLS por diseño, así que
 * publicarla en un bundle de JavaScript expondría la base de datos
 * entera con permiso de escritura. El workflow `frontend.yml` hace grep
 * de `dist/` buscándola y falla el build si aparece — es un error de una
 * línea (copiar la variable equivocada en Vercel) y la única defensa
 * fiable es automática.
 */

const url = import.meta.env.VITE_SUPABASE_URL;
const claveAnonima = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const supabaseConfigurado = Boolean(url && claveAnonima);

// Si falta la configuración no se lanza en el arranque: la interfaz tiene
// que poder montarse para explicar QUÉ falta. Una pantalla en blanco no
// dice nada; un panel que dice "falta VITE_SUPABASE_URL" se arregla en un
// minuto.
export const supabase = supabaseConfigurado
  ? createClient(url, claveAnonima, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null;
