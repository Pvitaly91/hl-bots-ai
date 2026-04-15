Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-LabRootDefault {
    return Join-Path (Get-RepoRoot) "lab"
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-MSBuildPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $installPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($installPath) {
            $candidate = Join-Path $installPath "MSBuild\Current\Bin\MSBuild.exe"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    throw "MSBuild.exe was not found. Install Visual Studio 2022 or Build Tools with MSBuild."
}

function Get-BuildOutputPath {
    param(
        [string]$Configuration = "Release",
        [string]$Platform = "Win32"
    )

    $repoRoot = Get-RepoRoot
    return Join-Path $repoRoot "build\bin\$Configuration\$Platform\addons\jk_botti\dlls\jk_botti_mm.dll"
}

function Get-HldsRootDefault {
    param([string]$LabRoot)
    return Join-Path $LabRoot "hlds"
}

function Get-LogsRootDefault {
    param([string]$LabRoot)
    return Join-Path $LabRoot "logs"
}

function Get-ServerModRoot {
    param([string]$HldsRoot)
    return Join-Path $HldsRoot "valve"
}

function Get-AiRuntimeDir {
    param([string]$HldsRoot)
    return Join-Path (Get-ServerModRoot -HldsRoot $HldsRoot) "addons\jk_botti\runtime\ai_balance"
}

function Get-BotTestConfigTemplatePath {
    return Join-Path (Get-RepoRoot) "addons\jk_botti\test_bots.cfg"
}

function Get-BotTestConfigPath {
    param(
        [string]$ModRoot,
        [string]$Map
    )

    $configName = if ($Map -ieq "logo") { "_jk_botti_logo.cfg" } else { "jk_botti_$Map.cfg" }
    return Join-Path (Join-Path $ModRoot "addons\jk_botti") $configName
}

function Write-BotTestConfig {
    param(
        [string]$HldsRoot,
        [string]$Map,
        [int]$BotCount,
        [int]$BotSkill
    )

    if ($BotCount -lt 1 -or $BotCount -gt 31) {
        throw "BotCount must be between 1 and 31. Actual value: $BotCount"
    }

    if ($BotSkill -lt 1 -or $BotSkill -gt 5) {
        throw "BotSkill must be between 1 and 5. Actual value: $BotSkill"
    }

    $templatePath = Get-BotTestConfigTemplatePath
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Bot test config template was not found at $templatePath"
    }

    $modRoot = Ensure-Directory -Path (Get-ServerModRoot -HldsRoot $HldsRoot)
    $botAddonsRoot = Ensure-Directory -Path (Join-Path $modRoot "addons\jk_botti")
    $configPath = Join-Path $botAddonsRoot (Split-Path -Leaf (Get-BotTestConfigPath -ModRoot $modRoot -Map $Map))
    $template = Get-Content -LiteralPath $templatePath -Raw

    $botSetup = @(
        "# Launcher-selected bot pool"
        "botskill $BotSkill"
        "min_bots $BotCount"
        "max_bots $BotCount"
    )

    for ($index = 0; $index -lt $BotCount; $index++) {
        $botSetup += "addbot """" """" $BotSkill"
    }

    $rendered = $template.Replace("__MAP_NAME__", $Map)
    $rendered = $rendered.Replace("__BOT_COUNT__", [string]$BotCount)
    $rendered = $rendered.Replace("__BOT_SKILL__", [string]$BotSkill)
    $rendered = $rendered.Replace("__BOT_SETUP__", ($botSetup -join [Environment]::NewLine))

    Set-Content -LiteralPath $configPath -Value $rendered -Encoding ASCII
    return $configPath
}

function Get-PythonPath {
    param([string]$PreferredPath)

    $candidates = @()
    if ($PreferredPath) { $candidates += $PreferredPath }
    if ($env:PYTHON) { $candidates += $env:PYTHON }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd -and $pythonCmd.Source -notlike "*WindowsApps*") {
        $candidates += $pythonCmd.Source
    }

    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd) { $candidates += $pyCmd.Source }

    $candidates += @(
        "C:\Program Files\LibreOffice\program\python.exe",
        "C:\Program Files\LibreOffice\program\python-core-3.11.14\bin\python.exe"
    )

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "A usable Python 3.11+ interpreter was not found. Set -PythonPath or `$env:PYTHON."
}

function Get-SteamCmdPath {
    param(
        [string]$ToolsRoot,
        [string]$PreferredPath
    )

    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    $localSteamCmd = Join-Path $ToolsRoot "steamcmd\steamcmd.exe"
    if (Test-Path -LiteralPath $localSteamCmd) {
        return $localSteamCmd
    }

    $command = Get-Command steamcmd.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $localSteamCmd
}

function Install-SteamCmd {
    param(
        [string]$ToolsRoot,
        [string]$SteamCmdPath,
        [string]$SteamCmdUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
    )

    $steamCmdExe = Get-SteamCmdPath -ToolsRoot $ToolsRoot -PreferredPath $SteamCmdPath
    if (Test-Path -LiteralPath $steamCmdExe) {
        return $steamCmdExe
    }

    $steamCmdDir = Ensure-Directory -Path (Split-Path -Parent $steamCmdExe)
    $zipPath = Join-Path $steamCmdDir "steamcmd.zip"

    Invoke-WebRequest -Uri $SteamCmdUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $steamCmdDir -Force
    Remove-Item -LiteralPath $zipPath -Force

    return $steamCmdExe
}

function Expand-ArchiveSmart {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }

    Ensure-Directory -Path $DestinationPath | Out-Null

    if ($ArchivePath -match '\.zip$') {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
        return
    }

    if ($ArchivePath -match '\.tar\.xz$') {
        & tar -xf $ArchivePath -C $DestinationPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract archive with tar: $ArchivePath"
        }
        return
    }

    throw "Unsupported archive format: $ArchivePath"
}

function Set-LiblistToMetamod {
    param([string]$ModRoot)

    $liblistPath = Join-Path $ModRoot "liblist.gam"
    if (-not (Test-Path -LiteralPath $liblistPath)) {
        throw "liblist.gam was not found at $liblistPath"
    }

    $backupPath = "$liblistPath.original"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $liblistPath -Destination $backupPath -Force
    }

    $content = Get-Content -LiteralPath $liblistPath
    $updated = $false
    $rewritten = foreach ($line in $content) {
        if ($line -match '^\s*gamedll\s+') {
            $updated = $true
            'gamedll "addons\metamod\dlls\metamod.dll"'
        }
        else {
            $line
        }
    }

    if (-not $updated) {
        $rewritten += 'gamedll "addons\metamod\dlls\metamod.dll"'
    }

    Set-Content -LiteralPath $liblistPath -Value $rewritten -Encoding ASCII
}

function Write-MetamodPluginsIni {
    param([string]$ModRoot)

    $metamodDir = Ensure-Directory -Path (Join-Path $ModRoot "addons\metamod")
    $pluginsIni = Join-Path $metamodDir "plugins.ini"
    @(
        "; Generated by scripts/setup_test_stand.ps1"
        "win32 addons/jk_botti/dlls/jk_botti_mm.dll"
    ) | Set-Content -LiteralPath $pluginsIni -Encoding ASCII
}

function Write-ServerCfg {
    param([string]$ModRoot)

    $serverCfg = Join-Path $ModRoot "server.cfg"
    @(
        'hostname "HLDM JK_Botti AI Lab"'
        "sv_lan 1"
        "log on"
        "mp_fraglimit 30"
        "mp_timelimit 10"
    ) | Set-Content -LiteralPath $serverCfg -Encoding ASCII
}

function Copy-JKBottiLabFiles {
    param(
        [string]$HldsRoot,
        [string]$Configuration = "Release",
        [string]$Platform = "Win32"
    )

    $repoRoot = Get-RepoRoot
    $modRoot = Ensure-Directory -Path (Get-ServerModRoot -HldsRoot $HldsRoot)
    $sourceAddons = Join-Path $repoRoot "addons\jk_botti"
    $destAddons = Join-Path $modRoot "addons\jk_botti"
    $buildDll = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform

    if (-not (Test-Path -LiteralPath $buildDll)) {
        throw "Built DLL not found at $buildDll"
    }

    Ensure-Directory -Path $destAddons | Out-Null
    Copy-Item -Path (Join-Path $sourceAddons "*") -Destination $destAddons -Recurse -Force
    Copy-Item -LiteralPath $buildDll -Destination (Join-Path $destAddons "dlls\jk_botti_mm.dll") -Force

    $runtimeDir = Ensure-Directory -Path (Get-AiRuntimeDir -HldsRoot $HldsRoot)
    Get-ChildItem -LiteralPath $runtimeDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force

    Write-MetamodPluginsIni -ModRoot $modRoot
    Write-ServerCfg -ModRoot $modRoot
    Set-LiblistToMetamod -ModRoot $modRoot
}
