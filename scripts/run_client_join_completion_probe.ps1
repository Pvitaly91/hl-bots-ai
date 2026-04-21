[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ClientExePath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$Port = 27016,
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
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }

        try {
            $records.Add(($trimmed | ConvertFrom-Json)) | Out-Null
        }
        catch {
        }
    }

    return @($records.ToArray())
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

function Get-FileSnapshot {
    param([string]$Path)

    $resolvedPath = Resolve-ExistingPath -Path $Path
    if (-not $resolvedPath) {
        return [pscustomobject]@{
            path = $Path
            exists = $false
            last_write_time_utc = ""
            length_bytes = 0
            line_count = 0
        }
    }

    $item = Get-Item -LiteralPath $resolvedPath
    $lineCount = 0
    try {
        $lineCount = @(Get-Content -LiteralPath $resolvedPath).Count
    }
    catch {
        $lineCount = 0
    }

    return [pscustomobject]@{
        path = $resolvedPath
        exists = $true
        last_write_time_utc = $item.LastWriteTimeUtc.ToString("o")
        length_bytes = [int64]$item.Length
        line_count = $lineCount
    }
}

function Copy-ArtifactIfExists {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $resolvedSourcePath = Resolve-ExistingPath -Path $SourcePath
    if (-not $resolvedSourcePath) {
        return ""
    }

    $parent = Split-Path -Path $DestinationPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    Copy-Item -LiteralPath $resolvedSourcePath -Destination $DestinationPath -Force
    return $DestinationPath
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

function Test-LocalPortActive {
    param([int]$Port)

    $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    if ($null -ne $udp) {
        return $true
    }

    $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $tcp
}

function Wait-ForPortActive {
    param(
        [int]$Port,
        [System.Diagnostics.Process]$ProbeProcess,
        [int]$TimeoutSeconds = 180
    )

    $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        if (Test-LocalPortActive -Port $Port) {
            return [pscustomobject]@{
                Ready = $true
                Explanation = "Detected an active listener on port $Port."
            }
        }

        if ($null -ne $ProbeProcess) {
            try {
                if ($ProbeProcess.HasExited) {
                    return [pscustomobject]@{
                        Ready = $false
                        Explanation = "The bounded control-lane probe exited before port $Port became active."
                    }
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        Ready = $false
        Explanation = "Timed out waiting for port $Port to become active."
    }
}

function Wait-ForLaneRoot {
    param(
        [string]$LaneOutputRoot,
        [System.Diagnostics.Process]$ProbeProcess,
        [int]$TimeoutSeconds = 180
    )

    $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        $candidate = Get-ChildItem -LiteralPath $LaneOutputRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($null -ne $candidate) {
            return [pscustomobject]@{
                Ready = $true
                LaneRoot = $candidate.FullName
                Explanation = "Detected the bounded control-lane root."
            }
        }

        if ($null -ne $ProbeProcess) {
            try {
                if ($ProbeProcess.HasExited) {
                    return [pscustomobject]@{
                        Ready = $false
                        LaneRoot = ""
                        Explanation = "The bounded control-lane probe exited before a lane root was created."
                    }
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        Ready = $false
        LaneRoot = ""
        Explanation = "Timed out waiting for the bounded control-lane root."
    }
}

function Stop-ProcessIfRunning {
    param(
        [int]$ProcessId,
        [string]$Reason
    )

    if ($ProcessId -le 0) {
        return $false
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Host "  Stopped process PID $ProcessId ($Reason)."
        return $true
    }
    catch {
        Write-Warning "Could not stop process PID $ProcessId ($Reason): $($_.Exception.Message)"
        return $false
    }
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

function Get-BoolString {
    param([bool]$Value)

    if ($Value) {
        return "yes"
    }

    return "no"
}

function Get-ProbeMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Client Join Completion Probe") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Report.prompt_id)") | Out-Null
    $lines.Add("- Probe verdict: $($Report.probe_verdict)") | Out-Null
    $lines.Add("- Narrowest confirmed break point: $($Report.narrowest_confirmed_break_point)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Probe root: $($Report.probe_root)") | Out-Null
    $lines.Add("- Lane root: $($Report.lane_root)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Mission Inputs") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Map: $($Report.map)") | Out-Null
    $lines.Add("- Bot count: $($Report.bot_count)") | Out-Null
    $lines.Add("- Bot skill: $($Report.bot_skill)") | Out-Null
    $lines.Add("- Port: $($Report.port)") | Out-Null
    $lines.Add("- Control minimum human snapshots: $($Report.thresholds.min_human_snapshots)") | Out-Null
    $lines.Add("- Control minimum human presence seconds: $($Report.thresholds.min_human_presence_seconds)") | Out-Null
    $lines.Add("- Requested capture seconds: $($Report.thresholds.duration_seconds)") | Out-Null
    $lines.Add("- Human join grace seconds: $($Report.thresholds.human_join_grace_seconds)") | Out-Null
    $lines.Add("- Launch command prepared: $(Get-BoolString -Value ([bool]$Report.launch_observability.launch_command_prepared))") | Out-Null
    $lines.Add("- Client path: $($Report.launch_observability.client_path)") | Out-Null
    $lines.Add("- Client working directory: $($Report.launch_observability.client_working_directory)") | Out-Null
    $lines.Add("- Join target: $($Report.launch_observability.join_target)") | Out-Null
    $lines.Add("- qconsole path: $($Report.launch_observability.qconsole_path)") | Out-Null
    $lines.Add("- debug log path: $($Report.launch_observability.debug_log_path)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Stage Verdicts") | Out-Null
    $lines.Add("") | Out-Null

    foreach ($stage in @(
            $Report.stages.client_discovered,
            $Report.stages.launch_command_prepared,
            $Report.stages.client_process_launched,
            $Report.stages.server_connection_seen,
            $Report.stages.entered_the_game_seen,
            $Report.stages.first_human_snapshot_seen,
            $Report.stages.human_presence_accumulating,
            $Report.stages.control_lane_human_usable
        )) {
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

    $lines.Add("## Probe Metrics") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control lane human snapshots: $($Report.final_metrics.human_snapshots_count)") | Out-Null
    $lines.Add("- Control lane human presence seconds: $($Report.final_metrics.seconds_with_human_presence)") | Out-Null
    $lines.Add("- Control lane human-usable: $(Get-BoolString -Value ([bool]$Report.final_metrics.control_lane_human_usable))") | Out-Null
    $lines.Add("- Entered-the-game observed: $(Get-BoolString -Value ([bool]$Report.final_metrics.entered_the_game_seen))") | Out-Null
    $lines.Add("- First human snapshot observed: $(Get-BoolString -Value ([bool]$Report.final_metrics.first_human_snapshot_seen))") | Out-Null
    $lines.Add("- Human presence accumulating: $(Get-BoolString -Value ([bool]$Report.final_metrics.human_presence_accumulating))") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe lane stdout log: $($Report.artifacts.probe_lane_stdout_log)") | Out-Null
    $lines.Add("- Probe lane stderr log: $($Report.artifacts.probe_lane_stderr_log)") | Out-Null
    $lines.Add("- Lane summary JSON: $($Report.artifacts.lane_summary_json)") | Out-Null
    $lines.Add("- Lane session pack JSON: $($Report.artifacts.session_pack_json)") | Out-Null
    $lines.Add("- Lane human presence timeline: $($Report.artifacts.human_presence_timeline_ndjson)") | Out-Null
    $lines.Add("- Lane HLDS stdout log: $($Report.artifacts.hlds_stdout_log)") | Out-Null
    $lines.Add("- Client qconsole copy: $($Report.artifacts.client_qconsole_copy)") | Out-Null
    $lines.Add("- Client debug log copy: $($Report.artifacts.client_debug_log_copy)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $LabRoot)
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "join_completion_probes")
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $OutputRoot)
}

$probeRootName = "{0}-{1}-b{2}-s{3}-p{4}-control-join-completion-probe" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Map, $BotCount, $BotSkill, $Port
$probeRoot = New-UniqueDirectoryPath -ParentPath $resolvedOutputRoot -LeafName $probeRootName
$laneOutputRoot = Ensure-Directory -Path (Join-Path $probeRoot "lane_capture")
$probeStdoutLog = Join-Path $probeRoot "probe_lane.stdout.log"
$probeStderrLog = Join-Path $probeRoot "probe_lane.stderr.log"
$reportJsonPath = Join-Path $probeRoot "client_join_completion_probe.json"
$reportMarkdownPath = Join-Path $probeRoot "client_join_completion_probe.md"

$resolvedHldsRoot = Get-HldsRootDefault -LabRoot $resolvedLabRoot
$runtimeDir = Get-AiRuntimeDir -HldsRoot $resolvedHldsRoot
$liveTelemetryPath = Join-Path $runtimeDir "telemetry.json"
$liveServerStdoutLog = Join-Path (Get-LogsRootDefault -LabRoot $resolvedLabRoot) "hlds.stdout.log"
$launchPlan = Get-HalfLifeClientLaunchPlan -PreferredClientPath $ClientExePath -Port $Port
$launchPrepared = -not [string]::IsNullOrWhiteSpace([string]$launchPlan.command_text)
$preQconsoleSnapshot = Get-FileSnapshot -Path $launchPlan.qconsole_path
$preDebugSnapshot = Get-FileSnapshot -Path $launchPlan.debug_log_path

$probeProcess = $null
$probeLaneRoot = ""
$joinExecution = $null
$joinProcessId = 0
$joinStartedAtUtc = ""
$postQconsoleSnapshot = $preQconsoleSnapshot
$postDebugSnapshot = $preDebugSnapshot
$qconsoleCopyPath = ""
$debugLogCopyPath = ""
$portReady = $false
$laneRootReady = $false
$controlConnectionEvidence = [pscustomobject]@{
    connected_lines = @()
    entered_game_lines = @()
    raw_entered_game_lines = @()
    connected_players = @()
}

$summaryPath = ""
$summaryPayload = $null
$primaryLaneSummary = $null
$sessionPackPath = ""
$sessionPack = $null
$humanPresenceTimelinePath = ""
$humanPresenceTimeline = @()
$laneJsonPath = ""
$laneJson = $null
$laneStdoutLogPath = ""
$laneStdoutLogLines = @()
$laneStderrLogPath = ""
$finalHumanSnapshots = 0
$finalHumanPresenceSeconds = 0.0
$firstHumanSeenTimestampUtc = ""
$firstHumanSeenOffsetSeconds = $null
$firstHumanTimelineRecord = $null
$telemetrySnapshotObserved = $false

try {
    if (-not $DryRun -and -not [bool]$launchPlan.launchable) {
        throw [string]$launchPlan.client_discovery.explanation
    }

    $powershellExe = (Get-Command powershell -ErrorAction Stop).Source
    $evalScriptPath = Join-Path $PSScriptRoot "run_balance_eval.ps1"
    $evalArgumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $evalScriptPath,
        "-Mode", "NoAI",
        "-Map", $Map,
        "-BotCount", [string]$BotCount,
        "-BotSkill", [string]$BotSkill,
        "-Port", [string]$Port,
        "-LabRoot", $resolvedLabRoot,
        "-OutputRoot", $laneOutputRoot,
        "-DurationSeconds", [string]$DurationSeconds,
        "-WaitForHumanJoin",
        "-HumanJoinGraceSeconds", [string]$HumanJoinGraceSeconds,
        "-MinHumanSnapshots", [string]$MinHumanSnapshots,
        "-MinHumanPresenceSeconds", [string]$MinHumanPresenceSeconds,
        "-LaneLabel", "control-join-completion-probe",
        "-SkipSteamCmdUpdate",
        "-SkipMetamodDownload"
    )
    $evalCommandText = @("powershell" + ($evalArgumentList | ForEach-Object { " " + (Format-ProcessArgumentText -Value ([string]$_)) })) -join ""

    if (-not $DryRun) {
        Write-Host "Starting bounded control-lane probe..."
        Write-Host "  Command: $evalCommandText"

        $probeProcess = Start-Process `
            -FilePath $powershellExe `
            -ArgumentList $evalArgumentList `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $probeStdoutLog `
            -RedirectStandardError $probeStderrLog `
            -PassThru

        $probeTimeoutSeconds = [Math]::Max(90, $HumanJoinGraceSeconds + $DurationSeconds + 30)
        $portWait = Wait-ForPortActive -Port $Port -ProbeProcess $probeProcess -TimeoutSeconds $probeTimeoutSeconds
        $portReady = [bool]$portWait.Ready
        Write-Host "  Port readiness: $($portWait.Explanation)"

        $laneRootWait = Wait-ForLaneRoot -LaneOutputRoot $laneOutputRoot -ProbeProcess $probeProcess -TimeoutSeconds $probeTimeoutSeconds
        $laneRootReady = [bool]$laneRootWait.Ready
        $probeLaneRoot = $laneRootWait.LaneRoot
        Write-Host "  Lane-root readiness: $($laneRootWait.Explanation)"

        if ($portReady) {
            if ($JoinDelaySeconds -gt 0) {
                Start-Sleep -Seconds $JoinDelaySeconds
            }

            $joinScriptPath = Join-Path $PSScriptRoot "join_live_pair_lane.ps1"
            $joinExecution = & $joinScriptPath -Lane Control -Port $Port -Map $Map -ClientExePath $launchPlan.client_exe_path
            $joinProcessId = [int](Get-ObjectPropertyValue -Object $joinExecution -Name "ProcessId" -Default 0)
            $joinStartedAtUtc = [string](Get-ObjectPropertyValue -Object $joinExecution -Name "LaunchStartedAtUtc" -Default "")
            Write-Host "  Join helper verdict: $([string](Get-ObjectPropertyValue -Object $joinExecution -Name 'ResultVerdict' -Default ''))"
        }

        $probeDeadlineUtc = (Get-Date).ToUniversalTime().AddSeconds([Math]::Max(90, $HumanJoinGraceSeconds + $DurationSeconds + 30))
        while ($null -ne $probeProcess -and -not $probeProcess.HasExited -and (Get-Date).ToUniversalTime() -lt $probeDeadlineUtc) {
            $telemetrySnapshotObserved = $telemetrySnapshotObserved -or (Test-Path -LiteralPath $liveTelemetryPath)
            Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
            try {
                $probeProcess.Refresh()
            }
            catch {
                break
            }
        }

        if ($null -ne $probeProcess) {
            try {
                $probeProcess.Refresh()
            }
            catch {
            }
            if (-not $probeProcess.HasExited) {
                Write-Warning "The bounded probe exceeded its wait budget and will be stopped."
                Stop-ProcessIfRunning -ProcessId $probeProcess.Id -Reason "probe timeout" | Out-Null
            }
        }
    }
}
finally {
    Stop-ProcessIfRunning -ProcessId $joinProcessId -Reason "bounded join probe cleanup" | Out-Null
}

$postQconsoleSnapshot = Get-FileSnapshot -Path $launchPlan.qconsole_path
$postDebugSnapshot = Get-FileSnapshot -Path $launchPlan.debug_log_path
$qconsoleCopyPath = Copy-ArtifactIfExists -SourcePath $launchPlan.qconsole_path -DestinationPath (Join-Path $probeRoot "client.qconsole.log")
$debugLogCopyPath = Copy-ArtifactIfExists -SourcePath $launchPlan.debug_log_path -DestinationPath (Join-Path $probeRoot "client.debug.log")

if ($probeLaneRoot) {
    $probeLaneRoot = Resolve-ExistingPath -Path $probeLaneRoot
    $summaryPath = Resolve-ExistingPath -Path (Join-Path $probeLaneRoot "summary.json")
    $summaryPayload = Read-JsonFile -Path $summaryPath
    $primaryLaneSummary = Get-ObjectPropertyValue -Object $summaryPayload -Name "primary_lane" -Default $null
    $sessionPackPath = Resolve-ExistingPath -Path (Join-Path $probeLaneRoot "session_pack.json")
    $sessionPack = Read-JsonFile -Path $sessionPackPath
    $humanPresenceTimelinePath = Resolve-ExistingPath -Path (Join-Path $probeLaneRoot "human_presence_timeline.ndjson")
    $humanPresenceTimeline = Read-NdjsonFile -Path $humanPresenceTimelinePath
    $laneJsonPath = Resolve-ExistingPath -Path (Join-Path $probeLaneRoot "lane.json")
    $laneJson = Read-JsonFile -Path $laneJsonPath
    $laneStdoutLogPath = Resolve-ExistingPath -Path (Join-Path $probeLaneRoot "hlds.stdout.log")
    $laneStderrLogPath = Resolve-ExistingPath -Path (Join-Path $probeLaneRoot "hlds.stderr.log")
    $laneStdoutLogLines = if ($laneStdoutLogPath) { @(Get-Content -LiteralPath $laneStdoutLogPath) } else { @() }
    $controlConnectionEvidence = Get-ConnectionEvidence -LogLines $laneStdoutLogLines

    $finalHumanSnapshots = [int](Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "human_snapshots_count" -Default 0)
    $finalHumanPresenceSeconds = [double](Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "seconds_with_human_presence" -Default 0.0)
    $firstHumanSeenTimestampUtc = [string](Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "first_human_seen_timestamp_utc" -Default "")
    $firstHumanSeenOffsetSeconds = Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "first_human_seen_offset_seconds" -Default $null
}

if (-not $firstHumanSeenTimestampUtc -and $humanPresenceTimeline.Count -gt 0) {
    $firstHumanTimelineRecord = $humanPresenceTimeline | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "human_present" -Default $false) } | Select-Object -First 1
    if ($null -ne $firstHumanTimelineRecord) {
        $firstHumanSeenTimestampUtc = [string](Get-ObjectPropertyValue -Object $firstHumanTimelineRecord -Name "timestamp_utc" -Default "")
        $firstHumanSeenOffsetSeconds = Get-ObjectPropertyValue -Object $firstHumanTimelineRecord -Name "offset_seconds" -Default $null
    }
}

$enteredGameSeenExact = @($controlConnectionEvidence.entered_game_lines).Count -gt 0
$firstHumanSnapshotSeen = $finalHumanSnapshots -gt 0
$enteredGameEquivalentSeen = $enteredGameSeenExact -or $firstHumanSnapshotSeen
$humanPresenceAccumulating = $firstHumanSnapshotSeen -and ($finalHumanPresenceSeconds -ge [Math]::Min(5.0, [double]$MinHumanPresenceSeconds) -or $finalHumanSnapshots -ge 2)
$controlLaneHumanUsable = $finalHumanSnapshots -ge $MinHumanSnapshots -and $finalHumanPresenceSeconds -ge [double]$MinHumanPresenceSeconds

$clientDiscoveredStage = Get-StageRecord `
    -StageName "client-discovered" `
    -Verdict $(if ([bool]$launchPlan.launchable) { "client-discovered" } else { "launch-failed" }) `
    -Reached ([bool]$launchPlan.launchable) `
    -EvidenceFound @(
        ("client discovery verdict: {0}" -f [string]$launchPlan.client_discovery.discovery_verdict),
        ("client path: {0}" -f [string]$launchPlan.client_exe_path)
    ) `
    -EvidenceMissing $(if ([bool]$launchPlan.launchable) { @() } else { @("launchable local Half-Life client") }) `
    -Explanation ([string]$launchPlan.client_discovery.explanation)

$launchCommandPreparedStage = Get-StageRecord `
    -StageName "launch-command-prepared" `
    -Verdict $(if ($launchPrepared) { "launch-command-prepared" } else { "launch-failed" }) `
    -Reached $launchPrepared `
    -EvidenceFound $(if ($launchPrepared) {
            @(
                ("launch command: {0}" -f [string]$launchPlan.command_text),
                ("client working directory: {0}" -f [string]$launchPlan.client_working_directory),
                ("join target: {0}" -f [string]$launchPlan.join_info.LoopbackAddress)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($launchPrepared) { @() } else { @("launch command text") }) `
    -Explanation $(if ($launchPrepared) {
            "Prepared the exact hl.exe launch command and working directory for the bounded control-lane probe."
        } else {
            "The probe could not prepare a launch command."
        })

$clientProcessLaunchedStage = Get-StageRecord `
    -StageName "client-process-launched" `
    -Verdict $(if ($DryRun) { "dry-run-no-process-launch" } elseif ($joinProcessId -gt 0) { "client-process-launched" } else { "launch-failed" }) `
    -Reached ($joinProcessId -gt 0) `
    -EvidenceFound $(if ($joinProcessId -gt 0) {
            @(
                ("join helper verdict: {0}" -f [string](Get-ObjectPropertyValue -Object $joinExecution -Name "ResultVerdict" -Default "")),
                ("process id: {0}" -f $joinProcessId),
                ("launch timestamp UTC: {0}" -f $joinStartedAtUtc)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($DryRun) { @("client process launch was intentionally skipped") } elseif ($joinProcessId -gt 0) { @() } else { @("observed client process id") }) `
    -Explanation $(if ($DryRun) {
            "Dry-run mode prepared the launch path but did not start hl.exe."
        } elseif ($joinProcessId -gt 0) {
            "The join helper started hl.exe and recorded a local process id."
        } else {
            "The join helper did not record a local client process id."
        })

$serverConnectionSeenStage = Get-StageRecord `
    -StageName "server-connection-seen" `
    -Verdict $(if (@($controlConnectionEvidence.connected_lines).Count -gt 0) { "server-connection-seen" } elseif ($joinProcessId -gt 0) { "launched-but-no-server-connect" } else { "launch-failed" }) `
    -Reached (@($controlConnectionEvidence.connected_lines).Count -gt 0) `
    -EvidenceFound $(if (@($controlConnectionEvidence.connected_lines).Count -gt 0) {
            @(
                ("server log path: {0}" -f $laneStdoutLogPath),
                ("connected line: {0}" -f $controlConnectionEvidence.connected_lines[0])
            )
        } else { @() }) `
    -EvidenceMissing $(if (@($controlConnectionEvidence.connected_lines).Count -gt 0) { @() } else { @("server-side connected line") }) `
    -Explanation $(if (@($controlConnectionEvidence.connected_lines).Count -gt 0) {
            "The control-lane HLDS log shows a real client connection."
        } elseif ($joinProcessId -gt 0) {
            "hl.exe launched, but the control-lane HLDS log does not show a real client connection."
        } else {
            "The probe never reached a point where a server connection could be confirmed."
        })

$enteredGameSeenStage = Get-StageRecord `
    -StageName "entered-the-game-seen" `
    -Verdict $(if ($enteredGameSeenExact) { "entered-the-game-seen" } elseif ($firstHumanSnapshotSeen) { "entered-the-game-equivalent-seen-via-human-snapshot" } elseif (@($controlConnectionEvidence.connected_lines).Count -gt 0) { "connected-but-not-entered-game" } else { "launch-failed" }) `
    -Reached $enteredGameEquivalentSeen `
    -EvidenceFound $(if ($enteredGameSeenExact) {
            @(("entered-the-game line: {0}" -f $controlConnectionEvidence.entered_game_lines[0]))
        } elseif ($firstHumanSnapshotSeen) {
            @("saved control-lane telemetry later counted a human player, which is equivalent to an in-game join state")
        } else { @() }) `
    -EvidenceMissing $(if ($enteredGameEquivalentSeen) { @() } else { @("server-side entered-the-game confirmation") }) `
    -Explanation $(if ($enteredGameSeenExact) {
            "The control-lane HLDS log shows the client fully entered the game."
        } elseif ($firstHumanSnapshotSeen) {
            "The explicit HLDS 'entered the game' line was not preserved, but the lane later recorded a real human snapshot."
        } elseif (@($controlConnectionEvidence.connected_lines).Count -gt 0) {
            "The client connected to the control lane, but the saved server log never shows 'entered the game'."
        } else {
            "The probe never reached a confirmed server connection."
        })

$firstHumanSnapshotSeenStage = Get-StageRecord `
    -StageName "first-human-snapshot-seen" `
    -Verdict $(if ($firstHumanSnapshotSeen) { "first-human-snapshot-seen" } elseif ($enteredGameEquivalentSeen) { "entered-game-but-no-human-snapshot" } else { "launch-failed" }) `
    -Reached $firstHumanSnapshotSeen `
    -EvidenceFound $(if ($firstHumanSnapshotSeen) {
            @(
                ("human snapshots count: {0}" -f $finalHumanSnapshots),
                ("first human snapshot timestamp UTC: {0}" -f $firstHumanSeenTimestampUtc),
                ("first human snapshot offset seconds: {0}" -f $firstHumanSeenOffsetSeconds)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($firstHumanSnapshotSeen) { @() } else { @("saved control-lane human snapshot") }) `
    -Explanation $(if ($firstHumanSnapshotSeen) {
            "The bounded control lane recorded at least one human snapshot in saved evidence."
        } elseif ($enteredGameEquivalentSeen) {
            "The client reached or effectively reached the in-game state, but saved telemetry never counted a human player."
        } else {
            "The probe never reached a confirmed in-game join state."
        })

$humanPresenceAccumulatingStage = Get-StageRecord `
    -StageName "human-presence-accumulating" `
    -Verdict $(if ($humanPresenceAccumulating) { "human-presence-accumulating" } elseif ($firstHumanSnapshotSeen) { "human-snapshot-seen-but-presence-does-not-accumulate" } else { "launch-failed" }) `
    -Reached $humanPresenceAccumulating `
    -EvidenceFound $(if ($humanPresenceAccumulating) {
            @(
                ("human presence seconds: {0}" -f $finalHumanPresenceSeconds),
                ("human snapshots count: {0}" -f $finalHumanSnapshots)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($humanPresenceAccumulating) { @() } else { @("accumulated human presence beyond the first snapshot") }) `
    -Explanation $(if ($humanPresenceAccumulating) {
            "Human presence was not limited to a single transient sample; saved control-lane evidence shows accumulation."
        } elseif ($firstHumanSnapshotSeen) {
            "A first human snapshot appeared, but saved control-lane evidence did not accumulate meaningful presence afterward."
        } else {
            "No saved control-lane human snapshot exists yet."
        })

$controlLaneHumanUsableStage = Get-StageRecord `
    -StageName "control-lane-human-usable" `
    -Verdict $(if ($controlLaneHumanUsable) { "control-lane-human-usable" } elseif ($humanPresenceAccumulating) { "human-presence-accumulating-but-below-usable-threshold" } else { "launch-failed" }) `
    -Reached $controlLaneHumanUsable `
    -EvidenceFound $(if ($controlLaneHumanUsable) {
            @(
                ("human snapshots count: {0} / target {1}" -f $finalHumanSnapshots, $MinHumanSnapshots),
                ("human presence seconds: {0} / target {1}" -f $finalHumanPresenceSeconds, $MinHumanPresenceSeconds)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($controlLaneHumanUsable) { @() } else {
            @(
                ("human snapshots target not yet met: actual {0}, target {1}" -f $finalHumanSnapshots, $MinHumanSnapshots),
                ("human presence seconds target not yet met: actual {0}, target {1}" -f $finalHumanPresenceSeconds, $MinHumanPresenceSeconds)
            )
        }) `
    -Explanation $(if ($controlLaneHumanUsable) {
            "The bounded control-lane probe reached the minimum human-usable threshold."
        } elseif ($humanPresenceAccumulating) {
            "The bounded control-lane probe began accumulating human presence, but it did not yet clear the configured human-usable threshold."
        } else {
            "The bounded control-lane probe never accumulated enough saved human evidence to be usable."
        })

$probeVerdict = if ($controlLaneHumanUsable) {
    "control-lane-human-usable"
}
elseif (-not [bool]$launchPlan.launchable -or ($launchPrepared -and -not $joinProcessId -and -not $DryRun)) {
    "launch-failed"
}
elseif ($DryRun) {
    "dry-run-launch-command-prepared"
}
elseif (@($controlConnectionEvidence.connected_lines).Count -eq 0) {
    "launched-but-no-server-connect"
}
elseif (-not $enteredGameEquivalentSeen) {
    "connected-but-not-entered-game"
}
elseif (-not $firstHumanSnapshotSeen) {
    "entered-game-but-no-human-snapshot"
}
elseif (-not $humanPresenceAccumulating) {
    "human-snapshot-seen-but-presence-does-not-accumulate"
}
else {
    "inconclusive-manual-review"
}

$narrowestBreakPoint = switch ($probeVerdict) {
    "control-lane-human-usable" {
        "The working launch path reached a confirmed join state, the first counted human snapshot, and accumulating human presence in saved control-lane evidence."
    }
    "launch-failed" {
        "The probe did not complete a trustworthy hl.exe launch."
    }
    "launched-but-no-server-connect" {
        "hl.exe launched, but the control-lane HLDS log never showed a real client connection."
    }
    "connected-but-not-entered-game" {
        "The control-lane HLDS log showed a real connection, but there was still no trusted 'entered the game' or equivalent saved join-state transition."
    }
    "entered-game-but-no-human-snapshot" {
        "The client reached or effectively reached the in-game state, but the saved control-lane evidence still never counted a human snapshot."
    }
    "human-snapshot-seen-but-presence-does-not-accumulate" {
        "The first human snapshot appeared, but saved control-lane evidence still failed to accumulate meaningful human presence."
    }
    default {
        "The probe moved partway through the join chain, but the saved evidence still needs manual review."
    }
}

$overallExplanation = switch ($probeVerdict) {
    "control-lane-human-usable" {
        "The bounded control-lane probe cleared the join chain end to end: the client launched, the server recognized the join state strongly enough to produce a counted human snapshot, and saved control-lane evidence started accumulating real human presence."
    }
    "connected-but-not-entered-game" {
        "The working-directory launch repair did not move the break far enough. The probe still reached server-side connection evidence without a trusted entered-the-game or first-human-snapshot transition."
    }
    "entered-game-but-no-human-snapshot" {
        "The probe moved past the earlier server-connect boundary into a confirmed join state, but saved control-lane telemetry still did not count the first human snapshot."
    }
    "human-snapshot-seen-but-presence-does-not-accumulate" {
        "The probe moved past the earlier missing first-human-snapshot boundary, but saved control-lane evidence still did not accumulate meaningful human presence."
    }
    "launched-but-no-server-connect" {
        "The probe launched hl.exe, but the saved server logs never confirmed a real client connection."
    }
    "launch-failed" {
        if ($DryRun) {
            "Dry-run mode only prepared the bounded join-completion probe."
        }
        else {
            "The bounded probe could not confirm a trustworthy client launch path."
        }
    }
    default {
        "The bounded probe produced partial evidence, but the exact end-to-end join completion still needs manual review."
    }
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    probe_verdict = $probeVerdict
    narrowest_confirmed_break_point = $narrowestBreakPoint
    explanation = $overallExplanation
    probe_root = $probeRoot
    lane_root = $probeLaneRoot
    map = $Map
    bot_count = $BotCount
    bot_skill = $BotSkill
    port = $Port
    dry_run = [bool]$DryRun
    launch_path_adjustments = @(
        "client-working-directory-used-for-hl-exe-launch",
        "client-qconsole-and-debug-log-paths-exposed"
    )
    thresholds = [ordered]@{
        min_human_snapshots = $MinHumanSnapshots
        min_human_presence_seconds = $MinHumanPresenceSeconds
        duration_seconds = $DurationSeconds
        human_join_grace_seconds = $HumanJoinGraceSeconds
        join_delay_seconds = $JoinDelaySeconds
        poll_seconds = $PollSeconds
    }
    launch_observability = [ordered]@{
        client_discovery_verdict = [string]$launchPlan.client_discovery.discovery_verdict
        client_path = [string]$launchPlan.client_exe_path
        client_working_directory = [string]$launchPlan.client_working_directory
        qconsole_path = [string]$launchPlan.qconsole_path
        debug_log_path = [string]$launchPlan.debug_log_path
        join_target = [string]$launchPlan.join_info.LoopbackAddress
        join_console_command = [string]$launchPlan.join_info.ConsoleCommand
        launch_command_prepared = $launchPrepared
        launch_command = [string]$launchPlan.command_text
        control_join_attempted = $null -ne $joinExecution
        control_join_helper_result_verdict = [string](Get-ObjectPropertyValue -Object $joinExecution -Name "ResultVerdict" -Default "")
        client_process_id = $joinProcessId
        launch_started_at_utc = $joinStartedAtUtc
        probe_lane_command = $evalCommandText
        probe_lane_process_id = if ($null -ne $probeProcess) { $probeProcess.Id } else { 0 }
        server_log_path_for_correlation = $liveServerStdoutLog
        telemetry_json_path_for_correlation = $liveTelemetryPath
    }
    qconsole_snapshot_before = $preQconsoleSnapshot
    qconsole_snapshot_after = $postQconsoleSnapshot
    debug_log_snapshot_before = $preDebugSnapshot
    debug_log_snapshot_after = $postDebugSnapshot
    probe_lane = [ordered]@{
        port_ready = $portReady
        lane_root_ready = $laneRootReady
        lane_json_path = $laneJsonPath
        summary_json_path = $summaryPath
        session_pack_json_path = $sessionPackPath
        human_join_observed = [bool](Get-ObjectPropertyValue -Object $laneJson -Name "human_join_observed" -Default $false)
        human_join_timed_out = [bool](Get-ObjectPropertyValue -Object $laneJson -Name "human_join_timed_out" -Default $false)
        smoke_status = [string](Get-ObjectPropertyValue -Object $laneJson -Name "smoke_status" -Default "")
    }
    final_metrics = [ordered]@{
        server_connection_seen = @($controlConnectionEvidence.connected_lines).Count -gt 0
        entered_the_game_seen = $enteredGameEquivalentSeen
        entered_the_game_seen_exact = $enteredGameSeenExact
        first_human_snapshot_seen = $firstHumanSnapshotSeen
        human_presence_accumulating = $humanPresenceAccumulating
        control_lane_human_usable = $controlLaneHumanUsable
        human_snapshots_count = $finalHumanSnapshots
        seconds_with_human_presence = $finalHumanPresenceSeconds
        first_human_seen_timestamp_utc = $firstHumanSeenTimestampUtc
        first_human_seen_offset_seconds = $firstHumanSeenOffsetSeconds
        telemetry_snapshot_observed_live = $telemetrySnapshotObserved
    }
    stages = [ordered]@{
        client_discovered = $clientDiscoveredStage
        launch_command_prepared = $launchCommandPreparedStage
        client_process_launched = $clientProcessLaunchedStage
        server_connection_seen = $serverConnectionSeenStage
        entered_the_game_seen = $enteredGameSeenStage
        first_human_snapshot_seen = $firstHumanSnapshotSeenStage
        human_presence_accumulating = $humanPresenceAccumulatingStage
        control_lane_human_usable = $controlLaneHumanUsableStage
    }
    artifacts = [ordered]@{
        client_join_completion_probe_json = $reportJsonPath
        client_join_completion_probe_markdown = $reportMarkdownPath
        probe_lane_stdout_log = Resolve-ExistingPath -Path $probeStdoutLog
        probe_lane_stderr_log = Resolve-ExistingPath -Path $probeStderrLog
        lane_json = $laneJsonPath
        lane_summary_json = $summaryPath
        session_pack_json = $sessionPackPath
        human_presence_timeline_ndjson = $humanPresenceTimelinePath
        hlds_stdout_log = $laneStdoutLogPath
        hlds_stderr_log = $laneStderrLogPath
        client_qconsole_copy = Resolve-ExistingPath -Path $qconsoleCopyPath
        client_debug_log_copy = Resolve-ExistingPath -Path $debugLogCopyPath
    }
}

Write-JsonFile -Path $reportJsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $reportJsonPath
Write-TextFile -Path $reportMarkdownPath -Value (Get-ProbeMarkdown -Report $reportForMarkdown)

Write-Host "Client join-completion probe:"
Write-Host "  Probe verdict: $($report.probe_verdict)"
Write-Host "  Narrowest confirmed break point: $($report.narrowest_confirmed_break_point)"
Write-Host "  Probe root: $probeRoot"
Write-Host "  Lane root: $probeLaneRoot"
Write-Host "  JSON: $reportJsonPath"
Write-Host "  Markdown: $reportMarkdownPath"

[pscustomobject]@{
    ClientJoinCompletionProbeJsonPath = $reportJsonPath
    ClientJoinCompletionProbeMarkdownPath = $reportMarkdownPath
    ProbeRoot = $probeRoot
    LaneRoot = $probeLaneRoot
    ProbeVerdict = $report.probe_verdict
    NarrowestConfirmedBreakPoint = $report.narrowest_confirmed_break_point
}
