-- ─────────────────────────────────────────────────────────────────────
-- 0053 — Prudencia vuelve a salir por deterioro (2026-10-31; doc fase-3/09
-- §3, decisión del dueño).
--
-- El 29-10 a las 13:40, dos días antes de que se aplicara la 0052,
-- Prudencia apagó sola la salida por deterioro (10 decisiones, −0,22 de
-- efecto medio). 7 de esas 10 eran de antes de la 0043, cuando bastaba una
-- lectura; con la regla de hoy (dos lecturas) la salida ganaba: +4,04 $ de
-- media en las 3 posteriores. Era el ajuste que la 0052 quería evitar, y se
-- deshace: Prudencia vuelve a las reglas con las que empezó el experimento.
-- Los dos ajustes del 15-10 (Audacia y Cadencia) se quedan.
--
-- Se registra en agente_ajustes como cualquier ajuste, marcado como
-- manual. Así, cuando acabe el experimento y se descongelen los ajustes,
-- la salida por deterioro de Prudencia se juzgará solo con decisiones
-- posteriores a hoy, todas con la regla de la 0043.
-- Idempotente: solo actúa si la tiene apagada.
-- ─────────────────────────────────────────────────────────────────────

with apagada as (
    select id from public.agentes
     where nombre = 'Prudencia'
       and not coalesce((estrategia ->> 'salida_deterioro')::boolean, true)
), encendida as (
    update public.agentes a
       set estrategia = jsonb_set(a.estrategia, '{salida_deterioro}', 'true'::jsonb)
      from apagada
     where a.id = apagada.id
    returning a.id
)
insert into public.agente_ajustes (agente_id, tipo, de, a, evidencia)
select id, 'deterioro', 'false'::jsonb, 'true'::jsonb,
       jsonb_build_object('manual', true,
                          'motivo', 'Deshace el ajuste del 29-10: 7 de sus 10 decisiones eran de antes de la 0043 (doc fase-3/09 §3)')
  from encendida;
