@echo off
rem Dev stack helper for Windows (macOS/Linux/WSL: ./ptx). up/down/logs drive Docker Compose;
rem anything else runs "ptx <command>" in the Panel container. "ptx help" lists those commands.
rem   ptx up           build the image (first run) and start; re-run after changing .env
rem   ptx down [-v]    stop the stack; -v also deletes the database and Panel state
rem   ptx logs [svc]   follow the panel, queue and scheduler logs
setlocal
pushd "%~dp0"
if /i "%~1"=="up" goto up
if /i "%~1"=="down" goto down
if /i "%~1"=="logs" goto logs
docker compose exec panel ptx %*
goto done

:up
if not exist .env copy .env.example .env >nul
docker compose up -d --build
if errorlevel 1 goto upfailed
docker compose logs --no-log-prefix --tail=1 setup
goto done

:upfailed
docker compose logs --no-log-prefix --tail=40 setup
popd
exit /b 1

:down
docker compose down %2 %3
goto done

:logs
if "%~2"=="" (
  docker compose logs -f --tail=100 panel queue scheduler
) else (
  docker compose logs -f --tail=100 %2 %3 %4
)

:done
set "rc=%errorlevel%"
popd
exit /b %rc%
