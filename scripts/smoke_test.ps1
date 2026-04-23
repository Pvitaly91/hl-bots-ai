param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$Map = "stalkyard",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [ValidateSet("Auto", "AI", "NoAI")]
    [string]$Mode = "Auto",
    [int]$TimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot "common.ps1")

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$Tail = 20
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return ((Get-Content -LiteralPath $Path -Tail $Tail) -join [Environment]::NewLine).Trim()
}

function Get-FirstMatchLine {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $match = $Text | Select-String -Pattern $Pattern | Select-Object -First 1
    if ($match) {
        return $match.Line.Trim()
    }

    return ""
}

function Get-BotConfigInfo {
    param(
        [string]$Path,
        [int]$BotCount,
        [int]$BotSkill
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Expected generated bot config was not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch "(?m)^botskill\s+$BotSkill\s*$") {
        throw "Generated bot test config does not contain the requested botskill: $Path"
    }

    if ($content -notmatch "(?m)^min_bots\s+$BotCount\s*$") {
        throw "Generated bot test config does not contain the requested min_bots value: $Path"
    }

    if ($content -notmatch "(?m)^max_bots\s+$BotCount\s*$") {
        throw "Generated bot test config does not contain the requested max_bots value: $Path"
    }

    $addbotMatches = [regex]::Matches($content, "(?m)^addbot\b")
    if ($addbotMatches.Count -ne $BotCount) {
        throw "Generated bot test config contains $($addbotMatches.Count) addbot lines, expected ${BotCount}: $Path"
    }

    [pscustomobject]@{
        Path        = $Path
        Content     = $content
        AiDisabled  = $content -match "(?m)^\s*jk_ai_balance_enabled\s+0\s*$"
    }
}

function Resolve-SmokeMode {
    param(
        [string]$RequestedMode,
        [bool]$AiDisabled
    )

    switch ($RequestedMode) {
        "AI" { return "AI" }
        "NoAI" { return "NoAI" }
        default {
            if ($AiDisabled) { return "NoAI" }
            return "AI"
        }
    }
}

function Invoke-FallbackAiValidation {
    param(
        [string]$LabRoot,
        [string]$HldsRoot
    )

    $validationRuntime = Ensure-Directory -Path (Join-Path $LabRoot "validation\runtime")
    $validationPatch = Join-Path $validationRuntime "patch.json"
    $validationTelemetry = Join-Path $validationRuntime "telemetry.json"

    @'
{
  "schema_version": 1,
  "match_id": "validation-match",
  "telemetry_sequence": 8,
  "timestamp_utc": "2026-04-16T00:00:00Z",
  "server_time_seconds": 180.0,
  "map_name": "stalkyard",
  "human_player_count": 2,
  "bot_count": 2,
  "top_human_frags": 20,
  "top_human_deaths": 7,
  "top_bot_frags": 10,
  "top_bot_deaths": 13,
  "recent_human_kills_per_minute": 11,
  "recent_bot_kills_per_minute": 4,
  "frag_gap_top_human_minus_top_bot": 10,
  "current_default_bot_skill_level": 3,
  "active_balance": {
    "pause_frequency_scale": 1.0,
    "battle_strafe_scale": 1.0,
    "interval_seconds": 20.0,
    "cooldown_seconds": 30.0,
    "enabled": 1
  }
}
'@ | Set-Content -LiteralPath $validationTelemetry -Encoding ASCII

    if (Test-Path -LiteralPath $validationPatch) {
        Remove-Item -LiteralPath $validationPatch -Force
    }

    $savedApiKey = $null
    $hadApiKey = Test-Path env:OPENAI_API_KEY
    if ($hadApiKey) {
        $savedApiKey = $env:OPENAI_API_KEY
        Remove-Item env:OPENAI_API_KEY
    }

    try {
        & (Join-Path $PSScriptRoot "run_ai_director.ps1") -LabRoot $LabRoot -HldsRoot $HldsRoot -RuntimeDir $validationRuntime -Once
    }
    finally {
        if ($hadApiKey) {
            $env:OPENAI_API_KEY = $savedApiKey
        }
    }

    if (-not (Test-Path -LiteralPath $validationPatch)) {
        throw "Fallback AI validation did not produce patch.json in $validationRuntime"
    }

    $validationPatchJson = Get-Content -LiteralPath $validationPatch -Raw | ConvertFrom-Json
    if ($validationPatchJson.target_skill_level -lt 1 -or $validationPatchJson.target_skill_level -gt 5) {
        throw "Fallback AI validation produced an out-of-range target_skill_level: $($validationPatchJson.target_skill_level)"
    }

    if ($validationPatchJson.bot_count_delta -lt -1 -or $validationPatchJson.bot_count_delta -gt 1) {
        throw "Fallback AI validation produced an out-of-range bot_count_delta: $($validationPatchJson.bot_count_delta)"
    }

    if ($validationPatchJson.pause_frequency_scale -lt 0.85 -or $validationPatchJson.pause_frequency_scale -gt 1.15) {
        throw "Fallback AI validation produced an out-of-range pause_frequency_scale: $($validationPatchJson.pause_frequency_scale)"
    }

    if ($validationPatchJson.battle_strafe_scale -lt 0.85 -or $validationPatchJson.battle_strafe_scale -gt 1.15) {
        throw "Fallback AI validation produced an out-of-range battle_strafe_scale: $($validationPatchJson.battle_strafe_scale)"
    }
}

function Get-SmokeSnapshot {
    param(
        [string]$HldsRoot,
        [string]$LogsRoot,
        [string]$BootstrapLogPath,
        [string]$TelemetryPath,
        [string]$PatchPath,
        [string]$PluginDllPath
    )

    $hldsStdout = Join-Path $LogsRoot "hlds.stdout.log"
    $hldsStderr = Join-Path $LogsRoot "hlds.stderr.log"
    $hldsStdoutText = if (Test-Path -LiteralPath $hldsStdout) { Get-Content -LiteralPath $hldsStdout -Raw } else { "" }
    $bootstrapText = if (Test-Path -LiteralPath $BootstrapLogPath) { Get-Content -LiteralPath $BootstrapLogPath -Raw } else { "" }
    $labProcesses = @(Get-LabProcesses -HldsRoot $HldsRoot)
    $hldsProcess = $labProcesses | Where-Object { $_.Name -ieq "hlds.exe" } | Select-Object -First 1
    $aiProcess = $labProcesses | Where-Object { $_.Name -ieq "python.exe" } | Select-Object -First 1
    $aiBalanceWarningLine = Get-FirstMatchLine -Text $hldsStdoutText -Pattern "unknown command: 'jk_ai_balance_[^']*'"

    [pscustomobject]@{
        HldsStdoutPath        = $hldsStdout
        HldsStderrPath        = $hldsStderr
        HldsRunning           = $null -ne $hldsProcess
        MetamodLoaded         = $hldsStdoutText -match "Metamod version"
        PluginDllExists       = Test-Path -LiteralPath $PluginDllPath
        BootstrapLogExists    = Test-Path -LiteralPath $BootstrapLogPath
        AttachLogged          = $hldsStdoutText -match "plugin attaching"
        DllLoaded             = $bootstrapText -match "DllMain result=process_attach"
        GiveFnptrsReached     = $bootstrapText -match "GiveFnptrsToDll result=success"
        MetaQueryEntered      = $bootstrapText -match "Meta_Query result=entered"
        MetaQuerySucceeded    = $bootstrapText -match "Meta_Query result=success"
        MetaQueryFailureLine  = Get-FirstMatchLine -Text $bootstrapText -Pattern "Meta_Query result=failure"
        MetaAttachEntered     = $bootstrapText -match "Meta_Attach result=entered"
        MetaAttachSucceeded   = $bootstrapText -match "Meta_Attach result=success"
        MetaAttachFailureLine = Get-FirstMatchLine -Text $bootstrapText -Pattern "Meta_Attach result=failure"
        AiSidecarRunning      = $null -ne $aiProcess
        AiBalanceWarningLine  = $aiBalanceWarningLine
        TelemetryExists       = Test-Path -LiteralPath $TelemetryPath
        PatchExists           = Test-Path -LiteralPath $PatchPath
        PatchApplied          = $hldsStdoutText -match "\[ai_balance\] applied patch="
        HldsStdoutTail        = Get-LogTailText -Path $hldsStdout
        HldsStderrTail        = Get-LogTailText -Path $hldsStderr
        BootstrapTail         = Get-LogTailText -Path $BootstrapLogPath
        BootstrapLogPath      = $BootstrapLogPath
    }
}

function New-SmokeStatus {
    param(
        [string]$Code,
        [string]$Summary,
        [bool]$Success = $false,
        [bool]$Terminal = $false,
        [string]$Detail = ""
    )

    [pscustomobject]@{
        Code     = $Code
        Summary  = $Summary
        Success  = $Success
        Terminal = $Terminal
        Detail   = $Detail
    }
}

function Get-SmokeStatus {
    param(
        [pscustomobject]$Snapshot,
        [string]$ResolvedMode
    )

    if (-not $Snapshot.HldsRunning -and -not (Test-Path -LiteralPath $Snapshot.HldsStdoutPath)) {
        return New-SmokeStatus -Code "hlds-did-not-start" -Summary "HLDS did not start." -Detail "No HLDS process or stdout log is present yet."
    }

    if (-not $Snapshot.MetamodLoaded) {
        return New-SmokeStatus -Code "metamod-did-not-load" -Summary "Metamod did not load." -Detail "HLDS started, but the stdout log does not contain the Metamod banner yet."
    }

    if (-not $Snapshot.PluginDllExists) {
        return New-SmokeStatus -Code "plugin-dll-file-missing" -Summary "Metamod loaded but the configured plugin DLL file is missing." -Terminal $true
    }

    if ($Snapshot.AttachLogged -and -not $Snapshot.BootstrapLogExists) {
        return New-SmokeStatus -Code "plugin-attached-but-bootstrap-log-missing" -Summary "The plugin attached, but the bootstrap log is missing." -Terminal $true
    }

    if ($Snapshot.MetaQueryFailureLine) {
        return New-SmokeStatus -Code "plugin-loaded-but-meta-query-failed" -Summary "The plugin loaded but Meta_Query failed." -Terminal $true -Detail $Snapshot.MetaQueryFailureLine
    }

    if ($Snapshot.MetaAttachFailureLine) {
        return New-SmokeStatus -Code "plugin-passed-meta-query-but-did-not-attach" -Summary "The plugin passed Meta_Query but Meta_Attach failed." -Terminal $true -Detail $Snapshot.MetaAttachFailureLine
    }

    if ($Snapshot.DllLoaded -and -not $Snapshot.MetaQueryEntered -and -not $Snapshot.MetaQuerySucceeded) {
        return New-SmokeStatus -Code "plugin-dll-loaded-but-meta-query-not-reached" -Summary "The plugin DLL loaded, but Meta_Query was never reached." -Terminal $true
    }

    if (-not $Snapshot.DllLoaded) {
        return New-SmokeStatus -Code "plugin-dll-load-failed" -Summary "Metamod loaded, but the plugin DLL did not reach DllMain." -Detail "Bootstrap log has no DLL_PROCESS_ATTACH entry."
    }

    if ($Snapshot.MetaQuerySucceeded -and -not $Snapshot.MetaAttachEntered -and -not $Snapshot.MetaAttachSucceeded) {
        return New-SmokeStatus -Code "plugin-passed-meta-query-but-did-not-attach" -Summary "The plugin passed Meta_Query but Meta_Attach was not reached." -Terminal $true
    }

    if ($Snapshot.AiBalanceWarningLine) {
        return New-SmokeStatus -Code "plugin-attached-but-config-warning-present" -Summary "The plugin attached, but the bot config still triggered an avoidable jk_ai_balance warning." -Terminal $true -Detail $Snapshot.AiBalanceWarningLine
    }

    if ($ResolvedMode -eq "NoAI") {
        if ($Snapshot.AiSidecarRunning) {
            return New-SmokeStatus -Code "no-ai-path-active-but-sidecar-running" -Summary "The no-AI path attached, but an AI sidecar process is still running." -Terminal $true
        }

        if ($Snapshot.PatchExists) {
            return New-SmokeStatus -Code "no-ai-path-active-but-unexpected-patch-output" -Summary "The no-AI path attached, but patch.json exists unexpectedly." -Terminal $true
        }

        if ($Snapshot.MetaAttachSucceeded -and $Snapshot.AttachLogged) {
            return New-SmokeStatus -Code "no-ai-healthy" -Summary "The no-AI path is healthy: plugin attached, bootstrap log is present, no AI sidecar is running, and no patch path is expected." -Success $true -Terminal $true
        }
    }

    if (-not $Snapshot.AiSidecarRunning) {
        return New-SmokeStatus -Code "ai-sidecar-not-yet-running" -Summary "The plugin attached, but the AI sidecar is not running yet."
    }

    if ($Snapshot.MetaAttachSucceeded -and -not $Snapshot.TelemetryExists) {
        return New-SmokeStatus -Code "plugin-attached-but-no-telemetry" -Summary "The plugin attached but no telemetry has been emitted yet."
    }

    if ($Snapshot.TelemetryExists -and -not $Snapshot.PatchExists) {
        return New-SmokeStatus -Code "telemetry-emitted-but-no-patch-path-yet" -Summary "Telemetry was emitted, but patch.json has not appeared yet."
    }

    if ($Snapshot.PatchExists -and -not $Snapshot.PatchApplied) {
        return New-SmokeStatus -Code "telemetry-and-patch-emitted-but-no-apply-log-yet" -Summary "Telemetry and patch files exist, but the patch application log has not appeared yet."
    }

    if ($Snapshot.PatchApplied) {
        return New-SmokeStatus -Code "ai-healthy" -Summary "The AI path is healthy: plugin attached, bootstrap log is present, the AI sidecar is running, telemetry and patch paths work, and patch application was observed." -Success $true -Terminal $true
    }

    return New-SmokeStatus -Code "plugin-passed-meta-query-but-did-not-attach" -Summary "The plugin passed Meta_Query but did not attach yet."
}

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }

$repoRoot = Get-RepoRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $LabRoot)
$runtimeDir = Get-AiRuntimeDir -HldsRoot $HldsRoot
$launcherBat = Join-Path $repoRoot "scripts\run_test_stand_with_bots.bat"
$launcherPs1 = Join-Path $repoRoot "scripts\run_test_stand_with_bots.ps1"
$standardLauncherBat = Join-Path $repoRoot "scripts\run_standard_bots_crossfire.bat"
$standardLauncherPs1 = Join-Path $repoRoot "scripts\run_standard_bots_crossfire.ps1"
$botTemplate = Get-BotTestConfigTemplatePath
$botConfigPath = Get-BotTestConfigPath -ModRoot (Get-ServerModRoot -HldsRoot $HldsRoot) -Map $Map
$pluginsIni = Get-MetamodPluginsIniPath -ModRoot (Get-ServerModRoot -HldsRoot $HldsRoot)
$bootstrapLog = Get-PluginBootstrapLogPath -HldsRoot $HldsRoot
$telemetryPath = Join-Path $runtimeDir "telemetry.json"
$patchPath = Join-Path $runtimeDir "patch.json"
$builtDll = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform

foreach ($requiredPath in @($launcherBat, $launcherPs1, $standardLauncherBat, $standardLauncherPs1, $botTemplate, $builtDll, $pluginsIni)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required path is missing: $requiredPath"
    }
}

$pluginRelativePath = Get-ConfiguredMetamodPluginRelativePath -PluginsIniPath $pluginsIni
$pluginDllPath = Get-DeployedPluginPath -HldsRoot $HldsRoot -RelativePath $pluginRelativePath
$botConfigInfo = Get-BotConfigInfo -Path $botConfigPath -BotCount $BotCount -BotSkill $BotSkill
$resolvedMode = Resolve-SmokeMode -RequestedMode $Mode -AiDisabled $botConfigInfo.AiDisabled

if ($resolvedMode -eq "AI") {
    Invoke-FallbackAiValidation -LabRoot $LabRoot -HldsRoot $HldsRoot
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $snapshot = Get-SmokeSnapshot -HldsRoot $HldsRoot -LogsRoot $logsRoot -BootstrapLogPath $bootstrapLog -TelemetryPath $telemetryPath -PatchPath $patchPath -PluginDllPath $pluginDllPath
    $status = Get-SmokeStatus -Snapshot $snapshot -ResolvedMode $resolvedMode

    if ($status.Success) {
        [pscustomobject]@{
            Status             = $status.Code
            Summary            = $status.Summary
            Mode               = $resolvedMode
            BotConfigPath      = $botConfigInfo.Path
            PluginsIniPath   = $pluginsIni
            PluginRelativePath = $pluginRelativePath
            PluginDllPath      = $pluginDllPath
            BootstrapLogPath   = $bootstrapLog
            BootstrapLogExists = $snapshot.BootstrapLogExists
            AiSidecarRunning   = $snapshot.AiSidecarRunning
            TelemetryPath      = $telemetryPath
            TelemetryExists    = $snapshot.TelemetryExists
            PatchPath          = $patchPath
            PatchExists        = $snapshot.PatchExists
            PatchApplied       = $snapshot.PatchApplied
        }
        return
    }

    if ($status.Terminal) {
        break
    }

    Start-Sleep -Seconds 2
}

$snapshot = Get-SmokeSnapshot -HldsRoot $HldsRoot -LogsRoot $logsRoot -BootstrapLogPath $bootstrapLog -TelemetryPath $telemetryPath -PatchPath $patchPath -PluginDllPath $pluginDllPath
$status = Get-SmokeStatus -Snapshot $snapshot -ResolvedMode $resolvedMode
$detailSuffix = if ($status.Detail) { " Detail: $($status.Detail)" } else { "" }
throw "Smoke status '$($status.Code)': $($status.Summary)$detailSuffix STDOUT tail: $($snapshot.HldsStdoutTail) STDERR tail: $($snapshot.HldsStderrTail) Bootstrap tail: $($snapshot.BootstrapTail)"
