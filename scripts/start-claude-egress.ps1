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
    [string]$ProxyUser = '',         # or $env:CLAUDE_EGRESS_PROXY_USER
    [string]$ProxyPassword = '',     # or $env:CLAUDE_EGRESS_PROXY_PASSWORD
    [switch]$AllowUnknownOwner,      # conscious override for gate 1b
    [switch]$AllowUnpinned,          # conscious override for -CheckOnly
    [Parameter(ValueFromRemainingArguments = $true)]
    $ClaudeArgs
)

$ErrorActionPreference = 'Stop'

$ProxyHostPort = "http://127.0.0.1:$LocalPort"
$ProxyUrl      = $ProxyHostPort
$Forward       = "127.0.0.1:{0}:127.0.0.1:{1}" -f $LocalPort, $RemotePort

# Optional proxy authentication (sing-box "users"). Credentials are URL-encoded
# into the proxy URL once, so both curl and the launched process receive them.
if (-not $ProxyUser)     { $ProxyUser     = $env:CLAUDE_EGRESS_PROXY_USER }
if (-not $ProxyPassword) { $ProxyPassword = $env:CLAUDE_EGRESS_PROXY_PASSWORD }
if ($ProxyUser -or $ProxyPassword) {
    if (-not ($ProxyUser -and $ProxyPassword)) {
        throw "Fail-closed: proxy authentication needs both -ProxyUser and -ProxyPassword."
    }
    $ProxyUrl = "http://{0}:{1}@127.0.0.1:{2}" -f `
        [uri]::EscapeDataString($ProxyUser), [uri]::EscapeDataString($ProxyPassword), $LocalPort
}

# The URL-encoded proxy URL already carries the credentials. Do not leave the
# raw values in this process environment: the CLI branch would pass them on to
# claude. The -Web branch re-adds them only around the browser launch.
Remove-Item Env:\CLAUDE_EGRESS_PROXY_USER -ErrorAction SilentlyContinue
Remove-Item Env:\CLAUDE_EGRESS_PROXY_PASSWORD -ErrorAction SilentlyContinue

# A leading '-' would reach ssh as an option; reject it before the allow-list.
if ($SshHost -notmatch '^(?!-)[A-Za-z0-9_.@-]+$') {
    throw "Fail-closed: unsafe -SshHost '$SshHost' (allowed: letters, digits, _ . @ -; cannot start with '-')."
}

# Match complete tokens, not substrings: 'claude-vps' must not match
# 'claude-vps-evil', and ':7890' must not match ':78901'. The forward must be
# the value of -L, and the host alias must be the final argument (how Start-Tunnel
# invokes ssh); this rejects -F path\claude-vps\... and ProxyJump=claude-vps.
$HostTokenPattern = '(?:^|\s)"?' + [regex]::Escape($SshHost) + '"?\s*$'
$ForwardPattern   = '-L\s+"?' + [regex]::Escape($Forward) + '"?(\s|$)'

# Resolve ssh.exe to an absolute path: CreateProcess searches the current
# directory first, so a planted ssh.exe could otherwise win.
$SshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
if (-not (Test-Path -LiteralPath $SshExe)) {
    $sshCmd = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if (-not $sshCmd) { throw 'Fail-closed: ssh.exe not found.' }
    $SshExe = $sshCmd.Source
}

function Test-Port([int]$p) {
    return [bool](Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

function Get-PortOwner([int]$p) {
    $conn = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
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
        if ($AllowUnknownOwner) {
            Write-Warning "Cannot identify the process on $LocalPort; continuing because -AllowUnknownOwner was given."
            return
        }
        throw ("Fail-closed: cannot identify the process listening on $LocalPort. " +
               "Refusing to trust an unverified proxy. Use -AllowUnknownOwner only if you accept that risk.")
    }
    if ($owner.Name -ne 'ssh.exe') {
        throw "Fail-closed: port $LocalPort is held by '$($owner.Name)' (PID $($owner.ProcessId)), not the tunnel. Aborting."
    }
    if (-not $owner.ExecutablePath -or $owner.ExecutablePath -ine $SshExe) {
        throw "Fail-closed: ssh on $LocalPort is '$($owner.ExecutablePath)', not $SshExe. Aborting."
    }
    if ($owner.CommandLine -notmatch $ForwardPattern -or
        $owner.CommandLine -notmatch $HostTokenPattern) {
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
    Start-Process -FilePath $SshExe -WindowStyle Hidden -ArgumentList (ConvertTo-ArgLine $sshArgs)
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
               "If $SshHost is a new host, verify its fingerprint and add it to known_hosts " +
               "(ssh-keyscan), or connect once with -o StrictHostKeyChecking=accept-new.")
    }
}
Assert-TunnelOwner

# --- 2. egress IP must be the VPS ------------------------------------------
# Use the "=" form. Windows PowerShell 5.1 silently drops an empty-string native
# argument, so `--noproxy ''` becomes `--noproxy --max-time 15`: the timeout is
# swallowed and `15` is fetched as a URL. `--noproxy=` survives intact and still
# prevents an inherited NO_PROXY (e.g. '*') from making curl skip -x.
$ip = $null
try {
    $raw = & curl.exe -s --noproxy= --max-time=15 -x $ProxyUrl 'https://ipwho.is/'
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $ip = (($raw -join '') | ConvertFrom-Json).ip
    }
} catch { }
if (-not $ip) {
    try {
        $raw = & curl.exe -s --noproxy= --max-time=15 -x $ProxyUrl 'https://api.ipify.org'
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $ip = ($raw -join '').Trim()
        }
    } catch { }
}
if (-not $ip) {
    throw "Fail-closed: cannot confirm egress IP through the proxy. Aborting."
}
if (-not $ExpectedIp) {
    if (-not $AllowUnpinned) {
        throw ("Fail-closed: -CheckOnly requires -ExpectedIp (or CLAUDE_EGRESS_EXPECTED_IP). " +
               "Use -AllowUnpinned only for a conscious one-off diagnostic.")
    }
    Write-Warning "Unpinned check: egress is '$ip' but there is no expected value to compare it to."
} elseif ($ip -ne $ExpectedIp) {
    throw "Fail-closed: egress IP is '$ip', expected '$ExpectedIp'. Aborting."
}

# --- 3. Anthropic API reachable (any HTTP status counts) -------------------
$apiCode = ((& curl.exe -s --noproxy= -o NUL -w "%{http_code}" --max-time=20 -x $ProxyUrl 'https://api.anthropic.com/v1/messages') -join '').Trim()
if ($LASTEXITCODE -ne 0 -or -not $apiCode -or $apiCode -eq '000') {
    throw "Fail-closed: api.anthropic.com is not reachable through the proxy. Aborting."
}

if ($Web) {
    $webCode = ((& curl.exe -s --noproxy= -o NUL -w "%{http_code}" --max-time=25 -x $ProxyUrl 'https://claude.ai/') -join '').Trim()
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
$env:https_proxy = $ProxyUrl
$env:http_proxy  = $ProxyUrl
$env:all_proxy   = $ProxyUrl
$env:no_proxy    = $env:NO_PROXY

# Re-check immediately before launch: the port could have changed hands between
# the first check and now (TOCTOU), and this narrows the window.
Assert-TunnelOwner

if ($Web) {
    if (-not $BrowserDir) { throw 'Missing -BrowserDir (the folder containing launch.py).' }
    try {
        $browserRoot = (Resolve-Path -LiteralPath $BrowserDir -ErrorAction Stop).Path
    } catch {
        throw "Browser directory not found: $BrowserDir"
    }
    $launch = Join-Path $browserRoot 'launch.py'
    $py     = Join-Path $browserRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { $py = 'python' }
    if (-not (Test-Path -LiteralPath $launch)) { throw "launch.py not found: $launch" }
    Write-Host 'Launching browser (fixed proxy, no fallback) ...'
    # launch.py reads these raw values and URL-encodes them itself. Scope them to
    # the browser launch: the CLI branch does not need them (HTTPS_PROXY already
    # carries the credentials) and should not leak them into claude's environment.
    $oldUser = $env:CLAUDE_EGRESS_PROXY_USER
    $oldPass = $env:CLAUDE_EGRESS_PROXY_PASSWORD
    if ($ProxyUser) {
        $env:CLAUDE_EGRESS_PROXY_USER = $ProxyUser
        $env:CLAUDE_EGRESS_PROXY_PASSWORD = $ProxyPassword
    }
    Push-Location $browserRoot
    try {
        # The launcher applies its own expected_ip check before opening Chrome.
        # Pass the port this script actually verified; config.local.json must not
        # be able to point the browser at a different proxy.
        & $py $launch --config config.local.json --profile claude `
            --expected-ip $ExpectedIp --proxy-server $ProxyHostPort
        $code = $LASTEXITCODE
    } finally {
        if ($null -eq $oldUser) {
            Remove-Item Env:\CLAUDE_EGRESS_PROXY_USER -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_EGRESS_PROXY_USER = $oldUser
        }
        if ($null -eq $oldPass) {
            Remove-Item Env:\CLAUDE_EGRESS_PROXY_PASSWORD -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_EGRESS_PROXY_PASSWORD = $oldPass
        }
        Pop-Location
    }
    exit $code
}

if ($NoClaude) {
    Write-Host 'Tunnel ready. Claude Code not started (-NoClaude).'
    exit 0
}

Write-Host "Starting Claude Code with HTTPS_PROXY=$ProxyHostPort ..."
& claude @ClaudeArgs
exit $LASTEXITCODE
