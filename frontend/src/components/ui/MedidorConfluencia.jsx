import { IconoDireccion } from "./Iconos.jsx";
import { segmentosDeFuerza } from "../../formato.js";

/**
 * Confluencia en una sola lectura: dirección (flecha), fuerza (tres
 * segmentos) y cuántos indicadores la sostienen.
 *
 * Los tres segmentos son deliberados: el motor solo produce baja/media/alta
 * y nunca dispara por un indicador aislado, así que un porcentaje continuo
 * sugeriría una precisión que el cálculo no tiene.
 */
export default function MedidorConfluencia({ direccion, fuerza, apoyos, total, nota }) {
  const encendidos = segmentosDeFuerza(fuerza);

  return (
    <div className={`conf conf--${direccion}`}>
      <span className={`conf__dir conf__dir--${direccion}`}>
        <IconoDireccion direccion={direccion} />
      </span>

      <div className="conf__body">
        <div
          className="conf__bars"
          role="img"
          aria-label={`Fuerza de confluencia ${fuerza ?? "sin dato"}`}
        >
          {[0, 1, 2].map((i) => (
            <i key={i} data-on={String(i < encendidos)} />
          ))}
        </div>
        <p className="conf__text">
          <b>{fuerza ?? "sin dato"}</b>
          {Number.isFinite(apoyos) && Number.isFinite(total) && total > 0
            ? ` · ${apoyos}/${total} indicadores`
            : ""}
        </p>
        {/* El motivo va en la propia celda y no solo en el detalle
            desplegable: si no, las celdas vacías de la fila se leen como
            un fallo del proveedor en vez de como una decisión del motor. */}
        {nota && <p className="conf__nota">{nota}</p>}
      </div>
    </div>
  );
}
