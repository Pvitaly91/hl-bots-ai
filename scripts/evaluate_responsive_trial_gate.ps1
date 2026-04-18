[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RegistryPath = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$RegistrySummaryPath = "",
    [string]$ProfileRecommendationPath = "",
    [string]$GateConfigPath = "",
    [switch]$IncludeSyntheticEvidenceForValidation
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

    $json = $Value | ConvertTo-Json -Depth 14
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

function Get-EvidenceBucket {
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

function Test-SyntheticRegistryEntry {
    param([object]$Entry)

    $explicitFlag = Get-ObjectPropertyValue -Object $Entry -Name "synthetic_fixture" -Default $null
    if ($null -ne $explicitFlag) {
        return [bool]$explicitFlag
    }

    $evidenceOrigin = [string](Get-ObjectPropertyValue -Object $Entry -Name "evidence_origin" -Default "")
    if ($evidenceOrigin -in @("rehearsal", "synthetic")) {
        return $true
    }

    if ([bool](Get-ObjectPropertyValue -Object $Entry -Name "rehearsal_mode" -Default $false)) {
        return $true
    }

    if ([bool](Get-ObjectPropertyValue -Object $Entry -Name "validation_only" -Default $false)) {
        return $true
    }

    foreach ($candidate in @(
        [string](Get-ObjectPropertyValue -Object $Entry -Name "pair_prompt_id" -Default ""),
        [string](Get-ObjectPropertyValue -Object $Entry -Name "pair_id" -Default ""),
        [string](Get-ObjectPropertyValue -Object $Entry -Name "source_commit_sha" -Default "")
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if ($candidate -like "*-SYNTHETIC" -or $candidate -like "synthetic-*" -or $candidate -eq "synthetic-fixture") {
            return $true
        }
    }

    return $false
}

function New-CountMap {
    param(
        [object[]]$Items,
        [scriptblock]$KeySelector,
        [string[]]$PreferredKeys = @()
    )

    $counts = [ordered]@{}
    foreach ($preferredKey in $PreferredKeys) {
        $counts[$preferredKey] = 0
    }

    foreach ($item in $Items) {
        $rawKey = [string](& $KeySelector $item)
        $key = if ([string]::IsNullOrWhiteSpace($rawKey)) { "(missing)" } else { $rawKey }
        if (-not $counts.Contains($key)) {
            $counts[$key] = 0
        }
        $counts[$key]++
    }

    return $counts
}

function Get-CountValue {
    param(
        [object[]]$Items,
        [scriptblock]$Predicate
    )

    $count = 0
    foreach ($item in $Items) {
        if (& $Predicate $item) {
            $count++
        }
    }

    return $count
}

function Get-SupportingPairIds {
    param([object[]]$Entries)

    return @(
        $Entries |
            Sort-Object `
                @{ Expression = { $_.pair_run_sort_key }; Descending = $true }, `
                @{ Expression = { $_.registered_at_utc }; Descending = $true }, `
                @{ Expression = { $_.pair_id }; Descending = $true } |
            Select-Object -ExpandProperty pair_id -Unique |
            Select-Object -First 5
    )
}

function Get-CountMarkdownLines {
    param([object]$Counts)

    $lines = @()
    if ($Counts -is [System.Collections.IDictionary]) {
        foreach ($key in $Counts.Keys) {
            $lines += "- ${key}: $($Counts[$key])"
        }
        return $lines
    }

    foreach ($property in $Counts.PSObject.Properties) {
        $lines += "- $($property.Name): $($property.Value)"
    }

    return $lines
}

function Get-ResponsiveTrialGateMarkdown {
    param([object]$Gate)

    $supportingPairIds = @($Gate.supporting_pair_ids)
    $missingEvidence = @($Gate.missing_evidence)

    $lines = @(
        "# Responsive Trial Gate",
        "",
        "- Gate verdict: $($Gate.gate_verdict)",
        "- Next live action: $($Gate.next_live_action)",
        "- Explanation: $($Gate.explanation)",
        "- Promotion evidence scope: $($Gate.promotion_evidence_scope)",
        "- Workflow-validation evidence excluded from promotion: $($Gate.synthetic_only_evidence_excluded_from_promotion)",
        "",
        "## Registry Context",
        "",
        "- Total registered sessions: $($Gate.total_registered_sessions)",
        "- Live registered sessions: $($Gate.real_registered_sessions)",
        "- Workflow-validation-only sessions: $($Gate.synthetic_registered_sessions)",
        "- Certified grounded sessions: $($Gate.certified_grounded_sessions)",
        "- Excluded registered sessions: $($Gate.excluded_registered_sessions)",
        "- Insufficient-data sessions: $($Gate.insufficient_data_count)",
        "- Weak-signal sessions: $($Gate.weak_signal_count)",
        "- Tuning-usable sessions: $($Gate.tuning_usable_count)",
        "- Strong-signal sessions: $($Gate.strong_signal_count)",
        "",
        "### Excluded Sessions By Reason",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Gate.excluded_sessions_by_reason
    $lines += @(
        "",
        "## Conservative Evidence",
        "",
        "- Total certified grounded conservative sessions: $($Gate.conservative_evidence_counts.total_grounded_count)",
        "- Live certified grounded conservative sessions: $($Gate.conservative_evidence_counts.real_grounded_count)",
        "- Certified grounded conservative too-quiet cases: $($Gate.conservative_evidence_counts.total_grounded_too_quiet_count)",
        "- Live certified grounded conservative too-quiet cases: $($Gate.conservative_evidence_counts.real_grounded_too_quiet_count)",
        "- Live certified grounded conservative appropriately-conservative cases: $($Gate.conservative_evidence_counts.real_grounded_appropriately_conservative_count)",
        "- Live distinct certified grounded conservative too-quiet pair IDs: $($Gate.conservative_evidence_counts.real_distinct_grounded_too_quiet_pair_ids_count)",
        "- Live certified grounded conservative shadow responsive-candidate cases: $($Gate.conservative_evidence_counts.real_shadow_responsive_candidate_count)",
        "",
        "## Responsive Risk Evidence",
        "",
        "- Total certified grounded responsive sessions: $($Gate.responsive_risk_evidence_counts.total_grounded_count)",
        "- Live certified grounded responsive sessions: $($Gate.responsive_risk_evidence_counts.real_grounded_count)",
        "- Certified grounded responsive too-reactive cases: $($Gate.responsive_risk_evidence_counts.total_grounded_too_reactive_count)",
        "- Live certified grounded responsive too-reactive cases: $($Gate.responsive_risk_evidence_counts.real_grounded_too_reactive_count)",
        "- Live certified grounded responsive appropriately-conservative cases: $($Gate.responsive_risk_evidence_counts.real_grounded_appropriately_conservative_count)",
        "",
        "## Thresholds",
        ""
    )

    foreach ($property in $Gate.thresholds.PSObject.Properties) {
        $lines += "- $($property.Name): $($property.Value)"
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

    if ($missingEvidence.Count -gt 0) {
        $lines += @(
            "",
            "## Missing Evidence",
            ""
        )
        foreach ($item in $missingEvidence) {
            $lines += "- $item"
        }
    }

    if ($Gate.registry_recommendation_available) {
        $lines += @(
            "",
            "## Registry Recommendation Alignment",
            "",
            "- Profile recommendation decision: $($Gate.registry_recommendation_decision)",
            "- Profile recommendation live profile: $($Gate.registry_recommendation_live_profile)",
            "- Gate agrees with registry recommendation: $($Gate.gate_agrees_with_registry_recommendation)"
        )
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ResponsiveTrialPlanMarkdown {
    param([object]$Plan)

    $missingEvidence = @($Plan.missing_evidence)
    $postRunWorkflow = @($Plan.post_run_workflow)

    $lines = @(
        "# Responsive Trial Plan",
        "",
        "- Plan status: $($Plan.plan_status)",
        "- Gate verdict: $($Plan.gate_verdict)",
        "- Next live action: $($Plan.next_live_action)",
        "- Explanation: $($Plan.explanation)"
    )

    if ($Plan.plan_status -eq "ready") {
        $lines += @(
            "",
            "## Trial Settings",
            "",
            "- Map: $($Plan.recommended_map)",
            "- Bot count: $($Plan.bot_count)",
            "- Bot skill: $($Plan.bot_skill)",
            "- Duration seconds: $($Plan.session_duration_seconds)",
            "- Wait for human join: $($Plan.wait_for_human_join)",
            "- Human join grace seconds: $($Plan.human_join_grace_seconds)",
            "- Minimum human snapshots: $($Plan.minimum_human_signal_required.min_human_snapshots)",
            "- Minimum human presence seconds: $($Plan.minimum_human_signal_required.min_human_presence_seconds)",
            "",
            "## Lane Settings",
            "",
            "- Control lane: port $($Plan.control_lane.port), label $($Plan.control_lane.lane_label), no-AI baseline, `jk_ai_balance_enabled 0`, no sidecar",
            "- Treatment lane: port $($Plan.treatment_lane.port), label $($Plan.treatment_lane.lane_label), profile $($Plan.treatment_lane.treatment_profile)",
            "",
            "## Trial Command",
            "",
            "```powershell",
            $Plan.trial_command,
            "```",
            "",
            "## Success Criteria",
            ""
        )

        foreach ($item in @($Plan.success_criteria)) {
            $lines += "- $item"
        }

        $lines += @(
            "",
            "## Overreaction Conditions",
            ""
        )
        foreach ($item in @($Plan.overreaction_conditions)) {
            $lines += "- $item"
        }

        $lines += @(
            "",
            "## Rollback Rule",
            "",
            "- $($Plan.rollback_condition)",
            "",
            "## Post-Run Workflow",
            ""
        )
        foreach ($item in $postRunWorkflow) {
            $lines += "- $item"
        }
    }
    else {
        if ($missingEvidence.Count -gt 0) {
            $lines += @(
                "",
                "## Not Yet",
                ""
            )
            foreach ($item in $missingEvidence) {
                $lines += "- $item"
            }
        }

        $lines += @(
            "",
            "## Post-Run Workflow Once Another Pair Is Captured",
            ""
        )
        foreach ($item in $postRunWorkflow) {
            $lines += "- $item"
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot }
$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Split-Path -Path $resolvedRegistryPath -Parent)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
}

$resolvedRegistrySummaryPath = if ([string]::IsNullOrWhiteSpace($RegistrySummaryPath)) {
    Join-Path $resolvedOutputRoot "registry_summary.json"
}
else {
    Get-AbsolutePath -Path $RegistrySummaryPath
}

$resolvedProfileRecommendationPath = if ([string]::IsNullOrWhiteSpace($ProfileRecommendationPath)) {
    Join-Path $resolvedOutputRoot "profile_recommendation.json"
}
else {
    Get-AbsolutePath -Path $ProfileRecommendationPath
}

$resolvedGateConfigPath = if ([string]::IsNullOrWhiteSpace($GateConfigPath)) {
    Join-Path (Get-RepoRoot) "ai_director\testdata\responsive_trial_gate.json"
}
else {
    Get-AbsolutePath -Path $GateConfigPath
}

$gateConfig = Read-JsonFile -Path $resolvedGateConfigPath
if ($null -eq $gateConfig) {
    throw "Responsive trial gate config was not found: $resolvedGateConfigPath"
}

$thresholds = Get-ObjectPropertyValue -Object $gateConfig -Name "gate_thresholds" -Default $null
$trialDefaults = Get-ObjectPropertyValue -Object $gateConfig -Name "trial_defaults" -Default $null
if ($null -eq $thresholds -or $null -eq $trialDefaults) {
    throw "Responsive trial gate config is missing gate_thresholds or trial_defaults."
}

$registrySummary = Read-JsonFile -Path $resolvedRegistrySummaryPath
$profileRecommendation = Read-JsonFile -Path $resolvedProfileRecommendationPath
$rawEntries = @(Read-NdjsonFile -Path $resolvedRegistryPath)
$normalizedEntries = @()
foreach ($entry in $rawEntries) {
    $pairClassification = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_classification" -Default "")
    $comparisonVerdict = [string](Get-ObjectPropertyValue -Object $entry -Name "comparison_verdict" -Default "")
    $controlEvidenceQuality = [string](Get-ObjectPropertyValue -Object $entry -Name "control_evidence_quality" -Default "")
    $treatmentEvidenceQuality = [string](Get-ObjectPropertyValue -Object $entry -Name "treatment_evidence_quality" -Default "")
    $sessionIsTuningUsable = [bool](Get-ObjectPropertyValue -Object $entry -Name "session_is_tuning_usable" -Default $false)
    $evidenceBucket = [string](Get-ObjectPropertyValue -Object $entry -Name "evidence_bucket" -Default "")
    if ([string]::IsNullOrWhiteSpace($evidenceBucket)) {
        $evidenceBucket = Get-EvidenceBucket `
            -PairClassification $pairClassification `
            -ComparisonVerdict $comparisonVerdict `
            -ControlEvidenceQuality $controlEvidenceQuality `
            -TreatmentEvidenceQuality $treatmentEvidenceQuality `
            -SessionIsTuningUsable $sessionIsTuningUsable
    }

    $certification = Get-PairSessionGroundedEvidenceCertificationFromRegistryEntry -Entry $entry

    $normalizedEntries += [pscustomobject]@{
        pair_id = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default "")
        pair_run_sort_key = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_run_sort_key" -Default (Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default ""))
        registered_at_utc = [string](Get-ObjectPropertyValue -Object $entry -Name "registered_at_utc" -Default "")
        treatment_profile = [string](Get-ObjectPropertyValue -Object $entry -Name "treatment_profile" -Default "")
        pair_classification = $pairClassification
        evidence_bucket = $evidenceBucket
        session_is_tuning_usable = $sessionIsTuningUsable -or $evidenceBucket -in @("tuning-usable", "strong-signal")
        session_is_strong_signal = [bool](Get-ObjectPropertyValue -Object $entry -Name "session_is_strong_signal" -Default ($evidenceBucket -eq "strong-signal"))
        treatment_behavior_assessment = [string](Get-ObjectPropertyValue -Object $entry -Name "scorecard_treatment_behavior_assessment" -Default "")
        shadow_review_present = [bool](Get-ObjectPropertyValue -Object $entry -Name "shadow_review_present" -Default $false)
        shadow_recommendation_decision = [string](Get-ObjectPropertyValue -Object $entry -Name "shadow_recommendation_decision" -Default "")
        evidence_origin = [string](Get-ObjectPropertyValue -Object $entry -Name "evidence_origin" -Default $certification.evidence_origin)
        synthetic_fixture = [bool](Get-ObjectPropertyValue -Object $entry -Name "synthetic_fixture" -Default $false)
        rehearsal_mode = [bool](Get-ObjectPropertyValue -Object $entry -Name "rehearsal_mode" -Default $false)
        validation_only = [bool](Get-ObjectPropertyValue -Object $entry -Name "validation_only" -Default $false)
        counts_toward_promotion = [bool]$certification.counts_toward_promotion
        counts_only_as_workflow_validation = [bool]$certification.counts_only_as_workflow_validation
        grounded_evidence_exclusion_reasons = @($certification.exclusion_reasons)
        fixture_id = [string](Get-ObjectPropertyValue -Object $entry -Name "fixture_id" -Default "")
    }
}

$liveRegisteredEntries = @($normalizedEntries | Where-Object { $_.evidence_origin -eq "live" -and -not $_.counts_only_as_workflow_validation })
$workflowValidationEntries = @($normalizedEntries | Where-Object { $_.counts_only_as_workflow_validation })
$nonCertifiedEntries = @($normalizedEntries | Where-Object { -not $_.counts_toward_promotion })
$excludedLiveEntries = @($normalizedEntries | Where-Object { $_.evidence_origin -eq "live" -and -not $_.counts_toward_promotion })
$decisionScopeEntries = @($normalizedEntries | Where-Object { $_.counts_toward_promotion })
$excludedReasonCounts = New-CountMap `
    -Items @($nonCertifiedEntries | ForEach-Object { foreach ($reason in @($_.grounded_evidence_exclusion_reasons)) { [pscustomobject]@{ reason = $reason } } }) `
    -KeySelector { param($item) $item.reason } `
    -PreferredKeys @()

$insufficientDataEntries = @($normalizedEntries | Where-Object { $_.evidence_bucket -eq "insufficient-data" })
$weakSignalEntries = @($normalizedEntries | Where-Object { $_.evidence_bucket -eq "weak-signal" })
$tuningUsableEntries = @($normalizedEntries | Where-Object { $_.evidence_bucket -eq "tuning-usable" })
$strongSignalEntries = @($normalizedEntries | Where-Object { $_.evidence_bucket -eq "strong-signal" })

$decisionGroundedEntries = @($decisionScopeEntries)
$liveCertifiedGroundedEntries = @($decisionScopeEntries | Where-Object { $_.evidence_origin -eq "live" })

$conservativeGroundedAll = @($decisionScopeEntries | Where-Object { $_.treatment_profile -eq "conservative" })
$conservativeGroundedReal = @($decisionScopeEntries | Where-Object { $_.treatment_profile -eq "conservative" -and $_.evidence_origin -eq "live" })
$conservativeGroundedDecision = @($conservativeGroundedAll)
$conservativeStrongDecision = @($conservativeGroundedDecision | Where-Object { $_.session_is_strong_signal })
$conservativeTooQuietAll = @($conservativeGroundedAll | Where-Object { $_.treatment_behavior_assessment -eq "too quiet" })
$conservativeTooQuietReal = @($conservativeGroundedReal | Where-Object { $_.treatment_behavior_assessment -eq "too quiet" })
$conservativeTooQuietDecision = @($conservativeGroundedDecision | Where-Object { $_.treatment_behavior_assessment -eq "too quiet" })
$conservativeAppropriateAll = @($conservativeGroundedAll | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })
$conservativeAppropriateReal = @($conservativeGroundedReal | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })
$conservativeAppropriateDecision = @($conservativeGroundedDecision | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })
$conservativeTooReactiveReal = @($conservativeGroundedReal | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })
$conservativeTooReactiveDecision = @($conservativeGroundedDecision | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })

$candidateShadowReviewsDecision = @($conservativeTooQuietDecision | Where-Object { $_.shadow_review_present })
$candidateShadowResponsiveDecision = @($candidateShadowReviewsDecision | Where-Object { $_.shadow_recommendation_decision -eq "conservative-looks-too-quiet-responsive-candidate" })
$candidateShadowTooReactiveDecision = @($candidateShadowReviewsDecision | Where-Object { $_.shadow_recommendation_decision -eq "responsive-would-have-overreacted" })
$candidateShadowManualDecision = @($candidateShadowReviewsDecision | Where-Object { $_.shadow_recommendation_decision -eq "manual-review-needed" })
$candidateShadowResponsiveReal = @($conservativeTooQuietReal | Where-Object { $_.shadow_recommendation_decision -eq "conservative-looks-too-quiet-responsive-candidate" })

$responsiveGroundedAll = @($decisionScopeEntries | Where-Object { $_.treatment_profile -eq "responsive" })
$responsiveGroundedReal = @($decisionScopeEntries | Where-Object { $_.treatment_profile -eq "responsive" -and $_.evidence_origin -eq "live" })
$responsiveGroundedDecision = @($responsiveGroundedAll)
$responsiveTooReactiveAll = @($responsiveGroundedAll | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })
$responsiveTooReactiveReal = @($responsiveGroundedReal | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })
$responsiveTooReactiveDecision = @($responsiveGroundedDecision | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })
$responsiveAppropriateReal = @($responsiveGroundedReal | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })
$responsiveAppropriateDecision = @($responsiveGroundedDecision | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })

$distinctConservativeTooQuietDecisionPairIds = @(
    $conservativeTooQuietDecision |
        Select-Object -ExpandProperty pair_id -Unique
)

$minGroundedConservativeSessionsForResponsiveTrial = [int]$thresholds.min_grounded_conservative_sessions_for_responsive_trial
$minGroundedConservativeTooQuietSessionsForResponsiveTrial = [int]$thresholds.min_grounded_conservative_too_quiet_sessions_for_responsive_trial
$minDistinctGroundedConservativeTooQuietPairIdsForResponsiveTrial = [int]$thresholds.min_distinct_grounded_conservative_too_quiet_pair_ids_for_responsive_trial
$maxGroundedConservativeAppropriateSessionsForResponsiveTrial = [int]$thresholds.max_grounded_conservative_appropriate_sessions_for_responsive_trial
$minGroundedResponsiveTooReactiveSessionsForRevert = [int]$thresholds.min_grounded_responsive_too_reactive_sessions_for_revert
$minGroundedConservativeAppropriateSessionsForKeep = [int]$thresholds.min_grounded_conservative_appropriate_sessions_for_keep
$minGroundedConservativeSessionsForKeep = [int]$thresholds.min_grounded_conservative_sessions_for_keep
$minGroundedConservativeStrongSignalSessionsForKeep = [int]$thresholds.min_grounded_conservative_strong_signal_sessions_for_keep

$candidateThresholdsMet = (
    $conservativeGroundedDecision.Count -ge $minGroundedConservativeSessionsForResponsiveTrial -and
    $conservativeTooQuietDecision.Count -ge $minGroundedConservativeTooQuietSessionsForResponsiveTrial -and
    $distinctConservativeTooQuietDecisionPairIds.Count -ge $minDistinctGroundedConservativeTooQuietPairIdsForResponsiveTrial -and
    $conservativeAppropriateDecision.Count -le $maxGroundedConservativeAppropriateSessionsForResponsiveTrial
)

$gateVerdict = "closed"
$nextLiveAction = "responsive-trial-not-allowed"
$explanation = ""
$supportingEntries = @()

if ($responsiveTooReactiveDecision.Count -gt 0 -and $responsiveAppropriateDecision.Count -gt 0) {
    $gateVerdict = "manual-review-needed"
    $nextLiveAction = "manual-review-needed"
    $explanation = "Certified grounded responsive evidence is mixed: at least one responsive session looks too reactive and at least one looks acceptably bounded, so an operator needs to review the artifacts before another live choice."
    $supportingEntries = $responsiveTooReactiveDecision + $responsiveAppropriateDecision
}
elseif ($responsiveTooReactiveDecision.Count -ge $minGroundedResponsiveTooReactiveSessionsForRevert) {
    $gateVerdict = "revert-recommended"
    $nextLiveAction = "responsive-revert-recommended"
    $explanation = "Certified grounded responsive evidence already shows overreaction, so the live treatment profile should revert to conservative instead of scheduling another responsive trial."
    $supportingEntries = $responsiveTooReactiveDecision
}
elseif ($conservativeTooReactiveDecision.Count -gt 0) {
    $gateVerdict = "manual-review-needed"
    $nextLiveAction = "manual-review-needed"
    $explanation = "Certified grounded conservative evidence includes at least one too-reactive assessment, which should not be promoted or ignored without manual review."
    $supportingEntries = $conservativeTooReactiveDecision
}
elseif ($conservativeTooQuietDecision.Count -gt 0 -and $conservativeAppropriateDecision.Count -gt 0) {
    $gateVerdict = "manual-review-needed"
    $nextLiveAction = "manual-review-needed"
    $explanation = "Certified grounded conservative evidence is mixed between too-quiet and appropriately-conservative outcomes, so the first responsive trial should stay blocked until the artifacts are reviewed."
    $supportingEntries = $conservativeTooQuietDecision + $conservativeAppropriateDecision
}
elseif ($candidateThresholdsMet -and ($candidateShadowTooReactiveDecision.Count -gt 0 -or $candidateShadowManualDecision.Count -gt 0)) {
    $gateVerdict = "manual-review-needed"
    $nextLiveAction = "manual-review-needed"
    $explanation = "The conservative too-quiet threshold was met, but shadow review on those certified grounded sessions still raised overreaction or manual-review concerns, so the first live responsive trial should not be scheduled blindly."
    $supportingEntries = $conservativeTooQuietDecision
}
elseif ($candidateThresholdsMet -and $candidateShadowReviewsDecision.Count -gt 0 -and $candidateShadowResponsiveDecision.Count -eq 0) {
    $gateVerdict = "closed"
    $nextLiveAction = "collect-more-conservative-evidence"
    $explanation = "Certified grounded conservative sessions are trending too quiet, but the available shadow reviews did not yet support responsive as the next candidate, so more conservative evidence should be collected first."
    $supportingEntries = $conservativeTooQuietDecision
}
elseif ($candidateThresholdsMet) {
    $gateVerdict = "open"
    $nextLiveAction = "responsive-trial-allowed"
    $explanation = "Repeated certified grounded conservative sessions stayed too quiet across distinct pair runs without certified grounded evidence that conservative is already behaving acceptably, so one bounded live responsive trial is justified."
    $supportingEntries = $conservativeTooQuietDecision
}
elseif ($decisionGroundedEntries.Count -eq 0) {
    $gateVerdict = "closed"
    $nextLiveAction = "responsive-trial-not-allowed"
    if ($normalizedEntries.Count -eq 0) {
        $explanation = "No pair sessions have been registered yet, so there is no evidence to justify the first live responsive trial."
    }
    elseif ($workflowValidationEntries.Count -gt 0 -and $excludedLiveEntries.Count -eq 0) {
        $explanation = "Registered sessions exist, but they are rehearsal or synthetic workflow-validation only, so none of them count toward responsive promotion thresholds."
    }
    else {
        $explanation = "Registered sessions exist, but none have been certified as grounded promotion evidence yet, so the first live responsive trial remains blocked."
    }
    $supportingEntries = if ($excludedLiveEntries.Count -gt 0) { $excludedLiveEntries } elseif ($workflowValidationEntries.Count -gt 0) { $workflowValidationEntries } else { @() }
}
elseif (
    $conservativeAppropriateDecision.Count -ge $minGroundedConservativeAppropriateSessionsForKeep -and
    ($conservativeStrongDecision.Count -ge $minGroundedConservativeStrongSignalSessionsForKeep -or $conservativeGroundedDecision.Count -ge $minGroundedConservativeSessionsForKeep) -and
    $conservativeTooQuietDecision.Count -eq 0
) {
    $gateVerdict = "closed"
    $nextLiveAction = "keep-conservative"
    $explanation = "Certified grounded conservative sessions already show bounded, acceptable live behavior without certified grounded too-quiet evidence, so conservative should remain the default live treatment profile."
    $supportingEntries = $conservativeAppropriateDecision
}
elseif ($conservativeGroundedDecision.Count -ge 1) {
    $gateVerdict = "closed"
    $nextLiveAction = "collect-more-conservative-evidence"
    $explanation = "There is some certified grounded conservative evidence, but not enough repeated evidence yet to justify opening the first live responsive trial."
    $supportingEntries = $conservativeGroundedDecision
}
else {
    $gateVerdict = "manual-review-needed"
    $nextLiveAction = "manual-review-needed"
    $explanation = "The available certified grounded evidence does not fit a clean responsive-trial promotion rule, so the registry and pair artifacts need manual review."
    $supportingEntries = $decisionScopeEntries
}

$missingEvidence = @()
switch ($nextLiveAction) {
    "responsive-trial-not-allowed" {
        if ($liveRegisteredEntries.Count -eq 0) {
            $missingEvidence += "At least one real live conservative pair session must be registered before responsive can be considered."
        }
        if ($liveCertifiedGroundedEntries.Count -eq 0) {
            $missingEvidence += "At least one real live conservative pair must be certified as grounded promotion evidence before responsive can be considered."
        }
        if ($conservativeGroundedReal.Count -lt $minGroundedConservativeSessionsForResponsiveTrial) {
            $missingEvidence += "At least $minGroundedConservativeSessionsForResponsiveTrial certified grounded conservative sessions are required before the first live responsive trial."
        }
        if ($conservativeTooQuietReal.Count -lt $minGroundedConservativeTooQuietSessionsForResponsiveTrial) {
            $missingEvidence += "At least $minGroundedConservativeTooQuietSessionsForResponsiveTrial certified grounded conservative too-quiet sessions are required before responsive can open."
        }
        if ($workflowValidationEntries.Count -gt 0) {
            $missingEvidence += "Rehearsal and synthetic workflow-validation sessions are excluded from promotion counts."
        }
        if ($excludedLiveEntries.Count -gt 0) {
            $missingEvidence += "Some registered live sessions still failed grounded-evidence certification and therefore do not count toward promotion."
        }
    }
    "collect-more-conservative-evidence" {
        if ($conservativeGroundedReal.Count -lt $minGroundedConservativeSessionsForResponsiveTrial) {
            $missingEvidence += "Collect another certified grounded conservative pair so the promotion rule spans more than one live session."
        }
        if ($conservativeTooQuietReal.Count -lt $minGroundedConservativeTooQuietSessionsForResponsiveTrial) {
            $missingEvidence += "Collect another certified grounded conservative too-quiet session before opening responsive."
        }
        if ($candidateShadowReviewsDecision.Count -gt 0 -and $candidateShadowResponsiveDecision.Count -eq 0) {
            $missingEvidence += "The current shadow reviews do not yet support responsive as the next candidate on the grounded too-quiet sessions."
        }
    }
    "manual-review-needed" {
        $missingEvidence += "Resolve the conflicting grounded evidence in the pair artifacts before scheduling another live profile choice."
    }
    "responsive-revert-recommended" {
        $missingEvidence += "Do not schedule another responsive live trial until the grounded overreaction evidence has been reviewed and conservative has been re-established as the live default."
    }
    default { }
}

$supportingPairIds = @(Get-SupportingPairIds -Entries $supportingEntries)
$promotionEvidenceScope = "certified-grounded-only"
$gateAgreesWithRegistryRecommendation = $false
if ($null -ne $profileRecommendation) {
    $registryDecision = [string](Get-ObjectPropertyValue -Object $profileRecommendation -Name "decision" -Default "")
    $registryRecommendedProfile = [string](Get-ObjectPropertyValue -Object $profileRecommendation -Name "recommended_live_profile" -Default "")
    $gateAgreesWithRegistryRecommendation = (
        ($nextLiveAction -eq "responsive-trial-allowed" -and $registryRecommendedProfile -eq "responsive") -or
        ($nextLiveAction -ne "responsive-trial-allowed" -and $registryRecommendedProfile -eq "conservative")
    )
}
else {
    $registryDecision = ""
    $registryRecommendedProfile = ""
}

$gate = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    registry_path = $resolvedRegistryPath
    output_root = $resolvedOutputRoot
    gate_config_path = $resolvedGateConfigPath
    registry_summary_available = $null -ne $registrySummary
    registry_summary_path = if ($null -ne $registrySummary) { $resolvedRegistrySummaryPath } else { "" }
    profile_recommendation_available = $null -ne $profileRecommendation
    profile_recommendation_path = if ($null -ne $profileRecommendation) { $resolvedProfileRecommendationPath } else { "" }
    registry_recommendation_available = $null -ne $profileRecommendation
    registry_recommendation_decision = $registryDecision
    registry_recommendation_live_profile = $registryRecommendedProfile
    gate_agrees_with_registry_recommendation = $gateAgreesWithRegistryRecommendation
    gate_verdict = $gateVerdict
    next_live_action = $nextLiveAction
    explanation = $explanation
    promotion_evidence_scope = $promotionEvidenceScope
    synthetic_only_evidence_excluded_from_promotion = $true
    total_registered_sessions = $normalizedEntries.Count
    real_registered_sessions = $liveRegisteredEntries.Count
    synthetic_registered_sessions = $workflowValidationEntries.Count
    certified_grounded_sessions = $decisionScopeEntries.Count
    excluded_registered_sessions = $nonCertifiedEntries.Count
    excluded_sessions_by_reason = $excludedReasonCounts
    insufficient_data_count = $insufficientDataEntries.Count
    weak_signal_count = $weakSignalEntries.Count
    tuning_usable_count = $tuningUsableEntries.Count
    strong_signal_count = $strongSignalEntries.Count
    grounded_conservative_too_quiet_count = $conservativeTooQuietAll.Count
    grounded_responsive_too_reactive_count = $responsiveTooReactiveAll.Count
    conservative_evidence_counts = [ordered]@{
        total_grounded_count = $conservativeGroundedAll.Count
        real_grounded_count = $conservativeGroundedReal.Count
        decision_scope_grounded_count = $conservativeGroundedDecision.Count
        total_grounded_too_quiet_count = $conservativeTooQuietAll.Count
        real_grounded_too_quiet_count = $conservativeTooQuietReal.Count
        real_grounded_appropriately_conservative_count = $conservativeAppropriateReal.Count
        real_grounded_too_reactive_count = $conservativeTooReactiveReal.Count
        real_distinct_grounded_too_quiet_pair_ids_count = @($conservativeTooQuietReal | Select-Object -ExpandProperty pair_id -Unique).Count
        real_shadow_responsive_candidate_count = $candidateShadowResponsiveReal.Count
    }
    responsive_risk_evidence_counts = [ordered]@{
        total_grounded_count = $responsiveGroundedAll.Count
        real_grounded_count = $responsiveGroundedReal.Count
        total_grounded_too_reactive_count = $responsiveTooReactiveAll.Count
        real_grounded_too_reactive_count = $responsiveTooReactiveReal.Count
        real_grounded_appropriately_conservative_count = $responsiveAppropriateReal.Count
    }
    thresholds = $thresholds
    supporting_pair_ids = $supportingPairIds
    missing_evidence = $missingEvidence
}

$controlPort = [int]$trialDefaults.control_port
$treatmentPort = [int]$trialDefaults.treatment_port
$durationSeconds = [int]$trialDefaults.duration_seconds
$waitForHumanJoin = [bool]$trialDefaults.wait_for_human_join
$humanJoinGraceSeconds = [int]$trialDefaults.human_join_grace_seconds
$minHumanSnapshots = [int]$trialDefaults.min_human_snapshots
$minHumanPresenceSeconds = [double]$trialDefaults.min_human_presence_seconds
$trialCommand = "powershell -NoProfile -File .\scripts\run_control_treatment_pair.ps1 -Map $([string]$trialDefaults.map) -BotCount $([int]$trialDefaults.bot_count) -BotSkill $([int]$trialDefaults.bot_skill) -ControlPort $controlPort -TreatmentPort $treatmentPort -DurationSeconds $durationSeconds -WaitForHumanJoin -HumanJoinGraceSeconds $humanJoinGraceSeconds -TreatmentProfile $([string]$trialDefaults.treatment_profile) -SkipSteamCmdUpdate -SkipMetamodDownload"

$postRunWorkflow = @(
    "powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1",
    "powershell -NoProfile -File .\scripts\run_shadow_profile_review.ps1 -UseLatest -Profiles conservative default responsive",
    "powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1",
    "powershell -NoProfile -File .\scripts\register_pair_session_result.ps1",
    "powershell -NoProfile -File .\scripts\summarize_pair_session_registry.ps1 -EvaluateResponsiveTrialGate",
    "powershell -NoProfile -File .\scripts\evaluate_responsive_trial_gate.ps1"
)

$plan = if ($nextLiveAction -eq "responsive-trial-allowed") {
    [ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        registry_path = $resolvedRegistryPath
        gate_verdict = $gateVerdict
        next_live_action = $nextLiveAction
        plan_status = "ready"
        explanation = $explanation
        recommended_map = [string]$trialDefaults.map
        bot_count = [int]$trialDefaults.bot_count
        bot_skill = [int]$trialDefaults.bot_skill
        session_duration_seconds = $durationSeconds
        wait_for_human_join = $waitForHumanJoin
        human_join_grace_seconds = $humanJoinGraceSeconds
        minimum_human_signal_required = [ordered]@{
            min_human_snapshots = $minHumanSnapshots
            min_human_presence_seconds = $minHumanPresenceSeconds
        }
        control_lane = [ordered]@{
            port = $controlPort
            lane_label = [string]$trialDefaults.control_lane_label
            mode = "NoAI"
            jk_ai_balance_enabled = 0
            sidecar = "disabled"
        }
        treatment_lane = [ordered]@{
            port = $treatmentPort
            lane_label = [string]$trialDefaults.treatment_lane_label
            mode = "AI"
            treatment_profile = [string]$trialDefaults.treatment_profile
            sidecar = "enabled"
        }
        trial_command = $trialCommand
        success_criteria = @(
            "Both lanes clear the minimum human-signal gate and the responsive treatment lane reaches tuning-usable or strong-signal evidence.",
            "The responsive live scorecard does not classify the treatment behavior as too reactive.",
            "The pair recommendation does not become responsive-too-reactive-revert-to-conservative or manual-review-needed.",
            "The post-run registry summary and responsive-trial gate do not immediately close the gate because of overreaction."
        )
        overreaction_conditions = @(
            "The responsive treatment lane is assessed as too reactive in the live scorecard.",
            "The responsive live pair produces a responsive-too-reactive-revert-to-conservative recommendation.",
            "The post-run gate reevaluation returns responsive-revert-recommended."
        )
        rollback_condition = "If the live responsive pair produces grounded too-reactive evidence or the reevaluated gate returns responsive-revert-recommended, immediately revert the live treatment profile to conservative."
        post_run_workflow = $postRunWorkflow
        missing_evidence = @()
    }
}
else {
    [ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        registry_path = $resolvedRegistryPath
        gate_verdict = $gateVerdict
        next_live_action = $nextLiveAction
        plan_status = "blocked"
        explanation = $explanation
        missing_evidence = $missingEvidence
        post_run_workflow = $postRunWorkflow
    }
}

$gateJsonPath = Join-Path $resolvedOutputRoot "responsive_trial_gate.json"
$gateMarkdownPath = Join-Path $resolvedOutputRoot "responsive_trial_gate.md"
$planJsonPath = Join-Path $resolvedOutputRoot "responsive_trial_plan.json"
$planMarkdownPath = Join-Path $resolvedOutputRoot "responsive_trial_plan.md"

Write-JsonFile -Path $gateJsonPath -Value $gate
Write-TextFile -Path $gateMarkdownPath -Value (Get-ResponsiveTrialGateMarkdown -Gate $gate)
Write-JsonFile -Path $planJsonPath -Value $plan
Write-TextFile -Path $planMarkdownPath -Value (Get-ResponsiveTrialPlanMarkdown -Plan $plan)

Write-Host "Responsive trial gate:"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Gate JSON: $gateJsonPath"
Write-Host "  Gate Markdown: $gateMarkdownPath"
Write-Host "  Plan JSON: $planJsonPath"
Write-Host "  Plan Markdown: $planMarkdownPath"
Write-Host "  Gate verdict: $gateVerdict"
Write-Host "  Next live action: $nextLiveAction"

[pscustomobject]@{
    RegistryPath = $resolvedRegistryPath
    OutputRoot = $resolvedOutputRoot
    ResponsiveTrialGateJsonPath = $gateJsonPath
    ResponsiveTrialGateMarkdownPath = $gateMarkdownPath
    ResponsiveTrialPlanJsonPath = $planJsonPath
    ResponsiveTrialPlanMarkdownPath = $planMarkdownPath
    GateVerdict = $gateVerdict
    NextLiveAction = $nextLiveAction
}
