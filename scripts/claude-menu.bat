@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Capture %~dp0 before enabling delayed expansion: a path containing '!'
rem would otherwise be mangled by the delayed-expansion phase.
set "HERE=%~dp0"
setlocal EnableDelayedExpansion
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
if defined CLAUDE_EGRESS_EXPECTED_IP echo   egress IP: !CLAUDE_EGRESS_EXPECTED_IP!
echo ============================================
choice /c 12345 /n /m "Select [1-5]: "

if errorlevel 5 exit /b %RC%
if errorlevel 4 goto watch
if errorlevel 3 goto check
if errorlevel 2 goto web
if errorlevel 1 goto cli
goto menu

:askip
if not defined CLAUDE_EGRESS_EXPECTED_IP goto askip_input
call :validip
if not errorlevel 1 goto askip_done
echo Invalid egress IP in CLAUDE_EGRESS_EXPECTED_IP.
set "CLAUDE_EGRESS_EXPECTED_IP="
goto askip_input

:askip_input
echo.
echo No egress IP pinned. The launcher will refuse to start.
set /p "CLAUDE_EGRESS_EXPECTED_IP=Expected VPS egress IP: "
call :validip
if errorlevel 1 goto askip_bad
goto askip_done

:askip_bad
echo Invalid IPv4 address.
set "CLAUDE_EGRESS_EXPECTED_IP="
goto askip_input

:askip_done
exit /b 0

:validip
powershell -NoProfile -Command "$s=$env:CLAUDE_EGRESS_EXPECTED_IP; if ($s -notmatch '^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$') { exit 1 }; $ip=$null; if (-not [System.Net.IPAddress]::TryParse($s, [ref]$ip)) { exit 1 }"
exit /b !ERRORLEVEL!

:cli
call :askip
powershell -NoProfile -ExecutionPolicy Bypass -File "!HERE!start-claude-egress.ps1" -Claude
set "RC=!ERRORLEVEL!"
if not "!RC!"=="0" echo.& echo [FAIL] exit !RC! & pause
goto menu

:web
call :askip
powershell -NoProfile -ExecutionPolicy Bypass -File "!HERE!start-claude-egress.ps1" -Web -BrowserDir "!HERE!..\browser"
set "RC=!ERRORLEVEL!"
if not "!RC!"=="0" echo.& echo [FAIL] exit !RC! & pause
goto menu

:check
call :askip
powershell -NoProfile -ExecutionPolicy Bypass -File "!HERE!start-claude-egress.ps1" -CheckOnly
set "RC=!ERRORLEVEL!"
pause
goto menu

:watch
powershell -NoProfile -ExecutionPolicy Bypass -File "!HERE!watch-tunnel.ps1"
goto menu
