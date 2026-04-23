[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$FixtureId = "strong_signal_keep_conservative",
    [string]$OutputRoot = "",
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$ControlPort = 27016,
    [int]$TreatmentPort = 27017,
    [int]$DurationSeconds = 20,
    [int]$StageDelaySeconds = 2,
    [int]$MinHumanSnapshots = 3,
    [double]$MinHumanPresenceSeconds = 60,
    [int]$MinPatchEventsForUsableLane = 2,
    [double]$MinPostPatchObservationSeconds = 20,
    [ValidateSet("conservative", "default", "responsive")]
    [string]$TreatmentProfile = "conservative",
    [string]$GuidedStopSignalPath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 20
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )

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

    $records = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $records += ($line | ConvertFrom-Json)
    }

    return $records
}

function Write-NdjsonFile {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $builder = New-Object System.Text.StringBuilder
    foreach ($record in @($Records)) {
        if ($null -eq $record) {
            continue
        }

        [void]$builder.AppendLine(($record | ConvertTo-Json -Depth 20 -Compress))
    }

    [System.IO.File]::WriteAllText($Path, $builder.ToString(), $encoding)
}

function Append-NdjsonRecord {
    param(
        [string]$Path,
        [object]$Record
    )

    $json = $Record | ConvertTo-Json -Depth 12 -Compress
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $encoding)
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
        return $Path
    }

    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        return Join-Path $BasePath $Path
    }

    return Join-Path (Get-RepoRoot) $Path
}

function Clone-Object {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Set-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $property.Value = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-PrimaryLaneSummary {
    param([object]$Payload)

    if ($null -eq $Payload) {
        throw "Lane summary payload is missing."
    }

    if ($null -ne $Payload.PSObject.Properties["primary_lane"] -and $null -ne $Payload.primary_lane) {
        return $Payload.primary_lane
    }

    return $Payload
}

function Get-StagedLaneSummaryPayload {
    param(
        [object]$BasePayload,
        [hashtable]$Overrides,
        [string]$FixtureIdValue
    )

    $payload = Clone-Object -Value $BasePayload
    $summary = Get-PrimaryLaneSummary -Payload $payload
    foreach ($entry in $Overrides.GetEnumerator()) {
        Set-ObjectPropertyValue -Object $summary -Name $entry.Key -Value $entry.Value
    }

    Set-ObjectPropertyValue -Object $payload -Name "synthetic_fixture" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "rehearsal_mode" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "validation_only" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "evidence_origin" -Value "rehearsal"
    Set-ObjectPropertyValue -Object $payload -Name "fixture_id" -Value $FixtureIdValue

    return $payload
}

function Get-RecordSpanSeconds {
    param(
        [object[]]$TelemetryRecords,
        [int]$Index
    )

    $record = $TelemetryRecords[$Index]
    $activeBalance = if ($null -ne $record.PSObject.Properties["active_balance"]) { $record.active_balance } else { $null }
    $intervalSeconds = 20.0
    if ($null -ne $activeBalance -and $null -ne $activeBalance.PSObject.Properties["interval_seconds"]) {
        $intervalSeconds = [Math]::Max(1.0, [double]$activeBalance.interval_seconds)
    }

    $currentTime = [double]$record.server_time_seconds
    if ($Index + 1 -ge $TelemetryRecords.Count) {
        return $intervalSeconds
    }

    $nextTime = [double]$TelemetryRecords[$Index + 1].server_time_seconds
    $delta = $nextTime - $currentTime
    if ($delta -le 0.0) {
        return $intervalSeconds
    }

    return [Math]::Min($intervalSeconds, $delta)
}

function Get-LatestTelemetryAtOrBefore {
    param(
        [object[]]$TelemetryRecords,
        [double]$ServerTimeSeconds
    )

    $latest = $null
    foreach ($record in @($TelemetryRecords)) {
        $recordTime = [double]$record.server_time_seconds
        if ($recordTime -le ($ServerTimeSeconds + 0.0001)) {
            $latest = $record
            continue
        }

        break
    }

    return $latest
}

function Test-HumanPresent {
    param([object]$Record)

    if ($null -eq $Record) {
        return $false
    }

    return [int]$Record.human_player_count -gt 0 -and [int]$Record.bot_count -gt 0
}

function Get-PostPatchObservationSeconds {
    param(
        [object[]]$TelemetryRecords,
        [object[]]$ApplyRecords
    )

    if (@($TelemetryRecords).Count -eq 0 -or @($ApplyRecords).Count -eq 0) {
        return 0.0
    }

    $firstHumanPresentApplyTime = $null
    foreach ($record in @($ApplyRecords)) {
        $applyTime = [double]$record.server_time_seconds
        $currentState = Get-LatestTelemetryAtOrBefore -TelemetryRecords $TelemetryRecords -ServerTimeSeconds $applyTime
        if (-not (Test-HumanPresent -Record $currentState)) {
            continue
        }

        $firstHumanPresentApplyTime = $applyTime
        break
    }

    if ($null -eq $firstHumanPresentApplyTime) {
        return 0.0
    }

    $totalSeconds = 0.0
    for ($index = 0; $index -lt $TelemetryRecords.Count; $index++) {
        $record = $TelemetryRecords[$index]
        $recordTime = [double]$record.server_time_seconds
        if ($recordTime -le ($firstHumanPresentApplyTime + 0.0001)) {
            continue
        }
        if (-not (Test-HumanPresent -Record $record)) {
            continue
        }

        $totalSeconds += Get-RecordSpanSeconds -TelemetryRecords $TelemetryRecords -Index $index
    }

    return [Math]::Round($totalSeconds, 1)
}

function Get-RehearsalObservationSlices {
    param(
        [object[]]$TelemetryRecords,
        [object[]]$ApplyRecords,
        [double]$ThresholdSeconds
    )

    $candidates = @(
        @{
            apply_count = 1
            stage4_telemetry_count = 5
            stage5_telemetry_count = 6
            stage4_apply_count = 1
            stage5_apply_count = 1
        }
        @{
            apply_count = 1
            stage4_telemetry_count = 4
            stage5_telemetry_count = 5
            stage4_apply_count = 1
            stage5_apply_count = 1
        }
        @{
            apply_count = 1
            stage4_telemetry_count = 5
            stage5_telemetry_count = 6
            stage4_apply_count = 1
            stage5_apply_count = 1
        }
    )

    $applyCandidates = @(
        @{
            stage4_telemetry_count = 5
            stage5_telemetry_count = 6
            apply_offset = 1
        }
        @{
            stage4_telemetry_count = 4
            stage5_telemetry_count = 5
            apply_offset = 0
        }
        @{
            stage4_telemetry_count = 5
            stage5_telemetry_count = 6
            apply_offset = 0
        }
    )

    foreach ($candidate in $applyCandidates) {
        $selectedApply = @($ApplyRecords | Select-Object -Skip $candidate.apply_offset -First 1)
        $stage4Telemetry = @($TelemetryRecords | Select-Object -First $candidate.stage4_telemetry_count)
        $stage5Telemetry = @($TelemetryRecords | Select-Object -First $candidate.stage5_telemetry_count)
        $stage4ObservationSeconds = Get-PostPatchObservationSeconds -TelemetryRecords $stage4Telemetry -ApplyRecords $selectedApply
        $stage5ObservationSeconds = Get-PostPatchObservationSeconds -TelemetryRecords $stage5Telemetry -ApplyRecords $selectedApply

        if ($stage4ObservationSeconds + 0.0001 -lt $ThresholdSeconds -and $stage5ObservationSeconds + 0.0001 -ge $ThresholdSeconds) {
            return [pscustomobject]@{
                Stage4Telemetry = $stage4Telemetry
                Stage4Apply = $selectedApply
                Stage4ObservationSeconds = $stage4ObservationSeconds
                Stage5Telemetry = $stage5Telemetry
                Stage5Apply = $selectedApply
                Stage5ObservationSeconds = $stage5ObservationSeconds
            }
        }
    }

    throw "The rehearsal fixture cannot model a waiting-then-sufficient post-patch progression for MinPostPatchObservationSeconds=$ThresholdSeconds. Keep the threshold at 60 seconds or below for rehearsal mode."
}

function Get-JoinInstructionText {
    param(
        [string]$RoleName,
        [string]$JoinTarget,
        [string]$ModeName,
        [string]$TreatmentProfileName,
        [string]$PairRootPath,
        [string]$FixtureIdValue
    )

    $lines = @(
        "Guided workflow rehearsal lane instructions",
        "",
        "Role: $RoleName",
        "Join target: $JoinTarget",
        "Mode: $ModeName",
        "Treatment profile: $TreatmentProfileName",
        "Synthetic fixture: True",
        "Rehearsal mode: True",
        "Evidence origin: rehearsal",
        "Validation only: True",
        "Fixture ID: $FixtureIdValue",
        "Pair root: $PairRootPath",
        "",
        "This lane exists only to validate guided workflow behavior. Do not treat it as real human-rich tuning evidence."
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-PairJoinInstructionText {
    param(
        [string]$ControlJoinTarget,
        [string]$TreatmentJoinTarget,
        [string]$PairRootPath,
        [string]$FixtureIdValue,
        [string]$TreatmentProfileName
    )

    $lines = @(
        "Guided workflow rehearsal pair instructions",
        "",
        "Control join target: $ControlJoinTarget",
        "Treatment join target: $TreatmentJoinTarget",
        "Treatment profile: $TreatmentProfileName",
        "Synthetic fixture: True",
        "Rehearsal mode: True",
        "Evidence origin: rehearsal",
        "Validation only: True",
        "Fixture ID: $FixtureIdValue",
        "Pair root: $PairRootPath",
        "",
        "This pair root is a deterministic sufficiency rehearsal. It validates monitor progression, guided auto-stop, and the post-run pipeline, but it does not validate live tuning quality."
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Invoke-RehearsalStageWrite {
    param(
        [string]$ControlSummaryPath,
        [object]$ControlSummaryPayload,
        [string]$TreatmentSummaryPath,
        [object]$TreatmentSummaryPayload,
        [string]$ControlTelemetryPath,
        [object[]]$ControlTelemetryRecords,
        [string]$TreatmentTelemetryPath,
        [object[]]$TreatmentTelemetryRecords,
        [string]$TreatmentPatchApplyPath,
        [object[]]$TreatmentApplyRecords,
        [string]$TreatmentPatchHistoryPath,
        [object[]]$TreatmentPatchRecords
    )

    Write-JsonFile -Path $ControlSummaryPath -Value $ControlSummaryPayload
    Write-JsonFile -Path $TreatmentSummaryPath -Value $TreatmentSummaryPayload
    Write-NdjsonFile -Path $ControlTelemetryPath -Records $ControlTelemetryRecords
    Write-NdjsonFile -Path $TreatmentTelemetryPath -Records $TreatmentTelemetryRecords
    Write-NdjsonFile -Path $TreatmentPatchApplyPath -Records $TreatmentApplyRecords
    Write-NdjsonFile -Path $TreatmentPatchHistoryPath -Records $TreatmentPatchRecords
}

function Update-RehearsalLabeledPairPayload {
    param(
        [object]$PairSummary,
        [string]$PromptId,
        [string]$FixtureIdValue,
        [string]$MapName,
        [int]$DesiredBotCount,
        [int]$DesiredBotSkill,
        [string]$TreatmentProfileName,
        [int]$DesiredControlPort,
        [int]$DesiredTreatmentPort,
        [string]$SessionId,
        [string]$FixtureNote,
        [string]$FixtureDescription
    )

    $payload = Clone-Object -Value $PairSummary
    $sourceFixturePromptId = [string]$payload.prompt_id
    Set-ObjectPropertyValue -Object $payload -Name "prompt_id" -Value $PromptId
    Set-ObjectPropertyValue -Object $payload -Name "source_fixture_prompt_id" -Value $sourceFixturePromptId
    Set-ObjectPropertyValue -Object $payload -Name "synthetic_fixture" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "rehearsal_mode" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "validation_only" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "evidence_origin" -Value "rehearsal"
    Set-ObjectPropertyValue -Object $payload -Name "fixture_id" -Value $FixtureIdValue
    Set-ObjectPropertyValue -Object $payload -Name "fixture_note" -Value $FixtureNote
    Set-ObjectPropertyValue -Object $payload -Name "fixture_description" -Value $FixtureDescription
    Set-ObjectPropertyValue -Object $payload -Name "pair_id" -Value ("rehearsal-{0}-{1}" -f $FixtureIdValue, $SessionId)
    Set-ObjectPropertyValue -Object $payload -Name "pair_root" -Value "."
    Set-ObjectPropertyValue -Object $payload -Name "map" -Value $MapName
    Set-ObjectPropertyValue -Object $payload -Name "bot_count" -Value $DesiredBotCount
    Set-ObjectPropertyValue -Object $payload -Name "bot_skill" -Value $DesiredBotSkill
    Set-ObjectPropertyValue -Object $payload -Name "treatment_profile" -Value $TreatmentProfileName

    $controlLane = $payload.control_lane
    $treatmentLane = $payload.treatment_lane
    if ($null -ne $controlLane) {
        Set-ObjectPropertyValue -Object $controlLane -Name "port" -Value $DesiredControlPort
        Set-ObjectPropertyValue -Object $controlLane -Name "join_target" -Value ("127.0.0.1:{0}" -f $DesiredControlPort)
    }
    if ($null -ne $treatmentLane) {
        Set-ObjectPropertyValue -Object $treatmentLane -Name "port" -Value $DesiredTreatmentPort
        Set-ObjectPropertyValue -Object $treatmentLane -Name "join_target" -Value ("127.0.0.1:{0}" -f $DesiredTreatmentPort)
        Set-ObjectPropertyValue -Object $treatmentLane -Name "treatment_profile" -Value $TreatmentProfileName
    }

    $operatorNotePrefix = "Guided rehearsal only. Synthetic evidence origin=rehearsal. This validates workflow behavior, not real live tuning quality."
    $existingOperatorNote = [string]$payload.operator_note
    $combinedOperatorNote = if ([string]::IsNullOrWhiteSpace($existingOperatorNote)) {
        $operatorNotePrefix
    }
    else {
        "$operatorNotePrefix $existingOperatorNote"
    }
    Set-ObjectPropertyValue -Object $payload -Name "operator_note" -Value $combinedOperatorNote

    return $payload
}

function Update-RehearsalLabeledComparisonPayload {
    param(
        [object]$ComparisonPayload,
        [string]$PromptId,
        [string]$FixtureIdValue,
        [string]$TreatmentProfileName
    )

    $payload = Clone-Object -Value $ComparisonPayload
    Set-ObjectPropertyValue -Object $payload -Name "synthetic_fixture" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "rehearsal_mode" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "validation_only" -Value $true
    Set-ObjectPropertyValue -Object $payload -Name "evidence_origin" -Value "rehearsal"
    Set-ObjectPropertyValue -Object $payload -Name "fixture_id" -Value $FixtureIdValue

    if ($null -ne $payload.PSObject.Properties["comparison"] -and $null -ne $payload.comparison) {
        Set-ObjectPropertyValue -Object $payload.comparison -Name "prompt_id" -Value $PromptId
        Set-ObjectPropertyValue -Object $payload.comparison -Name "treatment_tuning_profile" -Value $TreatmentProfileName
    }

    return $payload
}

function Finalize-RehearsalPairRoot {
    param(
        [string]$FixtureRoot,
        [string]$PairRoot,
        [string]$PromptId,
        [string]$FixtureIdValue,
        [string]$SessionId,
        [string]$MapName,
        [int]$DesiredBotCount,
        [int]$DesiredBotSkill,
        [string]$TreatmentProfileName,
        [int]$DesiredControlPort,
        [int]$DesiredTreatmentPort,
        [string]$FixtureNote,
        [string]$FixtureDescription
    )

    foreach ($topLevelFile in @("pair_summary.md", "comparison.md")) {
        $sourcePath = Join-Path $FixtureRoot $topLevelFile
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $PairRoot $topLevelFile) -Force
        }
    }

    $fixturePairSummary = Read-JsonFile -Path (Join-Path $FixtureRoot "pair_summary.json")
    $fixtureComparison = Read-JsonFile -Path (Join-Path $FixtureRoot "comparison.json")
    if ($null -eq $fixturePairSummary -or $null -eq $fixtureComparison) {
        throw "The rehearsal fixture is missing pair_summary.json or comparison.json: $FixtureRoot"
    }

    $labeledPairSummary = Update-RehearsalLabeledPairPayload `
        -PairSummary $fixturePairSummary `
        -PromptId $PromptId `
        -FixtureIdValue $FixtureIdValue `
        -MapName $MapName `
        -DesiredBotCount $DesiredBotCount `
        -DesiredBotSkill $DesiredBotSkill `
        -TreatmentProfileName $TreatmentProfileName `
        -DesiredControlPort $DesiredControlPort `
        -DesiredTreatmentPort $DesiredTreatmentPort `
        -SessionId $SessionId `
        -FixtureNote $FixtureNote `
        -FixtureDescription $FixtureDescription
    $labeledComparison = Update-RehearsalLabeledComparisonPayload `
        -ComparisonPayload $fixtureComparison `
        -PromptId $PromptId `
        -FixtureIdValue $FixtureIdValue `
        -TreatmentProfileName $TreatmentProfileName

    Write-JsonFile -Path (Join-Path $PairRoot "pair_summary.json") -Value $labeledPairSummary
    Write-JsonFile -Path (Join-Path $PairRoot "comparison.json") -Value $labeledComparison

    foreach ($laneName in @("control", "treatment")) {
        $sourceLaneRoot = Join-Path $FixtureRoot ("lanes\{0}" -f $laneName)
        $destinationLaneRoot = Ensure-Directory -Path (Join-Path $PairRoot ("lanes\{0}" -f $laneName))
        Copy-Item -Path (Join-Path $sourceLaneRoot "*") -Destination $destinationLaneRoot -Recurse -Force
    }

    $disclaimerLines = @(
        "> Synthetic fixture: True",
        "> Rehearsal mode: True",
        "> Evidence origin: rehearsal",
        "> Validation only: This artifact validates workflow behavior only and must not be treated as real human-rich tuning evidence.",
        ""
    ) -join [Environment]::NewLine

    foreach ($markdownFile in @("pair_summary.md", "comparison.md")) {
        $path = Join-Path $PairRoot $markdownFile
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $body = Get-Content -LiteralPath $path -Raw
        Write-TextFile -Path $path -Value ($disclaimerLines + $body)
    }
}

Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

if ($ControlPort -lt 1 -or $ControlPort -gt 65535) {
    throw "ControlPort must be between 1 and 65535."
}
if ($TreatmentPort -lt 1 -or $TreatmentPort -gt 65535) {
    throw "TreatmentPort must be between 1 and 65535."
}
if ($ControlPort -eq $TreatmentPort) {
    throw "ControlPort and TreatmentPort must differ."
}
if ($DurationSeconds -lt 8) {
    throw "DurationSeconds must be at least 8 seconds for rehearsal mode."
}
if ($StageDelaySeconds -lt 1) {
    throw "StageDelaySeconds must be at least 1."
}

$effectiveMinHumanSnapshots = [Math]::Max(1, $MinHumanSnapshots)
$effectiveMinHumanPresenceSeconds = [Math]::Max(1.0, [double]$MinHumanPresenceSeconds)
$effectiveMinPatchEvents = [Math]::Max(1, $MinPatchEventsForUsableLane)
$effectiveMinPostPatchObservationSeconds = [Math]::Max(1.0, [double]$MinPostPatchObservationSeconds)

$fixtureRoot = Join-Path (Get-RepoRoot) ("ai_director\testdata\pair_sessions\{0}" -f $FixtureId)
if (-not (Test-Path -LiteralPath $fixtureRoot)) {
    throw "The requested rehearsal fixture was not found: $fixtureRoot"
}

$fixtureMetadata = Read-JsonFile -Path (Join-Path $fixtureRoot "fixture_metadata.json")
$controlSummaryPayloadBase = Read-JsonFile -Path (Join-Path $fixtureRoot "lanes\control\summary.json")
$treatmentSummaryPayloadBase = Read-JsonFile -Path (Join-Path $fixtureRoot "lanes\treatment\summary.json")
$controlTelemetryRecordsBase = @(Read-NdjsonFile -Path (Join-Path $fixtureRoot "lanes\control\telemetry_history.ndjson"))
$treatmentTelemetryRecordsBase = @(Read-NdjsonFile -Path (Join-Path $fixtureRoot "lanes\treatment\telemetry_history.ndjson"))
$treatmentApplyRecordsBase = @(Read-NdjsonFile -Path (Join-Path $fixtureRoot "lanes\treatment\patch_apply_history.ndjson"))
$treatmentPatchRecordsBase = @(Read-NdjsonFile -Path (Join-Path $fixtureRoot "lanes\treatment\patch_history.ndjson"))

if ($null -eq $fixtureMetadata -or $null -eq $controlSummaryPayloadBase -or $null -eq $treatmentSummaryPayloadBase) {
    throw "The rehearsal fixture is missing required metadata or lane summaries: $fixtureRoot"
}
if ($treatmentTelemetryRecordsBase.Count -lt 6 -or $treatmentApplyRecordsBase.Count -lt 2) {
    throw "The rehearsal fixture does not contain enough treatment telemetry or patch apply history to model the staged sufficiency progression."
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Get-PairsRootDefault -LabRoot (Get-LabRootDefault))
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath (Get-RepoRoot))
}

$sessionId = Get-Date -Format "yyyyMMdd-HHmmss"
$pairRootName = "{0}-rehearsal-{1}-{2}-b{3}-s{4}-cp{5}-tp{6}" -f $sessionId, $FixtureId, $Map, $BotCount, $BotSkill, $ControlPort, $TreatmentPort
$pairRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot $pairRootName)
$controlLaneRoot = Ensure-Directory -Path (Join-Path $pairRoot "lanes\control")
$treatmentLaneRoot = Ensure-Directory -Path (Join-Path $pairRoot "lanes\treatment")

$controlSummaryPath = Join-Path $controlLaneRoot "summary.json"
$treatmentSummaryPath = Join-Path $treatmentLaneRoot "summary.json"
$controlTelemetryPath = Join-Path $controlLaneRoot "telemetry_history.ndjson"
$treatmentTelemetryPath = Join-Path $treatmentLaneRoot "telemetry_history.ndjson"
$treatmentPatchApplyPath = Join-Path $treatmentLaneRoot "patch_apply_history.ndjson"
$treatmentPatchHistoryPath = Join-Path $treatmentLaneRoot "patch_history.ndjson"
$progressionPath = Join-Path $pairRoot "rehearsal_progression.ndjson"
$rehearsalMetadataPath = Join-Path $pairRoot "rehearsal_metadata.json"

$controlJoinTarget = "127.0.0.1:$ControlPort"
$treatmentJoinTarget = "127.0.0.1:$TreatmentPort"
$promptId = Get-RepoPromptId
$fixtureDescription = [string]$fixtureMetadata.description
$fixtureNote = [string]$fixtureMetadata.fixture_note

$observationSlices = Get-RehearsalObservationSlices `
    -TelemetryRecords $treatmentTelemetryRecordsBase `
    -ApplyRecords $treatmentApplyRecordsBase `
    -ThresholdSeconds $effectiveMinPostPatchObservationSeconds

$controlWaitingSnapshots = [Math]::Max(0, $effectiveMinHumanSnapshots - 1)
$controlWaitingPresenceSeconds = [Math]::Max(0.0, $effectiveMinHumanPresenceSeconds - 20.0)
$treatmentWaitingSnapshots = [Math]::Max(0, $effectiveMinHumanSnapshots - 1)
$treatmentWaitingPresenceSeconds = [Math]::Max(0.0, $effectiveMinHumanPresenceSeconds - 20.0)

$controlWaitingSummary = Get-StagedLaneSummaryPayload `
    -BasePayload $controlSummaryPayloadBase `
    -FixtureIdValue $FixtureId `
    -Overrides @{
        prompt_id = $promptId
        human_snapshots_count = $controlWaitingSnapshots
        seconds_with_human_presence = [Math]::Round($controlWaitingPresenceSeconds, 1)
        max_human_player_count = if ($controlWaitingSnapshots -gt 0) { 1 } else { 0 }
        human_signal_verdict = if ($controlWaitingSnapshots -gt 0) { "human-sparse" } else { "no-humans" }
        tuning_signal_usable = $false
        lane_ever_became_tuning_usable = $false
        lane_stayed_sparse_or_insufficient = $true
        lane_quality_verdict = if ($controlWaitingSnapshots -gt 0) { "control-baseline-human-sparse" } else { "control-baseline-no-humans" }
        evidence_quality = "insufficient-data"
        evidence_quality_reason = "Guided rehearsal stage: control has not yet cleared the minimum human gate."
        explanation = "Guided rehearsal stage: control is still below the minimum human-signal gate."
    }
$controlReadySummary = Get-StagedLaneSummaryPayload `
    -BasePayload $controlSummaryPayloadBase `
    -FixtureIdValue $FixtureId `
    -Overrides @{
        prompt_id = $promptId
        human_snapshots_count = $effectiveMinHumanSnapshots
        seconds_with_human_presence = [Math]::Round($effectiveMinHumanPresenceSeconds, 1)
        max_human_player_count = 1
        human_signal_verdict = "human-usable"
        tuning_signal_usable = $true
        lane_ever_became_tuning_usable = $true
        lane_stayed_sparse_or_insufficient = $false
        lane_quality_verdict = "control-baseline-human-usable"
        evidence_quality = "usable-signal"
        evidence_quality_reason = "Guided rehearsal stage: control cleared the minimum human gate."
        explanation = "Guided rehearsal stage: control cleared the human gate and is ready for treatment comparison."
    }

$treatmentWaitingSummary = Get-StagedLaneSummaryPayload `
    -BasePayload $treatmentSummaryPayloadBase `
    -FixtureIdValue $FixtureId `
    -Overrides @{
        prompt_id = $promptId
        tuning_profile = $TreatmentProfile
        human_snapshots_count = $treatmentWaitingSnapshots
        seconds_with_human_presence = [Math]::Round($treatmentWaitingPresenceSeconds, 1)
        max_human_player_count = if ($treatmentWaitingSnapshots -gt 0) { 1 } else { 0 }
        human_signal_verdict = if ($treatmentWaitingSnapshots -gt 0) { "human-sparse" } else { "no-humans" }
        tuning_signal_usable = $false
        lane_ever_became_tuning_usable = $false
        lane_stayed_sparse_or_insufficient = $true
        lane_quality_verdict = if ($treatmentWaitingSnapshots -gt 0) { "ai-healthy-human-sparse" } else { "ai-healthy-no-humans" }
        evidence_quality = "insufficient-data"
        evidence_quality_reason = "Guided rehearsal stage: treatment has not yet cleared the minimum human gate."
        patch_events_while_humans_present_count = 0
        patch_apply_count = 0
        patch_apply_count_while_humans_present = 0
        human_reactive_patch_events_count = 0
        human_reactive_patch_apply_count = 0
        response_after_patch_observation_window_count = 0
        treatment_patched_while_humans_present = $false
        meaningful_post_patch_observation_window_exists = $false
        patch_response_to_human_imbalance_observed = $false
        explanation = "Guided rehearsal stage: treatment has not yet cleared the human gate."
    }

$treatmentPatchWaitingSummary = Get-StagedLaneSummaryPayload `
    -BasePayload $treatmentSummaryPayloadBase `
    -FixtureIdValue $FixtureId `
    -Overrides @{
        prompt_id = $promptId
        tuning_profile = $TreatmentProfile
        human_snapshots_count = $effectiveMinHumanSnapshots
        seconds_with_human_presence = [Math]::Round($effectiveMinHumanPresenceSeconds, 1)
        max_human_player_count = 1
        human_signal_verdict = "human-usable"
        tuning_signal_usable = $true
        lane_ever_became_tuning_usable = $true
        lane_stayed_sparse_or_insufficient = $false
        lane_quality_verdict = "ai-healthy-human-usable"
        evidence_quality = "weak-signal"
        evidence_quality_reason = "Guided rehearsal stage: treatment cleared the human gate but has not patched while humans are present yet."
        patch_events_while_humans_present_count = 0
        patch_apply_count = 0
        patch_apply_count_while_humans_present = 0
        human_reactive_patch_events_count = 0
        human_reactive_patch_apply_count = 0
        response_after_patch_observation_window_count = 0
        treatment_patched_while_humans_present = $false
        meaningful_post_patch_observation_window_exists = $false
        patch_response_to_human_imbalance_observed = $false
        explanation = "Guided rehearsal stage: treatment cleared the human gate, but no human-present patch has landed yet."
    }

$treatmentPostPatchWaitingSummary = Get-StagedLaneSummaryPayload `
    -BasePayload $treatmentSummaryPayloadBase `
    -FixtureIdValue $FixtureId `
    -Overrides @{
        prompt_id = $promptId
        tuning_profile = $TreatmentProfile
        human_snapshots_count = $effectiveMinHumanSnapshots + 1
        seconds_with_human_presence = [Math]::Round(($effectiveMinHumanPresenceSeconds + 20.0), 1)
        max_human_player_count = 2
        human_signal_verdict = "human-usable"
        tuning_signal_usable = $true
        lane_ever_became_tuning_usable = $true
        lane_stayed_sparse_or_insufficient = $false
        lane_quality_verdict = "ai-healthy-human-usable"
        evidence_quality = "weak-signal"
        evidence_quality_reason = "Guided rehearsal stage: treatment already patched while humans were present, but the post-patch observation window is still too short."
        patch_events_while_humans_present_count = $effectiveMinPatchEvents
        patch_apply_count = @($observationSlices.Stage4Apply).Count
        patch_apply_count_while_humans_present = @($observationSlices.Stage4Apply).Count
        human_reactive_patch_events_count = $effectiveMinPatchEvents
        human_reactive_patch_apply_count = @($observationSlices.Stage4Apply).Count
        response_after_patch_observation_window_count = 1
        treatment_patched_while_humans_present = $true
        meaningful_post_patch_observation_window_exists = $false
        patch_response_to_human_imbalance_observed = $true
        post_patch_frag_gap_trend = "inconclusive"
        explanation = "Guided rehearsal stage: treatment patched while humans were present, but the post-patch observation window is still below the minimum."
    }

$treatmentSufficientSummary = Get-StagedLaneSummaryPayload `
    -BasePayload $treatmentSummaryPayloadBase `
    -FixtureIdValue $FixtureId `
    -Overrides @{
        prompt_id = $promptId
        tuning_profile = $TreatmentProfile
        human_snapshots_count = $effectiveMinHumanSnapshots + 2
        seconds_with_human_presence = [Math]::Round(($effectiveMinHumanPresenceSeconds + $observationSlices.Stage5ObservationSeconds), 1)
        max_human_player_count = 2
        human_signal_verdict = "human-usable"
        tuning_signal_usable = $true
        lane_ever_became_tuning_usable = $true
        lane_stayed_sparse_or_insufficient = $false
        lane_quality_verdict = "ai-healthy-human-usable"
        evidence_quality = "usable-signal"
        evidence_quality_reason = "Guided rehearsal stage: treatment now has enough post-patch observation to stop honestly."
        patch_events_while_humans_present_count = $effectiveMinPatchEvents
        patch_apply_count = @($observationSlices.Stage5Apply).Count
        patch_apply_count_while_humans_present = @($observationSlices.Stage5Apply).Count
        human_reactive_patch_events_count = $effectiveMinPatchEvents
        human_reactive_patch_apply_count = @($observationSlices.Stage5Apply).Count
        response_after_patch_observation_window_count = 1
        treatment_patched_while_humans_present = $true
        meaningful_post_patch_observation_window_exists = $true
        patch_response_to_human_imbalance_observed = $true
        post_patch_frag_gap_trend = "improved"
        explanation = "Guided rehearsal stage: treatment now has enough post-patch observation for a sufficient live verdict."
    }

$rehearsalMetadata = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    synthetic_fixture = $true
    rehearsal_mode = $true
    validation_only = $true
    evidence_origin = "rehearsal"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    fixture_id = $FixtureId
    fixture_description = $fixtureDescription
    fixture_note = $fixtureNote
    pair_root = $pairRoot
    control_join_target = $controlJoinTarget
    treatment_join_target = $treatmentJoinTarget
    treatment_profile = $TreatmentProfile
    thresholds = [ordered]@{
        min_human_snapshots = $effectiveMinHumanSnapshots
        min_human_presence_seconds = $effectiveMinHumanPresenceSeconds
        min_patch_events_for_usable_lane = $effectiveMinPatchEvents
        min_post_patch_observation_seconds = $effectiveMinPostPatchObservationSeconds
    }
    staged_monitor_verdicts = @(
        "waiting-for-control-human-signal",
        "waiting-for-treatment-human-signal",
        "waiting-for-treatment-patch-while-humans-present",
        "waiting-for-post-patch-observation-window",
        "sufficient-for-tuning-usable-review",
        "sufficient-for-scorecard"
    )
    guided_stop_signal_path = $GuidedStopSignalPath
}
Write-JsonFile -Path $rehearsalMetadataPath -Value $rehearsalMetadata

$controlJoinInstructionsPath = Join-Path $pairRoot "control_join_instructions.txt"
$treatmentJoinInstructionsPath = Join-Path $pairRoot "treatment_join_instructions.txt"
$pairJoinInstructionsPath = Join-Path $pairRoot "pair_join_instructions.txt"

$stages = @(
    [ordered]@{
        name = "stage-1-control-human-wait"
        expected_verdict = "waiting-for-control-human-signal"
        control_summary = $controlWaitingSummary
        treatment_summary = $treatmentWaitingSummary
        control_telemetry = @($controlTelemetryRecordsBase | Select-Object -First ([Math]::Max(1, [Math]::Min($controlTelemetryRecordsBase.Count, $effectiveMinHumanSnapshots))))
        treatment_telemetry = @()
        treatment_apply = @()
        treatment_patch = @()
    }
    [ordered]@{
        name = "stage-2-treatment-human-wait"
        expected_verdict = "waiting-for-treatment-human-signal"
        control_summary = $controlReadySummary
        treatment_summary = $treatmentWaitingSummary
        control_telemetry = @($controlTelemetryRecordsBase | Select-Object -First ([Math]::Max(1, [Math]::Min($controlTelemetryRecordsBase.Count, $effectiveMinHumanSnapshots + 1))))
        treatment_telemetry = @($treatmentTelemetryRecordsBase | Select-Object -First 1)
        treatment_apply = @()
        treatment_patch = @()
    }
    [ordered]@{
        name = "stage-3-treatment-patch-wait"
        expected_verdict = "waiting-for-treatment-patch-while-humans-present"
        control_summary = $controlReadySummary
        treatment_summary = $treatmentPatchWaitingSummary
        control_telemetry = @($controlTelemetryRecordsBase | Select-Object -First ([Math]::Max(1, [Math]::Min($controlTelemetryRecordsBase.Count, $effectiveMinHumanSnapshots + 1))))
        treatment_telemetry = @($treatmentTelemetryRecordsBase | Select-Object -First 3)
        treatment_apply = @()
        treatment_patch = @()
    }
    [ordered]@{
        name = "stage-4-post-patch-observation-wait"
        expected_verdict = "waiting-for-post-patch-observation-window"
        control_summary = $controlReadySummary
        treatment_summary = $treatmentPostPatchWaitingSummary
        control_telemetry = @($controlTelemetryRecordsBase)
        treatment_telemetry = @($observationSlices.Stage4Telemetry)
        treatment_apply = @($observationSlices.Stage4Apply)
        treatment_patch = @($treatmentPatchRecordsBase | Select-Object -First 1)
    }
    [ordered]@{
        name = "stage-5-sufficient-live"
        expected_verdict = "sufficient-for-tuning-usable-review"
        control_summary = $controlReadySummary
        treatment_summary = $treatmentSufficientSummary
        control_telemetry = @($controlTelemetryRecordsBase)
        treatment_telemetry = @($observationSlices.Stage5Telemetry)
        treatment_apply = @($observationSlices.Stage5Apply)
        treatment_patch = @($treatmentPatchRecordsBase | Select-Object -First 1)
    }
)

Write-Host "Guided pair rehearsal:"
Write-Host "  Fixture ID: $FixtureId"
Write-Host "  Pair root: $pairRoot"
Write-Host "  Control join target: $controlJoinTarget"
Write-Host "  Treatment join target: $treatmentJoinTarget"
Write-Host "  Treatment profile: $TreatmentProfile"
Write-Host "  Rehearsal metadata: $rehearsalMetadataPath"
Write-Host "  Progression log: $progressionPath"
Write-Host "  Guided stop signal path: $GuidedStopSignalPath"

for ($stageIndex = 0; $stageIndex -lt $stages.Count; $stageIndex++) {
    $stage = $stages[$stageIndex]
    Invoke-RehearsalStageWrite `
        -ControlSummaryPath $controlSummaryPath `
        -ControlSummaryPayload $stage.control_summary `
        -TreatmentSummaryPath $treatmentSummaryPath `
        -TreatmentSummaryPayload $stage.treatment_summary `
        -ControlTelemetryPath $controlTelemetryPath `
        -ControlTelemetryRecords $stage.control_telemetry `
        -TreatmentTelemetryPath $treatmentTelemetryPath `
        -TreatmentTelemetryRecords $stage.treatment_telemetry `
        -TreatmentPatchApplyPath $treatmentPatchApplyPath `
        -TreatmentApplyRecords $stage.treatment_apply `
        -TreatmentPatchHistoryPath $treatmentPatchHistoryPath `
        -TreatmentPatchRecords $stage.treatment_patch

    Append-NdjsonRecord -Path $progressionPath -Record ([ordered]@{
        recorded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        stage_name = $stage.name
        expected_monitor_verdict = $stage.expected_verdict
        synthetic_fixture = $true
        rehearsal_mode = $true
        evidence_origin = "rehearsal"
    })

    if ($stageIndex -eq 0) {
        Write-TextFile -Path $controlJoinInstructionsPath -Value (
            Get-JoinInstructionText `
                -RoleName "control-baseline" `
                -JoinTarget $controlJoinTarget `
                -ModeName "NoAI" `
                -TreatmentProfileName "none" `
                -PairRootPath $pairRoot `
                -FixtureIdValue $FixtureId
        )
        Write-TextFile -Path $treatmentJoinInstructionsPath -Value (
            Get-JoinInstructionText `
                -RoleName ("treatment-{0}" -f $TreatmentProfile) `
                -JoinTarget $treatmentJoinTarget `
                -ModeName "AI" `
                -TreatmentProfileName $TreatmentProfile `
                -PairRootPath $pairRoot `
                -FixtureIdValue $FixtureId
        )
        Write-TextFile -Path $pairJoinInstructionsPath -Value (
            Get-PairJoinInstructionText `
                -ControlJoinTarget $controlJoinTarget `
                -TreatmentJoinTarget $treatmentJoinTarget `
                -PairRootPath $pairRoot `
                -FixtureIdValue $FixtureId `
                -TreatmentProfileName $TreatmentProfile
        )
    }

    Write-Host "  Wrote $($stage.name) -> expected monitor verdict $($stage.expected_verdict)"

    if ($stageIndex + 1 -lt $stages.Count) {
        Start-Sleep -Seconds $StageDelaySeconds
    }
}

$startedWaitingAt = Get-Date
$finalizeReason = "duration-elapsed-after-sufficient"
$deadline = $startedWaitingAt.AddSeconds([Math]::Max(5, $DurationSeconds - ($StageDelaySeconds * ($stages.Count - 1))))
while ((Get-Date) -lt $deadline) {
    if (-not [string]::IsNullOrWhiteSpace($GuidedStopSignalPath) -and (Test-Path -LiteralPath $GuidedStopSignalPath)) {
        $finalizeReason = "guided-stop-signal-observed-after-sufficient"
        break
    }

    Start-Sleep -Seconds 1
}

Finalize-RehearsalPairRoot `
    -FixtureRoot $fixtureRoot `
    -PairRoot $pairRoot `
    -PromptId $promptId `
    -FixtureIdValue $FixtureId `
    -SessionId $sessionId `
    -MapName $Map `
    -DesiredBotCount $BotCount `
    -DesiredBotSkill $BotSkill `
    -TreatmentProfileName $TreatmentProfile `
    -DesiredControlPort $ControlPort `
    -DesiredTreatmentPort $TreatmentPort `
    -FixtureNote $fixtureNote `
    -FixtureDescription $fixtureDescription

Append-NdjsonRecord -Path $progressionPath -Record ([ordered]@{
    recorded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    stage_name = "stage-6-finalized-pair-pack"
    expected_monitor_verdict = "sufficient-for-scorecard"
    finalize_reason = $finalizeReason
    guided_stop_signal_observed = $finalizeReason -eq "guided-stop-signal-observed-after-sufficient"
    synthetic_fixture = $true
    rehearsal_mode = $true
    evidence_origin = "rehearsal"
})

Write-Host "Guided pair rehearsal finished."
Write-Host "  Pair root: $pairRoot"
Write-Host "  Finalize reason: $finalizeReason"
Write-Host "  Pair summary JSON: $(Join-Path $pairRoot 'pair_summary.json')"
Write-Host "  Comparison JSON: $(Join-Path $pairRoot 'comparison.json')"

[pscustomobject]@{
    PairRoot = $pairRoot
    FixtureId = $FixtureId
    RehearsalMetadataPath = $rehearsalMetadataPath
    ProgressionPath = $progressionPath
    FinalizeReason = $finalizeReason
    GuidedStopSignalObserved = $finalizeReason -eq "guided-stop-signal-observed-after-sufficient"
}
