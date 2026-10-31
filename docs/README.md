# Documentación del proyecto

> **Por dónde empezar**: [`SISTEMA-HOY.md`](SISTEMA-HOY.md) (cómo funciona
> ahora), [`ESTADO.md`](ESTADO.md) (qué falta y qué espera) y
> [`CRONOLOGIA.md`](CRONOLOGIA.md) (desde cuándo son comparables los
> datos). Todo lo demás explica por qué se decidió cada cosa.
>
> **Antes de dar algo por fallo**, mira en `CRONOLOGIA.md` si los datos
> son de reglas anteriores: es la causa más frecuente de falsas alarmas.

---

## 1. Los tres documentos vivos

Se actualizan en el mismo PR que el cambio que describen.

| Documento | Qué dice | Cuándo se toca |
|---|---|---|
| [`SISTEMA-HOY.md`](SISTEMA-HOY.md) | Las reglas vigentes de cada agente, las tareas programadas y cómo se revisa | Cuando cambia una regla, una tarea o un parámetro |
| [`ESTADO.md`](ESTADO.md) | Lo abierto, lo previsto y lo que espera, con su motivo; y lo hecho | Al cerrar o abrir una tarea |
| [`CRONOLOGIA.md`](CRONOLOGIA.md) | Fechas de corte, incidentes, intervenciones y ajustes automáticos | Con cada migración que cambie cómo se opera, y con cada incidente |

Además, en la raíz: [`../CHANGELOG.md`](../CHANGELOG.md), la bitácora
entrada por entrada (lo más reciente arriba).

## 2. Diseño y resultados (por qué)

**Vigente** = describe cómo es hoy. **Registro** = sigue siendo la
referencia de por qué se decidió. **Histórico** = superado; útil solo para
entender el pasado. Cada documento lleva su vigencia en la cabecera.

### Fase 3 (desde el 2026-10-24): fiabilidad y laboratorio

| Doc | Tema | Vigencia |
|---|---|---|
| [`fase-3/00`](fase-3/00-diagnostico-y-plan.md) | Diagnóstico del 24-10 y plan E1–E9 | Foto de ese día |
| [`fase-3/01`](fase-3/01-agentes-investigadores.md) | Agentes investigadores: hipótesis H1–H4, I1–I5 | Vigente |
| [`fase-3/02`](fase-3/02-cortos-en-el-laboratorio.md) | Cortos: sin ventaja; Audacia sin acciones de menos de 10 $ | Vigente |
| [`fase-3/03`](fase-3/03-stops.md) | Los stops: qué salvan y qué cortan; entrada escalonada | Vigente |
| [`fase-3/04`](fase-3/04-escaner-y-guia.md) | El escáner dice qué hacer; la guía | Vigente |
| [`fase-3/05`](fase-3/05-indicadores.md) | ADX y media de 20; los agentes compran retrocesos | Vigente |
| [`fase-3/06`](fase-3/06-adx-completo.md) | Lo que faltaba del ADX; Santo Grial en cripto | Vigente |
| [`fase-3/07`](fase-3/07-revision-del-backlog.md) | Backlog revisado (E3), concordancia, revisión de los lunes | Vigente |
| [`fase-3/08`](fase-3/08-que-falta.md) | Qué falta para cumplir los objetivos (2026-10-27) | Vigente |
| [`fase-3/09`](fase-3/09-hackeo-binance-y-fundamentales.md) | El hackeo a Binance (29-10); fundamentales gratuitos | Vigente |

### Fase 2 (2026-09-20 → 10-13): la nube, el simulador y los agentes

| Doc | Tema | Vigencia |
|---|---|---|
| [`fase-2/00`](fase-2/00-equipo-y-alcance.md) | Equipo, punto de partida y alcance | Histórico |
| [`fase-2/01`](fase-2/01-modelo-de-datos.md) | Modelo de datos | Parcial: manda `supabase/migrations/` |
| [`fase-2/02`](fase-2/02-arquitectura-y-stack.md) | Arquitectura y stack | Vigente en lo esencial |
| [`fase-2/03`](fase-2/03-logica-de-agentes.md) | Lógica de los agentes, guardarraíles G1–G6 | Parcialmente superado |
| [`fase-2/04`](fase-2/04-sprint-backlog.md) | Historias y decisiones D1–D24 | Registro |
| [`fase-2/05`](fase-2/05-agentes-conscientes-del-tiempo.md) | Agentes conscientes del tiempo (entregas A–E) | Parcial |
| [`fase-2/06`](fase-2/06-laboratorio-y-agentes-con-ventaja.md) | Laboratorio y criterio de ventaja | Vigente |
| [`fase-2/07`](fase-2/07-agente-tendencia-cripto.md) | Tendencia cripto | Vigente |
| [`fase-2/README`](fase-2/README.md) | Índice de la Fase 2 | Histórico |
| [`propuesta-velas-ventanas.md`](propuesta-velas-ventanas.md) | Velas y ventanas (Fase 1 → 2) | Histórico |

### Procedimientos

| Doc | Para qué | Vigencia |
|---|---|---|
| [`fase-2/RUNBOOK-sprint-4.md`](fase-2/RUNBOOK-sprint-4.md) | Renovar el token de GitHub (sección «Renovación») | Vigente esa sección |
| [`fase-2/RUNBOOK-sprint-1.md`](fase-2/RUNBOOK-sprint-1.md), [`RUNBOOK-sprint-6.md`](fase-2/RUNBOOK-sprint-6.md) | Montaje inicial y puesta en marcha | Histórico |

## 3. Herramientas

| Herramienta | Para qué |
|---|---|
| `scripts/revision_agentes.sql` | La revisión de los lunes (fase-3/07 §6) |
| `scripts/consultar.py` | Consultas de solo lectura a producción |
| `scripts/aplicar-migraciones.cmd` | Aplicar migraciones (lo hace el dueño) |
| `scripts/diagnostico_agentes*.sql`, `ensayo_tendencia.sql`, `verificar_paso_7.sql` | Diagnósticos puntuales ya hechos; se conservan como ejemplo |
| `.github/workflows/laboratorio.yml` | Laboratorio de estrategias, a mano |

## 4. Cómo escribir un documento nuevo

- En `fase-3/` (o la fase en curso), numerado: `08-tema.md`.
- Cabecera con **Para qué sirve**, **Método** si hay datos, y la fecha.
- Cualquier análisis de datos de producción dice **desde qué fecha** los
  toma y por qué (ver `CRONOLOGIA.md`).
- Si cambia una regla: actualizar `SISTEMA-HOY.md`, `CRONOLOGIA.md`,
  `ESTADO.md` y `CHANGELOG.md` en el mismo PR.
