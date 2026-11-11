# El sistema hoy

> **Para qué sirve**: la foto de cómo funciona el sistema **ahora**, en
> una página. Los documentos de diseño (`fase-2/`, `fase-3/`) cuentan por
> qué se decidió cada cosa y en qué orden; muchos describen reglas que ya
> cambiaron. Si un documento antiguo y este no coinciden, **manda este** y,
> para lo que pasó entre medias, [`CRONOLOGIA.md`](CRONOLOGIA.md).
> **Comprobado contra producción**: 2026-10-27 (estrategias de
> `agentes.estrategia`, tareas de `pg_cron` y workflows); la salida por
> deterioro, según la 0053 (2026-10-31); la versión y las prácticas, el
> 2026-11-10.
> **Cómo mantenerlo**: quien cambie una regla de las de abajo actualiza su
> fila en el mismo PR.

---

## 1. Qué es

Un dashboard personal en la nube (coste 0 €) con:

- **Escáner**: señales de confluencia técnica sobre 32 acciones (NYSE y
  Nasdaq) y 15 criptos, con el veredicto «Comprar / Esperar / No comprar»
  y sus niveles (doc fase-3/04). Además, dos índices **solo de referencia**
  (S&P 500 y Nasdaq 100, 0058): se leen para la vara y no se operan.
- **Simulador**: cuentas de 500 $ con dinero ficticio, apalancamiento con
  tope, spread y huecos reales.
- **Agentes**: nueve cuentas que operan solas en el simulador: el grupo de
  control, Tendencia cripto, las tres v2 (0060) y dos carteras (0062).
- **Laboratorio**: reproduce años de velas diarias para decidir qué
  estrategia tiene ventaja antes de ponerla en un agente (doc fase-2/06).

**Es un experimento, no un sistema de inversión.** Ningún importe es
dinero real.

## 2. Los agentes

### 2.1 Grupo de control: agentes con metas diarias

Siguen como **grupo de control** mientras dura el experimento (doc
fase-2/06 §2; acaba como tarde el **2027-04-30**): sus reglas no se cambian a mano. Lo validado en el
laboratorio se guarda para el final (ESTADO §3.0).

| | Prudencia | Cadencia | Audacia |
|---|---|---|---|
| Meta diaria | 2 % | 5 % | 7 % |
| Riesgo por operación | 1,5 % | 3 % | 5 % |
| R:R mínimo | 1,5 | 1,3 | 1,2 |
| Banda de ATR (acciones) | ≤ 3 % | ≤ 2,3 % | ≥ 2,3 % |
| Banda de ATR (cripto) | ≤ 12 % | ≤ 4 % | ≥ 4 % |
| Fuerza de la señal | media o alta | media o alta | media o alta |
| Origen de los niveles | estructura | estructura o ATR | estructura o ATR |
| Toma parcial | 50 % a mitad de camino, stop a la entrada | 50 % a mitad de camino | no |
| Salida por deterioro | **sí** (dos lecturas, 0043; apagada sola el 29-10 y encendida de nuevo por la 0053) | **no** (la apagó sola el 15-10) | **no** (la apagó sola el 15-10) |
| Umbral de rotación | 2,0 | 1,5 | 1,2 |
| Apalancamiento propio máximo | 3× | 5× | 5× |
| Versión de la estrategia | 12 | 11 | 9 |
| Prácticas adoptadas (`mp_adopciones`) | 89 y 110 | 89 y 110 | 97 |

Común a los tres:

- **Ciclo cada 5 minutos** (`ciclo-agentes`). Deciden con la señal
  intradía del ETL (de 90 minutos como mucho).
- **Stop y objetivo** (D21, 0030): stop en el soporte acotado entre 1 y 2
  ATR; objetivo en la resistencia, como mucho a 2 ATR. Por eso compran
  **retrocesos** (doc fase-3/05 §3).
- **Saldo para operar** (0055, D25): **base × tope de la fase** (5× en
  Fase 1, 3× en Fase 2). La base es el saldo inicial o el último escalón
  alcanzado (1.000, 2.000, 5.000, 10.000, 15.000, 20.000, 25.000 y
  50.000 $) y **nunca baja**: sale del máximo del libro mayor. El tope de
  apalancamiento se mide sobre la base: cada tope (fase, propio y señal)
  se multiplica por base / equity, con 20× de techo. Con pérdidas, cada
  orden admite algo más de apalancamiento sobre el equity real; con
  ganancias que no tocan el escalón, algo menos. El riesgo por operación
  sigue siendo un % del equity real. Lo mismo en las cuentas del
  simulador; Tendencia cripto opera a 1× y no le afecta.
- **Límites**: el saldo para operar (con menos de 10 $ libres no abren
  nada), el riesgo abierto total (G6, 4 × su riesgo por operación) y por
  clase en cripto. **No hay tope de número de posiciones** desde la 0023
  (la columna `max_posiciones_abiertas` ya no se usa).
- **48 h sin volver a un activo** tras su stop (0043).
- **Solo largos** (regla protegida nº2).
- **Cuarentena y riesgo reducido suspendidos** durante el experimento
  (`consecuencias_semanales = false`, 0042): el corte semanal calcula la
  nota pero no la aplica.
- **Prácticas congeladas** (0061): con las consecuencias suspendidas, el
  corte semanal ya no les adopta ni les evalúa prácticas. Se quedan con
  las que tenían (la 89, la 97 y la 110, de 2-11 y 9-11), que no les han
  quitado ninguna entrada. Ver `CRONOLOGIA.md` §4.
- **Ajustes automáticos congelados** (0052): con las consecuencias
  suspendidas no cambian solos su rotación, toma parcial ni deterioro.
  Las decisiones se siguen registrando y resolviendo; al acabar el
  experimento se ajustan con toda esa evidencia (0016, 0024). Los dos
  ajustes del 15-10 se quedan; el del 29-10 de Prudencia lo deshizo la 0053. Ver `CRONOLOGIA.md` §4.

### 2.1 bis Agentes v2 (0060, doc fase-3/12 §4)

Tres agentes con metas nuevos, cada uno con su cuenta de 500 $. Siguen las
reglas comunes del §2.1, con los ajustes y las consecuencias congelados:

| | Prudencia v2 | Cadencia v2 | Audacia v2 |
|---|---|---|---|
| Reglas | Las de Prudencia | Las de Cadencia + solo con ADX(14) ≥ 25 | Las de Audacia + sin acciones de menos de 10 $ |
| Lo que espera el laboratorio | −0,041 R | −0,175 R | +0,054 R |

- `agentes.grupo_control` marca a Prudencia, Cadencia y Audacia, y
  `agentes.deriva_de`, el original de cada v2.
- **Añadir saldo** (Administración → Agentes, `rpc_aportar_saldo_agente`):
  solo fuera del grupo de control. Sube el saldo inicial y queda en el
  libro mayor (`aportacion`) y en la auditoría.
- Su veredicto está fijado en la 0060, con los umbrales de la 0059.
- **Llevan las prácticas de su original** (0061). Del 9-11 a la 0061
  tuvieron la 60, que exige acción y les cerró las cripto.

### 2.2 Experimento: Tendencia cripto (doc fase-2/07)

| | |
|---|---|
| Regla | Cierre sobre la media de 200 y sobre el máximo de 20 días → compra |
| Stop | 2 ATR, sube siguiendo al mejor cierre a 3 ATR |
| Salida | Cierre bajo el mínimo de 10 días, o el stop |
| Riesgo | 1 % por operación, a 1×, hasta 10 posiciones |
| Cuándo decide | Una vez por cripto y día, con la vela de ayer, de 01:20 a 07:20 UTC |
| Pausa | Si la caída desde el máximo supera el 35 % |
| Veredicto | A las 30 operaciones (doc 07 §6) o el **2027-04-30**, lo que llegue antes; si no hay 30, con las que haya |

### 2.3 Carteras (0062, doc fase-4/00 §7)

Dos agentes de `tipo = 'cartera'`, con 500 $ cada uno. Llevan cinco clases
de activo (SPY, EFA, IEF, VNQ y DBC) al 20 %, a 1×, sin stop ni objetivo.

| | Cartera sin tocar | Cartera con tendencia |
|---|---|---|
| Qué es | **La vara**: comprar y no hacer nada | Experimento, juzgado contra la vara |
| Regla | Compra una vez y mantiene | Cada clase, dentro si cerró el mes anterior sobre su media de 10 cierres mensuales; si no, en caja |
| Pausa por caída | No tiene | 25 % desde el máximo |
| Veredicto | No se juzga | Tras una caída del 15 % de la vara ya recuperada, o el 2031-11-30 |

- **Deciden una vez al mes**, los dos a la vez, en la primera sesión con
  precio fresco de los cinco. Hasta que los cinco ETF estén dados de alta
  y con 10 meses de historia, no hacen nada.
- **Los cinco ETF son solo suyos** (`activos.solo_cartera`): los demás
  agentes no los ven (`estado_activo = 'cartera'`), no cuentan en la vara
  del universo y ninguna otra cuenta puede abrirlos. Tienen vara propia
  («Cinco clases de activo»).
- G6 no les aplica. El simulador no paga dividendos ni reequilibra la
  cartera sin tocar.

## 3. Datos y tareas programadas

| Tarea | Cuándo (UTC) | Dónde |
|---|---|---|
| ETL de acciones | :07 y :37 con el mercado abierto; respaldo de GitHub 14:45, 17:45, 20:45 L–V | `etl-disparo` (pg_cron → GitHub), `etl-acciones.yml` |
| ETL de cripto | :07 cada hora; respaldo cada 3 h | `etl-disparo`, `etl-cripto.yml` |
| Monitor de órdenes (stop, objetivo, huecos) | cada minuto | `monitor-ordenes` |
| Ciclo de los agentes con metas | cada 5 min | `ciclo-agentes` |
| Decisión de Tendencia cripto | :20 de 01 a 07 | `decision-estrategias` |
| Decisión de las carteras | :50 de 14 a 20, los días 1 a 7 de cada mes | `decision-carteras` |
| Seguimiento tras el stop | :45 cada hora | `seguir-stops` |
| Credenciales | 07:00 a diario | `revisar-credenciales` |
| Corte semanal | lunes 00:07 | `corte-semanal` |
| Autodiagnóstico e hipótesis | lunes 00:17 | `autodiagnostico-agentes` |
| Prueba de las hipótesis | lunes 02:00, disparada desde `pg_cron` (0057; respaldo en GitHub a las 06:00) | `hipotesis-agentes` → `hipotesis.yml` |
| Respaldo y latido | lunes 06:00 | `keep-alive.yml` |

- **Proveedores**: Yahoo Finance (acciones, sin clave) y CoinGecko
  (cripto). El spread de Nasdaq no se mide (0041).
- **Credenciales**: ver la tabla `credenciales` o el panel «Salud del
  sistema». Solo una importa a corto plazo: `github_pat_altas` (Vault),
  sin caducidad.

## 4. Cómo se revisa

- **Cada lunes**: `python scripts/consultar.py -f scripts/revision_agentes.sql`
  (doc fase-3/07 §6). La sección `9b_escaner` mide qué hizo el precio 5 y
  10 sesiones después de cada veredicto del escáner, desde la 0030.
- **Comparativa de agentes** (Agentes): con la vara de comprar y mantener
  el universo (0056), del S&P 500 y del Nasdaq 100 (0058) y, bajo la expectativa, cuántas operaciones faltan
  para poder concluir con la dispersión observada.
- **Veredicto** (Agentes → Veredicto, 0059): el criterio de cada agente,
  fijado el 2026-11-05 y sin poder cambiarse (doc fase-3/12 §3): lo que
  espera el laboratorio y los umbrales de Tendencia cripto para todos.
- **Salud**: Administración → Sistema.
- **Peticiones e hipótesis de los agentes**: Administración →
  Investigación. Durante el experimento se responden con datos; lo
  validado se guarda para el final.
- **Laboratorio**: `laboratorio.yml` (a mano) y `hipotesis.yml` (lunes).
  Criterio frente al azar desde el 2026-11-05 (`laboratorio/criterio.py`,
  doc fase-3/12 §1): cuenta global de pruebas, el diseño también contra el
  azar y ventanas móviles.
  Su concordancia con los agentes se mide solo con las reglas de hoy.

## 5. Cómo se trabaja

| Paso | Quién |
|---|---|
| Código y migraciones: rama, PR, CI en verde y merge | Claude |
| Aplicar migraciones en producción (`scripts/aplicar-migraciones.cmd`) | Dueño |
| Consultas de solo lectura a producción (`scripts/consultar.py`) | Claude |
| Decisiones sobre el experimento y los agentes | Dueño |
