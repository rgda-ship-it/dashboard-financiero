# D. Sprint Backlog — historias listas para desarrollo

> **Autor**: Project Manager (equipo virtual)
> **Fecha**: 2026-09-20
> **Estado**: Propuesta
> **Destinatario**: Devs y QA
> **34 historias · 179 puntos · 6 sprints**

> **Reestimado el 2026-09-20, durante la implementación del Sprint 1.**
> El esquema del catálogo (`activos`, `precios_diarios`,
> `indicadores_diarios`, `senales`) estaba asignado a H-08 en el
> Sprint 2, pero dos criterios de aceptación del Sprint 1 lo exigen y
> no se pueden cumplir sin él: H-01 pide una semilla con los 24
> activos del universo de la Fase 1 —y una semilla necesita la tabla
> `activos`— y H-05 pide que un `workflow_dispatch` manual escriba en
> `senales`. El esquema se adelanta; H-08 se reduce a lo que queda.
> **Sprint 1: 29 → 35 pts. Sprint 2: 31 → 26 pts.**

---

## Cómo está escrita cada historia

| Campo | Qué significa |
|-------|---------------|
| **Como / quiero / para** | El valor. Si no se puede escribir, la historia es una tarea técnica disfrazada y hay que justificarla como deuda |
| **Tareas técnicas** | Lo que hay que hacer. Cada una cabe en menos de un día |
| **Criterios de aceptación** | Verificables. Un criterio que no se puede ejecutar no es un criterio |
| **Depende de** | Bloqueos duros |
| **Pts** | Fibonacci: 2 = trivial, 3 = claro, 5 = requiere pensar, 8 = tiene incógnitas |

**Todas las historias comparten la DoD** del documento 0 §7. No se repite en
cada una: los 69 tests de la Fase 1 en verde, tests nuevos, test de RLS si
toca datos sensibles, ubicación de ficheros según el README, `guia.js`
actualizada si cambia un umbral, y entrada en `CHANGELOG.md`.

**Requisito → historias** (trazabilidad para el dueño):

| Requisito original | Historias |
|--------------------|-----------|
| 1. Despliegue en la nube | H-01…H-07 |
| 2. Capa de persistencia | H-08…H-12 |
| 3. Ingesta de nuevos activos | H-19, H-20 |
| 4. Autenticación y gobierno | H-13…H-16 |
| 5. Portafolios dinámicos | H-17, H-18, H-21 |
| 6. Simulador y gestión de riesgo | H-22…H-26 |
| 7. Agentes de trading | H-27, H-28 |
| 8. Backlog de agentes | H-30 |
| 9. Aprendizaje colaborativo | H-29 |
| 10. Vista de operaciones de agentes | H-31 |

---

# SPRINT 1 — Infraestructura cloud y CI/CD · 35 pts

**Objetivo del sprint**: el dashboard de la Fase 1, **sin un solo cambio
funcional**, se abre desde una URL pública. Nada más. Si en este sprint se
cuela una funcionalidad nueva, el equipo pierde el único momento en que
puede verificar que la migración no rompió nada.

---

### H-01 · Proyecto Supabase con migraciones versionadas · 8 pts
**Como** equipo de desarrollo, **quiero** los tres entornos definidos y el
esquema bajo control de versiones, **para** que ningún cambio de base de
datos se haga a mano.

**Tareas técnicas**
- Enlazar el proyecto Supabase de producción (el único disponible: el otro slot del tier gratuito lo ocupa otra aplicación del usuario).
- `supabase init` en el repo; carpeta `supabase/migrations/`.
- Migración `0000_base_fase1.sql`: portar `backend/db/schema.sql` tal cual, añadiendo `usuario_id` a las dos tablas existentes.
- Migración `0001_catalogo.sql` (adelantada de H-08): `activos`, `precios_diarios`, `indicadores_diarios`, `senales`, las vistas `v_velas_con_rango` y `senales_vigentes`, el `CHECK senales_contrato_operable`, la columna generada `ratio_rr` y `fn_retencion_senales()`.
- RLS activada en todas las tablas y **sin políticas**: eso deniega todo a `anon` y `authenticated` y deja pasar solo al ETL. Estado seguro por defecto hasta H-14.
- `supabase start` funcionando en local con Docker.
- Habilitar extensiones `pg_cron` y `pg_net`.
- Script de semilla con los 21 tickers de `UNIVERSO_ACCIONES` + los 3 de `UNIVERSO_CRIPTO` de `escaner.js`.

**Criterios de aceptación**
- `supabase db reset` reconstruye la base desde cero en local sin intervención manual.
- `SELECT * FROM cron.job;` responde sin error en el proyecto remoto.
- Documentado en el README que **ningún cambio de esquema se hace desde la consola web** (retención de logs = 1 día).

---

### H-02 · CI con los 69 tests de la Fase 1 como puerta de merge · 3 pts
**Como** dueño del producto, **quiero** que sea imposible mergear algo que
rompa las reglas de riesgo, **para** no descubrirlo en producción.

**Tareas técnicas**
- Workflow `tests.yml`: `python 3.12`, `pip install -r motor-analitico/requirements.txt`, `pytest motor-analitico/tests/ -v`.
- Protección de rama `main`: merge bloqueado si el workflow falla.
- Caché de dependencias pip para bajar de 90 s a ~30 s.

**Criterios de aceptación**
- Un PR que rompa deliberadamente el tope de apalancamiento **no se puede mergear**.
- Los 69 casos aparecen en el resumen del job, no solo el total.

---

### H-03 · Frontend de la Fase 1 desplegado en Vercel · 5 pts
**Como** usuario, **quiero** abrir el dashboard desde cualquier dispositivo,
**para** no depender de tres terminales en mi portátil.

**Tareas técnicas**
- Conectar el repo a Vercel con **Root Directory en la raíz**. La configuración vive versionada en `vercel.json` en la raíz: instala y compila dentro de `frontend/` y sirve `frontend/dist`. *(Cambiado el 2026-09-21: la primera versión dependía de fijar `Root Directory = frontend` en la interfaz, que es un ajuste fácil de elegir mal y que ninguna CI revisa.)*
- Configurar SPA fallback (todas las rutas → `index.html`).
- Variables `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` en Vercel.
- Verificar que las dos familias tipográficas de Google Fonts cargan y que las pilas de respaldo funcionan sin red.

**Criterios de aceptación**
- La URL pública muestra la terminal con su sistema de diseño intacto: tokens, cifras tabulares, medidores.
- El panel de datos muestra vacío con un mensaje claro (aún no hay backend) — **no** una pantalla rota.
- Lighthouse: sin errores de consola.

---

### H-04 · Keep-alive, backup semanal y retención · 3 pts
**Como** dueño, **quiero** que el proyecto no se pause ni pierda datos,
**para** que los agentes no se paren en silencio un fin de semana.

**Tareas técnicas**
- Workflow `keep-alive.yml` semanal: `SELECT 1`, y falla ruidosamente si no responde.
- `pg_dump` de `perfiles`, `ordenes`, `movimientos_saldo`, `agente_*`, `mejores_practicas` → artefacto de Actions con 90 días de retención.
- Job de retención de `senales` según la política del doc B §6.1 (30 días completos / 1 año comprimido / borrado, preservando las referenciadas por `ordenes.senal_id`).

**Criterios de aceptación**
- El artefacto de backup se descarga y restaura en un Supabase local.
- Tras ejecutar la retención con datos sintéticos de 14 meses, `SELECT COUNT(*) FROM senales` baja como se espera y **ninguna** señal referenciada por una orden desaparece.

---

### H-05 · Motor analítico ejecutándose como job programado · 8 pts
**Como** sistema, **quiero** que el motor corra sin servidor, **para** que
no haya nada que pagar ni que mantener despierto.

**Tareas técnicas**
- Workflow `etl.yml` con `schedule` y `workflow_dispatch`.
- `motor-analitico/escritor_supabase.py`: adaptador de salida (doc B §3.1). **No contiene lógica de análisis.**
- `motor-analitico/etl.py`: orquestación. Reutiliza `_escanear_ticker()` sin tocarlo, y memoiza `_obtener_ohlcv` para que cada cripto cueste **dos** llamadas y no cuatro — el mismo error que el CHANGELOG de la Fase 1 documenta como causa del 429.
- `motor-analitico/ventana_mercado.py`: lógica pura de horario de mercado, en su propio fichero por el mismo criterio con que se separó `riesgo/rotacion.py`.
- `version_motor` inyectado por el workflow (`${{ github.sha }}`).
- Tests sin red: 12 de `escritor_supabase` (el central: que `rango_real` se decida **por fila** y no por proveedor) y 9 de `ventana_mercado` (el central: que la misma hora UTC dé respuestas distintas en verano y en invierno).

**Criterios de aceptación**
- Un `workflow_dispatch` manual escribe filas en `senales` para los 24 activos de la semilla.
- Ni un solo `NaN` en la tabla: el `CHECK` del contrato no salta (invariante que ya verifica `test_contrato_scan.py`).
- El job imprime un resumen: activos procesados, fallidos, duración.
- **Cada cripto muestra ~30 velas con `rango_real = true` y cientos en `false`.** Si salieran todas en `true`, el ATR estaría calculándose sobre velas sin recorrido intradía: es el bug que infló el ATR de BTC un 16 %.
- El `atr_pct` de una señal recién escrita coincide con el que devuelve `/internal/scan` en local para el mismo ticker.

---

### H-06 · Cliente Supabase, router y esqueleto de rutas · 5 pts
**Como** usuario, **quiero** navegar entre secciones, **para** que el
dashboard deje de ser una sola pantalla.

**Tareas técnicas**
- `npm i @supabase/supabase-js react-router-dom`.
- `frontend/src/supabase.js` — cliente único, solo `anon key`.
- Rutas: `/` (escáner), `/cartera`, `/simulador`, `/agentes`, `/admin`, `/login`, `/pendiente`.
- Adaptar `useApi.js`: los hooks pasan de `fetch` al backend a consultas de Supabase, **conservando su firma** para no tocar los componentes.

**Criterios de aceptación**
- `useEscaner()` devuelve la misma forma de datos que hoy; `ScannerTable.jsx` no cambia ni una línea.
- La navegación no recarga la página.

---

### H-07 · Gestión de secretos y puerta anti-fuga en CI · 3 pts
**Como** responsable de seguridad, **quiero** que sea imposible publicar la
clave de servicio, **para** que un descuido no exponga la base entera.

**Tareas técnicas**
- Repartir los secretos según la tabla del doc B §5.
- Paso de CI posterior al build: `grep -r` del prefijo de la `service_role key` en `dist/`; si aparece, **el build falla**.
- Eliminar `ANALYTICS_SERVICE_INTERNAL_TOKEN` y `SESSION_SECRET` del `.env.example` y del README, con nota de por qué desaparecen.
- Reescribir la sección del README sobre el `.env` duplicado: ya no aplica en la nube.

**Criterios de aceptación**
- Un commit que meta la `service_role key` en el código del frontend **falla el build**, verificado con un commit de prueba en una rama.
- `.env.example` refleja exactamente las variables que el código lee.

---

# SPRINT 2 — Persistencia y catálogo de activos · 26 pts

**Objetivo**: el escáner lee de PostgreSQL. **Ninguna petición del navegador
toca una API externa.** Es el requisito 2 cumplido y verificable con la
pestaña de red del navegador.

> **Ejecución del Sprint 2 (2026-09-21).** Buena parte de lo que pedían
> H-09…H-12 ya había llegado con el Sprint 1 (UPSERT de precios e
> indicadores, `rango_real`, backoff, `invalido`, lectura desde la BD,
> retención en el keep-alive). El sprint se dedicó a los fallos reales
> que quedaban y a medir:
>
> | Historia | Qué se hizo | Evidencia |
> |---|---|---|
> | H-08 | `senales_vigentes` reescrita con `LATERAL … LIMIT 1` (migración `0006`). Con 265.650 señales sintéticas (150 activos, un año): **227 ms → 1,3 ms**, **266.985 → 605 buffers**. Retención probada con 14 meses: 30 d–1 año comprimido a 1 señal/día, > 1 año borrado. Invariante **I15** fija que el resultado no cambia | CI de migraciones |
> | H-09 | **Corrección de la spec**: «si la vela de hoy existe, no llamar» congelaba el precio de la vela en curso todo el día. Se sustituye por una **ventana de frescura** (mitad de la cadencia del cron: 15 min acciones, 30 min cripto) en `seleccion_universo.py`. El criterio «dos ejecuciones seguidas → cero llamadas» se cumple dentro de esa ventana | `test_seleccion_universo.py` |
> | H-10 | Selección pura y testeada: posición abierta primero (ignora frescura y tope), resto por `ultimo_etl_en` con nulos primero, tope `--max` | 12 + 5 tests |
> | H-11 | **Fallo corregido**: un activo `suspendido` nunca se reintentaba. Ahora vuelve a la rotación cuando vence su `proximo_intento_en`. Y **dejaba de verse** en el escáner: ahora sigue visible con su última lectura y el aviso «suspendido · hace N» | `test_etl_seleccion.py`, I15 |
> | H-12 | La antigüedad es **por fila y por clase** (`frescura.js`): cripto atrasada > 90 min; acciones solo con NY abierto y > 60 min. Antes un solo activo viejo marcaba «caché» el escáner entero y cada lunes las acciones salían añejas por el fin de semana. Cripto se reconoce por `activos.clase`, no por una lista fija | `npm test` (5 casos) |
>
> **Diferido a H-21 (Sprint 4), con motivo**: retirar `IDS_CRIPTO`,
> `_registrar_cripto_del_catalogo`, `escaner.js` y `circuitBreaker.js`.
> Los usa todavía el stack local de la Fase 1 —`analyze-position` lee
> `_ultimo_escaneo`, que puebla `/internal/scan`— y la cartera no se
> migra a la nube hasta H-21. Borrarlos ahora rompe el modo local sin
> ganar nada en la nube, que ya no los ejecuta.
>
> **No verificable desde aquí**: «el ATR de BTC coincide con
> `/internal/scan` ±0,01» exige el servidor local de la Fase 1; y
> «ningún 429 en 24 h» se lee en el historial de Actions tras un día.

---

### H-08 · Endurecer el catálogo: índices, retención aplicada y contrato · 3 pts
**Como** Data Engineer, **quiero** el catálogo afinado y con su contrato
verificado, **para** que soporte el volumen de un año sin sorpresas.

> El DDL se adelantó al Sprint 1 (ver la nota de reestimación al inicio).
> Esta historia es lo que quedó.

**Tareas técnicas**
- Verificar con `EXPLAIN` que `senales_vigentes` usa el índice y no un seq scan, con volumen realista (30 días × 150 activos).
- Tests de pgTAP del `CHECK senales_contrato_operable` y de la columna generada `ratio_rr`.
- Programar `fn_retencion_senales()` y validarla contra datos sintéticos de 14 meses.
- Retirar el diccionario `IDS_CRIPTO` de `servicio_interno.py` ahora que `activos.id_proveedor` lo sustituye, y con él la función puente `_registrar_cripto_del_catalogo` de `etl.py`.

**Criterios de aceptación**
- Un `INSERT` en `senales` con `operable = true` y `tp = NULL` **es rechazado** por la base de datos.
- `SELECT * FROM v_velas_con_rango` nunca devuelve una fila con `rango_real = false`.
- `EXPLAIN` de `senales_vigentes` usa el índice, no un seq scan.

---

### H-09 · El ETL escribe precios e indicadores; la caché es la tabla · 8 pts
**Como** sistema, **quiero** pedir cada dato al proveedor una sola vez,
**para** no agotar la cuota de CoinGecko ni hacer esperar a nadie.

**Tareas técnicas**
- `escritor_supabase.py`: `UPSERT` en `precios_diarios` con `ON CONFLICT (activo_id, fecha) DO UPDATE`.
- **Propagar `rango_real`**: `true` para `yfinance`; para CoinGecko, `true` solo en los días que vienen de `/ohlc` a 4 h.
- `UPSERT` en `indicadores_diarios` calculado **exclusivamente** sobre `v_velas_con_rango`.
- Actualizar `activos.ultimo_precio` y `ultimo_precio_en` en cada pasada.
- ~~Antes de llamar al proveedor, comprobar si la vela de hoy ya está: si está, se salta.~~ **Corregido en ejecución**: ventana de frescura por clase (ver nota del sprint).

**Criterios de aceptación**
- Dos ejecuciones seguidas del ETL: la segunda hace **cero** llamadas a CoinGecko (verificable en los logs del conector).
- El ATR de BTC calculado desde `indicadores_diarios` coincide con el que devuelve hoy `/internal/scan` (misma cifra, ±0,01).
- Insertar a mano una vela con `rango_real = false` y reejecutar el cálculo: el ATR **no cambia**.

---

### H-10 · ETL de cripto priorizado por cuota · 5 pts
**Como** sistema, **quiero** repartir las llamadas a CoinGecko, **para** no
exceder 2.000 minutos de GitHub Actions ni recibir un `429`.

**Tareas técnicas**
- Priorización por dos niveles (doc B §6.2): criptos con orden abierta → cada pasada; el resto → rotación por `ultimo_etl_en`, máximo 5 por pasada.
- Conservar el espaciado de 6 s y el respeto a `Retry-After` que ya implementa `coingecko.py`.
- Registrar la duración de cada pasada en el job summary.

**Criterios de aceptación**
- Con 20 criptos en el catálogo, una pasada procesa ≤ 6 y dura < 90 s.
- Una cripto con posición abierta se actualiza en **todas** las pasadas, comprobado en 3 ejecuciones consecutivas.
- Ningún `429` en 24 h de ejecución continua.

---

### H-11 · Resiliencia de proveedor: el fallo no se propaga · 5 pts
**Como** usuario, **quiero** que si Yahoo se rompe siga funcionando lo
demás, **para** no quedarme con la pantalla vacía.

**Tareas técnicas**
- Capturar `ErrorEsquemaInesperado` **por clase de activo**: un fallo de acciones no aborta el bloque de cripto.
- Backoff en `activos`: `intentos++`, `proximo_intento_en = now() + 2^intentos minutos`, `ultimo_error`.
- Tres fallos consecutivos → `estado = 'suspendido'`; el proveedor rechaza el símbolo → `estado = 'invalido'` (terminal, no se reintenta).
- El circuit breaker en memoria de `circuitBreaker.js` **se retira**: el último dato válido es la propia tabla `senales` con su `calculado_en`.
- La UI marca el dato añejo, reutilizando el tratamiento visual que ya existe para `desdeCache`.

**Criterios de aceptación**
- Con el conector de Yahoo forzado a fallar, el ETL termina con éxito y las criptos se actualizan.
- El escáner muestra las acciones con su última lectura válida y el aviso de antigüedad — **no** un «—» a secas, que en el lenguaje visual de la Fase 1 significa otra cosa.
- Un símbolo inventado (`ZZZZ`) acaba en `estado = 'invalido'` y **no se reintenta** en las 5 pasadas siguientes.

---

### H-12 · El escáner lee de la base de datos · 5 pts
**Como** usuario, **quiero** que el escáner cargue al instante, **para** no
esperar medio minuto al bloque de cripto.

**Tareas técnicas**
- `useEscaner()` pasa a consultar `senales_vigentes` (más adelante `v_escaner_usuario`).
- Mostrar `calculado_en` en la barra de estado, sustituyendo `ultimaActualizacion`.
- Retirar `GET /api/scanner/signals` y `escaner.js`.
- Política de retención de `senales` (doc B §6.1) como función SQL invocada desde el keep-alive.

**Criterios de aceptación**
- La pestaña de red del navegador **no muestra ninguna petición a yahoo.com ni a coingecko.com**. Este es el criterio que cierra el requisito 2.
- El escáner pinta en < 500 ms con 24 activos.
- La antigüedad del dato es visible sin abrir ningún panel.

---

# SPRINT 3 — Autenticación y gobierno · 26 pts

**Objetivo**: un usuario nuevo queda `pendiente` y **no ve ni un dato** hasta
que un administrador lo aprueba. Verificado con `curl`, no solo con la UI.

> **Ejecución del Sprint 3 (2026-09-22).** Migraciones `0007_gobierno.sql`
> y `0008_posiciones_reales.sql` (la `0002_gobierno` del plan ya estaba
> ocupada por las extensiones). Decisiones del dueño que cambian la spec:
>
> | Tema | Plan | Decisión | Por qué |
> |---|---|---|---|
> | Admin inicial | El primer usuario registrado | **Ligado a un correo** (`fn_email_admin_inicial()`), y solo al **confirmarlo**; una única vez | La web es pública: cualquiera podía registrarse antes que el dueño |
> | Verificación de correo | Activada | Activada, con el correo gratuito de Supabase | Coste 0; pocos usuarios |
> | H-16, cartera de la Fase 1 | Descifrar e importar | **No se ejecuta**: el dueño no tiene posiciones que conservar | Se hace el renombrado, el `activo_id` y las FK a `perfiles` |
>
> Otras diferencias con la spec, con motivo:
>
> - **Acceso inmediato al aprobar** sin Realtime: `/pendiente` relee su
>   propio perfil cada 15 s (una fila). Realtime llega en H-32; el RPC ya
>   deja la fila en `eventos_sistema` que lo alimentará.
> - **`ordenes`, `movimientos_saldo`, `agentes`** aún no existen (Sprint 5).
>   Sus políticas se escriben con ellas; I8 e I14 ya obligan a que nazcan
>   con RLS y sin nada para `anon`.
> - **`carteras`** se crea ahora (esqueleto) porque aprobar crea la
>   cartera de seguimiento; su gestión sigue en H-17.
> - Defensa en profundidad: además de no tener políticas, `anon` pierde
>   los privilegios de tabla en `public`.
> - `registro_consentimiento` pasa a `on delete set null`: al ser un
>   audit trail, borrar un usuario no debe borrar su rastro.
>
> Los criterios «con `curl`» se ejecutan en la CI como invariantes
> **I16–I21**, simulando el rol y el JWT de cada usuario igual que
> PostgREST (ver `supabase/pruebas/01_invariantes.sql`), y se repiten
> contra producción tras el despliegue.

---

### H-13 · Registro, login y pantalla de estado pendiente · 8 pts
**Como** persona interesada, **quiero** registrarme con usuario y
contraseña, **para** solicitar acceso al dashboard.

**Tareas técnicas**
- Migración `0002_gobierno.sql`: `perfiles`, `auditoria_admin`, trigger del primer usuario admin.
- Trigger `on_auth_user_created` → inserta en `perfiles` con `estado = 'pendiente'`.
- Habilitar el proveedor email/password en Supabase Auth; verificación de correo activada.
- Pantallas `/login`, `/registro`, `/pendiente`, recuperación de contraseña.
- Guardia de rutas: sesión sin perfil aprobado → redirección a `/pendiente`.

**Criterios de aceptación**
- El **primer** usuario registrado queda `admin` + `aprobado` automáticamente.
- El segundo queda `pendiente` y ve una pantalla que explica el estado, sin datos de mercado.
- Cerrar sesión y volver a entrar conserva el estado.

---

### H-14 · Row Level Security completa · 8 pts
**Como** responsable de seguridad, **quiero** que la puerta esté en la base
de datos, **para** que un JWT de usuario pendiente no lea nada aunque salte
la interfaz.

**Tareas técnicas**
- Funciones `es_usuario_aprobado()` y `es_admin()` con `SECURITY DEFINER`, `STABLE` y `SET search_path` (doc A §6.1).
- `ENABLE ROW LEVEL SECURITY` en **todas** las tablas de `public`, sin excepción.
- Políticas según la matriz del doc A §6.2.
- Revocar `INSERT`/`UPDATE`/`DELETE` a `authenticated` en `ordenes` y `movimientos_saldo`: solo RPC.
- **Retirar las cuatro políticas `*_temporal_h14`** de la migración 0005 (lectura pública de `activos`, `senales`, `precios_diarios`, `indicadores_diarios`), que mantienen el escáner visible sin login hasta este sprint por decisión del dueño (2026-09-21).
- Endurecer la invariante I14 a su forma final: **ninguna** política concede nada a `anon`.
- Toda vista nueva con `security_invoker = true` (la invariante I13 ya lo exige: sin ello una vista se salta la RLS, que es el fallo que se detectó en producción el 2026-09-21).

**Criterios de aceptación** *(se ejecutan con `curl`, no desde la UI)*
- Un JWT de usuario `pendiente` recibe **0 filas** de `activos`, `senales`, `precios_diarios`, `ordenes` y `agentes`.
- Sin JWT (clave `anon` sola) tampoco se lee nada: `select * from pg_policies where policyname like '%temporal_h14%'` devuelve cero filas.
- El usuario A no ve ni una fila de `carteras` del usuario B.
- Un `INSERT` directo en `movimientos_saldo` desde `authenticated` es **rechazado**.
- Una tabla sin política de RLS hace fallar un test que recorre `pg_tables` y comprueba `rowsecurity = true`.

---

### H-15 · Panel de administración · 8 pts
**Como** administrador, **quiero** aprobar o rechazar solicitudes, **para**
controlar quién entra.

**Tareas técnicas**
- Ruta `/admin`, visible solo con `rol = 'admin'` (guardia en el cliente **y** política de RLS).
- Listado de `perfiles` con filtro por estado.
- `rpc_aprobar_usuario`, `rpc_rechazar_usuario`, `rpc_suspender_usuario`: `SECURITY DEFINER`, exigen `es_admin()`, escriben en `auditoria_admin` y crean la cartera por defecto al aprobar.
- Rechazo y suspensión exigen `motivo_estado`; el RPC lo valida.
- Al aprobar, `eventos_sistema` recibe una fila → el usuario lo ve por Realtime sin recargar.

**Criterios de aceptación**
- Aprobar a un usuario le da acceso **inmediato**, sin volver a iniciar sesión.
- Suspender a un usuario con posiciones abiertas **no las borra**; solo bloquea el acceso.
- Toda acción deja fila en `auditoria_admin` con actor, objetivo y momento.
- Un usuario normal que fuerce la ruta `/admin` no obtiene datos (comprobado por API, no por UI).

---

### H-16 · Migración del usuario único de la Fase 1 · 2 pts
**Como** dueño, **quiero** conservar mi cartera de la Fase 1, **para** no
empezar de cero.

**Tareas técnicas**
- Script que asigna las filas existentes de `cartera_posiciones` y `registro_consentimiento` al perfil admin.
- Renombrar `cartera_posiciones` → `posiciones_reales` y añadir `usuario_id`, `activo_id`.
- **Descifrar al migrar**: las filas que existan en el PostgreSQL local de la Fase 1 están cifradas con AES-256-GCM. El script de migración las pasa por `backend/src/services/cifrado.js` para leerlas y las inserta como `numeric` (decisión D3). Es el ÚNICO uso que le queda a `PORTFOLIO_ENCRYPTION_KEY`, y después se puede retirar.

**Criterios de aceptación**
- Las posiciones preexistentes se descifran correctamente y quedan atribuidas al admin.
- `registro_consentimiento` conserva su histórico íntegro (es un audit trail: no se trunca).

---

# SPRINT 4 — Carteras dinámicas e ingesta · 30 pts

**Objetivo**: un usuario busca un activo que el sistema no conocía y lo ve
con histórico completo en menos de 3 minutos. Requisitos 3 y 5.

> **Ejecución del Sprint 4 (2026-09-22).** Migración `0010_carteras_ingesta.sql`
> (la `0003_carteras` del plan ya estaba ocupada). Decisiones del dueño:
>
> | Tema | Plan | Decisión |
> |---|---|---|
> | Arquitectura | Edge Functions `resolver-activo` e importación en Deno | **Sin Edge Functions**: RPC en PostgreSQL + `pg_net` → workflow `altas.yml`; el CSV se lee en el navegador y la BD valida cada fila |
> | D7 (cuotas) | Abierta | **25 por usuario (admin sin tope personal), 150 activos distintos, 20 criptos distintas** |
> | Cartera de un usuario nuevo | — | **Vacía**. El admin conserva los 24 de la Fase 1 |
>
> Diferencias con la spec, con motivo:
>
> - **Las cuotas cuentan activos DISTINTOS seguidos** (`activos.seguidores > 0`).
>   El coste de proveedor crece con activos distintos, no con usuarios. El
>   ETL solo refresca activos con seguidores. *(Desde la 0029, D20: el ETL
>   procesa todo el catálogo activo y las cuotas cuentan ese conjunto,
>   `fn_en_universo_etl`.)* Se aplican en un trigger de
>   `cartera_activos`, así que rigen también por la vía del workflow.
> - **Cripto se valida al instante** contra una copia local de
>   `/coins/list` (`catalogo_coingecko`, refresco semanal en keep-alive).
>   **Una acción** queda como solicitud y la valida el workflow con la
>   descarga que es a la vez su backfill (~1-2 min): `ZZZZ` se rechaza en
>   ese plazo, no al instante, y **nunca** crea fila en `activos`.
> - **Disparo**: `fn_disparar_altas()` usa un PAT de alcance mínimo en
>   Supabase Vault (`github_pat_altas`). Sin PAT, el ETL de cripto procesa
>   lo pendiente en su pasada horaria (red de seguridad).
> - **Sin Realtime**: la pantalla relee cada 10 s mientras hay algo
>   aprovisionándose (Realtime llega en H-32).
> - **CSV**: una celda con forma de fórmula (`=1+1`) se **excluye con su
>   motivo** en vez de guardarse neutralizada: nunca llega a la BD. Una
>   coma decimal sin comillas («AAPL,184,72,10») se excluye en vez de
>   leerse como precio 184 y monto 72. Los tickers sin catálogo se
>   importan y se ofrecen para añadirlos (no se dan de alta solos: gastarían
>   cuota sin pedirlo).
> - **Diferido otra vez: retirar `escaner.js`, `circuitBreaker.js` e
>   `IDS_CRIPTO`.** El semáforo de salud y la sugerencia de rotación de
>   la cartera siguen viviendo solo en el modo local (motor Python +
>   backend), y necesitan fundamentales (una llamada extra por activo)
>   para calcularse en la nube. Portarlo es una historia propia con su
>   presupuesto de cuota; hasta entonces el modo local se conserva
>   intacto y la nube no usa esos ficheros.
>
> Invariantes nuevas **I23–I29** (ver `supabase/pruebas/01_invariantes.sql`);
> tests Python 107 → 113; tests de frontend 5 → 12.

---

### H-17 · Carteras por usuario · 5 pts
**Como** usuario, **quiero** gestionar mi propia lista de activos, **para**
que el dashboard hable de lo que me interesa.

**Tareas técnicas**
- Migración `0003_carteras.sql`: `carteras`, `cartera_activos`.
- Trigger: al aprobar un usuario se crea su cartera de seguimiento.
- Vista `v_escaner_usuario` = `senales_vigentes ⋈ cartera_activos`.
- UI: añadir y quitar activos de la cartera desde el escáner.
- Retirar `UNIVERSO_ACCIONES` y `UNIVERSO_CRIPTO` de `escaner.js`; los 24 símbolos pasan a ser la semilla de la cartera del admin.

**Criterios de aceptación**
- El escáner muestra **solo** los activos de la cartera del usuario que ha iniciado sesión.
- Quitar un activo no borra su histórico de `precios_diarios` (es global y otro usuario puede estar usándolo).
- El usuario A no puede añadir activos a la cartera del usuario B (test por API).

---

### H-18 · Cuotas de activos · 4 pts
**Como** sistema, **quiero** limitar cuántos activos se siguen, **para** no
reventar la cuota de CoinGecko.

**Tareas técnicas**
- Trigger `BEFORE INSERT ON cartera_activos`: máximo 25 por usuario.
- Trigger `BEFORE INSERT ON activos`: máximo 150 globales, 20 de clase `'cripto'`.
- Mensajes de error explicativos, mostrados tal cual en la UI.
- Indicador de cuota consumida en la pantalla de cartera.

**Criterios de aceptación**
- El activo 26 de un usuario es rechazado con un mensaje que dice cuántos tiene y cuál es el límite.
- La cripto 21 global es rechazada aunque el usuario tenga hueco personal.
- Las cuotas se aplican también por la vía del ETL, no solo desde la UI.

---

### H-19 · Buscador y resolución de activos nuevos · 8 pts
**Como** usuario, **quiero** buscar cualquier acción o cripto, **para**
añadirla aunque el sistema no la conozca.

**Tareas técnicas**
- `rpc_buscar_activo(q)`: busca primero en `activos` (coincidencia instantánea).
- Edge Function `resolver-activo`: valida el símbolo contra el proveedor con **una** llamada ligera, detecta la clase y el `id_proveedor`.
- Caché de la lista de CoinGecko (`/coins/list`) refrescada semanalmente, para resolver cripto sin gastar cuota.
- Inserción en `activos` con `estado = 'pendiente_backfill'` + `cartera_activos`.
- Normalización de símbolo: acciones en mayúsculas, cripto en minúsculas (como hoy).

**Criterios de aceptación**
- Buscar `bitcoin` cuando ya está en el catálogo lo añade en < 300 ms, **sin llamadas externas**.
- Buscar `NVDA` por primera vez lo deja en `pendiente_backfill` y visible en la cartera con estado «aprovisionando».
- Buscar `ZZZZ` devuelve un mensaje de símbolo no reconocido y **no** crea fila en `activos`.

---

### H-20 · Backfill bajo demanda · 8 pts
**Como** usuario, **quiero** que el histórico del activo nuevo llegue solo,
**para** no esperar a la siguiente pasada programada.

**Tareas técnicas**
- Workflow `backfill.yml` con `workflow_dispatch` e input `simbolo`.
- `resolver-activo` dispara el workflow por la API de GitHub con un PAT de alcance mínimo (`actions:write` sobre este repo).
- Backfill: 2 años de velas para acciones; reconstrucción de 30 días con rango real para cripto — exactamente la lógica que ya implementa `coingecko.py`.
- Al terminar: `estado = 'activo'`, `primer_backfill_en`, fila en `eventos_sistema`.
- La UI escucha por Realtime y actualiza la fila sin recargar.
- Procesado por lotes con `FOR UPDATE SKIP LOCKED` para que dos backfills concurrentes no se pisen.

**Criterios de aceptación**
- Desde que el usuario pulsa «añadir» hasta que ve indicadores: **< 3 minutos**.
- La UI pasa de «aprovisionando» a datos completos **sin recargar**.
- Añadir el mismo activo desde dos cuentas a la vez dispara **un solo** backfill.
- Un activo cuyo backfill falla acaba en `suspendido` con `ultimo_error` visible para quien lo pidió.

---

### H-21 · Importación de cartera real (CSV) · 5 pts
**Como** usuario, **quiero** cargar mi cartera anterior, **para** partir de
mi situación real en el simulador.

**Tareas técnicas**
- Portar `middleware/sanitizacionArchivos.js` a una Edge Function en Deno, **conservando** la protección contra fórmulas maliciosas y el formato numérico con punto decimal.
- **Validar por contenido, no por `file.mimetype`** — el cliente controla el MIME declarado (deuda técnica nº7).
- **Sin cifrado** (decisión D3): los importes se guardan como `numeric`. La pantalla de importación debe decirlo con todas las letras — «los importes se guardan sin cifrar; este sistema asume que ninguna cifra es dinero real».
- Resolver cada ticker del CSV contra `activos`, disparando backfill si hace falta.
- Conservar el comportamiento de la Fase 1: las filas inválidas se excluyen con su motivo, **nunca** rompen la carga.
- Conservar la plantilla `cartera-modelo.csv` de `plantillaCartera.js`.

**Criterios de aceptación**
- Un CSV con una celda `=1+1` se importa con esa celda neutralizada.
- Un `.exe` renombrado a `.csv` es rechazado por contenido.
- 10 filas válidas y 2 inválidas → 10 posiciones creadas y 2 motivos de exclusión mostrados.
- La pantalla de importación advierte de que los importes no se cifran, antes de que el usuario suelte el fichero.

---

# SPRINT 5 — Simulador y monitoreo · 34 pts

**Objetivo**: una orden con TP y SL **se cierra sola** y el saldo cuadra
contra el libro mayor. Requisito 6.

> **Ejecución del Sprint 5 (2026-09-24).** Migración `0011_simulador.sql`
> (la `0004_simulador` del plan ya estaba ocupada por las vistas con
> `security_invoker`). Decisiones del dueño:
>
> | Tema | Plan | Decisión |
> |---|---|---|
> | Monitor (H-25) | Edge Function `monitor-ordenes` + `pg_cron` vía `pg_net` | **D8 — SQL puro sobre `pg_cron`**, sin Edge Functions, coherente con el Sprint 4 |
> | Precio fresco para M4 | No especificado | **D9 — `pg_net` a CoinGecko, una petición por pasada con todos los ids y solo si hay posiciones abiertas** |
> | Saldo inicial | 500 $ como los agentes | **D10 — lo elige el usuario**, entre 100 y 10.000 $ ficticios |
>
> Diferencias con la spec, con motivo:
>
> - **El monitor es SQL y no una Edge Function.** Lo que se gana: las
>   cuatro reglas M1–M4 se prueban en cada pull request sobre un
>   PostgreSQL limpio, que es la única validación automática que tiene
>   este proyecto sin staging. Lo que se pierde: PostgreSQL no puede
>   llamar a yfinance, y eso es lo que fuerza D9 y la ventana de frescura
>   partida del punto siguiente.
> - **La ventana de M4 se parte por clase: 15 min para cripto, 35 para
>   acciones.** El precio de una acción lo escribe el ETL cada 30 minutos,
>   así que con 15 la mitad de las pasadas no evaluarían nada. Lo que
>   protege del riesgo R8 en una acción es la otra condición, que es más
>   fuerte: no se evalúa ni una orden de acciones con la bolsa cerrada.
> - **`pg_net` es asíncrono**, así que el ciclo tiene tres fases en este
>   orden: cosechar la respuesta que pidió la pasada anterior, evaluar las
>   órdenes con esos precios y pedir los de la siguiente. Retraso máximo
>   entre el cruce de un nivel y el cierre: dos pasadas ≈ 2 minutos, que
>   es el criterio de aceptación de H-25.
> - **El paso 6 del dimensionado (doc 03 §5.3) tenía un fallo de orden**:
>   termina con `margen := nominal / apalancamiento` y descarta los topes
>   que el paso 5 acababa de aplicar. Bajar el apalancamiento SUBE el
>   margen necesario, así que tal cual está escrito puede devolver un
>   margen por encima del saldo o del tope de G3. Los topes se vuelven a
>   aplicar después del paso 6, en las dos implementaciones.
> - **`rpc_abrir_orden` no recibe el activo**: se deduce de la señal. Con
>   los dos como parámetros, un cliente podía mandar la señal de un activo
>   y el id de otro, y los tres niveles quedarían referidos al activo
>   equivocado.
> - **La función interna del libro mayor se llama
>   `fn_registrar_movimiento`**, no `rpc_registrar_movimiento` como la
>   nombra el doc 01 §5.1: en este esquema el prefijo decide los
>   privilegios (I22 e I23), así que llamarla `rpc_` y revocarla después
>   sería contradecir la convención que sostiene esas invariantes.
> - **`movimientos_saldo.orden_id` sin `on delete set null`**: poner la
>   columna a NULL es un `UPDATE` sobre el libro mayor y el trigger de
>   inmutabilidad lo rechaza, lo que dejaría imposible borrar una orden.
>   Con `no action` la relación se invierte y queda mejor: un apunte fija
>   su orden.
> - **`cuentas_simulacion.agente_id` sin clave ajena** hasta el Sprint 6,
>   tal como anticipa la nota de orden de ejecución del doc 01 §7.
> - **Dos parámetros de riesgo nuevos por cuenta** que el doc 01 §3.4 no
>   listaba y que G3 y G5 necesitan para no ser constantes de código:
>   `margen_comprometido_max_pct` (60 por defecto) y
>   `antiguedad_senal_max_min` (90). Y `ratio_rr_minimo` (1,5), que es el
>   «mínimo» al que se refiere el doc 01 §5.1 sin darle valor.
> - **Sin Realtime todavía** (H-32): la pantalla sondea cada 30 s, y solo
>   mientras haya posiciones abiertas. Sin nada abierto no hay nada que el
>   monitor pueda cambiar, así que una pestaña olvidada no gasta lecturas.
>
> **La prueba de concurrencia no es una invariante y no puede serlo.**
> `01_invariantes.sql` es una sola sesión de `psql`, y una sesión no
> compite consigo misma: el `FOR UPDATE` que protege del cierre doble no
> se ejercitaría nunca. Vive en `supabase/pruebas/02_concurrencia.sh`, que
> abre diez conexiones de verdad citadas a la misma hora con `pg_sleep`, y
> se comprobó contra una implementación ingenua a propósito (sin
> `FOR UPDATE` ni `WHERE estado`) para confirmar que se pone en rojo.
>
> **Un hallazgo del camino**: la invariante I11 solo fallaba a las 23:59.
> Sembraba tres señales como `now() - 60 días + g minutos`, y ejecutada en
> los últimos minutos del día cruzaban la medianoche, caían en dos fechas
> y la compresión dejaba dos filas. Ahora se anclan al mediodía. Una
> invariante que solo falla a una hora concreta es peor que no tenerla:
> enseña a desconfiar de la roja.
>
> **Y un fallo que llegó a producción, con su lección.** Aplicada la
> 0011, `/simulador` cargaba con «permission denied for function
> fn_tope_fase»: las vistas llevan `security_invoker` (I13), así que se
> ejecutan con el rol de quien consulta, y la 0011 había revocado las
> `fn_` a `authenticated` sin distinguir entre las que tocan datos y las
> puras. Lo arregla la 0012 concediendo las cinco puras, y I23 pasa a
> comprobar `prosecdef` —que es la propiedad que de verdad importaba—
> en vez del prefijo del nombre.
>
> Por qué no lo vieron las invariantes: este fichero probaba los RPC con
> el JWT de cada usuario, pero leía las VISTAS como dueño del esquema, y
> el dueño ejecuta cualquier función. La nueva **I40** lee todas las
> vistas con el rol `authenticated`. Y con un detalle que costó
> encontrar: usando `count(*)` solo detectaba dos de las tres vistas
> rotas, porque al contar PostgreSQL poda la lista de selección y no
> comprueba el permiso; hay que usar `select * … limit 0`.
>
> Invariantes nuevas **I30–I40**; prueba de concurrencia y cuadre de
> saldos como pasos propios de la CI; tests Python 118 → 133; tests de
> frontend 12 (sin cambios: la lógica nueva vive en el servidor).

---

### H-22 · Cuentas de simulación y libro mayor · 5 pts
**Como** usuario, **quiero** declarar un saldo inicial ficticio, **para**
empezar a simular.

**Tareas técnicas**
- Migración `0004_simulador.sql`: `cuentas_simulacion`, `movimientos_saldo`, `ordenes`.
- Trigger de inmutabilidad del libro mayor (`BEFORE UPDATE OR DELETE` → excepción).
- `rpc_crear_cuenta_simulacion(saldo_inicial)` con el movimiento `deposito_inicial`.
- Parámetros de riesgo por cuenta (`riesgo_pct_operacion`, `max_posiciones_abiertas`) **en la tabla**, no en el `.env` — deuda técnica nº3.
- Vista `v_cuentas_equity`.

**Criterios de aceptación**
- Un `UPDATE` sobre `movimientos_saldo` lanza excepción, incluso como `service_role`.
- `saldo_disponible` coincide exactamente con el libro mayor tras crear la cuenta.
- El `CHECK` de titular único rechaza una cuenta con `usuario_id` **y** `agente_id`.

---

### H-23 · Apertura de órdenes con los cinco guardarraíles · 8 pts
**Como** sistema de riesgo, **quiero** validar cada apertura en el servidor,
**para** que ningún cliente pueda saltarse los límites.

**Tareas técnicas**
- `rpc_abrir_orden` con G1–G5 (doc C §4).
- `motor-analitico/riesgo/dimensionado.py` — nuevo módulo, con la lógica del doc C §5.3 incluido el ajuste por liquidación.
- Cálculo y almacenamiento de `precio_liquidacion`.
- `CHECK (tp > precio_entrada AND sl < precio_entrada)`, `CHECK (lado = 'largo')`, índice único de una orden abierta por cuenta y activo.
- Movimiento `bloqueo_margen` en el libro mayor.

**Criterios de aceptación**
- Una orden a 6× es rechazada aunque el cliente la pida (G1).
- Una cuenta en `fase_2_consolidacion` no admite más de 3× (G1 + regla protegida nº1).
- Una orden sobre una señal con `operable = false` es rechazada (G5, regla protegida nº4).
- Una señal de hace 2 horas es rechazada por antigüedad.
- Si el SL queda por debajo del precio de liquidación, el apalancamiento **se reduce** en vez de abrirse la orden con el riesgo declarado mal.
- Tests unitarios del dimensionado con al menos 8 casos, incluido el de ajuste por liquidación.

---

### H-24 · Cierre idempotente, máquina de fases y Game Over · 8 pts
**Como** sistema, **quiero** que cerrar una orden dos veces no duplique el
P&L, **para** que los saldos sean fiables.

**Tareas técnicas**
- `rpc_cerrar_orden` completo (doc A §8): `FOR UPDATE`, `WHERE estado='abierta'`, retorno temprano idempotente, clamp de la pérdida al margen, **dos** movimientos en el libro mayor.
- `rpc_evaluar_fase`: traducción SQL de `maquina_fases.py` — drawdown **desde el pico**, múltiplo 3×, 8 operaciones. Un solo evento por llamada.
- `rpc_revertir_fase_manual(cuenta, confirmacion)`: excepción sin `confirmacion = true` (regla protegida nº5).
- `rpc_evaluar_game_over` con la distinción `game_over` / `inoperante` (doc C §5.5).

**Criterios de aceptación**
- **Test de concurrencia**: 10 llamadas simultáneas a `rpc_cerrar_orden` sobre la misma orden → **una sola** cierra, 9 devuelven «ya cerrada», el saldo se acredita **una vez**. Este es el riesgo R4 y el test es obligatorio.
- Una pérdida mayor que el margen deja el saldo en 0, nunca en negativo, y la orden **queda cerrada**.
- Los casos de prueba #2, #4 y #5 del Risk Manager de la Fase 1 se replican contra los RPC y pasan.
- `rpc_revertir_fase_manual` sin confirmación lanza excepción.

---

### H-25 · Motor de monitoreo automatizado · 8 pts
**Como** usuario, **quiero** que el sistema cierre mis posiciones solo,
**para** no tener que mirar la pantalla.

**Tareas técnicas**
- Edge Function `monitor-ordenes` con las reglas M1–M4 (doc C §5.4).
- `pg_cron` cada minuto vía `pg_net`.
- Vista `v_ordenes_abiertas_monitor` con filtro de antigüedad de precio (15 min).
- Refresco de `activos.ultimo_precio` solo para los activos con posición abierta.
- Para acciones, no evaluar fuera del horario de mercado.
- Evento en `eventos_sistema` por cada cierre → Realtime.

**Criterios de aceptación**
- Una posición cuyo precio cruza el TP se cierra en **≤ 2 minutos** y `precio_salida = tp` exacto.
- Con el precio por debajo de TP y SL a la vez, se cierra en **SL** (M2).
- Con `ultimo_precio_en` de hace 2 horas, la orden **no** se toca (M4).
- A 5× y una caída del 25 % con SL al 30 %, se cierra por `liquidacion`, no por `sl` (M1).
- El P&L registrado coincide con el recalculado a mano en los 4 escenarios.

---

### H-26 · Recomendaciones, confirmación de orden y UI del simulador · 5 pts
**Como** usuario, **quiero** ver entradas sugeridas y confirmar mis
operaciones, **para** operar con la lógica del sistema.

**Tareas técnicas**
- Vista `v_recomendaciones_usuario`: `senales_vigentes` operables de su cartera, con `ratio_rr` y el tamaño sugerido por `dimensionado`.
- UI de confirmación: el usuario ajusta **precio de entrada y fecha** (requisito 6), no los niveles.
- Panel del simulador: equity, saldo disponible, margen bloqueado, posiciones abiertas con P&L flotante, histórico.
- Reutilizar íntegramente los componentes de la Fase 1: `MedidorConfluencia`, `RielRiesgo`, `BarraApalancamiento`, tokens y cifras tabulares.
- **Test de cuadre de saldo** del doc A §5.2, en CI.

**Criterios de aceptación**
- La consulta de cuadre devuelve **cero filas** tras una sesión de 50 operaciones simuladas.
- La UI del simulador respeta el sistema de diseño: ningún color ni tamaño literal, todo desde tokens.
- El usuario puede registrar una fecha de entrada pasada y el P&L se calcula bien.

---

# SPRINT 6 — Agentes, backlog y observabilidad · 28 pts

**Objetivo**: los tres agentes operan solos una semana completa y pasan su
primer corte semanal. Requisitos 7, 8, 9 y 10.

> **Ejecución del Sprint 6 (2026-09-29).** Migración `0013_agentes.sql`
> (la numeración del plan —0005, 0006, 0007— ya estaba ocupada: las
> historias se agrupan en una sola migración, como en el Sprint 5).
> Decisiones del dueño:
>
> | Tema | Plan | Decisión |
> |---|---|---|
> | Ciclo y corte (H-27, H-28) | Edge Functions `ciclo-agentes` y `corte-semanal` | **D11 — SQL sobre `pg_cron`**, como D8 |
> | Universo | Sin especificar («la cartera del agente») | **D12 — todo el catálogo activo** |
> | Arranque | Sin especificar | **D13 — en pausa; los activa un admin**, auditado |
> | Entrega | — | **D14 — un solo PR** |
> | Poder de trading | No existía | **D15 — escalas QuantFury hasta 20×** como cifra aparte; el tope de 5×/3× sigue siendo la regla (0014) |
> | Reparto y aprendizaje | Cierre parcial fuera de la Fase 2 | **D16 — cupo por posición como recomendación, cantidad a mano, cierre parcial, rotación y ajuste de parámetros por decisión juzgada contra su contrafactual** (0016) |
> | Saldo para operar (2026-10-02) | El usuario veía el apalancamiento de cada posición y un cupo de margen ÷ 3 | **D17 — saldo para operar = equity × tope de la fase; cada posición muestra lo que consume (margen × tope); G3 al 100 % por defecto en cuentas de usuario; el saldo libre se reparte entre las sugerencias marcadas, ponderado por apalancamiento** (0022). Los agentes, igual (0023): 100 % del saldo, sin G4, y marcan según su exigencia —el mayor número de candidatas que aún cubre la meta en objetivo; si ninguno la cubre, el de más ganancia— y las abren todas a la vez. Y cierran la posición cuya señal empeora sin esperar a tener el saldo lleno (0024) |
> | Estrategia de Prudencia (2026-10-05) | Solo fuerza `alta`; pidió «Revisar la estrategia de Prudencia» tras una semana deficiente | **D18 — admite fuerza `media` o `alta`**; el resto de su perfil no cambia (0026). En 7 días, 388 de 833 señales alcistas operables de acciones fallaban solo por la fuerza. Se descartaron, con datos, un filtro de distancia mínima al stop (los stops pegados ganaron +29,76 $ y los sanos perdieron −21,64 $) y cambiar el disparador de cortos (el motor no lee un mercado bajista) |
> | Cadencia y Audacia (2026-10-05) | Abrían las mismas órdenes en el mismo minuto: el ATR ≥ 1,5 % de Audacia no filtraba nada y todas las candidatas de Cadencia eran también suyas | **D19 — se separan por volatilidad con un corte común de ATR 2,3 %**: Cadencia ≤ 2,3, Audacia ≥ 2,3 (0027). Probados 2,0–3,0 sobre 10 días de bolsa: entre 2,2 y 2,4 las dos tienen al menos 2 símbolos cada día; con 2,3, 5,1 y 4,1 de media |
> | Universo del ETL (2026-10-06) | El ETL solo refrescaba lo que alguien seguía, pero los agentes operan todo el catálogo activo (D12): NKE y tres tokens cripto seguían «activos» con la señal congelada | **D20 — el ETL procesa todo el catálogo activo, lo siga alguien o no, sin pasar los límites de los proveedores**: las cuotas globales (150 activos, 20 criptos) cuentan ese mismo conjunto (0029). Un suspendido que nadie sigue queda fuera. Y el backlog deja de pedir lo que no falta: la apertura (9:30–9:45 NY) no es señal añeja, «Ampliar el universo» solo cuenta ciclos con señales frescas, y una ocurrencia nueva reabre lo resuelto |
>
> Diferencias con la spec, con motivo (el detalle, en la cabecera de la
> migración):
>
> - **El corte corre los lunes a las 00:07 UTC** sobre la semana ISO que
>   acaba de terminar, no el domingo a las 23:59: a esa hora el domingo
>   aún no está cerrado y las órdenes del último minuto se perderían.
> - **Un dimensionado por debajo de 10 $ descarta el candidato** en vez
>   de marcar la cuenta `inoperante` (paso 8): ese margen pequeño suele
>   ser G3, no ruina, y `rpc_evaluar_game_over` la devolvería a `activa`
>   en el ciclo siguiente.
> - **Una ocurrencia del backlog es un par (agente, día)**, no un ciclo:
>   con 288 ciclos al día, el contador mediría el cron y no el problema.
> - **El riesgo reducido dura hasta la siguiente `validada`** (criterio de
>   H-28), no «la semana siguiente» (doc 03 §6.2): se contradicen y manda
>   el criterio de aceptación. No se acumula.
> - **Un agente en pausa no tiene días operables**, igual que Prudencia
>   no los tiene en fin de semana.
> - **Solo se adoptan prácticas compatibles** con el perfil del agente:
>   una de cripto dejaría a Prudencia sin ningún candidato.
> - **«Mejoró» se mide contra el valor absoluto** del rendimiento previo:
>   `despues > antes × 1,1` invierte el sentido con un `antes` negativo.
> - **Sin Edge Functions no hay `resolver-activo`** (se retiró en el
>   Sprint 4): el límite de 30 por minuto y usuario se aplica a
>   `rpc_buscar_activo` y `rpc_solicitar_activo`, que son su sucesor.
> - **H-34 ya estaba casi entero**: RLS en todas las tablas (I8),
>   `search_path` en toda `SECURITY DEFINER` (I9), concurrencia,
>   cuadre y guardarraíles son de sprints anteriores y corren en cada PR.
>   Lo nuevo es la coherencia de `guia.js`.
>
> **Un fallo que habría llegado a producción**: desde este sprint todo
> aprobado lee las cuentas de los agentes (requisito 10), y
> `leerCuenta()` del simulador cogía «la última cuenta visible». Un
> usuario sin cuenta habría visto la de Audacia como suya. Filtra ahora
> por el usuario de la sesión.
>
> Invariantes nuevas **I41–I53** (el ciclo y el corte de verdad, con un
> universo de señales controlado); se comprobó que I45, I47 e I48 se
> ponen en rojo al romper N9, N10 y el filtro de prácticas. Tests Python
> 133 → 143; frontend 12 → 17.

---

### H-27 · Ciclo de agente determinista · 5 pts
**Como** dueño, **quiero** tres agentes operando solos, **para** comparar
tres estrategias sobre el mismo mercado.

**Tareas técnicas**
- Migración `0005_agentes.sql`: `agentes`, `agente_dias`, `agente_semanas`.
- Semilla de los tres agentes con los perfiles del doc C §3.1 y su `estrategia` jsonb.
- Edge Function `ciclo-agentes` con los 10 pasos del doc C §5.1.
- `pg_cron` cada 5 minutos.
- `agente_dias` con la columna `operable` y el cierre del día anterior.
- `ordenes.racional` poblado con candidatos evaluados y descartados.

**Criterios de aceptación**
- Los tres agentes abren órdenes distintas sobre el mismo conjunto de señales (si abrieran las mismas, los perfiles no estarían diferenciando nada).
- Un agente que cumple su meta **deja de abrir** posiciones ese día (N9).
- `agente_dias.saldo_apertura` del día N coincide con `saldo_cierre` del día N−1 (interés compuesto verificado).
- Ningún agente supera sus guardarraíles: consulta que busca violaciones devuelve cero filas.
- Reejecutar el ciclo con el mismo estado produce **la misma decisión** (determinismo).

---

### H-28 · Corte semanal y acción correctiva · 5 pts
**Como** dueño, **quiero** que las semanas malas tengan consecuencias,
**para** que el experimento se autorregule.

**Tareas técnicas**
- Edge Function `corte-semanal`, `pg_cron` domingos 23:59 UTC.
- Cálculo sobre `dias_operables`, **nunca** sobre 7 (N10).
- Umbrales 0,70 / 0,40 y las cuatro consecuencias del doc C §6.2.
- Estado `cuarentena` tras dos semanas deficientes seguidas.
- Evento en `eventos_sistema` por cada veredicto.

**Criterios de aceptación**
- Un agente que solo opera acciones y cumple sus 5 días de mercado obtiene `validada`, **no** `aviso` — el calendario no lo penaliza.
- Tras una semana `deficiente`, `riesgo_pct_operacion` queda a la mitad y se restaura tras una `validada`.
- Dos `deficiente` seguidas dejan al agente en `cuarentena` con `max_posiciones_abiertas = 1`.

---

### H-29 · Aprendizaje colaborativo con efecto medido · 5 pts
**Como** dueño, **quiero** que los agentes compartan lo que funciona,
**para** ver si aprender entre ellos mejora el resultado.

**Tareas técnicas**
- Migración `0006_practicas.sql`: `mejores_practicas`, `mp_adopciones`, `mp_valoraciones`.
- `destilar_practica()` con el umbral de ≥ 3 operaciones y ≥ 66 % de acierto (N11).
- `condiciones` jsonb como predicado aplicable en el filtro de candidatos.
- Adopción en el corte semanal; evaluación del efecto a las 2 semanas.
- Auto-refutación tras 2 adopciones con veredicto `empeoro` (N12).
- Vista de lectura ordenada por valoración y confianza.

**Criterios de aceptación**
- Una práctica publicada por el agente A **cambia el conjunto de candidatos** del agente B que la adopta (verificable comparando `racional.candidatos_evaluados`).
- Una práctica con 2 adopciones fallidas pasa a `refutada` y deja de ofrecerse.
- Ninguna práctica se publica con menos de 3 operaciones de respaldo.

---

### H-30 · Backlog autónomo de agentes · 3 pts
**Como** dueño, **quiero** que los agentes me digan qué les falta, **para**
priorizar la Fase 3 con datos en vez de intuición.

**Tareas técnicas**
- Migración `0007_backlog.sql`: `agente_backlog` con `UNIQUE(tipo, clave_deduplicacion)` y `CHECK` de evidencia no vacía.
- Los 7 disparadores deterministas del doc C §8.
- Incremento de `ocurrencias` y `agentes_solicitantes` en vez de duplicar.
- Vista `v_backlog_priorizado`.
- UI de revisión en `/admin`: aceptar, rechazar, marcar implementado.

**Criterios de aceptación**
- Un agente sin candidatos alcistas 3 días seguidos crea **una** entrada `sesgo_corto`, no una por ciclo.
- Un `INSERT` sin evidencia es rechazado por la base de datos.
- Cuando los tres agentes disparan la misma clave, la fila sube a lo más alto de `v_backlog_priorizado`.

---

### H-31 · Vista de operaciones de agentes · 3 pts *(requisito 10)*
**Como** dueño, **quiero** ver qué están haciendo los agentes, **para**
seguir el experimento.

**Tareas técnicas**
- Vistas `v_operaciones_agentes` y `v_ranking_agentes`.
- Ruta `/agentes`: marcador con equity, % hacia 1 M$, racha de días cumplidos, drawdown, estado y último veredicto semanal.
- Tabla de operaciones con filtro por agente, estado y motivo de cierre; fila desplegable con el `racional` — el mismo patrón de fila expandible de `ScannerTable.jsx`.
- Gráfico de equity de los tres agentes **con la curva teórica** `500 × (1+p)^n` como referencia.
- Pestañas de `agente_backlog` y `mejores_practicas` en modo lectura.
- Actualización por Realtime, sin recargar.

**Criterios de aceptación**
- Un usuario aprobado ve las operaciones de los agentes **pero no las de otros usuarios** (RLS).
- Al abrir una operación se lee por qué el agente la eligió y qué descartó.
- El gráfico distingue claramente curva real y teórica, usando la semántica de color del sistema de diseño (verde/rojo solo para mercado).

---

### H-32 · Eventos del sistema en tiempo real · 2 pts
**Como** usuario, **quiero** que el registro de eventos sobreviva y viaje
entre dispositivos, **para** no perder el contexto al cambiar de equipo.

**Tareas técnicas**
- Tabla `eventos_sistema` y publicación Realtime.
- `EventLog.jsx` pasa de `localStorage` a suscripción de `postgres_changes`, conservando su aspecto y el botón de vaciar.
- Emisores: cambio de fase, deterioro, estado de proveedor, cierre de orden, Game Over, corte semanal, entrada de backlog.
- Retirar `services/websocket.js`.

**Criterios de aceptación**
- Un evento generado por el monitor aparece en la UI en < 3 s sin recargar.
- El histórico sobrevive al cierre de sesión y se ve igual en otro dispositivo.
- Los eventos globales (proveedor caído) llegan a todos; los de usuario, solo a su dueño.

---

### H-33 · Hardening de seguridad y aviso legal · 3 pts
**Como** responsable, **quiero** cerrar los huecos conocidos, **para** no
exponer el sistema ni inducir a error.

**Tareas técnicas**
- Revisión de las cabeceras de seguridad en Vercel (CSP, `X-Frame-Options`, `Referrer-Policy`).
- Rate limiting en las Edge Functions públicas (`resolver-activo` es la superficie más golpeable).
- Revisión de las funciones `SECURITY DEFINER`: todas con `SET search_path` explícito.
- **Aviso legal permanente**: el sistema es una simulación educativa, no asesoramiento financiero. Visible en el simulador y en la vista de agentes, no escondido en un pie.
- **El supuesto de D3, por escrito**: «ninguna cifra de este sistema es dinero real; los importes se guardan sin cifrar». No es una formalidad — es la condición que hace segura la decisión de no cifrar, y tiene que estar donde el usuario la vea antes de introducir un importe.
- Actualizar la sección «Límites que conviene conocer» de `guia.js` con las limitaciones nuevas: precisión del monitor de ~1 minuto, señales con la edad del ETL, sin cierre parcial ni trailing stop.

**Criterios de aceptación**
- Ninguna función `SECURITY DEFINER` sin `search_path` (consulta sobre `pg_proc` que lo verifica).
- El aviso legal es visible sin desplazarse en las dos pantallas, y recoge el supuesto de D3.
- `resolver-activo` limita a 30 peticiones por minuto y usuario.

---

### H-34 · Suite de verificación completa · 2 pts
**Como** equipo, **quiero** una batería que cubra los riesgos críticos,
**para** poder desplegar sin miedo.

**Tareas técnicas**
- **Test de RLS**: recorre `pg_tables` y falla si alguna tabla de `public` tiene `rowsecurity = false`; intenta el acceso con JWT pendiente, con JWT de otro usuario y sin JWT.
- **Test de concurrencia** del cierre de órdenes (10 llamadas simultáneas).
- **Test de cuadre de saldo** (doc A §5.2) contra un escenario de 50 operaciones.
- **Test de los guardarraíles**: intento programático de violar G1–G5, uno por uno.
- **Test de coherencia de `guia.js`**: compara los umbrales del texto con los del motor y falla si divergen (deuda técnica nº5).
- **No-regresión**: los 69 casos de la Fase 1, sin tocar.
- Todo en el pipeline de `main`.

**Criterios de aceptación**
- La suite completa corre en < 5 minutos.
- Romper deliberadamente cualquiera de los cinco guardarraíles hace fallar la suite.
- Cambiar un umbral en `riesgo/apalancamiento.py` sin tocar `guia.js` **hace fallar el build**.

---

## Riesgos de ejecución del backlog

| Historia | Por qué puede desbordarse | Señal temprana |
|----------|---------------------------|----------------|
| **H-09** | Propagar `rango_real` correctamente entre dos proveedores con semánticas distintas es más sutil de lo que parece; es el punto donde el ATR se corrompe en silencio | Si el ATR de BTC no coincide con el actual, parar y entender por qué antes de seguir |
| **H-14** | RLS parece sencilla hasta que aparece la recursión de políticas en `perfiles` | Si una consulta simple se cuelga, es recursión de políticas |
| **H-20** | El disparo del workflow y los permisos del PAT tienen mucha superficie de error | Si el `dispatch` devuelve 403, es alcance del token |
| **H-24** | Es la historia con más riesgo del proyecto (R4, crítico). El test de concurrencia debe escribirse **antes** que el RPC | Si el test de concurrencia no está escrito el segundo día, la historia va mal |
| **H-27** | El ciclo del agente tiene 10 pasos y muchos casos límite | Si los tres agentes abren la misma orden, los perfiles no están diferenciando |

## Lo primero que hay que hacer

1. Cerrar las **siete decisiones** del documento 0 §4, en especial **D3** y
   **D5**, que tocan reglas protegidas y no son reversibles a coste cero.
2. Enlazar el proyecto de Supabase. **No hay staging**: el otro slot del tier
   gratuito lo ocupa otra aplicación, así que la validación de migraciones vive
   en `.github/workflows/migraciones.yml` y en `supabase start` local.
3. **H-02 antes que nada**: con los 69 tests como puerta de merge desde el
   primer día, todo lo demás se construye sobre red.
