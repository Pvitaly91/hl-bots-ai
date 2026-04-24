[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ServerAddress = "127.0.0.1",
    [int]$ServerPort = 27015,
    [string]$SteamExePath = "",
    [string]$ClientExePath = "",
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [string]$ServerLogPath = "",
    [string]$OutputRoot = "",
    [switch]$DryRun,
    [switch]$NoClientCleanup,
    [int]$AdmissionWaitSeconds = 35,
    [int]$StatusPollSeconds = 2,
    [int]$InterVariantPauseSeconds = 3,
    [string[]]$VariantIds = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$promptId = Get-RepoPromptId
$repoRoot = Get-RepoRoot
$labRoot = Get-LabRootDefault

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 18
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Write-TextFile {
    param([string]$Path, [string]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Read-JsonFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Resolve-RepoPathMaybe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path $repoRoot $Path
}

function Get-FileTailText {
    param([string]$Path, [int]$LineCount = 120)
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

function Get-FileWriteTimeUtc {
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

function Get-ProcessSnapshot {
    param([string]$Name)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Sort-Object Id)) {
        $startTime = ""
        try { $startTime = $process.StartTime.ToString("o") } catch { $startTime = "" }
        $items.Add([ordered]@{
            id = [int]$process.Id
            process_name = [string]$process.ProcessName
            path = [string](Get-ObjectPropertyValue -Object $process -Name "Path" -Default "")
            start_time_local = $startTime
        }) | Out-Null
    }
    return @($items.ToArray())
}

function Get-NewProcessIds {
    param(
        [object[]]$Before,
        [object[]]$After
    )
    $beforeIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($entry in @($Before)) {
        [void]$beforeIds.Add([int]$entry.id)
    }

    $newIds = New-Object System.Collections.Generic.List[int]
    foreach ($entry in @($After)) {
        $entryId = [int]$entry.id
        if (-not $beforeIds.Contains($entryId)) {
            $newIds.Add($entryId) | Out-Null
        }
    }
    return @($newIds.ToArray())
}

function Get-ProcessRuntimeState {
    param([int]$ProcessId)
    if ($ProcessId -le 0) {
        return [ordered]@{ pid = $ProcessId; running = $false; exited = $true; exit_code = $null; lifetime_seconds = $null; path = "" }
    }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $startTimeUtc = $null
        try { $startTimeUtc = $process.StartTime.ToUniversalTime() } catch { $startTimeUtc = $null }
        $lifetime = if ($null -ne $startTimeUtc) { [Math]::Round(((Get-Date).ToUniversalTime() - $startTimeUtc).TotalSeconds, 2) } else { $null }
        return [ordered]@{
            pid = $ProcessId
            running = $true
            exited = $false
            exit_code = $null
            lifetime_seconds = $lifetime
            path = [string](Get-ObjectPropertyValue -Object $process -Name "Path" -Default "")
        }
    }
    catch {
        return [ordered]@{ pid = $ProcessId; running = $false; exited = $true; exit_code = $null; lifetime_seconds = $null; path = "" }
    }
}

function Test-ServerHumanEvent {
    param([string]$LogPath, [string]$Kind)
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return $null
    }
    $lines = @(Get-Content -LiteralPath $LogPath -Tail 260 -ErrorAction SilentlyContinue)
    if ($Kind -eq "connect") {
        return $lines | Where-Object { $_ -match "connected, address" -and $_ -notmatch "\bBOT\b" } | Select-Object -First 1
    }
    if ($Kind -eq "entered") {
        return $lines | Where-Object { $_ -match "entered the game" -and $_ -notmatch "\bBOT\b" } | Select-Object -First 1
    }
    return $null
}

function Get-LatestPublicServerStatusJsonPath {
    param([int]$Port)
    $root = Join-Path $labRoot "logs\public_server"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return ""
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Filter "public_server_status.json" -File -ErrorAction SilentlyContinue)) {
        $payload = Read-JsonFile -Path $file.FullName
        if ($null -eq $payload) { continue }
        if ([int](Get-ObjectPropertyValue -Object $payload -Name "port" -Default 0) -ne $Port) { continue }
        $candidates.Add([pscustomobject]@{ path = $file.FullName; write_time_utc = $file.LastWriteTimeUtc }) | Out-Null
    }
    $latest = $candidates | Sort-Object write_time_utc -Descending | Select-Object -First 1
    if ($null -eq $latest) { return "" }
    return [string]$latest.path
}

function Get-VariantMarkdown {
    param([object]$Report)
    $lines = @(
        "# Public HLDM Launch Variants",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Overall verdict: $($Report.overall_verdict)",
        "- Explanation: $($Report.explanation)",
        "- Server address: $($Report.server_address)",
        "- Server port: $($Report.server_port)",
        "- Public status JSON: $($Report.public_server_status_json_path)",
        "- Server log path: $($Report.server_log_path)",
        "- Dry run: $($Report.dry_run)",
        "- Cleanup launched clients: $($Report.cleanup_launched_clients)"
    )
    $lines += @("", "## Variants", "")
    foreach ($variant in @($Report.variants)) {
        $lines += "- $($variant.variant_id): available=$($variant.available); new_steam=$($variant.new_steam_process_observed); new_hl=$($variant.new_hl_process_observed); client_pid=$($variant.client_pid); server_connect_seen=$($variant.server_connect_seen); entered_the_game_seen=$($variant.entered_the_game_seen); authoritative_human_seen=$($variant.authoritative_human_seen); stage=$($variant.failure_stage)"
        $lines += "  command=$($variant.exact_command)"
        $lines += "  working_directory=$($variant.working_directory)"
        $lines += "  explanation=$($variant.explanation)"
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-Variant {
    param(
        [string]$VariantId,
        [string]$Description,
        [string]$LauncherPath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$CommandText,
        [bool]$Available,
        [string]$UnavailableReason,
        [string]$Kind
    )
    return [ordered]@{
        variant_id = $VariantId
        description = $Description
        launcher_path = $LauncherPath
        arguments = @($Arguments)
        working_directory = $WorkingDirectory
        exact_command = $CommandText
        available = $Available
        unavailable_reason = $UnavailableReason
        kind = $Kind
    }
}

if ($AdmissionWaitSeconds -lt 5) { throw "AdmissionWaitSeconds must be at least 5 seconds." }
if ($StatusPollSeconds -lt 1) { throw "StatusPollSeconds must be at least 1 second." }
if ($InterVariantPauseSeconds -lt 0) { throw "InterVariantPauseSeconds cannot be negative." }

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Ensure-Directory -Path (Join-Path $labRoot ("logs\public_server\launch_variants\{0}-public-hldm-launch-variants-p{1}" -f $stamp, $ServerPort))
}
else {
    $candidate = Resolve-RepoPathMaybe -Path $OutputRoot
    Ensure-Directory -Path $candidate
}

$reportJsonPath = Join-Path $resolvedOutputRoot "public_hldm_launch_variants.json"
$reportMarkdownPath = Join-Path $resolvedOutputRoot "public_hldm_launch_variants.md"

$resolvedPublicStatusJsonPath = Resolve-RepoPathMaybe -Path $PublicServerStatusJsonPath
$resolvedPublicServerOutputRoot = Resolve-RepoPathMaybe -Path $PublicServerOutputRoot
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
    $resolvedPublicStatusJsonPath = Get-LatestPublicServerStatusJsonPath -Port $ServerPort
}
if ([string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
    $resolvedPublicServerOutputRoot = Split-Path -Path $resolvedPublicStatusJsonPath -Parent
}

$publicStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$resolvedServerLogPath = Resolve-RepoPathMaybe -Path $ServerLogPath
if ([string]::IsNullOrWhiteSpace($resolvedServerLogPath) -and $null -ne $publicStatus) {
    $resolvedServerLogPath = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $publicStatus -Name "artifacts" -Default $null) -Name "hlds_stdout_log" -Default "")
}

$admissionPlan = Get-PublicHldmClientAdmissionPlan -PreferredSteamPath $SteamExePath -PreferredClientPath $ClientExePath -ServerAddress $ServerAddress -ServerPort $ServerPort
$joinAddress = [string]$admissionPlan.join_info.LoopbackAddress
$steamExe = [string]$admissionPlan.steam_exe_path
$steamWorkingDirectory = [string]$admissionPlan.steam_working_directory
$directPlan = $admissionPlan.direct_launch_plan
$clientExe = [string]$directPlan.client_exe_path
$clientWorkingDirectory = [string]$directPlan.client_working_directory
$qconsolePath = [string]$directPlan.qconsole_path
$steamConnectionLogPath = Get-SteamConnectionLogPath -Port $ServerPort

$steamNativeArgs = @("-applaunch", "70", "-game", "valve", "+connect", $joinAddress)
$steamNativeCommand = if (-not [string]::IsNullOrWhiteSpace($steamExe)) {
    (@((Format-ProcessArgumentText -Value $steamExe)) + @($steamNativeArgs | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) })) -join " "
} else { "" }
$steamConnectUri = [string]$admissionPlan.steam_connect_uri
$steamConnectCommand = if (-not [string]::IsNullOrWhiteSpace($steamExe) -and -not [string]::IsNullOrWhiteSpace($steamConnectUri)) {
    "{0} {1}" -f (Format-ProcessArgumentText -Value $steamExe), (Format-ProcessArgumentText -Value $steamConnectUri)
} else { "" }
$encodedRunArgs = [System.Uri]::EscapeDataString("+connect $joinAddress")
$steamRunConnectUri = "steam://run/70//$encodedRunArgs/"
$steamRunCommand = if (-not [string]::IsNullOrWhiteSpace($steamExe)) {
    "{0} {1}" -f (Format-ProcessArgumentText -Value $steamExe), (Format-ProcessArgumentText -Value $steamRunConnectUri)
} else { "" }

$directArgs = @("-game", "valve", "+connect", $joinAddress)
$directCommand = if (-not [string]::IsNullOrWhiteSpace($clientExe)) {
    (@((Format-ProcessArgumentText -Value $clientExe)) + @($directArgs | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) })) -join " "
} else { "" }

$allVariants = @(
    (New-Variant -VariantId "steam-native-applaunch" -Description "Steam native app 70 launch with explicit +connect arguments." -LauncherPath $steamExe -Arguments $steamNativeArgs -WorkingDirectory $steamWorkingDirectory -CommandText $steamNativeCommand -Available (-not [string]::IsNullOrWhiteSpace($steamExe)) -UnavailableReason "steam.exe was not discoverable." -Kind "steam"),
    (New-Variant -VariantId "steam-connect-uri" -Description "Steam handles a steam://connect URI for the public server target." -LauncherPath $steamExe -Arguments @($steamConnectUri) -WorkingDirectory $steamWorkingDirectory -CommandText $steamConnectCommand -Available (-not [string]::IsNullOrWhiteSpace($steamExe) -and -not [string]::IsNullOrWhiteSpace($steamConnectUri)) -UnavailableReason "steam.exe or the steam://connect URI was not available." -Kind "steam"),
    (New-Variant -VariantId "steam-run-connect-uri" -Description "Steam handles a steam://run/70 URI carrying URL-encoded +connect arguments." -LauncherPath $steamExe -Arguments @($steamRunConnectUri) -WorkingDirectory $steamWorkingDirectory -CommandText $steamRunCommand -Available (-not [string]::IsNullOrWhiteSpace($steamExe)) -UnavailableReason "steam.exe was not discoverable." -Kind "steam"),
    (New-Variant -VariantId "direct-hl-exe-connect" -Description "Direct discovered hl.exe launch with explicit +connect arguments." -LauncherPath $clientExe -Arguments $directArgs -WorkingDirectory $clientWorkingDirectory -CommandText $directCommand -Available ([bool]$directPlan.launchable) -UnavailableReason "hl.exe was not discoverable or launchable." -Kind "direct")
)

$selectedIds = if (@($VariantIds).Count -gt 0) { @($VariantIds) } else { @("steam-native-applaunch", "steam-connect-uri", "steam-run-connect-uri", "direct-hl-exe-connect") }
$variantResults = New-Object System.Collections.Generic.List[object]

foreach ($variantId in @($selectedIds)) {
    $variant = $allVariants | Where-Object { [string]$_["variant_id"] -eq $variantId } | Select-Object -First 1
    if ($null -eq $variant) {
        $variantResults.Add([ordered]@{
            variant_id = $variantId
            available = $false
            exact_command = ""
            working_directory = ""
            failure_stage = "variant-unknown"
            explanation = "This launch variant is not defined by the helper."
        }) | Out-Null
        continue
    }

    $attemptRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot ("variant_{0}" -f ($variantId -replace "[^A-Za-z0-9._-]", "_")))
    $variantJsonPath = Join-Path $attemptRoot "public_hldm_launch_variant_attempt.json"
    $steamBefore = @(Get-ProcessSnapshot -Name "steam")
    $hlBefore = @(Get-ProcessSnapshot -Name "hl")
    $qconsoleWriteBefore = Get-FileWriteTimeUtc -Path $qconsolePath
    $steamLogWriteBefore = Get-FileWriteTimeUtc -Path $steamConnectionLogPath
    $serverLogWriteBefore = Get-FileWriteTimeUtc -Path $resolvedServerLogPath
    $startedAtUtc = (Get-Date).ToUniversalTime()
    $launcherProcess = $null
    $launcherStarted = $false
    $launcherError = ""
    $launcherPid = 0

    if (-not [bool]$variant["available"]) {
        $failureStage = "path-unavailable"
        $explanation = [string]$variant["unavailable_reason"]
    }
    elseif ($DryRun) {
        $failureStage = "dry-run-not-executed"
        $explanation = "Recorded launch shape without executing this variant."
    }
    else {
        try {
            $startParams = @{
                FilePath = [string]$variant["launcher_path"]
                ArgumentList = @($variant["arguments"])
                PassThru = $true
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$variant["working_directory"])) {
                $startParams["WorkingDirectory"] = [string]$variant["working_directory"]
            }
            $launcherProcess = Start-Process @startParams
            $launcherStarted = $true
            if ($null -ne $launcherProcess) {
                $launcherPid = [int](Get-ObjectPropertyValue -Object $launcherProcess -Name "Id" -Default 0)
            }
        }
        catch {
            $launcherError = $_.Exception.Message
        }
        $failureStage = ""
        $explanation = ""
    }

    $firstConnectAtUtc = ""
    $firstEnteredAtUtc = ""
    $firstAuthoritativeAtUtc = ""
    $serverConnectLine = ""
    $serverEnteredLine = ""
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $AdmissionWaitSeconds))
    $hlAfter = @(Get-ProcessSnapshot -Name "hl")
    $steamAfter = @(Get-ProcessSnapshot -Name "steam")
    $latestStatus = $publicStatus

    if (-not $DryRun -and [bool]$variant["available"] -and $launcherStarted) {
        while ([DateTime]::UtcNow -lt $deadlineUtc) {
            $latestStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
            if ([string]::IsNullOrWhiteSpace($firstAuthoritativeAtUtc) -and $null -ne $latestStatus -and [int](Get-ObjectPropertyValue -Object $latestStatus -Name "human_player_count" -Default 0) -gt 0) {
                $firstAuthoritativeAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
            if ([string]::IsNullOrWhiteSpace($firstConnectAtUtc)) {
                $candidateConnect = [string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "connect")
                if (-not [string]::IsNullOrWhiteSpace($candidateConnect)) {
                    $firstConnectAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                    $serverConnectLine = $candidateConnect
                }
            }
            if ([string]::IsNullOrWhiteSpace($firstEnteredAtUtc)) {
                $candidateEntered = [string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "entered")
                if (-not [string]::IsNullOrWhiteSpace($candidateEntered)) {
                    $firstEnteredAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                    $serverEnteredLine = $candidateEntered
                }
            }
            $hlAfter = @(Get-ProcessSnapshot -Name "hl")
            $steamAfter = @(Get-ProcessSnapshot -Name "steam")
            if (-not [string]::IsNullOrWhiteSpace($firstAuthoritativeAtUtc) -or -not [string]::IsNullOrWhiteSpace($firstEnteredAtUtc)) {
                break
            }
            Start-Sleep -Seconds ([Math]::Max(1, $StatusPollSeconds))
        }
    }

    $steamAfter = @(Get-ProcessSnapshot -Name "steam")
    $hlAfter = @(Get-ProcessSnapshot -Name "hl")
    $newSteamIds = @(Get-NewProcessIds -Before $steamBefore -After $steamAfter)
    $newHlIds = @(Get-NewProcessIds -Before $hlBefore -After $hlAfter)
    $qconsoleWriteAfter = Get-FileWriteTimeUtc -Path $qconsolePath
    $steamLogWriteAfter = Get-FileWriteTimeUtc -Path $steamConnectionLogPath
    $serverLogWriteAfter = Get-FileWriteTimeUtc -Path $resolvedServerLogPath
    $latestStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
    $serverConnectSeen = -not [string]::IsNullOrWhiteSpace($firstConnectAtUtc) -or -not [string]::IsNullOrWhiteSpace([string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "connect"))
    $enteredSeen = -not [string]::IsNullOrWhiteSpace($firstEnteredAtUtc) -or -not [string]::IsNullOrWhiteSpace([string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "entered"))
    $authoritativeSeen = $null -ne $latestStatus -and [int](Get-ObjectPropertyValue -Object $latestStatus -Name "human_player_count" -Default 0) -gt 0

    if ([string]::IsNullOrWhiteSpace($failureStage)) {
        if (-not $launcherStarted) {
            $failureStage = "launch-failed"
            $explanation = if ([string]::IsNullOrWhiteSpace($launcherError)) { "The launch command did not start a process." } else { $launcherError }
        }
        elseif ($authoritativeSeen -or $enteredSeen) {
            $failureStage = "public-admission-working"
            $explanation = "This launch variant crossed the server-side public human-admission boundary."
        }
        elseif ($serverConnectSeen) {
            $failureStage = "server-connect-seen-but-entered-game-not-seen"
            $explanation = "The server saw a non-BOT connect, but the variant did not reach entered-the-game or authoritative human status before timeout."
        }
        elseif ([string]$variant["kind"] -eq "steam" -and @($newHlIds).Count -eq 0) {
            $failureStage = "steam-app-launch-path-broken"
            $explanation = "Steam launch command was issued, but no new hl.exe process materialized."
        }
        elseif (@($newHlIds).Count -gt 0) {
            $failureStage = "hl-client-launches-but-public-admission-never-starts"
            $explanation = "A new hl.exe process materialized, but the public server never logged a non-BOT connect."
        }
        else {
            $failureStage = "public-admission-blocked-before-server-connect"
            $explanation = "The variant did not produce a non-BOT server connect before timeout."
        }
    }

    $launcherExited = $false
    $launcherExitCode = $null
    if ($null -ne $launcherProcess) {
        try {
            $launcherProcess.Refresh()
            $launcherExited = [bool]$launcherProcess.HasExited
            if ($launcherExited) { $launcherExitCode = [int]$launcherProcess.ExitCode }
        }
        catch {
        }
    }

    $clientStates = New-Object System.Collections.Generic.List[object]
    foreach ($clientProcessId in @($newHlIds)) {
        $clientStates.Add((Get-ProcessRuntimeState -ProcessId $clientProcessId)) | Out-Null
    }

    if (-not $NoClientCleanup -and -not $DryRun) {
        foreach ($clientProcessId in @($newHlIds)) {
            try {
                Stop-Process -Id $clientProcessId -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
    }

    $result = [ordered]@{
        variant_id = [string]$variant["variant_id"]
        description = [string]$variant["description"]
        available = [bool]$variant["available"]
        exact_command = [string]$variant["exact_command"]
        working_directory = [string]$variant["working_directory"]
        started_at_utc = $startedAtUtc.ToString("o")
        ended_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        pre_existing_steam_processes = @($steamBefore)
        pre_existing_hl_processes = @($hlBefore)
        new_steam_process_observed = @($newSteamIds).Count -gt 0
        new_steam_process_ids = @($newSteamIds)
        new_hl_process_observed = @($newHlIds).Count -gt 0
        new_hl_process_ids = @($newHlIds)
        client_pid = if (@($newHlIds).Count -gt 0) { [int]$newHlIds[0] } else { 0 }
        client_process_lifetimes = @($clientStates.ToArray())
        launcher_process_started = $launcherStarted
        launcher_pid = $launcherPid
        launcher_process_exited = $launcherExited
        launcher_process_exit_code = $launcherExitCode
        server_connect_seen = $serverConnectSeen
        entered_the_game_seen = $enteredSeen
        authoritative_human_seen = $authoritativeSeen
        first_server_connect_observed_at_utc = $firstConnectAtUtc
        first_server_entered_game_observed_at_utc = $firstEnteredAtUtc
        first_authoritative_human_seen_at_utc = $firstAuthoritativeAtUtc
        server_connect_line = $serverConnectLine
        server_entered_game_line = $serverEnteredLine
        failure_stage = $failureStage
        explanation = $explanation
        log_paths_used = [ordered]@{
            qconsole_log = $qconsolePath
            steam_connection_log = $steamConnectionLogPath
            server_log = $resolvedServerLogPath
        }
        log_freshness = [ordered]@{
            qconsole_write_time_before_utc = $qconsoleWriteBefore
            qconsole_write_time_after_utc = $qconsoleWriteAfter
            qconsole_updated_during_attempt = (-not [string]::IsNullOrWhiteSpace($qconsoleWriteAfter) -and $qconsoleWriteAfter -ne $qconsoleWriteBefore)
            steam_connection_log_write_time_before_utc = $steamLogWriteBefore
            steam_connection_log_write_time_after_utc = $steamLogWriteAfter
            steam_connection_log_updated_during_attempt = (-not [string]::IsNullOrWhiteSpace($steamLogWriteAfter) -and $steamLogWriteAfter -ne $steamLogWriteBefore)
            server_log_write_time_before_utc = $serverLogWriteBefore
            server_log_write_time_after_utc = $serverLogWriteAfter
            server_log_updated_during_attempt = (-not [string]::IsNullOrWhiteSpace($serverLogWriteAfter) -and $serverLogWriteAfter -ne $serverLogWriteBefore)
        }
        tails = [ordered]@{
            qconsole_tail = Get-FileTailText -Path $qconsolePath -LineCount 80
            steam_connection_log_tail = Get-FileTailText -Path $steamConnectionLogPath -LineCount 100
            server_log_tail = Get-FileTailText -Path $resolvedServerLogPath -LineCount 140
        }
        artifacts = [ordered]@{
            public_hldm_launch_variant_attempt_json = $variantJsonPath
        }
    }

    Write-JsonFile -Path $variantJsonPath -Value $result
    $variantResults.Add($result) | Out-Null
    if ($InterVariantPauseSeconds -gt 0) { Start-Sleep -Seconds $InterVariantPauseSeconds }
}

$anyAuthoritative = @($variantResults.ToArray() | Where-Object { [bool]$_["authoritative_human_seen"] -or [bool]$_["entered_the_game_seen"] }).Count -gt 0
$anyConnect = @($variantResults.ToArray() | Where-Object { [bool]$_["server_connect_seen"] }).Count -gt 0
$anyHl = @($variantResults.ToArray() | Where-Object { [bool]$_["new_hl_process_observed"] }).Count -gt 0
$steamVariants = @($variantResults.ToArray() | Where-Object { [string]$_["variant_id"] -like "steam-*" -and [bool]$_["available"] })
$steamStartedNoHl = $steamVariants.Count -gt 0 -and @($steamVariants | Where-Object { [bool]$_["launcher_process_started"] -and -not [bool]$_["new_hl_process_observed"] }).Count -eq $steamVariants.Count

$overallVerdict = ""
$overallExplanation = ""
if ($anyAuthoritative) {
    $overallVerdict = "public-admission-working"
    $overallExplanation = "At least one launch variant crossed the server-side public human-admission boundary."
}
elseif ($anyConnect) {
    $overallVerdict = "server-connect-seen-but-entered-game-not-seen"
    $overallExplanation = "At least one launch variant reached non-BOT server connect, but no variant reached entered-the-game or authoritative human status."
}
elseif ($steamStartedNoHl) {
    $overallVerdict = "steam-app-launch-path-broken"
    $overallExplanation = "All available Steam-backed variants issued a launch but did not materialize a new hl.exe process."
}
elseif ($anyHl) {
    $overallVerdict = "hl-client-launches-but-public-admission-never-starts"
    $overallExplanation = "At least one variant materialized hl.exe, but no variant produced a non-BOT server connect."
}
else {
    $overallVerdict = "public-admission-blocked-before-server-connect"
    $overallExplanation = "No tested variant produced server-side public admission evidence."
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    server_address = $ServerAddress
    server_port = $ServerPort
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    server_log_path = $resolvedServerLogPath
    dry_run = [bool]$DryRun
    cleanup_launched_clients = -not [bool]$NoClientCleanup
    admission_wait_seconds = $AdmissionWaitSeconds
    status_poll_seconds = $StatusPollSeconds
    overall_verdict = $overallVerdict
    explanation = $overallExplanation
    variants = @($variantResults.ToArray())
    artifacts = [ordered]@{
        public_hldm_launch_variants_json = $reportJsonPath
        public_hldm_launch_variants_markdown = $reportMarkdownPath
    }
}

Write-JsonFile -Path $reportJsonPath -Value $report
$reportForMarkdown = Get-Content -LiteralPath $reportJsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $reportMarkdownPath -Value (Get-VariantMarkdown -Report $reportForMarkdown)

Write-Host "Public HLDM launch variants:"
Write-Host "  Verdict: $overallVerdict"
Write-Host "  Explanation: $overallExplanation"
Write-Host "  Variants JSON: $reportJsonPath"
Write-Host "  Variants Markdown: $reportMarkdownPath"
