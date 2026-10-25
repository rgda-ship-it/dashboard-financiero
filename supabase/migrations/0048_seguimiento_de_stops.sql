-- ─────────────────────────────────────────────────────────────────────
-- 0048 — Qué pasa después de un stop, con operaciones reales (doc
-- fase-3/03 §2; petición del dueño, 2026-10-25).
--
-- El laboratorio mide que, por cada stop que corta una ganancia, de 3 a 6
-- evitan una pérdida mayor. En producción no se podía comprobar: la base
-- seguía el precio 24 h después de una salida por OBJETIVO
-- (`precio_max_post_cierre`, para el trailing stop), pero no después de un
-- stop.
--
-- Desde aquí, cada orden cerrada por stop (o liquidación) se sigue con las
-- velas diarias de las 10 sesiones siguientes, con la misma regla que el
-- laboratorio:
--   · «corto»   : el precio llegó al objetivo original → el stop cortó una ganancia;
--   · «salvo»   : cayó otro riesgo entero por debajo de la salida → el stop evitó una pérdida mayor;
--   · «ambiguo» : las dos cosas el mismo día (con velas diarias no se sabe el orden);
--   · «ninguno» : ninguna de las dos en 10 sesiones.
-- riesgo = entrada − stop inicial (`sl_original`, si la toma parcial lo movió).
--
-- Velas diarias y no el precio vivo: tras un stop, el activo puede no
-- tener posición abierta, y entonces su precio vivo se actualiza poco.
-- `fn_seguir_stops` corre cada hora y repasa los stops de los últimos 30
-- días sin veredicto. Al aplicarse, rellena los que ya hay.
-- ─────────────────────────────────────────────────────────────────────

alter table public.ordenes
    add column post_stop_max         numeric(20, 8),
    add column post_stop_min         numeric(20, 8),
    add column post_stop_sesiones    int,
    add column post_stop_evento      text check (post_stop_evento in ('corto', 'salvo', 'ambiguo', 'ninguno')),
    add column post_stop_revisado_en timestamptz;

comment on column public.ordenes.post_stop_evento is
    'Tras un stop, en 10 sesiones: corto (llegó al objetivo), salvo (cayó otro riesgo), ambiguo (las dos el mismo día) o ninguno. Null mientras se observa (0048).';

create function public.fn_seguir_stops()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_o       record;
    v_v       record;
    v_riesgo  numeric;
    v_max     numeric;
    v_min     numeric;
    v_n       int;
    v_evento  text;
    v_hechas  int := 0;
begin
    for v_o in
        select o.id, o.activo_id, o.precio_entrada, o.precio_salida, o.fecha_salida, o.tp,
               coalesce(o.sl_original, o.sl) as sl0
          from public.ordenes o
         where o.estado = 'cerrada' and o.motivo_cierre in ('sl', 'liquidacion')
           and o.post_stop_evento is null
           and o.fecha_salida > now() - interval '30 days'
           and o.tp is not null
    loop
        v_riesgo := v_o.precio_entrada - v_o.sl0;
        continue when v_riesgo is null or v_riesgo <= 0;
        v_max := null; v_min := null; v_n := 0; v_evento := null;
        for v_v in
            select coalesce(p.maximo, p.cierre) as alto, coalesce(p.minimo, p.cierre) as bajo
              from public.precios_diarios p
             where p.activo_id = v_o.activo_id and p.fecha > (v_o.fecha_salida at time zone 'UTC')::date
             order by p.fecha
             limit 10
        loop
            v_n := v_n + 1;
            v_max := greatest(coalesce(v_max, v_v.alto), v_v.alto);
            v_min := least(coalesce(v_min, v_v.bajo), v_v.bajo);
            if v_v.alto >= v_o.tp and v_v.bajo <= v_o.precio_salida - v_riesgo then
                v_evento := 'ambiguo';
            elsif v_v.alto >= v_o.tp then
                v_evento := 'corto';
            elsif v_v.bajo <= v_o.precio_salida - v_riesgo then
                v_evento := 'salvo';
            end if;
            exit when v_evento is not null;
        end loop;
        if v_evento is null and v_n >= 10 then
            v_evento := 'ninguno';
        end if;
        update public.ordenes
           set post_stop_max = v_max, post_stop_min = v_min, post_stop_sesiones = v_n,
               post_stop_evento = v_evento, post_stop_revisado_en = now()
         where id = v_o.id;
        v_hechas := v_hechas + 1;
    end loop;
    return v_hechas;
end;
$$;

revoke execute on function public.fn_seguir_stops() from public, anon, authenticated;

-- En R, para leerlo junto al laboratorio: el resultado del stop, cuánto
-- rebotó y cuánto siguió cayendo después de la salida (sobre el máximo y
-- el mínimo de las sesiones vistas), y el veredicto.
create view public.v_seguimiento_stops
with (security_invoker = true) as
    select o.id as orden_id, o.cuenta_id, g.nombre as agente, a.simbolo, a.clase,
           o.fecha_entrada, o.fecha_salida, o.motivo_cierre, o.cierre_por_hueco,
           o.precio_entrada, coalesce(o.sl_original, o.sl) as sl_inicial, o.tp, o.precio_salida,
           round((o.precio_salida - o.precio_entrada) / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0), 3) as r_real,
           round((o.post_stop_max - o.precio_salida) / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0), 3) as rebote_r,
           round((o.precio_salida - o.post_stop_min) / nullif(o.precio_entrada - coalesce(o.sl_original, o.sl), 0), 3) as caida_r,
           o.post_stop_sesiones as sesiones, o.post_stop_evento as evento, o.post_stop_revisado_en as revisado_en
      from public.ordenes o
      join public.activos a on a.id = o.activo_id
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      left join public.agentes g on g.id = c.agente_id
     where o.estado = 'cerrada' and o.motivo_cierre in ('sl', 'liquidacion');

grant select on public.v_seguimiento_stops to authenticated;

do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('seguir-stops', '45 * * * *', 'select public.fn_seguir_stops()')$q$;
        raise notice 'seguir-stops programado cada hora a los :45';
    else
        raise notice 'pg_cron no disponible: el seguimiento de stops no queda programado (esperado en la CI)';
    end if;
end
$cron$;

-- Los stops que ya hay (desde la 0030, todos de menos de 30 días).
select public.fn_seguir_stops();
