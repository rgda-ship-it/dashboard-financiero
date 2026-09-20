-- ─────────────────────────────────────────────────────────────────────
-- 0000 — Base heredada de la Fase 1.
--
-- Porta backend/db/schema.sql tal cual, con una sola diferencia:
-- `usuario_id`. Es exactamente la columna que anticipaba el comentario
-- de backend/src/services/persistenciaCartera.js:
--
--   "Uso de un solo usuario local: no hay `user_id` porque el sistema
--    corre en localhost para una sola persona: si en el futuro se
--    soporta más de un usuario, esta es la primera tabla que necesita
--    esa columna."
--
-- Aquí llega ese futuro.
--
-- La FK apunta por ahora a `auth.users` porque `public.perfiles` no
-- existe hasta el Sprint 3 (H-13). La migración 0002 la reapunta a
-- `perfiles` sin pérdida de datos.
-- ─────────────────────────────────────────────────────────────────────

-- Las extensiones (pg_cron, pg_net) viven en su propia migración,
-- `0002_extensiones.sql`, porque solo existen en Supabase. Separarlas
-- permite aplicar 0000 y 0001 sobre un PostgreSQL limpio en la CI, que
-- es la red que sustituye al proyecto de staging que el tier gratuito no
-- da (ver .github/workflows/migraciones.yml).

-- ── Cartera real importada (cifrada) ────────────────────────────────
-- Se conserva el nombre `cartera_posiciones` en esta migración para que
-- 0000 sea un port literal y verificable contra el schema.sql de la
-- Fase 1. El renombrado a `posiciones_reales` ocurre en el Sprint 3
-- (H-16), junto con la asignación de las filas existentes al perfil
-- admin.
--
-- precio_compra_cifrado y monto_cifrado siguen siendo TEXTO CIFRADO
-- (AES-256-GCM, ver backend/src/services/cifrado.js). La regla
-- protegida nº7 se mantiene INTACTA para esta tabla: es la cartera real
-- del usuario, su patrimonio. La decisión D3 solo afecta a los importes
-- ficticios del simulador, que llegan en el Sprint 5.
create table if not exists public.cartera_posiciones (
    id                     bigserial primary key,
    usuario_id             uuid references auth.users(id) on delete cascade,
    ticker                 varchar(20) not null,
    precio_compra_cifrado  text not null,
    monto_cifrado          text not null,
    creado_en              timestamptz not null default now()
);

comment on table public.cartera_posiciones is
  'Cartera real importada por CSV. Importes SIEMPRE cifrados (regla protegida nº7). Se renombra a posiciones_reales en H-16.';

-- ── Registro de consentimiento ──────────────────────────────────────
-- Audit trail exigido por el DPO en el Sprint 1 de la Fase 1. NO se
-- trunca nunca: su valor es justamente poder demostrar qué se consintió
-- y cuándo, incluso después de ejercer el derecho de supresión.
create table if not exists public.registro_consentimiento (
    id          bigserial primary key,
    usuario_id  uuid references auth.users(id) on delete cascade,
    tipo        varchar(50) not null,
    otorgado    boolean not null,
    otorgado_en timestamptz not null default now()
);

comment on table public.registro_consentimiento is
  'Audit trail de consentimiento (DPO, Fase 1 Sprint 1). Append-only por convención: no se trunca al borrar una cartera.';

create index if not exists registro_consentimiento_usuario_idx
  on public.registro_consentimiento (usuario_id, otorgado_en desc);
