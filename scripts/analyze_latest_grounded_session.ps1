[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$RegistryPath = "",
    [string]$OutputRoot = "",
    [string]$GateConfigPath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "pair_session_certification.ps1")

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

    $records = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $records += ($line | ConvertFrom-Json)
    }

    return $records
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 18
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

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($Path, $false, $encoding)
    try {
        foreach ($record in @($Records)) {
            $writer.WriteLine(($record | ConvertTo-Json -Depth 18 -Compress))
        }
    }
    finally {
        $writer.Dispose()
    }
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
        return $Path
    }

    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        return Join-Path $BasePath $Path
    }

    return Join-Path (Get-RepoRoot) $Path
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Find-LatestPairRoot {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Pairs root was not found: $Root"
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No pair_summary.json files were found under $Root"
    }

    return $candidate.DirectoryName
}

function Get-MatchingRegistryEntries {
    param(
        [object[]]$Entries,
        [string]$ResolvedPairRoot,
        [string]$PairId
    )

    return @(
        $Entries | Where-Object {
            $entryPairRoot = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_root" -Default "")
            $entryPairId = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "")
            $entryPairRoot -eq $ResolvedPairRoot -or
            ((-not [string]::IsNullOrWhiteSpace($PairId)) -and $entryPairId -eq $PairId)
        }
    )
}

function Get-LatestRegistryEntry {
    param([object[]]$Entries)

    return $Entries |
        Sort-Object `
            @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name "registered_at_utc" -Default "") }; Descending = $true }, `
            @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name "pair_run_sort_key" -Default "") }; Descending = $true }, `
            @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "") }; Descending = $true } |
        Select-Object -First 1
}

function Ensure-PairCertificate {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedPairsRoot,
        [string]$ResolvedLabRoot
    )

    $certificateJsonPath = Join-Path $ResolvedPairRoot "grounded_evidence_certificate.json"
    $certificateMarkdownPath = Join-Path $ResolvedPairRoot "grounded_evidence_certificate.md"
    $certificate = Read-JsonFile -Path $certificateJsonPath
    if ($null -ne $certificate) {
        return [ordered]@{
            certificate = $certificate
            certificate_json_path = $certificateJsonPath
            certificate_markdown_path = $certificateMarkdownPath
            certification_reran = $false
        }
    }

    $certifyScriptPath = Join-Path $PSScriptRoot "certify_latest_pair_session.ps1"
    & $certifyScriptPath `
        -PairRoot $ResolvedPairRoot `
        -PairsRoot $ResolvedPairsRoot `
        -LabRoot $ResolvedLabRoot | Out-Null

    $certificate = Read-JsonFile -Path $certificateJsonPath
    if ($null -eq $certificate) {
        throw "Grounded evidence certificate could not be created for pair root: $ResolvedPairRoot"
    }

    return [ordered]@{
        certificate = $certificate
        certificate_json_path = $certificateJsonPath
        certificate_markdown_path = $certificateMarkdownPath
        certification_reran = $true
    }
}

function Materialize-LatestEntry {
    param(
        [string]$ResolvedPairRoot,
        [string]$ScratchRoot
    )

    $registerScriptPath = Join-Path $PSScriptRoot "register_pair_session_result.ps1"
    $scratchOutputRoot = Ensure-Directory -Path $ScratchRoot
    $scratchRegistryPath = Join-Path $scratchOutputRoot "pair_sessions.ndjson"
    Write-NdjsonFile -Path $scratchRegistryPath -Records @()

    & $registerScriptPath -PairRoot $ResolvedPairRoot -RegistryPath $scratchRegistryPath | Out-Null

    $entries = @(Read-NdjsonFile -Path $scratchRegistryPath)
    if ($entries.Count -ne 1) {
        throw "Expected exactly one materialized registry entry for $ResolvedPairRoot, found $($entries.Count)."
    }

    return [ordered]@{
        entry = $entries[0]
        registry_path = $scratchRegistryPath
    }
}

function Invoke-ScenarioPipeline {
    param(
        [string]$ScenarioName,
        [object[]]$Entries,
        [string]$ScenarioRoot,
        [string]$ResolvedGateConfigPath
    )

    $resolvedScenarioRoot = Ensure-Directory -Path $ScenarioRoot
    $scenarioRegistryPath = Join-Path $resolvedScenarioRoot "pair_sessions.ndjson"
    $summaryJsonPath = Join-Path $resolvedScenarioRoot "registry_summary.json"
    $profileJsonPath = Join-Path $resolvedScenarioRoot "profile_recommendation.json"
    $gateJsonPath = Join-Path $resolvedScenarioRoot "responsive_trial_gate.json"
    $planJsonPath = Join-Path $resolvedScenarioRoot "next_live_plan.json"

    Write-NdjsonFile -Path $scenarioRegistryPath -Records $Entries

    $summaryScriptPath = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"
    $gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"
    $planScriptPath = Join-Path $PSScriptRoot "plan_next_live_session.ps1"

    & $summaryScriptPath -RegistryPath $scenarioRegistryPath -OutputRoot $resolvedScenarioRoot | Out-Null
    & $gateScriptPath `
        -RegistryPath $scenarioRegistryPath `
        -OutputRoot $resolvedScenarioRoot `
        -RegistrySummaryPath $summaryJsonPath `
        -ProfileRecommendationPath $profileJsonPath `
        -GateConfigPath $ResolvedGateConfigPath | Out-Null
    & $planScriptPath `
        -RegistryPath $scenarioRegistryPath `
        -OutputRoot $resolvedScenarioRoot `
        -RegistrySummaryPath $summaryJsonPath `
        -ProfileRecommendationPath $profileJsonPath `
        -ResponsiveTrialGatePath $gateJsonPath `
        -GateConfigPath $ResolvedGateConfigPath | Out-Null

    $summary = Read-JsonFile -Path $summaryJsonPath
    $profileRecommendation = Read-JsonFile -Path $profileJsonPath
    $gate = Read-JsonFile -Path $gateJsonPath
    $plan = Read-JsonFile -Path $planJsonPath

    if ($null -eq $summary -or $null -eq $profileRecommendation -or $null -eq $gate -or $null -eq $plan) {
        throw "Scenario '$ScenarioName' did not produce the expected registry summary, gate, and planner artifacts under $resolvedScenarioRoot"
    }

    return [ordered]@{
        name = $ScenarioName
        root = $resolvedScenarioRoot
        registry_path = $scenarioRegistryPath
        summary_json_path = $summaryJsonPath
        profile_recommendation_json_path = $profileJsonPath
        responsive_trial_gate_json_path = $gateJsonPath
        next_live_plan_json_path = $planJsonPath
        summary = $summary
        profile_recommendation = $profileRecommendation
        gate = $gate
        plan = $plan
    }
}

function Get-StateSnapshot {
    param(
        [object]$Summary,
        [object]$ProfileRecommendation,
        [object]$Gate,
        [object]$Plan
    )

    $evidenceGap = Get-ObjectPropertyValue -Object $Plan -Name "evidence_gap" -Default $null

    return [ordered]@{
        total_registered_sessions = [int](Get-ObjectPropertyValue -Object $Summary -Name "total_registered_pair_sessions" -Default 0)
        total_certified_grounded_sessions = [int](Get-ObjectPropertyValue -Object $Summary -Name "total_certified_grounded_sessions" -Default 0)
        latest_registered_pair_id = [string](Get-ObjectPropertyValue -Object $Summary -Name "latest_registered_pair_id" -Default "")
        latest_registered_treatment_profile = [string](Get-ObjectPropertyValue -Object $Summary -Name "latest_registered_treatment_profile" -Default "")
        registry_recommendation_decision = [string](Get-ObjectPropertyValue -Object $ProfileRecommendation -Name "decision" -Default "")
        registry_recommendation_live_profile = [string](Get-ObjectPropertyValue -Object $ProfileRecommendation -Name "recommended_live_profile" -Default "")
        gate_verdict = [string](Get-ObjectPropertyValue -Object $Gate -Name "gate_verdict" -Default "")
        gate_next_live_action = [string](Get-ObjectPropertyValue -Object $Gate -Name "next_live_action" -Default "")
        gate_explanation = [string](Get-ObjectPropertyValue -Object $Gate -Name "explanation" -Default "")
        recommended_next_live_profile = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_live_profile" -Default "")
        recommended_next_session_objective = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_session_objective" -Default "")
        plan_explanation = [string](Get-ObjectPropertyValue -Object $Plan -Name "explanation" -Default "")
        grounded_sessions_current = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_sessions_current" -Default 0)
        grounded_sessions_missing = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_sessions_missing" -Default 0)
        grounded_too_quiet_current = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_too_quiet_current" -Default 0)
        grounded_too_quiet_missing = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_too_quiet_missing" -Default 0)
        grounded_too_quiet_distinct_pair_ids_current = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_too_quiet_distinct_pair_ids_current" -Default 0)
        grounded_too_quiet_distinct_pair_ids_missing = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_too_quiet_distinct_pair_ids_missing" -Default 0)
        strong_signal_current = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "strong_signal_current" -Default 0)
        strong_signal_missing = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "strong_signal_missing" -Default 0)
        responsive_overreaction_blockers_current = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "responsive_overreaction_blockers_current" -Default 0)
        grounded_appropriate_current = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_appropriate_current" -Default 0)
        grounded_appropriate_excess = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "grounded_appropriate_excess" -Default 0)
        workflow_validation_only_sessions_count = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "workflow_validation_only_sessions_count" -Default 0)
        weak_or_insufficient_sessions_count = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "weak_or_insufficient_sessions_count" -Default 0)
        non_certified_live_sessions_count = [int](Get-ObjectPropertyValue -Object $evidenceGap -Name "non_certified_live_sessions_count" -Default 0)
        missing_evidence = @((Get-ObjectPropertyValue -Object $Gate -Name "missing_evidence" -Default @()))
        deficits_remaining_descriptions = @((Get-ObjectPropertyValue -Object $Plan -Name "deficits_remaining_descriptions" -Default @()))
    }
}

function Get-ManualReviewState {
    param([object]$Snapshot)

    return (
        $Snapshot.gate_verdict -eq "manual-review-needed" -or
        $Snapshot.gate_next_live_action -eq "manual-review-needed" -or
        $Snapshot.registry_recommendation_decision -eq "manual-review-needed" -or
        $Snapshot.recommended_next_session_objective -eq "manual-review-before-next-session"
    )
}

function Get-ImpactClassification {
    param(
        [bool]$CountsTowardPromotion,
        [bool]$ResponsiveBlockerAdded,
        [bool]$ManualReviewIntroduced,
        [bool]$TooQuietEvidenceAdded,
        [bool]$StrongSignalAdded,
        [bool]$FirstGroundedConservativeSession,
        [bool]$PromotionGapReduced
    )

    if (-not $CountsTowardPromotion) {
        return "no-impact-non-grounded-session"
    }

    if ($ResponsiveBlockerAdded) {
        return "responsive-blocker-added"
    }

    if ($ManualReviewIntroduced) {
        return "manual-review-needed"
    }

    if ($TooQuietEvidenceAdded) {
        return "grounded-conservative-too-quiet-evidence-added"
    }

    if ($StrongSignalAdded) {
        return "grounded-strong-signal-conservative-added"
    }

    if ($FirstGroundedConservativeSession) {
        return "first-grounded-conservative-session"
    }

    if ($PromotionGapReduced) {
        return "grounded-conservative-session-gap-reduced"
    }

    return "no-material-gap-change"
}

function Get-ImpactExplanation {
    param(
        [object]$LatestEntry,
        [object]$Certificate,
        [object]$BeforeSnapshot,
        [object]$AfterSnapshot,
        [object]$Delta
    )

    if (-not $Delta.counts_toward_promotion) {
        return ("The latest pair is {0} evidence with certification verdict '{1}', so it stays visible but does not count toward responsive-promotion thresholds. " +
            "The responsive gap stays at grounded sessions {2}->{3}, grounded too-quiet {4}->{5}, and the next objective stays '{6}'.") -f `
            $Delta.evidence_origin,
            $Delta.certification_verdict,
            $BeforeSnapshot.grounded_sessions_current,
            $AfterSnapshot.grounded_sessions_current,
            $BeforeSnapshot.grounded_too_quiet_current,
            $AfterSnapshot.grounded_too_quiet_current,
            $AfterSnapshot.recommended_next_session_objective
    }

    $parts = @("The latest pair counts as certified grounded evidence.")

    if ($Delta.reduced_promotion_gap) {
        $parts += "It reduced the responsive-promotion gap in: " + ($Delta.reduced_promotion_gap_components -join ", ") + "."
    }
    else {
        $parts += "It did not reduce the responsive-opening deficits."
    }

    if ($Delta.contributed_grounded_conservative_too_quiet_evidence) {
        $parts += "It added grounded conservative too-quiet evidence."
    }

    if ($Delta.strong_signal_delta -gt 0) {
        $parts += "It added grounded conservative strong-signal evidence."
    }

    if ($Delta.responsive_overreaction_blockers_delta -gt 0) {
        $parts += "It added grounded responsive too-reactive blocker evidence."
    }

    if ($Delta.moved_next_objective) {
        $parts += ("The next objective moved from '{0}' to '{1}'." -f `
            $BeforeSnapshot.recommended_next_session_objective,
            $AfterSnapshot.recommended_next_session_objective)
    }
    else {
        $parts += ("The next objective stays '{0}'." -f $AfterSnapshot.recommended_next_session_objective)
    }

    if ($Delta.responsive_gate_changed) {
        $parts += ("The responsive gate changed from '{0}/{1}' to '{2}/{3}'." -f `
            $BeforeSnapshot.gate_verdict,
            $BeforeSnapshot.gate_next_live_action,
            $AfterSnapshot.gate_verdict,
            $AfterSnapshot.gate_next_live_action)
    }
    else {
        $parts += ("The responsive gate remains '{0}/{1}'." -f `
            $AfterSnapshot.gate_verdict,
            $AfterSnapshot.gate_next_live_action)
    }

    return ($parts -join " ")
}

function Get-AnalysisMarkdown {
    param(
        [object]$Analysis,
        [object]$Delta
    )

    $withoutLatest = $Analysis.without_latest.snapshot
    $withLatest = $Analysis.with_latest.snapshot
    $reducedGapComponents = @($Delta.reduced_promotion_gap_components)
    $nonPromotionGapComponents = @($Delta.non_promotion_gap_components)

    $lines = @(
        "# Latest Grounded Session Analysis",
        "",
        "- Pair root: $($Analysis.pair_root)",
        "- Pair ID: $($Analysis.pair_id)",
        "- Pair selection: $($Analysis.selection_mode)",
        "- Registry path: $($Analysis.registry_path)",
        "- Analysis output root: $($Analysis.output_root)",
        "- Current registry already included latest pair: $($Analysis.current_registry_already_included_latest_pair)",
        "- Matching registry entries for this pair: $($Analysis.current_registry_matching_entry_count)",
        "",
        "## Latest Session",
        "",
        "- Treatment profile: $($Analysis.latest_session.treatment_profile)",
        "- Evidence origin: $($Analysis.latest_session.evidence_origin)",
        "- Pair classification: $($Analysis.latest_session.pair_classification)",
        "- Comparison verdict: $($Analysis.latest_session.comparison_verdict)",
        "- Evidence bucket: $($Analysis.latest_session.evidence_bucket)",
        "- Scorecard recommendation: $($Analysis.latest_session.scorecard_recommendation)",
        "- Treatment behavior assessment: $($Analysis.latest_session.treatment_behavior_assessment)",
        "- Shadow recommendation: $($Analysis.latest_session.shadow_recommendation_decision)",
        "",
        "## Grounded Certification",
        "",
        "- Certification verdict: $($Delta.certification_verdict)",
        "- Counts toward promotion: $($Delta.counts_toward_promotion)",
        "- Counts only as workflow validation: $($Analysis.latest_session.counts_only_as_workflow_validation)",
        "- Certification explanation: $($Analysis.latest_session.certification_explanation)",
        "",
        "## Impact",
        "",
        "- Impact classification: $($Delta.impact_classification)",
        "- Reduced promotion gap: $($Delta.reduced_promotion_gap)",
        "- Contributed grounded conservative too-quiet evidence: $($Delta.contributed_grounded_conservative_too_quiet_evidence)",
        "- Created first grounded conservative session: $($Delta.created_first_grounded_conservative_session)",
        "- Created first grounded conservative too-quiet session: $($Delta.created_first_grounded_conservative_too_quiet_session)",
        "- Created first grounded conservative strong-signal session: $($Delta.created_first_grounded_conservative_strong_signal_session)",
        "- Responsive blocker added: $($Delta.responsive_blocker_added)",
        "- Next-step recommendation changed: $($Delta.next_step_recommendation_changed)",
        "- Next objective moved: $($Delta.moved_next_objective)",
        "- Responsive gate changed: $($Delta.responsive_gate_changed)",
        "- Same blocked state after latest pair: $($Delta.same_blocked_state)",
        "- Explanation: $($Delta.explanation)",
        "",
        "## Before Vs After",
        "",
        "- Grounded conservative sessions: $($withoutLatest.grounded_sessions_current) -> $($withLatest.grounded_sessions_current) (delta $($Delta.grounded_sessions_delta))",
        "- Grounded conservative too-quiet sessions: $($withoutLatest.grounded_too_quiet_current) -> $($withLatest.grounded_too_quiet_current) (delta $($Delta.grounded_too_quiet_delta))",
        "- Distinct grounded too-quiet pair IDs: $($withoutLatest.grounded_too_quiet_distinct_pair_ids_current) -> $($withLatest.grounded_too_quiet_distinct_pair_ids_current) (delta $($Delta.grounded_too_quiet_distinct_pair_ids_delta))",
        "- Grounded conservative strong-signal sessions: $($withoutLatest.strong_signal_current) -> $($withLatest.strong_signal_current) (delta $($Delta.strong_signal_delta))",
        "- Responsive overreaction blockers: $($withoutLatest.responsive_overreaction_blockers_current) -> $($withLatest.responsive_overreaction_blockers_current) (delta $($Delta.responsive_overreaction_blockers_delta))",
        "- Gate verdict: $($withoutLatest.gate_verdict) / $($withoutLatest.gate_next_live_action) -> $($withLatest.gate_verdict) / $($withLatest.gate_next_live_action)",
        "- Registry recommendation: $($withoutLatest.registry_recommendation_decision) -> $($withLatest.registry_recommendation_decision)",
        "- Recommended next live profile: $($withoutLatest.recommended_next_live_profile) -> $($withLatest.recommended_next_live_profile)",
        "- Recommended next session objective: $($withoutLatest.recommended_next_session_objective) -> $($withLatest.recommended_next_session_objective)"
    )

    if ($reducedGapComponents.Count -gt 0) {
        $lines += @(
            "",
            "## Promotion Gap Components Reduced",
            ""
        )
        foreach ($component in $reducedGapComponents) {
            $lines += "- $component"
        }
    }

    if ($nonPromotionGapComponents.Count -gt 0) {
        $lines += @(
            "",
            "## Other Evidence Changes",
            ""
        )
        foreach ($component in $nonPromotionGapComponents) {
            $lines += "- $component"
        }
    }

    $lines += @(
        "",
        "## Scenario Artifacts",
        "",
        "- Without latest session counted: $($Analysis.without_latest.root)",
        "- With latest session counted: $($Analysis.with_latest.root)",
        "- Certificate JSON: $($Analysis.artifacts.grounded_evidence_certificate_json)",
        "- Delta JSON: $($Analysis.artifacts.promotion_gap_delta_json)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-PromotionGapDeltaMarkdown {
    param([object]$Delta)

    $lines = @(
        "# Promotion Gap Delta",
        "",
        "- Pair root: $($Delta.pair_root)",
        "- Pair ID: $($Delta.pair_id)",
        "- Evidence origin: $($Delta.evidence_origin)",
        "- Certification verdict: $($Delta.certification_verdict)",
        "- Counts toward promotion: $($Delta.counts_toward_promotion)",
        "- Impact classification: $($Delta.impact_classification)",
        "- Reduced promotion gap: $($Delta.reduced_promotion_gap)",
        "- Grounded sessions: $($Delta.grounded_sessions_before) -> $($Delta.grounded_sessions_after) (delta $($Delta.grounded_sessions_delta))",
        "- Grounded too-quiet: $($Delta.grounded_too_quiet_before) -> $($Delta.grounded_too_quiet_after) (delta $($Delta.grounded_too_quiet_delta))",
        "- Distinct grounded too-quiet pair IDs: $($Delta.grounded_too_quiet_distinct_pair_ids_before) -> $($Delta.grounded_too_quiet_distinct_pair_ids_after) (delta $($Delta.grounded_too_quiet_distinct_pair_ids_delta))",
        "- Strong-signal: $($Delta.strong_signal_before) -> $($Delta.strong_signal_after) (delta $($Delta.strong_signal_delta))",
        "- Responsive overreaction blockers: $($Delta.responsive_overreaction_blockers_before) -> $($Delta.responsive_overreaction_blockers_after) (delta $($Delta.responsive_overreaction_blockers_delta))",
        "- Gate: $($Delta.responsive_gate_before.gate_verdict) / $($Delta.responsive_gate_before.next_live_action) -> $($Delta.responsive_gate_after.gate_verdict) / $($Delta.responsive_gate_after.next_live_action)",
        "- Next objective: $($Delta.next_objective_before) -> $($Delta.next_objective_after)",
        "- Recommended live profile: $($Delta.next_live_profile_before) -> $($Delta.next_live_profile_after)",
        "- Explanation: $($Delta.explanation)"
    )

    if (@($Delta.reduced_promotion_gap_components).Count -gt 0) {
        $lines += @(
            "",
            "## Reduced Components",
            ""
        )
        foreach ($component in @($Delta.reduced_promotion_gap_components)) {
            $lines += "- $component"
        }
    }

    if (@($Delta.non_promotion_gap_components).Count -gt 0) {
        $lines += @(
            "",
            "## Other Evidence Changes",
            ""
        )
        foreach ($component in @($Delta.non_promotion_gap_components)) {
            $lines += "- $component"
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Get-LabRootDefault
}
else {
    Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot
}

$resolvedPairsRoot = if ([string]::IsNullOrWhiteSpace($PairsRoot)) {
    Get-PairsRootDefault -LabRoot $resolvedLabRoot
}
else {
    Get-AbsolutePath -Path $PairsRoot -BasePath $repoRoot
}

$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}

$resolvedPairRoot = if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    Find-LatestPairRoot -Root $resolvedPairsRoot
}
else {
    Resolve-ExistingPath -Path (Get-AbsolutePath -Path $PairRoot -BasePath $repoRoot)
}

if ([string]::IsNullOrWhiteSpace($resolvedPairRoot)) {
    throw "Pair root was not found: $PairRoot"
}

$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
if (-not $pairSummaryPath) {
    throw "Pair summary JSON was not found under $resolvedPairRoot"
}

$pairSummary = Read-JsonFile -Path $pairSummaryPath
if ($null -eq $pairSummary) {
    throw "Pair summary JSON could not be parsed: $pairSummaryPath"
}

$pairId = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default (Split-Path -Path $resolvedPairRoot -Leaf))
$pairSummaryEvidenceOrigin = Get-PairSessionResolvedEvidenceOrigin `
    -EvidenceOrigin ([string](Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default "")) `
    -RehearsalMode ([bool](Get-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Default $false)) `
    -Synthetic ([bool](Get-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Default $false)) `
    -ValidationOnly ([bool](Get-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Default $false))
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path $resolvedPairRoot
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}

$resolvedGateConfigPath = if ([string]::IsNullOrWhiteSpace($GateConfigPath)) {
    Join-Path $repoRoot "ai_director\testdata\responsive_trial_gate.json"
}
else {
    Get-AbsolutePath -Path $GateConfigPath -BasePath $repoRoot
}

$currentEntries = @(Read-NdjsonFile -Path $resolvedRegistryPath)
$matchingEntries = @(Get-MatchingRegistryEntries -Entries $currentEntries -ResolvedPairRoot $resolvedPairRoot -PairId $pairId)
$certificateInfo = Ensure-PairCertificate `
    -ResolvedPairRoot $resolvedPairRoot `
    -ResolvedPairsRoot $resolvedPairsRoot `
    -ResolvedLabRoot $resolvedLabRoot

$latestEntry = $null
if ($matchingEntries.Count -gt 0) {
    $latestEntry = Get-LatestRegistryEntry -Entries $matchingEntries
}
else {
    $materialized = Materialize-LatestEntry `
        -ResolvedPairRoot $resolvedPairRoot `
        -ScratchRoot (Join-Path $resolvedOutputRoot "analysis_scenarios\materialized_latest")
    $latestEntry = $materialized.entry
}

if ($null -eq $latestEntry) {
    throw "A registry-style entry could not be resolved for pair root: $resolvedPairRoot"
}

$baseEntries = @(
    $currentEntries | Where-Object {
        $entryPairRoot = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_root" -Default "")
        $entryPairId = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "")
        -not ($entryPairRoot -eq $resolvedPairRoot -or $entryPairId -eq $pairId)
    }
)

$withoutLatestScenario = Invoke-ScenarioPipeline `
    -ScenarioName "without_latest" `
    -Entries $baseEntries `
    -ScenarioRoot (Join-Path $resolvedOutputRoot "analysis_scenarios\without_latest") `
    -ResolvedGateConfigPath $resolvedGateConfigPath

$withLatestEntries = @($baseEntries + $latestEntry)
$withLatestScenario = Invoke-ScenarioPipeline `
    -ScenarioName "with_latest" `
    -Entries $withLatestEntries `
    -ScenarioRoot (Join-Path $resolvedOutputRoot "analysis_scenarios\with_latest") `
    -ResolvedGateConfigPath $resolvedGateConfigPath

$withoutLatestSnapshot = Get-StateSnapshot `
    -Summary $withoutLatestScenario.summary `
    -ProfileRecommendation $withoutLatestScenario.profile_recommendation `
    -Gate $withoutLatestScenario.gate `
    -Plan $withoutLatestScenario.plan
$withLatestSnapshot = Get-StateSnapshot `
    -Summary $withLatestScenario.summary `
    -ProfileRecommendation $withLatestScenario.profile_recommendation `
    -Gate $withLatestScenario.gate `
    -Plan $withLatestScenario.plan

$reducedPromotionGapComponents = @()
if ($withLatestSnapshot.grounded_sessions_missing -lt $withoutLatestSnapshot.grounded_sessions_missing) {
    $reducedPromotionGapComponents += "grounded-conservative-sessions-missing"
}
if ($withLatestSnapshot.grounded_too_quiet_missing -lt $withoutLatestSnapshot.grounded_too_quiet_missing) {
    $reducedPromotionGapComponents += "grounded-conservative-too-quiet-missing"
}
if ($withLatestSnapshot.grounded_too_quiet_distinct_pair_ids_missing -lt $withoutLatestSnapshot.grounded_too_quiet_distinct_pair_ids_missing) {
    $reducedPromotionGapComponents += "grounded-conservative-too-quiet-distinct-pair-ids-missing"
}
if ($withLatestSnapshot.grounded_appropriate_excess -lt $withoutLatestSnapshot.grounded_appropriate_excess) {
    $reducedPromotionGapComponents += "grounded-conservative-appropriate-excess"
}

$nonPromotionGapComponents = @()
if ($withLatestSnapshot.strong_signal_missing -lt $withoutLatestSnapshot.strong_signal_missing) {
    $nonPromotionGapComponents += "grounded-conservative-strong-signal-missing"
}

$groundedSessionsDelta = $withLatestSnapshot.grounded_sessions_current - $withoutLatestSnapshot.grounded_sessions_current
$groundedTooQuietDelta = $withLatestSnapshot.grounded_too_quiet_current - $withoutLatestSnapshot.grounded_too_quiet_current
$groundedTooQuietDistinctPairIdsDelta = $withLatestSnapshot.grounded_too_quiet_distinct_pair_ids_current - $withoutLatestSnapshot.grounded_too_quiet_distinct_pair_ids_current
$strongSignalDelta = $withLatestSnapshot.strong_signal_current - $withoutLatestSnapshot.strong_signal_current
$responsiveOverreactionBlockersDelta = $withLatestSnapshot.responsive_overreaction_blockers_current - $withoutLatestSnapshot.responsive_overreaction_blockers_current
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $latestEntry -Name "counts_toward_promotion" -Default $false)
$movedNextObjective = $withoutLatestSnapshot.recommended_next_session_objective -ne $withLatestSnapshot.recommended_next_session_objective
$responsiveGateChanged = (
    $withoutLatestSnapshot.gate_verdict -ne $withLatestSnapshot.gate_verdict -or
    $withoutLatestSnapshot.gate_next_live_action -ne $withLatestSnapshot.gate_next_live_action
)
$nextStepRecommendationChanged = (
    $movedNextObjective -or
    $withoutLatestSnapshot.registry_recommendation_decision -ne $withLatestSnapshot.registry_recommendation_decision -or
    $withoutLatestSnapshot.registry_recommendation_live_profile -ne $withLatestSnapshot.registry_recommendation_live_profile -or
    $withoutLatestSnapshot.recommended_next_live_profile -ne $withLatestSnapshot.recommended_next_live_profile
)
$responsiveBlockerAdded = $responsiveOverreactionBlockersDelta -gt 0
$promotionGapReduced = $countsTowardPromotion -and $reducedPromotionGapComponents.Count -gt 0
$tooQuietEvidenceAdded = $countsTowardPromotion -and $groundedTooQuietDelta -gt 0
$strongSignalAdded = $countsTowardPromotion -and $strongSignalDelta -gt 0
$firstGroundedConservativeSession = $countsTowardPromotion -and $withoutLatestSnapshot.grounded_sessions_current -eq 0 -and $withLatestSnapshot.grounded_sessions_current -gt 0
$firstGroundedConservativeTooQuietSession = $countsTowardPromotion -and $withoutLatestSnapshot.grounded_too_quiet_current -eq 0 -and $withLatestSnapshot.grounded_too_quiet_current -gt 0
$firstGroundedConservativeStrongSignalSession = $countsTowardPromotion -and $withoutLatestSnapshot.strong_signal_current -eq 0 -and $withLatestSnapshot.strong_signal_current -gt 0
$manualReviewIntroduced = (Get-ManualReviewState -Snapshot $withLatestSnapshot) -and -not (Get-ManualReviewState -Snapshot $withoutLatestSnapshot)
$impactClassification = Get-ImpactClassification `
    -CountsTowardPromotion $countsTowardPromotion `
    -ResponsiveBlockerAdded $responsiveBlockerAdded `
    -ManualReviewIntroduced $manualReviewIntroduced `
    -TooQuietEvidenceAdded $tooQuietEvidenceAdded `
    -StrongSignalAdded $strongSignalAdded `
    -FirstGroundedConservativeSession $firstGroundedConservativeSession `
    -PromotionGapReduced $promotionGapReduced

$sameBlockedState = (
    -not $promotionGapReduced -and
    -not $tooQuietEvidenceAdded -and
    -not $strongSignalAdded -and
    -not $responsiveBlockerAdded -and
    -not $nextStepRecommendationChanged -and
    -not $responsiveGateChanged
)

$latestEvidenceOrigin = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $certificateInfo.certificate -Name "evidence_origin" -Default $pairSummaryEvidenceOrigin))
$latestCertificationVerdict = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "grounded_evidence_certification_verdict" -Default (Get-ObjectPropertyValue -Object $certificateInfo.certificate -Name "certification_verdict" -Default ""))
$latestCertificationExplanation = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "grounded_evidence_explanation" -Default (Get-ObjectPropertyValue -Object $certificateInfo.certificate -Name "explanation" -Default ""))

$promotionGapDelta = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pair_root = $resolvedPairRoot
    pair_id = $pairId
    evidence_origin = $latestEvidenceOrigin
    certification_verdict = $latestCertificationVerdict
    counts_toward_promotion = $countsTowardPromotion
    impact_classification = $impactClassification
    reduced_promotion_gap = $promotionGapReduced
    reduced_promotion_gap_components = $reducedPromotionGapComponents
    non_promotion_gap_components = $nonPromotionGapComponents
    contributed_grounded_conservative_too_quiet_evidence = $tooQuietEvidenceAdded
    created_first_grounded_conservative_session = $firstGroundedConservativeSession
    created_first_grounded_conservative_too_quiet_session = $firstGroundedConservativeTooQuietSession
    created_first_grounded_conservative_strong_signal_session = $firstGroundedConservativeStrongSignalSession
    responsive_blocker_added = $responsiveBlockerAdded
    moved_next_objective = $movedNextObjective
    next_step_recommendation_changed = $nextStepRecommendationChanged
    responsive_gate_changed = $responsiveGateChanged
    same_blocked_state = $sameBlockedState
    grounded_sessions_before = $withoutLatestSnapshot.grounded_sessions_current
    grounded_sessions_after = $withLatestSnapshot.grounded_sessions_current
    grounded_sessions_delta = $groundedSessionsDelta
    grounded_sessions_missing_before = $withoutLatestSnapshot.grounded_sessions_missing
    grounded_sessions_missing_after = $withLatestSnapshot.grounded_sessions_missing
    grounded_sessions_missing_delta = $withLatestSnapshot.grounded_sessions_missing - $withoutLatestSnapshot.grounded_sessions_missing
    grounded_too_quiet_before = $withoutLatestSnapshot.grounded_too_quiet_current
    grounded_too_quiet_after = $withLatestSnapshot.grounded_too_quiet_current
    grounded_too_quiet_delta = $groundedTooQuietDelta
    grounded_too_quiet_missing_before = $withoutLatestSnapshot.grounded_too_quiet_missing
    grounded_too_quiet_missing_after = $withLatestSnapshot.grounded_too_quiet_missing
    grounded_too_quiet_missing_delta = $withLatestSnapshot.grounded_too_quiet_missing - $withoutLatestSnapshot.grounded_too_quiet_missing
    grounded_too_quiet_distinct_pair_ids_before = $withoutLatestSnapshot.grounded_too_quiet_distinct_pair_ids_current
    grounded_too_quiet_distinct_pair_ids_after = $withLatestSnapshot.grounded_too_quiet_distinct_pair_ids_current
    grounded_too_quiet_distinct_pair_ids_delta = $groundedTooQuietDistinctPairIdsDelta
    grounded_too_quiet_distinct_pair_ids_missing_before = $withoutLatestSnapshot.grounded_too_quiet_distinct_pair_ids_missing
    grounded_too_quiet_distinct_pair_ids_missing_after = $withLatestSnapshot.grounded_too_quiet_distinct_pair_ids_missing
    grounded_too_quiet_distinct_pair_ids_missing_delta = $withLatestSnapshot.grounded_too_quiet_distinct_pair_ids_missing - $withoutLatestSnapshot.grounded_too_quiet_distinct_pair_ids_missing
    strong_signal_before = $withoutLatestSnapshot.strong_signal_current
    strong_signal_after = $withLatestSnapshot.strong_signal_current
    strong_signal_delta = $strongSignalDelta
    strong_signal_missing_before = $withoutLatestSnapshot.strong_signal_missing
    strong_signal_missing_after = $withLatestSnapshot.strong_signal_missing
    strong_signal_missing_delta = $withLatestSnapshot.strong_signal_missing - $withoutLatestSnapshot.strong_signal_missing
    responsive_overreaction_blockers_before = $withoutLatestSnapshot.responsive_overreaction_blockers_current
    responsive_overreaction_blockers_after = $withLatestSnapshot.responsive_overreaction_blockers_current
    responsive_overreaction_blockers_delta = $responsiveOverreactionBlockersDelta
    responsive_gate_before = [ordered]@{
        gate_verdict = $withoutLatestSnapshot.gate_verdict
        next_live_action = $withoutLatestSnapshot.gate_next_live_action
    }
    responsive_gate_after = [ordered]@{
        gate_verdict = $withLatestSnapshot.gate_verdict
        next_live_action = $withLatestSnapshot.gate_next_live_action
    }
    registry_recommendation_before = $withoutLatestSnapshot.registry_recommendation_decision
    registry_recommendation_after = $withLatestSnapshot.registry_recommendation_decision
    next_live_profile_before = $withoutLatestSnapshot.recommended_next_live_profile
    next_live_profile_after = $withLatestSnapshot.recommended_next_live_profile
    next_objective_before = $withoutLatestSnapshot.recommended_next_session_objective
    next_objective_after = $withLatestSnapshot.recommended_next_session_objective
}

$promotionGapDelta["explanation"] = Get-ImpactExplanation `
    -LatestEntry $latestEntry `
    -Certificate $certificateInfo.certificate `
    -BeforeSnapshot $withoutLatestSnapshot `
    -AfterSnapshot $withLatestSnapshot `
    -Delta $promotionGapDelta

$groundedSessionAnalysisJsonPath = Join-Path $resolvedOutputRoot "grounded_session_analysis.json"
$groundedSessionAnalysisMarkdownPath = Join-Path $resolvedOutputRoot "grounded_session_analysis.md"
$promotionGapDeltaJsonPath = Join-Path $resolvedOutputRoot "promotion_gap_delta.json"
$promotionGapDeltaMarkdownPath = Join-Path $resolvedOutputRoot "promotion_gap_delta.md"

$groundedSessionAnalysis = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    selection_mode = if ([string]::IsNullOrWhiteSpace($PairRoot)) { "latest-pair-pack" } else { "explicit-pair-root" }
    pair_root = $resolvedPairRoot
    pair_id = $pairId
    registry_path = $resolvedRegistryPath
    output_root = $resolvedOutputRoot
    current_registry_already_included_latest_pair = $matchingEntries.Count -gt 0
    current_registry_matching_entry_count = $matchingEntries.Count
    latest_session = [ordered]@{
        pair_root = $resolvedPairRoot
        pair_id = $pairId
        treatment_profile = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "treatment_profile" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default ""))
        evidence_origin = $latestEvidenceOrigin
        pair_classification = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "pair_classification" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default ""))
        comparison_verdict = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "comparison_verdict" -Default "")
        evidence_bucket = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "evidence_bucket" -Default "")
        scorecard_recommendation = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "scorecard_recommendation" -Default "")
        treatment_behavior_assessment = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "scorecard_treatment_behavior_assessment" -Default "")
        shadow_recommendation_decision = [string](Get-ObjectPropertyValue -Object $latestEntry -Name "shadow_recommendation_decision" -Default "")
        certification_verdict = $latestCertificationVerdict
        counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $latestEntry -Name "counts_toward_promotion" -Default $false)
        counts_only_as_workflow_validation = [bool](Get-ObjectPropertyValue -Object $latestEntry -Name "counts_only_as_workflow_validation" -Default $false)
        certification_explanation = $latestCertificationExplanation
        certification_reran = $certificateInfo.certification_reran
    }
    without_latest = [ordered]@{
        root = $withoutLatestScenario.root
        registry_path = $withoutLatestScenario.registry_path
        summary_json_path = $withoutLatestScenario.summary_json_path
        profile_recommendation_json_path = $withoutLatestScenario.profile_recommendation_json_path
        responsive_trial_gate_json_path = $withoutLatestScenario.responsive_trial_gate_json_path
        next_live_plan_json_path = $withoutLatestScenario.next_live_plan_json_path
        snapshot = $withoutLatestSnapshot
    }
    with_latest = [ordered]@{
        root = $withLatestScenario.root
        registry_path = $withLatestScenario.registry_path
        summary_json_path = $withLatestScenario.summary_json_path
        profile_recommendation_json_path = $withLatestScenario.profile_recommendation_json_path
        responsive_trial_gate_json_path = $withLatestScenario.responsive_trial_gate_json_path
        next_live_plan_json_path = $withLatestScenario.next_live_plan_json_path
        snapshot = $withLatestSnapshot
    }
    impact = $promotionGapDelta
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryPath
        grounded_evidence_certificate_json = $certificateInfo.certificate_json_path
        grounded_evidence_certificate_markdown = $certificateInfo.certificate_markdown_path
        grounded_session_analysis_json = $groundedSessionAnalysisJsonPath
        grounded_session_analysis_markdown = $groundedSessionAnalysisMarkdownPath
        promotion_gap_delta_json = $promotionGapDeltaJsonPath
        promotion_gap_delta_markdown = $promotionGapDeltaMarkdownPath
    }
}

Write-JsonFile -Path $promotionGapDeltaJsonPath -Value $promotionGapDelta
Write-TextFile -Path $promotionGapDeltaMarkdownPath -Value (Get-PromotionGapDeltaMarkdown -Delta $promotionGapDelta)
Write-JsonFile -Path $groundedSessionAnalysisJsonPath -Value $groundedSessionAnalysis
Write-TextFile -Path $groundedSessionAnalysisMarkdownPath -Value (Get-AnalysisMarkdown -Analysis $groundedSessionAnalysis -Delta $promotionGapDelta)

Write-Host "Latest grounded-session analysis:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Analysis JSON: $groundedSessionAnalysisJsonPath"
Write-Host "  Analysis Markdown: $groundedSessionAnalysisMarkdownPath"
Write-Host "  Delta JSON: $promotionGapDeltaJsonPath"
Write-Host "  Delta Markdown: $promotionGapDeltaMarkdownPath"
Write-Host "  Impact classification: $impactClassification"
Write-Host "  Counts toward promotion: $countsTowardPromotion"
Write-Host "  Reduced promotion gap: $promotionGapReduced"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    RegistryPath = $resolvedRegistryPath
    GroundedSessionAnalysisJsonPath = $groundedSessionAnalysisJsonPath
    GroundedSessionAnalysisMarkdownPath = $groundedSessionAnalysisMarkdownPath
    PromotionGapDeltaJsonPath = $promotionGapDeltaJsonPath
    PromotionGapDeltaMarkdownPath = $promotionGapDeltaMarkdownPath
    ImpactClassification = $impactClassification
    CountsTowardPromotion = $countsTowardPromotion
    ReducedPromotionGap = $promotionGapReduced
}
