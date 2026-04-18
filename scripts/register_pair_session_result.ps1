param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$RegistryPath = "",
    [string]$NotesPath = "",
    [switch]$AllowDuplicate
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

    $records = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $records += ($line | ConvertFrom-Json)
    }

    return $records
}

function Append-NdjsonRecord {
    param(
        [string]$Path,
        [object]$Record
    )

    $json = $Record | ConvertTo-Json -Depth 12 -Compress
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $encoding)
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

function Test-UsableHumanSignal {
    param([string]$Label)

    $value = [string]$Label
    return $value -match '(^human-(usable|rich)$)|(-(human-usable|human-rich)$)'
}

function Get-TreatmentBehaviorAssessmentFallback {
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

function Get-EvidenceBucket {
    param(
        [string]$PairClassification,
        [string]$ComparisonVerdict,
        [string]$ControlEvidenceQuality,
        [string]$TreatmentEvidenceQuality,
        [bool]$ComparisonIsTuningUsable
    )

    if ($PairClassification -eq "strong-signal" -or $ComparisonVerdict -eq "comparison-strong-signal") {
        return "strong-signal"
    }

    if ($ComparisonIsTuningUsable -or $PairClassification -eq "tuning-usable" -or $ComparisonVerdict -eq "comparison-usable") {
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

function Get-PairRunIdentity {
    param(
        [string]$PairId,
        [string]$ResolvedPairRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($PairId)) {
        return $PairId
    }

    return Split-Path -Path $ResolvedPairRoot -Leaf
}

function Get-PairRunTimestampHint {
    param([string]$RunIdentity)

    if ([string]::IsNullOrWhiteSpace($RunIdentity)) {
        return ""
    }

    if ($RunIdentity -match '^(?<stamp>\d{8}-\d{6})') {
        try {
            $parsed = [DateTime]::ParseExact(
                $Matches["stamp"],
                "yyyyMMdd-HHmmss",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            return $parsed.ToString("s")
        }
        catch {
        }
    }

    return ""
}

function Resolve-NotesPath {
    param(
        [string]$ExplicitPath,
        [string]$ResolvedPairRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates = @(
            (Get-AbsolutePath -Path $ExplicitPath -BasePath $ResolvedPairRoot),
            (Get-AbsolutePath -Path $ExplicitPath)
        )

        foreach ($candidate in $candidates) {
            $resolved = Resolve-ExistingPath -Path $candidate
            if ($resolved) {
                return $resolved
            }
        }

        Write-Host "Requested notes file was not found; continuing without notes: $ExplicitPath"
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $ResolvedPairRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'notes' } |
        Sort-Object -Property `
            @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, `
            @{ Expression = { $_.Name }; Descending = $false } |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Get-EmbeddedCommitSha {
    param(
        [object]$PairSummary,
        [object]$Scorecard,
        [object]$ControlSessionPack,
        [object]$TreatmentSessionPack
    )

    foreach ($candidate in @(
        [string](Get-ObjectPropertyValue -Object $Scorecard -Name "source_pair_commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $PairSummary -Name "source_commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $PairSummary -Name "commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $ControlSessionPack -Name "source_commit_sha" -Default ""),
        [string](Get-ObjectPropertyValue -Object $TreatmentSessionPack -Name "source_commit_sha" -Default "")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim()
        }
    }

    return ""
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot }
$resolvedPairsRoot = if ([string]::IsNullOrWhiteSpace($PairsRoot)) {
    Get-PairsRootDefault -LabRoot $resolvedLabRoot
}
else {
    Get-AbsolutePath -Path $PairsRoot
}

$resolvedPairRoot = if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    Find-LatestPairRoot -Root $resolvedPairsRoot
}
else {
    Resolve-ExistingPath -Path (Get-AbsolutePath -Path $PairRoot)
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

$comparisonJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "artifacts" -Default $null) -Name "comparison_json" -Default (Join-Path $resolvedPairRoot "comparison.json")))
$comparisonPayload = Read-JsonFile -Path $comparisonJsonPath
$comparison = if ($null -ne $comparisonPayload) {
    Get-ObjectPropertyValue -Object $comparisonPayload -Name "comparison" -Default $null
}
else {
    Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
}

$controlSummaryPayload = Read-JsonFile -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "summary_json" -Default ""))
$treatmentSummaryPayload = Read-JsonFile -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "summary_json" -Default ""))
$controlLaneSummary = if ($null -ne $controlSummaryPayload) { Get-ObjectPropertyValue -Object $controlSummaryPayload -Name "primary_lane" -Default $null } else { $null }
$treatmentLaneSummary = if ($null -ne $treatmentSummaryPayload) { Get-ObjectPropertyValue -Object $treatmentSummaryPayload -Name "primary_lane" -Default $null } else { $null }

$controlSessionPackJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "session_pack_json" -Default ""))
$treatmentSessionPackJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "session_pack_json" -Default ""))
$controlSessionPack = Read-JsonFile -Path $controlSessionPackJsonPath
$treatmentSessionPack = Read-JsonFile -Path $treatmentSessionPackJsonPath

$scorecardJsonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "scorecard.json")
$scorecard = Read-JsonFile -Path $scorecardJsonPath
$scorecardMarkdownPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "scorecard.md")
$shadowProfilesJsonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "shadow_review\shadow_profiles.json")
$shadowProfilesMarkdownPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "shadow_review\shadow_profiles.md")
$shadowRecommendationJsonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "shadow_review\shadow_recommendation.json")
$shadowRecommendationMarkdownPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "shadow_review\shadow_recommendation.md")
$shadowRecommendation = Read-JsonFile -Path $shadowRecommendationJsonPath

$pairId = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default "")
$pairRunIdentity = Get-PairRunIdentity -PairId $pairId -ResolvedPairRoot $resolvedPairRoot
$pairTimestampHint = Get-PairRunTimestampHint -RunIdentity $pairRunIdentity
$pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "pair_classification" -Default ""))
$comparisonVerdict = [string](Get-ObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "comparison_verdict" -Default ""))
$controlLaneVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "lane_verdict" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "control_lane_verdict" -Default ""))
$treatmentLaneVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "lane_verdict" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_lane_verdict" -Default ""))
$controlEvidenceQuality = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "evidence_quality" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "control_evidence_quality" -Default ""))
$treatmentEvidenceQuality = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "evidence_quality" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_evidence_quality" -Default ""))
$treatmentProfile = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "treatment_profile" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_profile" -Default "")))
$controlHumanSignalVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "control_human_signal_verdict" -Default (Get-ObjectPropertyValue -Object $comparison -Name "control_human_signal_verdict" -Default (Get-ObjectPropertyValue -Object $controlLaneSummary -Name "human_signal_verdict" -Default "")))
$treatmentHumanSignalVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "treatment_human_signal_verdict" -Default (Get-ObjectPropertyValue -Object $comparison -Name "treatment_human_signal_verdict" -Default (Get-ObjectPropertyValue -Object $treatmentLaneSummary -Name "human_signal_verdict" -Default "")))
$controlUsableHumanSignal = Test-UsableHumanSignal -Label $controlHumanSignalVerdict
$treatmentUsableHumanSignal = Test-UsableHumanSignal -Label $treatmentHumanSignalVerdict
$comparisonIsTuningUsable = [bool](Get-ObjectPropertyValue -Object $comparison -Name "comparison_is_tuning_usable" -Default $false)
$treatmentPatchedWhileHumansPresent = [bool](Get-ObjectPropertyValue -Object $comparison -Name "treatment_patched_while_humans_present" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patched_while_humans_present" -Default $false))
$meaningfulPostPatchObservationWindowExists = [bool](Get-ObjectPropertyValue -Object $comparison -Name "meaningful_post_patch_observation_window_exists" -Default (Get-ObjectPropertyValue -Object $scorecard -Name "meaningful_post_patch_observation_window_exists" -Default $false))
$treatmentRelativeToControl = [string](Get-ObjectPropertyValue -Object $comparison -Name "treatment_relative_to_control" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patch_signal" -Default $null) -Name "treatment_relative_to_control" -Default ""))
$relativeBehaviorDiscussionReady = [bool](Get-ObjectPropertyValue -Object $comparison -Name "relative_behavior_discussion_ready" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patch_signal" -Default $null) -Name "relative_behavior_discussion_ready" -Default $false))
$apparentBenefitTooWeakToTrust = [bool](Get-ObjectPropertyValue -Object $comparison -Name "apparent_benefit_too_weak_to_trust" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patch_signal" -Default $null) -Name "apparent_benefit_too_weak_to_trust" -Default $false))
$treatmentBehaviorVerdict = [string](Get-ObjectPropertyValue -Object $treatmentLaneSummary -Name "behavior_verdict" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "behavior_verdict" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patch_signal" -Default $null) -Name "treatment_behavior_verdict" -Default "")))
$cooldownConstraintsRespected = [bool](Get-ObjectPropertyValue -Object $treatmentLaneSummary -Name "cooldown_constraints_respected" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patch_signal" -Default $null) -Name "cooldown_constraints_respected" -Default $true))
$boundednessConstraintsRespected = [bool](Get-ObjectPropertyValue -Object $treatmentLaneSummary -Name "boundedness_constraints_respected" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scorecard -Name "treatment_patch_signal" -Default $null) -Name "boundedness_constraints_respected" -Default $true))

$scorecardTreatmentBehaviorAssessment = [string](Get-ObjectPropertyValue -Object $scorecard -Name "treatment_behavior_assessment" -Default "")
if ([string]::IsNullOrWhiteSpace($scorecardTreatmentBehaviorAssessment)) {
    $scorecardTreatmentBehaviorAssessment = Get-TreatmentBehaviorAssessmentFallback `
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
}

$evidenceBucket = Get-EvidenceBucket `
    -PairClassification $pairClassification `
    -ComparisonVerdict $comparisonVerdict `
    -ControlEvidenceQuality $controlEvidenceQuality `
    -TreatmentEvidenceQuality $treatmentEvidenceQuality `
    -ComparisonIsTuningUsable $comparisonIsTuningUsable
$sessionIsTuningUsable = $evidenceBucket -in @("tuning-usable", "strong-signal")
$sessionIsStrongSignal = $evidenceBucket -eq "strong-signal"
$resolvedNotesPath = Resolve-NotesPath -ExplicitPath $NotesPath -ResolvedPairRoot $resolvedPairRoot
$currentPromptId = Get-RepoPromptId
$embeddedCommitSha = Get-EmbeddedCommitSha `
    -PairSummary $pairSummary `
    -Scorecard $scorecard `
    -ControlSessionPack $controlSessionPack `
    -TreatmentSessionPack $treatmentSessionPack

$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Ensure-Directory -Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot)) "pair_sessions.ndjson"
}
else {
    $candidate = Get-AbsolutePath -Path $RegistryPath
    $parent = Split-Path -Path $candidate -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }
    $candidate
}

$existingEntries = @(Read-NdjsonFile -Path $resolvedRegistryPath)
$duplicateEntry = $existingEntries |
    Where-Object {
        [string](Get-ObjectPropertyValue -Object $_ -Name "pair_root" -Default "") -eq $resolvedPairRoot -or
        [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "") -eq $pairId
    } |
    Select-Object -First 1

if ($null -ne $duplicateEntry -and -not $AllowDuplicate) {
    Write-Host "Pair-session registry registration skipped:"
    Write-Host "  Pair root: $resolvedPairRoot"
    Write-Host "  Pair ID: $pairId"
    Write-Host "  Registry path: $resolvedRegistryPath"
    Write-Host "  Reason: an entry for this pair pack is already present. Use -AllowDuplicate only when intentional."

    [pscustomobject]@{
        RegistrationStatus = "skipped-duplicate"
        PairRoot = $resolvedPairRoot
        PairId = $pairId
        RegistryPath = $resolvedRegistryPath
        EvidenceBucket = $evidenceBucket
        ExistingRecommendation = [string](Get-ObjectPropertyValue -Object $duplicateEntry -Name "scorecard_recommendation" -Default "")
    }
    return
}

$entry = [ordered]@{
    schema_version = 1
    registry_prompt_id = $currentPromptId
    registered_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pair_id = $pairId
    pair_root = $resolvedPairRoot
    pair_run_identity = $pairRunIdentity
    pair_run_sort_key = $pairRunIdentity
    pair_timestamp_hint = $pairTimestampHint
    map = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "map" -Default "")
    bot_count = [int](Get-ObjectPropertyValue -Object $pairSummary -Name "bot_count" -Default 0)
    bot_skill = [int](Get-ObjectPropertyValue -Object $pairSummary -Name "bot_skill" -Default 0)
    control_lane_label = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "lane_label" -Default "")
    treatment_lane_label = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "lane_label" -Default "")
    treatment_profile = $treatmentProfile
    pair_classification = $pairClassification
    evidence_bucket = $evidenceBucket
    comparison_verdict = $comparisonVerdict
    control_lane_verdict = $controlLaneVerdict
    treatment_lane_verdict = $treatmentLaneVerdict
    control_evidence_quality = $controlEvidenceQuality
    treatment_evidence_quality = $treatmentEvidenceQuality
    control_human_signal_verdict = $controlHumanSignalVerdict
    treatment_human_signal_verdict = $treatmentHumanSignalVerdict
    treatment_patched_while_humans_present = $treatmentPatchedWhileHumansPresent
    meaningful_post_patch_observation_window_exists = $meaningfulPostPatchObservationWindowExists
    scorecard_recommendation = [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation" -Default "")
    scorecard_recommendation_reason = [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation_reason" -Default "")
    scorecard_treatment_behavior_assessment = $scorecardTreatmentBehaviorAssessment
    shadow_review_present = $null -ne $shadowRecommendation
    shadow_recommendation_decision = [string](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "decision" -Default "")
    shadow_recommendation_explanation = [string](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "explanation" -Default "")
    shadow_responsive_justified_as_next_trial = [bool](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "responsive_justified_as_next_trial" -Default $false)
    shadow_conservative_should_remain_next_live_profile = [bool](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "conservative_should_remain_next_live_profile" -Default $false)
    shadow_evidence_too_weak_for_profile_change = [bool](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "evidence_too_weak_for_profile_change" -Default $false)
    shadow_manual_review_needed = [bool](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "manual_review_needed" -Default $false)
    session_is_tuning_usable = $sessionIsTuningUsable
    session_is_strong_signal = $sessionIsStrongSignal
    notes_path = $resolvedNotesPath
    pair_prompt_id = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "prompt_id" -Default "")
    scorecard_prompt_id = [string](Get-ObjectPropertyValue -Object $scorecard -Name "prompt_id" -Default "")
    control_session_prompt_id = [string](Get-ObjectPropertyValue -Object $controlSessionPack -Name "prompt_id" -Default "")
    treatment_session_prompt_id = [string](Get-ObjectPropertyValue -Object $treatmentSessionPack -Name "prompt_id" -Default "")
    source_commit_sha = $embeddedCommitSha
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryJsonPath
        comparison_json = $comparisonJsonPath
        scorecard_json = $scorecardJsonPath
        scorecard_markdown = $scorecardMarkdownPath
        shadow_profiles_json = $shadowProfilesJsonPath
        shadow_profiles_markdown = $shadowProfilesMarkdownPath
        shadow_recommendation_json = $shadowRecommendationJsonPath
        shadow_recommendation_markdown = $shadowRecommendationMarkdownPath
        control_session_pack_json = $controlSessionPackJsonPath
        treatment_session_pack_json = $treatmentSessionPackJsonPath
        notes_path = $resolvedNotesPath
    }
}

Append-NdjsonRecord -Path $resolvedRegistryPath -Record $entry

$scorecardRecommendation = [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation" -Default "")

Write-Host "Pair-session registry entry appended:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Pair ID: $pairId"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Evidence bucket: $evidenceBucket"
Write-Host "  Treatment profile: $treatmentProfile"
Write-Host "  Scorecard recommendation: $scorecardRecommendation"
if ($null -ne $shadowRecommendation) {
    Write-Host "  Shadow recommendation: $([string]$shadowRecommendation.decision)"
}
if ($resolvedNotesPath) {
    Write-Host "  Notes path: $resolvedNotesPath"
}

[pscustomobject]@{
    RegistrationStatus = "registered"
    PairRoot = $resolvedPairRoot
    PairId = $pairId
    RegistryPath = $resolvedRegistryPath
    EvidenceBucket = $evidenceBucket
    TreatmentProfile = $treatmentProfile
    ScorecardRecommendation = $scorecardRecommendation
    ShadowRecommendation = [string](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "decision" -Default "")
    NotesPath = $resolvedNotesPath
}
