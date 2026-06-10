param(
    [Parameter(Mandatory)][string] $ServerExe,
    [Parameter(Mandatory)][int]    $Port,
    [Parameter(Mandatory)][string] $ClientExe,
    [string[]] $ClientArgs = @(),
    [switch]   $ServerKeepStdin   # set when the server blocks on Console.ReadLine()
)

$ErrorActionPreference = 'Stop'

function Wait-ForPort([int]$port, [int]$tries = 15) {
    for ($i = 0; $i -lt $tries; $i++) {
        $c = New-Object System.Net.Sockets.TcpClient
        try   { $c.Connect('127.0.0.1', $port); $c.Close(); return $true }
        catch { Start-Sleep -Seconds 1 }
        finally { $c.Dispose() }
    }
    return $false
}

Write-Host "Starting server: $ServerExe"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName        = $ServerExe
$psi.UseShellExecute = $false
if ($ServerKeepStdin) {
    # Equivalent of `sleep infinity | server` on Linux: keep an open, empty
    # stdin so Console.ReadLine() blocks instead of hitting EOF and exiting.
    $psi.RedirectStandardInput = $true
}
$server = [System.Diagnostics.Process]::Start($psi)

try {
    if (-not (Wait-ForPort $Port)) {
        Write-Error "Server never opened port $Port"
        exit 1
    }
    Write-Host "Running client: $ClientExe $ClientArgs"
    & $ClientExe @ClientArgs
    $clientExit = $LASTEXITCODE
    Write-Host "Client exited with code $clientExit"
    exit $clientExit
}
finally {
    if (-not $server.HasExited) { $server.Kill() }
}

