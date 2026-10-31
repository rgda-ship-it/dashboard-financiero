# El sistema hoy

> **Para qué sirve**: la foto de cómo funciona el sistema **ahora**, en
> una página. Los documentos de diseño (`fase-2/`, `fase-3/`) cuentan por
> qué se decidió cada cosa y en qué orden; muchos describen reglas que ya
> cambiaron. Si un documento antiguo y este no coinciden, **manda este** y,
> para lo que pasó entre medias, [`CRONOLOGIA.md`](CRONOLOGIA.md).
> **Comprobado contra producción**: 2026-10-27 (estrategias de
> `agentes.estrategia`, tareas de `pg_cron` y workflows); la salida por
> deterioro y la versión, de nuevo el 2026-10-31.
> **Cómo mantenerlo**: quien cambie una regla de las de abajo actualiza su
> fila en el mismo PR.

---

## 1. Qué es

Un dashboard personal en la nube (coste 0 €) con:

- **Escáner**: señales de confluencia técnica sobre 32 acciones (NYSE y
  Nasdaq) y 15 criptos, con el veredicto «Comprar / Esperar / No comprar»
  y sus niveles (doc fase-3/04).
- **Simulador**: cuentas de 500 $ con dinero ficticio, apalancamiento con
  tope, spread y huecos reales.
- **Agentes**: cuatro cuentas que operan solas en el simulador.
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
| Salida por deterioro | **no** (la apagó sola el 29-10, ver doc fase-3/09 §3) | **no** (la apagó sola el 15-10) | **no** (la apagó sola el 15-10) |
| Umbral de rotación | 2,0 | 1,5 | 1,2 |
| Apalancamiento propio máximo | 3× | 5× | 5× |
| Versión de la estrategia | 9 | 9 | 8 |

Común a los tres:

- **Ciclo cada 5 minutos** (`ciclo-agentes`). Deciden con la señal
  intradía del ETL (de 90 minutos como mucho).
- **Stop y objetivo** (D21, 0030): stop en el soporte acotado entre 1 y 2
  ATR; objetivo en la resistencia, como mucho a 2 ATR. Por eso compran
  **retrocesos** (doc fase-3/05 §3).
- **Límites**: el saldo para operar (con menos de 10 $ libres no abren
  nada), el riesgo abierto total (G6, 4 × su riesgo por operación) y por
  clase en cripto. **No hay tope de número de posiciones** desde la 0023
  (la columna `max_posiciones_abiertas` ya no se usa).
- **48 h sin volver a un activo** tras su stop (0043).
- **Solo largos** (regla protegida nº2).
- **Cuarentena y riesgo reducido suspendidos** durante el experimento
  (`consecuencias_semanales = false`, 0042): el corte semanal calcula la
  nota pero no la aplica.
- **Ajustes automáticos congelados** (0052): con las consecuencias
  suspendidas no cambian solos su rotación, toma parcial ni deterioro.
  Las decisiones se siguen registrando y resolviendo; al acabar el
  experimento se ajustan con toda esa evidencia (0016, 0024). Los dos
  ajustes de antes (15-10 y 29-10) se quedan. Ver `CRONOLOGIA.md` §4.

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

## 3. Datos y tareas programadas

| Tarea | Cuándo (UTC) | Dónde |
|---|---|---|
| ETL de acciones | :07 y :37 con el mercado abierto; respaldo de GitHub 14:45, 17:45, 20:45 L–V | `etl-disparo` (pg_cron → GitHub), `etl-acciones.yml` |
| ETL de cripto | :07 cada hora; respaldo cada 3 h | `etl-disparo`, `etl-cripto.yml` |
| Monitor de órdenes (stop, objetivo, huecos) | cada minuto | `monitor-ordenes` |
| Ciclo de los agentes con metas | cada 5 min | `ciclo-agentes` |
| Decisión de Tendencia cripto | :20 de 01 a 07 | `decision-estrategias` |
| Seguimiento tras el stop | :45 cada hora | `seguir-stops` |
| Credenciales | 07:00 a diario | `revisar-credenciales` |
| Corte semanal | lunes 00:07 | `corte-semanal` |
| Autodiagnóstico e hipótesis | lunes 00:17 | `autodiagnostico-agentes` |
| Prueba de las hipótesis | lunes 02:00 (GitHub puede retrasarlo horas) | `hipotesis.yml` |
| Respaldo y latido | lunes 06:00 | `keep-alive.yml` |

- **Proveedores**: Yahoo Finance (acciones, sin clave) y CoinGecko
  (cripto). El spread de Nasdaq no se mide (0041).
- **Credenciales**: ver la tabla `credenciales` o el panel «Salud del
  sistema». Solo una importa a corto plazo: `github_pat_altas` (Vault),
  sin caducidad.

## 4. Cómo se revisa

- **Cada lunes**: `python scripts/consultar.py -f scripts/revision_agentes.sql`
  (doc fase-3/07 §6).
- **Salud**: Administración → Sistema.
- **Peticiones e hipótesis de los agentes**: Administración →
  Investigación. Durante el experimento se responden con datos; lo
  validado se guarda para el final.
- **Laboratorio**: `laboratorio.yml` (a mano) y `hipotesis.yml` (lunes).
  Su concordancia con los agentes se mide solo con las reglas de hoy.

## 5. Cómo se trabaja

| Paso | Quién |
|---|---|
| Código y migraciones: rama, PR, CI en verde y merge | Claude |
| Aplicar migraciones en producción (`scripts/aplicar-migraciones.cmd`) | Dueño |
| Consultas de solo lectura a producción (`scripts/consultar.py`) | Claude |
| Decisiones sobre el experimento y los agentes | Dueño |
