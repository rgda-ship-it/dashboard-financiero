import { useEffect, useRef } from "react";
import Panel from "./ui/Panel.jsx";
import Chip from "./ui/Chip.jsx";
import { IconoLimpiar } from "./ui/Iconos.jsx";
import { horaCorta } from "../formato.js";

/**
 * Stream de eventos del sistema.
 *
 * Se lee como una traza continua, no como una lista de mensajes sueltos:
 * un raíl vertical une los eventos y el color del punto codifica el tipo
 * (sistema, deterioro, cambio de fase, proveedor). El auto-scroll solo se
 * aplica si el usuario ya estaba mirando el final — si subió a leer algo,
 * no se le arrastra la vista.
 */
export default function EventLog({ eventos, conectado, alLimpiar, alPedirAyuda }) {
  const listaRef = useRef(null);
  const pegadoAlFinal = useRef(true);

  useEffect(() => {
    const nodo = listaRef.current;
    if (nodo && pegadoAlFinal.current) {
      nodo.scrollTop = nodo.scrollHeight;
    }
  }, [eventos]);

  function alDesplazar(e) {
    const { scrollTop, scrollHeight, clientHeight } = e.currentTarget;
    pegadoAlFinal.current = scrollHeight - scrollTop - clientHeight < 24;
  }

  return (
    <Panel
      titulo="Registro del sistema"
      alPedirAyuda={alPedirAyuda}
      flush
      acciones={
        <Chip
          valor={conectado ? "en vivo" : "sin conexión"}
          tono={conectado ? "neutro" : "warn"}
          vivo={conectado}
        />
      }
      pie={
        <>
          <span>Últimos {Math.min(eventos.length, 50)} eventos · guardados en este navegador</span>
          {eventos.length > 0 && (
            <button
              type="button"
              className="enlace"
              style={{ marginLeft: "auto" }}
              onClick={alLimpiar}
              title="Vaciar el historial guardado en este navegador"
            >
              <IconoLimpiar />
              Limpiar
            </button>
          )}
        </>
      }
    >
      {eventos.length === 0 ? (
        <div className="empty">
          <strong>Sin eventos todavía</strong>
          <span>
            Aquí aparecen los cambios de fase, el deterioro detectado en cartera y el estado de
            los proveedores de datos, en cuanto ocurren.
          </span>
        </div>
      ) : (
        <div className="log__list" ref={listaRef} onScroll={alDesplazar}>
          {eventos.map((e, i) => (
            <article key={`${e.timestamp ?? "sin-hora"}-${i}`} className={`log__item log__item--${e.tipo ?? "sys"}`}>
              <span className="log__glyph" aria-hidden="true" />
              <time className="log__time">{horaCorta(e.timestamp)}</time>
              <p className="log__msg">{e.mensaje}</p>
            </article>
          ))}
        </div>
      )}
    </Panel>
  );
}
