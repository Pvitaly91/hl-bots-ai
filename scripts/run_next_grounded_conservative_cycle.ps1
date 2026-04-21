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

function Get-ReportPaths {
    param(
        [string]$PairRoot,
        [string]$ResolvedRegistryRoot,
        [string]$Stamp
    )

    if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
        return [ordered]@{
            JsonPath = Join-Path $PairRoot "grounded_conservative_cycle_report.json"
            MarkdownPath = Join-Path $PairRoot "grounded_conservative_cycle_report.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedRegistryRoot "grounded_conservative_cycle_report")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot ("cycle-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $fallbackRoot ("cycle-{0}.md" -f $Stamp)
    }
}

function Get-CycleVerdict {
    param(
        [bool]$ManualReviewRequired,
        [bool]$CountsTowardPromotion,
        [string]$CertificationVerdict,
        [string]$EvidenceOrigin,
        [int]$GroundedSessionsBefore,
        [int]$GroundedSessionsAfter,
        [bool]$ReducedPromotionGap,
        [bool]$ObjectiveAdvanced
    )

    if ($ManualReviewRequired) {
        return "manual-review-required"
    }

    $grounded = $CountsTowardPromotion -and $CertificationVerdict -eq "certified-grounded-evidence" -and $EvidenceOrigin -notin @("rehearsal", "synthetic")
    if (-not $grounded) {
        return "another-non-grounded-conservative-attempt"
    }

    if ($GroundedSessionsBefore -eq 1 -and $GroundedSessionsAfter -ge 2) {
        return "second-grounded-conservative-capture"
    }

    if ($ObjectiveAdvanced) {
        return "conservative-objective-advanced"
    }

    if ($ReducedPromotionGap) {
        return "conservative-gap-reduced-but-objective-unchanged"
    }

    return "conservative-gap-reduced-but-objective-unchanged"
}

function Get-CycleExplanation {
    param(
        [string]$CycleVerdict,
        [string]$HumanAttemptExplanation,
        [string[]]$GroundedConsistencyIssues,
        [int]$GroundedSessionsBefore,
        [int]$GroundedSessionsAfter,
        [int]$GroundedSessionsDelta,
        [string]$NextObjectiveBefore,
        [string]$NextObjectiveAfter,
        [string]$ResponsiveGateBefore,
        [string]$ResponsiveGateAfter
    )

    switch ($CycleVerdict) {
        "manual-review-required" {
            if ($GroundedConsistencyIssues.Count -gt 0) {
                return "The latest live conservative cycle needs manual review before it can be treated as a clean milestone advance. Certification counted the pair, but the other evidence layers still disagree: $($GroundedConsistencyIssues -join ' ')"
            }

            return "The latest live conservative cycle needs manual review before it can be treated as a clean milestone advance."
        }
        "second-grounded-conservative-capture" {
            return "The latest live conservative cycle became the second certified grounded conservative session. The grounded conservative session count moved from $GroundedSessionsBefore to $GroundedSessionsAfter (delta $GroundedSessionsDelta). The next objective moved from '$NextObjectiveBefore' to '$NextObjectiveAfter'. The responsive gate stayed '$ResponsiveGateBefore' -> '$ResponsiveGateAfter'."
        }
        "conservative-objective-advanced" {
            return "The latest live conservative cycle counted toward promotion and advanced the next objective from '$NextObjectiveBefore' to '$NextObjectiveAfter'. The grounded conservative session count moved from $GroundedSessionsBefore to $GroundedSessionsAfter (delta $GroundedSessionsDelta). The responsive gate stayed '$ResponsiveGateBefore' -> '$ResponsiveGateAfter'."
        }
        "conservative-gap-reduced-but-objective-unchanged" {
            return "The latest live conservative cycle counted toward promotion and reduced the conservative evidence gap, but the next objective stayed '$NextObjectiveAfter'. The grounded conservative session count moved from $GroundedSessionsBefore to $GroundedSessionsAfter (delta $GroundedSessionsDelta). The responsive gate stayed '$ResponsiveGateBefore' -> '$ResponsiveGateAfter'."
        }
        default {
            if (-not [string]::IsNullOrWhiteSpace($HumanAttemptExplanation)) {
                return "The latest conservative cycle did not count as grounded promotion evidence. $HumanAttemptExplanation"
            }

            return "The latest conservative cycle did not count as grounded promotion evidence, so the milestone did not advance."
        }
    }
}

function Get-CycleMarkdown {
    param([object]$Report)

    $cycleVerdict = [string](Get-ObjectPropertyValue -Object $Report -Name "cycle_verdict" -Default "")
    $explanation = [string](Get-ObjectPropertyValue -Object $Report -Name "explanation" -Default "")
    $pairRoot = [string](Get-ObjectPropertyValue -Object $Report -Name "pair_root" -Default "")
    $missionPathUsed = [string](Get-ObjectPropertyValue -Object $Report -Name "mission_path_used" -Default "")
    $treatmentProfileUsed = [string](Get-ObjectPropertyValue -Object $Report -Name "treatment_profile_used" -Default "")
    $controlLaneVerdict = [string](Get-ObjectPropertyValue -Object $Report -Name "control_lane_verdict" -Default "")
    $treatmentLaneVerdict = [string](Get-ObjectPropertyValue -Object $Report -Name "treatment_lane_verdict" -Default "")
    $pairClassification = [string](Get-ObjectPropertyValue -Object $Report -Name "pair_classification" -Default "")
    $certificationVerdict = [string](Get-ObjectPropertyValue -Object $Report -Name "certification_verdict" -Default "")
    $countsTowardPromotion = [string](Get-ObjectPropertyValue -Object $Report -Name "counts_toward_promotion" -Default $false)
    $groundedBefore = [string](Get-ObjectPropertyValue -Object $Report -Name "grounded_sessions_before" -Default 0)
    $groundedAfter = [string](Get-ObjectPropertyValue -Object $Report -Name "grounded_sessions_after" -Default 0)
    $groundedDelta = [string](Get-ObjectPropertyValue -Object $Report -Name "grounded_sessions_delta" -Default 0)
    $tooQuietBefore = [string](Get-ObjectPropertyValue -Object $Report -Name "grounded_too_quiet_before" -Default 0)
    $tooQuietAfter = [string](Get-ObjectPropertyValue -Object $Report -Name "grounded_too_quiet_after" -Default 0)
    $tooQuietDelta = [string](Get-ObjectPropertyValue -Object $Report -Name "grounded_too_quiet_delta" -Default 0)
    $strongBefore = [string](Get-ObjectPropertyValue -Object $Report -Name "strong_signal_before" -Default 0)
    $strongAfter = [string](Get-ObjectPropertyValue -Object $Report -Name "strong_signal_after" -Default 0)
    $strongDelta = [string](Get-ObjectPropertyValue -Object $Report -Name "strong_signal_delta" -Default 0)
    $responsiveBefore = [string](Get-ObjectPropertyValue -Object $Report -Name "responsive_gate_before" -Default "")
    $responsiveAfter = [string](Get-ObjectPropertyValue -Object $Report -Name "responsive_gate_after" -Default "")
    $objectiveBefore = [string](Get-ObjectPropertyValue -Object $Report -Name "next_live_objective_before" -Default "")
    $objectiveAfter = [string](Get-ObjectPropertyValue -Object $Report -Name "next_live_objective_after" -Default "")
    $humanAttemptVerdict = [string](Get-ObjectPropertyValue -Object $Report -Name "human_participation_attempt_verdict" -Default "")

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Grounded Conservative Cycle Report") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Cycle verdict: $cycleVerdict") | Out-Null
    $lines.Add("- Explanation: $explanation") | Out-Null
    $lines.Add("- Pair root: $pairRoot") | Out-Null
    $lines.Add("- Mission path used: $missionPathUsed") | Out-Null
    $lines.Add("- Treatment profile used: $treatmentProfileUsed") | Out-Null
    $lines.Add("- Control lane verdict: $controlLaneVerdict") | Out-Null
    $lines.Add("- Treatment lane verdict: $treatmentLaneVerdict") | Out-Null
    $lines.Add("- Pair classification: $pairClassification") | Out-Null
    $lines.Add("- Certification verdict: $certificationVerdict") | Out-Null
    $lines.Add("- Counts toward promotion: $($countsTowardPromotion.ToLowerInvariant())") | Out-Null
    $lines.Add("- Grounded sessions: $groundedBefore -> $groundedAfter (delta $groundedDelta)") | Out-Null
    $lines.Add("- Grounded too quiet: $tooQuietBefore -> $tooQuietAfter (delta $tooQuietDelta)") | Out-Null
    $lines.Add("- Strong signal: $strongBefore -> $strongAfter (delta $strongDelta)") | Out-Null
    $lines.Add("- Responsive gate: $responsiveBefore -> $responsiveAfter") | Out-Null
    $lines.Add("- Next live objective: $objectiveBefore -> $objectiveAfter") | Out-Null
    $lines.Add("- Human participation attempt verdict: $humanAttemptVerdict") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Artifacts") | Out-Null

    $artifacts = Get-ObjectPropertyValue -Object $Report -Name "artifacts" -Default $null
    if ($null -ne $artifacts) {
        foreach ($property in $artifacts.PSObject.Properties) {
            $lines.Add("- $($property.Name): $($property.Value)") | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Ensure-Directory -Path (Join-Path $repoRoot "lab")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $LabRoot)
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedLabRoot "logs\eval")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot)
}

$resolvedRegistryRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "registry")
$cycleStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$pairRoot = ""
$humanAttemptReport = $null
$firstAttemptReport = $null
$delta = $null
$missionAttainment = $null
$dossier = $null
$certificate = $null
$pairSummary = $null
$humanAttemptArtifacts = $null
$humanAttemptJsonPath = ""
$humanAttemptMarkdownPath = ""
$outputPaths = Get-ReportPaths -PairRoot "" -ResolvedRegistryRoot $resolvedRegistryRoot -Stamp $cycleStamp

try {
    $humanAttemptScriptPath = Join-Path $PSScriptRoot "run_human_participation_conservative_attempt.ps1"
    $humanAttemptParams = @{
        LabRoot = $resolvedLabRoot
        OutputRoot = $resolvedOutputRoot
        JoinSequence = $JoinSequence
        ControlJoinDelaySeconds = $ControlJoinDelaySeconds
        TreatmentJoinDelaySeconds = $TreatmentJoinDelaySeconds
        ControlGatePollSeconds = $ControlGatePollSeconds
        TreatmentGatePollSeconds = $TreatmentGatePollSeconds
        ControlStaySecondsMinimum = $ControlStaySecondsMinimum
        TreatmentStaySecondsMinimum = $TreatmentStaySecondsMinimum
        ControlStaySeconds = $ControlStaySeconds
        TreatmentStaySeconds = $TreatmentStaySeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionPath)) {
        $humanAttemptParams["MissionPath"] = $MissionPath
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionMarkdownPath)) {
        $humanAttemptParams["MissionMarkdownPath"] = $MissionMarkdownPath
    }

    if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) {
        $humanAttemptParams["ClientExePath"] = $ClientExePath
    }

    if ($PSBoundParameters.ContainsKey("AutoJoinControl")) {
        $humanAttemptParams["AutoJoinControl"] = [bool]$AutoJoinControl
    }

    if ($PSBoundParameters.ContainsKey("AutoJoinTreatment")) {
        $humanAttemptParams["AutoJoinTreatment"] = [bool]$AutoJoinTreatment
    }

    if ($PSBoundParameters.ContainsKey("AutoSwitchWhenControlReady")) {
        $humanAttemptParams["AutoSwitchWhenControlReady"] = [bool]$AutoSwitchWhenControlReady
    }

    if ($PSBoundParameters.ContainsKey("AutoFinishWhenTreatmentGroundedReady")) {
        $humanAttemptParams["AutoFinishWhenTreatmentGroundedReady"] = [bool]$AutoFinishWhenTreatmentGroundedReady
    }

    $humanAttemptResult = & $humanAttemptScriptPath @humanAttemptParams
    $pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "PairRoot" -Default ""))
    $humanAttemptJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "HumanParticipationConservativeAttemptJsonPath" -Default (Join-Path $pairRoot "human_participation_conservative_attempt.json")))
    $humanAttemptMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptResult -Name "HumanParticipationConservativeAttemptMarkdownPath" -Default (Join-Path $pairRoot "human_participation_conservative_attempt.md")))
    $outputPaths = Get-ReportPaths -PairRoot $pairRoot -ResolvedRegistryRoot $resolvedRegistryRoot -Stamp $cycleStamp

    $humanAttemptReport = Read-JsonFile -Path $humanAttemptJsonPath
    $humanAttemptArtifacts = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "artifacts" -Default $null
    $firstAttemptReport = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.json") } else { $null }
    $delta = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "promotion_gap_delta.json") } else { $null }
    $missionAttainment = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "mission_attainment.json") } else { $null }
    $dossier = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "session_outcome_dossier.json") } else { $null }
    $certificate = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "grounded_evidence_certificate.json") } else { $null }
    $pairSummary = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "pair_summary.json") } else { $null }
}
catch {
    $fallbackReport = [ordered]@{
        schema_version = 1
        prompt_id = Get-RepoPromptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        cycle_verdict = "manual-review-required"
        explanation = "The next grounded conservative cycle helper did not complete cleanly. $($_.Exception.Message)"
        mission_path_used = ""
        pair_root = ""
        treatment_profile_used = "conservative"
        control_lane_verdict = ""
        treatment_lane_verdict = ""
        pair_classification = ""
        certification_verdict = ""
        counts_toward_promotion = $false
        grounded_sessions_before = 0
        grounded_sessions_after = 0
        grounded_sessions_delta = 0
        grounded_too_quiet_before = 0
        grounded_too_quiet_after = 0
        grounded_too_quiet_delta = 0
        strong_signal_before = 0
        strong_signal_after = 0
        strong_signal_delta = 0
        responsive_gate_before = ""
        responsive_gate_after = ""
        next_live_objective_before = ""
        next_live_objective_after = ""
        artifacts = [ordered]@{
            grounded_conservative_cycle_report_json = $outputPaths.JsonPath
            grounded_conservative_cycle_report_markdown = $outputPaths.MarkdownPath
        }
    }

    Write-JsonFile -Path $outputPaths.JsonPath -Value $fallbackReport
    $fallbackForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
    Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-CycleMarkdown -Report $fallbackForMarkdown)
    throw
}

$missionPathUsed = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "mission_path_used" -Default "")
$missionMarkdownPathUsed = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "mission_markdown_path_used" -Default "")
$missionExecutionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "mission_execution_path" -Default (Join-Path $pairRoot "guided_session\mission_execution.json")))
$treatmentProfileUsed = [string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "treatment_profile_used" -Default (Get-ObjectPropertyValue -Object $missionAttainment -Name "treatment_profile_used" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_profile" -Default "conservative")))
$certificationVerdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "certification_verdict" -Default ""))
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default (Get-ObjectPropertyValue -Object $humanAttemptReport -Name "counts_toward_promotion" -Default $false))
$evidenceOrigin = [string](Get-ObjectPropertyValue -Object $certificate -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Default ""))
$groundedSessionsBefore = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_sessions_before" -Default 0)
$groundedSessionsAfter = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_sessions_after" -Default 0)
$groundedSessionsDelta = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_sessions_delta" -Default 0)
$groundedTooQuietBefore = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_too_quiet_before" -Default 0)
$groundedTooQuietAfter = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_too_quiet_after" -Default 0)
$groundedTooQuietDelta = [int](Get-ObjectPropertyValue -Object $delta -Name "grounded_too_quiet_delta" -Default 0)
$strongSignalBefore = [int](Get-ObjectPropertyValue -Object $delta -Name "strong_signal_before" -Default 0)
$strongSignalAfter = [int](Get-ObjectPropertyValue -Object $delta -Name "strong_signal_after" -Default 0)
$strongSignalDelta = [int](Get-ObjectPropertyValue -Object $delta -Name "strong_signal_delta" -Default 0)
$groundedConsistencyReviewRequired = [bool](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "grounded_consistency_review_required" -Default $false)
$groundedConsistencyIssues = @([string[]](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "grounded_consistency_issues" -Default @()))
$responsiveGateBeforeVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_before" -Default $null) -Name "gate_verdict" -Default "")
$responsiveGateBeforeAction = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_before" -Default $null) -Name "next_live_action" -Default "")
$responsiveGateAfterVerdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_after" -Default $null) -Name "gate_verdict" -Default "")
$responsiveGateAfterAction = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $delta -Name "responsive_gate_after" -Default $null) -Name "next_live_action" -Default "")
$responsiveGateBefore = if ($responsiveGateBeforeVerdict -and $responsiveGateBeforeAction) { "$responsiveGateBeforeVerdict/$responsiveGateBeforeAction" } else { $responsiveGateBeforeVerdict }
$responsiveGateAfter = if ($responsiveGateAfterVerdict -and $responsiveGateAfterAction) { "$responsiveGateAfterVerdict/$responsiveGateAfterAction" } else { $responsiveGateAfterVerdict }
$nextObjectiveBefore = [string](Get-ObjectPropertyValue -Object $delta -Name "next_objective_before" -Default (Get-ObjectPropertyValue -Object $dossier -Name "previous_next_live_objective" -Default ""))
$nextObjectiveAfter = [string](Get-ObjectPropertyValue -Object $delta -Name "next_objective_after" -Default (Get-ObjectPropertyValue -Object $dossier -Name "current_next_live_objective" -Default ""))
$reducedPromotionGap = [bool](Get-ObjectPropertyValue -Object $delta -Name "reduced_promotion_gap" -Default ($groundedSessionsDelta -ne 0 -or $groundedTooQuietDelta -ne 0 -or $strongSignalDelta -ne 0))
$objectiveAdvanced = -not [string]::IsNullOrWhiteSpace($nextObjectiveBefore) -and -not [string]::IsNullOrWhiteSpace($nextObjectiveAfter) -and $nextObjectiveBefore -ne $nextObjectiveAfter
$phaseFlowJsonFallback = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "conservative_phase_flow.json") } else { "" }
$phaseFlowMarkdownFallback = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "conservative_phase_flow.md") } else { "" }
$cycleVerdict = Get-CycleVerdict `
    -ManualReviewRequired $groundedConsistencyReviewRequired `
    -CountsTowardPromotion $countsTowardPromotion `
    -CertificationVerdict $certificationVerdict `
    -EvidenceOrigin $evidenceOrigin `
    -GroundedSessionsBefore $groundedSessionsBefore `
    -GroundedSessionsAfter $groundedSessionsAfter `
    -ReducedPromotionGap $reducedPromotionGap `
    -ObjectiveAdvanced $objectiveAdvanced
$explanation = Get-CycleExplanation `
    -CycleVerdict $cycleVerdict `
    -HumanAttemptExplanation ([string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "explanation" -Default "")) `
    -GroundedConsistencyIssues @($groundedConsistencyIssues) `
    -GroundedSessionsBefore $groundedSessionsBefore `
    -GroundedSessionsAfter $groundedSessionsAfter `
    -GroundedSessionsDelta $groundedSessionsDelta `
    -NextObjectiveBefore $nextObjectiveBefore `
    -NextObjectiveAfter $nextObjectiveAfter `
    -ResponsiveGateBefore $responsiveGateBefore `
    -ResponsiveGateAfter $responsiveGateAfter

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    cycle_verdict = $cycleVerdict
    explanation = $explanation
    mission_path_used = $missionPathUsed
    mission_markdown_path_used = $missionMarkdownPathUsed
    mission_execution_path = $missionExecutionPath
    pair_root = $pairRoot
    treatment_profile_used = $treatmentProfileUsed
    evidence_origin = $evidenceOrigin
    human_participation_attempt_verdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "attempt_verdict" -Default "")
    control_lane_verdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "control_lane_verdict" -Default "")
    treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_lane_verdict" -Default "")
    pair_classification = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "pair_classification" -Default "")
    certification_verdict = $certificationVerdict
    counts_toward_promotion = $countsTowardPromotion
    grounded_sessions_before = $groundedSessionsBefore
    grounded_sessions_after = $groundedSessionsAfter
    grounded_sessions_delta = $groundedSessionsDelta
    grounded_too_quiet_before = $groundedTooQuietBefore
    grounded_too_quiet_after = $groundedTooQuietAfter
    grounded_too_quiet_delta = $groundedTooQuietDelta
    strong_signal_before = $strongSignalBefore
    strong_signal_after = $strongSignalAfter
    strong_signal_delta = $strongSignalDelta
    responsive_gate_before = $responsiveGateBefore
    responsive_gate_after = $responsiveGateAfter
    next_live_objective_before = $nextObjectiveBefore
    next_live_objective_after = $nextObjectiveAfter
    became_second_grounded_conservative_capture = (-not $groundedConsistencyReviewRequired) -and ($countsTowardPromotion -and $certificationVerdict -eq "certified-grounded-evidence" -and $groundedSessionsBefore -eq 1 -and $groundedSessionsAfter -ge 2)
    reduced_promotion_gap = $reducedPromotionGap
    objective_advanced = $objectiveAdvanced
    manual_review_required = $groundedConsistencyReviewRequired
    grounded_consistency_issues = @($groundedConsistencyIssues)
    closeout_stack_reused = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "closeout_stack_reused" -Default $null
    artifacts = [ordered]@{
        grounded_conservative_cycle_report_json = $outputPaths.JsonPath
        grounded_conservative_cycle_report_markdown = $outputPaths.MarkdownPath
        human_participation_conservative_attempt_json = $humanAttemptJsonPath
        human_participation_conservative_attempt_markdown = $humanAttemptMarkdownPath
        conservative_phase_flow_json = [string](Get-ObjectPropertyValue -Object $humanAttemptArtifacts -Name "conservative_phase_flow_json" -Default $phaseFlowJsonFallback)
        conservative_phase_flow_markdown = [string](Get-ObjectPropertyValue -Object $humanAttemptArtifacts -Name "conservative_phase_flow_markdown" -Default $phaseFlowMarkdownFallback)
        first_grounded_conservative_attempt_json = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.json") } else { "" }
        first_grounded_conservative_attempt_markdown = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.md") } else { "" }
        promotion_gap_delta_json = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "promotion_gap_delta.json") } else { "" }
        session_outcome_dossier_json = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "session_outcome_dossier.json") } else { "" }
        mission_attainment_json = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "mission_attainment.json") } else { "" }
        grounded_evidence_certificate_json = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "grounded_evidence_certificate.json") } else { "" }
        mission_execution_json = $missionExecutionPath
        pair_summary_json = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "pair_summary.json") } else { "" }
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-CycleMarkdown -Report $reportForMarkdown)

Write-Host "Grounded conservative cycle:"
Write-Host "  Cycle verdict: $($report.cycle_verdict)"
Write-Host "  Pair root: $($report.pair_root)"
Write-Host "  Certification verdict: $($report.certification_verdict)"
Write-Host "  Counts toward promotion: $($report.counts_toward_promotion)"
Write-Host "  Grounded sessions: $($report.grounded_sessions_before) -> $($report.grounded_sessions_after) (delta $($report.grounded_sessions_delta))"
Write-Host "  Next live objective: $($report.next_live_objective_before) -> $($report.next_live_objective_after)"
Write-Host "  Cycle report JSON: $($outputPaths.JsonPath)"
Write-Host "  Cycle report Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $pairRoot
    GroundedConservativeCycleReportJsonPath = $outputPaths.JsonPath
    GroundedConservativeCycleReportMarkdownPath = $outputPaths.MarkdownPath
    CycleVerdict = $report.cycle_verdict
    CertificationVerdict = $report.certification_verdict
    CountsTowardPromotion = $report.counts_toward_promotion
}
