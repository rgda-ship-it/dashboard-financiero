# Fase 3 — Diagnóstico del 2026-10-24 y plan

> **Vigencia (revisada el 2026-10-27)**: **Foto del 2026-10-24.** El diagnóstico describe el sistema de ese día; el plan (E1–E9) se sigue en [`../ESTADO.md`](../ESTADO.md).

> **Para qué sirve**: deja por escrito cómo se comportaba el sistema al
> cerrar la Fase 2, qué falla, qué se puede mejorar y en qué orden se
> hace. Es el punto de partida de la Fase 3.
> **Datos**: producción, del 2026-10-13 (los agentes con metas salen de la
> cuarentena) al 2026-10-24 a las 12:30 UTC, con `scripts/consultar.py`
> (rol `analista_lectura`, solo lectura) y el historial de GitHub Actions.

---

## 1. La situación en una página

- **El ETL lleva desde el viernes 23-10 a las 19:07 UTC sin lanzarse
  desde la base de datos.** GitHub responde `401 Bad credentials` a cada
  disparo: el token `github_pat_altas` de Vault ha caducado (un token
  *fine-grained* caduca a los 30 días si no se elige otra cosa). Solo
  corren los `schedule` de respaldo de GitHub, que son irregulares: dos
  pasadas de cripto en las últimas 12 horas, en vez de doce. Nadie lo vio,
  porque el sistema apuntaba «disparado» sin mirar la respuesta.
  **Hay que renovarlo antes del lunes 26 a las 13:30 UTC** (§4): sin él, el
  lunes no hay señales de acciones, y las tres posiciones de acciones de
  Audacia no reciben precio fresco (el monitor no evalúa una acción sin
  precio reciente).
- **Un fallo del simulador dejó a Cadencia un día sin decidir.** Del 19 al
  20-10, su ciclo falló 8 veces y el de Prudencia 2: la toma parcial
  intentaba cerrar el 50 % de una posición de **1 acción** de AMZN, y la
  excepción deshacía el ciclo entero (ni entradas, ni salidas por
  deterioro, ni rotaciones). Se arregla en la 0045.
- **El rol de solo lectura no veía 9 tablas y vistas**, entre ellas
  `v_comparativa_agentes` y `agente_decisiones_diarias`, y
  `scripts/revision_agentes.sql` no corría con él. Por eso las decisiones
  diarias de Tendencia cripto no se pudieron revisar. Se arregla en la 0045.
- **Los agentes, por lo demás, se comportan como se diseñaron.** La 0043
  funciona: menos salidas por deterioro en dos de los tres, y la espera de
  48 h tras un stop se respeta. Tendencia cripto no ha operado en 13 días;
  con un mercado cripto sin rupturas es lo esperado, pero hay que
  confirmarlo con sus decisiones (§2.5).

---

## 2. Diagnóstico

### 2.1 Lista de problemas

| # | Gravedad | Problema | Evidencia | Arreglo |
|---|---|---|---|---|
| P1 | 🔴 Crítica | Token de GitHub caducado: el ETL no se lanza | `net._http_response`: 401 «Bad credentials» en cada disparo desde el 23-10 19:07 UTC. GitHub: 11 de 14 pasadas de acciones el viernes, 19 de 24 de cripto, y ninguna `workflow_dispatch` desde entonces | 👤 Renovar el token (§4) |
| P2 | 🔴 Alta | El fallo de P1 es silencioso | `fn_disparar_workflow` lanza con pg_net (asíncrono) y apunta «disparado» sin leer la respuesta. `control_despachos` decía que todo iba bien | 0045: `fn_revisar_despachos` y panel de salud |
| P3 | 🔴 Alta | La toma parcial de 1 acción deshace el ciclo del agente | 10 eventos `fallo` del 19-10 13:40 al 20-10 14:40: «Con 1.00000000 acciones no se puede cerrar el 50 %…». Cadencia estuvo unas 24 h sin completar un ciclo | 0045: `fn_parcial_divisible` (I93) |
| P4 | 🟠 Media | El rol `analista_lectura` no lee 9 objetos y no ejecuta las funciones de las vistas | `permission denied` en `v_comparativa_agentes`, `v_agentes_estrategia`, `v_agentes_plan`, `v_spreads`, `v_huecos_activos`, `v_coste_spread`, `agente_decisiones_diarias`, `mercados`, `spreads_observados`; y en `fn_tope_fase`, `fn_mercado_abierto` y `fn_pnl_realizado_dia` desde otras 5 vistas | 0045: permisos y permisos por defecto (I95) |
| P5 | 🟠 Media | El dashboard no enseña la salud del sistema | La barra superior solo dice si el navegador recibe datos. Ni el admin ni nadie veía P1 ni P3 | 0045 y panel «Salud del sistema» en Administración |
| P6 | 🟡 Baja | El backlog sigue reabriendo «Ampliar el universo» | Rechazada en la 0044, vuelve el 19-10 (Audacia) y el 23-10 (Prudencia), con 58 ocurrencias. «Señales más frecuentes» (Cadencia, 37 ocurrencias) nunca se ha revisado | Revisión del backlog (E3) |
| P7 | 🟡 Baja | Entradas y salidas en bucle en el mismo activo | Prudencia sale de tron por deterioro el 22-10 a las 02:10, vuelve a entrar y sale otra vez a las 16:10 (pagando dos veces el spread). Audacia entra por cuarta vez en QFIN 48 h y 2 min después de su segundo stop | 👤 Decisión (§5): son reglas del grupo de control |

### 2.2 Resultados de los agentes con metas (13–24 oct)

Operaciones cerradas, separadas por la aplicación de la 0043 (17-10 13:30 UTC):

| Agente | Antes de la 0043 | Después de la 0043 | Saldo hoy* |
|---|---|---|---|
| Prudencia | 9 cierres, +0,44 R de media (4 objetivos, 4 deterioros, 1 stop) | 5 cierres, +0,17 R (1 objetivo, 4 deterioros) | 521,78 $ |
| Cadencia | 7 cierres, −0,05 R (2 objetivos, 3 deterioros, 2 stops) | 1 cierre, +1,35 R (objetivo) | 489,83 $ + 1 abierta |
| Audacia | 6 cierres, +0,08 R (2 objetivos, 2 deterioros, 2 stops) | 6 cierres, −0,49 R (4 stops, 2 rotaciones) | 415,22 $ con 4 abiertas |

\* Saldo disponible más bloqueado, sin el resultado de las posiciones abiertas.

Las cifras son pocas para juzgar nada: sirven para ver que el
comportamiento coincide con el diseño, no para medir ventaja.

### 2.3 Revisión de la 0043 (deterioro confirmado y espera tras el stop)

- **Salidas por deterioro**: 4 desde la 0043, las cuatro de Prudencia, a
  −0,29 R de media (−0,16 a −0,48 R). Antes eran 9 en cuatro días, en los
  tres agentes. Ninguna salió a la primera lectura.
- **Al menos una evitó un stop**: F salió a 11,97 el 21-10 y después bajó a
  11,48, por debajo de su stop (11,68).
- **Espera tras el stop**: se cumple. QFIN volvió a entrar 48 h y 2 min
  después del stop (P7).
- **Conclusión**: la 0043 hace lo que tenía que hacer. Sin cambios.

### 2.4 Infraestructura

- **ETL**: las pasadas que llegan a correr terminan bien (un fallo de cada
  14 algunos días). El problema es solo el disparo (P1).
- **Precios del monitor**: CoinGecko responde 200 cada minuto. Dos
  *timeouts* de 5 s el 24-10 (07:00 y 09:00), sin consecuencias.
- **Proveedores**: un corte de conexión con bitcoin el 21-10. Nada más.

### 2.5 Tendencia cripto

- Sin operaciones desde que empezó (12-10), con 500 $ intactos.
- La 0045 deja al rol de lectura ver `agente_decisiones_diarias`. Al
  aplicarla, hay que comprobar que cada día decide sobre las 14 criptos y
  con qué resultado (`sin_senal`, `sin_vela`, `sin_precio`). Desde el 23-10
  puede haber días con `sin_vela` por P1: no es un fallo del agente.

---

## 3. La Fase 3

### 3.1 Objetivo

La Fase 2 construyó el sistema y el experimento. La Fase 3 **lo mantiene
fiable mientras el experimento corre** (6–7 meses hasta el veredicto de
Tendencia cripto) y **prepara lo que se decidirá con ese veredicto**.

Principios:

1. **Un fallo tiene que verse el mismo día.** Todo lo que corre solo
   (ETL, ciclos, decisión diaria, corte semanal) deja rastro de si fue bien
   y el panel de salud lo enseña.
2. **El grupo de control no cambia de reglas.** Se arreglan fallos (como
   en la 0043 y en la 0045), no se cambian estrategias.
3. **Todo lo que Claude revisa, lo revisa solo.** El rol de lectura ve todo
   lo que hace falta para las revisiones periódicas.

### 3.2 Entregas

| Entrega | Qué | Estado |
|---|---|---|
| **E1 · Salud del sistema** | 0045: toma parcial que no rompe el ciclo (P3), disparos que miran la respuesta (P2), `rpc_salud_sistema` y panel en Administración (P5), permisos del rol de lectura (P4). Invariantes I93–I95 | Hecha en este PR; falta aplicarla |
| **E2 · Credenciales que no caducan por sorpresa** | Renovar el token (P1). Anotar su caducidad en el panel de salud y avisar 14 días antes. Un solo sitio que diga qué secretos hay y cuándo caducan | P1 👤 urgente; el aviso, después de E1 |
| **E3 · Revisión semanal guiada** | Una consulta única para la revisión de cada lunes (la de `scripts/revision_agentes.sql`, más salud y decisiones de Tendencia cripto), y revisar «Ampliar el universo» y «Señales más frecuentes» (P6) | Tras aplicar E1 |
| **E4 · Primeras operaciones de Tendencia cripto** | Comparar las 5 primeras con el laboratorio en las mismas fechas (ya previsto en ESTADO §3.1) | Cuando las haya |
| **E5 · Calibración de las prácticas** (doc 05 §9, la antigua entrega E) | Medir horizontes y resultados observados frente a lo estimado | Cuando haya semanas de datos (lleva la 0031 desde el 10-10) |
| **E7 · Agentes investigadores** | Los agentes proponen hipótesis con su propia evidencia y el laboratorio las prueba ([doc 01](01-agentes-investigadores.md)) | Diseño decidido el 2026-10-24; entregas I1–I5 |
| **E8 · Operaciones en corto** ✅ probadas, sin ventaja ([doc 02](02-cortos-en-el-laboratorio.md)) | Previstas para la Fase 3 desde la D6 (doc fase-2/00): quedaron fuera por la regla protegida nº2 porque el simulador no modela el coste del préstamo ni la financiación. Lo que iba a decidirlo, que los agentes las pidieran, no ha pasado: la plantilla «Operar en corto» no ha saltado nunca (exige tres días seguidos sin ninguna señal alcista). Probadas en el laboratorio el 2026-10-24, con financiación y contra el azar: ninguna estrategia bajista tiene ventaja, ni lo contrario que Audacia. La regla nº2 se mantiene | Cerrado |
| **E9 · Otros mercados** 👤 | Previsto como proyecto «multimercado» desde la 0019: conversión de divisas, horario por bolsa y lotes mínimos. Hoy todo es USD con el horario de Nueva York, y el alta rechaza las acciones en otra moneda. Antes hace falta saber qué mercados permite operar QuantFury | Decisión del dueño |
| **E6 · Lo que decida el veredicto** | Agente de cartera, ampliar el universo cripto, fin del experimento (`consecuencias_semanales = true`) | ⏸️ Hasta el veredicto |

---

## 4. Lo que tiene que hacer el dueño (urgente)

1. **Renovar el token** antes del lunes 26-10 a las 13:30 UTC. Crear uno
   *fine-grained* igual que el anterior (solo este repositorio, **Actions:
   Read and write**), pero con **caducidad de 1 año**, y actualizar Vault
   desde el SQL Editor de Supabase, como dice
   [`RUNBOOK-sprint-4.md`](../fase-2/RUNBOOK-sprint-4.md#renovación).
   Apuntar la fecha de caducidad.
2. **Aplicar la 0045** con `scripts\aplicar-migraciones.cmd`.
3. Avisar a Claude para comprobarlo (§6).

El orden da igual. Si la 0045 se aplica antes que el token, el panel de
salud enseña el ETL en rojo con el 401 hasta que se renueve, y en la
siguiente pasada después de renovarlo aparece «vuelve a lanzarse».

---

## 5. Decisiones abiertas

| Decisión | Opciones | Por defecto |
|---|---|---|
| P7: ¿espera tras salir por deterioro, como la de tras el stop? | A) Sí, 24 h en ese activo. B) No: es una regla del grupo de control y se deja como está | **B**, hasta el final del experimento |
| P7: ¿límite de stops por activo (QFIN: 2 stops en 10 días)? | A) Sí: tras 2 stops en 14 días, el activo sale del universo del agente. B) No | **B**, por la misma razón |
| ¿Avisos fuera del dashboard (correo o Telegram) cuando algo falla? | A) Sí, con un workflow que lea los fallos. B) No: basta con el panel | **B** de momento: la E1 primero; se decide al ver si el panel basta |

---

## 6. Comprobar la E1 al aplicarla

Con `scripts/consultar.py` (rol `analista_lectura`):

```sql
-- El rol ya lee todo: esto antes daba «permission denied».
select * from v_comparativa_agentes;
-- Los disparos guardan su petición y su respuesta.
select clave, ultimo, peticion_id, estado_http, fallando_desde, left(respuesta, 80)
  from control_despachos;
-- El aviso del 401 (si el token aún no se ha renovado).
select creado_en, mensaje from eventos_sistema
 where tipo in ('fallo', 'etl') and datos ->> 'donde' like 'disparar%'
 order by id desc limit 5;
-- Las decisiones diarias de Tendencia cripto.
select d.fecha_vela, d.accion, count(*) from agente_decisiones_diarias d
 group by 1, 2 order by 1 desc, 2;
```

Y en el dashboard, **Administración → Salud del sistema**: los dos ETL,
la frescura de las señales y el ciclo de cada agente.
