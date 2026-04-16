param(
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [string]$LabRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$SteamCmdPath = "",
    [int]$MaxPlayers = 0,
    [int]$Port = 27015,
    [string]$Hostname = "HLDM JK_Botti Standard Lab",
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

Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

if ($StartupWaitSeconds -lt 1) {
    throw "StartupWaitSeconds must be at least 1 second."
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
$HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
$ToolsRoot = Ensure-Directory -Path (Join-Path $LabRoot "tools")
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)

if ($MaxPlayers -lt 1 -or $MaxPlayers -lt ($BotCount + 1)) {
    $MaxPlayers = [Math]::Min(32, $BotCount + 1)
}

Write-Host "Resolved standard jk_botti launcher settings:"
Write-Host "  Map: $Map"
Write-Host "  Bot count: $BotCount"
Write-Host "  Bot skill: $BotSkill"
Write-Host "  Lab root: $LabRoot"
Write-Host "  HLDS root: $HldsRoot"
Write-Host "  Logs root: $logsRoot"
Write-Host "  AI sidecar: disabled"
Write-Host "  AI balance: disabled (jk_ai_balance_enabled 0)"
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

$serverProcess = $null
$botConfigPath = $null
$hldsStdout = Join-Path $logsRoot "hlds.stdout.log"
$hldsStderr = Join-Path $logsRoot "hlds.stderr.log"

try {
    $botConfigPath = Write-StandardBotTestConfig -HldsRoot $HldsRoot -Map $Map -BotCount $BotCount -BotSkill $BotSkill
    if (-not (Test-Path -LiteralPath $botConfigPath)) {
        throw "Expected generated bot config was not found: $botConfigPath"
    }

    $botConfig = Get-Content -LiteralPath $botConfigPath -Raw
    if (-not $botConfig.Contains("jk_ai_balance_enabled 0")) {
        throw "Generated standard bot config did not disable AI balance: $botConfigPath"
    }

    Write-Host "Generated standard bot config: $botConfigPath"

    $serverProcess = & (Join-Path $PSScriptRoot "run_server.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -Map $Map -MaxPlayers $MaxPlayers -Port $Port -Hostname $Hostname -PassThru

    Start-Sleep -Seconds $StartupWaitSeconds
    $serverProcess.Refresh()

    foreach ($logPath in @($hldsStdout, $hldsStderr)) {
        if (-not (Test-Path -LiteralPath $logPath)) {
            throw "Expected launcher log file was not created: $logPath"
        }
    }

    if ($serverProcess.HasExited) {
        $stdoutTail = Get-LogTailText -Path $hldsStdout
        $stderrTail = Get-LogTailText -Path $hldsStderr
        throw "HLDS exited during startup. See $hldsStdout and $hldsStderr. STDOUT: $stdoutTail STDERR: $stderrTail"
    }

    $runningAiDirector = Get-LabProcesses -HldsRoot $HldsRoot | Where-Object { $_.Name -ieq "python.exe" }
    if ($runningAiDirector) {
        throw "AI director process is still running for this lab after standard launcher startup."
    }
}
catch {
    if ($null -ne $serverProcess) {
        $serverProcess.Refresh()
        if (-not $serverProcess.HasExited) {
            Stop-Process -Id $serverProcess.Id -Force
        }
    }

    throw
}

[pscustomobject]@{
    HldsPid          = $serverProcess.Id
    BotConfigPath    = $botConfigPath
    LogsRoot         = $logsRoot
    AiSidecarStarted = $false
    AiBalanceEnabled = 0
}
