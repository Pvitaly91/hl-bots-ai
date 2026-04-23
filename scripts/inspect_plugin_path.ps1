param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32"
)

. (Join-Path $PSScriptRoot "common.ps1")

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
if (-not $HldsRoot) {
    $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot
}

$deployment = Test-JKBottiLabDeployment -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform
$pluginsIniContent = Get-Content -LiteralPath $deployment.PluginsIniPath

[pscustomobject]@{
    PluginsIniPath     = $deployment.PluginsIniPath
    PluginsIniContent  = $pluginsIniContent
    PluginRelativePath = $deployment.PluginRelativePath
    BuiltDllPath       = $deployment.BuiltDllPath
    DeployedDllPath    = $deployment.DeployedDllPath
    BootstrapLogPath   = $deployment.BootstrapLogPath
    BootstrapLogExists = Test-Path -LiteralPath $deployment.BootstrapLogPath
    AiRuntimeDir       = $deployment.AiRuntimeDir
}
