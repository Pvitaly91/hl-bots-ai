[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProbeRoot = "",
    [string]$LaneRoot = "",
    [string]$PairRoot = "",
    [switch]$UseLatest,
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

function Find-LatestProbeRoot {
    param([string]$EvalRoot)

    $candidate = Get-ChildItem -LiteralPath $EvalRoot -Filter "client_join_completion_probe.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No client_join_completion_probe.json was found under $EvalRoot"
    }

    return $candidate.DirectoryName
}

function Get-LatestControlLaneFromPair {
    param([string]$ResolvedPairRoot)

    $controlRoot = Join-Path $ResolvedPairRoot "lanes\control"
    if (-not (Test-Path -LiteralPath $controlRoot)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $controlRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Get-ConnectionEvidence {
    param([string[]]$LogLines)

    $connectedLines = New-Object System.Collections.Generic.List[string]
    $enteredLines = New-Object System.Collections.Generic.List[string]
    $connectedPlayers = New-Object System.Collections.Generic.List[object]
    $matchedEnteredLines = New-Object System.Collections.Generic.List[string]

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

function Get-LogTimestampText {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return ""
    }

    if ($Line -match '^L (?<stamp>\d{2}\/\d{2}\/\d{4} - \d{2}:\d{2}:\d{2})') {
        return [string]$Matches["stamp"]
    }

    return ""
}

function Resolve-AuditContext {
    param(
        [string]$ExplicitProbeRoot,
        [string]$ExplicitLaneRoot,
        [string]$ExplicitPairRoot,
        [switch]$PreferLatest,
        [string]$ResolvedLabRoot
    )

    $resolvedPairRoot = Resolve-ExistingPath -Path $ExplicitPairRoot
    if ($resolvedPairRoot) {
        $resolvedLaneRoot = Get-LatestControlLaneFromPair -ResolvedPairRoot $resolvedPairRoot
        return [pscustomobject]@{
            kind = "pair-root"
            report_root = $resolvedPairRoot
            probe_root = ""
            lane_root = $resolvedLaneRoot
            pair_root = $resolvedPairRoot
        }
    }

    $resolvedProbeRoot = Resolve-ExistingPath -Path $ExplicitProbeRoot
    if (-not $resolvedProbeRoot -and $PreferLatest) {
        $resolvedProbeRoot = Find-LatestProbeRoot -EvalRoot (Get-EvalRootDefault -LabRoot $ResolvedLabRoot)
    }

    if ($resolvedProbeRoot) {
        $probeReportPath = Resolve-ExistingPath -Path (Join-Path $resolvedProbeRoot "client_join_completion_probe.json")
        $probeReport = Read-JsonFile -Path $probeReportPath
        $probeLaneRoot = ""
        if ($null -ne $probeReport) {
            $probeLaneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeReport -Name "lane_root" -Default ""))
            if (-not $probeLaneRoot) {
                $readiness = Get-ObjectPropertyValue -Object $probeReport -Name "readiness_observability" -Default $null
                $probeLaneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $readiness -Name "lane_root" -Default ""))
            }
        }

        return [pscustomobject]@{
            kind = "probe-root"
            report_root = $resolvedProbeRoot
            probe_root = $resolvedProbeRoot
            lane_root = $probeLaneRoot
            pair_root = ""
        }
    }

    $resolvedLaneRoot = Resolve-ExistingPath -Path $ExplicitLaneRoot
    if ($resolvedLaneRoot) {
        return [pscustomobject]@{
            kind = "lane-root"
            report_root = $resolvedLaneRoot
            probe_root = ""
            lane_root = $resolvedLaneRoot
            pair_root = ""
        }
    }

    throw "A probe root, lane root, pair root, or -UseLatest is required."
}

function Get-AuditMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# First Human Snapshot Boundary Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Report.prompt_id)") | Out-Null
    $lines.Add("- Boundary verdict: $($Report.boundary_verdict)") | Out-Null
    $lines.Add("- Narrowest confirmed break point: $($Report.narrowest_confirmed_break_point)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Context kind: $($Report.context.kind)") | Out-Null
    $lines.Add("- Report root: $($Report.context.report_root)") | Out-Null
    $lines.Add("- Probe root: $($Report.context.probe_root)") | Out-Null
    $lines.Add("- Lane root: $($Report.context.lane_root)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Authoritative Inputs") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($item in @($Report.authoritative_inputs)) {
        $lines.Add("- $item") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Secondary Inputs") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($item in @($Report.secondary_inputs)) {
        $lines.Add("- $item") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Boundary Metrics") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Server entered-the-game seen: $(Get-BoolString -Value ([bool]$Report.metrics.entered_the_game_seen))") | Out-Null
    $lines.Add("- Server entered-the-game timestamp: $($Report.metrics.entered_the_game_timestamp_local)") | Out-Null
    $lines.Add("- Telemetry records: $($Report.metrics.telemetry_records_count)") | Out-Null
    $lines.Add("- First enumerated telemetry timestamp UTC: $($Report.metrics.first_enumerated_snapshot_timestamp_utc)") | Out-Null
    $lines.Add("- First human telemetry timestamp UTC: $($Report.metrics.first_human_snapshot_timestamp_utc)") | Out-Null
    $lines.Add("- First human telemetry server-time seconds: $($Report.metrics.first_human_snapshot_server_time_seconds)") | Out-Null
    $lines.Add("- Latest telemetry human player count: $($Report.metrics.latest_telemetry_human_player_count)") | Out-Null
    $lines.Add("- Lane summary human snapshots: $($Report.metrics.summary_human_snapshots_count)") | Out-Null
    $lines.Add("- Lane summary human presence seconds: $($Report.metrics.summary_seconds_with_human_presence)") | Out-Null
    $lines.Add("- Probe report first-human-snapshot verdict: $($Report.metrics.probe_report_first_human_snapshot_seen)") | Out-Null
    $lines.Add("- Timeline file present: $(Get-BoolString -Value ([bool]$Report.metrics.human_presence_timeline_present))") | Out-Null
    $lines.Add("- Summary writer failure detected: $(Get-BoolString -Value ([bool]$Report.metrics.summary_writer_failure_detected))") | Out-Null
    if ($Report.metrics.summary_writer_failure_excerpt) {
        $lines.Add("- Summary writer failure excerpt: $($Report.metrics.summary_writer_failure_excerpt)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Stage Verdicts") | Out-Null
    $lines.Add("") | Out-Null

    foreach ($stage in @(
            $Report.stages.entered_the_game_seen,
            $Report.stages.player_enumerated,
            $Report.stages.player_classified_human,
            $Report.stages.snapshot_written,
            $Report.stages.summary_updated,
            $Report.stages.human_presence_accumulating
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

    $lines.Add("## Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe report JSON: $($Report.artifacts.probe_report_json)") | Out-Null
    $lines.Add("- Probe lane stderr log: $($Report.artifacts.probe_lane_stderr_log)") | Out-Null
    $lines.Add("- Pair summary JSON: $($Report.artifacts.pair_summary_json)") | Out-Null
    $lines.Add("- Lane summary JSON: $($Report.artifacts.lane_summary_json)") | Out-Null
    $lines.Add("- Session pack JSON: $($Report.artifacts.session_pack_json)") | Out-Null
    $lines.Add("- Lane JSON: $($Report.artifacts.lane_json)") | Out-Null
    $lines.Add("- Human presence timeline: $($Report.artifacts.human_presence_timeline_ndjson)") | Out-Null
    $lines.Add("- Telemetry history NDJSON: $($Report.artifacts.telemetry_history_ndjson)") | Out-Null
    $lines.Add("- Latest telemetry JSON: $($Report.artifacts.latest_telemetry_json)") | Out-Null
    $lines.Add("- HLDS stdout log: $($Report.artifacts.hlds_stdout_log)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $LabRoot)
}

$context = Resolve-AuditContext `
    -ExplicitProbeRoot $ProbeRoot `
    -ExplicitLaneRoot $LaneRoot `
    -ExplicitPairRoot $PairRoot `
    -PreferLatest:$UseLatest `
    -ResolvedLabRoot $resolvedLabRoot

if (-not $context.lane_root) {
    throw "The audit context does not contain a readable lane root."
}

$probeReportPath = if ($context.probe_root) { Resolve-ExistingPath -Path (Join-Path $context.probe_root "client_join_completion_probe.json") } else { "" }
$probeReport = Read-JsonFile -Path $probeReportPath
$probeArtifacts = Get-ObjectPropertyValue -Object $probeReport -Name "artifacts" -Default $null
$probeStderrLogPath = if ($probeArtifacts) {
    Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeArtifacts -Name "probe_lane_stderr_log" -Default ""))
} else {
    Resolve-ExistingPath -Path (Join-Path $context.probe_root "probe_lane.stderr.log")
}

$pairSummaryPath = if ($context.pair_root) { Resolve-ExistingPath -Path (Join-Path $context.pair_root "pair_summary.json") } else { "" }
$pairSummary = Read-JsonFile -Path $pairSummaryPath
$laneSummaryPath = Resolve-ExistingPath -Path (Join-Path $context.lane_root "summary.json")
$laneSummaryPayload = Read-JsonFile -Path $laneSummaryPath
$primaryLaneSummary = Get-ObjectPropertyValue -Object $laneSummaryPayload -Name "primary_lane" -Default $null
$sessionPackPath = Resolve-ExistingPath -Path (Join-Path $context.lane_root "session_pack.json")
$laneJsonPath = Resolve-ExistingPath -Path (Join-Path $context.lane_root "lane.json")
$timelinePath = Resolve-LaneHumanPresenceTimelinePath -LaneRoot $context.lane_root
$timelineRecords = Read-NdjsonFile -Path $timelinePath
$telemetryHistoryPath = Resolve-ExistingPath -Path (Join-Path $context.lane_root "telemetry_history.ndjson")
$telemetryRecords = Read-NdjsonFile -Path $telemetryHistoryPath
$latestTelemetryPath = Resolve-ExistingPath -Path (Join-Path $context.lane_root "latest.telemetry.json")
$latestTelemetry = Read-JsonFile -Path $latestTelemetryPath
$hldsStdoutLogPath = Resolve-ExistingPath -Path (Join-Path $context.lane_root "hlds.stdout.log")
$hldsStdoutLogLines = if ($hldsStdoutLogPath) { @(Get-Content -LiteralPath $hldsStdoutLogPath) } else { @() }
$connectionEvidence = Get-ConnectionEvidence -LogLines $hldsStdoutLogLines

$enteredGameSeen = @($connectionEvidence.entered_game_lines).Count -gt 0
$enteredGameLine = if ($enteredGameSeen) { [string]$connectionEvidence.entered_game_lines[0] } else { "" }
$enteredGameTimestampLocal = Get-LogTimestampText -Line $enteredGameLine

$firstEnumeratedTelemetry = $null
foreach ($record in @($telemetryRecords)) {
    $humanCount = [int](Get-ObjectPropertyValue -Object $record -Name "human_player_count" -Default 0)
    $botCount = [int](Get-ObjectPropertyValue -Object $record -Name "bot_count" -Default 0)
    if ($humanCount -gt 0 -or $botCount -gt 0) {
        $firstEnumeratedTelemetry = $record
        break
    }
}

$firstHumanTelemetry = $null
foreach ($record in @($telemetryRecords)) {
    $humanCount = [int](Get-ObjectPropertyValue -Object $record -Name "human_player_count" -Default 0)
    if ($humanCount -gt 0) {
        $firstHumanTelemetry = $record
        break
    }
}

$latestTelemetryHumanCount = [int](Get-ObjectPropertyValue -Object $latestTelemetry -Name "human_player_count" -Default 0)
$playerEnumerated = $null -ne $firstEnumeratedTelemetry -or $latestTelemetryHumanCount -gt 0
$playerClassifiedHuman = $null -ne $firstHumanTelemetry -or $latestTelemetryHumanCount -gt 0
$snapshotWritten = $null -ne $firstHumanTelemetry

$summaryHumanSnapshots = [int](Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "human_snapshots_count" -Default 0)
$summaryHumanPresenceSeconds = [double](Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "seconds_with_human_presence" -Default 0.0)
$summaryFirstHumanTimestampUtc = [string](Get-ObjectPropertyValue -Object $primaryLaneSummary -Name "first_human_seen_timestamp_utc" -Default "")
$summaryUpdated = $summaryHumanSnapshots -gt 0
$humanPresenceAccumulating = $summaryUpdated -and $summaryHumanPresenceSeconds -gt 0.0

$summaryWriterFailureDetected = $false
$summaryWriterFailureExcerpt = ""
if ($probeStderrLogPath) {
    $stderrText = Get-Content -LiteralPath $probeStderrLogPath -Raw
    if ($stderrText -match 'human_presence_(timeline|.*)\.ndjson' -and $stderrText -match 'WriteAllText') {
        $summaryWriterFailureDetected = $true
        $summaryWriterFailureExcerpt = (($stderrText -split "`r?`n") | Where-Object { $_ -match 'WriteAllText|Could not find a part of the path' } | Select-Object -First 2) -join " | "
    }
}

$authoritativeInputs = @(
    ("HLDS stdout log: {0}" -f $hldsStdoutLogPath),
    ("telemetry history NDJSON: {0}" -f $telemetryHistoryPath),
    ("latest telemetry JSON: {0}" -f $latestTelemetryPath)
)
if ($pairSummaryPath) {
    $authoritativeInputs += ("pair summary JSON: {0}" -f $pairSummaryPath)
}

$secondaryInputs = @(
    ("lane summary JSON: {0}" -f $(if ($laneSummaryPath) { $laneSummaryPath } else { "(missing)" })),
    ("session pack JSON: {0}" -f $(if ($sessionPackPath) { $sessionPackPath } else { "(missing)" })),
    ("human presence timeline: {0}" -f $(if ($timelinePath) { $timelinePath } else { "(missing)" })),
    ("probe report JSON: {0}" -f $(if ($probeReportPath) { $probeReportPath } else { "(missing)" }))
)

$enteredGameStage = Get-StageRecord `
    -StageName "entered-the-game-seen" `
    -Verdict $(if ($enteredGameSeen) { "entered-the-game-seen" } else { "entered-game-not-seen" }) `
    -Reached $enteredGameSeen `
    -EvidenceFound $(if ($enteredGameSeen) {
            @(
                ("entered-the-game line: {0}" -f $enteredGameLine),
                ("entered-the-game timestamp: {0}" -f $enteredGameTimestampLocal)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($enteredGameSeen) { @() } else { @("authoritative HLDS 'entered the game' line") }) `
    -Explanation $(if ($enteredGameSeen) {
            "The authoritative HLDS log shows the player fully entered the game."
        } else {
            "The audit could not confirm the server-side entered-the-game transition."
        })

$playerEnumeratedStage = Get-StageRecord `
    -StageName "player-enumerated" `
    -Verdict $(if (-not $enteredGameSeen) { "entered-game-not-seen" } elseif ($playerEnumerated) { "player-enumerated" } else { "entered-game-seen-but-player-not-enumerated" }) `
    -Reached ($enteredGameSeen -and $playerEnumerated) `
    -EvidenceFound $(if ($playerEnumerated) {
            @(
                ("telemetry records count: {0}" -f @($telemetryRecords).Count),
                ("first enumerated telemetry timestamp UTC: {0}" -f [string](Get-ObjectPropertyValue -Object $firstEnumeratedTelemetry -Name "timestamp_utc" -Default "")),
                ("first enumerated telemetry human/bot counts: {0}/{1}" -f [int](Get-ObjectPropertyValue -Object $firstEnumeratedTelemetry -Name "human_player_count" -Default 0), [int](Get-ObjectPropertyValue -Object $firstEnumeratedTelemetry -Name "bot_count" -Default 0))
            )
        } else { @() }) `
    -EvidenceMissing $(if ($enteredGameSeen -and -not $playerEnumerated) { @("telemetry record showing any post-join player enumeration") } else { @() }) `
    -Explanation $(if ($enteredGameSeen -and $playerEnumerated) {
            "The telemetry stream enumerated players after the server-side join."
        } elseif ($enteredGameSeen) {
            "The player entered the game, but the telemetry stream never showed a post-join player enumeration."
        } else {
            "Enumeration is not meaningful until entered-the-game is confirmed."
        })

$playerClassifiedHumanStage = Get-StageRecord `
    -StageName "player-classified-human" `
    -Verdict $(if (-not $enteredGameSeen) { "entered-game-not-seen" } elseif (-not $playerEnumerated) { "entered-game-seen-but-player-not-enumerated" } elseif ($playerClassifiedHuman) { "player-classified-human" } else { "player-enumerated-but-classified-nonhuman" }) `
    -Reached ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman) `
    -EvidenceFound $(if ($playerClassifiedHuman) {
            @(
                ("first human telemetry timestamp UTC: {0}" -f $(if ($null -ne $firstHumanTelemetry) { [string](Get-ObjectPropertyValue -Object $firstHumanTelemetry -Name "timestamp_utc" -Default "") } else { [string](Get-ObjectPropertyValue -Object $latestTelemetry -Name "timestamp_utc" -Default "") })),
                ("latest telemetry human player count: {0}" -f $latestTelemetryHumanCount)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($enteredGameSeen -and $playerEnumerated -and -not $playerClassifiedHuman) { @("telemetry record classifying the joined player as human") } else { @() }) `
    -Explanation $(if ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman) {
            "The telemetry boundary already classifies the joined player as human."
        } elseif ($enteredGameSeen -and $playerEnumerated) {
            "Telemetry enumerated players after the join, but still never classified a human player."
        } else {
            "Human classification is downstream of enumeration."
        })

$snapshotWrittenStage = Get-StageRecord `
    -StageName "snapshot-written" `
    -Verdict $(if (-not $enteredGameSeen) { "entered-game-not-seen" } elseif (-not $playerEnumerated) { "entered-game-seen-but-player-not-enumerated" } elseif (-not $playerClassifiedHuman) { "player-enumerated-but-classified-nonhuman" } elseif ($snapshotWritten) { "snapshot-written" } else { "player-classified-human-but-no-snapshot-written" }) `
    -Reached ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman -and $snapshotWritten) `
    -EvidenceFound $(if ($snapshotWritten) {
            @(
                ("telemetry history path: {0}" -f $telemetryHistoryPath),
                ("first human telemetry timestamp UTC: {0}" -f [string](Get-ObjectPropertyValue -Object $firstHumanTelemetry -Name "timestamp_utc" -Default "")),
                ("first human telemetry server-time seconds: {0}" -f [double](Get-ObjectPropertyValue -Object $firstHumanTelemetry -Name "server_time_seconds" -Default 0.0))
            )
        } else { @() }) `
    -EvidenceMissing $(if ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman -and -not $snapshotWritten) { @("persisted telemetry-history record for the first human snapshot") } else { @() }) `
    -Explanation $(if ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman -and $snapshotWritten) {
            "A persisted telemetry-history snapshot already records the first human player."
        } elseif ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman) {
            "The joined player reached human classification, but the persisted telemetry history never wrote the first human snapshot."
        } else {
            "Snapshot persistence is downstream of the earlier boundary stages."
        })

$summaryUpdatedStage = Get-StageRecord `
    -StageName "summary-updated" `
    -Verdict $(if (-not $enteredGameSeen) { "entered-game-not-seen" } elseif (-not $playerEnumerated) { "entered-game-seen-but-player-not-enumerated" } elseif (-not $playerClassifiedHuman) { "player-enumerated-but-classified-nonhuman" } elseif (-not $snapshotWritten) { "player-classified-human-but-no-snapshot-written" } elseif ($summaryUpdated) { "first-human-snapshot-seen" } else { "snapshot-written-but-summary-not-updated" }) `
    -Reached ($enteredGameSeen -and $playerEnumerated -and $playerClassifiedHuman -and $snapshotWritten -and $summaryUpdated) `
    -EvidenceFound $(if ($summaryUpdated) {
            @(
                ("lane summary path: {0}" -f $laneSummaryPath),
                ("lane summary human snapshots count: {0}" -f $summaryHumanSnapshots),
                ("lane summary first human timestamp UTC: {0}" -f $summaryFirstHumanTimestampUtc)
            )
        } else {
            @(
                ("lane summary path: {0}" -f $(if ($laneSummaryPath) { $laneSummaryPath } else { "(missing)" })),
                ("probe stderr path: {0}" -f $(if ($probeStderrLogPath) { $probeStderrLogPath } else { "(missing)" }))
            )
        }) `
    -EvidenceMissing $(if ($snapshotWritten -and -not $summaryUpdated) { @("lane summary or session pack reflecting the first human snapshot") } else { @() }) `
    -Explanation $(if ($summaryUpdated) {
            "The saved lane summary now reflects the first human snapshot."
        } elseif ($snapshotWritten -and $summaryWriterFailureDetected) {
            "The first human snapshot exists in telemetry history, but the summary path did not update because the lane post-capture writer failed while materializing the human timeline artifact."
        } elseif ($snapshotWritten) {
            "The first human snapshot exists in telemetry history, but the saved lane summary still does not reflect it."
        } else {
            "Summary reflection is downstream of the first saved human snapshot."
        })

$humanPresenceAccumulatingStage = Get-StageRecord `
    -StageName "human-presence-accumulating" `
    -Verdict $(if (-not $enteredGameSeen) { "entered-game-not-seen" } elseif (-not $playerEnumerated) { "entered-game-seen-but-player-not-enumerated" } elseif (-not $playerClassifiedHuman) { "player-enumerated-but-classified-nonhuman" } elseif (-not $snapshotWritten) { "player-classified-human-but-no-snapshot-written" } elseif (-not $summaryUpdated) { "snapshot-written-but-summary-not-updated" } elseif ($humanPresenceAccumulating) { "human-presence-accumulating" } else { "first-human-snapshot-seen" }) `
    -Reached $humanPresenceAccumulating `
    -EvidenceFound $(if ($humanPresenceAccumulating) {
            @(
                ("summary seconds with human presence: {0}" -f $summaryHumanPresenceSeconds),
                ("human presence timeline present: {0}" -f [bool]$timelinePath)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($summaryUpdated -and -not $humanPresenceAccumulating) { @("saved human presence accumulation beyond the first counted snapshot") } else { @() }) `
    -Explanation $(if ($humanPresenceAccumulating) {
            "Saved lane evidence now shows human presence accumulating beyond the first counted snapshot."
        } elseif ($summaryUpdated) {
            "The first counted human snapshot is reflected in the lane summary, but meaningful accumulated human presence has not appeared yet."
        } else {
            "Human-presence accumulation cannot be trusted until the first counted snapshot is reflected in saved lane summary artifacts."
        })

$boundaryVerdict = if (-not $enteredGameSeen) {
    "entered-game-not-seen"
}
elseif (-not $playerEnumerated) {
    "entered-game-seen-but-player-not-enumerated"
}
elseif (-not $playerClassifiedHuman) {
    "player-enumerated-but-classified-nonhuman"
}
elseif (-not $snapshotWritten) {
    "player-classified-human-but-no-snapshot-written"
}
elseif (-not $summaryUpdated) {
    "snapshot-written-but-summary-not-updated"
}
elseif ($humanPresenceAccumulating) {
    "human-presence-accumulating"
}
elseif ($summaryUpdated) {
    "first-human-snapshot-seen"
}
else {
    "inconclusive-manual-review"
}

$narrowestBreakPoint = switch ($boundaryVerdict) {
    "entered-game-not-seen" { "The authoritative HLDS log never confirmed the entered-the-game transition." }
    "entered-game-seen-but-player-not-enumerated" { "The player entered the game, but telemetry never enumerated a post-join player state." }
    "player-enumerated-but-classified-nonhuman" { "Telemetry enumerated the post-join player state but never classified a human player." }
    "player-classified-human-but-no-snapshot-written" { "Human classification appeared, but the persisted telemetry history never wrote the first human snapshot." }
    "snapshot-written-but-summary-not-updated" { "Telemetry history already wrote the first human snapshot, but the lane summary/session artifacts never reflected it." }
    "first-human-snapshot-seen" { "The lane summary now reflects the first counted human snapshot, but accumulated saved presence still needs review." }
    "human-presence-accumulating" { "The first-human-snapshot boundary cleared and saved human presence is now accumulating." }
    default { "The audit could not isolate a narrower first-human-snapshot boundary break point." }
}

$explanation = switch ($boundaryVerdict) {
    "snapshot-written-but-summary-not-updated" {
        if ($summaryWriterFailureDetected) {
            "The current repeated-probe blocker is a summary aggregation failure, not player enumeration or human classification: the authoritative server log shows entered-the-game, telemetry history already records human_player_count > 0, and the post-capture writer then aborts before lane summary/session artifacts are written."
        }
        else {
            "The authoritative server and telemetry inputs already contain the first human snapshot, but saved lane summary artifacts still do not reflect it."
        }
    }
    "human-presence-accumulating" { "The first-human-snapshot boundary is now clear in both authoritative telemetry and saved lane summary artifacts." }
    "first-human-snapshot-seen" { "The first counted human snapshot is now reflected in saved summary artifacts, but accumulated human presence still remains thin." }
    default { $narrowestBreakPoint }
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    boundary_verdict = $boundaryVerdict
    narrowest_confirmed_break_point = $narrowestBreakPoint
    explanation = $explanation
    context = [ordered]@{
        kind = $context.kind
        report_root = $context.report_root
        probe_root = $context.probe_root
        lane_root = $context.lane_root
        pair_root = $context.pair_root
    }
    authoritative_inputs = @($authoritativeInputs)
    secondary_inputs = @($secondaryInputs)
    metrics = [ordered]@{
        entered_the_game_seen = $enteredGameSeen
        entered_the_game_line = $enteredGameLine
        entered_the_game_timestamp_local = $enteredGameTimestampLocal
        telemetry_records_count = @($telemetryRecords).Count
        first_enumerated_snapshot_timestamp_utc = if ($null -ne $firstEnumeratedTelemetry) { [string](Get-ObjectPropertyValue -Object $firstEnumeratedTelemetry -Name "timestamp_utc" -Default "") } else { "" }
        first_human_snapshot_timestamp_utc = if ($null -ne $firstHumanTelemetry) { [string](Get-ObjectPropertyValue -Object $firstHumanTelemetry -Name "timestamp_utc" -Default "") } else { "" }
        first_human_snapshot_server_time_seconds = if ($null -ne $firstHumanTelemetry) { [double](Get-ObjectPropertyValue -Object $firstHumanTelemetry -Name "server_time_seconds" -Default 0.0) } else { 0.0 }
        latest_telemetry_human_player_count = $latestTelemetryHumanCount
        summary_human_snapshots_count = $summaryHumanSnapshots
        summary_seconds_with_human_presence = $summaryHumanPresenceSeconds
        summary_first_human_seen_timestamp_utc = $summaryFirstHumanTimestampUtc
        human_presence_timeline_present = [bool]$timelinePath
        human_presence_timeline_records_count = @($timelineRecords).Count
        probe_report_verdict = [string](Get-ObjectPropertyValue -Object $probeReport -Name "probe_verdict" -Default "")
        probe_report_first_human_snapshot_seen = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $probeReport -Name "final_metrics" -Default $null) -Name "first_human_snapshot_seen" -Default $false)
        summary_writer_failure_detected = $summaryWriterFailureDetected
        summary_writer_failure_excerpt = $summaryWriterFailureExcerpt
    }
    stages = [ordered]@{
        entered_the_game_seen = $enteredGameStage
        player_enumerated = $playerEnumeratedStage
        player_classified_human = $playerClassifiedHumanStage
        snapshot_written = $snapshotWrittenStage
        summary_updated = $summaryUpdatedStage
        human_presence_accumulating = $humanPresenceAccumulatingStage
    }
    artifacts = [ordered]@{
        probe_report_json = $probeReportPath
        probe_lane_stderr_log = $probeStderrLogPath
        pair_summary_json = $pairSummaryPath
        lane_summary_json = $laneSummaryPath
        session_pack_json = $sessionPackPath
        lane_json = $laneJsonPath
        human_presence_timeline_ndjson = $timelinePath
        telemetry_history_ndjson = $telemetryHistoryPath
        latest_telemetry_json = $latestTelemetryPath
        hlds_stdout_log = $hldsStdoutLogPath
    }
}

$reportJsonPath = Join-Path $context.report_root "first_human_snapshot_audit.json"
$reportMarkdownPath = Join-Path $context.report_root "first_human_snapshot_audit.md"
Write-JsonFile -Path $reportJsonPath -Value $report
Write-TextFile -Path $reportMarkdownPath -Value (Get-AuditMarkdown -Report $report)

$report
