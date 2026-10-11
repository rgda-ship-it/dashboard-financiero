-- ─────────────────────────────────────────────────────────────────────
-- 0038 — Precio fresco para la decisión diaria de «Tendencia cripto»
--        (2026-10-11).
--
-- El ensayo de la 0037 sobre producción (`scripts/ensayo_tendencia.sql`)
-- dejó a la vista un hueco: la decisión diaria exige, como el monitor, un
-- precio de menos de 15 minutos (M4). Una cripto CON posición lo tiene
-- siempre: el monitor pide su precio a CoinGecko cada minuto. Una SIN
-- posición solo lo recibe del ETL horario (:07). Si el ETL tarda más de
-- trece minutos en escribir, a las :20 el precio ya no es fresco; a la hora
-- siguiente tampoco… y el agente podría pasar el día sin entrar,
-- registrando `sin_precio` a las 07:20.
--
-- Arreglo: durante la ventana de decisión (01:00–07:59 UTC), y solo si hay
-- un agente de estrategia activo, el monitor añade a su petición de cada
-- minuto las criptos del universo de ese agente. Es la MISMA petición
-- (`/simple/price` admite varias ids): no suma llamadas mientras haya
-- posiciones abiertas, y como mucho una por minuto en esas siete horas si
-- no las hay. La lista de ids pasa a una función propia para poder
-- probarla sin red.
-- ─────────────────────────────────────────────────────────────────────

create function public.fn_monitor_ids_cripto(p_ahora timestamptz default now())
returns text
language sql
stable
set search_path = public, pg_temp
as $$
    select string_agg(distinct id_proveedor, ',' order by id_proveedor)
      from (
        -- Lo de siempre: criptos con una posición abierta.
        select a.id_proveedor
          from public.ordenes o
          join public.activos a on a.id = o.activo_id
          join public.cuentas_simulacion c on c.id = o.cuenta_id
         where o.estado = 'abierta'
           and a.clase = 'cripto'
           and c.estado <> 'game_over'
        union
        -- 0038: en la ventana de decisión, el universo de los agentes de
        -- estrategia activos.
        select a.id_proveedor
          from public.agentes g
          join public.activos a
            on a.clase in (select jsonb_array_elements_text(g.estrategia -> 'clases_admitidas'))
         where g.tipo = 'estrategia'
           and g.estado = 'activo'
           and a.estado = 'activo'
           and a.clase = 'cripto'
           and extract(hour from p_ahora at time zone 'UTC') between 1 and 7
      ) s
     where id_proveedor is not null
$$;

comment on function public.fn_monitor_ids_cripto(timestamptz) is
  'Ids de CoinGecko cuyo precio pide el monitor cada minuto: las criptos con posición abierta y, de 01:00 a 07:59 UTC, el universo de los agentes de estrategia activos (0038).';

create or replace function public.fn_monitor_pedir_precios()
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

    v_ids := public.fn_monitor_ids_cripto(now());
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

revoke execute on function public.fn_monitor_ids_cripto(timestamptz) from public, anon, authenticated;
