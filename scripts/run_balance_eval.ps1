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
    [string]$TuningProfile = "default",
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

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Write-NdjsonFile {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $lines = @()
    foreach ($record in @($Records)) {
        $lines += ($record | ConvertTo-Json -Depth 8 -Compress)
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $content = if ($lines.Count -gt 0) {
        ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    }
    else {
        ""
    }
    [System.IO.File]::WriteAllText($Path, $content, $encoding)
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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
        [int]$MinPatchEventsForUsableLane,
        [double]$MeaningfulImbalanceMomentum = 4.0
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

        if ([int]$record.bot_count -gt 0 -and [Math]::Abs((Get-TelemetryMomentum -Record $record)) -ge $MeaningfulImbalanceMomentum) {
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
        if ([Math]::Abs([double]$record.momentum) -lt $MeaningfulImbalanceMomentum) {
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

function New-HumanPresenceTimelineRecords {
    param([object[]]$TelemetryRecords)

    if (-not $TelemetryRecords -or $TelemetryRecords.Count -eq 0) {
        return @()
    }

    $baseServerTime = [double]$TelemetryRecords[0].server_time_seconds
    $records = @()
    foreach ($record in $TelemetryRecords) {
        $serverTime = [double]$record.server_time_seconds
        $records += [ordered]@{
            schema_version = 1
            event_type = "human_presence_sample"
            match_id = [string]$record.match_id
            telemetry_sequence = [int]$record.telemetry_sequence
            timestamp_utc = [string]$record.timestamp_utc
            server_time_seconds = [Math]::Round($serverTime, 2)
            offset_seconds = [Math]::Round($serverTime - $baseServerTime, 1)
            human_player_count = [int]$record.human_player_count
            bot_count = [int]$record.bot_count
            human_present = ([int]$record.human_player_count -gt 0)
            frag_gap_top_human_minus_top_bot = [int]$record.frag_gap_top_human_minus_top_bot
            momentum = [Math]::Round((Get-TelemetryMomentum -Record $record), 3)
        }
    }

    return @($records)
}

function Get-JoinInstructionsText {
    param(
        [object]$JoinInfo,
        [string]$LaneLabel,
        [string]$Mode,
        [int]$Port
    )

    $lines = @(
        "HLDM lane join instructions",
        "Lane label: $LaneLabel",
        "Mode: $Mode",
        "Loopback join target: $($JoinInfo.LoopbackAddress)",
        "Loopback console command: $($JoinInfo.ConsoleCommand)",
        "Steam connect URI: $($JoinInfo.SteamConnectUri)"
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$JoinInfo.LanAddress)) {
        $lines += "LAN join target: $($JoinInfo.LanAddress)"
        $lines += "LAN console command: $($JoinInfo.LanConsoleCommand)"
    }

    $lines += "Optional client helper: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\launch_local_hldm_client.ps1 -Port $Port"
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-SessionPackMarkdown {
    param(
        [object]$LaneSummary,
        [string]$LaneLabel,
        [string]$Mode,
        [string]$TuningProfile,
        [object]$JoinInfo,
        [string]$HumanTimelinePath
    )

    $lines = @(
        "# Session Pack",
        "",
        "- Mode: $Mode",
        "- Lane label: $LaneLabel",
        "- Tuning profile: $TuningProfile",
        "- Loopback join target: $($JoinInfo.LoopbackAddress)",
        "- Lane quality verdict: $($LaneSummary.lane_quality_verdict)",
        "- Evidence quality: $($LaneSummary.evidence_quality)",
        "- Tuning usable: $($LaneSummary.tuning_signal_usable)",
        "- Stability verdict: $($LaneSummary.behavior_verdict)",
        "- Human snapshots: $($LaneSummary.human_snapshots_count)",
        "- Seconds with human presence: $($LaneSummary.seconds_with_human_presence)",
        "- Explanation: $($LaneSummary.explanation)",
        "- Human presence timeline: $HumanTimelinePath"
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$JoinInfo.LanAddress)) {
        $lines += "- LAN join target: $($JoinInfo.LanAddress)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if ($Mode -eq "AI") {
    $resolvedTuningProfile = Get-TuningProfileDefinition -Name $TuningProfile

    if (-not $PSBoundParameters.ContainsKey("MinHumanSnapshots")) {
        $MinHumanSnapshots = [int]$resolvedTuningProfile.evaluation.min_human_snapshots
    }
    if (-not $PSBoundParameters.ContainsKey("MinHumanPresenceSeconds")) {
        $MinHumanPresenceSeconds = [int][Math]::Round([double]$resolvedTuningProfile.evaluation.min_human_presence_seconds)
    }
    if (-not $PSBoundParameters.ContainsKey("MinPatchEventsForUsableLane")) {
        $MinPatchEventsForUsableLane = [int]$resolvedTuningProfile.evaluation.min_patch_events_for_usable_lane
    }
}
else {
    $resolvedTuningProfile = $null
    $TuningProfile = ""
}
$currentPromptId = Get-RepoPromptId
$sourceCommitSha = Get-RepoHeadCommitSha
$meaningfulImbalanceMomentumForPreview = if ($null -ne $resolvedTuningProfile) {
    [double]$resolvedTuningProfile.evaluation.meaningful_imbalance_momentum
}
else {
    4.0
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

$waitForHumanJoinEnabled = $false
if ($PSBoundParameters.ContainsKey("WaitForHumanJoin")) {
    $waitForHumanJoinEnabled = [bool]$WaitForHumanJoin
}
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
$joinInfo = Get-HldsJoinInfo -Port $Port

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
    $launcherArgs.TuningProfile = $TuningProfile
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
$telemetryRecords = @()

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
                -MinPatchEventsForUsableLane $MinPatchEventsForUsableLane `
                -MeaningfulImbalanceMomentum $meaningfulImbalanceMomentumForPreview

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
            $gateSatisfied = [bool]$humanSignalPreview.TuningSignalUsable
            if ($Mode -eq "AI") {
                $gateSatisfied = $gateSatisfied -and [bool]$humanSignalPreview.PatchEventRequirementMet
            }
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
    $telemetryRecords = @(Read-NdjsonFile -Path $telemetryHistoryPath)
    $humanSignalPreview = Get-HumanSignalStats `
        -TelemetryHistoryPath $telemetryHistoryPath `
        -PatchHistoryPath $patchHistoryPath `
        -MinHumanSnapshots $MinHumanSnapshots `
        -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
        -MinPatchEventsForUsableLane $MinPatchEventsForUsableLane `
        -MeaningfulImbalanceMomentum $meaningfulImbalanceMomentumForPreview
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

$humanPresenceTimelinePath = Join-Path $laneRoot "human_presence_timeline.ndjson"
$humanPresenceTimelineRecords = New-HumanPresenceTimelineRecords -TelemetryRecords $telemetryRecords
Write-NdjsonFile -Path $humanPresenceTimelinePath -Records $humanPresenceTimelineRecords
$copiedArtifacts["human_presence_timeline"] = $humanPresenceTimelinePath

$joinInstructionsPath = Join-Path $laneRoot "join_instructions.txt"
Write-TextFile -Path $joinInstructionsPath -Value (
    Get-JoinInstructionsText -JoinInfo $joinInfo -LaneLabel $LaneLabel -Mode $Mode -Port $Port
)
$copiedArtifacts["join_instructions"] = $joinInstructionsPath

$laneManifest = [ordered]@{
    schema_version = 2
    prompt_id = $currentPromptId
    source_commit_sha = $sourceCommitSha
    mode = $Mode
    lane_label = $LaneLabel
    map = $Map
    tuning_profile = if ($null -ne $resolvedTuningProfile) { [string]$resolvedTuningProfile.name } else { $null }
    tuning_profile_effective = if ($null -ne $resolvedTuningProfile) { $resolvedTuningProfile } else { $null }
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
    join_info = [ordered]@{
        loopback_address = $joinInfo.LoopbackAddress
        console_command = $joinInfo.ConsoleCommand
        lan_address = $joinInfo.LanAddress
        lan_console_command = $joinInfo.LanConsoleCommand
        steam_connect_uri = $joinInfo.SteamConnectUri
    }
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

$summaryPayload = Read-JsonFile -Path $summaryResult.OutputJson
$laneSummary = if ($null -ne $summaryPayload) { $summaryPayload.primary_lane } else { $null }
$sessionPackJsonPath = Join-Path $laneRoot "session_pack.json"
$sessionPackMarkdownPath = Join-Path $laneRoot "session_pack.md"

$sessionPack = [ordered]@{
    schema_version = 1
    prompt_id = $currentPromptId
    source_commit_sha = $sourceCommitSha
    lane_root = $laneRoot
    mode = $Mode
    lane_label = $LaneLabel
    tuning_profile = if ($null -ne $resolvedTuningProfile) { [string]$resolvedTuningProfile.name } else { $null }
    tuning_profile_effective = if ($null -ne $resolvedTuningProfile) { $resolvedTuningProfile } else { $null }
    match_id = $matchId
    loopback_join_target = $joinInfo.LoopbackAddress
    lan_join_target = $joinInfo.LanAddress
    tuning_usable = if ($null -ne $laneSummary) { [bool]$laneSummary.tuning_signal_usable } else { $false }
    lane_quality_verdict = if ($null -ne $laneSummary) { [string]$laneSummary.lane_quality_verdict } else { "" }
    evidence_quality = if ($null -ne $laneSummary) { [string]$laneSummary.evidence_quality } else { "" }
    behavior_verdict = if ($null -ne $laneSummary) { [string]$laneSummary.behavior_verdict } else { "" }
    explanation = if ($null -ne $laneSummary) { [string]$laneSummary.explanation } else { "" }
    artifacts = [ordered]@{
        lane_json = Join-Path $laneRoot "lane.json"
        summary_json = $summaryResult.OutputJson
        summary_markdown = $summaryResult.OutputMarkdown
        session_pack_json = $sessionPackJsonPath
        session_pack_markdown = $sessionPackMarkdownPath
        join_instructions = $joinInstructionsPath
        human_presence_timeline = $humanPresenceTimelinePath
        copied = $copiedArtifacts
    }
    comparison_outputs = @()
}

Write-JsonFile -Path $sessionPackJsonPath -Value $sessionPack
$sessionPackMarkdown = if ($null -ne $laneSummary) {
    Get-SessionPackMarkdown `
        -LaneSummary $laneSummary `
        -LaneLabel $LaneLabel `
        -Mode $Mode `
        -TuningProfile $(if ($null -ne $resolvedTuningProfile) { [string]$resolvedTuningProfile.name } else { "n/a" }) `
        -JoinInfo $joinInfo `
        -HumanTimelinePath $humanPresenceTimelinePath
}
else {
    "# Session Pack`r`n`r`n- Lane label: $LaneLabel`r`n- Tuning profile: $(if ($null -ne $resolvedTuningProfile) { [string]$resolvedTuningProfile.name } else { "n/a" })`r`n- Summary generation did not produce a lane summary.`r`n"
}
Write-TextFile -Path $sessionPackMarkdownPath -Value $sessionPackMarkdown

[pscustomobject]@{
    LaneRoot = $laneRoot
    Mode = $Mode
    LaneLabel = $LaneLabel
    TuningProfile = if ($null -ne $resolvedTuningProfile) { [string]$resolvedTuningProfile.name } else { "" }
    Map = $Map
    MatchId = $matchId
    SmokeStatus = if ($null -ne $smokeResult) { $smokeResult.Status } else { "" }
    HumanJoinObserved = $humanJoinObserved
    HumanJoinTimedOut = $humanJoinTimedOut
    JoinTarget = $joinInfo.LoopbackAddress
    JoinInstructionsPath = $joinInstructionsPath
    LaneJsonPath = (Join-Path $laneRoot "lane.json")
    SummaryJsonPath = $summaryResult.OutputJson
    SummaryMarkdownPath = $summaryResult.OutputMarkdown
    SessionPackJsonPath = $sessionPackJsonPath
    SessionPackMarkdownPath = $sessionPackMarkdownPath
}
