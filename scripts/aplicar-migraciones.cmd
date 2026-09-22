@echo off
REM ─────────────────────────────────────────────────────────────────────
REM  UNICA via para aplicar migraciones a produccion.
REM
REM  Por que existe: el repositorio es privado en una cuenta gratuita de
REM  GitHub, y ahi las reglas de proteccion de rama NO se aplican. Nada
REM  impide tecnicamente fusionar un PR con la CI en rojo. Lo que protege
REM  la base de datos es que solo cambia al ejecutar `supabase db push`,
REM  asi que el freno va aqui: no se aplica nada sin mirar antes el
REM  resultado del workflow `migraciones` sobre master.
REM
REM  No hay staging ni recuperacion a un punto en el tiempo: una
REM  migracion destructiva aplicada no se deshace.
REM ─────────────────────────────────────────────────────────────────────
chcp 65001 >nul
setlocal
cd /d "%~dp0.."

REM  [0] Las migraciones se aplican SIEMPRE desde master al dia. El
REM  2026-09-22 este script se ejecuto con la carpeta en la rama de un PR
REM  sin fusionar y aplico sus migraciones: `supabase db push` usa los
REM  ficheros de la carpeta, no los de GitHub. Esta guardia lo impide.
echo.
echo  [0/3] Poniendo tu carpeta en master y al dia con GitHub...
git diff --quiet
if errorlevel 1 goto :cambios
git diff --cached --quiet
if errorlevel 1 goto :cambios
git switch master
if errorlevel 1 goto :fallo_git
git pull --ff-only origin master
if errorlevel 1 goto :fallo_git
goto :al_dia
:cambios
echo.
echo  [X] Tu carpeta tiene cambios sin guardar en git. No se aplica nada. Avisa a Claude.
pause
exit /b 1
:fallo_git
echo.
echo  [X] No se pudo poner la carpeta en master al dia. No se aplica nada. Avisa a Claude.
pause
exit /b 1
:al_dia

echo.
echo  ==================================================
echo    APLICAR MIGRACIONES A PRODUCCION
echo  ==================================================
echo.
echo  [1/3] Abriendo el ultimo resultado de la CI de migraciones en master...
start "" "https://github.com/rgda-ship-it/dashboard-financiero/actions/workflows/migraciones.yml?query=branch%%3Amaster"
echo.
echo  Mira la PRIMERA fila de la lista que se ha abierto en el navegador.
echo  Tiene que tener el circulo VERDE con la marca de visto.
echo.
set /p OK=  ¿Esta en verde? Escribe S y pulsa Enter para seguir: 
if /i not "%OK%"=="S" (
  echo.
  echo  [X] No se aplica nada. Si la CI esta en rojo, avisa a Claude.
  pause
  exit /b 1
)

echo.
echo  [2/3] Migraciones: locales frente a las ya aplicadas en Supabase
echo  (las que tengan columna Remote vacia son las que se van a aplicar)
echo.
call supabase migration list
echo.

echo  [3/3] Aplicando. Supabase pedira confirmacion: revisa la lista y
echo  responde Y solo si son las migraciones que esperabas.
echo.
call supabase db push
if errorlevel 1 (
  echo.
  echo  [X] supabase db push fallo o se cancelo. Avisa a Claude.
  pause
  exit /b 1
)
echo.
echo  [OK] Migraciones aplicadas.
pause
