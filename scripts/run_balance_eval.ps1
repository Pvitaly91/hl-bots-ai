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
    [string]$LaneLabel = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [switch]$WaitForHumanJoin,
    [int]$HumanJoinGraceSeconds = 90,
    [int]$MinHumanSnapshots = 2,
    [int]$MinHumanPresenceSeconds = 40,
    [int]$MinPatchEventsForUsableLane = 1,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 10
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

function Convert-ToLaneSlug {
    param([string]$Value)

    $sourceValue = if ($null -eq $Value) { "" } else { $Value }
    $slug = $sourceValue.Trim().ToLowerInvariant()
    if (-not $slug) {
        return ""
    }

    $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-")
    $slug = $slug.Trim("-")
    if ($slug.Length -gt 32) {
        $slug = $slug.Substring(0, 32).Trim("-")
    }
    return $slug
}

function Read-NdjsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $records = @()
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line) {
            continue
        }
        $records += ($line | ConvertFrom-Json)
    }
    return @($records)
}

function Get-TelemetryMomentum {
    param([object]$Record)

    $fragGap = [double]$Record.frag_gap_top_human_minus_top_bot
    $humanKpm = [double]$Record.recent_human_kills_per_minute
    $botKpm = [double]$Record.recent_bot_kills_per_minute
    return $fragGap + (($humanKpm - $botKpm) * 0.75)
}

function Get-TelemetrySpanSeconds {
    param(
        [object[]]$TelemetryRecords,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge $TelemetryRecords.Count) {
        return 0.0
    }

    $record = $TelemetryRecords[$Index]
    $intervalSeconds = [double]$record.active_balance.interval_seconds
    if ($intervalSeconds -le 0.0) {
        $intervalSeconds = 20.0
    }

    if ($Index -ge ($TelemetryRecords.Count - 1)) {
        return [Math]::Max(1.0, $intervalSeconds)
    }

    $currentTime = [double]$record.server_time_seconds
    $nextTime = [double]$TelemetryRecords[$Index + 1].server_time_seconds
    $delta = $nextTime - $currentTime
    if ($delta -le 0.0) {
        return [Math]::Max(1.0, $intervalSeconds)
    }

    return [Math]::Min([Math]::Max(1.0, $intervalSeconds), $delta)
}

function Get-HumanSignalStats {
    param(
        [string]$TelemetryHistoryPath,
        [string]$PatchHistoryPath,
        [int]$MinHumanSnapshots,
        [double]$MinHumanPresenceSeconds,
        [int]$MinPatchEventsForUsableLane
    )

    $telemetryRecords = @(Read-NdjsonFile -Path $TelemetryHistoryPath)
    $patchRecords = @(Read-NdjsonFile -Path $PatchHistoryPath)
    $humanSnapshotsCount = 0
    $secondsWithHumanPresence = 0.0
    $maxHumanPlayerCount = 0
    $meaningfulImbalanceSnapshotsCount = 0
    $humanReactivePatchEventsCount = 0

    for ($index = 0; $index -lt $telemetryRecords.Count; $index++) {
        $record = $telemetryRecords[$index]
        $humanCount = [int]$record.human_player_count
        if ($humanCount -le 0) {
            continue
        }

        $humanSnapshotsCount += 1
        $maxHumanPlayerCount = [Math]::Max($maxHumanPlayerCount, $humanCount)
        $secondsWithHumanPresence += Get-TelemetrySpanSeconds -TelemetryRecords $telemetryRecords -Index $index

        if ([int]$record.bot_count -gt 0 -and [Math]::Abs((Get-TelemetryMomentum -Record $record)) -ge 4.0) {
            $meaningfulImbalanceSnapshotsCount += 1
        }
    }

    foreach ($record in $patchRecords) {
        if (-not [bool]$record.emitted) {
            continue
        }
        if ([int]$record.current_human_player_count -le 0 -or [int]$record.current_bot_count -le 0) {
            continue
        }
        if ([Math]::Abs([double]$record.momentum) -lt 4.0) {
            continue
        }
        $reason = [string]$record.reason
        if ($reason.ToLowerInvariant().StartsWith("waiting for both humans and bots")) {
            continue
        }
        $humanReactivePatchEventsCount += 1
    }

    if ($humanSnapshotsCount -eq 0 -or $secondsWithHumanPresence -le 0.0) {
        $humanSignalVerdict = "no-humans"
    }
    elseif ($humanSnapshotsCount -lt $MinHumanSnapshots -or $secondsWithHumanPresence -lt $MinHumanPresenceSeconds) {
        $humanSignalVerdict = "human-sparse"
    }
    else {
        $richMinHumanSnapshots = [Math]::Max($MinHumanSnapshots * 2, $MinHumanSnapshots + 2)
        $richMinHumanPresenceSeconds = [Math]::Max($MinHumanPresenceSeconds * 2.0, $MinHumanPresenceSeconds + 40.0)
        if ($humanSnapshotsCount -ge $richMinHumanSnapshots -and $secondsWithHumanPresence -ge $richMinHumanPresenceSeconds -and $maxHumanPlayerCount -ge 2) {
            $humanSignalVerdict = "human-rich"
        }
        else {
            $humanSignalVerdict = "human-usable"
        }
    }

    $tuningSignalUsable = $humanSignalVerdict -eq "human-usable" -or $humanSignalVerdict -eq "human-rich"
    $patchEventRequirementMet = ($meaningfulImbalanceSnapshotsCount -lt $MinHumanSnapshots) -or ($humanReactivePatchEventsCount -ge $MinPatchEventsForUsableLane)

    return [pscustomobject]@{
        HumanSnapshotsCount = $humanSnapshotsCount
        SecondsWithHumanPresence = [Math]::Round($secondsWithHumanPresence, 1)
        MaxHumanPlayerCount = $maxHumanPlayerCount
        MeaningfulHumanImbalanceSnapshotsCount = $meaningfulImbalanceSnapshotsCount
        HumanReactivePatchEventsCount = $humanReactivePatchEventsCount
        HumanSignalVerdict = $humanSignalVerdict
        TuningSignalUsable = $tuningSignalUsable
        PatchEventRequirementMet = $patchEventRequirementMet
    }
}

Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

if ($DurationSeconds -lt 5) {
    throw "DurationSeconds must be at least 5 seconds."
}
if ($HumanJoinGraceSeconds -lt 5) {
    throw "HumanJoinGraceSeconds must be at least 5 seconds."
}
if ($MinHumanSnapshots -lt 1) {
    throw "MinHumanSnapshots must be at least 1."
}
if ($MinHumanPresenceSeconds -lt 1) {
    throw "MinHumanPresenceSeconds must be at least 1."
}
if ($MinPatchEventsForUsableLane -lt 0) {
    throw "MinPatchEventsForUsableLane cannot be negative."
}

$waitForHumanJoinEnabled = ($Mode -eq "AI") -and $WaitForHumanJoin.IsPresent
$LaneLabel = if ($LaneLabel) {
    $LaneLabel.Trim()
}
elseif ($Mode -eq "NoAI") {
    "control-baseline"
}
elseif ($waitForHumanJoinEnabled) {
    "mixed-session-treatment"
}
else {
    "treatment"
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
$HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$runtimeDir = Get-AiRuntimeDir -HldsRoot $HldsRoot
$OutputRoot = if ($OutputRoot) { $OutputRoot } else { Join-Path $logsRoot "eval" }
$OutputRoot = Ensure-Directory -Path $OutputRoot
$pythonExe = Get-PythonPath -PreferredPath $PythonPath

$laneStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$laneSlug = Convert-ToLaneSlug -Value $LaneLabel
$laneFolderName = "{0}-{1}-{2}-b{3}-s{4}-p{5}" -f $laneStamp, $Mode.ToLowerInvariant(), $Map, $BotCount, $BotSkill, $Port
if ($laneSlug) {
    $laneFolderName = "$laneFolderName-$laneSlug"
}
$laneRoot = Ensure-Directory -Path (Join-Path $OutputRoot $laneFolderName)

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
$captureDeadlineUtc = $startedAtUtc.AddSeconds($DurationSeconds)
$humanJoinDeadlineUtc = if ($waitForHumanJoinEnabled) {
    $startedAtUtc.AddSeconds([Math]::Max($DurationSeconds, $HumanJoinGraceSeconds))
}
else {
    $captureDeadlineUtc
}

$launcherResult = $null
$smokeResult = $null
$latestTelemetry = $null
$latestPatch = $null
$matchId = ""
$humanJoinObserved = $false
$humanJoinTimedOut = $false
$humanSignalPreview = $null
$telemetryHistoryPath = ""
$patchHistoryPath = ""

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

    while ($true) {
        $nowUtc = (Get-Date).ToUniversalTime()

        $telemetryPath = Join-Path $runtimeDir "telemetry.json"
        $patchPath = Join-Path $runtimeDir "patch.json"
        if (Test-Path -LiteralPath $telemetryPath) {
            $latestTelemetry = Get-Content -LiteralPath $telemetryPath -Raw | ConvertFrom-Json
            if (-not $matchId) {
                $matchId = [string]$latestTelemetry.match_id
            }
        }

        if (Test-Path -LiteralPath $patchPath) {
            $latestPatch = Get-Content -LiteralPath $patchPath -Raw | ConvertFrom-Json
            if (-not $matchId) {
                $matchId = [string]$latestPatch.match_id
            }
        }

        if ($matchId) {
            $telemetryHistoryPath = Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "telemetry" -MatchId $matchId
            $patchHistoryPath = Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "patch" -MatchId $matchId
            $humanSignalPreview = Get-HumanSignalStats `
                -TelemetryHistoryPath $telemetryHistoryPath `
                -PatchHistoryPath $patchHistoryPath `
                -MinHumanSnapshots $MinHumanSnapshots `
                -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
                -MinPatchEventsForUsableLane $MinPatchEventsForUsableLane

            if ($humanSignalPreview.HumanSnapshotsCount -gt 0) {
                $humanJoinObserved = $true
            }
        }

        $captureComplete = $nowUtc -ge $captureDeadlineUtc
        if (-not $waitForHumanJoinEnabled) {
            if ($captureComplete) {
                break
            }
            Start-Sleep -Seconds 2
            continue
        }

        $gateSatisfied = $false
        if ($null -ne $humanSignalPreview) {
            $gateSatisfied = $humanSignalPreview.TuningSignalUsable -and $humanSignalPreview.PatchEventRequirementMet
        }

        if ($captureComplete -and $gateSatisfied) {
            break
        }

        if ($nowUtc -ge $humanJoinDeadlineUtc) {
            $humanJoinTimedOut = -not $gateSatisfied
            break
        }

        Start-Sleep -Seconds 2
    }
}
finally {
    Stop-LaneProcesses -HldsRoot $HldsRoot
}

$finishedAtUtc = (Get-Date).ToUniversalTime()
$actualDurationSeconds = [Math]::Max(0, [int][Math]::Ceiling(($finishedAtUtc - $startedAtUtc).TotalSeconds))
$telemetryHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "telemetry" -MatchId $matchId } else { "" }
$patchHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "patch" -MatchId $matchId } else { "" }
$patchApplyHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "patch_apply" -MatchId $matchId } else { "" }
$botSettingsHistoryPath = if ($matchId) { Get-AiRuntimeHistoryFilePath -HldsRoot $HldsRoot -Kind "bot_settings" -MatchId $matchId } else { "" }
$bootstrapSourcePath = Get-PluginBootstrapLogPath -HldsRoot $HldsRoot
$botConfigSourcePath = Get-BotTestConfigPath -ModRoot (Get-ServerModRoot -HldsRoot $HldsRoot) -Map $Map

if ($matchId) {
    $humanSignalPreview = Get-HumanSignalStats `
        -TelemetryHistoryPath $telemetryHistoryPath `
        -PatchHistoryPath $patchHistoryPath `
        -MinHumanSnapshots $MinHumanSnapshots `
        -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
        -MinPatchEventsForUsableLane $MinPatchEventsForUsableLane
    if ($humanSignalPreview.HumanSnapshotsCount -gt 0) {
        $humanJoinObserved = $true
    }
}

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
    schema_version = 2
    prompt_id = "HLDM-JKBOTTI-AI-STAND-20260415-11"
    mode = $Mode
    lane_label = $LaneLabel
    map = $Map
    bot_count = $BotCount
    bot_skill = $BotSkill
    port = $Port
    requested_duration_seconds = $DurationSeconds
    duration_seconds = $actualDurationSeconds
    configuration = $Configuration
    platform = $Platform
    lab_root = $LabRoot
    hlds_root = $HldsRoot
    logs_root = $logsRoot
    lane_root = $laneRoot
    started_at_utc = $startedAtUtc.ToString("o")
    finished_at_utc = $finishedAtUtc.ToString("o")
    match_id = $matchId
    wait_for_human_join = $waitForHumanJoinEnabled
    human_join_grace_seconds = $HumanJoinGraceSeconds
    human_join_deadline_utc = $humanJoinDeadlineUtc.ToString("o")
    human_join_observed = $humanJoinObserved
    human_join_timed_out = $humanJoinTimedOut
    min_human_snapshots = $MinHumanSnapshots
    min_human_presence_seconds = $MinHumanPresenceSeconds
    min_patch_events_for_usable_lane = $MinPatchEventsForUsableLane
    bootstrap_log_present = [bool]$copiedArtifacts["bootstrap_log"]
    attach_observed = $null -ne $smokeResult
    ai_sidecar_observed = if ($null -ne $smokeResult) { [bool]$smokeResult.AiSidecarRunning } else { $Mode -eq "AI" }
    smoke_status = if ($null -ne $smokeResult) { [string]$smokeResult.Status } else { "" }
    smoke_summary = if ($null -ne $smokeResult) { [string]$smokeResult.Summary } else { "" }
    human_signal_preview = if ($null -ne $humanSignalPreview) {
        [ordered]@{
            human_snapshots_count = $humanSignalPreview.HumanSnapshotsCount
            seconds_with_human_presence = $humanSignalPreview.SecondsWithHumanPresence
            human_signal_verdict = $humanSignalPreview.HumanSignalVerdict
            meaningful_human_imbalance_snapshots_count = $humanSignalPreview.MeaningfulHumanImbalanceSnapshotsCount
            human_reactive_patch_events_count = $humanSignalPreview.HumanReactivePatchEventsCount
            tuning_signal_usable = $humanSignalPreview.TuningSignalUsable
        }
    } else { $null }
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
    LaneRoot = $laneRoot
    Mode = $Mode
    LaneLabel = $LaneLabel
    Map = $Map
    MatchId = $matchId
    SmokeStatus = if ($null -ne $smokeResult) { $smokeResult.Status } else { "" }
    HumanJoinObserved = $humanJoinObserved
    HumanJoinTimedOut = $humanJoinTimedOut
    SummaryJsonPath = $summaryResult.OutputJson
    SummaryMarkdownPath = $summaryResult.OutputMarkdown
}
