# B. Arquitectura y stack tecnológico

> **Autor**: Arquitecto de Software (equipo virtual), con presupuesto de cuotas del Data Engineer
> **Fecha**: 2026-09-20
> **Estado**: Propuesta
> **Restricción dura**: coste de infraestructura **0 €/mes**, sin tarjeta de crédito en el camino crítico

---

## 1. La decisión que reordena todo: el motor deja de ser un servidor

En la Fase 1, el motor analítico es un servicio HTTP que responde cuando el
frontend pregunta. Eso obliga a tener un proceso Python **vivo y a la
escucha**, que es precisamente lo que ningún tier gratuito ofrece bien: o
duerme tras 15 minutos (Render), o cobra por tiempo de ejecución, o exige
tarjeta con techo de gasto abierto (Cloud Run).

La Fase 2 invierte el flujo: **el motor escribe, no responde**.

```
FASE 1 (pull, síncrono)              FASE 2 (push, asíncrono)
─────────────────────────            ────────────────────────────
usuario → frontend                   motor (job programado)
        → Express                            ↓ escribe
        → FastAPI                     PostgreSQL (senales, precios)
        → yfinance/CoinGecko                  ↑ lee
        ← espera 30 s el bloque       frontend → usuario (instantáneo)
          cripto en frío
```

Tres consecuencias, todas buenas:

1. **No hay servidor Python que pagar.** El motor corre como job programado
   en GitHub Actions, arranca, calcula, escribe y muere.
2. **La latencia de usuario se desploma.** Hoy el primer escaneo en frío del
   bloque cripto ronda el medio minuto (documentado en el README). En Fase 2
   el usuario lee una fila ya calculada: milisegundos.
3. **La lógica de negocio funciona offline**, que es el requisito 2 textual.
   Si Yahoo se cae, el sistema sigue mostrando la última lectura válida con
   su marca de tiempo, y el `circuitBreaker` en memoria de la Fase 1 deja de
   hacer falta: la caché es la tabla.

El precio a pagar: **las señales tienen la edad de la última pasada del
ETL**, no del instante. Se paga con honestidad en la UI (`calculado_en`
visible, y aviso cuando el dato supera cierta antigüedad), que es lo que el
sistema de diseño de la Fase 1 ya hace con `desdeCache`.

---

## 2. Topología propuesta

```
                        NAVEGADOR DEL USUARIO
                    ┌──────────────────────────┐
                    │ React 18 + Vite (SPA)    │
                    │ @supabase/supabase-js    │
                    │ solo anon key            │
                    └───┬──────────────┬───────┘
                        │ PostgREST    │ Realtime (WS)
                        │ (RLS)        │ postgres_changes
        ┌───────────────▼──────────────▼─────────────────────────┐
        │              SUPABASE (proyecto único, free)           │
        │  ┌──────────────────────────────────────────────────┐  │
        │  │ PostgreSQL 15 + RLS                              │  │
        │  │   19 tablas · 9 vistas · 6 RPC SECURITY DEFINER  │  │
        │  │   pg_cron  ───► dispara cada 1 min               │  │
        │  │   pg_net   ───► HTTP saliente desde SQL           │  │
        │  └──────────────────────────────────────────────────┘  │
        │  ┌──────────────┐  ┌───────────────┐  ┌─────────────┐  │
        │  │ Auth         │  │ Edge Functions│  │ Realtime    │  │
        │  │ email+passwd │  │ (Deno / TS)   │  │             │  │
        │  └──────────────┘  └───────┬───────┘  └─────────────┘  │
        └──────────────────────────┬─┴──────────────────────────┬─┘
                                   │                            │
        ┌──────────────────────────▼─────────┐   ┌──────────────▼────────┐
        │ 4 Edge Functions                   │   │ Precio vivo           │
        │  · monitor-ordenes   (cada 1 min)  │   │  yfinance-lite / CG    │
        │  · ciclo-agentes     (cada 5 min)  │──►│  solo cotización,      │
        │  · resolver-activo   (on demand)   │   │  sin pandas            │
        │  · corte-semanal     (dom 23:59)   │   └───────────────────────┘
        └──────────────┬─────────────────────┘
                       │ workflow_dispatch (GitHub API)
        ┌──────────────▼──────────────────────────────────────────┐
        │  GITHUB ACTIONS  (ubuntu-latest, python 3.12)           │
        │   motor-analitico/  ← EL CÓDIGO DE FASE 1, SIN CAMBIOS  │
        │   + escritor_supabase.py  (única pieza nueva)           │
        │                                                          │
        │   · etl-acciones   cada 30 min, horario de mercado US    │
        │   · etl-cripto     cada 60 min, 24/7                     │
        │   · backfill       on demand (activo nuevo)              │
        │   · keep-alive     semanal                               │
        └──────────────┬──────────────────────────────────────────┘
                       │ yfinance (2 años) · CoinGecko (2 llamadas/cripto)
                       ▼
                 PROVEEDORES EXTERNOS

        ┌────────────────────────────────────┐
        │ VERCEL (Hobby) — hosting estático  │
        │  build: vite build → dist/         │
        │  SIN cron (ver §4.2), SIN backend  │
        └────────────────────────────────────┘
```

---

## 3. Stack por capa, con el porqué

| Capa | Tecnología | Por qué esta y no otra |
|------|-----------|------------------------|
| **Frontend** | React 18 + Vite (lo que ya hay) + `@supabase/supabase-js` + React Router | No se reescribe: el sistema de diseño «Instrumento», los tokens CSS, `formato.js` y la guía de lectura se conservan íntegros. Solo se añaden router (hoy no hay) y cliente de Supabase |
| **Hosting frontend** | Vercel Hobby | Build de Vite nativo, HTTPS y dominio gratis. Alternativa equivalente: Cloudflare Pages, con ancho de banda ilimitado en su tier gratuito — preferible si el tráfico crece |
| **Base de datos** | PostgreSQL 15 en Supabase | Es el mismo PostgreSQL de la Fase 1: el `schema.sql` actual se extiende, no se migra de motor. Y trae `pg_cron`, `pg_net` y RLS sin instalar nada |
| **Autenticación** | Supabase Auth (email + password) | Requisito 4 literal. Hashing, tokens de recuperación y verificación de correo resueltos. **La aprobación manual NO la hace Auth**: la hace `perfiles.estado` + RLS (doc A §6) |
| **Autorización** | Row Level Security + 6 RPC `SECURITY DEFINER` | La regla de negocio vive junto al dato. Un cliente comprometido no puede abrir una orden a 50× porque el `CHECK` y el RPC están en el servidor |
| **Lógica de negocio ligera** | Edge Functions (Deno + TypeScript) | Monitoreo de TP/SL, ciclo de agentes, resolución de activos nuevos. Son aritmética y un `fetch`: no necesitan pandas. 500 k invocaciones/mes gratis |
| **Planificador** | `pg_cron` (intervalos de segundos) + GitHub Actions `schedule` | Ver §4.2: es la decisión no obvia del diseño |
| **Motor analítico** | Python 3.12 + pandas + `pandas-ta==0.4.71b0` en GitHub Actions | **Se mantiene sin cambios** (decisión D2). Corre como job, no como servidor |
| **Tiempo real** | Supabase Realtime sobre `postgres_changes` en `eventos_sistema` | Sustituye `/ws/events`. Sin servidor WebSocket que mantener |
| **CI/CD** | GitHub Actions: tests en cada PR, deploy de migraciones y Edge Functions en merge a `main` | Los 69 tests de la Fase 1 pasan a ser puerta de merge, no un comando manual |
| **Secretos** | GitHub Secrets + Supabase Function Secrets + Vercel Env Vars | El `.env` único de la Fase 1 muere aquí. Ver §5 |
| **Observabilidad** | `eventos_sistema` + logs de Supabase + resumen del ETL en el propio `job summary` de Actions | Cero coste, suficiente para un proyecto personal |

### 3.1 La única pieza de código verdaderamente nueva del motor

`motor-analitico/escritor_supabase.py` — el adaptador que convierte la salida
de `_escanear_ticker()` en filas de `precios_diarios`, `indicadores_diarios` y
`senales`. Respeta la regla de ubicación del README (lógica de análisis →
`motor-analitico/`) y **no toca ni una línea** de `indicadores/`, `riesgo/` o
`conectores/`.

```python
# motor-analitico/escritor_supabase.py  (esqueleto)
"""
Adaptador de salida: lo que antes devolvía FastAPI, ahora se escribe.

No contiene lógica de análisis. Si aquí aparece un cálculo de indicador,
está en el fichero equivocado (regla de ubicación del README).
"""

def volcar_escaneo(cliente, resultados: list[dict], version_motor: str) -> None:
    filas = []
    for r in resultados:
        if "error" in r:
            # El fallo NO tumba el lote: se marca el activo y se sigue.
            # Es el mismo espíritu que /internal/scan, que ya devolvía
            # {"ticker": t, "error": ...} en vez de abortar.
            marcar_error_activo(cliente, r["ticker"], r["error"])
            continue
        filas.append(a_fila_senal(r, version_motor))

    # UPSERT en lote: una sola llamada de red para todo el universo.
    cliente.table("senales").insert(filas).execute()
```

---

## 4. Las tres decisiones de arquitectura que no son obvias

### 4.1 ¿Por qué no AWS, GCP o Azure?

No es por capacidad técnica, es por la definición de «coste 0».

| Proveedor | Tier gratuito | Problema para este proyecto |
|-----------|--------------|------------------------------|
| **GCP Cloud Run** | 2 M peticiones/mes, escala a cero | Exige cuenta de facturación con tarjeta. El tier es generoso pero **no hay techo duro**: un bucle en el ETL factura. «Coste 0» pasa a depender de tu vigilancia |
| **AWS Lambda + RDS** | 1 M invocaciones Lambda | RDS free tier **caduca a los 12 meses**. Después, factura. Un proyecto personal que dura dos años acaba pagando |
| **Azure Functions + Postgres** | 1 M ejecuciones | Postgres flexible server no tiene tier permanentemente gratuito |
| **Supabase + Vercel + GH Actions** | Permanente, **sin tarjeta** | Cuando se agota una cuota, el servicio **se detiene**; no factura. Esto es lo que «coste 0» significa de verdad |

La diferencia es cualitativa: en los tres primeros, superar la cuota genera
una factura; en el elegido, genera un error. Para un proyecto personal, un
error es infinitamente preferible.

**Cuándo reconsiderarlo**: si el sistema pasara de 3 agentes a 30, o el
universo de 150 activos a 2.000, GCP Cloud Run con presupuesto y alerta
configurados sería la migración natural. El diseño no lo impide: el motor
ya está contenedorizado conceptualmente (un `Dockerfile` en el Sprint 1) y
solo cambiaría el disparador.

### 4.2 ¿Por qué `pg_cron` y no el cron de Vercel? *(la decisión más importante del documento)*

El plan Hobby de Vercel limita los cron jobs a **una ejecución al día**, y
una expresión más frecuente **falla en el despliegue** con un error
explícito. Además la precisión es «por hora»: un cron a la 1:00 puede
dispararse en cualquier momento entre 1:00 y 1:59.

Eso descarta a Vercel como planificador de un monitor de TP/SL, que por
definición necesita mirar el precio cada pocos minutos. Comparativa de los
planificadores gratuitos disponibles:

| Planificador | Intervalo mínimo | Cuota gratuita | Puede ejecutar pandas | Veredicto |
|--------------|------------------|----------------|----------------------|-----------|
| **Vercel Hobby cron** | 1 vez al día, ±59 min | Incluido | No | ❌ Descartado para el monitor |
| **`pg_cron` en Supabase** | **Segundos** (30 s en el ejemplo oficial) | Incluido | No | ✅ **Monitor y ciclo de agentes** |
| **GitHub Actions `schedule`** | 5 min (con retrasos habituales en horas punta) | 2.000 min/mes privado, **ilimitado público** | **Sí** | ✅ **Motor analítico (ETL)** |
| **Cloudflare Workers cron** | 1 min | 100 k peticiones/día, **5 cron triggers por cuenta**, 10 ms de CPU | No (10 ms es nada) | ⚠️ Reserva |

Reparto final:
- **`pg_cron` cada minuto** → `monitor-ordenes`. Aritmética pura: compara
  `activos.ultimo_precio` con `ordenes.tp/sl/precio_liquidacion`. No necesita
  ni pandas ni red si el precio ya está en la tabla.
- **`pg_cron` cada 5 minutos** → `ciclo-agentes`. Decide aperturas leyendo
  `senales_vigentes`.
- **`pg_cron` domingos 23:59 UTC** → `corte-semanal`.
- **GitHub Actions** → el motor Python, que es lo único que necesita
  `pandas-ta` y ventanas de 2 años de velas.

Beneficio colateral no menor: `pg_cron` disparando cada minuto mantiene el
proyecto de Supabase con actividad continua, lo que mitiga el riesgo R1
(pausa por inactividad).

### 4.3 ¿Cómo se hace un backfill *on demand* sin servidor?

El requisito 3 (ingesta de un activo nuevo) tiene un conflicto de latencia:
el motor solo corre cada 30-60 minutos, y un usuario que acaba de buscar
`NVDA` no va a esperar media hora.

Solución, coste 0: **la Edge Function dispara el workflow por la API de
GitHub**.

```
usuario escribe "NVDA"
   │
   ├─► rpc_buscar_activo('NVDA')
   │      ¿está en `activos`? → SÍ → se añade a la cartera. FIN (instantáneo)
   │                            NO ↓
   ├─► Edge Function `resolver-activo`
   │      1. valida el símbolo contra el proveedor (1 llamada ligera)
   │      2. INSERT INTO activos (estado = 'pendiente_backfill')
   │      3. INSERT INTO cartera_activos  ← el usuario ya lo ve, en estado
   │                                        «aprovisionando»
   │      4. POST /repos/{owner}/{repo}/actions/workflows/backfill.yml/dispatches
   │         con {"ref":"main","inputs":{"simbolo":"NVDA"}}
   │
   └─► GitHub Actions `backfill` (arranca en ~10-30 s)
          · 2 años de velas diarias (acciones) o reconstrucción de 30 días
            con rango real (cripto)
          · indicadores + confluencia + apalancamiento
          · UPDATE activos SET estado = 'activo', primer_backfill_en = now()
          · INSERT INTO eventos_sistema → Realtime → la UI se actualiza sola
```

Latencia percibida: el activo aparece **al instante** con un estado
explícito, y se completa en 1–3 minutos sin que el usuario recargue nada.
El truco es que la espera es visible y tiene nombre, en vez de ser un
spinner.

Y el ahorro: `activos.simbolo UNIQUE` significa que el **segundo** usuario
que añada `NVDA` no paga ningún backfill. Con 10 usuarios y 25 activos
cada uno, el sistema no hace 250 backfills sino tantos como activos
distintos haya — probablemente menos de 60, porque los usuarios se solapan
en los nombres populares.

---

## 5. Gestión de secretos — aquí muere el `.env` único

La Fase 1 tiene una regla clara: **un solo `.env` en la raíz** para los tres
servicios, y el README dedica una sección entera a diagnosticar el problema
del `backend/.env` duplicado que provoca un 401. En la nube esa regla no
puede sobrevivir, porque los tres servicios corren en tres proveedores
distintos que no comparten sistema de ficheros.

| Secreto | Dónde vive en Fase 2 | Quién lo lee |
|---------|---------------------|--------------|
| `SUPABASE_URL` | Vercel Env (público), GitHub Secrets, Function Secrets | Todos |
| `SUPABASE_ANON_KEY` | Vercel Env — **es pública por diseño**, protegida por RLS | Frontend |
| `SUPABASE_SERVICE_ROLE_KEY` | GitHub Secrets + Supabase Function Secrets. **JAMÁS en Vercel** | ETL, Edge Functions |
| `PORTFOLIO_ENCRYPTION_KEY` | Supabase Function Secrets | Solo la Edge Function que cifra `posiciones_reales` |
| `GITHUB_DISPATCH_TOKEN` | Supabase Function Secrets | `resolver-activo` (PAT con permiso `actions:write` **solo** sobre este repo) |
| `ANALYTICS_SERVICE_INTERNAL_TOKEN` | **Se elimina** | Ya no hay servicio interno que autenticar |
| `SESSION_SECRET` | **Se elimina** | Ya no hay sesión de Express |

**Puerta de CI obligatoria** (historia H-07): tras `vite build`, un paso hace
`grep` del prefijo de la `service_role key` en `dist/`. Si aparece, el build
falla. Es el error de una línea que expone la base de datos entera, y la
única defensa fiable es automática.

Dos variables que **sí** sobreviven de la Fase 1 y dos que se mueven:

- `LEVERAGE_HARD_CAP_FASE1` / `_FASE2`: pasan a `cuentas_simulacion` y a
  `agentes.estrategia`. Resuelve la deuda técnica nº3: tres agentes necesitan
  tres juegos de parámetros a la vez, y una variable de entorno no puede.
- Las `FASE_TRANSICION_*`: igual, a `agentes.estrategia`. Dejan de ser
  «declaradas pero sin leer».

---

## 6. Presupuesto de cuotas gratuitas

Este es el documento que decide si el coste 0 se sostiene. Números, no
optimismo.

### 6.1 Supabase (plan Free)

| Recurso | Límite | Uso estimado Fase 2 | Margen |
|---------|--------|---------------------|--------|
| Proyectos activos | 2 | **1** — el otro lo ocupa una aplicación distinta del usuario | **Agotado**: no hay proyecto de staging, ver §7 |
| Tamaño de BD | 500 MB | ~15 MB con 150 activos, 2 años de velas, 3 agentes operando un año | **97 %** |
| Usuarios activos/mes | 50.000 | < 20 | Irrelevante |
| Invocaciones Edge Functions | 500.000/mes | 43.200 (monitor 1/min) + 8.640 (agentes 1/5 min) + 4 (corte semanal) + eventuales ≈ **52.000** | **90 %** |
| Egress | 5 GB + 5 GB caché | < 1 GB | Amplio |
| Conexiones Realtime | 200 pico | < 20 | Amplio |
| **Pausa por inactividad** | ~1 semana de baja actividad | `pg_cron` cada minuto + ETL varias veces al día | Mitigado, más *keep-alive* semanal (H-04) |
| Retención de logs | 1 día | — | **Limitación real**: un fallo del fin de semana no es diagnosticable el lunes. Por eso `eventos_sistema` es una tabla y no solo un log |

Cálculo del tamaño de BD, para que se pueda auditar:

| Tabla | Filas estimadas | Tamaño |
|-------|-----------------|--------|
| `precios_diarios` | 150 activos × 504 velas = 75.600 | ~9 MB |
| `indicadores_diarios` | 75.600 | ~8 MB |
| `senales` | 150 × 48 pasadas/día × 365 = 2,6 M ⚠️ | **~600 MB — NO CABE** |

> **Hallazgo del presupuesto**: la tabla `senales` con histórico completo
> **revienta el tier gratuito en menos de un año.** Corrección incorporada al
> diseño (historia H-12): retención por ventanas.
> - Últimos **30 días**: todas las señales (para auditar cualquier orden reciente).
> - De 30 días a 1 año: **una señal por activo y día** (la del cierre).
> - Más de 1 año: se borra, salvo las señales referenciadas por una
>   `ordenes.senal_id` — esas son evidencia del experimento y **nunca** se
>   borran (`ON DELETE SET NULL` protege la integridad si alguna se perdiera).
>
> Con esa política: ~150 × 48 × 30 (recientes) + 150 × 335 (comprimidas) ≈
> 266.000 filas ≈ **60 MB**. Total del sistema: ~**80 MB**, un 16 % del límite.
> El job de retención corre en el `keep-alive` semanal.

Este es exactamente el tipo de problema que aparece al presupuestar y no al
diseñar sobre pizarra. Si nadie lo hubiera calculado, el sistema habría
funcionado perfectamente durante seis meses y luego habría dejado de
escribir señales sin explicación aparente.

### 6.2 GitHub Actions (repo privado, 2.000 min/mes)

| Workflow | Cadencia | Ejecuciones/mes | Duración estimada | Minutos/mes |
|----------|----------|-----------------|-------------------|-------------|
| `etl-acciones` | cada 30 min, 13 franjas/día × 21 días de mercado | 273 | ~60 s (hasta 130 acciones, `yfinance` en lote) | 273 |
| `etl-cripto` | cada 60 min, 24/7 | 720 | ~60 s (20 criptos × 2 llamadas con espaciado de 6 s ≈ 4 min ⚠️) | **ver nota** |
| `backfill` | on demand | ~30 | ~45 s | 23 |
| `keep-alive` + retención | semanal | 4 | ~30 s | 2 |
| `tests` (CI en PR) | por PR | ~40 | ~90 s | 60 |

> **Nota sobre `etl-cripto`**: con 20 criptos y el espaciado de 6 s que ya
> implementa `coingecko.py` para respetar el `429`, cada pasada son ~4
> minutos. A 720 pasadas/mes serían 2.880 minutos: **excede la cuota solo.**
>
> Corrección incorporada (H-10): el ETL de cripto **no recorre todas las
> criptos en cada pasada**. Prioriza por dos criterios:
> 1. Criptos con una orden abierta de un agente o usuario → **cada pasada**.
> 2. El resto → rotación por antigüedad de `ultimo_etl_en`, máximo 5 por pasada.
>
> Con ~6 criptos por pasada: ~36 s de espera + cálculo ≈ 60 s. **720 min/mes.**
> Total del sistema: 273 + 720 + 23 + 2 + 60 = **1.078 min/mes, el 54 % de la
> cuota.** Holgura suficiente para un mes con mucha actividad de desarrollo.

Salida de emergencia si se agota: hacer el repositorio público elimina el
límite por completo (decisión D5), previa auditoría del historial en busca
de secretos.

### 6.3 Proveedores de datos — el cuello de botella real

| Proveedor | Cuota | Consumo Fase 2 | Riesgo |
|-----------|-------|----------------|--------|
| **CoinGecko** (free, sin clave) | ~10-15 req/min; espaciado de 6 s y reintento con `Retry-After` ya implementados | 2 llamadas por cripto y pasada; máximo 6 criptos/pasada = 12 req en ~36 s | Controlado por diseño. **Este es el techo del sistema**: es lo que fija el límite de 20 criptos globales (D7) |
| **Yahoo (`yfinance`)** | Sin cuota publicada — API **no oficial** | 1 llamada por acción y pasada, en lote | Fragilidad estructural, no de cuota (riesgo R3) |

La observación que importa para el producto: **el coste 0 no lo limita la
nube, lo limita CoinGecko.** Supabase y GitHub Actions tienen holgura del
50-97 %; el número de criptomonedas que el sistema puede seguir está fijado
por una API gratuita que permite 15 peticiones por minuto y cobra dos por
moneda. Si algún día el proyecto necesita 100 criptos, el gasto no será en
servidores: será una clave de API de CoinGecko.

### 6.4 Vercel Hobby

| Recurso | Límite | Uso |
|---------|--------|-----|
| Ancho de banda | 100 GB/mes | SPA de ~400 KB comprimida; irrelevante |
| Builds | 100/día | < 5 |
| Cron jobs | 1/día, ±59 min | **No se usa** (§4.2) |
| Functions | Incluidas | **No se usan**: no hay backend en Vercel |

Vercel queda reducido a lo que hace mejor gratis: servir ficheros estáticos
con HTTPS. Su restricción de uso no comercial encaja: el proyecto es
personal por definición.

---

## 7. Entornos y despliegue

| Entorno | Supabase | Frontend | Datos |
|---------|----------|----------|-------|
| **local** | `supabase start` (Docker) | `vite dev` | Semilla con los 21 activos del `UNIVERSO_ACCIONES` de la Fase 1 y 90 días de velas sintéticas |
| **CI** | PostgreSQL 15 efímero en el runner | — | Migraciones desde cero + semilla, en cada PR |
| **producción** | El único proyecto Supabase disponible | `master` en Vercel | ETL programado |

> **No hay entorno de staging remoto, y eso cambia el modo de trabajo.**
> El tier gratuito da dos proyectos activos: uno lo ocupa otra aplicación
> y el otro es producción del dashboard. Cada migración que se mergea
> llega a producción sin escala intermedia, y el tier gratuito tampoco
> incluye recuperación a un punto en el tiempo, así que una migración
> destructiva no se deshace.
>
> Lo que ocupa ese lugar es `.github/workflows/migraciones.yml`: levanta
> un PostgreSQL 15 limpio, aplica las migraciones **desde cero** junto
> con la semilla, y ejecuta las catorce invariantes de `supabase/pruebas/`
> — entre ellas que el `CHECK` del contrato rechace una señal
> incoherente, que `v_velas_con_rango` deje fuera las velas
> reconstruidas, que ninguna tabla se quede sin RLS, que ninguna
> `SECURITY DEFINER` se quede sin `search_path`, y que la retención
> nunca borre una señal referenciada por una orden. Verificado también
> en negativo: quitar el `CHECK`, olvidar un `ENABLE ROW LEVEL SECURITY`
> o resetear un `search_path` ponen el job en rojo.
>
> Las previsualizaciones de Vercel por pull request apuntan a
> **producción** con la `anon key`. Es aceptable mientras RLS conceda
> solo lectura a usuarios aprobados, y es una razón más para que las
> políticas de H-14 se revisen con cuidado.

Pipeline en `merge` a `main`:
1. `pytest motor-analitico/tests/` — **los 69 casos de la Fase 1 son puerta de merge**.
2. Tests de las Edge Functions (Deno) y de los RPC (pgTAP).
3. `supabase db push` — migraciones versionadas, nunca cambios a mano en la consola.
4. `supabase functions deploy`.
5. `vercel deploy --prod`.
6. `grep` anti-fuga de `service_role key` en `dist/`. Si encuentra algo, **falla**.

> **Regla de operación**: ningún cambio de esquema se hace desde el editor
> SQL de la consola de Supabase. Todo va en un fichero de
> `supabase/migrations/`. Con retención de logs de un día, un cambio manual
> no documentado es indepurable a las 48 horas.

---

## 8. Lo que este stack no resuelve

Honestidad sobre los límites, para que nadie los descubra en producción:

1. **No hay backup automático.** El tier gratuito de Supabase no incluye
   descargas de backup ni recuperación a un punto en el tiempo. Mitigación
   (H-04): el `keep-alive` semanal hace `pg_dump` de las tablas de gobierno y
   del experimento (`perfiles`, `ordenes`, `agente_*`, `mejores_practicas`) y
   lo sube como artefacto de GitHub Actions, con 90 días de retención. Las
   tablas de precios no se respaldan: se pueden regenerar desde los
   proveedores.
2. **La precisión del monitor es de ~1 minuto, no de tiempo real.** Un activo
   que toque el TP y retroceda dentro del mismo minuto no se detecta. Es una
   limitación aceptada y debe estar escrita en la UI: el simulador aproxima,
   no replica un broker.
3. **Un retraso de GitHub Actions retrasa las señales.** Los workflows
   programados sufren cola en horas punta. El diseño lo absorbe porque el
   monitor no depende del ETL: lee `activos.ultimo_precio`, que la Edge
   Function refresca por su cuenta.
4. **Los workflows programados se desactivan tras 60 días sin actividad en el
   repositorio.** Con el proyecto en desarrollo activo no es un problema; si
   se aparca seis meses, los agentes se paran en silencio. El `keep-alive`
   semanal lo detecta y lo notifica.
