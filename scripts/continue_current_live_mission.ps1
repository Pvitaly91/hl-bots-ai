[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$RegistryPath = "",
    [string]$OutputJson = "",
    [string]$OutputMarkdown = "",
    [switch]$Execute,
    [switch]$DryRun,
    [switch]$AllowMissionOverride,
    [switch]$RerunWithNewPairRoot,
    [switch]$ForceReviewOnly
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

function Find-LatestPairRoot {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Pairs root was not found: $Root"
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No pair_summary.json files were found under $Root"
    }

    return $candidate.DirectoryName
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

function Build-CommandString {
    param([string[]]$Arguments)

    return (@($Arguments) | ForEach-Object { Format-ProcessArgument -Value ([string]$_) }) -join " "
}

function Resolve-MissionPaths {
    param([string]$ResolvedLabRoot)

    $prepareScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"
    $defaultMissionPath = Join-Path (Get-RegistryRootDefault -LabRoot $ResolvedLabRoot) "next_live_session_mission.json"

    $resolvedMissionPath = Resolve-ExistingPath -Path $defaultMissionPath
    if (-not $resolvedMissionPath) {
        $preparedMission = & $prepareScriptPath -LabRoot $ResolvedLabRoot
        $resolvedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionJsonPath" -Default ""))
    }

    if (-not $resolvedMissionPath) {
        return [pscustomobject]@{
            JsonPath = ""
            MarkdownPath = ""
        }
    }

    return [pscustomobject]@{
        JsonPath = $resolvedMissionPath
        MarkdownPath = (Resolve-ExistingPath -Path ([System.IO.Path]::ChangeExtension($resolvedMissionPath, ".md")))
    }
}

function Get-RecoveryAssessmentInfo {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedLabRoot,
        [string]$ResolvedRegistryPath
    )

    $assessmentScriptPath = Join-Path $PSScriptRoot "assess_latest_session_recovery.ps1"
    $assessmentResult = & $assessmentScriptPath -PairRoot $ResolvedPairRoot -LabRoot $ResolvedLabRoot -RegistryPath $ResolvedRegistryPath

    $reportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $assessmentResult -Name "SessionRecoveryReportJsonPath" -Default (Join-Path $ResolvedPairRoot "session_recovery_report.json")))
    $reportMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $assessmentResult -Name "SessionRecoveryReportMarkdownPath" -Default (Join-Path $ResolvedPairRoot "session_recovery_report.md")))
    $report = Read-JsonFile -Path $reportJsonPath
    if ($null -eq $report) {
        throw "Recovery report could not be parsed: $reportJsonPath"
    }

    return [ordered]@{
        report = $report
        json_path = $reportJsonPath
        markdown_path = $reportMarkdownPath
    }
}

function Get-MissionContext {
    param(
        [object]$RecoveryReport,
        [string]$ResolvedLabRoot,
        [bool]$AllowMissionOverrideForRerun
    )

    $artifactBlock = Get-ObjectPropertyValue -Object $RecoveryReport -Name "artifacts" -Default $null
    $savedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifactBlock -Name "mission_snapshot_json" -Default ""))
    $savedMissionMarkdownPath = if ($savedMissionPath) {
        Resolve-ExistingPath -Path ([System.IO.Path]::ChangeExtension($savedMissionPath, ".md"))
    }
    else {
        ""
    }

    $missionExecutionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $artifactBlock -Name "mission_execution_json" -Default ""))
    $missionExecution = Read-JsonFile -Path $missionExecutionPath
    $executionReferencedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionExecution -Name "mission_path_used" -Default ""))
    $executionReferencedMissionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $missionExecution -Name "mission_markdown_path_used" -Default ""))

    $currentMissionPaths = Resolve-MissionPaths -ResolvedLabRoot $ResolvedLabRoot
    $currentMissionPath = Resolve-ExistingPath -Path $currentMissionPaths.JsonPath
    $currentMissionMarkdownPath = Resolve-ExistingPath -Path $currentMissionPaths.MarkdownPath

    $savedMissionHash = if ($savedMissionPath) { Get-FileSha256 -Path $savedMissionPath } else { "" }
    $executionReferencedMissionHash = if ($executionReferencedMissionPath) { Get-FileSha256 -Path $executionReferencedMissionPath } else { "" }
    $currentMissionHash = if ($currentMissionPath) { Get-FileSha256 -Path $currentMissionPath } else { "" }

    $currentMatchesSaved = $savedMissionHash -and $currentMissionHash -and ($savedMissionHash -eq $currentMissionHash)
    $trustedSavedMissionContext = -not [string]::IsNullOrWhiteSpace($savedMissionPath)

    $selectedMissionPath = ""
    $selectedMissionMarkdownPath = ""
    $selectedMissionSource = ""
    $rerunLaunchClassification = ""
    $explanation = ""

    if ($AllowMissionOverrideForRerun -and $currentMissionPath) {
        $selectedMissionPath = $currentMissionPath
        $selectedMissionMarkdownPath = $currentMissionMarkdownPath
        $selectedMissionSource = "current-mission-brief"
        $rerunLaunchClassification = if ($currentMatchesSaved) { "mission-compliant-rerun" } else { "mission-recovered-rerun" }
        if ($trustedSavedMissionContext -and -not $currentMatchesSaved) {
            $explanation = "Using the current mission brief for rerun because -AllowMissionOverride was supplied and the saved mission context differs from the current mission."
        }
        else {
            $explanation = "Using the current mission brief for rerun."
        }
    }
    elseif ($trustedSavedMissionContext) {
        $selectedMissionPath = $savedMissionPath
        $selectedMissionMarkdownPath = $savedMissionMarkdownPath
        $selectedMissionSource = "pair-mission-snapshot"
        $rerunLaunchClassification = "mission-compliant-rerun"
        $explanation = "Using the saved pair-scoped mission snapshot so the rerun stays aligned with the interrupted mission."
    }
    elseif ($executionReferencedMissionPath) {
        $selectedMissionPath = $executionReferencedMissionPath
        $selectedMissionMarkdownPath = $executionReferencedMissionMarkdownPath
        $selectedMissionSource = "mission-execution-reference"
        $rerunLaunchClassification = "mission-recovered-rerun"
        $explanation = "The pair-scoped mission snapshot is missing, so rerun falls back to the mission path referenced by the saved mission execution artifact."
    }
    elseif ($currentMissionPath) {
        $selectedMissionPath = $currentMissionPath
        $selectedMissionMarkdownPath = $currentMissionMarkdownPath
        $selectedMissionSource = "current-mission-brief"
        $rerunLaunchClassification = "mission-recovered-rerun"
        $explanation = "No saved mission snapshot was available, so rerun falls back to the current mission brief."
    }

    return [ordered]@{
        trusted_saved_mission_context = $trustedSavedMissionContext
        saved_mission_json_path = $savedMissionPath
        saved_mission_markdown_path = $savedMissionMarkdownPath
        saved_mission_sha256 = $savedMissionHash
        mission_execution_json_path = $missionExecutionPath
        execution_referenced_mission_json_path = $executionReferencedMissionPath
        execution_referenced_mission_markdown_path = $executionReferencedMissionMarkdownPath
        execution_referenced_mission_sha256 = $executionReferencedMissionHash
        current_mission_json_path = $currentMissionPath
        current_mission_markdown_path = $currentMissionMarkdownPath
        current_mission_sha256 = $currentMissionHash
        current_matches_saved_mission = $currentMatchesSaved
        selected_rerun_mission_json_path = $selectedMissionPath
        selected_rerun_mission_markdown_path = $selectedMissionMarkdownPath
        selected_rerun_mission_source = $selectedMissionSource
        rerun_launch_classification = $rerunLaunchClassification
        explanation = $explanation
    }
}

function Get-RerunContext {
    param(
        [string]$ResolvedPairRoot,
        [object]$RecoveryReport
    )

    $pairSummary = Read-JsonFile -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
    $rehearsalMetadata = Read-JsonFile -Path (Join-Path $ResolvedPairRoot "rehearsal_metadata.json")
    $evidence = Get-ObjectPropertyValue -Object $RecoveryReport -Name "evidence" -Default $null

    $rehearsalMode = [bool](Get-ObjectPropertyValue -Object $evidence -Name "rehearsal_mode" -Default $false)
    if (-not $rehearsalMode) {
        $rehearsalMode = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Default $false)
    }

    $evidenceOrigin = [string](Get-ObjectPropertyValue -Object $evidence -Name "evidence_origin" -Default "")
    if (-not $evidenceOrigin) {
        $evidenceOrigin = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default "")
    }

    $validationOnly = [bool](Get-ObjectPropertyValue -Object $evidence -Name "validation_only" -Default $false)
    if (-not $validationOnly) {
        $validationOnly = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Default $false)
    }

    $fixtureId = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "fixture_id" -Default "")
    if (-not $fixtureId) {
        $fixtureId = [string](Get-ObjectPropertyValue -Object $rehearsalMetadata -Name "fixture_id" -Default "")
    }

    $rerunAsRehearsal = $rehearsalMode -or ($evidenceOrigin -eq "rehearsal")
    $outputRoot = ""
    try {
        $outputRoot = (Split-Path -Path $ResolvedPairRoot -Parent)
    }
    catch {
        $outputRoot = ""
    }

    $explanation = if ($rerunAsRehearsal) {
        "The assessed pair is rehearsal-backed, so reruns stay in rehearsal mode and reuse the same parent output root."
    }
    elseif ($outputRoot) {
        "Reruns will reuse the current pair's parent output root so the new attempt stays adjacent to the interrupted session."
    }
    else {
        "No pair-local rerun context was detected."
    }

    return [ordered]@{
        rerun_as_rehearsal = $rerunAsRehearsal
        rehearsal_fixture_id = $fixtureId
        evidence_origin = $evidenceOrigin
        validation_only = $validationOnly
        output_root = $outputRoot
        explanation = $explanation
    }
}

function Get-RerunLaunchInfo {
    param(
        [object]$MissionContext,
        [object]$RerunContext,
        [string]$ResolvedLabRoot
    )

    $missionPath = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "selected_rerun_mission_json_path" -Default "")
    $missionMarkdownPath = [string](Get-ObjectPropertyValue -Object $MissionContext -Name "selected_rerun_mission_markdown_path" -Default "")
    $rerunArgs = [ordered]@{
        MissionPath = $missionPath
        LabRoot = $ResolvedLabRoot
    }
    $commandArgs = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\run_current_live_mission.ps1",
        "-MissionPath",
        $missionPath
    )

    if ($missionMarkdownPath) {
        $rerunArgs.MissionMarkdownPath = $missionMarkdownPath
        $commandArgs += @("-MissionMarkdownPath", $missionMarkdownPath)
    }

    $outputRoot = [string](Get-ObjectPropertyValue -Object $RerunContext -Name "output_root" -Default "")
    if ($outputRoot) {
        $rerunArgs.OutputRoot = $outputRoot
        $commandArgs += @("-OutputRoot", $outputRoot)
    }

    if ([bool](Get-ObjectPropertyValue -Object $RerunContext -Name "rerun_as_rehearsal" -Default $false)) {
        $rerunArgs.RehearsalMode = $true
        $commandArgs += "-RehearsalMode"

        $fixtureId = [string](Get-ObjectPropertyValue -Object $RerunContext -Name "rehearsal_fixture_id" -Default "")
        if ($fixtureId) {
            $rerunArgs.RehearsalFixtureId = $fixtureId
            $commandArgs += @("-RehearsalFixtureId", $fixtureId)
        }
    }

    return [ordered]@{
        rerun_args = $rerunArgs
        command_args = $commandArgs
    }
}

function Get-DecisionCommandList {
    param(
        [string]$DecisionBranch,
        [string]$ResolvedPairRoot,
        [object]$MissionContext,
        [object]$RerunContext,
        [switch]$ForceNewPairRoot
    )

    $commands = @(
        (Build-CommandString -Arguments @(
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ".\scripts\continue_current_live_mission.ps1",
                "-PairRoot",
                $ResolvedPairRoot
            ))
    )

    switch ($DecisionBranch) {
        "salvage-interrupted-session" {
            $commands += (Build-CommandString -Arguments @(
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    ".\scripts\continue_current_live_mission.ps1",
                    "-PairRoot",
                    $ResolvedPairRoot,
                    "-Execute"
                ))
            $commands += (Build-CommandString -Arguments @(
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    ".\scripts\finalize_interrupted_session.ps1",
                    "-PairRoot",
                    $ResolvedPairRoot
                ))
        }
        "rerun-current-mission" {
            $rerunLaunchInfo = Get-RerunLaunchInfo -MissionContext $MissionContext -RerunContext $RerunContext -ResolvedLabRoot ""
            $rerunArgs = @($rerunLaunchInfo.command_args)

            $commands += (Build-CommandString -Arguments @(
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    ".\scripts\continue_current_live_mission.ps1",
                    "-PairRoot",
                    $ResolvedPairRoot,
                    "-Execute"
                ))
            $commands += (Build-CommandString -Arguments $rerunArgs)
        }
        "rerun-current-mission-with-new-pair-root" {
            $rerunLaunchInfo = Get-RerunLaunchInfo -MissionContext $MissionContext -RerunContext $RerunContext -ResolvedLabRoot ""
            $rerunArgs = @($rerunLaunchInfo.command_args)

            $controllerArgs = @(
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ".\scripts\continue_current_live_mission.ps1",
                "-PairRoot",
                $ResolvedPairRoot,
                "-Execute"
            )
            $controllerArgs += "-RerunWithNewPairRoot"

            $commands += (Build-CommandString -Arguments $controllerArgs)
            $commands += (Build-CommandString -Arguments $rerunArgs)
        }
    }

    return @($commands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-DecisionMarkdown {
    param([object]$Decision)

    $lines = @(
        "# Mission Continuation Decision",
        "",
        "- Pair root: $($Decision.pair_root)",
        "- Selection mode: $($Decision.selection_mode)",
        "- Prompt ID: $($Decision.prompt_id)",
        "- Controller mode: $($Decision.controller_mode)",
        "- Continuation decision: $($Decision.continuation_decision)",
        "- Action required: $($Decision.action_required)",
        "- Explanation: $($Decision.explanation)",
        "",
        "## Recovery Context",
        "",
        "- Recovery verdict: $($Decision.recovery.recovery_verdict)",
        "- Recommended next action: $($Decision.recovery.recommended_next_action)",
        "- Recovery explanation: $($Decision.recovery.explanation)",
        "- Session complete: $($Decision.recovery.session_complete)",
        "- Session interrupted: $($Decision.recovery.session_interrupted)",
        "- Salvageable without replay: $($Decision.recovery.salvageable_without_replay)",
        "",
        "## Mission Context",
        "",
        "- Saved mission snapshot: $($Decision.mission_context.saved_mission_json_path)",
        "- Mission execution artifact: $($Decision.mission_context.mission_execution_json_path)",
        "- Current mission brief: $($Decision.mission_context.current_mission_json_path)",
        "- Selected rerun mission: $($Decision.mission_context.selected_rerun_mission_json_path)",
        "- Selected rerun source: $($Decision.mission_context.selected_rerun_mission_source)",
        "- Rerun launch classification: $($Decision.mission_context.rerun_launch_classification)",
        "- Mission-context explanation: $($Decision.mission_context.explanation)",
        "",
        "## Promotion Handling",
        "",
        "- Registration disposition now: $($Decision.certification_context.registration_disposition)",
        "- Counts toward grounded certification now: $($Decision.certification_context.count_toward_grounded_certification_now)",
        "- Exclude from promotion logic now: $($Decision.certification_context.exclude_from_promotion_logic_now)",
        "- Promotion explanation: $($Decision.certification_context.explanation)",
        "",
        "## Execution",
        "",
        "- Requested execute mode: $($Decision.execution.execute_requested)",
        "- Execution attempted: $($Decision.execution.attempted)",
        "- Execution status: $($Decision.execution.status)",
        "- Downstream action: $($Decision.execution.action)",
        "- Downstream command: $($Decision.execution.downstream_command)",
        "- Execution explanation: $($Decision.execution.explanation)",
        "",
        "## Linked Artifacts",
        ""
    )

    foreach ($property in $Decision.linked_artifacts.PSObject.Properties) {
        $lines += "- $($property.Name): $($property.Value)"
    }

    if (@($Decision.suggested_commands).Count -gt 0) {
        $lines += ""
        $lines += "## Suggested Commands"
        $lines += ""
        foreach ($command in @($Decision.suggested_commands)) {
            $lines += "- $command"
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if ($Execute -and $DryRun) {
    throw "Use either -Execute or -DryRun. The controller stays preview-first unless -Execute is supplied."
}
if ($UseLatest -and -not [string]::IsNullOrWhiteSpace($PairRoot)) {
    throw "Use either -UseLatest or -PairRoot, not both."
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Get-LabRootDefault
}
else {
    Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot
}
$resolvedPairsRoot = if ([string]::IsNullOrWhiteSpace($PairsRoot)) {
    Get-PairsRootDefault -LabRoot $resolvedLabRoot
}
else {
    Get-AbsolutePath -Path $PairsRoot -BasePath $repoRoot
}
$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}

$selectionMode = "latest-pair-root"
$resolvedPairRoot = ""
if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
    $selectionMode = "explicit-pair-root"
    $resolvedPairRoot = Get-AbsolutePath -Path $PairRoot -BasePath $repoRoot
}
else {
    if ($UseLatest) {
        $selectionMode = "latest-pair-root"
    }
    $resolvedPairRoot = Find-LatestPairRoot -Root $resolvedPairsRoot
}

$resolvedPairRoot = Resolve-ExistingPath -Path $resolvedPairRoot
if (-not $resolvedPairRoot) {
    throw "Pair root could not be resolved."
}

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    Join-Path $resolvedPairRoot "mission_continuation_decision.json"
}
else {
    Get-AbsolutePath -Path $OutputJson -BasePath $resolvedPairRoot
}
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    Join-Path $resolvedPairRoot "mission_continuation_decision.md"
}
else {
    Get-AbsolutePath -Path $OutputMarkdown -BasePath $resolvedPairRoot
}

$decisionBranch = ""
$decisionExplanation = ""
$actionRequired = $false
$blockedDecision = $false
$executionAction = ""
$executionAttempted = $false
$executionStatus = if ($Execute) { "pending" } elseif ($DryRun) { "dry-run-preview" } else { "preview-only" }
$executionExplanation = ""
$downstreamCommand = ""
$executionError = ""
$salvageReportJsonPath = ""
$salvageReportMarkdownPath = ""
$rerunPairRoot = ""
$rerunMissionExecutionJsonPath = ""
$rerunMissionExecutionMarkdownPath = ""
$rerunFinalSessionDocketJsonPath = ""
$rerunFinalSessionDocketMarkdownPath = ""
$rerunMissionAttainmentJsonPath = ""
$rerunMissionAttainmentMarkdownPath = ""
$report = $null
$shouldThrowAfterWrite = $false
$postActionRecoveryVerdict = ""
$postActionRegistrationDisposition = ""

$recoveryInfo = Get-RecoveryAssessmentInfo -ResolvedPairRoot $resolvedPairRoot -ResolvedLabRoot $resolvedLabRoot -ResolvedRegistryPath $resolvedRegistryPath
$recoveryReport = $recoveryInfo.report
$recoveryVerdict = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "recovery_verdict" -Default "")
$recommendedNextAction = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "recommended_next_action" -Default "")
$recoveryState = Get-ObjectPropertyValue -Object $recoveryReport -Name "recovery_state" -Default $null
$certificationContext = Get-ObjectPropertyValue -Object $recoveryReport -Name "certification_registry" -Default $null
$certificationContextForReport = $certificationContext
$artifactBlock = Get-ObjectPropertyValue -Object $recoveryReport -Name "artifacts" -Default $null
$missionContext = Get-MissionContext -RecoveryReport $recoveryReport -ResolvedLabRoot $resolvedLabRoot -AllowMissionOverrideForRerun ([bool]$AllowMissionOverride)
$rerunContext = Get-RerunContext -ResolvedPairRoot $resolvedPairRoot -RecoveryReport $recoveryReport

switch ($recoveryVerdict) {
    "session-complete" {
        if ($ForceReviewOnly) {
            $decisionBranch = "session-already-complete-review-only"
            $decisionExplanation = "The session is already structurally complete. ForceReviewOnly keeps the controller in review mode and does not rerun or salvage anything."
        }
        else {
            $decisionBranch = "session-already-complete-no-action"
            $decisionExplanation = "The latest assessed session is already structurally complete. No salvage or rerun is needed."
        }
    }
    "session-complete-pending-review-only" {
        $decisionBranch = "session-already-complete-review-only"
        $decisionExplanation = "The session finished structurally, but one of the review layers still wants operator inspection."
    }
    "session-interrupted-after-sufficiency-before-closeout" {
        $decisionBranch = "salvage-interrupted-session"
        $decisionExplanation = "The saved evidence already cleared the sufficiency gate, so the controller chooses the supported salvage path instead of replaying the live run."
        $actionRequired = $true
    }
    "session-interrupted-during-post-pipeline" {
        $decisionBranch = "salvage-interrupted-session"
        $decisionExplanation = "The live evidence is sufficient and the closeout stack only needs a conservative rebuild, so the controller chooses salvage."
        $actionRequired = $true
    }
    "session-partial-artifacts-recoverable" {
        $decisionBranch = "salvage-interrupted-session"
        $decisionExplanation = "The raw pair evidence survives, but closeout artifacts are partial or stale. The controller chooses salvage instead of spending a new live run."
        $actionRequired = $true
    }
    "session-interrupted-before-sufficiency" {
        $decisionBranch = if ($RerunWithNewPairRoot -or $recommendedNextAction -eq "rerun-current-mission-with-new-pair-root") {
            "rerun-current-mission-with-new-pair-root"
        }
        else {
            "rerun-current-mission"
        }
        $decisionExplanation = "The interrupted session never reached sufficiency, so salvage would overclaim the evidence. The controller chooses rerun."
        $actionRequired = $true
    }
    "session-nonrecoverable-rerun-required" {
        $decisionBranch = "rerun-current-mission-with-new-pair-root"
        $decisionExplanation = "Critical raw artifacts are missing, so the interrupted run cannot be trusted or salvaged. The controller chooses a clean rerun with a new pair root."
        $actionRequired = $true
    }
    "session-manual-review-needed" {
        $decisionBranch = "manual-review-required"
        $decisionExplanation = "The recovery assessment already says the artifact set is too inconsistent for automatic continuation."
    }
    default {
        $decisionBranch = "manual-review-required"
        $decisionExplanation = "The controller does not recognize the recovery verdict well enough to automate continuation safely."
    }
}

if ($decisionBranch -like "rerun-current-mission*") {
    $selectedRerunMissionPath = [string](Get-ObjectPropertyValue -Object $missionContext -Name "selected_rerun_mission_json_path" -Default "")
    if (-not $selectedRerunMissionPath) {
        $decisionBranch = "blocked-no-mission-context"
        $decisionExplanation = "Recovery says this session should be rerun, but neither a trustworthy saved mission context nor a current mission brief could be resolved. Stop for manual review instead of guessing a rerun shape."
        $actionRequired = $false
        $blockedDecision = $true
    }
}

$registrationDisposition = [string](Get-ObjectPropertyValue -Object $certificationContext -Name "registration_disposition" -Default "")
$promotionExplanation = [string](Get-ObjectPropertyValue -Object $certificationContext -Name "explanation" -Default "")
if ($decisionBranch -in @("session-already-complete-no-action", "session-already-complete-review-only") -and $registrationDisposition -and $registrationDisposition -ne "grounded-evidence") {
    $decisionExplanation += " The saved session remains excluded from promotion as '$registrationDisposition'."
}

$suggestedCommands = Get-DecisionCommandList -DecisionBranch $decisionBranch -ResolvedPairRoot $resolvedPairRoot -MissionContext $missionContext -RerunContext $rerunContext -ForceNewPairRoot:$RerunWithNewPairRoot

try {
    switch ($decisionBranch) {
        "session-already-complete-no-action" {
            $executionStatus = "no-action-needed"
            $executionExplanation = "The controller left the completed session alone."
        }
        "session-already-complete-review-only" {
            $executionStatus = "review-only"
            $executionExplanation = "The controller did not mutate the completed session. Review the linked artifacts instead."
        }
        "manual-review-required" {
            $executionStatus = "manual-review-required"
            $executionExplanation = $decisionExplanation
            if ($Execute) {
                $shouldThrowAfterWrite = $true
            }
        }
        "blocked-no-mission-context" {
            $executionStatus = "blocked-no-mission-context"
            $executionExplanation = $decisionExplanation
            $blockedDecision = $true
            if ($Execute) {
                $shouldThrowAfterWrite = $true
            }
        }
        "salvage-interrupted-session" {
            $executionAction = "salvage-interrupted-session"
            $downstreamCommand = Build-CommandString -Arguments @(
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                ".\scripts\finalize_interrupted_session.ps1",
                "-PairRoot",
                $resolvedPairRoot
            )

            if ($Execute) {
                $executionAttempted = $true
                $salvageResult = & (Join-Path $PSScriptRoot "finalize_interrupted_session.ps1") -PairRoot $resolvedPairRoot -LabRoot $resolvedLabRoot -RegistryPath $resolvedRegistryPath
                $salvageReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $salvageResult -Name "SessionSalvageReportJsonPath" -Default (Join-Path $resolvedPairRoot "session_salvage_report.json")))
                $salvageReportMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $salvageResult -Name "SessionSalvageReportMarkdownPath" -Default (Join-Path $resolvedPairRoot "session_salvage_report.md")))
                $salvageReport = Read-JsonFile -Path $salvageReportJsonPath
                $afterRecovery = Get-ObjectPropertyValue -Object $salvageReport -Name "after_recovery" -Default $null
                $postActionRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $afterRecovery -Name "recovery_verdict" -Default "")
                $afterCertificationContext = Get-ObjectPropertyValue -Object $afterRecovery -Name "certification_registry" -Default $null
                if ($afterCertificationContext) {
                    $certificationContextForReport = $afterCertificationContext
                    $postActionRegistrationDisposition = [string](Get-ObjectPropertyValue -Object $afterCertificationContext -Name "registration_disposition" -Default "")
                }
                $executionStatus = "completed"
                $executionExplanation = "The controller ran the salvage helper and the follow-up recovery path completed successfully."
            }
            else {
                $executionStatus = if ($DryRun) { "dry-run-preview" } else { "preview-only" }
                $executionExplanation = "The controller previewed the salvage decision without mutating the pair."
            }
        }
        "rerun-current-mission" {
            $executionAction = "rerun-current-mission"
            $rerunLaunchInfo = Get-RerunLaunchInfo -MissionContext $missionContext -RerunContext $rerunContext -ResolvedLabRoot $resolvedLabRoot
            $rerunArgs = $rerunLaunchInfo.rerun_args
            $downstreamCommand = Build-CommandString -Arguments $rerunLaunchInfo.command_args

            if ($Execute) {
                $executionAttempted = $true
                $rerunResult = & (Join-Path $PSScriptRoot "run_current_live_mission.ps1") @rerunArgs
                $rerunPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "PairRoot" -Default ""))
                $rerunMissionExecutionJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionExecutionJsonPath" -Default ""))
                $rerunMissionExecutionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionExecutionMarkdownPath" -Default ""))
                $rerunFinalSessionDocketJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "FinalSessionDocketJsonPath" -Default ""))
                $rerunFinalSessionDocketMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "FinalSessionDocketMarkdownPath" -Default ""))
                $rerunMissionAttainmentJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionAttainmentJsonPath" -Default ""))
                $rerunMissionAttainmentMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionAttainmentMarkdownPath" -Default ""))
                $executionStatus = "completed"
                $executionExplanation = if ([bool](Get-ObjectPropertyValue -Object $rerunContext -Name "rerun_as_rehearsal" -Default $false)) {
                    "The controller started a rehearsal-scoped rerun from the selected mission context."
                }
                else {
                    "The controller started a rerun from the selected mission context."
                }
            }
            else {
                $executionStatus = if ($DryRun) { "dry-run-preview" } else { "preview-only" }
                $executionExplanation = "The controller previewed the rerun path without launching a new pair."
            }
        }
        "rerun-current-mission-with-new-pair-root" {
            $executionAction = "rerun-current-mission-with-new-pair-root"
            $rerunLaunchInfo = Get-RerunLaunchInfo -MissionContext $missionContext -RerunContext $rerunContext -ResolvedLabRoot $resolvedLabRoot
            $rerunArgs = $rerunLaunchInfo.rerun_args
            $downstreamCommand = Build-CommandString -Arguments $rerunLaunchInfo.command_args

            if ($Execute) {
                $executionAttempted = $true
                $rerunResult = & (Join-Path $PSScriptRoot "run_current_live_mission.ps1") @rerunArgs
                $rerunPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "PairRoot" -Default ""))
                $rerunMissionExecutionJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionExecutionJsonPath" -Default ""))
                $rerunMissionExecutionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionExecutionMarkdownPath" -Default ""))
                $rerunFinalSessionDocketJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "FinalSessionDocketJsonPath" -Default ""))
                $rerunFinalSessionDocketMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "FinalSessionDocketMarkdownPath" -Default ""))
                $rerunMissionAttainmentJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionAttainmentJsonPath" -Default ""))
                $rerunMissionAttainmentMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rerunResult -Name "MissionAttainmentMarkdownPath" -Default ""))
                $executionStatus = "completed"
                $executionExplanation = if ([bool](Get-ObjectPropertyValue -Object $rerunContext -Name "rerun_as_rehearsal" -Default $false)) {
                    "The controller started a clean rehearsal rerun. The guided workflow created a new pair root for the new attempt."
                }
                else {
                    "The controller started a clean rerun. The guided workflow created a new pair root for the new attempt."
                }
            }
            else {
                $executionStatus = if ($DryRun) { "dry-run-preview" } else { "preview-only" }
                $executionExplanation = "The controller previewed the clean rerun path without launching a new pair."
            }
        }
    }
}
catch {
    $executionStatus = "failed"
    $executionError = $_.Exception.Message
    if (-not $executionExplanation) {
        $executionExplanation = $executionError
    }
    $shouldThrowAfterWrite = $true
}

$linkedArtifacts = [ordered]@{
    recovery_report_json = $recoveryInfo.json_path
    recovery_report_markdown = $recoveryInfo.markdown_path
    mission_snapshot_json = [string](Get-ObjectPropertyValue -Object $artifactBlock -Name "mission_snapshot_json" -Default "")
    mission_execution_json = [string](Get-ObjectPropertyValue -Object $artifactBlock -Name "mission_execution_json" -Default "")
    final_session_docket_json = [string](Get-ObjectPropertyValue -Object $artifactBlock -Name "final_session_docket_json" -Default "")
    mission_attainment_json = [string](Get-ObjectPropertyValue -Object $artifactBlock -Name "mission_attainment_json" -Default "")
    session_outcome_dossier_json = [string](Get-ObjectPropertyValue -Object $artifactBlock -Name "session_outcome_dossier_json" -Default "")
    next_live_session_mission_json = [string](Get-ObjectPropertyValue -Object $missionContext -Name "current_mission_json_path" -Default "")
    next_live_session_mission_markdown = [string](Get-ObjectPropertyValue -Object $missionContext -Name "current_mission_markdown_path" -Default "")
    selected_rerun_mission_json = [string](Get-ObjectPropertyValue -Object $missionContext -Name "selected_rerun_mission_json_path" -Default "")
    selected_rerun_mission_markdown = [string](Get-ObjectPropertyValue -Object $missionContext -Name "selected_rerun_mission_markdown_path" -Default "")
    session_salvage_report_json = $salvageReportJsonPath
    session_salvage_report_markdown = $salvageReportMarkdownPath
    rerun_pair_root = $rerunPairRoot
    rerun_mission_execution_json = $rerunMissionExecutionJsonPath
    rerun_mission_execution_markdown = $rerunMissionExecutionMarkdownPath
    rerun_final_session_docket_json = $rerunFinalSessionDocketJsonPath
    rerun_final_session_docket_markdown = $rerunFinalSessionDocketMarkdownPath
    rerun_mission_attainment_json = $rerunMissionAttainmentJsonPath
    rerun_mission_attainment_markdown = $rerunMissionAttainmentMarkdownPath
    mission_continuation_decision_json = $outputJsonPath
    mission_continuation_decision_markdown = $outputMarkdownPath
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    selection_mode = $selectionMode
    controller_mode = if ($Execute) { "execute" } elseif ($DryRun) { "dry-run" } else { "preview" }
    pair_root = $resolvedPairRoot
    continuation_decision = $decisionBranch
    action_required = $actionRequired
    explanation = $decisionExplanation
    blocked = $blockedDecision
    recovery = [ordered]@{
        recovery_verdict = $recoveryVerdict
        recommended_next_action = $recommendedNextAction
        explanation = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "explanation" -Default "")
        session_complete = [bool](Get-ObjectPropertyValue -Object $recoveryState -Name "session_complete" -Default $false)
        session_interrupted = [bool](Get-ObjectPropertyValue -Object $recoveryState -Name "session_interrupted" -Default $false)
        salvageable_without_replay = [bool](Get-ObjectPropertyValue -Object $recoveryState -Name "salvageable_without_replay" -Default $false)
        manual_review_required = [bool](Get-ObjectPropertyValue -Object $recoveryState -Name "manual_review_required" -Default $false)
        nonrecoverable = [bool](Get-ObjectPropertyValue -Object $recoveryState -Name "nonrecoverable" -Default $false)
    }
    mission_context = $missionContext
    rerun_context = $rerunContext
    certification_context = [ordered]@{
        registration_disposition = [string](Get-ObjectPropertyValue -Object $certificationContextForReport -Name "registration_disposition" -Default $registrationDisposition)
        count_toward_grounded_certification_now = [bool](Get-ObjectPropertyValue -Object $certificationContextForReport -Name "count_toward_grounded_certification_now" -Default $false)
        exclude_from_promotion_logic_now = [bool](Get-ObjectPropertyValue -Object $certificationContextForReport -Name "exclude_from_promotion_logic_now" -Default $true)
        register_only_as_workflow_validation_now = [bool](Get-ObjectPropertyValue -Object $certificationContextForReport -Name "register_only_as_workflow_validation_now" -Default $false)
        register_only_as_non_grounded_now = [bool](Get-ObjectPropertyValue -Object $certificationContextForReport -Name "register_only_as_non_grounded_now" -Default $false)
        explanation = [string](Get-ObjectPropertyValue -Object $certificationContextForReport -Name "explanation" -Default $promotionExplanation)
    }
    linked_artifacts = $linkedArtifacts
    suggested_commands = $suggestedCommands
    execution = [ordered]@{
        execute_requested = [bool]$Execute
        attempted = $executionAttempted
        status = $executionStatus
        action = $executionAction
        downstream_command = $downstreamCommand
        explanation = $executionExplanation
        post_action_recovery_verdict = $postActionRecoveryVerdict
        post_action_registration_disposition = $postActionRegistrationDisposition
        error_message = $executionError
    }
}

Write-JsonFile -Path $outputJsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputJsonPath
Write-TextFile -Path $outputMarkdownPath -Value (Get-DecisionMarkdown -Decision $reportForMarkdown)

Write-Host "Mission continuation controller:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Continuation decision: $decisionBranch"
Write-Host "  Controller mode: $(if ($Execute) { "execute" } elseif ($DryRun) { "dry-run" } else { "preview" })"
Write-Host "  Execution status: $executionStatus"
Write-Host "  Decision report JSON: $outputJsonPath"
Write-Host "  Decision report Markdown: $outputMarkdownPath"

if ($shouldThrowAfterWrite) {
    if ($executionError) {
        throw $executionError
    }

    throw $decisionExplanation
}

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    ContinuationDecision = $decisionBranch
    ActionRequired = $actionRequired
    ExecutionStatus = $executionStatus
    MissionContinuationDecisionJsonPath = $outputJsonPath
    MissionContinuationDecisionMarkdownPath = $outputMarkdownPath
    RerunPairRoot = $rerunPairRoot
    SessionSalvageReportJsonPath = $salvageReportJsonPath
}
