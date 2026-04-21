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

function Invoke-ControlSwitchGuide {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ExplicitMissionPath,
        [int]$RequestedPollSeconds,
        [string]$ExplicitLabRoot,
        [string]$ExplicitEvalRoot,
        [string]$ExplicitPairsRoot
    )

    $guideScriptPath = Join-Path $PSScriptRoot "guide_control_to_treatment_switch.ps1"
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\guide_control_to_treatment_switch.ps1",
        "-Once",
        "-PollSeconds",
        [string]$RequestedPollSeconds
    )
    $guideArgs = [ordered]@{
        Once = $true
        PollSeconds = $RequestedPollSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        $commandParts += @("-PairRoot", $ExplicitPairRoot)
        $guideArgs.PairRoot = $ExplicitPairRoot
    }
    elseif ($ShouldUseLatest) {
        $commandParts += "-UseLatest"
        $guideArgs.UseLatest = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $commandParts += @("-MissionPath", $ExplicitMissionPath)
        $guideArgs.MissionPath = $ExplicitMissionPath
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
        $commandParts += @("-LabRoot", $ExplicitLabRoot)
        $guideArgs.LabRoot = $ExplicitLabRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        $commandParts += @("-EvalRoot", $ExplicitEvalRoot)
        $guideArgs.EvalRoot = $ExplicitEvalRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairsRoot)) {
        $commandParts += @("-PairsRoot", $ExplicitPairsRoot)
        $guideArgs.PairsRoot = $ExplicitPairsRoot
    }

    $commandText = @($commandParts | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "

    try {
        $result = & $guideScriptPath @guideArgs
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = ""
            Result = $result
        }
    }
    catch {
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = $_.Exception.Message
            Result = $null
        }
    }
}

function Get-TreatmentOutputPaths {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedOutputRoot,
        [string]$ResolvedEvalRoot
    )

    if ($ResolvedPairRoot) {
        return [ordered]@{
            JsonPath = Join-Path $ResolvedPairRoot "treatment_patch_window.json"
            MarkdownPath = Join-Path $ResolvedPairRoot "treatment_patch_window.md"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedOutputRoot)) {
        $root = Ensure-Directory -Path $ResolvedOutputRoot
        return [ordered]@{
            JsonPath = Join-Path $root "treatment_patch_window.json"
            MarkdownPath = Join-Path $root "treatment_patch_window.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedEvalRoot "registry\treatment_patch_window")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot "treatment_patch_window.json"
        MarkdownPath = Join-Path $fallbackRoot "treatment_patch_window.md"
    }
}

function Get-TreatmentLaneArtifacts {
    param(
        [string]$ResolvedPairRoot,
        [object]$PairSummary
    )

    $treatmentLane = Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null
    $laneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_root" -Default ""))

    if (-not $laneRoot) {
        $treatmentRoot = Join-Path $ResolvedPairRoot "lanes\treatment"
        if (Test-Path -LiteralPath $treatmentRoot) {
            $candidate = Get-ChildItem -LiteralPath $treatmentRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($null -ne $candidate) {
                $laneRoot = $candidate.FullName
            }
        }
    }

    $summaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "summary_json" -Default ""))
    if (-not $summaryPath -and $laneRoot) {
        $summaryPath = Resolve-ExistingPath -Path (Join-Path $laneRoot "summary.json")
    }

    return [pscustomobject]@{
        LaneRoot = $laneRoot
        SummaryPath = $summaryPath
        PatchHistoryPath = if ($laneRoot) { Resolve-ExistingPath -Path (Join-Path $laneRoot "patch_history.ndjson") } else { "" }
        PatchApplyHistoryPath = if ($laneRoot) { Resolve-ExistingPath -Path (Join-Path $laneRoot "patch_apply_history.ndjson") } else { "" }
        HumanPresenceTimelinePath = if ($laneRoot) { Resolve-ExistingPath -Path (Join-Path $laneRoot "human_presence_timeline.ndjson") } else { "" }
    }
}

function Get-FirstHumanPresentPatchEvidence {
    param(
        [object]$TreatmentSummary,
        [string]$PatchHistoryPath,
        [string]$PatchApplyHistoryPath
    )

    $patchHistory = Read-NdjsonFile -Path $PatchHistoryPath
    $patchApplyHistory = Read-NdjsonFile -Path $PatchApplyHistoryPath

    $firstCountedPatch = $patchHistory |
        Where-Object {
            [bool](Get-ObjectPropertyValue -Object $_ -Name "emitted" -Default $false) -and
            [int](Get-ObjectPropertyValue -Object $_ -Name "current_human_player_count" -Default 0) -gt 0
        } |
        Select-Object -First 1

    $firstHumanSeenServerTime = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "first_human_seen_server_time_seconds" -Default -1.0)
    $lastHumanSeenServerTime = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)
    $firstPatchApplyDuringPresence = $patchApplyHistory |
        Where-Object {
            $serverTime = [double](Get-ObjectPropertyValue -Object $_ -Name "server_time_seconds" -Default -1.0)
            $serverTime -ge 0.0 -and
            $firstHumanSeenServerTime -ge 0.0 -and
            $lastHumanSeenServerTime -ge $firstHumanSeenServerTime -and
            $serverTime -ge $firstHumanSeenServerTime -and
            $serverTime -le $lastHumanSeenServerTime
        } |
        Select-Object -First 1

    $patchApplyCountWhileHumansPresent = [int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "patch_apply_count_while_humans_present" -Default 0)
    $patchEventCountWhileHumansPresent = [int](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "patch_events_while_humans_present_count" -Default 0)
    $preferPatchApplySource = $patchApplyCountWhileHumansPresent -gt $patchEventCountWhileHumansPresent -and $null -ne $firstPatchApplyDuringPresence

    $sourceKind = if ($preferPatchApplySource) {
        "patch-apply-during-human-window"
    }
    elseif ($null -ne $firstCountedPatch) {
        "counted-patch-event"
    }
    elseif ($null -ne $firstPatchApplyDuringPresence) {
        "patch-apply-during-human-window"
    }
    else {
        "none"
    }

    $firstHumanPresentPatchTimestampUtc = if ($preferPatchApplySource -and $null -ne $firstPatchApplyDuringPresence) {
        [string](Get-ObjectPropertyValue -Object $firstPatchApplyDuringPresence -Name "timestamp_utc" -Default "")
    }
    else {
        [string](Get-ObjectPropertyValue -Object $firstCountedPatch -Name "timestamp_utc" -Default "")
    }

    $firstHumanPresentPatchOffsetSeconds = if ($preferPatchApplySource -and $null -ne $firstPatchApplyDuringPresence) {
        [double](Get-ObjectPropertyValue -Object $firstPatchApplyDuringPresence -Name "server_time_seconds" -Default 0.0)
    }
    else {
        [double](Get-ObjectPropertyValue -Object $firstCountedPatch -Name "server_time_seconds" -Default 0.0)
    }

    return [pscustomobject]@{
        SourceKind = $sourceKind
        FirstCountedPatchTimestampUtc = $firstHumanPresentPatchTimestampUtc
        FirstCountedPatchOffsetSeconds = $firstHumanPresentPatchOffsetSeconds
        FirstPatchApplyDuringHumanWindowTimestampUtc = [string](Get-ObjectPropertyValue -Object $firstPatchApplyDuringPresence -Name "timestamp_utc" -Default "")
        FirstPatchApplyDuringHumanWindowOffsetSeconds = [double](Get-ObjectPropertyValue -Object $firstPatchApplyDuringPresence -Name "server_time_seconds" -Default 0.0)
    }
}

function New-TreatmentLaneSection {
    param(
        [int]$TargetSnapshots,
        [double]$TargetSeconds,
        [int]$ActualSnapshots,
        [double]$ActualSeconds,
        [int]$TargetPatchEvents,
        [int]$ActualPatchEvents,
        [double]$TargetPostPatchSeconds,
        [double]$ActualPostPatchSeconds,
        [object]$PatchEvidence,
        [bool]$SafeToLeave
    )

    return [ordered]@{
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
        first_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $PatchEvidence -Name "FirstCountedPatchTimestampUtc" -Default "")
        first_human_present_patch_offset_seconds = [double](Get-ObjectPropertyValue -Object $PatchEvidence -Name "FirstCountedPatchOffsetSeconds" -Default 0.0)
        first_human_present_patch_source = [string](Get-ObjectPropertyValue -Object $PatchEvidence -Name "SourceKind" -Default "none")
        first_patch_apply_during_human_window_timestamp_utc = [string](Get-ObjectPropertyValue -Object $PatchEvidence -Name "FirstPatchApplyDuringHumanWindowTimestampUtc" -Default "")
        first_patch_apply_during_human_window_offset_seconds = [double](Get-ObjectPropertyValue -Object $PatchEvidence -Name "FirstPatchApplyDuringHumanWindowOffsetSeconds" -Default 0.0)
        safe_to_leave = $SafeToLeave
        grounded_ready = $SafeToLeave
    }
}

function Get-TreatmentVerdict {
    param(
        [bool]$PairComplete,
        [bool]$TreatmentReady,
        [bool]$PatchReady,
        [bool]$PostPatchReady
    )

    if ($PairComplete) {
        if ($TreatmentReady -and $PatchReady -and $PostPatchReady) {
            return "treatment-grounded-ready"
        }

        return "insufficient-timeout"
    }

    if (-not $TreatmentReady) {
        return "stay-in-treatment-waiting-for-human-signal"
    }

    if (-not $PatchReady) {
        return "stay-in-treatment-waiting-for-patch-while-humans-present"
    }

    if (-not $PostPatchReady) {
        return "stay-in-treatment-waiting-for-post-patch-window"
    }

    return "treatment-grounded-ready"
}

function Get-TreatmentExplanation {
    param(
        [string]$Verdict,
        [object]$TreatmentLaneSection,
        [bool]$PairComplete,
        [bool]$ControlPreconditionReady
    )

    $snapshotsShort = [int](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_human_snapshots" -Default 0)
    $secondsShort = [double](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_human_presence_seconds" -Default 0.0)
    $patchShort = [int](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_patch_while_human_present_events" -Default 0)
    $postPatchShort = [double](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "remaining_post_patch_observation_seconds" -Default 0.0)
    $countedPatchStamp = [string](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "first_human_present_patch_timestamp_utc" -Default "")
    $patchSource = [string](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "first_human_present_patch_source" -Default "none")
    $patchApplyStamp = [string](Get-ObjectPropertyValue -Object $TreatmentLaneSection -Name "first_patch_apply_during_human_window_timestamp_utc" -Default "")

    switch ($Verdict) {
        "blocked-no-active-pair" {
            return "No active or completed pair root could be resolved, so treatment-hold guidance cannot be produced."
        }
        "stay-in-treatment-waiting-for-human-signal" {
            if (-not $ControlPreconditionReady) {
                return "Treatment-side guidance started before the control handoff was really safe. Control should still clear first, and treatment is also short by $snapshotsShort snapshot(s) and $secondsShort second(s)."
            }

            return "Treatment is still short by $snapshotsShort snapshot(s) and $secondsShort second(s). Stay in treatment."
        }
        "stay-in-treatment-waiting-for-patch-while-humans-present" {
            if ($patchSource -eq "patch-apply-during-human-window" -and $patchApplyStamp) {
                return "Treatment human signal is sufficient, but counted patch-while-human-present events are still short by $patchShort. A patch was applied during the human window at $patchApplyStamp, but the grounded event counter still did not record a human-present patch recommendation."
            }

            if ($countedPatchStamp) {
                return "Treatment already recorded a human-present patch at $countedPatchStamp, but it still needs $patchShort more counted patch-while-human-present event(s)."
            }

            return "Treatment human signal is sufficient, but treatment still needs $patchShort more patch-while-human-present event(s) before it is safe to leave."
        }
        "stay-in-treatment-waiting-for-post-patch-window" {
            return "Treatment already recorded the required human-present patch event(s). Stay in treatment until the post-patch observation window grows by another $postPatchShort second(s)."
        }
        "treatment-grounded-ready" {
            return "Treatment has cleared the human-signal threshold, the required human-present patch event(s) were recorded, and the post-patch observation window is sufficient. It is now safe to leave treatment."
        }
        "insufficient-timeout" {
            if ($snapshotsShort -gt 0 -or $secondsShort -gt 0) {
                return "The pair is already complete, but treatment stayed short by $snapshotsShort snapshot(s) and $secondsShort second(s). This run stayed non-grounded."
            }

            if ($patchShort -gt 0) {
                if ($patchSource -eq "patch-apply-during-human-window" -and $patchApplyStamp) {
                    return "The pair is already complete, but treatment still missed $patchShort counted patch-while-human-present event(s). A patch was applied during the human window at $patchApplyStamp, but the grounded patch recommendation still happened before human participation counted."
                }

                return "The pair is already complete, but treatment still missed $patchShort patch-while-human-present event(s). This run stayed non-grounded."
            }

            if ($postPatchShort -gt 0) {
                return "The pair is already complete, but the treatment post-patch observation window was still short by $postPatchShort second(s). This run stayed non-grounded."
            }

            return "The pair is already complete, but the treatment-side grounded evidence bar was not cleared."
        }
        default {
            return "Treatment-hold guidance is unavailable."
        }
    }
}

function Get-TreatmentMarkdown {
    param([object]$Report)

    $treatmentLane = Get-ObjectPropertyValue -Object $Report -Name "treatment_lane" -Default $null

    $lines = @(
        "# Treatment Patch Window Guidance",
        "",
        "- Current verdict: $($Report.current_verdict)",
        "- Explanation: $($Report.explanation)",
        "- Pair root: $($Report.pair_root)",
        "- Pair complete: $($Report.pair_complete)",
        "- Mission path used: $($Report.mission_path_used)",
        "- Mission source kind: $($Report.mission_source_kind)",
        "- Treatment profile: $($Report.treatment_profile)",
        "- Monitor phase hint: $($Report.monitor_phase)",
        "- Control precondition ready: $($Report.control_precondition_ready)",
        "- Safe to leave treatment: $($Report.treatment_safe_to_leave)",
        "- Grounded-ready on treatment side: $($Report.treatment_grounded_ready)",
        "",
        "## Treatment Lane",
        "",
        "- Human snapshots: $($treatmentLane.actual_human_snapshots) / $($treatmentLane.target_human_snapshots)",
        "- Human presence seconds: $($treatmentLane.actual_human_presence_seconds) / $($treatmentLane.target_human_presence_seconds)",
        "- Patch while human present events: $($treatmentLane.actual_patch_while_human_present_events) / $($treatmentLane.target_patch_while_human_present_events)",
        "- Post-patch observation seconds: $($treatmentLane.actual_post_patch_observation_seconds) / $($treatmentLane.target_post_patch_observation_seconds)",
        "- First counted human-present patch timestamp: $($treatmentLane.first_human_present_patch_timestamp_utc)",
        "- First counted human-present patch offset seconds: $($treatmentLane.first_human_present_patch_offset_seconds)",
        "- First human-window patch source: $($treatmentLane.first_human_present_patch_source)",
        "- First patch apply during human window timestamp: $($treatmentLane.first_patch_apply_during_human_window_timestamp_utc)",
        "- First patch apply during human window offset seconds: $($treatmentLane.first_patch_apply_during_human_window_offset_seconds)",
        "",
        "## Artifacts",
        "",
        "- JSON: $($Report.artifacts.treatment_patch_window_json)",
        "- Markdown: $($Report.artifacts.treatment_patch_window_markdown)",
        "- Control-first switch JSON: $($Report.artifacts.control_to_treatment_switch_json)",
        "- Pair summary: $($Report.artifacts.pair_summary_json)",
        "- Treatment summary: $($Report.artifacts.treatment_summary_json)",
        "- Patch history: $($Report.artifacts.patch_history_ndjson)",
        "- Patch apply history: $($Report.artifacts.patch_apply_history_ndjson)",
        "- Human presence timeline: $($Report.artifacts.human_presence_timeline_ndjson)",
        "- Live monitor status: $($Report.artifacts.live_monitor_status_json)",
        "- Monitor history: $($Report.artifacts.monitor_verdict_history_ndjson)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-TreatmentStatus {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ExplicitMissionPath,
        [int]$RequestedPollSeconds,
        [string]$ExplicitLabRoot,
        [string]$ExplicitEvalRoot,
        [string]$ExplicitPairsRoot,
        [string]$ResolvedOutputRoot
    )

    $resolvedEvalRoot = if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitEvalRoot)
    }
    else {
        $labRoot = if ([string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
            Ensure-Directory -Path (Get-LabRootDefault)
        }
        else {
            Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitLabRoot)
        }

        Ensure-Directory -Path (Get-EvalRootDefault -LabRoot $labRoot)
    }

    $controlGuideExecution = Invoke-ControlSwitchGuide `
        -ExplicitPairRoot $ExplicitPairRoot `
        -ShouldUseLatest:$ShouldUseLatest `
        -ExplicitMissionPath $ExplicitMissionPath `
        -RequestedPollSeconds $RequestedPollSeconds `
        -ExplicitLabRoot $ExplicitLabRoot `
        -ExplicitEvalRoot $ExplicitEvalRoot `
        -ExplicitPairsRoot $ExplicitPairsRoot

    $controlGuideReport = Get-ObjectPropertyValue -Object $controlGuideExecution -Name "Result" -Default $null
    $controlGuideArtifacts = Get-ObjectPropertyValue -Object $controlGuideReport -Name "artifacts" -Default $null
    $resolvedPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "pair_root" -Default ""))
    $outputPaths = Get-TreatmentOutputPaths -ResolvedPairRoot $resolvedPairRoot -ResolvedOutputRoot $ResolvedOutputRoot -ResolvedEvalRoot $resolvedEvalRoot

    if ($null -eq $controlGuideReport -or -not $resolvedPairRoot) {
        $blockedReport = [ordered]@{
            schema_version = 1
            prompt_id = Get-RepoPromptId
            generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
            source_commit_sha = Get-RepoHeadCommitSha
            pair_root = ""
            pair_complete = $false
            mission_path_used = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "mission_path_used" -Default "")
            mission_source_kind = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "mission_source_kind" -Default "")
            treatment_profile = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "treatment_profile" -Default "conservative")
            monitor_phase = "blocked"
            control_precondition_ready = $false
            treatment_safe_to_leave = $false
            treatment_grounded_ready = $false
            current_verdict = "blocked-no-active-pair"
            explanation = if ($controlGuideExecution.Error) { $controlGuideExecution.Error } else { "No active or completed pair root could be resolved." }
            treatment_lane = New-TreatmentLaneSection -TargetSnapshots 0 -TargetSeconds 0 -ActualSnapshots 0 -ActualSeconds 0 -TargetPatchEvents 0 -ActualPatchEvents 0 -TargetPostPatchSeconds 0 -ActualPostPatchSeconds 0 -PatchEvidence $null -SafeToLeave $false
            artifacts = [ordered]@{
                treatment_patch_window_json = $outputPaths.JsonPath
                treatment_patch_window_markdown = $outputPaths.MarkdownPath
                control_to_treatment_switch_json = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "control_to_treatment_switch_json" -Default "")
                control_to_treatment_switch_markdown = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "control_to_treatment_switch_markdown" -Default "")
                pair_summary_json = ""
                treatment_summary_json = ""
                patch_history_ndjson = ""
                patch_apply_history_ndjson = ""
                human_presence_timeline_ndjson = ""
                live_monitor_status_json = ""
                monitor_verdict_history_ndjson = ""
                control_join_instructions = ""
                treatment_join_instructions = ""
            }
        }

        return [pscustomobject]$blockedReport
    }

    $pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    $laneArtifacts = Get-TreatmentLaneArtifacts -ResolvedPairRoot $resolvedPairRoot -PairSummary $pairSummary
    $treatmentSummary = Read-LaneSummaryFile -Path $laneArtifacts.SummaryPath
    $treatmentLaneFromControl = Get-ObjectPropertyValue -Object $controlGuideReport -Name "treatment_lane" -Default $null
    $controlLaneFromControl = Get-ObjectPropertyValue -Object $controlGuideReport -Name "control_lane" -Default $null
    $patchEvidence = Get-FirstHumanPresentPatchEvidence -TreatmentSummary $treatmentSummary -PatchHistoryPath $laneArtifacts.PatchHistoryPath -PatchApplyHistoryPath $laneArtifacts.PatchApplyHistoryPath

    $targetSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "target_human_snapshots" -Default 0)
    $actualSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "actual_human_snapshots" -Default 0)
    $targetSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "target_human_presence_seconds" -Default 0.0)
    $actualSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "actual_human_presence_seconds" -Default 0.0)
    $targetPatchEvents = [int](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "target_patch_while_human_present_events" -Default 0)
    $actualPatchEvents = [int](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "actual_patch_while_human_present_events" -Default 0)
    $targetPostPatchSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "target_post_patch_observation_seconds" -Default 0.0)
    $actualPostPatchSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLaneFromControl -Name "actual_post_patch_observation_seconds" -Default 0.0)

    $pairComplete = [bool](Get-ObjectPropertyValue -Object $controlGuideReport -Name "pair_complete" -Default $false)
    $controlPreconditionReady = [bool](Get-ObjectPropertyValue -Object $controlLaneFromControl -Name "safe_to_leave" -Default $false)
    $treatmentReady = $actualSnapshots -ge $targetSnapshots -and $actualSeconds -ge $targetSeconds
    $patchReady = $actualPatchEvents -ge $targetPatchEvents
    $postPatchReady = $actualPostPatchSeconds -ge $targetPostPatchSeconds
    $safeToLeave = $treatmentReady -and $patchReady -and $postPatchReady
    $verdict = Get-TreatmentVerdict -PairComplete $pairComplete -TreatmentReady $treatmentReady -PatchReady $patchReady -PostPatchReady $postPatchReady

    $treatmentLaneSection = New-TreatmentLaneSection `
        -TargetSnapshots $targetSnapshots `
        -TargetSeconds $targetSeconds `
        -ActualSnapshots $actualSnapshots `
        -ActualSeconds $actualSeconds `
        -TargetPatchEvents $targetPatchEvents `
        -ActualPatchEvents $actualPatchEvents `
        -TargetPostPatchSeconds $targetPostPatchSeconds `
        -ActualPostPatchSeconds $actualPostPatchSeconds `
        -PatchEvidence $patchEvidence `
        -SafeToLeave $safeToLeave

    $explanation = Get-TreatmentExplanation `
        -Verdict $verdict `
        -TreatmentLaneSection $treatmentLaneSection `
        -PairComplete $pairComplete `
        -ControlPreconditionReady $controlPreconditionReady

    return [pscustomobject]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $resolvedPairRoot
        pair_complete = $pairComplete
        mission_path_used = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "mission_path_used" -Default "")
        mission_source_kind = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "mission_source_kind" -Default "")
        treatment_profile = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "treatment_profile" -Default "conservative")
        monitor_phase = [string](Get-ObjectPropertyValue -Object $controlGuideReport -Name "monitor_phase" -Default "")
        control_precondition_ready = $controlPreconditionReady
        treatment_safe_to_leave = $safeToLeave
        treatment_grounded_ready = $safeToLeave
        current_verdict = $verdict
        explanation = $explanation
        treatment_lane = $treatmentLaneSection
        artifacts = [ordered]@{
            treatment_patch_window_json = $outputPaths.JsonPath
            treatment_patch_window_markdown = $outputPaths.MarkdownPath
            control_to_treatment_switch_json = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "control_to_treatment_switch_json" -Default "")
            control_to_treatment_switch_markdown = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "control_to_treatment_switch_markdown" -Default "")
            pair_summary_json = $pairSummaryPath
            treatment_summary_json = $laneArtifacts.SummaryPath
            patch_history_ndjson = $laneArtifacts.PatchHistoryPath
            patch_apply_history_ndjson = $laneArtifacts.PatchApplyHistoryPath
            human_presence_timeline_ndjson = $laneArtifacts.HumanPresenceTimelinePath
            live_monitor_status_json = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "live_monitor_status_json" -Default "")
            monitor_verdict_history_ndjson = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "monitor_verdict_history_ndjson" -Default "")
            control_join_instructions = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "control_join_instructions" -Default "")
            treatment_join_instructions = [string](Get-ObjectPropertyValue -Object $controlGuideArtifacts -Name "treatment_join_instructions" -Default "")
        }
    }
}

if ($PollSeconds -lt 1) {
    throw "PollSeconds must be at least 1."
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    ""
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
}

$latestStatus = $null
$lastPrintedKey = ""

while ($true) {
    $status = Get-TreatmentStatus `
        -ExplicitPairRoot $PairRoot `
        -ShouldUseLatest:$UseLatest `
        -ExplicitMissionPath $MissionPath `
        -RequestedPollSeconds $PollSeconds `
        -ExplicitLabRoot $LabRoot `
        -ExplicitEvalRoot $EvalRoot `
        -ExplicitPairsRoot $PairsRoot `
        -ResolvedOutputRoot $resolvedOutputRoot

    Write-JsonFile -Path $status.artifacts.treatment_patch_window_json -Value $status
    $statusForMarkdown = Read-JsonFile -Path $status.artifacts.treatment_patch_window_json
    Write-TextFile -Path $status.artifacts.treatment_patch_window_markdown -Value (Get-TreatmentMarkdown -Report $statusForMarkdown)

    $printKey = @(
        [string]$status.current_verdict
        [string]$status.treatment_safe_to_leave
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_human_snapshots" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_human_presence_seconds" -Default 0.0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_patch_while_human_present_events" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_post_patch_observation_seconds" -Default 0.0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "first_human_present_patch_timestamp_utc" -Default "")
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "first_patch_apply_during_human_window_timestamp_utc" -Default "")
    ) -join "|"

    if ($printKey -ne $lastPrintedKey -or $Once) {
        Write-Host "Treatment-hold guidance:"
        Write-Host "  Pair root: $($status.pair_root)"
        Write-Host "  Verdict: $($status.current_verdict)"
        Write-Host "  Treatment snapshots / seconds: $($status.treatment_lane.actual_human_snapshots) / $($status.treatment_lane.actual_human_presence_seconds)"
        Write-Host "  Treatment remaining snapshots / seconds: $($status.treatment_lane.remaining_human_snapshots) / $($status.treatment_lane.remaining_human_presence_seconds)"
        Write-Host "  Patch events / remaining: $($status.treatment_lane.actual_patch_while_human_present_events) / $($status.treatment_lane.remaining_patch_while_human_present_events)"
        Write-Host "  Post-patch seconds / remaining: $($status.treatment_lane.actual_post_patch_observation_seconds) / $($status.treatment_lane.remaining_post_patch_observation_seconds)"
        Write-Host "  First counted human-present patch: $($status.treatment_lane.first_human_present_patch_timestamp_utc)"
        Write-Host "  First patch apply during human window: $($status.treatment_lane.first_patch_apply_during_human_window_timestamp_utc)"
        Write-Host "  Safe to leave treatment: $($status.treatment_safe_to_leave)"
        Write-Host "  Explanation: $($status.explanation)"
        Write-Host "  JSON: $($status.artifacts.treatment_patch_window_json)"
        Write-Host "  Markdown: $($status.artifacts.treatment_patch_window_markdown)"
        $lastPrintedKey = $printKey
    }

    $latestStatus = $status

    if ($Once) {
        break
    }

    if ($status.current_verdict -in @("blocked-no-active-pair", "insufficient-timeout", "treatment-grounded-ready")) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
}

$latestStatus
