param(
    [string[]]$Profiles = @(),
    [string]$OutputRoot = "",
    [string]$PythonPath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$pythonExe = Get-PythonPath -PreferredPath $PythonPath
$toolPath = Join-Path $repoRoot "ai_director\tools\run_replay_sweep.py"
$resolvedOutputRoot = if ($OutputRoot) {
    $OutputRoot
}
else {
    Join-Path (Join-Path (Get-LogsRootDefault -LabRoot (Get-LabRootDefault)) "eval\replay_sweeps") (Get-Date -Format "yyyyMMdd-HHmmss")
}
$resolvedOutputRoot = Ensure-Directory -Path $resolvedOutputRoot

$arguments = @(
    $toolPath
    "--output-root"
    $resolvedOutputRoot
)

if ($Profiles -and $Profiles.Count -gt 0) {
    $arguments += "--profiles"
    $arguments += $Profiles
}

& $pythonExe @arguments

if ($LASTEXITCODE -ne 0) {
    throw "Replay/profile sweep failed with exit code $LASTEXITCODE."
}

[pscustomobject]@{
    OutputRoot = $resolvedOutputRoot
    SummaryJson = Join-Path $resolvedOutputRoot "summary.json"
    SummaryMarkdown = Join-Path $resolvedOutputRoot "summary.md"
    ComparisonJson = Join-Path $resolvedOutputRoot "comparison.json"
    ComparisonMarkdown = Join-Path $resolvedOutputRoot "comparison.md"
}
