# Start Claude traffic through a self-hosted VPS, fail-closed.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\start-claude-egress.ps1 -Claude
#   powershell -ExecutionPolicy Bypass -File .\start-claude-egress.ps1 -Web -BrowserDir C:\path\to\browser
#   powershell -ExecutionPolicy Bypass -File .\start-claude-egress.ps1 -CheckOnly
#
# Requires: an ssh alias in ~/.ssh/config, and a sing-box "mixed" inbound
# listening on 127.0.0.1:<RemotePort> on the VPS.
#
# Design rule: every check below aborts on failure. Nothing here ever falls
# back to a direct connection.

param(
    [string]$SshHost   = 'claude-vps',
    [int]$LocalPort    = 7891,
    [int]$RemotePort   = 7890,
    [string]$ExpectedIp = '',        # recommended: pin your VPS Elastic IP
    [switch]$Web,
    [switch]$NoClaude,
    [switch]$CheckOnly,
    [string]$BrowserDir = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    $ClaudeArgs
)

$ErrorActionPreference = 'Stop'

$ProxyUrl = "http://127.0.0.1:$LocalPort"
$Forward  = "127.0.0.1:{0}:127.0.0.1:{1}" -f $LocalPort, $RemotePort

function Test-Port([int]$p) {
    return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

function Start-Tunnel {
    $sshArgs = @(
        '-N',
        '-L', $Forward,
        '-o', 'BatchMode=yes',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=4',
        '-o', 'TCPKeepAlive=yes',
        $SshHost
    )
    Start-Process -FilePath 'ssh.exe' -WindowStyle Hidden -ArgumentList $sshArgs
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Port $LocalPort) { return $true }
    }
    return $false
}

# --- 1. local port ---------------------------------------------------------
if (-not (Test-Port $LocalPort)) {
    Write-Host "Starting SSH tunnel 127.0.0.1:$LocalPort -> ${SshHost}:127.0.0.1:$RemotePort ..."
    Start-Tunnel | Out-Null
}
if (-not (Test-Port $LocalPort)) {
    throw "Fail-closed: tunnel 127.0.0.1:$LocalPort is not listening. Aborting; no direct connection will be used."
}

# --- 2. egress IP must be the VPS -----------------------------------------
$ip = $null
try {
    $raw = & curl.exe -s --max-time 15 -x $ProxyUrl 'https://ipwho.is/'
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $ip = (($raw -join '') | ConvertFrom-Json).ip
    }
} catch { }
if (-not $ip) {
    try {
        $raw = & curl.exe -s --max-time 15 -x $ProxyUrl 'https://api.ipify.org'
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $ip = ($raw -join '').Trim()
        }
    } catch { }
}
if (-not $ip) {
    throw "Fail-closed: cannot confirm egress IP through the proxy. Aborting."
}
if ($ExpectedIp) {
    if ($ip -ne $ExpectedIp) {
        throw "Fail-closed: egress IP is '$ip', expected '$ExpectedIp'. Aborting."
    }
} else {
    Write-Warning "ExpectedIp not set; egress is '$ip' but it was not pinned."
}

# --- 3. Anthropic API reachable (any HTTP status counts) -------------------
$apiCode = & curl.exe -s -o NUL -w "%{http_code}" --max-time 20 -x $ProxyUrl 'https://api.anthropic.com/v1/messages'
if ($LASTEXITCODE -ne 0 -or -not $apiCode -or $apiCode -eq '000') {
    throw "Fail-closed: api.anthropic.com is not reachable through the proxy. Aborting."
}

if ($Web) {
    $webCode = & curl.exe -s -o NUL -w "%{http_code}" --max-time 25 -x $ProxyUrl 'https://claude.ai/'
    if ($LASTEXITCODE -ne 0 -or -not $webCode -or $webCode -eq '000') {
        throw "Fail-closed: claude.ai is not reachable through the proxy. Aborting."
    }
    Write-Host "Proxy OK: egress $ip | api.anthropic.com -> HTTP $apiCode | claude.ai -> HTTP $webCode"
} else {
    Write-Host "Proxy OK: egress $ip | api.anthropic.com -> HTTP $apiCode"
}

if ($CheckOnly) {
    Write-Host 'Check-only: nothing launched.'
    exit 0
}

$env:HTTPS_PROXY = $ProxyUrl
$env:HTTP_PROXY  = $ProxyUrl
$env:NO_PROXY    = 'localhost,127.0.0.1,::1'

if ($Web) {
    if (-not $BrowserDir) { throw 'Missing -BrowserDir (the folder containing launch.py).' }
    $launch = Join-Path $BrowserDir 'launch.py'
    $py     = Join-Path $BrowserDir '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    if (-not (Test-Path $launch)) { throw "launch.py not found: $launch" }
    Write-Host 'Launching browser (fixed proxy, no fallback) ...'
    Push-Location $BrowserDir
    try {
        & $py $launch --config config.local.json --profile claude
        exit $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

if ($NoClaude) {
    Write-Host 'Tunnel ready. Claude Code not started (-NoClaude).'
    exit 0
}

Write-Host "Starting Claude Code with HTTPS_PROXY=$ProxyUrl ..."
& claude @ClaudeArgs
