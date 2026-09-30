-- ─────────────────────────────────────────────────────────────────────
-- 0020 — Cada usuario elige los límites de su cuenta (2026-09-30).
--
-- Los parámetros de riesgo viven en la tabla desde la 0011 (deuda técnica
-- nº3 de la Fase 1), pero solo se podían cambiar a mano con SQL: el dueño
-- se encontró con que el simulador no le dejaba abrir una cuarta posición
-- (G4, 3 por defecto) y no había dónde cambiarlo.
--
-- `rpc_configurar_cuenta` cambia los cuatro que son decisión del usuario,
-- SOLO en su propia cuenta y dentro de rangos que no desactivan ningún
-- guardarraíl:
--
--   posiciones abiertas máx.   1 – 10   (G4; mismo rango que el CHECK)
--   riesgo por operación       0,1 – 10 % del equity (G2 sigue en 10 %)
--   margen comprometido máx.   10 – 80 % del equity (G3)
--   R:R mínimo                 0 – 5
--
-- El margen se queda en 80 % y no en el 100 % que admite el CHECK: con
-- todo el equity comprometido no queda saldo para la operación siguiente
-- ni colchón para una posición que se mueve en contra (doc 03 §4, G3). El
-- tope de apalancamiento NO es configurable: es la regla protegida nº1.
--
-- Nulo = no cambiar ese parámetro. Cada cambio deja un evento del usuario
-- con los valores de antes y de después.
-- ─────────────────────────────────────────────────────────────────────

create function public.rpc_configurar_cuenta(
    p_max_posiciones   int default null,
    p_riesgo_pct       numeric default null,
    p_margen_max_pct   numeric default null,
    p_ratio_rr_minimo  numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid    uuid := public.fn_exigir_aprobado();
    v_cuenta public.cuentas_simulacion;
    v_antes  jsonb;
    v_despues jsonb;
begin
    select * into v_cuenta from public.cuentas_simulacion
     where usuario_id = v_uid and estado <> 'game_over'
     order by id desc limit 1
       for update;
    if not found then
        raise exception 'No tienes una cuenta de simulación abierta.' using errcode = 'P0002';
    end if;

    if p_max_posiciones is not null and (p_max_posiciones < 1 or p_max_posiciones > 10) then
        raise exception 'Las posiciones abiertas van de 1 a 10. Recibido: %', p_max_posiciones
              using errcode = '22023';
    end if;
    if p_riesgo_pct is not null and (p_riesgo_pct < 0.1 or p_riesgo_pct > 10) then
        raise exception 'El riesgo por operación va del 0,1 %% al 10 %% del equity. Recibido: %', p_riesgo_pct
              using errcode = '22023';
    end if;
    if p_margen_max_pct is not null and (p_margen_max_pct < 10 or p_margen_max_pct > 80) then
        raise exception 'El margen comprometido máximo va del 10 %% al 80 %% del equity. Recibido: %', p_margen_max_pct
              using errcode = '22023';
    end if;
    if p_ratio_rr_minimo is not null and (p_ratio_rr_minimo < 0 or p_ratio_rr_minimo > 5) then
        raise exception 'El R:R mínimo va de 0 a 5. Recibido: %', p_ratio_rr_minimo
              using errcode = '22023';
    end if;

    v_antes := jsonb_build_object(
        'max_posiciones_abiertas', v_cuenta.max_posiciones_abiertas,
        'riesgo_pct_operacion', v_cuenta.riesgo_pct_operacion,
        'margen_comprometido_max_pct', v_cuenta.margen_comprometido_max_pct,
        'ratio_rr_minimo', v_cuenta.ratio_rr_minimo);

    update public.cuentas_simulacion set
        max_posiciones_abiertas     = coalesce(p_max_posiciones, max_posiciones_abiertas),
        riesgo_pct_operacion        = coalesce(round(p_riesgo_pct, 2), riesgo_pct_operacion),
        margen_comprometido_max_pct = coalesce(round(p_margen_max_pct, 2), margen_comprometido_max_pct),
        ratio_rr_minimo             = coalesce(round(p_ratio_rr_minimo, 2), ratio_rr_minimo),
        actualizado_en              = now()
     where id = v_cuenta.id
    returning jsonb_build_object(
        'max_posiciones_abiertas', max_posiciones_abiertas,
        'riesgo_pct_operacion', riesgo_pct_operacion,
        'margen_comprometido_max_pct', margen_comprometido_max_pct,
        'ratio_rr_minimo', ratio_rr_minimo) into v_despues;

    if v_despues is distinct from v_antes then
        insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
        values (v_uid, 'sys', 'Límites de la cuenta de simulación cambiados',
                jsonb_build_object('cuenta_id', v_cuenta.id, 'antes', v_antes, 'despues', v_despues));
    end if;

    return jsonb_build_object('cuenta_id', v_cuenta.id, 'antes', v_antes, 'despues', v_despues);
end;
$$;

revoke execute on function public.rpc_configurar_cuenta(int, numeric, numeric, numeric) from public, anon;
grant  execute on function public.rpc_configurar_cuenta(int, numeric, numeric, numeric) to authenticated;
