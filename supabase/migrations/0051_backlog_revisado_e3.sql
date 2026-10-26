-- ─────────────────────────────────────────────────────────────────────
-- 0051 — El backlog de los agentes, revisado en la E3 (2026-10-26; doc
-- fase-3/07).
--
-- Revisión de las 5 peticiones abiertas:
--   · 3 × «El filtro «rr» me deja sin operar» (83–86 % de los descartes de
--     la semana). Probado en el laboratorio: bajar el R:R mínimo (Prudencia
--     1,5 → 1,3/1,2/1,0; Cadencia 1,3 → 1,2/1,1/1,0; Audacia 1,2 →
--     1,1/1,0/0,8) da hasta el triple de operaciones, pero ninguna variante
--     mejora la expectativa en +0,05 R, a 5 ni a 10 años. → rechazadas.
--   · «Ampliar el universo de activos» (60 ocurrencias). Del 17 al 26-10
--     saltó casi a diario, con el 85–95 % de los descartes del perfil por
--     R:R. No faltan activos alcistas: los que hay no dan R:R. Es la misma
--     petición que la anterior, contada dos veces. → rechazada.
--   · «Señales más frecuentes» (37). Los descartes por señal añeja eran
--     masivos hasta el 09-10 y desaparecieron con la 0029 (el ETL refresca
--     todo el catálogo). Solo volvieron el 23 y 24-10, con el token de
--     GitHub caducado, que ya vigilan la 0045 y la 0050. → implementada.
--
-- Y dos cambios para que no vuelvan a abrirse por lo mismo:
--   1. «Ampliar el universo» no salta si un solo filtro explica el 80 % de
--      los descartes del perfil: eso ya lo pide «El filtro X…».
--   2. «El filtro X me deja sin operar», rechazado, no se reabre en un
--      agente con las consecuencias suspendidas (como la meta, 0044):
--      durante el experimento las reglas no cambian, y el filtro se prueba
--      en el laboratorio. Las ocurrencias y la evidencia se siguen
--      actualizando.
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.fn_registrar_backlog(
    p_agente_id bigint, p_tipo text, p_clave text, p_titulo text,
    p_descripcion text, p_justificacion text, p_evidencia jsonb, p_prioridad int)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id    bigint;
    v_hoy   date := (now() at time zone 'UTC')::date;
    v_nuevo boolean := false;
begin
    insert into public.agente_backlog
        (agente_id, tipo, titulo, descripcion, justificacion, evidencia,
         clave_deduplicacion, agentes_solicitantes, prioridad_sugerida)
    values (p_agente_id, p_tipo, p_titulo, p_descripcion, p_justificacion, p_evidencia,
            p_clave, array[p_agente_id], p_prioridad)
    on conflict (tipo, clave_deduplicacion) do nothing
    returning id into v_id;

    if v_id is not null then
        v_nuevo := true;
        insert into public.agente_backlog_ocurrencias (backlog_id, agente_id, fecha)
        values (v_id, p_agente_id, v_hoy);
        insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
        values (p_agente_id, 'backlog_nuevo',
                (select nombre from public.agentes where id = p_agente_id) || ' pide: ' || p_titulo,
                jsonb_build_object('backlog_id', v_id, 'tipo', p_tipo, 'clave', p_clave));
        return true;
    end if;

    select id into v_id from public.agente_backlog
     where tipo = p_tipo and clave_deduplicacion = p_clave;

    insert into public.agente_backlog_ocurrencias (backlog_id, agente_id, fecha)
    values (v_id, p_agente_id, v_hoy)
    on conflict do nothing;
    if found then
        -- 0029: una ocurrencia nueva reabre lo que se dio por resuelto. La
        -- resolución anterior se conserva detrás de la marca de reapertura.
        -- 0044: salvo la meta y la semana deficiente de un agente con las
        -- consecuencias semanales suspendidas (0042): se sabe y se decidió
        -- que no se alcanzan, así que no se reabren cada lunes.
        -- 0051: tampoco «El filtro X me deja sin operar»: durante el
        -- experimento las reglas no cambian, y el filtro se prueba en el
        -- laboratorio (fuente H3 de las hipótesis).
        if exists (select 1 from public.agente_backlog
                    where id = v_id and estado in ('implementado', 'rechazado'))
           and not ((p_clave like 'diagnostico:meta:%' or p_clave like 'ajuste_regla:semana_deficiente:%'
                     or p_clave like 'diagnostico:filtro:%')
                    and exists (select 1 from public.agentes
                                 where id = p_agente_id and not consecuencias_semanales)) then
            update public.agente_backlog
               set resolucion = format('Reabierta el %s por una ocurrencia nueva (%s). Antes, %s: %s',
                                       v_hoy, (select nombre from public.agentes where id = p_agente_id),
                                       estado, coalesce(resolucion, 'sin resolución')),
                   estado = 'nuevo'
             where id = v_id;
            insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
            values (p_agente_id, 'backlog_nuevo',
                    (select nombre from public.agentes where id = p_agente_id) || ' vuelve a pedir: ' || p_titulo,
                    jsonb_build_object('backlog_id', v_id, 'tipo', p_tipo, 'clave', p_clave, 'reabierta', true));
        end if;
        update public.agente_backlog
           set ocurrencias = ocurrencias + 1,
               agentes_solicitantes = case when p_agente_id = any(agentes_solicitantes)
                                           then agentes_solicitantes
                                           else agentes_solicitantes || p_agente_id end,
               evidencia = p_evidencia,
               -- 0044: la descripción es la de la última ocurrencia, como la
               -- evidencia (antes se quedaba en la primera: «W40» con
               -- evidencia de W41).
               descripcion = p_descripcion,
               actualizado_en = now()
         where id = v_id;
    end if;
    return false;
end;
$$;


create or replace function public.fn_disparadores_backlog(p_agente_id bigint, p_decision jsonb)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_cuenta  public.cuentas_simulacion;
    v_hoy     date := (now() at time zone 'UTC')::date;
    v_dia     public.agente_dias;
    v_n       int := 0;
    v_fechas  jsonb;
    v_ids     jsonb;
    v_mov     numeric;
    v_r       record;
    v_perfil  int;
    v_top     int;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    select * into v_cuenta from public.cuentas_simulacion where id = public.fn_cuenta_agente(p_agente_id);
    select * into v_dia from public.agente_dias where agente_id = p_agente_id and fecha = v_hoy;
    v_p := public.fn_parametros_agente(v_ag);

    -- 1. Sin candidatos por dirección: los tres últimos días con señales
    --    frescas, todos con cada ciclo «sin alcistas».
    select jsonb_agg(fecha order by fecha) into v_fechas
      from (select fecha, ciclos_con_universo, ciclos_sin_alcistas
              from public.agente_dias
             where agente_id = p_agente_id and ciclos_con_universo > 0
             order by fecha desc limit 3) t
    having count(*) = 3 and bool_and(ciclos_sin_alcistas = ciclos_con_universo);
    if v_fechas is not null then
        perform public.fn_registrar_backlog(p_agente_id, 'sesgo_corto', 'sesgo_corto:global',
            'Operar en corto',
            'Tres días seguidos en los que ninguna señal fresca tuvo más indicadores alcistas que bajistas.',
            'Solo-largo es la regla protegida nº2 (D6). Esta entrada mide cuánto cuesta: días enteros sin ninguna operación posible.',
            jsonb_build_object('dias', v_fechas, 'agente', v_ag.nombre), 3);
        v_n := v_n + 1;
    end if;

    -- 2. Universo insuficiente.
    -- 0029: solo cuentan los ciclos CON señales frescas. Con la bolsa
    -- cerrada Prudencia no tiene nada que mirar, y eso no es que falten
    -- activos.
    -- 0044: 24 ciclos (unas 2 horas) y, de media, al menos 3 señales
    -- descartadas por el PERFIL en cada uno (no por dirección, sesión,
    -- antigüedad, posición abierta o espera tras el stop). El sábado 17-10
    -- saltó con 5 ciclos y una sola cripto alcista descartada por R:R.
    select coalesce(sum(value::int), 0) into v_perfil
      from jsonb_each_text(coalesce(v_dia.descartes, '{}'::jsonb))
     where key not in ('direccion', 'fuera_de_sesion', 'antiguedad', 'posicion_abierta',
                       'tras_stop', 'candidata');
    -- 0051: y sin que un solo filtro explique el 80 % de esos descartes.
    -- Del 17 al 26-10 saltó casi a diario con el 85–95 % de los descartes
    -- por R:R: no faltan activos alcistas, los que hay no dan R:R, y eso
    -- ya lo pide «El filtro «rr» me deja sin operar».
    select coalesce(max(value::int), 0) into v_top
      from jsonb_each_text(coalesce(v_dia.descartes, '{}'::jsonb))
     where key not in ('direccion', 'fuera_de_sesion', 'antiguedad', 'posicion_abierta',
                       'tras_stop', 'candidata');
    if coalesce(v_dia.ciclos_universo_sin_candidatos, 0) >= 24
       and v_perfil >= 3 * v_dia.ciclos_universo_sin_candidatos
       and v_top * 100 < v_perfil * 80 then
        perform public.fn_registrar_backlog(p_agente_id, 'nuevo_activo', 'nuevo_activo:universo',
            'Ampliar el universo de activos',
            format('%s ciclos de hoy con señales frescas y ningún candidato que pase el filtro de %s.',
                   v_dia.ciclos_universo_sin_candidatos, v_ag.nombre),
            'Los descartes muestran por qué criterio cae cada señal; si ninguno encaja, faltan activos con ese perfil.',
            jsonb_build_object('fecha', v_hoy, 'ciclos_sin_candidatos', v_dia.ciclos_universo_sin_candidatos,
                               'descartes', v_dia.descartes), 2);
        v_n := v_n + 1;
    end if;

    -- 3. Tope de fase estrangulando (doc 03 §1.4): movimiento del
    --    subyacente que exige la meta con el tope de Fase 2 y el margen
    --    máximo del agente.
    if v_cuenta.fase = 'fase_2_consolidacion' then
        v_mov := v_ag.objetivo_diario_pct
                 / (public.fn_tope_fase(v_cuenta.fase)
                    * (v_p ->> 'margen_comprometido_max_pct')::numeric / 100);
        if v_mov > 3 then
            perform public.fn_registrar_backlog(p_agente_id, 'reversion_fase',
                'reversion_fase:cuenta_' || v_cuenta.id,
                'Revisar el umbral de la Fase 2',
                format('Con tope %sx y %s %% de margen, la meta de %s %% exige un %s %% diario del subyacente.',
                       public.fn_tope_fase(v_cuenta.fase), v_p ->> 'margen_comprometido_max_pct',
                       v_ag.objetivo_diario_pct, round(v_mov, 2)),
                'Volver a Fase 1 exige acción humana (regla protegida nº5). Esta entrada es el dato para decidir si la Fase 3 cambia el umbral.',
                jsonb_build_object('cuenta_id', v_cuenta.id, 'fase', v_cuenta.fase,
                                   'objetivo_diario_pct', v_ag.objetivo_diario_pct,
                                   'margen_max_pct', v_p -> 'margen_comprometido_max_pct',
                                   'movimiento_exigido_pct', round(v_mov, 2)), 4);
            v_n := v_n + 1;
        end if;
    end if;

    -- 4. Volatilidad no disponible: el mismo activo, cinco señales sin
    --    ATR en la última semana.
    for v_r in
        select a.id, a.simbolo, count(*) as n, jsonb_agg(s.id order by s.id desc) as ids
          from public.senales s join public.activos a on a.id = s.activo_id
         where s.atr_pct is null and not s.operable
           and s.calculado_en > now() - interval '7 days'
           and v_p -> 'clases_admitidas' ? a.clase
         group by a.id, a.simbolo
        having count(*) >= 5
    loop
        perform public.fn_registrar_backlog(p_agente_id, 'nuevo_dato', 'nuevo_dato:atr:' || v_r.simbolo,
            'Volatilidad de ' || v_r.simbolo,
            format('%s señales de %s sin ATR en siete días: el activo no es operable.', v_r.n, v_r.simbolo),
            'Sin volatilidad conocida no se opera (regla protegida nº4). Falta el dato, no el criterio.',
            jsonb_build_object('activo_id', v_r.id, 'simbolo', v_r.simbolo, 'senales', v_r.n,
                               'ultimas', (select jsonb_agg(value) from (
                                   select value from jsonb_array_elements(v_r.ids) limit 5) t)), 2);
        v_n := v_n + 1;
    end loop;

    -- 5. Cierre parcial: tres stops que antes tocaron el 80 % del camino al TP.
    select jsonb_agg(o.id order by o.id) into v_ids
      from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
     where c.agente_id = p_agente_id and o.motivo_cierre in ('sl', 'liquidacion')
       and o.precio_max_visto >= o.precio_entrada + 0.8 * (o.tp - o.precio_entrada)
    having count(*) >= 3;
    if v_ids is not null then
        perform public.fn_registrar_backlog(p_agente_id, 'nueva_herramienta',
            'nueva_herramienta:cierre_parcial', 'Cierre parcial',
            format('%s operaciones llegaron al 80 %% del recorrido hasta el objetivo y acabaron en el stop.',
                   jsonb_array_length(v_ids)),
            'Con cierre parcial, parte de ese recorrido habría quedado asegurado.',
            jsonb_build_object('ordenes', v_ids), 3);
        v_n := v_n + 1;
    end if;

    -- 6. Trailing stop: tres cierres en TP tras los que el precio subió
    --    más de un 2 % en las 24 h siguientes.
    select jsonb_agg(o.id order by o.id) into v_ids
      from public.ordenes o join public.cuentas_simulacion c on c.id = o.cuenta_id
     where c.agente_id = p_agente_id and o.motivo_cierre = 'tp'
       and o.precio_max_post_cierre > o.tp * 1.02
    having count(*) >= 3;
    if v_ids is not null then
        perform public.fn_registrar_backlog(p_agente_id, 'nueva_herramienta',
            'nueva_herramienta:trailing_stop', 'Trailing stop',
            format('%s cierres en objetivo tras los que el precio siguió subiendo más de un 2 %%.',
                   jsonb_array_length(v_ids)),
            'Un stop que sigue al precio habría capturado parte de esa subida.',
            jsonb_build_object('ordenes', v_ids), 3);
        v_n := v_n + 1;
    end if;

    -- 7. Señal añeja: diez descartes hoy por antigüedad, con mercado abierto.
    if coalesce((v_dia.descartes ->> 'antiguedad')::int, 0) >= 10 then
        perform public.fn_registrar_backlog(p_agente_id, 'ajuste_regla', 'ajuste_regla:cadencia_etl',
            'Señales más frecuentes',
            format('%s descartes hoy por señales de más de %s minutos con el mercado abierto.',
                   v_dia.descartes ->> 'antiguedad', v_p ->> 'antiguedad_senal_max_min'),
            'La cadencia del ETL limita lo que el agente puede operar.',
            jsonb_build_object('fecha', v_hoy, 'descartes_antiguedad', v_dia.descartes -> 'antiguedad',
                               'antiguedad_max_min', v_p -> 'antiguedad_senal_max_min'), 2);
        v_n := v_n + 1;
    end if;

    return v_n;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- Cierre de las peticiones revisadas
-- ═════════════════════════════════════════════════════════════════════
update public.agente_backlog
   set estado = 'rechazado',
       resolucion = 'Probado en el laboratorio (doc fase-3/07, 45 activos, 5 y 10 años): bajar el R:R mínimo da '
                 || 'hasta el triple de operaciones, pero ninguna variante mejora la expectativa en +0,05 R ni supera '
                 || 'al 90 % de las tiradas al azar. Las operaciones que deja pasar valen unos 0 R. El R:R es además lo '
                 || 'que os hace comprar retrocesos (doc fase-3/05). Revisado el 2026-10-26 (0051).',
       revisado_en = now(), actualizado_en = now()
 where clave_deduplicacion like 'diagnostico:filtro:rr:%'
   and estado in ('nuevo', 'en_revision');

update public.agente_backlog
   set estado = 'rechazado',
       resolucion = 'No faltan activos (0051): del 17 al 26-10, el 85–95 % de los descartes del perfil fueron por '
                 || 'R:R, que ya pide «El filtro «rr» me deja sin operar» y se probó sin mejora. Ampliar el universo '
                 || 'cripto sigue en espera por el sesgo de supervivencia. El disparador ya no salta si un solo filtro '
                 || 'explica el 80 % de los descartes. ' || coalesce('Antes: ' || resolucion, ''),
       revisado_en = now(), actualizado_en = now()
 where clave_deduplicacion = 'nuevo_activo:universo'
   and estado in ('nuevo', 'en_revision');

update public.agente_backlog
   set estado = 'implementado',
       resolucion = 'Resuelto en la 0029 (2026-10-06): el ETL refresca todo el catálogo activo, y desde el 10-10 no '
                 || 'hay descartes por señal añeja salvo con el ETL caído (23 y 24-10, token de GitHub caducado), que '
                 || 'ahora vigilan la 0045 y la 0050. Si vuelve a saltar, lo primero es mirar «Salud del sistema». '
                 || 'Revisado el 2026-10-26 (0051).',
       revisado_en = now(), actualizado_en = now()
 where clave_deduplicacion = 'ajuste_regla:cadencia_etl'
   and estado in ('nuevo', 'en_revision');
