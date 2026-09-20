# Fase 2 — Equipo virtual, As-Is y decisiones de alcance

> **Autor**: Senior Project Manager / Arquitecto de Software (equipo virtual)
> **Fecha**: 2026-09-20
> **Estado**: Propuesta
> **Documentos hermanos**: `01-modelo-de-datos.md`, `02-arquitectura-y-stack.md`,
> `03-logica-de-agentes.md`, `04-sprint-backlog.md`

---

## 1. Conformación del equipo virtual

Siete roles. No son etiquetas decorativas: cada uno tiene una **firma de
aceptación** concreta sobre entregables concretos, y cuando dos roles
discrepan el documento registra quién ganó y por qué. Así funcionó la Fase 1
(el CHANGELOG está lleno de «checklist del Risk Manager punto #6», «caso de
prueba #2 de QA»), y esa trazabilidad es lo que hace que ocho reglas de
negocio hayan sobrevivido cuatro sprints sin que nadie las rompa por
descuido.

| Rol | Responsabilidad en esta fase | Entregable que firma |
|-----|------------------------------|----------------------|
| **Project Manager** (líder) | Cerrar las 7 decisiones abiertas, secuenciar los 6 sprints, proteger el alcance de la Fase 3 | `04-sprint-backlog.md` y este documento |
| **Arquitecto de Software** | Topología cloud, contratos entre servicios, decidir qué muere del backend Express y qué se porta | `02-arquitectura-y-stack.md` |
| **Data Engineer** | Modelo de datos, estrategia de caché e ingesta, presupuesto de cuotas de proveedor, idempotencia del ETL | `01-modelo-de-datos.md` §2–§5, doc B §6 |
| **Backend Developer** | RPCs de PostgreSQL, Edge Functions, motor de monitoreo, ciclo de agentes | Historias H-08…H-27 |
| **Frontend Developer** | Migración del React de Vite local a SPA cloud, pantalla de aprobación pendiente, panel admin, vista de agentes | Historias H-03, H-06, H-13, H-15, H-19, H-26, H-31, H-32 |
| **Analista Cuantitativo / Risk Manager** | Viabilidad matemática de las metas 2/5/7 %, guardarraíles, dimensionado de posición, regla de liquidación | `03-logica-de-agentes.md` §3–§5 |
| **QA / Ingeniero de Seguridad** | Suite de RLS, idempotencia del cierre de órdenes, no-regresión de los 69 tests, checklist OWASP del panel admin | Historias H-07, H-14, H-24, H-33, H-34 |

### 1.1 Las tres discrepancias ya resueltas dentro del equipo

Se dejan escritas porque son los puntos donde un dev nuevo tomará la
decisión contraria si nadie le dice que ya se discutió:

1. **Data Engineer vs. Ingeniero de Seguridad — cifrado de importes.**
   Seguridad pedía extender el AES-256-GCM de la Fase 1 a los saldos del
   simulador. Data Engineer objetó que un `monto_cifrado TEXT` impide
   `SUM()`, `ORDER BY` y cualquier evaluación de meta diaria en SQL: el
   corte semanal de los agentes pasaría a resolverse en aplicación,
   descifrando toda la tabla en cada pasada. **Gana Data Engineer**, con la
   condición de que el cifrado se mantenga intacto para la cartera real
   importada (decisión D3).
2. **Risk Manager vs. PM — metas diarias.** El PM quería las metas tal cual
   las pidió el dueño. El Risk Manager demostró (§4 del doc C) que sin techo
   de riesgo por operación la estrategia óptima para el agente del 7 % es
   apostar el saldo entero cada día, lo que convierte el experimento en un
   sorteo. **Gana Risk Manager**: las metas se mantienen literales, pero se
   añaden tres guardarraíles duros que el agente no puede sortear.
3. **Arquitecto vs. Backend — dónde corre el monitor de TP/SL.** Backend
   proponía un cron de Vercel por cercanía al frontend. El Arquitecto
   comprobó que el plan Hobby limita el cron a **una ejecución diaria**, lo
   que haría inútil el monitoreo. **Gana Arquitecto**: `pg_cron` dentro de
   Postgres, que admite intervalos de segundos.

---

## 2. Estado actual del sistema (As-Is, Fase 1)

Levantado leyendo el repositorio, no la documentación: `README.md`,
`CHANGELOG.md`, los 4 commits del historial y los 36 ficheros de código.

### 2.1 Topología actual

```
┌──────────────────┐    HTTP + WS     ┌─────────────────────┐   HTTP    ┌────────────────────┐
│ React + Vite     │ ───────────────► │ Node.js / Express   │ ────────► │ FastAPI (Python)   │
│ localhost:5173   │ ◄─────────────── │ localhost:3000      │ ◄──────── │ localhost:8001     │
│ (SPA, sin router)│   /ws/events     │ sesión en memoria   │ X-Internal│ motor analítico    │
└──────────────────┘                  └──────────┬──────────┘  -Token   └─────────┬──────────┘
                                                 │                                │
                                          ┌──────▼──────┐              ┌──────────▼──────────┐
                                          │ PostgreSQL  │              │ yfinance  CoinGecko │
                                          │ 2 tablas    │              │ (no oficial) (free) │
                                          └─────────────┘              └─────────────────────┘
```

Tres procesos que el usuario levanta a mano en tres terminales, un único
`.env` en la raíz que alimenta a los tres, y un PostgreSQL local con **dos
tablas**: `cartera_posiciones` y `registro_consentimiento`.

### 2.2 Inventario de código

| Módulo | Ficheros | Líneas | Qué contiene |
|--------|----------|--------|--------------|
| `motor-analitico/` | 8 + 6 tests | 1.660 + 1.427 | Conectores, indicadores técnicos, apalancamiento, máquina de fases, salud de posición, rotación |
| `backend/src/` | 10 | 803 | Express, 2 routers, sanitización CSV, cifrado AES-256-GCM, circuit breaker, WebSocket, persistencia |
| `frontend/src/` | 12 (JS/JSX) + 7 primitivas UI + 6 hojas CSS | 2.042 | SPA React, sistema de diseño «Instrumento» con tokens, guía de lectura |
| **Total** | **36** | **5.932** | 69 casos de prueba, todos en verde |

### 2.3 Activos reutilizables — el capital real de la Fase 1

Lo que **no hay que volver a construir**, y que condiciona todo el diseño
de la Fase 2:

- **El contrato de `/internal/scan`.** 20 campos con invariantes verificadas
  por `test_contrato_scan.py`: `operable`, `leverage_recomendado`, `sl` y
  `tp` son coherentes entre sí; ningún `NaN` llega al JSON. *Este payload se
  convierte tal cual en la tabla `senales`* (doc A §3.4), así que los devs
  ya conocen el esquema sin aprender nada nuevo.
- **Las ocho reglas de negocio protegidas** del README §«Reglas de diseño
  que el código protege». Se auditan una por una en §3 de este documento.
- **`riesgo/maquina_fases.py`.** Una máquina de estados ya escrita y
  testeada que hace exactamente lo que los agentes necesitan: multiplicador
  de capital, drawdown desde el pico, contador de operaciones, y un tope de
  apalancamiento que baja de 5× a 3× al entrar en Fase 2. Hoy **no está
  conectada a nada** — no hay ninguna llamada a `MaquinaFases` en el
  backend. La Fase 2 la enchufa por fin, una instancia por cuenta.
- **La reconstrucción de la vela diaria de cripto** (`coingecko.py`), con la
  disciplina de `rango_real`: solo los últimos 30 días tienen máximo y
  mínimo reales, y el ATR se calcula **solo** sobre esas filas. Calcularlo
  sobre el frame completo inflaba el ATR de BTC un 16 %. Esta distinción
  **tiene que viajar a la base de datos como columna** o se pierde.
- **El sistema de diseño «Instrumento»**: tokens CSS, cifras tabulares,
  color como información. Sobrevive intacto a la nube.
- **La guía de lectura** (`guia.js`), con las fórmulas transcritas del
  código real. Es deuda de mantenimiento pero también el mejor onboarding
  que existe para un dev nuevo.

### 2.4 Qué muere y qué se porta del backend Express

El Express de la Fase 1 existe por tres razones que la nube resuelve de
otro modo. No es una pérdida: es la simplificación que hace viable el
coste 0.

| Pieza actual | Destino en Fase 2 | Nota |
|--------------|-------------------|------|
| `server.js` (Express + sesión en memoria) | **Muere** | Supabase Auth emite JWT; la sesión en memoria no sobrevive a un entorno sin estado |
| `routes/escaner.js` | **Muere** como ruta | El universo deja de ser una constante en código y pasa a la tabla `activos`; el frontend lee `senales_vigentes` |
| `routes/portfolio.js` | **Se porta** a RPCs de PostgreSQL | La regla «el monto nunca viaja al motor de rotación» se traduce a que la vista de rotación no expone `monto` |
| `services/clienteMotorAnalitico.js` | **Muere** | El motor ya no se invoca en vivo: escribe en la BD |
| `services/circuitBreaker.js` | **Se porta a Python** | Sigue haciendo falta ante caídas de proveedor, pero dentro del ETL, con el último dato válido en la BD en vez de en memoria |
| `services/cifrado.js` | **Se porta** (uso reducido) | Solo para `posiciones_reales` — ver decisión D3 |
| `services/websocket.js` | **Muere** | Supabase Realtime sobre `postgres_changes` da lo mismo sin servidor |
| `middleware/sanitizacionArchivos.js` | **Se porta a Edge Function** | Imprescindible: la carga de histórico del simulador es un CSV de usuario. La lógica anti-fórmula-maliciosa se traduce a Deno/TS tal cual |
| `db/schema.sql` | **Se extiende**, no se reemplaza | Las dos tablas actuales ganan `usuario_id`; el resto es nuevo |

### 2.5 Deuda técnica que la Fase 2 hereda

Registrada sin adornos, con su tratamiento:

| # | Deuda | Impacto en Fase 2 | Tratamiento |
|---|-------|-------------------|-------------|
| 1 | `yfinance` no es API oficial; lanza `ErrorEsquemaInesperado` si Yahoo cambia su estructura | Un cambio de Yahoo deja sin señales a **todos** los usuarios a la vez | Aislar el fallo por clase de activo y marcar `activos.estado='suspendido'` sin tumbar el ETL de cripto (H-11) |
| 2 | CoinGecko free: ~10-15 req/min, **2 llamadas por cripto**, espaciado de 6 s | Techo duro al número de criptos del sistema completo | Cuota global de 150 activos (D7) + caché de un día en `precios_diarios` (H-09) |
| 3 | `LEVERAGE_HARD_CAP_FASE2` y las `FASE_TRANSICION_*` están en el `.env` pero **no se leen**: viven como defaults en `ParametrosRiesgo` | Cada agente necesita sus propios parámetros; tocarlos en el `.env` no tendría efecto | Los parámetros pasan a `agentes.estrategia` (jsonb) y a `cuentas_simulacion` — se leen de la BD, no del entorno (H-22) |
| 4 | El `EventLog` vive en `localStorage`: no viaja entre dispositivos | En multiusuario y con agentes, los eventos son datos compartidos | Tabla `eventos_sistema` + Realtime (H-32) |
| 5 | La guía de lectura transcribe fórmulas a mano; si cambian los umbrales, miente | La Fase 2 añade dimensionado de posición y reglas de agente | Test que compara los umbrales de `guia.js` con los del motor (H-34) |
| 6 | El circuit breaker guarda el último dato válido **en memoria del proceso** | En un ETL que arranca y muere en cada ejecución, esa memoria no existe | El «último dato válido» pasa a ser la propia tabla `senales` (H-11) |
| 7 | `sanitizacionArchivos.js` filtra por `file.mimetype`, que el cliente controla | En internet eso es un vector real | Validar por contenido, no por MIME declarado (H-21) |

---

## 3. Auditoría de las ocho reglas protegidas frente a la Fase 2

Esta tabla es el contrato con la Fase 1. **Seis reglas se mantienen
intactas; dos quedan tocadas** y necesitan tu aprobación explícita.

| # | Regla protegida (README Fase 1) | Estado en Fase 2 | Cómo se garantiza / qué cambia |
|---|--------------------------------|------------------|-------------------------------|
| 1 | El tope duro de apalancamiento nunca es superable; el suelo de 1× se aplica **antes** del `min()` | ✅ **Intacta y reforzada** | Deja de depender solo del Python: se añade un `CHECK (apalancamiento BETWEEN 1 AND 5)` en `ordenes` y una validación en `rpc_abrir_orden` contra el tope de la fase **de esa cuenta**. Un cliente no puede insertar una orden a 50× |
| 2 | Solo se encuadran operaciones **en largo**; con lectura bajista `recomendado = None` | ✅ **Intacta** | `ordenes.lado` tiene `CHECK (lado = 'largo')`. Los agentes que necesiten cortos deberán **pedirlo por `agente_backlog`** (decisión D6) — el sistema no se lo concede solo |
| 3 | Dominancia, no conteo absoluto: `>` en rotación (capital nuevo), `>=` en salud (capital expuesto) | ✅ **Intacta** | La asimetría se traslada literal: el filtro de candidatos de los agentes usa `>` (abre posición nueva); el cierre defensivo usa `>=` |
| 4 | Modo degradado **hacia el riesgo mínimo** ante volatilidad ausente | ✅ **Intacta y extendida** | `senales.operable = false` cuando falta ATR, y `rpc_abrir_orden` **rechaza** cualquier orden sobre una señal no operable. Se extiende al monitor: un precio con más de N minutos de antigüedad no cierra posiciones |
| 5 | Fase 2 → Fase 1 solo por acción **manual** explícita | ⚠️ **Intacta, con tensión nueva** | Un agente que alcance 3× su capital queda topado a 3× **para siempre** salvo que un humano lo revierta. Es coherente con la regla, pero frena la meta del millón: el agente lo detectará y abrirá un `agente_backlog` de tipo `reversion_fase`. **Ninguna reversión es automática** |
| 6 | El monto invertido **nunca** viaja al motor de decisión de rotación | ✅ **Intacta** | La vista que alimenta la rotación (`v_candidatos_rotacion`) no expone ninguna columna de importe. Se vuelve verificable por RLS y por test, no por convención |
| 7 | Todo dato de cartera persistido pasa por AES-256-GCM | 🔴 **TOCADA — requiere decisión D3** | Los saldos del simulador son **dinero ficticio** y deben ser agregables en SQL. Propuesta: cifrado **solo** en `posiciones_reales` (la cartera real importada); saldos y órdenes del simulador en `numeric` plano, protegidos por RLS + TLS + cifrado en reposo del proveedor |
| 8 | El borrado es físico (`DELETE`), nunca soft-delete | ✅ **Intacta** | `ON DELETE CASCADE` desde `perfiles` hacia todo lo del usuario. Se documenta la excepción: las órdenes de los **agentes** no se borran, porque son el registro del experimento, no datos personales |

> **Regla nueva nº9 que la Fase 2 añade al contrato**: el saldo de una cuenta
> de simulación es **derivado**, nunca un campo mutable de confianza. La verdad
> es el libro mayor `movimientos_saldo` (append-only); `cuentas_simulacion.saldo_*`
> es una materialización que un test debe poder recalcular desde cero. Ver doc A §5.2.

---

## 4. Las siete decisiones que necesitan tu firma

### D1 — Proveedor cloud ✅ *firmada el 2026-09-20*
**Supabase + Vercel + GitHub Actions.**

> **Restricción descubierta al implementar**: el tier gratuito de
> Supabase da dos proyectos activos y uno ya lo ocupa otra aplicación del
> dueño. El dashboard tiene **un solo proyecto y no hay staging remoto**.
> La compensación es `.github/workflows/migraciones.yml`, que aplica las
> migraciones desde cero sobre un PostgreSQL limpio en cada pull request
> y ejecuta doce invariantes del esquema. Detalle en el doc B §7.

Razonamiento completo en doc B §2. El resumen: AWS/GCP/Azure ofrecen tiers
gratuitos con tarjeta obligatoria y sin techo de gasto, lo que hace que
«coste 0» dependa de tu vigilancia. Supabase y Vercel tienen tiers gratuitos
**sin tarjeta** que cortan el servicio en vez de facturar — que es lo que
«coste 0» significa de verdad para un proyecto personal.

### D2 — El motor Python se mantiene
**Recomendación: sí.** Ya confirmada por ti. Reescribirlo a TypeScript
obligaría a reimplementar `pandas-ta`, y en particular la siembra de la
media de Wilder del ATR sobre un subconjunto de velas, que el
`requirements.txt` documenta como la razón para **fijar** `pandas-ta==0.4.71b0`.
Ese cálculo es reproducible hoy; una reimplementación movería el ATR% de
tramo sin que nada falle de forma visible. No merece el riesgo.

### D3 — Cifrado aplicativo de los importes del simulador 🔴
**Recomendación: NO cifrar los importes del simulador; mantener el cifrado
en la cartera real importada.**
Esto toca la regla protegida nº7, por eso es una decisión y no un detalle
de implementación. El argumento: el simulador necesita `SUM(pnl)` por día y
por agente para evaluar la meta diaria y el corte semanal. Con importes
cifrados, cada evaluación exige descifrar la tabla completa en aplicación.
Y el dato protegido no es comparable: la cartera real de la Fase 1 es tu
patrimonio; el saldo del simulador es un número inventado que empieza en
500 y cuyo interés es justamente que se pueda graficar y comparar entre
agentes. Si prefieres mantener la regla nº7 sin excepciones, el impacto es
+21 puntos de estimación y las metas se evalúan en una Edge Function en
vez de en SQL.

### D4 — Cerebro de los agentes
**Recomendación: determinista, con capa LLM opcional y aislada.**
Ya confirmada por ti. Diseño en doc C §2. La capa LLM, si algún día se
activa, **no decide operaciones**: solo redacta el campo `racional` de una
orden ya decidida y el texto de una entrada de `agente_backlog`. Así el
experimento sigue siendo reproducible y el coste sigue siendo 0.

### D5 — Repositorio público o privado 🔴
El repositorio contiene reglas de riesgo y un sistema de diseño, no
secretos (el `.env` está en `.gitignore` desde el primer commit —
verificado). **GitHub Actions es ilimitado en repos públicos y 2.000
min/mes en privados.** El presupuesto del doc B §6 cabe en 993 min/mes con
el repo privado, así que **la recomendación es mantenerlo privado** y
aceptar el techo. Pero si en algún momento quieres subir la cadencia del
ETL, hacerlo público es el único camino gratuito.
**Acción previa obligatoria si se hace público**: `git log -p | grep` en
busca de secretos históricos antes de cambiar la visibilidad.

### D6 — Sesgo corto para los agentes
**Recomendación: no en Fase 2.** La regla protegida nº2 es explícita: el
sistema no modela coste de préstamo ni funding, así que un setup de corto
sería engañoso. Consecuencia asumida: en un mercado bajista los tres
agentes se quedan sin candidatos y fallan su meta diaria. **Eso no es un
bug, es el dato**: los tres abrirán una entrada de `agente_backlog`
pidiendo cortos, y la frecuencia con que lo pidan es la mejor evidencia
para decidir si la Fase 3 los implementa.

### D7 — Techo de activos por usuario
**Recomendación: 25 por usuario, 150 globales, con cuota separada para
cripto (máximo 20 globales).**
No es una decisión de producto, es aritmética de proveedor: cada cripto
cuesta 2 llamadas a CoinGecko con espaciado de 6 s, así que 20 criptos son
~4 minutos de ETL solo en espera. Las acciones vía `yfinance` no tienen
cuota publicada pero sí coste de latencia. El techo se implementa como
`CHECK` + trigger, con mensaje de error explicativo (H-18).

---

## 5. Riesgos del proyecto

Ordenados por exposición (probabilidad × impacto), con dueño y disparador
de mitigación — no por gravedad narrativa.

| ID | Riesgo | Prob. | Impacto | Mitigación | Dueño |
|----|--------|-------|---------|------------|-------|
| R0 | **Una migración rota llega directa a producción**: no hay staging (el segundo proyecto del tier gratuito lo ocupa otra aplicación) y el plan free no tiene recuperación a un punto en el tiempo | Media | **Crítico** | `migraciones.yml` aplica el esquema desde cero sobre un PostgreSQL limpio en cada PR y corre 12 invariantes; verificado en negativo (quitar el CHECK, olvidar un RLS o resetear un search_path ponen el job en rojo). Más `supabase start` en local antes de cada `db push` | DevOps + Data Engineer |
| R1 | **Supabase pausa el proyecto** tras ~1 semana de baja actividad y los agentes se congelan | Media | Alto | El ETL escribe varias veces al día y `pg_cron` dispara cada minuto: actividad continua por diseño. Además, workflow semanal de *keep-alive* que hace un `SELECT 1` y alerta si falla (H-04) | DevOps |
| R2 | **Cuota de CoinGecko agotada** por crecimiento del universo cripto | Alta | Medio | Techo de 20 criptos globales (D7), caché de un día, y backoff con `proximo_intento_en` en `activos`. El ETL nunca reintenta un activo inválido | Data Engineer |
| R3 | **Yahoo cambia su estructura interna** y `yfinance` rompe todas las acciones a la vez | Media | Alto | El ETL captura `ErrorEsquemaInesperado` por clase de activo: cripto sigue funcionando. `senales` conserva la última lectura válida con su `calculado_en`, y la UI marca el dato como añejo en vez de vaciarse | Data Engineer |
| R4 | **Doble cierre de una orden** por dos pasadas concurrentes del monitor → saldo inflado | Media | **Crítico** | El cierre es un `rpc_cerrar_orden` con `SELECT … FOR UPDATE` y `UPDATE … WHERE estado='abierta'` verificando filas afectadas. Test de concurrencia obligatorio en la DoD (H-24, H-34) | Backend + QA |
| R5 | **El agente del 7 % muere en días** y el experimento no produce datos | Alta | Medio | Guardarraíles duros (doc C §4) + `estado='cuarentena'` con riesgo a la mitad tras dos semanas deficientes. El Game Over se conserva como resultado válido y se reinicia por acción manual, nunca automática | Risk Manager |
| R6 | **Un usuario pendiente de aprobación accede a datos** porque la puerta está solo en la UI | Media | **Crítico** | Supabase Auth **emite JWT a un usuario pendiente**: la puerta tiene que estar en RLS. Función `es_usuario_aprobado()` en **todas** las políticas + suite de tests de RLS que intenta el acceso con un JWT pendiente (H-14, H-34) | Seguridad |
| R7 | **Liquidación no modelada**: con 5× una caída del 20 % agota el margen, pero el SL puede estar más lejos | Media | Alto | `precio_liquidacion = entrada × (1 − 1/apalancamiento)`; el monitor cierra en `max(sl, precio_liquidacion)`. Es un hueco real del requisito original: solo mencionaba TP y SL (doc C §5.3) | Risk Manager |
| R8 | **Precio añejo cierra posiciones en fin de semana** (el viernes queda congelado en la tabla) | Alta | Medio | El monitor ignora precios con antigüedad > 15 min y, para acciones, solo evalúa en horario de mercado. Coherente con la regla protegida nº4 | Backend |
| R9 | **2.000 min/mes de GitHub Actions agotados** a mitad de mes → sin señales | Baja | Alto | Presupuesto de 993 min/mes (doc B §6) con 50 % de holgura; alerta al 70 % de consumo; salida de emergencia documentada: repo público | DevOps |
| R10 | **El alcance se desborda** hacia cierre parcial, trailing stop y cortos porque «los agentes lo piden» | Alta | Medio | Por eso existe `agente_backlog` con estado `nuevo`: las peticiones se **acumulan y se miden**, no se implementan. Revisión de backlog al cierre de cada sprint | PM |

---

## 6. Hoja de ruta

| Sprint | Objetivo | Historias | Puntos | Hito verificable |
|--------|----------|-----------|--------|------------------|
| 1 | Infraestructura cloud y CI/CD | H-01…H-07 | 35 | El dashboard de Fase 1, sin cambios funcionales, se abre desde una URL pública |
| 2 | Persistencia y catálogo de activos | H-08…H-12 | 26 | El escáner lee de PostgreSQL; ninguna petición del navegador toca una API externa |
| 3 | Autenticación y gobierno | H-13…H-16 | 26 | Un usuario nuevo queda `pendiente` y no ve ni un dato hasta que el admin lo aprueba |
| 4 | Carteras dinámicas e ingesta | H-17…H-21 | 30 | Un usuario busca un activo que el sistema no conocía y lo ve con histórico en < 3 min |
| 5 | Simulador y monitoreo | H-22…H-26 | 34 | Una orden con TP/SL se cierra sola y el saldo cuadra contra el libro mayor |
| 6 | Agentes, backlog y vista de operaciones | H-27…H-34 | 28 | Los tres agentes operan solos una semana completa y pasan su primer corte semanal |
| | **Total** | **34** | **179** | |

> Reestimado el 2026-09-20 al implementar el Sprint 1: el esquema del
> catálogo se adelantó de H-08 a H-01 porque los criterios de
> aceptación de H-01 y H-05 lo exigen. Detalle en el doc D.

Los sprints 1–3 son secuenciales duros. El 4 y el 5 pueden solaparse
parcialmente (el simulador no depende de la ingesta si se prueba con los
21 activos que el universo de la Fase 1 ya trae precargados).

---

## 7. Definición de Hecho (DoD) — aplica a las 34 historias

Una historia no se cierra sin las seis:

1. **Los 69 tests de la Fase 1 siguen en verde**, sin tocar una línea de test.
2. Tests nuevos para la lógica nueva. Nada que toque saldos, apalancamiento
   o estado de órdenes entra sin test.
3. Si la historia toca precios, señales, saldos o parámetros de riesgo,
   lleva **test de RLS** que verifique el acceso con un JWT de usuario
   pendiente y con uno de otro usuario.
4. Los ficheros nuevos respetan la regla de ubicación del README: lógica de
   análisis → `motor-analitico/`; API o servicio → Edge Function o RPC;
   interfaz → `frontend/src/`.
5. Si se cambia un umbral de riesgo, **`frontend/src/guia.js` se actualiza
   en el mismo commit**. El README es explícito: si no, la guía miente.
6. Entrada en `CHANGELOG.md` con el mismo nivel de detalle que las
   existentes: qué cambió, por qué, y el efecto medido cuando aplique.
7. **Si la historia toca `supabase/`, el workflow `migraciones` está en
   verde.** No hay proyecto de staging: esa comprobación es lo único que
   se interpone entre un pull request y la base de datos de producción, y
   el tier gratuito no incluye recuperación a un punto en el tiempo.
