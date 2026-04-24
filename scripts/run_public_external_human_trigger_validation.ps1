[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Map = "crossfire",
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [int]$BotCountWhenEmpty = 4,
    [int]$BotSkillWhenEmpty = 3,
    [switch]$SkipSteamCmdUpdate,
    [switch]$SkipMetamodDownload,
    [string]$ServerAddress = "127.0.0.1",
    [string]$AdvertisedAddress = "",
    [string]$ExpectedExternalTesterName = "",
    [int]$WaitForHumanSeconds = 180,
    [int]$HumanHoldSeconds = 30,
    [int]$WaitForEmptySeconds = 120,
    [int]$RepopulateDelaySeconds = 10,
    [string]$OutputRoot = "",
    [switch]$AttachToExistingServer,
    [switch]$DryRun,
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [int]$StatusPollSeconds = 3,
    [int]$StartupWaitSeconds = 10,
    [int]$HumanJoinGraceSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$promptId = Get-RepoPromptId
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$resolvedHldsRoot = Get-HldsRootDefault -LabRoot $resolvedLabRoot
$validationStartedAtUtc = (Get-Date).ToUniversalTime()
$serverProcess = $null
$startedServer = $false

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

function Get-LatestPublicServerStatusJsonPath {
    param([int]$Port)
    $root = Join-Path $resolvedLabRoot "logs\public_server"
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
    if ($null -eq $latest) {
        return ""
    }
    return [string]$latest.path
}

function Get-ExternalJoinTarget {
    param([string]$AdvertisedAddress, [object]$JoinInfo, [int]$Port)
    if (-not [string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
        if ($AdvertisedAddress -match ':\d+$') {
            return $AdvertisedAddress.Trim()
        }
        return "{0}:{1}" -f $AdvertisedAddress.Trim(), $Port
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$JoinInfo.LanAddress)) {
        return [string]$JoinInfo.LanAddress
    }
    return [string]$JoinInfo.LoopbackAddress
}

function Get-StatusAgeSeconds {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [Math]::Round(((Get-Date).ToUniversalTime() - [System.IO.File]::GetLastWriteTimeUtc($Path)).TotalSeconds, 2)
}

function Get-LatestStatus {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return Read-JsonFile -Path $Path
}

function Get-StatusCount {
    param([object]$Status, [string]$Name)
    if ($null -eq $Status) {
        return 0
    }
    return [int](Get-ObjectPropertyValue -Object $Status -Name $Name -Default 0)
}

function Get-StatusPolicyTarget {
    param([object]$Status)
    if ($null -eq $Status) {
        return -1
    }
    return [int](Get-ObjectPropertyValue -Object $Status -Name "current_bot_target" -Default -1)
}

function Get-StatusPolicyState {
    param([object]$Status)
    if ($null -eq $Status) {
        return ""
    }
    return [string](Get-ObjectPropertyValue -Object $Status -Name "policy_state" -Default "")
}

function New-LifecycleRecord {
    param([string]$State, [object]$Status, [string]$Explanation)
    [ordered]@{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
        state = $State
        authoritative_human_count = Get-StatusCount -Status $Status -Name "human_player_count"
        authoritative_bot_count = Get-StatusCount -Status $Status -Name "bot_player_count"
        policy_target = Get-StatusPolicyTarget -Status $Status
        public_policy_state = Get-StatusPolicyState -Status $Status
        explanation = $Explanation
    }
}

function Add-LifecycleState {
    param(
        [System.Collections.Generic.List[object]]$States,
        [System.Collections.Generic.HashSet[string]]$SeenStates,
        [string]$State,
        [object]$Status,
        [string]$Explanation
    )
    if ($SeenStates.Contains($State)) {
        return
    }
    $States.Add((New-LifecycleRecord -State $State -Status $Status -Explanation $Explanation)) | Out-Null
    [void]$SeenStates.Add($State)
    Write-Host ("[{0}] humans={1} bots={2} target={3} - {4}" -f $State, (Get-StatusCount -Status $Status -Name "human_player_count"), (Get-StatusCount -Status $Status -Name "bot_player_count"), (Get-StatusPolicyTarget -Status $Status), $Explanation)
}

function Wait-ForStatusCondition {
    param(
        [string]$StatusPath,
        [int]$TimeoutSeconds,
        [scriptblock]$Predicate
    )
    $deadline = (Get-Date).ToUniversalTime().AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $latest = $null
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $latest = Get-LatestStatus -Path $StatusPath
        if ($null -ne $latest -and (& $Predicate $latest)) {
            return $latest
        }
        Start-Sleep -Seconds ([Math]::Max(1, $StatusPollSeconds))
    }
    return $latest
}

function Get-JoinInstructionText {
    param([object]$Instructions)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "External public HLDM join instructions",
        "",
        "Server: $($Instructions.external_join_target)",
        "Map: $($Instructions.map)",
        "Expected tester name: $($Instructions.expected_external_tester_name)",
        "Console command: $($Instructions.client_console_command)",
        "Steam URI: $($Instructions.steam_connect_uri)",
        "",
        "Tester steps:",
        "1. Open a real external Half-Life client from a different machine or environment that can reach the server.",
        "2. Join with the console command above.",
        "3. Stay connected for at least $($Instructions.human_hold_seconds) seconds after entering the game.",
        "4. Leave when the operator asks, then report any client-side error text.",
        "",
        "Server-side files to inspect afterward:",
        "$($Instructions.validation_json_path)",
        "$($Instructions.validation_markdown_path)",
        "$($Instructions.public_server_status_json_path)",
        "$($Instructions.public_server_status_markdown_path)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }
    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-JoinInstructionMarkdown {
    param([object]$Instructions)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# Public External Join Instructions",
        "",
        "- Server: $($Instructions.external_join_target)",
        "- Map: $($Instructions.map)",
        "- Expected tester name: $($Instructions.expected_external_tester_name)",
        "- Client console command: $($Instructions.client_console_command)",
        "- Steam URI: $($Instructions.steam_connect_uri)",
        "- Authoritative source of truth: $($Instructions.authoritative_count_source)",
        "",
        "## Tester Steps",
        "",
        "1. Open a real external Half-Life client from a different machine or environment that can reach the server.",
        "2. Join with $($Instructions.client_console_command).",
        "3. Stay connected for at least $($Instructions.human_hold_seconds) seconds after entering the game.",
        "4. Leave when the operator asks.",
        "5. Report any client-side error text or screenshots.",
        "",
        "## Server Files",
        "",
        "- Validation JSON: $($Instructions.validation_json_path)",
        "- Validation Markdown: $($Instructions.validation_markdown_path)",
        "- Public server status JSON: $($Instructions.public_server_status_json_path)",
        "- Public server status Markdown: $($Instructions.public_server_status_markdown_path)",
        "- Public server stdout log: $($Instructions.public_server_stdout_log)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }
    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-ValidationMarkdown {
    param([object]$Report)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# Public External Human Trigger Validation",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Verdict: $($Report.verdict)",
        "- Explanation: $($Report.explanation)",
        "- Map: $($Report.map)",
        "- Port: $($Report.port)",
        "- External join target: $($Report.external_join_target)",
        "- Expected external tester name: $($Report.expected_external_tester_name)",
        "- Client command: $($Report.client_console_command)",
        "- Attach to existing server: $($Report.attach_to_existing_server)",
        "- Dry run: $($Report.dry_run)",
        "- Authoritative count source: $($Report.authoritative_count_source)",
        "- Public server status JSON: $($Report.public_server_status_json_path)",
        "- Public server output root: $($Report.public_server_output_root)",
        ("- Advanced AI balance observed enabled: {0}" -f (Get-ObjectPropertyValue -Object $Report.latest_public_status -Name "advanced_ai_balance_enabled" -Default ""))
    )) {
        $lines.Add([string]$line) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Lifecycle States") | Out-Null
    foreach ($state in @($Report.lifecycle_states)) {
        $lines.Add("- $($state.timestamp_utc) $($state.state): humans=$($state.authoritative_human_count), bots=$($state.authoritative_bot_count), target=$($state.policy_target), public_state=$($state.public_policy_state), $($state.explanation)") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Artifacts") | Out-Null
    $artifactObject = $Report.artifacts
    foreach ($property in @($artifactObject.PSObject.Properties)) {
        $lines.Add("- $($property.Name): $($property.Value)") | Out-Null
    }

    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-ValidationReport {
    param(
        [string]$Verdict,
        [string]$Explanation,
        [object[]]$LifecycleStates,
        [object]$LatestPublicStatus
    )
    [ordered]@{
        schema_version = 1
        prompt_id = $promptId
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_commit_sha = Get-RepoHeadCommitSha
        verdict = $Verdict
        explanation = $Explanation
        map = $Map
        port = $Port
        server_address = $ServerAddress
        advertised_address = $AdvertisedAddress
        expected_external_tester_name = $ExpectedExternalTesterName
        external_join_target = $externalJoinTarget
        client_console_command = "connect $externalJoinTarget"
        steam_connect_uri = "steam://connect/$externalJoinTarget"
        lab_root = $resolvedLabRoot
        output_root = $resolvedOutputRoot
        public_server_output_root = $resolvedPublicServerOutputRoot
        public_server_status_json_path = $resolvedPublicStatusJsonPath
        public_server_status_age_seconds = Get-StatusAgeSeconds -Path $resolvedPublicStatusJsonPath
        public_server_monitor_pid = $(if ($serverProcess) { [int]$serverProcess.Id } else { 0 })
        attach_to_existing_server = $AttachToExistingServer.IsPresent
        dry_run = $DryRun.IsPresent
        authoritative_count_source = "GoldSrc status over RCON, surfaced through scripts/run_public_crossfire_server.ps1 public_server_status.json"
        bot_count_when_empty = $BotCountWhenEmpty
        bot_skill_when_empty = $BotSkillWhenEmpty
        wait_for_human_seconds = $WaitForHumanSeconds
        human_hold_seconds = $HumanHoldSeconds
        wait_for_empty_seconds = $WaitForEmptySeconds
        repopulate_delay_seconds = $RepopulateDelaySeconds
        status_poll_seconds = $StatusPollSeconds
        lifecycle_states = @($LifecycleStates)
        latest_public_status = $LatestPublicStatus
        artifacts = [ordered]@{
            public_external_human_trigger_validation_json = $validationJsonPath
            public_external_human_trigger_validation_markdown = $validationMarkdownPath
            public_external_join_instructions_text = $joinTextPath
            public_external_join_instructions_markdown = $joinMarkdownPath
            public_external_join_instructions_json = $joinJsonPath
            public_server_stdout_log = $publicServerStdoutPath
            public_server_stderr_log = $publicServerStderrPath
        }
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedLabRoot ("logs\public_server\external_human_trigger_validations\{0}-public-external-human-trigger-p{1}" -f $stamp, $Port))
}
else {
    $candidate = Resolve-RepoPathMaybe -Path $OutputRoot
    Ensure-Directory -Path $candidate
}

$resolvedPublicServerOutputRoot = Resolve-RepoPathMaybe -Path $PublicServerOutputRoot
if ([string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot) -and -not $AttachToExistingServer.IsPresent) {
    $resolvedPublicServerOutputRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot "public_server")
}

$resolvedPublicStatusJsonPath = Resolve-RepoPathMaybe -Path $PublicServerStatusJsonPath
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and $AttachToExistingServer.IsPresent) {
    $resolvedPublicStatusJsonPath = Get-LatestPublicServerStatusJsonPath -Port $Port
    if (-not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
        $resolvedPublicServerOutputRoot = Split-Path -Parent $resolvedPublicStatusJsonPath
    }
}

$validationJsonPath = Join-Path $resolvedOutputRoot "public_external_human_trigger_validation.json"
$validationMarkdownPath = Join-Path $resolvedOutputRoot "public_external_human_trigger_validation.md"
$joinTextPath = Join-Path $resolvedOutputRoot "public_external_join_instructions.txt"
$joinMarkdownPath = Join-Path $resolvedOutputRoot "public_external_join_instructions.md"
$joinJsonPath = Join-Path $resolvedOutputRoot "public_external_join_instructions.json"
$publicServerStdoutPath = Join-Path $resolvedOutputRoot "public_server_runner.stdout.log"
$publicServerStderrPath = Join-Path $resolvedOutputRoot "public_server_runner.stderr.log"

$joinInfo = Get-HldsJoinInfo -ServerHost $ServerAddress -Port $Port
$externalJoinTarget = Get-ExternalJoinTarget -AdvertisedAddress $AdvertisedAddress -JoinInfo $joinInfo -Port $Port
$publicStatusMarkdownPath = if (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) { Join-Path $resolvedPublicServerOutputRoot "public_server_status.md" } else { "" }

$joinInstructions = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    map = $Map
    port = $Port
    server_address = $ServerAddress
    advertised_address = $AdvertisedAddress
    expected_external_tester_name = $ExpectedExternalTesterName
    external_join_target = $externalJoinTarget
    client_console_command = "connect $externalJoinTarget"
    steam_connect_uri = "steam://connect/$externalJoinTarget"
    human_hold_seconds = $HumanHoldSeconds
    authoritative_count_source = "GoldSrc status over RCON, surfaced through scripts/run_public_crossfire_server.ps1 public_server_status.json"
    validation_json_path = $validationJsonPath
    validation_markdown_path = $validationMarkdownPath
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_server_status_markdown_path = $publicStatusMarkdownPath
    public_server_stdout_log = $publicServerStdoutPath
}

Write-JsonFile -Path $joinJsonPath -Value $joinInstructions
$joinForText = Get-Content -LiteralPath $joinJsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $joinTextPath -Value (Get-JoinInstructionText -Instructions $joinForText)
Write-TextFile -Path $joinMarkdownPath -Value (Get-JoinInstructionMarkdown -Instructions $joinForText)

$lifecycleStates = New-Object System.Collections.Generic.List[object]
$seenLifecycleStates = New-Object System.Collections.Generic.HashSet[string]
$verdict = "external-validation-inconclusive-manual-review"
$explanation = "Validation did not complete."
$latestStatus = $null

try {
    Write-Host "Public external validation target:"
    Write-Host "  Join target: $externalJoinTarget"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExternalTesterName)) {
        Write-Host "  Expected tester name: $ExpectedExternalTesterName"
    }
    Write-Host "  Client command: connect $externalJoinTarget"
    Write-Host "  Join instructions: $joinMarkdownPath"

    if ($DryRun.IsPresent) {
        Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "waiting-external-human" -Status $null -Explanation "Dry run only; no public server was started and no external admission was observed."
        $verdict = "external-validation-inconclusive-manual-review"
        $explanation = "Dry run wrote external join instructions and validation artifact paths without starting or polling a server."
    }
    else {
        if (-not $AttachToExistingServer.IsPresent) {
            $serverRunDurationSeconds = [Math]::Max(
                45,
                $StartupWaitSeconds + $HumanJoinGraceSeconds + $WaitForHumanSeconds + $HumanHoldSeconds + $WaitForEmptySeconds + $RepopulateDelaySeconds + 45
            )
            $serverArgs = New-Object System.Collections.Generic.List[string]
            foreach ($arg in @(
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
                "-EmptyServerRepopulateDelaySeconds", [string]$RepopulateDelaySeconds,
                "-StatusPollSeconds", [string]$StatusPollSeconds,
                "-StartupWaitSeconds", [string]$StartupWaitSeconds,
                "-RunDurationSeconds", [string]$serverRunDurationSeconds,
                "-StopServerOnExit"
            )) {
                $serverArgs.Add([string]$arg) | Out-Null
            }
            if ($SkipSteamCmdUpdate.IsPresent) {
                $serverArgs.Add("-SkipSteamCmdUpdate") | Out-Null
            }
            if ($SkipMetamodDownload.IsPresent) {
                $serverArgs.Add("-SkipMetamodDownload") | Out-Null
            }

            $serverProcess = Start-Process -FilePath "powershell" -ArgumentList $serverArgs.ToArray() -WorkingDirectory $repoRoot -RedirectStandardOutput $publicServerStdoutPath -RedirectStandardError $publicServerStderrPath -PassThru
            $startedServer = $true
            Write-Host "  Started public server monitor PID: $($serverProcess.Id)"
        }
        else {
            Write-Host "  Attaching to public status: $resolvedPublicStatusJsonPath"
        }

        if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
            $verdict = "public-server-not-reachable-locally"
            $explanation = "No public server status path was available to poll."
            Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "validation-timeout" -Status $null -Explanation $explanation
        }
        else {
            $readyTimeout = [Math]::Max(120, $StartupWaitSeconds + $HumanJoinGraceSeconds + $RepopulateDelaySeconds + 60)
            $latestStatus = Wait-ForStatusCondition -StatusPath $resolvedPublicStatusJsonPath -TimeoutSeconds $readyTimeout -Predicate {
                param($status)
                [bool](Get-ObjectPropertyValue -Object $status -Name "server_ready" -Default $false) -and [bool](Get-ObjectPropertyValue -Object $status -Name "last_query_successful" -Default $false)
            }

            if ($null -eq $latestStatus) {
                $verdict = "public-server-not-reachable-locally"
                $explanation = "The public status file was not produced before the local readiness timeout."
                Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "validation-timeout" -Status $null -Explanation $explanation
            }
            elseif (-not [bool](Get-ObjectPropertyValue -Object $latestStatus -Name "last_query_successful" -Default $false)) {
                $verdict = "public-server-not-reachable-locally"
                $explanation = "The public status file exists, but it does not contain a successful GoldSrc RCON status query."
                Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "validation-timeout" -Status $latestStatus -Explanation $explanation
            }
            else {
                $emptyStatus = Wait-ForStatusCondition -StatusPath $resolvedPublicStatusJsonPath -TimeoutSeconds ([Math]::Max(60, $HumanJoinGraceSeconds + $RepopulateDelaySeconds + 30)) -Predicate {
                    param($status)
                    (Get-StatusCount -Status $status -Name "human_player_count") -eq 0 -and
                    (Get-StatusCount -Status $status -Name "bot_player_count") -ge $BotCountWhenEmpty -and
                    (Get-StatusPolicyState -Status $status) -eq "bots-active-empty-server"
                }
                if ($null -ne $emptyStatus -and (Get-StatusPolicyState -Status $emptyStatus) -eq "bots-active-empty-server") {
                    $latestStatus = $emptyStatus
                    Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "bots-active-empty-server" -Status $latestStatus -Explanation "The public server is empty of humans and the configured bot pool is active."
                }

                Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "waiting-external-human" -Status $latestStatus -Explanation "Waiting for an external real Half-Life client to appear in authoritative server status."
                $humanStatus = Wait-ForStatusCondition -StatusPath $resolvedPublicStatusJsonPath -TimeoutSeconds $WaitForHumanSeconds -Predicate {
                    param($status)
                    (Get-StatusCount -Status $status -Name "human_player_count") -gt 0
                }
                $latestStatus = $humanStatus

                if ($null -eq $humanStatus -or (Get-StatusCount -Status $humanStatus -Name "human_player_count") -le 0) {
                    $verdict = "external-human-admission-not-observed"
                    $explanation = "No real non-BOT external human was observed by authoritative GoldSrc RCON status within the wait window."
                    Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "validation-blocked-no-external-admission" -Status $humanStatus -Explanation $explanation
                }
                else {
                    Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "external-human-admitted" -Status $humanStatus -Explanation "A real non-BOT human appeared in authoritative server status."

                    $disconnectStatus = Wait-ForStatusCondition -StatusPath $resolvedPublicStatusJsonPath -TimeoutSeconds ([Math]::Max(15, $StatusPollSeconds * 4)) -Predicate {
                        param($status)
                        (Get-StatusCount -Status $status -Name "human_player_count") -gt 0 -and
                        (Get-StatusCount -Status $status -Name "bot_player_count") -eq 0 -and
                        (Get-StatusPolicyTarget -Status $status) -eq 0
                    }
                    $latestStatus = $disconnectStatus
                    if ($null -eq $disconnectStatus -or (Get-StatusCount -Status $disconnectStatus -Name "bot_player_count") -gt 0 -or (Get-StatusPolicyTarget -Status $disconnectStatus) -ne 0) {
                        $verdict = "bots-failed-to-disconnect-on-human"
                        $explanation = "An external human was admitted, but bots did not fully disconnect or the policy target did not reach zero."
                    }
                    else {
                        Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "bots-disconnected-humans-present" -Status $disconnectStatus -Explanation "Bots were removed and the empty-server bot target is zero while a human remains present."

                        $holdDeadline = (Get-Date).ToUniversalTime().AddSeconds([Math]::Max(1, $HumanHoldSeconds))
                        $holdSucceeded = $true
                        while ((Get-Date).ToUniversalTime() -lt $holdDeadline) {
                            $latestStatus = Get-LatestStatus -Path $resolvedPublicStatusJsonPath
                            if ($null -eq $latestStatus -or (Get-StatusCount -Status $latestStatus -Name "human_player_count") -le 0 -or (Get-StatusPolicyTarget -Status $latestStatus) -ne 0) {
                                $holdSucceeded = $false
                                break
                            }
                            Start-Sleep -Seconds ([Math]::Max(1, $StatusPollSeconds))
                        }
                        if ($holdSucceeded) {
                            Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "humans-hold-bots-out" -Status $latestStatus -Explanation "The human remained present through the hold window and bots stayed out."
                        }

                        $emptyAgainStatus = Wait-ForStatusCondition -StatusPath $resolvedPublicStatusJsonPath -TimeoutSeconds $WaitForEmptySeconds -Predicate {
                            param($status)
                            (Get-StatusCount -Status $status -Name "human_player_count") -eq 0
                        }
                        $latestStatus = $emptyAgainStatus
                        if ($null -eq $emptyAgainStatus -or (Get-StatusCount -Status $emptyAgainStatus -Name "human_player_count") -gt 0) {
                            $verdict = "external-validation-inconclusive-manual-review"
                            $explanation = "The external human was admitted, but the server did not become empty again within the configured wait."
                        }
                        else {
                            Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "waiting-empty-server-repopulate" -Status $emptyAgainStatus -Explanation "The external human left; waiting for the bounded empty-server repopulation path."

                            $repopulatedStatus = Wait-ForStatusCondition -StatusPath $resolvedPublicStatusJsonPath -TimeoutSeconds ([Math]::Max(10, $RepopulateDelaySeconds + 30)) -Predicate {
                                param($status)
                                (Get-StatusCount -Status $status -Name "human_player_count") -eq 0 -and
                                (Get-StatusCount -Status $status -Name "bot_player_count") -ge $BotCountWhenEmpty -and
                                (Get-StatusPolicyState -Status $status) -eq "bots-active-empty-server"
                            }
                            $latestStatus = $repopulatedStatus
                            if ($null -eq $repopulatedStatus -or (Get-StatusCount -Status $repopulatedStatus -Name "bot_player_count") -lt $BotCountWhenEmpty) {
                                $verdict = "bots-failed-to-repopulate-after-empty"
                                $explanation = "The server became empty again, but the configured bot pool did not repopulate within the bounded wait."
                            }
                            else {
                                Add-LifecycleState -States $lifecycleStates -SeenStates $seenLifecycleStates -State "bots-repopulated-empty-server" -Status $repopulatedStatus -Explanation "The server became empty and the configured bot pool returned."
                                $verdict = "external-human-trigger-validated"
                                $explanation = "A real external human was admitted, bots disconnected while the human stayed, and bots repopulated after the server became empty again."
                            }
                        }
                    }
                }
            }
        }
    }
}
finally {
    $latestForReport = if (-not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) { Get-LatestStatus -Path $resolvedPublicStatusJsonPath } else { $latestStatus }
    if ($null -eq $latestForReport) {
        $latestForReport = [ordered]@{}
    }

    $report = New-ValidationReport -Verdict $verdict -Explanation $explanation -LifecycleStates @($lifecycleStates.ToArray()) -LatestPublicStatus $latestForReport
    Write-JsonFile -Path $validationJsonPath -Value $report
    $reportForMarkdown = Get-Content -LiteralPath $validationJsonPath -Raw | ConvertFrom-Json
    Write-TextFile -Path $validationMarkdownPath -Value (Get-ValidationMarkdown -Report $reportForMarkdown)

    if ($startedServer -and -not $AttachToExistingServer.IsPresent) {
        try {
            Stop-LabProcesses -HldsRoot $resolvedHldsRoot
        }
        catch {
        }
        if ($null -ne $serverProcess) {
            try {
                $serverProcess.Refresh()
                if (-not $serverProcess.HasExited) {
                    Stop-Process -Id $serverProcess.Id -Force
                }
            }
            catch {
            }
        }
    }
}

Write-Host "Public external human-trigger validation:"
Write-Host "  Verdict: $verdict"
Write-Host "  JSON: $validationJsonPath"
Write-Host "  Markdown: $validationMarkdownPath"
Write-Host "  Join instructions: $joinMarkdownPath"

if ($verdict -eq "public-server-not-reachable-locally") {
    exit 2
}
