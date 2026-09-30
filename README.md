# Dashboard Financiero Personal

Terminal de inteligencia financiera para uso 100% personal: escanea un
universo de acciones/cripto en busca de confluencia técnica/fundamental,
calcula apalancamiento recomendado dentro de un tope duro de seguridad, y
diagnostica la salud de tu cartera cargada por CSV/Excel — sin costos de
licencia ni de infraestructura.

> Este documento es el mapa del proyecto: qué hace cada carpeta, cómo
> levantar cada servicio, y dónde va cada nuevo archivo que agregues.

**Estado: en migración a la nube (Fase 2).** El sistema arranca igual que
siempre en `localhost`, y además se despliega en un entorno cloud de
coste 0. La diferencia de fondo es la dirección del flujo: el motor
analítico ha dejado de RESPONDER peticiones para pasar a ESCRIBIR en
PostgreSQL, y el navegador lee de ahí. El análisis completo está en
[`docs/fase-2/`](docs/fase-2/); el arranque paso a paso, en
[`docs/fase-2/RUNBOOK-sprint-1.md`](docs/fase-2/RUNBOOK-sprint-1.md).

---

## Estructura del proyecto

```
dashboard-financiero/
├── .env.example              # Plantilla de variables de entorno — copiar a .env
├── .gitattributes             # LF en el repositorio (cierra el ruido CRLF de Windows)
├── .gitignore                 # Protege .env y artefactos generados
├── README.md                  # Este archivo
├── vercel.json                # FASE 2 — build en frontend/, SPA fallback, cabeceras de seguridad
│
├── .github/workflows/        # FASE 2 — el motor corre aquí, no en un servidor
│   ├── tests.yml              # Los 133 casos como puerta de merge
│   ├── migraciones.yml        # El esquema desde cero + 40 invariantes + concurrencia + cuadre
│   ├── frontend.yml           # Build + puerta anti-fuga de la clave de servicio
│   ├── etl-acciones.yml       # Escaneo de acciones en horario de mercado
│   ├── etl-cripto.yml         # Escaneo de cripto, 24/7, con rotación por cuota
│   ├── altas.yml              # Alta de activos nuevos (lo dispara la BD)
│   ├── backfill.yml           # Rehacer el histórico de un símbolo, a mano
│   └── keep-alive.yml         # Latido semanal + respaldo JSON + retención + catálogo CoinGecko
│
├── supabase/                 # FASE 2 — el esquema, versionado
│   ├── config.toml
│   ├── pruebas/               # Lo que sustituye al staging que el tier gratuito no da
│   │   ├── 00_stubs_supabase.sql   # auth.users y los tres roles, para un Postgres limpio
│   │   ├── 01_invariantes.sql      # 40 invariantes del esquema
│   │   ├── 02_concurrencia.sh      # 10 cierres simultáneos de la misma orden (riesgo R4)
│   │   └── 03_cuadre_saldos.sql    # 50 operaciones y el cuadre del libro mayor
│   └── migrations/
│       ├── 0000_base_fase1.sql  # Port del schema.sql de la Fase 1 + usuario_id
│       ├── 0001_catalogo.sql    # activos, precios, indicadores, señales, vistas
│       ├── 0002_extensiones.sql # pg_cron y pg_net (lo único que exige Supabase)
│       ├── 0003_semilla_...sql  # Los 24 activos del universo de la Fase 1
│       ├── 0004_vistas_...sql   # Las vistas respetan la RLS (security_invoker)
│       ├── 0005_lectura_...sql  # Lectura pública de mercado, temporal hasta H-14
│       ├── 0006_senales_...sql  # senales_vigentes con LATERAL: 1 lectura por activo
│       ├── 0007_gobierno.sql    # Perfiles, aprobación por admin, RLS completa
│       ├── 0008_posiciones_...sql # cartera_posiciones -> posiciones_reales
│       ├── 0009_rpc_sin_anon.sql # anon no ejecuta ningún RPC
│       ├── 0010_carteras_...sql # Carteras, cuotas D7, altas y posiciones CSV
│       ├── 0011_simulador.sql   # Cuentas, órdenes, libro mayor, guardarraíles y monitor
│       ├── 0012_permisos_...sql # Las vistas necesitan ejecutar sus funciones puras
│       ├── 0013_agentes.sql     # Agentes, corte semanal, prácticas, backlog, Realtime y límites de uso
│       ├── 0014_poder_trading.sql # Poder de trading por escalas (D15), aparte del tope de 5×
│       ├── 0015_etl_disparado_...sql # pg_cron dispara el ETL: el schedule de GitHub no llegaba
│       ├── 0016_decisiones_...sql # Cupo, cantidad a mano, cierre parcial, rotación y aprendizaje (D16)
│       ├── 0017_minimo_una_accion.sql # Una acción entera si el riesgo no llega, dentro de G2
│       ├── 0018_retencion_y_respaldo.sql # Retención de eventos y respaldo del experimento
│       └── 0019_solo_acciones_usd.sql # Cortafuegos: solo acciones que coticen en USD
│
├── scripts/
│   ├── resumen_tests.py       # Resumen de la suite para el job summary de Actions
│   ├── aplicar-migraciones.cmd # ÚNICA vía para aplicar migraciones (comprueba la CI antes)
│   └── verificar_paso_7.sql   # Verificación del ETL para el SQL Editor
│
├── docs/                      # Análisis y propuestas técnicas (no código)
│   ├── propuesta-velas-ventanas.md  # Velas diarias coherentes entre acciones y cripto
│   └── fase-2/                # Análisis completo de la Fase 2 (6 documentos)
│
├── motor-analitico/           # Python — el "cerebro" del sistema
│   ├── requirements.txt
│   ├── servicio_interno.py    # FastAPI — expone el motor a Node.js
│   ├── etl.py                 # FASE 2 — punto de entrada del job programado
│   ├── escritor_supabase.py   # FASE 2 — adaptador de salida hacia PostgreSQL
│   ├── ventana_mercado.py     # FASE 2 — ¿está abierta la bolsa? (lógica pura)
│   ├── riesgo/dimensionado.py # FASE 2 — cuántas unidades comprar (lógica pura)
│   ├── seleccion_universo.py  # FASE 2 — qué activos procesa cada pasada (lógica pura)
│   ├── altas.py               # FASE 2 — valida y rellena activos nuevos (workflow altas)
│   ├── catalogo_cripto.py     # FASE 2 — copia semanal de /coins/list de CoinGecko
│   ├── respaldo.py            # FASE 2 — latido, respaldo JSON y retención (vía REST)
│   ├── conectores/
│   │   ├── yahoo_finance.py   # Acciones (vía yfinance, no oficial — aislado como adaptador)
│   │   └── coingecko.py       # Cripto (API pública gratuita)
│   ├── indicadores/
│   │   └── tecnicos.py        # SMA, RSI, MACD, ATR, lógica de confluencia
│   ├── riesgo/
│   │   ├── apalancamiento.py  # Cálculo de leverage recomendado (con tope duro)
│   │   ├── maquina_fases.py   # Máquina de estados Fase 1 (Aceleración) / Fase 2 (Consolidación)
│   │   ├── salud_posicion.py  # Score de salud del Portfolio Health Selector
│   │   └── rotacion.py        # Selección de mejor oportunidad para sugerir rotación
│   └── tests/
│       ├── test_apalancamiento.py  # Tope duro, sesgo operativo, modo degradado
│       ├── test_contrato_scan.py   # Invariantes del payload de /internal/scan
│       ├── test_maquina_fases.py
│       ├── test_rotacion.py
│       └── test_salud_posicion.py
│
├── backend/                   # Node.js — API pública + orquestación
│   ├── package.json
│   ├── db/
│   │   └── schema.sql         # Esquema PostgreSQL (cartera cifrada + consentimientos)
│   └── src/
│       ├── server.js          # Punto de entrada — Express (el WebSocket se retiró en el Sprint 6)
│       ├── routes/
│       │   ├── escaner.js     # GET /api/scanner/signals
│       │   └── portfolio.js   # Carga, diagnóstico, restauración y borrado de cartera
│       ├── middleware/
│       │   └── sanitizacionArchivos.js  # Sanitización CSV (fórmulas maliciosas, etc.)
│       └── services/
│           ├── clienteMotorAnalitico.js # Cliente HTTP hacia el motor Python
│           ├── circuitBreaker.js        # Protección ante caída de proveedores/motor
│           ├── cifrado.js               # AES-256-GCM para datos de cartera
│           └── persistenciaCartera.js   # Guardado/restauración/borrado en PostgreSQL
│
└── frontend/                  # React — la terminal visual
    ├── package.json
    ├── vite.config.js
    ├── index.html              # Carga las dos familias tipográficas del sistema
    └── src/
        ├── main.jsx
        ├── App.jsx             # FASE 2 — router de los seis módulos
        ├── supabase.js         # FASE 2 — cliente único (solo anon key)
        ├── auth/
        │   ├── sesion.jsx      # FASE 2 — sesión + perfil (¿aprobado?)
        │   └── Guardias.jsx    # Qué pantalla ver; la seguridad es la RLS
        ├── datos/
        │   ├── senales.js      # FASE 2 — lectura del escáner de tu cartera
        │   ├── cartera.js      # FASE 2 — RPC de cartera, búsqueda, altas e importación
        │   ├── csvCartera.js   # FASE 2 — lectura del CSV en el navegador (+ .test.js)
        │   ├── simulador.js    # FASE 2 — RPC del simulador; ni un cálculo vive aquí
        │   ├── frescura.js     # FASE 2 — ¿dato atrasado? por clase y mercado NY
        │   └── frescura.test.js # `npm test` — runner nativo de Node
        ├── rutas/
        │   ├── Escaner.jsx     # El armazón de la Fase 1, ahora una ruta
        │   ├── Admin.jsx       # FASE 2 — aprobar / rechazar / suspender + auditoría
        │   ├── Cartera.jsx     # FASE 2 — lo que sigues + posiciones importadas
        │   ├── Simulador.jsx   # FASE 2 — cuenta, entradas sugeridas, posiciones y libro mayor
        │   ├── acceso/         # Login, registro, pendiente, recuperar contraseña
        │   └── Proximamente.jsx # Módulos pendientes, con su sprint y sus historias
        ├── useApi.js           # Hooks: useEscaner, useCartera, useEventLog
        ├── formato.js          # Formato numérico (punto decimal), símbolos de activo, etiquetas
        ├── guia.js             # Contenido de la guía de lectura (fórmulas e interpretación)
        ├── plantillaCartera.js # Genera y descarga el CSV modelo de cartera
        ├── estilos.css         # Punto de entrada — solo ordena las capas de estilos/
        ├── estilos/            # Sistema de diseño "Instrumento"
        │   ├── tokens.css      # Paleta, tipografía, ritmo, radios, movimiento
        │   ├── base.css        # Reset, fondo, foco, scrollbars
        │   ├── layout.css      # Barra superior, rejilla de KPIs, rejilla principal
        │   ├── componentes.css # Paneles, tablas, medidores, stream
        │   ├── guia.css        # Panel lateral de ayuda y sus accesos
        │   ├── acceso.css      # FASE 2 — pantallas de acceso y panel de admin
        │   ├── cartera.css     # FASE 2 — módulo Cartera
        │   └── simulador.css   # FASE 2 — módulo Simulador
        └── components/
            ├── StatusBar.jsx      # Marca + estado de datos, stream y último escaneo
            ├── MetricsStrip.jsx   # Cuatro KPIs derivados de datos ya en pantalla
            ├── ScannerTable.jsx   # Escáner: filtros, orden y fila de detalle
            ├── PortfolioPanel.jsx # Carga (arrastrar/soltar), consentimiento, diagnóstico
            ├── EventLog.jsx       # Stream de eventos en tiempo real
            ├── HelpDrawer.jsx     # Guía de lectura + descarga del CSV modelo
            ├── Navegacion.jsx     # FASE 2 — tira de navegación entre módulos
            └── ui/                # Primitivas: Panel, Chip, medidores, iconos, marca
```

**Regla para agregar archivos nuevos**: si es lógica de análisis/cálculo →
`motor-analitico/`; si es una ruta de API o un servicio de backend →
`backend/src/`; si es interfaz visual → `frontend/src/`. Un archivo nunca
debería necesitar vivir en dos carpetas a la vez — si sientes que sí,
probablemente falta una función intermedia que los conecte (como
`clienteMotorAnalitico.js` conecta backend con motor analítico).

**Dónde van los análisis y las propuestas**: en `docs/`, versionados junto
al código. Un estudio que justifica un cambio de reglas de riesgo tiene
que poder consultarse meses después, cuando ya nadie recuerde por qué se
eligió una opción y no otra — si vive en un directorio temporal, se pierde.
Cada documento lleva en su cabecera autor, fecha y estado (propuesta,
aprobada, implementada).

**Regla adicional para el frontend**: ningún componente escribe un color,
un tamaño de fuente o un espaciado literal. Todo sale de una variable de
`estilos/tokens.css` — es lo que permite mover la identidad visual entera
tocando un solo archivo. Si necesitas un valor que no existe, se añade
como token antes de usarlo.

---

## Sistema de diseño ("Instrumento")

La interfaz está pensada para un analista mirando cifras comparables, no
para una demo. Tres decisiones sostienen todo lo demás:

- **El color es información, no decoración.** El verde y el rojo están
  reservados en exclusiva a la semántica de mercado (dirección de la
  confluencia, salud de una posición, signo del P&L). El cian es
  estructural: marca, foco, y lo que está vivo ahora mismo. El latón
  marca lo que el sistema protege — el tope duro de apalancamiento se
  dibuja como un remache al final de cada barra, precisamente porque es
  el límite que `riesgo/apalancamiento.py` garantiza con un `min()`.
- **Toda cifra comparable va en monoespaciada con cifras tabulares**, con
  punto decimal y coma de millares siempre presente (`$1,234.56`), para
  que las columnas se puedan leer en vertical sin que los dígitos bailen.
  Es el mismo formato que exige el CSV de cartera y el que usa el motor en
  sus textos: lo que se escribe, lo que se lee y lo que explica el sistema
  coinciden. Todo sale de `LOCALE_NUMEROS` en `formato.js`; ningún
  componente formatea números por su cuenta.
- **Cada fila del escáner responde sin hacer cuentas**: la confluencia se
  lee como dirección + fuerza + apoyos; el apalancamiento, como su
  distancia al tope; el riesgo, como la posición del precio entre sus dos
  niveles. Desplegar la fila muestra los indicadores individuales que el
  motor ya había calculado.
- **«Sin dato» y «sin operación» se ven distinto.** Cuando el motor no
  encuadra operación (regla protegida nº2), la fila no se vacía: el
  apalancamiento pasa a gris con la referencia de volatilidad, el riel
  pierde el gradiente y rotula «Sop./Res.» en vez de «SL/TP», y la celda
  de confluencia dice *sin operación encuadrada*. Un «—» a secas
  comunicaría «el proveedor falló», que es un problema distinto y tiene
  su propio tratamiento en la fila de error. La UI ramifica siempre por
  `operable`, nunca por la dirección: el motor puede marcar una lectura
  alcista como no operable si le faltó volatilidad.

Dos familias tipográficas: *Space Grotesk* para la interfaz y *JetBrains
Mono* para los datos, ambas desde Google Fonts con pilas de respaldo — sin
red, la jerarquía se mantiene.

### Guía de lectura

La interfaz explica sus propias cifras. El botón **Guía** de la barra
superior (o la tecla `?`) abre un panel lateral con, por cada valor del
dashboard, tres cosas: qué mide, la fórmula exacta que aplica el motor, y
cómo interpretarlo. Cada panel y cada KPI tienen además su propio icono de
ayuda, que abre la guía directamente por su sección.

Un detalle importante de mantenimiento: **las fórmulas de
`frontend/src/guia.js` están transcritas del código real**
(`indicadores/tecnicos.py`, `riesgo/apalancamiento.py`,
`riesgo/salud_posicion.py`, `riesgo/rotacion.py` y
`backend/src/routes/portfolio.js`). Si cambias uno de esos umbrales, la
guía queda mintiendo — actualízala en el mismo commit. La sección
*Límites que conviene conocer* documenta de cara al usuario las
asimetrías de datos que el CHANGELOG registra a nivel técnico.

Esa misma guía contiene la **plantilla de cartera descargable**
(`cartera-modelo.csv`), con las tres columnas que exige el backend y el
formato numérico correcto.

---

## Puesta en marcha (localhost)

Necesitas 3 procesos corriendo en paralelo, cada uno en su propia terminal
de VS Code.

### 0. Variables de entorno (una sola vez)

```bash
cp .env.example .env
```

Completa en `.env`:
- `PORTFOLIO_ENCRYPTION_KEY` → generar con:
  ```bash
  python3 -c "import secrets; print(secrets.token_hex(32))"
  ```
- `ANALYTICS_SERVICE_INTERNAL_TOKEN` → cualquier string largo aleatorio (token compartido entre backend y motor analítico)
- `SESSION_SECRET` → cualquier string largo aleatorio (firma la cookie de sesión que usa la carga/diagnóstico de cartera)
- `DB_*` → credenciales de tu PostgreSQL local

### 1. Base de datos (PostgreSQL)

Si no tienes PostgreSQL instalado, la vía más rápida es Docker:

```bash
docker run --name dashboard-db -e POSTGRES_PASSWORD=tu_password \
  -e POSTGRES_DB=dashboard_financiero -p 5432:5432 -d postgres:16
```

Luego crea las tablas:

```bash
psql -h localhost -U postgres -d dashboard_financiero -f backend/db/schema.sql
```

### 2. Motor analítico (Python)

**Requiere Python 3.11 o 3.12.** `pandas-ta` no se actualiza desde 2021 y
parte del stack científico (numpy y compañía) todavía no soporta versiones
muy nuevas de Python (p. ej. 3.13/3.14) — instalar con esas versiones falla
con un `RuntimeError` al compilar numpy. Usa un entorno virtual dedicado en
vez del Python global del sistema:

```bash
# Windows (PowerShell) — usa el launcher py para elegir la versión
cd motor-analitico
py -3.12 -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn servicio_interno:app --port 8001
```

```bash
# macOS/Linux
cd motor-analitico
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt --break-system-packages
uvicorn servicio_interno:app --port 8001
```

Si no tienes Python 3.12 instalado, `py -0p` (Windows) o `pyenv versions`
(macOS/Linux) muestran qué versiones tienes disponibles; instala 3.12 desde
python.org si hace falta. Recuerda activar `.venv` en cada terminal nueva
antes de correr `uvicorn` o los tests.

#### El puerto 8001 ya está ocupado

Si al lanzar `uvicorn` aparece esto:

```
INFO:     Application startup complete.
ERROR:    [Errno 10048] error while attempting to bind on address ('127.0.0.1', 8001):
          solo se permite un uso de cada dirección de socket
```

**no es un fallo del código**: ya tienes otra instancia del motor corriendo
en ese puerto. Confunde porque uvicorn primero imprime
`Application startup complete` (la app carga bien) y recién después falla al
reservar el socket — parece un arranque exitoso que se cae solo.

Suele pasar al cerrar la terminal con la ✕ en vez de con `Ctrl+C`: la ventana
desaparece pero el proceso sigue vivo y aferrado al puerto.

Para ver quién lo tiene y liberarlo:

```powershell
# Windows (PowerShell)
Get-NetTCPConnection -LocalPort 8001 -State Listen | Select-Object OwningProcess
Stop-Process -Id <PID> -Force
```

```bash
# macOS/Linux
lsof -i :8001
kill -9 <PID>
```

Si en realidad querías levantar una segunda instancia en paralelo, cambia el
puerto (`uvicorn servicio_interno:app --port 8002`) y ajusta
`ANALYTICS_SERVICE_PORT` en el `.env` para que el backend Node apunte ahí.

> Cierra el motor siempre con `Ctrl+C` en su terminal para evitar el proceso
> huérfano.

#### El motor responde 401 y el dashboard sale vacío

> **Solo aplica al stack local.** En la nube no hay servicio interno que
> autenticar: el motor no responde por HTTP, escribe en PostgreSQL. Por
> eso `ANALYTICS_SERVICE_INTERNAL_TOKEN` no existe en ningún secreto de
> GitHub Actions ni de Vercel. El fallo equivalente allí es un 401 de
> PostgREST, y significa que falta o está mal `SUPABASE_SERVICE_ROLE_KEY`.

Si el escáner no muestra datos y en la terminal del motor ves:

```
INFO:  127.0.0.1:xxxxx - "POST /internal/scan HTTP/1.1" 401 Unauthorized
```

El `ANALYTICS_SERVICE_INTERNAL_TOKEN` que manda Node **no coincide** con el
que lee Python. La causa casi siempre es un `.env` duplicado.

El proyecto usa **un único `.env` en la raíz** (ver §0): es el token
compartido entre backend y motor. `servicio_interno.py` lo carga por ruta
absoluta, y `backend/src/cargarEnv.js` hace lo mismo desde Node. Pero si
además existe un `backend/.env`, es fácil editar ese por error y creer que
está aplicado — el de la raíz es el que manda para ambos servicios.

Para comprobar que ambos lados ven el mismo token:

```powershell
# Windows (PowerShell) — compara sin exponer el valor
$raiz = (Select-String -Path .env -Pattern '^ANALYTICS_SERVICE_INTERNAL_TOKEN=').Line
$back = (Select-String -Path backend\.env -Pattern '^ANALYTICS_SERVICE_INTERNAL_TOKEN=' -ErrorAction SilentlyContinue).Line
if ($null -eq $back) { "OK: no hay backend/.env duplicado" }
elseif ($raiz -eq $back) { "OK: coinciden" }
else { "PROBLEMA: backend/.env tiene un token distinto al de la raiz" }
```

Si aparece `PROBLEMA`, borra `backend/.env` (o alinea su token con el de la
raíz) y **reinicia el backend** — Node lee el `.env` una sola vez, al
arrancar. Cambiar el `.env` con el servidor corriendo no tiene ningún efecto.

> Lo mismo vale para el motor: si tocas el `.env`, reinicia **ambos**
> servicios, no solo uno.

### 3. Backend (Node.js)

```bash
cd backend
npm install
npm start
```

Health check: `curl http://localhost:3000/api/health`

### 4. Frontend (React)

```bash
cd frontend
npm install
npm run dev
```

Abre la URL que muestra Vite (por defecto `http://localhost:5173`).

---

## Despliegue en la nube (Fase 2)

Tres plataformas, ninguna con tarjeta en el camino crítico. El reparto no
es una preferencia: es lo que hace que «coste 0» signifique que el
servicio **se detiene** al agotar una cuota, en vez de que llegue una
factura.

| Pieza | Dónde corre | Por qué ahí |
|-------|-------------|-------------|
| Datos, autenticación, cron | **Supabase** (free) | Es el mismo PostgreSQL de la Fase 1; el `schema.sql` se extiende, no se migra de motor. Trae `pg_cron`, `pg_net` y RLS sin instalar nada |
| Frontend | **Vercel** (Hobby) | Build de Vite nativo, HTTPS y dominio gratis. Sirve ficheros estáticos y nada más: **no hay backend en Vercel** |
| Motor analítico | **GitHub Actions** | Es lo único que necesita `pandas-ta` y ventanas de 2 años de velas. Corre como job programado, arranca, calcula, escribe y muere |

### El motor ya no es un servidor

```
FASE 1 (pull, síncrono)              FASE 2 (push, asíncrono)
─────────────────────────            ────────────────────────────
usuario → frontend                   motor (job programado)
        → Express                            ↓ escribe
        → FastAPI                     PostgreSQL (senales, precios)
        → yfinance/CoinGecko                  ↑ lee
        ← espera ~30 s el bloque      frontend → usuario (instantáneo)
          cripto en frío
```

Tres consecuencias:

1. **No hay servidor Python que pagar.** `motor-analitico/etl.py` es el
   punto de entrada del job; `escritor_supabase.py` traduce la salida de
   `_escanear_ticker()` a filas. **Ninguno de los dos contiene lógica de
   análisis**: reutilizan la del Sprint 1 al completo.
2. **La latencia de usuario desaparece.** El primer escaneo en frío del
   bloque cripto rondaba el medio minuto; ahora el navegador lee una fila
   ya calculada.
3. **El circuit breaker en memoria deja de hacer falta.** El «último dato
   válido» ya no es una variable de un proceso vivo: es la tabla
   `senales` con su `calculado_en`. Lo que se paga es que las señales
   tienen la edad de la última pasada, así que la interfaz muestra esa
   edad y avisa cuando el dato está añejo.

### Por qué `pg_cron` y no el cron de Vercel

Porque **el plan Hobby de Vercel limita los cron jobs a una ejecución al
día**, y una expresión más frecuente falla en el despliegue. Para un
monitor de Take Profit y Stop Loss eso es inservible. `pg_cron`, dentro
de Postgres, admite intervalos de segundos. Reparto final:

| Trabajo | Planificador | Cadencia |
|---------|--------------|----------|
| Monitor de órdenes | `pg_cron` → SQL (D8) | cada minuto |
| Ciclo de agentes | `pg_cron` → SQL (D11) | cada 5 minutos |
| Corte semanal de agentes | `pg_cron` → SQL (D11) | lunes 00:07 UTC, sobre la semana ISO cerrada |
| Disparo del ETL | `pg_cron` → `workflow_dispatch` (0015) | :07 y :37; acciones solo con NY abierto |
| ETL de acciones | GitHub Actions (disparado desde la BD) | cada 30 min en sesión; `schedule` de reserva 3 veces al día |
| ETL de cripto | GitHub Actions (disparado desde la BD) | cada hora, máximo 8 monedas; `schedule` de reserva cada 3 h |

La ventana de cron de acciones es ancha **a propósito**: los cron de
GitHub Actions se evalúan en UTC y no entienden el horario de verano, así
que la decisión real la toma `motor-analitico/ventana_mercado.py` en hora
de Nueva York. Una pasada fuera de sesión termina en segundos.

El monitor de órdenes es **SQL puro** y no una Edge Function (decisión D8
del dueño, 2026-09-24): así las cuatro reglas del cierre automático se
prueban en cada pull request sobre un PostgreSQL limpio, que es la única
validación automática que tiene este proyecto. El coste de esa decisión es
que PostgreSQL no puede llamar a yfinance, así que el precio vivo solo se
refresca desde SQL para cripto —una petición a CoinGecko por pasada, con
todos los ids a la vez, y ninguna cuando nadie tiene posiciones abiertas—
y las acciones se evalúan con el precio del ETL y solo con Nueva York
abierta.

### El presupuesto de cuotas, en una tabla

| Recurso | Límite del tier gratuito | Uso estimado |
|---------|--------------------------|--------------|
| Supabase — tamaño de BD | 500 MB | ~80 MB con retención de señales activa |
| Supabase — proyectos activos | 2 | **1** — el otro lo usa otra aplicación, así que **no hay staging** |
| Supabase — invocaciones Edge | 500.000/mes | ~52.000 |
| GitHub Actions (repo privado) | 2.000 min/mes | ~1.078 min/mes |
| CoinGecko (free, sin clave) | ~10-15 req/min | 12 req por pasada, espaciadas 6 s |

> **El coste 0 no lo limita la nube, lo limita CoinGecko.** Supabase y
> GitHub Actions quedan con holgura del 50-90 %; el número de
> criptomonedas que el sistema puede seguir está fijado por una API
> gratuita que permite 15 peticiones por minuto y cobra dos por moneda.
> De ahí el techo de 20 criptos globales.
>
> Y un hallazgo que solo aparece al presupuestar: la tabla `senales` con
> histórico completo alcanza ~600 MB en un año y el tier gratuito da 500.
> Por eso `fn_retencion_senales()` existe desde el primer día — sin ella
> el sistema funciona seis meses y luego deja de escribir señales sin
> explicación aparente.

### Arranque

Los once pasos que requieren credenciales están en
[`docs/fase-2/RUNBOOK-sprint-1.md`](docs/fase-2/RUNBOOK-sprint-1.md), con
la lista de verificación de los criterios de aceptación.

---

## Correr los tests del motor analítico

No requieren `pytest` instalado — corren con `assert` simples:

```bash
cd motor-analitico
python3 tests/test_apalancamiento.py
python3 tests/test_contrato_scan.py
python3 tests/test_maquina_fases.py
python3 tests/test_rotacion.py
python3 tests/test_salud_posicion.py
```

Cada archivo imprime una línea `PASS`/`FAIL` por caso; hoy son **133 casos**
y todos pasan — 69 heredados de la Fase 1, 21 del Sprint 1 de la Fase 2
(`test_escritor_supabase.py` y `test_ventana_mercado.py`) 17 del Sprint 2
(`test_seleccion_universo.py` y `test_etl_seleccion.py`), 6 del Sprint 4
(`test_altas.py` y uno más en `test_etl_seleccion.py`) y 15 del Sprint 5
(`test_dimensionado.py`). La cota está
fijada en `scripts/resumen_tests.py`: si la suite recolecta MENOS casos de
los esperados, la CI falla aunque todo esté en verde, porque un fichero de
test que deja de importarse hace que pytest termine con éxito y menos
pruebas — y eso es indistinguible del éxito si solo se mira el código de
salida. `test_contrato_scan.py` no toca ninguna API externa: sustituye
el conector por un doble y verifica sobre series sintéticas las invariantes
del payload (entre ellas que `operable`, `leverage_recomendado`, `sl` y `tp`
son consistentes entre sí, y que la respuesta no contiene `NaN` — que no es
JSON válido y tumbaría el escáner entero en el frontend, no solo el ticker
afectado).

Si tienes `pytest` disponible, también funciona:
```bash
pytest tests/ -v
```

---

## Reglas de diseño que el código protege (no romper sin querer)

Estas reglas vienen de decisiones de negocio explícitas — si vas a tocar
código cerca de ellas, vale la pena recordarlas:

1. **Apalancamiento**: el tope duro (`LEVERAGE_HARD_CAP_FASE1`/`FASE2` en
   `.env`) nunca es superable por el cálculo de `riesgo/apalancamiento.py`
   — hay un `min()` explícito que lo garantiza. El suelo de 1,0× se aplica
   **antes** de ese `min()`, no después: al revés, un tope configurado por
   debajo de 1,0× quedaba superado por el propio suelo.
2. **Sesgo operativo**: el motor solo encuadra operaciones **en largo**. Si
   la confluencia dominante no es alcista, `riesgo/apalancamiento.py`
   devuelve `recomendado = None` y `_escanear_ticker` no asigna roles de
   SL/TP a los niveles técnicos — solo emite `soporte`/`resistencia`, que
   son direccionalmente neutros. Nunca se invierten los roles para fabricar
   un setup de corto: el sistema no modela coste de préstamo ni funding.
3. **Dominancia, no conteo absoluto**: `rotacion.py` exige
   `indicadores_alcistas > indicadores_bajistas` (capital nuevo: el empate
   excluye) y `salud_posicion.py` cuenta bajistas solo si igualan o superan
   a los alcistas (capital ya expuesto: el empate mantiene la vigilancia).
   La asimetría `>` / `>=` es deliberada. Si rotación se queda sin
   candidatos devuelve `None`; no se relaja ningún criterio.
4. **Modo degradado hacia el riesgo mínimo**: si falta la volatilidad
   (`ATR` o precio no finitos, o `ATR <= 0`), el apalancamiento cae al
   mínimo y la fila deja de ser operable. Nunca al revés — antes, un `NaN`
   hacía fallar todas las comparaciones de tramo y el cálculo aterrizaba
   en «volatilidad baja», es decir, en el apalancamiento máximo.
5. **Fase 2 → Fase 1**: solo ocurre por acción manual explícita
   (`maquina_fases.py::revertir_a_fase1_manualmente`), nunca automática.
6. **Portfolio Health Selector**: el monto invertido por el usuario
   **nunca** viaja al motor de decisión de rotación — solo se usa
   localmente en `portfolio.js` para calcular P&L informativo. La
   sugerencia de rotación (`riesgo/rotacion.py`) usa siempre el TP/SL que
   ya calculó el escáner general para el activo destino.
7. **Cifrado**: cualquier dato de cartera que se persista en PostgreSQL
   pasa por `services/cifrado.js` (AES-256-GCM) — nunca se guarda en
   texto plano, ni siquiera corriendo en localhost.

   > **RETIRADA EN LA FASE 2** por la decisión D3, firmada el 2026-09-20.
   > En la nube no se cifra ningún importe: el supuesto es que **ninguna
   > cifra de este sistema es dinero real**, ni en el simulador ni en la
   > cartera importada. Cifrar un dato inventado no protege nada y sí
   > impide agregarlo en SQL, que es justo lo que necesitan el P&L y el
   > corte semanal de los agentes. La regla **sigue vigente en el stack
   > local de la Fase 1** mientras `cifrado.js` exista. Si algún día se
   > cargan cifras reales de patrimonio, hay que revisar D3 **antes** de
   > importarlas.
8. **Borrado**: `borrarCarteraReal()` hace `DELETE` físico, nunca
   soft-delete.

---

## Pendientes conocidos (no bloqueantes)

- El registro de eventos vive en `eventos_sistema` y llega por Supabase
  Realtime (Sprint 6, H-32): sobrevive al cierre de sesión y se ve igual
  en otro dispositivo. «Limpiar» no borra —los eventos globales son de
  todos—: mueve la marca de lectura del perfil. La tabla no tiene aún
  política de retención; con tres agentes cerrando órdenes crecerá unos
  pocos miles de filas al mes, lejos del límite del tier gratuito.
- `yfinance` no es una API oficial — si Yahoo cambia su estructura interna,
  `conectores/yahoo_finance.py` lanzará `ErrorEsquemaInesperado`. Revisar
  ese archivo primero si el escáner empieza a fallar solo para acciones
  (no para cripto).
- CoinGecko (tier gratuito, sin clave de API) permite del orden de 10-15
  req/min. Cada cripto cuesta **dos peticiones** —`/market_chart` para
  cierres, precio vivo y volumen, y `/ohlc` a 4 h para los máximos y
  mínimos diarios—, con cachés independientes de 15 y 60 minutos. El
  conector espacia sus llamadas 6 s y reintenta ante un `429` respetando
  `Retry-After`, así que el primer escaneo en frío del bloque cripto ronda
  el medio minuto. Si se amplía `UNIVERSO_CRIPTO` en
  `backend/src/routes/escaner.js`, contar ~12 s por cripto nueva; a partir
  de unas cinco monedas conviene reevaluar el proveedor (ver
  `docs/propuesta-velas-ventanas.md`, D4).
- **La vela diaria de cripto es reconstruida, no servida.** CoinGecko no
  ofrece velas diarias con máximo y mínimo reales sin plan de pago, así
  que el motor las arma con esas dos llamadas. Solo los últimos 30 días
  tienen rango real: el ATR y el soporte/resistencia se calculan
  únicamente sobre esas filas, nunca sobre el frame completo. Calcularlos
  sobre todo el frame inflaba el ATR de BTC un 16 % y le cambiaba el tramo
  de volatilidad, así que esa restricción no es un detalle de
  implementación — es lo que hace que la cifra signifique algo.
