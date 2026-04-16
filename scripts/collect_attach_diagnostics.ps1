param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [int]$Tail = 40
)

. (Join-Path $PSScriptRoot "common.ps1")

function Get-TailText {
    param(
        [string]$Path,
        [int]$Tail = 40
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return Get-Content -LiteralPath $Path -Tail $Tail
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
if (-not $HldsRoot) {
    $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
}

$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$pathInfo = & (Join-Path $PSScriptRoot "inspect_plugin_path.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform
$exportInfo = & (Join-Path $PSScriptRoot "inspect_plugin_exports.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform -UseDeployedDll
$dependencyInfo = & (Join-Path $PSScriptRoot "inspect_plugin_dependencies.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform -UseDeployedDll

[pscustomobject]@{
    PathInfo            = $pathInfo
    ExportInfo          = $exportInfo
    DependencyInfo      = $dependencyInfo
    HldsStdoutLog       = Join-Path $logsRoot "hlds.stdout.log"
    HldsStdoutTail      = Get-TailText -Path (Join-Path $logsRoot "hlds.stdout.log") -Tail $Tail
    HldsStderrLog       = Join-Path $logsRoot "hlds.stderr.log"
    HldsStderrTail      = Get-TailText -Path (Join-Path $logsRoot "hlds.stderr.log") -Tail $Tail
    BootstrapLogTail    = Get-TailText -Path $pathInfo.BootstrapLogPath -Tail $Tail
    TelemetryPath       = Join-Path $pathInfo.AiRuntimeDir "telemetry.json"
    TelemetryExists     = Test-Path -LiteralPath (Join-Path $pathInfo.AiRuntimeDir "telemetry.json")
    PatchPath           = Join-Path $pathInfo.AiRuntimeDir "patch.json"
    PatchExists         = Test-Path -LiteralPath (Join-Path $pathInfo.AiRuntimeDir "patch.json")
}
