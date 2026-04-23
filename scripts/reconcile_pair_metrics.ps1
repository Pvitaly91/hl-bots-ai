[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = "",
    [switch]$DryRun,
    [switch]$ExecuteRefresh
)

. (Join-Path $PSScriptRoot "common.ps1")

if ($DryRun -and $ExecuteRefresh) {
    throw "Use either -DryRun or -ExecuteRefresh, not both."
}

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

function Read-LaneSummaryFile {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if ($null -eq $payload) {
        return $null
    }

    $primaryLane = Get-ObjectPropertyValue -Object $payload -Name "primary_lane" -Default $null
    if ($null -ne $primaryLane) {
        return $primaryLane
    }

    return $payload
}

function Get-ResolvedEvalRoot {
    param(
        [string]$ExplicitLabRoot,
        [string]$ExplicitEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitEvalRoot)
    }

    $resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
        Ensure-Directory -Path (Get-LabRootDefault)
    }
    else {
        Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitLabRoot)
    }

    return Ensure-Directory -Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot)
}

function Get-ResolvedPairsRoot {
    param(
        [string]$ExplicitPairsRoot,
        [string]$ResolvedLabRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairsRoot)) {
        return Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitPairsRoot)
    }

    return Ensure-Directory -Path (Get-PairsRootDefault -LabRoot $ResolvedLabRoot)
}

function Find-LatestPairRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
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

function Find-LatestManualReviewPairRoot {
    param([string]$ResolvedEvalRoot)

    if (-not (Test-Path -LiteralPath $ResolvedEvalRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $ResolvedEvalRoot -Filter "promotion_gap_delta.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $candidates) {
        $payload = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $payload) {
            continue
        }

        $impact = [string](Get-ObjectPropertyValue -Object $payload -Name "impact_classification" -Default "")
        $counts = [bool](Get-ObjectPropertyValue -Object $payload -Name "counts_toward_promotion" -Default $false)
        $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $payload -Name "pair_root" -Default ""))
        if ($impact -eq "manual-review-needed" -and $counts -and $pairRoot) {
            return $pairRoot
        }
    }

    return ""
}

function Resolve-ReconciliationPairRoot {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ResolvedEvalRoot,
        [string]$ResolvedPairsRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        return Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
    }

    $manualReviewTarget = Find-LatestManualReviewPairRoot -ResolvedEvalRoot $ResolvedEvalRoot
    if ($manualReviewTarget) {
        return $manualReviewTarget
    }

    if ($ShouldUseLatest) {
        $latestEvalPair = Find-LatestPairRoot -Root $ResolvedEvalRoot
        if ($latestEvalPair) {
            return Resolve-ExistingPath -Path $latestEvalPair
        }
    }

    return Resolve-ExistingPath -Path (Find-LatestPairRoot -Root $ResolvedPairsRoot)
}

function Get-OutputPaths {
    param(
        [string]$ResolvedPairRoot,
        [string]$ExplicitOutputRoot,
        [string]$ResolvedEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitOutputRoot)) {
        $root = Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitOutputRoot)
        return [ordered]@{
            JsonPath = Join-Path $root "pair_metric_reconciliation.json"
            MarkdownPath = Join-Path $root "pair_metric_reconciliation.md"
        }
    }

    if ($ResolvedPairRoot) {
        return [ordered]@{
            JsonPath = Join-Path $ResolvedPairRoot "pair_metric_reconciliation.json"
            MarkdownPath = Join-Path $ResolvedPairRoot "pair_metric_reconciliation.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedEvalRoot "registry\pair_metric_reconciliation")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot "pair_metric_reconciliation.json"
        MarkdownPath = Join-Path $fallbackRoot "pair_metric_reconciliation.md"
    }
}

function Resolve-MissionPathForRefresh {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedEvalRoot
    )

    foreach ($candidate in @(
        (Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.json"),
        (Join-Path $ResolvedEvalRoot "registry\next_live_session_mission.json")
    )) {
        $resolved = Resolve-ExistingPath -Path $candidate
        if ($resolved) {
            return $resolved
        }
    }

    return ""
}

function Get-ArtifactRecord {
    param(
        [string]$Kind,
        [string]$Path,
        [bool]$Canonical,
        [string]$Summary
    )

    return [ordered]@{
        kind = $Kind
        path = $Path
        found = -not [string]::IsNullOrWhiteSpace($Path)
        canonical = $Canonical
        summary = $Summary
    }
}

function Resolve-RegistryEntry {
    param(
        [object[]]$RegistryEntries,
        [string]$PairId,
        [string]$ResolvedPairRoot
    )

    foreach ($entry in @($RegistryEntries)) {
        $entryPairId = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default "")
        $entryPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $entry -Name "pair_root" -Default ""))
        if (($PairId -and $entryPairId -eq $PairId) -or ($entryPairRoot -and $entryPairRoot -eq $ResolvedPairRoot)) {
            return $entry
        }
    }

    return $null
}

function Get-TreatmentLaneArtifacts {
    param(
        [string]$ResolvedPairRoot,
        [object]$PairSummary
    )

    $treatmentLane = Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null
    $controlLane = Get-ObjectPropertyValue -Object $PairSummary -Name "control_lane" -Default $null

    $treatmentLaneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_root" -Default ""))
    $controlLaneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_root" -Default ""))

    $treatmentSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "summary_json" -Default ""))
    if (-not $treatmentSummaryPath -and $treatmentLaneRoot) {
        $treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json")
    }

    $controlSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlLane -Name "summary_json" -Default ""))
    if (-not $controlSummaryPath -and $controlLaneRoot) {
        $controlSummaryPath = Resolve-ExistingPath -Path (Join-Path $controlLaneRoot "summary.json")
    }

    return [pscustomobject]@{
        TreatmentLaneRoot = $treatmentLaneRoot
        ControlLaneRoot = $controlLaneRoot
        TreatmentSummaryPath = $treatmentSummaryPath
        ControlSummaryPath = $controlSummaryPath
        TreatmentPatchHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_history.ndjson") } else { "" }
        TreatmentPatchApplyHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_apply_history.ndjson") } else { "" }
        TreatmentTelemetryHistoryPath = if ($treatmentLaneRoot) { Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "telemetry_history.ndjson") } else { "" }
    }
}

function Get-RecordSpanSeconds {
    param(
        [object[]]$TelemetryRecords,
        [int]$Index
    )

    $record = $TelemetryRecords[$Index]
    $intervalSeconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $record -Name "active_balance" -Default $null) -Name "interval_seconds" -Default 20.0)
    if ($intervalSeconds -lt 1.0) {
        $intervalSeconds = 1.0
    }

    $currentTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default 0.0)
    if (($Index + 1) -ge $TelemetryRecords.Count) {
        return $intervalSeconds
    }

    $nextTime = [double](Get-ObjectPropertyValue -Object $TelemetryRecords[$Index + 1] -Name "server_time_seconds" -Default ($currentTime + $intervalSeconds))
    $delta = $nextTime - $currentTime
    if ($delta -le 0.0) {
        return $intervalSeconds
    }

    return [Math]::Min($intervalSeconds, $delta)
}

function Get-LatestTelemetryAtOrBefore {
    param(
        [object[]]$TelemetryRecords,
        [double]$ServerTime
    )

    $latestRecord = $null
    foreach ($record in @($TelemetryRecords)) {
        $recordTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default 0.0)
        if ($recordTime -le ($ServerTime + 0.0001)) {
            $latestRecord = $record
            continue
        }

        break
    }

    return $latestRecord
}

function Test-HumanPresentRecord {
    param([object]$Record)

    return [int](Get-ObjectPropertyValue -Object $Record -Name "human_player_count" -Default 0) -gt 0 -and
        [int](Get-ObjectPropertyValue -Object $Record -Name "bot_count" -Default 0) -gt 0
}

function Get-FirstPatchApplyDuringHumanWindow {
    param(
        [object]$TreatmentSummary,
        [object[]]$PatchApplyHistory
    )

    $firstHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "first_human_seen_server_time_seconds" -Default -1.0)
    $lastHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)

    foreach ($record in @($PatchApplyHistory)) {
        $serverTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default -1.0)
        if (
            $serverTime -ge 0.0 -and
            $firstHumanSeen -ge 0.0 -and
            $lastHumanSeen -ge $firstHumanSeen -and
            $serverTime -ge $firstHumanSeen -and
            $serverTime -le $lastHumanSeen
        ) {
            return $record
        }
    }

    return $null
}

function Count-PatchAppliesDuringHumanWindow {
    param(
        [object]$TreatmentSummary,
        [object[]]$PatchApplyHistory
    )

    $summaryValue = [int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "patch_apply_count_while_humans_present" -Default -1)
    if ($summaryValue -ge 0) {
        return $summaryValue
    }

    $count = 0
    $firstHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "first_human_seen_server_time_seconds" -Default -1.0)
    $lastHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)

    foreach ($record in @($PatchApplyHistory)) {
        $serverTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default -1.0)
        if (
            $serverTime -ge 0.0 -and
            $firstHumanSeen -ge 0.0 -and
            $lastHumanSeen -ge $firstHumanSeen -and
            $serverTime -ge $firstHumanSeen -and
            $serverTime -le $lastHumanSeen
        ) {
            $count++
        }
    }

    return $count
}

function Count-EmittedHumanPresentPatchEvents {
    param([object[]]$PatchHistory)

    $count = 0
    foreach ($record in @($PatchHistory)) {
        if (
            [bool](Get-ObjectPropertyValue -Object $record -Name "emitted" -Default $false) -and
            [int](Get-ObjectPropertyValue -Object $record -Name "current_human_player_count" -Default 0) -gt 0
        ) {
            $count++
        }
    }

    return $count
}

function Get-FirstEmittedHumanPresentPatchEvent {
    param([object[]]$PatchHistory)

    foreach ($record in @($PatchHistory)) {
        if (
            [bool](Get-ObjectPropertyValue -Object $record -Name "emitted" -Default $false) -and
            [int](Get-ObjectPropertyValue -Object $record -Name "current_human_player_count" -Default 0) -gt 0
        ) {
            return $record
        }
    }

    return $null
}

function Get-MeaningfulPostPatchObservationSeconds {
    param(
        [object]$TreatmentSummary,
        [object[]]$TelemetryHistory,
        [object[]]$PatchApplyHistory,
        [double]$FallbackTargetSeconds
    )

    if ($TelemetryHistory.Count -eq 0 -or $PatchApplyHistory.Count -eq 0) {
        if ([bool](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "meaningful_post_patch_observation_window_exists" -Default $false)) {
            return [Math]::Round($FallbackTargetSeconds, 2)
        }

        return 0.0
    }

    $firstApply = Get-FirstPatchApplyDuringHumanWindow -TreatmentSummary $TreatmentSummary -PatchApplyHistory $PatchApplyHistory
    if ($null -eq $firstApply) {
        if ([bool](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "meaningful_post_patch_observation_window_exists" -Default $false)) {
            return [Math]::Round($FallbackTargetSeconds, 2)
        }

        return 0.0
    }

    $firstApplyServerTime = [double](Get-ObjectPropertyValue -Object $firstApply -Name "server_time_seconds" -Default -1.0)
    if ($firstApplyServerTime -lt 0.0) {
        return 0.0
    }

    $totalSeconds = 0.0
    for ($index = 0; $index -lt $TelemetryHistory.Count; $index++) {
        $record = $TelemetryHistory[$index]
        $recordTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default 0.0)
        if ($recordTime -le ($firstApplyServerTime + 0.0001)) {
            continue
        }

        if (-not (Test-HumanPresentRecord -Record $record)) {
            continue
        }

        $totalSeconds += Get-RecordSpanSeconds -TelemetryRecords $TelemetryHistory -Index $index
    }

    if ($totalSeconds -le 0.0 -and [bool](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "meaningful_post_patch_observation_window_exists" -Default $false)) {
        return [Math]::Round($FallbackTargetSeconds, 2)
    }

    return [Math]::Round($totalSeconds, 2)
}

function Get-CanonicalMetrics {
    param(
        [object]$PairSummary,
        [object]$ControlSummary,
        [object]$TreatmentSummary,
        [object]$Comparison,
        [object]$Certificate,
        [object]$Mission,
        [object[]]$TreatmentPatchHistory,
        [object[]]$TreatmentPatchApplyHistory,
        [object[]]$TreatmentTelemetryHistory
    )

    $controlSnapshotsTarget = [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_snapshots" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_snapshots" -Default 3))
    $controlSecondsTarget = [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_presence_seconds" -Default 60.0))
    $treatmentSnapshotsTarget = [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_snapshots" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_snapshots" -Default 3))
    $treatmentSecondsTarget = [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_presence_seconds" -Default 60.0))
    $patchEventsTarget = [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "min_patch_events_for_usable_lane" -Default 2))
    $postPatchTarget = [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_post_patch_observation_window_seconds" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "min_post_patch_observation_seconds" -Default 20.0))

    $controlSnapshotsActual = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PairSummary -Name "control_lane" -Default $null) -Name "human_snapshots_count" -Default (Get-ObjectPropertyValue -Object $ControlSummary -Name "human_snapshots_count" -Default 0))
    $controlSecondsActual = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PairSummary -Name "control_lane" -Default $null) -Name "seconds_with_human_presence" -Default (Get-ObjectPropertyValue -Object $ControlSummary -Name "seconds_with_human_presence" -Default 0.0))
    $treatmentSnapshotsActual = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null) -Name "human_snapshots_count" -Default (Get-ObjectPropertyValue -Object $TreatmentSummary -Name "human_snapshots_count" -Default 0))
    $treatmentSecondsActual = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null) -Name "seconds_with_human_presence" -Default (Get-ObjectPropertyValue -Object $TreatmentSummary -Name "seconds_with_human_presence" -Default 0.0))

    $patchApplyCountWhileHumansPresent = Count-PatchAppliesDuringHumanWindow -TreatmentSummary $TreatmentSummary -PatchApplyHistory $TreatmentPatchApplyHistory
    $patchEventCountWhileHumansPresent = Count-EmittedHumanPresentPatchEvents -PatchHistory $TreatmentPatchHistory
    $firstPatchApplyDuringHumanWindow = Get-FirstPatchApplyDuringHumanWindow -TreatmentSummary $TreatmentSummary -PatchApplyHistory $TreatmentPatchApplyHistory
    $firstEmittedHumanPresentPatch = Get-FirstEmittedHumanPresentPatchEvent -PatchHistory $TreatmentPatchHistory
    $canonicalPatchUsesApply = $patchApplyCountWhileHumansPresent -gt $patchEventCountWhileHumansPresent
    $firstHumanPresentPatchRecord = if ($canonicalPatchUsesApply -and $null -ne $firstPatchApplyDuringHumanWindow) {
        $firstPatchApplyDuringHumanWindow
    }
    elseif ($null -ne $firstEmittedHumanPresentPatch) {
        $firstEmittedHumanPresentPatch
    }
    else {
        $firstPatchApplyDuringHumanWindow
    }
    $meaningfulPostPatchObservationSeconds = Get-MeaningfulPostPatchObservationSeconds `
        -TreatmentSummary $TreatmentSummary `
        -TelemetryHistory $TreatmentTelemetryHistory `
        -PatchApplyHistory $TreatmentPatchApplyHistory `
        -FallbackTargetSeconds $postPatchTarget

    $controlHumanSignalMet = $controlSnapshotsActual -ge $controlSnapshotsTarget -and $controlSecondsActual -ge $controlSecondsTarget
    $treatmentHumanSignalMet = $treatmentSnapshotsActual -ge $treatmentSnapshotsTarget -and $treatmentSecondsActual -ge $treatmentSecondsTarget
    $treatmentGroundedReady = $treatmentHumanSignalMet -and $patchApplyCountWhileHumansPresent -ge $patchEventsTarget -and $meaningfulPostPatchObservationSeconds -ge $postPatchTarget

    $evidenceOrigin = [string](Get-ObjectPropertyValue -Object $Certificate -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "evidence_origin" -Default ""))
    $validationOnly = [bool](Get-ObjectPropertyValue -Object $Certificate -Name "counts_only_as_workflow_validation" -Default (Get-ObjectPropertyValue -Object $PairSummary -Name "validation_only" -Default $false))
    $rehearsalMode = [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "rehearsal_mode" -Default $false)
    $syntheticFixture = [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "synthetic_fixture" -Default $false)
    $pairClassification = [string](Get-ObjectPropertyValue -Object $PairSummary -Name "operator_note_classification" -Default "")
    $comparisonVerdict = [string](Get-ObjectPropertyValue -Object $Comparison -Name "comparison_verdict" -Default "")
    $pairStrongEnough = $pairClassification -in @("tuning-usable", "strong-signal") -and $comparisonVerdict -in @("comparison-usable", "comparison-strong-signal")
    $meaningfulPostPatchWindowExists = [bool](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "meaningful_post_patch_observation_window_exists" -Default ([bool](Get-ObjectPropertyValue -Object $Comparison -Name "meaningful_post_patch_observation_window_exists" -Default $false)))
    $pairGroundedCounting = (
        $evidenceOrigin -eq "live" -and
        -not $validationOnly -and
        -not $rehearsalMode -and
        -not $syntheticFixture -and
        $controlHumanSignalMet -and
        $treatmentHumanSignalMet -and
        $patchApplyCountWhileHumansPresent -ge $patchEventsTarget -and
        $meaningfulPostPatchWindowExists -and
        $pairStrongEnough
    )

    return [ordered]@{
        control_human_snapshots_target = $controlSnapshotsTarget
        control_human_snapshots_actual = $controlSnapshotsActual
        control_human_presence_seconds_target = [Math]::Round($controlSecondsTarget, 2)
        control_human_presence_seconds_actual = [Math]::Round($controlSecondsActual, 2)
        treatment_human_snapshots_target = $treatmentSnapshotsTarget
        treatment_human_snapshots_actual = $treatmentSnapshotsActual
        treatment_human_presence_seconds_target = [Math]::Round($treatmentSecondsTarget, 2)
        treatment_human_presence_seconds_actual = [Math]::Round($treatmentSecondsActual, 2)
        counted_human_present_patch_events_target = $patchEventsTarget
        counted_human_present_patch_events_canonical = $patchApplyCountWhileHumansPresent
        emitted_human_present_patch_events_secondary = $patchEventCountWhileHumansPresent
        first_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $firstHumanPresentPatchRecord -Name "timestamp_utc" -Default "")
        first_human_present_patch_offset_seconds = [double](Get-ObjectPropertyValue -Object $firstHumanPresentPatchRecord -Name "server_time_seconds" -Default 0.0)
        first_human_present_patch_source = if ($canonicalPatchUsesApply -and $null -ne $firstPatchApplyDuringHumanWindow) { "patch-apply-during-human-window" } elseif ($null -ne $firstEmittedHumanPresentPatch) { "counted-patch-event" } elseif ($null -ne $firstPatchApplyDuringHumanWindow) { "patch-apply-during-human-window" } else { "none" }
        meaningful_post_patch_observation_seconds_target = [Math]::Round($postPatchTarget, 2)
        meaningful_post_patch_observation_seconds_canonical = $meaningfulPostPatchObservationSeconds
        treatment_grounded_ready_canonical = $treatmentGroundedReady
        pair_grounded_counting_canonical = $pairGroundedCounting
        comparison_verdict = $comparisonVerdict
        pair_classification = $pairClassification
        meaningful_post_patch_window_exists = $meaningfulPostPatchWindowExists
    }
}

function New-DerivedValueRecord {
    param(
        [string]$ArtifactName,
        [string]$Path,
        [object]$Value,
        [string]$Summary
    )

    return [ordered]@{
        artifact_name = $ArtifactName
        path = $Path
        value = $Value
        summary = $Summary
    }
}

function Test-MetricValueMatch {
    param(
        [object]$CanonicalValue,
        [object]$DerivedValue
    )

    if ($null -eq $DerivedValue) {
        return $true
    }

    if ($CanonicalValue -is [bool] -or $DerivedValue -is [bool]) {
        return [bool]$CanonicalValue -eq [bool]$DerivedValue
    }

    if (($CanonicalValue -is [double] -or $CanonicalValue -is [single] -or $CanonicalValue -is [decimal]) -or ($DerivedValue -is [double] -or $DerivedValue -is [single] -or $DerivedValue -is [decimal])) {
        return [Math]::Abs([double]$CanonicalValue - [double]$DerivedValue) -lt 0.05
    }

    if (($CanonicalValue -is [int] -or $CanonicalValue -is [long]) -or ($DerivedValue -is [int] -or $DerivedValue -is [long])) {
        return [int]$CanonicalValue -eq [int]$DerivedValue
    }

    return [string]$CanonicalValue -eq [string]$DerivedValue
}

function New-MetricComparison {
    param(
        [string]$MetricName,
        [string]$Label,
        [object]$CanonicalValue,
        [string]$CanonicalSource,
        [object[]]$DerivedValues,
        [string]$MismatchExplanation
    )

    $annotated = New-Object System.Collections.Generic.List[object]
    $allMatched = $true

    foreach ($entry in @($DerivedValues)) {
        $matches = Test-MetricValueMatch -CanonicalValue $CanonicalValue -DerivedValue (Get-ObjectPropertyValue -Object $entry -Name "value" -Default $null)
        if (-not $matches) {
            $allMatched = $false
        }

        $annotated.Add([ordered]@{
                artifact_name = [string](Get-ObjectPropertyValue -Object $entry -Name "artifact_name" -Default "")
                path = [string](Get-ObjectPropertyValue -Object $entry -Name "path" -Default "")
                value = Get-ObjectPropertyValue -Object $entry -Name "value" -Default $null
                summary = [string](Get-ObjectPropertyValue -Object $entry -Name "summary" -Default "")
                match = $matches
            }) | Out-Null
    }

    return [ordered]@{
        metric_name = $MetricName
        label = $Label
        canonical_value = $CanonicalValue
        canonical_source = $CanonicalSource
        match = $allMatched
        mismatch_explanation = if ($allMatched) { "" } else { $MismatchExplanation }
        saved_derived_values = @($annotated.ToArray())
    }
}

function Invoke-RefreshCommand {
    param(
        [string]$ScriptName,
        [string]$ResolvedPairRoot,
        [string]$MissionPath
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (".\scripts\{0}" -f $ScriptName),
        "-PairRoot",
        $ResolvedPairRoot
    )
    $invokeArgs = @{
        PairRoot = $ResolvedPairRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionPath) -and $ScriptName -ne "evaluate_latest_session_mission.ps1") {
        $commandParts += @("-MissionPath", $MissionPath)
        $invokeArgs["MissionPath"] = $MissionPath
    }

    if ($ScriptName -ne "evaluate_latest_session_mission.ps1") {
        $commandParts += "-Once"
        $invokeArgs["Once"] = $true
    }

    $commandText = @($commandParts | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "

    try {
        $result = & $scriptPath @invokeArgs
        return [ordered]@{
            script = $ScriptName
            command = $commandText
            attempted = $true
            succeeded = $true
            error = ""
            result = $result
        }
    }
    catch {
        return [ordered]@{
            script = $ScriptName
            command = $commandText
            attempted = $true
            succeeded = $false
            error = $_.Exception.Message
            result = $null
        }
    }
}

function Get-ReconciliationData {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedEvalRoot
    )

    $pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    if ($null -eq $pairSummary) {
        throw "pair_summary.json could not be loaded: $pairSummaryPath"
    }

    $laneArtifacts = Get-TreatmentLaneArtifacts -ResolvedPairRoot $ResolvedPairRoot -PairSummary $pairSummary
    $controlSummary = Read-LaneSummaryFile -Path $laneArtifacts.ControlSummaryPath
    $treatmentSummary = Read-LaneSummaryFile -Path $laneArtifacts.TreatmentSummaryPath
    $comparisonPayload = Read-JsonFile -Path (Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "comparison.json"))
    $comparison = Get-ObjectPropertyValue -Object $comparisonPayload -Name "comparison" -Default $comparisonPayload
    $certificatePath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "grounded_evidence_certificate.json")
    $certificate = Read-JsonFile -Path $certificatePath
    $controlSwitchPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "control_to_treatment_switch.json")
    $controlSwitch = Read-JsonFile -Path $controlSwitchPath
    $treatmentPatchPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "treatment_patch_window.json")
    $treatmentPatch = Read-JsonFile -Path $treatmentPatchPath
    $phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "conservative_phase_flow.json")
    $phaseFlow = Read-JsonFile -Path $phaseFlowPath
    $missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission_execution.json")
    $missionExecution = Read-JsonFile -Path $missionExecutionPath
    $missionSnapshotPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.json")
    $missionSnapshot = Read-JsonFile -Path $missionSnapshotPath
    $liveMonitorStatusPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "live_monitor_status.json")
    $liveMonitorStatus = Read-JsonFile -Path $liveMonitorStatusPath
    $missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "mission_attainment.json")
    $missionAttainment = Read-JsonFile -Path $missionAttainmentPath
    $dossierPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "session_outcome_dossier.json")
    $dossier = Read-JsonFile -Path $dossierPath
    $humanAttemptPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "human_participation_conservative_attempt.json")
    $humanAttempt = Read-JsonFile -Path $humanAttemptPath
    $firstAttemptPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "first_grounded_conservative_attempt.json")
    $firstAttempt = Read-JsonFile -Path $firstAttemptPath
    $finalDocketPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\final_session_docket.json")
    $finalDocket = Read-JsonFile -Path $finalDocketPath
    $promotionGapDeltaPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "promotion_gap_delta.json")
    $promotionGapDelta = Read-JsonFile -Path $promotionGapDeltaPath
    $registryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedEvalRoot "registry\pair_sessions.ndjson")
    $registryEntries = Read-NdjsonFile -Path $registryPath
    $missionPath = Resolve-MissionPathForRefresh -ResolvedPairRoot $ResolvedPairRoot -ResolvedEvalRoot $ResolvedEvalRoot
    $mission = Read-JsonFile -Path $missionPath

    $registryEntry = Resolve-RegistryEntry -RegistryEntries $registryEntries -PairId ([string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default "")) -ResolvedPairRoot $ResolvedPairRoot

    return [ordered]@{
        pair_summary_path = $pairSummaryPath
        pair_summary = $pairSummary
        control_summary_path = $laneArtifacts.ControlSummaryPath
        control_summary = $controlSummary
        treatment_summary_path = $laneArtifacts.TreatmentSummaryPath
        treatment_summary = $treatmentSummary
        treatment_patch_history_path = $laneArtifacts.TreatmentPatchHistoryPath
        treatment_patch_history = Read-NdjsonFile -Path $laneArtifacts.TreatmentPatchHistoryPath
        treatment_patch_apply_history_path = $laneArtifacts.TreatmentPatchApplyHistoryPath
        treatment_patch_apply_history = Read-NdjsonFile -Path $laneArtifacts.TreatmentPatchApplyHistoryPath
        treatment_telemetry_history_path = $laneArtifacts.TreatmentTelemetryHistoryPath
        treatment_telemetry_history = Read-NdjsonFile -Path $laneArtifacts.TreatmentTelemetryHistoryPath
        comparison_path = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "comparison.json")
        comparison = $comparison
        certificate_path = $certificatePath
        certificate = $certificate
        control_switch_path = $controlSwitchPath
        control_switch = $controlSwitch
        treatment_patch_window_path = $treatmentPatchPath
        treatment_patch_window = $treatmentPatch
        phase_flow_path = $phaseFlowPath
        phase_flow = $phaseFlow
        mission_execution_path = $missionExecutionPath
        mission_execution = $missionExecution
        mission_snapshot_path = $missionSnapshotPath
        mission_snapshot = $missionSnapshot
        mission_path = $missionPath
        mission = $mission
        live_monitor_status_path = $liveMonitorStatusPath
        live_monitor_status = $liveMonitorStatus
        mission_attainment_path = $missionAttainmentPath
        mission_attainment = $missionAttainment
        session_outcome_dossier_path = $dossierPath
        session_outcome_dossier = $dossier
        human_attempt_path = $humanAttemptPath
        human_attempt = $humanAttempt
        first_attempt_path = $firstAttemptPath
        first_attempt = $firstAttempt
        final_docket_path = $finalDocketPath
        final_docket = $finalDocket
        promotion_gap_delta_path = $promotionGapDeltaPath
        promotion_gap_delta = $promotionGapDelta
        registry_path = $registryPath
        registry_entry = $registryEntry
    }
}

function Get-MetricComparisons {
    param([object]$Data)

    $canonical = Get-CanonicalMetrics `
        -PairSummary $Data.pair_summary `
        -ControlSummary $Data.control_summary `
        -TreatmentSummary $Data.treatment_summary `
        -Comparison $Data.comparison `
        -Certificate $Data.certificate `
        -Mission $Data.mission `
        -TreatmentPatchHistory $Data.treatment_patch_history `
        -TreatmentPatchApplyHistory $Data.treatment_patch_apply_history `
        -TreatmentTelemetryHistory $Data.treatment_telemetry_history

    $controlLaneFromSwitch = Get-ObjectPropertyValue -Object $Data.control_switch -Name "control_lane" -Default $null
    $treatmentLaneFromSwitch = Get-ObjectPropertyValue -Object $Data.control_switch -Name "treatment_lane" -Default $null
    $treatmentLaneFromPatch = Get-ObjectPropertyValue -Object $Data.treatment_patch_window -Name "treatment_lane" -Default $null
    $controlLaneFromPhase = Get-ObjectPropertyValue -Object $Data.phase_flow -Name "control_lane" -Default $null
    $treatmentLaneFromPhase = Get-ObjectPropertyValue -Object $Data.phase_flow -Name "treatment_lane" -Default $null
    $monitorStatus = $Data.live_monitor_status
    $missionTargetResults = Get-ObjectPropertyValue -Object $Data.mission_attainment -Name "target_results" -Default $null

    $comparisons = @(
        (New-MetricComparison -MetricName "control_human_snapshots" -Label "Control human snapshots" -CanonicalValue $canonical.control_human_snapshots_actual -CanonicalSource "pair_summary.json / control summary.json" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "control_to_treatment_switch" -Path $Data.control_switch_path -Value (Get-ObjectPropertyValue -Object $controlLaneFromSwitch -Name "actual_human_snapshots" -Default $null) -Summary "Saved control gate actual value."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $controlLaneFromPhase -Name "actual_human_snapshots" -Default $null) -Summary "Saved phase-director control value."),
                (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $Data.live_monitor_status_path -Value (Get-ObjectPropertyValue -Object $monitorStatus -Name "control_human_snapshots_count" -Default $null) -Summary "Saved live monitor control snapshots."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "control_minimum_human_snapshots" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout control actual value.")
            ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical control snapshot count.")
        (New-MetricComparison -MetricName "control_human_presence_seconds" -Label "Control human presence seconds" -CanonicalValue $canonical.control_human_presence_seconds_actual -CanonicalSource "pair_summary.json / control summary.json" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "control_to_treatment_switch" -Path $Data.control_switch_path -Value (Get-ObjectPropertyValue -Object $controlLaneFromSwitch -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved control gate control-seconds value."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $controlLaneFromPhase -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved phase-director control-seconds value."),
                (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $Data.live_monitor_status_path -Value (Get-ObjectPropertyValue -Object $monitorStatus -Name "control_human_presence_seconds" -Default $null) -Summary "Saved live monitor control-seconds value."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "control_minimum_human_presence_seconds" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout control-seconds value.")
            ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical control human-presence seconds.")
        (New-MetricComparison -MetricName "treatment_human_snapshots" -Label "Treatment human snapshots" -CanonicalValue $canonical.treatment_human_snapshots_actual -CanonicalSource "pair_summary.json / treatment summary.json" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "control_to_treatment_switch" -Path $Data.control_switch_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromSwitch -Name "actual_human_snapshots" -Default $null) -Summary "Saved control gate treatment snapshots."),
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPatch -Name "actual_human_snapshots" -Default $null) -Summary "Saved treatment gate treatment snapshots."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPhase -Name "actual_human_snapshots" -Default $null) -Summary "Saved phase-director treatment snapshots."),
                (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $Data.live_monitor_status_path -Value (Get-ObjectPropertyValue -Object $monitorStatus -Name "treatment_human_snapshots_count" -Default $null) -Summary "Saved live monitor treatment snapshots."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "treatment_minimum_human_snapshots" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout treatment snapshots.")
            ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical treatment snapshot count.")
        (New-MetricComparison -MetricName "treatment_human_presence_seconds" -Label "Treatment human presence seconds" -CanonicalValue $canonical.treatment_human_presence_seconds_actual -CanonicalSource "pair_summary.json / treatment summary.json" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "control_to_treatment_switch" -Path $Data.control_switch_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromSwitch -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved control gate treatment-seconds value."),
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPatch -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved treatment gate treatment-seconds value."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPhase -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved phase-director treatment-seconds value."),
                (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $Data.live_monitor_status_path -Value (Get-ObjectPropertyValue -Object $monitorStatus -Name "treatment_human_presence_seconds" -Default $null) -Summary "Saved live monitor treatment-seconds value."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "treatment_minimum_human_presence_seconds" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout treatment-seconds value.")
            ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical treatment human-presence seconds.")
        (New-MetricComparison -MetricName "counted_human_present_patch_events" -Label "Counted human-present patch events" -CanonicalValue $canonical.counted_human_present_patch_events_canonical -CanonicalSource "treatment summary.json patch_apply_count_while_humans_present / patch_apply_history.ndjson" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "control_to_treatment_switch" -Path $Data.control_switch_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromSwitch -Name "actual_patch_while_human_present_events" -Default $null) -Summary "Saved control gate patch count."),
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPatch -Name "actual_patch_while_human_present_events" -Default $null) -Summary "Saved treatment gate patch count."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPhase -Name "actual_patch_while_human_present_events" -Default $null) -Summary "Saved phase-director patch count."),
                (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $Data.live_monitor_status_path -Value (Get-ObjectPropertyValue -Object $monitorStatus -Name "treatment_patch_events_while_humans_present" -Default $null) -Summary "Saved live monitor patch count."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "treatment_minimum_patch_while_human_present_events" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout patch count.")
            ) -MismatchExplanation "Secondary derived artifacts are still using an under-counted treatment patch metric instead of the canonical patch-apply count during the human window.")
        (New-MetricComparison -MetricName "first_human_present_patch_timestamp" -Label "First human-present patch timestamp" -CanonicalValue $canonical.first_human_present_patch_timestamp_utc -CanonicalSource ("{0}" -f $canonical.first_human_present_patch_source) -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPatch -Name "first_human_present_patch_timestamp_utc" -Default $null) -Summary "Saved treatment gate canonical patch timestamp.")
            ) -MismatchExplanation "The saved treatment gate is pointing at a different first human-present patch timestamp than the canonical metric source.")
        (New-MetricComparison -MetricName "first_human_present_patch_offset_seconds" -Label "First human-present patch offset seconds" -CanonicalValue ([Math]::Round([double]$canonical.first_human_present_patch_offset_seconds, 2)) -CanonicalSource ("{0}" -f $canonical.first_human_present_patch_source) -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPatch -Name "first_human_present_patch_offset_seconds" -Default $null) -Summary "Saved treatment gate canonical patch offset.")
            ) -MismatchExplanation "The saved treatment gate is pointing at a different first human-present patch offset than the canonical metric source.")
        (New-MetricComparison -MetricName "meaningful_post_patch_observation_seconds" -Label "Meaningful post-patch observation seconds" -CanonicalValue $canonical.meaningful_post_patch_observation_seconds_canonical -CanonicalSource "telemetry_history.ndjson / patch_apply_history.ndjson with treatment summary fallback" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "control_to_treatment_switch" -Path $Data.control_switch_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromSwitch -Name "actual_post_patch_observation_seconds" -Default $null) -Summary "Saved control gate post-patch seconds."),
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPatch -Name "actual_post_patch_observation_seconds" -Default $null) -Summary "Saved treatment gate post-patch seconds."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $treatmentLaneFromPhase -Name "actual_post_patch_observation_seconds" -Default $null) -Summary "Saved phase-director post-patch seconds."),
                (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $Data.live_monitor_status_path -Value (Get-ObjectPropertyValue -Object $monitorStatus -Name "meaningful_post_patch_observation_seconds" -Default $null) -Summary "Saved live monitor post-patch seconds."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionTargetResults -Name "minimum_post_patch_observation_window_seconds" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout post-patch seconds.")
            ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical post-patch observation seconds.")
        (New-MetricComparison -MetricName "treatment_grounded_ready" -Label "Treatment grounded-ready" -CanonicalValue $canonical.treatment_grounded_ready_canonical -CanonicalSource "canonical treatment human signal + patch applies + post-patch window" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $Data.treatment_patch_window_path -Value (Get-ObjectPropertyValue -Object $Data.treatment_patch_window -Name "treatment_grounded_ready" -Default $null) -Summary "Saved treatment gate grounded-ready verdict."),
                (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $Data.phase_flow_path -Value (Get-ObjectPropertyValue -Object $Data.phase_flow -Name "finish_grounded_session_allowed" -Default $null) -Summary "Saved phase-director finish verdict.")
            ) -MismatchExplanation "The saved grounded-ready gates disagree with the canonical treatment evidence.")
        (New-MetricComparison -MetricName "pair_grounded_counting" -Label "Pair grounded-counting" -CanonicalValue $canonical.pair_grounded_counting_canonical -CanonicalSource "canonical pair evidence + certificate eligibility rules" -DerivedValues @(
                (New-DerivedValueRecord -ArtifactName "grounded_evidence_certificate" -Path $Data.certificate_path -Value (Get-ObjectPropertyValue -Object $Data.certificate -Name "counts_toward_promotion" -Default $null) -Summary "Saved certification promotion-counting state."),
                (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $Data.mission_attainment_path -Value (Get-ObjectPropertyValue -Object $Data.mission_attainment -Name "counts_toward_promotion" -Default $null) -Summary "Saved mission-attainment promotion-counting state."),
                (New-DerivedValueRecord -ArtifactName "session_outcome_dossier" -Path $Data.session_outcome_dossier_path -Value (Get-ObjectPropertyValue -Object $Data.session_outcome_dossier -Name "counts_toward_promotion" -Default $null) -Summary "Saved outcome dossier promotion-counting state."),
                (New-DerivedValueRecord -ArtifactName "promotion_gap_delta" -Path $Data.promotion_gap_delta_path -Value (Get-ObjectPropertyValue -Object $Data.promotion_gap_delta -Name "counts_toward_promotion" -Default $null) -Summary "Saved promotion-gap delta promotion-counting state."),
                (New-DerivedValueRecord -ArtifactName "registry_entry" -Path $Data.registry_path -Value (Get-ObjectPropertyValue -Object $Data.registry_entry -Name "counts_toward_promotion" -Default $null) -Summary "Append-only registry promotion-counting state.")
            ) -MismatchExplanation "Promotion-counting state differs from the canonical pair evidence and needs explicit review.")
    )

    return [ordered]@{
        canonical = $canonical
        comparisons = $comparisons
    }
}

function Get-NarrativeContradictions {
    param(
        [object]$Canonical,
        [object]$Data
    )

    $notes = New-Object System.Collections.Generic.List[string]
    $missionVerdict = [string](Get-ObjectPropertyValue -Object $Data.mission_attainment -Name "mission_verdict" -Default "")
    if ($Canonical.pair_grounded_counting_canonical -and $missionVerdict -like "mission-failed*") {
        $notes.Add("mission_attainment.json still reports a failed mission verdict even though the canonical pair evidence remains grounded and promotion-counting.") | Out-Null
    }

    $humanAttemptPhaseVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Data.human_attempt -Name "phase_flow_guidance" -Default $null) -Name "current_phase_verdict" -Default "")
    if ($Canonical.treatment_grounded_ready_canonical -and $humanAttemptPhaseVerdict -eq "phase-insufficient-timeout") {
        $notes.Add("human_participation_conservative_attempt.json still preserves the old phase-director timeout narrative.") | Out-Null
    }

    $finalDocketMonitorVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Data.final_docket -Name "monitor" -Default $null) -Name "last_verdict" -Default "")
    if ($Canonical.pair_grounded_counting_canonical -and $finalDocketMonitorVerdict -eq "insufficient-data-timeout") {
        $notes.Add("guided_session\\final_session_docket.json still preserves the stale monitor timeout narrative.") | Out-Null
    }

    return @($notes.ToArray())
}

function Get-RefreshPlan {
    param(
        [string]$ResolvedPairRoot,
        [string]$MissionPath
    )

    return @(
        [ordered]@{ script = "guide_control_to_treatment_switch.ps1"; pair_root = $ResolvedPairRoot; mission_path = $MissionPath },
        [ordered]@{ script = "guide_treatment_patch_window.ps1"; pair_root = $ResolvedPairRoot; mission_path = $MissionPath },
        [ordered]@{ script = "guide_conservative_phase_flow.ps1"; pair_root = $ResolvedPairRoot; mission_path = $MissionPath },
        [ordered]@{ script = "evaluate_latest_session_mission.ps1"; pair_root = $ResolvedPairRoot; mission_path = "" }
    )
}

function Get-ReconciliationMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Pair Metric Reconciliation") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Reconciliation verdict: $($Report.reconciliation_verdict)") | Out-Null
    $lines.Add("- Final counted grounded status: $($Report.final_counted_grounded_status)") | Out-Null
    $lines.Add("- Final promotion-counting status: $($Report.final_promotion_counting_status)") | Out-Null
    $lines.Add("- Manual-review label still needed: $($Report.manual_review_label_still_needed)") | Out-Null
    $lines.Add("- Registry correction recommended: $($Report.registry_correction_recommended)") | Out-Null
    $lines.Add("- Planner/gate recomputation recommended: $($Report.planner_gate_recomputation_recommended)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Canonical Precedence") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($source in @($Report.canonical_sources)) {
        $lines.Add("- $($source.kind): $($source.path)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Secondary / Potentially Stale Sources") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($source in @($Report.secondary_sources)) {
        $lines.Add("- $($source.kind): $($source.path)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Metric Comparison") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($comparison in @($Report.metric_comparison)) {
        $lines.Add("- $($comparison.label): canonical=$($comparison.canonical_value); match=$($comparison.match)") | Out-Null
        foreach ($derived in @($comparison.saved_derived_values)) {
            $lines.Add("  - $($derived.artifact_name): $($derived.value) (match=$($derived.match))") | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$comparison.mismatch_explanation)) {
            $lines.Add("  - mismatch: $($comparison.mismatch_explanation)") | Out-Null
        }
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Refresh") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Safe refresh allowed: $($Report.safe_refresh.allowed)") | Out-Null
    $lines.Add("- Dry run: $($Report.safe_refresh.dry_run)") | Out-Null
    $lines.Add("- Execute refresh: $($Report.safe_refresh.execute_refresh)") | Out-Null
    $lines.Add("- Refresh attempted: $($Report.safe_refresh.attempted)") | Out-Null
    $lines.Add("- Refresh succeeded: $($Report.safe_refresh.succeeded)") | Out-Null
    foreach ($step in @($Report.safe_refresh.steps)) {
        $lines.Add("- $($step.script): $($step.command)") | Out-Null
        if (-not [string]::IsNullOrWhiteSpace([string]$step.error)) {
            $lines.Add("  - error: $($step.error)") | Out-Null
        }
    }
    if (@($Report.remaining_stale_artifacts).Count -gt 0) {
        $lines.Add("") | Out-Null
        $lines.Add("## Remaining Stale Artifacts") | Out-Null
        $lines.Add("") | Out-Null
        foreach ($note in @($Report.remaining_stale_artifacts)) {
            $lines.Add("- $note") | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot)
}
$resolvedEvalRoot = Get-ResolvedEvalRoot -ExplicitLabRoot $resolvedLabRoot -ExplicitEvalRoot $EvalRoot
$resolvedPairsRoot = Get-ResolvedPairsRoot -ExplicitPairsRoot $PairsRoot -ResolvedLabRoot $resolvedLabRoot
$resolvedPairRoot = Resolve-ReconciliationPairRoot -ExplicitPairRoot $PairRoot -ShouldUseLatest:($UseLatest -or [string]::IsNullOrWhiteSpace($PairRoot)) -ResolvedEvalRoot $resolvedEvalRoot -ResolvedPairsRoot $resolvedPairsRoot

if (-not $resolvedPairRoot) {
    throw "A metric-reconciliation target pair root could not be resolved."
}

$outputPaths = Get-OutputPaths -ResolvedPairRoot $resolvedPairRoot -ExplicitOutputRoot $OutputRoot -ResolvedEvalRoot $resolvedEvalRoot
$missionPathForRefresh = Resolve-MissionPathForRefresh -ResolvedPairRoot $resolvedPairRoot -ResolvedEvalRoot $resolvedEvalRoot

$data = Get-ReconciliationData -ResolvedPairRoot $resolvedPairRoot -ResolvedEvalRoot $resolvedEvalRoot
$metricState = Get-MetricComparisons -Data $data
$canonical = $metricState.canonical
$metricComparisons = @($metricState.comparisons)
$metricMismatches = @($metricComparisons | Where-Object { -not [bool](Get-ObjectPropertyValue -Object $_ -Name "match" -Default $false) })
$narrativeContradictions = Get-NarrativeContradictions -Canonical $canonical -Data $data

$certificateCountsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $data.certificate -Name "counts_toward_promotion" -Default $false)
$registryCountsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $data.registry_entry -Name "counts_toward_promotion" -Default $false)
$promotionStateRisk = $canonical.pair_grounded_counting_canonical -ne $certificateCountsTowardPromotion -or (
    $null -ne $data.registry_entry -and $canonical.pair_grounded_counting_canonical -ne $registryCountsTowardPromotion
)

$safeRefreshAllowed = -not $promotionStateRisk -and (@($metricMismatches).Count -gt 0 -or @($narrativeContradictions).Count -gt 0)
$refreshPlan = Get-RefreshPlan -ResolvedPairRoot $resolvedPairRoot -MissionPath $missionPathForRefresh
$refreshSteps = New-Object System.Collections.Generic.List[object]
$refreshAttempted = $false
$refreshSucceeded = $false
$refreshError = ""

if ($ExecuteRefresh -and $safeRefreshAllowed) {
    $refreshAttempted = $true
    $refreshSucceeded = $true
    foreach ($step in @($refreshPlan)) {
        $result = Invoke-RefreshCommand -ScriptName $step.script -ResolvedPairRoot $resolvedPairRoot -MissionPath ([string]$step.mission_path)
        $refreshSteps.Add($result) | Out-Null
        if (-not [bool]$result.succeeded) {
            $refreshSucceeded = $false
            $refreshError = [string]$result.error
            break
        }
    }

    $data = Get-ReconciliationData -ResolvedPairRoot $resolvedPairRoot -ResolvedEvalRoot $resolvedEvalRoot
    $metricState = Get-MetricComparisons -Data $data
    $canonical = $metricState.canonical
    $metricComparisons = @($metricState.comparisons)
    $metricMismatches = @($metricComparisons | Where-Object { -not [bool](Get-ObjectPropertyValue -Object $_ -Name "match" -Default $false) })
    $narrativeContradictions = Get-NarrativeContradictions -Canonical $canonical -Data $data
}
else {
    foreach ($step in @($refreshPlan)) {
        $refreshSteps.Add([ordered]@{
                script = $step.script
                command = (@(
                        "powershell",
                        "-NoProfile",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-File",
                        (".\scripts\{0}" -f $step.script),
                        "-PairRoot",
                        $resolvedPairRoot
                    ) + $(if ($step.mission_path) { @("-MissionPath", $step.mission_path) } else { @() }) + $(if ($step.script -ne "evaluate_latest_session_mission.ps1") { @("-Once") } else { @() }) | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "
                attempted = $false
                succeeded = $false
                error = ""
            }) | Out-Null
    }
}

$manualReviewLabelStillNeeded = @($narrativeContradictions).Count -gt 0
$registryCorrectionRecommended = $promotionStateRisk
$plannerGateRecomputationRecommended = $false

$reconciliationVerdict = if ($promotionStateRisk) {
    "metrics-inconsistent-promotion-state-risk"
}
elseif (@($metricMismatches).Count -eq 0 -and @($narrativeContradictions).Count -eq 0) {
    "metrics-consistent-no-refresh-needed"
}
elseif (@($metricMismatches).Count -eq 0 -and @($narrativeContradictions).Count -gt 0) {
    if ($manualReviewLabelStillNeeded) { "metrics-reconciled-manual-review-label-still-needed" } else { "metrics-consistent-but-narrative-stale" }
}
elseif ($safeRefreshAllowed) {
    if ($manualReviewLabelStillNeeded) { "metrics-reconciled-manual-review-label-still-needed" } else { "metrics-reconciled-safe-derived-refresh" }
}
else {
    "metrics-inconclusive-manual-review-required"
}

$explanationParts = New-Object System.Collections.Generic.List[string]
if ($canonical.pair_grounded_counting_canonical) {
    $explanationParts.Add("Canonical pair evidence still supports grounded promotion counting for this pair.") | Out-Null
}
else {
    $explanationParts.Add("Canonical pair evidence does not currently support grounded promotion counting for this pair.") | Out-Null
}

if (@($metricMismatches).Count -gt 0) {
    $explanationParts.Add("The main disagreement was between canonical treatment patch-apply counting during the human window and stale secondary derived artifacts that under-counted treatment readiness.") | Out-Null
}
else {
    $explanationParts.Add("The canonical and refreshed derived metrics now agree on the control/treatment evidence counts.") | Out-Null
}

if (@($narrativeContradictions).Count -gt 0) {
    $explanationParts.Add("Some operator-facing wrapper or docket narratives still preserve stale wording and should remain manual-review-labeled until they are explicitly regenerated or superseded.") | Out-Null
}

if (-not $registryCorrectionRecommended) {
    $explanationParts.Add("No registry or promotion-history rewrite is justified because canonical promotion state did not change.") | Out-Null
}

$canonicalSources = @(
    (Get-ArtifactRecord -Kind "pair_summary_json" -Path $data.pair_summary_path -Canonical $true -Summary "Canonical pair-level control/treatment metrics and comparison summary."),
    (Get-ArtifactRecord -Kind "control_summary_json" -Path $data.control_summary_path -Canonical $true -Summary "Canonical control lane summary."),
    (Get-ArtifactRecord -Kind "treatment_summary_json" -Path $data.treatment_summary_path -Canonical $true -Summary "Canonical treatment lane summary including patch_apply_count_while_humans_present."),
    (Get-ArtifactRecord -Kind "patch_apply_history_ndjson" -Path $data.treatment_patch_apply_history_path -Canonical $true -Summary "Canonical patch-apply timeline used for human-window patch counting."),
    (Get-ArtifactRecord -Kind "patch_history_ndjson" -Path $data.treatment_patch_history_path -Canonical $true -Summary "Secondary raw patch recommendation timeline used only when apply data is incomplete."),
    (Get-ArtifactRecord -Kind "telemetry_history_ndjson" -Path $data.treatment_telemetry_history_path -Canonical $true -Summary "Canonical telemetry used for the post-patch observation window."),
    (Get-ArtifactRecord -Kind "grounded_evidence_certificate_json" -Path $data.certificate_path -Canonical $true -Summary "Canonical promotion-counting certification layer."),
    (Get-ArtifactRecord -Kind "mission_execution_json" -Path $data.mission_execution_path -Canonical $true -Summary "Canonical mission-compliance context."),
    (Get-ArtifactRecord -Kind "mission_snapshot_json" -Path $data.mission_snapshot_path -Canonical $true -Summary "Canonical mission thresholds for this saved pair.")
)

$secondarySources = @(
    (Get-ArtifactRecord -Kind "control_to_treatment_switch_json" -Path $data.control_switch_path -Canonical $false -Summary "Secondary operator gate derived from pair metrics."),
    (Get-ArtifactRecord -Kind "treatment_patch_window_json" -Path $data.treatment_patch_window_path -Canonical $false -Summary "Secondary treatment-hold gate derived from pair metrics."),
    (Get-ArtifactRecord -Kind "conservative_phase_flow_json" -Path $data.phase_flow_path -Canonical $false -Summary "Secondary sequential phase-director derived from control/treatment gates."),
    (Get-ArtifactRecord -Kind "live_monitor_status_json" -Path $data.live_monitor_status_path -Canonical $false -Summary "Secondary saved monitor snapshot that can go stale after pair completion."),
    (Get-ArtifactRecord -Kind "mission_attainment_json" -Path $data.mission_attainment_path -Canonical $false -Summary "Secondary mission-closeout artifact that previously inherited stale monitor metrics."),
    (Get-ArtifactRecord -Kind "session_outcome_dossier_json" -Path $data.session_outcome_dossier_path -Canonical $false -Summary "Secondary outcome dossier for operator summary."),
    (Get-ArtifactRecord -Kind "human_participation_conservative_attempt_json" -Path $data.human_attempt_path -Canonical $false -Summary "Secondary wrapper report that can preserve stale gate wording."),
    (Get-ArtifactRecord -Kind "first_grounded_conservative_attempt_json" -Path $data.first_attempt_path -Canonical $false -Summary "Secondary milestone wrapper."),
    (Get-ArtifactRecord -Kind "guided_final_session_docket_json" -Path $data.final_docket_path -Canonical $false -Summary "Secondary final docket that can preserve stale monitor wording.")
)

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $resolvedPairRoot
    pair_id = [string](Get-ObjectPropertyValue -Object $data.pair_summary -Name "pair_id" -Default "")
    target_selection = if ([string]::IsNullOrWhiteSpace($PairRoot)) { "current-manual-review-target" } else { "explicit-pair-root" }
    certification_verdict_before_reconciliation = [string](Get-ObjectPropertyValue -Object $data.certificate -Name "certification_verdict" -Default "")
    reconciliation_verdict = $reconciliationVerdict
    final_counted_grounded_status = $canonical.pair_grounded_counting_canonical
    final_promotion_counting_status = $canonical.pair_grounded_counting_canonical
    manual_review_label_still_needed = $manualReviewLabelStillNeeded
    registry_correction_recommended = $registryCorrectionRecommended
    planner_gate_recomputation_recommended = $plannerGateRecomputationRecommended
    explanation = (($explanationParts.ToArray()) -join " ")
    canonical_sources = $canonicalSources
    secondary_sources = $secondarySources
    canonical_metric_precedence = [ordered]@{
        treatment_patch_metric = "patch_apply_count_while_humans_present from treatment summary.json, confirmed against patch_apply_history.ndjson"
        treatment_post_patch_window_metric = "telemetry_history.ndjson plus patch_apply_history.ndjson, with treatment summary meaningful-window flag as fallback"
        pair_grounded_counting = "canonical pair evidence plus grounded certification eligibility rules"
    }
    metric_comparison = $metricComparisons
    canonical_metrics = $canonical
    safe_refresh = [ordered]@{
        allowed = $safeRefreshAllowed
        dry_run = [bool]$DryRun
        execute_refresh = [bool]$ExecuteRefresh
        attempted = $refreshAttempted
        succeeded = if ($refreshAttempted) { $refreshSucceeded } else { $false }
        error = $refreshError
        steps = @($refreshSteps.ToArray())
    }
    remaining_stale_artifacts = $narrativeContradictions
    promotion_state = [ordered]@{
        certificate_counts_toward_promotion = $certificateCountsTowardPromotion
        registry_counts_toward_promotion = $registryCountsTowardPromotion
        pair_remains_manual_review_labeled = $manualReviewLabelStillNeeded
        current_next_live_objective = [string](Get-ObjectPropertyValue -Object $data.session_outcome_dossier -Name "current_next_live_objective" -Default (Get-ObjectPropertyValue -Object $data.promotion_gap_delta -Name "next_objective_after" -Default ""))
        current_responsive_gate_verdict = [string](Get-ObjectPropertyValue -Object $data.session_outcome_dossier -Name "current_responsive_gate_verdict" -Default "")
    }
    artifacts = [ordered]@{
        pair_metric_reconciliation_json = $outputPaths.JsonPath
        pair_metric_reconciliation_markdown = $outputPaths.MarkdownPath
        pair_summary_json = $data.pair_summary_path
        control_summary_json = $data.control_summary_path
        treatment_summary_json = $data.treatment_summary_path
        patch_history_ndjson = $data.treatment_patch_history_path
        patch_apply_history_ndjson = $data.treatment_patch_apply_history_path
        telemetry_history_ndjson = $data.treatment_telemetry_history_path
        grounded_evidence_certificate_json = $data.certificate_path
        control_to_treatment_switch_json = $data.control_switch_path
        treatment_patch_window_json = $data.treatment_patch_window_path
        conservative_phase_flow_json = $data.phase_flow_path
        live_monitor_status_json = $data.live_monitor_status_path
        mission_attainment_json = $data.mission_attainment_path
        session_outcome_dossier_json = $data.session_outcome_dossier_path
        human_participation_conservative_attempt_json = $data.human_attempt_path
        first_grounded_conservative_attempt_json = $data.first_attempt_path
        guided_final_session_docket_json = $data.final_docket_path
        registry_path = $data.registry_path
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-ReconciliationMarkdown -Report $reportForMarkdown)

Write-Host "Pair metric reconciliation:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Reconciliation verdict: $($report.reconciliation_verdict)"
Write-Host "  Final counted grounded status: $($report.final_counted_grounded_status)"
Write-Host "  Final promotion-counting status: $($report.final_promotion_counting_status)"
Write-Host "  Safe refresh allowed: $($report.safe_refresh.allowed)"
Write-Host "  Refresh attempted: $($report.safe_refresh.attempted)"
Write-Host "  Reconciliation JSON: $($outputPaths.JsonPath)"
Write-Host "  Reconciliation Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    PairMetricReconciliationJsonPath = $outputPaths.JsonPath
    PairMetricReconciliationMarkdownPath = $outputPaths.MarkdownPath
    ReconciliationVerdict = [string]$report.reconciliation_verdict
    FinalCountedGroundedStatus = [bool]$report.final_counted_grounded_status
    FinalPromotionCountingStatus = [bool]$report.final_promotion_counting_status
    ManualReviewLabelStillNeeded = [bool]$report.manual_review_label_still_needed
    SafeRefreshAllowed = [bool]$report.safe_refresh.allowed
    RefreshAttempted = [bool]$report.safe_refresh.attempted
    RefreshSucceeded = [bool]$report.safe_refresh.succeeded
}
