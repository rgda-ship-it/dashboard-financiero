-- ─────────────────────────────────────────────────────────────────────
-- 0058 — Índices de referencia: se leen, no se operan
--        (doc fase-3/12 §2, recomendación 13; 2026-11-05).
--
-- El dueño dio de alta el S&P 500 (^GSPC) y el Nasdaq 100 (^NDX) el
-- 2026-11-05 a las 18:54 UTC. Entraron como acciones activas: los
-- agentes podían comprarlos en cuanto el escáner los diera por operables,
-- y la vara de la 0056 los contaba como dos acciones más del universo.
-- Un índice no se puede comprar; sirve de vara y para la fuerza relativa.
--
--   · `activos.referencia`: columna generada, verdadera para los
--     símbolos de Yahoo que empiezan por «^» (todos sus índices).
--   · `senales_vigentes.estado_activo` = 'referencia' para ellos: el
--     universo de los agentes (`fn_universo_agente`, que pide 'activo')
--     ya no los ve, ni sus descartes ni el autodiagnóstico.
--   · Ninguna orden sobre un índice, ni de agente ni del simulador
--     (disparador en `ordenes`).
--   · La vara (0056) los saca de «universo» y «acciones» y los añade
--     como referencias propias: «sp500» y «nasdaq100».
--
-- El ETL los sigue leyendo (no mira `referencia`): precios e
-- indicadores diarios al día. Para el grupo de control no cambia nada:
-- su universo vuelve a ser el de antes del alta.
-- ─────────────────────────────────────────────────────────────────────

alter table public.activos
    add column referencia boolean generated always as (simbolo like '^%') stored;

comment on column public.activos.referencia is
  'Índice de referencia (símbolo de Yahoo con «^»): se lee para la vara y la fuerza relativa, no se opera (0058).';

-- ── Las señales vigentes: un índice es «referencia», no «activo» ─────
create or replace view public.senales_vigentes
with (security_invoker = true) as
    select s.*,
           a.simbolo,
           a.clase,
           a.nombre,
           case when a.referencia then 'referencia' else a.estado end as estado_activo
      from public.activos a
      cross join lateral (
            select *
              from public.senales s1
             where s1.activo_id = a.id
             order by s1.calculado_en desc
             limit 1
      ) s;

comment on view public.senales_vigentes is
  'Última señal de cada activo. LATERAL + LIMIT 1 sobre senales_activo_fecha_idx: una lectura de índice por activo (0006, H-08). Los índices salen con estado_activo = referencia (0058).';

-- ── Ninguna orden sobre un índice ────────────────────────────────────
create function public.fn_ordenes_sin_indices()
returns trigger
language plpgsql
as $$
begin
    if exists (select 1 from public.activos where id = new.activo_id and referencia) then
        raise exception 'El activo % es un índice de referencia: no se opera (0058)', new.activo_id
              using errcode = 'P0001';
    end if;
    return new;
end
$$;

revoke execute on function public.fn_ordenes_sin_indices() from public, anon, authenticated;

create trigger ordenes_sin_indices
    before insert on public.ordenes
    for each row execute function public.fn_ordenes_sin_indices();

-- ── La vara, con los índices aparte ──────────────────────────────────
create or replace view public.v_referencia_mercado
with (security_invoker = true) as
with ventanas as (
    select 'alta'::text as ventana, min(creado_en)::date as desde
      from public.agentes where tipo = 'metas'
    union all
    select 'experimento', min(creado_en)::date
      from public.agentes where tipo = 'estrategia'
), grupos as (
    select a.id as activo_id, g.referencia
      from public.activos a
      cross join lateral (values (case when not a.referencia then 'universo' end),
                                 (case when a.referencia then null
                                       when a.clase = 'accion' then 'acciones' else 'cripto' end),
                                 (case when a.simbolo = 'bitcoin' then 'bitcoin' end),
                                 (case a.simbolo when '^GSPC' then 'sp500' when '^NDX' then 'nasdaq100' end))
                   g(referencia)
     where a.estado = 'activo' and g.referencia is not null
), extremos as (
    select v.ventana, v.desde, gr.referencia, ini.cierre as c0, fin.fecha as f1, fin.cierre as c1
      from ventanas v
      cross join grupos gr
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = gr.activo_id and p.fecha >= v.desde
                     order by p.fecha limit 1) ini on true
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = gr.activo_id
                     order by p.fecha desc limit 1) fin on true
     where v.desde is not null and ini.fecha <= v.desde + 4 and ini.cierre > 0
)
select referencia, ventana, desde, max(f1) as hasta, count(*) as activos,
       round(avg(c1 / c0 - 1) * 100, 2) as rentabilidad_pct
  from extremos
 group by referencia, ventana, desde;

comment on view public.v_referencia_mercado is
  'Comprar y mantener a partes iguales (todo, acciones, cripto y bitcoin), sin apalancamiento ni costes, desde el alta de los agentes con metas y desde el experimento (0056). Los índices (0058) no entran en el universo: son sus propias referencias (sp500, nasdaq100).';
