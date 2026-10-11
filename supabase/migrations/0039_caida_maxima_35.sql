-- ─────────────────────────────────────────────────────────────────────
-- 0039 — Pausa por caída de «Tendencia cripto» al 35 % (2026-10-11).
--
-- El laboratorio de cartera (doc 07 §6), con las restricciones reales del
-- agente, da caídas máximas del 25–26 % en una estrategia que gana
-- (+1,0–1,1 R por operación a 10 años), y del 15,1 % en la validación a
-- 5 años. Con el umbral de la 0037 (15 %) el agente se habría pausado solo
-- en plena racha ganadora. Decisión del dueño, antes de la primera
-- operación (sin contaminar el experimento): 35 %, por encima de la peor
-- caída histórica con margen.
--
-- El umbral pasa a ser un parámetro de la estrategia (`caida_max_pct`) en
-- vez de un número en la vista. El otro criterio de retirada (expectativa
-- negativa a las 30 operaciones) no cambia.
-- ─────────────────────────────────────────────────────────────────────

update public.agentes
   set estrategia = estrategia || '{"caida_max_pct": 35}'::jsonb
 where nombre = 'Tendencia cripto';

create or replace view public.v_agentes_estrategia
with (security_invoker = true) as
    select g.id as agente_id, g.nombre, g.estado, g.estrategia ->> 'regla' as regla,
           ce.id as cuenta_id, ce.equity, ce.drawdown_pct, ce.posiciones_abiertas,
           coalesce(o.cerradas, 0) as cerradas,
           o.expectativa_r, o.r_total, o.aciertos_pct, o.mejor_r, o.peor_r,
           coalesce(o.en_regla, 0) as en_regla, coalesce(o.en_sl, 0) as en_sl,
           o.dias_medios,
           case
               when coalesce(ce.drawdown_pct, 0) <= -coalesce((g.estrategia ->> 'caida_max_pct')::numeric, 35) then 'caida'
               when coalesce(o.cerradas, 0) < 5 then 'arranque'
               when o.cerradas < 30 then 'en_prueba'
               when o.expectativa_r < 0 then 'retirar'
               when o.expectativa_r <= 0.10 and o.cerradas < 60 then 'observacion'
               when o.expectativa_r <= 0.10 then 'retirar'
               else 'validado'
           end as criterio,
           (select max(fecha_vela) from public.agente_decisiones_diarias d where d.agente_id = g.id) as ultima_vela
      from public.agentes g
      left join public.v_cuentas_equity ce on ce.id = public.fn_cuenta_agente(g.id)
      left join lateral (
          select count(*) as cerradas,
                 round(avg(r), 4) as expectativa_r,
                 round(sum(r), 2) as r_total,
                 round(100.0 * count(*) filter (where r > 0) / nullif(count(*), 0), 1) as aciertos_pct,
                 round(max(r), 2) as mejor_r, round(min(r), 2) as peor_r,
                 count(*) filter (where motivo_cierre = 'regla') as en_regla,
                 count(*) filter (where motivo_cierre in ('sl', 'liquidacion')) as en_sl,
                 round(avg(extract(epoch from fecha_salida - fecha_entrada) / 86400)::numeric, 1) as dias_medios
            from (select x.*, x.pnl_bruto / nullif(x.cantidad * (x.precio_entrada - coalesce(x.sl_original, x.sl)), 0) as r
                    from public.ordenes x
                   where x.cuenta_id = ce.id and x.estado = 'cerrada') t
      ) o on true
     where g.tipo = 'estrategia';

comment on view public.v_agentes_estrategia is
  'Agentes de estrategia (0037): expectativa en R y criterio del doc 07 §6. arranque (< 5 cerradas), en_prueba (< 30), observacion (0..+0,10 R hasta 60), validado (> +0,10 R), retirar, caida (drawdown ≤ −caida_max_pct, 35 % por defecto desde la 0039).';

create or replace function public.fn_ciclo_estrategias()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag   record;
    v_out  jsonb := '[]'::jsonb;
    v_err  text;
    v_cod  text;
    v_ctx  text;
begin
    for v_ag in select g.id, g.nombre, e.criterio, e.cerradas, e.expectativa_r, e.drawdown_pct
                  from public.agentes g left join public.v_agentes_estrategia e on e.agente_id = g.id
                 where g.tipo = 'estrategia' order by g.id
    loop
        begin
            -- El criterio de retirada se fijó de antemano: se aplica solo.
            if v_ag.criterio in ('retirar', 'caida')
               and exists (select 1 from public.agentes where id = v_ag.id and estado = 'activo') then
                update public.agentes set estado = 'pausado', estado_previo = 'activo' where id = v_ag.id;
                insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
                values (v_ag.id, 'agente',
                        v_ag.nombre || case when v_ag.criterio = 'caida'
                                            then format(' queda en pausa: la caída desde el máximo pasó del %s %%',
                                                        (select coalesce(estrategia ->> 'caida_max_pct', '35')
                                                           from public.agentes where id = v_ag.id))
                                            else ' queda en pausa: cumple el criterio de retirada' end,
                        jsonb_build_object('criterio', v_ag.criterio, 'cerradas', v_ag.cerradas,
                                           'expectativa_r', v_ag.expectativa_r, 'drawdown_pct', v_ag.drawdown_pct));
            end if;
            v_out := v_out || public.fn_decidir_tendencia(v_ag.id);
        exception when others then
            get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
            v_out := v_out || jsonb_build_object('agente_id', v_ag.id, 'error', v_err);
            perform public.fn_registrar_fallo(v_ag.id, 'decisión diaria', v_err, v_cod, v_ctx);
        end;
    end loop;
    return v_out;
end;
$$;
