[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$RegistryPath = "",
    [string]$OutputJson = "",
    [string]$OutputMarkdown = ""
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

    $json = $Value | ConvertTo-Json -Depth 20
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

function Invoke-HelperScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    & $ScriptPath @Arguments | Out-Null
}

function Get-PreferredCommitSha {
    param(
        [object]$PairSummary,
        [object]$Scorecard,
        [object]$Certificate,
        [object]$GuidedDocket
    )

    foreach ($candidate in @(
        [string](Get-ObjectPropertyValue -Object $PairSummary -Name "source_commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $Scorecard -Name "commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $Scorecard -Name "source_pair_commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $Certificate -Name "source_commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $GuidedDocket -Name "source_commit_sha" -Default ""),
        (Get-RepoHeadCommitSha)
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

function Get-PromotionGapDeltaSummary {
    param([object]$Delta)

    return [ordered]@{
        reduced_promotion_gap = [bool](Get-ObjectPropertyValue -Object $Delta -Name "reduced_promotion_gap" -Default $false)
        reduced_promotion_gap_components = @((Get-ObjectPropertyValue -Object $Delta -Name "reduced_promotion_gap_components" -Default @()))
        non_promotion_gap_components = @((Get-ObjectPropertyValue -Object $Delta -Name "non_promotion_gap_components" -Default @()))
        grounded_sessions_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_sessions_delta" -Default 0)
        grounded_too_quiet_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_too_quiet_delta" -Default 0)
        grounded_too_quiet_distinct_pair_ids_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_too_quiet_distinct_pair_ids_delta" -Default 0)
        strong_signal_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "strong_signal_delta" -Default 0)
        responsive_overreaction_blockers_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "responsive_overreaction_blockers_delta" -Default 0)
    }
}

function Get-WhatChangedBecauseOfThisSession {
    param(
        [object]$Certificate,
        [object]$Delta
    )

    return [ordered]@{
        grounded_sessions_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_sessions_delta" -Default 0)
        grounded_too_quiet_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_too_quiet_delta" -Default 0)
        grounded_too_quiet_distinct_pair_ids_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_too_quiet_distinct_pair_ids_delta" -Default 0)
        strong_signal_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "strong_signal_delta" -Default 0)
        responsive_overreaction_blockers_delta = [int](Get-ObjectPropertyValue -Object $Delta -Name "responsive_overreaction_blockers_delta" -Default 0)
        changed_next_objective = [bool](Get-ObjectPropertyValue -Object $Delta -Name "moved_next_objective" -Default $false)
        changed_next_step_recommendation = [bool](Get-ObjectPropertyValue -Object $Delta -Name "next_step_recommendation_changed" -Default $false)
        changed_responsive_gate = [bool](Get-ObjectPropertyValue -Object $Delta -Name "responsive_gate_changed" -Default $false)
        reduced_promotion_gap = [bool](Get-ObjectPropertyValue -Object $Delta -Name "reduced_promotion_gap" -Default $false)
        same_blocked_state = [bool](Get-ObjectPropertyValue -Object $Delta -Name "same_blocked_state" -Default $false)
        workflow_validation_only = [bool](Get-ObjectPropertyValue -Object $Certificate -Name "counts_only_as_workflow_validation" -Default $false)
        materially_changed_anything = (
            [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_sessions_delta" -Default 0) -ne 0 -or
            [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_too_quiet_delta" -Default 0) -ne 0 -or
            [int](Get-ObjectPropertyValue -Object $Delta -Name "grounded_too_quiet_distinct_pair_ids_delta" -Default 0) -ne 0 -or
            [int](Get-ObjectPropertyValue -Object $Delta -Name "strong_signal_delta" -Default 0) -ne 0 -or
            [int](Get-ObjectPropertyValue -Object $Delta -Name "responsive_overreaction_blockers_delta" -Default 0) -ne 0 -or
            [bool](Get-ObjectPropertyValue -Object $Delta -Name "moved_next_objective" -Default $false) -or
            [bool](Get-ObjectPropertyValue -Object $Delta -Name "next_step_recommendation_changed" -Default $false) -or
            [bool](Get-ObjectPropertyValue -Object $Delta -Name "responsive_gate_changed" -Default $false)
        )
    }
}

function Get-MaterialChangeExplanation {
    param(
        [object]$Certificate,
        [object]$Delta
    )

    if ([bool](Get-ObjectPropertyValue -Object $Certificate -Name "counts_only_as_workflow_validation" -Default $false)) {
        return "This session validated workflow behavior only. It did not move the real promotion gap, responsive gate, or next live objective."
    }

    if (-not [bool](Get-ObjectPropertyValue -Object $Delta -Name "counts_toward_promotion" -Default $false)) {
        return "No material promotion-state change: the latest session stayed outside grounded promotion evidence, so the real responsive gate and next live objective remain unchanged."
    }

    if ([bool](Get-ObjectPropertyValue -Object $Delta -Name "responsive_gate_changed" -Default $false) -or [bool](Get-ObjectPropertyValue -Object $Delta -Name "moved_next_objective" -Default $false)) {
        return [string](Get-ObjectPropertyValue -Object $Delta -Name "explanation" -Default "")
    }

    if ([bool](Get-ObjectPropertyValue -Object $Delta -Name "reduced_promotion_gap" -Default $false)) {
        return [string](Get-ObjectPropertyValue -Object $Delta -Name "explanation" -Default "")
    }

    return "The session counted, but it did not materially change the current responsive gate or the next live objective."
}

function Format-OneDecimalInvariant {
    param([double]$Value)

    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.0}", $Value)
}

function Get-RecommendedNextLiveActionText {
    param(
        [object]$Plan,
        [object]$Certificate,
        [object]$Delta
    )

    $sessionTarget = Get-ObjectPropertyValue -Object $Plan -Name "session_target" -Default $null
    $recommendedProfile = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_live_profile" -Default "")
    $recommendedObjective = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_session_objective" -Default "")

    if ($recommendedObjective -eq "manual-review-before-next-session") {
        return "Manual review before the next live session: inspect comparison.md, scorecard.md, and the treatment lane summary before choosing another profile."
    }

    if ($null -eq $sessionTarget) {
        if (-not [string]::IsNullOrWhiteSpace($recommendedProfile) -or -not [string]::IsNullOrWhiteSpace($recommendedObjective)) {
            return ("Use the {0} profile for the next live pair and target '{1}'." -f $recommendedProfile, $recommendedObjective).Trim()
        }

        return [string](Get-ObjectPropertyValue -Object $Delta -Name "explanation" -Default "")
    }

    $profile = [string](Get-ObjectPropertyValue -Object $sessionTarget -Name "next_session_profile" -Default $recommendedProfile)
    $map = [string](Get-ObjectPropertyValue -Object $sessionTarget -Name "map" -Default "crossfire")
    $botCount = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "bot_count" -Default 4)
    $botSkill = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "bot_skill" -Default 3)
    $minSnapshots = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_snapshots" -Default 0)
    $minPresence = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_presence_seconds" -Default 0.0)
    $minPatchEvents = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_patch_while_humans_present_events" -Default 0)
    $minPostPatch = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_post_patch_observation_seconds" -Default 0.0)
    $anotherConservativeRequired = Get-ObjectPropertyValue -Object $sessionTarget -Name "another_conservative_session_required_after_this" -Default $null
    $couldOpenResponsiveGate = [bool](Get-ObjectPropertyValue -Object $sessionTarget -Name "could_theoretically_open_responsive_gate_if_successful" -Default $false)

    $prefix = if ([bool](Get-ObjectPropertyValue -Object $Certificate -Name "counts_only_as_workflow_validation" -Default $false)) {
        "Keep the real promotion plan conservative. "
    }
    elseif (-not [bool](Get-ObjectPropertyValue -Object $Delta -Name "counts_toward_promotion" -Default $false) -and [string](Get-ObjectPropertyValue -Object $Certificate -Name "evidence_origin" -Default "") -in @("rehearsal", "synthetic")) {
        "Real promotion state did not move. "
    }
    else {
        ""
    }

    $action = "{0}Run the next live pair with the {1} treatment profile on {2} using {3} bots at skill {4}, while keeping the control lane as the no-AI baseline" -f $prefix, $profile, $map, $botCount, $botSkill

    if ($minSnapshots -gt 0 -or $minPresence -gt 0 -or $minPatchEvents -gt 0 -or $minPostPatch -gt 0) {
        $action += ("; target >= {0} human snapshots, >= {1}s human presence, >= {2} treatment patch-while-human-present event(s), and >= {3}s post-patch observation" -f $minSnapshots, (Format-OneDecimalInvariant -Value $minPresence), $minPatchEvents, (Format-OneDecimalInvariant -Value $minPostPatch))
    }

    if ($couldOpenResponsiveGate) {
        $action += "; a successful run could open the responsive gate"
    }
    elseif ($anotherConservativeRequired -eq $true) {
        $action += "; even a successful run will still require another conservative grounded session after this one"
    }

    $action += "."
    return $action
}

function Get-DossierMarkdown {
    param([object]$Dossier)

    $reducedGapComponents = @((Get-ObjectPropertyValue -Object $Dossier.promotion_gap_delta_summary -Name "reduced_promotion_gap_components" -Default @()))
    $nonPromotionGapComponents = @((Get-ObjectPropertyValue -Object $Dossier.promotion_gap_delta_summary -Name "non_promotion_gap_components" -Default @()))

    $lines = @(
        "# Session Outcome Dossier",
        "",
        "- Pair root: $($Dossier.pair_root)",
        "- Prompt ID: $($Dossier.prompt_id)",
        "- Commit SHA: $($Dossier.commit_sha)",
        "- Evidence origin: $($Dossier.evidence_origin)",
        "- Treatment profile: $($Dossier.treatment_profile)",
        "- Certification verdict: $($Dossier.certification_verdict)",
        "- Counts toward promotion: $($Dossier.counts_toward_promotion)",
        "- Workflow-validation-only: $($Dossier.counts_only_as_workflow_validation)",
        "- Latest-session impact classification: $($Dossier.latest_session_impact_classification)",
        "- Current responsive gate verdict: $($Dossier.current_responsive_gate_verdict)",
        "- Current responsive gate action: $($Dossier.current_responsive_gate_next_live_action)",
        "- Current next-live objective: $($Dossier.current_next_live_objective)",
        "- Recommended next live action: $($Dossier.recommended_next_live_action)",
        "- Explanation: $($Dossier.explanation)",
        "",
        "## Session Verdicts",
        "",
        "- Control lane verdict: $($Dossier.control_lane_verdict)",
        "- Treatment lane verdict: $($Dossier.treatment_lane_verdict)",
        "- Pair classification: $($Dossier.pair_classification)",
        "- Scorecard recommendation: $($Dossier.scorecard_recommendation)",
        "- Shadow recommendation: $($Dossier.shadow_recommendation)",
        "- Certification explanation: $($Dossier.certification_explanation)",
        "",
        "## What Changed Because Of This Session?",
        "",
        "- Grounded sessions delta: $($Dossier.what_changed_because_of_this_session.grounded_sessions_delta)",
        "- Grounded too-quiet delta: $($Dossier.what_changed_because_of_this_session.grounded_too_quiet_delta)",
        "- Distinct grounded too-quiet pair IDs delta: $($Dossier.what_changed_because_of_this_session.grounded_too_quiet_distinct_pair_ids_delta)",
        "- Strong-signal delta: $($Dossier.what_changed_because_of_this_session.strong_signal_delta)",
        "- Responsive overreaction blockers delta: $($Dossier.what_changed_because_of_this_session.responsive_overreaction_blockers_delta)",
        "- Changed next objective: $($Dossier.what_changed_because_of_this_session.changed_next_objective)",
        "- Changed next-step recommendation: $($Dossier.what_changed_because_of_this_session.changed_next_step_recommendation)",
        "- Changed responsive gate: $($Dossier.what_changed_because_of_this_session.changed_responsive_gate)",
        "- Workflow-validation-only: $($Dossier.what_changed_because_of_this_session.workflow_validation_only)",
        "- Material change: $($Dossier.what_changed_because_of_this_session.materially_changed_anything)",
        "",
        "## Before Vs After",
        "",
        "- Responsive gate: $($Dossier.before_vs_after_summary.responsive_gate.before.gate_verdict) / $($Dossier.before_vs_after_summary.responsive_gate.before.next_live_action) -> $($Dossier.before_vs_after_summary.responsive_gate.after.gate_verdict) / $($Dossier.before_vs_after_summary.responsive_gate.after.next_live_action)",
        "- Next-live objective: $($Dossier.before_vs_after_summary.next_live_objective.before) -> $($Dossier.before_vs_after_summary.next_live_objective.after)",
        "- Next-live profile: $($Dossier.before_vs_after_summary.next_live_profile.before) -> $($Dossier.before_vs_after_summary.next_live_profile.after)",
        "- Grounded sessions current/missing: $($Dossier.before_vs_after_summary.promotion_gap_counts_before.grounded_sessions_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_before.grounded_sessions_missing) -> $($Dossier.before_vs_after_summary.promotion_gap_counts_after.grounded_sessions_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_after.grounded_sessions_missing)",
        "- Grounded too-quiet current/missing: $($Dossier.before_vs_after_summary.promotion_gap_counts_before.grounded_too_quiet_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_before.grounded_too_quiet_missing) -> $($Dossier.before_vs_after_summary.promotion_gap_counts_after.grounded_too_quiet_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_after.grounded_too_quiet_missing)",
        "- Distinct grounded too-quiet pair IDs current/missing: $($Dossier.before_vs_after_summary.promotion_gap_counts_before.grounded_too_quiet_distinct_pair_ids_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_before.grounded_too_quiet_distinct_pair_ids_missing) -> $($Dossier.before_vs_after_summary.promotion_gap_counts_after.grounded_too_quiet_distinct_pair_ids_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_after.grounded_too_quiet_distinct_pair_ids_missing)",
        "- Strong-signal current/missing: $($Dossier.before_vs_after_summary.promotion_gap_counts_before.strong_signal_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_before.strong_signal_missing) -> $($Dossier.before_vs_after_summary.promotion_gap_counts_after.strong_signal_current) / $($Dossier.before_vs_after_summary.promotion_gap_counts_after.strong_signal_missing)",
        "- Responsive overreaction blockers: $($Dossier.before_vs_after_summary.promotion_gap_counts_before.responsive_overreaction_blockers_current) -> $($Dossier.before_vs_after_summary.promotion_gap_counts_after.responsive_overreaction_blockers_current)",
        "- Material change explanation: $($Dossier.before_vs_after_summary.material_change_explanation)",
        "",
        "## Promotion Gap Delta Summary",
        "",
        "- Reduced promotion gap: $($Dossier.promotion_gap_delta_summary.reduced_promotion_gap)",
        "- Reduced components: $(if ($reducedGapComponents.Count -gt 0) { $reducedGapComponents -join ', ' } else { 'none' })",
        "- Non-promotion components: $(if ($nonPromotionGapComponents.Count -gt 0) { $nonPromotionGapComponents -join ', ' } else { 'none' })",
        "",
        "## Scenario Artifacts",
        "",
        "- Pair summary JSON: $($Dossier.artifacts.pair_summary_json)",
        "- Scorecard JSON: $($Dossier.artifacts.scorecard_json)",
        "- Shadow recommendation JSON: $($Dossier.artifacts.shadow_recommendation_json)",
        "- Grounded evidence certificate JSON: $($Dossier.artifacts.grounded_evidence_certificate_json)",
        "- Grounded session analysis JSON: $($Dossier.artifacts.grounded_session_analysis_json)",
        "- Promotion gap delta JSON: $($Dossier.artifacts.promotion_gap_delta_json)",
        "- Without-latest scenario root: $($Dossier.artifacts.without_latest_root)",
        "- With-latest scenario root: $($Dossier.artifacts.with_latest_root)",
        "- Guided final session docket JSON: $($Dossier.artifacts.guided_final_session_docket_json)",
        "- Outcome dossier JSON: $($Dossier.artifacts.session_outcome_dossier_json)",
        "- Outcome dossier Markdown: $($Dossier.artifacts.session_outcome_dossier_markdown)"
    )

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

$selectionMode = if ([string]::IsNullOrWhiteSpace($PairRoot)) { "latest-pair-root" } else { "explicit-pair-root" }
$resolvedPairRoot = if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    Find-LatestPairRoot -Root $resolvedPairsRoot
}
else {
    Resolve-ExistingPath -Path (Get-AbsolutePath -Path $PairRoot -BasePath $repoRoot)
}

if ([string]::IsNullOrWhiteSpace($resolvedPairRoot)) {
    throw "Pair root was not found: $PairRoot"
}

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    Join-Path $resolvedPairRoot "session_outcome_dossier.json"
}
else {
    Get-AbsolutePath -Path $OutputJson -BasePath $resolvedPairRoot
}
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    Join-Path $resolvedPairRoot "session_outcome_dossier.md"
}
else {
    Get-AbsolutePath -Path $OutputMarkdown -BasePath $resolvedPairRoot
}

$scoreScriptPath = Join-Path $PSScriptRoot "score_latest_pair_session.ps1"
$shadowScriptPath = Join-Path $PSScriptRoot "run_shadow_profile_review.ps1"
$certifyScriptPath = Join-Path $PSScriptRoot "certify_latest_pair_session.ps1"
$analysisScriptPath = Join-Path $PSScriptRoot "analyze_latest_grounded_session.ps1"

Invoke-HelperScript -ScriptPath $scoreScriptPath -Arguments @{ PairRoot = $resolvedPairRoot }
Invoke-HelperScript -ScriptPath $shadowScriptPath -Arguments @{ PairRoot = $resolvedPairRoot; Profiles = @("conservative", "default", "responsive") }
Invoke-HelperScript -ScriptPath $certifyScriptPath -Arguments @{ PairRoot = $resolvedPairRoot; LabRoot = $resolvedLabRoot }
Invoke-HelperScript -ScriptPath $analysisScriptPath -Arguments @{ PairRoot = $resolvedPairRoot; RegistryPath = $resolvedRegistryPath; LabRoot = $resolvedLabRoot }

$pairSummaryPath = Join-Path $resolvedPairRoot "pair_summary.json"
$scorecardPath = Join-Path $resolvedPairRoot "scorecard.json"
$shadowRecommendationPath = Join-Path $resolvedPairRoot "shadow_review\shadow_recommendation.json"
$certificatePath = Join-Path $resolvedPairRoot "grounded_evidence_certificate.json"
$analysisPath = Join-Path $resolvedPairRoot "grounded_session_analysis.json"
$deltaPath = Join-Path $resolvedPairRoot "promotion_gap_delta.json"
$guidedDocketPath = Join-Path $resolvedPairRoot "guided_session\final_session_docket.json"

$pairSummary = Read-JsonFile -Path $pairSummaryPath
$scorecard = Read-JsonFile -Path $scorecardPath
$shadowRecommendation = Read-JsonFile -Path $shadowRecommendationPath
$certificate = Read-JsonFile -Path $certificatePath
$analysis = Read-JsonFile -Path $analysisPath
$delta = Read-JsonFile -Path $deltaPath
$guidedDocket = Read-JsonFile -Path $guidedDocketPath

if ($null -eq $pairSummary -or $null -eq $scorecard -or $null -eq $shadowRecommendation -or $null -eq $certificate -or $null -eq $analysis -or $null -eq $delta) {
    throw "The dossier helper could not load the required post-session artifacts under $resolvedPairRoot"
}

$afterSnapshot = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $analysis -Name "with_latest" -Default $null) -Name "snapshot" -Default $null
$beforeSnapshot = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $analysis -Name "without_latest" -Default $null) -Name "snapshot" -Default $null
$afterPlanPath = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $analysis -Name "with_latest" -Default $null) -Name "next_live_plan_json_path" -Default "")
$afterPlan = Read-JsonFile -Path $afterPlanPath

if ($null -eq $afterSnapshot -or $null -eq $beforeSnapshot -or $null -eq $afterPlan) {
    throw "The dossier helper could not resolve the before/after scenario snapshots under $resolvedPairRoot"
}

$commitSha = Get-PreferredCommitSha -PairSummary $pairSummary -Scorecard $scorecard -Certificate $certificate -GuidedDocket $guidedDocket
$evidenceOrigin = [string](Get-ObjectPropertyValue -Object $certificate -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $delta -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default "")))
$treatmentProfile = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "treatment_profile" -Default ""))
$controlLaneVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "lane_verdict" -Default "")
$treatmentLaneVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "lane_verdict" -Default "")
$pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "pair_classification" -Default ""))
$scorecardRecommendation = [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation" -Default "")
$shadowRecommendationDecision = [string](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "decision" -Default "")
$certificationVerdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
$countsOnlyAsWorkflowValidation = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_only_as_workflow_validation" -Default $false)
$impactClassification = [string](Get-ObjectPropertyValue -Object $delta -Name "impact_classification" -Default "")
$currentResponsiveGateVerdict = [string](Get-ObjectPropertyValue -Object $afterSnapshot -Name "gate_verdict" -Default "")
$currentResponsiveGateNextLiveAction = [string](Get-ObjectPropertyValue -Object $afterSnapshot -Name "gate_next_live_action" -Default "")
$currentNextLiveObjective = [string](Get-ObjectPropertyValue -Object $afterSnapshot -Name "recommended_next_session_objective" -Default "")
$currentNextLiveProfile = [string](Get-ObjectPropertyValue -Object $afterSnapshot -Name "recommended_next_live_profile" -Default "")
$explanation = [string](Get-ObjectPropertyValue -Object $delta -Name "explanation" -Default "")
$recommendedNextLiveAction = Get-RecommendedNextLiveActionText -Plan $afterPlan -Certificate $certificate -Delta $delta
$whatChangedBlock = Get-WhatChangedBecauseOfThisSession -Certificate $certificate -Delta $delta
$materialChangeExplanation = Get-MaterialChangeExplanation -Certificate $certificate -Delta $delta

$beforeVsAfterSummary = [ordered]@{
    responsive_gate = [ordered]@{
        before = [ordered]@{
            gate_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_before" -Default $null) -Name "gate_verdict" -Default (Get-ObjectPropertyValue -Object $beforeSnapshot -Name "gate_verdict" -Default ""))
            next_live_action = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_before" -Default $null) -Name "next_live_action" -Default (Get-ObjectPropertyValue -Object $beforeSnapshot -Name "gate_next_live_action" -Default ""))
        }
        after = [ordered]@{
            gate_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_after" -Default $null) -Name "gate_verdict" -Default $currentResponsiveGateVerdict)
            next_live_action = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_after" -Default $null) -Name "next_live_action" -Default $currentResponsiveGateNextLiveAction)
        }
    }
    next_live_profile = [ordered]@{
        before = [string](Get-ObjectPropertyValue -Object $delta -Name "next_live_profile_before" -Default (Get-ObjectPropertyValue -Object $beforeSnapshot -Name "recommended_next_live_profile" -Default ""))
        after = $currentNextLiveProfile
    }
    next_live_objective = [ordered]@{
        before = [string](Get-ObjectPropertyValue -Object $delta -Name "next_objective_before" -Default (Get-ObjectPropertyValue -Object $beforeSnapshot -Name "recommended_next_session_objective" -Default ""))
        after = $currentNextLiveObjective
    }
    promotion_gap_counts_before = [ordered]@{
        grounded_sessions_current = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "grounded_sessions_current" -Default 0)
        grounded_sessions_missing = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "grounded_sessions_missing" -Default 0)
        grounded_too_quiet_current = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "grounded_too_quiet_current" -Default 0)
        grounded_too_quiet_missing = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "grounded_too_quiet_missing" -Default 0)
        grounded_too_quiet_distinct_pair_ids_current = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "grounded_too_quiet_distinct_pair_ids_current" -Default 0)
        grounded_too_quiet_distinct_pair_ids_missing = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "grounded_too_quiet_distinct_pair_ids_missing" -Default 0)
        strong_signal_current = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "strong_signal_current" -Default 0)
        strong_signal_missing = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "strong_signal_missing" -Default 0)
        responsive_overreaction_blockers_current = [int](Get-ObjectPropertyValue -Object $beforeSnapshot -Name "responsive_overreaction_blockers_current" -Default 0)
    }
    promotion_gap_counts_after = [ordered]@{
        grounded_sessions_current = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "grounded_sessions_current" -Default 0)
        grounded_sessions_missing = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "grounded_sessions_missing" -Default 0)
        grounded_too_quiet_current = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "grounded_too_quiet_current" -Default 0)
        grounded_too_quiet_missing = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "grounded_too_quiet_missing" -Default 0)
        grounded_too_quiet_distinct_pair_ids_current = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "grounded_too_quiet_distinct_pair_ids_current" -Default 0)
        grounded_too_quiet_distinct_pair_ids_missing = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "grounded_too_quiet_distinct_pair_ids_missing" -Default 0)
        strong_signal_current = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "strong_signal_current" -Default 0)
        strong_signal_missing = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "strong_signal_missing" -Default 0)
        responsive_overreaction_blockers_current = [int](Get-ObjectPropertyValue -Object $afterSnapshot -Name "responsive_overreaction_blockers_current" -Default 0)
    }
    material_change_explanation = $materialChangeExplanation
}

$dossier = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    selection_mode = $selectionMode
    pair_root = $resolvedPairRoot
    registry_path = $resolvedRegistryPath
    commit_sha = $commitSha
    evidence_origin = $evidenceOrigin
    treatment_profile = $treatmentProfile
    control_lane_verdict = $controlLaneVerdict
    treatment_lane_verdict = $treatmentLaneVerdict
    pair_classification = $pairClassification
    scorecard_recommendation = $scorecardRecommendation
    shadow_recommendation = $shadowRecommendationDecision
    certification_verdict = $certificationVerdict
    certification_explanation = [string](Get-ObjectPropertyValue -Object $certificate -Name "explanation" -Default "")
    counts_toward_promotion = $countsTowardPromotion
    counts_only_as_workflow_validation = $countsOnlyAsWorkflowValidation
    latest_session_impact_classification = $impactClassification
    promotion_gap_delta_summary = Get-PromotionGapDeltaSummary -Delta $delta
    current_responsive_gate_verdict = $currentResponsiveGateVerdict
    current_responsive_gate_next_live_action = $currentResponsiveGateNextLiveAction
    current_next_live_profile = $currentNextLiveProfile
    current_next_live_objective = $currentNextLiveObjective
    recommended_next_live_action = $recommendedNextLiveAction
    explanation = $explanation
    what_changed_because_of_this_session = $whatChangedBlock
    before_vs_after_summary = $beforeVsAfterSummary
    latest_session = [ordered]@{
        pair_id = [string](Get-ObjectPropertyValue -Object $analysis -Name "pair_id" -Default "")
        scorecard_recommendation = $scorecardRecommendation
        shadow_recommendation = $shadowRecommendationDecision
        certification_verdict = $certificationVerdict
    }
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryPath
        scorecard_json = $scorecardPath
        shadow_recommendation_json = $shadowRecommendationPath
        grounded_evidence_certificate_json = $certificatePath
        grounded_session_analysis_json = $analysisPath
        promotion_gap_delta_json = $deltaPath
        without_latest_root = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $analysis -Name "without_latest" -Default $null) -Name "root" -Default "")
        with_latest_root = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $analysis -Name "with_latest" -Default $null) -Name "root" -Default "")
        guided_final_session_docket_json = Resolve-ExistingPath -Path $guidedDocketPath
        session_outcome_dossier_json = $outputJsonPath
        session_outcome_dossier_markdown = $outputMarkdownPath
    }
}

Write-JsonFile -Path $outputJsonPath -Value $dossier
$dossierForMarkdown = $dossier | ConvertTo-Json -Depth 20 | ConvertFrom-Json
Write-TextFile -Path $outputMarkdownPath -Value (Get-DossierMarkdown -Dossier $dossierForMarkdown)

Write-Host "Session outcome dossier:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Certification verdict: $certificationVerdict"
Write-Host "  Latest-session impact classification: $impactClassification"
Write-Host "  Responsive gate verdict: $currentResponsiveGateVerdict"
Write-Host "  Next-live objective: $currentNextLiveObjective"
Write-Host "  Dossier JSON: $outputJsonPath"
Write-Host "  Dossier Markdown: $outputMarkdownPath"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    RegistryPath = $resolvedRegistryPath
    SessionOutcomeDossierJsonPath = $outputJsonPath
    SessionOutcomeDossierMarkdownPath = $outputMarkdownPath
    CertificationVerdict = $certificationVerdict
    ImpactClassification = $impactClassification
    ResponsiveGateVerdict = $currentResponsiveGateVerdict
    CurrentNextLiveObjective = $currentNextLiveObjective
    RecommendedNextLiveAction = $recommendedNextLiveAction
}
