-- ─────────────────────────────────────────────────────────────────────
-- 0028 — SPCX es una acción, no la cripto `spcx` (2026-10-05).
--
-- El 2026-09-30 entró en el catálogo la cripto de CoinGecko `spcx` (id 40
-- en producción) cuando lo que se buscaba era la acción SPCX. El buscador
-- de la cartera listaba primero los resultados de CoinGecko, con el mismo
-- ticker, y la opción «Buscar la acción en Yahoo Finance» debajo; y en
-- cuanto la cripto estuvo en el catálogo, esa opción DESAPARECÍA: el
-- buscador la ocultaba ante cualquier resultado con el mismo símbolo, sin
-- mirar la clase. La acción no se podía añadir. (El buscador se corrige en
-- el mismo cambio: frontend/src/datos/buscador.js.)
--
-- Por estar `activo`, la cripto entró en el universo de los agentes (D12):
-- Cadencia y Audacia abrieron una posición el 2026-10-01 que sigue abierta.
--
-- Qué hace esta migración, solo sobre la cripto `spcx`:
--   1. Cierra sus posiciones abiertas al último precio conocido, motivo
--      `manual`. No se anulan: estuvieron abiertas de verdad, con margen
--      bloqueado, y el libro mayor tiene que seguir cuadrando.
--   2. La quita de las carteras que la siguen.
--   3. La suspende. Sale del universo de los agentes (solo opera lo
--      `activo`) y, sin seguidores ni posiciones, el ETL no la vuelve a
--      procesar, así que no regresa a `activo` por su cuenta. Se conserva
--      con su histórico porque hay órdenes que la referencian.
--   4. Deja un evento en el registro con lo que se hizo.
--
-- La acción SPCX se añade después desde el buscador corregido: Yahoo la
-- valida, comprueba que cotiza en USD y descarga su histórico.
-- ─────────────────────────────────────────────────────────────────────

do $spcx$
declare
    v_activo  public.activos;
    v_orden   record;
    v_cierres jsonb := '[]'::jsonb;
    v_quitadas int;
begin
    select * into v_activo from public.activos
     where clase = 'cripto' and simbolo = 'spcx' and estado <> 'suspendido';
    if not found then
        return;   -- base de datos limpia (CI) o ya corregida: nada que hacer
    end if;

    for v_orden in
        select o.id, c.agente_id
          from public.ordenes o
          join public.cuentas_simulacion c on c.id = o.cuenta_id
         where o.activo_id = v_activo.id and o.estado = 'abierta'
         order by o.id
    loop
        perform public.rpc_cerrar_orden(v_orden.id, v_activo.ultimo_precio, 'manual', v_activo.ultimo_precio);
        v_cierres := v_cierres || jsonb_build_object(
            'orden_id', v_orden.id, 'agente_id', v_orden.agente_id,
            'pnl', (select pnl_bruto from public.ordenes where id = v_orden.id));
    end loop;

    delete from public.cartera_activos where activo_id = v_activo.id;
    get diagnostics v_quitadas = row_count;

    update public.activos set estado = 'suspendido' where id = v_activo.id;

    insert into public.eventos_sistema (tipo, mensaje, datos)
    values ('sys',
            'La cripto spcx se suspende: se buscaba la acción SPCX',
            jsonb_build_object('activo_id', v_activo.id, 'precio_cierre', v_activo.ultimo_precio,
                               'precio_en', v_activo.ultimo_precio_en, 'cierres', v_cierres,
                               'carteras_quitadas', v_quitadas, 'migracion', '0028'));
end
$spcx$;
