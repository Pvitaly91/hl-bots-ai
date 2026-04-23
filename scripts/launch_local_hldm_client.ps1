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
Write-Host "  Working directory: $($launchPlan.client_working_directory)"
Write-Host "  Join target: $($joinInfo.LoopbackAddress)"
Write-Host "  Console command: $($joinInfo.ConsoleCommand)"
Write-Host "  Discovery verdict: $($launchPlan.client_discovery.discovery_verdict)"
if ($launchPlan.qconsole_path) {
    Write-Host "  qconsole.log: $($launchPlan.qconsole_path)"
}
if ($launchPlan.debug_log_path) {
    Write-Host "  debug.log: $($launchPlan.debug_log_path)"
}

if ($DryRun) {
    [pscustomobject]@{
        ClientExePath = $clientExe
        ClientWorkingDirectory = [string]$launchPlan.client_working_directory
        ClientDiscoveryVerdict = [string]$launchPlan.client_discovery.discovery_verdict
        JoinTarget = $joinInfo.LoopbackAddress
        ConsoleCommand = $joinInfo.ConsoleCommand
        Arguments = $arguments
        LaunchCommand = [string]$launchPlan.command_text
        QConsolePath = [string]$launchPlan.qconsole_path
        DebugLogPath = [string]$launchPlan.debug_log_path
        DryRun = $true
    }
    return
}

$startProcessParams = @{
    FilePath = $clientExe
    ArgumentList = $arguments
    PassThru = $true
}
if (-not [string]::IsNullOrWhiteSpace($launchPlan.client_working_directory)) {
    $startProcessParams["WorkingDirectory"] = $launchPlan.client_working_directory
}

$process = Start-Process @startProcessParams

if ($PassThru) {
    $process
}
else {
    Write-Host "Half-Life client started with PID $($process.Id)"
}
