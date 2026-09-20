# A. Modelo de datos de la Fase 2

> **Autor**: Data Engineer (equipo virtual), revisado por Arquitecto y Seguridad
> **Fecha**: 2026-09-20
> **Estado**: Propuesta
> **Destinatario**: Data Engineer y Backend Developer
> **Objetivo**: un esquema que un dev pueda ejecutar y entender sin
> preguntar nada. El DDL de §7 es ejecutable tal cual sobre un PostgreSQL 15+.

---

## 1. Las cinco ideas que explican todo el esquema

Si solo se leen cinco párrafos de este documento, que sean estos:

1. **El catálogo de activos es global, no por usuario.** `activos` tiene
   `simbolo UNIQUE`. Si diez usuarios añaden `bitcoin`, el sistema paga **un**
   backfill y **una** actualización diaria. Esto es, literalmente, la
   respuesta al requisito «evitar peticiones redundantes a APIs externas»:
   no es una caché de respuestas HTTP, es que el dato vive una sola vez.

2. **`senales` es el payload de `/internal/scan` persistido.** Mismos 20
   campos, mismos nombres, mismas invariantes. El motor de la Fase 1 deja de
   responder por HTTP y pasa a hacer `UPSERT` en esta tabla. El frontend deja
   de llamar al backend y pasa a leer una vista. **El contrato no cambia**,
   solo su transporte — y los devs ya lo conocen.

3. **El saldo es derivado; el libro mayor es la verdad.** `movimientos_saldo`
   es *append-only*: cada bloqueo de margen, liberación y resultado de
   operación deja una fila con el `saldo_resultante`. `cuentas_simulacion.saldo_*`
   es una materialización por rendimiento, y un test debe poder recalcularla
   desde cero (§5.2). Sin esto, un bug en el monitor corrompe saldos en
   silencio y no hay forma de demostrarlo.

4. **Una sola tabla de cuentas para usuarios y agentes.** `cuentas_simulacion`
   con un `CHECK` que exige exactamente uno de `usuario_id` / `agente_id`. Un
   agente es un titular de cuenta más, así que todo el motor de órdenes,
   monitoreo y libro mayor sirve para los dos sin duplicar una línea.

5. **La puerta de aprobación está en RLS, no en la UI.** Supabase Auth
   **entrega un JWT válido a un usuario recién registrado y todavía pendiente**.
   Si la única barrera es una pantalla de React, ese JWT lee la base de datos
   entera con `curl`. Toda política usa `public.es_usuario_aprobado()` (§6.1).

---

## 2. Diagrama entidad-relación conceptual

```
  GOBIERNO                      CATÁLOGO GLOBAL (escritura: solo ETL)
  ┌───────────────────┐         ┌──────────────────┐
  │ auth.users        │         │ activos          │──1:N──┐
  │  (Supabase Auth)  │         │  simbolo UNIQUE  │       │
  └─────────┬─────────┘         │  clase, estado   │       │
            │1:1                └────────┬─────────┘       │
  ┌─────────▼─────────┐                  │1:N              │1:N
  │ perfiles          │         ┌────────▼─────────┐  ┌────▼──────────────┐
  │  rol              │         │ precios_diarios  │  │ senales           │
  │  estado ◄─── pendiente/     │  PK(activo,fecha)│  │  = payload /scan  │
  │              aprobado       │  rango_real ⚠    │  │  operable, tp, sl │
  │  aprobado_por     │         └────────┬─────────┘  └────┬──────────────┘
  └──┬────────────┬───┘                  │1:1              │
     │1:N         │1:N          ┌────────▼─────────┐       │ (justifica)
     │            │             │ indicadores_     │       │
     │            │             │ diarios (caché)  │       │
     │            │             └──────────────────┘       │
     │            │                                        │
  ┌──▼─────────┐  │  CARTERAS                              │
  │ carteras   │  │                                        │
  │  tipo      │──┼──N:M──► cartera_activos ──────────────►│
  └────────────┘  │                          (activo_id)   │
                  │                                        │
  ┌───────────────▼──┐  ┌──────────────────┐               │
  │ posiciones_reales│  │ registro_        │               │
  │  importes en claro│ │ consentimiento   │               │
  └──────────────────┘  └──────────────────┘               │
                                                            │
  SIMULADOR                                                 │
  ┌────────────────────────┐                                │
  │ cuentas_simulacion     │◄──1:1──┬── perfiles (usuario)  │
  │  saldo_disponible      │        └── agentes  (agente)   │
  │  saldo_bloqueado       │                                │
  │  fase, capital_maximo  │                                │
  │  estado                │                                │
  └───┬────────────────┬───┘                                │
      │1:N             │1:N                                 │
  ┌───▼──────────┐  ┌──▼────────────────┐                   │
  │ ordenes      │  │ movimientos_saldo │                   │
  │  senal_id ───┼──┼───────────────────┼───────────────────┘
  │  tp, sl      │  │  (APPEND-ONLY)    │
  │  apalancam.  │  │  saldo_resultante │
  │  motivo_cierre│ └───────────────────┘
  └──────────────┘

  AGENTES
  ┌──────────────┐     ┌────────────────┐     ┌──────────────────┐
  │ agentes      │─1:N─► agente_dias    │     │ eventos_sistema  │
  │  objetivo_   │     │  saldo_apertura│     │  (Realtime)      │
  │  diario_pct  │     │  cumplido      │     └──────────────────┘
  │  estrategia  │     └────────────────┘
  │  estado      │─1:N─► agente_semanas  (corte semanal, veredicto)
  └───┬──────┬───┘
      │1:N   │1:N
  ┌───▼──────────────┐  ┌──▼──────────────────┐
  │ agente_backlog   │  │ mejores_practicas   │──1:N──► mp_valoraciones
  │  tipo, estado    │  │  condiciones jsonb  │──1:N──► mp_adopciones
  │  clave_dedup ⚠   │  │  resultado_observado│         (¿funcionó?)
  └──────────────────┘  └─────────────────────┘
```

**Leyenda de los avisos**:
`⚠ rango_real` — sin esta columna se pierde la disciplina de la Fase 1 sobre
la vela reconstruida de cripto. `⚠ clave_dedup` — sin ella los agentes
inundan el backlog con la misma petición cada ciclo.

**Sobre los importes**: por la decisión D3, firmada el 2026-09-20, **no se
cifra ninguno** — ni en el simulador ni en la cartera importada. El
supuesto es que ningún importe del sistema es dinero real. Si algún día
se cargan cifras reales de patrimonio, esa decisión hay que revisarla
antes de importarlas.

---

## 3. Catálogo de tablas

### 3.1 Gobierno y usuarios

#### `perfiles`
Extiende `auth.users` de Supabase. **Es la tabla de la puerta de acceso.**

| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `uuid` PK | FK → `auth.users(id)` `ON DELETE CASCADE` |
| `email` | `text NOT NULL` | Duplicado de `auth.users` para poder listarlo en el panel admin sin permisos sobre el esquema `auth` |
| `nombre` | `text` | |
| `rol` | `text NOT NULL DEFAULT 'usuario'` | `'usuario'` \| `'admin'` |
| `estado` | `text NOT NULL DEFAULT 'pendiente'` | `'pendiente'` \| `'aprobado'` \| `'rechazado'` \| `'suspendido'` |
| `motivo_estado` | `text` | Obligatorio al rechazar o suspender (validado en el RPC, no en la tabla) |
| `aprobado_por` | `uuid` | FK → `perfiles(id)`; `NULL` mientras esté pendiente |
| `aprobado_en` | `timestamptz` | |
| `creado_en` | `timestamptz NOT NULL DEFAULT now()` | |

**Regla de negocio**: el primer usuario registrado se convierte en `admin` +
`aprobado` automáticamente (trigger), porque si no nadie puede aprobar a
nadie y el sistema queda muerto en el arranque. A partir del segundo, todos
nacen `pendiente` / `usuario`.

#### `auditoria_admin`
Toda acción de gobierno deja rastro. No es opcional: es lo que permite
responder «¿quién aprobó a este usuario y cuándo?».

`id`, `actor_id` (FK perfiles), `accion` (`'aprobar_usuario'`, `'rechazar_usuario'`,
`'suspender_usuario'`, `'revertir_fase'`, `'resolver_backlog'`, `'reiniciar_agente'`),
`objetivo_tipo`, `objetivo_id`, `detalle jsonb`, `creado_en`.

#### `registro_consentimiento` *(heredada de Fase 1, extendida)*
Se conserva tal cual **más** `usuario_id`. Sigue siendo el audit trail del
consentimiento de persistencia que pidió el DPO en el Sprint 1 de la Fase 1.

---

### 3.2 Catálogo global de activos

#### `activos`
El corazón del ahorro de peticiones. Escritura reservada al ETL
(`service_role`); lectura para cualquier usuario aprobado.

| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `bigserial` PK | |
| `simbolo` | `text NOT NULL UNIQUE` | Normalizado: acciones en mayúsculas (`AAPL`), cripto en minúsculas (`bitcoin`), exactamente como los usa hoy `escaner.js` |
| `clase` | `text NOT NULL` | `'accion'` \| `'cripto'` |
| `proveedor` | `text NOT NULL` | `'yahoo'` \| `'coingecko'` |
| `id_proveedor` | `text NOT NULL` | El id que espera el conector. Para cripto sustituye al `IDS_CRIPTO` hardcodeado de `servicio_interno.py` |
| `nombre` | `text` | |
| `moneda` | `text NOT NULL DEFAULT 'USD'` | |
| `estado` | `text NOT NULL DEFAULT 'pendiente_backfill'` | `'pendiente_backfill'` \| `'activo'` \| `'suspendido'` \| `'invalido'` |
| `ultimo_precio` | `numeric(20,8)` | Precio vivo, actualizado por el ETL y leído por el monitor |
| `ultimo_precio_en` | `timestamptz` | **Crítico**: el monitor descarta precios añejos (riesgo R8) |
| `intentos` | `int NOT NULL DEFAULT 0` | Backoff |
| `proximo_intento_en` | `timestamptz` | Backoff: el ETL nunca reintenta antes de esta hora |
| `ultimo_error` | `text` | Se muestra al usuario que añadió el activo |
| `creado_por` | `uuid` | Quién lo pidió primero (trazabilidad de cuota) |
| `primer_backfill_en`, `ultimo_etl_en`, `creado_en` | `timestamptz` | |

**Máquina de estados de `activos.estado`**:
```
  (alta por usuario)
        │
        ▼
  pendiente_backfill ──ETL OK──► activo ──proveedor roto 3 veces──► suspendido
        │                          ▲                                    │
        │                          └──────────ETL OK de nuevo───────────┘
        └──proveedor lo rechaza──► invalido   (terminal: no se reintenta;
                                              evita quemar cuota en tickers fantasma)
```

#### `precios_diarios`
La tabla más grande del sistema — y aun así pequeña: 100 activos × 504 velas
(2 años) ≈ **50.400 filas, ~6 MB**. Sobra de largo en los 500 MB del tier
gratuito.

| Campo | Tipo | Notas |
|-------|------|-------|
| `activo_id` | `bigint` | FK, parte de la PK |
| `fecha` | `date` | Parte de la PK |
| `apertura`, `maximo`, `minimo`, `cierre` | `numeric(20,8)` | |
| `volumen` | `numeric(24,4)` | |
| **`rango_real`** | `boolean NOT NULL DEFAULT true` | **La columna que no se puede olvidar.** `false` para las velas de cripto reconstruidas sin máximo/mínimo reales. `indicadores_diarios` y el cálculo de soporte/resistencia **solo** consumen filas con `rango_real = true` |
| `origen` | `text NOT NULL` | `'yahoo'` \| `'coingecko_market_chart'` \| `'coingecko_ohlc'` |
| `ingerido_en` | `timestamptz` | |

> **Por qué `rango_real` es una columna y no un comentario.** El CHANGELOG de
> la Fase 1 lo midió: calcular el ATR sobre el frame completo, incluyendo las
> velas sin rango real, **inflaba el ATR de BTC un 16 %** y le cambiaba el
> tramo de volatilidad — es decir, cambiaba el apalancamiento recomendado.
> Si esta disciplina no viaja al esquema, el primer dev que escriba
> `SELECT * FROM precios_diarios` para calcular un ATR reintroduce el bug
> silenciosamente. Se blinda además con la vista `v_velas_con_rango` (§4).

#### `indicadores_diarios`
Caché materializada de lo que hoy calcula `indicadores/tecnicos.py` en cada
petición. Existe para que la lógica de negocio funcione **offline**: los
agentes y el frontend no necesitan que el motor esté vivo.

`activo_id`, `fecha` (PK compuesta), `sma_50`, `sma_200`, `rsi_14`, `macd`,
`macd_signal`, `macd_hist`, `atr_14`, `version_motor`, `calculado_en`.

#### `senales`
El payload de `/internal/scan`, fila a fila. Histórico completo (no se
sobrescribe): permite backtesting de los agentes y responder «¿qué veía el
sistema cuando el agente abrió esa orden?».

| Campo | Tipo | Correspondencia con Fase 1 |
|-------|------|----------------------------|
| `id` | `bigserial` PK | — |
| `activo_id` | `bigint` FK | `ticker` |
| `calculado_en` | `timestamptz NOT NULL` | Momento del escaneo |
| `precio_actual` | `numeric(20,8)` | `precio_actual` |
| `direccion` | `text` | `direccion` — `'alcista'`\|`'bajista'`\|`'neutral'` |
| `sesgo_operativo` | `text` | `sesgo_operativo` — `'largo'`\|`'corto'`\|`'sin_sesgo'` |
| `fuerza` | `text` | `fuerza` — `'baja'`\|`'media'`\|`'alta'` |
| `indicadores_alcistas`, `indicadores_bajistas` | `int` | idem |
| `resumen_confluencia` | `text` | `resumen_confluencia` |
| `senales_detalle` | `jsonb` | `senales[]` (nombre, direccion, detalle) |
| `operable` | `boolean NOT NULL` | `operable` |
| `atr_pct` | `numeric(10,4)` | `atr_pct` |
| `leverage_tope` | `numeric(4,1) NOT NULL` | `leverage_tope` |
| `leverage_recomendado` | `numeric(4,1)` | `leverage_recomendado` — `NULL` ⟺ `operable = false` |
| `leverage_referencia_volatilidad` | `numeric(4,1) NOT NULL` | `leverage_referencia_volatilidad` |
| `leverage_motivo` | `text` | `leverage_motivo` |
| `soporte`, `resistencia` | `numeric(20,8)` | Niveles técnicos, **siempre** emitidos, sin rol operativo |
| `sl`, `tp` | `numeric(20,8)` | Solo cuando `operable = true` |
| `niveles_origen` | `text` | `'estructura'` \| `'atr'` |
| **`ratio_rr`** | `numeric(10,4)` | **NUEVO en Fase 2**: `(tp − precio) / (precio − sl)`. Columna generada |
| `version_motor` | `text NOT NULL` | Hash corto del commit del motor. Sin esto, una señal de hace tres semanas no es interpretable |

**Invariante que el esquema obliga** (traducción literal del contrato que
verifica `test_contrato_scan.py`):
```sql
CHECK (
  (operable = true  AND leverage_recomendado IS NOT NULL AND sl IS NOT NULL AND tp IS NOT NULL)
  OR
  (operable = false AND leverage_recomendado IS NULL     AND sl IS NULL     AND tp IS NULL)
)
```
Esto es importante: en la Fase 1 esa coherencia la garantizaba un test de
Python. Ahora la garantiza la base de datos, así que **ninguna vía de
escritura** —ni un ETL con un bug, ni un `INSERT` manual en la consola de
Supabase— puede violarla.

---

### 3.3 Carteras dinámicas

#### `carteras`
`id`, `usuario_id` (FK perfiles), `nombre`, `tipo` (`'seguimiento'` \| `'simulador'`),
`es_predeterminada boolean`, `creado_en`.

Cada usuario tiene una cartera `'seguimiento'` creada por trigger al ser
aprobado. `'simulador'` es la que se vincula a una `cuentas_simulacion`.

#### `cartera_activos`
Tabla puente N:M. `cartera_id`, `activo_id` (PK compuesta), `añadido_en`,
`notas`. **Aquí muere el `UNIVERSO_ACCIONES` hardcodeado de `escaner.js`.**

#### `posiciones_reales` *(sucesora de `cartera_posiciones` de la Fase 1)*
La cartera importada por CSV. **Importes en claro** por la decisión D3.

`id`, `usuario_id`, `activo_id`, `precio_compra numeric(20,8) NOT NULL`,
`monto numeric(20,2) NOT NULL`, `creado_en`.

Dos diferencias respecto a la Fase 1. La primera: gana `usuario_id`, que
era exactamente lo que el comentario de `persistenciaCartera.js`
anticipaba («si en el futuro se soporta más de un usuario, esta es la
primera tabla que necesita esa columna»). La segunda: los dos campos de
texto cifrado pasan a ser numéricos.

> El nombre `posiciones_reales` se queda por continuidad con la Fase 1,
> pero significa «posiciones que el usuario declara tener», no «importes
> reales». Bajo D3 el sistema asume que ninguna cifra lo es. Si eso deja
> de ser cierto, hay que revisar la decisión **antes** de cargar los datos.

---

### 3.4 Simulador

#### `cuentas_simulacion`
| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `bigserial` PK | |
| `usuario_id` | `uuid` | FK perfiles — `NULL` si es de un agente |
| `agente_id` | `bigint` | FK agentes — `NULL` si es de un usuario |
| `saldo_inicial` | `numeric(20,2) NOT NULL` | 500 para los agentes; lo que el usuario declare |
| `saldo_disponible` | `numeric(20,2) NOT NULL` | Materializado desde el libro mayor |
| `saldo_bloqueado` | `numeric(20,2) NOT NULL DEFAULT 0` | Margen comprometido en órdenes abiertas |
| `capital_maximo_alcanzado` | `numeric(20,2) NOT NULL` | Para el drawdown **desde el pico** (regla nº2 de `maquina_fases.py`) |
| `fase` | `text NOT NULL DEFAULT 'fase_1_aceleracion'` | Espejo exacto del enum `Fase` de Python |
| `operaciones_en_fase` | `int NOT NULL DEFAULT 0` | |
| `riesgo_pct_operacion` | `numeric(5,2) NOT NULL DEFAULT 2.0` | |
| `max_posiciones_abiertas` | `int NOT NULL DEFAULT 3` | |
| `estado` | `text NOT NULL DEFAULT 'activa'` | `'activa'` \| `'pausada'` \| `'inoperante'` \| `'game_over'` |
| `creado_en`, `actualizado_en` | `timestamptz` | |

`CHECK ((usuario_id IS NOT NULL) <> (agente_id IS NOT NULL))` — exactamente
un titular. Y `saldo_disponible >= 0`, `saldo_bloqueado >= 0`.

> **`equity` no es una columna.** Es `saldo_disponible + saldo_bloqueado + pnl_no_realizado`,
> y el `pnl_no_realizado` depende del precio de este instante. Guardarlo como
> campo sería garantizar que esté desactualizado; se calcula en la vista
> `v_cuentas_equity` (§4).

#### `ordenes`
| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `bigserial` PK | |
| `cuenta_id` | `bigint NOT NULL` | FK |
| `activo_id` | `bigint NOT NULL` | FK |
| `senal_id` | `bigint` | FK `senales` — **la señal que justificó la entrada**. Sin esta columna no hay forma de auditar por qué un agente abrió una posición |
| `lado` | `text NOT NULL DEFAULT 'largo'` | `CHECK (lado = 'largo')` — regla protegida nº2 |
| `estado` | `text NOT NULL` | `'propuesta'` \| `'abierta'` \| `'cerrada'` \| `'cancelada'` \| `'rechazada'` |
| `origen` | `text NOT NULL` | `'recomendacion'` \| `'manual'` \| `'agente'` |
| `precio_entrada` | `numeric(20,8) NOT NULL` | Lo confirma el usuario (requisito 6) o lo fija el ciclo del agente |
| `fecha_entrada` | `timestamptz NOT NULL` | Declarada por el usuario; puede ser pasada |
| `cantidad` | `numeric(24,8) NOT NULL` | Unidades del activo |
| `apalancamiento` | `numeric(4,1) NOT NULL` | `CHECK (apalancamiento >= 1 AND apalancamiento <= 5)` |
| `nominal` | `numeric(20,2)` | Columna generada: `cantidad × precio_entrada` |
| `margen_comprometido` | `numeric(20,2) NOT NULL` | `nominal / apalancamiento` |
| `tp`, `sl` | `numeric(20,8) NOT NULL` | Obligatorios: no existe orden sin gestión de riesgo |
| `precio_liquidacion` | `numeric(20,8) NOT NULL` | `precio_entrada × (1 − 1/apalancamiento)` — riesgo R7 |
| `precio_salida` | `numeric(20,8)` | |
| `fecha_salida` | `timestamptz` | |
| `motivo_cierre` | `text` | `'tp'` \| `'sl'` \| `'liquidacion'` \| `'manual'` \| `'caducidad'` |
| `precio_observado_cierre` | `numeric(20,8)` | El precio que **disparó** el cierre, distinto del precio al que se liquida. Permite medir el deslizamiento que hoy no se modela |
| `pnl_bruto`, `pnl_pct` | `numeric` | Solo con `estado='cerrada'` |
| `racional` | `jsonb` | Por qué esta orden y no otra: candidatos descartados, prácticas aplicadas, déficit del día |
| `creado_en`, `actualizado_en` | `timestamptz` | |

`CHECK (tp > precio_entrada AND sl < precio_entrada)` — en largo, y solo hay
largo. Un TP por debajo de la entrada es un bug, no una estrategia.

#### `movimientos_saldo` — libro mayor *append-only*
`id`, `cuenta_id`, `orden_id` (nullable), `tipo`, `importe numeric(20,2)`,
`saldo_disponible_resultante`, `saldo_bloqueado_resultante`, `creado_en`.

`tipo` ∈ `'deposito_inicial'`, `'bloqueo_margen'`, `'liberacion_margen'`,
`'resultado_operacion'`, `'ajuste_manual'`.

Sin `UPDATE` ni `DELETE`: se revoca por RLS **y** por un trigger
`BEFORE UPDATE OR DELETE` que lanza excepción. Un libro mayor que se puede
editar no es un libro mayor.

#### `eventos_sistema`
Sucesora del `EventLog` en `localStorage`. `id`, `usuario_id` (nullable →
eventos globales), `agente_id` (nullable), `tipo` (`'cambio_fase'`,
`'deterioro'`, `'proveedor'`, `'orden_cerrada'`, `'game_over'`,
`'corte_semanal'`, `'backlog_nuevo'`), `mensaje`, `datos jsonb`, `creado_en`.
Es la tabla que alimenta Supabase Realtime, sustituyendo a `/ws/events`.

---

### 3.5 Agentes

#### `agentes`
| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `bigserial` PK | |
| `nombre` | `text NOT NULL UNIQUE` | `'Prudencia'` (2 %), `'Cadencia'` (5 %), `'Audacia'` (7 %) — nombres propios para que la vista de operaciones se lea |
| `objetivo_diario_pct` | `numeric(5,2) NOT NULL` | 2.00 / 5.00 / 7.00 |
| `objetivo_final` | `numeric(20,2) NOT NULL DEFAULT 1000000` | |
| `estrategia` | `jsonb NOT NULL` | Todos los parámetros operativos. Esquema en doc C §3.2 |
| `version_estrategia` | `int NOT NULL DEFAULT 1` | Sube cada vez que adopta una práctica o el corte semanal le ajusta algo |
| `estado` | `text NOT NULL DEFAULT 'activo'` | `'activo'` \| `'cuarentena'` \| `'pausado'` \| `'game_over'` |
| `creado_en`, `game_over_en` | `timestamptz` | |

Los parámetros viven en `estrategia jsonb` y **no** en el `.env`,
resolviendo la deuda técnica nº3 de la Fase 1: tres agentes necesitan tres
juegos de parámetros simultáneos, y una variable de entorno solo puede
tener un valor.

#### `agente_dias` — una fila por agente y día
`agente_id`, `fecha` (PK compuesta), `saldo_apertura`, `saldo_cierre`,
`objetivo_importe`, `pnl_realizado`, `rendimiento_pct`,
**`operable boolean`**, `cumplido boolean`, `ops_abiertas`, `ops_cerradas`,
`ops_tp`, `ops_sl`, `cerrado_en`.

> **`operable` es la columna que evita un falso negativo estructural.** Si el
> objetivo diario se evaluara sobre los 7 días naturales, un agente que opere
> solo acciones fallaría **siempre** sábado y domingo, y suspendería el corte
> semanal por calendario, no por estrategia. El corte evalúa
> `dias_cumplidos / dias_operables`. Detalle en doc C §5.2.

#### `agente_semanas` — el corte semanal
`agente_id`, `semana_iso` (PK compuesta, p. ej. `'2026-W39'`), `fecha_inicio`,
`fecha_fin`, `dias_operables`, `dias_cumplidos`, `ratio_cumplimiento`,
`veredicto` (`'validada'` \| `'aviso'` \| `'deficiente'`), `saldo_inicio`,
`saldo_fin`, `rendimiento_semanal_pct`, `drawdown_semanal_pct`,
`accion_correctiva jsonb`, `evaluado_en`.

#### `agente_backlog` — requisito 8
| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `bigserial` PK | |
| `agente_id` | `bigint NOT NULL` | Quién lo pidió primero |
| `tipo` | `text NOT NULL` | `'nueva_herramienta'` \| `'nuevo_dato'` \| `'ajuste_regla'` \| `'nuevo_activo'` \| `'reversion_fase'` \| `'sesgo_corto'` |
| `titulo`, `descripcion`, `justificacion` | `text NOT NULL` | |
| `evidencia` | `jsonb NOT NULL` | Órdenes, días y métricas concretas que sostienen la petición. **Sin evidencia no se inserta**: una petición sin datos es una opinión |
| **`clave_deduplicacion`** | `text NOT NULL` | `UNIQUE(tipo, clave_deduplicacion)`. Ver aviso abajo |
| `ocurrencias` | `int NOT NULL DEFAULT 1` | Se incrementa en vez de duplicar |
| `agentes_solicitantes` | `bigint[] NOT NULL` | Si los tres piden lo mismo, la prioridad es evidente |
| `prioridad_sugerida` | `int` | 1–5, calculada por el agente |
| `estado` | `text NOT NULL DEFAULT 'nuevo'` | `'nuevo'` \| `'en_revision'` \| `'aceptado'` \| `'rechazado'` \| `'implementado'` |
| `resolucion`, `revisado_por`, `revisado_en` | | Decisión humana |
| `creado_en`, `actualizado_en` | `timestamptz` | |

> **`clave_deduplicacion` no es una optimización, es lo que hace la tabla
> legible.** El ciclo del agente corre cada pocos minutos. Sin clave única, un
> agente al que le falten candidatos alcistas durante un mercado bajista
> insertaría «necesito sesgo corto» cientos de veces y la tabla dejaría de ser
> un backlog para convertirse en un log. Con ella, hay **una** fila con
> `ocurrencias = 340`, que además es la métrica que de verdad informa la
> decisión. La clave la genera el agente de forma determinista, p. ej.
> `'sesgo_corto:global'` o `'nuevo_activo:solana'`.

#### `mejores_practicas` — requisito 9
| Campo | Tipo | Notas |
|-------|------|-------|
| `id` | `bigserial` PK | |
| `agente_autor_id` | `bigint NOT NULL` | |
| `titulo` | `text NOT NULL` | |
| `contexto` | `text NOT NULL` | Qué observó |
| `regla` | `text NOT NULL` | La instrucción en una frase |
| **`condiciones`** | `jsonb NOT NULL` | **La parte ejecutable.** Predicado sobre los campos de `senales` que otro agente puede aplicar como filtro. Esquema en doc C §6.1 |
| `resultado_observado` | `jsonb NOT NULL` | `{"ops": 7, "tp": 6, "sl": 1, "pnl_medio_pct": 3.4, "rr_medio": 2.1}` |
| `confianza` | `numeric(4,3)` | `tp / ops`, con mínimo de 3 operaciones para publicarse |
| `estado` | `text NOT NULL DEFAULT 'propuesta'` | `'propuesta'` \| `'validada'` \| `'refutada'` \| `'archivada'` |
| `creado_en`, `actualizado_en` | `timestamptz` | |

#### `mp_adopciones` — el bucle que cierra el aprendizaje
`id`, `practica_id`, `agente_id`, `adoptada_en`, `abandonada_en`,
`ops_bajo_practica`, `resultado jsonb`, `veredicto` (`'mejoro'` \| `'neutro'` \| `'empeoro'`).

Esta tabla es la que convierte el requisito 9 de un tablón de anuncios en un
experimento: no basta con que los agentes se escriban consejos, hay que
**medir si adoptarlos cambió el resultado**. Una práctica cuyas adopciones
salen `'empeoro'` pasa a `estado='refutada'` automáticamente.

#### `mp_valoraciones`
`practica_id`, `agente_id` (PK compuesta), `valoracion smallint CHECK (valoracion IN (-1,0,1))`,
`comentario`, `creado_en`. Es el «leen» del requisito: cada agente valora las
prácticas ajenas que ha probado, y el ranking de lectura usa esta valoración.

---

## 4. Vistas

Las vistas no son azúcar sintáctico: son **la superficie que el frontend
consume**, y por eso también son la frontera de seguridad. El frontend nunca
hace `SELECT` contra una tabla base.

| Vista | Para qué | Regla que protege |
|-------|----------|-------------------|
| `v_velas_con_rango` | `precios_diarios WHERE rango_real = true` | Ningún cálculo de ATR o soporte/resistencia puede tocar velas reconstruidas. **Todo el código de indicadores lee de aquí** |
| `senales_vigentes` | Última `senales` por `activo_id` (`DISTINCT ON`) | Sustituye a `GET /api/scanner/signals` |
| `v_escaner_usuario` | `senales_vigentes ⋈ cartera_activos` del usuario | El escáner deja de ser un universo fijo y pasa a ser «mis activos» |
| `v_candidatos_rotacion` | Candidatos con `fuerza IN ('media','alta')` y `indicadores_alcistas > indicadores_bajistas` | Regla protegida nº3 (`>` estricto: capital nuevo). **No expone ninguna columna de importe** → regla nº6 |
| `v_cuentas_equity` | `saldo_disponible + saldo_bloqueado + pnl_no_realizado` con el precio vivo | Evita el campo `equity` desactualizado |
| `v_ordenes_abiertas_monitor` | Órdenes abiertas ⋈ `activos.ultimo_precio` **con filtro de antigüedad** | Riesgo R8: un precio añejo no cierra posiciones |
| **`v_operaciones_agentes`** | **Requisito 10.** Órdenes de agentes con nombre del agente, símbolo, resultado, R:R y el `racional` | La vista que alimenta la pantalla que pediste |
| `v_ranking_agentes` | Equity, % hacia 1 M$, racha de días cumplidos, drawdown, estado, último veredicto semanal | El marcador del experimento |
| `v_backlog_priorizado` | `agente_backlog` ordenado por `ocurrencias × nº agentes solicitantes` | Lo que de verdad hay que decidir |

---

## 5. Reglas de integridad que el esquema impone

### 5.1 Todo lo que cambia un saldo pasa por un RPC

Hay exactamente **cuatro** funciones autorizadas a tocar `ordenes` y
`movimientos_saldo`. Los clientes no tienen `INSERT` ni `UPDATE` sobre esas
tablas — solo `EXECUTE` sobre estas funciones:

| RPC | Qué valida antes de escribir |
|-----|------------------------------|
| `rpc_abrir_orden(cuenta, activo, senal, precio, fecha, apalancamiento, riesgo_pct)` | Cuenta `activa`; señal existente, `operable = true` y con menos de N minutos; `apalancamiento <= leverage_tope` **de la fase de esa cuenta**; `tp > precio > sl`; `ratio_rr >= mínimo`; margen `<= saldo_disponible`; posiciones abiertas `< max_posiciones_abiertas`; margen total comprometido `<= 60 %` del equity |
| `rpc_cerrar_orden(orden, precio_salida, motivo, precio_observado)` | `SELECT … FOR UPDATE` + `UPDATE … WHERE estado='abierta'`, comprobando filas afectadas. **Idempotente**: la segunda llamada devuelve «ya cerrada» sin tocar el saldo (riesgo R4, crítico) |
| `rpc_registrar_movimiento(...)` | Interna, `SECURITY DEFINER`; nadie la llama desde fuera |
| `rpc_evaluar_fase(cuenta)` | Traducción SQL de `maquina_fases.py`: drawdown desde el pico, múltiplo, contador de operaciones. **Nunca** revierte de Fase 2 a Fase 1 (regla protegida nº5) |

Y una quinta, solo para admins: `rpc_revertir_fase_manual(cuenta, confirmacion boolean)`,
que replica `revertir_a_fase1_manualmente()` y lanza excepción sin
`confirmacion = true`.

### 5.2 El saldo tiene que ser recalculable

Test obligatorio en la DoD de H-26:

```sql
-- Para toda cuenta, el saldo materializado debe coincidir con el libro mayor.
SELECT c.id,
       c.saldo_disponible,
       c.saldo_inicial + COALESCE(SUM(m.importe) FILTER (
         WHERE m.tipo <> 'deposito_inicial'), 0) AS recalculado
FROM cuentas_simulacion c
LEFT JOIN movimientos_saldo m ON m.cuenta_id = c.id
GROUP BY c.id, c.saldo_disponible, c.saldo_inicial
HAVING ABS(c.saldo_disponible - (c.saldo_inicial + COALESCE(SUM(m.importe) FILTER (
         WHERE m.tipo <> 'deposito_inicial'), 0))) > 0.01;
-- Debe devolver CERO filas. Si devuelve alguna, hay un bug de saldo.
```

Este test corre en cada pasada de CI y después de cada ciclo de agentes en
el entorno de pruebas. Es la red que hace que el riesgo R4 sea detectable
en minutos en vez de en semanas.

### 5.3 Cuotas como restricción, no como aviso

Trigger `BEFORE INSERT ON cartera_activos`: si el usuario ya tiene 25
activos → excepción con mensaje explicativo. Trigger
`BEFORE INSERT ON activos`: si ya hay 150 activos, o 20 de clase `'cripto'`
→ excepción. El límite tiene que estar en la BD porque el ETL y el
frontend son dos vías de alta distintas, y una cuota implementada solo en
el frontend no es una cuota.

---

## 6. Seguridad a nivel de fila (RLS)

### 6.1 La función que sostiene todo

```sql
CREATE OR REPLACE FUNCTION public.es_usuario_aprobado()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND estado = 'aprobado'
  );
$$;

CREATE OR REPLACE FUNCTION public.es_admin()
RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND estado = 'aprobado' AND rol = 'admin'
  );
$$;
```

`SECURITY DEFINER` porque la función tiene que poder leer `perfiles` aunque
la política de `perfiles` aún no haya concedido nada — si no, se entra en una
recursión de políticas. `STABLE` para que PostgreSQL la evalúe una vez por
consulta y no una vez por fila. `SET search_path` explícito: sin él, una
`SECURITY DEFINER` es un vector de escalada de privilegios de manual.

### 6.2 Matriz de acceso

| Tabla | Usuario aprobado | Usuario pendiente | Admin | ETL (`service_role`) |
|-------|------------------|-------------------|-------|----------------------|
| `perfiles` | `SELECT` propio, `UPDATE` de `nombre` | `SELECT` propio (para ver su estado) | Todo | Todo |
| `activos`, `precios_diarios`, `indicadores_diarios`, `senales` | `SELECT` | **Nada** | `SELECT` | Todo |
| `carteras`, `cartera_activos`, `posiciones_reales` | Todo, donde `usuario_id = auth.uid()` | **Nada** | `SELECT` | Todo |
| `cuentas_simulacion` | `SELECT` propia | **Nada** | `SELECT` | Todo |
| `ordenes` | `SELECT` propias + `SELECT` de agentes (requisito 10) | **Nada** | `SELECT` | Todo |
| `movimientos_saldo` | `SELECT` propias. **Nunca** `INSERT`/`UPDATE`/`DELETE` | **Nada** | `SELECT` | `INSERT` |
| `agentes`, `agente_dias`, `agente_semanas` | `SELECT` | **Nada** | `SELECT` | Todo |
| `agente_backlog`, `mejores_practicas`, `mp_*` | `SELECT` | **Nada** | `SELECT` + `UPDATE` de `estado`/`resolucion` | Todo |
| `auditoria_admin` | **Nada** | **Nada** | `SELECT` | `INSERT` |

> **Nota de implementación que cuesta un día si se descubre tarde**:
> `service_role` **elude RLS por diseño**. Su clave vive en los secretos de
> GitHub Actions y en los de las Edge Functions, y **jamás** en el bundle del
> frontend. El frontend usa exclusivamente la `anon key`. Un test de CI debe
> hacer `grep` del bundle compilado buscando el prefijo de la
> `service_role key`; si aparece, el build falla.

### 6.3 Política de ejemplo

```sql
ALTER TABLE public.ordenes ENABLE ROW LEVEL SECURITY;

-- Un usuario ve sus órdenes.
CREATE POLICY ordenes_select_propias ON public.ordenes
FOR SELECT TO authenticated
USING (
  public.es_usuario_aprobado()
  AND cuenta_id IN (
    SELECT id FROM public.cuentas_simulacion WHERE usuario_id = auth.uid()
  )
);

-- Y ve las de los agentes: son públicas para los aprobados (requisito 10).
CREATE POLICY ordenes_select_agentes ON public.ordenes
FOR SELECT TO authenticated
USING (
  public.es_usuario_aprobado()
  AND cuenta_id IN (
    SELECT id FROM public.cuentas_simulacion WHERE agente_id IS NOT NULL
  )
);

-- Nadie escribe directo: solo los RPC (SECURITY DEFINER). Sin política de
-- INSERT/UPDATE/DELETE para `authenticated`, la escritura queda denegada.
```

---

## 7. DDL de arranque (ejecutable)

Fragmento representativo — el resto sigue el mismo patrón y se entrega
completo como `supabase/migrations/0001_fase2.sql` en la historia H-08.

```sql
-- ─────────────────────────────────────────────────────────────────────
-- Fase 2 — migración 0001. PostgreSQL 15+ / Supabase.
-- Convención: nombres en español, igual que el resto del proyecto.
-- ─────────────────────────────────────────────────────────────────────

-- ── Gobierno ────────────────────────────────────────────────────────
CREATE TABLE public.perfiles (
  id             uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email          text NOT NULL,
  nombre         text,
  rol            text NOT NULL DEFAULT 'usuario'
                 CHECK (rol IN ('usuario','admin')),
  estado         text NOT NULL DEFAULT 'pendiente'
                 CHECK (estado IN ('pendiente','aprobado','rechazado','suspendido')),
  motivo_estado  text,
  aprobado_por   uuid REFERENCES public.perfiles(id),
  aprobado_en    timestamptz,
  creado_en      timestamptz NOT NULL DEFAULT now()
);

-- El primer usuario nace admin y aprobado: si no, nadie puede aprobar a nadie.
CREATE OR REPLACE FUNCTION public.trg_primer_usuario_es_admin()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.perfiles) THEN
    NEW.rol := 'admin';
    NEW.estado := 'aprobado';
    NEW.aprobado_en := now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER perfiles_primer_usuario
  BEFORE INSERT ON public.perfiles
  FOR EACH ROW EXECUTE FUNCTION public.trg_primer_usuario_es_admin();

-- ── Catálogo global ─────────────────────────────────────────────────
CREATE TABLE public.activos (
  id                 bigserial PRIMARY KEY,
  simbolo            text NOT NULL UNIQUE,
  clase              text NOT NULL CHECK (clase IN ('accion','cripto')),
  proveedor          text NOT NULL CHECK (proveedor IN ('yahoo','coingecko')),
  id_proveedor       text NOT NULL,
  nombre             text,
  moneda             text NOT NULL DEFAULT 'USD',
  estado             text NOT NULL DEFAULT 'pendiente_backfill'
                     CHECK (estado IN ('pendiente_backfill','activo','suspendido','invalido')),
  ultimo_precio      numeric(20,8),
  ultimo_precio_en   timestamptz,
  intentos           int NOT NULL DEFAULT 0,
  proximo_intento_en timestamptz,
  ultimo_error       text,
  creado_por         uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  primer_backfill_en timestamptz,
  ultimo_etl_en      timestamptz,
  creado_en          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX activos_pendientes_idx ON public.activos (proximo_intento_en)
  WHERE estado = 'pendiente_backfill';

CREATE TABLE public.precios_diarios (
  activo_id   bigint NOT NULL REFERENCES public.activos(id) ON DELETE CASCADE,
  fecha       date   NOT NULL,
  apertura    numeric(20,8),
  maximo      numeric(20,8),
  minimo      numeric(20,8),
  cierre      numeric(20,8) NOT NULL,
  volumen     numeric(24,4),
  -- FALSE para las velas de cripto reconstruidas sin máximo/mínimo reales.
  -- El ATR y el soporte/resistencia SOLO se calculan sobre rango_real = true:
  -- hacerlo sobre el frame completo inflaba el ATR de BTC un 16 %.
  rango_real  boolean NOT NULL DEFAULT true,
  origen      text NOT NULL,
  ingerido_en timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (activo_id, fecha)
);

CREATE VIEW public.v_velas_con_rango AS
  SELECT * FROM public.precios_diarios WHERE rango_real = true;

CREATE TABLE public.senales (
  id                              bigserial PRIMARY KEY,
  activo_id                       bigint NOT NULL REFERENCES public.activos(id) ON DELETE CASCADE,
  calculado_en                    timestamptz NOT NULL DEFAULT now(),
  precio_actual                   numeric(20,8),
  direccion                       text CHECK (direccion IN ('alcista','bajista','neutral')),
  sesgo_operativo                 text CHECK (sesgo_operativo IN ('largo','corto','sin_sesgo')),
  fuerza                          text CHECK (fuerza IN ('baja','media','alta')),
  indicadores_alcistas            int NOT NULL DEFAULT 0,
  indicadores_bajistas            int NOT NULL DEFAULT 0,
  resumen_confluencia             text,
  senales_detalle                 jsonb,
  operable                        boolean NOT NULL,
  atr_pct                         numeric(10,4),
  leverage_tope                   numeric(4,1) NOT NULL,
  leverage_recomendado            numeric(4,1),
  leverage_referencia_volatilidad numeric(4,1) NOT NULL,
  leverage_motivo                 text,
  soporte                         numeric(20,8),
  resistencia                     numeric(20,8),
  sl                              numeric(20,8),
  tp                              numeric(20,8),
  niveles_origen                  text CHECK (niveles_origen IN ('estructura','atr')),
  version_motor                   text NOT NULL,
  -- Ratio riesgo/beneficio. NUEVO en Fase 2: la Fase 1 emitía niveles sin
  -- comprobar que la operación mereciera la pena.
  ratio_rr numeric(10,4) GENERATED ALWAYS AS (
    CASE WHEN tp IS NOT NULL AND sl IS NOT NULL
          AND precio_actual IS NOT NULL
          AND precio_actual > sl
         THEN (tp - precio_actual) / (precio_actual - sl)
    END
  ) STORED,
  -- Traducción literal del contrato que verifica test_contrato_scan.py.
  CONSTRAINT senales_contrato_operable CHECK (
    (operable AND leverage_recomendado IS NOT NULL
               AND sl IS NOT NULL AND tp IS NOT NULL)
    OR
    (NOT operable AND leverage_recomendado IS NULL
                  AND sl IS NULL AND tp IS NULL)
  )
);

CREATE INDEX senales_activo_fecha_idx
  ON public.senales (activo_id, calculado_en DESC);

CREATE VIEW public.senales_vigentes AS
  SELECT DISTINCT ON (activo_id) *
  FROM public.senales
  ORDER BY activo_id, calculado_en DESC;

-- ── Simulador ───────────────────────────────────────────────────────
CREATE TABLE public.cuentas_simulacion (
  id                       bigserial PRIMARY KEY,
  usuario_id               uuid   REFERENCES public.perfiles(id) ON DELETE CASCADE,
  agente_id                bigint REFERENCES public.agentes(id)  ON DELETE CASCADE,
  saldo_inicial            numeric(20,2) NOT NULL CHECK (saldo_inicial > 0),
  saldo_disponible         numeric(20,2) NOT NULL CHECK (saldo_disponible >= 0),
  saldo_bloqueado          numeric(20,2) NOT NULL DEFAULT 0 CHECK (saldo_bloqueado >= 0),
  capital_maximo_alcanzado numeric(20,2) NOT NULL,
  fase                     text NOT NULL DEFAULT 'fase_1_aceleracion'
                           CHECK (fase IN ('fase_1_aceleracion','fase_2_consolidacion')),
  operaciones_en_fase      int NOT NULL DEFAULT 0,
  riesgo_pct_operacion     numeric(5,2) NOT NULL DEFAULT 2.0
                           CHECK (riesgo_pct_operacion > 0 AND riesgo_pct_operacion <= 10),
  max_posiciones_abiertas  int NOT NULL DEFAULT 3 CHECK (max_posiciones_abiertas BETWEEN 1 AND 10),
  estado                   text NOT NULL DEFAULT 'activa'
                           CHECK (estado IN ('activa','pausada','inoperante','game_over')),
  creado_en                timestamptz NOT NULL DEFAULT now(),
  actualizado_en           timestamptz NOT NULL DEFAULT now(),
  -- Exactamente un titular: usuario o agente, nunca ambos ni ninguno.
  CONSTRAINT cuenta_un_solo_titular
    CHECK ((usuario_id IS NOT NULL) <> (agente_id IS NOT NULL))
);

CREATE TABLE public.ordenes (
  id                      bigserial PRIMARY KEY,
  cuenta_id               bigint NOT NULL REFERENCES public.cuentas_simulacion(id) ON DELETE CASCADE,
  activo_id               bigint NOT NULL REFERENCES public.activos(id),
  senal_id                bigint REFERENCES public.senales(id),
  lado                    text NOT NULL DEFAULT 'largo' CHECK (lado = 'largo'),
  estado                  text NOT NULL DEFAULT 'abierta'
                          CHECK (estado IN ('propuesta','abierta','cerrada','cancelada','rechazada')),
  origen                  text NOT NULL CHECK (origen IN ('recomendacion','manual','agente')),
  precio_entrada          numeric(20,8) NOT NULL CHECK (precio_entrada > 0),
  fecha_entrada           timestamptz NOT NULL,
  cantidad                numeric(24,8) NOT NULL CHECK (cantidad > 0),
  apalancamiento          numeric(4,1)  NOT NULL CHECK (apalancamiento >= 1 AND apalancamiento <= 5),
  nominal                 numeric(20,2) GENERATED ALWAYS AS (cantidad * precio_entrada) STORED,
  margen_comprometido     numeric(20,2) NOT NULL CHECK (margen_comprometido > 0),
  tp                      numeric(20,8) NOT NULL,
  sl                      numeric(20,8) NOT NULL,
  precio_liquidacion      numeric(20,8) NOT NULL,
  precio_salida           numeric(20,8),
  fecha_salida            timestamptz,
  motivo_cierre           text CHECK (motivo_cierre IN ('tp','sl','liquidacion','manual','caducidad')),
  precio_observado_cierre numeric(20,8),
  pnl_bruto               numeric(20,2),
  pnl_pct                 numeric(10,4),
  racional                jsonb,
  creado_en               timestamptz NOT NULL DEFAULT now(),
  actualizado_en          timestamptz NOT NULL DEFAULT now(),
  -- Solo hay largos: un TP por debajo de la entrada es un bug, no una estrategia.
  CONSTRAINT orden_niveles_coherentes CHECK (tp > precio_entrada AND sl < precio_entrada),
  CONSTRAINT orden_cierre_completo CHECK (
    (estado = 'cerrada' AND precio_salida IS NOT NULL
                        AND fecha_salida  IS NOT NULL
                        AND motivo_cierre IS NOT NULL
                        AND pnl_bruto     IS NOT NULL)
    OR estado <> 'cerrada'
  )
);

-- Solo una orden abierta por cuenta y activo: simplifica el monitor y evita
-- que un agente promedie a la baja sin que nadie lo haya decidido.
CREATE UNIQUE INDEX ordenes_una_abierta_por_activo
  ON public.ordenes (cuenta_id, activo_id) WHERE estado = 'abierta';

CREATE TABLE public.movimientos_saldo (
  id                          bigserial PRIMARY KEY,
  cuenta_id                   bigint NOT NULL REFERENCES public.cuentas_simulacion(id) ON DELETE CASCADE,
  orden_id                    bigint REFERENCES public.ordenes(id) ON DELETE SET NULL,
  tipo                        text NOT NULL CHECK (tipo IN (
                                'deposito_inicial','bloqueo_margen','liberacion_margen',
                                'resultado_operacion','ajuste_manual')),
  importe                     numeric(20,2) NOT NULL,
  saldo_disponible_resultante numeric(20,2) NOT NULL,
  saldo_bloqueado_resultante  numeric(20,2) NOT NULL,
  creado_en                   timestamptz NOT NULL DEFAULT now()
);

-- Un libro mayor que se puede editar no es un libro mayor.
CREATE OR REPLACE FUNCTION public.trg_libro_mayor_inmutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'movimientos_saldo es append-only: % no permitido', TG_OP;
END $$;

CREATE TRIGGER movimientos_saldo_inmutable
  BEFORE UPDATE OR DELETE ON public.movimientos_saldo
  FOR EACH ROW EXECUTE FUNCTION public.trg_libro_mayor_inmutable();
```

> **Nota de orden de ejecución**: `cuentas_simulacion` referencia a `agentes`
> y `agentes` referencia a `cuentas_simulacion`. En la migración real se crea
> primero `agentes` sin la FK a cuentas, luego `cuentas_simulacion`, y la FK
> que falta se añade al final con `ALTER TABLE`. El fragmento de arriba
> muestra el esquema conceptual, no el orden literal del fichero.

---

## 8. El RPC crítico, entero

`rpc_cerrar_orden` merece verse completo porque es el punto donde el riesgo
R4 (doble cierre → saldo inflado) se vive o se muere. La clave es el
`FOR UPDATE` y el `WHERE estado = 'abierta'`.

```sql
CREATE OR REPLACE FUNCTION public.rpc_cerrar_orden(
  p_orden_id        bigint,
  p_precio_salida   numeric,
  p_motivo          text,
  p_precio_observado numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_orden   public.ordenes;
  v_cuenta  public.cuentas_simulacion;
  v_pnl     numeric(20,2);
  v_pnl_pct numeric(10,4);
  v_nuevo_disponible numeric(20,2);
  v_nuevo_bloqueado  numeric(20,2);
BEGIN
  -- Bloqueo pesimista: si dos pasadas del monitor entran a la vez, la
  -- segunda espera aquí y luego encuentra estado <> 'abierta'.
  SELECT * INTO v_orden
  FROM public.ordenes
  WHERE id = p_orden_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Orden % no existe', p_orden_id;
  END IF;

  -- Idempotencia: no es un error, es el caso normal en un monitor
  -- concurrente. Se devuelve sin tocar ni un céntimo del saldo.
  IF v_orden.estado <> 'abierta' THEN
    RETURN jsonb_build_object(
      'cerrada', false,
      'motivo',  'la orden ya estaba en estado ' || v_orden.estado
    );
  END IF;

  SELECT * INTO v_cuenta
  FROM public.cuentas_simulacion
  WHERE id = v_orden.cuenta_id
  FOR UPDATE;

  -- P&L apalancado sobre el margen comprometido.
  v_pnl := ROUND(v_orden.cantidad * (p_precio_salida - v_orden.precio_entrada), 2);
  v_pnl_pct := ROUND(
    ((p_precio_salida - v_orden.precio_entrada) / v_orden.precio_entrada) * 100, 4);

  -- El margen no puede perder más de lo comprometido: por debajo de eso hay
  -- liquidación, no deuda. Sin este clamp, un hueco de mercado dejaría el
  -- saldo en negativo y el CHECK (saldo_disponible >= 0) abortaría el cierre,
  -- dejando la orden abierta para siempre.
  IF v_pnl < -v_orden.margen_comprometido THEN
    v_pnl := -v_orden.margen_comprometido;
  END IF;

  v_nuevo_bloqueado  := v_cuenta.saldo_bloqueado  - v_orden.margen_comprometido;
  v_nuevo_disponible := v_cuenta.saldo_disponible + v_orden.margen_comprometido + v_pnl;

  UPDATE public.ordenes SET
    estado = 'cerrada',
    precio_salida = p_precio_salida,
    fecha_salida = now(),
    motivo_cierre = p_motivo,
    precio_observado_cierre = COALESCE(p_precio_observado, p_precio_salida),
    pnl_bruto = v_pnl,
    pnl_pct = v_pnl_pct,
    actualizado_en = now()
  WHERE id = p_orden_id AND estado = 'abierta';  -- cinturón y tirantes

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Carrera detectada al cerrar la orden %', p_orden_id;
  END IF;

  -- Dos movimientos, no uno: liberar el margen y aplicar el resultado son
  -- hechos distintos, y separarlos es lo que hace auditable el libro mayor.
  INSERT INTO public.movimientos_saldo
    (cuenta_id, orden_id, tipo, importe,
     saldo_disponible_resultante, saldo_bloqueado_resultante)
  VALUES
    (v_orden.cuenta_id, p_orden_id, 'liberacion_margen',
     v_orden.margen_comprometido,
     v_cuenta.saldo_disponible + v_orden.margen_comprometido, v_nuevo_bloqueado),
    (v_orden.cuenta_id, p_orden_id, 'resultado_operacion',
     v_pnl, v_nuevo_disponible, v_nuevo_bloqueado);

  UPDATE public.cuentas_simulacion SET
    saldo_disponible = v_nuevo_disponible,
    saldo_bloqueado  = v_nuevo_bloqueado,
    capital_maximo_alcanzado = GREATEST(
      capital_maximo_alcanzado, v_nuevo_disponible + v_nuevo_bloqueado),
    operaciones_en_fase = operaciones_en_fase + 1,
    actualizado_en = now()
  WHERE id = v_orden.cuenta_id;

  -- Máquina de fases y Game Over, en ese orden.
  PERFORM public.rpc_evaluar_fase(v_orden.cuenta_id);
  PERFORM public.rpc_evaluar_game_over(v_orden.cuenta_id);

  RETURN jsonb_build_object(
    'cerrada', true, 'pnl', v_pnl, 'pnl_pct', v_pnl_pct,
    'saldo_disponible', v_nuevo_disponible
  );
END $$;

REVOKE ALL ON FUNCTION public.rpc_cerrar_orden(bigint,numeric,text,numeric) FROM public;
GRANT EXECUTE ON FUNCTION public.rpc_cerrar_orden(bigint,numeric,text,numeric) TO service_role;
```

Tres detalles de este código que un dev reproduciría mal si no estuvieran
escritos:

1. **El `RETURN` temprano cuando la orden ya no está abierta** no lanza
   excepción. En un monitor que corre cada 30 segundos, encontrarse una orden
   ya cerrada es el caso normal, no el excepcional. Si lanzara, el log se
   llenaría de errores falsos y el verdadero se perdería.
2. **El clamp de la pérdida al margen comprometido** existe porque
   `saldo_disponible >= 0` es un `CHECK`. Sin el clamp, un hueco de mercado
   violaría el `CHECK`, la transacción abortaría, y la orden quedaría abierta
   **para siempre** — el peor fallo posible en un monitor automático.
3. **Dos filas en el libro mayor, no una.** Liberar el margen y aplicar el
   resultado son hechos económicos distintos. Fusionarlos en un movimiento
   neto hace imposible reconstruir cuánto margen estuvo comprometido y
   cuándo, que es justo lo que se necesita para auditar el riesgo de un
   agente.
