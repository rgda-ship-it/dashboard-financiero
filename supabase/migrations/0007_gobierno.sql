-- ─────────────────────────────────────────────────────────────────────
-- 0007 — Gobierno: perfiles, aprobación por administrador y RLS completa.
--
-- Sprint 3 · H-13, H-14, H-15.
--
-- LA IDEA QUE SOSTIENE ESTE FICHERO: Supabase Auth entrega un token
-- válido a CUALQUIERA que se registre y confirme su correo. Ese token no
-- significa «puede ver datos»; significa «sabemos quién es». La puerta
-- real es `perfiles.estado = 'aprobado'`, y vive aquí, en la base de
-- datos, no en el menú de la interfaz: un usuario pendiente que llame a
-- la API a mano con su token recibe cero filas.
--
-- DECISIÓN DEL DUEÑO (2026-09-22): el administrador NO es «el primer
-- usuario que se registre», como decía el plan. La web es pública y
-- cualquiera podría adelantarse. El admin inicial está ligado a un correo
-- concreto y solo se promueve cuando ese correo está CONFIRMADO: quien se
-- registre con esa dirección sin poder leer su buzón se queda pendiente.
-- ─────────────────────────────────────────────────────────────────────

-- ── Perfiles: la tabla de la puerta ─────────────────────────────────
create table public.perfiles (
    id             uuid primary key references auth.users(id) on delete cascade,
    -- Duplicado de auth.users para que el panel de administración pueda
    -- listarlo sin permisos sobre el esquema `auth`.
    email          text not null,
    nombre         text,
    rol            text not null default 'usuario' check (rol in ('usuario', 'admin')),
    estado         text not null default 'pendiente'
                   check (estado in ('pendiente', 'aprobado', 'rechazado', 'suspendido')),
    -- Obligatorio al rechazar o suspender. Lo valida el RPC, no la tabla:
    -- al volver a aprobar se limpia, y un CHECK lo complicaría sin ganar nada.
    motivo_estado  text,
    aprobado_por   uuid references public.perfiles(id) on delete set null,
    aprobado_en    timestamptz,
    creado_en      timestamptz not null default now()
);

create index perfiles_estado_idx on public.perfiles (estado, creado_en);

comment on table public.perfiles is
  'Extiende auth.users. estado = aprobado es la única llave de lectura de datos (ver es_usuario_aprobado()).';

-- ── Auditoría de acciones de administración ─────────────────────────
create table public.auditoria_admin (
    id             bigserial primary key,
    actor_id       uuid references public.perfiles(id) on delete set null,
    accion         text not null check (accion in (
                       'aprobar_usuario', 'rechazar_usuario', 'suspender_usuario',
                       'revertir_fase', 'resolver_backlog', 'reiniciar_agente')),
    objetivo_tipo  text not null,
    objetivo_id    text not null,
    detalle        jsonb,
    creado_en      timestamptz not null default now()
);

create index auditoria_admin_recientes_idx on public.auditoria_admin (creado_en desc);

-- ── Carteras (el esqueleto; su gestión llega en el Sprint 4, H-17) ──
-- Se crea ahora porque aprobar a un usuario le crea su cartera de
-- seguimiento (H-15). Solo lo imprescindible.
create table public.carteras (
    id                 bigserial primary key,
    usuario_id         uuid not null references public.perfiles(id) on delete cascade,
    nombre             text not null,
    tipo               text not null default 'seguimiento' check (tipo in ('seguimiento', 'simulador')),
    es_predeterminada  boolean not null default false,
    creado_en          timestamptz not null default now()
);

-- Una sola predeterminada por usuario y tipo.
create unique index carteras_una_predeterminada_idx
  on public.carteras (usuario_id, tipo) where es_predeterminada;

-- ── Funciones de la puerta ──────────────────────────────────────────
-- SECURITY DEFINER: tienen que poder leer `perfiles` aunque la política
-- de `perfiles` aún no haya concedido nada (si no, recursión de
-- políticas). STABLE: se evalúan una vez por consulta, no por fila.
-- search_path fijo: sin él, una SECURITY DEFINER es un vector de
-- escalada de privilegios de manual (lo exige la invariante I9).
create function public.es_usuario_aprobado()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.perfiles
         where id = auth.uid() and estado = 'aprobado'
    );
$$;

create function public.es_admin()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
    select exists (
        select 1 from public.perfiles
         where id = auth.uid() and estado = 'aprobado' and rol = 'admin'
    );
$$;

-- ── Alta automática del perfil y promoción del admin inicial ────────
-- El correo del administrador inicial vive en UNA función para que
-- cambiarlo sea una migración de una línea.
create function public.fn_email_admin_inicial()
returns text
language sql
immutable
as $$ select 'ramirezgda@gmail.com'::text $$;

-- Al registrarse: perfil `pendiente` / `usuario`, siempre.
create function public.fn_alta_perfil()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    insert into public.perfiles (id, email)
    values (new.id, coalesce(new.email, ''))
    on conflict (id) do nothing;
    return new;
end;
$$;

-- Al confirmar el correo: si es el del admin inicial y todavía no hay
-- ningún admin, se promueve. «Todavía no hay ninguno» impide que esto
-- se convierta en una puerta trasera permanente: una vez existe un
-- admin, las promociones pasan por el panel y quedan auditadas.
create function public.fn_promover_admin_inicial()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    -- Los dos triggers son AFTER INSERT y PostgreSQL los dispara por orden
    -- alfabético: este puede correr antes que el alta. Se asegura el perfil.
    insert into public.perfiles (id, email)
    values (new.id, coalesce(new.email, ''))
    on conflict (id) do nothing;

    if new.email_confirmed_at is not null
       and lower(new.email) = lower(public.fn_email_admin_inicial())
       and not exists (select 1 from public.perfiles where rol = 'admin')
    then
        update public.perfiles
           set rol = 'admin', estado = 'aprobado',
               aprobado_en = now(), motivo_estado = null
         where id = new.id;

        insert into public.carteras (usuario_id, nombre, tipo, es_predeterminada)
        select new.id, 'Seguimiento', 'seguimiento', true
         where not exists (select 1 from public.carteras
                            where usuario_id = new.id and tipo = 'seguimiento');
    end if;
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.fn_alta_perfil();

-- Se evalúa en el alta (por si el correo llega ya confirmado, como al
-- crear un usuario desde el panel de Supabase) y en cada confirmación.
create trigger on_auth_user_confirmado
    after insert or update of email_confirmed_at on auth.users
    for each row execute function public.fn_promover_admin_inicial();

-- Usuarios que existieran ya en auth.users antes de esta migración.
insert into public.perfiles (id, email)
select id, coalesce(email, '') from auth.users
on conflict (id) do nothing;

update public.perfiles p
   set rol = 'admin', estado = 'aprobado', aprobado_en = now()
  from auth.users u
 where u.id = p.id
   and u.email_confirmed_at is not null
   and lower(u.email) = lower(public.fn_email_admin_inicial())
   and not exists (select 1 from public.perfiles where rol = 'admin');

insert into public.carteras (usuario_id, nombre, tipo, es_predeterminada)
select p.id, 'Seguimiento', 'seguimiento', true
  from public.perfiles p
 where p.estado = 'aprobado'
   and not exists (select 1 from public.carteras c where c.usuario_id = p.id);

-- ── RPC de administración (H-15) ────────────────────────────────────
-- Única vía de cambiar el estado de un usuario. Todas exigen es_admin()
-- DENTRO de la función: la guardia de la ruta /admin en el cliente es
-- comodidad, esta es la seguridad.
create function public.rpc_aprobar_usuario(p_usuario uuid)
returns public.perfiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_perfil public.perfiles;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador aprobado puede aprobar usuarios'
              using errcode = '42501';
    end if;

    update public.perfiles
       set estado = 'aprobado', motivo_estado = null,
           aprobado_por = auth.uid(), aprobado_en = now()
     where id = p_usuario
    returning * into v_perfil;

    if not found then
        raise exception 'No existe el usuario %', p_usuario using errcode = 'P0002';
    end if;

    insert into public.carteras (usuario_id, nombre, tipo, es_predeterminada)
    select p_usuario, 'Seguimiento', 'seguimiento', true
     where not exists (select 1 from public.carteras
                        where usuario_id = p_usuario and tipo = 'seguimiento');

    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), 'aprobar_usuario', 'perfil', p_usuario::text,
            jsonb_build_object('email', v_perfil.email));

    insert into public.eventos_sistema (usuario_id, tipo, mensaje, datos)
    values (p_usuario, 'sys', 'Tu acceso ha sido aprobado.',
            jsonb_build_object('estado', 'aprobado'));

    return v_perfil;
end;
$$;

-- Rechazar y suspender comparten todo menos el estado destino.
create function public.fn_cambiar_estado_usuario(
    p_usuario uuid, p_estado text, p_motivo text, p_accion text)
returns public.perfiles
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_perfil public.perfiles;
begin
    if not public.es_admin() then
        raise exception 'Solo un administrador aprobado puede cambiar el estado de un usuario'
              using errcode = '42501';
    end if;
    if nullif(btrim(coalesce(p_motivo, '')), '') is null then
        raise exception 'El motivo es obligatorio' using errcode = '22023';
    end if;
    -- Un admin que se suspende a sí mismo deja el sistema sin nadie que
    -- pueda deshacerlo.
    if p_usuario = auth.uid() then
        raise exception 'Un administrador no puede cambiar su propio estado'
              using errcode = '42501';
    end if;

    -- Suspender NO borra nada: posiciones, carteras y órdenes se quedan.
    -- Solo se cierra la puerta de lectura.
    update public.perfiles
       set estado = p_estado, motivo_estado = btrim(p_motivo)
     where id = p_usuario
    returning * into v_perfil;

    if not found then
        raise exception 'No existe el usuario %', p_usuario using errcode = 'P0002';
    end if;

    insert into public.auditoria_admin (actor_id, accion, objetivo_tipo, objetivo_id, detalle)
    values (auth.uid(), p_accion, 'perfil', p_usuario::text,
            jsonb_build_object('email', v_perfil.email, 'motivo', btrim(p_motivo)));

    return v_perfil;
end;
$$;

create function public.rpc_rechazar_usuario(p_usuario uuid, p_motivo text)
returns public.perfiles
language sql
security definer
set search_path = public, pg_temp
as $$ select public.fn_cambiar_estado_usuario(p_usuario, 'rechazado', p_motivo, 'rechazar_usuario') $$;

create function public.rpc_suspender_usuario(p_usuario uuid, p_motivo text)
returns public.perfiles
language sql
security definer
set search_path = public, pg_temp
as $$ select public.fn_cambiar_estado_usuario(p_usuario, 'suspendido', p_motivo, 'suspender_usuario') $$;

-- Las funciones son ejecutables por PUBLIC por defecto en PostgreSQL.
revoke execute on function public.fn_cambiar_estado_usuario(uuid, text, text, text) from public;
revoke execute on function public.fn_alta_perfil() from public;
revoke execute on function public.fn_promover_admin_inicial() from public;
revoke execute on function public.rpc_aprobar_usuario(uuid) from public;
revoke execute on function public.rpc_rechazar_usuario(uuid, text) from public;
revoke execute on function public.rpc_suspender_usuario(uuid, text) from public;
grant execute on function public.rpc_aprobar_usuario(uuid) to authenticated;
grant execute on function public.rpc_rechazar_usuario(uuid, text) to authenticated;
grant execute on function public.rpc_suspender_usuario(uuid, text) to authenticated;

-- ── RLS: activar en las tablas nuevas ───────────────────────────────
alter table public.perfiles         enable row level security;
alter table public.auditoria_admin  enable row level security;
alter table public.carteras         enable row level security;

-- ── Retirar la lectura pública temporal (0005) ──────────────────────
-- Decisión del dueño del 2026-09-21: el escáner se veía sin login hasta
-- este sprint. Aquí caduca, como estaba escrito.
drop policy activos_lectura_publica_temporal_h14     on public.activos;
drop policy senales_lectura_publica_temporal_h14     on public.senales;
drop policy precios_lectura_publica_temporal_h14     on public.precios_diarios;
drop policy indicadores_lectura_publica_temporal_h14 on public.indicadores_diarios;

-- ── Políticas según la matriz del doc 01 §6.2 ───────────────────────
-- Todas `to authenticated`. Una política sin `to` se aplica a PUBLIC, que
-- incluye a `anon`: la invariante I14 lo impide.

-- Perfiles: cada uno ve el suyo en cualquier estado (el pendiente
-- necesita leer su estado para saber qué pantalla ver); el admin, todos.
create policy perfiles_select_propio on public.perfiles
    for select to authenticated using (id = auth.uid());
create policy perfiles_select_admin on public.perfiles
    for select to authenticated using (public.es_admin());
-- El usuario solo cambia su nombre. La columna la limita el GRANT de
-- abajo; la fila, esta política. Rol y estado solo cambian por RPC.
create policy perfiles_update_nombre on public.perfiles
    for update to authenticated
    using (id = auth.uid()) with check (id = auth.uid());

-- Datos de mercado: solo aprobados.
create policy activos_select_aprobados on public.activos
    for select to authenticated using (public.es_usuario_aprobado());
create policy senales_select_aprobados on public.senales
    for select to authenticated using (public.es_usuario_aprobado());
create policy precios_select_aprobados on public.precios_diarios
    for select to authenticated using (public.es_usuario_aprobado());
create policy indicadores_select_aprobados on public.indicadores_diarios
    for select to authenticated using (public.es_usuario_aprobado());

-- Eventos: los del sistema (sin usuario) para aprobados; los propios,
-- siempre — así un pendiente puede recibir el aviso de su aprobación.
create policy eventos_select on public.eventos_sistema
    for select to authenticated
    using (usuario_id = auth.uid()
           or (usuario_id is null and public.es_usuario_aprobado())
           or public.es_admin());

-- Carteras y datos de cartera: lo propio, y solo estando aprobado.
create policy carteras_propias on public.carteras
    for all to authenticated
    using (usuario_id = auth.uid() and public.es_usuario_aprobado())
    with check (usuario_id = auth.uid() and public.es_usuario_aprobado());
create policy carteras_select_admin on public.carteras
    for select to authenticated using (public.es_admin());

-- Auditoría: solo lectura, solo admin. Se escribe desde los RPC.
create policy auditoria_select_admin on public.auditoria_admin
    for select to authenticated using (public.es_admin());

-- ── Privilegios de tabla ────────────────────────────────────────────
-- Defensa en profundidad: además de no tener políticas, `anon` pierde
-- los privilegios que Supabase concede por defecto sobre public. Si un
-- día alguien añade por error una política `to public`, la tabla sigue
-- cerrada para quien no ha iniciado sesión.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;

-- Perfiles y auditoría: sin escritura directa desde el cliente.
revoke insert, update, delete on public.perfiles        from authenticated;
revoke insert, update, delete on public.auditoria_admin from authenticated;
grant  update (nombre)        on public.perfiles        to authenticated;
-- Catálogo de mercado y eventos: los escribe el ETL (service_role).
revoke insert, update, delete on public.activos, public.senales,
       public.precios_diarios, public.indicadores_diarios,
       public.eventos_sistema from authenticated;
