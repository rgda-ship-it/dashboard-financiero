/**
 * Indicador de estado de la barra superior. `tono` decide el color y
 * `vivo` enciende el punto pulsante — solo debe usarse cuando algo está
 * realmente ocurriendo en tiempo real.
 */
export default function Chip({ etiqueta, valor, tono = "neutro", vivo = false }) {
  const clases = ["chip"];
  if (vivo) clases.push("chip--live");
  else if (tono !== "neutro") clases.push(`chip--${tono}`);

  return (
    <span className={clases.join(" ")}>
      <span className="chip__dot" aria-hidden="true" />
      {etiqueta && <span className="chip__key">{etiqueta}</span>}
      <span>{valor}</span>
    </span>
  );
}
