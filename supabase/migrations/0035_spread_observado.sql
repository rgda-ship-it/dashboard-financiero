-- ─────────────────────────────────────────────────────────────────────
-- 0035 — El spread real de cada acción, medido (D23 bis, 2026-10-11).
--
-- La 0034 supuso 0,03 $ para todas las acciones. El dueño contrastó tres
-- con su plataforma:
--     AGNC  8,67 / 8,68   → 0,01 $   (simulamos 0,03: pesimista)
--     F    12,16 / 12,17  → 0,01 $   (pesimista)
--     AMCR 41,77 / 41,87  → 0,10 $   (simulábamos 0,03: OPTIMISTA)
-- El spread depende de la liquidez de cada acción, no de su precio: un
-- único valor acierta en las muy líquidas y se queda corto en las demás.
--
--   1. AMCR pasa a 0,10 $ ya.
--   2. El ETL de acciones guarda, en sesión regular (9:35–15:55 NY, sin
--      subastas ni pre/post mercado), el precio de compra y de venta que da
--      Yahoo (`spreads_observados`).
--   3. Con al menos 10 observaciones en 30 días, el percentil 90 del spread
--      observado de cada acción se guarda en `activos.spread_observado`.
--   4. El spread que se cobra es el MAYOR entre el configurado (el de la
--      acción o, si no tiene, el de su mercado) y el observado. Nunca baja
--      del configurado: el dueño eligió el escenario pesimista, y una
--      acción que resulte menos líquida de lo supuesto deja de quedarse en
--      el lado optimista sin que nadie lo vea.
--
-- La cripto no se mide: CoinGecko no da compra y venta, y QuantFury copia
-- el libro mayorista. Sigue con los valores de la 0034.
-- ─────────────────────────────────────────────────────────────────────

-- 1. AMCR
update public.activos set spread_abs = 0.10, spread_pct = 0 where simbolo = 'AMCR';


-- 2. Observaciones
create table public.spreads_observados (
    id           bigserial primary key,
    activo_id    bigint not null references public.activos(id) on delete cascade,
    observado_en timestamptz not null default now(),
    bid          numeric(20, 8) not null check (bid > 0),
    ask          numeric(20, 8) not null,
    spread_abs   numeric(20, 8) generated always as (ask - bid) stored,
    spread_pct   numeric(10, 4) generated always as (round((ask - bid) / ((ask + bid) / 2) * 100, 4)) stored,
    constraint spread_ask_no_menor_que_bid check (ask >= bid)
);
create index spreads_observados_activo_idx on public.spreads_observados (activo_id, observado_en desc);

comment on table public.spreads_observados is
  'Precio de compra y de venta de cada acción que da Yahoo en sesión regular, guardado por el ETL (0035). De aquí sale activos.spread_observado.';

alter table public.spreads_observados enable row level security;
create policy spreads_observados_aprobados on public.spreads_observados
    for select to authenticated using (public.es_usuario_aprobado());
grant select on public.spreads_observados to authenticated;


-- 3. Resumen por activo
alter table public.activos
    add column spread_observado    numeric(20, 8),
    add column spread_observado_n  int not null default 0,
    add column spread_observado_en timestamptz;

comment on column public.activos.spread_observado is
  'Percentil 90 del spread medido en los últimos 30 días, con al menos 10 observaciones (0035). Nulo hasta entonces. fn_spread cobra el mayor entre este y el configurado.';

create function public.fn_resumir_spread_observado()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_n   int;
    v_p90 numeric;
begin
    -- Lo que tiene más de 60 días ya no sirve para nada: se purga aquí.
    delete from public.spreads_observados
     where activo_id = new.activo_id and observado_en < now() - interval '60 days';

    select count(*), percentile_cont(0.9) within group (order by spread_abs)
      into v_n, v_p90
      from public.spreads_observados
     where activo_id = new.activo_id and observado_en >= now() - interval '30 days';

    update public.activos
       set spread_observado = case when v_n >= 10 then round(v_p90, 8) end,
           spread_observado_n = v_n,
           spread_observado_en = now()
     where id = new.activo_id;
    return null;
end;
$$;

create trigger spreads_observados_resumen
    after insert on public.spreads_observados
    for each row execute function public.fn_resumir_spread_observado();

revoke execute on function public.fn_resumir_spread_observado() from public, anon, authenticated;


-- 4. El spread que se cobra
create or replace function public.fn_spread(p_activo_id bigint, p_precio numeric)
returns numeric
language sql stable
as $$
    select greatest(
               case when a.spread_abs is not null or a.spread_pct is not null
                    then greatest(coalesce(a.spread_abs, 0), p_precio * coalesce(a.spread_pct, 0) / 100)
                    else greatest(coalesce(m.spread_abs, 0), p_precio * coalesce(m.spread_pct, 0) / 100) end,
               -- 0035: lo medido manda si es mayor que lo supuesto.
               coalesce(a.spread_observado, 0))
      from public.activos a
      left join public.mercados m on m.clave = public.fn_mercado_de_clase(a.clase)
     where a.id = p_activo_id
$$;

-- Lo configurado frente a lo medido, por acción.
create view public.v_spreads
with (security_invoker = true) as
    select a.id as activo_id, a.simbolo, a.clase, a.ultimo_precio,
           case when a.spread_abs is not null or a.spread_pct is not null
                then greatest(coalesce(a.spread_abs, 0), a.ultimo_precio * coalesce(a.spread_pct, 0) / 100)
                else greatest(coalesce(m.spread_abs, 0), a.ultimo_precio * coalesce(m.spread_pct, 0) / 100) end
               as spread_configurado,
           a.spread_observado, a.spread_observado_n, a.spread_observado_en,
           public.fn_spread(a.id, a.ultimo_precio) as spread_cobrado,
           round(public.fn_spread(a.id, a.ultimo_precio) / nullif(a.ultimo_precio, 0) * 100, 4) as spread_cobrado_pct
      from public.activos a
      left join public.mercados m on m.clave = public.fn_mercado_de_clase(a.clase)
     where a.estado = 'activo';

comment on view public.v_spreads is
  'Spread configurado, medido (percentil 90, 30 días) y el que se cobra (el mayor) de cada activo (0035).';
