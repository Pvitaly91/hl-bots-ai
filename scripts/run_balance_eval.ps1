param(
    [ValidateSet("NoAI", "AI")]
    [string]$Mode = "NoAI",
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [int]$DurationSeconds = 60,
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Copy-ArtifactIfExists {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        return ""
    }

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        return ""
    }

    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    return $DestinationPath
}

function Stop-LaneProcesses {
    param([string]$HldsRoot)
    Stop-LabProcesses -HldsRoot $HldsRoot
}

Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

if ($DurationSeconds -lt 5) {
    throw "DurationSeconds must be at least 5 seconds."
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
$HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$runtimeDir = Get-AiRuntimeDir -HldsRoot $HldsRoot
$repoRoot = Get-RepoRoot
$OutputRoot = if ($OutputRoot) { $OutputRoot } else { Join-Path $logsRoot "eval" }
$OutputRoot = Ensure-Directory -Path $OutputRoot
$pythonExe = Get-PythonPath -PreferredPath $PythonPath

$laneStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$laneRoot = Ensure-Directory -Path (
    Join-Path $OutputRoot ("{0}-{1}-{2}-b{3}-s{4}-p{5}" -f $laneStamp, $Mode.ToLowerInvariant(), $Map, $BotCount, $BotSkill, $Port)
)

$launcherPath = if ($Mode -eq "NoAI") {
    Join-Path $PSScriptRoot "run_standard_bots_crossfire.ps1"
}
else {
    Join-Path $PSScriptRoot "run_test_stand_with_bots.ps1"
}

$launcherArgs = @{
    Map           = $Map
    BotCount      = $BotCount
    BotSkill      = $BotSkill
    LabRoot       = $LabRoot
    Configuration = $Configuration
    Platform      = $Platform
    SteamCmdPath  = $SteamCmdPath
    Port          = $Port
}

if ($Mode -eq "AI") {
    $launcherArgs.PythonPath = $pythonExe
}

if ($SkipSteamCmdUpdate) {
    $launcherArgs.SkipSteamCmdUpdate = $true
}

if ($SkipMetamodDownload) {
    $launcherArgs.SkipMetamodDownload = $true
}

$smokeTimeout = if ($Mode -eq "AI") {
    [Math]::Max(60, [Math]::Min(180, $DurationSeconds + 30))
}
else {
    [Math]::Max(30, [Math]::Min(120, $DurationSeconds + 10))
}

$startedAtUtc = (Get-Date).ToUniversalTime()
$launcherResult = $null
$smokeResult = $null
$latestTelemetry = $null
$latestPatch = $null
$matchId = ""

foreach ($logName in @(
    "hlds.stdout.log",
    "hlds.stderr.log",
    "ai_director.stdout.log",
    "ai_director.stderr.log"
)) {
    $logPath = Join-Path $logsRoot $logName
    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }
}

try {
    $launcherResult = & $launcherPath @launcherArgs

    $smokeResult = & (Join-Path $PSScriptRoot "smoke_test.ps1") `
        -LabRoot $LabRoot `
        -HldsRoot $HldsRoot `
        -Map $Map `
        -BotCount $BotCount `
        -BotSkill $BotSkill `
        -Mode $Mode `
        -TimeoutSeconds $smokeTimeout

    $elapsedSeconds = [Math]::Ceiling((((Get-Date).ToUniversalTime()) - $startedAtUtc).TotalSeconds)
    $remainingSeconds = [Math]::Max(0, $DurationSeconds - $elapsedSeconds)
    if ($remainingSeconds -gt 0) {
        Start-Sleep -Seconds $remainingSeconds
    }

    $telemetryPath = Join-Path $runtimeDir "telemetry.json"
    $patchPath = Join-Path $runtimeDir "patch.json"
    if (Test-Path -LiteralPath $telemetryPath) {
        $latestTelemetry = Get-Content -LiteralPath $telemetryPath -Raw | ConvertFrom-Json
        $matchId = [string]$latestTelemetry.match_id
    }

    if (Test-Path -LiteralPath $patchPath) {
        $latestPatch = Get-Content -LiteralPath $patchPath -Raw | ConvertFrom-Json
        if (-not $matchId) {
            $matchId = [string]$latestPatch.match_id
        }
    }
}
finally {
    Stop-LaneProcesses -HldsRoot $HldsRoot
}

$finishedAtUtc = (Get-Date).ToUniversalTime()
$telemetryHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "telemetry" -MatchId $matchId } else { "" }
$patchHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "patch" -MatchId $matchId } else { "" }
$patchApplyHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "patch_apply" -MatchId $matchId } else { "" }
$botSettingsHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "bot_settings" -MatchId $matchId } else { "" }
$bootstrapSourcePath = Get-PluginBootstrapLogPath -HldsRoot $HldsRoot
$botConfigSourcePath = Get-BotTestConfigPath -ModRoot (Get-ServerModRoot -HldsRoot $HldsRoot) -Map $Map

$copiedArtifacts = [ordered]@{}
$copiedArtifacts["hlds_stdout_log"] = Copy-ArtifactIfExists -SourcePath (Join-Path $logsRoot "hlds.stdout.log") -DestinationPath (Join-Path $laneRoot "hlds.stdout.log")
$copiedArtifacts["hlds_stderr_log"] = Copy-ArtifactIfExists -SourcePath (Join-Path $logsRoot "hlds.stderr.log") -DestinationPath (Join-Path $laneRoot "hlds.stderr.log")
$copiedArtifacts["ai_stdout_log"] = Copy-ArtifactIfExists -SourcePath (Join-Path $logsRoot "ai_director.stdout.log") -DestinationPath (Join-Path $laneRoot "ai_director.stdout.log")
$copiedArtifacts["ai_stderr_log"] = Copy-ArtifactIfExists -SourcePath (Join-Path $logsRoot "ai_director.stderr.log") -DestinationPath (Join-Path $laneRoot "ai_director.stderr.log")
$copiedArtifacts["bootstrap_log"] = Copy-ArtifactIfExists -SourcePath $bootstrapSourcePath -DestinationPath (Join-Path $laneRoot "bootstrap.log")
$copiedArtifacts["bot_config"] = Copy-ArtifactIfExists -SourcePath $botConfigSourcePath -DestinationPath (Join-Path $laneRoot "bot_config.cfg")
$copiedArtifacts["latest_telemetry"] = Copy-ArtifactIfExists -SourcePath (Join-Path $runtimeDir "telemetry.json") -DestinationPath (Join-Path $laneRoot "latest.telemetry.json")
$copiedArtifacts["latest_patch"] = Copy-ArtifactIfExists -SourcePath (Join-Path $runtimeDir "patch.json") -DestinationPath (Join-Path $laneRoot "latest.patch.json")
$copiedArtifacts["telemetry_history"] = Copy-ArtifactIfExists -SourcePath $telemetryHistoryPath -DestinationPath (Join-Path $laneRoot "telemetry_history.ndjson")
$copiedArtifacts["patch_history"] = Copy-ArtifactIfExists -SourcePath $patchHistoryPath -DestinationPath (Join-Path $laneRoot "patch_history.ndjson")
$copiedArtifacts["patch_apply_history"] = Copy-ArtifactIfExists -SourcePath $patchApplyHistoryPath -DestinationPath (Join-Path $laneRoot "patch_apply_history.ndjson")
$copiedArtifacts["bot_settings_history"] = Copy-ArtifactIfExists -SourcePath $botSettingsHistoryPath -DestinationPath (Join-Path $laneRoot "bot_settings_history.ndjson")

$laneManifest = [ordered]@{
    schema_version = 1
    prompt_id = "HLDM-JKBOTTI-AI-STAND-20260415-10"
    mode = $Mode
    map = $Map
    bot_count = $BotCount
    bot_skill = $BotSkill
    port = $Port
    duration_seconds = $DurationSeconds
    configuration = $Configuration
    platform = $Platform
    lab_root = $LabRoot
    hlds_root = $HldsRoot
    logs_root = $logsRoot
    lane_root = $laneRoot
    started_at_utc = $startedAtUtc.ToString("o")
    finished_at_utc = $finishedAtUtc.ToString("o")
    match_id = $matchId
    bootstrap_log_present = [bool]$copiedArtifacts["bootstrap_log"]
    attach_observed = $null -ne $smokeResult
    ai_sidecar_observed = if ($null -ne $smokeResult) { [bool]$smokeResult.AiSidecarRunning } else { $Mode -eq "AI" }
    smoke_status = if ($null -ne $smokeResult) { [string]$smokeResult.Status } else { "" }
    smoke_summary = if ($null -ne $smokeResult) { [string]$smokeResult.Summary } else { "" }
    launcher_script = $launcherPath
    source_paths = [ordered]@{
        runtime_dir = $runtimeDir
        telemetry_history = $telemetryHistoryPath
        patch_history = $patchHistoryPath
        patch_apply_history = $patchApplyHistoryPath
        bot_settings_history = $botSettingsHistoryPath
        hlds_stdout_log = Join-Path $logsRoot "hlds.stdout.log"
        hlds_stderr_log = Join-Path $logsRoot "hlds.stderr.log"
        ai_stdout_log = Join-Path $logsRoot "ai_director.stdout.log"
        ai_stderr_log = Join-Path $logsRoot "ai_director.stderr.log"
    }
    copied_artifacts = $copiedArtifacts
}

Write-JsonFile -Path (Join-Path $laneRoot "lane.json") -Value $laneManifest

$summaryResult = & (Join-Path $PSScriptRoot "summarize_balance_eval.ps1") `
    -LaneRoot $laneRoot `
    -PythonPath $pythonExe `
    -OutputJson (Join-Path $laneRoot "summary.json") `
    -OutputMarkdown (Join-Path $laneRoot "summary.md")

[pscustomobject]@{
    LaneRoot         = $laneRoot
    Mode             = $Mode
    Map              = $Map
    MatchId          = $matchId
    SmokeStatus      = if ($null -ne $smokeResult) { $smokeResult.Status } else { "" }
    SummaryJsonPath  = $summaryResult.OutputJson
    SummaryMarkdownPath = $summaryResult.OutputMarkdown
}
