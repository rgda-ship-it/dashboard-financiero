-- ─────────────────────────────────────────────────────────────────────
-- 0022 — Saldo para operar y reparto ponderado (decisión del dueño, D17,
-- 2026-10-02).
--
-- QUÉ PIDIÓ EL DUEÑO, Y POR QUÉ
--
--   «Abro mi cuenta de 500 $, estoy en Fase 1, tengo hasta 5× para
--   operar: mi saldo para operar son 2.500 $. El sistema propone 3
--   acciones y 2 criptos, abro las cinco, y lo que me interesa saber es
--   qué parte de esos 2.500 $ consume cada operación.» El «3x · 4x · 5x»
--   de cada posición es un dato técnico que no contesta a esa pregunta.
--
--   Y la regla de las 3 posiciones seguía viva aunque la 0021 quitó G4 de
--   las cuentas de usuario: el cupo era margen máx ÷ max_posiciones (60 %
--   ÷ 3 = 20 %), así que tras tres posiciones G3 ya no dejaba margen y la
--   cuarta y la quinta salían «sin margen libre». Y con el 60 % de G3 el
--   saldo nunca llegaba a 2.500 $: como mucho, 500 × 60 % × 5 = 1.500 $.
--
-- LO QUE CAMBIA (solo cuentas de usuario; los agentes siguen igual)
--
--   1. SALDO PARA OPERAR = equity × tope de la fase (500 × 5 = 2.500 $ en
--      Fase 1; × 3 en Fase 2). Una posición CONSUME margen × tope: a 5× su
--      nominal, y a 3× más que su nominal (300 $ nominales a 3× bloquean
--      100 $ de margen, lo mismo que 500 $ a 5×). Lo volátil cuesta más
--      saldo, y la protección contra liquidar antes del stop no se toca.
--      `v_cuentas_equity` gana tres columnas al final.
--   2. G3 AL 100 % POR DEFECTO para el usuario: es «qué parte del saldo
--      para operar quieres usar». `rpc_configurar_cuenta` admite ahora del
--      10 al 100 %. Las cuentas que conservaban el 60 % de fábrica (sin
--      ningún ajuste del usuario) pasan al 100 %, con su evento. Lo que
--      acota la pérdida sigue siendo G2 (≤ 10 % del equity hasta el stop).
--   3. REPARTO ENTRE LAS QUE EL USUARIO MARCA, PONDERADO POR APALANCAMIENTO
--      (`rpc_repartir_saldo`): a cada sugerencia le toca
--          parte = saldo libre × apal_i ÷ Σ apal
--      Una 5× pesa más que una 4×, y una 4× más que una 3×. Con tres
--      acciones a 5×, una cripto a 4× y otra a 3× (Σ = 22) sobre 2.500 $:
--      568 $ · 568 $ · 568 $ · 455 $ · 341 $. La parte es un TECHO: el
--      tamaño sigue saliendo del riesgo por operación, y si el riesgo pide
--      menos, la posición consume menos (la función lo señala).
--   4. `v_recomendaciones_usuario` deja de aplicar el cupo de
--      max_posiciones: en una cuenta de usuario ese número ya no reparte
--      nada. Los agentes siguen con su cupo y su G4 (0016, 0021).
--
-- POR QUÉ G3 PUEDE LLEGAR AL 100 % (la 0020 lo dejaba en 80 %)
--
--   La 0020 temía que «con todo el equity comprometido no quede colchón».
--   El margen es aislado por posición: una posición no puede perder más
--   que su margen, y el stop (G2) corta mucho antes. El dueño eligió usar
--   el saldo entero; quien quiera colchón lo baja en «Tus límites».
--   Con 100 % y 5×, el nominal llega a 5× el equity, por debajo de los 20×
--   del poder de trading (I54 sigue cubriendo esa relación).
-- ─────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════
-- G3 por defecto: todo el saldo para operar
-- ═════════════════════════════════════════════════════════════════════
-- Las cuentas de agente no dependen de este valor: `fn_sincronizar_cuenta_agente`
-- escribe el margen máximo de su perfil.
alter table public.cuentas_simulacion alter column margen_comprometido_max_pct set default 100;

comment on column public.cuentas_simulacion.margen_comprometido_max_pct is
  'G3. Usuarios (desde 0022): qué % del saldo para operar (equity × tope de la fase) se puede usar a la vez; 100 por defecto. Agentes: el de su perfil.';

-- Las cuentas de usuario que siguen con el 60 % de fábrica pasan al 100 %.
-- «De fábrica» = el usuario nunca cambió SU MARGEN: ningún evento de
-- `rpc_configurar_cuenta` sobre esa cuenta en el que el margen de antes y
-- el de después difieran. Si lo movió y está en 60, lo eligió: se respeta.
-- Haber cambiado otro límite (el riesgo, el R:R) no cuenta como elegir 60.
with migradas as (
    update public.cuentas_simulacion c
       set margen_comprometido_max_pct = 100,
           actualizado_en = now()
     where c.usuario_id is not null
       and c.estado <> 'game_over'
       and c.margen_comprometido_max_pct = 60
       and not exists (select 1 from public.eventos_sistema e
                        where e.usuario_id = c.usuario_id
                          and e.datos ? 'antes'
                          and (e.datos ->> 'cuenta_id')::bigint = c.id
                          and (e.datos #>> '{antes,margen_comprometido_max_pct}')::numeric
                              is distinct from (e.datos #>> '{despues,margen_comprometido_max_pct}')::numeric)
    returning c.id, c.usuario_id
)
insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
select usuario_id, 'sys',
       'Tu cuenta usa ahora todo el saldo para operar (margen máximo 60 % → 100 %)',
       jsonb_build_object('cuenta_id', id, 'migracion', '0022',
                          'antes', jsonb_build_object('margen_comprometido_max_pct', 60),
                          'despues', jsonb_build_object('margen_comprometido_max_pct', 100))
  from migradas;

-- ═════════════════════════════════════════════════════════════════════
-- Tus límites: el margen máximo llega al 100 %
--
-- Misma firma que la 0020 (CREATE OR REPLACE conserva los privilegios).
-- Solo cambia el rango del margen. `p_max_posiciones` se sigue aceptando
-- para no romper llamadas antiguas, pero en una cuenta de usuario ya no
-- interviene en nada: la pantalla deja de ofrecerlo.
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.rpc_configurar_cuenta(
    p_max_posiciones   int default null,
    p_riesgo_pct       numeric default null,
    p_margen_max_pct   numeric default null,
    p_ratio_rr_minimo  numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid    uuid := public.fn_exigir_aprobado();
    v_cuenta public.cuentas_simulacion;
    v_antes  jsonb;
    v_despues jsonb;
begin
    select * into v_cuenta from public.cuentas_simulacion
     where usuario_id = v_uid and estado <> 'game_over'
     order by id desc limit 1
       for update;
    if not found then
        raise exception 'No tienes una cuenta de simulación abierta.' using errcode = 'P0002';
    end if;

    if p_max_posiciones is not null and (p_max_posiciones < 1 or p_max_posiciones > 10) then
        raise exception 'Las posiciones abiertas van de 1 a 10. Recibido: %', p_max_posiciones
              using errcode = '22023';
    end if;
    if p_riesgo_pct is not null and (p_riesgo_pct < 0.1 or p_riesgo_pct > 10) then
        raise exception 'El riesgo por operación va del 0,1 %% al 10 %% del equity. Recibido: %', p_riesgo_pct
              using errcode = '22023';
    end if;
    if p_margen_max_pct is not null and (p_margen_max_pct < 10 or p_margen_max_pct > 100) then
        raise exception 'El uso máximo del saldo para operar va del 10 %% al 100 %%. Recibido: %', p_margen_max_pct
              using errcode = '22023';
    end if;
    if p_ratio_rr_minimo is not null and (p_ratio_rr_minimo < 0 or p_ratio_rr_minimo > 5) then
        raise exception 'El R:R mínimo va de 0 a 5. Recibido: %', p_ratio_rr_minimo
              using errcode = '22023';
    end if;

    v_antes := jsonb_build_object(
        'max_posiciones_abiertas', v_cuenta.max_posiciones_abiertas,
        'riesgo_pct_operacion', v_cuenta.riesgo_pct_operacion,
        'margen_comprometido_max_pct', v_cuenta.margen_comprometido_max_pct,
        'ratio_rr_minimo', v_cuenta.ratio_rr_minimo);

    update public.cuentas_simulacion set
        max_posiciones_abiertas     = coalesce(p_max_posiciones, max_posiciones_abiertas),
        riesgo_pct_operacion        = coalesce(round(p_riesgo_pct, 2), riesgo_pct_operacion),
        margen_comprometido_max_pct = coalesce(round(p_margen_max_pct, 2), margen_comprometido_max_pct),
        ratio_rr_minimo             = coalesce(round(p_ratio_rr_minimo, 2), ratio_rr_minimo),
        actualizado_en              = now()
     where id = v_cuenta.id
    returning jsonb_build_object(
        'max_posiciones_abiertas', max_posiciones_abiertas,
        'riesgo_pct_operacion', riesgo_pct_operacion,
        'margen_comprometido_max_pct', margen_comprometido_max_pct,
        'ratio_rr_minimo', ratio_rr_minimo) into v_despues;

    if v_despues is distinct from v_antes then
        insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
        values (v_uid, 'sys', 'Límites de la cuenta de simulación cambiados',
                jsonb_build_object('cuenta_id', v_cuenta.id, 'antes', v_antes, 'despues', v_despues));
    end if;

    return jsonb_build_object('cuenta_id', v_cuenta.id, 'antes', v_antes, 'despues', v_despues);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════
-- v_cuentas_equity: el saldo para operar, al final (lo único que admite
-- CREATE OR REPLACE VIEW). El resto es la vista de la 0014 sin cambios.
--
--   saldo_operar         equity × tope de la fase
--   saldo_operar_en_uso  margen bloqueado × tope   (lo que consumen las abiertas)
--   saldo_operar_max     saldo_operar × margen máx %  (lo que G3 deja usar)
-- ═════════════════════════════════════════════════════════════════════
create or replace view public.v_cuentas_equity
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
           end as drawdown_pct,
           public.fn_poder_trading(
               c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0)) as poder_trading,
           coalesce(p.nominal_abierto, 0) as nominal_abierto,
           round(greatest(c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0), 0)
                 * public.fn_tope_fase(c.fase), 2) as saldo_operar,
           round(c.saldo_bloqueado * public.fn_tope_fase(c.fase), 2) as saldo_operar_en_uso,
           round(greatest(c.saldo_disponible + c.saldo_bloqueado + coalesce(p.pnl_no_realizado, 0), 0)
                 * public.fn_tope_fase(c.fase) * c.margen_comprometido_max_pct / 100, 2) as saldo_operar_max
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

-- ═════════════════════════════════════════════════════════════════════
-- v_recomendaciones_usuario: sin el cupo de max_posiciones
--
-- Mismas columnas y en el mismo orden que la 0016; `cupo_pct` queda nulo
-- porque en una cuenta de usuario el reparto ya no lo fija este número
-- sino las sugerencias que se marcan (`rpc_repartir_saldo`). La fila sigue
-- diciendo si la sugerencia es confirmable y con qué apalancamiento: ese
-- apalancamiento es el PESO del reparto.
-- ═════════════════════════════════════════════════════════════════════
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
           e.leverage_recomendado, null, public.fn_tope_fase(e.fase), null,
           e.clase = 'accion') d;

-- ═════════════════════════════════════════════════════════════════════
-- rpc_repartir_saldo: el reparto de las sugerencias marcadas
--
-- SIN `security definer`: se ejecuta con el rol de quien llama, así que
-- solo ve su cuenta y sus sugerencias (las dos vistas filtran por
-- auth.uid() y llevan security_invoker). No escribe nada: propone, y la
-- apertura sigue pasando por `rpc_abrir_orden` y sus guardarraíles.
--
-- Para cada sugerencia marcada y confirmable:
--   peso        su apalancamiento (el que fija el dimensionado)
--   parte_pct   margen libre % × peso ÷ Σ pesos      (% del equity, en margen)
--   parte       esa misma parte en $ del saldo para operar (× tope)
--   cantidad, margen, apalancamiento, liquidación: el dimensionado con
--               `parte_pct` como cupo
--   consumo     margen × tope: lo que de verdad consume del saldo
--   limitado_por_riesgo  el riesgo por operación pide MENOS que la parte
--
-- El reparto es coherente al abrir una a una: tras abrir la primera, lo
-- que queda libre repartido entre las restantes da la misma parte a cada
-- una (B·w_i/Σw no cambia al quitar w_1 de la suma y b_1 del saldo).
-- ═════════════════════════════════════════════════════════════════════
create function public.rpc_repartir_saldo(p_senal_ids bigint[])
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
               public.fn_tope_fase(ce.fase) as tope,
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
           x.leverage_recomendado, null, x.tope, x.cupo,
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

revoke execute on function public.rpc_repartir_saldo(bigint[]) from public, anon;
grant  execute on function public.rpc_repartir_saldo(bigint[]) to authenticated;
