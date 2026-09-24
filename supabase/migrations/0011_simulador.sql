-- ─────────────────────────────────────────────────────────────────────
-- 0011 — Simulador y monitoreo (Sprint 5, H-22…H-26).
--
-- Lo que esta migración añade, en una frase: una orden con TP y SL se
-- cierra sola, y el saldo que muestra la pantalla se puede reconstruir
-- sumando el libro mayor.
--
-- TRES DECISIONES DEL DUEÑO QUE EXPLICAN POR QUÉ ESTE FICHERO ES COMO ES
--
-- D8 (2026-09-23) — EL MONITOR ES SQL, NO UNA EDGE FUNCTION.
--   El plan de H-25 pedía una Edge Function `monitor-ordenes` disparada
--   por `pg_cron` vía `pg_net`. Se descarta por la misma razón que en el
--   Sprint 4: una Edge Function hay que desplegarla con la CLI en cada
--   cambio (un paso manual más para el dueño en cada iteración) y queda
--   FUERA de la única validación automática que tiene el proyecto, que
--   es aplicar las migraciones sobre un PostgreSQL limpio y correr las
--   invariantes. Con el monitor en SQL, las reglas M1–M4 se prueban en
--   cada pull request. Lo que se pierde: no se puede llamar a yfinance
--   desde PostgreSQL. Se asume, y se documenta en D9.
--
-- D9 (2026-09-23) — EL PRECIO VIVO DEL MONITOR SALE DE COINGECKO, EN UNA
--   SOLA PETICIÓN POR PASADA Y SOLO SI HAY POSICIONES ABIERTAS.
--   `pg_net` es ASÍNCRONO: `net.http_get` devuelve un identificador y la
--   respuesta aparece más tarde en `net._http_response`. Por eso el ciclo
--   del monitor tiene dos fases y no una: primero COSECHA las respuestas
--   de la pasada anterior, evalúa las órdenes con esos precios, y al
--   final PIDE los precios de la pasada siguiente. Con `pg_cron` cada
--   minuto, el retraso máximo entre que el precio cruza un nivel y la
--   orden se cierra son dos pasadas ≈ 2 minutos, que es exactamente el
--   criterio de aceptación de H-25.
--
--   `simple/price` admite todos los ids en una sola llamada, así que el
--   coste es UNA petición por minuto como máximo, y CERO cuando nadie
--   tiene posiciones abiertas. Frente a las ~10-15 req/min que tolera
--   CoinGecko sin clave (doc 02 §6.3) y a las 12 que gasta el ETL en 36 s
--   una vez por hora, cabe sin tocar el techo del sistema.
--
--   Para las ACCIONES no hay proveedor accesible desde SQL: su precio lo
--   sigue escribiendo el ETL de GitHub Actions cada 30 minutos en horario
--   de mercado. Consecuencia honesta: la ventana de frescura de M4 no
--   puede ser 15 minutos para acciones, porque durante media hora de cada
--   treinta el precio sería «añejo» y ninguna orden se evaluaría nunca.
--   Se parte en dos: 15 min para cripto (el valor del doc 03 §5.4) y
--   35 min para acciones, MÁS la exigencia de que la bolsa esté abierta,
--   que es el guardarraíl que de verdad protege del riesgo R8 en una
--   acción. Fuera de sesión no se evalúa ni una orden de acciones.
--
-- D10 (2026-09-23) — EL SALDO INICIAL LO ELIGE EL USUARIO, entre 100 y
--   10.000 $ (los agentes seguirán arrancando con 500 $ en el Sprint 6).
--   Es dinero ficticio: la decisión D3 del dueño («no cifrar nunca, todo
--   el dinero indicado es ficticio») es la que permite que estos importes
--   vivan en columnas numéricas indexables en vez de en texto cifrado, y
--   por tanto que el cuadre del libro mayor sea un `SUM()`.
--
-- DOS DESVIACIONES DEL DISEÑO, DELIBERADAS Y ANOTADAS
--
--   1. `cuentas_simulacion.agente_id` se crea SIN clave ajena. La tabla
--      `agentes` no existe hasta el Sprint 6 (H-27) y es esa migración la
--      que añade el `ALTER TABLE … ADD CONSTRAINT`, como anticipa la nota
--      de orden de ejecución del doc 01 §7. El `CHECK` de titular único
--      sí se impone desde ya.
--   2. La función interna que registra movimientos se llama
--      `fn_registrar_movimiento`, no `rpc_registrar_movimiento` como la
--      nombra el doc 01 §5.1. El propio doc la describe como «interna,
--      nadie la llama desde fuera», y en este esquema el prefijo decide
--      los privilegios: `rpc_` lo ejecuta `authenticated` y `fn_` no
--      (invariantes I22 e I23). Llamarla `rpc_` y luego revocarla sería
--      contradecir la convención que sostiene esas dos invariantes.
-- ─────────────────────────────────────────────────────────────────────

-- ── Cuentas ─────────────────────────────────────────────────────────
-- Los parámetros de riesgo viven EN LA TABLA y no en variables de
-- entorno: es la deuda técnica nº3 de la Fase 1, donde el riesgo por
-- operación era una constante del backend y por tanto igual para todos.
create table public.cuentas_simulacion (
    id                        bigserial primary key,
    usuario_id                uuid   references public.perfiles(id) on delete cascade,
    -- FK a `agentes` en el Sprint 6 (H-27): la tabla aún no existe.
    agente_id                 bigint,
    saldo_inicial             numeric(20, 2) not null check (saldo_inicial > 0),
    saldo_disponible          numeric(20, 2) not null check (saldo_disponible >= 0),
    saldo_bloqueado           numeric(20, 2) not null default 0 check (saldo_bloqueado >= 0),
    capital_maximo_alcanzado  numeric(20, 2) not null,
    fase                      text not null default 'fase_1_aceleracion'
                              check (fase in ('fase_1_aceleracion', 'fase_2_consolidacion')),
    operaciones_en_fase       int not null default 0,
    riesgo_pct_operacion      numeric(5, 2) not null default 2.0
                              check (riesgo_pct_operacion > 0 and riesgo_pct_operacion <= 10),
    max_posiciones_abiertas   int not null default 3
                              check (max_posiciones_abiertas between 1 and 10),
    -- G3. El doc 03 §4 le da un rango de 40-60 % según el agente; para
    -- una cuenta de usuario el valor por defecto es el techo de §5.1.
    margen_comprometido_max_pct numeric(5, 2) not null default 60
                              check (margen_comprometido_max_pct > 0 and margen_comprometido_max_pct <= 100),
    -- G5. 90 minutos es el valor del doc 03 §4; por cuenta porque un
    -- agente de acciones y uno de cripto no toleran lo mismo.
    antiguedad_senal_max_min  int not null default 90 check (antiguedad_senal_max_min between 5 and 1440),
    -- El R:R mínimo del doc 01 §5.1. La Fase 1 emitía niveles sin
    -- comprobar que la operación mereciera la pena (regla N3).
    ratio_rr_minimo           numeric(5, 2) not null default 1.5 check (ratio_rr_minimo >= 0),
    estado                    text not null default 'activa'
                              check (estado in ('activa', 'pausada', 'inoperante', 'game_over')),
    creado_en                 timestamptz not null default now(),
    actualizado_en            timestamptz not null default now(),
    -- Exactamente un titular: usuario o agente, nunca ambos ni ninguno.
    constraint cuenta_un_solo_titular
        check ((usuario_id is not null) <> (agente_id is not null))
);

-- Una cuenta por usuario mientras el simulador sea de una sola cartera.
-- Es un índice parcial y no un UNIQUE de columna para que un futuro
-- «segunda cuenta archivada» no obligue a tocar el esquema.
create unique index cuentas_simulacion_una_por_usuario
    on public.cuentas_simulacion (usuario_id)
    where usuario_id is not null and estado <> 'game_over';

comment on column public.cuentas_simulacion.capital_maximo_alcanzado is
  'Pico de equity alcanzado. El drawdown de la máquina de fases se mide SIEMPRE desde aquí, nunca desde saldo_inicial (caso de prueba #2 del Risk Manager de la Fase 1).';

-- ── Órdenes ─────────────────────────────────────────────────────────
create table public.ordenes (
    id                      bigserial primary key,
    cuenta_id               bigint not null references public.cuentas_simulacion(id) on delete cascade,
    activo_id               bigint not null references public.activos(id),
    -- La señal que justificó la entrada. Sin esta columna no hay forma de
    -- auditar POR QUÉ se abrió una posición.
    senal_id                bigint references public.senales(id),
    lado                    text not null default 'largo' check (lado = 'largo'),
    estado                  text not null default 'abierta'
                            check (estado in ('propuesta', 'abierta', 'cerrada', 'cancelada', 'rechazada')),
    origen                  text not null check (origen in ('recomendacion', 'manual', 'agente')),
    precio_entrada          numeric(20, 8) not null check (precio_entrada > 0),
    fecha_entrada           timestamptz not null,
    cantidad                numeric(24, 8) not null check (cantidad > 0),
    apalancamiento          numeric(4, 1) not null check (apalancamiento >= 1 and apalancamiento <= 5),
    nominal                 numeric(20, 2) generated always as (cantidad * precio_entrada) stored,
    margen_comprometido     numeric(20, 2) not null check (margen_comprometido > 0),
    tp                      numeric(20, 8) not null,
    sl                      numeric(20, 8) not null,
    -- Riesgo R7: el tercer nivel que nadie declara. A 5x, una caída del
    -- 20 % agota el margen ANTES de que el precio llegue al stop.
    precio_liquidacion      numeric(20, 8) not null,
    precio_salida           numeric(20, 8),
    fecha_salida            timestamptz,
    motivo_cierre           text check (motivo_cierre in ('tp', 'sl', 'liquidacion', 'manual', 'caducidad')),
    -- El precio que DISPARÓ el cierre, distinto del nivel al que se
    -- liquida (regla M3). Permite medir el deslizamiento más adelante.
    precio_observado_cierre numeric(20, 8),
    pnl_bruto               numeric(20, 2),
    pnl_pct                 numeric(10, 4),
    racional                jsonb,
    creado_en               timestamptz not null default now(),
    actualizado_en          timestamptz not null default now(),
    -- Solo hay largos: un TP por debajo de la entrada es un bug, no una
    -- estrategia (regla protegida nº2).
    constraint orden_niveles_coherentes check (tp > precio_entrada and sl < precio_entrada),
    constraint orden_cierre_completo check (
        (estado = 'cerrada' and precio_salida is not null
                            and fecha_salida  is not null
                            and motivo_cierre is not null
                            and pnl_bruto     is not null)
        or estado <> 'cerrada'
    )
);

-- Solo una orden abierta por cuenta y activo: simplifica el monitor y
-- evita que un agente promedie a la baja sin que nadie lo decida.
create unique index ordenes_una_abierta_por_activo
    on public.ordenes (cuenta_id, activo_id) where estado = 'abierta';

create index ordenes_abiertas_idx on public.ordenes (activo_id) where estado = 'abierta';
create index ordenes_cuenta_fecha_idx on public.ordenes (cuenta_id, creado_en desc);

-- ── Libro mayor ─────────────────────────────────────────────────────
create table public.movimientos_saldo (
    id                          bigserial primary key,
    cuenta_id                   bigint not null references public.cuentas_simulacion(id) on delete cascade,
    -- Sin `on delete set null` (que es lo que propone el doc 01 §3.4):
    -- poner la columna a NULL es un UPDATE sobre el libro mayor, y el
    -- trigger de inmutabilidad lo rechazaría, dejando imposible borrar
    -- una orden. Con NO ACTION la relación se invierte y queda mejor: un
    -- apunte del libro mayor FIJA su orden. Borrar la cuenta entera sí
    -- funciona, porque el cascade borra órdenes y apuntes en la misma
    -- sentencia y la comprobación de la clave ajena es al final de ella.
    orden_id                    bigint references public.ordenes(id),
    tipo                        text not null check (tipo in (
                                    'deposito_inicial', 'bloqueo_margen', 'liberacion_margen',
                                    'resultado_operacion', 'ajuste_manual')),
    importe                     numeric(20, 2) not null,
    saldo_disponible_resultante numeric(20, 2) not null,
    saldo_bloqueado_resultante  numeric(20, 2) not null,
    creado_en                   timestamptz not null default now()
);

create index movimientos_saldo_cuenta_idx on public.movimientos_saldo (cuenta_id, id);

-- Un libro mayor que se puede editar no es un libro mayor. El trigger
-- va ADEMÁS de la RLS porque `service_role` elude la RLS por diseño: sin
-- él, el ETL o un script de mantenimiento podrían reescribir el pasado.
create function public.fn_libro_mayor_inmutable()
returns trigger
language plpgsql as $$
begin
    -- La única excepción, y no es una puerta trasera: cuando la cuenta ya
    -- no existe, este DELETE viene del `on delete cascade` de un borrado
    -- de cuenta o de perfil. Sin esta salida, dar de baja a un usuario
    -- sería imposible; y borrar la cuenta entera no falsifica un
    -- histórico, lo elimina. Reescribir el pasado CONSERVANDO la cuenta
    -- —que es el fraude del que protege un libro mayor— sigue prohibido:
    -- ahí la fila de `cuentas_simulacion` está presente y esto lanza.
    if tg_op = 'DELETE'
       and not exists (select 1 from public.cuentas_simulacion where id = old.cuenta_id) then
        return old;
    end if;

    raise exception 'movimientos_saldo es append-only: % no está permitido', tg_op
          using errcode = '42501';
end;
$$;

create trigger movimientos_saldo_inmutable
    before update or delete on public.movimientos_saldo
    for each row execute function public.fn_libro_mayor_inmutable();

-- ── Cola de peticiones de precio del monitor (D9) ───────────────────
-- `pg_net` es asíncrono: aquí se guarda el identificador de la petición
-- en vuelo para cosecharla en la pasada siguiente. Una fila por pasada.
create table public.monitor_peticiones (
    id          bigserial primary key,
    request_id  bigint not null,
    ids         text not null,
    pedido_en   timestamptz not null default now(),
    cosechado_en timestamptz,
    resultado   text
);

create index monitor_peticiones_pendientes_idx
    on public.monitor_peticiones (pedido_en) where cosechado_en is null;

-- ═════════════════════════════════════════════════════════════════════
-- Funciones auxiliares
-- ═════════════════════════════════════════════════════════════════════

-- Tope de apalancamiento por fase (G1). Espejo exacto de
-- `ParametrosRiesgo.leverage_tope_fase1/2` de `riesgo/maquina_fases.py`.
create function public.fn_tope_fase(p_fase text)
returns numeric
language sql immutable
as $$ select case when p_fase = 'fase_2_consolidacion' then 3.0 else 5.0 end::numeric $$;

-- Suelo a un decimal. `numeric(4,1)` no admite más, y redondear hacia
-- arriba el apalancamiento ajustado por liquidación volvería a poner la
-- liquidación por encima del stop, que es justo lo que se está evitando.
create function public.fn_piso_decimal(p_valor numeric)
returns numeric
language sql immutable
as $$ select floor(p_valor * 10) / 10 $$;

-- ¿Está abierta la bolsa estadounidense? Traducción de
-- `motor-analitico/ventana_mercado.py`, con sus mismos límites
-- (9:30–16:30 de Nueva York, sin festivos a propósito) y por el mismo
-- motivo: la decisión se toma en hora de Nueva York y no en UTC, porque
-- una ventana fija en UTC acierta seis meses al año.
create function public.fn_mercado_abierto(p_momento timestamptz default now())
returns boolean
language sql stable
as $$
    select extract(isodow from p_momento at time zone 'America/New_York') between 1 and 5
       and (p_momento at time zone 'America/New_York')::time between '09:30' and '16:30'
$$;

-- Ventana de frescura de precio por clase de activo (regla M4 y D9).
create function public.fn_frescura_precio_min(p_clase text)
returns int
language sql immutable
as $$ select case when p_clase = 'cripto' then 15 else 35 end $$;

comment on function public.fn_frescura_precio_min(text) is
  'M4: 15 min para cripto (valor del doc 03 §5.4). 35 para acciones porque su precio lo escribe el ETL cada 30 min y una ventana de 15 dejaría la mitad de las pasadas sin evaluar; el guardarraíl que protege ahí del riesgo R8 es fn_mercado_abierto().';

-- Equity: saldo disponible + bloqueado + P&L no realizado al precio de
-- este instante. NO es una columna a propósito (doc 01 §3.4): guardarlo
-- sería garantizar que esté desactualizado.
--
-- El `greatest(..., -margen)` es el mismo clamp que aplica el cierre: una
-- posición no puede perder más que su margen, porque por debajo de eso
-- hay liquidación, no deuda.
create function public.fn_equity(p_cuenta_id bigint)
returns numeric
language sql stable security definer
set search_path = public, pg_temp
as $$
    select c.saldo_disponible + c.saldo_bloqueado + coalesce((
               select sum(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                   -o.margen_comprometido))
                 from public.ordenes o
                 join public.activos a on a.id = o.activo_id
                where o.cuenta_id = c.id
                  and o.estado = 'abierta'
                  and a.ultimo_precio is not null), 0)
      from public.cuentas_simulacion c
     where c.id = p_cuenta_id
$$;

-- ── Dimensionado de posición (doc 03 §5.3) ──────────────────────────
-- Gemelo SQL de `motor-analitico/riesgo/dimensionado.py`. Existe en los
-- dos sitios por una razón concreta: el servidor NO puede confiar en un
-- tamaño calculado por el cliente (sería saltarse G2 y G3 escribiendo un
-- número), y el ciclo de agentes necesita simular tamaños en Python antes
-- de decidir a qué candidato entra. Los dos lados comparten los mismos
-- casos de prueba (`pruebas/test_dimensionado.py` e invariante I33).
--
-- DESVIACIÓN ANOTADA respecto al pseudocódigo del doc: el paso 6 termina
-- con `margen := nominal / apalancamiento`, que descarta los topes que el
-- paso 5 acababa de aplicar. Bajar el apalancamiento SUBE el margen
-- necesario, así que tal cual está escrito el paso 6 puede devolver un
-- margen por encima del saldo o del tope de G3. Aquí los topes se vuelven
-- a aplicar después del paso 6: son límites duros, y el orden en que se
-- escribió el pseudocódigo no los convierte en sugerencias.
create function public.fn_dimensionar_posicion(
    p_equity                numeric,
    p_saldo_disponible      numeric,
    p_saldo_bloqueado       numeric,
    p_precio                numeric,
    p_sl                    numeric,
    p_riesgo_pct            numeric,
    p_margen_max_pct        numeric,
    p_leverage_recomendado  numeric,
    p_leverage_propio       numeric,
    p_tope_fase             numeric,
    out cantidad            numeric,
    out apalancamiento      numeric,
    out margen              numeric,
    out precio_liquidacion  numeric,
    out motivo              text)
language plpgsql immutable
as $$
declare
    v_riesgo_max   numeric;
    v_distancia    numeric;
    v_nominal      numeric;
    v_margen_libre numeric;
begin
    -- 1. Cuánto se está dispuesto a PERDER en esta operación.
    v_riesgo_max := p_equity * p_riesgo_pct / 100;

    -- 2. Distancia relativa al stop: es lo que convierte riesgo en tamaño.
    v_distancia := (p_precio - p_sl) / p_precio;
    if v_distancia <= 0 then
        motivo := 'stop_por_encima_del_precio';
        return;
    end if;

    -- 3. Nominal que hace que tocar el SL cueste exactamente riesgo_max.
    v_nominal := v_riesgo_max / v_distancia;

    -- 4. Tres topes de apalancamiento; el de la fase manda (G1).
    apalancamiento := least(coalesce(p_leverage_recomendado, p_tope_fase),
                            coalesce(p_leverage_propio, p_tope_fase),
                            p_tope_fase);
    if apalancamiento < 1 then
        motivo := 'apalancamiento_bajo_uno';
        return;
    end if;

    -- 6. La liquidación puede llegar ANTES que el stop. Si pasa, el riesgo
    --    real es el margen entero y no `riesgo_max`, así que se BAJA el
    --    apalancamiento en vez de aceptar una operación cuyo riesgo no es
    --    el declarado (regla N4, coherente con la regla protegida nº4:
    --    ante ambigüedad de riesgo, se degrada hacia el mínimo).
    precio_liquidacion := p_precio * (1 - 1 / apalancamiento);
    if precio_liquidacion > p_sl then
        apalancamiento := public.fn_piso_decimal(1 / v_distancia) - 0.1;
        if apalancamiento < 1.0 then
            motivo := 'sin_operacion_liquidacion_antes_del_stop';
            return;
        end if;
        precio_liquidacion := p_precio * (1 - 1 / apalancamiento);
    end if;

    -- 5. Topes por saldo y por margen total comprometido (G3). Después
    --    del paso 6, no antes: ver la desviación anotada arriba.
    v_margen_libre := p_equity * p_margen_max_pct / 100 - p_saldo_bloqueado;
    margen := least(v_nominal / apalancamiento,
                    p_saldo_disponible * 0.95,
                    v_margen_libre);
    -- Céntimos hacia abajo: redondear hacia arriba podría pedir un
    -- céntimo más de margen del que hay y abortar el INSERT por el CHECK.
    margen := floor(margen * 100) / 100;
    if margen <= 0 then
        motivo := 'margen_insuficiente';
        return;
    end if;

    cantidad := round(margen * apalancamiento / p_precio, 8);
    if cantidad <= 0 then
        motivo := 'cantidad_nula';
        return;
    end if;
    motivo := null;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- Vistas. Todas con `security_invoker = true` (invariante I13): sin esa
-- opción una vista se ejecuta con los permisos de su propietario y se
-- salta la RLS, que es exactamente lo que ocurrió en producción el
-- 2026-09-21 con las dos vistas del Sprint 1.
-- ═════════════════════════════════════════════════════════════════════

create view public.v_cuentas_equity
with (security_invoker = true) as
    select c.*,
           coalesce(p.pnl_no_realizado, 0) as pnl_no_realizado,
           c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0) as equity,
           coalesce(p.posiciones_abiertas, 0) as posiciones_abiertas,
           public.fn_tope_fase(c.fase) as leverage_tope,
           case when c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0) > 0
                then round(c.saldo_bloqueado * 100
                           / (c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)), 2)
           end as margen_comprometido_pct,
           case when c.capital_maximo_alcanzado > 0
                then round((c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)
                            - c.capital_maximo_alcanzado) * 100 / c.capital_maximo_alcanzado, 2)
           end as drawdown_pct
      from public.cuentas_simulacion c
      left join lateral (
           select sum(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                               -o.margen_comprometido)) as pnl_no_realizado,
                  count(*) as posiciones_abiertas
             from public.ordenes o
             join public.activos a on a.id = o.activo_id
            where o.cuenta_id = c.id and o.estado = 'abierta'
              and a.ultimo_precio is not null
      ) p on true;

-- Órdenes que el monitor PUEDE evaluar. El filtro de antigüedad es la
-- regla M4 y vive aquí y no en el bucle: si mañana alguien escribe otro
-- consumidor del monitor, hereda la protección del riesgo R8 gratis.
create view public.v_ordenes_abiertas_monitor
with (security_invoker = true) as
    select o.id, o.cuenta_id, o.activo_id, o.precio_entrada, o.cantidad,
           o.apalancamiento, o.margen_comprometido, o.tp, o.sl, o.precio_liquidacion,
           a.simbolo, a.clase, a.ultimo_precio as precio_vivo, a.ultimo_precio_en
      from public.ordenes o
      join public.activos a on a.id = o.activo_id
      join public.cuentas_simulacion c on c.id = o.cuenta_id
     where o.estado = 'abierta'
       and c.estado in ('activa', 'pausada', 'inoperante')
       and a.ultimo_precio is not null
       and a.ultimo_precio_en > now() - (public.fn_frescura_precio_min(a.clase) || ' minutes')::interval
       -- Fuera de sesión una acción no se evalúa: su «último precio» es
       -- el del cierre y cerrar contra él sería inventar una ejecución.
       and (a.clase = 'cripto' or public.fn_mercado_abierto(now()));

-- Las órdenes del usuario, con P&L flotante al precio vivo. El frontend
-- nunca consulta la tabla base.
create view public.v_mis_ordenes
with (security_invoker = true) as
    select o.id, o.cuenta_id, o.activo_id, o.senal_id, o.estado, o.origen,
           o.precio_entrada, o.fecha_entrada, o.cantidad, o.apalancamiento,
           o.nominal, o.margen_comprometido, o.tp, o.sl, o.precio_liquidacion,
           o.precio_salida, o.fecha_salida, o.motivo_cierre, o.precio_observado_cierre,
           o.pnl_bruto, o.pnl_pct, o.racional, o.creado_en,
           a.simbolo, a.clase, a.nombre, a.ultimo_precio, a.ultimo_precio_en,
           case when o.estado = 'abierta' and a.ultimo_precio is not null
                then round(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                    -o.margen_comprometido), 2)
           end as pnl_flotante,
           case when o.estado = 'abierta' and a.ultimo_precio is not null and o.margen_comprometido > 0
                then round(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                    -o.margen_comprometido) * 100 / o.margen_comprometido, 2)
           end as pnl_flotante_pct_margen
      from public.ordenes o
      join public.activos a on a.id = o.activo_id
     where o.cuenta_id in (select id from public.cuentas_simulacion where usuario_id = auth.uid());

-- Entradas sugeridas: las señales operables y frescas de la cartera del
-- usuario, con el tamaño que el dimensionado propone para SU cuenta. El
-- tamaño se calcula aquí y no en el navegador porque el servidor no puede
-- confiar en un número que venga del cliente (G2 y G3).
create view public.v_recomendaciones_usuario
with (security_invoker = true) as
    select e.activo_id, e.simbolo, e.clase, e.nombre, e.senal_id,
           e.precio_actual, e.tp, e.sl, e.ratio_rr, e.fuerza, e.direccion,
           e.atr_pct, e.leverage_recomendado, e.leverage_tope,
           e.leverage_referencia_volatilidad, e.leverage_motivo, e.niveles_origen,
           e.soporte, e.resistencia, e.indicadores_alcistas, e.indicadores_bajistas,
           e.resumen_confluencia, e.calculado_en, e.antiguedad_min,
           e.cuenta_id, e.riesgo_pct_operacion, e.equity,
           d.cantidad, d.apalancamiento, d.margen, d.precio_liquidacion, d.motivo,
           (d.motivo is null and e.ratio_rr >= e.ratio_rr_minimo) as confirmable
      from (
           select sv.activo_id, sv.simbolo, sv.clase, sv.nombre, sv.id as senal_id,
                  sv.precio_actual, sv.tp, sv.sl, sv.ratio_rr, sv.fuerza, sv.direccion,
                  sv.atr_pct, sv.leverage_recomendado, sv.leverage_tope,
                  sv.leverage_referencia_volatilidad, sv.leverage_motivo, sv.niveles_origen,
                  sv.soporte, sv.resistencia, sv.indicadores_alcistas, sv.indicadores_bajistas,
                  sv.resumen_confluencia, sv.calculado_en,
                  round(extract(epoch from now() - sv.calculado_en) / 60)::int as antiguedad_min,
                  ce.id as cuenta_id, ce.riesgo_pct_operacion, ce.equity,
                  ce.saldo_disponible, ce.saldo_bloqueado, ce.margen_comprometido_max_pct,
                  ce.ratio_rr_minimo, ce.fase
             from public.v_escaner_usuario sv
             join public.v_cuentas_equity ce on ce.usuario_id = auth.uid() and ce.estado = 'activa'
            where sv.operable
              and sv.estado_activo = 'activo'
              and sv.calculado_en > now() - (ce.antiguedad_senal_max_min || ' minutes')::interval
              and not exists (select 1 from public.ordenes o
                               where o.cuenta_id = ce.id and o.activo_id = sv.activo_id
                                 and o.estado = 'abierta')
      ) e
      cross join lateral public.fn_dimensionar_posicion(
           e.equity, e.saldo_disponible, e.saldo_bloqueado,
           e.precio_actual, e.sl, e.riesgo_pct_operacion, e.margen_comprometido_max_pct,
           e.leverage_recomendado, null, public.fn_tope_fase(e.fase)) d;

-- ═════════════════════════════════════════════════════════════════════
-- El único camino de escritura. `authenticated` no tiene INSERT ni UPDATE
-- sobre `ordenes` ni sobre `movimientos_saldo`: solo EXECUTE sobre estas
-- funciones (doc 01 §5.1).
-- ═════════════════════════════════════════════════════════════════════

-- Escribe el apunte Y actualiza el saldo materializado en la MISMA
-- sentencia. Que las dos cosas no puedan ocurrir por separado es lo que
-- hace que la consulta de cuadre del doc 01 §5.2 devuelva cero filas por
-- construcción y no por suerte.
create function public.fn_registrar_movimiento(
    p_cuenta_id       bigint,
    p_orden_id        bigint,
    p_tipo            text,
    p_importe         numeric,
    p_delta_bloqueado numeric default 0)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_disp numeric(20, 2);
    v_bloq numeric(20, 2);
begin
    update public.cuentas_simulacion
       set saldo_disponible = saldo_disponible + p_importe,
           saldo_bloqueado  = saldo_bloqueado + p_delta_bloqueado,
           capital_maximo_alcanzado = greatest(
               capital_maximo_alcanzado,
               saldo_disponible + p_importe + saldo_bloqueado + p_delta_bloqueado),
           actualizado_en = now()
     where id = p_cuenta_id
    returning saldo_disponible, saldo_bloqueado into v_disp, v_bloq;

    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id;
    end if;

    insert into public.movimientos_saldo
        (cuenta_id, orden_id, tipo, importe,
         saldo_disponible_resultante, saldo_bloqueado_resultante)
    values (p_cuenta_id, p_orden_id, p_tipo, p_importe, v_disp, v_bloq);
end;
$$;

-- ── H-22 · Crear la cuenta ──────────────────────────────────────────
-- El saldo lo elige el dueño (decisión D10). Los 500 $ de los agentes
-- llegan en el Sprint 6 y usarán esta misma función.
create function public.rpc_crear_cuenta_simulacion(p_saldo_inicial numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid    uuid := public.fn_exigir_aprobado();
    v_cuenta bigint;
begin
    if p_saldo_inicial is null or p_saldo_inicial < 100 or p_saldo_inicial > 10000 then
        raise exception 'El saldo inicial debe estar entre 100 y 10.000 $ (ficticios). Recibido: %',
              coalesce(p_saldo_inicial::text, 'nada') using errcode = '22023';
    end if;

    if exists (select 1 from public.cuentas_simulacion
                where usuario_id = v_uid and estado <> 'game_over') then
        raise exception 'Ya tienes una cuenta de simulación abierta.' using errcode = 'P0001';
    end if;

    -- Nace con saldo cero y el depósito entra por el libro mayor. Si se
    -- creara ya con el saldo puesto, el primer apunte sería una copia
    -- decorativa de un número que ya estaba escrito: exactamente el vicio
    -- que este diseño evita.
    insert into public.cuentas_simulacion
        (usuario_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
    values (v_uid, round(p_saldo_inicial, 2), 0, 0)
    returning id into v_cuenta;

    perform public.fn_registrar_movimiento(
        v_cuenta, null, 'deposito_inicial', round(p_saldo_inicial, 2), 0);

    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (v_uid, 'sys', 'Cuenta de simulación creada',
            jsonb_build_object('cuenta_id', v_cuenta, 'saldo_inicial', round(p_saldo_inicial, 2)));

    return jsonb_build_object('cuenta_id', v_cuenta, 'saldo_inicial', round(p_saldo_inicial, 2));
end;
$$;

-- ── H-24 · Máquina de fases ─────────────────────────────────────────
-- Traducción de `motor-analitico/riesgo/maquina_fases.py`, con sus cuatro
-- reglas y su ORDEN, que no es decorativo: gana el PRIMER criterio que se
-- cumple, y así un cierre que dispara dos criterios a la vez genera un
-- solo evento (caso de prueba #4 del Risk Manager).
create function public.rpc_evaluar_fase(p_cuenta_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuenta   public.cuentas_simulacion;
    v_equity   numeric;
    v_drawdown numeric;
    v_multiplo numeric;
    v_criterio text;
    v_detalle  text;
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id;
    end if;

    -- Regla nº3 del módulo de Python: Fase 2 NUNCA vuelve a Fase 1 por
    -- una evaluación automática, por mucho que crezca el capital.
    if v_cuenta.fase = 'fase_2_consolidacion' then
        return jsonb_build_object('cambio', false, 'fase', v_cuenta.fase);
    end if;

    v_equity := public.fn_equity(p_cuenta_id);

    -- Regla nº2: el drawdown se mide desde el PICO, nunca desde el
    -- capital inicial. Es el punto donde el Risk Manager de la Fase 1
    -- encontró el bug (caso de prueba #2).
    v_drawdown := case when v_cuenta.capital_maximo_alcanzado > 0
                       then (v_equity - v_cuenta.capital_maximo_alcanzado)
                            / v_cuenta.capital_maximo_alcanzado * 100
                       else 0 end;
    v_multiplo := v_equity / v_cuenta.saldo_inicial;

    if v_drawdown <= -30 then
        v_criterio := 'drawdown_maximo';
        v_detalle  := format('Drawdown de %s%% desde el máximo alcanzado (límite: -30%%)',
                             round(v_drawdown, 1));
    elsif v_multiplo >= 3 then
        v_criterio := 'multiplo_capital';
        v_detalle  := format('Capital alcanzó %sx el inicial (umbral: 3x)', round(v_multiplo, 2));
    elsif v_cuenta.operaciones_en_fase >= 8 then
        v_criterio := 'revaluacion_operaciones';
        v_detalle  := format('Revaluación tras %s operaciones en Fase 1 (umbral: 8)',
                             v_cuenta.operaciones_en_fase);
    else
        return jsonb_build_object('cambio', false, 'fase', v_cuenta.fase);
    end if;

    update public.cuentas_simulacion
       set fase = 'fase_2_consolidacion',
           operaciones_en_fase = 0,
           actualizado_en = now()
     where id = p_cuenta_id;

    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (v_cuenta.usuario_id, 'cambio_fase',
            'Paso a Fase 2 (consolidación): ' || v_detalle,
            jsonb_build_object('cuenta_id', p_cuenta_id, 'criterio', v_criterio,
                               'equity', round(v_equity, 2),
                               'leverage_tope', public.fn_tope_fase('fase_2_consolidacion')));

    return jsonb_build_object('cambio', true, 'fase', 'fase_2_consolidacion',
                              'criterio', v_criterio, 'detalle', v_detalle);
end;
$$;

-- Único camino de regreso a Fase 1 (regla protegida nº5). Sin
-- `p_confirmacion = true` lanza, igual que `revertir_a_fase1_manualmente`
-- lanza `PermissionError` en el módulo de Python.
create function public.rpc_revertir_fase_manual(p_cuenta_id bigint, p_confirmacion boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuenta public.cuentas_simulacion;
    v_equity numeric;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador puede revertir la fase de una cuenta.'
              using errcode = '42501';
    end if;
    if p_confirmacion is not true then
        raise exception 'El regreso a Fase 1 exige confirmación explícita: nunca ocurre automáticamente.'
              using errcode = 'P0001';
    end if;

    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id;
    end if;

    v_equity := public.fn_equity(p_cuenta_id);

    -- El pico se reancla al capital de hoy, como hace el módulo de Python:
    -- si no, el drawdown se mediría contra un máximo de otra época y la
    -- cuenta volvería a Fase 2 en el primer cierre en rojo.
    update public.cuentas_simulacion
       set fase = 'fase_1_aceleracion',
           capital_maximo_alcanzado = round(v_equity, 2),
           operaciones_en_fase = 0,
           actualizado_en = now()
     where id = p_cuenta_id;

    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), 'revertir_fase', 'cuenta_simulacion', p_cuenta_id::text,
            jsonb_build_object('equity', round(v_equity, 2),
                               'fase_anterior', v_cuenta.fase,
                               'motivo', 'Reversión manual confirmada a Fase 1'));

    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (v_cuenta.usuario_id, 'cambio_fase', 'Reversión manual a Fase 1 (aceleración)',
            jsonb_build_object('cuenta_id', p_cuenta_id, 'criterio', 'manual'));

    return jsonb_build_object('fase', 'fase_1_aceleracion', 'criterio', 'manual');
end;
$$;

-- ── H-24 · Game Over y ruina técnica (doc 03 §5.5) ──────────────────
create function public.rpc_evaluar_game_over(p_cuenta_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuenta    public.cuentas_simulacion;
    v_equity    numeric;
    v_abiertas  int;
    v_orden     record;
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id;
    end if;

    -- Un Game Over es TERMINAL y no se revierte (regla N14). Este retorno
    -- temprano es además lo que corta la recursión: al declarar el Game
    -- Over se cierran las posiciones que quedaran, y cada cierre vuelve a
    -- llamar aquí.
    if v_cuenta.estado = 'game_over' then
        return jsonb_build_object('estado', 'game_over', 'nuevo', false);
    end if;

    v_equity := public.fn_equity(p_cuenta_id);
    select count(*) into v_abiertas
      from public.ordenes where cuenta_id = p_cuenta_id and estado = 'abierta';

    if v_equity <= 0 then
        update public.cuentas_simulacion
           set estado = 'game_over', actualizado_en = now() where id = p_cuenta_id;

        insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
        values (v_cuenta.usuario_id, 'game_over',
                'Game Over: el equity llegó a cero',
                jsonb_build_object('cuenta_id', p_cuenta_id, 'equity', round(v_equity, 2)));

        -- Lo que quede abierto se liquida. Se cierra al precio de
        -- liquidación y no al precio vivo: es el nivel al que el margen se
        -- agota, y es el mismo criterio de la regla M3.
        for v_orden in select id, precio_liquidacion from public.ordenes
                        where cuenta_id = p_cuenta_id and estado = 'abierta'
        loop
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.precio_liquidacion, 'liquidacion', null);
        end loop;

        return jsonb_build_object('estado', 'game_over', 'nuevo', true);
    end if;

    -- Ruina técnica: queda dinero, pero no el suficiente para abrir una
    -- posición que respete el riesgo por operación. NO es Game Over, y
    -- distinguirlo importa: una cuenta 'inoperante' con 8 $ no ha fallado
    -- igual que una con 0 $, y el experimento debe poder diferenciarlas.
    if v_equity < 10 and v_abiertas = 0 then
        if v_cuenta.estado <> 'inoperante' then
            update public.cuentas_simulacion
               set estado = 'inoperante', actualizado_en = now() where id = p_cuenta_id;
            insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
            values (v_cuenta.usuario_id, 'deterioro',
                    'Cuenta inoperante: el equity no alcanza el margen mínimo de 10 $',
                    jsonb_build_object('cuenta_id', p_cuenta_id, 'equity', round(v_equity, 2)));
        end if;
        return jsonb_build_object('estado', 'inoperante', 'nuevo', v_cuenta.estado <> 'inoperante');
    end if;

    -- Se recupera de 'inoperante' sola si el equity vuelve a dar para
    -- operar; de 'game_over' jamás.
    if v_cuenta.estado = 'inoperante' and v_equity >= 10 then
        update public.cuentas_simulacion
           set estado = 'activa', actualizado_en = now() where id = p_cuenta_id;
        return jsonb_build_object('estado', 'activa', 'nuevo', true);
    end if;

    return jsonb_build_object('estado', v_cuenta.estado, 'nuevo', false);
end;
$$;

-- ── H-24 · El RPC crítico: cierre idempotente (doc 01 §8) ───────────
-- Aquí se vive o se muere el riesgo R4 (doble cierre -> saldo inflado).
-- La clave son tres cosas: el `for update`, el `where estado = 'abierta'`
-- del UPDATE, y el retorno temprano SIN excepción.
create function public.rpc_cerrar_orden(
    p_orden_id         bigint,
    p_precio_salida    numeric,
    p_motivo           text,
    p_precio_observado numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_orden    public.ordenes;
    v_cuenta   public.cuentas_simulacion;
    v_pnl      numeric(20, 2);
    v_pnl_pct  numeric(10, 4);
    v_simbolo  text;
begin
    -- Bloqueo pesimista: si dos pasadas del monitor entran a la vez, la
    -- segunda espera aquí y al continuar encuentra estado <> 'abierta'.
    select * into v_orden from public.ordenes where id = p_orden_id for update;
    if not found then
        raise exception 'La orden % no existe', p_orden_id;
    end if;

    -- Idempotencia. NO es un error: en un monitor concurrente encontrarse
    -- una orden ya cerrada es el caso normal. Si esto lanzara, el registro
    -- se llenaría de errores falsos y el verdadero se perdería.
    if v_orden.estado <> 'abierta' then
        return jsonb_build_object(
            'cerrada', false,
            'motivo', 'la orden ya estaba en estado ' || v_orden.estado);
    end if;

    select * into v_cuenta from public.cuentas_simulacion
     where id = v_orden.cuenta_id for update;

    v_pnl := round(v_orden.cantidad * (p_precio_salida - v_orden.precio_entrada), 2);
    v_pnl_pct := round(
        ((p_precio_salida - v_orden.precio_entrada) / v_orden.precio_entrada) * 100, 4);

    -- El margen no puede perder más de lo comprometido: por debajo de eso
    -- hay liquidación, no deuda. Sin este clamp, un hueco de mercado
    -- dejaría el saldo en negativo, el CHECK (saldo_disponible >= 0)
    -- abortaría la transacción, y la orden quedaría abierta PARA SIEMPRE:
    -- el peor fallo posible en un monitor automático.
    if v_pnl < -v_orden.margen_comprometido then
        v_pnl := -v_orden.margen_comprometido;
    end if;

    update public.ordenes set
        estado = 'cerrada',
        precio_salida = p_precio_salida,
        fecha_salida = now(),
        motivo_cierre = p_motivo,
        precio_observado_cierre = coalesce(p_precio_observado, p_precio_salida),
        pnl_bruto = v_pnl,
        pnl_pct = v_pnl_pct,
        actualizado_en = now()
      where id = p_orden_id and estado = 'abierta';   -- cinturón y tirantes

    if not found then
        raise exception 'Carrera detectada al cerrar la orden %', p_orden_id;
    end if;

    -- DOS apuntes, no uno: liberar el margen y aplicar el resultado son
    -- hechos económicos distintos. Fusionarlos en un movimiento neto hace
    -- imposible reconstruir cuánto margen estuvo comprometido y cuándo,
    -- que es justo lo que se necesita para auditar el riesgo.
    perform public.fn_registrar_movimiento(
        v_orden.cuenta_id, p_orden_id, 'liberacion_margen',
        v_orden.margen_comprometido, -v_orden.margen_comprometido);
    perform public.fn_registrar_movimiento(
        v_orden.cuenta_id, p_orden_id, 'resultado_operacion', v_pnl, 0);

    update public.cuentas_simulacion
       set operaciones_en_fase = operaciones_en_fase + 1, actualizado_en = now()
     where id = v_orden.cuenta_id;

    select simbolo into v_simbolo from public.activos where id = v_orden.activo_id;
    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (v_cuenta.usuario_id, 'orden_cerrada',
            format('%s cerrada por %s: %s $', v_simbolo, p_motivo, v_pnl),
            jsonb_build_object('orden_id', p_orden_id, 'cuenta_id', v_orden.cuenta_id,
                               'simbolo', v_simbolo, 'motivo', p_motivo,
                               'precio_salida', p_precio_salida,
                               'precio_observado', coalesce(p_precio_observado, p_precio_salida),
                               'pnl', v_pnl, 'pnl_pct', v_pnl_pct));

    -- Máquina de fases y Game Over, en ese orden.
    perform public.rpc_evaluar_fase(v_orden.cuenta_id);
    perform public.rpc_evaluar_game_over(v_orden.cuenta_id);

    return jsonb_build_object('cerrada', true, 'pnl', v_pnl, 'pnl_pct', v_pnl_pct,
                              'saldo_disponible',
                              (select saldo_disponible from public.cuentas_simulacion
                                where id = v_orden.cuenta_id));
end;
$$;

-- Cierre a mano desde la interfaz. Existe aparte porque `rpc_cerrar_orden`
-- acepta cualquier precio y motivo —el monitor lo necesita así— y eso no
-- puede quedar en manos del navegador: aquí el precio es el vivo del
-- mercado y el motivo es siempre 'manual'.
create function public.rpc_cerrar_manual(p_orden_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid    uuid := public.fn_exigir_aprobado();
    v_precio numeric;
    v_clase  text;
    v_edad   int;
begin
    if not exists (select 1 from public.ordenes o
                     join public.cuentas_simulacion c on c.id = o.cuenta_id
                    where o.id = p_orden_id and c.usuario_id = v_uid) then
        raise exception 'Esa orden no es tuya.' using errcode = '42501';
    end if;

    select a.ultimo_precio, a.clase,
           round(extract(epoch from now() - a.ultimo_precio_en) / 60)::int
      into v_precio, v_clase, v_edad
      from public.ordenes o join public.activos a on a.id = o.activo_id
     where o.id = p_orden_id;

    if v_precio is null then
        raise exception 'No hay precio para ese activo: no se puede cerrar a ciegas.'
              using errcode = 'P0001';
    end if;
    -- Mismo criterio que la regla M4: sin precio fresco no se cierra, ni a
    -- mano. Un cierre contra el precio del viernes es una ejecución
    -- inventada, tanto si la pide el monitor como si la pide una persona.
    if v_edad > public.fn_frescura_precio_min(v_clase) then
        raise exception 'El último precio es de hace % minutos: espera a que se actualice.', v_edad
              using errcode = 'P0001';
    end if;

    return public.rpc_cerrar_orden(p_orden_id, v_precio, 'manual', v_precio);
end;
$$;

-- ── H-23 · Apertura con los cinco guardarraíles (doc 03 §4) ─────────
-- Los cinco límites los impone ESTA función, no el código del agente ni
-- el navegador. Un agente con un bug, una estrategia con un valor absurdo
-- o una llamada a mano no pueden saltárselos.
--
-- El activo NO es un parámetro: se deduce de la señal. Si viniera aparte,
-- un cliente podría mandar la señal de un activo y el id de otro, y todos
-- los niveles (tp, sl, liquidación) quedarían referidos al activo
-- equivocado. La señal ya sabe de qué activo habla.
--
-- Lo que el usuario SÍ ajusta (requisito 6) es el precio de entrada y la
-- fecha. Los niveles no: son del motor.
create function public.rpc_abrir_orden(
    p_cuenta_id      bigint,
    p_senal_id       bigint,
    p_precio_entrada numeric default null,
    p_fecha_entrada  timestamptz default null,
    p_apalancamiento numeric default null,
    p_riesgo_pct     numeric default null,
    p_origen         text default 'recomendacion',
    p_racional       jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid        uuid := auth.uid();
    v_cuenta     public.cuentas_simulacion;
    v_senal      record;
    v_equity     numeric;
    v_tope       numeric;
    v_precio     numeric;
    v_fecha      timestamptz;
    v_riesgo_pct numeric;
    v_rr         numeric;
    v_abiertas   int;
    v_dim        record;
    v_orden      bigint;
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id using errcode = '42501';
    end if;

    -- Quién puede operar esta cuenta. Las de usuario, su dueño aprobado;
    -- las de agente, solo el servidor (`service_role`, donde auth.uid() es
    -- nulo). Sin esta bifurcación, un usuario aprobado podría abrir
    -- órdenes en la cuenta de un agente y contaminar el experimento.
    if v_cuenta.usuario_id is not null then
        if v_uid is null or v_uid <> v_cuenta.usuario_id or not public.es_usuario_aprobado() then
            raise exception 'Esa cuenta no es tuya.' using errcode = '42501';
        end if;
    elsif v_uid is not null then
        raise exception 'Las cuentas de agente solo las opera el servidor.' using errcode = '42501';
    end if;

    if v_cuenta.estado <> 'activa' then
        raise exception 'La cuenta está en estado «%»: no admite operaciones nuevas.', v_cuenta.estado
              using errcode = 'P0001';
    end if;
    if p_origen not in ('recomendacion', 'manual', 'agente') then
        raise exception 'Origen no válido: %', p_origen using errcode = '22023';
    end if;

    -- ── G5 · Solo señales operables y frescas ───────────────────────
    -- Regla protegida nº4: sin volatilidad conocida no se opera. Y una
    -- señal de ayer no describe el mercado de hoy.
    select s.id, s.activo_id, s.operable, s.precio_actual, s.tp, s.sl,
           s.leverage_recomendado, s.calculado_en, a.clase, a.simbolo,
           a.estado as estado_activo,
           round(extract(epoch from now() - s.calculado_en) / 60)::int as antiguedad_min
      into v_senal
      from public.senales s join public.activos a on a.id = s.activo_id
     where s.id = p_senal_id;
    if not found then
        raise exception 'La señal % no existe', p_senal_id using errcode = '22023';
    end if;
    if not v_senal.operable then
        raise exception 'La señal de % no es operable: el motor no encuadra ninguna operación con ella.',
              v_senal.simbolo using errcode = 'P0001';
    end if;
    if v_senal.antiguedad_min > v_cuenta.antiguedad_senal_max_min then
        raise exception 'La señal de % es de hace % minutos (máximo %): pide un escaneo nuevo.',
              v_senal.simbolo, v_senal.antiguedad_min, v_cuenta.antiguedad_senal_max_min
              using errcode = 'P0001';
    end if;
    if v_senal.estado_activo <> 'activo' then
        raise exception 'El activo % está en estado «%»: sus datos no son fiables ahora mismo.',
              v_senal.simbolo, v_senal.estado_activo using errcode = 'P0001';
    end if;

    -- Un usuario solo opera lo que sigue: es el mismo universo que le
    -- muestra el escáner, y mantenerlo así evita que una señal enlazada
    -- desde fuera abra posiciones sobre activos que no vigila.
    if v_cuenta.usuario_id is not null
       and not exists (select 1 from public.cartera_activos ca
                         join public.carteras c on c.id = ca.cartera_id
                        where c.usuario_id = v_cuenta.usuario_id
                          and ca.activo_id = v_senal.activo_id) then
        raise exception 'No sigues %: añádelo a tu cartera antes de operarlo.', v_senal.simbolo
              using errcode = 'P0001';
    end if;

    -- ── G4 · Posiciones abiertas simultáneas ────────────────────────
    select count(*) into v_abiertas
      from public.ordenes where cuenta_id = p_cuenta_id and estado = 'abierta';
    if v_abiertas >= v_cuenta.max_posiciones_abiertas then
        raise exception 'Ya tienes % posiciones abiertas (máximo %). Tres posiciones en el mismo mercado son una sola apuesta con tres nombres.',
              v_abiertas, v_cuenta.max_posiciones_abiertas using errcode = 'P0001';
    end if;
    if exists (select 1 from public.ordenes
                where cuenta_id = p_cuenta_id and activo_id = v_senal.activo_id
                  and estado = 'abierta') then
        raise exception 'Ya tienes una posición abierta en %.', v_senal.simbolo
              using errcode = 'P0001';
    end if;

    -- Precio y fecha: lo único que el usuario ajusta.
    v_precio := coalesce(p_precio_entrada, v_senal.precio_actual);
    v_fecha  := coalesce(p_fecha_entrada, now());
    if v_precio is null or v_precio <= 0 then
        raise exception 'El precio de entrada debe ser mayor que cero.' using errcode = '22023';
    end if;
    if v_fecha > now() then
        raise exception 'La fecha de entrada no puede estar en el futuro.' using errcode = '22023';
    end if;
    if v_fecha < now() - interval '30 days' then
        raise exception 'La fecha de entrada no puede tener más de 30 días.' using errcode = '22023';
    end if;
    -- Los niveles son del motor; con el precio ajustado tienen que seguir
    -- encuadrando la operación. Si el usuario escribe una entrada por
    -- encima del TP, no hay operación que registrar.
    if not (v_senal.tp > v_precio and v_senal.sl < v_precio) then
        raise exception 'Con una entrada de % los niveles no encuadran: el objetivo está en % y el stop en %.',
              round(v_precio, 8), round(v_senal.tp, 8), round(v_senal.sl, 8)
              using errcode = 'P0001';
    end if;

    v_rr := (v_senal.tp - v_precio) / (v_precio - v_senal.sl);
    if v_rr < v_cuenta.ratio_rr_minimo then
        raise exception 'Relación riesgo/beneficio de %: por debajo del mínimo de % que exige tu cuenta.',
              round(v_rr, 2), v_cuenta.ratio_rr_minimo using errcode = 'P0001';
    end if;

    -- ── G1 · Apalancamiento <= tope de la FASE de la cuenta ─────────
    -- Se RECHAZA, no se recorta en silencio: si el cliente pide 6x, lo que
    -- tiene que aprender es que 6x no existe aquí, no recibir una orden a
    -- 5x que no ha pedido.
    v_tope := public.fn_tope_fase(v_cuenta.fase);
    if p_apalancamiento is not null and p_apalancamiento > v_tope then
        raise exception 'Apalancamiento %x rechazado: el tope de la % es %x.',
              p_apalancamiento, replace(v_cuenta.fase, '_', ' '), v_tope using errcode = 'P0001';
    end if;
    if p_apalancamiento is not null and p_apalancamiento < 1 then
        raise exception 'El apalancamiento mínimo es 1x.' using errcode = '22023';
    end if;

    -- ── G2 · Riesgo por operación <= 10 % del equity ────────────────
    v_riesgo_pct := coalesce(p_riesgo_pct, v_cuenta.riesgo_pct_operacion);
    if v_riesgo_pct <= 0 or v_riesgo_pct > 10 then
        raise exception 'El riesgo por operación debe estar entre 0 y 10 %% del equity. Recibido: %',
              v_riesgo_pct using errcode = 'P0001';
    end if;

    v_equity := public.fn_equity(p_cuenta_id);
    if v_equity < 10 then
        raise exception 'Equity de % $: por debajo del margen mínimo de 10 $ no se abre nada.',
              round(v_equity, 2) using errcode = 'P0001';
    end if;

    select * into v_dim from public.fn_dimensionar_posicion(
        v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
        v_precio, v_senal.sl, v_riesgo_pct, v_cuenta.margen_comprometido_max_pct,
        coalesce(p_apalancamiento, v_senal.leverage_recomendado), p_apalancamiento, v_tope);

    if v_dim.motivo = 'sin_operacion_liquidacion_antes_del_stop' then
        raise exception 'El stop queda por debajo del precio de liquidación incluso a 1x: esta operación no se puede abrir con el riesgo declarado.'
              using errcode = 'P0001';
    elsif v_dim.motivo = 'margen_insuficiente' then
        raise exception 'No queda margen libre: tienes % $ disponibles y el tope de margen comprometido de tu cuenta es el % %% del equity.',
              round(v_cuenta.saldo_disponible, 2), v_cuenta.margen_comprometido_max_pct
              using errcode = 'P0001';
    elsif v_dim.motivo is not null then
        raise exception 'El dimensionado no encuadra la operación (%).', v_dim.motivo
              using errcode = 'P0001';
    end if;

    -- ── G3 · Margen total comprometido <= tope de la cuenta ─────────
    -- El dimensionado ya lo aplica; esto es la comprobación independiente
    -- que lo verifica. Un guardarraíl que solo vive en el cálculo que
    -- debía limitar no es un guardarraíl.
    if v_dim.margen > v_cuenta.saldo_disponible then
        raise exception 'Margen de % $ por encima del saldo disponible (% $).',
              v_dim.margen, round(v_cuenta.saldo_disponible, 2) using errcode = 'P0001';
    end if;
    if v_cuenta.saldo_bloqueado + v_dim.margen
       > v_equity * v_cuenta.margen_comprometido_max_pct / 100 + 0.01 then
        raise exception 'Con esta orden el margen comprometido sería % $, por encima del % %% del equity que admite tu cuenta.',
              round(v_cuenta.saldo_bloqueado + v_dim.margen, 2),
              v_cuenta.margen_comprometido_max_pct using errcode = 'P0001';
    end if;
    -- G2, comprobado sobre el tamaño final y no sobre la intención.
    if v_dim.cantidad * (v_precio - v_senal.sl) > v_equity * 10 / 100 + 0.01 then
        raise exception 'El riesgo de esta orden (% $) supera el 10 %% del equity.',
              round(v_dim.cantidad * (v_precio - v_senal.sl), 2) using errcode = 'P0001';
    end if;

    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion, racional)
    values (p_cuenta_id, v_senal.activo_id, p_senal_id, p_origen, v_precio, v_fecha,
            v_dim.cantidad, v_dim.apalancamiento, v_dim.margen,
            v_senal.tp, v_senal.sl, round(v_dim.precio_liquidacion, 8), p_racional)
    returning id into v_orden;

    -- El margen sale del saldo disponible y queda bloqueado. Importe
    -- negativo: el cuadre del doc 01 §5.2 suma importes, así que un
    -- bloqueo tiene que restar.
    perform public.fn_registrar_movimiento(
        p_cuenta_id, v_orden, 'bloqueo_margen', -v_dim.margen, v_dim.margen);

    return jsonb_build_object(
        'orden_id', v_orden, 'simbolo', v_senal.simbolo,
        'cantidad', v_dim.cantidad, 'apalancamiento', v_dim.apalancamiento,
        'margen', v_dim.margen, 'precio_entrada', v_precio,
        'precio_liquidacion', round(v_dim.precio_liquidacion, 8),
        'tp', v_senal.tp, 'sl', v_senal.sl, 'ratio_rr', round(v_rr, 4),
        'apalancamiento_reducido', v_dim.apalancamiento < least(
            coalesce(p_apalancamiento, v_senal.leverage_recomendado, v_tope), v_tope));
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- H-25 · Monitor de órdenes. SQL puro sobre `pg_cron` (decisión D8).
--
-- El ciclo tiene tres fases y ese orden importa:
--   1. COSECHAR las respuestas HTTP que pidió la pasada anterior.
--   2. EVALUAR las órdenes con esos precios (reglas M1-M4).
--   3. PEDIR los precios que cosechará la pasada siguiente.
-- Si se pidiera antes de evaluar, cada pasada evaluaría con el precio de
-- la pasada anterior y el retraso sería el doble. `pg_net` es asíncrono:
-- no hay forma de pedir y leer en la misma transacción.
-- ═════════════════════════════════════════════════════════════════════

-- Fase 1. Lee `net._http_response` y escribe los precios. Todo por
-- `execute` dinámico y con guardas de `to_regprocedure`/`to_regclass`
-- porque `pg_net` solo existe en Supabase: la CI aplica este fichero
-- sobre un PostgreSQL limpio y tiene que pasar igual.
create function public.fn_monitor_cosechar_precios()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_pet      record;
    v_status   int;
    v_cuerpo   text;
    v_par      record;
    v_precios  int := 0;
    v_momento  timestamptz;
begin
    if to_regclass('net._http_response') is null then
        return 0;
    end if;

    for v_pet in select id, request_id from public.monitor_peticiones
                  where cosechado_en is null order by id
    loop
        v_status := null; v_cuerpo := null;
        execute 'select status_code, content from net._http_response where id = $1'
           into v_status, v_cuerpo using v_pet.request_id;

        -- Sin respuesta todavía: se deja para la pasada siguiente, salvo
        -- que haya pasado tanto tiempo que ya no vaya a llegar (pg_net
        -- limpia su tabla de respuestas sola).
        if v_status is null then
            update public.monitor_peticiones
               set cosechado_en = now(), resultado = 'sin_respuesta'
             where id = v_pet.id
               and pedido_en < now() - interval '5 minutes';
            continue;
        end if;

        if v_status <> 200 or v_cuerpo is null then
            update public.monitor_peticiones
               set cosechado_en = now(), resultado = 'http_' || v_status
             where id = v_pet.id;
            continue;
        end if;

        for v_par in select key, value from jsonb_each(v_cuerpo::jsonb)
        loop
            -- `last_updated_at` es la marca del PROVEEDOR, y es la que
            -- debe gobernar la regla M4: si CoinGecko sirve un precio de
            -- hace veinte minutos, el precio tiene veinte minutos, no
            -- cero, por mucho que la petición se acabe de hacer.
            v_momento := case
                when v_par.value ? 'last_updated_at'
                then least(now(), to_timestamp((v_par.value ->> 'last_updated_at')::bigint))
                else now() end;

            update public.activos
               set ultimo_precio = (v_par.value ->> 'usd')::numeric,
                   ultimo_precio_en = v_momento
             where clase = 'cripto'
               and id_proveedor = v_par.key
               and (v_par.value ->> 'usd') is not null
               -- Nunca retroceder: el ETL puede haber escrito un precio
               -- más nuevo entre la petición y la cosecha.
               and (ultimo_precio_en is null or ultimo_precio_en < v_momento);
            v_precios := v_precios + 1;
        end loop;

        update public.monitor_peticiones
           set cosechado_en = now(), resultado = 'ok' where id = v_pet.id;
    end loop;

    delete from public.monitor_peticiones where pedido_en < now() - interval '1 day';
    return v_precios;
end;
$$;

-- Fase 2. Las cuatro reglas del monitor, y solo ellas.
--
--   M1 — Liquidación PRIMERO. Con un único precio spot no se puede saber
--        si en el minuto transcurrido se tocó antes el TP o el SL, y a 5x
--        el margen se agota antes que el stop.
--   M2 — Empate al lado conservador: si el intervalo pudo tocar ambos,
--        gana el SL. Sin esta regla los resultados del experimento serían
--        optimistas de forma sistemática.
--   M3 — Cierre AL NIVEL, no al precio observado. El observado se guarda
--        aparte para poder medir el deslizamiento más adelante.
--   M4 — Precio fresco obligatorio: vive en `v_ordenes_abiertas_monitor`.
create function public.fn_monitorear_ordenes()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_orden    record;
    v_liq      int := 0;
    v_sl       int := 0;
    v_tp       int := 0;
    v_vistas   int := 0;
begin
    for v_orden in select * from public.v_ordenes_abiertas_monitor
    loop
        v_vistas := v_vistas + 1;

        if v_orden.precio_vivo <= v_orden.precio_liquidacion then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.precio_liquidacion, 'liquidacion', v_orden.precio_vivo);
            v_liq := v_liq + 1;

        elsif v_orden.precio_vivo <= v_orden.sl then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.sl, 'sl', v_orden.precio_vivo);
            v_sl := v_sl + 1;

        elsif v_orden.precio_vivo >= v_orden.tp then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.tp, 'tp', v_orden.precio_vivo);
            v_tp := v_tp + 1;
        end if;
    end loop;

    return jsonb_build_object('evaluadas', v_vistas, 'liquidacion', v_liq,
                              'sl', v_sl, 'tp', v_tp);
end;
$$;

-- Fase 3. Una sola petición con todos los ids (decisión D9), y solo si
-- hay posiciones abiertas en cripto. Sin posiciones abiertas, el monitor
-- no gasta ni una llamada de la cuota de CoinGecko.
create function public.fn_monitor_pedir_precios()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ids     text;
    v_url     text;
    v_request bigint;
begin
    if to_regprocedure('net.http_get(text,jsonb,jsonb,integer)') is null then
        return 'sin_infraestructura';
    end if;

    -- Una petición en vuelo basta: pedir otra mientras la anterior no ha
    -- llegado duplica el gasto de cuota sin adelantar nada.
    if exists (select 1 from public.monitor_peticiones
                where cosechado_en is null and pedido_en > now() - interval '90 seconds') then
        return 'en_vuelo';
    end if;

    select string_agg(distinct a.id_proveedor, ',' order by a.id_proveedor) into v_ids
      from public.ordenes o
      join public.activos a on a.id = o.activo_id
      join public.cuentas_simulacion c on c.id = o.cuenta_id
     where o.estado = 'abierta'
       and a.clase = 'cripto'
       and c.estado <> 'game_over';

    if v_ids is null then
        return 'sin_posiciones';
    end if;

    v_url := 'https://api.coingecko.com/api/v3/simple/price?ids=' || v_ids
             || '&vs_currencies=usd&include_last_updated_at=true';

    execute 'select net.http_get(url := $1, headers := $2, timeout_milliseconds := 5000)'
       into v_request
      using v_url,
            jsonb_build_object('Accept', 'application/json',
                               'User-Agent', 'dashboard-financiero');

    insert into public.monitor_peticiones (request_id, ids) values (v_request, v_ids);
    return 'pedido';
end;
$$;

-- El ciclo completo, que es lo que llama `pg_cron` cada minuto.
create function public.fn_ciclo_monitor()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_precios int;
    v_cierres jsonb;
    v_peticion text;
begin
    v_precios  := public.fn_monitor_cosechar_precios();
    v_cierres  := public.fn_monitorear_ordenes();
    v_peticion := public.fn_monitor_pedir_precios();

    return jsonb_build_object('precios_actualizados', v_precios,
                              'cierres', v_cierres, 'peticion', v_peticion);
end;
$$;

-- `pg_cron` cada minuto. Dentro de un bloque con guarda porque la
-- extensión no existe en el PostgreSQL de la CI, y en `execute` dinámico
-- para que ni se analice la sintaxis allí. Idempotente: si el job ya
-- existe, `cron.schedule` lo reprograma en vez de duplicarlo.
do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('monitor-ordenes', '* * * * *',
                                        'select public.fn_ciclo_monitor()')$q$;
        raise notice 'monitor-ordenes programado cada minuto';
    else
        raise notice 'pg_cron no disponible: el monitor no queda programado (esperado en la CI)';
    end if;
end
$cron$;

-- ═════════════════════════════════════════════════════════════════════
-- RLS. Matriz del doc 01 §6.2.
--
-- Toda política lleva `to authenticated` EXPLÍCITO: una política sin `to`
-- se aplica a `public`, que incluye a `anon`, y el Sprint 3 ya pagó esa
-- lección (invariante I14).
-- ═════════════════════════════════════════════════════════════════════
alter table public.cuentas_simulacion enable row level security;
alter table public.ordenes            enable row level security;
alter table public.movimientos_saldo  enable row level security;
alter table public.monitor_peticiones enable row level security;

create policy cuentas_propias on public.cuentas_simulacion
    for select to authenticated
    using (public.es_usuario_aprobado() and usuario_id = auth.uid());
-- Las cuentas de los agentes son públicas para los aprobados: es el
-- requisito 10 (ver cómo opera cada agente y por qué).
create policy cuentas_de_agentes on public.cuentas_simulacion
    for select to authenticated
    using (public.es_usuario_aprobado() and agente_id is not null);
create policy cuentas_select_admin on public.cuentas_simulacion
    for select to authenticated using (public.es_admin());

create policy ordenes_propias on public.ordenes
    for select to authenticated
    using (public.es_usuario_aprobado()
           and cuenta_id in (select id from public.cuentas_simulacion
                              where usuario_id = auth.uid()));
create policy ordenes_de_agentes on public.ordenes
    for select to authenticated
    using (public.es_usuario_aprobado()
           and cuenta_id in (select id from public.cuentas_simulacion
                              where agente_id is not null));
create policy ordenes_select_admin on public.ordenes
    for select to authenticated using (public.es_admin());

-- El libro mayor se LEE y nada más. No hay política de insert para
-- `authenticated`: escribe `fn_registrar_movimiento`, que es
-- SECURITY DEFINER, y solo se la llama desde los RPC.
create policy movimientos_propios on public.movimientos_saldo
    for select to authenticated
    using (public.es_usuario_aprobado()
           and cuenta_id in (select id from public.cuentas_simulacion
                              where usuario_id = auth.uid()));
create policy movimientos_select_admin on public.movimientos_saldo
    for select to authenticated using (public.es_admin());

-- `monitor_peticiones` es fontanería del servidor: ninguna política, y
-- además sin privilegios. Nadie desde el navegador tiene nada que hacer
-- aquí, ni de lectura.
revoke all on public.monitor_peticiones from authenticated;

-- Nadie escribe directo: ni órdenes, ni saldos, ni cuentas. Es lo que
-- convierte a los RPC en el único camino (doc 01 §5.1).
revoke insert, update, delete on public.cuentas_simulacion from authenticated;
revoke insert, update, delete on public.ordenes            from authenticated;
revoke insert, update, delete on public.movimientos_saldo  from authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- Privilegios de ejecución. `rpc_` lo ejecuta `authenticated`, `fn_` no
-- lo ejecuta nadie más que el propietario (invariantes I22 e I23).
--
-- Dos `rpc_` son la excepción y no se conceden a `authenticated`:
-- `rpc_cerrar_orden` acepta cualquier precio y motivo, y `rpc_evaluar_*`
-- se llaman desde el cierre. Que un cliente pudiera invocarlas sería
-- regalarle el P&L que quisiera.
-- ═════════════════════════════════════════════════════════════════════
revoke execute on function public.fn_tope_fase(text)                     from public, anon, authenticated;
revoke execute on function public.fn_piso_decimal(numeric)               from public, anon, authenticated;
revoke execute on function public.fn_mercado_abierto(timestamptz)        from public, anon, authenticated;
revoke execute on function public.fn_frescura_precio_min(text)           from public, anon, authenticated;
revoke execute on function public.fn_equity(bigint)                      from public, anon, authenticated;
revoke execute on function public.fn_libro_mayor_inmutable()             from public, anon, authenticated;
revoke execute on function public.fn_registrar_movimiento(bigint, bigint, text, numeric, numeric)
                                                                         from public, anon, authenticated;
revoke execute on function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
                                                                         from public, anon, authenticated;
revoke execute on function public.fn_monitor_cosechar_precios()          from public, anon, authenticated;
revoke execute on function public.fn_monitorear_ordenes()                from public, anon, authenticated;
revoke execute on function public.fn_monitor_pedir_precios()             from public, anon, authenticated;
revoke execute on function public.fn_ciclo_monitor()                     from public, anon, authenticated;

-- El ciclo del monitor, además de por `pg_cron`, se puede disparar desde
-- un workflow con la clave de servicio: es la salida de emergencia si
-- algún día `pg_cron` se para y hay posiciones abiertas.
grant execute on function public.fn_ciclo_monitor() to service_role;

revoke execute on function public.rpc_crear_cuenta_simulacion(numeric)   from public, anon;
revoke execute on function public.rpc_abrir_orden(bigint, bigint, numeric, timestamptz, numeric, numeric, text, jsonb)
                                                                         from public, anon;
revoke execute on function public.rpc_cerrar_manual(bigint)              from public, anon;
revoke execute on function public.rpc_revertir_fase_manual(bigint, boolean) from public, anon;
grant  execute on function public.rpc_crear_cuenta_simulacion(numeric)   to authenticated;
grant  execute on function public.rpc_abrir_orden(bigint, bigint, numeric, timestamptz, numeric, numeric, text, jsonb)
                                                                         to authenticated;
grant  execute on function public.rpc_cerrar_manual(bigint)              to authenticated;
grant  execute on function public.rpc_revertir_fase_manual(bigint, boolean) to authenticated;

-- Las tres que solo toca el servidor.
revoke execute on function public.rpc_cerrar_orden(bigint, numeric, text, numeric)
                                                                         from public, anon, authenticated;
revoke execute on function public.rpc_evaluar_fase(bigint)               from public, anon, authenticated;
revoke execute on function public.rpc_evaluar_game_over(bigint)          from public, anon, authenticated;
grant  execute on function public.rpc_cerrar_orden(bigint, numeric, text, numeric) to service_role;
grant  execute on function public.rpc_evaluar_fase(bigint)              to service_role;
grant  execute on function public.rpc_evaluar_game_over(bigint)         to service_role;
