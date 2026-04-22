[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = "",
    [switch]$DryRun,
    [switch]$ExecuteRefresh
)

. (Join-Path $PSScriptRoot "common.ps1")

if ($DryRun -and $ExecuteRefresh) {
    throw "Use either -DryRun or -ExecuteRefresh, not both."
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

function Read-LaneSummaryFile {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if ($null -eq $payload) {
        return $null
    }

    $primaryLane = Get-ObjectPropertyValue -Object $payload -Name "primary_lane" -Default $null
    if ($null -ne $primaryLane) {
        return $primaryLane
    }

    return $payload
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

function Find-LatestStrongSignalPairRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $strongSignalCandidate = Get-ChildItem -LiteralPath $Root -Filter "strong_signal_conservative_attempt.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $strongSignalCandidate) {
        return $strongSignalCandidate.DirectoryName
    }

    $pairCandidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $pairCandidate) {
        return $pairCandidate.DirectoryName
    }

    return ""
}

function Resolve-AuditPairRoot {
    param(
        [string]$ExplicitPairRoot,
        [switch]$ShouldUseLatest,
        [string]$ResolvedEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        return Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitPairRoot)
    }

    if ($ShouldUseLatest -or [string]::IsNullOrWhiteSpace($ExplicitPairRoot)) {
        return Resolve-ExistingPath -Path (Find-LatestStrongSignalPairRoot -Root $ResolvedEvalRoot)
    }

    return ""
}

function Get-TreatmentLaneRoot {
    param(
        [string]$ResolvedPairRoot,
        [object]$PairSummary
    )

    $fromPairSummary = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null) -Name "lane_root" -Default ""))
    if ($fromPairSummary) {
        return $fromPairSummary
    }

    $treatmentContainer = Join-Path $ResolvedPairRoot "lanes\treatment"
    if (-not (Test-Path -LiteralPath $treatmentContainer)) {
        return ""
    }

    $latest = Get-ChildItem -LiteralPath $treatmentContainer -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return ""
    }

    return $latest.FullName
}

function Get-MissionTargets {
    param(
        [object]$StrongSignalAttempt,
        [object]$Mission
    )

    $attemptTargets = Get-ObjectPropertyValue -Object $StrongSignalAttempt -Name "mission_targets" -Default $null

    return [ordered]@{
        treatment_human_snapshots = [int](Get-ObjectPropertyValue -Object $attemptTargets -Name "treatment_minimum_human_snapshots" -Default (Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_snapshots" -Default 0))
        treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $attemptTargets -Name "treatment_minimum_human_presence_seconds" -Default (Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0.0))
        treatment_patch_events_while_humans_present = [int](Get-ObjectPropertyValue -Object $attemptTargets -Name "treatment_minimum_patch_while_human_present_events" -Default (Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default 0))
        post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $attemptTargets -Name "minimum_post_patch_observation_window_seconds" -Default (Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0.0))
    }
}

function Get-EmittedHumanPresentPatchEvents {
    param([object[]]$PatchHistory)

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($PatchHistory)) {
        if (
            [bool](Get-ObjectPropertyValue -Object $record -Name "emitted" -Default $false) -and
            [int](Get-ObjectPropertyValue -Object $record -Name "current_human_player_count" -Default 0) -gt 0
        ) {
            $events.Add($record) | Out-Null
        }
    }

    return @($events.ToArray())
}

function Get-PatchAppliesDuringHumanWindow {
    param(
        [object]$TreatmentSummary,
        [object[]]$PatchApplyHistory
    )

    $firstHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "first_human_seen_server_time_seconds" -Default -1.0)
    $lastHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($PatchApplyHistory)) {
        $serverTime = [double](Get-ObjectPropertyValue -Object $record -Name "server_time_seconds" -Default -1.0)
        if (
            $serverTime -ge 0.0 -and
            $firstHumanSeen -ge 0.0 -and
            $lastHumanSeen -ge $firstHumanSeen -and
            $serverTime -ge $firstHumanSeen -and
            $serverTime -le $lastHumanSeen
        ) {
            $records.Add($record) | Out-Null
        }
    }

    return @($records.ToArray())
}

function Get-CanonicalPostPatchObservationSeconds {
    param(
        [object]$TreatmentSummary,
        [object[]]$PatchAppliesDuringHumanWindow
    )

    if (@($PatchAppliesDuringHumanWindow).Count -eq 0) {
        return 0.0
    }

    $firstApplyServerTime = [double](Get-ObjectPropertyValue -Object $PatchAppliesDuringHumanWindow[0] -Name "server_time_seconds" -Default -1.0)
    $lastHumanSeen = [double](Get-ObjectPropertyValue -Object $TreatmentSummary -Name "last_human_seen_server_time_seconds" -Default -1.0)

    if ($firstApplyServerTime -lt 0.0 -or $lastHumanSeen -lt $firstApplyServerTime) {
        return 0.0
    }

    return [Math]::Round(($lastHumanSeen - $firstApplyServerTime), 2)
}

function Get-TimestampAtIndexUtcString {
    param(
        [object[]]$Records,
        [int]$Index
    )

    if ($Index -lt 0 -or $Index -ge @($Records).Count) {
        return ""
    }

    return [string](Get-ObjectPropertyValue -Object $Records[$Index] -Name "timestamp_utc" -Default "")
}

function Get-DerivedMetricValue {
    param(
        [string]$ArtifactName,
        [object]$TreatmentPatchWindow,
        [object]$PhaseFlow,
        [object]$LiveMonitorStatus,
        [object]$MissionAttainment,
        [object]$StrongSignalAttempt,
        [object]$GroundedCertificate
    )

    $patchLane = Get-ObjectPropertyValue -Object $TreatmentPatchWindow -Name "treatment_lane" -Default $null
    $phaseLane = Get-ObjectPropertyValue -Object $PhaseFlow -Name "treatment_lane" -Default $null
    $targetResults = Get-ObjectPropertyValue -Object $MissionAttainment -Name "target_results" -Default $null

    switch ($ArtifactName) {
        "treatment_patch_window" { return $patchLane }
        "conservative_phase_flow" { return $phaseLane }
        "live_monitor_status" { return $LiveMonitorStatus }
        "mission_attainment_targets" { return $targetResults }
        "strong_signal_conservative_attempt" { return $StrongSignalAttempt }
        "grounded_evidence_certificate" { return $GroundedCertificate }
        default { return $null }
    }
}

function New-ArtifactRecord {
    param(
        [string]$Kind,
        [string]$Path,
        [bool]$Canonical,
        [string]$Summary
    )

    return [ordered]@{
        kind = $Kind
        path = Resolve-ExistingPath -Path $Path
        canonical = $Canonical
        summary = $Summary
    }
}

function New-DerivedValueRecord {
    param(
        [string]$ArtifactName,
        [string]$Path,
        [object]$Value,
        [string]$Summary
    )

    return [ordered]@{
        artifact_name = $ArtifactName
        path = Resolve-ExistingPath -Path $Path
        value = $Value
        summary = $Summary
    }
}

function Test-ValuesMatch {
    param(
        [object]$CanonicalValue,
        [object]$DerivedValue
    )

    if ($null -eq $DerivedValue) {
        return $false
    }

    if ($CanonicalValue -is [bool] -or $DerivedValue -is [bool]) {
        return [bool]$CanonicalValue -eq [bool]$DerivedValue
    }

    $canonicalIsNumber = $CanonicalValue -is [int] -or $CanonicalValue -is [long] -or $CanonicalValue -is [double] -or $CanonicalValue -is [single] -or $CanonicalValue -is [decimal]
    $derivedIsNumber = $DerivedValue -is [int] -or $DerivedValue -is [long] -or $DerivedValue -is [double] -or $DerivedValue -is [single] -or $DerivedValue -is [decimal]
    if ($canonicalIsNumber -and $derivedIsNumber) {
        return [math]::Abs(([double]$CanonicalValue) - ([double]$DerivedValue)) -lt 0.5
    }

    return [string]$CanonicalValue -eq [string]$DerivedValue
}

function New-MetricComparison {
    param(
        [string]$MetricName,
        [string]$Label,
        [object]$TargetValue,
        [object]$CanonicalValue,
        [string]$CanonicalSource,
        [object[]]$DerivedValues,
        [string]$MismatchExplanation = ""
    )

    $records = @($DerivedValues | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.artifact_name) })
    $mismatches = @($records | Where-Object { -not (Test-ValuesMatch -CanonicalValue $CanonicalValue -DerivedValue $_.value) })
    $match = @($mismatches).Count -eq 0

    return [ordered]@{
        metric_name = $MetricName
        label = $Label
        target_value = $TargetValue
        canonical_value = $CanonicalValue
        canonical_source = $CanonicalSource
        derived_values = $records
        match = $match
        explanation = if ($match) {
            "Derived values match the canonical treatment-side metric."
        }
        else {
            $MismatchExplanation
        }
    }
}

function Get-AuditMarkdown {
    param([object]$Audit)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Treatment Strong-Signal Gap Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Gap verdict: $($Audit.gap_verdict)") | Out-Null
    $lines.Add("- Consistency verdict: $($Audit.consistency_verdict)") | Out-Null
    $lines.Add("- Explanation: $($Audit.explanation)") | Out-Null
    $lines.Add("- Pair root: $($Audit.pair_root)") | Out-Null
    $lines.Add("- Strong-signal next step: $($Audit.next_step_recommendation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Canonical Precedence") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($source in @($Audit.canonical_sources)) {
        $lines.Add("- $($source.kind): $($source.summary)") | Out-Null
        $lines.Add("  Path: $($source.path)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Secondary Sources") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($source in @($Audit.secondary_sources)) {
        $lines.Add("- $($source.kind): $($source.summary)") | Out-Null
        $lines.Add("  Path: $($source.path)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Key Metrics") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($metric in @($Audit.metric_comparisons)) {
        $lines.Add("- $($metric.label): target=$($metric.target_value), canonical=$($metric.canonical_value), match=$($metric.match)") | Out-Null
        $lines.Add("  Canonical source: $($metric.canonical_source)") | Out-Null
        $lines.Add("  Explanation: $($metric.explanation)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Patch Timeline") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- First counted human-present patch timestamp: $($Audit.treatment_gap.first_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("- Second counted human-present patch timestamp: $($Audit.treatment_gap.second_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("- Third counted human-present patch timestamp: $($Audit.treatment_gap.third_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("- First patch apply during human window timestamp: $($Audit.treatment_gap.first_patch_apply_during_human_window_timestamp_utc)") | Out-Null
    $lines.Add("- First patch apply during human window count: $($Audit.treatment_gap.patch_apply_count_while_humans_present)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Refresh Plan") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Refresh justified: $($Audit.refresh_plan.refresh_justified)") | Out-Null
    $lines.Add("- Refresh mode requested: $($Audit.refresh_plan.mode_requested)") | Out-Null
    $lines.Add("- Refresh executed: $($Audit.refresh_plan.executed)") | Out-Null
    $lines.Add("- Explanation: $($Audit.refresh_plan.explanation)") | Out-Null
    foreach ($action in @($Audit.refresh_plan.actions)) {
        $lines.Add("- $($action.artifact): $($action.command)") | Out-Null
    }

    return (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedEvalRoot = Get-ResolvedEvalRoot -ExplicitLabRoot $LabRoot -ExplicitEvalRoot $EvalRoot
$resolvedPairRoot = Resolve-AuditPairRoot -ExplicitPairRoot $PairRoot -ShouldUseLatest:$UseLatest -ResolvedEvalRoot $resolvedEvalRoot

if ([string]::IsNullOrWhiteSpace($resolvedPairRoot)) {
    throw "No pair root could be resolved for the treatment strong-signal gap audit."
}

$auditRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $resolvedPairRoot
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $resolvedPairRoot)
}

$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
$pairSummary = Read-JsonFile -Path $pairSummaryPath
if ($null -eq $pairSummary) {
    throw "pair_summary.json is required for this audit: $resolvedPairRoot"
}

$treatmentLaneRoot = Get-TreatmentLaneRoot -ResolvedPairRoot $resolvedPairRoot -PairSummary $pairSummary
if (-not $treatmentLaneRoot) {
    throw "Treatment lane root could not be resolved for pair root: $resolvedPairRoot"
}

$treatmentSummaryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "summary.json")
$treatmentSummary = Read-LaneSummaryFile -Path $treatmentSummaryPath
if ($null -eq $treatmentSummary) {
    throw "Treatment lane summary is required for this audit: $treatmentLaneRoot"
}

$controlSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "summary_json" -Default ""))
$controlSummary = Read-LaneSummaryFile -Path $controlSummaryPath

$treatmentPatchWindowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "treatment_patch_window.json")
$treatmentPatchWindow = Read-JsonFile -Path $treatmentPatchWindowPath
$phaseFlowPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "conservative_phase_flow.json")
$phaseFlow = Read-JsonFile -Path $phaseFlowPath
$liveMonitorStatusPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$liveMonitorStatus = Read-JsonFile -Path $liveMonitorStatusPath
$missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_attainment.json")
$missionAttainment = Read-JsonFile -Path $missionAttainmentPath
$strongSignalAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "strong_signal_conservative_attempt.json")
$strongSignalAttempt = Read-JsonFile -Path $strongSignalAttemptPath
$humanAttemptPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "human_participation_conservative_attempt.json")
$humanAttempt = Read-JsonFile -Path $humanAttemptPath
$groundedCertificatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_evidence_certificate.json")
$groundedCertificate = Read-JsonFile -Path $groundedCertificatePath
$dossierPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "session_outcome_dossier.json")
$dossier = Read-JsonFile -Path $dossierPath
$deltaPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "promotion_gap_delta.json")
$delta = Read-JsonFile -Path $deltaPath

$missionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $StrongSignalAttempt -Name "mission_path_used" -Default (Get-ObjectPropertyValue -Object $HumanAttempt -Name "mission_path_used" -Default "")))
$mission = Read-JsonFile -Path $missionPath

$patchHistoryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_history.ndjson")
$patchApplyHistoryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "patch_apply_history.ndjson")
$telemetryHistoryPath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "telemetry_history.ndjson")
$humanPresenceTimelinePath = Resolve-ExistingPath -Path (Join-Path $treatmentLaneRoot "human_presence_timeline.ndjson")
$patchHistory = Read-NdjsonFile -Path $patchHistoryPath
$patchApplyHistory = Read-NdjsonFile -Path $patchApplyHistoryPath
$telemetryHistory = Read-NdjsonFile -Path $telemetryHistoryPath
$humanPresenceTimeline = Read-NdjsonFile -Path $humanPresenceTimelinePath
$monitorHistoryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\monitor_verdict_history.ndjson")
$monitorHistory = Read-NdjsonFile -Path $monitorHistoryPath

$targets = Get-MissionTargets -StrongSignalAttempt $strongSignalAttempt -Mission $mission
$emittedHumanPresentPatchEvents = Get-EmittedHumanPresentPatchEvents -PatchHistory $patchHistory
$patchAppliesDuringHumanWindow = Get-PatchAppliesDuringHumanWindow -TreatmentSummary $treatmentSummary -PatchApplyHistory $patchApplyHistory
$canonicalCountedPatchEvents = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_events_while_humans_present_count" -Default @($emittedHumanPresentPatchEvents).Count)
$canonicalPatchApplyCount = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_apply_count_while_humans_present" -Default @($patchAppliesDuringHumanWindow).Count)
$canonicalRawPatchEvents = @($emittedHumanPresentPatchEvents).Count
$canonicalPostPatchSeconds = Get-CanonicalPostPatchObservationSeconds -TreatmentSummary $treatmentSummary -PatchAppliesDuringHumanWindow $patchAppliesDuringHumanWindow

$treatmentHumanSnapshotsActual = [int](Get-ObjectPropertyValue -Object $treatmentSummary -Name "human_snapshots_count" -Default 0)
$treatmentHumanPresenceSecondsActual = [double](Get-ObjectPropertyValue -Object $treatmentSummary -Name "seconds_with_human_presence" -Default 0.0)
$treatmentPatchedWhileHumansPresent = [bool](Get-ObjectPropertyValue -Object $groundedCertificate -Name "treatment_patched_while_humans_present" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null) -Name "treatment_patched_while_humans_present" -Default $false))
$meaningfulPostPatchObservationWindowExists = [bool](Get-ObjectPropertyValue -Object $groundedCertificate -Name "meaningful_post_patch_observation_window_exists" -Default (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null) -Name "meaningful_post_patch_observation_window_exists" -Default $false))

$treatmentGroundedReadyCanonical = (
    $treatmentHumanSnapshotsActual -ge $targets.treatment_human_snapshots -and
    $treatmentHumanPresenceSecondsActual -ge $targets.treatment_human_presence_seconds -and
    $treatmentPatchedWhileHumansPresent -and
    $meaningfulPostPatchObservationWindowExists
)

$treatmentStrongSignalReadyCanonical = (
    $treatmentHumanSnapshotsActual -ge $targets.treatment_human_snapshots -and
    $treatmentHumanPresenceSecondsActual -ge $targets.treatment_human_presence_seconds -and
    $canonicalCountedPatchEvents -ge $targets.treatment_patch_events_while_humans_present -and
    $canonicalPostPatchSeconds -ge $targets.post_patch_observation_seconds
)

$targetResults = Get-ObjectPropertyValue -Object $missionAttainment -Name "target_results" -Default $null
$patchTargetResult = Get-ObjectPropertyValue -Object $targetResults -Name "treatment_minimum_patch_while_human_present_events" -Default $null
$postPatchTargetResult = Get-ObjectPropertyValue -Object $targetResults -Name "minimum_post_patch_observation_window_seconds" -Default $null

$metricComparisons = @(
    (New-MetricComparison -MetricName "treatment_human_snapshots" -Label "Treatment human snapshots" -TargetValue $targets.treatment_human_snapshots -CanonicalValue $treatmentHumanSnapshotsActual -CanonicalSource "treatment summary.json / pair_summary.json" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_human_snapshots" -Default $null) -Summary "Saved treatment gate actual value."),
            (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $phaseFlowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $phaseFlow -Name "treatment_lane" -Default $null) -Name "actual_human_snapshots" -Default $null) -Summary "Saved phase-director treatment value."),
            (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $liveMonitorStatusPath -Value (Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_human_snapshots_count" -Default $null) -Summary "Saved live monitor treatment snapshots."),
            (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $missionAttainmentPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $targetResults -Name "treatment_minimum_human_snapshots" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout treatment snapshots.")
        ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical treatment snapshot count."),
    (New-MetricComparison -MetricName "treatment_human_presence_seconds" -Label "Treatment human presence seconds" -TargetValue $targets.treatment_human_presence_seconds -CanonicalValue $treatmentHumanPresenceSecondsActual -CanonicalSource "treatment summary.json / pair_summary.json" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved treatment gate treatment-seconds."),
            (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $phaseFlowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $phaseFlow -Name "treatment_lane" -Default $null) -Name "actual_human_presence_seconds" -Default $null) -Summary "Saved phase-director treatment-seconds."),
            (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $liveMonitorStatusPath -Value (Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_human_presence_seconds" -Default $null) -Summary "Saved live monitor treatment-seconds."),
            (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $missionAttainmentPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $targetResults -Name "treatment_minimum_human_presence_seconds" -Default $null) -Name "actual_value" -Default $null) -Summary "Mission closeout treatment-seconds.")
        ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical treatment human-presence seconds."),
    (New-MetricComparison -MetricName "counted_human_present_patch_events" -Label "Counted human-present patch events" -TargetValue $targets.treatment_patch_events_while_humans_present -CanonicalValue $canonicalCountedPatchEvents -CanonicalSource "treatment summary.json patch_events_while_humans_present_count" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_patch_while_human_present_events" -Default $null) -Summary "Saved treatment gate counted patch events."),
            (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $phaseFlowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $phaseFlow -Name "treatment_lane" -Default $null) -Name "actual_patch_while_human_present_events" -Default $null) -Summary "Saved phase-director counted patch events."),
            (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $liveMonitorStatusPath -Value (Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_patch_events_while_humans_present" -Default $null) -Summary "Saved live monitor counted patch events."),
            (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $missionAttainmentPath -Value (Get-ObjectPropertyValue -Object $patchTargetResult -Name "actual_value" -Default $null) -Summary "Mission closeout counted patch events.")
        ) -MismatchExplanation "Secondary derived artifacts disagree with the counted treatment patch-event metric."),
    (New-MetricComparison -MetricName "canonical_human_present_patch_events" -Label "Canonical human-present patch events" -TargetValue $targets.treatment_patch_events_while_humans_present -CanonicalValue $canonicalRawPatchEvents -CanonicalSource "patch_history.ndjson emitted=true while humans present" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "treatment_summary" -Path $treatmentSummaryPath -Value (Get-ObjectPropertyValue -Object $treatmentSummary -Name "patch_events_while_humans_present_count" -Default $null) -Summary "Saved treatment summary patch-events count."),
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_patch_while_human_present_events" -Default $null) -Summary "Saved treatment gate patch-events count.")
        ) -MismatchExplanation "The raw patch-history count and the saved counted-patch metric do not agree."),
    (New-MetricComparison -MetricName "post_patch_observation_seconds" -Label "Post-patch observation seconds" -TargetValue $targets.post_patch_observation_seconds -CanonicalValue $canonicalPostPatchSeconds -CanonicalSource "treatment summary human window + patch_apply_history.ndjson" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_lane" -Default $null) -Name "actual_post_patch_observation_seconds" -Default $null) -Summary "Saved treatment gate post-patch seconds."),
            (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $phaseFlowPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $phaseFlow -Name "treatment_lane" -Default $null) -Name "actual_post_patch_observation_seconds" -Default $null) -Summary "Saved phase-director post-patch seconds."),
            (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $liveMonitorStatusPath -Value (Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "meaningful_post_patch_observation_seconds" -Default $null) -Summary "Saved live monitor post-patch seconds."),
            (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $missionAttainmentPath -Value (Get-ObjectPropertyValue -Object $postPatchTargetResult -Name "actual_value" -Default $null) -Summary "Mission closeout post-patch seconds.")
        ) -MismatchExplanation "Secondary derived artifacts disagree with the canonical post-patch observation seconds."),
    (New-MetricComparison -MetricName "treatment_grounded_ready" -Label "Treatment grounded-ready" -TargetValue $true -CanonicalValue $treatmentGroundedReadyCanonical -CanonicalSource "grounded certificate rules: human thresholds + patched while humans present + post-patch window" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "grounded_evidence_certificate" -Path $groundedCertificatePath -Value (Get-ObjectPropertyValue -Object $groundedCertificate -Name "counts_toward_promotion" -Default $null) -Summary "Canonical promotion-counting certificate."),
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_grounded_ready" -Default $null) -Summary "Secondary field that actually reflects the mission strong-signal gate."),
            (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $phaseFlowPath -Value (Get-ObjectPropertyValue -Object $phaseFlow -Name "finish_grounded_session_allowed" -Default $null) -Summary "Secondary phase-director finish field driven by the same mission gate.")
        ) -MismatchExplanation "The grounded certificate says the treatment side already counts, but the saved treatment gate fields are still reflecting the stricter strong-signal mission threshold rather than grounded-counting readiness."),
    (New-MetricComparison -MetricName "treatment_strong_signal_ready" -Label "Treatment strong-signal-ready" -TargetValue $true -CanonicalValue $treatmentStrongSignalReadyCanonical -CanonicalSource "mission treatment thresholds + canonical counted patch events + canonical post-patch seconds" -DerivedValues @(
            (New-DerivedValueRecord -ArtifactName "treatment_patch_window" -Path $treatmentPatchWindowPath -Value (Get-ObjectPropertyValue -Object $treatmentPatchWindow -Name "treatment_grounded_ready" -Default $null) -Summary "Secondary field currently used as the strong-signal gate."),
            (New-DerivedValueRecord -ArtifactName "conservative_phase_flow" -Path $phaseFlowPath -Value (Get-ObjectPropertyValue -Object $phaseFlow -Name "finish_grounded_session_allowed" -Default $null) -Summary "Secondary phase-director finish field."),
            (New-DerivedValueRecord -ArtifactName "live_monitor_status" -Path $liveMonitorStatusPath -Value ([string](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "current_verdict" -Default "") -in @("sufficient-for-scorecard", "sufficient-for-tuning-usable-grounded-pair", "sufficient-for-grounded-certification", "sufficient-for-strong-signal")) -Summary "Derived live monitor sufficient-state collapse."),
            (New-DerivedValueRecord -ArtifactName "mission_attainment" -Path $missionAttainmentPath -Value (Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_grounded_success" -Default $null) -Summary "Mission closeout strong-signal success field."),
            (New-DerivedValueRecord -ArtifactName "strong_signal_conservative_attempt" -Path $strongSignalAttemptPath -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "strong_signal_capture" -Default $null) -Name "captured" -Default $null) -Summary "Strong-signal wrapper capture field.")
        ) -MismatchExplanation "Secondary strong-signal layers disagree with the canonical strong-signal-ready state.")
)

$metricMismatches = @($metricComparisons | Where-Object { -not [bool]$_.match })
$groundedMetricMismatch = @($metricMismatches | Where-Object { $_.metric_name -eq "treatment_grounded_ready" }).Count -gt 0
$countedPatchMismatch = @($metricMismatches | Where-Object { $_.metric_name -eq "counted_human_present_patch_events" -or $_.metric_name -eq "canonical_human_present_patch_events" }).Count -gt 0
$postPatchMismatch = @($metricMismatches | Where-Object { $_.metric_name -eq "post_patch_observation_seconds" }).Count -gt 0

$gapVerdict = if ($treatmentStrongSignalReadyCanonical -and @($metricMismatches).Count -gt 0) {
    "strong-signal-criteria-met-but-wrapper-stale"
}
elseif ($countedPatchMismatch) {
    "patch-event-under-count-in-derived-layer"
}
elseif ($postPatchMismatch) {
    "post-patch-window-under-count-in-derived-layer"
}
elseif (-not $treatmentStrongSignalReadyCanonical) {
    "strong-signal-gap-real-treatment-still-short"
}
else {
    "inconclusive-manual-review"
}

$consistencyVerdict = if (-not $countedPatchMismatch -and -not $postPatchMismatch -and -not $treatmentStrongSignalReadyCanonical) {
    "canonical-and-derived-consistent-but-below-target"
}
elseif ($countedPatchMismatch) {
    "patch-event-under-count-in-derived-layer"
}
elseif ($postPatchMismatch) {
    "post-patch-window-under-count-in-derived-layer"
}
elseif ($treatmentStrongSignalReadyCanonical) {
    "strong-signal-criteria-met-but-wrapper-stale"
}
else {
    "inconclusive-manual-review"
}

$refreshJustified = $countedPatchMismatch -or $postPatchMismatch
$refreshActions = @(
    [ordered]@{
        artifact = "treatment_patch_window"
        command = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\guide_treatment_patch_window.ps1 -PairRoot `"$resolvedPairRoot`" -MissionPath `"$missionPath`" -Once"
        safe = $true
    },
    [ordered]@{
        artifact = "conservative_phase_flow"
        command = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\guide_conservative_phase_flow.ps1 -PairRoot `"$resolvedPairRoot`" -MissionPath `"$missionPath`" -Once"
        safe = $true
    },
    [ordered]@{
        artifact = "live_monitor_status"
        command = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\monitor_live_pair_session.ps1 -PairRoot `"$resolvedPairRoot`" -Once -MinControlHumanSnapshots $([int](Get-ObjectPropertyValue -Object $pairSummary -Name 'min_human_snapshots' -Default 5)) -MinControlHumanPresenceSeconds $([double](Get-ObjectPropertyValue -Object $pairSummary -Name 'min_human_presence_seconds' -Default 90.0)) -MinTreatmentHumanSnapshots $($targets.treatment_human_snapshots) -MinTreatmentHumanPresenceSeconds $($targets.treatment_human_presence_seconds) -MinTreatmentPatchEventsWhileHumansPresent $($targets.treatment_patch_events_while_humans_present) -MinPostPatchObservationSeconds $($targets.post_patch_observation_seconds)"
        safe = $true
    },
    [ordered]@{
        artifact = "mission_attainment"
        command = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\evaluate_latest_session_mission.ps1 -PairRoot `"$resolvedPairRoot`""
        safe = $true
    }
)

$refreshExecuted = $false
$refreshExecutionResults = @()
$refreshExplanation = if ($refreshJustified) {
    "A secondary derived under-count was detected, so the refresh plan is available for the safe gate and mission-closeout artifacts."
}
else {
    "No safe derived refresh is justified. The saved gap is driven by real treatment-side strong-signal shortfall or by scope/naming differences, not by stale counted metrics."
}

if ($ExecuteRefresh -and $refreshJustified) {
    foreach ($action in @($refreshActions)) {
        try {
            Invoke-Expression ([string]$action.command) | Out-Null
            $refreshExecutionResults += [ordered]@{
                artifact = $action.artifact
                command = $action.command
                executed = $true
                error = ""
            }
        }
        catch {
            $refreshExecutionResults += [ordered]@{
                artifact = $action.artifact
                command = $action.command
                executed = $false
                error = $_.Exception.Message
            }
        }
    }

    $refreshExecuted = $true
}

$canonicalSources = @(
    (New-ArtifactRecord -Kind "pair_summary_json" -Path $pairSummaryPath -Canonical $true -Summary "Canonical pair-level treatment metrics and comparison summary."),
    (New-ArtifactRecord -Kind "treatment_summary_json" -Path $treatmentSummaryPath -Canonical $true -Summary "Canonical treatment lane summary, including patch-event and patch-apply counts."),
    (New-ArtifactRecord -Kind "patch_history_ndjson" -Path $patchHistoryPath -Canonical $true -Summary "Canonical raw patch recommendation history used for human-present patch-event counting."),
    (New-ArtifactRecord -Kind "patch_apply_history_ndjson" -Path $patchApplyHistoryPath -Canonical $true -Summary "Canonical patch-apply history used for post-patch observation timing."),
    (New-ArtifactRecord -Kind "telemetry_history_ndjson" -Path $telemetryHistoryPath -Canonical $true -Summary "Canonical treatment telemetry used for post-patch timing context."),
    (New-ArtifactRecord -Kind "human_presence_timeline_ndjson" -Path $humanPresenceTimelinePath -Canonical $true -Summary "Canonical human-presence timeline for treatment-side timing review."),
    (New-ArtifactRecord -Kind "grounded_evidence_certificate_json" -Path $groundedCertificatePath -Canonical $true -Summary "Canonical grounded promotion-counting certificate."),
    (New-ArtifactRecord -Kind "strong_signal_conservative_mission_json" -Path $missionPath -Canonical $true -Summary "Canonical treatment-side strong-signal targets for this pair.")
)

$secondarySources = @(
    (New-ArtifactRecord -Kind "treatment_patch_window_json" -Path $treatmentPatchWindowPath -Canonical $false -Summary "Secondary treatment-hold gate derived from canonical treatment metrics."),
    (New-ArtifactRecord -Kind "conservative_phase_flow_json" -Path $phaseFlowPath -Canonical $false -Summary "Secondary sequential phase-director derived from control/treatment gates."),
    (New-ArtifactRecord -Kind "live_monitor_status_json" -Path $liveMonitorStatusPath -Canonical $false -Summary "Secondary monitor snapshot that summarizes the live mission outcome."),
    (New-ArtifactRecord -Kind "mission_attainment_json" -Path $missionAttainmentPath -Canonical $false -Summary "Secondary mission-closeout artifact that rephrases the strong-signal gap."),
    (New-ArtifactRecord -Kind "strong_signal_conservative_attempt_json" -Path $strongSignalAttemptPath -Canonical $false -Summary "Secondary wrapper summary for the strong-signal attempt."),
    (New-ArtifactRecord -Kind "human_participation_conservative_attempt_json" -Path $humanAttemptPath -Canonical $false -Summary "Secondary wrapper summary for the client-assisted run."),
    (New-ArtifactRecord -Kind "session_outcome_dossier_json" -Path $dossierPath -Canonical $false -Summary "Secondary operator-facing closeout dossier."),
    (New-ArtifactRecord -Kind "promotion_gap_delta_json" -Path $deltaPath -Canonical $false -Summary "Secondary registry delta summary.")
)

$substantiveDisagreements = New-Object System.Collections.Generic.List[string]
$narrativeDisagreements = New-Object System.Collections.Generic.List[string]

if ($countedPatchMismatch) {
    $substantiveDisagreements.Add("Derived treatment patch-event counts do not match the canonical treatment summary / raw patch-history count.") | Out-Null
}
if ($postPatchMismatch) {
    $substantiveDisagreements.Add("Derived post-patch observation seconds do not match the canonical treatment timing window.") | Out-Null
}
if ($groundedMetricMismatch) {
    $narrativeDisagreements.Add("Treatment gate files mark 'grounded-ready' false even though the canonical certificate already counts the pair. Those fields are reflecting the stronger mission gate, not the grounded-counting minimum.") | Out-Null
}

$explanationParts = New-Object System.Collections.Generic.List[string]
if (-not $treatmentStrongSignalReadyCanonical) {
    $explanationParts.Add("Canonical treatment evidence is still short of the strong-signal target.") | Out-Null
}
else {
    $explanationParts.Add("Canonical treatment evidence already meets the strong-signal target.") | Out-Null
}

if ($canonicalCountedPatchEvents -lt $targets.treatment_patch_events_while_humans_present) {
    $explanationParts.Add("Counted human-present patch events are $canonicalCountedPatchEvents / $($targets.treatment_patch_events_while_humans_present).") | Out-Null
}

if (@($substantiveDisagreements).Count -gt 0) {
    $explanationParts.Add("There is at least one substantive derived under-count that can justify a safe refresh.") | Out-Null
}
elseif (@($narrativeDisagreements).Count -gt 0) {
    $explanationParts.Add("The remaining disagreement is semantic: some secondary 'grounded-ready' fields are actually expressing the stronger mission gate, not canonical grounded counting.") | Out-Null
}
else {
    $explanationParts.Add("Canonical and secondary treatment-side metrics agree on the real shortfall.") | Out-Null
}

$nextStepRecommendation = if ($treatmentStrongSignalReadyCanonical -and @($substantiveDisagreements).Count -gt 0) {
    "treatment-side-evidence-actually-sufficient-refresh-derived-artifacts-only"
}
elseif (@($substantiveDisagreements).Count -gt 0) {
    "manual-review-needed"
}
elseif (-not $treatmentStrongSignalReadyCanonical) {
    "keep-conservative-and-collect-one-more-stronger-treatment-window"
}
else {
    "repeat-strong-signal-conservative-session"
}

$audit = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $resolvedPairRoot
    gap_verdict = $gapVerdict
    consistency_verdict = $consistencyVerdict
    explanation = (($explanationParts.ToArray()) -join " ")
    next_step_recommendation = $nextStepRecommendation
    responsive_remains_blocked = $true
    canonical_sources = $canonicalSources
    secondary_sources = $secondarySources
    canonical_metric_precedence = [ordered]@{
        treatment_human_signal = "treatment summary.json, confirmed against pair_summary.json"
        counted_human_present_patch_events = "patch_events_while_humans_present_count from treatment summary.json, confirmed against patch_history.ndjson"
        canonical_human_present_patch_events = "raw emitted patch recommendations from patch_history.ndjson while humans are present"
        post_patch_observation_seconds = "treatment summary human window combined with patch_apply_history.ndjson"
        grounded_counting = "grounded_evidence_certificate.json"
    }
    treatment_gap = [ordered]@{
        treatment_human_snapshots_target = $targets.treatment_human_snapshots
        treatment_human_snapshots_actual = $treatmentHumanSnapshotsActual
        treatment_human_presence_seconds_target = $targets.treatment_human_presence_seconds
        treatment_human_presence_seconds_actual = $treatmentHumanPresenceSecondsActual
        counted_human_present_patch_events_target = $targets.treatment_patch_events_while_humans_present
        counted_human_present_patch_events_actual = $canonicalCountedPatchEvents
        canonical_human_present_patch_events_target = $targets.treatment_patch_events_while_humans_present
        canonical_human_present_patch_events_actual = $canonicalRawPatchEvents
        patch_apply_count_while_humans_present = $canonicalPatchApplyCount
        first_human_present_patch_timestamp_utc = Get-TimestampAtIndexUtcString -Records $emittedHumanPresentPatchEvents -Index 0
        second_human_present_patch_timestamp_utc = Get-TimestampAtIndexUtcString -Records $emittedHumanPresentPatchEvents -Index 1
        third_human_present_patch_timestamp_utc = Get-TimestampAtIndexUtcString -Records $emittedHumanPresentPatchEvents -Index 2
        first_patch_apply_during_human_window_timestamp_utc = Get-TimestampAtIndexUtcString -Records $patchAppliesDuringHumanWindow -Index 0
        post_patch_observation_seconds_target = $targets.post_patch_observation_seconds
        post_patch_observation_seconds_actual = $canonicalPostPatchSeconds
        treatment_grounded_ready = $treatmentGroundedReadyCanonical
        treatment_strong_signal_ready = $treatmentStrongSignalReadyCanonical
    }
    metric_comparisons = $metricComparisons
    disagreements = [ordered]@{
        substantive = @($substantiveDisagreements.ToArray())
        narrative_only = @($narrativeDisagreements.ToArray())
    }
    artifact_consistency = [ordered]@{
        pair_summary = [ordered]@{
            pair_classification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
            treatment_behavior_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null) -Name "treatment_behavior_verdict" -Default "")
        }
        grounded_evidence_certificate = [ordered]@{
            certification_verdict = [string](Get-ObjectPropertyValue -Object $groundedCertificate -Name "certification_verdict" -Default "")
            counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $groundedCertificate -Name "counts_toward_promotion" -Default $false)
            session_is_strong_signal = [bool](Get-ObjectPropertyValue -Object $groundedCertificate -Name "session_is_strong_signal" -Default $false)
        }
        strong_signal_conservative_attempt = [ordered]@{
            attempt_verdict = [string](Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "attempt_verdict" -Default "")
            strong_signal_capture = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "strong_signal_capture" -Default $null) -Name "captured" -Default $false)
            counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $strongSignalAttempt -Name "counts_toward_promotion" -Default $false)
        }
        mission_attainment = [ordered]@{
            mission_verdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")
            treatment_patch_events_actual = Get-ObjectPropertyValue -Object $patchTargetResult -Name "actual_value" -Default $null
            post_patch_seconds_actual = Get-ObjectPropertyValue -Object $postPatchTargetResult -Name "actual_value" -Default $null
        }
        live_monitor_status = [ordered]@{
            current_verdict = [string](Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "current_verdict" -Default "")
            treatment_patch_events_while_humans_present = Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "treatment_patch_events_while_humans_present" -Default $null
            meaningful_post_patch_observation_seconds = Get-ObjectPropertyValue -Object $liveMonitorStatus -Name "meaningful_post_patch_observation_seconds" -Default $null
            history_records = @($monitorHistory).Count
        }
    }
    refresh_plan = [ordered]@{
        mode_requested = if ($ExecuteRefresh) { "execute-refresh" } elseif ($DryRun) { "dry-run" } else { "audit-only" }
        refresh_justified = $refreshJustified
        explanation = $refreshExplanation
        actions = $refreshActions
        executed = $refreshExecuted
        execution_results = $refreshExecutionResults
    }
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryPath
        treatment_summary_json = $treatmentSummaryPath
        treatment_patch_window_json = $treatmentPatchWindowPath
        conservative_phase_flow_json = $phaseFlowPath
        live_monitor_status_json = $liveMonitorStatusPath
        mission_attainment_json = $missionAttainmentPath
        strong_signal_conservative_attempt_json = $strongSignalAttemptPath
        human_participation_conservative_attempt_json = $humanAttemptPath
        grounded_evidence_certificate_json = $groundedCertificatePath
        session_outcome_dossier_json = $dossierPath
        promotion_gap_delta_json = $deltaPath
        patch_history_ndjson = $patchHistoryPath
        patch_apply_history_ndjson = $patchApplyHistoryPath
        telemetry_history_ndjson = $telemetryHistoryPath
        human_presence_timeline_ndjson = $humanPresenceTimelinePath
        monitor_verdict_history_ndjson = $monitorHistoryPath
    }
}

$jsonPath = Join-Path $auditRoot "treatment_strong_signal_gap_audit.json"
$markdownPath = Join-Path $auditRoot "treatment_strong_signal_gap_audit.md"
$markdown = Get-AuditMarkdown -Audit $audit

Write-JsonFile -Path $jsonPath -Value $audit
Write-TextFile -Path $markdownPath -Value $markdown

Write-Host "Treatment strong-signal gap audit:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Gap verdict: $gapVerdict"
Write-Host "  Consistency verdict: $consistencyVerdict"
Write-Host "  Audit JSON: $jsonPath"
Write-Host "  Audit Markdown: $markdownPath"
if ($DryRun) {
    Write-Host "  Refresh dry-run: $refreshExplanation"
}
elseif ($ExecuteRefresh) {
    Write-Host "  Refresh executed: $refreshExecuted"
}

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    TreatmentStrongSignalGapAuditJsonPath = $jsonPath
    TreatmentStrongSignalGapAuditMarkdownPath = $markdownPath
    GapVerdict = $gapVerdict
    ConsistencyVerdict = $consistencyVerdict
    RefreshJustified = $refreshJustified
}
