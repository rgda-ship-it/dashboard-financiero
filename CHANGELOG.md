# Changelog

Bitácora compartida de hallazgos y correcciones sobre `dashboard-financiero`,
mantenida entre las herramientas que trabajan sobre este repo (Cowork y
Claude Code) para no perder contexto entre sesiones.

## [Sin publicar] - 2026-09-30 — Tus límites y volver a Fase 1 desde /admin (0020)

### Añadido
- **«Ajustar tus límites»** en el simulador (`rpc_configurar_cuenta`): cada
  usuario cambia en SU cuenta las posiciones abiertas máx. (1–10), el riesgo
  por operación (0,1–10 %), el margen comprometido máx. (10–80 %) y el R:R
  mínimo (0–5). El apalancamiento no se ajusta (regla protegida nº1). Cada
  cambio deja un evento con los valores de antes y de después. Salió de que
  el simulador no dejaba abrir una cuarta posición (G4, 3 por defecto) y no
  había dónde cambiarlo.
- **«Volver a Fase 1»** en el panel de agentes de `/admin`, con
  confirmación: llama a `rpc_revertir_fase_manual`, que ya existía pero solo
  se podía usar con SQL. Auditado.

I64.

## [Sin publicar] - 2026-09-30 — Cortafuegos de moneda: solo acciones en USD (0019)

### Añadido — el alta rechaza acciones que no coticen en dólares
Todo el sistema supone USD y Yahoo da el precio en la moneda local: Toyota
en yenes o Vodafone en peniques se habrían leído como dólares y el tamaño,
el margen, el equity y el P&L habrían sido falsos. Y el ETL y el monitor
solo conocen el horario de Nueva York. Dos capas:
- la BD rechaza al pedirla una acción con sufijo de bolsa extranjera
  (`7203.T`, `VOD.L`, `SAP.DE`, `600519.SS`); las clases de EE. UU. van
  con guion (`BRK-B`);
- `altas.py` comprueba la moneda que declara Yahoo antes de validarla.

Los mercados en otras monedas quedan para el proyecto «multimercado»
(conversión de divisas, horario por bolsa, lotes mínimos). I63 y tres tests
de Python (150 → 153).

## [Sin publicar] - 2026-09-30 — Cabos sueltos de la Fase 2 (0018)

### Corregido — el respaldo semanal no incluía el experimento
`respaldo.py` copiaba gobierno y catálogo, pero ni cuentas, ni órdenes, ni
libro mayor, ni agentes: justo lo que no se regenera desde los proveedores.
Ahora respalda las 17 tablas del simulador y los agentes, y de `senales`
solo las que justifican una orden (`v_senales_evidencia`), sin las que las
órdenes no se podrían restaurar. La restauración quita las columnas
generadas y reajusta las secuencias al final (`fn_reajustar_secuencias`).
Un test lee las migraciones y falla si una tabla nueva no tiene destino.

### Añadido
- `fn_retencion_eventos`: borra los avisos de más de 180 días y conserva
  cortes semanales, Game Overs y cambios de fase. La invoca el respaldo.

### Cambiado
- El frontend carga bajo demanda los módulos distintos del escáner: el
  paquete principal baja de más de 500 kB a 477 kB.
- Se retira la dependencia `ws` del backend local (el WebSocket se quitó en
  el Sprint 6).
- El job de tests deja de llamarse «69 casos»; el README de la Fase 2 pasa
  de «Propuesta» a «Ejecutada».

## [Sin publicar] - 2026-09-29 — Mínimo de una acción (0017)

### Cambiado — si el riesgo no llega para una acción entera, se compra una
Con acciones enteras, el riesgo declarado podía no llegar para una sola:
Prudencia arriesga 7,50 $ de sus 500 $ y una acción de 100 $ con el stop
al 10 % arriesga 10 $. No le faltaba poder de compra (a 5× mueve 2.500 $):
el apalancamiento cambia el margen, no lo que se pierde si salta el stop.
Ahora se compra una acción si su riesgo no pasa del 10 % del equity (G2) y
su margen cabe en el saldo y en G3. El racional de la orden muestra el
riesgo real frente al declarado. I62 y un test más en Python (147 → 148).

## [Sin publicar] - 2026-09-29 — Reparto del capital, cierres parciales y agentes que aprenden de cada decisión (0016, D16)

### Corregido — una sola posición se llevaba todo el margen
El tamaño sale del riesgo (nominal = riesgo ÷ distancia al stop): con un
stop cercano, una orden pedía más margen del que admite la cuenta y G3 la
recortaba al tope entero, sin hueco para otra. Nuevo **cupo por posición =
margen máx ÷ nº máx de posiciones** (20 % del equity en una cuenta por
defecto). Es la recomendación del sistema, no un límite del usuario.

### Añadido
- **Cantidad a mano** al confirmar una orden (`p_cantidad`); el servidor
  deduce el margen y sigue imponiendo G1–G5.
- **Acciones en unidades enteras**, criptos con fracciones: en el
  dimensionado (SQL y Python), en la cantidad a mano y en el cierre parcial.
- **Cierre parcial** (25/50/75 %) con sus dos apuntes en el libro mayor. El
  P&L realizado del día sale ahora del libro mayor, para contarlo.
- **Agentes**: tres parámetros nuevos por perfil —reparto (cupo o
  concentrado), rotación (cerrar la posición con menos R:R restante si la
  mejor señal la supera por un umbral) y toma parcial automática—.
- **Aprendizaje por decisión**: cada rotación, toma parcial y apertura se
  resuelve contra su contrafactual (`agente_decisiones`); cada 10 resueltas
  de un tipo el agente mueve su parámetro un paso (`agente_ajustes`, con la
  evidencia). Sustituye a la idea de reaccionar solo al veredicto semanal:
  una semana mala puede tener una decisión excelente.
- **Errores a evitar**: la destilación publica también las firmas que
  pierden (≥ 3 ops, ≥ 66 % en stop, P&L medio < 0) como filtro de exclusión.

### Pruebas
Invariantes I56–I61 (I58 se pone en rojo si se rompe la regla de rotación;
comprobado). Python 144 → 147.

## [Sin publicar] - 2026-09-29 — Corrección: el ETL casi nunca arrancaba a su hora (0015)

### Corregido — criptos con 3 horas de atraso y agentes sin señales frescas
Medido con `gh run list`: `etl-cripto`, programado cada hora, corría cada
3-7 horas; `etl-acciones`, 18 pasadas al día en sesión, unas 3, y alguna
horas tarde (una arrancó a las 23:59 UTC con la bolsa cerrada). Todas
terminaban bien: el problema es que GitHub retrasa o descarta los
`schedule`, sobre todo en repos privados del plan gratuito y en horas en
punto. Desde el Sprint 6 no era solo un dato atrasado: los agentes solo
aceptan señales de menos de 90 minutos, así que casi nunca tenían ninguna.

- `pg_cron` (que sí es puntual) llama a la API de GitHub con
  `workflow_dispatch` —que arranca en segundos— usando el token de Vault
  que ya usaban las altas. Cripto cada hora a los :07; acciones a los :07
  y :37 con Nueva York abierto (`fn_etl_toca`, pura y probada con
  instantes fijos en I55).
- Los `schedule` de GitHub quedan de red de seguridad y espaciados: si
  corren detrás de un disparo, los activos están frescos y la pasada no
  llama a ningún proveedor.

## [Sin publicar] - 2026-09-29 — Fase 2, Sprint 6: los agentes operan solos

### Añadido — poder de trading por escalas (0014, D15)
El dueño separa dos cifras que no se sustituyen: el **tope de
apalancamiento** (5× / 3×) es lo recomendable y la regla protegida nº1,
que no cambia; el **poder de trading** es lo que el bróker permite por el
saldo, hasta 20× por escalas de equity (QuantFury): 1.000 $ → 20.000 $,
2.000 → 40.000, 5.000 → 100.000, 10.000 → 200.000, 15.000 → 300.000,
20.000 → 400.000, 25.000 → 500.000 y 50.000 → 1.000.000. Por debajo de
1.000 $, 20 × el equity; por encima de 50.000 $, se queda en 1 M$.
`fn_poder_trading()` y dos columnas nuevas en `v_cuentas_equity`
(`poder_trading`, `nominal_abierto`). Sin guardarraíl en
`rpc_abrir_orden`: con 5× y el tope de margen, el nominal no pasa de 3×
el equity, así que no puede dispararse; I54 deja escrita esa relación.

### Corregido — «no encuadra» en las entradas sugeridas
Una sugerencia es confirmable si el dimensionado cabe **y** su R:R llega
al mínimo de la cuenta. El caso del R:R caía en un «no encuadra»
genérico; ahora dice la cifra y el mínimo.

### Decisiones del dueño (2026-09-29)
- **D11** — el ciclo de agentes y el corte semanal son SQL sobre
  `pg_cron`, no Edge Functions: mismo motivo que D8, así los diez pasos
  del ciclo se prueban en cada pull request.
- **D12** — el universo de los agentes es todo el catálogo activo.
- **D13** — los agentes nacen **en pausa**; los pone en marcha un
  administrador desde `/admin`, y queda auditado.
- **D14** — un solo pull request para el sprint.

### Añadido — agentes deterministas (0013, H-27)
- `agentes`, `agente_dias`, `agente_estrategia_versiones`, clave ajena
  de `cuentas_simulacion.agente_id` (pendiente desde la 0011) y una
  cuenta viva por agente.
- Prudencia (2 %), Cadencia (5 %) y Audacia (7 %) con los perfiles del
  doc 03 §3.1, 500 $ cada uno por el libro mayor. Los parámetros viven en
  `estrategia jsonb` y se copian a la cuenta, que es lo que lee
  `rpc_abrir_orden`: una estrategia con un 40 % de riesgo no llega a
  escribirse porque el `CHECK` de la cuenta la rechaza.
- `fn_decidir_agente` toma la decisión **sin efectos**: llamarla dos veces
  con el mismo estado da el mismo JSON (criterio de determinismo).
  `fn_ciclo_agente` la ejecuta: sincroniza el día, Game Over primero,
  modo conservación con la meta cumplida (N9), filtro de candidatos con
  sus motivos de descarte, prácticas adoptadas, orden de cuatro claves y
  apertura por `rpc_abrir_orden`, que vuelve a validarlo todo.
- El interés compuesto es una línea: la apertura de hoy es el equity con
  el que amanece, el mismo número con el que se cierra ayer.

### Añadido — corte semanal, prácticas y backlog (H-28, H-29, H-30)
- `fn_corte_semanal` sobre días **operables** (N10): validada / aviso /
  deficiente con sus consecuencias; dos deficientes, cuarentena.
- `mejores_practicas`, `mp_adopciones`, `mp_valoraciones`: destilación
  con ≥ 3 operaciones y ≥ 66 % (también como `CHECK`), adopción que
  cambia de verdad el filtro de candidatos, evaluación a las dos semanas
  y refutación tras dos adopciones que empeoran (N12).
- `agente_backlog` con los siete disparadores del doc 03 §8, evidencia
  obligatoria (N13) y deduplicación por clave; una ocurrencia es un par
  (agente, día). Revisión humana con `rpc_revisar_backlog`.

### Añadido — `/agentes`, Realtime y hardening (H-31, H-32, H-33)
- `/agentes`: marcador, equity real frente a la teórica en escala
  logarítmica, operaciones con su racional desplegable, backlog y
  prácticas. Se actualiza por Realtime. `/admin` gana los controles de
  agentes y la revisión del backlog.
- El registro de eventos pasa de `localStorage` y WebSocket a
  `eventos_sistema` por Realtime. Se retira `backend/src/services/websocket.js`.
- CSP y HSTS en Vercel; 30 búsquedas y 30 altas por minuto y usuario;
  aviso legal permanente con el supuesto de D3 en simulador y agentes;
  `guia.js` explica los agentes y las limitaciones nuevas.

### Corregido — el simulador habría mostrado la cuenta de un agente
`leerCuenta()` cogía la última fila visible de `v_cuentas_equity`. Desde
este sprint todo aprobado lee también las cuentas de los agentes, así que
quien no tuviera cuenta propia habría visto la de Audacia como suya.
Ahora filtra por el usuario de la sesión, y el libro mayor por cuenta.

### Pruebas
- Invariantes **I41–I53** contra el ciclo y el corte de verdad. Se
  comprobó que se ponen en rojo rompiendo a propósito el modo
  conservación, el filtro de prácticas y el denominador del corte.
- `test_coherencia_guia.py` (H-34): lee los umbrales del texto de
  `guia.js` y los contrasta con el motor y con las migraciones. Cambiar
  el 6 % de `apalancamiento.py` sin tocar la guía rompe el build
  (comprobado). Python 133 → 143; frontend 12 → 17.
- El doble de `auth.uid()` de las pruebas ahora tolera claims vacíos,
  como el real de Supabase: el ciclo llama a `rpc_abrir_orden` sin JWT.

## [Sin publicar] - 2026-09-24 — Corrección: las vistas no podían ejecutar sus funciones

### Corregido — `/simulador` cargaba con «permission denied for function fn_tope_fase» (0012)
Recién aplicada la 0011, la pantalla del simulador cargaba pero no
mostraba la cuenta. La cadena es exacta: toda vista lleva
`security_invoker = true` (obligatorio, I13), así que se ejecuta con el
rol de quien consulta —`authenticated`—, y `v_cuentas_equity` llama a
`fn_tope_fase()`, que la 0011 había revocado a todas las `fn_` sin
distinguir. Tres vistas afectadas: `v_cuentas_equity`,
`v_ordenes_abiertas_monitor` y `v_recomendaciones_usuario`.

La regla de I23 decía «`authenticated` no ejecuta ninguna `fn_`». La
intención nunca fue la forma del nombre, sino que un cliente no pueda
invocar lo que toca datos o se salta la RLS: las `SECURITY DEFINER`. Una
función pura —sin acceso a tablas, sin `SECURITY DEFINER`— no concede
nada; `fn_tope_fase('fase_2_consolidacion')` devuelve 3.0 y punto.
Concederla es tan peligroso como conceder `round()`.

- **I23 afinada**: ahora comprueba `prosecdef`, que es la propiedad que
  de verdad importa. `fn_equity`, `fn_registrar_movimiento` y las cuatro
  del monitor siguen revocadas.
- Se conceden a `authenticated` las cinco puras que las vistas usan.
  `anon` sigue sin ninguna (I22).
- La alternativa era copiar el cuerpo de `fn_dimensionar_posicion` dentro
  de la vista: sesenta líneas de algoritmo de riesgo duplicadas por
  tercera vez. Un límite de riesgo copiado tres veces es un límite que
  algún día dirá tres cosas distintas.

### Añadido — I40, la invariante que faltaba
El resto del fichero prueba los RPC con el JWT de cada usuario, pero leía
las vistas como **dueño del esquema**, y el dueño ejecuta cualquier
función: un privilegio que falta era invisible desde ahí. I40 recorre
todas las vistas de `public` y hace un `select` con el rol
`authenticated`, que es lo que hace PostgREST.

Detalle que costó descubrir y que queda escrito: la primera versión usaba
`count(*)` y **solo detectaba dos de las tres** vistas rotas. Al contar,
PostgreSQL poda las expresiones de la lista de selección y nunca
comprueba el permiso sobre las funciones que la vista usa. Con
`select * … limit 0` se planifica la lista entera —que es donde se
verifica el EXECUTE— sin devolver ni una fila. Verificado en los dos
sentidos: sin la 0012 la invariante nombra las tres vistas; con ella,
pasa.

## [Sin publicar] - 2026-09-24 — Fase 2, Sprint 5: el simulador se cierra solo

### Añadido — cuentas, órdenes y libro mayor (0011)
- `cuentas_simulacion`, `ordenes` y `movimientos_saldo`, con los
  parámetros de riesgo **en la tabla** y no en variables de entorno
  (deuda técnica nº3 de la Fase 1).
- El saldo es derivado: nace de un apunte `deposito_inicial` y cambia
  únicamente a través de `fn_registrar_movimiento`, que escribe el apunte
  y actualiza el saldo en la misma sentencia. El libro mayor no admite
  `UPDATE` ni `DELETE` — ni como `service_role`, ni como dueño del
  esquema.
- `/simulador`: cuenta con equity, disponible, margen comprometido y
  caída desde el máximo; entradas sugeridas con el tamaño que le toca a
  tu cuenta; posiciones abiertas con P&L flotante; histórico con el
  precio observado además del nivel; y el libro mayor entero, porque el
  saldo de arriba es la suma de esas líneas.

### Añadido — los cinco guardarraíles, en PostgreSQL
`rpc_abrir_orden` los impone: tope de apalancamiento de la fase (5×/3×),
riesgo ≤ 10 % del equity, margen comprometido ≤ 60 %, número de posiciones
abiertas, y solo señales operables de menos de 90 minutos. Una orden a 6×
se **rechaza** con el motivo escrito, no se recorta en silencio.

### Añadido — dimensionado con ajuste por liquidación
`motor-analitico/riesgo/dimensionado.py` y su gemelo SQL
`fn_dimensionar_posicion`. Lo que un dev no escribiría por su cuenta: si
el precio de liquidación queda por ENCIMA del stop, el apalancamiento se
baja hasta que quede por debajo (a 5× y un stop al 25 %, de 5× a 3,9×), y
si ni a 1× cabe, no se ofrece la operación. Sin eso, la pérdida real sería
el margen entero en vez del riesgo declarado. 15 tests nuevos (133 en
total), incluido un barrido de 40 stops que comprueba la propiedad y no
solo los casos.

### Añadido — monitor cada minuto, en SQL puro
Decisión del dueño (D8): las reglas M1–M4 viven en una función SQL que
`pg_cron` ejecuta cada minuto, no en una Edge Function. Se gana que la CI
las pruebe en cada pull request y se pierde poder llamar a yfinance desde
la base de datos, que es lo que fuerza D9.

- Liquidación antes que stop; ante la duda gana el stop; se cierra **al
  nivel** y el precio que disparó el cierre se guarda aparte; sin precio
  fresco no se evalúa nada.
- El precio vivo (D9) sale de una sola petición a CoinGecko por pasada,
  con todos los ids a la vez, y **solo si hay posiciones abiertas**.
  `pg_net` es asíncrono, así que el ciclo cosecha la respuesta de la
  pasada anterior, evalúa y pide la siguiente: retraso máximo de dos
  minutos, que es el criterio de aceptación de H-25.
- Ventana de frescura partida por clase: 15 min para cripto (el valor del
  diseño) y 35 para acciones, cuyo precio escribe el ETL cada media hora,
  más la exigencia de que Nueva York esté abierta.

### Añadido — dos pruebas que no son invariantes
- `supabase/pruebas/02_concurrencia.sh`: diez conexiones **de verdad**
  cerrando la misma orden a la vez (riesgo R4). Un script de `psql` es una
  sola sesión y no puede competir consigo misma, así que el `FOR UPDATE`
  nunca se ejercitaría desde `01_invariantes.sql`. Comprobado contra una
  implementación ingenua a propósito: se pone en rojo.
- `supabase/pruebas/03_cuadre_saldos.sql`: cincuenta operaciones por los
  RPC de verdad y después la consulta de cuadre del doc 01 §5.2. Cero
  filas o hay un bug de saldo.

### Corregido — una invariante que solo fallaba a las 23:59
I11 sembraba tres señales como `now() - 60 días + g minutos`. Ejecutada en
los últimos minutos del día, los tres minutos cruzaban la medianoche,
caían en dos fechas distintas y la compresión dejaba dos filas en vez de
una. Ahora se anclan al mediodía. Se descubrió al ejecutarla, no al
leerla: una invariante que solo falla a una hora concreta es peor que no
tenerla, porque enseña a desconfiar de la roja.

### Decisiones del dueño
- **D8** — el monitor es SQL sobre `pg_cron`, sin Edge Functions.
- **D9** — el precio vivo del monitor sale de CoinGecko, una petición por
  pasada y ninguna sin posiciones abiertas.
- **D10** — el saldo inicial lo elige el usuario (100–10.000 $ ficticios);
  los agentes seguirán arrancando con 500 $.

### Desviaciones anotadas respecto al diseño
- `cuentas_simulacion.agente_id` se crea **sin** clave ajena: `agentes` no
  existe hasta el Sprint 6 y es esa migración la que la añade.
- La función interna del libro mayor se llama `fn_registrar_movimiento` y
  no `rpc_registrar_movimiento`: en este esquema el prefijo decide los
  privilegios (invariantes I22 e I23).
- El paso 6 del pseudocódigo de dimensionado descarta los topes que el
  paso 5 acaba de aplicar; aquí se vuelven a aplicar después, porque son
  límites duros.
- `movimientos_saldo.orden_id` no lleva `on delete set null`: poner la
  columna a NULL es un `UPDATE` sobre el libro mayor y el trigger lo
  rechazaría, dejando imposible borrar una orden.

## [Sin publicar] - 2026-09-22 — Cierre del Sprint 4: el latido semanal, por REST

### Corregido — el latido nunca había podido conectar
`SUPABASE_DB_URL` apunta a la conexión directa de Supabase, que solo
resuelve por IPv6; los runners de GitHub son IPv4. El job llevaba desde
el Sprint 1 sin poder ejecutarse (se vio en su primera ejecución manual).
Decisión del dueño: pasar el latido, el respaldo y la retención a la
misma vía que el ETL (PostgREST + clave de servicio), en vez de añadir la
contraseña de la base de datos en otro secreto. `SUPABASE_DB_URL` deja de
usarse.

- El respaldo pasa de volcado SQL a un JSON por tabla, con manifiesto, y
  se restaura con `scripts/restaurar_respaldo.py` (upsert por clave).
- Se respalda lo irreemplazable; precios, indicadores y señales siguen
  fuera por regenerables.
- 5 tests nuevos (118 en total).
- **Corregido en la primera ejecución real**: se paginaba con `order=1`,
  que PostgREST lee como una columna llamada «1» (42703), y un respaldo
  incompleto terminaba en verde. Ahora se ordena por la clave primaria de
  cada tabla y el job se pone en rojo si alguna falla.

### Corregido — deriva de producción y dos tropiezos del script
- `posiciones_reales` conservaba las columnas cifradas de la Fase 1
  (0000 se aplicó antes de firmar D3). La 0010 las reconcilia si la tabla
  está vacía. Comprobado: era la única diferencia con las migraciones.
- `catalogo_cripto.py` fallaba por no instalar pandas.
- `aplicar-migraciones.cmd` se reescribía a sí mismo al cambiar de rama:
  ahora se ejecuta desde una copia en `%TEMP%` y no pregunta por las
  carpetas que OneDrive bloquea.

## [Sin publicar] - 2026-09-22 — Fase 2, Sprint 4: carteras dinámicas e ingesta

### Añadido — cada usuario sigue sus propios activos (0010)
- `/cartera`: buscador (catálogo al instante; criptos nuevas desde una
  copia local de CoinGecko; acciones nuevas comprobadas en Yahoo), lista
  de lo que sigues con su estado y botón para quitar.
- El escáner muestra solo la cartera de quien consulta (`v_escaner_usuario`).
- Cuotas (D7): 25 por usuario (admin sin tope personal), 150 activos
  distintos y 20 criptos distintas en todo el sistema.
- El ETL solo refresca activos que alguien sigue.

### Añadido — altas de activos sin servidor
La BD pide a GitHub (pg_net + token en Vault) que ejecute `altas.yml`,
que valida el símbolo y descarga su histórico en 1-3 minutos. Si el
disparo no llega, el ETL de cripto lo procesa en su pasada horaria.

### Añadido — importación de posiciones por CSV en la nube
El fichero se lee en el navegador; al servidor solo llegan filas, que
`rpc_importar_posiciones` vuelve a validar. Reglas de la Fase 1
conservadas (punto decimal, filas inválidas excluidas con motivo). Los
importes se guardan sin cifrar (D3) y la pantalla lo avisa antes.

## [Sin publicar] - 2026-09-22 — Cierre del Sprint 3: dos correcciones

### Corregido — `anon` podía ejecutar los RPC de administración (0009)
Verificando en producción con la clave pública sola, `rpc_aprobar_usuario`
se ejecutaba y era su comprobación interna la que lo rechazaba. 0007
revocó EXECUTE a PUBLIC, pero Supabase concede EXECUTE a `anon`
directamente. Se revoca por nombre, también como privilegio por defecto,
y la invariante **I22** lo exige para toda función `rpc_`/`fn_`.

### Corregido — `aplicar-migraciones.cmd` solo aplica desde master al día
Se ejecutó con la carpeta en la rama de un PR sin fusionar y aplicó sus
migraciones (`supabase db push` usa los ficheros locales). No hubo daño:
eran las mismas que la CI del PR acababa de validar. Ahora el script pone
la carpeta en master, hace `pull --ff-only` y aborta si hay cambios.

## [Sin publicar] - 2026-09-22 — Fase 2, Sprint 3: autenticación y gobierno

### Añadido — cuentas con aprobación de administrador (0007)
- `perfiles`, `auditoria_admin` y el esqueleto de `carteras`.
- Registro, login, confirmación de correo, recuperación de contraseña y
  pantalla de estado (`/pendiente`), que entra sola al dashboard cuando
  un administrador aprueba la cuenta.
- Panel `/admin`: aprobar, rechazar y suspender (con motivo obligatorio),
  y las últimas acciones de la auditoría.
- El administrador inicial está ligado al correo del dueño y solo se
  promueve cuando ese correo está confirmado, una única vez.

### Cambiado — el escáner deja de ser público
- Se retiran las cuatro políticas `*_temporal_h14` de 0005, como estaba
  previsto. Los datos de mercado los lee solo un usuario aprobado.
- `anon` pierde además los privilegios de tabla en `public`.
- Invariante I14 en su forma final: ninguna política para `anon` ni
  `public`. Nuevas I16–I21 prueban la puerta con el rol y el JWT de cada
  usuario, como lo haría un atacante.

### Cambiado — `cartera_posiciones` pasa a `posiciones_reales` (0008)
Con `activo_id` y FK a `perfiles`. No se migra ninguna cartera de la
Fase 1: el dueño no tenía posiciones que conservar.

## [Sin publicar] - 2026-09-21 — Fase 2, Sprint 2: persistencia y catálogo

### Corregido — un activo suspendido no volvía nunca
El ETL solo seleccionaba `activo` y `pendiente_backfill`: tras tres
fallos, un activo quedaba fuera para siempre aunque su backoff hubiera
vencido. La selección vive ahora en `motor-analitico/seleccion_universo.py`
(lógica pura, 12 tests) y reintenta el suspendido cuando toca.

### Corregido — el escáner escondía los suspendidos y teñía todo de «caché»
- Los suspendidos siguen visibles con su última lectura y el aviso
  «suspendido · hace N».
- La antigüedad se calcula por fila y por clase (`frontend/src/datos/frescura.js`):
  cripto > 90 min; acciones solo con Nueva York abierto y > 60 min. Antes,
  un activo viejo marcaba «caché» el escáner entero, y cada fin de semana
  las acciones aparecían añejas aunque fuese el último dato posible.
- La barra de estado dice «atrasado» en vez de «caché».
- Cripto se reconoce por `activos.clase`, no por la lista fija de `formato.js`.

### Cambiado — frescura en vez de «si la vela de hoy existe, no llamar»
La spec original de H-09 congelaba el precio de la vela en curso el día
entero. Ahora un activo no se vuelve a pedir si se procesó hace menos de
media cadencia (15 min acciones, 30 min cripto). `--forzar` lo ignora.

### Rendimiento — `senales_vigentes` (migración 0006)
DISTINCT ON recorría toda la historia de señales. Con un año sintético
(265.650 filas): 227 ms → 1,3 ms. Nueva invariante I15.

### Diferido a H-21
Retirar `IDS_CRIPTO`, `escaner.js` y `circuitBreaker.js`: los necesita
todavía el modo local de la Fase 1.

## [Sin publicar] - 2026-09-21 — Fase 2, Sprint 1 en producción

El Sprint 1 está desplegado: código en GitHub (PR #1), secretos cargados,
ETL escribiendo en Supabase (acciones 21/21, cripto 3/3) y la web pública
en Vercel.

### Corregido — dos vistas se saltaban la RLS (PR #2, migración 0004)

Detectado al abrir la web recién desplegada. Con la clave pública, las
cinco tablas del catálogo devolvían 0 filas, como deben. Pero las dos
vistas lo devolvían todo: `senales_vigentes` 24 filas y
`v_velas_con_rango` 10.590.

En PostgreSQL una vista se ejecuta por defecto con los permisos de su
propietario, que es el dueño de las tablas y no está sujeto a su RLS. La
vista era una puerta lateral. Lo expuesto eran precios públicos, así que
el daño fue nulo; el riesgo era el patrón, porque los Sprints 5 y 6 crean
vistas sobre datos de usuario y lo habrían heredado.

- `0004_vistas_security_invoker.sql` pone `security_invoker = true` en
  las dos vistas.
- **Invariante I13**: falla la CI si una vista de `public` no lo lleva.
  La I8 revisaba solo tablas, por eso el fallo pasó.
- Verificado en negativo (sin el arreglo la CI se pone en rojo nombrando
  las dos vistas) y en producción tras aplicarlo.

### Añadido — lectura pública de datos de mercado, temporal hasta H-14 (migración 0005)

Al cerrar el agujero, el escáner de la web pública se habría quedado
vacío hasta el Sprint 3. El dueño prefiere mantenerlo visible. La
diferencia con lo de antes es la que importa: ahora sale por cuatro
políticas explícitas (`*_temporal_h14`), limitadas a `activos`,
`senales`, `precios_diarios` e `indicadores_diarios` —precios
públicos— y con caducidad escrita en H-14.

- **Invariante I14**: falla la CI si una política concede algo a `anon`
  fuera de esas cuatro tablas. Verificado abriendo la cartera por error.
- En producción: mercado visible; `cartera_posiciones`,
  `eventos_sistema` y `registro_consentimiento` devuelven 0 filas.

### Cambiado — la protección de `master` es por proceso

El paso 11 del runbook pedía una *branch protection rule*. GitHub avisa
de que **en un repositorio privado de cuenta gratuita esas reglas no se
aplican**, así que no se creó: habría dado una seguridad falsa. El dueño
mantiene el repositorio privado y el coste 0.

Lo que protege producción es que la base de datos solo cambia al ejecutar
`supabase db push`. **`scripts/aplicar-migraciones.cmd`** pasa a ser la
única vía para hacerlo: abre el último resultado de la CI de migraciones
sobre `master`, no sigue si no se confirma que está en verde, y enseña
las migraciones pendientes antes de aplicarlas.

### Detectado — Vercel precarga variables desde `.env.example`

Al importar el proyecto, Vercel leyó `.env.example` y propuso 23
variables, entre ellas `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_DB_URL`,
que nunca deben estar en Vercel. Iban vacías, pero con el nombre puesto
bastaba un descuido para rellenarlas. Se borraron las 20 sobrantes antes
del primer despliegue. También propuso por su cuenta `backend` como
directorio raíz y un preset que habría publicado el Express como API.
Conviene saberlo si algún día se reimporta el proyecto.

## [Sin publicar] - 2026-09-20 — Fase 2, Sprint 1

### Añadido — el motor deja de ser un servidor y pasa a escribir

Implementa el Sprint 1 de `docs/fase-2/` (firmado por el dueño), con las
decisiones D1, D2, D4 y D5 cerradas: Supabase + Vercel + GitHub Actions,
el motor Python intacto, agentes deterministas y repositorio privado.

**El cambio de fondo es la dirección del flujo.** En la Fase 1 el motor
respondía a la pregunta del navegador; ahora escribe en PostgreSQL y el
navegador lee de ahí. Eso elimina la necesidad de tener un proceso Python
vivo y a la escucha —que es lo que ningún tier gratuito ofrece bien— y
convierte el primer escaneo en frío del bloque cripto, que rondaba el
medio minuto, en la lectura de una fila ya calculada.

- **El esquema, versionado** (`supabase/migrations/`). `0000_base_fase1.sql`
  es un port literal de `backend/db/schema.sql` más `usuario_id` —
  exactamente la columna que anticipaba el comentario de
  `persistenciaCartera.js` («si en el futuro se soporta más de un usuario,
  esta es la primera tabla que necesita esa columna»). `0001_catalogo.sql`
  trae `activos`, `precios_diarios`, `indicadores_diarios` y `senales`.
  Verificado aplicando las dos migraciones y la semilla sobre un
  PostgreSQL limpio: 24 activos insertados, cero errores.

- **`senales` es el payload de `/internal/scan` persistido**: mismos 20
  campos, mismos nombres. Y la invariante que `test_contrato_scan.py`
  verifica en Python se traduce a un `CHECK` de la base de datos
  (`senales_contrato_operable`), así que `operable`, `leverage_recomendado`,
  `sl` y `tp` son nulos o no nulos los cuatro a la vez **por ninguna vía de
  escritura**: ni un ETL con un bug, ni un `INSERT` a mano en la consola.
  Comprobado: un `INSERT` con `operable = true` y `tp = NULL` es rechazado.

- **`precios_diarios.rango_real`**, la columna que no se puede olvidar.
  `false` para las velas de cripto reconstruidas sin máximo y mínimo
  reales. El CHANGELOG del 2026-09-20 midió lo que pasa si se ignora:
  calcular el ATR sobre el frame completo **inflaba el ATR de BTC un 16 %**
  y le cambiaba el tramo de volatilidad, es decir, cambiaba el
  apalancamiento recomendado. Se blinda además con la vista
  `v_velas_con_rango`, que es la única puerta legítima para calcular
  indicadores: `select * from precios_diarios` para un ATR reintroduce el
  bug en silencio.

- **`motor-analitico/etl.py` y `escritor_supabase.py`**: el punto de
  entrada del job y el adaptador de salida. Ninguno contiene lógica de
  análisis — reutilizan `_escanear_ticker()` tal cual, que es lo que hace
  que la decisión D2 («el motor no se toca») se cumpla de verdad. La
  memoización de `_obtener_ohlcv` existe por una razón concreta: el ETL
  necesita las velas dos veces —para escribir `precios_diarios` y dentro
  de `_escanear_ticker`— y sin caché de pasada cada cripto costaría
  **cuatro** llamadas a CoinGecko en vez de dos. Es el mismo error que ya
  ocurrió en la Fase 1 y que disparaba el 429 en el último ticker del
  universo; no se repite por la puerta de atrás del ETL.

- **`motor-analitico/ventana_mercado.py`**, en su propio fichero por el
  mismo criterio con que se separó `riesgo/rotacion.py`: es lógica pura y
  dejarla dentro de `etl.py` obligaría a importar FastAPI, yfinance y los
  conectores solo para comprobar si el sábado cuenta como día de mercado.

- **Seis workflows.** `tests.yml` convierte la suite en puerta de merge;
  `etl-acciones.yml` y `etl-cripto.yml` ejecutan el motor; `backfill.yml`
  atiende el alta de un activo nuevo bajo demanda; `keep-alive.yml` hace
  latido, respaldo y retención; `frontend.yml` compila y vigila.

- **21 casos de prueba nuevos, sin red. 90 en total, todos en verde**, y
  los 69 anteriores pasan sin tocar ni una línea de test. Los dos que de
  verdad importan: que `rango_real` se decida **por fila y no por
  proveedor** (una cripto tiene ~30 filas con rango real y cientos sin él,
  en la misma tabla), y que la misma hora UTC dé respuestas distintas en
  verano y en invierno — si ese segundo test se pusiera en rojo,
  significaría que alguien sustituyó la conversión de zona por una
  comparación en UTC, y el efecto sería invisible hasta el siguiente
  cambio de hora.

### Añadido — router y navegación en el frontend

- **`App.jsx` pasa a ser el router** y el armazón de la Fase 1 se muda
  intacto a `rutas/Escaner.jsx`. Los componentes **no cambian**:
  `ScannerTable.jsx`, `MetricsStrip.jsx` y `formato.js` siguen recibiendo
  exactamente la misma forma de objeto que devolvía
  `GET /api/scanner/signals`, porque `datos/senales.js` la reconstruye
  desde la vista `senales_vigentes`.

- **Los módulos que no existen se declaran, no se esconden.** Cartera,
  Simulador, Agentes y Admin aparecen en la navegación con su distintivo
  de sprint —en latón, que en este sistema marca lo fijado por una
  decisión— y una pantalla que dice qué habrá ahí y qué historias lo
  entregan. Un enlace ausente del menú es indistinguible de un módulo que
  nadie ha planificado.

- **La cartera y el stream de eventos se declaran pendientes de migración**
  cuando no hay backend alcanzable, en vez de reintentar contra
  `localhost:3000` cada pocos segundos desde una URL pública.

- Verificado con un build real: 100 módulos transformados, 447 KB de JS
  (132 KB comprimido) y 33 KB de CSS.

### Cambiado — el `.env`, los secretos y lo que el subtítulo dice

- **Sigue habiendo un único `.env` en la raíz.** `vite.config.js` lleva
  `envDir: ".."` a propósito: sin eso, Vite habría buscado su propio
  `.env` en `frontend/` y habría reabierto exactamente el agujero del
  `backend/.env` duplicado al que el README dedica una sección entera de
  diagnóstico.

- **`SESSION_SECRET` y `ANALYTICS_SERVICE_INTERNAL_TOKEN` no existen en la
  nube** —no hay sesión de Express que firmar ni servicio interno que
  autenticar— pero **se conservan en `.env.example`** porque
  `backend/src/server.js` lanza una excepción al arrancar sin la primera,
  y borrarlas de la plantilla rompería el desarrollo local antes de que
  los Sprints 4 y 6 retiren esos servicios. El bloque está etiquetado
  como «en retirada» y dice qué lo sustituye.

- **El subtítulo de la barra superior decía «localhost»** desde el primer
  commit. Con el dashboard servido desde una URL pública eso era
  simplemente falso, y todo el sistema de diseño se sostiene sobre que lo
  escrito coincida con lo que hace el código. Ahora sale de
  `VITE_ENTORNO`.

### Añadido — `.gitattributes`

El árbol de trabajo llegó al Sprint 1 con `backend/src/server.js` y
`motor-analitico/indicadores/tecnicos.py` marcados como modificados **sin
un solo cambio de contenido**: 359 inserciones y 359 borrados de las
mismas líneas. Era LF reescrito a CRLF por el editor o por la
sincronización de OneDrive.

En la Fase 1 eso era ruido molesto. En la Fase 2 es un problema real: la
CI corre en Linux y los runners no comparten el `core.autocrlf` de la
máquina de nadie. El repositorio fija LF. **Los dos ficheros sucios no
están incluidos en ningún commit de este sprint** — ver el runbook para
limpiarlos.

### Corregido — el runbook no decía cómo subir el código a GitHub

Los pasos 6, 7 y 8 del runbook daban por hecho que el código estaba en
GitHub, pero **ningún paso lo subía**. La carpeta local no tenía remoto
configurado y el repositorio de GitHub estaba vacío. De ahí salían dos
síntomas que parecían problemas distintos:

- Vercel solo ofrecía la raíz como *Root Directory*: no había ninguna
  carpeta que ofrecer.
- El paso 7 no podía ejecutarse: los workflows del ETL solo existían en
  los commits locales, y GitHub solo muestra *Run workflow* para
  workflows presentes en la rama por defecto.

El runbook gana un **paso 5b** con la subida y un pull request de
`fase-2/sprint-1` contra `master`. Ese PR es la primera ejecución real de
las tres puertas de la CI —tests, frontend y migraciones— en el entorno
de GitHub, y ninguna necesita secretos. Antes de escribir los comandos se
comprobó que ninguna rama lleva un `.env`, que el historial no contiene
secretos con forma real y que no se cuela ningún entorno virtual ni
`node_modules`.

### Cambiado — `vercel.json` a la raíz del repositorio

El runbook pedía fijar *Root Directory = `frontend`* en el panel de
Vercel. Ahora la configuración vive versionada en `vercel.json` en la
raíz: instala y compila dentro de `frontend/`, sirve `frontend/dist`, y
conserva las reescrituras SPA y las cabeceras de seguridad. *Root
Directory* se queda en `./` y no hay que tocarlo. `frontend/vercel.json`
se retira: dos ficheros de configuración para el mismo despliegue son
dos fuentes de verdad, y Vercel solo lee el del *Root Directory*.

Verificado simulando el build de Vercel desde la raíz, sin `.env` y con
las `VITE_*` como variables de entorno: instala, compila, y las variables
llegan al bundle aunque `envDir` apunte a una raíz sin `.env`, porque
Vite las toma de `process.env`.

### Añadido — `scripts/verificar_paso_7.sql`

Consulta de solo lectura para el SQL Editor de Supabase que devuelve 15
comprobaciones con su veredicto. Existe porque ni la máquina del dueño ni
el entorno de trabajo pueden alcanzar Supabase directamente —la política
de red lo bloquea en los dos lados— así que la verificación tiene que
poder hacerla él en un paso y leerse sin interpretación.

Distingue las tres situaciones que desde fuera parecen iguales («no veo
datos»): el ETL nunca corrió, corrió y falló, o corrió bien. La
comprobación 10 es la que importa: cada cripto debe tener ~30 velas con
rango real y el resto reconstruidas. Si todas salen con rango real, el
ATR se está calculando sobre velas sin recorrido intradía. Probada contra
una base recién migrada y contra una pasada simulada correcta.

### Cambiado — D3 firmada: no se cifra ningún importe

La regla protegida nº7 de la Fase 1 («cualquier dato de cartera que se
persista pasa por AES-256-GCM») queda **retirada en la Fase 2** por
decisión del dueño, el 2026-09-20.

El equipo proponía una excepción parcial: cifrar solo la cartera
importada y dejar en claro los saldos ficticios del simulador. El dueño
resolvió de forma más simple y más coherente: **en este sistema ningún
importe es dinero real**, ni los del simulador ni los de la cartera. Si
el dato no es real, cifrarlo no protege nada y sí cuesta bastante.

- `cartera_posiciones` pasa de `precio_compra_cifrado text` y
  `monto_cifrado text` a `precio_compra numeric(20,8)` y
  `monto numeric(20,2)`, ambos con `CHECK` de rango.
- Lo que se gana, comprobado: `select sum(monto)` funciona. Con importes
  cifrados, el corte semanal de los agentes y el P&L habrían tenido que
  descifrar la tabla entera en aplicación en cada evaluación, y además
  habría sido imposible indexar u ordenar por importe.
- `services/cifrado.js` deja de tener destino en la nube. Su último uso
  es descifrar las filas que existan en el PostgreSQL local al migrarlas
  (H-16); después, `PORTFOLIO_ENCRYPTION_KEY` se puede borrar.

**La condición que sostiene la decisión** queda escrita en tres sitios —
el comentario de la tabla, el doc 00 §4 y la regla nº7 del README — para
quien la lea dentro de un año: el supuesto es que ningún importe
corresponde a una posición real. Si algún día se cargan cifras reales de
patrimonio, la decisión deja de ser válida y hay que revisarla ANTES de
importarlas. Lo que queda protegiendo esos datos es RLS más el cifrado en
reposo del proveedor: protege frente a terceros, no frente a una consulta
autorizada. Por eso H-21 y H-33 obligan a decírselo al usuario en la
propia pantalla.

### Cambiado — la semilla pasa a ser una migración, y `psql` sale del arranque

`supabase/seed.sql` se convierte en
`supabase/migrations/0003_semilla_universo_fase1.sql`.

El motivo inmediato fue práctico: `seed.sql` solo lo aplica
`supabase db reset` en local, así que cargarlo en el proyecto remoto
exigía `psql`, que en Windows no viene instalado. El arranque pedía
instalar un cliente de PostgreSQL entero para insertar 24 filas.

El argumento de fondo es mejor: esos 24 símbolos **no son datos de
ejemplo**, son datos de referencia sin los cuales el ETL no tiene nada
que escanear. Eso es exactamente lo que va en una migración. El
`on conflict do nothing` la hace idempotente, así que reaplicarla nunca
duplica ni pisa lo que el usuario haya cambiado desde la interfaz.

Con esto, **todo el paso 3 del runbook es un solo `supabase db push`** y
las verificaciones se hacen desde el SQL Editor del panel. `psql` ya no
aparece en el camino crítico; solo lo usa `keep-alive.yml`, que corre en
Linux.

El runbook gana además una nota sobre el error más común aquí: la URL del
proyecto (`https://<ref>.supabase.co`, para el cliente y el ETL) y la
cadena de conexión (`postgresql://postgres:…@db.<ref>.supabase.co:5432/…`,
para `psql` y `pg_dump`) son dos cosas distintas. `psql` habla el
protocolo de PostgreSQL por el puerto 5432, no HTTPS: apuntarlo a la URL
de la API no puede funcionar ni con el cliente instalado.

### Añadido — puerta de migraciones, porque no hay staging

Restricción descubierta al arrancar el despliegue: el tier gratuito de
Supabase da **dos proyectos activos** y uno ya lo ocupa otra aplicación.
El dashboard se queda con uno, que es producción. **No hay staging.**

Eso cambia el modo de trabajo: cada migración que se mergea llega a
producción sin escala intermedia, y el plan gratuito tampoco incluye
recuperación a un punto en el tiempo, así que una migración destructiva
no se deshace.

- **`.github/workflows/migraciones.yml`** ocupa ese hueco. Levanta un
  PostgreSQL 15 limpio en cada pull request, aplica las migraciones
  **desde cero** junto con la semilla, y ejecuta doce invariantes.

- **`supabase/pruebas/01_invariantes.sql`** las contiene, escritas con
  `raise exception` en vez de con pgTAP para no añadir una dependencia.
  Las que de verdad protegen algo: que el `CHECK` del contrato rechace
  una señal incoherente en las dos direcciones; que `ratio_rr` calcule
  `(tp−precio)/(precio−sl)`; que una señal no operable conserve
  soporte y resistencia pero no tenga `sl`/`tp`; que
  `v_velas_con_rango` deje fuera las velas reconstruidas; que ninguna
  tabla se quede sin RLS; que ninguna `SECURITY DEFINER` se quede sin
  `search_path`; y que la retención **nunca** borre una señal
  referenciada por una orden.

- **Verificado en negativo, que es lo que distingue una puerta de un
  adorno**: quitar el `CHECK` del contrato, olvidar un
  `ENABLE ROW LEVEL SECURITY` o resetear el `search_path` de una
  `SECURITY DEFINER` ponen el job en rojo con el mensaje que nombra la
  invariante rota.

- **Las extensiones se separan a `0002_extensiones.sql`.** `pg_cron` y
  `pg_net` son lo único del esquema que necesita un PostgreSQL de
  Supabase y no vale uno cualquiera. Aislarlas es lo que permite aplicar
  el resto sobre un Postgres limpio sin filtrar líneas con `sed` en la CI.

### Detectado — dos hallazgos del presupuesto de cuotas

Ninguno de los dos se ve diseñando sobre pizarra; los dos aparecen al
poner números.

- **La tabla `senales` con histórico completo revienta el tier gratuito en
  menos de un año.** Con 150 activos y 48 pasadas diarias son ~2,6 M de
  filas y ~600 MB, y Supabase da 500 MB. Sin corregirlo, el sistema
  funciona seis meses y luego deja de escribir señales sin explicación
  aparente. `fn_retencion_senales()` aplica una política por ventanas —30
  días completos, un año comprimido a una señal por activo y día, después
  se borra— con una excepción inviolable: **una señal referenciada por una
  orden es evidencia del experimento y nunca se borra**. Verificado con
  datos sintéticos: de 3 señales del mismo día a 60 días quedó 1, de 2
  señales a 400 días quedó solo la atada a una orden.

- **El ETL de cripto a 20 monedas por pasada excede los 2.000 min/mes de
  GitHub Actions** (~2.880). Cada moneda cuesta dos llamadas con 6 s de
  espaciado. El ETL prioriza: las criptos con una posición abierta se
  actualizan en **todas** las pasadas; el resto rota por antigüedad de
  `ultimo_etl_en`, máximo 5. Consumo total estimado del sistema:
  **1.078 min/mes, el 54 % de la cuota.**

### Detectado — pendiente de decisión

- **D3 sigue abierta y es la que bloquea el Sprint 5**: si los importes
  del simulador se cifran como exige la regla protegida nº7, el corte
  semanal de los agentes no se puede evaluar en SQL. La recomendación del
  equipo es no cifrar dinero ficticio y mantener el cifrado solo en la
  cartera real importada. Rechazarla cuesta +21 puntos de estimación.
- **La ventana de cron de acciones es ancha a propósito** (13:00-21:00 UTC)
  y la decisión real la toma `ventana_mercado.py` en hora de Nueva York.
  Los festivos de NYSE **no** se contemplan: en un festivo yfinance
  devuelve la última sesión válida y la pasada reescribe la misma vela por
  `UPSERT`. Es idempotente, pero conviene saberlo antes de investigar por
  qué el 4 de julio hay una pasada que no cambió nada.

## [Sin publicar] - 2026-09-20

### Añadido — borrado de cartera, registro persistente y `.env.example`

- **Control visual para `DELETE /api/portfolio`**, el último endpoint que
  seguía sin forma de invocarse desde la interfaz. Vive en una zona
  separada del panel de cartera, con línea divisoria propia: el borrado es
  físico y sin deshacer, así que no debe poder pulsarse por inercia
  mientras se opera con lo cotidiano. Exige confirmación en dos pasos y
  enumera antes qué va a destruir — las posiciones de la sesión **y** el
  registro cifrado de PostgreSQL. Verificado: cancelar no envía ninguna
  petición; confirmar envía exactamente un `DELETE` y deja el panel en su
  estado vacío.
- **El registro de eventos ya no se pierde al recargar.** Se guardan los
  últimos 50 en `localStorage`, con cada lectura y escritura protegida
  porque el almacenamiento puede estar bloqueado (ventana privada) y
  quedarse sin historial nunca debe impedir que el panel monte. El pie del
  panel ofrece vaciarlo. No viajan a ningún servidor: son avisos de
  sistema, no datos de cartera.
- **`.env.example`**, que el README mandaba copiar desde el primer día
  pero no existía. Documenta solo las variables que el código lee de
  verdad, y separa explícitamente las que están declaradas pero todavía
  sin leer (`LEVERAGE_HARD_CAP_FASE2` y las `FASE_TRANSICION_*`, que hoy
  viven como valores por defecto en `ParametrosRiesgo`): cambiarlas en el
  `.env` no tiene efecto, y conviene que eso no sorprenda a nadie.
- Corregido el pie del escáner, que seguía diciendo que las señales de
  cripto se apoyan en menos indicadores. Ahora explica que la vela diaria
  de cripto es reconstruida y que solo los últimos 30 días tienen rango
  real, que es la limitación que de verdad queda.

### Cambiado — velas diarias coherentes entre acciones y cripto

Implementa `docs/propuesta-velas-ventanas.md`, aprobada por el dueño
(decisiones D1–D7 en su §0). Cierra los dos "pendientes de decisión" sobre
velas del 2026-08-27 y del 2026-08-28.

- **La vela diaria de cripto pasa a reconstruirse** con dos llamadas sin
  clave por moneda (`conectores/coingecko.py`): `/market_chart` da
  cierres, precio vivo y volumen; `/ohlc` a 4 h, agregado por día, da
  máximos y mínimos de los últimos 30 días. CoinGecko no sirve velas
  diarias con rango real en su tier gratuito, y una clave Demo tampoco lo
  resolvería.
- **El ATR y el soporte/resistencia se calculan solo sobre las filas con
  máximo y mínimo reales.** No es un detalle: calcularlos sobre el frame
  completo inflaba el ATR de BTC un 16 % y le cambiaba el tramo de
  volatilidad.
- **La ventana de acciones pasa de 6 meses a 2 años**, así que `SMA_200`
  por fin se calcula y `cruce_medias` empieza a votar. Era un indicador
  que existía en el código y no emitía señal nunca.
- `requirements.txt` fija `pandas-ta==0.4.71b0`: el cálculo del ATR sobre
  un subconjunto depende de cómo se toma la semilla, y estaba sin fijar.
- 22 casos de prueba nuevos (`tests/test_velas_y_ventanas.py`), sin red.
  **69 en total, todos en verde**, y los 47 anteriores pasan sin tocar ni
  una línea.

**Efecto medido sobre el riesgo — el apalancamiento sube.** Es consecuencia
buscada de corregir la escala, no un efecto colateral, y el tope duro sigue
siendo infranqueable.

- **Cripto**: el ATR% cae a la mitad (BTC 5,48 → 2,61; ETH 6,86 → 3,65),
  que es el factor ≈ √4 de pasar de velas de 4 días a diarias. La base de
  apalancamiento sube un tramo en ambas.
- **Acciones**: el ATR% **no se mueve ni una centésima** — ya estaba
  convergido con 126 velas. Todo el aumento viene de que `cruce_medias`
  empieza a votar. En una muestra de 6 tickers reales, 4 suben de tramo y
  2 llegan al tope de 5,0×. Es una subida más amplia de lo que sugerían
  los ejemplos de la propuesta.
- **El precio de cripto deja de ir desfasado.** Era el cierre de la última
  vela de 4 días completa, hasta 4 días por detrás del real; ahora son 15
  minutos como máximo. Afectaba también al P&L de cartera.
- **Los niveles de cripto se estrechan mucho**: la ventana de 20 velas son
  ahora 20 días y no ~80. En BTC, el riel pasa de cubrir un 32,2 % del
  precio a un 8,7 %, así que el stop queda mucho más cerca y la pérdida
  hasta él no crece en proporción al apalancamiento.

**Aviso de despliegue**: las señales cambian de forma visible el mismo día.
En BTC, la fila pasa de «alcista, 2,0× operable» a «neutral, no operable»,
porque el MACD cambia de signo al calcularse en diario. Es correcto, no es
un fallo. Las cifras de cripto anteriores a este cambio no son comparables
con las de ahora.

- `soporte`/`resistencia` **pueden ser nulos** cuando no hay volatilidad
  utilizable. El camino ya existía pero ningún test lo ejercitaba; el
  frontend no debe asumirlos no nulos (ya degrada correctamente).
- Se actualizaron las entradas de la guía de lectura que habían quedado
  siendo falsas: cripto ya no «se apoya en menos indicadores», el cruce de
  medias ya no «no aporta», y «confluencia alta» deja de ser excepcional.
  En su lugar, la guía explica ahora que la vela de cripto es reconstruida
  y que su ATR se apoya en solo 30 días.

### Añadido — `docs/` para análisis y propuestas

- `docs/propuesta-velas-ventanas.md`: propuesta del especialista en
  indicadores para conseguir velas diarias coherentes entre acciones y
  cripto. **Aprobada el mismo día**; las respuestas del dueño a D1–D7
  quedan registradas en su §0 y mandan sobre el resto del documento.
  Incluye la
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
- **[RESUELTO 2026-09-20 — velas diarias]** **Para cripto el riel cubre ~80 días, no 20.** CoinGecko agrega las velas
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

- **[RESUELTO 2026-09-20 — velas diarias reconstruidas]** **CoinGecko devuelve velas de 4 días con `days=180`** (comportamiento
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
