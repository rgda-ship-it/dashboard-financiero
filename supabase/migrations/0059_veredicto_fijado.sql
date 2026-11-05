-- ─────────────────────────────────────────────────────────────────────
-- 0059 — El veredicto de cada agente, fijado de antemano
--        (doc fase-3/12 §3, recomendación 1; 2026-11-05).
--
-- Hasta hoy no había un protocolo escrito para juzgar a los agentes con
-- metas al final del experimento (2027-04-30), y la pantalla solo decía
-- «meta no cumplida». Aquí se fija, antes de mirar el resultado:
--
--   · `agente_veredicto_criterio`: una fila por agente con lo que espera
--     el laboratorio (expectativa y dispersión de la R con sus reglas de
--     hoy, a 10 años) y los umbrales. Se escribe una vez y no se puede
--     cambiar ni borrar (disparador): cambiar el criterio a mitad sería
--     mover la portería.
--   · `fn_vara(referencia, desde)`: comprar y mantener desde cualquier
--     fecha, con la regla de la 0056 (cada agente se compara desde su
--     propio comienzo).
--   · `v_veredicto_agentes`: el estado de cada agente con su criterio.
--
-- Umbrales (los mismos que Tendencia cripto, doc fase-2/07 §6, y el
-- laboratorio, doc fase-2/06 §3.5):
--
--   pocas_operaciones  menos de 30 cierres desde `desde`
--   pausar             la caída desde el máximo pasa del 35 %
--   retirar            expectativa negativa con 30 cierres o más
--   validado           expectativa ≥ +0,10 R, el intervalo del 90 % por
--                      encima de cero y más rentable que su vara
--   sin_ventaja        a los 60 cierres, sin validar
--   observar           todo lo demás
--
-- Y la concordancia con el laboratorio: si la expectativa en vivo cae
-- fuera de lo esperado (la del laboratorio ± 1,645 σ / √n), el agente
-- opera distinto de lo que se probó, y eso se revisa antes de concluir.
--
-- No cambia cómo operan los agentes: solo lee.
-- ─────────────────────────────────────────────────────────────────────

create table public.agente_veredicto_criterio (
    agente_id              bigint primary key references public.agentes (id),
    desde                  timestamptz not null,
    vara                   text not null
                           check (vara in ('universo', 'acciones', 'cripto', 'bitcoin', 'sp500', 'nasdaq100')),
    vara_desde             date not null,
    expectativa_lab_r      numeric(8, 4) not null,
    desviacion_lab_r       numeric(8, 4) not null,
    operaciones_lab        int not null,
    lab_periodo            text not null,
    operaciones_min        int not null default 30,
    operaciones_max        int not null default 60,
    expectativa_validar_r  numeric(8, 4) not null default 0.10,
    caida_max_pct          numeric(6, 2) not null default 35,
    notas                  text,
    fijado_en              timestamptz not null default now()
);

comment on table public.agente_veredicto_criterio is
  'El criterio con que se juzga a cada agente, fijado antes de ver su resultado (0059, doc fase-3/12 §3). No se cambia ni se borra.';

alter table public.agente_veredicto_criterio enable row level security;
create policy agente_veredicto_criterio_aprobados on public.agente_veredicto_criterio
    for select to authenticated using (public.es_usuario_aprobado());
revoke insert, update, delete on public.agente_veredicto_criterio from authenticated;
revoke all on public.agente_veredicto_criterio from anon;

create function public.fn_veredicto_criterio_fijo()
returns trigger
language plpgsql
as $$
begin
    raise exception 'El criterio del veredicto se fija una vez y no se cambia (0059): agente %', old.agente_id
          using errcode = 'P0001';
end
$$;

revoke execute on function public.fn_veredicto_criterio_fijo() from public, anon, authenticated;

create trigger agente_veredicto_criterio_fijo
    before update or delete on public.agente_veredicto_criterio
    for each row execute function public.fn_veredicto_criterio_fijo();

-- ── La vara desde cualquier fecha ────────────────────────────────────
create function public.fn_vara(p_referencia text, p_desde date)
returns numeric
language sql
stable
security invoker
as $$
    select round(avg(fin.cierre / ini.cierre - 1) * 100, 2)
      from public.activos a
      join lateral (select p.fecha, p.cierre from public.precios_diarios p
                     where p.activo_id = a.id and p.fecha >= p_desde
                     order by p.fecha limit 1) ini on true
      join lateral (select p.cierre from public.precios_diarios p
                     where p.activo_id = a.id
                     order by p.fecha desc limit 1) fin on true
     where a.estado = 'activo'
       and ini.fecha <= p_desde + 4 and ini.cierre > 0
       and case p_referencia
               when 'universo'  then not a.referencia
               when 'acciones'  then not a.referencia and a.clase = 'accion'
               when 'cripto'    then a.clase = 'cripto'
               when 'bitcoin'   then a.simbolo = 'bitcoin'
               when 'sp500'     then a.simbolo = '^GSPC'
               when 'nasdaq100' then a.simbolo = '^NDX'
               else false end
$$;

comment on function public.fn_vara(text, date) is
  'Comprar y mantener una referencia (0056, 0058) desde una fecha: el primer cierre en los 4 días siguientes y el último (0059).';

-- ── El veredicto de hoy ──────────────────────────────────────────────
create view public.v_veredicto_agentes
with (security_invoker = true) as
with ops as (
    select c.agente_id,
           (o.pnl_bruto + o.pnl_parciales)
             / nullif((o.cantidad + coalesce(p.cantidad, 0))
                      * (o.precio_entrada - coalesce(o.sl_original, o.sl)), 0) as r
      from public.ordenes o
      join public.cuentas_simulacion c on c.id = o.cuenta_id
      join public.agente_veredicto_criterio k on k.agente_id = c.agente_id
      left join lateral (select sum(x.cantidad) as cantidad
                           from public.ordenes_parciales x where x.orden_id = o.id) p on true
     where o.estado = 'cerrada'
       and c.id = public.fn_cuenta_agente(c.agente_id)
       and o.precio_entrada > coalesce(o.sl_original, o.sl)
       and o.fecha_entrada >= k.desde
), medida as (
    select k.agente_id, count(o.r) as n, avg(o.r) as e, stddev_samp(o.r) as s
      from public.agente_veredicto_criterio k
      left join ops o on o.agente_id = k.agente_id
     group by k.agente_id
), base as (
    select g.nombre, g.tipo, k.*,
           m.n as cerradas, m.e, m.s,
           m.e - 1.645 * m.s / sqrt(nullif(m.n, 0))::numeric as ic_inf,
           m.e + 1.645 * m.s / sqrt(nullif(m.n, 0))::numeric as ic_sup,
           round((ce.equity / nullif(ce.saldo_inicial, 0) - 1) * 100, 2) as rentabilidad_pct,
           public.fn_vara(k.vara, k.vara_desde) as vara_pct,
           ce.drawdown_pct
      from public.agente_veredicto_criterio k
      join public.agentes g on g.id = k.agente_id
      join medida m on m.agente_id = k.agente_id
      left join public.v_cuentas_equity ce on ce.id = public.fn_cuenta_agente(g.id)
)
select agente_id, nombre, tipo, desde, vara, vara_desde,
       expectativa_lab_r, desviacion_lab_r, operaciones_lab, lab_periodo,
       operaciones_min, operaciones_max, expectativa_validar_r, caida_max_pct, fijado_en,
       cerradas,
       round(e, 4) as expectativa_r,
       round(s, 4) as desviacion_r,
       round(ic_inf, 4) as ic90_inf,
       round(ic_sup, 4) as ic90_sup,
       rentabilidad_pct, vara_pct, drawdown_pct,
       -- Lo que el laboratorio espera con n cierres: su expectativa ± 1,645 σ / √n.
       case when cerradas >= 2 then
            abs(e - expectativa_lab_r) <= 1.645 * desviacion_lab_r / sqrt(cerradas) end as concuerda_lab,
       -- Cierres que hacen falta para que el intervalo deje de incluir el cero.
       case when cerradas >= 2 and e <> 0 and s is not null
            then ceil(power(1.645 * s / abs(e), 2))::int end as necesarias,
       case
           when drawdown_pct is not null and drawdown_pct <= -caida_max_pct then 'pausar'
           when cerradas < operaciones_min then 'pocas_operaciones'
           when e < 0 then 'retirar'
           when e >= expectativa_validar_r and ic_inf > 0 and rentabilidad_pct > vara_pct then 'validado'
           when cerradas >= operaciones_max then 'sin_ventaja'
           else 'observar'
       end as estado
  from base;

comment on view public.v_veredicto_agentes is
  'El estado de cada agente frente al criterio fijado de antemano (0059, doc fase-3/12 §3).';

grant select on public.v_veredicto_agentes to authenticated;
revoke execute on function public.fn_vara(text, date) from public, anon;
grant execute on function public.fn_vara(text, date) to authenticated;

do $lectura$
begin
    if exists (select 1 from pg_roles where rolname = 'analista_lectura') then
        grant select on public.agente_veredicto_criterio, public.v_veredicto_agentes to analista_lectura;
        grant execute on function public.fn_vara(text, date) to analista_lectura;
    end if;
end
$lectura$;

-- ── El criterio del grupo de control y de Tendencia cripto ───────────
-- Valores del laboratorio: velas diarias de Yahoo a 10 años
-- (2016-11-05 → 2026-11-05), universo de producción del 2026-11-05 sin
-- índices, la estrategia de cada agente tal como opera hoy. Todo el
-- periodo, no solo la validación: es lo que se espera en vivo.
-- (Se rellena abajo con el resultado del laboratorio.)
--
--   agente            expectativa   σ de la R   operaciones
--   Prudencia         −0,041 R      1,713       595
--   Cadencia          −0,154 R      2,060       273
--   Audacia           +0,064 R      1,440       594
--   Tendencia cripto  +0,913 R      4,107       507  (estrategia `tendencia`
--                                                      sin la cartera; el
--                                                      doc 07 §6 da +1,03 R
--                                                      con ella)
--
-- El grupo de control cuenta sus cierres desde el experimento (el alta
-- de Tendencia cripto, ya con las reglas de la 0030) y compara su
-- rentabilidad desde el alta con la vara desde el alta.
insert into public.agente_veredicto_criterio
       (agente_id, desde, vara, vara_desde, expectativa_lab_r, desviacion_lab_r, operaciones_lab, lab_periodo, notas)
select g.id,
       case when g.tipo = 'metas'
            then coalesce((select min(creado_en) from public.agentes where tipo = 'estrategia'), g.creado_en)
            else g.creado_en end,
       case when g.tipo = 'metas' then 'universo' else 'cripto' end,
       g.creado_en::date,
       v.e, v.s, v.n,
       'velas diarias, 2016-11-05 → 2026-11-05, universo de producción del 2026-11-05 sin índices',
       v.notas
  from public.agentes g
  join (values ('Prudencia', -0.041, 1.713, 595, 'Grupo de control (reglas de la versión 11)'),
               ('Cadencia', -0.154, 2.060, 273, 'Grupo de control (reglas de la versión 10)'),
               ('Audacia', 0.064, 1.440, 594, 'Grupo de control (reglas de la versión 9)'),
               ('Tendencia cripto', 0.913, 4.107, 507,
                'Su criterio de siempre (doc fase-2/07 §6), aquí con los mismos umbrales'))
       v(nombre, e, s, n, notas) on v.nombre = g.nombre;
