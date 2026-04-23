[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("Control", "Treatment")]
    [string]$Lane,
    [string]$PairRoot = "",
    [switch]$UseLatest,
    [string]$ClientExePath = "",
    [string]$Map = "",
    [int]$Port = -1,
    [string]$LabRoot = "",
    [string]$ServerHost = "127.0.0.1",
    [switch]$DryRun,
    [switch]$PrintOnly
)

. (Join-Path $PSScriptRoot "common.ps1")

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Find-LatestPairRoot {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        throw "No eval root was available for -UseLatest: $Root"
    }

    $candidate = Get-ChildItem -LiteralPath $Root -Filter "pair_summary.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        throw "No pair_summary.json was found under $Root"
    }

    return $candidate.DirectoryName
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Resolve-NormalizedPathCandidate -Path $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$resolvedPairRoot = Resolve-ExistingPath -Path (Resolve-NormalizedPathCandidate -Path $PairRoot)
$resolvedMap = $Map
$resolvedPort = $Port
$pairSummaryPath = ""
$joinInstructionsPath = ""

if (-not $resolvedPairRoot -and ($UseLatest -or $resolvedPort -lt 1)) {
    $resolvedPairRoot = Find-LatestPairRoot -Root (Get-EvalRootDefault -LabRoot $resolvedLabRoot)
}

$pairSummary = $null
if ($resolvedPairRoot) {
    $pairSummaryPath = Join-Path $resolvedPairRoot "pair_summary.json"
    $pairSummary = Read-JsonFile -Path $pairSummaryPath
    if ($null -eq $pairSummary) {
        throw "Pair root does not contain a readable pair_summary.json: $resolvedPairRoot"
    }

    if ([string]::IsNullOrWhiteSpace($resolvedMap)) {
        $resolvedMap = [string]$pairSummary.map
    }

    $laneBlock = if ($Lane -eq "Control") { $pairSummary.control_lane } else { $pairSummary.treatment_lane }
    if ($null -eq $laneBlock) {
        throw "Lane '$Lane' was not present in the pair summary: $pairSummaryPath"
    }

    if ($resolvedPort -lt 1) {
        $resolvedPort = [int]$laneBlock.port
    }

    $joinInstructionsPath = Resolve-ExistingPath -Path ([string]$laneBlock.join_instructions)
}

if ($resolvedPort -lt 1 -or $resolvedPort -gt 65535) {
    throw "A valid port is required. Use -PairRoot/-UseLatest or pass -Port directly."
}

$launchPlan = Get-HalfLifeClientLaunchPlan -PreferredClientPath $ClientExePath -ServerHost $ServerHost -Port $resolvedPort
$joinInfo = $launchPlan.join_info
$launchAllowed = [bool]$launchPlan.launchable
$resultVerdict = if ($launchAllowed) {
    if ($DryRun -or $PrintOnly) { "client-ready-dry-run" } else { "client-launch-started" }
}
else {
    "client-prereq-missing"
}

$explanation = if ($launchAllowed) {
    "Resolved the $Lane lane target and prepared the local client launch command."
}
else {
    "Half-Life client launch is not available in this environment. {0}" -f [string]$launchPlan.client_discovery.explanation
}

Write-Host "Live pair lane join helper:"
Write-Host "  Lane: $Lane"
Write-Host "  Pair root: $resolvedPairRoot"
Write-Host "  Pair summary JSON: $pairSummaryPath"
Write-Host "  Map: $resolvedMap"
Write-Host "  Join target: $($joinInfo.LoopbackAddress)"
Write-Host "  Console command: $($joinInfo.ConsoleCommand)"
if ($joinInstructionsPath) {
    Write-Host "  Join instructions: $joinInstructionsPath"
}
Write-Host "  Client discovery verdict: $($launchPlan.client_discovery.discovery_verdict)"
Write-Host "  Client path: $($launchPlan.client_exe_path)"
Write-Host "  Client working directory: $($launchPlan.client_working_directory)"
Write-Host "  Launch allowed: $launchAllowed"
Write-Host "  Explanation: $explanation"
if ($launchPlan.command_text) {
    Write-Host "  Launch command: $($launchPlan.command_text)"
}
if ($launchPlan.qconsole_path) {
    Write-Host "  Client qconsole log: $($launchPlan.qconsole_path)"
}
if ($launchPlan.debug_log_path) {
    Write-Host "  Client debug log: $($launchPlan.debug_log_path)"
}

$processId = 0
$launchStartedAtUtc = ""
if (-not ($DryRun -or $PrintOnly)) {
    if (-not $launchAllowed) {
        throw $explanation
    }

    $launchStartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $startProcessParams = @{
        FilePath = $launchPlan.client_exe_path
        ArgumentList = $launchPlan.arguments
        PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($launchPlan.client_working_directory)) {
        $startProcessParams["WorkingDirectory"] = $launchPlan.client_working_directory
    }
    $process = Start-Process @startProcessParams
    $processId = $process.Id
    Write-Host "  Half-Life client started with PID $processId"
}

[pscustomobject]@{
    ResultVerdict = $resultVerdict
    Explanation = $explanation
    Lane = $Lane
    PairRoot = $resolvedPairRoot
    PairSummaryJsonPath = $pairSummaryPath
    Map = $resolvedMap
    Port = $resolvedPort
    JoinTarget = $joinInfo.LoopbackAddress
    ConsoleCommand = $joinInfo.ConsoleCommand
    JoinInstructionsPath = $joinInstructionsPath
    ClientDiscoveryVerdict = [string]$launchPlan.client_discovery.discovery_verdict
    ClientExePath = [string]$launchPlan.client_exe_path
    ClientWorkingDirectory = [string]$launchPlan.client_working_directory
    QConsolePath = [string]$launchPlan.qconsole_path
    DebugLogPath = [string]$launchPlan.debug_log_path
    LaunchAllowed = $launchAllowed
    LaunchCommand = [string]$launchPlan.command_text
    LaunchStartedAtUtc = $launchStartedAtUtc
    DryRun = [bool]($DryRun -or $PrintOnly)
    ProcessId = $processId
}
