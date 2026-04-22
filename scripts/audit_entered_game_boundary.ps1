[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SuccessfulProbeRoot = "",
    [string[]]$FailedProbeRoots = @(),
    [switch]$UseLatest,
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
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

    $json = $Value | ConvertTo-Json -Depth 16
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

function Get-BoolString {
    param([bool]$Value)

    if ($Value) {
        return "yes"
    }

    return "no"
}

function Get-StageRecord {
    param(
        [string]$StageName,
        [string]$Verdict,
        [bool]$Reached,
        [object[]]$EvidenceFound,
        [object[]]$EvidenceMissing,
        [string]$Explanation
    )

    [pscustomobject]@{
        stage = $StageName
        verdict = $Verdict
        reached = $Reached
        evidence_found = @($EvidenceFound)
        evidence_missing = @($EvidenceMissing)
        explanation = $Explanation
    }
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

function Find-LatestSuccessfulProbeRoot {
    param([string]$EvalRoot)

    $searchRoots = @(
        (Join-Path $EvalRoot "join_reliability_matrices"),
        (Join-Path $EvalRoot "join_completion_probes"),
        $EvalRoot
    )

    foreach ($searchRoot in @($searchRoots)) {
        $resolvedSearchRoot = Resolve-ExistingPath -Path $searchRoot
        if (-not $resolvedSearchRoot) {
            continue
        }

        $candidates = Get-ChildItem -LiteralPath $resolvedSearchRoot -Filter "client_join_completion_probe.json" -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending

        foreach ($candidate in @($candidates)) {
            $payload = Read-JsonFile -Path $candidate.FullName
            if ([bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $payload -Name "final_metrics" -Default $null) -Name "entered_the_game_seen" -Default $false)) {
                return $candidate.DirectoryName
            }
        }
    }

    throw "No successful probe with entered-the-game evidence was found under $EvalRoot"
}

function Find-LatestFailedProbeRootsFromMatrix {
    param([string]$EvalRoot)

    $matrixCandidate = Get-ChildItem -LiteralPath $EvalRoot -Filter "client_join_reliability_matrix.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $matrixCandidate) {
        throw "No client_join_reliability_matrix.json was found under $EvalRoot"
    }

    $matrixPayload = Read-JsonFile -Path $matrixCandidate.FullName
    $probeRoots = New-Object System.Collections.Generic.List[string]
    foreach ($attempt in @(Get-ObjectPropertyValue -Object $matrixPayload -Name "attempts" -Default @())) {
        $enteredGameSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "entered_the_game_seen" -Default $false)
        if ($enteredGameSeen) {
            continue
        }

        $probeRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $attempt -Name "probe_root" -Default ""))
        if ($probeRoot) {
            $probeRoots.Add($probeRoot) | Out-Null
        }
    }

    if ($probeRoots.Count -le 0) {
        throw "The latest reliability matrix did not contain failed repeated probe roots."
    }

    return $probeRoots.ToArray()
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

function Get-SecondsBetween {
    param(
        [string]$EarlierUtc,
        [string]$LaterUtc
    )

    if (-not $EarlierUtc -or -not $LaterUtc) {
        return $null
    }

    try {
        return [Math]::Round((([datetime]$LaterUtc) - ([datetime]$EarlierUtc)).TotalSeconds, 1)
    }
    catch {
        return $null
    }
}

function Get-LaneReadyLeadSeconds {
    param(
        [string]$PortReadyAtUtc,
        [string]$LaneRootReadyAtUtc,
        [string]$LaunchStartedAtUtc
    )

    if (-not $LaunchStartedAtUtc -or -not $PortReadyAtUtc -or -not $LaneRootReadyAtUtc) {
        return $null
    }

    try {
        $latestReadyAtUtc = @([datetime]$PortReadyAtUtc, [datetime]$LaneRootReadyAtUtc) | Sort-Object -Descending | Select-Object -First 1
        return [Math]::Round((([datetime]$LaunchStartedAtUtc) - $latestReadyAtUtc).TotalSeconds, 1)
    }
    catch {
        return $null
    }
}

function Get-ProbeBoundaryRecord {
    param([string]$ProbeRoot)

    $resolvedProbeRoot = Resolve-ExistingPath -Path $ProbeRoot
    if (-not $resolvedProbeRoot) {
        throw "Probe root was not found: $ProbeRoot"
    }

    $probeReportPath = Resolve-ExistingPath -Path (Join-Path $resolvedProbeRoot "client_join_completion_probe.json")
    $probeReport = Read-JsonFile -Path $probeReportPath
    if ($null -eq $probeReport) {
        throw "Probe root does not contain a readable client_join_completion_probe.json: $resolvedProbeRoot"
    }

    $artifacts = Get-ObjectPropertyValue -Object $probeReport -Name "artifacts" -Default $null
    $launchObservability = Get-ObjectPropertyValue -Object $probeReport -Name "launch_observability" -Default $null
    $readinessObservability = Get-ObjectPropertyValue -Object $probeReport -Name "readiness_observability" -Default $null
    $finalMetrics = Get-ObjectPropertyValue -Object $probeReport -Name "final_metrics" -Default $null
    $qconsoleBefore = Get-ObjectPropertyValue -Object $probeReport -Name "qconsole_snapshot_before" -Default $null
    $qconsoleAfter = Get-ObjectPropertyValue -Object $probeReport -Name "qconsole_snapshot_after" -Default $null

    $hldsStdoutLogPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "hlds_stdout_log" -Default ""))
    $hldsStdoutLines = if ($hldsStdoutLogPath) { @(Get-Content -LiteralPath $hldsStdoutLogPath) } else { @() }
    $connectedLines = @($hldsStdoutLines | Where-Object { $_ -match 'connected, address' })
    $enteredGameLines = @($hldsStdoutLines | Where-Object { $_ -match 'entered the game' -and $_ -notmatch '<BOT>' })

    $joinAttempts = @(Get-ObjectPropertyValue -Object $launchObservability -Name "join_attempts" -Default @())
    $latestJoinAttempt = if ($joinAttempts.Count -gt 0) { $joinAttempts[$joinAttempts.Count - 1] } else { $null }
    $joinAttemptCount = [int](Get-ObjectPropertyValue -Object $launchObservability -Name "join_attempt_count" -Default $joinAttempts.Count)
    $launchStartedAtUtc = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "initial_launch_started_at_utc" -Default "")
    if (-not $launchStartedAtUtc) {
        $launchStartedAtUtc = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "launch_started_at_utc" -Default "")
    }

    $firstServerConnectionSeenAtUtc = [string](Get-ObjectPropertyValue -Object $finalMetrics -Name "first_server_connection_seen_at_utc" -Default "")
    if (-not $firstServerConnectionSeenAtUtc -and $connectedLines.Count -gt 0) {
        $firstServerConnectionSeenAtUtc = Get-HldsLineTimestampUtcString -Line $connectedLines[0]
    }

    $firstEnteredGameSeenAtUtc = [string](Get-ObjectPropertyValue -Object $finalMetrics -Name "first_entered_the_game_seen_at_utc" -Default "")
    if (-not $firstEnteredGameSeenAtUtc -and $enteredGameLines.Count -gt 0) {
        $firstEnteredGameSeenAtUtc = Get-HldsLineTimestampUtcString -Line $enteredGameLines[0]
    }

    $laneReadyLeadSeconds = Get-LaneReadyLeadSeconds `
        -PortReadyAtUtc ([string](Get-ObjectPropertyValue -Object $readinessObservability -Name "port_wait_finished_at_utc" -Default "")) `
        -LaneRootReadyAtUtc ([string](Get-ObjectPropertyValue -Object $readinessObservability -Name "lane_root_wait_finished_at_utc" -Default "")) `
        -LaunchStartedAtUtc $launchStartedAtUtc

    $laneReadyBeforeClientLaunch = $null -ne $laneReadyLeadSeconds -and $laneReadyLeadSeconds -ge 0
    $qconsoleChanged = (
        [string](Get-ObjectPropertyValue -Object $qconsoleBefore -Name "last_write_time_utc" -Default "") -ne
        [string](Get-ObjectPropertyValue -Object $qconsoleAfter -Name "last_write_time_utc" -Default "")
    ) -or (
        [int64](Get-ObjectPropertyValue -Object $qconsoleBefore -Name "length_bytes" -Default 0) -ne
        [int64](Get-ObjectPropertyValue -Object $qconsoleAfter -Name "length_bytes" -Default 0)
    )

    $clientExitsTooEarly = $false
    $clientObservedRuntimeSeconds = Get-ObjectPropertyValue -Object $latestJoinAttempt -Name "process_runtime_seconds" -Default $null
    foreach ($attempt in @($joinAttempts)) {
        if (
            [bool](Get-ObjectPropertyValue -Object $attempt -Name "exited_before_server_connect" -Default $false) -or
            [bool](Get-ObjectPropertyValue -Object $attempt -Name "exited_before_entered_game" -Default $false)
        ) {
            $clientExitsTooEarly = $true
            break
        }
    }

    return [pscustomobject]@{
        probe_root = $resolvedProbeRoot
        probe_report_json = $probeReportPath
        probe_verdict = [string](Get-ObjectPropertyValue -Object $probeReport -Name "probe_verdict" -Default "")
        client_discovery_verdict = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "client_discovery_verdict" -Default "")
        client_path = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "client_path" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "launch_command" -Default "")
        working_directory = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "client_working_directory" -Default "")
        launch_started_at_utc = $launchStartedAtUtc
        join_target = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "join_target" -Default "")
        client_process_id = [int](Get-ObjectPropertyValue -Object $launchObservability -Name "client_process_id" -Default 0)
        client_process_observed_duration_seconds = $clientObservedRuntimeSeconds
        client_process_appears_to_exit_too_early = $clientExitsTooEarly
        join_attempt_count = $joinAttemptCount
        join_retry_used = [bool](Get-ObjectPropertyValue -Object $launchObservability -Name "join_retry_used" -Default $false)
        join_retry_reason = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "join_retry_reason" -Default "")
        qconsole_changed = $qconsoleChanged
        probe_lane_launch_attempted = [bool](Get-ObjectPropertyValue -Object $launchObservability -Name "probe_lane_launch_attempted" -Default $false)
        lane_root_materialized = [bool](Get-ObjectPropertyValue -Object $readinessObservability -Name "lane_root_materialized" -Default $false)
        port_ready = [bool](Get-ObjectPropertyValue -Object $readinessObservability -Name "port_ready" -Default $false)
        join_helper_invoked = [bool](Get-ObjectPropertyValue -Object $readinessObservability -Name "join_helper_invoked" -Default $false)
        lane_ready_before_client_launch = $laneReadyBeforeClientLaunch
        lane_ready_lead_seconds = $laneReadyLeadSeconds
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object $finalMetrics -Name "server_connection_seen" -Default ($connectedLines.Count -gt 0))
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $finalMetrics -Name "entered_the_game_seen_exact" -Default ($enteredGameLines.Count -gt 0))
        first_server_connect_line = if ($connectedLines.Count -gt 0) { $connectedLines[0] } else { "" }
        first_server_connect_line_timestamp_utc = $firstServerConnectionSeenAtUtc
        first_entered_the_game_line = if ($enteredGameLines.Count -gt 0) { $enteredGameLines[0] } else { "" }
        first_entered_the_game_line_timestamp_utc = $firstEnteredGameSeenAtUtc
        connect_delay_seconds = Get-SecondsBetween -EarlierUtc $launchStartedAtUtc -LaterUtc $firstServerConnectionSeenAtUtc
        entered_game_delay_seconds = Get-SecondsBetween -EarlierUtc $launchStartedAtUtc -LaterUtc $firstEnteredGameSeenAtUtc
        hlds_stdout_log = $hldsStdoutLogPath
    }
}

function Convert-ToSerializableProbeRecord {
    param([object]$ProbeRecord)

    return [ordered]@{
        probe_root = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "probe_root" -Default "")
        probe_report_json = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "probe_report_json" -Default "")
        probe_verdict = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "probe_verdict" -Default "")
        client_discovery_verdict = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "client_discovery_verdict" -Default "")
        client_path = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "client_path" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "launch_command" -Default "")
        working_directory = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "working_directory" -Default "")
        launch_started_at_utc = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "launch_started_at_utc" -Default "")
        join_target = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "join_target" -Default "")
        client_process_id = [int](Get-ObjectPropertyValue -Object $ProbeRecord -Name "client_process_id" -Default 0)
        client_process_observed_duration_seconds = Get-ObjectPropertyValue -Object $ProbeRecord -Name "client_process_observed_duration_seconds" -Default $null
        client_process_appears_to_exit_too_early = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "client_process_appears_to_exit_too_early" -Default $false)
        join_attempt_count = [int](Get-ObjectPropertyValue -Object $ProbeRecord -Name "join_attempt_count" -Default 0)
        join_retry_used = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "join_retry_used" -Default $false)
        join_retry_reason = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "join_retry_reason" -Default "")
        qconsole_changed = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "qconsole_changed" -Default $false)
        probe_lane_launch_attempted = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "probe_lane_launch_attempted" -Default $false)
        lane_root_materialized = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "lane_root_materialized" -Default $false)
        port_ready = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "port_ready" -Default $false)
        join_helper_invoked = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "join_helper_invoked" -Default $false)
        lane_ready_before_client_launch = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "lane_ready_before_client_launch" -Default $false)
        lane_ready_lead_seconds = Get-ObjectPropertyValue -Object $ProbeRecord -Name "lane_ready_lead_seconds" -Default $null
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "server_connection_seen" -Default $false)
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $ProbeRecord -Name "entered_the_game_seen" -Default $false)
        first_server_connect_line = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "first_server_connect_line" -Default "")
        first_server_connect_line_timestamp_utc = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "first_server_connect_line_timestamp_utc" -Default "")
        first_entered_the_game_line = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "first_entered_the_game_line" -Default "")
        first_entered_the_game_line_timestamp_utc = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "first_entered_the_game_line_timestamp_utc" -Default "")
        connect_delay_seconds = Get-ObjectPropertyValue -Object $ProbeRecord -Name "connect_delay_seconds" -Default $null
        entered_game_delay_seconds = Get-ObjectPropertyValue -Object $ProbeRecord -Name "entered_game_delay_seconds" -Default $null
        hlds_stdout_log = [string](Get-ObjectPropertyValue -Object $ProbeRecord -Name "hlds_stdout_log" -Default "")
    }
}

function Get-AuditMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Entered-The-Game Boundary Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Report.prompt_id)") | Out-Null
    $lines.Add("- Comparison verdict: $($Report.comparison_verdict)") | Out-Null
    $lines.Add("- Narrowest likely divergence: $($Report.narrowest_likely_divergence)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Successful probe root: $($Report.successful_probe.probe_root)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Failed Probe Roots") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($failed in @($Report.failed_probes)) {
        $lines.Add("- $($failed.probe_root)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Comparative Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Launch command equivalent: $(Get-BoolString -Value ([bool]$Report.comparison.launch_command_equivalent))") | Out-Null
    $lines.Add("- Working directory equivalent: $(Get-BoolString -Value ([bool]$Report.comparison.working_directory_equivalent))") | Out-Null
    $lines.Add("- Join target equivalent: $(Get-BoolString -Value ([bool]$Report.comparison.join_target_equivalent))") | Out-Null
    $lines.Add("- Success lane-ready-before-launch: $(Get-BoolString -Value ([bool]$Report.comparison.success_lane_ready_before_client_launch))") | Out-Null
    $lines.Add("- Failed probes lane-ready-before-launch count: $($Report.comparison.failed_lane_ready_before_client_launch_count) / $($Report.comparison.failed_probe_count)") | Out-Null
    $lines.Add("- Successful connect delay seconds: $($Report.comparison.success_connect_delay_seconds)") | Out-Null
    $lines.Add("- Successful entered-game delay seconds: $($Report.comparison.success_entered_game_delay_seconds)") | Out-Null
    $lines.Add("- Failed server-connect count: $($Report.comparison.failed_server_connect_count)") | Out-Null
    $lines.Add("- Failed entered-the-game count: $($Report.comparison.failed_entered_game_count)") | Out-Null
    $lines.Add("- Failed probes with early client exit evidence: $($Report.comparison.failed_client_exit_too_early_count)") | Out-Null
    $lines.Add("- qconsole changed in successful probe: $(Get-BoolString -Value ([bool]$Report.comparison.success_qconsole_changed))") | Out-Null
    $lines.Add("- qconsole changed in any failed probe: $(Get-BoolString -Value ([bool]$Report.comparison.any_failed_qconsole_changed))") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Stage Verdicts") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($stage in @($Report.stages.launch_started, $Report.stages.server_connect, $Report.stages.entered_game)) {
        $lines.Add(("### {0}" -f $stage.stage)) | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("- Verdict: $($stage.verdict)") | Out-Null
        $lines.Add("- Reached: $(Get-BoolString -Value ([bool]$stage.reached))") | Out-Null
        $lines.Add("- Explanation: $($stage.explanation)") | Out-Null
        $lines.Add("- Evidence found:") | Out-Null
        foreach ($item in @($stage.evidence_found)) {
            $lines.Add("  - $item") | Out-Null
        }
        if (@($stage.evidence_missing).Count -gt 0) {
            $lines.Add("- Evidence missing:") | Out-Null
            foreach ($item in @($stage.evidence_missing)) {
                $lines.Add("  - $item") | Out-Null
            }
        }
        $lines.Add("") | Out-Null
    }
    $lines.Add("## Per-Probe Comparison") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Probe | Verdict | Launch command matches success | Lane ready before launch | Connect seen | Entered game seen | Connect delay seconds | Entered-game delay seconds | Retry used | Early client exit evidence |") | Out-Null
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
    foreach ($probe in @($Report.failed_probes)) {
        $lines.Add((
                "| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |" -f
                $probe.probe_root,
                $probe.probe_verdict,
                (Get-BoolString -Value ([bool]($probe.launch_command -eq $Report.successful_probe.launch_command))),
                (Get-BoolString -Value ([bool]$probe.lane_ready_before_client_launch)),
                (Get-BoolString -Value ([bool]$probe.server_connection_seen)),
                (Get-BoolString -Value ([bool]$probe.entered_the_game_seen)),
                $probe.connect_delay_seconds,
                $probe.entered_game_delay_seconds,
                (Get-BoolString -Value ([bool]$probe.join_retry_used)),
                (Get-BoolString -Value ([bool]$probe.client_process_appears_to_exit_too_early))
            )) | Out-Null
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $LabRoot)
}

$evalRoot = Get-EvalRootDefault -LabRoot $resolvedLabRoot
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $evalRoot "entered_game_boundary_audits")
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $OutputRoot)
}

$resolvedSuccessfulProbeRoot = Resolve-ExistingPath -Path $SuccessfulProbeRoot
if (-not $resolvedSuccessfulProbeRoot) {
    $resolvedSuccessfulProbeRoot = Find-LatestSuccessfulProbeRoot -EvalRoot $evalRoot
}

$resolvedFailedProbeRoots = New-Object System.Collections.Generic.List[string]
foreach ($probeRoot in @($FailedProbeRoots)) {
    $resolvedProbeRoot = Resolve-ExistingPath -Path $probeRoot
    if ($resolvedProbeRoot) {
        $resolvedFailedProbeRoots.Add($resolvedProbeRoot) | Out-Null
    }
}

if ($resolvedFailedProbeRoots.Count -le 0 -or $UseLatest) {
    foreach ($probeRoot in @(Find-LatestFailedProbeRootsFromMatrix -EvalRoot $evalRoot)) {
        if ($resolvedFailedProbeRoots -notcontains $probeRoot) {
            $resolvedFailedProbeRoots.Add($probeRoot) | Out-Null
        }
    }
}

if ($resolvedFailedProbeRoots.Count -le 0) {
    throw "No failed repeated bounded probe roots were resolved. Pass -FailedProbeRoots or use -UseLatest."
}

$successfulProbe = Get-ProbeBoundaryRecord -ProbeRoot $resolvedSuccessfulProbeRoot
$failedProbeRecordList = New-Object System.Collections.Generic.List[object]
foreach ($failedProbeRoot in @($resolvedFailedProbeRoots.ToArray())) {
    $failedProbeRecordList.Add((Get-ProbeBoundaryRecord -ProbeRoot $failedProbeRoot)) | Out-Null
}
$failedProbeRecords = @($failedProbeRecordList.ToArray())

$launchCommandEquivalent = @($failedProbeRecords | Where-Object { $_.launch_command -eq $successfulProbe.launch_command }).Count -eq $failedProbeRecords.Count
$workingDirectoryEquivalent = @($failedProbeRecords | Where-Object { $_.working_directory -eq $successfulProbe.working_directory }).Count -eq $failedProbeRecords.Count
$joinTargetEquivalent = @($failedProbeRecords | Where-Object { $_.join_target -eq $successfulProbe.join_target }).Count -eq $failedProbeRecords.Count
$failedLaneReadyBeforeLaunchCount = @($failedProbeRecords | Where-Object { [bool]$_.lane_ready_before_client_launch }).Count
$failedServerConnectCount = @($failedProbeRecords | Where-Object { [bool]$_.server_connection_seen }).Count
$failedEnteredGameCount = @($failedProbeRecords | Where-Object { [bool]$_.entered_the_game_seen }).Count
$failedClientExitTooEarlyCount = @($failedProbeRecords | Where-Object { [bool]$_.client_process_appears_to_exit_too_early }).Count
$anyFailedQconsoleChanged = @($failedProbeRecords | Where-Object { [bool]$_.qconsole_changed }).Count -gt 0

$comparisonVerdict = if (-not $successfulProbe.client_path) {
    "inconclusive-manual-review"
}
elseif ($failedClientExitTooEarlyCount -gt 0) {
    "client-exits-too-early"
}
elseif ($failedServerConnectCount -le 0 -and $launchCommandEquivalent -and $workingDirectoryEquivalent -and $joinTargetEquivalent -and $successfulProbe.lane_ready_before_client_launch -and $failedLaneReadyBeforeLaunchCount -eq $failedProbeRecords.Count) {
    "entered-game-racy"
}
elseif ($failedServerConnectCount -le 0) {
    "launched-but-no-connect"
}
elseif ($failedEnteredGameCount -lt $failedServerConnectCount) {
    "connected-but-never-entered-game"
}
elseif ($successfulProbe.entered_the_game_seen -and $failedEnteredGameCount -eq $failedProbeRecords.Count) {
    "entered-game-reliable"
}
else {
    "inconclusive-manual-review"
}

$narrowestLikelyDivergence = switch ($comparisonVerdict) {
    "client-exits-too-early" {
        "One or more failed repeated probes now show the local client process disappearing before the server fully admits it."
    }
    "entered-game-racy" {
        "The successful and failed probes use the same launch command, working directory, and join target, and both launch only after the lane is ready. The divergence is now timing and admission reliability rather than static launch configuration."
    }
    "launched-but-no-connect" {
        "The failed repeated probes still launch hl.exe, but the server never logs a real connection."
    }
    "connected-but-never-entered-game" {
        "The failed repeated probes reach server-side connect but still do not cross the entered-the-game boundary reliably."
    }
    "entered-game-reliable" {
        "The compared probes now reach entered-the-game consistently."
    }
    default {
        "The current saved artifacts are still too mixed to name a narrower entered-the-game divergence confidently."
    }
}

$overallExplanation = switch ($comparisonVerdict) {
    "entered-game-racy" {
        "The successful probe and the failed repeated probes use the same hl.exe launch command, working directory, and loopback join target. The lane is already root-materialized and port-ready before client launch in both cases. The successful probe reaches server connect and entered-the-game only after a noticeable delay, while the failed repeated probes never even produce the first server-side connect line. That points at a racy admission window rather than a configuration mismatch."
    }
    "client-exits-too-early" {
        "The comparison now shows that one or more failed repeated probes launch hl.exe but the client process disappears before the server admits it fully. That is a narrower and more actionable failure than a generic no-connect result."
    }
    "launched-but-no-connect" {
        "The repeated bounded failures still sit before the first server-side connect line. The comparison does not show a strong static launch mismatch, but it also does not yet prove a stable admission path."
    }
    "connected-but-never-entered-game" {
        "The repeated bounded failures reach the server-side socket connection but still do not cross into a trusted entered-the-game state consistently."
    }
    "entered-game-reliable" {
        "The compared probes now show a stable entered-the-game boundary, which is the prerequisite for returning to broader human-signal validation."
    }
    default {
        "The comparison is useful, but the exact divergence around entered-the-game still needs manual review."
    }
}

$launchStage = Get-StageRecord `
    -StageName "launch-started" `
    -Verdict $(if ($launchCommandEquivalent -and $workingDirectoryEquivalent) { "launch-started" } else { "launch-never-started" }) `
    -Reached $launchCommandEquivalent `
    -EvidenceFound @(
        ("successful launch command: {0}" -f $successfulProbe.launch_command),
        ("successful working directory: {0}" -f $successfulProbe.working_directory),
        ("failed probes launch command equivalent count: {0}/{1}" -f @($failedProbeRecords | Where-Object { $_.launch_command -eq $successfulProbe.launch_command }).Count, $failedProbeRecords.Count),
        ("failed probes working directory equivalent count: {0}/{1}" -f @($failedProbeRecords | Where-Object { $_.working_directory -eq $successfulProbe.working_directory }).Count, $failedProbeRecords.Count)
    ) `
    -EvidenceMissing $(if ($launchCommandEquivalent -and $workingDirectoryEquivalent) { @() } else { @("equivalent launch command and working directory between successful and failed probes") }) `
    -Explanation $(if ($launchCommandEquivalent -and $workingDirectoryEquivalent) {
            "The failed repeated probes launch hl.exe the same way as the known successful bounded probe."
        } else {
            "A launch-command or working-directory mismatch still exists between the successful and failed probes."
        })

$connectStageVerdict = if ($failedClientExitTooEarlyCount -gt 0) {
    "client-exits-too-early"
}
elseif ($failedServerConnectCount -le 0) {
    "launched-but-no-connect"
}
else {
    "server-connect-seen"
}
$connectStage = Get-StageRecord `
    -StageName "server-connect" `
    -Verdict $connectStageVerdict `
    -Reached ($failedServerConnectCount -gt 0) `
    -EvidenceFound @(
        ("successful first server connect timestamp UTC: {0}" -f $successfulProbe.first_server_connect_line_timestamp_utc),
        ("successful connect delay seconds: {0}" -f $successfulProbe.connect_delay_seconds),
        ("failed probes with server connect: {0}/{1}" -f $failedServerConnectCount, $failedProbeRecords.Count),
        ("failed probes with early client exit evidence: {0}/{1}" -f $failedClientExitTooEarlyCount, $failedProbeRecords.Count)
    ) `
    -EvidenceMissing $(if ($failedServerConnectCount -gt 0) { @() } else { @("server-side connect line in at least one failed repeated probe") }) `
    -Explanation $(if ($failedClientExitTooEarlyCount -gt 0) {
            "At least one failed repeated probe now shows the client process exiting before server admission."
        } elseif ($failedServerConnectCount -le 0) {
            "The successful probe proves the join target is reachable, but the compared repeated failures still never produce the first server-side connect line."
        } else {
            "Some failed repeated probes do reach server connect, so the current break point is later than raw socket admission."
        })

$enteredStageVerdict = switch ($comparisonVerdict) {
    "entered-game-racy" { "entered-game-racy" }
    "connected-but-never-entered-game" { "connected-but-never-entered-game" }
    "entered-game-reliable" { "entered-game-reliable" }
    default { "inconclusive-manual-review" }
}
$enteredStageReached = $successfulProbe.entered_the_game_seen -and $failedEnteredGameCount -eq $failedProbeRecords.Count
$enteredStage = Get-StageRecord `
    -StageName "entered-game" `
    -Verdict $enteredStageVerdict `
    -Reached $enteredStageReached `
    -EvidenceFound @(
        ("successful first entered-the-game timestamp UTC: {0}" -f $successfulProbe.first_entered_the_game_line_timestamp_utc),
        ("successful entered-the-game delay seconds: {0}" -f $successfulProbe.entered_game_delay_seconds),
        ("successful lane-ready-before-launch: {0}" -f $successfulProbe.lane_ready_before_client_launch),
        ("failed probes lane-ready-before-launch count: {0}/{1}" -f $failedLaneReadyBeforeLaunchCount, $failedProbeRecords.Count),
        ("failed probes entered-the-game count: {0}/{1}" -f $failedEnteredGameCount, $failedProbeRecords.Count)
    ) `
    -EvidenceMissing $(if ($enteredStageReached) { @() } else { @("reliable entered-the-game transition across the failed repeated probes") }) `
    -Explanation $(if ($comparisonVerdict -eq "entered-game-racy") {
            "The same launch path can reach entered-the-game, but repeated probes are not doing so consistently yet."
        } elseif ($comparisonVerdict -eq "connected-but-never-entered-game") {
            "The repeated probes reach connect but still do not cross into entered-the-game reliably."
        } elseif ($comparisonVerdict -eq "entered-game-reliable") {
            "The compared probes now reach entered-the-game consistently."
        } else {
            "The entered-the-game boundary still needs manual review."
        })

$auditRoot = New-UniqueDirectoryPath -ParentPath $resolvedOutputRoot -LeafName ("{0}-egb-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), (Convert-ToLaneSlug -Value "crossfire"))
$auditJsonPath = Join-Path $auditRoot "entered_game_boundary_audit.json"
$auditMarkdownPath = Join-Path $auditRoot "entered_game_boundary_audit.md"
$successfulProbeForReport = Convert-ToSerializableProbeRecord -ProbeRecord $successfulProbe
$failedProbesForReport = @($failedProbeRecords | ForEach-Object { Convert-ToSerializableProbeRecord -ProbeRecord $_ })

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    comparison_verdict = $comparisonVerdict
    narrowest_likely_divergence = $narrowestLikelyDivergence
    explanation = $overallExplanation
    successful_probe = $successfulProbeForReport
    failed_probes = $failedProbesForReport
    comparison = [ordered]@{
        failed_probe_count = $failedProbeRecords.Count
        launch_command_equivalent = $launchCommandEquivalent
        working_directory_equivalent = $workingDirectoryEquivalent
        join_target_equivalent = $joinTargetEquivalent
        success_lane_ready_before_client_launch = $successfulProbe.lane_ready_before_client_launch
        failed_lane_ready_before_client_launch_count = $failedLaneReadyBeforeLaunchCount
        success_connect_delay_seconds = $successfulProbe.connect_delay_seconds
        success_entered_game_delay_seconds = $successfulProbe.entered_game_delay_seconds
        failed_server_connect_count = $failedServerConnectCount
        failed_entered_game_count = $failedEnteredGameCount
        failed_client_exit_too_early_count = $failedClientExitTooEarlyCount
        success_qconsole_changed = [bool]$successfulProbe.qconsole_changed
        any_failed_qconsole_changed = $anyFailedQconsoleChanged
        recommended_reliability_fix = if ($comparisonVerdict -eq "entered-game-racy" -or $comparisonVerdict -eq "launched-but-no-connect") {
            "use-one-bounded-retry-when-the-first-launch-never-produces-server-connect"
        } elseif ($comparisonVerdict -eq "client-exits-too-early") {
            "keep-the-client-alive-long-enough-to-allow-server-admission-or-bounded-retry"
        } else {
            "no-narrow-reliability-fix-identified"
        }
    }
    stages = [ordered]@{
        launch_started = $launchStage
        server_connect = $connectStage
        entered_game = $enteredStage
    }
    artifacts = [ordered]@{
        entered_game_boundary_audit_json = $auditJsonPath
        entered_game_boundary_audit_markdown = $auditMarkdownPath
    }
}

Write-Host "  Writing entered-game boundary JSON..."
Write-JsonFile -Path $auditJsonPath -Value $report
Write-Host "  Writing entered-game boundary Markdown..."
$reportForMarkdown = Read-JsonFile -Path $auditJsonPath
Write-TextFile -Path $auditMarkdownPath -Value (Get-AuditMarkdown -Report $reportForMarkdown)

Write-Host "Entered-the-game boundary audit:"
Write-Host "  Comparison verdict: $($report.comparison_verdict)"
Write-Host "  Narrowest likely divergence: $($report.narrowest_likely_divergence)"
Write-Host "  Successful probe: $($report.successful_probe.probe_root)"
Write-Host "  Failed probes compared: $($failedProbeRecords.Count)"
Write-Host "  JSON: $auditJsonPath"
Write-Host "  Markdown: $auditMarkdownPath"

[pscustomobject]@{
    EnteredGameBoundaryAuditJsonPath = $auditJsonPath
    EnteredGameBoundaryAuditMarkdownPath = $auditMarkdownPath
    ComparisonVerdict = $report.comparison_verdict
    NarrowestLikelyDivergence = $report.narrowest_likely_divergence
}
