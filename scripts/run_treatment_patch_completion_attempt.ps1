[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$ClientExePath = ""
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

function Get-ReportPaths {
    param(
        [string]$PairRoot,
        [string]$ResolvedOutputRoot,
        [string]$Stamp
    )

    if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
        return [ordered]@{
            JsonPath = Join-Path $PairRoot "treatment_patch_completion_attempt.json"
            MarkdownPath = Join-Path $PairRoot "treatment_patch_completion_attempt.md"
        }
    }

    return [ordered]@{
        JsonPath = Join-Path $ResolvedOutputRoot ("treatment_patch_completion_attempt-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $ResolvedOutputRoot ("treatment_patch_completion_attempt-{0}.md" -f $Stamp)
    }
}

function Get-TreatmentPatchCompletionVerdict {
    param(
        [bool]$InterruptedAndRecovered,
        [bool]$TreatmentHumanUsable,
        [int]$MissingPatchEventsAfter,
        [bool]$TreatmentStrongSignalReadyAfter,
        [bool]$FirstStrongSignalConservativeCapture,
        [bool]$ManualReviewRequired
    )

    if ($InterruptedAndRecovered) {
        return "treatment-phase-interrupted-and-recovered"
    }

    if (-not $TreatmentHumanUsable) {
        return "treatment-phase-insufficient-human-signal"
    }

    if ($MissingPatchEventsAfter -le 0 -and $TreatmentStrongSignalReadyAfter -and $FirstStrongSignalConservativeCapture) {
        return "treatment-patch-target-met"
    }

    if ($MissingPatchEventsAfter -le 0 -and $TreatmentStrongSignalReadyAfter -and $ManualReviewRequired) {
        return "treatment-phase-manual-review-required"
    }

    if ($MissingPatchEventsAfter -gt 0) {
        return "treatment-patch-target-still-short"
    }

    return "treatment-phase-manual-review-required"
}

function Get-TreatmentPatchCompletionExplanation {
    param(
        [string]$Verdict,
        [int]$MissingPatchEventsBefore,
        [int]$MissingPatchEventsAfter,
        [bool]$ThirdPatchCaptured,
        [bool]$TreatmentStrongSignalReadyAfter,
        [bool]$FirstStrongSignalConservativeCapture,
        [string]$AttemptExplanation,
        [string]$GapExplanation
    )

    switch ($Verdict) {
        "treatment-patch-target-met" {
            return "The missing treatment-side patch target was completed in this run. Missing patch events moved from $MissingPatchEventsBefore to $MissingPatchEventsAfter, the third human-present patch was captured, treatment became strong-signal-ready, and the session produced the first strong-signal conservative evidence pack."
        }
        "treatment-phase-interrupted-and-recovered" {
            return "The treatment-patch completion run needed recovery handling before closeout completed. Treat the saved pair as recovered evidence rather than a clean direct patch-completion capture."
        }
        "treatment-phase-insufficient-human-signal" {
            if (-not [string]::IsNullOrWhiteSpace($AttemptExplanation)) {
                return "The treatment-patch completion run did not preserve enough treatment-side human signal to close the remaining strong-signal gap. $AttemptExplanation"
            }

            return "The treatment-patch completion run did not preserve enough treatment-side human signal to close the remaining strong-signal gap."
        }
        "treatment-patch-target-still-short" {
            return "The run kept treatment alive, but the missing third human-present patch was still not captured. Missing patch events moved from $MissingPatchEventsBefore to $MissingPatchEventsAfter. $GapExplanation"
        }
        default {
            if ($ThirdPatchCaptured -and $TreatmentStrongSignalReadyAfter -and -not $FirstStrongSignalConservativeCapture) {
                return "The missing third human-present patch was captured and treatment became strong-signal-ready, but the final strong-signal outcome still needs manual review before it can be treated as a clean first capture. $AttemptExplanation"
            }

            if (-not [string]::IsNullOrWhiteSpace($AttemptExplanation)) {
                return "Manual review is still required for the treatment-patch completion attempt. $AttemptExplanation"
            }

            return "Manual review is still required for the treatment-patch completion attempt."
        }
    }
}

function Get-TreatmentPatchCompletionMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Treatment Patch Completion Attempt") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Attempt verdict: $($Report.attempt_verdict)") | Out-Null
    $lines.Add("- Explanation: $($Report.explanation)") | Out-Null
    $lines.Add("- Mission path used: $($Report.mission_path_used)") | Out-Null
    $lines.Add("- Mission markdown path used: $($Report.mission_markdown_path_used)") | Out-Null
    $lines.Add("- Pair root: $($Report.pair_root)") | Out-Null
    $lines.Add("- Treatment profile used: $($Report.treatment_profile_used)") | Out-Null
    $lines.Add("- Control lane verdict: $($Report.control_lane_verdict)") | Out-Null
    $lines.Add("- Treatment lane verdict: $($Report.treatment_lane_verdict)") | Out-Null
    $lines.Add("- Pair classification: $($Report.pair_classification)") | Out-Null
    $lines.Add("- Certification verdict: $($Report.certification_verdict)") | Out-Null
    $lines.Add("- Counts toward promotion: $($Report.counts_toward_promotion)") | Out-Null
    $lines.Add("- Treatment behavior assessment: $($Report.treatment_behavior_assessment)") | Out-Null
    $lines.Add("- Missing patch events: $($Report.missing_patch_events_before) -> $($Report.missing_patch_events_after)") | Out-Null
    $lines.Add("- Third human-present patch captured: $($Report.third_human_present_patch_captured)") | Out-Null
    $lines.Add("- Treatment strong-signal-ready: $($Report.treatment_strong_signal_ready)") | Out-Null
    $lines.Add("- First strong-signal conservative capture: $($Report.first_strong_signal_conservative_capture)") | Out-Null
    $lines.Add("- Strong signal: $($Report.strong_signal_before) -> $($Report.strong_signal_after)") | Out-Null
    $lines.Add("- Grounded sessions: $($Report.grounded_sessions_before) -> $($Report.grounded_sessions_after)") | Out-Null
    $lines.Add("- Grounded too quiet: $($Report.grounded_too_quiet_before) -> $($Report.grounded_too_quiet_after)") | Out-Null
    $lines.Add("- Responsive gate: $($Report.responsive_gate_before) -> $($Report.responsive_gate_after)") | Out-Null
    $lines.Add("- Next live objective: $($Report.next_live_objective_before) -> $($Report.next_live_objective_after)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Treatment Target") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Treatment human snapshots: $($Report.treatment_human_snapshots.target) -> $($Report.treatment_human_snapshots.actual)") | Out-Null
    $lines.Add("- Treatment human presence seconds: $($Report.treatment_human_presence_seconds.target) -> $($Report.treatment_human_presence_seconds.actual)") | Out-Null
    $lines.Add("- Treatment human-present patch events: $($Report.treatment_human_present_patch_events.target) -> $($Report.treatment_human_present_patch_events.actual)") | Out-Null
    $lines.Add("- Post-patch observation seconds: $($Report.post_patch_observation_seconds.target) -> $($Report.post_patch_observation_seconds.actual)") | Out-Null
    $lines.Add("- First human-present patch timestamp: $($Report.patch_timeline.first_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("- Second human-present patch timestamp: $($Report.patch_timeline.second_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("- Third human-present patch timestamp: $($Report.patch_timeline.third_human_present_patch_timestamp_utc)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Guidance") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Treatment may leave phase: $($Report.treatment_phase_guidance.safe_to_leave_treatment)") | Out-Null
    $lines.Add("- Treatment guidance verdict: $($Report.treatment_phase_guidance.verdict_at_release)") | Out-Null
    $lines.Add("- Treatment guidance explanation: $($Report.treatment_phase_guidance.explanation)") | Out-Null
    $lines.Add("- Recommendation: $($Report.recommendation)") | Out-Null
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
$attemptStamp = Get-Date -Format "yyyyMMdd-HHmmss"

$missionArtifacts = Resolve-StrongSignalMissionArtifacts `
    -ExplicitMissionPath $MissionPath `
    -ExplicitMissionMarkdownPath $MissionMarkdownPath `
    -ResolvedLabRoot $resolvedLabRoot `
    -ResolvedEvalRoot (Get-EvalRootDefault -LabRoot $resolvedLabRoot)

$beforeAuditScriptPath = Join-Path $PSScriptRoot "audit_treatment_strong_signal_gap.ps1"
$beforeAuditResult = & $beforeAuditScriptPath -UseLatest -LabRoot $resolvedLabRoot -EvalRoot (Get-EvalRootDefault -LabRoot $resolvedLabRoot) -DryRun
$beforeAuditJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $beforeAuditResult -Name "TreatmentStrongSignalGapAuditJsonPath" -Default ""))
$beforeAudit = Read-JsonFile -Path $beforeAuditJsonPath
if ($null -eq $beforeAudit) {
    throw "The baseline treatment strong-signal gap audit could not be read."
}

$strongSignalAttemptScriptPath = Join-Path $PSScriptRoot "run_strong_signal_conservative_attempt.ps1"
$strongSignalAttemptArguments = [ordered]@{
    MissionPath = $missionArtifacts.JsonPath
    MissionMarkdownPath = $missionArtifacts.MarkdownPath
    LabRoot = $resolvedLabRoot
    OutputRoot = $resolvedEvalRoot
}
if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) {
    $strongSignalAttemptArguments.ClientExePath = (Get-AbsolutePath -Path $ClientExePath -BasePath $repoRoot)
}

$wrappedCommandParts = New-Object System.Collections.Generic.List[string]
$wrappedCommandParts.Add("powershell -NoProfile -ExecutionPolicy Bypass -File `"$strongSignalAttemptScriptPath`"") | Out-Null
foreach ($entry in $strongSignalAttemptArguments.GetEnumerator()) {
    $wrappedCommandParts.Add("-$($entry.Key) `"$($entry.Value)`"") | Out-Null
}
$wrappedCommand = $wrappedCommandParts -join " "

$strongSignalAttemptResult = & $strongSignalAttemptScriptPath @strongSignalAttemptArguments
$strongSignalAttemptJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $strongSignalAttemptResult -Name "StrongSignalConservativeAttemptJsonPath" -Default ""))
$strongSignalAttemptMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $strongSignalAttemptResult -Name "StrongSignalConservativeAttemptMarkdownPath" -Default ""))
$strongSignalAttemptReport = Read-JsonFile -Path $strongSignalAttemptJsonPath
if ($null -eq $strongSignalAttemptReport) {
    throw "The wrapped strong-signal conservative attempt report could not be read."
}

$pairRoot = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "pair_root" -Default ([string](Get-ObjectPropertyValue -Object $strongSignalAttemptResult -Name "PairRoot" -Default ""))))
if (-not $pairRoot) {
    throw "The treatment-patch completion attempt did not produce a pair root."
}

$afterAuditResult = & $beforeAuditScriptPath -PairRoot $pairRoot -DryRun
$afterAuditJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $afterAuditResult -Name "TreatmentStrongSignalGapAuditJsonPath" -Default ""))
$afterAudit = Read-JsonFile -Path $afterAuditJsonPath
if ($null -eq $afterAudit) {
    throw "The post-run treatment strong-signal gap audit could not be read."
}

$beforeGap = Get-ObjectPropertyValue -Object $beforeAudit -Name "treatment_gap" -Default $null
$afterGap = Get-ObjectPropertyValue -Object $afterAudit -Name "treatment_gap" -Default $null
$beforePatchTarget = [int](Get-ObjectPropertyValue -Object $beforeGap -Name "counted_human_present_patch_events_target" -Default 0)
$beforePatchActual = [int](Get-ObjectPropertyValue -Object $beforeGap -Name "counted_human_present_patch_events_actual" -Default 0)
$afterPatchTarget = [int](Get-ObjectPropertyValue -Object $afterGap -Name "counted_human_present_patch_events_target" -Default 0)
$afterPatchActual = [int](Get-ObjectPropertyValue -Object $afterGap -Name "counted_human_present_patch_events_actual" -Default 0)
$missingPatchEventsBefore = [Math]::Max(0, $beforePatchTarget - $beforePatchActual)
$missingPatchEventsAfter = [Math]::Max(0, $afterPatchTarget - $afterPatchActual)
$thirdPatchCaptured = $missingPatchEventsBefore -gt 0 -and $missingPatchEventsAfter -eq 0
$treatmentStrongSignalReadyAfter = [bool](Get-ObjectPropertyValue -Object $afterGap -Name "treatment_strong_signal_ready" -Default $false)
$treatmentGroundedReadyAfter = [bool](Get-ObjectPropertyValue -Object $afterGap -Name "treatment_grounded_ready" -Default $false)

$treatmentSnapshotsTarget = [int](Get-ObjectPropertyValue -Object $afterGap -Name "treatment_human_snapshots_target" -Default 0)
$treatmentSnapshotsActual = [int](Get-ObjectPropertyValue -Object $afterGap -Name "treatment_human_snapshots_actual" -Default 0)
$treatmentSecondsTarget = [double](Get-ObjectPropertyValue -Object $afterGap -Name "treatment_human_presence_seconds_target" -Default 0.0)
$treatmentSecondsActual = [double](Get-ObjectPropertyValue -Object $afterGap -Name "treatment_human_presence_seconds_actual" -Default 0.0)
$postPatchTarget = [double](Get-ObjectPropertyValue -Object $afterGap -Name "post_patch_observation_seconds_target" -Default 0.0)
$postPatchActual = [double](Get-ObjectPropertyValue -Object $afterGap -Name "post_patch_observation_seconds_actual" -Default 0.0)

$treatmentHumanUsable = $treatmentSnapshotsActual -gt 0 -or $treatmentSecondsActual -gt 0.0
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "counts_toward_promotion" -Default $false)
$certificationVerdict = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "certification_verdict" -Default "")
$strongSignalBefore = [int](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "strong_signal_before" -Default 0)
$strongSignalAfter = [int](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "strong_signal_after" -Default 0)
$firstStrongSignalConservativeCapture = $thirdPatchCaptured -and $treatmentStrongSignalReadyAfter -and $strongSignalBefore -eq 0 -and $strongSignalAfter -gt 0
$wrappedAttemptVerdict = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "attempt_verdict" -Default "")
$manualReviewRequired = $wrappedAttemptVerdict -eq "strong-signal-conservative-manual-review-required" -or $wrappedAttemptVerdict -eq "strong-signal-conservative-but-still-mixed"
$humanAttemptJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "artifacts" -Default $null) -Name "human_participation_conservative_attempt_json" -Default ""))
$humanAttemptReport = Read-JsonFile -Path $humanAttemptJsonPath
$finalRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $humanAttemptReport -Name "final_recovery_verdict" -Default "")
$interruptedAndRecovered = $finalRecoveryVerdict -like "*recover*"

$attemptVerdict = Get-TreatmentPatchCompletionVerdict `
    -InterruptedAndRecovered $interruptedAndRecovered `
    -TreatmentHumanUsable $treatmentHumanUsable `
    -MissingPatchEventsAfter $missingPatchEventsAfter `
    -TreatmentStrongSignalReadyAfter $treatmentStrongSignalReadyAfter `
    -FirstStrongSignalConservativeCapture $firstStrongSignalConservativeCapture `
    -ManualReviewRequired $manualReviewRequired

$recommendation = if ($firstStrongSignalConservativeCapture) {
    "review-first-strong-signal-conservative-capture"
}
elseif ($missingPatchEventsAfter -gt 0) {
    "keep-conservative-and-collect-one-more-stronger-treatment-window"
}
elseif ($manualReviewRequired) {
    "manual-review-needed"
}
else {
    "responsive-remains-blocked"
}

$explanation = Get-TreatmentPatchCompletionExplanation `
    -Verdict $attemptVerdict `
    -MissingPatchEventsBefore $missingPatchEventsBefore `
    -MissingPatchEventsAfter $missingPatchEventsAfter `
    -ThirdPatchCaptured $thirdPatchCaptured `
    -TreatmentStrongSignalReadyAfter $treatmentStrongSignalReadyAfter `
    -FirstStrongSignalConservativeCapture $firstStrongSignalConservativeCapture `
    -AttemptExplanation ([string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "explanation" -Default "")) `
    -GapExplanation ([string](Get-ObjectPropertyValue -Object $afterAudit -Name "explanation" -Default ""))

$treatmentPatchGuidance = Get-ObjectPropertyValue -Object $humanAttemptReport -Name "treatment_patch_guidance" -Default $null
$outputPaths = Get-ReportPaths -PairRoot $pairRoot -ResolvedOutputRoot $resolvedEvalRoot -Stamp $attemptStamp
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
    treatment_profile_used = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "treatment_profile_used" -Default "conservative")
    control_lane_verdict = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "control_lane_verdict" -Default "")
    treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "treatment_lane_verdict" -Default "")
    pair_classification = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "pair_classification" -Default "")
    certification_verdict = $certificationVerdict
    counts_toward_promotion = $countsTowardPromotion
    treatment_behavior_assessment = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "treatment_behavior_assessment" -Default "")
    treatment_human_snapshots = [ordered]@{
        target = $treatmentSnapshotsTarget
        actual = $treatmentSnapshotsActual
    }
    treatment_human_presence_seconds = [ordered]@{
        target = $treatmentSecondsTarget
        actual = $treatmentSecondsActual
    }
    treatment_human_present_patch_events = [ordered]@{
        target = $afterPatchTarget
        actual = $afterPatchActual
    }
    treatment_human_present_patch_count_before_this_run = $beforePatchActual
    treatment_human_present_patch_count_after_this_run = $afterPatchActual
    missing_patch_events_before = $missingPatchEventsBefore
    missing_patch_events_after = $missingPatchEventsAfter
    third_human_present_patch_captured = $thirdPatchCaptured
    post_patch_observation_seconds = [ordered]@{
        target = $postPatchTarget
        actual = $postPatchActual
    }
    treatment_grounded_ready = $treatmentGroundedReadyAfter
    treatment_strong_signal_ready = $treatmentStrongSignalReadyAfter
    first_strong_signal_conservative_capture = $firstStrongSignalConservativeCapture
    strong_signal_before = $strongSignalBefore
    strong_signal_after = $strongSignalAfter
    grounded_sessions_before = [int](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "grounded_sessions_before" -Default 0)
    grounded_sessions_after = [int](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "grounded_sessions_after" -Default 0)
    grounded_too_quiet_before = [int](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "grounded_too_quiet_before" -Default 0)
    grounded_too_quiet_after = [int](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "grounded_too_quiet_after" -Default 0)
    responsive_gate_before = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "responsive_gate_before" -Default "")
    responsive_gate_after = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "responsive_gate_after" -Default "")
    next_live_objective_before = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "next_live_objective_before" -Default "")
    next_live_objective_after = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "next_live_objective_after" -Default "")
    recommendation = $recommendation
    treatment_phase_guidance = [ordered]@{
        verdict_at_release = [string](Get-ObjectPropertyValue -Object $treatmentPatchGuidance -Name "verdict_at_release" -Default "")
        safe_to_leave_treatment = [bool](Get-ObjectPropertyValue -Object $treatmentPatchGuidance -Name "safe_to_leave_treatment" -Default $false)
        explanation = [string](Get-ObjectPropertyValue -Object $treatmentPatchGuidance -Name "explanation" -Default "")
    }
    patch_timeline = [ordered]@{
        first_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $afterGap -Name "first_human_present_patch_timestamp_utc" -Default "")
        second_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $afterGap -Name "second_human_present_patch_timestamp_utc" -Default "")
        third_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object $afterGap -Name "third_human_present_patch_timestamp_utc" -Default "")
        first_patch_apply_during_human_window_timestamp_utc = [string](Get-ObjectPropertyValue -Object $afterGap -Name "first_patch_apply_during_human_window_timestamp_utc" -Default "")
    }
    wrapped_attempt = [ordered]@{
        attempt_verdict = $wrappedAttemptVerdict
        explanation = [string](Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "explanation" -Default "")
        wrapped_command = $wrappedCommand
        strong_signal_conservative_attempt_json = $strongSignalAttemptJsonPath
        strong_signal_conservative_attempt_markdown = $strongSignalAttemptMarkdownPath
    }
    audits = [ordered]@{
        treatment_gap_before_json = $beforeAuditJsonPath
        treatment_gap_after_json = $afterAuditJsonPath
    }
    reused_stack = [ordered]@{
        strong_signal_conservative_attempt = $true
        human_participation_conservative_attempt = $true
        mission_driven_runner = $true
        control_first_guidance = $true
        treatment_hold_guidance = $true
        live_monitor = $true
        grounded_evidence_certificate = $true
        mission_attainment = $true
        session_outcome_dossier = $true
        grounded_evidence_matrix = $true
        responsive_trial_gate = $true
        next_live_planner = $true
    }
    artifacts = [ordered]@{
        treatment_patch_completion_attempt_json = $outputPaths.JsonPath
        treatment_patch_completion_attempt_markdown = $outputPaths.MarkdownPath
        strong_signal_conservative_attempt_json = $strongSignalAttemptJsonPath
        strong_signal_conservative_attempt_markdown = $strongSignalAttemptMarkdownPath
        human_participation_conservative_attempt_json = $humanAttemptJsonPath
        human_participation_conservative_attempt_markdown = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "artifacts" -Default $null) -Name "human_participation_conservative_attempt_markdown" -Default ""))
        pair_summary_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "artifacts" -Default $null) -Name "pair_summary_json" -Default ""))
        grounded_evidence_certificate_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "artifacts" -Default $null) -Name "grounded_evidence_certificate_json" -Default ""))
        session_outcome_dossier_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "artifacts" -Default $null) -Name "session_outcome_dossier_json" -Default ""))
        mission_attainment_json = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $strongSignalAttemptReport -Name "artifacts" -Default $null) -Name "mission_attainment_json" -Default ""))
        treatment_strong_signal_gap_audit_before_json = $beforeAuditJsonPath
        treatment_strong_signal_gap_after_json = $afterAuditJsonPath
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-TreatmentPatchCompletionMarkdown -Report $reportForMarkdown)

Write-Host "Treatment patch completion attempt:"
Write-Host "  Attempt verdict: $($report.attempt_verdict)"
Write-Host "  Pair root: $($report.pair_root)"
Write-Host "  Missing patch events: $($report.missing_patch_events_before) -> $($report.missing_patch_events_after)"
Write-Host "  Third human-present patch captured: $($report.third_human_present_patch_captured)"
Write-Host "  Treatment strong-signal-ready: $($report.treatment_strong_signal_ready)"
Write-Host "  First strong-signal conservative capture: $($report.first_strong_signal_conservative_capture)"
Write-Host "  Attempt report JSON: $($outputPaths.JsonPath)"
Write-Host "  Attempt report Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $pairRoot
    TreatmentPatchCompletionAttemptJsonPath = $outputPaths.JsonPath
    TreatmentPatchCompletionAttemptMarkdownPath = $outputPaths.MarkdownPath
    AttemptVerdict = $report.attempt_verdict
    ThirdHumanPresentPatchCaptured = $report.third_human_present_patch_captured
    TreatmentStrongSignalReady = $report.treatment_strong_signal_ready
    FirstStrongSignalConservativeCapture = $report.first_strong_signal_conservative_capture
}
