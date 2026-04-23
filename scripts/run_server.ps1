param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Map = "stalkyard",
    [int]$BotCount = 0,
    [int]$BotSkill = 0,
    [int]$MaxPlayers = 8,
    [int]$Port = 27015,
    [string]$Hostname = "HLDM JK_Botti AI Lab",
    [ValidateRange(0, 1)][int]$SvLan = 1,
    [string]$RconPassword = "",
    [int]$FragLimit = 30,
    [int]$TimeLimit = 10,
    [switch]$UseTestBotConfig,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot "common.ps1")

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }

$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$hldsExe = Join-Path $HldsRoot "hlds.exe"

if (-not (Test-Path -LiteralPath $hldsExe)) {
    throw "hlds.exe was not found at $hldsExe. Run scripts/setup_test_stand.ps1 first."
}

if ($UseTestBotConfig) {
    if ($BotCount -lt 1) {
        throw "BotCount must be greater than zero when -UseTestBotConfig is set."
    }

    if ($BotSkill -lt 1) {
        throw "BotSkill must be between 1 and 5 when -UseTestBotConfig is set."
    }

    if ($MaxPlayers -lt ($BotCount + 1)) {
        $MaxPlayers = [Math]::Min(32, $BotCount + 1)
    }

    $botConfigPath = Write-BotTestConfig -HldsRoot $HldsRoot -Map $Map -BotCount $BotCount -BotSkill $BotSkill
    Write-Host "Generated bot test config: $botConfigPath"
}

$arguments = @(
    "-console"
    "-game", "valve"
    "-insecure"
    "+maxplayers", "$MaxPlayers"
    "+map", $Map
    "+sv_lan", "$SvLan"
    "+port", "$Port"
    "+hostname", $Hostname
    "+mp_fraglimit", "$FragLimit"
    "+mp_timelimit", "$TimeLimit"
)

if (-not [string]::IsNullOrWhiteSpace($RconPassword)) {
    $arguments += @("+rcon_password", $RconPassword)
}

$stdout = Join-Path $logsRoot "hlds.stdout.log"
$stderr = Join-Path $logsRoot "hlds.stderr.log"

$process = Start-Process -FilePath $hldsExe -ArgumentList $arguments -WorkingDirectory $HldsRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

if ($PassThru) {
    $process
}
else {
    Write-Host "HLDS started with PID $($process.Id)"
}
