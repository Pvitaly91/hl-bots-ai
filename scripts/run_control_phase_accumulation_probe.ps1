[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$ClientExePath = "",
    [switch]$AutoStayInControlUntilTarget,
    [int]$ControlTargetSnapshots = -1,
    [double]$ControlTargetSeconds = -1,
    [int]$MaxProbeSeconds = -1
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

function Resolve-StrongSignalMissionArtifacts {
    param(
        [string]$ExplicitMissionPath,
        [string]$ExplicitMissionMarkdownPath,
        [string]$ResolvedLabRoot,
        [string]$ResolvedEvalRoot,
        [string]$ResolvedRegistryRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $resolvedMissionPath = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionPath)
        if (-not $resolvedMissionPath) {
            throw "Strong-signal mission JSON was not found: $ExplicitMissionPath"
        }

        $resolvedMissionMarkdownPath = if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionMarkdownPath)) {
            Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionMarkdownPath)
        }
        else {
            Resolve-ExistingPath -Path ([System.IO.Path]::ChangeExtension($resolvedMissionPath, ".md"))
        }

        return [pscustomobject]@{
            JsonPath = $resolvedMissionPath
            MarkdownPath = $resolvedMissionMarkdownPath
        }
    }

    $prepareScriptPath = Join-Path $PSScriptRoot "prepare_strong_signal_conservative_mission.ps1"
    $preparedMission = & $prepareScriptPath -LabRoot $ResolvedLabRoot -EvalRoot $ResolvedEvalRoot -OutputRoot $ResolvedRegistryRoot
    $resolvedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "StrongSignalMissionJsonPath" -Default ""))
    $resolvedMissionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "StrongSignalMissionMarkdownPath" -Default ""))
    if (-not $resolvedMissionPath) {
        throw "The strong-signal conservative mission could not be prepared."
    }

    return [pscustomobject]@{
        JsonPath = $resolvedMissionPath
        MarkdownPath = $resolvedMissionMarkdownPath
    }
}

function Get-EffectiveMissionArtifacts {
    param(
        [object]$BaseMission,
        [string]$BaseMissionPath,
        [string]$BaseMissionMarkdownPath,
        [string]$ResolvedOutputRoot,
        [int]$OverrideControlTargetSnapshots,
        [double]$OverrideControlTargetSeconds,
        [int]$OverrideMaxProbeSeconds
    )

    $effectiveControlTargetSnapshots = if ($OverrideControlTargetSnapshots -gt 0) {
        $OverrideControlTargetSnapshots
    }
    else {
        [int](Get-ObjectPropertyValue -Object $BaseMission -Name "target_minimum_control_human_snapshots" -Default 5)
    }

    $effectiveControlTargetSeconds = if ($OverrideControlTargetSeconds -gt 0) {
        $OverrideControlTargetSeconds
    }
    else {
        [double](Get-ObjectPropertyValue -Object $BaseMission -Name "target_minimum_control_human_presence_seconds" -Default 90.0)
    }

    $launcherDefaults = Get-ObjectPropertyValue -Object $BaseMission -Name "launcher_defaults" -Default $null
    $effectiveMaxProbeSeconds = if ($OverrideMaxProbeSeconds -gt 0) {
        $OverrideMaxProbeSeconds
    }
    else {
        [int](Get-ObjectPropertyValue -Object $launcherDefaults -Name "duration_seconds" -Default 120)
    }

    $requiresEffectiveMission = `
        ($effectiveControlTargetSnapshots -ne [int](Get-ObjectPropertyValue -Object $BaseMission -Name "target_minimum_control_human_snapshots" -Default 5)) -or `
        ([Math]::Abs($effectiveControlTargetSeconds - [double](Get-ObjectPropertyValue -Object $BaseMission -Name "target_minimum_control_human_presence_seconds" -Default 90.0)) -gt 0.001) -or `
        ($effectiveMaxProbeSeconds -ne [int](Get-ObjectPropertyValue -Object $launcherDefaults -Name "duration_seconds" -Default 120))

    if (-not $requiresEffectiveMission) {
        return [pscustomobject]@{
            JsonPath = $BaseMissionPath
            MarkdownPath = $BaseMissionMarkdownPath
            Mission = $BaseMission
            BaseMissionPath = $BaseMissionPath
            BaseMissionMarkdownPath = $BaseMissionMarkdownPath
            ControlTargetSnapshots = $effectiveControlTargetSnapshots
            ControlTargetSeconds = $effectiveControlTargetSeconds
            MaxProbeSeconds = $effectiveMaxProbeSeconds
            EffectiveMissionUsed = $false
        }
    }

    $effectiveMission = $BaseMission | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $effectiveMission.prompt_id = Get-RepoPromptId
    $effectiveMission.generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    $effectiveMission.source_commit_sha = Get-RepoHeadCommitSha
    $effectiveMission.mission_kind = "strong-signal-control-phase-accumulation-probe"
    $effectiveMission.target_minimum_control_human_snapshots = $effectiveControlTargetSnapshots
    $effectiveMission.target_minimum_control_human_presence_seconds = $effectiveControlTargetSeconds

    if ($null -eq (Get-ObjectPropertyValue -Object $effectiveMission -Name "launcher_defaults" -Default $null)) {
        $effectiveMission | Add-Member -NotePropertyName "launcher_defaults" -NotePropertyValue ([pscustomobject]@{})
    }
    $effectiveMission.launcher_defaults.duration_seconds = $effectiveMaxProbeSeconds

    if ($null -ne (Get-ObjectPropertyValue -Object $effectiveMission -Name "strong_signal_targets" -Default $null)) {
        $effectiveMission.strong_signal_targets.control_human_snapshots = $effectiveControlTargetSnapshots
        $effectiveMission.strong_signal_targets.control_human_presence_seconds = $effectiveControlTargetSeconds
        $effectiveMission.strong_signal_targets.duration_seconds = $effectiveMaxProbeSeconds
    }

    $effectiveMission | Add-Member -Force -NotePropertyName "control_phase_probe_overrides" -NotePropertyValue ([pscustomobject]@{
            control_human_snapshots = $effectiveControlTargetSnapshots
            control_human_presence_seconds = $effectiveControlTargetSeconds
            max_probe_seconds = $effectiveMaxProbeSeconds
        })

    $effectiveMissionJsonPath = Join-Path $ResolvedOutputRoot "control_phase_accumulation_probe_effective_mission.json"
    $effectiveMissionMarkdownPath = Join-Path $ResolvedOutputRoot "control_phase_accumulation_probe_effective_mission.md"

    Write-JsonFile -Path $effectiveMissionJsonPath -Value $effectiveMission
    $missionMarkdown = @(
        "# Control-Phase Accumulation Probe Mission",
        "",
        "- Base mission JSON: $BaseMissionPath",
        "- Control target snapshots: $effectiveControlTargetSnapshots",
        "- Control target human presence seconds: $effectiveControlTargetSeconds",
        "- Max probe seconds: $effectiveMaxProbeSeconds",
        "- This effective mission exists only so the control-only probe can keep the launch path aligned with the strong-signal mission while making any explicit control-side overrides visible."
    ) -join [Environment]::NewLine
    Write-TextFile -Path $effectiveMissionMarkdownPath -Value ($missionMarkdown + [Environment]::NewLine)

    return [pscustomobject]@{
        JsonPath = $effectiveMissionJsonPath
        MarkdownPath = $effectiveMissionMarkdownPath
        Mission = $effectiveMission
        BaseMissionPath = $BaseMissionPath
        BaseMissionMarkdownPath = $BaseMissionMarkdownPath
        ControlTargetSnapshots = $effectiveControlTargetSnapshots
        ControlTargetSeconds = $effectiveControlTargetSeconds
        MaxProbeSeconds = $effectiveMaxProbeSeconds
        EffectiveMissionUsed = $true
    }
}

function Get-ReportPaths {
    param(
        [string]$PairRoot,
        [string]$ResolvedOutputRoot,
        [string]$Stamp
    )

    if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
        return [ordered]@{
            JsonPath = Join-Path $PairRoot "control_phase_accumulation_probe.json"
            MarkdownPath = Join-Path $PairRoot "control_phase_accumulation_probe.md"
        }
    }

    return [ordered]@{
        JsonPath = Join-Path $ResolvedOutputRoot ("control_phase_accumulation_probe-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $ResolvedOutputRoot ("control_phase_accumulation_probe-{0}.md" -f $Stamp)
    }
}

function Get-ControlProbeVerdict {
    param(
        [bool]$ManualReviewRequired,
        [bool]$InterruptedAndRecovered,
        [bool]$ControlHumanUsable,
        [bool]$ControlStrongSignalTargetMet
    )

    if ($ManualReviewRequired) {
        return "control-phase-manual-review-required"
    }

    if ($InterruptedAndRecovered) {
        return "control-phase-interrupted-and-recovered"
    }

    if ($ControlStrongSignalTargetMet) {
        return "control-phase-strong-signal-target-met"
    }

    if ($ControlHumanUsable) {
        return "control-phase-human-usable-but-below-strong-signal-target"
    }

    return "control-phase-insufficient-human-signal"
}

function Get-ControlBlocker {
    param(
        [int]$ActualSnapshots,
        [double]$ActualSeconds,
        [int]$TargetSnapshots,
        [double]$TargetSeconds,
        [bool]$ServerConnectionSeen,
        [bool]$EnteredTheGameSeen
    )

    if ($ActualSnapshots -ge $TargetSnapshots -and $ActualSeconds -ge $TargetSeconds) {
        return ""
    }

    if (-not $ServerConnectionSeen) {
        return "The full control-only probe launched the client, but the control lane never logged a real server connection."
    }

    if (-not $EnteredTheGameSeen) {
        return "The control lane logged a server connection, but the client never reached a confirmed 'entered the game' state in the saved control lane."
    }

    if ($ActualSnapshots -le 0 -and $ActualSeconds -le 0.0) {
        return "The client reached the control lane, but the saved control evidence still never accumulated a counted human snapshot or any human-presence seconds."
    }

    $remainingSnapshots = [Math]::Max(0, $TargetSnapshots - $ActualSnapshots)
    $remainingSeconds = [Math]::Max(0.0, $TargetSeconds - $ActualSeconds)
    if ($remainingSnapshots -gt 0 -and $remainingSeconds -gt 0.0) {
        return "The control-only probe still stopped short of the stronger target by $remainingSnapshots snapshot(s) and $([Math]::Round($remainingSeconds, 2)) second(s)."
    }

    if ($remainingSnapshots -gt 0) {
        return "The control-only probe still stopped short of the stronger target by $remainingSnapshots control snapshot(s)."
    }

    return "The control-only probe still stopped short of the stronger target by $([Math]::Round($remainingSeconds, 2)) control second(s)."
}

function Get-ControlProbeExplanation {
    param(
        [string]$Verdict,
        [string]$HumanAttemptExplanation,
        [string]$Blocker
    )

    switch ($Verdict) {
        "control-phase-strong-signal-target-met" {
            return "The control-only strong-signal probe kept the human in the no-AI control lane long enough to satisfy the stronger control target. Another full strong-signal control+treatment attempt is now justified."
        }
        "control-phase-human-usable-but-below-strong-signal-target" {
            return "The control-only probe produced real human-usable control evidence, but it still stayed below the stronger strong-signal target. $Blocker"
        }
        "control-phase-interrupted-and-recovered" {
            return "The control-only probe needed recovery handling before closeout completed. Treat the saved pair as a recovered control proof rather than a clean direct accumulation run."
        }
        "control-phase-manual-review-required" {
            if (-not [string]::IsNullOrWhiteSpace($HumanAttemptExplanation)) {
                return "Manual review is still required for the control-only probe. $HumanAttemptExplanation"
            }

            return "Manual review is still required for the control-only probe."
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($HumanAttemptExplanation)) {
                return "The control-only strong-signal probe did not clear the stronger control target. $HumanAttemptExplanation"
            }

            return "The control-only strong-signal probe did not clear the stronger control target. $Blocker"
        }
    }
}

function Get-ControlProbeMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Control-Phase Accumulation Probe") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe verdict: $($Report.probe_verdict)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Mission path used: $($Report.mission_path_used)") | Out-Null
    $lines.Add("- Effective mission path used: $($Report.effective_mission_path_used)") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Readiness for full strong-signal control+treatment attempt: $($Report.readiness_for_full_strong_signal_control_treatment_attempt)") | Out-Null
    $lines.Add("- Recommendation: $($Report.recommendation)") | Out-Null
    $lines.Add("- Narrowest confirmed control-side blocker: $($Report.narrowest_confirmed_control_side_blocker)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Control Target") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control human snapshots target: $($Report.control_target.human_snapshots)") | Out-Null
    $lines.Add("- Control human presence seconds target: $($Report.control_target.human_presence_seconds)") | Out-Null
    $lines.Add("- Baseline human-usable snapshots: $($Report.control_baseline.human_snapshots)") | Out-Null
    $lines.Add("- Baseline human-usable presence seconds: $($Report.control_baseline.human_presence_seconds)") | Out-Null
    $lines.Add("- Actual control human snapshots: $($Report.control_actual.human_snapshots)") | Out-Null
    $lines.Add("- Actual control human presence seconds: $($Report.control_actual.human_presence_seconds)") | Out-Null
    $lines.Add("- Control became human-usable: $($Report.control_became_human_usable)") | Out-Null
    $lines.Add("- Control met stronger strong-signal target: $($Report.control_met_stronger_strong_signal_target)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Join And Gates") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Treatment intentionally not attempted: $($Report.treatment_intentionally_not_attempted)") | Out-Null
    $lines.Add("- Control join attempted: $($Report.control_join.attempted)") | Out-Null
    $lines.Add("- Control join attempts: $($Report.control_join.join_attempt_count)") | Out-Null
    $lines.Add("- Control join retry used: $($Report.control_join.join_retry_used)") | Out-Null
    $lines.Add("- Control port ready: $($Report.control_join.port_ready)") | Out-Null
    $lines.Add("- Control server connection seen: $($Report.control_join.server_connection_seen)") | Out-Null
    $lines.Add("- Control entered the game seen: $($Report.control_join.entered_the_game_seen)") | Out-Null
    $lines.Add("- Control gate verdict: $($Report.control_gate.current_switch_verdict)") | Out-Null
    $lines.Add("- Safe to leave control: $($Report.control_gate.safe_to_leave_control)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe JSON: $($Report.artifacts.control_phase_accumulation_probe_json)") | Out-Null
    $lines.Add("- Probe Markdown: $($Report.artifacts.control_phase_accumulation_probe_markdown)") | Out-Null
    $lines.Add("- Human participation attempt JSON: $($Report.artifacts.human_participation_conservative_attempt_json)") | Out-Null
    $lines.Add("- Human participation attempt Markdown: $($Report.artifacts.human_participation_conservative_attempt_markdown)") | Out-Null
    $lines.Add("- Pair summary JSON: $($Report.artifacts.pair_summary_json)") | Out-Null
    $lines.Add("- Control-to-treatment switch JSON: $($Report.artifacts.control_to_treatment_switch_json)") | Out-Null
    $lines.Add("- Mission execution JSON: $($Report.artifacts.mission_execution_json)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot)
}
$resolvedEvalRoot = Ensure-Directory -Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot)
$resolvedRegistryRoot = Ensure-Directory -Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot)
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedEvalRoot "control_phase_accumulation_probes")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}

$baseMissionArtifacts = Resolve-StrongSignalMissionArtifacts `
    -ExplicitMissionPath $MissionPath `
    -ExplicitMissionMarkdownPath $MissionMarkdownPath `
    -ResolvedLabRoot $resolvedLabRoot `
    -ResolvedEvalRoot $resolvedEvalRoot `
    -ResolvedRegistryRoot $resolvedRegistryRoot
$baseMission = Read-JsonFile -Path $baseMissionArtifacts.JsonPath
if ($null -eq $baseMission) {
    throw "Strong-signal mission JSON could not be parsed: $($baseMissionArtifacts.JsonPath)"
}

$effectiveMissionArtifacts = Get-EffectiveMissionArtifacts `
    -BaseMission $baseMission `
    -BaseMissionPath $baseMissionArtifacts.JsonPath `
    -BaseMissionMarkdownPath $baseMissionArtifacts.MarkdownPath `
    -ResolvedOutputRoot $resolvedOutputRoot `
    -OverrideControlTargetSnapshots $ControlTargetSnapshots `
    -OverrideControlTargetSeconds $ControlTargetSeconds `
    -OverrideMaxProbeSeconds $MaxProbeSeconds

$effectiveMission = $effectiveMissionArtifacts.Mission
$autoStayInControlUntilTarget = if ($PSBoundParameters.ContainsKey("AutoStayInControlUntilTarget")) {
    [bool]$AutoStayInControlUntilTarget
}
else {
    $true
}

$baselineGroundedMinimums = Get-ObjectPropertyValue -Object $effectiveMission -Name "baseline_grounded_minimums" -Default $null
$controlBaselineSnapshots = [int](Get-ObjectPropertyValue -Object $baselineGroundedMinimums -Name "control_human_snapshots" -Default 3)
$controlBaselineSeconds = [double](Get-ObjectPropertyValue -Object $baselineGroundedMinimums -Name "control_human_presence_seconds" -Default 60.0)
$controlTargetSnapshotsResolved = [int]$effectiveMissionArtifacts.ControlTargetSnapshots
$controlTargetSecondsResolved = [double]$effectiveMissionArtifacts.ControlTargetSeconds

$humanAttemptScriptPath = Join-Path $PSScriptRoot "run_human_participation_conservative_attempt.ps1"
$humanAttemptArguments = [ordered]@{
    MissionPath = $effectiveMissionArtifacts.JsonPath
    MissionMarkdownPath = $effectiveMissionArtifacts.MarkdownPath
    LabRoot = $resolvedLabRoot
    OutputRoot = $resolvedOutputRoot
    JoinSequence = "ControlOnly"
    ControlStaySecondsMinimum = [int][Math]::Ceiling($controlTargetSecondsResolved)
    AutoJoinControl = $true
}
if ($autoStayInControlUntilTarget) {
    $humanAttemptArguments.AutoSwitchWhenControlReady = $true
}
if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) {
    $humanAttemptArguments.ClientExePath = Get-AbsolutePath -Path $ClientExePath -BasePath $repoRoot
}

$humanAttemptCommandParts = New-Object System.Collections.Generic.List[string]
$humanAttemptCommandParts.Add("powershell -NoProfile -ExecutionPolicy Bypass -File `"$humanAttemptScriptPath`"") | Out-Null
foreach ($entry in $humanAttemptArguments.GetEnumerator()) {
    if ($entry.Value -is [bool]) {
        if ([bool]$entry.Value) {
            $humanAttemptCommandParts.Add("-$($entry.Key)") | Out-Null
        }
    }
    else {
        $humanAttemptCommandParts.Add("-$($entry.Key) `"$($entry.Value)`"") | Out-Null
    }
}
$humanAttemptCommand = $humanAttemptCommandParts -join " "

$humanAttemptResult = & $humanAttemptScriptPath @humanAttemptArguments
$pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "PairRoot" -Default ""))
$humanAttemptJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "HumanParticipationConservativeAttemptJsonPath" -Default ""))
$humanAttemptMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "HumanParticipationConservativeAttemptMarkdownPath" -Default ""))
$humanAttemptReport = Read-JsonFile -Path $humanAttemptJsonPath
if ($null -eq $humanAttemptReport) {
    throw "The control-only probe could not read the wrapped human-participation report: $humanAttemptJsonPath"
}

$controlHumanSignal = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null
$controlJoin = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_lane_join" -Default $null
$treatmentJoin = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_join" -Default $null
$controlGate = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_switch_guidance" -Default $null
$pairSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "artifacts" -Default $null) -Name "pair_summary_json" -Default ""))
$controlSwitchJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "artifacts" -Default $null) -Name "control_to_treatment_switch_json" -Default ""))
$missionExecutionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "artifacts" -Default $null) -Name "mission_execution_json" -Default ""))

$actualControlSnapshots = [int](Get-ObjectPropertyValue -Object $controlHumanSignal -Name "control_human_snapshots_count" -Default 0)
$actualControlSeconds = [double](Get-ObjectPropertyValue -Object $controlHumanSignal -Name "control_seconds_with_human_presence" -Default 0.0)
$controlBecameHumanUsable = $actualControlSnapshots -ge $controlBaselineSnapshots -and $actualControlSeconds -ge $controlBaselineSeconds
$controlMetStrongSignalTarget = $actualControlSnapshots -ge $controlTargetSnapshotsResolved -and $actualControlSeconds -ge $controlTargetSecondsResolved
$treatmentIntentionallyNotAttempted = -not [bool](Get-ObjectPropertyValue -Object $treatmentJoin -Name "attempted" -Default $false)
$manualReviewRequired = [bool](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "grounded_consistency_review_required" -Default $false) -or `
    ([string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "attempt_verdict" -Default "") -eq "manual-review-required")
$finalRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "final_recovery_verdict" -Default "")
$interruptedAndRecovered = $finalRecoveryVerdict -like "*recover*"

$probeVerdict = Get-ControlProbeVerdict `
    -ManualReviewRequired $manualReviewRequired `
    -InterruptedAndRecovered $interruptedAndRecovered `
    -ControlHumanUsable $controlBecameHumanUsable `
    -ControlStrongSignalTargetMet $controlMetStrongSignalTarget
$controlBlocker = Get-ControlBlocker `
    -ActualSnapshots $actualControlSnapshots `
    -ActualSeconds $actualControlSeconds `
    -TargetSnapshots $controlTargetSnapshotsResolved `
    -TargetSeconds $controlTargetSecondsResolved `
    -ServerConnectionSeen ([bool](Get-ObjectPropertyValue -Object $controlJoin -Name "server_connection_seen" -Default $false)) `
    -EnteredTheGameSeen ([bool](Get-ObjectPropertyValue -Object $controlJoin -Name "entered_the_game_seen" -Default $false))
$readinessForFullAttempt = $controlMetStrongSignalTarget
$recommendation = if ($readinessForFullAttempt) {
    "Control-side accumulation reached the stronger target. Another full strong-signal conservative control+treatment attempt is justified."
}
else {
    "Stay on control-phase work. Do not spend another full strong-signal control+treatment attempt until the control-only proof can clear the stronger control target."
}
$explanation = Get-ControlProbeExplanation `
    -Verdict $probeVerdict `
    -HumanAttemptExplanation ([string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "explanation" -Default "")) `
    -Blocker $controlBlocker

$reportPaths = Get-ReportPaths -PairRoot $pairRoot -ResolvedOutputRoot $resolvedOutputRoot -Stamp (Get-Date -Format "yyyyMMdd-HHmmss")
$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    probe_verdict = $probeVerdict
    explanation = $explanation
    mission_path_used = $baseMissionArtifacts.JsonPath
    mission_markdown_path_used = $baseMissionArtifacts.MarkdownPath
    effective_mission_path_used = $effectiveMissionArtifacts.JsonPath
    effective_mission_markdown_path_used = $effectiveMissionArtifacts.MarkdownPath
    effective_mission_used = $effectiveMissionArtifacts.EffectiveMissionUsed
    pair_root = $pairRoot
    control_target = [ordered]@{
        human_snapshots = $controlTargetSnapshotsResolved
        human_presence_seconds = $controlTargetSecondsResolved
        max_probe_seconds = $effectiveMissionArtifacts.MaxProbeSeconds
    }
    control_baseline = [ordered]@{
        human_snapshots = $controlBaselineSnapshots
        human_presence_seconds = $controlBaselineSeconds
    }
    control_actual = [ordered]@{
        human_snapshots = $actualControlSnapshots
        human_presence_seconds = $actualControlSeconds
    }
    control_became_human_usable = $controlBecameHumanUsable
    control_met_stronger_strong_signal_target = $controlMetStrongSignalTarget
    treatment_intentionally_not_attempted = $treatmentIntentionallyNotAttempted
    readiness_for_full_strong_signal_control_treatment_attempt = $readinessForFullAttempt
    narrowest_confirmed_control_side_blocker = $controlBlocker
    recommendation = $recommendation
    wrapped_attempt_verdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "attempt_verdict" -Default "")
    control_lane_verdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_lane_verdict" -Default "")
    certification_verdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "certification_verdict" -Default "")
    counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "counts_toward_promotion" -Default $false)
    control_join = [ordered]@{
        attempted = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "attempted" -Default $false)
        join_attempt_count = [int](Get-ObjectPropertyValue -Object $controlJoin -Name "join_attempt_count" -Default 0)
        join_retry_used = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "join_retry_used" -Default $false)
        port_ready = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "port_ready" -Default $false)
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "server_connection_seen" -Default $false)
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "entered_the_game_seen" -Default $false)
        first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $controlJoin -Name "first_server_connection_seen_at_utc" -Default "")
        first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $controlJoin -Name "first_entered_the_game_seen_at_utc" -Default "")
        client_process_observed_running = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "client_process_observed_running" -Default $false)
        process_runtime_seconds = Get-ObjectPropertyValue -Object $controlJoin -Name "process_runtime_seconds" -Default $null
    }
    control_gate = [ordered]@{
        current_switch_verdict = [string](Get-ObjectPropertyValue -Object $controlGate -Name "verdict_at_handoff" -Default "")
        safe_to_leave_control = [bool](Get-ObjectPropertyValue -Object $controlGate -Name "safe_to_leave_control" -Default $false)
        control_remaining_human_snapshots = [int](Get-ObjectPropertyValue -Object $controlGate -Name "control_remaining_human_snapshots" -Default 0)
        control_remaining_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $controlGate -Name "control_remaining_human_presence_seconds" -Default 0.0)
        explanation = [string](Get-ObjectPropertyValue -Object $controlGate -Name "explanation" -Default "")
    }
    execution = [ordered]@{
        wrapped_command = $humanAttemptCommand
        join_sequence = "ControlOnly"
        auto_join_control = $true
        auto_stay_in_control_until_target = $autoStayInControlUntilTarget
        control_stay_seconds_minimum = [int][Math]::Ceiling($controlTargetSecondsResolved)
        output_root = $resolvedOutputRoot
    }
    reused_stack = [ordered]@{
        strong_signal_mission = $true
        human_participation_conservative_attempt = $true
        local_client_discovery = $true
        join_live_pair_lane = $true
        control_switch_guidance = $true
        mission_execution = $true
    }
    artifacts = [ordered]@{
        control_phase_accumulation_probe_json = $reportPaths.JsonPath
        control_phase_accumulation_probe_markdown = $reportPaths.MarkdownPath
        human_participation_conservative_attempt_json = $humanAttemptJsonPath
        human_participation_conservative_attempt_markdown = $humanAttemptMarkdownPath
        pair_summary_json = $pairSummaryPath
        control_to_treatment_switch_json = $controlSwitchJsonPath
        mission_execution_json = $missionExecutionPath
        effective_mission_json = $effectiveMissionArtifacts.JsonPath
        effective_mission_markdown = $effectiveMissionArtifacts.MarkdownPath
    }
}

Write-JsonFile -Path $reportPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $reportPaths.JsonPath
Write-TextFile -Path $reportPaths.MarkdownPath -Value (Get-ControlProbeMarkdown -Report $reportForMarkdown)

Write-Host "Control-phase accumulation probe:"
Write-Host "  Probe verdict: $($report.probe_verdict)"
Write-Host "  Pair root: $($report.pair_root)"
Write-Host "  Control snapshots / seconds: $($report.control_actual.human_snapshots) / $($report.control_actual.human_presence_seconds)"
Write-Host "  Control target snapshots / seconds: $($report.control_target.human_snapshots) / $($report.control_target.human_presence_seconds)"
Write-Host "  Readiness for next full strong-signal attempt: $($report.readiness_for_full_strong_signal_control_treatment_attempt)"
Write-Host "  Probe report JSON: $($reportPaths.JsonPath)"
Write-Host "  Probe report Markdown: $($reportPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $pairRoot
    ControlPhaseAccumulationProbeJsonPath = $reportPaths.JsonPath
    ControlPhaseAccumulationProbeMarkdownPath = $reportPaths.MarkdownPath
    ProbeVerdict = $report.probe_verdict
    ReadinessForFullStrongSignalControlTreatmentAttempt = $report.readiness_for_full_strong_signal_control_treatment_attempt
}
