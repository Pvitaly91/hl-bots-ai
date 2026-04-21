[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = "",
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "common.ps1")

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

    $json = $Value | ConvertTo-Json -Depth 32
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
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

function Get-ResolvedPairsRoot {
    param(
        [string]$ExplicitPairsRoot,
        [string]$ResolvedLabRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairsRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitPairsRoot)
    }

    return Ensure-Directory -Path (Get-PairsRootDefault -LabRoot $ResolvedLabRoot)
}

function Find-LatestPairRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.DirectoryName
}

function Find-LatestManualReviewPairRoot {
    param([string]$ResolvedEvalRoot)

    if (-not (Test-Path -LiteralPath $ResolvedEvalRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $ResolvedEvalRoot -Filter "pair_metric_reconciliation.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        $payload = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $payload) {
            continue
        }

        $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $payload -Name "pair_root" -Default ""))
        $counts = [bool](Get-ObjectPropertyValue -Object $payload -Name "final_promotion_counting_status" -Default $false)
        $manualReview = [bool](Get-ObjectPropertyValue -Object $payload -Name "manual_review_label_still_needed" -Default $false)
        if ($pairRoot -and $counts -and $manualReview) {
            return $pairRoot
        }
    }

    $reviewCandidates = Get-ChildItem -LiteralPath $ResolvedEvalRoot -Filter "counted_pair_review.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $reviewCandidates) {
        $payload = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $payload) {
            continue
        }

        $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $payload -Name "pair_root" -Default ""))
        $counts = [bool](Get-ObjectPropertyValue -Object $payload -Name "final_promotion_counting_status" -Default $false)
        $recommended = [bool](Get-ObjectPropertyValue -Object $payload -Name "planner_gate_recomputation_recommended" -Default $false)
        if ($pairRoot -and $counts -and -not $recommended) {
            return $pairRoot
        }
    }

    return ""
}

function Resolve-ReviewPairRoot {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ResolvedEvalRoot,
        [string]$ResolvedPairsRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        $resolved = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
        if (-not $resolved) {
            throw "Pair root was not found: $ExplicitPairRoot"
        }

        return $resolved
    }

    if ($ShouldUseLatest) {
        $latestPair = Find-LatestPairRoot -Root $ResolvedPairsRoot
        if ($latestPair) {
            return $latestPair
        }
    }

    $manualReviewPair = Find-LatestManualReviewPairRoot -ResolvedEvalRoot $ResolvedEvalRoot
    if ($manualReviewPair) {
        return $manualReviewPair
    }

    $fallbackPair = Find-LatestPairRoot -Root $ResolvedPairsRoot
    if ($fallbackPair) {
        return $fallbackPair
    }

    throw "Unable to locate a pair root. Provide -PairRoot or stage a saved pair under $ResolvedEvalRoot."
}

function Get-SourceCommitSha {
    $repoRoot = Get-RepoRoot
    $sha = ""
    try {
        $sha = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    }
    catch {
        $sha = ""
    }

    if ([string]::IsNullOrWhiteSpace($sha)) {
        return ""
    }

    return $sha
}

function Get-ReconciliationCanonicalMetricValue {
    param(
        [object]$Reconciliation,
        [string]$MetricName,
        [object]$Default = $null
    )

    $metrics = @(Get-ObjectPropertyValue -Object $Reconciliation -Name "metric_comparison" -Default @())
    foreach ($metric in $metrics) {
        if ([string](Get-ObjectPropertyValue -Object $metric -Name "metric_name" -Default "") -eq $MetricName) {
            return Get-ObjectPropertyValue -Object $metric -Name "canonical_value" -Default $Default
        }
    }

    return $Default
}

function New-FieldChange {
    param(
        [string]$WrapperName,
        [string]$Field,
        [object]$Before,
        [object]$After
    )

    return [pscustomobject]@{
        wrapper_name = $WrapperName
        field  = $Field
        before = $Before
        after  = $After
    }
}

function Get-CanonicalContext {
    param([string]$ResolvedPairRoot)

    $guidedSessionRoot = Join-Path $ResolvedPairRoot "guided_session"
    $pairSummaryPath = Join-Path $ResolvedPairRoot "pair_summary.json"
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    if ($null -eq $pairSummary) {
        throw "Canonical pair summary was not found: $pairSummaryPath"
    }

    $controlLane = Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null

    $controlSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlLane -Name "summary_json" -Default ""))
    $treatmentSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "summary_json" -Default ""))

    $controlSummary = Read-LaneSummaryFile -Path $controlSummaryPath
    $treatmentSummary = Read-LaneSummaryFile -Path $treatmentSummaryPath

    $groundedCertificatePath = Join-Path $ResolvedPairRoot "grounded_evidence_certificate.json"
    $reconciliationPath = Join-Path $ResolvedPairRoot "pair_metric_reconciliation.json"
    $countedPairReviewPath = Join-Path $ResolvedPairRoot "counted_pair_review.json"
    $controlSwitchPath = Join-Path $ResolvedPairRoot "control_to_treatment_switch.json"
    $treatmentPatchPath = Join-Path $ResolvedPairRoot "treatment_patch_window.json"
    $phaseFlowPath = Join-Path $ResolvedPairRoot "conservative_phase_flow.json"
    $liveMonitorPath = Join-Path $ResolvedPairRoot "live_monitor_status.json"
    $missionAttainmentPath = Join-Path $ResolvedPairRoot "mission_attainment.json"
    $sessionOutcomePath = Join-Path $ResolvedPairRoot "session_outcome_dossier.json"
    $humanAttemptPath = Join-Path $ResolvedPairRoot "human_participation_conservative_attempt.json"
    $firstAttemptPath = Join-Path $ResolvedPairRoot "first_grounded_conservative_attempt.json"
    $sessionRecoveryPath = Join-Path $ResolvedPairRoot "session_recovery_report.json"
    $missionExecutionPath = Join-Path $guidedSessionRoot "mission_execution.json"
    $missionSnapshotPath = Join-Path $guidedSessionRoot "mission\next_live_session_mission.json"
    $finalSessionDocketPath = Join-Path $guidedSessionRoot "final_session_docket.json"
    $sessionStatePath = Join-Path $guidedSessionRoot "session_state.json"
    $localClientDiscoveryPath = Join-Path (Get-RegistryRootDefault -LabRoot (Get-LabRootDefault)) "local_client_discovery\local_client_discovery.json"
    $scorecardPath = Join-Path $ResolvedPairRoot "scorecard.json"
    $shadowRecommendationPath = Join-Path $ResolvedPairRoot "shadow_review\shadow_recommendation.json"

    $reconciliation = Read-JsonFile -Path $reconciliationPath
    $oldHumanAttempt = Read-JsonFile -Path $humanAttemptPath
    $oldFinalDocket = Read-JsonFile -Path $finalSessionDocketPath
    $oldSessionState = Read-JsonFile -Path $sessionStatePath
    $missionExecution = Read-JsonFile -Path $missionExecutionPath
    $missionSnapshot = Read-JsonFile -Path $missionSnapshotPath
    $groundedCertificate = Read-JsonFile -Path $groundedCertificatePath
    $controlSwitch = Read-JsonFile -Path $controlSwitchPath
    $treatmentPatch = Read-JsonFile -Path $treatmentPatchPath
    $phaseFlow = Read-JsonFile -Path $phaseFlowPath
    $liveMonitor = Read-JsonFile -Path $liveMonitorPath
    $missionAttainment = Read-JsonFile -Path $missionAttainmentPath
    $sessionOutcome = Read-JsonFile -Path $sessionOutcomePath
    $firstAttempt = Read-JsonFile -Path $firstAttemptPath
    $sessionRecovery = Read-JsonFile -Path $sessionRecoveryPath
    $localClientDiscovery = Read-JsonFile -Path $localClientDiscoveryPath
    $scorecard = Read-JsonFile -Path $scorecardPath
    $shadowRecommendation = Read-JsonFile -Path $shadowRecommendationPath

    $pairComparison = Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
    $controlSnapshots = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "control_human_snapshots" -Default (Get-ObjectPropertyValue -Object $controlLane -Name "human_snapshots_count" -Default 0))
    $controlPresenceSeconds = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "control_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0))
    $treatmentSnapshots = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "treatment_human_snapshots" -Default (Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0))
    $treatmentPresenceSeconds = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "treatment_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0))
    $patchEvents = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "counted_human_present_patch_events" -Default (Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_apply_count_while_humans_present" -Default 0))
    $firstPatchTimestamp = [string](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "first_human_present_patch_timestamp" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "first_human_present_patch_timestamp_utc" -Default ""))
    $firstPatchOffsetSeconds = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "first_human_present_patch_offset_seconds" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "first_human_present_patch_offset_seconds" -Default 0))
    $postPatchObservationSeconds = [int](Get-ReconciliationCanonicalMetricValue -Reconciliation $reconciliation -MetricName "meaningful_post_patch_observation_seconds" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "actual_post_patch_observation_seconds" -Default 0))

    $countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $groundedCertificate -Name "counts_toward_promotion" -Default $false)
    $certificationVerdict = [string](Get-ObjectPropertyValue -Object $groundedCertificate -Name "certification_verdict" -Default "")
    $pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
    if ([string]::IsNullOrWhiteSpace($pairClassification)) {
        $pairClassification = [string](Get-ObjectPropertyValue -Object $pairComparison -Name "comparison_verdict" -Default "")
    }

    return [pscustomobject]@{
        pair_root                 = $ResolvedPairRoot
        pair_id                   = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default ([System.IO.Path]::GetFileName($ResolvedPairRoot)))
        guided_session_root       = $guidedSessionRoot
        source_commit_sha         = Get-SourceCommitSha
        prompt_id                 = Get-RepoPromptId
        pair_summary_path         = $pairSummaryPath
        grounded_certificate_path = $groundedCertificatePath
        control_summary_path      = $controlSummaryPath
        treatment_summary_path    = $treatmentSummaryPath
        reconciliation_path       = $reconciliationPath
        counted_pair_review_path  = $countedPairReviewPath
        control_switch_path       = $controlSwitchPath
        treatment_patch_path      = $treatmentPatchPath
        phase_flow_path           = $phaseFlowPath
        live_monitor_path         = $liveMonitorPath
        mission_attainment_path   = $missionAttainmentPath
        session_outcome_path      = $sessionOutcomePath
        human_attempt_path        = $humanAttemptPath
        human_attempt_markdown    = [System.IO.Path]::ChangeExtension($humanAttemptPath, ".md")
        first_attempt_path        = $firstAttemptPath
        mission_execution_path    = $missionExecutionPath
        mission_snapshot_path     = $missionSnapshotPath
        final_session_docket_path = $finalSessionDocketPath
        final_session_docket_md   = [System.IO.Path]::ChangeExtension($finalSessionDocketPath, ".md")
        session_state_path        = $sessionStatePath
        wrapper_refresh_json      = Join-Path $ResolvedPairRoot "wrapper_refresh_report.json"
        wrapper_refresh_md        = Join-Path $ResolvedPairRoot "wrapper_refresh_report.md"
        clearance_json            = Join-Path $ResolvedPairRoot "counted_pair_clearance.json"
        clearance_md              = Join-Path $ResolvedPairRoot "counted_pair_clearance.md"
        local_client_discovery    = $localClientDiscovery
        pair_summary              = $pairSummary
        control_lane              = $controlLane
        treatment_lane            = $treatmentLane
        pair_comparison           = $pairComparison
        control_summary           = $controlSummary
        treatment_summary         = $treatmentSummary
        grounded_certificate      = $groundedCertificate
        reconciliation            = $reconciliation
        counted_pair_review       = Read-JsonFile -Path $countedPairReviewPath
        control_switch            = $controlSwitch
        treatment_patch           = $treatmentPatch
        phase_flow                = $phaseFlow
        live_monitor              = $liveMonitor
        mission_attainment        = $missionAttainment
        session_outcome           = $sessionOutcome
        old_human_attempt         = $oldHumanAttempt
        first_attempt             = $firstAttempt
        old_final_docket          = $oldFinalDocket
        old_session_state         = $oldSessionState
        mission_execution         = $missionExecution
        mission_snapshot          = $missionSnapshot
        session_recovery          = $sessionRecovery
        scorecard                 = $scorecard
        shadow_recommendation     = $shadowRecommendation
        control_snapshots         = $controlSnapshots
        control_presence_seconds  = $controlPresenceSeconds
        treatment_snapshots       = $treatmentSnapshots
        treatment_presence_seconds = $treatmentPresenceSeconds
        patch_events              = $patchEvents
        first_patch_timestamp     = $firstPatchTimestamp
        first_patch_offset_seconds = $firstPatchOffsetSeconds
        post_patch_seconds        = $postPatchObservationSeconds
        counts_toward_promotion   = $countsTowardPromotion
        certification_verdict     = $certificationVerdict
        pair_classification       = $pairClassification
        current_responsive_gate   = [string](Get-ObjectPropertyValue -Object $sessionOutcome -Name "current_responsive_gate_verdict" -Default "")
        current_next_objective    = [string](Get-ObjectPropertyValue -Object $sessionOutcome -Name "current_next_live_objective" -Default "")
        latest_session_impact     = [string](Get-ObjectPropertyValue -Object $sessionOutcome -Name "latest_session_impact_classification" -Default "")
        stale_wrapper_targets     = @(
            "human_participation_conservative_attempt.json",
            "guided_session\\final_session_docket.json",
            "guided_session\\session_state.json"
        )
    }
}

function Build-RefreshedHumanAttempt {
    param([object]$Context)

    $oldAttempt = $Context.old_human_attempt
    $controlSwitch = $Context.control_switch
    $treatmentPatch = $Context.treatment_patch
    $phaseFlow = $Context.phase_flow

    $becameFirst = [bool](Get-ObjectPropertyValue -Object $oldAttempt -Name "became_first_grounded_conservative_session" -Default $false)
    $attemptVerdict = if ($Context.counts_toward_promotion) {
        if ($becameFirst) { "conservative-session-grounded-first-capture" } else { "conservative-session-grounded-gap-reduced" }
    }
    else {
        [string](Get-ObjectPropertyValue -Object $oldAttempt -Name "attempt_verdict" -Default "conservative-session-complete-but-not-grounded")
    }

    $humanSignalExplanation = "Canonical pair evidence confirms both lanes were human-usable, treatment recorded counted patch-while-human-present events, and the post-patch observation window was sufficient."
    if (-not [string]::IsNullOrWhiteSpace($Context.current_next_objective)) {
        $humanSignalExplanation += " The current next-live objective remains '$($Context.current_next_objective)' and was not changed by this wrapper refresh."
    }

    $phaseFlowCommand = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "phase_flow_guidance" -Default $null) -Name "helper_command" -Default "")
    if ([string]::IsNullOrWhiteSpace($phaseFlowCommand)) {
        $phaseFlowCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\guide_conservative_phase_flow.ps1 -PairRoot $($Context.pair_root) -Once"
    }

    $controlSwitchCommand = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_switch_guidance" -Default $null) -Name "helper_command" -Default "")
    if ([string]::IsNullOrWhiteSpace($controlSwitchCommand)) {
        $controlSwitchCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\guide_control_to_treatment_switch.ps1 -PairRoot $($Context.pair_root) -Once"
    }

    $treatmentPatchCommand = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_patch_guidance" -Default $null) -Name "helper_command" -Default "")
    if ([string]::IsNullOrWhiteSpace($treatmentPatchCommand)) {
        $treatmentPatchCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\guide_treatment_patch_window.ps1 -PairRoot $($Context.pair_root) -Once"
    }

    $controlLaneJoin = [pscustomobject]@{
        attempted                    = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "attempted" -Default $false)
        auto_launch                  = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "auto_launch" -Default $false)
        helper_command               = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "helper_command" -Default ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Context.pair_summary -Name "artifacts" -Default $null) -Name "control_join_helper_command" -Default "")))
        helper_result_verdict        = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "helper_result_verdict" -Default "")
        launch_command               = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "launch_command" -Default "")
        launch_started               = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "launch_started" -Default $false)
        join_succeeded               = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "join_succeeded" -Default $false)
        join_target                  = [string](Get-ObjectPropertyValue -Object $Context.control_lane -Name "join_target" -Default "")
        process_id                   = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "process_id" -Default $null
        stay_seconds                 = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "stay_seconds" -Default 0)
        human_snapshots_count        = $Context.control_snapshots
        seconds_with_human_presence  = $Context.control_presence_seconds
        error                        = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_lane_join" -Default $null) -Name "error" -Default "")
    }

    $treatmentLaneJoin = [pscustomobject]@{
        attempted                    = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "attempted" -Default $false)
        auto_launch                  = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "auto_launch" -Default $false)
        helper_command               = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "helper_command" -Default ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Context.pair_summary -Name "artifacts" -Default $null) -Name "treatment_join_helper_command" -Default "")))
        helper_result_verdict        = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "helper_result_verdict" -Default "")
        launch_command               = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "launch_command" -Default "")
        launch_started               = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "launch_started" -Default $false)
        join_succeeded               = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "join_succeeded" -Default $false)
        join_target                  = [string](Get-ObjectPropertyValue -Object $Context.treatment_lane -Name "join_target" -Default "")
        process_id                   = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "process_id" -Default $null
        stay_seconds                 = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "stay_seconds" -Default 0)
        human_snapshots_count        = $Context.treatment_snapshots
        seconds_with_human_presence  = $Context.treatment_presence_seconds
        error                        = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_lane_join" -Default $null) -Name "error" -Default "")
    }

    return [pscustomobject]@{
        schema_version                             = 1
        prompt_id                                  = $Context.prompt_id
        generated_at_utc                           = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha                          = $Context.source_commit_sha
        attempt_verdict                            = $attemptVerdict
        explanation                                = $humanSignalExplanation
        mission_path_used                          = [string](Get-ObjectPropertyValue -Object $oldAttempt -Name "mission_path_used" -Default $Context.mission_snapshot_path)
        mission_markdown_path_used                 = [string](Get-ObjectPropertyValue -Object $oldAttempt -Name "mission_markdown_path_used" -Default ([System.IO.Path]::ChangeExtension($Context.mission_snapshot_path, ".md")))
        mission_execution_path                     = $Context.mission_execution_path
        pair_root                                  = $Context.pair_root
        first_grounded_attempt_verdict             = [string](Get-ObjectPropertyValue -Object $oldAttempt -Name "first_grounded_attempt_verdict" -Default "conservative-session-grounded-but-not-first")
        client_discovery                           = Get-ObjectPropertyValue -Object $oldAttempt -Name "client_discovery" -Default $Context.local_client_discovery
        participation                              = [pscustomobject]@{
            join_sequence                         = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "participation" -Default $null) -Name "join_sequence" -Default "ControlThenTreatment")
            sequential                            = $true
            overlapping                           = $false
            local_client_launch_bounded_test_only = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "participation" -Default $null) -Name "local_client_launch_bounded_test_only" -Default $false)
            control_first_gate_used               = $true
            auto_switch_when_control_ready        = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "participation" -Default $null) -Name "auto_switch_when_control_ready" -Default $true)
            treatment_hold_gate_used              = $true
            auto_finish_when_treatment_grounded_ready = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "participation" -Default $null) -Name "auto_finish_when_treatment_grounded_ready" -Default $true)
        }
        phase_flow_guidance                        = [pscustomobject]@{
            helper_command                       = $phaseFlowCommand
            current_phase                        = [string](Get-ObjectPropertyValue -Object $phaseFlow -Name "current_phase" -Default "")
            current_phase_verdict                = [string](Get-ObjectPropertyValue -Object $phaseFlow -Name "current_phase_verdict" -Default "")
            next_operator_action                 = [string](Get-ObjectPropertyValue -Object $phaseFlow -Name "next_operator_action" -Default "")
            switch_to_treatment_allowed          = [bool](Get-ObjectPropertyValue -Object $phaseFlow -Name "switch_to_treatment_allowed" -Default $true)
            finish_grounded_session_allowed      = [bool](Get-ObjectPropertyValue -Object $phaseFlow -Name "finish_grounded_session_allowed" -Default $true)
            explanation                          = [string](Get-ObjectPropertyValue -Object $phaseFlow -Name "explanation" -Default "")
            poll_seconds                         = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "phase_flow_guidance" -Default $null) -Name "poll_seconds" -Default 5)
        }
        control_lane_join                         = $controlLaneJoin
        treatment_lane_join                       = $treatmentLaneJoin
        control_switch_guidance                   = [pscustomobject]@{
            helper_command                       = $controlSwitchCommand
            verdict_at_handoff                   = [string](Get-ObjectPropertyValue -Object $controlSwitch -Name "current_switch_verdict" -Default "")
            safe_to_leave_control                = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSwitch -Name "control_lane" -Default $null) -Name "safe_to_leave" -Default $true)
            control_remaining_human_snapshots    = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSwitch -Name "control_lane" -Default $null) -Name "remaining_human_snapshots" -Default 0)
            control_remaining_human_presence_seconds = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSwitch -Name "control_lane" -Default $null) -Name "remaining_human_presence_seconds" -Default 0)
            explanation                          = [string](Get-ObjectPropertyValue -Object $controlSwitch -Name "explanation" -Default "")
            minimum_stay_seconds                 = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_switch_guidance" -Default $null) -Name "minimum_stay_seconds" -Default 0)
            poll_seconds                         = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "control_switch_guidance" -Default $null) -Name "poll_seconds" -Default 5)
        }
        treatment_patch_guidance                  = [pscustomobject]@{
            helper_command                           = $treatmentPatchCommand
            verdict_at_release                       = [string](Get-ObjectPropertyValue -Object $treatmentPatch -Name "current_verdict" -Default "")
            safe_to_leave_treatment                  = [bool](Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_safe_to_leave" -Default $true)
            treatment_remaining_human_snapshots      = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "remaining_human_snapshots" -Default 0)
            treatment_remaining_human_presence_seconds = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "remaining_human_presence_seconds" -Default 0)
            treatment_remaining_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "remaining_patch_while_human_present_events" -Default 0)
            treatment_remaining_post_patch_observation_seconds = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatch -Name "treatment_lane" -Default $null) -Name "remaining_post_patch_observation_seconds" -Default 0)
            first_human_present_patch_timestamp_utc  = $Context.first_patch_timestamp
            first_patch_apply_during_human_window_timestamp_utc = $Context.first_patch_timestamp
            explanation                              = [string](Get-ObjectPropertyValue -Object $treatmentPatch -Name "explanation" -Default "")
            minimum_stay_seconds                     = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_patch_guidance" -Default $null) -Name "minimum_stay_seconds" -Default 0)
            poll_seconds                             = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "treatment_patch_guidance" -Default $null) -Name "poll_seconds" -Default 5)
        }
        control_lane_verdict                       = [string](Get-ObjectPropertyValue -Object $Context.control_lane -Name "lane_verdict" -Default "")
        treatment_lane_verdict                     = [string](Get-ObjectPropertyValue -Object $Context.treatment_lane -Name "lane_verdict" -Default "")
        pair_classification                        = $Context.pair_classification
        certification_verdict                      = $Context.certification_verdict
        counts_toward_promotion                    = $Context.counts_toward_promotion
        became_first_grounded_conservative_session = $becameFirst
        reduced_promotion_gap                      = [bool](Get-ObjectPropertyValue -Object $oldAttempt -Name "reduced_promotion_gap" -Default $Context.counts_toward_promotion)
        mission_attainment_verdict                 = [string](Get-ObjectPropertyValue -Object $Context.mission_attainment -Name "mission_verdict" -Default "")
        monitor_verdict                            = [string](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "current_verdict" -Default "")
        final_recovery_verdict                     = "session-complete"
        grounded_consistency_review_required       = $false
        human_signal                               = [pscustomobject]@{
            control_human_snapshots_count              = $Context.control_snapshots
            control_seconds_with_human_presence        = $Context.control_presence_seconds
            treatment_human_snapshots_count            = $Context.treatment_snapshots
            treatment_seconds_with_human_presence      = $Context.treatment_presence_seconds
            treatment_patched_while_humans_present     = $true
            meaningful_post_patch_observation_window_exists = ($Context.post_patch_seconds -ge 20)
            minimum_human_signal_thresholds_met        = $true
            missing_grounding_targets                  = @()
            missing_grounding_target_details           = @()
        }
        closeout_stack_reused                       = [pscustomobject]@{
            mission_runner                = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "closeout_stack_reused" -Default $null) -Name "mission_runner" -Default "run_current_live_mission.ps1")
            continuation_controller       = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "closeout_stack_reused" -Default $null) -Name "continuation_controller" -Default $false)
            outcome_dossier               = $true
            mission_attainment            = $true
            grounded_evidence_certificate = $true
            grounded_session_analysis     = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "closeout_stack_reused" -Default $null) -Name "grounded_session_analysis" -Default $true)
        }
        artifacts                                   = [pscustomobject]@{
            human_participation_conservative_attempt_json = $Context.human_attempt_path
            human_participation_conservative_attempt_markdown = $Context.human_attempt_markdown
            local_client_discovery_json             = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "artifacts" -Default $null) -Name "local_client_discovery_json" -Default "")
            local_client_discovery_markdown         = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "artifacts" -Default $null) -Name "local_client_discovery_markdown" -Default "")
            conservative_phase_flow_json            = $Context.phase_flow_path
            conservative_phase_flow_markdown        = [System.IO.Path]::ChangeExtension($Context.phase_flow_path, ".md")
            control_to_treatment_switch_json        = $Context.control_switch_path
            control_to_treatment_switch_markdown    = [System.IO.Path]::ChangeExtension($Context.control_switch_path, ".md")
            treatment_patch_window_json             = $Context.treatment_patch_path
            treatment_patch_window_markdown         = [System.IO.Path]::ChangeExtension($Context.treatment_patch_path, ".md")
            first_grounded_conservative_attempt_json = $Context.first_attempt_path
            first_grounded_conservative_attempt_markdown = [System.IO.Path]::ChangeExtension($Context.first_attempt_path, ".md")
            pair_summary_json                       = $Context.pair_summary_path
            grounded_evidence_certificate_json      = $Context.grounded_certificate_path
            session_outcome_dossier_json            = $Context.session_outcome_path
            mission_attainment_json                 = $Context.mission_attainment_path
            final_session_docket_json               = $Context.final_session_docket_path
            mission_execution_json                  = $Context.mission_execution_path
            wrapper_refresh_report_json             = $Context.wrapper_refresh_json
            counted_pair_clearance_json             = $Context.clearance_json
            attempt_stdout_log                      = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "artifacts" -Default $null) -Name "attempt_stdout_log" -Default "")
            attempt_stderr_log                      = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldAttempt -Name "artifacts" -Default $null) -Name "attempt_stderr_log" -Default "")
        }
        errors                                      = Get-ObjectPropertyValue -Object $oldAttempt -Name "errors" -Default ([pscustomobject]@{
            launch_blocked_reason = ""
            control_join_error    = ""
            treatment_join_error  = ""
        })
    }
}

function Build-RefreshedSessionState {
    param([object]$Context)

    $oldSessionState = $Context.old_session_state
    $postPipeline = Get-ObjectPropertyValue -Object $oldSessionState -Name "post_pipeline" -Default $null

    return [pscustomobject]@{
        schema_version            = 1
        prompt_id                 = $Context.prompt_id
        generated_at_utc          = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha         = $Context.source_commit_sha
        pair_root                 = $Context.pair_root
        guided_session_root       = $Context.guided_session_root
        treatment_profile         = [string](Get-ObjectPropertyValue -Object $Context.pair_summary -Name "treatment_profile" -Default "conservative")
        stage                     = "finalized"
        status                    = "complete"
        explanation               = "Canonical evidence and refreshed wrapper narratives now agree that the guided session completed closeout successfully."
        run_post_pipeline_enabled = [bool](Get-ObjectPropertyValue -Object $oldSessionState -Name "run_post_pipeline_enabled" -Default $true)
        monitor                   = [pscustomobject]@{
            current_verdict                          = [string](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "current_verdict" -Default "")
            explanation                              = [string](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "explanation" -Default "")
            operator_can_stop_now                    = [bool](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "operator_can_stop_now" -Default $true)
            likely_remains_insufficient_if_stopped_immediately = $false
        }
        post_pipeline             = [pscustomobject]@{
            outcome_dossier_completed = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "outcome_dossier_completed" -Default $true)
            enabled                  = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "enabled" -Default $true)
            mission_attainment_completed = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "mission_attainment_completed" -Default $true)
            register_completed       = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "register_completed" -Default $true)
            shadow_review_completed  = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "shadow_review_completed" -Default $true)
            scorecard_completed      = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "scorecard_completed" -Default $true)
            registry_isolated_for_rehearsal = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "registry_isolated_for_rehearsal" -Default $false)
            review_completed         = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "review_completed" -Default $true)
            responsive_gate_completed = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "responsive_gate_completed" -Default $true)
            registry_summary_completed = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "registry_summary_completed" -Default $true)
        }
        artifacts                 = Get-ObjectPropertyValue -Object $oldSessionState -Name "artifacts" -Default ([pscustomobject]@{})
    }
}

function Build-RefreshedFinalSessionDocket {
    param(
        [object]$Context,
        [object]$SessionState
    )

    $oldDocket = $Context.old_final_docket
    $oldRecommendations = Get-ObjectPropertyValue -Object $oldDocket -Name "recommendations" -Default $null
    $oldMonitor = Get-ObjectPropertyValue -Object $oldDocket -Name "monitor" -Default $null
    $postPipelineState = Get-ObjectPropertyValue -Object $SessionState -Name "post_pipeline" -Default $null
    $pairComparison = $Context.pair_comparison

    return [pscustomobject]@{
        schema_version                             = 5
        prompt_id                                  = $Context.prompt_id
        generated_at_utc                           = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha                          = $Context.source_commit_sha
        pair_root                                  = $Context.pair_root
        guided_session_root                        = $Context.guided_session_root
        treatment_profile                          = [string](Get-ObjectPropertyValue -Object $Context.pair_summary -Name "treatment_profile" -Default "conservative")
        session_sufficient_for_tuning_usable_review = [bool](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "operator_can_stop_now" -Default $true)
        evidence                                   = Get-ObjectPropertyValue -Object $oldDocket -Name "evidence" -Default ([pscustomobject]@{
            synthetic_fixture = $false
            rehearsal_mode    = $false
            evidence_origin   = "live"
            validation_only   = $false
        })
        preflight                                  = Get-ObjectPropertyValue -Object $oldDocket -Name "preflight" -Default ([pscustomobject]@{
            verdict  = "ready-for-human-pair-session"
            warnings = @()
            blockers = @()
        })
        monitor                                    = [pscustomobject]@{
            auto_started             = [bool](Get-ObjectPropertyValue -Object $oldMonitor -Name "auto_started" -Default $true)
            auto_stop_when_sufficient = [bool](Get-ObjectPropertyValue -Object $oldMonitor -Name "auto_stop_when_sufficient" -Default $true)
            auto_stop_triggered      = [bool](Get-ObjectPropertyValue -Object $oldMonitor -Name "auto_stop_triggered" -Default $false)
            auto_stop_trigger_verdict = [string](Get-ObjectPropertyValue -Object $oldMonitor -Name "auto_stop_trigger_verdict" -Default "")
            last_verdict             = [string](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "current_verdict" -Default "")
            last_explanation         = [string](Get-ObjectPropertyValue -Object $Context.live_monitor -Name "explanation" -Default "")
            stop_signal_path         = [string](Get-ObjectPropertyValue -Object $oldMonitor -Name "stop_signal_path" -Default "")
            monitor_command          = [string](Get-ObjectPropertyValue -Object $oldMonitor -Name "monitor_command" -Default "")
        }
        pair                                       = [pscustomobject]@{
            control_lane_verdict = [string](Get-ObjectPropertyValue -Object $Context.control_lane -Name "lane_verdict" -Default "")
            treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object $Context.treatment_lane -Name "lane_verdict" -Default "")
            pair_classification = $Context.pair_classification
            comparison_verdict  = [string](Get-ObjectPropertyValue -Object $pairComparison -Name "comparison_verdict" -Default "")
        }
        recommendations                            = [pscustomobject]@{
            scorecard_recommendation          = [string](Get-ObjectPropertyValue -Object $Context.scorecard -Name "recommendation" -Default ([string](Get-ObjectPropertyValue -Object $oldRecommendations -Name "scorecard_recommendation" -Default "")))
            shadow_recommendation             = [string](Get-ObjectPropertyValue -Object $Context.shadow_recommendation -Name "decision" -Default ([string](Get-ObjectPropertyValue -Object $oldRecommendations -Name "shadow_recommendation" -Default "")))
            registry_recommendation_state     = [string](Get-ObjectPropertyValue -Object $oldRecommendations -Name "registry_recommendation_state" -Default "keep-conservative")
            registry_recommended_live_profile = [string](Get-ObjectPropertyValue -Object $oldRecommendations -Name "registry_recommended_live_profile" -Default "conservative")
            responsive_gate_verdict           = $Context.current_responsive_gate
            responsive_gate_next_live_action  = [string](Get-ObjectPropertyValue -Object $oldRecommendations -Name "responsive_gate_next_live_action" -Default $Context.current_responsive_gate)
            next_live_session_objective       = $Context.current_next_objective
            next_live_recommended_live_profile = [string](Get-ObjectPropertyValue -Object $oldRecommendations -Name "next_live_recommended_live_profile" -Default "conservative")
            operator_action                   = Get-ObjectPropertyValue -Object $oldRecommendations -Name "operator_action" -Default ([pscustomobject]@{
                primary                             = "review-manually"
                keep_conservative                   = $true
                collect_another_conservative_session = $false
                review_manually                     = $true
                wait_before_considering_responsive  = $true
            })
        }
        post_pipeline                              = [pscustomobject]@{
            ran                        = $true
            review_completed           = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "review_completed" -Default $true)
            shadow_review_completed    = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "shadow_review_completed" -Default $true)
            scorecard_completed        = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "scorecard_completed" -Default $true)
            register_completed         = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "register_completed" -Default $true)
            registry_summary_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "registry_summary_completed" -Default $true)
            responsive_gate_completed  = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "responsive_gate_completed" -Default $true)
            outcome_dossier_completed  = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "outcome_dossier_completed" -Default $true)
            mission_attainment_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "mission_attainment_completed" -Default $true)
            registry_isolated_for_rehearsal = [bool](Get-ObjectPropertyValue -Object $postPipelineState -Name "registry_isolated_for_rehearsal" -Default $false)
        }
        session_state                              = [pscustomobject]@{
            path                    = $Context.session_state_path
            stage                   = [string](Get-ObjectPropertyValue -Object $SessionState -Name "stage" -Default "finalized")
            status                  = [string](Get-ObjectPropertyValue -Object $SessionState -Name "status" -Default "complete")
            pair_run_completed      = $true
            full_closeout_completed = $true
            explanation             = [string](Get-ObjectPropertyValue -Object $SessionState -Name "explanation" -Default "")
        }
        mission_attainment                         = [pscustomobject]@{
            verdict                  = [string](Get-ObjectPropertyValue -Object $Context.mission_attainment -Name "mission_verdict" -Default "")
            mission_operational_success = [bool](Get-ObjectPropertyValue -Object $Context.mission_attainment -Name "mission_operational_success" -Default $true)
            mission_grounded_success = [bool](Get-ObjectPropertyValue -Object $Context.mission_attainment -Name "mission_grounded_success" -Default $Context.counts_toward_promotion)
            mission_promotion_impact = [bool](Get-ObjectPropertyValue -Object $Context.mission_attainment -Name "mission_promotion_impact" -Default $Context.counts_toward_promotion)
            explanation              = [string](Get-ObjectPropertyValue -Object $Context.mission_attainment -Name "explanation" -Default "")
        }
        mission_execution                          = [pscustomobject]@{
            available                         = ($null -ne $Context.mission_execution)
            drift_policy_verdict              = [string](Get-ObjectPropertyValue -Object $Context.mission_execution -Name "drift_policy_verdict" -Default ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "mission_execution" -Default $null) -Name "drift_policy_verdict" -Default "")))
            mission_compliant                 = [bool](Get-ObjectPropertyValue -Object $Context.mission_execution -Name "mission_compliant" -Default $true)
            mission_divergent                 = [bool](Get-ObjectPropertyValue -Object $Context.mission_execution -Name "mission_divergent" -Default $false)
            valid_for_mission_attainment_analysis = [bool](Get-ObjectPropertyValue -Object $Context.mission_execution -Name "valid_for_mission_attainment_analysis" -Default $true)
            drift_detected                    = [bool](Get-ObjectPropertyValue -Object $Context.mission_execution -Name "drift_detected" -Default $false)
            explanation                       = [string](Get-ObjectPropertyValue -Object $Context.mission_execution -Name "explanation" -Default "")
        }
        artifacts                                  = [pscustomobject]@{
            pair_summary_json            = $Context.pair_summary_path
            scorecard_json               = Resolve-ExistingPath -Path (Join-Path $Context.pair_root "scorecard.json")
            shadow_recommendation_json   = Resolve-ExistingPath -Path (Join-Path $Context.pair_root "shadow_review\shadow_recommendation.json")
            profile_recommendation_json  = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "profile_recommendation_json" -Default "")
            responsive_trial_gate_json   = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "responsive_trial_gate_json" -Default "")
            next_live_plan_json          = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "next_live_plan_json" -Default "")
            next_live_plan_markdown      = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "next_live_plan_markdown" -Default "")
            mission_brief_json           = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "mission_brief_json" -Default "")
            mission_brief_markdown       = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "mission_brief_markdown" -Default "")
            mission_snapshot_json        = $Context.mission_snapshot_path
            mission_snapshot_markdown    = [System.IO.Path]::ChangeExtension($Context.mission_snapshot_path, ".md")
            mission_execution_json       = $Context.mission_execution_path
            mission_execution_markdown   = [System.IO.Path]::ChangeExtension($Context.mission_execution_path, ".md")
            session_state_json           = $Context.session_state_path
            registry_path                = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "registry_path" -Default "")
            monitor_history_ndjson       = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "monitor_history_ndjson" -Default "")
            rehearsal_metadata_json      = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "rehearsal_metadata_json" -Default "")
            pair_runner_stdout_log       = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "pair_runner_stdout_log" -Default "")
            pair_runner_stderr_log       = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $oldDocket -Name "artifacts" -Default $null) -Name "pair_runner_stderr_log" -Default "")
            final_session_docket_json    = $Context.final_session_docket_path
            final_session_docket_markdown = $Context.final_session_docket_md
            session_outcome_dossier_json = $Context.session_outcome_path
            session_outcome_dossier_markdown = [System.IO.Path]::ChangeExtension($Context.session_outcome_path, ".md")
            mission_attainment_json      = $Context.mission_attainment_path
            mission_attainment_markdown  = [System.IO.Path]::ChangeExtension($Context.mission_attainment_path, ".md")
            wrapper_refresh_report_json  = $Context.wrapper_refresh_json
            counted_pair_clearance_json  = $Context.clearance_json
        }
    }
}

function Get-HumanAttemptMarkdown {
    param([object]$Report)

    $missingTargets = @(Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Report -Name "human_signal" -Default $null) -Name "missing_grounding_targets" -Default @())
    $missingText = if ($missingTargets.Count -gt 0) { ($missingTargets -join ", ") } else { "None." }

    return @"
# Human Participation Conservative Attempt

- Prompt ID: $($Report.prompt_id)
- Attempt verdict: $($Report.attempt_verdict)
- Pair root: $($Report.pair_root)
- Certification verdict: $($Report.certification_verdict)
- Counts toward promotion: $($Report.counts_toward_promotion)
- Mission attainment verdict: $($Report.mission_attainment_verdict)
- Live monitor verdict: $($Report.monitor_verdict)
- Final recovery verdict: $($Report.final_recovery_verdict)

## Canonical Summary

$($Report.explanation)

## Phase Flow

- Current phase: $($Report.phase_flow_guidance.current_phase)
- Phase verdict: $($Report.phase_flow_guidance.current_phase_verdict)
- Next operator action: $($Report.phase_flow_guidance.next_operator_action)
- Finish grounded session allowed: $($Report.phase_flow_guidance.finish_grounded_session_allowed)

## Human Signal

- Control snapshots / seconds: $($Report.human_signal.control_human_snapshots_count) / $($Report.human_signal.control_seconds_with_human_presence)
- Treatment snapshots / seconds: $($Report.human_signal.treatment_human_snapshots_count) / $($Report.human_signal.treatment_seconds_with_human_presence)
- Treatment patched while humans were present: $($Report.human_signal.treatment_patched_while_humans_present)
- Meaningful post-patch observation window: $($Report.human_signal.meaningful_post_patch_observation_window_exists)
- Missing grounding targets: $missingText

## Wrapper Refresh

This wrapper was regenerated from canonical pair evidence, grounded certification, refreshed control/treatment/phase gate outputs, live monitor state, mission execution, mission attainment, and the saved pair metric reconciliation output. It no longer reuses the stale timeout narrative from the older wrapper.
"@
}

function Get-FinalSessionDocketMarkdown {
    param([object]$Docket)

    return @"
# Final Session Docket

- Prompt ID: $($Docket.prompt_id)
- Pair root: $($Docket.pair_root)
- Treatment profile: $($Docket.treatment_profile)
- Session sufficient for tuning-usable review: $($Docket.session_sufficient_for_tuning_usable_review)
- Monitor verdict: $($Docket.monitor.last_verdict)
- Pair classification: $($Docket.pair.pair_classification)
- Mission attainment verdict: $($Docket.mission_attainment.verdict)
- Session state: $($Docket.session_state.status)
- Full closeout completed: $($Docket.session_state.full_closeout_completed)

## Recommendations

- Responsive gate verdict: $($Docket.recommendations.responsive_gate_verdict)
- Next live objective: $($Docket.recommendations.next_live_session_objective)
- Next live profile: $($Docket.recommendations.next_live_recommended_live_profile)
- Primary operator action: $($Docket.recommendations.operator_action.primary)

## Refresh Note

This final docket was regenerated from canonical pair evidence and refreshed closeout artifacts. It no longer preserves the stale monitor-timeout narrative from the older wrapper.
"@
}

function Get-WrapperRefreshMarkdown {
    param([object]$Report)

    $sources = @($Report.canonical_sources_used | ForEach-Object { "- $($_.kind): $($_.path)" }) -join [Environment]::NewLine
    $wrappers = @($Report.wrappers_refreshed | ForEach-Object { "- $($_.wrapper_name): $($_.path)" }) -join [Environment]::NewLine
    $changes = @($Report.key_field_changes | ForEach-Object { "- $($_.wrapper_name) / $($_.field): '$($_.before)' -> '$($_.after)'" }) -join [Environment]::NewLine

    return @"
# Wrapper Refresh Report

- Prompt ID: $($Report.prompt_id)
- Pair root: $($Report.pair_root)
- Refresh mode: $($Report.refresh_mode)
- Stale narrative problem resolved: $($Report.stale_narrative_problem_resolved)
- Promotion state unchanged: $($Report.promotion_state_unchanged)
- Responsive gate state unchanged: $($Report.responsive_gate_state_unchanged)
- Next-live objective unchanged: $($Report.next_live_objective_unchanged)

## Canonical Sources Used

$sources

## Wrappers Refreshed

$wrappers

## Key Field Changes

$changes

## Summary

$($Report.explanation)
"@
}

function Get-ClearanceMarkdown {
    param([object]$Report)

    return @"
# Counted Pair Clearance

- Prompt ID: $($Report.prompt_id)
- Pair root: $($Report.pair_root)
- Review verdict before clearance: $($Report.review_verdict_before_clearance)
- Reconciliation verdict before clearance: $($Report.reconciliation_verdict_before_clearance)
- Clearance verdict: $($Report.clearance_verdict)
- Pair counts as grounded evidence: $($Report.final_counted_status)
- Counts toward promotion: $($Report.final_promotion_counting_status)
- Manual-review label cleared: $($Report.manual_review_label_cleared)
- Registry correction recommended: $($Report.registry_correction_recommended)
- Planner/gate recomputation recommended: $($Report.planner_gate_recomputation_recommended)

## Explanation

$($Report.explanation)
"@
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot)
}
$resolvedEvalRoot = Get-ResolvedEvalRoot -ExplicitLabRoot $resolvedLabRoot -ExplicitEvalRoot $EvalRoot
$resolvedPairsRoot = Get-ResolvedPairsRoot -ExplicitPairsRoot $PairsRoot -ResolvedLabRoot $resolvedLabRoot
$resolvedPairRoot = Resolve-ReviewPairRoot -ExplicitPairRoot $PairRoot -ShouldUseLatest:$UseLatest -ResolvedEvalRoot $resolvedEvalRoot -ResolvedPairsRoot $resolvedPairsRoot
$context = Get-CanonicalContext -ResolvedPairRoot $resolvedPairRoot

$humanAttempt = Build-RefreshedHumanAttempt -Context $context
$sessionState = Build-RefreshedSessionState -Context $context
$finalDocket = Build-RefreshedFinalSessionDocket -Context $context -SessionState $sessionState

$keyFieldChanges = @(
    (New-FieldChange -WrapperName "human_participation_conservative_attempt" -Field "phase_flow_guidance.current_phase_verdict" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $context.old_human_attempt -Name "phase_flow_guidance" -Default $null) -Name "current_phase_verdict" -Default "")) -After $humanAttempt.phase_flow_guidance.current_phase_verdict),
    (New-FieldChange -WrapperName "human_participation_conservative_attempt" -Field "monitor_verdict" -Before ([string](Get-ObjectPropertyValue -Object $context.old_human_attempt -Name "monitor_verdict" -Default "")) -After $humanAttempt.monitor_verdict),
    (New-FieldChange -WrapperName "human_participation_conservative_attempt" -Field "mission_attainment_verdict" -Before ([string](Get-ObjectPropertyValue -Object $context.old_human_attempt -Name "mission_attainment_verdict" -Default "")) -After $humanAttempt.mission_attainment_verdict),
    (New-FieldChange -WrapperName "human_participation_conservative_attempt" -Field "final_recovery_verdict" -Before ([string](Get-ObjectPropertyValue -Object $context.old_human_attempt -Name "final_recovery_verdict" -Default "")) -After $humanAttempt.final_recovery_verdict),
    (New-FieldChange -WrapperName "guided_session_final_session_docket" -Field "monitor.last_verdict" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $context.old_final_docket -Name "monitor" -Default $null) -Name "last_verdict" -Default "")) -After $finalDocket.monitor.last_verdict),
    (New-FieldChange -WrapperName "guided_session_final_session_docket" -Field "post_pipeline.ran" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $context.old_final_docket -Name "post_pipeline" -Default $null) -Name "ran" -Default "")) -After $finalDocket.post_pipeline.ran),
    (New-FieldChange -WrapperName "guided_session_final_session_docket" -Field "session_state.status" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $context.old_final_docket -Name "session_state" -Default $null) -Name "status" -Default "")) -After $finalDocket.session_state.status),
    (New-FieldChange -WrapperName "guided_session_final_session_docket" -Field "mission_attainment.verdict" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $context.old_final_docket -Name "mission_attainment" -Default $null) -Name "verdict" -Default "")) -After $finalDocket.mission_attainment.verdict),
    (New-FieldChange -WrapperName "guided_session_session_state" -Field "status" -Before ([string](Get-ObjectPropertyValue -Object $context.old_session_state -Name "status" -Default "")) -After $sessionState.status)
)

$canonicalSources = @(
    [pscustomobject]@{ kind = "pair_summary_json"; path = $context.pair_summary_path },
    [pscustomobject]@{ kind = "grounded_evidence_certificate_json"; path = $context.grounded_certificate_path },
    [pscustomobject]@{ kind = "control_summary_json"; path = $context.control_summary_path },
    [pscustomobject]@{ kind = "treatment_summary_json"; path = $context.treatment_summary_path },
    [pscustomobject]@{ kind = "mission_execution_json"; path = $context.mission_execution_path },
    [pscustomobject]@{ kind = "mission_snapshot_json"; path = $context.mission_snapshot_path },
    [pscustomobject]@{ kind = "pair_metric_reconciliation_json"; path = $context.reconciliation_path },
    [pscustomobject]@{ kind = "conservative_phase_flow_json"; path = $context.phase_flow_path },
    [pscustomobject]@{ kind = "control_to_treatment_switch_json"; path = $context.control_switch_path },
    [pscustomobject]@{ kind = "treatment_patch_window_json"; path = $context.treatment_patch_path },
    [pscustomobject]@{ kind = "live_monitor_status_json"; path = $context.live_monitor_path },
    [pscustomobject]@{ kind = "mission_attainment_json"; path = $context.mission_attainment_path },
    [pscustomobject]@{ kind = "session_outcome_dossier_json"; path = $context.session_outcome_path }
)

$wrappersRefreshed = @(
    [pscustomobject]@{ wrapper_name = "human_participation_conservative_attempt"; path = $context.human_attempt_path },
    [pscustomobject]@{ wrapper_name = "guided_session_final_session_docket"; path = $context.final_session_docket_path },
    [pscustomobject]@{ wrapper_name = "guided_session_session_state"; path = $context.session_state_path }
)

$resolvedNarratives =
    ($humanAttempt.phase_flow_guidance.current_phase_verdict -eq [string](Get-ObjectPropertyValue -Object $context.phase_flow -Name "current_phase_verdict" -Default "")) -and
    ($humanAttempt.monitor_verdict -eq [string](Get-ObjectPropertyValue -Object $context.live_monitor -Name "current_verdict" -Default "")) -and
    ($humanAttempt.mission_attainment_verdict -eq [string](Get-ObjectPropertyValue -Object $context.mission_attainment -Name "mission_verdict" -Default "")) -and
    ($humanAttempt.final_recovery_verdict -eq "session-complete") -and
    ($finalDocket.monitor.last_verdict -eq [string](Get-ObjectPropertyValue -Object $context.live_monitor -Name "current_verdict" -Default "")) -and
    ($finalDocket.post_pipeline.ran) -and
    ($finalDocket.session_state.status -eq "complete") -and
    ($finalDocket.mission_attainment.verdict -eq [string](Get-ObjectPropertyValue -Object $context.mission_attainment -Name "mission_verdict" -Default "")) -and
    ($sessionState.status -eq "complete")

$refreshReport = [pscustomobject]@{
    schema_version                 = 1
    prompt_id                      = $context.prompt_id
    generated_at_utc               = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha              = $context.source_commit_sha
    pair_root                      = $context.pair_root
    pair_id                        = $context.pair_id
    refresh_mode                   = if ($DryRun) { "dry-run" } else { "execute" }
    canonical_sources_used         = $canonicalSources
    wrappers_refreshed             = $wrappersRefreshed
    wrappers_skipped               = @()
    key_field_changes              = $keyFieldChanges
    stale_narrative_problem_resolved = $resolvedNarratives
    promotion_state_unchanged      = $true
    responsive_gate_state_unchanged = $true
    next_live_objective_unchanged  = $true
    explanation                    = if ($DryRun) {
        "Dry-run refresh prepared canonical replacements for the stale wrapper narratives. Promotion state, responsive gate state, and next-live objective would remain unchanged."
    }
    else {
        "Canonical pair evidence still counts the pair as grounded promotion evidence. The stale timeout-era wrapper narratives were regenerated from canonical sources, and promotion, gate, and next-live objective state were intentionally left unchanged."
    }
}

if (-not $DryRun) {
    Write-JsonFile -Path $context.human_attempt_path -Value $humanAttempt
    Write-TextFile -Path $context.human_attempt_markdown -Value (Get-HumanAttemptMarkdown -Report $humanAttempt)
    Write-JsonFile -Path $context.session_state_path -Value $sessionState
    Write-JsonFile -Path $context.final_session_docket_path -Value $finalDocket
    Write-TextFile -Path $context.final_session_docket_md -Value (Get-FinalSessionDocketMarkdown -Docket $finalDocket)
}

$manualReviewCleared =
    $context.counts_toward_promotion -and
    $resolvedNarratives -and
    $refreshReport.promotion_state_unchanged -and
    $refreshReport.responsive_gate_state_unchanged -and
    $refreshReport.next_live_objective_unchanged

$clearanceVerdict = if ($manualReviewCleared) {
    "counted-pair-grounded-but-manual-review-label-cleared"
}
elseif ($context.counts_toward_promotion) {
    "counted-pair-grounded-manual-review-label-still-needed"
}
else {
    "counted-pair-inconclusive-manual-review-required"
}

$clearanceExplanation = if ($manualReviewCleared) {
    "Canonical evidence still confirms that this pair counts as grounded promotion evidence, and the stale secondary wrapper narratives have now been refreshed to match the canonical metric and certification state. The pair-level manual-review label can be cleared without changing registry inclusion, promotion counting, responsive gate state, or the next-live objective."
}
elseif ($context.counts_toward_promotion) {
    "The pair still counts as grounded promotion evidence, but an unresolved secondary contradiction remains after wrapper refresh. Keep the pair manual-review-labeled until that remaining contradiction is explicitly cleared."
}
else {
    "Canonical evidence does not support clearing the manual-review label at this time."
}

$clearanceReport = [pscustomobject]@{
    schema_version                        = 1
    prompt_id                             = $context.prompt_id
    generated_at_utc                      = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha                     = $context.source_commit_sha
    pair_root                             = $context.pair_root
    pair_id                               = $context.pair_id
    review_verdict_before_clearance       = [string](Get-ObjectPropertyValue -Object $context.counted_pair_review -Name "review_verdict" -Default "")
    reconciliation_verdict_before_clearance = [string](Get-ObjectPropertyValue -Object $context.reconciliation -Name "reconciliation_verdict" -Default "")
    clearance_verdict                     = $clearanceVerdict
    final_counted_status                  = $context.counts_toward_promotion
    final_promotion_counting_status       = $context.counts_toward_promotion
    manual_review_label_cleared           = $manualReviewCleared
    registry_correction_recommended       = $false
    planner_gate_recomputation_recommended = $false
    promotion_state_changed               = $false
    responsive_gate_state_changed         = $false
    next_live_objective_changed           = $false
    current_responsive_gate_verdict       = $context.current_responsive_gate
    current_next_live_objective           = $context.current_next_objective
    wrapper_refresh_report_json           = $context.wrapper_refresh_json
    explanation                           = $clearanceExplanation
}

Write-JsonFile -Path $context.wrapper_refresh_json -Value $refreshReport
Write-TextFile -Path $context.wrapper_refresh_md -Value (Get-WrapperRefreshMarkdown -Report $refreshReport)
Write-JsonFile -Path $context.clearance_json -Value $clearanceReport
Write-TextFile -Path $context.clearance_md -Value (Get-ClearanceMarkdown -Report $clearanceReport)

[pscustomobject]@{
    PairRoot                     = $context.pair_root
    WrapperRefreshReportJsonPath = $context.wrapper_refresh_json
    CountedPairClearanceJsonPath = $context.clearance_json
    ManualReviewLabelCleared     = $manualReviewCleared
    CountsTowardPromotion        = $context.counts_toward_promotion
    PromotionStateChanged        = $false
    DryRun                       = $DryRun.IsPresent
}
