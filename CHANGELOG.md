# Changelog

Bitácora compartida de hallazgos y correcciones sobre `dashboard-financiero`,
mantenida entre las herramientas que trabajan sobre este repo (Cowork y
Claude Code) para no perder contexto entre sesiones.

## [Sin publicar] - 2026-09-20

### Añadido — `docs/` para análisis y propuestas

- `docs/propuesta-velas-ventanas.md`: propuesta del especialista en
  indicadores para conseguir velas diarias coherentes entre acciones y
  cripto. **Estado: pendiente de decisión** (D1–D7 en su §10). Incluye la
  especificación por conector, 9 alternativas descartadas con su motivo,
  20 casos de prueba sin red y comprobaciones empíricas con peticiones
  reales a CoinGecko.
- Los análisis que justifican cambios de reglas de riesgo pasan a
  versionarse en `docs/`. Se estaban escribiendo en un directorio temporal
  del sistema, y **la especificación que originó el cambio de sesgo
  operativo del 2026-08-28 se perdió** cuando ese directorio se limpió.
  Las decisiones que contenía sobrevivieron solo porque quedaron
  registradas en este CHANGELOG y en los comentarios del código.

## [Sin publicar] - 2026-09-19

### Corregido — formato numérico del CSV de cartera

Resuelve el "pendiente de decisión" del 2026-08-28 sobre CSV con
decimales en formato anglosajón. Decisión del dueño: **el separador
decimal es siempre el punto.**

- `normalizarNumero()` (`backend/src/middleware/sanitizacionArchivos.js`)
  asumía formato es-ES: borraba todos los puntos y convertía la coma en
  decimal, así que `184.72` se cargaba como `18472` — fila válida, precio
  multiplicado por 100, sin aviso. Ahora el punto es el decimal y la coma
  solo se admite como separador de millares bien agrupado (`1,200.50`).
- **Lo ambiguo se excluye, no se adivina.** Una coma decimal (`184,72`),
  el formato es-ES (`1.200,50`), millares mal agrupados, notación
  científica, hexadecimal o `5.` dejan la fila en `filasExcluidas` con un
  motivo que indica el formato esperado. Antes `Number()` aceptaba `1e3` y
  `0x10` sin rechistar.
- La plantilla descargable, el texto de la zona de carga y la guía de
  lectura enseñaban el formato contrario; actualizados. La plantilla ya no
  necesita entrecomillar valores.
- Verificado contra el parser real: la plantilla carga sus tres filas con
  los valores exactos, y 13/13 casos de formato dan el resultado esperado
  (incluidos los siete que deben excluirse). El backend Node sigue sin
  suite de tests propia; no se añadió infraestructura para esto.

### Cambiado — la interfaz también usa punto decimal

Por congruencia con el CSV (decisión del dueño): lo que el usuario escribe
al cargar la cartera y lo que lee en pantalla usan ya el mismo formato.

- `formato.js` pasa de `es-ES` a una única constante `LOCALE_NUMEROS`
  (`en-US`), usada solo como vehículo del formato: punto decimal y coma de
  millares (`$1,234.56`, `+18.44%`, `4.0x`). Los textos siguen en español.
  Todo el formato numérico de la interfaz ya pasaba por ese archivo, así
  que ningún componente necesitó cambios.
- Las cifras escritas a mano en la guía de lectura (`1.0×`, `+2.0×`,
  `1.5×`…) se pasaron al mismo formato.
- Efecto colateral bienvenido: los textos que genera el motor en Python
  (`leverage_motivo` con `3.0x`, `RSI en sobrecompra (73.5)`) ya usaban
  punto, así que el detalle de cada fila deja de mezclar dos formatos.
- La hora del registro de eventos sigue con `es-ES` (24 h): no tiene
  decimales y no afecta a la congruencia.

## [Sin publicar] - 2026-08-28

### Cambiado — el escáner distingue lectura de mercado y sesgo operativo

Origen: una pregunta del usuario sobre si los colores del dashboard estaban
invertidos. No lo estaban, pero la duda destapó que el motor emitía cifras
operables para señales que él mismo marcaba como bajistas. Se separaron dos
conceptos que estaban fundidos: **`direccion`** (qué dice el mercado) y
**`sesgo_operativo`** (qué está el sistema dispuesto a encuadrar como
operación y, por tanto, a dimensionar).

- **`riesgo/apalancamiento.py`**: `calcular_apalancamiento` recibe un 4.º
  parámetro obligatorio `direccion` (sin valor por defecto, deliberado: un
  default reintroduciría el fallo en silencio en cualquier llamador nuevo).
  Con sesgo distinto de largo, `recomendado` pasa a `None` y se emite
  `referencia_volatilidad` — la base por volatilidad, sin el bonus de
  confluencia. El bonus premia que los indicadores estén alineados *con la
  operación implícita*; aplicarlo a una lectura bajista premiaba la
  convicción y la apuntaba en la dirección contraria.
- **`servicio_interno.py`**: el payload de `/internal/scan` gana
  `sesgo_operativo`, `operable`, `leverage_referencia_volatilidad`,
  `soporte`, `resistencia` y `niveles_origen`. `sl`/`tp` y
  `leverage_recomendado` pasan a ser nulables. Los ítems con error
  conservan exactamente su forma anterior (`{ticker, error}`).
- **SL/TP dejan de fabricarse en toda fila**. Antes eran siempre soporte
  abajo y resistencia arriba, es decir, un setup de largo incluso sobre un
  activo recién marcado como bajista. Ahora los roles solo se asignan con
  sesgo largo; el dato técnico se conserva íntegro como `soporte` y
  `resistencia`, sin rol. **No se invierten los roles** para fabricar un
  setup de corto: sin modelar coste de préstamo ni funding, eso sería
  emitir una operación completa justo después de negarse a dimensionarla.
- **`calcular_tp_sl_por_atr()` pasa a usarse** — llevaba en el código sin
  llamarse desde ningún sitio. Es el fallback de `soporte`/`resistencia`
  cuando la ventana de 20 velas no describe estructura (rango menor que un
  ATR, o nulo). El campo `niveles_origen` dice cuál de los dos caminos se
  tomó.
- **`riesgo/rotacion.py`**: el filtro pasa de `indicadores_alcistas > 0` a
  dominancia estricta (`alcistas > bajistas`), y el `max()` se sustituye
  por una ordenación determinista de cuatro claves (dominancia neta →
  fuerza → proporción de indicadores alineados → ticker). La tercera clave
  corrige de paso el sesgo acciones-vs-cripto ya detectado el 2026-08-27:
  una cripto con 2/2 ahora gana a una acción con 2/3. La cuarta elimina la
  dependencia del orden de `UNIVERSO_*` en `escaner.js`.
- **`riesgo/salud_posicion.py`**: `evaluar_deterioro_tecnico` tenía la
  incoherencia espejo (conteo bajista absoluto sin dominancia). Pasa a
  `bajistas if bajistas >= alcistas else 0`. El `>=` frente al `>` de
  rotación es deliberado: en rotación se comprometería capital nuevo, aquí
  hay capital ya expuesto.

Nota sobre urgencia: el filtro de rotación era una trampa **latente**, no
un fallo activo. Con los conectores actuales `cruce_medias` nunca llega a
emitirse, así que hoy `bajistas >= 2` implica `alcistas == 0` y el caso
problemático no es alcanzable. Se habría activado en silencio al ampliar la
ventana histórica de los conectores; ahora esa ampliación ya es segura.

### Corregido — tres fallos encontrados de camino

- **El tope duro sí era superable.** `max(recomendado, 1.0)` corría
  *después* de `min(recomendado, tope_duro)`, así que un tope configurado
  por debajo de 1,0× quedaba superado por el propio suelo. Rompía la regla
  protegida nº1 del README. El suelo ahora se aplica antes del clamp.
- **Un `NaN` en volatilidad producía el apalancamiento máximo.** Con
  `ATR_14` o `precio_actual` no finitos, todas las comparaciones de tramo
  eran falsas y el cálculo caía en *volatilidad baja* → hasta 4,0× sobre un
  activo de volatilidad desconocida, rotulado «volatilidad baja». El modo
  degradado apuntaba al riesgo máximo. Ahora degrada al mínimo, marca la
  fila como no operable y lo dice en `leverage_motivo`. Se trata también
  `ATR <= 0` como volatilidad no disponible.
- **`sl`, `tp` y los `leverage_*` no pasaban por `_num()`**, así que un
  `NaN` volvía a producir JSON inválido y a tumbar el `JSON.parse()` del
  escáner completo, no solo del ticker afectado.

### Añadido — cobertura de tests del motor

De 7 casos a **47, todos en verde**, sin añadir `pytest` (mismo estilo de
`assert` + runner manual): `test_apalancamiento.py`, `test_salud_posicion.py`
y `test_contrato_scan.py` nuevos, `test_rotacion.py` ampliado.
`test_contrato_scan.py` verifica las invariantes del payload sobre series
sintéticas, sin tocar ninguna API externa, incluida la de que la respuesta
serializa a JSON válido.

Un caso de la especificación se resolvió en contra de lo que pedía: exigía
que una dominancia alcista con `deterioro_fundamental=True` diera «verde»,
lo que se contradecía con su propia restricción de no tocar los umbrales de
salud. Se resolvió a favor del comportamiento actual («ámbar»): que el
momento técnico silenciara un EPS negativo sería tapar deterioro
fundamental con lectura técnica, justo lo que este diagnóstico existe para
evitar.

### Cambiado — la interfaz refleja el contrato nuevo

- `RielRiesgo.jsx` acepta `soporte`/`resistencia` y conmuta la
  presentación: con sesgo largo mantiene SL en rojo y TP en verde; sin él,
  pierde el gradiente y rotula «Sop.»/«Res.» en gris.
- `BarraApalancamiento.jsx` no se apaga cuando no hay cifra operable:
  muestra en gris la referencia de volatilidad. Un «—» a secas se leería
  como «el proveedor falló», que es un problema distinto.
- `ScannerTable.jsx` mostraba literalmente «Recomendado x» en el detalle
  con `leverage_recomendado = null` — rotura visible, corregida. La celda
  de confluencia añade *sin operación encuadrada*, para que el motivo esté
  en la fila y no solo en el desplegable.
- `formato.js` gana `sesgoOperativo()`, `esOperable()` y
  `nivelesTecnicos()`, los tres con degradación para payloads sin los
  campos nuevos — el circuit breaker puede servir un escaneo cacheado por
  una versión anterior del motor. Un escaneo antiguo con lectura bajista se
  muestra como no operable, no con su apalancamiento viejo.
- **La UI ramifica por `operable`, nunca por `sesgo_operativo === "largo"`**:
  el motor puede marcar una lectura alcista como no operable en modo
  degradado.
- El KPI «Apalancamiento medio» promedia solo filas operables y dice
  cuántas son sobre el total. Los multiplicadores pasan a formato es-ES,
  como el resto de las cifras.
- Seis entradas de `frontend/src/guia.js` actualizadas más una nueva,
  «Sesgo operativo», tal como exige el README (mismo commit). `backend/`
  no necesitó cambios: `escaner.js` es passthrough y los campos nuevos
  llegan solos.

### Detectado — pendiente de decisión

- **`MACDh == 0` cuenta como bajista.** El MACD no tiene banda neutra, a
  diferencia del RSI (que ignora 30-70): un histograma exactamente en cero
  vota bajista. Hace que el ámbar de salud sea casi el estado por defecto.
- **Para cripto el riel cubre ~80 días, no 20.** CoinGecko agrega las velas
  de 4 en 4, así que la «ventana de 20 velas» de soporte/resistencia es
  cuatro veces más ancha en cripto que en acciones — y la guía de lectura
  dice 20 para ambos.
- `atr_pct` viaja sin redondear (float de 16 dígitos) mientras el resto de
  precios va a 2 decimales. Comportamiento previo, cosmético.
- **[RESUELTO 2026-09-19 — la interfaz pasó a punto decimal]** El texto de
  `leverage_motivo` formatea la referencia con punto decimal (`3.0x`)
  porque se genera en Python; el resto de la interfaz usaba coma.

### Cambiado (Claude Code) — rediseño de la interfaz

- **Sistema de diseño "Instrumento"** en `frontend/src/estilos/`: la hoja
  única `estilos.css` pasó a ser solo el índice que ordena cuatro capas
  (`tokens`, `base`, `layout`, `componentes`). Toda la identidad visual
  —paleta, tipografía, ritmo, radios, movimiento— vive en `tokens.css`;
  ningún componente escribe un valor literal. Se eligió CSS con custom
  properties en vez de añadir Tailwind: no introduce dependencias nuevas
  ni paso de build, y en una UI tan densa de datos el control fino de la
  tabla y de los medidores pesa más que la velocidad de prototipado.
- **Reglas de color con significado**: verde/rojo quedan reservados a la
  semántica de mercado, el cian es estructural (marca, foco, "vivo") y el
  latón marca lo que el sistema protege. El tope duro de apalancamiento
  se dibuja ahora como un remache al final de la barra de cada fila.
- **Escáner**: filtros por tipo de activo, búsqueda, "solo alta", orden
  por columna, fila desplegable con los indicadores individuales, riel
  SL–precio–TP, esqueletos de carga y estados vacío/error explícitos.
  Se muestra el `precio_actual`, que la API ya devolvía y la UI anterior
  descartaba.
- **Cartera**: zona de carga con arrastrar y soltar, encabezados CSV
  requeridos a la vista, consentimiento de persistencia como decisión
  explícita, filas excluidas informadas y total de P&L en el pie.
- **Registro del sistema**: traza con raíl vertical, color por tipo de
  evento, hora local y auto-scroll que respeta al usuario si subió a leer.
- **Nuevo control para `GET /api/portfolio/restore`** (pendiente conocido
  del README): el endpoint existía desde Sprint 4 sin forma de invocarlo
  desde la interfaz.

### Corregido (Claude Code)

- **El WebSocket de eventos no se reconectaba**: `useEventLog` abría el
  socket una vez y, al caerse (reinicio del backend en la otra terminal),
  el panel quedaba mudo para siempre sin decirlo. Ahora reintenta con
  backoff exponencial hasta 30 s y expone el estado de conexión, que la
  barra superior muestra.
- **Un `NaN` en el escaneo podía tumbar el escáner entero**: Python
  serializa `NaN` como el literal `NaN`, que no es JSON válido, así que
  `JSON.parse()` en el frontend fallaba para toda la respuesta y no solo
  para el ticker afectado. `servicio_interno.py` los degrada a `null`
  (`_num()`). El riesgo era real para cripto, donde varios indicadores
  quedan en `NaN` por las limitaciones de CoinGecko ya documentadas.

### Añadido (Claude Code) — guía de lectura y plantilla CSV

- **Panel lateral de ayuda** (`frontend/src/components/HelpDrawer.jsx`),
  con seis secciones: escáner, KPIs, cartera, registro, plantilla CSV y
  límites conocidos. Por cada valor del dashboard explica qué mide, con
  qué fórmula exacta y cómo interpretarlo. Se abre desde el botón *Guía*
  de la barra superior, con la tecla `?`, o desde el icono de ayuda de
  cada panel y cada KPI — en ese caso salta directo a su sección.
- **Las fórmulas están transcritas del código**, no redactadas de
  memoria: umbrales de RSI/MACD, tramos de ATR y de apalancamiento,
  ventana de 20 velas de SL/TP, condiciones de salud de una posición y
  criterios de rotación. El contenido vive aislado en
  `frontend/src/guia.js` para que corregirlo no obligue a tocar JSX.
- La sección *Límites que conviene conocer* traslada al usuario final las
  asimetrías que hasta ahora solo estaban en este CHANGELOG: cripto nunca
  alcanza confluencia «alta», la SMA 200 hoy no llega a calcularse, y una
  posición cripto nunca puede marcarse en rojo (el deterioro fundamental
  se apoya en el EPS, que CoinGecko no expone) y por tanto nunca recibe
  sugerencia de rotación.
- **Plantilla `cartera-modelo.csv` descargable** desde la propia guía
  (`frontend/src/plantillaCartera.js`), generada en el navegador. Se
  verificó pasándola por `parsearYSanitizarCSV()` real: las tres
  posiciones se parsean con los valores esperados y sin filas excluidas.
  Se emite deliberadamente **sin BOM** — el parser del backend no lo
  consume, y con BOM el primer encabezado sería `﻿Ticker` y la carga
  fallaría con «Formato no reconocido».

### Añadido (Claude Code)

- `/internal/scan` expone cinco campos más, todos derivados de cálculos
  que ya se hacían y sin ninguna llamada extra a proveedores:
  `direccion`, `indicadores_bajistas`, `senales` (nombre/dirección/detalle
  de cada indicador), `atr_pct` y `leverage_motivo`. Sin ellos el
  frontend tenía que deducir la dirección de la confluencia parseando el
  texto en español de `resumen_confluencia`. El frontend degrada con
  elegancia si el motor todavía no se reinició y no los envía.

### Detectado — pendiente de decisión

- **[RESUELTO 2026-09-19 — el decimal es siempre el punto]** **Un CSV con decimales en formato anglosajón se carga mal en silencio.**
  `normalizarNumero()` (`sanitizacionArchivos.js`) asume formato es-ES:
  borra **todos** los puntos como separador de millares y luego convierte
  la coma en punto decimal. Con `1.200,50` acierta (1200.5), pero con
  `184.72` —lo que exporta cualquier bróker en inglés, y lo que produce
  Excel en configuración regional inglesa— devuelve `18472`. No es un
  error de parseo: la fila se acepta como válida, con el precio de compra
  multiplicado por 100. El P&L resultante es absurdo pero plausible, y
  nada en la interfaz avisa.
  - Se documentó de cara al usuario en la guía de lectura y en la
    plantilla, pero eso mitiga, no resuelve.
  - Requiere una decisión de producto: ¿se detecta el formato por fila
    (un punto con exactamente dos dígitos detrás es decimal, no
    millares), se pide al usuario que declare el formato al cargar, o se
    rechazan las filas ambiguas en vez de adivinar? La opción de detectar
    tiene su propio caso ambiguo (`1.200` puede ser mil doscientos o uno
    con doscientas milésimas), así que conviene decidirlo antes de tocar
    la función.

## [Sin publicar] - 2026-08-27

### Corregido (Cowork)

- **Faltaba `backend/package.json`**: no había nada que instalar ni script
  `start` — se creó con las dependencias reales que usa el código
  (`express`, `cors`, `express-session`, `express-rate-limit`, `multer`,
  `pg`, `ws`, `dotenv`, `csv-parse`).
- **Carga de cartera rota por falta de sesión HTTP**: `portfolio.js` usaba
  `req.session` pero no había ningún middleware de sesión instalado —
  cada request llegaba con un objeto nuevo y `/api/portfolio/analyze`
  devolvía 404 siempre. Se agregó `express-session` a `server.js` y
  `SESSION_SECRET` a `.env.example`/README.
- **Cookie de sesión no viajaba entre frontend y backend** (puertos
  distintos, 5173 y 3000): se agregó `credentials: true` a `cors()` y
  `credentials: "include"` a los `fetch()` de `useApi.js`.
- **`backend/App.jsx` duplicado**: copia idéntica de
  `frontend/src/App.jsx` que había quedado mal ubicada — eliminado.
- **Test `test_maquina_fases.py` exigía `pytest`** sin declararlo,
  contradiciendo al README ("no requieren pytest instalado"). Se
  reemplazó su bloque `__main__` por un runner manual con `assert`,
  igual que `test_rotacion.py`.
- **El motor analítico (FastAPI) nunca cargaba `.env`**: no usaba
  `python-dotenv`, así que `ANALYTICS_SERVICE_INTERNAL_TOKEN` y demás
  variables llegaban vacías a Python. Se agregó `python-dotenv` a
  `requirements.txt` y `load_dotenv()` al inicio de `servicio_interno.py`.
- **`pandas-ta` incompatible con `numpy>=2.0`**: pandas-ta (sin
  actualizar desde 2021) hace `from numpy import NaN as npNaN`, alias
  eliminado en numpy 2.x — esto tiraba abajo el arranque completo de
  `uvicorn` con `ImportError`. Se restauró el alias (`np.NaN = np.nan`)
  antes de importar `pandas_ta` en `tecnicos.py`.
- **Documentación**: se agregó al README que `motor-analitico/` requiere
  Python 3.11 o 3.12 en un entorno virtual dedicado (Python 3.13/3.14 no
  son compatibles con parte del stack científico todavía).

### Corregido (Claude Code)

- **`.env` se cargaba desde el directorio equivocado**: `import
  "dotenv/config"` resuelve la ruta relativa a `process.cwd()`, que es
  `backend/` al correr `npm start` desde ahí — no la raíz del proyecto
  donde vive el `.env` real. Esto hacía que Node y el motor analítico
  Python vieran tokens distintos (o vacíos), y toda llamada
  `escáner → motor analítico` moría con 401 "Token interno inválido"
  (que el backend traduce a 503 de cara al frontend). Se agregó
  `backend/src/cargarEnv.js`, que resuelve la ruta del `.env` desde la
  ubicación del propio archivo en vez del cwd, y se lo importa primero
  en `server.js`.
- **`KeyError: 'Volume'` en todos los tickers cripto**: `calcular_indicadores()`
  accedía a `resultado["Volume"]` sin comprobar que existiera — el
  endpoint `/ohlc` de CoinGecko no devuelve volumen, así que todo el
  escaneo de cripto moría. Se degrada a `NaN` cuando la columna no
  existe; `evaluar_confluencia()` ya descarta indicadores con `NaN`.

### Detectado — pendiente de decisión

- **CoinGecko devuelve velas de 4 días con `days=180`** (comportamiento
  documentado de su API pública para rangos de 31–365 días), es decir
  ~45 velas totales en vez de ~180 diarias. `SMA_50` y `SMA_200`
  necesitan 50/200 cierres válidos respectivamente para dar un solo
  valor no nulo — con 45 velas, ninguna de las dos se calcula nunca para
  cripto. Sumado a que CoinGecko tampoco expone volumen, cripto queda
  con un máximo de 2 indicadores posibles de confluencia (RSI + MACD)
  contra hasta 4 en acciones (medias + RSI + MACD + volumen). Efecto
  concreto: `fuerza` nunca puede llegar a "alta" para cripto
  (`riesgo/apalancamiento.py` da +2.0x de apalancamiento recomendado
  solo con "alta"), y `mejor_oportunidad_del_escaneo`
  (`riesgo/rotacion.py`) compara `indicadores_alcistas` en crudo entre
  todo el universo mezclado — cripto nunca puede ganarle a una acción
  bien alineada, ni siquiera en empate (`max()` favorece al primer
  elemento y las acciones van primero en la lista). No es un crash: es
  un sesgo silencioso en el apalancamiento y en las sugerencias de
  rotación que depende de qué tan buenos sean los datos de origen, no
  del mercado real.
  - Relacionado: `motor-analitico/conectores/yahoo_finance.py` pide
    `period="6mo"` (~126 velas diarias) — tampoco alcanza para
    `SMA_200` (necesita 200), así que hoy el cruce de medias no se
    calcula ni siquiera para acciones. La asimetría real actual es
    3 indicadores posibles (acciones) contra 2 (cripto), no 4 contra 2.
  - Requiere una decisión de producto, no solo un fix de código: ¿se
    normaliza `fuerza` según la proporción de indicadores disponibles
    en vez de un conteo absoluto, se extiende la ventana histórica de
    ambos conectores, o se acepta la limitación y se documenta de cara
    al usuario en el escáner?
