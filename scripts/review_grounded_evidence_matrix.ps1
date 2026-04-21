[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RegistryPath = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = "",
    [string]$GateConfigPath = ""
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
        if ($Object.Contains($Name)) {
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

function Get-ArtifactPath {
    param(
        [object]$RegistryEntry,
        [string]$ArtifactPropertyName,
        [string]$FallbackRelativePath = ""
    )

    $artifacts = Get-ObjectPropertyValue -Object $RegistryEntry -Name "artifacts" -Default $null
    $artifactPath = [string](Get-ObjectPropertyValue -Object $artifacts -Name $ArtifactPropertyName -Default "")
    if (-not [string]::IsNullOrWhiteSpace($artifactPath)) {
        $resolved = Resolve-ExistingPath -Path $artifactPath
        if ($resolved) {
            return $resolved
        }
    }

    if ([string]::IsNullOrWhiteSpace($FallbackRelativePath)) {
        return ""
    }

    $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $RegistryEntry -Name "pair_root" -Default ""))
    if (-not $pairRoot) {
        return ""
    }

    return Resolve-ExistingPath -Path (Join-Path $pairRoot $FallbackRelativePath)
}

function Get-ResolvedLabRoot {
    param([string]$ExplicitLabRoot)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitLabRoot)
    }

    return Ensure-Directory -Path (Get-LabRootDefault)
}

function Get-ResolvedEvalRoot {
    param(
        [string]$ResolvedLabRoot,
        [string]$ExplicitEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitEvalRoot)
    }

    return Ensure-Directory -Path (Join-Path $ResolvedLabRoot "logs\eval")
}

function Get-ResolvedRegistryPath {
    param(
        [string]$ResolvedEvalRoot,
        [string]$ExplicitRegistryPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRegistryPath)) {
        $resolved = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitRegistryPath)
        if (-not $resolved) {
            throw "Registry path was not found: $ExplicitRegistryPath"
        }

        return $resolved
    }

    $defaultRegistryPath = Join-Path $ResolvedEvalRoot "registry\pair_sessions.ndjson"
    $resolvedDefaultRegistryPath = Resolve-ExistingPath -Path $defaultRegistryPath
    if (-not $resolvedDefaultRegistryPath) {
        throw "Default registry path was not found: $defaultRegistryPath"
    }

    return $resolvedDefaultRegistryPath
}

function Get-ResolvedOutputRoot {
    param(
        [string]$ResolvedEvalRoot,
        [string]$ExplicitOutputRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitOutputRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitOutputRoot)
    }

    return Ensure-Directory -Path (Join-Path $ResolvedEvalRoot "registry")
}

function Get-ResolvedGateConfigPath {
    param([string]$ExplicitGateConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitGateConfigPath)) {
        $resolved = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitGateConfigPath)
        if (-not $resolved) {
            throw "Gate config path was not found: $ExplicitGateConfigPath"
        }

        return $resolved
    }

    $defaultGateConfigPath = Join-Path (Get-RepoRoot) "ai_director\testdata\responsive_trial_gate.json"
    $resolvedDefaultGateConfigPath = Resolve-ExistingPath -Path $defaultGateConfigPath
    if (-not $resolvedDefaultGateConfigPath) {
        throw "Default gate config path was not found: $defaultGateConfigPath"
    }

    return $resolvedDefaultGateConfigPath
}

function Get-SignalBucket {
    param(
        [string]$PairClassification,
        [string]$EvidenceBucket,
        [bool]$SessionIsTuningUsable,
        [bool]$SessionIsStrongSignal
    )

    if ($SessionIsStrongSignal -or $PairClassification -eq "strong-signal" -or $EvidenceBucket -eq "strong-signal") {
        return "strong-signal"
    }

    if ($SessionIsTuningUsable -or $PairClassification -eq "tuning-usable" -or $EvidenceBucket -eq "tuning-usable") {
        return "tuning-usable"
    }

    if ($EvidenceBucket -eq "weak-signal" -or $PairClassification -eq "partially usable") {
        return "weak-signal"
    }

    return "insufficient-data"
}

function Get-BehaviorBucket {
    param([string]$TreatmentBehaviorAssessment)

    switch ($TreatmentBehaviorAssessment) {
        "appropriately conservative" { return "appropriately conservative" }
        "too quiet" { return "too quiet" }
        "too reactive" { return "too reactive" }
        "inconclusive" { return "inconclusive" }
        default { return "inconclusive" }
    }
}

function Get-StateReviewRecommendation {
    param(
        [hashtable]$Thresholds,
        [int]$GroundedConservativeCount,
        [int]$GroundedTooQuietCount,
        [int]$GroundedTooQuietDistinctPairCount,
        [int]$GroundedAppropriatelyConservativeCount,
        [int]$GroundedStrongSignalCount,
        [int]$ResponsiveOverreactionBlockerCount
    )

    $responsiveTrialReady =
        $GroundedConservativeCount -ge $Thresholds.min_grounded_conservative_sessions_for_responsive_trial -and
        $GroundedTooQuietCount -ge $Thresholds.min_grounded_conservative_too_quiet_sessions_for_responsive_trial -and
        $GroundedTooQuietDistinctPairCount -ge $Thresholds.min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial -and
        $GroundedAppropriatelyConservativeCount -le $Thresholds.max_grounded_conservative_appropriate_sessions_for_responsive_trial

    $mixedConservativeEvidence = $GroundedTooQuietCount -gt 0 -and $GroundedAppropriatelyConservativeCount -gt 0

    $keepConservativeReady =
        $GroundedAppropriatelyConservativeCount -ge $Thresholds.min_grounded_conservative_appropriate_sessions_for_keep -and
        ($GroundedStrongSignalCount -ge $Thresholds.min_grounded_conservative_strong_signal_sessions_for_keep -or
         $GroundedConservativeCount -ge $Thresholds.min_grounded_conservative_sessions_for_keep) -and
        $GroundedTooQuietCount -eq 0

    if ($ResponsiveOverreactionBlockerCount -ge $Thresholds.min_grounded_responsive_too_reactive_sessions_for_revert) {
        return [pscustomobject]@{
            recommendation = "responsive-remains-blocked"
            expected_gate_verdict = "revert-recommended"
            expected_next_live_objective = "manual-review-before-next-session"
            reason = "Grounded responsive overreaction blocker evidence is already present."
        }
    }

    if ($mixedConservativeEvidence) {
        return [pscustomobject]@{
            recommendation = "manual-review-still-needed"
            expected_gate_verdict = "manual-review-needed"
            expected_next_live_objective = "manual-review-before-next-session"
            reason = "Counted grounded conservative evidence is mixed between too-quiet and appropriately-conservative outcomes."
        }
    }

    if ($responsiveTrialReady) {
        return [pscustomobject]@{
            recommendation = "responsive-trial-ready"
            expected_gate_verdict = "open"
            expected_next_live_objective = "responsive-trial-ready"
            reason = "Repeated grounded too-quiet conservative evidence has cleared the responsive-opening thresholds."
        }
    }

    if ($keepConservativeReady) {
        return [pscustomobject]@{
            recommendation = "keep-conservative-and-review-again"
            expected_gate_verdict = "closed"
            expected_next_live_objective = "collect-more-grounded-conservative-sessions"
            reason = "Counted grounded conservative evidence is acceptably bounded without any grounded too-quiet counterexample."
        }
    }

    if ($GroundedTooQuietCount -gt 0) {
        return [pscustomobject]@{
            recommendation = "collect-grounded-conservative-too-quiet-evidence"
            expected_gate_verdict = "closed"
            expected_next_live_objective = "collect-grounded-conservative-too-quiet-evidence"
            reason = "There is already some grounded too-quiet conservative evidence, but not enough repeated distinct evidence to open responsive."
        }
    }

    if ($GroundedConservativeCount -gt 0) {
        return [pscustomobject]@{
            recommendation = "collect-more-grounded-conservative-sessions"
            expected_gate_verdict = "closed"
            expected_next_live_objective = "collect-more-grounded-conservative-sessions"
            reason = "Some counted grounded conservative evidence exists, but it does not yet justify a profile change."
        }
    }

    return [pscustomobject]@{
        recommendation = "collect-more-grounded-conservative-sessions"
        expected_gate_verdict = "closed"
        expected_next_live_objective = "collect-first-grounded-conservative-session"
        reason = "No counted grounded conservative evidence exists yet."
    }
}

function Get-MatrixMarkdown {
    param([object]$Matrix)

    $rows = @($Matrix.sessions | ForEach-Object {
        "| $($_.pair_id) | $($_.pair_classification) | $($_.treatment_behavior_assessment) | $($_.signal_bucket) | $($_.counts_toward_promotion) | $($_.contributes_grounded_conservative_too_quiet_evidence) | $($_.contributes_grounded_strong_signal_evidence) |"
    }) -join [Environment]::NewLine

    if ([string]::IsNullOrWhiteSpace($rows)) {
        $rows = "| (none) | | | | | | |"
    }

    return @"
# Grounded Evidence Matrix

- Prompt ID: $($Matrix.prompt_id)
- Registry path: $($Matrix.registry_path)
- Grounded conservative counted sessions: $($Matrix.aggregate_counts.grounded_conservative_sessions)
- Appropriately conservative counted sessions: $($Matrix.aggregate_counts.appropriately_conservative_sessions)
- Too-quiet counted sessions: $($Matrix.aggregate_counts.too_quiet_sessions)
- Strong-signal counted sessions: $($Matrix.aggregate_counts.strong_signal_sessions)

## Sessions

| Pair ID | Pair Classification | Treatment Behavior | Signal Bucket | Counts Toward Promotion | Too Quiet Contribution | Strong Signal Contribution |
| --- | --- | --- | --- | --- | --- | --- |
$rows

## Explanation

$($Matrix.explanation)
"@
}

function Get-PromotionStateReviewMarkdown {
    param([object]$Review)

    return @"
# Promotion State Review

- Prompt ID: $($Review.prompt_id)
- Review verdict: $($Review.review_verdict)
- Current responsive gate: $($Review.current_global_state.responsive_gate_verdict)
- Matrix-consistent gate: $($Review.matrix_derived_state.expected_gate_verdict)
- Current next-live objective: $($Review.current_global_state.next_live_objective)
- Matrix-consistent next-live objective: $($Review.matrix_derived_state.expected_next_live_objective)
- Current state consistent with matrix: $($Review.current_global_state_consistent_with_matrix)
- Recommendation: $($Review.recommendation)

## Aggregate Evidence

- Counted grounded conservative sessions: $($Review.matrix_derived_state.grounded_conservative_sessions)
- Appropriately conservative counted sessions: $($Review.matrix_derived_state.appropriately_conservative_sessions)
- Too-quiet counted sessions: $($Review.matrix_derived_state.too_quiet_sessions)
- Strong-signal counted sessions: $($Review.matrix_derived_state.strong_signal_sessions)
- Mixed evidence state: $($Review.matrix_derived_state.mixed_evidence_state)

## Explanation

$($Review.explanation)
"@
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = Get-ResolvedLabRoot -ExplicitLabRoot $LabRoot
$resolvedEvalRoot = Get-ResolvedEvalRoot -ResolvedLabRoot $resolvedLabRoot -ExplicitEvalRoot $EvalRoot
$resolvedRegistryPath = Get-ResolvedRegistryPath -ResolvedEvalRoot $resolvedEvalRoot -ExplicitRegistryPath $RegistryPath
$resolvedOutputRoot = Get-ResolvedOutputRoot -ResolvedEvalRoot $resolvedEvalRoot -ExplicitOutputRoot $OutputRoot
$resolvedGateConfigPath = Get-ResolvedGateConfigPath -ExplicitGateConfigPath $GateConfigPath

$registryRoot = Split-Path -Path $resolvedRegistryPath -Parent
$registrySummaryPath = Join-Path $registryRoot "registry_summary.json"
$responsiveGatePath = Join-Path $registryRoot "responsive_trial_gate.json"
$nextLivePlanPath = Join-Path $registryRoot "next_live_plan.json"

$gateConfig = Read-JsonFile -Path $resolvedGateConfigPath
$thresholdsObject = Get-ObjectPropertyValue -Object $gateConfig -Name "gate_thresholds" -Default $null
$thresholds = @{
    min_grounded_conservative_sessions_for_responsive_trial = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_grounded_conservative_sessions_for_responsive_trial" -Default 2)
    min_grounded_conservative_too_quiet_sessions_for_responsive_trial = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_grounded_conservative_too_quiet_sessions_for_responsive_trial" -Default 2)
    min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial" -Default 2)
    max_grounded_conservative_appropriate_sessions_for_responsive_trial = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "max_grounded_conservative_appropriate_sessions_for_responsive_trial" -Default 0)
    min_grounded_responsive_too_reactive_sessions_for_revert = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_grounded_responsive_too_reactive_sessions_for_revert" -Default 1)
    min_grounded_conservative_appropriate_sessions_for_keep = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_grounded_conservative_appropriate_sessions_for_keep" -Default 1)
    min_grounded_conservative_sessions_for_keep = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_grounded_conservative_sessions_for_keep" -Default 2)
    min_grounded_conservative_strong_signal_sessions_for_keep = [int](Get-ObjectPropertyValue -Object $thresholdsObject -Name "min_grounded_conservative_strong_signal_sessions_for_keep" -Default 1)
}

$registryEntries = @(Read-NdjsonFile -Path $resolvedRegistryPath)
$groundedConservativeEntries = @(
    $registryEntries |
        Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name "treatment_profile" -Default "") -eq "conservative" -and
            [bool](Get-ObjectPropertyValue -Object $_ -Name "grounded_evidence_certified" -Default $false) -and
            [bool](Get-ObjectPropertyValue -Object $_ -Name "counts_toward_promotion" -Default $false)
        } |
        Sort-Object `
            @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name "registered_at_utc" -Default "") }; Descending = $false }, `
            @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "") }; Descending = $false }
)

$matrixRows = New-Object System.Collections.Generic.List[object]
foreach ($entry in $groundedConservativeEntries) {
    $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $entry -Name "pair_root" -Default ""))
    $pairSummaryPath = Get-ArtifactPath -RegistryEntry $entry -ArtifactPropertyName "pair_summary_json" -FallbackRelativePath "pair_summary.json"
    $scorecardPath = Get-ArtifactPath -RegistryEntry $entry -ArtifactPropertyName "scorecard_json" -FallbackRelativePath "scorecard.json"
    $shadowRecommendationPath = Get-ArtifactPath -RegistryEntry $entry -ArtifactPropertyName "shadow_recommendation_json" -FallbackRelativePath "shadow_review\shadow_recommendation.json"
    $certificatePath = Get-ArtifactPath -RegistryEntry $entry -ArtifactPropertyName "grounded_evidence_certificate_json" -FallbackRelativePath "grounded_evidence_certificate.json"
    $clearancePath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "counted_pair_clearance.json") } else { "" }

    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    $scorecard = Read-JsonFile -Path $scorecardPath
    $shadowRecommendation = Read-JsonFile -Path $shadowRecommendationPath
    $certificate = Read-JsonFile -Path $certificatePath
    $clearance = Read-JsonFile -Path $clearancePath

    $pairClassificationDefault = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_classification" -Default "")
    $pairClassificationFromCertificate = [string](Get-ObjectPropertyValue -Object $certificate -Name "pair_classification" -Default $pairClassificationDefault)
    $pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_classification" -Default $pairClassificationFromCertificate)
    $controlEvidenceQuality = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "control_evidence_quality" -Default ([string](Get-ObjectPropertyValue -Object $entry -Name "control_evidence_quality" -Default "")))
    $treatmentEvidenceQuality = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_evidence_quality" -Default ([string](Get-ObjectPropertyValue -Object $entry -Name "treatment_evidence_quality" -Default "")))
    $treatmentBehaviorAssessmentDefault = [string](Get-ObjectPropertyValue -Object $entry -Name "scorecard_treatment_behavior_assessment" -Default "")
    $treatmentBehaviorAssessmentFromCertificate = [string](Get-ObjectPropertyValue -Object $certificate -Name "treatment_behavior_assessment" -Default $treatmentBehaviorAssessmentDefault)
    $treatmentBehaviorAssessment = [string](Get-ObjectPropertyValue -Object $scorecard -Name "treatment_behavior_assessment" -Default $treatmentBehaviorAssessmentFromCertificate)
    $scorecardRecommendation = [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation" -Default ([string](Get-ObjectPropertyValue -Object $entry -Name "scorecard_recommendation" -Default "")))
    $shadowDecision = [string](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "decision" -Default ([string](Get-ObjectPropertyValue -Object $entry -Name "shadow_recommendation_decision" -Default "")))
    $signalBucket = Get-SignalBucket `
        -PairClassification $pairClassification `
        -EvidenceBucket ([string](Get-ObjectPropertyValue -Object $entry -Name "evidence_bucket" -Default "")) `
        -SessionIsTuningUsable ([bool](Get-ObjectPropertyValue -Object $entry -Name "session_is_tuning_usable" -Default $false)) `
        -SessionIsStrongSignal ([bool](Get-ObjectPropertyValue -Object $entry -Name "session_is_strong_signal" -Default $false))
    $behaviorBucket = Get-BehaviorBucket -TreatmentBehaviorAssessment $treatmentBehaviorAssessment

    $matrixRows.Add([pscustomobject]@{
        pair_id = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default "")
        pair_root = $pairRoot
        treatment_profile = [string](Get-ObjectPropertyValue -Object $entry -Name "treatment_profile" -Default "")
        certification_verdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default ([string](Get-ObjectPropertyValue -Object $entry -Name "grounded_evidence_certification_verdict" -Default "")))
        counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $entry -Name "counts_toward_promotion" -Default $false)
        evidence_origin = [string](Get-ObjectPropertyValue -Object $entry -Name "evidence_origin" -Default "")
        control_evidence_quality = $controlEvidenceQuality
        treatment_evidence_quality = $treatmentEvidenceQuality
        pair_classification = $pairClassification
        treatment_behavior_assessment = $treatmentBehaviorAssessment
        behavior_bucket = $behaviorBucket
        signal_bucket = $signalBucket
        appropriately_conservative = ($behaviorBucket -eq "appropriately conservative")
        too_quiet = ($behaviorBucket -eq "too quiet")
        inconclusive = ($behaviorBucket -eq "inconclusive")
        too_reactive = ($behaviorBucket -eq "too reactive")
        tuning_usable = ($signalBucket -eq "tuning-usable")
        strong_signal = ($signalBucket -eq "strong-signal")
        weak_signal = ($signalBucket -eq "weak-signal")
        insufficient_data = ($signalBucket -eq "insufficient-data")
        contributes_grounded_conservative_evidence = $true
        contributes_grounded_conservative_too_quiet_evidence = ($behaviorBucket -eq "too quiet")
        contributes_grounded_strong_signal_evidence = ($signalBucket -eq "strong-signal")
        contributes_responsive_overreaction_blocker_evidence = ($behaviorBucket -eq "too reactive")
        scorecard_recommendation = $scorecardRecommendation
        shadow_recommendation_decision = $shadowDecision
        counted_pair_clearance_present = -not [string]::IsNullOrWhiteSpace($clearancePath)
        counted_pair_clearance_verdict = [string](Get-ObjectPropertyValue -Object $clearance -Name "clearance_verdict" -Default "")
        manual_review_label_cleared = [bool](Get-ObjectPropertyValue -Object $clearance -Name "manual_review_label_cleared" -Default $false)
        source_artifacts = [pscustomobject]@{
            pair_summary_json = $pairSummaryPath
            scorecard_json = $scorecardPath
            shadow_recommendation_json = $shadowRecommendationPath
            grounded_evidence_certificate_json = $certificatePath
            counted_pair_clearance_json = $clearancePath
        }
    }) | Out-Null
}

$matrixRowsArray = @($matrixRows.ToArray())

$groundedConservativeCount = @($matrixRowsArray).Count
$appropriatelyConservativeCount = @($matrixRowsArray | Where-Object { $_.appropriately_conservative }).Count
$tooQuietCount = @($matrixRowsArray | Where-Object { $_.too_quiet }).Count
$inconclusiveCount = @($matrixRowsArray | Where-Object { $_.inconclusive }).Count
$tooReactiveCount = @($matrixRowsArray | Where-Object { $_.too_reactive }).Count
$strongSignalCount = @($matrixRowsArray | Where-Object { $_.contributes_grounded_strong_signal_evidence }).Count
$weakSignalCount = @($matrixRowsArray | Where-Object { $_.weak_signal }).Count
$insufficientDataCount = @($matrixRowsArray | Where-Object { $_.insufficient_data }).Count
$distinctTooQuietPairCount = @($matrixRowsArray | Where-Object { $_.contributes_grounded_conservative_too_quiet_evidence } | ForEach-Object { $_.pair_id } | Sort-Object -Unique).Count
$responsiveOverreactionBlockerCount = @($matrixRowsArray | Where-Object { $_.contributes_responsive_overreaction_blocker_evidence }).Count
$mixedEvidenceState = $tooQuietCount -gt 0 -and $appropriatelyConservativeCount -gt 0

$recommendation = Get-StateReviewRecommendation `
    -Thresholds $thresholds `
    -GroundedConservativeCount $groundedConservativeCount `
    -GroundedTooQuietCount $tooQuietCount `
    -GroundedTooQuietDistinctPairCount $distinctTooQuietPairCount `
    -GroundedAppropriatelyConservativeCount $appropriatelyConservativeCount `
    -GroundedStrongSignalCount $strongSignalCount `
    -ResponsiveOverreactionBlockerCount $responsiveOverreactionBlockerCount

$currentRegistrySummary = Read-JsonFile -Path $registrySummaryPath
$currentResponsiveGate = Read-JsonFile -Path $responsiveGatePath
$currentNextLivePlan = Read-JsonFile -Path $nextLivePlanPath

$currentGateVerdict = [string](Get-ObjectPropertyValue -Object $currentResponsiveGate -Name "gate_verdict" -Default "")
$currentNextLiveObjective = [string](Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "recommended_next_session_objective" -Default "")
$currentGroundedConservativeCount = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "current_certified_grounded_session_counts" -Default $null) -Name "conservative" -Default 0)
$currentTooQuietCount = [int](Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "current_grounded_conservative_too_quiet_count" -Default 0)
$currentStrongSignalCount = [int](Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "current_grounded_strong_signal_count" -Default 0)

$consistencyIssues = New-Object System.Collections.Generic.List[string]
if ($currentGateVerdict -ne $recommendation.expected_gate_verdict) {
    $consistencyIssues.Add("Current responsive gate verdict '$currentGateVerdict' does not match the matrix-derived gate verdict '$($recommendation.expected_gate_verdict)'.") | Out-Null
}
if ($currentNextLiveObjective -ne $recommendation.expected_next_live_objective) {
    $consistencyIssues.Add("Current next-live objective '$currentNextLiveObjective' does not match the matrix-derived next-live objective '$($recommendation.expected_next_live_objective)'.") | Out-Null
}
if ($currentGroundedConservativeCount -ne $groundedConservativeCount) {
    $consistencyIssues.Add("Current grounded conservative count $currentGroundedConservativeCount does not match the matrix count $groundedConservativeCount.") | Out-Null
}
if ($currentTooQuietCount -ne $tooQuietCount) {
    $consistencyIssues.Add("Current grounded too-quiet count $currentTooQuietCount does not match the matrix count $tooQuietCount.") | Out-Null
}
if ($currentStrongSignalCount -ne $strongSignalCount) {
    $consistencyIssues.Add("Current grounded strong-signal count $currentStrongSignalCount does not match the matrix count $strongSignalCount.") | Out-Null
}

$currentStateConsistentWithMatrix = $consistencyIssues.Count -eq 0

$matrixExplanationParts = @(
    "The matrix includes every counted grounded conservative session in the registry and reads pair-local certificate, scorecard, shadow-review, and counted-pair-clearance artifacts when present.",
    "$groundedConservativeCount counted grounded conservative session(s) are currently recognized.",
    "$appropriatelyConservativeCount counted session(s) assess conservative as appropriately conservative.",
    "$tooQuietCount counted session(s) assess conservative as too quiet.",
    "$strongSignalCount counted session(s) contribute grounded strong-signal evidence."
)
if ($mixedEvidenceState) {
    $matrixExplanationParts += "The counted grounded conservative evidence is mixed because both too-quiet and appropriately-conservative outcomes are present."
}
else {
    $matrixExplanationParts += "The counted grounded conservative evidence is not mixed between too-quiet and appropriately-conservative outcomes."
}
$matrixExplanationParts += "The responsive-opening thresholds still require $($thresholds.min_grounded_conservative_too_quiet_sessions_for_responsive_trial) grounded too-quiet sessions across $($thresholds.min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial) distinct pair runs, while allowing at most $($thresholds.max_grounded_conservative_appropriate_sessions_for_responsive_trial) appropriately-conservative counterexample session(s)."
$matrixExplanationParts += "The current matrix-derived recommendation is '$($recommendation.recommendation)' because $($recommendation.reason)"

$matrix = [pscustomobject]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    registry_path = $resolvedRegistryPath
    output_root = $resolvedOutputRoot
    gate_config_path = $resolvedGateConfigPath
    aggregate_counts = [pscustomobject]@{
        grounded_conservative_sessions = $groundedConservativeCount
        appropriately_conservative_sessions = $appropriatelyConservativeCount
        too_quiet_sessions = $tooQuietCount
        inconclusive_sessions = $inconclusiveCount
        too_reactive_sessions = $tooReactiveCount
        strong_signal_sessions = $strongSignalCount
        weak_signal_sessions = $weakSignalCount
        insufficient_data_sessions = $insufficientDataCount
        distinct_grounded_too_quiet_pair_ids = $distinctTooQuietPairCount
        responsive_overreaction_blocker_sessions = $responsiveOverreactionBlockerCount
        mixed_evidence_state = $mixedEvidenceState
    }
    sessions = $matrixRowsArray
    explanation = ($matrixExplanationParts -join " ")
}

$reviewExplanationParts = @()
if ($currentStateConsistentWithMatrix) {
    $reviewExplanationParts += "The current global responsive gate and next-live objective are consistent with the grounded-evidence matrix."
}
else {
    $reviewExplanationParts += "The current global state is not fully consistent with the grounded-evidence matrix."
}
$reviewExplanationParts += "Responsive remains blocked because counted grounded conservative evidence is split between one too-quiet session and one appropriately-conservative session, so the responsive-opening rule is not satisfied."
if ($strongSignalCount -eq 0) {
    $reviewExplanationParts += "There is still no counted grounded strong-signal conservative session."
}
$reviewExplanationParts += "The matrix-based recommendation is '$($recommendation.recommendation)', and the current planner state '$currentNextLiveObjective' is $(if ($currentStateConsistentWithMatrix) { 'supported' } else { 'not supported' }) by the evidence map."
if ($consistencyIssues.Count -gt 0) {
    $reviewExplanationParts += ($consistencyIssues -join " ")
}

$reviewVerdict = if ($currentStateConsistentWithMatrix) {
    "current-global-state-consistent"
}
else {
    "current-global-state-needs-review"
}

$promotionStateReview = [pscustomobject]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    registry_path = $resolvedRegistryPath
    grounded_evidence_matrix_json = Join-Path $resolvedOutputRoot "grounded_evidence_matrix.json"
    grounded_evidence_matrix_markdown = Join-Path $resolvedOutputRoot "grounded_evidence_matrix.md"
    review_verdict = $reviewVerdict
    recommendation = $recommendation.recommendation
    current_global_state = [pscustomobject]@{
        responsive_gate_verdict = $currentGateVerdict
        responsive_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $currentResponsiveGate -Name "next_live_action" -Default "")
        next_live_objective = $currentNextLiveObjective
        grounded_conservative_sessions = $currentGroundedConservativeCount
        grounded_too_quiet_sessions = $currentTooQuietCount
        strong_signal_sessions = $currentStrongSignalCount
    }
    matrix_derived_state = [pscustomobject]@{
        expected_gate_verdict = $recommendation.expected_gate_verdict
        expected_next_live_objective = $recommendation.expected_next_live_objective
        grounded_conservative_sessions = $groundedConservativeCount
        appropriately_conservative_sessions = $appropriatelyConservativeCount
        too_quiet_sessions = $tooQuietCount
        strong_signal_sessions = $strongSignalCount
        responsive_overreaction_blocker_sessions = $responsiveOverreactionBlockerCount
        mixed_evidence_state = $mixedEvidenceState
        thresholds = [pscustomobject]$thresholds
    }
    current_global_state_consistent_with_matrix = $currentStateConsistentWithMatrix
    consistency_issues = @($consistencyIssues.ToArray())
    explanation = ($reviewExplanationParts -join " ")
}

$matrixJsonPath = Join-Path $resolvedOutputRoot "grounded_evidence_matrix.json"
$matrixMarkdownPath = Join-Path $resolvedOutputRoot "grounded_evidence_matrix.md"
$reviewJsonPath = Join-Path $resolvedOutputRoot "promotion_state_review.json"
$reviewMarkdownPath = Join-Path $resolvedOutputRoot "promotion_state_review.md"

Write-JsonFile -Path $matrixJsonPath -Value $matrix
Write-TextFile -Path $matrixMarkdownPath -Value (Get-MatrixMarkdown -Matrix $matrix)
Write-JsonFile -Path $reviewJsonPath -Value $promotionStateReview
Write-TextFile -Path $reviewMarkdownPath -Value (Get-PromotionStateReviewMarkdown -Review $promotionStateReview)

[pscustomobject]@{
    GroundedEvidenceMatrixJsonPath = $matrixJsonPath
    GroundedEvidenceMatrixMarkdownPath = $matrixMarkdownPath
    PromotionStateReviewJsonPath = $reviewJsonPath
    PromotionStateReviewMarkdownPath = $reviewMarkdownPath
    Recommendation = $recommendation.recommendation
    CurrentGlobalStateConsistentWithMatrix = $currentStateConsistentWithMatrix
}
