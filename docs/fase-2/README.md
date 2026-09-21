# Fase 2 — Dashboard Financiero en la nube, multiusuario y con agentes

> **Autor**: Equipo virtual de Fase 2 (ver `00-equipo-y-alcance.md` §1)
> **Fecha**: 2026-09-20
> **Estado**: **Propuesta** — pendiente de aprobación del dueño
> **Alcance**: convertir el dashboard de un instrumento local monousuario
> en un servicio cloud multiusuario con simulador de trading y tres
> agentes autónomos, con **coste de infraestructura 0 €**.

---

## Cómo leer este paquete

Los cinco documentos están pensados para leerse en orden, pero cada uno es
autónomo y tiene un destinatario distinto:

| # | Documento | Para quién | Qué resuelve |
|---|-----------|-----------|--------------|
| 0 | [`00-equipo-y-alcance.md`](00-equipo-y-alcance.md) | Dueño / PM | Equipo virtual, As-Is de la Fase 1, las 7 decisiones que necesitan tu firma, riesgos |
| A | [`01-modelo-de-datos.md`](01-modelo-de-datos.md) | Data Engineer / Backend | Entidad-relación, DDL PostgreSQL completo, RLS, vistas |
| B | [`02-arquitectura-y-stack.md`](02-arquitectura-y-stack.md) | Arquitecto / DevOps | Topología cloud, por qué cada pieza, presupuesto de cuotas gratuitas |
| C | [`03-logica-de-agentes.md`](03-logica-de-agentes.md) | Backend / Quant | Pseudocódigo del ciclo de agente, interés compuesto, corte semanal, guardarraíles |
| D | [`04-sprint-backlog.md`](04-sprint-backlog.md) | Devs / QA | 34 historias con tareas técnicas y criterios de aceptación |
| R | [`RUNBOOK-sprint-1.md`](RUNBOOK-sprint-1.md) | Dueño | Los 11 pasos con credenciales del Sprint 1 y su lista de verificación |

---

## Resumen ejecutivo en diez líneas

1. **El motor Python no se toca.** 1.660 líneas con 69 tests en verde y ocho
   reglas de riesgo protegidas. Cambia *cuándo* se ejecuta, no *qué* calcula:
   pasa de servicio HTTP en vivo a **job programado que escribe en la base de datos**.
2. **El backend Express desaparece.** Sesión → Supabase Auth; pool de
   PostgreSQL → Supabase; proxy al motor → ya no hace falta; WebSocket →
   Supabase Realtime. Tres de sus servicios sí se portan (§2.4 del doc 0).
3. **La base de datos deja de ser un anexo y pasa a ser el centro.** Todo
   —precios, señales, órdenes, saldos, agentes— vive en PostgreSQL. Las APIs
   externas se consultan una vez por activo y día, nunca por usuario.
4. **Los tres agentes son deterministas.** Deciden con las señales que ya
   calcula el motor, no con un LLM. Coste 0 real y backtesting reproducible.
5. **Las metas de 2 %, 5 % y 7 % diario son un test de estrés, no un plan.**
   Llegar a 1 M$ exige 384, 156 y 113 días respectivamente. El valor del
   experimento es el `agente_backlog` que generan y la distribución de
   Game Overs, no el millón.
6. **Sin guardarraíles duros, el agente del 7 % muere el primer día.** El
   diseño limita riesgo por operación, margen total comprometido y
   concurrencia — si no, la decisión racional es apostar todo (doc C §4).
7. **El monitor de TP/SL corre en Postgres, no en Vercel.** El plan Hobby de
   Vercel limita el cron a **una vez al día**; `pg_cron` baja a 30 segundos.
8. **El coste 0 se sostiene, pero con tres cuellos de botella reales**:
   la cuota de CoinGecko (~10-15 req/min, 2 llamadas por cripto), los
   2.000 min/mes de GitHub Actions, y que **los dos proyectos de Supabase
   están ocupados** — uno por otra aplicación del dueño, el otro por
   producción. Sin staging, la puerta de migraciones de la CI pasa de
   buena práctica a control compensatorio.
9. **Una regla protegida de la Fase 1 queda retirada**: el cifrado de los
   importes (nº7), por la decisión D3 ya firmada — ningún importe del
   sistema es dinero real. Las otras siete se mantienen intactas y
   auditadas una a una en el doc 0 §3.
10. **Estimación**: 34 historias, 179 puntos, 6 sprints. El simulador es
    jugable al final del Sprint 5; los agentes arrancan en el Sprint 6.

---

## Las siete decisiones que bloquean el arranque

Ninguna historia del Sprint 1 empieza sin que estas siete estén cerradas.
El detalle y el razonamiento de cada una está en `00-equipo-y-alcance.md` §4.

| ID | Decisión | Recomendación |
|----|----------|---------------|
| D1 | Proveedor cloud ✅ firmada | Supabase (datos + auth + cron) + Vercel (frontend) + GitHub Actions (motor). **Un solo proyecto: sin staging remoto** |
| D2 | El motor Python se mantiene | **Sí** — contenedorizado como job programado |
| D3 ✅ | Cifrado de importes | **No se cifra nada.** Ningún importe del sistema es dinero real; cifrarlo no protege nada y rompe toda agregación SQL |
| D4 | Cerebro de los agentes | Determinista; capa LLM opcional y aislada para redactar racionales |
| D5 | Repo público o privado | Privado + presupuesto de 993 min/mes (público elimina el límite) |
| D6 | Sesgo corto para los agentes | **No en Fase 2** — la regla protegida nº2 se mantiene; los agentes lo pedirán vía backlog |
| D7 | Universo de activos por usuario | Techo de 25 activos por usuario y 150 globales, por cuota de proveedor |

---

## Lo que esta Fase 2 **no** incluye

Declarado explícitamente para que no se cuele por la puerta de atrás:

- **Dinero real.** Ni broker, ni KYC, ni custodia. Todo el simulador opera
  con importes ficticios.
- **Operaciones en corto.** Regla protegida nº2 de la Fase 1.
- **Cierre parcial, trailing stop y órdenes limitadas.** El simulador abre y
  cierra posiciones completas a mercado. Los agentes ya tienen previsto
  pedirlo vía `agente_backlog` (doc C §7.2) — que es exactamente la señal
  que debe decidir si entra en Fase 3.
- **Asesoramiento financiero.** El aviso legal es una historia del backlog
  (H-33), no una nota al pie.
- **Multi-divisa.** Todo en USD.
