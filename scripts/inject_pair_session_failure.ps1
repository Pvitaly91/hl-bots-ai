[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "already-complete",
        "before-sufficiency",
        "after-sufficiency-before-closeout",
        "during-post-pipeline",
        "missing-mission-snapshot",
        "partial-artifacts-recoverable"
    )]
    [string]$FailureMode,
    [string]$SourcePairRoot = "",
    [switch]$UseLatest,
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$InjectedPairRoot = "",
    [string]$OutputRoot = "",
    [switch]$AllowInPlace,
    [switch]$AllowUnsafeNonRehearsalMutation
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

    $json = $Value | ConvertTo-Json -Depth 30
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

function Set-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Object) {
        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $existing = $Object.PSObject.Properties[$Name]
    if ($null -ne $existing) {
        $existing.Value = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
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

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    try {
        $normalizedPath = [System.IO.Path]::GetFullPath($Path)
        $normalizedRoot = [System.IO.Path]::GetFullPath($Root)
    }
    catch {
        return $false
    }

    if (-not $normalizedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $normalizedRoot += [System.IO.Path]::DirectorySeparatorChar
    }

    return $normalizedPath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-PathSafely {
    param(
        [string]$TargetPath,
        [string]$AllowedRoot
    )

    $resolvedTargetPath = Get-AbsolutePath -Path $TargetPath
    if (-not (Test-Path -LiteralPath $resolvedTargetPath)) {
        return $false
    }

    if (-not (Test-PathWithinRoot -Path $resolvedTargetPath -Root $AllowedRoot)) {
        throw "Refusing to remove '$resolvedTargetPath' because it is outside '$AllowedRoot'."
    }

    Remove-Item -LiteralPath $resolvedTargetPath -Recurse -Force
    return $true
}

function Replace-RootValue {
    param(
        [object]$Value,
        [string]$OldRoot,
        [string]$NewRoot
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        if ($Value.Contains($OldRoot)) {
            return $Value.Replace($OldRoot, $NewRoot)
        }

        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $Value[$key] = Replace-RootValue -Value $Value[$key] -OldRoot $OldRoot -NewRoot $NewRoot
        }

        return $Value
    }

    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $Value[$index] = Replace-RootValue -Value $Value[$index] -OldRoot $OldRoot -NewRoot $NewRoot
        }

        return $Value
    }

    foreach ($property in @($Value.PSObject.Properties)) {
        $property.Value = Replace-RootValue -Value $property.Value -OldRoot $OldRoot -NewRoot $NewRoot
    }

    return $Value
}

function Rewrite-JsonAbsolutePaths {
    param(
        [string]$PairRoot,
        [string]$SourcePairRoot
    )

    $rewrittenFiles = @()
    foreach ($jsonFile in Get-ChildItem -LiteralPath $PairRoot -Filter "*.json" -Recurse -File -ErrorAction Stop) {
        try {
            $jsonObject = Read-JsonFile -Path $jsonFile.FullName
            if ($null -eq $jsonObject) {
                continue
            }

            $updatedObject = Replace-RootValue -Value $jsonObject -OldRoot $SourcePairRoot -NewRoot $PairRoot
            Write-JsonFile -Path $jsonFile.FullName -Value $updatedObject
            $rewrittenFiles += $jsonFile.FullName
        }
        catch {
        }
    }

    return @($rewrittenFiles)
}

function Remove-RelativeArtifacts {
    param(
        [string]$PairRoot,
        [string[]]$RelativePaths
    )

    $removedPaths = @()
    foreach ($relativePath in @($RelativePaths)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $absolutePath = Join-Path $PairRoot $relativePath
        if (Remove-PathSafely -TargetPath $absolutePath -AllowedRoot $PairRoot) {
            $removedPaths += $absolutePath
        }
    }

    return @($removedPaths)
}

function Update-SessionState {
    param(
        [string]$PairRoot,
        [string]$Stage,
        [string]$Status,
        [string]$Explanation,
        [hashtable]$PostPipelineFlags = @{},
        [hashtable]$MonitorState = @{}
    )

    $sessionStatePath = Join-Path $PairRoot "guided_session\session_state.json"
    $sessionState = Read-JsonFile -Path $sessionStatePath
    if ($null -eq $sessionState) {
        return $false
    }

    Set-ObjectPropertyValue -Object $sessionState -Name "prompt_id" -Value (Get-RepoPromptId)
    Set-ObjectPropertyValue -Object $sessionState -Name "generated_at_utc" -Value ((Get-Date).ToUniversalTime().ToString("o"))
    Set-ObjectPropertyValue -Object $sessionState -Name "pair_root" -Value $PairRoot
    Set-ObjectPropertyValue -Object $sessionState -Name "guided_session_root" -Value (Join-Path $PairRoot "guided_session")
    Set-ObjectPropertyValue -Object $sessionState -Name "stage" -Value $Stage
    Set-ObjectPropertyValue -Object $sessionState -Name "status" -Value $Status
    Set-ObjectPropertyValue -Object $sessionState -Name "explanation" -Value $Explanation
    Set-ObjectPropertyValue -Object $sessionState -Name "pair_run_completed" -Value $true
    Set-ObjectPropertyValue -Object $sessionState -Name "full_closeout_completed" -Value ($Status -eq "complete")

    $postPipeline = Get-ObjectPropertyValue -Object $sessionState -Name "post_pipeline" -Default $null
    if ($null -eq $postPipeline) {
        $postPipeline = [ordered]@{}
        Set-ObjectPropertyValue -Object $sessionState -Name "post_pipeline" -Value $postPipeline
    }

    foreach ($flagName in $PostPipelineFlags.Keys) {
        Set-ObjectPropertyValue -Object $postPipeline -Name $flagName -Value ([bool]$PostPipelineFlags[$flagName])
    }

    if ($MonitorState.Count -gt 0) {
        $monitor = Get-ObjectPropertyValue -Object $sessionState -Name "monitor" -Default $null
        if ($null -eq $monitor) {
            $monitor = [ordered]@{}
            Set-ObjectPropertyValue -Object $sessionState -Name "monitor" -Value $monitor
        }

        foreach ($monitorName in $MonitorState.Keys) {
            Set-ObjectPropertyValue -Object $monitor -Name $monitorName -Value $MonitorState[$monitorName]
        }
    }

    Write-JsonFile -Path $sessionStatePath -Value $sessionState
    return $true
}

function Update-RehearsalMetadata {
    param(
        [string]$PairRoot,
        [string]$FailureMode,
        [string]$SourcePairRoot,
        [string]$Explanation
    )

    $metadataPath = Join-Path $PairRoot "rehearsal_metadata.json"
    $metadata = Read-JsonFile -Path $metadataPath
    if ($null -eq $metadata) {
        $metadata = [ordered]@{}
    }

    Set-ObjectPropertyValue -Object $metadata -Name "prompt_id" -Value (Get-RepoPromptId)
    Set-ObjectPropertyValue -Object $metadata -Name "generated_at_utc" -Value ((Get-Date).ToUniversalTime().ToString("o"))
    Set-ObjectPropertyValue -Object $metadata -Name "pair_root" -Value $PairRoot
    Set-ObjectPropertyValue -Object $metadata -Name "rehearsal_mode" -Value $true
    Set-ObjectPropertyValue -Object $metadata -Name "validation_only" -Value $true
    Set-ObjectPropertyValue -Object $metadata -Name "evidence_origin" -Value "rehearsal"
    Set-ObjectPropertyValue -Object $metadata -Name "failure_injection_mode" -Value $FailureMode
    Set-ObjectPropertyValue -Object $metadata -Name "failure_injection_source_pair_root" -Value $SourcePairRoot
    Set-ObjectPropertyValue -Object $metadata -Name "failure_injection_note" -Value $Explanation

    Write-JsonFile -Path $metadataPath -Value $metadata
}

function Update-PairSummaryForInjectedBranch {
    param(
        [string]$PairRoot,
        [string]$FailureMode,
        [string]$Classification,
        [string]$Explanation,
        [int]$HumanSnapshots,
        [double]$HumanPresenceSeconds,
        [bool]$ComparisonUsable,
        [string]$ComparisonVerdict
    )

    $pairSummaryPath = Join-Path $PairRoot "pair_summary.json"
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    if ($null -eq $pairSummary) {
        return $false
    }

    Set-ObjectPropertyValue -Object $pairSummary -Name "prompt_id" -Value (Get-RepoPromptId)
    Set-ObjectPropertyValue -Object $pairSummary -Name "pair_root" -Value "."
    Set-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Value $true
    Set-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Value $true
    Set-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Value $true
    Set-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Value "rehearsal"
    Set-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Value $Classification
    Set-ObjectPropertyValue -Object $pairSummary -Name "operator_note" -Value $Explanation
    Set-ObjectPropertyValue -Object $pairSummary -Name "fixture_note" -Value "Failure-injection rehearsal branch derived from a completed rehearsal run. This remains workflow-validation-only and does not count as grounded live evidence."
    Set-ObjectPropertyValue -Object $pairSummary -Name "failure_injection_mode" -Value $FailureMode

    foreach ($laneName in @("control_lane", "treatment_lane")) {
        $lane = Get-ObjectPropertyValue -Object $pairSummary -Name $laneName -Default $null
        if ($null -eq $lane) {
            continue
        }

        Set-ObjectPropertyValue -Object $lane -Name "human_snapshots_count" -Value $HumanSnapshots
        Set-ObjectPropertyValue -Object $lane -Name "seconds_with_human_presence" -Value $HumanPresenceSeconds
        Set-ObjectPropertyValue -Object $lane -Name "evidence_quality" -Value $(if ($ComparisonUsable) { "strong-signal" } else { "insufficient-data" })
        Set-ObjectPropertyValue -Object $lane -Name "behavior_verdict" -Value $(if ($ComparisonUsable) { "stable" } else { "insufficient-data" })
        Set-ObjectPropertyValue -Object $lane -Name "lane_verdict" -Value $(if ($ComparisonUsable) {
                if ($laneName -eq "control_lane") { "control-baseline-human-rich" } else { "ai-healthy-human-rich" }
            }
            else {
                if ($laneName -eq "control_lane") { "control-baseline-insufficient-human-signal" } else { "ai-healthy-insufficient-human-signal" }
            })
    }

    $nestedComparison = Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
    if ($nestedComparison) {
        Set-ObjectPropertyValue -Object $nestedComparison -Name "comparison_is_tuning_usable" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $nestedComparison -Name "comparison_verdict" -Value $ComparisonVerdict
        Set-ObjectPropertyValue -Object $nestedComparison -Name "comparison_reason" -Value $Explanation
        Set-ObjectPropertyValue -Object $nestedComparison -Name "comparison_explanation" -Value $Explanation
        Set-ObjectPropertyValue -Object $nestedComparison -Name "control_human_snapshots_count" -Value $HumanSnapshots
        Set-ObjectPropertyValue -Object $nestedComparison -Name "treatment_human_snapshots_count" -Value $HumanSnapshots
        Set-ObjectPropertyValue -Object $nestedComparison -Name "control_seconds_with_human_presence" -Value $HumanPresenceSeconds
        Set-ObjectPropertyValue -Object $nestedComparison -Name "treatment_seconds_with_human_presence" -Value $HumanPresenceSeconds
        Set-ObjectPropertyValue -Object $nestedComparison -Name "control_evidence_quality" -Value $(if ($ComparisonUsable) { "strong-signal" } else { "insufficient-data" })
        Set-ObjectPropertyValue -Object $nestedComparison -Name "treatment_evidence_quality" -Value $(if ($ComparisonUsable) { "strong-signal" } else { "insufficient-data" })
        Set-ObjectPropertyValue -Object $nestedComparison -Name "control_tuning_signal_usable" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $nestedComparison -Name "treatment_tuning_signal_usable" -Value $ComparisonUsable
    }

    Write-JsonFile -Path $pairSummaryPath -Value $pairSummary
    return $true
}

function Update-ComparisonForInjectedBranch {
    param(
        [string]$PairRoot,
        [string]$Explanation,
        [int]$HumanSnapshots,
        [double]$HumanPresenceSeconds,
        [bool]$ComparisonUsable,
        [string]$ComparisonVerdict
    )

    $comparisonPath = Join-Path $PairRoot "comparison.json"
    $comparison = Read-JsonFile -Path $comparisonPath
    if ($null -eq $comparison) {
        return $false
    }

    $comparisonTargets = @($comparison)
    $nestedComparison = Get-ObjectPropertyValue -Object $comparison -Name "comparison" -Default $null
    if ($null -ne $nestedComparison) {
        $comparisonTargets += $nestedComparison
    }

    $evidenceQuality = if ($ComparisonUsable) { "strong-signal" } else { "insufficient-data" }
    $humanSignalVerdict = if ($ComparisonUsable) { "human-rich" } else { "insufficient-data" }
    $laneVerdictControl = if ($ComparisonUsable) { "control-baseline-human-rich" } else { "control-baseline-insufficient-human-signal" }
    $laneVerdictTreatment = if ($ComparisonUsable) { "ai-healthy-human-rich" } else { "ai-healthy-insufficient-human-signal" }

    foreach ($comparisonTarget in $comparisonTargets) {
        foreach ($propertyName in @(
                "control_human_snapshots_count",
                "treatment_human_snapshots_count",
                "control_telemetry_snapshots_count",
                "treatment_telemetry_snapshots_count"
            )) {
            Set-ObjectPropertyValue -Object $comparisonTarget -Name $propertyName -Value $HumanSnapshots
        }

        foreach ($propertyName in @(
                "control_seconds_with_human_presence",
                "treatment_seconds_with_human_presence"
            )) {
            Set-ObjectPropertyValue -Object $comparisonTarget -Name $propertyName -Value $HumanPresenceSeconds
        }

        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_lane_quality_verdict" -Value $laneVerdictControl
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_lane_quality_verdict" -Value $laneVerdictTreatment
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_evidence_quality" -Value $evidenceQuality
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_evidence_quality" -Value $evidenceQuality
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_behavior_verdict" -Value $(if ($ComparisonUsable) { "stable" } else { "insufficient-data" })
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_behavior_verdict" -Value $(if ($ComparisonUsable) { "stable" } else { "insufficient-data" })
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_human_signal_verdict" -Value $humanSignalVerdict
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_human_signal_verdict" -Value $humanSignalVerdict
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_tuning_signal_usable" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_tuning_signal_usable" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_patch_apply_count" -Value 0
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_patch_apply_count" -Value $(if ($ComparisonUsable) { 2 } else { 1 })
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_frag_gap_samples_while_humans_present" -Value @()
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_frag_gap_samples_while_humans_present" -Value @()
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "control_mean_abs_frag_gap_while_humans_present" -Value $null
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_mean_abs_frag_gap_while_humans_present" -Value $null
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_patched_while_humans_present" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "meaningful_post_patch_observation_window_exists" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_pre_post_trend_classification" -Value $(if ($ComparisonUsable) { "pre-post-improved" } else { "no-usable-human-signal" })
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_relative_to_control" -Value $(if ($ComparisonUsable) { "similar" } else { "quieter" })
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "relative_behavior_discussion_ready" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "apparent_benefit_too_weak_to_trust" -Value $false
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "treatment_patch_response_to_human_imbalance_observed" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "comparison_is_tuning_usable" -Value $ComparisonUsable
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "comparison_verdict" -Value $ComparisonVerdict
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "comparison_reason" -Value $Explanation
        Set-ObjectPropertyValue -Object $comparisonTarget -Name "comparison_explanation" -Value $Explanation
    }

    Write-JsonFile -Path $comparisonPath -Value $comparison
    return $true
}

function Update-MonitorForInjectedBranch {
    param(
        [string]$PairRoot,
        [string]$Verdict,
        [string]$Explanation,
        [int]$HumanSnapshots,
        [double]$HumanPresenceSeconds,
        [int]$PatchEventsWhileHumansPresent,
        [double]$PostPatchObservationSeconds,
        [int]$PostPatchWindowCount
    )

    $monitorPath = Join-Path $PairRoot "live_monitor_status.json"
    $monitor = Read-JsonFile -Path $monitorPath
    if ($null -eq $monitor) {
        return $false
    }

    Set-ObjectPropertyValue -Object $monitor -Name "prompt_id" -Value (Get-RepoPromptId)
    Set-ObjectPropertyValue -Object $monitor -Name "generated_at_utc" -Value ((Get-Date).ToUniversalTime().ToString("o"))
    Set-ObjectPropertyValue -Object $monitor -Name "pair_root" -Value $PairRoot
    Set-ObjectPropertyValue -Object $monitor -Name "phase" -Value "completed"
    Set-ObjectPropertyValue -Object $monitor -Name "pair_complete" -Value $true
    Set-ObjectPropertyValue -Object $monitor -Name "comparison_available" -Value $true
    Set-ObjectPropertyValue -Object $monitor -Name "current_verdict" -Value $Verdict
    Set-ObjectPropertyValue -Object $monitor -Name "explanation" -Value $Explanation
    Set-ObjectPropertyValue -Object $monitor -Name "control_human_snapshots_count" -Value $HumanSnapshots
    Set-ObjectPropertyValue -Object $monitor -Name "control_human_presence_seconds" -Value $HumanPresenceSeconds
    Set-ObjectPropertyValue -Object $monitor -Name "treatment_human_snapshots_count" -Value $HumanSnapshots
    Set-ObjectPropertyValue -Object $monitor -Name "treatment_human_presence_seconds" -Value $HumanPresenceSeconds
    Set-ObjectPropertyValue -Object $monitor -Name "treatment_patch_events_while_humans_present" -Value $PatchEventsWhileHumansPresent
    Set-ObjectPropertyValue -Object $monitor -Name "meaningful_post_patch_observation_seconds" -Value $PostPatchObservationSeconds
    Set-ObjectPropertyValue -Object $monitor -Name "treatment_response_after_patch_window_count" -Value $PostPatchWindowCount
    Set-ObjectPropertyValue -Object $monitor -Name "operator_can_stop_now" -Value $true
    Set-ObjectPropertyValue -Object $monitor -Name "likely_remains_insufficient_if_stopped_immediately" -Value ($Verdict -notin @("sufficient-for-tuning-usable-review", "sufficient-for-scorecard"))
    Set-ObjectPropertyValue -Object $monitor -Name "control_lane_quality_verdict" -Value $(if ($Verdict -in @("sufficient-for-tuning-usable-review", "sufficient-for-scorecard")) { "control-baseline-human-rich" } else { "control-baseline-insufficient-human-signal" })
    Set-ObjectPropertyValue -Object $monitor -Name "treatment_lane_quality_verdict" -Value $(if ($Verdict -in @("sufficient-for-tuning-usable-review", "sufficient-for-scorecard")) { "ai-healthy-human-rich" } else { "ai-healthy-insufficient-human-signal" })
    Set-ObjectPropertyValue -Object $monitor -Name "comparison_verdict" -Value $(if ($Verdict -in @("sufficient-for-tuning-usable-review", "sufficient-for-scorecard")) { "comparison-strong-signal" } else { "comparison-insufficient-data" })
    Set-ObjectPropertyValue -Object $monitor -Name "comparison_explanation" -Value $Explanation

    Write-JsonFile -Path $monitorPath -Value $monitor
    return $true
}

function Get-FailureInjectionMarkdown {
    param([object]$Report)

    $lines = @(
        "# Pair Session Failure Injection",
        "",
        "- Prompt ID: $($Report.prompt_id)",
        "- Failure mode: $($Report.failure_mode)",
        "- Source pair root: $($Report.source_pair_root)",
        "- Injected pair root: $($Report.pair_root)",
        "- Mutation mode: $($Report.mutation_mode)",
        "- Source rehearsal-safe: $($Report.source_rehearsal_safe)",
        "- Explanation: $($Report.explanation)",
        "",
        "## Removed Artifacts",
        ""
    )

    if (@($Report.removed_artifacts).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($path in @($Report.removed_artifacts)) {
            $lines += "- $path"
        }
    }

    $lines += ""
    $lines += "## Rewritten JSON Files"
    $lines += ""

    if (@($Report.rewritten_json_files).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($path in @($Report.rewritten_json_files)) {
            $lines += "- $path"
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ($LabRoot) { Get-AbsolutePath -Path $LabRoot } else { Get-LabRootDefault }
$resolvedPairsRoot = if ($PairsRoot) { Get-AbsolutePath -Path $PairsRoot } else { Get-PairsRootDefault -LabRoot $resolvedLabRoot }

if (-not $SourcePairRoot) {
    if (-not $UseLatest) {
        $UseLatest = $true
    }
}

$resolvedSourcePairRoot = if ($UseLatest) {
    Find-LatestPairRoot -Root $resolvedPairsRoot
}
else {
    Get-AbsolutePath -Path $SourcePairRoot
}

$resolvedSourcePairRoot = Resolve-ExistingPath -Path $resolvedSourcePairRoot
if (-not $resolvedSourcePairRoot) {
    throw "Source pair root was not found."
}

$sourcePairSummary = Read-JsonFile -Path (Join-Path $resolvedSourcePairRoot "pair_summary.json")
if ($null -eq $sourcePairSummary) {
    throw "Source pair root does not contain pair_summary.json: $resolvedSourcePairRoot"
}

$sourceRehearsalSafe = (
    [bool](Get-ObjectPropertyValue -Object $sourcePairSummary -Name "rehearsal_mode" -Default $false) -or
    [bool](Get-ObjectPropertyValue -Object $sourcePairSummary -Name "validation_only" -Default $false) -or
    [string](Get-ObjectPropertyValue -Object $sourcePairSummary -Name "evidence_origin" -Default "") -eq "rehearsal"
)

if (-not $sourceRehearsalSafe -and -not $AllowUnsafeNonRehearsalMutation) {
    throw "Refusing to inject failure into a non-rehearsal pair root. Use rehearsal-backed or validation-only evidence only."
}

$resolvedTargetPairRoot = ""
$mutationMode = if ($AllowInPlace) { "in-place" } else { "copy" }
if ($AllowInPlace) {
    $resolvedTargetPairRoot = $resolvedSourcePairRoot
}
else {
    $resolvedOutputRoot = if ($OutputRoot) {
        Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
    }
    elseif ($InjectedPairRoot) {
        Ensure-Directory -Path (Split-Path -Path (Get-AbsolutePath -Path $InjectedPairRoot) -Parent)
    }
    else {
        Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "continuation_rehearsal\injected_pairs")
    }

    $resolvedTargetPairRoot = if ($InjectedPairRoot) {
        Get-AbsolutePath -Path $InjectedPairRoot
    }
    else {
        Join-Path $resolvedOutputRoot ("{0}-{1}" -f $FailureMode, (Split-Path -Path $resolvedSourcePairRoot -Leaf))
    }

    if (Test-Path -LiteralPath $resolvedTargetPairRoot) {
        Remove-PathSafely -TargetPath $resolvedTargetPairRoot -AllowedRoot $repoRoot | Out-Null
    }

    Copy-Item -LiteralPath $resolvedSourcePairRoot -Destination $resolvedTargetPairRoot -Recurse -Force
}

$resolvedTargetPairRoot = Resolve-ExistingPath -Path $resolvedTargetPairRoot
if (-not $resolvedTargetPairRoot) {
    throw "Injected pair root could not be created."
}

$rewrittenJsonFiles = @()
if (-not $AllowInPlace) {
    $rewrittenJsonFiles = Rewrite-JsonAbsolutePaths -PairRoot $resolvedTargetPairRoot -SourcePairRoot $resolvedSourcePairRoot
}

$removedArtifacts = @()
$removedArtifacts += Remove-RelativeArtifacts -PairRoot $resolvedTargetPairRoot -RelativePaths @(
    "session_recovery_report.json",
    "session_recovery_report.md",
    "session_salvage_report.json",
    "session_salvage_report.md",
    "mission_continuation_decision.json",
    "mission_continuation_decision.md",
    "continuation_rehearsal_report.json",
    "continuation_rehearsal_report.md",
    "failure_injection_report.json",
    "failure_injection_report.md"
)

$explanation = ""
switch ($FailureMode) {
    "already-complete" {
        $explanation = "The copied rehearsal pair stays structurally complete so the continuation controller should choose no action."
    }
    "after-sufficiency-before-closeout" {
        $removedArtifacts += Remove-RelativeArtifacts -PairRoot $resolvedTargetPairRoot -RelativePaths @(
            "scorecard.json",
            "scorecard.md",
            "shadow_review",
            "grounded_evidence_certificate.json",
            "grounded_evidence_certificate.md",
            "grounded_session_analysis.json",
            "grounded_session_analysis.md",
            "promotion_gap_delta.json",
            "promotion_gap_delta.md",
            "session_outcome_dossier.json",
            "session_outcome_dossier.md",
            "mission_attainment.json",
            "mission_attainment.md",
            "guided_session\final_session_docket.json",
            "guided_session\final_session_docket.md",
            "guided_session\registry",
            "analysis_scenarios"
        )
        Update-SessionState -PairRoot $resolvedTargetPairRoot -Stage "pair-run-complete" -Status "partial" -Explanation "Injected rehearsal failure branch: evidence is sufficient, but the post-pipeline closeout never started." -PostPipelineFlags @{
            enabled = $true
            review_completed = $false
            shadow_review_completed = $false
            scorecard_completed = $false
            register_completed = $false
            registry_summary_completed = $false
            responsive_gate_completed = $false
            outcome_dossier_completed = $false
            mission_attainment_completed = $false
        } | Out-Null
        $explanation = "The injected pair keeps sufficient raw evidence but removes every post-pipeline artifact so recovery should classify it as interrupted after sufficiency and before closeout."
    }
    "during-post-pipeline" {
        $removedArtifacts += Remove-RelativeArtifacts -PairRoot $resolvedTargetPairRoot -RelativePaths @(
            "grounded_evidence_certificate.json",
            "grounded_evidence_certificate.md",
            "grounded_session_analysis.json",
            "grounded_session_analysis.md",
            "promotion_gap_delta.json",
            "promotion_gap_delta.md",
            "session_outcome_dossier.json",
            "session_outcome_dossier.md",
            "mission_attainment.json",
            "mission_attainment.md",
            "guided_session\final_session_docket.json",
            "guided_session\final_session_docket.md",
            "guided_session\registry",
            "analysis_scenarios"
        )
        Update-SessionState -PairRoot $resolvedTargetPairRoot -Stage "post-pipeline-interrupted" -Status "partial" -Explanation "Injected rehearsal failure branch: post-pipeline started, but the closeout stack stopped before certification, dossier, and mission closeout finished." -PostPipelineFlags @{
            enabled = $true
            review_completed = $true
            shadow_review_completed = $true
            scorecard_completed = $true
            register_completed = $false
            registry_summary_completed = $false
            responsive_gate_completed = $false
            outcome_dossier_completed = $false
            mission_attainment_completed = $false
        } | Out-Null
        $explanation = "The injected pair keeps sufficient evidence plus early closeout artifacts, but removes the later dossier and mission-closeout layer so recovery should classify it as interrupted during post-pipeline."
    }
    "partial-artifacts-recoverable" {
        $removedArtifacts += Remove-RelativeArtifacts -PairRoot $resolvedTargetPairRoot -RelativePaths @(
            "comparison.json",
            "comparison.md",
            "grounded_evidence_certificate.json",
            "grounded_evidence_certificate.md",
            "grounded_session_analysis.json",
            "grounded_session_analysis.md",
            "promotion_gap_delta.json",
            "promotion_gap_delta.md",
            "session_outcome_dossier.json",
            "session_outcome_dossier.md",
            "mission_attainment.json",
            "mission_attainment.md",
            "guided_session\final_session_docket.json",
            "guided_session\final_session_docket.md",
            "guided_session\registry",
            "analysis_scenarios"
        )
        Update-SessionState -PairRoot $resolvedTargetPairRoot -Stage "post-pipeline-partial" -Status "partial" -Explanation "Injected rehearsal failure branch: the pair looked sufficient, but the artifact set is incomplete enough that closeout must be rebuilt conservatively." -PostPipelineFlags @{
            enabled = $true
            review_completed = $true
            shadow_review_completed = $true
            scorecard_completed = $true
            register_completed = $false
            registry_summary_completed = $false
            responsive_gate_completed = $false
            outcome_dossier_completed = $false
            mission_attainment_completed = $false
        } | Out-Null
        $explanation = "The injected pair removes comparison plus the later closeout layer while leaving strong-signal summary markers, so recovery should land on partial-artifacts-recoverable instead of pretending the session is complete."
    }
    "before-sufficiency" {
        $removedArtifacts += Remove-RelativeArtifacts -PairRoot $resolvedTargetPairRoot -RelativePaths @(
            "scorecard.json",
            "scorecard.md",
            "shadow_review",
            "grounded_evidence_certificate.json",
            "grounded_evidence_certificate.md",
            "grounded_session_analysis.json",
            "grounded_session_analysis.md",
            "promotion_gap_delta.json",
            "promotion_gap_delta.md",
            "session_outcome_dossier.json",
            "session_outcome_dossier.md",
            "mission_attainment.json",
            "mission_attainment.md",
            "guided_session\final_session_docket.json",
            "guided_session\final_session_docket.md",
            "guided_session\registry",
            "analysis_scenarios"
        )
        $branchExplanation = "Injected rehearsal failure branch: the saved pair was stopped before the sufficiency gate cleared, so it should be rerun instead of salvaged."
        Update-PairSummaryForInjectedBranch -PairRoot $resolvedTargetPairRoot -FailureMode $FailureMode -Classification "insufficient-data" -Explanation $branchExplanation -HumanSnapshots 1 -HumanPresenceSeconds 15.0 -ComparisonUsable:$false -ComparisonVerdict "comparison-insufficient-data" | Out-Null
        Update-ComparisonForInjectedBranch -PairRoot $resolvedTargetPairRoot -Explanation $branchExplanation -HumanSnapshots 1 -HumanPresenceSeconds 15.0 -ComparisonUsable:$false -ComparisonVerdict "comparison-insufficient-data" | Out-Null
        Update-MonitorForInjectedBranch -PairRoot $resolvedTargetPairRoot -Verdict "insufficient-data-timeout" -Explanation $branchExplanation -HumanSnapshots 1 -HumanPresenceSeconds 15.0 -PatchEventsWhileHumansPresent 1 -PostPatchObservationSeconds 0.0 -PostPatchWindowCount 0 | Out-Null
        Update-SessionState -PairRoot $resolvedTargetPairRoot -Stage "pair-run-complete" -Status "partial" -Explanation $branchExplanation -PostPipelineFlags @{
            enabled = $true
            review_completed = $false
            shadow_review_completed = $false
            scorecard_completed = $false
            register_completed = $false
            registry_summary_completed = $false
            responsive_gate_completed = $false
            outcome_dossier_completed = $false
            mission_attainment_completed = $false
        } -MonitorState @{
            current_verdict = "insufficient-data-timeout"
            explanation = $branchExplanation
            operator_can_stop_now = $true
            likely_remains_insufficient_if_stopped_immediately = $true
        } | Out-Null
        $explanation = $branchExplanation
    }
    "missing-mission-snapshot" {
        $removedArtifacts += Remove-RelativeArtifacts -PairRoot $resolvedTargetPairRoot -RelativePaths @(
            "guided_session\mission\next_live_session_mission.json",
            "guided_session\mission\next_live_session_mission.md"
        )
        $explanation = "The injected pair leaves the closeout stack in place but removes the mission snapshot so recovery should stop for manual review instead of over-claiming mission cleanliness."
    }
}

Update-RehearsalMetadata -PairRoot $resolvedTargetPairRoot -FailureMode $FailureMode -SourcePairRoot $resolvedSourcePairRoot -Explanation $explanation

$reportJsonPath = Join-Path $resolvedTargetPairRoot "failure_injection_report.json"
$reportMarkdownPath = Join-Path $resolvedTargetPairRoot "failure_injection_report.md"
$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    failure_mode = $FailureMode
    mutation_mode = $mutationMode
    source_pair_root = $resolvedSourcePairRoot
    pair_root = $resolvedTargetPairRoot
    source_rehearsal_safe = $sourceRehearsalSafe
    removed_artifacts = @($removedArtifacts | Sort-Object -Unique)
    rewritten_json_files = @($rewrittenJsonFiles | Sort-Object -Unique)
    explanation = $explanation
}

Write-JsonFile -Path $reportJsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $reportJsonPath
Write-TextFile -Path $reportMarkdownPath -Value (Get-FailureInjectionMarkdown -Report $reportForMarkdown)

Write-Host "Pair session failure injection:"
Write-Host "  Failure mode: $FailureMode"
Write-Host "  Source pair root: $resolvedSourcePairRoot"
Write-Host "  Injected pair root: $resolvedTargetPairRoot"
Write-Host "  Mutation mode: $mutationMode"
Write-Host "  Failure injection report JSON: $reportJsonPath"
Write-Host "  Failure injection report Markdown: $reportMarkdownPath"

[pscustomobject]@{
    FailureMode = $FailureMode
    SourcePairRoot = $resolvedSourcePairRoot
    PairRoot = $resolvedTargetPairRoot
    MutationMode = $mutationMode
    FailureInjectionReportJsonPath = $reportJsonPath
    FailureInjectionReportMarkdownPath = $reportMarkdownPath
}
