[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$FailureModes = @(
        "already-complete",
        "after-sufficiency-before-closeout",
        "during-post-pipeline",
        "before-sufficiency",
        "missing-mission-snapshot",
        "partial-artifacts-recoverable"
    ),
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$BasePairRoot = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$RehearsalFixtureId = "strong_signal_keep_conservative",
    [int]$RehearsalStepSeconds = 2,
    [int]$MonitorPollSeconds = 1,
    [switch]$PreviewOnly
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

    $json = $Value | ConvertTo-Json -Depth 30
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

function Get-GateArtifactPath {
    param([string]$PairRoot)

    foreach ($candidate in @(
            (Join-Path $PairRoot "guided_session\registry\responsive_trial_gate.json"),
            (Join-Path $PairRoot "responsive_trial_gate.json"),
            (Join-Path $PairRoot "analysis_scenarios\with_latest\responsive_trial_gate.json")
        )) {
        $resolved = Resolve-ExistingPath -Path $candidate
        if ($resolved) {
            return $resolved
        }
    }

    return ""
}

function Get-BranchControllerArgs {
    param(
        [object]$RecoveryReport,
        [bool]$PreviewOnlyMode
    )

    $verdict = [string](Get-ObjectPropertyValue -Object $RecoveryReport -Name "recovery_verdict" -Default "")
    $args = [ordered]@{}

    if ($PreviewOnlyMode) {
        $args.DryRun = $true
        return $args
    }

    if ($verdict -in @(
            "session-interrupted-after-sufficiency-before-closeout",
            "session-interrupted-during-post-pipeline",
            "session-partial-artifacts-recoverable",
            "session-interrupted-before-sufficiency",
            "session-nonrecoverable-rerun-required"
        )) {
        $args.Execute = $true
        return $args
    }

    $args.DryRun = $true
    return $args
}

function Get-ContinuationRehearsalMarkdown {
    param([object]$Report)

    $lines = @(
        "# Mission Continuation Rehearsal",
        "",
        "- Prompt ID: $($Report.prompt_id)",
        "- Failure mode: $($Report.failure_mode)",
        "- Mission path used: $($Report.mission_path_used)",
        "- Branch pair root: $($Report.branch_pair_root)",
        "- Initial recovery verdict: $($Report.initial_recovery_verdict)",
        "- Continuation decision: $($Report.continuation_decision)",
        "- Controller execution status: $($Report.controller_execution_status)",
        "- Salvage ran: $($Report.salvage_ran)",
        "- Rerun selected: $($Report.rerun_selected)",
        "- Manual review selected: $($Report.manual_review_selected)",
        "- Result pair root: $($Report.result_pair_root)",
        "- Final recovery verdict: $($Report.final_recovery_verdict)",
        "- Structurally complete after continuation: $($Report.structurally_complete_after_continuation)",
        "- Excluded from promotion after continuation: $($Report.promotion_safety.exclude_from_promotion_logic_now)",
        "- Registration disposition after continuation: $($Report.promotion_safety.registration_disposition)",
        "- Responsive gate verdict after continuation: $($Report.promotion_safety.responsive_gate_verdict)",
        "- Explanation: $($Report.explanation)",
        "",
        "## Artifacts",
        "",
        "- Recovery report JSON: $($Report.artifacts.recovery_report_json)",
        "- Continuation decision JSON: $($Report.artifacts.continuation_decision_json)",
        "- Session salvage report JSON: $($Report.artifacts.session_salvage_report_json)",
        "- Final session docket JSON: $($Report.artifacts.final_session_docket_json)",
        "- Mission attainment JSON: $($Report.artifacts.mission_attainment_json)",
        "- Failure injection report JSON: $($Report.artifacts.failure_injection_report_json)",
        "",
        "## Promotion Safety",
        "",
        "- Rehearsal mode: $($Report.promotion_safety.rehearsal_mode)",
        "- Validation only: $($Report.promotion_safety.validation_only)",
        "- Register only as workflow validation now: $($Report.promotion_safety.register_only_as_workflow_validation_now)",
        "- Count toward grounded certification now: $($Report.promotion_safety.count_toward_grounded_certification_now)",
        "- Exclude from promotion logic now: $($Report.promotion_safety.exclude_from_promotion_logic_now)",
        "- Responsive gate next live action: $($Report.promotion_safety.responsive_gate_next_live_action)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-RehearsalSuiteSummaryMarkdown {
    param([object]$Summary)

    $lines = @(
        "# Mission Continuation Rehearsal Suite Summary",
        "",
        "- Prompt ID: $($Summary.prompt_id)",
        "- Mission path used: $($Summary.mission_path_used)",
        "- Base pair root: $($Summary.base_pair_root)",
        "- Suite root: $($Summary.suite_root)",
        ""
    )

    foreach ($branch in @($Summary.branches)) {
        $lines += "- $($branch.failure_mode): initial=$($branch.initial_recovery_verdict); decision=$($branch.continuation_decision); final=$($branch.final_recovery_verdict); excluded=$($branch.exclude_from_promotion_logic_now); rerun_pair_root=$($branch.rerun_pair_root)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedLabRoot = if ($LabRoot) { Get-AbsolutePath -Path $LabRoot } else { Get-LabRootDefault }
$suiteStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$suiteRoot = if ($OutputRoot) {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
}
else {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) ("continuation_rehearsal\suite-{0}" -f $suiteStamp))
}
$runtimeRoot = Ensure-Directory -Path (Join-Path $suiteRoot "runtime")
$branchesRoot = Ensure-Directory -Path (Join-Path $suiteRoot "branches")

$basePairRootResolved = ""
$missionPathUsed = ""
$missionMarkdownPathUsed = ""
$baseMissionExecutionJsonPath = ""
$baseFinalSessionDocketJsonPath = ""
$baseMissionAttainmentJsonPath = ""

if ($BasePairRoot) {
    $basePairRootResolved = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $BasePairRoot)
    if (-not $basePairRootResolved) {
        throw "BasePairRoot was not found: $BasePairRoot"
    }
}
else {
    $launchArgs = [ordered]@{
        LabRoot = $resolvedLabRoot
        OutputRoot = $runtimeRoot
        RehearsalMode = $true
        RehearsalFixtureId = $RehearsalFixtureId
        RehearsalStepSeconds = $RehearsalStepSeconds
        AutoStopWhenSufficient = $true
        MonitorPollSeconds = $MonitorPollSeconds
    }

    if ($MissionPath) {
        $launchArgs.MissionPath = Get-AbsolutePath -Path $MissionPath
    }
    if ($MissionMarkdownPath) {
        $launchArgs.MissionMarkdownPath = Get-AbsolutePath -Path $MissionMarkdownPath
    }

    $launchResult = & (Join-Path $PSScriptRoot "run_current_live_mission.ps1") @launchArgs
    $basePairRootResolved = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchResult -Name "PairRoot" -Default ""))
    $missionPathUsed = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchResult -Name "MissionPath" -Default ""))
    $missionMarkdownPathUsed = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchResult -Name "MissionMarkdownPath" -Default ""))
    $baseMissionExecutionJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchResult -Name "MissionExecutionJsonPath" -Default ""))
    $baseFinalSessionDocketJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchResult -Name "FinalSessionDocketJsonPath" -Default ""))
    $baseMissionAttainmentJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $launchResult -Name "MissionAttainmentJsonPath" -Default ""))
}

if (-not $missionPathUsed) {
    $baseMissionExecution = Read-JsonFile -Path (Join-Path $basePairRootResolved "guided_session\mission_execution.json")
    $missionPathUsed = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $baseMissionExecution -Name "mission_path_used" -Default ""))
    $missionMarkdownPathUsed = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $baseMissionExecution -Name "mission_markdown_path_used" -Default ""))
}

$branchReports = @()
foreach ($failureMode in @($FailureModes)) {
    $branchPairRoot = Join-Path $branchesRoot $failureMode
    $injectResult = & (Join-Path $PSScriptRoot "inject_pair_session_failure.ps1") -FailureMode $failureMode -SourcePairRoot $basePairRootResolved -InjectedPairRoot $branchPairRoot -LabRoot $resolvedLabRoot
    $branchPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $injectResult -Name "PairRoot" -Default $branchPairRoot))
    $failureInjectionReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $injectResult -Name "FailureInjectionReportJsonPath" -Default (Join-Path $branchPairRoot "failure_injection_report.json")))

    $initialRecoveryResult = & (Join-Path $PSScriptRoot "assess_latest_session_recovery.ps1") -PairRoot $branchPairRoot -LabRoot $resolvedLabRoot
    $initialRecoveryReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $initialRecoveryResult -Name "SessionRecoveryReportJsonPath" -Default (Join-Path $branchPairRoot "session_recovery_report.json")))
    $initialRecoveryReport = Read-JsonFile -Path $initialRecoveryReportJsonPath

    $controllerArgs = [ordered]@{
        PairRoot = $branchPairRoot
        LabRoot = $resolvedLabRoot
    }
    foreach ($controllerFlag in (Get-BranchControllerArgs -RecoveryReport $initialRecoveryReport -PreviewOnlyMode ([bool]$PreviewOnly)).GetEnumerator()) {
        $controllerArgs[$controllerFlag.Key] = $controllerFlag.Value
    }

    $continuationResult = & (Join-Path $PSScriptRoot "continue_current_live_mission.ps1") @controllerArgs
    $continuationDecisionJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $continuationResult -Name "MissionContinuationDecisionJsonPath" -Default (Join-Path $branchPairRoot "mission_continuation_decision.json")))
    $continuationDecisionReport = Read-JsonFile -Path $continuationDecisionJsonPath
    $sessionSalvageReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $continuationResult -Name "SessionSalvageReportJsonPath" -Default (Join-Path $branchPairRoot "session_salvage_report.json")))

    $continuationDecision = [string](Get-ObjectPropertyValue -Object $continuationDecisionReport -Name "continuation_decision" -Default "")
    $rerunPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $continuationDecisionReport -Name "linked_artifacts" -Default $null) -Name "rerun_pair_root" -Default ""))
    $resultPairRoot = if ($rerunPairRoot) { $rerunPairRoot } else { $branchPairRoot }

    $finalRecoveryResult = & (Join-Path $PSScriptRoot "assess_latest_session_recovery.ps1") -PairRoot $resultPairRoot -LabRoot $resolvedLabRoot
    $finalRecoveryReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $finalRecoveryResult -Name "SessionRecoveryReportJsonPath" -Default (Join-Path $resultPairRoot "session_recovery_report.json")))
    $finalRecoveryReport = Read-JsonFile -Path $finalRecoveryReportJsonPath
    $finalCertification = Get-ObjectPropertyValue -Object $finalRecoveryReport -Name "certification_registry" -Default $null
    $finalEvidence = Get-ObjectPropertyValue -Object $finalRecoveryReport -Name "evidence" -Default $null

    $finalSessionDocketJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $continuationDecisionReport -Name "linked_artifacts" -Default $null) -Name "rerun_final_session_docket_json" -Default (Join-Path $resultPairRoot "guided_session\final_session_docket.json")))
    if (-not $finalSessionDocketJsonPath) {
        $finalSessionDocketJsonPath = Resolve-ExistingPath -Path (Join-Path $resultPairRoot "guided_session\final_session_docket.json")
    }

    $missionAttainmentJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $continuationDecisionReport -Name "linked_artifacts" -Default $null) -Name "rerun_mission_attainment_json" -Default (Join-Path $resultPairRoot "mission_attainment.json")))
    if (-not $missionAttainmentJsonPath) {
        $missionAttainmentJsonPath = Resolve-ExistingPath -Path (Join-Path $resultPairRoot "mission_attainment.json")
    }

    $outcomeDossierJsonPath = Resolve-ExistingPath -Path (Join-Path $resultPairRoot "session_outcome_dossier.json")
    $gateJsonPath = Get-GateArtifactPath -PairRoot $resultPairRoot
    $gateReport = Read-JsonFile -Path $gateJsonPath

    $report = [ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        suite_root = $suiteRoot
        base_pair_root = $basePairRootResolved
        mission_path_used = $missionPathUsed
        mission_markdown_path_used = $missionMarkdownPathUsed
        failure_mode = $failureMode
        branch_pair_root = $branchPairRoot
        initial_recovery_verdict = [string](Get-ObjectPropertyValue -Object $initialRecoveryReport -Name "recovery_verdict" -Default "")
        initial_recommended_next_action = [string](Get-ObjectPropertyValue -Object $initialRecoveryReport -Name "recommended_next_action" -Default "")
        continuation_decision = $continuationDecision
        controller_execution_status = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $continuationDecisionReport -Name "execution" -Default $null) -Name "status" -Default "")
        salvage_ran = -not [string]::IsNullOrWhiteSpace($sessionSalvageReportJsonPath)
        rerun_selected = $continuationDecision -like "rerun-current-mission*"
        manual_review_selected = $continuationDecision -eq "manual-review-required" -or $continuationDecision -eq "blocked-no-mission-context"
        rerun_pair_root = $rerunPairRoot
        result_pair_root = $resultPairRoot
        final_recovery_verdict = [string](Get-ObjectPropertyValue -Object $finalRecoveryReport -Name "recovery_verdict" -Default "")
        structurally_complete_after_continuation = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $finalRecoveryReport -Name "closeout" -Default $null) -Name "guided_closeout_complete" -Default $false)
        final_closeout_artifacts_exist = [ordered]@{
            final_session_docket = -not [string]::IsNullOrWhiteSpace($finalSessionDocketJsonPath)
            mission_attainment = -not [string]::IsNullOrWhiteSpace($missionAttainmentJsonPath)
            session_outcome_dossier = -not [string]::IsNullOrWhiteSpace($outcomeDossierJsonPath)
        }
        promotion_safety = [ordered]@{
            rehearsal_mode = [bool](Get-ObjectPropertyValue -Object $finalEvidence -Name "rehearsal_mode" -Default $false)
            validation_only = [bool](Get-ObjectPropertyValue -Object $finalEvidence -Name "validation_only" -Default $false)
            registration_disposition = [string](Get-ObjectPropertyValue -Object $finalCertification -Name "registration_disposition" -Default "")
            register_only_as_workflow_validation_now = [bool](Get-ObjectPropertyValue -Object $finalCertification -Name "register_only_as_workflow_validation_now" -Default $false)
            count_toward_grounded_certification_now = [bool](Get-ObjectPropertyValue -Object $finalCertification -Name "count_toward_grounded_certification_now" -Default $false)
            exclude_from_promotion_logic_now = [bool](Get-ObjectPropertyValue -Object $finalCertification -Name "exclude_from_promotion_logic_now" -Default $true)
            responsive_gate_verdict = [string](Get-ObjectPropertyValue -Object $gateReport -Name "gate_verdict" -Default "")
            responsive_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $gateReport -Name "next_live_action" -Default "")
        }
        artifacts = [ordered]@{
            failure_injection_report_json = $failureInjectionReportJsonPath
            recovery_report_json = $initialRecoveryReportJsonPath
            continuation_decision_json = $continuationDecisionJsonPath
            session_salvage_report_json = $sessionSalvageReportJsonPath
            final_session_docket_json = $finalSessionDocketJsonPath
            mission_attainment_json = $missionAttainmentJsonPath
            responsive_trial_gate_json = $gateJsonPath
        }
        explanation = [string](Get-ObjectPropertyValue -Object $continuationDecisionReport -Name "explanation" -Default "")
    }

    $branchReportJsonPath = Join-Path $branchPairRoot "continuation_rehearsal_report.json"
    $branchReportMarkdownPath = Join-Path $branchPairRoot "continuation_rehearsal_report.md"
    Write-JsonFile -Path $branchReportJsonPath -Value $report
    $reportForMarkdown = Read-JsonFile -Path $branchReportJsonPath
    Write-TextFile -Path $branchReportMarkdownPath -Value (Get-ContinuationRehearsalMarkdown -Report $reportForMarkdown)

    $branchReports += [pscustomobject]@{
        failure_mode = $failureMode
        initial_recovery_verdict = $report.initial_recovery_verdict
        continuation_decision = $report.continuation_decision
        final_recovery_verdict = $report.final_recovery_verdict
        exclude_from_promotion_logic_now = $report.promotion_safety.exclude_from_promotion_logic_now
        rerun_pair_root = $report.rerun_pair_root
        continuation_rehearsal_report_json = $branchReportJsonPath
    }
}

$suiteSummaryJsonPath = Join-Path $suiteRoot "rehearsal_suite_summary.json"
$suiteSummaryMarkdownPath = Join-Path $suiteRoot "rehearsal_suite_summary.md"
$suiteSummary = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    suite_root = $suiteRoot
    base_pair_root = $basePairRootResolved
    mission_path_used = $missionPathUsed
    mission_markdown_path_used = $missionMarkdownPathUsed
    base_mission_execution_json = $baseMissionExecutionJsonPath
    base_final_session_docket_json = $baseFinalSessionDocketJsonPath
    base_mission_attainment_json = $baseMissionAttainmentJsonPath
    branches = @($branchReports)
}

Write-JsonFile -Path $suiteSummaryJsonPath -Value $suiteSummary
$suiteSummaryForMarkdown = Read-JsonFile -Path $suiteSummaryJsonPath
Write-TextFile -Path $suiteSummaryMarkdownPath -Value (Get-RehearsalSuiteSummaryMarkdown -Summary $suiteSummaryForMarkdown)

Write-Host "Mission continuation rehearsal:"
Write-Host "  Suite root: $suiteRoot"
Write-Host "  Base pair root: $basePairRootResolved"
Write-Host "  Mission path used: $missionPathUsed"
Write-Host "  Rehearsed failure modes: $(@($FailureModes) -join ', ')"
Write-Host "  Suite summary JSON: $suiteSummaryJsonPath"
Write-Host "  Suite summary Markdown: $suiteSummaryMarkdownPath"

[pscustomobject]@{
    SuiteRoot = $suiteRoot
    BasePairRoot = $basePairRootResolved
    MissionPathUsed = $missionPathUsed
    RehearsalSuiteSummaryJsonPath = $suiteSummaryJsonPath
    RehearsalSuiteSummaryMarkdownPath = $suiteSummaryMarkdownPath
}
