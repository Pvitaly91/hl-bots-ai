[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$LabRoot = "",
    [string]$OutputRoot = ""
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

function Set-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $property.Value = $Value
        return
    }

    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
}

function Remove-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Invoke-HelperScript {
    param(
        [string]$ScriptName,
        [hashtable]$Arguments
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    & $scriptPath @Arguments | Out-Null
}

function Invoke-CmdWrapper {
    param(
        [string]$WrapperPath,
        [string[]]$Arguments
    )

    $escapedArgs = @($Arguments | ForEach-Object {
        '"' + ($_ -replace '"', '\"') + '"'
    })
    $commandText = @($WrapperPath) + $escapedArgs
    & cmd.exe /c ($commandText -join " ")
    if ($LASTEXITCODE -ne 0) {
        throw "Wrapper failed: $WrapperPath $($Arguments -join ' ')"
    }
}

function Initialize-EmptyRegistry {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    Ensure-Directory -Path $parent | Out-Null
    Write-TextFile -Path $Path -Value ""
}

function New-ValidationPairRoot {
    param(
        [string]$FixtureId,
        [string]$DestinationRoot,
        [string]$PairId
    )

    $sourceRoot = Join-Path (Get-RepoRoot) ("ai_director\testdata\pair_sessions\{0}" -f $FixtureId)
    if (-not (Test-Path -LiteralPath $sourceRoot)) {
        throw "Fixture root was not found: $sourceRoot"
    }

    if (Test-Path -LiteralPath $DestinationRoot) {
        Remove-Item -LiteralPath $DestinationRoot -Recurse -Force
    }

    $parent = Split-Path -Parent $DestinationRoot
    Ensure-Directory -Path $parent | Out-Null
    Copy-Item -LiteralPath $sourceRoot -Destination $DestinationRoot -Recurse -Force

    $pairSummaryPath = Join-Path $DestinationRoot "pair_summary.json"
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    if ($null -eq $pairSummary) {
        throw "Pair summary could not be read from validation root: $DestinationRoot"
    }

    Set-ObjectPropertyValue -Object $pairSummary -Name "prompt_id" -Value (Get-RepoPromptId)
    Set-ObjectPropertyValue -Object $pairSummary -Name "pair_id" -Value $PairId
    Set-ObjectPropertyValue -Object $pairSummary -Name "source_commit_sha" -Value "mission-attainment-validation-fixture"
    Set-ObjectPropertyValue -Object $pairSummary -Name "pair_root" -Value "."
    Set-ObjectPropertyValue -Object $pairSummary -Name "evidence_origin" -Value "live"
    Set-ObjectPropertyValue -Object $pairSummary -Name "rehearsal_mode" -Value $false
    Set-ObjectPropertyValue -Object $pairSummary -Name "validation_only" -Value $false
    Set-ObjectPropertyValue -Object $pairSummary -Name "synthetic_fixture" -Value $false
    $fixtureDescription = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "fixture_description" -Default "")
    Set-ObjectPropertyValue -Object $pairSummary -Name "operator_note" -Value ("Fixture-backed live-like validation pair. Derived from '{0}'. {1}" -f $FixtureId, $fixtureDescription).Trim()

    Write-JsonFile -Path $pairSummaryPath -Value $pairSummary
    return $DestinationRoot
}

function Ensure-ValidationPairArtifacts {
    param(
        [string]$PairRoot,
        [string]$LabRoot
    )

    $pairSummary = Read-JsonFile -Path (Join-Path $PairRoot "pair_summary.json")
    $monitorArgs = @{
        PairRoot = $PairRoot
        Once = $true
        MinControlHumanSnapshots = [int](Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_snapshots" -Default 3)
        MinControlHumanPresenceSeconds = [double](Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_presence_seconds" -Default 60.0)
        MinTreatmentHumanSnapshots = [int](Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_snapshots" -Default 3)
        MinTreatmentHumanPresenceSeconds = [double](Get-ObjectPropertyValue -Object $pairSummary -Name "min_human_presence_seconds" -Default 60.0)
        MinTreatmentPatchEventsWhileHumansPresent = [int](Get-ObjectPropertyValue -Object $pairSummary -Name "min_patch_events_for_usable_lane" -Default 0)
        MinPostPatchObservationSeconds = 20.0
    }
    if (-not [string]::IsNullOrWhiteSpace($LabRoot)) {
        $monitorArgs.LabRoot = $LabRoot
    }

    Invoke-HelperScript -ScriptName "monitor_live_pair_session.ps1" -Arguments $monitorArgs
    Invoke-HelperScript -ScriptName "score_latest_pair_session.ps1" -Arguments @{ PairRoot = $PairRoot }
    Invoke-HelperScript -ScriptName "run_shadow_profile_review.ps1" -Arguments @{ PairRoot = $PairRoot; Profiles = @("conservative", "default", "responsive") }
    Invoke-HelperScript -ScriptName "certify_latest_pair_session.ps1" -Arguments @{ PairRoot = $PairRoot; LabRoot = $LabRoot }
}

function Register-PairRoots {
    param(
        [string[]]$PairRoots,
        [string]$RegistryPath
    )

    Initialize-EmptyRegistry -Path $RegistryPath
    foreach ($pairRoot in @($PairRoots)) {
        Invoke-HelperScript -ScriptName "register_pair_session_result.ps1" -Arguments @{
            PairRoot = $pairRoot
            RegistryPath = $RegistryPath
        }
    }
}

function Build-RegistryArtifacts {
    param(
        [string]$RegistryPath,
        [string]$OutputRoot
    )

    Invoke-HelperScript -ScriptName "summarize_pair_session_registry.ps1" -Arguments @{
        RegistryPath = $RegistryPath
        OutputRoot = $OutputRoot
    }
    Invoke-HelperScript -ScriptName "evaluate_responsive_trial_gate.ps1" -Arguments @{
        RegistryPath = $RegistryPath
        OutputRoot = $OutputRoot
    }
    Invoke-HelperScript -ScriptName "plan_next_live_session.ps1" -Arguments @{
        RegistryPath = $RegistryPath
        OutputRoot = $OutputRoot
        RegistrySummaryPath = (Join-Path $OutputRoot "registry_summary.json")
        ProfileRecommendationPath = (Join-Path $OutputRoot "profile_recommendation.json")
        ResponsiveTrialGatePath = (Join-Path $OutputRoot "responsive_trial_gate.json")
    }
}

function Attach-MissionSnapshot {
    param(
        [string]$PairRoot,
        [string]$MissionJsonPath,
        [string]$MissionMarkdownPath
    )

    $missionRoot = Ensure-Directory -Path (Join-Path $PairRoot "guided_session\mission")
    Copy-Item -LiteralPath $MissionJsonPath -Destination (Join-Path $missionRoot "next_live_session_mission.json") -Force
    Copy-Item -LiteralPath $MissionMarkdownPath -Destination (Join-Path $missionRoot "next_live_session_mission.md") -Force
}

function Build-PreRunMission {
    param(
        [string]$BaselineRegistryPath,
        [string]$BaselineOutputRoot,
        [string]$MissionOutputRoot,
        [string]$PairsRoot
    )

    Invoke-HelperScript -ScriptName "prepare_next_live_session_mission.ps1" -Arguments @{
        RegistryPath = $BaselineRegistryPath
        OutputRoot = $MissionOutputRoot
        RegistrySummaryPath = (Join-Path $BaselineOutputRoot "registry_summary.json")
        ProfileRecommendationPath = (Join-Path $BaselineOutputRoot "profile_recommendation.json")
        ResponsiveTrialGatePath = (Join-Path $BaselineOutputRoot "responsive_trial_gate.json")
        NextLivePlanPath = (Join-Path $BaselineOutputRoot "next_live_plan.json")
        PairsRoot = $PairsRoot
    }

    return [ordered]@{
        json_path = Join-Path $MissionOutputRoot "next_live_session_mission.json"
        markdown_path = Join-Path $MissionOutputRoot "next_live_session_mission.md"
    }
}

function Assert-Condition {
    param(
        [string]$Label,
        [bool]$Condition,
        [string]$FailureMessage
    )

    if (-not $Condition) {
        throw "$Label failed: $FailureMessage"
    }
}

function Find-LatestHistoricalLivePairRoot {
    param([string]$PairsRoot)

    $pairSummaries = Get-ChildItem -LiteralPath $PairsRoot -Filter "pair_summary.json" -Recurse -File -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending

    foreach ($summaryPath in $pairSummaries) {
        $summary = Read-JsonFile -Path $summaryPath.FullName
        $synthetic = [bool](Get-ObjectPropertyValue -Object $summary -Name "synthetic_fixture" -Default $false)
        $rehearsal = [bool](Get-ObjectPropertyValue -Object $summary -Name "rehearsal_mode" -Default $false)
        $validationOnly = [bool](Get-ObjectPropertyValue -Object $summary -Name "validation_only" -Default $false)
        if (-not $synthetic -and -not $rehearsal -and -not $validationOnly) {
            return $summaryPath.DirectoryName
        }
    }

    throw "No historical live pair pack was found under $PairsRoot"
}

function Invoke-MissionAttainment {
    param(
        [string]$PairRoot,
        [string]$RegistryPath
    )

    Invoke-HelperScript -ScriptName "evaluate_latest_session_mission.ps1" -Arguments @{
        PairRoot = $PairRoot
        RegistryPath = $RegistryPath
    }

    $missionAttainmentPath = Join-Path $PairRoot "mission_attainment.json"
    $missionAttainment = Read-JsonFile -Path $missionAttainmentPath
    if ($null -eq $missionAttainment) {
        throw "Mission attainment output was not created for pair root: $PairRoot"
    }

    return $missionAttainment
}

function New-ScenarioResult {
    param(
        [string]$CaseId,
        [string]$PairRoot,
        [object]$MissionAttainment
    )

    return [ordered]@{
        case_id = $CaseId
        pair_root = $PairRoot
        mission_verdict = [string](Get-ObjectPropertyValue -Object $MissionAttainment -Name "mission_verdict" -Default "")
        mission_promotion_impact = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "mission_promotion_impact" -Default $false)
        counts_toward_promotion = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "counts_toward_promotion" -Default $false)
        next_objective_changed = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "next_objective_changed" -Default $false)
        responsive_gate_changed = [bool](Get-ObjectPropertyValue -Object $MissionAttainment -Name "responsive_gate_changed" -Default $false)
        mission_attainment_json = Join-Path $PairRoot "mission_attainment.json"
        mission_attainment_markdown = Join-Path $PairRoot "mission_attainment.md"
    }
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot }
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "mission_attainment_validation")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
$pairsWorkspaceRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "pairs")
$registryWorkspaceRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "registry")
$missionWorkspaceRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "missions")
$summaryJsonPath = Join-Path $resolvedOutputRoot "validation_summary.json"
$summaryMarkdownPath = Join-Path $resolvedOutputRoot "validation_summary.md"

$results = @()

$historicalLivePairRoot = Find-LatestHistoricalLivePairRoot -PairsRoot (Get-PairsRootDefault -LabRoot $resolvedLabRoot)
$historicalLiveCase = [ordered]@{
    case_id = "historical-live-missing-mission-snapshot"
    pair_root = $historicalLivePairRoot
    expected_failure = $true
    observed_failure = $false
    failure_message = ""
}

try {
    Invoke-HelperScript -ScriptName "evaluate_latest_session_mission.ps1" -Arguments @{
        PairRoot = $historicalLivePairRoot
        RegistryPath = (Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "pair_sessions.ndjson")
    }
}
catch {
    $historicalLiveCase.observed_failure = $true
    $historicalLiveCase.failure_message = $_.Exception.Message
}

Assert-Condition -Label "historical live pair missing mission snapshot" -Condition ([bool]$historicalLiveCase.observed_failure) -FailureMessage "Expected the helper to refuse historical live pairs that predate mission snapshots."
Assert-Condition -Label "historical live pair failure message" -Condition ($historicalLiveCase.failure_message -like "No associated mission brief was found*") -FailureMessage ("Unexpected failure message: {0}" -f $historicalLiveCase.failure_message)
$results += $historicalLiveCase

$nonGroundedPairRoot = New-ValidationPairRoot `
    -FixtureId "no_humans_insufficient_data" `
    -DestinationRoot (Join-Path $pairsWorkspaceRoot "non_grounded_latest_session") `
    -PairId "mission-validation-live-no-humans"
Ensure-ValidationPairArtifacts -PairRoot $nonGroundedPairRoot -LabRoot $resolvedLabRoot
$nonGroundedBaselineRegistry = Join-Path $registryWorkspaceRoot "non_grounded_before\pair_sessions.ndjson"
$nonGroundedAfterRegistry = Join-Path $registryWorkspaceRoot "non_grounded_after\pair_sessions.ndjson"
Register-PairRoots -PairRoots @() -RegistryPath $nonGroundedBaselineRegistry
Build-RegistryArtifacts -RegistryPath $nonGroundedBaselineRegistry -OutputRoot (Split-Path -Parent $nonGroundedBaselineRegistry)
$nonGroundedMission = Build-PreRunMission `
    -BaselineRegistryPath $nonGroundedBaselineRegistry `
    -BaselineOutputRoot (Split-Path -Parent $nonGroundedBaselineRegistry) `
    -MissionOutputRoot (Join-Path $missionWorkspaceRoot "non_grounded_before") `
    -PairsRoot (Ensure-Directory -Path (Join-Path $resolvedOutputRoot "mission_pairs\non_grounded_before"))
Attach-MissionSnapshot -PairRoot $nonGroundedPairRoot -MissionJsonPath $nonGroundedMission.json_path -MissionMarkdownPath $nonGroundedMission.markdown_path
Register-PairRoots -PairRoots @($nonGroundedPairRoot) -RegistryPath $nonGroundedAfterRegistry
Build-RegistryArtifacts -RegistryPath $nonGroundedAfterRegistry -OutputRoot (Split-Path -Parent $nonGroundedAfterRegistry)
$nonGroundedMissionAttainment = Invoke-MissionAttainment -PairRoot $nonGroundedPairRoot -RegistryPath $nonGroundedAfterRegistry
Assert-Condition -Label "non-grounded mission verdict" -Condition ([string]$nonGroundedMissionAttainment.mission_verdict -eq "mission-failed-insufficient-signal") -FailureMessage ("Expected mission-failed-insufficient-signal, got {0}" -f $nonGroundedMissionAttainment.mission_verdict)
Assert-Condition -Label "non-grounded mission promotion impact" -Condition (-not [bool]$nonGroundedMissionAttainment.mission_promotion_impact) -FailureMessage "Non-grounded no-human evidence must not show promotion impact."
Assert-Condition -Label "non-grounded responsive gate unchanged" -Condition (-not [bool]$nonGroundedMissionAttainment.responsive_gate_changed) -FailureMessage "Non-grounded evidence must not change the responsive gate."
$results += New-ScenarioResult -CaseId "non_grounded_latest_session" -PairRoot $nonGroundedPairRoot -MissionAttainment $nonGroundedMissionAttainment

$baselineStrongOne = New-ValidationPairRoot `
    -FixtureId "strong_signal_keep_conservative" `
    -DestinationRoot (Join-Path $pairsWorkspaceRoot "gap_reduced_baseline_one") `
    -PairId "mission-validation-grounded-baseline-one"
$gapReducedPairRoot = New-ValidationPairRoot `
    -FixtureId "strong_signal_keep_conservative" `
    -DestinationRoot (Join-Path $pairsWorkspaceRoot "gap_reduced_target") `
    -PairId "mission-validation-grounded-gap-reduced"
Ensure-ValidationPairArtifacts -PairRoot $baselineStrongOne -LabRoot $resolvedLabRoot
Ensure-ValidationPairArtifacts -PairRoot $gapReducedPairRoot -LabRoot $resolvedLabRoot
$gapReducedBaselineRegistry = Join-Path $registryWorkspaceRoot "gap_reduced_before\pair_sessions.ndjson"
$gapReducedAfterRegistry = Join-Path $registryWorkspaceRoot "gap_reduced_after\pair_sessions.ndjson"
Register-PairRoots -PairRoots @($baselineStrongOne) -RegistryPath $gapReducedBaselineRegistry
Build-RegistryArtifacts -RegistryPath $gapReducedBaselineRegistry -OutputRoot (Split-Path -Parent $gapReducedBaselineRegistry)
$gapReducedMission = Build-PreRunMission `
    -BaselineRegistryPath $gapReducedBaselineRegistry `
    -BaselineOutputRoot (Split-Path -Parent $gapReducedBaselineRegistry) `
    -MissionOutputRoot (Join-Path $missionWorkspaceRoot "gap_reduced_before") `
    -PairsRoot (Ensure-Directory -Path (Join-Path $resolvedOutputRoot "mission_pairs\gap_reduced_before"))
Attach-MissionSnapshot -PairRoot $gapReducedPairRoot -MissionJsonPath $gapReducedMission.json_path -MissionMarkdownPath $gapReducedMission.markdown_path
Register-PairRoots -PairRoots @($baselineStrongOne, $gapReducedPairRoot) -RegistryPath $gapReducedAfterRegistry
Build-RegistryArtifacts -RegistryPath $gapReducedAfterRegistry -OutputRoot (Split-Path -Parent $gapReducedAfterRegistry)
$gapReducedMissionAttainment = Invoke-MissionAttainment -PairRoot $gapReducedPairRoot -RegistryPath $gapReducedAfterRegistry
Assert-Condition -Label "gap reduced mission verdict" -Condition ([string]$gapReducedMissionAttainment.mission_verdict -eq "mission-met-and-gap-reduced") -FailureMessage ("Expected mission-met-and-gap-reduced, got {0}" -f $gapReducedMissionAttainment.mission_verdict)
Assert-Condition -Label "gap reduced mission promotion impact" -Condition ([bool]$gapReducedMissionAttainment.mission_promotion_impact) -FailureMessage "Gap-reduced grounded evidence must show promotion impact."
Assert-Condition -Label "gap reduced next objective unchanged" -Condition (-not [bool]$gapReducedMissionAttainment.next_objective_changed) -FailureMessage "This scenario should reduce the gap without advancing the next objective."
$results += New-ScenarioResult -CaseId "grounded_gap_reduced" -PairRoot $gapReducedPairRoot -MissionAttainment $gapReducedMissionAttainment

$advancedStrongOne = New-ValidationPairRoot `
    -FixtureId "strong_signal_keep_conservative" `
    -DestinationRoot (Join-Path $pairsWorkspaceRoot "advanced_baseline_one") `
    -PairId "mission-validation-advanced-baseline-one"
$advancedStrongTwo = New-ValidationPairRoot `
    -FixtureId "strong_signal_keep_conservative" `
    -DestinationRoot (Join-Path $pairsWorkspaceRoot "advanced_baseline_two") `
    -PairId "mission-validation-advanced-baseline-two"
$advancedTargetPairRoot = New-ValidationPairRoot `
    -FixtureId "conservative_too_quiet_responsive_candidate" `
    -DestinationRoot (Join-Path $pairsWorkspaceRoot "advanced_target") `
    -PairId "mission-validation-advanced-target"
Ensure-ValidationPairArtifacts -PairRoot $advancedStrongOne -LabRoot $resolvedLabRoot
Ensure-ValidationPairArtifacts -PairRoot $advancedStrongTwo -LabRoot $resolvedLabRoot
Ensure-ValidationPairArtifacts -PairRoot $advancedTargetPairRoot -LabRoot $resolvedLabRoot
$advancedBaselineRegistry = Join-Path $registryWorkspaceRoot "advanced_before\pair_sessions.ndjson"
$advancedAfterRegistry = Join-Path $registryWorkspaceRoot "advanced_after\pair_sessions.ndjson"
Register-PairRoots -PairRoots @($advancedStrongOne, $advancedStrongTwo) -RegistryPath $advancedBaselineRegistry
Build-RegistryArtifacts -RegistryPath $advancedBaselineRegistry -OutputRoot (Split-Path -Parent $advancedBaselineRegistry)
$advancedMission = Build-PreRunMission `
    -BaselineRegistryPath $advancedBaselineRegistry `
    -BaselineOutputRoot (Split-Path -Parent $advancedBaselineRegistry) `
    -MissionOutputRoot (Join-Path $missionWorkspaceRoot "advanced_before") `
    -PairsRoot (Ensure-Directory -Path (Join-Path $resolvedOutputRoot "mission_pairs\advanced_before"))
Attach-MissionSnapshot -PairRoot $advancedTargetPairRoot -MissionJsonPath $advancedMission.json_path -MissionMarkdownPath $advancedMission.markdown_path
Register-PairRoots -PairRoots @($advancedStrongOne, $advancedStrongTwo, $advancedTargetPairRoot) -RegistryPath $advancedAfterRegistry
Build-RegistryArtifacts -RegistryPath $advancedAfterRegistry -OutputRoot (Split-Path -Parent $advancedAfterRegistry)
$advancedMissionAttainment = Invoke-MissionAttainment -PairRoot $advancedTargetPairRoot -RegistryPath $advancedAfterRegistry
Assert-Condition -Label "advanced mission verdict" -Condition ([string]$advancedMissionAttainment.mission_verdict -eq "mission-met-and-next-objective-advanced") -FailureMessage ("Expected mission-met-and-next-objective-advanced, got {0}" -f $advancedMissionAttainment.mission_verdict)
Assert-Condition -Label "advanced mission promotion impact" -Condition ([bool]$advancedMissionAttainment.mission_promotion_impact) -FailureMessage "Objective-advanced grounded evidence must show promotion impact."
Assert-Condition -Label "advanced mission next objective changed" -Condition ([bool]$advancedMissionAttainment.next_objective_changed) -FailureMessage "This scenario should advance the next objective."
$results += New-ScenarioResult -CaseId "grounded_next_objective_advanced" -PairRoot $advancedTargetPairRoot -MissionAttainment $advancedMissionAttainment

$rehearsalEvalRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "guided_rehearsal_eval")
$rehearsalResult = & (Join-Path $PSScriptRoot "run_guided_live_pair_session.ps1") `
    -RehearsalMode `
    -RehearsalFixtureId "strong_signal_keep_conservative" `
    -AutoStartMonitor `
    -AutoStopWhenSufficient `
    -RunPostPipeline `
    -OutputRoot $rehearsalEvalRoot `
    -MonitorPollSeconds 1 `
    -MinHumanSnapshots 3 `
    -MinHumanPresenceSeconds 60 `
    -MinPatchEventsForUsableLane 2 `
    -MinPostPatchObservationSeconds 20
$rehearsalPairRoot = [string](Get-ObjectPropertyValue -Object $rehearsalResult -Name "PairRoot" -Default "")
if (-not $rehearsalPairRoot) {
    throw "Guided rehearsal did not return a pair root."
}
$rehearsalMissionAttainment = Read-JsonFile -Path (Join-Path $rehearsalPairRoot "mission_attainment.json")
if ($null -eq $rehearsalMissionAttainment) {
    throw "Guided rehearsal did not produce mission_attainment.json under $rehearsalPairRoot"
}
Assert-Condition -Label "guided rehearsal mission verdict" -Condition ([string]$rehearsalMissionAttainment.mission_verdict -eq "mission-met-but-no-promotion-impact") -FailureMessage ("Expected rehearsal mission-met-but-no-promotion-impact, got {0}" -f $rehearsalMissionAttainment.mission_verdict)
Assert-Condition -Label "guided rehearsal no promotion impact" -Condition (-not [bool]$rehearsalMissionAttainment.mission_promotion_impact) -FailureMessage "Rehearsal evidence must not show promotion impact."
$results += New-ScenarioResult -CaseId "guided_rehearsal_latest" -PairRoot $rehearsalPairRoot -MissionAttainment $rehearsalMissionAttainment

$wrapperPath = Join-Path (Get-RepoRoot) "scripts\evaluate_latest_session_mission.bat"
if (Test-Path -LiteralPath $wrapperPath) {
    Invoke-CmdWrapper -WrapperPath $wrapperPath -Arguments @($gapReducedPairRoot, "-RegistryPath", $gapReducedAfterRegistry)
    Assert-Condition -Label "bat wrapper mission output" -Condition (Test-Path -LiteralPath (Join-Path $gapReducedPairRoot "mission_attainment.json")) -FailureMessage "The batch wrapper did not produce mission_attainment.json."
}

$summary = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    output_root = $resolvedOutputRoot
    cases = $results
}

Write-JsonFile -Path $summaryJsonPath -Value $summary

$summaryLines = @(
    "# Mission Attainment Validation",
    "",
    "- Output root: $resolvedOutputRoot",
    "- Summary JSON: $summaryJsonPath",
    ""
)
foreach ($case in @($results)) {
    $caseVerdict = [string](Get-ObjectPropertyValue -Object $case -Name "mission_verdict" -Default "")
    if ([string]::IsNullOrWhiteSpace($caseVerdict) -and [bool](Get-ObjectPropertyValue -Object $case -Name "observed_failure" -Default $false)) {
        $caseVerdict = "expected-failure"
    }
    $summaryLines += "- $($case.case_id): $caseVerdict"
}
$summaryLines += ""
Write-TextFile -Path $summaryMarkdownPath -Value (($summaryLines -join [Environment]::NewLine) + [Environment]::NewLine)

Write-Host "Mission-attainment validation:"
Write-Host "  Summary JSON: $summaryJsonPath"
Write-Host "  Summary Markdown: $summaryMarkdownPath"

[pscustomobject]@{
    OutputRoot = $resolvedOutputRoot
    SummaryJsonPath = $summaryJsonPath
    SummaryMarkdownPath = $summaryMarkdownPath
}
