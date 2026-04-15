param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$ToolsRoot = "",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$Map = "stalkyard",
    [switch]$SkipSetup
)

. (Join-Path $PSScriptRoot "common.ps1")

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path $LabRoot "tools" }

if (-not $SkipSetup) {
    & (Join-Path $PSScriptRoot "setup_test_stand.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -ToolsRoot $ToolsRoot -SteamCmdPath $SteamCmdPath -Configuration $Configuration -Platform $Platform
}

$aiProcess = & (Join-Path $PSScriptRoot "run_ai_director.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -PythonPath $PythonPath -PassThru
$serverProcess = & (Join-Path $PSScriptRoot "run_server.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -Map $Map -PassThru

[pscustomobject]@{
    AiDirectorPid = $aiProcess.Id
    HldsPid       = $serverProcess.Id
    RuntimeDir    = Get-AiRuntimeDir -HldsRoot $HldsRoot
}
