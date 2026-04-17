param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

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

function Select-NextArtifact {
    param(
        [string]$PairClassification,
        [bool]$TreatmentPatchedWhileHumansPresent,
        [string]$PairSummaryMarkdownPath,
        [string]$ComparisonMarkdownPath,
        [string]$ControlSummaryMarkdownPath,
        [string]$TreatmentSummaryMarkdownPath
    )

    if ($PairClassification -in @("tuning-usable", "strong-signal") -and $ComparisonMarkdownPath) {
        return [pscustomobject]@{
            Path = $ComparisonMarkdownPath
            Reason = "The pair already has usable live evidence, so the direct control-vs-treatment comparison is the next artifact worth reading."
        }
    }

    if (-not $TreatmentPatchedWhileHumansPresent -and $TreatmentSummaryMarkdownPath) {
        return [pscustomobject]@{
            Path = $TreatmentSummaryMarkdownPath
            Reason = "Treatment never patched while humans were present, so inspect the treatment lane summary before scheduling another pair."
        }
    }

    if ($PairClassification -eq "plumbing-valid only" -and $PairSummaryMarkdownPath) {
        return [pscustomobject]@{
            Path = $PairSummaryMarkdownPath
            Reason = "This run stayed at plumbing validation only, so confirm the operator note and the missing human signal first."
        }
    }

    if ($TreatmentSummaryMarkdownPath) {
        return [pscustomobject]@{
            Path = $TreatmentSummaryMarkdownPath
            Reason = "The treatment lane is the next place to inspect when the pair is not yet clearly usable."
        }
    }

    if ($ControlSummaryMarkdownPath) {
        return [pscustomobject]@{
            Path = $ControlSummaryMarkdownPath
            Reason = "The control lane summary is the next available artifact."
        }
    }

    return [pscustomobject]@{
        Path = $PairSummaryMarkdownPath
        Reason = "The pair summary is the best available operator artifact."
    }
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

$scorecardJsonPath = Join-Path $resolvedPairRoot "scorecard.json"
$scorecardMarkdownPath = Join-Path $resolvedPairRoot "scorecard.md"
$scoreCommand = "powershell -NoProfile -File .\scripts\score_latest_pair_session.ps1 -PairRoot `"$resolvedPairRoot`""

$pairSummaryJsonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
if (-not $pairSummaryJsonPath) {
    throw "Pair summary JSON was not found under $resolvedPairRoot"
}

$pairSummary = Read-JsonFile -Path $pairSummaryJsonPath
if ($null -eq $pairSummary) {
    throw "Pair summary JSON could not be parsed: $pairSummaryJsonPath"
}

$artifacts = $pairSummary.artifacts
$pairSummaryMarkdownCandidate = if ($artifacts -and $artifacts.pair_summary_markdown) { [string]$artifacts.pair_summary_markdown } else { Join-Path $resolvedPairRoot "pair_summary.md" }
$comparisonJsonCandidate = if ($artifacts -and $artifacts.comparison_json) { [string]$artifacts.comparison_json } else { Join-Path $resolvedPairRoot "comparison.json" }
$comparisonMarkdownCandidate = if ($artifacts -and $artifacts.comparison_markdown) { [string]$artifacts.comparison_markdown } else { Join-Path $resolvedPairRoot "comparison.md" }

$pairSummaryMarkdownPath = Resolve-ExistingPath -Path $pairSummaryMarkdownCandidate
$comparisonJsonPath = Resolve-ExistingPath -Path $comparisonJsonCandidate
$comparisonMarkdownPath = Resolve-ExistingPath -Path $comparisonMarkdownCandidate

$controlSummaryMarkdownPath = Resolve-ExistingPath -Path ([string]$pairSummary.control_lane.summary_markdown)
$controlSessionPackMarkdownPath = Resolve-ExistingPath -Path ([string]$pairSummary.control_lane.session_pack_markdown)
$treatmentSummaryMarkdownPath = Resolve-ExistingPath -Path ([string]$pairSummary.treatment_lane.summary_markdown)
$treatmentSessionPackMarkdownPath = Resolve-ExistingPath -Path ([string]$pairSummary.treatment_lane.session_pack_markdown)

$comparisonPayload = Read-JsonFile -Path $comparisonJsonPath
$comparison = if ($null -ne $comparisonPayload) { $comparisonPayload.comparison } else { $pairSummary.comparison }

$controlLaneVerdict = [string]$pairSummary.control_lane.lane_verdict
$treatmentLaneVerdict = [string]$pairSummary.treatment_lane.lane_verdict
$controlEvidence = [string]$pairSummary.control_lane.evidence_quality
$treatmentEvidence = [string]$pairSummary.treatment_lane.evidence_quality
$pairClassification = [string]$pairSummary.operator_note_classification
$treatmentPatchedWhileHumansPresent = if ($null -ne $comparison) { [bool]$comparison.treatment_patched_while_humans_present } else { $false }
$meaningfulPostPatchWindow = if ($null -ne $comparison) { [bool]$comparison.meaningful_post_patch_observation_window_exists } else { $false }
$comparisonVerdict = if ($null -ne $comparison) { [string]$comparison.comparison_verdict } else { "" }

$nextArtifact = Select-NextArtifact `
    -PairClassification $pairClassification `
    -TreatmentPatchedWhileHumansPresent $treatmentPatchedWhileHumansPresent `
    -PairSummaryMarkdownPath $pairSummaryMarkdownPath `
    -ComparisonMarkdownPath $comparisonMarkdownPath `
    -ControlSummaryMarkdownPath $controlSummaryMarkdownPath `
    -TreatmentSummaryMarkdownPath $treatmentSummaryMarkdownPath

Write-Host "Latest pair run review:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Pair summary JSON: $pairSummaryJsonPath"
Write-Host "  Pair summary Markdown: $pairSummaryMarkdownPath"
Write-Host "  Comparison JSON: $comparisonJsonPath"
Write-Host "  Comparison Markdown: $comparisonMarkdownPath"
Write-Host "  Control summary Markdown: $controlSummaryMarkdownPath"
Write-Host "  Control session pack Markdown: $controlSessionPackMarkdownPath"
Write-Host "  Treatment summary Markdown: $treatmentSummaryMarkdownPath"
Write-Host "  Treatment session pack Markdown: $treatmentSessionPackMarkdownPath"
Write-Host "Summary:"
Write-Host "  Control lane verdict: $controlLaneVerdict"
Write-Host "  Treatment lane verdict: $treatmentLaneVerdict"
Write-Host "  Control evidence quality: $controlEvidence"
Write-Host "  Treatment evidence quality: $treatmentEvidence"
Write-Host "  Treatment patched while humans were present: $treatmentPatchedWhileHumansPresent"
Write-Host "  Meaningful post-patch observation window: $meaningfulPostPatchWindow"
Write-Host "  Pair classification: $pairClassification"
Write-Host "  Comparison verdict: $comparisonVerdict"
Write-Host "  Score helper: $scoreCommand"
Write-Host "  Scorecard JSON path: $scorecardJsonPath"
Write-Host "  Scorecard Markdown path: $scorecardMarkdownPath"
Write-Host "Next artifact to inspect:"
Write-Host "  Path: $($nextArtifact.Path)"
Write-Host "  Reason: $($nextArtifact.Reason)"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    PairSummaryJsonPath = $pairSummaryJsonPath
    PairSummaryMarkdownPath = $pairSummaryMarkdownPath
    ComparisonJsonPath = $comparisonJsonPath
    ComparisonMarkdownPath = $comparisonMarkdownPath
    ControlLaneVerdict = $controlLaneVerdict
    TreatmentLaneVerdict = $treatmentLaneVerdict
    ControlEvidenceQuality = $controlEvidence
    TreatmentEvidenceQuality = $treatmentEvidence
    TreatmentPatchedWhileHumansPresent = $treatmentPatchedWhileHumansPresent
    MeaningfulPostPatchObservationWindowExists = $meaningfulPostPatchWindow
    PairClassification = $pairClassification
    ComparisonVerdict = $comparisonVerdict
    ScoreCommand = $scoreCommand
    ScorecardJsonPath = $scorecardJsonPath
    ScorecardMarkdownPath = $scorecardMarkdownPath
    NextArtifactPath = $nextArtifact.Path
    NextArtifactReason = $nextArtifact.Reason
}
