@echo off
setlocal
set HERE=%~dp0

:menu
cls
echo ============================================
echo   Claude Egress Gateway
echo ============================================
echo   1. Claude Code (through VPS)
echo   2. Claude web (through VPS)
echo   3. Check only (verify tunnel + egress IP)
echo   4. Keep tunnel alive (watcher)
echo   5. Exit
echo ============================================
set /p CHOICE=Select [1-5]:

if "%CHOICE%"=="1" goto cli
if "%CHOICE%"=="2" goto web
if "%CHOICE%"=="3" goto check
if "%CHOICE%"=="4" goto watch
if "%CHOICE%"=="5" exit /b 0
goto menu

:cli
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-claude-egress.ps1" -Claude
pause
goto menu

:web
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-claude-egress.ps1" -Web -BrowserDir "%HERE%..\browser"
pause
goto menu

:check
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-claude-egress.ps1" -CheckOnly
pause
goto menu

:watch
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%watch-tunnel.ps1"
goto menu
