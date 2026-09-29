-- ─────────────────────────────────────────────────────────────────────
-- 0017 — Mínimo de una acción (decisión del dueño, 2026-09-29).
--
-- Con acciones enteras, el riesgo por operación puede no llegar para UNA:
-- Prudencia arriesga un 1,5 % de 500 $ (7,50 $); con el stop un 10 % por
-- debajo, una acción de 100 $ arriesga 10 $ y el cálculo daba cero. No le
-- faltaba poder de compra —a 5× mueve 2.500 $—: le faltaba margen de
-- PÉRDIDA. El apalancamiento no cambia lo que se pierde si salta el stop.
--
-- Decisión: cuando el cálculo da cero acciones, se compra una si su riesgo
-- hasta el stop no pasa del 10 % del equity (G2, el límite duro) y su
-- margen cabe en el saldo y en el tope de margen comprometido (G3). En el
-- ejemplo, 10 $ = 2 % del equity: algo más de lo declarado, dentro del
-- límite. La interfaz lo señala en el racional de la orden.
--
-- Misma firma que la 0016: CREATE OR REPLACE, sin tocar las vistas ni los
-- privilegios que dependen de ella. El gemelo de Python cambia igual
-- (`riesgo/dimensionado.py`).
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.fn_dimensionar_posicion(
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
    p_cupo_pct              numeric default null,
    p_unidades_enteras      boolean default false,
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
    v_riesgo_max := p_equity * p_riesgo_pct / 100;

    v_distancia := (p_precio - p_sl) / p_precio;
    if v_distancia <= 0 then
        motivo := 'stop_por_encima_del_precio';
        return;
    end if;

    v_nominal := v_riesgo_max / v_distancia;

    apalancamiento := least(coalesce(p_leverage_recomendado, p_tope_fase),
                            coalesce(p_leverage_propio, p_tope_fase),
                            p_tope_fase);
    if apalancamiento < 1 then
        motivo := 'apalancamiento_bajo_uno';
        return;
    end if;

    precio_liquidacion := p_precio * (1 - 1 / apalancamiento);
    if precio_liquidacion > p_sl then
        apalancamiento := public.fn_piso_decimal(1 / v_distancia) - 0.1;
        if apalancamiento < 1.0 then
            motivo := 'sin_operacion_liquidacion_antes_del_stop';
            return;
        end if;
        precio_liquidacion := p_precio * (1 - 1 / apalancamiento);
    end if;

    -- 5. Topes por saldo, por margen total comprometido (G3) y, desde la
    --    0016, por CUPO de la posición: con él, una sola orden ya no puede
    --    llevarse todo el margen que admite la cuenta.
    v_margen_libre := p_equity * p_margen_max_pct / 100 - p_saldo_bloqueado;
    margen := least(v_nominal / apalancamiento,
                    p_saldo_disponible * 0.95,
                    v_margen_libre,
                    coalesce(p_equity * p_cupo_pct / 100, v_nominal / apalancamiento));
    margen := floor(margen * 100) / 100;
    if margen <= 0 then
        motivo := 'margen_insuficiente';
        return;
    end if;

    -- Las acciones no se compran por fracciones; las criptos sí. Con
    -- unidades enteras se redondea HACIA ABAJO (hacia arriba se pasaría de
    -- los topes) y el margen se recalcula para esas unidades.
    if p_unidades_enteras then
        cantidad := floor(margen * apalancamiento / p_precio);
        -- 0017 · Mínimo de UNA acción. Si el riesgo declarado no llega para
        -- una acción entera, se compra una siempre que su riesgo hasta el
        -- stop no pase del 10 % del equity (G2, el límite duro) y que su
        -- margen quepa en el saldo y en el tope de margen comprometido (G3).
        -- El cupo no se aplica aquí: es una recomendación, y la alternativa
        -- es no operar.
        if cantidad < 1
           and p_precio - p_sl <= p_equity * 10 / 100
           and ceil(p_precio / apalancamiento * 100) / 100
               <= least(p_saldo_disponible * 0.95, v_margen_libre) then
            cantidad := 1;
        end if;
        if cantidad < 1 then
            motivo := 'cantidad_nula';
            return;
        end if;
        margen := ceil(cantidad * p_precio / apalancamiento * 100) / 100;
    else
        cantidad := round(margen * apalancamiento / p_precio, 8);
    end if;
    if cantidad <= 0 then
        motivo := 'cantidad_nula';
        return;
    end if;
    motivo := null;
end;
$$;
