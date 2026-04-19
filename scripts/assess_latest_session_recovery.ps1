[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PairRoot = "",
    [string]$PairsRoot = "",
    [string]$LabRoot = "",
    [string]$RegistryPath = "",
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

function Resolve-ArtifactCandidatePath {
    param(
        [string[]]$Candidates,
        [string]$BasePath = ""
    )

    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $resolvedCandidate = if ([System.IO.Path]::IsPathRooted($candidate)) {
            $candidate
        }
        elseif (-not [string]::IsNullOrWhiteSpace($BasePath)) {
            Join-Path $BasePath $candidate
        }
        else {
            Join-Path (Get-RepoRoot) $candidate
        }

        $resolved = Resolve-ExistingPath -Path $resolvedCandidate
        if ($resolved) {
            return $resolved
        }
    }

    return ""
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

function Resolve-PairScopedArtifactPath {
    param(
        [string[]]$Candidates,
        [string]$BasePath
    )

    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $resolved = Resolve-ArtifactCandidatePath -Candidates @($candidate) -BasePath $BasePath
        if (-not [string]::IsNullOrWhiteSpace($resolved) -and (Test-PathWithinRoot -Path $resolved -Root $BasePath)) {
            return $resolved
        }
    }

    return ""
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
        [object]$PairSummaryTimestampUtc
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ($null -eq $PairSummaryTimestampUtc) {
        return $false
    }

    $artifactTime = Get-ArtifactTimestampUtc -Path $Path
    if ($null -eq $artifactTime) {
        return $false
    }

    return $artifactTime -lt ([datetime]$PairSummaryTimestampUtc).AddSeconds(-1)
}

function New-ArtifactCheck {
    param(
        [string]$Name,
        [string]$Label,
        [string]$Path,
        [bool]$Expected,
        [bool]$MissingRecoverable,
        [string]$Explanation,
        [switch]$CheckStale,
        [object]$PairSummaryTimestampUtc = $null
    )

    $found = -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)
    $stale = $false
    if ($found -and $CheckStale) {
        $stale = Test-DerivedArtifactStale -Path $Path -PairSummaryTimestampUtc $PairSummaryTimestampUtc
    }

    return [ordered]@{
        name = $Name
        label = $Label
        path = $Path
        expected = $Expected
        found = $found
        stale = $stale
        missing_recoverable = if ($found) { $false } else { $MissingRecoverable }
        explanation = $Explanation
    }
}

function Get-FirstNonEmptyString {
    param([string[]]$Candidates)

    foreach ($candidate in @($Candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

function Test-MonitorVerdictSufficient {
    param([string]$Verdict)

    return $Verdict -in @(
        "sufficient-for-tuning-usable-review",
        "sufficient-for-scorecard"
    )
}

function Test-EvidenceSufficientFromSummary {
    param(
        [object]$PairSummary,
        [object]$Comparison,
        [object]$GuidedDocket
    )

    if ([bool](Get-ObjectPropertyValue -Object $GuidedDocket -Name "session_sufficient_for_tuning_usable_review" -Default $false)) {
        return $true
    }

    $pairClassification = [string](Get-ObjectPropertyValue -Object $PairSummary -Name "operator_note_classification" -Default "")
    if ($pairClassification -in @("tuning-usable", "strong-signal")) {
        return $true
    }

    $comparisonVerdict = [string](Get-ObjectPropertyValue -Object $Comparison -Name "comparison_verdict" -Default "")
    return $comparisonVerdict -in @("comparison-usable", "comparison-strong-signal")
}

function Get-RecoveryCommandList {
    param(
        [string]$NextAction,
        [string]$ResolvedPairRoot
    )

    switch ($NextAction) {
        "run-post-pipeline-only" {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\score_latest_pair_session.ps1 -PairRoot `"$ResolvedPairRoot`"",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_shadow_profile_review.ps1 -PairRoot `"$ResolvedPairRoot`" -Profiles conservative default responsive",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_latest_session_outcome_dossier.ps1 -PairRoot `"$ResolvedPairRoot`"",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\evaluate_latest_session_mission.ps1 -PairRoot `"$ResolvedPairRoot`""
            )
        }
        "rebuild-dossier-and-closeout" {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_latest_session_outcome_dossier.ps1 -PairRoot `"$ResolvedPairRoot`"",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\evaluate_latest_session_mission.ps1 -PairRoot `"$ResolvedPairRoot`"",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assess_latest_session_recovery.ps1 -PairRoot `"$ResolvedPairRoot`""
            )
        }
        "rerun-current-mission" {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1 -DryRun",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1"
            )
        }
        "rerun-current-mission-with-new-pair-root" {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1 -DryRun",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1"
            )
        }
        "discard-and-rerun" {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1 -DryRun",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1"
            )
        }
        "manual-review-required" {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_shadow_profile_review.ps1 -PairRoot `"$ResolvedPairRoot`" -Profiles conservative default responsive",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_latest_session_outcome_dossier.ps1 -PairRoot `"$ResolvedPairRoot`"",
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assess_latest_session_recovery.ps1 -PairRoot `"$ResolvedPairRoot`""
            )
        }
        default {
            return @(
                "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assess_latest_session_recovery.ps1 -PairRoot `"$ResolvedPairRoot`""
            )
        }
    }
}

function Get-RecommendedSalvageCommand {
    param(
        [string]$RecoveryVerdict,
        [string]$NextAction,
        [string]$ResolvedPairRoot
    )

    if (
        $RecoveryVerdict -in @(
            "session-interrupted-after-sufficiency-before-closeout",
            "session-interrupted-during-post-pipeline",
            "session-partial-artifacts-recoverable"
        ) -and
        $NextAction -in @(
            "run-post-pipeline-only",
            "rebuild-dossier-and-closeout"
        )
    ) {
        return "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\finalize_interrupted_session.ps1 -PairRoot `"$ResolvedPairRoot`""
    }

    return ""
}

function Get-RecoveryMarkdown {
    param([object]$Report)

    $lines = @(
        "# Session Recovery Report",
        "",
        "- Pair root: $($Report.pair_root)",
        "- Selection mode: $($Report.selection_mode)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Recovery verdict: $($Report.recovery_verdict)",
        "- Recommended next action: $($Report.recommended_next_action)",
        "- Recommended salvage command: $($Report.recommended_salvage_command)",
        "- Session complete: $($Report.recovery_state.session_complete)",
        "- Session interrupted: $($Report.recovery_state.session_interrupted)",
        "- Salvageable without replay: $($Report.recovery_state.salvageable_without_replay)",
        "- Nonrecoverable: $($Report.recovery_state.nonrecoverable)",
        "- Manual review required: $($Report.recovery_state.manual_review_required)",
        "- Explanation: $($Report.explanation)",
        "",
        "## Evidence And Closeout",
        "",
        "- Monitor verdict: $($Report.evidence.monitor_verdict)",
        "- Pair classification: $($Report.evidence.pair_classification)",
        "- Comparison verdict: $($Report.evidence.comparison_verdict)",
        "- Evidence sufficient: $($Report.evidence.evidence_sufficient)",
        "- Pair run completed: $($Report.closeout.pair_run_completed)",
        "- Post-pipeline started: $($Report.closeout.post_pipeline_started)",
        "- Core closeout complete: $($Report.closeout.core_closeout_complete)",
        "- Guided closeout complete: $($Report.closeout.guided_closeout_complete)",
        "- Mission-aware run: $($Report.closeout.mission_aware_run)",
        "- Strict mission audit required: $($Report.closeout.strict_mission_audit_required)",
        "- Guided-session artifacts detected: $($Report.closeout.guided_session_detected)",
        "",
        "## Certification And Registry",
        "",
        "- Registration disposition: $($Report.certification_registry.registration_disposition)",
        "- Register now: $($Report.certification_registry.register_in_registry_now)",
        "- Counts toward grounded certification now: $($Report.certification_registry.count_toward_grounded_certification_now)",
        "- Can count toward grounded certification after salvage: $($Report.certification_registry.can_count_toward_grounded_evidence_after_salvage)",
        "- Register only as workflow validation now: $($Report.certification_registry.register_only_as_workflow_validation_now)",
        "- Register only as non-grounded evidence now: $($Report.certification_registry.register_only_as_non_grounded_now)",
        "- Exclude from promotion logic now: $($Report.certification_registry.exclude_from_promotion_logic_now)",
        "- Explanation: $($Report.certification_registry.explanation)",
        "",
        "## Artifact Checks",
        ""
    )

    foreach ($artifact in @($Report.artifact_checks)) {
        $lines += "- $($artifact.label): expected=$($artifact.expected) found=$($artifact.found) stale=$($artifact.stale) missing_recoverable=$($artifact.missing_recoverable)"
        $lines += "  Path: $($artifact.path)"
        $lines += "  Explanation: $($artifact.explanation)"
    }

    if (@($Report.suggested_commands).Count -gt 0) {
        $lines += ""
        $lines += "## Suggested Commands"
        $lines += ""
        foreach ($command in @($Report.suggested_commands)) {
            $lines += "- $command"
        }
    }

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
$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
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

$guidedSessionRoot = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session")
$sessionStatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\session_state.json")
$finalDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\final_session_docket.json")
$pairSummaryPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "pair_summary.json")
$comparisonPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "comparison.json")
$scorecardPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "scorecard.json")
$shadowRecommendationPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "shadow_review\shadow_recommendation.json")
$monitorStatusPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "live_monitor_status.json")
$certificatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_evidence_certificate.json")
$groundedAnalysisPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_session_analysis.json")
$promotionGapDeltaPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "promotion_gap_delta.json")
$outcomeDossierPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "session_outcome_dossier.json")
$missionAttainmentPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "mission_attainment.json")

$sessionState = Read-JsonFile -Path $sessionStatePath
$guidedDocket = Read-JsonFile -Path $finalDocketPath
$pairSummary = Read-JsonFile -Path $pairSummaryPath
$comparisonPayload = Read-JsonFile -Path $comparisonPath
$comparison = if ($null -ne $comparisonPayload) {
    Get-ObjectPropertyValue -Object $comparisonPayload -Name "comparison" -Default $comparisonPayload
}
else {
    $null
}
$scorecard = Read-JsonFile -Path $scorecardPath
$shadowRecommendation = Read-JsonFile -Path $shadowRecommendationPath
$monitorStatus = Read-JsonFile -Path $monitorStatusPath
$certificate = Read-JsonFile -Path $certificatePath
$groundedAnalysis = Read-JsonFile -Path $groundedAnalysisPath
$promotionGapDelta = Read-JsonFile -Path $promotionGapDeltaPath
$outcomeDossier = Read-JsonFile -Path $outcomeDossierPath
$missionAttainment = Read-JsonFile -Path $missionAttainmentPath

$missionSnapshotPath = Resolve-PairScopedArtifactPath -Candidates @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $guidedDocket -Name "artifacts" -Default $null) -Name "mission_snapshot_json" -Default ""),
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionAttainment -Name "artifacts" -Default $null) -Name "mission_brief_json" -Default ""),
    (Join-Path $resolvedPairRoot "guided_session\mission\next_live_session_mission.json")
) -BasePath $resolvedPairRoot
$missionExecutionPath = Resolve-PairScopedArtifactPath -Candidates @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $guidedDocket -Name "artifacts" -Default $null) -Name "mission_execution_json" -Default ""),
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_execution" -Default $null) -Name "path" -Default ""),
    (Join-Path $resolvedPairRoot "guided_session\mission_execution.json")
) -BasePath $resolvedPairRoot
$monitorHistoryPath = Resolve-PairScopedArtifactPath -Candidates @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $guidedDocket -Name "artifacts" -Default $null) -Name "monitor_history_ndjson" -Default ""),
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $sessionState -Name "artifacts" -Default $null) -Name "monitor_history_ndjson" -Default ""),
    (Join-Path $resolvedPairRoot "guided_session\monitor_verdict_history.ndjson")
) -BasePath $resolvedPairRoot
$nextLivePlanPath = Resolve-PairScopedArtifactPath -Candidates @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $guidedDocket -Name "artifacts" -Default $null) -Name "next_live_plan_json" -Default ""),
    (Join-Path $resolvedPairRoot "guided_session\registry\next_live_plan.json")
) -BasePath $resolvedPairRoot

$missionExecution = Read-JsonFile -Path $missionExecutionPath
$missionSnapshot = Read-JsonFile -Path $missionSnapshotPath
$nextLivePlan = Read-JsonFile -Path $nextLivePlanPath

$pairSummaryTimestampUtc = Get-ArtifactTimestampUtc -Path $pairSummaryPath

$guidedSessionRootPresent = -not [string]::IsNullOrWhiteSpace($guidedSessionRoot)
$guidedSessionDetected = $guidedSessionRootPresent -and (
    -not [string]::IsNullOrWhiteSpace($sessionStatePath) -or
    -not [string]::IsNullOrWhiteSpace($finalDocketPath) -or
    -not [string]::IsNullOrWhiteSpace($missionExecutionPath) -or
    -not [string]::IsNullOrWhiteSpace($monitorHistoryPath) -or
    -not [string]::IsNullOrWhiteSpace($nextLivePlanPath)
)
$strictMissionAuditRequired = $guidedSessionDetected -or -not [string]::IsNullOrWhiteSpace($missionExecutionPath)
$missionAwareRun = $strictMissionAuditRequired -or -not [string]::IsNullOrWhiteSpace($missionSnapshotPath) -or -not [string]::IsNullOrWhiteSpace($missionAttainmentPath)
$pairRunCompleted = -not [string]::IsNullOrWhiteSpace($pairSummaryPath)

$monitorVerdict = Get-FirstNonEmptyString -Candidates @(
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $sessionState -Name "monitor" -Default $null) -Name "current_verdict" -Default ""),
    [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $guidedDocket -Name "monitor" -Default $null) -Name "last_verdict" -Default ""),
    [string](Get-ObjectPropertyValue -Object $monitorStatus -Name "current_verdict" -Default ""),
    [string](Get-ObjectPropertyValue -Object $certificate -Name "monitor_verdict" -Default "")
)
$pairClassification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
$comparisonVerdict = [string](Get-ObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default "")
$evidenceSufficient = Test-MonitorVerdictSufficient -Verdict $monitorVerdict
if (-not $evidenceSufficient) {
    $evidenceSufficient = Test-EvidenceSufficientFromSummary -PairSummary $pairSummary -Comparison $comparison -GuidedDocket $guidedDocket
}

$postPipelineStarted = (
    [string](Get-ObjectPropertyValue -Object $sessionState -Name "stage" -Default "") -like "post-pipeline*" -or
    -not [string]::IsNullOrWhiteSpace($scorecardPath) -or
    -not [string]::IsNullOrWhiteSpace($shadowRecommendationPath) -or
    -not [string]::IsNullOrWhiteSpace($certificatePath) -or
    -not [string]::IsNullOrWhiteSpace($groundedAnalysisPath) -or
    -not [string]::IsNullOrWhiteSpace($promotionGapDeltaPath) -or
    -not [string]::IsNullOrWhiteSpace($outcomeDossierPath) -or
    -not [string]::IsNullOrWhiteSpace($missionAttainmentPath) -or
    -not [string]::IsNullOrWhiteSpace($nextLivePlanPath) -or
    -not [string]::IsNullOrWhiteSpace($finalDocketPath)
)

$postPipelineArtifactsFoundCount = @(
    $scorecardPath,
    $shadowRecommendationPath,
    $certificatePath,
    $groundedAnalysisPath,
    $promotionGapDeltaPath,
    $outcomeDossierPath,
    $missionAttainmentPath,
    $nextLivePlanPath,
    $finalDocketPath
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Measure-Object | Select-Object -ExpandProperty Count

$coreCloseoutComplete = @(
    $scorecardPath,
    $shadowRecommendationPath,
    $certificatePath,
    $groundedAnalysisPath,
    $promotionGapDeltaPath,
    $outcomeDossierPath,
    $missionAttainmentPath
) -notcontains ""
$guidedCloseoutComplete = $coreCloseoutComplete -and ((-not $guidedSessionDetected) -or (-not [string]::IsNullOrWhiteSpace($finalDocketPath)))

$manualReviewFlag = (
    [string](Get-ObjectPropertyValue -Object $scorecard -Name "recommendation" -Default "") -eq "manual-review-needed" -or
    [bool](Get-ObjectPropertyValue -Object $shadowRecommendation -Name "manual_review_needed" -Default $false) -or
    [bool](Get-ObjectPropertyValue -Object $certificate -Name "manual_review_needed" -Default $false) -or
    [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $guidedDocket -Name "recommendations" -Default $null) -Name "operator_action" -Default $null) -Name "review_manually" -Default $false)
)

$rawEvidenceRecoverable = $pairRunCompleted -and -not [string]::IsNullOrWhiteSpace($comparisonPath)
$missionCriticalMissing = $strictMissionAuditRequired -and (([string]::IsNullOrWhiteSpace($missionSnapshotPath)) -or ([string]::IsNullOrWhiteSpace($missionExecutionPath)))

$artifactChecks = @()
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "mission_snapshot" -Label "Mission snapshot" -Path $missionSnapshotPath -Expected $missionAwareRun -MissingRecoverable $false -Explanation $(if ($missionAwareRun) { "Mission-aware guided runs should preserve the exact mission snapshot used for launch. If it is missing, later mission-attainment claims need manual review." } else { "This pair does not clearly advertise mission-aware launch metadata, so a mission snapshot is not strictly required." }) -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "mission_execution" -Label "Mission execution artifact" -Path $missionExecutionPath -Expected $strictMissionAuditRequired -MissingRecoverable $false -Explanation $(if ($strictMissionAuditRequired) { "Modern mission-driven runs should preserve the exact launch record. Missing mission execution means launch drift can no longer be audited honestly." } else { "This pair only exposes legacy mission metadata, so a mission execution record is helpful but not strictly required." }) -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "session_state" -Label "Guided session state" -Path $sessionStatePath -Expected $guidedSessionDetected -MissingRecoverable $false -Explanation $(if ($guidedSessionDetected) { "Guided sessions now write session_state.json to help interrupted-run assessment. Older guided artifacts may be missing it." } else { "No guided-session wrapper artifacts were detected, so a guided session-state marker is optional." }) -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "monitor_status" -Label "Monitor status" -Path $monitorStatusPath -Expected $pairRunCompleted -MissingRecoverable $pairRunCompleted -Explanation "The live monitor status helps distinguish insufficient runs from sufficient runs that only missed closeout. It can usually be regenerated from the saved pair root." -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "pair_summary" -Label "Pair summary" -Path $pairSummaryPath -Expected $true -MissingRecoverable $false -Explanation "pair_summary.json is the minimum structural artifact for trustworthy recovery assessment." -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "comparison" -Label "Comparison artifact" -Path $comparisonPath -Expected $pairRunCompleted -MissingRecoverable $pairRunCompleted -Explanation "comparison.json is the minimum control-vs-treatment evidence summary needed for honest salvage or rerun decisions." -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "scorecard" -Label "Scorecard" -Path $scorecardPath -Expected $pairRunCompleted -MissingRecoverable $rawEvidenceRecoverable -Explanation "The scorecard is part of the post-pipeline closeout and is usually recoverable as long as the raw pair summary and comparison survive." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "shadow_review" -Label "Shadow review" -Path $shadowRecommendationPath -Expected $pairRunCompleted -MissingRecoverable $rawEvidenceRecoverable -Explanation "The shadow review is derived from the saved treatment lane and is usually recoverable without replaying the live run." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "grounded_evidence_certificate" -Label "Grounded evidence certificate" -Path $certificatePath -Expected $pairRunCompleted -MissingRecoverable $rawEvidenceRecoverable -Explanation "Certification is derived from the saved pair and can usually be rerun if the raw pair artifacts are intact." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "grounded_session_analysis" -Label "Latest-session delta analysis" -Path $groundedAnalysisPath -Expected $pairRunCompleted -MissingRecoverable $rawEvidenceRecoverable -Explanation "The latest-session analysis compares the registry with and without this pair counted. It can usually be rebuilt if pair_summary survives." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "promotion_gap_delta" -Label "Promotion gap delta" -Path $promotionGapDeltaPath -Expected $pairRunCompleted -MissingRecoverable $rawEvidenceRecoverable -Explanation "promotion_gap_delta.json is the machine-readable delta layer behind the latest-session analysis." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "next_live_plan" -Label "Next-live planner output" -Path $nextLivePlanPath -Expected ($pairRunCompleted -and ($postPipelineStarted -or $guidedSessionDetected)) -MissingRecoverable $rawEvidenceRecoverable -Explanation "The next-live plan is a post-pipeline planning artifact. It is useful for recovery context, but older validation packs may still be structurally complete without it." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "session_outcome_dossier" -Label "Outcome dossier" -Path $outcomeDossierPath -Expected $pairRunCompleted -MissingRecoverable $rawEvidenceRecoverable -Explanation "The outcome dossier consolidates certification, delta, and next-action context. It is usually recoverable when the pair summary still exists." -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "mission_attainment" -Label "Mission attainment output" -Path $missionAttainmentPath -Expected ($pairRunCompleted -and $missionAwareRun) -MissingRecoverable ($pairRunCompleted -and -not [string]::IsNullOrWhiteSpace($missionSnapshotPath) -and -not [string]::IsNullOrWhiteSpace($missionExecutionPath)) -Explanation $(if ($missionAwareRun) { "Mission attainment is expected for mission-aware runs and can be rebuilt only while the mission snapshot and mission execution record remain intact." } else { "This pair does not clearly advertise mission-aware launch metadata, so mission attainment is optional." }) -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)
$artifactChecks += [pscustomobject](New-ArtifactCheck -Name "final_session_docket" -Label "Final session docket" -Path $finalDocketPath -Expected $guidedSessionDetected -MissingRecoverable $false -Explanation $(if ($guidedSessionDetected) { "The final docket is the guided-session wrapper summary. Missing it does not always invalidate the pair, but it does mean the wrapper closeout did not finish cleanly." } else { "No guided-session wrapper artifacts were detected, so a final docket is optional." }) -CheckStale -PairSummaryTimestampUtc $pairSummaryTimestampUtc)

$missingExpectedArtifacts = @($artifactChecks | Where-Object { $_.expected -and -not $_.found })
$staleArtifacts = @($artifactChecks | Where-Object { $_.found -and $_.stale })
$staleCriticalArtifacts = @($artifactChecks | Where-Object {
    $_.found -and $_.stale -and $_.name -in @(
        "scorecard",
        "grounded_evidence_certificate",
        "grounded_session_analysis",
        "promotion_gap_delta",
        "session_outcome_dossier",
        "mission_attainment",
        "final_session_docket"
    )
})
$hasArtifactInconsistency = $staleCriticalArtifacts.Count -gt 0

$evidenceOrigin = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $certificate -Name "evidence_origin" -Default ""))
$rehearsalMode = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Default $false)
$syntheticFixture = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Default $false)
$validationOnly = [bool](Get-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Default $false)
$workflowValidationEvidence = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_only_as_workflow_validation" -Default ($validationOnly -or $rehearsalMode -or $syntheticFixture))
$liveGroundableEvidence = (
    $evidenceOrigin -eq "live" -and
    -not $rehearsalMode -and
    -not $syntheticFixture -and
    -not $validationOnly
)

$countTowardGroundedNow = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
$registerOnlyWorkflowNow = $coreCloseoutComplete -and $workflowValidationEvidence
$registerOnlyNonGroundedNow = $coreCloseoutComplete -and -not $countTowardGroundedNow -and -not $registerOnlyWorkflowNow
$registerNow = $coreCloseoutComplete -and -not $missionCriticalMissing -and -not $hasArtifactInconsistency
$canCountTowardGroundedAfterSalvage = $rawEvidenceRecoverable -and $evidenceSufficient -and $liveGroundableEvidence -and -not $missionCriticalMissing
$excludeFromPromotionNow = -not $countTowardGroundedNow

$recoveryVerdict = ""
$recommendedNextAction = ""
$explanation = ""

if (-not $pairRunCompleted) {
    if ($rawEvidenceRecoverable) {
        $recoveryVerdict = "session-manual-review-needed"
        $recommendedNextAction = "manual-review-required"
        $explanation = "The pair root is missing pair_summary.json even though some comparison evidence exists. That is too inconsistent for an automatic salvage decision."
    }
    else {
        $recoveryVerdict = "session-nonrecoverable-rerun-required"
        $recommendedNextAction = if ($missionAwareRun) { "discard-and-rerun" } else { "rerun-current-mission" }
        $explanation = "The pair root does not contain the minimum pair summary needed for trustworthy closeout. Discard this partial session and rerun."
    }
}
elseif ($missionCriticalMissing -and $coreCloseoutComplete) {
    $recoveryVerdict = "session-manual-review-needed"
    $recommendedNextAction = "manual-review-required"
    $explanation = "The closeout stack is mostly present, but mission-critical launch artifacts are missing. Do not treat this as mission-clean without operator review."
}
elseif ($coreCloseoutComplete) {
    if ($manualReviewFlag -or $hasArtifactInconsistency -or ($guidedSessionDetected -and -not [string]::IsNullOrWhiteSpace($missionExecutionPath) -and [string]::IsNullOrWhiteSpace($finalDocketPath))) {
        $recoveryVerdict = "session-complete-pending-review-only"
        $recommendedNextAction = "no-recovery-needed"
        if ($manualReviewFlag) {
            $explanation = "The session completed structurally, but one of the review layers already requested manual review."
        }
        elseif ($hasArtifactInconsistency) {
            $explanation = "The session completed structurally, but one or more closeout artifacts look stale relative to pair_summary.json. Treat it as complete pending review, not as silently clean."
        }
        else {
            $explanation = "The core closeout stack is complete, but the guided-session wrapper summary is missing. Treat the session as complete with noncritical wrapper drift."
        }
    }
    else {
        $recoveryVerdict = "session-complete"
        $recommendedNextAction = "no-recovery-needed"
        $explanation = "The pair summary, certification, delta analysis, outcome dossier, and mission-attainment layers are all present. No recovery action is required."
    }
}
elseif ($hasArtifactInconsistency -and $rawEvidenceRecoverable) {
    $recoveryVerdict = "session-partial-artifacts-recoverable"
    $recommendedNextAction = "rebuild-dossier-and-closeout"
    $explanation = "The raw pair evidence survives, but one or more derived closeout artifacts look stale. Rebuild the closeout layer instead of replaying the live session."
}
elseif ($evidenceSufficient) {
    if (-not $postPipelineStarted) {
        $recoveryVerdict = "session-interrupted-after-sufficiency-before-closeout"
        $recommendedNextAction = "run-post-pipeline-only"
        $explanation = "The saved pair evidence already cleared the sufficiency gate, but the post-pipeline closeout never started."
    }
    elseif ($rawEvidenceRecoverable) {
        $recoveryVerdict = "session-interrupted-during-post-pipeline"
        $recommendedNextAction = "rebuild-dossier-and-closeout"
        $explanation = "The pair evidence is sufficient and some post-pipeline artifacts exist, but the closeout stack is incomplete."
    }
    else {
        $recoveryVerdict = "session-partial-artifacts-recoverable"
        $recommendedNextAction = "rebuild-dossier-and-closeout"
        $explanation = "The saved evidence appears sufficient, but the artifact set is incomplete enough that closeout should be rebuilt conservatively."
    }
}
elseif ($rawEvidenceRecoverable) {
    $recoveryVerdict = "session-interrupted-before-sufficiency"
    $recommendedNextAction = if ($missionAwareRun) { "rerun-current-mission-with-new-pair-root" } else { "rerun-current-mission" }
    $explanation = "The saved pair ended before the sufficiency gate cleared. Finish the paperwork if you want the record, but do not count it as a candidate grounded session. Rerun the mission instead."
}
else {
    $recoveryVerdict = "session-nonrecoverable-rerun-required"
    $recommendedNextAction = if ($missionAwareRun) { "discard-and-rerun" } else { "rerun-current-mission" }
    $explanation = "Critical raw pair artifacts are missing, and the remaining evidence is too weak to salvage honestly."
}

$sessionComplete = $recoveryVerdict -in @("session-complete", "session-complete-pending-review-only")
$sessionInterrupted = $recoveryVerdict -in @(
    "session-interrupted-before-sufficiency",
    "session-interrupted-after-sufficiency-before-closeout",
    "session-interrupted-during-post-pipeline"
)
$salvageableWithoutReplay = $recommendedNextAction -in @("run-post-pipeline-only", "rebuild-dossier-and-closeout")
$manualReviewRequired = $recoveryVerdict -eq "session-manual-review-needed"
$nonrecoverable = $recoveryVerdict -eq "session-nonrecoverable-rerun-required"

$registrationDisposition = if ($registerNow -and $countTowardGroundedNow) {
    "grounded-evidence"
}
elseif ($registerNow -and $registerOnlyWorkflowNow) {
    "workflow-validation-only"
}
elseif ($registerNow -and $registerOnlyNonGroundedNow) {
    "non-grounded-excluded"
}
elseif ($canCountTowardGroundedAfterSalvage) {
    "not-ready-can-be-certified-after-salvage"
}
elseif ($salvageableWithoutReplay -and $workflowValidationEvidence) {
    "not-ready-workflow-validation-after-salvage"
}
else {
    "not-ready-rerun-required"
}

$certificationExplanation = if ($registerNow -and $countTowardGroundedNow) {
    "This session already has a complete closeout stack and currently counts toward grounded promotion evidence."
}
elseif ($registerNow -and $registerOnlyWorkflowNow) {
    "This session is structurally complete, but it stays visible only as workflow-validation evidence and remains excluded from promotion logic."
}
elseif ($registerNow -and $registerOnlyNonGroundedNow) {
    "This session is structurally complete, but it remains non-grounded evidence and must stay excluded from promotion logic."
}
elseif ($canCountTowardGroundedAfterSalvage) {
    "The saved pair evidence is strong enough that a rebuilt closeout stack may still certify it as grounded evidence after salvage."
}
elseif ($salvageableWithoutReplay) {
    "The pair may still be worth salvaging operationally, but the current evidence is not eligible to count toward grounded promotion logic."
}
else {
    "Do not count this session toward grounded evidence or promotion logic in its current state."
}

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    Join-Path $resolvedPairRoot "session_recovery_report.json"
}
else {
    Get-AbsolutePath -Path $OutputJson -BasePath $resolvedPairRoot
}
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    Join-Path $resolvedPairRoot "session_recovery_report.md"
}
else {
    Get-AbsolutePath -Path $OutputMarkdown -BasePath $resolvedPairRoot
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    selection_mode = $selectionMode
    pair_root = $resolvedPairRoot
    registry_path = $resolvedRegistryPath
    recovery_verdict = $recoveryVerdict
    recommended_next_action = $recommendedNextAction
    recommended_salvage_command = (Get-RecommendedSalvageCommand -RecoveryVerdict $recoveryVerdict -NextAction $recommendedNextAction -ResolvedPairRoot $resolvedPairRoot)
    explanation = $explanation
    recovery_state = [ordered]@{
        session_complete = $sessionComplete
        session_interrupted = $sessionInterrupted
        salvageable_without_replay = $salvageableWithoutReplay
        nonrecoverable = $nonrecoverable
        manual_review_required = $manualReviewRequired
    }
    evidence = [ordered]@{
        monitor_verdict = $monitorVerdict
        pair_classification = $pairClassification
        comparison_verdict = $comparisonVerdict
        evidence_sufficient = $evidenceSufficient
        evidence_origin = $evidenceOrigin
        rehearsal_mode = $rehearsalMode
        synthetic_fixture = $syntheticFixture
        validation_only = $validationOnly
    }
    closeout = [ordered]@{
        pair_run_completed = $pairRunCompleted
        post_pipeline_started = $postPipelineStarted
        post_pipeline_artifacts_found_count = $postPipelineArtifactsFoundCount
        core_closeout_complete = $coreCloseoutComplete
        guided_closeout_complete = $guidedCloseoutComplete
        mission_aware_run = $missionAwareRun
        strict_mission_audit_required = $strictMissionAuditRequired
        guided_session_detected = $guidedSessionDetected
        mission_critical_artifacts_missing = $missionCriticalMissing
        missing_expected_artifacts_count = $missingExpectedArtifacts.Count
        stale_artifacts_count = $staleArtifacts.Count
    }
    certification_registry = [ordered]@{
        current_certification_verdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
        registration_disposition = $registrationDisposition
        register_in_registry_now = $registerNow
        count_toward_grounded_certification_now = $countTowardGroundedNow
        can_count_toward_grounded_evidence_after_salvage = $canCountTowardGroundedAfterSalvage
        register_only_as_workflow_validation_now = $registerOnlyWorkflowNow
        register_only_as_non_grounded_now = $registerOnlyNonGroundedNow
        exclude_from_promotion_logic_now = $excludeFromPromotionNow
        explanation = $certificationExplanation
    }
    artifact_checks = $artifactChecks
    suggested_commands = @(Get-RecoveryCommandList -NextAction $recommendedNextAction -ResolvedPairRoot $resolvedPairRoot)
    artifacts = [ordered]@{
        session_state_json = $sessionStatePath
        final_session_docket_json = $finalDocketPath
        mission_snapshot_json = $missionSnapshotPath
        mission_execution_json = $missionExecutionPath
        monitor_status_json = $monitorStatusPath
        monitor_history_ndjson = $monitorHistoryPath
        pair_summary_json = $pairSummaryPath
        comparison_json = $comparisonPath
        scorecard_json = $scorecardPath
        shadow_recommendation_json = $shadowRecommendationPath
        grounded_evidence_certificate_json = $certificatePath
        grounded_session_analysis_json = $groundedAnalysisPath
        promotion_gap_delta_json = $promotionGapDeltaPath
        next_live_plan_json = $nextLivePlanPath
        session_outcome_dossier_json = $outcomeDossierPath
        mission_attainment_json = $missionAttainmentPath
        session_recovery_report_json = $outputJsonPath
        session_recovery_report_markdown = $outputMarkdownPath
    }
}

Write-JsonFile -Path $outputJsonPath -Value $report
Write-TextFile -Path $outputMarkdownPath -Value (Get-RecoveryMarkdown -Report $report)

Write-Host "Session recovery assessment:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Recovery verdict: $recoveryVerdict"
Write-Host "  Recommended next action: $recommendedNextAction"
Write-Host "  Session complete: $sessionComplete"
Write-Host "  Session interrupted: $sessionInterrupted"
Write-Host "  Salvageable without replay: $salvageableWithoutReplay"
Write-Host "  Session recovery report JSON: $outputJsonPath"
Write-Host "  Session recovery report Markdown: $outputMarkdownPath"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    RecoveryVerdict = $recoveryVerdict
    RecommendedNextAction = $recommendedNextAction
    SessionComplete = $sessionComplete
    SessionInterrupted = $sessionInterrupted
    SalvageableWithoutReplay = $salvageableWithoutReplay
    SessionRecoveryReportJsonPath = $outputJsonPath
    SessionRecoveryReportMarkdownPath = $outputMarkdownPath
}
