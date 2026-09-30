-- ─────────────────────────────────────────────────────────────────────
-- 0018 — Retención de eventos y un respaldo que cubre el experimento.
--
-- DOS CABOS SUELTOS DE LA FASE 2
--
--   1. `eventos_sistema` no tenía retención. Con tres agentes abriendo y
--      cerrando órdenes crece unos miles de filas al mes: poco, pero sin
--      techo. `fn_retencion_eventos` borra los avisos de más de 180 días y
--      conserva siempre los que son HISTORIA del experimento (cortes
--      semanales, Game Overs, cambios de fase). Lo demás —cierres,
--      prácticas, backlog— son avisos: el dato vive en su tabla.
--
--   2. El respaldo semanal (`respaldo.py`) solo copiaba gobierno y
--      catálogo: ni cuentas, ni órdenes, ni libro mayor, ni agentes. Es
--      decir, NADA del experimento, que es lo único que no se regenera
--      desde los proveedores. Para respaldarlo hacen falta dos piezas de
--      base de datos:
--
--        · `v_senales_evidencia`: las señales que justifican una orden.
--          `ordenes.senal_id` es clave ajena, así que restaurar órdenes
--          sin sus señales fallaría; y respaldar `senales` entera son
--          cientos de MB regenerables. Esta vista es el término medio —la
--          misma «evidencia» que `fn_retencion_senales` nunca borra—.
--        · `fn_reajustar_secuencias`: tras restaurar filas con sus ids,
--          las secuencias siguen donde estaban y el primer INSERT nuevo
--          chocaría con un id restaurado. La llama el script de
--          restauración al terminar.
-- ─────────────────────────────────────────────────────────────────────

create function public.fn_retencion_eventos()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_borrados bigint;
begin
    delete from public.eventos_sistema
     where creado_en < now() - interval '180 days'
       and tipo not in ('corte_semanal', 'game_over', 'cambio_fase');
    get diagnostics v_borrados = row_count;
    return jsonb_build_object('borrados', v_borrados, 'ejecutado_en', now());
end;
$$;

comment on function public.fn_retencion_eventos() is
  'Borra avisos de eventos_sistema de más de 180 días; conserva cortes semanales, Game Overs y cambios de fase. La invoca respaldo.py cada semana.';

create view public.v_senales_evidencia
with (security_invoker = true) as
    select s.*
      from public.senales s
     where exists (select 1 from public.ordenes o where o.senal_id = s.id);

comment on view public.v_senales_evidencia is
  'Señales referenciadas por una orden: lo que respaldo.py copia de senales para que las órdenes se puedan restaurar.';

create function public.fn_reajustar_secuencias()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_r   record;
    v_max bigint;
    v_out jsonb := '{}'::jsonb;
begin
    -- Toda columna de `public` cuyo valor por defecto sale de una
    -- secuencia (bigserial) o que es identity.
    for v_r in
        select c.relname as tabla, a.attname as columna,
               pg_get_serial_sequence(format('public.%I', c.relname), a.attname) as secuencia
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
          join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
         where c.relkind = 'r'
           and pg_get_serial_sequence(format('public.%I', c.relname), a.attname) is not null
    loop
        execute format('select max(%I) from public.%I', v_r.columna, v_r.tabla) into v_max;
        if v_max is not null then
            perform setval(v_r.secuencia, v_max);
            v_out := v_out || jsonb_build_object(v_r.tabla, v_max);
        end if;
    end loop;
    return v_out;
end;
$$;

revoke execute on function public.fn_retencion_eventos()     from public, anon, authenticated;
revoke execute on function public.fn_reajustar_secuencias()  from public, anon, authenticated;
grant  execute on function public.fn_retencion_eventos()     to service_role;
grant  execute on function public.fn_reajustar_secuencias()  to service_role;
