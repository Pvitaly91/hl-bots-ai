[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [switch]$Once,
    [int]$PollSeconds = 5,
    [switch]$WatchActiveJoin,
    [string]$LabRoot = ""
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

function Find-LatestPairRoot {
    param([string]$EvalRoot)

    if ([string]::IsNullOrWhiteSpace($EvalRoot) -or -not (Test-Path -LiteralPath $EvalRoot)) {
        throw "No eval root was available for pair discovery: $EvalRoot"
    }

    $candidate = Get-ChildItem -LiteralPath $EvalRoot -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No pair_summary.json was found under $EvalRoot"
    }

    return $candidate.DirectoryName
}

function Resolve-PairRoot {
    param(
        [string]$ExplicitPairRoot,
        [switch]$PreferLatest,
        [string]$ResolvedLabRoot
    )

    $resolvedExplicit = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
    if ($resolvedExplicit) {
        return $resolvedExplicit
    }

    if (-not $PreferLatest) {
        throw "A pair root is required. Pass -PairRoot or use -UseLatest."
    }

    return Find-LatestPairRoot -EvalRoot (Get-EvalRootDefault -LabRoot $ResolvedLabRoot)
}

function Get-LaneRootFromPairSummary {
    param(
        [object]$PairSummary,
        [string]$LaneName
    )

    $laneBlock = Get-ObjectPropertyValue -Object $PairSummary -Name $LaneName -Default $null
    return Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $laneBlock -Name "lane_root" -Default ""))
}

function Get-LaneArtifacts {
    param([string]$LaneRoot)

    if ([string]::IsNullOrWhiteSpace($LaneRoot)) {
        return [pscustomobject]@{
            LaneRoot = ""
            SummaryPath = ""
            Summary = $null
            SessionPackPath = ""
            SessionPack = $null
            HumanPresenceTimelinePath = ""
            HumanPresenceTimeline = @()
            HldsStdoutLogPath = ""
            HldsStdoutLogLines = @()
            HldsStderrLogPath = ""
            HldsStderrLogLines = @()
        }
    }

    $summaryPath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "summary.json")
    $sessionPackPath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "session_pack.json")
    $timelinePath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "human_presence_timeline.ndjson")
    $stdoutPath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "hlds.stdout.log")
    $stderrPath = Resolve-ExistingPath -Path (Join-Path $LaneRoot "hlds.stderr.log")

    [pscustomobject]@{
        LaneRoot = $LaneRoot
        SummaryPath = $summaryPath
        Summary = Read-JsonFile -Path $summaryPath
        SessionPackPath = $sessionPackPath
        SessionPack = Read-JsonFile -Path $sessionPackPath
        HumanPresenceTimelinePath = $timelinePath
        HumanPresenceTimeline = Read-NdjsonFile -Path $timelinePath
        HldsStdoutLogPath = $stdoutPath
        HldsStdoutLogLines = if ($stdoutPath) { @(Get-Content -LiteralPath $stdoutPath) } else { @() }
        HldsStderrLogPath = $stderrPath
        HldsStderrLogLines = if ($stderrPath) { @(Get-Content -LiteralPath $stderrPath) } else { @() }
    }
}

function Get-ConnectionEvidence {
    param(
        [string[]]$LogLines,
        [string]$LaneLabel
    )

    $connectedLines = New-Object System.Collections.Generic.List[string]
    $enteredLines = New-Object System.Collections.Generic.List[string]
    $matchedEnteredLines = New-Object System.Collections.Generic.List[string]
    $disconnectLines = New-Object System.Collections.Generic.List[string]
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
        if ($line -match 'disconnected') {
            $disconnectLines.Add($line) | Out-Null
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

    $verdict = if ($connectedLines.Count -gt 0) {
        if ($matchedEnteredLines.Count -gt 0) {
            "server-connection-and-game-entry-observed"
        }
        else {
            "server-connection-observed-no-game-entry"
        }
    }
    else {
        "no-server-connection-observed"
    }

    $explanation = switch ($verdict) {
        "server-connection-and-game-entry-observed" {
            "The $LaneLabel lane HLDS log shows a real client connection and an 'entered the game' event."
        }
        "server-connection-observed-no-game-entry" {
            "The $LaneLabel lane HLDS log shows a real client connection, but no matching 'entered the game' event."
        }
        default {
            "The $LaneLabel lane HLDS log does not show a real client connection."
        }
    }

    [pscustomobject]@{
        verdict = $verdict
        connected_lines = @($connectedLines.ToArray())
        entered_game_lines = @($matchedEnteredLines.ToArray())
        unmatched_entered_game_lines = @($enteredLines.ToArray())
        disconnected_lines = @($disconnectLines.ToArray())
        connected_players = @($connectedPlayers.ToArray())
        explanation = $explanation
    }
}

function Get-BoolString {
    param([bool]$Value)
    if ($Value) { return "yes" }
    return "no"
}

function Get-StageRecord {
    param(
        [string]$StageName,
        [string]$Verdict,
        [object[]]$EvidenceFound,
        [object[]]$EvidenceMissing,
        [string]$Explanation
    )

    [pscustomobject]@{
        stage = $StageName
        verdict = $Verdict
        evidence_found = @($EvidenceFound)
        evidence_missing = @($EvidenceMissing)
        explanation = $Explanation
    }
}

function Invoke-ClientPresenceAudit {
    param([string]$ResolvedPairRoot)

    $pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    if (-not $pairSummaryPath) {
        throw "Pair root does not contain pair_summary.json: $ResolvedPairRoot"
    }

    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    $humanAttemptPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "human_participation_conservative_attempt.json")
    $humanAttempt = Read-JsonFile -Path $humanAttemptPath
    $strongSignalAttemptPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "strong_signal_conservative_attempt.json")
    $strongSignalAttempt = Read-JsonFile -Path $strongSignalAttemptPath
    $monitorStatusPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "live_monitor_status.json")
    $monitorStatus = Read-JsonFile -Path $monitorStatusPath
    $phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "conservative_phase_flow.json")
    $phaseFlow = Read-JsonFile -Path $phaseFlowPath
    $controlSwitchPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "control_to_treatment_switch.json")
    $controlSwitch = Read-JsonFile -Path $controlSwitchPath
    $treatmentPatchPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "treatment_patch_window.json")
    $treatmentPatch = Read-JsonFile -Path $treatmentPatchPath
    $missionExecutionPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission_execution.json")
    $missionExecution = Read-JsonFile -Path $missionExecutionPath
    $monitorHistoryPath = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\monitor_verdict_history.ndjson")
    $monitorHistory = Read-NdjsonFile -Path $monitorHistoryPath

    $controlLaneRoot = Get-LaneRootFromPairSummary -PairSummary $pairSummary -LaneName "control_lane"
    $treatmentLaneRoot = Get-LaneRootFromPairSummary -PairSummary $pairSummary -LaneName "treatment_lane"
    $controlLane = Get-LaneArtifacts -LaneRoot $controlLaneRoot
    $treatmentLane = Get-LaneArtifacts -LaneRoot $treatmentLaneRoot
    $controlConnection = Get-ConnectionEvidence -LogLines $controlLane.HldsStdoutLogLines -LaneLabel "control"
    $treatmentConnection = Get-ConnectionEvidence -LogLines $treatmentLane.HldsStdoutLogLines -LaneLabel "treatment"

    $clientDiscovery = Get-ObjectPropertyValue -Object $humanAttempt -Name "client_discovery" -Default $null
    $controlJoin = Get-ObjectPropertyValue -Object $humanAttempt -Name "control_lane_join" -Default $null
    $treatmentJoin = Get-ObjectPropertyValue -Object $humanAttempt -Name "treatment_lane_join" -Default $null
    $artifacts = Get-ObjectPropertyValue -Object $humanAttempt -Name "artifacts" -Default $null
    $attemptStdoutPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "attempt_stdout_log" -Default ""))
    $attemptStderrPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "attempt_stderr_log" -Default ""))

    $controlHumanSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "human_snapshots_count" -Default 0)
    $treatmentHumanSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "human_snapshots_count" -Default 0)
    $controlLaneSummaryHumanSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlLane.Summary -Name "primary_lane" -Default $null) -Name "human_snapshots_count" -Default 0)
    $treatmentLaneSummaryHumanSnapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentLane.Summary -Name "primary_lane" -Default $null) -Name "human_snapshots_count" -Default 0)
    $liveMonitorSawHuman = @($monitorHistory | Where-Object {
            [double](Get-ObjectPropertyValue -Object $_ -Name "control_human_presence_seconds" -Default 0.0) -gt 0 -or
            [double](Get-ObjectPropertyValue -Object $_ -Name "treatment_human_presence_seconds" -Default 0.0) -gt 0 -or
            [int](Get-ObjectPropertyValue -Object $_ -Name "control_human_snapshots_count" -Default 0) -gt 0 -or
            [int](Get-ObjectPropertyValue -Object $_ -Name "treatment_human_snapshots_count" -Default 0) -gt 0
        }).Count -gt 0
    $phaseAdvancedBecauseOfHumanSignal = [bool](Get-ObjectPropertyValue -Object $phaseFlow -Name "switch_to_treatment_allowed" -Default $false) -or
        [bool](Get-ObjectPropertyValue -Object $phaseFlow -Name "finish_grounded_session_allowed" -Default $false)

    $clientProcessObserved = [int](Get-ObjectPropertyValue -Object $controlJoin -Name "process_id" -Default 0) -gt 0 -or
        [int](Get-ObjectPropertyValue -Object $treatmentJoin -Name "process_id" -Default 0) -gt 0
    $serverConnectionObserved = $controlConnection.connected_lines.Count -gt 0 -or $treatmentConnection.connected_lines.Count -gt 0
    $laneAttributionPresent = ($controlConnection.connected_lines.Count -gt 0 -and $controlLane.LaneRoot) -or ($treatmentConnection.connected_lines.Count -gt 0 -and $treatmentLane.LaneRoot)
    $pairSummaryShowsHumanSnapshots = ($controlHumanSnapshots + $treatmentHumanSnapshots) -gt 0
    $controlSummaryShowsHumanSnapshots = $controlLaneSummaryHumanSnapshots -gt 0
    $treatmentSummaryShowsHumanSnapshots = $treatmentLaneSummaryHumanSnapshots -gt 0

    $launchEvidenceFound = @()
    $launchEvidenceMissing = @()
    if ([string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "discovery_verdict" -Default "")) {
        $launchEvidenceFound += ("client discovery verdict: {0}" -f [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "discovery_verdict" -Default ""))
    }
    else {
        $launchEvidenceMissing += "client discovery verdict"
    }
    if ([string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "client_path_used" -Default "")) {
        $launchEvidenceFound += ("client path: {0}" -f [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "client_path_used" -Default ""))
    }
    else {
        $launchEvidenceMissing += "client path"
    }
    if ([bool](Get-ObjectPropertyValue -Object $controlJoin -Name "attempted" -Default $false)) {
        $launchEvidenceFound += "control join was attempted"
    }
    else {
        $launchEvidenceMissing += "control join attempt"
    }
    if ([int](Get-ObjectPropertyValue -Object $controlJoin -Name "process_id" -Default 0) -gt 0) {
        $launchEvidenceFound += ("control client process observed: PID {0}" -f [int](Get-ObjectPropertyValue -Object $controlJoin -Name "process_id" -Default 0))
    }
    else {
        $launchEvidenceMissing += "observed client PID"
    }
    if ([string](Get-ObjectPropertyValue -Object $controlJoin -Name "launch_command" -Default "")) {
        $launchEvidenceFound += ("control launch command: {0}" -f [string](Get-ObjectPropertyValue -Object $controlJoin -Name "launch_command" -Default ""))
    }
    else {
        $launchEvidenceMissing += "control launch command"
    }

    $launchStageVerdict = if ([bool](Get-ObjectPropertyValue -Object $controlJoin -Name "attempted" -Default $false) -and $clientProcessObserved) {
        "client-launched-process-only"
    }
    elseif ([bool](Get-ObjectPropertyValue -Object $controlJoin -Name "attempted" -Default $false)) {
        "client-launch-attempted-no-process-observed"
    }
    else {
        "client-not-launched"
    }
    $launchExplanation = switch ($launchStageVerdict) {
        "client-launched-process-only" {
            "The join helper attempted the control launch, resolved hl.exe, and observed a local client PID."
        }
        "client-launch-attempted-no-process-observed" {
            "The helper attempted a join, but the saved attempt evidence did not record a client PID."
        }
        default {
            "The saved pair does not show a local client launch attempt."
        }
    }

    $serverConnectStageVerdict = if ($serverConnectionObserved) {
        if ($controlConnection.entered_game_lines.Count -gt 0 -or $treatmentConnection.entered_game_lines.Count -gt 0) {
            "client-connected-and-entered-game"
        }
        else {
            "client-connected-but-no-server-game-entry"
        }
    }
    else {
        "client-launched-but-no-server-connect"
    }
    $serverConnectFound = @()
    $serverConnectMissing = @()
    if ($controlConnection.connected_lines.Count -gt 0) {
        $serverConnectFound += ("control HLDS log connected line: {0}" -f $controlConnection.connected_lines[0])
    }
    if ($controlConnection.entered_game_lines.Count -gt 0) {
        $serverConnectFound += ("control HLDS log entered-the-game line: {0}" -f $controlConnection.entered_game_lines[0])
    }
    else {
        $serverConnectMissing += "control entered-the-game line"
    }
    if ($treatmentConnection.connected_lines.Count -gt 0) {
        $serverConnectFound += ("treatment HLDS log connected line: {0}" -f $treatmentConnection.connected_lines[0])
    }
    if ($controlConnection.connected_lines.Count -eq 0 -and $treatmentConnection.connected_lines.Count -eq 0) {
        $serverConnectMissing += "server-side connected line"
    }
    $serverConnectExplanation = switch ($serverConnectStageVerdict) {
        "client-connected-and-entered-game" {
            "Server-side logs show the client both connected and entered the game."
        }
        "client-connected-but-no-server-game-entry" {
            "Server-side logs show a real client connection, but no matching 'entered the game' event."
        }
        default {
            "The saved server logs do not show a real client connection after launch."
        }
    }

    $laneAttributionStageVerdict = if ($laneAttributionPresent) {
        "lane-attribution-present"
    }
    elseif ($serverConnectionObserved) {
        "client-connected-but-no-lane-attribution"
    }
    else {
        "no-lane-attribution"
    }
    $laneAttributionFound = @()
    $laneAttributionMissing = @()
    if ($controlConnection.connected_lines.Count -gt 0) {
        $laneAttributionFound += ("control lane HLDS log captured the client connection at {0}" -f $controlLane.HldsStdoutLogPath)
    }
    if ($treatmentConnection.connected_lines.Count -gt 0) {
        $laneAttributionFound += ("treatment lane HLDS log captured the client connection at {0}" -f $treatmentLane.HldsStdoutLogPath)
    }
    if (-not $laneAttributionPresent) {
        $laneAttributionMissing += "lane-local server log with a client connection"
    }
    $laneAttributionExplanation = switch ($laneAttributionStageVerdict) {
        "lane-attribution-present" {
            "The connection evidence is already lane-local, so attribution did not disappear between launch and the pair pack."
        }
        "client-connected-but-no-lane-attribution" {
            "A client connection exists somewhere, but the saved pair pack does not attribute it to a specific lane."
        }
        default {
            "There is no saved lane-local connection evidence to attribute."
        }
    }

    $humanSnapshotStageVerdict = if ($controlSummaryShowsHumanSnapshots -and $treatmentSummaryShowsHumanSnapshots) {
        "human-snapshots-present-both-lanes"
    }
    elseif ($controlSummaryShowsHumanSnapshots) {
        "human-snapshots-present-control-only"
    }
    elseif ($treatmentSummaryShowsHumanSnapshots) {
        "human-snapshots-present-treatment-only"
    }
    elseif ($laneAttributionPresent) {
        "lane-attribution-present-but-no-human-snapshots"
    }
    else {
        "no-human-snapshot-evidence"
    }
    $humanSnapshotFound = @()
    $humanSnapshotMissing = @()
    $humanSnapshotFound += ("control lane human snapshots: {0}" -f $controlLaneSummaryHumanSnapshots)
    $humanSnapshotFound += ("treatment lane human snapshots: {0}" -f $treatmentLaneSummaryHumanSnapshots)
    $humanSnapshotFound += ("control lane human presence seconds: {0}" -f [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlLane.Summary -Name "primary_lane" -Default $null) -Name "seconds_with_human_presence" -Default 0.0))
    $humanSnapshotFound += ("treatment lane human presence seconds: {0}" -f [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentLane.Summary -Name "primary_lane" -Default $null) -Name "seconds_with_human_presence" -Default 0.0))
    if (-not $controlSummaryShowsHumanSnapshots) {
        $humanSnapshotMissing += "control telemetry sample with human_player_count > 0"
    }
    if (-not $treatmentSummaryShowsHumanSnapshots) {
        $humanSnapshotMissing += "treatment telemetry sample with human_player_count > 0"
    }
    if ($controlConnection.connected_lines.Count -gt 0 -and $controlConnection.entered_game_lines.Count -eq 0) {
        $humanSnapshotMissing += "control server-side entered-the-game confirmation"
    }
    $humanSnapshotExplanation = switch ($humanSnapshotStageVerdict) {
        "lane-attribution-present-but-no-human-snapshots" {
            "The pair pack preserved lane-local connection evidence, but telemetry and lane summaries never counted the client as a human participant."
        }
        "human-snapshots-present-control-only" {
            "Only the control lane accumulated human snapshots."
        }
        "human-snapshots-present-treatment-only" {
            "Only the treatment lane accumulated human snapshots."
        }
        "human-snapshots-present-both-lanes" {
            "Both lanes accumulated human snapshots."
        }
        default {
            "No saved telemetry or lane summary shows human participation."
        }
    }

    $finalSummaryStageVerdict = if ($pairSummaryShowsHumanSnapshots) {
        "pair-summary-recorded-human-signal"
    }
    elseif ($laneAttributionPresent) {
        "pair-summary-missed-human-signal-after-lane-attribution"
    }
    else {
        "pair-summary-no-human-signal"
    }
    $finalSummaryFound = @(
        ("pair classification: {0}" -f [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")),
        ("control lane verdict: {0}" -f [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "lane_verdict" -Default "")),
        ("treatment lane verdict: {0}" -f [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "lane_verdict" -Default ""))
    )
    $finalSummaryMissing = @()
    if (-not $pairSummaryShowsHumanSnapshots) {
        $finalSummaryMissing += "pair-summary human snapshot count above zero"
    }
    $finalSummaryExplanation = switch ($finalSummaryStageVerdict) {
        "pair-summary-missed-human-signal-after-lane-attribution" {
            "The final pair summary still ended with zero human snapshots even though the control lane log captured a client connection."
        }
        "pair-summary-recorded-human-signal" {
            "The final pair summary captured human participation."
        }
        default {
            "The final pair summary never recorded human signal."
        }
    }

    $auditVerdict = if ($controlSummaryShowsHumanSnapshots -and $treatmentSummaryShowsHumanSnapshots) {
        "human-snapshots-present-both-lanes"
    }
    elseif ($controlSummaryShowsHumanSnapshots) {
        "human-snapshots-present-control-only"
    }
    elseif ($treatmentSummaryShowsHumanSnapshots) {
        "human-snapshots-present-treatment-only"
    }
    elseif ($laneAttributionPresent) {
        "lane-attribution-present-but-no-human-snapshots"
    }
    elseif ($serverConnectionObserved) {
        "client-connected-but-no-lane-attribution"
    }
    elseif ($clientProcessObserved) {
        "client-launched-but-no-server-connect"
    }
    elseif ([bool](Get-ObjectPropertyValue -Object $controlJoin -Name "attempted" -Default $false) -or [bool](Get-ObjectPropertyValue -Object $treatmentJoin -Name "attempted" -Default $false)) {
        "client-launched-process-only"
    }
    else {
        "client-not-launched"
    }

    $breakPoint = switch ($auditVerdict) {
        "lane-attribution-present-but-no-human-snapshots" {
            "The saved chain breaks after lane-local server connection evidence and before telemetry or lane summaries ever count a human player."
        }
        "client-connected-but-no-lane-attribution" {
            "A client connection exists, but the pair pack never attributes it to a lane."
        }
        "client-launched-but-no-server-connect" {
            "hl.exe launched, but the server logs never show a real client connection."
        }
        "client-launched-process-only" {
            "The helper attempted launch, but there is no confirmed server connection."
        }
        "client-not-launched" {
            "No saved client-launch attempt exists in the pair."
        }
        default {
            "Human snapshot accumulation is present; the chain did not fail before lane summaries."
        }
    }

    $overallExplanation = if ($auditVerdict -eq "lane-attribution-present-but-no-human-snapshots") {
        "The local client launch path and the control-lane connection path both succeeded far enough to produce a real 'connected' line in the control HLDS log. The narrowest confirmed break point is after lane attribution and before human snapshot accumulation: there is no 'entered the game' line for the client, no telemetry sample with human_player_count > 0, and the final pair summary still records 0 human snapshots / 0 human presence seconds."
    }
    elseif ($auditVerdict -eq "client-launched-but-no-server-connect") {
        "The local client launched, but the saved server logs do not show a real client connection."
    }
    else {
        "The audit classified the saved pair evidence at '$auditVerdict'."
    }

    $report = [ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = ((Get-Date).ToUniversalTime().ToString("o"))
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $ResolvedPairRoot
        audit_verdict = $auditVerdict
        narrowest_confirmed_break_point = $breakPoint
        explanation = $overallExplanation
        client_discovery_verdict = [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "discovery_verdict" -Default "")
        client_path = [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "client_path_used" -Default "")
        control_join_attempted = [bool](Get-ObjectPropertyValue -Object $controlJoin -Name "attempted" -Default $false)
        treatment_join_attempted = [bool](Get-ObjectPropertyValue -Object $treatmentJoin -Name "attempted" -Default $false)
        client_process_observed = $clientProcessObserved
        server_logs_show_real_client_connection = $serverConnectionObserved
        pair_summary_shows_human_snapshots = $pairSummaryShowsHumanSnapshots
        control_lane_summary_shows_human_snapshots = $controlSummaryShowsHumanSnapshots
        treatment_lane_summary_shows_human_snapshots = $treatmentSummaryShowsHumanSnapshots
        live_monitor_ever_saw_human_presence = $liveMonitorSawHuman
        phase_flow_ever_advanced_because_of_human_signal = $phaseAdvancedBecauseOfHumanSignal
        client_launch_stage = Get-StageRecord -StageName "client-launch" -Verdict $launchStageVerdict -EvidenceFound $launchEvidenceFound -EvidenceMissing $launchEvidenceMissing -Explanation $launchExplanation
        server_connect_stage = Get-StageRecord -StageName "server-connect" -Verdict $serverConnectStageVerdict -EvidenceFound $serverConnectFound -EvidenceMissing $serverConnectMissing -Explanation $serverConnectExplanation
        lane_attribution_stage = Get-StageRecord -StageName "lane-attribution" -Verdict $laneAttributionStageVerdict -EvidenceFound $laneAttributionFound -EvidenceMissing $laneAttributionMissing -Explanation $laneAttributionExplanation
        human_snapshot_stage = Get-StageRecord -StageName "human-snapshot-accumulation" -Verdict $humanSnapshotStageVerdict -EvidenceFound $humanSnapshotFound -EvidenceMissing $humanSnapshotMissing -Explanation $humanSnapshotExplanation
        final_pair_summary_stage = Get-StageRecord -StageName "final-pair-summary" -Verdict $finalSummaryStageVerdict -EvidenceFound $finalSummaryFound -EvidenceMissing $finalSummaryMissing -Explanation $finalSummaryExplanation
        supporting_observability = [ordered]@{
            control_join_helper_command = [string](Get-ObjectPropertyValue -Object $controlJoin -Name "helper_command" -Default "")
            control_join_helper_result_verdict = [string](Get-ObjectPropertyValue -Object $controlJoin -Name "helper_result_verdict" -Default "")
            control_launch_command = [string](Get-ObjectPropertyValue -Object $controlJoin -Name "launch_command" -Default "")
            control_launch_started_at_utc = [string](Get-ObjectPropertyValue -Object $controlJoin -Name "launch_started_at_utc" -Default "")
            control_process_id = [int](Get-ObjectPropertyValue -Object $controlJoin -Name "process_id" -Default 0)
            treatment_join_helper_command = [string](Get-ObjectPropertyValue -Object $treatmentJoin -Name "helper_command" -Default "")
            treatment_join_helper_result_verdict = [string](Get-ObjectPropertyValue -Object $treatmentJoin -Name "helper_result_verdict" -Default "")
            treatment_launch_command = [string](Get-ObjectPropertyValue -Object $treatmentJoin -Name "launch_command" -Default "")
            treatment_launch_started_at_utc = [string](Get-ObjectPropertyValue -Object $treatmentJoin -Name "launch_started_at_utc" -Default "")
            treatment_process_id = [int](Get-ObjectPropertyValue -Object $treatmentJoin -Name "process_id" -Default 0)
            attempt_stdout_log = $attemptStdoutPath
            attempt_stderr_log = $attemptStderrPath
            control_hlds_stdout_log = $controlLane.HldsStdoutLogPath
            control_hlds_stderr_log = $controlLane.HldsStderrLogPath
            treatment_hlds_stdout_log = $treatmentLane.HldsStdoutLogPath
            treatment_hlds_stderr_log = $treatmentLane.HldsStderrLogPath
        }
        artifacts = [ordered]@{
            human_participation_conservative_attempt_json = $humanAttemptPath
            strong_signal_conservative_attempt_json = $strongSignalAttemptPath
            pair_summary_json = $pairSummaryPath
            control_lane_summary_json = $controlLane.SummaryPath
            treatment_lane_summary_json = $treatmentLane.SummaryPath
            control_lane_session_pack_json = $controlLane.SessionPackPath
            treatment_lane_session_pack_json = $treatmentLane.SessionPackPath
            control_lane_human_presence_timeline_ndjson = $controlLane.HumanPresenceTimelinePath
            treatment_lane_human_presence_timeline_ndjson = $treatmentLane.HumanPresenceTimelinePath
            live_monitor_status_json = $monitorStatusPath
            conservative_phase_flow_json = $phaseFlowPath
            control_to_treatment_switch_json = $controlSwitchPath
            treatment_patch_window_json = $treatmentPatchPath
            mission_execution_json = $missionExecutionPath
            monitor_verdict_history_ndjson = $monitorHistoryPath
        }
    }

    return [pscustomobject]$report
}

function Get-AuditMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Client Presence Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Report.prompt_id)") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Audit verdict: $($Report.audit_verdict)") | Out-Null
    $lines.Add("- Narrowest confirmed break point: $($Report.narrowest_confirmed_break_point)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Chain Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Client discovery verdict: $($Report.client_discovery_verdict)") | Out-Null
    $lines.Add("- Client path: $($Report.client_path)") | Out-Null
    $lines.Add("- Control join attempted: $(Get-BoolString -Value ([bool]$Report.control_join_attempted))") | Out-Null
    $lines.Add("- Treatment join attempted: $(Get-BoolString -Value ([bool]$Report.treatment_join_attempted))") | Out-Null
    $lines.Add("- Client process observed: $(Get-BoolString -Value ([bool]$Report.client_process_observed))") | Out-Null
    $lines.Add("- Server logs show a real client connection: $(Get-BoolString -Value ([bool]$Report.server_logs_show_real_client_connection))") | Out-Null
    $lines.Add("- Pair summary shows human snapshots: $(Get-BoolString -Value ([bool]$Report.pair_summary_shows_human_snapshots))") | Out-Null
    $lines.Add("- Control lane summary shows human snapshots: $(Get-BoolString -Value ([bool]$Report.control_lane_summary_shows_human_snapshots))") | Out-Null
    $lines.Add("- Treatment lane summary shows human snapshots: $(Get-BoolString -Value ([bool]$Report.treatment_lane_summary_shows_human_snapshots))") | Out-Null
    $lines.Add("- Live monitor ever saw human presence: $(Get-BoolString -Value ([bool]$Report.live_monitor_ever_saw_human_presence))") | Out-Null
    $lines.Add("- Phase flow ever advanced because of human signal: $(Get-BoolString -Value ([bool]$Report.phase_flow_ever_advanced_because_of_human_signal))") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Stage Verdicts") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($stage in @($Report.client_launch_stage, $Report.server_connect_stage, $Report.lane_attribution_stage, $Report.human_snapshot_stage, $Report.final_pair_summary_stage)) {
        $lines.Add(("### {0}" -f $stage.stage)) | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("- Verdict: $($stage.verdict)") | Out-Null
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
    $lines.Add("## Observability Paths") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Attempt stdout log: $($Report.supporting_observability.attempt_stdout_log)") | Out-Null
    $lines.Add("- Attempt stderr log: $($Report.supporting_observability.attempt_stderr_log)") | Out-Null
    $lines.Add("- Control HLDS stdout log: $($Report.supporting_observability.control_hlds_stdout_log)") | Out-Null
    $lines.Add("- Treatment HLDS stdout log: $($Report.supporting_observability.treatment_hlds_stdout_log)") | Out-Null
    $lines.Add("- Control launch command: $($Report.supporting_observability.control_launch_command)") | Out-Null
    $lines.Add("- Control launch started at UTC: $($Report.supporting_observability.control_launch_started_at_utc)") | Out-Null
    $lines.Add("- Control process ID: $($Report.supporting_observability.control_process_id)") | Out-Null
    $lines.Add("- Treatment launch started at UTC: $($Report.supporting_observability.treatment_launch_started_at_utc)") | Out-Null
    $lines.Add("- Treatment process ID: $($Report.supporting_observability.treatment_process_id)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot)
}

$resolvedPairRoot = Resolve-PairRoot -ExplicitPairRoot $PairRoot -PreferLatest:$UseLatest -ResolvedLabRoot $resolvedLabRoot

if ($WatchActiveJoin -and -not $Once) {
    while ($true) {
        $report = Invoke-ClientPresenceAudit -ResolvedPairRoot $resolvedPairRoot
        $jsonPath = Join-Path $resolvedPairRoot "client_presence_audit.json"
        $markdownPath = Join-Path $resolvedPairRoot "client_presence_audit.md"
        Write-JsonFile -Path $jsonPath -Value $report
        Write-TextFile -Path $markdownPath -Value (Get-AuditMarkdown -Report $report)
        Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $report.audit_verdict)
        Write-Host "  Narrowest confirmed break point: $($report.narrowest_confirmed_break_point)"
        Write-Host "  Explanation: $($report.explanation)"
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    }
}

$report = Invoke-ClientPresenceAudit -ResolvedPairRoot $resolvedPairRoot
$jsonPath = Join-Path $resolvedPairRoot "client_presence_audit.json"
$markdownPath = Join-Path $resolvedPairRoot "client_presence_audit.md"
Write-JsonFile -Path $jsonPath -Value $report
Write-TextFile -Path $markdownPath -Value (Get-AuditMarkdown -Report $report)

Write-Host "Client presence audit:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Audit verdict: $($report.audit_verdict)"
Write-Host "  Narrowest confirmed break point: $($report.narrowest_confirmed_break_point)"
Write-Host "  JSON: $jsonPath"
Write-Host "  Markdown: $markdownPath"

[pscustomobject]@{
    ClientPresenceAuditJsonPath = $jsonPath
    ClientPresenceAuditMarkdownPath = $markdownPath
    PairRoot = $resolvedPairRoot
    AuditVerdict = $report.audit_verdict
    BreakPoint = $report.narrowest_confirmed_break_point
}
