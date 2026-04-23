param(
    [string]$LabRoot = "",
    [string]$HldsRoot = "",
    [string]$ToolsRoot = "",
    [string]$SteamCmdPath = "",
    [string]$SteamCmdUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip",
    [string]$MetamodUrl = "https://github.com/Bots-United/metamod-p/releases/download/v1.21p38/metamod_i686_linux_win32-1.21p38.tar.xz",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [switch]$SkipBuild
)

. (Join-Path $PSScriptRoot "common.ps1")

$LabRoot = if ($LabRoot) { $LabRoot } else { Get-LabRootDefault }
$LabRoot = Ensure-Directory -Path $LabRoot
if (-not $HldsRoot) { $HldsRoot = Get-HldsRootDefault -LabRoot $LabRoot }
if (-not $ToolsRoot) { $ToolsRoot = Join-Path $LabRoot "tools" }

$HldsRoot = Ensure-Directory -Path $HldsRoot
$ToolsRoot = Ensure-Directory -Path $ToolsRoot

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "build_vs2022.ps1") -Configuration $Configuration -Platform $Platform
}

$steamCmdExe = Install-SteamCmd -ToolsRoot $ToolsRoot -SteamCmdPath $SteamCmdPath -SteamCmdUrl $SteamCmdUrl

if (-not $SkipSteamCmdUpdate) {
    & $steamCmdExe +force_install_dir $HldsRoot +login anonymous +app_set_config 90 mod valve +app_update 90 validate +quit
}

$modRoot = Ensure-Directory -Path (Get-ServerModRoot -HldsRoot $HldsRoot)

if (-not $SkipMetamodDownload) {
    $metamodArchive = Join-Path $ToolsRoot ([System.IO.Path]::GetFileName(([Uri]$MetamodUrl).AbsolutePath))
    $extractDir = Join-Path $ToolsRoot "metamod-p"
    $metamodDest = Ensure-Directory -Path (Join-Path $modRoot "addons\metamod")
    $legacyLayout = Join-Path $extractDir "addons\metamod"
    $flatDll = Join-Path $extractDir "metamod.dll"
    $existingPayloadAvailable = (Test-Path -LiteralPath $legacyLayout) -or (Test-Path -LiteralPath $flatDll)

    if (-not $existingPayloadAvailable -and (Test-Path -LiteralPath $metamodArchive)) {
        Expand-ArchiveSmart -ArchivePath $metamodArchive -DestinationPath $extractDir
        $existingPayloadAvailable = (Test-Path -LiteralPath $legacyLayout) -or (Test-Path -LiteralPath $flatDll)
    }

    if (-not $existingPayloadAvailable) {
        Invoke-WebRequest -Uri $MetamodUrl -OutFile $metamodArchive
        Expand-ArchiveSmart -ArchivePath $metamodArchive -DestinationPath $extractDir
    }
    else {
        try {
            Invoke-WebRequest -Uri $MetamodUrl -OutFile $metamodArchive
            Expand-ArchiveSmart -ArchivePath $metamodArchive -DestinationPath $extractDir
        }
        catch {
            Write-Warning "Could not refresh the Metamod payload from $MetamodUrl. Reusing the existing extracted payload under $extractDir. $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $legacyLayout) {
        Copy-Item -Path (Join-Path $legacyLayout "*") -Destination $metamodDest -Recurse -Force
    }
    elseif (Test-Path -LiteralPath $flatDll) {
        $dllDir = Ensure-Directory -Path (Join-Path $metamodDest "dlls")
        Copy-Item -LiteralPath $flatDll -Destination (Join-Path $dllDir "metamod.dll") -Force
    }
    else {
        throw "Unsupported Metamod archive layout in $metamodArchive"
    }
}

Copy-JKBottiLabFiles -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform

Write-Host "Test stand prepared under $HldsRoot"
