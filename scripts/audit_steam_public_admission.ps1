[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$AttemptRoot = "",
    [string]$AttemptJsonPath = "",
    [string]$ComparisonJsonPath = "",
    [string]$PublicValidationJsonPath = "",
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

function Get-LatestSteamAttemptJsonPath {
    $searchRoots = @(
        (Join-Path $labRoot "logs\public_server\human_trigger_validations"),
        (Join-Path $labRoot "logs\public_server\client_admissions"),
        (Join-Path $labRoot "logs\public_server\admission_path_comparisons")
    )

    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $candidateFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "public_client_admission_attempt.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        foreach ($file in $candidateFiles) {
            $attempt = Read-JsonFile -Path $file.FullName
            $pathKind = [string](Get-ObjectPropertyValue -Object $attempt -Name "attempt_path_kind" -Default "")
            if ($pathKind -eq "steam-native-applaunch" -or $pathKind -eq "steam-connect-uri") {
                return $file.FullName
            }
        }
    }

    return ""
}

function Resolve-JsonPathMaybe {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function Get-AuditMarkdown {
    param([object]$Audit)

    $steamTailText = [string](Get-ObjectPropertyValue -Object $Audit -Name "steam_connection_log_tail" -Default "")
    $qconsoleTailText = [string](Get-ObjectPropertyValue -Object $Audit -Name "qconsole_tail" -Default "")
    $serverTailText = [string](Get-ObjectPropertyValue -Object $Audit -Name "server_log_tail" -Default "")
    $lines = @(
        "# Steam Public Admission Audit",
        "",
        "- Generated at UTC: $($Audit.generated_at_utc)",
        "- Prompt ID: $($Audit.prompt_id)",
        "- Stage verdict: $($Audit.stage_verdict)",
        "- Explanation: $($Audit.explanation)",
        "- Attempt path kind: $($Audit.attempt_path_kind)",
        "- Narrowest blocker stage: $($Audit.narrowest_blocker_stage)",
        "- Steam path found: $($Audit.steam_path_found)",
        "- Steam executable: $($Audit.steam_exe_path)",
        "- Working directory: $($Audit.working_directory)",
        "- Command: $($Audit.command_text)",
        "- Client process started: $($Audit.client_process_started)",
        "- Server connect seen: $($Audit.server_connect_seen)",
        "- Entered the game seen: $($Audit.entered_the_game_seen)",
        "- Authoritative human seen: $($Audit.authoritative_human_seen)",
        "- Validator verdict: $($Audit.public_validator_verdict)"
    )

    if ($Audit.evidence_found) {
        $lines += @("", "## Evidence Found", "")
        foreach ($entry in @($Audit.evidence_found)) {
            $lines += "- $entry"
        }
    }

    if ($Audit.evidence_missing) {
        $lines += @("", "## Evidence Missing", "")
        foreach ($entry in @($Audit.evidence_missing)) {
            $lines += "- $entry"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($steamTailText)) {
        $lines += @("", "## Steam Connection Log Tail", "", '```text', $steamTailText, '```')
    }

    if (-not [string]::IsNullOrWhiteSpace($qconsoleTailText)) {
        $lines += @("", "## qconsole Tail", "", '```text', $qconsoleTailText, '```')
    }

    if (-not [string]::IsNullOrWhiteSpace($serverTailText)) {
        $lines += @("", "## Server Log Tail", "", '```text', $serverTailText, '```')
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedAttemptJsonPath = ""
if (-not [string]::IsNullOrWhiteSpace($AttemptJsonPath)) {
    $resolvedAttemptJsonPath = Resolve-JsonPathMaybe -Path $AttemptJsonPath
}
elseif (-not [string]::IsNullOrWhiteSpace($AttemptRoot)) {
    $resolvedAttemptJsonPath = Join-Path (Resolve-JsonPathMaybe -Path $AttemptRoot) "public_client_admission_attempt.json"
}
elseif (-not [string]::IsNullOrWhiteSpace($ComparisonJsonPath)) {
    $comparison = Read-JsonFile -Path (Resolve-JsonPathMaybe -Path $ComparisonJsonPath)
    if ($null -ne $comparison) {
        foreach ($entry in @($comparison.path_results)) {
            $pathId = [string](Get-ObjectPropertyValue -Object $entry -Name "path_id" -Default "")
            if ($pathId -eq "steam-native-applaunch" -or $pathId -eq "steam-connect-uri") {
                $candidateAttempt = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $entry -Name "artifacts" -Default $null) -Name "public_client_admission_attempt_json" -Default "")
                if (-not [string]::IsNullOrWhiteSpace($candidateAttempt)) {
                    $resolvedAttemptJsonPath = $candidateAttempt
                    break
                }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($resolvedAttemptJsonPath)) {
    $resolvedAttemptJsonPath = Get-LatestSteamAttemptJsonPath
}

if ([string]::IsNullOrWhiteSpace($resolvedAttemptJsonPath) -or -not (Test-Path -LiteralPath $resolvedAttemptJsonPath -PathType Leaf)) {
    throw "A Steam-backed public_client_admission_attempt.json path is required."
}

$attempt = Read-JsonFile -Path $resolvedAttemptJsonPath
if ($null -eq $attempt) {
    throw "Failed to read attempt JSON from $resolvedAttemptJsonPath."
}

$resolvedAttemptRoot = Split-Path -Path $resolvedAttemptJsonPath -Parent
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $resolvedAttemptRoot
}
else {
    Resolve-JsonPathMaybe -Path $OutputRoot
}

$auditJsonPath = Join-Path $resolvedOutputRoot "steam_public_admission_audit.json"
$auditMarkdownPath = Join-Path $resolvedOutputRoot "steam_public_admission_audit.md"

$resolvedValidationJsonPath = Resolve-JsonPathMaybe -Path $PublicValidationJsonPath
if ([string]::IsNullOrWhiteSpace($resolvedValidationJsonPath)) {
    $candidateValidationPath = Join-Path (Split-Path -Path $resolvedAttemptRoot -Parent) "public_human_trigger_validation.json"
    if (Test-Path -LiteralPath $candidateValidationPath -PathType Leaf) {
        $resolvedValidationJsonPath = $candidateValidationPath
    }
}
$validation = Read-JsonFile -Path $resolvedValidationJsonPath

$diagnoseScriptPath = Join-Path $PSScriptRoot "diagnose_public_client_admission.ps1"
& $diagnoseScriptPath -AttemptJsonPath $resolvedAttemptJsonPath -PublicValidationJsonPath $resolvedValidationJsonPath -OutputRoot $resolvedAttemptRoot | Out-Null
$diagnosisJsonPath = Join-Path $resolvedAttemptRoot "public_client_admission_diagnosis.json"
$diagnosis = Read-JsonFile -Path $diagnosisJsonPath

$attemptPathKind = [string](Get-ObjectPropertyValue -Object $attempt -Name "attempt_path_kind" -Default "")
$steamPath = [string](Get-ObjectPropertyValue -Object $attempt -Name "steam_exe_path" -Default "")
$steamPathFound = -not [string]::IsNullOrWhiteSpace($steamPath) -and (Test-Path -LiteralPath $steamPath -PathType Leaf)
$workingDirectory = [string](Get-ObjectPropertyValue -Object $attempt -Name "working_directory" -Default "")
$workingDirectoryExists = -not [string]::IsNullOrWhiteSpace($workingDirectory) -and (Test-Path -LiteralPath $workingDirectory -PathType Container)
$commandText = [string](Get-ObjectPropertyValue -Object $attempt -Name "command_text" -Default "")
$launcherProcessStarted = [bool](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_started" -Default $false)
$launchedHlProcessIds = @((Get-ObjectPropertyValue -Object $attempt -Name "launched_hl_process_ids" -Default @()))
$clientProcessStarted = $launcherProcessStarted -or @($launchedHlProcessIds).Count -gt 0
$serverConnectSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_connect_seen" -Default $false)
$enteredGameSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_entered_game_seen" -Default $false)
$authoritativeHumanSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "authoritative_human_seen" -Default $false)
$steamLogPath = [string](Get-ObjectPropertyValue -Object $attempt -Name "steam_connection_log_path" -Default "")
$qconsolePath = [string](Get-ObjectPropertyValue -Object $attempt -Name "qconsole_path" -Default "")
$serverLogPath = [string](Get-ObjectPropertyValue -Object $attempt -Name "server_log_path" -Default "")
$steamTail = Get-FileTailText -Path $steamLogPath -LineCount 120
$qconsoleTail = Get-FileTailText -Path $qconsolePath -LineCount 120
$serverTail = Get-FileTailText -Path $serverLogPath -LineCount 160
$steamWebApiFailureSeen = $steamTail -match "GetCMListForConnect -- web API call failed"
$steamCmFailureSeen = $steamTail -match "failed talking to cm|ConnectFailed\(|StartAutoReconnect"
$qconsoleSteamInitFailureSeen = $qconsoleTail -match "Unable to initialize Steam"

$publicValidatorVerdict = [string](Get-ObjectPropertyValue -Object $validation -Name "validation_verdict" -Default "")
$comparisonVerdict = ""
if (-not [string]::IsNullOrWhiteSpace($ComparisonJsonPath)) {
    $comparisonJson = Read-JsonFile -Path (Resolve-JsonPathMaybe -Path $ComparisonJsonPath)
    if ($null -ne $comparisonJson) {
        $comparisonVerdict = [string](Get-ObjectPropertyValue -Object $comparisonJson -Name "comparison_verdict" -Default "")
    }
}

$evidenceFound = New-Object System.Collections.Generic.List[string]
$evidenceMissing = New-Object System.Collections.Generic.List[string]
if ($steamPathFound) { $evidenceFound.Add("steam.exe path resolved") | Out-Null } else { $evidenceMissing.Add("steam.exe path") | Out-Null }
if ($workingDirectoryExists) { $evidenceFound.Add("working directory exists") | Out-Null } else { $evidenceMissing.Add("working directory") | Out-Null }
if ($launcherProcessStarted) { $evidenceFound.Add("Steam-backed launcher process started") | Out-Null } else { $evidenceMissing.Add("Steam-backed launcher process") | Out-Null }
if ($clientProcessStarted) { $evidenceFound.Add("client process became visible") | Out-Null } else { $evidenceMissing.Add("client process visibility") | Out-Null }
if ($steamWebApiFailureSeen) { $evidenceFound.Add("Steam log showed GetCMListForConnect web API failure") | Out-Null }
if ($steamCmFailureSeen) { $evidenceFound.Add("Steam log showed CM reconnect/connect failure before server admission") | Out-Null }
if ($qconsoleSteamInitFailureSeen) { $evidenceFound.Add("qconsole showed Steam initialization failure") | Out-Null }
if ($serverConnectSeen) { $evidenceFound.Add("server-side non-BOT connect was seen") | Out-Null } else { $evidenceMissing.Add("server-side non-BOT connect") | Out-Null }
if ($enteredGameSeen) { $evidenceFound.Add("server-side non-BOT entered-the-game was seen") | Out-Null } else { $evidenceMissing.Add("server-side non-BOT entered-the-game") | Out-Null }
if ($authoritativeHumanSeen) { $evidenceFound.Add("authoritative public human count exceeded zero") | Out-Null } else { $evidenceMissing.Add("authoritative public human count above zero") | Out-Null }

$stageVerdict = ""
$narrowestBlockerStage = ""
$explanation = ""
if (-not $steamPathFound) {
    $stageVerdict = "steam-path-not-found"
    $narrowestBlockerStage = "steam-executable-resolution"
    $explanation = "The Steam-backed public admission path cannot run because steam.exe was not resolved."
}
elseif ($attemptPathKind -ne "steam-native-applaunch" -and $attemptPathKind -ne "steam-connect-uri") {
    $stageVerdict = "steam-launch-not-attempted"
    $narrowestBlockerStage = "path-selection"
    $explanation = "The inspected admission attempt was not Steam-backed."
}
elseif ($authoritativeHumanSeen -or $enteredGameSeen) {
    $stageVerdict = "entered-game-seen-human-admitted"
    $narrowestBlockerStage = "none"
    $explanation = "The Steam-backed public admission path crossed the authoritative human-admission boundary."
}
elseif ($serverConnectSeen) {
    $stageVerdict = "server-connect-seen-no-entered-game"
    $narrowestBlockerStage = "post-connect-entered-game"
    $explanation = "The Steam-backed path reached server connect, but it still did not clear entered-the-game."
}
elseif (-not $clientProcessStarted) {
    $stageVerdict = "steam-launch-attempted-no-client-process"
    $narrowestBlockerStage = "client-process-materialization"
    $explanation = "The Steam-backed launch command ran, but no client process became visible afterward."
}
elseif ($steamWebApiFailureSeen -or $steamCmFailureSeen -or $qconsoleSteamInitFailureSeen) {
    $stageVerdict = "steam-admission-failed-before-server-connect"
    $narrowestBlockerStage = "steam-cm-admission-before-server-connect"
    $explanation = "The Steam-backed path started locally but failed in the Steam admission chain before the server counted a real human."
}
elseif ($clientProcessStarted) {
    $stageVerdict = "client-process-started-no-steam-admission"
    $narrowestBlockerStage = "steam-admission-before-server-connect"
    $explanation = "A client process started, but the Steam-backed path still never produced server-side connect."
}
else {
    $stageVerdict = "inconclusive-manual-review"
    $narrowestBlockerStage = "unknown"
    $explanation = "The saved artifacts do not isolate the Steam-backed admission stage further."
}

if ($null -ne $diagnosis) {
    $diagnosisStage = [string](Get-ObjectPropertyValue -Object $diagnosis -Name "stage_verdict" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($diagnosisStage)) {
        $stageVerdict = $diagnosisStage
    }
}

$audit = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_root = $resolvedAttemptRoot
    attempt_json_path = $resolvedAttemptJsonPath
    public_validation_json_path = $resolvedValidationJsonPath
    comparison_json_path = Resolve-JsonPathMaybe -Path $ComparisonJsonPath
    stage_verdict = $stageVerdict
    narrowest_blocker_stage = $narrowestBlockerStage
    explanation = $explanation
    attempt_path_kind = $attemptPathKind
    steam_path_found = $steamPathFound
    steam_exe_path = $steamPath
    working_directory = $workingDirectory
    working_directory_exists = $workingDirectoryExists
    command_text = $commandText
    launcher_process_started = $launcherProcessStarted
    launched_hl_process_ids = @($launchedHlProcessIds)
    client_process_started = $clientProcessStarted
    server_connect_seen = $serverConnectSeen
    entered_the_game_seen = $enteredGameSeen
    authoritative_human_seen = $authoritativeHumanSeen
    steam_connection_log_path = $steamLogPath
    steam_connection_log_contains_webapi_failure = $steamWebApiFailureSeen
    steam_connection_log_contains_cm_failure = $steamCmFailureSeen
    qconsole_path = $qconsolePath
    qconsole_contains_steam_init_failure = $qconsoleSteamInitFailureSeen
    server_log_path = $serverLogPath
    public_validator_verdict = $publicValidatorVerdict
    comparison_verdict = $comparisonVerdict
    steam_connection_log_tail = $steamTail
    qconsole_tail = $qconsoleTail
    server_log_tail = $serverTail
    evidence_found = @($evidenceFound.ToArray())
    evidence_missing = @($evidenceMissing.ToArray())
    artifacts = [ordered]@{
        steam_public_admission_audit_json = $auditJsonPath
        steam_public_admission_audit_markdown = $auditMarkdownPath
        public_client_admission_diagnosis_json = $diagnosisJsonPath
    }
}

Write-JsonFile -Path $auditJsonPath -Value $audit
$auditForMarkdown = Read-JsonFile -Path $auditJsonPath
Write-TextFile -Path $auditMarkdownPath -Value (Get-AuditMarkdown -Audit $auditForMarkdown)

Write-Host "Steam public admission audit:"
Write-Host "  Stage verdict: $stageVerdict"
Write-Host "  Narrowest blocker stage: $narrowestBlockerStage"
Write-Host "  Explanation: $explanation"
Write-Host "  Audit JSON: $auditJsonPath"
Write-Host "  Audit Markdown: $auditMarkdownPath"
