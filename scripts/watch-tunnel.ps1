# Keep the fail-closed tunnel alive on 127.0.0.1:<LocalPort>.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\watch-tunnel.ps1
#
# Put a shortcut in shell:startup to make it survive logon. sshd drops tunnels
# silently (sleep, NAT timeout, network switch). The loop is deliberately dumb:
# if the port is gone, rebuild it. It refuses to touch a port owned by something
# other than the expected ssh forward, so a foreign listener is never mistaken
# for a healthy tunnel.

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SshHost  = 'claude-vps',
    [int]$LocalPort   = 7891,
    [int]$RemotePort  = 7890,
    [int]$IntervalSec = 20
)

$Forward = "127.0.0.1:{0}:127.0.0.1:{1}" -f $LocalPort, $RemotePort

if ($SshHost -notmatch '^[A-Za-z0-9_.@-]+$') {
    throw "Unsafe -SshHost '$SshHost'."
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

function Get-ForwardingSsh {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($Forward) }
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
    Start-Process -FilePath 'ssh.exe' -WindowStyle Hidden -ArgumentList (ConvertTo-ArgLine $sshArgs)
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
        if ($owner -and $owner.Name -ne 'ssh.exe') {
            Write-Warning "[$stamp] $LocalPort is held by '$($owner.Name)' - not touching it."
        }
    } else {
        if (Start-Tunnel) { Write-Host "[$stamp] tunnel restarted" }
        else              { Write-Host "[$stamp] restart failed, retrying next tick" }
    }
    Start-Sleep -Seconds $IntervalSec
}
