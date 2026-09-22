# Runbook del Sprint 4 — activar las altas automáticas

> Para Daniel. Se hace **una vez**, después de fusionar el PR del Sprint 4
> y de aplicar la migración 0010 con `scripts\aplicar-migraciones.cmd`.

Sin este paso todo funciona igual, pero un activo nuevo tarda hasta
**una hora** en darse de alta (lo recoge la pasada horaria del ETL de
cripto). Con él, tarda **1-3 minutos**.

## 1. Crear el token de GitHub (lo abre Claude en el navegador)

Token *fine-grained* con el mínimo permiso posible:

| Campo | Valor |
|---|---|
| Nombre | `dashboard-financiero-altas` |
| Caducidad | 1 año (anótalo: habrá que renovarlo) |
| Repositorio | solo `rgda-ship-it/dashboard-financiero` |
| Permisos | **Actions: Read and write**. Nada más |

GitHub lo muestra **una sola vez**. Cópialo.

## 2. Guardarlo en Supabase Vault (lo pegas tú)

En Supabase → SQL Editor, pega esto, **sustituye** `PEGA_AQUI_EL_TOKEN`
por el token y pulsa *Run*:

```sql
select vault.create_secret('PEGA_AQUI_EL_TOKEN', 'github_pat_altas',
       'Token de GitHub (Actions: write) para el workflow altas.yml');
```

El token queda cifrado en Vault. No va al código ni a GitHub.

## 3. Comprobarlo (lo hace Claude)

Buscar una acción que el catálogo no tenga y ver que en 1-3 minutos pasa
de «comprobando en Yahoo Finance…» a «al día» sin recargar.

## Renovación

Cuando caduque, crea otro igual y ejecuta en el SQL Editor:

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'github_pat_altas'),
  'PEGA_AQUI_EL_TOKEN_NUEVO');
```
