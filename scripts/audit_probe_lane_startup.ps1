[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProbeRoot = "",
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

function Resolve-ProbeRoot {
    param(
        [string]$ExplicitProbeRoot,
        [switch]$PreferLatest,
        [string]$ResolvedLabRoot
    )

    $resolvedExplicit = Resolve-ExistingPath -Path $ExplicitProbeRoot
    if ($resolvedExplicit) {
        return $resolvedExplicit
    }

    if (-not $PreferLatest) {
        throw "A probe root is required. Pass -ProbeRoot or use -UseLatest."
    }

    return Find-LatestProbeRoot -EvalRoot (Get-EvalRootDefault -LabRoot $ResolvedLabRoot)
}

function Get-AuditMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Probe Lane Startup Audit") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Report.prompt_id)") | Out-Null
    $lines.Add("- Startup verdict: $($Report.startup_verdict)") | Out-Null
    $lines.Add("- Narrowest startup break point: $($Report.narrowest_startup_break_point)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Probe root: $($Report.probe_root)") | Out-Null
    $lines.Add("- Probe report: $($Report.probe_report_json)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Startup Observability") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe lane command: $($Report.startup_observability.probe_lane_command)") | Out-Null
    $lines.Add("- Probe lane output root: $($Report.startup_observability.probe_lane_output_root)") | Out-Null
    $lines.Add("- Expected lane root path: $($Report.startup_observability.expected_lane_root_path)") | Out-Null
    $lines.Add("- Expected lane root path length: $($Report.startup_observability.expected_lane_root_path_length)") | Out-Null
    $lines.Add("- Port: $($Report.startup_observability.port)") | Out-Null
    $lines.Add("- Probe lane launch attempted: $(Get-BoolString -Value ([bool]$Report.startup_observability.probe_lane_launch_attempted))") | Out-Null
    $lines.Add("- Lane root materialized: $(Get-BoolString -Value ([bool]$Report.startup_observability.lane_root_materialized))") | Out-Null
    $lines.Add("- Port ready: $(Get-BoolString -Value ([bool]$Report.startup_observability.port_ready))") | Out-Null
    $lines.Add("- Join helper invoked: $(Get-BoolString -Value ([bool]$Report.startup_observability.join_helper_invoked))") | Out-Null
    $lines.Add("- Join helper skipped reason: $($Report.startup_observability.join_helper_skipped_reason)") | Out-Null
    $lines.Add("- Resolve-Path missing-directory error detected: $(Get-BoolString -Value ([bool]$Report.startup_observability.resolve_path_missing_directory_error_detected))") | Out-Null
    $lines.Add("- Long path risk detected: $(Get-BoolString -Value ([bool]$Report.startup_observability.long_path_risk_detected))") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Stage Verdicts") | Out-Null
    $lines.Add("") | Out-Null

    foreach ($stage in @(
            $Report.stages.lane_launch_attempted,
            $Report.stages.lane_root_materialized,
            $Report.stages.port_ready,
            $Report.stages.join_invoked
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

    $lines.Add("## Logs") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Probe lane stdout log: $($Report.artifacts.probe_lane_stdout_log)") | Out-Null
    $lines.Add("- Probe lane stderr log: $($Report.artifacts.probe_lane_stderr_log)") | Out-Null
    $lines.Add("- Lane JSON: $($Report.artifacts.lane_json)") | Out-Null
    $lines.Add("- Lane summary JSON: $($Report.artifacts.lane_summary_json)") | Out-Null
    $lines.Add("- Session pack JSON: $($Report.artifacts.session_pack_json)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $LabRoot)
}

$resolvedProbeRoot = Resolve-ProbeRoot -ExplicitProbeRoot $ProbeRoot -PreferLatest:$UseLatest -ResolvedLabRoot $resolvedLabRoot
$probeReportPath = Resolve-ExistingPath -Path (Join-Path $resolvedProbeRoot "client_join_completion_probe.json")
$probeReport = Read-JsonFile -Path $probeReportPath
if ($null -eq $probeReport) {
    throw "Probe root does not contain a readable client_join_completion_probe.json: $resolvedProbeRoot"
}

$artifacts = Get-ObjectPropertyValue -Object $probeReport -Name "artifacts" -Default $null
$launchObservability = Get-ObjectPropertyValue -Object $probeReport -Name "launch_observability" -Default $null
$readinessObservability = Get-ObjectPropertyValue -Object $probeReport -Name "readiness_observability" -Default $null
$probeLane = Get-ObjectPropertyValue -Object $probeReport -Name "probe_lane" -Default $null

$probeStdoutLog = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "probe_lane_stdout_log" -Default ""))
$probeStderrLog = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "probe_lane_stderr_log" -Default ""))
$laneOutputRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchObservability -Name "probe_lane_output_root" -Default ""))
$laneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $readinessObservability -Name "lane_root" -Default ""))
if (-not $laneRoot) {
    $laneRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $probeReport -Name "lane_root" -Default ""))
}

$stderrText = if ($probeStderrLog) { Get-Content -LiteralPath $probeStderrLog -Raw } else { "" }
$stdoutText = if ($probeStdoutLog) { Get-Content -LiteralPath $probeStdoutLog -Raw } else { "" }
$expectedLaneRootFromError = ""
if ($stderrText -match "Cannot find path '([^']+)'") {
    $expectedLaneRootFromError = [string]$Matches[1]
}

$expectedLaneRootPath = if ($expectedLaneRootFromError) {
    $expectedLaneRootFromError
}
elseif ($laneRoot) {
    $laneRoot
}
else {
    ""
}

$probeLaneLaunchAttempted = [bool](Get-ObjectPropertyValue -Object $launchObservability -Name "probe_lane_launch_attempted" -Default ($null -ne (Get-ObjectPropertyValue -Object $launchObservability -Name "probe_lane_process_id" -Default $null)))
$portReady = [bool](Get-ObjectPropertyValue -Object $readinessObservability -Name "port_ready" -Default (Get-ObjectPropertyValue -Object $probeLane -Name "port_ready" -Default $false))
$laneRootMaterialized = [bool](Get-ObjectPropertyValue -Object $readinessObservability -Name "lane_root_materialized" -Default (Get-ObjectPropertyValue -Object $probeLane -Name "lane_root_ready" -Default $false))
$joinHelperInvoked = [bool](Get-ObjectPropertyValue -Object $readinessObservability -Name "join_helper_invoked" -Default (Get-ObjectPropertyValue -Object $launchObservability -Name "control_join_attempted" -Default $false))
$joinHelperSkippedReason = [string](Get-ObjectPropertyValue -Object $readinessObservability -Name "join_helper_skipped_reason" -Default "")
$resolvePathMissingDirectoryErrorDetected = $stderrText -match "Resolve-Path : Cannot find path"
$longPathRiskDetected = (-not [string]::IsNullOrWhiteSpace($expectedLaneRootPath)) -and ($expectedLaneRootPath.Length -gt 259)

$laneJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "lane_json" -Default ""))
$laneSummaryPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "lane_summary_json" -Default ""))
$sessionPackPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifacts -Name "session_pack_json" -Default ""))

$laneLaunchStage = Get-StageRecord `
    -StageName "lane-launch-attempted" `
    -Verdict $(if ($probeLaneLaunchAttempted) { "lane-launch-attempted" } else { "lane-launch-not-attempted" }) `
    -Reached $probeLaneLaunchAttempted `
    -EvidenceFound $(if ($probeLaneLaunchAttempted) {
            @(
                ("probe lane command: {0}" -f [string](Get-ObjectPropertyValue -Object $launchObservability -Name "probe_lane_command" -Default "")),
                ("probe lane output root: {0}" -f $laneOutputRoot)
            )
        } else { @() }) `
    -EvidenceMissing $(if ($probeLaneLaunchAttempted) { @() } else { @("probe lane launch command or process evidence") }) `
    -Explanation $(if ($probeLaneLaunchAttempted) {
            "The bounded probe did start the control-lane launcher path."
        } else {
            "The saved probe root does not show a control-lane startup attempt."
        })

$laneRootStage = Get-StageRecord `
    -StageName "lane-root-materialized" `
    -Verdict $(if ($laneRootMaterialized) { "lane-root-created" } elseif ($probeLaneLaunchAttempted) { "lane-launch-attempted-no-root" } else { "lane-launch-not-attempted" }) `
    -Reached $laneRootMaterialized `
    -EvidenceFound $(if ($laneRootMaterialized) {
            @(
                ("lane root: {0}" -f $laneRoot),
                ("lane json: {0}" -f $laneJsonPath)
            )
        } else {
            @(
                ("expected lane root path: {0}" -f $expectedLaneRootPath),
                ("expected lane root path length: {0}" -f $expectedLaneRootPath.Length)
            ) | Where-Object { $_ -notmatch ': $' }
        }) `
    -EvidenceMissing $(if ($laneRootMaterialized) { @() } else { @("materialized lane root directory under the probe lane output root") }) `
    -Explanation $(if ($laneRootMaterialized) {
            "The probe lane created a real lane root under the capture output root."
        } elseif ($longPathRiskDetected) {
            "The probe lane never materialized its lane root, and the missing path captured in stderr exceeds a practical MAX_PATH boundary."
        } else {
            "The probe lane launch was attempted, but no lane root was materialized."
        })

$portReadyStage = Get-StageRecord `
    -StageName "port-ready" `
    -Verdict $(if ($portReady) { "port-ready" } elseif ($laneRootMaterialized) { "lane-root-created-no-port-ready" } elseif ($probeLaneLaunchAttempted) { "lane-launch-attempted-no-root" } else { "lane-launch-not-attempted" }) `
    -Reached $portReady `
    -EvidenceFound $(if ($portReady) {
            @("probe lane became port-ready before the join helper gate")
        } else { @() }) `
    -EvidenceMissing $(if ($portReady) { @() } else { @("port-ready signal for the bounded control lane") }) `
    -Explanation $(if ($portReady) {
            "The bounded control lane became ready on the target port."
        } elseif ($laneRootMaterialized) {
            "The lane root exists, but the bounded control lane still never became port-ready."
        } else {
            "Port readiness never had a chance to clear because the probe lane startup stalled earlier."
        })

$joinInvokedStage = Get-StageRecord `
    -StageName "join-invoked" `
    -Verdict $(if ($joinHelperInvoked) { "join-invoked" } elseif ($portReady) { "port-ready-no-join-invocation" } else { "startup-inconclusive" }) `
    -Reached $joinHelperInvoked `
    -EvidenceFound $(if ($joinHelperInvoked) {
            @(
                ("join helper invoked: yes"),
                ("join helper result verdict: {0}" -f [string](Get-ObjectPropertyValue -Object $launchObservability -Name "control_join_helper_result_verdict" -Default ""))
            )
        } else { @() }) `
    -EvidenceMissing $(if ($joinHelperInvoked) { @() } else { @("join helper invocation after startup became ready") }) `
    -Explanation $(if ($joinHelperInvoked) {
            "The saved probe root shows that startup progressed far enough to invoke join_live_pair_lane.ps1."
        } elseif ($portReady) {
            "The port became ready, but the join helper still was not invoked."
        } else {
            "The join helper was skipped because startup never reached the ready gate."
        })

$startupVerdict = if (-not $probeLaneLaunchAttempted) {
    "lane-launch-not-attempted"
}
elseif (-not $laneRootMaterialized) {
    "lane-launch-attempted-no-root"
}
elseif (-not $portReady) {
    "lane-root-created-no-port-ready"
}
elseif (-not $joinHelperInvoked) {
    "port-ready-no-join-invocation"
}
elseif ($joinHelperInvoked) {
    "join-invoked"
}
else {
    "startup-inconclusive"
}

$narrowestBreakPoint = switch ($startupVerdict) {
    "lane-launch-not-attempted" { "The bounded control-lane startup was never attempted." }
    "lane-launch-attempted-no-root" {
        if ($longPathRiskDetected) {
            "The bounded control-lane startup was attempted, but the lane root never materialized. The saved stderr points at a missing lane root path length of $($expectedLaneRootPath.Length), which is consistent with path-depth startup failure."
        }
        else {
            "The bounded control-lane startup was attempted, but no lane root was ever materialized."
        }
    }
    "lane-root-created-no-port-ready" { "The lane root exists, but the bounded control lane still never became port-ready." }
    "port-ready-no-join-invocation" { "The control lane became port-ready, but the join helper still was not invoked." }
    "join-invoked" { "Startup progressed far enough to invoke the join helper." }
    default { "The probe startup still needs manual review." }
}

$overallExplanation = switch ($startupVerdict) {
    "lane-launch-attempted-no-root" {
        if ($longPathRiskDetected) {
            "The saved bounded probe did start the control-lane launch command, but startup never materialized a lane root. The stderr trail shows a missing lane-root path at length $($expectedLaneRootPath.Length), so the narrowest confirmed blocker is path-depth startup failure before port readiness."
        }
        else {
            "The saved bounded probe started the control-lane launch command, but startup still failed before lane-root materialization."
        }
    }
    "lane-root-created-no-port-ready" {
        "The saved bounded probe got far enough to create a lane root, but startup still never became ready on the target port."
    }
    "port-ready-no-join-invocation" {
        "The saved bounded probe reached port readiness but still did not invoke the join helper."
    }
    "join-invoked" {
        "The saved bounded probe startup path is healthy enough to invoke the join helper."
    }
    "lane-launch-not-attempted" {
        "The saved probe root does not show a bounded control-lane startup attempt."
    }
    default {
        "The saved probe startup path still needs manual review."
    }
}

$auditJsonPath = Join-Path $resolvedProbeRoot "probe_lane_startup_audit.json"
$auditMarkdownPath = Join-Path $resolvedProbeRoot "probe_lane_startup_audit.md"

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    probe_root = $resolvedProbeRoot
    probe_report_json = $probeReportPath
    startup_verdict = $startupVerdict
    narrowest_startup_break_point = $narrowestBreakPoint
    explanation = $overallExplanation
    startup_observability = [ordered]@{
        probe_lane_command = [string](Get-ObjectPropertyValue -Object $launchObservability -Name "probe_lane_command" -Default "")
        probe_lane_output_root = $laneOutputRoot
        expected_lane_root_path = $expectedLaneRootPath
        expected_lane_root_path_length = if ($expectedLaneRootPath) { $expectedLaneRootPath.Length } else { 0 }
        port = [int](Get-ObjectPropertyValue -Object $probeReport -Name "port" -Default 0)
        probe_lane_launch_attempted = $probeLaneLaunchAttempted
        lane_root_materialized = $laneRootMaterialized
        port_ready = $portReady
        join_helper_invoked = $joinHelperInvoked
        join_helper_skipped_reason = $joinHelperSkippedReason
        probe_started_at_utc = [string](Get-ObjectPropertyValue -Object $readinessObservability -Name "probe_started_at_utc" -Default "")
        port_wait_finished_at_utc = [string](Get-ObjectPropertyValue -Object $readinessObservability -Name "port_wait_finished_at_utc" -Default "")
        lane_root_wait_finished_at_utc = [string](Get-ObjectPropertyValue -Object $readinessObservability -Name "lane_root_wait_finished_at_utc" -Default "")
        resolve_path_missing_directory_error_detected = $resolvePathMissingDirectoryErrorDetected
        long_path_risk_detected = $longPathRiskDetected
    }
    stages = [ordered]@{
        lane_launch_attempted = $laneLaunchStage
        lane_root_materialized = $laneRootStage
        port_ready = $portReadyStage
        join_invoked = $joinInvokedStage
    }
    artifacts = [ordered]@{
        probe_lane_stdout_log = $probeStdoutLog
        probe_lane_stderr_log = $probeStderrLog
        lane_json = $laneJsonPath
        lane_summary_json = $laneSummaryPath
        session_pack_json = $sessionPackPath
        probe_lane_startup_audit_json = $auditJsonPath
        probe_lane_startup_audit_markdown = $auditMarkdownPath
    }
}

Write-JsonFile -Path $auditJsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $auditJsonPath
Write-TextFile -Path $auditMarkdownPath -Value (Get-AuditMarkdown -Report $reportForMarkdown)

Write-Host "Probe lane startup audit:"
Write-Host "  Startup verdict: $($report.startup_verdict)"
Write-Host "  Narrowest startup break point: $($report.narrowest_startup_break_point)"
Write-Host "  Probe root: $resolvedProbeRoot"
Write-Host "  JSON: $auditJsonPath"
Write-Host "  Markdown: $auditMarkdownPath"

[pscustomobject]@{
    ProbeLaneStartupAuditJsonPath = $auditJsonPath
    ProbeLaneStartupAuditMarkdownPath = $auditMarkdownPath
    ProbeRoot = $resolvedProbeRoot
    StartupVerdict = $report.startup_verdict
    NarrowestStartupBreakPoint = $report.narrowest_startup_break_point
}
