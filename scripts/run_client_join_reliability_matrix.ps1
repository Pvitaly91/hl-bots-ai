[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Attempts = 3,
    [string]$ClientExePath = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [Alias("Port")]
    [int]$ControlPort = 27016,
    [int]$AttemptSpacingSeconds = 5,
    [int]$TimeoutSeconds = 180,
    [switch]$UseLatestMissionContext,
    [string]$LabRoot = "",
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$DurationSeconds = 20,
    [int]$HumanJoinGraceSeconds = 60,
    [int]$MinHumanSnapshots = 1,
    [int]$MinHumanPresenceSeconds = 10,
    [int]$JoinDelaySeconds = 5,
    [int]$PollSeconds = 2,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 64
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

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Find-LatestProbeReportPath {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath) -or -not (Test-Path -LiteralPath $RootPath)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $RootPath -Filter "client_join_completion_probe.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function New-UniqueDirectoryPath {
    param(
        [string]$ParentPath,
        [string]$LeafName
    )

    $attempt = 0
    while ($true) {
        $candidateLeaf = if ($attempt -le 0) { $LeafName } else { "{0}-r{1}" -f $LeafName, $attempt }
        $candidatePath = Join-Path $ParentPath $candidateLeaf
        if (-not (Test-Path -LiteralPath $candidatePath)) {
            return (Ensure-Directory -Path $candidatePath)
        }

        $attempt += 1
    }
}

function Convert-ToLaneSlug {
    param([string]$Value)

    $sourceValue = if ($null -eq $Value) { "" } else { $Value }
    $slug = $sourceValue.Trim().ToLowerInvariant()
    if (-not $slug) {
        return ""
    }

    $slug = [regex]::Replace($slug, "[^a-z0-9]+", "-")
    $slug = $slug.Trim("-")
    if ($slug.Length -gt 32) {
        $slug = $slug.Substring(0, 32).Trim("-")
    }

    return $slug
}

function Get-CompactMatrixLeafName {
    param(
        [string]$Map,
        [int]$BotCount,
        [int]$BotSkill,
        [int]$ControlPort
    )

    return "{0}-jrm-{1}-b{2}-s{3}-p{4}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), (Convert-ToLaneSlug -Value $Map), $BotCount, $BotSkill, $ControlPort
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

function Get-BoolString {
    param([bool]$Value)

    if ($Value) {
        return "yes"
    }

    return "no"
}

function Get-CountMap {
    param([object[]]$Values)

    $counts = [ordered]@{}
    foreach ($value in @($Values)) {
        $key = [string]$value
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = "(blank)"
        }

        if (-not $counts.Contains($key)) {
            $counts[$key] = 0
        }

        $counts[$key] = [int]$counts[$key] + 1
    }

    return [pscustomobject]$counts
}

function Get-LatestMissionContext {
    param([string]$RegistryRoot)

    $candidates = @(
        (Join-Path $RegistryRoot "strong_signal_conservative_mission.json"),
        (Join-Path $RegistryRoot "next_live_session_mission.json")
    )

    foreach ($candidate in $candidates) {
        $resolved = Resolve-ExistingPath -Path $candidate
        if ($resolved) {
            $payload = Read-JsonFile -Path $resolved
            return [pscustomobject]@{
                path = $resolved
                payload = $payload
            }
        }
    }

    return [pscustomobject]@{
        path = ""
        payload = $null
    }
}

function Get-AttemptVerdict {
    param([object]$ProbeReport)

    if ($null -eq $ProbeReport) {
        return "inconclusive-manual-review"
    }

    $clientDiscovered = [bool](Get-ObjectPropertyValue -Object $ProbeReport.stages.client_discovered -Name "reached" -Default $false)
    $clientLaunched = [bool](Get-ObjectPropertyValue -Object $ProbeReport.stages.client_process_launched -Name "reached" -Default $false)
    $serverConnectionSeen = [bool](Get-ObjectPropertyValue -Object $ProbeReport.final_metrics -Name "server_connection_seen" -Default $false)
    $enteredTheGameSeen = [bool](Get-ObjectPropertyValue -Object $ProbeReport.final_metrics -Name "entered_the_game_seen" -Default $false)
    $firstHumanSnapshotSeen = [bool](Get-ObjectPropertyValue -Object $ProbeReport.final_metrics -Name "first_human_snapshot_seen" -Default $false)
    $humanPresenceAccumulating = [bool](Get-ObjectPropertyValue -Object $ProbeReport.final_metrics -Name "human_presence_accumulating" -Default $false)
    $laneRoot = [string](Get-ObjectPropertyValue -Object $ProbeReport -Name "lane_root" -Default "")
    $hldsStdoutLog = [string](Get-ObjectPropertyValue -Object $ProbeReport.artifacts -Name "hlds_stdout_log" -Default "")

    if (-not $clientLaunched -and -not $serverConnectionSeen) {
        return "client-not-launched"
    }

    if ($clientLaunched -and -not $serverConnectionSeen -and -not $laneRoot -and -not $hldsStdoutLog) {
        return "client-launched-process-only"
    }

    if ($clientLaunched -and -not $serverConnectionSeen) {
        return "client-launched-but-no-server-connect"
    }

    if ($serverConnectionSeen -and -not $enteredTheGameSeen) {
        return "client-connected-but-no-entered-game"
    }

    if ($enteredTheGameSeen -and -not $firstHumanSnapshotSeen) {
        return "entered-game-but-no-human-snapshot"
    }

    if ($firstHumanSnapshotSeen -and -not $humanPresenceAccumulating) {
        return "human-snapshot-seen-control-only"
    }

    if ($humanPresenceAccumulating) {
        return "human-presence-accumulating"
    }

    return "inconclusive-manual-review"
}

function Get-ReadinessAssessment {
    param(
        [object[]]$AttemptRows,
        [int]$MinimumAttemptsForReady = 3,
        [bool]$DryRunRequested = $false
    )

    $totalAttempts = @($AttemptRows).Count
    $enteredTheGameCount = @($AttemptRows | Where-Object { [bool]$_.entered_the_game_seen }).Count
    $firstHumanSnapshotCount = @($AttemptRows | Where-Object { [bool]$_.first_human_snapshot_seen }).Count
    $humanPresenceAccumulatingCount = @($AttemptRows | Where-Object { [bool]$_.human_presence_accumulating }).Count
    $controlLaneHumanUsableCount = @($AttemptRows | Where-Object { [bool]$_.control_lane_human_usable }).Count
    $budgetExceededCount = @($AttemptRows | Where-Object { [bool]$_.timed_out_budget }).Count

    $ready = $false
    $readinessVerdict = ""
    $recommendedNextAction = ""
    $confidenceNote = ""
    $explanation = ""

    if ($DryRunRequested -or $totalAttempts -le 0) {
        $readinessVerdict = "not-ready-repeat-join-hardening"
        $recommendedNextAction = "run-real-bounded-probes-before-any-full-strong-signal-session"
        $confidenceNote = "No real bounded join probe evidence was collected in this matrix run."
        $explanation = "Dry-run output is useful for command inspection, but it cannot certify the repaired join path as ready for another full strong-signal conservative session."
    }
    elseif (
        $totalAttempts -ge $MinimumAttemptsForReady -and
        $budgetExceededCount -eq 0 -and
        $enteredTheGameCount -eq $totalAttempts -and
        $firstHumanSnapshotCount -eq $totalAttempts -and
        $humanPresenceAccumulatingCount -eq $totalAttempts -and
        $controlLaneHumanUsableCount -eq $totalAttempts
    ) {
        $ready = $true
        $readinessVerdict = "ready-for-next-strong-signal-attempt"
        $recommendedNextAction = "another-strong-signal-conservative-attempt-is-justified"
        $confidenceNote = "The readiness bar requires every bounded attempt in this suite to reach entered-the-game, first-human-snapshot, accumulating presence, and control-lane-human-usable without overrunning the matrix budget."
        $explanation = "The repaired local client join path cleared the full bounded join-completion chain on every attempt in this matrix. That is strong enough to justify spending the next full strong-signal conservative session."
    }
    elseif ($humanPresenceAccumulatingCount -le 0) {
        $readinessVerdict = "not-ready-repeat-join-hardening"
        $recommendedNextAction = "repeat-join-hardening-before-any-full-strong-signal-session"
        $confidenceNote = "The matrix did not produce a single bounded attempt that accumulated saved human presence."
        $explanation = "Join reliability is still too weak for another full strong-signal conservative spend because none of the repeated bounded probes accumulated trustworthy saved human presence."
    }
    else {
        $readinessVerdict = "partially-reliable-repeat-bounded-probes"
        $recommendedNextAction = "repeat-bounded-probes-before-full-strong-signal-session"
        if ($totalAttempts -lt $MinimumAttemptsForReady) {
            $confidenceNote = "Every bounded probe must succeed across at least three attempts before the path is certified as ready."
        }
        else {
            $confidenceNote = "Some bounded attempts succeeded, but the suite still contains earlier-chain failures or budget overruns. That is better than a one-off success, but still not stable enough for a full live spend."
        }
        $explanation = "The repaired join path is no longer totally blocked, but the repeated bounded probes still show mixed reliability. One or more attempts reached accumulating human presence while at least one other attempt failed earlier in the chain or exceeded the allowed budget."
    }

    return [pscustomobject]@{
        ready_for_next_strong_signal_attempt = $ready
        readiness_verdict = $readinessVerdict
        recommended_next_action = $recommendedNextAction
        confidence_note = $confidenceNote
        explanation = $explanation
        readiness_policy = [pscustomobject]@{
            minimum_attempts_for_ready = $MinimumAttemptsForReady
            requires_every_attempt_entered_the_game = $true
            requires_every_attempt_first_human_snapshot = $true
            requires_every_attempt_human_presence_accumulating = $true
            requires_every_attempt_control_lane_human_usable = $true
            requires_zero_budget_overruns = $true
            mixed_results_verdict = "partially-reliable-repeat-bounded-probes"
            zero_accumulation_verdict = "not-ready-repeat-join-hardening"
        }
    }
}

function Get-MatrixMarkdown {
    param(
        [object]$Matrix,
        [object]$Certificate
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Client Join Reliability Matrix") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Matrix.prompt_id)") | Out-Null
    $lines.Add("- Matrix root: $($Matrix.matrix_root)") | Out-Null
    $lines.Add("- Total attempts: $($Matrix.aggregate.total_attempts)") | Out-Null
    $lines.Add("- Readiness verdict: $($Certificate.readiness_verdict)") | Out-Null
    $lines.Add("- Ready for next strong-signal attempt: $(Get-BoolString -Value ([bool]$Certificate.ready_for_next_strong_signal_attempt))") | Out-Null
    $lines.Add("- Recommended next action: $($Certificate.recommended_next_action)") | Out-Null
    $lines.Add("- Explanation: $($Certificate.explanation)") | Out-Null
    $lines.Add("- Confidence / caution note: $($Certificate.confidence_note)") | Out-Null
    $lines.Add("") | Out-Null

    if ($Matrix.mission_context.used_latest_mission_context) {
        $lines.Add("## Mission Context") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("- Mission context path: $($Matrix.mission_context.mission_path)") | Out-Null
        $lines.Add("- Mission kind: $($Matrix.mission_context.mission_kind)") | Out-Null
        $lines.Add("- Current next-live objective: $($Matrix.mission_context.current_next_live_objective)") | Out-Null
        $lines.Add("- Strong-signal target control snapshots: $($Matrix.mission_context.target_control_human_snapshots)") | Out-Null
        $lines.Add("- Strong-signal target control presence seconds: $($Matrix.mission_context.target_control_human_presence_seconds)") | Out-Null
        $lines.Add("") | Out-Null
    }

    $lines.Add("## Aggregate Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe lane launch attempted: $($Matrix.aggregate.startup_counts.lane_launch_attempted)") | Out-Null
    $lines.Add("- Lane root materialized: $($Matrix.aggregate.startup_counts.lane_root_materialized)") | Out-Null
    $lines.Add("- Port-ready attempts: $($Matrix.aggregate.startup_counts.port_ready)") | Out-Null
    $lines.Add("- Join-helper-invoked attempts: $($Matrix.aggregate.startup_counts.join_helper_invoked)") | Out-Null
    $lines.Add("- Entered-the-game successes: $($Matrix.aggregate.success_counts.entered_the_game)") | Out-Null
    $lines.Add("- First-human-snapshot successes: $($Matrix.aggregate.success_counts.first_human_snapshot)") | Out-Null
    $lines.Add("- Human-presence-accumulating successes: $($Matrix.aggregate.success_counts.human_presence_accumulating)") | Out-Null
    $lines.Add("- Control-lane-human-usable successes: $($Matrix.aggregate.success_counts.control_lane_human_usable)") | Out-Null
    $lines.Add("- Budget overruns: $($Matrix.aggregate.budget_exceeded_attempts)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("### Count By Final Attempt Verdict") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($property in $Matrix.aggregate.count_by_final_attempt_verdict.PSObject.Properties) {
        $lines.Add("- $($property.Name): $($property.Value)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("### Failure Count By Narrowest Confirmed Break Point") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($property in $Matrix.aggregate.failure_count_by_break_point.PSObject.Properties) {
        $lines.Add("- $($property.Name): $($property.Value)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Readiness Policy") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Minimum attempts for ready: $($Certificate.readiness_policy.minimum_attempts_for_ready)") | Out-Null
    $lines.Add("- Requires every attempt entered the game: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_entered_the_game))") | Out-Null
    $lines.Add("- Requires every attempt first human snapshot: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_first_human_snapshot))") | Out-Null
    $lines.Add("- Requires every attempt human presence accumulating: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_human_presence_accumulating))") | Out-Null
    $lines.Add("- Requires every attempt control lane human usable: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_control_lane_human_usable))") | Out-Null
    $lines.Add("- Requires zero budget overruns: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_zero_budget_overruns))") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Attempts") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Attempt | Final verdict | Lane root | Port ready | Join helper | Entered game | First human snapshot | Human presence accumulating | Control lane human usable | Budget exceeded | Probe root |") | Out-Null
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
    foreach ($attempt in @($Matrix.attempts)) {
        $lines.Add((
                "| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |" -f
                $attempt.attempt_index,
                $attempt.final_attempt_verdict,
                (Get-BoolString -Value ([bool]$attempt.lane_root_materialized)),
                (Get-BoolString -Value ([bool]$attempt.port_ready)),
                (Get-BoolString -Value ([bool]$attempt.join_helper_invoked)),
                (Get-BoolString -Value ([bool]$attempt.entered_the_game_seen)),
                (Get-BoolString -Value ([bool]$attempt.first_human_snapshot_seen)),
                (Get-BoolString -Value ([bool]$attempt.human_presence_accumulating)),
                (Get-BoolString -Value ([bool]$attempt.control_lane_human_usable)),
                (Get-BoolString -Value ([bool]$attempt.timed_out_budget)),
                $attempt.probe_root
            )) | Out-Null
    }
    $lines.Add("") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-CertificateMarkdown {
    param([object]$Certificate)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Client Join Reliability Certificate") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Certificate.prompt_id)") | Out-Null
    $lines.Add("- Readiness verdict: $($Certificate.readiness_verdict)") | Out-Null
    $lines.Add("- Ready for next strong-signal attempt: $(Get-BoolString -Value ([bool]$Certificate.ready_for_next_strong_signal_attempt))") | Out-Null
    $lines.Add("- Recommended next action: $($Certificate.recommended_next_action)") | Out-Null
    $lines.Add("- Explanation: $($Certificate.explanation)") | Out-Null
    $lines.Add("- Confidence / caution note: $($Certificate.confidence_note)") | Out-Null
    $lines.Add("- Total attempts: $($Certificate.total_attempts)") | Out-Null
    $lines.Add("- Human-presence-accumulating successes: $($Certificate.human_presence_accumulating_success_count)") | Out-Null
    $lines.Add("- Control-lane-human-usable successes: $($Certificate.control_lane_human_usable_success_count)") | Out-Null
    $lines.Add("- Budget overruns: $($Certificate.budget_exceeded_attempts)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Readiness Policy") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Minimum attempts for ready: $($Certificate.readiness_policy.minimum_attempts_for_ready)") | Out-Null
    $lines.Add("- Requires every attempt entered the game: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_entered_the_game))") | Out-Null
    $lines.Add("- Requires every attempt first human snapshot: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_first_human_snapshot))") | Out-Null
    $lines.Add("- Requires every attempt human presence accumulating: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_human_presence_accumulating))") | Out-Null
    $lines.Add("- Requires every attempt control lane human usable: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_every_attempt_control_lane_human_usable))") | Out-Null
    $lines.Add("- Requires zero budget overruns: $(Get-BoolString -Value ([bool]$Certificate.readiness_policy.requires_zero_budget_overruns))") | Out-Null
    $lines.Add("") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if ($Attempts -lt 1) {
    throw "Attempts must be at least 1."
}

$repoRoot = Get-RepoRoot
$promptId = Get-RepoPromptId
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $LabRoot)
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "join_reliability_matrices")
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $OutputRoot)
}

$matrixRootName = Get-CompactMatrixLeafName -Map $Map -BotCount $BotCount -BotSkill $BotSkill -ControlPort $ControlPort
$matrixRoot = New-UniqueDirectoryPath -ParentPath $resolvedOutputRoot -LeafName $matrixRootName
$attemptsRoot = Ensure-Directory -Path (Join-Path $matrixRoot "att")
$matrixJsonPath = Join-Path $matrixRoot "client_join_reliability_matrix.json"
$matrixMarkdownPath = Join-Path $matrixRoot "client_join_reliability_matrix.md"
$certificateJsonPath = Join-Path $matrixRoot "client_join_reliability_certificate.json"
$certificateMarkdownPath = Join-Path $matrixRoot "client_join_reliability_certificate.md"

$missionContext = [pscustomobject]@{
    used_latest_mission_context = [bool]$UseLatestMissionContext
    mission_path = ""
    mission_kind = ""
    current_next_live_objective = ""
    target_control_human_snapshots = $null
    target_control_human_presence_seconds = $null
}
if ($UseLatestMissionContext) {
    $resolvedMissionContext = Get-LatestMissionContext -RegistryRoot (Get-RegistryRootDefault -LabRoot $resolvedLabRoot)
    $missionPayload = $resolvedMissionContext.payload
    $missionContext = [pscustomobject]@{
        used_latest_mission_context = $true
        mission_path = [string]$resolvedMissionContext.path
        mission_kind = [string](Get-ObjectPropertyValue -Object $missionPayload -Name "mission_kind" -Default "")
        current_next_live_objective = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionPayload -Name "current_global_state" -Default $null) -Name "next_live_objective" -Default "")
        target_control_human_snapshots = Get-ObjectPropertyValue -Object $missionPayload -Name "target_minimum_control_human_snapshots" -Default $null
        target_control_human_presence_seconds = Get-ObjectPropertyValue -Object $missionPayload -Name "target_minimum_control_human_presence_seconds" -Default $null
    }
}

$probeScriptPath = Join-Path $PSScriptRoot "run_client_join_completion_probe.ps1"
$attemptRows = New-Object System.Collections.Generic.List[object]

for ($attemptIndex = 1; $attemptIndex -le $Attempts; $attemptIndex += 1) {
    $attemptLabel = "a{0:d2}" -f $attemptIndex
    $attemptOutputRoot = Ensure-Directory -Path (Join-Path $attemptsRoot $attemptLabel)
    $startedAtUtc = (Get-Date).ToUniversalTime()
    $probeResult = $null
    $probeReport = $null
    $exceptionMessage = ""

    Write-Host ("Running join reliability attempt {0}/{1}..." -f $attemptIndex, $Attempts)

    try {
        $probeResult = & $probeScriptPath `
            -ClientExePath $ClientExePath `
            -LabRoot $resolvedLabRoot `
            -OutputRoot $attemptOutputRoot `
            -Map $Map `
            -BotCount $BotCount `
            -BotSkill $BotSkill `
            -Port $ControlPort `
            -DurationSeconds $DurationSeconds `
            -HumanJoinGraceSeconds $HumanJoinGraceSeconds `
            -MinHumanSnapshots $MinHumanSnapshots `
            -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
            -JoinDelaySeconds $JoinDelaySeconds `
            -PollSeconds $PollSeconds `
            -DryRun:$DryRun
    }
    catch {
        $exceptionMessage = $_.Exception.Message
    }

    $probeJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeResult -Name "ClientJoinCompletionProbeJsonPath" -Default ""))
    if (-not $probeJsonPath) {
        $probeJsonPath = Resolve-ExistingPath -Path (Find-LatestProbeReportPath -RootPath $attemptOutputRoot)
    }
    $probeReport = Read-JsonFile -Path $probeJsonPath

    $completedAtUtc = (Get-Date).ToUniversalTime()
    $elapsedSeconds = [Math]::Round(($completedAtUtc - $startedAtUtc).TotalSeconds, 1)
    $timedOutBudget = ($TimeoutSeconds -gt 0) -and ($elapsedSeconds -gt [double]$TimeoutSeconds)

    $probeArtifacts = Get-ObjectPropertyValue -Object $probeReport -Name "artifacts" -Default $null
    $probeLaunchObservability = Get-ObjectPropertyValue -Object $probeReport -Name "launch_observability" -Default $null
    $probeReadinessObservability = Get-ObjectPropertyValue -Object $probeReport -Name "readiness_observability" -Default $null
    $probeStages = Get-ObjectPropertyValue -Object $probeReport -Name "stages" -Default $null
    $probeFinalMetrics = Get-ObjectPropertyValue -Object $probeReport -Name "final_metrics" -Default $null
    $probeClientProcessLaunchedStage = Get-ObjectPropertyValue -Object $probeStages -Name "client_process_launched" -Default $null

    $clientPath = [string](Get-ObjectPropertyValue -Object $probeLaunchObservability -Name "client_path" -Default "")
    $launchCommand = [string](Get-ObjectPropertyValue -Object $probeLaunchObservability -Name "launch_command" -Default "")
    $probeRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeReport -Name "probe_root" -Default ""))
    $finalAttemptVerdict = if ($probeReport) { Get-AttemptVerdict -ProbeReport $probeReport } else { "inconclusive-manual-review" }

    $attemptRows.Add([pscustomobject]@{
            attempt_index = $attemptIndex
            attempt_label = $attemptLabel
            started_at_utc = $startedAtUtc.ToString("o")
            completed_at_utc = $completedAtUtc.ToString("o")
            elapsed_seconds = $elapsedSeconds
            timed_out_budget = $timedOutBudget
            attempt_output_root = $attemptOutputRoot
            probe_root = $probeRoot
            probe_report_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeArtifacts -Name "client_join_completion_probe_json" -Default ""))
            probe_report_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeArtifacts -Name "client_join_completion_probe_markdown" -Default ""))
            discovered_client_path = $clientPath
            launch_command_used = $launchCommand
            probe_lane_launch_attempted = [bool](Get-ObjectPropertyValue -Object $probeLaunchObservability -Name "probe_lane_launch_attempted" -Default $false)
            lane_root_materialized = [bool](Get-ObjectPropertyValue -Object $probeReadinessObservability -Name "lane_root_materialized" -Default $false)
            port_ready = [bool](Get-ObjectPropertyValue -Object $probeReadinessObservability -Name "port_ready" -Default $false)
            join_helper_invoked = [bool](Get-ObjectPropertyValue -Object $probeReadinessObservability -Name "join_helper_invoked" -Default $false)
            client_process_launched = [bool](Get-ObjectPropertyValue -Object $probeClientProcessLaunchedStage -Name "reached" -Default $false)
            server_connection_seen = [bool](Get-ObjectPropertyValue -Object $probeFinalMetrics -Name "server_connection_seen" -Default $false)
            entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $probeFinalMetrics -Name "entered_the_game_seen" -Default $false)
            first_human_snapshot_seen = [bool](Get-ObjectPropertyValue -Object $probeFinalMetrics -Name "first_human_snapshot_seen" -Default $false)
            human_presence_accumulating = [bool](Get-ObjectPropertyValue -Object $probeFinalMetrics -Name "human_presence_accumulating" -Default $false)
            control_lane_human_usable = [bool](Get-ObjectPropertyValue -Object $probeFinalMetrics -Name "control_lane_human_usable" -Default $false)
            raw_probe_verdict = [string](Get-ObjectPropertyValue -Object $probeReport -Name "probe_verdict" -Default "")
            final_attempt_verdict = $finalAttemptVerdict
            narrowest_confirmed_break_point = [string](Get-ObjectPropertyValue -Object $probeReport -Name "narrowest_confirmed_break_point" -Default "")
            exception_message = $exceptionMessage
        }) | Out-Null

    if ($attemptIndex -lt $Attempts -and $AttemptSpacingSeconds -gt 0) {
        Start-Sleep -Seconds $AttemptSpacingSeconds
    }
}

$attemptsArray = @($attemptRows.ToArray())
$aggregate = [pscustomobject]@{
    total_attempts = $attemptsArray.Count
    count_by_final_attempt_verdict = Get-CountMap -Values ($attemptsArray | ForEach-Object { $_.final_attempt_verdict })
    count_by_raw_probe_verdict = Get-CountMap -Values ($attemptsArray | ForEach-Object { $_.raw_probe_verdict })
    startup_counts = [pscustomobject]@{
        lane_launch_attempted = @($attemptsArray | Where-Object { [bool]$_.probe_lane_launch_attempted }).Count
        lane_root_materialized = @($attemptsArray | Where-Object { [bool]$_.lane_root_materialized }).Count
        port_ready = @($attemptsArray | Where-Object { [bool]$_.port_ready }).Count
        join_helper_invoked = @($attemptsArray | Where-Object { [bool]$_.join_helper_invoked }).Count
    }
    success_counts = [pscustomobject]@{
        entered_the_game = @($attemptsArray | Where-Object { [bool]$_.entered_the_game_seen }).Count
        first_human_snapshot = @($attemptsArray | Where-Object { [bool]$_.first_human_snapshot_seen }).Count
        human_presence_accumulating = @($attemptsArray | Where-Object { [bool]$_.human_presence_accumulating }).Count
        control_lane_human_usable = @($attemptsArray | Where-Object { [bool]$_.control_lane_human_usable }).Count
    }
    failure_count_by_break_point = Get-CountMap -Values ($attemptsArray | Where-Object { -not [bool]$_.human_presence_accumulating } | ForEach-Object { $_.narrowest_confirmed_break_point })
    budget_exceeded_attempts = @($attemptsArray | Where-Object { [bool]$_.timed_out_budget }).Count
}

$readiness = Get-ReadinessAssessment -AttemptRows $attemptsArray -DryRunRequested ([bool]$DryRun)

$matrix = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    matrix_root = $matrixRoot
    attempts_root = $attemptsRoot
    dry_run = [bool]$DryRun
    mission_context = $missionContext
    run_settings = [ordered]@{
        attempts = $Attempts
        control_port = $ControlPort
        attempt_spacing_seconds = $AttemptSpacingSeconds
        timeout_seconds = $TimeoutSeconds
        map = $Map
        bot_count = $BotCount
        bot_skill = $BotSkill
        duration_seconds = $DurationSeconds
        human_join_grace_seconds = $HumanJoinGraceSeconds
        min_human_snapshots = $MinHumanSnapshots
        min_human_presence_seconds = $MinHumanPresenceSeconds
        join_delay_seconds = $JoinDelaySeconds
        poll_seconds = $PollSeconds
        client_exe_path_override = $ClientExePath
    }
    attempts = $attemptsArray
    aggregate = $aggregate
    readiness_verdict = $readiness.readiness_verdict
    confidence_note = $readiness.confidence_note
    recommended_next_action = $readiness.recommended_next_action
    explanation = $readiness.explanation
    artifacts = [ordered]@{
        client_join_reliability_matrix_json = $matrixJsonPath
        client_join_reliability_matrix_markdown = $matrixMarkdownPath
        client_join_reliability_certificate_json = $certificateJsonPath
        client_join_reliability_certificate_markdown = $certificateMarkdownPath
    }
}

$certificate = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    matrix_root = $matrixRoot
    total_attempts = $aggregate.total_attempts
    count_by_final_attempt_verdict = $aggregate.count_by_final_attempt_verdict
    success_counts = $aggregate.success_counts
    failure_count_by_break_point = $aggregate.failure_count_by_break_point
    budget_exceeded_attempts = $aggregate.budget_exceeded_attempts
    human_presence_accumulating_success_count = $aggregate.success_counts.human_presence_accumulating
    control_lane_human_usable_success_count = $aggregate.success_counts.control_lane_human_usable
    ready_for_next_strong_signal_attempt = $readiness.ready_for_next_strong_signal_attempt
    readiness_verdict = $readiness.readiness_verdict
    readiness_policy = $readiness.readiness_policy
    confidence_note = $readiness.confidence_note
    recommended_next_action = $readiness.recommended_next_action
    explanation = $readiness.explanation
}

Write-JsonFile -Path $matrixJsonPath -Value $matrix
$matrixForMarkdown = Read-JsonFile -Path $matrixJsonPath
Write-TextFile -Path $matrixMarkdownPath -Value (Get-MatrixMarkdown -Matrix $matrixForMarkdown -Certificate $certificate)
Write-JsonFile -Path $certificateJsonPath -Value $certificate
$certificateForMarkdown = Read-JsonFile -Path $certificateJsonPath
Write-TextFile -Path $certificateMarkdownPath -Value (Get-CertificateMarkdown -Certificate $certificateForMarkdown)

Write-Host "Client join reliability matrix:"
Write-Host "  Readiness verdict: $($certificate.readiness_verdict)"
Write-Host "  Recommended next action: $($certificate.recommended_next_action)"
Write-Host "  Matrix root: $matrixRoot"
Write-Host "  JSON: $matrixJsonPath"
Write-Host "  Markdown: $matrixMarkdownPath"
Write-Host "  Certificate JSON: $certificateJsonPath"
Write-Host "  Certificate Markdown: $certificateMarkdownPath"

[pscustomobject]@{
    ClientJoinReliabilityMatrixJsonPath = $matrixJsonPath
    ClientJoinReliabilityMatrixMarkdownPath = $matrixMarkdownPath
    ClientJoinReliabilityCertificateJsonPath = $certificateJsonPath
    ClientJoinReliabilityCertificateMarkdownPath = $certificateMarkdownPath
    MatrixRoot = $matrixRoot
    ReadinessVerdict = $certificate.readiness_verdict
    RecommendedNextAction = $certificate.recommended_next_action
}
