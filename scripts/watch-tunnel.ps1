# Keep the fail-closed tunnel alive on 127.0.0.1:<LocalPort>.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\watch-tunnel.ps1
#
# Put a shortcut in shell:startup to make it survive logon. sshd drops tunnels
# silently (sleep, NAT timeout, network switch). The loop rebuilds the port when
# it is gone. A port is treated as healthy only when its owner is ssh.exe *and*
# the command line contains the expected -L forward and host alias, so a foreign
# listener or a leftover forward for another host is never mistaken for ours.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SshHost  = 'claude-vps',
    [int]$LocalPort   = 7891,
    [int]$RemotePort  = 7890,
    [int]$IntervalSec = 20
)

$Forward = "127.0.0.1:{0}:127.0.0.1:{1}" -f $LocalPort, $RemotePort

if ($SshHost -notmatch '^(?!-)[A-Za-z0-9_.@-]+$') {
    throw "Unsafe -SshHost '$SshHost'."
}

# Match complete tokens. The forward must be the value of -L, and the host alias
# must be the final argument (how Start-Tunnel invokes ssh); this rejects
# -F path\claude-vps\... and ProxyJump=claude-vps.
$HostTokenPattern = '(?:^|\s)"?' + [regex]::Escape($SshHost) + '"?\s*$'
$ForwardPattern   = '-L\s+"?' + [regex]::Escape($Forward) + '"?(\s|$)'

# Resolve ssh.exe to an absolute path: CreateProcess searches the current
# directory first, so a planted ssh.exe could otherwise win.
$SshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
if (-not (Test-Path -LiteralPath $SshExe)) {
    $sshCmd = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if (-not $sshCmd) { throw 'ssh.exe not found.' }
    $SshExe = $sshCmd.Source
}

# One watcher per machine: the port is machine-wide, so a second watcher in
# another session would still fight this one. An abandoned mutex (the previous
# watcher crashed without releasing it) is safe to take over.
try {
    $mutex = [System.Threading.Mutex]::new($false, 'Global\ClaudeEgressWatcher')
} catch {
    Write-Warning 'Global mutex unavailable; falling back to a per-session mutex.'
    $mutex = [System.Threading.Mutex]::new($false, 'Local\ClaudeEgressWatcher')
}
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $owned = $true
}
if (-not $owned) {
    throw "Another watch-tunnel.ps1 is already running."
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

function Test-ExpectedTunnelOwner($owner) {
    if (-not $owner) { return $false }
    if ($owner.Name -ne 'ssh.exe') { return $false }
    if (-not $owner.ExecutablePath -or $owner.ExecutablePath -ine $SshExe) { return $false }
    if (-not $owner.CommandLine) { return $false }
    return (($owner.CommandLine -match $ForwardPattern) -and
            ($owner.CommandLine -match $HostTokenPattern))
}

function Get-ForwardingSsh {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match $ForwardPattern -and
            $_.CommandLine -match $HostTokenPattern
        }
}

function ConvertTo-ArgLine([string[]]$items) {
    ($items | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
}

function Start-Tunnel {
    # Kill stale ssh processes for this exact forward: a hung connection would
    # otherwise accumulate one process per tick.
    Get-ForwardingSsh | ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
    }

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

Write-Host "Watching 127.0.0.1:$LocalPort (every ${IntervalSec}s). Ctrl+C to stop."

while ($true) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    if (Test-Port $LocalPort) {
        $owner = Get-PortOwner $LocalPort
        if (Test-ExpectedTunnelOwner $owner) {
            # Healthy: our forward holds the port.
        } elseif (-not $owner) {
            Write-Warning "[$stamp] $LocalPort is listening but its owner cannot be identified - not touching it."
        } else {
            Write-Warning "[$stamp] $LocalPort is held by '$($owner.Name)' without the expected forward - not touching it."
        }
    } else {
        if (Start-Tunnel) {
            $owner = Get-PortOwner $LocalPort
            if (Test-ExpectedTunnelOwner $owner) {
                Write-Host "[$stamp] tunnel restarted"
            } else {
                Write-Warning "[$stamp] a listener appeared on $LocalPort but it is not the expected forward."
            }
        } else {
            Write-Host "[$stamp] restart failed, retrying next tick"
        }
    }
    Start-Sleep -Seconds $IntervalSec
}
