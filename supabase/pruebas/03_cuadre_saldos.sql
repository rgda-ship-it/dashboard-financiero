-- ─────────────────────────────────────────────────────────────────────
-- Cuadre del libro mayor tras una sesión de 50 operaciones (doc 01 §5.2).
--
-- Es el test obligatorio de la DoD de H-26, y la razón por la que existe
-- es concreta: el riesgo R4 (un saldo que se infla por un cierre doble)
-- no se manifiesta como un error, se manifiesta como un número creíble
-- pero falso. Esta consulta es la red que lo convierte en detectable en
-- minutos en vez de en semanas.
--
-- No comprueba un caso: comprueba la PROPIEDAD. Después de cincuenta
-- aperturas y cierres por los RPC de verdad —con sus topes, sus recortes
-- de margen, su cambio de fase a mitad de camino y sus pérdidas limitadas
-- al margen— el saldo materializado de cada cuenta tiene que poder
-- reconstruirse sumando sus apuntes. Si no, hay un bug de saldo.
--
-- Se usa una cuenta de AGENTE para no arrastrar aquí el gobierno entero
-- (perfil, aprobación, cartera): `rpc_abrir_orden` distingue las cuentas
-- de agente y las deja operar al servidor, que es quien ejecuta esto.
--
-- Uso:
--   psql "$URL" -v ON_ERROR_STOP=1 -f supabase/pruebas/03_cuadre_saldos.sql
-- ─────────────────────────────────────────────────────────────────────

\set ON_ERROR_STOP on

do $cuadre$
declare
    v_cuenta   bigint;
    v_activo   bigint;
    v_senal    bigint;
    v_orden    bigint;
    v_json     jsonb;
    v_precio   numeric;
    v_conteo   bigint;
    v_abiertas int;
    v_cerradas int := 0;
    v_equity   numeric;
    i          int;
begin
    raise notice '── Cuadre de saldos: 50 operaciones simuladas ──';

    delete from public.ordenes
     where cuenta_id in (select id from public.cuentas_simulacion where agente_id = 990002);
    delete from public.cuentas_simulacion where agente_id = 990002;
    insert into public.agentes (id, nombre, objetivo_diario_pct, estrategia)
    values (990002, 'prueba-cuadre', 2, '{}') on conflict do nothing;

    insert into public.cuentas_simulacion
        (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado, max_posiciones_abiertas)
    -- Nace con saldo cero y el depósito entra por el libro mayor, igual
    -- que hace `rpc_crear_cuenta_simulacion`: si se creara con el saldo ya
    -- puesto, el cuadre empezaría comparando un número contra sí mismo.
    values (990002, 1000, 0, 0, 3) returning id into v_cuenta;
    perform public.fn_registrar_movimiento(v_cuenta, null, 'deposito_inicial', 1000, 0);

    -- Un activo propio de esta prueba: así no depende de la semilla ni
    -- interfiere con las cuotas, que se cuentan sobre activos SEGUIDOS.
    insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado,
                                ultimo_precio, ultimo_precio_en)
    values ('zzcuadre', 'cripto', 'coingecko', 'zzcuadre', 'activo', 100, now())
    on conflict (simbolo) do update set estado = 'activo', ultimo_precio = 100,
                                        ultimo_precio_en = now()
    returning id into v_activo;

    for i in 1 .. 50 loop
        -- Señal nueva en cada vuelta: la anterior ya tiene 0 minutos pero
        -- la orden anterior la consumió, y así cada operación queda ligada
        -- a la señal que la justificó (que es lo que hace auditable el
        -- experimento).
        insert into public.senales
            (activo_id, operable, leverage_tope, leverage_referencia_volatilidad, version_motor,
             precio_actual, sl, tp, leverage_recomendado, direccion, sesgo_operativo, fuerza,
             niveles_origen, atr_pct)
        values (v_activo, true, 5, 3, 'cuadre' || i, 100, 90, 130, 5,
                'alcista', 'largo', 'alta', 'estructura', 2)
        returning id into v_senal;

        v_json := public.rpc_abrir_orden(v_cuenta, v_senal, null, null, null, null, 'agente');
        v_orden := (v_json ->> 'orden_id')::bigint;

        -- Tres desenlaces que rotan, para que el cuadre se pruebe contra
        -- las tres formas en que un cierre mueve el saldo:
        --   · TP (+60 sobre un margen de ~40): el caso feliz.
        --   · SL (-20): pérdida dentro del margen.
        --   · Hueco por debajo de la liquidación: pérdida MAYOR que el
        --     margen, que el clamp tiene que limitar. Es el caso donde un
        --     bug dejaría el saldo en negativo o la orden abierta.
        v_precio := case i % 3 when 0 then 130 when 1 then 90 else 50 end;
        v_json := public.rpc_cerrar_orden(v_orden, v_precio,
                     case i % 3 when 0 then 'tp' when 1 then 'sl' else 'liquidacion' end,
                     v_precio);
        if not (v_json ->> 'cerrada')::boolean then
            raise exception 'CUADRE FALLO: la operación % no se cerró: %', i, v_json;
        end if;
        v_cerradas := v_cerradas + 1;

        -- Si la racha de pérdidas deja la cuenta sin equity operable, el
        -- sistema la marca `inoperante` y deja de admitir órdenes: eso es
        -- correcto, pero cortaría la prueba antes de las 50. Se recapitaliza
        -- con un `ajuste_manual`, que es un apunte del libro mayor como
        -- cualquier otro y por tanto ENTRA en el cuadre.
        v_equity := public.fn_equity(v_cuenta);
        if v_equity < 200 then
            perform public.fn_registrar_movimiento(v_cuenta, null, 'ajuste_manual', 500, 0);
            update public.cuentas_simulacion set estado = 'activa'
             where id = v_cuenta and estado = 'inoperante';
        end if;
    end loop;

    if v_cerradas <> 50 then
        raise exception 'CUADRE FALLO: se cerraron % operaciones de 50', v_cerradas;
    end if;

    select count(*) into v_conteo from public.ordenes
     where cuenta_id = v_cuenta and estado = 'cerrada';
    if v_conteo <> 50 then
        raise exception 'CUADRE FALLO: hay % órdenes cerradas y deberían ser 50', v_conteo;
    end if;

    -- Tres apuntes por operación: bloqueo, liberación y resultado. Ni dos
    -- (que fusionaría hechos económicos distintos) ni cuatro (que sería un
    -- cierre doble).
    select count(*) into v_conteo from public.movimientos_saldo
     where cuenta_id = v_cuenta and tipo in ('bloqueo_margen', 'liberacion_margen',
                                             'resultado_operacion');
    if v_conteo <> 150 then
        raise exception 'CUADRE FALLO: % apuntes de operación, se esperaban 150 (3 x 50)', v_conteo;
    end if;

    select count(*) into v_abiertas from public.ordenes
     where cuenta_id = v_cuenta and estado = 'abierta';
    if v_abiertas <> 0 then
        raise exception 'CUADRE FALLO: quedaron % órdenes abiertas', v_abiertas;
    end if;
    if (select saldo_bloqueado from public.cuentas_simulacion where id = v_cuenta) <> 0 then
        raise exception 'CUADRE FALLO: sin órdenes abiertas el margen bloqueado no es cero';
    end if;
    if (select saldo_disponible from public.cuentas_simulacion where id = v_cuenta) < 0 then
        raise exception 'CUADRE FALLO: el saldo disponible quedó en negativo';
    end if;
    raise notice 'PASS  50 operaciones cerradas, 150 apuntes, ningún margen huérfano';
end
$cuadre$;

-- ── LA CONSULTA, tal cual la fija el doc 01 §5.2 ─────────────────────
-- Para toda cuenta, el saldo materializado debe coincidir con el libro
-- mayor. DEBE DEVOLVER CERO FILAS. Si devuelve alguna, hay un bug de saldo.
--
-- Corre sobre TODAS las cuentas y no solo sobre la de esta prueba: si una
-- migración futura toca un saldo sin pasar por `fn_registrar_movimiento`,
-- aquí se ve.
--
-- Se excluyen las cuentas sin ningún apunte: son bancos de pruebas que
-- otros ficheros crean a mano para ejercitar la máquina de fases, y no
-- pretenden tener libro mayor.
do $verificar$
declare
    v_descuadres bigint;
    v_detalle    text;
begin
    select count(*), string_agg(format('cuenta %s: saldo %s, recalculado %s',
                                        id, saldo_disponible, recalculado), '; ')
      into v_descuadres, v_detalle
      from (
        select c.id, c.saldo_disponible,
               c.saldo_inicial + coalesce(sum(m.importe) filter (
                 where m.tipo <> 'deposito_inicial'), 0) as recalculado
          from public.cuentas_simulacion c
          join public.movimientos_saldo m on m.cuenta_id = c.id
         group by c.id, c.saldo_disponible, c.saldo_inicial
        having abs(c.saldo_disponible - (c.saldo_inicial + coalesce(sum(m.importe) filter (
                 where m.tipo <> 'deposito_inicial'), 0))) > 0.01
      ) d;

    if v_descuadres <> 0 then
        raise exception 'CUADRE FALLO: % cuentas descuadradas -> %', v_descuadres, v_detalle;
    end if;
    raise notice 'PASS  el cuadre del libro mayor devuelve cero filas';
end
$verificar$;
