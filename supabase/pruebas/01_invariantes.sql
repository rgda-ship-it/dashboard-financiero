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
