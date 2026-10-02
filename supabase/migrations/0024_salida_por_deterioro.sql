-- ─────────────────────────────────────────────────────────────────────
-- 0024 — Salida por deterioro de la señal (D17, 2026-10-02).
--
-- Observación del dueño sobre la 0023: si un agente solo rota con el saldo
-- lleno, una posición cuya señal ha cambiado sigue abierta mientras quede
-- saldo libre, cuando podría cerrarla, asegurar algo de ganancia o perder
-- menos, y llevar ese saldo a otra con más fuerza.
--
-- LA REGLA (determinista, en cada ciclo y antes de decidir):
--   una posición abierta hace más de 30 minutos, con precio fresco (M4) y
--   aún entre stop y objetivo, se cierra al precio vivo si la señal VIGENTE
--   de su activo —calculada después de la entrada— ha empeorado frente a
--   la de entrada:
--     · 'direccion'    ya no es alcista (alcistas ≤ bajistas);
--     · 'no_operable'  el motor ya no encuadra la operación (con ATR
--                      conocido: la falta de dato no es un cambio de mercado);
--     · 'fuerza'       su fuerza baja (alta → media, media → baja…).
--   El saldo liberado entra en el reparto de ese mismo ciclo.
--
-- Y SE APRENDE: cada salida es una decisión (`deterioro`) juzgada contra
-- lo que habría pasado sin ella (mismo contrafactual que la rotación:
-- primer nivel tocado, o el precio a los 7 días). Positivo = cerrar evitó
-- algo peor. Con 10 resueltas y media negativa, el agente apaga
-- `salida_deterioro`; si la tiene apagada y a los demás les funciona (10
-- resueltas de otros con media positiva), la vuelve a encender.
--
-- Motivo de cierre nuevo, `deterioro`. Como la rotación, lo decidió el
-- agente y no el mercado: no cuenta en la destilación de prácticas.
-- ─────────────────────────────────────────────────────────────────────

alter table public.ordenes drop constraint ordenes_motivo_cierre_check;
alter table public.ordenes add constraint ordenes_motivo_cierre_check
    check (motivo_cierre in ('tp', 'sl', 'liquidacion', 'manual', 'caducidad', 'rotacion', 'deterioro'));

alter table public.agente_decisiones drop constraint agente_decisiones_tipo_check;
alter table public.agente_decisiones add constraint agente_decisiones_tipo_check
    check (tipo in ('rotacion', 'parcial', 'reparto', 'deterioro'));

alter table public.agente_ajustes drop constraint agente_ajustes_tipo_check;
alter table public.agente_ajustes add constraint agente_ajustes_tipo_check
    check (tipo in ('rotacion', 'parcial', 'reparto', 'deterioro'));


-- ═════════════════════════════════════════════════════════════════════
-- Parámetros: salida_deterioro
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_parametros_agente(p_agente public.agentes)
returns jsonb
language plpgsql immutable
as $$
declare
    v jsonb;
begin
    v := jsonb_build_object(
            'riesgo_pct_operacion', 2.0,
            'max_posiciones_abiertas', 1,
            'rr_minimo', 1.5,
            'fuerzas_admitidas', jsonb_build_array('alta'),
            'clases_admitidas', jsonb_build_array('accion', 'cripto'),
            'niveles_origen_admitidos', jsonb_build_array('estructura', 'atr'),
            'apalancamiento_maximo_propio', 5.0,
            'margen_comprometido_max_pct', 100.0,
            'atr_pct_min', null,
            'atr_pct_max', null,
            'antiguedad_senal_max_min', 90,
            -- 0016: reparto por cupo, sin rotación y sin toma parcial, salvo
            -- que la estrategia diga otra cosa.
            -- 0023: el reparto lo decide la exigencia del día.
            'reparto', 'exigencia',
            'rotacion_umbral', null,
            'tp_parcial', null,
            -- 0024: cerrar una posición cuya señal se deterioró. Activo
            -- de partida; el agente lo apaga si le cuesta dinero.
            'salida_deterioro', true)
         || (p_agente.estrategia - 'practicas_adoptadas' - 'version' - 'modo_conservacion');

    -- 0023 (D17): los tres usan hasta el 100 % de su saldo para operar.
    -- Lo que diferencia a un perfil es su meta y su riesgo por operación,
    -- no cuánto saldo puede tocar. Se impone aquí, después de la mezcla,
    -- para que ninguna estrategia lo cambie.
    v := v || jsonb_build_object('margen_comprometido_max_pct', 100.0,
                                 'reparto', 'exigencia');

    if p_agente.riesgo_reducido then
        v := jsonb_set(v, '{riesgo_pct_operacion}',
                       to_jsonb(round((v ->> 'riesgo_pct_operacion')::numeric / 2, 2)));
    end if;
    if p_agente.estado = 'cuarentena'
       or (p_agente.estado = 'pausado' and p_agente.estado_previo = 'cuarentena') then
        v := v || jsonb_build_object('max_posiciones_abiertas', 1,
                                     'fuerzas_admitidas', jsonb_build_array('alta'));
    end if;
    return v;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- La salida por deterioro
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_agente_salidas_deterioro(p_agente_id bigint)
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
               s.indicadores_alcistas, s.indicadores_bajistas,
               case
                   when s.indicadores_alcistas <= s.indicadores_bajistas then 'direccion'
                   when not s.operable and s.atr_pct is not null then 'no_operable'
                   when public.fn_rango_fuerza(s.fuerza) < public.fn_rango_fuerza(e.fuerza) then 'fuerza'
               end as motivo
          from public.v_ordenes_abiertas_monitor m
          join public.ordenes o on o.id = m.id
          join public.senales e on e.id = o.senal_id
          join public.senales_vigentes s on s.activo_id = o.activo_id
         where m.cuenta_id = v_cuenta
           and o.fecha_entrada < now() - interval '30 minutes'
           and s.id <> o.senal_id
           and s.calculado_en > o.fecha_entrada
           and m.precio_vivo > m.sl and m.precio_vivo < m.tp
         order by m.id
    loop
        continue when v_o.motivo is null;
        v_res := public.rpc_cerrar_orden(v_o.id, v_o.precio_vivo, 'deterioro', v_o.precio_vivo);
        continue when not coalesce((v_res ->> 'cerrada')::boolean, false);
        insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
        values (p_agente_id, 'deterioro', v_o.id,
                jsonb_build_object('salida_deterioro', true),
                jsonb_build_object('motivo', v_o.motivo, 'simbolo', v_o.simbolo,
                                   'precio', v_o.precio_vivo, 'tp', v_o.tp, 'sl', v_o.sl,
                                   'cantidad', v_o.cantidad, 'senal_nueva', v_o.senal_nueva,
                                   'fuerza_entrada', v_o.fuerza_entrada, 'fuerza_nueva', v_o.fuerza_nueva,
                                   'pnl_al_cerrar', v_res -> 'pnl'));
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$;

revoke execute on function public.fn_agente_salidas_deterioro(bigint) from public, anon, authenticated;


-- ═════════════════════════════════════════════════════════════════════
-- El ciclo: la de la 0023 con la salida por deterioro antes de decidir
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_ciclo_agente(p_agente_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag       public.agentes;
    v_cuenta   bigint;
    v_dia      public.agente_dias;
    v_go       jsonb;
    v_dec      jsonb;
    v_c        jsonb;
    v_res      jsonb;
    v_rech     jsonb := '[]'::jsonb;
    v_hoy      date := (now() at time zone 'UTC')::date;
    v_salida   jsonb;
    v_parc     int := 0;
    v_det      int := 0;
    v_rot      jsonb;
    v_decision bigint;
    v_ordenes  jsonb := '[]'::jsonb;
    v_r        jsonb;
begin
    select * into v_ag from public.agentes where id = p_agente_id for update;
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    if v_cuenta is null then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'sin_cuenta');
    end if;

    v_dia := public.fn_sincronizar_dia_agente(p_agente_id, v_cuenta);

    v_go := public.rpc_evaluar_game_over(v_cuenta);
    if v_go ->> 'estado' = 'game_over' then
        if v_ag.estado <> 'game_over' then
            update public.agentes set estado = 'game_over', estado_previo = null,
                                      game_over_en = now() where id = p_agente_id;
        end if;
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'game_over');
    end if;

    if v_ag.estado not in ('activo', 'cuarentena') then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'agente_' || v_ag.estado);
    end if;

    -- 0016: gestionar lo abierto ANTES de decidir. Una toma parcial libera
    -- margen que la decisión de este mismo ciclo puede usar.
    v_parc := public.fn_agente_tomas_parciales(p_agente_id);
    -- 0024: y cerrar lo que se ha deteriorado. También va ANTES de
    -- decidir: el saldo que libera entra en el reparto de este ciclo.
    v_det := public.fn_agente_salidas_deterioro(p_agente_id);

    if not v_dia.operable then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'dia_no_operable',
                                  'tomas_parciales', v_parc, 'salidas_deterioro', v_det);
    end if;
    if v_go ->> 'estado' = 'inoperante' then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'cuenta_inoperante');
    end if;

    v_dec := public.fn_decidir_agente(p_agente_id);

    -- ── Rotación: cerrar la más débil y volver a decidir ────────────
    if v_dec ->> 'accion' = 'rotar' then
        v_rot := v_dec -> 'rotacion';
        v_res := public.rpc_cerrar_orden((v_rot ->> 'cerrar_orden_id')::bigint,
                                         (v_rot ->> 'precio')::numeric, 'rotacion',
                                         (v_rot ->> 'precio')::numeric);
        insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
        values (p_agente_id, 'rotacion', (v_rot ->> 'cerrar_orden_id')::bigint,
                jsonb_build_object('umbral', v_rot -> 'umbral'),
                v_rot || jsonb_build_object('pnl_al_cerrar', v_res -> 'pnl'))
        returning id into v_decision;
        v_dec := public.fn_decidir_agente(p_agente_id)
                 || jsonb_build_object('tras_rotar', v_rot);
        v_res := null;
    end if;

    -- 0023: abre TODAS sus marcadas en el mismo ciclo, cada una con su
    -- parte del reparto. Si el servidor rechaza una, siguen las demás.
    if v_dec ->> 'accion' = 'abrir' then
        for v_c in select c from jsonb_array_elements(v_dec -> 'marcadas') c
        loop
            begin
                v_r := public.rpc_abrir_orden(
                    v_cuenta, (v_c ->> 'senal_id')::bigint, null, null,
                    (v_c ->> 'apalancamiento_pedido')::numeric,
                    (v_dec #>> '{parametros,riesgo_pct_operacion}')::numeric,
                    'agente',
                    (v_dec - 'parametros' - 'accion' - 'marcadas')
                        || jsonb_build_object('elegido', v_c, 'marcadas', v_dec -> 'marcadas',
                                              'rechazos_servidor', v_rech,
                                              'parametros', v_dec -> 'parametros'),
                    (v_c ->> 'cantidad')::numeric);
                v_ordenes := v_ordenes || v_r;
                insert into public.agente_decisiones (agente_id, tipo, orden_id, parametro, datos)
                values (p_agente_id, 'reparto', (v_r ->> 'orden_id')::bigint,
                        jsonb_build_object('reparto', 'exigencia',
                                           'modo', v_dec #> '{reparto,modo}',
                                           'marcadas', v_dec #> '{reparto,marcadas}'),
                        jsonb_build_object('margen', v_r -> 'margen',
                                           'deficit', v_dec #> '{reparto,deficit}'));
            exception when others then
                v_rech := v_rech || jsonb_build_object('simbolo', v_c ->> 'simbolo', 'motivo', sqlerrm);
            end;
        end loop;

        if jsonb_array_length(v_ordenes) > 0 then
            v_res := v_ordenes -> 0;
            if v_decision is not null then
                update public.agente_decisiones
                   set orden_nueva_id = (v_res ->> 'orden_id')::bigint
                 where id = v_decision;
            end if;
        end if;
    end if;

    update public.agente_dias d set
        ciclos = ciclos + 1,
        ciclos_con_universo  = ciclos_con_universo + case when coalesce((v_dec ->> 'frescas')::int, 0) > 0 then 1 else 0 end,
        ciclos_sin_alcistas  = ciclos_sin_alcistas + case when coalesce((v_dec ->> 'sin_alcistas')::boolean, false) then 1 else 0 end,
        ciclos_sin_candidatos = ciclos_sin_candidatos
                                + case when v_dec ->> 'accion' = 'sin_candidatos'
                                         or (v_dec ->> 'accion' = 'abrir' and v_res is null) then 1 else 0 end,
        descartes = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
                        select k, sum(v)::int as v from (
                            select key as k, value::int as v from jsonb_each_text(d.descartes)
                            union all
                            select key, value::int from jsonb_each_text(coalesce(v_dec -> 'descartes_por_motivo', '{}'))
                             where key <> 'candidata') t group by k) s),
        cumplido = cumplido or v_dec ->> 'accion' = 'meta_cumplida',
        ultimo_ciclo_en = now(),
        ultima_decision = jsonb_build_object('accion', v_dec ->> 'accion',
                                             'orden', v_res, 'ordenes', v_ordenes, 'rechazos', v_rech,
                                             'rotacion', v_rot, 'tomas_parciales', v_parc,
                                             'salidas_deterioro', v_det,
                                             'deficit', v_dec -> 'deficit_pendiente',
                                             'candidatos', v_dec -> 'candidatos_evaluados')
     where agente_id = p_agente_id and fecha = v_hoy;

    perform public.fn_disparadores_backlog(p_agente_id, v_dec);

    if exists (select 1 from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
                where c.agente_id = p_agente_id and o.estado = 'cerrada'
                  and o.fecha_salida > coalesce(v_ag.destilado_en, '-infinity'::timestamptz)) then
        perform public.fn_destilar_practicas(p_agente_id);
    end if;

    -- Aprender: con decisiones resueltas suficientes, mover un parámetro.
    perform public.fn_ajustar_parametros(p_agente_id);

    v_salida := jsonb_build_object('agente', v_ag.nombre, 'accion', v_dec ->> 'accion',
                                   'candidatos', v_dec -> 'candidatos_evaluados');
    if v_rot is not null then
        v_salida := v_salida || jsonb_build_object('rotacion', v_rot);
    end if;
    if v_parc > 0 then
        v_salida := v_salida || jsonb_build_object('tomas_parciales', v_parc);
    end if;
    if v_det > 0 then
        v_salida := v_salida || jsonb_build_object('salidas_deterioro', v_det);
    end if;
    if v_res is not null then
        v_salida := v_salida || jsonb_build_object('orden', v_res, 'ordenes', v_ordenes);
    end if;
    if jsonb_array_length(v_rech) > 0 then
        v_salida := v_salida || jsonb_build_object('rechazos', v_rech);
    end if;
    return v_salida;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Resolver: la de la 0016 con las salidas por deterioro
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_resolver_decisiones()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_d     record;
    v_o     public.ordenes;
    v_b     public.ordenes;
    v_a     public.activos;
    v_cf    numeric;
    v_pnl_b numeric;
    v_n     int := 0;
begin
    for v_d in select * from public.agente_decisiones where resuelta_en is null order by id
    loop
        select * into v_o from public.ordenes where id = v_d.orden_id;
        if not found then continue; end if;

        if v_d.tipo = 'reparto' then
            -- Retorno sobre el margen con el que se abrió: la moneda común
            -- para comparar concentrar con repartir.
            continue when v_o.estado <> 'cerrada';
            update public.agente_decisiones
               set efecto = round((v_o.pnl_bruto + v_o.pnl_parciales) * 100
                                  / nullif((v_d.datos ->> 'margen')::numeric, 0), 4),
                   resultado = jsonb_build_object('pnl_total', v_o.pnl_bruto + v_o.pnl_parciales,
                                                  'motivo_cierre', v_o.motivo_cierre),
                   resuelta_en = now()
             where id = v_d.id;
            v_n := v_n + 1;

        elsif v_d.tipo = 'parcial' then
            -- Sin la parcial, esa cantidad habría salido al precio final de
            -- la orden. Positivo = la parcial se adelantó a algo peor.
            continue when v_o.estado <> 'cerrada';
            update public.agente_decisiones
               set efecto = round((v_d.datos ->> 'cantidad_cerrada')::numeric
                                  * ((v_d.datos ->> 'precio_parcial')::numeric - v_o.precio_salida), 4),
                   resultado = jsonb_build_object('precio_salida', v_o.precio_salida,
                                                  'motivo_cierre', v_o.motivo_cierre),
                   resuelta_en = now()
             where id = v_d.id;
            v_n := v_n + 1;

        elsif v_d.tipo = 'deterioro' then
            -- 0024: ¿qué habría hecho la posición si no se hubiera cerrado?
            -- Mismo contrafactual que la rotación. Efecto = lo que se dejó de
            -- ganar o perder, con el signo cambiado: positivo si cerrar evitó
            -- una pérdida, negativo si se perdió un objetivo.
            select * into v_a from public.activos where id = v_o.activo_id;
            v_cf := null;
            if v_a.ultimo_precio_en > v_d.creado_en then
                v_cf := case
                    when v_a.ultimo_precio >= (v_d.datos ->> 'tp')::numeric
                        then (v_d.datos ->> 'cantidad')::numeric
                             * ((v_d.datos ->> 'tp')::numeric - (v_d.datos ->> 'precio')::numeric)
                    when v_a.ultimo_precio <= (v_d.datos ->> 'sl')::numeric
                        then (v_d.datos ->> 'cantidad')::numeric
                             * ((v_d.datos ->> 'sl')::numeric - (v_d.datos ->> 'precio')::numeric)
                    when v_d.creado_en < now() - interval '7 days'
                        then (v_d.datos ->> 'cantidad')::numeric
                             * (v_a.ultimo_precio - (v_d.datos ->> 'precio')::numeric)
                end;
            end if;
            if v_cf is not null then
                update public.agente_decisiones
                   set efecto = round(-v_cf, 4),
                       resultado = jsonb_build_object('contrafactual', round(v_cf, 4)),
                       resuelta_en = now()
                 where id = v_d.id;
                v_n := v_n + 1;
            end if;

        elsif v_d.tipo = 'rotacion' then
            -- Contrafactual de la cerrada: ¿qué habría hecho después? Se
            -- fija la primera vez que el precio toca un nivel, o a los 7
            -- días al precio de ese momento (ver cabecera).
            v_cf := (v_d.resultado ->> 'contrafactual')::numeric;
            if v_cf is null then
                select * into v_a from public.activos where id = v_o.activo_id;
                if v_a.ultimo_precio_en > v_d.creado_en then
                    v_cf := case
                        when v_a.ultimo_precio >= (v_d.datos ->> 'tp')::numeric
                            then (v_d.datos ->> 'cantidad')::numeric
                                 * ((v_d.datos ->> 'tp')::numeric - (v_d.datos ->> 'precio')::numeric)
                        when v_a.ultimo_precio <= (v_d.datos ->> 'sl')::numeric
                            then (v_d.datos ->> 'cantidad')::numeric
                                 * ((v_d.datos ->> 'sl')::numeric - (v_d.datos ->> 'precio')::numeric)
                        when v_d.creado_en < now() - interval '7 days'
                            then (v_d.datos ->> 'cantidad')::numeric
                                 * (v_a.ultimo_precio - (v_d.datos ->> 'precio')::numeric)
                    end;
                end if;
                if v_cf is not null then
                    update public.agente_decisiones
                       set resultado = coalesce(resultado, '{}'::jsonb)
                                       || jsonb_build_object('contrafactual', round(v_cf, 4))
                     where id = v_d.id;
                end if;
            end if;

            -- Lo que dio la nueva. Si no llegó a abrirse, cero.
            v_pnl_b := null;
            if v_d.orden_nueva_id is null then
                v_pnl_b := 0;
            else
                select * into v_b from public.ordenes where id = v_d.orden_nueva_id;
                if v_b.estado = 'cerrada' then
                    v_pnl_b := v_b.pnl_bruto + v_b.pnl_parciales;
                end if;
            end if;

            if v_cf is not null and v_pnl_b is not null then
                update public.agente_decisiones
                   set efecto = round(v_pnl_b - v_cf, 4),
                       resultado = coalesce(resultado, '{}'::jsonb)
                                   || jsonb_build_object('pnl_nueva', v_pnl_b),
                       resuelta_en = now()
                 where id = v_d.id;
                v_n := v_n + 1;
            end if;
        end if;
    end loop;
    return v_n;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Ajuste: la de la 0023 con el parámetro salida_deterioro
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_ajustar_parametros(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_desde   timestamptz;
    v_n       int;
    v_media   numeric;
    v_nuevo   jsonb;
    v_propio  numeric;
    v_otro    numeric;
    v_n_otro  int;
    v_modo    text;
    v_cambios int := 0;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    v_p := public.fn_parametros_agente(v_ag);

    -- ── Rotación ────────────────────────────────────────────────────
    if v_p ->> 'rotacion_umbral' is not null then
        select coalesce(max(creado_en), '-infinity') into v_desde
          from public.agente_ajustes where agente_id = p_agente_id and tipo = 'rotacion';
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'rotacion' and resuelta_en > v_desde;
        if v_n >= 10 and v_media <> 0 then
            v_nuevo := to_jsonb(case when v_media < 0
                                     then least(3.0, (v_p ->> 'rotacion_umbral')::numeric + 0.2)
                                     else greatest(1.1, (v_p ->> 'rotacion_umbral')::numeric - 0.1) end);
            if v_nuevo <> v_p -> 'rotacion_umbral' then
                insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
                values (p_agente_id, 'rotacion', v_p -> 'rotacion_umbral', v_nuevo,
                        jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
                update public.agentes set estrategia = jsonb_set(estrategia, '{rotacion_umbral}', v_nuevo)
                 where id = p_agente_id;
                v_cambios := v_cambios + 1;
            end if;
        end if;
    end if;

    -- ── Toma parcial ────────────────────────────────────────────────
    select coalesce(max(creado_en), '-infinity') into v_desde
      from public.agente_ajustes where agente_id = p_agente_id and tipo = 'parcial';
    if jsonb_typeof(v_p -> 'tp_parcial') = 'object' then
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'parcial' and resuelta_en > v_desde;
        if v_n >= 10 and v_media < 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'parcial', v_p -> 'tp_parcial', 'null'::jsonb,
                    jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{tp_parcial}', 'null'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    else
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id <> p_agente_id and tipo = 'parcial' and resuelta_en > v_desde;
        if v_n >= 10 and v_media > 0 then
            v_nuevo := jsonb_build_object('recorrido', 0.5, 'fraccion', 0.5, 'mover_stop', false);
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'parcial', 'null'::jsonb, v_nuevo,
                    jsonb_build_object('decisiones_de_otros', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{tp_parcial}', v_nuevo)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    end if;

    -- ── Salida por deterioro (0024) ─────────────────────────────────
    -- Como la toma parcial: si la usa y le cuesta dinero, la apaga; si la
    -- tiene apagada y a los demás les funciona, la vuelve a encender.
    select coalesce(max(creado_en), '-infinity') into v_desde
      from public.agente_ajustes where agente_id = p_agente_id and tipo = 'deterioro';
    if coalesce((v_p ->> 'salida_deterioro')::boolean, true) then
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id = p_agente_id and tipo = 'deterioro' and resuelta_en > v_desde;
        if v_n >= 10 and v_media < 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'deterioro', 'true'::jsonb, 'false'::jsonb,
                    jsonb_build_object('decisiones', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{salida_deterioro}', 'false'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    else
        select count(*), avg(efecto) into v_n, v_media
          from public.agente_decisiones
         where agente_id <> p_agente_id and tipo = 'deterioro' and resuelta_en > v_desde;
        if v_n >= 10 and v_media > 0 then
            insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
            values (p_agente_id, 'deterioro', 'false'::jsonb, 'true'::jsonb,
                    jsonb_build_object('decisiones_de_otros', v_n, 'efecto_medio', round(v_media, 4)));
            update public.agentes set estrategia = jsonb_set(estrategia, '{salida_deterioro}', 'true'::jsonb)
             where id = p_agente_id;
            v_cambios := v_cambios + 1;
        end if;
    end if;

    -- ── Reparto: retirado en la 0023 ────────────────────────────────
    -- Ya no se elige entre «cupo» y «concentrado»: cuánto se reparte lo
    -- decide la exigencia de cada día. Las decisiones de reparto se siguen
    -- registrando y resolviendo (retorno sobre el margen) como evidencia.

    if v_cambios > 0 then
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'agente',
                v_ag.nombre || ' ajusta su estrategia con lo aprendido',
                jsonb_build_object('ajustes', v_cambios));
    end if;
    return v_cambios;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Destilación: la de la 0021 sin contar las salidas por deterioro
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.fn_destilar_practicas(p_agente_id bigint)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag    public.agentes;
    v_g     record;
    v_n     int := 0;
    v_id    bigint;
    v_nueva boolean;
    v_evita boolean;
    v_firma text;
    v_ajena public.mejores_practicas;
    v_stats jsonb;
begin
    select * into v_ag from public.agentes where id = p_agente_id;

    for v_g in
        with base as (
            select o.id, o.motivo_cierre, o.pnl_pct, s.ratio_rr,
                   a.clase, s.fuerza, s.niveles_origen,
                   case when s.atr_pct < 3 then 'bajo' when s.atr_pct < 6 then 'medio' else 'alto' end as tramo_atr,
                   case when s.ratio_rr < 1.5 then 'bajo' when s.ratio_rr < 2.5 then 'medio' else 'alto' end as tramo_rr
              from public.ordenes o
              join public.cuentas_simulacion c on c.id = o.cuenta_id
              join public.senales s on s.id = o.senal_id
              join public.activos a on a.id = o.activo_id
             where c.agente_id = p_agente_id and o.estado = 'cerrada'
               -- Una rotación la decidió el agente, no el mercado: no
               -- cuenta como acierto ni como error de la firma.
               -- 0024: tampoco una salida por deterioro; la decidió el agente.
               and o.motivo_cierre not in ('rotacion', 'deterioro')
               and s.atr_pct is not null and s.ratio_rr is not null and s.fuerza is not null
               and s.niveles_origen is not null
        ),
        grupos as (
            select clase, fuerza, niveles_origen, tramo_atr, tramo_rr,
                   count(*) as ops,
                   count(*) filter (where motivo_cierre = 'tp') as tp,
                   count(*) filter (where motivo_cierre in ('sl', 'liquidacion')) as sl,
                   round(avg(pnl_pct), 4) as pnl_medio_pct,
                   round(avg(ratio_rr), 4) as rr_medio,
                   jsonb_agg(id order by id) as ordenes
              from base
             group by clase, fuerza, niveles_origen, tramo_atr, tramo_rr
            having count(*) >= 3
        )
        select *,
               case when tp::numeric / ops >= 0.66 and pnl_medio_pct > 0 then 'exigir'
                    when sl::numeric / ops >= 0.66 and pnl_medio_pct < 0 then 'evitar' end as sentido
          from grupos
         where (tp::numeric / ops >= 0.66 and pnl_medio_pct > 0)
            or (sl::numeric / ops >= 0.66 and pnl_medio_pct < 0)
    loop
        v_evita := v_g.sentido = 'evitar';
        v_firma := case when v_evita then 'evitar|' else '' end
                   || concat_ws('|', v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr);
        v_stats := jsonb_build_object('ops', v_g.ops, 'tp', v_g.tp, 'sl', v_g.sl,
                                      'pnl_medio_pct', v_g.pnl_medio_pct, 'rr_medio', v_g.rr_medio,
                                      'ordenes', v_g.ordenes);

        -- 0021 · Si OTRO agente ya publicó esta misma firma, no se duplica:
        -- se RESPALDA. La evidencia se suma, la confianza se recalcula con
        -- las operaciones de todos, el respaldo cuenta como una valoración
        -- a favor y el agente queda como coautor. Dos agentes que llegan
        -- por su cuenta a la misma regla son la mejor evidencia de que
        -- funciona; dos filas iguales solo la dividían.
        select * into v_ajena from public.mejores_practicas
         where firma = v_firma and sentido = v_g.sentido
           and agente_autor_id <> p_agente_id
           and estado in ('propuesta', 'validada')
         order by id limit 1;
        if v_ajena.id is not null then
            perform public.fn_respaldar_practica(v_ajena.id, p_agente_id, v_stats);
            v_n := v_n + 1;
            continue;
        end if;

        insert into public.mejores_practicas
            (agente_autor_id, firma, titulo, contexto, regla, condiciones,
             resultado_observado, confianza, estado, sentido)
        values (
            p_agente_id,
            case when v_evita then 'evitar|' else '' end
                || concat_ws('|', v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr),
            case when v_evita then 'Evitar: ' else '' end
                || format('%s de fuerza %s con niveles de %s, ATR %s y R:R %s',
                          initcap(v_g.clase), v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr),
            format('%s cerró %s operaciones con esta firma: %s en objetivo, %s en stop, %s %% de media.',
                   v_ag.nombre, v_g.ops, v_g.tp, v_g.sl, v_g.pnl_medio_pct),
            case when v_evita
                 then format('En %s, NO entrar con fuerza %s, niveles de %s, ATR %s y R:R %s.',
                             v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr)
                 else format('En %s, exigir fuerza %s, niveles de %s, ATR %s y R:R %s antes de entrar.',
                             v_g.clase, v_g.fuerza, v_g.niveles_origen, v_g.tramo_atr, v_g.tramo_rr) end,
            jsonb_strip_nulls(jsonb_build_object(
                'clase', v_g.clase,
                'fuerza', jsonb_build_array(v_g.fuerza),
                'niveles_origen', v_g.niveles_origen,
                'atr_pct', case v_g.tramo_atr
                               when 'bajo'  then jsonb_build_object('max', 3)
                               when 'medio' then jsonb_build_object('min', 3, 'max', 6)
                               else jsonb_build_object('min', 6) end,
                'ratio_rr', case v_g.tramo_rr
                               when 'bajo'  then jsonb_build_object('max', 1.5)
                               when 'medio' then jsonb_build_object('min', 1.5, 'max', 2.5)
                               else jsonb_build_object('min', 2.5) end)),
            jsonb_build_object('ops', v_g.ops, 'tp', v_g.tp, 'sl', v_g.sl,
                               'pnl_medio_pct', v_g.pnl_medio_pct, 'rr_medio', v_g.rr_medio,
                               'ordenes', v_g.ordenes),
            round((case when v_evita then v_g.sl else v_g.tp end)::numeric / v_g.ops, 3),
            case when v_g.ops >= 10 then 'validada' else 'propuesta' end,
            v_g.sentido)
        on conflict (agente_autor_id, firma) do update set
            resultado_observado = excluded.resultado_observado,
            contexto = excluded.contexto,
            confianza = excluded.confianza,
            estado = case when mejores_practicas.estado in ('refutada', 'archivada')
                          then mejores_practicas.estado else excluded.estado end,
            actualizado_en = now()
        returning id, (xmax = 0) into v_id, v_nueva;

        if v_nueva then
            insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
            values (p_agente_id, 'practica',
                    v_ag.nombre || case when v_evita then ' publica un error a evitar'
                                        else ' publica una práctica' end,
                    jsonb_build_object('practica_id', v_id, 'sentido', v_g.sentido));
        end if;
        v_n := v_n + 1;
    end loop;

    update public.agentes set destilado_en = now() where id = p_agente_id;
    return v_n;
end;
$$;
