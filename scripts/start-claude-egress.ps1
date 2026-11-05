# Start Claude traffic through a self-hosted VPS, fail-closed.
#
#   powershell -ExecutionPolicy Bypass -File .\start-claude-egress.ps1 -Claude
#   powershell -ExecutionPolicy Bypass -File .\start-claude-egress.ps1 -Web -BrowserDir C:\path\to\browser
#   powershell -ExecutionPolicy Bypass -File .\start-claude-egress.ps1 -CheckOnly
#
# Requires: an ssh alias in ~/.ssh/config, and a sing-box "mixed" inbound on
# 127.0.0.1:<RemotePort> on the VPS.
#
# Design rule: every check aborts on failure. Nothing here ever falls back to
# a direct connection. Egress IP pinning is mandatory (see -ExpectedIp).

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SshHost    = 'claude-vps',
    [int]$LocalPort     = 7891,
    [int]$RemotePort    = 7890,
    [string]$ExpectedIp = '',        # or $env:CLAUDE_EGRESS_EXPECTED_IP
    [switch]$Web,
    [switch]$NoClaude,
    [switch]$CheckOnly,
    [switch]$Claude,                 # explicit form; starting Claude is the default
    [string]$BrowserDir = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    $ClaudeArgs
)

$ErrorActionPreference = 'Stop'

$ProxyUrl = "http://127.0.0.1:$LocalPort"
$Forward  = "127.0.0.1:{0}:127.0.0.1:{1}" -f $LocalPort, $RemotePort

if ($SshHost -notmatch '^[A-Za-z0-9_.@-]+$') {
    throw "Fail-closed: unsafe -SshHost '$SshHost' (allowed: letters, digits, _ . @ -)."
}

function Test-Port([int]$p) {
    return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

function Get-PortOwner([int]$p) {
    $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if (-not $conn) { return $null }
    try {
        return Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction Stop
    } catch {
        return $null
    }
}

function Assert-TunnelOwner {
    # A listening port is not proof of a tunnel. If something else owns 7891,
    # using it would silently route Claude through an unknown proxy.
    $owner = Get-PortOwner $LocalPort
    if (-not $owner) {
        Write-Warning "Cannot identify the process listening on $LocalPort; relying on the egress-IP check only."
        return
    }
    if ($owner.Name -ne 'ssh.exe') {
        throw "Fail-closed: port $LocalPort is held by '$($owner.Name)' (PID $($owner.ProcessId)), not the tunnel. Aborting."
    }
    if ($owner.CommandLine -notmatch [regex]::Escape($Forward) -or
        $owner.CommandLine -notmatch [regex]::Escape($SshHost)) {
        throw "Fail-closed: ssh owns $LocalPort but is not the expected forward ($Forward via $SshHost). Aborting."
    }
}

function ConvertTo-ArgLine([string[]]$items) {
    # Start-Process joins arguments with spaces without quoting. Quote every
    # element so values containing spaces or option-like text stay one argv.
    ($items | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
}

function Start-Tunnel {
    $sshArgs = @(
        '-N',
        '-L', $Forward,
        '-o', 'BatchMode=yes',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=4',
        '-o', 'TCPKeepAlive=yes',
        $SshHost
    )
    Start-Process -FilePath 'ssh.exe' -WindowStyle Hidden -ArgumentList (ConvertTo-ArgLine $sshArgs)
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Port $LocalPort) { return $true }
    }
    return $false
}

# --- 0. egress IP must be pinned -------------------------------------------
if (-not $ExpectedIp) { $ExpectedIp = $env:CLAUDE_EGRESS_EXPECTED_IP }
if (-not $ExpectedIp -and -not $CheckOnly) {
    throw "Fail-closed: -ExpectedIp (or `$env:CLAUDE_EGRESS_EXPECTED_IP) is required. " +
          "Refusing to start without pinning the egress IP."
}

# --- 1. local port, and who owns it ----------------------------------------
if (-not (Test-Port $LocalPort)) {
    Write-Host "Starting SSH tunnel 127.0.0.1:$LocalPort -> ${SshHost}:127.0.0.1:$RemotePort ..."
    Start-Tunnel | Out-Null
    if (-not (Test-Port $LocalPort)) {
        throw ("Fail-closed: tunnel 127.0.0.1:$LocalPort did not come up. " +
               "If $SshHost is a new host, run 'ssh $SshHost' once to accept its host key.")
    }
}
Assert-TunnelOwner

# --- 2. egress IP must be the VPS ------------------------------------------
# --noproxy "" matters: an inherited NO_PROXY (e.g. '*') would make curl skip
# -x and measure the direct path instead of the tunnel.
$ip = $null
try {
    $raw = & curl.exe -s --noproxy '' --max-time 15 -x $ProxyUrl 'https://ipwho.is/'
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $ip = (($raw -join '') | ConvertFrom-Json).ip
    }
} catch { }
if (-not $ip) {
    try {
        $raw = & curl.exe -s --noproxy '' --max-time 15 -x $ProxyUrl 'https://api.ipify.org'
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $ip = ($raw -join '').Trim()
        }
    } catch { }
}
if (-not $ip) {
    throw "Fail-closed: cannot confirm egress IP through the proxy. Aborting."
}
if ($CheckOnly -and -not $ExpectedIp) {
    Write-Warning "ExpectedIp not set; egress is '$ip' but there is nothing to compare it to."
} elseif ($ip -ne $ExpectedIp) {
    throw "Fail-closed: egress IP is '$ip', expected '$ExpectedIp'. Aborting."
}

# --- 3. Anthropic API reachable (any HTTP status counts) -------------------
$apiCode = & curl.exe -s --noproxy '' -o NUL -w "%{http_code}" --max-time 20 -x $ProxyUrl 'https://api.anthropic.com/v1/messages'
if ($LASTEXITCODE -ne 0 -or -not $apiCode -or $apiCode -eq '000') {
    throw "Fail-closed: api.anthropic.com is not reachable through the proxy. Aborting."
}

if ($Web) {
    $webCode = & curl.exe -s --noproxy '' -o NUL -w "%{http_code}" --max-time 25 -x $ProxyUrl 'https://claude.ai/'
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
$env:ALL_PROXY   = $ProxyUrl
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
        # The launcher applies its own expected_ip check before opening Chrome.
        & $py $launch --config config.local.json --profile claude --expected-ip $ExpectedIp
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    exit $code
}

if ($NoClaude) {
    Write-Host 'Tunnel ready. Claude Code not started (-NoClaude).'
    exit 0
}

Write-Host "Starting Claude Code with HTTPS_PROXY=$ProxyUrl ..."
& claude @ClaudeArgs
exit $LASTEXITCODE
