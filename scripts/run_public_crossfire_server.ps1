param(
    [string]$Map = "crossfire",
    [int]$BotCountWhenEmpty = 4,
    [int]$BotSkillWhenEmpty = 3,
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [string]$OutputRoot = "",
    [string]$SteamCmdPath = "",
    [string]$PythonPath = "",
    [string]$TuningProfile = "default",
    [string]$Hostname = "HLDM JK_Botti Public Crossfire",
    [int]$MaxPlayers = 12,
    [int]$HumanJoinGraceSeconds = 15,
    [int]$EmptyServerRepopulateDelaySeconds = 10,
    [int]$StatusPollSeconds = 5,
    [int]$StartupWaitSeconds = 5,
    [int]$RunDurationSeconds = 0,
    [switch]$StopServerOnExit,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [switch]$EnableAdvancedAIBalance
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-PublicStatusFiles {
    param(
        [string]$JsonPath,
        [string]$MarkdownPath,
        [object]$Status
    )

    $parent = Split-Path -Parent $JsonPath
    if ($parent) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $json = $Status | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $JsonPath -Value $json -Encoding UTF8

    $lines = @(
        "# Public Server Status",
        "",
        "- Generated at UTC: $($Status.generated_at_utc)",
        "- Prompt ID: $($Status.prompt_id)",
        "- State: $($Status.policy_state)",
        "- Explanation: $($Status.explanation)",
        "- Server started: $($Status.server_started)",
        "- Server PID: $($Status.server_pid)",
        "- Map: $($Status.map)",
        "- Port: $($Status.port)",
        "- Loopback join target: $($Status.join_targets.loopback_address)",
        "- LAN join target: $($Status.join_targets.lan_address)",
        "- Steam connect URI: $($Status.join_targets.steam_connect_uri)",
        "- Max players: $($Status.max_players)",
        "- Bot target when empty: $($Status.bot_count_target_when_empty)",
        "- Current commanded bot target: $($Status.current_bot_target)",
        "- Bot skill when empty: $($Status.bot_skill_target_when_empty)",
        "- Human player count: $($Status.human_player_count)",
        "- Bot player count: $($Status.bot_player_count)",
        "- Human count source: $($Status.human_count_source)",
        "- Human join grace seconds: $($Status.human_join_grace_seconds)",
        "- Empty-server repopulate delay seconds: $($Status.empty_server_repopulate_delay_seconds)",
        "- Advanced AI balance enabled: $($Status.advanced_ai_balance_enabled)",
        "- Last policy action: $($Status.last_policy_action)",
        "- Last query successful: $($Status.last_query_successful)",
        "- Server ready: $($Status.server_ready)",
        "- Status JSON: $JsonPath"
    )

    if ($Status.players) {
        $lines += ""
        $lines += "## Players"
        foreach ($player in @($Status.players)) {
            $playerType = if ($player.is_bot) { "bot" } else { "human" }
            $lines += "- $($player.name) [$playerType]"
        }
    }

    if ($Status.last_query_error) {
        $lines += ""
        $lines += "## Last Query Error"
        $lines += ""
        $lines += '```text'
        $lines += [string]$Status.last_query_error
        $lines += '```'
    }

    Set-Content -LiteralPath $MarkdownPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

function Invoke-GoldSrcRconCommand {
    param(
        [string]$ServerHost,
        [int]$Port,
        [string]$Password,
        [string]$Command,
        [int]$TimeoutMilliseconds = 2000
    )

    function Send-GoldSrcUdpMessage {
        param(
            [System.Net.Sockets.UdpClient]$Client,
            [string]$Message
        )

        $prefix = [byte[]](0xFF, 0xFF, 0xFF, 0xFF)
        $body = [System.Text.Encoding]::ASCII.GetBytes($Message)
        $packet = New-Object byte[] ($prefix.Length + $body.Length)
        [Array]::Copy($prefix, 0, $packet, 0, $prefix.Length)
        [Array]::Copy($body, 0, $packet, $prefix.Length, $body.Length)
        [void]$Client.Send($packet, $packet.Length)
    }

    function Receive-GoldSrcUdpText {
        param([System.Net.Sockets.UdpClient]$Client)

        $remoteEndPoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $chunks = New-Object System.Collections.Generic.List[string]
        while ($true) {
            try {
                $responseBytes = $Client.Receive([ref]$remoteEndPoint)
            }
            catch [System.Management.Automation.MethodInvocationException] {
                break
            }

            if ($responseBytes.Length -gt 4) {
                $text = [System.Text.Encoding]::ASCII.GetString($responseBytes, 4, ($responseBytes.Length - 4))
                $chunks.Add($text.Trim()) | Out-Null
            }
        }

        return (($chunks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
    }

    $udpClient = [System.Net.Sockets.UdpClient]::new()
    try {
        $udpClient.Client.ReceiveTimeout = $TimeoutMilliseconds
        $udpClient.Connect($ServerHost, $Port)

        Send-GoldSrcUdpMessage -Client $udpClient -Message "challenge rcon"
        $challengeText = Receive-GoldSrcUdpText -Client $udpClient
        if ($challengeText -notmatch 'challenge rcon\s+(-?\d+)') {
            throw "The server did not return a usable GoldSrc RCON challenge."
        }

        $challengeToken = [string]$matches[1]
        $escapedPassword = $Password.Replace('"', '')
        Send-GoldSrcUdpMessage -Client $udpClient -Message ('rcon {0} "{1}" {2}' -f $challengeToken, $escapedPassword, $Command)
        return Receive-GoldSrcUdpText -Client $udpClient
    }
    finally {
        $udpClient.Dispose()
    }
}

function Get-GoldSrcStatusSnapshot {
    param(
        [string]$ServerHost,
        [int]$Port,
        [string]$Password
    )

    $statusText = Invoke-GoldSrcRconCommand -ServerHost $ServerHost -Port $Port -Password $Password -Command "status"
    if ([string]::IsNullOrWhiteSpace($statusText)) {
        throw "The server did not return any status text."
    }

    if ($statusText -match "Bad rcon_password") {
        throw "The server rejected the configured RCON password."
    }

    $players = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($statusText -split "`r?`n")) {
        if ($line -notmatch '^\s*#\s*\d+\s+"([^"]+)"') {
            continue
        }

        $trimmedLine = $line.Trim()
        $name = [string]$matches[1]
        $isBot = $trimmedLine -match "\bBOT\b"
        $players.Add([pscustomobject]@{
            name = $name
            is_bot = $isBot
            raw_line = $trimmedLine
        }) | Out-Null
    }

    $humanPlayers = @($players | Where-Object { -not $_.is_bot })
    $botPlayers = @($players | Where-Object { $_.is_bot })

    return [pscustomobject]@{
        queried_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        status_text = $statusText
        players = $players.ToArray()
        human_players = @($humanPlayers)
        bot_players = @($botPlayers)
        human_count = $humanPlayers.Count
        bot_count = $botPlayers.Count
    }
}

function Invoke-PublicServerCommand {
    param(
        [string]$ServerHost,
        [int]$Port,
        [string]$Password,
        [string]$Command
    )

    $response = Invoke-GoldSrcRconCommand -ServerHost $ServerHost -Port $Port -Password $Password -Command $Command
    return [pscustomobject]@{
        command = $Command
        response = $response
    }
}

function Set-PublicModeBotTarget {
    param(
        [string]$ServerHost,
        [int]$Port,
        [string]$Password,
        [int]$TargetCount,
        [int]$BotSkill
    )

    $results = New-Object System.Collections.Generic.List[object]
    $results.Add((Invoke-PublicServerCommand -ServerHost $ServerHost -Port $Port -Password $Password -Command ("jk_botti botskill {0}" -f $BotSkill))) | Out-Null
    $results.Add((Invoke-PublicServerCommand -ServerHost $ServerHost -Port $Port -Password $Password -Command ("jk_botti min_bots {0}" -f $TargetCount))) | Out-Null
    $results.Add((Invoke-PublicServerCommand -ServerHost $ServerHost -Port $Port -Password $Password -Command ("jk_botti max_bots {0}" -f $TargetCount))) | Out-Null

    return $results.ToArray()
}

function Initialize-PublicServerPolicy {
    param(
        [string]$ServerHost,
        [int]$Port,
        [string]$Password,
        [int]$BotSkill,
        [bool]$EnableAdvancedAIBalance
    )

    $commands = @(
        "jk_botti min_bots 0",
        "jk_botti max_bots 0",
        ("jk_botti botskill {0}" -f $BotSkill),
        ("jk_ai_balance_enabled {0}" -f $(if ($EnableAdvancedAIBalance) { 1 } else { 0 }))
    )

    foreach ($command in $commands) {
        Invoke-PublicServerCommand -ServerHost $ServerHost -Port $Port -Password $Password -Command $command | Out-Null
    }

    Set-PublicModeBotTarget -ServerHost $ServerHost -Port $Port -Password $Password -TargetCount 0 -BotSkill $BotSkill | Out-Null
}

Assert-BotLaunchSettings -BotCount $BotCountWhenEmpty -BotSkill $BotSkillWhenEmpty

if ($HumanJoinGraceSeconds -lt 0) {
    throw "HumanJoinGraceSeconds must be zero or greater."
}

if ($EmptyServerRepopulateDelaySeconds -lt 0) {
    throw "EmptyServerRepopulateDelaySeconds must be zero or greater."
}

if ($StatusPollSeconds -lt 1) {
    throw "StatusPollSeconds must be at least 1 second."
}

if ($StartupWaitSeconds -lt 1) {
    throw "StartupWaitSeconds must be at least 1 second."
}

$repoRoot = Get-RepoRoot
$promptId = Get-RepoPromptId
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$resolvedHldsRoot = Get-HldsRootDefault -LabRoot $resolvedLabRoot
$resolvedToolsRoot = Ensure-Directory -Path (Join-Path $resolvedLabRoot "tools")
$resolvedLogsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $resolvedLabRoot)
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedLogsRoot ("public_server\{0}-public-{1}-p{2}" -f $stamp, $Map, $Port))
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
    Ensure-Directory -Path $candidate
}

$statusJsonPath = Join-Path $resolvedOutputRoot "public_server_status.json"
$statusMarkdownPath = Join-Path $resolvedOutputRoot "public_server_status.md"
$rconPassword = ([Guid]::NewGuid().ToString("N").Substring(0, 24))
$maxPlayersResolved = [Math]::Max($MaxPlayers, [Math]::Max(8, ($BotCountWhenEmpty + 4)))
$advancedAiEnabled = $EnableAdvancedAIBalance.IsPresent
$humanCountSource = "goldsrc-rcon-status"
$serverHost = "127.0.0.1"
$joinInfo = Get-HldsJoinInfo -Port $Port -ServerHost $serverHost
$policyCommandSettleSeconds = [Math]::Max(3, $StatusPollSeconds)

Write-Host "Resolved public crossfire server settings:"
Write-Host "  Map: $Map"
Write-Host "  Port: $Port"
Write-Host "  Max players: $maxPlayersResolved"
Write-Host "  Bot target when empty: $BotCountWhenEmpty"
Write-Host "  Bot skill when empty: $BotSkillWhenEmpty"
Write-Host "  Human join grace seconds: $HumanJoinGraceSeconds"
Write-Host "  Empty-server repopulate delay seconds: $EmptyServerRepopulateDelaySeconds"
Write-Host "  Advanced AI balance: $(if ($advancedAiEnabled) { "enabled" } else { "disabled" })"
Write-Host "  Status output root: $resolvedOutputRoot"

& (Join-Path $PSScriptRoot "build_vs2022.ps1") -Configuration "Release" -Platform "Win32"
Stop-LabProcesses -HldsRoot $resolvedHldsRoot

$setupArgs = @{
    LabRoot = $resolvedLabRoot
    HldsRoot = $resolvedHldsRoot
    ToolsRoot = $resolvedToolsRoot
    SteamCmdPath = $SteamCmdPath
    Configuration = "Release"
    Platform = "Win32"
    SkipBuild = $true
}

if ($SkipSteamCmdUpdate) {
    $setupArgs.SkipSteamCmdUpdate = $true
}

if ($SkipMetamodDownload) {
    $setupArgs.SkipMetamodDownload = $true
}

& (Join-Path $PSScriptRoot "setup_test_stand.ps1") @setupArgs

$modRoot = Get-ServerModRoot -HldsRoot $resolvedHldsRoot
Write-ServerCfg -ModRoot $modRoot -Hostname $Hostname -SvLan 0 -FragLimit 0 -TimeLimit 0 -RconPassword $rconPassword
$publicConfigPath = Write-PublicCrossfireConfig -HldsRoot $resolvedHldsRoot -Map $Map -BotSkill $BotSkillWhenEmpty -EnableAdvancedAIBalance:$advancedAiEnabled
$deployment = Test-JKBottiLabDeployment -HldsRoot $resolvedHldsRoot -Configuration "Release" -Platform "Win32"
$aiProcess = $null
$serverProcess = $null
$stopProcessesOnExit = $StopServerOnExit.IsPresent

try {
    if ($advancedAiEnabled) {
        $aiProcess = & (Join-Path $PSScriptRoot "run_ai_director.ps1") -LabRoot $resolvedLabRoot -HldsRoot $resolvedHldsRoot -PythonPath $PythonPath -TuningProfile $TuningProfile -PassThru
    }

    $serverProcess = & (Join-Path $PSScriptRoot "run_server.ps1") `
        -LabRoot $resolvedLabRoot `
        -HldsRoot $resolvedHldsRoot `
        -Map $Map `
        -MaxPlayers $maxPlayersResolved `
        -Port $Port `
        -Hostname $Hostname `
        -SvLan 0 `
        -RconPassword $rconPassword `
        -FragLimit 0 `
        -TimeLimit 0 `
        -PassThru

    Start-Sleep -Seconds $StartupWaitSeconds

    $monitorStartedAtUtc = [DateTime]::UtcNow
    $runDeadlineUtc = if ($RunDurationSeconds -gt 0) { $monitorStartedAtUtc.AddSeconds($RunDurationSeconds) } else { $null }
    $emptySinceUtc = $monitorStartedAtUtc
    $lastPolicyActionAtUtc = [DateTime]::MinValue
    $lastPolicyAction = "none"
    $lastExplanation = "Public server started. Waiting for the first authoritative status query."
    $lastSuccessfulSnapshot = $null
    $serverReady = $false
    $policyInitialized = $false
    $currentBotTarget = -1

    while ($true) {
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) {
            $lastExplanation = "The HLDS process exited, so public-mode policy monitoring stopped."
        }

        $nowUtc = [DateTime]::UtcNow
        $querySucceeded = $false
        $queryError = ""
        $policyState = if ($lastSuccessfulSnapshot) { "waiting-empty-server-repopulate" } else { "waiting-human-join-grace" }
        $snapshot = $lastSuccessfulSnapshot
        $players = @()
        $humanCount = 0
        $botCount = 0

        if (-not $serverProcess.HasExited) {
            try {
                $snapshot = Get-GoldSrcStatusSnapshot -ServerHost $serverHost -Port $Port -Password $rconPassword
                $lastSuccessfulSnapshot = $snapshot
                $querySucceeded = $true
                $serverReady = $true
                $players = @($snapshot.players)
                $humanCount = [int]$snapshot.human_count
                $botCount = [int]$snapshot.bot_count

                if (-not $policyInitialized) {
                    Initialize-PublicServerPolicy -ServerHost $serverHost -Port $Port -Password $rconPassword -BotSkill $BotSkillWhenEmpty -EnableAdvancedAIBalance:$advancedAiEnabled
                    $policyInitialized = $true
                    $currentBotTarget = 0
                }

                $canIssuePolicyAction = ($lastPolicyActionAtUtc -eq [DateTime]::MinValue) -or (($nowUtc - $lastPolicyActionAtUtc).TotalSeconds -ge $policyCommandSettleSeconds)

                if ($humanCount -gt 0) {
                    $emptySinceUtc = $null
                    $policyState = "bots-disconnected-humans-present"
                    if ($canIssuePolicyAction -and ($currentBotTarget -ne 0 -or $botCount -gt 0)) {
                        Set-PublicModeBotTarget -ServerHost $serverHost -Port $Port -Password $rconPassword -TargetCount 0 -BotSkill $BotSkillWhenEmpty | Out-Null
                        $currentBotTarget = 0
                        if ($botCount -gt 0) {
                            Invoke-PublicServerCommand -ServerHost $serverHost -Port $Port -Password $rconPassword -Command "jk_botti kickall" | Out-Null
                        }
                        $lastPolicyActionAtUtc = $nowUtc
                        $lastPolicyAction = "set-public-bot-target 0 + jk_botti kickall"
                        $lastExplanation = "Humans are present, so public mode set the empty-server bot target to zero and disconnected bots. Bots stay out while humans remain."
                    }
                    else {
                        $lastExplanation = "Humans are present and public mode is holding the empty-server bot target at zero, so bots remain absent."
                    }
                }
                else {
                    if ($null -eq $emptySinceUtc) {
                        $emptySinceUtc = $nowUtc
                    }

                    $secondsSinceStart = ($nowUtc - $monitorStartedAtUtc).TotalSeconds
                    $secondsSinceEmpty = ($nowUtc - $emptySinceUtc).TotalSeconds

                    if ($botCount -eq 0 -and $secondsSinceStart -lt $HumanJoinGraceSeconds) {
                        $policyState = "waiting-human-join-grace"
                        if ($canIssuePolicyAction -and $currentBotTarget -ne 0) {
                            Set-PublicModeBotTarget -ServerHost $serverHost -Port $Port -Password $rconPassword -TargetCount 0 -BotSkill $BotSkillWhenEmpty | Out-Null
                            $currentBotTarget = 0
                            $lastPolicyActionAtUtc = $nowUtc
                            $lastPolicyAction = "set-public-bot-target 0"
                        }
                        $lastExplanation = "The server is empty, but public mode is still holding bots back during the initial human-join grace window."
                    }
                    elseif ($botCount -lt $BotCountWhenEmpty -and $secondsSinceEmpty -lt $EmptyServerRepopulateDelaySeconds) {
                        $policyState = "waiting-empty-server-repopulate"
                        if ($canIssuePolicyAction -and $currentBotTarget -ne 0) {
                            Set-PublicModeBotTarget -ServerHost $serverHost -Port $Port -Password $rconPassword -TargetCount 0 -BotSkill $BotSkillWhenEmpty | Out-Null
                            $currentBotTarget = 0
                            $lastPolicyActionAtUtc = $nowUtc
                            $lastPolicyAction = "set-public-bot-target 0"
                        }
                        $lastExplanation = "The server is empty. Public mode is waiting for the bounded repopulate delay before restoring bots."
                    }
                    else {
                        if ($canIssuePolicyAction -and $currentBotTarget -ne $BotCountWhenEmpty) {
                            Set-PublicModeBotTarget -ServerHost $serverHost -Port $Port -Password $rconPassword -TargetCount $BotCountWhenEmpty -BotSkill $BotSkillWhenEmpty | Out-Null
                            $currentBotTarget = $BotCountWhenEmpty
                            $lastPolicyActionAtUtc = $nowUtc
                            $lastPolicyAction = ("set-public-bot-target {0}" -f $BotCountWhenEmpty)
                            $policyState = "waiting-empty-server-repopulate"
                            $lastExplanation = "The server is empty, so public mode set the authoritative bot target to the configured empty-server pool and is waiting for the plugin to materialize bots."
                        }
                        elseif ($botCount -ge $BotCountWhenEmpty) {
                            $policyState = "bots-active-empty-server"
                            $lastExplanation = "The server is empty and the configured bot pool is active."
                        }
                        else {
                            $policyState = "waiting-empty-server-repopulate"
                            $lastExplanation = "The server is empty and bot restoration is still settling."
                        }
                    }
                }
            }
            catch {
                $queryError = $_.Exception.Message
                $lastExplanation = "The public-mode monitor could not query authoritative server status yet."
                if ($lastSuccessfulSnapshot) {
                    $players = @($lastSuccessfulSnapshot.players)
                    $humanCount = [int]$lastSuccessfulSnapshot.human_count
                    $botCount = [int]$lastSuccessfulSnapshot.bot_count
                }
            }
        }

        $status = [ordered]@{
            schema_version = 1
            prompt_id = $promptId
            generated_at_utc = $nowUtc.ToString("o")
            source_commit_sha = Get-RepoHeadCommitSha
            output_root = $resolvedOutputRoot
            server_started = $null -ne $serverProcess
            server_ready = $serverReady
            server_pid = $(if ($serverProcess) { $serverProcess.Id } else { 0 })
            server_host = $serverHost
            port = $Port
            map = $Map
            hostname = $Hostname
            max_players = $maxPlayersResolved
            join_targets = [ordered]@{
                loopback_address = $joinInfo.LoopbackAddress
                lan_address = $joinInfo.LanAddress
                console_command = $joinInfo.ConsoleCommand
                lan_console_command = $joinInfo.LanConsoleCommand
                steam_connect_uri = $joinInfo.SteamConnectUri
            }
            public_config_path = $publicConfigPath
            bootstrap_log_path = $deployment.BootstrapLogPath
            plugin_relative_path = $deployment.PluginRelativePath
            bot_count_target_when_empty = $BotCountWhenEmpty
            current_bot_target = $currentBotTarget
            bot_skill_target_when_empty = $BotSkillWhenEmpty
            human_join_grace_seconds = $HumanJoinGraceSeconds
            empty_server_repopulate_delay_seconds = $EmptyServerRepopulateDelaySeconds
            human_count_source = $humanCountSource
            human_player_count = $humanCount
            bot_player_count = $botCount
            players = $players
            policy_state = $policyState
            last_policy_action = $lastPolicyAction
            advanced_ai_balance_enabled = $advancedAiEnabled
            ai_director_pid = $(if ($aiProcess) { $aiProcess.Id } else { 0 })
            last_query_successful = $querySucceeded
            last_query_error = $queryError
            latest_status_query_utc = $(if ($snapshot) { [string]$snapshot.queried_at_utc } else { "" })
            latest_empty_since_utc = $(if ($emptySinceUtc) { $emptySinceUtc.ToString("o") } else { "" })
            explanation = $lastExplanation
            artifacts = [ordered]@{
                public_server_status_json = $statusJsonPath
                public_server_status_markdown = $statusMarkdownPath
                hlds_stdout_log = Join-Path $resolvedLogsRoot "hlds.stdout.log"
                hlds_stderr_log = Join-Path $resolvedLogsRoot "hlds.stderr.log"
                ai_director_stdout_log = Join-Path $resolvedLogsRoot "ai_director.stdout.log"
                ai_director_stderr_log = Join-Path $resolvedLogsRoot "ai_director.stderr.log"
            }
        }

        Write-PublicStatusFiles -JsonPath $statusJsonPath -MarkdownPath $statusMarkdownPath -Status $status

        Write-Host ("[{0}] state={1} humans={2} bots={3} ai={4}" -f $status.generated_at_utc, $policyState, $humanCount, $botCount, $(if ($advancedAiEnabled) { "on" } else { "off" }))

        if ($serverProcess.HasExited) {
            break
        }

        if ($runDeadlineUtc -and $nowUtc -ge $runDeadlineUtc) {
            $stopProcessesOnExit = $true
            break
        }

        Start-Sleep -Seconds $StatusPollSeconds
    }
}
finally {
    foreach ($process in @($aiProcess, $serverProcess)) {
        if ($null -eq $process) {
            continue
        }

        try {
            $process.Refresh()
            if ($stopProcessesOnExit -and -not $process.HasExited) {
                Stop-Process -Id $process.Id -Force
            }
        }
        catch {
        }
    }
}
