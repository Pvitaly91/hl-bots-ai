param(
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$Port = 27017,
    [string]$LabRoot = "",
    [int]$DurationSeconds = 80,
    [switch]$WaitForHumanJoin,
    [int]$HumanJoinGraceSeconds = 120,
    [int]$MinHumanSnapshots = 2,
    [int]$MinHumanPresenceSeconds = 40,
    [int]$MinPatchEventsForUsableLane = 1,
    [string]$LaneLabel = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload
)

. (Join-Path $PSScriptRoot "common.ps1")

$laneLabelValue = if ($LaneLabel) { $LaneLabel.Trim() } else { "mixed-session-treatment" }
$waitForHumanJoinEnabled = $true
if ($PSBoundParameters.ContainsKey("WaitForHumanJoin")) {
    $waitForHumanJoinEnabled = [bool]$WaitForHumanJoin
}

$joinInfo = Get-HldsJoinInfo -Port $Port

Write-Host "Mixed-session balance evaluation lane:"
Write-Host "  Map: $Map"
Write-Host "  Bot count: $BotCount"
Write-Host "  Bot skill: $BotSkill"
Write-Host "  Port: $Port"
Write-Host "  Lane label: $laneLabelValue"
Write-Host "  Loopback join target: $($joinInfo.LoopbackAddress)"
Write-Host "  Console join command: $($joinInfo.ConsoleCommand)"
if (-not [string]::IsNullOrWhiteSpace([string]$joinInfo.LanAddress)) {
    Write-Host "  LAN join target: $($joinInfo.LanAddress)"
}
Write-Host "  Optional client helper: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\launch_local_hldm_client.ps1 -Port $Port"

$evalArgs = @{
    Mode = "AI"
    Map = $Map
    BotCount = $BotCount
    BotSkill = $BotSkill
    Port = $Port
    DurationSeconds = $DurationSeconds
    HumanJoinGraceSeconds = $HumanJoinGraceSeconds
    MinHumanSnapshots = $MinHumanSnapshots
    MinHumanPresenceSeconds = $MinHumanPresenceSeconds
    MinPatchEventsForUsableLane = $MinPatchEventsForUsableLane
    LaneLabel = $laneLabelValue
    Configuration = $Configuration
    Platform = $Platform
    SteamCmdPath = $SteamCmdPath
    PythonPath = $PythonPath
}

if ($LabRoot) {
    $evalArgs.LabRoot = $LabRoot
}
if ($OutputRoot) {
    $evalArgs.OutputRoot = $OutputRoot
}
if ($waitForHumanJoinEnabled) {
    $evalArgs.WaitForHumanJoin = $true
}
if ($SkipSteamCmdUpdate) {
    $evalArgs.SkipSteamCmdUpdate = $true
}
if ($SkipMetamodDownload) {
    $evalArgs.SkipMetamodDownload = $true
}

$result = & (Join-Path $PSScriptRoot "run_balance_eval.ps1") @evalArgs

Write-Host "Mixed-session lane finished."
Write-Host "  Summary JSON: $($result.SummaryJsonPath)"
Write-Host "  Session pack JSON: $($result.SessionPackJsonPath)"
Write-Host "  Join target used: $($result.JoinTarget)"

$result
