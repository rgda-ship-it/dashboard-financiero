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

## Paso 1 — Crear los dos proyectos de Supabase

El tier gratuito permite **exactamente dos proyectos activos**. No hay un
tercero para experimentar, así que son estos dos y no más:

| Proyecto | Nombre sugerido | Para qué |
|----------|-----------------|----------|
| 1 | `dashboard-financiero` | Producción |
| 2 | `dashboard-financiero-staging` | Pruebas de migraciones |

En [supabase.com](https://supabase.com) → **New project**. Región: la más
cercana a ti (Europa). Guarda la contraseña de la base de datos que te
pide al crearlo: **no se puede volver a ver** y la necesitas en el paso 4.

> Anota el **Project Ref** de cada uno (la cadena de la URL del panel).

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

Aplica `0000_base_fase1.sql` y `0001_catalogo.sql`. Después, la semilla
con los 24 activos del universo de la Fase 1:

```bash
psql "<SUPABASE_DB_URL>" -f supabase/seed.sql
```

**Verificación**: en el panel → Table Editor debe haber 7 tablas y la
tabla `activos` con 24 filas, todas en estado `pendiente_backfill`.

> Si `pg_cron` falla al crearse, habilítalo desde el panel →
> Database → Extensions y vuelve a lanzar `supabase db push`. No lo
> necesita nada del Sprint 1; lo necesita el monitor del Sprint 5.

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

**Verificación en la base de datos**:

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

[vercel.com](https://vercel.com) → **Add New → Project** → importar el
repositorio.

| Ajuste | Valor |
|--------|-------|
| **Root Directory** | `frontend` ← **imprescindible**: `vercel.json` vive ahí |
| Framework Preset | Vite (se detecta solo) |
| Build Command | `npm run build` |
| Output Directory | `dist` |

**Environment Variables** — solo tres, y ninguna es la de servicio:

| Nombre | Valor |
|--------|-------|
| `VITE_SUPABASE_URL` | Project URL |
| `VITE_SUPABASE_ANON_KEY` | clave `anon` |
| `VITE_ENTORNO` | `nube` |

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
- Checks obligatorios: **`Motor analítico (69 casos)`** y **`Build y puerta anti-fuga`**

Esto es lo que convierte los tests en una puerta y no en una costumbre.

---

## Lista de verificación del sprint

| Historia | Criterio | ✓ |
|----------|----------|---|
| H-01 | `supabase db push` reconstruye el esquema sin pasos manuales | ☐ |
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
