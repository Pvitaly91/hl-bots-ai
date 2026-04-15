param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Map = "stalkyard",
    [int]$MaxPlayers = 8,
    [int]$Port = 27015,
    [string]$Hostname = "HLDM JK_Botti AI Lab",
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

$arguments = @(
    "-console"
    "-game", "valve"
    "-insecure"
    "+maxplayers", "$MaxPlayers"
    "+map", $Map
    "+sv_lan", "1"
    "+port", "$Port"
    "+hostname", $Hostname
    "+mp_fraglimit", "30"
    "+mp_timelimit", "10"
)

$stdout = Join-Path $logsRoot "hlds.stdout.log"
$stderr = Join-Path $logsRoot "hlds.stderr.log"

$process = Start-Process -FilePath $hldsExe -ArgumentList $arguments -WorkingDirectory $HldsRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

if ($PassThru) {
    $process
}
else {
    Write-Host "HLDS started with PID $($process.Id)"
}
