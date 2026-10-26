# Dashboard financiero — notas para Claude

- **Idioma**: todo en español (código, comentarios, documentos, commits,
  PR y respuestas), tratando al dueño de tú.
- **Antes de empezar**: `docs/README.md` (índice), `docs/SISTEMA-HOY.md`
  (cómo funciona ahora) y `docs/ESTADO.md` (lo abierto).
- **Antes de dar algo por fallo o sacar conclusiones de datos de
  producción**: `docs/CRONOLOGIA.md`. Las reglas cambiaron muchas veces
  (la 0030 el 10-10, la 0043 el 17-10, ajustes automáticos el 15-10) y
  mezclar datos de reglas distintas ha producido falsas alarmas una y
  otra vez. Todo análisis dice desde qué fecha toma los datos.
- **Producción**: solo lectura, con `scripts/consultar.py` (rol
  `analista_lectura`). Nunca la URL de administrador. Las migraciones las
  aplica el dueño con `scripts/aplicar-migraciones.cmd`.
- **Flujo**: rama, PR, CI en verde y merge. Una migración nueva lleva su
  invariante en `supabase/pruebas/01_invariantes.sql`; la CI de
  migraciones se reproduce en local con Docker (`postgres:15`).
- **Al cambiar una regla de los agentes, el ETL o el simulador**:
  actualizar en el mismo PR `docs/SISTEMA-HOY.md`, `docs/CRONOLOGIA.md`,
  `docs/ESTADO.md` y `CHANGELOG.md`.
- **Grupo de control**: Prudencia, Cadencia y Audacia no se cambian a mano
  mientras dure el experimento; lo validado en el laboratorio se guarda
  para el final.
