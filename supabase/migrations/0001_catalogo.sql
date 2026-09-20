-- ─────────────────────────────────────────────────────────────────────
-- 0001 — Catálogo global de activos, precios, indicadores y señales.
--
-- NOTA DE PLANIFICACIÓN: este esquema estaba asignado a H-08 (Sprint 2),
-- pero se adelanta al Sprint 1 porque dos criterios de aceptación de
-- este sprint lo exigen y no se pueden cumplir sin él:
--   · H-01 pide una semilla con los 24 activos del universo de Fase 1
--     — una semilla necesita la tabla `activos`.
--   · H-05 pide que un workflow_dispatch manual escriba en `senales`.
-- H-08 se reduce a lo que queda: caché de indicadores, índices de
-- rendimiento y la política de retención aplicada. Sprint 1 pasa de 29 a
-- 34 puntos; Sprint 2, de 31 a 26.
--
-- LA IDEA CENTRAL: el catálogo es GLOBAL, no por usuario. `simbolo` es
-- UNIQUE. Si diez usuarios añaden bitcoin, el sistema paga UN backfill y
-- UNA actualización diaria. Esa es la respuesta al requisito 2 ("evitar
-- peticiones redundantes a APIs externas"): no es una caché de
-- respuestas HTTP, es que el dato vive una sola vez.
--
-- RLS: estas tablas se crean SIN políticas porque `perfiles` —y por
-- tanto `es_usuario_aprobado()`— no existe hasta el Sprint 3. Se activa
-- RLS igualmente y sin política: eso DENIEGA todo a `anon` y
-- `authenticated`, y deja pasar solo a `service_role` (el ETL). Es el
-- estado seguro por defecto: durante el Sprint 2 el frontend no lee
-- nada, que es exactamente lo que H-03 espera ("el panel de datos
-- muestra vacío con un mensaje claro").
-- ─────────────────────────────────────────────────────────────────────

-- ── Catálogo de activos ─────────────────────────────────────────────
create table public.activos (
    id                 bigserial primary key,
    -- Normalizado como ya lo usa backend/src/routes/escaner.js:
    -- acciones en MAYÚSCULAS ('IBM'), cripto en minúsculas ('bitcoin').
    simbolo            text not null unique,
    clase              text not null check (clase in ('accion', 'cripto')),
    proveedor          text not null check (proveedor in ('yahoo', 'coingecko')),
    -- El id que espera el conector. Sustituye al diccionario IDS_CRIPTO
    -- hardcodeado en motor-analitico/servicio_interno.py: añadir una
    -- cripto nueva deja de ser un cambio de código.
    id_proveedor       text not null,
    nombre             text,
    moneda             text not null default 'USD',
    estado             text not null default 'pendiente_backfill'
                       check (estado in ('pendiente_backfill', 'activo', 'suspendido', 'invalido')),
    -- Precio vivo. Lo refresca el ETL y lo lee el monitor de órdenes.
    ultimo_precio      numeric(20, 8),
    -- CRÍTICO para el monitor: un precio del viernes por la tarde
    -- congelado aquí cerraría posiciones todo el fin de semana contra un
    -- mercado que no existe. La regla M4 del doc 03 §5.4 descarta
    -- cualquier precio con más de 15 minutos.
    ultimo_precio_en   timestamptz,
    intentos           int not null default 0,
    -- Backoff exponencial: el ETL no reintenta antes de esta hora. Es lo
    -- que evita quemar la cuota de CoinGecko (~15 req/min, 2 llamadas
    -- por moneda) en un activo que falla.
    proximo_intento_en timestamptz,
    ultimo_error       text,
    creado_por         uuid references auth.users(id) on delete set null,
    primer_backfill_en timestamptz,
    ultimo_etl_en      timestamptz,
    creado_en          timestamptz not null default now()
);

comment on column public.activos.estado is
  'pendiente_backfill -> activo -> suspendido (reversible). invalido es TERMINAL: no se reintenta, para no gastar cuota en tickers fantasma.';

-- Índice parcial: la cola de backfill son pocas filas entre muchas.
create index activos_pendientes_idx
  on public.activos (proximo_intento_en nulls first)
  where estado = 'pendiente_backfill';

-- El ETL de cripto rota por antigüedad (H-10): este índice sostiene
-- "dame las 5 criptos que llevan más tiempo sin actualizarse".
create index activos_rotacion_etl_idx
  on public.activos (clase, ultimo_etl_en nulls first)
  where estado = 'activo';

-- ── Velas diarias ───────────────────────────────────────────────────
create table public.precios_diarios (
    activo_id   bigint not null references public.activos(id) on delete cascade,
    fecha       date not null,
    apertura    numeric(20, 8),
    maximo      numeric(20, 8),
    minimo      numeric(20, 8),
    cierre      numeric(20, 8) not null,
    volumen     numeric(24, 4),
    -- LA COLUMNA QUE NO SE PUEDE OLVIDAR.
    --
    -- false para las velas de cripto reconstruidas sin máximo y mínimo
    -- reales. CoinGecko no sirve velas diarias con rango real en su tier
    -- gratuito, así que el motor las arma con dos llamadas y solo los
    -- últimos 30 días tienen rango verdadero.
    --
    -- El CHANGELOG de la Fase 1 lo midió: calcular el ATR sobre el frame
    -- completo, incluyendo las velas sin rango real, INFLABA EL ATR DE
    -- BTC UN 16 % y le cambiaba el tramo de volatilidad — es decir,
    -- cambiaba el apalancamiento recomendado.
    --
    -- Si esta disciplina no viaja al esquema, el primer dev que escriba
    -- `select * from precios_diarios` para calcular un ATR reintroduce
    -- el bug en silencio. De ahí la vista v_velas_con_rango: TODO
    -- cálculo de ATR o de soporte/resistencia lee de ahí, no de aquí.
    rango_real  boolean not null default true,
    origen      text not null check (origen in ('yahoo', 'coingecko_market_chart', 'coingecko_ohlc')),
    ingerido_en timestamptz not null default now(),
    primary key (activo_id, fecha)
);

-- La única puerta legítima para calcular indicadores.
create view public.v_velas_con_rango as
    select * from public.precios_diarios where rango_real = true;

comment on view public.v_velas_con_rango is
  'ATR y soporte/resistencia se calculan SOLO sobre estas filas. Usar precios_diarios directamente para eso reintroduce el bug del ATR de BTC inflado un 16 %.';

-- ── Caché de indicadores ────────────────────────────────────────────
-- Existe para que la lógica de negocio funcione OFFLINE: los agentes y
-- el frontend no necesitan que el motor esté vivo ni que el proveedor
-- responda.
create table public.indicadores_diarios (
    activo_id     bigint not null references public.activos(id) on delete cascade,
    fecha         date not null,
    sma_50        numeric(20, 8),
    sma_200       numeric(20, 8),
    rsi_14        numeric(10, 4),
    macd          numeric(20, 8),
    macd_signal   numeric(20, 8),
    macd_hist     numeric(20, 8),
    atr_14        numeric(20, 8),
    version_motor text not null,
    calculado_en  timestamptz not null default now(),
    primary key (activo_id, fecha)
);

-- ── Señales ─────────────────────────────────────────────────────────
-- Esta tabla ES el payload de /internal/scan persistido: mismos campos,
-- mismos nombres, mismas invariantes. El motor deja de responder por
-- HTTP y pasa a hacer INSERT aquí. El contrato no cambia, solo su
-- transporte — y los devs ya lo conocen (test_contrato_scan.py).
create table public.senales (
    id                              bigserial primary key,
    activo_id                       bigint not null references public.activos(id) on delete cascade,
    calculado_en                    timestamptz not null default now(),
    precio_actual                   numeric(20, 8),
    direccion                       text check (direccion in ('alcista', 'bajista', 'neutral')),
    -- `direccion` describe el MERCADO; `sesgo_operativo` describe qué
    -- está el motor dispuesto a dimensionar. Hoy coinciden 1:1, pero son
    -- conceptos distintos y se desacoplarán si algún día se habilitan
    -- cortos. Se guardan los dos, igual que en el payload.
    sesgo_operativo                 text check (sesgo_operativo in ('largo', 'corto', 'sin_sesgo')),
    fuerza                          text check (fuerza in ('baja', 'media', 'alta')),
    indicadores_alcistas            int not null default 0,
    indicadores_bajistas            int not null default 0,
    resumen_confluencia             text,
    -- Las señales individuales, tal como las emite el payload. Exponerlas
    -- cuesta cero llamadas extra y permite explicar POR QUÉ una
    -- confluencia es lo que es.
    senales_detalle                 jsonb,
    operable                        boolean not null,
    atr_pct                         numeric(10, 4),
    leverage_tope                   numeric(4, 1) not null,
    leverage_recomendado            numeric(4, 1),
    leverage_referencia_volatilidad numeric(4, 1) not null,
    leverage_motivo                 text,
    -- Niveles técnicos: se emiten SIEMPRE y sin rol operativo.
    soporte                         numeric(20, 8),
    resistencia                     numeric(20, 8),
    -- sl/tp son el mismo número que soporte/resistencia, pero solo
    -- cuando el sistema encuadra la operación. No se invierten los roles
    -- en un sesgo corto (regla protegida nº2).
    sl                              numeric(20, 8),
    tp                              numeric(20, 8),
    niveles_origen                  text check (niveles_origen in ('estructura', 'atr')),
    -- Hash corto del commit del motor. Sin esto, una señal de hace tres
    -- semanas no es interpretable: no se sabe con qué umbrales se calculó.
    version_motor                   text not null,
    -- NUEVO en Fase 2: la Fase 1 emitía niveles sin comprobar que la
    -- operación mereciera la pena. Este ratio es el primer filtro de los
    -- agentes (doc 03 §5.1 paso 5).
    ratio_rr numeric(10, 4) generated always as (
        case
            when tp is not null and sl is not null
                 and precio_actual is not null
                 and precio_actual > sl
            then (tp - precio_actual) / (precio_actual - sl)
        end
    ) stored,
    -- Traducción LITERAL a la base de datos del contrato que verifica
    -- test_contrato_scan.py. En la Fase 1 esa coherencia la garantizaba
    -- un test de Python; ahora la garantiza PostgreSQL, así que ninguna
    -- vía de escritura puede violarla: ni un ETL con un bug, ni un
    -- INSERT a mano en la consola.
    constraint senales_contrato_operable check (
        (operable and leverage_recomendado is not null
                  and sl is not null and tp is not null)
        or
        (not operable and leverage_recomendado is null
                      and sl is null and tp is null)
    )
);

create index senales_activo_fecha_idx
  on public.senales (activo_id, calculado_en desc);

-- Última señal por activo. Sustituye a GET /api/scanner/signals.
create view public.senales_vigentes as
    select distinct on (s.activo_id)
           s.*,
           a.simbolo,
           a.clase,
           a.nombre,
           a.estado as estado_activo
      from public.senales s
      join public.activos a on a.id = s.activo_id
     order by s.activo_id, s.calculado_en desc;

-- ── Eventos del sistema ─────────────────────────────────────────────
-- Sucesora del EventLog en localStorage. Se crea ya en el Sprint 1
-- porque el ETL necesita dónde dejar constancia de un proveedor caído
-- desde su primera ejecución. La suscripción Realtime llega en H-32.
create table public.eventos_sistema (
    id         bigserial primary key,
    usuario_id uuid references auth.users(id) on delete cascade,
    tipo       text not null check (tipo in (
                   'sys', 'cambio_fase', 'deterioro', 'proveedor',
                   'orden_cerrada', 'game_over', 'corte_semanal',
                   'backlog_nuevo', 'activo_listo', 'etl')),
    mensaje    text not null,
    datos      jsonb,
    creado_en  timestamptz not null default now()
);

create index eventos_sistema_recientes_idx
  on public.eventos_sistema (creado_en desc);

-- ── Retención de señales (H-12, función lista desde ya) ─────────────
-- HALLAZGO DEL PRESUPUESTO DE CUOTAS (doc 02 §6.1): con 150 activos y
-- 48 pasadas diarias, `senales` alcanza ~2,6 M de filas y ~600 MB en un
-- año. El tier gratuito de Supabase da 500 MB. Sin esta función, el
-- sistema funciona seis meses y luego deja de escribir señales sin
-- explicación aparente.
--
-- Política por ventanas:
--   · últimos 30 días  -> todas las señales (auditar cualquier orden reciente)
--   · 30 días a 1 año  -> una por activo y día (la última del día)
--   · más de 1 año     -> se borra
--
-- EXCEPCIÓN INVIOLABLE: una señal referenciada por una orden es
-- evidencia del experimento y NUNCA se borra, por antigua que sea.
--
-- El filtro de evidencia se inyecta como FRAGMENTO de SQL, no como una
-- función auxiliar llamada fila a fila: `ordenes` no existe hasta el
-- Sprint 5, y resolverlo con to_regclass una sola vez al principio
-- convierte dos borrados masivos en dos sentencias con un anti-join, en
-- vez de en un EXECUTE por fila.
create or replace function public.fn_retencion_senales()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
    v_evidencia   text := '';
    v_comprimidas bigint;
    v_borradas    bigint;
begin
    if to_regclass('public.ordenes') is not null then
        v_evidencia := ' and not exists (select 1 from public.ordenes o where o.senal_id = s.id)';
    end if;

    -- Tramo 30 días – 1 año: conservar solo la última señal de cada día.
    execute format($sql$
        with clasificadas as (
            select s.id,
                   row_number() over (
                       partition by s.activo_id, s.calculado_en::date
                       order by s.calculado_en desc
                   ) as puesto
              from public.senales s
             where s.calculado_en <  now() - interval '30 days'
               and s.calculado_en >= now() - interval '1 year'
        )
        delete from public.senales s
         using clasificadas c
         where s.id = c.id
           and c.puesto > 1
           %s
    $sql$, v_evidencia);
    get diagnostics v_comprimidas = row_count;

    -- Tramo > 1 año: se borra, salvo evidencia.
    execute format($sql$
        delete from public.senales s
         where s.calculado_en < now() - interval '1 year'
           %s
    $sql$, v_evidencia);
    get diagnostics v_borradas = row_count;

    return jsonb_build_object(
        'comprimidas',  v_comprimidas,
        'borradas',     v_borradas,
        'evidencia_protegida', v_evidencia <> '',
        'ejecutado_en', now()
    );
end
$fn$;

comment on function public.fn_retencion_senales() is
  'Retención por ventanas de la tabla senales. La invoca el workflow keep-alive semanal. Nunca borra una señal referenciada por una orden.';

-- ── RLS: activada y sin políticas = denegado por defecto ────────────
-- No es un olvido. Sin política, `anon` y `authenticated` no leen NADA;
-- `service_role` (el ETL) elude RLS por diseño. Las políticas reales
-- llegan en H-14, cuando exista `es_usuario_aprobado()`.
alter table public.activos             enable row level security;
alter table public.precios_diarios     enable row level security;
alter table public.indicadores_diarios enable row level security;
alter table public.senales             enable row level security;
alter table public.eventos_sistema     enable row level security;
alter table public.cartera_posiciones  enable row level security;
alter table public.registro_consentimiento enable row level security;
