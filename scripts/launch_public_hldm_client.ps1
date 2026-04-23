param(
    [string]$ServerAddress = "127.0.0.1",
    [int]$ServerPort = 27015,
    [string]$SteamExePath = "",
    [string]$ClientExePath = "",
    [switch]$UseSteamLaunchPath,
    [switch]$UseDirectClientLaunchPath,
    [switch]$DryRun,
    [string]$OutputRoot = "",
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [string]$ServerLogPath = "",
    [int]$AdmissionWaitSeconds = 45,
    [int]$StatusPollSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$promptId = "HLDM-JKBOTTI-AI-STAND-20260415-71"
$repoRoot = Get-RepoRoot
$resolvedLabRoot = Get-LabRootDefault
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $defaultKind = if ($UseDirectClientLaunchPath) { "direct-hl-exe" } else { "steam-native-applaunch" }
    Ensure-Directory -Path (Join-Path $resolvedLabRoot ("logs\public_server\client_admissions\{0}-launch-public-hldm-client-p{1}-{2}" -f $stamp, $ServerPort, $defaultKind))
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
    Ensure-Directory -Path $candidate
}

$attemptJsonPath = Join-Path $resolvedOutputRoot "public_client_admission_attempt.json"
$attemptMarkdownPath = Join-Path $resolvedOutputRoot "public_client_admission_attempt.md"

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 12
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

function Get-FileTailText {
    param(
        [string]$Path,
        [int]$LineCount = 120
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

function Get-HlProcesses {
    return @(Get-Process -Name "hl" -ErrorAction SilentlyContinue | Sort-Object -Property Id)
}

function Get-NewHlProcessIds {
    param([int[]]$BeforeIds = @())

    $beforeLookup = New-Object System.Collections.Generic.HashSet[int]
    foreach ($id in @($BeforeIds)) {
        [void]$beforeLookup.Add([int]$id)
    }

    $newIds = New-Object System.Collections.Generic.List[int]
    foreach ($process in @(Get-HlProcesses)) {
        if ($beforeLookup.Contains([int]$process.Id)) {
            continue
        }

        $newIds.Add([int]$process.Id) | Out-Null
    }

    return @($newIds.ToArray())
}

function Test-ServerHumanEvent {
    param(
        [string]$LogPath,
        [string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return $null
    }

    $lines = @(Get-Content -LiteralPath $LogPath -Tail 220 -ErrorAction SilentlyContinue)
    if ($Kind -eq "connect") {
        return $lines | Where-Object { $_ -match "connected, address" -and $_ -notmatch "\bBOT\b" } | Select-Object -First 1
    }

    if ($Kind -eq "entered") {
        return $lines | Where-Object { $_ -match "entered the game" -and $_ -notmatch "\bBOT\b" } | Select-Object -First 1
    }

    return $null
}

function Get-AttemptMarkdown {
    param([object]$Attempt)

    $serverTailText = [string](Get-ObjectPropertyValue -Object $Attempt -Name "server_log_tail" -Default "")
    $qconsoleTailText = [string](Get-ObjectPropertyValue -Object $Attempt -Name "qconsole_tail" -Default "")
    $steamTailText = [string](Get-ObjectPropertyValue -Object $Attempt -Name "steam_connection_log_tail" -Default "")
    $lines = @(
        "# Public Client Admission Attempt",
        "",
        "- Generated at UTC: $($Attempt.generated_at_utc)",
        "- Prompt ID: $($Attempt.prompt_id)",
        "- Verdict: $($Attempt.attempt_verdict)",
        "- Explanation: $($Attempt.explanation)",
        "- Admission path kind: $($Attempt.attempt_path_kind)",
        "- Admission confirmed: $($Attempt.admission_confirmed)",
        "- Server connect seen: $($Attempt.server_connect_seen)",
        "- Server entered the game seen: $($Attempt.server_entered_game_seen)",
        "- Authoritative human seen: $($Attempt.authoritative_human_seen)",
        "- Launcher process started: $($Attempt.launcher_process_started)",
        "- Launcher PID: $($Attempt.launcher_process_id)",
        "- New hl.exe PIDs: $((@($Attempt.launched_hl_process_ids) -join ', '))",
        "- Command: $($Attempt.command_text)",
        "- Working directory: $($Attempt.working_directory)",
        "- Steam executable: $($Attempt.steam_exe_path)",
        "- Client executable: $($Attempt.client_exe_path)",
        "- Public status JSON: $($Attempt.public_server_status_json_path)",
        "- Server log path: $($Attempt.server_log_path)",
        "- qconsole path: $($Attempt.qconsole_path)",
        "- Steam connection log path: $($Attempt.steam_connection_log_path)"
    )

    if ($Attempt.first_authoritative_human_seen_at_utc) {
        $lines += "- First authoritative human seen at UTC: $($Attempt.first_authoritative_human_seen_at_utc)"
    }
    if ($Attempt.first_server_connect_observed_at_utc) {
        $lines += "- First server connect seen at UTC: $($Attempt.first_server_connect_observed_at_utc)"
    }
    if ($Attempt.first_server_entered_game_observed_at_utc) {
        $lines += "- First entered-the-game seen at UTC: $($Attempt.first_server_entered_game_observed_at_utc)"
    }

    $lines += @(
        "",
        "## Log Freshness",
        "",
        "- qconsole updated during attempt: $($Attempt.qconsole_updated_during_attempt)",
        "- Steam connection log updated during attempt: $($Attempt.steam_connection_log_updated_during_attempt)",
        "- Server log updated during attempt: $($Attempt.server_log_updated_during_attempt)"
    )

    if ($Attempt.public_server_latest_status) {
        $lines += @(
            "",
            "## Latest Public Status",
            "",
            "- Policy state: $($Attempt.public_server_latest_status.policy_state)",
            "- Human count: $($Attempt.public_server_latest_status.human_player_count)",
            "- Bot count: $($Attempt.public_server_latest_status.bot_player_count)",
            "- Human count source: $($Attempt.public_server_latest_status.human_count_source)"
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($serverTailText)) {
        $lines += @(
            "",
            "## Server Log Tail",
            "",
            '```text',
            $serverTailText,
            '```'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($qconsoleTailText)) {
        $lines += @(
            "",
            "## qconsole Tail",
            "",
            '```text',
            $qconsoleTailText,
            '```'
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($steamTailText)) {
        $lines += @(
            "",
            "## Steam Connection Log Tail",
            "",
            '```text',
            $steamTailText,
            '```'
        )
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedPublicServerOutputRoot = ""
if (-not [string]::IsNullOrWhiteSpace($PublicServerOutputRoot)) {
    $resolvedPublicServerOutputRoot = if ([System.IO.Path]::IsPathRooted($PublicServerOutputRoot)) {
        $PublicServerOutputRoot
    }
    else {
        Join-Path $repoRoot $PublicServerOutputRoot
    }
}

$resolvedPublicStatusJsonPath = ""
if (-not [string]::IsNullOrWhiteSpace($PublicServerStatusJsonPath)) {
    if ([System.IO.Path]::IsPathRooted($PublicServerStatusJsonPath)) {
        $resolvedPublicStatusJsonPath = $PublicServerStatusJsonPath
    }
    else {
        $resolvedPublicStatusJsonPath = Join-Path $repoRoot $PublicServerStatusJsonPath
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}

$admissionPlan = Get-PublicHldmClientAdmissionPlan -PreferredSteamPath $SteamExePath -PreferredClientPath $ClientExePath -ServerAddress $ServerAddress -ServerPort $ServerPort
$pathKind = ""
if ($UseDirectClientLaunchPath) {
    $pathKind = "direct-hl-exe"
}
elseif ($UseSteamLaunchPath -or -not $UseDirectClientLaunchPath) {
    $pathKind = "steam-native-applaunch"
}
else {
    $pathKind = [string]$admissionPlan.preferred_launch_path
}

$publicStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$resolvedServerLogPath = ""
if (-not [string]::IsNullOrWhiteSpace($ServerLogPath)) {
    if ([System.IO.Path]::IsPathRooted($ServerLogPath)) {
        $resolvedServerLogPath = $ServerLogPath
    }
    else {
        $resolvedServerLogPath = Join-Path $repoRoot $ServerLogPath
    }
}
elseif ($null -ne $publicStatus) {
    $resolvedServerLogPath = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $publicStatus -Name "artifacts" -Default $null) -Name "hlds_stdout_log" -Default "")
}

$qconsolePath = [string]$admissionPlan.direct_launch_plan.qconsole_path
$steamConnectionLogPath = Get-SteamConnectionLogPath -Port $ServerPort

$commandText = ""
$workingDirectory = ""
$launcherPath = ""
$launcherArguments = @()
$launcherAvailable = $false
$launchExplanation = ""

if ($pathKind -eq "steam-native-applaunch") {
    $launcherPath = [string]$admissionPlan.steam_exe_path
    $launcherArguments = @($admissionPlan.steam_launch_arguments)
    $commandText = [string]$admissionPlan.steam_launch_command_text
    $workingDirectory = [string]$admissionPlan.steam_working_directory
    $launcherAvailable = -not [string]::IsNullOrWhiteSpace($launcherPath)
    if ($launcherAvailable) {
        $launchExplanation = "Steam-native applaunch path selected."
    }
    else {
        $launchExplanation = "Steam.exe was not discoverable for the public admission attempt."
    }
}
elseif ($pathKind -eq "direct-hl-exe") {
    $launcherPath = [string]$admissionPlan.direct_launch_plan.client_exe_path
    $launcherArguments = @($admissionPlan.direct_launch_plan.arguments)
    $commandText = [string]$admissionPlan.direct_launch_plan.command_text
    $workingDirectory = [string]$admissionPlan.direct_launch_plan.client_working_directory
    $launcherAvailable = [bool]$admissionPlan.direct_launch_plan.launchable
    if ($launcherAvailable) {
        $launchExplanation = "Direct hl.exe path selected."
    }
    else {
        $launchExplanation = [string]$admissionPlan.direct_launch_plan.client_discovery.explanation
    }
}
else {
    $launchExplanation = "No launch path was selected or available."
}

$attemptStartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
$beforeHlIds = @(Get-HlProcesses | Select-Object -ExpandProperty Id)
$qconsoleWriteBefore = Get-FileWriteTimeUtc -Path $qconsolePath
$steamLogWriteBefore = Get-FileWriteTimeUtc -Path $steamConnectionLogPath
$serverLogWriteBefore = Get-FileWriteTimeUtc -Path $resolvedServerLogPath

$launcherProcess = $null
$launcherProcessId = 0
$launcherProcessStarted = $false
$firstAuthoritativeHumanSeenAtUtc = ""
$firstServerConnectObservedAtUtc = ""
$firstServerEnteredObservedAtUtc = ""
$serverConnectLine = ""
$serverEnteredLine = ""

if (-not $DryRun -and $launcherAvailable) {
    try {
        $startProcessParams = @{
            FilePath = $launcherPath
            ArgumentList = $launcherArguments
            PassThru = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) {
            $startProcessParams["WorkingDirectory"] = $workingDirectory
        }

        $launcherProcess = Start-Process @startProcessParams
        $launcherProcessStarted = $true
        if ($null -ne $launcherProcess) {
            $launcherProcessId = [int](Get-ObjectPropertyValue -Object $launcherProcess -Name "Id" -Default 0)
        }
        Start-Sleep -Seconds 2
    }
    catch {
        $launchExplanation = $_.Exception.Message
    }
}

$latestStatus = $publicStatus
$newHlProcessIds = @(Get-NewHlProcessIds -BeforeIds $beforeHlIds)
$deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $AdmissionWaitSeconds))
if (-not $DryRun) {
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $latestStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
        if ([string]::IsNullOrWhiteSpace($firstAuthoritativeHumanSeenAtUtc) -and $null -ne $latestStatus -and [int](Get-ObjectPropertyValue -Object $latestStatus -Name "human_player_count" -Default 0) -gt 0) {
            $firstAuthoritativeHumanSeenAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }

        if ([string]::IsNullOrWhiteSpace($firstServerConnectObservedAtUtc)) {
            $candidateConnectLine = [string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "connect")
            if (-not [string]::IsNullOrWhiteSpace($candidateConnectLine)) {
                $firstServerConnectObservedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                $serverConnectLine = $candidateConnectLine
            }
        }

        if ([string]::IsNullOrWhiteSpace($firstServerEnteredObservedAtUtc)) {
            $candidateEnteredLine = [string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "entered")
            if (-not [string]::IsNullOrWhiteSpace($candidateEnteredLine)) {
                $firstServerEnteredObservedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                $serverEnteredLine = $candidateEnteredLine
            }
        }

        $newHlProcessIds = @(Get-NewHlProcessIds -BeforeIds $beforeHlIds)
        if (-not [string]::IsNullOrWhiteSpace($firstAuthoritativeHumanSeenAtUtc) -or -not [string]::IsNullOrWhiteSpace($firstServerEnteredObservedAtUtc)) {
            break
        }

        Start-Sleep -Seconds ([Math]::Max(1, $StatusPollSeconds))
    }
}

$latestStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$authoritativeHumanSeen = $null -ne $latestStatus -and [int](Get-ObjectPropertyValue -Object $latestStatus -Name "human_player_count" -Default 0) -gt 0
$serverConnectSeen = -not [string]::IsNullOrWhiteSpace($firstServerConnectObservedAtUtc) -or -not [string]::IsNullOrWhiteSpace([string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "connect"))
$serverEnteredSeen = -not [string]::IsNullOrWhiteSpace($firstServerEnteredObservedAtUtc) -or -not [string]::IsNullOrWhiteSpace([string](Test-ServerHumanEvent -LogPath $resolvedServerLogPath -Kind "entered"))
$admissionConfirmed = $authoritativeHumanSeen -or $serverEnteredSeen
$qconsoleWriteAfter = Get-FileWriteTimeUtc -Path $qconsolePath
$steamLogWriteAfter = Get-FileWriteTimeUtc -Path $steamConnectionLogPath
$serverLogWriteAfter = Get-FileWriteTimeUtc -Path $resolvedServerLogPath
$qconsoleTail = Get-FileTailText -Path $qconsolePath -LineCount 120
$steamLogTail = Get-FileTailText -Path $steamConnectionLogPath -LineCount 120
$serverLogTail = Get-FileTailText -Path $resolvedServerLogPath -LineCount 160

if ($launcherProcessStarted -and $null -ne $launcherProcess) {
    try {
        $launcherProcess.Refresh()
    }
    catch {
    }
}

$launcherProcessExited = $false
$launcherProcessExitCode = $null
if ($null -ne $launcherProcess) {
    try {
        $launcherProcessExited = [bool]$launcherProcess.HasExited
        if ($launcherProcessExited) {
            $launcherProcessExitCode = [int]$launcherProcess.ExitCode
        }
    }
    catch {
    }
}

$attemptVerdict = ""
$explanation = ""
if ($DryRun) {
    $attemptVerdict = "dry-run-ready"
    $explanation = "Recorded the resolved public-mode admission command without launching a client process."
}
elseif (-not $launcherAvailable -or -not $launcherProcessStarted) {
    $attemptVerdict = "launch-prereq-missing"
    $explanation = $launchExplanation
}
elseif ($admissionConfirmed) {
    $attemptVerdict = "entered-game-seen-human-admitted"
    $explanation = "A real public-mode admission signal was observed: the authoritative human count rose above zero or the server logged a non-BOT entered-the-game event."
}
elseif ($serverConnectSeen) {
    $attemptVerdict = "server-connect-seen-no-entered-game"
    $explanation = "The server logged a non-BOT connect, but no non-BOT entered-the-game event was observed before the admission timeout expired."
}
elseif ($pathKind -eq "steam-native-applaunch" -and @($newHlProcessIds).Count -eq 0) {
    $attemptVerdict = "steam-launch-attempted-no-client-process"
    $explanation = "The Steam-native public admission launch was attempted, but no new hl.exe client process became visible afterward."
}
else {
    $attemptVerdict = "client-process-started-no-server-admission"
    $explanation = "A local public admission launch ran, but the server never counted a real human and never logged a non-BOT connect or entered-the-game event."
}

$attempt = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_verdict = $attemptVerdict
    explanation = $explanation
    dry_run = [bool]$DryRun
    attempt_path_kind = $pathKind
    preferred_launch_path = [string]$admissionPlan.preferred_launch_path
    server_address = $ServerAddress
    server_port = $ServerPort
    command_text = $commandText
    working_directory = $workingDirectory
    steam_exe_path = [string]$admissionPlan.steam_exe_path
    client_exe_path = [string]$admissionPlan.direct_launch_plan.client_exe_path
    client_working_directory = [string]$admissionPlan.direct_launch_plan.client_working_directory
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    server_log_path = $resolvedServerLogPath
    qconsole_path = $qconsolePath
    steam_connection_log_path = $steamConnectionLogPath
    attempt_started_at_utc = $attemptStartedAtUtc
    launcher_process_started = $launcherProcessStarted
    launcher_process_id = $launcherProcessId
    launcher_process_exited = $launcherProcessExited
    launcher_process_exit_code = $launcherProcessExitCode
    launched_hl_process_ids = @($newHlProcessIds)
    authoritative_human_seen = $authoritativeHumanSeen
    server_connect_seen = $serverConnectSeen
    server_entered_game_seen = $serverEnteredSeen
    admission_confirmed = $admissionConfirmed
    first_authoritative_human_seen_at_utc = $firstAuthoritativeHumanSeenAtUtc
    first_server_connect_observed_at_utc = $firstServerConnectObservedAtUtc
    first_server_entered_game_observed_at_utc = $firstServerEnteredObservedAtUtc
    server_connect_line = $serverConnectLine
    server_entered_game_line = $serverEnteredLine
    qconsole_write_time_before_utc = $qconsoleWriteBefore
    qconsole_write_time_after_utc = $qconsoleWriteAfter
    qconsole_updated_during_attempt = (-not [string]::IsNullOrWhiteSpace($qconsoleWriteAfter) -and $qconsoleWriteAfter -ne $qconsoleWriteBefore)
    steam_connection_log_write_time_before_utc = $steamLogWriteBefore
    steam_connection_log_write_time_after_utc = $steamLogWriteAfter
    steam_connection_log_updated_during_attempt = (-not [string]::IsNullOrWhiteSpace($steamLogWriteAfter) -and $steamLogWriteAfter -ne $steamLogWriteBefore)
    server_log_write_time_before_utc = $serverLogWriteBefore
    server_log_write_time_after_utc = $serverLogWriteAfter
    server_log_updated_during_attempt = (-not [string]::IsNullOrWhiteSpace($serverLogWriteAfter) -and $serverLogWriteAfter -ne $serverLogWriteBefore)
    qconsole_tail = $qconsoleTail
    steam_connection_log_tail = $steamLogTail
    server_log_tail = $serverLogTail
    public_server_latest_status = $latestStatus
    artifacts = [ordered]@{
        public_client_admission_attempt_json = $attemptJsonPath
        public_client_admission_attempt_markdown = $attemptMarkdownPath
    }
}

Write-JsonFile -Path $attemptJsonPath -Value $attempt
$attemptForMarkdown = Read-JsonFile -Path $attemptJsonPath
Write-TextFile -Path $attemptMarkdownPath -Value (Get-AttemptMarkdown -Attempt $attemptForMarkdown)

Write-Host "Public client admission attempt:"
Write-Host "  Path kind: $pathKind"
Write-Host "  Verdict: $attemptVerdict"
Write-Host "  Explanation: $explanation"
Write-Host "  Attempt JSON: $attemptJsonPath"
Write-Host "  Attempt Markdown: $attemptMarkdownPath"
