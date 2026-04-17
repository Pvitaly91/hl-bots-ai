param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$RuntimeDir = "",
    [string]$PythonPath = "",
    [string]$TuningProfile = "default",
    [double]$PollInterval = 5,
    [switch]$Once,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot "common.ps1")

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }
if (-not $RuntimeDir) { $RuntimeDir = Get-AiRuntimeDir -HldsRoot $HldsRoot }

$RuntimeDir = Ensure-Directory -Path $RuntimeDir
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$pythonExe = Get-PythonPath -PreferredPath $PythonPath
$repoRoot = Get-RepoRoot
$mainPath = Join-Path $repoRoot "ai_director\main.py"

$arguments = @(
    $mainPath
    "--runtime-dir", $RuntimeDir
    "--poll-interval", "$PollInterval"
    "--tuning-profile", $TuningProfile
)

if ($Once) {
    & $pythonExe @arguments --once
    return
}

$stdout = Join-Path $logsRoot "ai_director.stdout.log"
$stderr = Join-Path $logsRoot "ai_director.stderr.log"

$process = Start-Process -FilePath $pythonExe -ArgumentList $arguments -WorkingDirectory $repoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

if ($PassThru) {
    $process
}
else {
    Write-Host "AI director started with PID $($process.Id)"
}
