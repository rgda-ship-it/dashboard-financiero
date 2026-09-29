import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import Escaner from "./rutas/Escaner.jsx";
import Admin from "./rutas/Admin.jsx";
import Cartera from "./rutas/Cartera.jsx";
import Simulador from "./rutas/Simulador.jsx";
import Agentes from "./rutas/Agentes.jsx";
import Login from "./rutas/acceso/Login.jsx";
import Registro from "./rutas/acceso/Registro.jsx";
import Recuperar from "./rutas/acceso/Recuperar.jsx";
import NuevaContrasena from "./rutas/acceso/NuevaContrasena.jsx";
import Pendiente from "./rutas/acceso/Pendiente.jsx";
import { ProveedorSesion } from "./auth/sesion.jsx";
import { RequiereAdmin, RequiereAprobado, SoloSinSesion } from "./auth/Guardias.jsx";

/**
 * Router de la aplicación.
 *
 * La Fase 1 no tenía router porque era una sola pantalla. En la Fase 2
 * hay seis módulos. Mientras se construían, los pendientes se declaraban
 * aquí con su sprint (`Proximamente`) en vez de dejarlos fuera del menú;
 * desde el Sprint 6 están todos.
 *
 * Desde el Sprint 3 todo módulo exige sesión con perfil APROBADO. Las
 * guardias solo eligen pantalla: la puerta real es la RLS de la base de
 * datos, que a un token pendiente le devuelve cero filas.
 */
export default function App() {
  return (
    <BrowserRouter>
      <ProveedorSesion>
      <Routes>
        {/* Acceso: públicas. */}
        <Route path="/login" element={<SoloSinSesion><Login /></SoloSinSesion>} />
        <Route path="/registro" element={<SoloSinSesion><Registro /></SoloSinSesion>} />
        <Route path="/recuperar" element={<Recuperar />} />
        <Route path="/nueva-contrasena" element={<NuevaContrasena />} />
        <Route path="/pendiente" element={<Pendiente />} />

        {/* Módulos: exigen perfil aprobado. */}
        <Route path="/" element={<RequiereAprobado><Escaner /></RequiereAprobado>} />
        <Route path="/admin" element={<RequiereAdmin><Admin /></RequiereAdmin>} />

        <Route path="/cartera" element={<RequiereAprobado><Cartera /></RequiereAprobado>} />

        <Route path="/simulador" element={<RequiereAprobado><Simulador /></RequiereAprobado>} />

        <Route path="/agentes" element={<RequiereAprobado><Agentes /></RequiereAprobado>} />

        {/* Cualquier otra ruta vuelve al escáner: con SPA fallback en
            Vercel, una URL escrita a mano no debe acabar en blanco. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </ProveedorSesion>
    </BrowserRouter>
  );
}
