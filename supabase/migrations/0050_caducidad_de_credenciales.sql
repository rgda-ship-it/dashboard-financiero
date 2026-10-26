-- ─────────────────────────────────────────────────────────────────────
-- 0050 — Credenciales que no caducan por sorpresa (Fase 3, E2; doc
-- fase-3/00 §3).
--
-- El 23-10 caducó el token `github_pat_altas` de Vault y el ETL dejó de
-- lanzarse durante un día: nadie tenía anotado cuándo caducaba. La 0045
-- hizo visible el fallo cuando ya había pasado; esto avisa antes.
--
-- Lo que cambia:
--   · `credenciales`: un solo sitio que dice qué secretos usa el sistema,
--     dónde viven, para qué sirven, cuándo caducan y cómo se renuevan.
--     Solo METADATOS: ningún valor de ningún secreto pasa por aquí.
--   · `fn_revisar_credenciales`, cada día a las 07:00 UTC: un evento
--     `sys` cuando a una credencial le quedan 14 días o menos, y un
--     `fallo` el día que caduca. Uno por nivel y por fecha de caducidad,
--     no uno por día.
--   · `rpc_credencial_renovada` (solo admin, auditado): anota la nueva
--     fecha de caducidad tras renovar y rearma los avisos.
--   · `rpc_salud_sistema` añade `credenciales`, con los días que quedan.
--
-- Inventario del 2026-10-26 (revisado sin leer ningún valor):
--   · github_pat_altas (Vault): fine-grained, 1 año, renovado el 24-10.
--   · SUPABASE_SERVICE_ROLE_KEY (GitHub Actions): clave `sb_secret`, no
--     caduca.
--   · SUPABASE_DB_URL (GitHub Actions): contraseña de postgres, no caduca.
--   · VITE_SUPABASE_ANON_KEY (Vercel): JWT con `exp` el 2036-09-20.
--   · SUPABASE_DB_URL_LECTURA (.env del dueño): `analista_lectura`, sin
--     `valid until`.
-- ─────────────────────────────────────────────────────────────────────

create table public.credenciales (
    nombre         text primary key,
    donde          text not null,
    para_que       text not null,
    caduca_en      date,
    renovar        text not null,
    renovada_en    timestamptz,
    -- Último aviso dado ('pronto' o 'caducada') y la caducidad a la que
    -- se refería: si cambia la fecha, los avisos se rearman solos.
    aviso          text check (aviso in ('pronto', 'caducada')),
    aviso_para     date,
    actualizado_en timestamptz not null default now()
);

comment on table public.credenciales is
    'Qué secretos usa el sistema y cuándo caducan (0050). Solo metadatos: nunca el valor. caduca_en null = no caduca.';

alter table public.credenciales enable row level security;
-- Sin políticas: se lee con `rpc_salud_sistema` (solo admin) y se cambia
-- con `rpc_credencial_renovada`.
revoke all on public.credenciales from anon, authenticated;

insert into public.credenciales (nombre, donde, para_que, caduca_en, renovar, renovada_en) values
    ('github_pat_altas', 'Vault de Supabase',
     'Lanza el ETL de acciones y de cripto y las altas desde la base de datos (GitHub, Actions: Read and write)',
     date '2027-10-24', 'RUNBOOK-sprint-4, «Renovación»: token fine-grained de 1 año y vault.update_secret',
     timestamptz '2026-10-24 13:00+00'),
    ('SUPABASE_SERVICE_ROLE_KEY', 'Secretos de GitHub Actions',
     'El ETL, el laboratorio y las hipótesis escriben en la base de datos',
     null, 'Supabase → Settings → API keys: crear una clave secreta nueva y sustituir el secreto de GitHub', null),
    ('SUPABASE_DB_URL', 'Secretos de GitHub Actions',
     'keep-alive: respaldo semanal y retención de señales',
     null, 'Supabase → Settings → Database: cambiar la contraseña y sustituir el secreto de GitHub', null),
    ('VITE_SUPABASE_ANON_KEY', 'Variables de Vercel',
     'El navegador habla con Supabase (clave pública por diseño)',
     date '2036-09-20', 'Supabase → Settings → API keys y redesplegar en Vercel', null),
    ('SUPABASE_DB_URL_LECTURA', '.env del dueño',
     'Consultas de solo lectura de Claude (rol analista_lectura)',
     null, 'alter role analista_lectura password … y actualizar el .env', null);

alter table public.auditoria_admin drop constraint auditoria_admin_accion_check;
alter table public.auditoria_admin add constraint auditoria_admin_accion_check check (accion in (
    'aprobar_usuario', 'rechazar_usuario', 'suspender_usuario', 'revertir_fase',
    'resolver_backlog', 'reiniciar_agente', 'cambiar_estado_agente', 'resolver_hipotesis',
    'renovar_credencial'));

-- ═════════════════════════════════════════════════════════════════════
-- Avisos
-- ═════════════════════════════════════════════════════════════════════
create function public.fn_revisar_credenciales()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_c     record;
    v_nivel text;
    v_dias  int;
    v_n     int := 0;
begin
    for v_c in select * from public.credenciales where caduca_en is not null order by nombre for update
    loop
        v_dias := v_c.caduca_en - current_date;
        v_nivel := case when v_dias <= 0 then 'caducada' when v_dias <= 14 then 'pronto' end;
        continue when v_nivel is null
                   or (v_c.aviso = v_nivel and v_c.aviso_para = v_c.caduca_en);

        insert into public.eventos_sistema (tipo, mensaje, datos)
        values (case v_nivel when 'caducada' then 'fallo' else 'sys' end,
                case v_nivel
                     when 'caducada' then format('La credencial %s (%s) ha caducado el %s. Renuévala: %s.',
                                                 v_c.nombre, v_c.donde, to_char(v_c.caduca_en, 'DD-MM-YYYY'), v_c.renovar)
                     else format('La credencial %s (%s) caduca en %s días, el %s. Renuévala: %s.',
                                 v_c.nombre, v_c.donde, v_dias, to_char(v_c.caduca_en, 'DD-MM-YYYY'), v_c.renovar) end,
                jsonb_build_object('donde', 'credenciales', 'credencial', v_c.nombre,
                                   'caduca_en', v_c.caduca_en, 'dias', v_dias, 'nivel', v_nivel));

        update public.credenciales
           set aviso = v_nivel, aviso_para = v_c.caduca_en, actualizado_en = now()
         where nombre = v_c.nombre;
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$;

revoke execute on function public.fn_revisar_credenciales() from public, anon, authenticated;

do $cron$
begin
    if to_regprocedure('cron.schedule(text,text,text)') is not null then
        execute $q$select cron.schedule('revisar-credenciales', '0 7 * * *', 'select public.fn_revisar_credenciales()')$q$;
        raise notice 'revisar-credenciales programado cada día a las 07:00 UTC';
    else
        raise notice 'pg_cron no disponible: la revisión de credenciales no queda programada (esperado en la CI)';
    end if;
end
$cron$;

-- ═════════════════════════════════════════════════════════════════════
-- Anotar una renovación
-- ═════════════════════════════════════════════════════════════════════
create function public.rpc_credencial_renovada(p_nombre text, p_caduca_en date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_previa date;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador anota la renovación de una credencial.' using errcode = '42501';
    end if;
    if p_caduca_en is not null and p_caduca_en <= current_date then
        raise exception 'La nueva caducidad tiene que ser posterior a hoy (%).', p_caduca_en using errcode = '22023';
    end if;

    select caduca_en into v_previa from public.credenciales where nombre = p_nombre for update;
    if not found then
        raise exception 'La credencial % no existe', p_nombre using errcode = 'P0002';
    end if;

    update public.credenciales
       set caduca_en = p_caduca_en, renovada_en = now(), aviso = null, aviso_para = null, actualizado_en = now()
     where nombre = p_nombre;

    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), 'renovar_credencial', 'credenciales', p_nombre,
            jsonb_build_object('de', v_previa, 'a', p_caduca_en));
    return jsonb_build_object('nombre', p_nombre, 'caduca_en', p_caduca_en);
end;
$$;

revoke execute on function public.rpc_credencial_renovada(text, date) from public, anon;
grant  execute on function public.rpc_credencial_renovada(text, date) to authenticated;

-- ═════════════════════════════════════════════════════════════════════
-- Salud del sistema: + credenciales
-- ═════════════════════════════════════════════════════════════════════
create or replace function public.rpc_salud_sistema()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador ve la salud del sistema.' using errcode = '42501';
    end if;

    return jsonb_build_object(
        'generado_en', now(),
        'despachos', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'workflow', d.clave, 'ultimo', d.ultimo, 'estado_http', d.estado_http,
                       'respuesta', d.respuesta, 'fallando_desde', d.fallando_desde)
                     order by d.clave), '[]'::jsonb)
              from public.control_despachos d
             where d.clave in ('etl-acciones.yml', 'etl-cripto.yml')),
        'senales', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'clase', x.clase, 'activos', x.activos, 'con_senal', x.con_senal,
                       'ultima', x.ultima, 'primera', x.primera)
                     order by x.clase), '[]'::jsonb)
              from (select a.clase, count(*) as activos, count(s.calculado_en) as con_senal,
                           max(s.calculado_en) as ultima, min(s.calculado_en) as primera
                      from public.activos a
                      left join public.senales_vigentes s on s.activo_id = a.id
                     where a.estado = 'activo'
                     group by a.clase) x),
        'agentes', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'agente_id', g.id, 'nombre', g.nombre, 'estado', g.estado,
                       'fallos_24h', f.n, 'ultimo_fallo', f.ultimo, 'ultimo_mensaje', f.mensaje,
                       'en_fallo', f.ultimo is not null and f.ultimo > coalesce(r.ultimo, '-infinity'::timestamptz))
                     order by g.id), '[]'::jsonb)
              from public.agentes g
              left join lateral (
                    select count(*) filter (where e.creado_en > now() - interval '24 hours') as n,
                           max(e.creado_en) as ultimo,
                           (array_agg(e.mensaje order by e.id desc))[1] as mensaje
                      from public.eventos_sistema e
                     where e.agente_id = g.id and e.tipo = 'fallo'
                       and e.creado_en > now() - interval '7 days') f on true
              left join lateral (
                    select max(e.creado_en) as ultimo
                      from public.eventos_sistema e
                     where e.agente_id = g.id and e.tipo = 'agente'
                       and e.datos ->> 'recuperado' = 'true') r on true),
        'fallos_sistema_24h', (
            select count(*) from public.eventos_sistema
             where agente_id is null and tipo = 'fallo' and creado_en > now() - interval '24 hours'),
        -- 0050: las que caducan primero, arriba; las que no caducan, al final.
        'credenciales', (
            select coalesce(jsonb_agg(jsonb_build_object(
                       'nombre', c.nombre, 'donde', c.donde, 'para_que', c.para_que,
                       'caduca_en', c.caduca_en, 'dias', c.caduca_en - current_date,
                       'renovar', c.renovar, 'renovada_en', c.renovada_en)
                     order by c.caduca_en nulls last, c.nombre), '[]'::jsonb)
              from public.credenciales c));
end;
$$;

revoke execute on function public.rpc_salud_sistema() from public, anon;
grant  execute on function public.rpc_salud_sistema() to authenticated;
