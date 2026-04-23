[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$OutputJson = "",
    [string]$OutputMarkdown = ""
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

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-PairArtifactPath {
    param(
        [string]$Path,
        [string]$ResolvedPairRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path $ResolvedPairRoot $Path
    }

    return Resolve-ExistingPath -Path $candidate
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

$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
if (-not $pairSummaryPath) {
    throw "Pair summary JSON was not found under $resolvedPairRoot"
}

$pairSummary = Read-JsonFile -Path $pairSummaryPath
if ($null -eq $pairSummary) {
    throw "Pair summary JSON could not be parsed: $pairSummaryPath"
}

$comparisonPath = Resolve-PairArtifactPath -Path ([string](Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "artifacts" -Default $null) -Name "comparison_json" -Default "comparison.json")) -ResolvedPairRoot $resolvedPairRoot
$comparisonPayload = Read-JsonFile -Path $comparisonPath
$comparison = if ($null -ne $comparisonPayload) {
    Get-PairSessionCertificationObjectPropertyValue -Object $comparisonPayload -Name "comparison" -Default $null
}
else {
    Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
}

$scorecardPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "scorecard.json")
$scorecard = Read-JsonFile -Path $scorecardPath
$shadowRecommendationPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "shadow_review\\shadow_recommendation.json")
$shadowRecommendation = Read-JsonFile -Path $shadowRecommendationPath
$monitorStatusPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$monitorStatus = Read-JsonFile -Path $monitorStatusPath
$guidedDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\\final_session_docket.json")
$guidedDocket = Read-JsonFile -Path $guidedDocketPath

$pairId = [string](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default "")
$treatmentProfile = [string](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default (Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "treatment_profile" -Default ""))
$pairClassification = [string](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "pair_classification" -Default ""))
$comparisonVerdict = [string](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "comparison_verdict" -Default ""))
$controlEvidenceQuality = [string](Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "evidence_quality" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "control_evidence_quality" -Default ""))
$treatmentEvidenceQuality = [string](Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "evidence_quality" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "treatment_evidence_quality" -Default ""))
$controlHumanSignalVerdict = [string](Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "control_human_signal_verdict" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "control_human_signal_verdict" -Default ""))
$treatmentHumanSignalVerdict = [string](Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "treatment_human_signal_verdict" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "treatment_human_signal_verdict" -Default ""))
$minHumanSnapshots = [int](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "min_human_snapshots" -Default 0)
$minHumanPresenceSeconds = [double](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "min_human_presence_seconds" -Default 0.0)
$controlHumanSnapshotsCount = [int](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "control_human_snapshots_count" -Default (Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "control_human_snapshots_count" -Default -1))
$treatmentHumanSnapshotsCount = [int](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "treatment_human_snapshots_count" -Default (Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "treatment_human_snapshots_count" -Default -1))
$controlSecondsWithHumanPresence = [double](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "control_seconds_with_human_presence" -Default (Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "control_seconds_with_human_presence" -Default -1.0))
$treatmentSecondsWithHumanPresence = [double](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "treatment_seconds_with_human_presence" -Default (Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "human_signal" -Default $null) -Name "treatment_seconds_with_human_presence" -Default -1.0))
$treatmentPatchedWhileHumansPresent = [bool](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "treatment_patched_while_humans_present" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "treatment_patched_while_humans_present" -Default $false))
$meaningfulPostPatchObservationWindowExists = [bool](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "meaningful_post_patch_observation_window_exists" -Default (Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "meaningful_post_patch_observation_window_exists" -Default $false))
$sessionIsTuningUsable = [bool](Get-PairSessionCertificationObjectPropertyValue -Object $comparison -Name "comparison_is_tuning_usable" -Default ($comparisonVerdict -in @("comparison-usable", "comparison-strong-signal")))
$sessionIsStrongSignal = $pairClassification -eq "strong-signal" -or $comparisonVerdict -eq "comparison-strong-signal"
$evidenceBucket = Get-PairSessionEvidenceBucket `
    -PairClassification $pairClassification `
    -ComparisonVerdict $comparisonVerdict `
    -ControlEvidenceQuality $controlEvidenceQuality `
    -TreatmentEvidenceQuality $treatmentEvidenceQuality `
    -SessionIsTuningUsable $sessionIsTuningUsable
$monitorVerdict = if ($null -ne $guidedDocket) {
    [string](Get-PairSessionCertificationObjectPropertyValue -Object (Get-PairSessionCertificationObjectPropertyValue -Object $guidedDocket -Name "monitor" -Default $null) -Name "last_verdict" -Default "")
}
else {
    [string](Get-PairSessionCertificationObjectPropertyValue -Object $monitorStatus -Name "current_verdict" -Default "")
}

$certificate = Get-PairSessionGroundedEvidenceCertification `
    -PairId $pairId `
    -PairRoot $resolvedPairRoot `
    -TreatmentProfile $treatmentProfile `
    -EvidenceOrigin ([string](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default "")) `
    -RehearsalMode ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Default $false)) `
    -Synthetic ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Default $false)) `
    -ValidationOnly ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $pairSummary -Name "validation_only" -Default $false)) `
    -PairClassification $pairClassification `
    -ComparisonVerdict $comparisonVerdict `
    -ControlEvidenceQuality $controlEvidenceQuality `
    -TreatmentEvidenceQuality $treatmentEvidenceQuality `
    -ControlHumanSignalVerdict $controlHumanSignalVerdict `
    -TreatmentHumanSignalVerdict $treatmentHumanSignalVerdict `
    -MinHumanSnapshots $minHumanSnapshots `
    -MinHumanPresenceSeconds $minHumanPresenceSeconds `
    -ControlHumanSnapshotsCount $controlHumanSnapshotsCount `
    -TreatmentHumanSnapshotsCount $treatmentHumanSnapshotsCount `
    -ControlSecondsWithHumanPresence $controlSecondsWithHumanPresence `
    -TreatmentSecondsWithHumanPresence $treatmentSecondsWithHumanPresence `
    -TreatmentPatchedWhileHumansPresent $treatmentPatchedWhileHumansPresent `
    -MeaningfulPostPatchObservationWindowExists $meaningfulPostPatchObservationWindowExists `
    -SessionIsTuningUsable $sessionIsTuningUsable `
    -SessionIsStrongSignal $sessionIsStrongSignal `
    -EvidenceBucket $evidenceBucket `
    -ScorecardRecommendation ([string](Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "recommendation" -Default "")) `
    -TreatmentBehaviorAssessment ([string](Get-PairSessionCertificationObjectPropertyValue -Object $scorecard -Name "treatment_behavior_assessment" -Default "")) `
    -ShadowDecision ([string](Get-PairSessionCertificationObjectPropertyValue -Object $shadowRecommendation -Name "decision" -Default "")) `
    -ShadowManualReviewNeeded ([bool](Get-PairSessionCertificationObjectPropertyValue -Object $shadowRecommendation -Name "manual_review_needed" -Default $false)) `
    -MonitorVerdict $monitorVerdict

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    Join-Path $resolvedPairRoot "grounded_evidence_certificate.json"
}
else {
    Get-AbsolutePath -Path $OutputJson -BasePath $resolvedPairRoot
}
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    Join-Path $resolvedPairRoot "grounded_evidence_certificate.md"
}
else {
    Get-AbsolutePath -Path $OutputMarkdown -BasePath $resolvedPairRoot
}

$certificate["prompt_id"] = Get-RepoPromptId
$certificate["generated_at_utc"] = (Get-Date).ToUniversalTime().ToString("o")
$certificate["source_commit_sha"] = Get-RepoHeadCommitSha
$certificate["artifacts"] = [ordered]@{
    pair_summary_json = $pairSummaryPath
    comparison_json = $comparisonPath
    scorecard_json = $scorecardPath
    shadow_recommendation_json = $shadowRecommendationPath
    live_monitor_status_json = $monitorStatusPath
    guided_final_session_docket_json = $guidedDocketPath
    grounded_evidence_certificate_json = $outputJsonPath
    grounded_evidence_certificate_markdown = $outputMarkdownPath
}

Write-PairSessionCertificationJsonFile -Path $outputJsonPath -Value $certificate
Write-PairSessionCertificationTextFile -Path $outputMarkdownPath -Value (Get-PairSessionGroundedEvidenceCertificateMarkdown -Certificate $certificate)

Write-Host "Grounded evidence certification:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Certificate JSON: $outputJsonPath"
Write-Host "  Certificate Markdown: $outputMarkdownPath"
Write-Host "  Certification verdict: $($certificate.certification_verdict)"
Write-Host "  Counts toward promotion: $($certificate.counts_toward_promotion)"
Write-Host "  Evidence origin: $($certificate.evidence_origin)"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    GroundedEvidenceCertificateJsonPath = $outputJsonPath
    GroundedEvidenceCertificateMarkdownPath = $outputMarkdownPath
    CertificationVerdict = [string]$certificate.certification_verdict
    CountsTowardPromotion = [bool]$certificate.counts_toward_promotion
    EvidenceOrigin = [string]$certificate.evidence_origin
}
