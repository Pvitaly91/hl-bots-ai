[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$LaneRoot = "",
    [ValidateSet("conservative", "default", "responsive")]
    [string[]]$Profiles = @("conservative", "default", "responsive"),
    [string]$OutputRoot = "",
    [switch]$UseLatest,
    [switch]$RequireHumanSignal,
    [int]$MinHumanSnapshots = -1,
    [double]$MinHumanPresenceSeconds = -1,
    [string]$LabRoot = "",
    [string]$PythonPath = "",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalProfiles
)

. (Join-Path $PSScriptRoot "common.ps1")

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

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Resolve-ProfileList {
    param(
        [string[]]$Primary,
        [string[]]$Additional
    )

    $resolved = @()
    foreach ($name in @($Primary + $Additional)) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        switch ($name.Trim()) {
            "conservative" { $resolved += "conservative" }
            "default" { $resolved += "default" }
            "responsive" { $resolved += "responsive" }
            default { throw "Unknown profile '$name'. Supported values: conservative, default, responsive." }
        }
    }

    if ($resolved.Count -eq 0) {
        return @("conservative", "default", "responsive")
    }

    return @($resolved | Select-Object -Unique)
}

function Find-LatestPairRoot {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.DirectoryName
}

function Resolve-PairRootFromLaneRoot {
    param([string]$ResolvedLaneRoot)

    if ([string]::IsNullOrWhiteSpace($ResolvedLaneRoot)) {
        return ""
    }

    $current = [System.IO.DirectoryInfo](Get-Item -LiteralPath $ResolvedLaneRoot)
    while ($null -ne $current) {
        $candidate = Join-Path $current.FullName "pair_summary.json"
        if (Test-Path -LiteralPath $candidate) {
            return $current.FullName
        }
        $current = $current.Parent
    }

    return ""
}

function Resolve-TreatmentLaneRootFromPairRoot {
    param([string]$ResolvedPairRoot)

    $pairSummary = Read-JsonFile -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    if ($null -eq $pairSummary) {
        throw "Pair summary could not be read from $ResolvedPairRoot"
    }

    $laneRoot = Resolve-ExistingPath -Path (Get-AbsolutePath -Path ([string]$pairSummary.treatment_lane.lane_root) -BasePath $ResolvedPairRoot)
    if (-not $laneRoot) {
        throw "Treatment lane root was not recorded in $ResolvedPairRoot"
    }

    return $laneRoot
}

function Find-LatestTreatmentLaneRoot {
    param([string]$EvalRoot)

    if (-not (Test-Path -LiteralPath $EvalRoot)) {
        return ""
    }

    $sessionPacks = Get-ChildItem -LiteralPath $EvalRoot -Filter "session_pack.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($sessionPack in $sessionPacks) {
        $payload = Read-JsonFile -Path $sessionPack.FullName
        if ($null -eq $payload) {
            continue
        }

        if ([string]$payload.mode -eq "AI") {
            return $sessionPack.DirectoryName
        }
    }

    return ""
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Get-LabRootDefault
}
else {
    Get-AbsolutePath -Path $LabRoot
}
$pairsRoot = Get-PairsRootDefault -LabRoot $resolvedLabRoot
$evalRoot = Get-EvalRootDefault -LabRoot $resolvedLabRoot

$resolvedPairRoot = ""
$resolvedLaneRoot = ""
$resolvedProfiles = Resolve-ProfileList -Primary $Profiles -Additional $AdditionalProfiles

if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
    $resolvedPairRoot = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $PairRoot)
    if (-not $resolvedPairRoot) {
        throw "Pair root was not found: $PairRoot"
    }
    $resolvedLaneRoot = Resolve-TreatmentLaneRootFromPairRoot -ResolvedPairRoot $resolvedPairRoot
}
elseif (-not [string]::IsNullOrWhiteSpace($LaneRoot)) {
    $resolvedLaneRoot = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $LaneRoot)
    if (-not $resolvedLaneRoot) {
        throw "Lane root was not found: $LaneRoot"
    }
    $resolvedPairRoot = Resolve-PairRootFromLaneRoot -ResolvedLaneRoot $resolvedLaneRoot
}
else {
    $resolvedPairRoot = Find-LatestPairRoot -Root $pairsRoot
    if ($resolvedPairRoot) {
        $resolvedLaneRoot = Resolve-TreatmentLaneRootFromPairRoot -ResolvedPairRoot $resolvedPairRoot
    }
    else {
        $resolvedLaneRoot = Find-LatestTreatmentLaneRoot -EvalRoot $evalRoot
        if (-not $resolvedLaneRoot) {
            throw "No captured treatment lane or pair pack was found under $evalRoot"
        }
        $resolvedPairRoot = Resolve-PairRootFromLaneRoot -ResolvedLaneRoot $resolvedLaneRoot
    }
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    if ($resolvedPairRoot) {
        Join-Path $resolvedPairRoot "shadow_review"
    }
    else {
        Join-Path $resolvedLaneRoot "shadow_review"
    }
}
else {
    $outputBasePath = if ($resolvedPairRoot) { $resolvedPairRoot } else { $resolvedLaneRoot }
    Get-AbsolutePath -Path $OutputRoot -BasePath $outputBasePath
}
$resolvedOutputRoot = Ensure-Directory -Path $resolvedOutputRoot

$python = Get-PythonPath -PreferredPath $PythonPath
$toolPath = Join-Path (Get-RepoRoot) "ai_director\tools\replay_captured_lane_with_profiles.py"
if (-not (Test-Path -LiteralPath $toolPath)) {
    throw "Shadow replay tool was not found: $toolPath"
}

$arguments = @(
    $toolPath
    "--output-root"
    $resolvedOutputRoot
)

if ($resolvedPairRoot) {
    $arguments += @("--pair-root", $resolvedPairRoot)
}
else {
    $arguments += @("--lane-root", $resolvedLaneRoot)
}

if ($Profiles.Count -gt 0) {
    $arguments += "--profiles"
    $arguments += $resolvedProfiles
}
if ($RequireHumanSignal) {
    $arguments += "--require-human-signal"
}
if ($MinHumanSnapshots -ge 0) {
    $arguments += @("--min-human-snapshots", [string]$MinHumanSnapshots)
}
if ($MinHumanPresenceSeconds -ge 0) {
    $arguments += @("--min-human-presence-seconds", [string]$MinHumanPresenceSeconds)
}

& $python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Shadow replay tool failed with exit code $LASTEXITCODE"
}

$shadowProfilesJsonPath = Join-Path $resolvedOutputRoot "shadow_profiles.json"
$shadowProfilesMarkdownPath = Join-Path $resolvedOutputRoot "shadow_profiles.md"
$shadowRecommendationJsonPath = Join-Path $resolvedOutputRoot "shadow_recommendation.json"
$shadowRecommendationMarkdownPath = Join-Path $resolvedOutputRoot "shadow_recommendation.md"

foreach ($requiredPath in @(
    $shadowProfilesJsonPath,
    $shadowProfilesMarkdownPath,
    $shadowRecommendationJsonPath,
    $shadowRecommendationMarkdownPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Expected shadow review artifact was not produced: $requiredPath"
    }
}

$shadowRecommendation = Read-JsonFile -Path $shadowRecommendationJsonPath

Write-Host "Shadow profile review:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Treatment lane root: $resolvedLaneRoot"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Profiles: $($resolvedProfiles -join ', ')"
Write-Host "  Shadow profiles JSON: $shadowProfilesJsonPath"
Write-Host "  Shadow profiles Markdown: $shadowProfilesMarkdownPath"
Write-Host "  Shadow recommendation JSON: $shadowRecommendationJsonPath"
Write-Host "  Shadow recommendation Markdown: $shadowRecommendationMarkdownPath"
if ($null -ne $shadowRecommendation) {
    Write-Host "  Decision: $([string]$shadowRecommendation.decision)"
    Write-Host "  Conservative should remain next live profile: $([bool]$shadowRecommendation.conservative_should_remain_next_live_profile)"
    Write-Host "  Responsive justified as next trial: $([bool]$shadowRecommendation.responsive_justified_as_next_trial)"
}

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    LaneRoot = $resolvedLaneRoot
    OutputRoot = $resolvedOutputRoot
    ShadowProfilesJsonPath = $shadowProfilesJsonPath
    ShadowProfilesMarkdownPath = $shadowProfilesMarkdownPath
    ShadowRecommendationJsonPath = $shadowRecommendationJsonPath
    ShadowRecommendationMarkdownPath = $shadowRecommendationMarkdownPath
    Recommendation = if ($null -ne $shadowRecommendation) { [string]$shadowRecommendation.decision } else { "" }
    ConservativeShouldRemainNextLiveProfile = if ($null -ne $shadowRecommendation) { [bool]$shadowRecommendation.conservative_should_remain_next_live_profile } else { $false }
    ResponsiveJustifiedAsNextTrial = if ($null -ne $shadowRecommendation) { [bool]$shadowRecommendation.responsive_justified_as_next_trial } else { $false }
}
