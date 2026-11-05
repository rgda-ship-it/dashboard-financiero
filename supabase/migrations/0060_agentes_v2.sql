-- ─────────────────────────────────────────────────────────────────────
-- 0060 — Prudencia v2, Cadencia v2 y Audacia v2
--        (doc fase-3/12 §4; decisión del dueño, 2026-11-05).
--
-- Tres agentes NUEVOS, con su propia cuenta de 500 $, que arrancan al
-- aplicar esta migración. El grupo de control (Prudencia, Cadencia y
-- Audacia) no cambia: sus estrategias no llevan las claves nuevas, y
-- para ellos `fn_universo_agente` da lo mismo que antes.
--
--   Prudencia v2  las reglas de Prudencia, en una cuenta limpia
--   Cadencia v2   las de Cadencia, y solo con ADX(14) ≥ 25 (`adx_min`)
--   Audacia v2    las de Audacia, sin acciones de menos de 10 $
--                 (`precio_min_accion`; las criptos baratas siguen)
--
-- Las tres, con los ajustes automáticos y las consecuencias semanales
-- congelados (`consecuencias_semanales = false`, 0042 y 0052): la regla
-- que se mide es la que se fijó hoy. Su veredicto queda fijado en
-- `agente_veredicto_criterio` (0059) con lo que espera el laboratorio.
--
-- Y para los agentes que no son del grupo de control, el dueño puede
-- AÑADIR SALDO (`rpc_aportar_saldo_agente`): un apunte `aportacion` en el
-- libro mayor, que sube también el saldo inicial de la cuenta. Así la
-- rentabilidad se mide sobre todo lo aportado y la base para operar
-- (0055) crece con la aportación. Auditado.
-- ─────────────────────────────────────────────────────────────────────

-- ── Quién es del grupo de control y de quién deriva cada agente ──────
alter table public.agentes
    add column grupo_control boolean not null default false,
    add column deriva_de bigint references public.agentes (id);

comment on column public.agentes.grupo_control is
  'Prudencia, Cadencia y Audacia durante el experimento: no se cambian a mano ni admiten aportaciones (0060).';
comment on column public.agentes.deriva_de is
  'El agente del que es versión (0060: las v2 derivan del grupo de control).';

update public.agentes set grupo_control = true
 where tipo = 'metas' and nombre in ('Prudencia', 'Cadencia', 'Audacia');

-- ── El universo de un agente, con dos filtros más ────────────────────
-- La función de la 0043 con dos motivos de descarte nuevos, justo
-- después de la banda de ATR. Sin las claves en la estrategia (el grupo
-- de control), no actúan.
--   precio_bajo  acción por debajo de `precio_min_accion` (doc fase-3/02 §5)
--   adx          ADX(14) del último día por debajo de `adx_min` (doc fase-3/05)
create or replace function public.fn_universo_agente(p_params jsonb, p_cuenta_id bigint, p_practicas jsonb)
returns table (
    senal_id bigint, activo_id bigint, simbolo text, clase text, fuerza text,
    niveles_origen text, ratio_rr numeric, atr_pct numeric, precio_actual numeric,
    sl numeric, tp numeric, leverage_recomendado numeric,
    alcistas int, bajistas int, antiguedad_min int, motivo text)
language sql stable
as $$
    select s.id, s.activo_id, s.simbolo, s.clase, s.fuerza, s.niveles_origen,
           s.ratio_rr, s.atr_pct, s.precio_actual, s.sl, s.tp, s.leverage_recomendado,
           s.indicadores_alcistas, s.indicadores_bajistas, x.antiguedad_min,
           case
               when x.antiguedad_min > (p_params ->> 'antiguedad_senal_max_min')::int
                    then case when s.clase = 'accion' and public.fn_esperando_apertura(now())
                                   then 'fuera_de_sesion'   -- 0029: aún sin la primera lectura de la sesión
                              when s.clase = 'cripto' or public.fn_mercado_abierto(now())
                                   then 'antiguedad' else 'fuera_de_sesion' end
               when not (s.indicadores_alcistas > s.indicadores_bajistas) then 'direccion'
               when not s.operable and s.atr_pct is null then 'sin_atr'
               when not s.operable then 'no_operable'
               when not (p_params -> 'fuerzas_admitidas' ? coalesce(s.fuerza, '')) then 'fuerza'
               when not (p_params -> 'niveles_origen_admitidos' ? coalesce(s.niveles_origen, '')) then 'niveles_origen'
               when s.ratio_rr is null or s.ratio_rr < (p_params ->> 'rr_minimo')::numeric then 'rr'
               -- 0032: el rango de ATR puede ser distinto por mercado.
               when public.fn_param_clase(p_params, s.clase, 'atr_pct_min') #>> '{}' is not null
                    and (s.atr_pct is null
                         or s.atr_pct < (public.fn_param_clase(p_params, s.clase, 'atr_pct_min') #>> '{}')::numeric) then 'atr_bajo'
               when public.fn_param_clase(p_params, s.clase, 'atr_pct_max') #>> '{}' is not null
                    and (s.atr_pct is null
                         or s.atr_pct > (public.fn_param_clase(p_params, s.clase, 'atr_pct_max') #>> '{}')::numeric) then 'atr_alto'
               -- 0060: solo para quien lleve las claves (las v2).
               when s.clase = 'accion' and p_params ->> 'precio_min_accion' is not null
                    and (s.precio_actual is null
                         or s.precio_actual < (p_params ->> 'precio_min_accion')::numeric) then 'precio_bajo'
               when p_params ->> 'adx_min' is not null
                    and coalesce((select i.adx_14 from public.indicadores_diarios i
                                   where i.activo_id = s.activo_id and i.adx_14 is not null
                                   order by i.fecha desc limit 1), -1)
                        < (p_params ->> 'adx_min')::numeric then 'adx'
               when exists (select 1 from public.ordenes o
                             where o.cuenta_id = p_cuenta_id and o.activo_id = s.activo_id
                               and o.estado = 'abierta') then 'posicion_abierta'
               -- 0043: tras un stop en este activo, se espera antes de volver.
               when exists (select 1 from public.ordenes o
                             where o.cuenta_id = p_cuenta_id and o.activo_id = s.activo_id
                               and o.estado = 'cerrada' and o.motivo_cierre in ('sl', 'liquidacion')
                               and o.fecha_salida > now() - make_interval(
                                       hours => coalesce((p_params ->> 'espera_tras_stop_horas')::int, 48)))
                    then 'tras_stop'
               when exists (select 1 from jsonb_array_elements(coalesce(p_practicas, '[]'::jsonb)) e
                             where case when coalesce(e ->> 's', 'exigir') = 'evitar'
                                        then public.fn_cumple_condiciones(
                                                 e -> 'c', s.clase, s.fuerza, s.niveles_origen, s.atr_pct, s.ratio_rr)
                                        else not public.fn_cumple_condiciones(
                                                 coalesce(e -> 'c', e), s.clase, s.fuerza, s.niveles_origen,
                                                 s.atr_pct, s.ratio_rr) end)
                    then 'practica'
           end
      from public.senales_vigentes s
      cross join lateral (
           select round(extract(epoch from now() - s.calculado_en) / 60)::int as antiguedad_min) x
     where s.estado_activo = 'activo'
       and p_params -> 'clases_admitidas' ? s.clase
$$;

-- ── Añadir saldo ─────────────────────────────────────────────────────
alter table public.movimientos_saldo drop constraint movimientos_saldo_tipo_check;
alter table public.movimientos_saldo add constraint movimientos_saldo_tipo_check check (tipo in (
    'deposito_inicial', 'bloqueo_margen', 'liberacion_margen',
    'resultado_operacion', 'ajuste_manual', 'aportacion'));

alter table public.auditoria_admin drop constraint auditoria_admin_accion_check;
alter table public.auditoria_admin add constraint auditoria_admin_accion_check check (accion in (
    'aprobar_usuario', 'rechazar_usuario', 'suspender_usuario', 'revertir_fase',
    'resolver_backlog', 'reiniciar_agente', 'cambiar_estado_agente', 'resolver_hipotesis',
    'renovar_credencial', 'aportar_saldo'));

create function public.rpc_aportar_saldo_agente(p_agente_id bigint, p_importe numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_ag     public.agentes;
    v_cuenta bigint;
    v_antes  numeric;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador puede añadir saldo a un agente.' using errcode = '42501';
    end if;
    if p_importe is null or p_importe < 10 or p_importe > 100000 then
        raise exception 'Importe no válido: % (de 10 a 100.000 $)', p_importe using errcode = '22023';
    end if;
    select * into v_ag from public.agentes where id = p_agente_id for update;
    if not found then
        raise exception 'El agente % no existe', p_agente_id using errcode = 'P0002';
    end if;
    if v_ag.grupo_control then
        raise exception '% es del grupo de control: no admite aportaciones durante el experimento.', v_ag.nombre
              using errcode = 'P0001';
    end if;
    v_cuenta := public.fn_cuenta_agente(p_agente_id);
    if v_cuenta is null then
        raise exception '% no tiene cuenta', v_ag.nombre using errcode = 'P0002';
    end if;

    select saldo_inicial into v_antes from public.cuentas_simulacion where id = v_cuenta for update;
    perform public.fn_registrar_movimiento(v_cuenta, null, 'aportacion', round(p_importe, 2), 0);
    update public.cuentas_simulacion set saldo_inicial = saldo_inicial + round(p_importe, 2) where id = v_cuenta;

    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), 'aportar_saldo', 'agente', p_agente_id::text,
            jsonb_build_object('agente', v_ag.nombre, 'importe', round(p_importe, 2),
                               'saldo_inicial_antes', v_antes, 'saldo_inicial_despues', v_antes + round(p_importe, 2)));
    insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
    values (p_agente_id, 'agente',
            v_ag.nombre || ' recibe ' || to_char(round(p_importe, 2), 'FM999G999D00') || ' $ de saldo',
            jsonb_build_object('importe', round(p_importe, 2)));
    return jsonb_build_object('agente', v_ag.nombre, 'importe', round(p_importe, 2),
                              'saldo_inicial', v_antes + round(p_importe, 2));
end;
$$;

comment on function public.rpc_aportar_saldo_agente(bigint, numeric) is
  'Añade saldo a un agente que no es del grupo de control (0060): apunte en el libro mayor, sube el saldo inicial y queda auditado.';

revoke execute on function public.rpc_aportar_saldo_agente(bigint, numeric) from public, anon;
grant execute on function public.rpc_aportar_saldo_agente(bigint, numeric) to authenticated;

-- ── Las tres v2 ──────────────────────────────────────────────────────
insert into public.agentes (nombre, tipo, objetivo_diario_pct, objetivo_final, saldo_inicial, estrategia,
                            version_estrategia, estado, consecuencias_semanales, grupo_control, deriva_de)
select g.nombre || ' v2', 'metas', g.objetivo_diario_pct, g.objetivo_final, 500,
       g.estrategia || jsonb_build_object('version', 1) || v.cambio,
       1, 'activo', false, false, g.id
  from public.agentes g
  join (values ('Prudencia', '{}'::jsonb),
               ('Cadencia', '{"adx_min": 25}'::jsonb),
               ('Audacia', '{"precio_min_accion": 10}'::jsonb)) v(nombre, cambio) on v.nombre = g.nombre
 where g.grupo_control;

select public.fn_crear_cuenta_agente(id) from public.agentes where deriva_de is not null and nombre like '% v2';

insert into public.eventos_sistema (agente_id, tipo, mensaje, datos)
select id, 'agente', nombre || ' se pone en marcha (0060)',
       jsonb_build_object('deriva_de', deriva_de, 'estrategia', estrategia)
  from public.agentes where deriva_de is not null and nombre like '% v2';

-- ── Su veredicto, fijado ─────────────────────────────────────────────
-- Laboratorio, como la 0059: velas diarias del 2016-11-05 al 2026-11-05,
-- universo de producción del 2026-11-05 sin índices, 10 años enteros.
--   Prudencia v2  −0,041 R  σ 1,713  595 operaciones (las reglas de Prudencia)
--   Cadencia v2   −0,175 R  σ 3,080  105            (diseño −0,490, validación +0,316)
--   Audacia v2    +0,054 R  σ 1,441  558            (diseño +0,033, validación +0,085)
insert into public.agente_veredicto_criterio
       (agente_id, desde, vara, vara_desde, expectativa_lab_r, desviacion_lab_r, operaciones_lab, lab_periodo, notas)
select g.id, g.creado_en, 'universo', g.creado_en::date, v.e, v.s, v.n,
       'velas diarias, 2016-11-05 → 2026-11-05, universo de producción del 2026-11-05 sin índices',
       v.notas
  from public.agentes g
  join (values ('Prudencia v2', -0.041, 1.713, 595, 'Las reglas de Prudencia, en una cuenta limpia'),
               ('Cadencia v2', -0.175, 3.080, 105,
                'Cadencia solo con ADX ≥ 25: mejora en validación y empeora en diseño; prueba en vivo'),
               ('Audacia v2', 0.054, 1.441, 558,
                'Audacia sin acciones de menos de 10 $: mejora en validación y empeora en diseño; prueba en vivo'))
       v(nombre, e, s, n, notas) on v.nombre = g.nombre;
