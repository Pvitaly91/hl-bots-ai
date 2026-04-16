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
$headers = & $dumpbin /headers $dllPath
$exports = & $dumpbin /exports $dllPath

$machineLine = (($headers | Select-String -Pattern 'machine \((x86|x64)\)') | Select-Object -First 1).Line.Trim()
$magicLine = (($headers | Select-String -Pattern 'magic #') | Select-Object -First 1).Line.Trim()
$requiredExports = foreach ($name in @('GiveFnptrsToDll', 'Meta_Query', 'Meta_Attach', 'Meta_Detach')) {
    $line = (($exports | Select-String -Pattern ([regex]::Escape($name))) | Select-Object -First 1)
    if ($line) { $line.Line.Trim() }
}

[pscustomobject]@{
    DllPath          = $dllPath
    Machine          = $machineLine
    OptionalHeader   = $magicLine
    RequiredExports  = $requiredExports
}
