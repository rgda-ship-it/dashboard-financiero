-- ─────────────────────────────────────────────────────────────────────
-- 0062 — Agentes de cartera: la vara viva y la tendencia sobre clases
-- (doc fase-4/00 §6, decisión del dueño del 2026-11-11).
--
-- Tras 38 ideas de entrada sin ventaja, la pregunta pasa de «cuándo
-- entro» a «cuánta cartera llevo». Dos agentes nuevos, de un tipo nuevo
-- (`tipo = 'cartera'`), cada uno con su cuenta de 500 $:
--
--   · «Cartera sin tocar»: compra cinco clases de activo a partes iguales
--     (SPY, EFA, IEF, VNQ y DBC) y no hace nada más. No es una estrategia
--     que haya que demostrar: es la vara, con el mismo spread y la misma
--     cuenta que los demás.
--   · «Cartera con tendencia»: la misma cartera, pero cada clase solo
--     está comprada si cerró el mes anterior sobre su media de 10 cierres
--     mensuales (`tendencia_clases` del laboratorio). No pasó el criterio
--     frente al azar (percentil 91, se exigía el 98): es experimental, y
--     se juzga contra la otra.
--
-- Deciden una vez al mes, en la primera sesión con precio fresco de los
-- cinco, y los dos a la vez. Hasta que el dueño dé de alta los cinco ETF
-- no hacen nada.
--
-- Los cinco ETF son SOLO de las carteras (`activos.solo_cartera`): los
-- demás agentes no los ven y no entran en la vara del universo. Si no, el
-- alta cambiaría el universo del grupo de control.
--
-- El grupo de control, las v2 y Tendencia cripto no cambian: sus bucles
-- recorren `tipo = 'metas'` y `tipo = 'estrategia'`.
--
-- Lo que el simulador NO hace y el laboratorio sí: pagar dividendos (el
-- laboratorio usa precios ajustados) y reequilibrar cada mes la cartera
-- sin tocar. La vara viva mide solo precio y deja correr los pesos.
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- 1. Tipo de agente
-- ═════════════════════════════════════════════════════════════════════
alter table public.agentes drop constraint agentes_tipo_check;
alter table public.agentes add constraint agentes_tipo_check
    check (tipo in ('metas', 'estrategia', 'cartera'));

comment on column public.agentes.tipo is
  'metas: persigue una meta diaria (grupo de control y v2). estrategia: una regla validada en el laboratorio, sin meta (0037). cartera: lleva clases de activo enteras y decide una vez al mes cuánta (0062).';


-- ═════════════════════════════════════════════════════════════════════
-- 2. Las clases de activo, solo para las carteras
-- ═════════════════════════════════════════════════════════════════════
alter table public.activos
    add column solo_cartera boolean
    generated always as (simbolo in ('SPY', 'EFA', 'IEF', 'VNQ', 'DBC')) stored;

comment on column public.activos.solo_cartera is
  'ETF de una clase de activo entera (0062): lo llevan los agentes de cartera. Los demás agentes no lo ven y no cuenta en la vara del universo.';

create or replace view public.senales_vigentes
with (security_invoker = true) as
    select s.*,
           a.simbolo,
           a.clase,
           a.nombre,
           case when a.referencia then 'referencia'
                when a.solo_cartera and a.estado = 'activo' then 'cartera'
                else a.estado end as estado_activo
      from public.activos a
      cross join lateral (
            select *
              from public.senales s1
             where s1.activo_id = a.id
             order by s1.calculado_en desc
             limit 1
      ) s;

comment on view public.senales_vigentes is
  'Última señal de cada activo. LATERAL + LIMIT 1 sobre senales_activo_fecha_idx: una lectura de índice por activo (0006, H-08). Los índices salen con estado_activo = referencia (0058) y las clases de activo de las carteras, con cartera (0062): el universo de los agentes pide activo.';

-- Una orden sobre una clase de activo solo la abre una cuenta de cartera.
create function public.fn_ordenes_clases_solo_carteras()
returns trigger
language plpgsql
as $$
begin
    if exists (select 1 from public.activos where id = new.activo_id and solo_cartera)
       and not exists (select 1 from public.cuentas_simulacion c
                         join public.agentes g on g.id = c.agente_id
                        where c.id = new.cuenta_id and g.tipo = 'cartera') then
        raise exception 'El activo % es una clase de activo de las carteras: no se opera desde otra cuenta (0062)',
              new.activo_id using errcode = 'P0001';
    end if;
    return new;
end
$$;

revoke execute on function public.fn_ordenes_clases_solo_carteras() from public, anon, authenticated;

create trigger ordenes_clases_solo_carteras
    before insert on public.ordenes
    for each row execute function public.fn_ordenes_clases_solo_carteras();

-- La vara del universo y la de acciones, sin las clases de activo; estas
-- tienen la suya (clases), sin costes.
create or replace view public.v_referencia_mercado
with (security_invoker = true) as
with ventanas as (
    select 'alta'::text as ventana, min(creado_en)::date as desde
      from public.agentes where tipo = 'metas'
    union all
    select 'experimento', min(creado_en)::date
      from public.agentes where tipo = 'estrategia'
), grupos as (
    select a.id as activo_id, g.referencia
      from public.activos a
      cross join lateral (values (case when not a.referencia and not a.solo_cartera then 'universo' end),
                                 (case when a.referencia or a.solo_cartera then null
                                       when a.clase = 'accion' then 'acciones' else 'cripto' end),
                                 (case when a.solo_cartera then 'clases' end),
                                 (case when a.simbolo = 'bitcoin' then 'bitcoin' end),
                                 (case a.simbolo when '^GSPC' then 'sp500' when '^NDX' then 'nasdaq100' end))
                   g(referencia)
     where a.estado = 'activo' and g.referencia is not null
), extremos as (
    select v.ventana, v.desde, gr.referencia, ini.cierre as c0, fin.fecha as f1, fin.cierre as c1
      from ventanas v
      cross join grupos gr
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = gr.activo_id and p.fecha >= v.desde
                     order by p.fecha limit 1) ini on true
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = gr.activo_id
                     order by p.fecha desc limit 1) fin on true
     where v.desde is not null and ini.fecha <= v.desde + 4 and ini.cierre > 0
)
select referencia, ventana, desde, max(f1) as hasta, count(*) as activos,
       round(avg(c1 / c0 - 1) * 100, 2) as rentabilidad_pct
  from extremos
 group by referencia, ventana, desde;

comment on view public.v_referencia_mercado is
  'Comprar y mantener a partes iguales (todo, acciones, cripto y bitcoin), sin apalancamiento ni costes, desde el alta de los agentes con metas y desde el experimento (0056). Los índices (0058) y las clases de activo de las carteras (0062) no entran en el universo: son varas propias (sp500, nasdaq100 y clases).';

-- ═════════════════════════════════════════════════════════════════════
-- 3. G6 no aplica a una cartera
-- ═════════════════════════════════════════════════════════════════════
-- G6 limita el riesgo abierto, medido hasta el stop. Una cartera no tiene
-- stop: su límite es que compra a 1× y por pesos. Sin esto, G6 la
-- bloquearía entera.
create or replace function public.fn_g6_riesgo_abierto()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_equity  numeric;
    v_max     numeric;
    v_abierto numeric;
    v_nuevo   numeric;
begin
    select a.* into v_ag
      from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id
     where c.id = new.cuenta_id;
    if not found then
        return new;      -- cuentas de usuario: no aplica
    end if;
    if v_ag.tipo = 'cartera' then
        return new;      -- 0062: sin stop, a 1× y por pesos
    end if;

    v_equity  := public.fn_equity(new.cuenta_id);
    v_max     := v_equity * (public.fn_parametros_agente(v_ag) ->> 'riesgo_pct_operacion')::numeric
                 * public.fn_multiplo_riesgo_abierto() / 100;
    v_abierto := public.fn_riesgo_abierto(new.cuenta_id);
    v_nuevo   := greatest(new.cantidad * (new.precio_entrada - new.sl), 0);

    if v_abierto + v_nuevo > v_max + 0.01 then
        raise exception 'G6: con esta orden el riesgo abierto sería % $, por encima de % $ (% × el riesgo por operación).',
              round(v_abierto + v_nuevo, 2), round(v_max, 2), public.fn_multiplo_riesgo_abierto()
              using errcode = 'P0001';
    end if;
    return new;
end;
$$;

revoke execute on function public.fn_g6_riesgo_abierto() from public, anon, authenticated;


-- ═════════════════════════════════════════════════════════════════════
-- 4. Abrir por peso, sin stop ni objetivo
-- ═════════════════════════════════════════════════════════════════════
-- Compra `p_peso_pct` del equity, a 1×, como mucho lo que haya libre. El
-- esquema pide un stop positivo: se pone uno simbólico al 1 % del precio,
-- que no es una regla de salida (una clase de activo no cae un 99 %).
create function public.fn_abrir_orden_cartera(
    p_cuenta_id bigint, p_activo_id bigint, p_peso_pct numeric, p_racional jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuenta   public.cuentas_simulacion;
    v_a        public.activos;
    v_precio   numeric;
    v_equity   numeric;
    v_importe  numeric;
    v_cantidad numeric;
    v_margen   numeric;
    v_sl       numeric;
    v_orden    bigint;
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found or v_cuenta.agente_id is null then
        raise exception 'La cuenta % no es de un agente.', p_cuenta_id using errcode = '42501';
    end if;
    if v_cuenta.estado <> 'activa' then
        raise exception 'La cuenta está en estado «%»: no admite operaciones nuevas.', v_cuenta.estado
              using errcode = 'P0001';
    end if;
    if p_peso_pct is null or p_peso_pct <= 0 or p_peso_pct > 100 then
        raise exception 'El peso debe estar entre 0 y 100 %%. Recibido: %', p_peso_pct using errcode = 'P0001';
    end if;

    select * into v_a from public.activos where id = p_activo_id;
    if not found or v_a.estado <> 'activo' then
        raise exception 'El activo % no está activo.', coalesce(v_a.simbolo, p_activo_id::text) using errcode = 'P0001';
    end if;
    if v_a.ultimo_precio is null
       or v_a.ultimo_precio_en < now() - make_interval(mins => public.fn_frescura_precio_min(v_a.clase)) then
        raise exception 'El precio de % no es fresco.', v_a.simbolo using errcode = 'P0001';
    end if;
    if exists (select 1 from public.ordenes
                where cuenta_id = p_cuenta_id and activo_id = p_activo_id and estado = 'abierta') then
        raise exception 'Ya tienes una posición abierta en %.', v_a.simbolo using errcode = 'P0001';
    end if;

    v_precio   := public.fn_precio_compra(p_activo_id, v_a.ultimo_precio);
    v_equity   := public.fn_equity(p_cuenta_id);
    v_importe  := least(v_equity * p_peso_pct / 100, v_cuenta.saldo_disponible - 0.01);
    v_cantidad := trunc(greatest(v_importe, 0) / v_precio, 8);
    v_margen   := ceil(v_cantidad * v_precio * 100) / 100;
    if v_cantidad <= 0 or v_margen < 10 then
        raise exception 'Posición de % $ en %: por debajo del mínimo de 10 $.', v_margen, v_a.simbolo
              using errcode = 'P0001';
    end if;
    v_sl := round(v_precio * 0.01, 8);

    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, sl_original, precio_liquidacion, racional)
    values (p_cuenta_id, p_activo_id, null, 'agente', v_precio, now(),
            v_cantidad, 1, v_margen, null, v_sl, v_sl, 0, p_racional)
    returning id into v_orden;

    perform public.fn_registrar_movimiento(p_cuenta_id, v_orden, 'bloqueo_margen', -v_margen, v_margen);

    return jsonb_build_object('orden_id', v_orden, 'simbolo', v_a.simbolo, 'cantidad', v_cantidad,
                              'precio_entrada', v_precio, 'margen', v_margen,
                              'peso_pct', round(v_margen * 100 / v_equity, 2));
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 5. Cierres mensuales
-- ═════════════════════════════════════════════════════════════════════
-- El último cierre de cada mes anterior a `p_mes` (primer día del mes en
-- curso) y la media de los `p_n` últimos, incluido el más reciente: la
-- misma cuenta que `laboratorio/asignacion.py`.
create function public.fn_cierres_mensuales(p_activo_id bigint, p_mes date, p_n int)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
    with meses as (
        select distinct on (date_trunc('month', fecha))
               date_trunc('month', fecha)::date as mes, fecha, cierre
          from public.precios_diarios
         where activo_id = p_activo_id and fecha < p_mes
         order by date_trunc('month', fecha), fecha desc
    ), ultimos as (
        select * from meses order by mes desc limit p_n
    )
    select jsonb_build_object(
               'fecha', max(fecha),
               'ultimo_mes', max(mes),
               'meses', count(*),
               'cierre', (select cierre from ultimos order by mes desc limit 1),
               'media', round(avg(cierre), 8))
      from ultimos
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 6. La decisión del mes
-- ═════════════════════════════════════════════════════════════════════
-- Una vez por mes y agente, con los cierres del mes anterior. No decide
-- nada hasta que los cinco activos están activos, con sus meses de
-- historia y con precio fresco: así las dos carteras entran el mismo día
-- y con todo a la vez. Primero vende lo que toca; luego compra.
create function public.fn_decidir_cartera(p_agente_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag      public.agentes;
    v_p       jsonb;
    v_cuenta  bigint;
    v_go      jsonb;
    v_mes     date := date_trunc('month', now() at time zone 'UTC')::date;
    v_n       int;
    v_peso    numeric;
    v_simbolo text;
    v_a       public.activos;
    v_ind     jsonb;
    v_o       public.ordenes;
    v_plan    jsonb := '[]'::jsonb;
    v_c       jsonb;
    v_r       jsonb;
    v_dentro  boolean;
    v_falta   text[] := '{}';
    v_acciones jsonb;
begin
    select * into v_ag from public.agentes where id = p_agente_id for update;
    if not found or v_ag.tipo <> 'cartera' then
        raise exception 'El agente % no es de cartera.', p_agente_id using errcode = '22023';
    end if;
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    if v_cuenta is null then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'sin_cuenta');
    end if;
    v_go := public.rpc_evaluar_game_over(v_cuenta);
    if v_go ->> 'estado' = 'game_over' then
        if v_ag.estado <> 'game_over' then
            update public.agentes set estado = 'game_over', estado_previo = null, game_over_en = now()
             where id = p_agente_id;
        end if;
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'game_over');
    end if;
    if v_ag.estado <> 'activo' then
        return jsonb_build_object('agente', v_ag.nombre, 'accion', 'agente_' || v_ag.estado);
    end if;

    v_p := v_ag.estrategia;
    if v_p ->> 'regla' not in ('mantener', 'tendencia_mensual') then
        raise exception 'Regla de cartera desconocida: %', v_p ->> 'regla' using errcode = '22023';
    end if;
    v_n    := coalesce((v_p ->> 'media_meses')::int, 10);
    v_peso := (v_p ->> 'peso_pct')::numeric;

    -- Una decisión por mes: la clave es la vela del último día del mes anterior.
    if exists (select 1 from public.agente_decisiones_diarias
                where agente_id = p_agente_id
                  and fecha_vela >= (v_mes - interval '1 month')::date and fecha_vela < v_mes) then
        return jsonb_build_object('agente', v_ag.nombre, 'mes', v_mes, 'accion', 'ya_decidido');
    end if;

    -- ── Todo listo, o nada ────────────────────────────────────────────
    for v_simbolo in select jsonb_array_elements_text(v_p -> 'activos')
    loop
        select * into v_a from public.activos where simbolo = v_simbolo and estado = 'activo';
        if not found then
            v_falta := v_falta || (v_simbolo || ': sin alta');
            continue;
        end if;
        v_ind := public.fn_cierres_mensuales(v_a.id, v_mes, v_n);
        if coalesce((v_ind ->> 'meses')::int, 0) < v_n
           or (v_ind ->> 'ultimo_mes')::date <> (v_mes - interval '1 month')::date then
            v_falta := v_falta || (v_simbolo || ': sin meses');
            continue;
        end if;
        if v_a.ultimo_precio is null
           or v_a.ultimo_precio_en < now() - make_interval(mins => public.fn_frescura_precio_min(v_a.clase)) then
            v_falta := v_falta || (v_simbolo || ': sin precio');
            continue;
        end if;
        select * into v_o from public.ordenes
         where cuenta_id = v_cuenta and activo_id = v_a.id and estado = 'abierta';
        v_dentro := v_p ->> 'regla' = 'mantener'
                    or (v_ind ->> 'cierre')::numeric > (v_ind ->> 'media')::numeric;
        v_plan := v_plan || jsonb_build_object(
            'activo_id', v_a.id, 'simbolo', v_a.simbolo, 'precio', v_a.ultimo_precio,
            'fecha_vela', v_ind ->> 'fecha', 'indicadores', v_ind,
            'orden_id', v_o.id, 'dentro', v_dentro,
            'paso', case when v_o.id is not null and not v_dentro then 'salir'
                         when v_o.id is not null then 'mantener'
                         when v_dentro then 'entrar' else 'fuera' end);
    end loop;
    if array_length(v_falta, 1) > 0 then
        return jsonb_build_object('agente', v_ag.nombre, 'mes', v_mes, 'accion', 'esperando', 'falta', v_falta);
    end if;

    -- ── Vender, mantener y quedarse fuera ─────────────────────────────
    for v_c in select c from jsonb_array_elements(v_plan) c where c ->> 'paso' <> 'entrar'
    loop
        if v_c ->> 'paso' = 'salir' then
            v_r := public.rpc_cerrar_orden((v_c ->> 'orden_id')::bigint, (v_c ->> 'precio')::numeric, 'regla',
                                           (v_c ->> 'precio')::numeric);
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
            values (p_agente_id, (v_c ->> 'activo_id')::bigint, (v_c ->> 'fecha_vela')::date, 'salir_regla',
                    (v_c ->> 'orden_id')::bigint, (v_c -> 'indicadores') || jsonb_build_object('cierre_orden', v_r));
        else
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
            values (p_agente_id, (v_c ->> 'activo_id')::bigint, (v_c ->> 'fecha_vela')::date,
                    case v_c ->> 'paso' when 'mantener' then 'mantener' else 'sin_senal' end,
                    (v_c ->> 'orden_id')::bigint, v_c -> 'indicadores');
        end if;
    end loop;

    -- ── Comprar ───────────────────────────────────────────────────────
    for v_c in select c from jsonb_array_elements(v_plan) c where c ->> 'paso' = 'entrar' order by c ->> 'simbolo'
    loop
        begin
            v_r := public.fn_abrir_orden_cartera(
                v_cuenta, (v_c ->> 'activo_id')::bigint, v_peso,
                jsonb_build_object('regla', v_p ->> 'regla', 'version_estrategia', v_ag.version_estrategia,
                                   'mes', v_mes, 'peso_pct', v_peso, 'indicadores', v_c -> 'indicadores',
                                   'equity', public.fn_equity(v_cuenta)));
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, orden_id, datos)
            values (p_agente_id, (v_c ->> 'activo_id')::bigint, (v_c ->> 'fecha_vela')::date, 'entrar',
                    (v_r ->> 'orden_id')::bigint, (v_c -> 'indicadores') || jsonb_build_object('orden', v_r));
        exception when others then
            insert into public.agente_decisiones_diarias (agente_id, activo_id, fecha_vela, accion, datos)
            values (p_agente_id, (v_c ->> 'activo_id')::bigint, (v_c ->> 'fecha_vela')::date, 'descartada',
                    (v_c -> 'indicadores') || jsonb_build_object('motivo', sqlerrm));
        end;
    end loop;

    select coalesce(jsonb_object_agg(accion, n), '{}'::jsonb) into v_acciones
      from (select accion, count(*) as n from public.agente_decisiones_diarias
             where agente_id = p_agente_id
               and fecha_vela >= (v_mes - interval '1 month')::date and fecha_vela < v_mes
             group by accion) s;
    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'agente', v_ag.nombre || ': decisión del mes', jsonb_build_object('mes', v_mes, 'acciones', v_acciones));
    return jsonb_build_object('agente', v_ag.nombre, 'mes', v_mes, 'acciones', v_acciones);
end;
$$;


-- ═════════════════════════════════════════════════════════════════════
-- 7. Ciclo y pausa por caída
-- ═════════════════════════════════════════════════════════════════════
-- La cartera con tendencia se pausa sola si cae más de `caida_max_pct`
-- desde su máximo (25 %: el doble de su peor caída en 20 años de
-- laboratorio). La cartera sin tocar no tiene tope: es la vara, y tiene
-- que mostrar lo que cae el mercado.
create function public.fn_ciclo_carteras()
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
    for v_ag in select g.id, g.nombre, g.estado, (g.estrategia ->> 'caida_max_pct')::numeric as caida_max,
                       ce.drawdown_pct
                  from public.agentes g
                  left join public.v_cuentas_equity ce on ce.id = public.fn_cuenta_agente(g.id)
                 where g.tipo = 'cartera' order by g.id
    loop
        begin
            if v_ag.caida_max is not null and v_ag.estado = 'activo'
               and coalesce(v_ag.drawdown_pct, 0) <= -v_ag.caida_max then
                update public.agentes set estado = 'pausado', estado_previo = 'activo' where id = v_ag.id;
                insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
                values (v_ag.id, 'agente',
                        format('%s queda en pausa: la caída desde el máximo pasó del %s %%', v_ag.nombre, v_ag.caida_max),
                        jsonb_build_object('criterio', 'caida', 'drawdown_pct', v_ag.drawdown_pct));
            end if;
            v_out := v_out || public.fn_decidir_cartera(v_ag.id);
        exception when others then
            get stacked diagnostics v_err = message_text, v_cod = returned_sqlstate, v_ctx = pg_exception_context;
            v_out := v_out || jsonb_build_object('agente_id', v_ag.id, 'error', v_err);
            perform public.fn_registrar_fallo(v_ag.id, 'decisión mensual', v_err, v_cod, v_ctx);
        end;
    end loop;
    return v_out;
end;
$$;

revoke execute on function public.fn_abrir_orden_cartera(bigint, bigint, numeric, jsonb) from public, anon, authenticated;
revoke execute on function public.fn_cierres_mensuales(bigint, date, int)                from public, anon, authenticated;
revoke execute on function public.fn_decidir_cartera(bigint)                             from public, anon, authenticated;
revoke execute on function public.fn_ciclo_carteras()                                    from public, anon, authenticated;


-- ═════════════════════════════════════════════════════════════════════
-- 8. Los dos agentes
-- ═════════════════════════════════════════════════════════════════════
-- Nacen activos: no hacen nada hasta que existen los cinco ETF. Las
-- claves de abajo de `activos` son las que lee fn_parametros_agente para
-- sincronizar la cuenta.
insert into public.agentes (nombre, tipo, objetivo_diario_pct, saldo_inicial, estado, estrategia)
values
    ('Cartera sin tocar', 'cartera', null, 500, 'activo',
     jsonb_build_object(
         'regla', 'mantener',
         'activos', jsonb_build_array('SPY', 'EFA', 'IEF', 'VNQ', 'DBC'),
         'peso_pct', 20,
         'clases_admitidas', jsonb_build_array('accion'),
         'riesgo_pct_operacion', 1.0, 'max_posiciones_abiertas', 5, 'rr_minimo', 1.0,
         'apalancamiento_maximo_propio', 1.0, 'salida_deterioro', false)),
    ('Cartera con tendencia', 'cartera', null, 500, 'activo',
     jsonb_build_object(
         'regla', 'tendencia_mensual',
         'activos', jsonb_build_array('SPY', 'EFA', 'IEF', 'VNQ', 'DBC'),
         'peso_pct', 20, 'media_meses', 10, 'caida_max_pct', 25,
         'clases_admitidas', jsonb_build_array('accion'),
         'riesgo_pct_operacion', 1.0, 'max_posiciones_abiertas', 5, 'rr_minimo', 1.0,
         'apalancamiento_maximo_propio', 1.0, 'salida_deterioro', false));

select public.fn_crear_cuenta_agente(id) from public.agentes where tipo = 'cartera';

insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
select id, 'agente', nombre || ' creado (0062): espera a que existan SPY, EFA, IEF, VNQ y DBC',
       jsonb_build_object('regla', estrategia ->> 'regla')
  from public.agentes where tipo = 'cartera';

-- Días 1 a 7 de cada mes, cada hora de 14:50 a 20:50 UTC (la bolsa de
-- Nueva York abierta en horario de invierno y de verano). Decide en la
-- primera pasada con los cinco precios frescos; las demás no hacen nada.
do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('decision-carteras', '50 14-20 1-7 * *',
                                        'select public.fn_ciclo_carteras()')$q$;
        raise notice 'decision-carteras programado los días 1 a 7, de 14:50 a 20:50 UTC';
    else
        raise notice 'pg_cron no disponible: la decisión mensual no queda programada (esperado en la CI)';
    end if;
end
$cron$;
