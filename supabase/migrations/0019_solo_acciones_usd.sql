-- ─────────────────────────────────────────────────────────────────────
-- 0019 — Cortafuegos de moneda: solo acciones en USD (2026-09-30).
--
-- Todo el sistema supone dólares: `activos.moneda` vale siempre 'USD' y el
-- tamaño, el margen, el equity y el libro mayor no convierten nada. Yahoo
-- da el precio en la moneda LOCAL (Toyota en yenes, Londres en peniques),
-- así que una acción de otra bolsa se leería como si sus yenes fueran
-- dólares, y todos los números del simulador y de los agentes serían
-- falsos. Además el ETL y el monitor solo conocen el horario de Nueva York.
--
-- Hasta el proyecto «multimercado» (conversión de divisas, horario por
-- bolsa, lotes mínimos), el alta rechaza las acciones que no coticen en
-- USD en dos capas:
--   · aquí, al pedirlas: los símbolos con sufijo de bolsa extranjera, al
--     instante y sin gastar una llamada a Yahoo;
--   · en `altas.py`, al validarlas: la moneda que declara Yahoo, que es la
--     comprobación definitiva (índices como ^N225, casos sin sufijo).
--
-- Mismo cuerpo que la versión de la 0013 más el bloque marcado.
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.rpc_solicitar_activo(p_clase text, p_identificador text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid     uuid := public.fn_exigir_aprobado();
    v_simbolo text;
    v_activo  public.activos;
    v_cg      public.catalogo_coingecko;
    v_disparo text;
begin
    perform public.fn_limitar_uso('solicitar_activo', 30);

    if p_clase = 'cripto' then
        v_simbolo := lower(btrim(p_identificador));
    elsif p_clase = 'accion' then
        v_simbolo := upper(btrim(p_identificador));
    else
        raise exception 'Clase de activo desconocida: %', p_clase using errcode = '22023';
    end if;

    select * into v_activo from public.activos
     where simbolo = v_simbolo
        or (p_clase = 'cripto' and clase = 'cripto' and id_proveedor = v_simbolo)
     limit 1;
    if found then
        if v_activo.estado = 'invalido' then
            raise exception 'El proveedor no reconoce «%»', v_simbolo using errcode = '22023';
        end if;
        perform public.fn_seguir(v_uid, v_activo.id);
        return jsonb_build_object('estado', 'seguido', 'activo_id', v_activo.id);
    end if;

    if p_clase = 'cripto' then
        select * into v_cg from public.catalogo_coingecko where id = v_simbolo;
        if not found then
            raise exception 'CoinGecko no tiene ninguna criptomoneda con el identificador «%»', v_simbolo
                  using errcode = '22023';
        end if;
        perform public.fn_verificar_cuota(v_uid, null, 'cripto');
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, nombre, estado)
        values (v_cg.id, 'cripto', 'coingecko', v_cg.id, v_cg.nombre, 'pendiente_backfill')
        returning * into v_activo;
        perform public.fn_seguir(v_uid, v_activo.id);
        v_disparo := public.fn_disparar_altas();
        return jsonb_build_object('estado', 'aprovisionando', 'activo_id', v_activo.id,
                                  'disparo', v_disparo);
    end if;

    -- Cortafuegos de moneda (0019): un punto en un símbolo de Yahoo es el
    -- sufijo de una bolsa no estadounidense (7203.T Tokio, VOD.L Londres,
    -- SAP.DE Xetra, 600519.SS Shanghái). Cotizan en su moneda local y el
    -- sistema aún no convierte divisas. Las clases de acciones de EE. UU.
    -- usan guion en Yahoo (BRK-B), no punto. `altas.py` hace además la
    -- comprobación definitiva contra la moneda que declara Yahoo.
    if position('.' in v_simbolo) > 0 then
        raise exception '«%» cotiza fuera de EE. UU.: por ahora solo se admiten acciones en dólares (USD). Si es una clase de acción (como BRK.B), escríbela con guion: BRK-B.',
              v_simbolo using errcode = '22023';
    end if;

    if v_simbolo !~ '^[A-Z0-9^][A-Z0-9.=^-]{0,14}$' then
        raise exception '«%» no tiene el formato de un símbolo bursátil', p_identificador
              using errcode = '22023';
    end if;
    perform public.fn_verificar_cuota(v_uid, null, 'accion');

    insert into public.solicitudes_activo (usuario_id, simbolo)
    values (v_uid, v_simbolo)
    on conflict (usuario_id, simbolo) where estado in ('pendiente', 'procesando') do nothing;

    v_disparo := public.fn_disparar_altas();
    return jsonb_build_object('estado', 'verificando', 'simbolo', v_simbolo, 'disparo', v_disparo);
end;
$$;
