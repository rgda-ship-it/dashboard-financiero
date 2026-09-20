/**
 * Set de iconos propio, dibujado a 16px sobre una rejilla de 24 con trazo
 * de 1.6. Se dibujan en línea (no hay librería de iconos) para que hereden
 * `currentColor` y para no cargar un paquete entero por siete glifos.
 */

function Svg({ size = 16, children, ...resto }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...resto}
    >
      {children}
    </svg>
  );
}

export function IconoRefrescar(props) {
  return (
    <Svg {...props}>
      <path d="M20 11a8 8 0 0 0-13.7-5.3L3 9" />
      <path d="M4 13a8 8 0 0 0 13.7 5.3L21 15" />
      <path d="M3 4v5h5" />
      <path d="M21 20v-5h-5" />
    </Svg>
  );
}

export function IconoBuscar(props) {
  return (
    <Svg size={14} {...props}>
      <circle cx="11" cy="11" r="6.5" />
      <path d="m20 20-3.6-3.6" />
    </Svg>
  );
}

export function IconoCaret(props) {
  return (
    <Svg size={12} {...props}>
      <path d="m6 9 6 6 6-6" />
    </Svg>
  );
}

export function IconoSubir(props) {
  return (
    <Svg size={18} {...props}>
      <path d="M12 16V4" />
      <path d="m7.5 8.5 4.5-4.5 4.5 4.5" />
      <path d="M4 15v3.5A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5V15" />
    </Svg>
  );
}

export function IconoRestaurar(props) {
  return (
    <Svg size={14} {...props}>
      <path d="M3.5 8V4" />
      <path d="M3.5 8h4" />
      <path d="M4.2 8.3A8 8 0 1 1 4 12" />
      <path d="M12 8v4.4l3 1.8" />
    </Svg>
  );
}

export function IconoAlerta(props) {
  return (
    <Svg size={15} {...props}>
      <path d="M12 4.5 2.8 20h18.4L12 4.5Z" />
      <path d="M12 10v4" />
      <path d="M12 17.2h.01" />
    </Svg>
  );
}

export function IconoRadar(props) {
  return (
    <Svg size={26} {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <circle cx="12" cy="12" r="4.5" />
      <path d="M12 12 18 6" />
    </Svg>
  );
}

export function IconoCartera(props) {
  return (
    <Svg size={26} {...props}>
      <rect x="3" y="7" width="18" height="13" rx="2" />
      <path d="M8 7V5.5A1.5 1.5 0 0 1 9.5 4h5A1.5 1.5 0 0 1 16 5.5V7" />
      <path d="M3 12h18" />
    </Svg>
  );
}

export function IconoDireccion({ direccion, ...resto }) {
  if (direccion === "alcista") {
    return (
      <Svg size={14} {...resto}>
        <path d="M12 19V6" />
        <path d="m6 11.5 6-6 6 6" />
      </Svg>
    );
  }
  if (direccion === "bajista") {
    return (
      <Svg size={14} {...resto}>
        <path d="M12 5v13" />
        <path d="m6 12.5 6 6 6-6" />
      </Svg>
    );
  }
  return (
    <Svg size={14} {...resto}>
      <path d="M5 12h14" />
    </Svg>
  );
}

export function IconoAyuda(props) {
  return (
    <Svg {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M9.6 9.4a2.5 2.5 0 1 1 3.2 2.6c-.6.2-.8.7-.8 1.3v.4" />
      <path d="M12 16.6h.01" />
    </Svg>
  );
}

export function IconoCerrar(props) {
  return (
    <Svg {...props}>
      <path d="m6.5 6.5 11 11" />
      <path d="m17.5 6.5-11 11" />
    </Svg>
  );
}

export function IconoDescargar(props) {
  return (
    <Svg size={15} {...props}>
      <path d="M12 4v11" />
      <path d="m7.5 10.5 4.5 4.5 4.5-4.5" />
      <path d="M4 16v2.5A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5V16" />
    </Svg>
  );
}
