@echo off
setlocal
set "HERE=%~dp0"
set "RC=0"

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
if defined CLAUDE_EGRESS_EXPECTED_IP echo   egress IP: %CLAUDE_EGRESS_EXPECTED_IP%
echo ============================================
set /p CHOICE=Select [1-5]:

if "%CHOICE%"=="1" goto cli
if "%CHOICE%"=="2" goto web
if "%CHOICE%"=="3" goto check
if "%CHOICE%"=="4" goto watch
if "%CHOICE%"=="5" exit /b %RC%
goto menu

:askip
if not defined CLAUDE_EGRESS_EXPECTED_IP (
    echo.
    echo No egress IP pinned. The launcher will refuse to start.
    set /p CLAUDE_EGRESS_EXPECTED_IP=Expected VPS egress IP:
)
exit /b 0

:cli
call :askip
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-claude-egress.ps1" -Claude
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo.& echo [FAIL] exit %RC% & pause
goto menu

:web
call :askip
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-claude-egress.ps1" -Web -BrowserDir "%HERE%..\browser"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo.& echo [FAIL] exit %RC% & pause
goto menu

:check
call :askip
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-claude-egress.ps1" -CheckOnly
set "RC=%ERRORLEVEL%"
pause
goto menu

:watch
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%watch-tunnel.ps1"
goto menu
