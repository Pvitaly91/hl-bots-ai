param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [int]$PollSeconds = 5,
    [int]$MinControlHumanSnapshots = -1,
    [double]$MinControlHumanPresenceSeconds = -1,
    [int]$MinTreatmentHumanSnapshots = -1,
    [double]$MinTreatmentHumanPresenceSeconds = -1,
    [int]$MinTreatmentPatchEventsWhileHumansPresent = -1,
    [double]$MinPostPatchObservationSeconds = -1,
    [switch]$StopWhenSufficient,
    [int]$MaxMonitorSeconds = 0,
    [string]$OutputRoot = "",
    [switch]$Once,
    [string]$LabRoot = "",
    [string]$PairsRoot = "",
    [string]$PythonPath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
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

function Read-LaneSummaryFile {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if ($null -eq $payload) {
        return $null
    }

    if ($null -ne $payload.PSObject.Properties["primary_lane"]) {
        return $payload.primary_lane
    }

    return $payload
}

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Find-LatestActivePairRoot {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName "pair_summary.json")) } |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Get-TreatmentProfileHint {
    param([string]$ResolvedPairRoot)

    $pairSummary = Read-JsonFile -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    if ($null -ne $pairSummary -and -not [string]::IsNullOrWhiteSpace([string]$pairSummary.treatment_profile)) {
        return [string]$pairSummary.treatment_profile
    }

    foreach ($laneJsonPath in @(
        (Join-Path $ResolvedPairRoot "lanes\treatment\lane.json"),
        (Join-Path $ResolvedPairRoot "lanes\control\lane.json")
    )) {
        $laneJson = Read-JsonFile -Path $laneJsonPath
        $hasTuningProfile = $null -ne $laneJson -and $null -ne $laneJson.PSObject.Properties["tuning_profile"]
        if ($hasTuningProfile -and -not [string]::IsNullOrWhiteSpace([string]$laneJson.tuning_profile)) {
            return [string]$laneJson.tuning_profile
        }
    }

    $treatmentSummary = Read-LaneSummaryFile -Path (Join-Path $ResolvedPairRoot "lanes\treatment\summary.json")
    if ($null -ne $treatmentSummary -and -not [string]::IsNullOrWhiteSpace([string]$treatmentSummary.tuning_profile)) {
        return [string]$treatmentSummary.tuning_profile
    }

    return "conservative"
}

function Resolve-MonitorThresholds {
    param(
        [string]$ResolvedPairRoot,
        [int]$InputMinControlHumanSnapshots,
        [double]$InputMinControlHumanPresenceSeconds,
        [int]$InputMinTreatmentHumanSnapshots,
        [double]$InputMinTreatmentHumanPresenceSeconds,
        [int]$InputMinTreatmentPatchEventsWhileHumansPresent,
        [double]$InputMinPostPatchObservationSeconds,
        [string]$TreatmentProfileName
    )

    $pairSummary = Read-JsonFile -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    $controlSummary = Read-LaneSummaryFile -Path (Join-Path $ResolvedPairRoot "lanes\control\summary.json")
    $treatmentSummary = Read-LaneSummaryFile -Path (Join-Path $ResolvedPairRoot "lanes\treatment\summary.json")

    $profile = Get-TuningProfileDefinition -Name $TreatmentProfileName
    $defaultMinHumanSnapshots = [int]$profile.evaluation.min_human_snapshots
    $defaultMinHumanPresenceSeconds = [double]$profile.evaluation.min_human_presence_seconds
    $defaultMinPatchEvents = [int]$profile.evaluation.min_patch_events_for_usable_lane
    $defaultMinPostPatchObservationSeconds = 20.0

    $resolved = [ordered]@{
        MinControlHumanSnapshots = if ($InputMinControlHumanSnapshots -gt 0) {
            $InputMinControlHumanSnapshots
        } elseif ($null -ne $pairSummary -and [int]$pairSummary.min_human_snapshots -gt 0) {
            [int]$pairSummary.min_human_snapshots
        } elseif ($null -ne $controlSummary -and [int]$controlSummary.min_human_snapshots -gt 0) {
            [int]$controlSummary.min_human_snapshots
        } else {
            $defaultMinHumanSnapshots
        }
        MinControlHumanPresenceSeconds = if ($InputMinControlHumanPresenceSeconds -gt 0) {
            $InputMinControlHumanPresenceSeconds
        } elseif ($null -ne $pairSummary -and [double]$pairSummary.min_human_presence_seconds -gt 0) {
            [double]$pairSummary.min_human_presence_seconds
        } elseif ($null -ne $controlSummary -and [double]$controlSummary.min_human_presence_seconds -gt 0) {
            [double]$controlSummary.min_human_presence_seconds
        } else {
            $defaultMinHumanPresenceSeconds
        }
        MinTreatmentHumanSnapshots = if ($InputMinTreatmentHumanSnapshots -gt 0) {
            $InputMinTreatmentHumanSnapshots
        } elseif ($null -ne $pairSummary -and [int]$pairSummary.min_human_snapshots -gt 0) {
            [int]$pairSummary.min_human_snapshots
        } elseif ($null -ne $treatmentSummary -and [int]$treatmentSummary.min_human_snapshots -gt 0) {
            [int]$treatmentSummary.min_human_snapshots
        } else {
            $defaultMinHumanSnapshots
        }
        MinTreatmentHumanPresenceSeconds = if ($InputMinTreatmentHumanPresenceSeconds -gt 0) {
            $InputMinTreatmentHumanPresenceSeconds
        } elseif ($null -ne $pairSummary -and [double]$pairSummary.min_human_presence_seconds -gt 0) {
            [double]$pairSummary.min_human_presence_seconds
        } elseif ($null -ne $treatmentSummary -and [double]$treatmentSummary.min_human_presence_seconds -gt 0) {
            [double]$treatmentSummary.min_human_presence_seconds
        } else {
            $defaultMinHumanPresenceSeconds
        }
        MinTreatmentPatchEventsWhileHumansPresent = if ($InputMinTreatmentPatchEventsWhileHumansPresent -gt 0) {
            $InputMinTreatmentPatchEventsWhileHumansPresent
        } elseif ($null -ne $pairSummary -and [int]$pairSummary.min_patch_events_for_usable_lane -ge 0) {
            [int]$pairSummary.min_patch_events_for_usable_lane
        } elseif ($null -ne $treatmentSummary -and [int]$treatmentSummary.min_patch_events_for_usable_lane -ge 0) {
            [int]$treatmentSummary.min_patch_events_for_usable_lane
        } else {
            $defaultMinPatchEvents
        }
        MinPostPatchObservationSeconds = if ($InputMinPostPatchObservationSeconds -gt 0) {
            $InputMinPostPatchObservationSeconds
        } else {
            $defaultMinPostPatchObservationSeconds
        }
    }

    return [pscustomobject]$resolved
}

function Resolve-RuntimeDir {
    param(
        [string]$ResolvedPairRoot,
        [string]$FallbackLabRoot
    )

    foreach ($laneJsonPath in @(
        (Join-Path $ResolvedPairRoot "lanes\control\lane.json"),
        (Join-Path $ResolvedPairRoot "lanes\treatment\lane.json")
    )) {
        $laneJson = Read-JsonFile -Path $laneJsonPath
        $hasSourcePaths = $null -ne $laneJson -and $null -ne $laneJson.PSObject.Properties["source_paths"]
        if ($hasSourcePaths -and $null -ne $laneJson.source_paths.PSObject.Properties["runtime_dir"] -and -not [string]::IsNullOrWhiteSpace([string]$laneJson.source_paths.runtime_dir)) {
            $runtimeDir = Resolve-ExistingPath -Path ([string]$laneJson.source_paths.runtime_dir)
            if ($runtimeDir) {
                return $runtimeDir
            }
        }
    }

    $resolvedLabRoot = if ($FallbackLabRoot) { $FallbackLabRoot } else { Get-LabRootDefault }
    return Get-AiRuntimeDir -HldsRoot (Get-HldsRootDefault -LabRoot $resolvedLabRoot)
}

function Get-LiveMonitorMarkdown {
    param([object]$Status)

    $lines = @(
        "# Live Pair Monitor Status",
        "",
        "- Generated at (UTC): $($Status.generated_at_utc)",
        "- Pair root: $($Status.pair_root)",
        "- Phase: $($Status.phase)",
        "- Pair complete: $($Status.pair_complete)",
        "- Treatment profile: $($Status.treatment_profile)",
        "- Current verdict: $($Status.current_verdict)",
        "- Can stop now: $($Status.operator_can_stop_now)",
        "- Likely insufficient if stopped immediately: $($Status.likely_remains_insufficient_if_stopped_immediately)",
        "",
        "## Evidence Progress",
        "",
        "- Control human snapshots: $($Status.control_human_snapshots_count) / $($Status.thresholds.min_control_human_snapshots)",
        "- Control human presence seconds: $($Status.control_human_presence_seconds) / $($Status.thresholds.min_control_human_presence_seconds)",
        "- Treatment human snapshots: $($Status.treatment_human_snapshots_count) / $($Status.thresholds.min_treatment_human_snapshots)",
        "- Treatment human presence seconds: $($Status.treatment_human_presence_seconds) / $($Status.thresholds.min_treatment_human_presence_seconds)",
        "- Treatment patch events while humans present: $($Status.treatment_patch_events_while_humans_present) / $($Status.thresholds.min_treatment_patch_events_while_humans_present)",
        "- Meaningful post-patch observation seconds: $($Status.meaningful_post_patch_observation_seconds) / $($Status.thresholds.min_post_patch_observation_seconds)",
        "- Treatment response-after-patch windows: $($Status.treatment_response_after_patch_window_count)",
        "",
        "## Context",
        "",
        "- Control lane quality verdict: $($Status.control_lane_quality_verdict)",
        "- Treatment lane quality verdict: $($Status.treatment_lane_quality_verdict)",
        "- Comparison verdict: $($Status.comparison_verdict)",
        "- Explanation: $($Status.explanation)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-BlockedStatus {
    param(
        [string]$PairRootPath,
        [string]$Explanation
    )

    return [pscustomobject]@{
        schema_version = 1
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        pair_root = $PairRootPath
        phase = "blocked"
        pair_complete = $false
        comparison_available = $false
        treatment_profile = ""
        thresholds = [ordered]@{}
        control_human_snapshots_count = 0
        control_human_presence_seconds = 0.0
        treatment_human_snapshots_count = 0
        treatment_human_presence_seconds = 0.0
        treatment_patch_events_while_humans_present = 0
        meaningful_post_patch_observation_seconds = 0.0
        treatment_response_after_patch_window_count = 0
        current_verdict = "blocked-no-active-pair-run"
        explanation = $Explanation
        operator_can_stop_now = $false
        likely_remains_insufficient_if_stopped_immediately = $true
        control_lane_quality_verdict = ""
        treatment_lane_quality_verdict = ""
        comparison_verdict = ""
        comparison_explanation = ""
        artifacts = [ordered]@{}
    }
}

if ($PollSeconds -lt 1) {
    throw "PollSeconds must be at least 1."
}
if ($MaxMonitorSeconds -lt 0) {
    throw "MaxMonitorSeconds cannot be negative."
}

$resolvedPairsRoot = if ($PairsRoot) {
    $PairsRoot
} else {
    Get-PairsRootDefault -LabRoot $(if ($LabRoot) { $LabRoot } else { Get-LabRootDefault })
}

$shouldUseLatest = $UseLatest
if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    $shouldUseLatest = $true
}

$resolvedPairRoot = if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
    Resolve-ExistingPath -Path $PairRoot
} elseif ($shouldUseLatest) {
    Resolve-ExistingPath -Path (Find-LatestActivePairRoot -Root $resolvedPairsRoot)
} else {
    ""
}

if (-not $resolvedPairRoot) {
    $blockedStatus = New-BlockedStatus -PairRootPath "" -Explanation "No active pair run was found under $resolvedPairsRoot."
    Write-Host "Live pair monitor:"
    Write-Host "  Verdict: $($blockedStatus.current_verdict)"
    Write-Host "  Explanation: $($blockedStatus.explanation)"
    $blockedStatus
    return
}

$resolvedOutputRoot = if ($OutputRoot) {
    Ensure-Directory -Path $OutputRoot
} else {
    Ensure-Directory -Path $resolvedPairRoot
}

$statusJsonPath = Join-Path $resolvedOutputRoot "live_monitor_status.json"
$statusMarkdownPath = Join-Path $resolvedOutputRoot "live_monitor_status.md"
$treatmentProfileName = Get-TreatmentProfileHint -ResolvedPairRoot $resolvedPairRoot
$thresholds = Resolve-MonitorThresholds `
    -ResolvedPairRoot $resolvedPairRoot `
    -InputMinControlHumanSnapshots $MinControlHumanSnapshots `
    -InputMinControlHumanPresenceSeconds $MinControlHumanPresenceSeconds `
    -InputMinTreatmentHumanSnapshots $MinTreatmentHumanSnapshots `
    -InputMinTreatmentHumanPresenceSeconds $MinTreatmentHumanPresenceSeconds `
    -InputMinTreatmentPatchEventsWhileHumansPresent $MinTreatmentPatchEventsWhileHumansPresent `
    -InputMinPostPatchObservationSeconds $MinPostPatchObservationSeconds `
    -TreatmentProfileName $treatmentProfileName
$runtimeDir = Resolve-RuntimeDir -ResolvedPairRoot $resolvedPairRoot -FallbackLabRoot $LabRoot
$pythonExe = Get-PythonPath -PreferredPath $PythonPath
$monitorToolPath = Join-Path (Get-RepoRoot) "ai_director\tools\monitor_live_pair_status.py"
$promptId = Get-RepoPromptId
$startedAt = Get-Date
$lastPrintedKey = ""
$lastStatus = $null

Write-Host "Live pair monitor:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Runtime dir: $runtimeDir"
Write-Host "  Output JSON: $statusJsonPath"
Write-Host "  Output Markdown: $statusMarkdownPath"
Write-Host "  Poll seconds: $PollSeconds"
Write-Host "  Stop when sufficient: $StopWhenSufficient"
Write-Host "  Max monitor seconds: $MaxMonitorSeconds"

while ($true) {
    $args = @(
        $monitorToolPath
        "--pair-root", $resolvedPairRoot
        "--prompt-id", $promptId
        "--treatment-profile", $treatmentProfileName
        "--min-control-human-snapshots", [string]$thresholds.MinControlHumanSnapshots
        "--min-control-human-presence-seconds", [string]$thresholds.MinControlHumanPresenceSeconds
        "--min-treatment-human-snapshots", [string]$thresholds.MinTreatmentHumanSnapshots
        "--min-treatment-human-presence-seconds", [string]$thresholds.MinTreatmentHumanPresenceSeconds
        "--min-treatment-patch-events-while-humans-present", [string]$thresholds.MinTreatmentPatchEventsWhileHumansPresent
        "--min-post-patch-observation-seconds", [string]$thresholds.MinPostPatchObservationSeconds
    )
    if ($runtimeDir -and (Test-Path -LiteralPath $runtimeDir)) {
        $args += @("--runtime-dir", $runtimeDir)
    }

    $statusJsonText = & $pythonExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "Live monitor helper failed while evaluating $resolvedPairRoot"
    }

    $status = ($statusJsonText -join [Environment]::NewLine) | ConvertFrom-Json
    $elapsedSeconds = [int][Math]::Floor(((Get-Date) - $startedAt).TotalSeconds)

    if (
        $MaxMonitorSeconds -gt 0 -and
        $elapsedSeconds -ge $MaxMonitorSeconds -and
        [string]$status.current_verdict -notin @("sufficient-for-scorecard", "sufficient-for-tuning-usable-review")
    ) {
        $status.current_verdict = "insufficient-data-timeout"
        $status.explanation = "The live monitor timed out after $elapsedSeconds seconds before the grounded evidence gate cleared. $($status.explanation)"
        $status.operator_can_stop_now = $true
        $status.likely_remains_insufficient_if_stopped_immediately = $true
    }

    $markdown = Get-LiveMonitorMarkdown -Status $status
    Write-JsonFile -Path $statusJsonPath -Value $status
    Write-TextFile -Path $statusMarkdownPath -Value $markdown

    $printKey = @(
        [string]$status.current_verdict
        [string]$status.control_human_snapshots_count
        [string]$status.control_human_presence_seconds
        [string]$status.treatment_human_snapshots_count
        [string]$status.treatment_human_presence_seconds
        [string]$status.treatment_patch_events_while_humans_present
        [string]$status.meaningful_post_patch_observation_seconds
    ) -join "|"

    if ($printKey -ne $lastPrintedKey -or $Once) {
        Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $status.current_verdict)
        Write-Host "  Control human snapshots / seconds: $($status.control_human_snapshots_count) / $($status.control_human_presence_seconds)"
        Write-Host "  Treatment human snapshots / seconds: $($status.treatment_human_snapshots_count) / $($status.treatment_human_presence_seconds)"
        Write-Host "  Treatment patch events while humans present: $($status.treatment_patch_events_while_humans_present)"
        Write-Host "  Meaningful post-patch observation seconds: $($status.meaningful_post_patch_observation_seconds)"
        Write-Host "  Can stop now: $($status.operator_can_stop_now)"
        Write-Host "  Explanation: $($status.explanation)"
        $lastPrintedKey = $printKey
    }

    $lastStatus = $status

    if ($Once) {
        break
    }

    if ([string]$status.current_verdict -eq "blocked-no-active-pair-run") {
        break
    }

    if (
        $StopWhenSufficient -and
        [string]$status.current_verdict -in @("sufficient-for-scorecard", "sufficient-for-tuning-usable-review")
    ) {
        break
    }

    if ($MaxMonitorSeconds -gt 0 -and $elapsedSeconds -ge $MaxMonitorSeconds) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
}

$lastStatus
