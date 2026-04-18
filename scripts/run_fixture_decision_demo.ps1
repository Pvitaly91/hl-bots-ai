param(
    [string]$FixtureRoot = "",
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

function Get-DemoMarkdown {
    param(
        [object[]]$Rows,
        [object]$RegistryRecommendation,
        [string]$RegistrySummaryPath,
        [string]$ProfileRecommendationPath
    )

    $lines = @(
        "# Synthetic Fixture Decision Demo",
        "",
        "- Synthetic fixtures only: True",
        "- Registry summary JSON: $RegistrySummaryPath",
        "- Profile recommendation JSON: $ProfileRecommendationPath",
        "- Aggregate decision: $($RegistryRecommendation.decision)",
        "- Aggregate recommended live profile: $($RegistryRecommendation.recommended_live_profile)",
        "",
        "## Fixture Outcomes",
        ""
    )

    foreach ($row in $Rows) {
        $lines += "- $($row.fixture_id): pair=$($row.pair_classification), comparison=$($row.comparison_verdict), scorecard=$($row.scorecard_recommendation), shadow=$($row.shadow_decision)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedFixtureRoot = if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
    Join-Path (Get-RepoRoot) "ai_director\testdata\pair_sessions"
}
else {
    $FixtureRoot
}

if (-not (Test-Path -LiteralPath $resolvedFixtureRoot)) {
    throw "Fixture root was not found: $resolvedFixtureRoot"
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Join-Path (Get-EvalRootDefault -LabRoot (Get-LabRootDefault)) ("fixture_demo\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
else {
    $OutputRoot
}
$resolvedOutputRoot = Ensure-Directory -Path $resolvedOutputRoot
$pairsOutputRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "pairs")
$registryRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "registry")
$registryPath = Join-Path $registryRoot "pair_sessions.ndjson"
if (Test-Path -LiteralPath $registryPath) {
    Remove-Item -LiteralPath $registryPath -Force
}

$python = Get-PythonPath -PreferredPath $PythonPath
$rows = @()
$shadowScript = Join-Path $PSScriptRoot "run_shadow_profile_review.ps1"
$scoreScript = Join-Path $PSScriptRoot "score_latest_pair_session.ps1"
$registerScript = Join-Path $PSScriptRoot "register_pair_session_result.ps1"
$summaryScript = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"

$fixturePairs = Get-ChildItem -LiteralPath $resolvedFixtureRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "pair_summary.json") } |
    Sort-Object Name

foreach ($fixture in $fixturePairs) {
    $pairOutputRoot = Join-Path $pairsOutputRoot $fixture.Name
    Copy-Item -LiteralPath $fixture.FullName -Destination $pairOutputRoot -Recurse

    $metadata = Read-JsonFile -Path (Join-Path $pairOutputRoot "fixture_metadata.json")
    if ($null -eq $metadata) {
        throw "Fixture metadata was not found under $pairOutputRoot"
    }

    & $shadowScript `
        -PairRoot $pairOutputRoot `
        -Profiles conservative default responsive `
        -RequireHumanSignal `
        -MinHumanSnapshots ([int]$metadata.min_human_snapshots) `
        -MinHumanPresenceSeconds ([double]$metadata.min_human_presence_seconds) `
        -PythonPath $python | Out-Null

    & $scoreScript -PairRoot $pairOutputRoot | Out-Null
    & $registerScript -PairRoot $pairOutputRoot -RegistryPath $registryPath | Out-Null

    $scorecard = Read-JsonFile -Path (Join-Path $pairOutputRoot "scorecard.json")
    $shadow = Read-JsonFile -Path (Join-Path $pairOutputRoot "shadow_review\shadow_recommendation.json")
    $rows += [pscustomobject]@{
        fixture_id = [string]$metadata.fixture_id
        description = [string]$metadata.description
        pair_classification = [string]$scorecard.pair_classification
        comparison_verdict = [string]$scorecard.comparison_verdict
        scorecard_recommendation = [string]$scorecard.recommendation
        shadow_decision = [string]$shadow.decision
    }
}

& $summaryScript -RegistryPath $registryPath -OutputRoot $registryRoot | Out-Null

$registrySummaryPath = Join-Path $registryRoot "registry_summary.json"
$profileRecommendationPath = Join-Path $registryRoot "profile_recommendation.json"
$profileRecommendation = Read-JsonFile -Path $profileRecommendationPath
$demoSummaryPath = Join-Path $resolvedOutputRoot "demo_summary.json"
$demoMarkdownPath = Join-Path $resolvedOutputRoot "demo_summary.md"
$demoPayload = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    fixture_root = $resolvedFixtureRoot
    output_root = $resolvedOutputRoot
    registry_path = $registryPath
    registry_summary_json = $registrySummaryPath
    profile_recommendation_json = $profileRecommendationPath
    fixtures = $rows
    aggregate_recommendation = $profileRecommendation
}

Write-JsonFile -Path $demoSummaryPath -Value $demoPayload
Write-TextFile -Path $demoMarkdownPath -Value (
    Get-DemoMarkdown `
        -Rows $rows `
        -RegistryRecommendation $profileRecommendation `
        -RegistrySummaryPath $registrySummaryPath `
        -ProfileRecommendationPath $profileRecommendationPath
)

Write-Host "Synthetic fixture decision demo:"
Write-Host "  Fixture root: $resolvedFixtureRoot"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Registry path: $registryPath"
Write-Host "  Demo summary JSON: $demoSummaryPath"
Write-Host "  Demo summary Markdown: $demoMarkdownPath"
Write-Host "  Aggregate decision: $($profileRecommendation.decision)"
Write-Host "  Aggregate recommended live profile: $($profileRecommendation.recommended_live_profile)"

[pscustomobject]@{
    FixtureRoot = $resolvedFixtureRoot
    OutputRoot = $resolvedOutputRoot
    RegistryPath = $registryPath
    DemoSummaryJsonPath = $demoSummaryPath
    DemoSummaryMarkdownPath = $demoMarkdownPath
    AggregateDecision = [string]$profileRecommendation.decision
    RecommendedLiveProfile = [string]$profileRecommendation.recommended_live_profile
}
