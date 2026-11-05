# Keep the fail-closed tunnel alive on 127.0.0.1:<LocalPort>.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\watch-tunnel.ps1
#
# Put a shortcut in shell:startup to make it survive logon. The loop is
# intentionally dumb: if the port is gone, start the tunnel again. sshd drops
# tunnels silently (laptop sleep, NAT timeout, network switch), and a dead
# tunnel is indistinguishable from "no proxy" to a fail-closed launcher --
# except that the launcher would refuse to start. This keeps that the only
# failure mode.

param(
    [string]$SshHost  = 'claude-vps',
    [int]$LocalPort   = 7891,
    [int]$RemotePort  = 7890,
    [int]$IntervalSec = 20
)

$Forward = "127.0.0.1:{0}:127.0.0.1:{1}" -f $LocalPort, $RemotePort

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

Write-Host "Watching 127.0.0.1:$LocalPort (every ${IntervalSec}s). Ctrl+C to stop."

while ($true) {
    if (-not (Test-Port $LocalPort)) {
        $ok = Start-Tunnel
        $stamp = Get-Date -Format 'HH:mm:ss'
        if ($ok) { Write-Host "[$stamp] tunnel restarted" }
        else     { Write-Host "[$stamp] restart failed, retrying next tick" }
    }
    Start-Sleep -Seconds $IntervalSec
}
