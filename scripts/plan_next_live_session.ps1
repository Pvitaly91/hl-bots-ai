[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RegistryPath = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$RegistrySummaryPath = "",
    [string]$ProfileRecommendationPath = "",
    [string]$ResponsiveTrialGatePath = "",
    [string]$GateConfigPath = "",
    [switch]$RefreshRegistrySummary,
    [switch]$RefreshResponsiveTrialGate
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

    $json = $Value | ConvertTo-Json -Depth 16
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

function Get-UniqueStringList {
    param([object[]]$Items)

    return @(
        $Items |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-MissingCount {
    param(
        [int]$Required,
        [int]$Current
    )

    return [Math]::Max(0, $Required - $Current)
}

function New-SessionTarget {
    param(
        [string]$TreatmentProfile,
        [object]$TrialDefaults,
        [int]$TargetMinHumanSnapshots,
        [double]$TargetMinHumanPresenceSeconds,
        [int]$TargetMinPatchEventsWhileHumansPresent,
        [double]$TargetMinPostPatchObservationSeconds,
        [bool]$CanReducePromotionGap,
        [bool]$CouldOpenResponsiveGateIfSuccessful,
        [Nullable[bool]]$AnotherConservativeSessionRequiredAfterThis,
        [string[]]$Priorities
    )

    $treatmentLaneLabel = if ($TreatmentProfile -eq "responsive") {
        [string](Get-ObjectPropertyValue -Object $TrialDefaults -Name "treatment_lane_label" -Default "treatment-responsive")
    }
    else {
        "treatment-$TreatmentProfile"
    }

    return [ordered]@{
        map = [string](Get-ObjectPropertyValue -Object $TrialDefaults -Name "map" -Default "crossfire")
        bot_count = [int](Get-ObjectPropertyValue -Object $TrialDefaults -Name "bot_count" -Default 4)
        bot_skill = [int](Get-ObjectPropertyValue -Object $TrialDefaults -Name "bot_skill" -Default 3)
        next_session_profile = $TreatmentProfile
        control_lane = [ordered]@{
            unchanged = $true
            mode = "NoAI"
            lane_label = [string](Get-ObjectPropertyValue -Object $TrialDefaults -Name "control_lane_label" -Default "control-baseline")
            port = [int](Get-ObjectPropertyValue -Object $TrialDefaults -Name "control_port" -Default 27016)
            jk_ai_balance_enabled = 0
            sidecar = "disabled"
        }
        treatment_lane = [ordered]@{
            mode = "AI"
            lane_label = $treatmentLaneLabel
            port = [int](Get-ObjectPropertyValue -Object $TrialDefaults -Name "treatment_port" -Default 27017)
            treatment_profile = $TreatmentProfile
            sidecar = "enabled"
        }
        target_min_human_snapshots = $TargetMinHumanSnapshots
        target_min_human_presence_seconds = [Math]::Round($TargetMinHumanPresenceSeconds, 1)
        target_min_patch_while_humans_present_events = $TargetMinPatchEventsWhileHumansPresent
        target_min_post_patch_observation_seconds = [Math]::Round($TargetMinPostPatchObservationSeconds, 1)
        can_reduce_promotion_gap = $CanReducePromotionGap
        could_theoretically_open_responsive_gate_if_successful = $CouldOpenResponsiveGateIfSuccessful
        another_conservative_session_required_after_this = $AnotherConservativeSessionRequiredAfterThis
        priorities = @($Priorities)
    }
}

function Get-NextLivePlanMarkdown {
    param([object]$Plan)

    $blockReasons = @($Plan.responsive_block_reasons)
    $deficits = @($Plan.deficits_remaining_descriptions)
    $priorities = @($Plan.session_target.priorities)
    $supportingPairIds = @($Plan.supporting_pair_ids)
    $excludedReasonCounts = Get-ObjectPropertyValue -Object $Plan.exclusions -Name "excluded_sessions_by_reason" -Default $null

    $lines = @(
        "# Next Live Session Plan",
        "",
        "- Responsive gate verdict: $($Plan.current_responsive_gate_verdict)",
        "- Responsive gate next live action: $($Plan.current_responsive_gate_next_live_action)",
        "- Current default live treatment profile: $($Plan.current_default_live_treatment_profile)",
        "- Recommended next live profile: $($Plan.recommended_next_live_profile)",
        "- Recommended next-session objective: $($Plan.recommended_next_session_objective)",
        "- Explanation: $($Plan.explanation)",
        "",
        "## Certified Grounded Evidence",
        "",
        "- Total certified grounded sessions: $($Plan.current_certified_grounded_session_counts.total)",
        "- Certified grounded conservative sessions: $($Plan.current_certified_grounded_session_counts.conservative)",
        "- Certified grounded responsive sessions: $($Plan.current_certified_grounded_session_counts.responsive)",
        "- Grounded conservative too-quiet count: $($Plan.current_grounded_conservative_too_quiet_count)",
        "- Grounded responsive too-reactive count: $($Plan.current_grounded_responsive_too_reactive_count)",
        "- Grounded tuning-usable count: $($Plan.current_grounded_tuning_usable_count)",
        "- Grounded strong-signal count: $($Plan.current_grounded_strong_signal_count)",
        "",
        "## Evidence Gap",
        "",
        "- Promotion evidence scope: $($Plan.promotion_evidence_scope)",
        "- Grounded conservative sessions required/current/missing: $($Plan.evidence_gap.grounded_sessions_required) / $($Plan.evidence_gap.grounded_sessions_current) / $($Plan.evidence_gap.grounded_sessions_missing)",
        "- Grounded conservative too-quiet required/current/missing: $($Plan.evidence_gap.grounded_too_quiet_required) / $($Plan.evidence_gap.grounded_too_quiet_current) / $($Plan.evidence_gap.grounded_too_quiet_missing)",
        "- Distinct grounded conservative too-quiet pair IDs required/current/missing: $($Plan.evidence_gap.grounded_too_quiet_distinct_pair_ids_required) / $($Plan.evidence_gap.grounded_too_quiet_distinct_pair_ids_current) / $($Plan.evidence_gap.grounded_too_quiet_distinct_pair_ids_missing)",
        "- Strong-signal required/current/missing: $($Plan.evidence_gap.strong_signal_required) / $($Plan.evidence_gap.strong_signal_current) / $($Plan.evidence_gap.strong_signal_missing)",
        "- Grounded tuning-usable current: $($Plan.evidence_gap.grounded_tuning_usable_current)",
        "- Responsive overreaction blockers current: $($Plan.evidence_gap.responsive_overreaction_blockers_current)",
        "- Conservative appropriate-session ceiling/current/excess: $($Plan.evidence_gap.grounded_appropriate_max_for_responsive_trial) / $($Plan.evidence_gap.grounded_appropriate_current) / $($Plan.evidence_gap.grounded_appropriate_excess)",
        "",
        "## Exclusions",
        "",
        "- Synthetic or rehearsal sessions excluded from promotion: $($Plan.exclusions.synthetic_or_rehearsal_evidence_excluded)",
        "- Weak or insufficient sessions excluded from promotion: $($Plan.exclusions.weak_or_insufficient_evidence_excluded)",
        "- Workflow-validation-only sessions: $($Plan.exclusions.workflow_validation_only_sessions_count)",
        "- Weak or insufficient sessions: $($Plan.exclusions.weak_or_insufficient_sessions_count)",
        "- Non-certified live sessions: $($Plan.exclusions.non_certified_live_sessions_count)",
        ""
    )

    if ($excludedReasonCounts -is [System.Collections.IDictionary] -and $excludedReasonCounts.Count -gt 0) {
        $lines += "### Excluded Sessions By Reason"
        $lines += ""
        foreach ($key in $excludedReasonCounts.Keys) {
            $lines += "- ${key}: $($excludedReasonCounts[$key])"
        }
        $lines += ""
    }

    $lines += @(
        "## Responsive Block Reasons",
        ""
    )

    if ($blockReasons.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($reason in $blockReasons) {
            $lines += "- $reason"
        }
    }

    $lines += @(
        "",
        "## Deficits Remaining",
        ""
    )

    if ($deficits.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($deficit in $deficits) {
            $lines += "- $deficit"
        }
    }

    $lines += @(
        "",
        "## Next Session Target",
        "",
        "- Next session profile: $($Plan.session_target.next_session_profile)",
        "- Control lane: unchanged no-AI baseline on port $($Plan.session_target.control_lane.port)",
        "- Treatment lane: $($Plan.session_target.treatment_lane.lane_label) on port $($Plan.session_target.treatment_lane.port)",
        "- Map: $($Plan.session_target.map)",
        "- Bot count: $($Plan.session_target.bot_count)",
        "- Bot skill: $($Plan.session_target.bot_skill)",
        "- Target minimum human snapshots: $($Plan.session_target.target_min_human_snapshots)",
        "- Target minimum human presence seconds: $($Plan.session_target.target_min_human_presence_seconds)",
        "- Target minimum patch-while-human-present events: $($Plan.session_target.target_min_patch_while_humans_present_events)",
        "- Target minimum post-patch observation seconds: $($Plan.session_target.target_min_post_patch_observation_seconds)",
        "- This session can reduce the promotion gap: $($Plan.session_target.can_reduce_promotion_gap)",
        "- This session could open the responsive gate if successful: $($Plan.session_target.could_theoretically_open_responsive_gate_if_successful)",
        "- Another conservative session would still be required after this: $($Plan.session_target.another_conservative_session_required_after_this)",
        "",
        "## Priorities",
        ""
    )

    if ($priorities.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($priority in $priorities) {
            $lines += "- $priority"
        }
    }

    $lines += @(
        "",
        "## Supporting Pair IDs",
        ""
    )

    if ($supportingPairIds.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($pairId in $supportingPairIds) {
            $lines += "- $pairId"
        }
    }

    $lines += @(
        "",
        "## Source Artifacts",
        "",
        "- Registry summary JSON: $($Plan.registry_summary_json)",
        "- Profile recommendation JSON: $($Plan.profile_recommendation_json)",
        "- Responsive trial gate JSON: $($Plan.responsive_trial_gate_json)"
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

$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Split-Path -Path $resolvedRegistryPath -Parent)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}

$resolvedRegistrySummaryPath = if ([string]::IsNullOrWhiteSpace($RegistrySummaryPath)) {
    Join-Path $resolvedOutputRoot "registry_summary.json"
}
else {
    Get-AbsolutePath -Path $RegistrySummaryPath -BasePath $repoRoot
}

$resolvedProfileRecommendationPath = if ([string]::IsNullOrWhiteSpace($ProfileRecommendationPath)) {
    Join-Path $resolvedOutputRoot "profile_recommendation.json"
}
else {
    Get-AbsolutePath -Path $ProfileRecommendationPath -BasePath $repoRoot
}

$resolvedResponsiveTrialGatePath = if ([string]::IsNullOrWhiteSpace($ResponsiveTrialGatePath)) {
    Join-Path $resolvedOutputRoot "responsive_trial_gate.json"
}
else {
    Get-AbsolutePath -Path $ResponsiveTrialGatePath -BasePath $repoRoot
}

$resolvedGateConfigPath = if ([string]::IsNullOrWhiteSpace($GateConfigPath)) {
    Join-Path $repoRoot "ai_director\testdata\responsive_trial_gate.json"
}
else {
    Get-AbsolutePath -Path $GateConfigPath -BasePath $repoRoot
}

$summaryScriptPath = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"
$gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"

if (
    $RefreshRegistrySummary -or
    -not (Test-Path -LiteralPath $resolvedRegistrySummaryPath) -or
    -not (Test-Path -LiteralPath $resolvedProfileRecommendationPath)
) {
    & $summaryScriptPath `
        -RegistryPath $resolvedRegistryPath `
        -OutputRoot $resolvedOutputRoot | Out-Null
}

if (
    $RefreshResponsiveTrialGate -or
    -not (Test-Path -LiteralPath $resolvedResponsiveTrialGatePath)
) {
    $gateArgs = @{
        RegistryPath = $resolvedRegistryPath
        OutputRoot = $resolvedOutputRoot
        RegistrySummaryPath = $resolvedRegistrySummaryPath
        ProfileRecommendationPath = $resolvedProfileRecommendationPath
        GateConfigPath = $resolvedGateConfigPath
    }
    & $gateScriptPath @gateArgs | Out-Null
}

$summary = Read-JsonFile -Path $resolvedRegistrySummaryPath
$profileRecommendation = Read-JsonFile -Path $resolvedProfileRecommendationPath
$gate = Read-JsonFile -Path $resolvedResponsiveTrialGatePath
$gateConfig = Read-JsonFile -Path $resolvedGateConfigPath

if ($null -eq $summary) {
    throw "Registry summary was not found: $resolvedRegistrySummaryPath"
}
if ($null -eq $profileRecommendation) {
    throw "Profile recommendation was not found: $resolvedProfileRecommendationPath"
}
if ($null -eq $gate) {
    throw "Responsive trial gate output was not found: $resolvedResponsiveTrialGatePath"
}
if ($null -eq $gateConfig) {
    throw "Responsive trial gate config was not found: $resolvedGateConfigPath"
}

$thresholds = Get-ObjectPropertyValue -Object $gate -Name "thresholds" -Default $null
$trialDefaults = Get-ObjectPropertyValue -Object $gateConfig -Name "trial_defaults" -Default $null
if ($null -eq $thresholds -or $null -eq $trialDefaults) {
    throw "Responsive trial gate inputs are missing thresholds or trial_defaults."
}

$conservativeProfile = Get-TuningProfileDefinition -Name "conservative"
$responsiveProfile = Get-TuningProfileDefinition -Name "responsive"
$conservativeSnapshot = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $profileRecommendation -Name "evidence_snapshot" -Default $null) -Name "conservative" -Default $null
$responsiveSnapshot = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $profileRecommendation -Name "evidence_snapshot" -Default $null) -Name "responsive" -Default $null
$conservativeEvidenceCounts = Get-ObjectPropertyValue -Object $gate -Name "conservative_evidence_counts" -Default $null
$responsiveRiskEvidenceCounts = Get-ObjectPropertyValue -Object $gate -Name "responsive_risk_evidence_counts" -Default $null
$profileQuestions = Get-ObjectPropertyValue -Object $profileRecommendation -Name "questions" -Default $null

$groundedSessionsRequired = [int](Get-ObjectPropertyValue -Object $thresholds -Name "min_grounded_conservative_sessions_for_responsive_trial" -Default 0)
$groundedSessionsCurrent = [int](Get-ObjectPropertyValue -Object $conservativeEvidenceCounts -Name "real_grounded_count" -Default 0)
$groundedSessionsMissing = Get-MissingCount -Required $groundedSessionsRequired -Current $groundedSessionsCurrent

$groundedTooQuietRequired = [int](Get-ObjectPropertyValue -Object $thresholds -Name "min_grounded_conservative_too_quiet_sessions_for_responsive_trial" -Default 0)
$groundedTooQuietCurrent = [int](Get-ObjectPropertyValue -Object $conservativeEvidenceCounts -Name "real_grounded_too_quiet_count" -Default 0)
$groundedTooQuietMissing = Get-MissingCount -Required $groundedTooQuietRequired -Current $groundedTooQuietCurrent

$groundedTooQuietDistinctPairIdsRequired = [int](Get-ObjectPropertyValue -Object $thresholds -Name "min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial" -Default 0)
$groundedTooQuietDistinctPairIdsCurrent = [int](Get-ObjectPropertyValue -Object $conservativeEvidenceCounts -Name "real_distinct_grounded_too_quiet_pair_ids_count" -Default 0)
$groundedTooQuietDistinctPairIdsMissing = Get-MissingCount -Required $groundedTooQuietDistinctPairIdsRequired -Current $groundedTooQuietDistinctPairIdsCurrent

$groundedAppropriateMaxForResponsiveTrial = [int](Get-ObjectPropertyValue -Object $thresholds -Name "max_grounded_conservative_appropriate_sessions_for_responsive_trial" -Default 0)
$groundedAppropriateCurrent = [int](Get-ObjectPropertyValue -Object $conservativeEvidenceCounts -Name "real_grounded_appropriately_conservative_count" -Default 0)
$groundedAppropriateExcess = [Math]::Max(0, $groundedAppropriateCurrent - $groundedAppropriateMaxForResponsiveTrial)

$strongSignalRequired = [int](Get-ObjectPropertyValue -Object $thresholds -Name "min_grounded_conservative_strong_signal_sessions_for_keep" -Default 0)
$strongSignalCurrent = [int](Get-ObjectPropertyValue -Object $conservativeSnapshot -Name "strong_signal_count" -Default 0)
$strongSignalMissing = Get-MissingCount -Required $strongSignalRequired -Current $strongSignalCurrent

$groundedTuningUsableCurrent = [int](Get-ObjectPropertyValue -Object $summary -Name "grounded_tuning_usable_count" -Default 0)
$groundedStrongSignalCurrent = [int](Get-ObjectPropertyValue -Object $summary -Name "grounded_strong_signal_count" -Default 0)
$responsiveOverreactionBlockersCurrent = [int](Get-ObjectPropertyValue -Object $responsiveRiskEvidenceCounts -Name "real_grounded_too_reactive_count" -Default 0)
$responsiveOverreactionBlockerThreshold = [int](Get-ObjectPropertyValue -Object $thresholds -Name "min_grounded_responsive_too_reactive_sessions_for_revert" -Default 1)
$responsiveOverreactionHistoryActive = $responsiveOverreactionBlockerThreshold -gt 0 -and $responsiveOverreactionBlockersCurrent -ge $responsiveOverreactionBlockerThreshold
$conservativeTooReactiveCurrent = [int](Get-ObjectPropertyValue -Object $conservativeEvidenceCounts -Name "real_grounded_too_reactive_count" -Default 0)
$shadowResponsiveCandidateCurrent = [int](Get-ObjectPropertyValue -Object $conservativeEvidenceCounts -Name "real_shadow_responsive_candidate_count" -Default 0)

$totalRegisteredPairSessions = [int](Get-ObjectPropertyValue -Object $summary -Name "total_registered_pair_sessions" -Default 0)
$totalCertifiedGroundedSessions = [int](Get-ObjectPropertyValue -Object $summary -Name "total_certified_grounded_sessions" -Default 0)
$workflowValidationOnlySessionsCount = [int](Get-ObjectPropertyValue -Object $summary -Name "workflow_validation_only_sessions_count" -Default 0)
$totalNonCertifiedSessions = [int](Get-ObjectPropertyValue -Object $summary -Name "total_non_certified_sessions" -Default 0)
$nonCertifiedLiveSessionsCount = [Math]::Max(0, $totalNonCertifiedSessions - $workflowValidationOnlySessionsCount)
$weakSignalCount = [int](Get-ObjectPropertyValue -Object $summary -Name "weak_signal_count" -Default 0)
$insufficientDataCount = [int](Get-ObjectPropertyValue -Object $summary -Name "insufficient_data_count" -Default 0)
$weakOrInsufficientSessionsCount = $weakSignalCount + $insufficientDataCount
$excludedSessionsByReason = Get-ObjectPropertyValue -Object $summary -Name "excluded_sessions_by_reason" -Default @{}

$gateVerdict = [string](Get-ObjectPropertyValue -Object $gate -Name "gate_verdict" -Default "")
$gateNextLiveAction = [string](Get-ObjectPropertyValue -Object $gate -Name "next_live_action" -Default "")
$gateExplanation = [string](Get-ObjectPropertyValue -Object $gate -Name "explanation" -Default "")
$profileDecision = [string](Get-ObjectPropertyValue -Object $profileRecommendation -Name "decision" -Default "")
$profileRecommendedLiveProfile = [string](Get-ObjectPropertyValue -Object $profileRecommendation -Name "recommended_live_profile" -Default "conservative")
$currentDefaultLiveTreatmentProfile = if ($gateVerdict -eq "open" -and $gateNextLiveAction -eq "responsive-trial-allowed") {
    "responsive"
}
elseif ([string]::IsNullOrWhiteSpace($profileRecommendedLiveProfile)) {
    "conservative"
}
else {
    $profileRecommendedLiveProfile
}

$manualReviewNeeded = (
    $gateVerdict -eq "manual-review-needed" -or
    $profileDecision -eq "manual-review-needed" -or
    [bool](Get-ObjectPropertyValue -Object $profileQuestions -Name "manual_review_needed" -Default $false)
)
$keepConservativeEvidencePresent = $gateNextLiveAction -eq "keep-conservative"
$responsiveTrialReady = $gateVerdict -eq "open" -and $gateNextLiveAction -eq "responsive-trial-allowed"

$deficitsRemainingDescriptions = @()
if ($groundedSessionsMissing -gt 0) {
    $deficitsRemainingDescriptions += "$groundedSessionsMissing certified grounded conservative session(s) are still missing before responsive can open."
}
if ($groundedTooQuietMissing -gt 0) {
    $deficitsRemainingDescriptions += "$groundedTooQuietMissing certified grounded conservative too-quiet session(s) are still missing before responsive can open."
}
if ($groundedTooQuietDistinctPairIdsMissing -gt 0) {
    $deficitsRemainingDescriptions += "$groundedTooQuietDistinctPairIdsMissing distinct certified grounded conservative too-quiet pair run(s) are still missing before responsive can open."
}
if ($groundedAppropriateExcess -gt 0) {
    $deficitsRemainingDescriptions += "$groundedAppropriateExcess certified grounded conservative appropriately-conservative session(s) sit above the responsive-opening ceiling."
}
if ($responsiveOverreactionHistoryActive) {
    $deficitsRemainingDescriptions += "Responsive promotion is blocked by $responsiveOverreactionBlockersCurrent grounded responsive too-reactive blocker(s)."
}
if ($workflowValidationOnlySessionsCount -gt 0) {
    $deficitsRemainingDescriptions += "$workflowValidationOnlySessionsCount rehearsal or synthetic workflow-validation session(s) are excluded from the real promotion gap."
}
if ($nonCertifiedLiveSessionsCount -gt 0) {
    $deficitsRemainingDescriptions += "$nonCertifiedLiveSessionsCount live session(s) were excluded because they did not clear grounded certification."
}
if ($weakOrInsufficientSessionsCount -gt 0) {
    $deficitsRemainingDescriptions += "$weakOrInsufficientSessionsCount weak or insufficient session(s) do not reduce the responsive promotion gap."
}
if ($strongSignalMissing -gt 0) {
    $deficitsRemainingDescriptions += "$strongSignalMissing additional grounded conservative strong-signal session(s) would still be needed to satisfy the keep-conservative strong-signal threshold."
}

$responsiveBlockReasons = @()
if (-not [string]::IsNullOrWhiteSpace($gateExplanation)) {
    $responsiveBlockReasons += $gateExplanation
}
$responsiveBlockReasons += @((Get-ObjectPropertyValue -Object $gate -Name "missing_evidence" -Default @()))
if ($workflowValidationOnlySessionsCount -gt 0) {
    $responsiveBlockReasons += "Synthetic and rehearsal workflow-validation sessions are excluded from responsive promotion."
}
if ($weakOrInsufficientSessionsCount -gt 0) {
    $responsiveBlockReasons += "Weak-signal and insufficient-data sessions do not reduce the responsive promotion gap."
}
if ($responsiveOverreactionHistoryActive) {
    $responsiveBlockReasons += "Grounded responsive overreaction history is active and blocks another responsive promotion."
}
if ($manualReviewNeeded) {
    $responsiveBlockReasons += "Manual review is required before another live profile choice."
}
$responsiveBlockReasons = Get-UniqueStringList -Items $responsiveBlockReasons
$deficitsRemainingDescriptions = Get-UniqueStringList -Items $deficitsRemainingDescriptions

$recommendedNextLiveProfile = "conservative"
$recommendedNextSessionObjective = ""
$sessionTargetPriorities = @()
$canReducePromotionGap = $false
$couldOpenResponsiveGateIfSuccessful = $false
$anotherConservativeSessionRequiredAfterThis = $null
$objectiveExplanation = ""

$oneMoreConservativeSessionCouldOpenResponsive = (
    $groundedSessionsMissing -le 1 -and
    $groundedTooQuietMissing -le 1 -and
    $groundedTooQuietDistinctPairIdsMissing -le 1 -and
    $groundedAppropriateExcess -eq 0 -and
    -not $manualReviewNeeded -and
    -not $responsiveOverreactionHistoryActive
)

if ($manualReviewNeeded) {
    $recommendedNextSessionObjective = "manual-review-before-next-session"
    $sessionTargetPriorities = @("manual-review")
    $objectiveExplanation = "The grounded evidence is conflicting or risk-signaling, so the next operator action is manual review rather than another blind live profile choice."
}
elseif ($responsiveOverreactionHistoryActive) {
    $recommendedNextSessionObjective = "responsive-blocked-by-overreaction-history"
    $sessionTargetPriorities = @("manual-review")
    $objectiveExplanation = "Grounded responsive evidence already shows overreaction, so responsive stays blocked until that history is reviewed and conservative is re-established."
}
elseif ($responsiveTrialReady) {
    $recommendedNextLiveProfile = "responsive"
    $recommendedNextSessionObjective = "responsive-trial-ready"
    $sessionTargetPriorities = @(
        "human-presence-duration",
        "patch-while-humans-present",
        "post-patch-observation-window"
    )
    $objectiveExplanation = "The responsive gate is already open on certified grounded evidence, so the next live session can be the bounded responsive trial."
}
elseif ($groundedSessionsCurrent -eq 0) {
    $recommendedNextSessionObjective = "collect-first-grounded-conservative-session"
    $sessionTargetPriorities = @(
        "human-presence-duration",
        "patch-while-humans-present",
        "post-patch-observation-window"
    )
    $canReducePromotionGap = $true
    $anotherConservativeSessionRequiredAfterThis = $true
    $objectiveExplanation = "No certified grounded conservative session exists yet, so the next live conservative run must first clear the grounded certification bar."
}
elseif ($keepConservativeEvidencePresent -and $groundedTooQuietCurrent -eq 0) {
    $recommendedNextSessionObjective = "collect-more-grounded-conservative-sessions"
    $sessionTargetPriorities = @(
        "human-presence-duration",
        "patch-while-humans-present",
        "post-patch-observation-window"
    )
    $canReducePromotionGap = $false
    $couldOpenResponsiveGateIfSuccessful = $false
    $anotherConservativeSessionRequiredAfterThis = $true
    $objectiveExplanation = "Certified grounded conservative evidence already looks acceptable, so another conservative live session would be for continued verification rather than for opening responsive."
}
elseif ($groundedTooQuietCurrent -gt 0 -or $shadowResponsiveCandidateCurrent -gt 0) {
    $recommendedNextSessionObjective = "collect-grounded-conservative-too-quiet-evidence"
    $sessionTargetPriorities = @(
        "repeated-grounded-too-quiet-conservative-evidence",
        "human-presence-duration",
        "patch-while-humans-present",
        "post-patch-observation-window"
    )
    $canReducePromotionGap = $true
    $couldOpenResponsiveGateIfSuccessful = $oneMoreConservativeSessionCouldOpenResponsive
    $anotherConservativeSessionRequiredAfterThis = -not $couldOpenResponsiveGateIfSuccessful
    $objectiveExplanation = "Grounded conservative evidence is already trending too quiet, so the next live conservative session should try to repeat that grounded too-quiet result under another certified real session."
}
else {
    $recommendedNextSessionObjective = "collect-more-grounded-conservative-sessions"
    $sessionTargetPriorities = @(
        "human-presence-duration",
        "patch-while-humans-present",
        "post-patch-observation-window"
    )
    $canReducePromotionGap = $true
    $couldOpenResponsiveGateIfSuccessful = $oneMoreConservativeSessionCouldOpenResponsive
    $anotherConservativeSessionRequiredAfterThis = -not $couldOpenResponsiveGateIfSuccessful
    $objectiveExplanation = "Some certified grounded conservative evidence exists, but the live record still needs another grounded conservative session before any responsive promotion decision can be justified."
}

$nextSessionProfileDefinition = if ($recommendedNextLiveProfile -eq "responsive") {
    $responsiveProfile
}
else {
    $conservativeProfile
}

$targetMinHumanSnapshots = if ($recommendedNextLiveProfile -eq "responsive") {
    [int](Get-ObjectPropertyValue -Object $trialDefaults -Name "min_human_snapshots" -Default ([int]$nextSessionProfileDefinition.evaluation.min_human_snapshots))
}
else {
    [int]$nextSessionProfileDefinition.evaluation.min_human_snapshots
}

$targetMinHumanPresenceSeconds = if ($recommendedNextLiveProfile -eq "responsive") {
    [double](Get-ObjectPropertyValue -Object $trialDefaults -Name "min_human_presence_seconds" -Default ([double]$nextSessionProfileDefinition.evaluation.min_human_presence_seconds))
}
else {
    [double]$nextSessionProfileDefinition.evaluation.min_human_presence_seconds
}

$targetMinPatchEventsWhileHumansPresent = [int]$nextSessionProfileDefinition.evaluation.min_patch_events_for_usable_lane
$targetMinPostPatchObservationSeconds = [double](Get-ObjectPropertyValue -Object $trialDefaults -Name "min_post_patch_observation_seconds" -Default 20.0)

$sessionTarget = New-SessionTarget `
    -TreatmentProfile $recommendedNextLiveProfile `
    -TrialDefaults $trialDefaults `
    -TargetMinHumanSnapshots $targetMinHumanSnapshots `
    -TargetMinHumanPresenceSeconds $targetMinHumanPresenceSeconds `
    -TargetMinPatchEventsWhileHumansPresent $targetMinPatchEventsWhileHumansPresent `
    -TargetMinPostPatchObservationSeconds $targetMinPostPatchObservationSeconds `
    -CanReducePromotionGap $canReducePromotionGap `
    -CouldOpenResponsiveGateIfSuccessful $couldOpenResponsiveGateIfSuccessful `
    -AnotherConservativeSessionRequiredAfterThis $anotherConservativeSessionRequiredAfterThis `
    -Priorities $sessionTargetPriorities

$explanationParts = @($objectiveExplanation)
if (-not [string]::IsNullOrWhiteSpace($gateExplanation) -and $gateExplanation -ne $objectiveExplanation) {
    $explanationParts += $gateExplanation
}
if ($recommendedNextSessionObjective -eq "collect-first-grounded-conservative-session") {
    $explanationParts += "Use the next live conservative session to meet the explicit human-presence, human-present patch, and post-patch observation thresholds so the run can count as certified grounded evidence."
}
elseif ($recommendedNextSessionObjective -eq "collect-grounded-conservative-too-quiet-evidence") {
    $explanationParts += "One more certified grounded conservative too-quiet session could open responsive only if it also satisfies the remaining grounded-session and distinct-pair thresholds."
}

$plan = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    registry_path = $resolvedRegistryPath
    output_root = $resolvedOutputRoot
    registry_summary_json = $resolvedRegistrySummaryPath
    profile_recommendation_json = $resolvedProfileRecommendationPath
    responsive_trial_gate_json = $resolvedResponsiveTrialGatePath
    gate_config_path = $resolvedGateConfigPath
    promotion_evidence_scope = "certified-grounded-only"
    current_responsive_gate_verdict = $gateVerdict
    current_responsive_gate_next_live_action = $gateNextLiveAction
    current_default_live_treatment_profile = $currentDefaultLiveTreatmentProfile
    current_registry_recommendation_decision = $profileDecision
    current_certified_grounded_session_counts = [ordered]@{
        total = $totalCertifiedGroundedSessions
        conservative = $groundedSessionsCurrent
        responsive = [int](Get-ObjectPropertyValue -Object $responsiveRiskEvidenceCounts -Name "real_grounded_count" -Default 0)
    }
    current_grounded_conservative_too_quiet_count = $groundedTooQuietCurrent
    current_grounded_responsive_too_reactive_count = $responsiveOverreactionBlockersCurrent
    current_grounded_tuning_usable_count = $groundedTuningUsableCurrent
    current_grounded_strong_signal_count = $groundedStrongSignalCurrent
    evidence_gap = [ordered]@{
        grounded_sessions_scope = "responsive-promotion"
        grounded_sessions_required = $groundedSessionsRequired
        grounded_sessions_current = $groundedSessionsCurrent
        grounded_sessions_missing = $groundedSessionsMissing
        grounded_too_quiet_scope = "responsive-promotion"
        grounded_too_quiet_required = $groundedTooQuietRequired
        grounded_too_quiet_current = $groundedTooQuietCurrent
        grounded_too_quiet_missing = $groundedTooQuietMissing
        grounded_too_quiet_distinct_pair_ids_required = $groundedTooQuietDistinctPairIdsRequired
        grounded_too_quiet_distinct_pair_ids_current = $groundedTooQuietDistinctPairIdsCurrent
        grounded_too_quiet_distinct_pair_ids_missing = $groundedTooQuietDistinctPairIdsMissing
        grounded_appropriate_max_for_responsive_trial = $groundedAppropriateMaxForResponsiveTrial
        grounded_appropriate_current = $groundedAppropriateCurrent
        grounded_appropriate_excess = $groundedAppropriateExcess
        strong_signal_scope = "keep-conservative-evidence"
        strong_signal_required = $strongSignalRequired
        strong_signal_current = $strongSignalCurrent
        strong_signal_missing = $strongSignalMissing
        grounded_tuning_usable_current = $groundedTuningUsableCurrent
        responsive_overreaction_blockers_current = $responsiveOverreactionBlockersCurrent
        responsive_overreaction_blocker_threshold = $responsiveOverreactionBlockerThreshold
        conservative_overreaction_blockers_current = $conservativeTooReactiveCurrent
        synthetic_or_rehearsal_evidence_excluded = $true
        weak_or_insufficient_evidence_excluded = $true
        workflow_validation_only_sessions_count = $workflowValidationOnlySessionsCount
        weak_or_insufficient_sessions_count = $weakOrInsufficientSessionsCount
        non_certified_live_sessions_count = $nonCertifiedLiveSessionsCount
    }
    exclusions = [ordered]@{
        synthetic_or_rehearsal_evidence_excluded = $true
        weak_or_insufficient_evidence_excluded = $true
        workflow_validation_only_sessions_count = $workflowValidationOnlySessionsCount
        weak_or_insufficient_sessions_count = $weakOrInsufficientSessionsCount
        non_certified_live_sessions_count = $nonCertifiedLiveSessionsCount
        excluded_sessions_by_reason = $excludedSessionsByReason
    }
    responsive_block_reasons = @($responsiveBlockReasons)
    deficits_remaining_descriptions = @($deficitsRemainingDescriptions)
    recommended_next_live_profile = $recommendedNextLiveProfile
    recommended_next_session_objective = $recommendedNextSessionObjective
    session_target = $sessionTarget
    supporting_pair_ids = @((Get-ObjectPropertyValue -Object $gate -Name "supporting_pair_ids" -Default @()))
    explanation = (($explanationParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
}

$nextLivePlanJsonPath = Join-Path $resolvedOutputRoot "next_live_plan.json"
$nextLivePlanMarkdownPath = Join-Path $resolvedOutputRoot "next_live_plan.md"

Write-JsonFile -Path $nextLivePlanJsonPath -Value $plan
Write-TextFile -Path $nextLivePlanMarkdownPath -Value (Get-NextLivePlanMarkdown -Plan $plan)

Write-Host "Next live session plan:"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Next-live plan JSON: $nextLivePlanJsonPath"
Write-Host "  Next-live plan Markdown: $nextLivePlanMarkdownPath"
Write-Host "  Responsive gate verdict: $gateVerdict"
Write-Host "  Recommended next live profile: $recommendedNextLiveProfile"
Write-Host "  Recommended next-session objective: $recommendedNextSessionObjective"

[pscustomobject]@{
    RegistryPath = $resolvedRegistryPath
    OutputRoot = $resolvedOutputRoot
    NextLivePlanJsonPath = $nextLivePlanJsonPath
    NextLivePlanMarkdownPath = $nextLivePlanMarkdownPath
    ResponsiveGateVerdict = $gateVerdict
    RecommendedLiveProfile = $recommendedNextLiveProfile
    RecommendedNextSessionObjective = $recommendedNextSessionObjective
}
