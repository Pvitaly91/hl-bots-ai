param(
    [string]$Map = "stalkyard",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [string]$LabRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [int]$MaxPlayers = 8,
    [int]$Port = 27015,
    [string]$Hostname = "HLDM JK_Botti AI Lab",
    [int]$StartupWaitSeconds = 5,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload
)

. (Join-Path $PSScriptRoot "common.ps1")

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$Tail = 20
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return ((Get-Content -LiteralPath $Path -Tail $Tail) -join [Environment]::NewLine).Trim()
}

if ($BotCount -lt 1 -or $BotCount -gt 31) {
    throw "BotCount must be between 1 and 31. Actual value: $BotCount"
}

if ($BotSkill -lt 1 -or $BotSkill -gt 5) {
    throw "BotSkill must be between 1 and 5. Actual value: $BotSkill"
}

if ($StartupWaitSeconds -lt 1) {
    throw "StartupWaitSeconds must be at least 1 second."
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
$HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
$ToolsRoot = Ensure-Directory -Path (Join-Path $LabRoot "tools")
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)

if ($MaxPlayers -lt ($BotCount + 1)) {
    $MaxPlayers = [Math]::Min(32, $BotCount + 1)
}

$mode = if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) { "offline fallback" } else { "OpenAI" }

Write-Host "Resolved test-stand settings:"
Write-Host "  Map: $Map"
Write-Host "  Bot count: $BotCount"
Write-Host "  Bot skill: $BotSkill"
Write-Host "  Lab root: $LabRoot"
Write-Host "  HLDS root: $HldsRoot"
Write-Host "  Logs root: $logsRoot"
Write-Host "  Mode: $mode"
Write-Host "  Max players: $MaxPlayers"
Write-Host "  Port: $Port"

& (Join-Path $PSScriptRoot "build_vs2022.ps1") -Configuration $Configuration -Platform $Platform
Stop-LabProcesses -HldsRoot $HldsRoot

$setupArgs = @{
    LabRoot       = $LabRoot
    HldsRoot      = $HldsRoot
    ToolsRoot     = $ToolsRoot
    SteamCmdPath  = $SteamCmdPath
    Configuration = $Configuration
    Platform      = $Platform
    SkipBuild     = $true
}

if ($SkipSteamCmdUpdate) {
    $setupArgs.SkipSteamCmdUpdate = $true
}

if ($SkipMetamodDownload) {
    $setupArgs.SkipMetamodDownload = $true
}

& (Join-Path $PSScriptRoot "setup_test_stand.ps1") @setupArgs

$aiProcess = $null
$serverProcess = $null
$botConfigPath = $null
$deployment = Test-JKBottiLabDeployment -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform
$aiStdout = Join-Path $logsRoot "ai_director.stdout.log"
$aiStderr = Join-Path $logsRoot "ai_director.stderr.log"
$hldsStdout = Join-Path $logsRoot "hlds.stdout.log"
$hldsStderr = Join-Path $logsRoot "hlds.stderr.log"

Write-Host "Verified plugin deployment:"
Write-Host "  plugins.ini: $($deployment.PluginsIniPath)"
Write-Host "  plugin path: $($deployment.PluginRelativePath)"
Write-Host "  deployed DLL: $($deployment.DeployedDllPath)"
Write-Host "  bootstrap log: $($deployment.BootstrapLogPath)"

try {
    $aiProcess = & (Join-Path $PSScriptRoot "run_ai_director.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -PythonPath $PythonPath -PassThru
    $serverProcess = & (Join-Path $PSScriptRoot "run_server.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -Map $Map -BotCount $BotCount -BotSkill $BotSkill -MaxPlayers $MaxPlayers -Port $Port -Hostname $Hostname -UseTestBotConfig -PassThru

    $botConfigPath = Get-BotTestConfigPath -ModRoot (Get-ServerModRoot -HldsRoot $HldsRoot) -Map $Map

    if (-not (Test-Path -LiteralPath $botConfigPath)) {
        throw "Expected generated bot config was not found: $botConfigPath"
    }

    Start-Sleep -Seconds $StartupWaitSeconds
    $aiProcess.Refresh()
    $serverProcess.Refresh()

    foreach ($logPath in @($aiStdout, $aiStderr, $hldsStdout, $hldsStderr)) {
        if (-not (Test-Path -LiteralPath $logPath)) {
            throw "Expected launcher log file was not created: $logPath"
        }
    }

    if ($aiProcess.HasExited) {
        $aiTail = Get-LogTailText -Path $aiStderr
        throw "AI director exited during startup. See $aiStdout and $aiStderr. $aiTail"
    }

    if ($serverProcess.HasExited) {
        $stdoutTail = Get-LogTailText -Path $hldsStdout
        $stderrTail = Get-LogTailText -Path $hldsStderr
        throw "HLDS exited during startup. See $hldsStdout and $hldsStderr. STDOUT: $stdoutTail STDERR: $stderrTail"
    }
}
catch {
    foreach ($process in @($serverProcess, $aiProcess)) {
        if ($null -ne $process) {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force
            }
        }
    }

    throw
}

[pscustomobject]@{
    AiDirectorPid = $aiProcess.Id
    HldsPid       = $serverProcess.Id
    BotConfigPath = $botConfigPath
    LogsRoot      = $logsRoot
    BootstrapLogPath = $deployment.BootstrapLogPath
    Mode          = $mode
}
