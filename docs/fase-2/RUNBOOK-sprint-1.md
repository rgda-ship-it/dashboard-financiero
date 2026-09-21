# Runbook del Sprint 1 — lo que solo puedes hacer tú

> **Fecha**: 2026-09-20
> **Rama**: `fase-2/sprint-1`
> **Estado**: código listo y verificado; pendiente de las cuentas

El código del Sprint 1 está escrito, probado y commiteado. Lo que queda
son once pasos que requieren tus credenciales: crear cuentas, copiar
claves y pulsar botones. Ninguno lleva más de cinco minutos y el orden
importa, porque cada uno produce el secreto que necesita el siguiente.

Al final hay una **lista de verificación** con los criterios de
aceptación de las siete historias, para que el sprint se cierre contra
hechos y no contra impresiones.

---

## Antes de empezar: dos avisos

**1. Había dos ficheros "modificados" sin cambios reales. Ya están limpios.**
`backend/src/server.js` y `motor-analitico/indicadores/tecnicos.py`
aparecían como modificados con 359 inserciones y 359 borrados de las
**mismas** líneas: era LF reescrito a CRLF por el editor o por la
sincronización de OneDrive.

**No están incluidos en ningún commit de este sprint** — y con
`.gitattributes` ya en el repositorio, `git status` los da por limpios,
porque Git normaliza al comparar y su contenido coincide con el blob que
ya estaba en `HEAD`. El problema se resolvió solo al fijar la norma.

Si en algún momento vuelven a aparecer sucios, es que algo está
reescribiendo finales de línea; renormalizar de una vez:

```bash
git add --renormalize .
```

**2. La rama por defecto es `master`, no `main`.** Los workflows apuntan a
`master`. Si algún día la renombras, hay que tocar los seis ficheros de
`.github/workflows/`.

---

## Paso 1 — El proyecto de Supabase

Usa el proyecto libre que ya tienes, o crea uno nuevo si prefieres
partir de cero. **Es el único que va a tener el dashboard**: el tier
gratuito permite dos proyectos activos y el otro lo ocupa tu otra
aplicación.

Si lo creas ahora, en [supabase.com](https://supabase.com) → **New
project**, región Europa. Guarda la contraseña de la base de datos que
te pide al crearlo: **no se puede volver a ver** y la necesitas en el
paso 4.

> Anota el **Project Ref** (la cadena de la URL del panel).

### Lo que implica no tener staging

Esto no es un detalle administrativo: cambia cómo se trabaja a partir de
ahora. **Cada migración que mergees a `master` llega a producción sin
escala intermedia**, y el tier gratuito tampoco incluye recuperación a un
punto en el tiempo, así que una migración destructiva no se deshace.

La cadena de validación que ocupa ese hueco es:

```
  supabase start          ->   .github/workflows/      ->   supabase db push
  (Docker, en tu máquina)      migraciones.yml              (producción)
   opcional, recomendado        OBLIGATORIO, automático
```

`migraciones.yml` levanta un PostgreSQL 15 limpio en cada pull request,
aplica las migraciones **desde cero** junto con la semilla, y ejecuta las
doce invariantes de `supabase/pruebas/01_invariantes.sql`. Entre ellas:

- el `CHECK` del contrato rechaza una señal incoherente;
- `v_velas_con_rango` deja fuera las velas reconstruidas;
- ninguna tabla se queda sin RLS;
- ninguna `SECURITY DEFINER` se queda sin `search_path`;
- la retención nunca borra una señal referenciada por una orden.

Verificado también en negativo: quitar el `CHECK`, olvidar un
`ENABLE ROW LEVEL SECURITY` o resetear un `search_path` ponen el job en
rojo. **Si ese workflow está en verde, la migración es segura de aplicar;
si no lo está, no la apliques aunque tengas prisa.**

---

## Paso 2 — Instalar la CLI y enlazar

```bash
npm install -g supabase
supabase login

cd C:\Users\ramir\OneDrive\Documentos\project\dashboard-financiero
supabase link --project-ref <REF_DE_PRODUCCION>
```

---

## Paso 3 — Aplicar el esquema

```bash
supabase db push
```

Y ya está. Eso aplica las cuatro migraciones:

| Migración | Qué hace |
|-----------|----------|
| `0000_base_fase1.sql` | Port del `schema.sql` de la Fase 1 + `usuario_id` |
| `0001_catalogo.sql` | `activos`, `precios_diarios`, `indicadores_diarios`, `senales`, vistas, retención |
| `0002_extensiones.sql` | `pg_cron` y `pg_net` |
| `0003_semilla_universo_fase1.sql` | Los 24 activos del universo de la Fase 1 |

> **No hace falta `psql`.** La semilla es una migración y no un
> `seed.sql` precisamente por esto: `supabase/seed.sql` solo lo aplica
> `supabase db reset` en local, y cargarlo en el proyecto remoto habría
> exigido instalar el cliente de PostgreSQL en Windows solo para
> insertar 24 filas. Además, esos 24 símbolos no son datos de ejemplo:
> son datos de referencia sin los cuales el ETL no tiene nada que
> escanear, y eso es exactamente lo que va en una migración.

**Verificación** — en el panel del proyecto → **SQL Editor**, pega esto:

```sql
select
  (select count(*) from public.activos)                          as activos,
  (select count(*) from public.activos where clase = 'accion')   as acciones,
  (select count(*) from public.activos where clase = 'cripto')   as criptos,
  (select count(*) from public.activos
    where estado = 'pendiente_backfill')                         as pendientes;
```

Debe devolver `24 | 21 | 3 | 24`.

> Si `0002_extensiones.sql` falla, habilita `pg_cron` y `pg_net` desde el
> panel → Database → Extensions y vuelve a lanzar `supabase db push`. No
> los necesita nada del Sprint 1; los necesita el monitor del Sprint 5.

### Si prefieres usar `psql` de todos modos

No hace falta para nada de este runbook, pero si lo quieres para trastear:

```powershell
winget install PostgreSQL.PostgreSQL.16
```

Y **la cadena de conexión no es la URL de la API**. Son dos cosas
distintas y confundirlas es el error más común aquí:

| | Para qué sirve | Aspecto |
|---|---|---|
| **Project URL** | El cliente JavaScript y el ETL, por HTTPS | `https://<ref>.supabase.co` |
| **Connection string** | `psql`, `pg_dump`, cualquier cliente de PostgreSQL | `postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres` |

`psql` habla el protocolo de PostgreSQL por el puerto 5432, no HTTPS:
apuntarlo a `https://<ref>.supabase.co/rest/v1/` no puede funcionar ni
con el cliente instalado. La cadena buena está en el panel →
**Settings → Database → Connection string → URI**.

---

## Paso 4 — Recoger las cuatro claves

Panel → **Settings → API**:

| Dónde | Qué copiar |
|-------|------------|
| Project URL | → `SUPABASE_URL` y `VITE_SUPABASE_URL` |
| `anon` / `public` | → `VITE_SUPABASE_ANON_KEY` |
| `service_role` / `secret` | → `SUPABASE_SERVICE_ROLE_KEY` |

Panel → **Settings → Database → Connection string → URI**:

| Qué copiar |
|------------|
| La URI con tu contraseña del paso 1 → `SUPABASE_DB_URL` |

> `SUPABASE_DB_URL` **solo** la usa el workflow `keep-alive.yml`, que
> corre en Linux y sí tiene `psql` y `pg_dump` instalados. Tú no la
> necesitas en tu máquina: va directa a los secretos de GitHub en el
> paso 6.

> **La `service_role key` elude Row Level Security por diseño.** No la
> pegues nunca en una variable que empiece por `VITE_`, ni en Vercel, ni
> en un fichero versionado. Solo en los secretos de GitHub Actions.

---

## Paso 5 — El `.env` local

```bash
cp .env.example .env
```

Rellena el bloque **FASE 2** con las claves del paso 4. El bloque
**FASE 1** solo hace falta si vas a seguir levantando el backend Express
en localhost.

---

## Paso 5b — Subir el código a GitHub

> **Añadido el 2026-09-21.** La primera versión de este runbook no lo
> incluía, y los pasos 6, 7 y 8 lo daban por hecho: sin código en GitHub
> no hay workflows que lanzar en el paso 7 ni carpetas que Vercel pueda
> ofrecer en el 8. Era un hueco del runbook, no un error tuyo.

Tu repositorio de GitHub está **vacío**, así que es una subida limpia: no
hay nada que forzar ni que fusionar. Antes de escribir estas líneas se
comprobó que ninguna rama contiene un `.env`, que el historial no lleva
secretos con forma real, y que no se cuela ningún entorno virtual ni
`node_modules`: 63 ficheros en `master`, 108 en la rama del sprint,
menos de 1 MB.

GitHub te muestra la URL en la propia página del repositorio vacío, bajo
*«…or push an existing repository from the command line»*. En
PowerShell:

```powershell
cd C:\Users\ramir\OneDrive\Documentos\project\dashboard-financiero
git remote add origin https://github.com/<TU_USUARIO>/<TU_REPO>.git
git push -u origin master
git push -u origin fase-2/sprint-1
```

**`master` primero, y a propósito**: la primera rama que llega a un
repositorio vacío se convierte en la rama por defecto, y los siete
workflows apuntan a `master`.

### El pull request: la primera ejecución real de la CI

Tras el segundo `push`, GitHub mostrará un aviso *«fase-2/sprint-1 had
recent pushes»* con un botón **Compare & pull request**. Ábrelo contra
`master`.

Se lanzan solas **tres comprobaciones**, y ninguna necesita secretos:

| Check | Qué demuestra |
|-------|---------------|
| **Motor analítico (69 casos)** | Los 90 casos en verde en Linux, no solo en mi entorno |
| **Build y puerta anti-fuga** | El frontend compila y no lleva la clave de servicio |
| **Migraciones desde cero + invariantes** | El esquema se aplica limpio y cumple las 12 invariantes |

Es la primera vez que todo lo verificado en local se comprueba en el
entorno real de GitHub. **Cuando las tres estén en verde → Merge pull
request.** Si alguna falla, no fusiones: pásame el log.

> **Por qué no basta con subir la rama.** Los workflows programados —el
> ETL cada 30 minutos, el latido semanal— **solo corren desde la rama por
> defecto**, y el botón *Run workflow* del paso 7 solo aparece para
> workflows que existen en ella. Hasta que el PR no se fusione en
> `master`, el paso 7 no tiene nada que lanzar.

---

## Paso 6 — Los secretos de GitHub

Repositorio → **Settings → Secrets and variables → Actions → New
repository secret**. Cuatro secretos:

| Nombre | Valor |
|--------|-------|
| `SUPABASE_URL` | Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | clave `service_role` |
| `SUPABASE_DB_URL` | cadena de conexión con la contraseña |
| `SUPABASE_ANON_KEY` | clave `anon` (la usa la puerta anti-fuga para comparar) |

---

## Paso 7 — Primera pasada del ETL, a mano

Repositorio → **Actions → etl-acciones → Run workflow**, marcando
**forzar** (para que no espere a que abra la bolsa).

Debe terminar en verde y dejar en el resumen del job una tabla con los 21
tickers y, por cada uno, el número de velas y si quedó operable.

Luego lo mismo con **etl-cripto** (sin marcar nada).

**Verificación** — pega el contenido de `scripts/verificar_paso_7.sql`
en el **SQL Editor** del panel. Devuelve 15 comprobaciones con su
veredicto y distingue las tres situaciones que desde fuera parecen
iguales: el ETL nunca corrió, corrió y falló, o corrió bien. Si prefieres
mirar a mano, estas son las consultas clave:

```sql
-- Los 24 activos deben haber pasado a 'activo'.
select estado, count(*) from activos group by estado;

-- Debe haber señales, y ninguna incoherente (el CHECK lo impide, pero
-- conviene verlo).
select count(*) from senales;

-- La disciplina del rango real, para cripto:
select a.simbolo,
       count(*) filter (where p.rango_real) as con_rango_real,
       count(*) filter (where not p.rango_real) as reconstruidas
  from precios_diarios p join activos a on a.id = p.activo_id
 where a.clase = 'cripto'
 group by a.simbolo;
```

> **Lo que hay que mirar de verdad en esa última consulta**: cada cripto
> debe tener del orden de **30 velas con rango real** y **cientos
> reconstruidas**. Si salieran todas con rango real, el ATR estaría
> calculándose sobre velas sin recorrido intradía y volvería a inflarse
> — fue lo que subió el ATR de BTC un 16 % en la Fase 1.

**Y la comprobación que cierra el sprint**: compara el `atr_pct` de una
señal recién escrita con lo que devuelve hoy tu `/internal/scan` local
para el mismo ticker. Deben coincidir. Si no, algo se perdió en la
traducción y hay que entenderlo **antes** de seguir al Sprint 2.

---

## Paso 8 — Vercel

> **Cambiado el 2026-09-21.** La versión anterior pedía fijar *Root
> Directory = `frontend`*. Ya no hace falta: la configuración vive en
> `vercel.json` en la **raíz** del repositorio, versionada, y le dice a
> Vercel que instale y compile dentro de `frontend/` y que sirva
> `frontend/dist`. Un ajuste de interfaz que se puede elegir mal pasa a
> ser un fichero que revisa la CI.

Si ya importaste el proyecto con el repositorio vacío, no hace falta
borrarlo: basta con revisar estos ajustes en **Settings → General** y
**Settings → Build & Deployment**.

| Ajuste | Valor |
|--------|-------|
| **Root Directory** | `./` — **no lo cambies** |
| Framework Preset | *Other* |
| Build / Output / Install Command | Déjalos sin sobrescribir: manda `vercel.json` |

**Environment Variables** — solo tres, ninguna es la de servicio, y
**marca los tres entornos** (Production, Preview, Development) para que
también funcionen las previsualizaciones de cada PR:

| Nombre | Valor |
|--------|-------|
| `VITE_SUPABASE_URL` | Project URL |
| `VITE_SUPABASE_ANON_KEY` | clave `anon` |
| `VITE_ENTORNO` | `nube` |

### Lo que vas a ver, en orden

1. **Al subir `master`**, Vercel intentará desplegarla y **fallará**. Es
   lo esperado: `master` todavía es la Fase 1 y no tiene `vercel.json`
   en la raíz. No hay que hacer nada.
2. **Al subir `fase-2/sprint-1`**, Vercel crea una **previsualización**
   de esa rama, que sí tiene la configuración nueva. Esa URL de
   previsualización ya debería mostrar el dashboard: es la prueba de que
   el despliegue funciona **antes** de fusionar.
3. **Al fusionar el PR**, `master` pasa a tener `vercel.json` y el
   despliegue de producción se arregla solo.

---

## Paso 9 — Abrir la URL pública

Debes ver la terminal con su sistema de diseño intacto —tokens, cifras
tabulares, medidores— la tira de navegación nueva con cinco módulos, y
tres estados honestos:

- **Escáner**: con datos si el ETL ya corrió. Si las señales aún no son
  legibles para un usuario anónimo, un mensaje que lo explica. No una
  pantalla rota.
- **Cartera** y **stream de eventos**: «pendiente de migración».
- **Cartera / Simulador / Agentes / Admin** en el menú: con su distintivo
  de sprint y una pantalla que dice qué habrá ahí y qué historias lo
  entregan.

---

## Paso 10 — Comprobar la puerta anti-fuga

Vale la pena verificar que funciona, porque el día que haga falta será
tarde. En una rama desechable:

```bash
git checkout -b prueba/fuga
echo 'const x = "service_role_de_prueba";' >> frontend/src/supabase.js
git commit -am "prueba: la CI debe rechazar esto"
git push origin prueba/fuga
```

El workflow `frontend` debe fallar en el paso **«Puerta anti-fuga de la
clave de servicio»**. Luego borra la rama.

---

## Paso 11 — Proteger `master`

Repositorio → **Settings → Branches → Add branch protection rule**:

- Branch name pattern: `master`
- ✅ Require status checks to pass before merging
- Checks obligatorios: **`Motor analítico (69 casos)`**, **`Build y puerta anti-fuga`** y **`Migraciones desde cero + invariantes`**

El tercero es el que más importa aquí: sin staging, es lo único que se
interpone entre un pull request y la base de datos de producción.

Esto es lo que convierte los tests en una puerta y no en una costumbre.

---

## Lista de verificación del sprint

| Historia | Criterio | ✓ |
|----------|----------|---|
| — | El código está en GitHub y el PR de `fase-2/sprint-1` se fusionó con los tres checks en verde | ☐ |
| H-01 | `supabase db push` reconstruye el esquema sin pasos manuales | ☐ |
| H-01 | El workflow `migraciones` está en verde en la rama | ☐ |
| H-01 | `activos` tiene 24 filas tras la semilla | ☐ |
| H-02 | Un PR que rompa una regla protegida no se puede mergear | ☐ |
| H-02 | El resumen del job informa de 90 casos, no solo del total | ☐ |
| H-03 | La URL pública muestra la terminal con su diseño intacto | ☐ |
| H-03 | Ningún panel aparece roto: los no migrados se declaran pendientes | ☐ |
| H-04 | El artefacto de respaldo se descarga y se restaura en local | ☐ |
| H-04 | `fn_retencion_senales()` devuelve JSON sin error | ☐ |
| H-05 | Un `workflow_dispatch` manual escribe filas en `senales` | ☐ |
| H-05 | Ni un `NaN` en la tabla (el CHECK del contrato no salta) | ☐ |
| H-05 | El `atr_pct` coincide con el del `/internal/scan` local | ☐ |
| H-06 | La navegación no recarga la página | ☐ |
| H-06 | `ScannerTable.jsx` no cambió ni una línea | ☐ |
| H-07 | Un commit con la clave de servicio en el frontend falla el build | ☐ |
| H-07 | `.env.example` refleja lo que el código lee de verdad | ☐ |

---

## Qué NO está hecho, y es correcto que no lo esté

El Sprint 1 es infraestructura. Estas cosas están **fuera de alcance por
diseño**, no olvidadas:

- **Nadie puede iniciar sesión.** No hay autenticación hasta el Sprint 3.
- **Las tablas del catálogo tienen RLS activada y sin políticas**, así que
  la clave anónima no lee nada. Es el estado seguro por defecto: las
  políticas llegan con `es_usuario_aprobado()` en H-14. Mientras tanto el
  escáner en la URL pública sale vacío **con su mensaje**, que es
  exactamente el criterio de aceptación de H-03.
- **La cartera sigue necesitando el backend local.** Migra en el Sprint 4.
- **El monitor de órdenes y los agentes no existen.** Sprints 5 y 6.
- **`pg_cron` está habilitado pero no dispara nada.** Su primer trabajo
  programado llega con el monitor del Sprint 5.
- **No hay entorno de staging y no lo va a haber** mientras el tier
  gratuito dé dos proyectos y el otro esté ocupado. La compensación es el
  workflow `migraciones`, no un tercer proyecto. Si en algún momento
  necesitas probar algo contra datos reales sin tocar producción, la vía
  es `supabase start` en local más el volcado del respaldo semanal que
  deja `keep-alive.yml` como artefacto.
