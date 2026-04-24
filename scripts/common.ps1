Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-RepoPromptId {
    $promptIdPath = Join-Path (Get-RepoRoot) "PROMPT_ID.txt"
    if (-not (Test-Path -LiteralPath $promptIdPath)) {
        throw "Prompt ID file was not found: $promptIdPath"
    }

    $rawLines = @(Get-Content -LiteralPath $promptIdPath | ForEach-Object { $_.Trim() })
    $beginIndex = [Array]::IndexOf($rawLines, "PROMPT_ID_BEGIN")
    $endIndex = [Array]::IndexOf($rawLines, "PROMPT_ID_END")
    if ($beginIndex -lt 0 -or $endIndex -le $beginIndex) {
        throw "Prompt ID file is malformed: $promptIdPath"
    }

    $promptLines = @($rawLines[($beginIndex + 1)..($endIndex - 1)] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($promptLines.Count -ne 1) {
        throw "Prompt ID file must contain exactly one prompt ID between the markers: $promptIdPath"
    }

    return [string]$promptLines[0]
}

function Get-RepoHeadCommitSha {
    param([string]$RepoRoot = "")

    $resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        Get-RepoRoot
    }
    else {
        $RepoRoot
    }

    try {
        $sha = & git -C $resolvedRepoRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) {
            return ($sha | Select-Object -First 1).Trim()
        }
    }
    catch {
    }

    return ""
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) {
            return $Object[$Name]
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Get-TuningProfilesPath {
    return Join-Path (Get-RepoRoot) "ai_director\testdata\tuning_profiles.json"
}

function Get-TuningProfilesCatalog {
    $profilesPath = Get-TuningProfilesPath
    if (-not (Test-Path -LiteralPath $profilesPath)) {
        throw "Tuning profile catalog was not found: $profilesPath"
    }

    return Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json
}

function Get-TuningProfileDefinition {
    param([string]$Name = "")

    $catalog = Get-TuningProfilesCatalog
    $profiles = $catalog.profiles
    if ($null -eq $profiles) {
        throw "The tuning profile catalog does not contain a profiles object."
    }

    $profileName = if ([string]::IsNullOrWhiteSpace($Name)) {
        [string]$catalog.default_profile
    }
    else {
        $Name.Trim()
    }

    if (-not $profileName) {
        $profileName = "default"
    }

    $profile = $profiles.PSObject.Properties[$profileName]
    if ($null -eq $profile) {
        $availableNames = @($profiles.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
        throw "Unknown tuning profile '$profileName'. Available profiles: $availableNames"
    }

    return [pscustomobject]@{
        name = $profileName
        description = [string]$profile.Value.description
        cooldown_seconds = [double]$profile.Value.cooldown_seconds
        decision = $profile.Value.decision
        evaluation = $profile.Value.evaluation
    }
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

function Resolve-LaneArtifactPath {
    param(
        [string]$LaneRoot,
        [string]$PreferredLeaf,
        [string[]]$FallbackLeafNames = @()
    )

    if ([string]::IsNullOrWhiteSpace($LaneRoot) -or [string]::IsNullOrWhiteSpace($PreferredLeaf)) {
        return ""
    }

    foreach ($leafName in @($PreferredLeaf) + @($FallbackLeafNames)) {
        if ([string]::IsNullOrWhiteSpace($leafName)) {
            continue
        }

        $candidatePath = Join-Path $LaneRoot $leafName
        if (Test-Path -LiteralPath $candidatePath) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    return ""
}

function Get-CompatibleLaneArtifactOutputPath {
    param(
        [string]$LaneRoot,
        [string]$PreferredLeaf,
        [string[]]$FallbackLeafNames = @(),
        [int]$MaxPathLength = 259
    )

    if ([string]::IsNullOrWhiteSpace($LaneRoot) -or [string]::IsNullOrWhiteSpace($PreferredLeaf)) {
        throw "LaneRoot and PreferredLeaf are required."
    }

    $candidates = @($PreferredLeaf) + @($FallbackLeafNames)
    foreach ($leafName in $candidates) {
        if ([string]::IsNullOrWhiteSpace($leafName)) {
            continue
        }

        $candidatePath = Join-Path $LaneRoot $leafName
        if ($candidatePath.Length -le $MaxPathLength) {
            return [pscustomobject]@{
                path = $candidatePath
                leaf = $leafName
                used_fallback = $leafName -ne $PreferredLeaf
                preferred_leaf = $PreferredLeaf
            }
        }
    }

    return [pscustomobject]@{
        path = (Join-Path $LaneRoot $PreferredLeaf)
        leaf = $PreferredLeaf
        used_fallback = $false
        preferred_leaf = $PreferredLeaf
    }
}

function Resolve-LaneHumanPresenceTimelinePath {
    param([string]$LaneRoot)

    return Resolve-LaneArtifactPath `
        -LaneRoot $LaneRoot `
        -PreferredLeaf "human_presence_timeline.ndjson" `
        -FallbackLeafNames @("human_timeline.ndjson")
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

function Get-DumpbinPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe was not found. Install Visual Studio 2022 with VC++ tools."
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installPath) {
        throw "A Visual Studio installation with VC++ tools was not found."
    }

    $toolRoot = Get-ChildItem -LiteralPath (Join-Path $installPath "VC\Tools\MSVC") | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $toolRoot) {
        throw "VC++ tools were not found under $installPath."
    }

    foreach ($candidate in @(
        (Join-Path $toolRoot.FullName "bin\Hostx64\x64\dumpbin.exe"),
        (Join-Path $toolRoot.FullName "bin\Hostx86\x86\dumpbin.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "dumpbin.exe was not found under $($toolRoot.FullName)."
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

function Get-EvalRootDefault {
    param([string]$LabRoot)
    return Join-Path (Get-LogsRootDefault -LabRoot $LabRoot) "eval"
}

function Get-PairsRootDefault {
    param([string]$LabRoot)
    return Join-Path (Get-EvalRootDefault -LabRoot $LabRoot) "pairs"
}

function Get-RegistryRootDefault {
    param([string]$LabRoot)
    return Join-Path (Get-EvalRootDefault -LabRoot $LabRoot) "registry"
}

function Get-LocalIPv4Address {
    $netAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and
            $_.IPAddress -notmatch '^0\.'
        } |
        Sort-Object InterfaceMetric, SkipAsSource |
        Select-Object -First 1

    if ($netAddress -and $netAddress.IPAddress) {
        return $netAddress.IPAddress
    }

    try {
        $dnsAddress = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object {
                $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $_.IPAddressToString -notmatch '^(127\.|169\.254\.)'
            } |
            Select-Object -First 1

        if ($dnsAddress) {
            return $dnsAddress.IPAddressToString
        }
    }
    catch {
    }

    return ""
}

function Get-HldsJoinInfo {
    param(
        [int]$Port,
        [string]$ServerHost = "127.0.0.1"
    )

    $resolvedHost = if ([string]::IsNullOrWhiteSpace($ServerHost)) {
        "127.0.0.1"
    }
    else {
        $ServerHost.Trim()
    }

    $loopbackAddress = "{0}:{1}" -f $resolvedHost, $Port
    $lanHost = Get-LocalIPv4Address
    $lanAddress = if ($lanHost) { "{0}:{1}" -f $lanHost, $Port } else { "" }

    [pscustomobject]@{
        LoopbackHost        = $resolvedHost
        LoopbackAddress     = $loopbackAddress
        LanHost             = $lanHost
        LanAddress          = $lanAddress
        ConsoleCommand      = "connect $loopbackAddress"
        LanConsoleCommand   = if ($lanAddress) { "connect $lanAddress" } else { "" }
        SteamConnectUri     = "steam://connect/$loopbackAddress"
    }
}

function Format-ProcessArgumentText {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function Resolve-NormalizedPathCandidate {
    param(
        [string]$Path,
        [string]$AppendLeaf = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        return ""
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return ""
    }

    if (-not [string]::IsNullOrWhiteSpace($AppendLeaf) -and (Test-Path -LiteralPath $fullPath -PathType Container)) {
        $fullPath = Join-Path $fullPath $AppendLeaf
    }

    return $fullPath
}

function Get-SteamLibraryRootsFromVdf {
    param([string]$LibraryFoldersPath)

    if ([string]::IsNullOrWhiteSpace($LibraryFoldersPath) -or -not (Test-Path -LiteralPath $LibraryFoldersPath)) {
        return @()
    }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $LibraryFoldersPath) {
        $pathText = ""
        if ($line -match '"path"\s*"([^"]+)"') {
            $pathText = $Matches[1]
        }
        elseif ($line -match '^\s*"\d+"\s*"([^"]+)"') {
            $candidateText = [string]$Matches[1]
            if ($candidateText -match '[:\\/]') {
                $pathText = $candidateText
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($pathText)) {
            $normalized = ($pathText -replace '\\\\', '\').Trim()
            try {
                $fullPath = [System.IO.Path]::GetFullPath($normalized)
                if (-not [string]::IsNullOrWhiteSpace($fullPath)) {
                    $roots.Add($fullPath) | Out-Null
                }
            }
            catch {
            }
        }
    }

    return @($roots | Select-Object -Unique)
}

function Get-SteamRegistryInstallRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $registrySpecs = @(
        @{ Path = "HKCU:\Software\Valve\Steam"; PropertyNames = @("SteamPath", "InstallPath") },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam"; PropertyNames = @("InstallPath", "SteamPath") },
        @{ Path = "HKLM:\SOFTWARE\Valve\Steam"; PropertyNames = @("InstallPath", "SteamPath") }
    )

    foreach ($spec in $registrySpecs) {
        try {
            $properties = Get-ItemProperty -Path $spec.Path -ErrorAction Stop
            foreach ($propertyName in $spec.PropertyNames) {
                $value = [string]$properties.$propertyName
                if ([string]::IsNullOrWhiteSpace($value)) {
                    continue
                }

                $candidate = Resolve-NormalizedPathCandidate -Path $value
                if ([string]::IsNullOrWhiteSpace($candidate)) {
                    continue
                }

                if ([System.IO.Path]::GetFileName($candidate) -ieq "steam.exe") {
                    $candidate = Split-Path -Path $candidate -Parent
                }

                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $roots.Add($candidate) | Out-Null
                }
            }
        }
        catch {
        }
    }

    return @($roots | Select-Object -Unique)
}

function Get-SteamInstallRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $standardRoots = @(
        (Resolve-NormalizedPathCandidate -Path (Join-Path ${env:ProgramFiles(x86)} "Steam")),
        (Resolve-NormalizedPathCandidate -Path (Join-Path ${env:ProgramFiles} "Steam")),
        (Resolve-NormalizedPathCandidate -Path "D:\Steam"),
        "C:\Program Files (x86)\Steam",
        "C:\Program Files\Steam"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($root in @($standardRoots) + @(Get-SteamRegistryInstallRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $candidate = Resolve-NormalizedPathCandidate -Path $root
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $roots.Add($candidate) | Out-Null
    }

    return @($roots | Select-Object -Unique)
}

function Get-SteamExecutablePath {
    foreach ($root in Get-SteamInstallRoots) {
        $candidate = Join-Path $root "steam.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return ""
}

function Get-SteamLogsRoot {
    $steamExePath = Get-SteamExecutablePath
    if ([string]::IsNullOrWhiteSpace($steamExePath)) {
        return ""
    }

    $steamRoot = Split-Path -Path $steamExePath -Parent
    if ([string]::IsNullOrWhiteSpace($steamRoot)) {
        return ""
    }

    return Join-Path $steamRoot "logs"
}

function Get-SteamConnectionLogPath {
    param([int]$Port)

    if ($Port -lt 1 -or $Port -gt 65535) {
        return ""
    }

    $logsRoot = Get-SteamLogsRoot
    if ([string]::IsNullOrWhiteSpace($logsRoot)) {
        return ""
    }

    return Join-Path $logsRoot ("connection_log_{0}.txt" -f $Port)
}

function Get-HalfLifeClientDiscovery {
    param([string]$PreferredPath = "")

    $checkedSources = New-Object System.Collections.Generic.List[object]
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    $seenCandidates = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $discoveredClientPath = ""
    $discoveryExplanation = ""

    function Add-ClientDiscoveryCheck {
        param(
            [string]$SourceName,
            [string]$CheckKind,
            [string]$PathChecked,
            [bool]$Exists,
            [string]$Details
        )

        $checkedSources.Add([pscustomobject]@{
            source_name = $SourceName
            check_kind = $CheckKind
            path_checked = $PathChecked
            exists = $Exists
            details = $Details
        }) | Out-Null
    }

    function Test-ClientCandidate {
        param(
            [string]$SourceName,
            [string]$CandidatePath,
            [string]$Details
        )

        if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
            Add-ClientDiscoveryCheck -SourceName $SourceName -CheckKind "client-executable" -PathChecked "" -Exists $false -Details $Details
            return $false
        }

        $normalizedCandidate = Resolve-NormalizedPathCandidate -Path $CandidatePath
        $exists = -not [string]::IsNullOrWhiteSpace($normalizedCandidate) -and (Test-Path -LiteralPath $normalizedCandidate -PathType Leaf)
        Add-ClientDiscoveryCheck -SourceName $SourceName -CheckKind "client-executable" -PathChecked $normalizedCandidate -Exists $exists -Details $Details
        if ($exists) {
            Set-Variable -Name discoveredClientPath -Scope 1 -Value ((Resolve-Path -LiteralPath $normalizedCandidate).Path)
            return $true
        }

        return $false
    }

    function Add-LibraryRootsForSteamRoot {
        param(
            [string]$SourceName,
            [string]$SteamRoot
        )

        if ([string]::IsNullOrWhiteSpace($SteamRoot)) {
            return
        }

        $normalizedRoot = Resolve-NormalizedPathCandidate -Path $SteamRoot
        if ([string]::IsNullOrWhiteSpace($normalizedRoot)) {
            return
        }

        $libraryFoldersPath = Join-Path $normalizedRoot "steamapps\libraryfolders.vdf"
        $libraryRoots = @(Get-SteamLibraryRootsFromVdf -LibraryFoldersPath $libraryFoldersPath)
        $foundLibraries = $libraryRoots.Count -gt 0
        Add-ClientDiscoveryCheck -SourceName $SourceName -CheckKind "steam-library-folders" -PathChecked $libraryFoldersPath -Exists $foundLibraries -Details $(if ($foundLibraries) { ($libraryRoots -join "; ") } else { "No Steam library folders were discovered from this root." })

        foreach ($libraryRoot in $libraryRoots) {
            if ($seenCandidates.Add($libraryRoot)) {
                $candidateRoots.Add($libraryRoot) | Out-Null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $preferredCandidate = Resolve-NormalizedPathCandidate -Path $PreferredPath -AppendLeaf "hl.exe"
        if (Test-ClientCandidate -SourceName "explicit-client-path" -CandidatePath $preferredCandidate -Details "Checked the explicit -ClientExePath first.") {
            $discoveryExplanation = "Found hl.exe from -ClientExePath."
        }
    }

    if (-not $discoveredClientPath) {
        $envCandidate = Resolve-NormalizedPathCandidate -Path $env:HL_CLIENT_EXE -AppendLeaf "hl.exe"
        if (Test-ClientCandidate -SourceName "env:HL_CLIENT_EXE" -CandidatePath $envCandidate -Details "Checked the HL_CLIENT_EXE environment variable.") {
            $discoveryExplanation = "Found hl.exe from HL_CLIENT_EXE."
        }
    }

    if (-not $discoveredClientPath -and -not [string]::IsNullOrWhiteSpace($env:HALF_LIFE_EXE)) {
        $fallbackEnvCandidate = Resolve-NormalizedPathCandidate -Path $env:HALF_LIFE_EXE -AppendLeaf "hl.exe"
        if (Test-ClientCandidate -SourceName "env:HALF_LIFE_EXE" -CandidatePath $fallbackEnvCandidate -Details "Checked the legacy HALF_LIFE_EXE environment variable.") {
            $discoveryExplanation = "Found hl.exe from HALF_LIFE_EXE."
        }
    }

    $standardSteamRoots = @(
        (Resolve-NormalizedPathCandidate -Path (Join-Path ${env:ProgramFiles(x86)} "Steam")),
        (Resolve-NormalizedPathCandidate -Path (Join-Path ${env:ProgramFiles} "Steam")),
        "C:\Program Files (x86)\Steam",
        "C:\Program Files\Steam"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    if (-not $discoveredClientPath) {
        foreach ($steamRoot in $standardSteamRoots) {
            $directCandidate = Resolve-NormalizedPathCandidate -Path (Join-Path $steamRoot "steamapps\common\Half-Life\hl.exe")
            if (Test-ClientCandidate -SourceName "standard-steam-root" -CandidatePath $directCandidate -Details "Checked the standard Steam install root for Half-Life.") {
                $discoveryExplanation = "Found hl.exe under a standard Steam install root."
                break
            }
        }
    }

    foreach ($steamRoot in $standardSteamRoots) {
        Add-LibraryRootsForSteamRoot -SourceName "standard-steam-root" -SteamRoot $steamRoot
    }

    if (-not $discoveredClientPath) {
        foreach ($libraryRoot in @($candidateRoots | Select-Object -Unique)) {
            $libraryCandidate = Resolve-NormalizedPathCandidate -Path (Join-Path $libraryRoot "steamapps\common\Half-Life\hl.exe")
            if (Test-ClientCandidate -SourceName "steam-library-folder" -CandidatePath $libraryCandidate -Details "Checked a Steam library folder for Half-Life.") {
                $discoveryExplanation = "Found hl.exe under a discovered Steam library folder."
                break
            }
        }
    }

    $registrySteamRoots = Get-SteamRegistryInstallRoots
    if (-not $discoveredClientPath) {
        foreach ($steamRoot in $registrySteamRoots) {
            $registryCandidate = Resolve-NormalizedPathCandidate -Path (Join-Path $steamRoot "steamapps\common\Half-Life\hl.exe")
            if (Test-ClientCandidate -SourceName "registry-steam-root" -CandidatePath $registryCandidate -Details "Checked a Steam install path hinted by the Windows registry.") {
                $discoveryExplanation = "Found hl.exe from a registry-discovered Steam install hint."
                break
            }
        }
    }

    foreach ($steamRoot in $registrySteamRoots) {
        Add-LibraryRootsForSteamRoot -SourceName "registry-steam-root" -SteamRoot $steamRoot
    }

    if (-not $discoveredClientPath) {
        foreach ($libraryRoot in @($candidateRoots | Select-Object -Unique)) {
            $libraryCandidate = Resolve-NormalizedPathCandidate -Path (Join-Path $libraryRoot "steamapps\common\Half-Life\hl.exe")
            if (Test-ClientCandidate -SourceName "registry-steam-library-folder" -CandidatePath $libraryCandidate -Details "Checked a Steam library folder that was discovered from a registry Steam root.") {
                $discoveryExplanation = "Found hl.exe from a registry-discovered Steam library folder."
                break
            }
        }
    }

    $legacyCandidates = @(
        "C:\Sierra\Half-Life\hl.exe",
        "C:\Program Files (x86)\Sierra\Half-Life\hl.exe",
        "C:\Program Files\Sierra\Half-Life\hl.exe"
    )
    if (-not $discoveredClientPath) {
        foreach ($legacyCandidate in $legacyCandidates) {
            if (Test-ClientCandidate -SourceName "legacy-half-life-path" -CandidatePath $legacyCandidate -Details "Checked a legacy locally documented Half-Life install path.") {
                $discoveryExplanation = "Found hl.exe under a legacy Half-Life install path."
                break
            }
        }
    }

    $launchable = $false
    if ($discoveredClientPath) {
        try {
            $stream = [System.IO.File]::Open($discoveredClientPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $launchable = $true
            }
            finally {
                $stream.Dispose()
            }
        }
        catch {
            $launchable = $false
        }
    }

    $verdict = if ($discoveredClientPath) {
        if ($launchable) { "client-found-and-launchable" } else { "client-found-but-unverified" }
    }
    else {
        "client-not-found"
    }

    if (-not $discoveryExplanation) {
        if ($discoveredClientPath) {
            $discoveryExplanation = if ($launchable) {
                "Found hl.exe and verified that the file is readable for local client launch."
            }
            else {
                "Found hl.exe, but the file could not be verified as launchable from this environment."
            }
        }
        else {
            $discoveryExplanation = "Half-Life client discovery did not find hl.exe. Checked the explicit path, environment variables, standard Steam roots, discoverable Steam library folders, registry Steam hints, and legacy documented install paths."
        }
    }

    $discoverySourcesChecked = @()
    foreach ($entry in $checkedSources) {
        $discoverySourcesChecked += $entry
    }

    $payload = [ordered]@{
        client_path = $discoveredClientPath
        discovery_verdict = $verdict
        launchable = $launchable
        launchable_for_local_lane_join = $launchable
        discovery_sources_checked = $discoverySourcesChecked
        explanation = $discoveryExplanation
    }

    return New-Object psobject -Property $payload
}

function Get-HalfLifeClientLaunchPlan {
    param(
        [string]$PreferredClientPath = "",
        [string]$ServerHost = "127.0.0.1",
        [int]$Port,
        [string]$Game = "valve"
    )

    $discovery = Get-HalfLifeClientDiscovery -PreferredPath $PreferredClientPath
    $joinInfo = Get-HldsJoinInfo -Port $Port -ServerHost $ServerHost
    $clientWorkingDirectory = ""
    $qconsolePath = ""
    $debugLogPath = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$discovery.client_path)) {
        $clientWorkingDirectory = Split-Path -Path ([string]$discovery.client_path) -Parent
        if (-not [string]::IsNullOrWhiteSpace($clientWorkingDirectory)) {
            $qconsolePath = Join-Path $clientWorkingDirectory "qconsole.log"
            $debugLogPath = Join-Path $clientWorkingDirectory "debug.log"
        }
    }
    $arguments = @(
        "-game", $Game,
        "+connect", $joinInfo.LoopbackAddress
    )

    $commandText = ""
    if ($discovery.launchable -and -not [string]::IsNullOrWhiteSpace($discovery.client_path)) {
        $commandParts = @((Format-ProcessArgumentText -Value $discovery.client_path))
        $commandParts += @($arguments | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) })
        $commandText = $commandParts -join " "
    }

    return [pscustomobject]@{
        client_discovery = $discovery
        client_exe_path = [string]$discovery.client_path
        client_working_directory = $clientWorkingDirectory
        qconsole_path = $qconsolePath
        debug_log_path = $debugLogPath
        join_info = $joinInfo
        arguments = $arguments
        command_text = $commandText
        launchable = [bool]$discovery.launchable
    }
}

function Get-PublicHldmClientAdmissionPlan {
    param(
        [string]$PreferredSteamPath = "",
        [string]$PreferredClientPath = "",
        [string]$ServerAddress = "127.0.0.1",
        [int]$ServerPort,
        [string]$Game = "valve"
    )

    $resolvedServerAddress = if ([string]::IsNullOrWhiteSpace($ServerAddress)) {
        "127.0.0.1"
    }
    else {
        $ServerAddress.Trim()
    }

    $directLaunchPlan = Get-HalfLifeClientLaunchPlan -PreferredClientPath $PreferredClientPath -ServerHost $resolvedServerAddress -Port $ServerPort -Game $Game
    $joinInfo = $directLaunchPlan.join_info

    $steamExePath = if ([string]::IsNullOrWhiteSpace($PreferredSteamPath)) {
        Get-SteamExecutablePath
    }
    else {
        $resolvedSteamPath = Resolve-NormalizedPathCandidate -Path $PreferredSteamPath
        if (-not [string]::IsNullOrWhiteSpace($resolvedSteamPath) -and (Test-Path -LiteralPath $resolvedSteamPath -PathType Leaf)) {
            try {
                (Resolve-Path -LiteralPath $resolvedSteamPath).Path
            }
            catch {
                $resolvedSteamPath
            }
        }
        else {
            ""
        }
    }

    $steamWorkingDirectory = if ([string]::IsNullOrWhiteSpace($steamExePath)) {
        ""
    }
    else {
        Split-Path -Path $steamExePath -Parent
    }

    $steamLaunchArguments = @(
        "-applaunch", "70",
        "-game", $Game,
        "+connect", $joinInfo.LoopbackAddress
    )

    $steamLaunchCommandText = ""
    if (-not [string]::IsNullOrWhiteSpace($steamExePath)) {
        $steamCommandParts = @((Format-ProcessArgumentText -Value $steamExePath))
        $steamCommandParts += @($steamLaunchArguments | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) })
        $steamLaunchCommandText = $steamCommandParts -join " "
    }

    $steamConnectUriCommandText = ""
    if (-not [string]::IsNullOrWhiteSpace($steamExePath) -and -not [string]::IsNullOrWhiteSpace($joinInfo.SteamConnectUri)) {
        $steamConnectUriCommandText = "{0} {1}" -f `
            (Format-ProcessArgumentText -Value $steamExePath), `
            (Format-ProcessArgumentText -Value $joinInfo.SteamConnectUri)
    }

    $preferredLaunchPath = if (-not [string]::IsNullOrWhiteSpace($steamExePath)) {
        "steam-native-applaunch"
    }
    elseif ([bool]$directLaunchPlan.launchable) {
        "direct-hl-exe"
    }
    else {
        "none"
    }

    return [pscustomobject]@{
        server_address = $resolvedServerAddress
        server_port = $ServerPort
        game = $Game
        join_info = $joinInfo
        steam_exe_path = $steamExePath
        steam_working_directory = $steamWorkingDirectory
        steam_launch_arguments = $steamLaunchArguments
        steam_launch_command_text = $steamLaunchCommandText
        steam_connect_uri = $joinInfo.SteamConnectUri
        steam_connect_uri_command_text = $steamConnectUriCommandText
        direct_launch_plan = $directLaunchPlan
        preferred_launch_path = $preferredLaunchPath
    }
}

function Get-ServerModRoot {
    param([string]$HldsRoot)
    return Join-Path $HldsRoot "valve"
}

function Get-AiRuntimeDir {
    param([string]$HldsRoot)
    return Join-Path (Get-ServerModRoot -HldsRoot $HldsRoot) "addons\jk_botti\runtime\ai_balance"
}

function Get-AiRuntimeHistoryDir {
    param([string]$HldsRoot)
    return Join-Path (Get-AiRuntimeDir -HldsRoot $HldsRoot) "history"
}

function Get-AiRuntimeHistoryFilePath {
    param(
        [string]$HldsRoot,
        [string]$Kind,
        [string]$MatchId
    )

    if ([string]::IsNullOrWhiteSpace($Kind)) {
        throw "Kind is required."
    }

    if ([string]::IsNullOrWhiteSpace($MatchId)) {
        throw "MatchId is required."
    }

    $safeMatchId = [regex]::Replace($MatchId, "[^A-Za-z0-9._-]", "_")
    return Join-Path (Get-AiRuntimeHistoryDir -HldsRoot $HldsRoot) ("{0}-{1}.ndjson" -f $Kind, $safeMatchId)
}

function Get-PluginBootstrapLogPath {
    param([string]$HldsRoot)
    return Join-Path (Get-ServerModRoot -HldsRoot $HldsRoot) "addons\jk_botti\runtime\bootstrap.log"
}

function Get-JKBottiPluginRelativePath {
    return "addons/jk_botti/dlls/jk_botti_mm.dll"
}

function Get-MetamodPluginsIniPath {
    param([string]$ModRoot)
    return Join-Path $ModRoot "addons\metamod\plugins.ini"
}

function Get-DeployedPluginPath {
    param(
        [string]$HldsRoot,
        [string]$RelativePath = (Get-JKBottiPluginRelativePath)
    )

    $normalizedRelativePath = $RelativePath -replace '/', '\'
    return Join-Path (Get-ServerModRoot -HldsRoot $HldsRoot) $normalizedRelativePath
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File was not found at $Path"
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "")
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
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

function Assert-BotLaunchSettings {
    param(
        [int]$BotCount,
        [int]$BotSkill
    )

    if ($BotCount -lt 1 -or $BotCount -gt 31) {
        throw "BotCount must be between 1 and 31. Actual value: $BotCount"
    }

    if ($BotSkill -lt 1 -or $BotSkill -gt 5) {
        throw "BotSkill must be between 1 and 5. Actual value: $BotSkill"
    }
}

function New-BotAddCommands {
    param(
        [int]$BotCount,
        [int]$BotSkill
    )

    Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

    $commands = @()
    for ($index = 0; $index -lt $BotCount; $index++) {
        $commands += "addbot """" """" $BotSkill"
    }

    return $commands
}

function Write-BotTestConfig {
    param(
        [string]$HldsRoot,
        [string]$Map,
        [int]$BotCount,
        [int]$BotSkill
    )

    Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

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

    $botSetup += New-BotAddCommands -BotCount $BotCount -BotSkill $BotSkill

    $rendered = $template.Replace("__MAP_NAME__", $Map)
    $rendered = $rendered.Replace("__BOT_COUNT__", [string]$BotCount)
    $rendered = $rendered.Replace("__BOT_SKILL__", [string]$BotSkill)
    $rendered = $rendered.Replace("__BOT_SETUP__", ($botSetup -join [Environment]::NewLine))

    Set-Content -LiteralPath $configPath -Value $rendered -Encoding ASCII
    return $configPath
}

function Write-StandardBotTestConfig {
    param(
        [string]$HldsRoot,
        [string]$Map,
        [int]$BotCount,
        [int]$BotSkill
    )

    Assert-BotLaunchSettings -BotCount $BotCount -BotSkill $BotSkill

    $modRoot = Ensure-Directory -Path (Get-ServerModRoot -HldsRoot $HldsRoot)
    $botAddonsRoot = Ensure-Directory -Path (Join-Path $modRoot "addons\jk_botti")
    $configPath = Join-Path $botAddonsRoot (Split-Path -Leaf (Get-BotTestConfigPath -ModRoot $modRoot -Map $Map))

    $lines = @(
        "pause 3"
        "autowaypoint 1"
        "bot_add_level_tag 1"
        "bot_conntimes 0"
        "team_balancetype 1"
        "bot_chat_percent 0"
        "bot_taunt_percent 0"
        "bot_whine_percent 0"
        "bot_endgame_percent 0"
        "bot_logo_percent 0"
        "random_color 0"
        "bot_shoot_breakables 2"
        ""
        "jk_ai_balance_enabled 0"
        ""
        "botskill $BotSkill"
        "min_bots $BotCount"
        "max_bots $BotCount"
        ""
    )

    $lines += New-BotAddCommands -BotCount $BotCount -BotSkill $BotSkill

    Set-Content -LiteralPath $configPath -Value ($lines -join [Environment]::NewLine) -Encoding ASCII
    return $configPath
}

function Get-PublicCrossfireConfigTemplatePath {
    return Join-Path (Get-RepoRoot) "addons\jk_botti\public_crossfire.cfg"
}

function Write-PublicCrossfireConfig {
    param(
        [string]$HldsRoot,
        [string]$Map,
        [int]$BotSkill,
        [bool]$EnableAdvancedAIBalance = $false
    )

    if ($BotSkill -lt 1 -or $BotSkill -gt 5) {
        throw "BotSkill must be between 1 and 5. Actual value: $BotSkill"
    }

    $templatePath = Get-PublicCrossfireConfigTemplatePath
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Public crossfire config template was not found at $templatePath"
    }

    $modRoot = Ensure-Directory -Path (Get-ServerModRoot -HldsRoot $HldsRoot)
    $botAddonsRoot = Ensure-Directory -Path (Join-Path $modRoot "addons\jk_botti")
    $configPath = Join-Path $botAddonsRoot (Split-Path -Leaf (Get-BotTestConfigPath -ModRoot $modRoot -Map $Map))
    $template = Get-Content -LiteralPath $templatePath -Raw

    $rendered = $template.Replace("__MAP_NAME__", $Map)
    $rendered = $rendered.Replace("__BOT_SKILL__", [string]$BotSkill)
    $rendered = $rendered.Replace("__AI_BALANCE_ENABLED__", $(if ($EnableAdvancedAIBalance) { "1" } else { "0" }))

    Set-Content -LiteralPath $configPath -Value $rendered -Encoding ASCII
    return $configPath
}

function Get-LabProcesses {
    param([string]$HldsRoot)

    $runtimeDir = (Get-AiRuntimeDir -HldsRoot $HldsRoot).ToLowerInvariant()
    $hldsExe = (Join-Path $HldsRoot "hlds.exe").ToLowerInvariant()

    return Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -ieq "hlds.exe" -and $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant() -eq $hldsExe) -or
        ($_.Name -ieq "python.exe" -and $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains("ai_director\main.py") -and $_.CommandLine.ToLowerInvariant().Contains($runtimeDir))
    }
}

function Stop-LabProcesses {
    param([string]$HldsRoot)

    $existingProcesses = Get-LabProcesses -HldsRoot $HldsRoot
    foreach ($existing in $existingProcesses) {
        Write-Host "Stopping existing lab process $($existing.Name) PID=$($existing.ProcessId)"
        try {
            Stop-Process -Id $existing.ProcessId -Force -ErrorAction Stop
        }
        catch {
            if ($_.Exception.Message -notmatch "Cannot find a process") {
                throw
            }
            Write-Warning "Lab process PID=$($existing.ProcessId) was already gone by the time cleanup tried to stop it."
        }
    }
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
    $pluginsIni = Get-MetamodPluginsIniPath -ModRoot $ModRoot
    @(
        "; Generated by scripts/setup_test_stand.ps1"
        "win32 $(Get-JKBottiPluginRelativePath)"
    ) | Set-Content -LiteralPath $pluginsIni -Encoding ASCII
}

function Write-ServerCfg {
    param(
        [string]$ModRoot,
        [string]$Hostname = "HLDM JK_Botti AI Lab",
        [ValidateRange(0, 1)][int]$SvLan = 1,
        [bool]$LogEnabled = $true,
        [int]$FragLimit = 30,
        [int]$TimeLimit = 10,
        [string]$RconPassword = ""
    )

    $serverCfg = Join-Path $ModRoot "server.cfg"
    $lines = @(
        ('hostname "{0}"' -f $Hostname.Replace('"', ''))
        ("sv_lan {0}" -f $SvLan)
        ("log {0}" -f $(if ($LogEnabled) { "on" } else { "off" }))
        ("mp_fraglimit {0}" -f $FragLimit)
        ("mp_timelimit {0}" -f $TimeLimit)
    )

    if (-not [string]::IsNullOrWhiteSpace($RconPassword)) {
        $lines += ('rcon_password "{0}"' -f $RconPassword.Replace('"', ''))
    }

    $lines | Set-Content -LiteralPath $serverCfg -Encoding ASCII
}

function Get-ConfiguredMetamodPluginRelativePath {
    param([string]$PluginsIniPath)

    if (-not (Test-Path -LiteralPath $PluginsIniPath)) {
        throw "Metamod plugins.ini is missing: $PluginsIniPath"
    }

    foreach ($line in (Get-Content -LiteralPath $PluginsIniPath)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith(";")) {
            continue
        }

        if ($trimmed -match '^(win32|linux)\s+(.+)$') {
            return $Matches[2].Trim()
        }
    }

    throw "Metamod plugins.ini does not contain a plugin entry: $PluginsIniPath"
}

function Test-JKBottiLabDeployment {
    param(
        [string]$HldsRoot,
        [string]$Configuration = "Release",
        [string]$Platform = "Win32"
    )

    $modRoot = Get-ServerModRoot -HldsRoot $HldsRoot
    $builtDll = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform
    $pluginsIni = Get-MetamodPluginsIniPath -ModRoot $modRoot
    $expectedRelativePath = Get-JKBottiPluginRelativePath
    $configuredRelativePath = Get-ConfiguredMetamodPluginRelativePath -PluginsIniPath $pluginsIni
    $configuredComparable = ($configuredRelativePath -replace '\\', '/').ToLowerInvariant()
    $expectedComparable = $expectedRelativePath.ToLowerInvariant()

    if (-not (Test-Path -LiteralPath $builtDll)) {
        throw "Built DLL not found at $builtDll"
    }

    if ($configuredComparable -ne $expectedComparable) {
        throw "plugins.ini points to '$configuredRelativePath', expected '$expectedRelativePath'"
    }

    $deployedDll = Get-DeployedPluginPath -HldsRoot $HldsRoot -RelativePath $configuredRelativePath
    if (-not (Test-Path -LiteralPath $deployedDll)) {
        throw "Configured plugin DLL is missing at $deployedDll"
    }

    $builtHash = Get-FileSha256 -Path $builtDll
    $deployedHash = Get-FileSha256 -Path $deployedDll
    if ($builtHash -ne $deployedHash) {
        throw "Deployed plugin DLL does not match the staged build output. Built=$builtDll Deployed=$deployedDll"
    }

    [pscustomobject]@{
        BuiltDllPath          = $builtDll
        BuiltDllSha256        = $builtHash
        PluginsIniPath        = $pluginsIni
        PluginRelativePath    = $configuredRelativePath
        DeployedDllPath       = $deployedDll
        DeployedDllSha256     = $deployedHash
        BootstrapLogPath      = Get-PluginBootstrapLogPath -HldsRoot $HldsRoot
        AiRuntimeDir          = Get-AiRuntimeDir -HldsRoot $HldsRoot
    }
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
    $deployedDll = Get-DeployedPluginPath -HldsRoot $HldsRoot

    if (-not (Test-Path -LiteralPath $buildDll)) {
        throw "Built DLL not found at $buildDll"
    }

    Ensure-Directory -Path $destAddons | Out-Null
    Copy-Item -Path (Join-Path $sourceAddons "*") -Destination $destAddons -Recurse -Force
    Copy-Item -LiteralPath $buildDll -Destination $deployedDll -Force

    $runtimeDir = Ensure-Directory -Path (Get-AiRuntimeDir -HldsRoot $HldsRoot)
    Get-ChildItem -LiteralPath $runtimeDir -Filter "*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
    $bootstrapLog = Get-PluginBootstrapLogPath -HldsRoot $HldsRoot
    if (Test-Path -LiteralPath $bootstrapLog) {
        Remove-Item -LiteralPath $bootstrapLog -Force
    }

    Write-MetamodPluginsIni -ModRoot $modRoot
    Write-ServerCfg -ModRoot $modRoot
    Set-LiblistToMetamod -ModRoot $modRoot
    Test-JKBottiLabDeployment -HldsRoot $HldsRoot -Configuration $Configuration -Platform $Platform | Out-Null
}
