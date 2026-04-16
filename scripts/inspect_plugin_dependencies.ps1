param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [switch]$UseDeployedDll
)

. (Join-Path $PSScriptRoot "common.ps1")

if (-not $HldsRoot) {
    $LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
    $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
}

$dllPath = if ($UseDeployedDll) {
    (Test-JKBottiLabDeployment -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform).DeployedDllPath
}
else {
    Get-BuildOutputPath -Configuration $Configuration -Platform $Platform
}

if (-not (Test-Path -LiteralPath $dllPath)) {
    throw "DLL was not found at $dllPath"
}

$dumpbin = Get-DumpbinPath
$dependentsOutput = & $dumpbin /dependents $dllPath
$dependents = @($dependentsOutput | Select-String -Pattern '^\s+[A-Za-z0-9_]+\.(dll|DLL)$' | ForEach-Object { $_.Line.Trim() })

[xml]$project = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) "jk_botti_mm.vcxproj")
$releaseRuntime = ($project.Project.ItemDefinitionGroup | Where-Object { $_.Condition -eq '''$(Configuration)|$(Platform)''==''Release|Win32''' }).ClCompile.RuntimeLibrary
$debugRuntime = ($project.Project.ItemDefinitionGroup | Where-Object { $_.Condition -eq '''$(Configuration)|$(Platform)''==''Debug|Win32''' }).ClCompile.RuntimeLibrary

[pscustomobject]@{
    DllPath                = $dllPath
    ReleaseRuntimeLibrary  = $releaseRuntime
    DebugRuntimeLibrary    = $debugRuntime
    Dependents             = $dependents
}
