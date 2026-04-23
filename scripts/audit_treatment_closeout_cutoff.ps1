param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

$PromptId = "HLDM-JKBOTTI-AI-STAND-20260415-67"

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
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("o")
    }

    $parsed = Convert-ToUtcDateTimeOrNull -Value ([string]$Value)
    if ($null -eq $parsed) {
        return ""
    }

    return $parsed.ToString("o")
}

function Resolve-LatestRegressedPairRoot {
    param([string]$PairsRoot)

    if (-not (Test-Path -LiteralPath $PairsRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $PairsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        $attemptPath = Join-Path $candidate.FullName "human_participation_conservative_attempt.json"
        if (-not (Test-Path -LiteralPath $attemptPath)) {
            continue
        }

        $attempt = Read-JsonFile -Path $attemptPath
        $treatmentJoin = Get-ObjectPropertyValue -Object $attempt -Name "treatment_lane_join" -Default $null
        $treatmentSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentJoin -Name "human_snapshots_count" -Default 0)
        $treatmentSeconds = [double](Get-ObjectPropertyValue -Object $treatmentJoin -Name "seconds_with_human_presence" -Default 0.0)
        if ($treatmentSnapshots -lt 5 -or $treatmentSeconds -lt 90.0) {
            return $candidate.FullName
        }
    }

    $latest = $candidates | Select-Object -First 1
    if ($null -ne $latest) {
        return $latest.FullName
    }

    return ""
}

function Get-HumanSampleCadenceState {
    param([object[]]$Records)

    $result = [ordered]@{
        sample_cadence_seconds = 20.0
        last_human_snapshot_at_utc = $null
        expected_next_human_snapshot_at_utc = $null
        first_human_snapshot_at_utc = $null
        human_snapshot_count = 0
    }

    if (-not $Records -or $Records.Count -eq 0) {
        return [pscustomobject]$result
    }

    $humanRecords = @($Records | Where-Object {
        [int](Get-ObjectPropertyValue -Object $_ -Name "human_player_count" -Default 0) -gt 0 -or
        [bool](Get-ObjectPropertyValue -Object $_ -Name "human_present" -Default $false)
    })

    $result.human_snapshot_count = $humanRecords.Count
    if ($humanRecords.Count -eq 0) {
        return [pscustomobject]$result
    }

    $firstHumanTimestamp = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object $humanRecords[0] -Name "timestamp_utc" -Default ""))
    $lastHumanTimestamp = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object $humanRecords[$humanRecords.Count - 1] -Name "timestamp_utc" -Default ""))
    $result.first_human_snapshot_at_utc = $firstHumanTimestamp
    $result.last_human_snapshot_at_utc = $lastHumanTimestamp

    $deltas = New-Object System.Collections.Generic.List[double]
    for ($index = 1; $index -lt $humanRecords.Count; $index++) {
        $currentTimestamp = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object $humanRecords[$index] -Name "timestamp_utc" -Default ""))
        $previousTimestamp = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object $humanRecords[$index - 1] -Name "timestamp_utc" -Default ""))
        if ($null -eq $currentTimestamp -or $null -eq $previousTimestamp) {
            continue
        }

        $deltaSeconds = ($currentTimestamp - $previousTimestamp).TotalSeconds
        if ($deltaSeconds -gt 0.0) {
            $deltas.Add($deltaSeconds) | Out-Null
        }
    }

    if ($deltas.Count -gt 0) {
        $orderedDeltas = @($deltas | Sort-Object)
        $medianIndex = [int][Math]::Floor(($orderedDeltas.Count - 1) / 2)
        $result.sample_cadence_seconds = [Math]::Round([double]$orderedDeltas[$medianIndex], 2)
    }

    if ($null -ne $lastHumanTimestamp) {
        $result.expected_next_human_snapshot_at_utc = $lastHumanTimestamp.AddSeconds([Math]::Max(1.0, $result.sample_cadence_seconds))
    }

    return [pscustomobject]$result
}

function Get-CutoffVerdict {
    param(
        [object]$Audit
    )

    $missing = @($Audit.evidence_missing)
    if ($missing.Count -gt 0 -and $null -eq (Get-ObjectPropertyValue -Object $Audit -Name "closeout_started_at_utc" -Default $null)) {
        return "cutoff-inconclusive-manual-review"
    }

    $remainingSnapshots = [int](Get-ObjectPropertyValue -Object $Audit -Name "treatment_remaining_human_snapshots_at_closeout" -Default 0)
    $remainingSeconds = [double](Get-ObjectPropertyValue -Object $Audit -Name "treatment_remaining_human_presence_seconds_at_closeout" -Default 0.0)
    $cadenceSeconds = [double](Get-ObjectPropertyValue -Object $Audit -Name "sample_cadence_inferred_seconds" -Default 20.0)
    $safeToLeave = [bool](Get-ObjectPropertyValue -Object $Audit -Name "safe_to_leave_treatment_at_closeout" -Default $false)
    $deltaToNext = Get-ObjectPropertyValue -Object $Audit -Name "seconds_between_closeout_start_and_expected_next_human_sample" -Default $null

    if ($remainingSnapshots -gt 1 -or $remainingSeconds -gt ($cadenceSeconds + 1.0)) {
        return "treatment-already-far-from-target-no-cutoff-claim"
    }

    if ($false -eq $safeToLeave -and $null -ne $deltaToNext -and [double]$deltaToNext -gt 0.0) {
        return "closeout-started-before-next-expected-human-sample"
    }

    if ($false -eq $safeToLeave) {
        return "closeout-started-while-safe_to_leave_false"
    }

    if ($null -ne $deltaToNext) {
        return "no-cutoff-problem-detected"
    }

    return "cutoff-inconclusive-manual-review"
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { [System.IO.Path]::GetFullPath((Join-Path $repoRoot $LabRoot)) }
$resolvedEvalRoot = if ([string]::IsNullOrWhiteSpace($EvalRoot)) { Get-EvalRootDefault -LabRoot $resolvedLabRoot } else { [System.IO.Path]::GetFullPath((Join-Path $repoRoot $EvalRoot)) }
$pairsRoot = Join-Path $resolvedEvalRoot "ssca53-live"

if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    if (-not $UseLatest) {
        $UseLatest = $true
    }

    if ($UseLatest) {
        $PairRoot = Resolve-LatestRegressedPairRoot -PairsRoot $pairsRoot
    }
}
else {
    $PairRoot = if ([System.IO.Path]::IsPathRooted($PairRoot)) { $PairRoot } else { [System.IO.Path]::GetFullPath((Join-Path $repoRoot $PairRoot)) }
}

if ([string]::IsNullOrWhiteSpace($PairRoot) -or -not (Test-Path -LiteralPath $PairRoot)) {
    throw "Could not resolve a pair root for the treatment closeout-cutoff audit."
}

$resolvedPairRoot = (Resolve-Path -LiteralPath $PairRoot).Path
$outputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $resolvedPairRoot } else { Ensure-Directory -Path (if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot)) }) }
$jsonPath = Join-Path $outputRoot "treatment_closeout_cutoff_audit.json"
$markdownPath = Join-Path $outputRoot "treatment_closeout_cutoff_audit.md"

$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
$pairSummary = Read-JsonFile -Path $pairSummaryPath
$treatmentLaneFromPair = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
$treatmentLaneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLaneFromPair -Name "lane_root" -Default ""))
$treatmentSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLaneFromPair -Name "summary_json" -Default ""))
if (-not $treatmentSummaryPath -and $treatmentLaneRoot) {
    $treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json")
}
$treatmentSummary = Read-LaneSummaryFile -Path $treatmentSummaryPath

$humanParticipationPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "human_participation_conservative_attempt.json")
$strongSignalAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "strong_signal_conservative_attempt.json")
$treatmentPatchWindowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "treatment_patch_window.json")
$phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "conservative_phase_flow.json")
$liveMonitorPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_attainment.json")
$closeoutGuardPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "closeout_guard.json") } else { "" }

$humanParticipation = Read-JsonFile -Path $humanParticipationPath
$strongSignalAttempt = Read-JsonFile -Path $strongSignalAttemptPath
$treatmentPatchWindow = Read-JsonFile -Path $treatmentPatchWindowPath
$phaseFlow = Read-JsonFile -Path $phaseFlowPath
$liveMonitor = Read-JsonFile -Path $liveMonitorPath
$missionAttainment = Read-JsonFile -Path $missionAttainmentPath
$closeoutGuard = Read-JsonFile -Path $closeoutGuardPath

$humanTimelinePath = if ($treatmentLaneRoot) {
    Resolve-LaneHumanPresenceTimelinePath -LaneRoot $treatmentLaneRoot
}
else {
    ""
}
$telemetryHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "telemetry_history.ndjson") } else { "" }
$patchHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_history.ndjson") } else { "" }
$patchApplyHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_apply_history.ndjson") } else { "" }

$humanTimelineRecords = @(Read-NdjsonFile -Path $humanTimelinePath)
if ($humanTimelineRecords.Count -eq 0) {
    $humanTimelineRecords = @(Read-NdjsonFile -Path $telemetryHistoryPath)
}
$cadenceState = Get-HumanSampleCadenceState -Records $humanTimelineRecords

$closeoutStartedAtUtc = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "closeout" -Default $null) -Name "wait_started_at_utc" -Default ""))
$attemptExitedAtUtc = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "closeout" -Default $null) -Name "attempt_process_exit_observed_at_utc" -Default ""))
$treatmentProcessLastSeenAtUtc = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "process_alive_last_seen_at_utc" -Default ""))
$treatmentJoinRequestedAtUtc = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "join_requested_at_utc" -Default ""))
$treatmentJoinLaunchedAtUtc = Convert-ToUtcDateTimeOrNull -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "launch_started_at_utc" -Default ""))
$safeToLeaveAtCloseout = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_patch_guidance" -Default $null) -Name "safe_to_leave_treatment" -Default ([bool](Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_safe_to_leave" -Default $false)))

$treatmentPatchLane = Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null
$missionTargetResults = Get-ObjectPropertyValue -Object $missionAttainment -Name "target_results" -Default $null
$targetSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentPatchLane -Name "target_human_snapshots" -Default 0)
if ($targetSnapshots -le 0) {
    $targetSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "treatment_minimum_human_snapshots" -Default $null) -Name "target_value" -Default 0)
}
$actualSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "human_snapshots_count" -Default ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "human_snapshots_count" -Default 0)))
$targetSeconds = [double](Get-ObjectPropertyValue -Object $treatmentPatchLane -Name "target_human_presence_seconds" -Default 0.0)
if ($targetSeconds -le 0.0) {
    $targetSeconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "treatment_minimum_human_presence_seconds" -Default $null) -Name "target_value" -Default 0.0)
}
$actualSeconds = [double](Get-ObjectPropertyValue -Object $treatmentSummary -Name "seconds_with_human_presence" -Default ([double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanParticipation -Name "treatment_lane_join" -Default $null) -Name "seconds_with_human_presence" -Default 0.0)))

$remainingSnapshots = [Math]::Max(0, $targetSnapshots - $actualSnapshots)
$remainingSeconds = [Math]::Round([Math]::Max(0.0, $targetSeconds - $actualSeconds), 2)
$lastHumanSnapshotAtUtc = Get-ObjectPropertyValue -Object $cadenceState -Name "last_human_snapshot_at_utc" -Default $null
$expectedNextHumanSnapshotAtUtc = Get-ObjectPropertyValue -Object $cadenceState -Name "expected_next_human_snapshot_at_utc" -Default $null
$firstHumanSnapshotAtUtc = Get-ObjectPropertyValue -Object $cadenceState -Name "first_human_snapshot_at_utc" -Default $null

$secondsBetweenCloseoutAndExpectedNext = if ($null -ne $closeoutStartedAtUtc -and $null -ne $expectedNextHumanSnapshotAtUtc) {
    [Math]::Round(($expectedNextHumanSnapshotAtUtc - $closeoutStartedAtUtc).TotalSeconds, 2)
}
else {
    $null
}
$secondsBetweenProcessExitAndExpectedNext = if ($null -ne $treatmentProcessLastSeenAtUtc -and $null -ne $expectedNextHumanSnapshotAtUtc) {
    [Math]::Round(($expectedNextHumanSnapshotAtUtc - $treatmentProcessLastSeenAtUtc).TotalSeconds, 2)
}
else {
    $null
}

$evidenceFound = New-Object System.Collections.Generic.List[string]
$evidenceMissing = New-Object System.Collections.Generic.List[string]

foreach ($entry in @(
    @{ Path = $pairSummaryPath; Label = "pair_summary.json" },
    @{ Path = $treatmentSummaryPath; Label = "treatment summary.json" },
    @{ Path = $treatmentPatchWindowPath; Label = "treatment_patch_window.json" },
    @{ Path = $phaseFlowPath; Label = "conservative_phase_flow.json" },
    @{ Path = $liveMonitorPath; Label = "live_monitor_status.json" },
    @{ Path = $missionAttainmentPath; Label = "mission_attainment.json" },
    @{ Path = $humanParticipationPath; Label = "human_participation_conservative_attempt.json" },
    @{ Path = $strongSignalAttemptPath; Label = "strong_signal_conservative_attempt.json" },
    @{ Path = $patchHistoryPath; Label = "patch_history.ndjson" },
    @{ Path = $patchApplyHistoryPath; Label = "patch_apply_history.ndjson" },
    @{ Path = $humanTimelinePath; Label = "human_presence_timeline.ndjson" }
)) {
    if ($entry.Path) {
        $evidenceFound.Add($entry.Label) | Out-Null
    }
    else {
        $evidenceMissing.Add($entry.Label) | Out-Null
    }
}

$audit = [ordered]@{
    schema_version = 1
    prompt_id = $PromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $resolvedPairRoot
    treatment_lane_root = $treatmentLaneRoot
    sample_cadence_inferred_seconds = [Math]::Round([double](Get-ObjectPropertyValue -Object $cadenceState -Name "sample_cadence_seconds" -Default 20.0), 2)
    first_human_snapshot_timestamp_utc = Convert-ToUtcString -Value $firstHumanSnapshotAtUtc
    last_observed_human_snapshot_timestamp_utc = Convert-ToUtcString -Value $lastHumanSnapshotAtUtc
    expected_next_human_snapshot_timestamp_utc = Convert-ToUtcString -Value $expectedNextHumanSnapshotAtUtc
    seconds_between_closeout_start_and_expected_next_human_sample = $secondsBetweenCloseoutAndExpectedNext
    seconds_between_process_exit_and_expected_next_human_sample = $secondsBetweenProcessExitAndExpectedNext
    treatment_join_requested_at_utc = Convert-ToUtcString -Value $treatmentJoinRequestedAtUtc
    treatment_join_launched_at_utc = Convert-ToUtcString -Value $treatmentJoinLaunchedAtUtc
    closeout_started_at_utc = Convert-ToUtcString -Value $closeoutStartedAtUtc
    treatment_process_last_observed_at_utc = Convert-ToUtcString -Value $treatmentProcessLastSeenAtUtc
    attempt_process_exit_observed_at_utc = Convert-ToUtcString -Value $attemptExitedAtUtc
    treatment_target_human_snapshots = $targetSnapshots
    treatment_actual_human_snapshots = $actualSnapshots
    treatment_remaining_human_snapshots_at_closeout = $remainingSnapshots
    treatment_target_human_presence_seconds = $targetSeconds
    treatment_actual_human_presence_seconds = [Math]::Round($actualSeconds, 2)
    treatment_remaining_human_presence_seconds_at_closeout = $remainingSeconds
    safe_to_leave_treatment_at_closeout = $safeToLeaveAtCloseout
    treatment_patch_events_while_humans_present = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_patch_while_human_present_events" -Default 0)
    treatment_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_post_patch_observation_seconds" -Default 0.0)
    closeout_guard_present = [bool]($null -ne $closeoutGuard)
    closeout_guard = if ($null -ne $closeoutGuard) { $closeoutGuard } else { $null }
    evidence_found = @([string[]]$evidenceFound.ToArray())
    evidence_missing = @([string[]]$evidenceMissing.ToArray())
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryPath
        treatment_summary_json = $treatmentSummaryPath
        treatment_patch_window_json = $treatmentPatchWindowPath
        conservative_phase_flow_json = $phaseFlowPath
        live_monitor_status_json = $liveMonitorPath
        mission_attainment_json = $missionAttainmentPath
        human_participation_conservative_attempt_json = $humanParticipationPath
        strong_signal_conservative_attempt_json = $strongSignalAttemptPath
        closeout_guard_json = $closeoutGuardPath
        human_presence_timeline_ndjson = $humanTimelinePath
        telemetry_history_ndjson = $telemetryHistoryPath
        patch_history_ndjson = $patchHistoryPath
        patch_apply_history_ndjson = $patchApplyHistoryPath
    }
}

$audit.verdict = Get-CutoffVerdict -Audit $audit
$audit.explanation = switch ($audit.verdict) {
    "closeout-started-before-next-expected-human-sample" {
        "Closeout started $secondsBetweenCloseoutAndExpectedNext second(s) before the next expected treatment human sample while treatment was still short by $remainingSnapshots snapshot(s) and $remainingSeconds second(s), and safe_to_leave_treatment was false."
    }
    "closeout-started-while-safe_to_leave_false" {
        "Closeout started after treatment was still marked unsafe to leave, but the expected next human sample timestamp was not close enough to prove a one-sample cutoff."
    }
    "treatment-already-far-from-target-no-cutoff-claim" {
        "The treatment lane ended below target, but it was still more than one sample away from the dwell threshold, so this audit does not claim a narrow closeout cutoff."
    }
    "no-cutoff-problem-detected" {
        "The saved treatment timing does not show a narrow closeout cutoff relative to the next expected human sample."
    }
    default {
        "The cutoff audit could not prove or disprove a narrow treatment closeout cutoff from the saved artifacts."
    }
}

$markdown = @(
    "# Treatment Closeout Cutoff Audit",
    "",
    "- Verdict: $($audit.verdict)",
    "- Explanation: $($audit.explanation)",
    "- Pair root: $($audit.pair_root)",
    "- Treatment lane root: $($audit.treatment_lane_root)",
    "- Sample cadence inferred seconds: $($audit.sample_cadence_inferred_seconds)",
    "- First human snapshot: $($audit.first_human_snapshot_timestamp_utc)",
    "- Last observed human snapshot: $($audit.last_observed_human_snapshot_timestamp_utc)",
    "- Expected next human snapshot: $($audit.expected_next_human_snapshot_timestamp_utc)",
    "- Closeout started at: $($audit.closeout_started_at_utc)",
    "- Treatment process last observed at: $($audit.treatment_process_last_observed_at_utc)",
    "- Seconds between closeout start and expected next sample: $($audit.seconds_between_closeout_start_and_expected_next_human_sample)",
    "- Seconds between process exit and expected next sample: $($audit.seconds_between_process_exit_and_expected_next_human_sample)",
    "- Treatment human snapshots: $($audit.treatment_actual_human_snapshots) / $($audit.treatment_target_human_snapshots)",
    "- Treatment human presence seconds: $($audit.treatment_actual_human_presence_seconds) / $($audit.treatment_target_human_presence_seconds)",
    "- Safe to leave treatment at closeout: $($audit.safe_to_leave_treatment_at_closeout)",
    "- Closeout guard artifact present: $($audit.closeout_guard_present)",
    "",
    "## Evidence Found",
    ""
) + (@($audit.evidence_found) | ForEach-Object { "- $_" }) + @(
    "",
    "## Evidence Missing",
    ""
) + (@($audit.evidence_missing) | ForEach-Object { "- $_" }) + @(
    "",
    "## Artifacts",
    "",
    "- Pair summary JSON: $($audit.artifacts.pair_summary_json)",
    "- Treatment summary JSON: $($audit.artifacts.treatment_summary_json)",
    "- Treatment patch window JSON: $($audit.artifacts.treatment_patch_window_json)",
    "- Conservative phase flow JSON: $($audit.artifacts.conservative_phase_flow_json)",
    "- Live monitor status JSON: $($audit.artifacts.live_monitor_status_json)",
    "- Mission attainment JSON: $($audit.artifacts.mission_attainment_json)",
    "- Human participation attempt JSON: $($audit.artifacts.human_participation_conservative_attempt_json)",
    "- Strong-signal attempt JSON: $($audit.artifacts.strong_signal_conservative_attempt_json)",
    "- Closeout guard JSON: $($audit.artifacts.closeout_guard_json)",
    "- Human presence timeline NDJSON: $($audit.artifacts.human_presence_timeline_ndjson)",
    "- Telemetry history NDJSON: $($audit.artifacts.telemetry_history_ndjson)",
    "- Patch history NDJSON: $($audit.artifacts.patch_history_ndjson)",
    "- Patch apply history NDJSON: $($audit.artifacts.patch_apply_history_ndjson)"
)

Write-JsonFile -Path $jsonPath -Value $audit
Write-TextFile -Path $markdownPath -Value (($markdown -join [Environment]::NewLine) + [Environment]::NewLine)

$audit
