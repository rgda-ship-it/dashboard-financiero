-- ─────────────────────────────────────────────────────────────────────
-- 0063 — La cartera, con las cuatro clases que ofrece el broker
-- (2026-11-14).
--
-- El broker no tiene EFA ni DBC, ni otro ETF de bolsa desarrollada o de
-- materias primas amplias. De lo que tiene, la cartera queda en cuatro
-- clases al 25 %: bolsa de EE. UU. (SPY), bonos del Tesoro a 7–10 años
-- (IEF), inmobiliario (VNQ) y oro (GLD). Con la lista de la 0062 las
-- carteras esperaban a cinco activos y no habrían empezado nunca.
--
-- Ninguna de las dos carteras ha operado todavía: el cambio no toca
-- ningún dato.
--
-- De paso, `activos.solo_cartera` deja de ser una columna generada con la
-- lista escrita dentro: cambiar la lista obligaba a borrar la columna y
-- las vistas que la leen. Ahora la lista está en una función y un
-- disparador la aplica al dar de alta el activo.
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. La lista, en un solo sitio ────────────────────────────────────
create function public.fn_es_clase_de_cartera(p_simbolo text)
returns boolean
language sql
immutable
as $$
    select p_simbolo in ('SPY', 'IEF', 'VNQ', 'GLD')
$$;

comment on function public.fn_es_clase_de_cartera(text) is
  'Las clases de activo que llevan los agentes de cartera (0063). Para cambiar la lista: esta función y un UPDATE de activos.solo_cartera.';

-- La columna pasa a ser normal, conservando lo que tenía.
alter table public.activos alter column solo_cartera drop expression;
update public.activos set solo_cartera = public.fn_es_clase_de_cartera(simbolo)
 where solo_cartera is distinct from public.fn_es_clase_de_cartera(simbolo);
alter table public.activos alter column solo_cartera set default false;
alter table public.activos alter column solo_cartera set not null;

comment on column public.activos.solo_cartera is
  'ETF de una clase de activo entera (0062): lo llevan los agentes de cartera. Los demás agentes no lo ven y no cuenta en la vara del universo. Lo pone el disparador activos_solo_cartera según fn_es_clase_de_cartera (0063).';

create function public.fn_activos_solo_cartera()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    new.solo_cartera := public.fn_es_clase_de_cartera(new.simbolo);
    return new;
end
$$;

create trigger activos_solo_cartera
    before insert or update of simbolo, solo_cartera on public.activos
    for each row execute function public.fn_activos_solo_cartera();

revoke execute on function public.fn_activos_solo_cartera() from public, anon, authenticated;
revoke execute on function public.fn_es_clase_de_cartera(text) from public, anon, authenticated;

-- ── 2. Las dos carteras, con cuatro clases al 25 % ───────────────────
update public.agentes
   set estrategia = estrategia || jsonb_build_object(
           'activos', jsonb_build_array('SPY', 'IEF', 'VNQ', 'GLD'),
           'peso_pct', 25,
           'max_posiciones_abiertas', 4)
 where tipo = 'cartera';

select public.fn_sincronizar_cuenta_agente(id) from public.agentes where tipo = 'cartera';

insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
select id, 'agente', nombre || ' pasa a cuatro clases al 25 % (0063): SPY, IEF, VNQ y GLD',
       jsonb_build_object('activos', estrategia -> 'activos')
  from public.agentes where tipo = 'cartera';
