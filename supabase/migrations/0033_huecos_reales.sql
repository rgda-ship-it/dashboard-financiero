-- ─────────────────────────────────────────────────────────────────────
-- 0033 — Huecos reales en el simulador: regla M3' (doc 05 §5.4, aprobada
-- por el dueño el 2026-10-10).
--
-- La regla M3 cierra al NIVEL del stop, no al precio observado: si entre
-- dos pasadas el precio cae un 3 % por debajo del stop, la operación se
-- registra al stop. Dentro de una sesión es razonable: el mercado cotiza
-- sin pausa y una orden de stop se habría ejecutado cerca de su nivel.
--
-- Pero con el mercado CERRADO no hay nada entre medias. Una acción que el
-- viernes cierra a 100 con el stop en 98 y el lunes abre a 95 no sale a
-- 98: sale a 95, porque no había nadie a quien venderle a 98. El
-- simulador la sacaba a 98, así que un fin de semana no tenía riesgo de
-- hueco. Y un agente que aprende de sus resultados aprendería que
-- mantener las acciones el fin de semana sale gratis, que es justo lo
-- contrario de lo que tiene que evaluar (doc 05 §5.4).
--
-- M3': si entre la última vez que el monitor vio la orden y el precio de
-- ahora el mercado del activo estuvo CERRADO, y ese precio ya está más
-- allá del stop, la orden se cierra a ese precio, como haría un bróker.
-- Se marca `cierre_por_hueco`. El objetivo no cambia: un hueco a favor se
-- sigue cerrando al nivel del objetivo (el lado conservador, M2), y la
-- liquidación se sigue evaluando primero (M1). La cripto cotiza sin pausa:
-- no tiene huecos.
--
-- Afecta a todas las cuentas, también a las de los usuarios (decisión del
-- dueño). Y no cambia nada para lo que ya está cerrado.
-- ─────────────────────────────────────────────────────────────────────

alter table public.ordenes
    add column ultima_observacion_en timestamptz,
    add column cierre_por_hueco      boolean not null default false;

comment on column public.ordenes.ultima_observacion_en is
  'Momento del último precio con el que el monitor evaluó la orden (0033). Sirve para saber si entre esa observación y la siguiente el mercado estuvo cerrado (M3'').';
comment on column public.ordenes.cierre_por_hueco is
  'La orden se cerró al precio de un hueco de apertura, más allá del stop, y no al nivel del stop (M3'', 0033).';

-- ¿Estuvo cerrado el mercado en algún momento entre `p_desde` y `p_hasta`?
-- Si estaba cerrado en `p_desde`, sí. Si estaba abierto, sí cuando
-- `p_hasta` llega después del cierre de esa sesión. Un mercado continuo
-- (riesgo de hueco bajo, la cripto) nunca.
create function public.fn_hubo_cierre(p_mercado text, p_desde timestamptz, p_hasta timestamptz)
returns boolean
language sql stable
as $$
    select case
        when p_desde is null or p_hasta is null or p_hasta <= p_desde then false
        when (select riesgo_hueco from public.mercados where clave = p_mercado) is distinct from 'alto' then false
        when not public.fn_sesion_abierta(p_mercado, p_desde) then true
        else p_hasta >= (select ((p_desde at time zone m.zona_horaria)::date + m.cierre) at time zone m.zona_horaria
                           from public.mercados m where m.clave = p_mercado)
    end
$$;

comment on function public.fn_hubo_cierre(text, timestamptz, timestamptz) is
  'Si entre dos instantes el mercado estuvo cerrado (0033): entonces el primer precio después es un hueco de apertura (M3'').';

revoke execute on function public.fn_hubo_cierre(text, timestamptz, timestamptz) from public, anon;
grant  execute on function public.fn_hubo_cierre(text, timestamptz, timestamptz) to authenticated;

-- La vista del monitor, con dos columnas al final (lo único que admite
-- CREATE OR REPLACE VIEW): cuándo entró la orden y cuándo la vio el
-- monitor por última vez.
create or replace view public.v_ordenes_abiertas_monitor
with (security_invoker = true) as
    select o.id, o.cuenta_id, o.activo_id, o.precio_entrada, o.cantidad,
           o.apalancamiento, o.margen_comprometido, o.tp, o.sl, o.precio_liquidacion,
           a.simbolo, a.clase, a.ultimo_precio as precio_vivo, a.ultimo_precio_en,
           o.fecha_entrada, o.ultima_observacion_en
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

-- El monitor: el de la 0011 con M3'.
create or replace function public.fn_monitorear_ordenes()
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
    v_huecos   int := 0;
    v_vistas   int := 0;
    v_hueco    boolean;
begin
    for v_orden in select * from public.v_ordenes_abiertas_monitor
    loop
        v_vistas := v_vistas + 1;

        if v_orden.precio_vivo <= v_orden.precio_liquidacion then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.precio_liquidacion, 'liquidacion', v_orden.precio_vivo);
            v_liq := v_liq + 1;

        elsif v_orden.precio_vivo <= v_orden.sl then
            -- M3': con el mercado cerrado entre medias no había a quién
            -- venderle al nivel del stop. Se sale al precio del hueco.
            v_hueco := public.fn_hubo_cierre(
                public.fn_mercado_de_clase(v_orden.clase),
                coalesce(v_orden.ultima_observacion_en, v_orden.fecha_entrada),
                v_orden.ultimo_precio_en);
            if v_hueco then
                perform public.rpc_cerrar_orden(
                    v_orden.id, v_orden.precio_vivo, 'sl', v_orden.precio_vivo);
                update public.ordenes set cierre_por_hueco = true where id = v_orden.id;
                v_huecos := v_huecos + 1;
            else
                perform public.rpc_cerrar_orden(
                    v_orden.id, v_orden.sl, 'sl', v_orden.precio_vivo);
            end if;
            v_sl := v_sl + 1;

        elsif v_orden.precio_vivo >= v_orden.tp then
            perform public.rpc_cerrar_orden(
                v_orden.id, v_orden.tp, 'tp', v_orden.precio_vivo);
            v_tp := v_tp + 1;

        else
            -- 0033: sigue abierta. Se anota con qué precio se vio, para que
            -- la próxima pasada sepa si entre medias cerró el mercado.
            update public.ordenes
               set ultima_observacion_en = v_orden.ultimo_precio_en
             where id = v_orden.id
               and ultima_observacion_en is distinct from v_orden.ultimo_precio_en;
        end if;
    end loop;

    return jsonb_build_object('evaluadas', v_vistas, 'liquidacion', v_liq,
                              'sl', v_sl, 'tp', v_tp, 'sl_por_hueco', v_huecos);
end;
$$;

-- Las órdenes abiertas hoy no tienen observación anotada. Sin ella, la
-- primera pasada tomaría la fecha de entrada y podría ver un «cierre de
-- mercado» que el monitor sí observó. Su última observación es, como
-- pronto, el último precio conocido de su activo.
update public.ordenes o
   set ultima_observacion_en = greatest(o.fecha_entrada, a.ultimo_precio_en)
  from public.activos a
 where a.id = o.activo_id and o.estado = 'abierta' and o.ultima_observacion_en is null;
