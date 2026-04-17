param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
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

    $json = $Value | ConvertTo-Json -Depth 12
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

function Test-UsableHumanSignal {
    param([string]$Label)

    $value = [string]$Label
    return $value -match '(^human-(usable|rich)$)|(-(human-usable|human-rich)$)'
}

function Get-TreatmentBehaviorAssessment {
    param(
        [string]$PairClassification,
        [string]$ComparisonVerdict,
        [string]$TreatmentProfile,
        [string]$TreatmentBehaviorVerdict,
        [string]$TreatmentEvidenceQuality,
        [bool]$ControlUsableHumanSignal,
        [bool]$TreatmentUsableHumanSignal,
        [bool]$TreatmentPatchedWhileHumansPresent,
        [bool]$MeaningfulPostPatchObservationWindowExists,
        [string]$TreatmentRelativeToControl,
        [bool]$RelativeBehaviorDiscussionReady,
        [bool]$ApparentBenefitTooWeakToTrust,
        [bool]$CooldownConstraintsRespected,
        [bool]$BoundednessConstraintsRespected
    )

    if ($TreatmentBehaviorVerdict -eq "oscillatory" -or -not $CooldownConstraintsRespected -or -not $BoundednessConstraintsRespected) {
        return "too reactive"
    }

    if ($PairClassification -eq "plumbing-valid only" -or $ComparisonVerdict -eq "comparison-insufficient-data") {
        return "inconclusive"
    }

    if (
        $TreatmentProfile -eq "conservative" -and
        $ControlUsableHumanSignal -and
        $TreatmentUsableHumanSignal -and
        -not $TreatmentPatchedWhileHumansPresent -and
        -not $MeaningfulPostPatchObservationWindowExists -and
        $TreatmentRelativeToControl -eq "quieter"
    ) {
        return "too quiet"
    }

    if (
        $TreatmentProfile -eq "conservative" -and
        $TreatmentEvidenceQuality -eq "weak-signal" -and
        $ControlUsableHumanSignal -and
        $TreatmentUsableHumanSignal -and
        $TreatmentRelativeToControl -eq "quieter" -and
        -not $MeaningfulPostPatchObservationWindowExists
    ) {
        return "too quiet"
    }

    if (
        $TreatmentProfile -eq "conservative" -and
        $RelativeBehaviorDiscussionReady -and
        $TreatmentEvidenceQuality -in @("usable-signal", "strong-signal") -and
        $TreatmentPatchedWhileHumansPresent -and
        $MeaningfulPostPatchObservationWindowExists -and
        -not $ApparentBenefitTooWeakToTrust
    ) {
        return "appropriately conservative"
    }

    return "inconclusive"
}

function Get-Recommendation {
    param(
        [string]$PairClassification,
        [string]$ComparisonVerdict,
        [string]$ControlEvidenceQuality,
        [string]$TreatmentEvidenceQuality,
        [string]$TreatmentProfile,
        [string]$TreatmentBehaviorAssessment,
        [bool]$TreatmentPatchedWhileHumansPresent,
        [bool]$MeaningfulPostPatchObservationWindowExists
    )

    if (
        $PairClassification -eq "plumbing-valid only" -or
        $ComparisonVerdict -eq "comparison-insufficient-data" -or
        ($ControlEvidenceQuality -eq "insufficient-data" -and $TreatmentEvidenceQuality -eq "insufficient-data")
    ) {
        return [pscustomobject]@{
            Key = "insufficient-data-repeat-session"
            Reason = "The pair never cleared the human-signal gate, so it should be treated as plumbing validation only and repeated before any tuning decision."
            SuggestedNextStep = "Repeat the conservative pair session with a real human in both lanes and only score it again after review_latest_pair_run.ps1."
        }
    }

    if ($TreatmentBehaviorAssessment -eq "too reactive") {
        return [pscustomobject]@{
            Key = "review-artifacts-manually"
            Reason = "The treatment lane looked oscillatory or violated a guardrail, so the lane artifacts need manual inspection before choosing another profile."
            SuggestedNextStep = "Open comparison.md and the treatment summary/session pack before scheduling another live profile change."
        }
    }

    if ($TreatmentBehaviorAssessment -eq "too quiet" -and $TreatmentProfile -eq "conservative") {
        return [pscustomobject]@{
            Key = "conservative-looks-too-quiet-try-responsive-next"
            Reason = "Humans were present long enough to compare lanes, but conservative stayed quieter than control without grounded human-present patch evidence."
            SuggestedNextStep = "Preserve this pair pack, then plan the next live pair with the responsive profile."
        }
    }

    if ($ComparisonVerdict -eq "comparison-strong-signal" -and $TreatmentBehaviorAssessment -eq "appropriately conservative") {
        return [pscustomobject]@{
            Key = "keep-conservative-and-collect-more"
            Reason = "Conservative produced grounded post-patch evidence without looking overactive, so it remains the safest live default."
            SuggestedNextStep = "Keep conservative as the next live profile and collect another comparable human pair session."
        }
    }

    if (($PairClassification -eq "tuning-usable" -or $ComparisonVerdict -eq "comparison-usable") -and $TreatmentBehaviorAssessment -eq "appropriately conservative") {
        return [pscustomobject]@{
            Key = "treatment-evidence-promising-repeat-conservative"
            Reason = "The treatment lane produced usable human-present evidence and conservative does not look too quiet or too reactive yet."
            SuggestedNextStep = "Repeat another conservative human pair session before considering a profile change."
        }
    }

    if (
        $PairClassification -eq "partially usable" -or
        $ComparisonVerdict -eq "comparison-weak-signal" -or
        $ControlEvidenceQuality -eq "weak-signal" -or
        $TreatmentEvidenceQuality -eq "weak-signal"
    ) {
        if ($TreatmentPatchedWhileHumansPresent -or $MeaningfulPostPatchObservationWindowExists) {
            return [pscustomobject]@{
                Key = "treatment-evidence-promising-repeat-conservative"
                Reason = "There is some grounded live treatment signal, but it is still too weak for a profile change."
                SuggestedNextStep = "Repeat conservative first and try to capture a longer post-patch window."
            }
        }

        return [pscustomobject]@{
            Key = "weak-signal-repeat-session"
            Reason = "Humans joined, but grounded post-patch evidence stayed weak, so the session should be repeated before changing profiles."
            SuggestedNextStep = "Repeat the conservative pair with better human presence continuity before considering responsive."
        }
    }

    return [pscustomobject]@{
        Key = "review-artifacts-manually"
        Reason = "The current evidence does not cleanly support a profile-change recommendation."
        SuggestedNextStep = "Inspect comparison.md, scorecard.md, and the treatment summary manually before choosing the next live action."
    }
}

function Get-ScorecardMarkdown {
    param([object]$Scorecard)

    $lines = @(
        "# First Real Human Pair Session Scorecard",
        "",
        "- Pair root: $($Scorecard.pair_root)",
        "- Pair classification: $($Scorecard.pair_classification)",
        "- Comparison verdict: $($Scorecard.comparison_verdict)",
        "- Treatment profile: $($Scorecard.treatment_profile)",
        "- Treatment behavior assessment: $($Scorecard.treatment_behavior_assessment)",
        "- Recommendation: $($Scorecard.recommendation)",
        "- Recommendation reason: $($Scorecard.recommendation_reason)",
        "",
        "## Control Lane",
        "",
        "- Lane verdict: $($Scorecard.control_lane_verdict)",
        "- Evidence quality: $($Scorecard.control_evidence_quality)",
        "- Human signal verdict: $($Scorecard.human_signal.control_human_signal_verdict)",
        "- Human snapshots: $($Scorecard.human_signal.control_human_snapshots_count)",
        "- Seconds with human presence: $($Scorecard.human_signal.control_seconds_with_human_presence)",
        "",
        "## Treatment Lane",
        "",
        "- Lane verdict: $($Scorecard.treatment_lane_verdict)",
        "- Evidence quality: $($Scorecard.treatment_evidence_quality)",
        "- Human signal verdict: $($Scorecard.human_signal.treatment_human_signal_verdict)",
        "- Human snapshots: $($Scorecard.human_signal.treatment_human_snapshots_count)",
        "- Seconds with human presence: $($Scorecard.human_signal.treatment_seconds_with_human_presence)",
        "- Patched while humans were present: $($Scorecard.treatment_patched_while_humans_present)",
        "- Meaningful post-patch observation window: $($Scorecard.meaningful_post_patch_observation_window_exists)",
        "- Patch applies total: $($Scorecard.treatment_patch_signal.patch_apply_count)",
        "- Patch applies while humans present: $($Scorecard.treatment_patch_signal.patch_apply_count_while_humans_present)",
        "- Post-patch observation windows: $($Scorecard.treatment_patch_signal.response_after_patch_observation_window_count)",
        "- Relative to control: $($Scorecard.treatment_patch_signal.treatment_relative_to_control)",
        "- Pre/post trend: $($Scorecard.treatment_patch_signal.treatment_pre_post_trend_classification)",
        "- Behavior verdict: $($Scorecard.treatment_patch_signal.treatment_behavior_verdict)",
        "",
        "## Decision Flags",
        "",
        "- Good enough to keep conservative: $($Scorecard.good_enough_for.keep_conservative)",
        "- Good enough to try responsive next: $($Scorecard.good_enough_for.try_responsive_next)",
        "- Good enough to collect another conservative session first: $($Scorecard.good_enough_for.collect_another_conservative_session_first)",
        "- Reject session as insufficient-data: $($Scorecard.good_enough_for.reject_session_as_insufficient_data)",
        "",
        "## Next Action",
        "",
        "- Recommendation: $($Scorecard.recommendation)",
        "- Reason: $($Scorecard.recommendation_reason)",
        "- Suggested operator next step: $($Scorecard.suggested_operator_next_step)",
        "",
        "## Artifacts",
        "",
        "- Pair summary JSON: $($Scorecard.artifacts.pair_summary_json)",
        "- Pair summary Markdown: $($Scorecard.artifacts.pair_summary_markdown)",
        "- Comparison JSON: $($Scorecard.artifacts.comparison_json)",
        "- Comparison Markdown: $($Scorecard.artifacts.comparison_markdown)",
        "- Control summary Markdown: $($Scorecard.artifacts.control_summary_markdown)",
        "- Treatment summary Markdown: $($Scorecard.artifacts.treatment_summary_markdown)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedPairsRoot = if ([string]::IsNullOrWhiteSpace($PairsRoot)) {
    $resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { $LabRoot }
    Join-Path (Get-LogsRootDefault -LabRoot $resolvedLabRoot) "eval\pairs"
}
else {
    $PairsRoot
}

$resolvedPairRoot = if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    Find-LatestPairRoot -Root $resolvedPairsRoot
}
else {
    Resolve-ExistingPath -Path $PairRoot
}

if ([string]::IsNullOrWhiteSpace($resolvedPairRoot)) {
    throw "Pair root was not found: $PairRoot"
}

$pairSummaryJsonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
if (-not $pairSummaryJsonPath) {
    throw "Pair summary JSON was not found under $resolvedPairRoot"
}

$pairSummary = Read-JsonFile -Path $pairSummaryJsonPath
if ($null -eq $pairSummary) {
    throw "Pair summary JSON could not be parsed: $pairSummaryJsonPath"
}

$artifacts = $pairSummary.artifacts
$comparisonJsonCandidate = if ($artifacts -and $artifacts.comparison_json) { [string]$artifacts.comparison_json } else { Join-Path $resolvedPairRoot "comparison.json" }
$pairSummaryMarkdownCandidate = if ($artifacts -and $artifacts.pair_summary_markdown) { [string]$artifacts.pair_summary_markdown } else { Join-Path $resolvedPairRoot "pair_summary.md" }
$comparisonMarkdownCandidate = if ($artifacts -and $artifacts.comparison_markdown) { [string]$artifacts.comparison_markdown } else { Join-Path $resolvedPairRoot "comparison.md" }

$comparisonJsonPath = Resolve-ExistingPath -Path $comparisonJsonCandidate
$pairSummaryMarkdownPath = Resolve-ExistingPath -Path $pairSummaryMarkdownCandidate
$comparisonMarkdownPath = Resolve-ExistingPath -Path $comparisonMarkdownCandidate

$comparisonPayload = Read-JsonFile -Path $comparisonJsonPath
$comparison = if ($null -ne $comparisonPayload) { $comparisonPayload.comparison } else { $pairSummary.comparison }
$controlLaneSummary = if ($null -ne $comparisonPayload) { $comparisonPayload.primary_lane } else { $null }
$treatmentLaneSummary = if ($null -ne $comparisonPayload) { $comparisonPayload.secondary_lane } else { $null }

if ($null -eq $comparison) {
    throw "Comparison data was not found for $resolvedPairRoot"
}

if ($null -eq $controlLaneSummary) {
    $controlLaneSummary = Read-JsonFile -Path ([string]$pairSummary.control_lane.summary_json)
    if ($null -ne $controlLaneSummary) {
        $controlLaneSummary = $controlLaneSummary.primary_lane
    }
}

if ($null -eq $treatmentLaneSummary) {
    $treatmentLaneSummary = Read-JsonFile -Path ([string]$pairSummary.treatment_lane.summary_json)
    if ($null -ne $treatmentLaneSummary) {
        $treatmentLaneSummary = $treatmentLaneSummary.primary_lane
    }
}

$controlLaneVerdict = [string]$pairSummary.control_lane.lane_verdict
$treatmentLaneVerdict = [string]$pairSummary.treatment_lane.lane_verdict
$controlEvidenceQuality = [string]$pairSummary.control_lane.evidence_quality
$treatmentEvidenceQuality = [string]$pairSummary.treatment_lane.evidence_quality
$pairClassification = [string]$pairSummary.operator_note_classification
$comparisonVerdict = [string]$comparison.comparison_verdict
$treatmentProfile = if ($pairSummary.treatment_profile) { [string]$pairSummary.treatment_profile } else { [string]$pairSummary.treatment_lane.treatment_profile }

$controlHumanSignalVerdict = if ($comparison.control_human_signal_verdict) { [string]$comparison.control_human_signal_verdict } else { [string]$controlLaneVerdict }
$treatmentHumanSignalVerdict = if ($comparison.treatment_human_signal_verdict) { [string]$comparison.treatment_human_signal_verdict } else { [string]$treatmentLaneVerdict }
$controlUsableHumanSignal = Test-UsableHumanSignal -Label $controlHumanSignalVerdict
$treatmentUsableHumanSignal = Test-UsableHumanSignal -Label $treatmentHumanSignalVerdict

$treatmentPatchedWhileHumansPresent = [bool]$comparison.treatment_patched_while_humans_present
$meaningfulPostPatchObservationWindowExists = [bool]$comparison.meaningful_post_patch_observation_window_exists
$treatmentRelativeToControl = [string]$comparison.treatment_relative_to_control
$treatmentPrePostTrendClassification = [string]$comparison.treatment_pre_post_trend_classification
$relativeBehaviorDiscussionReady = [bool]$comparison.relative_behavior_discussion_ready
$apparentBenefitTooWeakToTrust = [bool]$comparison.apparent_benefit_too_weak_to_trust

$treatmentBehaviorVerdict = if ($null -ne $treatmentLaneSummary) { [string]$treatmentLaneSummary.behavior_verdict } else { [string]$pairSummary.treatment_lane.behavior_verdict }
$treatmentBehaviorReason = if ($null -ne $treatmentLaneSummary) { [string]$treatmentLaneSummary.behavior_reason } else { "" }
$cooldownConstraintsRespected = if ($null -ne $treatmentLaneSummary) { [bool]$treatmentLaneSummary.cooldown_constraints_respected } else { $true }
$boundednessConstraintsRespected = if ($null -ne $treatmentLaneSummary) { [bool]$treatmentLaneSummary.boundedness_constraints_respected } else { $true }
$patchApplyCount = if ($null -ne $treatmentLaneSummary) { [int]$treatmentLaneSummary.patch_apply_count } else { [int]$comparison.treatment_patch_apply_count }
$patchApplyCountWhileHumansPresent = if ($null -ne $treatmentLaneSummary) { [int]$treatmentLaneSummary.patch_apply_count_while_humans_present } else { 0 }
$responseAfterPatchObservationWindowCount = if ($null -ne $treatmentLaneSummary) { [int]$treatmentLaneSummary.response_after_patch_observation_window_count } else { 0 }
$humanReactivePatchApplyCount = if ($null -ne $treatmentLaneSummary) { [int]$treatmentLaneSummary.human_reactive_patch_apply_count } else { 0 }

$treatmentBehaviorAssessment = Get-TreatmentBehaviorAssessment `
    -PairClassification $pairClassification `
    -ComparisonVerdict $comparisonVerdict `
    -TreatmentProfile $treatmentProfile `
    -TreatmentBehaviorVerdict $treatmentBehaviorVerdict `
    -TreatmentEvidenceQuality $treatmentEvidenceQuality `
    -ControlUsableHumanSignal $controlUsableHumanSignal `
    -TreatmentUsableHumanSignal $treatmentUsableHumanSignal `
    -TreatmentPatchedWhileHumansPresent $treatmentPatchedWhileHumansPresent `
    -MeaningfulPostPatchObservationWindowExists $meaningfulPostPatchObservationWindowExists `
    -TreatmentRelativeToControl $treatmentRelativeToControl `
    -RelativeBehaviorDiscussionReady $relativeBehaviorDiscussionReady `
    -ApparentBenefitTooWeakToTrust $apparentBenefitTooWeakToTrust `
    -CooldownConstraintsRespected $cooldownConstraintsRespected `
    -BoundednessConstraintsRespected $boundednessConstraintsRespected

$recommendation = Get-Recommendation `
    -PairClassification $pairClassification `
    -ComparisonVerdict $comparisonVerdict `
    -ControlEvidenceQuality $controlEvidenceQuality `
    -TreatmentEvidenceQuality $treatmentEvidenceQuality `
    -TreatmentProfile $treatmentProfile `
    -TreatmentBehaviorAssessment $treatmentBehaviorAssessment `
    -TreatmentPatchedWhileHumansPresent $treatmentPatchedWhileHumansPresent `
    -MeaningfulPostPatchObservationWindowExists $meaningfulPostPatchObservationWindowExists

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) { Join-Path $resolvedPairRoot "scorecard.json" } else { $OutputJson }
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) { Join-Path $resolvedPairRoot "scorecard.md" } else { $OutputMarkdown }

$scorecard = [ordered]@{
    schema_version = 1
    prompt_id = "HLDM-JKBOTTI-AI-STAND-20260415-20"
    source_pair_prompt_id = [string]$pairSummary.prompt_id
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pair_root = $resolvedPairRoot
    pair_id = [string]$pairSummary.pair_id
    pair_classification = $pairClassification
    operator_note = [string]$pairSummary.operator_note
    comparison_verdict = $comparisonVerdict
    comparison_reason = [string]$comparison.comparison_reason
    control_lane_verdict = $controlLaneVerdict
    treatment_lane_verdict = $treatmentLaneVerdict
    control_evidence_quality = $controlEvidenceQuality
    treatment_evidence_quality = $treatmentEvidenceQuality
    treatment_profile = $treatmentProfile
    treatment_patched_while_humans_present = $treatmentPatchedWhileHumansPresent
    meaningful_post_patch_observation_window_exists = $meaningfulPostPatchObservationWindowExists
    treatment_behavior_assessment = $treatmentBehaviorAssessment
    recommendation = [string]$recommendation.Key
    recommendation_reason = [string]$recommendation.Reason
    suggested_operator_next_step = [string]$recommendation.SuggestedNextStep
    good_enough_for = [ordered]@{
        keep_conservative = $recommendation.Key -in @(
            "keep-conservative-and-collect-more",
            "treatment-evidence-promising-repeat-conservative",
            "weak-signal-repeat-session"
        )
        try_responsive_next = $recommendation.Key -eq "conservative-looks-too-quiet-try-responsive-next"
        collect_another_conservative_session_first = $recommendation.Key -in @(
            "keep-conservative-and-collect-more",
            "treatment-evidence-promising-repeat-conservative",
            "weak-signal-repeat-session"
        )
        reject_session_as_insufficient_data = $recommendation.Key -eq "insufficient-data-repeat-session"
    }
    human_signal = [ordered]@{
        control_human_signal_verdict = $controlHumanSignalVerdict
        treatment_human_signal_verdict = $treatmentHumanSignalVerdict
        control_tuning_signal_usable = [bool]$comparison.control_tuning_signal_usable
        treatment_tuning_signal_usable = [bool]$comparison.treatment_tuning_signal_usable
        control_human_snapshots_count = [int]$comparison.control_human_snapshots_count
        treatment_human_snapshots_count = [int]$comparison.treatment_human_snapshots_count
        control_seconds_with_human_presence = [double]$comparison.control_seconds_with_human_presence
        treatment_seconds_with_human_presence = [double]$comparison.treatment_seconds_with_human_presence
    }
    treatment_patch_signal = [ordered]@{
        treatment_relative_to_control = $treatmentRelativeToControl
        treatment_pre_post_trend_classification = $treatmentPrePostTrendClassification
        relative_behavior_discussion_ready = $relativeBehaviorDiscussionReady
        apparent_benefit_too_weak_to_trust = $apparentBenefitTooWeakToTrust
        patch_apply_count = $patchApplyCount
        patch_apply_count_while_humans_present = $patchApplyCountWhileHumansPresent
        response_after_patch_observation_window_count = $responseAfterPatchObservationWindowCount
        human_reactive_patch_apply_count = $humanReactivePatchApplyCount
        treatment_behavior_verdict = $treatmentBehaviorVerdict
        treatment_behavior_reason = $treatmentBehaviorReason
        cooldown_constraints_respected = $cooldownConstraintsRespected
        boundedness_constraints_respected = $boundednessConstraintsRespected
    }
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryJsonPath
        pair_summary_markdown = $pairSummaryMarkdownPath
        comparison_json = $comparisonJsonPath
        comparison_markdown = $comparisonMarkdownPath
        control_summary_markdown = Resolve-ExistingPath -Path ([string]$pairSummary.control_lane.summary_markdown)
        treatment_summary_markdown = Resolve-ExistingPath -Path ([string]$pairSummary.treatment_lane.summary_markdown)
        scorecard_json = $outputJsonPath
        scorecard_markdown = $outputMarkdownPath
    }
}

Write-JsonFile -Path $outputJsonPath -Value $scorecard
Write-TextFile -Path $outputMarkdownPath -Value (Get-ScorecardMarkdown -Scorecard $scorecard)

Write-Host "Pair-session scorecard:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Scorecard JSON: $outputJsonPath"
Write-Host "  Scorecard Markdown: $outputMarkdownPath"
Write-Host "  Pair classification: $pairClassification"
Write-Host "  Treatment behavior assessment: $treatmentBehaviorAssessment"
Write-Host "  Recommendation: $($recommendation.Key)"
Write-Host "  Recommendation reason: $($recommendation.Reason)"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    ScorecardJsonPath = $outputJsonPath
    ScorecardMarkdownPath = $outputMarkdownPath
    PairClassification = $pairClassification
    TreatmentBehaviorAssessment = $treatmentBehaviorAssessment
    Recommendation = [string]$recommendation.Key
    RecommendationReason = [string]$recommendation.Reason
    SuggestedOperatorNextStep = [string]$recommendation.SuggestedNextStep
}
