[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$MissionPath = "",
    [int]$PollSeconds = 5,
    [switch]$Once,
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$PairsRoot = "",
    [string]$OutputRoot = ""
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

    $json = $Value | ConvertTo-Json -Depth 20
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

    if ($null -ne $payload.PSObject.Properties["primary_lane"]) {
        return $payload.primary_lane
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

function Find-LatestPairRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName "guided_session")) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName "pair_summary.json")) -or
            (Test-Path -LiteralPath (Join-Path $_.FullName "control_join_instructions.txt"))
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Resolve-PairRootForSwitchGuide {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ResolvedEvalRoot,
        [string]$ResolvedPairsRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        return Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
    }

    if (-not $ShouldUseLatest) {
        return ""
    }

    $latestPairRoot = Find-LatestPairRoot -Root $ResolvedEvalRoot
    if ($latestPairRoot) {
        return Resolve-ExistingPath -Path $latestPairRoot
    }

    return Resolve-ExistingPath -Path (Find-LatestPairRoot -Root $ResolvedPairsRoot)
}

function Resolve-MissionContext {
    param(
        [string]$ExplicitMissionPath,
        [string]$ResolvedPairRoot,
        [string]$ResolvedEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $resolvedMissionPath = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionPath)
        if (-not $resolvedMissionPath) {
            throw "Mission JSON was not found: $ExplicitMissionPath"
        }

        return [pscustomobject]@{
            MissionPath = $resolvedMissionPath
            Mission = Read-JsonFile -Path $resolvedMissionPath
            SourceKind = "explicit-mission-path"
            MissionExecutionPath = ""
            MissionSnapshotPath = ""
        }
    }

    $missionExecutionPath = ""
    $missionSnapshotPath = ""
    $candidateMissionPaths = New-Object System.Collections.Generic.List[string]

    if ($ResolvedPairRoot) {
        $pairMissionSnapshotPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.json")
        if ($pairMissionSnapshotPath) {
            $candidateMissionPaths.Add($pairMissionSnapshotPath) | Out-Null
            $missionSnapshotPath = $pairMissionSnapshotPath
        }

        $missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission_execution.json")
        $missionExecution = Read-JsonFile -Path $missionExecutionPath
        $missionPathFromExecution = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionExecution -Name "mission_path_used" -Default ""))
        if ($missionPathFromExecution) {
            $candidateMissionPaths.Add($missionPathFromExecution) | Out-Null
        }
    }

    $registryMissionPath = Resolve-ExistingPath -Path (Join-Path $ResolvedEvalRoot "registry\next_live_session_mission.json")
    if ($registryMissionPath) {
        $candidateMissionPaths.Add($registryMissionPath) | Out-Null
    }

    foreach ($candidateMissionPath in ($candidateMissionPaths | Select-Object -Unique)) {
        $mission = Read-JsonFile -Path $candidateMissionPath
        if ($null -ne $mission) {
            $sourceKind = if ($candidateMissionPath -eq $missionSnapshotPath) {
                "pair-mission-snapshot"
            }
            elseif ($candidateMissionPath -eq $registryMissionPath) {
                "registry-current-mission"
            }
            else {
                "mission-execution-reference"
            }

            return [pscustomobject]@{
                MissionPath = $candidateMissionPath
                Mission = $mission
                SourceKind = $sourceKind
                MissionExecutionPath = $missionExecutionPath
                MissionSnapshotPath = $missionSnapshotPath
            }
        }
    }

    return [pscustomobject]@{
        MissionPath = ""
        Mission = $null
        SourceKind = ""
        MissionExecutionPath = $missionExecutionPath
        MissionSnapshotPath = $missionSnapshotPath
    }
}

function Resolve-Thresholds {
    param(
        [object]$PairSummary,
        [object]$ControlSummary,
        [object]$TreatmentSummary,
        [object]$Mission,
        [object]$MissionExecution
    )

    $missionLaunch = Get-ObjectPropertyValue -Object $MissionExecution -Name "actual_launch_parameters" -Default $null

    $controlSnapshots = if ([int](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_snapshots" -Default 0) -gt 0) {
        [int](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_snapshots" -Default 0)
    }
    elseif ([int](Get-ObjectPropertyValue -Object $ControlSummary -Name "min_human_snapshots" -Default 0) -gt 0) {
        [int](Get-ObjectPropertyValue -Object $ControlSummary -Name "min_human_snapshots" -Default 0)
    }
    elseif ([int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_snapshots" -Default 0) -gt 0) {
        [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_snapshots" -Default 0)
    }
    else {
        [int](Get-ObjectPropertyValue -Object $missionLaunch -Name "min_human_snapshots" -Default 3)
    }

    $controlSeconds = if ([double](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_presence_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_presence_seconds" -Default 0.0)
    }
    elseif ([double](Get-ObjectPropertyValue -Object $ControlSummary -Name "min_human_presence_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $ControlSummary -Name "min_human_presence_seconds" -Default 0.0)
    }
    elseif ([double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_presence_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_presence_seconds" -Default 0.0)
    }
    else {
        [double](Get-ObjectPropertyValue -Object $missionLaunch -Name "min_human_presence_seconds" -Default 60.0)
    }

    $treatmentSnapshots = if ([int](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_snapshots" -Default 0) -gt 0) {
        [int](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_snapshots" -Default 0)
    }
    elseif ([int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "min_human_snapshots" -Default 0) -gt 0) {
        [int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "min_human_snapshots" -Default 0)
    }
    elseif ([int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_snapshots" -Default 0) -gt 0) {
        [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_snapshots" -Default 0)
    }
    else {
        [int](Get-ObjectPropertyValue -Object $missionLaunch -Name "min_human_snapshots" -Default 3)
    }

    $treatmentSeconds = if ([double](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_presence_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $PairSummary -Name "min_human_presence_seconds" -Default 0.0)
    }
    elseif ([double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "min_human_presence_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "min_human_presence_seconds" -Default 0.0)
    }
    elseif ([double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0.0)
    }
    else {
        [double](Get-ObjectPropertyValue -Object $missionLaunch -Name "min_human_presence_seconds" -Default 60.0)
    }

    $patchEvents = if ([int](Get-ObjectPropertyValue -Object $PairSummary -Name "min_patch_events_for_usable_lane" -Default -1) -ge 0) {
        [int](Get-ObjectPropertyValue -Object $PairSummary -Name "min_patch_events_for_usable_lane" -Default -1)
    }
    elseif ([int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "min_patch_events_for_usable_lane" -Default -1) -ge 0) {
        [int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "min_patch_events_for_usable_lane" -Default -1)
    }
    elseif ([int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default -1) -ge 0) {
        [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default -1)
    }
    else {
        [int](Get-ObjectPropertyValue -Object $missionLaunch -Name "min_patch_events_for_usable_lane" -Default 2)
    }

    $postPatchSeconds = if ([double](Get-ObjectPropertyValue -Object $PairSummary -Name "min_post_patch_observation_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $PairSummary -Name "min_post_patch_observation_seconds" -Default 0.0)
    }
    elseif ([double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0.0) -gt 0) {
        [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0.0)
    }
    else {
        [double](Get-ObjectPropertyValue -Object $missionLaunch -Name "min_post_patch_observation_seconds" -Default 20.0)
    }

    return [pscustomobject]@{
        ControlHumanSnapshots = $controlSnapshots
        ControlHumanPresenceSeconds = $controlSeconds
        TreatmentHumanSnapshots = $treatmentSnapshots
        TreatmentHumanPresenceSeconds = $treatmentSeconds
        TreatmentPatchWhileHumanPresentEvents = $patchEvents
        PostPatchObservationSeconds = $postPatchSeconds
    }
}

function Get-HistoryProgress {
    param(
        [object[]]$HistoryRecords,
        [int]$ControlTargetSnapshots,
        [double]$ControlTargetSeconds
    )

    if ($null -eq $HistoryRecords -or $HistoryRecords.Count -eq 0) {
        return [pscustomobject]@{
            HasFreshControlHistory = $false
            ControlMaxSnapshots = 0
            ControlMaxSeconds = 0.0
            TreatmentMaxSnapshots = 0
            TreatmentMaxSeconds = 0.0
            PatchEventsMax = 0
            PostPatchSecondsMax = 0.0
            LatestVerdict = ""
            LatestPhase = ""
            PairComplete = $false
            LatestExplanation = ""
        }
    }

    $freshIndex = -1
    for ($index = 0; $index -lt $HistoryRecords.Count; $index++) {
        $record = $HistoryRecords[$index]
        $recordVerdict = [string](Get-ObjectPropertyValue -Object $record -Name "current_verdict" -Default "")
        $recordControlSnapshots = [int](Get-ObjectPropertyValue -Object $record -Name "control_human_snapshots_count" -Default 0)
        $recordControlSeconds = [double](Get-ObjectPropertyValue -Object $record -Name "control_human_presence_seconds" -Default 0.0)
        if ($recordVerdict -eq "waiting-for-control-human-signal" -or $recordControlSnapshots -lt $ControlTargetSnapshots -or $recordControlSeconds -lt $ControlTargetSeconds) {
            $freshIndex = $index
            break
        }
    }

    if ($freshIndex -lt 0) {
        $latestRecord = $HistoryRecords | Select-Object -Last 1
        return [pscustomobject]@{
            HasFreshControlHistory = $false
            ControlMaxSnapshots = 0
            ControlMaxSeconds = 0.0
            TreatmentMaxSnapshots = 0
            TreatmentMaxSeconds = 0.0
            PatchEventsMax = 0
            PostPatchSecondsMax = 0.0
            LatestVerdict = [string](Get-ObjectPropertyValue -Object $latestRecord -Name "current_verdict" -Default "")
            LatestPhase = [string](Get-ObjectPropertyValue -Object $latestRecord -Name "phase" -Default "")
            PairComplete = [bool](Get-ObjectPropertyValue -Object $latestRecord -Name "pair_complete" -Default $false)
            LatestExplanation = [string](Get-ObjectPropertyValue -Object $latestRecord -Name "explanation" -Default "")
        }
    }

    $trustedRecords = @($HistoryRecords[$freshIndex..($HistoryRecords.Count - 1)])
    $latestTrustedRecord = $trustedRecords | Select-Object -Last 1

    $controlMaxSnapshots = 0
    $controlMaxSeconds = 0.0
    $treatmentMaxSnapshots = 0
    $treatmentMaxSeconds = 0.0
    $patchEventsMax = 0
    $postPatchSecondsMax = 0.0

    foreach ($record in $trustedRecords) {
        $controlMaxSnapshots = [Math]::Max($controlMaxSnapshots, [int](Get-ObjectPropertyValue -Object $record -Name "control_human_snapshots_count" -Default 0))
        $controlMaxSeconds = [Math]::Max($controlMaxSeconds, [double](Get-ObjectPropertyValue -Object $record -Name "control_human_presence_seconds" -Default 0.0))
        $treatmentMaxSnapshots = [Math]::Max($treatmentMaxSnapshots, [int](Get-ObjectPropertyValue -Object $record -Name "treatment_human_snapshots_count" -Default 0))
        $treatmentMaxSeconds = [Math]::Max($treatmentMaxSeconds, [double](Get-ObjectPropertyValue -Object $record -Name "treatment_human_presence_seconds" -Default 0.0))
        $patchEventsMax = [Math]::Max($patchEventsMax, [int](Get-ObjectPropertyValue -Object $record -Name "treatment_patch_events_while_humans_present" -Default 0))
        $postPatchSecondsMax = [Math]::Max($postPatchSecondsMax, [double](Get-ObjectPropertyValue -Object $record -Name "meaningful_post_patch_observation_seconds" -Default 0.0))
    }

    return [pscustomobject]@{
        HasFreshControlHistory = $true
        ControlMaxSnapshots = $controlMaxSnapshots
        ControlMaxSeconds = $controlMaxSeconds
        TreatmentMaxSnapshots = $treatmentMaxSnapshots
        TreatmentMaxSeconds = $treatmentMaxSeconds
        PatchEventsMax = $patchEventsMax
        PostPatchSecondsMax = $postPatchSecondsMax
        LatestVerdict = [string](Get-ObjectPropertyValue -Object $latestTrustedRecord -Name "current_verdict" -Default "")
        LatestPhase = [string](Get-ObjectPropertyValue -Object $latestTrustedRecord -Name "phase" -Default "")
        PairComplete = [bool](Get-ObjectPropertyValue -Object $latestTrustedRecord -Name "pair_complete" -Default $false)
        LatestExplanation = [string](Get-ObjectPropertyValue -Object $latestTrustedRecord -Name "explanation" -Default "")
    }
}

function Get-SwitchOutputPaths {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedOutputRoot,
        [string]$ResolvedEvalRoot
    )

    if ($ResolvedPairRoot) {
        return [ordered]@{
            JsonPath = Join-Path $ResolvedPairRoot "control_to_treatment_switch.json"
            MarkdownPath = Join-Path $ResolvedPairRoot "control_to_treatment_switch.md"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedOutputRoot)) {
        $root = Ensure-Directory -Path $ResolvedOutputRoot
        return [ordered]@{
            JsonPath = Join-Path $root "control_to_treatment_switch.json"
            MarkdownPath = Join-Path $root "control_to_treatment_switch.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedEvalRoot "registry\control_to_treatment_switch")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot "control_to_treatment_switch.json"
        MarkdownPath = Join-Path $fallbackRoot "control_to_treatment_switch.md"
    }
}

function New-SwitchLaneSection {
    param(
        [string]$LaneName,
        [int]$TargetSnapshots,
        [double]$TargetSeconds,
        [int]$ActualSnapshots,
        [double]$ActualSeconds,
        [int]$TargetPatchEvents = 0,
        [int]$ActualPatchEvents = 0,
        [double]$TargetPostPatchSeconds = 0.0,
        [double]$ActualPostPatchSeconds = 0.0,
        [bool]$SafeToLeave = $false
    )

    return [ordered]@{
        lane = $LaneName
        target_human_snapshots = $TargetSnapshots
        actual_human_snapshots = $ActualSnapshots
        remaining_human_snapshots = [Math]::Max(0, $TargetSnapshots - $ActualSnapshots)
        target_human_presence_seconds = $TargetSeconds
        actual_human_presence_seconds = [Math]::Round($ActualSeconds, 2)
        remaining_human_presence_seconds = [Math]::Round([Math]::Max(0.0, $TargetSeconds - $ActualSeconds), 2)
        target_patch_while_human_present_events = $TargetPatchEvents
        actual_patch_while_human_present_events = $ActualPatchEvents
        remaining_patch_while_human_present_events = [Math]::Max(0, $TargetPatchEvents - $ActualPatchEvents)
        target_post_patch_observation_seconds = $TargetPostPatchSeconds
        actual_post_patch_observation_seconds = [Math]::Round($ActualPostPatchSeconds, 2)
        remaining_post_patch_observation_seconds = [Math]::Round([Math]::Max(0.0, $TargetPostPatchSeconds - $ActualPostPatchSeconds), 2)
        safe_to_leave = $SafeToLeave
    }
}

function Get-SwitchExplanation {
    param(
        [string]$Verdict,
        [object]$ControlLaneSection,
        [object]$TreatmentLaneSection,
        [bool]$PairComplete,
        [bool]$FreshControlHistorySeen,
        [bool]$TreatmentActivitySeen
    )

    $controlSnapshotsShort = [int](Get-ObjectPropertyValue -Object $ControlLaneSection -Name "remaining_human_snapshots" -Default 0)
    $controlSecondsShort = [double](Get-ObjectPropertyValue -Object $ControlLaneSection -Name "remaining_human_presence_seconds" -Default 0.0)
    $treatmentSnapshotsShort = [int](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_human_snapshots" -Default 0)
    $treatmentSecondsShort = [double](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_human_presence_seconds" -Default 0.0)
    $patchShort = [int](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_patch_while_human_present_events" -Default 0)
    $postPatchShort = [double](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_post_patch_observation_seconds" -Default 0.0)

    switch ($Verdict) {
        "blocked-no-active-pair" {
            return "No active or completed pair root could be resolved, so the control-to-treatment switch cannot be guided."
        }
        "stay-in-control" {
            if (-not $FreshControlHistorySeen -and -not $PairComplete) {
                return "No fresh control-lane progress has been recorded yet. Ignore any stale ready-looking state and stay in the control lane until the helper sees real control progress."
            }

            if ($TreatmentActivitySeen -and -not $PairComplete) {
                return "Control is still short by $controlSnapshotsShort snapshot(s) and $controlSecondsShort second(s), but treatment activity already appeared. The operator switched away too early; return to control if the control lane is still live."
            }

            return "Control is still short by $controlSnapshotsShort snapshot(s) and $controlSecondsShort second(s). Stay in the control lane."
        }
        "control-ready-switch-to-treatment" {
            return "Control has reached the minimum human signal threshold. It is now safe to leave control and join the treatment lane."
        }
        "stay-in-treatment-waiting-for-human-signal" {
            return "Control is safe to leave. Stay in treatment until treatment human signal clears the remaining gap of $treatmentSnapshotsShort snapshot(s) and $treatmentSecondsShort second(s)."
        }
        "stay-in-treatment-waiting-for-patch" {
            return "Treatment human signal is sufficient, but treatment still needs $patchShort more patch-while-human-present event(s) before the grounded bar is cleared."
        }
        "stay-in-treatment-waiting-for-post-patch-window" {
            return "Treatment already patched while humans were present. Stay in treatment until the post-patch observation window grows by another $postPatchShort second(s)."
        }
        "sufficient-for-grounded-closeout" {
            return "Control and treatment have both cleared the grounded human-signal thresholds, treatment patched while humans were present, and the post-patch observation window is sufficient."
        }
        "insufficient-timeout" {
            if ($controlSnapshotsShort -gt 0 -or $controlSecondsShort -gt 0) {
                return "The pair is already complete, but control was still short by $controlSnapshotsShort snapshot(s) and $controlSecondsShort second(s). This run stayed non-grounded because control was left too early or never cleared the minimum."
            }

            if ($treatmentSnapshotsShort -gt 0 -or $treatmentSecondsShort -gt 0) {
                return "The pair is already complete, but treatment stayed short by $treatmentSnapshotsShort snapshot(s) and $treatmentSecondsShort second(s). This run stayed non-grounded."
            }

            if ($patchShort -gt 0) {
                return "The pair is already complete, but treatment still missed $patchShort patch-while-human-present event(s). This run stayed non-grounded."
            }

            if ($postPatchShort -gt 0) {
                return "The pair is already complete, but the meaningful post-patch observation window was still short by $postPatchShort second(s). This run stayed non-grounded."
            }

            return "The pair is already complete, but the grounded closeout bar was not cleared."
        }
        default {
            return "Control-first switch guidance is unavailable."
        }
    }
}

function Get-SwitchMarkdown {
    param([object]$Report)

    $controlLane = Get-ObjectPropertyValue -Object $Report -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $Report -Name "treatment_lane" -Default $null

    $lines = @(
        "# Control To Treatment Switch Guidance",
        "",
        "- Current switch verdict: $($Report.current_switch_verdict)",
        "- Explanation: $($Report.explanation)",
        "- Pair root: $($Report.pair_root)",
        "- Pair complete: $($Report.pair_complete)",
        "- Mission path used: $($Report.mission_path_used)",
        "- Mission source kind: $($Report.mission_source_kind)",
        "- Treatment profile: $($Report.treatment_profile)",
        "- Monitor phase hint: $($Report.monitor_phase)",
        "",
        "## Control Lane",
        "",
        "- Human snapshots: $($controlLane.actual_human_snapshots) / $($controlLane.target_human_snapshots)",
        "- Human presence seconds: $($controlLane.actual_human_presence_seconds) / $($controlLane.target_human_presence_seconds)",
        "- Remaining human snapshots: $($controlLane.remaining_human_snapshots)",
        "- Remaining human presence seconds: $($controlLane.remaining_human_presence_seconds)",
        "- Safe to leave control: $($controlLane.safe_to_leave)",
        "",
        "## Treatment Lane",
        "",
        "- Human snapshots: $($treatmentLane.actual_human_snapshots) / $($treatmentLane.target_human_snapshots)",
        "- Human presence seconds: $($treatmentLane.actual_human_presence_seconds) / $($treatmentLane.target_human_presence_seconds)",
        "- Patch while human present events: $($treatmentLane.actual_patch_while_human_present_events) / $($treatmentLane.target_patch_while_human_present_events)",
        "- Post-patch observation seconds: $($treatmentLane.actual_post_patch_observation_seconds) / $($treatmentLane.target_post_patch_observation_seconds)",
        "",
        "## Artifacts",
        "",
        "- JSON: $($Report.artifacts.control_to_treatment_switch_json)",
        "- Markdown: $($Report.artifacts.control_to_treatment_switch_markdown)",
        "- Mission execution: $($Report.artifacts.mission_execution_json)",
        "- Mission snapshot: $($Report.artifacts.mission_snapshot_json)",
        "- Pair summary: $($Report.artifacts.pair_summary_json)",
        "- Monitor status: $($Report.artifacts.live_monitor_status_json)",
        "- Monitor history: $($Report.artifacts.monitor_verdict_history_ndjson)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-SwitchStatus {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedEvalRoot,
        [string]$ResolvedOutputRoot,
        [object]$MissionContext
    )

    $outputPaths = Get-SwitchOutputPaths -ResolvedPairRoot $ResolvedPairRoot -ResolvedOutputRoot $ResolvedOutputRoot -ResolvedEvalRoot $ResolvedEvalRoot
    if (-not $ResolvedPairRoot) {
        $blockedReport = [ordered]@{
            schema_version = 1
            prompt_id = Get-RepoPromptId
            generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
            source_commit_sha = Get-RepoHeadCommitSha
            pair_root = ""
            pair_complete = $false
            mission_path_used = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "MissionPath" -Default "")
            mission_source_kind = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "SourceKind" -Default "")
            treatment_profile = "conservative"
            monitor_phase = "blocked"
            current_switch_verdict = "blocked-no-active-pair"
            explanation = "No active or completed pair root could be resolved."
            control_lane = New-SwitchLaneSection -LaneName "control" -TargetSnapshots 0 -TargetSeconds 0 -ActualSnapshots 0 -ActualSeconds 0 -SafeToLeave $false
            treatment_lane = New-SwitchLaneSection -LaneName "treatment" -TargetSnapshots 0 -TargetSeconds 0 -ActualSnapshots 0 -ActualSeconds 0 -TargetPatchEvents 0 -ActualPatchEvents 0 -TargetPostPatchSeconds 0 -ActualPostPatchSeconds 0 -SafeToLeave $false
            fresh_control_history_seen = $false
            treatment_activity_seen = $false
            artifacts = [ordered]@{
                control_to_treatment_switch_json = $outputPaths.JsonPath
                control_to_treatment_switch_markdown = $outputPaths.MarkdownPath
                mission_execution_json = ""
                mission_snapshot_json = ""
                pair_summary_json = ""
                live_monitor_status_json = ""
                monitor_verdict_history_ndjson = ""
                control_join_instructions = ""
                treatment_join_instructions = ""
            }
        }

        return [pscustomobject]$blockedReport
    }

    $pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    $controlSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "summary_json" -Default ""))
    $treatmentSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "summary_json" -Default ""))

    if (-not $controlSummaryPath) {
        $controlSummaryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "lanes\control\summary.json")
    }
    if (-not $treatmentSummaryPath) {
        $treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "lanes\treatment\summary.json")
    }

    $controlSummary = Read-LaneSummaryFile -Path $controlSummaryPath
    $treatmentSummary = Read-LaneSummaryFile -Path $treatmentSummaryPath
    $comparison = Read-JsonFile -Path (Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "comparison.json"))
    $missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission_execution.json")
    $missionExecution = Read-JsonFile -Path $missionExecutionPath
    $liveMonitorStatusPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "live_monitor_status.json")
    $monitorHistoryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\monitor_verdict_history.ndjson")
    $monitorHistory = Read-NdjsonFile -Path $monitorHistoryPath

    $thresholds = Resolve-Thresholds `
        -PairSummary $pairSummary `
        -ControlSummary $controlSummary `
        -TreatmentSummary $treatmentSummary `
        -Mission (Get-ObjectPropertyValue -Object $MissionContext -Name "Mission" -Default $null) `
        -MissionExecution $missionExecution

    $historyProgress = Get-HistoryProgress `
        -HistoryRecords $monitorHistory `
        -ControlTargetSnapshots $thresholds.ControlHumanSnapshots `
        -ControlTargetSeconds $thresholds.ControlHumanPresenceSeconds

    $pairComplete = $null -ne $pairSummary -or [bool](Get-ObjectPropertyValue -Object $historyProgress -Name "PairComplete" -Default $false)
    $treatmentProfile = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default (Get-ObjectPropertyValue -Object $treatmentSummary -Name "tuning_profile" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $MissionContext -Name "Mission" -Default $null) -Name "current_default_live_treatment_profile" -Default "conservative")))

    if ($pairComplete) {
        $controlActualSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "human_snapshots_count" -Default (Get-ObjectPropertyValue -Object $controlSummary -Name "human_snapshots_count" -Default 0))
        $controlActualSeconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "seconds_with_human_presence" -Default (Get-ObjectPropertyValue -Object $controlSummary -Name "seconds_with_human_presence" -Default 0.0))
        $treatmentActualSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "human_snapshots_count" -Default (Get-ObjectPropertyValue -Object $treatmentSummary -Name "human_snapshots_count" -Default 0))
        $treatmentActualSeconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "seconds_with_human_presence" -Default (Get-ObjectPropertyValue -Object $treatmentSummary -Name "seconds_with_human_presence" -Default 0.0))
        $patchActual = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_events_while_humans_present_count" -Default (Get-ObjectPropertyValue -Object $historyProgress -Name "PatchEventsMax" -Default 0))
        if ($patchActual -lt 1 -and [bool](Get-ObjectPropertyValue -Object $comparison -Name "treatment_patched_while_humans_present" -Default $false)) {
            $patchActual = 1
        }

        $postPatchActual = [double](Get-ObjectPropertyValue -Object $historyProgress -Name "PostPatchSecondsMax" -Default 0.0)
        if ($postPatchActual -lt 0.01 -and [bool](Get-ObjectPropertyValue -Object $treatmentSummary -Name "meaningful_post_patch_observation_window_exists" -Default $false)) {
            $postPatchActual = $thresholds.PostPatchObservationSeconds
        }
    }
    else {
        $controlActualSnapshots = [int](Get-ObjectPropertyValue -Object $historyProgress -Name "ControlMaxSnapshots" -Default 0)
        $controlActualSeconds = [double](Get-ObjectPropertyValue -Object $historyProgress -Name "ControlMaxSeconds" -Default 0.0)
        $treatmentActualSnapshots = [int](Get-ObjectPropertyValue -Object $historyProgress -Name "TreatmentMaxSnapshots" -Default 0)
        $treatmentActualSeconds = [double](Get-ObjectPropertyValue -Object $historyProgress -Name "TreatmentMaxSeconds" -Default 0.0)
        $patchActual = [int](Get-ObjectPropertyValue -Object $historyProgress -Name "PatchEventsMax" -Default 0)
        $postPatchActual = [double](Get-ObjectPropertyValue -Object $historyProgress -Name "PostPatchSecondsMax" -Default 0.0)
    }

    $controlReady = $controlActualSnapshots -ge $thresholds.ControlHumanSnapshots -and $controlActualSeconds -ge $thresholds.ControlHumanPresenceSeconds
    $treatmentReady = $treatmentActualSnapshots -ge $thresholds.TreatmentHumanSnapshots -and $treatmentActualSeconds -ge $thresholds.TreatmentHumanPresenceSeconds
    $patchReady = $patchActual -ge $thresholds.TreatmentPatchWhileHumanPresentEvents
    $postPatchReady = $postPatchActual -ge $thresholds.PostPatchObservationSeconds
    $freshControlHistorySeen = [bool](Get-ObjectPropertyValue -Object $historyProgress -Name "HasFreshControlHistory" -Default $false)
    $treatmentActivitySeen = $treatmentActualSnapshots -gt 0 -or $treatmentActualSeconds -gt 0.0 -or $patchActual -gt 0 -or $postPatchActual -gt 0.0

    if ($pairComplete) {
        if ($controlReady -and $treatmentReady -and $patchReady -and $postPatchReady) {
            $verdict = "sufficient-for-grounded-closeout"
        }
        else {
            $verdict = "insufficient-timeout"
        }
    }
    else {
        if (-not $controlReady) {
            $verdict = "stay-in-control"
        }
        elseif (-not $treatmentReady) {
            if ($treatmentActivitySeen) {
                $verdict = "stay-in-treatment-waiting-for-human-signal"
            }
            else {
                $verdict = "control-ready-switch-to-treatment"
            }
        }
        elseif (-not $patchReady) {
            $verdict = "stay-in-treatment-waiting-for-patch"
        }
        elseif (-not $postPatchReady) {
            $verdict = "stay-in-treatment-waiting-for-post-patch-window"
        }
        else {
            $verdict = "sufficient-for-grounded-closeout"
        }
    }

    $controlLaneSection = New-SwitchLaneSection `
        -LaneName "control" `
        -TargetSnapshots $thresholds.ControlHumanSnapshots `
        -TargetSeconds $thresholds.ControlHumanPresenceSeconds `
        -ActualSnapshots $controlActualSnapshots `
        -ActualSeconds $controlActualSeconds `
        -SafeToLeave $controlReady
    $treatmentLaneSection = New-SwitchLaneSection `
        -LaneName "treatment" `
        -TargetSnapshots $thresholds.TreatmentHumanSnapshots `
        -TargetSeconds $thresholds.TreatmentHumanPresenceSeconds `
        -ActualSnapshots $treatmentActualSnapshots `
        -ActualSeconds $treatmentActualSeconds `
        -TargetPatchEvents $thresholds.TreatmentPatchWhileHumanPresentEvents `
        -ActualPatchEvents $patchActual `
        -TargetPostPatchSeconds $thresholds.PostPatchObservationSeconds `
        -ActualPostPatchSeconds $postPatchActual `
        -SafeToLeave ($controlReady -and $treatmentReady -and $patchReady -and $postPatchReady)

    $explanation = Get-SwitchExplanation `
        -Verdict $verdict `
        -ControlLaneSection $controlLaneSection `
        -TreatmentLaneSection $treatmentLaneSection `
        -PairComplete $pairComplete `
        -FreshControlHistorySeen $freshControlHistorySeen `
        -TreatmentActivitySeen $treatmentActivitySeen

    return [pscustomobject]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $ResolvedPairRoot
        pair_complete = $pairComplete
        mission_path_used = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "MissionPath" -Default "")
        mission_source_kind = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "SourceKind" -Default "")
        treatment_profile = $treatmentProfile
        monitor_phase = if ($pairComplete) { "pair-complete" } else { [string](Get-ObjectPropertyValue -Object $historyProgress -Name "LatestPhase" -Default "control-live") }
        current_switch_verdict = $verdict
        explanation = $explanation
        control_lane = $controlLaneSection
        treatment_lane = $treatmentLaneSection
        fresh_control_history_seen = $freshControlHistorySeen
        treatment_activity_seen = $treatmentActivitySeen
        artifacts = [ordered]@{
            control_to_treatment_switch_json = $outputPaths.JsonPath
            control_to_treatment_switch_markdown = $outputPaths.MarkdownPath
            mission_execution_json = $missionExecutionPath
            mission_snapshot_json = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "MissionSnapshotPath" -Default "")
            pair_summary_json = $pairSummaryPath
            live_monitor_status_json = $liveMonitorStatusPath
            monitor_verdict_history_ndjson = $monitorHistoryPath
            control_join_instructions = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "control_join_instructions.txt")
            treatment_join_instructions = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "treatment_join_instructions.txt")
        }
    }
}

if ($PollSeconds -lt 1) {
    throw "PollSeconds must be at least 1."
}

$repoRoot = Get-RepoRoot
$resolvedEvalRoot = Get-ResolvedEvalRoot -ExplicitLabRoot $LabRoot -ExplicitEvalRoot $EvalRoot
$resolvedPairsRoot = if (-not [string]::IsNullOrWhiteSpace($PairsRoot)) {
    Ensure-Directory -Path (Get-AbsolutePath -Path $PairsRoot)
}
else {
    Ensure-Directory -Path (Get-PairsRootDefault -LabRoot $(if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot }))
}
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    ""
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
$resolvedPairRoot = Resolve-PairRootForSwitchGuide -ExplicitPairRoot $PairRoot -ShouldUseLatest:($UseLatest -or [string]::IsNullOrWhiteSpace($PairRoot)) -ResolvedEvalRoot $resolvedEvalRoot -ResolvedPairsRoot $resolvedPairsRoot
$missionContext = Resolve-MissionContext -ExplicitMissionPath $MissionPath -ResolvedPairRoot $resolvedPairRoot -ResolvedEvalRoot $resolvedEvalRoot
$lastPrintedKey = ""
$latestStatus = $null

while ($true) {
    $status = Get-SwitchStatus -ResolvedPairRoot $resolvedPairRoot -ResolvedEvalRoot $resolvedEvalRoot -ResolvedOutputRoot $resolvedOutputRoot -MissionContext $missionContext
    Write-JsonFile -Path $status.artifacts.control_to_treatment_switch_json -Value $status
    $statusForMarkdown = Read-JsonFile -Path $status.artifacts.control_to_treatment_switch_json
    Write-TextFile -Path $status.artifacts.control_to_treatment_switch_markdown -Value (Get-SwitchMarkdown -Report $statusForMarkdown)

    $printKey = @(
        [string]$status.current_switch_verdict
        [string](Get-ObjectPropertyValue -Object $status.control_lane -Name "actual_human_snapshots" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.control_lane -Name "actual_human_presence_seconds" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_human_snapshots" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_human_presence_seconds" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_patch_while_human_present_events" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_post_patch_observation_seconds" -Default 0)
    ) -join "|"

    if ($printKey -ne $lastPrintedKey -or $Once) {
        Write-Host "Control-first switch guidance:"
        Write-Host "  Pair root: $($status.pair_root)"
        Write-Host "  Verdict: $($status.current_switch_verdict)"
        Write-Host "  Control snapshots / seconds: $($status.control_lane.actual_human_snapshots) / $($status.control_lane.actual_human_presence_seconds)"
        Write-Host "  Control remaining snapshots / seconds: $($status.control_lane.remaining_human_snapshots) / $($status.control_lane.remaining_human_presence_seconds)"
        Write-Host "  Treatment snapshots / seconds: $($status.treatment_lane.actual_human_snapshots) / $($status.treatment_lane.actual_human_presence_seconds)"
        Write-Host "  Treatment patch events / post-patch seconds: $($status.treatment_lane.actual_patch_while_human_present_events) / $($status.treatment_lane.actual_post_patch_observation_seconds)"
        Write-Host "  Safe to leave control: $($status.control_lane.safe_to_leave)"
        Write-Host "  Explanation: $($status.explanation)"
        Write-Host "  JSON: $($status.artifacts.control_to_treatment_switch_json)"
        Write-Host "  Markdown: $($status.artifacts.control_to_treatment_switch_markdown)"
        $lastPrintedKey = $printKey
    }

    $latestStatus = $status

    if ($Once) {
        break
    }

    if ($status.current_switch_verdict -in @("blocked-no-active-pair", "insufficient-timeout", "sufficient-for-grounded-closeout")) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
}

$latestStatus
