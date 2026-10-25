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

-- Agentes de banco de pruebas. Desde la 0013 `cuentas_simulacion.agente_id`
-- tiene clave ajena, así que las cuentas de agente que este fichero crea a
-- mano necesitan un agente de verdad. En pausa y sin cuenta propia: el
-- ciclo de agentes los ve pero no opera con ellos.
insert into public.agentes (id, nombre, objetivo_diario_pct, estrategia)
select g, 'prueba-' || g, 2, '{}'::jsonb
  from unnest(array[9001, 9101, 9102, 9103]) g
on conflict do nothing;

-- Desde la 0034 se compra y se vende con spread. Las invariantes escritas
-- antes razonan con un único precio (y usan «bitcoin» a 100 $, donde su
-- spread de 5 $ sería un 5 %), así que corren sin spread: se guardan los
-- valores de la migración y se ponen a cero. I83, al final, los restaura y
-- prueba el spread.
create temp table spreads_0034 as
    select 'mercado' as tipo, clave as id, spread_abs, spread_pct from public.mercados
    union all
    select 'activo', simbolo, spread_abs, spread_pct from public.activos
     where spread_abs is not null or spread_pct is not null;
update public.mercados set spread_abs = 0, spread_pct = 0;
update public.activos set spread_abs = null, spread_pct = null
 where spread_abs is not null or spread_pct is not null;

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

    -- La 0032 añade seis criptos líquidas al catálogo: no son de la semilla.
    select count(*) into v_conteo from public.activos
     where clase = 'cripto'
       and simbolo not in ('litecoin', 'chainlink', 'avalanche-2', 'polkadot', 'tron', 'bitcoin-cash');
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

    -- ── 14. Ninguna política concede nada a `anon` ───────────────────
    -- Forma final (H-14, Sprint 3). Hasta 0007 existían cuatro políticas
    -- temporales de lectura pública del mercado (0005); aquí se exige que
    -- no quede ninguna, ni ninguna política `to public` — PUBLIC incluye
    -- a `anon`, así que olvidar el `to authenticated` abre la tabla.
    select string_agg(distinct tablename || '.' || policyname, ', ') into v_texto
      from pg_policies
     where schemaname = 'public'
       and ('anon' = any(roles) or 'public' = any(roles));
    if v_texto is not null then
        raise exception 'I14 FALLO: política accesible sin iniciar sesión -> %', v_texto;
    end if;
    raise notice 'PASS  I14 ninguna política concede nada a anon ni a public';

    raise notice '── Invariantes: todas en verde ──';
end
$inv$;


-- ─────────────────────────────────────────────────────────────────────
-- 10. Retención de señales y la evidencia del experimento.
--
-- Hasta el Sprint 5 este bloque creaba una tabla `ordenes` de juguete
-- para probar el anti-join, porque la de verdad no existía. Desde la
-- migración 0011 existe, así que se prueba contra ella: una señal
-- referenciada por una orden REAL —con su cuenta, su margen y sus
-- niveles— es evidencia y no se borra jamás.
--
-- Se hace fuera del bloque anterior porque deja filas por el camino y
-- conviene que un fallo aquí no arrastre al resto.
-- ─────────────────────────────────────────────────────────────────────
do $ret$
declare
    v_id       bigint;
    v_json     jsonb;
    v_conteo   bigint;
    v_cuenta   bigint;
    v_protegida bigint;
begin
    select id into v_id from public.activos where simbolo = 'GM';

    -- Con `ordenes` en el esquema, la función tiene que activar el
    -- anti-join y decirlo en su informe.
    select public.fn_retencion_senales() into v_json;
    if not (v_json ->> 'evidencia_protegida')::boolean then
        raise exception 'I10 FALLO: existiendo la tabla ordenes, la retención no protege la evidencia';
    end if;
    raise notice 'PASS  I10 fn_retencion_senales() activa el anti-join cuando existe `ordenes`';

    -- Tres señales del MISMO día, hace 60 días: deben comprimirse a 1.
    --
    -- Ancladas al mediodía y no a `now() - 60 días + g minutos`, que es
    -- como estaban hasta el Sprint 5: si la CI corría en los últimos
    -- minutos del día, los tres minutos consecutivos cruzaban la
    -- medianoche, caían en DOS fechas distintas y la compresión dejaba
    -- dos filas. Una invariante que solo falla a las 23:59 es peor que
    -- una que no existe, porque enseña a desconfiar de la roja.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
         version_motor, calculado_en)
    select v_id, false, 5, 1, 'vieja' || g,
           date_trunc('day', now() - interval '60 days') + interval '12 hours'
           + (g || ' minutes')::interval
      from generate_series(1, 3) g;

    -- Dos de hace 400 días: deben borrarse... salvo la referenciada.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
         version_motor, calculado_en)
    select v_id, false, 5, 1, 'antigua' || g,
           date_trunc('day', now() - interval '400 days') + interval '12 hours'
      from generate_series(1, 2) g;

    -- Una cuenta de agente sirve para esto y no necesita perfil (el
    -- agente 9001 es de banco de pruebas, sembrado al principio).
    insert into public.cuentas_simulacion
        (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
    values (9001, 500, 500, 500)
    returning id into v_cuenta;

    select min(id) into v_protegida from public.senales
     where activo_id = v_id and calculado_en < now() - interval '1 year';

    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_id, v_protegida, 'agente', 100, now() - interval '400 days',
            1, 2, 50, 110, 90, 50);

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

    delete from public.ordenes where cuenta_id = v_cuenta;
    delete from public.cuentas_simulacion where id = v_cuenta;
    raise notice '── Retención: en verde ──';
end
$ret$;

-- ── I15: senales_vigentes devuelve la ÚLTIMA señal de cada activo ────
-- 0006 reescribió la vista (DISTINCT ON -> LATERAL + LIMIT 1) por
-- rendimiento. Esta invariante fija que el resultado es el mismo: una
-- fila por activo con señales, la más reciente, y que los suspendidos
-- siguen visibles (el escáner los muestra con aviso).
do $vig$
declare
    v_id      bigint;
    v_ultimo  bigint;
    v_conteo  bigint;
    v_estado  text;
begin
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
    values ('ZZI15', 'accion', 'yahoo', 'ZZI15', 'suspendido')
    returning id into v_id;

    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad,
         version_motor, calculado_en)
    select v_id, false, 5, 1, 'i15-' || g, now() - (g || ' hours')::interval
      from generate_series(1, 5) g;

    select id into v_ultimo from public.senales
     where activo_id = v_id order by calculado_en desc limit 1;

    select count(*), max(estado_activo) into v_conteo, v_estado
      from public.senales_vigentes where activo_id = v_id;
    if v_conteo <> 1 then
        raise exception 'I15 FALLO: senales_vigentes devolvió % filas para un activo, se esperaba 1', v_conteo;
    end if;
    if not exists (select 1 from public.senales_vigentes where id = v_ultimo) then
        raise exception 'I15 FALLO: senales_vigentes no devuelve la señal más reciente';
    end if;
    if v_estado <> 'suspendido' then
        raise exception 'I15 FALLO: estado_activo = %, se esperaba suspendido', v_estado;
    end if;

    select count(*) into v_conteo from (
        (select id from public.senales_vigentes)
        except
        (select distinct on (activo_id) id from public.senales
          order by activo_id, calculado_en desc)
    ) x;
    if v_conteo <> 0 then
        raise exception 'I15 FALLO: % filas de senales_vigentes no son la última señal de su activo', v_conteo;
    end if;

    delete from public.activos where id = v_id;
    raise notice 'PASS  I15 senales_vigentes devuelve la última señal de cada activo, suspendidos incluidos';
end
$vig$;

-- ═════════════════════════════════════════════════════════════════════
-- Sprint 3 — la puerta de acceso, probada como la probaría un atacante:
-- con el rol y el JWT de cada usuario, no desde la interfaz.
--
-- `como(uid)` simula una petición autenticada (rol `authenticated` +
-- claim `sub`), igual que hace PostgREST con el token de Supabase Auth.
-- `como(null)` simula la clave pública sin sesión (rol `anon`).
-- ═════════════════════════════════════════════════════════════════════
create or replace function pg_temp.como(p_uid uuid) returns void
language plpgsql as $$
begin
    if p_uid is null then
        perform set_config('request.jwt.claims', '', true);
        execute 'set local role anon';
    else
        perform set_config('request.jwt.claims',
                           json_build_object('sub', p_uid)::text, true);
        execute 'set local role authenticated';
    end if;
end $$;

create or replace function pg_temp.como_dueno() returns void
language plpgsql as $$
begin
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
end $$;

do $gob$
declare
    v_intruso  uuid := gen_random_uuid();
    v_admin    uuid := gen_random_uuid();
    v_suplant  uuid := gen_random_uuid();
    v_b        uuid := gen_random_uuid();
    v_conteo   bigint;
    v_texto    text;
    v_fallo    boolean;
begin
    -- ── I16 · El admin inicial: ligado a un correo CONFIRMADO ─────────
    -- Alguien se registra antes que el dueño: queda pendiente.
    insert into auth.users (id, email, email_confirmed_at)
    values (v_intruso, 'primero@ejemplo.com', now());
    select rol || '/' || estado into v_texto from public.perfiles where id = v_intruso;
    if v_texto <> 'usuario/pendiente' then
        raise exception 'I16 FALLO: el primer registro quedó %, se esperaba usuario/pendiente', v_texto;
    end if;

    -- El correo del admin, sin confirmar todavía: pendiente.
    insert into auth.users (id, email) values (v_admin, upper(public.fn_email_admin_inicial()));
    select rol || '/' || estado into v_texto from public.perfiles where id = v_admin;
    if v_texto <> 'usuario/pendiente' then
        raise exception 'I16 FALLO: el correo del admin SIN confirmar quedó %', v_texto;
    end if;

    -- Al confirmarlo: admin aprobado, con su cartera de seguimiento.
    update auth.users set email_confirmed_at = now() where id = v_admin;
    select rol || '/' || estado into v_texto from public.perfiles where id = v_admin;
    if v_texto <> 'admin/aprobado' then
        raise exception 'I16 FALLO: el correo del admin confirmado quedó %', v_texto;
    end if;
    if not exists (select 1 from public.carteras where usuario_id = v_admin) then
        raise exception 'I16 FALLO: el admin inicial no recibió su cartera de seguimiento';
    end if;

    -- Con un admin ya existente, el mismo correo no vuelve a promover.
    insert into auth.users (id, email, email_confirmed_at)
    values (v_suplant, public.fn_email_admin_inicial(), now());
    select rol into v_texto from public.perfiles where id = v_suplant;
    if v_texto <> 'usuario' then
        raise exception 'I16 FALLO: la promoción automática se repitió habiendo ya un admin';
    end if;
    raise notice 'PASS  I16 el admin inicial exige su correo confirmado y solo se promueve una vez';

    -- ── I17 · Un pendiente con su token no lee NADA del mercado ───────
    insert into auth.users (id, email, email_confirmed_at) values (v_b, 'b@ejemplo.com', now());
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor)
    select id, false, 5, 1, 'i17' from public.activos limit 1;
    insert into public.eventos_sistema (tipo, mensaje) values ('etl', 'evento de sistema i17');

    perform pg_temp.como(v_b);
    select (select count(*) from public.activos)
         + (select count(*) from public.senales)
         + (select count(*) from public.precios_diarios)
         + (select count(*) from public.indicadores_diarios)
         + (select count(*) from public.senales_vigentes)
         + (select count(*) from public.eventos_sistema)
         + (select count(*) from public.auditoria_admin)
         + (select count(*) from public.perfiles where id <> v_b)
      into v_conteo;
    select estado into v_texto from public.perfiles where id = v_b;
    perform pg_temp.como_dueno();
    if v_conteo <> 0 then
        raise exception 'I17 FALLO: un usuario pendiente leyó % filas', v_conteo;
    end if;
    if v_texto is distinct from 'pendiente' then
        raise exception 'I17 FALLO: el pendiente no puede leer su propio estado (%)', v_texto;
    end if;
    raise notice 'PASS  I17 un JWT pendiente recibe 0 filas y solo ve su propio perfil';

    -- ── I18 · Sin sesión (anon) no hay ni permiso de tabla ───────────
    perform pg_temp.como(null);
    begin
        perform count(*) from public.activos;
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I18 FALLO: anon puede consultar activos';
    end if;
    raise notice 'PASS  I18 la clave pública sin sesión no tiene permiso sobre las tablas';

    -- ── I19 · Solo un admin aprueba, y queda auditado ─────────────────
    perform pg_temp.como(v_intruso);
    begin
        perform public.rpc_aprobar_usuario(v_intruso);
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I19 FALLO: un usuario no admin se aprobó a sí mismo';
    end if;

    perform pg_temp.como(v_admin);
    perform public.rpc_aprobar_usuario(v_b);
    begin
        perform public.rpc_rechazar_usuario(v_intruso, '   ');
        v_fallo := false;
    exception when invalid_parameter_value then
        v_fallo := true;
    end;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I19 FALLO: se rechazó a un usuario sin motivo';
    end if;
    if (select estado from public.perfiles where id = v_b) <> 'aprobado'
       or not exists (select 1 from public.auditoria_admin
                       where accion = 'aprobar_usuario' and actor_id = v_admin
                         and objetivo_id = v_b::text)
       or not exists (select 1 from public.carteras where usuario_id = v_b)
       or not exists (select 1 from public.eventos_sistema where usuario_id = v_b)
    then
        raise exception 'I19 FALLO: aprobar no dejó estado, auditoría, cartera y evento';
    end if;
    raise notice 'PASS  I19 solo un admin aprueba; exige motivo al rechazar; todo queda auditado';

    -- ── I20 · Aprobado: lee mercado, solo sus carteras, no escribe mercado
    perform pg_temp.como(v_b);
    select count(*) into v_conteo from public.activos;
    if v_conteo = 0 then
        perform pg_temp.como_dueno();
        raise exception 'I20 FALLO: un usuario aprobado no lee el catálogo';
    end if;
    select count(*) into v_conteo from public.carteras where usuario_id <> v_b;
    if v_conteo <> 0 then
        perform pg_temp.como_dueno();
        raise exception 'I20 FALLO: el usuario B ve % carteras ajenas', v_conteo;
    end if;
    begin
        insert into public.carteras (usuario_id, nombre) values (v_admin, 'ajena');
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    if not v_fallo then
        perform pg_temp.como_dueno();
        raise exception 'I20 FALLO: B creó una cartera a nombre de otro usuario';
    end if;
    begin
        insert into public.senales (activo_id, operable, leverage_tope,
               leverage_referencia_volatilidad, version_motor)
        select id, false, 5, 1, 'intruso' from public.activos limit 1;
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    if not v_fallo then
        perform pg_temp.como_dueno();
        raise exception 'I20 FALLO: un usuario escribió en senales';
    end if;
    begin
        update public.perfiles set estado = 'aprobado', rol = 'admin' where id = v_b;
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    update public.perfiles set nombre = 'Usuario B' where id = v_b;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I20 FALLO: un usuario se cambió el rol o el estado';
    end if;
    if (select nombre from public.perfiles where id = v_b) <> 'Usuario B' then
        raise exception 'I20 FALLO: el usuario no pudo cambiar su propio nombre';
    end if;
    raise notice 'PASS  I20 aprobado: lee mercado, solo sus carteras, no escribe mercado ni su rol';

    -- ── I21 · Suspender cierra la puerta sin borrar nada ─────────────
    perform pg_temp.como(v_admin);
    perform public.rpc_suspender_usuario(v_b, 'prueba de suspensión');
    begin
        perform public.rpc_suspender_usuario(v_admin, 'auto');
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    perform pg_temp.como(v_b);
    select count(*) into v_conteo from public.activos;
    perform pg_temp.como_dueno();
    if v_conteo <> 0 then
        raise exception 'I21 FALLO: un usuario suspendido sigue leyendo % activos', v_conteo;
    end if;
    if not v_fallo then
        raise exception 'I21 FALLO: el admin pudo suspenderse a sí mismo';
    end if;
    if not exists (select 1 from public.carteras where usuario_id = v_b) then
        raise exception 'I21 FALLO: suspender borró la cartera del usuario';
    end if;
    raise notice 'PASS  I21 suspender bloquea la lectura sin borrar datos; el admin no se autosuspende';

    raise notice '── Gobierno: en verde ──';
end
$gob$;

-- ── I22 · `anon` no ejecuta ningún RPC ni función interna ────────────
do $i22$
declare
    v_texto text;
begin
    select string_agg(p.proname, ', ') into v_texto
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'rpc\_%' or p.proname like 'fn\_%')
       and has_function_privilege('anon', p.oid, 'EXECUTE');
    if v_texto is not null then
        raise exception 'I22 FALLO: anon puede ejecutar -> %', v_texto;
    end if;
    raise notice 'PASS  I22 anon no puede ejecutar ningún rpc_ ni fn_';
end
$i22$;

-- ── I23 · `authenticated` no ejecuta ninguna fn_ SECURITY DEFINER ───
--
-- Hasta el Sprint 5 esta invariante decía «ninguna `fn_`, punto». La
-- intención nunca fue la forma del nombre: era que un cliente no pueda
-- invocar las funciones que TOCAN DATOS o que se saltan la RLS, y esas
-- son exactamente las `SECURITY DEFINER`.
--
-- La regla literal resultó ser demasiado ancha y rompió producción: las
-- vistas llevan `security_invoker = true` (I13), así que se ejecutan con
-- el rol de quien consulta, y `v_cuentas_equity` llama a
-- `fn_tope_fase()`. Resultado el 2026-09-24: la pantalla del simulador
-- cargaba con «permission denied for function fn_tope_fase».
--
-- Una función PURA —sin acceso a tablas y sin `SECURITY DEFINER`— no
-- concede nada: `fn_tope_fase('fase_2_consolidacion')` devuelve 3.0 y
-- punto. Concederla es tan peligroso como conceder `round()`. Lo que se
-- comprueba aquí, por tanto, es lo que de verdad importa.
do $i23$
declare
    v_texto text;
begin
    select string_agg(p.proname, ', ') into v_texto
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like 'fn\_%'
       and p.prosecdef                              -- SECURITY DEFINER
       and has_function_privilege('authenticated', p.oid, 'EXECUTE');
    if v_texto is not null then
        raise exception 'I23 FALLO: authenticated puede ejecutar funciones SECURITY DEFINER -> %', v_texto;
    end if;
    raise notice 'PASS  I23 authenticated no ejecuta ninguna fn_ SECURITY DEFINER';
end
$i23$;

-- ═════════════════════════════════════════════════════════════════════
-- Sprint 4 — carteras, cuotas, altas e importación, con el JWT de cada
-- usuario (mismo método que el bloque de gobierno).
-- ═════════════════════════════════════════════════════════════════════
do $s4$
declare
    v_x      uuid := gen_random_uuid();   -- usuario normal aprobado
    v_y      uuid := gen_random_uuid();   -- otro usuario normal aprobado
    v_admin  uuid;
    v_ids    bigint[];
    v_id     bigint;
    v_conteo bigint;
    v_texto  text;
    v_json   jsonb;
    v_fallo  boolean;
    i        int;
begin
    insert into auth.users (id, email, email_confirmed_at) values
        (v_x, 'x@ejemplo.com', now()), (v_y, 'y@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id in (v_x, v_y);
    select id into v_admin from public.perfiles where rol = 'admin' and estado = 'aprobado' limit 1;
    select array_agg(id order by simbolo) into v_ids from public.activos where clase = 'accion';

    -- ── I24 · Cada uno ve solo su cartera; seguir va por RPC ──────────
    perform pg_temp.como(v_x);
    perform public.rpc_seguir_activo(v_ids[1]);
    perform public.rpc_seguir_activo(v_ids[2]);
    perform pg_temp.como(v_y);
    perform public.rpc_seguir_activo(v_ids[3]);
    begin
        insert into public.cartera_activos (cartera_id, activo_id)
        select id, v_ids[4] from public.carteras where usuario_id = v_x limit 1;
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    select count(*) into v_conteo from public.v_mi_cartera;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I24 FALLO: Y insertó directamente en la cartera de X';
    end if;
    if v_conteo <> 1 then
        raise exception 'I24 FALLO: Y ve % activos en su cartera, se esperaba 1', v_conteo;
    end if;

    -- El escáner de X solo trae señales de SU cartera.
    insert into public.senales (activo_id, operable, leverage_tope,
           leverage_referencia_volatilidad, version_motor)
    select unnest(v_ids[1:4]), false, 5, 1, 'i24';
    perform pg_temp.como(v_x);
    select count(*), count(*) filter (where activo_id not in (v_ids[1], v_ids[2]))
      into v_conteo, v_id from public.v_escaner_usuario;
    perform pg_temp.como_dueno();
    if v_conteo <> 2 or v_id <> 0 then
        raise exception 'I24 FALLO: el escáner de X trae % filas (% ajenas)', v_conteo, v_id;
    end if;

    -- Dejar de seguir no borra el histórico global.
    insert into public.precios_diarios (activo_id, fecha, cierre, origen, rango_real)
    values (v_ids[1], current_date, 100, 'yahoo', true) on conflict do nothing;
    perform pg_temp.como(v_x);
    perform public.rpc_dejar_activo(v_ids[1]);
    perform pg_temp.como_dueno();
    if not exists (select 1 from public.precios_diarios where activo_id = v_ids[1]) then
        raise exception 'I24 FALLO: dejar de seguir borró precios_diarios';
    end if;
    if (select seguidores from public.activos where id = v_ids[1]) <> 0
       or (select seguidores from public.activos where id = v_ids[2]) <> 1 then
        raise exception 'I24 FALLO: el contador de seguidores no cuadra';
    end if;
    raise notice 'PASS  I24 cada usuario ve solo su cartera y su escáner; seguir solo por RPC; dejar no borra histórico';

    -- ── I25 · Cuotas: 20 criptos globales y 25 por usuario ───────────
    insert into public.catalogo_coingecko (id, simbolo, nombre)
    select 'moneda-' || g, 'm' || g, 'Moneda ' || g from generate_series(1, 21) g;

    perform pg_temp.como(v_x);
    -- 11 monedas + las 3 de la semilla + las 6 líquidas de la 0032 = 20.
    for i in 1..11 loop
        perform public.rpc_solicitar_activo('cripto', 'moneda-' || i);
    end loop;
    perform public.rpc_solicitar_activo('cripto', 'bitcoin');
    perform public.rpc_solicitar_activo('cripto', 'ethereum');
    perform public.rpc_solicitar_activo('cripto', 'solana');
    perform public.rpc_solicitar_activo('cripto', x)
       from unnest(array['litecoin', 'chainlink', 'avalanche-2', 'polkadot', 'tron', 'bitcoin-cash']) x;
    -- X sigue ya 21 (1 acción + 20 criptos). Cuatro acciones más: 25.
    for i in 5..8 loop
        perform public.rpc_seguir_activo(v_ids[i]);
    end loop;
    begin
        perform public.rpc_seguir_activo(v_ids[9]);
        v_texto := null;
    exception when raise_exception then
        v_texto := sqlerrm;
    end;
    perform pg_temp.como_dueno();
    if v_texto is null or v_texto not like '%25 activos y el límite es 25%' then
        raise exception 'I25 FALLO: el activo 26 no se rechazó con el mensaje esperado (%)', v_texto;
    end if;

    -- Y tiene hueco personal, pero la cripto 21 global se rechaza…
    perform pg_temp.como(v_y);
    begin
        perform public.rpc_solicitar_activo('cripto', 'moneda-21');
        v_texto := null;
    exception when raise_exception then
        v_texto := sqlerrm;
    end;
    -- …y seguir una cripto que ya sigue otro no cuesta hueco.
    perform public.rpc_solicitar_activo('cripto', 'moneda-1');
    perform pg_temp.como_dueno();
    if v_texto is null or v_texto not like '%20 criptomonedas%' then
        raise exception 'I25 FALLO: la cripto 21 global no se rechazó (%)', v_texto;
    end if;
    if exists (select 1 from public.activos where simbolo = 'moneda-21') then
        raise exception 'I25 FALLO: la cripto rechazada por cuota quedó en activos';
    end if;

    -- El admin no tiene tope personal.
    perform pg_temp.como(v_admin);
    for i in 1..array_length(v_ids, 1) loop
        perform public.rpc_seguir_activo(v_ids[i]);
    end loop;
    perform public.rpc_solicitar_activo('cripto', 'moneda-2');
    perform public.rpc_solicitar_activo('cripto', 'moneda-3');
    perform public.rpc_solicitar_activo('cripto', 'moneda-4');
    perform public.rpc_solicitar_activo('cripto', 'moneda-5');
    perform public.rpc_solicitar_activo('cripto', 'moneda-6');
    select count(*) into v_conteo from public.v_mi_cartera;
    perform pg_temp.como_dueno();
    if v_conteo <= 25 then
        raise exception 'I25 FALLO: el admin quedó limitado a % activos', v_conteo;
    end if;
    raise notice 'PASS  I25 cuotas: el activo 26 de un usuario y la cripto 21 global se rechazan con su cifra; el admin no tiene tope personal';

    -- ── I26 · Altas: catálogo al instante, desconocidos sin fila ─────
    perform pg_temp.como(v_y);
    v_json := public.rpc_solicitar_activo('cripto', 'bitcoin');
    if v_json ->> 'estado' <> 'seguido' then
        perform pg_temp.como_dueno();
        raise exception 'I26 FALLO: bitcoin del catálogo devolvió %', v_json;
    end if;
    begin
        perform public.rpc_solicitar_activo('cripto', 'no-existe-zzzz');
        v_fallo := false;
    exception when invalid_parameter_value then
        v_fallo := true;
    end;
    if not v_fallo then
        perform pg_temp.como_dueno();
        raise exception 'I26 FALLO: una cripto inexistente no se rechazó';
    end if;
    begin
        perform public.rpc_solicitar_activo('accion', '=1+1');
        v_fallo := false;
    exception when invalid_parameter_value then
        v_fallo := true;
    end;
    v_json := public.rpc_solicitar_activo('accion', 'nvda');
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I26 FALLO: un símbolo con forma de fórmula se aceptó';
    end if;
    if v_json ->> 'estado' <> 'verificando'
       or exists (select 1 from public.activos where simbolo in ('NVDA', 'no-existe-zzzz'))
       or not exists (select 1 from public.solicitudes_activo where usuario_id = v_y and simbolo = 'NVDA') then
        raise exception 'I26 FALLO: la acción nueva no quedó como solicitud sin fila en activos (%)', v_json;
    end if;
    raise notice 'PASS  I26 altas: catálogo al instante; cripto inexistente y fórmulas rechazadas; acción nueva queda como solicitud';

    -- ── I27 · El workflow: un solo alta para dos solicitantes ────────
    perform pg_temp.como(v_admin);
    perform public.rpc_solicitar_activo('accion', 'NVDA');
    perform public.rpc_solicitar_activo('accion', 'ZZZZ');
    perform pg_temp.como_dueno();

    select count(*) into v_conteo from public.fn_tomar_solicitudes();
    if v_conteo <> 3 then
        raise exception 'I27 FALLO: fn_tomar_solicitudes tomó % solicitudes, se esperaban 3', v_conteo;
    end if;
    select count(*) into v_conteo from public.fn_tomar_solicitudes();
    if v_conteo <> 0 then
        raise exception 'I27 FALLO: una segunda toma volvió a coger % solicitudes', v_conteo;
    end if;

    perform public.fn_resolver_alta('NVDA', true, null, 'NVIDIA');
    perform public.fn_resolver_alta('ZZZZ', false, 'Yahoo Finance no reconoce «ZZZZ»');

    if (select count(*) from public.activos where simbolo = 'NVDA') <> 1
       or (select seguidores from public.activos where simbolo = 'NVDA') <> 2
       or (select estado from public.activos where simbolo = 'NVDA') <> 'pendiente_backfill'
       or exists (select 1 from public.solicitudes_activo where simbolo = 'NVDA' and estado <> 'resuelta')
    then
        raise exception 'I27 FALLO: NVDA no quedó como un solo activo seguido por los dos solicitantes';
    end if;
    if exists (select 1 from public.activos where simbolo = 'ZZZZ')
       or (select estado from public.solicitudes_activo where simbolo = 'ZZZZ') <> 'rechazada' then
        raise exception 'I27 FALLO: ZZZZ creó activo o su solicitud no quedó rechazada';
    end if;
    raise notice 'PASS  I27 dos solicitudes del mismo símbolo -> un solo activo; un símbolo desconocido no crea fila';

    -- ── I28 · Importación CSV: 10 válidas + 2 inválidas ──────────────
    perform pg_temp.como(v_x);
    v_json := public.rpc_importar_posiciones(
        (select jsonb_agg(jsonb_build_object('fila', g, 'ticker',
                    case g when 11 then '=1+1' else (select simbolo from public.activos where id = v_ids[g]) end,
                    'precio_compra', case g when 12 then '-5' else '100.50' end,
                    'monto', '1000'))
           from generate_series(1, 12) g));
    select count(*) into v_conteo from public.v_mis_posiciones;
    perform pg_temp.como(v_y);
    select count(*) into v_id from public.v_mis_posiciones;
    perform pg_temp.como_dueno();
    if (v_json ->> 'importadas')::int <> 10 or jsonb_array_length(v_json -> 'excluidas') <> 2
       or v_conteo <> 10 or v_id <> 0 then
        raise exception 'I28 FALLO: importación % (X ve %, Y ve %)', v_json, v_conteo, v_id;
    end if;
    if exists (select 1 from public.posiciones_reales where ticker like '%=%') then
        raise exception 'I28 FALLO: una celda con forma de fórmula llegó a la base de datos';
    end if;
    if not exists (select 1 from public.registro_consentimiento
                    where usuario_id = v_x and tipo = 'persistencia_cartera' and otorgado) then
        raise exception 'I28 FALLO: importar no dejó rastro de consentimiento';
    end if;
    perform pg_temp.como(v_x);
    begin
        insert into public.posiciones_reales (usuario_id, ticker, precio_compra, monto)
        values (v_x, 'X', 1, 1);
        v_fallo := false;
    exception when insufficient_privilege then
        v_fallo := true;
    end;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I28 FALLO: se pudo insertar una posición sin pasar por la validación';
    end if;
    raise notice 'PASS  I28 importación: 10 válidas y 2 excluidas con motivo; las fórmulas nunca llegan a la BD; solo el dueño las ve';

    -- ── I29 · `seguidores` cuadra con las carteras ───────────────────
    select count(*) into v_conteo
      from public.activos a
     where a.seguidores <> (select count(*) from public.cartera_activos ca where ca.activo_id = a.id);
    if v_conteo <> 0 then
        raise exception 'I29 FALLO: % activos con el contador de seguidores descuadrado', v_conteo;
    end if;
    raise notice 'PASS  I29 activos.seguidores coincide con las carteras';

    raise notice '── Sprint 4: en verde ──';
end
$s4$;

-- ═════════════════════════════════════════════════════════════════════
-- Sprint 5 — el simulador. Se prueba lo que el dinero ficticio tiene en
-- común con el de verdad: que si el saldo no cuadra, todo lo demás da
-- igual.
--
-- La prueba de CONCURRENCIA de `rpc_cerrar_orden` (riesgo R4) no está
-- aquí y no puede estarlo: un script de `psql` es una sola sesión y la
-- carrera necesita diez. Vive en `supabase/pruebas/02_concurrencia.sh`,
-- que abre diez conexiones de verdad. Lo que se prueba aquí es la
-- idempotencia en secuencia, que es la mitad del contrato.
-- ═════════════════════════════════════════════════════════════════════
do $s5$
declare
    v_u        uuid := gen_random_uuid();
    v_v        uuid := gen_random_uuid();
    v_admin    uuid;
    v_cuenta   bigint;
    v_cuenta_v bigint;
    v_btc      bigint;
    v_eth      bigint;
    v_sol      bigint;
    v_senal    bigint;
    v_orden    bigint;
    v_json     jsonb;
    v_conteo   bigint;
    v_texto    text;
    v_num      numeric;
    v_disp     numeric;
    v_fallo    boolean;
    v_dim      record;
    i          int;
begin
    insert into auth.users (id, email, email_confirmed_at) values
        (v_u, 'sim@ejemplo.com', now()), (v_v, 'sim2@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id in (v_u, v_v);
    select id into v_admin from public.perfiles where rol = 'admin' and estado = 'aprobado' limit 1;

    -- Las tres criptos de la semilla, en estado operable y con precio
    -- vivo. Se usan criptos y no acciones a propósito: el monitor no
    -- evalúa acciones fuera del horario de Nueva York, y una invariante
    -- que solo pasa entre semana a media tarde no es una invariante.
    select id into v_btc from public.activos where simbolo = 'bitcoin';
    select id into v_eth from public.activos where simbolo = 'ethereum';
    select id into v_sol from public.activos where simbolo = 'solana';
    update public.activos set estado = 'activo', ultimo_precio = 100, ultimo_precio_en = now()
     where id in (v_btc, v_eth, v_sol);

    perform pg_temp.como(v_u);
    perform public.rpc_seguir_activo(v_btc);
    perform public.rpc_seguir_activo(v_eth);
    perform public.rpc_seguir_activo(v_sol);
    perform pg_temp.como(v_v);
    perform public.rpc_seguir_activo(v_btc);
    perform pg_temp.como_dueno();

    -- ── I30 · El libro mayor es de verdad append-only ────────────────
    perform pg_temp.como(v_u);
    v_json := public.rpc_crear_cuenta_simulacion(1000);
    v_cuenta := (v_json ->> 'cuenta_id')::bigint;
    perform pg_temp.como(v_v);
    v_cuenta_v := (public.rpc_crear_cuenta_simulacion(500) ->> 'cuenta_id')::bigint;
    perform pg_temp.como_dueno();

    -- El saldo materializado sale del libro mayor y no de un literal.
    select saldo_disponible into v_num from public.cuentas_simulacion where id = v_cuenta;
    if v_num <> 1000 then
        raise exception 'I30 FALLO: la cuenta nació con saldo % y no con 1000', v_num;
    end if;
    if (select count(*) from public.movimientos_saldo
         where cuenta_id = v_cuenta and tipo = 'deposito_inicial') <> 1 then
        raise exception 'I30 FALLO: crear la cuenta no dejó un depósito inicial';
    end if;

    -- Como DUEÑO del esquema, que es más privilegio del que tiene
    -- `service_role`: ni así se puede reescribir un apunte.
    v_fallo := false;
    begin
        update public.movimientos_saldo set importe = 999999 where cuenta_id = v_cuenta;
        v_fallo := true;
    exception when others then null;
    end;
    if v_fallo then
        raise exception 'I30 FALLO: se pudo ACTUALIZAR el libro mayor';
    end if;
    v_fallo := false;
    begin
        delete from public.movimientos_saldo where cuenta_id = v_cuenta;
        v_fallo := true;
    exception when others then null;
    end;
    if v_fallo then
        raise exception 'I30 FALLO: se pudo BORRAR del libro mayor';
    end if;

    -- Titular único: ni las dos cosas a la vez, ni ninguna.
    v_fallo := false;
    begin
        insert into public.cuentas_simulacion
            (usuario_id, agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
        values (v_u, 1, 100, 100, 100);
        v_fallo := true;
    exception when check_violation then null;
    end;
    if v_fallo then
        raise exception 'I30 FALLO: se aceptó una cuenta con usuario Y agente';
    end if;
    v_fallo := false;
    begin
        insert into public.cuentas_simulacion
            (saldo_inicial, saldo_disponible, capital_maximo_alcanzado) values (100, 100, 100);
        v_fallo := true;
    exception when check_violation then null;
    end;
    if v_fallo then
        raise exception 'I30 FALLO: se aceptó una cuenta sin titular';
    end if;
    raise notice 'PASS  I30 el libro mayor no admite UPDATE ni DELETE ni como dueño; el saldo nace de él; el titular es único';

    -- ── I31 · G1 · El tope de apalancamiento es el de la FASE ────────
    -- Señal canónica de aquí en adelante: precio 100, sl 90, tp 130.
    -- Distancia al stop 10 %, R:R 3,0, liquidación a 5x en 80 (por debajo
    -- del stop, así que no hay ajuste).
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct)
    values (v_btc, true, 5, 3, 'i31', 100, 90, 130, 5, 'alcista', 'largo', 'alta', 'estructura', 2)
    returning id into v_senal;

    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_senal, null, null, 6);
        v_fallo := true;
    exception when others then
        v_texto := sqlerrm;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I31 FALLO: se abrió una orden a 6x';
    end if;
    if v_texto not like '%6%' or v_texto not like '%tope%' then
        raise exception 'I31 FALLO: el rechazo de 6x no explica el tope: %', v_texto;
    end if;

    -- En Fase 2 el tope baja a 3x (regla protegida nº1).
    update public.cuentas_simulacion set fase = 'fase_2_consolidacion' where id = v_cuenta;
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_senal, null, null, 4);
        v_fallo := true;
    exception when others then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I31 FALLO: una cuenta en fase 2 aceptó 4x';
    end if;
    update public.cuentas_simulacion set fase = 'fase_1_aceleracion' where id = v_cuenta;
    raise notice 'PASS  I31 G1: 6x se rechaza siempre y 4x se rechaza en fase 2';

    -- ── I32 · G5 · Señal operable y fresca, o no hay orden ───────────
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, direccion, fuerza)
    values (v_eth, false, 5, 3, 'i32-no-operable', 100, 'neutral', 'baja')
    returning id into v_orden;
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_orden);
        v_fallo := true;
    exception when others then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I32 FALLO: se abrió una orden sobre una señal no operable';
    end if;

    -- Una señal de hace dos horas: por encima de los 90 minutos.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, calculado_en)
    values (v_eth, true, 5, 3, 'i32-aneja', 100, 90, 130, 5, now() - interval '2 hours')
    returning id into v_orden;
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_orden);
        v_fallo := true;
    exception when others then
        v_texto := sqlerrm;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I32 FALLO: se abrió una orden sobre una señal de hace dos horas';
    end if;
    if v_texto not like '%minutos%' then
        raise exception 'I32 FALLO: el rechazo por antigüedad no lo explica: %', v_texto;
    end if;
    raise notice 'PASS  I32 G5: ni señal no operable ni señal de hace dos horas abren orden';

    -- ── I33 · Dimensionado: el paso 6 BAJA el apalancamiento ─────────
    -- Caso sin ajuste: precio 100, sl 90 -> liquidación a 5x en 80, por
    -- debajo del stop. 2 % de 1.000 = 20 $ de riesgo; nominal 200;
    -- margen 40; cantidad 2. Tocar el stop cuesta exactamente 20 $.
    select * into v_dim from public.fn_dimensionar_posicion(
        1000, 1000, 0, 100, 90, 2, 60, 5, null, 5);
    if v_dim.motivo is not null or v_dim.apalancamiento <> 5
       or v_dim.margen <> 40 or v_dim.cantidad <> 2 then
        raise exception 'I33 FALLO: dimensionado sin ajuste dio %', to_jsonb(v_dim);
    end if;
    if round(v_dim.cantidad * (100 - 90), 2) <> 20 then
        raise exception 'I33 FALLO: tocar el stop no cuesta el riesgo declarado';
    end if;

    -- Caso CON ajuste: sl 75 -> a 5x la liquidación caería en 80, ENCIMA
    -- del stop. El apalancamiento tiene que bajar a 3,9 (1/0,25 = 4,0
    -- menos un decimal) y la liquidación quedar por debajo de 75.
    select * into v_dim from public.fn_dimensionar_posicion(
        1000, 1000, 0, 100, 75, 2, 60, 5, null, 5);
    if v_dim.motivo is not null or v_dim.apalancamiento <> 3.9 then
        raise exception 'I33 FALLO: el ajuste por liquidación dio % en vez de 3,9', to_jsonb(v_dim);
    end if;
    if v_dim.precio_liquidacion >= 75 then
        raise exception 'I33 FALLO: tras el ajuste la liquidación sigue por encima del stop (%)',
              v_dim.precio_liquidacion;
    end if;
    if round(v_dim.cantidad * (100 - 75), 2) > 20 then
        raise exception 'I33 FALLO: tras el ajuste el riesgo real supera el declarado';
    end if;

    -- Un stop tan lejano que ni a 1x la liquidación queda por debajo: no
    -- hay operación, en vez de una operación con el riesgo mal declarado.
    select * into v_dim from public.fn_dimensionar_posicion(
        1000, 1000, 0, 100, 1, 2, 60, 5, null, 5);
    if v_dim.motivo <> 'sin_operacion_liquidacion_antes_del_stop' then
        raise exception 'I33 FALLO: con el stop al 99 %% debería no haber operación, dio %',
              to_jsonb(v_dim);
    end if;

    -- El tope de G3 recorta el margen: con el 60 % del equity ya
    -- comprometido no queda nada libre.
    select * into v_dim from public.fn_dimensionar_posicion(
        1000, 400, 600, 100, 90, 2, 60, 5, null, 5);
    if v_dim.motivo <> 'margen_insuficiente' then
        raise exception 'I33 FALLO: con el margen agotado debería no haber operación, dio %',
              to_jsonb(v_dim);
    end if;
    raise notice 'PASS  I33 dimensionado: 5x sin ajuste, 3,9x cuando la liquidación adelanta al stop, y sin operación cuando no cabe';

    -- ── I34 · G2, G3 y G4 ────────────────────────────────────────────
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_senal, null, null, null, 25);
        v_fallo := true;
    exception when others then null;
    end;
    if v_fallo then
        raise exception 'I34 FALLO: se aceptó un riesgo del 25 %% del equity';
    end if;

    -- La orden buena, con los números de I33.
    v_json := public.rpc_abrir_orden(v_cuenta, v_senal);
    v_orden := (v_json ->> 'orden_id')::bigint;
    perform pg_temp.como_dueno();
    if (v_json ->> 'cantidad')::numeric <> 2 or (v_json ->> 'margen')::numeric <> 40
       or (v_json ->> 'apalancamiento')::numeric <> 5 then
        raise exception 'I34 FALLO: la orden se abrió con % ', v_json;
    end if;
    select saldo_disponible, saldo_bloqueado into v_disp, v_num
      from public.cuentas_simulacion where id = v_cuenta;
    if v_disp <> 960 or v_num <> 40 then
        raise exception 'I34 FALLO: tras abrir, disponible % y bloqueado %', v_disp, v_num;
    end if;
    if (select count(*) from public.movimientos_saldo
         where orden_id = v_orden and tipo = 'bloqueo_margen' and importe = -40) <> 1 then
        raise exception 'I34 FALLO: abrir no dejó el apunte de bloqueo de margen';
    end if;

    -- Dos veces el mismo activo: no. (Índice único de orden abierta.)
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_senal);
        v_fallo := true;
    exception when others then null;
    end;
    if v_fallo then
        raise exception 'I34 FALLO: se abrieron dos órdenes en el mismo activo';
    end if;

    -- G4 (desde la 0021) NO limita la cuenta de un usuario: con
    -- `max_posiciones_abiertas` a 1, la segunda posición —en otro activo—
    -- se abre. Ese número solo reparte el cupo; lo que acota la exposición
    -- son G2 y G3. Para los agentes se prueba en I65.
    perform pg_temp.como_dueno();
    update public.cuentas_simulacion set max_posiciones_abiertas = 1 where id = v_cuenta;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado)
    values (v_sol, true, 5, 3, 'i34', 100, 90, 130, 5);
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(
            v_cuenta, (select max(id) from public.senales where version_motor = 'i34'));
        v_fallo := true;
    exception when others then
        v_texto := sqlerrm;
    end;
    perform pg_temp.como_dueno();
    if not v_fallo then
        raise exception 'I34 FALLO: G4 frenó la cuenta de un usuario: %', v_texto;
    end if;
    -- Se cierra al precio de entrada para no alterar lo que viene después.
    perform public.rpc_cerrar_orden(
        (select max(id) from public.ordenes where cuenta_id = v_cuenta and estado = 'abierta'
                                             and activo_id = v_sol), 100, 'manual', 100);
    update public.cuentas_simulacion set max_posiciones_abiertas = 3 where id = v_cuenta;

    -- Y la orden de otro usuario sobre MI cuenta, jamás.
    perform pg_temp.como(v_v);
    v_fallo := false;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_senal);
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I34 FALLO: otro usuario pudo abrir una orden en una cuenta ajena';
    end if;
    raise notice 'PASS  I34 G2/G3: riesgo, margen y propiedad de la cuenta se imponen en el servidor; G4 ya no frena a un usuario';

    -- ── I35 · Cierre idempotente y P&L recalculado a mano ────────────
    -- Cierre en TP: cantidad 2, entrada 100, salida 130 -> +60 $.
    v_json := public.rpc_cerrar_orden(v_orden, 130, 'tp', 131);
    if not (v_json ->> 'cerrada')::boolean or (v_json ->> 'pnl')::numeric <> 60 then
        raise exception 'I35 FALLO: el cierre en TP dio %', v_json;
    end if;
    select saldo_disponible into v_disp from public.cuentas_simulacion where id = v_cuenta;
    if v_disp <> 1060 then
        raise exception 'I35 FALLO: tras cerrar en TP el disponible es % y debería ser 1060', v_disp;
    end if;

    -- La SEGUNDA llamada no toca ni un céntimo. Es el caso normal en un
    -- monitor concurrente, así que no lanza: devuelve «ya cerrada».
    v_json := public.rpc_cerrar_orden(v_orden, 130, 'tp', 131);
    if (v_json ->> 'cerrada')::boolean then
        raise exception 'I35 FALLO: la segunda llamada volvió a cerrar la orden';
    end if;
    if v_json ->> 'motivo' not like '%cerrada%' then
        raise exception 'I35 FALLO: la segunda llamada no explica que ya estaba cerrada: %', v_json;
    end if;
    select saldo_disponible into v_num from public.cuentas_simulacion where id = v_cuenta;
    if v_num <> v_disp then
        raise exception 'I35 FALLO: la segunda llamada movió el saldo de % a %', v_disp, v_num;
    end if;
    if (select count(*) from public.movimientos_saldo
         where orden_id = v_orden and tipo = 'resultado_operacion') <> 1 then
        raise exception 'I35 FALLO: el resultado se acreditó más de una vez';
    end if;
    -- Dos apuntes por cierre, no uno: liberar margen y aplicar resultado
    -- son hechos económicos distintos.
    if (select count(*) from public.movimientos_saldo where orden_id = v_orden) <> 3 then
        raise exception 'I35 FALLO: se esperaban 3 apuntes (bloqueo + liberación + resultado)';
    end if;
    raise notice 'PASS  I35 cerrar dos veces acredita el P&L una vez y deja tres apuntes por operación';

    -- ── I36 · Una pérdida mayor que el margen deja el saldo en 0 ─────
    -- Se inserta la orden a mano: es una posición a 5x con el stop al
    -- 30 %, que el dimensionado NUNCA habría abierto (regla N4). Es justo
    -- el caso que el monitor tiene que saber cerrar.
    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_eth, null, 'manual', 100, now(), 2, 5, 40, 160, 70, 80)
    returning id into v_orden;
    perform public.fn_registrar_movimiento(v_cuenta, v_orden, 'bloqueo_margen', -40, 40);

    -- Un hueco de mercado: cierre en 50 -> pérdida bruta de 100 $ sobre
    -- un margen de 40. Sin el clamp, el saldo iría a negativo, el CHECK
    -- abortaría y la orden quedaría abierta para siempre.
    v_json := public.rpc_cerrar_orden(v_orden, 50, 'liquidacion', 45);
    if (v_json ->> 'pnl')::numeric <> -40 then
        raise exception 'I36 FALLO: la pérdida no se limitó al margen, dio %', v_json;
    end if;
    select estado into v_texto from public.ordenes where id = v_orden;
    if v_texto <> 'cerrada' then
        raise exception 'I36 FALLO: la orden quedó en estado % en vez de cerrada', v_texto;
    end if;
    if (select saldo_disponible from public.cuentas_simulacion where id = v_cuenta) < 0 then
        raise exception 'I36 FALLO: el saldo quedó en negativo';
    end if;
    raise notice 'PASS  I36 una pérdida mayor que el margen se limita al margen y la orden queda cerrada';

    -- ── I37 · El monitor y sus cuatro reglas ─────────────────────────
    -- Cuatro escenarios sobre cuatro órdenes, una pasada del monitor.
    -- Todas a mano por el mismo motivo que en I36: dos de ellas son
    -- posiciones que el dimensionado no habría abierto.
    perform pg_temp.como_dueno();
    delete from public.ordenes where cuenta_id = v_cuenta and estado = 'abierta';
    update public.cuentas_simulacion set max_posiciones_abiertas = 10 where id = v_cuenta;
    -- Frontera para mirar SOLO las órdenes de esta invariante: dentro de
    -- una transacción `now()` está congelado, así que filtrar por fecha de
    -- salida arrastraría los cierres de I35 e I36.
    select coalesce(max(id), 0) into v_conteo from public.ordenes;

    -- A) TP: precio 131 -> cierra en 130 exacto (M3), +60 $.
    insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_btc, 'manual', 100, now(), 2, 5, 40, 130, 90, 80);
    perform public.fn_registrar_movimiento(v_cuenta,
        (select max(id) from public.ordenes where cuenta_id = v_cuenta), 'bloqueo_margen', -40, 40);
    update public.activos set ultimo_precio = 131, ultimo_precio_en = now() where id = v_btc;

    -- B) SL: precio 85, por debajo del stop pero por encima de la
    --    liquidación -> cierra en 90 (M2 + M3), -20 $.
    insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_eth, 'manual', 100, now(), 2, 5, 40, 130, 90, 80);
    perform public.fn_registrar_movimiento(v_cuenta,
        (select max(id) from public.ordenes where cuenta_id = v_cuenta), 'bloqueo_margen', -40, 40);
    update public.activos set ultimo_precio = 85, ultimo_precio_en = now() where id = v_eth;

    -- C) Liquidación antes que el stop (M1): 5x, stop al 30 %, caída del
    --    25 % -> el precio 75 ya cruzó la liquidación de 80. Cierra por
    --    'liquidacion' y NO por 'sl'.
    insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_sol, 'manual', 100, now(), 2, 5, 40, 160, 70, 80);
    perform public.fn_registrar_movimiento(v_cuenta,
        (select max(id) from public.ordenes where cuenta_id = v_cuenta), 'bloqueo_margen', -40, 40);
    update public.activos set ultimo_precio = 75, ultimo_precio_en = now() where id = v_sol;

    -- D) Precio añejo (M4): la cuenta de V, con un precio de hace dos
    --    horas sobre un activo propio. No se toca.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado,
                                ultimo_precio, ultimo_precio_en)
    values ('zzi37', 'cripto', 'coingecko', 'zzi37', 'activo', 50, now() - interval '2 hours')
    returning id into v_num;
    insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta_v, v_num::bigint, 'manual', 100, now(), 1, 5, 20, 130, 90, 80)
    returning id into v_orden;
    perform public.fn_registrar_movimiento(v_cuenta_v, v_orden, 'bloqueo_margen', -20, 20);

    v_json := public.fn_monitorear_ordenes();
    if (v_json ->> 'tp')::int <> 1 or (v_json ->> 'sl')::int <> 1
       or (v_json ->> 'liquidacion')::int <> 1 or (v_json ->> 'evaluadas')::int <> 3 then
        raise exception 'I37 FALLO: la pasada del monitor cerró % (se esperaban 1 tp, 1 sl, 1 liquidación y 3 evaluadas)',
              v_json;
    end if;

    -- El P&L de los tres, recalculado a mano, y el cierre AL NIVEL.
    select string_agg(motivo_cierre || ':' || precio_salida || ':' || pnl_bruto
                      || ':' || precio_observado_cierre, ' | ' order by id)
      into v_texto
      from public.ordenes where cuenta_id = v_cuenta and estado = 'cerrada' and id > v_conteo;
    if v_texto <> 'tp:130.00000000:60.00:131.00000000'
                  || ' | sl:90.00000000:-20.00:85.00000000'
                  || ' | liquidacion:80.00000000:-40.00:75.00000000' then
        raise exception 'I37 FALLO: los cierres fueron «%»', v_texto;
    end if;

    if (select estado from public.ordenes where id = v_orden) <> 'abierta' then
        raise exception 'I37 FALLO: se cerró una orden con el precio de hace dos horas (M4)';
    end if;
    if (select count(*) from public.eventos_sistema
         where tipo = 'orden_cerrada' and creado_en > now() - interval '1 minute') < 3 then
        raise exception 'I37 FALLO: los cierres no dejaron evento en eventos_sistema';
    end if;
    raise notice 'PASS  I37 monitor: cierra en TP y SL al nivel exacto, la liquidación gana al stop, y un precio de hace dos horas no toca nada';

    -- ── I38 · Máquina de fases, reversión y Game Over ────────────────
    -- Drawdown desde el PICO, no desde el capital inicial: una cuenta que
    -- subió a 2.000 y bajó a 1.300 ha perdido el 35 % de su máximo aunque
    -- siga por encima del inicial. Es el caso #2 del Risk Manager.
    insert into public.cuentas_simulacion
        (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
    values (9101, 1000, 1300, 2000) returning id into v_orden;
    v_json := public.rpc_evaluar_fase(v_orden);
    if (v_json ->> 'criterio') <> 'drawdown_maximo' then
        raise exception 'I38 FALLO: no detectó el drawdown desde el pico, dio %', v_json;
    end if;
    -- Y de Fase 2 no se vuelve sola, por mucho que el capital crezca.
    update public.cuentas_simulacion set saldo_disponible = 100000 where id = v_orden;
    v_json := public.rpc_evaluar_fase(v_orden);
    if (v_json ->> 'fase') <> 'fase_2_consolidacion' or (v_json ->> 'cambio')::boolean then
        raise exception 'I38 FALLO: fase 2 cambió por evaluación automática: %', v_json;
    end if;

    -- Un solo evento por llamada aunque se cumplan dos criterios: aquí el
    -- múltiplo (3x) y el contador de operaciones (8) a la vez.
    insert into public.cuentas_simulacion
        (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado, operaciones_en_fase)
    values (9102, 1000, 3500, 3500, 9) returning id into v_orden;
    v_json := public.rpc_evaluar_fase(v_orden);
    if (v_json ->> 'criterio') <> 'multiplo_capital' then
        raise exception 'I38 FALLO: con dos criterios cumplidos debía ganar el múltiplo, dio %', v_json;
    end if;
    if (select count(*) from public.eventos_sistema
         where tipo = 'cambio_fase' and datos ->> 'cuenta_id' = v_orden::text) <> 1 then
        raise exception 'I38 FALLO: una sola llamada generó más de un evento de cambio de fase';
    end if;

    -- Reversión manual: sin confirmación, excepción. Y solo un admin.
    v_fallo := false;
    perform pg_temp.como(v_admin);
    begin
        perform public.rpc_revertir_fase_manual(v_orden, false);
        v_fallo := true;
    exception when others then null;
    end;
    if v_fallo then
        raise exception 'I38 FALLO: se revirtió la fase sin confirmación explícita';
    end if;
    v_json := public.rpc_revertir_fase_manual(v_orden, true);
    perform pg_temp.como(v_u);
    v_fallo := false;
    begin
        perform public.rpc_revertir_fase_manual(v_orden, true);
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I38 FALLO: un usuario normal pudo revertir la fase';
    end if;
    if (v_json ->> 'fase') <> 'fase_1_aceleracion'
       or (select capital_maximo_alcanzado from public.cuentas_simulacion where id = v_orden) <> 3500
    then
        raise exception 'I38 FALLO: la reversión manual no reancló el pico: %', v_json;
    end if;
    if (select count(*) from public.auditoria_admin
         where accion = 'revertir_fase' and objetivo_id = v_orden::text) <> 1 then
        raise exception 'I38 FALLO: la reversión manual no quedó auditada';
    end if;

    -- `inoperante` y `game_over` son cosas distintas y el experimento
    -- tiene que poder distinguirlas.
    insert into public.cuentas_simulacion
        (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
    values (9103, 500, 8, 500) returning id into v_orden;
    v_json := public.rpc_evaluar_game_over(v_orden);
    if (v_json ->> 'estado') <> 'inoperante' then
        raise exception 'I38 FALLO: 8 $ sin posiciones abiertas debería ser inoperante, dio %', v_json;
    end if;
    update public.cuentas_simulacion set saldo_disponible = 0 where id = v_orden;
    v_json := public.rpc_evaluar_game_over(v_orden);
    if (v_json ->> 'estado') <> 'game_over' then
        raise exception 'I38 FALLO: con equity 0 debería ser game_over, dio %', v_json;
    end if;
    -- Terminal: ni con dinero nuevo vuelve.
    update public.cuentas_simulacion set saldo_disponible = 5000 where id = v_orden;
    if (public.rpc_evaluar_game_over(v_orden) ->> 'estado') <> 'game_over' then
        raise exception 'I38 FALLO: un game over se revirtió solo';
    end if;
    raise notice 'PASS  I38 fases: drawdown desde el pico, un evento por llamada, fase 2 sin vuelta automática, reversión solo de admin con confirmación, game over terminal';

    -- ── I39 · El cuadre del libro mayor ──────────────────────────────
    -- La consulta del doc 01 §5.2, sobre TODO lo que este fichero ha
    -- movido. Cero filas o hay un bug de saldo.
    select count(*) into v_conteo from (
        select c.id
          from public.cuentas_simulacion c
          left join public.movimientos_saldo m on m.cuenta_id = c.id
         group by c.id, c.saldo_disponible, c.saldo_inicial
        having abs(c.saldo_disponible - (c.saldo_inicial + coalesce(sum(m.importe) filter (
                 where m.tipo <> 'deposito_inicial'), 0))) > 0.01
           -- Las cuentas que este fichero crea a mano para probar la
           -- máquina de fases no pasan por el libro mayor: no son un
           -- descuadre, son un banco de pruebas. Se identifican por no
           -- tener ni un apunte.
           and exists (select 1 from public.movimientos_saldo m2 where m2.cuenta_id = c.id)
    ) descuadres;
    if v_conteo <> 0 then
        raise exception 'I39 FALLO: % cuentas con el saldo descuadrado respecto al libro mayor', v_conteo;
    end if;
    raise notice 'PASS  I39 el saldo de toda cuenta con libro mayor se reconstruye sumando sus apuntes';

    raise notice '── Sprint 5: en verde ──';
end
$s5$;

-- ═════════════════════════════════════════════════════════════════════
-- Sprint 6 — los agentes.
--
-- Se prueban los criterios de aceptación de H-27…H-33 contra el ciclo de
-- verdad (`fn_ciclo_agentes`, el mismo que llama `pg_cron`), no contra
-- una copia. El universo de señales lo controla este bloque: suspende
-- todo lo que estuviera activo y siembra cinco activos propios, así que
-- lo que cada agente elige es predecible y comprobable.
--
-- Una sola licencia con el calendario: tras poner en marcha a los
-- agentes se fuerza `operable = true` en el día de hoy. Prudencia solo
-- opera acciones y, sin esto, este bloque pasaría entre semana y fallaría
-- en sábado — y una invariante que depende del día en que se ejecuta
-- enseña a desconfiar de la roja (lección de I11). Lo que decide si un
-- día es operable se prueba aparte, en I47.
-- ═════════════════════════════════════════════════════════════════════
do $s6$
declare
    v_admin    uuid;
    v_u        uuid := gen_random_uuid();
    v_pend     uuid := gen_random_uuid();
    v_hoy      date := (now() at time zone 'UTC')::date;
    v_lunes    date := date_trunc('week', (now() at time zone 'UTC')::date)::date - 28;
    v_pru      bigint;
    v_cad      bigint;
    v_auda     bigint;
    v_c_pru    bigint;
    v_c_cad    bigint;
    v_c_auda   bigint;
    v_zza      bigint;
    v_z1       bigint;
    v_z2       bigint;
    v_z3       bigint;
    v_z4       bigint;
    v_ag       bigint;
    v_ag2      bigint;
    v_cta      bigint;
    v_practica bigint;
    v_senal    bigint;
    v_orden    bigint;
    v_json     jsonb;
    v_json2    jsonb;
    v_conteo   bigint;
    v_texto    text;
    v_num      numeric;
    v_fallo    boolean;
    v_d        date;
    i          int;
begin
    select id into v_admin from public.perfiles where rol = 'admin' and estado = 'aprobado' limit 1;
    insert into auth.users (id, email, email_confirmed_at) values
        (v_u, 'agentes@ejemplo.com', now()), (v_pend, 'pendiente-agentes@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id = v_u;

    select id into v_pru  from public.agentes where nombre = 'Prudencia';
    select id into v_cad  from public.agentes where nombre = 'Cadencia';
    select id into v_auda from public.agentes where nombre = 'Audacia';
    v_c_pru  := public.fn_cuenta_agente(v_pru);
    v_c_cad  := public.fn_cuenta_agente(v_cad);
    v_c_auda := public.fn_cuenta_agente(v_auda);

    -- ── I41 · La semilla: tres agentes en pausa con 500 $ del libro mayor
    select count(*) into v_conteo from public.agentes
     where nombre in ('Prudencia', 'Cadencia', 'Audacia') and estado = 'pausado';
    if v_conteo <> 3 then
        raise exception 'I41 FALLO: se esperaban los tres agentes en pausa (D13), hay %', v_conteo;
    end if;
    select count(*) into v_conteo from public.cuentas_simulacion c
     where c.id in (v_c_pru, v_c_cad, v_c_auda) and c.saldo_disponible = 500
       and exists (select 1 from public.movimientos_saldo m
                    where m.cuenta_id = c.id and m.tipo = 'deposito_inicial' and m.importe = 500);
    if v_conteo <> 3 then
        raise exception 'I41 FALLO: % de 3 cuentas de agente nacen con 500 $ por el libro mayor', v_conteo;
    end if;
    -- Los guardarraíles leen la CUENTA: tiene que reflejar la estrategia.
    -- Desde la 0023 el margen de todo agente es el 100 % del saldo para
    -- operar, diga lo que diga su estrategia. Desde la 0030 su R:R mínimo
    -- es 1,5 (escala acotada en ATR, máximo 2).
    select format('%s/%s/%s/%s', riesgo_pct_operacion, max_posiciones_abiertas,
                  margen_comprometido_max_pct, ratio_rr_minimo) into v_texto
      from public.cuentas_simulacion where id = v_c_pru;
    if v_texto <> '1.50/3/100.00/1.50' then
        raise exception 'I41 FALLO: la cuenta de Prudencia no refleja su estrategia: %', v_texto;
    end if;
    if not exists (select 1 from public.agente_estrategia_versiones where agente_id = v_pru and version = 1) then
        raise exception 'I41 FALLO: la versión 1 de la estrategia no quedó registrada';
    end if;
    v_fallo := false;
    begin
        insert into public.cuentas_simulacion (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
        values (424242, 500, 500, 500);
        v_fallo := true;
    exception when foreign_key_violation then null;
    end;
    if v_fallo then
        raise exception 'I41 FALLO: se aceptó una cuenta de un agente que no existe';
    end if;
    -- Una estrategia absurda no llega a escribirse: el CHECK de la cuenta
    -- la rechaza al sincronizar (doc 03 §4).
    v_fallo := false;
    begin
        update public.agentes set estrategia = estrategia || '{"riesgo_pct_operacion": 40}' where id = v_cad;
        v_fallo := true;
    exception when check_violation then null;
    end;
    if v_fallo then
        raise exception 'I41 FALLO: se aceptó una estrategia con un 40 %% de riesgo por operación';
    end if;
    raise notice 'PASS  I41 tres agentes en pausa con 500 $ del libro mayor; la cuenta refleja la estrategia; ni agente fantasma ni estrategia absurda';

    -- ── Universo controlado ──────────────────────────────────────────
    update public.activos set estado = 'suspendido' where estado = 'activo';
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('ZZAGA', 'accion', 'yahoo',     'ZZAGA', 'activo', 10,  now()),
        ('zzag1', 'cripto', 'coingecko', 'zzag1', 'activo', 100, now()),
        ('zzag2', 'cripto', 'coingecko', 'zzag2', 'activo', 100, now()),
        ('zzag3', 'cripto', 'coingecko', 'zzag3', 'activo', 100, now()),
        ('zzag4', 'cripto', 'coingecko', 'zzag4', 'activo', 100, now());
    select id into v_zza from public.activos where simbolo = 'ZZAGA';
    select id into v_z1  from public.activos where simbolo = 'zzag1';
    select id into v_z2  from public.activos where simbolo = 'zzag2';
    select id into v_z3  from public.activos where simbolo = 'zzag3';
    select id into v_z4  from public.activos where simbolo = 'zzag4';

    -- ZZAGA: acción a 10 $, alta, estructura, R:R 2,2 -> la de Prudencia (a
    --        10 $ y no a 100: con unidades enteras, los 75 $ de nominal de
    --        Prudencia no llegan para una acción de 100)
    -- zzag1: cripto, media, atr, R:R 2,5, ATR 4,5       -> la de Audacia
    -- zzag2: cripto, alta, atr, R:R 4, ATR 1            -> la de Cadencia (Audacia la
    --                                                     descarta: ATR < 1,5)
    -- zzag3: bajista, no operable                       -> descarte por dirección
    -- zzag4: la mejor de todas, pero de hace tres horas -> descarte por antigüedad
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values
        (v_zza, true, 5, 3, 's6', 10, 9, 12.2, 5, 'alcista', 'largo', 'alta',  'estructura', 2, 3, 0, now()),
        (v_z1,  true, 5, 2, 's6', 100, 90, 125, 3, 'alcista', 'largo', 'media', 'atr',      4.5, 2, 0, now()),
        (v_z2,  true, 5, 3, 's6', 100, 90, 140, 5, 'alcista', 'largo', 'alta',  'atr',        1, 3, 0, now()),
        (v_z4,  true, 5, 3, 's6', 100, 90, 150, 5, 'alcista', 'largo', 'alta',  'atr',        2, 3, 0, now() - interval '3 hours');
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, direccion, sesgo_operativo, fuerza, atr_pct,
         indicadores_alcistas, indicadores_bajistas, calculado_en, soporte, resistencia)
    values (v_z3, false, 5, 2, 's6', 100, 'bajista', 'sin_sesgo', 'alta', 3, 0, 3, now(), 90, 110);

    -- ── I42 · En pausa no se opera; solo un admin los pone en marcha ─
    perform public.fn_ciclo_agentes();
    select count(*) into v_conteo from public.ordenes where cuenta_id in (v_c_pru, v_c_cad, v_c_auda);
    if v_conteo <> 0 then
        raise exception 'I42 FALLO: agentes en pausa abrieron % órdenes', v_conteo;
    end if;
    select count(*) into v_conteo from public.agente_dias
     where agente_id in (v_pru, v_cad, v_auda) and fecha = v_hoy and not operable;
    if v_conteo <> 3 then
        raise exception 'I42 FALLO: el día de un agente en pausa no debe ser operable (% de 3)', v_conteo;
    end if;

    v_fallo := false;
    begin
        perform pg_temp.como(v_u);
        perform public.rpc_cambiar_estado_agente(v_pru, 'activo');
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I42 FALLO: un usuario no admin puso en marcha a un agente';
    end if;

    perform pg_temp.como(v_admin);
    perform public.rpc_cambiar_estado_agente(v_pru, 'activo');
    perform public.rpc_cambiar_estado_agente(v_cad, 'activo');
    perform public.rpc_cambiar_estado_agente(v_auda, 'activo');
    perform pg_temp.como_dueno();
    select count(*) into v_conteo from public.auditoria_admin
     where accion = 'cambiar_estado_agente' and objetivo_id in (v_pru::text, v_cad::text, v_auda::text);
    if v_conteo <> 3 or (select count(*) from public.agentes
                          where id in (v_pru, v_cad, v_auda) and estado = 'activo') <> 3 then
        raise exception 'I42 FALLO: poner en marcha no dejó el estado y la auditoría (% auditados)', v_conteo;
    end if;
    raise notice 'PASS  I42 un agente en pausa no opera ni cuenta el día; ponerlo en marcha es cosa de admin y queda auditado';

    -- Ver la nota de la cabecera del bloque.
    update public.agente_dias set operable = true
     where agente_id in (v_pru, v_cad, v_auda) and fecha = v_hoy;

    -- ── I43 · Determinismo y perfiles que diferencian ────────────────
    foreach v_ag in array array[v_pru, v_cad, v_auda]
    loop
        v_json  := public.fn_decidir_agente(v_ag);
        v_json2 := public.fn_decidir_agente(v_ag);
        if v_json is distinct from v_json2 then
            raise exception 'I43 FALLO: el agente % decidió distinto con el mismo estado', v_ag;
        end if;
    end loop;

    -- Desde la 0027 Audacia solo admite ATR > 2,3 %: descarta por ATR bajo
    -- la acción (2 %) y zzag2 (1 %), y Cadencia la cripto de ATR 4 %.
    v_json := public.fn_decidir_agente(v_auda);
    if coalesce((v_json #>> '{descartes_por_motivo,atr_bajo}')::int, 0) <> 2
       or coalesce((v_json #>> '{descartes_por_motivo,direccion}')::int, 0) <> 1
       or coalesce((v_json #>> '{descartes_por_motivo,antiguedad}')::int, 0) <> 1 then
        raise exception 'I43 FALLO: los descartes de Audacia no son los esperados: %', v_json -> 'descartes_por_motivo';
    end if;

    perform public.fn_ciclo_agentes();

    select string_agg(g.nombre || '=' || a.simbolo, ',' order by g.id, a.simbolo collate "C") into v_texto
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.agentes g on g.id = c.agente_id
      join public.activos a on a.id = o.activo_id
     where g.id in (v_pru, v_cad, v_auda) and o.estado = 'abierta';
    -- Desde la 0023 cada agente abre a la vez todas las que marca. A todos
    -- les falta la meta entera del día y, con su riesgo por operación,
    -- cualquiera de sus candidatas la cubre si llega al objetivo: reparten
    -- entre todas las que admite su perfil. Prudencia solo admite la
    -- acción. Desde la 0027 el ATR separa a Cadencia (≤ 2,3 %: ZZAGA y
    -- zzag2) de Audacia (> 2,3 %: zzag1): ya no comparten ninguna.
    -- Desde la 0032 cada perfil tiene su rango de ATR en cripto: Cadencia
    -- hasta el 4 % y Audacia desde el 4 %: zzag1 (ATR 4,5) sigue siendo
    -- solo de Audacia y zzag2 (ATR 1) de Cadencia. Prudencia admite
    -- cripto, pero solo niveles de estructura.
    if v_texto is distinct from 'Prudencia=ZZAGA,Cadencia=ZZAGA,Cadencia=zzag2,Audacia=zzag1' then
        raise exception 'I43 FALLO: los perfiles no diferencian: %', v_texto;
    end if;
    -- El racional explica la decisión: qué faltaba, qué se evaluó y qué se descartó.
    select count(*) into v_conteo from public.ordenes
     where cuenta_id in (v_c_pru, v_c_cad, v_c_auda) and origen = 'agente'
       and racional ? 'candidatos_evaluados' and racional ? 'descartados_top3'
       and racional ? 'deficit_pendiente' and racional ? 'version_estrategia'
       and racional ? 'elegido' and racional ? 'marcadas' and racional ? 'reparto';
    if v_conteo <> 4 then
        raise exception 'I43 FALLO: % de 4 órdenes llevan el racional completo', v_conteo;
    end if;
    raise notice 'PASS  I43 misma decisión con el mismo estado; sobre las mismas señales cada agente marca lo que admite su perfil y lo abre de una vez, con su racional';

    -- ── I44 · Ningún agente supera sus guardarraíles ─────────────────
    -- La consulta que pide H-27. G2 se compara contra el PICO de capital,
    -- que es una cota superior del equity al abrir: si supera el 10 % del
    -- pico, seguro que superó el 10 % del equity.
    select count(*) into v_conteo from (
        select o.id
          from public.ordenes o
          join public.cuentas_simulacion c on c.id = o.cuenta_id
          join public.agentes g on g.id = c.agente_id
          left join public.senales s on s.id = o.senal_id
         where g.id in (v_pru, v_cad, v_auda)
           and (o.apalancamiento > public.fn_tope_fase(c.fase)                                        -- G1
                or o.apalancamiento > (public.fn_parametros_agente(g) ->> 'apalancamiento_maximo_propio')::numeric
                or o.cantidad * (o.precio_entrada - o.sl) > c.capital_maximo_alcanzado * 0.10 + 0.01   -- G2
                or s.id is null or not s.operable                                                      -- G5
                or o.fecha_entrada - s.calculado_en > make_interval(mins => c.antiguedad_senal_max_min)
                or o.precio_liquidacion > o.sl)                                                        -- N4
        union all
        select c.id
          from public.cuentas_simulacion c
         where c.agente_id in (v_pru, v_cad, v_auda)
           -- G4 ya no existe para los agentes (0023); solo la cuarentena
           -- limita a una posición abierta.
           and ((select count(*) from public.ordenes o
                  where o.cuenta_id = c.id and o.estado = 'abierta')
                 > case when (select estado from public.agentes where id = c.agente_id) = 'cuarentena'
                        then 1 else 1000 end
                or c.saldo_bloqueado > public.fn_equity(c.id) * c.margen_comprometido_max_pct / 100 + 0.01) -- G3
    ) violaciones;
    if v_conteo <> 0 then
        raise exception 'I44 FALLO: % violaciones de guardarraíles en órdenes de agentes', v_conteo;
    end if;
    raise notice 'PASS  I44 la consulta de violaciones de G1-G5 sobre las órdenes de los agentes devuelve cero filas';

    -- ── I48 · Prácticas: destilación, respaldo mínimo y efecto medido ─
    -- (Va antes que I45: Cadencia necesita un hueco libre para que su
    -- conjunto de candidatos se pueda comparar.)
    --
    -- Tres operaciones de Audacia, de hace tres días, en objetivo, sobre
    -- una señal con firma cripto|alta|atr|ATR bajo|R:R alto; y dos con otra
    -- firma, que no alcanzan el mínimo de tres (N11).
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_z2, true, 5, 3, 's6-hist', 100, 90, 130, 5, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0,
            now() - interval '3 days')
    returning id into v_senal;
    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, estado, precio_entrada, fecha_entrada, cantidad,
         apalancamiento, margen_comprometido, tp, sl, precio_liquidacion,
         precio_salida, fecha_salida, motivo_cierre, pnl_bruto, pnl_pct)
    select v_c_auda, v_z2, v_senal, 'agente', 'cerrada', 100, now() - interval '3 days', 1,
           1, 100, 130, 90, 0, 130, now() - interval '3 days' + interval '1 hour', 'tp', 30, 30
      from generate_series(1, 3);
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_z1, true, 5, 2, 's6-hist', 100, 90, 125, 3, 'alcista', 'largo', 'media', 'atr', 4.5, 2, 0,
            now() - interval '3 days')
    returning id into v_senal;
    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, estado, precio_entrada, fecha_entrada, cantidad,
         apalancamiento, margen_comprometido, tp, sl, precio_liquidacion,
         precio_salida, fecha_salida, motivo_cierre, pnl_bruto, pnl_pct)
    select v_c_auda, v_z1, v_senal, 'agente', 'cerrada', 100, now() - interval '3 days', 1,
           1, 100, 125, 90, 0, 125, now() - interval '3 days' + interval '1 hour', 'tp', 25, 25
      from generate_series(1, 2);

    if public.fn_destilar_practicas(v_auda) <> 1 then
        raise exception 'I48 FALLO: la destilación no publicó exactamente una práctica';
    end if;
    select id into v_practica from public.mejores_practicas
     where agente_autor_id = v_auda and firma = 'cripto|alta|atr|bajo|alto'
       and estado = 'propuesta' and confianza = 1 and (resultado_observado ->> 'ops')::int = 3;
    if v_practica is null then
        raise exception 'I48 FALLO: la práctica publicada no tiene la firma ni el respaldo esperados';
    end if;
    v_fallo := false;
    begin
        insert into public.mejores_practicas
            (agente_autor_id, firma, titulo, contexto, regla, condiciones, resultado_observado, confianza)
        values (v_auda, 'x', 'x', 'x', 'x', '{}', '{"ops": 2}', 1);
        v_fallo := true;
    exception when check_violation then null;
    end;
    if v_fallo then
        raise exception 'I48 FALLO: la base de datos aceptó una práctica con 2 operaciones (N11)';
    end if;

    -- Desde la 0023 Cadencia abrió sus candidatas de una vez (desde la
    -- 0027, ZZAGA y zzag2). Para comparar su conjunto de candidatos se
    -- cierra ZZAGA a su precio de entrada (P&L cero): queda solo zzag2.
    perform public.rpc_cerrar_orden(o.id, o.precio_entrada, 'manual', o.precio_entrada)
       from public.ordenes o
      where o.cuenta_id = v_c_cad and o.estado = 'abierta' and o.activo_id <> v_z2;

    -- Adoptarla CAMBIA el conjunto de candidatos de Cadencia: ZZAGA es una
    -- acción y la práctica exige cripto alta. (zzag1 ya no es suya desde
    -- la 0027: su ATR del 4 % es de Audacia.)
    select version_estrategia into v_num from public.agentes where id = v_cad;
    v_json := public.fn_decidir_agente(v_cad);
    if public.fn_adoptar_practica(v_cad) is distinct from v_practica then
        raise exception 'I48 FALLO: Cadencia no adoptó la única práctica compatible';
    end if;
    v_json2 := public.fn_decidir_agente(v_cad);
    if (v_json ->> 'candidatos_evaluados')::int <> 1
       or (v_json2 ->> 'candidatos_evaluados')::int <> 0
       or (v_json2 ->> 'candidatos_antes_practicas')::int <> 1
       or (v_json2 #>> '{descartes_por_motivo,practica}')::int <> 1 then
        raise exception 'I48 FALLO: adoptar no cambió los candidatos como se esperaba: antes % después %',
              v_json -> 'candidatos_evaluados', v_json2 -> 'candidatos_evaluados';
    end if;
    if (select version_estrategia from public.agentes where id = v_cad) <> v_num + 1
       or not ((select estrategia -> 'practicas_adoptadas' from public.agentes where id = v_cad)
               @> to_jsonb(v_practica)) then
        raise exception 'I48 FALLO: adoptar no subió la versión ni quedó en estrategia.practicas_adoptadas';
    end if;

    -- Refutación (N12): dos adopciones que empeoran. Los dos agentes de
    -- banco de pruebas la adoptan hace 15 días; antes rendían +5 %, después
    -- cinco operaciones a -3 %.
    foreach v_ag in array array[9101::bigint, 9102::bigint]
    loop
        v_cta := public.fn_cuenta_agente(v_ag);
        insert into public.mp_adopciones (practica_id, agente_id, adoptada_en)
        values (v_practica, v_ag, now() - interval '15 days');
        insert into public.ordenes
            (cuenta_id, activo_id, origen, estado, precio_entrada, fecha_entrada, cantidad,
             apalancamiento, margen_comprometido, tp, sl, precio_liquidacion,
             precio_salida, fecha_salida, motivo_cierre, pnl_bruto, pnl_pct)
        values (v_cta, v_z2, 'agente', 'cerrada', 100, now() - interval '20 days', 1, 1, 100,
                130, 90, 0, 105, now() - interval '20 days', 'manual', 5, 5);
        insert into public.ordenes
            (cuenta_id, activo_id, origen, estado, precio_entrada, fecha_entrada, cantidad,
             apalancamiento, margen_comprometido, tp, sl, precio_liquidacion,
             precio_salida, fecha_salida, motivo_cierre, pnl_bruto, pnl_pct)
        select v_cta, v_z2, 'agente', 'cerrada', 100, now() - interval '10 days', 1, 1, 100,
               130, 90, 0, 97, now() - interval '10 days', 'manual', -3, -3
          from generate_series(1, 5);
    end loop;

    perform public.fn_evaluar_adopciones(9101);
    if (select estado from public.mejores_practicas where id = v_practica) <> 'propuesta' then
        raise exception 'I48 FALLO: una sola adopción fallida refutó la práctica';
    end if;
    perform public.fn_evaluar_adopciones(9102);
    if (select estado from public.mejores_practicas where id = v_practica) <> 'refutada' then
        raise exception 'I48 FALLO: dos adopciones que empeoraron no refutaron la práctica';
    end if;
    if (select count(*) from public.mp_valoraciones where practica_id = v_practica and valoracion = -1) <> 2 then
        raise exception 'I48 FALLO: las adopciones fallidas no dejaron su valoración negativa';
    end if;
    -- Deja de ofrecerse y deja de aplicarse.
    if exists (select 1 from public.mp_adopciones where practica_id = v_practica and abandonada_en is null) then
        raise exception 'I48 FALLO: una práctica refutada sigue adoptada';
    end if;
    if public.fn_adoptar_practica(v_pru) is not null or public.fn_adoptar_practica(9001) is not null then
        raise exception 'I48 FALLO: se ofreció una práctica refutada';
    end if;
    if (select estrategia -> 'practicas_adoptadas' from public.agentes where id = v_cad) <> '[]'::jsonb then
        raise exception 'I48 FALLO: la estrategia de Cadencia sigue listando la práctica refutada';
    end if;
    raise notice 'PASS  I48 prácticas: se destila con ≥3 ops y ≥66 %%, adoptar cambia los candidatos y sube la versión, dos fracasos la refutan para todos';

    -- ── I45 · N9: meta cumplida ⇒ no se abre nada más hoy ────────────
    -- Desde la 0023 Audacia abrió ZZAGA y zzag1 a la vez. Se cierra zzag1
    -- en su objetivo; ZZAGA sigue abierta y no debe aparecer ninguna más.
    select id into v_orden from public.ordenes
     where cuenta_id = v_c_auda and estado = 'abierta' and activo_id = v_z1;
    perform public.rpc_cerrar_orden(v_orden, 125, 'tp', 125);   -- muy por encima de una meta de 35 $
    if public.fn_decidir_agente(v_auda) ->> 'accion' <> 'meta_cumplida' then
        raise exception 'I45 FALLO: con la meta cumplida Audacia no entra en modo conservación';
    end if;
    select count(*) into v_conteo from public.ordenes where cuenta_id = v_c_auda;
    perform public.fn_ciclo_agentes();
    if (select count(*) from public.ordenes where cuenta_id = v_c_auda) <> v_conteo then
        raise exception 'I45 FALLO: Audacia abrió otra posición con la meta del día cumplida (N9)';
    end if;
    if not (select cumplido from public.agente_dias where agente_id = v_auda and fecha = v_hoy) then
        raise exception 'I45 FALLO: el día de Audacia no quedó cumplido';
    end if;
    -- H-32: el evento del cierre se etiqueta con su agente sin que
    -- rpc_cerrar_orden sepa nada de agentes.
    if not exists (select 1 from public.eventos_sistema
                    where tipo = 'orden_cerrada' and agente_id = v_auda
                      and (datos ->> 'orden_id')::bigint = v_orden) then
        raise exception 'I45 FALLO: el evento del cierre no quedó etiquetado con el agente';
    end if;
    raise notice 'PASS  I45 meta cumplida: modo conservación, sin posiciones nuevas, y el día queda cumplido';

    -- ── I46 · Interés compuesto: apertura de hoy = cierre de ayer ────
    update public.agente_dias set fecha = fecha - 1 where agente_id = v_auda and fecha = v_hoy;
    perform public.fn_ciclo_agente(v_auda);
    select count(*) into v_conteo
      from public.agente_dias ayer
      join public.agente_dias hoy on hoy.agente_id = ayer.agente_id and hoy.fecha = ayer.fecha + 1
     where ayer.agente_id = v_auda and ayer.fecha = v_hoy - 1
       and ayer.cerrado_en is not null and ayer.saldo_cierre = hoy.saldo_apertura
       and hoy.objetivo_importe = round(hoy.saldo_apertura * 0.07, 2);
    if v_conteo <> 1 then
        raise exception 'I46 FALLO: la apertura de hoy no coincide con el cierre de ayer o la meta no es el 7 %% de ella';
    end if;
    raise notice 'PASS  I46 el saldo de apertura de hoy es el de cierre de ayer y la meta se calcula sobre él';

    -- ── I47 · Corte semanal ──────────────────────────────────────────
    -- Un agente que solo opera acciones y cumple sus 5 días de mercado.
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
    values ('prueba-acciones', 2, 'activo', '{"clases_admitidas": ["accion"]}') returning id into v_ag;
    v_cta := public.fn_crear_cuenta_agente(v_ag);
    if public.fn_mercado_para_clases('["accion"]', v_lunes + 5)
       or not public.fn_mercado_para_clases('["accion"]', v_lunes)
       or not public.fn_mercado_para_clases('["cripto"]', v_lunes + 6) then
        raise exception 'I47 FALLO: el calendario de mercado por clase no es el esperado';
    end if;
    insert into public.agente_dias
        (agente_id, fecha, cuenta_id, saldo_apertura, saldo_cierre, objetivo_importe, operable, cumplido, cerrado_en)
    select v_ag, d, v_cta, 500, 510, 10,
           public.fn_mercado_para_clases('["accion"]', d), public.fn_mercado_para_clases('["accion"]', d), now()
      from (select v_lunes + k as d from generate_series(0, 6) k) g;
    v_json := public.fn_corte_semanal_agente(v_ag, v_lunes);
    if v_json ->> 'veredicto' <> 'validada' or (v_json ->> 'dias_operables')::int <> 5 then
        raise exception 'I47 FALLO: 5 de 5 días de mercado debía ser validada sobre 5, dio %', v_json;
    end if;
    if (public.fn_corte_semanal_agente(v_ag, v_lunes) ->> 'ya_evaluada')::boolean is not true
       or (select count(*) from public.agente_semanas where agente_id = v_ag) <> 1 then
        raise exception 'I47 FALLO: el corte de una semana ya evaluada no es idempotente';
    end if;

    -- Dos deficientes seguidas y después una validada.
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
    values ('prueba-deficiente', 2, 'activo',
            '{"riesgo_pct_operacion": 4, "max_posiciones_abiertas": 3}') returning id into v_ag2;
    v_cta := public.fn_crear_cuenta_agente(v_ag2);
    for i in 0..2 loop
        insert into public.agente_dias
            (agente_id, fecha, cuenta_id, saldo_apertura, saldo_cierre, objetivo_importe, operable, cumplido, cerrado_en)
        select v_ag2, d, v_cta, 500, 500, 10, true,
               -- semanas 0 y 1: un día de siete; semana 2: los siete
               case when i = 2 then true else d = v_lunes + 7 * i end, now()
          from (select v_lunes + 7 * i + k as d from generate_series(0, 6) k) g;
    end loop;

    v_json := public.fn_corte_semanal_agente(v_ag2, v_lunes);
    select format('%s/%s/%s', riesgo_pct_operacion, max_posiciones_abiertas, a.estado) into v_texto
      from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id where c.id = v_cta;
    if v_json ->> 'veredicto' <> 'deficiente' or v_texto <> '2.00/3/activo' then
        raise exception 'I47 FALLO: tras una deficiente el riesgo debía quedar a la mitad (2.00/3/activo), quedó % (%)',
              v_texto, v_json ->> 'veredicto';
    end if;
    if not exists (select 1 from public.agente_backlog
                    where clave_deduplicacion = 'ajuste_regla:semana_deficiente:agente_' || v_ag2) then
        raise exception 'I47 FALLO: una semana deficiente no abrió su entrada de backlog';
    end if;
    perform public.fn_corte_semanal_agente(v_ag2, v_lunes + 7);
    select format('%s/%s/%s', riesgo_pct_operacion, max_posiciones_abiertas, a.estado) into v_texto
      from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id where c.id = v_cta;
    if v_texto <> '2.00/1/cuarentena' then
        raise exception 'I47 FALLO: dos deficientes seguidas debían dar cuarentena con 1 posición, quedó %', v_texto;
    end if;
    perform public.fn_corte_semanal_agente(v_ag2, v_lunes + 14);
    select format('%s/%s/%s', riesgo_pct_operacion, max_posiciones_abiertas, a.estado) into v_texto
      from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id where c.id = v_cta;
    if v_texto <> '4.00/3/activo' then
        raise exception 'I47 FALLO: una validada debía restaurar riesgo y salir de cuarentena, quedó %', v_texto;
    end if;
    if (select count(*) from public.eventos_sistema where tipo = 'corte_semanal' and agente_id = v_ag2) <> 3 then
        raise exception 'I47 FALLO: cada veredicto debe dejar su evento';
    end if;
    -- Que no operen en lo que queda de fichero.
    update public.agentes set estado = 'pausado' where id in (v_ag, v_ag2);
    raise notice 'PASS  I47 corte: 5/5 de acciones es validada, idempotente; una deficiente deja el riesgo a la mitad, dos dan cuarentena, una validada lo restaura';

    -- ── I49 · Backlog: una fila por clave, evidencia obligatoria ─────
    for i in 0..2 loop
        insert into public.agente_dias
            (agente_id, fecha, cuenta_id, saldo_apertura, objetivo_importe, operable,
             ciclos, ciclos_con_universo, ciclos_sin_alcistas)
        values (v_ag, v_hoy - i, public.fn_cuenta_agente(v_ag), 500, 10, true, 4, 4, 4);
    end loop;
    for i in 1..5 loop
        perform public.fn_disparadores_backlog(v_ag, '{}');
    end loop;
    select count(*), max(ocurrencias) into v_conteo, v_num
      from public.agente_backlog where tipo = 'sesgo_corto';
    if v_conteo <> 1 or v_num <> 1 then
        raise exception 'I49 FALLO: tres días sin alcistas debían crear UNA entrada con 1 ocurrencia, hay % con %', v_conteo, v_num;
    end if;
    v_fallo := false;
    begin
        insert into public.agente_backlog
            (agente_id, tipo, titulo, descripcion, justificacion, evidencia, clave_deduplicacion, agentes_solicitantes)
        values (v_pru, 'nuevo_dato', 'x', 'x', 'x', '{}', 'sin-evidencia', array[v_pru]);
        v_fallo := true;
    exception when check_violation then null;
    end;
    if v_fallo then
        raise exception 'I49 FALLO: se insertó una entrada de backlog sin evidencia (N13)';
    end if;
    foreach v_ag in array array[v_pru, v_cad, v_auda]
    loop
        perform public.fn_registrar_backlog(v_ag, 'nueva_herramienta', 'nueva_herramienta:prueba',
            'x', 'x', 'x', jsonb_build_object('agente', v_ag), 3);
        perform public.fn_registrar_backlog(v_ag, 'nueva_herramienta', 'nueva_herramienta:prueba',
            'x', 'x', 'x', jsonb_build_object('agente', v_ag), 3);
    end loop;
    select clave_deduplicacion, prioridad into v_texto, v_num from public.v_backlog_priorizado limit 1;
    if v_texto <> 'nueva_herramienta:prueba' or v_num <> 9 then
        raise exception 'I49 FALLO: lo que piden los tres agentes debía encabezar el backlog con prioridad 9, encabeza % (%)', v_texto, v_num;
    end if;

    select id into v_orden from public.agente_backlog where clave_deduplicacion = 'nueva_herramienta:prueba';
    v_fallo := false;
    begin
        perform pg_temp.como(v_u);
        perform public.rpc_revisar_backlog(v_orden, 'aceptado', null);
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I49 FALLO: un usuario no admin revisó el backlog';
    end if;
    v_fallo := false;
    perform pg_temp.como(v_admin);
    begin
        perform public.rpc_revisar_backlog(v_orden, 'rechazado', '  ');
        v_fallo := true;
    exception when invalid_parameter_value then null;
    end;
    perform public.rpc_revisar_backlog(v_orden, 'rechazado', 'Fuera del alcance de la Fase 2');
    perform pg_temp.como_dueno();
    if v_fallo or (select estado from public.agente_backlog where id = v_orden) <> 'rechazado'
       or not exists (select 1 from public.auditoria_admin
                       where accion = 'resolver_backlog' and objetivo_id = v_orden::text) then
        raise exception 'I49 FALLO: rechazar exige motivo y queda auditado';
    end if;
    raise notice 'PASS  I49 backlog: una fila por clave aunque se dispare cada ciclo; sin evidencia no entra; lo que piden los tres encabeza; revisar es de admin';

    -- ── I50 · Eventos: el registro viaja con el usuario ──────────────
    insert into public.eventos_sistema (usuario_id, tipo, mensaje) values (v_pend, 'sys', 'privado de otro');
    perform pg_temp.como(v_u);
    select count(*) into v_conteo from public.v_mis_eventos where usuario_id = v_pend;
    if v_conteo <> 0 then
        perform pg_temp.como_dueno();
        raise exception 'I50 FALLO: un usuario ve eventos privados de otro';
    end if;
    if not exists (select 1 from public.v_mis_eventos where agente_id = v_auda) then
        perform pg_temp.como_dueno();
        raise exception 'I50 FALLO: un aprobado no ve los eventos globales de los agentes';
    end if;
    perform public.rpc_vaciar_eventos();
    select count(*) into v_conteo from public.v_mis_eventos;
    perform pg_temp.como_dueno();
    if v_conteo <> 0 then
        raise exception 'I50 FALLO: tras vaciar quedan % eventos visibles', v_conteo;
    end if;
    insert into public.eventos_sistema (tipo, mensaje) values ('sys', 'nuevo tras vaciar');
    perform pg_temp.como(v_u);
    select count(*) into v_conteo from public.v_mis_eventos;
    perform pg_temp.como_dueno();
    if v_conteo <> 1 or (select count(*) from public.eventos_sistema) < 5 then
        raise exception 'I50 FALLO: vaciar debe ocultar lo leído sin borrar nada (visibles %)', v_conteo;
    end if;
    raise notice 'PASS  I50 eventos: los globales para todos, los privados para su dueño; vaciar mueve la marca del perfil y no borra';

    -- ── I51 · 30 búsquedas por minuto y usuario ──────────────────────
    -- Se ancla al principio de un minuto para que el cambio de minuto no
    -- reparta las 31 llamadas entre dos ventanas (y la prueba dependa de
    -- la hora a la que corre).
    if extract(second from clock_timestamp()) > 50 then
        perform pg_sleep(61 - extract(second from clock_timestamp()));
    end if;
    perform pg_temp.como(v_u);
    for i in 1..30 loop
        perform * from public.rpc_buscar_activo('zz');
    end loop;
    v_fallo := false;
    begin
        perform * from public.rpc_buscar_activo('zz');
        v_fallo := true;
    exception when raise_exception then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I51 FALLO: la búsqueda 31 del minuto no se limitó';
    end if;
    raise notice 'PASS  I51 la búsqueda de activos se limita a 30 peticiones por minuto y usuario';

    -- ── I52 · RLS: los agentes a la vista, los usuarios no ───────────
    perform pg_temp.como(v_u);
    select count(*) into v_conteo from public.v_operaciones_agentes where agente_id in (v_pru, v_cad, v_auda);
    select count(*) into v_num from public.ordenes
     where cuenta_id in (select id from public.cuentas_simulacion where usuario_id is not null);
    select count(*) into i from public.v_ranking_agentes;
    perform pg_temp.como_dueno();
    if v_conteo < 3 or v_num <> 0 or i < 3 then
        raise exception 'I52 FALLO: un aprobado ve % operaciones de agentes, % órdenes ajenas y % agentes', v_conteo, v_num, i;
    end if;
    perform pg_temp.como(v_pend);
    select count(*) into v_conteo from public.agentes;
    perform pg_temp.como_dueno();
    if v_conteo <> 0 then
        raise exception 'I52 FALLO: un usuario pendiente ve % agentes', v_conteo;
    end if;
    v_fallo := false;
    begin
        perform pg_temp.como(v_u);
        update public.agentes set estado = 'activo' where id = 9001;
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I52 FALLO: un usuario escribió en agentes';
    end if;
    raise notice 'PASS  I52 un aprobado ve las operaciones de los agentes y no las de otros usuarios; un pendiente no ve nada; nadie escribe directo';

    -- ── I53 · Game Over terminal; reiniciar crea otra cuenta (N14) ───
    -- La cuenta del agente 9103 quedó en game over en I38.
    if public.fn_ciclo_agente(9103) ->> 'accion' <> 'game_over'
       or (select estado from public.agentes where id = 9103) <> 'game_over' then
        raise exception 'I53 FALLO: el ciclo no propagó el Game Over de la cuenta al agente';
    end if;
    v_cta := public.fn_cuenta_agente(9103);
    v_fallo := false;
    perform pg_temp.como(v_admin);
    begin
        perform public.rpc_reiniciar_agente(9103, false);
        v_fallo := true;
    exception when raise_exception then null;
    end;
    begin
        perform public.rpc_cambiar_estado_agente(9103, 'activo');
        v_fallo := true;
    exception when raise_exception then null;
    end;
    v_json := public.rpc_reiniciar_agente(9103, true);
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I53 FALLO: se reinició sin confirmación o se reanudó un Game Over';
    end if;
    if (v_json ->> 'cuenta_anterior')::bigint <> v_cta
       or (select estado from public.cuentas_simulacion where id = v_cta) <> 'game_over'
       or (select saldo_disponible from public.cuentas_simulacion
            where id = (v_json ->> 'cuenta_nueva')::bigint) <> 500
       or (select estado from public.agentes where id = 9103) <> 'pausado'
       or not exists (select 1 from public.auditoria_admin
                       where accion = 'reiniciar_agente' and objetivo_id = '9103') then
        raise exception 'I53 FALLO: reiniciar debía conservar la cuenta vieja y crear otra de 500 $ en pausa: %', v_json;
    end if;
    raise notice 'PASS  I53 Game Over terminal: reiniciar exige admin y confirmación, crea una cuenta nueva y conserva la vieja';

    raise notice '── Sprint 6: en verde ──';
end
$s6$;

-- ═════════════════════════════════════════════════════════════════════
-- I54 · Poder de trading por escalas (D15, 0014).
--
-- Dos cosas: que las escalas son las del dueño, y la relación que justifica
-- que `rpc_abrir_orden` no tenga un guardarraíl de poder de trading — con el
-- tope de 5× y todo el equity comprometido, el nominal nunca llega al poder
-- de trading (hasta 200.000 $ de equity; por encima, la tabla del dueño no
-- dice nada y el poder se queda en 1 M$). Si un día sube el tope de
-- apalancamiento, esto se pone en rojo y avisa de que el límite hace falta.
-- ═════════════════════════════════════════════════════════════════════
do $i54$
declare
    v_texto text;
begin
    select string_agg(format('%s→%s', e, public.fn_poder_trading(e)), ' ' order by e) into v_texto
      from unnest(array[500, 999.99, 1000, 1999, 2000, 5000, 10000, 15000, 20000, 25000, 50000, 90000]::numeric[]) e;
    if v_texto <> '500→10000.00 999.99→19999.80 1000→20000 1999→20000 2000→40000 5000→100000 10000→200000 15000→300000 20000→400000 25000→500000 50000→1000000 90000→1000000' then
        raise exception 'I54 FALLO: las escalas de poder de trading no son las del dueño: %', v_texto;
    end if;

    select string_agg(e::text, ', ') into v_texto
      from generate_series(100, 200000, 50) e
     where public.fn_tope_fase('fase_1_aceleracion') * e > public.fn_poder_trading(e);
    if v_texto is not null then
        raise exception 'I54 FALLO: con el tope de la fase el nominal superaría el poder de trading en: %', left(v_texto, 200);
    end if;

    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'v_cuentas_equity'
                      and column_name = 'poder_trading') then
        raise exception 'I54 FALLO: v_cuentas_equity no expone el poder de trading';
    end if;
    raise notice 'PASS  I54 poder de trading: las escalas del dueño, y el tope de 5x nunca lo alcanza';
end
$i54$;

-- ═════════════════════════════════════════════════════════════════════
-- I55 · El ETL lo dispara Supabase (0015).
--
-- Con instantes FIJOS: si la invariante dependiera de la hora de la CI,
-- pasaría o fallaría según el día.
-- ═════════════════════════════════════════════════════════════════════
do $i55$
declare
    v_json  jsonb;
    v_fallo boolean := false;
begin
    -- Martes 29-sep-2026: 13:00 UTC = 09:00 NY (cerrado), 14:00 UTC = 10:00
    -- NY (abierto), 21:00 UTC = 17:00 NY (cerrado). Sábado 3-oct: cerrado.
    if public.fn_etl_toca('accion', '2026-09-29 13:00+00')
       or not public.fn_etl_toca('accion', '2026-09-29 14:00+00')
       or public.fn_etl_toca('accion', '2026-09-29 21:00+00')
       or public.fn_etl_toca('accion', '2026-10-03 15:00+00')
       or not public.fn_etl_toca('cripto', '2026-10-03 03:00+00') then
        raise exception 'I55 FALLO: la ventana del ETL de acciones no es la de Nueva York';
    end if;

    -- Sin pg_net ni Vault (la CI) no revienta: lo dice y sigue.
    v_json := public.fn_programar_etl();
    if v_json ->> 'cripto' <> 'sin_infraestructura' then
        raise exception 'I55 FALLO: sin infraestructura el disparo debía decirlo, dio %', v_json;
    end if;

    -- Solo los dos workflows del ETL: el token no sirve para lanzar otros.
    begin
        perform public.fn_disparar_workflow('altas.yml', interval '1 minute');
        v_fallo := true;
    exception when invalid_parameter_value then null;
    end;
    if v_fallo then
        raise exception 'I55 FALLO: fn_disparar_workflow aceptó un workflow que no es del ETL';
    end if;
    raise notice 'PASS  I55 el ETL se dispara desde la BD: ventana de NY con instantes fijos, sin infraestructura no revienta, solo workflows del ETL';
end
$i55$;

-- ═════════════════════════════════════════════════════════════════════
-- 0016 — reparto, cierres parciales, rotación y aprendizaje por decisión.
--
-- Universo propio: se suspende lo que estuviera activo y se siembran una
-- acción y tres criptos. Dos agentes de banco de pruebas, cada uno con UN
-- parámetro nuevo activo, para que lo que se mide sea ese y no otro.
-- ═════════════════════════════════════════════════════════════════════
do $s7$
declare
    v_u      uuid := gen_random_uuid();
    v_otro   uuid := gen_random_uuid();
    v_hoy    date := (now() at time zone 'UTC')::date;
    v_acc    bigint;
    v_c1     bigint;
    v_c2     bigint;
    v_c3     bigint;
    v_c9     bigint;
    v_s9     bigint;
    v_s_acc  bigint;
    v_s1     bigint;
    v_s3     bigint;
    v_cuenta bigint;
    v_orden  bigint;
    v_rota   bigint;
    v_parc   bigint;
    v_c_rota bigint;
    v_c_parc bigint;
    v_json   jsonb;
    v_num    numeric;
    v_num2   numeric;
    v_conteo bigint;
    v_texto  text;
    v_fallo  boolean;
    v_dim    record;
    v_senal  bigint;
    i        int;
begin
    update public.activos set estado = 'suspendido' where estado = 'activo';
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('ZZDA',  'accion', 'yahoo',     'ZZDA',  'activo', 30,  now()),
        ('zzd2',  'cripto', 'coingecko', 'zzd2',  'activo', 100, now()),
        ('zzd3',  'cripto', 'coingecko', 'zzd3',  'activo', 100, now());
    select id into v_acc from public.activos where simbolo = 'ZZDA';
    -- Bitcoin y no una cripto nueva: el catálogo ya sigue 20 criptos (el
    -- tope global por la cuota de CoinGecko) y el usuario no podría seguirla.
    select id into v_c1  from public.activos where simbolo = 'bitcoin';
    update public.activos set estado = 'activo', ultimo_precio = 100, ultimo_precio_en = now() where id = v_c1;
    select id into v_c2  from public.activos where simbolo = 'zzd2';
    select id into v_c3  from public.activos where simbolo = 'zzd3';

    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_acc, true, 5, 3, 's7', 30,  27, 36,  5, 'alcista', 'largo', 'alta',  'estructura', 2, 3, 0, now())
    returning id into v_s_acc;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    -- Bitcoin arrastra señales de bloques anteriores: esta tiene que ser
    -- la vigente, así que va un segundo por delante de la más reciente.
    values (v_c1,  true, 5, 3, 's7', 100, 90, 120, 5, 'alcista', 'largo', 'alta',  'atr', 2, 3, 0,
            greatest(now(), (select max(calculado_en) + interval '1 second'
                               from public.senales where activo_id = v_c1)))
    returning id into v_s1;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_c3,  true, 5, 3, 's7', 100, 90, 120, 5, 'alcista', 'largo', 'media', 'atr', 2, 2, 0, now())
    returning id into v_s3;

    -- ── I56 · Cupo, unidades enteras y cantidad a mano ───────────────
    select * into v_dim from public.fn_dimensionar_posicion(1000, 1000, 0, 100, 99.5, 2, 60, 5, null, 5);
    if v_dim.margen <> 600 then
        raise exception 'I56 FALLO: sin cupo, un stop al 0,5 %% debía llevarse el 60 %% (600 $), dio %', v_dim.margen;
    end if;
    select * into v_dim from public.fn_dimensionar_posicion(1000, 1000, 0, 100, 99.5, 2, 60, 5, null, 5, 20);
    if v_dim.margen <> 200 then
        raise exception 'I56 FALLO: con cupo del 20 %% el margen debía ser 200 $, dio %', v_dim.margen;
    end if;
    select * into v_dim from public.fn_dimensionar_posicion(1000, 1000, 0, 30, 27, 2, 60, 5, null, 5, null, true);
    if v_dim.cantidad <> 6 or v_dim.margen <> 36 then
        raise exception 'I56 FALLO: una acción debía dimensionarse en 6 unidades enteras y 36 $, dio % y %',
              v_dim.cantidad, v_dim.margen;
    end if;

    insert into auth.users (id, email, email_confirmed_at) values
        (v_u, 'reparto@ejemplo.com', now()), (v_otro, 'reparto2@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id in (v_u, v_otro);
    perform pg_temp.como(v_u);
    perform public.rpc_seguir_activo(v_acc);
    perform public.rpc_seguir_activo(v_c1);
    v_cuenta := (public.rpc_crear_cuenta_simulacion(1000) ->> 'cuenta_id')::bigint;
    select cupo_pct into v_num from public.v_recomendaciones_usuario where senal_id = v_s_acc;
    select cantidad into v_num2 from public.v_recomendaciones_usuario where senal_id = v_s_acc;
    perform pg_temp.como_dueno();
    -- Desde la 0022 la recomendación de un USUARIO no lleva el cupo de
    -- max_posiciones: el reparto lo hace `rpc_repartir_saldo` (I66).
    if v_num is not null or v_num2 <> trunc(v_num2) then
        raise exception 'I56 FALLO: la recomendación de un usuario no debía llevar cupo y sí acciones enteras, dio % y %', v_num, v_num2;
    end if;

    v_fallo := false;
    perform pg_temp.como(v_u);
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_s_acc, null, null, null, null, 'manual', null, 2.5);
        v_fallo := true;
    exception when invalid_parameter_value then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I56 FALLO: se aceptaron 2,5 acciones';
    end if;
    perform pg_temp.como(v_u);
    v_json := public.rpc_abrir_orden(v_cuenta, v_s_acc, null, null, null, null, 'manual', null, 3);
    perform pg_temp.como_dueno();
    if (v_json ->> 'cantidad')::numeric <> 3 then
        raise exception 'I56 FALLO: la cantidad a mano no se respetó: %', v_json;
    end if;
    -- A mano se puede pasar del cupo, pero no de G2: 40 unidades a 100 con
    -- el stop en 90 son 400 $ de riesgo sobre 1.000 $.
    v_fallo := false;
    perform pg_temp.como(v_u);
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_s1, null, null, null, null, 'manual', null, 40);
        v_fallo := true;
    exception when raise_exception then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo then
        raise exception 'I56 FALLO: una cantidad a mano con un 40 %% de riesgo se aceptó (G2)';
    end if;
    raise notice 'PASS  I56 cupo por posición en el dimensionado; acciones en unidades enteras; la cantidad a mano manda pero G2 sigue imponiéndose';

    -- ── I57 · Cierre parcial ─────────────────────────────────────────
    perform pg_temp.como(v_u);
    v_orden := (public.rpc_abrir_orden(v_cuenta, v_s1, null, null, null, null, 'manual', null, 4) ->> 'orden_id')::bigint;
    perform pg_temp.como_dueno();
    update public.activos set ultimo_precio = 110, ultimo_precio_en = now() where id = v_c1;
    select margen_comprometido into v_num from public.ordenes where id = v_orden;

    perform pg_temp.como(v_u);
    v_json := public.rpc_cerrar_parcial(v_orden, 0.5);
    perform pg_temp.como_dueno();
    select format('%s/%s/%s/%s', cantidad, margen_comprometido * 2 = v_num, pnl_parciales, estado) into v_texto
      from public.ordenes where id = v_orden;
    if v_texto <> '2.00000000/t/20.00/abierta' then
        raise exception 'I57 FALLO: cerrar el 50 %% debía dejar 2 unidades, la mitad del margen y +20 $ realizados: %', v_texto;
    end if;
    if public.fn_pnl_realizado_dia(v_cuenta, v_hoy) <> 20 then
        raise exception 'I57 FALLO: el P&L realizado del día no incluye el cierre parcial';
    end if;
    -- El libro mayor sigue cuadrando al céntimo.
    select c.saldo_inicial + coalesce(sum(m.importe) filter (where m.tipo <> 'deposito_inicial'), 0) - c.saldo_disponible
      into v_num2
      from public.cuentas_simulacion c join public.movimientos_saldo m on m.cuenta_id = c.id
     where c.id = v_cuenta group by c.id;
    if v_num2 <> 0 then
        raise exception 'I57 FALLO: el cierre parcial descuadró el libro mayor en % $', v_num2;
    end if;

    v_fallo := false;
    perform pg_temp.como(v_otro);
    begin
        perform public.rpc_cerrar_parcial(v_orden, 0.5);
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como(v_u);
    begin
        perform public.rpc_cerrar_parcial(v_orden, 1);
        v_fallo := true;
    exception when invalid_parameter_value then null;
    end;
    -- 3 acciones al 50 %: 1 entera, no 1,5.
    select id into v_senal from public.ordenes where cuenta_id = v_cuenta and activo_id = v_acc;
    v_json := public.rpc_cerrar_parcial(v_senal, 0.5);
    perform pg_temp.como_dueno();
    if v_fallo or (v_json ->> 'cantidad_cerrada')::numeric <> 1 then
        raise exception 'I57 FALLO: parcial ajeno, del 100 %% o de acciones fraccionadas: %', v_json;
    end if;
    raise notice 'PASS  I57 cierre parcial: libera la parte del margen, realiza su P&L, cuadra el libro mayor y cierra acciones enteras';

    -- ── Agentes de banco de pruebas ──────────────────────────────────
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-rota', 50, 'activo', '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["alta"],
          "rr_minimo": 1.2, "max_posiciones_abiertas": 1, "margen_comprometido_max_pct": 60,
          "riesgo_pct_operacion": 2, "reparto": "concentrado", "rotacion_umbral": 1.5}')
    returning id into v_rota;
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-parcial', 50, 'activo', '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["media"],
          "rr_minimo": 1.2, "max_posiciones_abiertas": 1, "margen_comprometido_max_pct": 60,
          "riesgo_pct_operacion": 2, "reparto": "cupo",
          "tp_parcial": {"recorrido": 0.5, "fraccion": 0.5, "mover_stop": true}}')
    returning id into v_parc;
    v_c_rota := public.fn_crear_cuenta_agente(v_rota);
    v_c_parc := public.fn_crear_cuenta_agente(v_parc);
    perform public.fn_sincronizar_dia_agente(v_rota, v_c_rota);
    perform public.fn_sincronizar_dia_agente(v_parc, v_c_parc);
    update public.agente_dias set operable = true where agente_id in (v_rota, v_parc) and fecha = v_hoy;

    -- ── I58 · Rotación ───────────────────────────────────────────────
    update public.activos set ultimo_precio = 100, ultimo_precio_en = now() where id = v_c1;
    v_json := public.fn_ciclo_agente(v_rota);
    select id into v_orden from public.ordenes where cuenta_id = v_c_rota and estado = 'abierta' and activo_id = v_c1;
    if v_orden is null then
        raise exception 'I58 FALLO: el agente de rotación no abrió su primera posición: %', v_json;
    end if;
    -- Desde la 0023 no hay G4: se rota cuando el SALDO está lleno. El
    -- servidor llena la cuenta con una posición de relleno (stop al 0,5 %,
    -- recién abierta: la rotación no la toca) hasta dejar menos de 10 $ de
    -- margen libre.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzd9', 'cripto', 'coingecko', 'zzd9', 'activo', 100, now())
    returning id into v_c9;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_c9, true, 5, 3, 's7', 100, 99.5, 100.6, 5, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0, now())
    returning id into v_s9;
    perform public.rpc_abrir_orden(v_c_rota, v_s9, null, null, 5, 2, 'agente', '{}'::jsonb,
                                   trunc((saldo_disponible - 5) * 5 / 100, 8))
       from public.cuentas_simulacion where id = v_c_rota;
    if public.fn_decidir_agente(v_rota) ->> 'accion' not in ('rotar', 'saldo_lleno') then
        raise exception 'I58 FALLO: con menos de 10 $ libres el saldo debía estar lleno: %',
              public.fn_decidir_agente(v_rota) ->> 'accion';
    end if;

    -- La posición madura y se acerca al objetivo: le queda poco que ganar
    -- (R:R restante 2/28) y aparece una señal de R:R 3.
    update public.ordenes set fecha_entrada = now() - interval '1 hour' where id = v_orden;
    update public.activos set ultimo_precio = 118, ultimo_precio_en = now() where id = v_c1;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_c2, true, 5, 3, 's7', 100, 90, 130, 5, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0, now());
    v_json := public.fn_ciclo_agente(v_rota);
    if (select motivo_cierre from public.ordenes where id = v_orden) is distinct from 'rotacion'
       or not exists (select 1 from public.ordenes where cuenta_id = v_c_rota and estado = 'abierta' and activo_id = v_c2)
       or not exists (select 1 from public.agente_decisiones
                       where agente_id = v_rota and tipo = 'rotacion' and orden_id = v_orden
                         and orden_nueva_id is not null) then
        raise exception 'I58 FALLO: debía cerrar la débil por rotación, abrir la nueva y registrar la decisión: %', v_json;
    end if;
    raise notice 'PASS  I58 rotación con el saldo lleno: cierra la posición con menos R:R restante, abre la mejor señal y deja la decisión para juzgarla';

    -- ── I59 · Toma parcial automática y su contrafactual ─────────────
    update public.activos set ultimo_precio = 100, ultimo_precio_en = now() where id = v_c3;
    v_json := public.fn_ciclo_agente(v_parc);
    select id into v_orden from public.ordenes where cuenta_id = v_c_parc and estado = 'abierta';
    if v_orden is null then
        raise exception 'I59 FALLO: el agente de parciales no abrió su posición: %', v_json;
    end if;
    select cantidad into v_num from public.ordenes where id = v_orden;
    update public.activos set ultimo_precio = 111, ultimo_precio_en = now() where id = v_c3;
    perform public.fn_ciclo_agente(v_parc);
    select format('%s/%s/%s', cantidad * 2 = v_num, sl, sl_original) into v_texto
      from public.ordenes where id = v_orden;
    if v_texto <> 't/99.95000000/90.00000000' then
        raise exception 'I59 FALLO: al 50 %% del recorrido debía cerrar la mitad y subir el stop a la entrada: %', v_texto;
    end if;
    -- La parte que quedaba sale por el stop movido: la parcial salvó
    -- (110 − 99,95) × la mitad.
    perform public.rpc_cerrar_orden(v_orden, 99.95, 'sl', 99.9);
    perform public.fn_resolver_decisiones();
    select efecto into v_num2 from public.agente_decisiones where agente_id = v_parc and tipo = 'parcial';
    if v_num2 is null or v_num2 <= 0 then
        raise exception 'I59 FALLO: una parcial que se adelantó al stop debía resolverse con efecto positivo, dio %', v_num2;
    end if;
    raise notice 'PASS  I59 toma parcial al nivel, stop a la entrada, y su efecto se mide contra lo que habría pasado sin ella';

    -- ── I60 · Ajuste de parámetros con evidencia ─────────────────────
    -- Diez rotaciones resueltas que salieron mal, y el reparto por cupo
    -- rindiendo más que el concentrado en diez operaciones de cada modo.
    -- Desde la 0023 el reparto ya no es un parámetro aprendido (lo decide
    -- la exigencia del día): esa evidencia ya no lo mueve.
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_rota, 'rotacion', '{"umbral": 1.5}', -3, now() from generate_series(1, 10);
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_parc, 'reparto', '{"reparto": "cupo"}', 50, now() from generate_series(1, 10);
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_rota, 'reparto', '{"reparto": "concentrado"}', -50, now() from generate_series(1, 10);
    select version_estrategia into v_num from public.agentes where id = v_rota;

    if public.fn_ajustar_parametros(v_rota) <> 1 then
        raise exception 'I60 FALLO: con esa evidencia debía ajustar solo el umbral de rotación';
    end if;
    -- El reparto se lee del parámetro EFECTIVO: la estrategia guardada de
    -- este agente de pruebas dice «concentrado», y la 0023 lo ignora.
    select format('%s/%s', estrategia -> 'rotacion_umbral', public.fn_parametros_agente(a) ->> 'reparto')
      into v_texto from public.agentes a where id = v_rota;
    if v_texto <> '1.7/exigencia' or (select version_estrategia from public.agentes where id = v_rota) <= v_num
       or (select count(*) from public.agente_ajustes where agente_id = v_rota) <> 1 then
        raise exception 'I60 FALLO: rotaciones que pierden suben el umbral un paso y el reparto sigue por exigencia: %', v_texto;
    end if;
    -- Sin evidencia nueva no se vuelve a mover.
    if public.fn_ajustar_parametros(v_rota) <> 0 then
        raise exception 'I60 FALLO: un parámetro se movió dos veces con la misma evidencia';
    end if;
    raise notice 'PASS  I60 los parámetros se mueven un paso con 10 decisiones resueltas, quedan registrados y no se mueven dos veces por lo mismo; el reparto ya no se aprende';

    -- ── I61 · Aprender de los errores: prácticas «a evitar» ──────────
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_c2, true, 5, 3, 's7-hist', 100, 90, 130, 5, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0,
            now() - interval '5 days')
    returning id into v_senal;
    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, estado, precio_entrada, fecha_entrada, cantidad,
         apalancamiento, margen_comprometido, tp, sl, precio_liquidacion,
         precio_salida, fecha_salida, motivo_cierre, pnl_bruto, pnl_pct)
    select v_c_rota, v_c2, v_senal, 'agente', 'cerrada', 100, now() - interval '5 days', 1,
           1, 100, 130, 90, 0, 90, now() - interval '5 days' + interval '1 hour', 'sl', -10, -10
      from generate_series(1, 3);
    perform public.fn_destilar_practicas(v_rota);
    select id into v_orden from public.mejores_practicas
     where agente_autor_id = v_rota and sentido = 'evitar' and firma = 'evitar|cripto|alta|atr|bajo|alto';
    if v_orden is null then
        raise exception 'I61 FALLO: tres stops con la misma firma debían publicarse como error a evitar';
    end if;
    -- Aplicada como «evitar», excluye justo las señales que la cumplen
    -- (zzd2: alta, atr, ATR 2, R:R 3) y deja pasar las demás.
    select string_agg(simbolo || '=' || coalesce(motivo, 'candidata'), ',' order by simbolo) into v_texto
      from public.fn_universo_agente(
               public.fn_parametros_agente((select a from public.agentes a where a.id = v_parc))
                   -- 0043: sin la espera tras el stop; aquí se mide la práctica.
                   || '{"fuerzas_admitidas": ["alta", "media"], "espera_tras_stop_horas": 0}',
               v_c_parc,
               jsonb_build_array(jsonb_build_object(
                   'c', (select condiciones from public.mejores_practicas where id = v_orden), 's', 'evitar')))
     where simbolo in ('zzd2', 'zzd3');
    if v_texto <> 'zzd2=practica,zzd3=candidata' then
        raise exception 'I61 FALLO: la práctica a evitar debía excluir zzd2 y dejar zzd3: %', v_texto;
    end if;
    raise notice 'PASS  I61 los errores también se destilan: una firma que pierde se publica como «evitar» y excluye esas señales';

    update public.agentes set estado = 'pausado' where id in (v_rota, v_parc);
    raise notice '── 0016: en verde ──';
end
$s7$;

-- ═════════════════════════════════════════════════════════════════════
-- I62 · Mínimo de una acción (0017).
-- ═════════════════════════════════════════════════════════════════════
do $i62$
declare
    v_dim record;
begin
    -- Prudencia con 500 $: 7,50 $ de riesgo no llegan para una acción de
    -- 100 $ con el stop al 10 % (10 $). Se compra una: 2 % del equity.
    select * into v_dim from public.fn_dimensionar_posicion(
        500, 500, 0, 100, 90, 1.5, 40, 5, 3, 5, 13.33, true);
    if v_dim.cantidad is distinct from 1 or v_dim.margen <> 33.34 then
        raise exception 'I62 FALLO: debía comprar 1 acción con 33,34 $ de margen, dio % y %',
              v_dim.cantidad, v_dim.margen;
    end if;
    -- Pero nunca por encima de G2: una acción de 900 $ con el stop a 20 $
    -- arriesga el 20 % de una cuenta de 100 $.
    select * into v_dim from public.fn_dimensionar_posicion(
        100, 100, 0, 900, 880, 1, 60, 1, null, 5, null, true);
    if v_dim.motivo is distinct from 'cantidad_nula' then
        raise exception 'I62 FALLO: el mínimo de una acción no puede saltarse G2, dio %', v_dim.motivo;
    end if;
    -- Ni por encima del saldo: una acción de 2.000 $ a 5x pide 400 $ de
    -- margen y solo hay 300 disponibles.
    select * into v_dim from public.fn_dimensionar_posicion(
        1000, 300, 0, 2000, 1990, 0.1, 60, 5, null, 5, null, true);
    if v_dim.motivo is distinct from 'cantidad_nula' then
        raise exception 'I62 FALLO: el mínimo de una acción no puede pasar del saldo, dio %', v_dim.motivo;
    end if;
    raise notice 'PASS  I62 si el riesgo no llega para una acción se compra una, sin pasar de G2 ni del saldo';
end
$i62$;

-- ═════════════════════════════════════════════════════════════════════
-- I63 · Solo acciones en USD (0019).
-- ═════════════════════════════════════════════════════════════════════
do $i63$
declare
    v_u     uuid := gen_random_uuid();
    v_json  jsonb;
    v_texto text := '';
begin
    insert into auth.users (id, email, email_confirmed_at) values (v_u, 'usd@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id = v_u;
    perform pg_temp.como(v_u);
    -- Tokio, Londres, Xetra y Shanghái: rechazadas al pedirlas.
    foreach v_json in array array['"7203.T"', '"VOD.L"', '"SAP.DE"', '"600519.SS"']::jsonb[]
    loop
        begin
            perform public.rpc_solicitar_activo('accion', v_json #>> '{}');
            v_texto := v_texto || (v_json #>> '{}') || ' ';
        exception when invalid_parameter_value then null;
        end;
    end loop;
    -- Una clase de acción de EE. UU. con guion sigue entrando como solicitud.
    v_json := public.rpc_solicitar_activo('accion', 'BRK-B');
    perform pg_temp.como_dueno();
    if v_texto <> '' then
        raise exception 'I63 FALLO: se aceptaron acciones de bolsas extranjeras: %', v_texto;
    end if;
    if v_json ->> 'estado' <> 'verificando' then
        raise exception 'I63 FALLO: BRK-B debía quedar como solicitud, dio %', v_json;
    end if;
    raise notice 'PASS  I63 las acciones con sufijo de bolsa extranjera se rechazan al pedirlas; las de EE. UU. con guion entran';
end
$i63$;

-- ═════════════════════════════════════════════════════════════════════
-- I64 · Cada usuario ajusta los límites de SU cuenta (0020).
-- ═════════════════════════════════════════════════════════════════════
do $i64$
declare
    v_u      uuid := gen_random_uuid();
    v_sin    uuid := gen_random_uuid();
    v_json   jsonb;
    v_texto  text;
    v_malos  int := 0;
begin
    insert into auth.users (id, email, email_confirmed_at) values
        (v_u, 'ajustes@ejemplo.com', now()), (v_sin, 'sin-cuenta@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id in (v_u, v_sin);
    perform pg_temp.como(v_u);
    perform public.rpc_crear_cuenta_simulacion(1000);
    v_json := public.rpc_configurar_cuenta(6, 1.5, 50, 1.2);
    select format('%s/%s/%s/%s', max_posiciones_abiertas, riesgo_pct_operacion,
                  margen_comprometido_max_pct, ratio_rr_minimo) into v_texto
      from public.v_cuentas_equity where usuario_id = v_u;
    -- Nulo = no tocar.
    perform public.rpc_configurar_cuenta(null, null, null, 2.0);
    if (select ratio_rr_minimo from public.v_cuentas_equity where usuario_id = v_u) <> 2.0
       or (select max_posiciones_abiertas from public.v_cuentas_equity where usuario_id = v_u) <> 6 then
        perform pg_temp.como_dueno();
        raise exception 'I64 FALLO: un parámetro nulo debía dejar el valor como estaba';
    end if;
    -- Fuera de rango: ni 11 posiciones, ni 12 % de riesgo, ni 110 % de
    -- margen (desde la 0022 el margen llega al 100 %, no al 80 %).
    begin perform public.rpc_configurar_cuenta(11); v_malos := v_malos + 1;
    exception when invalid_parameter_value then null; end;
    begin perform public.rpc_configurar_cuenta(null, 12); v_malos := v_malos + 1;
    exception when invalid_parameter_value then null; end;
    begin perform public.rpc_configurar_cuenta(null, null, 110); v_malos := v_malos + 1;
    exception when invalid_parameter_value then null; end;
    begin perform public.rpc_configurar_cuenta(null, null, 5); v_malos := v_malos + 1;
    exception when invalid_parameter_value then null; end;
    -- Sin cuenta propia no hay nada que configurar (y no toca la de otro).
    perform pg_temp.como(v_sin);
    begin perform public.rpc_configurar_cuenta(4); v_malos := v_malos + 1;
    exception when no_data_found then null; end;
    perform pg_temp.como_dueno();

    if v_texto <> '6/1.50/50.00/1.20' or v_malos <> 0 then
        raise exception 'I64 FALLO: ajustes guardados % y % valores fuera de rango aceptados', v_texto, v_malos;
    end if;
    if not exists (select 1 from public.eventos_sistema
                    where usuario_id = v_u and datos ? 'antes' and datos ? 'despues') then
        raise exception 'I64 FALLO: el cambio de límites no dejó su evento';
    end if;
    raise notice 'PASS  I64 cada usuario ajusta los límites de su cuenta dentro de rango; nulo no toca; fuera de rango y sin cuenta se rechazan';
end
$i64$;

-- ═════════════════════════════════════════════════════════════════════
-- I65 · Una práctica repetida se respalda (0021); G4 ya no frena a los
--       agentes (0023).
-- ═════════════════════════════════════════════════════════════════════
do $i65$
declare
    v_rota   bigint;
    v_cad    bigint;
    v_aud    bigint;
    v_cuenta bigint;
    v_senal  bigint;
    v_fallo  boolean := false;
    v_texto  text;
    v_antes  int;
    v_id     bigint;
begin
    -- El agente de rotación del bloque 0016 tiene max 1 en su estrategia y
    -- posiciones abiertas. Hasta la 0023 otra orden se rechazaba por G4;
    -- desde la 0023 G4 no existe tampoco para los agentes: si se rechaza,
    -- que sea por otra cosa (aquí, su saldo para operar está casi lleno).
    select id into v_rota from public.agentes where nombre = 'prueba-rota';
    v_cuenta := public.fn_cuenta_agente(v_rota);
    select s.id into v_senal from public.senales s join public.activos a on a.id = s.activo_id
     where a.simbolo = 'zzd3' and s.version_motor = 's7' order by s.id desc limit 1;
    begin
        perform public.rpc_abrir_orden(v_cuenta, v_senal, null, null, null, null, 'agente');
        v_fallo := true;
    exception when raise_exception then v_texto := sqlerrm;
    end;
    if v_texto like '%posiciones abiertas%' then
        raise exception 'I65 FALLO: G4 sigue frenando a un agente: %', v_texto;
    end if;

    -- Respaldo: Audacia destila la misma firma que ya publicó Cadencia.
    select id into v_cad from public.agentes where nombre = 'Cadencia';
    select id into v_aud from public.agentes where nombre = 'Audacia';
    insert into public.mejores_practicas
        (agente_autor_id, firma, titulo, contexto, regla, condiciones, resultado_observado, confianza)
    values (v_cad, 'cripto|alta|estructura|medio|medio', 't', 'c', 'r',
            '{"clase": "cripto"}', '{"ops": 3, "tp": 3, "sl": 0}', 1)
    returning id into v_id;
    select count(*) into v_antes from public.mejores_practicas;
    perform public.fn_respaldar_practica(v_id, v_aud, '{"ops": 3, "tp": 2, "sl": 1}');
    perform public.fn_respaldar_practica(v_id, v_aud, '{"ops": 3, "tp": 2, "sl": 1}');   -- dos veces = una
    select format('%s/%s/%s', confianza, v_aud = any(coautores) and cardinality(coautores) = 1,
                  (select valoracion from public.mp_valoraciones where practica_id = v_id and agente_id = v_aud))
      into v_texto
      from public.mejores_practicas where id = v_id;
    if v_texto <> '0.833/t/1' or (select count(*) from public.mejores_practicas) <> v_antes then
        raise exception 'I65 FALLO: el respaldo debía sumar evidencia (5/6), añadir un coautor y un voto, sin fila nueva: %', v_texto;
    end if;
    -- Y la coautora no se la adopta a sí misma.
    if public.fn_adoptar_practica(v_aud) = v_id then
        raise exception 'I65 FALLO: un agente adoptó una práctica que ya respalda';
    end if;
    -- Duplicado de antes de la 0021: Prudencia publicó la misma firma por
    -- su cuenta y Cadencia la había adoptado. Al fundir, la de Prudencia
    -- se archiva, Prudencia pasa a coautora y la adopción de Cadencia... no
    -- se traslada: Cadencia es la autora del principal, así que se abandona.
    insert into public.mejores_practicas
        (agente_autor_id, firma, titulo, contexto, regla, condiciones, resultado_observado, confianza)
    values ((select id from public.agentes where nombre = 'Prudencia'),
            'cripto|alta|estructura|medio|medio', 't', 'c', 'r',
            '{"clase": "cripto"}', '{"ops": 4, "tp": 4, "sl": 0}', 1)
    returning id into v_senal;
    insert into public.mp_adopciones (practica_id, agente_id) values (v_senal, v_cad);
    v_antes := public.fn_fundir_practicas_duplicadas();
    if v_antes <> 1
       or (select estado from public.mejores_practicas where id = v_senal) <> 'archivada'
       or not exists (select 1 from public.mejores_practicas
                       where id = v_id
                         and (select id from public.agentes where nombre = 'Prudencia') = any(coautores))
       or exists (select 1 from public.mp_adopciones where practica_id in (v_senal, v_id)
                    and agente_id = v_cad and abandonada_en is null) then
        raise exception 'I65 FALLO: fundir debía archivar el duplicado, sumar a su autor como coautor y no dejar a la autora adoptándose a sí misma';
    end if;
    raise notice 'PASS  I65 G4 ya no frena a los agentes; una práctica repetida se respalda: evidencia sumada, coautor y voto, sin duplicado';
end
$i65$;

-- ═════════════════════════════════════════════════════════════════════
-- I66 · Saldo para operar y reparto ponderado por apalancamiento (0022).
--
-- El caso del dueño, con números redondos: 1.000 $ en Fase 1 son 5.000 $
-- de saldo para operar. Tres sugerencias a 5×, 4× y 3× se reparten ese
-- saldo en proporción 5 : 4 : 3 (2.083 · 1.667 · 1.250 $), se pueden abrir
-- las tres —la regla de las tres posiciones no reaparece por el cupo— y
-- entre las tres consumen casi todo el saldo sin pasarse.
-- ═════════════════════════════════════════════════════════════════════
do $i66$
declare
    v_u      uuid := gen_random_uuid();
    v_otro   uuid := gen_random_uuid();
    v_cuenta bigint;
    v_a      bigint[];
    v_s      bigint[] := '{}';
    v_texto  text;
    v_num    numeric;
    v_n      int;
    v_r      record;
    v_btc    bigint;
    v_sbtc   bigint;
    i        int;
begin
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('ZZRA', 'accion', 'yahoo', 'ZZRA', 'activo', 10, now()),
        ('ZZRB', 'accion', 'yahoo', 'ZZRB', 'activo', 10, now()),
        ('ZZRC', 'accion', 'yahoo', 'ZZRC', 'activo', 10, now());
    select array_agg(id order by simbolo) into v_a from public.activos where simbolo in ('ZZRA', 'ZZRB', 'ZZRC');

    -- Stop al 1 %: el riesgo por operación (10 %) pediría 10.000 $ de
    -- nominal, así que lo que fija el tamaño es la parte del reparto.
    for i in 1..3 loop
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
             precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
             niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
        values (v_a[i], true, 5, 3, 's8', 10, 9.9, 10.3, 6 - i, 'alcista', 'largo', 'alta',
                'estructura', 2, 3, 0, now());
        v_s := v_s || currval(pg_get_serial_sequence('public.senales', 'id'));
    end loop;

    insert into auth.users (id, email, email_confirmed_at) values
        (v_u, 'saldo-operar@ejemplo.com', now()), (v_otro, 'saldo-operar2@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id in (v_u, v_otro);

    perform pg_temp.como(v_u);
    for i in 1..3 loop perform public.rpc_seguir_activo(v_a[i]); end loop;
    v_cuenta := (public.rpc_crear_cuenta_simulacion(1000) ->> 'cuenta_id')::bigint;
    perform public.rpc_configurar_cuenta(null, 10);

    -- 1. Cuenta nueva: G3 al 100 % y 5.000 $ de saldo para operar.
    select format('%s/%s/%s/%s', margen_comprometido_max_pct, saldo_operar, saldo_operar_max, saldo_operar_en_uso)
      into v_texto from public.v_cuentas_equity where id = v_cuenta;
    if v_texto <> '100.00/5000.00/5000.00/0.00' then
        perform pg_temp.como_dueno();
        raise exception 'I66 FALLO: la cuenta nueva debía tener margen 100 %% y 5.000 $ de saldo para operar, dio %', v_texto;
    end if;

    -- 2. Reparto de las tres: partes 5 : 4 : 3 del saldo, acciones enteras.
    select string_agg(format('%s:%s:%s:%s', peso::numeric(4,1), parte, cantidad, limitado_por_riesgo),
                      ' ' order by peso desc), sum(parte)
      into v_texto, v_num
      from public.rpc_repartir_saldo(v_s);
    if v_texto <> '5.0:2083.33:208:f 4.0:1666.67:133:f 3.0:1250.00:75:f'
       or abs(v_num - 5000) > 0.02 then
        perform pg_temp.como_dueno();
        raise exception 'I66 FALLO: el reparto ponderado no es 5 : 4 : 3 del saldo: % (suma %)', v_texto, v_num;
    end if;

    -- 3. Solo las marcadas: con dos (5× y 3×) el saldo se reparte 5 : 3.
    select string_agg(parte::text, ' ' order by peso desc) into v_texto
      from public.rpc_repartir_saldo(array[v_s[1], v_s[3]]);
    if v_texto <> '3125.00 1875.00' then
        perform pg_temp.como_dueno();
        raise exception 'I66 FALLO: el reparto debía hacerse solo entre las marcadas, dio %', v_texto;
    end if;

    -- 4. Se abren las tres con su cantidad; ninguna regla de tres
    --    posiciones ni cupo de max_posiciones lo impide.
    for v_r in select * from public.rpc_repartir_saldo(v_s) loop
        perform public.rpc_abrir_orden(v_cuenta, v_r.senal_id, null, null, null, null,
                                       'recomendacion', null, v_r.cantidad);
    end loop;
    select format('%s/%s', posiciones_abiertas, saldo_operar_en_uso) into v_texto
      from public.v_cuentas_equity where id = v_cuenta;
    select count(*) into v_n from public.rpc_repartir_saldo(v_s);
    perform pg_temp.como_dueno();
    -- 416 + 332,50 + 250 = 998,50 $ de margen × 5 = 4.992,50 $ del saldo.
    if v_texto <> '3/4992.50' or v_n <> 0 then
        raise exception 'I66 FALLO: las tres debían abrirse y consumir 4.992,50 $ del saldo; dio % (y % sugerencias aún repartibles)', v_texto, v_n;
    end if;

    -- 5. Otro usuario no ve el reparto de nadie, y anon no puede llamarlo.
    perform pg_temp.como(v_otro);
    select count(*) into v_n from public.rpc_repartir_saldo(v_s);
    perform pg_temp.como_dueno();
    if v_n <> 0 then
        raise exception 'I66 FALLO: otro usuario obtuvo % filas del reparto ajeno', v_n;
    end if;
    if has_function_privilege('anon', 'public.rpc_repartir_saldo(bigint[])', 'EXECUTE') then
        raise exception 'I66 FALLO: anon puede ejecutar rpc_repartir_saldo';
    end if;

    -- 6. Con una cripto a un precio sin decimales redondos, el lote entero
    --    también entra: la cantidad se trunca y el margen que deduce
    --    `rpc_abrir_orden` no se pasa de lo libre ni por un céntimo.
    select id into v_btc from public.activos where simbolo = 'bitcoin';
    update public.activos set estado = 'activo', ultimo_precio = 33.333, ultimo_precio_en = now() where id = v_btc;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_btc, true, 5, 3, 's8', 33.333, 33, 34.5, 4.7, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0,
            greatest(now(), (select max(calculado_en) + interval '1 second'
                               from public.senales where activo_id = v_btc)))
    returning id into v_sbtc;
    perform pg_temp.como(v_otro);
    perform public.rpc_seguir_activo(v_a[1]);
    perform public.rpc_seguir_activo(v_btc);
    v_cuenta := (public.rpc_crear_cuenta_simulacion(777.77) ->> 'cuenta_id')::bigint;
    perform public.rpc_configurar_cuenta(null, 10);
    for v_r in select * from public.rpc_repartir_saldo(array[v_s[1], v_sbtc]) loop
        perform public.rpc_abrir_orden(v_cuenta, v_r.senal_id, null, null, null, null,
                                       'recomendacion', null, v_r.cantidad);
    end loop;
    select format('%s/%s', posiciones_abiertas, saldo_operar_en_uso <= saldo_operar_max)
      into v_texto from public.v_cuentas_equity where id = v_cuenta;
    perform pg_temp.como_dueno();
    if v_texto <> '2/t' then
        raise exception 'I66 FALLO: el lote con una cripto debía abrirse entero dentro del saldo, dio %', v_texto;
    end if;

    update public.activos set estado = 'suspendido' where id = any(v_a);
    raise notice 'PASS  I66 saldo para operar = equity × tope; el reparto entre las marcadas pondera por apalancamiento y se abren todas, también con cripto';
end
$i66$;

-- ═════════════════════════════════════════════════════════════════════
-- I67 · Los agentes reparten su saldo según la exigencia del día (0023).
--
-- Un agente de pruebas con 500 $ (2.500 $ de saldo para operar) y dos
-- criptos: A a 5× con un 3 % hasta el objetivo y B a 3× con un 2 %. Con un
-- riesgo del 10 % y el stop al 1 %, lo que fija el tamaño es la parte del
-- reparto. Concentrar en A gana 71,25 $ en objetivo; repartir 5 : 3, 58,13 $.
--   · le faltan 20 $   → las dos cubren la meta: reparte entre las dos;
--   · le faltan 65 $   → solo concentrar la cubre: marca A;
--   · le faltan 100 $  → nada la cubre: la de más ganancia, que es A sola;
--   · en cuarentena    → como mucho una.
-- Y en el ciclo abre todas sus marcadas a la vez, con margen 100 % aunque
-- su estrategia diga 40.
-- ═════════════════════════════════════════════════════════════════════
do $i67$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_a      bigint;
    v_b      bigint;
    v_json   jsonb;
    v_texto  text;
begin
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('zzexa', 'cripto', 'coingecko', 'zzexa', 'activo', 100, now()),
        ('zzexb', 'cripto', 'coingecko', 'zzexb', 'activo', 100, now());
    select id into v_a from public.activos where simbolo = 'zzexa';
    select id into v_b from public.activos where simbolo = 'zzexb';
    -- ATR del 8 % y niveles de estructura: ninguna otra señal del fichero
    -- entra en el universo de este agente.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, true, 5, 3, 's9', 100, 99, 103, 5, 'alcista', 'largo', 'alta', 'estructura', 8, 3, 0, now()),
           (v_b, true, 5, 3, 's9', 100, 99, 102, 3, 'alcista', 'largo', 'alta', 'estructura', 8, 3, 0, now());

    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-exigencia', 4, 'activo',
         '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["alta"], "niveles_origen_admitidos": ["estructura"],
           "atr_pct_min": 7.5, "rr_minimo": 1.5, "max_posiciones_abiertas": 1,
           "margen_comprometido_max_pct": 40, "riesgo_pct_operacion": 10}')
    returning id into v_ag;
    v_cuenta := public.fn_crear_cuenta_agente(v_ag);

    -- 1. Le falta poco (4 % = 20 $): reparte 5 : 3 entre las dos.
    v_json := public.fn_decidir_agente(v_ag);
    select format('%s/%s/%s', v_json #>> '{reparto,modo}',
                  (select string_agg((x ->> 'simbolo') || ':' || (x ->> 'margen')::numeric(10,2), ' ')
                     from jsonb_array_elements(v_json -> 'marcadas') x),
                  v_json #>> '{reparto,ganancia_objetivo}')
      into v_texto;
    if v_texto <> 'cubre_meta/zzexa:312.50 zzexb:187.50/58.13' then
        raise exception 'I67 FALLO: con poca exigencia debía repartir 5 : 3 entre las dos: % (%)', v_texto, v_json -> 'reparto';
    end if;

    -- 2. Le faltan 65 $ (13 %): solo concentrar en la 5× la cubre.
    update public.agentes set objetivo_diario_pct = 13 where id = v_ag;
    v_json := public.fn_decidir_agente(v_ag);
    select format('%s/%s', v_json #>> '{reparto,modo}',
                  (select string_agg(x ->> 'simbolo', ' ') from jsonb_array_elements(v_json -> 'marcadas') x))
      into v_texto;
    if v_texto <> 'cubre_meta/zzexa' then
        raise exception 'I67 FALLO: con 65 $ por cubrir debía concentrar en la 5×: %', v_texto;
    end if;

    -- 3. Le faltan 100 $ (20 %): nada la cubre; la de más ganancia es A sola.
    update public.agentes set objetivo_diario_pct = 20 where id = v_ag;
    v_json := public.fn_decidir_agente(v_ag);
    select format('%s/%s/%s', v_json #>> '{reparto,modo}',
                  (select string_agg(x ->> 'simbolo', ' ') from jsonb_array_elements(v_json -> 'marcadas') x),
                  v_json #>> '{reparto,ganancia_objetivo}')
      into v_texto;
    if v_texto <> 'maxima_ganancia/zzexa/71.25' then
        raise exception 'I67 FALLO: con una meta inalcanzable debía concentrar en lo que más gana: %', v_texto;
    end if;

    -- 4. En cuarentena, como mucho una, aunque repartir cubriera la meta.
    update public.agentes set objetivo_diario_pct = 4, estado = 'cuarentena' where id = v_ag;
    v_json := public.fn_decidir_agente(v_ag);
    if jsonb_array_length(v_json -> 'marcadas') <> 1 then
        raise exception 'I67 FALLO: en cuarentena marcó % posiciones', jsonb_array_length(v_json -> 'marcadas');
    end if;

    -- 5. El ciclo abre las dos a la vez, con el saldo entero (margen 100 %
    --    aunque su estrategia diga 40) y una decisión de reparto por orden.
    update public.agentes set estado = 'activo' where id = v_ag;
    perform public.fn_sincronizar_dia_agente(v_ag, v_cuenta);
    update public.agente_dias set operable = true
     where agente_id = v_ag and fecha = (now() at time zone 'UTC')::date;
    perform public.fn_ciclo_agente(v_ag);
    select format('%s/%s/%s', posiciones_abiertas, margen_comprometido_max_pct, saldo_operar_en_uso)
      into v_texto from public.v_cuentas_equity where id = v_cuenta;
    if v_texto <> '2/100.00/2500.00'
       or (select count(*) from public.agente_decisiones
            where agente_id = v_ag and tipo = 'reparto' and parametro ->> 'modo' = 'cubre_meta') <> 2 then
        raise exception 'I67 FALLO: el ciclo debía abrir las dos y consumir los 2.500 $ del saldo: %', v_texto;
    end if;

    update public.activos set estado = 'suspendido' where id in (v_a, v_b);
    raise notice 'PASS  I67 los agentes marcan según la exigencia: reparten si les falta poco, concentran en la 5× si les falta mucho, una en cuarentena, y abren todas a la vez con el 100 %% del saldo';
end
$i67$;

-- ═════════════════════════════════════════════════════════════════════
-- I68 · Salida por deterioro de la señal (0024).
--
-- Un agente abre A y B. Una hora después, la nueva lectura de A ya no es
-- alcista y la de B sigue igual: en el ciclo siguiente cierra A al precio
-- vivo (motivo «deterioro»), deja B, y el saldo liberado vuelve al reparto
-- (C, una señal nueva, entra en ese mismo ciclo). Después A cae al stop:
-- cerrar evitó la pérdida y la decisión se resuelve con efecto positivo.
-- Con diez salidas que salieron mal, el agente la apaga.
-- ═════════════════════════════════════════════════════════════════════
do $i68$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_a      bigint;
    v_b      bigint;
    v_c      bigint;
    v_oa     bigint;
    v_texto  text;
    v_num    numeric;
    v_hoy    date := (now() at time zone 'UTC')::date;
begin
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('zzdea', 'cripto', 'coingecko', 'zzdea', 'activo', 100, now()),
        ('zzdeb', 'cripto', 'coingecko', 'zzdeb', 'activo', 100, now()),
        ('zzdec', 'cripto', 'coingecko', 'zzdec', 'activo', 100, now());
    select id into v_a from public.activos where simbolo = 'zzdea';
    select id into v_b from public.activos where simbolo = 'zzdeb';
    select id into v_c from public.activos where simbolo = 'zzdec';
    -- ATR del 9 %: ninguna otra señal del fichero entra en su universo.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, true, 5, 3, 's10', 100, 95, 110, 5, 'alcista', 'largo', 'alta', 'estructura', 9, 3, 0, now() - interval '2 hours'),
           (v_b, true, 5, 3, 's10', 100, 95, 110, 5, 'alcista', 'largo', 'alta', 'estructura', 9, 3, 0, now() - interval '2 hours');

    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-deterioro', 2, 'activo',
         '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["alta"], "niveles_origen_admitidos": ["estructura"],
           "atr_pct_min": 8.5, "rr_minimo": 1.5, "riesgo_pct_operacion": 2, "antiguedad_senal_max_min": 600}')
    returning id into v_ag;
    v_cuenta := public.fn_crear_cuenta_agente(v_ag);
    perform public.fn_sincronizar_dia_agente(v_ag, v_cuenta);
    update public.agente_dias set operable = true where agente_id = v_ag and fecha = v_hoy;
    perform public.fn_ciclo_agente(v_ag);
    if (select count(*) from public.ordenes where cuenta_id = v_cuenta and estado = 'abierta') <> 2 then
        raise exception 'I68 FALLO: el agente debía abrir A y B';
    end if;
    select id into v_oa from public.ordenes where cuenta_id = v_cuenta and activo_id = v_a;

    -- Una hora después: A deja de ser alcista, B sigue igual, aparece C.
    update public.ordenes set fecha_entrada = now() - interval '1 hour' where cuenta_id = v_cuenta;
    update public.activos set ultimo_precio = 102, ultimo_precio_en = now() where id in (v_a, v_b, v_c);
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, false, 5, 3, 's10', 102, null, null, null, 'bajista', 'sin_sesgo', 'alta', null, 9, 0, 3, now()),
           -- 0043: el deterioro tiene que verse en dos lecturas seguidas.
           (v_a, false, 5, 3, 's10', 102, null, null, null, 'bajista', 'sin_sesgo', 'alta', null, 9, 0, 3, now() - interval '30 minutes'),
           (v_b, true, 5, 3, 's10', 102, 97, 112, 5, 'alcista', 'largo', 'alta', 'estructura', 9, 3, 0, now()),
           (v_c, true, 5, 3, 's10', 102, 97, 112, 5, 'alcista', 'largo', 'alta', 'estructura', 9, 3, 0, now());
    perform public.fn_ciclo_agente(v_ag);

    select format('%s/%s/%s', o.motivo_cierre, o.precio_salida::numeric(10,2),
                  (select string_agg(a.simbolo, ',' order by a.simbolo)
                     from public.ordenes x join public.activos a on a.id = x.activo_id
                    where x.cuenta_id = v_cuenta and x.estado = 'abierta'))
      into v_texto from public.ordenes o where o.id = v_oa;
    if v_texto <> 'deterioro/102.00/zzdeb,zzdec' then
        raise exception 'I68 FALLO: debía cerrar A por deterioro a 102, dejar B y entrar en C: %', v_texto;
    end if;
    if not exists (select 1 from public.agente_decisiones
                    where agente_id = v_ag and tipo = 'deterioro' and orden_id = v_oa
                      and datos ->> 'motivo' = 'direccion') then
        raise exception 'I68 FALLO: la salida no dejó su decisión con el motivo';
    end if;

    -- A cae al stop: cerrar a 102 evitó perder (102 − 95) × cantidad.
    update public.activos set ultimo_precio = 94, ultimo_precio_en = now() + interval '1 second' where id = v_a;
    perform public.fn_resolver_decisiones();
    select efecto into v_num from public.agente_decisiones where agente_id = v_ag and tipo = 'deterioro';
    if v_num is null or v_num <= 0 then
        raise exception 'I68 FALLO: una salida que evitó el stop debía resolverse en positivo, dio %', v_num;
    end if;

    -- Diez salidas que salieron mal: la apaga, y apagada no cierra nada.
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_ag, 'deterioro', '{"salida_deterioro": true}', -5, now() + interval '1 second'
      from generate_series(1, 12);
    perform public.fn_ajustar_parametros(v_ag);
    if (select public.fn_parametros_agente(a) ->> 'salida_deterioro' from public.agentes a where id = v_ag) <> 'false' then
        raise exception 'I68 FALLO: con diez salidas en contra debía apagar salida_deterioro';
    end if;
    if public.fn_agente_salidas_deterioro(v_ag) <> 0 then
        raise exception 'I68 FALLO: con la salida apagada cerró posiciones';
    end if;

    update public.activos set estado = 'suspendido' where id in (v_a, v_b, v_c);
    raise notice 'PASS  I68 salida por deterioro: cierra la que dejó de ser alcista, deja la que sigue igual, el saldo liberado entra en otra, se juzga contra su contrafactual y se apaga si cuesta dinero';
end
$i68$;

-- ═════════════════════════════════════════════════════════════════════
-- I69 · Un ciclo de agente que falla deja aviso (0025).
--
-- Se rompe a propósito el ciclo de un agente de pruebas (un trigger que
-- rechaza su fila del día). Los demás siguen; queda UN aviso «fallo» con
-- el error aunque el ciclo corra dos veces; y al arreglarlo, un aviso de
-- que vuelve a funcionar.
-- ═════════════════════════════════════════════════════════════════════
create function public.zz_romper_ciclo() returns trigger language plpgsql as $f$
begin
    if new.agente_id = (select id from public.agentes where nombre = 'prueba-fallo') then
        raise exception 'fallo provocado por I69';
    end if;
    return new;
end $f$;
create trigger zz_romper_ciclo before insert or update on public.agente_dias
    for each row execute function public.zz_romper_ciclo();

do $i69$
declare
    v_ag     bigint;
    v_otro   bigint;
    v_ciclos int;
    v_texto  text;
begin
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
    values ('prueba-fallo', 2, 'activo', '{"clases_admitidas": ["cripto"]}')
    returning id into v_ag;
    perform public.fn_crear_cuenta_agente(v_ag);
    select id into v_otro from public.agentes where nombre = 'prueba-exigencia';
    select coalesce(sum(ciclos), 0) into v_ciclos from public.agente_dias where agente_id = v_otro;

    perform public.fn_ciclo_agentes();
    perform public.fn_ciclo_agentes();

    select string_agg(mensaje, ' | ') into v_texto from public.eventos_sistema
     where agente_id = v_ag and tipo = 'fallo';
    if v_texto is distinct from 'El ciclo de prueba-fallo falló: fallo provocado por I69' then
        raise exception 'I69 FALLO: el fallo debía dejar exactamente un aviso con el error, dejó: %', v_texto;
    end if;
    if (select coalesce(sum(ciclos), 0) from public.agente_dias where agente_id = v_otro) <> v_ciclos + 2 then
        raise exception 'I69 FALLO: el fallo de un agente frenó el ciclo de los demás';
    end if;

    drop trigger zz_romper_ciclo on public.agente_dias;
    perform public.fn_ciclo_agentes();
    perform public.fn_ciclo_agentes();
    if (select count(*) from public.eventos_sistema
         where agente_id = v_ag and tipo = 'agente' and datos ->> 'recuperado' = 'true') <> 1 then
        raise exception 'I69 FALLO: al recuperarse debía quedar un único aviso de que vuelve a funcionar';
    end if;
    if has_function_privilege('authenticated', 'public.fn_registrar_fallo(bigint, text, text, text, text)', 'EXECUTE') then
        raise exception 'I69 FALLO: authenticated puede registrar fallos';
    end if;

    update public.agentes set estado = 'pausado' where id = v_ag;
    raise notice 'PASS  I69 un ciclo que falla deja un aviso por hora con el error, no frena a los demás, y la recuperación también se avisa';
end
$i69$;
drop function public.zz_romper_ciclo();

-- ═════════════════════════════════════════════════════════════════════
-- I70 · Prudencia admite la fuerza media (0026, D18).
--
-- Dos acciones que pasan todo lo demás de su perfil (estructura, R:R 2,5,
-- ATR 2 %): una de fuerza media, que ahora es candidata, y otra de fuerza
-- baja, que sigue fuera. El cambio queda versionado.
-- ═════════════════════════════════════════════════════════════════════
do $i70$
declare
    v_ag    public.agentes;
    v_media bigint;
    v_baja  bigint;
    v_texto text;
begin
    select * into v_ag from public.agentes where nombre = 'Prudencia';
    if not (v_ag.estrategia -> 'fuerzas_admitidas' @> '["media", "alta"]'::jsonb) then
        raise exception 'I70 FALLO: la estrategia de Prudencia no admite media y alta: %',
            v_ag.estrategia -> 'fuerzas_admitidas';
    end if;
    if not exists (select 1 from public.agente_estrategia_versiones
                    where agente_id = v_ag.id and version < v_ag.version_estrategia
                      and estrategia -> 'fuerzas_admitidas' = '["alta"]'::jsonb) then
        raise exception 'I70 FALLO: la versión anterior (solo alta) no quedó en el histórico';
    end if;

    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('ZZPMED', 'accion', 'yahoo', 'ZZPMED', 'activo', 10, now()),
        ('ZZPBAJ', 'accion', 'yahoo', 'ZZPBAJ', 'activo', 10, now());
    select id into v_media from public.activos where simbolo = 'ZZPMED';
    select id into v_baja  from public.activos where simbolo = 'ZZPBAJ';
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values
        (v_media, true, 5, 3, 'i70', 10, 9.6, 11, 4, 'alcista', 'largo', 'media', 'estructura', 2, 2, 0, now()),
        (v_baja,  true, 5, 3, 'i70', 10, 9.6, 11, 3, 'alcista', 'largo', 'baja',  'estructura', 2, 1, 0, now());

    select string_agg(simbolo || '=' || coalesce(motivo, 'candidata'), ',' order by simbolo) into v_texto
      from public.fn_universo_agente(public.fn_parametros_agente(v_ag),
                                     public.fn_cuenta_agente(v_ag.id), '[]'::jsonb)
     where simbolo in ('ZZPMED', 'ZZPBAJ');
    if v_texto is distinct from 'ZZPBAJ=fuerza,ZZPMED=candidata' then
        raise exception 'I70 FALLO: Prudencia debería admitir la media y descartar la baja: %', v_texto;
    end if;

    delete from public.activos where id in (v_media, v_baja);
    raise notice 'PASS  I70 Prudencia admite fuerza media y sigue descartando la baja; la versión anterior queda en el histórico';
end
$i70$;

-- ═════════════════════════════════════════════════════════════════════
-- I71 · Cadencia y Audacia se separan por volatilidad (0027, D19).
--
-- El mismo corte, 2,3 % de ATR, es el techo de Cadencia y el suelo de
-- Audacia. Dos acciones que pasan todo lo demás de los dos perfiles, una
-- con ATR 2 % y otra con 2,6 %: cada una es candidata de un solo agente.
-- ═════════════════════════════════════════════════════════════════════
do $i71$
declare
    v_cad   public.agentes;
    v_auda  public.agentes;
    v_texto text;
begin
    select * into v_cad  from public.agentes where nombre = 'Cadencia';
    select * into v_auda from public.agentes where nombre = 'Audacia';
    if (public.fn_parametros_agente(v_cad) ->> 'atr_pct_max')::numeric is distinct from 2.3
       or (public.fn_parametros_agente(v_auda) ->> 'atr_pct_min')::numeric is distinct from 2.3 then
        raise exception 'I71 FALLO: el corte no es el mismo 2,3 %%: Cadencia ≤ %, Audacia ≥ %',
            public.fn_parametros_agente(v_cad) ->> 'atr_pct_max',
            public.fn_parametros_agente(v_auda) ->> 'atr_pct_min';
    end if;

    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en) values
        ('ZZTRAN', 'accion', 'yahoo', 'ZZTRAN', 'activo', 10, now()),
        ('ZZMOVI', 'accion', 'yahoo', 'ZZMOVI', 'activo', 10, now());
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    select a.id, true, 5, 3, 'i71', 10, 9.6, 11, 4, 'alcista', 'largo', 'media', 'estructura', v.atr, 2, 0, now()
      from (values ('ZZTRAN', 2.0), ('ZZMOVI', 2.6)) v(simbolo, atr)
      join public.activos a on a.simbolo = v.simbolo;

    select string_agg(g.nombre || ':' || u.simbolo || '=' || coalesce(u.motivo, 'candidata'), ','
                      order by g.nombre, u.simbolo) into v_texto
      from (values (v_cad), (v_auda)) x(ag)
      cross join lateral (select (x.ag).nombre) g(nombre)
      cross join lateral public.fn_universo_agente(public.fn_parametros_agente(x.ag),
                                                   public.fn_cuenta_agente((x.ag).id), '[]'::jsonb) u
     where u.simbolo in ('ZZTRAN', 'ZZMOVI');
    if v_texto is distinct from
       'Audacia:ZZMOVI=candidata,Audacia:ZZTRAN=atr_bajo,Cadencia:ZZMOVI=atr_alto,Cadencia:ZZTRAN=candidata' then
        raise exception 'I71 FALLO: cada acción debería ser de un solo agente: %', v_texto;
    end if;

    delete from public.activos where simbolo in ('ZZTRAN', 'ZZMOVI');
    raise notice 'PASS  I71 el ATR separa a Cadencia (≤ 2,3 %%) de Audacia (≥ 2,3 %%): cada señal es de uno solo';
end
$i71$;

-- ═════════════════════════════════════════════════════════════════════
-- I72 · Las cuotas cuentan el universo del ETL (0029, D20).
--
-- El ETL procesa todo el catálogo activo, lo siga alguien o no, así que
-- el tope de 20 criptos (CoinGecko) cuenta también las que nadie sigue:
-- con 20 en el universo, una cripto nueva se rechaza aunque ninguna tenga
-- seguidores; seguir una que ya está dentro no cuesta hueco. Un suspendido
-- que nadie sigue está fuera del universo.
-- ═════════════════════════════════════════════════════════════════════
do $i72$
declare
    v_u     uuid := gen_random_uuid();
    v_n     int;
    v_texto text;
begin
    if not public.fn_en_universo_etl('activo', 0) or not public.fn_en_universo_etl('pendiente_backfill', 0)
       or public.fn_en_universo_etl('suspendido', 0) or not public.fn_en_universo_etl('suspendido', 2)
       or public.fn_en_universo_etl('invalido', 5) then
        raise exception 'I72 FALLO: fn_en_universo_etl no describe el universo del ETL';
    end if;

    insert into auth.users (id, email, email_confirmed_at) values (v_u, 'cuota-universo@ejemplo.com', now());
    update public.perfiles set estado = 'aprobado' where id = v_u;

    -- Se llena el universo de cripto hasta 20 con criptos que nadie sigue.
    select count(*) into v_n from public.activos
     where clase = 'cripto' and public.fn_en_universo_etl(estado, seguidores);
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
    select 'zzu-' || i, 'cripto', 'coingecko', 'zzu-' || i, 'activo'
      from generate_series(1, greatest(0, 20 - v_n)) i;
    insert into public.catalogo_coingecko (id, simbolo, nombre)
    values ('zzu-nueva', 'zzun', 'Nueva de I72'), ('zzu-1', 'zzu1', 'Llena de I72')
    on conflict (id) do nothing;

    perform pg_temp.como(v_u);
    begin
        perform public.rpc_solicitar_activo('cripto', 'zzu-nueva');
        v_texto := null;
    exception when raise_exception then
        v_texto := sqlerrm;
    end;
    perform pg_temp.como_dueno();
    if v_texto is null or v_texto not like '%criptomonedas distintas y el límite es 20%' then
        raise exception 'I72 FALLO: con 20 criptos en el universo (sin seguidores) se aceptó una nueva (%)', v_texto;
    end if;

    if exists (select 1 from public.activos where simbolo = 'zzu-1') then
        perform pg_temp.como(v_u);
        perform public.rpc_solicitar_activo('cripto', 'zzu-1');
        perform pg_temp.como_dueno();
        if (select seguidores from public.activos where simbolo = 'zzu-1') <> 1 then
            raise exception 'I72 FALLO: seguir una cripto que ya está en el universo debía costar cero';
        end if;
    end if;

    delete from public.cartera_activos where activo_id in (select id from public.activos where simbolo like 'zzu-%');
    delete from public.activos where simbolo like 'zzu-%';
    delete from public.catalogo_coingecko where id like 'zzu-%';
    raise notice 'PASS  I72 las cuotas cuentan el universo del ETL: 20 criptos sin seguidores llenan el tope; seguir una de dentro no cuesta';
end
$i72$;

-- ═════════════════════════════════════════════════════════════════════
-- I73 · La apertura no es una señal añeja (0029).
--
-- De 9:30 a 9:45 de Nueva York la acción espera su primera lectura de la
-- sesión; antes y después, no. Lunes 5 de octubre de 2026 (EDT, UTC-4).
-- ═════════════════════════════════════════════════════════════════════
do $i73$
begin
    if not public.fn_esperando_apertura('2026-10-05 13:35+00')
       or public.fn_esperando_apertura('2026-10-05 13:25+00')       -- aún cerrado
       or public.fn_esperando_apertura('2026-10-05 13:50+00')       -- pasado el margen
       or public.fn_esperando_apertura('2026-10-03 13:35+00') then  -- sábado
        raise exception 'I73 FALLO: el margen de apertura no es 9:30–9:45 NY en día de bolsa';
    end if;
    if position('fn_esperando_apertura' in pg_get_functiondef(
           'public.fn_universo_agente(jsonb, bigint, jsonb)'::regprocedure)) = 0 then
        raise exception 'I73 FALLO: el universo de los agentes no aplica el margen de apertura';
    end if;
    raise notice 'PASS  I73 de 9:30 a 9:45 NY una acción espera su primera lectura: no cuenta como añeja';
end
$i73$;

-- ═════════════════════════════════════════════════════════════════════
-- I74 · El backlog mide lo que dice y reabre lo resuelto (0029).
--
-- «Ampliar el universo» cuenta solo ciclos con señales frescas y sin
-- candidatas. Y una ocurrencia nueva (otro día) de una petición dada por
-- implementada la reabre, conservando la resolución anterior.
-- ═════════════════════════════════════════════════════════════════════
do $i74$
declare
    v_ag    bigint;
    v_dia   public.agente_dias;
    v_b     public.agente_backlog;
begin
    select agente_id into v_ag from public.agente_dias limit 1;
    select * into v_dia from public.agente_dias where agente_id = v_ag limit 1;

    -- Ciclo con universo y sin candidatas: cuenta.
    update public.agente_dias
       set ciclos = ciclos + 1, ciclos_con_universo = ciclos_con_universo + 1,
           ciclos_sin_candidatos = ciclos_sin_candidatos + 1
     where agente_id = v_dia.agente_id and fecha = v_dia.fecha;
    -- Ciclo con bolsa cerrada (sin universo) y sin candidatas: no cuenta.
    update public.agente_dias
       set ciclos = ciclos + 1, ciclos_sin_candidatos = ciclos_sin_candidatos + 1
     where agente_id = v_dia.agente_id and fecha = v_dia.fecha;
    if (select ciclos_universo_sin_candidatos from public.agente_dias
         where agente_id = v_dia.agente_id and fecha = v_dia.fecha)
       <> v_dia.ciclos_universo_sin_candidatos + 1 then
        raise exception 'I74 FALLO: el contador de ciclos con universo y sin candidatas no cuadra';
    end if;

    perform public.fn_registrar_backlog(v_ag, 'ajuste_regla', 'ajuste_regla:i74', 'Petición de I74',
                                        'd', 'j', '{"i74": 1}', 3);
    update public.agente_backlog set estado = 'implementado', resolucion = 'Hecho en la 9999'
     where clave_deduplicacion = 'ajuste_regla:i74';
    -- El mismo día no cuenta como ocurrencia nueva: sigue cerrada.
    perform public.fn_registrar_backlog(v_ag, 'ajuste_regla', 'ajuste_regla:i74', 'Petición de I74',
                                        'd', 'j', '{"i74": 2}', 3);
    if (select estado from public.agente_backlog where clave_deduplicacion = 'ajuste_regla:i74') <> 'implementado' then
        raise exception 'I74 FALLO: la misma petición del mismo día reabrió la entrada';
    end if;
    -- Otro día (se borra la ocurrencia de hoy para simularlo): se reabre.
    delete from public.agente_backlog_ocurrencias
     where backlog_id = (select id from public.agente_backlog where clave_deduplicacion = 'ajuste_regla:i74');
    perform public.fn_registrar_backlog(v_ag, 'ajuste_regla', 'ajuste_regla:i74', 'Petición de I74',
                                        'd', 'j', '{"i74": 3}', 3);
    select * into v_b from public.agente_backlog where clave_deduplicacion = 'ajuste_regla:i74';
    if v_b.estado <> 'nuevo' or v_b.ocurrencias <> 2
       or v_b.resolucion not like 'Reabierta el %Antes, implementado: Hecho en la 9999' then
        raise exception 'I74 FALLO: la ocurrencia nueva no reabrió la entrada como se esperaba: % / % / %',
            v_b.estado, v_b.ocurrencias, v_b.resolucion;
    end if;
    if not exists (select 1 from public.eventos_sistema
                    where tipo = 'backlog_nuevo' and (datos ->> 'reabierta')::boolean
                      and (datos ->> 'backlog_id')::bigint = v_b.id) then
        raise exception 'I74 FALLO: la reapertura no dejó su evento';
    end if;

    delete from public.agente_backlog where id = v_b.id;
    raise notice 'PASS  I74 «Ampliar el universo» cuenta solo ciclos con señales frescas; una ocurrencia nueva reabre lo resuelto y conserva la resolución';
end
$i74$;

-- ═════════════════════════════════════════════════════════════════════
-- I75 · El R:R mínimo de cada agente cabe en la escala nueva (0030).
--
-- Desde el 2026-10-10 el motor acota SL y TP en ATR: el R:R de una señal
-- va como mucho hasta 2 (TP_MAX_ATR / SL_MIN_ATR en indicadores/
-- tecnicos.py). Un agente que exija 2 o más no opera nunca, y ser prudente
-- no puede ser no operar. Y ninguna práctica viva puede filtrar por R:R:
-- las que había se destilaron sobre la escala vieja.
-- ═════════════════════════════════════════════════════════════════════
do $i75$
declare
    v_r record;
begin
    for v_r in select a.nombre, (public.fn_parametros_agente(a) ->> 'rr_minimo')::numeric as rr
                 from public.agentes a
    loop
        if v_r.rr >= 2 then
            raise exception 'I75 FALLO: % exige R:R % y el motor no emite más de 2', v_r.nombre, v_r.rr;
        end if;
    end loop;
    if (select array_agg((public.fn_parametros_agente(a) ->> 'rr_minimo')::numeric order by a.id)
          from public.agentes a where a.nombre in ('Prudencia', 'Cadencia', 'Audacia'))
       <> array[1.5, 1.3, 1.2]::numeric[] then
        raise exception 'I75 FALLO: el R:R mínimo de Prudencia, Cadencia y Audacia no es 1,5 · 1,3 · 1,2';
    end if;
    if (select ratio_rr_minimo from public.cuentas_simulacion c
          join public.agentes a on a.id = c.agente_id
         where a.nombre = 'Prudencia' and c.estado <> 'game_over' limit 1) <> 1.5 then
        raise exception 'I75 FALLO: la cuenta de Prudencia no recibió el R:R mínimo nuevo';
    end if;
    raise notice 'PASS  I75 el R:R mínimo de cada agente cabe en la escala acotada en ATR (máximo 2)';
end
$i75$;

-- ═════════════════════════════════════════════════════════════════════
-- I76 · Riesgo abierto total, G6 (0030).
--
-- Un agente con riesgo del 2 % y 500 $ puede tener a la vez como mucho
-- 4 × 2 % = 40 $ en juego. Seis criptos con el stop al 10 %: sin G6, el
-- saldo le dejaría abrir las seis (60 $ en juego). La decisión reparte el
-- riesgo libre entre las que marca, el ciclo no pasa de 40 $, la decisión
-- siguiente dice `riesgo_lleno`, y una orden insertada a mano por encima
-- la rechaza la base de datos.
-- ═════════════════════════════════════════════════════════════════════
do $i76$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_json   jsonb;
    v_riesgo numeric;
    v_act    bigint;
    v_i      int;
begin
    for v_i in 1 .. 6 loop
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
        values ('zzg6' || v_i, 'cripto', 'coingecko', 'zzg6' || v_i, 'activo', 100, now())
        returning id into v_act;
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
             precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
             niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
        values (v_act, true, 5, 3, 's9', 100, 90, 115, 5, 'alcista', 'largo', 'alta',
                'estructura', 9.5, 3, 0, now());
    end loop;

    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-g6', 20, 'activo',
         '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["alta"], "niveles_origen_admitidos": ["estructura"],
           "atr_pct_min": 9.2, "rr_minimo": 1.2, "riesgo_pct_operacion": 2}')
    returning id into v_ag;
    v_cuenta := public.fn_crear_cuenta_agente(v_ag);

    -- 1. La decisión no propone más de 40 $ en juego entre sus marcadas.
    v_json := public.fn_decidir_agente(v_ag);
    select sum((x ->> 'riesgo_stop')::numeric) into v_riesgo
      from jsonb_array_elements(v_json -> 'marcadas') x;
    if v_json ->> 'accion' <> 'abrir' or v_riesgo > 40.01 or (v_json ->> 'riesgo_abierto_max')::numeric <> 40 then
        raise exception 'I76 FALLO: la decisión debía repartir como mucho 40 $ de riesgo: % · % $ · máx %',
              v_json ->> 'accion', v_riesgo, v_json ->> 'riesgo_abierto_max';
    end if;

    -- 2. El ciclo abre y el riesgo abierto queda en el límite, no por encima.
    perform public.fn_sincronizar_dia_agente(v_ag, v_cuenta);
    update public.agente_dias set operable = true
     where agente_id = v_ag and fecha = (now() at time zone 'UTC')::date;
    perform public.fn_ciclo_agente(v_ag);
    v_riesgo := public.fn_riesgo_abierto(v_cuenta);
    if v_riesgo > 40.01 or v_riesgo < 30 then
        raise exception 'I76 FALLO: tras el ciclo el riesgo abierto es % $ (límite 40 $)', v_riesgo;
    end if;

    -- 3. Con el riesgo lleno no propone nada nuevo.
    if public.fn_decidir_agente(v_ag) ->> 'accion' not in ('riesgo_lleno', 'saldo_lleno', 'sin_candidatos') then
        raise exception 'I76 FALLO: con el riesgo abierto lleno la decisión fue %',
              public.fn_decidir_agente(v_ag) ->> 'accion';
    end if;

    -- 4. Una orden a mano por encima del límite la rechaza PostgreSQL (G6).
    begin
        insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
             cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
        values (v_cuenta, v_act, 'agente', 100, now(), 2, 5, 40, 115, 90, 80);
        raise exception 'I76 FALLO: G6 dejó insertar una orden con 20 $ más de riesgo';
    exception when sqlstate 'P0001' then
        if sqlerrm not like 'G6:%' then raise; end if;
    end;

    update public.activos set estado = 'suspendido' where simbolo like 'zzg6%';
    update public.agentes set estado = 'pausado' where id = v_ag;
    raise notice 'PASS  I76 riesgo abierto total: la decisión reparte el riesgo libre, el ciclo no pasa de 4 × el riesgo por operación y G6 rechaza lo que se salga';
end
$i76$;

-- ═════════════════════════════════════════════════════════════════════
-- I77 · El calendario de mercados (0031).
--
-- La NYSE: abierta un viernes a las 15:30 con 30 minutos por delante;
-- cerrada el sábado, con la próxima apertura el lunes a las 9:30; cerrada
-- en Acción de Gracias; 4 sesiones esa semana. La cripto, siempre abierta.
-- ═════════════════════════════════════════════════════════════════════
do $i77$
begin
    if not public.fn_sesion_abierta('nyse', '2026-10-09 15:30 America/New_York')
       or public.fn_minutos_restantes_sesion('nyse', '2026-10-09 15:30 America/New_York') <> 30 then
        raise exception 'I77 FALLO: el viernes a las 15:30 la NYSE está abierta y le quedan 30 minutos';
    end if;
    if public.fn_sesion_abierta('nyse', '2026-10-09 16:00 America/New_York') then
        raise exception 'I77 FALLO: a las 16:00 la NYSE ya ha cerrado';
    end if;
    if public.fn_sesion_abierta('nyse', '2026-10-10 12:00 America/New_York')
       or public.fn_proxima_apertura('nyse', '2026-10-10 12:00 America/New_York')
          <> '2026-10-12 09:30 America/New_York'::timestamptz then
        raise exception 'I77 FALLO: el sábado está cerrada y abre el lunes a las 9:30';
    end if;
    if public.fn_sesion_abierta('nyse', '2026-11-26 11:00 America/New_York')
       or public.fn_proxima_apertura('nyse', '2026-11-26 11:00 America/New_York')
          <> '2026-11-27 09:30 America/New_York'::timestamptz then
        raise exception 'I77 FALLO: Acción de Gracias es festivo y la próxima sesión es el viernes';
    end if;
    if public.fn_sesiones_entre('nyse', '2026-11-23', '2026-11-29') <> 4
       or public.fn_sesiones_entre('cripto', '2026-11-23', '2026-11-29') <> 7 then
        raise exception 'I77 FALLO: la semana de Acción de Gracias tiene 4 sesiones de bolsa y 7 de cripto';
    end if;
    if not public.fn_sesion_abierta('cripto', '2026-10-10 23:59 UTC')
       or public.fn_minutos_restantes_sesion('cripto', '2026-10-10 23:00 UTC') <> 60 then
        raise exception 'I77 FALLO: la cripto está siempre abierta';
    end if;
    if public.fn_mercado_de_clase('accion') <> 'nyse' or public.fn_mercado_de_clase('cripto') <> 'cripto' then
        raise exception 'I77 FALLO: cada clase de activo tiene su mercado';
    end if;
    raise notice 'PASS  I77 calendario de mercados: sesiones, festivos, minutos restantes y próxima apertura';
end
$i77$;

-- ═════════════════════════════════════════════════════════════════════
-- I78 · Cada orden nace con su estimación y su régimen; el recorrido se
-- mide en el tiempo (0031).
--
-- Entrada 100, objetivo 104, stop 98, ATR del 2 %: el objetivo está a
-- 2 ATR y el stop a 1, así que unas 2 sesiones y p = 1/3. Al observar
-- precios se guardan el mejor y el peor, y cuándo.
-- ═════════════════════════════════════════════════════════════════════
do $i78$
declare
    v_act    bigint;
    v_senal  bigint;
    v_cuenta bigint;
    v_orden  public.ordenes;
begin
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzest', 'cripto', 'coingecko', 'zzest', 'activo', 100, now()) returning id into v_act;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_act, true, 5, 3, 's9', 100, 98, 104, 3, 'alcista', 'largo', 'media', 'estructura', 2, 2, 0, now())
    returning id into v_senal;
    select c.id into v_cuenta from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id
     where a.nombre = 'Cadencia' and c.estado <> 'game_over';

    insert into public.ordenes (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_act, v_senal, 'agente', 100, now(), 0.1, 1, 10, 104, 98, 1)
    returning * into v_orden;
    if v_orden.horizonte_estimado_sesiones <> 2 or v_orden.p_estimada <> 0.3333
       or v_orden.regimen is null or not (v_orden.regimen ? 'clases') then
        raise exception 'I78 FALLO: la orden debía nacer con 2 sesiones, p = 0,3333 y su régimen: % / % / %',
              v_orden.horizonte_estimado_sesiones, v_orden.p_estimada, v_orden.regimen;
    end if;

    update public.activos set ultimo_precio = 102, ultimo_precio_en = now() where id = v_act;
    perform public.fn_agentes_observar_precios();
    update public.activos set ultimo_precio = 99, ultimo_precio_en = now() where id = v_act;
    perform public.fn_agentes_observar_precios();
    select * into v_orden from public.ordenes where id = v_orden.id;
    if v_orden.precio_max_visto <> 102 or v_orden.precio_max_visto_en is null
       or v_orden.precio_min_visto <> 99 or v_orden.precio_min_visto_en is null then
        raise exception 'I78 FALLO: debía guardar el mejor (102) y el peor (99) con su momento: % % / % %',
              v_orden.precio_max_visto, v_orden.precio_max_visto_en, v_orden.precio_min_visto, v_orden.precio_min_visto_en;
    end if;

    perform public.fn_registrar_movimiento(v_cuenta, v_orden.id, 'bloqueo_margen', -10, 10);
    perform public.rpc_cerrar_orden(v_orden.id, 99, 'manual', 99);
    update public.activos set estado = 'suspendido' where id = v_act;
    raise notice 'PASS  I78 cada orden nace con su horizonte, su probabilidad y su régimen; se guardan el mejor y el peor precio, y cuándo';
end
$i78$;

-- ═════════════════════════════════════════════════════════════════════
-- I79 · Régimen de las prácticas, plan de la semana y huecos (0031).
-- ═════════════════════════════════════════════════════════════════════
do $i79$
declare
    v_act   bigint;
    v_plan  record;
    v_hueco record;
begin
    -- Una práctica nueva guarda el régimen de mercado del momento.
    insert into public.mejores_practicas (agente_autor_id, firma, titulo, contexto, regla, condiciones,
                                          resultado_observado, confianza, estado, sentido)
    select a.id, 'i79', 't', 'c', 'r', '{"clase": "cripto"}', '{"ops": 3}', 0.7, 'archivada', 'exigir'
      from public.agentes a where a.nombre = 'Audacia';
    if (select regimen is null or not (regimen ? 'clases') from public.mejores_practicas where firma = 'i79') then
        raise exception 'I79 FALLO: la práctica no guardó el régimen de mercado';
    end if;
    delete from public.mejores_practicas where firma = 'i79';

    -- El plan de la semana: meta compuesta sobre las sesiones de su mercado.
    select * into v_plan from public.v_agentes_plan where nombre = 'Audacia';
    if v_plan.sesiones_semana <> 7
       or v_plan.meta_semana <> round(v_plan.saldo_lunes * (power(1 + v_plan.objetivo_diario_pct / 100, 7) - 1), 2)
       or v_plan.falta_semana <> v_plan.meta_semana - v_plan.pnl_semana
       or jsonb_array_length(v_plan.mercados) <> 2 then
        raise exception 'I79 FALLO: el plan de Audacia no cuadra: %', row_to_json(v_plan);
    end if;
    -- Un agente que solo opera acciones: su semana son las sesiones de la
    -- NYSE. (Prudencia lo era hasta la 0032; ahora también opera cripto.)
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
    values ('prueba-plan', 2, 'pausado', '{"clases_admitidas": ["accion"]}') returning id into v_act;
    perform public.fn_crear_cuenta_agente(v_act);
    if (select sesiones_semana from public.v_agentes_plan where nombre = 'prueba-plan')
       <> public.fn_sesiones_entre('nyse', v_plan.lunes, v_plan.lunes + 6) then
        raise exception 'I79 FALLO: la semana de un agente solo de acciones son las sesiones de la NYSE';
    end if;

    -- Huecos: un lunes que abre un 3 % por debajo del cierre del viernes.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
    values ('ZZHUECO', 'accion', 'yahoo', 'ZZHUECO', 'activo') returning id into v_act;
    insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, origen)
    select v_act, d::date, 100, 101, 99, 100, 'yahoo'
      from generate_series(current_date - 30, current_date - 1, interval '1 day') d
     where extract(isodow from d) between 1 and 5;
    update public.precios_diarios set apertura = 97
     where activo_id = v_act
       and fecha = (select max(fecha) from public.precios_diarios where activo_id = v_act and extract(isodow from fecha) = 1);
    insert into public.senales (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor, atr_pct)
    values (v_act, false, 5, 3, 's9', 2);
    select * into v_hueco from public.v_huecos_activos where activo_id = v_act;
    if v_hueco.caida_max_pct <> 3 or v_hueco.lunes < 1 or v_hueco.caida_p90_lunes_pct <= 0 then
        raise exception 'I79 FALLO: el hueco del lunes no se midió: %', row_to_json(v_hueco);
    end if;
    update public.activos set estado = 'suspendido' where id = v_act;
    raise notice 'PASS  I79 las prácticas guardan su régimen, el plan de la semana cuadra y los huecos de apertura se miden';
end
$i79$;

-- ═════════════════════════════════════════════════════════════════════
-- I80 · Autodiagnóstico semanal (0031).
--
-- Un agente de pruebas con 15 cierres en el stop, ninguno en el objetivo,
-- stops a 0,1 ATR y todas sus entradas con un voto en contra: el
-- autodiagnóstico pide «objetivos», «stops» y «votos», con evidencia. Un
-- segundo pase el mismo día no duplica nada.
-- ═════════════════════════════════════════════════════════════════════
do $i80$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_act    bigint;
    v_senal  bigint;
    v_orden  bigint;
    v_n      int;
begin
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
    values ('prueba-diagnostico', 5, 'pausado', '{"clases_admitidas": ["cripto"]}') returning id into v_ag;
    v_cuenta := public.fn_crear_cuenta_agente(v_ag);
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzdiag', 'cripto', 'coingecko', 'zzdiag', 'activo', 100, now()) returning id into v_act;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_act, true, 5, 3, 's9', 100, 99.8, 116, 3, 'alcista', 'largo', 'media', 'estructura', 2, 2, 1, now())
    returning id into v_senal;

    for i in 1 .. 15 loop
        insert into public.ordenes (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
             cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
        values (v_cuenta, v_act, v_senal, 'agente', 100, now(), 0.1, 1, 10, 116, 99.8, 1)
        returning id into v_orden;
        perform public.fn_registrar_movimiento(v_cuenta, v_orden, 'bloqueo_margen', -10, 10);
        perform public.rpc_cerrar_orden(v_orden, 99.8, 'sl', 99.7);
    end loop;

    v_n := public.fn_autodiagnostico_agente(v_ag);
    if v_n < 3
       or (select count(*) from public.agente_backlog
            where clave_deduplicacion in ('diagnostico:objetivos:agente_' || v_ag,
                                          'diagnostico:stops:agente_' || v_ag,
                                          'diagnostico:votos:agente_' || v_ag)
              and evidencia ? 'ordenes') <> 3 then
        raise exception 'I80 FALLO: el autodiagnóstico debía pedir objetivos, stops y votos con evidencia (pidió %)', v_n;
    end if;
    if (select descripcion from public.agente_backlog
         where clave_deduplicacion = 'diagnostico:objetivos:agente_' || v_ag) not like '15 cierres en 14 días, ninguno en el objetivo y 15 en el stop%' then
        raise exception 'I80 FALLO: la petición de objetivos no describe la evidencia';
    end if;

    perform public.fn_autodiagnostico_agente(v_ag);
    if (select max(ocurrencias) from public.agente_backlog where clave_deduplicacion like 'diagnostico:%:agente_' || v_ag) <> 1 then
        raise exception 'I80 FALLO: un segundo pase el mismo día no debe sumar ocurrencias';
    end if;
    if not exists (select 1 from public.eventos_sistema
                    where agente_id = v_ag and (datos ->> 'autodiagnostico')::int >= 3) then
        raise exception 'I80 FALLO: el autodiagnóstico no dejó constancia en el registro';
    end if;

    delete from public.agente_backlog where clave_deduplicacion like 'diagnostico:%:agente_' || v_ag;
    update public.activos set estado = 'suspendido' where id = v_act;
    raise notice 'PASS  I80 el autodiagnóstico semanal pide, con evidencia, lo que una revisión externa descubrió: objetivos, stops y votos';
end
$i80$;

-- ═════════════════════════════════════════════════════════════════════
-- I81 · Cripto prudente: riesgo escalado por volatilidad y riesgo abierto
-- por mercado (0032).
--
-- Un agente con riesgo del 2 % (10 $ sobre 500 $), referencia de ATR 3 en
-- cripto y como mucho 1 × su riesgo abierto en cripto. Tres criptos:
--   A  ATR 3,05 → factor 0,98
--   B  ATR 6,05 → factor 0,50
--   D  ATR 12   → factor 0,25: con 2,5 $ de riesgo y el stop a 1 ATR no
--      llega a 10 $ de margen → descarte `riesgo_escalado`
-- Entre todas las cripto que marca no arriesga más de 10 $; una vez
-- abiertas, otra cripto cae por `riesgo_clase_lleno`; y si eso se repite,
-- el autodiagnóstico pide ampliar el riesgo.
-- ═════════════════════════════════════════════════════════════════════
do $i81$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_json   jsonb;
    v_act    bigint;
    v_n      numeric;
    v_x      record;
begin
    for v_x in select * from (values ('zzpa', 3.05, 97.0, 106.0, 3.0), ('zzpb', 6.05, 94.0, 112.0, 3.0),
                                     ('zzpd', 12.0, 88.0, 124.0, 3.0)) t(sim, atr, sl, tp, lev)
    loop
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
        values (v_x.sim, 'cripto', 'coingecko', v_x.sim, 'activo', 100, now()) returning id into v_act;
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
             precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
             niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
        values (v_act, true, 5, 2, 's9', 100, v_x.sl, v_x.tp, v_x.lev, 'alcista', 'largo', 'alta',
                'estructura', v_x.atr, 3, 0, now());
    end loop;

    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-cripto-prudente', 20, 'activo',
         '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["alta"], "niveles_origen_admitidos": ["estructura"],
           "rr_minimo": 1.5, "riesgo_pct_operacion": 2,
           "por_clase": {"cripto": {"atr_pct_min": 3, "atr_pct_max": 12.5,
                                    "riesgo_atr_ref": 3, "riesgo_abierto_mult": 1}}}')
    returning id into v_ag;
    v_cuenta := public.fn_crear_cuenta_agente(v_ag);

    -- 1. Factores, descarte por riesgo escalado y tope del mercado.
    v_json := public.fn_decidir_agente(v_ag);
    if (select (c ->> 'factor_riesgo')::numeric from jsonb_array_elements(v_json -> 'candidatos') c
         where c ->> 'simbolo' = 'zzpb') <> 0.4959
       or (select c ->> 'descarte' from jsonb_array_elements(v_json -> 'candidatos') c
            where c ->> 'simbolo' = 'zzpd') <> 'riesgo_escalado'
       or coalesce((v_json #>> '{descartes_por_motivo,riesgo_escalado}')::int, 0) <> 1 then
        raise exception 'I81 FALLO: factores o descarte por riesgo escalado inesperados: %', v_json -> 'candidatos';
    end if;
    select sum((x ->> 'riesgo_stop')::numeric) into v_n from jsonb_array_elements(v_json -> 'marcadas') x;
    if v_json ->> 'accion' <> 'abrir' or v_n > 10.01 then
        raise exception 'I81 FALLO: entre sus cripto debía arriesgar como mucho 10 $: % · %', v_json ->> 'accion', v_n;
    end if;

    -- 2. Abre, y el riesgo abierto en cripto no pasa de 1 × su riesgo.
    perform public.fn_sincronizar_dia_agente(v_ag, v_cuenta);
    update public.agente_dias set operable = true
     where agente_id = v_ag and fecha = (now() at time zone 'UTC')::date;
    perform public.fn_ciclo_agente(v_ag);
    v_n := public.fn_riesgo_abierto_clase(v_cuenta, 'cripto');
    if v_n > 10.01 or v_n < 5 then
        raise exception 'I81 FALLO: riesgo abierto en cripto de % $ (tope 10 $)', v_n;
    end if;

    -- 3. Con el mercado lleno, una cripto nueva cae por riesgo_clase_lleno.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzpc', 'cripto', 'coingecko', 'zzpc', 'activo', 100, now()) returning id into v_act;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_act, true, 5, 2, 's9', 100, 96, 108, 3, 'alcista', 'largo', 'alta', 'estructura', 4, 3, 0, now());
    v_json := public.fn_decidir_agente(v_ag);
    if (select c ->> 'descarte' from jsonb_array_elements(v_json -> 'candidatos') c
         where c ->> 'simbolo' = 'zzpc') <> 'riesgo_clase_lleno' then
        raise exception 'I81 FALLO: con el riesgo cripto lleno, zzpc debía caer por riesgo_clase_lleno: %', v_json -> 'candidatos';
    end if;

    -- 4. Si se repite, el autodiagnóstico pide ampliarlo, con evidencia.
    update public.agente_dias
       set descartes = descartes || '{"riesgo_clase_lleno": 150}'::jsonb
     where agente_id = v_ag and fecha = (now() at time zone 'UTC')::date;
    perform public.fn_autodiagnostico_agente(v_ag);
    if not exists (select 1 from public.agente_backlog
                    where clave_deduplicacion = 'diagnostico:riesgo_clase_lleno:agente_' || v_ag
                      and evidencia ->> 'limite' = 'clase_lleno') then
        raise exception 'I81 FALLO: el autodiagnóstico no pidió ampliar el riesgo por mercado';
    end if;

    -- 5. Los perfiles reales: los tres operan cripto, cada uno a su manera.
    if (select string_agg(nombre || ':' || coalesce(public.fn_param_clase(public.fn_parametros_agente(a), 'cripto', 'atr_pct_min') #>> '{}', '-')
                          || '-' || coalesce(public.fn_param_clase(public.fn_parametros_agente(a), 'cripto', 'atr_pct_max') #>> '{}', '-'),
                          ' ' order by id)
          from public.agentes a
         where nombre in ('Prudencia', 'Cadencia', 'Audacia')
           and public.fn_parametros_agente(a) -> 'clases_admitidas' ? 'cripto')
       <> 'Prudencia:--12 Cadencia:--4 Audacia:4--' then
        raise exception 'I81 FALLO: los rangos de ATR en cripto no son los de la 0032';
    end if;

    delete from public.agente_backlog where clave_deduplicacion like 'diagnostico:%:agente_' || v_ag;
    update public.activos set estado = 'suspendido' where simbolo in ('zzpa', 'zzpb', 'zzpc', 'zzpd');
    update public.agentes set estado = 'pausado' where id = v_ag;
    raise notice 'PASS  I81 cripto prudente: el riesgo se escala por volatilidad, el mercado tiene su tope de riesgo abierto, y el agente pide ampliarlo si se repite';
end
$i81$;

-- ═════════════════════════════════════════════════════════════════════
-- I82 · Huecos reales: M3' (0033).
--
-- 1. Cuándo hubo un cierre de mercado entre dos instantes (NYSE y cripto).
-- 2. El monitor: con un cierre entre medias y el precio por debajo del
--    stop, la orden sale al precio del hueco y se marca; sin cierre, sale
--    al nivel del stop (M3 de siempre). Para no depender de la hora a la
--    que corre la prueba, se usa una cripto y se marca su mercado, solo
--    durante la prueba, como mercado con huecos: su «sesión» acaba a
--    medianoche UTC.
-- ═════════════════════════════════════════════════════════════════════
do $i82$
declare
    v_act    bigint;
    v_act2   bigint;
    v_cuenta bigint;
    v_a      bigint;
    v_b      bigint;
    v_o      public.ordenes;
begin
    -- 1. Cierres de mercado.
    if not public.fn_hubo_cierre('nyse', '2026-10-09 15:50 America/New_York', '2026-10-12 09:37 America/New_York')
       or public.fn_hubo_cierre('nyse', '2026-10-12 10:00 America/New_York', '2026-10-12 11:00 America/New_York')
       or public.fn_hubo_cierre('nyse', '2026-10-09 15:50 America/New_York', '2026-10-09 15:59 America/New_York')
       or not public.fn_hubo_cierre('nyse', '2026-10-10 12:00 America/New_York', '2026-10-12 09:37 America/New_York')
       or not public.fn_hubo_cierre('nyse', '2026-11-25 15:00 America/New_York', '2026-11-27 09:40 America/New_York')
       or public.fn_hubo_cierre('cripto', now() - interval '3 days', now()) then
        raise exception 'I82 FALLO: fn_hubo_cierre no reconoce bien los cierres de mercado';
    end if;

    -- 2. El monitor.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzhueco', 'cripto', 'coingecko', 'zzhueco', 'activo', 100, now()) returning id into v_act;
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzhueco2', 'cripto', 'coingecko', 'zzhueco2', 'activo', 100, now()) returning id into v_act2;
    select c.id into v_cuenta from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id
     where a.nombre = 'Cadencia' and c.estado <> 'game_over';

    -- A: vista por última vez hace dos días (con medianoche entre medias).
    insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion, ultima_observacion_en)
    values (v_cuenta, v_act, 'agente', 100, now() - interval '2 days', 0.1, 1, 10, 110, 98, 1,
            now() - interval '2 days')
    returning id into v_a;
    perform public.fn_registrar_movimiento(v_cuenta, v_a, 'bloqueo_margen', -10, 10);
    -- B: vista hace un instante, sin cierre entre medias.
    insert into public.ordenes (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion, ultima_observacion_en)
    values (v_cuenta, v_act2, 'agente', 100, now(), 0.1, 1, 10, 110, 98, 1, now() - interval '1 second')
    returning id into v_b;
    perform public.fn_registrar_movimiento(v_cuenta, v_b, 'bloqueo_margen', -10, 10);

    update public.mercados set riesgo_hueco = 'alto' where clave = 'cripto';
    update public.activos set ultimo_precio = 95, ultimo_precio_en = now() where id in (v_act, v_act2);
    perform public.fn_monitorear_ordenes();
    update public.mercados set riesgo_hueco = 'bajo' where clave = 'cripto';

    select * into v_o from public.ordenes where id = v_a;
    if v_o.estado <> 'cerrada' or v_o.precio_salida <> 95 or not v_o.cierre_por_hueco or v_o.pnl_bruto <> -0.50 then
        raise exception 'I82 FALLO: con un cierre entre medias debía salir al precio del hueco (95): % % % %',
              v_o.estado, v_o.precio_salida, v_o.cierre_por_hueco, v_o.pnl_bruto;
    end if;
    select * into v_o from public.ordenes where id = v_b;
    if v_o.estado <> 'cerrada' or v_o.precio_salida <> 98 or v_o.cierre_por_hueco or v_o.precio_observado_cierre <> 95 then
        raise exception 'I82 FALLO: sin cierre entre medias debía salir al nivel del stop (98): % % % %',
              v_o.estado, v_o.precio_salida, v_o.cierre_por_hueco, v_o.precio_observado_cierre;
    end if;

    update public.activos set estado = 'suspendido' where id in (v_act, v_act2);
    raise notice 'PASS  I82 huecos reales: con el mercado cerrado entre medias, el stop sale al precio del hueco; si no, al nivel';
end
$i82$;

-- ═════════════════════════════════════════════════════════════════════
-- I83 · El spread (0034).
--
-- Los valores de la migración (pesimistas, QuantFury): acciones 0,03 $,
-- cripto 0,10 %, BTC 5 $, ETH 0,10 $. Una cripto a 100 $ con 0,10 % de
-- spread: se compra a 100,05 y se vende a 99,95. El monitor dispara el
-- stop con el precio de venta (el intermedio 98,04 aún no lo toca, la venta
-- 97,99 sí); un cierre a mano vende al precio de venta; y el agente
-- descarta lo que con el spread no llega a su R:R.
-- ═════════════════════════════════════════════════════════════════════
do $i83$
declare
    v_act    bigint;
    v_act2   bigint;
    v_senal  bigint;
    v_cuenta bigint;
    v_r      jsonb;
    v_o      public.ordenes;
    v_ag     bigint;
    v_json   jsonb;
begin
    -- Restaurar los valores de la migración y comprobarlos.
    update public.mercados m set spread_abs = t.spread_abs, spread_pct = t.spread_pct
      from spreads_0034 t where t.tipo = 'mercado' and t.id = m.clave;
    update public.activos a set spread_abs = t.spread_abs, spread_pct = t.spread_pct
      from spreads_0034 t where t.tipo = 'activo' and t.id = a.simbolo;
    if (select string_agg(clave || ':' || spread_abs::numeric(10,2) || '/' || spread_pct::numeric(10,2), ' ' order by clave)
          from public.mercados) <> 'cripto:0.00/0.10 nyse:0.03/0.00'
       or (select spread_abs from public.activos where simbolo = 'bitcoin') <> 5
       or (select spread_abs from public.activos where simbolo = 'ethereum') <> 0.10 then
        raise exception 'I83 FALLO: los spreads de la migración no son los acordados';
    end if;

    -- Precios de compra y de venta.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzspread', 'cripto', 'coingecko', 'zzspread', 'activo', 100, now()) returning id into v_act;
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('ZZSPR', 'accion', 'yahoo', 'ZZSPR', 'activo', 10, now()) returning id into v_act2;
    if public.fn_precio_compra(v_act, 100) <> 100.05 or public.fn_precio_venta(v_act, 100) <> 99.95
       or public.fn_precio_compra(v_act2, 10) <> 10.015 or public.fn_precio_venta(v_act2, 10) <> 9.985
       or public.fn_spread((select id from public.activos where simbolo = 'bitcoin'), 100000) <> 5 then
        raise exception 'I83 FALLO: precios de compra y venta inesperados';
    end if;

    -- Abrir: al precio de compra.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_act, true, 5, 2, 's9', 100, 98, 104, 2, 'alcista', 'largo', 'alta', 'estructura', 2, 3, 0, now())
    returning id into v_senal;
    select c.id into v_cuenta from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id
     where a.nombre = 'Prudencia' and c.estado <> 'game_over';
    v_r := public.rpc_abrir_orden(v_cuenta, v_senal, null, null, 2, 1, 'agente', null, 1);
    if (v_r ->> 'precio_entrada')::numeric <> 100.05 then
        raise exception 'I83 FALLO: debía comprar a 100,05: %', v_r;
    end if;

    -- El monitor dispara con el precio de venta: 98,04 de intermedio son
    -- 97,99 de venta, por debajo del stop de 98. Sale al stop.
    update public.activos set ultimo_precio = 98.04, ultimo_precio_en = now() where id = v_act;
    perform public.fn_monitorear_ordenes();
    select * into v_o from public.ordenes where id = (v_r ->> 'orden_id')::bigint;
    if v_o.estado <> 'cerrada' or v_o.precio_salida <> 98 or v_o.precio_observado_cierre <> 98.04 then
        raise exception 'I83 FALLO: el monitor debía disparar el stop con el precio de venta: % % %',
              v_o.estado, v_o.precio_salida, v_o.precio_observado_cierre;
    end if;

    -- Un cierre a mercado vende al precio de venta.
    update public.activos set ultimo_precio = 101, ultimo_precio_en = now() where id = v_act;
    update public.senales set precio_actual = 101, tp = 110, calculado_en = now() where id = v_senal;
    v_r := public.rpc_abrir_orden(v_cuenta, v_senal, null, null, 2, 1, 'agente', null, 1);
    perform public.rpc_cerrar_orden((v_r ->> 'orden_id')::bigint, 101, 'deterioro', 101);
    select * into v_o from public.ordenes where id = (v_r ->> 'orden_id')::bigint;
    if v_o.precio_entrada <> 101.0505 or v_o.precio_salida <> 100.9495 or v_o.pnl_bruto <> -0.10 then
        raise exception 'I83 FALLO: entrar y salir a mercado debía costar el spread entero: % → % (% $)',
              v_o.precio_entrada, v_o.precio_salida, v_o.pnl_bruto;
    end if;

    -- El agente descarta lo que con el spread no llega a su R:R mínimo:
    -- acción a 10 $ con stop a 9,80 y objetivo a 10,30 (R:R 1,5 al
    -- intermedio, 1,32 a la compra de 10,015) para un agente que exige 1,5.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_act2, true, 5, 3, 's9', 10, 9.80, 10.30, 3, 'alcista', 'largo', 'alta', 'estructura', 2.05, 3, 0, now());
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-spread', 2, 'activo',
         '{"clases_admitidas": ["accion"], "fuerzas_admitidas": ["alta"], "niveles_origen_admitidos": ["estructura"],
           "rr_minimo": 1.5, "atr_pct_min": 2.04, "atr_pct_max": 2.06}')
    returning id into v_ag;
    perform public.fn_crear_cuenta_agente(v_ag);
    v_json := public.fn_decidir_agente(v_ag);
    if (select c ->> 'descarte' from jsonb_array_elements(v_json -> 'candidatos') c
         where c ->> 'simbolo' = 'ZZSPR') is distinct from 'rr_con_spread' then
        raise exception 'I83 FALLO: con el spread, ZZSPR no llega al R:R 1,5 y debía descartarse: %', v_json -> 'candidatos';
    end if;

    update public.activos set estado = 'suspendido' where id in (v_act, v_act2);
    update public.agentes set estado = 'pausado' where id = v_ag;
    raise notice 'PASS  I83 spread: se compra a la compra, se vende a la venta, el monitor dispara con la venta y el agente descarta lo que el spread deja sin R:R';
end
$i83$;

-- ═════════════════════════════════════════════════════════════════════
-- I84 · El spread medido (0035).
--
-- AMCR cobra 0,10 $. Una acción con spread configurado de 0,03 $: con 9
-- observaciones de 0,05 $ todavía no hay spread observado (hacen falta 10);
-- con la décima, el percentil 90 (0,05 $) manda porque es mayor. Otra con
-- observaciones de 0,01 $ sigue cobrando 0,03 $: lo medido nunca baja lo
-- configurado. Lo de más de 60 días se purga.
-- ═════════════════════════════════════════════════════════════════════
do $i84$
declare
    v_a bigint;
    v_b bigint;
begin
    if (select spread_abs from public.activos where simbolo = 'AMCR') is distinct from 0.10 then
        raise exception 'I84 FALLO: AMCR debía cobrar 0,10 $ de spread';
    end if;

    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('ZZSPA', 'accion', 'yahoo', 'ZZSPA', 'activo', 20, now()) returning id into v_a;
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('ZZSPB', 'accion', 'yahoo', 'ZZSPB', 'activo', 20, now()) returning id into v_b;

    insert into public.spreads_observados (activo_id, bid, ask)
    select v_a, 20, 20.05 from generate_series(1, 9);
    if (select spread_observado from public.activos where id = v_a) is not null
       or public.fn_spread(v_a, 20) <> 0.03 then
        raise exception 'I84 FALLO: con 9 observaciones no debía haber spread observado';
    end if;
    insert into public.spreads_observados (activo_id, bid, ask) values (v_a, 20, 20.05);
    if (select spread_observado from public.activos where id = v_a) <> 0.05
       or public.fn_spread(v_a, 20) <> 0.05 or public.fn_precio_compra(v_a, 20) <> 20.025 then
        raise exception 'I84 FALLO: con 10 observaciones de 0,05 $ debía cobrar 0,05 $ (cobra %)', public.fn_spread(v_a, 20);
    end if;

    insert into public.spreads_observados (activo_id, bid, ask)
    select v_b, 20, 20.01 from generate_series(1, 12);
    if (select spread_observado from public.activos where id = v_b) <> 0.01 or public.fn_spread(v_b, 20) <> 0.03 then
        raise exception 'I84 FALLO: un spread medido menor que el configurado no debía bajarlo';
    end if;

    insert into public.spreads_observados (activo_id, observado_en, bid, ask)
    values (v_b, now() - interval '70 days', 20, 21);
    insert into public.spreads_observados (activo_id, bid, ask) values (v_b, 20, 20.01);
    if exists (select 1 from public.spreads_observados where activo_id = v_b and observado_en < now() - interval '60 days') then
        raise exception 'I84 FALLO: las observaciones de más de 60 días debían purgarse';
    end if;

    if (select spread_cobrado from public.v_spreads where activo_id = v_a) <> 0.05 then
        raise exception 'I84 FALLO: v_spreads no muestra el spread que se cobra';
    end if;

    update public.activos set estado = 'suspendido' where id in (v_a, v_b);
    raise notice 'PASS  I84 spread medido: AMCR a 0,10 $; con 10 observaciones el percentil 90 manda si es mayor; nunca baja lo configurado';
end
$i84$;

-- ═════════════════════════════════════════════════════════════════════
-- I85 · «Ampliar el universo» no cuenta los ciclos sin nada alcista (0036).
-- ═════════════════════════════════════════════════════════════════════
do $i85$
declare
    v_dia public.agente_dias;
begin
    select * into v_dia from public.agente_dias limit 1;

    -- Sin candidatas y sin ninguna alcista: es el mercado, no cuenta.
    update public.agente_dias
       set ciclos = ciclos + 1, ciclos_con_universo = ciclos_con_universo + 1,
           ciclos_sin_candidatos = ciclos_sin_candidatos + 1, ciclos_sin_alcistas = ciclos_sin_alcistas + 1
     where agente_id = v_dia.agente_id and fecha = v_dia.fecha;
    if (select ciclos_universo_sin_candidatos from public.agente_dias
         where agente_id = v_dia.agente_id and fecha = v_dia.fecha) <> v_dia.ciclos_universo_sin_candidatos then
        raise exception 'I85 FALLO: un ciclo sin ninguna señal alcista contó para «Ampliar el universo»';
    end if;

    -- Sin candidatas pero con alguna alcista descartada por el perfil: cuenta.
    update public.agente_dias
       set ciclos = ciclos + 1, ciclos_con_universo = ciclos_con_universo + 1,
           ciclos_sin_candidatos = ciclos_sin_candidatos + 1
     where agente_id = v_dia.agente_id and fecha = v_dia.fecha;
    if (select ciclos_universo_sin_candidatos from public.agente_dias
         where agente_id = v_dia.agente_id and fecha = v_dia.fecha) <> v_dia.ciclos_universo_sin_candidatos + 1 then
        raise exception 'I85 FALLO: un ciclo con alcistas descartadas por el perfil debía contar';
    end if;
    raise notice 'PASS  I85 «Ampliar el universo» solo cuenta los ciclos con señales alcistas que el perfil descartó';
end
$i85$;

-- ═════════════════════════════════════════════════════════════════════
-- I86 · Agente «Tendencia cripto» (0037, doc 07).
--
-- Una cripto de prueba con 260 velas diarias en tendencia y una ruptura
-- ayer. Comprueba: los indicadores; que entra con el stop a 2 ATR, sin
-- objetivo, a 1× y con el 1 % de riesgo; que no decide dos veces sobre la
-- misma vela; que el stop solo sube y nunca por encima del precio de
-- venta; la salida por regla al precio de venta; que el monitor no cierra
-- por objetivo una orden sin él pero sí por stop; G6; y que los bucles de
-- los agentes con metas no lo tocan.
-- ═════════════════════════════════════════════════════════════════════
do $i86$
declare
    v_ag      public.agentes;
    v_cuenta  bigint;
    v_act     bigint;
    v_otros   bigint[] := '{}';
    v_id      bigint;
    v_ayer    date := (now() at time zone 'UTC')::date - 1;
    v_ind     jsonb;
    v_sma     numeric;
    v_o       public.ordenes;
    v_equity  numeric;
    v_sl      numeric;
    v_r       jsonb;
    v_n       int;
    v_err     text;
    v_ciclo   jsonb;
    i         int;
begin
    select * into v_ag from public.agentes where nombre = 'Tendencia cripto';
    if v_ag.tipo <> 'estrategia' or v_ag.objetivo_diario_pct is not null or v_ag.estado <> 'pausado' then
        raise exception 'I86 FALLO: el agente debía existir como estrategia, sin meta y en pausa';
    end if;
    v_cuenta := public.fn_cuenta_agente(v_ag.id);
    if (select saldo_disponible from public.cuentas_simulacion where id = v_cuenta) <> 500 then
        raise exception 'I86 FALLO: la cuenta del agente debía empezar con 500 $';
    end if;

    -- Un agente con metas sin meta no se puede crear.
    begin
        insert into public.agentes (nombre, tipo, objetivo_diario_pct, estrategia)
        values ('zz sin meta', 'metas', null, '{}');
        raise exception 'I86 FALLO: un agente con metas sin objetivo diario debía rechazarse';
    exception when check_violation then null;
    end;

    -- Para la prueba: sin esperar al margen del ETL ni a la hora límite.
    update public.agentes
       set estado = 'activo',
           estrategia = estrategia || '{"margen_etl_min": 0, "hora_limite_utc": 24}'::jsonb
     where id = v_ag.id;

    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en, ultimo_etl_en)
    values ('zz-tendencia', 'cripto', 'coingecko', 'zz-tendencia', 'activo', 1, now(), now())
    returning id into v_act;

    -- 259 velas subiendo 0,2 $ al día (las 30 últimas con rango real del
    -- ±1 %) y ayer una ruptura del 6 %.
    insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, rango_real, origen)
    select v_act, v_ayer - 259 + g, 100 + 0.2 * g,
           case when g >= 229 then (100 + 0.2 * g) * 1.01 end,
           case when g >= 229 then (100 + 0.2 * g) * 0.99 end,
           100 + 0.2 * g, g >= 229, 'coingecko_ohlc'
      from generate_series(0, 258) g;
    insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, rango_real, origen)
    values (v_act, v_ayer, 151.6, 161.0, 151.0, 160.0, true, 'coingecko_ohlc');
    update public.activos set ultimo_precio = 160 where id = v_act;

    -- ── Indicadores ──────────────────────────────────────────────────
    v_ind := public.fn_indicadores_tendencia(v_act, v_ayer, v_ag.estrategia);
    select avg(cierre) into v_sma from (select cierre from public.precios_diarios
                                         where activo_id = v_act order by fecha desc limit 200) s;
    if (v_ind ->> 'sma')::numeric <> round(v_sma, 8)
       or (v_ind ->> 'max_ruptura')::numeric <> round((100 + 0.2 * 258) * 1.01, 8)
       or (v_ind ->> 'min_salida')::numeric <> round((100 + 0.2 * 249) * 0.99, 8)
       or (v_ind ->> 'cierre')::numeric <> 160
       or not ((v_ind ->> 'atr')::numeric between 1.5 and 4) then
        raise exception 'I86 FALLO: indicadores inesperados: %', v_ind;
    end if;

    -- ── Entrada ──────────────────────────────────────────────────────
    v_equity := public.fn_equity(v_cuenta);
    v_r := public.fn_decidir_tendencia(v_ag.id);
    select * into v_o from public.ordenes where cuenta_id = v_cuenta and activo_id = v_act and estado = 'abierta';
    if not found then
        raise exception 'I86 FALLO: con la ruptura debía entrar (%; decisión: %)', v_r,
              (select datos from public.agente_decisiones_diarias where agente_id = v_ag.id and activo_id = v_act);
    end if;
    v_sl := round(160 - 2 * (v_ind ->> 'atr')::numeric, 8);
    if v_o.tp is not null or v_o.sl <> v_sl or v_o.sl_original <> v_sl or v_o.apalancamiento <> 1
       or v_o.precio_entrada <> public.fn_precio_compra(v_act, 160)
       or abs(v_o.cantidad * (v_o.precio_entrada - v_o.sl) - v_equity * 0.01) > 0.01
       or v_o.racional ->> 'regla' <> 'tendencia' then
        raise exception 'I86 FALLO: orden de entrada inesperada (tp %, sl % frente a %, riesgo % frente a %)',
              v_o.tp, v_o.sl, v_sl, v_o.cantidad * (v_o.precio_entrada - v_o.sl), v_equity * 0.01;
    end if;

    -- Una sola decisión por vela.
    perform public.fn_decidir_tendencia(v_ag.id);
    select count(*) into v_n from public.agente_decisiones_diarias where agente_id = v_ag.id and activo_id = v_act;
    if v_n <> 1 or (select count(*) from public.ordenes where cuenta_id = v_cuenta and activo_id = v_act) <> 1 then
        raise exception 'I86 FALLO: decidió dos veces sobre la misma vela';
    end if;

    -- ── El stop solo sube, y nunca por encima de la venta ─────────────
    if public.fn_subir_stop(v_o.id, v_o.sl - 1) then
        raise exception 'I86 FALLO: el stop no debía bajar';
    end if;
    begin
        perform public.fn_subir_stop(v_o.id, 165);
        raise exception 'I86 FALLO: un stop por encima del precio de venta debía rechazarse';
    exception when sqlstate 'P0001' then null;
    end;

    -- Al día siguiente (simulado: la orden entró hace 5 días y su stop
    -- quedó bajo), el stop sube a mejor cierre − 3 ATR.
    update public.ordenes set fecha_entrada = now() - interval '5 days', sl = 100, sl_original = 100 where id = v_o.id;
    delete from public.agente_decisiones_diarias where agente_id = v_ag.id and activo_id = v_act;
    perform public.fn_decidir_tendencia(v_ag.id);
    select * into v_o from public.ordenes where id = v_o.id;
    if v_o.sl <> round(160 - 3 * (v_ind ->> 'atr')::numeric, 8)
       or jsonb_array_length(v_o.racional -> 'stops') <> 1
       or (select accion from public.agente_decisiones_diarias where agente_id = v_ag.id and activo_id = v_act) <> 'subir_stop' then
        raise exception 'I86 FALLO: el stop debía subir a mejor cierre − 3 ATR (está en %)', v_o.sl;
    end if;

    -- ── El monitor: sin objetivo no cierra por arriba ─────────────────
    update public.activos set ultimo_precio = 10000, ultimo_precio_en = now() where id = v_act;
    perform public.fn_monitorear_ordenes();
    if (select estado from public.ordenes where id = v_o.id) <> 'abierta' then
        raise exception 'I86 FALLO: el monitor cerró por objetivo una orden sin objetivo';
    end if;
    update public.activos set ultimo_precio = 160, ultimo_precio_en = now() where id = v_act;

    -- ── Salida por regla: ayer cerró bajo el mínimo de 10 días ────────
    update public.precios_diarios set cierre = 140, minimo = 139, maximo = 152
     where activo_id = v_act and fecha = v_ayer;
    delete from public.agente_decisiones_diarias where agente_id = v_ag.id and activo_id = v_act;
    perform public.fn_decidir_tendencia(v_ag.id);
    select * into v_o from public.ordenes where id = v_o.id;
    if v_o.estado <> 'cerrada' or v_o.motivo_cierre <> 'regla'
       or v_o.precio_salida <> public.fn_precio_venta(v_act, 160) then
        raise exception 'I86 FALLO: debía salir por regla al precio de venta (estado %, motivo %, salida %)',
              v_o.estado, v_o.motivo_cierre, v_o.precio_salida;
    end if;
    -- Y ese día no vuelve a entrar.
    if exists (select 1 from public.ordenes where cuenta_id = v_cuenta and activo_id = v_act and estado = 'abierta') then
        raise exception 'I86 FALLO: no debía volver a entrar el mismo día de la salida';
    end if;

    -- ── G6 y el monitor por stop ─────────────────────────────────────
    for i in 1..5 loop
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
        values ('zz-g6-' || i, 'cripto', 'coingecko', 'zz-g6-' || i, 'activo', 100, now())
        returning id into v_id;
        v_otros := v_otros || v_id;
    end loop;
    for i in 1..4 loop
        perform public.fn_abrir_orden_estrategia(v_cuenta, v_otros[i], 90, 1, '{}');
    end loop;
    begin
        perform public.fn_abrir_orden_estrategia(v_cuenta, v_otros[5], 90, 1, '{}');
        raise exception 'I86 FALLO: la quinta posición al 1 %% debía chocar con G6 (4 × riesgo)';
    exception when sqlstate 'P0001' then
        get stacked diagnostics v_err = message_text;
        if v_err not like 'G6%' then
            raise exception 'I86 FALLO: la quinta debía rechazarla G6, no: %', v_err;
        end if;
    end;
    -- Con el stop por encima de la entrada, la posición deja de consumir
    -- riesgo y cabe otra.
    update public.activos set ultimo_precio = 120, ultimo_precio_en = now() where id = v_otros[1];
    perform public.fn_subir_stop((select id from public.ordenes where cuenta_id = v_cuenta and activo_id = v_otros[1] and estado = 'abierta'), 105);
    perform public.fn_abrir_orden_estrategia(v_cuenta, v_otros[5], 90, 1, '{}');

    update public.activos set ultimo_precio = 85, ultimo_precio_en = now() where id = v_otros[2];
    perform public.fn_monitorear_ordenes();
    if (select motivo_cierre from public.ordenes where cuenta_id = v_cuenta and activo_id = v_otros[2]) <> 'sl' then
        raise exception 'I86 FALLO: el monitor debía cerrar por stop una orden sin objetivo';
    end if;

    -- ── Los bucles con metas no lo recorren ──────────────────────────
    v_ciclo := public.fn_ciclo_agentes();
    if v_ciclo::text like '%Tendencia cripto%' then
        raise exception 'I86 FALLO: el ciclo de los agentes con metas recorrió al agente de estrategia';
    end if;

    -- ── Criterio de retirada: caída > 15 % → pausa sola ──────────────
    if (select criterio from public.v_agentes_estrategia where agente_id = v_ag.id) <> 'arranque' then
        raise exception 'I86 FALLO: con menos de 5 cerradas el criterio debía ser «arranque»';
    end if;
    update public.cuentas_simulacion set capital_maximo_alcanzado = 1000 where id = v_cuenta;
    perform public.fn_ciclo_estrategias();
    if (select estado from public.agentes where id = v_ag.id) <> 'pausado' then
        raise exception 'I86 FALLO: con una caída de más del 15 %% el agente debía quedar en pausa';
    end if;

    update public.activos set estado = 'suspendido' where id = v_act or id = any(v_otros);
    raise notice 'PASS  I86 Tendencia cripto: entra con la ruptura a 2 ATR y 1 %% de riesgo, sin objetivo; una decisión por vela; el stop solo sube; sale por regla; G6; pausa por caída';
end
$i86$;

-- ═════════════════════════════════════════════════════════════════════
-- I87 · Precio fresco para la decisión diaria (0038).
--
-- De 01:00 a 07:59 UTC el monitor pide también el precio del universo de
-- los agentes de estrategia ACTIVOS; fuera de esa ventana, o con el agente
-- en pausa, solo el de las criptos con posición abierta.
-- ═════════════════════════════════════════════════════════════════════
do $i87$
declare
    v_ag  bigint;
    v_act bigint;
begin
    select id into v_ag from public.agentes where nombre = 'Tendencia cripto';
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
    values ('zz-ids', 'cripto', 'coingecko', 'zz-ids', 'activo') returning id into v_act;

    update public.agentes set estado = 'activo' where id = v_ag;
    if coalesce(public.fn_monitor_ids_cripto('2026-10-12 03:00+00'), '') not like '%zz-ids%' then
        raise exception 'I87 FALLO: en la ventana de decisión debía pedir el precio del universo del agente';
    end if;
    if coalesce(public.fn_monitor_ids_cripto('2026-10-12 12:00+00'), '') like '%zz-ids%' then
        raise exception 'I87 FALLO: fuera de la ventana solo debía pedir las criptos con posición';
    end if;
    update public.agentes set estado = 'pausado' where id = v_ag;
    if coalesce(public.fn_monitor_ids_cripto('2026-10-12 03:00+00'), '') like '%zz-ids%' then
        raise exception 'I87 FALLO: con el agente en pausa no debía pedir su universo';
    end if;

    update public.activos set estado = 'suspendido' where id = v_act;
    raise notice 'PASS  I87 el monitor pide el precio del universo de Tendencia cripto de 01:00 a 07:59 UTC, solo con el agente activo';
end
$i87$;

-- ═════════════════════════════════════════════════════════════════════
-- I88 · La pausa por caída de «Tendencia cripto» salta al 35 % (0039).
--
-- Una caída del 20 %, normal en la estrategia (el laboratorio de cartera
-- llega al 26 % ganando), no la pausa; una del 40 %, sí.
-- ═════════════════════════════════════════════════════════════════════
do $i88$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_equity numeric;
begin
    select id into v_ag from public.agentes where nombre = 'Tendencia cripto';
    v_cuenta := public.fn_cuenta_agente(v_ag);
    v_equity := public.fn_equity(v_cuenta);
    if (select (estrategia ->> 'caida_max_pct')::numeric from public.agentes where id = v_ag) <> 35 then
        raise exception 'I88 FALLO: el umbral de caída debía ser 35 %%';
    end if;

    update public.cuentas_simulacion set capital_maximo_alcanzado = round(v_equity / 0.8, 2) where id = v_cuenta;
    if (select criterio from public.v_agentes_estrategia where agente_id = v_ag) = 'caida' then
        raise exception 'I88 FALLO: una caída del 20 %% no debía pausar al agente';
    end if;
    update public.cuentas_simulacion set capital_maximo_alcanzado = round(v_equity / 0.6, 2) where id = v_cuenta;
    if (select criterio from public.v_agentes_estrategia where agente_id = v_ag) <> 'caida' then
        raise exception 'I88 FALLO: una caída del 40 %% debía marcar «caida»';
    end if;
    raise notice 'PASS  I88 la pausa por caída de Tendencia cripto salta al 35 %%, no al 20 %%';
end
$i88$;

-- ═════════════════════════════════════════════════════════════════════
-- I89 · Panel comparativo (0040).
--
-- Una fila por agente; para el de estrategia, las mismas operaciones y la
-- misma expectativa en R que su propia vista; y la R de una orden con un
-- cierre parcial cuenta el riesgo de la cantidad INICIAL y el resultado
-- de las dos partes.
-- ═════════════════════════════════════════════════════════════════════
do $i89$
declare
    v_ag  bigint;
    v_c   record;
    v_e   record;
begin
    if (select count(*) from public.v_comparativa_agentes) <> (select count(*) from public.agentes) then
        raise exception 'I89 FALLO: debía haber una fila por agente';
    end if;
    select id into v_ag from public.agentes where nombre = 'Tendencia cripto';
    select * into v_c from public.v_comparativa_agentes where agente_id = v_ag;
    select * into v_e from public.v_agentes_estrategia where agente_id = v_ag;
    if v_c.cerradas <> v_e.cerradas or v_c.cerradas = 0
       or round(v_c.expectativa_r, 3) <> round(v_e.expectativa_r, 3) then
        raise exception 'I89 FALLO: la comparativa (% ops, % R) no cuadra con v_agentes_estrategia (% ops, % R)',
              v_c.cerradas, v_c.expectativa_r, v_e.cerradas, v_e.expectativa_r;
    end if;
    -- (I86 adelanta 5 días la entrada de una orden: queda antes del alta.)
    if v_c.experimento_desde is null or v_c.cerradas_exp <> v_c.cerradas - 1 then
        raise exception 'I89 FALLO: «desde el experimento» debía contar las entradas posteriores al alta (% de %)',
              v_c.cerradas_exp, v_c.cerradas;
    end if;

    -- R con un parcial: 2 unidades a 100 con stop en 90 (riesgo 20 $); se
    -- cierra 1 a 110 (+10) y la otra a 120 (+20): R = 30 / 20 = 1,5.
    if exists (
        select 1
          from (select (o.pnl_bruto + o.pnl_parciales)
                         / ((o.cantidad + p.cantidad) * (o.precio_entrada - coalesce(o.sl_original, o.sl))) as r
                  from (values (1.0::numeric, 100.0::numeric, 90.0::numeric, null::numeric, 20.0::numeric, 10.0::numeric)) as
                       o(cantidad, precio_entrada, sl, sl_original, pnl_bruto, pnl_parciales),
                       (values (1.0::numeric)) as p(cantidad)) t
         where t.r <> 1.5) then
        raise exception 'I89 FALLO: la R con un parcial debía ser 1,5';
    end if;
    raise notice 'PASS  I89 comparativa: una fila por agente; la R de Tendencia cripto cuadra con su vista; los parciales cuentan';
end
$i89$;

-- ═════════════════════════════════════════════════════════════════════
-- I90 · Corte semanal sin consecuencias durante el experimento (0042).
--
-- Los agentes con metas no están en cuarentena ni con el riesgo reducido
-- y tienen las consecuencias suspendidas. Un agente así, con dos semanas
-- deficientes seguidas, recibe su nota y su entrada en el backlog, pero
-- sigue activo y con el riesgo completo.
-- ═════════════════════════════════════════════════════════════════════
do $i90$
declare
    v_lunes date := date_trunc('week', (now() at time zone 'UTC')::date)::date - 70;
    v_ag    bigint;
    v_cta   bigint;
    v_json  jsonb;
    v_texto text;
begin
    if exists (select 1 from public.agentes
                where nombre in ('Prudencia', 'Cadencia', 'Audacia')
                  and (consecuencias_semanales or riesgo_reducido or estado = 'cuarentena')) then
        raise exception 'I90 FALLO: los agentes con metas debían quedar sin cuarentena, con el riesgo completo y sin consecuencias';
    end if;

    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, consecuencias_semanales)
    values ('prueba-sin-consecuencias', 2, 'activo',
            '{"riesgo_pct_operacion": 4, "max_posiciones_abiertas": 3}', false) returning id into v_ag;
    v_cta := public.fn_crear_cuenta_agente(v_ag);
    insert into public.agente_dias
        (agente_id, fecha, cuenta_id, saldo_apertura, saldo_cierre, objetivo_importe, operable, cumplido, cerrado_en)
    select v_ag, v_lunes + k, v_cta, 500, 500, 10, true, false, now()
      from generate_series(0, 13) k;

    v_json := public.fn_corte_semanal_agente(v_ag, v_lunes);
    perform public.fn_corte_semanal_agente(v_ag, v_lunes + 7);
    select format('%s/%s/%s', c.riesgo_pct_operacion, c.max_posiciones_abiertas, a.estado) into v_texto
      from public.cuentas_simulacion c join public.agentes a on a.id = c.agente_id where c.id = v_cta;
    if v_json ->> 'veredicto' <> 'deficiente' or v_texto <> '4.00/3/activo' then
        raise exception 'I90 FALLO: dos deficientes sin consecuencias debían dejar 4.00/3/activo, quedó % (%)',
              v_texto, v_json ->> 'veredicto';
    end if;
    if (v_json -> 'accion_correctiva' ->> 'consecuencias_suspendidas')::boolean is not true
       or not exists (select 1 from public.agente_backlog
                       where clave_deduplicacion = 'ajuste_regla:semana_deficiente:agente_' || v_ag)
       or (select count(*) from public.agente_semanas where agente_id = v_ag and veredicto = 'deficiente') <> 2 then
        raise exception 'I90 FALLO: la nota, su entrada en el backlog y la marca de consecuencias suspendidas debían quedar';
    end if;
    update public.agentes set estado = 'pausado' where id = v_ag;
    raise notice 'PASS  I90 sin consecuencias semanales: dos deficientes dejan la nota y el backlog, pero ni riesgo a la mitad ni cuarentena';
end
$i90$;

-- ═════════════════════════════════════════════════════════════════════
-- I91 · Deterioro confirmado y espera tras el stop (0043).
--
-- Una sola lectura deteriorada después de la entrada no cierra; la
-- segunda seguida, sí. Y tras un stop en un activo, el agente no vuelve
-- a entrar en él durante 48 h (descarte «tras_stop»); pasado ese tiempo,
-- sí.
-- ═════════════════════════════════════════════════════════════════════
do $i91$
declare
    v_ag     bigint;
    v_cuenta bigint;
    v_a      bigint;
    v_oa     bigint;
    v_hoy    date := (now() at time zone 'UTC')::date;
    v_motivo text;
    v_n      int;
begin
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
    values ('zzdcf', 'cripto', 'coingecko', 'zzdcf', 'activo', 100, now()) returning id into v_a;
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, true, 5, 3, 's10', 100, 95, 110, 5, 'alcista', 'largo', 'alta', 'estructura', 9.5, 3, 0, now() - interval '3 hours');
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
        ('prueba-confirmado', 2, 'activo',
         '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["alta"], "niveles_origen_admitidos": ["estructura"],
           "atr_pct_min": 9.2, "rr_minimo": 1.5, "riesgo_pct_operacion": 2, "antiguedad_senal_max_min": 600}')
    returning id into v_ag;
    v_cuenta := public.fn_crear_cuenta_agente(v_ag);
    perform public.fn_sincronizar_dia_agente(v_ag, v_cuenta);
    update public.agente_dias set operable = true where agente_id = v_ag and fecha = v_hoy;
    perform public.fn_ciclo_agente(v_ag);
    select id into v_oa from public.ordenes where cuenta_id = v_cuenta and activo_id = v_a and estado = 'abierta';
    if v_oa is null then
        raise exception 'I91 FALLO: el agente debía abrir la posición de prueba';
    end if;
    update public.ordenes set fecha_entrada = now() - interval '2 hours' where id = v_oa;
    update public.activos set ultimo_precio = 101, ultimo_precio_en = now() where id = v_a;

    -- Una lectura deteriorada después de la entrada: no basta.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, false, 5, 3, 's10', 101, null, null, null, 'bajista', 'sin_sesgo', 'alta', null, 9.5, 0, 3, now() - interval '30 minutes');
    if public.fn_agente_salidas_deterioro(v_ag) <> 0
       or (select estado from public.ordenes where id = v_oa) <> 'abierta' then
        raise exception 'I91 FALLO: una sola lectura deteriorada no debía cerrar';
    end if;

    -- La segunda seguida: cierra, y deja los dos motivos.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, false, 5, 3, 's10', 101, null, null, null, 'bajista', 'sin_sesgo', 'alta', null, 9.5, 0, 3, now());
    v_n := public.fn_agente_salidas_deterioro(v_ag);
    if v_n <> 1
       or not exists (select 1 from public.agente_decisiones
                       where agente_id = v_ag and tipo = 'deterioro' and orden_id = v_oa
                         and datos ->> 'motivo' = 'direccion' and datos ->> 'motivo_anterior' = 'direccion') then
        raise exception 'I91 FALLO: dos lecturas deterioradas seguidas debían cerrar y dejar los dos motivos';
    end if;

    -- Espera tras el stop: un cierre por stop hace 1 h la descarta; hace 49 h, no.
    insert into public.senales
        (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
         precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
         niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
    values (v_a, true, 5, 3, 's10', 101, 96, 111, 5, 'alcista', 'largo', 'alta', 'estructura', 9.5, 3, 0, now() + interval '1 second');
    update public.ordenes set motivo_cierre = 'sl', fecha_salida = now() - interval '1 hour' where id = v_oa;
    select u.motivo into v_motivo
      from public.agentes a, public.fn_universo_agente(public.fn_parametros_agente(a), v_cuenta, '[]') u
     where a.id = v_ag and u.activo_id = v_a;
    if v_motivo is distinct from 'tras_stop' then
        raise exception 'I91 FALLO: tras un stop hace 1 h debía descartar con «tras_stop», dio %', v_motivo;
    end if;
    update public.ordenes set fecha_salida = now() - interval '49 hours' where id = v_oa;
    select u.motivo into v_motivo
      from public.agentes a, public.fn_universo_agente(public.fn_parametros_agente(a), v_cuenta, '[]') u
     where a.id = v_ag and u.activo_id = v_a;
    if v_motivo is not null then
        raise exception 'I91 FALLO: pasadas 48 h debía volver a ser candidata, dio %', v_motivo;
    end if;

    update public.agentes set estado = 'pausado' where id = v_ag;
    update public.activos set estado = 'suspendido' where id = v_a;
    raise notice 'PASS  I91 deterioro: una lectura no cierra, dos seguidas sí; tras un stop, 48 h sin volver a entrar en ese activo';
end
$i91$;

-- ═════════════════════════════════════════════════════════════════════
-- I92 · Backlog revisado (0044).
--
-- «Ampliar el universo» no salta con 5 ciclos ni con 24 de una sola señal
-- descartada por ciclo; sí con 24 y 3 descartes del perfil por ciclo. La
-- meta de un agente sin consecuencias semanales no se reabre; la de uno
-- con consecuencias, sí. Y la descripción sigue a la última ocurrencia.
-- ═════════════════════════════════════════════════════════════════════
do $i92$
declare
    v_ag    bigint;
    v_otro  bigint;
    v_cta   bigint;
    v_hoy   date := (now() at time zone 'UTC')::date;
    v_b     public.agente_backlog;
begin
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, consecuencias_semanales)
    values ('prueba-backlog', 2, 'pausado', '{}', false) returning id into v_ag;
    v_cta := public.fn_crear_cuenta_agente(v_ag);
    insert into public.agente_dias (agente_id, fecha, cuenta_id, saldo_apertura, objetivo_importe, operable,
                                    ciclos, ciclos_con_universo, ciclos_sin_candidatos, descartes)
    values (v_ag, v_hoy, v_cta, 500, 10, true, 0, 0, 0, '{"rr": 5, "direccion": 70}');
    update public.agente_dias set ciclos_universo_sin_candidatos = 5 where agente_id = v_ag and fecha = v_hoy;
    perform public.fn_disparadores_backlog(v_ag, '{}');
    update public.agente_dias set ciclos_universo_sin_candidatos = 24, descartes = '{"rr": 24, "direccion": 900}'
     where agente_id = v_ag and fecha = v_hoy;
    perform public.fn_disparadores_backlog(v_ag, '{}');
    if exists (select 1 from public.agente_backlog where clave_deduplicacion = 'nuevo_activo:universo'
                                                     and agente_id = v_ag) then
        raise exception 'I92 FALLO: «Ampliar el universo» saltó sin 24 ciclos con 3 descartes del perfil por ciclo';
    end if;
    delete from public.agente_backlog where clave_deduplicacion = 'nuevo_activo:universo';
    update public.agente_dias set descartes = '{"rr": 50, "atr_alto": 30, "direccion": 900}'
     where agente_id = v_ag and fecha = v_hoy;
    perform public.fn_disparadores_backlog(v_ag, '{}');
    if not exists (select 1 from public.agente_backlog where clave_deduplicacion = 'nuevo_activo:universo') then
        raise exception 'I92 FALLO: con 24 ciclos y 80 descartes del perfil debía saltar «Ampliar el universo»';
    end if;
    delete from public.agente_backlog where clave_deduplicacion = 'nuevo_activo:universo';

    -- La meta sin consecuencias no se reabre, pero cuenta y actualiza el texto.
    perform public.fn_registrar_backlog(v_ag, 'ajuste_regla', 'diagnostico:meta:agente_' || v_ag, 'Meta', 'W41', 'j', '{"n": 1}', 2);
    update public.agente_backlog set estado = 'rechazado', resolucion = 'Conocido'
     where clave_deduplicacion = 'diagnostico:meta:agente_' || v_ag;
    delete from public.agente_backlog_ocurrencias
     where backlog_id = (select id from public.agente_backlog where clave_deduplicacion = 'diagnostico:meta:agente_' || v_ag);
    perform public.fn_registrar_backlog(v_ag, 'ajuste_regla', 'diagnostico:meta:agente_' || v_ag, 'Meta', 'W42', 'j', '{"n": 2}', 2);
    select * into v_b from public.agente_backlog where clave_deduplicacion = 'diagnostico:meta:agente_' || v_ag;
    if v_b.estado <> 'rechazado' or v_b.ocurrencias <> 2 or v_b.descripcion <> 'W42' then
        raise exception 'I92 FALLO: la meta sin consecuencias debía seguir rechazada, contar la ocurrencia y decir W42: % / % / %',
            v_b.estado, v_b.ocurrencias, v_b.descripcion;
    end if;

    -- Con consecuencias, sí se reabre.
    insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
    values ('prueba-backlog-2', 2, 'pausado', '{}') returning id into v_otro;
    perform public.fn_registrar_backlog(v_otro, 'ajuste_regla', 'diagnostico:meta:agente_' || v_otro, 'Meta', 'W41', 'j', '{"n": 1}', 2);
    update public.agente_backlog set estado = 'rechazado' where clave_deduplicacion = 'diagnostico:meta:agente_' || v_otro;
    delete from public.agente_backlog_ocurrencias
     where backlog_id = (select id from public.agente_backlog where clave_deduplicacion = 'diagnostico:meta:agente_' || v_otro);
    perform public.fn_registrar_backlog(v_otro, 'ajuste_regla', 'diagnostico:meta:agente_' || v_otro, 'Meta', 'W42', 'j', '{"n": 2}', 2);
    if (select estado from public.agente_backlog where clave_deduplicacion = 'diagnostico:meta:agente_' || v_otro) <> 'nuevo' then
        raise exception 'I92 FALLO: con consecuencias, la meta debía reabrirse';
    end if;
    raise notice 'PASS  I92 backlog: «Ampliar el universo» pide 24 ciclos y 3 descartes del perfil por ciclo; la meta sin consecuencias no se reabre; la descripción sigue a la última ocurrencia';
end
$i92$;

-- ═════════════════════════════════════════════════════════════════════
-- I93 · La toma parcial no rompe el ciclo con 1 acción (0045).
--
-- La regla es la de `fn_cerrar_parcial`. Si la bolsa está abierta al
-- correr la prueba, además se recorre `fn_agente_tomas_parciales` con una
-- posición de 1 acción en su nivel: no lanza y la deja entera. Con la
-- bolsa cerrada el monitor no ve acciones y esa parte no aplica.
-- ═════════════════════════════════════════════════════════════════════
do $i93$
declare
    v_ag    bigint;
    v_cta   bigint;
    v_act   bigint;
    v_senal bigint;
    v_orden bigint;
    v_n     int;
begin
    if public.fn_parcial_divisible('accion', 1, 0.5) or not public.fn_parcial_divisible('accion', 3, 0.5)
       or public.fn_parcial_divisible('accion', 2, 0.4) or not public.fn_parcial_divisible('cripto', 1, 0.5) then
        raise exception 'I93 FALLO: 1 acción no se parte, 3 sí (1 entera), 2 al 40 %% no, y la cripto siempre';
    end if;

    if public.fn_mercado_abierto(now()) then
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia) values
            ('prueba-parcial-1accion', 50, 'pausado', '{"clases_admitidas": ["accion"], "fuerzas_admitidas": ["alta"],
              "rr_minimo": 1.2, "margen_comprometido_max_pct": 60, "riesgo_pct_operacion": 2,
              "tp_parcial": {"recorrido": 0.5, "fraccion": 0.5, "mover_stop": true}}')
        returning id into v_ag;
        v_cta := public.fn_crear_cuenta_agente(v_ag);
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
        values ('ZZP1', 'accion', 'yahoo', 'ZZP1', 'activo', 100, now()) returning id into v_act;
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
             precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
             niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
        values (v_act, true, 5, 3, 's7', 100, 90, 130, 1, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0, now())
        returning id into v_senal;
        v_orden := (public.rpc_abrir_orden(v_cta, v_senal, null, null, 1, 2, 'agente', null, 1) ->> 'orden_id')::bigint;
        update public.activos set ultimo_precio = 120, ultimo_precio_en = now() where id = v_act;
        v_n := public.fn_agente_tomas_parciales(v_ag);
        if v_n <> 0 or (select cantidad from public.ordenes where id = v_orden) <> 1
           or (select sl from public.ordenes where id = v_orden) <> 90 then
            raise exception 'I93 FALLO: con 1 acción la toma parcial debía saltarse la posición sin mover el stop';
        end if;
    end if;
    raise notice 'PASS  I93 la toma parcial del agente se salta la posición que no se parte en unidades enteras';
end
$i93$;

-- ═════════════════════════════════════════════════════════════════════
-- I94 · Los disparos del ETL miran la respuesta (0045).
--
-- En la CI no hay pg_net: se crea una `net._http_response` mínima. Un 401
-- deja un solo `fallo` por episodio (no uno por pasada) y guarda desde
-- cuándo falla; un 204 lo da por resuelto con un evento `etl`.
-- ═════════════════════════════════════════════════════════════════════
do $i94$
declare
    v_d public.control_despachos;
begin
    create schema if not exists net;
    create table net._http_response (id bigint primary key, status_code int, timed_out boolean,
                                     error_msg text, content text, created timestamptz default now());
    insert into net._http_response (id, status_code, content) values
        (9001, 401, '{"message": "Bad credentials", "status": "401"}'),
        (9002, 401, '{"message": "Bad credentials", "status": "401"}'),
        (9003, 204, null);

    insert into public.control_despachos (clave, ultimo, peticion_id)
    values ('etl-acciones.yml', now() - interval '30 minutes', 9001)
    on conflict (clave) do update set ultimo = excluded.ultimo, peticion_id = 9001,
                                      estado_http = null, respuesta = null, fallando_desde = null;
    perform public.fn_revisar_despachos();
    update public.control_despachos set peticion_id = 9002, estado_http = null where clave = 'etl-acciones.yml';
    perform public.fn_revisar_despachos();

    select * into v_d from public.control_despachos where clave = 'etl-acciones.yml';
    if v_d.estado_http <> 401 or v_d.fallando_desde is null
       or (select count(*) from public.eventos_sistema
            where tipo = 'fallo' and datos ->> 'donde' = 'disparar etl-acciones.yml') <> 1
       or not exists (select 1 from public.eventos_sistema
                       where tipo = 'fallo' and mensaje like '%401 (Bad credentials)%github_pat_altas%') then
        raise exception 'I94 FALLO: dos 401 seguidos debían dejar un solo fallo con el aviso del token: % / %',
              v_d.estado_http, v_d.fallando_desde;
    end if;

    update public.control_despachos set peticion_id = 9003, estado_http = null where clave = 'etl-acciones.yml';
    perform public.fn_revisar_despachos();
    select * into v_d from public.control_despachos where clave = 'etl-acciones.yml';
    if v_d.estado_http <> 204 or v_d.fallando_desde is not null
       or not exists (select 1 from public.eventos_sistema
                       where tipo = 'etl' and datos ->> 'donde' = 'disparar etl-acciones.yml'
                         and datos ->> 'recuperado' = 'true') then
        raise exception 'I94 FALLO: un 204 debía dar el fallo por resuelto: % / %', v_d.estado_http, v_d.fallando_desde;
    end if;

    drop schema net cascade;
    delete from public.control_despachos where clave = 'etl-acciones.yml';
    raise notice 'PASS  I94 un disparo rechazado deja un aviso por episodio, y la recuperación otro';
end
$i94$;

-- ═════════════════════════════════════════════════════════════════════
-- I95 · Salud del sistema y rol de solo lectura (0045).
--
-- `rpc_salud_sistema` solo responde a un admin. `analista_lectura` lee
-- todas las tablas y vistas de `public` (con `limit 0`, que planifica la
-- lista de selección y comprueba el EXECUTE de sus funciones, ver I40) y
-- no puede escribir en ninguna.
-- ═════════════════════════════════════════════════════════════════════
do $i95$
declare
    v_admin  uuid;
    v_otro   uuid;
    v_json   jsonb;
    v_fallo  boolean := false;
    v_rel    text;
    v_fallos text := '';
begin
    select id into v_admin from public.perfiles where rol = 'admin' and estado = 'aprobado' limit 1;
    select id into v_otro from public.perfiles where rol <> 'admin' and estado = 'aprobado' limit 1;

    perform pg_temp.como(v_admin);
    v_json := public.rpc_salud_sistema();
    perform pg_temp.como(v_otro);
    begin
        perform public.rpc_salud_sistema();
        v_fallo := true;
    exception when insufficient_privilege then null;
    end;
    perform pg_temp.como_dueno();
    if v_fallo or jsonb_typeof(v_json -> 'agentes') <> 'array' or jsonb_typeof(v_json -> 'senales') <> 'array'
       or jsonb_typeof(v_json -> 'despachos') <> 'array' then
        raise exception 'I95 FALLO: la salud del sistema es solo para el admin y trae agentes, señales y despachos: %', v_json;
    end if;

    for v_rel in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p') order by 1
    loop
        if has_table_privilege('analista_lectura', format('public.%I', v_rel), 'insert, update, delete, truncate') then
            v_fallos := v_fallos || v_rel || ' (escribe); ';
        end if;
        begin
            execute 'set local role analista_lectura';
            execute format('select * from public.%I limit 0', v_rel);
            execute 'reset role';
        exception when others then
            execute 'reset role';
            v_fallos := v_fallos || format('%s (%s); ', v_rel, sqlerrm);
        end;
    end loop;
    if v_fallos <> '' then
        raise exception 'I95 FALLO: analista_lectura -> %', v_fallos;
    end if;
    raise notice 'PASS  I95 la salud del sistema solo para el admin; analista_lectura lee todo public y no escribe';
end
$i95$;

-- ═════════════════════════════════════════════════════════════════════
-- I96 · Los agentes proponen hipótesis (0046, doc fase-3/01).
--
-- H2: cuatro criptos con dos saltos de 5 ATR cada una, en los que el
-- agente no entró; el MACD positivo solo el día en que empieza cada
-- movimiento → «movimiento:macd_positivo». Una por semana. H1: 25 salidas
-- por deterioro que costaron → «sin deterioro»; la rotación, que el
-- laboratorio no modela, queda `no_ejecutable`. La misma idea viva no se
-- repite. Solo el admin revisa, y solo adopta lo validado.
--
-- Todo dentro de un bloque que se deshace al final: suspender las demás
-- criptos para aislar la prueba no debe afectar a nada de después.
-- ═════════════════════════════════════════════════════════════════════
do $i96$
declare
    v_a      bigint;
    v_b      bigint;
    v_c      bigint;
    v_d      bigint;
    v_act    bigint;
    v_h      public.agente_hipotesis;
    v_id     bigint;
    v_id2    bigint;
    v_admin  uuid;
    v_otro   uuid;
    v_fallo  boolean := false;
    v_inicio date := current_date - 40;
begin
    begin
        update public.activos set estado = 'suspendido' where clase = 'cripto' and estado = 'activo';
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, creado_en)
        values ('prueba-hip-a', 2, 'pausado', '{"clases_admitidas": ["cripto"]}', now() - interval '60 days')
        returning id into v_a;
        perform public.fn_crear_cuenta_agente(v_a);

        for i in 1..4 loop
            insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
            values ('zzhip' || i, 'cripto', 'coingecko', 'zzhip' || i, 'activo') returning id into v_act;
            -- 100 hasta el día 8+i, 110 hasta el 22+i y 120 después: dos
            -- saltos de 10 con ATR 2.
            insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, volumen, origen)
            select v_act, v_inicio + d, c, c + 1, c - 1, c, 1000, 'coingecko_market_chart'
              from (select d, case when d <= 8 + i then 100 when d <= 22 + i then 110 else 120 end as c
                      from generate_series(0, 39) d) x;
            insert into public.indicadores_diarios (activo_id, fecha, sma_50, sma_200, rsi_14, macd, macd_signal,
                                                    macd_hist, atr_14, version_motor)
            select v_act, v_inicio + d, 50, 200, 45, 0, 0,
                   case when d in (8 + i - 4, 22 + i - 4) then 1 else -1 end, 2, 's9'
              from generate_series(0, 39) d;
        end loop;

        v_id := public.fn_generar_hipotesis(v_a);
        select * into v_h from public.agente_hipotesis where id = v_id;
        if v_h.id is null or v_h.origen <> 'movimiento' or v_h.clave <> 'movimiento:macd_positivo'
           or v_h.estado <> 'propuesta' or (v_h.evidencia ->> 'movimientos_perdidos')::int <> 8
           or v_h.experimento -> 'cambio' <> '{"condicion": "macd_positivo"}'::jsonb
           or v_h.experimento -> 'clases' <> '["cripto"]'::jsonb
           or (v_h.criterio ->> 'percentil_azar_min')::int <> 90
           or not exists (select 1 from public.eventos_sistema
                           where agente_id = v_a and tipo = 'agente' and datos ->> 'hipotesis_id' = v_id::text) then
            raise exception 'I96 FALLO: H2 debía proponer «macd_positivo» con 8 movimientos perdidos: % / % / %',
                  v_h.clave, v_h.evidencia, v_h.experimento;
        end if;
        if public.fn_generar_hipotesis(v_a) is not null then
            raise exception 'I96 FALLO: una sola hipótesis por agente y semana';
        end if;
        -- La semana siguiente, la misma idea sigue viva: no se repite.
        update public.agente_hipotesis set semana = semana - 7 where id = v_id;
        if public.fn_generar_hipotesis(v_a) is not null then
            raise exception 'I96 FALLO: la misma hipótesis viva no se propone otra vez';
        end if;

        -- H1: 25 salidas por deterioro que costaron.
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, creado_en)
        values ('prueba-hip-b', 2, 'pausado', '{"clases_admitidas": ["accion"]}', now() - interval '60 days')
        returning id into v_b;
        insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, creado_en, resuelta_en)
        select v_b, 'deterioro', '{"salida_deterioro": true}', -3 + (g % 3), now() - interval '1 day', now()
          from generate_series(1, 25) g;
        v_id2 := public.fn_generar_hipotesis(v_b);
        select * into v_h from public.agente_hipotesis where id = v_id2;
        if v_h.origen is distinct from 'decision' or v_h.clave <> 'decision:deterioro'
           or v_h.experimento -> 'cambio' <> '{"deterioro": 0}'::jsonb or v_h.estado <> 'propuesta'
           or (v_h.evidencia ->> 'decisiones')::int <> 25 then
            raise exception 'I96 FALLO: H1 debía proponer probar sin deterioro: % / %', v_h.clave, v_h.evidencia;
        end if;

        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, creado_en)
        values ('prueba-hip-c', 2, 'pausado', '{"clases_admitidas": ["accion"]}', now() - interval '60 days')
        returning id into v_c;
        insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, creado_en, resuelta_en)
        select v_c, 'rotacion', '{"umbral": 1.5}', -2 - (g % 2), now() - interval '1 day', now()
          from generate_series(1, 25) g;
        v_id2 := public.fn_generar_hipotesis(v_c);
        select * into v_h from public.agente_hipotesis where id = v_id2;
        if v_h.clave is distinct from 'decision:rotacion' or v_h.estado <> 'no_ejecutable' then
            raise exception 'I96 FALLO: la rotación debía quedar no_ejecutable: % / %', v_h.clave, v_h.estado;
        end if;

        -- H4: la plantilla «trailing stop» del backlog pasa a experimento.
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, creado_en)
        values ('prueba-hip-d', 2, 'pausado', '{"clases_admitidas": ["accion"]}', now() - interval '60 days')
        returning id into v_d;
        delete from public.agente_backlog where clave_deduplicacion = 'nueva_herramienta:trailing_stop';
        perform public.fn_registrar_backlog(v_d, 'nueva_herramienta', 'nueva_herramienta:trailing_stop',
                                            'Trailing stop', 'd', 'j', '{"ordenes": [1, 2, 3]}', 3);
        v_id2 := public.fn_generar_hipotesis(v_d);
        select * into v_h from public.agente_hipotesis where id = v_id2;
        if v_h.clave is distinct from 'plantilla:trailing_stop' or v_h.origen <> 'plantilla'
           or v_h.experimento -> 'cambio' <> '{"sigue_atr": 2}'::jsonb
           or v_h.evidencia -> 'ordenes' <> '[1, 2, 3]'::jsonb then
            raise exception 'I96 FALLO: H4 debía convertir el trailing stop en experimento: % / %', v_h.clave, v_h.evidencia;
        end if;

        -- Revisión: solo el admin, y solo adopta lo validado.
        select id into v_admin from public.perfiles where rol = 'admin' and estado = 'aprobado' limit 1;
        select id into v_otro from public.perfiles where rol <> 'admin' and estado = 'aprobado' limit 1;
        perform pg_temp.como(v_otro);
        begin
            perform public.rpc_revisar_hipotesis(v_id, 'archivada', 'no');
            v_fallo := true;
        exception when insufficient_privilege then null;
        end;
        perform pg_temp.como(v_admin);
        begin
            perform public.rpc_revisar_hipotesis(v_id, 'adoptada');
            v_fallo := true;
        exception when raise_exception then null;
        end;
        begin
            perform public.rpc_revisar_hipotesis(v_id, 'archivada');
            v_fallo := true;
        exception when invalid_parameter_value then null;
        end;
        perform public.rpc_revisar_hipotesis(v_id, 'archivada', 'Se probará con más movimientos');
        perform pg_temp.como_dueno();
        if v_fallo or (select estado from public.agente_hipotesis where id = v_id) <> 'archivada'
           or not exists (select 1 from public.auditoria_admin
                           where accion = 'resolver_hipotesis' and objetivo_id = v_id::text) then
            raise exception 'I96 FALLO: la revisión es del admin, adopta solo lo validado y archivar pide motivo';
        end if;
        -- Archivada hace menos de 8 semanas: tampoco se repite.
        if public.fn_hipotesis_repetida(v_a, 'movimiento:macd_positivo') is not true then
            raise exception 'I96 FALLO: una hipótesis archivada hace poco no debe volver';
        end if;

        raise exception 'I96 OK';
    exception when others then
        perform pg_temp.como_dueno();
        if sqlerrm <> 'I96 OK' then
            raise;
        end if;
    end;
    raise notice 'PASS  I96 hipótesis: H2 (movimientos perdidos), H1 (decisiones que cuestan) y H4 (plantillas), una por semana, sin repetir, revisión del admin';
end
$i96$;

-- ═════════════════════════════════════════════════════════════════════
-- I97 · Qué descartan los agentes y la fuente H3 (0047).
--
-- Un agente que solo admite la fuerza alta descarta una señal media por
-- «fuerza» y una alta con R:R 0,5 por «rr»; registrarlo dos veces el mismo
-- día deja una fila por motivo. H3: seis criptos que suben 10 cada 10
-- días (ATR 2), y 36 descartes por R:R justo antes de cada salto (+5 ATR
-- en 5 sesiones, frente a +2,14 de media en el universo: 15 de sus 35
-- días con cierre 5 sesiones después están justo antes de un salto) → «bajar el R:R
-- mínimo de 1,5 a 1,3». Todo dentro de un bloque que se deshace.
-- ═════════════════════════════════════════════════════════════════════
do $i97$
declare
    v_ag     bigint;
    v_b      bigint;
    v_media  bigint;
    v_rr     bigint;
    v_act    bigint;
    v_id     bigint;
    v_h      public.agente_hipotesis;
    v_inicio date := current_date - 40;
begin
    begin
        update public.activos set estado = 'suspendido' where clase = 'cripto' and estado = 'activo';
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
        values ('prueba-desc', 2, 'activo', '{"clases_admitidas": ["cripto"]}') returning id into v_ag;
        perform public.fn_crear_cuenta_agente(v_ag);
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
        values ('zzdm', 'cripto', 'coingecko', 'zzdm', 'activo', 100, now()) returning id into v_media;
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
        values ('zzdr', 'cripto', 'coingecko', 'zzdr', 'activo', 100, now()) returning id into v_rr;
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
             precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
             niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
        values (v_media, true, 5, 3, 's9', 100, 90, 130, 1, 'alcista', 'largo', 'media', 'atr', 2, 2, 0, now()),
               (v_rr, true, 5, 3, 's9', 100, 99, 100.5, 1, 'alcista', 'largo', 'alta', 'atr', 2, 3, 0, now());
        perform public.fn_registrar_descartes(v_ag);
        perform public.fn_registrar_descartes(v_ag);
        if (select count(*) from public.agente_descartes where agente_id = v_ag) <> 2
           or not exists (select 1 from public.agente_descartes where agente_id = v_ag and activo_id = v_media and motivo = 'fuerza')
           or not exists (select 1 from public.agente_descartes where agente_id = v_ag and activo_id = v_rr and motivo = 'rr') then
            raise exception 'I97 FALLO: debía quedar un descarte por «fuerza» y otro por «rr», sin repetir: %',
                  (select jsonb_agg(to_jsonb(d)) from public.agente_descartes d where agente_id = v_ag);
        end if;

        -- H3.
        update public.activos set estado = 'suspendido' where id in (v_media, v_rr);
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia, creado_en)
        values ('prueba-h3', 2, 'pausado', '{"clases_admitidas": ["cripto"], "fuerzas_admitidas": ["media", "alta"], "rr_minimo": 1.5}',
                now() - interval '60 days')
        returning id into v_b;
        for i in 1..6 loop
            insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
            values ('zzh3' || i, 'cripto', 'coingecko', 'zzh3' || i, 'activo') returning id into v_act;
            insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, volumen, origen)
            select v_act, v_inicio + d, c, c + 1, c - 1, c, 1000, 'coingecko_market_chart'
              from (select d, 100 + 10 * (d / 10) as c from generate_series(0, 39) d) x;
            insert into public.indicadores_diarios (activo_id, fecha, sma_50, sma_200, rsi_14, macd, macd_signal,
                                                    macd_hist, atr_14, version_motor)
            select v_act, v_inicio + d, 50, 200, 45, 0, 0, -1, 2, 's9' from generate_series(0, 39) d;
            insert into public.agente_descartes (agente_id, activo_id, fecha, motivo, precio, fuerza, ratio_rr, atr_pct)
            select v_b, v_act, v_inicio + d, 'rr', 100, 'alta', 1.2, 2 from unnest(array[5, 6, 15, 16, 25, 26]) d;
        end loop;

        v_id := public.fn_generar_hipotesis(v_b);
        select * into v_h from public.agente_hipotesis where id = v_id;
        if v_h.clave is distinct from 'descarte:rr' or v_h.origen <> 'descarte' or v_h.estado <> 'propuesta'
           or v_h.experimento -> 'cambio' <> '{"rr_minimo": 1.30}'::jsonb
           or (v_h.evidencia ->> 'descartes')::int <> 36
           or (v_h.evidencia ->> 'atr_en_5_medio')::numeric <> 5
           or (v_h.evidencia ->> 'atr_en_5_universo')::numeric <> 2.143 then
            raise exception 'I97 FALLO: H3 debía proponer bajar el R:R mínimo a 1,3: % / % / %',
                  v_h.clave, v_h.experimento, v_h.evidencia;
        end if;

        raise exception 'I97 OK';
    exception when others then
        if sqlerrm <> 'I97 OK' then
            raise;
        end if;
    end;
    raise notice 'PASS  I97 descartes del perfil registrados una vez al día, y H3 propone relajar el filtro que quitaba lo que más subía';
end
$i97$;

-- ═════════════════════════════════════════════════════════════════════
-- I98 · Qué pasa después de un stop (0048).
--
-- Cinco órdenes compradas a 100 con stop 90 y objetivo 120 que salen por
-- el stop a 90 (riesgo 10). Con las velas siguientes: llega a 121 →
-- «corto»; cae a 79 → «salvo»; las dos el mismo día → «ambiguo»; 12
-- sesiones planas → «ninguno»; solo 2 sesiones → sin veredicto todavía.
-- Dentro de un bloque que se deshace.
-- ═════════════════════════════════════════════════════════════════════
do $i98$
declare
    v_ag     bigint;
    v_cta    bigint;
    v_act    bigint;
    v_senal  bigint;
    v_orden  bigint;
    v_casos  text[] := array['corto', 'salvo', 'ambiguo', 'ninguno', 'pendiente'];
    v_caso   text;
    v_salida date;
    v_ids    jsonb := '{}';
    v_v      record;
begin
    begin
        insert into public.agentes (nombre, objetivo_diario_pct, estado, estrategia)
        values ('prueba-stops', 2, 'activo', '{}') returning id into v_ag;
        v_cta := public.fn_crear_cuenta_agente(v_ag);
        foreach v_caso in array v_casos loop
            insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado, ultimo_precio, ultimo_precio_en)
            values ('zzst' || v_caso, 'cripto', 'coingecko', 'zzst' || v_caso, 'activo', 100, now()) returning id into v_act;
            insert into public.senales
                (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
                 precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
                 niveles_origen, atr_pct, indicadores_alcistas, indicadores_bajistas, calculado_en)
            values (v_act, true, 5, 2, 's9', 100, 90, 120, 1, 'alcista', 'largo', 'alta', 'estructura', 2, 3, 0, now())
            returning id into v_senal;
            v_orden := (public.rpc_abrir_orden(v_cta, v_senal, 100, null, 1, 1, 'agente', null, 1) ->> 'orden_id')::bigint;
            perform public.rpc_cerrar_orden(v_orden, 90, 'sl', 90);
            v_salida := current_date - case when v_caso = 'pendiente' then 3 else 15 end;
            update public.ordenes set fecha_salida = v_salida + time '20:00' where id = v_orden;
            insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, origen)
            select v_act, v_salida + d,
                   95,
                   case when v_caso = 'corto' and d = 3 then 121 when v_caso = 'ambiguo' and d = 1 then 125 else 96 end,
                   case when v_caso = 'salvo' and d = 2 then 79 when v_caso = 'ambiguo' and d = 1 then 75 else 94 end,
                   95, 'coingecko_market_chart'
              from generate_series(1, case when v_caso = 'pendiente' then 2 else 12 end) d;
            v_ids := v_ids || jsonb_build_object(v_caso, v_orden);
        end loop;

        perform public.fn_seguir_stops();
        for v_v in
            select k.key as caso, o.post_stop_evento as evento, o.post_stop_sesiones as sesiones,
                   s.r_real, s.caida_r, s.rebote_r
              from jsonb_each_text(v_ids) k
              join public.ordenes o on o.id = k.value::bigint
              join public.v_seguimiento_stops s on s.orden_id = o.id
        loop
            if v_v.r_real <> -1
               or (v_v.caso <> 'pendiente' and v_v.evento is distinct from v_v.caso)
               or (v_v.caso = 'pendiente' and (v_v.evento is not null or v_v.sesiones <> 2))
               or (v_v.caso = 'ninguno' and v_v.sesiones <> 10)
               or (v_v.caso = 'corto' and (v_v.sesiones <> 3 or v_v.rebote_r <> 3.1))
               or (v_v.caso = 'salvo' and v_v.caida_r <> 1.1) then
                raise exception 'I98 FALLO: caso % → evento %, % sesiones, R %, caída %, rebote %',
                      v_v.caso, v_v.evento, v_v.sesiones, v_v.r_real, v_v.caida_r, v_v.rebote_r;
            end if;
        end loop;
        -- Lo ya resuelto no se vuelve a tocar; lo pendiente, sí.
        update public.ordenes set post_stop_revisado_en = '2000-01-01' where id in
            ((v_ids ->> 'corto')::bigint, (v_ids ->> 'pendiente')::bigint);
        perform public.fn_seguir_stops();
        if (select post_stop_revisado_en from public.ordenes where id = (v_ids ->> 'corto')::bigint) <> '2000-01-01'
           or (select post_stop_revisado_en from public.ordenes where id = (v_ids ->> 'pendiente')::bigint) = '2000-01-01' then
            raise exception 'I98 FALLO: la segunda pasada debía revisar la pendiente y no la resuelta';
        end if;

        raise exception 'I98 OK';
    exception when others then
        if sqlerrm <> 'I98 OK' then
            raise;
        end if;
    end;
    raise notice 'PASS  I98 tras un stop: corto, salvo, ambiguo, ninguno o pendiente, con las velas de las 10 sesiones siguientes';
end
$i98$;

-- ═════════════════════════════════════════════════════════════════════
-- I99 · ADX y media de 20 en el catálogo (0049).
--
-- Cierre 105 con la media de 20 en 104,5, ATR 1 y ADX 30 → adx_fuerte,
-- cerca_media_20 y no_sobreextendido. A 107,5 → sobreextendido. Sin ADX
-- (aún no lo escribe el ETL) → ninguna condición de ADX.
-- ═════════════════════════════════════════════════════════════════════
do $i99$
declare
    v_act bigint;
    v_c   text[];
begin
    begin
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
        values ('ZZADX', 'accion', 'yahoo', 'ZZADX', 'activo') returning id into v_act;
        insert into public.precios_diarios (activo_id, fecha, apertura, maximo, minimo, cierre, volumen, origen)
        values (v_act, current_date - 3, 105, 106, 104, 105, 1000, 'yahoo'),
               (v_act, current_date - 2, 107, 108, 106, 107.5, 1000, 'yahoo'),
               (v_act, current_date - 1, 105, 106, 104, 105, 1000, 'yahoo');
        insert into public.indicadores_diarios (activo_id, fecha, sma_20, adx_14, atr_14, version_motor)
        values (v_act, current_date - 3, 104.5, 30, 1, 's9'),
               (v_act, current_date - 2, 104.5, 15, 1, 's9'),
               (v_act, current_date - 1, 104.5, null, 1, 's9');
        select condiciones into v_c from public.v_condiciones_dia where activo_id = v_act and fecha = current_date - 3;
        if not (v_c @> array['adx_fuerte', 'cerca_media_20', 'no_sobreextendido'])
           or v_c && array['adx_debil', 'sobreextendido'] then
            raise exception 'I99 FALLO: día 1 → %', v_c;
        end if;
        select condiciones into v_c from public.v_condiciones_dia where activo_id = v_act and fecha = current_date - 2;
        if not (v_c @> array['adx_debil', 'sobreextendido']) or v_c && array['cerca_media_20', 'no_sobreextendido'] then
            raise exception 'I99 FALLO: día 2 → %', v_c;
        end if;
        select condiciones into v_c from public.v_condiciones_dia where activo_id = v_act and fecha = current_date - 1;
        if v_c && array['adx_fuerte', 'adx_debil'] then
            raise exception 'I99 FALLO: sin ADX no debía haber condiciones de ADX → %', v_c;
        end if;
        raise exception 'I99 OK';
    exception when others then
        if sqlerrm <> 'I99 OK' then
            raise;
        end if;
    end;
    raise notice 'PASS  I99 ADX y media de 20 en el catálogo de condiciones';
end
$i99$;

-- ═════════════════════════════════════════════════════════════════════
-- I40 · Toda vista se puede LEER con el rol del navegador.
--
-- La invariante que faltaba, y que habría evitado el incidente del
-- 2026-09-24: `/simulador` cargaba en producción con «permission denied
-- for function fn_tope_fase». El resto de este fichero prueba los RPC
-- con el JWT de cada usuario, pero leía las vistas como DUEÑO del
-- esquema — y el dueño ejecuta cualquier función, así que un privilegio
-- que falta es invisible desde ahí.
--
-- Esto recorre TODAS las vistas de `public` y hace un `select` con el rol
-- `authenticated`, que es lo que hace PostgREST. Va al final del fichero
-- a propósito: a estas alturas los bloques anteriores ya han creado
-- usuarios, carteras, señales, cuentas y órdenes, así que las vistas se
-- leen con datos dentro y no vacías.
--
-- Cero filas sería un resultado perfectamente válido (la RLS hace su
-- trabajo); lo que se busca es que ninguna reviente por un permiso.
-- ═════════════════════════════════════════════════════════════════════
do $i40$
declare
    v_vista   text;
    v_usuario uuid;
    v_fallos  text := '';
    v_leidas  int := 0;
begin
    select id into v_usuario from public.perfiles where estado = 'aprobado' limit 1;

    for v_vista in select viewname from pg_views where schemaname = 'public' order by viewname
    loop
        begin
            perform pg_temp.como(v_usuario);
            -- `select *` y no `count(*)`: al contar, PostgreSQL PODA las
            -- expresiones de la lista de selección y nunca comprueba el
            -- permiso sobre las funciones que la vista usa. Justo así se
            -- escapó el fallo del 2026-09-24. Con `limit 0` se planifica
            -- la lista entera —que es donde PostgreSQL verifica el
            -- EXECUTE— sin devolver ni una fila.
            execute format('select * from public.%I limit 0', v_vista);
            perform pg_temp.como_dueno();
            v_leidas := v_leidas + 1;
        exception when others then
            perform pg_temp.como_dueno();
            v_fallos := v_fallos || format('%s (%s); ', v_vista, sqlerrm);
        end;
    end loop;

    if v_fallos <> '' then
        raise exception 'I40 FALLO: vistas ilegibles para authenticated -> %', v_fallos;
    end if;
    raise notice 'PASS  I40 las % vistas de public se leen con el rol authenticated', v_leidas;
end
$i40$;
