param(
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$ControlPort = 27016,
    [int]$TreatmentPort = 27017,
    [string]$LabRoot = "",
    [int]$DurationSeconds = 80,
    [switch]$WaitForHumanJoin,
    [int]$HumanJoinGraceSeconds = 120,
    [int]$MinHumanSnapshots = -1,
    [int]$MinHumanPresenceSeconds = -1,
    [int]$MinPatchEventsForUsableLane = -1,
    [ValidateSet("conservative", "default", "responsive")]
    [string]$TreatmentProfile = "conservative",
    [string]$ControlLaneLabel = "control-baseline",
    [string]$TreatmentLaneLabel = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
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

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-LaneJoinInstructionsText {
    param(
        [string]$RoleName,
        [string]$Mode,
        [string]$LaneLabel,
        [object]$JoinInfo,
        [string]$PairRoot,
        [int]$MinHumanPresenceSeconds,
        [string]$TreatmentProfileName
    )

    $lines = @(
        "HLDM paired live-session lane instructions",
        "Role: $RoleName",
        "Lane label: $LaneLabel",
        "Mode: $Mode",
        "Loopback join target: $($JoinInfo.LoopbackAddress)",
        "Loopback console command: $($JoinInfo.ConsoleCommand)",
        "Steam connect URI: $($JoinInfo.SteamConnectUri)"
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$JoinInfo.LanAddress)) {
        $lines += "LAN join target: $($JoinInfo.LanAddress)"
        $lines += "LAN console command: $($JoinInfo.LanConsoleCommand)"
    }

    if ($Mode -eq "AI") {
        $lines += "Treatment profile: $TreatmentProfileName"
    }

    $lines += @(
        "Useful human session target: keep at least one human in-lane for about $MinHumanPresenceSeconds seconds or longer.",
        "If no humans join, this lane stays plumbing-valid at most and should not be treated as tuning evidence.",
        "Pair pack root: $PairRoot"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-PairJoinInstructionsText {
    param(
        [object]$ControlJoinInfo,
        [string]$ControlLaneLabel,
        [object]$TreatmentJoinInfo,
        [string]$TreatmentLaneLabel,
        [string]$TreatmentProfileName,
        [string]$PairRoot,
        [int]$MinHumanPresenceSeconds,
        [int]$HumanJoinGraceSeconds
    )

    $lines = @(
        "HLDM paired control vs treatment instructions",
        "Sequence: run/join the no-AI control lane first, then the AI treatment lane.",
        "Control lane: $ControlLaneLabel",
        "Control loopback join target: $($ControlJoinInfo.LoopbackAddress)",
        "Treatment lane: $TreatmentLaneLabel",
        "Treatment loopback join target: $($TreatmentJoinInfo.LoopbackAddress)",
        "Treatment profile: $TreatmentProfileName",
        "Useful human session target: keep a human in each lane for about $MinHumanPresenceSeconds seconds or longer.",
        "Treatment becomes most interpretable when it patches while humans are present and there is time to observe the aftermath.",
        "If humans never join, the pair should be treated as insufficient-data only.",
        "If humans join briefly, the pair should be treated as weak-signal.",
        "After the run, review pair_summary.md first, then comparison.md, or run scripts\review_latest_pair_run.ps1.",
        "Human-join grace window: $HumanJoinGraceSeconds seconds",
        "Pair pack root: $PairRoot"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-OperatorNoteClassification {
    param(
        [object]$ControlSummary,
        [object]$TreatmentSummary,
        [object]$Comparison
    )

    $comparisonVerdict = [string]$Comparison.comparison_verdict
    if ($comparisonVerdict -eq "comparison-strong-signal") {
        return "strong-signal"
    }
    if ($comparisonVerdict -eq "comparison-usable") {
        return "tuning-usable"
    }

    $controlPlumbingHealthy = ([string]$ControlSummary.smoke_status -eq "no-ai-healthy")
    $treatmentPlumbingHealthy = ([string]$TreatmentSummary.smoke_status -in @("ai-healthy", "simulated"))
    $controlUsable = [bool]$ControlSummary.tuning_signal_usable
    $treatmentUsable = [bool]$TreatmentSummary.tuning_signal_usable

    if ($controlPlumbingHealthy -and $treatmentPlumbingHealthy -and -not $controlUsable -and -not $treatmentUsable) {
        return "plumbing-valid only"
    }

    return "partially usable"
}

function Get-OperatorNoteText {
    param(
        [string]$Classification,
        [object]$ControlSummary,
        [object]$TreatmentSummary,
        [object]$Comparison
    )

    $baseReason = [string]$Comparison.comparison_explanation
    switch ($Classification) {
        "strong-signal" {
            return "Strong-signal: both lanes were human-usable, treatment patched while humans were present, and multiple grounded post-patch windows were captured. $baseReason"
        }
        "tuning-usable" {
            return "Tuning-usable: both lanes were human-usable and treatment produced grounded live evidence after a human-present patch. $baseReason"
        }
        "plumbing-valid only" {
            return "Plumbing-valid only: both launch paths worked, but neither lane captured enough human signal to support tuning claims. $baseReason"
        }
        default {
            return "Partially usable: at least one lane captured some useful signal, but the pair is still not strong enough for a fair control-vs-treatment conclusion. $baseReason"
        }
    }
}

function Get-PairSummaryMarkdown {
    param(
        [object]$PairSummary
    )

    $lines = @(
        "# Control vs Treatment Pair Summary",
        "",
        "- Pair classification: $($PairSummary.operator_note_classification)",
        "- Comparison verdict: $($PairSummary.comparison.comparison_verdict)",
        "- Explanation: $($PairSummary.comparison.comparison_explanation)",
        "- Operator note: $($PairSummary.operator_note)",
        "- Pair pack root: $($PairSummary.pair_root)",
        "",
        "## Control Lane",
        "",
        "- Lane label: $($PairSummary.control_lane.lane_label)",
        "- Mode: $($PairSummary.control_lane.mode)",
        "- Port: $($PairSummary.control_lane.port)",
        "- Lane verdict: $($PairSummary.control_lane.lane_verdict)",
        "- Evidence quality: $($PairSummary.control_lane.evidence_quality)",
        "- Behavior verdict: $($PairSummary.control_lane.behavior_verdict)",
        "- Human snapshots: $($PairSummary.control_lane.human_snapshots_count)",
        "- Seconds with human presence: $($PairSummary.control_lane.seconds_with_human_presence)",
        "- Session pack: $($PairSummary.control_lane.session_pack_json)",
        "- Join instructions: $($PairSummary.control_lane.join_instructions)",
        "",
        "## Treatment Lane",
        "",
        "- Lane label: $($PairSummary.treatment_lane.lane_label)",
        "- Mode: $($PairSummary.treatment_lane.mode)",
        "- Port: $($PairSummary.treatment_lane.port)",
        "- Treatment profile: $($PairSummary.treatment_lane.treatment_profile)",
        "- Lane verdict: $($PairSummary.treatment_lane.lane_verdict)",
        "- Evidence quality: $($PairSummary.treatment_lane.evidence_quality)",
        "- Behavior verdict: $($PairSummary.treatment_lane.behavior_verdict)",
        "- Human snapshots: $($PairSummary.treatment_lane.human_snapshots_count)",
        "- Seconds with human presence: $($PairSummary.treatment_lane.seconds_with_human_presence)",
        "- Patched while humans present: $($PairSummary.comparison.treatment_patched_while_humans_present)",
        "- Meaningful post-patch observation window: $($PairSummary.comparison.meaningful_post_patch_observation_window_exists)",
        "- Treatment pre/post trend: $($PairSummary.comparison.treatment_pre_post_trend_classification)",
        "- Treatment relative to control: $($PairSummary.comparison.treatment_relative_to_control)",
        "- Apparent benefit too weak to trust: $($PairSummary.comparison.apparent_benefit_too_weak_to_trust)",
        "- Session pack: $($PairSummary.treatment_lane.session_pack_json)",
        "- Join instructions: $($PairSummary.treatment_lane.join_instructions)",
        "",
        "## Pair Artifacts",
        "",
        "- Comparison JSON: $($PairSummary.artifacts.comparison_json)",
        "- Comparison Markdown: $($PairSummary.artifacts.comparison_markdown)",
        "- Combined join instructions: $($PairSummary.artifacts.pair_join_instructions)",
        "- Control join instructions: $($PairSummary.artifacts.control_join_instructions)",
        "- Treatment join instructions: $($PairSummary.artifacts.treatment_join_instructions)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

if ($ControlPort -lt 1 -or $ControlPort -gt 65535) {
    throw "ControlPort must be between 1 and 65535."
}
if ($TreatmentPort -lt 1 -or $TreatmentPort -gt 65535) {
    throw "TreatmentPort must be between 1 and 65535."
}
if ($ControlPort -eq $TreatmentPort) {
    throw "ControlPort and TreatmentPort must differ."
}
if ($DurationSeconds -lt 5) {
    throw "DurationSeconds must be at least 5 seconds."
}
if ($HumanJoinGraceSeconds -lt 5) {
    throw "HumanJoinGraceSeconds must be at least 5 seconds."
}

$resolvedTuningProfile = Get-TuningProfileDefinition -Name $TreatmentProfile
if (-not $PSBoundParameters.ContainsKey("MinHumanSnapshots")) {
    $MinHumanSnapshots = [int]$resolvedTuningProfile.evaluation.min_human_snapshots
}
if (-not $PSBoundParameters.ContainsKey("MinHumanPresenceSeconds")) {
    $MinHumanPresenceSeconds = [int][Math]::Round([double]$resolvedTuningProfile.evaluation.min_human_presence_seconds)
}
if (-not $PSBoundParameters.ContainsKey("MinPatchEventsForUsableLane")) {
    $MinPatchEventsForUsableLane = [int]$resolvedTuningProfile.evaluation.min_patch_events_for_usable_lane
}

if ($MinHumanSnapshots -lt 1) {
    throw "MinHumanSnapshots must be at least 1."
}
if ($MinHumanPresenceSeconds -lt 1) {
    throw "MinHumanPresenceSeconds must be at least 1."
}
if ($MinPatchEventsForUsableLane -lt 0) {
    throw "MinPatchEventsForUsableLane cannot be negative."
}

$waitForHumanJoinEnabled = $true
if ($PSBoundParameters.ContainsKey("WaitForHumanJoin")) {
    $waitForHumanJoinEnabled = [bool]$WaitForHumanJoin
}

$TreatmentLaneLabel = if ($TreatmentLaneLabel) {
    $TreatmentLaneLabel.Trim()
}
else {
    "treatment-$($resolvedTuningProfile.name)"
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$pairOutputBase = if ($OutputRoot) { $OutputRoot } else { Join-Path $logsRoot "eval\pairs" }
$pairOutputBase = Ensure-Directory -Path $pairOutputBase

$pairStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$pairFolderName = "{0}-{1}-b{2}-s{3}-cp{4}-tp{5}" -f $pairStamp, $Map, $BotCount, $BotSkill, $ControlPort, $TreatmentPort
$pairRoot = Ensure-Directory -Path (Join-Path $pairOutputBase $pairFolderName)
$controlLaneOutputRoot = Ensure-Directory -Path (Join-Path $pairRoot "lanes\control")
$treatmentLaneOutputRoot = Ensure-Directory -Path (Join-Path $pairRoot "lanes\treatment")

$controlJoinInfo = Get-HldsJoinInfo -Port $ControlPort
$treatmentJoinInfo = Get-HldsJoinInfo -Port $TreatmentPort
$controlJoinInstructionsPath = Join-Path $pairRoot "control_join_instructions.txt"
$treatmentJoinInstructionsPath = Join-Path $pairRoot "treatment_join_instructions.txt"
$pairJoinInstructionsPath = Join-Path $pairRoot "pair_join_instructions.txt"

Write-TextFile -Path $controlJoinInstructionsPath -Value (
    Get-LaneJoinInstructionsText `
        -RoleName "Control baseline" `
        -Mode "NoAI" `
        -LaneLabel $ControlLaneLabel `
        -JoinInfo $controlJoinInfo `
        -PairRoot $pairRoot `
        -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
        -TreatmentProfileName ""
)
Write-TextFile -Path $treatmentJoinInstructionsPath -Value (
    Get-LaneJoinInstructionsText `
        -RoleName "Treatment" `
        -Mode "AI" `
        -LaneLabel $TreatmentLaneLabel `
        -JoinInfo $treatmentJoinInfo `
        -PairRoot $pairRoot `
        -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
        -TreatmentProfileName $resolvedTuningProfile.name
)
Write-TextFile -Path $pairJoinInstructionsPath -Value (
    Get-PairJoinInstructionsText `
        -ControlJoinInfo $controlJoinInfo `
        -ControlLaneLabel $ControlLaneLabel `
        -TreatmentJoinInfo $treatmentJoinInfo `
        -TreatmentLaneLabel $TreatmentLaneLabel `
        -TreatmentProfileName $resolvedTuningProfile.name `
        -PairRoot $pairRoot `
        -MinHumanPresenceSeconds $MinHumanPresenceSeconds `
        -HumanJoinGraceSeconds $HumanJoinGraceSeconds
)

$operatorChecklistPath = Join-Path (Get-RepoRoot) "docs\operator-checklist.md"
$reviewHelperCommand = "powershell -NoProfile -File .\scripts\review_latest_pair_run.ps1 -PairRoot `"$pairRoot`""

Write-Host "Paired control+treatment evaluation:"
Write-Host "  Pair pack root: $pairRoot"
Write-Host "  Map: $Map"
Write-Host "  Bot count: $BotCount"
Write-Host "  Bot skill: $BotSkill"
Write-Host "  Duration seconds per lane: $DurationSeconds"
Write-Host "  Wait for human join: $waitForHumanJoinEnabled"
Write-Host "  Human join grace seconds: $HumanJoinGraceSeconds"
Write-Host "  Minimum human snapshots: $MinHumanSnapshots"
Write-Host "  Minimum human presence seconds: $MinHumanPresenceSeconds"
Write-Host "  Minimum treatment patch events for usable lane: $MinPatchEventsForUsableLane"
Write-Host "Operator join plan:"
Write-Host "  CONTROL lane (join first): $ControlLaneLabel"
Write-Host "    Role: no-AI control baseline"
Write-Host "    Loopback join target: $($controlJoinInfo.LoopbackAddress)"
Write-Host "    Console command: $($controlJoinInfo.ConsoleCommand)"
if (-not [string]::IsNullOrWhiteSpace([string]$controlJoinInfo.LanAddress)) {
    Write-Host "    LAN join target: $($controlJoinInfo.LanAddress)"
}
Write-Host "    Join instructions: $controlJoinInstructionsPath"
Write-Host "  TREATMENT lane (join second): $TreatmentLaneLabel"
Write-Host "    Role: AI treatment"
Write-Host "    Loopback join target: $($treatmentJoinInfo.LoopbackAddress)"
Write-Host "    Console command: $($treatmentJoinInfo.ConsoleCommand)"
if (-not [string]::IsNullOrWhiteSpace([string]$treatmentJoinInfo.LanAddress)) {
    Write-Host "    LAN join target: $($treatmentJoinInfo.LanAddress)"
}
Write-Host "    Treatment profile: $($resolvedTuningProfile.name)"
Write-Host "    Join instructions: $treatmentJoinInstructionsPath"
Write-Host "Success means:"
Write-Host "  Keep at least one human in each lane for about $MinHumanPresenceSeconds seconds."
Write-Host "  Treatment is strongest when it patches while humans are present and there is time to observe the aftermath."
Write-Host "  No-human or sparse-human runs are plumbing validation only, not tuning evidence."
Write-Host "After the run:"
Write-Host "  Review helper: $reviewHelperCommand"
Write-Host "  Pair join instructions: $pairJoinInstructionsPath"
Write-Host "  Operator checklist: $operatorChecklistPath"

$sharedEvalArgs = @{
    Map = $Map
    BotCount = $BotCount
    BotSkill = $BotSkill
    LabRoot = $LabRoot
    DurationSeconds = $DurationSeconds
    HumanJoinGraceSeconds = $HumanJoinGraceSeconds
    MinHumanSnapshots = $MinHumanSnapshots
    MinHumanPresenceSeconds = $MinHumanPresenceSeconds
    MinPatchEventsForUsableLane = $MinPatchEventsForUsableLane
    Configuration = $Configuration
    Platform = $Platform
    SteamCmdPath = $SteamCmdPath
}

if ($PythonPath) {
    $sharedEvalArgs.PythonPath = $PythonPath
}
if ($waitForHumanJoinEnabled) {
    $sharedEvalArgs.WaitForHumanJoin = $true
}
if ($SkipSteamCmdUpdate) {
    $sharedEvalArgs.SkipSteamCmdUpdate = $true
}
if ($SkipMetamodDownload) {
    $sharedEvalArgs.SkipMetamodDownload = $true
}

Write-Host "Running control lane..."
$controlResult = & (Join-Path $PSScriptRoot "run_balance_eval.ps1") `
    @sharedEvalArgs `
    -Mode "NoAI" `
    -Port $ControlPort `
    -LaneLabel $ControlLaneLabel `
    -OutputRoot $controlLaneOutputRoot

Write-Host "Control lane finished."
Write-Host "  Summary JSON: $($controlResult.SummaryJsonPath)"
Write-Host "  Session pack JSON: $($controlResult.SessionPackJsonPath)"

Write-Host "Running treatment lane..."
$treatmentResult = & (Join-Path $PSScriptRoot "run_balance_eval.ps1") `
    @sharedEvalArgs `
    -Mode "AI" `
    -Port $TreatmentPort `
    -LaneLabel $TreatmentLaneLabel `
    -TuningProfile $resolvedTuningProfile.name `
    -OutputRoot $treatmentLaneOutputRoot

Write-Host "Treatment lane finished."
Write-Host "  Summary JSON: $($treatmentResult.SummaryJsonPath)"
Write-Host "  Session pack JSON: $($treatmentResult.SessionPackJsonPath)"

$comparisonJsonPath = Join-Path $pairRoot "comparison.json"
$comparisonMarkdownPath = Join-Path $pairRoot "comparison.md"

$comparisonResult = & (Join-Path $PSScriptRoot "summarize_balance_eval.ps1") `
    -LaneRoot $controlResult.LaneRoot `
    -CompareLaneRoot $treatmentResult.LaneRoot `
    -OutputJson $comparisonJsonPath `
    -OutputMarkdown $comparisonMarkdownPath `
    -PythonPath $PythonPath

$comparisonPayload = Read-JsonFile -Path $comparisonResult.OutputJson
if ($null -eq $comparisonPayload) {
    throw "Pair comparison summary was not generated: $comparisonJsonPath"
}

$controlSummary = $comparisonPayload.primary_lane
$treatmentSummary = $comparisonPayload.secondary_lane
$comparisonSummary = $comparisonPayload.comparison
$operatorClassification = Get-OperatorNoteClassification `
    -ControlSummary $controlSummary `
    -TreatmentSummary $treatmentSummary `
    -Comparison $comparisonSummary
$operatorNote = Get-OperatorNoteText `
    -Classification $operatorClassification `
    -ControlSummary $controlSummary `
    -TreatmentSummary $treatmentSummary `
    -Comparison $comparisonSummary

$pairSummaryJsonPath = Join-Path $pairRoot "pair_summary.json"
$pairSummaryMarkdownPath = Join-Path $pairRoot "pair_summary.md"

$pairSummary = [ordered]@{
    schema_version = 1
    prompt_id = "HLDM-JKBOTTI-AI-STAND-20260415-19"
    pair_id = $pairFolderName
    pair_root = $pairRoot
    map = $Map
    bot_count = $BotCount
    bot_skill = $BotSkill
    duration_seconds = $DurationSeconds
    wait_for_human_join = $waitForHumanJoinEnabled
    human_join_grace_seconds = $HumanJoinGraceSeconds
    min_human_snapshots = $MinHumanSnapshots
    min_human_presence_seconds = $MinHumanPresenceSeconds
    min_patch_events_for_usable_lane = $MinPatchEventsForUsableLane
    treatment_profile = $resolvedTuningProfile.name
    control_lane = [ordered]@{
        lane_root = $controlResult.LaneRoot
        lane_label = $ControlLaneLabel
        mode = "NoAI"
        port = $ControlPort
        join_target = $controlJoinInfo.LoopbackAddress
        join_instructions = $controlJoinInstructionsPath
        session_pack_json = $controlResult.SessionPackJsonPath
        session_pack_markdown = $controlResult.SessionPackMarkdownPath
        summary_json = $controlResult.SummaryJsonPath
        summary_markdown = $controlResult.SummaryMarkdownPath
        lane_verdict = [string]$controlSummary.lane_quality_verdict
        evidence_quality = [string]$controlSummary.evidence_quality
        behavior_verdict = [string]$controlSummary.behavior_verdict
        human_snapshots_count = [int]$controlSummary.human_snapshots_count
        seconds_with_human_presence = [double]$controlSummary.seconds_with_human_presence
    }
    treatment_lane = [ordered]@{
        lane_root = $treatmentResult.LaneRoot
        lane_label = $TreatmentLaneLabel
        mode = "AI"
        port = $TreatmentPort
        treatment_profile = $resolvedTuningProfile.name
        join_target = $treatmentJoinInfo.LoopbackAddress
        join_instructions = $treatmentJoinInstructionsPath
        session_pack_json = $treatmentResult.SessionPackJsonPath
        session_pack_markdown = $treatmentResult.SessionPackMarkdownPath
        summary_json = $treatmentResult.SummaryJsonPath
        summary_markdown = $treatmentResult.SummaryMarkdownPath
        lane_verdict = [string]$treatmentSummary.lane_quality_verdict
        evidence_quality = [string]$treatmentSummary.evidence_quality
        behavior_verdict = [string]$treatmentSummary.behavior_verdict
        human_snapshots_count = [int]$treatmentSummary.human_snapshots_count
        seconds_with_human_presence = [double]$treatmentSummary.seconds_with_human_presence
    }
    comparison = $comparisonSummary
    operator_note_classification = $operatorClassification
    operator_note = $operatorNote
    artifacts = [ordered]@{
        comparison_json = $comparisonJsonPath
        comparison_markdown = $comparisonMarkdownPath
        pair_summary_json = $pairSummaryJsonPath
        pair_summary_markdown = $pairSummaryMarkdownPath
        pair_join_instructions = $pairJoinInstructionsPath
        control_join_instructions = $controlJoinInstructionsPath
        treatment_join_instructions = $treatmentJoinInstructionsPath
    }
}

Write-JsonFile -Path $pairSummaryJsonPath -Value $pairSummary
Write-TextFile -Path $pairSummaryMarkdownPath -Value (Get-PairSummaryMarkdown -PairSummary $pairSummary)

Write-Host "Pair evaluation finished."
Write-Host "  Pair pack root: $pairRoot"
Write-Host "  Pair summary JSON: $pairSummaryJsonPath"
Write-Host "  Pair summary Markdown: $pairSummaryMarkdownPath"
Write-Host "  Comparison JSON: $comparisonJsonPath"
Write-Host "  Comparison Markdown: $comparisonMarkdownPath"
Write-Host "  Operator note: $operatorNote"
Write-Host "  Next step: $reviewHelperCommand"
Write-Host "  Operator checklist: $operatorChecklistPath"

[pscustomobject]@{
    PairRoot = $pairRoot
    ControlLaneRoot = $controlResult.LaneRoot
    TreatmentLaneRoot = $treatmentResult.LaneRoot
    ControlSummaryJsonPath = $controlResult.SummaryJsonPath
    TreatmentSummaryJsonPath = $treatmentResult.SummaryJsonPath
    PairSummaryJsonPath = $pairSummaryJsonPath
    PairSummaryMarkdownPath = $pairSummaryMarkdownPath
    ComparisonJsonPath = $comparisonJsonPath
    ComparisonMarkdownPath = $comparisonMarkdownPath
    ControlJoinInstructionsPath = $controlJoinInstructionsPath
    TreatmentJoinInstructionsPath = $treatmentJoinInstructionsPath
    PairJoinInstructionsPath = $pairJoinInstructionsPath
    ComparisonVerdict = [string]$comparisonSummary.comparison_verdict
    OperatorNoteClassification = $operatorClassification
    TreatmentProfile = $resolvedTuningProfile.name
    ReviewCommand = $reviewHelperCommand
    OperatorChecklistPath = $operatorChecklistPath
}
