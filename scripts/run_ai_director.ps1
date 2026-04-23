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
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process `
            -FilePath $pythonExe `
            -ArgumentList @($arguments + "--once") `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru `
            -Wait

        $stdoutText = Get-Content -LiteralPath $stdoutPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
            Write-Output $stdoutText.TrimEnd()
        }

        $stderrText = Get-Content -LiteralPath $stderrPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-Host $stderrText.TrimEnd()
        }

        if ($process.ExitCode -ne 0) {
            throw "AI director one-shot run failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }

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
