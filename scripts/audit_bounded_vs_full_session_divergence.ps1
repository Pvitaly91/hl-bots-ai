[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$BoundedProbeRoots = @(),
    [string[]]$FullSessionRoots = @(),
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

function Get-ConnectionEvidence {
    param([string[]]$LogLines)

    $connectedLines = New-Object System.Collections.Generic.List[string]
    $enteredLines = New-Object System.Collections.Generic.List[string]
    $matchedEnteredLines = New-Object System.Collections.Generic.List[string]
    $connectedPlayers = New-Object System.Collections.Generic.List[object]

    foreach ($line in @($LogLines)) {
        if ($line -match 'connected, address') {
            $connectedLines.Add($line) | Out-Null
            if ($line -match '"(?<name>[^"<]+)<\d+><(?<steam>[^>]*)><[^>]*>" connected, address "(?<address>[^"]+)"') {
                $connectedPlayers.Add([pscustomobject]@{
                        name = [string]$Matches["name"]
                        steam = [string]$Matches["steam"]
                        address = [string]$Matches["address"]
                    }) | Out-Null
            }
        }

        if ($line -match 'entered the game') {
            $enteredLines.Add($line) | Out-Null
        }
    }

    foreach ($enteredLine in @($enteredLines.ToArray())) {
        foreach ($player in @($connectedPlayers.ToArray())) {
            $name = [string](Get-ObjectPropertyValue -Object $player -Name "name" -Default "")
            $steam = [string](Get-ObjectPropertyValue -Object $player -Name "steam" -Default "")
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $nameMatched = $enteredLine -match ('"{0}<\d+><' -f [regex]::Escape($name))
            $steamMatched = if ([string]::IsNullOrWhiteSpace($steam)) { $true } else { $enteredLine -match [regex]::Escape($steam) }
            if ($nameMatched -and $steamMatched) {
                $matchedEnteredLines.Add($enteredLine) | Out-Null
                break
            }
        }
    }

    return [pscustomobject]@{
        connected_lines = @($connectedLines.ToArray())
        entered_game_lines = @($matchedEnteredLines.ToArray())
        raw_entered_game_lines = @($enteredLines.ToArray())
        connected_players = @($connectedPlayers.ToArray())
    }
}

function Get-ConnectionEvidenceFromLogPath {
    param([string]$Path)

    $resolvedPath = Resolve-ExistingPath -Path $Path
    if (-not $resolvedPath) {
        return [pscustomobject]@{
            connected_lines = @()
            entered_game_lines = @()
            raw_entered_game_lines = @()
            connected_players = @()
        }
    }

    return Get-ConnectionEvidence -LogLines @(Get-Content -LiteralPath $resolvedPath)
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

function Find-LatestSuccessfulBoundedProbeRoot {
    param([string]$EvalRoot)

    if ([string]::IsNullOrWhiteSpace($EvalRoot) -or -not (Test-Path -LiteralPath $EvalRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $EvalRoot -Filter "client_join_completion_probe.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in @($candidates)) {
        $report = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $report) {
            continue
        }

        $finalMetrics = Get-ObjectPropertyValue -Object $report -Name "final_metrics" -Default $null
        $probeVerdict = [string](Get-ObjectPropertyValue -Object $report -Name "probe_verdict" -Default "")
        $usable = [bool](Get-ObjectPropertyValue -Object $finalMetrics -Name "control_lane_human_usable" -Default $false)
        if ($usable -or $probeVerdict -eq "control-lane-human-usable") {
            return $candidate.DirectoryName
        }
    }

    return ""
}

function Find-LatestFailedFullSessionRoot {
    param([string]$EvalRoot)

    if ([string]::IsNullOrWhiteSpace($EvalRoot) -or -not (Test-Path -LiteralPath $EvalRoot)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $EvalRoot -Filter "strong_signal_conservative_attempt.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in @($candidates)) {
        $report = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $report) {
            continue
        }

        $countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $report -Name "counts_toward_promotion" -Default $false)
        $captured = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $report -Name "strong_signal_capture" -Default $null) -Name "captured" -Default $false)
        if (-not $countsTowardPromotion -or -not $captured) {
            return $candidate.DirectoryName
        }
    }

    return ""
}

function Get-BoundedProbeSnapshot {
    param([string]$ProbeRoot)

    $resolvedProbeRoot = Resolve-RootArgument -Path $ProbeRoot
    if (-not $resolvedProbeRoot) {
        throw "Bounded probe root was not found: $ProbeRoot"
    }

    $reportPath = Resolve-ExistingPath -Path (Join-Path $resolvedProbeRoot "client_join_completion_probe.json")
    if (-not $reportPath) {
        throw "Bounded probe root does not contain client_join_completion_probe.json: $resolvedProbeRoot"
    }

    $report = Read-JsonFile -Path $reportPath
    $launch = Get-ObjectPropertyValue -Object $report -Name "launch_observability" -Default $null
    $readiness = Get-ObjectPropertyValue -Object $report -Name "readiness_observability" -Default $null
    $metrics = Get-ObjectPropertyValue -Object $report -Name "final_metrics" -Default $null
    $artifacts = Get-ObjectPropertyValue -Object $report -Name "artifacts" -Default $null
    $joinAttempts = @(Get-ObjectPropertyValue -Object $launch -Name "join_attempts" -Default @())
    $latestJoinAttempt = if ($joinAttempts.Count -gt 0) { $joinAttempts[$joinAttempts.Count - 1] } else { $null }

    return [ordered]@{
        root = $resolvedProbeRoot
        report_json = $reportPath
        prompt_id = [string](Get-ObjectPropertyValue -Object $report -Name "prompt_id" -Default "")
        discovery_verdict = [string](Get-ObjectPropertyValue -Object $launch -Name "client_discovery_verdict" -Default "")
        client_path = [string](Get-ObjectPropertyValue -Object $launch -Name "client_path" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object $launch -Name "launch_command" -Default "")
        client_working_directory = [string](Get-ObjectPropertyValue -Object $launch -Name "client_working_directory" -Default "")
        join_target = [string](Get-ObjectPropertyValue -Object $launch -Name "join_target" -Default "")
        launch_started_at_utc = [string](Get-ObjectPropertyValue -Object $launch -Name "initial_launch_started_at_utc" -Default (Get-ObjectPropertyValue -Object $launch -Name "launch_started_at_utc" -Default ""))
        join_attempt_count = [int](Get-ObjectPropertyValue -Object $launch -Name "join_attempt_count" -Default 0)
        join_retry_used = [bool](Get-ObjectPropertyValue -Object $launch -Name "join_retry_used" -Default $false)
        join_retry_reason = [string](Get-ObjectPropertyValue -Object $launch -Name "join_retry_reason" -Default "")
        client_process_id = [int](Get-ObjectPropertyValue -Object $launch -Name "client_process_id" -Default 0)
        client_process_runtime_seconds = Get-ObjectPropertyValue -Object $latestJoinAttempt -Name "process_runtime_seconds" -Default $null
        client_process_exit_observed_at_utc = [string](Get-ObjectPropertyValue -Object $latestJoinAttempt -Name "process_exit_observed_at_utc" -Default "")
        client_exited_before_server_connect = [bool](Get-ObjectPropertyValue -Object $latestJoinAttempt -Name "exited_before_server_connect" -Default $false)
        client_exited_before_entered_game = [bool](Get-ObjectPropertyValue -Object $latestJoinAttempt -Name "exited_before_entered_game" -Default $false)
        control_join_attempted = [bool](Get-ObjectPropertyValue -Object $launch -Name "control_join_attempted" -Default $false)
        port_ready = [bool](Get-ObjectPropertyValue -Object $readiness -Name "port_ready" -Default $false)
        port_ready_at_utc = [string](Get-ObjectPropertyValue -Object $readiness -Name "port_wait_finished_at_utc" -Default "")
        lane_root_materialized = [bool](Get-ObjectPropertyValue -Object $readiness -Name "lane_root_materialized" -Default $false)
        lane_root_ready_at_utc = [string](Get-ObjectPropertyValue -Object $readiness -Name "lane_root_wait_finished_at_utc" -Default "")
        join_helper_invoked = [bool](Get-ObjectPropertyValue -Object $readiness -Name "join_helper_invoked" -Default $false)
        lane_root = [string](Get-ObjectPropertyValue -Object $readiness -Name "lane_root" -Default "")
        hlds_stdout_log = [string](Get-ObjectPropertyValue -Object $artifacts -Name "hlds_stdout_log" -Default "")
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object $metrics -Name "server_connection_seen" -Default $false)
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $metrics -Name "entered_the_game_seen" -Default $false)
        first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $metrics -Name "first_server_connection_seen_at_utc" -Default "")
        first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $metrics -Name "first_entered_the_game_seen_at_utc" -Default "")
        first_human_snapshot_seen = [bool](Get-ObjectPropertyValue -Object $metrics -Name "first_human_snapshot_seen" -Default $false)
        human_presence_accumulating = [bool](Get-ObjectPropertyValue -Object $metrics -Name "human_presence_accumulating" -Default $false)
        control_lane_human_usable = [bool](Get-ObjectPropertyValue -Object $metrics -Name "control_lane_human_usable" -Default $false)
        first_human_seen_timestamp_utc = [string](Get-ObjectPropertyValue -Object $metrics -Name "first_human_seen_timestamp_utc" -Default "")
        human_snapshots_count = [int](Get-ObjectPropertyValue -Object $metrics -Name "human_snapshots_count" -Default 0)
        seconds_with_human_presence = [double](Get-ObjectPropertyValue -Object $metrics -Name "seconds_with_human_presence" -Default 0.0)
        probe_verdict = [string](Get-ObjectPropertyValue -Object $report -Name "probe_verdict" -Default "")
    }
}

function Get-FullSessionSnapshot {
    param([string]$FullRoot)

    $resolvedFullRoot = Resolve-RootArgument -Path $FullRoot
    if (-not $resolvedFullRoot) {
        throw "Full session root was not found: $FullRoot"
    }

    $strongSignalPath = Resolve-ExistingPath -Path (Join-Path $resolvedFullRoot "strong_signal_conservative_attempt.json")
    if (-not $strongSignalPath) {
        throw "Full session root does not contain strong_signal_conservative_attempt.json: $resolvedFullRoot"
    }

    $humanAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedFullRoot "human_participation_conservative_attempt.json")
    $pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedFullRoot "pair_summary.json")
    $strongSignal = Read-JsonFile -Path $strongSignalPath
    $humanAttempt = Read-JsonFile -Path $humanAttemptPath
    $pairSummary = Read-JsonFile -Path $pairSummaryPath

    $controlLane = Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
    $controlSummary = Read-JsonFile -Path ([string](Get-ObjectPropertyValue -Object $controlLane -Name "summary_json" -Default ""))
    $treatmentSummary = Read-JsonFile -Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "summary_json" -Default ""))

    $controlHldsLogPath = Resolve-ExistingPath -Path (Join-Path ([string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_root" -Default "")) "hlds.stdout.log")
    $treatmentHldsLogPath = Resolve-ExistingPath -Path (Join-Path ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_root" -Default "")) "hlds.stdout.log")
    $controlConnectionEvidence = Get-ConnectionEvidenceFromLogPath -Path $controlHldsLogPath
    $treatmentConnectionEvidence = Get-ConnectionEvidenceFromLogPath -Path $treatmentHldsLogPath
    $controlConnectedLine = if (@($controlConnectionEvidence.connected_lines).Count -gt 0) { [string]$controlConnectionEvidence.connected_lines[0] } else { "" }
    $controlEnteredLine = if (@($controlConnectionEvidence.entered_game_lines).Count -gt 0) { [string]$controlConnectionEvidence.entered_game_lines[0] } else { "" }
    $treatmentConnectedLine = if (@($treatmentConnectionEvidence.connected_lines).Count -gt 0) { [string]$treatmentConnectionEvidence.connected_lines[0] } else { "" }
    $treatmentEnteredLine = if (@($treatmentConnectionEvidence.entered_game_lines).Count -gt 0) { [string]$treatmentConnectionEvidence.entered_game_lines[0] } else { "" }

    $humanControlJoin = Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null
    $humanTreatmentJoin = Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_lane_join" -Default $null
    $controlSwitchGuidance = Get-ObjectPropertyValue -Object $humanAttempt -Name "control_switch_guidance" -Default $null
    $treatmentPatchGuidance = Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_patch_guidance" -Default $null

    return [ordered]@{
        root = $resolvedFullRoot
        strong_signal_json = $strongSignalPath
        human_attempt_json = $humanAttemptPath
        pair_summary_json = $pairSummaryPath
        prompt_id = [string](Get-ObjectPropertyValue -Object $strongSignal -Name "prompt_id" -Default "")
        attempt_verdict = [string](Get-ObjectPropertyValue -Object $strongSignal -Name "attempt_verdict" -Default "")
        pair_classification = [string](Get-ObjectPropertyValue -Object $strongSignal -Name "pair_classification" -Default "")
        certification_verdict = [string](Get-ObjectPropertyValue -Object $strongSignal -Name "certification_verdict" -Default "")
        counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $strongSignal -Name "counts_toward_promotion" -Default $false)
        discovery_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "client_discovery" -Default $null) -Name "discovery_verdict" -Default "")
        client_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttempt -Name "client_discovery" -Default $null) -Name "client_path_used" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "launch_command" -Default "")
        client_working_directory = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "client_working_directory" -Default "")
        join_target = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "join_target" -Default "")
        launch_started_at_utc = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "launch_started_at_utc" -Default "")
        control_join_attempted = [bool](Get-ObjectPropertyValue -Object $humanControlJoin -Name "attempted" -Default $false)
        treatment_join_attempted = [bool](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "attempted" -Default $false)
        control_join_attempt_count = Get-ObjectPropertyValue -Object $humanControlJoin -Name "join_attempt_count" -Default $null
        control_join_retry_used = Get-ObjectPropertyValue -Object $humanControlJoin -Name "join_retry_used" -Default $null
        treatment_join_attempt_count = Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "join_attempt_count" -Default $null
        treatment_join_retry_used = Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "join_retry_used" -Default $null
        control_port_ready = Get-ObjectPropertyValue -Object $humanControlJoin -Name "port_ready" -Default $null
        control_port_ready_at_utc = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "port_wait_finished_at_utc" -Default "")
        treatment_port_ready = Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "port_ready" -Default $null
        treatment_port_ready_at_utc = [string](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "port_wait_finished_at_utc" -Default "")
        control_phase_verdict = [string](Get-ObjectPropertyValue -Object $controlSwitchGuidance -Name "verdict_at_handoff" -Default "")
        treatment_phase_verdict = [string](Get-ObjectPropertyValue -Object $treatmentPatchGuidance -Name "verdict_at_release" -Default "")
        control_lane_root = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "lane_root" -Default ([string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_root" -Default "")))
        treatment_lane_root = [string](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "lane_root" -Default ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_root" -Default "")))
        control_hlds_stdout_log = if ([string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "hlds_stdout_log" -Default "")) { [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "hlds_stdout_log" -Default "") } else { $controlHldsLogPath }
        treatment_hlds_stdout_log = if ([string](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "hlds_stdout_log" -Default "")) { [string](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "hlds_stdout_log" -Default "") } else { $treatmentHldsLogPath }
        control_server_connection_seen = if ($null -ne (Get-ObjectPropertyValue -Object $humanControlJoin -Name "server_connection_seen" -Default $null)) { [bool](Get-ObjectPropertyValue -Object $humanControlJoin -Name "server_connection_seen" -Default $false) } else { @($controlConnectionEvidence.connected_lines).Count -gt 0 }
        control_entered_the_game_seen = if ($null -ne (Get-ObjectPropertyValue -Object $humanControlJoin -Name "entered_the_game_seen" -Default $null)) { [bool](Get-ObjectPropertyValue -Object $humanControlJoin -Name "entered_the_game_seen" -Default $false) } else { @($controlConnectionEvidence.entered_game_lines).Count -gt 0 }
        treatment_server_connection_seen = if ($null -ne (Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "server_connection_seen" -Default $null)) { [bool](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "server_connection_seen" -Default $false) } else { @($treatmentConnectionEvidence.connected_lines).Count -gt 0 }
        treatment_entered_the_game_seen = if ($null -ne (Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "entered_the_game_seen" -Default $null)) { [bool](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "entered_the_game_seen" -Default $false) } else { @($treatmentConnectionEvidence.entered_game_lines).Count -gt 0 }
        control_first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "first_server_connection_seen_at_utc" -Default (Get-HldsLineTimestampUtcString -Line $controlConnectedLine))
        control_first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $humanControlJoin -Name "first_entered_the_game_seen_at_utc" -Default (Get-HldsLineTimestampUtcString -Line $controlEnteredLine))
        treatment_first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "first_server_connection_seen_at_utc" -Default (Get-HldsLineTimestampUtcString -Line $treatmentConnectedLine))
        treatment_first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "first_entered_the_game_seen_at_utc" -Default (Get-HldsLineTimestampUtcString -Line $treatmentEnteredLine))
        control_process_runtime_seconds = Get-ObjectPropertyValue -Object $humanControlJoin -Name "process_runtime_seconds" -Default $null
        treatment_process_runtime_seconds = Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "process_runtime_seconds" -Default $null
        control_client_exits_too_early = [bool](Get-ObjectPropertyValue -Object $humanControlJoin -Name "exited_before_server_connect" -Default $false) -or [bool](Get-ObjectPropertyValue -Object $humanControlJoin -Name "exited_before_entered_game" -Default $false)
        treatment_client_exits_too_early = [bool](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "exited_before_server_connect" -Default $false) -or [bool](Get-ObjectPropertyValue -Object $humanTreatmentJoin -Name "exited_before_entered_game" -Default $false)
        control_human_snapshots_count = [int](Get-ObjectPropertyValue -Object $controlLane -Name "human_snapshots_count" -Default 0)
        control_seconds_with_human_presence = [double](Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0.0)
        treatment_human_snapshots_count = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0)
        treatment_seconds_with_human_presence = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)
        control_human_usable = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSummary -Name "primary_lane" -Default $null) -Name "tuning_signal_usable" -Default $false)
        treatment_human_usable = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "tuning_signal_usable" -Default $false)
        pair_duration_seconds = [int](Get-ObjectPropertyValue -Object $pairSummary -Name "duration_seconds" -Default 0)
        control_human_join_timed_out = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSummary -Name "primary_lane" -Default $null) -Name "human_join_timed_out" -Default $false)
        treatment_human_join_timed_out = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentSummary -Name "primary_lane" -Default $null) -Name "human_join_timed_out" -Default $false)
    }
}

function Get-DivergenceComparison {
    param(
        [object]$Bounded,
        [object]$Full
    )

    $evidenceFound = New-Object System.Collections.Generic.List[string]
    $evidenceMissing = New-Object System.Collections.Generic.List[string]

    if ($Bounded.discovery_verdict) { $evidenceFound.Add("bounded discovery verdict: $($Bounded.discovery_verdict)") | Out-Null } else { $evidenceMissing.Add("bounded discovery verdict") | Out-Null }
    if ($Full.discovery_verdict) { $evidenceFound.Add("full discovery verdict: $($Full.discovery_verdict)") | Out-Null } else { $evidenceMissing.Add("full discovery verdict") | Out-Null }

    $launchCommandEquivalent = -not [string]::IsNullOrWhiteSpace($Bounded.launch_command) -and $Bounded.launch_command -eq $Full.launch_command
    $workingDirectoryEquivalent = -not [string]::IsNullOrWhiteSpace($Bounded.client_working_directory) -and $Bounded.client_working_directory -eq $Full.client_working_directory
    if ($launchCommandEquivalent) { $evidenceFound.Add("launch command matched between bounded and full") | Out-Null } else { $evidenceMissing.Add("launch command equivalence") | Out-Null }
    if ($workingDirectoryEquivalent) { $evidenceFound.Add("working directory matched between bounded and full") | Out-Null } else { $evidenceMissing.Add("working directory equivalence") | Out-Null }
    if ($Bounded.port_ready) { $evidenceFound.Add("bounded lane was port-ready before join") | Out-Null } else { $evidenceMissing.Add("bounded port-ready evidence") | Out-Null }
    if ($Bounded.lane_root_materialized) { $evidenceFound.Add("bounded lane root materialized before join") | Out-Null } else { $evidenceMissing.Add("bounded lane-root materialization evidence") | Out-Null }
    if ($Full.control_join_attempted) { $evidenceFound.Add("full control join was attempted") | Out-Null } else { $evidenceMissing.Add("full control join attempt") | Out-Null }
    if ($Full.treatment_join_attempted) { $evidenceFound.Add("full treatment join was attempted") | Out-Null } else { $evidenceFound.Add("full treatment join was skipped") | Out-Null }
    if ($Bounded.server_connection_seen) { $evidenceFound.Add("bounded probe saw a real server connection") | Out-Null } else { $evidenceMissing.Add("bounded server connection evidence") | Out-Null }
    if ($Bounded.entered_the_game_seen) { $evidenceFound.Add("bounded probe reached entered-the-game") | Out-Null } else { $evidenceMissing.Add("bounded entered-the-game evidence") | Out-Null }
    if ($Bounded.first_human_snapshot_seen) { $evidenceFound.Add("bounded probe reached the first human snapshot") | Out-Null } else { $evidenceMissing.Add("bounded first human snapshot evidence") | Out-Null }
    if ($Bounded.human_presence_accumulating) { $evidenceFound.Add("bounded probe accumulated saved human presence") | Out-Null } else { $evidenceMissing.Add("bounded human presence accumulation evidence") | Out-Null }
    if ($Full.control_server_connection_seen) { $evidenceFound.Add("full control lane logged a real server connection") | Out-Null } else { $evidenceFound.Add("full control lane never logged a real server connection") | Out-Null }
    if ($Full.control_entered_the_game_seen) { $evidenceFound.Add("full control lane logged entered-the-game") | Out-Null } else { $evidenceFound.Add("full control lane never logged entered-the-game") | Out-Null }
    if ($Full.control_human_snapshots_count -gt 0) { $evidenceFound.Add("full control lane wrote at least one human snapshot") | Out-Null } else { $evidenceFound.Add("full control lane wrote zero human snapshots") | Out-Null }
    if ($Full.treatment_human_snapshots_count -gt 0) { $evidenceFound.Add("full treatment lane wrote human snapshots") | Out-Null } else { $evidenceFound.Add("full treatment lane wrote zero human snapshots") | Out-Null }

    $narrowestPoint = ""
    $verdict = "divergence-inconclusive"
    $explanation = ""

    if ($Bounded.control_lane_human_usable -and ($Full.control_human_snapshots_count -le 0) -and ($Full.treatment_human_snapshots_count -le 0)) {
        $verdict = "bounded-success-full-nohuman"
        $narrowestPoint = "The bounded probe reached saved human presence, but the full session still recorded zero human signal in both lanes."
        $explanation = "The already-working bounded launch path did not survive the full strong-signal workflow. The divergence is real and happens before the full session can produce promotion-usable human evidence."
    }

    if ($Bounded.control_lane_human_usable -and $Full.control_phase_verdict -eq "insufficient-timeout" -and -not $Full.treatment_join_attempted) {
        $verdict = "bounded-success-full-control-never-cleared"
        $narrowestPoint = "The full session control-first gate never cleared, so treatment auto-join never started."
        $explanation = "Bounded control reached human-usable evidence, but the full session control lane stayed no-human and timed out before the control-first switch gate opened."
    }

    if ($verdict -eq "bounded-success-full-control-never-cleared" -and -not $Full.control_server_connection_seen) {
        $narrowestPoint = "The bounded probe reached server connect, entered-the-game, first human snapshot, and accumulating presence, but the full control lane launched a client and still never logged a real server connection."
        $explanation = "The operational divergence is earlier than telemetry or summary aggregation. The full-session control launch path diverged between process launch and server admission, which then kept the control-first gate closed and treatment unjoined."
    }
    elseif ($verdict -in @("bounded-success-full-nohuman", "bounded-success-full-control-never-cleared") -and $Full.control_server_connection_seen -and -not $Full.control_entered_the_game_seen) {
        $verdict = "bounded-success-full-nohuman"
        $narrowestPoint = "The full control lane reached server connect but never entered the game."
        $explanation = "The divergence moved later than launch: the full control client connected, but the admission boundary still failed before entered-the-game."
    }
    elseif ($verdict -in @("bounded-success-full-nohuman", "bounded-success-full-control-never-cleared") -and $Full.control_entered_the_game_seen -and ($Full.control_human_snapshots_count -le 0)) {
        $verdict = "bounded-success-full-summary-ingestion-missing"
        $narrowestPoint = "The full control lane reached entered-the-game, but saved summaries still wrote zero human snapshots."
        $explanation = "The divergence is later than admission and points at full-session telemetry or summary ingestion rather than launch or connect timing."
    }
    elseif ($verdict -in @("bounded-success-full-nohuman", "bounded-success-full-control-never-cleared") -and $Full.control_client_exits_too_early) {
        $verdict = "bounded-success-full-session-timing-too-short"
        $narrowestPoint = "The full control client appears to disappear before server admission completes."
        $explanation = "The full-session client lifetime looks too short relative to the bounded success path, so timing or retry behavior is the likely divergence."
    }

    if ($verdict -eq "bounded-success-full-control-never-cleared" -and -not $Full.treatment_join_attempted) {
        $evidenceFound.Add("full treatment join was skipped because control never became ready") | Out-Null
    }

    return [ordered]@{
        bounded_probe_root = $Bounded.root
        full_session_root = $Full.root
        divergence_verdict = $verdict
        evidence_found = @($evidenceFound.ToArray())
        evidence_missing = @($evidenceMissing.ToArray())
        narrowest_confirmed_divergence_point = $narrowestPoint
        explanation = $explanation
        exact_comparison = [ordered]@{
            client_discovery_result = [ordered]@{
                bounded = $Bounded.discovery_verdict
                full = $Full.discovery_verdict
            }
            launch_command = [ordered]@{
                bounded = $Bounded.launch_command
                full = $Full.launch_command
                equivalent = $launchCommandEquivalent
            }
            client_working_directory = [ordered]@{
                bounded = $Bounded.client_working_directory
                full = $Full.client_working_directory
                equivalent = $workingDirectoryEquivalent
            }
            join_target = [ordered]@{
                bounded = $Bounded.join_target
                full = $Full.join_target
                equivalent = (-not [string]::IsNullOrWhiteSpace($Bounded.join_target) -and $Bounded.join_target -eq $Full.join_target)
            }
            client_process_lifetime = [ordered]@{
                bounded_runtime_seconds = $Bounded.client_process_runtime_seconds
                full_runtime_seconds = $Full.control_process_runtime_seconds
                full_exits_too_early = $Full.control_client_exits_too_early
            }
            readiness_timing = [ordered]@{
                bounded_lane_root_materialized = $Bounded.lane_root_materialized
                bounded_lane_root_ready_at_utc = $Bounded.lane_root_ready_at_utc
                bounded_port_ready = $Bounded.port_ready
                bounded_port_ready_at_utc = $Bounded.port_ready_at_utc
                full_control_port_ready = $Full.control_port_ready
                full_control_port_ready_at_utc = $Full.control_port_ready_at_utc
            }
            join_progression = [ordered]@{
                bounded_control_join_attempted = $Bounded.control_join_attempted
                bounded_join_helper_invoked = $Bounded.join_helper_invoked
                full_control_join_attempted = $Full.control_join_attempted
                full_treatment_join_attempted = $Full.treatment_join_attempted
                full_control_phase_verdict = $Full.control_phase_verdict
                full_treatment_phase_verdict = $Full.treatment_phase_verdict
            }
            admission_boundary = [ordered]@{
                bounded_connected = $Bounded.server_connection_seen
                bounded_entered_the_game = $Bounded.entered_the_game_seen
                bounded_first_server_connection_seen_at_utc = $Bounded.first_server_connection_seen_at_utc
                bounded_first_entered_the_game_seen_at_utc = $Bounded.first_entered_the_game_seen_at_utc
                full_connected = $Full.control_server_connection_seen
                full_entered_the_game = $Full.control_entered_the_game_seen
                full_first_server_connection_seen_at_utc = $Full.control_first_server_connection_seen_at_utc
                full_first_entered_the_game_seen_at_utc = $Full.control_first_entered_the_game_seen_at_utc
            }
            human_signal_boundary = [ordered]@{
                bounded_first_human_snapshot_seen = $Bounded.first_human_snapshot_seen
                bounded_human_presence_accumulating = $Bounded.human_presence_accumulating
                bounded_control_lane_human_usable = $Bounded.control_lane_human_usable
                full_control_human_snapshots_count = $Full.control_human_snapshots_count
                full_control_seconds_with_human_presence = $Full.control_seconds_with_human_presence
                full_treatment_human_snapshots_count = $Full.treatment_human_snapshots_count
                full_treatment_seconds_with_human_presence = $Full.treatment_seconds_with_human_presence
                full_control_human_usable = $Full.control_human_usable
                full_treatment_human_usable = $Full.treatment_human_usable
            }
            summary_reflection = [ordered]@{
                full_pair_classification = $Full.pair_classification
                full_certification_verdict = $Full.certification_verdict
                full_counts_toward_promotion = $Full.counts_toward_promotion
                full_attempt_verdict = $Full.attempt_verdict
                full_pair_duration_seconds = $Full.pair_duration_seconds
            }
        }
    }
}

function Get-Markdown {
    param(
        [object]$Report
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Bounded-vs-Full Session Divergence Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Report.prompt_id)") | Out-Null
    $lines.Add("- Generated at UTC: $($Report.generated_at_utc)") | Out-Null
    $lines.Add("- Primary bounded probe root: $($Report.primary_bounded_probe.root)") | Out-Null
    $lines.Add("- Primary full session root: $($Report.primary_full_session.root)") | Out-Null
    $lines.Add("- Aggregate divergence verdict: $($Report.aggregate_divergence_verdict)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Primary Comparison") | Out-Null
    $lines.Add("") | Out-Null

    foreach ($comparison in @($Report.comparisons)) {
        $lines.Add("- Full session root: $($comparison.full_session_root)") | Out-Null
        $lines.Add("- Divergence verdict: $($comparison.divergence_verdict)") | Out-Null
        $lines.Add("- Narrowest confirmed divergence point: $($comparison.narrowest_confirmed_divergence_point)") | Out-Null
        $lines.Add("- Explanation: $($comparison.explanation)") | Out-Null
        $lines.Add("- Launch command equivalent: $($comparison.exact_comparison.launch_command.equivalent)") | Out-Null
        $lines.Add("- Working directory equivalent: $($comparison.exact_comparison.client_working_directory.equivalent)") | Out-Null
        $lines.Add("- Bounded connected / entered / first snapshot / accumulating: $($comparison.exact_comparison.admission_boundary.bounded_connected) / $($comparison.exact_comparison.admission_boundary.bounded_entered_the_game) / $($comparison.exact_comparison.human_signal_boundary.bounded_first_human_snapshot_seen) / $($comparison.exact_comparison.human_signal_boundary.bounded_human_presence_accumulating)") | Out-Null
        $lines.Add("- Full connected / entered / control snapshots / control seconds: $($comparison.exact_comparison.admission_boundary.full_connected) / $($comparison.exact_comparison.admission_boundary.full_entered_the_game) / $($comparison.exact_comparison.human_signal_boundary.full_control_human_snapshots_count) / $($comparison.exact_comparison.human_signal_boundary.full_control_seconds_with_human_presence)") | Out-Null
        $lines.Add("- Full treatment attempted: $($comparison.exact_comparison.join_progression.full_treatment_join_attempted)") | Out-Null
        $lines.Add("- Full control phase verdict: $($comparison.exact_comparison.join_progression.full_control_phase_verdict)") | Out-Null
        $lines.Add("- Evidence found:") | Out-Null
        foreach ($item in @($comparison.evidence_found)) {
            $lines.Add("  - $item") | Out-Null
        }
        if (@($comparison.evidence_missing).Count -gt 0) {
            $lines.Add("- Evidence missing:") | Out-Null
            foreach ($item in @($comparison.evidence_missing)) {
                $lines.Add("  - $item") | Out-Null
            }
        }
        $lines.Add("") | Out-Null
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Resolve-NormalizedPathCandidate -Path $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$evalRoot = Get-EvalRootDefault -LabRoot $resolvedLabRoot

$resolvedBoundedRoots = New-Object System.Collections.Generic.List[string]
foreach ($root in @($BoundedProbeRoots)) {
    $resolved = Resolve-RootArgument -Path $root
    if ($resolved) {
        $resolvedBoundedRoots.Add($resolved) | Out-Null
    }
}

$resolvedFullRoots = New-Object System.Collections.Generic.List[string]
foreach ($root in @($FullSessionRoots)) {
    $resolved = Resolve-RootArgument -Path $root
    if ($resolved) {
        $resolvedFullRoots.Add($resolved) | Out-Null
    }
}

if ($resolvedBoundedRoots.Count -eq 0) {
    $latestBoundedRoot = Find-LatestSuccessfulBoundedProbeRoot -EvalRoot $evalRoot
    if (-not $latestBoundedRoot) {
        throw "A successful bounded probe root could not be located automatically."
    }
    $resolvedBoundedRoots.Add($latestBoundedRoot) | Out-Null
}

if ($resolvedFullRoots.Count -eq 0) {
    $latestFullRoot = Find-LatestFailedFullSessionRoot -EvalRoot $evalRoot
    if (-not $latestFullRoot) {
        throw "A failed full strong-signal session root could not be located automatically."
    }
    $resolvedFullRoots.Add($latestFullRoot) | Out-Null
}

$boundedSnapshots = @()
foreach ($root in @($resolvedBoundedRoots | Select-Object -Unique)) {
    $boundedSnapshots += Get-BoundedProbeSnapshot -ProbeRoot $root
}

$fullSnapshots = @()
foreach ($root in @($resolvedFullRoots | Select-Object -Unique)) {
    $fullSnapshots += Get-FullSessionSnapshot -FullRoot $root
}

$primaryBounded = $boundedSnapshots[0]
$comparisons = New-Object System.Collections.Generic.List[object]
foreach ($fullSnapshot in @($fullSnapshots)) {
    $comparisons.Add((Get-DivergenceComparison -Bounded $primaryBounded -Full $fullSnapshot)) | Out-Null
}

$aggregateVerdict = "divergence-inconclusive"
$aggregateExplanation = "The comparison did not isolate one authoritative bounded-vs-full divergence point."
if ($comparisons.Count -gt 0) {
    $aggregateVerdict = [string](Get-ObjectPropertyValue -Object $comparisons[0] -Name "divergence_verdict" -Default $aggregateVerdict)
    $aggregateExplanation = [string](Get-ObjectPropertyValue -Object $comparisons[0] -Name "explanation" -Default $aggregateExplanation)
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $evalRoot ("divergence_audits\{0}-bounded-vs-full-session-divergence" -f $stamp))
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $OutputRoot)
}

$jsonPath = Join-Path $resolvedOutputRoot "bounded_vs_full_session_divergence.json"
$markdownPath = Join-Path $resolvedOutputRoot "bounded_vs_full_session_divergence.md"

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    output_root = $resolvedOutputRoot
    primary_bounded_probe = $primaryBounded
    primary_full_session = $fullSnapshots[0]
    bounded_probe_roots = @($resolvedBoundedRoots | Select-Object -Unique)
    full_session_roots = @($resolvedFullRoots | Select-Object -Unique)
    aggregate_divergence_verdict = $aggregateVerdict
    explanation = $aggregateExplanation
    comparisons = @($comparisons.ToArray())
    artifacts = [ordered]@{
        bounded_vs_full_session_divergence_json = $jsonPath
        bounded_vs_full_session_divergence_markdown = $markdownPath
    }
}

Write-JsonFile -Path $jsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $jsonPath
Write-TextFile -Path $markdownPath -Value (Get-Markdown -Report $reportForMarkdown)

Write-Host "Bounded-vs-full session divergence audit:"
Write-Host "  Bounded probe root: $($report.primary_bounded_probe.root)"
Write-Host "  Full session root: $($report.primary_full_session.root)"
Write-Host "  Aggregate divergence verdict: $($report.aggregate_divergence_verdict)"
Write-Host "  Explanation: $($report.explanation)"
Write-Host "  Audit JSON: $jsonPath"
Write-Host "  Audit Markdown: $markdownPath"

[pscustomobject]@{
    AuditJsonPath = $jsonPath
    AuditMarkdownPath = $markdownPath
    AggregateDivergenceVerdict = $report.aggregate_divergence_verdict
    Explanation = $report.explanation
}
