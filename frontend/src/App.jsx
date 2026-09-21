import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import Escaner from "./rutas/Escaner.jsx";
import Proximamente from "./rutas/Proximamente.jsx";

/**
 * Router de la aplicación.
 *
 * La Fase 1 no tenía router porque era una sola pantalla. En la Fase 2
 * hay seis módulos, y la mitad no existen todavía: se declaran aquí con
 * su sprint y sus historias en vez de dejarlos fuera del menú, porque un
 * módulo ausente del menú es indistinguible de un módulo que nadie ha
 * planificado.
 *
 * El módulo de autenticación (Sprint 3) añadirá aquí las rutas /login y
 * /pendiente y una guardia que envuelva el resto. Hasta entonces todo es
 * público, que es coherente con lo que la base de datos concede: las
 * tablas del catálogo tienen RLS activada y SIN políticas, así que la
 * `anon key` no lee nada. La puerta está en el servidor, no en el menú.
 */
export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Escaner />} />

        <Route
          path="/cartera"
          element={
            <Proximamente
              titulo="Cartera"
              sprint={4}
              descripcion="Aquí se gestionará tu propia lista de activos: buscar cualquier acción o criptomoneda, añadirla aunque el sistema no la conozca todavía, y ver su histórico completo en menos de tres minutos. También la importación de tu cartera real por CSV, con los importes cifrados como en la Fase 1."
              historias={[
                "H-17 — Carteras por usuario",
                "H-18 — Cuotas de activos (25 por usuario, 150 globales, 20 criptos)",
                "H-19 — Buscador y resolución de activos nuevos",
                "H-20 — Backfill bajo demanda",
                "H-21 — Importación de cartera real por CSV",
              ]}
            />
          }
        />

        <Route
          path="/simulador"
          element={
            <Proximamente
              titulo="Simulador"
              sprint={5}
              descripcion="Saldo inicial ficticio, entradas sugeridas con Take Profit y Stop Loss, confirmación de orden con tu precio y fecha, y un motor que vigila el precio cada minuto, cierra la operación cuando toca un nivel, libera el margen y actualiza el balance. El saldo será derivado de un libro mayor inmutable, nunca un número editable."
              historias={[
                "H-22 — Cuentas de simulación y libro mayor",
                "H-23 — Apertura de órdenes con los cinco guardarraíles",
                "H-24 — Cierre idempotente, máquina de fases y Game Over",
                "H-25 — Motor de monitoreo automatizado",
                "H-26 — Recomendaciones y confirmación de orden",
              ]}
            />
          }
        />

        <Route
          path="/agentes"
          element={
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
          }
        />

        <Route
          path="/admin"
          element={
            <Proximamente
              titulo="Administración"
              sprint={3}
              descripcion="Aprobación manual de usuarios antes de darles acceso: un usuario nuevo queda pendiente y no ve ni un dato hasta que un administrador lo aprueba. La puerta vive en Row Level Security y no en esta pantalla, porque Supabase Auth entrega un token válido a un usuario todavía pendiente."
              historias={[
                "H-13 — Registro, login y pantalla de estado pendiente",
                "H-14 — Row Level Security completa",
                "H-15 — Panel de administración",
                "H-16 — Migración del usuario único de la Fase 1",
              ]}
            />
          }
        />

        {/* Cualquier otra ruta vuelve al escáner: con SPA fallback en
            Vercel, una URL escrita a mano no debe acabar en blanco. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
