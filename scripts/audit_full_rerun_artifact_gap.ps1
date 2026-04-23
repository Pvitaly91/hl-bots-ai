[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

$PromptId = "HLDM-JKBOTTI-AI-STAND-20260415-68"

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

function Resolve-LatestFailedRerunRoot {
    param([string]$PairsRoot)

    if (-not (Test-Path -LiteralPath $PairsRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $PairsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        $strongSignalPath = Join-Path $candidate.FullName "strong_signal_conservative_attempt.json"
        if (-not (Test-Path -LiteralPath $strongSignalPath)) {
            continue
        }

        $pairSummaryPath = Join-Path $candidate.FullName "pair_summary.json"
        if (-not (Test-Path -LiteralPath $pairSummaryPath)) {
            return $candidate.FullName
        }
    }

    $latest = $candidates | Select-Object -First 1
    if ($null -ne $latest) {
        return $latest.FullName
    }

    return ""
}

function Get-PairRootAnchorUtc {
    param([string]$ResolvedPairRoot)

    $name = Split-Path -Path $ResolvedPairRoot -Leaf
    if ($name -match '^(?<stamp>\d{8}-\d{6})') {
        try {
            $localTime = [datetime]::ParseExact($Matches["stamp"], "yyyyMMdd-HHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
            return $localTime.ToUniversalTime()
        }
        catch {
        }
    }

    return (Get-Item -LiteralPath $ResolvedPairRoot).LastWriteTimeUtc
}

function Resolve-ClosestGuidedRunnerLogPath {
    param(
        [string]$LogsRoot,
        [datetime]$PairAnchorUtc,
        [string]$LeafName,
        [int]$WindowMinutes = 15
    )

    $guidedSessionsRoot = Join-Path $LogsRoot "guided_sessions"
    if (-not (Test-Path -LiteralPath $guidedSessionsRoot)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $guidedSessionsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $candidatePath = Join-Path $_.FullName $LeafName
            if (-not (Test-Path -LiteralPath $candidatePath)) {
                return
            }

            [pscustomobject]@{
                path = $candidatePath
                delta_minutes = [math]::Abs(($_.LastWriteTimeUtc - $PairAnchorUtc).TotalMinutes)
            }
        } |
        Where-Object { $null -ne $_ -and $_.delta_minutes -le $WindowMinutes } |
        Sort-Object delta_minutes |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return [string]$candidate.path
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

function Get-LatestLaneRoot {
    param(
        [string]$ResolvedPairRoot,
        [string]$LaneName
    )

    $laneContainer = Join-Path $ResolvedPairRoot ("lanes\{0}" -f $LaneName.ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $laneContainer)) {
        return ""
    }

    $laneRoot = Get-ChildItem -LiteralPath $laneContainer -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $laneRoot) {
        return ""
    }

    return $laneRoot.FullName
}

function New-ArtifactPresenceRecord {
    param(
        [string]$Label,
        [string]$Path
    )

    $resolvedPath = Resolve-ExistingPath -Path $Path
    return [ordered]@{
        present = -not [string]::IsNullOrWhiteSpace($resolvedPath)
        path = $resolvedPath
        label = $Label
    }
}

function Get-FirstNonEmptyValue {
    param([object[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) {
            continue
        }

        $text = [string]$candidate
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
    }

    return ""
}

function Get-AuditVerdict {
    param(
        [bool]$ControlReadyObserved,
        [bool]$TreatmentRequested,
        [bool]$TreatmentLaneMaterialized,
        [bool]$PairSummaryPresent,
        [bool]$FinalSessionDocketPresent,
        [bool]$CloseoutStarted,
        [bool]$ProcessExitBeforeSummaryFlush
    )

    if ($ProcessExitBeforeSummaryFlush) {
        return "process-exit-before-summary-flush"
    }
    if (-not $ControlReadyObserved) {
        return "rerun-failed-before-control-ready"
    }
    if ($ControlReadyObserved -and -not $TreatmentRequested) {
        return "control-ready-but-treatment-not-requested"
    }
    if ($TreatmentRequested -and -not $TreatmentLaneMaterialized) {
        return "treatment-requested-but-treatment-lane-never-materialized"
    }
    if ($TreatmentLaneMaterialized -and -not $PairSummaryPresent) {
        return "treatment-lane-materialized-but-pair-summary-missing"
    }
    if (-not $CloseoutStarted) {
        return "closeout-never-started"
    }
    if ($CloseoutStarted -and -not $FinalSessionDocketPresent) {
        return "closeout-started-but-final-artifacts-missing"
    }

    return "artifact-gap-inconclusive-manual-review"
}

function Get-SalvageDecision {
    param(
        [bool]$PairSummaryPresent,
        [bool]$ControlSummaryPresent,
        [bool]$TreatmentSummaryPresent,
        [object]$RecoveryReport
    )

    $recoveryVerdict = [string](Get-ObjectPropertyValue -Object $RecoveryReport -Name "recovery_verdict" -Default "")
    $recommendedNextAction = [string](Get-ObjectPropertyValue -Object $RecoveryReport -Name "recommended_next_action" -Default "")

    if ($recoveryVerdict -eq "session-nonrecoverable-rerun-required" -or $recommendedNextAction -eq "discard-and-rerun") {
        return [pscustomobject]@{
            structurally_salvageable = $false
            salvageable_with_existing_path = $false
            rerun_required = $true
            manual_review_required = $false
            explanation = "The saved recovery path already classifies this pair as nonrecoverable because the raw pair summary never existed."
        }
    }

    if (-not $PairSummaryPresent -and -not $ControlSummaryPresent -and -not $TreatmentSummaryPresent) {
        return [pscustomobject]@{
            structurally_salvageable = $false
            salvageable_with_existing_path = $false
            rerun_required = $true
            manual_review_required = $false
            explanation = "The pair root is missing the minimum lane and pair summaries needed for safe salvage. A new full rerun is required."
        }
    }

    if (-not $PairSummaryPresent -and ($ControlSummaryPresent -or $TreatmentSummaryPresent)) {
        return [pscustomobject]@{
            structurally_salvageable = $true
            salvageable_with_existing_path = $true
            rerun_required = $false
            manual_review_required = $false
            explanation = "The lane summaries survived even though pair_summary.json is missing, so pair-local salvage is still possible."
        }
    }

    return [pscustomobject]@{
        structurally_salvageable = $PairSummaryPresent
        salvageable_with_existing_path = $PairSummaryPresent
        rerun_required = -not $PairSummaryPresent
        manual_review_required = -not $PairSummaryPresent
        explanation = if ($PairSummaryPresent) { "The pair root has enough structure for normal closeout review." } else { "The pair root needs manual review because the structural salvage signal is mixed." }
    }
}

$resolvedLabRoot = if ($LabRoot) { Resolve-ExistingPath -Path $LabRoot } else { Get-LabRootDefault }
$resolvedEvalRoot = if ($EvalRoot) { Resolve-ExistingPath -Path $EvalRoot } else { Get-EvalRootDefault -LabRoot $resolvedLabRoot }
$pairsRoot = Join-Path $resolvedEvalRoot "ssca53-live"

$resolvedPairRoot = Resolve-ExistingPath -Path $PairRoot
if (-not $resolvedPairRoot) {
    if (-not $UseLatest) {
        $UseLatest = $true
    }

    if ($UseLatest) {
        $resolvedPairRoot = Resolve-LatestFailedRerunRoot -PairsRoot $pairsRoot
    }
}

if (-not $resolvedPairRoot) {
    throw "Could not resolve a failed full rerun root. Pass -PairRoot or use -UseLatest."
}

$sessionStatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\session_state.json")
$missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\mission_execution.json")
$missionSnapshotPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\mission\next_live_session_mission.json")
$controlSwitchPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "control_to_treatment_switch.json")
$phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "conservative_phase_flow.json")
$treatmentPatchWindowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "treatment_patch_window.json")
$liveMonitorStatusPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
$groundedCertificatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_evidence_certificate.json")
$missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_attainment.json")
$finalSessionDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\final_session_docket.json")
$recoveryReportPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "session_recovery_report.json")
$continuationDecisionPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_continuation_decision.json")
$humanAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "human_participation_conservative_attempt.json")
$strongSignalAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "strong_signal_conservative_attempt.json")

$sessionState = Read-JsonFile -Path $sessionStatePath
$missionExecution = Read-JsonFile -Path $missionExecutionPath
$controlSwitch = Read-JsonFile -Path $controlSwitchPath
$phaseFlow = Read-JsonFile -Path $phaseFlowPath
$treatmentPatchWindow = Read-JsonFile -Path $treatmentPatchWindowPath
$liveMonitorStatus = Read-JsonFile -Path $liveMonitorStatusPath
$recoveryReport = Read-JsonFile -Path $recoveryReportPath
$continuationDecision = Read-JsonFile -Path $continuationDecisionPath
$humanAttempt = Read-JsonFile -Path $humanAttemptPath
$strongSignalAttempt = Read-JsonFile -Path $strongSignalAttemptPath

$pairAnchorUtc = Get-PairRootAnchorUtc -ResolvedPairRoot $resolvedPairRoot
$logsRoot = Get-LogsRootDefault -LabRoot $resolvedLabRoot
$pairRunnerStdoutPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $sessionState -Name "artifacts" -Default $null) -Name "pair_runner_stdout_log" -Default ""))
$pairRunnerStderrPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $sessionState -Name "artifacts" -Default $null) -Name "pair_runner_stderr_log" -Default ""))
if (-not $pairRunnerStdoutPath) {
    $pairRunnerStdoutPath = Resolve-ExistingPath -Path (Resolve-ClosestGuidedRunnerLogPath -LogsRoot $logsRoot -PairAnchorUtc $pairAnchorUtc -LeafName "pair_runner.stdout.log")
}
if (-not $pairRunnerStderrPath) {
    $pairRunnerStderrPath = Resolve-ExistingPath -Path (Resolve-ClosestGuidedRunnerLogPath -LogsRoot $logsRoot -PairAnchorUtc $pairAnchorUtc -LeafName "pair_runner.stderr.log")
}
$pairRunnerStdoutText = if ($pairRunnerStdoutPath) { Get-Content -LiteralPath $pairRunnerStdoutPath -Raw } else { "" }
$pairRunnerStderrText = if ($pairRunnerStderrPath) { Get-Content -LiteralPath $pairRunnerStderrPath -Raw } else { "" }

$controlLaneRoot = Get-FirstNonEmptyValue @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null) -Name "lane_root" -Default ""),
    (Get-LatestLaneRoot -ResolvedPairRoot $resolvedPairRoot -LaneName "control")
)
$treatmentLaneRoot = Get-FirstNonEmptyValue @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_lane_join" -Default $null) -Name "lane_root" -Default ""),
    (Get-LatestLaneRoot -ResolvedPairRoot $resolvedPairRoot -LaneName "treatment")
)

$controlSummaryPath = if ($controlLaneRoot) { Resolve-ExistingPath -Path (Join-Path $controlLaneRoot "summary.json") } else { "" }
$treatmentSummaryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json") } else { "" }
$controlCloseoutGuardPath = if ($controlLaneRoot) { Resolve-ExistingPath -Path (Join-Path $controlLaneRoot "closeout_guard.json") } else { "" }
$treatmentCloseoutGuardPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "closeout_guard.json") } else { "" }

$artifacts = [ordered]@{
    mission_snapshot = New-ArtifactPresenceRecord -Label "Mission snapshot" -Path $missionSnapshotPath
    mission_execution = New-ArtifactPresenceRecord -Label "Mission execution" -Path $missionExecutionPath
    session_state = New-ArtifactPresenceRecord -Label "Session state" -Path $sessionStatePath
    control_to_treatment_switch = New-ArtifactPresenceRecord -Label "Control-to-treatment switch" -Path $controlSwitchPath
    conservative_phase_flow = New-ArtifactPresenceRecord -Label "Conservative phase flow" -Path $phaseFlowPath
    treatment_patch_window = New-ArtifactPresenceRecord -Label "Treatment patch window" -Path $treatmentPatchWindowPath
    live_monitor_status = New-ArtifactPresenceRecord -Label "Live monitor status" -Path $liveMonitorStatusPath
    pair_summary = New-ArtifactPresenceRecord -Label "Pair summary" -Path $pairSummaryPath
    grounded_evidence_certificate = New-ArtifactPresenceRecord -Label "Grounded evidence certificate" -Path $groundedCertificatePath
    mission_attainment = New-ArtifactPresenceRecord -Label "Mission attainment" -Path $missionAttainmentPath
    final_session_docket = New-ArtifactPresenceRecord -Label "Final session docket" -Path $finalSessionDocketPath
    control_summary = New-ArtifactPresenceRecord -Label "Control lane summary" -Path $controlSummaryPath
    treatment_summary = New-ArtifactPresenceRecord -Label "Treatment lane summary" -Path $treatmentSummaryPath
    control_closeout_guard = New-ArtifactPresenceRecord -Label "Control closeout guard" -Path $controlCloseoutGuardPath
    treatment_closeout_guard = New-ArtifactPresenceRecord -Label "Treatment closeout guard" -Path $treatmentCloseoutGuardPath
    session_recovery_report = New-ArtifactPresenceRecord -Label "Session recovery report" -Path $recoveryReportPath
    continuation_decision = New-ArtifactPresenceRecord -Label "Continuation decision" -Path $continuationDecisionPath
    pair_runner_stdout = New-ArtifactPresenceRecord -Label "Pair runner stdout log" -Path $pairRunnerStdoutPath
    pair_runner_stderr = New-ArtifactPresenceRecord -Label "Pair runner stderr log" -Path $pairRunnerStderrPath
}

$evidenceFound = New-Object System.Collections.Generic.List[string]
$evidenceMissing = New-Object System.Collections.Generic.List[string]
foreach ($entry in $artifacts.GetEnumerator()) {
    if ([bool](Get-ObjectPropertyValue -Object $entry.Value -Name "present" -Default $false)) {
        $evidenceFound.Add([string](Get-ObjectPropertyValue -Object $entry.Value -Name "label" -Default $entry.Key)) | Out-Null
    }
    else {
        $evidenceMissing.Add([string](Get-ObjectPropertyValue -Object $entry.Value -Name "label" -Default $entry.Key)) | Out-Null
    }
}

$controlReadyObserved = [bool](Get-ObjectPropertyValue -Object $controlSwitch -Name "ready_to_leave_observed" -Default $false)
$treatmentRequested = -not [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_lane_join" -Default $null) -Name "join_requested_at_utc" -Default ""))
$treatmentLaneMaterialized = -not [string]::IsNullOrWhiteSpace($treatmentLaneRoot)
$closeoutStarted = -not [string]::IsNullOrWhiteSpace([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "closeout" -Default $null) -Name "wait_started_at_utc" -Default ""))
$pairSummaryPresent = [bool](Get-ObjectPropertyValue -Object $artifacts.pair_summary -Name "present" -Default $false)
$finalSessionDocketPresent = [bool](Get-ObjectPropertyValue -Object $artifacts.final_session_docket -Name "present" -Default $false)
$controlSummaryPresent = [bool](Get-ObjectPropertyValue -Object $artifacts.control_summary -Name "present" -Default $false)
$treatmentSummaryPresent = [bool](Get-ObjectPropertyValue -Object $artifacts.treatment_summary -Name "present" -Default $false)

$runnerErrorDetected = $pairRunnerStderrText -match 'Get-ObjectPropertyValue' -or $pairRunnerStderrText -match 'run_balance_eval\.ps1'
$processExitBeforeSummaryFlush = $runnerErrorDetected -and -not $pairSummaryPresent -and -not $controlSummaryPresent
$verdict = Get-AuditVerdict `
    -ControlReadyObserved:$controlReadyObserved `
    -TreatmentRequested:$treatmentRequested `
    -TreatmentLaneMaterialized:$treatmentLaneMaterialized `
    -PairSummaryPresent:$pairSummaryPresent `
    -FinalSessionDocketPresent:$finalSessionDocketPresent `
    -CloseoutStarted:$closeoutStarted `
    -ProcessExitBeforeSummaryFlush:$processExitBeforeSummaryFlush

$salvageDecision = Get-SalvageDecision `
    -PairSummaryPresent:$pairSummaryPresent `
    -ControlSummaryPresent:$controlSummaryPresent `
    -TreatmentSummaryPresent:$treatmentSummaryPresent `
    -RecoveryReport $recoveryReport

$runnerErrorSummary = if ($runnerErrorDetected) {
    (($pairRunnerStderrText -split "(`r`n|`n|`r)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8) -join [Environment]::NewLine
}
else {
    ""
}

$explanation = switch ($verdict) {
    "process-exit-before-summary-flush" {
        "The full rerun collapsed inside run_balance_eval before the control lane could flush summary.json. Pair-level closeout then had no raw lane summary to build pair_summary.json, certificate, or mission attainment."
    }
    "rerun-failed-before-control-ready" {
        "The rerun never cleared the control-first gate, so treatment was never eligible and the final pair pack could not be completed."
    }
    "control-ready-but-treatment-not-requested" {
        "Control reached ready state, but the runner never requested treatment join, so the pair never advanced to a valid treatment phase."
    }
    "treatment-requested-but-treatment-lane-never-materialized" {
        "Treatment join was requested, but no treatment lane root was materialized, so the pair pack stayed structurally incomplete."
    }
    "treatment-lane-materialized-but-pair-summary-missing" {
        "Both lane roots existed, but closeout never produced pair_summary.json, so downstream certificate and mission artifacts could not be generated."
    }
    "closeout-never-started" {
        "The pair runner never reached closeout, so missing final artifacts reflect an earlier lifecycle failure, not just a post-pipeline gap."
    }
    "closeout-started-but-final-artifacts-missing" {
        "Closeout started, but it did not finish writing the final guided-session artifacts."
    }
    default {
        "The failed rerun leaves a mixed artifact picture that still needs manual review."
    }
}

$audit = [ordered]@{
    schema_version = 1
    prompt_id = $PromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $resolvedPairRoot
    verdict = $verdict
    explanation = $explanation
    earliest_broken_stage = if ($processExitBeforeSummaryFlush) { "control-lane-summary-flush" } elseif (-not $controlReadyObserved) { "control-ready-gate" } elseif (-not $treatmentRequested) { "treatment-request-invocation" } elseif (-not $treatmentLaneMaterialized) { "treatment-lane-materialization" } elseif (-not $pairSummaryPresent) { "pair-summary-generation" } elseif (-not $finalSessionDocketPresent) { "guided-closeout-finalization" } else { "manual-review-required" }
    salvage_decision = [ordered]@{
        structurally_salvageable = [bool]$salvageDecision.structurally_salvageable
        salvageable_with_existing_path = [bool]$salvageDecision.salvageable_with_existing_path
        rerun_required = [bool]$salvageDecision.rerun_required
        manual_review_required = [bool]$salvageDecision.manual_review_required
        explanation = [string]$salvageDecision.explanation
    }
    stage_state = [ordered]@{
        control_ready_observed = $controlReadyObserved
        treatment_requested = $treatmentRequested
        treatment_lane_materialized = $treatmentLaneMaterialized
        closeout_started = $closeoutStarted
        process_exit_before_summary_flush = $processExitBeforeSummaryFlush
        pair_complete = $pairSummaryPresent
    }
    timestamps = [ordered]@{
        control_join_launched_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null) -Name "launch_started_at_utc" -Default "")
        control_first_server_connection_seen_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null) -Name "first_server_connection_seen_at_utc" -Default "")
        control_entered_the_game_seen_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null) -Name "first_entered_the_game_seen_at_utc" -Default "")
        control_ready_observed_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object $controlSwitch -Name "ready_observed_at_utc" -Default "")
        treatment_join_requested_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_lane_join" -Default $null) -Name "join_requested_at_utc" -Default "")
        treatment_join_launched_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_lane_join" -Default $null) -Name "launch_started_at_utc" -Default "")
        closeout_started_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "closeout" -Default $null) -Name "wait_started_at_utc" -Default "")
        rerun_process_exit_observed_at_utc = Convert-ToUtcString -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "closeout" -Default $null) -Name "attempt_process_exit_observed_at_utc" -Default "")
    }
    artifact_completeness = [ordered]@{
        mission_snapshot_present = [bool]$artifacts.mission_snapshot.present
        mission_execution_present = [bool]$artifacts.mission_execution.present
        control_to_treatment_switch_present = [bool]$artifacts.control_to_treatment_switch.present
        treatment_patch_window_present = [bool]$artifacts.treatment_patch_window.present
        conservative_phase_flow_present = [bool]$artifacts.conservative_phase_flow.present
        live_monitor_status_present = [bool]$artifacts.live_monitor_status.present
        pair_summary_present = [bool]$artifacts.pair_summary.present
        grounded_evidence_certificate_present = [bool]$artifacts.grounded_evidence_certificate.present
        mission_attainment_present = [bool]$artifacts.mission_attainment.present
        final_session_docket_present = [bool]$artifacts.final_session_docket.present
        control_lane_summary_present = [bool]$artifacts.control_summary.present
        treatment_lane_summary_present = [bool]$artifacts.treatment_summary.present
        pair_root_structurally_salvageable = [bool]$salvageDecision.structurally_salvageable
    }
    control_lane = [ordered]@{
        lane_root = $controlLaneRoot
        summary_json = $controlSummaryPath
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null) -Name "server_connection_seen" -Default $false)
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null) -Name "entered_the_game_seen" -Default $false)
        last_live_monitor_human_snapshots = [int](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "control_human_snapshots_count" -Default 0)
        last_live_monitor_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "control_human_presence_seconds" -Default 0.0)
        phase_flow_human_snapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $phaseFlow -Name "control_lane" -Default $null) -Name "actual_human_snapshots" -Default 0)
        phase_flow_human_presence_seconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $phaseFlow -Name "control_lane" -Default $null) -Name "actual_human_presence_seconds" -Default 0.0)
    }
    treatment_lane = [ordered]@{
        lane_root = $treatmentLaneRoot
        summary_json = $treatmentSummaryPath
        join_requested = $treatmentRequested
        lane_materialized = $treatmentLaneMaterialized
    }
    runner_error = [ordered]@{
        pair_runner_stdout_log = $pairRunnerStdoutPath
        pair_runner_stderr_log = $pairRunnerStderrPath
        detected = $runnerErrorDetected
        summary = $runnerErrorSummary
    }
    recovery = [ordered]@{
        recovery_verdict = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "recovery_verdict" -Default "")
        recommended_next_action = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "recommended_next_action" -Default "")
        continuation_decision = [string](Get-ObjectPropertyValue -Object $continuationDecision -Name "decision" -Default "")
        continuation_execution_status = [string](Get-ObjectPropertyValue -Object $continuationDecision -Name "execution_status" -Default "")
    }
    evidence_found = @($evidenceFound.ToArray())
    evidence_missing = @($evidenceMissing.ToArray())
    artifacts = [ordered]@{
        mission_snapshot_json = $missionSnapshotPath
        mission_execution_json = $missionExecutionPath
        session_state_json = $sessionStatePath
        control_to_treatment_switch_json = $controlSwitchPath
        conservative_phase_flow_json = $phaseFlowPath
        treatment_patch_window_json = $treatmentPatchWindowPath
        live_monitor_status_json = $liveMonitorStatusPath
        pair_summary_json = $pairSummaryPath
        grounded_evidence_certificate_json = $groundedCertificatePath
        mission_attainment_json = $missionAttainmentPath
        final_session_docket_json = $finalSessionDocketPath
        control_summary_json = $controlSummaryPath
        treatment_summary_json = $treatmentSummaryPath
        session_recovery_report_json = $recoveryReportPath
        continuation_decision_json = $continuationDecisionPath
        pair_runner_stdout_log = $pairRunnerStdoutPath
        pair_runner_stderr_log = $pairRunnerStderrPath
    }
}

$resolvedOutputRoot = if ($OutputRoot) {
    Ensure-Directory -Path $OutputRoot
}
else {
    $resolvedPairRoot
}

$auditJsonPath = Join-Path $resolvedOutputRoot "full_rerun_artifact_gap_audit.json"
$auditMarkdownPath = Join-Path $resolvedOutputRoot "full_rerun_artifact_gap_audit.md"

$markdown = @(
    "# Full Rerun Artifact Gap Audit",
    "",
    "- Pair root: $($audit.pair_root)",
    "- Verdict: $($audit.verdict)",
    "- Earliest broken stage: $($audit.earliest_broken_stage)",
    "- Explanation: $($audit.explanation)",
    "",
    "## Stage State",
    "",
    "- Control ready observed: $($audit.stage_state.control_ready_observed)",
    "- Treatment requested: $($audit.stage_state.treatment_requested)",
    "- Treatment lane materialized: $($audit.stage_state.treatment_lane_materialized)",
    "- Closeout started: $($audit.stage_state.closeout_started)",
    "- Process exit before summary flush: $($audit.stage_state.process_exit_before_summary_flush)",
    "- Pair complete: $($audit.stage_state.pair_complete)",
    "",
    "## Artifact Completeness",
    "",
    "- Mission snapshot present: $($audit.artifact_completeness.mission_snapshot_present)",
    "- Mission execution present: $($audit.artifact_completeness.mission_execution_present)",
    "- Control-to-treatment switch present: $($audit.artifact_completeness.control_to_treatment_switch_present)",
    "- Treatment patch window present: $($audit.artifact_completeness.treatment_patch_window_present)",
    "- Conservative phase flow present: $($audit.artifact_completeness.conservative_phase_flow_present)",
    "- Live monitor status present: $($audit.artifact_completeness.live_monitor_status_present)",
    "- Pair summary present: $($audit.artifact_completeness.pair_summary_present)",
    "- Grounded evidence certificate present: $($audit.artifact_completeness.grounded_evidence_certificate_present)",
    "- Mission attainment present: $($audit.artifact_completeness.mission_attainment_present)",
    "- Final session docket present: $($audit.artifact_completeness.final_session_docket_present)",
    "- Control lane summary present: $($audit.artifact_completeness.control_lane_summary_present)",
    "- Treatment lane summary present: $($audit.artifact_completeness.treatment_lane_summary_present)",
    "- Pair root structurally salvageable: $($audit.artifact_completeness.pair_root_structurally_salvageable)",
    "",
    "## Salvage Decision",
    "",
    "- Structurally salvageable: $($audit.salvage_decision.structurally_salvageable)",
    "- Salvageable with existing path: $($audit.salvage_decision.salvageable_with_existing_path)",
    "- Rerun required: $($audit.salvage_decision.rerun_required)",
    "- Manual review required: $($audit.salvage_decision.manual_review_required)",
    "- Explanation: $($audit.salvage_decision.explanation)",
    "",
    "## Timing",
    "",
    "- Control join launched at: $($audit.timestamps.control_join_launched_at_utc)",
    "- Control first server connection at: $($audit.timestamps.control_first_server_connection_seen_at_utc)",
    "- Control entered the game at: $($audit.timestamps.control_entered_the_game_seen_at_utc)",
    "- Control ready observed at: $($audit.timestamps.control_ready_observed_at_utc)",
    "- Treatment join requested at: $($audit.timestamps.treatment_join_requested_at_utc)",
    "- Treatment join launched at: $($audit.timestamps.treatment_join_launched_at_utc)",
    "- Closeout started at: $($audit.timestamps.closeout_started_at_utc)",
    "- Process exit observed at: $($audit.timestamps.rerun_process_exit_observed_at_utc)",
    "",
    "## Runner Error",
    "",
    "- Error detected: $($audit.runner_error.detected)",
    "- Summary:",
    $($audit.runner_error.summary),
    "",
    "## Evidence Found",
    ""
) + @($audit.evidence_found | ForEach-Object { "- $_" }) + @(
    "",
    "## Evidence Missing",
    ""
) + @($audit.evidence_missing | ForEach-Object { "- $_" }) + @(
    "",
    "## Artifacts",
    ""
) + @(
    "- Mission snapshot JSON: $($audit.artifacts.mission_snapshot_json)",
    "- Mission execution JSON: $($audit.artifacts.mission_execution_json)",
    "- Session state JSON: $($audit.artifacts.session_state_json)",
    "- Control-to-treatment switch JSON: $($audit.artifacts.control_to_treatment_switch_json)",
    "- Conservative phase flow JSON: $($audit.artifacts.conservative_phase_flow_json)",
    "- Treatment patch window JSON: $($audit.artifacts.treatment_patch_window_json)",
    "- Live monitor status JSON: $($audit.artifacts.live_monitor_status_json)",
    "- Pair summary JSON: $($audit.artifacts.pair_summary_json)",
    "- Grounded evidence certificate JSON: $($audit.artifacts.grounded_evidence_certificate_json)",
    "- Mission attainment JSON: $($audit.artifacts.mission_attainment_json)",
    "- Final session docket JSON: $($audit.artifacts.final_session_docket_json)",
    "- Control summary JSON: $($audit.artifacts.control_summary_json)",
    "- Treatment summary JSON: $($audit.artifacts.treatment_summary_json)",
    "- Session recovery report JSON: $($audit.artifacts.session_recovery_report_json)",
    "- Continuation decision JSON: $($audit.artifacts.continuation_decision_json)",
    "- Pair runner stdout log: $($audit.artifacts.pair_runner_stdout_log)",
    "- Pair runner stderr log: $($audit.artifacts.pair_runner_stderr_log)"
) -join [Environment]::NewLine

Write-JsonFile -Path $auditJsonPath -Value $audit
Write-TextFile -Path $auditMarkdownPath -Value ($markdown + [Environment]::NewLine)

Write-Host "Full rerun artifact-gap audit:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Verdict: $($audit.verdict)"
Write-Host "  Earliest broken stage: $($audit.earliest_broken_stage)"
Write-Host "  Structurally salvageable: $($audit.artifact_completeness.pair_root_structurally_salvageable)"
Write-Host "  Rerun required: $($audit.salvage_decision.rerun_required)"
Write-Host "  Audit JSON: $auditJsonPath"
Write-Host "  Audit Markdown: $auditMarkdownPath"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    Verdict = $audit.verdict
    EarliestBrokenStage = $audit.earliest_broken_stage
    StructurallySalvageable = [bool]$audit.artifact_completeness.pair_root_structurally_salvageable
    RerunRequired = [bool]$audit.salvage_decision.rerun_required
    AuditJsonPath = $auditJsonPath
    AuditMarkdownPath = $auditMarkdownPath
}
