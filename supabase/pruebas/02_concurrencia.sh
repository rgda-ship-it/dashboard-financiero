#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Prueba de concurrencia de `rpc_cerrar_orden` — riesgo R4, CRÍTICO.
#
# POR QUÉ ESTO ES UN SCRIPT DE SHELL Y NO UNA INVARIANTE MÁS
#
# 01_invariantes.sql prueba la idempotencia EN SECUENCIA: llamar dos veces
# seguidas y comprobar que la segunda no toca el saldo. Eso es la mitad del
# contrato. La otra mitad es la carrera: dos pasadas del monitor entrando a
# la vez sobre la misma orden. Un script de `psql` es UNA sesión, y una
# sesión no puede competir consigo misma: el `FOR UPDATE` que protege de la
# carrera no se ejercita nunca. Hacen falta diez conexiones de verdad.
#
# Si esta prueba falla, el fallo no es cosmético: significa que un cierre
# concurrente acredita el P&L dos veces y que todos los saldos del
# experimento son ficción. Es el riesgo R4 del doc 00 y la razón por la que
# el plan de H-24 exige este test ANTES de escribir el RPC.
#
# Uso:  02_concurrencia.sh "postgresql://usuario@host:puerto/base"
#       (o con PGURL en el entorno)
# ─────────────────────────────────────────────────────────────────────
set -uo pipefail

URL="${1:-${PGURL:-}}"
if [ -z "$URL" ]; then
  echo "FALLO: hace falta la URL de la base (argumento 1 o \$PGURL)." >&2
  exit 2
fi

LLAMADAS="${LLAMADAS:-10}"
Q() { psql "$URL" -v ON_ERROR_STOP=1 -qtAX -c "$1"; }

echo "── Concurrencia de rpc_cerrar_orden (riesgo R4) ──"

# ── 1. Fixture ──────────────────────────────────────────────────────
# Cuenta de AGENTE: no necesita perfil ni usuario de auth, así que el
# fixture no depende de nada del gobierno. `agente_id` no tiene clave
# ajena hasta el Sprint 6 (H-27), y cuando la tenga habrá que sembrar un
# agente aquí.
#
# La orden se inserta a mano en vez de por `rpc_abrir_orden` a propósito:
# lo que se prueba es el CIERRE, y montar la apertura entera (cartera,
# señal fresca, cuotas) metería en esta prueba media docena de motivos de
# fallo que no tienen nada que ver con la carrera.
#
# Números: entrada 100, cantidad 2, margen 40, salida en TP 130.
# P&L esperado = 2 x (130 - 100) = +60. Saldo final = 1000 - 40 + 40 + 60.
IDS=$(Q "
do \$\$
declare v_cuenta bigint; v_activo bigint; v_orden bigint;
begin
    delete from public.ordenes
     where cuenta_id in (select id from public.cuentas_simulacion where agente_id = 990001);
    delete from public.cuentas_simulacion where agente_id = 990001;

    insert into public.cuentas_simulacion
        (agente_id, saldo_inicial, saldo_disponible, capital_maximo_alcanzado)
    values (990001, 1000, 1000, 1000) returning id into v_cuenta;

    select id into v_activo from public.activos where simbolo = 'bitcoin';
    if v_activo is null then
        insert into public.activos (simbolo, clase, proveedor, id_proveedor, estado)
        values ('zzconc', 'cripto', 'coingecko', 'zzconc', 'activo') returning id into v_activo;
    end if;

    insert into public.ordenes
        (cuenta_id, activo_id, origen, precio_entrada, fecha_entrada, cantidad,
         apalancamiento, margen_comprometido, tp, sl, precio_liquidacion)
    values (v_cuenta, v_activo, 'agente', 100, now(), 2, 5, 40, 130, 90, 80)
    returning id into v_orden;

    perform public.fn_registrar_movimiento(v_cuenta, v_orden, 'bloqueo_margen', -40, 40);

    raise notice 'ids %,%', v_cuenta, v_orden;
end \$\$;
" 2>&1 | sed -n 's/^NOTICE:  ids //p')

CUENTA="${IDS%%,*}"
ORDEN="${IDS##*,}"
if [ -z "$CUENTA" ] || [ -z "$ORDEN" ]; then
  echo "FALLO: no se pudo preparar el fixture (cuenta='$CUENTA' orden='$ORDEN')." >&2
  exit 1
fi
echo "  cuenta $CUENTA · orden $ORDEN · $LLAMADAS cierres simultáneos"

# ── 2. La carrera ───────────────────────────────────────────────────
# Las diez sesiones se citan a una hora concreta y esperan ahí con
# `pg_sleep`. Lanzarlas sin cita deja que la primera termine antes de que
# la última haya conectado, y entonces no habría carrera que probar: el
# test pasaría sin haber ejercitado el `FOR UPDATE`.
T0=$(Q "select (now() + interval '3 seconds')::text")
SALIDA=$(mktemp -d)

for i in $(seq 1 "$LLAMADAS"); do
  (
    psql "$URL" -qtAX \
      -c "select pg_sleep(greatest(0, extract(epoch from (timestamptz '$T0' - clock_timestamp()))))" \
      -c "select public.rpc_cerrar_orden($ORDEN, 130, 'tp', 131)" \
      > "$SALIDA/$i.txt" 2>&1
  ) &
done
wait

CERRADAS=$(grep -l '"cerrada": true' "$SALIDA"/*.txt 2>/dev/null | wc -l)
YA_CERRADAS=$(grep -l 'ya estaba en estado' "$SALIDA"/*.txt 2>/dev/null | wc -l)
ERRORES=$(grep -il 'error' "$SALIDA"/*.txt 2>/dev/null | wc -l)

echo "  respuestas: $CERRADAS cerraron · $YA_CERRADAS «ya cerrada» · $ERRORES con error"

# ── 3. Veredicto ────────────────────────────────────────────────────
FALLOS=0
reprobar() { echo "  FALLO: $1"; FALLOS=$((FALLOS + 1)); }

[ "$CERRADAS" = "1" ]  || reprobar "cerraron $CERRADAS llamadas, se esperaba exactamente 1"
[ "$YA_CERRADAS" = "$((LLAMADAS - 1))" ] || \
  reprobar "$YA_CERRADAS llamadas dijeron «ya cerrada», se esperaban $((LLAMADAS - 1))"
[ "$ERRORES" = "0" ] || {
  reprobar "$ERRORES llamadas devolvieron error"
  grep -il 'error' "$SALIDA"/*.txt | while read -r f; do echo "    --- $f"; cat "$f"; done
}

# El estado de la base es el juez de verdad: las respuestas podrían
# mentir, los apuntes no.
LEIDO=$(Q "
select (select count(*) from public.ordenes where id = $ORDEN and estado = 'cerrada')
    || '|' || (select count(*) from public.movimientos_saldo
                where orden_id = $ORDEN and tipo = 'resultado_operacion')
    || '|' || (select count(*) from public.movimientos_saldo
                where orden_id = $ORDEN and tipo = 'liberacion_margen')
    || '|' || (select saldo_disponible from public.cuentas_simulacion where id = $CUENTA)
    || '|' || (select saldo_bloqueado  from public.cuentas_simulacion where id = $CUENTA)
    || '|' || (select coalesce(pnl_bruto::text, 'nulo') from public.ordenes where id = $ORDEN)")

IFS='|' read -r ORDEN_CERRADA N_RESULTADO N_LIBERACION DISPONIBLE BLOQUEADO PNL <<< "$LEIDO"

[ "$ORDEN_CERRADA" = "1" ] || reprobar "la orden no quedó cerrada"
[ "$N_RESULTADO" = "1" ]   || reprobar "hay $N_RESULTADO apuntes de resultado_operacion, se esperaba 1"
[ "$N_LIBERACION" = "1" ]  || reprobar "hay $N_LIBERACION apuntes de liberacion_margen, se esperaba 1"
[ "$PNL" = "60.00" ]       || reprobar "el P&L registrado es $PNL, se esperaba 60.00"
[ "$DISPONIBLE" = "1060.00" ] || reprobar "el saldo disponible es $DISPONIBLE, se esperaba 1060.00"
[ "$BLOQUEADO" = "0.00" ]  || reprobar "el saldo bloqueado es $BLOQUEADO, se esperaba 0.00"

# Y el cuadre del doc 01 §5.2 para esta cuenta.
DESCUADRE=$(Q "
select count(*) from (
  select c.id
    from public.cuentas_simulacion c
    left join public.movimientos_saldo m on m.cuenta_id = c.id
   where c.id = $CUENTA
   group by c.id, c.saldo_disponible, c.saldo_inicial
  having abs(c.saldo_disponible - (c.saldo_inicial + coalesce(sum(m.importe) filter (
           where m.tipo <> 'deposito_inicial'), 0))) > 0.01) d")
[ "$DESCUADRE" = "0" ] || reprobar "el saldo no cuadra con el libro mayor"

rm -rf "$SALIDA"
psql "$URL" -qtAX -c "delete from public.ordenes where cuenta_id = $CUENTA" \
                  -c "delete from public.cuentas_simulacion where id = $CUENTA" > /dev/null 2>&1

if [ "$FALLOS" -gt 0 ]; then
  echo "── FALLO: la carrera de cierre NO es segura ($FALLOS comprobaciones en rojo) ──"
  exit 1
fi
echo "PASS  R4  $LLAMADAS cierres simultáneos: una sola orden cerrada, el P&L acreditado una vez, el saldo cuadra"
