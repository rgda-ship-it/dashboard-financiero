-- ─────────────────────────────────────────────────────────────────────
-- 0008 — H-16: la cartera de la Fase 1 pasa a `posiciones_reales`.
--
-- Lo que anunciaba 0000: el nombre `cartera_posiciones` se conservó para
-- que el port fuera verificable contra el schema.sql de la Fase 1, y las
-- FK apuntaban a auth.users porque `perfiles` no existía. Ya existe.
--
-- DESCIFRADO DE LA FASE 1: NO SE EJECUTA. El dueño confirmó el
-- 2026-09-22 que no tiene posiciones que conservar en el PostgreSQL local
-- de la Fase 1 y empieza de cero. Así que no hay nada que pasar por
-- backend/src/services/cifrado.js, y PORTFOLIO_ENCRYPTION_KEY no se usa
-- en la nube. Sigue existiendo solo para el modo local de la Fase 1, que
-- se retira en H-21.
-- ─────────────────────────────────────────────────────────────────────

alter table public.cartera_posiciones rename to posiciones_reales;
alter sequence if exists public.cartera_posiciones_id_seq rename to posiciones_reales_id_seq;

comment on table public.posiciones_reales is
  'Posiciones que el usuario declara tener (sucesora de cartera_posiciones, Fase 1). Importes EN CLARO por D3: ninguna cifra del sistema es dinero real.';

-- Enlace al catálogo. Nullable: la importación por CSV (H-21) resuelve
-- el ticker contra `activos` y puede encontrarse uno aún desconocido.
alter table public.posiciones_reales
    add column activo_id bigint references public.activos(id) on delete set null;

-- Las FK pasan de auth.users a perfiles. 0007 creó un perfil para cada
-- usuario existente, así que ninguna fila queda huérfana.
alter table public.posiciones_reales
    drop constraint if exists cartera_posiciones_usuario_id_fkey,
    add constraint posiciones_reales_usuario_id_fkey
        foreign key (usuario_id) references public.perfiles(id) on delete cascade;

-- El consentimiento es un audit trail: si se borra el usuario, la fila
-- se conserva con usuario_id nulo en vez de desaparecer en cascada.
alter table public.registro_consentimiento
    drop constraint if exists registro_consentimiento_usuario_id_fkey,
    add constraint registro_consentimiento_usuario_id_fkey
        foreign key (usuario_id) references public.perfiles(id) on delete set null;

create index if not exists posiciones_reales_usuario_idx
    on public.posiciones_reales (usuario_id);

-- ── RLS (ya activada en 0001; se repite por claridad) ─────────────
alter table public.posiciones_reales       enable row level security;
alter table public.registro_consentimiento enable row level security;

create policy posiciones_propias on public.posiciones_reales
    for all to authenticated
    using (usuario_id = auth.uid() and public.es_usuario_aprobado())
    with check (usuario_id = auth.uid() and public.es_usuario_aprobado());
create policy posiciones_select_admin on public.posiciones_reales
    for select to authenticated using (public.es_admin());

-- Consentimiento: se lee y se AÑADE, nunca se edita ni se borra.
create policy consentimiento_select_propio on public.registro_consentimiento
    for select to authenticated
    using (usuario_id = auth.uid() and public.es_usuario_aprobado());
create policy consentimiento_insert_propio on public.registro_consentimiento
    for insert to authenticated
    with check (usuario_id = auth.uid() and public.es_usuario_aprobado());
revoke update, delete on public.registro_consentimiento from authenticated;
