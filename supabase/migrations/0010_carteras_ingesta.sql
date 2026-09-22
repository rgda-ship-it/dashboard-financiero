-- ─────────────────────────────────────────────────────────────────────
-- 0010 — Sprint 4: carteras por usuario, cuotas, altas de activos y
--        posiciones importadas por CSV.  H-17 · H-18 · H-19 · H-20 · H-21
--
-- DECISIONES DEL DUEÑO (2026-09-22)
--   · Sin Edge Functions. Todo vive en la base de datos y en el workflow
--     de GitHub que ya existía. El navegador llama a RPC; la BD valida,
--     aplica cuotas y, si hace falta, pide a GitHub que ejecute el alta.
--   · D7 firmada: 25 activos por usuario (el admin no tiene ese tope),
--     150 activos DISTINTOS en seguimiento, 20 criptos distintas.
--   · Un usuario nuevo empieza con la cartera VACÍA. El admin conserva
--     los 24 activos de la Fase 1.
--
-- LA IDEA QUE ORDENA LAS CUOTAS: el catálogo es común. Si dos usuarios
-- siguen NVDA, el ETL la descarga una vez. El coste (cuota de CoinGecko,
-- minutos de Actions) crece con los activos DISTINTOS que alguien sigue,
-- no con los usuarios. Por eso:
--   · `activos.seguidores` cuenta cuántas carteras siguen cada activo, y
--     el ETL solo refresca los que tienen al menos uno;
--   · los topes globales cuentan activos con seguidores > 0: dejar de
--     seguir el último libera el hueco (su histórico se conserva).
-- ─────────────────────────────────────────────────────────────────────

-- ── Reconciliación previa: `posiciones_reales` en producción ─────────
-- DERIVA DETECTADA AL APLICAR ESTA MIGRACIÓN (2026-09-22): en producción
-- la tabla conservaba las columnas cifradas de la Fase 1
-- (`precio_compra_cifrado`, `monto_cifrado` como texto). 0000 se aplicó
-- ANTES de firmar D3 y el fichero se editó después; como usa `create
-- table if not exists`, la versión corregida nunca llegó a producción. La
-- CI no lo vio porque siempre parte de una base limpia.
--
-- Se corrige aquí, de forma idempotente: si las columnas viejas existen,
-- se sustituyen por las de D3. Solo si la tabla está VACÍA (lo estaba: 0
-- filas); con datos, se aborta en vez de perder nada.
-- Lección registrada: una migración aplicada no se edita nunca; se añade
-- otra.
do $reconciliar$
begin
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'posiciones_reales'
                  and column_name = 'precio_compra_cifrado') then
        if exists (select 1 from public.posiciones_reales) then
            raise exception 'posiciones_reales tiene filas con importes cifrados: migración manual necesaria';
        end if;
        alter table public.posiciones_reales
            drop column precio_compra_cifrado,
            drop column monto_cifrado,
            add column precio_compra numeric(20, 8) not null check (precio_compra > 0),
            add column monto numeric(20, 2) not null check (monto >= 0);
    end if;
end
$reconciliar$;

comment on column public.posiciones_reales.monto is
  'Importe FICTICIO. Si alguna vez fuera a contener una cifra real de patrimonio, hay que revisar la decisión D3 antes de cargarla.';

-- ── Parámetros de cuota (D7) en un solo sitio ───────────────────────
create function public.fn_cuotas(out por_usuario int, out globales int, out cripto int)
language sql immutable
as $$ select 25, 150, 20 $$;

-- ── Seguidores por activo ───────────────────────────────────────────
alter table public.activos
    add column seguidores int not null default 0 check (seguidores >= 0);

comment on column public.activos.seguidores is
  'Carteras que siguen el activo. Mantenido por trigger. El ETL solo refresca activos con seguidores > 0 y las cuotas globales cuentan esos.';

-- ── Cartera ⇄ activos ───────────────────────────────────────────────
create table public.cartera_activos (
    cartera_id  bigint not null references public.carteras(id) on delete cascade,
    activo_id   bigint not null references public.activos(id) on delete cascade,
    anadido_en  timestamptz not null default now(),
    notas       text,
    primary key (cartera_id, activo_id)
);

create index cartera_activos_activo_idx on public.cartera_activos (activo_id);

create function public.fn_contar_seguidores()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    if tg_op = 'INSERT' then
        update public.activos set seguidores = seguidores + 1 where id = new.activo_id;
    else
        update public.activos set seguidores = greatest(seguidores - 1, 0) where id = old.activo_id;
    end if;
    return null;
end;
$$;

create trigger cartera_activos_seguidores
    after insert or delete on public.cartera_activos
    for each row execute function public.fn_contar_seguidores();

-- ── Cuotas (H-18) ───────────────────────────────────────────────────
-- Se comprueban en un TRIGGER, no en la interfaz ni en un RPC: así rigen
-- por cualquier vía de entrada, incluida la del ETL cuando da de alta un
-- activo pedido por un usuario. El candado consultivo serializa las
-- altas concurrentes para que dos inserciones a la vez no se cuelen por
-- el mismo último hueco.
create function public.fn_verificar_cuota(p_usuario uuid, p_activo_id bigint, p_clase text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_cuota      record;
    v_propios    int;
    v_globales   int;
    v_cripto     int;
    v_ya_seguido boolean;
    v_es_admin   boolean;
begin
    select * into v_cuota from public.fn_cuotas();
    perform pg_advisory_xact_lock(hashtext('cuota_activos'));

    select rol = 'admin' into v_es_admin from public.perfiles where id = p_usuario;

    if not coalesce(v_es_admin, false) then
        select count(distinct ca.activo_id) into v_propios
          from public.cartera_activos ca
          join public.carteras c on c.id = ca.cartera_id
         where c.usuario_id = p_usuario;
        if v_propios >= v_cuota.por_usuario then
            raise exception 'Tu cartera ya sigue % activos y el límite es %. Quita alguno para añadir otro.',
                  v_propios, v_cuota.por_usuario
                  using errcode = 'P0001', hint = 'cuota_usuario';
        end if;
    end if;

    -- Seguir un activo que ya sigue otra persona no cuesta nada: no ocupa
    -- hueco global.
    select coalesce(seguidores, 0) > 0 into v_ya_seguido
      from public.activos where id = p_activo_id;
    if coalesce(v_ya_seguido, false) then
        return;
    end if;

    select count(*), count(*) filter (where clase = 'cripto')
      into v_globales, v_cripto
      from public.activos where seguidores > 0;

    if v_globales >= v_cuota.globales then
        raise exception 'El sistema ya sigue % activos distintos y el límite global es %. Puedes añadir cualquiera de los que ya están en el catálogo.',
              v_globales, v_cuota.globales
              using errcode = 'P0001', hint = 'cuota_global';
    end if;
    if p_clase = 'cripto' and v_cripto >= v_cuota.cripto then
        raise exception 'El sistema ya sigue % criptomonedas distintas y el límite es % (cuota gratuita de CoinGecko). Puedes añadir cualquiera de las que ya están en el catálogo.',
              v_cripto, v_cuota.cripto
              using errcode = 'P0001', hint = 'cuota_cripto';
    end if;
end;
$$;

create function public.fn_cuota_al_seguir()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    perform public.fn_verificar_cuota(
        (select usuario_id from public.carteras where id = new.cartera_id),
        new.activo_id,
        (select clase from public.activos where id = new.activo_id));
    return new;
end;
$$;

create trigger cartera_activos_cuota
    before insert on public.cartera_activos
    for each row execute function public.fn_cuota_al_seguir();

-- ── Seguir / dejar de seguir ────────────────────────────────────────
-- Cartera de seguimiento predeterminada del usuario; la crea si falta.
create function public.fn_cartera_de(p_usuario uuid)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_id bigint;
begin
    select id into v_id from public.carteras
     where usuario_id = p_usuario and tipo = 'seguimiento'
     order by es_predeterminada desc, id limit 1;
    if v_id is null then
        insert into public.carteras (usuario_id, nombre, tipo, es_predeterminada)
        values (p_usuario, 'Seguimiento', 'seguimiento', true)
        returning id into v_id;
    end if;
    return v_id;
end;
$$;

create function public.fn_seguir(p_usuario uuid, p_activo_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
    insert into public.cartera_activos (cartera_id, activo_id)
    values (public.fn_cartera_de(p_usuario), p_activo_id)
    on conflict do nothing;
end;
$$;

-- Los 24 activos de la Fase 1 pasan a ser la cartera del admin (H-17).
-- Los usuarios nuevos empiezan vacíos (decisión del dueño).
select public.fn_seguir(p.id, a.id)
  from public.perfiles p
  cross join public.activos a
 where p.rol = 'admin' and p.estado = 'aprobado'
   and a.estado <> 'invalido';

-- ── Catálogo de CoinGecko (H-19) ────────────────────────────────────
-- Copia local de /coins/list, refrescada cada semana por el workflow
-- keep-alive (una sola llamada). Resuelve criptos SIN gastar cuota y
-- rechaza al instante una que no existe.
create table public.catalogo_coingecko (
    id              text primary key,
    simbolo         text not null,
    nombre          text not null,
    actualizado_en  timestamptz not null default now()
);

create index catalogo_coingecko_simbolo_idx on public.catalogo_coingecko (lower(simbolo));

-- Las tres criptos de la Fase 1: el catálogo nunca está vacío del todo,
-- aunque el primer refresco aún no haya corrido.
insert into public.catalogo_coingecko (id, simbolo, nombre) values
    ('bitcoin', 'btc', 'Bitcoin'),
    ('ethereum', 'eth', 'Ethereum'),
    ('solana', 'sol', 'Solana')
on conflict (id) do nothing;

-- ── Solicitudes de alta de acciones (H-19 / H-20) ───────────────────
-- Una acción no se puede validar desde la BD (no hay lista de Yahoo que
-- copiar). Queda como solicitud y la valida el workflow de altas con una
-- sola descarga, que es a la vez el backfill. Un símbolo que Yahoo no
-- reconoce NO llega a crear fila en `activos`.
create table public.solicitudes_activo (
    id              bigserial primary key,
    usuario_id      uuid not null references public.perfiles(id) on delete cascade,
    simbolo         text not null,
    estado          text not null default 'pendiente'
                    check (estado in ('pendiente', 'procesando', 'resuelta', 'rechazada', 'error')),
    mensaje         text,
    activo_id       bigint references public.activos(id) on delete set null,
    creado_en       timestamptz not null default now(),
    actualizado_en  timestamptz not null default now()
);

-- Un usuario no puede tener dos solicitudes vivas del mismo símbolo.
create unique index solicitudes_activo_viva_idx
    on public.solicitudes_activo (usuario_id, simbolo)
    where estado in ('pendiente', 'procesando');
create index solicitudes_activo_pendientes_idx
    on public.solicitudes_activo (estado, creado_en);

-- ── Disparo del workflow de altas ───────────────────────────────────
-- pg_net hace la petición a la API de GitHub de forma asíncrona, con un
-- token de alcance mínimo (Actions: write sobre este repositorio) que
-- vive en Supabase Vault con el nombre `github_pat_altas`, nunca en el
-- código. Si el token no está, no pasa nada grave: el ETL de cripto
-- procesa las altas pendientes en su pasada horaria.
create table public.control_despachos (
    clave   text primary key,
    ultimo  timestamptz not null
);

create function public.fn_disparar_altas()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_token text;
    v_ultimo timestamptz;
begin
    if to_regclass('vault.decrypted_secrets') is null
       or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
        return 'sin_infraestructura';
    end if;

    -- Un disparo cada 30 s basta: cada ejecución procesa TODAS las
    -- solicitudes pendientes, y GitHub encola una sola ejecución más.
    select ultimo into v_ultimo from public.control_despachos where clave = 'altas' for update;
    if v_ultimo is not null and v_ultimo > now() - interval '30 seconds' then
        return 'reciente';
    end if;

    execute $q$select decrypted_secret from vault.decrypted_secrets
               where name = 'github_pat_altas' limit 1$q$
       into v_token;
    if v_token is null then
        return 'sin_token';
    end if;

    execute $q$select net.http_post(
                 url     := 'https://api.github.com/repos/rgda-ship-it/dashboard-financiero/actions/workflows/altas.yml/dispatches',
                 body    := '{"ref":"master"}'::jsonb,
                 headers := jsonb_build_object(
                              'Authorization', 'Bearer ' || $1,
                              'Accept', 'application/vnd.github+json',
                              'X-GitHub-Api-Version', '2022-11-28',
                              'User-Agent', 'dashboard-financiero'),
                 timeout_milliseconds := 5000)$q$
      using v_token;

    insert into public.control_despachos (clave, ultimo) values ('altas', now())
    on conflict (clave) do update set ultimo = excluded.ultimo;
    return 'disparado';
end;
$$;

-- ── RPC para el navegador ───────────────────────────────────────────
create function public.fn_exigir_aprobado()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
    if not public.es_usuario_aprobado() then
        raise exception 'Tu cuenta no está aprobada' using errcode = '42501';
    end if;
    return auth.uid();
end;
$$;

-- Buscador: primero el catálogo (instantáneo, sin llamadas externas);
-- después criptos de CoinGecko que aún no están en el catálogo.
create function public.rpc_buscar_activo(p_consulta text)
returns table (
    origen     text,     -- 'catalogo' | 'coingecko'
    activo_id  bigint,
    simbolo    text,
    nombre     text,
    clase      text,
    estado     text,
    seguido    boolean,
    ticker     text      -- símbolo corto visible (BTC); para acciones = simbolo
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := public.fn_exigir_aprobado();
    v_q   text := lower(btrim(coalesce(p_consulta, '')));
begin
    if length(v_q) < 1 then
        return;
    end if;

    return query
    select 'catalogo'::text, a.id, a.simbolo, a.nombre, a.clase, a.estado,
           exists (select 1 from public.cartera_activos ca
                     join public.carteras c on c.id = ca.cartera_id
                    where c.usuario_id = v_uid and ca.activo_id = a.id),
           coalesce(upper(cg.simbolo), upper(a.simbolo))
      from public.activos a
      left join public.catalogo_coingecko cg on a.clase = 'cripto' and cg.id = a.id_proveedor
     where a.estado <> 'invalido'
       and (lower(a.simbolo) like v_q || '%'
            or lower(coalesce(a.nombre, '')) like '%' || v_q || '%'
            or lower(coalesce(cg.simbolo, '')) = v_q)
     order by (lower(a.simbolo) = v_q or lower(coalesce(cg.simbolo, '')) = v_q) desc, a.simbolo
     limit 8;

    return query
    select 'coingecko'::text, null::bigint, cg.id, cg.nombre, 'cripto'::text, null::text,
           false, upper(cg.simbolo)
      from public.catalogo_coingecko cg
     where not exists (select 1 from public.activos a
                        where a.clase = 'cripto' and a.id_proveedor = cg.id)
       and (lower(cg.simbolo) = v_q or cg.id like v_q || '%'
            or lower(cg.nombre) like v_q || '%')
     order by (lower(cg.simbolo) = v_q) desc, (cg.id = v_q) desc, length(cg.id), cg.id
     limit 8;
end;
$$;

create function public.rpc_seguir_activo(p_activo_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := public.fn_exigir_aprobado();
begin
    if not exists (select 1 from public.activos where id = p_activo_id and estado <> 'invalido') then
        raise exception 'Ese activo no existe en el catálogo' using errcode = 'P0002';
    end if;
    perform public.fn_seguir(v_uid, p_activo_id);
end;
$$;

-- Dejar de seguir NO borra el histórico: precios e indicadores son
-- globales y otro usuario puede estar usándolos.
create function public.rpc_dejar_activo(p_activo_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := public.fn_exigir_aprobado();
begin
    delete from public.cartera_activos ca
     using public.carteras c
     where c.id = ca.cartera_id and c.usuario_id = v_uid and ca.activo_id = p_activo_id;
end;
$$;

-- Alta de un activo que el catálogo no conoce.
--   cripto → se valida contra la copia de CoinGecko, al instante; si
--            existe se crea en `activos` como pendiente_backfill y se sigue.
--   acción → se valida el formato y queda como solicitud; el workflow
--            de altas la comprueba contra Yahoo en ~1-2 minutos.
create function public.rpc_solicitar_activo(p_clase text, p_identificador text)
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
    if p_clase = 'cripto' then
        v_simbolo := lower(btrim(p_identificador));
    elsif p_clase = 'accion' then
        v_simbolo := upper(btrim(p_identificador));
    else
        raise exception 'Clase de activo desconocida: %', p_clase using errcode = '22023';
    end if;

    -- ¿Ya está en el catálogo? Entonces solo hay que seguirlo.
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

    -- Acción: formato de Yahoo. Empieza por letra, dígito o ^ (índices);
    -- admite . - = (clases de acciones, futuros, divisas). Nada que un
    -- editor de hojas de cálculo pueda leer como fórmula.
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

-- ── Funciones del workflow de altas (solo service_role) ─────────────
-- Toma las solicitudes pendientes con FOR UPDATE SKIP LOCKED: dos
-- ejecuciones concurrentes nunca procesan la misma. Las que llevan más
-- de 15 minutos «procesando» se consideran huérfanas (un job cortado).
create function public.fn_tomar_solicitudes()
returns setof public.solicitudes_activo
language sql
security definer
set search_path = public, pg_temp
as $$
    update public.solicitudes_activo s
       set estado = 'procesando', actualizado_en = now()
     where s.id in (
            select id from public.solicitudes_activo
             where estado = 'pendiente'
                or (estado = 'procesando' and actualizado_en < now() - interval '15 minutes')
             order by creado_en
             limit 50
             for update skip locked)
    returning s.*;
$$;

-- Resultado de validar un símbolo contra Yahoo.
--   ok      → crea el activo (pendiente_backfill) y lo añade a la cartera
--             de cada solicitante; si a alguno no le cabe por cuota, su
--             solicitud queda en error con el mensaje de la cuota.
--   no ok   → todas las solicitudes de ese símbolo quedan rechazadas.
create function public.fn_resolver_alta(p_simbolo text, p_ok boolean, p_mensaje text, p_nombre text default null)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_activo_id bigint;
    v_sol record;
begin
    if not p_ok then
        update public.solicitudes_activo
           set estado = 'rechazada', mensaje = p_mensaje, actualizado_en = now()
         where simbolo = p_simbolo and estado = 'procesando';
        return null;
    end if;

    select id into v_activo_id from public.activos where simbolo = p_simbolo;
    if v_activo_id is null then
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, nombre, estado)
        values (p_simbolo, 'accion', 'yahoo', p_simbolo, p_nombre, 'pendiente_backfill')
        returning id into v_activo_id;
    end if;

    for v_sol in select * from public.solicitudes_activo
                  where simbolo = p_simbolo and estado = 'procesando'
    loop
        begin
            perform public.fn_seguir(v_sol.usuario_id, v_activo_id);
            update public.solicitudes_activo
               set estado = 'resuelta', activo_id = v_activo_id, mensaje = null,
                   actualizado_en = now()
             where id = v_sol.id;
        exception when raise_exception then
            update public.solicitudes_activo
               set estado = 'error', activo_id = v_activo_id, mensaje = sqlerrm,
                   actualizado_en = now()
             where id = v_sol.id;
        end;
    end loop;
    return v_activo_id;
end;
$$;

-- ── Posiciones importadas por CSV (H-21) ────────────────────────────
-- El navegador lee el fichero y envía SOLO filas en JSON: un binario
-- disfrazado de .csv nunca llega al servidor. Aquí se vuelve a validar
-- todo, porque el cliente no es de fiar. Las filas inválidas se excluyen
-- con su motivo y NUNCA rompen la importación (comportamiento Fase 1).
-- Importar REEMPLAZA las posiciones del usuario, como en la Fase 1.
create function public.rpc_importar_posiciones(p_filas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid        uuid := public.fn_exigir_aprobado();
    v_fila       jsonb;
    v_n          int := 0;
    v_ticker     text;
    v_precio     numeric;
    v_monto      numeric;
    v_activo_id  bigint;
    v_validas    jsonb := '[]'::jsonb;
    v_excluidas  jsonb := '[]'::jsonb;
    v_sin_cat    jsonb := '[]'::jsonb;
begin
    if jsonb_typeof(p_filas) <> 'array' then
        raise exception 'Se esperaba una lista de filas' using errcode = '22023';
    end if;
    if jsonb_array_length(p_filas) > 500 then
        raise exception 'Máximo 500 filas por importación' using errcode = '22023';
    end if;

    for v_fila in select * from jsonb_array_elements(p_filas)
    loop
        v_n := v_n + 1;
        v_ticker := btrim(coalesce(v_fila ->> 'ticker', ''));

        if v_ticker !~ '^[A-Za-z0-9^][A-Za-z0-9.=^-]{0,19}$' then
            v_excluidas := v_excluidas || jsonb_build_object(
                'fila', coalesce((v_fila ->> 'fila')::int, v_n),
                'motivo', 'ticker no válido (no puede empezar por = + - @ ni contener espacios)');
            continue;
        end if;

        begin
            v_precio := (v_fila ->> 'precio_compra')::numeric;
            v_monto  := (v_fila ->> 'monto')::numeric;
        exception when others then
            v_precio := null;
        end;
        if v_precio is null or v_monto is null or v_precio <= 0 or v_monto < 0
           or v_precio >= 1e12 or v_monto >= 1e18 then
            v_excluidas := v_excluidas || jsonb_build_object(
                'fila', coalesce((v_fila ->> 'fila')::int, v_n),
                'motivo', 'precio o monto no válidos (precio > 0, monto ≥ 0, decimal con punto)');
            continue;
        end if;

        -- Acciones en mayúsculas; cripto por su id de CoinGecko.
        select id into v_activo_id from public.activos
         where estado <> 'invalido'
           and (simbolo = upper(v_ticker)
                or (clase = 'cripto' and (simbolo = lower(v_ticker) or id_proveedor = lower(v_ticker))))
         limit 1;
        if v_activo_id is null then
            v_sin_cat := v_sin_cat || to_jsonb(upper(v_ticker));
        end if;

        v_validas := v_validas || jsonb_build_object(
            'ticker', upper(v_ticker), 'activo_id', v_activo_id,
            'precio_compra', v_precio, 'monto', v_monto);
    end loop;

    if jsonb_array_length(v_validas) = 0 then
        return jsonb_build_object('importadas', 0, 'excluidas', v_excluidas,
                                  'sin_catalogo', '[]'::jsonb);
    end if;

    delete from public.posiciones_reales where usuario_id = v_uid;
    insert into public.posiciones_reales (usuario_id, ticker, activo_id, precio_compra, monto)
    select v_uid, e ->> 'ticker', (e ->> 'activo_id')::bigint,
           (e ->> 'precio_compra')::numeric, (e ->> 'monto')::numeric
      from jsonb_array_elements(v_validas) e;

    -- Audit trail del DPO (Fase 1): importar es consentir que se guarden.
    insert into public.registro_consentimiento (usuario_id, tipo, otorgado)
    values (v_uid, 'persistencia_cartera', true);

    return jsonb_build_object(
        'importadas', jsonb_array_length(v_validas),
        'excluidas', v_excluidas,
        'sin_catalogo', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                           from jsonb_array_elements(v_sin_cat) x));
end;
$$;

create function public.rpc_borrar_posiciones()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_uid uuid := public.fn_exigir_aprobado();
begin
    delete from public.posiciones_reales where usuario_id = v_uid;
    insert into public.registro_consentimiento (usuario_id, tipo, otorgado)
    values (v_uid, 'persistencia_cartera', false);
end;
$$;

-- ── Vistas para el navegador (security_invoker: I13) ────────────────
-- El escáner muestra SOLO los activos de la cartera de quien consulta.
create view public.v_escaner_usuario
with (security_invoker = true) as
    select sv.*
      from public.senales_vigentes sv
     where exists (select 1
                     from public.cartera_activos ca
                     join public.carteras c on c.id = ca.cartera_id
                    where c.usuario_id = auth.uid()
                      and ca.activo_id = sv.activo_id);

create view public.v_mi_cartera
with (security_invoker = true) as
    select a.id as activo_id, a.simbolo, a.clase, a.nombre, a.estado,
           a.ultimo_precio, a.ultimo_precio_en, a.ultimo_etl_en,
           a.primer_backfill_en, a.ultimo_error, a.seguidores,
           upper(coalesce(cg.simbolo, a.simbolo)) as ticker,
           min(ca.anadido_en) as anadido_en
      from public.cartera_activos ca
      join public.carteras c on c.id = ca.cartera_id
      join public.activos a on a.id = ca.activo_id
      left join public.catalogo_coingecko cg on a.clase = 'cripto' and cg.id = a.id_proveedor
     where c.usuario_id = auth.uid()
     group by a.id, cg.simbolo;

create view public.v_mis_posiciones
with (security_invoker = true) as
    select p.id, p.ticker, p.activo_id, p.precio_compra, p.monto, p.creado_en,
           a.ultimo_precio as precio_actual, a.ultimo_precio_en, a.estado as estado_activo,
           case when a.ultimo_precio is not null
                then round((a.ultimo_precio - p.precio_compra) / p.precio_compra * 100, 2) end as pnl_pct,
           case when a.ultimo_precio is not null
                then round(p.monto * (a.ultimo_precio - p.precio_compra) / p.precio_compra, 2) end as pnl
      from public.posiciones_reales p
      left join public.activos a on a.id = p.activo_id
     where p.usuario_id = auth.uid();

-- ── RLS ─────────────────────────────────────────────────────────────
alter table public.cartera_activos     enable row level security;
alter table public.catalogo_coingecko  enable row level security;
alter table public.solicitudes_activo  enable row level security;
alter table public.control_despachos   enable row level security;

create policy cartera_activos_propios on public.cartera_activos
    for select to authenticated
    using (public.es_usuario_aprobado()
           and cartera_id in (select id from public.carteras where usuario_id = auth.uid()));
create policy cartera_activos_select_admin on public.cartera_activos
    for select to authenticated using (public.es_admin());

create policy catalogo_coingecko_aprobados on public.catalogo_coingecko
    for select to authenticated using (public.es_usuario_aprobado());

create policy solicitudes_propias on public.solicitudes_activo
    for select to authenticated
    using (usuario_id = auth.uid() and public.es_usuario_aprobado());
create policy solicitudes_select_admin on public.solicitudes_activo
    for select to authenticated using (public.es_admin());

-- Escritura: solo por RPC. Seguir pasa por rpc_seguir_activo (cuotas),
-- nunca por un INSERT directo.
revoke insert, update, delete on public.cartera_activos, public.catalogo_coingecko,
       public.solicitudes_activo, public.control_despachos from authenticated;
revoke all on public.control_despachos from authenticated;
-- Las posiciones se escriben por rpc_importar_posiciones (valida filas).
revoke insert, update on public.posiciones_reales from authenticated;
-- `seguidores` lo mantiene el trigger; nadie lo toca a mano.
revoke insert, update, delete on public.activos from authenticated;

-- ── Privilegios de ejecución ────────────────────────────────────────
-- rpc_* → authenticated. fn_* → nadie salvo el propietario, y
-- service_role en las dos que usa el workflow de altas (I22/I23).
revoke execute on function public.fn_cuotas()                                   from public, anon, authenticated;
revoke execute on function public.fn_contar_seguidores()                        from public, anon, authenticated;
revoke execute on function public.fn_verificar_cuota(uuid, bigint, text)        from public, anon, authenticated;
revoke execute on function public.fn_cuota_al_seguir()                          from public, anon, authenticated;
revoke execute on function public.fn_cartera_de(uuid)                           from public, anon, authenticated;
revoke execute on function public.fn_seguir(uuid, bigint)                       from public, anon, authenticated;
revoke execute on function public.fn_disparar_altas()                           from public, anon, authenticated;
revoke execute on function public.fn_exigir_aprobado()                          from public, anon, authenticated;
revoke execute on function public.fn_tomar_solicitudes()                        from public, anon, authenticated;
revoke execute on function public.fn_resolver_alta(text, boolean, text, text)   from public, anon, authenticated;
grant  execute on function public.fn_tomar_solicitudes()                        to service_role;
grant  execute on function public.fn_resolver_alta(text, boolean, text, text)   to service_role;

revoke execute on function public.rpc_buscar_activo(text)              from public, anon;
revoke execute on function public.rpc_seguir_activo(bigint)            from public, anon;
revoke execute on function public.rpc_dejar_activo(bigint)             from public, anon;
revoke execute on function public.rpc_solicitar_activo(text, text)     from public, anon;
revoke execute on function public.rpc_importar_posiciones(jsonb)       from public, anon;
revoke execute on function public.rpc_borrar_posiciones()              from public, anon;
grant  execute on function public.rpc_buscar_activo(text)              to authenticated;
grant  execute on function public.rpc_seguir_activo(bigint)            to authenticated;
grant  execute on function public.rpc_dejar_activo(bigint)             to authenticated;
grant  execute on function public.rpc_solicitar_activo(text, text)     to authenticated;
grant  execute on function public.rpc_importar_posiciones(jsonb)       to authenticated;
grant  execute on function public.rpc_borrar_posiciones()              to authenticated;
