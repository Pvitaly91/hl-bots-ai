function Get-PairSessionCertificationObjectPropertyValue {
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

function Test-PairSessionUsableHumanSignal {
    param([string]$Label)

    $value = [string]$Label
    return $value -match '(^human-(usable|rich)$)|(-(human-usable|human-rich)$)'
}

function Get-PairSessionEvidenceBucket {
    param(
        [string]$PairClassification,
        [string]$ComparisonVerdict,
        [string]$ControlEvidenceQuality,
        [string]$TreatmentEvidenceQuality,
        [bool]$SessionIsTuningUsable
    )

    if ($PairClassification -eq "strong-signal" -or $ComparisonVerdict -eq "comparison-strong-signal") {
        return "strong-signal"
    }

    if ($SessionIsTuningUsable -or $PairClassification -eq "tuning-usable" -or $ComparisonVerdict -eq "comparison-usable") {
        return "tuning-usable"
    }

    if (
        $PairClassification -eq "partially usable" -or
        $ComparisonVerdict -eq "comparison-weak-signal" -or
        $ControlEvidenceQuality -eq "weak-signal" -or
        $TreatmentEvidenceQuality -eq "weak-signal"
    ) {
        return "weak-signal"
    }

    return "insufficient-data"
}

function Get-PairSessionResolvedEvidenceOrigin {
    param(
        [string]$EvidenceOrigin,
        [bool]$RehearsalMode,
        [bool]$Synthetic,
        [bool]$ValidationOnly
    )

    $normalized = [string]$EvidenceOrigin
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
        return $normalized.Trim().ToLowerInvariant()
    }

    if ($Synthetic) {
        return "synthetic"
    }

    if ($RehearsalMode) {
        return "rehearsal"
    }

    if ($ValidationOnly) {
        return "validation"
    }

    return "live"
}

function Get-PairSessionCertificationReasonText {
    param([string]$ReasonCode)

    switch ($ReasonCode) {
        "evidence-origin-rehearsal" { return "the evidence origin is rehearsal" }
        "evidence-origin-synthetic" { return "the evidence origin is synthetic" }
        "evidence-origin-not-live" { return "the evidence origin is not a real live session" }
        "rehearsal-mode" { return "the pair pack is marked as rehearsal mode" }
        "synthetic-evidence" { return "the pair pack is marked synthetic" }
        "workflow-validation-only" { return "the pair pack is marked as workflow validation only" }
        "pair-classification-plumbing-valid-only" { return "the pair classification is only plumbing-valid" }
        "pair-classification-below-tuning-usable" { return "the pair classification is below tuning-usable" }
        "comparison-verdict-insufficient-data" { return "the comparison verdict is insufficient-data" }
        "comparison-verdict-below-usable" { return "the comparison verdict is below usable" }
        "control-evidence-insufficient-data" { return "the control lane evidence quality is insufficient-data" }
        "control-evidence-weak-signal" { return "the control lane evidence quality is weak-signal" }
        "control-evidence-below-usable" { return "the control lane evidence quality is below usable-signal" }
        "treatment-evidence-insufficient-data" { return "the treatment lane evidence quality is insufficient-data" }
        "treatment-evidence-weak-signal" { return "the treatment lane evidence quality is weak-signal" }
        "treatment-evidence-below-usable" { return "the treatment lane evidence quality is below usable-signal" }
        "treatment-never-patched-while-humans-present" { return "treatment never patched while humans were present" }
        "no-meaningful-post-patch-observation-window" { return "no meaningful post-patch observation window exists" }
        "minimum-human-signal-thresholds-not-met" { return "the minimum required human-signal thresholds were not met in both lanes" }
        default { return $ReasonCode }
    }
}

function Get-PairSessionCertificationReasonLines {
    param([string[]]$ReasonCodes)

    $lines = @()
    foreach ($reasonCode in @($ReasonCodes | Select-Object -Unique)) {
        $lines += Get-PairSessionCertificationReasonText -ReasonCode $reasonCode
    }

    return $lines
}

function Get-PairSessionMinimumHumanSignalResult {
    param(
        [int]$MinHumanSnapshots,
        [double]$MinHumanPresenceSeconds,
        [int]$ControlHumanSnapshotsCount,
        [int]$TreatmentHumanSnapshotsCount,
        [double]$ControlSecondsWithHumanPresence,
        [double]$TreatmentSecondsWithHumanPresence,
        [string]$ControlHumanSignalVerdict,
        [string]$TreatmentHumanSignalVerdict
    )

    $thresholdsAvailable = $MinHumanSnapshots -gt 0 -and $MinHumanPresenceSeconds -gt 0
    $controlCountsAvailable = $ControlHumanSnapshotsCount -ge 0 -and $ControlSecondsWithHumanPresence -ge 0
    $treatmentCountsAvailable = $TreatmentHumanSnapshotsCount -ge 0 -and $TreatmentSecondsWithHumanPresence -ge 0

    $controlMeets = if ($thresholdsAvailable -and $controlCountsAvailable) {
        $ControlHumanSnapshotsCount -ge $MinHumanSnapshots -and $ControlSecondsWithHumanPresence -ge $MinHumanPresenceSeconds
    }
    else {
        Test-PairSessionUsableHumanSignal -Label $ControlHumanSignalVerdict
    }

    $treatmentMeets = if ($thresholdsAvailable -and $treatmentCountsAvailable) {
        $TreatmentHumanSnapshotsCount -ge $MinHumanSnapshots -and $TreatmentSecondsWithHumanPresence -ge $MinHumanPresenceSeconds
    }
    else {
        Test-PairSessionUsableHumanSignal -Label $TreatmentHumanSignalVerdict
    }

    return [ordered]@{
        thresholds_available = $thresholdsAvailable
        used_numeric_thresholds = $thresholdsAvailable -and $controlCountsAvailable -and $treatmentCountsAvailable
        control_meets = $controlMeets
        treatment_meets = $treatmentMeets
        both_meet = $controlMeets -and $treatmentMeets
    }
}

function Get-PairSessionGroundedEvidenceCertification {
    param(
        [string]$PairId = "",
        [string]$PairRoot = "",
        [string]$TreatmentProfile = "",
        [string]$EvidenceOrigin = "",
        [bool]$RehearsalMode = $false,
        [bool]$Synthetic = $false,
        [bool]$ValidationOnly = $false,
        [string]$PairClassification = "",
        [string]$ComparisonVerdict = "",
        [string]$ControlEvidenceQuality = "",
        [string]$TreatmentEvidenceQuality = "",
        [string]$ControlHumanSignalVerdict = "",
        [string]$TreatmentHumanSignalVerdict = "",
        [int]$MinHumanSnapshots = 0,
        [double]$MinHumanPresenceSeconds = 0,
        [int]$ControlHumanSnapshotsCount = -1,
        [int]$TreatmentHumanSnapshotsCount = -1,
        [double]$ControlSecondsWithHumanPresence = -1,
        [double]$TreatmentSecondsWithHumanPresence = -1,
        [bool]$TreatmentPatchedWhileHumansPresent = $false,
        [bool]$MeaningfulPostPatchObservationWindowExists = $false,
        [bool]$SessionIsTuningUsable = $false,
        [bool]$SessionIsStrongSignal = $false,
        [string]$EvidenceBucket = "",
        [string]$ScorecardRecommendation = "",
        [string]$TreatmentBehaviorAssessment = "",
        [string]$ShadowDecision = "",
        [bool]$ShadowManualReviewNeeded = $false,
        [string]$MonitorVerdict = ""
    )

    $resolvedEvidenceOrigin = Get-PairSessionResolvedEvidenceOrigin `
        -EvidenceOrigin $EvidenceOrigin `
        -RehearsalMode $RehearsalMode `
        -Synthetic $Synthetic `
        -ValidationOnly $ValidationOnly

    $workflowValidationOnly = $ValidationOnly -or $Synthetic -or $RehearsalMode -or $resolvedEvidenceOrigin -in @("rehearsal", "synthetic", "validation")
    $resolvedEvidenceBucket = if ([string]::IsNullOrWhiteSpace($EvidenceBucket)) {
        Get-PairSessionEvidenceBucket `
            -PairClassification $PairClassification `
            -ComparisonVerdict $ComparisonVerdict `
            -ControlEvidenceQuality $ControlEvidenceQuality `
            -TreatmentEvidenceQuality $TreatmentEvidenceQuality `
            -SessionIsTuningUsable $SessionIsTuningUsable
    }
    else {
        [string]$EvidenceBucket
    }

    $minimumHumanSignal = Get-PairSessionMinimumHumanSignalResult `
        -MinHumanSnapshots $MinHumanSnapshots `
        -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
        -ControlHumanSnapshotsCount $ControlHumanSnapshotsCount `
        -TreatmentHumanSnapshotsCount $TreatmentHumanSnapshotsCount `
        -ControlSecondsWithHumanPresence $ControlSecondsWithHumanPresence `
        -TreatmentSecondsWithHumanPresence $TreatmentSecondsWithHumanPresence `
        -ControlHumanSignalVerdict $ControlHumanSignalVerdict `
        -TreatmentHumanSignalVerdict $TreatmentHumanSignalVerdict

    $pairClassificationStrongEnough = $PairClassification -in @("tuning-usable", "strong-signal")
    $comparisonVerdictStrongEnough = $ComparisonVerdict -in @("comparison-usable", "comparison-strong-signal")
    $controlEvidenceStrongEnough = $ControlEvidenceQuality -in @("usable-signal", "strong-signal")
    $treatmentEvidenceStrongEnough = $TreatmentEvidenceQuality -in @("usable-signal", "strong-signal")
    $sessionEvidenceStrongEnough = $resolvedEvidenceBucket -in @("tuning-usable", "strong-signal") -or $SessionIsTuningUsable -or $pairClassificationStrongEnough -or $comparisonVerdictStrongEnough
    $resolvedSessionIsStrongSignal = $SessionIsStrongSignal -or $resolvedEvidenceBucket -eq "strong-signal" -or $PairClassification -eq "strong-signal" -or $ComparisonVerdict -eq "comparison-strong-signal"

    $reasons = @()
    switch ($resolvedEvidenceOrigin) {
        "rehearsal" { $reasons += "evidence-origin-rehearsal" }
        "synthetic" { $reasons += "evidence-origin-synthetic" }
        "live" { }
        default { $reasons += "evidence-origin-not-live" }
    }

    if ($RehearsalMode) {
        $reasons += "rehearsal-mode"
    }

    if ($Synthetic) {
        $reasons += "synthetic-evidence"
    }

    if ($workflowValidationOnly) {
        $reasons += "workflow-validation-only"
    }

    if ($PairClassification -eq "plumbing-valid only") {
        $reasons += "pair-classification-plumbing-valid-only"
    }
    elseif (-not $pairClassificationStrongEnough) {
        $reasons += "pair-classification-below-tuning-usable"
    }

    if ($ComparisonVerdict -eq "comparison-insufficient-data") {
        $reasons += "comparison-verdict-insufficient-data"
    }
    elseif (-not $comparisonVerdictStrongEnough) {
        $reasons += "comparison-verdict-below-usable"
    }

    if ($ControlEvidenceQuality -eq "insufficient-data") {
        $reasons += "control-evidence-insufficient-data"
    }
    elseif ($ControlEvidenceQuality -eq "weak-signal") {
        $reasons += "control-evidence-weak-signal"
    }
    elseif (-not $controlEvidenceStrongEnough) {
        $reasons += "control-evidence-below-usable"
    }

    if ($TreatmentEvidenceQuality -eq "insufficient-data") {
        $reasons += "treatment-evidence-insufficient-data"
    }
    elseif ($TreatmentEvidenceQuality -eq "weak-signal") {
        $reasons += "treatment-evidence-weak-signal"
    }
    elseif (-not $treatmentEvidenceStrongEnough) {
        $reasons += "treatment-evidence-below-usable"
    }

    if (-not $TreatmentPatchedWhileHumansPresent) {
        $reasons += "treatment-never-patched-while-humans-present"
    }

    if (-not $MeaningfulPostPatchObservationWindowExists) {
        $reasons += "no-meaningful-post-patch-observation-window"
    }

    if (-not $minimumHumanSignal.both_meet) {
        $reasons += "minimum-human-signal-thresholds-not-met"
    }

    if (-not $sessionEvidenceStrongEnough -and $reasons -notcontains "pair-classification-below-tuning-usable") {
        $reasons += "pair-classification-below-tuning-usable"
    }

    $reasonCodes = @($reasons | Select-Object -Unique)
    $reasonLines = @(Get-PairSessionCertificationReasonLines -ReasonCodes $reasonCodes)
    $manualReviewNeeded = $ScorecardRecommendation -eq "manual-review-needed" -or $ShadowDecision -eq "manual-review-needed" -or $ShadowManualReviewNeeded
    $countsTowardPromotion = $reasonCodes.Count -eq 0
    $certificationVerdict = if ($countsTowardPromotion) { "certified-grounded-evidence" } else { "excluded-not-grounded-evidence" }
    $explanation = if ($countsTowardPromotion) {
        "This session counts as real grounded promotion evidence because it is a live non-synthetic session, both lanes cleared the minimum human-signal bar, treatment patched while humans were present, a meaningful post-patch observation window exists, and the pair cleared the tuning-usable threshold."
    }
    else {
        "This session does not count toward responsive-gate promotion thresholds because " + (($reasonLines -join "; ") + ".")
    }

    return [ordered]@{
        schema_version = 1
        pair_id = $PairId
        pair_root = $PairRoot
        treatment_profile = $TreatmentProfile
        certification_verdict = $certificationVerdict
        certified_grounded_evidence = $countsTowardPromotion
        explanation = $explanation
        evidence_origin = $resolvedEvidenceOrigin
        rehearsal_mode = $RehearsalMode
        synthetic = $Synthetic
        validation_only = $ValidationOnly
        counts_only_as_workflow_validation = $workflowValidationOnly
        counts_toward_responsive_gate_thresholds = $countsTowardPromotion
        counts_toward_promotion = $countsTowardPromotion
        excluded_from_promotion = -not $countsTowardPromotion
        manual_review_needed = $manualReviewNeeded
        exclusion_reasons = $reasonCodes
        exclusion_reason_details = $reasonLines
        control_evidence_quality = $ControlEvidenceQuality
        treatment_evidence_quality = $TreatmentEvidenceQuality
        pair_classification = $PairClassification
        comparison_verdict = $ComparisonVerdict
        evidence_bucket = $resolvedEvidenceBucket
        session_is_tuning_usable = $sessionEvidenceStrongEnough
        session_is_strong_signal = $resolvedSessionIsStrongSignal
        control_human_signal_verdict = $ControlHumanSignalVerdict
        treatment_human_signal_verdict = $TreatmentHumanSignalVerdict
        min_required_human_snapshots = $MinHumanSnapshots
        min_required_human_presence_seconds = $MinHumanPresenceSeconds
        control_human_snapshots_count = $ControlHumanSnapshotsCount
        treatment_human_snapshots_count = $TreatmentHumanSnapshotsCount
        control_seconds_with_human_presence = $ControlSecondsWithHumanPresence
        treatment_seconds_with_human_presence = $TreatmentSecondsWithHumanPresence
        control_meets_minimum_human_signal = $minimumHumanSignal.control_meets
        treatment_meets_minimum_human_signal = $minimumHumanSignal.treatment_meets
        minimum_human_signal_thresholds_met = $minimumHumanSignal.both_meet
        human_signal_thresholds_available = $minimumHumanSignal.thresholds_available
        used_numeric_human_signal_thresholds = $minimumHumanSignal.used_numeric_thresholds
        treatment_patched_while_humans_present = $TreatmentPatchedWhileHumansPresent
        meaningful_post_patch_observation_window_exists = $MeaningfulPostPatchObservationWindowExists
        scorecard_recommendation = $ScorecardRecommendation
        treatment_behavior_assessment = $TreatmentBehaviorAssessment
        shadow_decision = $ShadowDecision
        monitor_verdict = $MonitorVerdict
    }
}

function Get-PairSessionGroundedEvidenceCertificationFromRegistryEntry {
    param([object]$Entry)

    return Get-PairSessionGroundedEvidenceCertification `
        -PairId ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "pair_id" -Default "")) `
        -PairRoot ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "pair_root" -Default "")) `
        -TreatmentProfile ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "treatment_profile" -Default "")) `
        -EvidenceOrigin ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "evidence_origin" -Default "")) `
        -RehearsalMode ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "rehearsal_mode" -Default $false)) `
        -Synthetic ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "synthetic_fixture" -Default $false)) `
        -ValidationOnly ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "validation_only" -Default $false)) `
        -PairClassification ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "pair_classification" -Default "")) `
        -ComparisonVerdict ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "comparison_verdict" -Default "")) `
        -ControlEvidenceQuality ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "control_evidence_quality" -Default "")) `
        -TreatmentEvidenceQuality ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "treatment_evidence_quality" -Default "")) `
        -ControlHumanSignalVerdict ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "control_human_signal_verdict" -Default "")) `
        -TreatmentHumanSignalVerdict ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "treatment_human_signal_verdict" -Default "")) `
        -MinHumanSnapshots ([int](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "min_human_snapshots" -Default 0)) `
        -MinHumanPresenceSeconds ([double](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "min_human_presence_seconds" -Default 0.0)) `
        -ControlHumanSnapshotsCount ([int](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "control_human_snapshots_count" -Default -1)) `
        -TreatmentHumanSnapshotsCount ([int](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "treatment_human_snapshots_count" -Default -1)) `
        -ControlSecondsWithHumanPresence ([double](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "control_seconds_with_human_presence" -Default -1.0)) `
        -TreatmentSecondsWithHumanPresence ([double](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "treatment_seconds_with_human_presence" -Default -1.0)) `
        -TreatmentPatchedWhileHumansPresent ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "treatment_patched_while_humans_present" -Default $false)) `
        -MeaningfulPostPatchObservationWindowExists ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "meaningful_post_patch_observation_window_exists" -Default $false)) `
        -SessionIsTuningUsable ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "session_is_tuning_usable" -Default $false)) `
        -SessionIsStrongSignal ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "session_is_strong_signal" -Default $false)) `
        -EvidenceBucket ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "evidence_bucket" -Default "")) `
        -ScorecardRecommendation ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "scorecard_recommendation" -Default "")) `
        -TreatmentBehaviorAssessment ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "scorecard_treatment_behavior_assessment" -Default "")) `
        -ShadowDecision ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "shadow_recommendation_decision" -Default "")) `
        -ShadowManualReviewNeeded ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "shadow_manual_review_needed" -Default $false)) `
        -MonitorVerdict ([string](Get-PairSessionCertificationObjectPropertyValue -Object $Entry -Name "monitor_verdict" -Default ""))
}

function Write-PairSessionCertificationJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 14
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Write-PairSessionCertificationTextFile {
    param(
        [string]$Path,
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Get-PairSessionGroundedEvidenceCertificateMarkdown {
    param([object]$Certificate)

    $lines = @(
        "# Grounded Evidence Certificate",
        "",
        "- Pair ID: $($Certificate.pair_id)",
        "- Pair root: $($Certificate.pair_root)",
        "- Treatment profile: $($Certificate.treatment_profile)",
        "- Certification verdict: $($Certificate.certification_verdict)",
        "- Counts toward responsive-gate thresholds: $($Certificate.counts_toward_responsive_gate_thresholds)",
        "- Counts only as workflow validation: $($Certificate.counts_only_as_workflow_validation)",
        "- Manual review needed: $($Certificate.manual_review_needed)",
        "- Evidence origin: $($Certificate.evidence_origin)",
        "- Rehearsal mode: $($Certificate.rehearsal_mode)",
        "- Synthetic: $($Certificate.synthetic)",
        "- Validation only: $($Certificate.validation_only)",
        "- Explanation: $($Certificate.explanation)",
        "",
        "## Evidence Quality",
        "",
        "- Pair classification: $($Certificate.pair_classification)",
        "- Comparison verdict: $($Certificate.comparison_verdict)",
        "- Evidence bucket: $($Certificate.evidence_bucket)",
        "- Control evidence quality: $($Certificate.control_evidence_quality)",
        "- Treatment evidence quality: $($Certificate.treatment_evidence_quality)",
        "- Session is tuning-usable: $($Certificate.session_is_tuning_usable)",
        "- Session is strong-signal: $($Certificate.session_is_strong_signal)",
        "",
        "## Human Signal",
        "",
        "- Minimum required human snapshots: $($Certificate.min_required_human_snapshots)",
        "- Minimum required human presence seconds: $($Certificate.min_required_human_presence_seconds)",
        "- Control human signal verdict: $($Certificate.control_human_signal_verdict)",
        "- Treatment human signal verdict: $($Certificate.treatment_human_signal_verdict)",
        "- Control human snapshots: $($Certificate.control_human_snapshots_count)",
        "- Treatment human snapshots: $($Certificate.treatment_human_snapshots_count)",
        "- Control seconds with human presence: $($Certificate.control_seconds_with_human_presence)",
        "- Treatment seconds with human presence: $($Certificate.treatment_seconds_with_human_presence)",
        "- Control meets minimum human signal: $($Certificate.control_meets_minimum_human_signal)",
        "- Treatment meets minimum human signal: $($Certificate.treatment_meets_minimum_human_signal)",
        "- Minimum human signal thresholds met: $($Certificate.minimum_human_signal_thresholds_met)",
        "",
        "## Treatment Reaction",
        "",
        "- Treatment patched while humans were present: $($Certificate.treatment_patched_while_humans_present)",
        "- Meaningful post-patch observation window exists: $($Certificate.meaningful_post_patch_observation_window_exists)",
        "- Scorecard recommendation: $($Certificate.scorecard_recommendation)",
        "- Treatment behavior assessment: $($Certificate.treatment_behavior_assessment)",
        "- Shadow decision: $($Certificate.shadow_decision)",
        "- Monitor verdict: $($Certificate.monitor_verdict)",
        "",
        "## Exclusion Reasons",
        ""
    )

    $reasonLines = @($Certificate.exclusion_reason_details)
    if ($reasonLines.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($reasonLine in $reasonLines) {
            $lines += "- $reasonLine"
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}
