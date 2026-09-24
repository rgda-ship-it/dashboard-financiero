import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import Escaner from "./rutas/Escaner.jsx";
import Proximamente from "./rutas/Proximamente.jsx";
import Admin from "./rutas/Admin.jsx";
import Cartera from "./rutas/Cartera.jsx";
import Simulador from "./rutas/Simulador.jsx";
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
 * hay seis módulos, y la mitad no existen todavía: se declaran aquí con
 * su sprint y sus historias en vez de dejarlos fuera del menú, porque un
 * módulo ausente del menú es indistinguible de un módulo que nadie ha
 * planificado.
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

        <Route
          path="/agentes"
          element={
            <RequiereAprobado>
            <Proximamente
              titulo="Agentes"
              sprint={6}
              descripcion="Tres agentes operando solos con metas de 2 %, 5 % y 7 % diario sobre saldo compuesto, partiendo de 500 $. Esta pantalla mostrará sus operaciones con el motivo de cada entrada, el marcador hacia el millón, su racha de días cumplidos, el veredicto de cada corte semanal, y las dos tablas que escriben por su cuenta: las funciones que piden y las estrategias que se comparten entre ellos."
              historias={[
                "H-27 — Ciclo de agente determinista",
                "H-28 — Corte semanal y acción correctiva",
                "H-29 — Aprendizaje colaborativo con efecto medido",
                "H-30 — Backlog autónomo de agentes",
                "H-31 — Vista de operaciones de agentes",
              ]}
            />
            </RequiereAprobado>
          }
        />

        {/* Cualquier otra ruta vuelve al escáner: con SPA fallback en
            Vercel, una URL escrita a mano no debe acabar en blanco. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </ProveedorSesion>
    </BrowserRouter>
  );
}
