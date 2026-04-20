param(
    [string]$ClientExePath = "",
    [string]$ServerHost = "127.0.0.1",
    [int]$Port = 27017,
    [string]$Game = "valve",
    [switch]$DryRun,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot "common.ps1")
$launchPlan = Get-HalfLifeClientLaunchPlan -PreferredClientPath $ClientExePath -ServerHost $ServerHost -Port $Port -Game $Game
$clientExe = $launchPlan.client_exe_path
$joinInfo = $launchPlan.join_info
$arguments = @($launchPlan.arguments)

if (-not $launchPlan.launchable) {
    throw [string]$launchPlan.client_discovery.explanation
}

Write-Host "Half-Life client target:"
Write-Host "  Executable: $clientExe"
Write-Host "  Join target: $($joinInfo.LoopbackAddress)"
Write-Host "  Console command: $($joinInfo.ConsoleCommand)"
Write-Host "  Discovery verdict: $($launchPlan.client_discovery.discovery_verdict)"

if ($DryRun) {
    [pscustomobject]@{
        ClientExePath = $clientExe
        ClientDiscoveryVerdict = [string]$launchPlan.client_discovery.discovery_verdict
        JoinTarget = $joinInfo.LoopbackAddress
        ConsoleCommand = $joinInfo.ConsoleCommand
        Arguments = $arguments
        LaunchCommand = [string]$launchPlan.command_text
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
