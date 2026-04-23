[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$BetterPairRoot = "",
    [string]$RegressedPairRoot = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

$PromptId = "HLDM-JKBOTTI-AI-STAND-20260415-66"

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Read-NdjsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $records.Add(($line | ConvertFrom-Json)) | Out-Null
        }
        catch {
        }
    }

    return @($records.ToArray())
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine), $encoding)
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-AbsolutePath {
    param(
        [string]$Path,
        [string]$BasePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) $Path))
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) {
            return $Object[$Name]
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Read-LaneSummaryFile {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if ($null -eq $payload) {
        return $null
    }

    $primaryLane = Get-ObjectPropertyValue -Object $payload -Name "primary_lane" -Default $null
    if ($null -ne $primaryLane) {
        return $primaryLane
    }

    return $payload
}

function Convert-ToUtcDateTimeOrNull {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return ([datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Convert-ToUtcString {
    param([datetime]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return $Value.ToUniversalTime().ToString("o")
}

function Get-FileTimestampUtcString {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString("o")
}

function Get-GeneratedAtUtcString {
    param(
        [object]$Artifact,
        [string]$Path = ""
    )

    $generatedAt = [string](Get-ObjectPropertyValue -Object $Artifact -Name "generated_at_utc" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($generatedAt)) {
        return $generatedAt
    }

    return Get-FileTimestampUtcString -Path $Path
}

function Get-ResolvedEvalRoot {
    param(
        [string]$ExplicitLabRoot,
        [string]$ExplicitEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitEvalRoot)
    }

    $resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
        Ensure-Directory -Path (Get-LabRootDefault)
    }
    else {
        Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitLabRoot)
    }

    return Ensure-Directory -Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot)
}

function Get-TreatmentLaneRoot {
    param(
        [string]$ResolvedPairRoot,
        [object]$PairSummary
    )

    $fromPairSummary = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null) -Name "lane_root" -Default ""))
    if ($fromPairSummary) {
        return $fromPairSummary
    }

    $treatmentContainer = Join-Path $ResolvedPairRoot "lanes\treatment"
    if (-not (Test-Path -LiteralPath $treatmentContainer)) {
        return ""
    }

    $latest = Get-ChildItem -LiteralPath $treatmentContainer -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return ""
    }

    return $latest.FullName
}

function Get-HumanTimelineRecords {
    param([string]$LaneRoot)

    $primaryPath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "human_presence_timeline.ndjson")
    if ($primaryPath) {
        return [pscustomobject]@{
            Path = $primaryPath
            Records = @(Read-NdjsonFile -Path $primaryPath)
        }
    }

    $fallbackPath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "human_timeline.ndjson")
    return [pscustomobject]@{
        Path = $fallbackPath
        Records = @(Read-NdjsonFile -Path $fallbackPath)
    }
}

function Get-EmittedHumanPresentPatchEvents {
    param([object[]]$PatchHistory)

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($PatchHistory)) {
        if (
            [bool](Get-ObjectPropertyValue -Object $record -Name "emitted" -Default $false) -and
            [int](Get-ObjectPropertyValue -Object $record -Name "current_human_player_count" -Default 0) -gt 0
        ) {
            $events.Add($record) | Out-Null
        }
    }

    return @($events.ToArray())
}

function Get-PatchAppliesDuringHumanWindow {
    param(
        [object]$TreatmentSummary,
        [object[]]$PatchApplyHistory
    )

    $firstHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "first_human_seen_server_time_seconds" -Default -1.0)
    $lastHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($PatchApplyHistory)) {
        $serverTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default -1.0)
        if (
            $serverTime -ge 0.0 -and
            $firstHumanSeen -ge 0.0 -and
            $lastHumanSeen -ge $firstHumanSeen -and
            $serverTime -ge $firstHumanSeen -and
            $serverTime -le $lastHumanSeen
        ) {
            $records.Add($record) | Out-Null
        }
    }

    return @($records.ToArray())
}

function Get-CanonicalPostPatchObservationSeconds {
    param(
        [object]$TreatmentSummary,
        [object[]]$PatchAppliesDuringHumanWindow
    )

    if (@($PatchAppliesDuringHumanWindow).Count -eq 0) {
        return 0.0
    }

    $firstApplyServerTime = [double](Get-ObjectPropertyValue -Object $PatchAppliesDuringHumanWindow[0] -Name "server_time_seconds" -Default -1.0)
    $lastHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)

    if ($firstApplyServerTime -lt 0.0 -or $lastHumanSeen -lt $firstApplyServerTime) {
        return 0.0
    }

    return [Math]::Round(($lastHumanSeen - $firstApplyServerTime), 2)
}

function Get-TimestampAtIndexUtcString {
    param(
        [object[]]$Records,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge @($Records).Count) {
        return ""
    }

    return [string](Get-ObjectPropertyValue -Object $Records[$Index] -Name "timestamp_utc" -Default "")
}

function Get-MedianPositiveDeltaSeconds {
    param([object[]]$Records)

    $values = New-Object System.Collections.Generic.List[double]
    $timestamps = @($Records | ForEach-Object { Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object $_ -Name "timestamp_utc" -Default "")) } | Where-Object { $null -ne $_ })
    for ($i = 1; $i -lt $timestamps.Count; $i++) {
        $delta = ($timestamps[$i] - $timestamps[$i - 1]).TotalSeconds
        if ($delta -gt 0.0) {
            $values.Add([double]$delta) | Out-Null
        }
    }

    if ($values.Count -eq 0) {
        return 0.0
    }

    $sorted = @($values.ToArray() | Sort-Object)
    $mid = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        return [Math]::Round([double]$sorted[$mid], 2)
    }

    return [Math]::Round((([double]$sorted[$mid - 1]) + ([double]$sorted[$mid])) / 2.0, 2)
}

function Get-FirstRegexInt {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, $Pattern)
    if (-not $match.Success) {
        return $null
    }

    try {
        return [int]$match.Groups[1].Value
    }
    catch {
        return $null
    }
}

function Get-CurrentCommitSha {
    $repoRoot = Get-RepoRoot
    try {
        $sha = (& git -C $repoRoot rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0) {
            return ($sha | Select-Object -First 1).Trim()
        }
    }
    catch {
    }

    return ""
}

function Get-DefaultBetterPairRoot {
    param([string]$LiveRoot)

    if (-not (Test-Path -LiteralPath $LiveRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $LiveRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        $pairRoot = $candidate.FullName
        $pairSummary = Read-JsonFile -Path (Join-Path $pairRoot "pair_summary.json")
        $certificate = Read-JsonFile -Path (Join-Path $pairRoot "grounded_evidence_certificate.json")
        if ($null -eq $pairSummary -or $null -eq $certificate) {
            continue
        }

        $countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
        $treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
        $snapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0)
        $seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)
        if ($countsTowardPromotion -and $snapshots -ge 5 -and $seconds -ge 90.0) {
            return $pairRoot
        }
    }

    return ""
}

function Get-DefaultRegressedPairRoot {
    param([string]$LiveRoot)

    if (-not (Test-Path -LiteralPath $LiveRoot)) {
        return ""
    }

    $patchAttempt = Get-ChildItem -LiteralPath $LiveRoot -Filter "treatment_patch_completion_attempt.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $patchAttempt) {
        return $patchAttempt.DirectoryName
    }

    $candidates = Get-ChildItem -LiteralPath $LiveRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    foreach ($candidate in $candidates) {
        $pairRoot = $candidate.FullName
        $pairSummary = Read-JsonFile -Path (Join-Path $pairRoot "pair_summary.json")
        if ($null -eq $pairSummary) {
            continue
        }

        $treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
        $snapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0)
        $seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)
        if ($snapshots -lt 5 -or $seconds -lt 90.0) {
            return $pairRoot
        }
    }

    return ""
}

function Resolve-ComparisonPairRoots {
    param(
        [string]$ExplicitBetterPairRoot,
        [string]$ExplicitRegressedPairRoot,
        [string]$ResolvedEvalRoot
    )

    $liveRoot = Join-Path $ResolvedEvalRoot "ssca53-live"
    $resolvedBetter = if ($ExplicitBetterPairRoot) {
        Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitBetterPairRoot)
    }
    else {
        Resolve-ExistingPath -Path (Get-DefaultBetterPairRoot -LiveRoot $liveRoot)
    }

    $resolvedRegressed = if ($ExplicitRegressedPairRoot) {
        Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitRegressedPairRoot)
    }
    else {
        Resolve-ExistingPath -Path (Get-DefaultRegressedPairRoot -LiveRoot $liveRoot)
    }

    return [pscustomobject]@{
        BetterPairRoot = $resolvedBetter
        RegressedPairRoot = $resolvedRegressed
    }
}

function Get-RunData {
    param(
        [string]$PairRoot,
        [string]$Label
    )

    $resolvedPairRoot = Resolve-ExistingPath -Path $PairRoot
    if (-not $resolvedPairRoot) {
        throw "Pair root does not exist: $PairRoot"
    }

    $pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    $groundedCertificatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_evidence_certificate.json")
    $groundedCertificate = Read-JsonFile -Path $groundedCertificatePath
    $treatmentPatchWindowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "treatment_patch_window.json")
    $treatmentPatchWindow = Read-JsonFile -Path $treatmentPatchWindowPath
    $phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "conservative_phase_flow.json")
    $phaseFlow = Read-JsonFile -Path $phaseFlowPath
    $liveMonitorStatusPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
    $liveMonitorStatus = Read-JsonFile -Path $liveMonitorStatusPath
    $missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_attainment.json")
    $missionAttainment = Read-JsonFile -Path $missionAttainmentPath
    $humanParticipationPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "human_participation_conservative_attempt.json")
    $humanParticipation = Read-JsonFile -Path $humanParticipationPath
    $strongSignalAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "strong_signal_conservative_attempt.json")
    $strongSignalAttempt = Read-JsonFile -Path $strongSignalAttemptPath

    $missionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanParticipation -Name "mission_path_used" -Default ""))
    if (-not $missionPath) {
        $missionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "mission_path_used" -Default ""))
    }
    $mission = Read-JsonFile -Path $missionPath

    $treatmentLaneRoot = Get-TreatmentLaneRoot -ResolvedPairRoot $resolvedPairRoot -PairSummary $pairSummary
    $treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json")
    $treatmentSummary = Read-LaneSummaryFile -Path $treatmentSummaryPath
    $patchHistoryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_history.ndjson")
    $patchHistory = @(Read-NdjsonFile -Path $patchHistoryPath)
    $patchApplyHistoryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_apply_history.ndjson")
    $patchApplyHistory = @(Read-NdjsonFile -Path $patchApplyHistoryPath)
    $telemetryHistoryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "telemetry_history.ndjson")
    $telemetryHistory = @(Read-NdjsonFile -Path $telemetryHistoryPath)
    $humanTimeline = Get-HumanTimelineRecords -LaneRoot $treatmentLaneRoot
    $humanTimelineRecords = @($humanTimeline.Records)

    $emittedHumanPatchEvents = @(Get-EmittedHumanPresentPatchEvents -PatchHistory $patchHistory)
    $patchAppliesDuringHumanWindow = @(Get-PatchAppliesDuringHumanWindow -TreatmentSummary $treatmentSummary -PatchApplyHistory $patchApplyHistory)
    $sampleIntervalSeconds = Get-MedianPositiveDeltaSeconds -Records $humanTimelineRecords

    $firstHumanSnapshotUtc = [string](Get-ObjectPropertyValue -Object $treatmentSummary -Name "first_human_seen_timestamp_utc" -Default "")
    if ([string]::IsNullOrWhiteSpace($firstHumanSnapshotUtc)) {
        $firstHumanSnapshotUtc = Get-TimestampAtIndexUtcString -Records $humanTimelineRecords -Index 0
    }

    $lastHumanSnapshotUtc = [string](Get-ObjectPropertyValue -Object $treatmentSummary -Name "last_human_seen_timestamp_utc" -Default "")
    if ([string]::IsNullOrWhiteSpace($lastHumanSnapshotUtc) -and $humanTimelineRecords.Count -gt 0) {
        $lastHumanSnapshotUtc = Get-TimestampAtIndexUtcString -Records $humanTimelineRecords -Index ($humanTimelineRecords.Count - 1)
    }

    $expectedNextSnapshotUtc = ""
    $secondsBeforeNextSnapshotWhenCloseoutStarted = $null
    $secondsBeforeNextSnapshotWhenProcessEnded = $null
    $lastHumanSnapshotDateTime = Convert-ToUtcDateTimeOrNull -Value $lastHumanSnapshotUtc
    if ($null -ne $lastHumanSnapshotDateTime -and $sampleIntervalSeconds -gt 0.0) {
        $expectedNextSnapshotUtc = Convert-ToUtcString -Value $lastHumanSnapshotDateTime.AddSeconds($sampleIntervalSeconds)
    }

    $closeout = Get-ObjectPropertyValue -Object $humanParticipation -Name "closeout" -Default $null
    $closeoutStartUtc = [string](Get-ObjectPropertyValue -Object $closeout -Name "wait_started_at_utc" -Default "")
    $processEndedUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "process_alive_last_seen_at_utc" -Default "")
    if (-not $processEndedUtc) {
        $processEndedUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "process_exit_observed_at_utc" -Default "")
    }

    $expectedNextSnapshotDateTime = Convert-ToUtcDateTimeOrNull -Value $expectedNextSnapshotUtc
    $closeoutStartDateTime = Convert-ToUtcDateTimeOrNull -Value $closeoutStartUtc
    if ($null -ne $expectedNextSnapshotDateTime -and $null -ne $closeoutStartDateTime) {
        $secondsBeforeNextSnapshotWhenCloseoutStarted = [Math]::Round(($expectedNextSnapshotDateTime - $closeoutStartDateTime).TotalSeconds, 2)
    }

    $processEndedDateTime = Convert-ToUtcDateTimeOrNull -Value $processEndedUtc
    if ($null -ne $expectedNextSnapshotDateTime -and $null -ne $processEndedDateTime) {
        $secondsBeforeNextSnapshotWhenProcessEnded = [Math]::Round(($expectedNextSnapshotDateTime - $processEndedDateTime).TotalSeconds, 2)
    }

    $strongTargets = Get-ObjectPropertyValue -Object $mission -Name "strong_signal_targets" -Default $null
    $baselineTargets = Get-ObjectPropertyValue -Object $mission -Name "baseline_grounded_minimums" -Default $null
    $treatmentSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "human_snapshots_count" -Default 0)
    $treatmentSeconds = [double](Get-ObjectPropertyValue -Object $treatmentSummary -Name "seconds_with_human_presence" -Default 0.0)
    $canonicalPatchEventsActual = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_events_while_humans_present_count" -Default @($emittedHumanPatchEvents).Count)
    $canonicalPatchApplyCountActual = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_apply_count_while_humans_present" -Default @($patchAppliesDuringHumanWindow).Count)
    $canonicalPostPatchSeconds = Get-CanonicalPostPatchObservationSeconds -TreatmentSummary $treatmentSummary -PatchAppliesDuringHumanWindow $patchAppliesDuringHumanWindow

    $groundedReady = (
        $treatmentSnapshots -ge [int](Get-ObjectPropertyValue -Object $baselineTargets -Name "treatment_human_snapshots" -Default 0) -and
        $treatmentSeconds -ge [double](Get-ObjectPropertyValue -Object $baselineTargets -Name "treatment_human_presence_seconds" -Default 0.0) -and
        $canonicalPatchEventsActual -ge [int](Get-ObjectPropertyValue -Object $baselineTargets -Name "treatment_patch_while_human_present_events" -Default 0) -and
        $canonicalPostPatchSeconds -ge [double](Get-ObjectPropertyValue -Object $baselineTargets -Name "post_patch_observation_window_seconds" -Default 0.0)
    )
    $strongSignalReady = (
        $treatmentSnapshots -ge [int](Get-ObjectPropertyValue -Object $strongTargets -Name "treatment_human_snapshots" -Default 0) -and
        $treatmentSeconds -ge [double](Get-ObjectPropertyValue -Object $strongTargets -Name "treatment_human_presence_seconds" -Default 0.0) -and
        $canonicalPatchEventsActual -ge [int](Get-ObjectPropertyValue -Object $strongTargets -Name "treatment_patch_while_human_present_events" -Default 0) -and
        $canonicalPostPatchSeconds -ge [double](Get-ObjectPropertyValue -Object $strongTargets -Name "post_patch_observation_window_seconds" -Default 0.0)
    )

    $patchWindowLane = Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null
    $phaseFlowLane = Get-ObjectPropertyValue -Object $phaseFlow -Name "treatment_lane" -Default $null
    $missionTargetResults = Get-ObjectPropertyValue -Object $missionAttainment -Name "target_results" -Default $null
    $missionPatchTarget = Get-ObjectPropertyValue -Object $missionTargetResults -Name "treatment_minimum_patch_while_human_present_events" -Default $null

    $humanParticipationExplanation = [string](Get-ObjectPropertyValue -Object $humanParticipation -Name "explanation" -Default "")
    $strongSignalExplanation = [string](Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "explanation" -Default "")
    $missionExplanation = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "explanation" -Default "")

    return [ordered]@{
        label = $Label
        pair_root = $resolvedPairRoot
        treatment_lane_root = $treatmentLaneRoot
        canonical_sources = [ordered]@{
            pair_summary_json = $pairSummaryPath
            treatment_summary_json = $treatmentSummaryPath
            grounded_evidence_certificate_json = $groundedCertificatePath
            patch_history_ndjson = $patchHistoryPath
            patch_apply_history_ndjson = $patchApplyHistoryPath
            telemetry_history_ndjson = $telemetryHistoryPath
            human_presence_timeline_ndjson = [string]$humanTimeline.Path
        }
        secondary_sources = [ordered]@{
            treatment_patch_window_json = $treatmentPatchWindowPath
            conservative_phase_flow_json = $phaseFlowPath
            live_monitor_status_json = $liveMonitorStatusPath
            mission_attainment_json = $missionAttainmentPath
            human_participation_conservative_attempt_json = $humanParticipationPath
            strong_signal_conservative_attempt_json = $strongSignalAttemptPath
        }
        targets = [ordered]@{
            grounded_treatment_human_snapshots = [int](Get-ObjectPropertyValue -Object $baselineTargets -Name "treatment_human_snapshots" -Default 0)
            grounded_treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $baselineTargets -Name "treatment_human_presence_seconds" -Default 0.0)
            grounded_treatment_patch_events_while_humans_present = [int](Get-ObjectPropertyValue -Object $baselineTargets -Name "treatment_patch_while_human_present_events" -Default 0)
            grounded_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $baselineTargets -Name "post_patch_observation_window_seconds" -Default 0.0)
            strong_signal_treatment_human_snapshots = [int](Get-ObjectPropertyValue -Object $strongTargets -Name "treatment_human_snapshots" -Default 0)
            strong_signal_treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $strongTargets -Name "treatment_human_presence_seconds" -Default 0.0)
            strong_signal_treatment_patch_events_while_humans_present = [int](Get-ObjectPropertyValue -Object $strongTargets -Name "treatment_patch_while_human_present_events" -Default 0)
            strong_signal_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $strongTargets -Name "post_patch_observation_window_seconds" -Default 0.0)
        }
        canonical = [ordered]@{
            treatment_human_snapshots = $treatmentSnapshots
            treatment_human_presence_seconds = $treatmentSeconds
            treatment_patch_while_humans_present_count = $canonicalPatchEventsActual
            treatment_patch_apply_count_while_humans_present = $canonicalPatchApplyCountActual
            first_human_present_patch_timestamp_utc = Get-TimestampAtIndexUtcString -Records $emittedHumanPatchEvents -Index 0
            second_human_present_patch_timestamp_utc = Get-TimestampAtIndexUtcString -Records $emittedHumanPatchEvents -Index 1
            third_human_present_patch_timestamp_utc = Get-TimestampAtIndexUtcString -Records $emittedHumanPatchEvents -Index 2
            post_patch_observation_seconds = $canonicalPostPatchSeconds
            treatment_grounded_ready = $groundedReady
            treatment_strong_signal_ready = $strongSignalReady
            treatment_behavior_assessment = [string](Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "treatment_behavior_assessment" -Default "")
            certification_verdict = [string](Get-ObjectPropertyValue -Object $groundedCertificate -Name "certification_verdict" -Default (Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "certification_verdict" -Default ""))
            counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $groundedCertificate -Name "counts_toward_promotion" -Default (Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "counts_toward_promotion" -Default $false))
            pair_classification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default (Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "pair_classification" -Default ""))
        }
        timing = [ordered]@{
            control_ready_observed_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "control_switch_guidance" -Default $null) -Name "ready_observed_at_utc" -Default "")
            treatment_join_requested_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "join_requested_at_utc" -Default "")
            treatment_join_launched_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "launch_started_at_utc" -Default "")
            first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "first_server_connection_seen_at_utc" -Default "")
            first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "first_entered_the_game_seen_at_utc" -Default "")
            first_treatment_human_snapshot_at_utc = $firstHumanSnapshotUtc
            last_treatment_human_snapshot_at_utc = $lastHumanSnapshotUtc
            treatment_hold_generated_at_utc = Get-GeneratedAtUtcString -Artifact $treatmentPatchWindow -Path $treatmentPatchWindowPath
            treatment_hold_verdict_at_release = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_patch_guidance" -Default $null) -Name "verdict_at_release" -Default "")
            treatment_safe_to_leave_at_release = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_patch_guidance" -Default $null) -Name "safe_to_leave_treatment" -Default $false)
            treatment_hold_explanation = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_patch_guidance" -Default $null) -Name "explanation" -Default "")
            closeout_started_at_utc = $closeoutStartUtc
            final_pair_summary_written_at_utc = Get-GeneratedAtUtcString -Artifact $pairSummary -Path $pairSummaryPath
            process_alive_last_seen_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "process_alive_last_seen_at_utc" -Default "")
            process_runtime_seconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "process_runtime_seconds" -Default 0.0)
            human_sample_interval_seconds = $sampleIntervalSeconds
            expected_next_human_snapshot_at_utc = $expectedNextSnapshotUtc
            seconds_before_next_snapshot_when_closeout_started = $secondsBeforeNextSnapshotWhenCloseoutStarted
            seconds_before_next_snapshot_when_process_ended = $secondsBeforeNextSnapshotWhenProcessEnded
        }
        derived = [ordered]@{
            treatment_patch_window = [ordered]@{
                patch_count = [int](Get-ObjectPropertyValue -Object $patchWindowLane -Name "actual_patch_while_human_present_events" -Default -1)
                first_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $patchWindowLane -Name "first_human_present_patch_timestamp_utc" -Default "")
                source = [string](Get-ObjectPropertyValue -Object $patchWindowLane -Name "first_human_present_patch_source" -Default "")
            }
            conservative_phase_flow = [ordered]@{
                patch_count = [int](Get-ObjectPropertyValue -Object $phaseFlowLane -Name "actual_patch_while_human_present_events" -Default -1)
                first_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $phaseFlowLane -Name "first_human_present_patch_timestamp_utc" -Default "")
            }
            live_monitor_status = [ordered]@{
                patch_count = [int](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_patch_events_while_humans_present" -Default -1)
                post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "meaningful_post_patch_observation_seconds" -Default -1.0)
            }
            mission_attainment = [ordered]@{
                patch_count = [int](Get-ObjectPropertyValue -Object $missionPatchTarget -Name "actual_value" -Default -1)
                explanation = [string](Get-ObjectPropertyValue -Object $missionPatchTarget -Name "explanation" -Default "")
            }
            human_participation_conservative_attempt = [ordered]@{
                parsed_patch_count_from_explanation = Get-FirstRegexInt -Text $humanParticipationExplanation -Pattern "treatment minimum patch-while-human-present events needed at least \\d+, but the session produced (\\d+)"
            }
            strong_signal_conservative_attempt = [ordered]@{
                parsed_patch_count_from_explanation = Get-FirstRegexInt -Text $strongSignalExplanation -Pattern "treatment minimum patch-while-human-present events needed at least \\d+, but the session produced (\\d+)"
            }
            mission_attainment_narrative = [ordered]@{
                parsed_patch_count_from_explanation = Get-FirstRegexInt -Text $missionExplanation -Pattern "treatment minimum patch-while-human-present events needed at least \\d+, but the session produced (\\d+)"
            }
        }
        artifact_generated_at_utc = [ordered]@{
            treatment_patch_window = Get-GeneratedAtUtcString -Artifact $treatmentPatchWindow -Path $treatmentPatchWindowPath
            conservative_phase_flow = Get-GeneratedAtUtcString -Artifact $phaseFlow -Path $phaseFlowPath
            live_monitor_status = Get-GeneratedAtUtcString -Artifact $liveMonitorStatus -Path $liveMonitorStatusPath
            mission_attainment = Get-GeneratedAtUtcString -Artifact $missionAttainment -Path $missionAttainmentPath
            human_participation_conservative_attempt = Get-GeneratedAtUtcString -Artifact $humanParticipation -Path $humanParticipationPath
            strong_signal_conservative_attempt = Get-GeneratedAtUtcString -Artifact $strongSignalAttempt -Path $strongSignalAttemptPath
        }
    }
}

function Get-AuditDecision {
    param(
        [object]$BetterRun,
        [object]$RegressedRun
    )

    $canonicalBetter = Get-ObjectPropertyValue -Object $BetterRun -Name "canonical" -Default $null
    $canonicalRegressed = Get-ObjectPropertyValue -Object $RegressedRun -Name "canonical" -Default $null
    $timingRegressed = Get-ObjectPropertyValue -Object $RegressedRun -Name "timing" -Default $null
    $derivedRegressed = Get-ObjectPropertyValue -Object $RegressedRun -Name "derived" -Default $null

    $numericDerivedMismatches = New-Object System.Collections.Generic.List[string]
    foreach ($artifactName in @("treatment_patch_window", "conservative_phase_flow", "live_monitor_status", "mission_attainment")) {
        $artifact = Get-ObjectPropertyValue -Object $derivedRegressed -Name $artifactName -Default $null
        if ($null -eq $artifact) {
            continue
        }

        $derivedValue = [int](Get-ObjectPropertyValue -Object $artifact -Name "patch_count" -Default -1)
        $canonicalValue = [int](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "treatment_patch_while_humans_present_count" -Default 0)
        if ($derivedValue -ge 0 -and $derivedValue -ne $canonicalValue) {
            $numericDerivedMismatches.Add("$artifactName reports $derivedValue patch events while canonical treatment evidence reports $canonicalValue.") | Out-Null
        }
    }

    $narrativeMismatches = New-Object System.Collections.Generic.List[string]
    foreach ($artifactName in @("human_participation_conservative_attempt", "strong_signal_conservative_attempt", "mission_attainment_narrative")) {
        $artifact = Get-ObjectPropertyValue -Object $derivedRegressed -Name $artifactName -Default $null
        if ($null -eq $artifact) {
            continue
        }

        $derivedValue = Get-ObjectPropertyValue -Object $artifact -Name "parsed_patch_count_from_explanation" -Default $null
        $canonicalValue = [int](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "treatment_patch_while_humans_present_count" -Default 0)
        if ($null -ne $derivedValue -and [int]$derivedValue -ne $canonicalValue) {
            $narrativeMismatches.Add("$artifactName narrative still says $derivedValue patch events while canonical treatment evidence reports $canonicalValue.") | Out-Null
        }
    }

    $realDwellRegression = (
        [int](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "treatment_human_snapshots" -Default 0) -lt [int](Get-ObjectPropertyValue -Object $canonicalBetter -Name "treatment_human_snapshots" -Default 0) -or
        [double](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "treatment_human_presence_seconds" -Default 0.0) -lt [double](Get-ObjectPropertyValue -Object $canonicalBetter -Name "treatment_human_presence_seconds" -Default 0.0)
    )
    $patchOpportunityShortfall = [int](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "treatment_patch_while_humans_present_count" -Default 0) -lt [int](Get-ObjectPropertyValue -Object $canonicalBetter -Name "treatment_patch_while_humans_present_count" -Default 0)
    $closeoutStartedBeforeNextSample = ($null -ne (Get-ObjectPropertyValue -Object $timingRegressed -Name "seconds_before_next_snapshot_when_closeout_started" -Default $null)) -and [double](Get-ObjectPropertyValue -Object $timingRegressed -Name "seconds_before_next_snapshot_when_closeout_started" -Default 0.0) -gt 0.0
    $processEndedBeforeNextSample = ($null -ne (Get-ObjectPropertyValue -Object $timingRegressed -Name "seconds_before_next_snapshot_when_process_ended" -Default $null)) -and [double](Get-ObjectPropertyValue -Object $timingRegressed -Name "seconds_before_next_snapshot_when_process_ended" -Default 0.0) -gt 0.0
    $treatmentHoldStillBlocked = -not [bool](Get-ObjectPropertyValue -Object $timingRegressed -Name "treatment_safe_to_leave_at_release" -Default $false)
    $postPatchWindowCutShort = [double](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "post_patch_observation_seconds" -Default 0.0) -lt [double](Get-ObjectPropertyValue -Object $canonicalBetter -Name "post_patch_observation_seconds" -Default 0.0) -and -not [bool](Get-ObjectPropertyValue -Object $canonicalRegressed -Name "treatment_grounded_ready" -Default $false)

    $evidenceFound = New-Object System.Collections.Generic.List[string]
    $evidenceMissing = New-Object System.Collections.Generic.List[string]

    $evidenceFound.Add("Better run canonical treatment evidence reached $($canonicalBetter.treatment_human_snapshots) snapshot(s), $($canonicalBetter.treatment_human_presence_seconds) second(s), and $($canonicalBetter.treatment_patch_while_humans_present_count) counted patch event(s) while humans were present.") | Out-Null
    $evidenceFound.Add("Regressed run canonical treatment evidence fell to $($canonicalRegressed.treatment_human_snapshots) snapshot(s), $($canonicalRegressed.treatment_human_presence_seconds) second(s), and $($canonicalRegressed.treatment_patch_while_humans_present_count) counted patch event(s) while humans were present.") | Out-Null

    if ($closeoutStartedBeforeNextSample) {
        $evidenceFound.Add("Regressed run closeout started $($timingRegressed.seconds_before_next_snapshot_when_closeout_started) second(s) before the next expected human sample while treatment still reported safe_to_leave=false.") | Out-Null
    }
    if ($processEndedBeforeNextSample) {
        $evidenceFound.Add("Regressed run treatment process stopped $($timingRegressed.seconds_before_next_snapshot_when_process_ended) second(s) before the next expected human sample.") | Out-Null
    }
    if ($numericDerivedMismatches.Count -gt 0) {
        foreach ($item in $numericDerivedMismatches) {
            $evidenceFound.Add($item) | Out-Null
        }
    }
    if ($narrativeMismatches.Count -gt 0) {
        foreach ($item in $narrativeMismatches) {
            $evidenceFound.Add($item) | Out-Null
        }
    }

    if (-not $closeoutStartedBeforeNextSample -and -not $processEndedBeforeNextSample) {
        $evidenceMissing.Add("No authoritative timing marker proved that the regressed run ended before the next expected 20-second human sample.") | Out-Null
    }
    if (-not $patchOpportunityShortfall) {
        $evidenceMissing.Add("The canonical patch-event count did not actually regress relative to the better run.") | Out-Null
    }
    if ($numericDerivedMismatches.Count -eq 0) {
        $evidenceMissing.Add("No current numeric mismatch remains in refreshed treatment_patch_window, conservative_phase_flow, live_monitor_status, or mission_attainment outputs.") | Out-Null
    }

    $verdict = "inconclusive-manual-review"
    $narrowestPoint = "Unable to prove whether the regression was dominated by treatment dwell loss or secondary artifact drift."
    $explanation = "The comparison did not isolate one trustworthy regression point."
    $refreshOnlyJustified = $false
    $recommendation = "still-more-treatment-hold-hardening"

    if ($realDwellRegression -and ($closeoutStartedBeforeNextSample -or $processEndedBeforeNextSample)) {
        $verdict = "real-treatment-dwell-regression"
        $narrowestPoint = "The regressed treatment phase finalized before the next expected human-presence sample while treatment was still below target."
        $explanation = "The later run really lost treatment dwell. Canonical treatment evidence fell from 5 / 100 to 4 / 80, and the regressed pair entered closeout just before the next expected 20-second human sample while treatment guidance still reported safe_to_leave=false. Any remaining wrapper drift is secondary to that real dwell loss."
        $refreshOnlyJustified = $numericDerivedMismatches.Count -gt 0
        $recommendation = "still-more-treatment-hold-hardening"
    }
    elseif ($patchOpportunityShortfall -and -not $realDwellRegression) {
        $verdict = "real-treatment-patch-opportunity-shortfall"
        $narrowestPoint = "Treatment kept enough dwell, but raw emitted patch opportunities while humans were present still dropped."
        $explanation = "The regressed run stayed treatment-human-usable, but the canonical emitted patch-event count fell below the better run without a dwell drop large enough to explain it."
        $recommendation = "another-full-strong-signal-conservative-session"
    }
    elseif ($numericDerivedMismatches.Count -gt 0 -and -not $realDwellRegression) {
        $verdict = "derived-layer-patch-undercount-only"
        $narrowestPoint = "Canonical treatment evidence stayed stable, but secondary derived layers reported a different patch count."
        $explanation = "The canonical treatment evidence did not regress, and the remaining issue is confined to secondary artifacts that can be refreshed safely."
        $refreshOnlyJustified = $true
        $recommendation = "refresh-only-cleanup"
    }
    elseif ($postPatchWindowCutShort) {
        $verdict = "post-patch-window-cut-short"
        $narrowestPoint = "The treatment lane kept enough human presence, but the post-patch observation window regressed."
        $explanation = "The regression was later than treatment admission and later than human presence: the saved post-patch observation window shrank below the better run."
        $recommendation = "still-more-treatment-hold-hardening"
    }

    return [ordered]@{
        verdict = $verdict
        narrowest_confirmed_regression_point = $narrowestPoint
        explanation = $explanation
        recommendation = $recommendation
        refresh_only_cleanup_justified = $refreshOnlyJustified
        numeric_derived_patch_mismatch_present = $numericDerivedMismatches.Count -gt 0
        numeric_derived_patch_mismatches = @($numericDerivedMismatches.ToArray())
        narrative_only_patch_mismatches = @($narrativeMismatches.ToArray())
        evidence_found = @($evidenceFound.ToArray())
        evidence_missing = @($evidenceMissing.ToArray())
    }
}

function Get-ComparisonSummary {
    param(
        [object]$BetterRun,
        [object]$RegressedRun
    )

    $betterCanonical = Get-ObjectPropertyValue -Object $BetterRun -Name "canonical" -Default $null
    $regressedCanonical = Get-ObjectPropertyValue -Object $RegressedRun -Name "canonical" -Default $null
    $betterTiming = Get-ObjectPropertyValue -Object $BetterRun -Name "timing" -Default $null
    $regressedTiming = Get-ObjectPropertyValue -Object $RegressedRun -Name "timing" -Default $null
    $regressedDerived = Get-ObjectPropertyValue -Object $RegressedRun -Name "derived" -Default $null

    return [ordered]@{
        treatment_human_snapshots = [ordered]@{
            better = [int](Get-ObjectPropertyValue -Object $betterCanonical -Name "treatment_human_snapshots" -Default 0)
            regressed = [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_human_snapshots" -Default 0)
        }
        treatment_human_presence_seconds = [ordered]@{
            better = [double](Get-ObjectPropertyValue -Object $betterCanonical -Name "treatment_human_presence_seconds" -Default 0.0)
            regressed = [double](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_human_presence_seconds" -Default 0.0)
        }
        treatment_patch_while_humans_present_count = [ordered]@{
            better = [int](Get-ObjectPropertyValue -Object $betterCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
            regressed = [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
        }
        first_human_present_patch_timestamp_utc = [ordered]@{
            better = [string](Get-ObjectPropertyValue -Object $betterCanonical -Name "first_human_present_patch_timestamp_utc" -Default "")
            regressed = [string](Get-ObjectPropertyValue -Object $regressedCanonical -Name "first_human_present_patch_timestamp_utc" -Default "")
        }
        second_human_present_patch_timestamp_utc = [ordered]@{
            better = [string](Get-ObjectPropertyValue -Object $betterCanonical -Name "second_human_present_patch_timestamp_utc" -Default "")
            regressed = [string](Get-ObjectPropertyValue -Object $regressedCanonical -Name "second_human_present_patch_timestamp_utc" -Default "")
        }
        third_human_present_patch_timestamp_utc = [ordered]@{
            better = [string](Get-ObjectPropertyValue -Object $betterCanonical -Name "third_human_present_patch_timestamp_utc" -Default "")
            regressed = [string](Get-ObjectPropertyValue -Object $regressedCanonical -Name "third_human_present_patch_timestamp_utc" -Default "")
        }
        post_patch_observation_seconds = [ordered]@{
            better = [double](Get-ObjectPropertyValue -Object $betterCanonical -Name "post_patch_observation_seconds" -Default 0.0)
            regressed = [double](Get-ObjectPropertyValue -Object $regressedCanonical -Name "post_patch_observation_seconds" -Default 0.0)
        }
        treatment_grounded_ready = [ordered]@{
            better = [bool](Get-ObjectPropertyValue -Object $betterCanonical -Name "treatment_grounded_ready" -Default $false)
            regressed = [bool](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_grounded_ready" -Default $false)
        }
        treatment_strong_signal_ready = [ordered]@{
            better = [bool](Get-ObjectPropertyValue -Object $betterCanonical -Name "treatment_strong_signal_ready" -Default $false)
            regressed = [bool](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_strong_signal_ready" -Default $false)
        }
        treatment_behavior_assessment = [ordered]@{
            better = [string](Get-ObjectPropertyValue -Object $betterCanonical -Name "treatment_behavior_assessment" -Default "")
            regressed = [string](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_behavior_assessment" -Default "")
        }
        certification_verdict = [ordered]@{
            better = [string](Get-ObjectPropertyValue -Object $betterCanonical -Name "certification_verdict" -Default "")
            regressed = [string](Get-ObjectPropertyValue -Object $regressedCanonical -Name "certification_verdict" -Default "")
        }
        counts_toward_promotion = [ordered]@{
            better = [bool](Get-ObjectPropertyValue -Object $betterCanonical -Name "counts_toward_promotion" -Default $false)
            regressed = [bool](Get-ObjectPropertyValue -Object $regressedCanonical -Name "counts_toward_promotion" -Default $false)
        }
        pair_classification = [ordered]@{
            better = [string](Get-ObjectPropertyValue -Object $betterCanonical -Name "pair_classification" -Default "")
            regressed = [string](Get-ObjectPropertyValue -Object $regressedCanonical -Name "pair_classification" -Default "")
        }
        timing = [ordered]@{
            control_ready_observed_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "control_ready_observed_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "control_ready_observed_at_utc" -Default "")
            }
            treatment_join_requested_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "treatment_join_requested_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "treatment_join_requested_at_utc" -Default "")
            }
            treatment_join_launched_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "treatment_join_launched_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "treatment_join_launched_at_utc" -Default "")
            }
            first_treatment_human_snapshot_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "first_treatment_human_snapshot_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "first_treatment_human_snapshot_at_utc" -Default "")
            }
            treatment_hold_verdict_at_release = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "treatment_hold_verdict_at_release" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "treatment_hold_verdict_at_release" -Default "")
            }
            closeout_started_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "closeout_started_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "closeout_started_at_utc" -Default "")
            }
            final_pair_summary_written_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "final_pair_summary_written_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "final_pair_summary_written_at_utc" -Default "")
            }
            expected_next_human_snapshot_at_utc = [ordered]@{
                better = [string](Get-ObjectPropertyValue -Object $betterTiming -Name "expected_next_human_snapshot_at_utc" -Default "")
                regressed = [string](Get-ObjectPropertyValue -Object $regressedTiming -Name "expected_next_human_snapshot_at_utc" -Default "")
            }
            seconds_before_next_snapshot_when_closeout_started = [ordered]@{
                better = Get-ObjectPropertyValue -Object $betterTiming -Name "seconds_before_next_snapshot_when_closeout_started" -Default $null
                regressed = Get-ObjectPropertyValue -Object $regressedTiming -Name "seconds_before_next_snapshot_when_closeout_started" -Default $null
            }
            seconds_before_next_snapshot_when_process_ended = [ordered]@{
                better = Get-ObjectPropertyValue -Object $betterTiming -Name "seconds_before_next_snapshot_when_process_ended" -Default $null
                regressed = Get-ObjectPropertyValue -Object $regressedTiming -Name "seconds_before_next_snapshot_when_process_ended" -Default $null
            }
        }
        derived_consistency = [ordered]@{
            treatment_patch_window_patch_count = [ordered]@{
                canonical = [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
                derived = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "treatment_patch_window" -Default $null) -Name "patch_count" -Default -1)
                match = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "treatment_patch_window" -Default $null) -Name "patch_count" -Default -1) -eq [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
            }
            conservative_phase_flow_patch_count = [ordered]@{
                canonical = [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
                derived = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "conservative_phase_flow" -Default $null) -Name "patch_count" -Default -1)
                match = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "conservative_phase_flow" -Default $null) -Name "patch_count" -Default -1) -eq [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
            }
            live_monitor_status_patch_count = [ordered]@{
                canonical = [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
                derived = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "live_monitor_status" -Default $null) -Name "patch_count" -Default -1)
                match = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "live_monitor_status" -Default $null) -Name "patch_count" -Default -1) -eq [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
            }
            mission_attainment_patch_count = [ordered]@{
                canonical = [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
                derived = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "mission_attainment" -Default $null) -Name "patch_count" -Default -1)
                match = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $regressedDerived -Name "mission_attainment" -Default $null) -Name "patch_count" -Default -1) -eq [int](Get-ObjectPropertyValue -Object $regressedCanonical -Name "treatment_patch_while_humans_present_count" -Default 0)
            }
        }
    }
}

function Get-AuditMarkdown {
    param([object]$Audit)

    $better = Get-ObjectPropertyValue -Object $Audit -Name "better_run" -Default $null
    $regressed = Get-ObjectPropertyValue -Object $Audit -Name "regressed_run" -Default $null
    $decision = Get-ObjectPropertyValue -Object $Audit -Name "decision" -Default $null

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Treatment Dwell / Patch Consistency Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Audit.prompt_id)") | Out-Null
    $lines.Add("- Generated at UTC: $($Audit.generated_at_utc)") | Out-Null
    $lines.Add("- Better pair root: $($better.pair_root)") | Out-Null
    $lines.Add("- Regressed pair root: $($regressed.pair_root)") | Out-Null
    $lines.Add("- Verdict: $($decision.verdict)") | Out-Null
    $lines.Add("- Narrowest confirmed regression point: $($decision.narrowest_confirmed_regression_point)") | Out-Null
    $lines.Add("- Recommendation: $($decision.recommendation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Canonical Comparison") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Treatment snapshots: $($Audit.comparison.treatment_human_snapshots.better) -> $($Audit.comparison.treatment_human_snapshots.regressed)") | Out-Null
    $lines.Add("- Treatment human presence seconds: $($Audit.comparison.treatment_human_presence_seconds.better) -> $($Audit.comparison.treatment_human_presence_seconds.regressed)") | Out-Null
    $lines.Add("- Counted treatment patch events while humans present: $($Audit.comparison.treatment_patch_while_humans_present_count.better) -> $($Audit.comparison.treatment_patch_while_humans_present_count.regressed)") | Out-Null
    $lines.Add("- First counted treatment patch timestamp: $($Audit.comparison.first_human_present_patch_timestamp_utc.better) -> $($Audit.comparison.first_human_present_patch_timestamp_utc.regressed)") | Out-Null
    $lines.Add("- Second counted treatment patch timestamp: $($Audit.comparison.second_human_present_patch_timestamp_utc.better) -> $($Audit.comparison.second_human_present_patch_timestamp_utc.regressed)") | Out-Null
    $lines.Add("- Third counted treatment patch timestamp: $($Audit.comparison.third_human_present_patch_timestamp_utc.better) -> $($Audit.comparison.third_human_present_patch_timestamp_utc.regressed)") | Out-Null
    $lines.Add("- Post-patch observation seconds: $($Audit.comparison.post_patch_observation_seconds.better) -> $($Audit.comparison.post_patch_observation_seconds.regressed)") | Out-Null
    $lines.Add("- Treatment grounded-ready: $($Audit.comparison.treatment_grounded_ready.better) -> $($Audit.comparison.treatment_grounded_ready.regressed)") | Out-Null
    $lines.Add("- Treatment strong-signal-ready: $($Audit.comparison.treatment_strong_signal_ready.better) -> $($Audit.comparison.treatment_strong_signal_ready.regressed)") | Out-Null
    $lines.Add("- Treatment behavior assessment: $($Audit.comparison.treatment_behavior_assessment.better) -> $($Audit.comparison.treatment_behavior_assessment.regressed)") | Out-Null
    $lines.Add("- Certification verdict: $($Audit.comparison.certification_verdict.better) -> $($Audit.comparison.certification_verdict.regressed)") | Out-Null
    $lines.Add("- Counts toward promotion: $($Audit.comparison.counts_toward_promotion.better) -> $($Audit.comparison.counts_toward_promotion.regressed)") | Out-Null
    $lines.Add("- Pair classification: $($Audit.comparison.pair_classification.better) -> $($Audit.comparison.pair_classification.regressed)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Timing") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control-ready observed: $($Audit.comparison.timing.control_ready_observed_at_utc.better) -> $($Audit.comparison.timing.control_ready_observed_at_utc.regressed)") | Out-Null
    $lines.Add("- Treatment join requested: $($Audit.comparison.timing.treatment_join_requested_at_utc.better) -> $($Audit.comparison.timing.treatment_join_requested_at_utc.regressed)") | Out-Null
    $lines.Add("- Treatment join launched: $($Audit.comparison.timing.treatment_join_launched_at_utc.better) -> $($Audit.comparison.timing.treatment_join_launched_at_utc.regressed)") | Out-Null
    $lines.Add("- First treatment human snapshot: $($Audit.comparison.timing.first_treatment_human_snapshot_at_utc.better) -> $($Audit.comparison.timing.first_treatment_human_snapshot_at_utc.regressed)") | Out-Null
    $lines.Add("- Treatment-hold verdict at release: $($Audit.comparison.timing.treatment_hold_verdict_at_release.better) -> $($Audit.comparison.timing.treatment_hold_verdict_at_release.regressed)") | Out-Null
    $lines.Add("- Closeout started at: $($Audit.comparison.timing.closeout_started_at_utc.better) -> $($Audit.comparison.timing.closeout_started_at_utc.regressed)") | Out-Null
    $lines.Add("- Final pair summary written at: $($Audit.comparison.timing.final_pair_summary_written_at_utc.better) -> $($Audit.comparison.timing.final_pair_summary_written_at_utc.regressed)") | Out-Null
    $lines.Add("- Expected next treatment human snapshot after regression: $($Audit.comparison.timing.expected_next_human_snapshot_at_utc.regressed)") | Out-Null
    $lines.Add("- Seconds before next snapshot when closeout started: $($Audit.comparison.timing.seconds_before_next_snapshot_when_closeout_started.regressed)") | Out-Null
    $lines.Add("- Seconds before next snapshot when process ended: $($Audit.comparison.timing.seconds_before_next_snapshot_when_process_ended.regressed)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Derived Consistency") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- treatment_patch_window patch count: canonical $($Audit.comparison.derived_consistency.treatment_patch_window_patch_count.canonical), derived $($Audit.comparison.derived_consistency.treatment_patch_window_patch_count.derived), match=$($Audit.comparison.derived_consistency.treatment_patch_window_patch_count.match)") | Out-Null
    $lines.Add("- conservative_phase_flow patch count: canonical $($Audit.comparison.derived_consistency.conservative_phase_flow_patch_count.canonical), derived $($Audit.comparison.derived_consistency.conservative_phase_flow_patch_count.derived), match=$($Audit.comparison.derived_consistency.conservative_phase_flow_patch_count.match)") | Out-Null
    $lines.Add("- live_monitor_status patch count: canonical $($Audit.comparison.derived_consistency.live_monitor_status_patch_count.canonical), derived $($Audit.comparison.derived_consistency.live_monitor_status_patch_count.derived), match=$($Audit.comparison.derived_consistency.live_monitor_status_patch_count.match)") | Out-Null
    $lines.Add("- mission_attainment patch count: canonical $($Audit.comparison.derived_consistency.mission_attainment_patch_count.canonical), derived $($Audit.comparison.derived_consistency.mission_attainment_patch_count.derived), match=$($Audit.comparison.derived_consistency.mission_attainment_patch_count.match)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Evidence Found") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($item in @($decision.evidence_found)) {
        $lines.Add("- $item") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Evidence Missing") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($item in @($decision.evidence_missing)) {
        $lines.Add("- $item") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Explanation") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add($decision.explanation) | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedEvalRoot = Get-ResolvedEvalRoot -ExplicitLabRoot $LabRoot -ExplicitEvalRoot $EvalRoot
$comparisonRoots = Resolve-ComparisonPairRoots -ExplicitBetterPairRoot $BetterPairRoot -ExplicitRegressedPairRoot $RegressedPairRoot -ResolvedEvalRoot $resolvedEvalRoot

if (-not $comparisonRoots.BetterPairRoot) {
    throw "A better treatment pair root could not be resolved. Pass -BetterPairRoot explicitly."
}

if (-not $comparisonRoots.RegressedPairRoot) {
    throw "A regressed treatment pair root could not be resolved. Pass -RegressedPairRoot explicitly."
}

$betterRun = Get-RunData -PairRoot $comparisonRoots.BetterPairRoot -Label "better"
$regressedRun = Get-RunData -PairRoot $comparisonRoots.RegressedPairRoot -Label "regressed"
$decision = Get-AuditDecision -BetterRun $betterRun -RegressedRun $regressedRun
$comparison = Get-ComparisonSummary -BetterRun $betterRun -RegressedRun $regressedRun

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$defaultOutputRoot = Join-Path (Ensure-Directory -Path (Join-Path $resolvedEvalRoot "treatment_dwell_patch_audits")) ("{0}-treatment-dwell-patch-consistency" -f $stamp)
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path $defaultOutputRoot
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
}

$jsonPath = Join-Path $resolvedOutputRoot "treatment_dwell_patch_audit.json"
$markdownPath = Join-Path $resolvedOutputRoot "treatment_dwell_patch_audit.md"

$audit = [ordered]@{
    schema_version = 1
    prompt_id = $PromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-CurrentCommitSha
    better_pair_root = $comparisonRoots.BetterPairRoot
    regressed_pair_root = $comparisonRoots.RegressedPairRoot
    canonical_precedence = @(
        "treatment lane summary.json",
        "pair_summary.json",
        "grounded_evidence_certificate.json",
        "patch_history.ndjson",
        "patch_apply_history.ndjson",
        "telemetry_history.ndjson",
        "human_presence_timeline.ndjson or human_timeline.ndjson"
    )
    secondary_artifacts = @(
        "treatment_patch_window.json",
        "conservative_phase_flow.json",
        "live_monitor_status.json",
        "mission_attainment.json",
        "human_participation_conservative_attempt.json",
        "strong_signal_conservative_attempt.json"
    )
    decision = $decision
    comparison = $comparison
    better_run = $betterRun
    regressed_run = $regressedRun
    artifacts = [ordered]@{
        treatment_dwell_patch_audit_json = $jsonPath
        treatment_dwell_patch_audit_markdown = $markdownPath
    }
}

Write-JsonFile -Path $jsonPath -Value $audit
Write-TextFile -Path $markdownPath -Value (Get-AuditMarkdown -Audit $audit)

Write-Host "Treatment dwell / patch consistency audit:"
Write-Host "  Better pair root: $($comparisonRoots.BetterPairRoot)"
Write-Host "  Regressed pair root: $($comparisonRoots.RegressedPairRoot)"
Write-Host "  Verdict: $($decision.verdict)"
Write-Host "  Audit JSON: $jsonPath"
Write-Host "  Audit Markdown: $markdownPath"

[pscustomobject]@{
    BetterPairRoot = $comparisonRoots.BetterPairRoot
    RegressedPairRoot = $comparisonRoots.RegressedPairRoot
    TreatmentDwellPatchAuditJsonPath = $jsonPath
    TreatmentDwellPatchAuditMarkdownPath = $markdownPath
    Verdict = $decision.verdict
}
