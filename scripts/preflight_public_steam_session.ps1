[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SteamExePath = "",
    [string]$ClientExePath = "",
    [int]$ServerPort = 27015,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$promptId = Get-RepoPromptId
$repoRoot = Get-RepoRoot
$labRoot = Get-LabRootDefault

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 14
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Get-FileTailText {
    param(
        [string]$Path,
        [int]$LineCount = 80
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    try {
        return ((Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop) -join [Environment]::NewLine).Trim()
    }
    catch {
        return ""
    }
}

function Test-FileReadable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-PathWriteTimeUtc {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    try {
        return [System.IO.File]::GetLastWriteTimeUtc($Path).ToString("o")
    }
    catch {
        return ""
    }
}

function Get-NamedProcessStates {
    param([string]$Name)

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Sort-Object Id)) {
        $startTime = ""
        try {
            $startTime = $process.StartTime.ToString("o")
        }
        catch {
            $startTime = ""
        }

        $states.Add([ordered]@{
            id = [int]$process.Id
            process_name = [string]$process.ProcessName
            path = [string](Get-ObjectPropertyValue -Object $process -Name "Path" -Default "")
            start_time_local = $startTime
        }) | Out-Null
    }

    return @($states.ToArray())
}

function Get-HalfLifeAppManifestCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($steamRoot in @(Get-SteamInstallRoots)) {
        if ([string]::IsNullOrWhiteSpace($steamRoot)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $steamRoot -PathType Container -ErrorAction SilentlyContinue)) {
            continue
        }

        $direct = Join-Path $steamRoot "steamapps\appmanifest_70.acf"
        $candidates.Add($direct) | Out-Null

        $libraryFoldersPath = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
        foreach ($libraryRoot in @(Get-SteamLibraryRootsFromVdf -LibraryFoldersPath $libraryFoldersPath)) {
            if (-not [string]::IsNullOrWhiteSpace($libraryRoot) -and (Test-Path -LiteralPath $libraryRoot -PathType Container -ErrorAction SilentlyContinue)) {
                $candidates.Add((Join-Path $libraryRoot "steamapps\appmanifest_70.acf")) | Out-Null
            }
        }
    }

    return @($candidates | Select-Object -Unique)
}

function Get-AppManifestSummary {
    param([string]$Path)

    $installedDir = ""
    $stateFlags = ""
    $name = ""
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $text = Get-Content -LiteralPath $Path -Raw
            if ($text -match '"installdir"\s+"(?<value>[^"]+)"') { $installedDir = [string]$Matches["value"] }
            if ($text -match '"StateFlags"\s+"(?<value>[^"]+)"') { $stateFlags = [string]$Matches["value"] }
            if ($text -match '"name"\s+"(?<value>[^"]+)"') { $name = [string]$Matches["value"] }
        }
        catch {
        }
    }

    return [ordered]@{
        path = $Path
        readable = Test-FileReadable -Path $Path
        name = $name
        installdir = $installedDir
        state_flags = $stateFlags
        write_time_utc = Get-PathWriteTimeUtc -Path $Path
    }
}

function Get-SteamLogSummary {
    param(
        [string]$Label,
        [string]$Path
    )

    $tail = Get-FileTailText -Path $Path -LineCount 100
    $cmFailure = $tail -match "GetCMListForConnect -- web API call failed|failed talking to cm|ConnectFailed\(|StartAutoReconnect|No Connection"
    $offlineSignal = $tail -match "Offline|offline mode|No Connection"
    $onlineSignal = $tail -match "Logged on OK|Connection established|OK waiting for jobs|SetSteamID"

    return [ordered]@{
        label = $Label
        path = $Path
        exists = -not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)
        readable = Test-FileReadable -Path $Path
        write_time_utc = Get-PathWriteTimeUtc -Path $Path
        contains_cm_failure = [bool]$cmFailure
        contains_offline_signal = [bool]$offlineSignal
        contains_online_signal = [bool]$onlineSignal
        tail = $tail
    }
}

function Get-PreflightMarkdown {
    param([object]$Preflight)

    $lines = @(
        "# Public Steam Session Preflight",
        "",
        "- Generated at UTC: $($Preflight.generated_at_utc)",
        "- Prompt ID: $($Preflight.prompt_id)",
        "- Verdict: $($Preflight.session_verdict)",
        "- Explanation: $($Preflight.explanation)",
        "- Steam executable: $($Preflight.steam_exe_path)",
        "- Steam install root: $($Preflight.steam_install_root)",
        "- Half-Life client: $($Preflight.client_exe_path)",
        "- Steam running: $($Preflight.steam_running)",
        "- steamwebhelper running: $($Preflight.steamwebhelper_running)",
        "- Half-Life app manifest present: $($Preflight.half_life_app_manifest_present)",
        "- Half-Life appears installed: $($Preflight.half_life_appears_installed)",
        "- Steam appears online: $($Preflight.steam_appears_online)",
        "- Steam appears offline: $($Preflight.steam_appears_offline)",
        "- Steam CM failure seen: $($Preflight.steam_cm_failure_seen)"
    )

    if ($Preflight.evidence_found) {
        $lines += @("", "## Evidence Found", "")
        foreach ($entry in @($Preflight.evidence_found)) {
            $lines += "- $entry"
        }
    }

    if ($Preflight.evidence_missing) {
        $lines += @("", "## Evidence Missing", "")
        foreach ($entry in @($Preflight.evidence_missing)) {
            $lines += "- $entry"
        }
    }

    $lines += @("", "## Logs Checked", "")
    foreach ($log in @($Preflight.steam_logs_checked)) {
        $lines += "- $($log.label): exists=$($log.exists); readable=$($log.readable); cm_failure=$($log.contains_cm_failure); online_signal=$($log.contains_online_signal); offline_signal=$($log.contains_offline_signal); path=$($log.path)"
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Ensure-Directory -Path (Join-Path $labRoot ("logs\public_server\steam_session_preflights\{0}-public-steam-session-preflight-p{1}" -f $stamp, $ServerPort))
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
    Ensure-Directory -Path $candidate
}

$preflightJsonPath = Join-Path $resolvedOutputRoot "public_steam_session_preflight.json"
$preflightMarkdownPath = Join-Path $resolvedOutputRoot "public_steam_session_preflight.md"

$admissionPlan = Get-PublicHldmClientAdmissionPlan -PreferredSteamPath $SteamExePath -PreferredClientPath $ClientExePath -ServerAddress "127.0.0.1" -ServerPort $ServerPort
$clientDiscovery = Get-HalfLifeClientDiscovery -PreferredPath $ClientExePath
$resolvedSteamExePath = [string]$admissionPlan.steam_exe_path
$steamInstallRoot = if ([string]::IsNullOrWhiteSpace($resolvedSteamExePath)) { "" } else { Split-Path -Path $resolvedSteamExePath -Parent }
$resolvedClientExePath = [string]$clientDiscovery.client_path
$steamLogsRoot = Get-SteamLogsRoot
$connectionLogPath = Get-SteamConnectionLogPath -Port $ServerPort

$manifestCandidates = @(Get-HalfLifeAppManifestCandidates)
$existingManifest = $manifestCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
$manifestSummary = Get-AppManifestSummary -Path $(if ($existingManifest) { [string]$existingManifest } else { "" })

$logsToCheck = New-Object System.Collections.Generic.List[object]
if (-not [string]::IsNullOrWhiteSpace($steamLogsRoot)) {
    $logsToCheck.Add((Get-SteamLogSummary -Label "connection_log_current_port" -Path $connectionLogPath)) | Out-Null
    $logsToCheck.Add((Get-SteamLogSummary -Label "connection_log" -Path (Join-Path $steamLogsRoot "connection_log.txt"))) | Out-Null
    $logsToCheck.Add((Get-SteamLogSummary -Label "bootstrap_log" -Path (Join-Path $steamLogsRoot "bootstrap_log.txt"))) | Out-Null
    $logsToCheck.Add((Get-SteamLogSummary -Label "content_log" -Path (Join-Path $steamLogsRoot "content_log.txt"))) | Out-Null
}

$steamProcesses = @(Get-NamedProcessStates -Name "steam")
$steamWebHelperProcesses = @(Get-NamedProcessStates -Name "steamwebhelper")
$hlProcesses = @(Get-NamedProcessStates -Name "hl")
$steamRunning = $steamProcesses.Count -gt 0
$steamWebHelperRunning = $steamWebHelperProcesses.Count -gt 0
$manifestPresent = -not [string]::IsNullOrWhiteSpace([string]$existingManifest)
$clientFound = -not [string]::IsNullOrWhiteSpace($resolvedClientExePath) -and (Test-Path -LiteralPath $resolvedClientExePath -PathType Leaf)
$halfLifeAppearsInstalled = $manifestPresent -and $clientFound
$steamCmFailureSeen = @($logsToCheck.ToArray() | Where-Object { [bool]$_.contains_cm_failure }).Count -gt 0
$steamOnlineSeen = @($logsToCheck.ToArray() | Where-Object { [bool]$_.contains_online_signal }).Count -gt 0
$steamOfflineSeen = @($logsToCheck.ToArray() | Where-Object { [bool]$_.contains_offline_signal }).Count -gt 0

$evidenceFound = New-Object System.Collections.Generic.List[string]
$evidenceMissing = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($resolvedSteamExePath)) { $evidenceFound.Add("steam.exe path resolved") | Out-Null } else { $evidenceMissing.Add("steam.exe path") | Out-Null }
if ($clientFound) { $evidenceFound.Add("hl.exe path resolved") | Out-Null } else { $evidenceMissing.Add("hl.exe path") | Out-Null }
if ($manifestPresent) { $evidenceFound.Add("Half-Life appmanifest_70.acf present") | Out-Null } else { $evidenceMissing.Add("Half-Life appmanifest_70.acf") | Out-Null }
if ($steamRunning) { $evidenceFound.Add("Steam process is running") | Out-Null } else { $evidenceMissing.Add("running Steam process") | Out-Null }
if ($steamWebHelperRunning) { $evidenceFound.Add("steamwebhelper process is running") | Out-Null } else { $evidenceMissing.Add("running steamwebhelper process") | Out-Null }
if ($steamOnlineSeen) { $evidenceFound.Add("Steam logs contain an online/session signal") | Out-Null }
if ($steamOfflineSeen) { $evidenceFound.Add("Steam logs contain an offline/no-connection signal") | Out-Null }
if ($steamCmFailureSeen) { $evidenceFound.Add("Steam logs contain CM connection failure evidence") | Out-Null }

$sessionVerdict = ""
$explanation = ""
if (-not $halfLifeAppearsInstalled) {
    $sessionVerdict = "steam-session-blocked-app-missing"
    $explanation = "Half-Life app 70 is not fully present for local public admission: the app manifest or hl.exe is missing."
}
elseif ($steamCmFailureSeen) {
    $sessionVerdict = "steam-session-blocked-cm-failure"
    $explanation = "Steam and Half-Life are discoverable, but Steam logs show CM/no-connection failure that can block public admission before HLDS connect."
}
elseif ($steamRunning -and $steamWebHelperRunning -and $steamOnlineSeen) {
    $sessionVerdict = "steam-session-ready"
    $explanation = "Steam and Half-Life prerequisites are present, Steam is running, and logs include an online/session signal."
}
elseif ($steamRunning -or $steamWebHelperRunning -or $manifestPresent -or $clientFound) {
    $sessionVerdict = "steam-session-ready-with-warnings"
    $explanation = "Steam and Half-Life prerequisites are mostly present, but the preflight did not detect a clean online/session signal."
}
else {
    $sessionVerdict = "steam-session-inconclusive"
    $explanation = "The preflight could not gather enough Steam session evidence to classify readiness."
}

$preflight = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    server_port = $ServerPort
    session_verdict = $sessionVerdict
    explanation = $explanation
    steam_exe_path = $resolvedSteamExePath
    steam_install_root = $steamInstallRoot
    steam_install_roots_checked = @((Get-SteamInstallRoots))
    steam_logs_root = $steamLogsRoot
    steam_running = $steamRunning
    steam_processes = @($steamProcesses)
    steamwebhelper_running = $steamWebHelperRunning
    steamwebhelper_processes = @($steamWebHelperProcesses)
    client_exe_path = $resolvedClientExePath
    client_discovery_verdict = [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "discovery_verdict" -Default "")
    client_discovery_explanation = [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "explanation" -Default "")
    hl_processes = @($hlProcesses)
    half_life_app_manifest_present = $manifestPresent
    half_life_app_manifest_path = if ($existingManifest) { [string]$existingManifest } else { "" }
    half_life_app_manifest_candidates = @($manifestCandidates)
    half_life_app_manifest = $manifestSummary
    half_life_appears_installed = $halfLifeAppearsInstalled
    steam_appears_online = $steamOnlineSeen
    steam_appears_offline = $steamOfflineSeen
    steam_cm_failure_seen = $steamCmFailureSeen
    steam_logs_checked = @($logsToCheck.ToArray())
    evidence_found = @($evidenceFound.ToArray())
    evidence_missing = @($evidenceMissing.ToArray())
    artifacts = [ordered]@{
        public_steam_session_preflight_json = $preflightJsonPath
        public_steam_session_preflight_markdown = $preflightMarkdownPath
    }
}

Write-JsonFile -Path $preflightJsonPath -Value $preflight
$preflightForMarkdown = Get-Content -LiteralPath $preflightJsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $preflightMarkdownPath -Value (Get-PreflightMarkdown -Preflight $preflightForMarkdown)

Write-Host "Public Steam session preflight:"
Write-Host "  Verdict: $sessionVerdict"
Write-Host "  Explanation: $explanation"
Write-Host "  Preflight JSON: $preflightJsonPath"
Write-Host "  Preflight Markdown: $preflightMarkdownPath"
