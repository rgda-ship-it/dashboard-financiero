import { formatearMultiplicador, formatearTope } from "../../formato.js";

/**
 * Apalancamiento recomendado contra el tope duro.
 *
 * El tope se dibuja como un remache de latón al final de la barra: es la
 * regla que `riesgo/apalancamiento.py` garantiza con un `min()` explícito
 * y que ninguna señal puede cruzar. Hacerlo visible en cada fila es la
 * forma de que esa garantía se lea, no solo se cumpla.
 *
 * Cuando el motor NO encuadra operación (confluencia bajista, neutral, o
 * volatilidad no disponible) no hay número operable. En ese caso la barra
 * no se apaga: muestra en gris la referencia de volatilidad —la base sin
 * el bonus de confluencia— porque sigue siendo información útil, pero
 * deja claro con el color y con el rótulo que no es una cifra para operar.
 *
 * Un «—» a secas se leería como «el proveedor falló», que es un problema
 * distinto y ya tiene su propio tratamiento en la fila de error.
 */

export default function BarraApalancamiento({ recomendado, tope, referencia, operable }) {
  const topeValido = Number.isFinite(tope) && tope > 0;
  const cifra = operable ? recomendado : referencia;
  const hayCifra = Number.isFinite(cifra);
  const proporcion = hayCifra && topeValido ? Math.min(1, Math.max(0, cifra / tope)) : 0;

  return (
    <div className={`lev${operable ? "" : " lev--inerte"}`}>
      <p className="lev__val">
        {operable ? formatearMultiplicador(recomendado) : "—"}
        <span>x</span>
      </p>

      <div
        className="lev__bar"
        role="img"
        aria-label={
          operable && Number.isFinite(recomendado)
            ? `Apalancamiento recomendado ${recomendado} de un tope duro de ${tope}`
            : hayCifra
              ? `Sin apalancamiento operable. Referencia por volatilidad: ${cifra}`
              : "Sin apalancamiento operable"
        }
      >
        <span className="lev__fill" style={{ width: `${proporcion * 100}%` }} />
        <span className="lev__cap" />
      </div>

      <p className="lev__note">
        {operable
          ? `tope ${formatearTope(tope)}x`
          : hayCifra
            ? `ref. vol. ${formatearMultiplicador(cifra)}x`
            : "no operable"}
      </p>
    </div>
  );
}
