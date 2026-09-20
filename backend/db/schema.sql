-- Esquema de persistencia de cartera del Portfolio Health Selector.
--
-- precio_compra_cifrado y monto_cifrado se guardan como texto cifrado
-- (ver backend/src/services/cifrado.js) — nunca en texto plano, incluso
-- corriendo en localhost (checklist de auditoría, Sprint 4, punto #1).

CREATE TABLE IF NOT EXISTS cartera_posiciones (
    id SERIAL PRIMARY KEY,
    ticker VARCHAR(20) NOT NULL,
    precio_compra_cifrado TEXT NOT NULL,
    monto_cifrado TEXT NOT NULL,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Registro de consentimiento de persistencia (audit trail exigido por el
-- DPO en Sprint 1 — permite demostrar cumplimiento ante una auditoría).
CREATE TABLE IF NOT EXISTS registro_consentimiento (
    id SERIAL PRIMARY KEY,
    tipo VARCHAR(50) NOT NULL,           -- ej. 'persistencia_cartera'
    otorgado BOOLEAN NOT NULL,
    otorgado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
