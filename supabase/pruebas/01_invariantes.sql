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
    for i in 1..17 loop   -- + bitcoin, ethereum, solana = 20
        perform public.rpc_solicitar_activo('cripto', 'moneda-' || i);
    end loop;
    perform public.rpc_solicitar_activo('cripto', 'bitcoin');
    perform public.rpc_solicitar_activo('cripto', 'ethereum');
    perform public.rpc_solicitar_activo('cripto', 'solana');
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

    -- G4: con `max_posiciones_abiertas` a 1, la segunda posición —en otro
    -- activo— también se rechaza.
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
    if v_fallo then
        raise exception 'I34 FALLO: se superó el máximo de posiciones abiertas';
    end if;
    if v_texto not like '%posiciones abiertas%' then
        raise exception 'I34 FALLO: el rechazo de G4 no lo explica: %', v_texto;
    end if;
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
    raise notice 'PASS  I34 G2/G3/G4: riesgo, margen, número de posiciones y propiedad de la cuenta se imponen en el servidor';

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
    select format('%s/%s/%s/%s', riesgo_pct_operacion, max_posiciones_abiertas,
                  margen_comprometido_max_pct, ratio_rr_minimo) into v_texto
      from public.cuentas_simulacion where id = v_c_pru;
    if v_texto <> '1.50/3/40.00/2.00' then
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
    -- zzag1: cripto, media, atr, R:R 2,5, ATR 4         -> la de Audacia
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
        (v_z1,  true, 5, 2, 's6', 100, 90, 125, 3, 'alcista', 'largo', 'media', 'atr',        4, 2, 0, now()),
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

    v_json := public.fn_decidir_agente(v_auda);
    if coalesce((v_json #>> '{descartes_por_motivo,atr_bajo}')::int, 0) <> 1
       or coalesce((v_json #>> '{descartes_por_motivo,direccion}')::int, 0) <> 1
       or coalesce((v_json #>> '{descartes_por_motivo,antiguedad}')::int, 0) <> 1 then
        raise exception 'I43 FALLO: los descartes de Audacia no son los esperados: %', v_json -> 'descartes_por_motivo';
    end if;

    perform public.fn_ciclo_agentes();

    select string_agg(g.nombre || '=' || a.simbolo, ',' order by g.id) into v_texto
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.agentes g on g.id = c.agente_id
      join public.activos a on a.id = o.activo_id
     where g.id in (v_pru, v_cad, v_auda) and o.estado = 'abierta';
    if v_texto is distinct from 'Prudencia=ZZAGA,Cadencia=zzag2,Audacia=zzag1' then
        raise exception 'I43 FALLO: los perfiles no diferencian: %', v_texto;
    end if;
    -- El racional explica la decisión: qué faltaba, qué se evaluó y qué se descartó.
    select count(*) into v_conteo from public.ordenes
     where cuenta_id in (v_c_pru, v_c_cad, v_c_auda) and origen = 'agente'
       and racional ? 'candidatos_evaluados' and racional ? 'descartados_top3'
       and racional ? 'deficit_pendiente' and racional ? 'version_estrategia'
       and racional ? 'elegido';
    if v_conteo <> 3 then
        raise exception 'I43 FALLO: % de 3 órdenes llevan el racional completo', v_conteo;
    end if;
    raise notice 'PASS  I43 misma decisión con el mismo estado; sobre las mismas señales los tres agentes eligen tres activos distintos, con su racional';

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
           and ((select count(*) from public.ordenes o
                  where o.cuenta_id = c.id and o.estado = 'abierta') > c.max_posiciones_abiertas     -- G4
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
    values (v_z1, true, 5, 2, 's6-hist', 100, 90, 125, 3, 'alcista', 'largo', 'media', 'atr', 4, 2, 0,
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

    -- Adoptarla CAMBIA el conjunto de candidatos de Cadencia: zzag1 es de
    -- fuerza media y ZZAGA es una acción; la práctica exige cripto alta.
    select version_estrategia into v_num from public.agentes where id = v_cad;
    v_json := public.fn_decidir_agente(v_cad);
    if public.fn_adoptar_practica(v_cad) is distinct from v_practica then
        raise exception 'I48 FALLO: Cadencia no adoptó la única práctica compatible';
    end if;
    v_json2 := public.fn_decidir_agente(v_cad);
    if (v_json ->> 'candidatos_evaluados')::int <> 2
       or (v_json2 ->> 'candidatos_evaluados')::int <> 0
       or (v_json2 ->> 'candidatos_antes_practicas')::int <> 2
       or (v_json2 #>> '{descartes_por_motivo,practica}')::int <> 2 then
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
    select id into v_orden from public.ordenes where cuenta_id = v_c_auda and estado = 'abierta';
    perform public.rpc_cerrar_orden(v_orden, 125, 'tp', 125);   -- +62,50 $ sobre una meta de 35 $
    if public.fn_decidir_agente(v_auda) ->> 'accion' <> 'meta_cumplida' then
        raise exception 'I45 FALLO: con la meta cumplida Audacia no entra en modo conservación';
    end if;
    perform public.fn_ciclo_agentes();
    if exists (select 1 from public.ordenes where cuenta_id = v_c_auda and estado = 'abierta') then
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
    if v_num <> 20 or v_num2 <> trunc(v_num2) then
        raise exception 'I56 FALLO: la recomendación debía llevar cupo 20 %% y acciones enteras, dio % y %', v_num, v_num2;
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
    raise notice 'PASS  I56 cupo por posición en el dimensionado y la recomendación; acciones en unidades enteras; la cantidad a mano manda pero G2 sigue imponiéndose';

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
    raise notice 'PASS  I58 rotación: cierra la posición con menos R:R restante, abre la mejor señal y deja la decisión para juzgarla';

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
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_rota, 'rotacion', '{"umbral": 1.5}', -3, now() from generate_series(1, 10);
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_parc, 'reparto', '{"reparto": "cupo"}', 50, now() from generate_series(1, 10);
    insert into public.agente_decisiones (agente_id, tipo, parametro, efecto, resuelta_en)
    select v_rota, 'reparto', '{"reparto": "concentrado"}', -50, now() from generate_series(1, 10);
    select version_estrategia into v_num from public.agentes where id = v_rota;

    if public.fn_ajustar_parametros(v_rota) <> 2 then
        raise exception 'I60 FALLO: con esa evidencia debía ajustar dos parámetros';
    end if;
    select format('%s/%s', estrategia -> 'rotacion_umbral', estrategia ->> 'reparto') into v_texto
      from public.agentes where id = v_rota;
    if v_texto <> '1.7/cupo' or (select version_estrategia from public.agentes where id = v_rota) <= v_num
       or (select count(*) from public.agente_ajustes where agente_id = v_rota) <> 2 then
        raise exception 'I60 FALLO: rotaciones que pierden suben el umbral un paso y el reparto cambia al que rinde más: %', v_texto;
    end if;
    -- Sin evidencia nueva no se vuelve a mover.
    if public.fn_ajustar_parametros(v_rota) <> 0 then
        raise exception 'I60 FALLO: un parámetro se movió dos veces con la misma evidencia';
    end if;
    raise notice 'PASS  I60 los parámetros se mueven un paso con 10 decisiones resueltas, quedan registrados y no se mueven dos veces por lo mismo';

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
                   || '{"fuerzas_admitidas": ["alta", "media"]}',
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
