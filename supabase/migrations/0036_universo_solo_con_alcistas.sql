-- ─────────────────────────────────────────────────────────────────────
-- 0036 — «Ampliar el universo» solo cuenta los ciclos con señales alcistas
-- que el perfil descartó (2026-10-11).
--
-- El domingo 11 Prudencia reabrió «Ampliar el universo de activos»: «5
-- ciclos de hoy sin ningún candidato». Desde la 0032 admite cripto, así que
-- los fines de semana ya tiene señales frescas que mirar; y ninguna cripto
-- era alcista. El contador (0029) sumaba cualquier ciclo con señales
-- frescas y sin candidatas, fuera cual fuera el motivo. Pero que no haya
-- NADA alcista es el mercado, no el universo: ampliar el universo no lo
-- arregla, y ese caso ya lo mide otro disparador («Operar en corto», con
-- `ciclos_sin_alcistas`).
--
-- Ahora solo cuenta un ciclo si, además, hubo al menos una señal fresca
-- alcista y el perfil las descartó todas: eso sí es «faltan activos con mi
-- perfil». Es la misma exclusión que ya hace el autodiagnóstico (0031),
-- que no cuenta los descartes por dirección.
--
-- La petición reabierta queda rechazada con el motivo; si vuelve a saltar
-- por una causa real, se reabre sola conservando esta nota (0029).
-- ─────────────────────────────────────────────────────────────────────

create or replace function public.fn_contar_universo_sin_candidatos()
returns trigger
language plpgsql as $$
begin
    if new.ciclos = old.ciclos + 1
       and new.ciclos_con_universo = old.ciclos_con_universo + 1
       and new.ciclos_sin_candidatos = old.ciclos_sin_candidatos + 1
       -- 0036: y no fue un ciclo «sin alcistas»: hubo algo alcista y el
       -- perfil lo descartó.
       and new.ciclos_sin_alcistas = old.ciclos_sin_alcistas then
        new.ciclos_universo_sin_candidatos := old.ciclos_universo_sin_candidatos + 1;
    end if;
    return new;
end;
$$;

comment on column public.agente_dias.ciclos_universo_sin_candidatos is
  'Ciclos con señales frescas, alguna alcista, en los que ninguna pasó el filtro del agente (0029; desde la 0036 no cuentan los ciclos sin ninguna señal alcista). Es lo que mide «Ampliar el universo».';

update public.agente_backlog
   set estado = 'rechazado',
       resolucion = 'Falso positivo de fin de semana (0036): desde la 0032 Prudencia mira cripto los domingos y no había '
                 || 'señales cripto alcistas. El universo cripto ya se amplió en la 0032. El disparador ya solo cuenta '
                 || 'ciclos con señales alcistas que el perfil descartó. '
                 || coalesce('Antes: ' || resolucion, ''),
       revisado_en = now(),
       actualizado_en = now()
 where clave_deduplicacion = 'nuevo_activo:universo'
   and estado in ('nuevo', 'en_revision');
