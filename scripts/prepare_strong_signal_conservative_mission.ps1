[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RegistryPath = "",
    [string]$LabRoot = "",
    [string]$EvalRoot = "",
    [string]$OutputRoot = "",
    [string]$GroundedEvidenceMatrixPath = "",
    [string]$PromotionStateReviewPath = "",
    [string]$ResponsiveTrialGatePath = "",
    [string]$NextLivePlanPath = "",
    [string]$BaseMissionPath = "",
    [string]$BaseMissionMarkdownPath = "",
    [string]$GateConfigPath = ""
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

    $json = $Value | ConvertTo-Json -Depth 32
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

function Get-RequiredArtifactPath {
    param(
        [string]$ExplicitPath,
        [string]$DefaultPath,
        [string]$Description
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $DefaultPath
    }
    else {
        Get-AbsolutePath -Path $ExplicitPath -BasePath (Get-RepoRoot)
    }

    $resolved = Resolve-ExistingPath -Path $candidate
    if (-not $resolved) {
        throw "$Description was not found: $candidate"
    }

    return $resolved
}

function Get-StrongSignalTarget {
    param(
        [double]$BaselineValue,
        [double]$MinimumAbsoluteValue,
        [double]$AdditiveLift,
        [double]$Multiplier
    )

    $scaledValue = [Math]::Ceiling($BaselineValue * $Multiplier)
    $liftedValue = [Math]::Ceiling($BaselineValue + $AdditiveLift)
    return [int][Math]::Max($MinimumAbsoluteValue, [Math]::Max($scaledValue, $liftedValue))
}

function Get-StrongSignalMissionMarkdown {
    param([object]$Mission)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Strong-Signal Conservative Mission") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Prompt ID: $($Mission.prompt_id)") | Out-Null
    $lines.Add("- Mission kind: $($Mission.mission_kind)") | Out-Null
    $lines.Add("- Current responsive gate verdict: $($Mission.current_global_state.responsive_gate_verdict)") | Out-Null
    $lines.Add("- Current next-live objective: $($Mission.current_global_state.next_live_objective)") | Out-Null
    $lines.Add("- Recommended live treatment profile: $($Mission.recommended_live_treatment_profile)") | Out-Null
    $lines.Add("- Explanation: $($Mission.explanation)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Current Evidence Mix") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Counted grounded conservative sessions: $($Mission.current_evidence_mix_summary.counted_grounded_conservative_sessions)") | Out-Null
    $lines.Add("- Appropriately conservative sessions: $($Mission.current_evidence_mix_summary.appropriately_conservative_sessions)") | Out-Null
    $lines.Add("- Too-quiet sessions: $($Mission.current_evidence_mix_summary.too_quiet_sessions)") | Out-Null
    $lines.Add("- Too-reactive sessions: $($Mission.current_evidence_mix_summary.too_reactive_sessions)") | Out-Null
    $lines.Add("- Strong-signal sessions: $($Mission.current_evidence_mix_summary.strong_signal_sessions)") | Out-Null
    $lines.Add("- Manual-review reason: $($Mission.current_global_state.manual_review_reason)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Why This Must Be Stronger-Signal") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add($Mission.why_stronger_signal_not_generic_grounded_session) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Lane Configuration") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Map: $($Mission.live_session_run_shape.map)") | Out-Null
    $lines.Add("- Bot count: $($Mission.live_session_run_shape.bot_count)") | Out-Null
    $lines.Add("- Bot skill: $($Mission.live_session_run_shape.bot_skill)") | Out-Null
    $lines.Add("- Recommended duration seconds: $($Mission.launcher_defaults.duration_seconds)") | Out-Null
    $lines.Add(('- Control lane: port {0}, label {1}, no-AI baseline, `jk_ai_balance_enabled 0`, no sidecar' -f $Mission.control_lane_configuration.port, $Mission.control_lane_configuration.lane_label)) | Out-Null
    $lines.Add(('- Treatment lane: port {0}, label {1}, profile {2}, sidecar enabled' -f $Mission.treatment_lane_configuration.port, $Mission.treatment_lane_configuration.lane_label, $Mission.treatment_lane_configuration.treatment_profile)) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Strong-Signal Targets") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control minimum human snapshots: $($Mission.target_minimum_control_human_snapshots)") | Out-Null
    $lines.Add("- Control minimum human presence seconds: $($Mission.target_minimum_control_human_presence_seconds)") | Out-Null
    $lines.Add("- Treatment minimum human snapshots: $($Mission.target_minimum_treatment_human_snapshots)") | Out-Null
    $lines.Add("- Treatment minimum human presence seconds: $($Mission.target_minimum_treatment_human_presence_seconds)") | Out-Null
    $lines.Add("- Treatment minimum patch-while-human-present events: $($Mission.target_minimum_treatment_patch_while_human_present_events)") | Out-Null
    $lines.Add("- Minimum post-patch observation window seconds: $($Mission.target_minimum_post_patch_observation_window_seconds)") | Out-Null
    $lines.Add("- Intended to create a strong-signal conservative outcome: $($Mission.intended_to_create_strong_signal_conservative_outcome)") | Out-Null
    $lines.Add("- Intended to discriminate appropriately conservative vs too quiet: $($Mission.intended_to_discriminate_appropriately_conservative_vs_too_quiet)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Strong-Signal Definition") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($criterion in @($Mission.strong_signal_operator_definition)) {
        $lines.Add("- $criterion") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Disambiguation Branches") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($branch in @($Mission.disambiguation_branches)) {
        $lines.Add("- If the next strong-signal conservative session lands as '$($branch.result_bucket)', then $($branch.support_statement)") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Execution Path") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Preferred mission-driven runner:") | Out-Null
    $lines.Add('```powershell') | Out-Null
    $lines.Add([string](Get-ObjectPropertyValue -Object $Mission.execution_guidance -Name "mission_runner_command" -Default "")) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add("- Client-assisted conservative runner:") | Out-Null
    $lines.Add('```powershell') | Out-Null
    $lines.Add([string](Get-ObjectPropertyValue -Object $Mission.execution_guidance -Name "client_assisted_runner_command" -Default "")) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add("- Cycle wrapper that reuses the same mission:") | Out-Null
    $lines.Add('```powershell') | Out-Null
    $lines.Add([string](Get-ObjectPropertyValue -Object $Mission.execution_guidance -Name "next_cycle_runner_command" -Default "")) | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Supporting Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Grounded evidence matrix JSON: $($Mission.supporting_artifacts.grounded_evidence_matrix_json)") | Out-Null
    $lines.Add("- Promotion state review JSON: $($Mission.supporting_artifacts.promotion_state_review_json)") | Out-Null
    $lines.Add("- Responsive trial gate JSON: $($Mission.supporting_artifacts.responsive_trial_gate_json)") | Out-Null
    $lines.Add("- Next-live plan JSON: $($Mission.supporting_artifacts.next_live_plan_json)") | Out-Null
    $lines.Add("- Base mission JSON: $($Mission.supporting_artifacts.base_mission_json)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Honest State Constraints") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Responsive is still closed: $($Mission.responsive_still_closed)") | Out-Null
    $lines.Add("- Mixed evidence already resolved: $($Mission.mixed_evidence_state_resolved)") | Out-Null
    $lines.Add("- Strong-signal evidence already exists: $($Mission.strong_signal_evidence_already_exists)") | Out-Null

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot)
}
$resolvedEvalRoot = if ([string]::IsNullOrWhiteSpace($EvalRoot)) {
    Ensure-Directory -Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $EvalRoot -BasePath $repoRoot)
}
$resolvedRegistryRoot = Ensure-Directory -Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot)
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $resolvedRegistryRoot
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
$resolvedRegistryPath = Get-RequiredArtifactPath `
    -ExplicitPath $RegistryPath `
    -DefaultPath (Join-Path $resolvedRegistryRoot "pair_sessions.ndjson") `
    -Description "Registry path"

$matrixScriptPath = Join-Path $PSScriptRoot "review_grounded_evidence_matrix.ps1"
$missionScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"

$matrixResult = if ([string]::IsNullOrWhiteSpace($GroundedEvidenceMatrixPath) -or [string]::IsNullOrWhiteSpace($PromotionStateReviewPath)) {
    & $matrixScriptPath -RegistryPath $resolvedRegistryPath -LabRoot $resolvedLabRoot -EvalRoot $resolvedEvalRoot -OutputRoot $resolvedRegistryRoot -GateConfigPath $GateConfigPath
}
else {
    $null
}

$baseMissionResult = if ([string]::IsNullOrWhiteSpace($BaseMissionPath)) {
    & $missionScriptPath -RegistryPath $resolvedRegistryPath -LabRoot $resolvedLabRoot -OutputRoot $resolvedRegistryRoot -GateConfigPath $GateConfigPath
}
else {
    $null
}

$resolvedMatrixPath = Get-RequiredArtifactPath `
    -ExplicitPath $GroundedEvidenceMatrixPath `
    -DefaultPath ([string](Get-ObjectPropertyValue -Object $matrixResult -Name "GroundedEvidenceMatrixJsonPath" -Default (Join-Path $resolvedRegistryRoot "grounded_evidence_matrix.json"))) `
    -Description "Grounded evidence matrix JSON"
$resolvedPromotionReviewPath = Get-RequiredArtifactPath `
    -ExplicitPath $PromotionStateReviewPath `
    -DefaultPath ([string](Get-ObjectPropertyValue -Object $matrixResult -Name "PromotionStateReviewJsonPath" -Default (Join-Path $resolvedRegistryRoot "promotion_state_review.json"))) `
    -Description "Promotion state review JSON"
$resolvedBaseMissionPath = Get-RequiredArtifactPath `
    -ExplicitPath $BaseMissionPath `
    -DefaultPath ([string](Get-ObjectPropertyValue -Object $baseMissionResult -Name "MissionJsonPath" -Default (Join-Path $resolvedRegistryRoot "next_live_session_mission.json"))) `
    -Description "Base next-live mission JSON"
$resolvedBaseMissionMarkdownPath = Get-RequiredArtifactPath `
    -ExplicitPath $BaseMissionMarkdownPath `
    -DefaultPath ([string](Get-ObjectPropertyValue -Object $baseMissionResult -Name "MissionMarkdownPath" -Default ([System.IO.Path]::ChangeExtension($resolvedBaseMissionPath, ".md")))) `
    -Description "Base next-live mission Markdown"

$matrix = Read-JsonFile -Path $resolvedMatrixPath
$promotionStateReview = Read-JsonFile -Path $resolvedPromotionReviewPath
$baseMission = Read-JsonFile -Path $resolvedBaseMissionPath
if ($null -eq $matrix) {
    throw "Grounded evidence matrix could not be parsed: $resolvedMatrixPath"
}
if ($null -eq $promotionStateReview) {
    throw "Promotion state review could not be parsed: $resolvedPromotionReviewPath"
}
if ($null -eq $baseMission) {
    throw "Base next-live mission could not be parsed: $resolvedBaseMissionPath"
}

$resolvedResponsiveTrialGatePath = Get-RequiredArtifactPath `
    -ExplicitPath $ResponsiveTrialGatePath `
    -DefaultPath ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $baseMission -Name "artifacts" -Default $null) -Name "responsive_trial_gate_json" -Default (Join-Path $resolvedRegistryRoot "responsive_trial_gate.json"))) `
    -Description "Responsive trial gate JSON"
$resolvedNextLivePlanPath = Get-RequiredArtifactPath `
    -ExplicitPath $NextLivePlanPath `
    -DefaultPath ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $baseMission -Name "artifacts" -Default $null) -Name "next_live_plan_json" -Default (Join-Path $resolvedRegistryRoot "next_live_plan.json"))) `
    -Description "Next-live plan JSON"

$responsiveTrialGate = Read-JsonFile -Path $resolvedResponsiveTrialGatePath
$nextLivePlan = Read-JsonFile -Path $resolvedNextLivePlanPath
if ($null -eq $responsiveTrialGate) {
    throw "Responsive trial gate could not be parsed: $resolvedResponsiveTrialGatePath"
}
if ($null -eq $nextLivePlan) {
    throw "Next-live plan could not be parsed: $resolvedNextLivePlanPath"
}

$baseControlSnapshots = [int](Get-ObjectPropertyValue -Object $baseMission -Name "target_minimum_control_human_snapshots" -Default 3)
$baseControlPresenceSeconds = [double](Get-ObjectPropertyValue -Object $baseMission -Name "target_minimum_control_human_presence_seconds" -Default 60)
$baseTreatmentSnapshots = [int](Get-ObjectPropertyValue -Object $baseMission -Name "target_minimum_treatment_human_snapshots" -Default $baseControlSnapshots)
$baseTreatmentPresenceSeconds = [double](Get-ObjectPropertyValue -Object $baseMission -Name "target_minimum_treatment_human_presence_seconds" -Default $baseControlPresenceSeconds)
$basePatchEvents = [int](Get-ObjectPropertyValue -Object $baseMission -Name "target_minimum_treatment_patch_while_human_present_events" -Default 2)
$basePostPatchSeconds = [double](Get-ObjectPropertyValue -Object $baseMission -Name "target_minimum_post_patch_observation_window_seconds" -Default 20)
$baseDurationSeconds = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $baseMission -Name "launcher_defaults" -Default $null) -Name "duration_seconds" -Default 80)

$strongControlSnapshots = Get-StrongSignalTarget -BaselineValue $baseControlSnapshots -MinimumAbsoluteValue 5 -AdditiveLift 2 -Multiplier 1.5
$strongControlPresenceSeconds = Get-StrongSignalTarget -BaselineValue $baseControlPresenceSeconds -MinimumAbsoluteValue 90 -AdditiveLift 30 -Multiplier 1.5
$strongTreatmentSnapshots = Get-StrongSignalTarget -BaselineValue $baseTreatmentSnapshots -MinimumAbsoluteValue 5 -AdditiveLift 2 -Multiplier 1.5
$strongTreatmentPresenceSeconds = Get-StrongSignalTarget -BaselineValue $baseTreatmentPresenceSeconds -MinimumAbsoluteValue 90 -AdditiveLift 30 -Multiplier 1.5
$strongPatchEvents = Get-StrongSignalTarget -BaselineValue $basePatchEvents -MinimumAbsoluteValue 3 -AdditiveLift 1 -Multiplier 1.5
$strongPostPatchSeconds = Get-StrongSignalTarget -BaselineValue $basePostPatchSeconds -MinimumAbsoluteValue 40 -AdditiveLift 20 -Multiplier 2.0
$strongDurationSeconds = Get-StrongSignalTarget -BaselineValue $baseDurationSeconds -MinimumAbsoluteValue 120 -AdditiveLift 40 -Multiplier 1.5

$controlLaneConfiguration = Get-ObjectPropertyValue -Object $baseMission -Name "control_lane_configuration" -Default $null
$treatmentLaneConfiguration = Get-ObjectPropertyValue -Object $baseMission -Name "treatment_lane_configuration" -Default $null
$liveSessionRunShape = Get-ObjectPropertyValue -Object $baseMission -Name "live_session_run_shape" -Default $null
$launcherDefaults = Get-ObjectPropertyValue -Object $baseMission -Name "launcher_defaults" -Default $null

$missionJsonPath = Join-Path $resolvedOutputRoot "strong_signal_conservative_mission.json"
$missionMarkdownPath = Join-Path $resolvedOutputRoot "strong_signal_conservative_mission.md"
$missionRunnerCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_current_live_mission.ps1 -MissionPath ""{0}"" -MissionMarkdownPath ""{1}""" -f $missionJsonPath, $missionMarkdownPath
$clientAssistedCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_human_participation_conservative_attempt.ps1 -MissionPath ""{0}"" -MissionMarkdownPath ""{1}""" -f $missionJsonPath, $missionMarkdownPath
$nextCycleCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_next_grounded_conservative_cycle.ps1 -MissionPath ""{0}"" -MissionMarkdownPath ""{1}""" -f $missionJsonPath, $missionMarkdownPath

$missionExplanationParts = @(
    "The current counted grounded conservative evidence is mixed between one appropriately-conservative outcome and one too-quiet outcome, and there are still zero counted grounded strong-signal conservative sessions.",
    "That means another minimum-bar grounded session could add evidence without actually resolving the ambiguity.",
    "This mission keeps the treatment profile conservative, keeps the no-AI control lane unchanged, and raises the human-signal, patch-window, and post-patch observation targets above the grounded minimum so the next run is more discriminating.",
    "This mission does not open responsive automatically and does not change promotion criteria. It only plans a stronger conservative session whose result should be easier to interpret."
)

$mission = [pscustomobject]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    mission_kind = "strong-signal-conservative-disambiguation"
    registry_path = $resolvedRegistryPath
    output_root = $resolvedOutputRoot
    current_global_state = [pscustomobject]@{
        responsive_gate_verdict = [string](Get-ObjectPropertyValue -Object $promotionStateReview.current_global_state -Name "responsive_gate_verdict" -Default "")
        responsive_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $promotionStateReview.current_global_state -Name "responsive_gate_next_live_action" -Default "")
        next_live_objective = [string](Get-ObjectPropertyValue -Object $promotionStateReview.current_global_state -Name "next_live_objective" -Default "")
        manual_review_reason = [string](Get-ObjectPropertyValue -Object $promotionStateReview -Name "explanation" -Default "")
    }
    current_evidence_mix_summary = [pscustomobject]@{
        counted_grounded_conservative_sessions = [int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "grounded_conservative_sessions" -Default 0)
        appropriately_conservative_sessions = [int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "appropriately_conservative_sessions" -Default 0)
        too_quiet_sessions = [int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "too_quiet_sessions" -Default 0)
        inconclusive_sessions = [int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "inconclusive_sessions" -Default 0)
        too_reactive_sessions = [int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "too_reactive_sessions" -Default 0)
        strong_signal_sessions = [int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "strong_signal_sessions" -Default 0)
        mixed_evidence_state = [bool](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "mixed_evidence_state" -Default $false)
        counted_sessions = @(
            @($matrix.sessions) | ForEach-Object {
                [pscustomobject]@{
                    pair_id = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_id" -Default "")
                    pair_root = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_root" -Default "")
                    pair_classification = [string](Get-ObjectPropertyValue -Object $_ -Name "pair_classification" -Default "")
                    treatment_behavior_assessment = [string](Get-ObjectPropertyValue -Object $_ -Name "treatment_behavior_assessment" -Default "")
                    signal_bucket = [string](Get-ObjectPropertyValue -Object $_ -Name "signal_bucket" -Default "")
                }
            }
        )
    }
    why_stronger_signal_not_generic_grounded_session = "A generic grounded session at the current minimum bar could add another tuning-usable pair while still leaving the evidence mix split between 'appropriately conservative' and 'too quiet'. The next run therefore needs richer human participation, more than the minimum human-present patch activity, and a longer post-patch observation window so the treatment result is less ambiguous than the current mixed matrix."
    recommended_live_treatment_profile = "conservative"
    live_session_run_shape = [pscustomobject]@{
        map = [string](Get-ObjectPropertyValue -Object $liveSessionRunShape -Name "map" -Default "crossfire")
        bot_count = [int](Get-ObjectPropertyValue -Object $liveSessionRunShape -Name "bot_count" -Default 4)
        bot_skill = [int](Get-ObjectPropertyValue -Object $liveSessionRunShape -Name "bot_skill" -Default 3)
        wait_for_human_join = [bool](Get-ObjectPropertyValue -Object $liveSessionRunShape -Name "wait_for_human_join" -Default $true)
        human_join_grace_seconds = [int](Get-ObjectPropertyValue -Object $liveSessionRunShape -Name "human_join_grace_seconds" -Default 120)
    }
    launcher_defaults = [pscustomobject]@{
        pair_output_root = [string](Get-ObjectPropertyValue -Object $launcherDefaults -Name "pair_output_root" -Default (Get-PairsRootDefault -LabRoot $resolvedLabRoot))
        eval_root = [string](Get-ObjectPropertyValue -Object $launcherDefaults -Name "eval_root" -Default $resolvedEvalRoot)
        configuration = [string](Get-ObjectPropertyValue -Object $launcherDefaults -Name "configuration" -Default "Release")
        platform = [string](Get-ObjectPropertyValue -Object $launcherDefaults -Name "platform" -Default "Win32")
        duration_seconds = $strongDurationSeconds
        skip_steamcmd_update = [bool](Get-ObjectPropertyValue -Object $launcherDefaults -Name "skip_steamcmd_update" -Default $false)
        skip_metamod_download = [bool](Get-ObjectPropertyValue -Object $launcherDefaults -Name "skip_metamod_download" -Default $false)
    }
    control_lane_configuration = $controlLaneConfiguration
    treatment_lane_configuration = [pscustomobject]@{
        mode = [string](Get-ObjectPropertyValue -Object $treatmentLaneConfiguration -Name "mode" -Default "AI")
        lane_label = [string](Get-ObjectPropertyValue -Object $treatmentLaneConfiguration -Name "lane_label" -Default "treatment-conservative")
        port = [int](Get-ObjectPropertyValue -Object $treatmentLaneConfiguration -Name "port" -Default 27017)
        treatment_profile = "conservative"
        sidecar = [string](Get-ObjectPropertyValue -Object $treatmentLaneConfiguration -Name "sidecar" -Default "enabled")
    }
    baseline_grounded_minimums = [pscustomobject]@{
        control_human_snapshots = $baseControlSnapshots
        control_human_presence_seconds = $baseControlPresenceSeconds
        treatment_human_snapshots = $baseTreatmentSnapshots
        treatment_human_presence_seconds = $baseTreatmentPresenceSeconds
        treatment_patch_while_human_present_events = $basePatchEvents
        post_patch_observation_window_seconds = $basePostPatchSeconds
        duration_seconds = $baseDurationSeconds
    }
    strong_signal_targets = [pscustomobject]@{
        control_human_snapshots = $strongControlSnapshots
        control_human_presence_seconds = $strongControlPresenceSeconds
        treatment_human_snapshots = $strongTreatmentSnapshots
        treatment_human_presence_seconds = $strongTreatmentPresenceSeconds
        treatment_patch_while_human_present_events = $strongPatchEvents
        post_patch_observation_window_seconds = $strongPostPatchSeconds
        duration_seconds = $strongDurationSeconds
    }
    target_minimum_control_human_snapshots = $strongControlSnapshots
    target_minimum_control_human_presence_seconds = $strongControlPresenceSeconds
    target_minimum_treatment_human_snapshots = $strongTreatmentSnapshots
    target_minimum_treatment_human_presence_seconds = $strongTreatmentPresenceSeconds
    target_minimum_treatment_patch_while_human_present_events = $strongPatchEvents
    target_minimum_post_patch_observation_window_seconds = $strongPostPatchSeconds
    intended_to_create_strong_signal_conservative_outcome = $true
    intended_to_discriminate_appropriately_conservative_vs_too_quiet = $true
    strong_signal_operator_definition = @(
        "Keep human presence well above the grounded minimum in both lanes instead of stopping at the first usable threshold.",
        "Capture more than the bare minimum human-present treatment patch evidence so the treatment side is not judged from a single marginal patch window.",
        "Keep the treatment lane occupied long enough after the first human-present patch to collect a longer post-patch observation window than the grounded minimum.",
        "Aim for a result that is easier to bucket as 'appropriately conservative' or 'too quiet' without relying on wrapper narrative interpretation."
    )
    disambiguation_branches = @(
        [pscustomobject]@{
            result_bucket = "strong-signal appropriately conservative"
            support_statement = "the keep-conservative case becomes much stronger because richer grounded evidence repeated the bounded conservative outcome."
        },
        [pscustomobject]@{
            result_bucket = "strong-signal too quiet"
            support_statement = "the case for future responsive consideration becomes much stronger because richer grounded evidence repeated the too-quiet outcome."
        },
        [pscustomobject]@{
            result_bucket = "still ambiguous or only tuning-usable"
            support_statement = "manual review still persists because the mixed state would remain unresolved even after another conservative session."
        }
    )
    execution_guidance = [pscustomobject]@{
        mission_runner_command = $missionRunnerCommand
        client_assisted_runner_command = $clientAssistedCommand
        next_cycle_runner_command = $nextCycleCommand
    }
    supporting_artifacts = [pscustomobject]@{
        grounded_evidence_matrix_json = $resolvedMatrixPath
        promotion_state_review_json = $resolvedPromotionReviewPath
        responsive_trial_gate_json = $resolvedResponsiveTrialGatePath
        next_live_plan_json = $resolvedNextLivePlanPath
        base_mission_json = $resolvedBaseMissionPath
        base_mission_markdown = $resolvedBaseMissionMarkdownPath
    }
    responsive_still_closed = ([string](Get-ObjectPropertyValue -Object $promotionStateReview.current_global_state -Name "responsive_gate_verdict" -Default "") -ne "open")
    mixed_evidence_state_resolved = $false
    strong_signal_evidence_already_exists = ([int](Get-ObjectPropertyValue -Object $matrix.aggregate_counts -Name "strong_signal_sessions" -Default 0) -gt 0)
    explanation = ($missionExplanationParts -join " ")
}

Write-JsonFile -Path $missionJsonPath -Value $mission
$missionForMarkdown = Read-JsonFile -Path $missionJsonPath
Write-TextFile -Path $missionMarkdownPath -Value (Get-StrongSignalMissionMarkdown -Mission $missionForMarkdown)

Write-Host "Strong-signal conservative mission:"
Write-Host "  Registry path: $resolvedRegistryPath"
Write-Host "  Output root: $resolvedOutputRoot"
Write-Host "  Mission JSON: $missionJsonPath"
Write-Host "  Mission Markdown: $missionMarkdownPath"
Write-Host "  Recommended live treatment profile: $($mission.recommended_live_treatment_profile)"
Write-Host "  Responsive gate verdict: $($mission.current_global_state.responsive_gate_verdict)"
Write-Host "  Current next-live objective: $($mission.current_global_state.next_live_objective)"
Write-Host "  Mission runner command: $missionRunnerCommand"

[pscustomobject]@{
    StrongSignalMissionJsonPath = $missionJsonPath
    StrongSignalMissionMarkdownPath = $missionMarkdownPath
    GroundedEvidenceMatrixJsonPath = $resolvedMatrixPath
    PromotionStateReviewJsonPath = $resolvedPromotionReviewPath
    ResponsiveTrialGateJsonPath = $resolvedResponsiveTrialGatePath
    NextLivePlanJsonPath = $resolvedNextLivePlanPath
    BaseMissionJsonPath = $resolvedBaseMissionPath
    BaseMissionMarkdownPath = $resolvedBaseMissionMarkdownPath
    RecommendedLiveTreatmentProfile = [string]$mission.recommended_live_treatment_profile
    MissionRunnerCommand = $missionRunnerCommand
}
