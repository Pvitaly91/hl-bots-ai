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

function Invoke-HelperScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    & $ScriptPath @Arguments | Out-Null
}

function Get-UniqueStringList {
    param([string[]]$Items)

    $result = @()
    foreach ($item in @($Items)) {
        $value = [string]$item
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($result -notcontains $value) {
            $result += $value
        }
    }

    return @($result)
}

function Format-DisplayValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [int] -or $Value -is [long]) {
        return [string]$Value
    }

    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", [double]$Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return (@($Value) | ForEach-Object { Format-DisplayValue -Value $_ }) -join ", "
    }

    return [string]$Value
}

function New-NumericTargetResult {
    param(
        [string]$Key,
        [string]$Label,
        [double]$TargetValue,
        [double]$ActualValue,
        [string]$Unit = "",
        [string]$Comparison = "at-least"
    )

    $met = switch ($Comparison) {
        "exactly" { [double]$ActualValue -eq [double]$TargetValue }
        default { [double]$ActualValue -ge [double]$TargetValue }
    }

    $targetText = if ([string]::IsNullOrWhiteSpace($Unit)) {
        Format-DisplayValue -Value $TargetValue
    }
    else {
        "{0} {1}" -f (Format-DisplayValue -Value $TargetValue), $Unit
    }

    $actualText = if ([string]::IsNullOrWhiteSpace($Unit)) {
        Format-DisplayValue -Value $ActualValue
    }
    else {
        "{0} {1}" -f (Format-DisplayValue -Value $ActualValue), $Unit
    }

    $explanation = if ($met) {
        ""
    }
    else {
        switch ($Comparison) {
            "exactly" {
                "{0} needed exactly {1}, but the session produced {2}." -f $Label, $targetText, $actualText
            }
            default {
                "{0} needed at least {1}, but the session produced {2}." -f $Label, $targetText, $actualText
            }
        }
    }

    return [ordered]@{
        key = $Key
        label = $Label
        target_value = $TargetValue
        actual_value = $ActualValue
        met = $met
        explanation = $explanation
    }
}

function New-BooleanTargetResult {
    param(
        [string]$Key,
        [string]$Label,
        [bool]$TargetValue,
        [bool]$ActualValue,
        [string]$FailureExplanation
    )

    $met = if ($TargetValue) { $ActualValue } else { $true }
    $explanation = if ($met) { "" } elseif (-not [string]::IsNullOrWhiteSpace($FailureExplanation)) { $FailureExplanation } else { "$Label was required, but the session did not satisfy it." }

    return [ordered]@{
        key = $Key
        label = $Label
        target_value = $TargetValue
        actual_value = $ActualValue
        met = $met
        explanation = $explanation
    }
}

function Resolve-MissionBriefPaths {
    param(
        [string]$ResolvedPairRoot,
        [object]$GuidedDocket
    )

    $jsonCandidates = @(
        (Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.json"),
        [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $GuidedDocket -Name "artifacts" -Default $null) -Name "mission_snapshot_json" -Default ""),
        [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $GuidedDocket -Name "artifacts" -Default $null) -Name "mission_brief_json" -Default ""),
        (Join-Path $ResolvedPairRoot "mission\next_live_session_mission.json"),
        (Join-Path $ResolvedPairRoot "next_live_session_mission.json")
    )
    $markdownCandidates = @(
        (Join-Path $ResolvedPairRoot "guided_session\mission\next_live_session_mission.md"),
        [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $GuidedDocket -Name "artifacts" -Default $null) -Name "mission_snapshot_markdown" -Default ""),
        [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $GuidedDocket -Name "artifacts" -Default $null) -Name "mission_brief_markdown" -Default ""),
        (Join-Path $ResolvedPairRoot "mission\next_live_session_mission.md"),
        (Join-Path $ResolvedPairRoot "next_live_session_mission.md")
    )

    $checkedJsonPaths = @()
    $resolvedJsonPath = ""
    foreach ($candidate in Get-UniqueStringList -Items $jsonCandidates) {
        $checkedJsonPaths += $candidate
        $resolvedCandidate = Resolve-ExistingPath -Path $candidate
        if ($resolvedCandidate) {
            $resolvedJsonPath = $resolvedCandidate
            break
        }
    }

    if (-not $resolvedJsonPath) {
        throw ("No associated mission brief was found for pair root '{0}'. Checked: {1}" -f $ResolvedPairRoot, ($checkedJsonPaths -join "; "))
    }

    $resolvedMarkdownPath = ""
    foreach ($candidate in Get-UniqueStringList -Items $markdownCandidates) {
        $resolvedCandidate = Resolve-ExistingPath -Path $candidate
        if ($resolvedCandidate) {
            $resolvedMarkdownPath = $resolvedCandidate
            break
        }
    }

    return [ordered]@{
        json_path = $resolvedJsonPath
        markdown_path = $resolvedMarkdownPath
    }
}

function Ensure-LiveMonitorStatus {
    param(
        [string]$ResolvedPairRoot,
        [object]$Mission,
        [string]$ResolvedLabRoot,
        [string]$ResolvedPairsRoot
    )

    $monitorStatusJsonPath = Join-Path $ResolvedPairRoot "live_monitor_status.json"
    $monitorStatusMarkdownPath = Join-Path $ResolvedPairRoot "live_monitor_status.md"
    $monitorStatus = Read-JsonFile -Path $monitorStatusJsonPath
    $reranMonitor = $false

    $missionThresholds = [ordered]@{
        min_control_human_snapshots = [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_snapshots" -Default 0)
        min_control_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_control_human_presence_seconds" -Default 0.0)
        min_treatment_human_snapshots = [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_snapshots" -Default 0)
        min_treatment_human_presence_seconds = [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0.0)
        min_treatment_patch_events_while_humans_present = [int](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default 0)
        min_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object $Mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0.0)
    }

    $thresholdMismatch = $false
    if ($null -ne $monitorStatus) {
        $existingThresholds = Get-ObjectPropertyValue -Object $monitorStatus -Name "thresholds" -Default $null
        foreach ($entry in $missionThresholds.GetEnumerator()) {
            $existingValue = Get-ObjectPropertyValue -Object $existingThresholds -Name $entry.Key -Default $null
            if ($null -eq $existingValue) {
                $thresholdMismatch = $true
                break
            }

            if ([math]::Abs([double]$existingValue - [double]$entry.Value) -gt 0.001) {
                $thresholdMismatch = $true
                break
            }
        }
    }

    if ($null -eq $monitorStatus -or $thresholdMismatch) {
        $monitorScriptPath = Join-Path $PSScriptRoot "monitor_live_pair_session.ps1"
        $monitorArgs = @{
            PairRoot = $ResolvedPairRoot
            Once = $true
            MinControlHumanSnapshots = $missionThresholds.min_control_human_snapshots
            MinControlHumanPresenceSeconds = $missionThresholds.min_control_human_presence_seconds
            MinTreatmentHumanSnapshots = $missionThresholds.min_treatment_human_snapshots
            MinTreatmentHumanPresenceSeconds = $missionThresholds.min_treatment_human_presence_seconds
            MinTreatmentPatchEventsWhileHumansPresent = $missionThresholds.min_treatment_patch_events_while_humans_present
            MinPostPatchObservationSeconds = $missionThresholds.min_post_patch_observation_seconds
        }
        if (-not [string]::IsNullOrWhiteSpace($ResolvedLabRoot)) {
            $monitorArgs.LabRoot = $ResolvedLabRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($ResolvedPairsRoot)) {
            $monitorArgs.PairsRoot = $ResolvedPairsRoot
        }

        Invoke-HelperScript -ScriptPath $monitorScriptPath -Arguments $monitorArgs
        $monitorStatus = Read-JsonFile -Path $monitorStatusJsonPath
        $reranMonitor = $true
    }

    if ($null -eq $monitorStatus) {
        throw "Live monitor status was not available for pair root: $ResolvedPairRoot"
    }

    return [ordered]@{
        status = $monitorStatus
        json_path = $monitorStatusJsonPath
        markdown_path = $monitorStatusMarkdownPath
        reran_monitor = $reranMonitor
    }
}

function Ensure-OutcomeDossier {
    param(
        [string]$ResolvedPairRoot,
        [string]$ResolvedLabRoot,
        [string]$ResolvedPairsRoot,
        [string]$ResolvedRegistryPath
    )

    $dossierScriptPath = Join-Path $PSScriptRoot "build_latest_session_outcome_dossier.ps1"
    $dossierArgs = @{
        PairRoot = $ResolvedPairRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ResolvedLabRoot)) {
        $dossierArgs.LabRoot = $ResolvedLabRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ResolvedPairsRoot)) {
        $dossierArgs.PairsRoot = $ResolvedPairsRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ResolvedRegistryPath)) {
        $dossierArgs.RegistryPath = $ResolvedRegistryPath
    }

    Invoke-HelperScript -ScriptPath $dossierScriptPath -Arguments $dossierArgs

    $dossierJsonPath = Join-Path $ResolvedPairRoot "session_outcome_dossier.json"
    $dossierMarkdownPath = Join-Path $ResolvedPairRoot "session_outcome_dossier.md"
    $dossier = Read-JsonFile -Path $dossierJsonPath
    if ($null -eq $dossier) {
        throw "Session outcome dossier was not available for pair root: $ResolvedPairRoot"
    }

    return [ordered]@{
        dossier = $dossier
        json_path = $dossierJsonPath
        markdown_path = $dossierMarkdownPath
    }
}

function Get-MissedTargetItems {
    param([object]$TargetResults)

    return @(
        @($TargetResults.GetEnumerator()) |
            ForEach-Object { $_.Value } |
            Where-Object { -not [bool](Get-ObjectPropertyValue -Object $_ -Name "met" -Default $false) }
    )
}

function Get-MetTargetItems {
    param([object]$TargetResults)

    return @(
        @($TargetResults.GetEnumerator()) |
            ForEach-Object { $_.Value } |
            Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "met" -Default $false) }
    )
}

function Get-MissionVerdict {
    param(
        [object]$TargetResults,
        [object]$Certificate,
        [object]$Scorecard,
        [object]$Dossier,
        [object]$MonitorStatus
    )

    $missionOperationalSuccess = [bool](Get-ObjectPropertyValue -Object $TargetResults.live_monitor_sufficient_verdict -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.control_minimum_human_snapshots -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.control_minimum_human_presence_seconds -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.treatment_minimum_human_snapshots -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.treatment_minimum_human_presence_seconds -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.treatment_minimum_patch_while_human_present_events -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.minimum_post_patch_observation_window_seconds -Name "met" -Default $false)

    $missionGroundedSuccess = $missionOperationalSuccess -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.success_requires_grounded_certification -Name "met" -Default $false) -and
        [bool](Get-ObjectPropertyValue -Object $TargetResults.success_requires_counts_toward_promotion -Name "met" -Default $false)

    $whatChanged = Get-ObjectPropertyValue -Object $Dossier -Name "what_changed_because_of_this_session" -Default $null
    $nextObjectiveChanged = [bool](Get-ObjectPropertyValue -Object $whatChanged -Name "changed_next_objective" -Default $false)
    $responsiveGateChanged = [bool](Get-ObjectPropertyValue -Object $whatChanged -Name "changed_responsive_gate" -Default $false)
    $reducedPromotionGap = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Dossier -Name "promotion_gap_delta_summary" -Default $null) -Name "reduced_promotion_gap" -Default $false)
    $missionPromotionImpact = $missionGroundedSuccess -and ($reducedPromotionGap -or $nextObjectiveChanged -or $responsiveGateChanged)

    $manualReviewNeeded = [bool](Get-ObjectPropertyValue -Object $Certificate -Name "manual_review_needed" -Default $false) -or
        [string](Get-ObjectPropertyValue -Object $Scorecard -Name "recommendation" -Default "") -eq "manual-review-needed" -or
        [bool](Get-ObjectPropertyValue -Object $Certificate -Name "manual_review_needed" -Default $false)

    $missedTargets = Get-MissedTargetItems -TargetResults $TargetResults
    $missedOperationalTargets = @(
        $missedTargets | Where-Object {
            [string](Get-ObjectPropertyValue -Object $_ -Name "key" -Default "") -in @(
                "live_monitor_sufficient_verdict",
                "control_minimum_human_snapshots",
                "control_minimum_human_presence_seconds",
                "treatment_minimum_human_snapshots",
                "treatment_minimum_human_presence_seconds",
                "treatment_minimum_patch_while_human_present_events",
                "minimum_post_patch_observation_window_seconds"
            )
        }
    )

    $evidenceOrigin = [string](Get-ObjectPropertyValue -Object $Certificate -Name "evidence_origin" -Default "")
    $countsOnlyAsWorkflowValidation = [bool](Get-ObjectPropertyValue -Object $Certificate -Name "counts_only_as_workflow_validation" -Default $false)
    $exclusionReasons = @((Get-ObjectPropertyValue -Object $Certificate -Name "exclusion_reasons" -Default @()))
    $originOnlyExclusions = @("evidence-origin-rehearsal", "evidence-origin-synthetic", "evidence-origin-not-live", "rehearsal-mode", "synthetic-evidence", "workflow-validation-only")
    $blockedOnlyByOrigin = @($exclusionReasons | Where-Object { $_ -notin $originOnlyExclusions }).Count -eq 0 -and @($exclusionReasons).Count -gt 0

    $verdict = ""
    if ($manualReviewNeeded) {
        $verdict = "manual-review-needed"
    }
    elseif ([string](Get-ObjectPropertyValue -Object $MonitorStatus -Name "phase" -Default "") -eq "waiting") {
        $verdict = "mission-not-attempted"
    }
    elseif (-not $missionOperationalSuccess) {
        $verdict = "mission-failed-insufficient-signal"
    }
    elseif (-not $missionGroundedSuccess) {
        if ($countsOnlyAsWorkflowValidation -or $blockedOnlyByOrigin -or $evidenceOrigin -in @("rehearsal", "synthetic")) {
            $verdict = "mission-met-but-no-promotion-impact"
        }
        else {
            $verdict = "mission-failed-no-grounded-certification"
        }
    }
    elseif ($missionPromotionImpact) {
        if ($nextObjectiveChanged -or $responsiveGateChanged) {
            $verdict = "mission-met-and-next-objective-advanced"
        }
        else {
            $verdict = "mission-met-and-gap-reduced"
        }
    }
    else {
        $verdict = "mission-met-but-no-promotion-impact"
    }

    $explanation = switch ($verdict) {
        "manual-review-needed" {
            "Mission closeout stays manual-review-needed because the post-session review stack still requires human judgment before promotion conclusions can be trusted."
        }
        "mission-not-attempted" {
            "The pair did not reach a completed mission-evaluation state, so there is no honest attainment verdict yet."
        }
        "mission-failed-insufficient-signal" {
            $missedDescriptions = @($missedOperationalTargets | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "explanation" -Default "") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($missedDescriptions.Count -gt 0) {
                "Mission failed before grounded promotion review because " + ($missedDescriptions -join " ")
            }
            else {
                "Mission failed before grounded promotion review because the session did not clear the required operational evidence thresholds."
            }
        }
        "mission-partially-met" {
            $missedDescriptions = @($missedTargets | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "explanation" -Default "") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            "The session met some mission targets but still missed: " + ($missedDescriptions -join " ")
        }
        "mission-failed-no-grounded-certification" {
            [string](Get-ObjectPropertyValue -Object $Certificate -Name "explanation" -Default "Operational targets were met, but the session still failed grounded certification.")
        }
        "mission-met-but-no-promotion-impact" {
            $baseExplanation = [string](Get-ObjectPropertyValue -Object $Dossier -Name "explanation" -Default "")
            if ($countsOnlyAsWorkflowValidation -or $evidenceOrigin -in @("rehearsal", "synthetic")) {
                $certificateExplanation = [string](Get-ObjectPropertyValue -Object $Certificate -Name "explanation" -Default "")
                if (-not [string]::IsNullOrWhiteSpace($certificateExplanation)) {
                    "The session met the monitor-facing mission targets, but it still does not count in the promotion ledger. $certificateExplanation"
                }
                else {
                    "The session met the monitor-facing mission targets, but it still does not count in the promotion ledger."
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($baseExplanation)) {
                $baseExplanation
            }
            else {
                "The session met the mission thresholds and counted as grounded evidence, but it did not change the promotion gap, responsive gate, or next objective."
            }
        }
        "mission-met-and-gap-reduced" {
            $currentObjective = [string](Get-ObjectPropertyValue -Object $Dossier -Name "current_next_live_objective" -Default "")
            "The session met the mission thresholds, counted as grounded evidence, and reduced the promotion gap while the next objective remains '$currentObjective'."
        }
        "mission-met-and-next-objective-advanced" {
            $beforeObjective = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Dossier -Name "before_vs_after_summary" -Default $null).next_live_objective -Name "before" -Default "")
            $afterObjective = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $Dossier -Name "before_vs_after_summary" -Default $null).next_live_objective -Name "after" -Default "")
            "The session met the mission thresholds, counted as grounded evidence, and advanced the next objective from '$beforeObjective' to '$afterObjective'."
        }
        default {
            [string](Get-ObjectPropertyValue -Object $Dossier -Name "explanation" -Default "")
        }
    }

    return [ordered]@{
        verdict = $verdict
        explanation = $explanation
        mission_operational_success = $missionOperationalSuccess
        mission_grounded_success = $missionGroundedSuccess
        mission_promotion_impact = $missionPromotionImpact
        next_objective_changed = $nextObjectiveChanged
        responsive_gate_changed = $responsiveGateChanged
        reduced_promotion_gap = $reducedPromotionGap
    }
}

function Get-MissionAttainmentMarkdown {
    param([object]$MissionAttainment)

    $targetLines = @(
        "| Target | Target Value | Actual Value | Met | Notes |",
        "| --- | --- | --- | --- | --- |"
    )

    foreach ($property in @($MissionAttainment.target_results.PSObject.Properties)) {
        $result = $property.Value
        $targetLines += ("| {0} | {1} | {2} | {3} | {4} |" -f
            [string](Get-ObjectPropertyValue -Object $result -Name "label" -Default ""),
            (Format-DisplayValue -Value (Get-ObjectPropertyValue -Object $result -Name "target_value" -Default $null)),
            (Format-DisplayValue -Value (Get-ObjectPropertyValue -Object $result -Name "actual_value" -Default $null)),
            ([bool](Get-ObjectPropertyValue -Object $result -Name "met" -Default $false)).ToString().ToLowerInvariant(),
            ([string](Get-ObjectPropertyValue -Object $result -Name "explanation" -Default "") -replace '\|', '\|')
        )
    }

    $lines = @(
        "# Session Mission Attainment",
        "",
        "- Pair root: $($MissionAttainment.pair_root)",
        "- Mission brief path used: $($MissionAttainment.mission_brief_path_used)",
        "- Evidence origin: $($MissionAttainment.evidence_origin)",
        "- Treatment profile used: $($MissionAttainment.treatment_profile_used)",
        "- Current certification verdict: $($MissionAttainment.current_certification_verdict)",
        "- Counts toward promotion: $($MissionAttainment.counts_toward_promotion)",
        "- Mission verdict: $($MissionAttainment.mission_verdict)",
        "- Mission operational success: $($MissionAttainment.mission_operational_success)",
        "- Mission grounded success: $($MissionAttainment.mission_grounded_success)",
        "- Mission promotion impact: $($MissionAttainment.mission_promotion_impact)",
        "- Explanation: $($MissionAttainment.explanation)",
        "",
        "## Targets Met",
        ""
    )

    if (@($MissionAttainment.targets_met).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($item in @($MissionAttainment.targets_met)) {
            $lines += "- $item"
        }
    }

    $lines += @(
        "",
        "## Targets Missed",
        ""
    )

    if (@($MissionAttainment.targets_missed).Count -eq 0) {
        $lines += "- none"
    }
    else {
        foreach ($item in @($MissionAttainment.targets_missed)) {
            $lines += "- $item"
        }
    }

    $lines += @(
        "",
        "## Target Vs Actual",
        ""
    )
    $lines += $targetLines
    $lines += @(
        "",
        "## Promotion Impact",
        "",
        "- Grounded sessions delta: $($MissionAttainment.grounded_sessions_delta)",
        "- Grounded too-quiet delta: $($MissionAttainment.grounded_too_quiet_delta)",
        "- Strong-signal delta: $($MissionAttainment.strong_signal_delta)",
        "- Responsive overreaction blockers delta: $($MissionAttainment.responsive_overreaction_blockers_delta)",
        "- Reduced promotion gap: $($MissionAttainment.reduced_promotion_gap)",
        "- Next objective changed: $($MissionAttainment.next_objective_changed)",
        "- Responsive gate changed: $($MissionAttainment.responsive_gate_changed)",
        "- Current next objective: $($MissionAttainment.next_mission.objective)",
        "- Recommended next live action: $($MissionAttainment.next_mission.recommended_next_live_action)",
        "",
        "## Artifacts",
        "",
        "- Live monitor JSON: $($MissionAttainment.artifacts.live_monitor_status_json)",
        "- Scorecard JSON: $($MissionAttainment.artifacts.scorecard_json)",
        "- Grounded evidence certificate JSON: $($MissionAttainment.artifacts.grounded_evidence_certificate_json)",
        "- Session outcome dossier JSON: $($MissionAttainment.artifacts.session_outcome_dossier_json)",
        "- Mission attainment JSON: $($MissionAttainment.artifacts.mission_attainment_json)",
        "- Mission attainment Markdown: $($MissionAttainment.artifacts.mission_attainment_markdown)"
    )

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

$outputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJson)) {
    Join-Path $resolvedPairRoot "mission_attainment.json"
}
else {
    Get-AbsolutePath -Path $OutputJson -BasePath $resolvedPairRoot
}
$outputMarkdownPath = if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    Join-Path $resolvedPairRoot "mission_attainment.md"
}
else {
    Get-AbsolutePath -Path $OutputMarkdown -BasePath $resolvedPairRoot
}

$guidedDocketPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "guided_session\final_session_docket.json")
$guidedDocket = Read-JsonFile -Path $guidedDocketPath
$missionPaths = Resolve-MissionBriefPaths -ResolvedPairRoot $resolvedPairRoot -GuidedDocket $guidedDocket
$mission = Read-JsonFile -Path $missionPaths.json_path
if ($null -eq $mission) {
    throw "Mission brief could not be parsed: $($missionPaths.json_path)"
}

$monitorInfo = Ensure-LiveMonitorStatus -ResolvedPairRoot $resolvedPairRoot -Mission $mission -ResolvedLabRoot $resolvedLabRoot -ResolvedPairsRoot $resolvedPairsRoot
$dossierInfo = Ensure-OutcomeDossier -ResolvedPairRoot $resolvedPairRoot -ResolvedLabRoot $resolvedLabRoot -ResolvedPairsRoot $resolvedPairsRoot -ResolvedRegistryPath $resolvedRegistryPath

$monitorStatus = $monitorInfo.status
$dossier = $dossierInfo.dossier
$certificatePath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "grounded_evidence_certificate.json")
$scorecardPath = Resolve-ExistingPath -Path (Join-Path $resolvedPairRoot "scorecard.json")
$certificate = Read-JsonFile -Path $certificatePath
$scorecard = Read-JsonFile -Path $scorecardPath

if ($null -eq $certificate) {
    throw "Grounded evidence certificate was not available for pair root: $resolvedPairRoot"
}
if ($null -eq $scorecard) {
    throw "Scorecard was not available for pair root: $resolvedPairRoot"
}

$requiredSufficientVerdicts = @((Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "exact_stop_condition" -Default $null) -Name "stop_only_when_live_monitor_verdict_in" -Default @()))
$currentMonitorVerdict = [string](Get-ObjectPropertyValue -Object $monitorStatus -Name "current_verdict" -Default "")
$liveMonitorSufficient = $requiredSufficientVerdicts -contains $currentMonitorVerdict

$targetResults = [ordered]@{
    live_monitor_sufficient_verdict = New-BooleanTargetResult `
        -Key "live_monitor_sufficient_verdict" `
        -Label "live monitor sufficient verdict" `
        -TargetValue ([bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "grounded_session_success_criteria" -Default $null) -Name "success_requires_live_monitor_sufficient_verdict" -Default $true)) `
        -ActualValue $liveMonitorSufficient `
        -FailureExplanation ("The live monitor needed one of [{0}], but the session ended at '{1}'." -f ($requiredSufficientVerdicts -join ", "), $currentMonitorVerdict)
    control_minimum_human_snapshots = New-NumericTargetResult `
        -Key "control_minimum_human_snapshots" `
        -Label "control minimum human snapshots" `
        -TargetValue ([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_snapshots" -Default 0)) `
        -ActualValue ([double](Get-ObjectPropertyValue -Object $monitorStatus -Name "control_human_snapshots_count" -Default 0))
    control_minimum_human_presence_seconds = New-NumericTargetResult `
        -Key "control_minimum_human_presence_seconds" `
        -Label "control minimum human presence seconds" `
        -TargetValue ([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_presence_seconds" -Default 0.0)) `
        -ActualValue ([double](Get-ObjectPropertyValue -Object $monitorStatus -Name "control_human_presence_seconds" -Default 0.0)) `
        -Unit "seconds"
    treatment_minimum_human_snapshots = New-NumericTargetResult `
        -Key "treatment_minimum_human_snapshots" `
        -Label "treatment minimum human snapshots" `
        -TargetValue ([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_snapshots" -Default 0)) `
        -ActualValue ([double](Get-ObjectPropertyValue -Object $monitorStatus -Name "treatment_human_snapshots_count" -Default 0))
    treatment_minimum_human_presence_seconds = New-NumericTargetResult `
        -Key "treatment_minimum_human_presence_seconds" `
        -Label "treatment minimum human presence seconds" `
        -TargetValue ([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_presence_seconds" -Default 0.0)) `
        -ActualValue ([double](Get-ObjectPropertyValue -Object $monitorStatus -Name "treatment_human_presence_seconds" -Default 0.0)) `
        -Unit "seconds"
    treatment_minimum_patch_while_human_present_events = New-NumericTargetResult `
        -Key "treatment_minimum_patch_while_human_present_events" `
        -Label "treatment minimum patch-while-human-present events" `
        -TargetValue ([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default 0)) `
        -ActualValue ([double](Get-ObjectPropertyValue -Object $monitorStatus -Name "treatment_patch_events_while_humans_present" -Default 0))
    minimum_post_patch_observation_window_seconds = New-NumericTargetResult `
        -Key "minimum_post_patch_observation_window_seconds" `
        -Label "minimum post-patch observation window" `
        -TargetValue ([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0.0)) `
        -ActualValue ([double](Get-ObjectPropertyValue -Object $monitorStatus -Name "meaningful_post_patch_observation_seconds" -Default 0.0)) `
        -Unit "seconds"
    success_requires_grounded_certification = New-BooleanTargetResult `
        -Key "success_requires_grounded_certification" `
        -Label "success_requires_grounded_certification" `
        -TargetValue ([bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "grounded_session_success_criteria" -Default $null) -Name "success_requires_grounded_certification" -Default $true)) `
        -ActualValue ([bool](Get-ObjectPropertyValue -Object $certificate -Name "certified_grounded_evidence" -Default $false)) `
        -FailureExplanation ([string](Get-ObjectPropertyValue -Object $certificate -Name "explanation" -Default "Grounded certification was required but the session did not earn it."))
    success_requires_counts_toward_promotion = New-BooleanTargetResult `
        -Key "success_requires_counts_toward_promotion" `
        -Label "success_requires_counts_toward_promotion" `
        -TargetValue ([bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "grounded_session_success_criteria" -Default $null) -Name "success_requires_counts_toward_promotion" -Default $true)) `
        -ActualValue ([bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)) `
        -FailureExplanation ("Mission success required promotion-counting grounded evidence, but the session stayed outside the promotion ledger: {0}" -f ([string](Get-ObjectPropertyValue -Object $certificate -Name "explanation" -Default "")))
}

$verdictInfo = Get-MissionVerdict -TargetResults $targetResults -Certificate $certificate -Scorecard $scorecard -Dossier $dossier -MonitorStatus $monitorStatus
$metTargetItems = Get-MetTargetItems -TargetResults $targetResults
$missedTargetItems = Get-MissedTargetItems -TargetResults $targetResults
$whatChanged = Get-ObjectPropertyValue -Object $dossier -Name "what_changed_because_of_this_session" -Default $null
$promotionGapDeltaSummary = Get-ObjectPropertyValue -Object $dossier -Name "promotion_gap_delta_summary" -Default $null
$beforeVsAfterSummary = Get-ObjectPropertyValue -Object $dossier -Name "before_vs_after_summary" -Default $null

$missionAttainment = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    selection_mode = $selectionMode
    pair_root = $resolvedPairRoot
    mission_brief_path_used = $missionPaths.json_path
    mission_brief_markdown_path_used = $missionPaths.markdown_path
    evidence_origin = [string](Get-ObjectPropertyValue -Object $certificate -Name "evidence_origin" -Default (Get-ObjectPropertyValue -Object $dossier -Name "evidence_origin" -Default ""))
    treatment_profile_used = [string](Get-ObjectPropertyValue -Object $dossier -Name "treatment_profile" -Default "")
    current_certification_verdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
    counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
    counts_as_grounded_evidence = [bool](Get-ObjectPropertyValue -Object $certificate -Name "certified_grounded_evidence" -Default $false)
    mission_verdict = $verdictInfo.verdict
    mission_operational_success = $verdictInfo.mission_operational_success
    mission_grounded_success = $verdictInfo.mission_grounded_success
    mission_promotion_impact = $verdictInfo.mission_promotion_impact
    reduced_promotion_gap = $verdictInfo.reduced_promotion_gap
    grounded_sessions_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "grounded_sessions_delta" -Default 0)
    grounded_too_quiet_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "grounded_too_quiet_delta" -Default 0)
    strong_signal_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "strong_signal_delta" -Default 0)
    responsive_overreaction_blockers_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "responsive_overreaction_blockers_delta" -Default 0)
    next_objective_changed = $verdictInfo.next_objective_changed
    responsive_gate_changed = $verdictInfo.responsive_gate_changed
    explanation = $verdictInfo.explanation
    targets_met = @($metTargetItems | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "label" -Default "") })
    targets_missed = @($missedTargetItems | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "label" -Default "") })
    target_keys_met = @($metTargetItems | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "key" -Default "") })
    target_keys_missed = @($missedTargetItems | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "key" -Default "") })
    target_results = $targetResults
    mission_context = [ordered]@{
        objective_before_session = [string](Get-ObjectPropertyValue -Object $mission -Name "current_next_live_objective" -Default "")
        recommended_live_treatment_profile_before_session = [string](Get-ObjectPropertyValue -Object $mission -Name "recommended_live_treatment_profile" -Default "")
        can_reduce_promotion_gap = [bool](Get-ObjectPropertyValue -Object $mission -Name "can_reduce_promotion_gap" -Default $false)
        can_fully_close_any_part_of_gap = [bool](Get-ObjectPropertyValue -Object $mission -Name "can_fully_close_any_part_of_gap" -Default $false)
        could_open_responsive_gate_if_successful = [bool](Get-ObjectPropertyValue -Object $mission -Name "could_open_responsive_gate_if_successful" -Default $false)
        another_conservative_session_expected_after_success = Get-ObjectPropertyValue -Object $mission -Name "another_conservative_session_expected_after_success" -Default $null
    }
    promotion_impact = [ordered]@{
        reduced_promotion_gap = [bool](Get-ObjectPropertyValue -Object $promotionGapDeltaSummary -Name "reduced_promotion_gap" -Default $false)
        reduced_promotion_gap_components = @((Get-ObjectPropertyValue -Object $promotionGapDeltaSummary -Name "reduced_promotion_gap_components" -Default @()))
        non_promotion_gap_components = @((Get-ObjectPropertyValue -Object $promotionGapDeltaSummary -Name "non_promotion_gap_components" -Default @()))
        grounded_sessions_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "grounded_sessions_delta" -Default 0)
        grounded_too_quiet_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "grounded_too_quiet_delta" -Default 0)
        strong_signal_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "strong_signal_delta" -Default 0)
        responsive_overreaction_blockers_delta = [int](Get-ObjectPropertyValue -Object $whatChanged -Name "responsive_overreaction_blockers_delta" -Default 0)
        next_objective_before = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $beforeVsAfterSummary -Name "next_live_objective" -Default $null) -Name "before" -Default "")
        next_objective_after = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $beforeVsAfterSummary -Name "next_live_objective" -Default $null) -Name "after" -Default "")
        next_objective_changed = $verdictInfo.next_objective_changed
        responsive_gate_before = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $beforeVsAfterSummary -Name "responsive_gate" -Default $null) -Name "before" -Default $null
        responsive_gate_after = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $beforeVsAfterSummary -Name "responsive_gate" -Default $null) -Name "after" -Default $null
        responsive_gate_changed = $verdictInfo.responsive_gate_changed
    }
    next_mission = [ordered]@{
        objective = [string](Get-ObjectPropertyValue -Object $dossier -Name "current_next_live_objective" -Default "")
        treatment_profile = [string](Get-ObjectPropertyValue -Object $dossier -Name "current_next_live_profile" -Default "")
        responsive_gate_verdict = [string](Get-ObjectPropertyValue -Object $dossier -Name "current_responsive_gate_verdict" -Default "")
        responsive_gate_next_live_action = [string](Get-ObjectPropertyValue -Object $dossier -Name "current_responsive_gate_next_live_action" -Default "")
        recommended_next_live_action = [string](Get-ObjectPropertyValue -Object $dossier -Name "recommended_next_live_action" -Default "")
    }
    artifacts = [ordered]@{
        mission_brief_json = $missionPaths.json_path
        mission_brief_markdown = $missionPaths.markdown_path
        live_monitor_status_json = $monitorInfo.json_path
        live_monitor_status_markdown = $monitorInfo.markdown_path
        scorecard_json = $scorecardPath
        grounded_evidence_certificate_json = $certificatePath
        session_outcome_dossier_json = $dossierInfo.json_path
        session_outcome_dossier_markdown = $dossierInfo.markdown_path
        guided_final_session_docket_json = $guidedDocketPath
        mission_attainment_json = $outputJsonPath
        mission_attainment_markdown = $outputMarkdownPath
    }
}

Write-JsonFile -Path $outputJsonPath -Value $missionAttainment
$missionAttainmentForMarkdown = Read-JsonFile -Path $outputJsonPath
Write-TextFile -Path $outputMarkdownPath -Value (Get-MissionAttainmentMarkdown -MissionAttainment $missionAttainmentForMarkdown)

Write-Host "Session mission attainment:"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Mission brief path: $($missionPaths.json_path)"
Write-Host "  Mission verdict: $($missionAttainment.mission_verdict)"
Write-Host "  Grounded certification verdict: $($missionAttainment.current_certification_verdict)"
Write-Host "  Promotion impact: $($missionAttainment.mission_promotion_impact)"
Write-Host "  Next objective: $($missionAttainment.next_mission.objective)"
Write-Host "  Mission attainment JSON: $outputJsonPath"
Write-Host "  Mission attainment Markdown: $outputMarkdownPath"

[pscustomobject]@{
    PairRoot = $resolvedPairRoot
    MissionBriefPath = $missionPaths.json_path
    MissionBriefMarkdownPath = $missionPaths.markdown_path
    MissionVerdict = [string]$missionAttainment.mission_verdict
    MissionOperationalSuccess = [bool]$missionAttainment.mission_operational_success
    MissionGroundedSuccess = [bool]$missionAttainment.mission_grounded_success
    MissionPromotionImpact = [bool]$missionAttainment.mission_promotion_impact
    MissionAttainmentJsonPath = $outputJsonPath
    MissionAttainmentMarkdownPath = $outputMarkdownPath
}
