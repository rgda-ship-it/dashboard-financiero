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

-- ── Cartera importada ───────────────────────────────────────────────
-- Se conserva el nombre `cartera_posiciones` en esta migración para que
-- 0000 sea un port verificable contra el schema.sql de la Fase 1. El
-- renombrado a `posiciones_reales` ocurre en el Sprint 3 (H-16).
--
-- DECISIÓN D3, FIRMADA POR EL DUEÑO EL 2026-09-20: NO SE CIFRA NINGÚN
-- IMPORTE. La Fase 1 guardaba `precio_compra_cifrado` y `monto_cifrado`
-- como texto AES-256-GCM (backend/src/services/cifrado.js), y la regla
-- protegida nº7 del README exigía que así fuera. Esa regla queda
-- RETIRADA en la Fase 2, por una razón concreta: en este sistema NINGÚN
-- importe es dinero real. Ni los del simulador, ficticios por
-- definición, ni los de esta tabla.
--
-- Lo que se gana: el corte semanal de los agentes, el P&L y cualquier
-- agregación se resuelven en SQL con un SUM(). Con importes cifrados
-- habría que descifrar la tabla entera en aplicación en cada evaluación,
-- y además sería imposible indexar u ordenar por importe.
--
-- LA CONDICIÓN QUE SOSTIENE ESTA DECISIÓN, escrita para quien la lea
-- dentro de un año: el supuesto es que ningún importe de este sistema
-- corresponde a una posición real del usuario. Si algún día se cargan
-- cifras reales de patrimonio, la decisión deja de ser válida y hay que
-- revisarla ANTES de importarlas, no después. Lo que queda protegiendo
-- estos datos es RLS más el cifrado en reposo del proveedor: eso protege
-- frente a terceros, no frente a una consulta autorizada.
create table if not exists public.cartera_posiciones (
    id             bigserial primary key,
    usuario_id     uuid references auth.users(id) on delete cascade,
    ticker         varchar(20) not null,
    precio_compra  numeric(20, 8) not null check (precio_compra > 0),
    monto          numeric(20, 2) not null check (monto >= 0),
    creado_en      timestamptz not null default now()
);

comment on table public.cartera_posiciones is
  'Cartera importada por CSV. Importes EN CLARO por decisión D3 (2026-09-20): ningún importe del sistema es dinero real. Se renombra a posiciones_reales en H-16.';

comment on column public.cartera_posiciones.monto is
  'Importe FICTICIO. Si alguna vez fuera a contener una cifra real de patrimonio, hay que revisar la decisión D3 antes de cargarla.';

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
