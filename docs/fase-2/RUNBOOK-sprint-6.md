# Runbook del Sprint 6 — poner en marcha a los agentes

> Para Daniel. Se hace **una vez**, después de fusionar el PR del Sprint 6
> y de aplicar la migración 0013 con `scripts\aplicar-migraciones.cmd`.

Aplicar la 0013 crea a Prudencia, Cadencia y Audacia con sus cuentas de
500 $ **en pausa** (decisión D13): hasta que no los pongas en marcha, no
abren nada. Programa además dos trabajos de `pg_cron` y publica
`eventos_sistema` en Realtime.

## 1. Comprobar que la migración dejó todo programado (SQL Editor)

```sql
select jobname, schedule, active from cron.job
 where jobname in ('monitor-ordenes', 'ciclo-agentes', 'corte-semanal');
```

Tienen que salir tres filas activas: `* * * * *`, `*/5 * * * *` y
`7 0 * * 1`.

```sql
select tablename from pg_publication_tables
 where pubname = 'supabase_realtime' and tablename = 'eventos_sistema';
```

Una fila. Si sale vacía, Realtime no está activado en el proyecto:
actívalo en *Database → Replication* y vuelve a lanzar el bloque `$rt$`
del final de la 0013.

## 2. Ponerlos en marcha (desde `/admin`)

Panel **Agentes** → *Poner en marcha*, uno a uno. Cada pulsación queda en
la auditoría. Prudencia solo opera acciones: en fin de semana o antes de
las 15:30 (hora peninsular) no verás que haga nada, y es lo correcto.

## 3. Comprobarlo (lo hace Claude)

- En 5 minutos, `/agentes` muestra «hace N min» en la última decisión de
  cada tarjeta, y el registro de eventos del escáner dice «en vivo».
- La primera orden de un agente aparece en la tabla sin recargar, y al
  desplegarla se lee por qué la eligió.
- El lunes siguiente, tras las 00:07 UTC, cada tarjeta enseña su primer
  veredicto semanal.

## Si algo se tuerce

- **Pausar**: `/admin` → *Pausar*. El día en curso deja de contar para el
  corte, así que pausar no penaliza al agente.
- **Game Over**: no se revierte. `/admin` → *Reiniciar* crea una cuenta
  nueva de 500 $ y conserva la anterior entera; el agente vuelve en pausa.
- **`pg_cron` parado**: el ciclo y el corte se pueden lanzar a mano con la
  clave de servicio: `select public.fn_ciclo_agentes();` y
  `select public.fn_corte_semanal();`.
- **La CSP nueva bloquea algo**: la consola del navegador dice qué
  dominio. La política está en `vercel.json`; solo admite el propio
  origen, Google Fonts y `*.supabase.co`.
