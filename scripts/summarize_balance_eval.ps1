param(
    [Parameter(Mandatory = $true)]
    [string]$LaneRoot,
    [string]$CompareLaneRoot = "",
    [string]$OutputJson = "",
    [string]$OutputMarkdown = "",
    [string]$PythonPath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$pythonExe = Get-PythonPath -PreferredPath $PythonPath
$toolPath = Join-Path $repoRoot "ai_director\tools\summarize_eval.py"

$arguments = @(
    $toolPath
    "--lane-root"
    $LaneRoot
)

if ($CompareLaneRoot) {
    $arguments += @("--compare-lane-root", $CompareLaneRoot)
}

if ($OutputJson) {
    $arguments += @("--output-json", $OutputJson)
}

if ($OutputMarkdown) {
    $arguments += @("--output-md", $OutputMarkdown)
}

& $pythonExe @arguments

if ($LASTEXITCODE -ne 0) {
    throw "Balance evaluation summary generation failed with exit code $LASTEXITCODE."
}

[pscustomobject]@{
    LaneRoot       = $LaneRoot
    CompareLaneRoot = $CompareLaneRoot
    OutputJson     = if ($OutputJson) { $OutputJson } else { Join-Path $LaneRoot "summary.json" }
    OutputMarkdown = if ($OutputMarkdown) { $OutputMarkdown } else { Join-Path $LaneRoot "summary.md" }
}
