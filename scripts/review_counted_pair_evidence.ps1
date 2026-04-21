[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = "",
    [switch]$SkipSafeDerivedArtifactRefresh
)

. (Join-Path $PSScriptRoot "common.ps1")

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

    $json = $Value | ConvertTo-Json -Depth 24
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

    $candidates = Get-ChildItem -LiteralPath $ResolvedEvalRoot -Filter "promotion_gap_delta.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        try {
            $payload = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
        }
        catch {
            continue
        }

        $impact = [string](Get-ObjectPropertyValue -Object $payload -Name "impact_classification" -Default "")
        $counts = [bool](Get-ObjectPropertyValue -Object $payload -Name "counts_toward_promotion" -Default $false)
        $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $payload -Name "pair_root" -Default ""))
        if ($impact -eq "manual-review-needed" -and $counts -and $pairRoot) {
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
        return Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
    }

    $manualReviewTarget = Find-LatestManualReviewPairRoot -ResolvedEvalRoot $ResolvedEvalRoot
    if ($manualReviewTarget) {
        return $manualReviewTarget
    }

    if ($ShouldUseLatest) {
        $latestEvalPair = Find-LatestPairRoot -Root $ResolvedEvalRoot
        if ($latestEvalPair) {
            return Resolve-ExistingPath -Path $latestEvalPair
        }
    }

    return Resolve-ExistingPath -Path (Find-LatestPairRoot -Root $ResolvedPairsRoot)
}

function Get-ArtifactRecord {
    param(
        [string]$Kind,
        [string]$Path,
        [bool]$Authoritative,
        [string]$Role,
        [string]$Summary
    )

    return [ordered]@{
        kind = $Kind
        path = $Path
        found = -not [string]::IsNullOrWhiteSpace($Path)
        authoritative = $Authoritative
        role = $Role
        summary = $Summary
    }
}

function Get-BooleanText {
    param([bool]$Value)
    return $Value.ToString().ToLowerInvariant()
}

function Add-UniqueText {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    if (-not $List.Contains($Text)) {
        $List.Add($Text) | Out-Null
    }
}

function Get-OutputPaths {
    param(
        [string]$ResolvedPairRoot,
        [string]$ExplicitOutputRoot,
        [string]$ResolvedEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitOutputRoot)) {
        $root = Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitOutputRoot)
        return [ordered]@{
            JsonPath = Join-Path $root "counted_pair_review.json"
            MarkdownPath = Join-Path $root "counted_pair_review.md"
        }
    }

    if ($ResolvedPairRoot) {
        return [ordered]@{
            JsonPath = Join-Path $ResolvedPairRoot "counted_pair_review.json"
            MarkdownPath = Join-Path $ResolvedPairRoot "counted_pair_review.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedEvalRoot "registry\counted_pair_review")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot "counted_pair_review.json"
        MarkdownPath = Join-Path $fallbackRoot "counted_pair_review.md"
    }
}

function Invoke-SafeDerivedRefresh {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedLabRoot
    )

    $builderPath = Join-Path $PSScriptRoot "build_latest_session_outcome_dossier.ps1"
    $commandText = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\build_latest_session_outcome_dossier.ps1",
        "-PairRoot",
        $ResolvedPairRoot,
        "-LabRoot",
        $ResolvedLabRoot
    ) | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }

    try {
        $result = & $builderPath -PairRoot $ResolvedPairRoot -LabRoot $ResolvedLabRoot
        return [ordered]@{
            attempted = $true
            command = ($commandText -join " ")
            succeeded = $true
            error = ""
            artifacts = [ordered]@{
                session_outcome_dossier_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $result -Name "SessionOutcomeDossierJsonPath" -Default ""))
                session_outcome_dossier_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $result -Name "SessionOutcomeDossierMarkdownPath" -Default ""))
            }
        }
    }
    catch {
        return [ordered]@{
            attempted = $true
            command = ($commandText -join " ")
            succeeded = $false
            error = $_.Exception.Message
            artifacts = [ordered]@{}
        }
    }
}

function Get-ReviewMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Counted Pair Review") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Review verdict: $($Report.review_verdict)") | Out-Null
    $lines.Add("- Final counted status: $($Report.final_counted_status)") | Out-Null
    $lines.Add("- Final promotion-counting status: $($Report.final_promotion_counting_status)") | Out-Null
    $lines.Add("- Certification verdict before review: $($Report.certification_verdict_before_review)") | Out-Null
    $lines.Add("- Registry correction recommended: $($Report.registry_correction_recommended)") | Out-Null
    $lines.Add("- Planner/gate recomputation recommended: $($Report.planner_gate_recomputation_recommended)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Authoritative Evidence") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control usable: $($Report.grounded_criteria.control_human_signal_met)") | Out-Null
    $lines.Add("- Control snapshots / seconds: $($Report.grounded_criteria.control_human_snapshots_actual) / $($Report.grounded_criteria.control_human_presence_seconds_actual)") | Out-Null
    $lines.Add("- Treatment usable: $($Report.grounded_criteria.treatment_human_signal_met)") | Out-Null
    $lines.Add("- Treatment snapshots / seconds: $($Report.grounded_criteria.treatment_human_snapshots_actual) / $($Report.grounded_criteria.treatment_human_presence_seconds_actual)") | Out-Null
    $lines.Add("- Treatment patch apply count while humans present: $($Report.grounded_criteria.treatment_patch_apply_count_while_humans_present)") | Out-Null
    $lines.Add("- Treatment emitted patch events while humans present: $($Report.grounded_criteria.treatment_patch_events_while_humans_present_count)") | Out-Null
    $lines.Add("- Meaningful post-patch observation window: $($Report.grounded_criteria.meaningful_post_patch_observation_window_exists)") | Out-Null
    $lines.Add("- Pair truly satisfies grounded criteria: $($Report.grounded_criteria.truly_satisfies_grounded_criteria)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Evidence Priority") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($artifact in @($Report.authoritative_artifacts)) {
        $lines.Add("- $($artifact.kind): $($artifact.path)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Potentially Stale Narrative Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($artifact in @($Report.potentially_stale_narrative_artifacts)) {
        $lines.Add("- $($artifact.kind): $($artifact.path)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Review Notes") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($note in @($Report.authoritative_conflicts)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$note)) {
            $lines.Add("- Authoritative conflict: $note") | Out-Null
        }
    }
    foreach ($note in @($Report.narrative_contradictions)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$note)) {
            $lines.Add("- Narrative contradiction: $note") | Out-Null
        }
    }
    if (@($Report.safe_refresh).Count -gt 0) {
        $lines.Add("") | Out-Null
        $lines.Add("## Safe Refresh") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("- Safe derived artifact refresh attempted: $($Report.safe_refresh.attempted)") | Out-Null
        $lines.Add("- Safe derived artifact refresh succeeded: $($Report.safe_refresh.succeeded)") | Out-Null
        $lines.Add("- Safe refresh command: $($Report.safe_refresh.command)") | Out-Null
        if (-not [string]::IsNullOrWhiteSpace([string]$Report.safe_refresh.error)) {
            $lines.Add("- Safe refresh error: $($Report.safe_refresh.error)") | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
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

if (-not $resolvedPairRoot) {
    throw "A counted pair review target could not be resolved."
}

$outputPaths = Get-OutputPaths -ResolvedPairRoot $resolvedPairRoot -ExplicitOutputRoot $OutputRoot -ResolvedEvalRoot $resolvedEvalRoot

$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
if (-not $pairSummaryPath) {
    throw "pair_summary.json was not found under $resolvedPairRoot"
}

$pairSummary = Read-JsonFile -Path $pairSummaryPath
if ($null -eq $pairSummary) {
    throw "pair_summary.json could not be parsed: $pairSummaryPath"
}

$comparisonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "comparison.json")
$comparisonPayload = Read-JsonFile -Path $comparisonPath
$comparison = if ($null -ne $comparisonPayload) {
    Get-ObjectPropertyValue -Object $comparisonPayload -Name "comparison" -Default $comparisonPayload
}
else {
    Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
}

$certificatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_evidence_certificate.json")
$certificate = Read-JsonFile -Path $certificatePath
$controlSwitchPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "control_to_treatment_switch.json")
$controlSwitch = Read-JsonFile -Path $controlSwitchPath
$treatmentPatchPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "treatment_patch_window.json")
$treatmentPatch = Read-JsonFile -Path $treatmentPatchPath
$phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "conservative_phase_flow.json")
$phaseFlow = Read-JsonFile -Path $phaseFlowPath
$missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\mission_execution.json")
$missionExecution = Read-JsonFile -Path $missionExecutionPath
$missionSnapshotPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\mission\next_live_session_mission.json")
$missionSnapshot = Read-JsonFile -Path $missionSnapshotPath
$liveMonitorStatusPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$liveMonitorStatus = Read-JsonFile -Path $liveMonitorStatusPath
$monitorHistoryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\monitor_verdict_history.ndjson")
$monitorHistory = Read-NdjsonFile -Path $monitorHistoryPath
$missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_attainment.json")
$missionAttainment = Read-JsonFile -Path $missionAttainmentPath
$humanAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "human_participation_conservative_attempt.json")
$humanAttempt = Read-JsonFile -Path $humanAttemptPath
$firstAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "first_grounded_conservative_attempt.json")
$firstAttempt = Read-JsonFile -Path $firstAttemptPath
$finalDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\final_session_docket.json")
$finalDocket = Read-JsonFile -Path $finalDocketPath
$promotionGapDeltaPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "promotion_gap_delta.json")
$promotionGapDelta = Read-JsonFile -Path $promotionGapDeltaPath
$sessionOutcomeDossierPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "session_outcome_dossier.json")
$sessionOutcomeDossier = Read-JsonFile -Path $sessionOutcomeDossierPath
$groundedAnalysisPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_session_analysis.json")
$groundedAnalysis = Read-JsonFile -Path $groundedAnalysisPath
$registryPath = Resolve-ExistingPath -Path (Join-Path $resolvedEvalRoot "registry\pair_sessions.ndjson")
$registryEntries = Read-NdjsonFile -Path $registryPath

$controlLane = Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null
$treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
$treatmentLaneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_root" -Default ""))
$treatmentSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "summary_json" -Default ""))
if (-not $treatmentSummaryPath -and $treatmentLaneRoot) {
    $treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json")
}
$treatmentSummaryPayload = Read-JsonFile -Path $treatmentSummaryPath
$treatmentSummary = if ($null -ne $treatmentSummaryPayload) {
    Get-ObjectPropertyValue -Object $treatmentSummaryPayload -Name "primary_lane" -Default $treatmentSummaryPayload
}
else {
    $null
}
$patchApplyHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_apply_history.ndjson") } else { "" }
$patchHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_history.ndjson") } else { "" }
$telemetryHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "telemetry_history.ndjson") } else { "" }
$patchApplyHistory = Read-NdjsonFile -Path $patchApplyHistoryPath
$patchHistory = Read-NdjsonFile -Path $patchHistoryPath

$pairId = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default "")
$registryEntry = $registryEntries |
    Where-Object {
        [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "") -eq $pairId -or
        [string](Get-ObjectPropertyValue -Object $_ -Name "pair_root" -Default "") -eq $resolvedPairRoot
    } |
    Select-Object -First 1

$controlSnapshotsTarget = [int](Get-ObjectPropertyValue -Object $missionSnapshot -Name "target_minimum_control_human_snapshots" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_snapshots" -Default 0))
$controlSecondsTarget = [double](Get-ObjectPropertyValue -Object $missionSnapshot -Name "target_minimum_control_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_presence_seconds" -Default 0.0))
$treatmentSnapshotsTarget = [int](Get-ObjectPropertyValue -Object $missionSnapshot -Name "target_minimum_treatment_human_snapshots" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_snapshots" -Default 0))
$treatmentSecondsTarget = [double](Get-ObjectPropertyValue -Object $missionSnapshot -Name "target_minimum_treatment_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_presence_seconds" -Default 0.0))
$patchEventsTarget = [int](Get-ObjectPropertyValue -Object $missionSnapshot -Name "target_minimum_treatment_patch_while_human_present_events" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "min_patch_events_for_usable_lane" -Default 0))
$postPatchTarget = [double](Get-ObjectPropertyValue -Object $missionSnapshot -Name "target_minimum_post_patch_observation_window_seconds" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "min_post_patch_observation_seconds" -Default 0.0))

$controlSnapshotsActual = [int](Get-ObjectPropertyValue -Object $controlLane -Name "human_snapshots_count" -Default 0)
$controlSecondsActual = [double](Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0.0)
$treatmentSnapshotsActual = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0)
$treatmentSecondsActual = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)
$patchApplyCountWhileHumansPresent = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_apply_count_while_humans_present" -Default 0)
$patchEventCountWhileHumansPresent = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_events_while_humans_present_count" -Default 0)
$humanReactivePatchApplyCount = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "human_reactive_patch_apply_count" -Default 0)
$postPatchWindowCount = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "response_after_patch_observation_window_count" -Default 0)
$meaningfulPostPatch = [bool](Get-ObjectPropertyValue -Object $treatmentSummary -Name "meaningful_post_patch_observation_window_exists" -Default (Get-ObjectPropertyValue -Object $comparison -Name "meaningful_post_patch_observation_window_exists" -Default $false))
$pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
$comparisonVerdict = [string](Get-ObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default "")
$evidenceOrigin = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default "live")
$rehearsalMode = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Default $false)
$syntheticFixture = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Default $false)
$validationOnly = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Default $false)
$certificateCountsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
$certificateVerdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
$registryCountsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $registryEntry -Name "counts_toward_promotion" -Default $false)
$currentResponsiveGate = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $promotionGapDelta -Name "responsive_gate_after" -Default $null) -Name "gate_verdict" -Default "")
$currentNextObjective = [string](Get-ObjectPropertyValue -Object $promotionGapDelta -Name "next_objective_after" -Default "")

$controlHumanSignalMet = $controlSnapshotsActual -ge $controlSnapshotsTarget -and $controlSecondsActual -ge $controlSecondsTarget
$treatmentHumanSignalMet = $treatmentSnapshotsActual -ge $treatmentSnapshotsTarget -and $treatmentSecondsActual -ge $treatmentSecondsTarget
$treatmentPatchTargetMetByApplies = $patchApplyCountWhileHumansPresent -ge $patchEventsTarget
$treatmentPatchTargetMetByEvents = $patchEventCountWhileHumansPresent -ge $patchEventsTarget
$postPatchTargetMet = $meaningfulPostPatch -and $postPatchTarget -le 20.0 -or ($meaningfulPostPatch -and $postPatchTarget -gt 20.0 -and $postPatchWindowCount -gt 0)
$pairStrongEnough = $pairClassification -in @("tuning-usable", "strong-signal") -and $comparisonVerdict -in @("comparison-usable", "comparison-strong-signal")
$evidenceEligible = $evidenceOrigin -eq "live" -and -not $rehearsalMode -and -not $syntheticFixture -and -not $validationOnly
$rawGroundedCriteriaMet = $evidenceEligible -and $controlHumanSignalMet -and $treatmentHumanSignalMet -and $treatmentPatchTargetMetByApplies -and $meaningfulPostPatch -and $pairStrongEnough

$authoritativeConflicts = New-Object System.Collections.Generic.List[string]
$narrativeContradictions = New-Object System.Collections.Generic.List[string]
$staleNarrativeNeedsCorrection = $false

if ($certificateCountsTowardPromotion -and -not $rawGroundedCriteriaMet) {
    Add-UniqueText -List $authoritativeConflicts -Text "The grounded evidence certificate counts the pair, but the raw pair/mission evidence does not satisfy the grounded criteria."
}

if ($certificateCountsTowardPromotion -and $treatmentPatchTargetMetByApplies -and -not $treatmentPatchTargetMetByEvents) {
    Add-UniqueText -List $authoritativeConflicts -Text ("The treatment gate counted only {0}/{1} emitted human-present patch event(s), but the treatment lane recorded {2}/{1} patch applies during the human window." -f $patchEventCountWhileHumansPresent, $patchEventsTarget, $patchApplyCountWhileHumansPresent)
}

$monitorTreatmentSnapshots = [int](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_human_snapshots_count" -Default -1)
$monitorTreatmentSeconds = [double](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_human_presence_seconds" -Default -1.0)
$monitorPatchEvents = [int](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_patch_events_while_humans_present" -Default -1)
$monitorPostPatchSeconds = [double](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "meaningful_post_patch_observation_seconds" -Default -1.0)
$monitorVerdict = [string](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "current_verdict" -Default "")

if ($monitorTreatmentSnapshots -ge 0 -and $treatmentSnapshotsActual -ne $monitorTreatmentSnapshots) {
    Add-UniqueText -List $authoritativeConflicts -Text ("The saved live-monitor status ended with treatment snapshots {0}, but the pair summary and treatment lane summary show {1}." -f $monitorTreatmentSnapshots, $treatmentSnapshotsActual)
}

if ($monitorTreatmentSeconds -ge 0 -and [Math]::Abs($treatmentSecondsActual - $monitorTreatmentSeconds) -gt 0.1) {
    Add-UniqueText -List $authoritativeConflicts -Text ("The saved live-monitor status ended with treatment human-presence seconds {0}, but the pair summary and treatment lane summary show {1}." -f $monitorTreatmentSeconds, $treatmentSecondsActual)
}

if ($monitorPatchEvents -ge 0 -and $patchApplyCountWhileHumansPresent -ne $monitorPatchEvents) {
    Add-UniqueText -List $authoritativeConflicts -Text ("The saved live-monitor status ended with treatment patch events while humans present = {0}, but the treatment lane recorded {1} patch applies during the human window." -f $monitorPatchEvents, $patchApplyCountWhileHumansPresent)
}

if ($monitorPostPatchSeconds -ge 0 -and $meaningfulPostPatch -and $monitorPostPatchSeconds -lt $postPatchTarget) {
    Add-UniqueText -List $authoritativeConflicts -Text ("The saved live-monitor status reported no meaningful post-patch window, but the treatment lane summary marked the post-patch observation window as meaningful.")
}

$missionVerdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")
if ($rawGroundedCriteriaMet -and $missionVerdict -like "mission-failed*") {
    $staleNarrativeNeedsCorrection = $true
    Add-UniqueText -List $narrativeContradictions -Text ("mission_attainment.json still says '{0}', but the pair summary, treatment summary, and certificate show grounded evidence that counts toward promotion." -f $missionVerdict)
}

$humanAttemptVerdict = [string](Get-ObjectPropertyValue -Object $humanAttempt -Name "attempt_verdict" -Default "")
if ($humanAttemptVerdict -and $humanAttemptVerdict -notlike "manual-review-required" -and $humanAttemptVerdict -notlike "*no-meaningful-human-signal*") {
    if ($rawGroundedCriteriaMet -and @($authoritativeConflicts).Count -gt 0) {
        $staleNarrativeNeedsCorrection = $true
        Add-UniqueText -List $narrativeContradictions -Text ("human_participation_conservative_attempt.json reused a grounded-success narrative even though the saved gate artifacts still disagreed about treatment readiness.")
    }
}

$firstAttemptVerdict = [string](Get-ObjectPropertyValue -Object $firstAttempt -Name "attempt_verdict" -Default "")
if ($rawGroundedCriteriaMet -and $firstAttemptVerdict -like "conservative-session-grounded*" -and $missionVerdict -like "mission-failed*") {
    $staleNarrativeNeedsCorrection = $true
    Add-UniqueText -List $narrativeContradictions -Text ("first_grounded_conservative_attempt.json correctly counted the pair, but mission-attainment narrative text under the same pair root still reports missing treatment signal.")
}

$finalDocketMonitorVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $finalDocket -Name "monitor" -Default $null) -Name "last_verdict" -Default "")
if ($rawGroundedCriteriaMet -and $finalDocketMonitorVerdict -eq "insufficient-data-timeout") {
    $staleNarrativeNeedsCorrection = $true
    Add-UniqueText -List $narrativeContradictions -Text "The final session docket preserved the stale monitor verdict 'insufficient-data-timeout' even though the pair summary/certificate classify the saved pair as grounded and promotion-counting."
}

$reviewVerdict = ""
if (-not $rawGroundedCriteriaMet) {
    if ($certificateCountsTowardPromotion) {
        $reviewVerdict = "counted-pair-needs-registry-correction"
    }
    else {
        $reviewVerdict = "counted-pair-non-grounded"
    }
}
elseif (@($authoritativeConflicts).Count -gt 0) {
    $reviewVerdict = "counted-pair-needs-manual-review-label"
}
elseif ($staleNarrativeNeedsCorrection -or @($narrativeContradictions).Count -gt 0) {
    $reviewVerdict = "counted-pair-grounded-but-narrative-stale"
}
else {
    $reviewVerdict = "counted-pair-confirmed-grounded"
}

$finalCountedStatus = $rawGroundedCriteriaMet
$finalPromotionCountingStatus = $rawGroundedCriteriaMet
$registryCorrectionRecommended = $finalPromotionCountingStatus -ne $registryCountsTowardPromotion
$plannerGateRecomputationRecommended = $registryCorrectionRecommended -or (
    $reviewVerdict -eq "counted-pair-needs-manual-review-label" -and $currentResponsiveGate -ne "manual-review-needed"
)
$manualReviewLabelRecommended = $reviewVerdict -eq "counted-pair-needs-manual-review-label" -or $reviewVerdict -eq "counted-pair-inconclusive-manual-review-required"

$safeRefresh = [ordered]@{
    attempted = $false
    command = ""
    succeeded = $false
    error = ""
    artifacts = [ordered]@{}
}

if (-not $SkipSafeDerivedArtifactRefresh -and $finalCountedStatus -and ($staleNarrativeNeedsCorrection -or $manualReviewLabelRecommended)) {
    $safeRefresh = Invoke-SafeDerivedRefresh -ResolvedPairRoot $resolvedPairRoot -ResolvedLabRoot $resolvedLabRoot
}

$authoritativeArtifacts = @(
    (Get-ArtifactRecord -Kind "pair_summary_json" -Path $pairSummaryPath -Authoritative $true -Role "authoritative-derived-summary" -Summary "Pair-level control/treatment human signal, comparison verdict, and grounded-session classification."),
    (Get-ArtifactRecord -Kind "treatment_summary_json" -Path $treatmentSummaryPath -Authoritative $true -Role "authoritative-lane-summary" -Summary "Treatment lane raw-derived summary including patch applies during the human window."),
    (Get-ArtifactRecord -Kind "patch_apply_history_ndjson" -Path $patchApplyHistoryPath -Authoritative $true -Role "authoritative-raw-history" -Summary "Raw patch application timestamps and server-time offsets."),
    (Get-ArtifactRecord -Kind "patch_history_ndjson" -Path $patchHistoryPath -Authoritative $true -Role "authoritative-raw-history" -Summary "Raw patch recommendation/emission history."),
    (Get-ArtifactRecord -Kind "grounded_evidence_certificate_json" -Path $certificatePath -Authoritative $true -Role "authoritative-derived-certification" -Summary "Promotion-counting grounded evidence certification."),
    (Get-ArtifactRecord -Kind "control_to_treatment_switch_json" -Path $controlSwitchPath -Authoritative $true -Role "authoritative-operator-gate" -Summary "Control gate output showing when the handoff to treatment became allowed."),
    (Get-ArtifactRecord -Kind "treatment_patch_window_json" -Path $treatmentPatchPath -Authoritative $true -Role "authoritative-operator-gate" -Summary "Treatment hold gate output using the helper's human-present patch-event metric."),
    (Get-ArtifactRecord -Kind "conservative_phase_flow_json" -Path $phaseFlowPath -Authoritative $true -Role "authoritative-operator-gate" -Summary "Sequential phase-director output composed from the control and treatment gates."),
    (Get-ArtifactRecord -Kind "mission_execution_json" -Path $missionExecutionPath -Authoritative $true -Role "authoritative-mission-context" -Summary "Mission-compliance record and launch parameters."),
    (Get-ArtifactRecord -Kind "mission_snapshot_json" -Path $missionSnapshotPath -Authoritative $true -Role "authoritative-mission-context" -Summary "Saved mission thresholds for this exact pair."),
    (Get-ArtifactRecord -Kind "live_monitor_status_json" -Path $liveMonitorStatusPath -Authoritative $true -Role "authoritative-monitor-state" -Summary "Saved live-monitor stop-state and last seen treatment thresholds."),
    (Get-ArtifactRecord -Kind "monitor_verdict_history_ndjson" -Path $monitorHistoryPath -Authoritative $true -Role "authoritative-monitor-history" -Summary "Saved live-monitor verdict history.")
)

$staleNarrativeArtifacts = @(
    (Get-ArtifactRecord -Kind "mission_attainment_json" -Path $missionAttainmentPath -Authoritative $false -Role "potentially-stale-narrative" -Summary "Mission-closeout narrative that inherited stale monitor treatment values."),
    (Get-ArtifactRecord -Kind "human_participation_conservative_attempt_json" -Path $humanAttemptPath -Authoritative $false -Role "potentially-stale-narrative" -Summary "Wrapper report that mixed grounded certification with a still-closed phase gate."),
    (Get-ArtifactRecord -Kind "first_grounded_conservative_attempt_json" -Path $firstAttemptPath -Authoritative $false -Role "potentially-stale-narrative" -Summary "Milestone wrapper that reused later derived explanations."),
    (Get-ArtifactRecord -Kind "final_session_docket_json" -Path $finalDocketPath -Authoritative $false -Role "potentially-stale-narrative" -Summary "Final docket monitor section preserved the stale insufficient-data monitor verdict.")
)

$explanationParts = New-Object System.Collections.Generic.List[string]
if ($finalCountedStatus) {
    Add-UniqueText -List $explanationParts -Text "The reviewed pair still counts as grounded promotion evidence."
}
else {
    Add-UniqueText -List $explanationParts -Text "The reviewed pair does not satisfy grounded promotion criteria from the saved evidence."
}

if ($manualReviewLabelRecommended) {
    Add-UniqueText -List $explanationParts -Text "The pair should keep a manual-review label because authoritative artifacts disagree about the treatment-side patch-event metric."
}

if ($staleNarrativeNeedsCorrection) {
    Add-UniqueText -List $explanationParts -Text "Mission-attainment and wrapper narratives should not be treated as authoritative for this pair because they inherited stale monitor state."
}

if (-not $registryCorrectionRecommended) {
    Add-UniqueText -List $explanationParts -Text "No registry correction is recommended because the final promotion-counting status matches the current registry entry."
}
else {
    Add-UniqueText -List $explanationParts -Text "Registry correction is recommended because the final promotion-counting status differs from the current registry entry."
}

if (-not $plannerGateRecomputationRecommended) {
    Add-UniqueText -List $explanationParts -Text "No planner/gate recomputation is recommended from this review alone."
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $resolvedPairRoot
    pair_id = $pairId
    target_selection = if ([string]::IsNullOrWhiteSpace($PairRoot)) { "current-manual-review-target" } else { "explicit-pair-root" }
    certification_verdict_before_review = $certificateVerdict
    review_verdict = $reviewVerdict
    final_counted_status = $finalCountedStatus
    final_promotion_counting_status = $finalPromotionCountingStatus
    final_manual_review_label_recommended = $manualReviewLabelRecommended
    registry_counts_toward_promotion_before_review = $registryCountsTowardPromotion
    registry_correction_recommended = $registryCorrectionRecommended
    planner_gate_recomputation_recommended = $plannerGateRecomputationRecommended
    explanation = (($explanationParts.ToArray()) -join " ")
    authoritative_evidence_precedence = [ordered]@{
        raw_history_and_lane_summaries = @(
            "patch_apply_history.ndjson",
            "patch_history.ndjson",
            "treatment lane summary.json"
        )
        pair_and_mission_state = @(
            "pair_summary.json",
            "mission_execution.json",
            "mission snapshot"
        )
        operator_gate_and_monitor_state = @(
            "control_to_treatment_switch.json",
            "treatment_patch_window.json",
            "conservative_phase_flow.json",
            "live_monitor_status.json",
            "monitor_verdict_history.ndjson"
        )
        certification_and_registry_layer = @(
            "grounded_evidence_certificate.json",
            "pair_sessions.ndjson registry entry"
        )
        potentially_stale_narrative_outputs = @(
            "mission_attainment.json",
            "human_participation_conservative_attempt.json",
            "first_grounded_conservative_attempt.json",
            "guided final_session_docket.json"
        )
    }
    grounded_criteria = [ordered]@{
        evidence_origin = $evidenceOrigin
        rehearsal_mode = $rehearsalMode
        synthetic_fixture = $syntheticFixture
        validation_only = $validationOnly
        control_human_snapshots_target = $controlSnapshotsTarget
        control_human_snapshots_actual = $controlSnapshotsActual
        control_human_presence_seconds_target = $controlSecondsTarget
        control_human_presence_seconds_actual = $controlSecondsActual
        treatment_human_snapshots_target = $treatmentSnapshotsTarget
        treatment_human_snapshots_actual = $treatmentSnapshotsActual
        treatment_human_presence_seconds_target = $treatmentSecondsTarget
        treatment_human_presence_seconds_actual = $treatmentSecondsActual
        treatment_patch_target = $patchEventsTarget
        treatment_patch_apply_count_while_humans_present = $patchApplyCountWhileHumansPresent
        treatment_patch_events_while_humans_present_count = $patchEventCountWhileHumansPresent
        treatment_human_reactive_patch_apply_count = $humanReactivePatchApplyCount
        treatment_post_patch_observation_target_seconds = $postPatchTarget
        treatment_post_patch_window_count = $postPatchWindowCount
        meaningful_post_patch_observation_window_exists = $meaningfulPostPatch
        control_human_signal_met = $controlHumanSignalMet
        treatment_human_signal_met = $treatmentHumanSignalMet
        treatment_patch_target_met_by_patch_applies = $treatmentPatchTargetMetByApplies
        treatment_patch_target_met_by_emitted_patch_events = $treatmentPatchTargetMetByEvents
        post_patch_target_met = $postPatchTargetMet
        pair_classification = $pairClassification
        comparison_verdict = $comparisonVerdict
        truly_satisfies_grounded_criteria = $rawGroundedCriteriaMet
    }
    current_state = [ordered]@{
        certificate_counts_toward_promotion = $certificateCountsTowardPromotion
        registry_counts_toward_promotion = $registryCountsTowardPromotion
        current_responsive_gate_verdict = $currentResponsiveGate
        current_next_live_objective = $currentNextObjective
    }
    authoritative_conflicts = @([string[]]$authoritativeConflicts.ToArray())
    narrative_contradictions = @([string[]]$narrativeContradictions.ToArray())
    authoritative_artifacts = $authoritativeArtifacts
    potentially_stale_narrative_artifacts = $staleNarrativeArtifacts
    safe_refresh = $safeRefresh
    artifacts = [ordered]@{
        counted_pair_review_json = $outputPaths.JsonPath
        counted_pair_review_markdown = $outputPaths.MarkdownPath
        pair_summary_json = $pairSummaryPath
        grounded_evidence_certificate_json = $certificatePath
        control_to_treatment_switch_json = $controlSwitchPath
        treatment_patch_window_json = $treatmentPatchPath
        conservative_phase_flow_json = $phaseFlowPath
        mission_execution_json = $missionExecutionPath
        mission_snapshot_json = $missionSnapshotPath
        live_monitor_status_json = $liveMonitorStatusPath
        monitor_verdict_history_ndjson = $monitorHistoryPath
        mission_attainment_json = $missionAttainmentPath
        human_participation_conservative_attempt_json = $humanAttemptPath
        first_grounded_conservative_attempt_json = $firstAttemptPath
        final_session_docket_json = $finalDocketPath
        promotion_gap_delta_json = $promotionGapDeltaPath
        session_outcome_dossier_json = $sessionOutcomeDossierPath
        grounded_session_analysis_json = $groundedAnalysisPath
        registry_path = $registryPath
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-ReviewMarkdown -Report $report)

Write-Host "Counted pair review:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Review verdict: $($report.review_verdict)"
Write-Host "  Final counted status: $($report.final_counted_status)"
Write-Host "  Final promotion-counting status: $($report.final_promotion_counting_status)"
Write-Host "  Registry correction recommended: $($report.registry_correction_recommended)"
Write-Host "  Planner/gate recomputation recommended: $($report.planner_gate_recomputation_recommended)"
Write-Host "  Review JSON: $($outputPaths.JsonPath)"
Write-Host "  Review Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    CountedPairReviewJsonPath = $outputPaths.JsonPath
    CountedPairReviewMarkdownPath = $outputPaths.MarkdownPath
    ReviewVerdict = [string]$report.review_verdict
    FinalCountedStatus = [bool]$report.final_counted_status
    FinalPromotionCountingStatus = [bool]$report.final_promotion_counting_status
    RegistryCorrectionRecommended = [bool]$report.registry_correction_recommended
    PlannerGateRecomputationRecommended = [bool]$report.planner_gate_recomputation_recommended
}
