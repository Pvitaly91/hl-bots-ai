param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$Map = "stalkyard",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$TimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot "common.ps1")

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$Tail = 20
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return ((Get-Content -LiteralPath $Path -Tail $Tail) -join [Environment]::NewLine).Trim()
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }

$repoRoot = Get-RepoRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$runtimeDir = Get-AiRuntimeDir -HldsRoot $HldsRoot
$builtDll = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform
$launcherBat = Join-Path $repoRoot "scripts\run_test_stand_with_bots.bat"
$launcherPs1 = Join-Path $repoRoot "scripts\run_test_stand_with_bots.ps1"
$botTemplate = Get-BotTestConfigTemplatePath
$botConfigPath = Get-BotTestConfigPath -ModRoot (Get-ServerModRoot -HldsRoot $HldsRoot) -Map $Map
$pluginsIni = Join-Path (Get-ServerModRoot -HldsRoot $HldsRoot) "addons\metamod\plugins.ini"
$aiStdout = Join-Path $logsRoot "ai_director.stdout.log"
$aiStderr = Join-Path $logsRoot "ai_director.stderr.log"
$hldsLog = Join-Path $logsRoot "hlds.stdout.log"
$hldsErrLog = Join-Path $logsRoot "hlds.stderr.log"

if (-not (Test-Path -LiteralPath $launcherBat)) {
    throw "Launcher batch file is missing: $launcherBat"
}

if (-not (Test-Path -LiteralPath $launcherPs1)) {
    throw "Launcher PowerShell implementation is missing: $launcherPs1"
}

if (-not (Test-Path -LiteralPath $botTemplate)) {
    throw "Bot test config template is missing: $botTemplate"
}

if (-not (Test-Path -LiteralPath $builtDll)) {
    throw "Expected built DLL is missing: $builtDll"
}

if (-not (Test-Path -LiteralPath $pluginsIni)) {
    throw "Metamod plugins.ini is missing: $pluginsIni"
}

if (-not ((Get-Content -LiteralPath $pluginsIni -Raw) -match "jk_botti_mm\.dll")) {
    throw "plugins.ini does not reference jk_botti_mm.dll"
}

if (-not (Test-Path -LiteralPath $botConfigPath)) {
    $botConfigPath = Write-BotTestConfig -HldsRoot $HldsRoot -Map $Map -BotCount $BotCount -BotSkill $BotSkill
}

$botConfigContent = Get-Content -LiteralPath $botConfigPath -Raw
if ($botConfigContent -notmatch "(?m)^botskill\s+$BotSkill\s*$") {
    throw "Generated bot test config does not contain the requested botskill: $botConfigPath"
}

if ($botConfigContent -notmatch "(?m)^min_bots\s+$BotCount\s*$") {
    throw "Generated bot test config does not contain the requested min_bots value: $botConfigPath"
}

if ($botConfigContent -notmatch "(?m)^max_bots\s+$BotCount\s*$") {
    throw "Generated bot test config does not contain the requested max_bots value: $botConfigPath"
}

$addbotMatches = [regex]::Matches($botConfigContent, "(?m)^addbot\b")
if ($addbotMatches.Count -ne $BotCount) {
    throw "Generated bot test config contains $($addbotMatches.Count) addbot lines, expected ${BotCount}: $botConfigPath"
}

$validationRuntime = Ensure-Directory -Path (Join-Path $LabRoot "validation\runtime")
$validationTelemetry = Join-Path $validationRuntime "telemetry.json"
$validationPatch = Join-Path $validationRuntime "patch.json"

@'
{
  "schema_version": 1,
  "match_id": "validation-match",
  "telemetry_sequence": 8,
  "timestamp_utc": "2026-04-16T00:00:00Z",
  "server_time_seconds": 180.0,
  "map_name": "stalkyard",
  "human_player_count": 2,
  "bot_count": 2,
  "top_human_frags": 20,
  "top_human_deaths": 7,
  "top_bot_frags": 10,
  "top_bot_deaths": 13,
  "recent_human_kills_per_minute": 11,
  "recent_bot_kills_per_minute": 4,
  "frag_gap_top_human_minus_top_bot": 10,
  "current_default_bot_skill_level": 3,
  "active_balance": {
    "pause_frequency_scale": 1.0,
    "battle_strafe_scale": 1.0,
    "interval_seconds": 20.0,
    "cooldown_seconds": 30.0,
    "enabled": 1
  }
}
'@ | Set-Content -LiteralPath $validationTelemetry -Encoding ASCII

if (Test-Path -LiteralPath $validationPatch) {
    Remove-Item -LiteralPath $validationPatch -Force
}

$savedApiKey = $null
$hadApiKey = Test-Path env:OPENAI_API_KEY
if ($hadApiKey) {
    $savedApiKey = $env:OPENAI_API_KEY
    Remove-Item env:OPENAI_API_KEY
}

try {
    & (Join-Path $PSScriptRoot "run_ai_director.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -RuntimeDir $validationRuntime -Once
}
finally {
    if ($hadApiKey) {
        $env:OPENAI_API_KEY = $savedApiKey
    }
}

if (-not (Test-Path -LiteralPath $validationPatch)) {
    throw "Fallback AI validation did not produce patch.json in $validationRuntime"
}

$validationPatchJson = Get-Content -LiteralPath $validationPatch -Raw | ConvertFrom-Json
if ($validationPatchJson.target_skill_level -lt 1 -or $validationPatchJson.target_skill_level -gt 5) {
    throw "Fallback AI validation produced an out-of-range target_skill_level: $($validationPatchJson.target_skill_level)"
}

if ($validationPatchJson.bot_count_delta -lt -1 -or $validationPatchJson.bot_count_delta -gt 1) {
    throw "Fallback AI validation produced an out-of-range bot_count_delta: $($validationPatchJson.bot_count_delta)"
}

if ($validationPatchJson.pause_frequency_scale -lt 0.85 -or $validationPatchJson.pause_frequency_scale -gt 1.15) {
    throw "Fallback AI validation produced an out-of-range pause_frequency_scale: $($validationPatchJson.pause_frequency_scale)"
}

if ($validationPatchJson.battle_strafe_scale -lt 0.85 -or $validationPatchJson.battle_strafe_scale -gt 1.15) {
    throw "Fallback AI validation produced an out-of-range battle_strafe_scale: $($validationPatchJson.battle_strafe_scale)"
}

$logFiles = @($aiStdout, $aiStderr, $hldsLog, $hldsErrLog)
foreach ($logPath in $logFiles) {
    if (-not (Test-Path -LiteralPath $logPath)) {
        throw "Expected launcher log file is missing: $logPath"
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $telemetryExists = Test-Path -LiteralPath (Join-Path $runtimeDir "telemetry.json")
    $patchExists = Test-Path -LiteralPath (Join-Path $runtimeDir "patch.json")
    $hldsReady = (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match "plugin attaching")
    $applied = (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match "\[ai_balance\] applied patch=")

    if ($telemetryExists -and $patchExists -and $hldsReady -and $applied) {
        Write-Host "Smoke test passed."
        return
    }

    Start-Sleep -Seconds 2
}

$stdoutTail = Get-LogTailText -Path $hldsLog
$stderrTail = Get-LogTailText -Path $hldsErrLog
$blockers = @()
$missingChecks = @()
$telemetryExists = Test-Path -LiteralPath (Join-Path $runtimeDir "telemetry.json")
$patchExists = Test-Path -LiteralPath (Join-Path $runtimeDir "patch.json")
$hldsReady = (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match "plugin attaching")
$applied = (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match "\[ai_balance\] applied patch=")

if (-not $telemetryExists) {
    $missingChecks += "telemetry.json"
}

if (-not $patchExists) {
    $missingChecks += "patch.json"
}

if (-not $hldsReady) {
    $missingChecks += "jk_botti attach log"
}

if (-not $applied) {
    $missingChecks += "applied patch log"
}

if ((Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match 'Unable to initialize Steam')) {
    $blockers += 'HLDS reported "Unable to initialize Steam."'
}

if ((Test-Path -LiteralPath $hldsErrLog) -and ((Get-Content -LiteralPath $hldsErrLog -Raw) -match 'SDL3\.dll')) {
    $blockers += 'HLDS failed to load SDL3.dll.'
}

if ($blockers.Count -eq 0 -and (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match 'Metamod version')) {
    $blockers += "Metamod started, but the following checks never completed: $($missingChecks -join ', ')."
}

$blockerText = if ($blockers.Count -gt 0) { $blockers -join " " } else { "No specific external blocker was detected in the current log tail." }
throw "Smoke test timed out waiting for Metamod/jk_botti load, telemetry output, patch output, and patch application. $blockerText STDOUT tail: $stdoutTail STDERR tail: $stderrTail"
