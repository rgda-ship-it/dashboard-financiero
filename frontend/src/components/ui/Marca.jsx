/**
 * Marca del producto: una retícula de escaneo con un vértice encendido.
 * Es la misma idea que sostiene toda la interfaz — el sistema barre un
 * universo y solo una intersección se ilumina.
 */
export default function Marca() {
  return (
    <div className="mark" aria-hidden="true">
      <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
        <path
          d="M2 6h14M2 12h14M6 2v14M12 2v14"
          stroke="currentColor"
          strokeWidth="1"
          className="dim"
          opacity="0.55"
        />
        <path
          d="M2.5 13.5 6 10l3 2.5L15.5 4.5"
          stroke="var(--acc-500)"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <circle cx="15.5" cy="4.5" r="2" fill="var(--acc-500)" opacity="0.22" />
        <circle cx="15.5" cy="4.5" r="1.1" fill="var(--acc-300)" />
      </svg>
    </div>
  );
}
