import { formatearPrecio } from "../../formato.js";

/**
 * Riel de niveles técnicos: dónde está el precio entre el soporte y la
 * resistencia recientes. Tres cifras sueltas en columnas separadas obligan
 * a hacer la resta mentalmente; el riel la resuelve de un vistazo.
 *
 * El riel tiene dos lecturas según si el motor encuadra o no una operación:
 *
 * - `operable`: los niveles llevan rol. El inferior es el STOP (rojo, lo
 *   que se pierde) y el superior el OBJETIVO (verde, lo que se busca), y
 *   la pista se tiñe en ese sentido.
 * - no operable: exactamente los mismos números, sin rol y en gris. Son
 *   soporte y resistencia, dato técnico válido en cualquier dirección —
 *   pero el sistema no está proponiendo ninguna operación con ellos.
 *
 * Rotularlos «SL» y «TP» cuando no hay operación encuadrada sería vender
 * como orden lo que solo es estructura de precio.
 */
export default function RielRiesgo({ inferior, superior, precio, operable }) {
  const valido =
    Number.isFinite(inferior) &&
    Number.isFinite(superior) &&
    Number.isFinite(precio) &&
    superior > inferior;

  // Fuera de rango el precio se ancla al extremo: preferible a un punto
  // flotando fuera de la barra.
  const posicion = valido ? Math.min(1, Math.max(0, (precio - inferior) / (superior - inferior))) : 0.5;

  const descripcion = !valido
    ? "Niveles técnicos no disponibles"
    : operable
      ? `Precio ${precio} entre stop ${inferior} y objetivo ${superior}`
      : `Precio ${precio} entre soporte ${inferior} y resistencia ${superior}, sin rol operativo`;

  return (
    <div className={`rail${operable ? "" : " rail--neutro"}`}>
      <div className="rail__track" role="img" aria-label={descripcion}>
        {valido && <span className="rail__dot" style={{ left: `${posicion * 100}%` }} />}
      </div>

      <div className="rail__ends">
        <span className={operable ? "neg" : "dim"}>
          <b className="label">{operable ? "SL" : "Sop."}</b> {formatearPrecio(inferior)}
        </span>
        <span className={operable ? "pos" : "dim"}>
          {formatearPrecio(superior)} <b className="label">{operable ? "TP" : "Res."}</b>
        </span>
      </div>
    </div>
  );
}
