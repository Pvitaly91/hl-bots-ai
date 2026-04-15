param(
    [string]$Configuration = "Release",
    [string]$Platform = "Win32"
)

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$solution = Join-Path $repoRoot "hl-bots-ai.sln"
$msbuild = Get-MSBuildPath

if (-not (Test-Path -LiteralPath $solution)) {
    throw "Solution file not found at $solution"
}

& $msbuild $solution /t:Build /p:Configuration=$Configuration /p:Platform=$Platform /m

$dllPath = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform
if (-not (Test-Path -LiteralPath $dllPath)) {
    throw "Expected output DLL was not produced: $dllPath"
}

Write-Host "Built $dllPath"
