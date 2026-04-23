[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$Configuration = "",
    [string]$Platform = "",
    [int]$DurationSeconds = -1,
    [string]$Map = "",
    [int]$BotCount = -1,
    [int]$BotSkill = -1,
    [int]$ControlPort = -1,
    [int]$TreatmentPort = -1,
    [string]$TreatmentProfile = "",
    [int]$MinHumanSnapshots = -1,
    [double]$MinHumanPresenceSeconds = -1,
    [int]$MinPatchEventsForUsableLane = -1,
    [double]$MinPostPatchObservationSeconds = -1,
    [int]$HumanJoinGraceSeconds = -1,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [switch]$AutoStartMonitor,
    [switch]$AutoStopWhenSufficient,
    [int]$MonitorPollSeconds = 5,
    [switch]$RunPostPipeline,
    [switch]$RehearsalMode,
    [string]$RehearsalFixtureId = "strong_signal_keep_conservative",
    [int]$RehearsalStepSeconds = 2,
    [switch]$AllowMissionOverride,
    [switch]$AllowSafePortOverride,
    [switch]$DryRun,
    [switch]$PrintCommandOnly
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

function Format-DisplayValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", [double]$Value)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return (@($Value) | ForEach-Object { Format-DisplayValue -Value $_ }) -join ", "
    }

    return [string]$Value
}

function Format-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function New-DriftFieldRecord {
    param(
        [string]$FieldName,
        [object]$MissionValue,
        [object]$ActualValue,
        [bool]$Match,
        [bool]$Allowed,
        [bool]$ChangesExperimentMeaning,
        [string]$Explanation
    )

    return [ordered]@{
        field_name = $FieldName
        mission_value = $MissionValue
        actual_value = $ActualValue
        match = $Match
        allowed = $Allowed
        changes_experiment_meaning = $ChangesExperimentMeaning
        explanation = $Explanation
    }
}

function Get-MissionExecutionMarkdown {
    param([object]$Execution)

    $lines = @(
        "# Mission Execution",
        "",
        "- Mission path used: $($Execution.mission_path_used)",
        "- Mission Markdown path used: $($Execution.mission_markdown_path_used)",
        "- Mission hash SHA256: $($Execution.mission_identity.sha256)",
        "- Mission objective: $($Execution.mission_identity.current_next_live_objective)",
        "- Mission recommended live profile: $($Execution.mission_identity.recommended_live_treatment_profile)",
        "- Execution mode: $($Execution.execution_mode)",
        "- Pair root: $($Execution.pair_root)",
        "- Guided session root: $($Execution.guided_session_root)",
        "- Mission compliant: $($Execution.mission_compliant)",
        "- Mission divergent: $($Execution.mission_divergent)",
        "- Valid for mission-attainment analysis: $($Execution.valid_for_mission_attainment_analysis)",
        "- Drift detected: $($Execution.drift_summary.drift_detected)",
        "- Drift policy verdict: $($Execution.drift_policy_verdict)",
        "- Explanation: $($Execution.explanation)",
        "",
        "## Requested Launch Parameters",
        "",
        "- Map: $($Execution.requested_execution_parameters.map)",
        "- Bot count: $($Execution.requested_execution_parameters.bot_count)",
        "- Bot skill: $($Execution.requested_execution_parameters.bot_skill)",
        "- Control port: $($Execution.requested_execution_parameters.control_port)",
        "- Treatment port: $($Execution.requested_execution_parameters.treatment_port)",
        "- Treatment profile: $($Execution.requested_execution_parameters.treatment_profile)",
        "- Min human snapshots: $($Execution.requested_execution_parameters.min_human_snapshots)",
        "- Min human presence seconds: $($Execution.requested_execution_parameters.min_human_presence_seconds)",
        "- Min patch-while-human-present events: $($Execution.requested_execution_parameters.min_patch_events_for_usable_lane)",
        "- Min post-patch observation seconds: $($Execution.requested_execution_parameters.min_post_patch_observation_seconds)",
        "- Pair output root: $($Execution.requested_execution_parameters.output_root)",
        "- Skip SteamCMD update: $($Execution.requested_execution_parameters.skip_steamcmd_update)",
        "- Skip Metamod download: $($Execution.requested_execution_parameters.skip_metamod_download)",
        "- Rehearsal mode: $($Execution.requested_execution_parameters.rehearsal_mode)",
        "",
        "## Drift Fields",
        ""
    )

    foreach ($property in @($Execution.drift_summary.fields.PSObject.Properties)) {
        $field = $property.Value
        $lines += ("- {0}: mission={1}; actual={2}; match={3}; allowed={4}; explanation={5}" -f
            [string](Get-ObjectPropertyValue -Object $field -Name "field_name" -Default $property.Name),
            (Format-DisplayValue -Value (Get-ObjectPropertyValue -Object $field -Name "mission_value" -Default $null)),
            (Format-DisplayValue -Value (Get-ObjectPropertyValue -Object $field -Name "actual_value" -Default $null)),
            ([bool](Get-ObjectPropertyValue -Object $field -Name "match" -Default $false)).ToString().ToLowerInvariant(),
            ([bool](Get-ObjectPropertyValue -Object $field -Name "allowed" -Default $false)).ToString().ToLowerInvariant(),
            [string](Get-ObjectPropertyValue -Object $field -Name "explanation" -Default "")
        )
    }

    $lines += @(
        "",
        "## Guided Runner Command",
        "",
        '```powershell',
        ([string](Get-ObjectPropertyValue -Object $Execution -Name "guided_runner_command" -Default "")),
        '```',
        ""
    )

    return ($lines -join [Environment]::NewLine)
}

function Resolve-MissionPaths {
    param(
        [string]$ExplicitMissionPath,
        [string]$ExplicitMissionMarkdownPath,
        [string]$ResolvedLabRoot
    )

    $repoRoot = Get-RepoRoot
    $prepareScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"
    $defaultMissionPath = Join-Path (Get-RegistryRootDefault -LabRoot $ResolvedLabRoot) "next_live_session_mission.json"

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $resolvedMissionPath = Get-AbsolutePath -Path $ExplicitMissionPath -BasePath $repoRoot
        if (-not (Test-Path -LiteralPath $resolvedMissionPath)) {
            throw "MissionPath was not found: $resolvedMissionPath"
        }
    }
    else {
        $resolvedMissionPath = Resolve-ExistingPath -Path $defaultMissionPath
        if (-not $resolvedMissionPath) {
            $preparedMission = & $prepareScriptPath -LabRoot $ResolvedLabRoot
            $resolvedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionJsonPath" -Default ""))
        }
        if (-not $resolvedMissionPath) {
            throw "No current mission brief was available. Run scripts\\prepare_next_live_session_mission.ps1 first."
        }
    }

    $resolvedMissionMarkdownPath = ""
    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionMarkdownPath)) {
        $resolvedMissionMarkdownPath = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionMarkdownPath -BasePath $repoRoot)
    }

    if (-not $resolvedMissionMarkdownPath) {
        $siblingMarkdownPath = [System.IO.Path]::ChangeExtension($resolvedMissionPath, ".md")
        $resolvedMissionMarkdownPath = Resolve-ExistingPath -Path $siblingMarkdownPath
    }

    return [pscustomobject]@{
        JsonPath = $resolvedMissionPath
        MarkdownPath = $resolvedMissionMarkdownPath
    }
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    Get-LabRootDefault
}
else {
    Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot
}
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot

$missionPaths = Resolve-MissionPaths `
    -ExplicitMissionPath $MissionPath `
    -ExplicitMissionMarkdownPath $MissionMarkdownPath `
    -ResolvedLabRoot $resolvedLabRoot

$mission = Read-JsonFile -Path $missionPaths.JsonPath
if ($null -eq $mission) {
    throw "Mission brief could not be parsed: $($missionPaths.JsonPath)"
}

$missionHash = Get-FileSha256 -Path $missionPaths.JsonPath
$missionLiveShape = Get-ObjectPropertyValue -Object $mission -Name "live_session_run_shape" -Default $null
$missionLauncherDefaults = Get-ObjectPropertyValue -Object $mission -Name "launcher_defaults" -Default $null
$missionControlLane = Get-ObjectPropertyValue -Object $mission -Name "control_lane_configuration" -Default $null
$missionTreatmentLane = Get-ObjectPropertyValue -Object $mission -Name "treatment_lane_configuration" -Default $null

$missionMinControlSnapshots = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_snapshots" -Default 0)
$missionMinTreatmentSnapshots = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_snapshots" -Default $missionMinControlSnapshots)
if ($missionMinControlSnapshots -ne $missionMinTreatmentSnapshots) {
    throw "The current mission brief requires asymmetric human snapshot thresholds, but the guided runner supports one shared MinHumanSnapshots value."
}

$missionMinControlPresence = [double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_presence_seconds" -Default 0.0)
$missionMinTreatmentPresence = [double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_presence_seconds" -Default $missionMinControlPresence)
if ([math]::Abs($missionMinControlPresence - $missionMinTreatmentPresence) -gt 0.001) {
    throw "The current mission brief requires asymmetric human presence thresholds, but the guided runner supports one shared MinHumanPresenceSeconds value."
}

$missionMap = [string](Get-ObjectPropertyValue -Object $missionLiveShape -Name "map" -Default "crossfire")
$missionBotCount = [int](Get-ObjectPropertyValue -Object $missionLiveShape -Name "bot_count" -Default 4)
$missionBotSkill = [int](Get-ObjectPropertyValue -Object $missionLiveShape -Name "bot_skill" -Default 3)
$missionControlPort = [int](Get-ObjectPropertyValue -Object $missionControlLane -Name "port" -Default 27016)
$missionTreatmentPort = [int](Get-ObjectPropertyValue -Object $missionTreatmentLane -Name "port" -Default 27017)
$missionTreatmentProfile = [string](Get-ObjectPropertyValue -Object $mission -Name "recommended_live_treatment_profile" -Default (Get-ObjectPropertyValue -Object $missionTreatmentLane -Name "treatment_profile" -Default "conservative"))
$missionWaitForHumanJoin = [bool](Get-ObjectPropertyValue -Object $missionLiveShape -Name "wait_for_human_join" -Default $true)
$missionHumanJoinGraceSeconds = [int](Get-ObjectPropertyValue -Object $missionLiveShape -Name "human_join_grace_seconds" -Default 120)
$missionMinHumanSnapshots = $missionMinControlSnapshots
$missionMinHumanPresenceSeconds = $missionMinControlPresence
$missionMinPatchEvents = [int](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_patch_while_human_present_events" -Default 0)
$missionMinPostPatchObservationSeconds = [double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_post_patch_observation_window_seconds" -Default 0.0)
$missionOutputRoot = [string](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "pair_output_root" -Default (Get-PairsRootDefault -LabRoot $resolvedLabRoot))
$missionEvalRoot = [string](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "eval_root" -Default (Get-EvalRootDefault -LabRoot $resolvedLabRoot))
$missionConfiguration = [string](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "configuration" -Default "Release")
$missionPlatform = [string](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "platform" -Default "Win32")
$missionDurationSeconds = [int](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "duration_seconds" -Default 80)
$missionSkipSteamCmdUpdate = [bool](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "skip_steamcmd_update" -Default $false)
$missionSkipMetamodDownload = [bool](Get-ObjectPropertyValue -Object $missionLauncherDefaults -Name "skip_metamod_download" -Default $false)
$missionSemantics = "paired-control-vs-treatment-guided-session"
$missionGateVerdict = [string](Get-ObjectPropertyValue -Object $mission -Name "current_responsive_gate_verdict" -Default "")

$actualMap = if ($PSBoundParameters.ContainsKey("Map")) { $Map } else { $missionMap }
$actualBotCount = if ($PSBoundParameters.ContainsKey("BotCount")) { $BotCount } else { $missionBotCount }
$actualBotSkill = if ($PSBoundParameters.ContainsKey("BotSkill")) { $BotSkill } else { $missionBotSkill }
$actualControlPort = if ($PSBoundParameters.ContainsKey("ControlPort")) { $ControlPort } else { $missionControlPort }
$actualTreatmentPort = if ($PSBoundParameters.ContainsKey("TreatmentPort")) { $TreatmentPort } else { $missionTreatmentPort }
$actualTreatmentProfile = if ($PSBoundParameters.ContainsKey("TreatmentProfile") -and -not [string]::IsNullOrWhiteSpace($TreatmentProfile)) { $TreatmentProfile.Trim() } else { $missionTreatmentProfile }
$actualMinHumanSnapshots = if ($PSBoundParameters.ContainsKey("MinHumanSnapshots")) { $MinHumanSnapshots } else { $missionMinHumanSnapshots }
$actualMinHumanPresenceSeconds = if ($PSBoundParameters.ContainsKey("MinHumanPresenceSeconds")) { $MinHumanPresenceSeconds } else { $missionMinHumanPresenceSeconds }
$actualMinPatchEvents = if ($PSBoundParameters.ContainsKey("MinPatchEventsForUsableLane")) { $MinPatchEventsForUsableLane } else { $missionMinPatchEvents }
$actualMinPostPatchObservationSeconds = if ($PSBoundParameters.ContainsKey("MinPostPatchObservationSeconds")) { $MinPostPatchObservationSeconds } else { $missionMinPostPatchObservationSeconds }
$actualHumanJoinGraceSeconds = if ($PSBoundParameters.ContainsKey("HumanJoinGraceSeconds")) { $HumanJoinGraceSeconds } else { $missionHumanJoinGraceSeconds }
$actualOutputRoot = if ($PSBoundParameters.ContainsKey("OutputRoot")) { Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot } else { Get-AbsolutePath -Path $missionOutputRoot -BasePath $repoRoot }
$actualEvalRoot = if ($actualOutputRoot -ieq (Get-AbsolutePath -Path $missionOutputRoot -BasePath $repoRoot)) {
    Get-AbsolutePath -Path $missionEvalRoot -BasePath $repoRoot
}
else {
    Split-Path -Path $actualOutputRoot -Parent
}
$actualConfiguration = if ($PSBoundParameters.ContainsKey("Configuration") -and -not [string]::IsNullOrWhiteSpace($Configuration)) { $Configuration } else { $missionConfiguration }
$actualPlatform = if ($PSBoundParameters.ContainsKey("Platform") -and -not [string]::IsNullOrWhiteSpace($Platform)) { $Platform } else { $missionPlatform }
$actualDurationSeconds = if ($PSBoundParameters.ContainsKey("DurationSeconds")) { $DurationSeconds } else { $missionDurationSeconds }
$actualSkipSteamCmdUpdate = if ($PSBoundParameters.ContainsKey("SkipSteamCmdUpdate")) { [bool]$SkipSteamCmdUpdate } else { $missionSkipSteamCmdUpdate }
$actualSkipMetamodDownload = if ($PSBoundParameters.ContainsKey("SkipMetamodDownload")) { [bool]$SkipMetamodDownload } else { $missionSkipMetamodDownload }
$actualSemantics = $missionSemantics

if ([string]::IsNullOrWhiteSpace($actualTreatmentProfile) -or $actualTreatmentProfile -notin @("conservative", "default", "responsive")) {
    throw "TreatmentProfile must resolve to one of: conservative, default, responsive."
}

Assert-BotLaunchSettings -BotCount $actualBotCount -BotSkill $actualBotSkill

if ($actualControlPort -lt 1 -or $actualControlPort -gt 65535) {
    throw "ControlPort must be between 1 and 65535."
}
if ($actualTreatmentPort -lt 1 -or $actualTreatmentPort -gt 65535) {
    throw "TreatmentPort must be between 1 and 65535."
}
if ($actualControlPort -eq $actualTreatmentPort) {
    throw "ControlPort and TreatmentPort must differ."
}
if ($actualMinHumanSnapshots -lt 1) {
    throw "MinHumanSnapshots must be at least 1."
}
if ($actualMinHumanPresenceSeconds -lt 1) {
    throw "MinHumanPresenceSeconds must be at least 1."
}
if ($actualMinPatchEvents -lt 0) {
    throw "MinPatchEventsForUsableLane cannot be negative."
}
if ($actualMinPostPatchObservationSeconds -lt 1) {
    throw "MinPostPatchObservationSeconds must be at least 1."
}
if ($actualHumanJoinGraceSeconds -lt 5) {
    throw "HumanJoinGraceSeconds must be at least 5."
}
if ($actualDurationSeconds -lt 5) {
    throw "DurationSeconds must be at least 5."
}
if ($actualConfiguration -ne "Release" -and $actualConfiguration -ne "Debug") {
    throw "Configuration must be Release or Debug."
}
if ($actualPlatform -ne "Win32") {
    throw "Platform must remain Win32 for this repository."
}

$driftFields = [ordered]@{}

$field = New-DriftFieldRecord -FieldName "map" `
    -MissionValue $missionMap `
    -ActualValue $actualMap `
    -Match ($actualMap -ieq $missionMap) `
    -Allowed (($actualMap -ieq $missionMap) -or $AllowMissionOverride) `
    -ChangesExperimentMeaning ($actualMap -ine $missionMap) `
    -Explanation $(if ($actualMap -ieq $missionMap) { "Matches the mission." } elseif ($AllowMissionOverride) { "Map drift changes the experiment shape and is allowed only because -AllowMissionOverride was supplied." } else { "Map drift changes the experiment shape and is blocked unless -AllowMissionOverride is supplied." })
$driftFields.map = $field

$field = New-DriftFieldRecord -FieldName "bot_count" `
    -MissionValue $missionBotCount `
    -ActualValue $actualBotCount `
    -Match ($actualBotCount -eq $missionBotCount) `
    -Allowed (($actualBotCount -eq $missionBotCount) -or $AllowMissionOverride) `
    -ChangesExperimentMeaning ($actualBotCount -ne $missionBotCount) `
    -Explanation $(if ($actualBotCount -eq $missionBotCount) { "Matches the mission." } elseif ($AllowMissionOverride) { "Bot-count drift changes the experiment shape and is allowed only because -AllowMissionOverride was supplied." } else { "Bot-count drift changes the experiment shape and is blocked unless -AllowMissionOverride is supplied." })
$driftFields.bot_count = $field

$field = New-DriftFieldRecord -FieldName "bot_skill" `
    -MissionValue $missionBotSkill `
    -ActualValue $actualBotSkill `
    -Match ($actualBotSkill -eq $missionBotSkill) `
    -Allowed (($actualBotSkill -eq $missionBotSkill) -or $AllowMissionOverride) `
    -ChangesExperimentMeaning ($actualBotSkill -ne $missionBotSkill) `
    -Explanation $(if ($actualBotSkill -eq $missionBotSkill) { "Matches the mission." } elseif ($AllowMissionOverride) { "Bot-skill drift changes the experiment shape and is allowed only because -AllowMissionOverride was supplied." } else { "Bot-skill drift changes the experiment shape and is blocked unless -AllowMissionOverride is supplied." })
$driftFields.bot_skill = $field

$portsAllowed = $AllowSafePortOverride -or $AllowMissionOverride
$field = New-DriftFieldRecord -FieldName "control_port" `
    -MissionValue $missionControlPort `
    -ActualValue $actualControlPort `
    -Match ($actualControlPort -eq $missionControlPort) `
    -Allowed (($actualControlPort -eq $missionControlPort) -or $portsAllowed) `
    -ChangesExperimentMeaning $false `
    -Explanation $(if ($actualControlPort -eq $missionControlPort) { "Matches the mission." } elseif ($portsAllowed) { "Control-port drift is operator-level only and is allowed because -AllowSafePortOverride or -AllowMissionOverride was supplied." } else { "Control-port drift is blocked by default; use -AllowSafePortOverride for safe operator-level port changes." })
$driftFields.control_port = $field

$field = New-DriftFieldRecord -FieldName "treatment_port" `
    -MissionValue $missionTreatmentPort `
    -ActualValue $actualTreatmentPort `
    -Match ($actualTreatmentPort -eq $missionTreatmentPort) `
    -Allowed (($actualTreatmentPort -eq $missionTreatmentPort) -or $portsAllowed) `
    -ChangesExperimentMeaning $false `
    -Explanation $(if ($actualTreatmentPort -eq $missionTreatmentPort) { "Matches the mission." } elseif ($portsAllowed) { "Treatment-port drift is operator-level only and is allowed because -AllowSafePortOverride or -AllowMissionOverride was supplied." } else { "Treatment-port drift is blocked by default; use -AllowSafePortOverride for safe operator-level port changes." })
$driftFields.treatment_port = $field

$responsiveWhenClosed = ($actualTreatmentProfile -ieq "responsive") -and ($missionGateVerdict -ne "open")
$profileAllowed = ($actualTreatmentProfile -ieq $missionTreatmentProfile) -or $AllowMissionOverride
$profileExplanation = if ($actualTreatmentProfile -ieq $missionTreatmentProfile) {
    "Matches the mission."
}
elseif ($responsiveWhenClosed -and -not $AllowMissionOverride) {
    "The mission keeps the live treatment profile on '$missionTreatmentProfile' while the responsive gate is '$missionGateVerdict'. Launching responsive here is blocked unless -AllowMissionOverride is supplied, and any such run must stay mission-divergent."
}
elseif ($AllowMissionOverride) {
    "Treatment-profile drift changes the experiment meaning and is allowed only because -AllowMissionOverride was supplied. The run stays mission-divergent."
}
else {
    "Treatment-profile drift changes the experiment meaning and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "treatment_profile" `
    -MissionValue $missionTreatmentProfile `
    -ActualValue $actualTreatmentProfile `
    -Match ($actualTreatmentProfile -ieq $missionTreatmentProfile) `
    -Allowed $profileAllowed `
    -ChangesExperimentMeaning ($actualTreatmentProfile -ine $missionTreatmentProfile) `
    -Explanation $profileExplanation
$driftFields.treatment_profile = $field

$humanSnapshotMatch = ($actualMinHumanSnapshots -eq $missionMinHumanSnapshots)
$humanSnapshotAllowed = if ($humanSnapshotMatch) { $true } elseif ($actualMinHumanSnapshots -gt $missionMinHumanSnapshots) { $true } else { $AllowMissionOverride }
$humanSnapshotMeaningChange = $actualMinHumanSnapshots -lt $missionMinHumanSnapshots
$humanSnapshotExplanation = if ($humanSnapshotMatch) {
    "Matches the mission."
}
elseif ($actualMinHumanSnapshots -gt $missionMinHumanSnapshots) {
    "The launch raises the minimum human snapshots above the mission floor. That is stricter than requested and stays mission-compliant, but the drift is recorded."
}
elseif ($AllowMissionOverride) {
    "The launch weakens the minimum human snapshots below the mission floor and is allowed only because -AllowMissionOverride was supplied. The run stays mission-divergent."
}
else {
    "The launch weakens the minimum human snapshots below the mission floor and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "human_signal_threshold_min_human_snapshots" `
    -MissionValue $missionMinHumanSnapshots `
    -ActualValue $actualMinHumanSnapshots `
    -Match $humanSnapshotMatch `
    -Allowed $humanSnapshotAllowed `
    -ChangesExperimentMeaning $humanSnapshotMeaningChange `
    -Explanation $humanSnapshotExplanation
$driftFields.human_signal_threshold_min_human_snapshots = $field

$humanPresenceMatch = [math]::Abs($actualMinHumanPresenceSeconds - $missionMinHumanPresenceSeconds) -lt 0.001
$humanPresenceAllowed = if ($humanPresenceMatch) { $true } elseif ($actualMinHumanPresenceSeconds -gt $missionMinHumanPresenceSeconds) { $true } else { $AllowMissionOverride }
$humanPresenceMeaningChange = $actualMinHumanPresenceSeconds -lt $missionMinHumanPresenceSeconds
$humanPresenceExplanation = if ($humanPresenceMatch) {
    "Matches the mission."
}
elseif ($actualMinHumanPresenceSeconds -gt $missionMinHumanPresenceSeconds) {
    "The launch raises the minimum human presence threshold above the mission floor. That is stricter than requested and stays mission-compliant, but the drift is recorded."
}
elseif ($AllowMissionOverride) {
    "The launch weakens the minimum human presence threshold below the mission floor and is allowed only because -AllowMissionOverride was supplied. The run stays mission-divergent."
}
else {
    "The launch weakens the minimum human presence threshold below the mission floor and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "human_signal_threshold_min_human_presence_seconds" `
    -MissionValue $missionMinHumanPresenceSeconds `
    -ActualValue $actualMinHumanPresenceSeconds `
    -Match $humanPresenceMatch `
    -Allowed $humanPresenceAllowed `
    -ChangesExperimentMeaning $humanPresenceMeaningChange `
    -Explanation $humanPresenceExplanation
$driftFields.human_signal_threshold_min_human_presence_seconds = $field

$patchMatch = ($actualMinPatchEvents -eq $missionMinPatchEvents)
$patchAllowed = if ($patchMatch) { $true } elseif ($actualMinPatchEvents -gt $missionMinPatchEvents) { $true } else { $AllowMissionOverride }
$patchMeaningChange = $actualMinPatchEvents -lt $missionMinPatchEvents
$patchExplanation = if ($patchMatch) {
    "Matches the mission."
}
elseif ($actualMinPatchEvents -gt $missionMinPatchEvents) {
    "The launch raises the patch-while-human-present requirement above the mission floor. That is stricter than requested and stays mission-compliant, but the drift is recorded."
}
elseif ($AllowMissionOverride) {
    "The launch weakens the patch-while-human-present requirement below the mission floor and is allowed only because -AllowMissionOverride was supplied. The run stays mission-divergent."
}
else {
    "The launch weakens the patch-while-human-present requirement below the mission floor and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "patch_while_human_present_target" `
    -MissionValue $missionMinPatchEvents `
    -ActualValue $actualMinPatchEvents `
    -Match $patchMatch `
    -Allowed $patchAllowed `
    -ChangesExperimentMeaning $patchMeaningChange `
    -Explanation $patchExplanation
$driftFields.patch_while_human_present_target = $field

$postPatchMatch = [math]::Abs($actualMinPostPatchObservationSeconds - $missionMinPostPatchObservationSeconds) -lt 0.001
$postPatchAllowed = if ($postPatchMatch) { $true } elseif ($actualMinPostPatchObservationSeconds -gt $missionMinPostPatchObservationSeconds) { $true } else { $AllowMissionOverride }
$postPatchMeaningChange = $actualMinPostPatchObservationSeconds -lt $missionMinPostPatchObservationSeconds
$postPatchExplanation = if ($postPatchMatch) {
    "Matches the mission."
}
elseif ($actualMinPostPatchObservationSeconds -gt $missionMinPostPatchObservationSeconds) {
    "The launch raises the post-patch observation requirement above the mission floor. That is stricter than requested and stays mission-compliant, but the drift is recorded."
}
elseif ($AllowMissionOverride) {
    "The launch weakens the post-patch observation requirement below the mission floor and is allowed only because -AllowMissionOverride was supplied. The run stays mission-divergent."
}
else {
    "The launch weakens the post-patch observation requirement below the mission floor and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "post_patch_observation_target" `
    -MissionValue $missionMinPostPatchObservationSeconds `
    -ActualValue $actualMinPostPatchObservationSeconds `
    -Match $postPatchMatch `
    -Allowed $postPatchAllowed `
    -ChangesExperimentMeaning $postPatchMeaningChange `
    -Explanation $postPatchExplanation
$driftFields.post_patch_observation_target = $field

$skipSteamMatch = ($actualSkipSteamCmdUpdate -eq $missionSkipSteamCmdUpdate)
$skipSteamAllowed = $skipSteamMatch -or $AllowMissionOverride
$skipSteamExplanation = if ($skipSteamMatch) {
    "Matches the mission launcher defaults."
}
elseif ($AllowMissionOverride) {
    "Skipping SteamCMD update changes environment-preparation behavior and is allowed only because -AllowMissionOverride was supplied. The experiment shape stays mission-compliant, but the operational drift is recorded."
}
else {
    "Skipping SteamCMD update changes environment-preparation behavior and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "skip_steamcmd_update" `
    -MissionValue $missionSkipSteamCmdUpdate `
    -ActualValue $actualSkipSteamCmdUpdate `
    -Match $skipSteamMatch `
    -Allowed $skipSteamAllowed `
    -ChangesExperimentMeaning $false `
    -Explanation $skipSteamExplanation
$driftFields.skip_steamcmd_update = $field

$skipMetamodMatch = ($actualSkipMetamodDownload -eq $missionSkipMetamodDownload)
$skipMetamodAllowed = $skipMetamodMatch -or $AllowMissionOverride
$skipMetamodExplanation = if ($skipMetamodMatch) {
    "Matches the mission launcher defaults."
}
elseif ($AllowMissionOverride) {
    "Skipping Metamod download changes environment-preparation behavior and is allowed only because -AllowMissionOverride was supplied. The experiment shape stays mission-compliant, but the operational drift is recorded."
}
else {
    "Skipping Metamod download changes environment-preparation behavior and is blocked unless -AllowMissionOverride is supplied."
}
$field = New-DriftFieldRecord -FieldName "skip_metamod_download" `
    -MissionValue $missionSkipMetamodDownload `
    -ActualValue $actualSkipMetamodDownload `
    -Match $skipMetamodMatch `
    -Allowed $skipMetamodAllowed `
    -ChangesExperimentMeaning $false `
    -Explanation $skipMetamodExplanation
$driftFields.skip_metamod_download = $field

$outputRootMatch = ($actualOutputRoot -ieq (Get-AbsolutePath -Path $missionOutputRoot -BasePath $repoRoot))
$field = New-DriftFieldRecord -FieldName "output_root" `
    -MissionValue (Get-AbsolutePath -Path $missionOutputRoot -BasePath $repoRoot) `
    -ActualValue $actualOutputRoot `
    -Match $outputRootMatch `
    -Allowed $true `
    -ChangesExperimentMeaning $false `
    -Explanation $(if ($outputRootMatch) { "Matches the mission launcher default." } else { "Output-root drift is operator-level only and is allowed by default because it does not change the experiment semantics." })
$driftFields.output_root = $field

$evalRootMatch = ($actualEvalRoot -ieq (Get-AbsolutePath -Path $missionEvalRoot -BasePath $repoRoot))
$field = New-DriftFieldRecord -FieldName "eval_root" `
    -MissionValue (Get-AbsolutePath -Path $missionEvalRoot -BasePath $repoRoot) `
    -ActualValue $actualEvalRoot `
    -Match $evalRootMatch `
    -Allowed $true `
    -ChangesExperimentMeaning $false `
    -Explanation $(if ($evalRootMatch) { "Matches the mission launcher default." } else { "Eval-root drift is operator-level only and is allowed by default because it does not change the experiment semantics." })
$driftFields.eval_root = $field

$field = New-DriftFieldRecord -FieldName "control_treatment_semantics" `
    -MissionValue $missionSemantics `
    -ActualValue $actualSemantics `
    -Match $true `
    -Allowed $true `
    -ChangesExperimentMeaning $false `
    -Explanation "The mission runner always launches the existing paired no-AI control lane against the AI treatment lane. This semantic cannot silently drift through this helper."
$driftFields.control_treatment_semantics = $field

$driftValues = @($driftFields.GetEnumerator() | ForEach-Object { $_.Value })
$driftDetected = @($driftValues | Where-Object { -not [bool](Get-ObjectPropertyValue -Object $_ -Name "match" -Default $false) }).Count -gt 0
$blockedDriftItems = @($driftValues | Where-Object { -not [bool](Get-ObjectPropertyValue -Object $_ -Name "allowed" -Default $false) })
$blockedDrift = $blockedDriftItems.Count -gt 0
$missionMeaningDriftItems = @($driftValues | Where-Object {
    -not [bool](Get-ObjectPropertyValue -Object $_ -Name "match" -Default $false) -and
    [bool](Get-ObjectPropertyValue -Object $_ -Name "changes_experiment_meaning" -Default $false)
})
$missionDivergent = $missionMeaningDriftItems.Count -gt 0
$missionCompliant = -not $missionDivergent
$validForMissionAttainmentAnalysis = $missionCompliant

$policyVerdict = if ($blockedDrift) {
    "blocked"
}
elseif ($missionDivergent) {
    "allowed-mission-divergence"
}
elseif ($driftDetected) {
    "warned-safe-drift"
}
else {
    "mission-exact"
}

$explanation = if ($blockedDrift) {
    "Launch blocked because at least one requested parameter drifted from the mission without an explicit policy override: " + (($blockedDriftItems | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "field_name" -Default "") }) -join ", ") + "."
}
elseif ($missionDivergent) {
    "Launch divergence was explicitly allowed, but the run does not count as mission-compliant because it changes the mission meaning in: " + (($missionMeaningDriftItems | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "field_name" -Default "") }) -join ", ") + "."
}
elseif ($driftDetected) {
    "Launch stays mission-compliant, but operator-level drift was recorded in: " + ((@($driftValues | Where-Object { -not [bool](Get-ObjectPropertyValue -Object $_ -Name "match" -Default $false) }) | ForEach-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "field_name" -Default "") }) -join ", ") + "."
}
else {
    "Launch matches the current mission exactly."
}

$requestedExecutionParameters = [ordered]@{
    map = $actualMap
    bot_count = $actualBotCount
    bot_skill = $actualBotSkill
    control_port = $actualControlPort
    treatment_port = $actualTreatmentPort
    treatment_profile = $actualTreatmentProfile
    wait_for_human_join = $missionWaitForHumanJoin
    human_join_grace_seconds = $actualHumanJoinGraceSeconds
    min_human_snapshots = $actualMinHumanSnapshots
    min_human_presence_seconds = $actualMinHumanPresenceSeconds
    min_patch_events_for_usable_lane = $actualMinPatchEvents
    min_post_patch_observation_seconds = $actualMinPostPatchObservationSeconds
    output_root = $actualOutputRoot
    eval_root = $actualEvalRoot
    duration_seconds = $actualDurationSeconds
    configuration = $actualConfiguration
    platform = $actualPlatform
    skip_steamcmd_update = $actualSkipSteamCmdUpdate
    skip_metamod_download = $actualSkipMetamodDownload
    rehearsal_mode = [bool]$RehearsalMode
    rehearsal_fixture_id = if ($RehearsalMode) { $RehearsalFixtureId } else { "" }
    monitor_poll_seconds = $MonitorPollSeconds
    auto_stop_when_sufficient = [bool]$AutoStopWhenSufficient
}

$localClientDiscovery = Get-HalfLifeClientDiscovery
$controlJoinHelperCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\join_live_pair_lane.ps1 -Lane Control -Port {0} -Map {1}" -f $actualControlPort, $actualMap
$treatmentJoinHelperCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\join_live_pair_lane.ps1 -Lane Treatment -Port {0} -Map {1}" -f $actualTreatmentPort, $actualMap

$guidedRunnerArgs = [ordered]@{
    MissionJsonPath = $missionPaths.JsonPath
    Map = $actualMap
    BotCount = $actualBotCount
    BotSkill = $actualBotSkill
    ControlPort = $actualControlPort
    TreatmentPort = $actualTreatmentPort
    LabRoot = $resolvedLabRoot
    DurationSeconds = $actualDurationSeconds
    HumanJoinGraceSeconds = $actualHumanJoinGraceSeconds
    MinHumanSnapshots = $actualMinHumanSnapshots
    MinHumanPresenceSeconds = [int][Math]::Round($actualMinHumanPresenceSeconds)
    MinPatchEventsForUsableLane = $actualMinPatchEvents
    MinPostPatchObservationSeconds = [int][Math]::Round($actualMinPostPatchObservationSeconds)
    TreatmentProfile = $actualTreatmentProfile
    Configuration = $actualConfiguration
    Platform = $actualPlatform
    OutputRoot = $actualOutputRoot
    MonitorPollSeconds = $MonitorPollSeconds
}
if ($missionPaths.MarkdownPath) {
    $guidedRunnerArgs.MissionMarkdownPath = $missionPaths.MarkdownPath
}
if ($missionWaitForHumanJoin) {
    $guidedRunnerArgs.WaitForHumanJoin = $true
}
if ($actualSkipSteamCmdUpdate) {
    $guidedRunnerArgs.SkipSteamCmdUpdate = $true
}
if ($actualSkipMetamodDownload) {
    $guidedRunnerArgs.SkipMetamodDownload = $true
}
if (-not [string]::IsNullOrWhiteSpace($SteamCmdPath)) {
    $guidedRunnerArgs.SteamCmdPath = Get-AbsolutePath -Path $SteamCmdPath -BasePath $repoRoot
}
if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
    $guidedRunnerArgs.PythonPath = Get-AbsolutePath -Path $PythonPath -BasePath $repoRoot
}
if ($AutoStartMonitor) {
    $guidedRunnerArgs.AutoStartMonitor = $true
}
if ($AutoStopWhenSufficient) {
    $guidedRunnerArgs.AutoStopWhenSufficient = $true
}
if ($RunPostPipeline) {
    $guidedRunnerArgs.RunPostPipeline = $true
}
if ($RehearsalMode) {
    $guidedRunnerArgs.RehearsalMode = $true
    $guidedRunnerArgs.RehearsalFixtureId = $RehearsalFixtureId
    $guidedRunnerArgs.RehearsalStepSeconds = $RehearsalStepSeconds
}

$guidedRunnerCommandParts = @(
    "powershell",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    ".\scripts\run_guided_live_pair_session.ps1"
)
foreach ($entry in $guidedRunnerArgs.GetEnumerator()) {
    if ($entry.Value -is [bool]) {
        if ([bool]$entry.Value) {
            $guidedRunnerCommandParts += "-$($entry.Key)"
        }
    }
    else {
        $guidedRunnerCommandParts += @("-$($entry.Key)", [string]$entry.Value)
    }
}
$guidedRunnerCommand = @($guidedRunnerCommandParts | ForEach-Object { Format-ProcessArgument -Value ([string]$_) }) -join " "

$previewStamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmssfff"), $PID
$previewRoot = Ensure-Directory -Path (Join-Path (Split-Path -Path $missionPaths.JsonPath -Parent) ("mission_execution_preview\{0}" -f $previewStamp))
$previewJsonPath = Join-Path $previewRoot "mission_execution.json"
$previewMarkdownPath = Join-Path $previewRoot "mission_execution.md"

$missionExecution = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    execution_mode = if ($DryRun) { "dry-run" } elseif ($PrintCommandOnly) { "print-command-only" } else { "actual-run" }
    execution_record_status = if ($blockedDrift) { "blocked" } elseif ($DryRun -or $PrintCommandOnly) { "preview" } else { "launch-requested" }
    mission_path_used = $missionPaths.JsonPath
    mission_markdown_path_used = $missionPaths.MarkdownPath
    mission_identity = [ordered]@{
        prompt_id = [string](Get-ObjectPropertyValue -Object $mission -Name "prompt_id" -Default "")
        generated_at_utc = [string](Get-ObjectPropertyValue -Object $mission -Name "generated_at_utc" -Default "")
        sha256 = $missionHash
        current_next_live_objective = [string](Get-ObjectPropertyValue -Object $mission -Name "current_next_live_objective" -Default "")
        recommended_live_treatment_profile = [string](Get-ObjectPropertyValue -Object $mission -Name "recommended_live_treatment_profile" -Default "")
        responsive_gate_verdict = $missionGateVerdict
    }
    pair_root = ""
    guided_session_root = ""
    mission_compliant = $missionCompliant
    mission_divergent = $missionDivergent
    valid_for_mission_attainment_analysis = $validForMissionAttainmentAnalysis
    drift_policy_verdict = $policyVerdict
    explanation = $explanation
    override_switches = [ordered]@{
        allow_mission_override = [bool]$AllowMissionOverride
        allow_safe_port_override = [bool]$AllowSafePortOverride
    }
    requested_execution_parameters = $requestedExecutionParameters
    actual_launch_parameters = $requestedExecutionParameters
    drift_summary = [ordered]@{
        drift_detected = $driftDetected
        blocked = $blockedDrift
        mission_compliant = $missionCompliant
        mission_divergent = $missionDivergent
        valid_for_mission_attainment_analysis = $validForMissionAttainmentAnalysis
        policy_verdict = $policyVerdict
        explanation = $explanation
        fields = $driftFields
    }
    artifacts = [ordered]@{
        preview_json_path = $previewJsonPath
        preview_markdown_path = $previewMarkdownPath
        mission_execution_json = ""
        mission_execution_markdown = ""
    }
    guided_runner_command = $guidedRunnerCommand
}

Write-JsonFile -Path $previewJsonPath -Value $missionExecution
$missionExecutionForMarkdown = Read-JsonFile -Path $previewJsonPath
Write-TextFile -Path $previewMarkdownPath -Value (Get-MissionExecutionMarkdown -Execution $missionExecutionForMarkdown)

Write-Host "Current live mission runner:"
Write-Host "  Mission JSON: $($missionPaths.JsonPath)"
Write-Host "  Mission Markdown: $($missionPaths.MarkdownPath)"
Write-Host "  Preview execution JSON: $previewJsonPath"
Write-Host "  Preview execution Markdown: $previewMarkdownPath"
Write-Host "  Drift policy verdict: $policyVerdict"
Write-Host "  Mission compliant: $missionCompliant"
Write-Host "  Mission divergent: $missionDivergent"
Write-Host "  Valid for mission-attainment analysis: $validForMissionAttainmentAnalysis"
Write-Host "  Local client discovery: $($localClientDiscovery.discovery_verdict)"
if ($localClientDiscovery.client_path) {
    Write-Host "    Client path: $($localClientDiscovery.client_path)"
}
Write-Host "    Explanation: $($localClientDiscovery.explanation)"
Write-Host "  Control join helper: $controlJoinHelperCommand"
Write-Host "  Treatment join helper: $treatmentJoinHelperCommand"
Write-Host "  Guided runner command: $guidedRunnerCommand"

if ($PrintCommandOnly -or $DryRun) {
    if ($blockedDrift) {
        throw $explanation
    }

    [pscustomobject]@{
        MissionPath = $missionPaths.JsonPath
        MissionMarkdownPath = $missionPaths.MarkdownPath
        MissionExecutionJsonPath = $previewJsonPath
        MissionExecutionMarkdownPath = $previewMarkdownPath
        DriftPolicyVerdict = $policyVerdict
        MissionCompliant = $missionCompliant
        MissionDivergent = $missionDivergent
        GuidedRunnerCommand = $guidedRunnerCommand
    }
    return
}

if ($blockedDrift) {
    throw $explanation
}

$guidedRunnerScriptPath = Join-Path $PSScriptRoot "run_guided_live_pair_session.ps1"
$guidedRunnerArgs.MissionExecutionSeedJsonPath = $previewJsonPath
$guidedResult = & $guidedRunnerScriptPath @guidedRunnerArgs

[pscustomobject]@{
    MissionPath = $missionPaths.JsonPath
    MissionMarkdownPath = $missionPaths.MarkdownPath
    PairRoot = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "PairRoot" -Default "")
    FinalSessionDocketJsonPath = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "FinalSessionDocketJsonPath" -Default "")
    FinalSessionDocketMarkdownPath = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "FinalSessionDocketMarkdownPath" -Default "")
    MissionExecutionJsonPath = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "MissionExecutionJsonPath" -Default "")
    MissionExecutionMarkdownPath = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "MissionExecutionMarkdownPath" -Default "")
    MissionAttainmentJsonPath = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "MissionAttainmentJsonPath" -Default "")
    MissionAttainmentMarkdownPath = [string](Get-ObjectPropertyValue -Object $guidedResult -Name "MissionAttainmentMarkdownPath" -Default "")
    DriftPolicyVerdict = $policyVerdict
    MissionCompliant = $missionCompliant
    MissionDivergent = $missionDivergent
}
