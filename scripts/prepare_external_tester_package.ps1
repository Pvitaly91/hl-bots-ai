[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Map = "crossfire",
    [int]$Port = 27015,
    [string]$ServerAddress = "127.0.0.1",
    [string]$AdvertisedAddress = "",
    [string]$ExpectedExternalTesterName = "",
    [int]$WaitForHumanSeconds = 180,
    [int]$HumanHoldSeconds = 30,
    [int]$WaitForEmptySeconds = 120,
    [int]$RepopulateDelaySeconds = 10,
    [string]$LabRoot = "",
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [string]$ValidationOutputRoot = "",
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$promptId = Get-RepoPromptId
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Directory -Path $parent | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 14
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $encoding)
}

function Write-TextFile {
    param([string]$Path, [string]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Directory -Path $parent | Out-Null }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Read-JsonFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Resolve-RepoPathMaybe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $repoRoot $Path
}

function Get-LatestPublicServerStatusJsonPath {
    param([int]$Port)
    $root = Join-Path $resolvedLabRoot "logs\public_server"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return "" }
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

function Get-JoinTarget {
    param([string]$AdvertisedAddress, [object]$JoinInfo, [int]$Port)
    if (-not [string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
        if ($AdvertisedAddress -match ':\d+$') { return $AdvertisedAddress.Trim() }
        return "{0}:{1}" -f $AdvertisedAddress.Trim(), $Port
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$JoinInfo.LanAddress)) { return [string]$JoinInfo.LanAddress }
    return [string]$JoinInfo.LoopbackAddress
}

function Get-PackageMarkdown {
    param([object]$Package)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# External Tester Package",
        "",
        "- Generated at UTC: $($Package.generated_at_utc)",
        "- Prompt ID: $($Package.prompt_id)",
        "- Server target: $($Package.external_join_target)",
        "- Map: $($Package.map)",
        "- Port: $($Package.port)",
        "- Expected tester name: $($Package.expected_external_tester_name)",
        "- Client command: $($Package.client_console_command)",
        "- Steam URI: $($Package.steam_connect_uri)",
        "- Human hold seconds: $($Package.human_hold_seconds)",
        "- Public status JSON: $($Package.public_server_status_json_path)",
        "- Validation output root: $($Package.validation_output_root)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Send To Tester") | Out-Null
    foreach ($step in @($Package.tester_steps)) {
        $lines.Add("- $step") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Operator Watch List") | Out-Null
    foreach ($item in @($Package.operator_watch_list)) {
        $lines.Add("- $item") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Expected Bot Behavior") | Out-Null
    foreach ($item in @($Package.expected_bot_behavior)) {
        $lines.Add("- $item") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Commands") | Out-Null
    $lines.Add("- Network preflight: $($Package.operator_commands.public_network_exposure_preflight)") | Out-Null
    $lines.Add("- Firewall dry-run: $($Package.operator_commands.firewall_dry_run)") | Out-Null
    $lines.Add("- External validation watcher: $($Package.operator_commands.external_validation_watcher)") | Out-Null

    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

function Get-JoinStepsText {
    param([object]$Package)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "External Half-Life tester join steps",
        "",
        "Server: $($Package.external_join_target)",
        "Map: $($Package.map)",
        "Command: $($Package.client_console_command)",
        "",
        "1. Start Half-Life Deathmatch from a real external client machine or network.",
        "2. Open the console and run: $($Package.client_console_command)",
        "3. If you enter the server, stay connected for at least $($Package.human_hold_seconds) seconds.",
        "4. Wait for the operator to confirm bots have disconnected.",
        "5. Leave the server when the operator asks.",
        "6. Report any client-side error, timeout, password prompt, version mismatch, or disconnect text.",
        "",
        "Expected behavior:",
        "- Before you join: bots are present.",
        "- When you join: bots disconnect.",
        "- While you stay: bots remain absent.",
        "- After you leave: bots return after the configured delay."
    )) {
        $lines.Add([string]$line) | Out-Null
    }
    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedLabRoot ("logs\public_server\external_tester_packages\{0}-external-tester-package-p{1}" -f $stamp, $Port))
}
else {
    Ensure-Directory -Path (Resolve-RepoPathMaybe -Path $OutputRoot)
}

$resolvedPublicServerOutputRoot = Resolve-RepoPathMaybe -Path $PublicServerOutputRoot
$resolvedPublicStatusJsonPath = Resolve-RepoPathMaybe -Path $PublicServerStatusJsonPath
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
    $resolvedPublicStatusJsonPath = Get-LatestPublicServerStatusJsonPath -Port $Port
}
if ([string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
    $resolvedPublicServerOutputRoot = Split-Path -Parent $resolvedPublicStatusJsonPath
}

$resolvedValidationOutputRoot = Resolve-RepoPathMaybe -Path $ValidationOutputRoot
if ([string]::IsNullOrWhiteSpace($resolvedValidationOutputRoot)) {
    $resolvedValidationOutputRoot = Join-Path $resolvedLabRoot "logs\public_server\external_human_trigger_validations"
}

$joinInfo = Get-HldsJoinInfo -ServerHost $ServerAddress -Port $Port
$externalJoinTarget = Get-JoinTarget -AdvertisedAddress $AdvertisedAddress -JoinInfo $joinInfo -Port $Port
$statusPayload = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$publicStatusMarkdownPath = if (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) { Join-Path $resolvedPublicServerOutputRoot "public_server_status.md" } else { "" }

$jsonPath = Join-Path $resolvedOutputRoot "external_tester_package.json"
$markdownPath = Join-Path $resolvedOutputRoot "external_tester_package.md"
$stepsPath = Join-Path $resolvedOutputRoot "external_tester_join_steps.txt"

$package = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    map = $Map
    port = $Port
    server_address = $ServerAddress
    advertised_address = $AdvertisedAddress
    external_join_target = $externalJoinTarget
    client_console_command = "connect $externalJoinTarget"
    steam_connect_uri = "steam://connect/$externalJoinTarget"
    expected_external_tester_name = $ExpectedExternalTesterName
    wait_for_human_seconds = $WaitForHumanSeconds
    human_hold_seconds = $HumanHoldSeconds
    wait_for_empty_seconds = $WaitForEmptySeconds
    repopulate_delay_seconds = $RepopulateDelaySeconds
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_server_status_markdown_path = $publicStatusMarkdownPath
    latest_public_status = $statusPayload
    validation_output_root = $resolvedValidationOutputRoot
    tester_steps = @(
        "Start a real external Half-Life Deathmatch client from a different machine or network.",
        "Open the client console and run: connect $externalJoinTarget",
        "Stay connected for at least $HumanHoldSeconds seconds after entering the game.",
        "Wait for the operator to confirm bots disconnected before leaving.",
        "Leave when the operator asks so bot repopulation can be checked.",
        "Report any timeout, version mismatch, password prompt, disconnect, or other client-side error text."
    )
    operator_watch_list = @(
        "Run scripts\\preflight_public_network_exposure.ps1 before the tester starts.",
        "Run scripts\\run_public_external_human_trigger_validation.ps1 and keep it open while the tester joins and leaves.",
        "Watch public_server_status.json for human_player_count greater than 0.",
        "Confirm policy_state becomes bots-disconnected-humans-present and current_bot_target becomes 0.",
        "After the tester leaves, confirm policy_state returns to bots-active-empty-server and bot_player_count returns to the configured empty-server target.",
        "Save the validation JSON/Markdown, public_server_status.json/.md, server stdout/stderr logs, and tester error notes."
    )
    expected_bot_behavior = @(
        "Before tester joins: bots present on an empty public crossfire server.",
        "Tester joins: authoritative human count increases and bots disconnect.",
        "Tester stays: bots remain absent while humans are present.",
        "Tester leaves: after the bounded delay, bots repopulate on the empty server."
    )
    operator_commands = [ordered]@{
        public_network_exposure_preflight = ("powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight_public_network_exposure.ps1 -Port {0} -AdvertisedAddress {1} -PublicServerOutputRoot {2}" -f $Port, (Format-ProcessArgumentText -Value $AdvertisedAddress), (Format-ProcessArgumentText -Value $resolvedPublicServerOutputRoot))
        firewall_dry_run = ("powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure_public_hlds_firewall.ps1 -Port {0}" -f $Port)
        external_validation_watcher = ("powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_public_external_human_trigger_validation.ps1 -Map {0} -Port {1} -AdvertisedAddress {2} -ExpectedExternalTesterName {3} -WaitForHumanSeconds {4} -HumanHoldSeconds {5} -WaitForEmptySeconds {6} -RepopulateDelaySeconds {7} -SkipSteamCmdUpdate -SkipMetamodDownload" -f (Format-ProcessArgumentText -Value $Map), $Port, (Format-ProcessArgumentText -Value $AdvertisedAddress), (Format-ProcessArgumentText -Value $ExpectedExternalTesterName), $WaitForHumanSeconds, $HumanHoldSeconds, $WaitForEmptySeconds, $RepopulateDelaySeconds)
    }
    artifacts = [ordered]@{
        external_tester_package_json = $jsonPath
        external_tester_package_markdown = $markdownPath
        external_tester_join_steps_text = $stepsPath
    }
}

Write-JsonFile -Path $jsonPath -Value $package
$packageForOutput = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $markdownPath -Value (Get-PackageMarkdown -Package $packageForOutput)
Write-TextFile -Path $stepsPath -Value (Get-JoinStepsText -Package $packageForOutput)

Write-Host "External tester package:"
Write-Host "  Join target: $externalJoinTarget"
Write-Host "  JSON: $jsonPath"
Write-Host "  Markdown: $markdownPath"
Write-Host "  Tester steps: $stepsPath"
