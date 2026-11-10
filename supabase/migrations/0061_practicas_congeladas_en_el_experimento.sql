-- ─────────────────────────────────────────────────────────────────────
-- 0061 — Prácticas congeladas durante el experimento, y las v2 con las
-- prácticas de su original (revisión del lunes 9-11, decisión del dueño
-- del 2026-11-10).
--
-- Cada semana «aviso» o «deficiente», el corte semanal (0042) hace que el
-- agente adopte la práctica ajena mejor valorada que pueda aplicar, y a
-- las dos semanas la evalúa y puede abandonarla. Con las metas
-- inalcanzables todas las semanas lo son, así que el grupo de control
-- cambia de reglas cada lunes: la 0052 congeló los ajustes, pero no esto.
-- El 2-11 Prudencia y Cadencia adoptaron la 89 y Audacia la 97; el 9-11,
-- Prudencia y Cadencia la 110. Hasta hoy no les han quitado ninguna
-- entrada.
--
-- Las v2 nacieron (0060) con `practicas_adoptadas` copiado del original,
-- pero sin fila en `mp_adopciones`, que es de donde lee el ciclo. El 9-11
-- adoptaron la 60, que exige clase acción: desde entonces no abren
-- ninguna cripto y dejan de ser «su original más su filtro».
--
-- Ahora:
-- 1. fn_adoptar_practica y fn_evaluar_adopciones no hacen nada en un
--    agente con `consecuencias_semanales = false` (el mismo interruptor
--    de la 0042 y la 0052). Al acabar el experimento vuelven solas.
-- 2. Cada v2 deja las prácticas que adoptó por su cuenta y lleva las que
--    tiene activas su original. Con la adopción congelada, se quedan
--    iguales.
-- Las del grupo de control (89, 97 y 110) se quedan como están: quitarlas
-- también sería cambiarle las reglas.
-- ─────────────────────────────────────────────────────────────────────

-- ── 1. Adoptar: congelado con las consecuencias suspendidas ──────────
create or replace function public.fn_adoptar_practica(p_agente_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag public.agentes;
    v_id bigint;
begin
    select * into v_ag from public.agentes where id = p_agente_id;

    -- 0061: durante el experimento, el agente no adopta prácticas solo.
    if not v_ag.consecuencias_semanales then
        return null;
    end if;

    select p.id into v_id
      from public.mejores_practicas p
      left join lateral (select coalesce(sum(valoracion), 0) as puntos
                           from public.mp_valoraciones v where v.practica_id = p.id) v on true
     where p.estado in ('propuesta', 'validada')
       and p.agente_autor_id <> p_agente_id
       and not (p_agente_id = any(p.coautores))
       and not exists (select 1 from public.mp_adopciones ad
                        where ad.practica_id = p.id and ad.agente_id = p_agente_id)
       and public.fn_practica_adoptable(public.fn_parametros_agente(v_ag), p.condiciones, p.sentido)
     order by v.puntos desc, p.confianza desc,
              (p.resultado_observado ->> 'ops')::int desc, p.id
     limit 1;

    if v_id is null then return null; end if;

    insert into public.mp_adopciones (practica_id, agente_id) values (v_id, p_agente_id);
    perform public.fn_espejar_practicas(p_agente_id);
    return v_id;
end;
$$;

-- ── 1 bis. Evaluar: también congelado ────────────────────────────────
-- Evaluar puede abandonar una práctica (o refutarla para todos): también
-- cambia las reglas. Las adopciones quedan pendientes y se evalúan al
-- volver las consecuencias, con todas las operaciones que haya.
create or replace function public.fn_evaluar_adopciones(p_agente_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ad        record;
    v_antes     numeric;
    v_despues   numeric;
    v_ops_antes int;
    v_ops_desp  int;
    v_ver       text;
    v_out       jsonb := '[]'::jsonb;
begin
    -- 0061: durante el experimento no se evalúa ni se abandona nada.
    if not coalesce((select consecuencias_semanales from public.agentes where id = p_agente_id), true) then
        return v_out;
    end if;

    for v_ad in select * from public.mp_adopciones
                 where agente_id = p_agente_id and abandonada_en is null and veredicto is null
                   and adoptada_en <= now() - interval '14 days'
                 order by id
    loop
        select coalesce(avg(o.pnl_pct), 0), count(*) into v_antes, v_ops_antes
          from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
         where c.agente_id = p_agente_id and o.estado = 'cerrada' and o.fecha_entrada < v_ad.adoptada_en;
        select avg(o.pnl_pct), count(*) into v_despues, v_ops_desp
          from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
         where c.agente_id = p_agente_id and o.estado = 'cerrada' and o.fecha_entrada >= v_ad.adoptada_en;

        if v_ops_desp < 5 then continue; end if;

        v_ver := case when v_despues > v_antes + abs(v_antes) * 0.1 then 'mejoro'
                      when v_despues < v_antes - abs(v_antes) * 0.1 then 'empeoro'
                      else 'neutro' end;

        update public.mp_adopciones
           set veredicto = v_ver, evaluada_en = now(), ops_bajo_practica = v_ops_desp,
               resultado = jsonb_build_object('antes_pnl_medio_pct', round(v_antes, 4),
                                              'despues_pnl_medio_pct', round(v_despues, 4),
                                              'ops_antes', v_ops_antes, 'ops_despues', v_ops_desp),
               abandonada_en = case when v_ver = 'empeoro' then now() end
         where id = v_ad.id;

        perform public.fn_valorar_practica(v_ad.practica_id, p_agente_id,
            (case v_ver when 'mejoro' then 1 when 'empeoro' then -1 else 0 end)::smallint,
            format('%s: %s %% antes, %s %% después', v_ver, round(v_antes, 2), round(v_despues, 2)));

        if v_ver = 'empeoro' then
            perform public.fn_espejar_practicas(p_agente_id);
            if (select count(*) from public.mp_adopciones
                 where practica_id = v_ad.practica_id and veredicto = 'empeoro') >= 2 then
                update public.mejores_practicas
                   set estado = 'refutada', actualizado_en = now()
                 where id = v_ad.practica_id and estado <> 'refutada';
                -- Refutada deja de ofrecerse, y deja de aplicarse a quien la
                -- tuviera adoptada: un filtro refutado no es un filtro.
                update public.mp_adopciones
                   set abandonada_en = now(), resultado = coalesce(resultado, '{}'::jsonb)
                                                          || '{"motivo": "practica_refutada"}'
                 where practica_id = v_ad.practica_id and abandonada_en is null;
                perform public.fn_espejar_practicas(a.agente_id)
                   from (select distinct agente_id from public.mp_adopciones
                          where practica_id = v_ad.practica_id) a;
                insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
                values (p_agente_id, 'practica', 'Práctica refutada tras dos adopciones que empeoraron',
                        jsonb_build_object('practica_id', v_ad.practica_id));
            end if;
        end if;

        v_out := v_out || jsonb_build_object('adopcion_id', v_ad.id, 'practica_id', v_ad.practica_id,
                                             'veredicto', v_ver);
    end loop;
    return v_out;
end;
$$;

revoke execute on function public.fn_adoptar_practica(bigint)   from public, anon, authenticated;
revoke execute on function public.fn_evaluar_adopciones(bigint) from public, anon, authenticated;

-- ── 2. Las v2, con las prácticas de su original ──────────────────────
-- Deja las que adoptó cada v2 por su cuenta (la 60, el 9-11)...
update public.mp_adopciones ad
   set abandonada_en = now(),
       resultado = coalesce(ad.resultado, '{}'::jsonb) || '{"motivo": "0061_v2_como_su_original"}'
  from public.agentes v
 where v.id = ad.agente_id and v.deriva_de is not null and ad.abandonada_en is null
   and not exists (select 1 from public.mp_adopciones o
                    where o.agente_id = v.deriva_de and o.practica_id = ad.practica_id
                      and o.abandonada_en is null);

-- ...y lleva las que tiene activas su original.
insert into public.mp_adopciones (practica_id, agente_id, resultado)
select o.practica_id, v.id, '{"motivo": "0061_copia_del_original"}'::jsonb
  from public.agentes v
  join public.mp_adopciones o on o.agente_id = v.deriva_de and o.abandonada_en is null
 where v.deriva_de is not null
   and not exists (select 1 from public.mp_adopciones x
                    where x.agente_id = v.id and x.practica_id = o.practica_id
                      and x.abandonada_en is null);

select public.fn_espejar_practicas(v.id) from public.agentes v where v.deriva_de is not null;

insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
select v.id, 'agente', v.nombre || ' lleva las prácticas de su original (0061)',
       jsonb_build_object('practicas', v.estrategia -> 'practicas_adoptadas')
  from public.agentes v
 where v.deriva_de is not null;
