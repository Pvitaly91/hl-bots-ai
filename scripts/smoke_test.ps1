param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [int]$TimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot "common.ps1")

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }

$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$runtimeDir = Get-AiRuntimeDir -HldsRoot $HldsRoot
$builtDll = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform
$pluginsIni = Join-Path (Get-ServerModRoot -HldsRoot $HldsRoot) "addons\metamod\plugins.ini"
$hldsLog = Join-Path $logsRoot "hlds.stdout.log"

if (-not (Test-Path -LiteralPath $builtDll)) {
    throw "Expected built DLL is missing: $builtDll"
}

if (-not (Test-Path -LiteralPath $pluginsIni)) {
    throw "Metamod plugins.ini is missing: $pluginsIni"
}

if (-not ((Get-Content -LiteralPath $pluginsIni -Raw) -match "jk_botti_mm\.dll")) {
    throw "plugins.ini does not reference jk_botti_mm.dll"
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $telemetryExists = Test-Path -LiteralPath (Join-Path $runtimeDir "telemetry.json")
    $patchExists = Test-Path -LiteralPath (Join-Path $runtimeDir "patch.json")
    $hldsReady = (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match "plugin attaching")
    $applied = (Test-Path -LiteralPath $hldsLog) -and ((Get-Content -LiteralPath $hldsLog -Raw) -match "\[ai_balance\] applied patch=")

    if ($telemetryExists -and $patchExists -and $hldsReady -and $applied) {
        Write-Host "Smoke test passed."
        return
    }

    Start-Sleep -Seconds 2
}

throw "Smoke test timed out waiting for Metamod/jk_botti load, telemetry output, patch output, and patch application."
