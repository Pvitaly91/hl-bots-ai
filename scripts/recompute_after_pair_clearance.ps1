[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$RegistryPath = "",
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

function Write-NdjsonFile {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = New-Object System.IO.StreamWriter($Path, $false, $encoding)
    try {
        foreach ($record in @($Records)) {
            $writer.WriteLine(($record | ConvertTo-Json -Depth 24 -Compress))
        }
    }
    finally {
        $writer.Dispose()
    }
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
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) {
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

function Get-SourceCommitSha {
    $repoRoot = Get-RepoRoot
    $sha = ""
    try {
        $sha = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    }
    catch {
        $sha = ""
    }

    return $sha
}

function Get-ResolvedLabRoot {
    param([string]$ExplicitLabRoot)

    if ([string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
        return Ensure-Directory -Path (Get-LabRootDefault)
    }

    return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitLabRoot)
}

function Get-ResolvedEvalRoot {
    param(
        [string]$ResolvedLabRoot,
        [string]$ExplicitEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitEvalRoot)
    }

    return Ensure-Directory -Path (Get-EvalRootDefault -LabRoot $ResolvedLabRoot)
}

function Get-ResolvedPairsRoot {
    param(
        [string]$ResolvedLabRoot,
        [string]$ExplicitPairsRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairsRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitPairsRoot)
    }

    return Ensure-Directory -Path (Get-PairsRootDefault -LabRoot $ResolvedLabRoot)
}

function Find-LatestClearedPairRoot {
    param([string]$ResolvedEvalRoot)

    if (-not (Test-Path -LiteralPath $ResolvedEvalRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $ResolvedEvalRoot -Filter "counted_pair_clearance.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        $payload = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $payload) {
            continue
        }

        $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $payload -Name "pair_root" -Default ""))
        $cleared = [bool](Get-ObjectPropertyValue -Object $payload -Name "manual_review_label_cleared" -Default $false)
        $counts = [bool](Get-ObjectPropertyValue -Object $payload -Name "final_promotion_counting_status" -Default $false)
        if ($pairRoot -and $cleared -and $counts) {
            return $pairRoot
        }
    }

    return ""
}

function Resolve-ClearedPairRoot {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ResolvedEvalRoot,
        [string]$ResolvedPairsRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        $resolved = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
        if (-not $resolved) {
            throw "Pair root was not found: $ExplicitPairRoot"
        }

        return $resolved
    }

    if ($ShouldUseLatest) {
        $latestPair = Get-ChildItem -LiteralPath $ResolvedPairsRoot -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $latestPair) {
            return $latestPair.DirectoryName
        }
    }

    $clearedPair = Find-LatestClearedPairRoot -ResolvedEvalRoot $ResolvedEvalRoot
    if ($clearedPair) {
        return $clearedPair
    }

    throw "Unable to locate a cleared counted-pair target. Provide -PairRoot or stage counted_pair_clearance.json under $ResolvedEvalRoot."
}

function Materialize-FreshRegistryEntry {
    param(
        [string]$ResolvedPairRoot,
        [string]$ScratchRoot
    )

    $registerScriptPath = Join-Path $PSScriptRoot "register_pair_session_result.ps1"
    $materializedRoot = Ensure-Directory -Path $ScratchRoot
    $scratchRegistryPath = Join-Path $materializedRoot "pair_sessions.ndjson"
    Write-NdjsonFile -Path $scratchRegistryPath -Records @()

    & $registerScriptPath -PairRoot $ResolvedPairRoot -RegistryPath $scratchRegistryPath | Out-Null

    $entries = @(Read-NdjsonFile -Path $scratchRegistryPath)
    if ($entries.Count -ne 1) {
        throw "Expected exactly one materialized registry entry for $ResolvedPairRoot, found $($entries.Count)."
    }

    return $entries[0]
}

function Get-BeforeAfterField {
    param(
        [string]$Name,
        [object]$Before,
        [object]$After
    )

    return [pscustomobject]@{
        field   = $Name
        before  = $Before
        after   = $After
        changed = ($Before -ne $After)
    }
}

function Get-ArtifactChangeRecord {
    param(
        [string]$ArtifactName,
        [string]$BeforePath,
        [string]$AfterPath,
        [object[]]$FieldDiffs
    )

    return [pscustomobject]@{
        artifact_name = $ArtifactName
        before_path   = $BeforePath
        after_path    = $AfterPath
        changed       = (@($FieldDiffs | Where-Object { $_.changed })).Count -gt 0
        key_fields    = @($FieldDiffs)
    }
}

function Get-RegistrySnapshot {
    param(
        [object]$Summary,
        [object]$Gate,
        [object]$Plan,
        [object]$Mission
    )

    return [pscustomobject]@{
        responsive_gate_verdict                 = [string](Get-ObjectPropertyValue -Object $Gate -Name "gate_verdict" -Default "")
        responsive_gate_next_live_action        = [string](Get-ObjectPropertyValue -Object $Gate -Name "next_live_action" -Default "")
        next_live_objective                     = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_session_objective" -Default "")
        next_live_profile                       = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_live_profile" -Default "")
        grounded_conservative_sessions          = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Plan -Name "current_certified_grounded_session_counts" -Default $null) -Name "conservative" -Default 0)
        grounded_conservative_too_quiet_sessions = [int](Get-ObjectPropertyValue -Object $Plan -Name "current_grounded_conservative_too_quiet_count" -Default 0)
        strong_signal_sessions                  = [int](Get-ObjectPropertyValue -Object $Plan -Name "current_grounded_strong_signal_count" -Default 0)
        total_certified_grounded_sessions       = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Plan -Name "current_certified_grounded_session_counts" -Default $null) -Name "total" -Default 0)
        grounded_tuning_usable_sessions         = [int](Get-ObjectPropertyValue -Object $Summary -Name "grounded_tuning_usable_count" -Default 0)
        responsive_overreaction_blockers        = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Plan -Name "evidence_gap" -Default $null) -Name "responsive_overreaction_blockers_current" -Default 0)
        latest_outcome_context_path             = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Mission -Name "latest_outcome_context" -Default $null) -Name "path" -Default "")
    }
}

function Get-RecomputeVerdict {
    param(
        [object]$BeforeSnapshot,
        [object]$AfterSnapshot,
        [bool]$OnlyDerivedOutputsChanged
    )

    if ($BeforeSnapshot.responsive_gate_verdict -eq $AfterSnapshot.responsive_gate_verdict -and
        $BeforeSnapshot.next_live_objective -eq $AfterSnapshot.next_live_objective -and
        $BeforeSnapshot.grounded_conservative_sessions -eq $AfterSnapshot.grounded_conservative_sessions -and
        $BeforeSnapshot.grounded_conservative_too_quiet_sessions -eq $AfterSnapshot.grounded_conservative_too_quiet_sessions -and
        $BeforeSnapshot.strong_signal_sessions -eq $AfterSnapshot.strong_signal_sessions) {
        return "no-downstream-state-change"
    }

    if ($AfterSnapshot.grounded_conservative_sessions -gt $BeforeSnapshot.grounded_conservative_sessions) {
        return "counted-grounded-sessions-now-recognized-as-$($AfterSnapshot.grounded_conservative_sessions)"
    }

    if ($AfterSnapshot.next_live_objective -eq "collect-grounded-conservative-too-quiet-evidence") {
        return "too-quiet-target-now-active"
    }

    if ($BeforeSnapshot.next_live_objective -ne $AfterSnapshot.next_live_objective) {
        return "next-objective-advanced-after-clearance"
    }

    if ($AfterSnapshot.responsive_gate_verdict -eq "closed") {
        return "manual-review-label-cleared-but-gate-still-closed"
    }

    if (-not $OnlyDerivedOutputsChanged -and $AfterSnapshot.responsive_gate_verdict -eq "manual-review-needed") {
        return "manual-review-state-persisted-because-clearance-was-insufficient"
    }

    return "no-downstream-state-change"
}

function Get-PostClearanceMarkdown {
    param([object]$Report)

    $artifacts = @($Report.recomputed_artifacts | ForEach-Object {
        "- $($_.artifact_name): changed=$($_.changed), before=$($_.before_path), after=$($_.after_path)"
    }) -join [Environment]::NewLine

    return @"
# Post-Clearance Recompute

- Prompt ID: $($Report.prompt_id)
- Pair root: $($Report.pair_root)
- Clearance verdict: $($Report.clearance_verdict)
- Recompute verdict: $($Report.recompute_verdict)
- Promotion state changed: $($Report.promotion_state_changed)
- Only labels or derived outputs changed: $($Report.only_labels_or_derived_outputs_changed)

## Before vs After

- Responsive gate before -> after: $($Report.before_state.responsive_gate_verdict) -> $($Report.after_state.responsive_gate_verdict)
- Next-live objective before -> after: $($Report.before_state.next_live_objective) -> $($Report.after_state.next_live_objective)
- Grounded conservative sessions before -> after: $($Report.before_state.grounded_conservative_sessions) -> $($Report.after_state.grounded_conservative_sessions)
- Grounded conservative too-quiet before -> after: $($Report.before_state.grounded_conservative_too_quiet_sessions) -> $($Report.after_state.grounded_conservative_too_quiet_sessions)
- Strong-signal before -> after: $($Report.before_state.strong_signal_sessions) -> $($Report.after_state.strong_signal_sessions)
- Responsive overreaction blockers before -> after: $($Report.before_state.responsive_overreaction_blockers) -> $($Report.after_state.responsive_overreaction_blockers)

## Recomputed Artifacts

$artifacts

## Explanation

$($Report.explanation)
"@
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = Get-ResolvedLabRoot -ExplicitLabRoot $LabRoot
$resolvedEvalRoot = Get-ResolvedEvalRoot -ResolvedLabRoot $resolvedLabRoot -ExplicitEvalRoot $EvalRoot
$resolvedPairsRoot = Get-ResolvedPairsRoot -ResolvedLabRoot $resolvedLabRoot -ExplicitPairsRoot $PairsRoot
$resolvedPairRoot = Resolve-ClearedPairRoot -ExplicitPairRoot $PairRoot -ShouldUseLatest:$UseLatest -ResolvedEvalRoot $resolvedEvalRoot -ResolvedPairsRoot $resolvedPairsRoot

$clearancePath = Join-Path $resolvedPairRoot "counted_pair_clearance.json"
$clearance = Read-JsonFile -Path $clearancePath
if ($null -eq $clearance) {
    throw "Counted-pair clearance output was not found: $clearancePath"
}

$manualReviewLabelCleared = [bool](Get-ObjectPropertyValue -Object $clearance -Name "manual_review_label_cleared" -Default $false)
$finalPromotionCountingStatus = [bool](Get-ObjectPropertyValue -Object $clearance -Name "final_promotion_counting_status" -Default $false)
if (-not $manualReviewLabelCleared -or -not $finalPromotionCountingStatus) {
    throw "The target pair is not cleared for downstream recomputation. Expected manual_review_label_cleared=true and final_promotion_counting_status=true."
}

$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}

if (-not (Test-Path -LiteralPath $resolvedRegistryPath)) {
    throw "Registry path was not found: $resolvedRegistryPath"
}

$registryRoot = Split-Path -Path $resolvedRegistryPath -Parent
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedPairRoot "post_clearance_recompute")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}

$resolvedGateConfigPath = if ([string]::IsNullOrWhiteSpace($GateConfigPath)) {
    Join-Path $repoRoot "ai_director\testdata\responsive_trial_gate.json"
}
else {
    Get-AbsolutePath -Path $GateConfigPath -BasePath $repoRoot
}

$currentRegistrySummaryPath = Join-Path $registryRoot "registry_summary.json"
$currentResponsiveGatePath = Join-Path $registryRoot "responsive_trial_gate.json"
$currentNextLivePlanPath = Join-Path $registryRoot "next_live_plan.json"
$currentMissionPath = Join-Path $registryRoot "next_live_session_mission.json"

$currentRegistrySummary = Read-JsonFile -Path $currentRegistrySummaryPath
$currentResponsiveGate = Read-JsonFile -Path $currentResponsiveGatePath
$currentNextLivePlan = Read-JsonFile -Path $currentNextLivePlanPath
$currentMission = Read-JsonFile -Path $currentMissionPath
$currentPairAnalysis = Read-JsonFile -Path (Join-Path $resolvedPairRoot "grounded_session_analysis.json")
$currentPromotionGapDelta = Read-JsonFile -Path (Join-Path $resolvedPairRoot "promotion_gap_delta.json")
$currentOutcomeDossier = Read-JsonFile -Path (Join-Path $resolvedPairRoot "session_outcome_dossier.json")

$baseRegistryEntries = @(Read-NdjsonFile -Path $resolvedRegistryPath)
$pairSummary = Read-JsonFile -Path (Join-Path $resolvedPairRoot "pair_summary.json")
$pairId = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default ([System.IO.Path]::GetFileName($resolvedPairRoot)))

$materializedEntryRoot = Join-Path $resolvedOutputRoot ("materialized_entry\" + ([guid]::NewGuid().ToString("N")))
$freshEntry = Materialize-FreshRegistryEntry -ResolvedPairRoot $resolvedPairRoot -ScratchRoot $materializedEntryRoot
$overlayEntry = $freshEntry | ConvertTo-Json -Depth 24 | ConvertFrom-Json
$overlayEntry | Add-Member -NotePropertyName "clearance_overlay_applied" -NotePropertyValue $true -Force
$overlayEntry | Add-Member -NotePropertyName "counted_pair_clearance_verdict" -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $clearance -Name "clearance_verdict" -Default "")) -Force
$overlayEntry | Add-Member -NotePropertyName "manual_review_label_cleared" -NotePropertyValue $true -Force
$overlayEntry | Add-Member -NotePropertyName "counted_pair_clearance_json" -NotePropertyValue $clearancePath -Force
$overlayEntry | Add-Member -NotePropertyName "registry_overlay_prompt_id" -NotePropertyValue (Get-RepoPromptId) -Force
$overlayEntry | Add-Member -NotePropertyName "overlay_explanation" -NotePropertyValue "This materialized registry entry was refreshed from the cleared pair artifacts for downstream recomputation only." -Force

$overlayEntries = New-Object System.Collections.Generic.List[object]
$matched = $false
foreach ($entry in $baseRegistryEntries) {
    $entryPairRoot = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_root" -Default "")
    $entryPairId = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default "")
    if ($entryPairRoot -eq $resolvedPairRoot -or ($pairId -and $entryPairId -eq $pairId)) {
        if (-not $matched) {
            $overlayEntries.Add($overlayEntry) | Out-Null
            $matched = $true
        }
        continue
    }

    $overlayEntries.Add($entry) | Out-Null
}

if (-not $matched) {
    $overlayEntries.Add($overlayEntry) | Out-Null
}

$overlayRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "overlay")
$overlayRegistryPath = Join-Path $overlayRoot "pair_sessions_clearance_overlay.ndjson"
Write-NdjsonFile -Path $overlayRegistryPath -Records @($overlayEntries.ToArray())

$scenarioRegistryRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "derived_state")
$scenarioPairRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "latest_grounded")

$summaryScriptPath = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"
$gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"
$planScriptPath = Join-Path $PSScriptRoot "plan_next_live_session.ps1"
$missionScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"
$analysisScriptPath = Join-Path $PSScriptRoot "analyze_latest_grounded_session.ps1"
$dossierScriptPath = Join-Path $PSScriptRoot "build_latest_session_outcome_dossier.ps1"

& $summaryScriptPath -RegistryPath $overlayRegistryPath -OutputRoot $scenarioRegistryRoot | Out-Null

$scenarioRegistrySummaryPath = Join-Path $scenarioRegistryRoot "registry_summary.json"
$scenarioProfileRecommendationPath = Join-Path $scenarioRegistryRoot "profile_recommendation.json"

& $gateScriptPath `
    -RegistryPath $overlayRegistryPath `
    -OutputRoot $scenarioRegistryRoot `
    -RegistrySummaryPath $scenarioRegistrySummaryPath `
    -ProfileRecommendationPath $scenarioProfileRecommendationPath `
    -GateConfigPath $resolvedGateConfigPath | Out-Null

$scenarioResponsiveGatePath = Join-Path $scenarioRegistryRoot "responsive_trial_gate.json"

& $planScriptPath `
    -RegistryPath $overlayRegistryPath `
    -OutputRoot $scenarioRegistryRoot `
    -RegistrySummaryPath $scenarioRegistrySummaryPath `
    -ProfileRecommendationPath $scenarioProfileRecommendationPath `
    -ResponsiveTrialGatePath $scenarioResponsiveGatePath `
    -GateConfigPath $resolvedGateConfigPath | Out-Null

$scenarioNextLivePlanPath = Join-Path $scenarioRegistryRoot "next_live_plan.json"

& $analysisScriptPath `
    -PairRoot $resolvedPairRoot `
    -PairsRoot $resolvedPairsRoot `
    -LabRoot $resolvedLabRoot `
    -RegistryPath $overlayRegistryPath `
    -OutputRoot $scenarioPairRoot `
    -GateConfigPath $resolvedGateConfigPath | Out-Null

$scenarioGroundedAnalysisPath = Join-Path $scenarioPairRoot "grounded_session_analysis.json"
$scenarioPromotionGapDeltaPath = Join-Path $scenarioPairRoot "promotion_gap_delta.json"

$scenarioOutcomeJsonPath = Join-Path $scenarioPairRoot "session_outcome_dossier.json"
$scenarioOutcomeMarkdownPath = Join-Path $scenarioPairRoot "session_outcome_dossier.md"
& $dossierScriptPath `
    -PairRoot $resolvedPairRoot `
    -PairsRoot $resolvedPairsRoot `
    -LabRoot $resolvedLabRoot `
    -RegistryPath $overlayRegistryPath `
    -OutputJson $scenarioOutcomeJsonPath `
    -OutputMarkdown $scenarioOutcomeMarkdownPath | Out-Null

& $missionScriptPath `
    -RegistryPath $overlayRegistryPath `
    -LabRoot $resolvedLabRoot `
    -OutputRoot $scenarioRegistryRoot `
    -RegistrySummaryPath $scenarioRegistrySummaryPath `
    -ProfileRecommendationPath $scenarioProfileRecommendationPath `
    -ResponsiveTrialGatePath $scenarioResponsiveGatePath `
    -NextLivePlanPath $scenarioNextLivePlanPath `
    -LatestOutcomeDossierPath $scenarioOutcomeJsonPath `
    -PairsRoot $resolvedPairsRoot | Out-Null

$scenarioMissionPath = Join-Path $scenarioRegistryRoot "next_live_session_mission.json"

$scenarioRegistrySummary = Read-JsonFile -Path $scenarioRegistrySummaryPath
$scenarioResponsiveGate = Read-JsonFile -Path $scenarioResponsiveGatePath
$scenarioNextLivePlan = Read-JsonFile -Path $scenarioNextLivePlanPath
$scenarioMission = Read-JsonFile -Path $scenarioMissionPath
$scenarioGroundedAnalysis = Read-JsonFile -Path $scenarioGroundedAnalysisPath
$scenarioPromotionGapDelta = Read-JsonFile -Path $scenarioPromotionGapDeltaPath
$scenarioOutcomeDossier = Read-JsonFile -Path $scenarioOutcomeJsonPath

$beforeState = Get-RegistrySnapshot -Summary $currentRegistrySummary -Gate $currentResponsiveGate -Plan $currentNextLivePlan -Mission $currentMission
$afterState = Get-RegistrySnapshot -Summary $scenarioRegistrySummary -Gate $scenarioResponsiveGate -Plan $scenarioNextLivePlan -Mission $scenarioMission

$registrySummaryDiffs = @(
    (Get-BeforeAfterField -Name "responsive_trial_gate_verdict" -Before ([string](Get-ObjectPropertyValue -Object $currentRegistrySummary -Name "responsive_trial_gate_verdict" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioRegistrySummary -Name "responsive_trial_gate_verdict" -Default ""))),
    (Get-BeforeAfterField -Name "next_live_session_objective" -Before ([string](Get-ObjectPropertyValue -Object $currentRegistrySummary -Name "next_live_session_objective" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioRegistrySummary -Name "next_live_session_objective" -Default ""))),
    (Get-BeforeAfterField -Name "total_certified_grounded_sessions" -Before ([int](Get-ObjectPropertyValue -Object $currentRegistrySummary -Name "total_certified_grounded_sessions" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object $scenarioRegistrySummary -Name "total_certified_grounded_sessions" -Default 0))),
    (Get-BeforeAfterField -Name "grounded_conservative_too_quiet_count" -Before ([int](Get-ObjectPropertyValue -Object $currentRegistrySummary -Name "grounded_conservative_too_quiet_count" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object $scenarioRegistrySummary -Name "grounded_conservative_too_quiet_count" -Default 0))),
    (Get-BeforeAfterField -Name "grounded_strong_signal_count" -Before ([int](Get-ObjectPropertyValue -Object $currentRegistrySummary -Name "grounded_strong_signal_count" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object $scenarioRegistrySummary -Name "grounded_strong_signal_count" -Default 0)))
)

$gateDiffs = @(
    (Get-BeforeAfterField -Name "gate_verdict" -Before ([string](Get-ObjectPropertyValue -Object $currentResponsiveGate -Name "gate_verdict" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioResponsiveGate -Name "gate_verdict" -Default ""))),
    (Get-BeforeAfterField -Name "next_live_action" -Before ([string](Get-ObjectPropertyValue -Object $currentResponsiveGate -Name "next_live_action" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioResponsiveGate -Name "next_live_action" -Default ""))),
    (Get-BeforeAfterField -Name "real_grounded_count" -Before ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentResponsiveGate -Name "conservative_evidence_counts" -Default $null) -Name "real_grounded_count" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioResponsiveGate -Name "conservative_evidence_counts" -Default $null) -Name "real_grounded_count" -Default 0))),
    (Get-BeforeAfterField -Name "real_grounded_too_quiet_count" -Before ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentResponsiveGate -Name "conservative_evidence_counts" -Default $null) -Name "real_grounded_too_quiet_count" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioResponsiveGate -Name "conservative_evidence_counts" -Default $null) -Name "real_grounded_too_quiet_count" -Default 0)))
)

$planDiffs = @(
    (Get-BeforeAfterField -Name "recommended_next_session_objective" -Before ([string](Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "recommended_next_session_objective" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioNextLivePlan -Name "recommended_next_session_objective" -Default ""))),
    (Get-BeforeAfterField -Name "recommended_next_live_profile" -Before ([string](Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "recommended_next_live_profile" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioNextLivePlan -Name "recommended_next_live_profile" -Default ""))),
    (Get-BeforeAfterField -Name "grounded_sessions_current" -Before ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "evidence_gap" -Default $null) -Name "grounded_sessions_current" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioNextLivePlan -Name "evidence_gap" -Default $null) -Name "grounded_sessions_current" -Default 0))),
    (Get-BeforeAfterField -Name "grounded_too_quiet_current" -Before ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "evidence_gap" -Default $null) -Name "grounded_too_quiet_current" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioNextLivePlan -Name "evidence_gap" -Default $null) -Name "grounded_too_quiet_current" -Default 0))),
    (Get-BeforeAfterField -Name "strong_signal_current" -Before ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentNextLivePlan -Name "evidence_gap" -Default $null) -Name "strong_signal_current" -Default 0)) -After ([int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioNextLivePlan -Name "evidence_gap" -Default $null) -Name "strong_signal_current" -Default 0)))
)

$missionDiffs = @(
    (Get-BeforeAfterField -Name "current_responsive_gate_verdict" -Before ([string](Get-ObjectPropertyValue -Object $currentMission -Name "current_responsive_gate_verdict" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioMission -Name "current_responsive_gate_verdict" -Default ""))),
    (Get-BeforeAfterField -Name "current_next_live_objective" -Before ([string](Get-ObjectPropertyValue -Object $currentMission -Name "current_next_live_objective" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioMission -Name "current_next_live_objective" -Default ""))),
    (Get-BeforeAfterField -Name "latest_outcome_context_path" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentMission -Name "latest_outcome_context" -Default $null) -Name "path" -Default "")) -After ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioMission -Name "latest_outcome_context" -Default $null) -Name "path" -Default "")))
)

$analysisDiffs = @(
    (Get-BeforeAfterField -Name "impact_classification" -Before ([string](Get-ObjectPropertyValue -Object $currentPromotionGapDelta -Name "impact_classification" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioPromotionGapDelta -Name "impact_classification" -Default ""))),
    (Get-BeforeAfterField -Name "responsive_gate_after.gate_verdict" -Before ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $currentPromotionGapDelta -Name "responsive_gate_after" -Default $null) -Name "gate_verdict" -Default "")) -After ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $scenarioPromotionGapDelta -Name "responsive_gate_after" -Default $null) -Name "gate_verdict" -Default ""))),
    (Get-BeforeAfterField -Name "next_objective_after" -Before ([string](Get-ObjectPropertyValue -Object $currentPromotionGapDelta -Name "next_objective_after" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioPromotionGapDelta -Name "next_objective_after" -Default "")))
)

$dossierDiffs = @(
    (Get-BeforeAfterField -Name "latest_session_impact_classification" -Before ([string](Get-ObjectPropertyValue -Object $currentOutcomeDossier -Name "latest_session_impact_classification" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioOutcomeDossier -Name "latest_session_impact_classification" -Default ""))),
    (Get-BeforeAfterField -Name "current_responsive_gate_verdict" -Before ([string](Get-ObjectPropertyValue -Object $currentOutcomeDossier -Name "current_responsive_gate_verdict" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioOutcomeDossier -Name "current_responsive_gate_verdict" -Default ""))),
    (Get-BeforeAfterField -Name "current_next_live_objective" -Before ([string](Get-ObjectPropertyValue -Object $currentOutcomeDossier -Name "current_next_live_objective" -Default "")) -After ([string](Get-ObjectPropertyValue -Object $scenarioOutcomeDossier -Name "current_next_live_objective" -Default "")))
)

$artifactChanges = @(
    (Get-ArtifactChangeRecord -ArtifactName "registry_summary" -BeforePath $currentRegistrySummaryPath -AfterPath $scenarioRegistrySummaryPath -FieldDiffs $registrySummaryDiffs),
    (Get-ArtifactChangeRecord -ArtifactName "responsive_trial_gate" -BeforePath $currentResponsiveGatePath -AfterPath $scenarioResponsiveGatePath -FieldDiffs $gateDiffs),
    (Get-ArtifactChangeRecord -ArtifactName "next_live_plan" -BeforePath $currentNextLivePlanPath -AfterPath $scenarioNextLivePlanPath -FieldDiffs $planDiffs),
    (Get-ArtifactChangeRecord -ArtifactName "next_live_session_mission" -BeforePath $currentMissionPath -AfterPath $scenarioMissionPath -FieldDiffs $missionDiffs),
    (Get-ArtifactChangeRecord -ArtifactName "grounded_session_analysis_and_delta" -BeforePath (Join-Path $resolvedPairRoot "promotion_gap_delta.json") -AfterPath $scenarioPromotionGapDeltaPath -FieldDiffs $analysisDiffs),
    (Get-ArtifactChangeRecord -ArtifactName "session_outcome_dossier" -BeforePath (Join-Path $resolvedPairRoot "session_outcome_dossier.json") -AfterPath $scenarioOutcomeJsonPath -FieldDiffs $dossierDiffs)
)

$promotionStateChanged =
    $false

$onlyDerivedOutputsChanged =
    ($beforeState.responsive_gate_verdict -eq $afterState.responsive_gate_verdict) -and
    ($beforeState.next_live_objective -eq $afterState.next_live_objective) -and
    ($beforeState.grounded_conservative_sessions -eq $afterState.grounded_conservative_sessions) -and
    ($beforeState.grounded_conservative_too_quiet_sessions -eq $afterState.grounded_conservative_too_quiet_sessions) -and
    ($beforeState.strong_signal_sessions -eq $afterState.strong_signal_sessions) -and
    (@($artifactChanges | Where-Object { $_.changed }).Count -gt 0)

$recomputeVerdict = Get-RecomputeVerdict -BeforeSnapshot $beforeState -AfterSnapshot $afterState -OnlyDerivedOutputsChanged $onlyDerivedOutputsChanged

$explanationParts = @()
if ($beforeState.responsive_gate_verdict -eq $afterState.responsive_gate_verdict -and $beforeState.next_live_objective -eq $afterState.next_live_objective) {
    $explanationParts += "The clearance-aware overlay did not change the responsive gate verdict or the next-live objective."
}
else {
    $explanationParts += "The clearance-aware overlay changed the downstream decision state."
}

if ($beforeState.grounded_conservative_sessions -eq $afterState.grounded_conservative_sessions -and
    $beforeState.grounded_conservative_too_quiet_sessions -eq $afterState.grounded_conservative_too_quiet_sessions -and
    $beforeState.strong_signal_sessions -eq $afterState.strong_signal_sessions) {
    $explanationParts += "Promotion-counting totals stayed unchanged."
}
else {
    $explanationParts += "Promotion-counting totals changed under the overlay."
}

if ($onlyDerivedOutputsChanged) {
    $explanationParts += "Only labels or secondary derived outputs changed. The pair still counts, but the stale-looking downstream state was materially the same after recomputation."
}

if ($afterState.responsive_gate_verdict -eq "manual-review-needed") {
    $explanationParts += "The manual-review-oriented gate persists because the grounded conservative evidence is still mixed between too-quiet and appropriately-conservative outcomes, not because the cleared pair still carries a manual-review label."
}

$report = [pscustomobject]@{
    schema_version                       = 1
    prompt_id                            = Get-RepoPromptId
    generated_at_utc                     = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha                    = Get-SourceCommitSha
    pair_root                            = $resolvedPairRoot
    pair_id                              = $pairId
    clearance_json_path                  = $clearancePath
    clearance_verdict                    = [string](Get-ObjectPropertyValue -Object $clearance -Name "clearance_verdict" -Default "")
    overlay_registry_path                = $overlayRegistryPath
    post_clearance_output_root           = $resolvedOutputRoot
    recompute_verdict                    = $recomputeVerdict
    before_state                         = $beforeState
    after_state                          = $afterState
    promotion_state_changed              = $promotionStateChanged
    only_labels_or_derived_outputs_changed = $onlyDerivedOutputsChanged
    recomputed_artifacts                 = $artifactChanges
    explanation                          = ($explanationParts -join " ")
    artifacts                            = [pscustomobject]@{
        post_clearance_recompute_json = Join-Path $resolvedPairRoot "post_clearance_recompute.json"
        post_clearance_recompute_markdown = Join-Path $resolvedPairRoot "post_clearance_recompute.md"
        overlay_registry_path         = $overlayRegistryPath
        registry_summary_json         = $scenarioRegistrySummaryPath
        responsive_trial_gate_json    = $scenarioResponsiveGatePath
        next_live_plan_json           = $scenarioNextLivePlanPath
        next_live_session_mission_json = $scenarioMissionPath
        grounded_session_analysis_json = $scenarioGroundedAnalysisPath
        promotion_gap_delta_json      = $scenarioPromotionGapDeltaPath
        session_outcome_dossier_json  = $scenarioOutcomeJsonPath
    }
}

$reportJsonPath = Join-Path $resolvedPairRoot "post_clearance_recompute.json"
$reportMarkdownPath = Join-Path $resolvedPairRoot "post_clearance_recompute.md"
Write-JsonFile -Path $reportJsonPath -Value $report
Write-TextFile -Path $reportMarkdownPath -Value (Get-PostClearanceMarkdown -Report $report)

[pscustomobject]@{
    PairRoot                    = $resolvedPairRoot
    OverlayRegistryPath         = $overlayRegistryPath
    PostClearanceRecomputeJsonPath = $reportJsonPath
    PostClearanceRecomputeMarkdownPath = $reportMarkdownPath
    RecomputeVerdict            = $recomputeVerdict
    PromotionStateChanged       = $promotionStateChanged
}
