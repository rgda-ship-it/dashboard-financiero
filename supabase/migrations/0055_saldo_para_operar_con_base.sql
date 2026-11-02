-- ─────────────────────────────────────────────────────────────────────
-- 0055 — Saldo para operar con base fija y escalones (decisión del dueño,
-- 2026-11-02; D25).
--
-- QUÉ PIDIÓ EL DUEÑO
--
--   «Con 500 $ y el tope de 5×, mi saldo para operar son 2.500 $. Esos
--   2.500 $ se mantienen aunque el saldo baje, y suben cuando se tocan los
--   escalones.» Hasta hoy (D17, 0022) era equity × tope de la fase: Audacia,
--   con 415 $, tenía 2.078 $; Cadencia, con 464 $, 2.322 $.
--
-- LA REGLA (para los agentes y para las cuentas del simulador)
--
--   1. BASE = el saldo inicial o el último escalón alcanzado, lo que sea
--      mayor. Los escalones son los de la 0014 (equity de 1.000, 2.000,
--      5.000, 10.000, 15.000, 20.000, 25.000 y 50.000 $). La base NUNCA
--      baja: sale del máximo del libro mayor, que es inmutable (el pico de
--      capital se reancla al revertir a Fase 1, y con él bajaría).
--   2. SALDO PARA OPERAR = base × tope de la fase (5× en Fase 1, 3× en
--      Fase 2), con el poder de trading de la 0014 como techo.
--   3. EL TOPE SE MIDE SOBRE LA BASE (regla protegida nº1, reformulada por
--      el dueño). Cada tope de apalancamiento —el de la fase, el propio del
--      agente y el de la señal— se multiplica por la escala base / equity.
--      Con pérdidas, una orden admite algo más de apalancamiento sobre el
--      equity real (Audacia: 5 × 500 / 415 = 6,0×); con ganancias que aún
--      no tocan el escalón, algo menos. El nominal abierto no pasa de base
--      × tope. El techo absoluto es 20× (el poder de trading).
--
-- LO QUE NO CAMBIA
--
--   · El riesgo por operación (G2) sigue siendo un % del equity REAL: el
--     tamaño de cada posición no cambia, solo el margen que bloquea.
--   · La protección contra liquidar antes del stop (N4): con más
--     apalancamiento, el dimensionado lo baja si la liquidación quedaría
--     por encima del stop.
--   · La máquina de fases, el riesgo abierto (G6) y por mercado.
--   · Tendencia cripto opera a 1× con su propio dimensionado.
--
-- `fn_dimensionar_posicion` no cambia: quien la llama le pasa los topes ya
-- escalados. `v_cuentas_equity` mantiene sus columnas (leverage_tope pasa
-- a ser el de la cuenta) y añade al final `base_operar` y `tope_fase`.
-- Cambia una regla del grupo de control a mitad del experimento: el corte
-- está en `CRONOLOGIA.md`.
-- ─────────────────────────────────────────────────────────────────────

-- El escalón de un capital: el mayor de la tabla de la 0014 que alcanza,
-- y nunca menos que el saldo inicial.
create function public.fn_escalon_operar(p_saldo_inicial numeric, p_pico numeric)
returns numeric
language sql immutable
as $$
    select greatest(p_saldo_inicial,
                    case when p_pico >= 50000 then 50000
                         when p_pico >= 25000 then 25000
                         when p_pico >= 20000 then 20000
                         when p_pico >= 15000 then 15000
                         when p_pico >= 10000 then 10000
                         when p_pico >=  5000 then  5000
                         when p_pico >=  2000 then  2000
                         when p_pico >=  1000 then  1000
                         else 0 end)::numeric
$$;

comment on function public.fn_escalon_operar(numeric, numeric) is
  'Base del saldo para operar (0055): el saldo inicial o el mayor escalón de la 0014 que alcanza el pico.';

-- La base de una cuenta. Sin SECURITY DEFINER (I23): con el rol de quien
-- consulta, la RLS deja leer el libro mayor de las cuentas propias. Quien
-- mira una cuenta de agente sin poder leer su libro ve la base del pico de
-- capital, que solo difiere tras una reversión manual a Fase 1; los
-- agentes deciden y abren con el servidor, que lo lee todo.
create function public.fn_base_operar(p_cuenta_id bigint)
returns numeric
language sql stable
set search_path = public, pg_temp
as $$
    select public.fn_escalon_operar(
               c.saldo_inicial,
               greatest(c.capital_maximo_alcanzado,
                        coalesce((select max(m.saldo_disponible_resultante + m.saldo_bloqueado_resultante)
                                    from public.movimientos_saldo m
                                   where m.cuenta_id = c.id), 0)))
      from public.cuentas_simulacion c
     where c.id = p_cuenta_id
$$;

comment on function public.fn_base_operar(bigint) is
  'Base del saldo para operar de una cuenta (0055): nunca baja, sale del máximo del libro mayor.';

-- La escala con la que se miden los topes sobre la base: base / equity,
-- con el poder de trading como techo del nominal.
create function public.fn_escala_operar(p_base numeric, p_fase text, p_equity numeric)
returns numeric
language sql immutable
as $$
    select case when p_base is null or p_equity is null or p_equity <= 0 then 1::numeric
                else least(p_base * public.fn_tope_fase(p_fase), public.fn_poder_trading(p_equity))
                     / public.fn_tope_fase(p_fase) / p_equity end
$$;

-- El tope de apalancamiento de una cuenta (G1 desde la 0055): el de la
-- fase, medido sobre la base. A un decimal hacia abajo, como el resto.
create function public.fn_tope_cuenta(p_base numeric, p_fase text, p_equity numeric)
returns numeric
language sql immutable
as $$
    select greatest(1.0, public.fn_piso_decimal(
               public.fn_tope_fase(p_fase) * public.fn_escala_operar(p_base, p_fase, p_equity)))
$$;

-- Un tope de apalancamiento (el propio o el de la señal) escalado igual.
create function public.fn_escalar_apalancamiento(p_apalancamiento numeric, p_escala numeric)
returns numeric
language sql immutable
as $$
    select case when p_apalancamiento is null then null
                else greatest(1.0, public.fn_piso_decimal(p_apalancamiento * coalesce(p_escala, 1))) end
$$;

revoke execute on function public.fn_escalon_operar(numeric, numeric) from public, anon;
revoke execute on function public.fn_base_operar(bigint) from public, anon;
revoke execute on function public.fn_escala_operar(numeric, text, numeric) from public, anon;
revoke execute on function public.fn_tope_cuenta(numeric, text, numeric) from public, anon;
revoke execute on function public.fn_escalar_apalancamiento(numeric, numeric) from public, anon;
grant  execute on function public.fn_escalon_operar(numeric, numeric) to authenticated;
grant  execute on function public.fn_base_operar(bigint) to authenticated;
grant  execute on function public.fn_escala_operar(numeric, text, numeric) to authenticated;
grant  execute on function public.fn_tope_cuenta(numeric, text, numeric) to authenticated;
grant  execute on function public.fn_escalar_apalancamiento(numeric, numeric) to authenticated;
grant  execute on function public.fn_piso_decimal(numeric) to authenticated;

-- G1 en la tabla: el techo absoluto pasa de 5× a 20× (el poder de trading).
-- El de cada cuenta lo impone `rpc_abrir_orden`.
do $$
declare
    v_nombre text;
begin
    select conname into v_nombre
      from pg_constraint
     where conrelid = 'public.ordenes'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) like '%apalancamiento <=%5%';
    execute format('alter table public.ordenes drop constraint %I', v_nombre);
end
$$;
alter table public.ordenes
    add constraint ordenes_apalancamiento_check check (apalancamiento >= 1 and apalancamiento <= 20);

-- El rol de solo lectura (0045) ejecuta las funciones no volátiles: las
-- vistas que las usan se le romperían sin esto.
do $lectura$
begin
    if exists (select 1 from pg_roles where rolname = 'analista_lectura') then
        grant execute on function public.fn_escalon_operar(numeric, numeric) to analista_lectura;
        grant execute on function public.fn_base_operar(bigint) to analista_lectura;
        grant execute on function public.fn_escala_operar(numeric, text, numeric) to analista_lectura;
        grant execute on function public.fn_tope_cuenta(numeric, text, numeric) to analista_lectura;
        grant execute on function public.fn_escalar_apalancamiento(numeric, numeric) to analista_lectura;
    end if;
end
$lectura$;

create or replace view public.v_cuentas_equity
with (security_invoker = true) as
    select c.*,
           coalesce(p.pnl_no_realizado, 0) as pnl_no_realizado,
           c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0) as equity,
           coalesce(p.posiciones_abiertas, 0) as posiciones_abiertas,
           public.fn_tope_cuenta(public.fn_base_operar(c.id), c.fase, c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)) as leverage_tope,
           case when c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0) > 0
                then round(c.saldo_bloqueado * 100
                           / (c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)), 2)
           end as margen_comprometido_pct,
           case when c.capital_maximo_alcanzado > 0
                then round((c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)
                            - c.capital_maximo_alcanzado) * 100 / c.capital_maximo_alcanzado, 2)
           end as drawdown_pct,
           public.fn_poder_trading(
               c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)) as poder_trading,
           coalesce(p.nominal_abierto, 0) as nominal_abierto,
           -- 0055: base × tope de la fase (equity × tope × escala), con el
           -- poder de trading como techo.
           round(greatest(c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0), 0)
                 * public.fn_tope_fase(c.fase) * public.fn_escala_operar(public.fn_base_operar(c.id), c.fase, c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)), 2) as saldo_operar,
           round(c.saldo_bloqueado * public.fn_tope_fase(c.fase) * public.fn_escala_operar(public.fn_base_operar(c.id), c.fase, c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)), 2)
               as saldo_operar_en_uso,
           round(greatest(c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0), 0)
                 * public.fn_tope_fase(c.fase) * public.fn_escala_operar(public.fn_base_operar(c.id), c.fase, c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0))
                 * c.margen_comprometido_max_pct / 100, 2) as saldo_operar_max,
           -- 0055, al final: la base y el tope de la fase sin escalar.
           public.fn_base_operar(c.id) as base_operar,
           public.fn_tope_fase(c.fase) as tope_fase
      from public.cuentas_simulacion c
      left join lateral (
           select sum(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                               -o.margen_comprometido)) as pnl_no_realizado,
                  count(*) as posiciones_abiertas,
                  sum(o.nominal) as nominal_abierto
             from public.ordenes o
             join public.activos a on a.id = o.activo_id
            where o.cuenta_id = c.id and o.estado = 'abierta'
              and a.ultimo_precio is not null
      ) p on true;

create or replace view public.v_recomendaciones_usuario
with (security_invoker = true) as
    select e.activo_id, e.simbolo, e.clase, e.nombre, e.senal_id,
           e.precio_actual, e.tp, e.sl, e.ratio_rr, e.fuerza, e.direccion,
           e.atr_pct, e.leverage_recomendado, e.leverage_tope,
           e.leverage_referencia_volatilidad, e.leverage_motivo, e.niveles_origen,
           e.soporte, e.resistencia, e.indicadores_alcistas, e.indicadores_bajistas,
           e.resumen_confluencia, e.calculado_en, e.antiguedad_min,
           e.cuenta_id, e.riesgo_pct_operacion, e.equity,
           d.cantidad, d.apalancamiento, d.margen, d.precio_liquidacion, d.motivo,
           (d.motivo is null and e.ratio_rr >= e.ratio_rr_minimo) as confirmable,
           null::numeric as cupo_pct
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
                  ce.ratio_rr_minimo, ce.fase,
                  public.fn_escala_operar(public.fn_base_operar(ce.id), ce.fase, ce.equity) as escala,
                  ce.leverage_tope as tope_cuenta
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
           public.fn_escalar_apalancamiento(e.leverage_recomendado, e.escala), null, e.tope_cuenta, null,
           e.clase = 'accion') d;

create or replace function public.rpc_repartir_saldo(p_senal_ids bigint[])
returns table (
    senal_id            bigint,
    peso                numeric,
    parte_pct           numeric,
    parte               numeric,
    cantidad            numeric,
    apalancamiento      numeric,
    margen              numeric,
    consumo             numeric,
    precio_liquidacion  numeric,
    motivo              text,
    limitado_por_riesgo boolean)
language sql
stable
set search_path = public, pg_temp
as $$
    with c as (
        select ce.equity, ce.saldo_disponible, ce.saldo_bloqueado,
               ce.margen_comprometido_max_pct, ce.riesgo_pct_operacion,
               -- 0055: el tope de la cuenta, medido sobre su base.
               ce.leverage_tope as tope,
               public.fn_escala_operar(public.fn_base_operar(ce.id), ce.fase, ce.equity) as escala,
               -- Lo libre es lo que deja G3 y, como mucho, el saldo
               -- disponible: con P&L flotante a favor el equity supera
               -- disponible + bloqueado, y repartir ese exceso haría fallar
               -- la última apertura del lote por falta de saldo.
               greatest(least(ce.margen_comprometido_max_pct
                              - ce.saldo_bloqueado * 100 / ce.equity,
                              ce.saldo_disponible * 100 / ce.equity), 0) as libre_pct
          from public.v_cuentas_equity ce
         where ce.usuario_id = auth.uid() and ce.estado = 'activa' and ce.equity > 0
         order by ce.id desc
         limit 1
    ),
    r as (
        select r.senal_id, r.clase, r.precio_actual, r.sl, r.leverage_recomendado,
               r.apalancamiento as peso,
               sum(r.apalancamiento) over () as suma
          from public.v_recomendaciones_usuario r
         where r.senal_id = any(p_senal_ids) and r.confirmable
    ),
    x as (
        select r.*, c.*, c.libre_pct * r.peso / r.suma as cupo
          from r cross join c
    )
    select x.senal_id,
           x.peso,
           round(x.cupo, 4),
           round(x.equity * x.cupo / 100 * x.tope, 2),
           q.cantidad, d.apalancamiento, q.margen,
           round(q.margen * x.tope, 2),
           round(d.precio_liquidacion, 8),
           d.motivo,
           (x.equity * x.riesgo_pct_operacion / 100)
               / ((x.precio_actual - x.sl) / x.precio_actual) / x.peso
               < x.equity * x.cupo / 100
      from x
      cross join lateral public.fn_dimensionar_posicion(
           x.equity, x.saldo_disponible, x.saldo_bloqueado,
           x.precio_actual, x.sl, x.riesgo_pct_operacion, x.margen_comprometido_max_pct,
           public.fn_escalar_apalancamiento(x.leverage_recomendado, x.escala), null, x.tope, x.cupo,
           x.clase = 'accion') d
      -- Las criptos, truncadas a 8 decimales y no redondeadas: al abrir con
      -- esa cantidad, `rpc_abrir_orden` deduce el margen redondeando HACIA
      -- ARRIBA, y un redondeo al alza de la cantidad lo subiría un céntimo
      -- por encima de su parte (y de lo libre, en la última del lote).
      cross join lateral (
           select case when x.clase = 'accion' or d.cantidad is null then d.cantidad
                       else trunc(d.margen * d.apalancamiento / x.precio_actual, 8) end as cantidad
      ) q0
      cross join lateral (
           select q0.cantidad,
                  case when x.clase = 'accion' or q0.cantidad is null then d.margen
                       else ceil(q0.cantidad * x.precio_actual / d.apalancamiento * 100) / 100 end as margen
      ) q
     order by x.peso desc, x.senal_id
$$;

create or replace view public.v_operaciones_agentes
with (security_invoker = true) as
    select o.id, o.cuenta_id, g.id as agente_id, g.nombre as agente,
           o.activo_id, o.senal_id, o.estado, o.origen,
           o.precio_entrada, o.fecha_entrada, o.cantidad, o.apalancamiento,
           o.nominal, o.margen_comprometido, o.tp, o.sl, o.precio_liquidacion,
           o.precio_salida, o.fecha_salida, o.motivo_cierre, o.precio_observado_cierre,
           o.pnl_bruto, o.pnl_pct, o.racional, o.creado_en, o.precio_max_visto,
           a.simbolo, a.clase, a.nombre, a.ultimo_precio, a.ultimo_precio_en,
           case when o.estado = 'abierta' and a.ultimo_precio is not null
                then round(greatest(o.cantidad * (a.ultimo_precio - o.precio_entrada),
                                    -o.margen_comprometido), 2)
           end as pnl_flotante,
           o.pnl_parciales, o.parcial_hecho, o.sl_original,
           round(o.margen_comprometido * public.fn_tope_fase(c.fase)
                 * public.fn_escala_operar(public.fn_base_operar(c.id), c.fase, ce.equity), 2) as consumo_saldo,
           ce.saldo_operar
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id and c.agente_id is not null
      join public.agentes g on g.id = c.agente_id
      join public.activos a on a.id = o.activo_id
      left join public.v_cuentas_equity ce on ce.id = c.id;

create or replace function public.rpc_abrir_orden(
    p_cuenta_id      bigint,
    p_senal_id       bigint,
    p_precio_entrada numeric default null,
    p_fecha_entrada  timestamptz default null,
    p_apalancamiento numeric default null,
    p_riesgo_pct     numeric default null,
    p_origen         text default 'recomendacion',
    p_racional       jsonb default null,
    p_cantidad       numeric default null)
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
    v_escala     numeric;
    v_precio     numeric;
    v_fecha      timestamptz;
    v_riesgo_pct numeric;
    v_rr         numeric;
    v_abiertas   int;
    v_dim        record;
    v_cantidad   numeric;
    v_margen     numeric;
    v_orden      bigint;
begin
    select * into v_cuenta from public.cuentas_simulacion where id = p_cuenta_id for update;
    if not found then
        raise exception 'La cuenta % no existe', p_cuenta_id using errcode = '42501';
    end if;

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

    -- ── G5 ──────────────────────────────────────────────────────────
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

    if v_cuenta.usuario_id is not null
       and not exists (select 1 from public.cartera_activos ca
                         join public.carteras c on c.id = ca.cartera_id
                        where c.usuario_id = v_cuenta.usuario_id
                          and ca.activo_id = v_senal.activo_id) then
        raise exception 'No sigues %: añádelo a tu cartera antes de operarlo.', v_senal.simbolo
              using errcode = 'P0001';
    end if;

    -- ── G4 · retirado también para los agentes (0023, D17) ──────────
    -- Cuántas posiciones abre un agente lo decide su reparto por exigencia
    -- (`fn_decidir_agente`); lo que acota la exposición, para él igual que
    -- para el usuario, es el riesgo por operación (G2) y el saldo para
    -- operar (G3). La cuarentena («una posición») la impone la decisión.
    if exists (select 1 from public.ordenes
                where cuenta_id = p_cuenta_id and activo_id = v_senal.activo_id
                  and estado = 'abierta') then
        raise exception 'Ya tienes una posición abierta en %.', v_senal.simbolo
              using errcode = 'P0001';
    end if;

    -- 0034: sin precio a mano se compra al precio de COMPRA (el intermedio
    -- más medio spread), no al intermedio.
    v_precio := coalesce(p_precio_entrada, public.fn_precio_compra(v_senal.activo_id, v_senal.precio_actual));
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

    -- ── G1 ──────────────────────────────────────────────────────────
    -- 0055: el tope de la fase se mide sobre la BASE del saldo para operar
    -- (saldo inicial o el último escalón alcanzado), no sobre el equity.
    -- Con pérdidas, cada orden admite algo más de apalancamiento; con
    -- ganancias que no llegan al escalón, algo menos.
    v_escala := public.fn_escala_operar(public.fn_base_operar(v_cuenta.id), v_cuenta.fase, public.fn_equity(p_cuenta_id));
    v_tope   := public.fn_tope_cuenta(public.fn_base_operar(v_cuenta.id), v_cuenta.fase, public.fn_equity(p_cuenta_id));
    if p_apalancamiento is not null and p_apalancamiento > v_tope then
        raise exception 'Apalancamiento %x rechazado: el tope de tu cuenta es %x (%x de la % sobre una base de % $).',
              p_apalancamiento, v_tope, public.fn_tope_fase(v_cuenta.fase), replace(v_cuenta.fase, '_', ' '),
              public.fn_base_operar(v_cuenta.id)
              using errcode = 'P0001';
    end if;
    if p_apalancamiento is not null and p_apalancamiento < 1 then
        raise exception 'El apalancamiento mínimo es 1x.' using errcode = '22023';
    end if;

    -- ── G2 ──────────────────────────────────────────────────────────
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
        coalesce(p_apalancamiento, public.fn_escalar_apalancamiento(v_senal.leverage_recomendado, v_escala)),
        p_apalancamiento, v_tope,
        null, v_senal.clase = 'accion');

    -- El apalancamiento lo decide siempre el dimensionado (G1 y N4), también
    -- con cantidad a mano: esos dos motivos no tienen arreglo cambiando el
    -- tamaño. Los de margen sí, así que con cantidad a mano no se lanzan
    -- aquí: los juzgan las comprobaciones independientes de abajo.
    if v_dim.motivo = 'sin_operacion_liquidacion_antes_del_stop' then
        raise exception 'El stop queda por debajo del precio de liquidación incluso a 1x: esta operación no se puede abrir con el riesgo declarado.'
              using errcode = 'P0001';
    elsif v_dim.motivo in ('stop_por_encima_del_precio', 'apalancamiento_bajo_uno') then
        raise exception 'El dimensionado no encuadra la operación (%).', v_dim.motivo
              using errcode = 'P0001';
    elsif p_cantidad is null and v_dim.motivo = 'margen_insuficiente' then
        raise exception 'No queda margen libre: tienes % $ disponibles y el tope de margen comprometido de tu cuenta es el % %% del equity.',
              round(v_cuenta.saldo_disponible, 2), v_cuenta.margen_comprometido_max_pct
              using errcode = 'P0001';
    elsif p_cantidad is null and v_dim.motivo is not null then
        raise exception 'El dimensionado no encuadra la operación (%).', v_dim.motivo
              using errcode = 'P0001';
    end if;

    -- ── 0016 · Cantidad a mano ──────────────────────────────────────
    -- El usuario (o el agente, que siempre manda la suya) decide cuánto;
    -- el margen se deduce con el apalancamiento que fijó el dimensionado, y
    -- se redondea HACIA ARRIBA: con el céntimo de menos, el margen no
    -- cubriría el nominal.
    if p_cantidad is not null then
        if p_cantidad <= 0 then
            raise exception 'La cantidad debe ser mayor que cero.' using errcode = '22023';
        end if;
        -- Las acciones no admiten fracciones (las criptos sí).
        if v_senal.clase = 'accion' and p_cantidad <> trunc(p_cantidad) then
            raise exception 'Las acciones se compran por unidades enteras: % no es un número entero.',
                  p_cantidad using errcode = '22023';
        end if;
        v_cantidad := round(p_cantidad, 8);
        v_margen   := ceil(v_cantidad * v_precio / v_dim.apalancamiento * 100) / 100;
    else
        v_cantidad := v_dim.cantidad;
        v_margen   := v_dim.margen;
    end if;

    -- ── G3 · comprobación independiente ─────────────────────────────
    if v_margen > v_cuenta.saldo_disponible then
        raise exception 'Margen de % $ por encima del saldo disponible (% $).',
              v_margen, round(v_cuenta.saldo_disponible, 2) using errcode = 'P0001';
    end if;
    if v_cuenta.saldo_bloqueado + v_margen
       > v_equity * v_cuenta.margen_comprometido_max_pct / 100 + 0.01 then
        raise exception 'Con esta orden el margen comprometido sería % $, por encima del % %% del equity que admite tu cuenta.',
              round(v_cuenta.saldo_bloqueado + v_margen, 2),
              v_cuenta.margen_comprometido_max_pct using errcode = 'P0001';
    end if;
    -- G2, sobre el tamaño final y no sobre la intención.
    if v_cantidad * (v_precio - v_senal.sl) > v_equity * 10 / 100 + 0.01 then
        raise exception 'El riesgo de esta orden (% $) supera el 10 %% del equity: reduce la cantidad.',
              round(v_cantidad * (v_precio - v_senal.sl), 2) using errcode = 'P0001';
    end if;

    insert into public.ordenes
        (cuenta_id, activo_id, senal_id, origen, precio_entrada, fecha_entrada,
         cantidad, apalancamiento, margen_comprometido, tp, sl, precio_liquidacion, racional)
    values (p_cuenta_id, v_senal.activo_id, p_senal_id, p_origen, v_precio, v_fecha,
            v_cantidad, v_dim.apalancamiento, v_margen,
            v_senal.tp, v_senal.sl, round(v_dim.precio_liquidacion, 8), p_racional)
    returning id into v_orden;

    perform public.fn_registrar_movimiento(
        p_cuenta_id, v_orden, 'bloqueo_margen', -v_margen, v_margen);

    return jsonb_build_object(
        'orden_id', v_orden, 'simbolo', v_senal.simbolo,
        'cantidad', v_cantidad, 'apalancamiento', v_dim.apalancamiento,
        'margen', v_margen, 'precio_entrada', v_precio,
        'precio_liquidacion', round(v_dim.precio_liquidacion, 8),
        'tp', v_senal.tp, 'sl', v_senal.sl, 'ratio_rr', round(v_rr, 4),
        'cantidad_a_mano', p_cantidad is not null,
        'apalancamiento_reducido', v_dim.apalancamiento < least(
            coalesce(p_apalancamiento, public.fn_escalar_apalancamiento(v_senal.leverage_recomendado, v_escala),
                     v_tope), v_tope));
end;
$$;

create or replace function public.fn_decidir_agente(p_agente_id bigint)
returns jsonb
language plpgsql stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag         public.agentes;
    v_p          jsonb;
    v_cuenta     public.cuentas_simulacion;
    v_hoy        date := (now() at time zone 'UTC')::date;
    v_equity     numeric;
    v_objetivo   numeric;
    v_logrado    numeric;
    v_deficit    numeric;
    v_abiertas   int;
    v_margen_pct numeric;
    v_tope       numeric;
    v_propio     numeric;
    v_riesgo     numeric;
    v_libre      numeric;
    v_libre_pct  numeric;
    v_cuarentena boolean;
    v_validas    int;
    v_k          int;
    v_set        jsonb;
    v_gan        numeric;
    v_ok         boolean;
    v_cubre_k    int;
    v_mejor_k    int;
    v_mejor_g    numeric;
    v_evals      jsonb := '[]'::jsonb;
    v_marcadas   jsonb;
    v_practicas  jsonb;
    v_ids_pract  jsonb;
    v_base       jsonb;
    v_universo   int;
    v_frescas    int;
    v_sin_alc    boolean;
    v_antes      int;
    v_cands      jsonb;
    v_descartes  jsonb;
    v_top3       jsonb;
    v_sin_hueco  text;
    v_mejor      jsonb;
    v_debil      record;
    v_abierto    numeric;
    v_heat_max   numeric;
    v_heat_libre_pct numeric;
    v_heat_clase jsonb := '{}'::jsonb;
    v_clase      text;
    v_mult       numeric;
    v_extra      jsonb;
    v_escala     numeric;
begin
    select * into v_ag from public.agentes where id = p_agente_id;
    select * into v_cuenta from public.cuentas_simulacion where id = public.fn_cuenta_agente(p_agente_id);
    v_p := public.fn_parametros_agente(v_ag);

    v_equity := public.fn_equity(v_cuenta.id);
    select objetivo_importe into v_objetivo from public.agente_dias
     where agente_id = p_agente_id and fecha = v_hoy;
    v_objetivo := coalesce(v_objetivo, round(v_equity * v_ag.objetivo_diario_pct / 100, 2));
    v_logrado  := public.fn_pnl_realizado_dia(v_cuenta.id, v_hoy);
    v_deficit  := v_objetivo - v_logrado;

    v_base := jsonb_build_object(
        'agente', v_ag.nombre, 'cuenta_id', v_cuenta.id,
        'version_estrategia', v_ag.version_estrategia,
        'equity', round(v_equity, 2), 'objetivo_importe', v_objetivo,
        'logrado', v_logrado, 'deficit_pendiente', round(v_deficit, 2));

    -- N9: meta cumplida ⇒ modo conservación. Tampoco se rota: rotar es
    -- abrir algo nuevo.
    if v_deficit <= 0 then
        return v_base || jsonb_build_object('accion', 'meta_cumplida');
    end if;

    select count(*) into v_abiertas
      from public.ordenes where cuenta_id = v_cuenta.id and estado = 'abierta';
    -- 0023: sin G4. Lo libre es el margen que deja G3 (el 100 % del
    -- equity) y, como mucho, el disponible. Con menos de 10 $ de margen
    -- libre no cabe ninguna posición: el saldo para operar está lleno.
    -- La cuarentena sigue siendo «una posición a la vez».
    v_cuarentena := v_ag.estado = 'cuarentena';
    v_libre := greatest(least(v_equity * (v_p ->> 'margen_comprometido_max_pct')::numeric / 100
                              - v_cuenta.saldo_bloqueado,
                              v_cuenta.saldo_disponible), 0);
    v_libre_pct := case when v_equity > 0 then v_libre * 100 / v_equity else 0 end;
    -- 0030 · Riesgo abierto total: lo que arriesgan a la vez sus
    -- posiciones abiertas no pasa de 4 × su riesgo por operación. Con
    -- menos de un cuarto de riesgo libre no cabe ninguna posición útil.
    v_abierto  := public.fn_riesgo_abierto(v_cuenta.id);
    v_heat_max := v_equity * (v_p ->> 'riesgo_pct_operacion')::numeric
                  * public.fn_multiplo_riesgo_abierto() / 100;
    v_heat_libre_pct := case when v_equity > 0
                             then greatest(v_heat_max - v_abierto, 0) * 100 / v_equity else 0 end;
    if v_cuarentena and v_abiertas >= 1 then
        v_sin_hueco := 'sin_hueco';
    elsif v_libre < 10 then
        v_sin_hueco := 'saldo_lleno';
    elsif v_heat_libre_pct < (v_p ->> 'riesgo_pct_operacion')::numeric * 0.25 then
        v_sin_hueco := 'riesgo_lleno';
    end if;

    -- 0032 · Riesgo abierto por mercado: lo que arriesgan a la vez sus
    -- posiciones de una clase (p. ej. cripto, que se mueve en bloque con
    -- BTC) no pasa de `riesgo_abierto_mult` × su riesgo por operación.
    for v_clase in select jsonb_array_elements_text(v_p -> 'clases_admitidas') loop
        v_mult := (public.fn_param_clase(v_p, v_clase, 'riesgo_abierto_mult') #>> '{}')::numeric;
        if v_mult is not null and v_equity > 0 then
            v_heat_clase := v_heat_clase || jsonb_build_object(v_clase,
                greatest(v_equity * (v_p ->> 'riesgo_pct_operacion')::numeric * v_mult / 100
                         - public.fn_riesgo_abierto_clase(v_cuenta.id, v_clase), 0) * 100 / v_equity);
        end if;
    end loop;

    select coalesce(jsonb_agg(jsonb_build_object('c', p.condiciones, 's', p.sentido) order by p.id), '[]'::jsonb),
           coalesce(jsonb_agg(p.id order by p.id), '[]'::jsonb)
      into v_practicas, v_ids_pract
      from public.mp_adopciones ad
      join public.mejores_practicas p on p.id = ad.practica_id
     where ad.agente_id = p_agente_id and ad.abandonada_en is null
       and p.estado in ('propuesta', 'validada');

    -- 0055: los topes de apalancamiento (el de la fase, el propio y el de
    -- cada señal) se miden sobre la base del saldo para operar.
    v_escala := public.fn_escala_operar(public.fn_base_operar(v_cuenta.id), v_cuenta.fase, v_equity);
    v_tope   := public.fn_tope_cuenta(public.fn_base_operar(v_cuenta.id), v_cuenta.fase, v_equity);
    v_propio := public.fn_escalar_apalancamiento((v_p ->> 'apalancamiento_maximo_propio')::numeric, v_escala);
    v_riesgo := (v_p ->> 'riesgo_pct_operacion')::numeric;

    with u as (
        -- 0034: el agente dimensiona al precio al que de verdad compraría.
        select x.*, public.fn_precio_compra(x.activo_id, x.precio_actual) as precio_compra
          from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas) x
    ),
    dim as (
        select u.*, d.cantidad, d.apalancamiento, d.margen, d.precio_liquidacion,
               d.motivo as motivo_dim, f.factor,
               least(coalesce(public.fn_escalar_apalancamiento(u.leverage_recomendado, v_escala), v_tope),
                     v_propio, v_tope) as lev_pedido
          from u
          -- 0032: prudencia como tamaño. El riesgo se escala por la
          -- volatilidad respecto a la referencia del perfil en ese mercado.
          cross join lateral (select public.fn_factor_riesgo(v_p, u.clase, u.atr_pct) as factor) f
          cross join lateral public.fn_dimensionar_posicion(
               v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
               u.precio_compra, u.sl, v_riesgo * f.factor,
               (v_p ->> 'margen_comprometido_max_pct')::numeric,
               least(coalesce(public.fn_escalar_apalancamiento(u.leverage_recomendado, v_escala), v_tope),
                     v_propio, v_tope),
               v_propio, v_tope, null, u.clase = 'accion') d
         where u.motivo is null
    ),
    ordenados as (
        select dim.*,
               row_number() over (order by ratio_rr desc,
                                           public.fn_rango_fuerza(fuerza) desc,
                                           (alcistas - bajistas) desc,
                                           simbolo asc) as puesto
          from dim
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'senal_id', senal_id, 'activo_id', activo_id, 'simbolo', simbolo,
               'clase', clase, 'fuerza', fuerza, 'niveles_origen', niveles_origen,
               'ratio_rr', round(ratio_rr, 4), 'atr_pct', atr_pct,
               'dominancia_neta', alcistas - bajistas, 'puesto', puesto,
               'apalancamiento_pedido', lev_pedido,
               'apalancamiento', apalancamiento, 'margen', margen,
               'cantidad', cantidad, 'precio_liquidacion', round(precio_liquidacion, 8),
               'precio', precio_compra, 'precio_medio', precio_actual, 'sl', sl, 'tp', tp,
               -- 0023: lo que rinde cada dólar de saldo para operar si
               -- toca el objetivo. Ordena qué se marca primero.
               'rendimiento', round(coalesce(apalancamiento, 0) * (tp - precio_compra) / precio_compra, 6),
               'factor_riesgo', factor,
               'descarte', case when (v_heat_clase ->> clase)::numeric
                                     < (v_p ->> 'riesgo_pct_operacion')::numeric * 0.25 then 'riesgo_clase_lleno'
                                -- 0034: con el spread pagado, el R:R real puede
                                -- quedar por debajo del mínimo del perfil.
                                when tp <= precio_compra or sl >= precio_compra
                                     or (tp - precio_compra) / (precio_compra - sl)
                                        < (v_p ->> 'rr_minimo')::numeric then 'rr_con_spread'
                                when motivo_dim is not null then 'dimensionado:' || motivo_dim
                                when margen < 10 and factor < 1 then 'riesgo_escalado'
                                when margen < 10 then 'margen_minimo' end)
               order by puesto), '[]'::jsonb)
      into v_cands
      from ordenados;

    select count(*),
           count(*) filter (where motivo is distinct from 'fuera_de_sesion'
                              and motivo is distinct from 'antiguedad'),
           count(*) filter (where motivo is null or motivo = 'practica')
      into v_universo, v_frescas, v_antes
      from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas);

    select v_frescas > 0 and bool_and(motivo = 'direccion')
      into v_sin_alc
      from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
     where motivo is distinct from 'fuera_de_sesion' and motivo is distinct from 'antiguedad';

    select coalesce(jsonb_object_agg(m, n), '{}'::jsonb) into v_descartes
      from (select coalesce(motivo, 'candidata') as m, count(*) as n
              from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
             group by 1) t;
    -- 0032: los límites prudentes también cuentan como descarte, para que
    -- el agente pueda pedir que se amplíen con evidencia.
    select coalesce(jsonb_object_agg(d, n), '{}'::jsonb) into v_extra
      from (select c ->> 'descarte' as d, count(*) as n
              from jsonb_array_elements(v_cands) c
             where c ->> 'descarte' in ('riesgo_escalado', 'riesgo_clase_lleno')
             group by 1) t;
    v_descartes := v_descartes || v_extra;

    select coalesce(jsonb_agg(jsonb_build_object(
               'simbolo', simbolo, 'motivo', motivo, 'ratio_rr', round(ratio_rr, 4),
               'fuerza', fuerza) order by ratio_rr desc nulls last, simbolo), '[]'::jsonb)
      into v_top3
      from (select * from public.fn_universo_agente(v_p, v_cuenta.id, v_practicas)
             where motivo is not null
               and motivo not in ('fuera_de_sesion', 'antiguedad')
             order by ratio_rr desc nulls last, simbolo
             limit 3) t;

    v_base := v_base || jsonb_build_object(
        'candidatos_evaluados', jsonb_array_length(v_cands),
        'candidatos_antes_practicas', v_antes,
        'candidatos', v_cands,
        'descartados_top3', v_top3,
        'descartes_por_motivo', v_descartes,
        'practicas_aplicadas', v_ids_pract,
        'universo', v_universo,
        'frescas', v_frescas,
        'sin_alcistas', coalesce(v_sin_alc, false),
        'saldo_libre', round(v_libre * v_tope, 2),
        'riesgo_abierto', round(v_abierto, 2),
        'riesgo_abierto_max', round(v_heat_max, 2),
        'parametros', v_p);

    -- ── Sin hueco: ¿merece la pena rotar? ───────────────────────────
    if v_sin_hueco is not null then
        if v_p ->> 'rotacion_umbral' is null then
            return v_base || jsonb_build_object('accion', v_sin_hueco, 'abiertas', v_abiertas);
        end if;

        -- La mejor señal que entraría si hubiera sitio: se ignoran los
        -- descartes por margen (al rotar se libera) pero no los de riesgo.
        select c into v_mejor
          from jsonb_array_elements(v_cands) c
         where c ->> 'descarte' is null
            or c ->> 'descarte' in ('dimensionado:margen_insuficiente', 'margen_minimo')
         order by (c ->> 'puesto')::int
         limit 1;

        -- La posición más débil: la de menor R:R restante al precio de
        -- ahora, con precio FRESCO (M4) y abierta hace más de 30 minutos,
        -- para que una orden recién abierta no se cierre por ruido.
        select m.id, m.simbolo, m.precio_vivo, m.tp, m.sl, m.cantidad,
               (m.tp - m.precio_vivo) / (m.precio_vivo - m.sl) as rr_restante
          into v_debil
          from public.v_ordenes_abiertas_monitor m
          join public.ordenes o on o.id = m.id
         where m.cuenta_id = v_cuenta.id
           and m.precio_vivo > m.sl and m.precio_vivo < m.tp
           and o.fecha_entrada < now() - interval '30 minutes'
         order by (m.tp - m.precio_vivo) / (m.precio_vivo - m.sl), m.id
         limit 1;

        if v_mejor is not null and v_debil.id is not null
           and (v_mejor ->> 'ratio_rr')::numeric
               >= (v_p ->> 'rotacion_umbral')::numeric * v_debil.rr_restante then
            return v_base || jsonb_build_object(
                'accion', 'rotar',
                'rotacion', jsonb_build_object(
                    'cerrar_orden_id', v_debil.id, 'cerrar_simbolo', v_debil.simbolo,
                    'precio', v_debil.precio_vivo, 'tp', v_debil.tp, 'sl', v_debil.sl,
                    'cantidad', v_debil.cantidad,
                    'rr_restante', round(v_debil.rr_restante, 4),
                    'umbral', (v_p ->> 'rotacion_umbral')::numeric,
                    'candidato', v_mejor));
        end if;
        return v_base || jsonb_build_object(
            'accion', v_sin_hueco, 'abiertas', v_abiertas,
            'rotacion_evaluada', jsonb_build_object(
                'mejor_rr', v_mejor -> 'ratio_rr',
                'debil_rr_restante', round(v_debil.rr_restante, 4),
                'umbral', v_p -> 'rotacion_umbral'));
    end if;

    -- ── 0023 · Qué marca: el reparto por exigencia ──────────────────
    -- Las válidas se ordenan por rendimiento sobre el saldo (las 5× con
    -- recorrido, primero) y se prueba a marcar 1, 2, 3… Para cada k, el
    -- saldo libre se reparte entre las k en proporción a su apalancamiento
    -- y cada una se dimensiona con esa parte como techo (el riesgo por
    -- operación sigue mandando). Se elige:
    --   · el MAYOR k cuya ganancia en objetivo cubre lo que falta de la
    --     meta: si falta poco, reparte y arriesga menos en cada una;
    --   · si ningún k la cubre, el de MÁS ganancia potencial: con mucha
    --     exigencia, concentra en lo que más rinde.
    -- Un k solo vale si todas sus marcadas caben (≥ 10 $ de margen y sin
    -- motivo del dimensionado). En cuarentena, como mucho una.
    select count(*) into v_validas
      from jsonb_array_elements(v_cands) c where c ->> 'descarte' is null;
    if v_validas = 0 then
        return v_base || jsonb_build_object('accion', 'sin_candidatos');
    end if;

    for v_k in 1 .. case when v_cuarentena then 1 else v_validas end loop
        with m as (
            select c, row_number() over (order by (c ->> 'rendimiento')::numeric desc,
                                                  (c ->> 'puesto')::int) as orden
              from jsonb_array_elements(v_cands) c
             where c ->> 'descarte' is null
        ),
        mk as (
            select c, orden, sum((c ->> 'apalancamiento')::numeric) over () as suma,
                   count(*) over (partition by c ->> 'clase') as kc
              from m where orden <= v_k
        ),
        d as (
            select mk.c, mk.orden, x.apalancamiento, x.motivo,
                   (mk.c ->> 'precio')::numeric as precio,
                   v_libre_pct * (mk.c ->> 'apalancamiento')::numeric / mk.suma as cupo,
                   -- Criptos truncadas (no redondeadas): ver rpc_repartir_saldo.
                   case when mk.c ->> 'clase' = 'accion' or x.cantidad is null then x.cantidad
                        else trunc(x.margen * x.apalancamiento / (mk.c ->> 'precio')::numeric, 8) end as cantidad,
                   x.margen as margen_dim
              from mk
              cross join lateral public.fn_dimensionar_posicion(
                   v_equity, v_cuenta.saldo_disponible, v_cuenta.saldo_bloqueado,
                   (mk.c ->> 'precio')::numeric, (mk.c ->> 'sl')::numeric,
                   -- 0030: entre las k marcadas no arriesgan más que el
                   -- riesgo abierto que queda libre.
                   -- 0032: escalado por volatilidad y, si su mercado tiene
                   -- tope propio, sin pasar del riesgo libre de ese mercado
                   -- repartido entre sus marcadas (least ignora el nulo).
                   least(v_riesgo * (mk.c ->> 'factor_riesgo')::numeric, v_heat_libre_pct / v_k,
                         (v_heat_clase ->> (mk.c ->> 'clase'))::numeric / mk.kc),
                   (v_p ->> 'margen_comprometido_max_pct')::numeric,
                   (mk.c ->> 'apalancamiento_pedido')::numeric, v_propio, v_tope,
                   v_libre_pct * (mk.c ->> 'apalancamiento')::numeric / mk.suma,
                   mk.c ->> 'clase' = 'accion') x
        ),
        f as (
            select d.*, case when d.c ->> 'clase' = 'accion' or d.cantidad is null then d.margen_dim
                             else ceil(d.cantidad * d.precio / d.apalancamiento * 100) / 100 end as margen
              from d
        )
        select jsonb_agg((f.c - 'descarte') || jsonb_build_object(
                   'cantidad', f.cantidad, 'apalancamiento', f.apalancamiento, 'margen', f.margen,
                   'parte', round(v_equity * f.cupo / 100 * v_tope, 2),
                   'consumo', round(f.margen * v_tope, 2),
                   'ganancia_objetivo', round(f.cantidad * ((f.c ->> 'tp')::numeric - f.precio), 2),
                   'riesgo_stop', round(f.cantidad * (f.precio - (f.c ->> 'sl')::numeric), 2))
                   order by f.orden),
               sum(f.cantidad * ((f.c ->> 'tp')::numeric - f.precio)),
               bool_and(f.motivo is null and f.cantidad > 0 and f.margen >= 10)
          into v_set, v_gan, v_ok
          from f;

        v_evals := v_evals || jsonb_build_object('marcadas', v_k, 'valido', v_ok,
                                                 'ganancia_objetivo', round(v_gan, 2));
        continue when not coalesce(v_ok, false);
        if v_gan >= v_deficit then
            v_cubre_k := v_k;
            v_marcadas := v_set;
        end if;
        if v_mejor_g is null or v_gan > v_mejor_g then
            v_mejor_g := v_gan;
            v_mejor_k := v_k;
            if v_cubre_k is null then
                v_marcadas := v_set;
            end if;
        end if;
    end loop;

    if v_marcadas is null then
        return v_base || jsonb_build_object('accion', 'sin_candidatos',
                                            'reparto', jsonb_build_object('evaluado', v_evals));
    end if;
    return v_base || jsonb_build_object(
        'accion', 'abrir',
        'marcadas', v_marcadas,
        'reparto', jsonb_build_object(
            'modo', case when v_cubre_k is not null then 'cubre_meta' else 'maxima_ganancia' end,
            'marcadas', jsonb_array_length(v_marcadas),
            'deficit', round(v_deficit, 2),
            'ganancia_objetivo', (select round(sum((x ->> 'ganancia_objetivo')::numeric), 2)
                                    from jsonb_array_elements(v_marcadas) x),
            'evaluado', v_evals));
end;
$$;
