param(
    [string]$AttemptRoot = "",
    [string]$AttemptJsonPath = "",
    [string]$PublicValidationJsonPath = "",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$promptId = Get-RepoPromptId
$repoRoot = Get-RepoRoot

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

function Get-DiagnosisMarkdown {
    param([object]$Diagnosis)

    $qconsoleTailText = [string](Get-ObjectPropertyValue -Object $Diagnosis -Name "qconsole_tail" -Default "")
    $steamTailText = [string](Get-ObjectPropertyValue -Object $Diagnosis -Name "steam_connection_log_tail" -Default "")
    $serverTailText = [string](Get-ObjectPropertyValue -Object $Diagnosis -Name "server_log_tail" -Default "")
    $lines = @(
        "# Public Client Admission Diagnosis",
        "",
        "- Generated at UTC: $($Diagnosis.generated_at_utc)",
        "- Prompt ID: $($Diagnosis.prompt_id)",
        "- Stage verdict: $($Diagnosis.stage_verdict)",
        "- Explanation: $($Diagnosis.explanation)",
        "- Attempt path kind: $($Diagnosis.attempt_path_kind)",
        "- Command: $($Diagnosis.command_text)",
        "- Working directory: $($Diagnosis.working_directory)",
        "- Steam executable: $($Diagnosis.steam_exe_path)",
        "- Client executable: $($Diagnosis.client_exe_path)",
        "- Launcher process started: $($Diagnosis.launcher_process_started)",
        "- Launcher PID: $($Diagnosis.launcher_process_id)",
        "- New hl.exe PIDs: $((@($Diagnosis.launched_hl_process_ids) -join ', '))",
        "- Server connect seen: $($Diagnosis.server_connect_seen)",
        "- Server entered the game seen: $($Diagnosis.server_entered_game_seen)",
        "- Attempt authoritative human seen: $($Diagnosis.attempt_authoritative_human_seen)",
        "- Public validator authoritative human seen: $($Diagnosis.public_validator_authoritative_human_seen)"
    )

    if ($Diagnosis.evidence_found) {
        $lines += @("", "## Evidence Found", "")
        foreach ($entry in @($Diagnosis.evidence_found)) {
            $lines += "- $entry"
        }
    }

    if ($Diagnosis.evidence_missing) {
        $lines += @("", "## Evidence Missing", "")
        foreach ($entry in @($Diagnosis.evidence_missing)) {
            $lines += "- $entry"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($qconsoleTailText)) {
        $lines += @("", "## qconsole Tail", "", '```text', $qconsoleTailText, '```')
    }

    if (-not [string]::IsNullOrWhiteSpace($steamTailText)) {
        $lines += @("", "## Steam Connection Log Tail", "", '```text', $steamTailText, '```')
    }

    if (-not [string]::IsNullOrWhiteSpace($serverTailText)) {
        $lines += @("", "## Server Log Tail", "", '```text', $serverTailText, '```')
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedAttemptJsonPath = ""
if (-not [string]::IsNullOrWhiteSpace($AttemptJsonPath)) {
    if ([System.IO.Path]::IsPathRooted($AttemptJsonPath)) {
        $resolvedAttemptJsonPath = $AttemptJsonPath
    }
    else {
        $resolvedAttemptJsonPath = Join-Path $repoRoot $AttemptJsonPath
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($AttemptRoot)) {
    $resolvedAttemptRootCandidate = if ([System.IO.Path]::IsPathRooted($AttemptRoot)) { $AttemptRoot } else { Join-Path $repoRoot $AttemptRoot }
    $resolvedAttemptJsonPath = Join-Path $resolvedAttemptRootCandidate "public_client_admission_attempt.json"
}

if ([string]::IsNullOrWhiteSpace($resolvedAttemptJsonPath) -or -not (Test-Path -LiteralPath $resolvedAttemptJsonPath -PathType Leaf)) {
    throw "A public_client_admission_attempt.json path is required."
}

$attempt = Read-JsonFile -Path $resolvedAttemptJsonPath
if ($null -eq $attempt) {
    throw "Failed to read attempt JSON from $resolvedAttemptJsonPath."
}

$resolvedAttemptRoot = Split-Path -Path $resolvedAttemptJsonPath -Parent
$resolvedOutputRoot = ""
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $resolvedOutputRoot = $resolvedAttemptRoot
}
else {
    if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
        $resolvedOutputRoot = $OutputRoot
    }
    else {
        $resolvedOutputRoot = Join-Path $repoRoot $OutputRoot
    }
}

$diagnosisJsonPath = Join-Path $resolvedOutputRoot "public_client_admission_diagnosis.json"
$diagnosisMarkdownPath = Join-Path $resolvedOutputRoot "public_client_admission_diagnosis.md"

$validation = $null
if (-not [string]::IsNullOrWhiteSpace($PublicValidationJsonPath)) {
    $resolvedValidationPath = if ([System.IO.Path]::IsPathRooted($PublicValidationJsonPath)) { $PublicValidationJsonPath } else { Join-Path $repoRoot $PublicValidationJsonPath }
    $validation = Read-JsonFile -Path $resolvedValidationPath
}

$matchingValidationAttempt = $null
if ($null -ne $validation) {
    foreach ($entry in @($validation.human_join_attempts)) {
        $entryArtifacts = Get-ObjectPropertyValue -Object $entry -Name "artifacts" -Default $null
        $entryAttemptJson = [string](Get-ObjectPropertyValue -Object $entryArtifacts -Name "public_client_admission_attempt_json" -Default "")
        if (-not [string]::IsNullOrWhiteSpace($entryAttemptJson) -and $entryAttemptJson -eq $resolvedAttemptJsonPath) {
            $matchingValidationAttempt = $entry
            break
        }
    }
}

$attemptPathKind = [string](Get-ObjectPropertyValue -Object $attempt -Name "attempt_path_kind" -Default "")
$steamBackedAttempt = $attemptPathKind -eq "steam-native-applaunch" -or $attemptPathKind -eq "steam-connect-uri"
$launcherProcessStarted = [bool](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_started" -Default $false)
$launcherProcessId = [int](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_id" -Default 0)
$launchedHlProcessIds = @((Get-ObjectPropertyValue -Object $attempt -Name "launched_hl_process_ids" -Default @()))
$serverConnectSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_connect_seen" -Default $false)
$serverEnteredSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_entered_game_seen" -Default $false)
$attemptAuthoritativeHumanSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "authoritative_human_seen" -Default $false)
$publicValidatorAuthoritativeHumanSeen = $null
if ($null -ne $matchingValidationAttempt) {
    $publicValidatorAuthoritativeHumanSeen = [bool](Get-ObjectPropertyValue -Object $matchingValidationAttempt -Name "authoritative_human_seen" -Default $false)
}

$steamConnectionLogTail = if ([string]::IsNullOrWhiteSpace([string]($attempt.steam_connection_log_tail))) {
    Get-FileTailText -Path ([string]($attempt.steam_connection_log_path)) -LineCount 120
}
else {
    [string]($attempt.steam_connection_log_tail)
}
$qconsoleTail = if ([string]::IsNullOrWhiteSpace([string]($attempt.qconsole_tail))) {
    Get-FileTailText -Path ([string]($attempt.qconsole_path)) -LineCount 120
}
else {
    [string]($attempt.qconsole_tail)
}
$serverLogTail = if ([string]::IsNullOrWhiteSpace([string]($attempt.server_log_tail))) {
    Get-FileTailText -Path ([string]($attempt.server_log_path)) -LineCount 160
}
else {
    [string]($attempt.server_log_tail)
}

$steamCmFailureSeen = $steamConnectionLogTail -match "GetCMListForConnect -- web API call failed|failed talking to cm|ConnectFailed\(|StartAutoReconnect"
$qconsoleSteamInitFailureSeen = $qconsoleTail -match "Unable to initialize Steam"

$evidenceFound = New-Object System.Collections.Generic.List[string]
$evidenceMissing = New-Object System.Collections.Generic.List[string]

if ($launcherProcessStarted) { $evidenceFound.Add("client launcher process started") | Out-Null } else { $evidenceMissing.Add("client launcher process start") | Out-Null }
if (@($launchedHlProcessIds).Count -gt 0) { $evidenceFound.Add("new hl.exe client process observed") | Out-Null } else { $evidenceMissing.Add("new hl.exe client process") | Out-Null }
if ($serverConnectSeen) { $evidenceFound.Add("server logged non-BOT connect") | Out-Null } else { $evidenceMissing.Add("server-side non-BOT connect log") | Out-Null }
if ($serverEnteredSeen) { $evidenceFound.Add("server logged non-BOT entered-the-game") | Out-Null } else { $evidenceMissing.Add("server-side non-BOT entered-the-game log") | Out-Null }
if ($attemptAuthoritativeHumanSeen) { $evidenceFound.Add("attempt observed authoritative public human count above zero") | Out-Null } else { $evidenceMissing.Add("attempt-side authoritative public human count above zero") | Out-Null }
if ($publicValidatorAuthoritativeHumanSeen -eq $true) { $evidenceFound.Add("public validator observed authoritative human count above zero") | Out-Null }
elseif ($publicValidatorAuthoritativeHumanSeen -eq $false) { $evidenceMissing.Add("public validator authoritative human count above zero") | Out-Null }
if ($steamCmFailureSeen) { $evidenceFound.Add("Steam connection log showed CM reconnect failure before server admission") | Out-Null }
if ($qconsoleSteamInitFailureSeen) { $evidenceFound.Add("qconsole showed Steam initialization failure") | Out-Null }

$stageVerdict = ""
$explanation = ""
if (-not $steamBackedAttempt) {
    $stageVerdict = "steam-launch-not-attempted"
    $explanation = "This admission attempt did not use a Steam-backed public path. Use a Steam-backed path first for authoritative sv_lan 0 admission checks, then use direct hl.exe only as comparison."
}
elseif ($serverEnteredSeen -or $attemptAuthoritativeHumanSeen) {
    $stageVerdict = "entered-game-seen-human-admitted"
    $explanation = "The public admission attempt crossed the authoritative boundary: the server saw a real human enter the game or the public status count rose above zero."
}
elseif ($serverConnectSeen) {
    $stageVerdict = "server-connect-seen-no-entered-game"
    $explanation = "The server saw a real human connect, but no non-BOT entered-the-game event was captured before the attempt ended."
}
elseif (-not $launcherProcessStarted -and @($launchedHlProcessIds).Count -eq 0) {
    $stageVerdict = "steam-launch-attempted-no-client-process"
    $explanation = "The Steam-backed launch command was issued, but no new hl.exe client process appeared afterward."
}
elseif ($steamCmFailureSeen -or $qconsoleSteamInitFailureSeen) {
    $stageVerdict = "steam-admission-failed-before-server-connect"
    $explanation = "The client-side public admission path failed before the server counted a real human. Steam-side admission evidence failed locally before any non-BOT server connect was observed."
}
elseif ($launcherProcessStarted -or @($launchedHlProcessIds).Count -gt 0) {
    $stageVerdict = "client-process-started-no-steam-admission"
    $explanation = "A local client process started, but the public server never logged a non-BOT connect and the authoritative human count never increased."
}
else {
    $stageVerdict = "inconclusive-manual-review"
    $explanation = "The attempt did not provide enough grounded evidence to isolate the client-side admission stage further."
}

$diagnosis = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_root = $resolvedAttemptRoot
    attempt_json_path = $resolvedAttemptJsonPath
    public_validation_json_path = if ($null -ne $validation) { $resolvedValidationPath } else { "" }
    stage_verdict = $stageVerdict
    explanation = $explanation
    attempt_path_kind = $attemptPathKind
    command_text = [string](Get-ObjectPropertyValue -Object $attempt -Name "command_text" -Default "")
    working_directory = [string](Get-ObjectPropertyValue -Object $attempt -Name "working_directory" -Default "")
    steam_exe_path = [string](Get-ObjectPropertyValue -Object $attempt -Name "steam_exe_path" -Default "")
    client_exe_path = [string](Get-ObjectPropertyValue -Object $attempt -Name "client_exe_path" -Default "")
    launcher_process_started = $launcherProcessStarted
    launcher_process_id = $launcherProcessId
    launched_hl_process_ids = @($launchedHlProcessIds)
    attempt_authoritative_human_seen = $attemptAuthoritativeHumanSeen
    public_validator_authoritative_human_seen = $publicValidatorAuthoritativeHumanSeen
    server_connect_seen = $serverConnectSeen
    server_entered_game_seen = $serverEnteredSeen
    steam_connection_log_contains_cm_failure = $steamCmFailureSeen
    qconsole_contains_steam_init_failure = $qconsoleSteamInitFailureSeen
    steam_connection_log_path = [string](Get-ObjectPropertyValue -Object $attempt -Name "steam_connection_log_path" -Default "")
    qconsole_path = [string](Get-ObjectPropertyValue -Object $attempt -Name "qconsole_path" -Default "")
    server_log_path = [string](Get-ObjectPropertyValue -Object $attempt -Name "server_log_path" -Default "")
    steam_connection_log_tail = $steamConnectionLogTail
    qconsole_tail = $qconsoleTail
    server_log_tail = $serverLogTail
    evidence_found = @($evidenceFound.ToArray())
    evidence_missing = @($evidenceMissing.ToArray())
    artifacts = [ordered]@{
        public_client_admission_diagnosis_json = $diagnosisJsonPath
        public_client_admission_diagnosis_markdown = $diagnosisMarkdownPath
    }
}

Write-JsonFile -Path $diagnosisJsonPath -Value $diagnosis
$diagnosisForMarkdown = Read-JsonFile -Path $diagnosisJsonPath
Write-TextFile -Path $diagnosisMarkdownPath -Value (Get-DiagnosisMarkdown -Diagnosis $diagnosisForMarkdown)

Write-Host "Public client admission diagnosis:"
Write-Host "  Stage verdict: $stageVerdict"
Write-Host "  Explanation: $explanation"
Write-Host "  Diagnosis JSON: $diagnosisJsonPath"
Write-Host "  Diagnosis Markdown: $diagnosisMarkdownPath"
