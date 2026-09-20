# Dashboard Financiero Personal

Terminal de inteligencia financiera para uso 100% personal: escanea un
universo de acciones/cripto en busca de confluencia técnica/fundamental,
calcula apalancamiento recomendado dentro de un tope duro de seguridad, y
diagnostica la salud de tu cartera cargada por CSV/Excel — todo corriendo
en tu propio `localhost`, sin costos de licencia.

> Este documento es el mapa del proyecto: qué hace cada carpeta, cómo
> levantar cada servicio, y dónde va cada nuevo archivo que agregues.

---

## Estructura del proyecto

```
dashboard-financiero/
├── .env.example              # Plantilla de variables de entorno — copiar a .env
├── .gitignore                 # Protege .env y artefactos generados
├── README.md                  # Este archivo
│
├── motor-analitico/           # Python — el "cerebro" del sistema
│   ├── requirements.txt
│   ├── servicio_interno.py    # FastAPI — expone el motor a Node.js
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
│       ├── server.js          # Punto de entrada — Express + WebSocket
│       ├── routes/
│       │   ├── escaner.js     # GET /api/scanner/signals
│       │   └── portfolio.js   # Carga, diagnóstico, restauración y borrado de cartera
│       ├── middleware/
│       │   └── sanitizacionArchivos.js  # Sanitización CSV (fórmulas maliciosas, etc.)
│       └── services/
│           ├── clienteMotorAnalitico.js # Cliente HTTP hacia el motor Python
│           ├── circuitBreaker.js        # Protección ante caída de proveedores/motor
│           ├── cifrado.js               # AES-256-GCM para datos de cartera
│           ├── persistenciaCartera.js   # Guardado/restauración/borrado en PostgreSQL
│           └── websocket.js             # Eventos en tiempo real (/ws/events)
│
└── frontend/                  # React — la terminal visual
    ├── package.json
    ├── vite.config.js
    ├── index.html              # Carga las dos familias tipográficas del sistema
    └── src/
        ├── main.jsx
        ├── App.jsx             # Armazón: barra fija, franja de KPIs, rejilla de trabajo
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
        │   └── guia.css        # Panel lateral de ayuda y sus accesos
        └── components/
            ├── StatusBar.jsx      # Marca + estado de datos, stream y último escaneo
            ├── MetricsStrip.jsx   # Cuatro KPIs derivados de datos ya en pantalla
            ├── ScannerTable.jsx   # Escáner: filtros, orden y fila de detalle
            ├── PortfolioPanel.jsx # Carga (arrastrar/soltar), consentimiento, diagnóstico
            ├── EventLog.jsx       # Stream de eventos en tiempo real
            ├── HelpDrawer.jsx     # Guía de lectura + descarga del CSV modelo
            └── ui/                # Primitivas: Panel, Chip, medidores, iconos, marca
```

**Regla para agregar archivos nuevos**: si es lógica de análisis/cálculo →
`motor-analitico/`; si es una ruta de API o un servicio de backend →
`backend/src/`; si es interfaz visual → `frontend/src/`. Un archivo nunca
debería necesitar vivir en dos carpetas a la vez — si sientes que sí,
probablemente falta una función intermedia que los conecte (como
`clienteMotorAnalitico.js` conecta backend con motor analítico).

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

Cada archivo imprime una línea `PASS`/`FAIL` por caso; hoy son 47 casos y
todos pasan. `test_contrato_scan.py` no toca ninguna API externa: sustituye
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
8. **Borrado**: `borrarCarteraReal()` hace `DELETE` físico, nunca
   soft-delete.

---

## Pendientes conocidos (no bloqueantes)

- El `EventLog` del frontend no persiste entre recargas de página.
- `DELETE /api/portfolio` (borrado real, derecho de supresión) sigue sin
  control visual. Se dejó fuera del rediseño a propósito: es una acción
  destructiva e irreversible y merece su propio flujo de confirmación,
  no un botón más en el panel de cartera.
- `yfinance` no es una API oficial — si Yahoo cambia su estructura interna,
  `conectores/yahoo_finance.py` lanzará `ErrorEsquemaInesperado`. Revisar
  ese archivo primero si el escáner empieza a fallar solo para acciones
  (no para cripto).
- CoinGecko (tier gratuito, sin clave de API) permite del orden de 10-15
  req/min. El conector espacia sus llamadas 6 s, cachea velas 15 min y
  fundamentales 5 min, y reintenta ante un `429` respetando `Retry-After`.
  Si se amplía `UNIVERSO_CRIPTO` en `backend/src/routes/escaner.js`, el
  primer escaneo en frío se alargará (~6 s por cripto nueva); a partir de
  cierto tamaño conviene sacar una clave Demo de CoinGecko y subir el ritmo.
- El endpoint `/ohlc` de CoinGecko **no devuelve volumen** y con
  `days=180` agrega las velas de 4 en 4 días (45 velas en total). Por eso,
  para cripto, el indicador de volumen relativo queda en `NaN` y `SMA_50`/
  `SMA_200` nunca llegan a calcularse: las señales de cripto se apoyan en
  menos indicadores que las de acciones. Es una limitación del proveedor,
  no un fallo — tenerlo en cuenta al comparar confluencias entre ambos.
