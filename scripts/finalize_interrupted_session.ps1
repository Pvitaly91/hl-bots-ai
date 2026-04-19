[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$RegistryPath = "",
    [string]$RecoveryReportPath = "",
    [string]$OutputJson = "",
    [string]$OutputMarkdown = ""
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
        return $Path
    }

    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        return Join-Path $BasePath $Path
    }

    return Join-Path (Get-RepoRoot) $Path
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

function Convert-ToOrderedMap {
    param([object]$InputObject)

    $map = [ordered]@{}
    if ($null -eq $InputObject) {
        return $map
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $map[[string]$key] = $InputObject[$key]
        }
        return $map
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Merge-ObjectMap {
    param(
        [object]$BaseObject,
        [System.Collections.IDictionary]$Updates
    )

    $merged = Convert-ToOrderedMap -InputObject $BaseObject
    foreach ($key in $Updates.Keys) {
        $merged[$key] = $Updates[$key]
    }

    return $merged
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

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    try {
        $normalizedPath = [System.IO.Path]::GetFullPath($Path)
        $normalizedRoot = [System.IO.Path]::GetFullPath($Root)
    }
    catch {
        return $false
    }

    if (-not $normalizedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $normalizedRoot += [System.IO.Path]::DirectorySeparatorChar
    }

    return $normalizedPath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ArtifactTimestampUtc {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-Item -LiteralPath $Path).LastWriteTimeUtc
}

function Test-DerivedArtifactStale {
    param(
        [string]$Path,
        [object]$ReferenceTimestampUtc
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path) -or $null -eq $ReferenceTimestampUtc) {
        return $false
    }

    $artifactTimestampUtc = Get-ArtifactTimestampUtc -Path $Path
    if ($null -eq $artifactTimestampUtc) {
        return $false
    }

    return $artifactTimestampUtc -lt $ReferenceTimestampUtc
}

function Get-RecoveryAssessmentInfo {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedLabRoot,
        [string]$ResolvedRegistryPath,
        [string]$ExplicitRecoveryReportPath
    )

    $assessmentScriptPath = Join-Path $PSScriptRoot "assess_latest_session_recovery.ps1"
    $reportPath = ""
    $report = $null

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRecoveryReportPath)) {
        $reportPath = Resolve-ExistingPath -Path $ExplicitRecoveryReportPath
        if (-not $reportPath) {
            throw "Recovery report was not found: $ExplicitRecoveryReportPath"
        }

        $report = Read-JsonFile -Path $reportPath
        if ($null -eq $report) {
            throw "Recovery report could not be parsed: $reportPath"
        }

        $reportPairRoot = [string](Get-ObjectPropertyValue -Object $report -Name "pair_root" -Default "")
        if ($reportPairRoot -and ($reportPairRoot -ne $ResolvedPairRoot)) {
            throw "Recovery report '$reportPath' does not match pair root '$ResolvedPairRoot'."
        }
    }
    else {
        $assessmentArgs = @{
            PairRoot = $ResolvedPairRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($ResolvedLabRoot)) {
            $assessmentArgs.LabRoot = $ResolvedLabRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($ResolvedRegistryPath)) {
            $assessmentArgs.RegistryPath = $ResolvedRegistryPath
        }

        $assessmentResult = & $assessmentScriptPath @assessmentArgs
        $reportPath = [string](Get-ObjectPropertyValue -Object $assessmentResult -Name "SessionRecoveryReportJsonPath" -Default "")
        if (-not $reportPath) {
            $reportPath = Join-Path $ResolvedPairRoot "session_recovery_report.json"
        }
        $report = Read-JsonFile -Path $reportPath
        if ($null -eq $report) {
            throw "Recovery assessment did not produce a readable report under $ResolvedPairRoot."
        }
    }

    return [ordered]@{
        report = $report
        json_path = $reportPath
        markdown_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $report -Name "artifacts" -Default $null) -Name "session_recovery_report_markdown" -Default (Join-Path $ResolvedPairRoot "session_recovery_report.md"))
    }
}

function Get-RegistryContext {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedLabRoot,
        [string]$ExplicitRegistryPath,
        [object]$PairSummary,
        [object]$SessionState,
        [object]$FinalDocket,
        [object]$RecoveryReport
    )

    $guidedSessionRoot = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session")
    $guidedRegistryRootCandidate = if ($guidedSessionRoot) {
        Join-Path $guidedSessionRoot "registry"
    }
    else {
        ""
    }
    $guidedRegistryRoot = if ($guidedRegistryRootCandidate) {
        Resolve-ExistingPath -Path $guidedRegistryRootCandidate
    }
    else {
        ""
    }

    $sessionStateArtifacts = Get-ObjectPropertyValue -Object $SessionState -Name "artifacts" -Default $null
    $docketArtifacts = Get-ObjectPropertyValue -Object $FinalDocket -Name "artifacts" -Default $null
    $postPipeline = Get-ObjectPropertyValue -Object $SessionState -Name "post_pipeline" -Default $null
    $recoveryCloseout = Get-ObjectPropertyValue -Object $RecoveryReport -Name "closeout" -Default $null

    $shouldIsolateForRehearsal = [bool](Get-ObjectPropertyValue -Object $postPipeline -Name "registry_isolated_for_rehearsal" -Default $false) -or
        [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "rehearsal_mode" -Default $false) -or
        [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "validation_only" -Default $false) -or
        [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "synthetic_fixture" -Default $false)

    $registryPathCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitRegistryPath)) {
        $registryPathCandidates += (Get-AbsolutePath -Path $ExplicitRegistryPath -BasePath (Get-RepoRoot))
    }
    $registryPathCandidates += [string](Get-ObjectPropertyValue -Object $sessionStateArtifacts -Name "registry_path" -Default "")
    $registryPathCandidates += [string](Get-ObjectPropertyValue -Object $docketArtifacts -Name "registry_path" -Default "")
    if ($shouldIsolateForRehearsal -and $guidedRegistryRootCandidate) {
        $registryPathCandidates += (Join-Path $guidedRegistryRootCandidate "pair_sessions.ndjson")
    }
    if ($guidedRegistryRoot) {
        $registryPathCandidates += (Join-Path $guidedRegistryRoot "pair_sessions.ndjson")
    }
    $registryPathCandidates += (Join-Path (Get-RegistryRootDefault -LabRoot $ResolvedLabRoot) "pair_sessions.ndjson")

    $resolvedRegistryPath = ""
    foreach ($candidate in $registryPathCandidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if ([System.IO.Path]::IsPathRooted($candidate)) {
            $resolvedRegistryPath = $candidate
        }
        else {
            $resolvedRegistryPath = Get-AbsolutePath -Path $candidate -BasePath (Get-RepoRoot)
        }

        break
    }

    $registryIsolatedForRehearsal = $shouldIsolateForRehearsal -or
        [bool](Get-ObjectPropertyValue -Object $recoveryCloseout -Name "guided_session_detected" -Default $false) -and
        (Test-PathWithinRoot -Path $resolvedRegistryPath -Root $ResolvedPairRoot) -or
        [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "rehearsal_mode" -Default $false)

    $outputRootCandidates = @(
        [string](Get-ObjectPropertyValue -Object $docketArtifacts -Name "next_live_plan_json" -Default ""),
        [string](Get-ObjectPropertyValue -Object $docketArtifacts -Name "profile_recommendation_json" -Default ""),
        [string](Get-ObjectPropertyValue -Object $docketArtifacts -Name "responsive_trial_gate_json" -Default "")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $resolvedOutputRoot = ""
    foreach ($candidate in $outputRootCandidates) {
        if (Test-PathWithinRoot -Path $candidate -Root $ResolvedPairRoot) {
            $resolvedOutputRoot = Split-Path -Path $candidate -Parent
            break
        }
    }

    if (-not $resolvedOutputRoot) {
        if ($registryIsolatedForRehearsal -and $guidedRegistryRootCandidate) {
            $resolvedOutputRoot = $guidedRegistryRootCandidate
        }
        else {
            $resolvedOutputRoot = Split-Path -Path $resolvedRegistryPath -Parent
        }
    }

    return [ordered]@{
        guided_session_root = $guidedSessionRoot
        registry_path = $resolvedRegistryPath
        output_root = $resolvedOutputRoot
        registry_isolated_for_rehearsal = $registryIsolatedForRehearsal
        registry_summary_json = Join-Path $resolvedOutputRoot "registry_summary.json"
        profile_recommendation_json = Join-Path $resolvedOutputRoot "profile_recommendation.json"
        responsive_trial_gate_json = Join-Path $resolvedOutputRoot "responsive_trial_gate.json"
        next_live_plan_json = Join-Path $resolvedOutputRoot "next_live_plan.json"
    }
}

function Get-ArtifactStatusCollection {
    param(
        [string]$ResolvedPairRoot,
        [hashtable]$RegistryContext,
        [datetime]$PairSummaryTimestampUtc
    )

    $guidedSessionRoot = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session")
    $artifactMap = [ordered]@{
        mission_snapshot = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.json")
        mission_execution = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\mission_execution.json")
        session_state = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\session_state.json")
        final_session_docket = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "guided_session\final_session_docket.json")
        monitor_status = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "live_monitor_status.json")
        pair_summary = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "pair_summary.json")
        comparison = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "comparison.json")
        scorecard = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "scorecard.json")
        shadow_review = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "shadow_review\shadow_recommendation.json")
        grounded_evidence_certificate = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "grounded_evidence_certificate.json")
        grounded_session_analysis = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "grounded_session_analysis.json")
        promotion_gap_delta = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "promotion_gap_delta.json")
        session_outcome_dossier = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "session_outcome_dossier.json")
        mission_attainment = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "mission_attainment.json")
        registry_summary = Resolve-ExistingPath -Path $RegistryContext.registry_summary_json
        profile_recommendation = Resolve-ExistingPath -Path $RegistryContext.profile_recommendation_json
        responsive_trial_gate = Resolve-ExistingPath -Path $RegistryContext.responsive_trial_gate_json
        next_live_plan = Resolve-ExistingPath -Path $RegistryContext.next_live_plan_json
        registry = Resolve-ExistingPath -Path $RegistryContext.registry_path
        session_salvage_report = Resolve-ExistingPath -Path (Join-Path $ResolvedPairRoot "session_salvage_report.json")
    }

    $derivedArtifactNames = @(
        "scorecard",
        "shadow_review",
        "grounded_evidence_certificate",
        "grounded_session_analysis",
        "promotion_gap_delta",
        "session_outcome_dossier",
        "mission_attainment",
        "registry_summary",
        "profile_recommendation",
        "responsive_trial_gate",
        "next_live_plan",
        "final_session_docket",
        "session_state",
        "session_salvage_report"
    )

    $statuses = @()
    foreach ($artifactName in $artifactMap.Keys) {
        $path = [string]$artifactMap[$artifactName]
        $found = -not [string]::IsNullOrWhiteSpace($path)
        $stale = $false
        if ($artifactName -in $derivedArtifactNames) {
            $stale = Test-DerivedArtifactStale -Path $path -ReferenceTimestampUtc $PairSummaryTimestampUtc
        }

        $statuses += [pscustomobject]@{
            name = $artifactName
            path = $path
            found = $found
            stale = $stale
        }
    }

    return $statuses
}

function Test-RegistryEntryPresent {
    param(
        [string]$RegistryPath,
        [string]$ResolvedPairRoot,
        [string]$PairId
    )

    foreach ($entry in @(Read-NdjsonFile -Path $RegistryPath)) {
        $entryPairRoot = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_root" -Default "")
        $entryPairId = [string](Get-ObjectPropertyValue -Object $entry -Name "pair_id" -Default "")
        if (($entryPairRoot -and ($entryPairRoot -eq $ResolvedPairRoot)) -or ($entryPairId -and ($entryPairId -eq $PairId))) {
            return $true
        }
    }

    return $false
}

function Get-ArtifactStatusByName {
    param(
        [object[]]$Statuses,
        [string]$Name
    )

    return $Statuses | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Get-ArtifactNameList {
    param(
        [object[]]$Statuses,
        [scriptblock]$Predicate
    )

    return @(
        $Statuses |
            Where-Object $Predicate |
            ForEach-Object { [string]$_.name }
    )
}

function Get-SalvageStepList {
    param(
        [string]$RecommendedAction,
        [object[]]$ArtifactStatuses,
        [bool]$RegistryEntryPresent
    )

    $needsCoreCloseout = @(
        @(
            "scorecard",
            "shadow_review",
            "grounded_evidence_certificate",
            "grounded_session_analysis",
            "promotion_gap_delta",
            "session_outcome_dossier"
        ) | Where-Object {
            $status = Get-ArtifactStatusByName -Statuses $ArtifactStatuses -Name $_
            $null -eq $status -or -not $status.found -or $status.stale
        }
    )

    $needsMissionAttainment = $false
    $missionAttainmentStatus = Get-ArtifactStatusByName -Statuses $ArtifactStatuses -Name "mission_attainment"
    if ($null -eq $missionAttainmentStatus -or -not $missionAttainmentStatus.found -or $missionAttainmentStatus.stale) {
        $needsMissionAttainment = $true
    }

    $needsRegistrySummary = @(
        @(
            "registry_summary",
            "profile_recommendation",
            "responsive_trial_gate",
            "next_live_plan"
        ) | Where-Object {
            $status = Get-ArtifactStatusByName -Statuses $ArtifactStatuses -Name $_
            $null -eq $status -or -not $status.found -or $status.stale
        }
    )

    return [ordered]@{
        rebuild_core_closeout = ($needsCoreCloseout.Count -gt 0) -or ($RecommendedAction -eq "run-post-pipeline-only")
        register_pair_result = -not $RegistryEntryPresent
        refresh_registry_summary = (-not $RegistryEntryPresent) -or ($needsRegistrySummary.Count -gt 0)
        refresh_responsive_trial_gate = (-not $RegistryEntryPresent) -or ($needsRegistrySummary -contains "responsive_trial_gate") -or ($needsRegistrySummary -contains "registry_summary") -or ($needsRegistrySummary -contains "profile_recommendation")
        refresh_next_live_plan = (-not $RegistryEntryPresent) -or ($needsRegistrySummary -contains "next_live_plan") -or ($needsRegistrySummary -contains "registry_summary") -or ($needsRegistrySummary -contains "profile_recommendation") -or ($needsRegistrySummary -contains "responsive_trial_gate")
        rebuild_mission_attainment = $needsMissionAttainment -or ($RecommendedAction -eq "run-post-pipeline-only")
    }
}

function Get-RecommendedSalvageStepNames {
    param([hashtable]$Plan)

    $steps = @()
    if ($Plan.rebuild_core_closeout) {
        $steps += "build_latest_session_outcome_dossier.ps1"
    }
    if ($Plan.register_pair_result) {
        $steps += "register_pair_session_result.ps1"
    }
    if ($Plan.refresh_registry_summary) {
        $steps += "summarize_pair_session_registry.ps1"
    }
    if ($Plan.refresh_responsive_trial_gate) {
        $steps += "evaluate_responsive_trial_gate.ps1"
    }
    if ($Plan.refresh_next_live_plan) {
        $steps += "plan_next_live_session.ps1"
    }
    if ($Plan.rebuild_mission_attainment) {
        $steps += "evaluate_latest_session_mission.ps1"
    }

    return $steps
}

function Get-SalvageStatusText {
    param(
        [bool]$SalvageAllowed,
        [bool]$SalvageCompleted,
        [bool]$StructuralCompleteAfterSalvage
    )

    if (-not $SalvageAllowed) {
        return "blocked"
    }

    if ($SalvageCompleted -and $StructuralCompleteAfterSalvage) {
        return "completed"
    }

    if ($SalvageCompleted) {
        return "completed-partial"
    }

    return "failed"
}

function Get-BooleanSafe {
    param([object]$Value)

    return [bool]$Value
}

function Update-SessionStateForSalvage {
    param(
        [string]$Path,
        [string]$ResolvedPairRoot,
        [string]$GuidedSessionRoot,
        [object]$PairSummary,
        [object]$ExistingSessionState,
        [hashtable]$RegistryContext,
        [string]$RecoveryVerdict,
        [string]$RecommendedAction,
        [string]$SalvageStatus,
        [string]$Explanation,
        [bool]$StructuralCompleteAfterSalvage,
        [string]$RecoveryReportJsonPath,
        [string]$PostRecoveryReportJsonPath,
        [string]$SalvageReportJsonPath,
        [string]$SalvageReportMarkdownPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $artifacts = Merge-ObjectMap -BaseObject (Get-ObjectPropertyValue -Object $ExistingSessionState -Name "artifacts" -Default $null) -Updates ([ordered]@{
        registry_path = $RegistryContext.registry_path
        session_state_json = $Path
        final_session_docket_json = Join-Path $GuidedSessionRoot "final_session_docket.json"
        session_outcome_dossier_json = Join-Path $ResolvedPairRoot "session_outcome_dossier.json"
        mission_attainment_json = Join-Path $ResolvedPairRoot "mission_attainment.json"
        scorecard_json = Join-Path $ResolvedPairRoot "scorecard.json"
        shadow_recommendation_json = Join-Path $ResolvedPairRoot "shadow_review\shadow_recommendation.json"
        session_salvage_report_json = $SalvageReportJsonPath
        session_salvage_report_markdown = $SalvageReportMarkdownPath
        session_recovery_report_json = $PostRecoveryReportJsonPath
    })

    $monitorStatus = Read-JsonFile -Path (Join-Path $ResolvedPairRoot "live_monitor_status.json")
    $postPipeline = Merge-ObjectMap -BaseObject (Get-ObjectPropertyValue -Object $ExistingSessionState -Name "post_pipeline" -Default $null) -Updates ([ordered]@{
        enabled = $true
        salvage_applied = $true
        salvage_status = $SalvageStatus
        salvage_recovery_verdict = $RecoveryVerdict
        salvage_recommended_action = $RecommendedAction
        shadow_review_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "shadow_review\shadow_recommendation.json")
        scorecard_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "scorecard.json")
        register_completed = Test-RegistryEntryPresent -RegistryPath $RegistryContext.registry_path -ResolvedPairRoot $ResolvedPairRoot -PairId ([string](Get-ObjectPropertyValue -Object $PairSummary -Name "pair_id" -Default ""))
        registry_summary_completed = Test-Path -LiteralPath $RegistryContext.registry_summary_json
        responsive_gate_completed = Test-Path -LiteralPath $RegistryContext.responsive_trial_gate_json
        next_live_plan_completed = Test-Path -LiteralPath $RegistryContext.next_live_plan_json
        outcome_dossier_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "session_outcome_dossier.json")
        mission_attainment_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "mission_attainment.json")
        registry_isolated_for_rehearsal = $RegistryContext.registry_isolated_for_rehearsal
        recovery_report_json = $RecoveryReportJsonPath
        post_recovery_report_json = $PostRecoveryReportJsonPath
    })

    $sessionState = Merge-ObjectMap -BaseObject $ExistingSessionState -Updates ([ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $ResolvedPairRoot
        guided_session_root = $GuidedSessionRoot
        treatment_profile = [string](Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_profile" -Default "")
        stage = "salvage-finalized"
        status = $(if ($StructuralCompleteAfterSalvage) { "complete" } else { "partial" })
        explanation = $Explanation
        run_post_pipeline_enabled = $true
        monitor = [ordered]@{
            current_verdict = [string](Get-ObjectPropertyValue -Object $monitorStatus -Name "current_verdict" -Default "")
            explanation = [string](Get-ObjectPropertyValue -Object $monitorStatus -Name "explanation" -Default "")
            operator_can_stop_now = [bool](Get-ObjectPropertyValue -Object $monitorStatus -Name "operator_can_stop_now" -Default $false)
            likely_remains_insufficient_if_stopped_immediately = [bool](Get-ObjectPropertyValue -Object $monitorStatus -Name "likely_remains_insufficient_if_stopped_immediately" -Default $false)
        }
        post_pipeline = $postPipeline
        artifacts = $artifacts
        salvage = [ordered]@{
            applied_at_utc = (Get-Date).ToUniversalTime().ToString("o")
            status = $SalvageStatus
            recovery_verdict_used = $RecoveryVerdict
            recommended_recovery_action = $RecommendedAction
            structural_complete_after_salvage = $StructuralCompleteAfterSalvage
            session_salvage_report_json = $SalvageReportJsonPath
            session_salvage_report_markdown = $SalvageReportMarkdownPath
            session_recovery_report_json = $PostRecoveryReportJsonPath
        }
    })

    Write-JsonFile -Path $Path -Value $sessionState
}

function Get-SalvageDocketMarkdown {
    param([object]$Docket)

    $lines = @(
        "# Final Session Docket",
        "",
        "- Pair root: $($Docket.pair_root)",
        "- Treatment profile: $($Docket.treatment_profile)",
        "- Salvage applied: $($Docket.salvage.applied)",
        "- Salvage status: $($Docket.salvage.status)",
        "- Salvage explanation: $($Docket.salvage.explanation)",
        "",
        "## Evidence",
        "",
        "- Evidence origin: $($Docket.evidence.evidence_origin)",
        "- Rehearsal mode: $($Docket.evidence.rehearsal_mode)",
        "- Synthetic fixture: $($Docket.evidence.synthetic_fixture)",
        "- Validation only: $($Docket.evidence.validation_only)",
        "",
        "## Post-Pipeline",
        "",
        "- Ran: $($Docket.post_pipeline.ran)",
        "- Scorecard completed: $($Docket.post_pipeline.scorecard_completed)",
        "- Shadow review completed: $($Docket.post_pipeline.shadow_review_completed)",
        "- Register completed: $($Docket.post_pipeline.register_completed)",
        "- Registry summary completed: $($Docket.post_pipeline.registry_summary_completed)",
        "- Responsive gate completed: $($Docket.post_pipeline.responsive_gate_completed)",
        "- Next-live plan completed: $($Docket.post_pipeline.next_live_plan_completed)",
        "- Outcome dossier completed: $($Docket.post_pipeline.outcome_dossier_completed)",
        "- Mission attainment completed: $($Docket.post_pipeline.mission_attainment_completed)",
        "",
        "## Session State",
        "",
        "- Session state path: $($Docket.session_state.path)",
        "- Session state stage: $($Docket.session_state.stage)",
        "- Session state status: $($Docket.session_state.status)",
        "- Full closeout completed: $($Docket.session_state.full_closeout_completed)",
        "",
        "## Mission Attainment",
        "",
        "- Verdict: $($Docket.mission_attainment.verdict)",
        "- Operational success: $($Docket.mission_attainment.mission_operational_success)",
        "- Grounded success: $($Docket.mission_attainment.mission_grounded_success)",
        "- Promotion impact: $($Docket.mission_attainment.mission_promotion_impact)",
        "- Explanation: $($Docket.mission_attainment.explanation)",
        "",
        "## Artifacts",
        ""
    )

    foreach ($property in $Docket.artifacts.PSObject.Properties) {
        $lines += "- $($property.Name): $($property.Value)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Update-FinalDocketForSalvage {
    param(
        [string]$Path,
        [string]$MarkdownPath,
        [string]$ResolvedPairRoot,
        [string]$GuidedSessionRoot,
        [object]$PairSummary,
        [object]$ExistingDocket,
        [hashtable]$RegistryContext,
        [object]$MissionAttainment,
        [object]$MissionExecution,
        [string]$RecoveryVerdict,
        [string]$RecommendedAction,
        [string]$SalvageStatus,
        [string]$Explanation,
        [bool]$StructuralCompleteAfterSalvage,
        [string[]]$RebuiltArtifacts,
        [string[]]$RemainingMissingArtifacts,
        [string]$SalvageReportJsonPath,
        [string]$SalvageReportMarkdownPath,
        [string]$PostRecoveryReportJsonPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($GuidedSessionRoot)) {
        return
    }

    $evidenceBlock = Merge-ObjectMap -BaseObject (Get-ObjectPropertyValue -Object $ExistingDocket -Name "evidence" -Default $null) -Updates ([ordered]@{
        synthetic_fixture = [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "synthetic_fixture" -Default $false)
        rehearsal_mode = [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "rehearsal_mode" -Default $false)
        evidence_origin = [string](Get-ObjectPropertyValue -Object $PairSummary -Name "evidence_origin" -Default "")
        validation_only = [bool](Get-ObjectPropertyValue -Object $PairSummary -Name "validation_only" -Default $false)
    })

    $artifactsBlock = Merge-ObjectMap -BaseObject (Get-ObjectPropertyValue -Object $ExistingDocket -Name "artifacts" -Default $null) -Updates ([ordered]@{
        pair_summary_json = Join-Path $ResolvedPairRoot "pair_summary.json"
        scorecard_json = Join-Path $ResolvedPairRoot "scorecard.json"
        shadow_recommendation_json = Join-Path $ResolvedPairRoot "shadow_review\shadow_recommendation.json"
        profile_recommendation_json = $RegistryContext.profile_recommendation_json
        responsive_trial_gate_json = $RegistryContext.responsive_trial_gate_json
        next_live_plan_json = $RegistryContext.next_live_plan_json
        mission_snapshot_json = Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.json"
        mission_execution_json = Join-Path $ResolvedPairRoot "guided_session\mission_execution.json"
        session_state_json = Join-Path $GuidedSessionRoot "session_state.json"
        registry_path = $RegistryContext.registry_path
        final_session_docket_json = $Path
        final_session_docket_markdown = $MarkdownPath
        session_outcome_dossier_json = Join-Path $ResolvedPairRoot "session_outcome_dossier.json"
        session_outcome_dossier_markdown = Join-Path $ResolvedPairRoot "session_outcome_dossier.md"
        mission_attainment_json = Join-Path $ResolvedPairRoot "mission_attainment.json"
        mission_attainment_markdown = Join-Path $ResolvedPairRoot "mission_attainment.md"
        session_salvage_report_json = $SalvageReportJsonPath
        session_salvage_report_markdown = $SalvageReportMarkdownPath
        session_recovery_report_json = $PostRecoveryReportJsonPath
    })

    $postPipelineBlock = Merge-ObjectMap -BaseObject (Get-ObjectPropertyValue -Object $ExistingDocket -Name "post_pipeline" -Default $null) -Updates ([ordered]@{
        ran = $true
        review_completed = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $ExistingDocket -Name "post_pipeline" -Default $null) -Name "review_completed" -Default $false)
        shadow_review_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "shadow_review\shadow_recommendation.json")
        scorecard_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "scorecard.json")
        register_completed = Test-RegistryEntryPresent -RegistryPath $RegistryContext.registry_path -ResolvedPairRoot $ResolvedPairRoot -PairId ([string](Get-ObjectPropertyValue -Object $PairSummary -Name "pair_id" -Default ""))
        registry_summary_completed = Test-Path -LiteralPath $RegistryContext.registry_summary_json
        responsive_gate_completed = Test-Path -LiteralPath $RegistryContext.responsive_trial_gate_json
        next_live_plan_completed = Test-Path -LiteralPath $RegistryContext.next_live_plan_json
        outcome_dossier_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "session_outcome_dossier.json")
        mission_attainment_completed = Test-Path -LiteralPath (Join-Path $ResolvedPairRoot "mission_attainment.json")
        registry_isolated_for_rehearsal = $RegistryContext.registry_isolated_for_rehearsal
    })

    $missionAttainmentBlock = if ($null -ne $MissionAttainment) {
        [ordered]@{
            verdict = [string](Get-ObjectPropertyValue -Object $MissionAttainment -Name "mission_attainment_verdict" -Default "")
            mission_operational_success = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "mission_operational_success" -Default $false)
            mission_grounded_success = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "mission_grounded_success" -Default $false)
            mission_promotion_impact = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "mission_promotion_impact" -Default $false)
            explanation = [string](Get-ObjectPropertyValue -Object $MissionAttainment -Name "explanation" -Default "")
        }
    }
    else {
        Convert-ToOrderedMap -InputObject (Get-ObjectPropertyValue -Object $ExistingDocket -Name "mission_attainment" -Default $null)
    }

    $missionExecutionBlock = if ($null -ne $MissionExecution) {
        [ordered]@{
            available = $true
            drift_policy_verdict = [string](Get-ObjectPropertyValue -Object $MissionExecution -Name "drift_policy_verdict" -Default "")
            mission_compliant = [bool](Get-ObjectPropertyValue -Object $MissionExecution -Name "mission_compliant" -Default $false)
            mission_divergent = [bool](Get-ObjectPropertyValue -Object $MissionExecution -Name "mission_divergent" -Default $false)
            valid_for_mission_attainment_analysis = [bool](Get-ObjectPropertyValue -Object $MissionExecution -Name "valid_for_mission_attainment_analysis" -Default $false)
            drift_detected = [bool](Get-ObjectPropertyValue -Object $MissionExecution -Name "drift_detected" -Default $false)
            explanation = [string](Get-ObjectPropertyValue -Object $MissionExecution -Name "explanation" -Default "")
        }
    }
    else {
        Convert-ToOrderedMap -InputObject (Get-ObjectPropertyValue -Object $ExistingDocket -Name "mission_execution" -Default $null)
    }

    $docket = Merge-ObjectMap -BaseObject $ExistingDocket -Updates ([ordered]@{
        schema_version = 6
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        pair_root = $ResolvedPairRoot
        guided_session_root = $GuidedSessionRoot
        treatment_profile = [string](Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_profile" -Default "")
        evidence = $evidenceBlock
        post_pipeline = $postPipelineBlock
        session_state = [ordered]@{
            path = Join-Path $GuidedSessionRoot "session_state.json"
            stage = "salvage-finalized"
            status = $(if ($StructuralCompleteAfterSalvage) { "complete" } else { "partial" })
            pair_run_completed = $true
            full_closeout_completed = $StructuralCompleteAfterSalvage
            explanation = $Explanation
        }
        mission_attainment = $missionAttainmentBlock
        mission_execution = $missionExecutionBlock
        salvage = [ordered]@{
            applied = $true
            status = $SalvageStatus
            recovery_verdict_used = $RecoveryVerdict
            recommended_recovery_action = $RecommendedAction
            structural_complete_after_salvage = $StructuralCompleteAfterSalvage
            rebuilt_artifacts = $RebuiltArtifacts
            remaining_missing_artifacts = $RemainingMissingArtifacts
            session_salvage_report_json = $SalvageReportJsonPath
            session_salvage_report_markdown = $SalvageReportMarkdownPath
            explanation = $Explanation
        }
        artifacts = $artifactsBlock
    })

    Write-JsonFile -Path $Path -Value $docket
    Write-TextFile -Path $MarkdownPath -Value (Get-SalvageDocketMarkdown -Docket $docket)
}

function Get-SalvageMarkdown {
    param([object]$Report)

    $lines = @(
        "# Session Salvage Report",
        "",
        "- Pair root: $($Report.pair_root)",
        "- Selection mode: $($Report.selection_mode)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Recovery verdict used: $($Report.recovery_verdict_used)",
        "- Recommended recovery action used: $($Report.recommended_recovery_action_used)",
        "- Salvage allowed: $($Report.salvage_allowed)",
        "- Salvage status: $($Report.salvage_status)",
        "- Salvage completed successfully: $($Report.salvage_completed_successfully)",
        "- Structurally complete after salvage: $($Report.structurally_complete_after_salvage)",
        "- Explanation: $($Report.explanation)",
        "",
        "## Registry And Promotion",
        "",
        "- Registry path: $($Report.registry_context.registry_path)",
        "- Registry output root: $($Report.registry_context.output_root)",
        "- Registration disposition after salvage: $($Report.after_recovery.certification_registry.registration_disposition)",
        "- Counts toward grounded certification now: $($Report.after_recovery.certification_registry.count_toward_grounded_certification_now)",
        "- Register only as workflow validation now: $($Report.after_recovery.certification_registry.register_only_as_workflow_validation_now)",
        "- Register only as non-grounded now: $($Report.after_recovery.certification_registry.register_only_as_non_grounded_now)",
        "- Exclude from promotion logic now: $($Report.after_recovery.certification_registry.exclude_from_promotion_logic_now)",
        "",
        "## Step Plan",
        ""
    )

    foreach ($step in @($Report.steps)) {
        $lines += "- $($step.name): needed=$($step.needed) ran=$($step.ran) status=$($step.status)"
        $lines += "  Explanation: $($step.explanation)"
    }

    $lines += ""
    $lines += "## Artifacts"
    $lines += ""
    $lines += "- Already present before salvage: $(([string[]]$Report.artifacts.already_present) -join ', ')"
    $lines += "- Rebuilt: $(([string[]]$Report.artifacts.rebuilt) -join ', ')"
    $lines += "- Remaining missing after salvage: $(([string[]]$Report.artifacts.remaining_missing_after_salvage) -join ', ')"

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
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
$selectionMode = if ([string]::IsNullOrWhiteSpace($PairRoot)) { "latest-pair-root" } else { "explicit-pair-root" }
$resolvedPairRoot = if ([string]::IsNullOrWhiteSpace($PairRoot)) {
    Find-LatestPairRoot -Root $resolvedPairsRoot
}
else {
    Resolve-ExistingPath -Path (Get-AbsolutePath -Path $PairRoot -BasePath $repoRoot)
}

if ([string]::IsNullOrWhiteSpace($resolvedPairRoot)) {
    throw "Pair root was not found: $PairRoot"
}

$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
if (-not $pairSummaryPath) {
    throw "Pair summary JSON was not found under $resolvedPairRoot"
}

$pairSummary = Read-JsonFile -Path $pairSummaryPath
$pairSummaryTimestampUtc = Get-ArtifactTimestampUtc -Path $pairSummaryPath
$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    ""
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}

$resolvedRecoveryReportPath = if ([string]::IsNullOrWhiteSpace($RecoveryReportPath)) {
    ""
}
else {
    Get-AbsolutePath -Path $RecoveryReportPath -BasePath $repoRoot
}

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    Join-Path $resolvedPairRoot "session_salvage_report.json"
}
else {
    Get-AbsolutePath -Path $OutputJson -BasePath $resolvedPairRoot
}
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    Join-Path $resolvedPairRoot "session_salvage_report.md"
}
else {
    Get-AbsolutePath -Path $OutputMarkdown -BasePath $resolvedPairRoot
}

$recoveryInfo = Get-RecoveryAssessmentInfo `
    -ResolvedPairRoot $resolvedPairRoot `
    -ResolvedLabRoot $resolvedLabRoot `
    -ResolvedRegistryPath $resolvedRegistryPath `
    -ExplicitRecoveryReportPath $resolvedRecoveryReportPath
$recoveryReport = $recoveryInfo.report
$recoveryVerdict = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "recovery_verdict" -Default "")
$recommendedAction = [string](Get-ObjectPropertyValue -Object $recoveryReport -Name "recommended_next_action" -Default "")

$recoverableVerdicts = @(
    "session-interrupted-after-sufficiency-before-closeout",
    "session-interrupted-during-post-pipeline",
    "session-partial-artifacts-recoverable"
)
$recoverableActions = @(
    "run-post-pipeline-only",
    "rebuild-dossier-and-closeout"
)
$salvageAllowed = ($recoverableVerdicts -contains $recoveryVerdict) -and ($recoverableActions -contains $recommendedAction)

$guidedSessionRoot = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session")
$sessionStatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\session_state.json")
$finalDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\final_session_docket.json")
$sessionState = Read-JsonFile -Path $sessionStatePath
$finalDocket = Read-JsonFile -Path $finalDocketPath
$registryContext = Get-RegistryContext `
    -ResolvedPairRoot $resolvedPairRoot `
    -ResolvedLabRoot $resolvedLabRoot `
    -ExplicitRegistryPath $resolvedRegistryPath `
    -PairSummary $pairSummary `
    -SessionState $sessionState `
    -FinalDocket $finalDocket `
    -RecoveryReport $recoveryReport

$null = Ensure-Directory -Path (Split-Path -Path $registryContext.registry_path -Parent)
$null = Ensure-Directory -Path $registryContext.output_root

$pairId = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Default "")
$artifactStatusesBefore = Get-ArtifactStatusCollection -ResolvedPairRoot $resolvedPairRoot -RegistryContext $registryContext -PairSummaryTimestampUtc $pairSummaryTimestampUtc
$registryEntryPresentBefore = Test-RegistryEntryPresent -RegistryPath $registryContext.registry_path -ResolvedPairRoot $resolvedPairRoot -PairId $pairId
$salvagePlan = Get-SalvageStepList -RecommendedAction $recommendedAction -ArtifactStatuses $artifactStatusesBefore -RegistryEntryPresent $registryEntryPresentBefore
$plannedStepNames = Get-RecommendedSalvageStepNames -Plan $salvagePlan

$alreadyPresentArtifacts = Get-ArtifactNameList -Statuses $artifactStatusesBefore -Predicate { $_.found -and -not $_.stale }
$missingBeforeArtifacts = Get-ArtifactNameList -Statuses $artifactStatusesBefore -Predicate { -not $_.found }
$staleBeforeArtifacts = Get-ArtifactNameList -Statuses $artifactStatusesBefore -Predicate { $_.found -and $_.stale }

$steps = @()
$rebuiltArtifacts = @()
$explanation = ""
$salvageCompletedSuccessfully = $false
$afterRecoveryInfo = $recoveryInfo
$afterRecoveryReport = $recoveryReport

try {
    if (-not $salvageAllowed) {
        if ($recoveryVerdict -in @("session-complete", "session-complete-pending-review-only")) {
            $explanation = "Salvage was blocked because the session is already structurally complete. Use recovery assessment for classification, not salvage."
        }
        else {
            $explanation = "Salvage was blocked because the recovery assessment did not authorize a recoverable closeout path. Verdict '$recoveryVerdict' with action '$recommendedAction' must be rerun or reviewed manually instead."
        }

        $steps += [pscustomobject]@{
            name = "salvage-blocked"
            needed = $false
            ran = $false
            status = "blocked"
            explanation = $explanation
        }

        throw $explanation
    }

    $dossierScriptPath = Join-Path $PSScriptRoot "build_latest_session_outcome_dossier.ps1"
    $registerScriptPath = Join-Path $PSScriptRoot "register_pair_session_result.ps1"
    $summaryScriptPath = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"
    $gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"
    $plannerScriptPath = Join-Path $PSScriptRoot "plan_next_live_session.ps1"
    $missionScriptPath = Join-Path $PSScriptRoot "evaluate_latest_session_mission.ps1"

    if ($salvagePlan.rebuild_core_closeout) {
        $dossierArgs = @{
            PairRoot = $resolvedPairRoot
            RegistryPath = $registryContext.registry_path
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedLabRoot)) {
            $dossierArgs.LabRoot = $resolvedLabRoot
        }

        & $dossierScriptPath @dossierArgs | Out-Null
        $steps += [pscustomobject]@{
            name = "build_latest_session_outcome_dossier.ps1"
            needed = $true
            ran = $true
            status = "completed"
            explanation = "Rebuilt the core closeout stack so scorecard, shadow review, certification, grounded analysis, promotion-gap delta, and the dossier are current."
        }
        $rebuiltArtifacts += @(
            "scorecard",
            "shadow_review",
            "grounded_evidence_certificate",
            "grounded_session_analysis",
            "promotion_gap_delta",
            "session_outcome_dossier"
        )
    }
    else {
        $steps += [pscustomobject]@{
            name = "build_latest_session_outcome_dossier.ps1"
            needed = $false
            ran = $false
            status = "skipped-current"
            explanation = "Core closeout artifacts were already present and current enough to reuse."
        }
    }

    if ($salvagePlan.register_pair_result) {
        $registerArgs = @{
            PairRoot = $resolvedPairRoot
            RegistryPath = $registryContext.registry_path
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedLabRoot)) {
            $registerArgs.LabRoot = $resolvedLabRoot
        }

        & $registerScriptPath @registerArgs | Out-Null
        $steps += [pscustomobject]@{
            name = "register_pair_session_result.ps1"
            needed = $true
            ran = $true
            status = "completed"
            explanation = "Registered the pair in the selected registry so planner outputs can be rebuilt honestly."
        }
        $rebuiltArtifacts += @("registry")
    }
    else {
        $steps += [pscustomobject]@{
            name = "register_pair_session_result.ps1"
            needed = $false
            ran = $false
            status = "skipped-current"
            explanation = "The selected registry already contains an entry for this pair."
        }
    }

    if ($salvagePlan.refresh_registry_summary) {
        & $summaryScriptPath -RegistryPath $registryContext.registry_path -OutputRoot $registryContext.output_root | Out-Null
        $steps += [pscustomobject]@{
            name = "summarize_pair_session_registry.ps1"
            needed = $true
            ran = $true
            status = "completed"
            explanation = "Rebuilt the registry summary and profile recommendation outputs from the selected registry."
        }
        $rebuiltArtifacts += @("registry_summary", "profile_recommendation")
    }
    else {
        $steps += [pscustomobject]@{
            name = "summarize_pair_session_registry.ps1"
            needed = $false
            ran = $false
            status = "skipped-current"
            explanation = "Registry summary and profile recommendation outputs were already current."
        }
    }

    if ($salvagePlan.refresh_responsive_trial_gate) {
        & $gateScriptPath `
            -RegistryPath $registryContext.registry_path `
            -OutputRoot $registryContext.output_root `
            -RegistrySummaryPath $registryContext.registry_summary_json `
            -ProfileRecommendationPath $registryContext.profile_recommendation_json | Out-Null
        $steps += [pscustomobject]@{
            name = "evaluate_responsive_trial_gate.ps1"
            needed = $true
            ran = $true
            status = "completed"
            explanation = "Rebuilt the responsive-gate output from the refreshed registry state."
        }
        $rebuiltArtifacts += @("responsive_trial_gate")
    }
    else {
        $steps += [pscustomobject]@{
            name = "evaluate_responsive_trial_gate.ps1"
            needed = $false
            ran = $false
            status = "skipped-current"
            explanation = "Responsive-gate output was already current."
        }
    }

    if ($salvagePlan.refresh_next_live_plan) {
        & $plannerScriptPath `
            -RegistryPath $registryContext.registry_path `
            -OutputRoot $registryContext.output_root `
            -RegistrySummaryPath $registryContext.registry_summary_json `
            -ProfileRecommendationPath $registryContext.profile_recommendation_json `
            -ResponsiveTrialGatePath $registryContext.responsive_trial_gate_json | Out-Null
        $steps += [pscustomobject]@{
            name = "plan_next_live_session.ps1"
            needed = $true
            ran = $true
            status = "completed"
            explanation = "Rebuilt the next-live plan from the refreshed registry summary and responsive-gate outputs."
        }
        $rebuiltArtifacts += @("next_live_plan")
    }
    else {
        $steps += [pscustomobject]@{
            name = "plan_next_live_session.ps1"
            needed = $false
            ran = $false
            status = "skipped-current"
            explanation = "Next-live planning output was already current."
        }
    }

    if ($salvagePlan.rebuild_mission_attainment) {
        $missionArgs = @{
            PairRoot = $resolvedPairRoot
            RegistryPath = $registryContext.registry_path
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedLabRoot)) {
            $missionArgs.LabRoot = $resolvedLabRoot
        }

        & $missionScriptPath @missionArgs | Out-Null
        $steps += [pscustomobject]@{
            name = "evaluate_latest_session_mission.ps1"
            needed = $true
            ran = $true
            status = "completed"
            explanation = "Rebuilt mission-attainment closeout from the saved mission snapshot, mission execution, monitor status, and refreshed dossier."
        }
        $rebuiltArtifacts += @("mission_attainment")
    }
    else {
        $steps += [pscustomobject]@{
            name = "evaluate_latest_session_mission.ps1"
            needed = $false
            ran = $false
            status = "skipped-current"
            explanation = "Mission-attainment output was already current."
        }
    }

    if ($guidedSessionRoot) {
        $preliminaryExplanation = "Salvage rebuilt the recoverable post-pipeline artifacts from the saved pair root without replaying the live session."
        Update-SessionStateForSalvage `
            -Path (Join-Path $guidedSessionRoot "session_state.json") `
            -ResolvedPairRoot $resolvedPairRoot `
            -GuidedSessionRoot $guidedSessionRoot `
            -PairSummary $pairSummary `
            -ExistingSessionState $sessionState `
            -RegistryContext $registryContext `
            -RecoveryVerdict $recoveryVerdict `
            -RecommendedAction $recommendedAction `
            -SalvageStatus "pending-verification" `
            -Explanation $preliminaryExplanation `
            -StructuralCompleteAfterSalvage:$false `
            -RecoveryReportJsonPath $recoveryInfo.json_path `
            -PostRecoveryReportJsonPath $recoveryInfo.json_path `
            -SalvageReportJsonPath $outputJsonPath `
            -SalvageReportMarkdownPath $outputMarkdownPath

        Update-FinalDocketForSalvage `
            -Path (Join-Path $guidedSessionRoot "final_session_docket.json") `
            -MarkdownPath (Join-Path $guidedSessionRoot "final_session_docket.md") `
            -ResolvedPairRoot $resolvedPairRoot `
            -GuidedSessionRoot $guidedSessionRoot `
            -PairSummary $pairSummary `
            -ExistingDocket $finalDocket `
            -RegistryContext $registryContext `
            -MissionAttainment (Read-JsonFile -Path (Join-Path $resolvedPairRoot "mission_attainment.json")) `
            -MissionExecution (Read-JsonFile -Path (Join-Path $resolvedPairRoot "guided_session\mission_execution.json")) `
            -RecoveryVerdict $recoveryVerdict `
            -RecommendedAction $recommendedAction `
            -SalvageStatus "pending-verification" `
            -Explanation $preliminaryExplanation `
            -StructuralCompleteAfterSalvage:$false `
            -RebuiltArtifacts $rebuiltArtifacts `
            -RemainingMissingArtifacts @() `
            -SalvageReportJsonPath $outputJsonPath `
            -SalvageReportMarkdownPath $outputMarkdownPath `
            -PostRecoveryReportJsonPath $recoveryInfo.json_path
    }

    $afterRecoveryInfo = Get-RecoveryAssessmentInfo `
        -ResolvedPairRoot $resolvedPairRoot `
        -ResolvedLabRoot $resolvedLabRoot `
        -ResolvedRegistryPath $registryContext.registry_path `
        -ExplicitRecoveryReportPath ""
    $afterRecoveryReport = $afterRecoveryInfo.report

    $afterRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $afterRecoveryReport -Name "recovery_verdict" -Default "")
    $structurallyCompleteAfterSalvage = $afterRecoveryVerdict -in @("session-complete", "session-complete-pending-review-only")
    $salvageCompletedSuccessfully = $structurallyCompleteAfterSalvage

    $explanation = if ($salvageCompletedSuccessfully) {
        "Salvage finished the recoverable closeout path without replaying the live run. The session is now structurally complete, although promotion eligibility still depends on the underlying evidence bucket."
    }
    else {
        "Salvage reran the recoverable closeout steps, but the follow-up recovery assessment still found the session incomplete or review-blocked."
    }

    if ($guidedSessionRoot) {
        Update-SessionStateForSalvage `
            -Path (Join-Path $guidedSessionRoot "session_state.json") `
            -ResolvedPairRoot $resolvedPairRoot `
            -GuidedSessionRoot $guidedSessionRoot `
            -PairSummary $pairSummary `
            -ExistingSessionState (Read-JsonFile -Path (Join-Path $guidedSessionRoot "session_state.json")) `
            -RegistryContext $registryContext `
            -RecoveryVerdict $recoveryVerdict `
            -RecommendedAction $recommendedAction `
            -SalvageStatus (Get-SalvageStatusText -SalvageAllowed $true -SalvageCompleted $salvageCompletedSuccessfully -StructuralCompleteAfterSalvage $structurallyCompleteAfterSalvage) `
            -Explanation $explanation `
            -StructuralCompleteAfterSalvage:$structurallyCompleteAfterSalvage `
            -RecoveryReportJsonPath $recoveryInfo.json_path `
            -PostRecoveryReportJsonPath $afterRecoveryInfo.json_path `
            -SalvageReportJsonPath $outputJsonPath `
            -SalvageReportMarkdownPath $outputMarkdownPath

        Update-FinalDocketForSalvage `
            -Path (Join-Path $guidedSessionRoot "final_session_docket.json") `
            -MarkdownPath (Join-Path $guidedSessionRoot "final_session_docket.md") `
            -ResolvedPairRoot $resolvedPairRoot `
            -GuidedSessionRoot $guidedSessionRoot `
            -PairSummary $pairSummary `
            -ExistingDocket (Read-JsonFile -Path (Join-Path $guidedSessionRoot "final_session_docket.json")) `
            -RegistryContext $registryContext `
            -MissionAttainment (Read-JsonFile -Path (Join-Path $resolvedPairRoot "mission_attainment.json")) `
            -MissionExecution (Read-JsonFile -Path (Join-Path $resolvedPairRoot "guided_session\mission_execution.json")) `
            -RecoveryVerdict $recoveryVerdict `
            -RecommendedAction $recommendedAction `
            -SalvageStatus (Get-SalvageStatusText -SalvageAllowed $true -SalvageCompleted $salvageCompletedSuccessfully -StructuralCompleteAfterSalvage $structurallyCompleteAfterSalvage) `
            -Explanation $explanation `
            -StructuralCompleteAfterSalvage:$structurallyCompleteAfterSalvage `
            -RebuiltArtifacts $rebuiltArtifacts `
            -RemainingMissingArtifacts @() `
            -SalvageReportJsonPath $outputJsonPath `
            -SalvageReportMarkdownPath $outputMarkdownPath `
            -PostRecoveryReportJsonPath $afterRecoveryInfo.json_path
    }
}
catch {
    if (-not $explanation) {
        $explanation = $_.Exception.Message
    }
}

$artifactStatusesAfter = Get-ArtifactStatusCollection -ResolvedPairRoot $resolvedPairRoot -RegistryContext $registryContext -PairSummaryTimestampUtc $pairSummaryTimestampUtc
$remainingMissingAfterSalvage = Get-ArtifactNameList -Statuses $artifactStatusesAfter -Predicate { -not $_.found }
$remainingStaleAfterSalvage = Get-ArtifactNameList -Statuses $artifactStatusesAfter -Predicate { $_.found -and $_.stale }
$recoveryStateAfter = Get-ObjectPropertyValue -Object $afterRecoveryReport -Name "recovery_state" -Default $null
$structurallyCompleteAfterSalvage = [bool](Get-ObjectPropertyValue -Object $recoveryStateAfter -Name "session_complete" -Default $false)
$salvageStatus = Get-SalvageStatusText -SalvageAllowed $salvageAllowed -SalvageCompleted $salvageCompletedSuccessfully -StructuralCompleteAfterSalvage $structurallyCompleteAfterSalvage

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    selection_mode = $selectionMode
    pair_root = $resolvedPairRoot
    recovery_report_json_path = $recoveryInfo.json_path
    post_recovery_report_json_path = $afterRecoveryInfo.json_path
    recovery_verdict_used = $recoveryVerdict
    recommended_recovery_action_used = $recommendedAction
    salvage_allowed = $salvageAllowed
    salvage_status = $salvageStatus
    salvage_completed_successfully = $salvageCompletedSuccessfully
    structurally_complete_after_salvage = $structurallyCompleteAfterSalvage
    explanation = $explanation
    registry_context = [ordered]@{
        registry_path = $registryContext.registry_path
        output_root = $registryContext.output_root
        registry_isolated_for_rehearsal = $registryContext.registry_isolated_for_rehearsal
    }
    before_recovery = $recoveryReport
    after_recovery = $afterRecoveryReport
    steps = $steps
    artifacts = [ordered]@{
        already_present = $alreadyPresentArtifacts
        missing_before_salvage = $missingBeforeArtifacts
        stale_before_salvage = $staleBeforeArtifacts
        rebuilt = @($rebuiltArtifacts | Select-Object -Unique)
        remaining_missing_after_salvage = $remainingMissingAfterSalvage
        remaining_stale_after_salvage = $remainingStaleAfterSalvage
        session_salvage_report_json = $outputJsonPath
        session_salvage_report_markdown = $outputMarkdownPath
    }
}

Write-JsonFile -Path $outputJsonPath -Value $report
Write-TextFile -Path $outputMarkdownPath -Value (Get-SalvageMarkdown -Report $report)

Write-Host "Interrupted-session salvage:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Recovery verdict used: $recoveryVerdict"
Write-Host "  Recommended action used: $recommendedAction"
Write-Host "  Salvage allowed: $salvageAllowed"
Write-Host "  Salvage status: $salvageStatus"
Write-Host "  Structurally complete after salvage: $structurallyCompleteAfterSalvage"
Write-Host "  Session salvage report JSON: $outputJsonPath"
Write-Host "  Session salvage report Markdown: $outputMarkdownPath"

if (-not $salvageAllowed) {
    throw $explanation
}
if (-not $salvageCompletedSuccessfully) {
    throw $explanation
}

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    RecoveryVerdictUsed = $recoveryVerdict
    RecommendedActionUsed = $recommendedAction
    SalvageAllowed = $salvageAllowed
    SalvageStatus = $salvageStatus
    StructurallyCompleteAfterSalvage = $structurallyCompleteAfterSalvage
    SessionSalvageReportJsonPath = $outputJsonPath
    SessionSalvageReportMarkdownPath = $outputMarkdownPath
}
