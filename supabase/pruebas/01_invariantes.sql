-- ─────────────────────────────────────────────────────────────────────
-- Invariantes del esquema de la Fase 2.
--
-- POR QUÉ ESTO EXISTE Y NO ES OPCIONAL
--
-- El tier gratuito de Supabase da dos proyectos activos. Uno lo ocupa
-- otra aplicación y el otro es producción del dashboard, así que NO HAY
-- PROYECTO DE STAGING: cada migración que se mergea llega a producción
-- sin escala intermedia.
--
-- Estas comprobaciones son la escala intermedia. Se ejecutan en cada
-- pull request sobre un PostgreSQL limpio, tras aplicar las migraciones
-- desde cero y la semilla. Si una falla, la migración no llega a master.
--
-- Se escriben con `raise exception` en vez de con pgTAP para no añadir
-- una dependencia: con `psql -v ON_ERROR_STOP=1`, una excepción devuelve
-- código de salida distinto de cero y el job se pone en rojo.
--
-- Uso:
--   psql "$URL" -v ON_ERROR_STOP=1 -f supabase/pruebas/01_invariantes.sql
-- ─────────────────────────────────────────────────────────────────────

\set ON_ERROR_STOP on

do $inv$
declare
    v_id_ibm  bigint;
    v_id_btc  bigint;
    v_rr      numeric;
    v_conteo  bigint;
    v_texto   text;
    v_json    jsonb;
    v_fallo   boolean;
begin
    raise notice '── Invariantes del esquema ──';

    -- ── 1. La semilla trae el universo de la Fase 1 ──────────────────
    select count(*) into v_conteo from public.activos where clase = 'accion';
    if v_conteo <> 21 then
        raise exception 'I1 FALLO: se esperaban 21 acciones en la semilla, hay %', v_conteo;
    end if;

    select count(*) into v_conteo from public.activos where clase = 'cripto';
    if v_conteo <> 3 then
        raise exception 'I1 FALLO: se esperaban 3 criptos en la semilla, hay %', v_conteo;
    end if;
    raise notice 'PASS  I1  la semilla trae 21 acciones y 3 criptos';

    select id into v_id_ibm from public.activos where simbolo = 'IBM';
    select id into v_id_btc from public.activos where simbolo = 'bitcoin';

    -- ── 2. El contrato rechaza operable=true sin tp ──────────────────
    -- Es la invariante que test_contrato_scan.py verifica en Python.
    -- Aquí se comprueba que la base de datos la impone también, para que
    -- NINGUNA vía de escritura pueda saltársela.
    v_fallo := false;
    begin
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
             version_motor, leverage_recomendado, sl, tp)
        values (v_id_ibm, true, 5, 3, 'prueba', 5, 100, null);
        v_fallo := true;
    exception when check_violation then
        null;  -- esperado
    end;
    if v_fallo then
        raise exception 'I2 FALLO: se aceptó una señal operable sin tp';
    end if;
    raise notice 'PASS  I2  el CHECK rechaza operable=true sin tp';

    -- ── 3. Y rechaza operable=false CON tp ───────────────────────────
    v_fallo := false;
    begin
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
             version_motor, tp)
        values (v_id_ibm, false, 5, 3, 'prueba', 120);
        v_fallo := true;
    exception when check_violation then
        null;
    end;
    if v_fallo then
        raise exception 'I3 FALLO: se aceptó una señal no operable con tp';
    end if;
    raise notice 'PASS  I3  el CHECK rechaza operable=false con tp';

    -- ── 4. ratio_rr se calcula bien ──────────────────────────────────
    insert into public.senales
        (activo_id, precio_actual, operable, leverage_tope, leverage_recomendado,
         leverage_referencia_volatilidad, sl, tp, direccion, sesgo_operativo,
         fuerza, niveles_origen, version_motor)
    values (v_id_ibm, 100, true, 5, 4, 3, 90, 130, 'alcista', 'largo',
            'alta', 'estructura', 'prueba');

    select ratio_rr into v_rr from public.senales
     where activo_id = v_id_ibm order by id desc limit 1;

    -- (130 - 100) / (100 - 90) = 3
    if v_rr is distinct from 3.0000 then
        raise exception 'I4 FALLO: ratio_rr = %, se esperaba 3.0000', v_rr;
    end if;
    raise notice 'PASS  I4  ratio_rr calcula (tp-precio)/(precio-sl)';

    -- ── 5. La fila no operable conserva los niveles técnicos ─────────
    -- Regla protegida nº2: soporte y resistencia se emiten SIEMPRE, sin
    -- rol operativo. Lo que desaparece es el par sl/tp.
    insert into public.senales
        (activo_id, precio_actual, operable, leverage_tope,
         leverage_referencia_volatilidad, soporte, resistencia, direccion,
         sesgo_operativo, fuerza, version_motor)
    values (v_id_btc, 50, false, 5, 1, 45, 55, 'bajista', 'corto', 'media', 'prueba');

    select ratio_rr into v_rr from public.senales
     where activo_id = v_id_btc order by id desc limit 1;
    if v_rr is not null then
        raise exception 'I5 FALLO: una señal sin tp/sl no debería tener ratio_rr (vale %)', v_rr;
    end if;

    select count(*) into v_conteo from public.senales
     where activo_id = v_id_btc and soporte = 45 and resistencia = 55;
    if v_conteo <> 1 then
        raise exception 'I5 FALLO: los niveles técnicos no se conservaron en la señal no operable';
    end if;
    raise notice 'PASS  I5  la señal no operable conserva soporte/resistencia y no tiene ratio_rr';

    -- ── 6. v_velas_con_rango filtra las velas reconstruidas ──────────
    -- LA INVARIANTE MÁS CARA DE PERDER: calcular el ATR sobre el frame
    -- completo inflaba el ATR de BTC un 16 % y le cambiaba el tramo de
    -- volatilidad, es decir, el apalancamiento recomendado.
    insert into public.precios_diarios
        (activo_id, fecha, cierre, maximo, minimo, rango_real, origen)
    values
        (v_id_btc, date '2026-09-18', 100, 101, 99,   true,  'coingecko_ohlc'),
        (v_id_btc, date '2026-09-17', 100, null, null, false, 'coingecko_market_chart');

    select count(*) into v_conteo from public.precios_diarios where activo_id = v_id_btc;
    if v_conteo <> 2 then
        raise exception 'I6 FALLO: se esperaban 2 velas en precios_diarios, hay %', v_conteo;
    end if;

    select count(*) into v_conteo from public.v_velas_con_rango where activo_id = v_id_btc;
    if v_conteo <> 1 then
        raise exception 'I6 FALLO: v_velas_con_rango devolvió % velas, se esperaba 1', v_conteo;
    end if;
    raise notice 'PASS  I6  v_velas_con_rango deja fuera las velas sin máximo ni mínimo reales';

    -- ── 7. senales_vigentes devuelve la última por activo ────────────
    insert into public.senales
        (activo_id, precio_actual, operable, leverage_tope,
         leverage_referencia_volatilidad, version_motor, calculado_en)
    values (v_id_btc, 999, false, 5, 1, 'la-mas-nueva', now() + interval '1 hour');

    select version_motor into v_texto from public.senales_vigentes where activo_id = v_id_btc;
    if v_texto <> 'la-mas-nueva' then
        raise exception 'I7 FALLO: senales_vigentes devolvió la versión %, se esperaba la más reciente', v_texto;
    end if;

    select count(*) into v_conteo from public.senales_vigentes where activo_id = v_id_btc;
    if v_conteo <> 1 then
        raise exception 'I7 FALLO: senales_vigentes devolvió % filas para un activo', v_conteo;
    end if;
    raise notice 'PASS  I7  senales_vigentes devuelve una sola fila, la más reciente';

    -- ── 8. RLS activada en todas las tablas ──────────────────────────
    -- Sin política, RLS activada deniega todo a anon y authenticated. Una
    -- tabla a la que se le olvide el ALTER queda legible para cualquiera
    -- con la anon key, que es pública por diseño.
    select string_agg(c.relname, ', ') into v_texto
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and not c.relrowsecurity;
    if v_texto is not null then
        raise exception 'I8 FALLO: tablas sin RLS en public -> %', v_texto;
    end if;
    raise notice 'PASS  I8  todas las tablas de public tienen RLS activada';

    -- ── 9. Las SECURITY DEFINER llevan search_path fijado ────────────
    -- Una SECURITY DEFINER sin search_path explícito es un vector de
    -- escalada de privilegios de manual: quien la llame puede anteponer
    -- un schema propio y secuestrar la resolución de nombres.
    select string_agg(p.proname, ', ') into v_texto
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and (p.proconfig is null
            or not exists (select 1 from unnest(p.proconfig) cfg
                            where cfg like 'search_path=%'));
    if v_texto is not null then
        raise exception 'I9 FALLO: SECURITY DEFINER sin search_path -> %', v_texto;
    end if;
    raise notice 'PASS  I9  toda SECURITY DEFINER fija su search_path';

    -- ── 13. Ninguna vista se salta la RLS ────────────────────────────
    -- Añadida el 2026-09-21 tras detectar en producción que las dos
    -- vistas del catálogo devolvían todas sus filas a la clave pública
    -- mientras las tablas, correctamente, no devolvían ninguna. Una vista
    -- sin security_invoker se ejecuta con los permisos de su propietario,
    -- que es el dueño de las tablas y no está sujeto a su RLS. I8 miraba
    -- solo tablas; esta mira las vistas.
    select string_agg(c.relname, ', ') into v_texto
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'v'
       and not coalesce(
             (select option_value::boolean
                from pg_options_to_table(c.reloptions)
               where option_name = 'security_invoker'), false);
    if v_texto is not null then
        raise exception 'I13 FALLO: vistas sin security_invoker (se saltan la RLS) -> %', v_texto;
    end if;
    raise notice 'PASS  I13 ninguna vista de public se salta la RLS (todas con security_invoker)';

    raise notice '── Invariantes: todas en verde ──';
end
$inv$;


-- ─────────────────────────────────────────────────────────────────────
-- 10. Retención de señales, con y sin la tabla `ordenes`.
--
-- Se hace fuera del bloque anterior porque crea y destruye una tabla, y
-- conviene que el estado quede limpio incluso si algo falla por el camino.
-- ─────────────────────────────────────────────────────────────────────
do $ret$
declare
    v_id      bigint;
    v_json    jsonb;
    v_conteo  bigint;
begin
    select id into v_id from public.activos where simbolo = 'GM';

    -- Sin `ordenes` en el esquema (estado real hasta el Sprint 5), la
    -- función tiene que funcionar igual y no intentar el anti-join.
    select public.fn_retencion_senales() into v_json;
    if (v_json ->> 'evidencia_protegida')::boolean then
        raise exception 'I10 FALLO: dice proteger evidencia sin que exista la tabla ordenes';
    end if;
    raise notice 'PASS  I10 fn_retencion_senales() funciona antes de que exista `ordenes`';

    -- Ahora con `ordenes`, simulando el Sprint 5.
    create table public.ordenes (
        id       bigserial primary key,
        senal_id bigint references public.senales(id) on delete set null
    );

    -- Tres señales del mismo día, hace 60 días: deben comprimirse a 1.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
         version_motor, calculado_en)
    select v_id, false, 5, 1, 'vieja' || g,
           now() - interval '60 days' + (g || ' minutes')::interval
      from generate_series(1, 3) g;

    -- Dos de hace 400 días: deben borrarse... salvo la referenciada.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
         version_motor, calculado_en)
    select v_id, false, 5, 1, 'antigua' || g, now() - interval '400 days'
      from generate_series(1, 2) g;

    insert into public.ordenes (senal_id)
    select min(id) from public.senales
     where activo_id = v_id and calculado_en < now() - interval '1 year';

    select public.fn_retencion_senales() into v_json;

    select count(*) into v_conteo from public.senales
     where activo_id = v_id
       and calculado_en < now() - interval '30 days'
       and calculado_en >= now() - interval '1 year';
    if v_conteo <> 1 then
        raise exception 'I11 FALLO: el tramo de 30d-1año quedó con % señales, se esperaba 1', v_conteo;
    end if;
    raise notice 'PASS  I11 el tramo de 30 días a 1 año se comprime a una señal por día';

    -- LA INVARIANTE INVIOLABLE: una señal referenciada por una orden es
    -- evidencia del experimento y no se borra jamás.
    select count(*) into v_conteo
      from public.senales s
      join public.ordenes o on o.senal_id = s.id;
    if v_conteo <> 1 then
        raise exception 'I12 FALLO: la retención borró una señal referenciada por una orden';
    end if;

    select count(*) into v_conteo from public.senales
     where activo_id = v_id and calculado_en < now() - interval '1 year';
    if v_conteo <> 1 then
        raise exception 'I12 FALLO: quedaron % señales de más de un año, se esperaba solo la protegida', v_conteo;
    end if;
    raise notice 'PASS  I12 la retención nunca borra una señal referenciada por una orden';

    drop table public.ordenes;
    raise notice '── Retención: en verde ──';
end
$ret$;
