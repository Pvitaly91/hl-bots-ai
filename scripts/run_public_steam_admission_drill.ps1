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
    [int]$AdmissionWaitSeconds = 45,
    [int]$StatusPollSeconds = 2,
    [int]$MaxPublicStatusAgeSeconds = 180
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

    $json = $Value | ConvertTo-Json -Depth 18
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

function Get-JsonFileAgeSeconds {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return -1
    }

    try {
        return [int][Math]::Round(((Get-Date).ToUniversalTime() - [System.IO.File]::GetLastWriteTimeUtc($Path)).TotalSeconds)
    }
    catch {
        return -1
    }
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
        if ($null -eq $payload) {
            continue
        }

        $candidatePort = [int](Get-ObjectPropertyValue -Object $payload -Name "port" -Default 0)
        if ($candidatePort -ne $Port) {
            continue
        }

        $candidates.Add([pscustomobject]@{
            path = $file.FullName
            write_time_utc = $file.LastWriteTimeUtc
        }) | Out-Null
    }

    $latest = $candidates | Sort-Object -Property write_time_utc -Descending | Select-Object -First 1
    if ($null -eq $latest) {
        return ""
    }

    return [string]$latest.path
}

function Convert-InvocationParametersForReport {
    param([hashtable]$Parameters)

    $ordered = [ordered]@{}
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        $ordered[$key] = $Parameters[$key]
    }

    return $ordered
}

function Invoke-DrillChildScript {
    param(
        [string]$ScriptPath,
        [hashtable]$Parameters,
        [string]$TranscriptPath
    )

    $outputLines = New-Object System.Collections.Generic.List[string]
    $success = $false
    $errorMessage = ""

    try {
        foreach ($line in @(& $ScriptPath @Parameters 2>&1)) {
            $outputLines.Add([string]$line) | Out-Null
        }
        $success = $true
    }
    catch {
        $errorMessage = $_.Exception.Message
        $outputLines.Add([string]$_) | Out-Null
    }

    Write-TextFile -Path $TranscriptPath -Value (($outputLines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)

    return [ordered]@{
        script_path = $ScriptPath
        success = $success
        error = $errorMessage
        transcript_path = $TranscriptPath
        parameters = Convert-InvocationParametersForReport -Parameters $Parameters
    }
}

function Get-ProcessStateForPid {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return [ordered]@{
            pid = $ProcessId
            running = $false
            process_name = ""
            start_time_local = ""
        }
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $startTime = ""
        try {
            $startTime = $process.StartTime.ToString("o")
        }
        catch {
            $startTime = ""
        }

        return [ordered]@{
            pid = $ProcessId
            running = $true
            process_name = [string]$process.ProcessName
            start_time_local = $startTime
        }
    }
    catch {
        return [ordered]@{
            pid = $ProcessId
            running = $false
            process_name = ""
            start_time_local = ""
        }
    }
}

function Test-TextForSteamAdmissionFailure {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return $Text -match "GetCMListForConnect -- web API call failed|failed talking to cm|ConnectFailed\(|StartAutoReconnect|Unable to initialize Steam"
}

function Get-PathDrillSummary {
    param([object]$PathResult)

    $pathId = [string](Get-ObjectPropertyValue -Object $PathResult -Name "path_id" -Default "")
    $artifacts = Get-ObjectPropertyValue -Object $PathResult -Name "artifacts" -Default $null
    $attemptJsonPath = [string](Get-ObjectPropertyValue -Object $artifacts -Name "public_client_admission_attempt_json" -Default "")
    $diagnosisJsonPath = [string](Get-ObjectPropertyValue -Object $artifacts -Name "public_client_admission_diagnosis_json" -Default "")
    $attempt = Read-JsonFile -Path $attemptJsonPath
    $diagnosis = Read-JsonFile -Path $diagnosisJsonPath

    $launcherStarted = [bool](Get-ObjectPropertyValue -Object $PathResult -Name "launcher_process_started" -Default $false)
    $launcherPid = 0
    $launcherExited = $false
    $launcherExitCode = $null
    $clientPids = @()
    $steamLogsAdvanced = $false
    $qconsoleAdvanced = $false
    $serverLogAdvanced = $false
    $attemptVerdict = ""
    $attemptExplanation = ""
    $qconsolePath = ""
    $steamConnectionLogPath = ""
    $serverLogPath = ""
    $steamFailureSeen = $false
    $commandText = [string](Get-ObjectPropertyValue -Object $PathResult -Name "command_text" -Default "")
    $workingDirectory = [string](Get-ObjectPropertyValue -Object $PathResult -Name "working_directory" -Default "")

    if ($null -ne $attempt) {
        $launcherStarted = [bool](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_started" -Default $launcherStarted)
        $launcherPid = [int](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_id" -Default 0)
        $launcherExited = [bool](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_exited" -Default $false)
        $launcherExitCode = Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_exit_code" -Default $null
        $clientPids = @((Get-ObjectPropertyValue -Object $attempt -Name "launched_hl_process_ids" -Default @()) | ForEach-Object { [int]$_ })
        $steamLogsAdvanced = [bool](Get-ObjectPropertyValue -Object $attempt -Name "steam_connection_log_updated_during_attempt" -Default $false)
        $qconsoleAdvanced = [bool](Get-ObjectPropertyValue -Object $attempt -Name "qconsole_updated_during_attempt" -Default $false)
        $serverLogAdvanced = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_log_updated_during_attempt" -Default $false)
        $attemptVerdict = [string](Get-ObjectPropertyValue -Object $attempt -Name "attempt_verdict" -Default "")
        $attemptExplanation = [string](Get-ObjectPropertyValue -Object $attempt -Name "explanation" -Default "")
        $qconsolePath = [string](Get-ObjectPropertyValue -Object $attempt -Name "qconsole_path" -Default "")
        $steamConnectionLogPath = [string](Get-ObjectPropertyValue -Object $attempt -Name "steam_connection_log_path" -Default "")
        $serverLogPath = [string](Get-ObjectPropertyValue -Object $attempt -Name "server_log_path" -Default "")
        $commandText = [string](Get-ObjectPropertyValue -Object $attempt -Name "command_text" -Default $commandText)
        $workingDirectory = [string](Get-ObjectPropertyValue -Object $attempt -Name "working_directory" -Default $workingDirectory)
        $steamFailureSeen = Test-TextForSteamAdmissionFailure -Text ([string](Get-ObjectPropertyValue -Object $attempt -Name "steam_connection_log_tail" -Default ""))
        if (-not $steamFailureSeen) {
            $steamFailureSeen = Test-TextForSteamAdmissionFailure -Text ([string](Get-ObjectPropertyValue -Object $attempt -Name "qconsole_tail" -Default ""))
        }
    }

    $diagnosisStage = [string](Get-ObjectPropertyValue -Object $diagnosis -Name "stage_verdict" -Default "")
    $diagnosisExplanation = [string](Get-ObjectPropertyValue -Object $diagnosis -Name "explanation" -Default "")
    if ($null -ne $diagnosis) {
        if (-not $steamFailureSeen) {
            $steamFailureSeen = [bool](Get-ObjectPropertyValue -Object $diagnosis -Name "steam_connection_log_contains_cm_failure" -Default $false) -or
                [bool](Get-ObjectPropertyValue -Object $diagnosis -Name "qconsole_contains_steam_init_failure" -Default $false)
        }
    }

    $serverConnectSeen = [bool](Get-ObjectPropertyValue -Object $PathResult -Name "server_connect_seen" -Default $false)
    $enteredGameSeen = [bool](Get-ObjectPropertyValue -Object $PathResult -Name "entered_the_game_seen" -Default $false)
    $authoritativeHumanSeen = [bool](Get-ObjectPropertyValue -Object $PathResult -Name "authoritative_human_seen" -Default $false)
    if ($null -ne $attempt) {
        $serverConnectSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_connect_seen" -Default $serverConnectSeen)
        $enteredGameSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_entered_game_seen" -Default $enteredGameSeen)
        $authoritativeHumanSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "authoritative_human_seen" -Default $authoritativeHumanSeen)
    }

    $failureStage = if (-not [string]::IsNullOrWhiteSpace($diagnosisStage)) {
        $diagnosisStage
    }
    else {
        [string](Get-ObjectPropertyValue -Object $PathResult -Name "narrowest_failure_stage" -Default "")
    }

    if ($pathId -eq "direct-hl-exe-connect" -and $failureStage -eq "steam-launch-not-attempted" -and -not [string]::IsNullOrWhiteSpace($attemptVerdict)) {
        $failureStage = $attemptVerdict
    }

    $explanation = if (-not [string]::IsNullOrWhiteSpace($diagnosisExplanation)) {
        $diagnosisExplanation
    }
    elseif (-not [string]::IsNullOrWhiteSpace($attemptExplanation)) {
        $attemptExplanation
    }
    else {
        [string](Get-ObjectPropertyValue -Object $PathResult -Name "explanation" -Default "")
    }

    $hlProcessStates = New-Object System.Collections.Generic.List[object]
    foreach ($clientProcessId in @($clientPids)) {
        $hlProcessStates.Add((Get-ProcessStateForPid -ProcessId $clientProcessId)) | Out-Null
    }

    return [ordered]@{
        path_label = $pathId
        path_available = [bool](Get-ObjectPropertyValue -Object $PathResult -Name "path_available" -Default $false)
        exact_command_line = $commandText
        working_directory = $workingDirectory
        steam_exe_started = ($pathId -in @("steam-native-applaunch", "steam-connect-uri")) -and $launcherStarted
        launcher_process_started = $launcherStarted
        launcher_pid = $launcherPid
        launcher_process_exited = $launcherExited
        launcher_process_exit_code = $launcherExitCode
        hl_exe_materialized = (@($clientPids).Count -gt 0)
        client_pid = if (@($clientPids).Count -gt 0) { [int]$clientPids[0] } else { 0 }
        client_pids = @($clientPids)
        client_process_states_after_drill = @($hlProcessStates.ToArray())
        steam_side_logs_advanced = $steamLogsAdvanced
        qconsole_advanced = $qconsoleAdvanced
        server_log_advanced = $serverLogAdvanced
        steam_side_failure_seen = $steamFailureSeen
        server_connect_seen = $serverConnectSeen
        entered_the_game_seen = $enteredGameSeen
        authoritative_human_seen = $authoritativeHumanSeen
        narrowest_failure_stage = $failureStage
        explanation = $explanation
        log_file_locations = [ordered]@{
            qconsole_log = $qconsolePath
            steam_connection_log = $steamConnectionLogPath
            server_log = $serverLogPath
        }
        artifacts = [ordered]@{
            public_client_admission_attempt_json = $attemptJsonPath
            public_client_admission_diagnosis_json = $diagnosisJsonPath
        }
    }
}

function Get-DrillClassification {
    param(
        [object]$EnvironmentAudit,
        [object[]]$PathSummaries,
        [bool]$ServerContextFresh,
        [string]$ServerContextExplanation
    )

    $anyAuthoritative = @($PathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "authoritative_human_seen" -Default $false) }).Count -gt 0
    $anyEntered = @($PathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "entered_the_game_seen" -Default $false) }).Count -gt 0
    $anyConnect = @($PathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "server_connect_seen" -Default $false) }).Count -gt 0
    $anyHlMaterialized = @($PathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "hl_exe_materialized" -Default $false) }).Count -gt 0
    $anySteamFailure = @($PathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "steam_side_failure_seen" -Default $false) }).Count -gt 0
    $anySteamLogAdvanced = @($PathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "steam_side_logs_advanced" -Default $false) }).Count -gt 0
    $steamPathSummaries = @($PathSummaries | Where-Object { [string](Get-ObjectPropertyValue -Object $_ -Name "path_label" -Default "") -in @("steam-native-applaunch", "steam-connect-uri") })
    $availableSteamSummaries = @($steamPathSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "path_available" -Default $false) })
    $steamLaunchersStarted = @($availableSteamSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "launcher_process_started" -Default $false) }).Count
    $steamHlMaterialized = @($availableSteamSummaries | Where-Object { [bool](Get-ObjectPropertyValue -Object $_ -Name "hl_exe_materialized" -Default $false) }).Count

    $steamExePath = [string](Get-ObjectPropertyValue -Object $EnvironmentAudit -Name "steam_exe_path" -Default "")
    $clientExePath = [string](Get-ObjectPropertyValue -Object $EnvironmentAudit -Name "client_exe_path" -Default "")
    $steamRunning = [bool](Get-ObjectPropertyValue -Object $EnvironmentAudit -Name "steam_running" -Default $false)
    $steamWebHelperRunning = [bool](Get-ObjectPropertyValue -Object $EnvironmentAudit -Name "steamwebhelper_running" -Default $false)
    $manifestPresent = [bool](Get-ObjectPropertyValue -Object $EnvironmentAudit -Name "half_life_app_manifest_present" -Default $false)
    $environmentConclusion = [string](Get-ObjectPropertyValue -Object $EnvironmentAudit -Name "conclusion" -Default "")

    if ($anyAuthoritative -or $anyEntered) {
        return [ordered]@{
            diagnosis = "public-admission-working"
            explanation = "At least one admission path crossed the server-side human boundary, so the public human-trigger validator is justified now."
        }
    }

    if ($anyConnect) {
        return [ordered]@{
            diagnosis = "server-connect-seen-but-entered-game-not-seen"
            explanation = "At least one path produced a non-BOT server connect, but no entered-the-game or authoritative public human-count signal was captured."
        }
    }

    if ([string]::IsNullOrWhiteSpace($steamExePath) -or [string]::IsNullOrWhiteSpace($clientExePath) -or
        (-not $manifestPresent -and $steamHlMaterialized -eq 0) -or
        (-not $steamRunning -and -not $steamWebHelperRunning -and $steamLaunchersStarted -eq 0)) {
        return [ordered]@{
            diagnosis = "steam-session-not-ready"
            explanation = "The Steam/Half-Life session prerequisites were not fully present before admission could be tested: steam.exe, hl.exe, the Half-Life app manifest, or a running Steam session is missing."
        }
    }

    if ($availableSteamSummaries.Count -gt 0 -and $steamLaunchersStarted -gt 0 -and $steamHlMaterialized -eq 0) {
        return [ordered]@{
            diagnosis = "steam-app-launch-path-broken"
            explanation = "Steam-backed launch commands were issued, but neither Steam-backed path materialized a new hl.exe client process."
        }
    }

    if ($anySteamFailure -or ($anySteamLogAdvanced -and $environmentConclusion -eq "steam-environment-blocked-before-admission")) {
        return [ordered]@{
            diagnosis = "public-admission-blocked-before-server-connect"
            explanation = "Steam-side admission logs advanced or reported CM/Steam initialization failure, and no path reached a non-BOT server connect."
        }
    }

    if ($anyHlMaterialized) {
        return [ordered]@{
            diagnosis = "hl-client-launches-but-public-admission-never-starts"
            explanation = "At least one path materialized hl.exe, but the public server never logged a non-BOT connect and never observed an authoritative human."
        }
    }

    if (-not $ServerContextFresh) {
        return [ordered]@{
            diagnosis = "admission-inconclusive-external-environment"
            explanation = $ServerContextExplanation
        }
    }

    return [ordered]@{
        diagnosis = "admission-inconclusive-external-environment"
        explanation = "The drill completed without a server-side human signal, but the captured evidence was not specific enough to separate Steam session state, app launch semantics, Half-Life launch behavior, and external public-network restrictions."
    }
}

function Get-DrillMarkdown {
    param([object]$Drill)

    $lines = @(
        "# Public Steam Admission Drill",
        "",
        "- Generated at UTC: $($Drill.generated_at_utc)",
        "- Prompt ID: $($Drill.prompt_id)",
        "- Diagnosis: $($Drill.machine_local_blocker_classification)",
        "- Explanation: $($Drill.classification_explanation)",
        "- Server address: $($Drill.server_address)",
        "- Server port: $($Drill.server_port)",
        "- Dry run: $($Drill.dry_run)",
        "- Public server status JSON: $($Drill.public_server_status_json_path)",
        "- Public server status age seconds: $($Drill.public_server_status_age_seconds)",
        "- Public server context fresh: $($Drill.public_server_context_fresh)",
        "- Environment audit JSON: $($Drill.artifacts.public_steam_environment_audit_after_json)",
        "- Path comparison JSON: $($Drill.artifacts.public_admission_path_comparison_json)"
    )

    $lines += @("", "## Admission Paths", "")
    foreach ($entry in @($Drill.path_results)) {
        $lines += "- $($entry.path_label): available=$($entry.path_available); steam_started=$($entry.steam_exe_started); hl_materialized=$($entry.hl_exe_materialized); client_pid=$($entry.client_pid); steam_logs_advanced=$($entry.steam_side_logs_advanced); server_connect_seen=$($entry.server_connect_seen); entered_the_game_seen=$($entry.entered_the_game_seen); authoritative_human_seen=$($entry.authoritative_human_seen); stage=$($entry.narrowest_failure_stage)"
        $lines += "  command=$($entry.exact_command_line)"
        $lines += "  working_directory=$($entry.working_directory)"
        $lines += "  explanation=$($entry.explanation)"
    }

    $lines += @("", "## Interpretation", "")
    $lines += "- `public-admission-working`: rerun `scripts\validate_public_human_trigger.ps1` because a server-side human signal exists."
    $lines += "- `server-connect-seen-but-entered-game-not-seen`: the blocker moved past raw connect and should be diagnosed at the entered-the-game boundary."
    $lines += "- `steam-session-not-ready`: fix the local Steam/Half-Life session before spending validator runs."
    $lines += "- `steam-app-launch-path-broken`: Steam accepted a launch command but did not materialize `hl.exe`."
    $lines += "- `hl-client-launches-but-public-admission-never-starts`: `hl.exe` launches locally, but public admission never reaches HLDS."
    $lines += "- `public-admission-blocked-before-server-connect`: client-side Steam/public admission evidence failed before the first non-BOT server connect."
    $lines += "- `admission-inconclusive-external-environment`: the run lacks enough fresh evidence to justify repo-side public-policy changes."

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

if ($AdmissionWaitSeconds -lt 5) {
    throw "AdmissionWaitSeconds must be at least 5 seconds."
}
if ($StatusPollSeconds -lt 1) {
    throw "StatusPollSeconds must be at least 1 second."
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Ensure-Directory -Path (Join-Path $labRoot ("logs\public_server\steam_admission_drills\{0}-public-steam-admission-drill-p{1}" -f $stamp, $ServerPort))
}
else {
    $candidate = Resolve-RepoPathMaybe -Path $OutputRoot
    Ensure-Directory -Path $candidate
}

$drillJsonPath = Join-Path $resolvedOutputRoot "public_steam_admission_drill.json"
$drillMarkdownPath = Join-Path $resolvedOutputRoot "public_steam_admission_drill.md"

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

$statusAgeSeconds = Get-JsonFileAgeSeconds -Path $resolvedPublicStatusJsonPath
$serverContextFresh = $statusAgeSeconds -ge 0 -and $statusAgeSeconds -le $MaxPublicStatusAgeSeconds
$serverContextExplanation = if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
    "No public_server_status.json was provided or discovered for this port, so the drill cannot distinguish client admission failure from a missing live server context."
}
elseif (-not $serverContextFresh) {
    "The discovered public_server_status.json is stale for this drill threshold, so the run cannot fully separate client admission failure from a non-current server context."
}
else {
    "A fresh public server status artifact was available for the admission drill."
}

$auditBeforeOutputRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "environment_audit_before")
$comparisonOutputRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "path_comparison")
$auditAfterOutputRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "environment_audit_after")

$auditScriptPath = Join-Path $PSScriptRoot "audit_public_steam_environment.ps1"
$comparisonScriptPath = Join-Path $PSScriptRoot "compare_public_client_admission_paths.ps1"

$baseChildParams = @{
    ServerAddress = $ServerAddress
    ServerPort = $ServerPort
}
if (-not [string]::IsNullOrWhiteSpace($SteamExePath)) { $baseChildParams["SteamExePath"] = $SteamExePath }
if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) { $baseChildParams["ClientExePath"] = $ClientExePath }
if (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) { $baseChildParams["PublicServerOutputRoot"] = $resolvedPublicServerOutputRoot }
if (-not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) { $baseChildParams["PublicServerStatusJsonPath"] = $resolvedPublicStatusJsonPath }

$auditBeforeParams = @{} + $baseChildParams
$auditBeforeParams["OutputRoot"] = $auditBeforeOutputRoot
$auditBeforeInvocation = Invoke-DrillChildScript -ScriptPath $auditScriptPath -Parameters $auditBeforeParams -TranscriptPath (Join-Path $resolvedOutputRoot "environment_audit_before.stdout.txt")

$comparisonParams = @{} + $baseChildParams
$comparisonParams["OutputRoot"] = $comparisonOutputRoot
$comparisonParams["AdmissionWaitSeconds"] = $AdmissionWaitSeconds
$comparisonParams["StatusPollSeconds"] = $StatusPollSeconds
$comparisonParams["PreferredPaths"] = @("steam-native-applaunch", "steam-connect-uri", "direct-hl-exe-connect")
if (-not [string]::IsNullOrWhiteSpace($resolvedServerLogPath)) { $comparisonParams["ServerLogPath"] = $resolvedServerLogPath }
if ($DryRun) { $comparisonParams["DryRun"] = $true }
$comparisonInvocation = Invoke-DrillChildScript -ScriptPath $comparisonScriptPath -Parameters $comparisonParams -TranscriptPath (Join-Path $resolvedOutputRoot "path_comparison.stdout.txt")

$auditAfterParams = @{} + $baseChildParams
$auditAfterParams["OutputRoot"] = $auditAfterOutputRoot
$auditAfterInvocation = Invoke-DrillChildScript -ScriptPath $auditScriptPath -Parameters $auditAfterParams -TranscriptPath (Join-Path $resolvedOutputRoot "environment_audit_after.stdout.txt")

$auditBeforeJsonPath = Join-Path $auditBeforeOutputRoot "public_steam_environment_audit.json"
$auditAfterJsonPath = Join-Path $auditAfterOutputRoot "public_steam_environment_audit.json"
$comparisonJsonPath = Join-Path $comparisonOutputRoot "public_admission_path_comparison.json"
$auditBefore = Read-JsonFile -Path $auditBeforeJsonPath
$auditAfter = Read-JsonFile -Path $auditAfterJsonPath
$comparison = Read-JsonFile -Path $comparisonJsonPath
$environmentForClassification = if ($null -ne $auditAfter) { $auditAfter } else { $auditBefore }

$pathSummaries = New-Object System.Collections.Generic.List[object]
if ($null -ne $comparison) {
    foreach ($pathResult in @((Get-ObjectPropertyValue -Object $comparison -Name "path_results" -Default @()))) {
        $pathSummaries.Add((Get-PathDrillSummary -PathResult $pathResult)) | Out-Null
    }
}

$classification = Get-DrillClassification -EnvironmentAudit $environmentForClassification -PathSummaries @($pathSummaries.ToArray()) -ServerContextFresh $serverContextFresh -ServerContextExplanation $serverContextExplanation

$drill = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    server_address = $ServerAddress
    server_port = $ServerPort
    dry_run = [bool]$DryRun
    admission_wait_seconds = $AdmissionWaitSeconds
    status_poll_seconds = $StatusPollSeconds
    max_public_status_age_seconds = $MaxPublicStatusAgeSeconds
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_server_status_age_seconds = $statusAgeSeconds
    public_server_context_fresh = $serverContextFresh
    public_server_context_explanation = $serverContextExplanation
    server_log_path = $resolvedServerLogPath
    machine_local_blocker_classification = [string]$classification.diagnosis
    classification_explanation = [string]$classification.explanation
    environment_audit_before_conclusion = [string](Get-ObjectPropertyValue -Object $auditBefore -Name "conclusion" -Default "")
    environment_audit_after_conclusion = [string](Get-ObjectPropertyValue -Object $auditAfter -Name "conclusion" -Default "")
    admission_path_comparison_verdict = [string](Get-ObjectPropertyValue -Object $comparison -Name "comparison_verdict" -Default "")
    admission_path_comparison_explanation = [string](Get-ObjectPropertyValue -Object $comparison -Name "explanation" -Default "")
    path_results = @($pathSummaries.ToArray())
    child_invocations = [ordered]@{
        environment_audit_before = $auditBeforeInvocation
        path_comparison = $comparisonInvocation
        environment_audit_after = $auditAfterInvocation
    }
    artifacts = [ordered]@{
        public_steam_admission_drill_json = $drillJsonPath
        public_steam_admission_drill_markdown = $drillMarkdownPath
        public_steam_environment_audit_before_json = $auditBeforeJsonPath
        public_steam_environment_audit_before_markdown = Join-Path $auditBeforeOutputRoot "public_steam_environment_audit.md"
        public_admission_path_comparison_json = $comparisonJsonPath
        public_admission_path_comparison_markdown = Join-Path $comparisonOutputRoot "public_admission_path_comparison.md"
        public_steam_environment_audit_after_json = $auditAfterJsonPath
        public_steam_environment_audit_after_markdown = Join-Path $auditAfterOutputRoot "public_steam_environment_audit.md"
    }
}

Write-JsonFile -Path $drillJsonPath -Value $drill
$drillForMarkdown = Read-JsonFile -Path $drillJsonPath
Write-TextFile -Path $drillMarkdownPath -Value (Get-DrillMarkdown -Drill $drillForMarkdown)

Write-Host "Public Steam admission drill:"
Write-Host "  Diagnosis: $($drill.machine_local_blocker_classification)"
Write-Host "  Explanation: $($drill.classification_explanation)"
Write-Host "  Drill JSON: $drillJsonPath"
Write-Host "  Drill Markdown: $drillMarkdownPath"
