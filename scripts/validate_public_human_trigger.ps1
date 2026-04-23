[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Map = "crossfire",
    [int]$BotCountWhenEmpty = 4,
    [int]$BotSkillWhenEmpty = 3,
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$PublicServerOutputRoot = "",
    [string]$ClientExePath = "",
    [int]$HumanJoinGraceSeconds = 15,
    [int]$EmptyServerRepopulateDelaySeconds = 10,
    [int]$StatusPollSeconds = 2,
    [int]$StartupWaitSeconds = 5,
    [int]$InitialEmptyValidationSeconds = 45,
    [int]$HumanJoinAttemptWaitSeconds = 45,
    [int]$HumansPresentObserveSeconds = 15,
    [int]$RepopulateObserveSeconds = 40,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [switch]$EnableAdvancedAIBalance
)

. (Join-Path $PSScriptRoot "common.ps1")

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

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
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
        [int]$LineCount = 80
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    try {
        return ((Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop) -join [Environment]::NewLine).Trim()
    }
    catch {
        return ""
    }
}

function Get-HlProcessIds {
    $processes = @(Get-Process -Name "hl" -ErrorAction SilentlyContinue)
    return @($processes | Select-Object -ExpandProperty Id)
}

function Add-NewHlProcessIds {
    param([int[]]$BeforeIds = @())

    $beforeLookup = New-Object System.Collections.Generic.HashSet[int]
    foreach ($id in @($BeforeIds)) {
        [void]$beforeLookup.Add([int]$id)
    }

    foreach ($process in @(Get-Process -Name "hl" -ErrorAction SilentlyContinue)) {
        if ($beforeLookup.Contains([int]$process.Id)) {
            continue
        }

        [void]$script:launchedClientProcessIds.Add([int]$process.Id)
    }
}

function Stop-TrackedHlProcesses {
    foreach ($processId in @($script:launchedClientProcessIds)) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
        }
        catch {
        }
    }
}

function Test-ServerHumanEvent {
    param(
        [string]$LogPath,
        [string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    $lines = @(Get-Content -LiteralPath $LogPath -Tail 160 -ErrorAction SilentlyContinue)
    if ($Kind -eq "connect") {
        return $lines | Where-Object { $_ -match "connected, address" -and $_ -notmatch "\bBOT\b" } | Select-Object -First 1
    }

    if ($Kind -eq "entered") {
        return $lines | Where-Object { $_ -match "entered the game" -and $_ -notmatch "\bBOT\b" } | Select-Object -First 1
    }

    return $false
}

function Get-SteamConnectLaunchCommandText {
    param(
        [string]$SteamExePath,
        [string]$SteamConnectUri
    )

    if ([string]::IsNullOrWhiteSpace($SteamExePath) -or [string]::IsNullOrWhiteSpace($SteamConnectUri)) {
        return ""
    }

    return "{0} {1}" -f (Format-ProcessArgumentText -Value $SteamExePath), (Format-ProcessArgumentText -Value $SteamConnectUri)
}

function New-StateRecord {
    param([string]$StateId)

    return [ordered]@{
        state_id = $StateId
        observed = $false
        first_observed_at_utc = ""
        authoritative_human_count = -1
        authoritative_bot_count = -1
        explanation = "Not observed during this validation run."
    }
}

function Record-StateObservation {
    param(
        [string]$StateId,
        [object]$Status,
        [string]$Explanation
    )

    $record = $script:stateObservations[$StateId]
    if ($null -eq $record -or [bool]$record.observed) {
        return
    }

    $record["observed"] = $true
    $record["first_observed_at_utc"] = [string](Get-ObjectPropertyValue -Object $Status -Name "generated_at_utc" -Default "")
    $record["authoritative_human_count"] = [int](Get-ObjectPropertyValue -Object $Status -Name "human_player_count" -Default -1)
    $record["authoritative_bot_count"] = [int](Get-ObjectPropertyValue -Object $Status -Name "bot_player_count" -Default -1)
    $record["explanation"] = $Explanation
}

function Update-StateObservationsFromStatus {
    param([object]$Status)

    if ($null -eq $Status) {
        return
    }

    $policyState = [string](Get-ObjectPropertyValue -Object $Status -Name "policy_state" -Default "")
    $humanCount = [int](Get-ObjectPropertyValue -Object $Status -Name "human_player_count" -Default 0)
    $botCount = [int](Get-ObjectPropertyValue -Object $Status -Name "bot_player_count" -Default 0)
    $generatedAtUtc = [string](Get-ObjectPropertyValue -Object $Status -Name "generated_at_utc" -Default "")

    if ($policyState -and $policyState -ne $script:lastObservedPolicyState) {
        $script:policyTransitions.Add([pscustomobject]@{
            observed_at_utc = $generatedAtUtc
            policy_state = $policyState
            human_player_count = $humanCount
            bot_player_count = $botCount
            explanation = [string](Get-ObjectPropertyValue -Object $Status -Name "explanation" -Default "")
        }) | Out-Null
        $script:lastObservedPolicyState = $policyState
    }

    switch ($policyState) {
        "waiting-human-join-grace" {
            Record-StateObservation -StateId $policyState -Status $Status -Explanation "Observed the public runner intentionally holding bots out during the initial join grace window."
        }
        "bots-active-empty-server" {
            Record-StateObservation -StateId $policyState -Status $Status -Explanation "Observed the empty-server bot pool active on crossfire."
        }
        "bots-disconnected-humans-present" {
            $script:humanPhaseObserved = $true
            Record-StateObservation -StateId $policyState -Status $Status -Explanation "Observed authoritative human presence with bots intentionally removed."
        }
        "waiting-empty-server-repopulate" {
            if ($script:humanPhaseObserved) {
                $script:repopulateWaitObservedAfterHuman = $true
                Record-StateObservation -StateId $policyState -Status $Status -Explanation "Observed the bounded empty-server repopulate delay after human presence ended."
            }
            else {
                Record-StateObservation -StateId $policyState -Status $Status -Explanation "Observed the empty-server repopulate delay before the bot pool fully returned."
            }
        }
    }

    if ($script:humanPhaseObserved -and $humanCount -eq 0 -and $botCount -ge $script:botCountWhenEmpty -and $policyState -eq "bots-active-empty-server") {
        Record-StateObservation -StateId "bots-repopulated-empty-server" -Status $Status -Explanation "Observed bots return after humans left and the bounded repopulate delay expired."
    }
}

function Get-PublicStatusSnapshot {
    param([string]$StatusJsonPath)

    $status = Read-JsonFile -Path $StatusJsonPath
    if ($null -ne $status) {
        Update-StateObservationsFromStatus -Status $status
        $script:lastStatusSnapshot = $status
    }

    return $status
}

function Wait-ForPublicCondition {
    param(
        [string]$Description,
        [string]$StatusJsonPath,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [scriptblock]$Condition
    )

    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $latestStatus = $null
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $latestStatus = Get-PublicStatusSnapshot -StatusJsonPath $StatusJsonPath
        if ($null -ne $latestStatus) {
            $matched = $false
            try {
                $matched = [bool](& $Condition $latestStatus)
            }
            catch {
                $matched = $false
            }

            if ($matched) {
                return [pscustomobject]@{
                    matched = $true
                    latest_status = $latestStatus
                    description = $Description
                }
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return [pscustomobject]@{
        matched = $false
        latest_status = $latestStatus
        description = $Description
    }
}

function Invoke-HumanJoinAttempt {
    param(
        [string]$Method,
        [string]$StatusJsonPath,
        [string]$ServerLogPath,
        [string]$ClientQConsolePath,
        [string]$SteamConnectionLogPath,
        [int]$TimeoutSeconds,
        [scriptblock]$LaunchAction,
        [string]$CommandText,
        [string]$WorkingDirectory,
        [string]$ExplanationIfUnavailable = ""
    )

    $attemptStartedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    $beforeHlIds = @(Get-HlProcessIds)
    $launched = $false
    $launcherProcessId = 0
    $launcherProcess = $null
    $launchExplanation = ""

    if ($null -eq $LaunchAction) {
        $launchExplanation = $ExplanationIfUnavailable
    }
    else {
        try {
            $launcherProcess = & $LaunchAction
            $launched = $true
            if ($null -ne $launcherProcess) {
                $launcherProcessId = [int](Get-ObjectPropertyValue -Object $launcherProcess -Name "Id" -Default 0)
            }
            $launchExplanation = "Launch attempt started."
        }
        catch {
            $launchExplanation = $_.Exception.Message
        }
    }

    if ($launched) {
        Start-Sleep -Seconds 2
    }

    Add-NewHlProcessIds -BeforeIds $beforeHlIds
    $waitResult = Wait-ForPublicCondition `
        -Description ("human join via {0}" -f $Method) `
        -StatusJsonPath $StatusJsonPath `
        -TimeoutSeconds $TimeoutSeconds `
        -PollSeconds $script:statusPollSeconds `
        -Condition { param($status) [int]$status.human_player_count -gt 0 }

    Add-NewHlProcessIds -BeforeIds $beforeHlIds

    $latestStatus = $waitResult.latest_status
    $authoritativeHumanSeen = $false
    $authoritativeBotCount = -1
    if ($null -ne $latestStatus) {
        $authoritativeHumanSeen = [int]$latestStatus.human_player_count -gt 0
        $authoritativeBotCount = [int]$latestStatus.bot_player_count
    }

    $serverConnectSeen = [bool](Test-ServerHumanEvent -LogPath $ServerLogPath -Kind "connect")
    $serverEnteredSeen = [bool](Test-ServerHumanEvent -LogPath $ServerLogPath -Kind "entered")
    $qconsoleTail = Get-FileTailText -Path $ClientQConsolePath -LineCount 80
    $steamLogTail = Get-FileTailText -Path $SteamConnectionLogPath -LineCount 80
    $qconsoleSteamInitFailure = $qconsoleTail -match "Unable to initialize Steam"
    $steamConnectionCmFailure = $steamLogTail -match "GetCMListForConnect -- web API call failed|failed talking to cm|ConnectFailed\("

    $attemptExplanation = if ($authoritativeHumanSeen) {
        "The public-mode authoritative human count increased above zero during this attempt."
    }
    elseif ($launched) {
        "The client launch started, but the authoritative public-mode human count never rose above zero."
    }
    else {
        $launchExplanation
    }

    return [pscustomobject]@{
        method = $Method
        attempt_started_at_utc = $attemptStartedAtUtc
        launched = $launched
        launcher_process_id = $launcherProcessId
        working_directory = $WorkingDirectory
        command_text = $CommandText
        authoritative_human_seen = $authoritativeHumanSeen
        authoritative_bot_count_when_finished = $authoritativeBotCount
        server_connect_seen = $serverConnectSeen
        server_entered_game_seen = $serverEnteredSeen
        qconsole_path = $ClientQConsolePath
        qconsole_tail = $qconsoleTail
        qconsole_contains_steam_init_failure = $qconsoleSteamInitFailure
        steam_connection_log_path = $SteamConnectionLogPath
        steam_connection_log_tail = $steamLogTail
        steam_connection_log_contains_cm_failure = $steamConnectionCmFailure
        explanation = $attemptExplanation
    }
}

function Get-ValidationMarkdown {
    param([object]$Report)

    $lines = @(
        "# Public Human-Trigger Validation",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Verdict: $($Report.validation_verdict)",
        "- Explanation: $($Report.explanation)",
        "- Public server output root: $($Report.public_server_output_root)",
        "- Authoritative human count source: $($Report.authoritative_human_count_source)",
        "- Advanced AI balance enabled: $($Report.advanced_ai_balance_enabled)",
        "- Empty-server path validated: $($Report.empty_server_path_validated)",
        "- Human-present path validated: $($Report.human_present_path_validated)",
        "- Return-to-empty path validated: $($Report.return_to_empty_validated)"
    )

    if ($Report.remaining_blocker) {
        $lines += "- Remaining blocker: $($Report.remaining_blocker)"
    }

    $lines += @(
        "",
        "## Join Targets",
        "",
        "- Loopback join target: $($Report.join_targets.loopback_address)",
        "- LAN join target: $($Report.join_targets.lan_address)",
        "- Steam connect URI: $($Report.join_targets.steam_connect_uri)",
        "",
        "## State Observations",
        ""
    )

    foreach ($state in @($Report.state_observations.PSObject.Properties | ForEach-Object { $_.Value })) {
        $lines += "- $($state.state_id): observed=$($state.observed); first_observed_at_utc=$($state.first_observed_at_utc); humans=$($state.authoritative_human_count); bots=$($state.authoritative_bot_count); explanation=$($state.explanation)"
    }

    if ($Report.human_join_attempts) {
        $lines += @(
            "",
            "## Human Join Attempts",
            ""
        )

        foreach ($attempt in @($Report.human_join_attempts)) {
            $lines += "- $($attempt.method): launched=$($attempt.launched); authoritative_human_seen=$($attempt.authoritative_human_seen); server_connect_seen=$($attempt.server_connect_seen); server_entered_game_seen=$($attempt.server_entered_game_seen); explanation=$($attempt.explanation)"
        }
    }

    if ($Report.policy_transitions) {
        $lines += @(
            "",
            "## Policy Transitions",
            ""
        )

        foreach ($transition in @($Report.policy_transitions)) {
            $lines += "- $($transition.observed_at_utc): $($transition.policy_state) (humans=$($transition.human_player_count), bots=$($transition.bot_player_count))"
        }
    }

    if ($Report.blocker_evidence.qconsole_tail) {
        $lines += @(
            "",
            "## Latest qconsole Tail",
            "",
            '```text',
            [string]$Report.blocker_evidence.qconsole_tail,
            '```'
        )
    }

    if ($Report.blocker_evidence.steam_connection_log_tail) {
        $lines += @(
            "",
            "## Latest Steam Connection Log Tail",
            "",
            '```text',
            [string]$Report.blocker_evidence.steam_connection_log_tail,
            '```'
        )
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

Assert-BotLaunchSettings -BotCount $BotCountWhenEmpty -BotSkill $BotSkillWhenEmpty

$repoRoot = Get-RepoRoot
$promptId = Get-RepoPromptId
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Resolve-NormalizedPathCandidate -Path $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$resolvedLogsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $resolvedLabRoot)
$resolvedHldsRoot = Get-HldsRootDefault -LabRoot $resolvedLabRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$defaultValidationLeaf = "{0}-validate-public-human-trigger-{1}-p{2}" -f $stamp, $Map, $Port
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Join-Path $resolvedLogsRoot "public_server\human_trigger_validations") $defaultValidationLeaf)
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
    Ensure-Directory -Path $candidate
}

$resolvedPublicServerOutputRoot = if ([string]::IsNullOrWhiteSpace($PublicServerOutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedOutputRoot "public_server")
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($PublicServerOutputRoot)) { $PublicServerOutputRoot } else { Join-Path $repoRoot $PublicServerOutputRoot }
    Ensure-Directory -Path $candidate
}

$validationJsonPath = Join-Path $resolvedOutputRoot "public_human_trigger_validation.json"
$validationMarkdownPath = Join-Path $resolvedOutputRoot "public_human_trigger_validation.md"
$publicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
$publicStatusMarkdownPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.md"
$publicRunnerStdoutPath = Join-Path $resolvedOutputRoot "public_runner.stdout.log"
$publicRunnerStderrPath = Join-Path $resolvedOutputRoot "public_runner.stderr.log"

$script:stateObservations = [ordered]@{
    "bots-active-empty-server" = (New-StateRecord -StateId "bots-active-empty-server")
    "waiting-human-join-grace" = (New-StateRecord -StateId "waiting-human-join-grace")
    "bots-disconnected-humans-present" = (New-StateRecord -StateId "bots-disconnected-humans-present")
    "waiting-empty-server-repopulate" = (New-StateRecord -StateId "waiting-empty-server-repopulate")
    "bots-repopulated-empty-server" = (New-StateRecord -StateId "bots-repopulated-empty-server")
}
$script:policyTransitions = New-Object System.Collections.Generic.List[object]
$script:lastObservedPolicyState = ""
$script:lastStatusSnapshot = $null
$script:humanPhaseObserved = $false
$script:repopulateWaitObservedAfterHuman = $false
$script:launchedClientProcessIds = New-Object System.Collections.Generic.HashSet[int]
$script:statusPollSeconds = [Math]::Max(1, $StatusPollSeconds)
$script:botCountWhenEmpty = $BotCountWhenEmpty

$publicRunnerProcess = $null
$publicRunnerStartedByValidator = $false
$launchPlan = Get-HalfLifeClientLaunchPlan -PreferredClientPath $ClientExePath -ServerHost "127.0.0.1" -Port $Port
$joinInfo = $launchPlan.join_info
$steamExePath = Get-SteamExecutablePath
$steamConnectionLogPath = Get-SteamConnectionLogPath -Port $Port
$serverLogPath = Join-Path $resolvedLogsRoot "hlds.stdout.log"

try {
    if ([string]::IsNullOrWhiteSpace($PublicServerOutputRoot)) {
        $publicRunnerStartedByValidator = $true
        $powershellExe = (Get-Command powershell -ErrorAction Stop).Source
        $publicRunnerArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $PSScriptRoot "run_public_crossfire_server.ps1"),
            "-Map", $Map,
            "-BotCountWhenEmpty", [string]$BotCountWhenEmpty,
            "-BotSkillWhenEmpty", [string]$BotSkillWhenEmpty,
            "-Port", [string]$Port,
            "-LabRoot", $resolvedLabRoot,
            "-OutputRoot", $resolvedPublicServerOutputRoot,
            "-HumanJoinGraceSeconds", [string]$HumanJoinGraceSeconds,
            "-EmptyServerRepopulateDelaySeconds", [string]$EmptyServerRepopulateDelaySeconds,
            "-StatusPollSeconds", [string]$script:statusPollSeconds,
            "-StartupWaitSeconds", [string]$StartupWaitSeconds
        )

        if ($SkipSteamCmdUpdate) {
            $publicRunnerArgs += "-SkipSteamCmdUpdate"
        }

        if ($SkipMetamodDownload) {
            $publicRunnerArgs += "-SkipMetamodDownload"
        }

        if ($EnableAdvancedAIBalance) {
            $publicRunnerArgs += "-EnableAdvancedAIBalance"
        }

        $publicRunnerProcess = Start-Process `
            -FilePath $powershellExe `
            -ArgumentList $publicRunnerArgs `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $publicRunnerStdoutPath `
            -RedirectStandardError $publicRunnerStderrPath `
            -PassThru
    }

    $initialStatusWait = Wait-ForPublicCondition `
        -Description "initial public status" `
        -StatusJsonPath $publicStatusJsonPath `
        -TimeoutSeconds ([Math]::Max(120, $StartupWaitSeconds + 90)) `
        -PollSeconds $script:statusPollSeconds `
        -Condition { param($status) $null -ne $status -and [string]$status.map -eq $Map }

    if (-not $initialStatusWait.matched) {
        throw "The public-mode status file did not become readable at $publicStatusJsonPath."
    }

    $emptyServerValidation = Wait-ForPublicCondition `
        -Description "empty-server bots active" `
        -StatusJsonPath $publicStatusJsonPath `
        -TimeoutSeconds $InitialEmptyValidationSeconds `
        -PollSeconds $script:statusPollSeconds `
        -Condition { param($status) [string]$status.policy_state -eq "bots-active-empty-server" -and [int]$status.human_player_count -eq 0 -and [int]$status.bot_player_count -ge $BotCountWhenEmpty }

    $humanJoinAttempts = New-Object System.Collections.Generic.List[object]
    $humanPresenceValidated = $false
    $returnToEmptyValidated = $false
    $remainingBlocker = ""

    $directLaunchAction = $null
    if ($launchPlan.launchable -and -not [string]::IsNullOrWhiteSpace($launchPlan.client_exe_path)) {
        $directLaunchAction = {
            $startProcessParams = @{
                FilePath = $launchPlan.client_exe_path
                ArgumentList = $launchPlan.arguments
                PassThru = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($launchPlan.client_working_directory)) {
                $startProcessParams["WorkingDirectory"] = $launchPlan.client_working_directory
            }
            return Start-Process @startProcessParams
        }
    }

    $humanJoinAttempts.Add((Invoke-HumanJoinAttempt `
        -Method "direct-hl-exe-connect" `
        -StatusJsonPath $publicStatusJsonPath `
        -ServerLogPath $serverLogPath `
        -ClientQConsolePath $launchPlan.qconsole_path `
        -SteamConnectionLogPath $steamConnectionLogPath `
        -TimeoutSeconds $HumanJoinAttemptWaitSeconds `
        -LaunchAction $directLaunchAction `
        -CommandText $launchPlan.command_text `
        -WorkingDirectory $launchPlan.client_working_directory `
        -ExplanationIfUnavailable [string]$launchPlan.client_discovery.explanation)) | Out-Null

    $latestAttempt = $humanJoinAttempts[$humanJoinAttempts.Count - 1]
    if (-not $latestAttempt.authoritative_human_seen) {
        Stop-TrackedHlProcesses
        Start-Sleep -Seconds 2

        $steamLaunchAction = $null
        $steamCommandText = Get-SteamConnectLaunchCommandText -SteamExePath $steamExePath -SteamConnectUri $joinInfo.SteamConnectUri
        $steamWorkingDirectory = if ($steamExePath) { Split-Path -Path $steamExePath -Parent } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($steamExePath) -and -not [string]::IsNullOrWhiteSpace($joinInfo.SteamConnectUri)) {
            $steamLaunchAction = {
                return Start-Process -FilePath $steamExePath -ArgumentList $joinInfo.SteamConnectUri -PassThru
            }
        }

        $humanJoinAttempts.Add((Invoke-HumanJoinAttempt `
            -Method "steam-connect-uri" `
            -StatusJsonPath $publicStatusJsonPath `
            -ServerLogPath $serverLogPath `
            -ClientQConsolePath $launchPlan.qconsole_path `
            -SteamConnectionLogPath $steamConnectionLogPath `
            -TimeoutSeconds ([Math]::Max(20, [Math]::Floor($HumanJoinAttemptWaitSeconds / 2))) `
            -LaunchAction $steamLaunchAction `
            -CommandText $steamCommandText `
            -WorkingDirectory $steamWorkingDirectory `
            -ExplanationIfUnavailable "Steam.exe was not discoverable for the public-mode fallback attempt.")) | Out-Null
    }

    $latestStatus = Get-PublicStatusSnapshot -StatusJsonPath $publicStatusJsonPath
    if ($null -ne $latestStatus -and [int]$latestStatus.human_player_count -gt 0) {
        $humansPresentHold = Wait-ForPublicCondition `
            -Description "humans present with bots removed" `
            -StatusJsonPath $publicStatusJsonPath `
            -TimeoutSeconds ([Math]::Max(10, $HumansPresentObserveSeconds)) `
            -PollSeconds $script:statusPollSeconds `
            -Condition { param($status) [int]$status.human_player_count -gt 0 -and [int]$status.bot_player_count -eq 0 -and [string]$status.policy_state -eq "bots-disconnected-humans-present" }

        if ($humansPresentHold.matched) {
            $humanPresenceValidated = $true
        }

        Stop-TrackedHlProcesses
        Start-Sleep -Seconds 2

        $waitingForRepopulate = Wait-ForPublicCondition `
            -Description "waiting for empty-server repopulate" `
            -StatusJsonPath $publicStatusJsonPath `
            -TimeoutSeconds ([Math]::Max(20, $EmptyServerRepopulateDelaySeconds + 10)) `
            -PollSeconds $script:statusPollSeconds `
            -Condition { param($status) [int]$status.human_player_count -eq 0 -and [string]$status.policy_state -eq "waiting-empty-server-repopulate" }

        $botsRepopulated = Wait-ForPublicCondition `
            -Description "bots repopulated after humans left" `
            -StatusJsonPath $publicStatusJsonPath `
            -TimeoutSeconds $RepopulateObserveSeconds `
            -PollSeconds $script:statusPollSeconds `
            -Condition { param($status) [int]$status.human_player_count -eq 0 -and [int]$status.bot_player_count -ge $BotCountWhenEmpty -and [string]$status.policy_state -eq "bots-active-empty-server" }

        if ($waitingForRepopulate.matched -and $botsRepopulated.matched) {
            $returnToEmptyValidated = $true
        }
    }
    else {
        $remainingBlocker = "local public-mode human admission still failed before server-side human count increased."
    }

    $latestStatus = Get-PublicStatusSnapshot -StatusJsonPath $publicStatusJsonPath
    $emptyServerValidated = $emptyServerValidation.matched
    $humanAttemptSucceeded = @($humanJoinAttempts | Where-Object { $_.authoritative_human_seen }).Count -gt 0

    $validationVerdict = ""
    $explanation = ""
    if ($emptyServerValidated -and $humanPresenceValidated -and $returnToEmptyValidated) {
        $validationVerdict = "public-human-trigger-validated"
        $explanation = "Observed the full public-mode cycle: empty-server bots active, humans present with bots disconnected, and bots repopulated after humans left."
    }
    elseif (-not $humanAttemptSucceeded) {
        $validationVerdict = "public-human-trigger-blocked-before-server-admission"
        $explanation = "The public server stayed empty of humans during both local join attempts. The narrowest remaining blocker is the local Steam-backed public client admission path, not the empty-server bot policy."
    }
    else {
        $validationVerdict = "public-human-trigger-partially-validated"
        $explanation = "A local human reached the public server, but the full stay-out and repopulate cycle did not finish completely within this validation pass."
    }

    $latestAttemptForEvidence = if ($humanJoinAttempts.Count -gt 0) { $humanJoinAttempts[$humanJoinAttempts.Count - 1] } else { $null }
    $authoritativeHumanCountSource = if ($latestStatus) { [string]$latestStatus.human_count_source } else { "goldsrc-rcon-status" }
    $advancedAiEnabledForReport = if ($latestStatus) { [bool]$latestStatus.advanced_ai_balance_enabled } else { [bool]$EnableAdvancedAIBalance.IsPresent }
    $latestQconsoleTail = if ($latestAttemptForEvidence) { [string]$latestAttemptForEvidence.qconsole_tail } else { "" }
    $latestSteamConnectionLogTail = if ($latestAttemptForEvidence) { [string]$latestAttemptForEvidence.steam_connection_log_tail } else { "" }
    $sourceCommitSha = Get-RepoHeadCommitSha
    $serverLogTail = Get-FileTailText -Path $serverLogPath -LineCount 120
    $policyTransitionsArray = @($script:policyTransitions.ToArray())
    $humanJoinAttemptsArray = @($humanJoinAttempts.ToArray())
    $qconsoleShowsSteamInitFailure = @($humanJoinAttemptsArray | Where-Object { $_.qconsole_contains_steam_init_failure }).Count -gt 0
    $steamConnectionShowsCmFailure = @($humanJoinAttemptsArray | Where-Object { $_.steam_connection_log_contains_cm_failure }).Count -gt 0
    if ($validationVerdict -eq "public-human-trigger-blocked-before-server-admission") {
        if ($steamConnectionShowsCmFailure -and $qconsoleShowsSteamInitFailure) {
            $remainingBlocker = "The public server authoritative human count never exceeded zero. No real human connect was observed server-side, and both qconsole plus the per-port Steam connection log showed Steam-backed public admission failure."
        }
        elseif ($steamConnectionShowsCmFailure) {
            $remainingBlocker = "The public server authoritative human count never exceeded zero. No real human connect was observed server-side, and the per-port Steam connection log showed repeated CM reconnect failures before server admission."
        }
        elseif ($qconsoleShowsSteamInitFailure) {
            $remainingBlocker = "The public server authoritative human count never exceeded zero. No real human connect was observed server-side, and qconsole.log showed Steam initialization failure before server admission."
        }
        else {
            $remainingBlocker = "The public server authoritative human count never exceeded zero. No real human connect was observed server-side, and the local public client still failed before admission."
        }
    }

    $report = [ordered]@{
        schema_version = 1
        prompt_id = $promptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = $sourceCommitSha
        validation_verdict = $validationVerdict
        explanation = $explanation
        public_server_started_by_validator = $publicRunnerStartedByValidator
        public_server_output_root = $resolvedPublicServerOutputRoot
        public_server_status_json_path = $publicStatusJsonPath
        public_server_status_markdown_path = $publicStatusMarkdownPath
        authoritative_human_count_source = $authoritativeHumanCountSource
        advanced_ai_balance_enabled = $advancedAiEnabledForReport
        join_targets = [ordered]@{
            loopback_address = $joinInfo.LoopbackAddress
            lan_address = $joinInfo.LanAddress
            console_command = $joinInfo.ConsoleCommand
            lan_console_command = $joinInfo.LanConsoleCommand
            steam_connect_uri = $joinInfo.SteamConnectUri
        }
        empty_server_path_validated = $emptyServerValidated
        human_present_path_validated = $humanPresenceValidated
        return_to_empty_validated = $returnToEmptyValidated
        remaining_blocker = $remainingBlocker
        state_observations = [pscustomobject]$script:stateObservations
        policy_transitions = $policyTransitionsArray
        human_join_attempts = $humanJoinAttemptsArray
        latest_public_status = $latestStatus
        blocker_evidence = [ordered]@{
            client_discovery_verdict = [string]$launchPlan.client_discovery.discovery_verdict
            client_path = [string]$launchPlan.client_exe_path
            client_working_directory = [string]$launchPlan.client_working_directory
            qconsole_path = [string]$launchPlan.qconsole_path
            qconsole_tail = $latestQconsoleTail
            steam_exe_path = $steamExePath
            steam_connection_log_path = $steamConnectionLogPath
            steam_connection_log_tail = $latestSteamConnectionLogTail
            server_log_path = $serverLogPath
            server_log_tail = $serverLogTail
            public_runner_stdout_log = $publicRunnerStdoutPath
            public_runner_stderr_log = $publicRunnerStderrPath
        }
        artifacts = [ordered]@{
            public_human_trigger_validation_json = $validationJsonPath
            public_human_trigger_validation_markdown = $validationMarkdownPath
            public_server_status_json = $publicStatusJsonPath
            public_server_status_markdown = $publicStatusMarkdownPath
        }
    }

    Write-JsonFile -Path $validationJsonPath -Value $report
    $reportForMarkdown = Get-Content -LiteralPath $validationJsonPath -Raw | ConvertFrom-Json
    Write-TextFile -Path $validationMarkdownPath -Value (Get-ValidationMarkdown -Report $reportForMarkdown)

    Write-Host "Public human-trigger validation:"
    Write-Host "  Verdict: $validationVerdict"
    Write-Host "  Explanation: $explanation"
    Write-Host "  Empty-server path validated: $emptyServerValidated"
    Write-Host "  Human-present path validated: $humanPresenceValidated"
    Write-Host "  Return-to-empty path validated: $returnToEmptyValidated"
    Write-Host "  Advanced AI balance enabled: $($report.advanced_ai_balance_enabled)"
    if ($remainingBlocker) {
        Write-Host "  Remaining blocker: $remainingBlocker"
    }
    Write-Host "  Validation JSON: $validationJsonPath"
    Write-Host "  Validation Markdown: $validationMarkdownPath"
}
finally {
    Stop-TrackedHlProcesses

    if ($publicRunnerStartedByValidator) {
        try {
            Stop-LabProcesses -HldsRoot $resolvedHldsRoot
        }
        catch {
        }

        if ($null -ne $publicRunnerProcess) {
            try {
                $publicRunnerProcess.Refresh()
                if (-not $publicRunnerProcess.HasExited) {
                    Stop-Process -Id $publicRunnerProcess.Id -Force
                }
            }
            catch {
            }
        }
    }
}
