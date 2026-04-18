[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RegistryPath = "",
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$RegistrySummaryPath = "",
    [string]$ProfileRecommendationPath = "",
    [string]$ResponsiveTrialGatePath = "",
    [string]$GateConfigPath = "",
    [string]$NextLivePlanPath = "",
    [string]$LatestOutcomeDossierPath = "",
    [string]$PairsRoot = ""
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

function Get-UniqueStringList {
    param([object[]]$Items)

    return @(
        $Items |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Format-OneDecimalInvariant {
    param([double]$Value)

    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.0}", $Value)
}

function Invoke-HelperScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    return & $ScriptPath @Arguments
}

function Get-LatestOutcomeDossierSelection {
    param(
        [string]$ExplicitPath,
        [string]$ResolvedPairsRoot
    )

    $selection = [ordered]@{
        selected_kind = "none"
        selected_path = ""
        selected = $null
        latest_overall_path = ""
        latest_overall = $null
        latest_live_path = ""
        latest_live = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolvedExplicitPath = Get-AbsolutePath -Path $ExplicitPath -BasePath (Get-RepoRoot)
        if (-not (Test-Path -LiteralPath $resolvedExplicitPath)) {
            throw "LatestOutcomeDossierPath was not found: $resolvedExplicitPath"
        }

        $explicitDossier = Read-JsonFile -Path $resolvedExplicitPath
        if ($null -eq $explicitDossier) {
            throw "LatestOutcomeDossierPath could not be parsed: $resolvedExplicitPath"
        }

        $selection.selected_kind = "explicit"
        $selection.selected_path = $resolvedExplicitPath
        $selection.selected = $explicitDossier
        $selection.latest_overall_path = $resolvedExplicitPath
        $selection.latest_overall = $explicitDossier

        if ([string](Get-ObjectPropertyValue -Object $explicitDossier -Name "evidence_origin" -Default "") -eq "live") {
            $selection.latest_live_path = $resolvedExplicitPath
            $selection.latest_live = $explicitDossier
        }

        return [pscustomobject]$selection
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedPairsRoot) -or -not (Test-Path -LiteralPath $ResolvedPairsRoot)) {
        return [pscustomobject]$selection
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $ResolvedPairsRoot -Filter "session_outcome_dossier.json" -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )

    foreach ($candidate in $candidates) {
        $payload = Read-JsonFile -Path $candidate.FullName
        if ($null -eq $payload) {
            continue
        }

        if (-not $selection.latest_overall_path) {
            $selection.latest_overall_path = $candidate.FullName
            $selection.latest_overall = $payload
        }

        if (
            -not $selection.latest_live_path -and
            [string](Get-ObjectPropertyValue -Object $payload -Name "evidence_origin" -Default "") -eq "live"
        ) {
            $selection.latest_live_path = $candidate.FullName
            $selection.latest_live = $payload
        }

        if ($selection.latest_overall_path -and $selection.latest_live_path) {
            break
        }
    }

    if ($selection.latest_live_path) {
        $selection.selected_kind = "latest-live"
        $selection.selected_path = $selection.latest_live_path
        $selection.selected = $selection.latest_live
    }
    elseif ($selection.latest_overall_path) {
        $selection.selected_kind = "latest-overall"
        $selection.selected_path = $selection.latest_overall_path
        $selection.selected = $selection.latest_overall
    }

    return [pscustomobject]$selection
}

function Get-ObjectiveCompletionRequirements {
    param([string]$Objective)

    switch ($Objective) {
        "collect-first-grounded-conservative-session" {
            return @("The session must become the first certified grounded conservative entry in the real live ledger.")
        }
        "collect-more-grounded-conservative-sessions" {
            return @("The session must add another certified grounded conservative entry to the real live ledger.")
        }
        "collect-grounded-conservative-too-quiet-evidence" {
            return @(
                "The session must count as certified grounded promotion evidence.",
                "The treatment behavior must still land in a grounded conservative too-quiet outcome if the goal is to close the responsive-opening too-quiet gap."
            )
        }
        "responsive-trial-ready" {
            return @(
                "The responsive trial must stay bounded under grounded live evidence.",
                "The treatment behavior must not create grounded responsive too-reactive blocker evidence."
            )
        }
        default {
            return @()
        }
    }
}

function Get-FullyClosableGapComponents {
    param([object]$Plan)

    $objective = [string](Get-ObjectPropertyValue -Object $Plan -Name "recommended_next_session_objective" -Default "")
    $gap = Get-ObjectPropertyValue -Object $Plan -Name "evidence_gap" -Default $null
    if ($null -eq $gap) {
        return @()
    }

    $components = @()
    $groundedSessionsMissing = [int](Get-ObjectPropertyValue -Object $gap -Name "grounded_sessions_missing" -Default 0)
    $groundedTooQuietMissing = [int](Get-ObjectPropertyValue -Object $gap -Name "grounded_too_quiet_missing" -Default 0)
    $groundedTooQuietDistinctPairIdsMissing = [int](Get-ObjectPropertyValue -Object $gap -Name "grounded_too_quiet_distinct_pair_ids_missing" -Default 0)

    if (
        $objective -in @(
            "collect-first-grounded-conservative-session",
            "collect-more-grounded-conservative-sessions",
            "collect-grounded-conservative-too-quiet-evidence"
        ) -and
        $groundedSessionsMissing -eq 1
    ) {
        $components += "grounded-conservative-sessions"
    }

    if ($objective -eq "collect-grounded-conservative-too-quiet-evidence" -and $groundedTooQuietMissing -eq 1) {
        $components += "grounded-conservative-too-quiet-sessions"
    }

    if ($objective -eq "collect-grounded-conservative-too-quiet-evidence" -and $groundedTooQuietDistinctPairIdsMissing -eq 1) {
        $components += "grounded-conservative-too-quiet-distinct-pair-ids"
    }

    return @($components | Select-Object -Unique)
}

function Get-NextLiveSessionMissionMarkdown {
    param([object]$Mission)

    $deficits = @($Mission.exact_evidence_deficits_still_missing)
    $failureReasons = @($Mission.this_session_still_does_not_count_if)
    $objectiveRequirements = @((Get-ObjectPropertyValue -Object $Mission -Name "objective_completion_requirements" -Default @()))
    $closableComponents = @((Get-ObjectPropertyValue -Object $Mission -Name "fully_closable_gap_components" -Default @()))
    $sourceArtifacts = Get-ObjectPropertyValue -Object $Mission -Name "artifacts" -Default $null
    $latestOutcome = Get-ObjectPropertyValue -Object $Mission -Name "latest_outcome_context" -Default $null

    $lines = @(
        "# Next Live Session Mission",
        "",
        "- Current responsive gate verdict: $($Mission.current_responsive_gate_verdict)",
        "- Current responsive gate next live action: $($Mission.current_responsive_gate_next_live_action)",
        "- Current next-live objective: $($Mission.current_next_live_objective)",
        "- Recommended live treatment profile: $($Mission.recommended_live_treatment_profile)",
        "- Explanation: $($Mission.explanation)",
        "",
        "## Lane Configuration",
        "",
        "- Map: $($Mission.live_session_run_shape.map)",
        "- Bot count: $($Mission.live_session_run_shape.bot_count)",
        "- Bot skill: $($Mission.live_session_run_shape.bot_skill)",
        "- Control lane: port $($Mission.control_lane_configuration.port), label $($Mission.control_lane_configuration.lane_label), no-AI baseline, `jk_ai_balance_enabled 0`, no sidecar",
        "- Treatment lane: port $($Mission.treatment_lane_configuration.port), label $($Mission.treatment_lane_configuration.lane_label), profile $($Mission.treatment_lane_configuration.treatment_profile), sidecar enabled",
        "",
        "## Exact Evidence Deficits Still Missing",
        ""
    )

    if (@($deficits).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($deficit in $deficits) {
            $lines += "- $deficit"
        }
    }

    $lines += @(
        "",
        "## Exact Target Thresholds",
        "",
        "- Target minimum control human snapshots: $($Mission.target_minimum_control_human_snapshots)",
        "- Target minimum control human presence seconds: $($Mission.target_minimum_control_human_presence_seconds)",
        "- Target minimum treatment human snapshots: $($Mission.target_minimum_treatment_human_snapshots)",
        "- Target minimum treatment human presence seconds: $($Mission.target_minimum_treatment_human_presence_seconds)",
        "- Target minimum treatment patch-while-human-present events: $($Mission.target_minimum_treatment_patch_while_human_present_events)",
        "- Target minimum post-patch observation window seconds: $($Mission.target_minimum_post_patch_observation_window_seconds)",
        "- This next session can reduce the promotion gap: $($Mission.can_reduce_promotion_gap)",
        "- This next session can fully close any part of the gap: $($Mission.can_fully_close_any_part_of_gap)",
        "- Fully closable gap components: $(if (@($closableComponents).Count -gt 0) { $closableComponents -join ', ' } else { 'none' })",
        "- This next session could open the responsive gate if successful: $($Mission.could_open_responsive_gate_if_successful)",
        "- Another conservative session is still expected afterward even if this one succeeds: $($Mission.another_conservative_session_expected_after_success)",
        "",
        "## Exact Stop Condition",
        "",
        "- Stop only when the live monitor reaches `sufficient-for-tuning-usable-review` or `sufficient-for-scorecard`.",
        "- Do not stop on `waiting-for-control-human-signal`, `waiting-for-treatment-human-signal`, `waiting-for-treatment-patch-while-humans-present`, `waiting-for-post-patch-observation-window`, or `insufficient-data-timeout`.",
        "- The stop is only honest once both lanes meet the human-signal thresholds, treatment has patched while humans are present, and the post-patch observation window meets the target.",
        "- Stop-condition explanation: $($Mission.exact_stop_condition.explanation)",
        "",
        "## Grounded-Session Success Criteria",
        "",
        "- success_requires_grounded_certification = $($Mission.grounded_session_success_criteria.success_requires_grounded_certification)",
        "- success_requires_counts_toward_promotion = $($Mission.grounded_session_success_criteria.success_requires_counts_toward_promotion)",
        "- success_requires_treatment_patch_while_humans_present = $($Mission.grounded_session_success_criteria.success_requires_treatment_patch_while_humans_present)",
        "- success_requires_post_patch_observation_window = $($Mission.grounded_session_success_criteria.success_requires_post_patch_observation_window)",
        "- success_requires_non_rehearsal_non_synthetic = $($Mission.grounded_session_success_criteria.success_requires_non_rehearsal_non_synthetic)"
    )

    if (@($objectiveRequirements).Count -gt 0) {
        $lines += @(
            "",
            "## Objective Completion Requirements",
            ""
        )
        foreach ($requirement in $objectiveRequirements) {
            $lines += "- $requirement"
        }
    }

    $lines += @(
        "",
        "## This Session Still Does NOT Count If ...",
        ""
    )

    foreach ($reason in $failureReasons) {
        $lines += "- $reason"
    }

    $lines += @(
        "",
        "## Latest Outcome Context",
        ""
    )

    if ($null -eq $latestOutcome -or -not [bool](Get-ObjectPropertyValue -Object $latestOutcome -Name "available" -Default $false)) {
        $lines += "- No prior outcome dossier was available."
    }
    else {
        $lines += "- Selected outcome dossier source: $($latestOutcome.selection_kind)"
        $lines += "- Outcome dossier JSON: $($latestOutcome.path)"
        $lines += "- Evidence origin: $($latestOutcome.evidence_origin)"
        $lines += "- Counts toward promotion: $($latestOutcome.counts_toward_promotion)"
        $lines += "- Impact classification: $($latestOutcome.latest_session_impact_classification)"
        $lines += "- Explanation: $($latestOutcome.explanation)"
    }

    $lines += @(
        "",
        "## Source Artifacts",
        "",
        "- Registry path: $($Mission.registry_path)",
        "- Registry summary JSON: $($sourceArtifacts.registry_summary_json)",
        "- Profile recommendation JSON: $($sourceArtifacts.profile_recommendation_json)",
        "- Responsive trial gate JSON: $($sourceArtifacts.responsive_trial_gate_json)",
        "- Next-live plan JSON: $($sourceArtifacts.next_live_plan_json)",
        "- Next-live mission JSON: $($sourceArtifacts.next_live_session_mission_json)",
        "- Next-live mission Markdown: $($sourceArtifacts.next_live_session_mission_markdown)"
    )

    if ($sourceArtifacts.latest_outcome_dossier_json) {
        $lines += "- Latest outcome dossier JSON: $($sourceArtifacts.latest_outcome_dossier_json)"
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

$resolvedRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson"
}
else {
    Get-AbsolutePath -Path $RegistryPath -BasePath $repoRoot
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Split-Path -Path $resolvedRegistryPath -Parent)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}

$resolvedPairsRoot = if ([string]::IsNullOrWhiteSpace($PairsRoot)) {
    Get-PairsRootDefault -LabRoot $resolvedLabRoot
}
else {
    Get-AbsolutePath -Path $PairsRoot -BasePath $repoRoot
}

$summaryScriptPath = Join-Path $PSScriptRoot "summarize_pair_session_registry.ps1"
$gateScriptPath = Join-Path $PSScriptRoot "evaluate_responsive_trial_gate.ps1"
$plannerScriptPath = Join-Path $PSScriptRoot "plan_next_live_session.ps1"

$summaryArgs = @{
    RegistryPath = $resolvedRegistryPath
    OutputRoot = $resolvedOutputRoot
}
$summaryResult = Invoke-HelperScript -ScriptPath $summaryScriptPath -Arguments $summaryArgs

$resolvedRegistrySummaryPath = if ([string]::IsNullOrWhiteSpace($RegistrySummaryPath)) {
    [string](Get-ObjectPropertyValue -Object $summaryResult -Name "RegistrySummaryJsonPath" -Default (Join-Path $resolvedOutputRoot "registry_summary.json"))
}
else {
    Get-AbsolutePath -Path $RegistrySummaryPath -BasePath $repoRoot
}

$resolvedProfileRecommendationPath = if ([string]::IsNullOrWhiteSpace($ProfileRecommendationPath)) {
    [string](Get-ObjectPropertyValue -Object $summaryResult -Name "ProfileRecommendationJsonPath" -Default (Join-Path $resolvedOutputRoot "profile_recommendation.json"))
}
else {
    Get-AbsolutePath -Path $ProfileRecommendationPath -BasePath $repoRoot
}

$gateArgs = @{
    RegistryPath = $resolvedRegistryPath
    OutputRoot = $resolvedOutputRoot
    RegistrySummaryPath = $resolvedRegistrySummaryPath
    ProfileRecommendationPath = $resolvedProfileRecommendationPath
}
if (-not [string]::IsNullOrWhiteSpace($GateConfigPath)) {
    $gateArgs.GateConfigPath = Get-AbsolutePath -Path $GateConfigPath -BasePath $repoRoot
}
$gateResult = Invoke-HelperScript -ScriptPath $gateScriptPath -Arguments $gateArgs

$resolvedResponsiveTrialGatePath = if ([string]::IsNullOrWhiteSpace($ResponsiveTrialGatePath)) {
    [string](Get-ObjectPropertyValue -Object $gateResult -Name "ResponsiveTrialGateJsonPath" -Default (Join-Path $resolvedOutputRoot "responsive_trial_gate.json"))
}
else {
    Get-AbsolutePath -Path $ResponsiveTrialGatePath -BasePath $repoRoot
}

$resolvedGateConfigPath = if ([string]::IsNullOrWhiteSpace($GateConfigPath)) {
    Join-Path $repoRoot "ai_director\testdata\responsive_trial_gate.json"
}
else {
    Get-AbsolutePath -Path $GateConfigPath -BasePath $repoRoot
}

$plannerArgs = @{
    RegistryPath = $resolvedRegistryPath
    OutputRoot = $resolvedOutputRoot
    RegistrySummaryPath = $resolvedRegistrySummaryPath
    ProfileRecommendationPath = $resolvedProfileRecommendationPath
    ResponsiveTrialGatePath = $resolvedResponsiveTrialGatePath
    GateConfigPath = $resolvedGateConfigPath
}
$planResult = Invoke-HelperScript -ScriptPath $plannerScriptPath -Arguments $plannerArgs

$resolvedNextLivePlanPath = if ([string]::IsNullOrWhiteSpace($NextLivePlanPath)) {
    [string](Get-ObjectPropertyValue -Object $planResult -Name "NextLivePlanJsonPath" -Default (Join-Path $resolvedOutputRoot "next_live_plan.json"))
}
else {
    Get-AbsolutePath -Path $NextLivePlanPath -BasePath $repoRoot
}

$registrySummary = Read-JsonFile -Path $resolvedRegistrySummaryPath
$profileRecommendation = Read-JsonFile -Path $resolvedProfileRecommendationPath
$gate = Read-JsonFile -Path $resolvedResponsiveTrialGatePath
$plan = Read-JsonFile -Path $resolvedNextLivePlanPath
$gateConfig = Read-JsonFile -Path $resolvedGateConfigPath

if ($null -eq $registrySummary) {
    throw "Registry summary was not found: $resolvedRegistrySummaryPath"
}
if ($null -eq $profileRecommendation) {
    throw "Profile recommendation was not found: $resolvedProfileRecommendationPath"
}
if ($null -eq $gate) {
    throw "Responsive trial gate output was not found: $resolvedResponsiveTrialGatePath"
}
if ($null -eq $plan) {
    throw "Next-live plan output was not found: $resolvedNextLivePlanPath"
}
if ($null -eq $gateConfig) {
    throw "Responsive trial gate config was not found: $resolvedGateConfigPath"
}

$sessionTarget = Get-ObjectPropertyValue -Object $plan -Name "session_target" -Default $null
if ($null -eq $sessionTarget) {
    throw "The next-live plan did not contain a session_target block."
}

$latestOutcomeSelection = Get-LatestOutcomeDossierSelection -ExplicitPath $LatestOutcomeDossierPath -ResolvedPairsRoot $resolvedPairsRoot
$selectedOutcome = Get-ObjectPropertyValue -Object $latestOutcomeSelection -Name "selected" -Default $null
$selectedOutcomePath = [string](Get-ObjectPropertyValue -Object $latestOutcomeSelection -Name "selected_path" -Default "")
$selectedOutcomeKind = [string](Get-ObjectPropertyValue -Object $latestOutcomeSelection -Name "selected_kind" -Default "none")

$combinedDeficits = Get-UniqueStringList -Items (
    @((Get-ObjectPropertyValue -Object $gate -Name "missing_evidence" -Default @())) +
    @((Get-ObjectPropertyValue -Object $plan -Name "deficits_remaining_descriptions" -Default @()))
)

$controlLane = Get-ObjectPropertyValue -Object $sessionTarget -Name "control_lane" -Default $null
$treatmentLane = Get-ObjectPropertyValue -Object $sessionTarget -Name "treatment_lane" -Default $null
$fullyClosableGapComponents = Get-FullyClosableGapComponents -Plan $plan

$missionJsonPath = Join-Path $resolvedOutputRoot "next_live_session_mission.json"
$missionMarkdownPath = Join-Path $resolvedOutputRoot "next_live_session_mission.md"

$mission = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    registry_path = $resolvedRegistryPath
    output_root = $resolvedOutputRoot
    current_responsive_gate_verdict = [string](Get-ObjectPropertyValue -Object $gate -Name "gate_verdict" -Default "")
    current_responsive_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $gate -Name "next_live_action" -Default "")
    current_next_live_objective = [string](Get-ObjectPropertyValue -Object $plan -Name "recommended_next_session_objective" -Default "")
    current_default_live_treatment_profile = [string](Get-ObjectPropertyValue -Object $plan -Name "current_default_live_treatment_profile" -Default "")
    recommended_live_treatment_profile = [string](Get-ObjectPropertyValue -Object $plan -Name "recommended_next_live_profile" -Default "")
    live_session_run_shape = [ordered]@{
        map = [string](Get-ObjectPropertyValue -Object $sessionTarget -Name "map" -Default "crossfire")
        bot_count = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "bot_count" -Default 4)
        bot_skill = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "bot_skill" -Default 3)
        wait_for_human_join = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $gateConfig -Name "trial_defaults" -Default $null) -Name "wait_for_human_join" -Default $true)
        human_join_grace_seconds = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $gateConfig -Name "trial_defaults" -Default $null) -Name "human_join_grace_seconds" -Default 120)
    }
    control_lane_configuration = $controlLane
    treatment_lane_configuration = $treatmentLane
    exact_evidence_deficits_still_missing = @($combinedDeficits)
    exact_target_thresholds = [ordered]@{
        target_minimum_control_human_snapshots = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_snapshots" -Default 0)
        target_minimum_control_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_presence_seconds" -Default 0.0)
        target_minimum_treatment_human_snapshots = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_snapshots" -Default 0)
        target_minimum_treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_presence_seconds" -Default 0.0)
        target_minimum_treatment_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_patch_while_humans_present_events" -Default 0)
        target_minimum_post_patch_observation_window_seconds = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_post_patch_observation_seconds" -Default 0.0)
    }
    target_minimum_control_human_snapshots = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_snapshots" -Default 0)
    target_minimum_control_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_presence_seconds" -Default 0.0)
    target_minimum_treatment_human_snapshots = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_snapshots" -Default 0)
    target_minimum_treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_human_presence_seconds" -Default 0.0)
    target_minimum_treatment_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_patch_while_humans_present_events" -Default 0)
    target_minimum_post_patch_observation_window_seconds = [double](Get-ObjectPropertyValue -Object $sessionTarget -Name "target_min_post_patch_observation_seconds" -Default 0.0)
    can_reduce_promotion_gap = [bool](Get-ObjectPropertyValue -Object $sessionTarget -Name "can_reduce_promotion_gap" -Default $false)
    can_fully_close_any_part_of_gap = @($fullyClosableGapComponents).Count -gt 0
    fully_closable_gap_components = @($fullyClosableGapComponents)
    could_open_responsive_gate_if_successful = [bool](Get-ObjectPropertyValue -Object $sessionTarget -Name "could_theoretically_open_responsive_gate_if_successful" -Default $false)
    another_conservative_session_expected_after_success = Get-ObjectPropertyValue -Object $sessionTarget -Name "another_conservative_session_required_after_this" -Default $null
    exact_stop_condition = [ordered]@{
        stop_only_when_live_monitor_verdict_in = @(
            "sufficient-for-tuning-usable-review",
            "sufficient-for-scorecard"
        )
        do_not_stop_if_live_monitor_verdict_in = @(
            "waiting-for-control-human-signal",
            "waiting-for-treatment-human-signal",
            "waiting-for-treatment-patch-while-humans-present",
            "waiting-for-post-patch-observation-window",
            "insufficient-data-timeout"
        )
        explanation = "Stop only after the existing live monitor says the pair is sufficient for tuning-usable review or already sufficient for scorecard. The waiting states and insufficient-data timeout do not satisfy grounded evidence."
    }
    grounded_session_success_criteria = [ordered]@{
        success_requires_grounded_certification = $true
        success_requires_counts_toward_promotion = $true
        success_requires_treatment_patch_while_humans_present = $true
        success_requires_post_patch_observation_window = $true
        success_requires_non_rehearsal_non_synthetic = $true
        success_requires_control_human_signal_thresholds = $true
        success_requires_treatment_human_signal_thresholds = $true
        success_requires_live_monitor_sufficient_verdict = $true
    }
    objective_completion_requirements = @(Get-ObjectiveCompletionRequirements -Objective ([string](Get-ObjectPropertyValue -Object $plan -Name "recommended_next_session_objective" -Default "")))
    exact_failure_conditions_that_would_leave_session_non_grounded = @(
        "rehearsal",
        "synthetic",
        "no-human",
        "insufficient-data",
        "weak-signal",
        "no patch while humans are present",
        "no meaningful post-patch observation window",
        "minimum human-signal thresholds are not met in both lanes",
        "pair stays below tuning-usable"
    )
    this_session_still_does_not_count_if = @(
        "rehearsal: rehearsal-mode and workflow-validation-only evidence never counts toward promotion.",
        "synthetic: synthetic fixture evidence never counts toward promotion.",
        "no-human: either lane misses the minimum human snapshots or human-presence threshold.",
        "insufficient-data: the pair remains comparison-insufficient-data or a lane remains insufficient-data.",
        "weak-signal: the pair never clears tuning-usable and still lands below usable signal.",
        "no patch while humans are present: treatment never produces the required human-present patch events.",
        "no meaningful post-patch observation window: treatment patches, but the grounded observation window stays too short.",
        "minimum human-signal thresholds are not met in both lanes: the session never clears the grounded minimum in control and treatment.",
        "pair stays below tuning-usable: plumbing-valid-only or otherwise below-tuning-usable evidence is excluded from promotion."
    )
    latest_outcome_context = if ($null -eq $selectedOutcome) {
        [ordered]@{
            available = $false
        }
    }
    else {
        [ordered]@{
            available = $true
            selection_kind = $selectedOutcomeKind
            path = $selectedOutcomePath
            evidence_origin = [string](Get-ObjectPropertyValue -Object $selectedOutcome -Name "evidence_origin" -Default "")
            counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $selectedOutcome -Name "counts_toward_promotion" -Default $false)
            latest_session_impact_classification = [string](Get-ObjectPropertyValue -Object $selectedOutcome -Name "latest_session_impact_classification" -Default "")
            explanation = [string](Get-ObjectPropertyValue -Object $selectedOutcome -Name "explanation" -Default "")
            recommended_next_live_action = [string](Get-ObjectPropertyValue -Object $selectedOutcome -Name "recommended_next_live_action" -Default "")
        }
    }
    explanation = [string](Get-ObjectPropertyValue -Object $plan -Name "explanation" -Default "")
    artifacts = [ordered]@{
        registry_summary_json = $resolvedRegistrySummaryPath
        profile_recommendation_json = $resolvedProfileRecommendationPath
        responsive_trial_gate_json = $resolvedResponsiveTrialGatePath
        next_live_plan_json = $resolvedNextLivePlanPath
        latest_outcome_dossier_json = $selectedOutcomePath
        next_live_session_mission_json = $missionJsonPath
        next_live_session_mission_markdown = $missionMarkdownPath
    }
}

Write-JsonFile -Path $missionJsonPath -Value $mission
$missionForMarkdown = Read-JsonFile -Path $missionJsonPath
Write-TextFile -Path $missionMarkdownPath -Value (Get-NextLiveSessionMissionMarkdown -Mission $missionForMarkdown)

Write-Host "Next live session mission:"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Mission JSON: $missionJsonPath"
Write-Host "  Mission Markdown: $missionMarkdownPath"
Write-Host "  Responsive gate verdict: $($mission.current_responsive_gate_verdict)"
Write-Host "  Recommended live treatment profile: $($mission.recommended_live_treatment_profile)"
Write-Host "  Current next-live objective: $($mission.current_next_live_objective)"
Write-Host "  Can reduce promotion gap: $($mission.can_reduce_promotion_gap)"
Write-Host "  Can fully close any part of the gap: $($mission.can_fully_close_any_part_of_gap)"

[pscustomobject]@{
    RegistryPath = $resolvedRegistryPath
    OutputRoot = $resolvedOutputRoot
    MissionJsonPath = $missionJsonPath
    MissionMarkdownPath = $missionMarkdownPath
    ResponsiveGateVerdict = [string]$mission.current_responsive_gate_verdict
    RecommendedLiveProfile = [string]$mission.recommended_live_treatment_profile
    CurrentNextLiveObjective = [string]$mission.current_next_live_objective
    CanReducePromotionGap = [bool]$mission.can_reduce_promotion_gap
    CanFullyCloseAnyPartOfGap = [bool]$mission.can_fully_close_any_part_of_gap
    LatestOutcomeDossierPath = $selectedOutcomePath
}
