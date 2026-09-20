import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],

  // El .env sigue siendo UNO y sigue viviendo en la raíz del proyecto.
  //
  // Vite busca por defecto el .env en su propia raíz (frontend/), lo que
  // habría obligado a un segundo fichero de entorno — exactamente el
  // problema del `backend/.env` duplicado al que el README de la Fase 1
  // dedica una sección entera de diagnóstico. Con `envDir` apuntando
  // arriba, la regla "un único .env en la raíz" sobrevive al desarrollo
  // local de la Fase 2.
  //
  // En producción no hay .env: Vercel inyecta las variables VITE_* en su
  // propio build.
  envDir: "..",
});
