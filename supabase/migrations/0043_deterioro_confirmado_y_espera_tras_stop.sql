-- ─────────────────────────────────────────────────────────────────────
-- 0043 — Deterioro confirmado y espera tras el stop (2026-10-17).
--
-- La revisión de la primera semana fuera de la cuarentena (13–16 de
-- octubre) mostró dos fallos en los agentes con metas:
--
--   1. LA SALIDA POR DETERIORO VENDÍA POR UNA SOLA LECTURA. La señal se
--      recalcula cada 30 minutos y la salida (0024) saltaba con la primera
--      que empeorase. F entró a las 13:40 del 13-10, salió por deterioro a
--      las 14:10 (−0,66 R), volvió a entrar a las 15:10 más caro y llegó al
--      objetivo (+1,86 R). WFC salió por deterioro en la primera lectura
--      de la sesión del 14-10 (13:40), volvió a entrar a las 15:10 más
--      caro y llegó al objetivo. De 16 cierres, 7 fueron por deterioro,
--      con una media de unos −0,4 R.
--      → Ahora el deterioro tiene que verse en DOS lecturas seguidas
--        posteriores a la entrada: la vigente y la anterior. Una lectura
--        de ruido, o la primera de la sesión con la subasta de apertura,
--        ya no basta.
--
--   2. VOLVÍAN A ENTRAR EN EL VALOR QUE ACABABA DE TOCAR EL STOP. Audacia
--      perdió −1 R en QFIN el 12-10 y otra vez el 14-10, y a los dos
--      minutos de este último stop volvió a entrar en QFIN.
--      → Tras un cierre por stop (o liquidación) en un activo, el agente
--        no vuelve a entrar en él durante `espera_tras_stop_horas` (48 h
--        por defecto, parámetro de la estrategia). Descarte nuevo:
--        'tras_stop'.
--
-- Lo demás no cambia: el resto de motivos de deterioro, la permanencia
-- mínima de 30 minutos, el aprendizaje que apaga la salida si le cuesta
-- dinero y los demás filtros del universo. Decisión del dueño: los
-- agentes con metas se ajustan para medir el efecto de las mejoras (0042).
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- 1. Deterioro confirmado
-- ═════════════════════════════════════════════════════════════════════

-- Por qué una señal ha empeorado frente a la de entrada (null = no ha
-- empeorado). La misma regla de la 0024, ahora reutilizable.
create function public.fn_motivo_deterioro(p_nueva public.senales, p_entrada public.senales)
returns text
language sql immutable
as $$
    select case
               when p_nueva.indicadores_alcistas <= p_nueva.indicadores_bajistas then 'direccion'
               when not p_nueva.operable and p_nueva.atr_pct is not null then 'no_operable'
               when public.fn_rango_fuerza(p_nueva.fuerza) < public.fn_rango_fuerza(p_entrada.fuerza) then 'fuerza'
           end
$$;

create or replace function public.fn_agente_salidas_deterioro(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_p      jsonb;
    v_cuenta bigint;
    v_o      record;
    v_res    jsonb;
    v_n      int := 0;
begin
    select public.fn_parametros_agente(a) into v_p from public.agentes a where a.id = p_agente_id;
    if not coalesce((v_p ->> 'salida_deterioro')::boolean, true) then
        return 0;
    end if;
    v_cuenta := public.fn_cuenta_agente(p_agente_id);

    for v_o in
        select m.id, m.simbolo, m.precio_vivo, m.tp, m.sl, m.cantidad,
               e.fuerza as fuerza_entrada, s.id as senal_nueva, s.fuerza as fuerza_nueva,
               ant.id as senal_anterior,
               public.fn_motivo_deterioro(s, e) as motivo,
               public.fn_motivo_deterioro(ant, e) as motivo_anterior
          from public.v_ordenes_abiertas_monitor m
          join public.ordenes o on o.id = m.id
          join public.senales e on e.id = o.senal_id
          join public.senales s on s.id = (select v.id from public.senales_vigentes v
                                             where v.activo_id = o.activo_id)
          -- 0043: la lectura anterior a la vigente, también posterior a
          -- la entrada.
          left join lateral (
               select a.* from public.senales a
                where a.activo_id = o.activo_id
                  and a.calculado_en < s.calculado_en
                  and a.calculado_en > o.fecha_entrada
                order by a.calculado_en desc
                limit 1) ant on true
         where m.cuenta_id = v_cuenta
           and o.fecha_entrada < now() - interval '30 minutes'
           and s.id <> o.senal_id
           and s.calculado_en > o.fecha_entrada
           and m.precio_vivo > m.sl and m.precio_vivo < m.tp
         order by m.id
    loop
        -- 0043: hacen falta dos lecturas seguidas con deterioro.
        continue when v_o.motivo is null or v_o.senal_anterior is null or v_o.motivo_anterior is null;
        v_res := public.rpc_cerrar_orden(v_o.id, v_o.precio_vivo, 'deterioro', v_o.precio_vivo);
        continue when not coalesce((v_res ->> 'cerrada')::boolean, false);
        insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
        values (p_agente_id, 'deterioro', v_o.id,
                jsonb_build_object('salida_deterioro', true),
                jsonb_build_object('motivo', v_o.motivo, 'motivo_anterior', v_o.motivo_anterior,
                                   'simbolo', v_o.simbolo,
                                   'precio', v_o.precio_vivo, 'tp', v_o.tp, 'sl', v_o.sl,
                                   'cantidad', v_o.cantidad, 'senal_nueva', v_o.senal_nueva,
                                   'senal_anterior', v_o.senal_anterior,
                                   'fuerza_entrada', v_o.fuerza_entrada, 'fuerza_nueva', v_o.fuerza_nueva,
                                   'pnl_al_cerrar', v_res -> 'pnl'));
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$;

revoke execute on function public.fn_agente_salidas_deterioro(bigint) from public, anon, authenticated;
revoke execute on function public.fn_motivo_deterioro(public.senales, public.senales) from public, anon;


-- ═════════════════════════════════════════════════════════════════════
-- 2. Espera tras el stop
-- ═════════════════════════════════════════════════════════════════════
-- La función de la 0032 con un motivo de descarte más, justo después de
-- «ya tengo una posición abierta en este activo».
create or replace function public.fn_universo_agente(p_params jsonb, p_cuenta_id bigint, p_practicas jsonb)
returns table (
    senal_id bigint, activo_id bigint, simbolo text, clase text, fuerza text,
    niveles_origen text, ratio_rr numeric, atr_pct numeric, precio_actual numeric,
    sl numeric, tp numeric, leverage_recomendado numeric,
    alcistas int, bajistas int, antiguedad_min int, motivo text)
language sql stable
as $$
    select s.id, s.activo_id, s.simbolo, s.clase, s.fuerza, s.niveles_origen,
           s.ratio_rr, s.atr_pct, s.precio_actual, s.sl, s.tp, s.leverage_recomendado,
           s.indicadores_alcistas, s.indicadores_bajistas, x.antiguedad_min,
           case
               when x.antiguedad_min > (p_params ->> 'antiguedad_senal_max_min')::int
                    then case when s.clase = 'accion' and public.fn_esperando_apertura(now())
                                   then 'fuera_de_sesion'   -- 0029: aún sin la primera lectura de la sesión
                              when s.clase = 'cripto' or public.fn_mercado_abierto(now())
                                   then 'antiguedad' else 'fuera_de_sesion' end
               when not (s.indicadores_alcistas > s.indicadores_bajistas) then 'direccion'
               when not s.operable and s.atr_pct is null then 'sin_atr'
               when not s.operable then 'no_operable'
               when not (p_params -> 'fuerzas_admitidas' ? coalesce(s.fuerza, '')) then 'fuerza'
               when not (p_params -> 'niveles_origen_admitidos' ? coalesce(s.niveles_origen, '')) then 'niveles_origen'
               when s.ratio_rr is null or s.ratio_rr < (p_params ->> 'rr_minimo')::numeric then 'rr'
               -- 0032: el rango de ATR puede ser distinto por mercado.
               when public.fn_param_clase(p_params, s.clase, 'atr_pct_min') #>> '{}' is not null
                    and (s.atr_pct is null
                         or s.atr_pct < (public.fn_param_clase(p_params, s.clase, 'atr_pct_min') #>> '{}')::numeric) then 'atr_bajo'
               when public.fn_param_clase(p_params, s.clase, 'atr_pct_max') #>> '{}' is not null
                    and (s.atr_pct is null
                         or s.atr_pct > (public.fn_param_clase(p_params, s.clase, 'atr_pct_max') #>> '{}')::numeric) then 'atr_alto'
               when exists (select 1 from public.ordenes o
                             where o.cuenta_id = p_cuenta_id and o.activo_id = s.activo_id
                               and o.estado = 'abierta') then 'posicion_abierta'
               -- 0043: tras un stop en este activo, se espera antes de volver.
               when exists (select 1 from public.ordenes o
                             where o.cuenta_id = p_cuenta_id and o.activo_id = s.activo_id
                               and o.estado = 'cerrada' and o.motivo_cierre in ('sl', 'liquidacion')
                               and o.fecha_salida > now() - make_interval(
                                       hours => coalesce((p_params ->> 'espera_tras_stop_horas')::int, 48)))
                    then 'tras_stop'
               when exists (select 1 from jsonb_array_elements(coalesce(p_practicas, '[]'::jsonb)) e
                             where case when coalesce(e ->> 's', 'exigir') = 'evitar'
                                        then public.fn_cumple_condiciones(
                                                 e -> 'c', s.clase, s.fuerza, s.niveles_origen, s.atr_pct, s.ratio_rr)
                                        else not public.fn_cumple_condiciones(
                                                 coalesce(e -> 'c', e), s.clase, s.fuerza, s.niveles_origen,
                                                 s.atr_pct, s.ratio_rr) end)
                    then 'practica'
           end
      from public.senales_vigentes s
      cross join lateral (
           select round(extract(epoch from now() - s.calculado_en) / 60)::int as antiguedad_min) x
     where s.estado_activo = 'activo'
       and p_params -> 'clases_admitidas' ? s.clase
$$;
