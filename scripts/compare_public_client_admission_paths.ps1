[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ServerAddress = "127.0.0.1",
    [int]$ServerPort = 27015,
    [string]$SteamExePath = "",
    [string]$ClientExePath = "",
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [string]$ServerLogPath = "",
    [string]$OutputRoot = "",
    [switch]$DryRun,
    [string[]]$PreferredPaths = @(),
    [int]$AdmissionWaitSeconds = 45,
    [int]$StatusPollSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$legacyScriptPath = Join-Path $PSScriptRoot "compare_public_admission_paths.ps1"
if (-not (Test-Path -LiteralPath $legacyScriptPath -PathType Leaf)) {
    throw "The legacy comparison helper was not found: $legacyScriptPath"
}

$invokeParams = @{
    ServerAddress = $ServerAddress
    ServerPort = $ServerPort
    AdmissionWaitSeconds = $AdmissionWaitSeconds
    StatusPollSeconds = $StatusPollSeconds
}
if (-not [string]::IsNullOrWhiteSpace($SteamExePath)) {
    $invokeParams["SteamExePath"] = $SteamExePath
}
if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) {
    $invokeParams["ClientExePath"] = $ClientExePath
}
if (-not [string]::IsNullOrWhiteSpace($PublicServerOutputRoot)) {
    $invokeParams["PublicServerOutputRoot"] = $PublicServerOutputRoot
}
if (-not [string]::IsNullOrWhiteSpace($PublicServerStatusJsonPath)) {
    $invokeParams["PublicServerStatusJsonPath"] = $PublicServerStatusJsonPath
}
if (-not [string]::IsNullOrWhiteSpace($ServerLogPath)) {
    $invokeParams["ServerLogPath"] = $ServerLogPath
}
if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $invokeParams["OutputRoot"] = $OutputRoot
}
if (@($PreferredPaths).Count -gt 0) {
    $invokeParams["PreferredPaths"] = @($PreferredPaths)
}
if ($DryRun) {
    $invokeParams["DryRun"] = $true
}

& $legacyScriptPath @invokeParams
