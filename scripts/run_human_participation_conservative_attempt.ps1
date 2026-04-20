[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$ClientExePath = "",
    [ValidateSet("ControlThenTreatment", "ControlOnly", "TreatmentOnly", "ManualOnly")]
    [string]$JoinSequence = "ControlThenTreatment",
    [switch]$AutoJoinControl,
    [switch]$AutoJoinTreatment,
    [int]$ControlJoinDelaySeconds = 5,
    [int]$TreatmentJoinDelaySeconds = 5,
    [int]$ControlStaySeconds = -1,
    [int]$TreatmentStaySeconds = -1
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

    $json = $Value | ConvertTo-Json -Depth 24
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

function Resolve-MissionArtifacts {
    param(
        [string]$ExplicitMissionPath,
        [string]$ExplicitMissionMarkdownPath,
        [string]$ResolvedLabRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $resolvedMissionPath = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionPath)
        if (-not $resolvedMissionPath) {
            throw "Mission JSON was not found: $ExplicitMissionPath"
        }

        $resolvedMissionMarkdownPath = if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionMarkdownPath)) {
            Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionMarkdownPath)
        }
        else {
            Resolve-ExistingPath -Path ([System.IO.Path]::ChangeExtension($resolvedMissionPath, ".md"))
        }

        return [pscustomobject]@{
            JsonPath = $resolvedMissionPath
            MarkdownPath = $resolvedMissionMarkdownPath
        }
    }

    $prepareScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"
    $preparedMission = & $prepareScriptPath -LabRoot $ResolvedLabRoot
    $resolvedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionJsonPath" -Default ""))
    $resolvedMissionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionMarkdownPath" -Default ""))
    if (-not $resolvedMissionPath) {
        throw "The current mission brief could not be prepared."
    }

    return [pscustomobject]@{
        JsonPath = $resolvedMissionPath
        MarkdownPath = $resolvedMissionMarkdownPath
    }
}

function Find-NewPairRoot {
    param(
        [string]$Root,
        [datetime]$NotBeforeUtc
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTimeUtc -ge $NotBeforeUtc.AddMinutes(-1) -and (
                (Test-Path -LiteralPath (Join-Path $_.FullName "control_join_instructions.txt")) -or
                (Test-Path -LiteralPath (Join-Path $_.FullName "pair_join_instructions.txt")) -or
                (Test-Path -LiteralPath (Join-Path $_.FullName "guided_session"))
            )
        } |
        Sort-Object LastWriteTimeUtc -Descending

    $candidate = $candidates | Select-Object -First 1
    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Wait-ForPairRoot {
    param(
        [string]$Root,
        [datetime]$NotBeforeUtc,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$TimeoutSeconds = 180
    )

    $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        $pairRoot = Find-NewPairRoot -Root $Root -NotBeforeUtc $NotBeforeUtc
        if ($pairRoot) {
            return $pairRoot
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    break
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds 2
    }

    return Find-NewPairRoot -Root $Root -NotBeforeUtc $NotBeforeUtc
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
        [string]$Label,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$TimeoutSeconds = 180
    )

    $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        if (Test-LocalPortActive -Port $Port) {
            return [pscustomobject]@{
                Ready = $true
                Explanation = "Detected an active listener on port $Port for the $Label lane."
            }
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    return [pscustomobject]@{
                        Ready = $false
                        Explanation = "The background conservative attempt exited before port $Port became active for the $Label lane."
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
        Explanation = "Timed out waiting for port $Port to become active for the $Label lane."
    }
}

function Stop-ClientProcessIfRunning {
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
        Write-Host "  Stopped client PID $ProcessId ($Reason)."
        return $true
    }
    catch {
        Write-Warning "Could not stop client PID $ProcessId ($Reason): $($_.Exception.Message)"
        return $false
    }
}

function Invoke-LaneJoinHelper {
    param(
        [string]$Lane,
        [string]$PairRoot,
        [string]$ResolvedClientExePath,
        [int]$Port,
        [string]$Map
    )

    $joinScriptPath = Join-Path $PSScriptRoot "join_live_pair_lane.ps1"
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\join_live_pair_lane.ps1",
        "-Lane",
        $Lane
    )
    $joinArgs = [ordered]@{
        Lane = $Lane
    }

    $pairSummaryPath = if ($PairRoot) { Join-Path $PairRoot "pair_summary.json" } else { "" }
    if ($pairSummaryPath -and (Test-Path -LiteralPath $pairSummaryPath)) {
        $commandParts += @("-PairRoot", $PairRoot)
        $joinArgs.PairRoot = $PairRoot
    }
    else {
        $commandParts += @("-Port", [string]$Port, "-Map", $Map)
        $joinArgs.Port = $Port
        $joinArgs.Map = $Map
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedClientExePath)) {
        $commandParts += @("-ClientExePath", $ResolvedClientExePath)
        $joinArgs.ClientExePath = $ResolvedClientExePath
    }

    $commandText = @($commandParts | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "

    try {
        $result = & $joinScriptPath @joinArgs
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = ""
            Result = $result
        }
    }
    catch {
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = $_.Exception.Message
            Result = $null
        }
    }
}

function Get-ReportPaths {
    param(
        [string]$PairRoot,
        [string]$ResolvedRegistryRoot,
        [string]$Stamp
    )

    if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
        return [ordered]@{
            JsonPath = Join-Path $PairRoot "human_participation_conservative_attempt.json"
            MarkdownPath = Join-Path $PairRoot "human_participation_conservative_attempt.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedRegistryRoot "human_participation_conservative_attempt")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot ("attempt-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $fallbackRoot ("attempt-{0}.md" -f $Stamp)
    }
}

function Get-DiscoverySourceName {
    param([object]$DiscoveryReport)

    $checked = @($DiscoveryReport.discovery_sources_checked)
    foreach ($source in $checked) {
        if ([bool](Get-ObjectPropertyValue -Object $source -Name "exists" -Default $false)) {
            return [string](Get-ObjectPropertyValue -Object $source -Name "source_name" -Default "")
        }
    }

    return ""
}

function Get-HumanAttemptVerdict {
    param(
        [bool]$ClientLaunchable,
        [bool]$ManualReviewRequired,
        [bool]$CountsTowardPromotion,
        [bool]$CreatedFirstGroundedConservativeSession,
        [bool]$ReducedPromotionGap,
        [bool]$InterruptedAndRecovered,
        [bool]$ControlHumanSignal,
        [bool]$TreatmentHumanSignal,
        [string]$JoinSequence,
        [string]$MissionVerdict
    )

    if (-not $ClientLaunchable) {
        return "no-client-available"
    }

    if ($ManualReviewRequired) {
        return "manual-review-required"
    }

    if ($CountsTowardPromotion -and $CreatedFirstGroundedConservativeSession) {
        return "conservative-session-grounded-first-capture"
    }

    if ($CountsTowardPromotion -and $ReducedPromotionGap) {
        return "conservative-session-grounded-gap-reduced"
    }

    if ($InterruptedAndRecovered) {
        return "conservative-session-interrupted-and-recovered"
    }

    if (-not $ControlHumanSignal -and -not $TreatmentHumanSignal) {
        return "client-launchable-but-no-meaningful-human-signal"
    }

    if ($ControlHumanSignal -and -not $TreatmentHumanSignal) {
        return "control-only-human-signal"
    }

    if (-not $ControlHumanSignal -and $TreatmentHumanSignal) {
        return "treatment-only-human-signal"
    }

    if ($ControlHumanSignal -and $TreatmentHumanSignal -and $JoinSequence -eq "ControlThenTreatment") {
        return "sequential-human-signal-insufficient"
    }

    if ($MissionVerdict -eq "mission-failed-insufficient-signal") {
        return "conservative-session-insufficient-human-signal"
    }

    return "conservative-session-insufficient-human-signal"
}

function Get-HumanAttemptExplanation {
    param(
        [string]$AttemptVerdict,
        [object]$DiscoveryReport,
        [object]$FirstAttemptReport,
        [object]$MissionAttainment,
        [object]$PairSummary,
        [string[]]$MissingTargetDetails
    )

    $firstAttemptExplanation = [string](Get-ObjectPropertyValue -Object $FirstAttemptReport -Name "explanation" -Default "")
    $missionExplanation = [string](Get-ObjectPropertyValue -Object $MissionAttainment -Name "explanation" -Default "")
    $controlLane = Get-ObjectPropertyValue -Object $PairSummary -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null
    $controlSeconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0.0)
    $treatmentSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)

    switch ($AttemptVerdict) {
        "no-client-available" {
            return "The local Half-Life client could not be discovered for automatic lane joins. {0}" -f [string](Get-ObjectPropertyValue -Object $DiscoveryReport -Name "explanation" -Default "")
        }
        "conservative-session-grounded-first-capture" {
            return "The local client joined both lanes sequentially, both lanes cleared the grounded human-signal threshold, treatment patched while humans were present, and the pair became the first certified grounded conservative session."
        }
        "conservative-session-grounded-gap-reduced" {
            return "The local client produced grounded human participation and the resulting pair counted toward promotion, reducing the conservative evidence gap."
        }
        "conservative-session-interrupted-and-recovered" {
            return $firstAttemptExplanation
        }
        "client-launchable-but-no-meaningful-human-signal" {
            return "The local client was launchable, but the saved pair evidence still shows no human presence in either lane. {0}" -f $missionExplanation
        }
        "control-only-human-signal" {
            return "The local client produced human signal only in the control lane ({0:0.#}s). The treatment lane still missed grounded human participation. {1}" -f $controlSeconds, $missionExplanation
        }
        "treatment-only-human-signal" {
            return "The local client produced human signal only in the treatment lane ({0:0.#}s). The control baseline still missed grounded human participation. {1}" -f $treatmentSeconds, $missionExplanation
        }
        "sequential-human-signal-insufficient" {
            if ($MissingTargetDetails.Count -gt 0) {
                return "Sequential control-then-treatment participation was observed, but the run still missed grounded conservative criteria: {0}" -f ($MissingTargetDetails -join " ")
            }

            return $missionExplanation
        }
        "manual-review-required" {
            if (-not [string]::IsNullOrWhiteSpace($firstAttemptExplanation)) {
                return $firstAttemptExplanation
            }

            return "The client-assisted attempt needs manual review before any grounded conservative claim can be made."
        }
        default {
            if ($MissingTargetDetails.Count -gt 0) {
                return "The client-assisted attempt stayed non-grounded because it still missed: {0}" -f ($MissingTargetDetails -join " ")
            }

            if (-not [string]::IsNullOrWhiteSpace($missionExplanation)) {
                return $missionExplanation
            }

            return $firstAttemptExplanation
        }
    }
}

function Get-HumanAttemptMarkdown {
    param([object]$Report)

    $missingTargets = @($Report.human_signal.missing_grounding_target_details)
    $lines = @(
        "# Human Participation Conservative Attempt",
        "",
        "- Attempt verdict: $($Report.attempt_verdict)",
        "- Explanation: $($Report.explanation)",
        "- Mission path used: $($Report.mission_path_used)",
        "- Mission execution path: $($Report.mission_execution_path)",
        "- Pair root: $($Report.pair_root)",
        "- First-grounded helper verdict: $($Report.first_grounded_attempt_verdict)",
        "- Client discovery verdict: $($Report.client_discovery.discovery_verdict)",
        "- Client path used: $($Report.client_discovery.client_path_used)",
        "- Client path source: $($Report.client_discovery.client_path_source)",
        "- Sequential participation: $($Report.participation.sequential)",
        "- Overlapping participation: $($Report.participation.overlapping)",
        "",
        "## Lane Participation",
        "",
        "- Control attempted: $($Report.control_lane_join.attempted)",
        "- Control helper command: $($Report.control_lane_join.helper_command)",
        "- Control launch command: $($Report.control_lane_join.launch_command)",
        "- Control join succeeded: $($Report.control_lane_join.join_succeeded)",
        "- Control human snapshots: $($Report.control_lane_join.human_snapshots_count)",
        "- Control human seconds: $($Report.control_lane_join.seconds_with_human_presence)",
        "- Treatment attempted: $($Report.treatment_lane_join.attempted)",
        "- Treatment helper command: $($Report.treatment_lane_join.helper_command)",
        "- Treatment launch command: $($Report.treatment_lane_join.launch_command)",
        "- Treatment join succeeded: $($Report.treatment_lane_join.join_succeeded)",
        "- Treatment human snapshots: $($Report.treatment_lane_join.human_snapshots_count)",
        "- Treatment human seconds: $($Report.treatment_lane_join.seconds_with_human_presence)",
        "",
        "## Evidence Result",
        "",
        "- Control lane verdict: $($Report.control_lane_verdict)",
        "- Treatment lane verdict: $($Report.treatment_lane_verdict)",
        "- Pair classification: $($Report.pair_classification)",
        "- Certification verdict: $($Report.certification_verdict)",
        "- Counts toward promotion: $($Report.counts_toward_promotion)",
        "- Became first grounded conservative session: $($Report.became_first_grounded_conservative_session)",
        "- Reduced promotion gap: $($Report.reduced_promotion_gap)",
        "- Mission attainment verdict: $($Report.mission_attainment_verdict)",
        "- Monitor verdict: $($Report.monitor_verdict)",
        "- Final recovery verdict: $($Report.final_recovery_verdict)",
        "",
        "## Grounding Gaps",
        "",
        "- Treatment patched while humans present: $($Report.human_signal.treatment_patched_while_humans_present)",
        "- Meaningful post-patch observation window exists: $($Report.human_signal.meaningful_post_patch_observation_window_exists)",
        "- Minimum human signal thresholds met: $($Report.human_signal.minimum_human_signal_thresholds_met)"
    )

    if ($missingTargets.Count -gt 0) {
        $lines += ""
        $lines += "### Missing Target Details"
        $lines += ""
        foreach ($item in $missingTargets) {
            $lines += "- $item"
        }
    }

    $lines += @(
        "",
        "## Artifacts",
        "",
        "- Discovery JSON: $($Report.artifacts.local_client_discovery_json)",
        "- First grounded attempt JSON: $($Report.artifacts.first_grounded_conservative_attempt_json)",
        "- Pair summary JSON: $($Report.artifacts.pair_summary_json)",
        "- Grounded evidence certificate JSON: $($Report.artifacts.grounded_evidence_certificate_json)",
        "- Session outcome dossier JSON: $($Report.artifacts.session_outcome_dossier_json)",
        "- Mission attainment JSON: $($Report.artifacts.mission_attainment_json)",
        "- Final session docket JSON: $($Report.artifacts.final_session_docket_json)",
        "- Attempt stdout log: $($Report.artifacts.attempt_stdout_log)",
        "- Attempt stderr log: $($Report.artifacts.attempt_stderr_log)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot }
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "human_participation_live")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
$resolvedRegistryRoot = Get-RegistryRootDefault -LabRoot $resolvedLabRoot
$attemptStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$attemptStartUtc = (Get-Date).ToUniversalTime()
$attemptStdoutLog = Join-Path $resolvedOutputRoot ("human_participation_attempt-{0}.stdout.log" -f $attemptStamp)
$attemptStderrLog = Join-Path $resolvedOutputRoot ("human_participation_attempt-{0}.stderr.log" -f $attemptStamp)
$discoveryScriptPath = Join-Path $PSScriptRoot "discover_hldm_client.ps1"
$firstAttemptScriptPath = Join-Path $PSScriptRoot "run_first_grounded_conservative_attempt.ps1"
$missionArtifacts = Resolve-MissionArtifacts -ExplicitMissionPath $MissionPath -ExplicitMissionMarkdownPath $MissionMarkdownPath -ResolvedLabRoot $resolvedLabRoot
$mission = Read-JsonFile -Path $missionArtifacts.JsonPath
if ($null -eq $mission) {
    throw "Mission JSON could not be read: $($missionArtifacts.JsonPath)"
}

$controlPresenceTarget = [int][Math]::Ceiling([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_presence_seconds" -Default 60.0))
$treatmentPresenceTarget = [int][Math]::Ceiling([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_presence_seconds" -Default 60.0))
if ($ControlStaySeconds -lt 1) {
    $ControlStaySeconds = [Math]::Max(15, $controlPresenceTarget + 10)
}
if ($TreatmentStaySeconds -lt 1) {
    $TreatmentStaySeconds = [Math]::Max(15, $treatmentPresenceTarget + 10)
}

$controlPort = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "control_lane_configuration" -Default $null) -Name "port" -Default 27016)
$treatmentPort = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "treatment_lane_configuration" -Default $null) -Name "port" -Default 27017)
$missionMap = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "live_session_run_shape" -Default $null) -Name "map" -Default "crossfire")

$autoJoinControlEnabled = if ($PSBoundParameters.ContainsKey("AutoJoinControl")) {
    [bool]$AutoJoinControl
}
else {
    $JoinSequence -in @("ControlThenTreatment", "ControlOnly")
}
$autoJoinTreatmentEnabled = if ($PSBoundParameters.ContainsKey("AutoJoinTreatment")) {
    [bool]$AutoJoinTreatment
}
else {
    $JoinSequence -in @("ControlThenTreatment", "TreatmentOnly")
}

$discoveryResult = & $discoveryScriptPath -ClientExePath $ClientExePath -LabRoot $resolvedLabRoot
$discoveryReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $discoveryResult -Name "LocalClientDiscoveryJsonPath" -Default ""))
$discoveryReportMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $discoveryResult -Name "LocalClientDiscoveryMarkdownPath" -Default ""))
$discoveryReport = Read-JsonFile -Path $discoveryReportJsonPath
if ($null -eq $discoveryReport) {
    throw "Local client discovery did not produce a readable discovery report."
}

$resolvedClientExePath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $discoveryReport -Name "client_path" -Default ""))
$clientLaunchable = [bool](Get-ObjectPropertyValue -Object $discoveryReport -Name "launchable_for_local_lane_join" -Default $false)
$clientPathSource = Get-DiscoverySourceName -DiscoveryReport $discoveryReport

$attemptProcess = $null
$pairRoot = ""
$firstAttemptResult = $null
$firstAttemptJsonPath = ""
$firstAttemptMarkdownPath = ""
$firstAttemptReport = $null
$pairSummary = $null
$certificate = $null
$missionAttainment = $null
$finalDocket = $null
$controlJoinExecution = $null
$treatmentJoinExecution = $null
$controlProcessId = 0
$treatmentProcessId = 0
$launchBlockedReason = ""

if (-not $clientLaunchable) {
    $launchBlockedReason = [string](Get-ObjectPropertyValue -Object $discoveryReport -Name "explanation" -Default "")
}
else {
    $attemptCommandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $firstAttemptScriptPath,
        "-LabRoot",
        $resolvedLabRoot,
        "-OutputRoot",
        $resolvedOutputRoot
    )

    if ($missionArtifacts.JsonPath) {
        $attemptCommandParts += @("-MissionPath", $missionArtifacts.JsonPath)
    }
    if ($missionArtifacts.MarkdownPath) {
        $attemptCommandParts += @("-MissionMarkdownPath", $missionArtifacts.MarkdownPath)
    }

    try {
        $attemptProcess = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $attemptCommandParts[1..($attemptCommandParts.Count - 1)] `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $attemptStdoutLog `
            -RedirectStandardError $attemptStderrLog `
            -PassThru

        Write-Host "Human-participation conservative attempt:"
        Write-Host "  Mission path: $($missionArtifacts.JsonPath)"
        Write-Host "  Output root: $resolvedOutputRoot"
        Write-Host "  Background first-grounded helper PID: $($attemptProcess.Id)"
        Write-Host "  Local client discovery: $($discoveryReport.discovery_verdict)"
        Write-Host "  Client path: $resolvedClientExePath"
    }
    catch {
        $launchBlockedReason = "Could not start the first-grounded helper in the background: $($_.Exception.Message)"
    }
}

if ($attemptProcess) {
    $pairRoot = Wait-ForPairRoot -Root $resolvedOutputRoot -NotBeforeUtc $attemptStartUtc -AttemptProcess $attemptProcess -TimeoutSeconds 240
    if ($pairRoot) {
        Write-Host "  Pair root discovered: $pairRoot"
    }
    else {
        Write-Warning "The pair root was not discovered before the background attempt exited or timed out."
    }

    if ($pairRoot -and $autoJoinControlEnabled) {
        if ($ControlJoinDelaySeconds -gt 0) {
            Start-Sleep -Seconds $ControlJoinDelaySeconds
        }

        $controlPortWait = Wait-ForPortActive -Port $controlPort -Label "control" -AttemptProcess $attemptProcess -TimeoutSeconds 180
        Write-Host "  Control lane port wait: $($controlPortWait.Explanation)"
        if ($controlPortWait.Ready) {
            $controlJoinExecution = Invoke-LaneJoinHelper -Lane "Control" -PairRoot $pairRoot -ResolvedClientExePath $resolvedClientExePath -Port $controlPort -Map $missionMap
            if ($controlJoinExecution.Result) {
                $controlProcessId = [int](Get-ObjectPropertyValue -Object $controlJoinExecution.Result -Name "ProcessId" -Default 0)
                $controlJoinVerdict = [string](Get-ObjectPropertyValue -Object $controlJoinExecution.Result -Name "ResultVerdict" -Default "")
                Write-Host "  Control lane join helper verdict: $controlJoinVerdict"
            }
            elseif ($controlJoinExecution.Error) {
                Write-Warning "Control lane join failed: $($controlJoinExecution.Error)"
            }

            if ($controlProcessId -gt 0 -and $ControlStaySeconds -gt 0) {
                Start-Sleep -Seconds $ControlStaySeconds
                Stop-ClientProcessIfRunning -ProcessId $controlProcessId -Reason "control lane stay complete" | Out-Null
            }
        }
        else {
            $controlJoinExecution = [pscustomobject]@{
                Attempted = $true
                CommandText = ""
                Error = $controlPortWait.Explanation
                Result = $null
            }
        }
    }

    if ($pairRoot -and $autoJoinTreatmentEnabled) {
        if ($TreatmentJoinDelaySeconds -gt 0) {
            Start-Sleep -Seconds $TreatmentJoinDelaySeconds
        }

        $treatmentPortWait = Wait-ForPortActive -Port $treatmentPort -Label "treatment" -AttemptProcess $attemptProcess -TimeoutSeconds 300
        Write-Host "  Treatment lane port wait: $($treatmentPortWait.Explanation)"
        if ($treatmentPortWait.Ready) {
            $treatmentJoinExecution = Invoke-LaneJoinHelper -Lane "Treatment" -PairRoot $pairRoot -ResolvedClientExePath $resolvedClientExePath -Port $treatmentPort -Map $missionMap
            if ($treatmentJoinExecution.Result) {
                $treatmentProcessId = [int](Get-ObjectPropertyValue -Object $treatmentJoinExecution.Result -Name "ProcessId" -Default 0)
                $treatmentJoinVerdict = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution.Result -Name "ResultVerdict" -Default "")
                Write-Host "  Treatment lane join helper verdict: $treatmentJoinVerdict"
            }
            elseif ($treatmentJoinExecution.Error) {
                Write-Warning "Treatment lane join failed: $($treatmentJoinExecution.Error)"
            }

            if ($treatmentProcessId -gt 0 -and $TreatmentStaySeconds -gt 0) {
                Start-Sleep -Seconds $TreatmentStaySeconds
                Stop-ClientProcessIfRunning -ProcessId $treatmentProcessId -Reason "treatment lane stay complete" | Out-Null
            }
        }
        else {
            $treatmentJoinExecution = [pscustomobject]@{
                Attempted = $true
                CommandText = ""
                Error = $treatmentPortWait.Explanation
                Result = $null
            }
        }
    }

    try {
        Wait-Process -Id $attemptProcess.Id -Timeout 1800 -ErrorAction Stop
    }
    catch {
        throw "The background conservative attempt did not finish inside the safety timeout: $($_.Exception.Message)"
    }

    Stop-ClientProcessIfRunning -ProcessId $controlProcessId -Reason "final control cleanup" | Out-Null
    Stop-ClientProcessIfRunning -ProcessId $treatmentProcessId -Reason "final treatment cleanup" | Out-Null
}

if (-not $pairRoot) {
    $pairRoot = Find-NewPairRoot -Root $resolvedOutputRoot -NotBeforeUtc $attemptStartUtc
}

if ($pairRoot) {
    $firstAttemptJsonPath = Resolve-ExistingPath -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.json")
    $firstAttemptMarkdownPath = Resolve-ExistingPath -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.md")
    if ($firstAttemptJsonPath) {
        $firstAttemptReport = Read-JsonFile -Path $firstAttemptJsonPath
    }

    $pairSummary = Read-JsonFile -Path (Join-Path $pairRoot "pair_summary.json")
    $certificate = Read-JsonFile -Path (Join-Path $pairRoot "grounded_evidence_certificate.json")
    $missionAttainment = Read-JsonFile -Path (Join-Path $pairRoot "mission_attainment.json")
    $finalDocket = Read-JsonFile -Path (Join-Path $pairRoot "guided_session\final_session_docket.json")
}

$outputPaths = Get-ReportPaths -PairRoot $pairRoot -ResolvedRegistryRoot $resolvedRegistryRoot -Stamp $attemptStamp
$promotionGapDelta = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "promotion_gap_delta.json") } else { $null }
$pairSummaryPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "pair_summary.json") } else { "" }
$certificatePath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "grounded_evidence_certificate.json") } else { "" }
$dossierPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "session_outcome_dossier.json") } else { "" }
$missionAttainmentPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "mission_attainment.json") } else { "" }
$finalDocketPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "guided_session\final_session_docket.json") } else { "" }
$missionExecutionPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "guided_session\mission_execution.json") } else { "" }
$controlLane = Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null
$treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
$comparison = Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
$controlHumanSnapshots = [int](Get-ObjectPropertyValue -Object $controlLane -Name "human_snapshots_count" -Default 0)
$treatmentHumanSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0)
$controlHumanSeconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0.0)
$treatmentHumanSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)
$controlHumanSignal = $controlHumanSnapshots -gt 0 -or $controlHumanSeconds -gt 0.0
$treatmentHumanSignal = $treatmentHumanSnapshots -gt 0 -or $treatmentHumanSeconds -gt 0.0
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
$createdFirstGrounded = [bool](Get-ObjectPropertyValue -Object $promotionGapDelta -Name "created_first_grounded_conservative_session" -Default $false)
$reducedPromotionGap = [bool](Get-ObjectPropertyValue -Object $promotionGapDelta -Name "reduced_promotion_gap" -Default $false)
$finalRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "final_recovery_verdict" -Default "")
$manualReviewRequired = $finalRecoveryVerdict -eq "session-manual-review-needed"
$interruptedAndRecovered = [bool](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "interrupted_and_recovered" -Default $false)
$missionVerdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")
$finalDocketMonitor = Get-ObjectPropertyValue -Object $finalDocket -Name "monitor" -Default $null
$monitorVerdict = [string](Get-ObjectPropertyValue -Object $finalDocketMonitor -Name "last_verdict" -Default "")

$missingTargetDetails = New-Object System.Collections.Generic.List[string]
$targetResults = Get-ObjectPropertyValue -Object $missionAttainment -Name "target_results" -Default $null
if (-not $countsTowardPromotion -and $null -ne $targetResults) {
    foreach ($property in $targetResults.PSObject.Properties) {
        $target = $property.Value
        if (-not [bool](Get-ObjectPropertyValue -Object $target -Name "met" -Default $false)) {
            $explanation = [string](Get-ObjectPropertyValue -Object $target -Name "explanation" -Default "")
            if (-not [string]::IsNullOrWhiteSpace($explanation)) {
                $missingTargetDetails.Add($explanation) | Out-Null
            }
        }
    }
}

$attemptVerdict = Get-HumanAttemptVerdict `
    -ClientLaunchable $clientLaunchable `
    -ManualReviewRequired $manualReviewRequired `
    -CountsTowardPromotion $countsTowardPromotion `
    -CreatedFirstGroundedConservativeSession $createdFirstGrounded `
    -ReducedPromotionGap $reducedPromotionGap `
    -InterruptedAndRecovered $interruptedAndRecovered `
    -ControlHumanSignal $controlHumanSignal `
    -TreatmentHumanSignal $treatmentHumanSignal `
    -JoinSequence $JoinSequence `
    -MissionVerdict $missionVerdict

$explanation = Get-HumanAttemptExplanation `
    -AttemptVerdict $attemptVerdict `
    -DiscoveryReport $discoveryReport `
    -FirstAttemptReport $firstAttemptReport `
    -MissionAttainment $missionAttainment `
    -PairSummary $pairSummary `
    -MissingTargetDetails @($missingTargetDetails)

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_verdict = $attemptVerdict
    explanation = $explanation
    mission_path_used = $missionArtifacts.JsonPath
    mission_markdown_path_used = $missionArtifacts.MarkdownPath
    mission_execution_path = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "mission_execution_path" -Default ""))
    pair_root = $pairRoot
    first_grounded_attempt_verdict = [string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "attempt_verdict" -Default "")
    client_discovery = [ordered]@{
        discovery_verdict = [string](Get-ObjectPropertyValue -Object $discoveryReport -Name "discovery_verdict" -Default "")
        client_path_used = $resolvedClientExePath
        client_path_source = $clientPathSource
        launchable_for_local_lane_join = $clientLaunchable
        explanation = [string](Get-ObjectPropertyValue -Object $discoveryReport -Name "explanation" -Default "")
        discovery_json = $discoveryReportJsonPath
        discovery_markdown = $discoveryReportMarkdownPath
    }
    participation = [ordered]@{
        join_sequence = $JoinSequence
        sequential = $JoinSequence -eq "ControlThenTreatment" -and $autoJoinControlEnabled -and $autoJoinTreatmentEnabled
        overlapping = $false
        local_client_launch_bounded_test_only = $false
    }
    control_lane_join = [ordered]@{
        attempted = [bool]($null -ne $controlJoinExecution)
        auto_launch = $autoJoinControlEnabled
        helper_command = [string](Get-ObjectPropertyValue -Object $controlJoinExecution -Name "CommandText" -Default "")
        helper_result_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ResultVerdict" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "LaunchCommand" -Default "")
        launch_started = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0) -gt 0
        join_succeeded = $controlHumanSignal
        join_target = [string](Get-ObjectPropertyValue -Object $controlLane -Name "join_target" -Default ("127.0.0.1:{0}" -f $controlPort))
        process_id = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0)
        stay_seconds = $ControlStaySeconds
        human_snapshots_count = $controlHumanSnapshots
        seconds_with_human_presence = $controlHumanSeconds
        error = [string](Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Error" -Default "")
    }
    treatment_lane_join = [ordered]@{
        attempted = [bool]($null -ne $treatmentJoinExecution)
        auto_launch = $autoJoinTreatmentEnabled
        helper_command = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "CommandText" -Default "")
        helper_result_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ResultVerdict" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "LaunchCommand" -Default "")
        launch_started = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0) -gt 0
        join_succeeded = $treatmentHumanSignal
        join_target = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "join_target" -Default ("127.0.0.1:{0}" -f $treatmentPort))
        process_id = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0)
        stay_seconds = $TreatmentStaySeconds
        human_snapshots_count = $treatmentHumanSnapshots
        seconds_with_human_presence = $treatmentHumanSeconds
        error = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Error" -Default "")
    }
    control_lane_verdict = [string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_verdict" -Default "")
    treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_verdict" -Default "")
    pair_classification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
    certification_verdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
    counts_toward_promotion = $countsTowardPromotion
    became_first_grounded_conservative_session = $createdFirstGrounded
    reduced_promotion_gap = $reducedPromotionGap
    mission_attainment_verdict = $missionVerdict
    monitor_verdict = $monitorVerdict
    final_recovery_verdict = $finalRecoveryVerdict
    human_signal = [ordered]@{
        control_human_snapshots_count = $controlHumanSnapshots
        control_seconds_with_human_presence = $controlHumanSeconds
        treatment_human_snapshots_count = $treatmentHumanSnapshots
        treatment_seconds_with_human_presence = $treatmentHumanSeconds
        treatment_patched_while_humans_present = [bool](Get-ObjectPropertyValue -Object $comparison -Name "treatment_patched_while_humans_present" -Default $false)
        meaningful_post_patch_observation_window_exists = [bool](Get-ObjectPropertyValue -Object $comparison -Name "meaningful_post_patch_observation_window_exists" -Default $false)
        minimum_human_signal_thresholds_met = [bool](Get-ObjectPropertyValue -Object $certificate -Name "minimum_human_signal_thresholds_met" -Default $false)
        missing_grounding_targets = @([string[]](Get-ObjectPropertyValue -Object $missionAttainment -Name "targets_missed" -Default @()))
        missing_grounding_target_details = @($missingTargetDetails)
    }
    closeout_stack_reused = Get-ObjectPropertyValue -Object $firstAttemptReport -Name "closeout_stack_reused" -Default $null
    artifacts = [ordered]@{
        human_participation_conservative_attempt_json = $outputPaths.JsonPath
        human_participation_conservative_attempt_markdown = $outputPaths.MarkdownPath
        local_client_discovery_json = $discoveryReportJsonPath
        local_client_discovery_markdown = $discoveryReportMarkdownPath
        first_grounded_conservative_attempt_json = $firstAttemptJsonPath
        first_grounded_conservative_attempt_markdown = $firstAttemptMarkdownPath
        pair_summary_json = $pairSummaryPath
        grounded_evidence_certificate_json = $certificatePath
        session_outcome_dossier_json = $dossierPath
        mission_attainment_json = $missionAttainmentPath
        final_session_docket_json = $finalDocketPath
        mission_execution_json = $missionExecutionPath
        attempt_stdout_log = Resolve-ExistingPath -Path $attemptStdoutLog
        attempt_stderr_log = Resolve-ExistingPath -Path $attemptStderrLog
    }
    errors = [ordered]@{
        launch_blocked_reason = $launchBlockedReason
        control_join_error = [string](Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Error" -Default "")
        treatment_join_error = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Error" -Default "")
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-HumanAttemptMarkdown -Report $reportForMarkdown)

Write-Host "Human-participation conservative attempt:"
Write-Host "  Attempt verdict: $($report.attempt_verdict)"
Write-Host "  Pair root: $($report.pair_root)"
Write-Host "  Control join succeeded: $($report.control_lane_join.join_succeeded)"
Write-Host "  Treatment join succeeded: $($report.treatment_lane_join.join_succeeded)"
Write-Host "  Certification verdict: $($report.certification_verdict)"
Write-Host "  Counts toward promotion: $($report.counts_toward_promotion)"
Write-Host "  Attempt report JSON: $($outputPaths.JsonPath)"
Write-Host "  Attempt report Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $pairRoot
    HumanParticipationConservativeAttemptJsonPath = $outputPaths.JsonPath
    HumanParticipationConservativeAttemptMarkdownPath = $outputPaths.MarkdownPath
    AttemptVerdict = $report.attempt_verdict
    CertificationVerdict = $report.certification_verdict
    CountsTowardPromotion = $report.counts_toward_promotion
}
