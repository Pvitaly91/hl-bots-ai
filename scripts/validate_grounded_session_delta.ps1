[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$PythonPath = ""
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

function Write-NdjsonFile {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($Path, $false, $encoding)
    try {
        foreach ($record in @($Records)) {
            $writer.WriteLine(($record | ConvertTo-Json -Depth 16 -Compress))
        }
    }
    finally {
        $writer.Dispose()
    }
}

function Set-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Object) {
        return
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        return
    }

    $property.Value = $Value
}

function Copy-LiveValidationFixture {
    param(
        [string]$FixtureId,
        [string]$DestinationRoot,
        [string]$PairId
    )

    $sourceRoot = Join-Path (Join-Path (Get-RepoRoot) "ai_director\testdata\pair_sessions") $FixtureId
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        throw "Fixture root was not found: $sourceRoot"
    }

    Copy-Item -LiteralPath $sourceRoot -Destination $DestinationRoot -Recurse

    $pairSummaryPath = Join-Path $DestinationRoot "pair_summary.json"
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    if ($null -eq $pairSummary) {
        throw "Fixture pair summary could not be parsed: $pairSummaryPath"
    }

    Set-ObjectPropertyValue -Object $pairSummary -Name "prompt_id" -Value (Get-RepoPromptId)
    Set-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Value $false
    Set-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Value $false
    Set-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Value $false
    Set-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Value "live"
    Set-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Value $PairId
    Set-ObjectPropertyValue -Object $pairSummary -Name "fixture_note" -Value "Grounded delta-validation fixture copied from deterministic replay. Test-only; do not register into the live ledger."
    Set-ObjectPropertyValue -Object $pairSummary -Name "fixture_description" -Value ([string]$pairSummary.fixture_description)
    Set-ObjectPropertyValue -Object $pairSummary -Name "operator_note" -Value (([string]$pairSummary.operator_note) -replace '^Synthetic fixture:', 'Grounded delta-validation fixture:')
    Set-ObjectPropertyValue -Object $pairSummary -Name "source_commit_sha" -Value (Get-RepoHeadCommitSha)

    Write-JsonFile -Path $pairSummaryPath -Value $pairSummary

    foreach ($laneName in @("control", "treatment")) {
        $sessionPackPath = Join-Path $DestinationRoot ("lanes\{0}\session_pack.json" -f $laneName)
        $sessionPack = Read-JsonFile -Path $sessionPackPath
        if ($null -ne $sessionPack) {
            Set-ObjectPropertyValue -Object $sessionPack -Name "prompt_id" -Value (Get-RepoPromptId)
            Set-ObjectPropertyValue -Object $sessionPack -Name "synthetic_fixture" -Value $false
            Set-ObjectPropertyValue -Object $sessionPack -Name "fixture_note" -Value ([string]$pairSummary.fixture_note)
            Set-ObjectPropertyValue -Object $sessionPack -Name "source_commit_sha" -Value (Get-RepoHeadCommitSha)
            Write-JsonFile -Path $sessionPackPath -Value $sessionPack
        }
    }

    return [ordered]@{
        PairRoot = $DestinationRoot
        PairSummaryPath = $pairSummaryPath
        Metadata = (Read-JsonFile -Path (Join-Path $DestinationRoot "fixture_metadata.json"))
    }
}

function Invoke-FixturePostPipeline {
    param(
        [string]$PairRoot,
        [string]$PythonExecutable,
        [object]$Metadata
    )

    $shadowScriptPath = Join-Path $PSScriptRoot "run_shadow_profile_review.ps1"
    $scoreScriptPath = Join-Path $PSScriptRoot "score_latest_pair_session.ps1"

    & $shadowScriptPath `
        -PairRoot $PairRoot `
        -Profiles conservative default responsive `
        -RequireHumanSignal `
        -MinHumanSnapshots ([int]$Metadata.min_human_snapshots) `
        -MinHumanPresenceSeconds ([double]$Metadata.min_human_presence_seconds) `
        -PythonPath $PythonExecutable | Out-Null

    & $scoreScriptPath -PairRoot $PairRoot | Out-Null
}

function Register-PairIntoRegistry {
    param(
        [string]$PairRoot,
        [string]$RegistryPath
    )

    $registerScriptPath = Join-Path $PSScriptRoot "register_pair_session_result.ps1"
    & $registerScriptPath -PairRoot $PairRoot -RegistryPath $RegistryPath | Out-Null
}

function Invoke-CaseAnalysis {
    param(
        [string]$CaseId,
        [string]$PairRoot,
        [string]$RegistryPath,
        [string]$AnalysisOutputRoot
    )

    $analyzeScriptPath = Join-Path $PSScriptRoot "analyze_latest_grounded_session.ps1"
    & $analyzeScriptPath `
        -PairRoot $PairRoot `
        -RegistryPath $RegistryPath `
        -OutputRoot $AnalysisOutputRoot | Out-Null

    $analysisJsonPath = Join-Path $AnalysisOutputRoot "grounded_session_analysis.json"
    $deltaJsonPath = Join-Path $AnalysisOutputRoot "promotion_gap_delta.json"
    $analysis = Read-JsonFile -Path $analysisJsonPath
    $delta = Read-JsonFile -Path $deltaJsonPath
    if ($null -eq $analysis -or $null -eq $delta) {
        throw "Delta analysis artifacts were not produced for case '$CaseId'."
    }

    return [ordered]@{
        analysis = $analysis
        delta = $delta
        analysis_json_path = $analysisJsonPath
        delta_json_path = $deltaJsonPath
    }
}

function Assert-Condition {
    param(
        [string]$Label,
        [bool]$Condition,
        [string]$FailureMessage
    )

    if (-not $Condition) {
        throw "$Label failed: $FailureMessage"
    }
}

function Get-ValidationMarkdown {
    param([object[]]$Cases)

    $lines = @(
        "# Grounded Session Delta Validation",
        "",
        "- Prompt ID: $(Get-RepoPromptId)",
        "- Generated at UTC: $((Get-Date).ToUniversalTime().ToString('o'))",
        "",
        "## Cases",
        ""
    )

    foreach ($case in $Cases) {
        $lines += "- $($case.case_id): $($case.status) | impact=$($case.actual.impact_classification) | counts=$($case.actual.counts_toward_promotion) | reduced-gap=$($case.actual.reduced_promotion_gap)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Get-LabRootDefault
}
elseif ([System.IO.Path]::IsPathRooted($LabRoot)) {
    $LabRoot
}
else {
    Join-Path $repoRoot $LabRoot
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) ("grounded_session_delta_validation\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
else {
    Join-Path $repoRoot $OutputRoot
}
$resolvedOutputRoot = Ensure-Directory -Path $resolvedOutputRoot
$python = Get-PythonPath -PreferredPath $PythonPath

$cases = @()
$realRegistryRoot = Ensure-Directory -Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot)
$realRegistryPath = Join-Path $realRegistryRoot "pair_sessions.ndjson"
$realSummary = Read-JsonFile -Path (Join-Path $realRegistryRoot "registry_summary.json")
if ($null -eq $realSummary) {
    throw "A current registry summary is required for the non-grounded live-session validation case."
}

$latestRegisteredLivePairRoot = [string]$realSummary.latest_registered_pair_root
if ([string]::IsNullOrWhiteSpace($latestRegisteredLivePairRoot) -or -not (Test-Path -LiteralPath $latestRegisteredLivePairRoot)) {
    throw "The latest registered live pair root could not be resolved from the current registry summary."
}

$case1Root = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "case_non_grounded_latest_live")
$case1Analysis = Invoke-CaseAnalysis `
    -CaseId "non-grounded-latest-live" `
    -PairRoot $latestRegisteredLivePairRoot `
    -RegistryPath $realRegistryPath `
    -AnalysisOutputRoot (Join-Path $case1Root "analysis")
Assert-Condition `
    -Label "non-grounded-latest-live classification" `
    -Condition ($case1Analysis.delta.impact_classification -eq "no-impact-non-grounded-session") `
    -FailureMessage ("Expected no-impact-non-grounded-session but got {0}" -f $case1Analysis.delta.impact_classification)
Assert-Condition `
    -Label "non-grounded-latest-live reduced gap" `
    -Condition (-not [bool]$case1Analysis.delta.reduced_promotion_gap) `
    -FailureMessage "Non-grounded live session should not reduce the promotion gap."
Assert-Condition `
    -Label "non-grounded-latest-live gate stays closed" `
    -Condition ($case1Analysis.delta.responsive_gate_after.gate_verdict -ne "open") `
    -FailureMessage "Non-grounded evidence must not fabricate a responsive gate opening."
$cases += [ordered]@{
    case_id = "non-grounded-latest-live"
    status = "passed"
    actual = [ordered]@{
        impact_classification = [string]$case1Analysis.delta.impact_classification
        counts_toward_promotion = [bool]$case1Analysis.delta.counts_toward_promotion
        reduced_promotion_gap = [bool]$case1Analysis.delta.reduced_promotion_gap
    }
    analysis_json_path = $case1Analysis.analysis_json_path
    delta_json_path = $case1Analysis.delta_json_path
}

$case2Root = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "case_first_grounded_conservative")
$case2PairsRoot = Ensure-Directory -Path (Join-Path $case2Root "pairs")
$case2RegistryRoot = Ensure-Directory -Path (Join-Path $case2Root "registry")
$case2RegistryPath = Join-Path $case2RegistryRoot "pair_sessions.ndjson"
Write-NdjsonFile -Path $case2RegistryPath -Records @()
$case2Pair = Copy-LiveValidationFixture `
    -FixtureId "conservative_acceptable_usable_signal" `
    -DestinationRoot (Join-Path $case2PairsRoot "latest") `
    -PairId "grounded-validation-first-conservative"
Invoke-FixturePostPipeline -PairRoot $case2Pair.PairRoot -PythonExecutable $python -Metadata $case2Pair.Metadata
$case2Analysis = Invoke-CaseAnalysis `
    -CaseId "first-grounded-conservative" `
    -PairRoot $case2Pair.PairRoot `
    -RegistryPath $case2RegistryPath `
    -AnalysisOutputRoot (Join-Path $case2Root "analysis")
Assert-Condition `
    -Label "first-grounded-conservative classification" `
    -Condition ($case2Analysis.delta.impact_classification -eq "first-grounded-conservative-session") `
    -FailureMessage ("Expected first-grounded-conservative-session but got {0}" -f $case2Analysis.delta.impact_classification)
Assert-Condition `
    -Label "first-grounded-conservative grounded delta" `
    -Condition ([int]$case2Analysis.delta.grounded_sessions_delta -eq 1) `
    -FailureMessage "Expected grounded_sessions_delta = 1."
Assert-Condition `
    -Label "first-grounded-conservative reduced gap" `
    -Condition ([bool]$case2Analysis.delta.reduced_promotion_gap) `
    -FailureMessage "First grounded conservative session should reduce the promotion gap."
$cases += [ordered]@{
    case_id = "first-grounded-conservative"
    status = "passed"
    actual = [ordered]@{
        impact_classification = [string]$case2Analysis.delta.impact_classification
        counts_toward_promotion = [bool]$case2Analysis.delta.counts_toward_promotion
        reduced_promotion_gap = [bool]$case2Analysis.delta.reduced_promotion_gap
    }
    analysis_json_path = $case2Analysis.analysis_json_path
    delta_json_path = $case2Analysis.delta_json_path
}

$case3Root = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "case_grounded_too_quiet")
$case3PairsRoot = Ensure-Directory -Path (Join-Path $case3Root "pairs")
$case3RegistryRoot = Ensure-Directory -Path (Join-Path $case3Root "registry")
$case3RegistryPath = Join-Path $case3RegistryRoot "pair_sessions.ndjson"
Write-NdjsonFile -Path $case3RegistryPath -Records @()
$case3BasePair = Copy-LiveValidationFixture `
    -FixtureId "conservative_too_quiet_responsive_candidate" `
    -DestinationRoot (Join-Path $case3PairsRoot "base") `
    -PairId "grounded-validation-base-too-quiet"
$case3LatestPair = Copy-LiveValidationFixture `
    -FixtureId "conservative_too_quiet_responsive_candidate" `
    -DestinationRoot (Join-Path $case3PairsRoot "latest") `
    -PairId "grounded-validation-too-quiet"
Invoke-FixturePostPipeline -PairRoot $case3BasePair.PairRoot -PythonExecutable $python -Metadata $case3BasePair.Metadata
Invoke-FixturePostPipeline -PairRoot $case3LatestPair.PairRoot -PythonExecutable $python -Metadata $case3LatestPair.Metadata
Register-PairIntoRegistry -PairRoot $case3BasePair.PairRoot -RegistryPath $case3RegistryPath
$case3Analysis = Invoke-CaseAnalysis `
    -CaseId "grounded-too-quiet" `
    -PairRoot $case3LatestPair.PairRoot `
    -RegistryPath $case3RegistryPath `
    -AnalysisOutputRoot (Join-Path $case3Root "analysis")
Assert-Condition `
    -Label "grounded-too-quiet classification" `
    -Condition ($case3Analysis.delta.impact_classification -eq "grounded-conservative-too-quiet-evidence-added") `
    -FailureMessage ("Expected grounded-conservative-too-quiet-evidence-added but got {0}" -f $case3Analysis.delta.impact_classification)
Assert-Condition `
    -Label "grounded-too-quiet delta" `
    -Condition ([int]$case3Analysis.delta.grounded_too_quiet_delta -eq 1) `
    -FailureMessage "Expected grounded_too_quiet_delta = 1."
$cases += [ordered]@{
    case_id = "grounded-too-quiet"
    status = "passed"
    actual = [ordered]@{
        impact_classification = [string]$case3Analysis.delta.impact_classification
        counts_toward_promotion = [bool]$case3Analysis.delta.counts_toward_promotion
        reduced_promotion_gap = [bool]$case3Analysis.delta.reduced_promotion_gap
    }
    analysis_json_path = $case3Analysis.analysis_json_path
    delta_json_path = $case3Analysis.delta_json_path
}

$case4Root = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "case_grounded_strong_signal")
$case4PairsRoot = Ensure-Directory -Path (Join-Path $case4Root "pairs")
$case4RegistryRoot = Ensure-Directory -Path (Join-Path $case4Root "registry")
$case4RegistryPath = Join-Path $case4RegistryRoot "pair_sessions.ndjson"
Write-NdjsonFile -Path $case4RegistryPath -Records @()
$case4BasePair = Copy-LiveValidationFixture `
    -FixtureId "conservative_acceptable_usable_signal" `
    -DestinationRoot (Join-Path $case4PairsRoot "base") `
    -PairId "grounded-validation-base-strong-signal"
$case4LatestPair = Copy-LiveValidationFixture `
    -FixtureId "strong_signal_keep_conservative" `
    -DestinationRoot (Join-Path $case4PairsRoot "latest") `
    -PairId "grounded-validation-strong-signal"
Invoke-FixturePostPipeline -PairRoot $case4BasePair.PairRoot -PythonExecutable $python -Metadata $case4BasePair.Metadata
Invoke-FixturePostPipeline -PairRoot $case4LatestPair.PairRoot -PythonExecutable $python -Metadata $case4LatestPair.Metadata
Register-PairIntoRegistry -PairRoot $case4BasePair.PairRoot -RegistryPath $case4RegistryPath
$case4Analysis = Invoke-CaseAnalysis `
    -CaseId "grounded-strong-signal" `
    -PairRoot $case4LatestPair.PairRoot `
    -RegistryPath $case4RegistryPath `
    -AnalysisOutputRoot (Join-Path $case4Root "analysis")
Assert-Condition `
    -Label "grounded-strong-signal classification" `
    -Condition ($case4Analysis.delta.impact_classification -eq "grounded-strong-signal-conservative-added") `
    -FailureMessage ("Expected grounded-strong-signal-conservative-added but got {0}" -f $case4Analysis.delta.impact_classification)
Assert-Condition `
    -Label "grounded-strong-signal delta" `
    -Condition ([int]$case4Analysis.delta.strong_signal_delta -eq 1) `
    -FailureMessage "Expected strong_signal_delta = 1."
$cases += [ordered]@{
    case_id = "grounded-strong-signal"
    status = "passed"
    actual = [ordered]@{
        impact_classification = [string]$case4Analysis.delta.impact_classification
        counts_toward_promotion = [bool]$case4Analysis.delta.counts_toward_promotion
        reduced_promotion_gap = [bool]$case4Analysis.delta.reduced_promotion_gap
    }
    analysis_json_path = $case4Analysis.analysis_json_path
    delta_json_path = $case4Analysis.delta_json_path
}

$case5Root = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "case_responsive_blocker")
$case5PairsRoot = Ensure-Directory -Path (Join-Path $case5Root "pairs")
$case5RegistryRoot = Ensure-Directory -Path (Join-Path $case5Root "registry")
$case5RegistryPath = Join-Path $case5RegistryRoot "pair_sessions.ndjson"
Write-NdjsonFile -Path $case5RegistryPath -Records @()
$case5LatestPair = Copy-LiveValidationFixture `
    -FixtureId "responsive_too_reactive_revert_candidate" `
    -DestinationRoot (Join-Path $case5PairsRoot "latest") `
    -PairId "grounded-validation-responsive-blocker"
Invoke-FixturePostPipeline -PairRoot $case5LatestPair.PairRoot -PythonExecutable $python -Metadata $case5LatestPair.Metadata
$case5Analysis = Invoke-CaseAnalysis `
    -CaseId "responsive-blocker" `
    -PairRoot $case5LatestPair.PairRoot `
    -RegistryPath $case5RegistryPath `
    -AnalysisOutputRoot (Join-Path $case5Root "analysis")
Assert-Condition `
    -Label "responsive-blocker classification" `
    -Condition ($case5Analysis.delta.impact_classification -eq "responsive-blocker-added") `
    -FailureMessage ("Expected responsive-blocker-added but got {0}" -f $case5Analysis.delta.impact_classification)
Assert-Condition `
    -Label "responsive-blocker delta" `
    -Condition ([int]$case5Analysis.delta.responsive_overreaction_blockers_delta -eq 1) `
    -FailureMessage "Expected responsive_overreaction_blockers_delta = 1."
$cases += [ordered]@{
    case_id = "responsive-blocker"
    status = "passed"
    actual = [ordered]@{
        impact_classification = [string]$case5Analysis.delta.impact_classification
        counts_toward_promotion = [bool]$case5Analysis.delta.counts_toward_promotion
        reduced_promotion_gap = [bool]$case5Analysis.delta.reduced_promotion_gap
    }
    analysis_json_path = $case5Analysis.analysis_json_path
    delta_json_path = $case5Analysis.delta_json_path
}

$summaryJsonPath = Join-Path $resolvedOutputRoot "validation_summary.json"
$summaryMarkdownPath = Join-Path $resolvedOutputRoot "validation_summary.md"
$summaryPayload = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    output_root = $resolvedOutputRoot
    cases = $cases
}

Write-JsonFile -Path $summaryJsonPath -Value $summaryPayload
Write-TextFile -Path $summaryMarkdownPath -Value (Get-ValidationMarkdown -Cases $cases)

Write-Host "Grounded-session delta validation:"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Summary JSON: $summaryJsonPath"
Write-Host "  Summary Markdown: $summaryMarkdownPath"
Write-Host "  Cases validated: $($cases.Count)"

[pscustomobject]@{
    OutputRoot = $resolvedOutputRoot
    SummaryJsonPath = $summaryJsonPath
    SummaryMarkdownPath = $summaryMarkdownPath
    CaseCount = $cases.Count
}
