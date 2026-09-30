import { Suspense, lazy } from "react";
import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import Escaner from "./rutas/Escaner.jsx";

// El escáner es la portada y va en el paquete principal; el resto de
// módulos se descargan al entrar en ellos. Antes todo iba en un solo
// fichero de más de 500 kB, y quien solo mira el escáner pagaba el
// simulador, los agentes y la administración.
const Admin = lazy(() => import("./rutas/Admin.jsx"));
const Cartera = lazy(() => import("./rutas/Cartera.jsx"));
const Simulador = lazy(() => import("./rutas/Simulador.jsx"));
const Agentes = lazy(() => import("./rutas/Agentes.jsx"));
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
      <Suspense fallback={<p className="cargando-modulo">Cargando…</p>}>
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
      </Suspense>
      </ProveedorSesion>
    </BrowserRouter>
  );
}
