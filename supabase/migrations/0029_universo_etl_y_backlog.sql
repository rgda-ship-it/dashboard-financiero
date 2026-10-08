-- ─────────────────────────────────────────────────────────────────────
-- 0029 — El ETL mantiene al día todo el universo de los agentes (D20,
-- 2026-10-06), y el backlog deja de pedir lo que no falta.
--
-- Las peticiones «Señales más frecuentes» y «Ampliar el universo de
-- activos» saltaban cada día para los tres agentes. Medido en producción:
--
--   · SEÑALES AÑEJAS. Dos causas, ninguna de cadencia del ETL:
--       - La apertura: el primer ETL de acciones corre a las 9:37 de Nueva
--         York y los agentes miran desde las 9:30. En los ciclos de 9:30 y
--         9:35 las 28 acciones tienen la señal del cierre anterior: 56
--         descartes «por antigüedad» cada día que no indican nada.
--       - Cuatro activos «activos» que nadie seguía (NKE, y tres tokens
--         cripto que replican acciones: tesla-dinari-tokenized-stock,
--         mcdonald-s-dinari-tokenized-stock, nike-backpack-securities). El
--         ETL solo refrescaba lo seguido, pero el universo de los agentes
--         es todo el catálogo activo (D12): los veían en cada ciclo con la
--         señal congelada desde hacía días.
--   · UNIVERSO INSUFICIENTE contaba todos los ciclos sin candidatas,
--     también los de bolsa cerrada: Prudencia (solo acciones) la cumplía
--     cada noche.
--
-- Decisión del dueño (D20): el ETL procesa TODO el catálogo activo, lo
-- siga alguien o no, sin pasar los límites de los proveedores. Para eso
-- las cuotas globales (150 activos, 20 criptos por CoinGecko) cuentan ese
-- mismo conjunto y no solo lo seguido: el universo nunca crece por encima
-- de lo que el ETL puede refrescar. (El cambio del ETL está en
-- motor-analitico/etl.py y seleccion_universo.py.)
--
-- Además:
--   1. Una acción sin la primera lectura de la sesión (9:30–9:45 NY) cuenta
--      como «fuera de sesión», no como añeja. Pasado ese margen, una señal
--      vieja vuelve a ser añeja: un ETL roto no queda escondido.
--   2. «Ampliar el universo» solo cuenta ciclos con señales frescas y sin
--      ninguna candidata (contador nuevo en agente_dias).
--   3. Una ocurrencia nueva reabre la entrada del backlog dada por
--      implementada o rechazada, conservando la resolución anterior.
--   4. Los tres tokens que replican acciones se suspenden, como la cripto
--      `spcx` en la 0028: no tienen posiciones ni seguidores, y ocuparían
--      tres de los 20 huecos de cripto. Un suspendido que nadie sigue no
--      entra en el ETL; si alguien lo vuelve a seguir, vuelve a entrar.
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- El universo del ETL, en un solo sitio
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_en_universo_etl(p_estado text, p_seguidores int)
returns boolean
language sql immutable
as $$
    select p_estado in ('activo', 'pendiente_backfill')
        or (p_estado = 'suspendido' and coalesce(p_seguidores, 0) > 0)
$$;

comment on function public.fn_en_universo_etl(text, int) is
  'Lo que el ETL procesa (D20): todo el catálogo activo o pendiente, lo siga alguien o no, y los suspendidos que alguien sigue (se reintentan). Gemelo de seleccion_universo.py; las cuotas globales cuentan este conjunto.';

comment on column public.activos.seguidores is
  'Carteras que siguen el activo. Mantenido por trigger. Desde la 0029 el ETL procesa todo el catálogo activo; seguidores solo decide si un suspendido se reintenta.';

create or replace function public.fn_verificar_cuota(p_usuario uuid, p_activo_id bigint, p_clase text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuota      record;
    v_propios    int;
    v_globales   int;
    v_cripto     int;
    v_ya_seguido boolean;
    v_es_admin   boolean;
begin
    select * into v_cuota from public.fn_cuotas();
    perform pg_advisory_xact_lock(hashtext('cuota_activos'));

    select rol = 'admin' into v_es_admin from public.perfiles where id = p_usuario;

    if not coalesce(v_es_admin, false) then
        select count(distinct ca.activo_id) into v_propios
          from public.cartera_activos ca
          join public.carteras c on c.id = ca.cartera_id
         where c.usuario_id = p_usuario;
        if v_propios >= v_cuota.por_usuario then
            raise exception 'Tu cartera ya sigue % activos y el límite es %. Quita alguno para añadir otro.',
                  v_propios, v_cuota.por_usuario
                  using errcode = 'P0001', hint = 'cuota_usuario';
        end if;
    end if;

    -- Seguir un activo que ya está en el universo del ETL no cuesta nada:
    -- ya ocupa su hueco (0029; antes, «que ya sigue otra persona»).
    select public.fn_en_universo_etl(estado, seguidores) into v_ya_seguido
      from public.activos where id = p_activo_id;
    if coalesce(v_ya_seguido, false) then
        return;
    end if;

    -- 0029: los topes cuentan lo que el ETL procesa (todo el catálogo
    -- activo), no solo lo que alguien sigue. Así el universo nunca pasa
    -- de lo que aguanta CoinGecko.
    select count(*), count(*) filter (where clase = 'cripto')
      into v_globales, v_cripto
      from public.activos where public.fn_en_universo_etl(estado, seguidores);

    if v_globales >= v_cuota.globales then
        raise exception 'El sistema ya procesa % activos distintos y el límite global es %. Puedes añadir cualquiera de los que ya están en el catálogo.',
              v_globales, v_cuota.globales
              using errcode = 'P0001', hint = 'cuota_global';
    end if;
    if p_clase = 'cripto' and v_cripto >= v_cuota.cripto then
        raise exception 'El sistema ya procesa % criptomonedas distintas y el límite es % (cuota gratuita de CoinGecko). Puedes añadir cualquiera de las que ya están en el catálogo.',
              v_cripto, v_cuota.cripto
              using errcode = 'P0001', hint = 'cuota_cripto';
    end if;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- La primera lectura de la sesión aún no ha llegado
-- ═════════════════════════════════════════════════════════════════════
-- El primer ETL de acciones lo dispara pg_cron a las 9:37 NY y tarda unos
-- minutos. 15 minutos de margen desde la apertura; pasado ese margen, una
-- señal vieja es añeja de verdad.
create function public.fn_esperando_apertura(p_momento timestamptz default now())
returns boolean
language sql stable
as $$
    select public.fn_mercado_abierto(p_momento)
       and (p_momento at time zone 'America/New_York')::time < '09:45'
$$;

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
               when p_params ->> 'atr_pct_min' is not null
                    and (s.atr_pct is null or s.atr_pct < (p_params ->> 'atr_pct_min')::numeric) then 'atr_bajo'
               when p_params ->> 'atr_pct_max' is not null
                    and (s.atr_pct is null or s.atr_pct > (p_params ->> 'atr_pct_max')::numeric) then 'atr_alto'
               when exists (select 1 from public.ordenes o
                             where o.cuenta_id = p_cuenta_id and o.activo_id = s.activo_id
                               and o.estado = 'abierta') then 'posicion_abierta'
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


-- ═════════════════════════════════════════════════════════════════════
-- Ciclos con señales frescas y ninguna candidata
-- ═════════════════════════════════════════════════════════════════════
alter table public.agente_dias
    add column ciclos_universo_sin_candidatos int not null default 0;

comment on column public.agente_dias.ciclos_universo_sin_candidatos is
  'Ciclos con señales frescas en los que ninguna pasó el filtro del agente (0029). Es lo que mide «Ampliar el universo»; ciclos_sin_candidatos cuenta también los de bolsa cerrada.';

-- Lo lleva un trigger para no copiar el ciclo entero: un ciclo suma 1 a
-- `ciclos`, y a la vez a `ciclos_con_universo` y a `ciclos_sin_candidatos`
-- si tuvo señales frescas y ninguna candidata.
create function public.fn_contar_universo_sin_candidatos()
returns trigger
language plpgsql as $$
begin
    if new.ciclos = old.ciclos + 1
       and new.ciclos_con_universo = old.ciclos_con_universo + 1
       and new.ciclos_sin_candidatos = old.ciclos_sin_candidatos + 1 then
        new.ciclos_universo_sin_candidatos := old.ciclos_universo_sin_candidatos + 1;
    end if;
    return new;
end;
$$;

create trigger agente_dias_universo_sin_candidatos
    before update of ciclos on public.agente_dias
    for each row execute function public.fn_contar_universo_sin_candidatos();

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

    -- 2. Universo insuficiente: cinco ciclos de hoy sin candidatos.
    -- 0029: solo cuentan los ciclos CON señales frescas. Con la bolsa
    -- cerrada Prudencia no tiene nada que mirar, y eso no es que falten
    -- activos.
    if coalesce(v_dia.ciclos_universo_sin_candidatos, 0) >= 5 then
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
        if exists (select 1 from public.agente_backlog
                    where id = v_id and estado in ('implementado', 'rechazado')) then
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
               actualizado_en = now()
         where id = v_id;
    end if;
    return false;
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- Datos: los tokens que replican acciones salen del universo
-- ═════════════════════════════════════════════════════════════════════
do $tokens$
declare
    v_suspendidos jsonb;
begin
    with s as (
        update public.activos a set estado = 'suspendido'
         where a.clase = 'cripto'
           and a.simbolo in ('tesla-dinari-tokenized-stock', 'mcdonald-s-dinari-tokenized-stock',
                             'nike-backpack-securities')
           and a.estado <> 'suspendido'
           and a.seguidores = 0
           and not exists (select 1 from public.ordenes o
                            where o.activo_id = a.id and o.estado = 'abierta')
        returning a.simbolo)
    select jsonb_agg(simbolo order by simbolo) into v_suspendidos from s;

    if v_suspendidos is not null then
        insert into public.eventos_sistema (tipo, mensaje, datos)
        values ('sys', 'Se suspenden tokens cripto que replican acciones',
                jsonb_build_object('activos', v_suspendidos, 'migracion', '0029'));
    end if;
end
$tokens$;

revoke execute on function public.fn_en_universo_etl(text, int)               from public, anon, authenticated;
revoke execute on function public.fn_esperando_apertura(timestamptz)          from public, anon, authenticated;
revoke execute on function public.fn_contar_universo_sin_candidatos()         from public, anon, authenticated;
