[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$FailureModes = @(
        "already-complete",
        "after-sufficiency-before-closeout",
        "during-post-pipeline",
        "partial-artifacts-recoverable",
        "before-sufficiency",
        "missing-mission-snapshot"
    ),
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$BasePairRoot = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$RehearsalFixtureId = "strong_signal_keep_conservative",
    [int]$RehearsalStepSeconds = 2,
    [int]$MonitorPollSeconds = 1
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

function Get-BooleanSafe {
    param([object]$Value)

    return [bool]$Value
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

function Get-ExpectedBranchCatalog {
    $catalog = [ordered]@{}

    $catalog["already-complete"] = [ordered]@{
        expected_recovery_verdict = "session-complete"
        expected_continuation_action = "session-already-complete-no-action"
        expected_final_recovery_verdict = "session-complete"
        expected_salvage_ran = $false
        expected_rerun_selected = $false
        expected_manual_review_selected = $false
        expected_structurally_complete_after_continuation = $true
        expected_branch_type = "no-action"
    }
    $catalog["after-sufficiency-before-closeout"] = [ordered]@{
        expected_recovery_verdict = "session-interrupted-after-sufficiency-before-closeout"
        expected_continuation_action = "salvage-interrupted-session"
        expected_final_recovery_verdict = "session-complete"
        expected_salvage_ran = $true
        expected_rerun_selected = $false
        expected_manual_review_selected = $false
        expected_structurally_complete_after_continuation = $true
        expected_branch_type = "salvage"
    }
    $catalog["during-post-pipeline"] = [ordered]@{
        expected_recovery_verdict = "session-interrupted-during-post-pipeline"
        expected_continuation_action = "salvage-interrupted-session"
        expected_final_recovery_verdict = "session-complete"
        expected_salvage_ran = $true
        expected_rerun_selected = $false
        expected_manual_review_selected = $false
        expected_structurally_complete_after_continuation = $true
        expected_branch_type = "salvage"
    }
    $catalog["partial-artifacts-recoverable"] = [ordered]@{
        expected_recovery_verdict = "session-partial-artifacts-recoverable"
        expected_continuation_action = "salvage-interrupted-session"
        expected_final_recovery_verdict = "session-complete"
        expected_salvage_ran = $true
        expected_rerun_selected = $false
        expected_manual_review_selected = $false
        expected_structurally_complete_after_continuation = $true
        expected_branch_type = "salvage"
    }
    $catalog["before-sufficiency"] = [ordered]@{
        expected_recovery_verdict = "session-interrupted-before-sufficiency"
        expected_continuation_action = "rerun-current-mission-with-new-pair-root"
        expected_final_recovery_verdict = "session-complete"
        expected_salvage_ran = $false
        expected_rerun_selected = $true
        expected_manual_review_selected = $false
        expected_structurally_complete_after_continuation = $true
        expected_branch_type = "rerun"
    }
    $catalog["missing-mission-snapshot"] = [ordered]@{
        expected_recovery_verdict = "session-manual-review-needed"
        expected_continuation_action = "manual-review-required"
        expected_final_recovery_verdict = "session-manual-review-needed"
        expected_salvage_ran = $false
        expected_rerun_selected = $false
        expected_manual_review_selected = $true
        expected_structurally_complete_after_continuation = $true
        expected_branch_type = "manual-review"
    }

    return $catalog
}

function Get-PairRegistryPath {
    param([string]$PairRoot)

    $sessionState = Read-JsonFile -Path (Join-Path $PairRoot "guided_session\session_state.json")
    $artifacts = Get-ObjectPropertyValue -Object $sessionState -Name "artifacts" -Default $null

    foreach ($candidate in @(
            [string](Get-ObjectPropertyValue -Object $artifacts -Name "registry_path" -Default ""),
            (Join-Path $PairRoot "guided_session\registry\pair_sessions.ndjson"),
            (Join-Path $PairRoot "analysis_scenarios\with_latest\pair_sessions.ndjson"),
            (Join-Path $PairRoot "analysis_scenarios\materialized_latest\pair_sessions.ndjson")
        )) {
        $resolved = Resolve-ExistingPath -Path $candidate
        if ($resolved) {
            return $resolved
        }
    }

    return ""
}

function Get-RecoveryMatrixMarkdown {
    param([object]$Matrix)

    $lines = @(
        "# Recovery Branch Matrix",
        "",
        "- Prompt ID: $($Matrix.prompt_id)",
        "- Matrix root: $($Matrix.matrix_root)",
        "- Continuation rehearsal suite root: $($Matrix.continuation_rehearsal_suite_root)",
        "- Mission path used: $($Matrix.mission_path_used)",
        "- Overall pass: $($Matrix.overall_pass)",
        ""
    )

    foreach ($branch in @($Matrix.branches)) {
        $lines += "## $($branch.branch_name)"
        $lines += ""
        $lines += "- Expected recovery verdict: $($branch.expected_recovery_verdict)"
        $lines += "- Actual recovery verdict: $($branch.actual_recovery_verdict)"
        $lines += "- Expected continuation action: $($branch.expected_continuation_action)"
        $lines += "- Actual continuation action: $($branch.actual_continuation_action)"
        $lines += "- Expected final recovery verdict: $($branch.expected_final_recovery_verdict)"
        $lines += "- Actual final recovery verdict: $($branch.actual_final_recovery_verdict)"
        $lines += "- Salvage ran: $($branch.salvage_ran)"
        $lines += "- Rerun selected: $($branch.rerun_selected)"
        $lines += "- Manual review selected: $($branch.manual_review_selected)"
        $lines += "- Structurally complete after continuation: $($branch.structurally_complete_after_continuation)"
        $lines += "- Excluded from promotion: $($branch.remained_excluded_from_promotion)"
        $lines += "- Registry remained branch-local: $($branch.registry_is_branch_local)"
        $lines += "- Branch pass: $($branch.branch_pass)"
        $lines += "- Staged by: $($branch.staged_by)"
        $lines += "- Explanation: $($branch.explanation)"
        $lines += ""
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-RecoveryReadinessMarkdown {
    param([object]$Certificate)

    $lines = @(
        "# Recovery Readiness Certificate",
        "",
        "- Prompt ID: $($Certificate.prompt_id)",
        "- Overall verdict: $($Certificate.overall_verdict)",
        "- Continuation controller behaved conservatively: $($Certificate.continuation_controller_behaved_conservatively)",
        "- Rehearsal evidence stayed excluded from promotion: $($Certificate.rehearsal_evidence_stayed_excluded_from_promotion)",
        "- Salvaged rehearsal registries stayed isolated: $($Certificate.salvaged_rehearsal_registries_stayed_isolated)",
        "- Responsive gate stayed closed on rehearsal-only evidence: $($Certificate.responsive_gate_stayed_closed_on_rehearsal_only_evidence)",
        "- Remaining gap should stop next real conservative run: $($Certificate.remaining_gap_should_stop_next_real_conservative_run)",
        "- Explanation: $($Certificate.explanation)",
        "",
        "## Fully Validated Branches",
        ""
    )

    if (@($Certificate.fully_validated_branches).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($branch in @($Certificate.fully_validated_branches)) {
            $lines += "- $branch"
        }
    }

    $lines += ""
    $lines += "## Branches With Gaps"
    $lines += ""
    if (@($Certificate.branches_with_gaps).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($gap in @($Certificate.branches_with_gaps)) {
            $lines += "- $($gap.branch_name): $($gap.reason)"
        }
    }

    $lines += ""
    $lines += "## Previously Unclosed Branches"
    $lines += ""
    foreach ($branch in @($Certificate.previously_unclosed_branches_now_covered.PSObject.Properties)) {
        $lines += "- $($branch.Name): covered=$($branch.Value.covered); pass=$($branch.Value.pass)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$requiredFailureModes = @(
    "already-complete",
    "after-sufficiency-before-closeout",
    "during-post-pipeline",
    "partial-artifacts-recoverable",
    "before-sufficiency",
    "missing-mission-snapshot"
)
$expectedCatalog = Get-ExpectedBranchCatalog
$resolvedLabRoot = if ($LabRoot) { Get-AbsolutePath -Path $LabRoot } else { Get-LabRootDefault }
$matrixStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$matrixRoot = if ($OutputRoot) {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
}
else {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) ("recovery_branch_matrix\matrix-{0}" -f $matrixStamp))
}
$rehearsalSuiteRoot = Ensure-Directory -Path (Join-Path $matrixRoot "rehearsal_suite")

$rehearsalArgs = [ordered]@{
    FailureModes = @($FailureModes)
    LabRoot = $resolvedLabRoot
    OutputRoot = $rehearsalSuiteRoot
    RehearsalFixtureId = $RehearsalFixtureId
    RehearsalStepSeconds = $RehearsalStepSeconds
    MonitorPollSeconds = $MonitorPollSeconds
}
if ($MissionPath) {
    $rehearsalArgs.MissionPath = Get-AbsolutePath -Path $MissionPath
}
if ($MissionMarkdownPath) {
    $rehearsalArgs.MissionMarkdownPath = Get-AbsolutePath -Path $MissionMarkdownPath
}
if ($BasePairRoot) {
    $rehearsalArgs.BasePairRoot = Get-AbsolutePath -Path $BasePairRoot
}

$rehearsalResult = & (Join-Path $PSScriptRoot "run_mission_continuation_rehearsal.ps1") @rehearsalArgs
$continuationRehearsalSuiteRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rehearsalResult -Name "SuiteRoot" -Default $rehearsalSuiteRoot))
$suiteSummaryJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rehearsalResult -Name "RehearsalSuiteSummaryJsonPath" -Default (Join-Path $continuationRehearsalSuiteRoot "rehearsal_suite_summary.json")))
$suiteSummary = Read-JsonFile -Path $suiteSummaryJsonPath
$basePairRootUsed = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rehearsalResult -Name "BasePairRoot" -Default (Get-ObjectPropertyValue -Object $suiteSummary -Name "base_pair_root" -Default "")))
$missionPathUsed = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $rehearsalResult -Name "MissionPathUsed" -Default (Get-ObjectPropertyValue -Object $suiteSummary -Name "mission_path_used" -Default "")))

$branchMatrixRows = @()
$fullyValidatedBranches = @()
$branchesWithGaps = @()

foreach ($requiredMode in $requiredFailureModes) {
    $expected = $expectedCatalog[$requiredMode]
    $branchPairRoot = Join-Path (Join-Path $continuationRehearsalSuiteRoot "branches") $requiredMode
    $branchReportJsonPath = Resolve-ExistingPath -Path (Join-Path $branchPairRoot "continuation_rehearsal_report.json")
    $failureInjectionReportJsonPath = Resolve-ExistingPath -Path (Join-Path $branchPairRoot "failure_injection_report.json")
    $failureInjectionReport = Read-JsonFile -Path $failureInjectionReportJsonPath

    if (-not $branchReportJsonPath) {
        $branchRow = [ordered]@{
            branch_name = $requiredMode
            staged_by = "missing-branch-report"
            staging_explanation = "The rehearsal suite did not produce a branch report for this required recovery branch."
            expected_recovery_verdict = $expected.expected_recovery_verdict
            actual_recovery_verdict = ""
            expected_continuation_action = $expected.expected_continuation_action
            actual_continuation_action = ""
            expected_final_recovery_verdict = $expected.expected_final_recovery_verdict
            actual_final_recovery_verdict = ""
            salvage_ran = $false
            rerun_selected = $false
            manual_review_selected = $false
            structurally_complete_after_continuation = $false
            remained_excluded_from_promotion = $false
            registry_path = ""
            registry_is_branch_local = $false
            responsive_gate_verdict = ""
            branch_pass = $false
            explanation = "Required branch '$requiredMode' was not produced by the continuation rehearsal suite."
            artifacts = [ordered]@{
                continuation_rehearsal_report_json = ""
                failure_injection_report_json = $failureInjectionReportJsonPath
            }
        }
        $branchMatrixRows += [pscustomobject]$branchRow
        $branchesWithGaps += [pscustomobject]@{
            branch_name = $requiredMode
            reason = $branchRow.explanation
        }
        continue
    }

    $branchReport = Read-JsonFile -Path $branchReportJsonPath
    $resultPairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $branchReport -Name "result_pair_root" -Default ""))
    $promotionSafety = Get-ObjectPropertyValue -Object $branchReport -Name "promotion_safety" -Default $null
    $rehearsalMode = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $promotionSafety -Name "rehearsal_mode" -Default $false)
    $validationOnly = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $promotionSafety -Name "validation_only" -Default $false)
    $excludedFromPromotion = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $promotionSafety -Name "exclude_from_promotion_logic_now" -Default $false)
    $countTowardGrounded = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $promotionSafety -Name "count_toward_grounded_certification_now" -Default $false)
    $responsiveGateVerdict = [string](Get-ObjectPropertyValue -Object $promotionSafety -Name "responsive_gate_verdict" -Default "")
    $registryPath = Get-PairRegistryPath -PairRoot $resultPairRoot
    $registryIsBranchLocal = Test-PathWithinRoot -Path $registryPath -Root $resultPairRoot
    $structurallyCompleteAfterContinuation = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $branchReport -Name "structurally_complete_after_continuation" -Default $false)
    $salvageRan = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $branchReport -Name "salvage_ran" -Default $false)
    $rerunSelected = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $branchReport -Name "rerun_selected" -Default $false)
    $manualReviewSelected = Get-BooleanSafe -Value (Get-ObjectPropertyValue -Object $branchReport -Name "manual_review_selected" -Default $false)
    $actualRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $branchReport -Name "initial_recovery_verdict" -Default "")
    $actualContinuationAction = [string](Get-ObjectPropertyValue -Object $branchReport -Name "continuation_decision" -Default "")
    $actualFinalRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $branchReport -Name "final_recovery_verdict" -Default "")

    $mismatches = @()
    if ($actualRecoveryVerdict -ne $expected.expected_recovery_verdict) {
        $mismatches += "expected recovery verdict '$($expected.expected_recovery_verdict)' but got '$actualRecoveryVerdict'"
    }
    if ($actualContinuationAction -ne $expected.expected_continuation_action) {
        $mismatches += "expected continuation action '$($expected.expected_continuation_action)' but got '$actualContinuationAction'"
    }
    if ($actualFinalRecoveryVerdict -ne $expected.expected_final_recovery_verdict) {
        $mismatches += "expected final recovery verdict '$($expected.expected_final_recovery_verdict)' but got '$actualFinalRecoveryVerdict'"
    }
    if ($salvageRan -ne [bool]$expected.expected_salvage_ran) {
        $mismatches += "expected salvage_ran=$($expected.expected_salvage_ran) but got $salvageRan"
    }
    if ($rerunSelected -ne [bool]$expected.expected_rerun_selected) {
        $mismatches += "expected rerun_selected=$($expected.expected_rerun_selected) but got $rerunSelected"
    }
    if ($manualReviewSelected -ne [bool]$expected.expected_manual_review_selected) {
        $mismatches += "expected manual_review_selected=$($expected.expected_manual_review_selected) but got $manualReviewSelected"
    }
    if ($structurallyCompleteAfterContinuation -ne [bool]$expected.expected_structurally_complete_after_continuation) {
        $mismatches += "expected structurally_complete_after_continuation=$($expected.expected_structurally_complete_after_continuation) but got $structurallyCompleteAfterContinuation"
    }
    if (-not ($rehearsalMode -and $validationOnly)) {
        $mismatches += "rehearsal labeling was not preserved"
    }
    if (-not $excludedFromPromotion) {
        $mismatches += "promotion exclusion was not preserved"
    }
    if ($countTowardGrounded) {
        $mismatches += "the branch counted toward grounded certification unexpectedly"
    }
    if ($responsiveGateVerdict -ne "closed") {
        $mismatches += "responsive gate verdict should stay 'closed' but was '$responsiveGateVerdict'"
    }
    if (-not $registryIsBranchLocal) {
        $mismatches += "registry path '$registryPath' was not branch-local"
    }

    $branchPass = @($mismatches).Count -eq 0
    $branchExplanation = if ($branchPass) {
        "Expected recovery and continuation behavior matched, and the rehearsal stayed isolated from live promotion evidence."
    }
    else {
        (@($mismatches) -join "; ")
    }

    $branchRow = [ordered]@{
        branch_name = $requiredMode
        branch_type = $expected.expected_branch_type
        staged_by = "inject_pair_session_failure.ps1:$requiredMode"
        staging_explanation = [string](Get-ObjectPropertyValue -Object $failureInjectionReport -Name "explanation" -Default "")
        mutation_mode = [string](Get-ObjectPropertyValue -Object $failureInjectionReport -Name "mutation_mode" -Default "")
        expected_recovery_verdict = $expected.expected_recovery_verdict
        actual_recovery_verdict = $actualRecoveryVerdict
        expected_continuation_action = $expected.expected_continuation_action
        actual_continuation_action = $actualContinuationAction
        expected_final_recovery_verdict = $expected.expected_final_recovery_verdict
        actual_final_recovery_verdict = $actualFinalRecoveryVerdict
        salvage_ran = $salvageRan
        rerun_selected = $rerunSelected
        manual_review_selected = $manualReviewSelected
        structurally_complete_after_continuation = $structurallyCompleteAfterContinuation
        remained_excluded_from_promotion = $excludedFromPromotion
        rehearsal_mode = $rehearsalMode
        validation_only = $validationOnly
        registration_disposition = [string](Get-ObjectPropertyValue -Object $promotionSafety -Name "registration_disposition" -Default "")
        count_toward_grounded_certification_now = $countTowardGrounded
        registry_path = $registryPath
        registry_is_branch_local = $registryIsBranchLocal
        responsive_gate_verdict = $responsiveGateVerdict
        responsive_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $promotionSafety -Name "responsive_gate_next_live_action" -Default "")
        result_pair_root = $resultPairRoot
        branch_pass = $branchPass
        explanation = $branchExplanation
        artifacts = [ordered]@{
            continuation_rehearsal_report_json = $branchReportJsonPath
            failure_injection_report_json = $failureInjectionReportJsonPath
            mission_continuation_decision_json = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $branchReport -Name "artifacts" -Default $null) -Name "continuation_decision_json" -Default "")
            session_salvage_report_json = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $branchReport -Name "artifacts" -Default $null) -Name "session_salvage_report_json" -Default "")
            final_session_docket_json = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $branchReport -Name "artifacts" -Default $null) -Name "final_session_docket_json" -Default "")
            mission_attainment_json = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $branchReport -Name "artifacts" -Default $null) -Name "mission_attainment_json" -Default "")
        }
    }

    $branchMatrixRows += [pscustomobject]$branchRow
    if ($branchPass) {
        $fullyValidatedBranches += $requiredMode
    }
    else {
        $branchesWithGaps += [pscustomobject]@{
            branch_name = $requiredMode
            reason = $branchExplanation
        }
    }
}

$requestedRequiredModes = @($requiredFailureModes | Where-Object { $_ -in @($FailureModes) })
$allRequiredBranchesValidated = @($fullyValidatedBranches | Where-Object { $_ -in $requiredFailureModes }).Count -eq $requiredFailureModes.Count
$rehearsalEvidenceStayedExcluded = @($branchMatrixRows | Where-Object {
        $_.branch_name -in $requiredFailureModes -and
        $_.remained_excluded_from_promotion -and
        -not $_.count_toward_grounded_certification_now
    }).Count -eq $requiredFailureModes.Count
$salvagedRehearsalRegistriesStayedIsolated = @($branchMatrixRows | Where-Object {
        $_.branch_name -in $requiredFailureModes -and
        $_.branch_type -eq "salvage" -and
        $_.registry_is_branch_local
    }).Count -eq @($branchMatrixRows | Where-Object { $_.branch_name -in $requiredFailureModes -and $_.branch_type -eq "salvage" }).Count
$responsiveGateStayedClosed = @($branchMatrixRows | Where-Object {
        $_.branch_name -in $requiredFailureModes -and $_.responsive_gate_verdict -eq "closed"
    }).Count -eq $requiredFailureModes.Count
$continuationControllerBehavedConservatively = @($branchMatrixRows | Where-Object {
        $_.branch_name -in $requiredFailureModes -and $_.branch_pass
    }).Count -eq $requiredFailureModes.Count
$previouslyUnclosedBranches = [ordered]@{
    after_sufficiency_before_closeout = [ordered]@{
        covered = [bool](@($branchMatrixRows | Where-Object { $_.branch_name -eq "after-sufficiency-before-closeout" }).Count -gt 0)
        pass = [bool](@($branchMatrixRows | Where-Object { $_.branch_name -eq "after-sufficiency-before-closeout" -and $_.branch_pass }).Count -gt 0)
    }
    partial_artifacts_recoverable = [ordered]@{
        covered = [bool](@($branchMatrixRows | Where-Object { $_.branch_name -eq "partial-artifacts-recoverable" }).Count -gt 0)
        pass = [bool](@($branchMatrixRows | Where-Object { $_.branch_name -eq "partial-artifacts-recoverable" -and $_.branch_pass }).Count -gt 0)
    }
}

$remainingGapShouldStop = -not ($allRequiredBranchesValidated -and $rehearsalEvidenceStayedExcluded -and $salvagedRehearsalRegistriesStayedIsolated -and $responsiveGateStayedClosed -and $continuationControllerBehavedConservatively)
$overallVerdict = if (-not $remainingGapShouldStop) {
    "ready-for-first-grounded-conservative-session"
}
elseif (@($branchesWithGaps).Count -gt 0) {
    "blocked"
}
else {
    "ready-with-known-gaps"
}

$certificateExplanation = if ($overallVerdict -eq "ready-for-first-grounded-conservative-session") {
    "The full recovery matrix matched the expected no-action, salvage, rerun, and manual-review branches, and rehearsal evidence stayed isolated from live promotion state across the suite."
}
elseif ($overallVerdict -eq "blocked") {
    "One or more required recovery branches failed validation or rehearsal-safety separation. Fix the branch gaps before relying on the first real human-rich conservative session under failure conditions."
}
else {
    "The major recovery workflow is usable, but known validation gaps remain. Review the branch gaps before depending on the first real human-rich conservative session."
}

$matrixJsonPath = Join-Path $matrixRoot "recovery_branch_matrix.json"
$matrixMarkdownPath = Join-Path $matrixRoot "recovery_branch_matrix.md"
$matrix = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    matrix_root = $matrixRoot
    continuation_rehearsal_suite_root = $continuationRehearsalSuiteRoot
    requested_failure_modes = @($FailureModes)
    required_failure_modes = @($requiredFailureModes)
    base_pair_root = $basePairRootUsed
    mission_path_used = $missionPathUsed
    overall_pass = $allRequiredBranchesValidated -and $rehearsalEvidenceStayedExcluded -and $salvagedRehearsalRegistriesStayedIsolated -and $responsiveGateStayedClosed -and $continuationControllerBehavedConservatively
    branches = @($branchMatrixRows)
}
Write-JsonFile -Path $matrixJsonPath -Value $matrix
$matrixForMarkdown = Read-JsonFile -Path $matrixJsonPath
Write-TextFile -Path $matrixMarkdownPath -Value (Get-RecoveryMatrixMarkdown -Matrix $matrixForMarkdown)

$certificateJsonPath = Join-Path $matrixRoot "recovery_readiness_certificate.json"
$certificateMarkdownPath = Join-Path $matrixRoot "recovery_readiness_certificate.md"
$certificate = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    matrix_root = $matrixRoot
    continuation_rehearsal_suite_root = $continuationRehearsalSuiteRoot
    recovery_branch_matrix_json = $matrixJsonPath
    recovery_branch_matrix_markdown = $matrixMarkdownPath
    overall_verdict = $overallVerdict
    fully_validated_branches = @($fullyValidatedBranches)
    branches_with_gaps = @($branchesWithGaps)
    rehearsal_evidence_stayed_excluded_from_promotion = $rehearsalEvidenceStayedExcluded
    salvaged_rehearsal_registries_stayed_isolated = $salvagedRehearsalRegistriesStayedIsolated
    responsive_gate_stayed_closed_on_rehearsal_only_evidence = $responsiveGateStayedClosed
    continuation_controller_behaved_conservatively = $continuationControllerBehavedConservatively
    remaining_gap_should_stop_next_real_conservative_run = $remainingGapShouldStop
    previously_unclosed_branches_now_covered = $previouslyUnclosedBranches
    explanation = $certificateExplanation
}
Write-JsonFile -Path $certificateJsonPath -Value $certificate
$certificateForMarkdown = Read-JsonFile -Path $certificateJsonPath
Write-TextFile -Path $certificateMarkdownPath -Value (Get-RecoveryReadinessMarkdown -Certificate $certificateForMarkdown)

Write-Host "Recovery branch matrix:"
Write-Host "  Matrix root: $matrixRoot"
Write-Host "  Continuation rehearsal suite root: $continuationRehearsalSuiteRoot"
Write-Host "  Recovery branch matrix JSON: $matrixJsonPath"
Write-Host "  Recovery branch matrix Markdown: $matrixMarkdownPath"
Write-Host "  Recovery readiness certificate JSON: $certificateJsonPath"
Write-Host "  Recovery readiness certificate Markdown: $certificateMarkdownPath"
Write-Host "  Overall readiness verdict: $overallVerdict"
Write-Host "  Fully validated branches: $(@($fullyValidatedBranches) -join ', ')"

[pscustomobject]@{
    MatrixRoot = $matrixRoot
    ContinuationRehearsalSuiteRoot = $continuationRehearsalSuiteRoot
    RecoveryBranchMatrixJsonPath = $matrixJsonPath
    RecoveryBranchMatrixMarkdownPath = $matrixMarkdownPath
    RecoveryReadinessCertificateJsonPath = $certificateJsonPath
    RecoveryReadinessCertificateMarkdownPath = $certificateMarkdownPath
    OverallReadinessVerdict = $overallVerdict
}
