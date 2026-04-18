param(
    [string]$RegistryPath = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [switch]$EvaluateResponsiveTrialGate,
    [switch]$EvaluateNextLiveSessionPlan,
    [string]$ResponsiveTrialGateConfigPath = "",
    [switch]$IncludeSyntheticEvidenceForResponsiveTrialGate
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

function New-ReasonCountMap {
    param([object[]]$Items)

    $counts = [ordered]@{}
    foreach ($item in $Items) {
        foreach ($reason in @($item.grounded_evidence_exclusion_reasons)) {
            $key = if ([string]::IsNullOrWhiteSpace([string]$reason)) { "(missing)" } else { [string]$reason }
            if (-not $counts.Contains($key)) {
                $counts[$key] = 0
            }
            $counts[$key]++
        }
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

function Get-ProfileStats {
    param(
        [string]$ProfileName,
        [object[]]$Entries
    )

    $profileEntries = @($Entries | Where-Object { $_.treatment_profile -eq $ProfileName })
    $certifiedProfileEntries = @($profileEntries | Where-Object { $_.counts_toward_promotion })
    $behaviorCounts = New-CountMap `
        -Items $certifiedProfileEntries `
        -KeySelector { param($entry) $entry.treatment_behavior_assessment } `
        -PreferredKeys @("too quiet", "appropriately conservative", "inconclusive", "too reactive", "unknown")
    $recommendationCounts = New-CountMap `
        -Items $profileEntries `
        -KeySelector { param($entry) $entry.scorecard_recommendation } `
        -PreferredKeys @()

    return [ordered]@{
        treatment_profile = $ProfileName
        total_sessions = $profileEntries.Count
        certified_grounded_sessions = $certifiedProfileEntries.Count
        workflow_validation_sessions = Get-CountValue -Items $profileEntries -Predicate { param($entry) $entry.counts_only_as_workflow_validation }
        excluded_from_promotion_sessions = Get-CountValue -Items $profileEntries -Predicate { param($entry) -not $entry.counts_toward_promotion }
        insufficient_data_count = Get-CountValue -Items $profileEntries -Predicate { param($entry) $entry.evidence_bucket -eq "insufficient-data" }
        weak_signal_count = Get-CountValue -Items $profileEntries -Predicate { param($entry) $entry.evidence_bucket -eq "weak-signal" }
        tuning_usable_count = Get-CountValue -Items $certifiedProfileEntries -Predicate { param($entry) $entry.evidence_bucket -eq "tuning-usable" }
        strong_signal_count = Get-CountValue -Items $certifiedProfileEntries -Predicate { param($entry) $entry.evidence_bucket -eq "strong-signal" }
        tuning_usable_or_strong_count = Get-CountValue -Items $certifiedProfileEntries -Predicate { param($entry) $entry.counts_toward_promotion }
        treatment_patched_while_humans_present_count = Get-CountValue -Items $certifiedProfileEntries -Predicate { param($entry) $entry.treatment_patched_while_humans_present }
        meaningful_post_patch_observation_window_count = Get-CountValue -Items $certifiedProfileEntries -Predicate { param($entry) $entry.meaningful_post_patch_observation_window_exists }
        treatment_behavior_assessment_counts = $behaviorCounts
        scorecard_recommendation_counts = $recommendationCounts
    }
}

function Get-ShadowRecommendationBucket {
    param([string]$Decision)

    switch ($Decision) {
        "keep-conservative" { return "keep-conservative" }
        "conservative-and-default-similar" { return "keep-conservative" }
        "insufficient-data-no-promotion" { return "insufficient-data-no-promotion" }
        "conservative-looks-too-quiet-responsive-candidate" { return "responsive-candidate" }
        "responsive-would-have-overreacted" { return "responsive-too-reactive" }
        "manual-review-needed" { return "manual-review-needed" }
        default { return "(missing)" }
    }
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

function New-ProfileRecommendationResult {
    param(
        [string]$Decision,
        [string]$RecommendedLiveProfile,
        [string]$Reason,
        [string[]]$SupportingPairIds,
        [bool]$KeepConservative,
        [bool]$CollectMoreConservativeEvidenceFirst,
        [bool]$ResponsiveJustifiedAsNextTrial,
        [bool]$RevertFromResponsive,
        [bool]$EvidenceTooWeakForProfileChange,
        [bool]$ManualReviewNeeded
    )

    return [ordered]@{
        decision = $Decision
        recommended_live_profile = $RecommendedLiveProfile
        reason = $Reason
        supporting_pair_ids = $SupportingPairIds
        questions = [ordered]@{
            keep_conservative = $KeepConservative
            collect_more_conservative_evidence_first = $CollectMoreConservativeEvidenceFirst
            responsive_justified_as_next_trial = $ResponsiveJustifiedAsNextTrial
            revert_from_responsive = $RevertFromResponsive
            evidence_too_weak_for_profile_change = $EvidenceTooWeakForProfileChange
            manual_review_needed = $ManualReviewNeeded
        }
    }
}

function Get-ProfileRecommendation {
    param([object[]]$Entries)

    if ($Entries.Count -eq 0) {
        return New-ProfileRecommendationResult `
            -Decision "insufficient-data-repeat-session" `
            -RecommendedLiveProfile "conservative" `
            -Reason "No pair sessions have been registered yet, so there is no cross-session evidence for any profile change." `
            -SupportingPairIds @() `
            -KeepConservative $true `
            -CollectMoreConservativeEvidenceFirst $true `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $true `
            -ManualReviewNeeded $false
    }

    $insufficientEntries = @($Entries | Where-Object { $_.evidence_bucket -eq "insufficient-data" })
    $weakEntries = @($Entries | Where-Object { $_.evidence_bucket -eq "weak-signal" })
    $certifiedEntries = @($Entries | Where-Object { $_.counts_toward_promotion })
    $workflowValidationEntries = @($Entries | Where-Object { $_.counts_only_as_workflow_validation })
    $excludedNonValidationEntries = @($Entries | Where-Object { -not $_.counts_toward_promotion -and -not $_.counts_only_as_workflow_validation })

    $conservativeEntries = @($Entries | Where-Object { $_.treatment_profile -eq "conservative" })
    $responsiveEntries = @($Entries | Where-Object { $_.treatment_profile -eq "responsive" })

    if ($insufficientEntries.Count -eq $Entries.Count) {
        return New-ProfileRecommendationResult `
            -Decision "insufficient-data-repeat-session" `
            -RecommendedLiveProfile "conservative" `
            -Reason "Every registered pair is still plumbing-only or no-human evidence, so there is no certified grounded cross-session basis for a profile change." `
            -SupportingPairIds (Get-SupportingPairIds -Entries $insufficientEntries) `
            -KeepConservative $true `
            -CollectMoreConservativeEvidenceFirst $true `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $true `
            -ManualReviewNeeded $false
    }

    if ($certifiedEntries.Count -eq 0) {
        $reasonParts = @()
        if ($workflowValidationEntries.Count -gt 0) {
            $reasonParts += "$($workflowValidationEntries.Count) registered session(s) are rehearsal or synthetic workflow-validation only"
        }
        if ($excludedNonValidationEntries.Count -gt 0) {
            $reasonParts += "$($excludedNonValidationEntries.Count) registered session(s) were excluded by the grounded-evidence certification rules"
        }
        if ($reasonParts.Count -eq 0) {
            $reasonParts += "no registered session has been certified as grounded promotion evidence yet"
        }

        $supportingEntries = if ($excludedNonValidationEntries.Count -gt 0) { $excludedNonValidationEntries } elseif ($workflowValidationEntries.Count -gt 0) { $workflowValidationEntries } else { $Entries }
        $decision = if ($weakEntries.Count -gt 0) { "weak-signal-repeat-session" } else { "insufficient-data-repeat-session" }

        return New-ProfileRecommendationResult `
            -Decision $decision `
            -RecommendedLiveProfile "conservative" `
            -Reason ("Registered sessions exist, but none count toward promotion because " + (($reasonParts -join "; ") + ".")) `
            -SupportingPairIds (Get-SupportingPairIds -Entries $supportingEntries) `
            -KeepConservative $true `
            -CollectMoreConservativeEvidenceFirst $true `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $true `
            -ManualReviewNeeded $false
    }

    $conservativeGrounded = @($conservativeEntries | Where-Object { $_.counts_toward_promotion })
    $responsiveGrounded = @($responsiveEntries | Where-Object { $_.counts_toward_promotion })

    $conservativeStrong = @($conservativeGrounded | Where-Object { $_.evidence_bucket -eq "strong-signal" })
    $conservativeTooQuiet = @($conservativeGrounded | Where-Object { $_.treatment_behavior_assessment -eq "too quiet" })
    $conservativeAppropriate = @($conservativeGrounded | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })
    $conservativeTooReactive = @($conservativeGrounded | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })

    $responsiveTooReactive = @($responsiveGrounded | Where-Object { $_.treatment_behavior_assessment -eq "too reactive" })
    $responsiveAppropriate = @($responsiveGrounded | Where-Object { $_.treatment_behavior_assessment -eq "appropriately conservative" })

    if ($responsiveTooReactive.Count -gt 0 -and $responsiveAppropriate.Count -gt 0) {
        return New-ProfileRecommendationResult `
            -Decision "manual-review-needed" `
            -RecommendedLiveProfile "conservative" `
            -Reason "Certified grounded responsive evidence is mixed: at least one responsive session looks too reactive and at least one looks appropriately conservative, so the artifacts need manual review before another live choice." `
            -SupportingPairIds (Get-SupportingPairIds -Entries ($responsiveTooReactive + $responsiveAppropriate)) `
            -KeepConservative $false `
            -CollectMoreConservativeEvidenceFirst $false `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $false `
            -ManualReviewNeeded $true
    }

    if ($responsiveTooReactive.Count -gt 0 -and $responsiveAppropriate.Count -eq 0) {
        return New-ProfileRecommendationResult `
            -Decision "responsive-too-reactive-revert-to-conservative" `
            -RecommendedLiveProfile "conservative" `
            -Reason "Responsive already has certified grounded too-reactive evidence and no certified grounded responsive session has yet shown bounded, acceptable live behavior." `
            -SupportingPairIds (Get-SupportingPairIds -Entries $responsiveTooReactive) `
            -KeepConservative $true `
            -CollectMoreConservativeEvidenceFirst $false `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $true `
            -EvidenceTooWeakForProfileChange $false `
            -ManualReviewNeeded $false
    }

    if ($conservativeTooReactive.Count -gt 0) {
        return New-ProfileRecommendationResult `
            -Decision "manual-review-needed" `
            -RecommendedLiveProfile "conservative" `
            -Reason "Certified grounded conservative evidence includes a too-reactive assessment, which should not be promoted or ignored without manual artifact review." `
            -SupportingPairIds (Get-SupportingPairIds -Entries $conservativeTooReactive) `
            -KeepConservative $false `
            -CollectMoreConservativeEvidenceFirst $false `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $false `
            -ManualReviewNeeded $true
    }

    if (
        $conservativeTooQuiet.Count -ge 2 -and
        $conservativeAppropriate.Count -eq 0
    ) {
        return New-ProfileRecommendationResult `
            -Decision "conservative-validated-try-responsive" `
            -RecommendedLiveProfile "responsive" `
            -Reason "Repeated certified grounded conservative sessions say the profile stayed too quiet under real human presence, and there is still no certified grounded conservative session showing appropriately conservative live behavior." `
            -SupportingPairIds (Get-SupportingPairIds -Entries $conservativeTooQuiet) `
            -KeepConservative $false `
            -CollectMoreConservativeEvidenceFirst $false `
            -ResponsiveJustifiedAsNextTrial $true `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $false `
            -ManualReviewNeeded $false
    }

    if ($conservativeAppropriate.Count -ge 1 -and ($conservativeStrong.Count -ge 1 -or $conservativeGrounded.Count -ge 2)) {
        return New-ProfileRecommendationResult `
            -Decision "keep-conservative" `
            -RecommendedLiveProfile "conservative" `
            -Reason "Certified grounded conservative sessions show bounded, human-present treatment behavior without evidence that the profile is too quiet or too reactive." `
            -SupportingPairIds (Get-SupportingPairIds -Entries $conservativeAppropriate) `
            -KeepConservative $true `
            -CollectMoreConservativeEvidenceFirst $false `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $false `
            -ManualReviewNeeded $false
    }

    if ($conservativeGrounded.Count -ge 1) {
        return New-ProfileRecommendationResult `
            -Decision "collect-more-conservative-evidence" `
            -RecommendedLiveProfile "conservative" `
            -Reason "There is some certified grounded conservative evidence, but not enough repeated usable or strong-signal evidence yet to justify promoting or rejecting the profile." `
            -SupportingPairIds (Get-SupportingPairIds -Entries $conservativeGrounded) `
            -KeepConservative $true `
            -CollectMoreConservativeEvidenceFirst $true `
            -ResponsiveJustifiedAsNextTrial $false `
            -RevertFromResponsive $false `
            -EvidenceTooWeakForProfileChange $true `
            -ManualReviewNeeded $false
    }

    return New-ProfileRecommendationResult `
        -Decision "manual-review-needed" `
        -RecommendedLiveProfile "conservative" `
        -Reason "The certified grounded evidence does not fit a clean conservative promotion rule, so the session artifacts need manual review." `
        -SupportingPairIds (Get-SupportingPairIds -Entries $certifiedEntries) `
        -KeepConservative $false `
        -CollectMoreConservativeEvidenceFirst $false `
        -ResponsiveJustifiedAsNextTrial $false `
        -RevertFromResponsive $false `
        -EvidenceTooWeakForProfileChange $false `
        -ManualReviewNeeded $true
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

function Get-RegistrySummaryMarkdown {
    param([object]$Summary)

    $lines = @(
        "# Pair Session Registry Summary",
        "",
        "- Registry path: $($Summary.registry_path)",
        "- Total registered pair sessions: $($Summary.total_registered_pair_sessions)",
        "- Latest registered pair: $($Summary.latest_registered_pair_id)",
        "- Latest registered profile: $($Summary.latest_registered_treatment_profile)",
        "- Sessions with optional notes attached: $($Summary.sessions_with_notes_count)",
        "",
        "## Evidence Buckets",
        ""
    )

    $lines += Get-CountMarkdownLines -Counts $Summary.sessions_by_evidence_bucket
    $lines += @(
        "",
        "## Pair Classifications",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Summary.sessions_by_pair_classification
    $lines += @(
        "",
        "## Treatment Profiles",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Summary.sessions_by_treatment_profile
    $lines += @(
        "",
        "## Certification",
        "",
        "- Total certified grounded sessions: $($Summary.total_certified_grounded_sessions)",
        "- Total non-certified sessions: $($Summary.total_non_certified_sessions)",
        "- Workflow-validation-only sessions: $($Summary.workflow_validation_only_sessions_count)",
        "- Grounded conservative-too-quiet count: $($Summary.grounded_conservative_too_quiet_count)",
        "- Grounded responsive-too-reactive count: $($Summary.grounded_responsive_too_reactive_count)",
        "- Grounded tuning-usable count: $($Summary.grounded_tuning_usable_count)",
        "- Grounded strong-signal count: $($Summary.grounded_strong_signal_count)",
        "",
        "### Excluded Sessions By Reason",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Summary.excluded_sessions_by_reason
    $lines += @(
        "",
        "## Human-Present Patch Evidence",
        "",
        "- Sessions where treatment patched while humans were present: $($Summary.treatment_patched_while_humans_present_count)",
        "- Sessions with a meaningful post-patch observation window: $($Summary.meaningful_post_patch_observation_window_count)",
        "",
        "## Treatment Behavior Assessments",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Summary.treatment_behavior_assessment_counts
    $lines += @(
        "",
        "## Shadow Review",
        "",
        "- Sessions with shadow review present: $($Summary.shadow_review_present_count)",
        "",
        "### Shadow Recommendation Buckets",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Summary.shadow_recommendation_bucket_counts
    $lines += @(
        "",
        "### Shadow Recommendation Decisions",
        ""
    )
    $lines += Get-CountMarkdownLines -Counts $Summary.shadow_recommendation_decision_counts
    $lines += @(
        "",
        "## Per-Profile Snapshot",
        ""
    )

    foreach ($profile in $Summary.profiles) {
        $lines += "- $($profile.treatment_profile): total=$($profile.total_sessions), certified-grounded=$($profile.certified_grounded_sessions), workflow-validation=$($profile.workflow_validation_sessions), tuning-usable=$($profile.tuning_usable_count), strong=$($profile.strong_signal_count), usable-or-strong=$($profile.tuning_usable_or_strong_count)"
    }

    if ([bool](Get-ObjectPropertyValue -Object $Summary -Name "responsive_trial_gate_present" -Default $false)) {
        $lines += @(
            "",
            "## Responsive Trial Gate",
            "",
            "- Gate verdict: $([string](Get-ObjectPropertyValue -Object $Summary -Name 'responsive_trial_gate_verdict' -Default ''))",
            "- Next live action: $([string](Get-ObjectPropertyValue -Object $Summary -Name 'responsive_trial_gate_next_live_action' -Default ''))",
            "- Gate JSON: $([string](Get-ObjectPropertyValue -Object $Summary -Name 'responsive_trial_gate_json' -Default ''))",
            "- Gate Markdown: $([string](Get-ObjectPropertyValue -Object $Summary -Name 'responsive_trial_gate_markdown' -Default ''))"
        )
    }

    $lines += @(
        "",
        "## Recent Sessions",
        ""
    )

    foreach ($entry in $Summary.recent_sessions) {
        $notesLabel = if ($entry.notes_path) { "notes-linked" } else { "no-notes" }
        $lines += "- $($entry.pair_id): profile=$($entry.treatment_profile), bucket=$($entry.evidence_bucket), certified=$($entry.grounded_evidence_certified), recommendation=$($entry.scorecard_recommendation), shadow=$($entry.shadow_recommendation_bucket), behavior=$($entry.treatment_behavior_assessment), $notesLabel"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ProfileRecommendationMarkdown {
    param([object]$Recommendation)

    $lines = @(
        "# Profile Recommendation",
        "",
        "- Decision: $($Recommendation.decision)",
        "- Recommended next live profile: $($Recommendation.recommended_live_profile)",
        "- Should keep conservative: $($Recommendation.questions.keep_conservative)",
        "- Should collect more conservative evidence first: $($Recommendation.questions.collect_more_conservative_evidence_first)",
        "- Is responsive justified as the next trial: $($Recommendation.questions.responsive_justified_as_next_trial)",
        "- Should revert from responsive: $($Recommendation.questions.revert_from_responsive)",
        "- Is the evidence still too weak for a profile change: $($Recommendation.questions.evidence_too_weak_for_profile_change)",
        "- Manual review needed: $($Recommendation.questions.manual_review_needed)",
        "- Reason: $($Recommendation.reason)",
        "",
        "## Evidence Snapshot",
        "",
        "- Total registered pair sessions: $($Recommendation.evidence_snapshot.total_registered_pair_sessions)",
        "- Total certified grounded sessions: $($Recommendation.evidence_snapshot.total_certified_grounded_sessions)",
        "- Workflow-validation-only sessions: $($Recommendation.evidence_snapshot.workflow_validation_only_sessions_count)",
        "- Insufficient-data sessions: $($Recommendation.evidence_snapshot.insufficient_data_count)",
        "- Weak-signal sessions: $($Recommendation.evidence_snapshot.weak_signal_count)",
        "- Grounded tuning-usable sessions: $($Recommendation.evidence_snapshot.grounded_tuning_usable_count)",
        "- Grounded strong-signal sessions: $($Recommendation.evidence_snapshot.grounded_strong_signal_count)",
        "- Conservative usable-or-strong sessions: $($Recommendation.evidence_snapshot.conservative.tuning_usable_or_strong_count)",
        "- Conservative too-quiet grounded sessions: $($Recommendation.evidence_snapshot.conservative.too_quiet_grounded_count)",
        "- Conservative appropriately-conservative grounded sessions: $($Recommendation.evidence_snapshot.conservative.appropriately_conservative_grounded_count)",
        "- Responsive usable-or-strong sessions: $($Recommendation.evidence_snapshot.responsive.tuning_usable_or_strong_count)",
        "- Responsive too-reactive grounded sessions: $($Recommendation.evidence_snapshot.responsive.too_reactive_grounded_count)",
        "",
        "## Supporting Pair IDs",
        ""
    )

    if ($Recommendation.supporting_pair_ids.Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($pairId in $Recommendation.supporting_pair_ids) {
            $lines += "- $pairId"
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

$entries = @(Read-NdjsonFile -Path $resolvedRegistryPath)
$normalizedEntries = @()
foreach ($entry in $entries) {
    $treatmentProfile = [string](Get-ObjectPropertyValue -Object $entry -Name "treatment_profile" -Default "")
    if ([string]::IsNullOrWhiteSpace($treatmentProfile)) {
        $treatmentProfile = "(missing)"
    }

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

    $behaviorAssessment = [string](Get-ObjectPropertyValue -Object $entry -Name "scorecard_treatment_behavior_assessment" -Default "")
    if ([string]::IsNullOrWhiteSpace($behaviorAssessment)) {
        $behaviorAssessment = "unknown"
    }

    $shadowDecision = [string](Get-ObjectPropertyValue -Object $entry -Name "shadow_recommendation_decision" -Default "")
    $shadowBucket = Get-ShadowRecommendationBucket -Decision $shadowDecision
    $certification = Get-PairSessionGroundedEvidenceCertificationFromRegistryEntry -Entry $entry

    $normalizedEntries += [pscustomobject]@{
        pair_id = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default "")
        pair_root = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_root" -Default "")
        pair_run_sort_key = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_run_sort_key" -Default (Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default ""))
        registered_at_utc = [string](Get-ObjectPropertyValue -Object $entry -Name "registered_at_utc" -Default "")
        treatment_profile = $treatmentProfile
        pair_classification = $pairClassification
        comparison_verdict = $comparisonVerdict
        control_evidence_quality = $controlEvidenceQuality
        treatment_evidence_quality = $treatmentEvidenceQuality
        evidence_bucket = $evidenceBucket
        session_is_tuning_usable = $sessionIsTuningUsable -or $evidenceBucket -in @("tuning-usable", "strong-signal")
        session_is_strong_signal = [bool](Get-ObjectPropertyValue -Object $entry -Name "session_is_strong_signal" -Default ($evidenceBucket -eq "strong-signal"))
        treatment_patched_while_humans_present = [bool](Get-ObjectPropertyValue -Object $entry -Name "treatment_patched_while_humans_present" -Default $false)
        meaningful_post_patch_observation_window_exists = [bool](Get-ObjectPropertyValue -Object $entry -Name "meaningful_post_patch_observation_window_exists" -Default $false)
        treatment_behavior_assessment = $behaviorAssessment
        scorecard_recommendation = [string](Get-ObjectPropertyValue -Object $entry -Name "scorecard_recommendation" -Default "")
        shadow_review_present = [bool](Get-ObjectPropertyValue -Object $entry -Name "shadow_review_present" -Default $false)
        shadow_recommendation_decision = $shadowDecision
        shadow_recommendation_bucket = $shadowBucket
        evidence_origin = [string](Get-ObjectPropertyValue -Object $entry -Name "evidence_origin" -Default $certification.evidence_origin)
        synthetic_fixture = [bool](Get-ObjectPropertyValue -Object $entry -Name "synthetic_fixture" -Default $false)
        rehearsal_mode = [bool](Get-ObjectPropertyValue -Object $entry -Name "rehearsal_mode" -Default $false)
        validation_only = [bool](Get-ObjectPropertyValue -Object $entry -Name "validation_only" -Default $false)
        grounded_evidence_certification_verdict = [string]$certification.certification_verdict
        grounded_evidence_certified = [bool]$certification.certified_grounded_evidence
        counts_toward_promotion = [bool]$certification.counts_toward_promotion
        counts_only_as_workflow_validation = [bool]$certification.counts_only_as_workflow_validation
        grounded_evidence_manual_review_needed = [bool]$certification.manual_review_needed
        grounded_evidence_exclusion_reasons = @($certification.exclusion_reasons)
        minimum_human_signal_thresholds_met = [bool]$certification.minimum_human_signal_thresholds_met
        control_meets_minimum_human_signal = [bool]$certification.control_meets_minimum_human_signal
        treatment_meets_minimum_human_signal = [bool]$certification.treatment_meets_minimum_human_signal
        notes_path = [string](Get-ObjectPropertyValue -Object $entry -Name "notes_path" -Default "")
    }
}

$sortedEntries = @(
    $normalizedEntries |
        Sort-Object `
            @{ Expression = { $_.pair_run_sort_key }; Descending = $true }, `
            @{ Expression = { $_.registered_at_utc }; Descending = $true }, `
            @{ Expression = { $_.pair_id }; Descending = $true }
)
$latestEntry = if ($sortedEntries.Count -gt 0) { $sortedEntries[0] } else { $null }

$sessionsByEvidenceBucket = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.evidence_bucket } `
    -PreferredKeys @("insufficient-data", "weak-signal", "tuning-usable", "strong-signal")
$sessionsByPairClassification = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.pair_classification } `
    -PreferredKeys @("plumbing-valid only", "partially usable", "tuning-usable", "strong-signal")
$sessionsByTreatmentProfile = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.treatment_profile } `
    -PreferredKeys @("conservative", "responsive", "default")
$treatmentBehaviorAssessmentCounts = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.treatment_behavior_assessment } `
    -PreferredKeys @("too quiet", "appropriately conservative", "inconclusive", "too reactive", "unknown")
$scorecardRecommendationCounts = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.scorecard_recommendation } `
    -PreferredKeys @()
$shadowRecommendationDecisionCounts = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.shadow_recommendation_decision } `
    -PreferredKeys @(
        "keep-conservative",
        "conservative-and-default-similar",
        "insufficient-data-no-promotion",
        "conservative-looks-too-quiet-responsive-candidate",
        "responsive-would-have-overreacted",
        "manual-review-needed",
        "(missing)"
    )
$shadowRecommendationBucketCounts = New-CountMap `
    -Items $normalizedEntries `
    -KeySelector { param($entry) $entry.shadow_recommendation_bucket } `
    -PreferredKeys @(
        "keep-conservative",
        "insufficient-data-no-promotion",
        "responsive-candidate",
        "responsive-too-reactive",
        "manual-review-needed",
        "(missing)"
    )

$profileNames = @(
    $normalizedEntries |
        Select-Object -ExpandProperty treatment_profile -Unique |
        Sort-Object
)
$profileStats = @()
foreach ($profileName in $profileNames) {
    $profileStats += [pscustomobject](Get-ProfileStats -ProfileName $profileName -Entries $normalizedEntries)
}

$certifiedGroundedEntries = @($normalizedEntries | Where-Object { $_.counts_toward_promotion })
$excludedEntries = @($normalizedEntries | Where-Object { -not $_.counts_toward_promotion })
$workflowValidationEntries = @($normalizedEntries | Where-Object { $_.counts_only_as_workflow_validation })
$excludedReasonCounts = New-ReasonCountMap -Items $excludedEntries
$groundedConservativeTooQuietCount = Get-CountValue -Items $certifiedGroundedEntries -Predicate { param($entry) $entry.treatment_profile -eq "conservative" -and $entry.treatment_behavior_assessment -eq "too quiet" }
$groundedResponsiveTooReactiveCount = Get-CountValue -Items $certifiedGroundedEntries -Predicate { param($entry) $entry.treatment_profile -eq "responsive" -and $entry.treatment_behavior_assessment -eq "too reactive" }
$groundedTuningUsableCount = Get-CountValue -Items $certifiedGroundedEntries -Predicate { param($entry) $entry.evidence_bucket -eq "tuning-usable" }
$groundedStrongSignalCount = Get-CountValue -Items $certifiedGroundedEntries -Predicate { param($entry) $entry.evidence_bucket -eq "strong-signal" }

$summary = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    registry_path = $resolvedRegistryPath
    total_registered_pair_sessions = $normalizedEntries.Count
    latest_registered_pair_id = if ($null -ne $latestEntry) { $latestEntry.pair_id } else { "" }
    latest_registered_pair_root = if ($null -ne $latestEntry) { $latestEntry.pair_root } else { "" }
    latest_registered_treatment_profile = if ($null -ne $latestEntry) { $latestEntry.treatment_profile } else { "" }
    sessions_by_evidence_bucket = $sessionsByEvidenceBucket
    sessions_by_pair_classification = $sessionsByPairClassification
    sessions_by_treatment_profile = $sessionsByTreatmentProfile
    insufficient_data_count = $sessionsByEvidenceBucket["insufficient-data"]
    weak_signal_count = $sessionsByEvidenceBucket["weak-signal"]
    tuning_usable_count = $sessionsByEvidenceBucket["tuning-usable"]
    strong_signal_count = $sessionsByEvidenceBucket["strong-signal"]
    tuning_usable_or_strong_count = Get-CountValue -Items $normalizedEntries -Predicate { param($entry) $entry.session_is_tuning_usable }
    total_certified_grounded_sessions = $certifiedGroundedEntries.Count
    total_non_certified_sessions = $excludedEntries.Count
    workflow_validation_only_sessions_count = $workflowValidationEntries.Count
    excluded_sessions_by_reason = $excludedReasonCounts
    grounded_conservative_too_quiet_count = $groundedConservativeTooQuietCount
    grounded_responsive_too_reactive_count = $groundedResponsiveTooReactiveCount
    grounded_tuning_usable_count = $groundedTuningUsableCount
    grounded_strong_signal_count = $groundedStrongSignalCount
    treatment_patched_while_humans_present_count = Get-CountValue -Items $certifiedGroundedEntries -Predicate { param($entry) $entry.treatment_patched_while_humans_present }
    meaningful_post_patch_observation_window_count = Get-CountValue -Items $certifiedGroundedEntries -Predicate { param($entry) $entry.meaningful_post_patch_observation_window_exists }
    treatment_behavior_assessment_counts = $treatmentBehaviorAssessmentCounts
    scorecard_recommendation_counts = $scorecardRecommendationCounts
    shadow_review_present_count = Get-CountValue -Items $normalizedEntries -Predicate { param($entry) $entry.shadow_review_present }
    shadow_recommendation_decision_counts = $shadowRecommendationDecisionCounts
    shadow_recommendation_bucket_counts = $shadowRecommendationBucketCounts
    sessions_with_notes_count = Get-CountValue -Items $normalizedEntries -Predicate { param($entry) -not [string]::IsNullOrWhiteSpace($entry.notes_path) }
    responsive_trial_gate_present = $false
    responsive_trial_gate_verdict = ""
    responsive_trial_gate_next_live_action = ""
    responsive_trial_gate_json = ""
    responsive_trial_gate_markdown = ""
    next_live_plan_present = $false
    next_live_session_objective = ""
    next_live_recommended_live_profile = ""
    next_live_plan_json = ""
    next_live_plan_markdown = ""
    profiles = $profileStats
    recent_sessions = @($sortedEntries | Select-Object -First 10)
}

$recommendationCore = Get-ProfileRecommendation -Entries $normalizedEntries
$conservativeStats = $profileStats | Where-Object { $_.treatment_profile -eq "conservative" } | Select-Object -First 1
$responsiveStats = $profileStats | Where-Object { $_.treatment_profile -eq "responsive" } | Select-Object -First 1

if ($null -eq $conservativeStats) {
    $conservativeStats = [pscustomobject](Get-ProfileStats -ProfileName "conservative" -Entries @())
}
if ($null -eq $responsiveStats) {
    $responsiveStats = [pscustomobject](Get-ProfileStats -ProfileName "responsive" -Entries @())
}

$profileRecommendation = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    registry_path = $resolvedRegistryPath
    decision = $recommendationCore.decision
    recommended_live_profile = $recommendationCore.recommended_live_profile
    reason = $recommendationCore.reason
    supporting_pair_ids = $recommendationCore.supporting_pair_ids
    questions = $recommendationCore.questions
    latest_registered_pair_id = if ($null -ne $latestEntry) { $latestEntry.pair_id } else { "" }
    latest_registered_treatment_profile = if ($null -ne $latestEntry) { $latestEntry.treatment_profile } else { "" }
    evidence_snapshot = [ordered]@{
        total_registered_pair_sessions = $summary.total_registered_pair_sessions
        total_certified_grounded_sessions = $summary.total_certified_grounded_sessions
        workflow_validation_only_sessions_count = $summary.workflow_validation_only_sessions_count
        insufficient_data_count = $summary.insufficient_data_count
        weak_signal_count = $summary.weak_signal_count
        grounded_tuning_usable_count = $summary.grounded_tuning_usable_count
        grounded_strong_signal_count = $summary.grounded_strong_signal_count
        treatment_patched_while_humans_present_count = $summary.treatment_patched_while_humans_present_count
        meaningful_post_patch_observation_window_count = $summary.meaningful_post_patch_observation_window_count
        conservative = [ordered]@{
            total_sessions = $conservativeStats.total_sessions
            certified_grounded_sessions = $conservativeStats.certified_grounded_sessions
            tuning_usable_or_strong_count = $conservativeStats.tuning_usable_or_strong_count
            too_quiet_grounded_count = [int]$conservativeStats.treatment_behavior_assessment_counts["too quiet"]
            appropriately_conservative_grounded_count = [int]$conservativeStats.treatment_behavior_assessment_counts["appropriately conservative"]
            too_reactive_grounded_count = [int]$conservativeStats.treatment_behavior_assessment_counts["too reactive"]
            strong_signal_count = $conservativeStats.strong_signal_count
        }
        responsive = [ordered]@{
            total_sessions = $responsiveStats.total_sessions
            certified_grounded_sessions = $responsiveStats.certified_grounded_sessions
            tuning_usable_or_strong_count = $responsiveStats.tuning_usable_or_strong_count
            too_reactive_grounded_count = [int]$responsiveStats.treatment_behavior_assessment_counts["too reactive"]
            appropriately_conservative_grounded_count = [int]$responsiveStats.treatment_behavior_assessment_counts["appropriately conservative"]
            strong_signal_count = $responsiveStats.strong_signal_count
        }
    }
}

$registrySummaryJsonPath = Join-Path $resolvedOutputRoot "registry_summary.json"
$registrySummaryMarkdownPath = Join-Path $resolvedOutputRoot "registry_summary.md"
$profileRecommendationJsonPath = Join-Path $resolvedOutputRoot "profile_recommendation.json"
$profileRecommendationMarkdownPath = Join-Path $resolvedOutputRoot "profile_recommendation.md"

Write-JsonFile -Path $registrySummaryJsonPath -Value $summary
Write-TextFile -Path $registrySummaryMarkdownPath -Value (Get-RegistrySummaryMarkdown -Summary $summary)
Write-JsonFile -Path $profileRecommendationJsonPath -Value $profileRecommendation
Write-TextFile -Path $profileRecommendationMarkdownPath -Value (Get-ProfileRecommendationMarkdown -Recommendation $profileRecommendation)

$responsiveTrialGateJsonPath = Join-Path $resolvedOutputRoot "responsive_trial_gate.json"
$responsiveTrialGateMarkdownPath = Join-Path $resolvedOutputRoot "responsive_trial_gate.md"

if ($EvaluateResponsiveTrialGate) {
    $gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"
    $gateScriptParams = @{
        RegistryPath = $resolvedRegistryPath
        OutputRoot = $resolvedOutputRoot
        RegistrySummaryPath = $registrySummaryJsonPath
        ProfileRecommendationPath = $profileRecommendationJsonPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ResponsiveTrialGateConfigPath)) {
        $gateScriptParams.GateConfigPath = $ResponsiveTrialGateConfigPath
    }
    if ($IncludeSyntheticEvidenceForResponsiveTrialGate) {
        $gateScriptParams.IncludeSyntheticEvidenceForValidation = $true
    }

    & $gateScriptPath @gateScriptParams | Out-Null
}

$responsiveTrialGate = Read-JsonFile -Path $responsiveTrialGateJsonPath
if ($null -ne $responsiveTrialGate) {
    $summary.responsive_trial_gate_present = $true
    $summary.responsive_trial_gate_verdict = [string](Get-ObjectPropertyValue -Object $responsiveTrialGate -Name "gate_verdict" -Default "")
    $summary.responsive_trial_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $responsiveTrialGate -Name "next_live_action" -Default "")
    $summary.responsive_trial_gate_json = $responsiveTrialGateJsonPath
    $summary.responsive_trial_gate_markdown = $responsiveTrialGateMarkdownPath

    Write-JsonFile -Path $registrySummaryJsonPath -Value $summary
    Write-TextFile -Path $registrySummaryMarkdownPath -Value (Get-RegistrySummaryMarkdown -Summary $summary)
}

$nextLivePlanJsonPath = Join-Path $resolvedOutputRoot "next_live_plan.json"
$nextLivePlanMarkdownPath = Join-Path $resolvedOutputRoot "next_live_plan.md"
if ($EvaluateNextLiveSessionPlan) {
    $plannerScriptPath = Join-Path $PSScriptRoot "plan_next_live_session.ps1"
    $plannerParams = @{
        RegistryPath = $resolvedRegistryPath
        OutputRoot = $resolvedOutputRoot
        RegistrySummaryPath = $registrySummaryJsonPath
        ProfileRecommendationPath = $profileRecommendationJsonPath
        ResponsiveTrialGatePath = $responsiveTrialGateJsonPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ResponsiveTrialGateConfigPath)) {
        $plannerParams.GateConfigPath = $ResponsiveTrialGateConfigPath
    }

    & $plannerScriptPath @plannerParams | Out-Null
}

$nextLivePlan = Read-JsonFile -Path $nextLivePlanJsonPath
if ($null -ne $nextLivePlan) {
    $summary.next_live_plan_present = $true
    $summary.next_live_session_objective = [string](Get-ObjectPropertyValue -Object $nextLivePlan -Name "recommended_next_session_objective" -Default "")
    $summary.next_live_recommended_live_profile = [string](Get-ObjectPropertyValue -Object $nextLivePlan -Name "recommended_next_live_profile" -Default "")
    $summary.next_live_plan_json = $nextLivePlanJsonPath
    $summary.next_live_plan_markdown = $nextLivePlanMarkdownPath

    Write-JsonFile -Path $registrySummaryJsonPath -Value $summary
    Write-TextFile -Path $registrySummaryMarkdownPath -Value (Get-RegistrySummaryMarkdown -Summary $summary)
}

Write-Host "Pair-session registry summary:"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Registered pair sessions: $($summary.total_registered_pair_sessions)"
Write-Host "  Registry summary JSON: $registrySummaryJsonPath"
Write-Host "  Registry summary Markdown: $registrySummaryMarkdownPath"
Write-Host "  Profile recommendation JSON: $profileRecommendationJsonPath"
Write-Host "  Profile recommendation Markdown: $profileRecommendationMarkdownPath"
Write-Host "  Recommendation: $($profileRecommendation.decision)"
Write-Host "  Recommended next live profile: $($profileRecommendation.recommended_live_profile)"
if ($summary.responsive_trial_gate_present) {
    Write-Host "  Responsive trial gate verdict: $($summary.responsive_trial_gate_verdict)"
    Write-Host "  Responsive trial next live action: $($summary.responsive_trial_gate_next_live_action)"
}
if ($summary.next_live_plan_present) {
    Write-Host "  Next-live plan objective: $($summary.next_live_session_objective)"
    Write-Host "  Next-live recommended profile: $($summary.next_live_recommended_live_profile)"
}

[pscustomobject]@{
    RegistryPath = $resolvedRegistryPath
    TotalRegisteredPairSessions = $summary.total_registered_pair_sessions
    RegistrySummaryJsonPath = $registrySummaryJsonPath
    RegistrySummaryMarkdownPath = $registrySummaryMarkdownPath
    ProfileRecommendationJsonPath = $profileRecommendationJsonPath
    ProfileRecommendationMarkdownPath = $profileRecommendationMarkdownPath
    Recommendation = $profileRecommendation.decision
    RecommendedLiveProfile = $profileRecommendation.recommended_live_profile
    ResponsiveTrialGateJsonPath = if ($summary.responsive_trial_gate_present) { $responsiveTrialGateJsonPath } else { "" }
    ResponsiveTrialGateMarkdownPath = if ($summary.responsive_trial_gate_present) { $responsiveTrialGateMarkdownPath } else { "" }
    ResponsiveTrialGateVerdict = $summary.responsive_trial_gate_verdict
    ResponsiveTrialGateNextLiveAction = $summary.responsive_trial_gate_next_live_action
    NextLivePlanJsonPath = if ($summary.next_live_plan_present) { $nextLivePlanJsonPath } else { "" }
    NextLivePlanMarkdownPath = if ($summary.next_live_plan_present) { $nextLivePlanMarkdownPath } else { "" }
    NextLiveSessionObjective = $summary.next_live_session_objective
    NextLiveRecommendedLiveProfile = $summary.next_live_recommended_live_profile
}
