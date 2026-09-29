import { IconoAlerta } from "./ui/Iconos.jsx";

/**
 * Aviso legal permanente (H-33).
 *
 * Va ARRIBA de las dos pantallas donde aparecen importes —simulador y
 * agentes— y no en un pie, porque tiene que leerse antes de introducir una
 * cifra. No se puede cerrar: un aviso que se descarta una vez deja de
 * existir para siempre, y este es la condición de dos decisiones.
 *
 * La segunda frase es el supuesto de la decisión D3 (no cifrar importes)
 * escrito donde el usuario lo ve. No es una formalidad: es lo que hace
 * segura esa decisión, y si algún día deja de ser cierto hay que revisarla.
 */
export default function AvisoLegal() {
  return (
    <aside className="aviso-legal" role="note" aria-label="Aviso legal">
      <IconoAlerta size={14} aria-hidden="true" />
      <p>
        <strong>Simulación educativa, no asesoramiento financiero.</strong> Ninguna cifra de este
        sistema es dinero real: los saldos, las órdenes y los agentes son ficticios, y por eso los
        importes se guardan sin cifrar. No introduzcas aquí datos de cuentas reales.
      </p>
    </aside>
  );
}
