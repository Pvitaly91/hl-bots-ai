[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [switch]$UseLatest
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

function Resolve-RootArgument {
    param([string]$Path)

    $resolved = Resolve-ExistingPath -Path (Resolve-NormalizedPathCandidate -Path $Path)
    if ($resolved) {
        return $resolved
    }

    $normalized = Resolve-NormalizedPathCandidate -Path $Path
    if (-not $normalized) {
        return ""
    }

    if (Test-Path -LiteralPath $normalized -PathType Leaf) {
        return Split-Path -Path $normalized -Parent
    }

    return ""
}

function Get-PairRootAnchorUtc {
    param([string]$ResolvedPairRoot)

    $name = Split-Path -Path $ResolvedPairRoot -Leaf
    if ($name -match '^(?<stamp>\d{8}-\d{6})') {
        try {
            $localTime = [datetime]::ParseExact($Matches["stamp"], "yyyyMMdd-HHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
            return $localTime.ToUniversalTime()
        }
        catch {
        }
    }

    $item = Get-Item -LiteralPath $ResolvedPairRoot
    return $item.LastWriteTimeUtc
}

function Resolve-LatestPairRoot {
    param([string]$EvalRoot)

    if ([string]::IsNullOrWhiteSpace($EvalRoot) -or -not (Test-Path -LiteralPath $EvalRoot)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $EvalRoot -Directory |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Get-LaneRoot {
    param(
        [string]$ResolvedPairRoot,
        [string]$Lane
    )

    $laneContainer = Join-Path $ResolvedPairRoot ("lanes\{0}" -f $Lane.ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $laneContainer)) {
        return ""
    }

    $laneRoot = Get-ChildItem -LiteralPath $laneContainer -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $laneRoot) {
        return ""
    }

    return $laneRoot.FullName
}

function Get-ConnectionEvidence {
    param([string]$HldsStdoutLogPath)

    $resolvedLogPath = Resolve-ExistingPath -Path $HldsStdoutLogPath
    $connectedLines = New-Object System.Collections.Generic.List[string]
    $enteredLines = New-Object System.Collections.Generic.List[string]

    if ($resolvedLogPath) {
        foreach ($line in @(Get-Content -LiteralPath $resolvedLogPath)) {
            if ($line -match 'STEAM_ID_LAN' -and $line -match 'connected, address') {
                $connectedLines.Add($line) | Out-Null
            }

            if ($line -match 'STEAM_ID_LAN' -and $line -match 'entered the game') {
                $enteredLines.Add($line) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        log_path = $resolvedLogPath
        connected_lines = @($connectedLines.ToArray())
        entered_lines = @($enteredLines.ToArray())
    }
}

function Get-HldsLineTimestampUtcString {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return ""
    }

    if ($Line -match '^L\s+(?<month>\d{2})/(?<day>\d{2})/(?<year>\d{4})\s+-\s+(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}):') {
        try {
            $localTime = Get-Date -Year ([int]$Matches["year"]) -Month ([int]$Matches["month"]) -Day ([int]$Matches["day"]) `
                -Hour ([int]$Matches["hour"]) -Minute ([int]$Matches["minute"]) -Second ([int]$Matches["second"])
            return $localTime.ToUniversalTime().ToString("o")
        }
        catch {
            return ""
        }
    }

    return ""
}

function Get-ClosestFileByTime {
    param(
        [string]$Root,
        [string]$Filter,
        [datetime]$TargetUtc,
        [int]$WindowMinutes = 15
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter $Filter -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                path = $_.FullName
                delta = [math]::Abs(($_.LastWriteTimeUtc - $TargetUtc).TotalMinutes)
            }
        } |
        Where-Object { $_.delta -le $WindowMinutes } |
        Sort-Object delta |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return [string]$candidate.path
}

function Get-RunnerStageTimestampUtcString {
    param(
        [string]$RunnerStdoutPath,
        [string]$Stage,
        [datetime]$PairAnchorUtc
    )

    $resolvedPath = Resolve-ExistingPath -Path $RunnerStdoutPath
    if (-not $resolvedPath) {
        return ""
    }

    foreach ($line in @(Get-Content -LiteralPath $resolvedPath)) {
        if ($line -match '^\[(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})\]\s+(?<stage>.+)$') {
            if ([string]$Matches["stage"] -eq $Stage) {
                try {
                    $localDate = [datetime]::SpecifyKind($PairAnchorUtc.ToLocalTime().Date, [System.DateTimeKind]::Local)
                    $localTime = Get-Date -Year $localDate.Year -Month $localDate.Month -Day $localDate.Day `
                        -Hour ([int]$Matches["hour"]) -Minute ([int]$Matches["minute"]) -Second ([int]$Matches["second"])
                    return $localTime.ToUniversalTime().ToString("o")
                }
                catch {
                    return ""
                }
            }
        }
    }

    return ""
}

function Get-LastRunnerTimestampUtcString {
    param(
        [string]$RunnerStdoutPath,
        [datetime]$PairAnchorUtc
    )

    $resolvedPath = Resolve-ExistingPath -Path $RunnerStdoutPath
    if (-not $resolvedPath) {
        return ""
    }

    $lastTimestamp = ""
    foreach ($line in @(Get-Content -LiteralPath $resolvedPath)) {
        if ($line -match '^\[(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})\]') {
            try {
                $localDate = [datetime]::SpecifyKind($PairAnchorUtc.ToLocalTime().Date, [System.DateTimeKind]::Local)
                $localTime = Get-Date -Year $localDate.Year -Month $localDate.Month -Day $localDate.Day `
                    -Hour ([int]$Matches["hour"]) -Minute ([int]$Matches["minute"]) -Second ([int]$Matches["second"])
                $lastTimestamp = $localTime.ToUniversalTime().ToString("o")
            }
            catch {
            }
        }
    }

    return $lastTimestamp
}

function New-StageRecord {
    param(
        [string]$Verdict,
        [string[]]$EvidenceFound,
        [string[]]$EvidenceMissing,
        [string]$Explanation
    )

    return [ordered]@{
        verdict = $Verdict
        evidence_found = @($EvidenceFound | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        evidence_missing = @($EvidenceMissing | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        explanation = $Explanation
    }
}

function Get-AuditMarkdown {
    param([object]$Audit)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Full Session Handoff Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Verdict: $($Audit.handoff_verdict)") | Out-Null
    $lines.Add("- Explanation: $($Audit.explanation)") | Out-Null
    $lines.Add("- Pair root: $($Audit.pair_root)") | Out-Null
    $lines.Add("- Control became ready at: $($Audit.handoff_timing.control_became_ready_at_utc)") | Out-Null
    $lines.Add("- Runner observed control-ready at: $($Audit.handoff_timing.runner_observed_control_ready_at_utc)") | Out-Null
    $lines.Add("- Treatment join requested at: $($Audit.handoff_timing.treatment_join_requested_at_utc)") | Out-Null
    $lines.Add("- Treatment join launched at: $($Audit.handoff_timing.treatment_join_launched_at_utc)") | Out-Null
    $lines.Add("- Treatment evidence first appeared at: $($Audit.handoff_timing.treatment_evidence_first_appeared_at_utc)") | Out-Null
    $lines.Add("- Closeout wait started at: $($Audit.handoff_timing.closeout_wait_began_at_utc)") | Out-Null
    $lines.Add("- Session exit observed at: $($Audit.handoff_timing.session_exit_observed_at_utc)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Stages") | Out-Null
    $lines.Add("") | Out-Null

    foreach ($name in @("control_ready", "treatment_join", "treatment_phase", "closeout")) {
        $stage = Get-ObjectPropertyValue -Object $Audit.stages -Name $name -Default $null
        if ($null -eq $stage) {
            continue
        }

        $lines.Add("### $name") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("- Verdict: $($stage.verdict)") | Out-Null
        $lines.Add("- Explanation: $($stage.explanation)") | Out-Null
        if (@($stage.evidence_found).Count -gt 0) {
            $lines.Add("- Evidence found:") | Out-Null
            foreach ($item in @($stage.evidence_found)) {
                $lines.Add("  - $item") | Out-Null
            }
        }
        if (@($stage.evidence_missing).Count -gt 0) {
            $lines.Add("- Evidence missing:") | Out-Null
            foreach ($item in @($stage.evidence_missing)) {
                $lines.Add("  - $item") | Out-Null
            }
        }
        $lines.Add("") | Out-Null
    }

    $lines.Add("## Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Mission execution JSON: $($Audit.artifacts.mission_execution_json)") | Out-Null
    $lines.Add("- Session state JSON: $($Audit.artifacts.session_state_json)") | Out-Null
    $lines.Add("- Control-to-treatment switch JSON: $($Audit.artifacts.control_to_treatment_switch_json)") | Out-Null
    $lines.Add("- Conservative phase flow JSON: $($Audit.artifacts.conservative_phase_flow_json)") | Out-Null
    $lines.Add("- Treatment patch window JSON: $($Audit.artifacts.treatment_patch_window_json)") | Out-Null
    $lines.Add("- Live monitor status JSON: $($Audit.artifacts.live_monitor_status_json)") | Out-Null
    $lines.Add("- Pair summary JSON: $($Audit.artifacts.pair_summary_json)") | Out-Null
    $lines.Add("- Final session docket JSON: $($Audit.artifacts.final_session_docket_json)") | Out-Null
    $lines.Add("- Runner stdout log: $($Audit.artifacts.runner_stdout_log)") | Out-Null
    $lines.Add("- Runner stderr log: $($Audit.artifacts.runner_stderr_log)") | Out-Null
    $lines.Add("- First grounded attempt JSON: $($Audit.artifacts.first_grounded_attempt_json)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ($LabRoot) { Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot } else { Get-LabRootDefault }
$resolvedEvalRoot = Ensure-Directory -Path (Join-Path $resolvedLabRoot "logs\eval")
$resolvedFullRoot = Ensure-Directory -Path (Join-Path $resolvedEvalRoot "ssca53-live")

$resolvedPairRoot = if ($UseLatest) {
    Resolve-LatestPairRoot -EvalRoot $resolvedFullRoot
}
else {
    Resolve-RootArgument -Path $PairRoot
}

if (-not $resolvedPairRoot) {
    throw "Could not resolve a full-session pair root. Pass -PairRoot or use -UseLatest."
}

$pairAnchorUtc = Get-PairRootAnchorUtc -ResolvedPairRoot $resolvedPairRoot
$auditRoot = if ($OutputRoot) {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
else {
    $resolvedPairRoot
}

$controlLaneRoot = Get-LaneRoot -ResolvedPairRoot $resolvedPairRoot -Lane "Control"
$treatmentLaneRoot = Get-LaneRoot -ResolvedPairRoot $resolvedPairRoot -Lane "Treatment"
$controlSummaryPath = Resolve-ExistingPath -Path (Join-Path $controlLaneRoot "summary.json")
$treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json")
$controlSummary = Read-JsonFile -Path $controlSummaryPath
$treatmentSummary = Read-JsonFile -Path $treatmentSummaryPath
$missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\mission_execution.json")
$sessionStatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\session_state.json")
$finalSessionDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\final_session_docket.json")
$switchPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "control_to_treatment_switch.json")
$phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "conservative_phase_flow.json")
$patchWindowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "treatment_patch_window.json")
$liveMonitorPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")

$switchReport = Read-JsonFile -Path $switchPath
$phaseFlowReport = Read-JsonFile -Path $phaseFlowPath
$patchWindowReport = Read-JsonFile -Path $patchWindowPath
$liveMonitorReport = Read-JsonFile -Path $liveMonitorPath
$sessionState = Read-JsonFile -Path $sessionStatePath

$supportRoot = Split-Path -Path $resolvedPairRoot -Parent
$runnerStdoutPath = Get-ClosestFileByTime -Root $supportRoot -Filter "human_participation_attempt-*.stdout.log" -TargetUtc $pairAnchorUtc
$runnerStderrPath = Get-ClosestFileByTime -Root $supportRoot -Filter "human_participation_attempt-*.stderr.log" -TargetUtc $pairAnchorUtc
$firstGroundedFallbackRoot = Ensure-Directory -Path (Join-Path $resolvedEvalRoot "registry\first_grounded_conservative_attempt")
$firstGroundedAttemptJsonPath = Get-ClosestFileByTime -Root $firstGroundedFallbackRoot -Filter "attempt-*.json" -TargetUtc $pairAnchorUtc
$firstGroundedAttemptReport = Read-JsonFile -Path $firstGroundedAttemptJsonPath
$humanAttemptReport = Read-JsonFile -Path (Join-Path $resolvedPairRoot "human_participation_conservative_attempt.json")

$controlConnectionEvidence = Get-ConnectionEvidence -HldsStdoutLogPath (Join-Path $controlLaneRoot "hlds.stdout.log")
$treatmentConnectionEvidence = Get-ConnectionEvidence -HldsStdoutLogPath (Join-Path $treatmentLaneRoot "hlds.stdout.log")

$controlReadyBySwitch = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $switchReport -Name "control_lane" -Default $null) -Name "safe_to_leave" -Default $false)
$controlReadyByPhaseFlow = [bool](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "switch_to_treatment_allowed" -Default $false)
$treatmentStageObservedAtUtc = Get-RunnerStageTimestampUtcString -RunnerStdoutPath $runnerStdoutPath -Stage "waiting-for-treatment-human-signal" -PairAnchorUtc $pairAnchorUtc
$runnerObservedControlReady = $controlReadyByPhaseFlow -or -not [string]::IsNullOrWhiteSpace($treatmentStageObservedAtUtc) -or [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_switch_guidance" -Default $null) -Name "ready_to_leave_observed" -Default $false)

$controlReadyAtUtc = [string](Get-ObjectPropertyValue -Object $switchReport -Name "generated_at_utc" -Default "")
if (-not $controlReadyAtUtc -and $controlReadyBySwitch) {
    $controlReadyAtUtc = Get-HldsLineTimestampUtcString -Line (@($controlConnectionEvidence.entered_lines)[-1])
}

$runnerObservedControlReadyAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_switch_guidance" -Default $null) -Name "ready_observed_at_utc" -Default "")
if (-not $runnerObservedControlReadyAtUtc) {
    $runnerObservedControlReadyAtUtc = $treatmentStageObservedAtUtc
}

$treatmentJoinRequestedAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_join" -Default $null) -Name "join_requested_at_utc" -Default "")
$treatmentJoinLaunchedAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_join" -Default $null) -Name "launch_started_at_utc" -Default "")
$treatmentEvidenceFirstAppearedAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_join" -Default $null) -Name "first_server_connection_seen_at_utc" -Default "")
if (-not $treatmentEvidenceFirstAppearedAtUtc) {
    $treatmentConnectedLines = @($treatmentConnectionEvidence.connected_lines)
    if ($treatmentConnectedLines.Count -gt 0) {
        $treatmentEvidenceFirstAppearedAtUtc = Get-HldsLineTimestampUtcString -Line $treatmentConnectedLines[0]
    }
}
if (-not $treatmentEvidenceFirstAppearedAtUtc) {
    $treatmentEvidenceFirstAppearedAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "first_human_seen_timestamp_utc" -Default "")
}

$closeoutWaitBeganAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "closeout" -Default $null) -Name "wait_started_at_utc" -Default "")
$sessionExitObservedAtUtc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "closeout" -Default $null) -Name "attempt_process_exit_observed_at_utc" -Default "")
if (-not $sessionExitObservedAtUtc) {
    $sessionExitObservedAtUtc = Get-LastRunnerTimestampUtcString -RunnerStdoutPath $runnerStdoutPath -PairAnchorUtc $pairAnchorUtc
}
if (-not $sessionExitObservedAtUtc) {
    $sessionExitObservedAtUtc = [string](Get-ObjectPropertyValue -Object $firstGroundedAttemptReport -Name "generated_at_utc" -Default "")
}

$treatmentJoinInvoked = -not [string]::IsNullOrWhiteSpace($treatmentJoinRequestedAtUtc) -or [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_join" -Default $null) -Name "attempted" -Default $false)
$treatmentPhaseStarted = -not [string]::IsNullOrWhiteSpace($treatmentStageObservedAtUtc) -or -not [string]::IsNullOrWhiteSpace($treatmentLaneRoot)
$treatmentEvidenceAppeared = @($treatmentConnectionEvidence.connected_lines).Count -gt 0 -or @($treatmentConnectionEvidence.entered_lines).Count -gt 0 -or [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "human_snapshots_count" -Default 0) -gt 0
$finalArtifactsProduced = [bool]($pairSummaryPath) -and [bool]($finalSessionDocketPath)
$closeoutRaced = -not $finalArtifactsProduced -and (-not [string]::IsNullOrWhiteSpace($resolvedPairRoot))
$controlSwitchVerdict = [string](Get-ObjectPropertyValue -Object $switchReport -Name 'current_switch_verdict' -Default '')
$controlActualSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $switchReport -Name 'control_lane' -Default $null) -Name 'actual_human_snapshots' -Default 0)
$controlActualHumanPresenceSeconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $switchReport -Name 'control_lane' -Default $null) -Name 'actual_human_presence_seconds' -Default 0.0)

$treatmentJoinInconclusiveFound = New-Object System.Collections.Generic.List[string]
if ($treatmentJoinInvoked) {
    $treatmentJoinInconclusiveFound.Add("Treatment join was requested.") | Out-Null
}
if ($treatmentJoinLaunchedAtUtc) {
    $treatmentJoinInconclusiveFound.Add("Treatment launch started at $treatmentJoinLaunchedAtUtc.") | Out-Null
}

$treatmentJoinInconclusiveMissing = New-Object System.Collections.Generic.List[string]
if (-not $treatmentJoinInvoked) {
    $treatmentJoinInconclusiveMissing.Add("No saved treatment join request was found.") | Out-Null
}

$treatmentPhaseMissingFound = New-Object System.Collections.Generic.List[string]
if ($treatmentJoinInvoked) {
    $treatmentPhaseMissingFound.Add("Treatment join was requested.") | Out-Null
}

$treatmentPhaseRacedFound = New-Object System.Collections.Generic.List[string]
if ($treatmentStageObservedAtUtc) {
    $treatmentPhaseRacedFound.Add("Runner entered waiting-for-treatment-human-signal at $treatmentStageObservedAtUtc.") | Out-Null
}
if ($treatmentLaneRoot) {
    $treatmentPhaseRacedFound.Add("Treatment lane root exists: $treatmentLaneRoot") | Out-Null
}

$treatmentPhaseRacedMissing = New-Object System.Collections.Generic.List[string]
if (-not $treatmentEvidenceAppeared) {
    $treatmentPhaseRacedMissing.Add("No treatment-side connected/entered-the-game evidence was captured.") | Out-Null
}
$treatmentPhaseRacedMissing.Add("No final pair_summary.json was produced.") | Out-Null
$treatmentPhaseRacedMissing.Add("No final_session_docket.json was produced.") | Out-Null

$closeoutRacedFound = New-Object System.Collections.Generic.List[string]
$closeoutRacedFound.Add("Pair root exists: $resolvedPairRoot") | Out-Null
if ($sessionStatePath) {
    $closeoutRacedFound.Add("Session state remained at $sessionStatePath.") | Out-Null
}
if ($firstGroundedAttemptJsonPath) {
    $closeoutRacedFound.Add("Fallback first-grounded report exists: $firstGroundedAttemptJsonPath") | Out-Null
}

$controlReadyStage = if (-not ($controlReadyBySwitch -or $controlReadyByPhaseFlow)) {
    New-StageRecord -Verdict "control-never-became-ready" `
        -EvidenceFound @() `
        -EvidenceMissing @("No authoritative control-ready switch artifact was found.") `
        -Explanation "The saved switch and phase-flow artifacts never showed control as safe to leave."
}
elseif (-not $runnerObservedControlReady) {
    New-StageRecord -Verdict "control-ready-not-observed-by-runner" `
        -EvidenceFound @(
            "control_to_treatment_switch.json reached '$controlSwitchVerdict'.",
            "Control snapshots / seconds reached $controlActualSnapshots / $controlActualHumanPresenceSeconds."
        ) `
        -EvidenceMissing @("No runner-side handoff observation timestamp was captured.") `
        -Explanation "Authoritative control-ready evidence exists, but the full wrapper did not persist a matching ready-observed marker."
}
else {
    New-StageRecord -Verdict "control-ready-observed" `
        -EvidenceFound @(
            "Control-ready artifacts were present.",
            "Runner treatment-stage observation appeared at $runnerObservedControlReadyAtUtc."
        ) `
        -EvidenceMissing @() `
        -Explanation "The full chain reached a real control-ready transition."
}

$treatmentJoinStage = if ($runnerObservedControlReady -and -not $treatmentJoinInvoked) {
    New-StageRecord -Verdict "control-ready-observed-but-treatment-join-not-invoked" `
        -EvidenceFound @(
            "Control-ready was observed by the session chain.",
            "Treatment lane root exists: $treatmentLaneRoot"
        ) `
        -EvidenceMissing @("No treatment join request timestamp was saved.", "No treatment join launch timestamp was saved.") `
        -Explanation "The full workflow advanced to treatment waiting, but no local treatment join invocation was captured."
}
elseif ($treatmentJoinInvoked -and [string]::IsNullOrWhiteSpace($treatmentJoinLaunchedAtUtc)) {
    New-StageRecord -Verdict "treatment-join-invoked-but-no-treatment-phase" `
        -EvidenceFound @("Treatment join was requested.") `
        -EvidenceMissing @("No treatment launch timestamp was saved.", "No treatment server admission evidence was captured.") `
        -Explanation "The runner requested treatment join, but there is no proof that the local client launch completed."
}
else {
    New-StageRecord -Verdict "treatment-join-stage-inconclusive" `
        -EvidenceFound @($treatmentJoinInconclusiveFound.ToArray()) `
        -EvidenceMissing @($treatmentJoinInconclusiveMissing.ToArray()) `
        -Explanation "Treatment join evidence is partial and should be read together with treatment-phase and closeout stages."
}

$treatmentPhaseStage = if (-not $treatmentPhaseStarted) {
    New-StageRecord -Verdict "treatment-join-invoked-but-no-treatment-phase" `
        -EvidenceFound @($treatmentPhaseMissingFound.ToArray()) `
        -EvidenceMissing @("No treatment-phase stage transition was found in the runner log.", "No treatment lane root was materialized.") `
        -Explanation "The full run never showed a trustworthy treatment phase."
}
elseif (-not $finalArtifactsProduced) {
    New-StageRecord -Verdict "treatment-phase-started-but-closeout-raced" `
        -EvidenceFound @($treatmentPhaseRacedFound.ToArray()) `
        -EvidenceMissing @($treatmentPhaseRacedMissing.ToArray()) `
        -Explanation "The session advanced out of control, but the full pair never finished clean closeout."
}
else {
    New-StageRecord -Verdict "treatment-phase-complete" `
        -EvidenceFound @("Treatment phase started.", "Final pair artifacts were produced.") `
        -EvidenceMissing @() `
        -Explanation "Treatment phase reached a clean closeout."
}

$closeoutStage = if ($closeoutRaced) {
    New-StageRecord -Verdict "closeout-raced-before-final-artifacts" `
        -EvidenceFound @($closeoutRacedFound.ToArray()) `
        -EvidenceMissing @("pair_summary.json", "guided_session\\final_session_docket.json", "grounded_evidence_certificate.json") `
        -Explanation ([string](Get-ObjectPropertyValue -Object $firstGroundedAttemptReport -Name "explanation" -Default "The full session exited before the final closeout artifacts were written."))
}
else {
    New-StageRecord -Verdict "handoff-chain-complete" `
        -EvidenceFound @("pair_summary.json is present.", "guided_session\\final_session_docket.json is present.") `
        -EvidenceMissing @() `
        -Explanation "The full session reached final artifacts without a visible closeout race."
}

$handoffVerdict = if ($controlReadyStage.verdict -eq "control-never-became-ready") {
    "control-never-became-ready"
}
elseif ($treatmentJoinStage.verdict -eq "control-ready-observed-but-treatment-join-not-invoked") {
    "control-ready-observed-but-treatment-join-not-invoked"
}
elseif ($treatmentPhaseStage.verdict -eq "treatment-join-invoked-but-no-treatment-phase") {
    "treatment-join-invoked-but-no-treatment-phase"
}
elseif ($treatmentPhaseStage.verdict -eq "treatment-phase-started-but-closeout-raced") {
    "treatment-phase-started-but-closeout-raced"
}
elseif ($closeoutStage.verdict -eq "closeout-raced-before-final-artifacts") {
    "closeout-raced-before-final-artifacts"
}
elseif ($finalArtifactsProduced) {
    "handoff-chain-complete"
}
else {
    "inconclusive-manual-review"
}

$explanation = switch ($handoffVerdict) {
    "control-never-became-ready" {
        "The full pair never produced authoritative control-ready evidence, so treatment handoff was never justified."
    }
    "control-ready-observed-but-treatment-join-not-invoked" {
        "Control-ready evidence existed and the pair advanced to treatment waiting, but no local treatment join invocation was captured before the session drifted into truncated closeout."
    }
    "treatment-join-invoked-but-no-treatment-phase" {
        "Treatment join was requested, but no trustworthy treatment phase ever appeared."
    }
    "treatment-phase-started-but-closeout-raced" {
        "The full run moved into treatment-stage waiting, but the closeout stack ended without final pair artifacts."
    }
    "closeout-raced-before-final-artifacts" {
        "The pair root exists, but the full closeout stack ended before final artifacts were written."
    }
    "handoff-chain-complete" {
        "The full handoff chain reached treatment and produced final closeout artifacts."
    }
    default {
        "The saved evidence does not isolate a single trustworthy handoff break point."
    }
}

$audit = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $resolvedPairRoot
    handoff_verdict = $handoffVerdict
    narrowest_confirmed_break_point = $handoffVerdict
    explanation = $explanation
    handoff_timing = [ordered]@{
        control_became_ready_at_utc = $controlReadyAtUtc
        runner_observed_control_ready_at_utc = $runnerObservedControlReadyAtUtc
        treatment_join_requested_at_utc = $treatmentJoinRequestedAtUtc
        treatment_join_launched_at_utc = $treatmentJoinLaunchedAtUtc
        treatment_phase_started_at_utc = $treatmentStageObservedAtUtc
        treatment_evidence_first_appeared_at_utc = $treatmentEvidenceFirstAppearedAtUtc
        closeout_wait_began_at_utc = $closeoutWaitBeganAtUtc
        session_exit_observed_at_utc = $sessionExitObservedAtUtc
    }
    comparison = [ordered]@{
        control_ready_in_switch_artifact = $controlReadyBySwitch
        control_ready_in_phase_flow = $controlReadyByPhaseFlow
        runner_observed_control_ready = $runnerObservedControlReady
        treatment_join_invoked = $treatmentJoinInvoked
        treatment_phase_started = $treatmentPhaseStarted
        treatment_evidence_appeared = $treatmentEvidenceAppeared
        final_artifacts_produced = $finalArtifactsProduced
    }
    stages = [ordered]@{
        control_ready = $controlReadyStage
        treatment_join = $treatmentJoinStage
        treatment_phase = $treatmentPhaseStage
        closeout = $closeoutStage
    }
    artifacts = [ordered]@{
        mission_execution_json = $missionExecutionPath
        session_state_json = $sessionStatePath
        control_to_treatment_switch_json = $switchPath
        conservative_phase_flow_json = $phaseFlowPath
        treatment_patch_window_json = $patchWindowPath
        live_monitor_status_json = $liveMonitorPath
        pair_summary_json = $pairSummaryPath
        final_session_docket_json = $finalSessionDocketPath
        runner_stdout_log = $runnerStdoutPath
        runner_stderr_log = $runnerStderrPath
        first_grounded_attempt_json = $firstGroundedAttemptJsonPath
        control_summary_json = $controlSummaryPath
        treatment_summary_json = $treatmentSummaryPath
    }
    control_lane = [ordered]@{
        lane_root = $controlLaneRoot
        summary_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSummary -Name "primary_lane" -Default $null) -Name "lane_quality_verdict" -Default "")
        human_snapshots_count = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSummary -Name "primary_lane" -Default $null) -Name "human_snapshots_count" -Default 0)
        seconds_with_human_presence = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSummary -Name "primary_lane" -Default $null) -Name "seconds_with_human_presence" -Default 0.0)
        connected_lines = @($controlConnectionEvidence.connected_lines)
        entered_lines = @($controlConnectionEvidence.entered_lines)
    }
    treatment_lane = [ordered]@{
        lane_root = $treatmentLaneRoot
        summary_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "lane_quality_verdict" -Default "")
        human_snapshots_count = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "human_snapshots_count" -Default 0)
        seconds_with_human_presence = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "seconds_with_human_presence" -Default 0.0)
        connected_lines = @($treatmentConnectionEvidence.connected_lines)
        entered_lines = @($treatmentConnectionEvidence.entered_lines)
    }
}

$jsonPath = Join-Path $auditRoot "full_session_handoff_audit.json"
$markdownPath = Join-Path $auditRoot "full_session_handoff_audit.md"
$markdown = Get-AuditMarkdown -Audit $audit

Write-JsonFile -Path $jsonPath -Value $audit
Write-TextFile -Path $markdownPath -Value $markdown

Write-Host "Full-session handoff audit:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Handoff verdict: $handoffVerdict"
Write-Host "  Audit JSON: $jsonPath"
Write-Host "  Audit Markdown: $markdownPath"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    FullSessionHandoffAuditJsonPath = $jsonPath
    FullSessionHandoffAuditMarkdownPath = $markdownPath
    HandoffVerdict = $handoffVerdict
}
