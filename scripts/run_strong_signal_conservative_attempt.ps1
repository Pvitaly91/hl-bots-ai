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
    [switch]$AutoSwitchWhenControlReady,
    [switch]$AutoFinishWhenTreatmentGroundedReady,
    [int]$ControlJoinDelaySeconds = 5,
    [int]$TreatmentJoinDelaySeconds = 5,
    [int]$ControlGatePollSeconds = 5,
    [int]$TreatmentGatePollSeconds = 5,
    [int]$ControlStaySecondsMinimum = -1,
    [int]$TreatmentStaySecondsMinimum = -1,
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

function Resolve-StrongSignalMissionArtifacts {
    param(
        [string]$ExplicitMissionPath,
        [string]$ExplicitMissionMarkdownPath,
        [string]$ResolvedLabRoot,
        [string]$ResolvedEvalRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $resolvedMissionPath = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionPath)
        if (-not $resolvedMissionPath) {
            throw "Strong-signal mission JSON was not found: $ExplicitMissionPath"
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

    $prepareScriptPath = Join-Path $PSScriptRoot "prepare_strong_signal_conservative_mission.ps1"
    $preparedMission = & $prepareScriptPath -LabRoot $ResolvedLabRoot -EvalRoot $ResolvedEvalRoot
    $resolvedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "StrongSignalMissionJsonPath" -Default ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionJsonPath" -Default ""))))
    $resolvedMissionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "StrongSignalMissionMarkdownPath" -Default ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionMarkdownPath" -Default ""))))
    if (-not $resolvedMissionPath) {
        throw "The strong-signal conservative mission could not be prepared."
    }

    return [pscustomobject]@{
        JsonPath = $resolvedMissionPath
        MarkdownPath = $resolvedMissionMarkdownPath
    }
}

function Get-StrongSignalStateSnapshot {
    param(
        [string]$ResolvedLabRoot,
        [string]$ResolvedRegistryRoot
    )

    $matrixScriptPath = Join-Path $PSScriptRoot "review_grounded_evidence_matrix.ps1"
    $null = & $matrixScriptPath -LabRoot $ResolvedLabRoot

    $matrixPath = Join-Path $ResolvedRegistryRoot "grounded_evidence_matrix.json"
    $promotionReviewPath = Join-Path $ResolvedRegistryRoot "promotion_state_review.json"
    $responsiveGatePath = Join-Path $ResolvedRegistryRoot "responsive_trial_gate.json"
    $nextLivePlanPath = Join-Path $ResolvedRegistryRoot "next_live_plan.json"

    $matrix = Read-JsonFile -Path $matrixPath
    $promotionReview = Read-JsonFile -Path $promotionReviewPath
    $responsiveGate = Read-JsonFile -Path $responsiveGatePath
    $nextLivePlan = Read-JsonFile -Path $nextLivePlanPath
    $aggregate = Get-ObjectPropertyValue -Object $matrix -Name "aggregate_counts" -Default $null

    $summary = [ordered]@{
        grounded_conservative_sessions = [int](Get-ObjectPropertyValue -Object $aggregate -Name "grounded_conservative_sessions" -Default 0)
        appropriately_conservative_sessions = [int](Get-ObjectPropertyValue -Object $aggregate -Name "appropriately_conservative_sessions" -Default 0)
        too_quiet_sessions = [int](Get-ObjectPropertyValue -Object $aggregate -Name "too_quiet_sessions" -Default 0)
        inconclusive_sessions = [int](Get-ObjectPropertyValue -Object $aggregate -Name "inconclusive_sessions" -Default 0)
        too_reactive_sessions = [int](Get-ObjectPropertyValue -Object $aggregate -Name "too_reactive_sessions" -Default 0)
        strong_signal_sessions = [int](Get-ObjectPropertyValue -Object $aggregate -Name "strong_signal_sessions" -Default 0)
        mixed_evidence_state = [bool](Get-ObjectPropertyValue -Object $aggregate -Name "mixed_evidence_state" -Default $false)
    }

    [pscustomobject]@{
        Matrix = $matrix
        PromotionStateReview = $promotionReview
        ResponsiveTrialGate = $responsiveGate
        NextLivePlan = $nextLivePlan
        Summary = $summary
        ResponsiveGateVerdict = [string](Get-ObjectPropertyValue -Object $responsiveGate -Name "gate_verdict" -Default ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $promotionReview -Name "current_global_state" -Default $null) -Name "responsive_gate_verdict" -Default "")))
        NextLiveObjective = [string](Get-ObjectPropertyValue -Object $nextLivePlan -Name "current_next_live_objective" -Default ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $promotionReview -Name "current_global_state" -Default $null) -Name "next_live_objective" -Default "")))
        Paths = [ordered]@{
            grounded_evidence_matrix_json = Resolve-ExistingPath -Path $matrixPath
            promotion_state_review_json = Resolve-ExistingPath -Path $promotionReviewPath
            responsive_trial_gate_json = Resolve-ExistingPath -Path $responsiveGatePath
            next_live_plan_json = Resolve-ExistingPath -Path $nextLivePlanPath
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
            JsonPath = Join-Path $PairRoot "strong_signal_conservative_attempt.json"
            MarkdownPath = Join-Path $PairRoot "strong_signal_conservative_attempt.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedRegistryRoot "strong_signal_conservative_attempt")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot ("attempt-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $fallbackRoot ("attempt-{0}.md" -f $Stamp)
    }
}

function Find-MatrixSessionByPairRoot {
    param(
        [object]$Matrix,
        [string]$PairRoot
    )

    if ([string]::IsNullOrWhiteSpace($PairRoot)) {
        return $null
    }

    foreach ($session in @(Get-ObjectPropertyValue -Object $Matrix -Name "sessions" -Default @())) {
        if ([string](Get-ObjectPropertyValue -Object $session -Name "pair_root" -Default "") -eq $PairRoot) {
            return $session
        }
    }

    return $null
}

function Get-MissionExactStatus {
    param([object]$MissionExecution)

    $driftDetected = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $MissionExecution -Name "drift_summary" -Default $null) -Name "drift_detected" -Default $false)
    $missionCompliant = [bool](Get-ObjectPropertyValue -Object $MissionExecution -Name "mission_compliant" -Default $false)
    $missionDivergent = [bool](Get-ObjectPropertyValue -Object $MissionExecution -Name "mission_divergent" -Default $false)

    return [pscustomobject]@{
        mission_exact = -not $driftDetected
        mission_drifted = $driftDetected
        mission_compliant = $missionCompliant
        mission_divergent = $missionDivergent
        drift_policy_verdict = [string](Get-ObjectPropertyValue -Object $MissionExecution -Name "drift_policy_verdict" -Default "")
        drift_explanation = [string](Get-ObjectPropertyValue -Object $MissionExecution -Name "explanation" -Default "")
    }
}

function Get-StrongSignalAttemptVerdict {
    param(
        [bool]$ManualReviewRequired,
        [bool]$InterruptedAndRecovered,
        [bool]$CountsTowardPromotion,
        [string]$CertificationVerdict,
        [bool]$StrongSignalCaptured,
        [int]$StrongSignalBefore,
        [int]$StrongSignalAfter,
        [bool]$ControlHumanSignal,
        [bool]$TreatmentHumanSignal,
        [bool]$TreatmentPatchedWhileHumansPresent,
        [bool]$MeaningfulPostPatchObservationWindowExists,
        [bool]$StrongSignalCriteriaMet
    )

    if ($ManualReviewRequired) {
        return "strong-signal-conservative-manual-review-required"
    }

    if ($InterruptedAndRecovered) {
        return "strong-signal-conservative-interrupted-and-recovered"
    }

    if ($StrongSignalCaptured -and $CountsTowardPromotion -and $CertificationVerdict -eq "certified-grounded-evidence" -and $StrongSignalCriteriaMet) {
        if ($StrongSignalBefore -eq 0 -and $StrongSignalAfter -gt 0) {
            return "first-strong-signal-conservative-capture"
        }

        return "strong-signal-conservative-gap-reduced"
    }

    if (-not $CountsTowardPromotion -or $CertificationVerdict -ne "certified-grounded-evidence") {
        if (-not $ControlHumanSignal -or -not $TreatmentHumanSignal -or -not $TreatmentPatchedWhileHumansPresent -or -not $MeaningfulPostPatchObservationWindowExists) {
            return "strong-signal-conservative-insufficient-human-signal"
        }

        return "strong-signal-conservative-manual-review-required"
    }

    return "strong-signal-conservative-but-still-mixed"
}

function Get-MixedStateDirection {
    param(
        [bool]$StrongSignalCaptured,
        [string]$TreatmentBehaviorAssessment,
        [bool]$MixedBefore,
        [bool]$MixedAfter
    )

    if (-not $StrongSignalCaptured) {
        if ($MixedBefore -eq $MixedAfter) {
            return "unchanged"
        }

        return "still-ambiguous"
    }

    switch ($TreatmentBehaviorAssessment) {
        "appropriately conservative" { return "narrowed-toward-keep-conservative" }
        "too quiet" { return "narrowed-toward-future-responsive-consideration" }
        default {
            if ($MixedAfter) {
                return "still-ambiguous"
            }

            return "unchanged"
        }
    }
}

function Get-EvidenceMixNarrative {
    param([object]$Summary)

    return "{0} grounded conservative, {1} appropriately conservative, {2} too quiet, {3} too reactive, {4} strong-signal" -f `
        [int](Get-ObjectPropertyValue -Object $Summary -Name "grounded_conservative_sessions" -Default 0), `
        [int](Get-ObjectPropertyValue -Object $Summary -Name "appropriately_conservative_sessions" -Default 0), `
        [int](Get-ObjectPropertyValue -Object $Summary -Name "too_quiet_sessions" -Default 0), `
        [int](Get-ObjectPropertyValue -Object $Summary -Name "too_reactive_sessions" -Default 0), `
        [int](Get-ObjectPropertyValue -Object $Summary -Name "strong_signal_sessions" -Default 0)
}

function Get-StrongSignalAttemptExplanation {
    param(
        [string]$AttemptVerdict,
        [string]$HumanAttemptExplanation,
        [string]$TreatmentBehaviorAssessment,
        [bool]$StrongSignalCaptured,
        [string]$MixedStateDirection,
        [int]$StrongSignalBefore,
        [int]$StrongSignalAfter,
        [object]$BeforeSummary,
        [object]$AfterSummary
    )

    switch ($AttemptVerdict) {
        "first-strong-signal-conservative-capture" {
            return "The strong-signal mission produced the first counted grounded strong-signal conservative session. Strong-signal grounded evidence moved from $StrongSignalBefore to $StrongSignalAfter, and the latest pair assessed conservative as '$TreatmentBehaviorAssessment'."
        }
        "strong-signal-conservative-gap-reduced" {
            return "The strong-signal mission added another counted grounded strong-signal conservative session. The evidence mix direction is '$MixedStateDirection', and the latest pair assessed conservative as '$TreatmentBehaviorAssessment'."
        }
        "strong-signal-conservative-but-still-mixed" {
            return "The strong-signal mission still landed below a new counted strong-signal conservative capture. The session counted as grounded promotion evidence, but the resulting evidence mix remains '$MixedStateDirection': before $((Get-EvidenceMixNarrative -Summary $BeforeSummary)); after $((Get-EvidenceMixNarrative -Summary $AfterSummary))."
        }
        "strong-signal-conservative-insufficient-human-signal" {
            if (-not [string]::IsNullOrWhiteSpace($HumanAttemptExplanation)) {
                return "The strong-signal mission did not create grounded strong-signal evidence. $HumanAttemptExplanation"
            }

            return "The strong-signal mission did not create grounded strong-signal evidence because the session stayed below the required human-signal or treatment-patch window thresholds."
        }
        "strong-signal-conservative-interrupted-and-recovered" {
            return "The strong-signal mission needed recovery handling before the closeout stack finished. Treat the saved artifacts as recovered evidence, not as a clean direct capture."
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($HumanAttemptExplanation)) {
                return "Manual review is still required for the strong-signal conservative attempt. $HumanAttemptExplanation"
            }

            return "Manual review is still required for the strong-signal conservative attempt."
        }
    }
}

function Get-StrongSignalAttemptMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Strong-Signal Conservative Attempt") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Attempt verdict: $($Report.attempt_verdict)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Mission path used: $($Report.mission_path_used)") | Out-Null
    $lines.Add("- Mission markdown path used: $($Report.mission_markdown_path_used)") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Treatment profile used: $($Report.treatment_profile_used)") | Out-Null
    $lines.Add("- Mission exact: $($Report.mission_execution.mission_exact)") | Out-Null
    $lines.Add("- Mission drifted: $($Report.mission_execution.mission_drifted)") | Out-Null
    $lines.Add("- Mission drift policy verdict: $($Report.mission_execution.drift_policy_verdict)") | Out-Null
    $lines.Add("- Control lane verdict: $($Report.control_lane_verdict)") | Out-Null
    $lines.Add("- Treatment lane verdict: $($Report.treatment_lane_verdict)") | Out-Null
    $lines.Add("- Pair classification: $($Report.pair_classification)") | Out-Null
    $lines.Add("- Certification verdict: $($Report.certification_verdict)") | Out-Null
    $lines.Add("- Counts toward promotion: $($Report.counts_toward_promotion)") | Out-Null
    $lines.Add("- Treatment behavior assessment: $($Report.treatment_behavior_assessment)") | Out-Null
    $lines.Add("- Strong signal: $($Report.strong_signal_before) -> $($Report.strong_signal_after)") | Out-Null
    $lines.Add("- Grounded conservative sessions: $($Report.grounded_sessions_before) -> $($Report.grounded_sessions_after)") | Out-Null
    $lines.Add("- Grounded too quiet: $($Report.grounded_too_quiet_before) -> $($Report.grounded_too_quiet_after)") | Out-Null
    $lines.Add("- Responsive gate: $($Report.responsive_gate_before) -> $($Report.responsive_gate_after)") | Out-Null
    $lines.Add("- Next live objective: $($Report.next_live_objective_before) -> $($Report.next_live_objective_after)") | Out-Null
    $lines.Add("- Evidence mix direction: $($Report.mixed_state_direction)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Strong-Signal Targets") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Control minimum human snapshots: $($Report.mission_targets.control_minimum_human_snapshots)") | Out-Null
    $lines.Add("- Control minimum human presence seconds: $($Report.mission_targets.control_minimum_human_presence_seconds)") | Out-Null
    $lines.Add("- Treatment minimum human snapshots: $($Report.mission_targets.treatment_minimum_human_snapshots)") | Out-Null
    $lines.Add("- Treatment minimum human presence seconds: $($Report.mission_targets.treatment_minimum_human_presence_seconds)") | Out-Null
    $lines.Add("- Treatment minimum patch-while-human-present events: $($Report.mission_targets.treatment_minimum_patch_while_human_present_events)") | Out-Null
    $lines.Add("- Minimum post-patch observation window seconds: $($Report.mission_targets.minimum_post_patch_observation_window_seconds)") | Out-Null
    $lines.Add("- Recommended duration seconds: $($Report.mission_targets.recommended_duration_seconds)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Evidence Mix") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Before: $($Report.evidence_mix_before.narrative)") | Out-Null
    $lines.Add("- After: $($Report.evidence_mix_after.narrative)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Artifacts") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($property in $Report.artifacts.PSObject.Properties) {
        $lines.Add("- $($property.Name): $($property.Value)") | Out-Null
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Get-LabRootDefault)
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot)
}
$resolvedEvalRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "ssca53-live")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
$resolvedRegistryRoot = Ensure-Directory -Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot)
$attemptStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$missionArtifacts = Resolve-StrongSignalMissionArtifacts -ExplicitMissionPath $MissionPath -ExplicitMissionMarkdownPath $MissionMarkdownPath -ResolvedLabRoot $resolvedLabRoot -ResolvedEvalRoot (Get-EvalRootDefault -LabRoot $resolvedLabRoot)
$mission = Read-JsonFile -Path $missionArtifacts.JsonPath
if ($null -eq $mission) {
    throw "Strong-signal mission JSON could not be read: $($missionArtifacts.JsonPath)"
}

$beforeState = Get-StrongSignalStateSnapshot -ResolvedLabRoot $resolvedLabRoot -ResolvedRegistryRoot $resolvedRegistryRoot
$beforeSummary = $beforeState.Summary

$useAutoJoinControl = if ($PSBoundParameters.ContainsKey("AutoJoinControl")) { [bool]$AutoJoinControl } else { $true }
$useAutoJoinTreatment = if ($PSBoundParameters.ContainsKey("AutoJoinTreatment")) { [bool]$AutoJoinTreatment } else { $true }
$useAutoSwitchWhenControlReady = if ($PSBoundParameters.ContainsKey("AutoSwitchWhenControlReady")) { [bool]$AutoSwitchWhenControlReady } else { $true }
$useAutoFinishWhenTreatmentGroundedReady = if ($PSBoundParameters.ContainsKey("AutoFinishWhenTreatmentGroundedReady")) { [bool]$AutoFinishWhenTreatmentGroundedReady } else { $true }

$resolvedControlStayMinimum = if ($ControlStaySecondsMinimum -ge 0) {
    $ControlStaySecondsMinimum
}
else {
    [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_presence_seconds" -Default 0)
}
$resolvedTreatmentStayMinimum = if ($TreatmentStaySecondsMinimum -ge 0) {
    $TreatmentStaySecondsMinimum
}
else {
    [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0)
}

$humanAttemptScriptPath = Join-Path $PSScriptRoot "run_human_participation_conservative_attempt.ps1"
$humanAttemptArguments = [ordered]@{
    MissionPath = $missionArtifacts.JsonPath
    MissionMarkdownPath = $missionArtifacts.MarkdownPath
    LabRoot = $resolvedLabRoot
    OutputRoot = $resolvedEvalRoot
    JoinSequence = $JoinSequence
    ControlJoinDelaySeconds = $ControlJoinDelaySeconds
    TreatmentJoinDelaySeconds = $TreatmentJoinDelaySeconds
    ControlGatePollSeconds = $ControlGatePollSeconds
    TreatmentGatePollSeconds = $TreatmentGatePollSeconds
    ControlStaySecondsMinimum = $resolvedControlStayMinimum
    TreatmentStaySecondsMinimum = $resolvedTreatmentStayMinimum
}
if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) {
    $humanAttemptArguments.ClientExePath = (Get-AbsolutePath -Path $ClientExePath -BasePath $repoRoot)
}
if ($ControlStaySeconds -ge 0) {
    $humanAttemptArguments.ControlStaySeconds = $ControlStaySeconds
}
if ($TreatmentStaySeconds -ge 0) {
    $humanAttemptArguments.TreatmentStaySeconds = $TreatmentStaySeconds
}
if ($useAutoJoinControl) {
    $humanAttemptArguments.AutoJoinControl = $true
}
if ($useAutoJoinTreatment) {
    $humanAttemptArguments.AutoJoinTreatment = $true
}
if ($useAutoSwitchWhenControlReady) {
    $humanAttemptArguments.AutoSwitchWhenControlReady = $true
}
if ($useAutoFinishWhenTreatmentGroundedReady) {
    $humanAttemptArguments.AutoFinishWhenTreatmentGroundedReady = $true
}

$humanAttemptCommandParts = New-Object System.Collections.Generic.List[string]
$humanAttemptCommandParts.Add("powershell -NoProfile -ExecutionPolicy Bypass -File `"$humanAttemptScriptPath`"") | Out-Null
foreach ($entry in $humanAttemptArguments.GetEnumerator()) {
    if ($entry.Value -is [bool]) {
        if ([bool]$entry.Value) {
            $humanAttemptCommandParts.Add("-$($entry.Key)") | Out-Null
        }
    }
    else {
        $humanAttemptCommandParts.Add("-$($entry.Key) `"$($entry.Value)`"") | Out-Null
    }
}
$humanAttemptCommand = $humanAttemptCommandParts -join " "

$humanAttemptResult = & $humanAttemptScriptPath @humanAttemptArguments
$pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "PairRoot" -Default ""))
$humanAttemptJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "HumanParticipationConservativeAttemptJsonPath" -Default ""))
$humanAttemptMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "HumanParticipationConservativeAttemptMarkdownPath" -Default ""))
$humanAttemptReport = Read-JsonFile -Path $humanAttemptJsonPath

$afterState = Get-StrongSignalStateSnapshot -ResolvedLabRoot $resolvedLabRoot -ResolvedRegistryRoot $resolvedRegistryRoot
$afterSummary = $afterState.Summary
$afterMatrixSession = Find-MatrixSessionByPairRoot -Matrix $afterState.Matrix -PairRoot $pairRoot

$pairSummaryPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "pair_summary.json") } else { "" }
$pairSummary = Read-JsonFile -Path $pairSummaryPath
$certificatePath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "grounded_evidence_certificate.json") } else { "" }
$certificate = Read-JsonFile -Path $certificatePath
$scorecardPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "scorecard.json") } else { "" }
$scorecard = Read-JsonFile -Path $scorecardPath
$missionAttainmentPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "mission_attainment.json") } else { "" }
$missionAttainment = Read-JsonFile -Path $missionAttainmentPath
$dossierPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "session_outcome_dossier.json") } else { "" }
$dossier = Read-JsonFile -Path $dossierPath
$missionExecutionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "mission_execution_path" -Default ""))
$missionExecution = Read-JsonFile -Path $missionExecutionPath
$missionExactStatus = Get-MissionExactStatus -MissionExecution $missionExecution

$controlLaneVerdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_lane_verdict" -Default ([string](Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane_verdict" -Default "")))
$treatmentLaneVerdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_verdict" -Default ([string](Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane_verdict" -Default "")))
$pairClassification = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "pair_classification" -Default ([string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")))
$certificationVerdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "certification_verdict" -Default ([string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")))
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "counts_toward_promotion" -Default ([bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)))
$treatmentBehaviorAssessment = [string](Get-ObjectPropertyValue -Object $afterMatrixSession -Name "treatment_behavior_assessment" -Default ([string](Get-ObjectPropertyValue -Object $scorecard -Name "treatment_behavior_assessment" -Default "")))
$treatmentProfileUsed = [string](Get-ObjectPropertyValue `
    -Object $afterMatrixSession `
    -Name "treatment_profile" `
    -Default ([string](Get-ObjectPropertyValue `
        -Object $pairSummary `
        -Name "treatment_profile" `
        -Default ([string](Get-ObjectPropertyValue -Object $mission -Name "recommended_live_treatment_profile" -Default "conservative")))))
$strongSignalBefore = [int](Get-ObjectPropertyValue -Object $beforeSummary -Name "strong_signal_sessions" -Default 0)
$strongSignalAfter = [int](Get-ObjectPropertyValue -Object $afterSummary -Name "strong_signal_sessions" -Default 0)
$groundedBefore = [int](Get-ObjectPropertyValue -Object $beforeSummary -Name "grounded_conservative_sessions" -Default 0)
$groundedAfter = [int](Get-ObjectPropertyValue -Object $afterSummary -Name "grounded_conservative_sessions" -Default 0)
$tooQuietBefore = [int](Get-ObjectPropertyValue -Object $beforeSummary -Name "too_quiet_sessions" -Default 0)
$tooQuietAfter = [int](Get-ObjectPropertyValue -Object $afterSummary -Name "too_quiet_sessions" -Default 0)
$responsiveGateBefore = $beforeState.ResponsiveGateVerdict
$responsiveGateAfter = $afterState.ResponsiveGateVerdict
$nextObjectiveBefore = $beforeState.NextLiveObjective
$nextObjectiveAfter = $afterState.NextLiveObjective
$strongSignalCaptured = [bool](Get-ObjectPropertyValue -Object $afterMatrixSession -Name "contributes_grounded_strong_signal_evidence" -Default $false)
$controlHumanSignal = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "control_human_snapshots_count" -Default 0) -gt 0 -or `
    [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "control_seconds_with_human_presence" -Default 0.0) -gt 0.0
$treatmentHumanSignal = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "treatment_human_snapshots_count" -Default 0) -gt 0 -or `
    [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "treatment_seconds_with_human_presence" -Default 0.0) -gt 0.0
$treatmentPatchedWhileHumansPresent = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "treatment_patched_while_humans_present" -Default $false)
$meaningfulPostPatchObservationWindowExists = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "meaningful_post_patch_observation_window_exists" -Default $false)
$targetedPatchEvents = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default 0)
$targetedPostPatchSeconds = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0)
$targetedControlSnapshots = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_snapshots" -Default 0)
$targetedControlSeconds = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_presence_seconds" -Default 0)
$targetedTreatmentSnapshots = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_snapshots" -Default 0)
$targetedTreatmentSeconds = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0)
$recommendedDurationSeconds = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "launcher_defaults" -Default $null) -Name "duration_seconds" -Default 0)
$controlSnapshotsActual = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "control_human_snapshots_count" -Default 0)
$controlSecondsActual = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "control_seconds_with_human_presence" -Default 0.0)
$treatmentSnapshotsActual = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "treatment_human_snapshots_count" -Default 0)
$treatmentSecondsActual = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "human_signal" -Default $null) -Name "treatment_seconds_with_human_presence" -Default 0.0)
$treatmentPatchGuidance = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_patch_guidance" -Default $null
$treatmentPatchEventsActual = [int](Get-ObjectPropertyValue -Object $treatmentPatchGuidance -Name "treatment_remaining_patch_while_human_present_events" -Default 0)
$treatmentPatchEventsRemaining = $treatmentPatchEventsActual
$treatmentPatchEventsActual = [Math]::Max(0, $targetedPatchEvents - $treatmentPatchEventsRemaining)
$postPatchSecondsRemaining = [double](Get-ObjectPropertyValue -Object $treatmentPatchGuidance -Name "treatment_remaining_post_patch_observation_seconds" -Default 0.0)
$postPatchSecondsActual = [Math]::Max(0.0, $targetedPostPatchSeconds - $postPatchSecondsRemaining)
$strongSignalCriteriaMet = $strongSignalCaptured -and `
    $controlSnapshotsActual -ge $targetedControlSnapshots -and `
    $controlSecondsActual -ge $targetedControlSeconds -and `
    $treatmentSnapshotsActual -ge $targetedTreatmentSnapshots -and `
    $treatmentSecondsActual -ge $targetedTreatmentSeconds -and `
    $treatmentPatchEventsActual -ge $targetedPatchEvents -and `
    $postPatchSecondsActual -ge $targetedPostPatchSeconds
$manualReviewRequired = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "attempt_verdict" -Default "") -eq "manual-review-required" -or `
    [bool](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "grounded_consistency_review_required" -Default $false)
$finalRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "final_recovery_verdict" -Default "")
$interruptedAndRecovered = $finalRecoveryVerdict -like "*recover*"
$mixedStateDirection = Get-MixedStateDirection `
    -StrongSignalCaptured $strongSignalCaptured `
    -TreatmentBehaviorAssessment $treatmentBehaviorAssessment `
    -MixedBefore ([bool](Get-ObjectPropertyValue -Object $beforeSummary -Name "mixed_evidence_state" -Default $false)) `
    -MixedAfter ([bool](Get-ObjectPropertyValue -Object $afterSummary -Name "mixed_evidence_state" -Default $false))
$attemptVerdict = Get-StrongSignalAttemptVerdict `
    -ManualReviewRequired $manualReviewRequired `
    -InterruptedAndRecovered $interruptedAndRecovered `
    -CountsTowardPromotion $countsTowardPromotion `
    -CertificationVerdict $certificationVerdict `
    -StrongSignalCaptured $strongSignalCaptured `
    -StrongSignalBefore $strongSignalBefore `
    -StrongSignalAfter $strongSignalAfter `
    -ControlHumanSignal $controlHumanSignal `
    -TreatmentHumanSignal $treatmentHumanSignal `
    -TreatmentPatchedWhileHumansPresent $treatmentPatchedWhileHumansPresent `
    -MeaningfulPostPatchObservationWindowExists $meaningfulPostPatchObservationWindowExists `
    -StrongSignalCriteriaMet $strongSignalCriteriaMet
$explanation = Get-StrongSignalAttemptExplanation `
    -AttemptVerdict $attemptVerdict `
    -HumanAttemptExplanation ([string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "explanation" -Default "")) `
    -TreatmentBehaviorAssessment $treatmentBehaviorAssessment `
    -StrongSignalCaptured $strongSignalCaptured `
    -MixedStateDirection $mixedStateDirection `
    -StrongSignalBefore $strongSignalBefore `
    -StrongSignalAfter $strongSignalAfter `
    -BeforeSummary $beforeSummary `
    -AfterSummary $afterSummary

$outputPaths = Get-ReportPaths -PairRoot $pairRoot -ResolvedRegistryRoot $resolvedRegistryRoot -Stamp $attemptStamp
$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_verdict = $attemptVerdict
    explanation = $explanation
    mission_path_used = $missionArtifacts.JsonPath
    mission_markdown_path_used = $missionArtifacts.MarkdownPath
    pair_root = $pairRoot
    treatment_profile_used = $treatmentProfileUsed
    mission_execution = [ordered]@{
        mission_exact = $missionExactStatus.mission_exact
        mission_drifted = $missionExactStatus.mission_drifted
        mission_compliant = $missionExactStatus.mission_compliant
        mission_divergent = $missionExactStatus.mission_divergent
        drift_policy_verdict = $missionExactStatus.drift_policy_verdict
        drift_explanation = $missionExactStatus.drift_explanation
        mission_execution_json = $missionExecutionPath
    }
    mission_targets = [ordered]@{
        control_minimum_human_snapshots = $targetedControlSnapshots
        control_minimum_human_presence_seconds = $targetedControlSeconds
        treatment_minimum_human_snapshots = $targetedTreatmentSnapshots
        treatment_minimum_human_presence_seconds = $targetedTreatmentSeconds
        treatment_minimum_patch_while_human_present_events = $targetedPatchEvents
        minimum_post_patch_observation_window_seconds = $targetedPostPatchSeconds
        recommended_duration_seconds = $recommendedDurationSeconds
    }
    control_lane_verdict = $controlLaneVerdict
    treatment_lane_verdict = $treatmentLaneVerdict
    pair_classification = $pairClassification
    certification_verdict = $certificationVerdict
    counts_toward_promotion = $countsTowardPromotion
    treatment_behavior_assessment = $treatmentBehaviorAssessment
    strong_signal_before = $strongSignalBefore
    strong_signal_after = $strongSignalAfter
    grounded_sessions_before = $groundedBefore
    grounded_sessions_after = $groundedAfter
    grounded_too_quiet_before = $tooQuietBefore
    grounded_too_quiet_after = $tooQuietAfter
    responsive_gate_before = $responsiveGateBefore
    responsive_gate_after = $responsiveGateAfter
    next_live_objective_before = $nextObjectiveBefore
    next_live_objective_after = $nextObjectiveAfter
    evidence_mix_before = [ordered]@{
        grounded_conservative_sessions = $beforeSummary.grounded_conservative_sessions
        appropriately_conservative_sessions = $beforeSummary.appropriately_conservative_sessions
        too_quiet_sessions = $beforeSummary.too_quiet_sessions
        too_reactive_sessions = $beforeSummary.too_reactive_sessions
        strong_signal_sessions = $beforeSummary.strong_signal_sessions
        mixed_evidence_state = $beforeSummary.mixed_evidence_state
        narrative = Get-EvidenceMixNarrative -Summary $beforeSummary
    }
    evidence_mix_after = [ordered]@{
        grounded_conservative_sessions = $afterSummary.grounded_conservative_sessions
        appropriately_conservative_sessions = $afterSummary.appropriately_conservative_sessions
        too_quiet_sessions = $afterSummary.too_quiet_sessions
        too_reactive_sessions = $afterSummary.too_reactive_sessions
        strong_signal_sessions = $afterSummary.strong_signal_sessions
        mixed_evidence_state = $afterSummary.mixed_evidence_state
        narrative = Get-EvidenceMixNarrative -Summary $afterSummary
    }
    mixed_state_direction = $mixedStateDirection
    mixed_state_reduction = [ordered]@{
        mixed_state_before = $beforeSummary.mixed_evidence_state
        mixed_state_after = $afterSummary.mixed_evidence_state
        narrowed_toward_keep_conservative = $mixedStateDirection -eq "narrowed-toward-keep-conservative"
        narrowed_toward_future_responsive_consideration = $mixedStateDirection -eq "narrowed-toward-future-responsive-consideration"
        still_ambiguous = $mixedStateDirection -eq "still-ambiguous"
        unchanged = $mixedStateDirection -eq "unchanged"
    }
    strong_signal_capture = [ordered]@{
        captured = $strongSignalCaptured
        strong_signal_criteria_met = $strongSignalCriteriaMet
        first_strong_signal_capture = $attemptVerdict -eq "first-strong-signal-conservative-capture"
    }
    reused_stack = [ordered]@{
        human_participation_conservative_attempt = $true
        live_monitor = $true
        certification = $true
        mission_attainment = $true
        session_outcome_dossier = $true
        grounded_evidence_matrix = $true
        responsive_gate = $true
        next_live_planner = $true
    }
    artifacts = [ordered]@{
        strong_signal_conservative_attempt_json = $outputPaths.JsonPath
        strong_signal_conservative_attempt_markdown = $outputPaths.MarkdownPath
        strong_signal_conservative_mission_json = $missionArtifacts.JsonPath
        strong_signal_conservative_mission_markdown = $missionArtifacts.MarkdownPath
        human_participation_conservative_attempt_json = $humanAttemptJsonPath
        human_participation_conservative_attempt_markdown = $humanAttemptMarkdownPath
        pair_summary_json = $pairSummaryPath
        grounded_evidence_certificate_json = $certificatePath
        scorecard_json = $scorecardPath
        mission_attainment_json = $missionAttainmentPath
        session_outcome_dossier_json = $dossierPath
        mission_execution_json = $missionExecutionPath
        grounded_evidence_matrix_json = [string](Get-ObjectPropertyValue -Object $afterState.Paths -Name "grounded_evidence_matrix_json" -Default "")
        promotion_state_review_json = [string](Get-ObjectPropertyValue -Object $afterState.Paths -Name "promotion_state_review_json" -Default "")
        responsive_trial_gate_json = [string](Get-ObjectPropertyValue -Object $afterState.Paths -Name "responsive_trial_gate_json" -Default "")
        next_live_plan_json = [string](Get-ObjectPropertyValue -Object $afterState.Paths -Name "next_live_plan_json" -Default "")
    }
    execution = [ordered]@{
        wrapped_command = $humanAttemptCommand
        join_sequence = $JoinSequence
        auto_join_control = $useAutoJoinControl
        auto_join_treatment = $useAutoJoinTreatment
        auto_switch_when_control_ready = $useAutoSwitchWhenControlReady
        auto_finish_when_treatment_grounded_ready = $useAutoFinishWhenTreatmentGroundedReady
        output_root = $resolvedEvalRoot
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-StrongSignalAttemptMarkdown -Report $reportForMarkdown)

Write-Host "Strong-signal conservative attempt:"
Write-Host "  Attempt verdict: $($report.attempt_verdict)"
Write-Host "  Pair root: $($report.pair_root)"
Write-Host "  Mission drift verdict: $($report.mission_execution.drift_policy_verdict)"
Write-Host "  Certification verdict: $($report.certification_verdict)"
Write-Host "  Counts toward promotion: $($report.counts_toward_promotion)"
Write-Host "  Strong signal: $($report.strong_signal_before) -> $($report.strong_signal_after)"
Write-Host "  Attempt report JSON: $($outputPaths.JsonPath)"
Write-Host "  Attempt report Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $pairRoot
    StrongSignalConservativeAttemptJsonPath = $outputPaths.JsonPath
    StrongSignalConservativeAttemptMarkdownPath = $outputPaths.MarkdownPath
    AttemptVerdict = $report.attempt_verdict
    CertificationVerdict = $report.certification_verdict
    CountsTowardPromotion = $report.counts_toward_promotion
}
