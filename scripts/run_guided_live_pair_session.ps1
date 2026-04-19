[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$ControlPort = 27016,
    [int]$TreatmentPort = 27017,
    [string]$LabRoot = "",
    [int]$DurationSeconds = 80,
    [switch]$WaitForHumanJoin,
    [int]$HumanJoinGraceSeconds = 120,
    [int]$MinHumanSnapshots = -1,
    [int]$MinHumanPresenceSeconds = -1,
    [int]$MinPatchEventsForUsableLane = -1,
    [int]$MinPostPatchObservationSeconds = 20,
    [ValidateSet("conservative", "default", "responsive")]
    [string]$TreatmentProfile = "conservative",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [switch]$AutoStartMonitor,
    [switch]$AutoStopWhenSufficient,
    [int]$MonitorPollSeconds = 5,
    [switch]$RunPostPipeline,
    [switch]$RehearsalMode,
    [string]$RehearsalFixtureId = "strong_signal_keep_conservative",
    [int]$RehearsalStepSeconds = 2,
    [string]$MissionJsonPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$MissionExecutionSeedJsonPath = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 14
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

function Append-NdjsonRecord {
    param(
        [string]$Path,
        [object]$Record
    )

    $json = $Record | ConvertTo-Json -Depth 12 -Compress
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Get-SessionStatePostPipelineSnapshot {
    param(
        [object]$ReviewResult = $null,
        [object]$ShadowResult = $null,
        [object]$ScoreResult = $null,
        [object]$RegisterResult = $null,
        [object]$RegistrySummaryResult = $null,
        [object]$GateResult = $null,
        [object]$OutcomeDossierResult = $null,
        [object]$MissionAttainmentResult = $null,
        [bool]$RunPostPipelineEnabled = $false,
        [bool]$RegistryIsolatedForRehearsal = $false
    )

    return [ordered]@{
        enabled = $RunPostPipelineEnabled
        review_completed = $null -ne $ReviewResult
        shadow_review_completed = $null -ne $ShadowResult
        scorecard_completed = $null -ne $ScoreResult
        register_completed = $null -ne $RegisterResult
        registry_summary_completed = $null -ne $RegistrySummaryResult
        responsive_gate_completed = $null -ne $GateResult
        outcome_dossier_completed = $null -ne $OutcomeDossierResult
        mission_attainment_completed = $null -ne $MissionAttainmentResult
        registry_isolated_for_rehearsal = $RegistryIsolatedForRehearsal
    }
}

function Write-SessionStateFile {
    param(
        [string]$Path,
        [string]$PairRoot,
        [string]$GuidedSessionRoot,
        [string]$Stage,
        [string]$Status,
        [string]$Explanation,
        [string]$TreatmentProfile,
        [bool]$RunPostPipelineEnabled,
        [object]$MonitorStatus = $null,
        [hashtable]$Artifacts = @{},
        [hashtable]$PostPipeline = $null
    )

    $artifacts = [ordered]@{}
    foreach ($entry in $Artifacts.GetEnumerator()) {
        $artifacts[$entry.Key] = $entry.Value
    }

    $postPipelineSnapshot = if ($null -eq $PostPipeline) {
        Get-SessionStatePostPipelineSnapshot -RunPostPipelineEnabled:$RunPostPipelineEnabled
    }
    else {
        $clonedPostPipeline = [ordered]@{}
        foreach ($entry in $PostPipeline.GetEnumerator()) {
            $clonedPostPipeline[$entry.Key] = $entry.Value
        }

        $clonedPostPipeline
    }

    $payload = [ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $PairRoot
        guided_session_root = $GuidedSessionRoot
        treatment_profile = $TreatmentProfile
        stage = $Stage
        status = $Status
        explanation = $Explanation
        run_post_pipeline_enabled = $RunPostPipelineEnabled
        monitor = [ordered]@{
            current_verdict = [string](Get-ObjectPropertyValue -Object $MonitorStatus -Name "current_verdict" -Default "")
            explanation = [string](Get-ObjectPropertyValue -Object $MonitorStatus -Name "explanation" -Default "")
            operator_can_stop_now = [bool](Get-ObjectPropertyValue -Object $MonitorStatus -Name "operator_can_stop_now" -Default $false)
            likely_remains_insufficient_if_stopped_immediately = [bool](Get-ObjectPropertyValue -Object $MonitorStatus -Name "likely_remains_insufficient_if_stopped_immediately" -Default $true)
        }
        post_pipeline = $postPipelineSnapshot
        artifacts = $artifacts
    }

    Write-JsonFile -Path $Path -Value $payload
    return $payload
}

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$Tail = 40
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return ((Get-Content -LiteralPath $Path -Tail $Tail) -join [Environment]::NewLine).Trim()
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
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

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
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
        return
    }

    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
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

function Format-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function Get-NewPairRootCandidate {
    param(
        [string]$PairsRoot,
        [hashtable]$KnownDirectoryPaths
    )

    if (-not (Test-Path -LiteralPath $PairsRoot)) {
        return ""
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $PairsRoot -Filter "pair_join_instructions.txt" -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )

    foreach ($candidate in $candidates) {
        $pairRoot = $candidate.DirectoryName
        if ($KnownDirectoryPaths.ContainsKey($pairRoot)) {
            continue
        }

        return $pairRoot
    }

    return ""
}

function Wait-ForNewPairRoot {
    param(
        [string]$PairsRoot,
        [hashtable]$KnownDirectoryPaths,
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-NewPairRootCandidate -PairsRoot $PairsRoot -KnownDirectoryPaths $KnownDirectoryPaths
        if ($candidate) {
            return $candidate
        }

        $Process.Refresh()
        if ($Process.HasExited) {
            break
        }

        Start-Sleep -Seconds 1
    }

    return ""
}

function Find-LatestPairRoot {
    param(
        [string]$PairsRoot,
        [hashtable]$KnownDirectoryPaths
    )

    if (-not (Test-Path -LiteralPath $PairsRoot)) {
        return ""
    }

    $latestJoinInstructions = Get-ChildItem -LiteralPath $PairsRoot -Filter "pair_join_instructions.txt" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($candidate in $latestJoinInstructions) {
        $pairRoot = $candidate.DirectoryName
        if ($KnownDirectoryPaths.ContainsKey($pairRoot)) {
            continue
        }

        return $pairRoot
    }

    $latestWithSummary = Get-ChildItem -LiteralPath $PairsRoot -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latestWithSummary) {
        return ""
    }

    return $latestWithSummary.DirectoryName
}

function Get-MonitorCommandText {
    param(
        [string]$PairRoot,
        [int]$PollSeconds,
        [int]$ResolvedMinHumanSnapshots,
        [double]$ResolvedMinHumanPresenceSeconds,
        [int]$ResolvedMinPatchEventsForUsableLane,
        [int]$ResolvedMinPostPatchObservationSeconds,
        [switch]$StopWhenSufficient
    )

    $parts = @(
        "powershell"
        "-NoProfile"
        "-File"
        ".\scripts\monitor_live_pair_session.ps1"
        "-PairRoot"
        ('"{0}"' -f $PairRoot)
        "-PollSeconds"
        [string]$PollSeconds
        "-MinControlHumanSnapshots"
        [string]$ResolvedMinHumanSnapshots
        "-MinControlHumanPresenceSeconds"
        [string]$ResolvedMinHumanPresenceSeconds
        "-MinTreatmentHumanSnapshots"
        [string]$ResolvedMinHumanSnapshots
        "-MinTreatmentHumanPresenceSeconds"
        [string]$ResolvedMinHumanPresenceSeconds
        "-MinTreatmentPatchEventsWhileHumansPresent"
        [string]$ResolvedMinPatchEventsForUsableLane
        "-MinPostPatchObservationSeconds"
        [string]$ResolvedMinPostPatchObservationSeconds
    )

    if ($StopWhenSufficient) {
        $parts += "-StopWhenSufficient"
    }

    return $parts -join " "
}

function Write-StopRequest {
    param(
        [string]$Path,
        [string]$Reason,
        [string]$RequestedBy,
        [string]$Verdict
    )

    $payload = [ordered]@{
        requested_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        reason = $Reason
        requested_by = $RequestedBy
        live_monitor_verdict = $Verdict
    }

    Write-JsonFile -Path $Path -Value $payload
}

function Get-ManualStopCommandText {
    param([string]$StopSignalPath)

    return ('powershell -NoProfile -Command "New-Item -ItemType File -Path ''{0}'' -Force | Out-Null"' -f $StopSignalPath)
}

function Invoke-MonitorSnapshot {
    param(
        [string]$MonitorScriptPath,
        [string]$PairRoot,
        [int]$PollSeconds,
        [int]$ResolvedMinHumanSnapshots,
        [double]$ResolvedMinHumanPresenceSeconds,
        [int]$ResolvedMinPatchEventsForUsableLane,
        [int]$ResolvedMinPostPatchObservationSeconds,
        [string]$LabRoot,
        [string]$PythonPath
    )

    $monitorArgs = @{
        PairRoot = $PairRoot
        PollSeconds = $PollSeconds
        MinControlHumanSnapshots = $ResolvedMinHumanSnapshots
        MinControlHumanPresenceSeconds = $ResolvedMinHumanPresenceSeconds
        MinTreatmentHumanSnapshots = $ResolvedMinHumanSnapshots
        MinTreatmentHumanPresenceSeconds = $ResolvedMinHumanPresenceSeconds
        MinTreatmentPatchEventsWhileHumansPresent = $ResolvedMinPatchEventsForUsableLane
        MinPostPatchObservationSeconds = $ResolvedMinPostPatchObservationSeconds
        Once = $true
        LabRoot = $LabRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
        $monitorArgs.PythonPath = $PythonPath
    }

    return & $MonitorScriptPath @monitorArgs
}

function Write-MonitorHistoryRecord {
    param(
        [string]$Path,
        [object]$MonitorStatus,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $MonitorStatus) {
        return
    }

    Append-NdjsonRecord -Path $Path -Record ([ordered]@{
        recorded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source = $Source
        current_verdict = [string](Get-ObjectPropertyValue -Object $MonitorStatus -Name "current_verdict" -Default "")
        phase = [string](Get-ObjectPropertyValue -Object $MonitorStatus -Name "phase" -Default "")
        pair_complete = [bool](Get-ObjectPropertyValue -Object $MonitorStatus -Name "pair_complete" -Default $false)
        control_human_snapshots_count = [int](Get-ObjectPropertyValue -Object $MonitorStatus -Name "control_human_snapshots_count" -Default 0)
        control_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $MonitorStatus -Name "control_human_presence_seconds" -Default 0.0)
        treatment_human_snapshots_count = [int](Get-ObjectPropertyValue -Object $MonitorStatus -Name "treatment_human_snapshots_count" -Default 0)
        treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $MonitorStatus -Name "treatment_human_presence_seconds" -Default 0.0)
        treatment_patch_events_while_humans_present = [int](Get-ObjectPropertyValue -Object $MonitorStatus -Name "treatment_patch_events_while_humans_present" -Default 0)
        meaningful_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $MonitorStatus -Name "meaningful_post_patch_observation_seconds" -Default 0.0)
        explanation = [string](Get-ObjectPropertyValue -Object $MonitorStatus -Name "explanation" -Default "")
    })
}

function Get-RecommendedOperatorAction {
    param(
        [string]$ScorecardRecommendation,
        [string]$ShadowDecision,
        [string]$RegistryDecision,
        [string]$RegistryRecommendedLiveProfile,
        [string]$ResponsiveGateVerdict,
        [string]$ResponsiveGateNextLiveAction
    )

    $reviewManually = $ScorecardRecommendation -eq "manual-review-needed" -or
        $ShadowDecision -eq "manual-review-needed" -or
        $RegistryDecision -eq "manual-review-needed" -or
        $ResponsiveGateVerdict -eq "manual-review-needed" -or
        $ResponsiveGateNextLiveAction -eq "manual-review-needed"

    $collectAnotherConservativeSession = $ScorecardRecommendation -in @(
        "keep-conservative-and-collect-more",
        "treatment-evidence-promising-repeat-conservative",
        "weak-signal-repeat-session",
        "insufficient-data-repeat-session"
    ) -or $RegistryDecision -in @(
        "insufficient-data-repeat-session",
        "weak-signal-repeat-session",
        "collect-more-conservative-evidence"
    ) -or $ResponsiveGateNextLiveAction -eq "collect-more-conservative-evidence"

    $keepConservative = $RegistryRecommendedLiveProfile -eq "conservative" -or
        $ShadowDecision -eq "keep-conservative" -or
        $ResponsiveGateNextLiveAction -in @(
            "keep-conservative",
            "collect-more-conservative-evidence",
            "responsive-trial-not-allowed",
            "responsive-revert-recommended"
        )

    $waitBeforeConsideringResponsive = $ResponsiveGateVerdict -ne "open"

    $primary = if ($reviewManually) {
        "review-manually"
    }
    elseif ($collectAnotherConservativeSession) {
        "collect-another-conservative-session"
    }
    elseif ($keepConservative) {
        "keep-conservative"
    }
    else {
        "wait-before-considering-responsive"
    }

    [pscustomobject]@{
        Primary = $primary
        KeepConservative = $keepConservative
        CollectAnotherConservativeSession = $collectAnotherConservativeSession
        ReviewManually = $reviewManually
        WaitBeforeConsideringResponsive = $waitBeforeConsideringResponsive
    }
}

function Get-MissionExecutionMarkdown {
    param([object]$Execution)

    $lines = @(
        "# Mission Execution",
        "",
        "- Mission path used: $($Execution.mission_path_used)",
        "- Mission Markdown path used: $($Execution.mission_markdown_path_used)",
        "- Mission hash SHA256: $($Execution.mission_identity.sha256)",
        "- Mission objective: $($Execution.mission_identity.current_next_live_objective)",
        "- Mission recommended live profile: $($Execution.mission_identity.recommended_live_treatment_profile)",
        "- Execution mode: $($Execution.execution_mode)",
        "- Pair root: $($Execution.pair_root)",
        "- Guided session root: $($Execution.guided_session_root)",
        "- Mission compliant: $($Execution.mission_compliant)",
        "- Mission divergent: $($Execution.mission_divergent)",
        "- Valid for mission-attainment analysis: $($Execution.valid_for_mission_attainment_analysis)",
        "- Drift detected: $($Execution.drift_summary.drift_detected)",
        "- Drift policy verdict: $($Execution.drift_policy_verdict)",
        "- Explanation: $($Execution.explanation)",
        "",
        "## Requested Launch Parameters",
        "",
        "- Map: $($Execution.requested_execution_parameters.map)",
        "- Bot count: $($Execution.requested_execution_parameters.bot_count)",
        "- Bot skill: $($Execution.requested_execution_parameters.bot_skill)",
        "- Control port: $($Execution.requested_execution_parameters.control_port)",
        "- Treatment port: $($Execution.requested_execution_parameters.treatment_port)",
        "- Treatment profile: $($Execution.requested_execution_parameters.treatment_profile)",
        "- Min human snapshots: $($Execution.requested_execution_parameters.min_human_snapshots)",
        "- Min human presence seconds: $($Execution.requested_execution_parameters.min_human_presence_seconds)",
        "- Min patch-while-human-present events: $($Execution.requested_execution_parameters.min_patch_events_for_usable_lane)",
        "- Min post-patch observation seconds: $($Execution.requested_execution_parameters.min_post_patch_observation_seconds)",
        "- Pair output root: $($Execution.requested_execution_parameters.output_root)",
        "- Skip SteamCMD update: $($Execution.requested_execution_parameters.skip_steamcmd_update)",
        "- Skip Metamod download: $($Execution.requested_execution_parameters.skip_metamod_download)",
        "- Rehearsal mode: $($Execution.requested_execution_parameters.rehearsal_mode)",
        "",
        "## Drift Fields",
        ""
    )

    foreach ($entry in @($Execution.drift_summary.fields.PSObject.Properties)) {
        $field = $entry.Value
        $lines += ("- {0}: mission={1}; actual={2}; match={3}; allowed={4}; explanation={5}" -f
            [string](Get-ObjectPropertyValue -Object $field -Name "field_name" -Default $entry.Name),
            (Format-DisplayValue -Value (Get-ObjectPropertyValue -Object $field -Name "mission_value" -Default $null)),
            (Format-DisplayValue -Value (Get-ObjectPropertyValue -Object $field -Name "actual_value" -Default $null)),
            ([bool](Get-ObjectPropertyValue -Object $field -Name "match" -Default $false)).ToString().ToLowerInvariant(),
            ([bool](Get-ObjectPropertyValue -Object $field -Name "allowed" -Default $false)).ToString().ToLowerInvariant(),
            [string](Get-ObjectPropertyValue -Object $field -Name "explanation" -Default "")
        )
    }

    $lines += @(
        "",
        "## Guided Runner Command",
        "",
        '```powershell',
        ([string](Get-ObjectPropertyValue -Object $Execution -Name "guided_runner_command" -Default "")),
        '```',
        ""
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Finalize-MissionExecutionArtifacts {
    param(
        [string]$SeedJsonPath,
        [string]$PairRoot,
        [string]$GuidedSessionRoot
    )

    if ([string]::IsNullOrWhiteSpace($SeedJsonPath) -or -not (Test-Path -LiteralPath $SeedJsonPath)) {
        return [pscustomobject]@{
            JsonPath = ""
            MarkdownPath = ""
            Payload = $null
        }
    }

    $payload = Read-JsonFile -Path $SeedJsonPath
    if ($null -eq $payload) {
        throw "Mission execution seed could not be parsed: $SeedJsonPath"
    }

    $missionExecutionJsonPath = Join-Path $GuidedSessionRoot "mission_execution.json"
    $missionExecutionMarkdownPath = Join-Path $GuidedSessionRoot "mission_execution.md"

    Set-ObjectPropertyValue -Object $payload -Name "pair_root" -Value $PairRoot
    Set-ObjectPropertyValue -Object $payload -Name "guided_session_root" -Value $GuidedSessionRoot
    Set-ObjectPropertyValue -Object $payload -Name "execution_record_status" -Value "launched"

    $artifacts = Get-ObjectPropertyValue -Object $payload -Name "artifacts" -Default ([ordered]@{})
    if ($artifacts -isnot [System.Collections.IDictionary]) {
        $artifacts = [ordered]@{}
    }
    $artifacts.mission_execution_json = $missionExecutionJsonPath
    $artifacts.mission_execution_markdown = $missionExecutionMarkdownPath
    Set-ObjectPropertyValue -Object $payload -Name "artifacts" -Value $artifacts

    Write-JsonFile -Path $missionExecutionJsonPath -Value $payload
    $payloadForMarkdown = Read-JsonFile -Path $missionExecutionJsonPath
    Write-TextFile -Path $missionExecutionMarkdownPath -Value (Get-MissionExecutionMarkdown -Execution $payloadForMarkdown)

    return [pscustomobject]@{
        JsonPath = $missionExecutionJsonPath
        MarkdownPath = $missionExecutionMarkdownPath
        Payload = $payloadForMarkdown
    }
}

function Get-FinalSessionDocketMarkdown {
    param([object]$Docket)

    $lines = @(
        "# Final Session Docket",
        "",
        "- Pair root: $($Docket.pair_root)",
        "- Guided session root: $($Docket.guided_session_root)",
        "- Preflight verdict: $($Docket.preflight.verdict)",
        "- Treatment profile: $($Docket.treatment_profile)",
        "- Synthetic fixture: $($Docket.evidence.synthetic_fixture)",
        "- Rehearsal mode: $($Docket.evidence.rehearsal_mode)",
        "- Evidence origin: $($Docket.evidence.evidence_origin)",
        "- Validation only: $($Docket.evidence.validation_only)",
        "- Auto-start monitor: $($Docket.monitor.auto_started)",
        "- Auto-stop when sufficient: $($Docket.monitor.auto_stop_when_sufficient)",
        "- Auto-stop triggered: $($Docket.monitor.auto_stop_triggered)",
        "- Last live monitor verdict: $($Docket.monitor.last_verdict)",
        "- Session sufficient for tuning-usable review: $($Docket.session_sufficient_for_tuning_usable_review)",
        "",
        "## Pair Verdict",
        "",
        "- Control lane verdict: $($Docket.pair.control_lane_verdict)",
        "- Treatment lane verdict: $($Docket.pair.treatment_lane_verdict)",
        "- Pair classification: $($Docket.pair.pair_classification)",
        "- Comparison verdict: $($Docket.pair.comparison_verdict)",
        "",
        "## Recommendations",
        "",
        "- Scorecard recommendation: $($Docket.recommendations.scorecard_recommendation)",
        "- Shadow recommendation: $($Docket.recommendations.shadow_recommendation)",
        "- Registry recommendation state: $($Docket.recommendations.registry_recommendation_state)",
        "- Registry recommended live profile: $($Docket.recommendations.registry_recommended_live_profile)",
        "- Responsive gate verdict: $($Docket.recommendations.responsive_gate_verdict)",
        "- Responsive gate next live action: $($Docket.recommendations.responsive_gate_next_live_action)",
        "- Next-live planner objective: $($Docket.recommendations.next_live_session_objective)",
        "- Next-live planner profile: $($Docket.recommendations.next_live_recommended_live_profile)",
        "- Primary operator action: $($Docket.recommendations.operator_action.primary)",
        "- Keep conservative: $($Docket.recommendations.operator_action.keep_conservative)",
        "- Collect another conservative session: $($Docket.recommendations.operator_action.collect_another_conservative_session)",
        "- Review manually: $($Docket.recommendations.operator_action.review_manually)",
        "- Wait before considering responsive: $($Docket.recommendations.operator_action.wait_before_considering_responsive)",
        "",
        "## Mission Attainment",
        "",
        "- Mission verdict: $($Docket.mission_attainment.verdict)",
        "- Mission operational success: $($Docket.mission_attainment.mission_operational_success)",
        "- Mission grounded success: $($Docket.mission_attainment.mission_grounded_success)",
        "- Mission promotion impact: $($Docket.mission_attainment.mission_promotion_impact)",
        "- Mission explanation: $($Docket.mission_attainment.explanation)",
        "",
        "## Mission Execution",
        "",
        "- Drift policy verdict: $($Docket.mission_execution.drift_policy_verdict)",
        "- Mission compliant launch: $($Docket.mission_execution.mission_compliant)",
        "- Mission divergent launch: $($Docket.mission_execution.mission_divergent)",
        "- Valid for mission-attainment analysis: $($Docket.mission_execution.valid_for_mission_attainment_analysis)",
        "- Drift detected: $($Docket.mission_execution.drift_detected)",
        "- Mission execution explanation: $($Docket.mission_execution.explanation)",
        "",
        "## Session State",
        "",
        "- Session state path: $($Docket.session_state.path)",
        "- Session state stage: $($Docket.session_state.stage)",
        "- Session state status: $($Docket.session_state.status)",
        "- Full closeout completed: $($Docket.session_state.full_closeout_completed)",
        "",
        "## Artifacts",
        "",
        "- Pair summary JSON: $($Docket.artifacts.pair_summary_json)",
        "- Scorecard JSON: $($Docket.artifacts.scorecard_json)",
        "- Shadow recommendation JSON: $($Docket.artifacts.shadow_recommendation_json)",
        "- Profile recommendation JSON: $($Docket.artifacts.profile_recommendation_json)",
        "- Responsive trial gate JSON: $($Docket.artifacts.responsive_trial_gate_json)",
        "- Next-live plan JSON: $($Docket.artifacts.next_live_plan_json)",
        "- Mission brief JSON: $($Docket.artifacts.mission_brief_json)",
        "- Mission brief Markdown: $($Docket.artifacts.mission_brief_markdown)",
        "- Mission snapshot JSON: $($Docket.artifacts.mission_snapshot_json)",
        "- Mission snapshot Markdown: $($Docket.artifacts.mission_snapshot_markdown)",
        "- Mission execution JSON: $($Docket.artifacts.mission_execution_json)",
        "- Mission execution Markdown: $($Docket.artifacts.mission_execution_markdown)",
        "- Session state JSON: $($Docket.artifacts.session_state_json)",
        "- Registry path: $($Docket.artifacts.registry_path)",
        "- Monitor history NDJSON: $($Docket.artifacts.monitor_history_ndjson)",
        "- Rehearsal metadata JSON: $($Docket.artifacts.rehearsal_metadata_json)",
        "- Final docket JSON: $($Docket.artifacts.final_session_docket_json)",
        "- Outcome dossier JSON: $($Docket.artifacts.session_outcome_dossier_json)",
        "- Mission attainment JSON: $($Docket.artifacts.mission_attainment_json)",
        "- Mission attainment Markdown: $($Docket.artifacts.mission_attainment_markdown)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
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
if ($DurationSeconds -lt 5) {
    throw "DurationSeconds must be at least 5 seconds."
}
if ($HumanJoinGraceSeconds -lt 5) {
    throw "HumanJoinGraceSeconds must be at least 5 seconds."
}
if ($MonitorPollSeconds -lt 1) {
    throw "MonitorPollSeconds must be at least 1."
}
if ($RehearsalStepSeconds -lt 1) {
    throw "RehearsalStepSeconds must be at least 1."
}
if ($MinPostPatchObservationSeconds -lt 1) {
    throw "MinPostPatchObservationSeconds must be at least 1."
}

$resolvedProfile = Get-TuningProfileDefinition -Name $TreatmentProfile
if (-not $PSBoundParameters.ContainsKey("MinHumanSnapshots")) {
    $MinHumanSnapshots = [int]$resolvedProfile.evaluation.min_human_snapshots
}
if (-not $PSBoundParameters.ContainsKey("MinHumanPresenceSeconds")) {
    $MinHumanPresenceSeconds = [int][Math]::Round([double]$resolvedProfile.evaluation.min_human_presence_seconds)
}
if (-not $PSBoundParameters.ContainsKey("MinPatchEventsForUsableLane")) {
    $MinPatchEventsForUsableLane = [int]$resolvedProfile.evaluation.min_patch_events_for_usable_lane
}

if ($MinHumanSnapshots -lt 1) {
    throw "MinHumanSnapshots must be at least 1."
}
if ($MinHumanPresenceSeconds -lt 1) {
    throw "MinHumanPresenceSeconds must be at least 1."
}
if ($MinPatchEventsForUsableLane -lt 0) {
    throw "MinPatchEventsForUsableLane cannot be negative."
}

$waitForHumanJoinEnabled = $true
if ($PSBoundParameters.ContainsKey("WaitForHumanJoin")) {
    $waitForHumanJoinEnabled = [bool]$WaitForHumanJoin
}

$autoStartMonitorEnabled = $true
if ($PSBoundParameters.ContainsKey("AutoStartMonitor")) {
    $autoStartMonitorEnabled = [bool]$AutoStartMonitor
}

$runPostPipelineEnabled = $true
if ($PSBoundParameters.ContainsKey("RunPostPipeline")) {
    $runPostPipelineEnabled = [bool]$RunPostPipeline
}

if ($AutoStopWhenSufficient) {
    $autoStartMonitorEnabled = $true
}

$repoRoot = Get-RepoRoot
$LabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot }
$LabRoot = Ensure-Directory -Path $LabRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$pairsRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Get-PairsRootDefault -LabRoot $LabRoot)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}

$sessionStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$guidanceRoot = Ensure-Directory -Path (Join-Path $logsRoot ("guided_sessions\{0}" -f $sessionStamp))
$stopSignalPath = Join-Path $guidanceRoot "stop_when_sufficient.request.json"
$pairRunnerStdoutPath = Join-Path $guidanceRoot "pair_runner.stdout.log"
$pairRunnerStderrPath = Join-Path $guidanceRoot "pair_runner.stderr.log"
$monitorScriptPath = Join-Path $PSScriptRoot "monitor_live_pair_session.ps1"
$livePairScriptPath = Join-Path $PSScriptRoot "run_control_treatment_pair.ps1"
$rehearsalPairScriptPath = Join-Path $PSScriptRoot "run_guided_pair_rehearsal.ps1"
$pairScriptPath = if ($RehearsalMode) { $rehearsalPairScriptPath } else { $livePairScriptPath }
$preflightScriptPath = Join-Path $PSScriptRoot "preflight_real_pair_session.ps1"
$reviewScriptPath = Join-Path $PSScriptRoot "review_latest_pair_run.ps1"
$shadowScriptPath = Join-Path $PSScriptRoot "run_shadow_profile_review.ps1"
$scoreScriptPath = Join-Path $PSScriptRoot "score_latest_pair_session.ps1"
$registerScriptPath = Join-Path $PSScriptRoot "register_pair_session_result.ps1"
$summaryScriptPath = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"
$gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"
$missionScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"

$controlJoinInfo = Get-HldsJoinInfo -Port $ControlPort
$treatmentJoinInfo = Get-HldsJoinInfo -Port $TreatmentPort

Write-Host "Guided live pair session:"
Write-Host "  Control join target: $($controlJoinInfo.LoopbackAddress)"
Write-Host "  Treatment join target: $($treatmentJoinInfo.LoopbackAddress)"
Write-Host "  Treatment profile: $($resolvedProfile.name)"
Write-Host "  Rehearsal mode: $RehearsalMode"
if ($RehearsalMode) {
    Write-Host "  Rehearsal fixture ID: $RehearsalFixtureId"
    Write-Host "  Rehearsal evidence origin: rehearsal (synthetic, validation only)"
}
Write-Host "  Pair output root: $pairsRoot"
Write-Host "  Auto-start monitor: $autoStartMonitorEnabled"
Write-Host "  Auto-stop when sufficient: $AutoStopWhenSufficient"
Write-Host "  Enough evidence means:"
Write-Host "    control human snapshots >= $MinHumanSnapshots"
Write-Host "    control human presence seconds >= $MinHumanPresenceSeconds"
Write-Host "    treatment human snapshots >= $MinHumanSnapshots"
Write-Host "    treatment human presence seconds >= $MinHumanPresenceSeconds"
Write-Host "    treatment patch events while humans are present >= $MinPatchEventsForUsableLane"
Write-Host "    post-patch observation seconds >= $MinPostPatchObservationSeconds"
Write-Host "  Post-run pipeline enabled: $runPostPipelineEnabled"
Write-Host "  Post-run pipeline steps:"
Write-Host "    scripts\review_latest_pair_run.ps1"
Write-Host "    scripts\run_shadow_profile_review.ps1"
Write-Host "    scripts\score_latest_pair_session.ps1"
Write-Host "    scripts\register_pair_session_result.ps1"
Write-Host "    scripts\summarize_pair_session_registry.ps1"
Write-Host "    scripts\evaluate_responsive_trial_gate.ps1"
if ($RehearsalMode) {
    Write-Host "  Post-run registry mode: isolated rehearsal registry under guided_session\registry"
}
Write-Host "  Manual safe-stop request file: $stopSignalPath"
Write-Host "  Manual safe-stop command: $(Get-ManualStopCommandText -StopSignalPath $stopSignalPath)"

$preflightArgs = @{
    Map = $Map
    BotCount = $BotCount
    BotSkill = $BotSkill
    ControlPort = $ControlPort
    TreatmentPort = $TreatmentPort
    LabRoot = $LabRoot
    TreatmentProfile = $resolvedProfile.name
    Configuration = $Configuration
    Platform = $Platform
}
if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
    $preflightArgs.PythonPath = $PythonPath
}

$preflightResult = & $preflightScriptPath @preflightArgs
if ([string]$preflightResult.Verdict -eq "blocked") {
    throw "Preflight reported 'blocked'. Resolve the listed blockers before running the guided pair session."
}

$missionPayload = $null
if (-not [string]::IsNullOrWhiteSpace($MissionJsonPath)) {
    $MissionJsonPath = Get-AbsolutePath -Path $MissionJsonPath -BasePath $repoRoot
    if (-not (Test-Path -LiteralPath $MissionJsonPath)) {
        throw "MissionJsonPath was not found: $MissionJsonPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionMarkdownPath)) {
        $MissionMarkdownPath = Get-AbsolutePath -Path $MissionMarkdownPath -BasePath $repoRoot
    }
    elseif (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($MissionJsonPath, ".md"))) {
        $MissionMarkdownPath = [System.IO.Path]::ChangeExtension($MissionJsonPath, ".md")
    }

    $missionPayload = Read-JsonFile -Path $MissionJsonPath
}
else {
    $missionArgs = @{
        LabRoot = $LabRoot
    }
    $missionResult = & $missionScriptPath @missionArgs
    $MissionJsonPath = [string](Get-ObjectPropertyValue -Object $missionResult -Name "MissionJsonPath" -Default "")
    $MissionMarkdownPath = [string](Get-ObjectPropertyValue -Object $missionResult -Name "MissionMarkdownPath" -Default "")
    $missionPayload = Read-JsonFile -Path $MissionJsonPath
}

if ($null -eq $missionPayload) {
    throw "Mission brief could not be parsed: $MissionJsonPath"
}

$missionJsonPath = $MissionJsonPath
$missionMarkdownPath = $MissionMarkdownPath
$missionRecommendedProfile = [string](Get-ObjectPropertyValue -Object $missionPayload -Name "recommended_live_treatment_profile" -Default "")
$missionCurrentObjective = [string](Get-ObjectPropertyValue -Object $missionPayload -Name "current_next_live_objective" -Default "")

Write-Host "  Mission brief JSON: $missionJsonPath"
Write-Host "  Mission brief Markdown: $missionMarkdownPath"
Write-Host "  Mission recommended live profile: $missionRecommendedProfile"
Write-Host "  Mission current objective: $missionCurrentObjective"
if (-not [string]::IsNullOrWhiteSpace($missionRecommendedProfile) -and $resolvedProfile.name -ne $missionRecommendedProfile) {
    Write-Warning "The requested treatment profile '$($resolvedProfile.name)' does not match the current mission recommendation '$missionRecommendedProfile'."
}

$knownPairDirectories = @{}
foreach ($markerPath in @(
    Get-ChildItem -LiteralPath $pairsRoot -Filter "pair_join_instructions.txt" -Recurse -File -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $pairsRoot -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue
)) {
    foreach ($item in @($markerPath)) {
        if ($null -ne $item) {
            $knownPairDirectories[$item.DirectoryName] = $true
        }
    }
}

$pairProcessArguments = @(
    "-NoProfile"
    "-ExecutionPolicy"
    "Bypass"
    "-File"
    $pairScriptPath
    "-Map"
    $Map
    "-BotCount"
    [string]$BotCount
    "-BotSkill"
    [string]$BotSkill
    "-ControlPort"
    [string]$ControlPort
    "-TreatmentPort"
    [string]$TreatmentPort
    "-DurationSeconds"
    [string]$DurationSeconds
    "-MinHumanSnapshots"
    [string]$MinHumanSnapshots
    "-MinHumanPresenceSeconds"
    [string]$MinHumanPresenceSeconds
    "-MinPatchEventsForUsableLane"
    [string]$MinPatchEventsForUsableLane
    "-MinPostPatchObservationSeconds"
    [string]$MinPostPatchObservationSeconds
    "-TreatmentProfile"
    $resolvedProfile.name
    "-GuidedStopSignalPath"
    $stopSignalPath
)

if ($RehearsalMode) {
    $pairProcessArguments += @(
        "-FixtureId"
        $RehearsalFixtureId
        "-OutputRoot"
        $pairsRoot
        "-StageDelaySeconds"
        [string]$RehearsalStepSeconds
    )
}
else {
    $pairProcessArguments += @(
        "-LabRoot"
        $LabRoot
        "-HumanJoinGraceSeconds"
        [string]$HumanJoinGraceSeconds
        "-Configuration"
        $Configuration
        "-Platform"
        $Platform
    )

    if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
        $pairProcessArguments += @("-OutputRoot", $pairsRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($SteamCmdPath)) {
        $pairProcessArguments += @("-SteamCmdPath", $SteamCmdPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
        $pairProcessArguments += @("-PythonPath", $PythonPath)
    }
    if ($waitForHumanJoinEnabled) {
        $pairProcessArguments += "-WaitForHumanJoin"
    }
    if ($SkipSteamCmdUpdate) {
        $pairProcessArguments += "-SkipSteamCmdUpdate"
    }
    if ($SkipMetamodDownload) {
        $pairProcessArguments += "-SkipMetamodDownload"
    }
}

$pairProcessCommandLine = @($pairProcessArguments | ForEach-Object { Format-ProcessArgument -Value ([string]$_) }) -join " "
$pairProcess = Start-Process `
    -FilePath "powershell" `
    -ArgumentList $pairProcessCommandLine `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $pairRunnerStdoutPath `
    -RedirectStandardError $pairRunnerStderrPath `
    -PassThru

$pairRoot = Wait-ForNewPairRoot -PairsRoot $pairsRoot -KnownDirectoryPaths $knownPairDirectories -Process $pairProcess -TimeoutSeconds 180
if (-not $pairRoot) {
    $pairRoot = Find-LatestPairRoot -PairsRoot $pairsRoot -KnownDirectoryPaths $knownPairDirectories
}
if (-not $pairRoot) {
    while (-not $pairProcess.HasExited) {
        Start-Sleep -Seconds 1
        $pairProcess.Refresh()
    }

    throw "The guided pair runner did not create a new pair root under $pairsRoot. STDERR: $(Get-LogTailText -Path $pairRunnerStderrPath)"
}

$guidedSessionRoot = Ensure-Directory -Path (Join-Path $pairRoot "guided_session")
$finalDocketJsonPath = Join-Path $guidedSessionRoot "final_session_docket.json"
$finalDocketMarkdownPath = Join-Path $guidedSessionRoot "final_session_docket.md"
$sessionStateJsonPath = Join-Path $guidedSessionRoot "session_state.json"
$monitorHistoryPath = Join-Path $guidedSessionRoot "monitor_verdict_history.ndjson"
$missionSnapshotRoot = Ensure-Directory -Path (Join-Path $guidedSessionRoot "mission")
$missionSnapshotJsonPath = ""
$missionSnapshotMarkdownPath = ""
$missionExecutionJsonPath = ""
$missionExecutionMarkdownPath = ""
$missionExecutionPayload = $null
$rehearsalRegistryRoot = if ($RehearsalMode) {
    Ensure-Directory -Path (Join-Path $guidedSessionRoot "registry")
}
else {
    ""
}
$postPipelineRegistryPath = if ($RehearsalMode) {
    Join-Path $rehearsalRegistryRoot "pair_sessions.ndjson"
}
else {
    ""
}
$monitorCommandText = Get-MonitorCommandText `
    -PairRoot $pairRoot `
    -PollSeconds $MonitorPollSeconds `
    -ResolvedMinHumanSnapshots $MinHumanSnapshots `
    -ResolvedMinHumanPresenceSeconds $MinHumanPresenceSeconds `
    -ResolvedMinPatchEventsForUsableLane $MinPatchEventsForUsableLane `
    -ResolvedMinPostPatchObservationSeconds $MinPostPatchObservationSeconds `
    -StopWhenSufficient:$AutoStopWhenSufficient

if ($missionJsonPath -and (Test-Path -LiteralPath $missionJsonPath)) {
    $missionSnapshotJsonPath = Join-Path $missionSnapshotRoot "next_live_session_mission.json"
    Copy-Item -LiteralPath $missionJsonPath -Destination $missionSnapshotJsonPath -Force
}
else {
    Write-Warning "Mission JSON was not available to snapshot into the pair root."
}

if ($missionMarkdownPath -and (Test-Path -LiteralPath $missionMarkdownPath)) {
    $missionSnapshotMarkdownPath = Join-Path $missionSnapshotRoot "next_live_session_mission.md"
    Copy-Item -LiteralPath $missionMarkdownPath -Destination $missionSnapshotMarkdownPath -Force
}
else {
    Write-Warning "Mission Markdown was not available to snapshot into the pair root."
}

$missionExecutionArtifact = Finalize-MissionExecutionArtifacts `
    -SeedJsonPath $MissionExecutionSeedJsonPath `
    -PairRoot $pairRoot `
    -GuidedSessionRoot $guidedSessionRoot
$missionExecutionJsonPath = [string](Get-ObjectPropertyValue -Object $missionExecutionArtifact -Name "JsonPath" -Default "")
$missionExecutionMarkdownPath = [string](Get-ObjectPropertyValue -Object $missionExecutionArtifact -Name "MarkdownPath" -Default "")
$missionExecutionPayload = Get-ObjectPropertyValue -Object $missionExecutionArtifact -Name "Payload" -Default $null

$sessionStateArtifacts = [ordered]@{
    session_state_json = $sessionStateJsonPath
    pair_runner_stdout_log = $pairRunnerStdoutPath
    pair_runner_stderr_log = $pairRunnerStderrPath
    monitor_history_ndjson = $monitorHistoryPath
    mission_snapshot_json = $missionSnapshotJsonPath
    mission_snapshot_markdown = $missionSnapshotMarkdownPath
    mission_execution_json = $missionExecutionJsonPath
    mission_execution_markdown = $missionExecutionMarkdownPath
}

$null = Write-SessionStateFile `
    -Path $sessionStateJsonPath `
    -PairRoot $pairRoot `
    -GuidedSessionRoot $guidedSessionRoot `
    -Stage "pair-running" `
    -Status "active" `
    -Explanation "Guided pair capture is active. Recovery assessment should treat missing closeout artifacts as provisional until the pair runner exits." `
    -TreatmentProfile $resolvedProfile.name `
    -RunPostPipelineEnabled:$runPostPipelineEnabled `
    -Artifacts $sessionStateArtifacts

Write-Host "  Active pair root: $pairRoot"
Write-Host "  Final session docket JSON: $finalDocketJsonPath"
Write-Host "  Final session docket Markdown: $finalDocketMarkdownPath"
Write-Host "  Session state JSON: $sessionStateJsonPath"
Write-Host "  Mission snapshot JSON: $missionSnapshotJsonPath"
Write-Host "  Mission snapshot Markdown: $missionSnapshotMarkdownPath"
Write-Host "  Mission execution JSON: $missionExecutionJsonPath"
Write-Host "  Mission execution Markdown: $missionExecutionMarkdownPath"
Write-Host "  Monitor history NDJSON: $monitorHistoryPath"
if ($RehearsalMode) {
    Write-Host "  Rehearsal registry path: $postPipelineRegistryPath"
}
if ($autoStartMonitorEnabled) {
    Write-Host "  Monitor status: auto-started in guided mode"
}
else {
    Write-Host "  Monitor command: $monitorCommandText"
}

$lastMonitorStatus = $null
$autoStopTriggered = $false
$autoStopVerdict = ""

while ($true) {
    $pairProcess.Refresh()
    if ($pairProcess.HasExited) {
        break
    }

    if ($autoStartMonitorEnabled) {
        $lastMonitorStatus = Invoke-MonitorSnapshot `
            -MonitorScriptPath $monitorScriptPath `
            -PairRoot $pairRoot `
            -PollSeconds $MonitorPollSeconds `
            -ResolvedMinHumanSnapshots $MinHumanSnapshots `
            -ResolvedMinHumanPresenceSeconds $MinHumanPresenceSeconds `
            -ResolvedMinPatchEventsForUsableLane $MinPatchEventsForUsableLane `
            -ResolvedMinPostPatchObservationSeconds $MinPostPatchObservationSeconds `
            -LabRoot $LabRoot `
            -PythonPath $PythonPath

        Write-MonitorHistoryRecord -Path $monitorHistoryPath -MonitorStatus $lastMonitorStatus -Source "poll"

        $currentVerdict = [string](Get-ObjectPropertyValue -Object $lastMonitorStatus -Name "current_verdict" -Default "")
        if (
            $AutoStopWhenSufficient -and
            -not $autoStopTriggered -and
            $currentVerdict -in @("sufficient-for-tuning-usable-review", "sufficient-for-scorecard")
        ) {
            Write-Host "Guided auto-stop: sufficient evidence reached at verdict '$currentVerdict'."
            Write-StopRequest `
                -Path $stopSignalPath `
                -Reason "guided-auto-stop-when-sufficient" `
                -RequestedBy "run_guided_live_pair_session.ps1" `
                -Verdict $currentVerdict
            $autoStopTriggered = $true
            $autoStopVerdict = $currentVerdict
        }
    }

    Start-Sleep -Seconds $MonitorPollSeconds
}

while (-not $pairProcess.HasExited) {
    Start-Sleep -Seconds 1
    $pairProcess.Refresh()
}

$pairExitCode = $null
try {
    $pairProcess.WaitForExit()
    $pairProcess.Refresh()
    $pairExitCode = $pairProcess.ExitCode
}
catch {
    $pairExitCode = $null
}

$lastMonitorStatus = Invoke-MonitorSnapshot `
    -MonitorScriptPath $monitorScriptPath `
    -PairRoot $pairRoot `
    -PollSeconds $MonitorPollSeconds `
    -ResolvedMinHumanSnapshots $MinHumanSnapshots `
    -ResolvedMinHumanPresenceSeconds $MinHumanPresenceSeconds `
    -ResolvedMinPatchEventsForUsableLane $MinPatchEventsForUsableLane `
    -ResolvedMinPostPatchObservationSeconds $MinPostPatchObservationSeconds `
    -LabRoot $LabRoot `
    -PythonPath $PythonPath

Write-MonitorHistoryRecord -Path $monitorHistoryPath -MonitorStatus $lastMonitorStatus -Source "final"

$pairSummaryJsonPath = Join-Path $pairRoot "pair_summary.json"
if (-not (Test-Path -LiteralPath $pairSummaryJsonPath)) {
    throw "The pair runner completed without producing pair_summary.json under $pairRoot. ExitCode=$pairExitCode STDERR: $(Get-LogTailText -Path $pairRunnerStderrPath)"
}

$sessionStateArtifacts.pair_summary_json = $pairSummaryJsonPath
$sessionStateArtifacts.live_monitor_status_json = Join-Path $pairRoot "live_monitor_status.json"
$null = Write-SessionStateFile `
    -Path $sessionStateJsonPath `
    -PairRoot $pairRoot `
    -GuidedSessionRoot $guidedSessionRoot `
    -Stage "pair-run-complete" `
    -Status $(if ($runPostPipelineEnabled) { "awaiting-closeout" } else { "pair-finished" }) `
    -Explanation $(if ($runPostPipelineEnabled) { "The pair runner exited and produced pair_summary.json. Recovery may still be possible from this pair root even if post-pipeline closeout does not finish." } else { "The pair runner exited cleanly and post-pipeline closeout was disabled for this run." }) `
    -TreatmentProfile $resolvedProfile.name `
    -RunPostPipelineEnabled:$runPostPipelineEnabled `
    -MonitorStatus $lastMonitorStatus `
    -Artifacts $sessionStateArtifacts

$reviewResult = $null
$shadowResult = $null
$scoreResult = $null
$registerResult = $null
$registrySummaryResult = $null
$gateResult = $null
$nextLivePlanResult = $null
$outcomeDossierResult = $null
$missionAttainmentResult = $null
$registryIsolatedForRehearsal = -not [string]::IsNullOrWhiteSpace($postPipelineRegistryPath)

if ($runPostPipelineEnabled) {
    $null = Write-SessionStateFile `
        -Path $sessionStateJsonPath `
        -PairRoot $pairRoot `
        -GuidedSessionRoot $guidedSessionRoot `
        -Stage "post-pipeline-running" `
        -Status "active" `
        -Explanation "The pair run finished and the guided post-pipeline closeout is now running." `
        -TreatmentProfile $resolvedProfile.name `
        -RunPostPipelineEnabled:$runPostPipelineEnabled `
        -MonitorStatus $lastMonitorStatus `
        -Artifacts $sessionStateArtifacts

    $reviewResult = & $reviewScriptPath -PairRoot $pairRoot
    $shadowResult = & $shadowScriptPath -PairRoot $pairRoot -Profiles conservative, default, responsive
    $scoreResult = & $scoreScriptPath -PairRoot $pairRoot
    $registerArgs = @{
        PairRoot = $pairRoot
    }
    if ($postPipelineRegistryPath) {
        $registerArgs.RegistryPath = $postPipelineRegistryPath
    }
    $registerResult = & $registerScriptPath @registerArgs

    $summaryArgs = @{}
    if (-not $postPipelineRegistryPath) {
        $summaryArgs.LabRoot = $LabRoot
    }
    if ($rehearsalRegistryRoot) {
        $summaryArgs.OutputRoot = $rehearsalRegistryRoot
    }
    if ($registerResult -and $registerResult.RegistryPath) {
        $summaryArgs.RegistryPath = [string]$registerResult.RegistryPath
    }
    $registrySummaryResult = & $summaryScriptPath @summaryArgs

    $gateArgs = @{}
    if (-not $postPipelineRegistryPath) {
        $gateArgs.LabRoot = $LabRoot
    }
    if ($rehearsalRegistryRoot) {
        $gateArgs.OutputRoot = $rehearsalRegistryRoot
    }
    if ($registerResult -and $registerResult.RegistryPath) {
        $gateArgs.RegistryPath = [string]$registerResult.RegistryPath
    }
    $gateResult = & $gateScriptPath @gateArgs

    $plannerScriptPath = Join-Path $PSScriptRoot "plan_next_live_session.ps1"
    $plannerArgs = @{}
    if (-not $postPipelineRegistryPath) {
        $plannerArgs.LabRoot = $LabRoot
    }
    if ($rehearsalRegistryRoot) {
        $plannerArgs.OutputRoot = $rehearsalRegistryRoot
    }
    if ($registerResult -and $registerResult.RegistryPath) {
        $plannerArgs.RegistryPath = [string]$registerResult.RegistryPath
    }
    if ($registrySummaryResult -and $registrySummaryResult.RegistrySummaryJsonPath) {
        $plannerArgs.RegistrySummaryPath = [string]$registrySummaryResult.RegistrySummaryJsonPath
    }
    if ($registrySummaryResult -and $registrySummaryResult.ProfileRecommendationJsonPath) {
        $plannerArgs.ProfileRecommendationPath = [string]$registrySummaryResult.ProfileRecommendationJsonPath
    }
    if ($gateResult -and $gateResult.ResponsiveTrialGateJsonPath) {
        $plannerArgs.ResponsiveTrialGatePath = [string]$gateResult.ResponsiveTrialGateJsonPath
    }
    $nextLivePlanResult = & $plannerScriptPath @plannerArgs

    $outcomeDossierScriptPath = Join-Path $PSScriptRoot "build_latest_session_outcome_dossier.ps1"
    $dossierArgs = @{
        PairRoot = $pairRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($LabRoot)) {
        $dossierArgs.LabRoot = $LabRoot
    }
    $outcomeDossierResult = & $outcomeDossierScriptPath @dossierArgs

    $missionAttainmentScriptPath = Join-Path $PSScriptRoot "evaluate_latest_session_mission.ps1"
    $missionAttainmentArgs = @{
        PairRoot = $pairRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($LabRoot)) {
        $missionAttainmentArgs.LabRoot = $LabRoot
    }
    if ($registerResult -and $registerResult.RegistryPath) {
        $missionAttainmentArgs.RegistryPath = [string]$registerResult.RegistryPath
    }
    elseif ($postPipelineRegistryPath) {
        $missionAttainmentArgs.RegistryPath = $postPipelineRegistryPath
    }
    $missionAttainmentResult = & $missionAttainmentScriptPath @missionAttainmentArgs
}

$postPipelineSnapshot = Get-SessionStatePostPipelineSnapshot `
    -ReviewResult $reviewResult `
    -ShadowResult $shadowResult `
    -ScoreResult $scoreResult `
    -RegisterResult $registerResult `
    -RegistrySummaryResult $registrySummaryResult `
    -GateResult $gateResult `
    -OutcomeDossierResult $outcomeDossierResult `
    -MissionAttainmentResult $missionAttainmentResult `
    -RunPostPipelineEnabled:$runPostPipelineEnabled `
    -RegistryIsolatedForRehearsal:$registryIsolatedForRehearsal

$pairSummary = Read-JsonFile -Path $pairSummaryJsonPath
$scorecard = Read-JsonFile -Path (Join-Path $pairRoot "scorecard.json")
$shadowRecommendation = Read-JsonFile -Path (Join-Path $pairRoot "shadow_review\shadow_recommendation.json")
$profileRecommendationPath = if ($registrySummaryResult -and $registrySummaryResult.ProfileRecommendationJsonPath) {
    [string]$registrySummaryResult.ProfileRecommendationJsonPath
}
elseif ($rehearsalRegistryRoot) {
    Join-Path $rehearsalRegistryRoot "profile_recommendation.json"
}
else {
    Join-Path (Get-RegistryRootDefault -LabRoot $LabRoot) "profile_recommendation.json"
}
$responsiveTrialGatePath = if ($gateResult -and $gateResult.ResponsiveTrialGateJsonPath) {
    [string]$gateResult.ResponsiveTrialGateJsonPath
}
elseif ($rehearsalRegistryRoot) {
    Join-Path $rehearsalRegistryRoot "responsive_trial_gate.json"
}
else {
    Join-Path (Get-RegistryRootDefault -LabRoot $LabRoot) "responsive_trial_gate.json"
}
$profileRecommendation = Read-JsonFile -Path $profileRecommendationPath
$responsiveTrialGate = Read-JsonFile -Path $responsiveTrialGatePath
$nextLivePlanPath = if ($nextLivePlanResult -and $nextLivePlanResult.NextLivePlanJsonPath) {
    [string]$nextLivePlanResult.NextLivePlanJsonPath
}
elseif ($rehearsalRegistryRoot) {
    Join-Path $rehearsalRegistryRoot "next_live_plan.json"
}
else {
    Join-Path (Get-RegistryRootDefault -LabRoot $LabRoot) "next_live_plan.json"
}
$nextLivePlan = Read-JsonFile -Path $nextLivePlanPath
$nextLivePlanMarkdownPath = if ($nextLivePlanResult -and $nextLivePlanResult.NextLivePlanMarkdownPath) {
    [string]$nextLivePlanResult.NextLivePlanMarkdownPath
}
elseif ($rehearsalRegistryRoot) {
    Join-Path $rehearsalRegistryRoot "next_live_plan.md"
}
else {
    Join-Path (Get-RegistryRootDefault -LabRoot $LabRoot) "next_live_plan.md"
}
$outcomeDossierJsonPath = if ($outcomeDossierResult -and $outcomeDossierResult.SessionOutcomeDossierJsonPath) {
    [string]$outcomeDossierResult.SessionOutcomeDossierJsonPath
}
else {
    Join-Path $pairRoot "session_outcome_dossier.json"
}
$outcomeDossierMarkdownPath = if ($outcomeDossierResult -and $outcomeDossierResult.SessionOutcomeDossierMarkdownPath) {
    [string]$outcomeDossierResult.SessionOutcomeDossierMarkdownPath
}
else {
    Join-Path $pairRoot "session_outcome_dossier.md"
}
$missionAttainmentJsonPath = if ($missionAttainmentResult -and $missionAttainmentResult.MissionAttainmentJsonPath) {
    [string]$missionAttainmentResult.MissionAttainmentJsonPath
}
else {
    Join-Path $pairRoot "mission_attainment.json"
}
$missionAttainmentMarkdownPath = if ($missionAttainmentResult -and $missionAttainmentResult.MissionAttainmentMarkdownPath) {
    [string]$missionAttainmentResult.MissionAttainmentMarkdownPath
}
else {
    Join-Path $pairRoot "mission_attainment.md"
}
$missionAttainment = Read-JsonFile -Path $missionAttainmentJsonPath

$pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
$comparison = Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
$comparisonVerdict = [string](Get-ObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default "")
$scorecardRecommendation = [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation" -Default "")
$shadowDecision = [string](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "decision" -Default "")
$registryDecision = [string](Get-ObjectPropertyValue -Object $profileRecommendation -Name "decision" -Default "")
$registryRecommendedLiveProfile = [string](Get-ObjectPropertyValue -Object $profileRecommendation -Name "recommended_live_profile" -Default "")
$responsiveGateVerdict = [string](Get-ObjectPropertyValue -Object $responsiveTrialGate -Name "gate_verdict" -Default "")
$responsiveGateNextLiveAction = [string](Get-ObjectPropertyValue -Object $responsiveTrialGate -Name "next_live_action" -Default "")
$nextLiveSessionObjective = [string](Get-ObjectPropertyValue -Object $nextLivePlan -Name "recommended_next_session_objective" -Default "")
$nextLiveRecommendedLiveProfile = [string](Get-ObjectPropertyValue -Object $nextLivePlan -Name "recommended_next_live_profile" -Default "")
$operatorAction = Get-RecommendedOperatorAction `
    -ScorecardRecommendation $scorecardRecommendation `
    -ShadowDecision $shadowDecision `
    -RegistryDecision $registryDecision `
    -RegistryRecommendedLiveProfile $registryRecommendedLiveProfile `
    -ResponsiveGateVerdict $responsiveGateVerdict `
    -ResponsiveGateNextLiveAction $responsiveGateNextLiveAction

$monitorVerdict = [string](Get-ObjectPropertyValue -Object $lastMonitorStatus -Name "current_verdict" -Default "")
$syntheticFixture = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Default $false)
$rehearsalEvidence = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Default $false)
$validationOnly = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Default ($syntheticFixture -or $rehearsalEvidence))
$evidenceOrigin = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default $(if ($validationOnly) { "rehearsal" } else { "live" }))
$sessionSufficientForTuningUsableReview = $monitorVerdict -in @(
    "sufficient-for-tuning-usable-review",
    "sufficient-for-scorecard"
) -or $pairClassification -in @(
    "tuning-usable",
    "strong-signal"
) -or $comparisonVerdict -in @(
    "comparison-usable",
    "comparison-strong-signal"
)
$fullCloseoutCompleted = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "outcome_dossier_completed" -Default $false) -and [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "mission_attainment_completed" -Default $false)
$sessionStateFinalStatus = if (-not $runPostPipelineEnabled) {
    "pair-finished"
}
elseif ($fullCloseoutCompleted) {
    "complete"
}
else {
    "partial"
}
$sessionStateFinalExplanation = if ($fullCloseoutCompleted) {
    "The guided session completed the available closeout stack and wrote the final docket."
}
elseif ($runPostPipelineEnabled) {
    "The guided session wrote a final docket, but one or more closeout artifacts remain incomplete."
}
else {
    "The guided session finished the pair run and wrote a final docket without running the post-pipeline closeout stack."
}

$docket = [ordered]@{
    schema_version = 5
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    pair_root = $pairRoot
    guided_session_root = $guidedSessionRoot
    treatment_profile = $resolvedProfile.name
    session_sufficient_for_tuning_usable_review = $sessionSufficientForTuningUsableReview
    evidence = [ordered]@{
        synthetic_fixture = $syntheticFixture
        rehearsal_mode = $rehearsalEvidence
        evidence_origin = $evidenceOrigin
        validation_only = $validationOnly
    }
    preflight = [ordered]@{
        verdict = [string](Get-ObjectPropertyValue -Object $preflightResult -Name "Verdict" -Default "")
        warnings = @((Get-ObjectPropertyValue -Object $preflightResult -Name "Warnings" -Default @()))
        blockers = @((Get-ObjectPropertyValue -Object $preflightResult -Name "Blockers" -Default @()))
    }
    monitor = [ordered]@{
        auto_started = $autoStartMonitorEnabled
        auto_stop_when_sufficient = [bool]$AutoStopWhenSufficient
        auto_stop_triggered = $autoStopTriggered
        auto_stop_trigger_verdict = $autoStopVerdict
        last_verdict = $monitorVerdict
        last_explanation = [string](Get-ObjectPropertyValue -Object $lastMonitorStatus -Name "explanation" -Default "")
        stop_signal_path = $stopSignalPath
        monitor_command = $monitorCommandText
    }
    pair = [ordered]@{
        control_lane_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null) -Name "lane_verdict" -Default "")
        treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null) -Name "lane_verdict" -Default "")
        pair_classification = $pairClassification
        comparison_verdict = $comparisonVerdict
    }
    recommendations = [ordered]@{
        scorecard_recommendation = $scorecardRecommendation
        shadow_recommendation = $shadowDecision
        registry_recommendation_state = $registryDecision
        registry_recommended_live_profile = $registryRecommendedLiveProfile
        responsive_gate_verdict = $responsiveGateVerdict
        responsive_gate_next_live_action = $responsiveGateNextLiveAction
        next_live_session_objective = $nextLiveSessionObjective
        next_live_recommended_live_profile = $nextLiveRecommendedLiveProfile
        operator_action = [ordered]@{
            primary = $operatorAction.Primary
            keep_conservative = $operatorAction.KeepConservative
            collect_another_conservative_session = $operatorAction.CollectAnotherConservativeSession
            review_manually = $operatorAction.ReviewManually
            wait_before_considering_responsive = $operatorAction.WaitBeforeConsideringResponsive
        }
    }
    post_pipeline = [ordered]@{
        ran = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "enabled" -Default $false)
        review_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "review_completed" -Default $false)
        shadow_review_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "shadow_review_completed" -Default $false)
        scorecard_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "scorecard_completed" -Default $false)
        register_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "register_completed" -Default $false)
        registry_summary_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "registry_summary_completed" -Default $false)
        responsive_gate_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "responsive_gate_completed" -Default $false)
        outcome_dossier_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "outcome_dossier_completed" -Default $false)
        mission_attainment_completed = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "mission_attainment_completed" -Default $false)
        registry_isolated_for_rehearsal = [bool](Get-ObjectPropertyValue -Object $postPipelineSnapshot -Name "registry_isolated_for_rehearsal" -Default $false)
    }
    session_state = [ordered]@{
        path = $sessionStateJsonPath
        stage = "finalized"
        status = $sessionStateFinalStatus
        pair_run_completed = $true
        full_closeout_completed = $fullCloseoutCompleted
        explanation = $sessionStateFinalExplanation
    }
    mission_attainment = [ordered]@{
        verdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")
        mission_operational_success = [bool](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_operational_success" -Default $false)
        mission_grounded_success = [bool](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_grounded_success" -Default $false)
        mission_promotion_impact = [bool](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_promotion_impact" -Default $false)
        explanation = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "explanation" -Default "")
    }
    mission_execution = [ordered]@{
        available = $null -ne $missionExecutionPayload
        drift_policy_verdict = [string](Get-ObjectPropertyValue -Object $missionExecutionPayload -Name "drift_policy_verdict" -Default "")
        mission_compliant = [bool](Get-ObjectPropertyValue -Object $missionExecutionPayload -Name "mission_compliant" -Default $true)
        mission_divergent = [bool](Get-ObjectPropertyValue -Object $missionExecutionPayload -Name "mission_divergent" -Default $false)
        valid_for_mission_attainment_analysis = [bool](Get-ObjectPropertyValue -Object $missionExecutionPayload -Name "valid_for_mission_attainment_analysis" -Default $true)
        drift_detected = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionExecutionPayload -Name "drift_summary" -Default $null) -Name "drift_detected" -Default $false)
        explanation = [string](Get-ObjectPropertyValue -Object $missionExecutionPayload -Name "explanation" -Default "")
    }
    artifacts = [ordered]@{
        pair_summary_json = $pairSummaryJsonPath
        scorecard_json = Join-Path $pairRoot "scorecard.json"
        shadow_recommendation_json = Join-Path $pairRoot "shadow_review\shadow_recommendation.json"
        profile_recommendation_json = $profileRecommendationPath
        responsive_trial_gate_json = $responsiveTrialGatePath
        next_live_plan_json = $nextLivePlanPath
        next_live_plan_markdown = $nextLivePlanMarkdownPath
        mission_brief_json = $missionJsonPath
        mission_brief_markdown = $missionMarkdownPath
        mission_snapshot_json = $missionSnapshotJsonPath
        mission_snapshot_markdown = $missionSnapshotMarkdownPath
        mission_execution_json = $missionExecutionJsonPath
        mission_execution_markdown = $missionExecutionMarkdownPath
        session_state_json = $sessionStateJsonPath
        registry_path = if ($registerResult -and $registerResult.RegistryPath) { [string]$registerResult.RegistryPath } elseif ($postPipelineRegistryPath) { $postPipelineRegistryPath } else { Join-Path (Get-RegistryRootDefault -LabRoot $LabRoot) "pair_sessions.ndjson" }
        monitor_history_ndjson = $monitorHistoryPath
        rehearsal_metadata_json = Join-Path $pairRoot "rehearsal_metadata.json"
        pair_runner_stdout_log = $pairRunnerStdoutPath
        pair_runner_stderr_log = $pairRunnerStderrPath
        final_session_docket_json = $finalDocketJsonPath
        final_session_docket_markdown = $finalDocketMarkdownPath
        session_outcome_dossier_json = $outcomeDossierJsonPath
        session_outcome_dossier_markdown = $outcomeDossierMarkdownPath
        mission_attainment_json = $missionAttainmentJsonPath
        mission_attainment_markdown = $missionAttainmentMarkdownPath
    }
}

Write-JsonFile -Path $finalDocketJsonPath -Value $docket
Write-TextFile -Path $finalDocketMarkdownPath -Value (Get-FinalSessionDocketMarkdown -Docket $docket)

$sessionStateArtifacts.final_session_docket_json = $finalDocketJsonPath
$sessionStateArtifacts.final_session_docket_markdown = $finalDocketMarkdownPath
$sessionStateArtifacts.scorecard_json = Join-Path $pairRoot "scorecard.json"
$sessionStateArtifacts.shadow_recommendation_json = Join-Path $pairRoot "shadow_review\shadow_recommendation.json"
$sessionStateArtifacts.session_outcome_dossier_json = $outcomeDossierJsonPath
$sessionStateArtifacts.session_outcome_dossier_markdown = $outcomeDossierMarkdownPath
$sessionStateArtifacts.mission_attainment_json = $missionAttainmentJsonPath
$sessionStateArtifacts.mission_attainment_markdown = $missionAttainmentMarkdownPath
$null = Write-SessionStateFile `
    -Path $sessionStateJsonPath `
    -PairRoot $pairRoot `
    -GuidedSessionRoot $guidedSessionRoot `
    -Stage "finalized" `
    -Status $sessionStateFinalStatus `
    -Explanation $sessionStateFinalExplanation `
    -TreatmentProfile $resolvedProfile.name `
    -RunPostPipelineEnabled:$runPostPipelineEnabled `
    -MonitorStatus $lastMonitorStatus `
    -Artifacts $sessionStateArtifacts `
    -PostPipeline $postPipelineSnapshot

$missionVerdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")

Write-Host "Guided live pair session finished."
Write-Host "  Pair root: $pairRoot"
Write-Host "  Session state JSON: $sessionStateJsonPath"
Write-Host "  Final session docket JSON: $finalDocketJsonPath"
Write-Host "  Final session docket Markdown: $finalDocketMarkdownPath"
Write-Host "  Outcome dossier JSON: $outcomeDossierJsonPath"
Write-Host "  Outcome dossier Markdown: $outcomeDossierMarkdownPath"
Write-Host "  Mission attainment JSON: $missionAttainmentJsonPath"
Write-Host "  Mission attainment Markdown: $missionAttainmentMarkdownPath"
Write-Host "  Last live monitor verdict: $monitorVerdict"
Write-Host "  Scorecard recommendation: $scorecardRecommendation"
Write-Host "  Shadow recommendation: $shadowDecision"
Write-Host "  Registry recommendation: $registryDecision"
Write-Host "  Responsive gate verdict: $responsiveGateVerdict"
Write-Host "  Next-live planner objective: $nextLiveSessionObjective"
Write-Host "  Mission verdict: $missionVerdict"
Write-Host "  Evidence origin: $evidenceOrigin"
Write-Host "  Primary operator action: $($operatorAction.Primary)"

[pscustomobject]@{
    PairRoot = $pairRoot
    SessionStateJsonPath = $sessionStateJsonPath
    FinalSessionDocketJsonPath = $finalDocketJsonPath
    FinalSessionDocketMarkdownPath = $finalDocketMarkdownPath
    MissionBriefJsonPath = $missionJsonPath
    MissionBriefMarkdownPath = $missionMarkdownPath
    MissionExecutionJsonPath = $missionExecutionJsonPath
    MissionExecutionMarkdownPath = $missionExecutionMarkdownPath
    OutcomeDossierJsonPath = $outcomeDossierJsonPath
    OutcomeDossierMarkdownPath = $outcomeDossierMarkdownPath
    MissionAttainmentJsonPath = $missionAttainmentJsonPath
    MissionAttainmentMarkdownPath = $missionAttainmentMarkdownPath
    MonitorVerdict = $monitorVerdict
    EvidenceOrigin = $evidenceOrigin
    ScorecardRecommendation = $scorecardRecommendation
    ShadowRecommendation = $shadowDecision
    RegistryRecommendation = $registryDecision
    ResponsiveGateVerdict = $responsiveGateVerdict
    MissionVerdict = $missionVerdict
    PrimaryOperatorAction = $operatorAction.Primary
}
