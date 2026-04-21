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

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 24
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

function Resolve-PairRootForPhaseFlow {
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

function Invoke-GuideScript {
    param(
        [string]$ScriptName,
        [string]$ResolvedPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ExplicitMissionPath,
        [int]$RequestedPollSeconds,
        [string]$ExplicitLabRoot,
        [string]$ExplicitEvalRoot,
        [string]$ExplicitPairsRoot,
        [string]$ExplicitOutputRoot
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (".\scripts\{0}" -f $ScriptName),
        "-Once",
        "-PollSeconds",
        [string]$RequestedPollSeconds
    )

    $invokeParams = @{
        Once = $true
        PollSeconds = $RequestedPollSeconds
    }

    if ($ResolvedPairRoot) {
        $commandParts += @("-PairRoot", $ResolvedPairRoot)
        $invokeParams["PairRoot"] = $ResolvedPairRoot
    }
    elseif ($ShouldUseLatest) {
        $commandParts += "-UseLatest"
        $invokeParams["UseLatest"] = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $commandParts += @("-MissionPath", $ExplicitMissionPath)
        $invokeParams["MissionPath"] = $ExplicitMissionPath
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitLabRoot)) {
        $commandParts += @("-LabRoot", $ExplicitLabRoot)
        $invokeParams["LabRoot"] = $ExplicitLabRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEvalRoot)) {
        $commandParts += @("-EvalRoot", $ExplicitEvalRoot)
        $invokeParams["EvalRoot"] = $ExplicitEvalRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairsRoot)) {
        $commandParts += @("-PairsRoot", $ExplicitPairsRoot)
        $invokeParams["PairsRoot"] = $ExplicitPairsRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitOutputRoot)) {
        $commandParts += @("-OutputRoot", $ExplicitOutputRoot)
        $invokeParams["OutputRoot"] = $ExplicitOutputRoot
    }

    $commandText = ($commandParts | ForEach-Object {
            if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
        }) -join ' '

    try {
        $result = & $scriptPath @invokeParams
        return [pscustomobject]@{
            CommandText = $commandText
            Result = $result
            Error = ""
        }
    }
    catch {
        return [pscustomobject]@{
            CommandText = $commandText
            Result = $null
            Error = $_.Exception.Message
        }
    }
}

function Get-PhaseOutputPaths {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedOutputRoot,
        [string]$ResolvedEvalRoot
    )

    if ($ResolvedPairRoot) {
        return [ordered]@{
            JsonPath = Join-Path $ResolvedPairRoot "conservative_phase_flow.json"
            MarkdownPath = Join-Path $ResolvedPairRoot "conservative_phase_flow.md"
        }
    }

    if ($ResolvedOutputRoot) {
        return [ordered]@{
            JsonPath = Join-Path $ResolvedOutputRoot "conservative_phase_flow.json"
            MarkdownPath = Join-Path $ResolvedOutputRoot "conservative_phase_flow.md"
        }
    }

    $registryRoot = Ensure-Directory -Path (Join-Path $ResolvedEvalRoot "registry\conservative_phase_flow")
    return [ordered]@{
        JsonPath = Join-Path $registryRoot "conservative_phase_flow.json"
        MarkdownPath = Join-Path $registryRoot "conservative_phase_flow.md"
    }
}

function Get-PhaseDecision {
    param(
        [bool]$PairComplete,
        [bool]$SwitchAllowed,
        [bool]$FinishAllowed,
        [bool]$TreatmentActivitySeen,
        [int]$ControlRemainingSnapshots,
        [double]$ControlRemainingSeconds,
        [int]$TreatmentRemainingSnapshots,
        [double]$TreatmentRemainingSeconds,
        [int]$TreatmentRemainingPatchEvents,
        [double]$TreatmentRemainingPostPatchSeconds
    )

    if ($FinishAllowed) {
        return [pscustomobject]@{
            CurrentPhase = "grounded-ready"
            Verdict = "phase-grounded-ready-finish-now"
            NextAction = "Finish the grounded conservative session now and proceed to closeout."
        }
    }

    if (-not $SwitchAllowed) {
        if ($PairComplete) {
            return [pscustomobject]@{
                CurrentPhase = "complete-insufficient"
                Verdict = "phase-insufficient-timeout"
                NextAction = "Do not switch. The session already ended with missing control-side evidence."
            }
        }

        return [pscustomobject]@{
            CurrentPhase = "control"
            Verdict = "phase-control-stay"
            NextAction = "Stay in the control lane until the control minimums are cleared."
        }
    }

    if (-not $PairComplete -and -not $TreatmentActivitySeen -and $TreatmentRemainingSnapshots -gt 0 -and $TreatmentRemainingSeconds -gt 0) {
        return [pscustomobject]@{
            CurrentPhase = "control-ready-switch"
            Verdict = "phase-control-ready-switch-now"
            NextAction = "Control is cleared. Switch to the treatment lane now."
        }
    }

    if ($TreatmentRemainingSnapshots -gt 0 -or $TreatmentRemainingSeconds -gt 0) {
        if ($PairComplete) {
            return [pscustomobject]@{
                CurrentPhase = "complete-insufficient"
                Verdict = "phase-insufficient-timeout"
                NextAction = "The session already ended before treatment human signal became sufficient."
            }
        }

        return [pscustomobject]@{
            CurrentPhase = "treatment"
            Verdict = "phase-treatment-waiting-for-human-signal"
            NextAction = "Stay in the treatment lane until treatment human signal clears the mission minimums."
        }
    }

    if ($TreatmentRemainingPatchEvents -gt 0) {
        if ($PairComplete) {
            return [pscustomobject]@{
                CurrentPhase = "complete-insufficient"
                Verdict = "phase-insufficient-timeout"
                NextAction = "The session already ended before treatment produced enough counted human-present patch events."
            }
        }

        return [pscustomobject]@{
            CurrentPhase = "treatment"
            Verdict = "phase-treatment-waiting-for-patch"
            NextAction = "Stay in the treatment lane until a counted patch-while-human-present event occurs."
        }
    }

    if ($TreatmentRemainingPostPatchSeconds -gt 0) {
        if ($PairComplete) {
            return [pscustomobject]@{
                CurrentPhase = "complete-insufficient"
                Verdict = "phase-insufficient-timeout"
                NextAction = "The session already ended before the treatment post-patch observation window became long enough."
            }
        }

        return [pscustomobject]@{
            CurrentPhase = "treatment"
            Verdict = "phase-treatment-waiting-for-post-patch-window"
            NextAction = "Stay in the treatment lane until the post-patch observation window is long enough."
        }
    }

    if ($PairComplete) {
        return [pscustomobject]@{
            CurrentPhase = "complete-insufficient"
            Verdict = "phase-insufficient-timeout"
            NextAction = "Inspect the saved pair artifacts because the session ended without a clean grounded-ready finish."
        }
    }

    return [pscustomobject]@{
        CurrentPhase = "treatment"
        Verdict = "phase-treatment-waiting-for-post-patch-window"
        NextAction = "Stay in the treatment lane and keep watching the treatment grounded window."
    }
}

function Get-PhaseExplanation {
    param(
        [string]$Verdict,
        [object]$ControlLane,
        [object]$TreatmentLane,
        [string]$ControlExplanation,
        [string]$TreatmentExplanation
    )

    $controlRemainingSnapshots = [int](Get-ObjectPropertyValue -Object $ControlLane -Name "remaining_human_snapshots" -Default 0)
    $controlRemainingSeconds = [double](Get-ObjectPropertyValue -Object $ControlLane -Name "remaining_human_presence_seconds" -Default 0.0)
    $treatmentRemainingSnapshots = [int](Get-ObjectPropertyValue -Object $TreatmentLane -Name "remaining_human_snapshots" -Default 0)
    $treatmentRemainingSeconds = [double](Get-ObjectPropertyValue -Object $TreatmentLane -Name "remaining_human_presence_seconds" -Default 0.0)
    $treatmentRemainingPatchEvents = [int](Get-ObjectPropertyValue -Object $TreatmentLane -Name "remaining_patch_while_human_present_events" -Default 0)
    $treatmentRemainingPostPatchSeconds = [double](Get-ObjectPropertyValue -Object $TreatmentLane -Name "remaining_post_patch_observation_seconds" -Default 0.0)

    switch ($Verdict) {
        "phase-control-stay" {
            return "Stay in control. Control is still short by $controlRemainingSnapshots snapshot(s) and $controlRemainingSeconds second(s). $ControlExplanation"
        }
        "phase-control-ready-switch-now" {
            return "Control is clear. Switch from control to treatment now and begin the treatment-hold phase. $ControlExplanation"
        }
        "phase-treatment-waiting-for-human-signal" {
            return "Stay in treatment. Treatment is still short by $treatmentRemainingSnapshots snapshot(s) and $treatmentRemainingSeconds second(s). $TreatmentExplanation"
        }
        "phase-treatment-waiting-for-patch" {
            return "Stay in treatment. Human signal is already sufficient, but treatment still needs $treatmentRemainingPatchEvents counted patch-while-human-present event(s). $TreatmentExplanation"
        }
        "phase-treatment-waiting-for-post-patch-window" {
            return "Stay in treatment. Counted human-present patch evidence exists, but the post-patch observation window is still short by $treatmentRemainingPostPatchSeconds second(s). $TreatmentExplanation"
        }
        "phase-grounded-ready-finish-now" {
            return "Control is clear and treatment is grounded-ready. Finish the live session and proceed to closeout. $TreatmentExplanation"
        }
        "phase-insufficient-timeout" {
            if ($controlRemainingSnapshots -gt 0 -or $controlRemainingSeconds -gt 0) {
                return "The saved session ended before control cleared. Control was still short by $controlRemainingSnapshots snapshot(s) and $controlRemainingSeconds second(s). $ControlExplanation"
            }

            if ($treatmentRemainingSnapshots -gt 0 -or $treatmentRemainingSeconds -gt 0) {
                return "The saved session ended before treatment human signal cleared. Treatment was still short by $treatmentRemainingSnapshots snapshot(s) and $treatmentRemainingSeconds second(s). $TreatmentExplanation"
            }

            if ($treatmentRemainingPatchEvents -gt 0) {
                return "The saved session ended before treatment produced enough counted human-present patch events. Treatment still missed $treatmentRemainingPatchEvents event(s). $TreatmentExplanation"
            }

            if ($treatmentRemainingPostPatchSeconds -gt 0) {
                return "The saved session ended before the treatment post-patch observation window was long enough. Treatment was still short by $treatmentRemainingPostPatchSeconds second(s). $TreatmentExplanation"
            }

            return "The saved session ended before the sequential phase flow reached a clean grounded-ready finish."
        }
        default {
            return if (-not [string]::IsNullOrWhiteSpace($ControlExplanation)) { $ControlExplanation } else { "No active pair root could be resolved for the sequential phase flow." }
        }
    }
}

function Get-PhaseMarkdown {
    param([object]$Report)

    $artifacts = Get-ObjectPropertyValue -Object $Report -Name "artifacts" -Default $null
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Conservative Sequential Phase Flow") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Current phase: $($Report.current_phase)") | Out-Null
    $lines.Add("- Current phase verdict: $($Report.current_phase_verdict)") | Out-Null
    $lines.Add("- Next operator action: $($Report.next_operator_action)") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Mission path used: $($Report.mission_path_used)") | Out-Null
    $lines.Add("- Switch to treatment allowed: $($Report.switch_to_treatment_allowed)") | Out-Null
    $lines.Add("- Finish grounded session allowed: $($Report.finish_grounded_session_allowed)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Control Phase") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control snapshots: $($Report.control_lane.actual_human_snapshots) / $($Report.control_lane.target_human_snapshots)") | Out-Null
    $lines.Add("- Control seconds: $($Report.control_lane.actual_human_presence_seconds) / $($Report.control_lane.target_human_presence_seconds)") | Out-Null
    $lines.Add("- Safe to leave control: $($Report.control_lane.safe_to_leave)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Treatment Phase") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Treatment snapshots: $($Report.treatment_lane.actual_human_snapshots) / $($Report.treatment_lane.target_human_snapshots)") | Out-Null
    $lines.Add("- Treatment seconds: $($Report.treatment_lane.actual_human_presence_seconds) / $($Report.treatment_lane.target_human_presence_seconds)") | Out-Null
    $lines.Add("- Treatment patch events: $($Report.treatment_lane.actual_patch_while_human_present_events) / $($Report.treatment_lane.target_patch_while_human_present_events)") | Out-Null
    $lines.Add("- Treatment first counted human-present patch timestamp: $($Report.treatment_lane.first_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("- Treatment first patch apply during human window timestamp: $($Report.treatment_lane.first_patch_apply_during_human_window_timestamp_utc)") | Out-Null
    $lines.Add("- Treatment post-patch observation seconds: $($Report.treatment_lane.actual_post_patch_observation_seconds) / $($Report.treatment_lane.target_post_patch_observation_seconds)") | Out-Null
    $lines.Add("- Treatment safe to leave: $($Report.treatment_lane.safe_to_leave)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Artifacts") | Out-Null
    $lines.Add("") | Out-Null

    if ($null -ne $artifacts) {
        foreach ($property in $artifacts.PSObject.Properties) {
            $lines.Add("- $($property.Name): $($property.Value)") | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-PhaseStatus {
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

    $resolvedEvalRoot = Get-ResolvedEvalRoot -ExplicitLabRoot $ExplicitLabRoot -ExplicitEvalRoot $ExplicitEvalRoot
    $resolvedPairsRoot = if ([string]::IsNullOrWhiteSpace($ExplicitPairsRoot)) {
        Ensure-Directory -Path (Get-PairsRootDefault -LabRoot (Split-Path -Path $resolvedEvalRoot -Parent))
    }
    else {
        Ensure-Directory -Path (Get-AbsolutePath -Path $ExplicitPairsRoot)
    }

    $resolvedPairRoot = Resolve-PairRootForPhaseFlow `
        -ExplicitPairRoot $ExplicitPairRoot `
        -ShouldUseLatest:$ShouldUseLatest `
        -ResolvedEvalRoot $resolvedEvalRoot `
        -ResolvedPairsRoot $resolvedPairsRoot

    $outputPaths = Get-PhaseOutputPaths -ResolvedPairRoot $resolvedPairRoot -ResolvedOutputRoot $ResolvedOutputRoot -ResolvedEvalRoot $resolvedEvalRoot
    $controlExecution = Invoke-GuideScript `
        -ScriptName "guide_control_to_treatment_switch.ps1" `
        -ResolvedPairRoot $resolvedPairRoot `
        -ShouldUseLatest:$ShouldUseLatest `
        -ExplicitMissionPath $ExplicitMissionPath `
        -RequestedPollSeconds $RequestedPollSeconds `
        -ExplicitLabRoot $ExplicitLabRoot `
        -ExplicitEvalRoot $ExplicitEvalRoot `
        -ExplicitPairsRoot $ExplicitPairsRoot `
        -ExplicitOutputRoot $ResolvedOutputRoot
    $controlReport = Get-ObjectPropertyValue -Object $controlExecution -Name "Result" -Default $null
    $controlArtifacts = Get-ObjectPropertyValue -Object $controlReport -Name "artifacts" -Default $null

    $treatmentExecution = Invoke-GuideScript `
        -ScriptName "guide_treatment_patch_window.ps1" `
        -ResolvedPairRoot $resolvedPairRoot `
        -ShouldUseLatest:$ShouldUseLatest `
        -ExplicitMissionPath $ExplicitMissionPath `
        -RequestedPollSeconds $RequestedPollSeconds `
        -ExplicitLabRoot $ExplicitLabRoot `
        -ExplicitEvalRoot $ExplicitEvalRoot `
        -ExplicitPairsRoot $ExplicitPairsRoot `
        -ExplicitOutputRoot $ResolvedOutputRoot
    $treatmentReport = Get-ObjectPropertyValue -Object $treatmentExecution -Name "Result" -Default $null
    $treatmentArtifacts = Get-ObjectPropertyValue -Object $treatmentReport -Name "artifacts" -Default $null

    $resolvedPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlReport -Name "pair_root" -Default $resolvedPairRoot))
    if (-not $resolvedPairRoot) {
        $resolvedPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentReport -Name "pair_root" -Default ""))
    }

    $outputPaths = Get-PhaseOutputPaths -ResolvedPairRoot $resolvedPairRoot -ResolvedOutputRoot $ResolvedOutputRoot -ResolvedEvalRoot $resolvedEvalRoot

    if ($null -eq $controlReport -or [string](Get-ObjectPropertyValue -Object $controlReport -Name "current_switch_verdict" -Default "") -eq "blocked-no-active-pair") {
        return [pscustomobject]@{
            schema_version = 1
            prompt_id = Get-RepoPromptId
            generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
            source_commit_sha = Get-RepoHeadCommitSha
            pair_root = ""
            pair_complete = $false
            mission_path_used = [string](Get-ObjectPropertyValue -Object $controlReport -Name "mission_path_used" -Default "")
            mission_source_kind = [string](Get-ObjectPropertyValue -Object $controlReport -Name "mission_source_kind" -Default "")
            treatment_profile = [string](Get-ObjectPropertyValue -Object $controlReport -Name "treatment_profile" -Default "conservative")
            current_phase = "blocked"
            current_phase_verdict = "phase-blocked-no-active-pair"
            next_operator_action = "Start or select an active pair root before using the sequential phase-director."
            switch_to_treatment_allowed = $false
            finish_grounded_session_allowed = $false
            explanation = if ($controlExecution.Error) { $controlExecution.Error } else { "No active or completed pair root could be resolved." }
            control_lane = [ordered]@{
                target_human_snapshots = 0
                actual_human_snapshots = 0
                remaining_human_snapshots = 0
                target_human_presence_seconds = 0.0
                actual_human_presence_seconds = 0.0
                remaining_human_presence_seconds = 0.0
                safe_to_leave = $false
            }
            treatment_lane = [ordered]@{
                target_human_snapshots = 0
                actual_human_snapshots = 0
                remaining_human_snapshots = 0
                target_human_presence_seconds = 0.0
                actual_human_presence_seconds = 0.0
                remaining_human_presence_seconds = 0.0
                target_patch_while_human_present_events = 0
                actual_patch_while_human_present_events = 0
                remaining_patch_while_human_present_events = 0
                target_post_patch_observation_seconds = 0.0
                actual_post_patch_observation_seconds = 0.0
                remaining_post_patch_observation_seconds = 0.0
                first_human_present_patch_timestamp_utc = ""
                first_patch_apply_during_human_window_timestamp_utc = ""
                safe_to_leave = $false
            }
            artifacts = [ordered]@{
                conservative_phase_flow_json = $outputPaths.JsonPath
                conservative_phase_flow_markdown = $outputPaths.MarkdownPath
                control_to_treatment_switch_json = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "control_to_treatment_switch_json" -Default "")
                control_to_treatment_switch_markdown = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "control_to_treatment_switch_markdown" -Default "")
                treatment_patch_window_json = [string](Get-ObjectPropertyValue -Object $treatmentArtifacts -Name "treatment_patch_window_json" -Default "")
                treatment_patch_window_markdown = [string](Get-ObjectPropertyValue -Object $treatmentArtifacts -Name "treatment_patch_window_markdown" -Default "")
            }
        }
    }

    $controlLane = Get-ObjectPropertyValue -Object $controlReport -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $treatmentReport -Name "treatment_lane" -Default (Get-ObjectPropertyValue -Object $controlReport -Name "treatment_lane" -Default $null)
    $pairComplete = [bool](Get-ObjectPropertyValue -Object $controlReport -Name "pair_complete" -Default (Get-ObjectPropertyValue -Object $treatmentReport -Name "pair_complete" -Default $false))
    $switchAllowed = [bool](Get-ObjectPropertyValue -Object $controlLane -Name "safe_to_leave" -Default $false)
    $finishAllowed = [bool](Get-ObjectPropertyValue -Object $treatmentReport -Name "treatment_safe_to_leave" -Default $false)
    $treatmentActivitySeen = [bool](Get-ObjectPropertyValue -Object $controlReport -Name "treatment_activity_seen" -Default $false)

    $phaseDecision = Get-PhaseDecision `
        -PairComplete $pairComplete `
        -SwitchAllowed $switchAllowed `
        -FinishAllowed $finishAllowed `
        -TreatmentActivitySeen $treatmentActivitySeen `
        -ControlRemainingSnapshots ([int](Get-ObjectPropertyValue -Object $controlLane -Name "remaining_human_snapshots" -Default 0)) `
        -ControlRemainingSeconds ([double](Get-ObjectPropertyValue -Object $controlLane -Name "remaining_human_presence_seconds" -Default 0.0)) `
        -TreatmentRemainingSnapshots ([int](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_human_snapshots" -Default 0)) `
        -TreatmentRemainingSeconds ([double](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_human_presence_seconds" -Default 0.0)) `
        -TreatmentRemainingPatchEvents ([int](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_patch_while_human_present_events" -Default 0)) `
        -TreatmentRemainingPostPatchSeconds ([double](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_post_patch_observation_seconds" -Default 0.0))

    $explanation = Get-PhaseExplanation `
        -Verdict $phaseDecision.Verdict `
        -ControlLane $controlLane `
        -TreatmentLane $treatmentLane `
        -ControlExplanation ([string](Get-ObjectPropertyValue -Object $controlReport -Name "explanation" -Default "")) `
        -TreatmentExplanation ([string](Get-ObjectPropertyValue -Object $treatmentReport -Name "explanation" -Default ""))

    return [pscustomobject]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $resolvedPairRoot
        pair_complete = $pairComplete
        mission_path_used = [string](Get-ObjectPropertyValue -Object $controlReport -Name "mission_path_used" -Default (Get-ObjectPropertyValue -Object $treatmentReport -Name "mission_path_used" -Default ""))
        mission_source_kind = [string](Get-ObjectPropertyValue -Object $controlReport -Name "mission_source_kind" -Default (Get-ObjectPropertyValue -Object $treatmentReport -Name "mission_source_kind" -Default ""))
        treatment_profile = [string](Get-ObjectPropertyValue -Object $controlReport -Name "treatment_profile" -Default (Get-ObjectPropertyValue -Object $treatmentReport -Name "treatment_profile" -Default "conservative"))
        current_phase = $phaseDecision.CurrentPhase
        current_phase_verdict = $phaseDecision.Verdict
        next_operator_action = $phaseDecision.NextAction
        switch_to_treatment_allowed = $switchAllowed
        finish_grounded_session_allowed = $finishAllowed
        explanation = $explanation
        control_lane = [ordered]@{
            target_human_snapshots = [int](Get-ObjectPropertyValue -Object $controlLane -Name "target_human_snapshots" -Default 0)
            actual_human_snapshots = [int](Get-ObjectPropertyValue -Object $controlLane -Name "actual_human_snapshots" -Default 0)
            remaining_human_snapshots = [int](Get-ObjectPropertyValue -Object $controlLane -Name "remaining_human_snapshots" -Default 0)
            target_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "target_human_presence_seconds" -Default 0.0)
            actual_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "actual_human_presence_seconds" -Default 0.0)
            remaining_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "remaining_human_presence_seconds" -Default 0.0)
            safe_to_leave = $switchAllowed
        }
        treatment_lane = [ordered]@{
            target_human_snapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "target_human_snapshots" -Default 0)
            actual_human_snapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_human_snapshots" -Default 0)
            remaining_human_snapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_human_snapshots" -Default 0)
            target_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "target_human_presence_seconds" -Default 0.0)
            actual_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_human_presence_seconds" -Default 0.0)
            remaining_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_human_presence_seconds" -Default 0.0)
            target_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "target_patch_while_human_present_events" -Default 0)
            actual_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_patch_while_human_present_events" -Default 0)
            remaining_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_patch_while_human_present_events" -Default 0)
            target_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "target_post_patch_observation_seconds" -Default 0.0)
            actual_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_post_patch_observation_seconds" -Default 0.0)
            remaining_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_post_patch_observation_seconds" -Default 0.0)
            first_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "first_human_present_patch_timestamp_utc" -Default "")
            first_patch_apply_during_human_window_timestamp_utc = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "first_patch_apply_during_human_window_timestamp_utc" -Default "")
            safe_to_leave = $finishAllowed
        }
        artifacts = [ordered]@{
            conservative_phase_flow_json = $outputPaths.JsonPath
            conservative_phase_flow_markdown = $outputPaths.MarkdownPath
            control_to_treatment_switch_json = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "control_to_treatment_switch_json" -Default "")
            control_to_treatment_switch_markdown = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "control_to_treatment_switch_markdown" -Default "")
            treatment_patch_window_json = [string](Get-ObjectPropertyValue -Object $treatmentArtifacts -Name "treatment_patch_window_json" -Default "")
            treatment_patch_window_markdown = [string](Get-ObjectPropertyValue -Object $treatmentArtifacts -Name "treatment_patch_window_markdown" -Default "")
            mission_execution_json = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "mission_execution_json" -Default "")
            mission_snapshot_json = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "mission_snapshot_json" -Default "")
            pair_summary_json = [string](Get-ObjectPropertyValue -Object $treatmentArtifacts -Name "pair_summary_json" -Default "")
            live_monitor_status_json = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "live_monitor_status_json" -Default "")
            monitor_verdict_history_ndjson = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "monitor_verdict_history_ndjson" -Default "")
            control_join_instructions = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "control_join_instructions" -Default "")
            treatment_join_instructions = [string](Get-ObjectPropertyValue -Object $controlArtifacts -Name "treatment_join_instructions" -Default "")
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
    $status = Get-PhaseStatus `
        -ExplicitPairRoot $PairRoot `
        -ShouldUseLatest:$UseLatest `
        -ExplicitMissionPath $MissionPath `
        -RequestedPollSeconds $PollSeconds `
        -ExplicitLabRoot $LabRoot `
        -ExplicitEvalRoot $EvalRoot `
        -ExplicitPairsRoot $PairsRoot `
        -ResolvedOutputRoot $resolvedOutputRoot

    Write-JsonFile -Path $status.artifacts.conservative_phase_flow_json -Value $status
    $statusForMarkdown = Read-JsonFile -Path $status.artifacts.conservative_phase_flow_json
    Write-TextFile -Path $status.artifacts.conservative_phase_flow_markdown -Value (Get-PhaseMarkdown -Report $statusForMarkdown)

    $printKey = @(
        [string]$status.current_phase_verdict
        [string]$status.switch_to_treatment_allowed
        [string]$status.finish_grounded_session_allowed
        [string](Get-ObjectPropertyValue -Object $status.control_lane -Name "actual_human_snapshots" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.control_lane -Name "actual_human_presence_seconds" -Default 0.0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_human_snapshots" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_human_presence_seconds" -Default 0.0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_patch_while_human_present_events" -Default 0)
        [string](Get-ObjectPropertyValue -Object $status.treatment_lane -Name "actual_post_patch_observation_seconds" -Default 0.0)
    ) -join "|"

    if ($printKey -ne $lastPrintedKey -or $Once) {
        Write-Host "Sequential phase-director:"
        Write-Host "  Pair root: $($status.pair_root)"
        Write-Host "  Current phase: $($status.current_phase)"
        Write-Host "  Verdict: $($status.current_phase_verdict)"
        Write-Host "  Next action: $($status.next_operator_action)"
        Write-Host "  Control snapshots / seconds: $($status.control_lane.actual_human_snapshots) / $($status.control_lane.actual_human_presence_seconds)"
        Write-Host "  Control remaining snapshots / seconds: $($status.control_lane.remaining_human_snapshots) / $($status.control_lane.remaining_human_presence_seconds)"
        Write-Host "  Treatment snapshots / seconds: $($status.treatment_lane.actual_human_snapshots) / $($status.treatment_lane.actual_human_presence_seconds)"
        Write-Host "  Treatment patch events / remaining: $($status.treatment_lane.actual_patch_while_human_present_events) / $($status.treatment_lane.remaining_patch_while_human_present_events)"
        Write-Host "  Treatment post-patch seconds / remaining: $($status.treatment_lane.actual_post_patch_observation_seconds) / $($status.treatment_lane.remaining_post_patch_observation_seconds)"
        Write-Host "  Switch allowed: $($status.switch_to_treatment_allowed)"
        Write-Host "  Finish allowed: $($status.finish_grounded_session_allowed)"
        Write-Host "  Explanation: $($status.explanation)"
        Write-Host "  JSON: $($status.artifacts.conservative_phase_flow_json)"
        Write-Host "  Markdown: $($status.artifacts.conservative_phase_flow_markdown)"
        $lastPrintedKey = $printKey
    }

    $latestStatus = $status

    if ($Once) {
        break
    }

    if ($status.current_phase_verdict -in @("phase-blocked-no-active-pair", "phase-insufficient-timeout", "phase-grounded-ready-finish-now")) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
}

$latestStatus
