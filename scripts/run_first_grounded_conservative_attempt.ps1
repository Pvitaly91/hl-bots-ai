[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$LabRoot = "",
    [string]$PairsRoot = "",
    [string]$RegistryPath = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$Configuration = "",
    [string]$Platform = "",
    [int]$DurationSeconds = -1,
    [int]$HumanJoinGraceSeconds = -1,
    [int]$MonitorPollSeconds = 5,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [switch]$AllowMissionOverride,
    [switch]$AllowSafePortOverride
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

function Format-DisplayValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", [double]$Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return (@($Value) | ForEach-Object { Format-DisplayValue -Value $_ }) -join ", "
    }

    return [string]$Value
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
            PreparedNow = $false
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
        PreparedNow = $true
    }
}

function Find-LatestPairRootSince {
    param(
        [string]$Root,
        [datetime]$NotBeforeUtc
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $NotBeforeUtc } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.DirectoryName
}

function Get-AttemptReportPaths {
    param(
        [string]$PairRoot,
        [string]$ResolvedRegistryRoot,
        [string]$Stamp
    )

    if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
        return [ordered]@{
            JsonPath = Join-Path $PairRoot "first_grounded_conservative_attempt.json"
            MarkdownPath = Join-Path $PairRoot "first_grounded_conservative_attempt.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedRegistryRoot "first_grounded_conservative_attempt")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot ("attempt-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $fallbackRoot ("attempt-{0}.md" -f $Stamp)
    }
}

function Get-ContinuationNeeded {
    param([string]$RecoveryVerdict)

    return $RecoveryVerdict -notin @(
        "session-complete",
        "session-complete-pending-review-only"
    )
}

function Get-AttemptVerdict {
    param(
        [bool]$CreatedFirstGroundedConservativeSession,
        [bool]$CountsTowardPromotion,
        [bool]$InterruptedAndRecovered,
        [bool]$InsufficientHumanSignal,
        [bool]$ManualReviewRequired,
        [bool]$RerunRequired,
        [bool]$FinalSessionComplete,
        [string]$EvidenceOrigin
    )

    if ($ManualReviewRequired) {
        return "conservative-session-manual-review-required"
    }

    if ($RerunRequired) {
        return "conservative-session-interrupted-rerun-required"
    }

    if ($CreatedFirstGroundedConservativeSession -and $CountsTowardPromotion -and $EvidenceOrigin -notin @("rehearsal", "synthetic")) {
        return "first-grounded-conservative-captured"
    }

    if ($CountsTowardPromotion -and $EvidenceOrigin -notin @("rehearsal", "synthetic")) {
        return "conservative-session-grounded-but-not-first"
    }

    if ($InterruptedAndRecovered) {
        return "conservative-session-interrupted-and-recovered"
    }

    if ($InsufficientHumanSignal) {
        return "conservative-session-insufficient-human-signal"
    }

    if ($FinalSessionComplete) {
        return "conservative-session-complete-but-not-grounded"
    }

    return "conservative-session-manual-review-required"
}

function Get-AttemptExplanation {
    param(
        [string]$AttemptVerdict,
        [string]$MissionExplanation,
        [string]$DossierExplanation,
        [string]$RecoveryExplanation,
        [string]$ContinuationExplanation,
        [string]$MissionVerdict,
        [string]$MonitorVerdict
    )

    switch ($AttemptVerdict) {
        "first-grounded-conservative-captured" {
            if (-not [string]::IsNullOrWhiteSpace($MissionExplanation)) {
                return $MissionExplanation
            }

            return "The session launched the conservative mission, cleared grounded certification, and created the first grounded conservative evidence pack."
        }
        "conservative-session-grounded-but-not-first" {
            if (-not [string]::IsNullOrWhiteSpace($MissionExplanation)) {
                return $MissionExplanation
            }

            return "The session counted as grounded conservative evidence, but it was not the first grounded conservative pack in the registry."
        }
        "conservative-session-interrupted-and-recovered" {
            if (-not [string]::IsNullOrWhiteSpace($ContinuationExplanation)) {
                return $ContinuationExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($DossierExplanation)) {
                return $DossierExplanation
            }

            return "The first live attempt needed the supported continuation path, and the final pair closed out honestly after recovery."
        }
        "conservative-session-insufficient-human-signal" {
            if (-not [string]::IsNullOrWhiteSpace($MissionExplanation)) {
                return $MissionExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($DossierExplanation)) {
                return $DossierExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($MonitorVerdict)) {
                return "The attempt did not become grounded because the live monitor ended at '{0}' instead of a grounded sufficient verdict." -f $MonitorVerdict
            }

            return "The attempt completed without enough real human-rich signal to count as grounded conservative evidence."
        }
        "conservative-session-complete-but-not-grounded" {
            if (-not [string]::IsNullOrWhiteSpace($DossierExplanation)) {
                return $DossierExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($MissionExplanation)) {
                return $MissionExplanation
            }

            return "The attempt completed and reused the normal closeout stack, but it still did not count as grounded conservative evidence."
        }
        "conservative-session-interrupted-rerun-required" {
            if (-not [string]::IsNullOrWhiteSpace($ContinuationExplanation)) {
                return $ContinuationExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($RecoveryExplanation)) {
                return $RecoveryExplanation
            }

            return "The interrupted attempt never reached a recoverable grounded state, so the supported next step is to rerun the current conservative mission."
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($ContinuationExplanation)) {
                return $ContinuationExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($RecoveryExplanation)) {
                return $RecoveryExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($MissionExplanation)) {
                return $MissionExplanation
            }

            return "The attempt requires manual review before any grounded conservative milestone claim can be made."
        }
    }
}

function Get-AttemptMarkdown {
    param([object]$Attempt)

    $lines = @(
        "# First Grounded Conservative Attempt",
        "",
        "- Attempt verdict: $($Attempt.attempt_verdict)",
        "- Explanation: $($Attempt.explanation)",
        "- Mission path used: $($Attempt.mission_path_used)",
        "- Mission execution path: $($Attempt.mission_execution_path)",
        "- Pair root: $($Attempt.pair_root)",
        "- Evidence origin: $($Attempt.evidence_origin)",
        "- Treatment profile used: $($Attempt.treatment_profile_used)",
        "- Control join target: $($Attempt.live_join_targets.control)",
        "- Treatment join target: $($Attempt.live_join_targets.treatment)",
        "- Final recovery verdict: $($Attempt.final_recovery_verdict)",
        "- Continuation used: $($Attempt.continuation.used)",
        "- Continuation decision: $($Attempt.continuation.decision)",
        "- Continuation execution status: $($Attempt.continuation.execution_status)",
        "",
        "## Evidence Result",
        "",
        "- Control lane verdict: $($Attempt.control_lane_verdict)",
        "- Treatment lane verdict: $($Attempt.treatment_lane_verdict)",
        "- Pair classification: $($Attempt.pair_classification)",
        "- Certification verdict: $($Attempt.certification_verdict)",
        "- Counts toward promotion: $($Attempt.counts_toward_promotion)",
        "- Latest-session impact classification: $($Attempt.latest_session_impact_classification)",
        "- Created first grounded conservative session: $($Attempt.became_first_grounded_conservative_session)",
        "- Reduced promotion gap: $($Attempt.reduced_promotion_gap)",
        "",
        "## Delta",
        "",
        "- Grounded sessions delta: $($Attempt.grounded_sessions_delta)",
        "- Grounded too-quiet delta: $($Attempt.grounded_too_quiet_delta)",
        "- Strong-signal delta: $($Attempt.strong_signal_delta)",
        "- Responsive overreaction blockers delta: $($Attempt.responsive_overreaction_blockers_delta)",
        "",
        "## Before Vs After",
        "",
        "- Responsive gate: $($Attempt.responsive_gate.before.gate_verdict) / $($Attempt.responsive_gate.before.next_live_action) -> $($Attempt.responsive_gate.after.gate_verdict) / $($Attempt.responsive_gate.after.next_live_action)",
        "- Next-live objective: $($Attempt.next_live_objective.before) -> $($Attempt.next_live_objective.after)",
        "",
        "## Closeout Stack",
        "",
        "- Outcome dossier JSON: $($Attempt.artifacts.session_outcome_dossier_json)",
        "- Mission attainment JSON: $($Attempt.artifacts.mission_attainment_json)",
        "- Grounded evidence certificate JSON: $($Attempt.artifacts.grounded_evidence_certificate_json)",
        "- Grounded session analysis JSON: $($Attempt.artifacts.grounded_session_analysis_json)",
        "- Promotion gap delta JSON: $($Attempt.artifacts.promotion_gap_delta_json)",
        "- Final session docket JSON: $($Attempt.artifacts.final_session_docket_json)",
        "- Recovery report JSON: $($Attempt.artifacts.session_recovery_report_json)",
        "",
        "## Notes",
        "",
        "- Mission verdict: $($Attempt.mission_attainment_verdict)",
        "- Monitor verdict: $($Attempt.monitor_verdict)",
        "- Mission promotion impact: $($Attempt.mission_promotion_impact)",
        "- First attempt report JSON: $($Attempt.artifacts.first_grounded_conservative_attempt_json)",
        "- First attempt report Markdown: $($Attempt.artifacts.first_grounded_conservative_attempt_markdown)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ($LabRoot) { Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot } else { Get-LabRootDefault }
$resolvedPairsRoot = if ($PairsRoot) { Get-AbsolutePath -Path $PairsRoot -BasePath $repoRoot } else { Get-PairsRootDefault -LabRoot $resolvedLabRoot }
$resolvedRegistryRoot = if ($RegistryPath) {
    Split-Path -Path (Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot) -Parent
}
else {
    Get-RegistryRootDefault -LabRoot $resolvedLabRoot
}
$resolvedRegistryPath = if ($RegistryPath) {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}
else {
    Join-Path $resolvedRegistryRoot "pair_sessions.ndjson"
}

$attemptStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$attemptStartUtc = (Get-Date).ToUniversalTime()
$missionRunResult = $null
$missionRunError = ""
$helperLaunchBlocked = $false
$initialPairRoot = ""
$finalPairRoot = ""
$continuationResult = $null
$initialRecoveryInfo = $null
$finalRecoveryInfo = $null

$missionArtifacts = Resolve-MissionArtifacts `
    -ExplicitMissionPath $MissionPath `
    -ExplicitMissionMarkdownPath $MissionMarkdownPath `
    -ResolvedLabRoot $resolvedLabRoot

$mission = Read-JsonFile -Path $missionArtifacts.JsonPath
if ($null -eq $mission) {
    throw "Mission JSON could not be read: $($missionArtifacts.JsonPath)"
}

$missionRecommendedProfile = [string](Get-ObjectPropertyValue -Object $mission -Name "recommended_live_treatment_profile" -Default "")
if ($missionRecommendedProfile -and $missionRecommendedProfile -ne "conservative") {
    throw "The current mission does not target the conservative treatment profile. Refusing to use this helper against '$missionRecommendedProfile'."
}

$missionLiveShape = Get-ObjectPropertyValue -Object $mission -Name "live_session_run_shape" -Default $null
$missionLauncherDefaults = Get-ObjectPropertyValue -Object $mission -Name "launcher_defaults" -Default $null
$missionDurationDefault = [int](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "duration_seconds" -Default 80)
$missionHumanJoinGraceDefault = [int](Get-ObjectPropertyValue -Object $missionLiveShape -Name "human_join_grace_seconds" -Default 120)
$missionSkipSteamCmdUpdateDefault = [bool](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "skip_steamcmd_update" -Default $false)
$missionSkipMetamodDownloadDefault = [bool](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "skip_metamod_download" -Default $false)
$attemptLevelOverrideFields = New-Object System.Collections.Generic.List[string]

if ($DurationSeconds -gt 0 -and $DurationSeconds -ne $missionDurationDefault) {
    $attemptLevelOverrideFields.Add("duration_seconds")
}
if ($HumanJoinGraceSeconds -ge 0 -and $HumanJoinGraceSeconds -ne $missionHumanJoinGraceDefault) {
    $attemptLevelOverrideFields.Add("human_join_grace_seconds")
}
if ($PSBoundParameters.ContainsKey("SkipSteamCmdUpdate") -and ([bool]$SkipSteamCmdUpdate -ne $missionSkipSteamCmdUpdateDefault)) {
    $attemptLevelOverrideFields.Add("skip_steamcmd_update")
}
if ($PSBoundParameters.ContainsKey("SkipMetamodDownload") -and ([bool]$SkipMetamodDownload -ne $missionSkipMetamodDownloadDefault)) {
    $attemptLevelOverrideFields.Add("skip_metamod_download")
}

$attemptLevelOverrideList = @($attemptLevelOverrideFields)
if ($attemptLevelOverrideList.Count -gt 0 -and -not $AllowMissionOverride) {
    $helperLaunchBlocked = $true
    $missionRunError = "The first-grounded-attempt helper refuses mission-divergent launch shortcuts without -AllowMissionOverride: " + ($attemptLevelOverrideList -join ", ") + ". Use the mission-exact defaults for the real first grounded conservative attempt, or rerun with -AllowMissionOverride for an explicit validation-only fallback."
}

$beforeResponsiveGateVerdict = [string](Get-ObjectPropertyValue -Object $mission -Name "current_responsive_gate_verdict" -Default "")
$beforeResponsiveGateAction = [string](Get-ObjectPropertyValue -Object $mission -Name "current_responsive_gate_next_live_action" -Default "")
$beforeNextObjective = [string](Get-ObjectPropertyValue -Object $mission -Name "current_next_live_objective" -Default "")

$runCurrentMissionScriptPath = Join-Path $PSScriptRoot "run_current_live_mission.ps1"
$missionRunArgs = [ordered]@{
    MissionPath = $missionArtifacts.JsonPath
    LabRoot = $resolvedLabRoot
    TreatmentProfile = "conservative"
    AutoStopWhenSufficient = $true
}
if ($missionArtifacts.MarkdownPath) {
    $missionRunArgs.MissionMarkdownPath = $missionArtifacts.MarkdownPath
}
if ($OutputRoot) {
    $missionRunArgs.OutputRoot = Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot
}
if ($Configuration) {
    $missionRunArgs.Configuration = $Configuration
}
if ($Platform) {
    $missionRunArgs.Platform = $Platform
}
if ($DurationSeconds -gt 0) {
    $missionRunArgs.DurationSeconds = $DurationSeconds
}
if ($HumanJoinGraceSeconds -ge 0) {
    $missionRunArgs.HumanJoinGraceSeconds = $HumanJoinGraceSeconds
}
if ($MonitorPollSeconds -gt 0) {
    $missionRunArgs.MonitorPollSeconds = $MonitorPollSeconds
}
if ($SkipSteamCmdUpdate) {
    $missionRunArgs.SkipSteamCmdUpdate = $true
}
if ($SkipMetamodDownload) {
    $missionRunArgs.SkipMetamodDownload = $true
}
if ($AllowMissionOverride) {
    $missionRunArgs.AllowMissionOverride = $true
}
if ($AllowSafePortOverride) {
    $missionRunArgs.AllowSafePortOverride = $true
}

if (-not $helperLaunchBlocked) {
    try {
        $missionRunResult = & $runCurrentMissionScriptPath @missionRunArgs
    }
    catch {
        $missionRunError = $_.Exception.Message
    }
}

$initialPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "PairRoot" -Default ""))
if (-not $initialPairRoot) {
    $searchRoot = if ($OutputRoot) { Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot } else { $resolvedPairsRoot }
    $initialPairRoot = Find-LatestPairRootSince -Root $searchRoot -NotBeforeUtc $attemptStartUtc.AddMinutes(-1)
}

if ($initialPairRoot) {
    $assessScriptPath = Join-Path $PSScriptRoot "assess_latest_session_recovery.ps1"
    $initialRecoveryResult = & $assessScriptPath -PairRoot $initialPairRoot -LabRoot $resolvedLabRoot -RegistryPath $resolvedRegistryPath
    $initialRecoveryJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $initialRecoveryResult -Name "SessionRecoveryReportJsonPath" -Default (Join-Path $initialPairRoot "session_recovery_report.json")))
    $initialRecoveryInfo = Read-JsonFile -Path $initialRecoveryJsonPath

    $initialRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $initialRecoveryInfo -Name "recovery_verdict" -Default "")
    if (Get-ContinuationNeeded -RecoveryVerdict $initialRecoveryVerdict) {
        $continueScriptPath = Join-Path $PSScriptRoot "continue_current_live_mission.ps1"
        $continueArgs = [ordered]@{
            PairRoot = $initialPairRoot
            LabRoot = $resolvedLabRoot
            RegistryPath = $resolvedRegistryPath
            Execute = $true
        }
        if ($AllowMissionOverride) {
            $continueArgs.AllowMissionOverride = $true
        }

        try {
            $continuationResult = & $continueScriptPath @continueArgs
        }
        catch {
            $missionRunError = if ($missionRunError) {
                "$missionRunError Continuing attempt also failed: $($_.Exception.Message)"
            }
            else {
                "Continuation failed: $($_.Exception.Message)"
            }
        }
    }
}

$finalPairRoot = if ($continuationResult) {
    $rerunPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $continuationResult -Name "RerunPairRoot" -Default ""))
    if ($rerunPairRoot) {
        $rerunPairRoot
    }
    else {
        $initialPairRoot
    }
}
else {
    $initialPairRoot
}

$outputPaths = Get-AttemptReportPaths -PairRoot $finalPairRoot -ResolvedRegistryRoot $resolvedRegistryRoot -Stamp $attemptStamp

$attemptReport = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_verdict = ""
    explanation = ""
    mission_path_used = $missionArtifacts.JsonPath
    mission_markdown_path_used = $missionArtifacts.MarkdownPath
    mission_execution_path = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "MissionExecutionJsonPath" -Default ""))
    mission_execution_markdown_path = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "MissionExecutionMarkdownPath" -Default ""))
    pair_root = $finalPairRoot
    initial_pair_root = $initialPairRoot
    evidence_origin = ""
    treatment_profile_used = "conservative"
    live_join_targets = [ordered]@{
        control = ""
        treatment = ""
    }
    control_lane_verdict = ""
    treatment_lane_verdict = ""
    pair_classification = ""
    certification_verdict = ""
    counts_toward_promotion = $false
    latest_session_impact_classification = ""
    grounded_sessions_delta = 0
    grounded_too_quiet_delta = 0
    strong_signal_delta = 0
    responsive_overreaction_blockers_delta = 0
    responsive_gate = [ordered]@{
        before = [ordered]@{
            gate_verdict = $beforeResponsiveGateVerdict
            next_live_action = $beforeResponsiveGateAction
        }
        after = [ordered]@{
            gate_verdict = ""
            next_live_action = ""
        }
    }
    next_live_objective = [ordered]@{
        before = $beforeNextObjective
        after = ""
    }
    became_first_grounded_conservative_session = $false
    reduced_promotion_gap = $false
    mission_attainment_verdict = ""
    mission_promotion_impact = $false
    monitor_verdict = ""
    final_recovery_verdict = ""
    final_recommended_recovery_action = ""
    continuation = [ordered]@{
        used = $null -ne $continuationResult
        decision = [string](Get-ObjectPropertyValue -Object $continuationResult -Name "ContinuationDecision" -Default "")
        execution_status = ""
        report_json = ""
        report_markdown = ""
    }
    interrupted_and_recovered = $false
    closeout_stack_reused = [ordered]@{
        mission_runner = "run_current_live_mission.ps1"
        continuation_controller = [bool]($null -ne $continuationResult)
        outcome_dossier = $false
        mission_attainment = $false
        grounded_evidence_certificate = $false
        grounded_session_analysis = $false
    }
    artifacts = [ordered]@{
        first_grounded_conservative_attempt_json = $outputPaths.JsonPath
        first_grounded_conservative_attempt_markdown = $outputPaths.MarkdownPath
        mission_path = $missionArtifacts.JsonPath
        mission_markdown_path = $missionArtifacts.MarkdownPath
        mission_execution_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "MissionExecutionJsonPath" -Default ""))
        mission_execution_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "MissionExecutionMarkdownPath" -Default ""))
        session_recovery_report_json = ""
        session_recovery_report_markdown = ""
        mission_continuation_decision_json = ""
        mission_continuation_decision_markdown = ""
        final_session_docket_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "FinalSessionDocketJsonPath" -Default ""))
        final_session_docket_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "FinalSessionDocketMarkdownPath" -Default ""))
        pair_summary_json = ""
        scorecard_json = ""
        grounded_evidence_certificate_json = ""
        grounded_session_analysis_json = ""
        promotion_gap_delta_json = ""
        session_outcome_dossier_json = ""
        mission_attainment_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "MissionAttainmentJsonPath" -Default ""))
        mission_attainment_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionRunResult -Name "MissionAttainmentMarkdownPath" -Default ""))
    }
    errors = [ordered]@{
        mission_run_error = $missionRunError
    }
}

if ($continuationResult) {
    $attemptReport.continuation.execution_status = [string](Get-ObjectPropertyValue -Object $continuationResult -Name "ExecutionStatus" -Default "")
    $attemptReport.continuation.report_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $continuationResult -Name "MissionContinuationDecisionJsonPath" -Default ""))
    $attemptReport.continuation.report_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $continuationResult -Name "MissionContinuationDecisionMarkdownPath" -Default ""))
    $attemptReport.artifacts.mission_continuation_decision_json = $attemptReport.continuation.report_json
    $attemptReport.artifacts.mission_continuation_decision_markdown = $attemptReport.continuation.report_markdown
}

if ($finalPairRoot) {
    $dossierScriptPath = Join-Path $PSScriptRoot "build_latest_session_outcome_dossier.ps1"
    & $dossierScriptPath -PairRoot $finalPairRoot -LabRoot $resolvedLabRoot -RegistryPath $resolvedRegistryPath | Out-Null

    $missionAttainmentScriptPath = Join-Path $PSScriptRoot "evaluate_latest_session_mission.ps1"
    & $missionAttainmentScriptPath -PairRoot $finalPairRoot | Out-Null

    $finalRecoveryScriptPath = Join-Path $PSScriptRoot "assess_latest_session_recovery.ps1"
    $finalRecoveryResult = & $finalRecoveryScriptPath -PairRoot $finalPairRoot -LabRoot $resolvedLabRoot -RegistryPath $resolvedRegistryPath
    $finalRecoveryJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $finalRecoveryResult -Name "SessionRecoveryReportJsonPath" -Default (Join-Path $finalPairRoot "session_recovery_report.json")))
    $finalRecoveryMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $finalRecoveryResult -Name "SessionRecoveryReportMarkdownPath" -Default (Join-Path $finalPairRoot "session_recovery_report.md")))
    $finalRecoveryInfo = Read-JsonFile -Path $finalRecoveryJsonPath

    $pairSummaryPath = Join-Path $finalPairRoot "pair_summary.json"
    $scorecardPath = Join-Path $finalPairRoot "scorecard.json"
    $certificatePath = Join-Path $finalPairRoot "grounded_evidence_certificate.json"
    $analysisPath = Join-Path $finalPairRoot "grounded_session_analysis.json"
    $deltaPath = Join-Path $finalPairRoot "promotion_gap_delta.json"
    $dossierPath = Join-Path $finalPairRoot "session_outcome_dossier.json"
    $missionAttainmentPath = Join-Path $finalPairRoot "mission_attainment.json"
    $missionExecutionPath = Join-Path $finalPairRoot "guided_session\mission_execution.json"
    $missionExecutionMarkdownPath = Join-Path $finalPairRoot "guided_session\mission_execution.md"
    $finalDocketPath = Join-Path $finalPairRoot "guided_session\final_session_docket.json"
    $finalDocketMarkdownPath = Join-Path $finalPairRoot "guided_session\final_session_docket.md"

    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    $scorecard = Read-JsonFile -Path $scorecardPath
    $certificate = Read-JsonFile -Path $certificatePath
    $analysis = Read-JsonFile -Path $analysisPath
    $delta = Read-JsonFile -Path $deltaPath
    $dossier = Read-JsonFile -Path $dossierPath
    $missionAttainment = Read-JsonFile -Path $missionAttainmentPath
    $missionExecution = Read-JsonFile -Path $missionExecutionPath
    $finalDocket = Read-JsonFile -Path $finalDocketPath

    $controlLane = Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
    $comparison = Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
    $monitorBlock = Get-ObjectPropertyValue -Object $finalDocket -Name "monitor" -Default $null

    $attemptReport.mission_execution_path = Resolve-ExistingPath -Path $missionExecutionPath
    $attemptReport.mission_execution_markdown_path = Resolve-ExistingPath -Path $missionExecutionMarkdownPath
    $attemptReport.evidence_origin = [string](Get-ObjectPropertyValue -Object $certificate -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default ""))
    $attemptReport.treatment_profile_used = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "treatment_profile_used" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default "conservative"))
    $attemptReport.live_join_targets.control = [string](Get-ObjectPropertyValue -Object $controlLane -Name "join_target" -Default "")
    $attemptReport.live_join_targets.treatment = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "join_target" -Default "")
    $attemptReport.control_lane_verdict = [string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_verdict" -Default "")
    $attemptReport.treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_verdict" -Default "")
    $attemptReport.pair_classification = [string](Get-ObjectPropertyValue -Object $scorecard -Name "pair_classification" -Default (Get-ObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default ""))
    $attemptReport.certification_verdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
    $attemptReport.counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
    $attemptReport.latest_session_impact_classification = [string](Get-ObjectPropertyValue -Object $delta -Name "impact_classification" -Default (Get-ObjectPropertyValue -Object $dossier -Name "latest_session_impact_classification" -Default ""))
    $attemptReport.grounded_sessions_delta = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_sessions_delta" -Default 0)
    $attemptReport.grounded_too_quiet_delta = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_too_quiet_delta" -Default 0)
    $attemptReport.strong_signal_delta = [int](Get-ObjectPropertyValue -Object $delta -Name "strong_signal_delta" -Default 0)
    $attemptReport.responsive_overreaction_blockers_delta = [int](Get-ObjectPropertyValue -Object $delta -Name "responsive_overreaction_blockers_delta" -Default 0)
    $attemptReport.responsive_gate.after.gate_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_after" -Default $null) -Name "gate_verdict" -Default (Get-ObjectPropertyValue -Object $dossier -Name "current_responsive_gate_verdict" -Default ""))
    $attemptReport.responsive_gate.after.next_live_action = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_after" -Default $null) -Name "next_live_action" -Default (Get-ObjectPropertyValue -Object $dossier -Name "current_responsive_gate_next_live_action" -Default ""))
    $attemptReport.responsive_gate.before.gate_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_before" -Default $null) -Name "gate_verdict" -Default $attemptReport.responsive_gate.before.gate_verdict)
    $attemptReport.responsive_gate.before.next_live_action = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_before" -Default $null) -Name "next_live_action" -Default $attemptReport.responsive_gate.before.next_live_action)
    $attemptReport.next_live_objective.after = [string](Get-ObjectPropertyValue -Object $delta -Name "next_objective_after" -Default (Get-ObjectPropertyValue -Object $dossier -Name "current_next_live_objective" -Default ""))
    $attemptReport.next_live_objective.before = [string](Get-ObjectPropertyValue -Object $delta -Name "next_objective_before" -Default $attemptReport.next_live_objective.before)
    $attemptReport.became_first_grounded_conservative_session = [bool](Get-ObjectPropertyValue -Object $delta -Name "created_first_grounded_conservative_session" -Default $false)
    $attemptReport.reduced_promotion_gap = [bool](Get-ObjectPropertyValue -Object $delta -Name "reduced_promotion_gap" -Default $false)
    $attemptReport.mission_attainment_verdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")
    $attemptReport.mission_promotion_impact = [bool](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_promotion_impact" -Default $false)
    $attemptReport.monitor_verdict = [string](Get-ObjectPropertyValue -Object $monitorBlock -Name "last_verdict" -Default "")
    $attemptReport.final_recovery_verdict = [string](Get-ObjectPropertyValue -Object $finalRecoveryInfo -Name "recovery_verdict" -Default "")
    $attemptReport.final_recommended_recovery_action = [string](Get-ObjectPropertyValue -Object $finalRecoveryInfo -Name "recommended_next_action" -Default "")
    $attemptReport.interrupted_and_recovered = [bool]($attemptReport.continuation.used -and $attemptReport.final_recovery_verdict -in @("session-complete", "session-complete-pending-review-only"))
    $attemptReport.closeout_stack_reused.outcome_dossier = $null -ne $dossier
    $attemptReport.closeout_stack_reused.mission_attainment = $null -ne $missionAttainment
    $attemptReport.closeout_stack_reused.grounded_evidence_certificate = $null -ne $certificate
    $attemptReport.closeout_stack_reused.grounded_session_analysis = $null -ne $analysis

    $attemptReport.artifacts.session_recovery_report_json = $finalRecoveryJsonPath
    $attemptReport.artifacts.session_recovery_report_markdown = $finalRecoveryMarkdownPath
    $attemptReport.artifacts.final_session_docket_json = Resolve-ExistingPath -Path $finalDocketPath
    $attemptReport.artifacts.final_session_docket_markdown = Resolve-ExistingPath -Path $finalDocketMarkdownPath
    $attemptReport.artifacts.pair_summary_json = Resolve-ExistingPath -Path $pairSummaryPath
    $attemptReport.artifacts.scorecard_json = Resolve-ExistingPath -Path $scorecardPath
    $attemptReport.artifacts.grounded_evidence_certificate_json = Resolve-ExistingPath -Path $certificatePath
    $attemptReport.artifacts.grounded_session_analysis_json = Resolve-ExistingPath -Path $analysisPath
    $attemptReport.artifacts.promotion_gap_delta_json = Resolve-ExistingPath -Path $deltaPath
    $attemptReport.artifacts.session_outcome_dossier_json = Resolve-ExistingPath -Path $dossierPath
    $attemptReport.artifacts.mission_attainment_json = Resolve-ExistingPath -Path $missionAttainmentPath
    $attemptReport.artifacts.mission_attainment_markdown = Resolve-ExistingPath -Path (Join-Path $finalPairRoot "mission_attainment.md")
    $attemptReport.artifacts.mission_execution_json = Resolve-ExistingPath -Path $missionExecutionPath
    $attemptReport.artifacts.mission_execution_markdown = Resolve-ExistingPath -Path $missionExecutionMarkdownPath

    $manualReviewRequired = $attemptReport.final_recovery_verdict -eq "session-manual-review-needed" -or $attemptReport.final_recommended_recovery_action -eq "manual-review-required"
    $rerunRequired = $attemptReport.final_recovery_verdict -eq "session-interrupted-before-sufficiency" -or $attemptReport.final_recovery_verdict -eq "session-nonrecoverable-rerun-required"
    $finalSessionComplete = $attemptReport.final_recovery_verdict -in @("session-complete", "session-complete-pending-review-only")
    $insufficientHumanSignal = $attemptReport.mission_attainment_verdict -eq "mission-failed-insufficient-signal" -or $attemptReport.monitor_verdict -eq "insufficient-data-timeout"

    $attemptReport.attempt_verdict = Get-AttemptVerdict `
        -CreatedFirstGroundedConservativeSession $attemptReport.became_first_grounded_conservative_session `
        -CountsTowardPromotion $attemptReport.counts_toward_promotion `
        -InterruptedAndRecovered $attemptReport.interrupted_and_recovered `
        -InsufficientHumanSignal $insufficientHumanSignal `
        -ManualReviewRequired $manualReviewRequired `
        -RerunRequired $rerunRequired `
        -FinalSessionComplete $finalSessionComplete `
        -EvidenceOrigin $attemptReport.evidence_origin

    $attemptReport.explanation = Get-AttemptExplanation `
        -AttemptVerdict $attemptReport.attempt_verdict `
        -MissionExplanation ([string](Get-ObjectPropertyValue -Object $missionAttainment -Name "explanation" -Default "")) `
        -DossierExplanation ([string](Get-ObjectPropertyValue -Object $dossier -Name "explanation" -Default "")) `
        -RecoveryExplanation ([string](Get-ObjectPropertyValue -Object $finalRecoveryInfo -Name "explanation" -Default "")) `
        -ContinuationExplanation ([string](Get-ObjectPropertyValue -Object (Read-JsonFile -Path $attemptReport.continuation.report_json) -Name "explanation" -Default "")) `
        -MissionVerdict $attemptReport.mission_attainment_verdict `
        -MonitorVerdict $attemptReport.monitor_verdict
}
else {
    $attemptReport.attempt_verdict = "conservative-session-manual-review-required"
    $attemptReport.explanation = if ($missionRunError) {
        "The first grounded conservative attempt did not produce a trustworthy pair root. $missionRunError"
    }
    else {
        "The first grounded conservative attempt did not produce a pair root, so manual review is required."
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $attemptReport
$attemptForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-AttemptMarkdown -Attempt $attemptForMarkdown)

Write-Host "First grounded conservative attempt:"
Write-Host "  Attempt verdict: $($attemptReport.attempt_verdict)"
Write-Host "  Mission path used: $($attemptReport.mission_path_used)"
Write-Host "  Pair root: $($attemptReport.pair_root)"
Write-Host "  Certification verdict: $($attemptReport.certification_verdict)"
Write-Host "  Counts toward promotion: $($attemptReport.counts_toward_promotion)"
Write-Host "  Latest-session impact classification: $($attemptReport.latest_session_impact_classification)"
Write-Host "  Attempt report JSON: $($outputPaths.JsonPath)"
Write-Host "  Attempt report Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $finalPairRoot
    FirstGroundedConservativeAttemptJsonPath = $outputPaths.JsonPath
    FirstGroundedConservativeAttemptMarkdownPath = $outputPaths.MarkdownPath
    AttemptVerdict = $attemptReport.attempt_verdict
    CertificationVerdict = $attemptReport.certification_verdict
    CountsTowardPromotion = $attemptReport.counts_toward_promotion
}
