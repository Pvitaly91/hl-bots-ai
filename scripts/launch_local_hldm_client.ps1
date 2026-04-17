param(
    [string]$ClientExePath = "",
    [string]$ServerHost = "127.0.0.1",
    [int]$Port = 27017,
    [string]$Game = "valve",
    [switch]$DryRun,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot "common.ps1")

function Resolve-HalfLifeClientPath {
    param([string]$PreferredPath)

    $candidates = @()
    if ($PreferredPath) { $candidates += $PreferredPath }
    if ($env:HL_CLIENT_EXE) { $candidates += $env:HL_CLIENT_EXE }
    if ($env:HALF_LIFE_EXE) { $candidates += $env:HALF_LIFE_EXE }

    $candidates += @(
        "C:\Program Files (x86)\Steam\steamapps\common\Half-Life\hl.exe",
        "C:\Program Files\Steam\steamapps\common\Half-Life\hl.exe",
        "C:\Sierra\Half-Life\hl.exe",
        "C:\Program Files (x86)\Sierra\Half-Life\hl.exe"
    )

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Half-Life client executable was not found. Set -ClientExePath or `$env:HL_CLIENT_EXE to hl.exe."
}

$clientExe = Resolve-HalfLifeClientPath -PreferredPath $ClientExePath
$joinInfo = Get-HldsJoinInfo -Port $Port -ServerHost $ServerHost
$arguments = @(
    "-game", $Game,
    "+connect", $joinInfo.LoopbackAddress
)

Write-Host "Half-Life client target:"
Write-Host "  Executable: $clientExe"
Write-Host "  Join target: $($joinInfo.LoopbackAddress)"
Write-Host "  Console command: $($joinInfo.ConsoleCommand)"

if ($DryRun) {
    [pscustomobject]@{
        ClientExePath = $clientExe
        JoinTarget = $joinInfo.LoopbackAddress
        ConsoleCommand = $joinInfo.ConsoleCommand
        Arguments = $arguments
        DryRun = $true
    }
    return
}

$process = Start-Process -FilePath $clientExe -ArgumentList $arguments -PassThru

if ($PassThru) {
    $process
}
else {
    Write-Host "Half-Life client started with PID $($process.Id)"
}
