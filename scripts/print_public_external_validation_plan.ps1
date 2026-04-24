[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ServerAddress = "127.0.0.1",
    [int]$ServerPort = 27015,
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [string]$OutputRoot = ""
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
    $json = $Value | ConvertTo-Json -Depth 12
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
    $root = Join-Path $labRoot "logs\public_server"
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

function Get-PlanMarkdown {
    param([object]$Plan)
    $lines = @(
        "# Public External Validation Plan",
        "",
        "- Generated at UTC: $($Plan.generated_at_utc)",
        "- Prompt ID: $($Plan.prompt_id)",
        "- Server address: $($Plan.server_address)",
        "- Server port: $($Plan.server_port)",
        "- Loopback join target: $($Plan.join_targets.loopback_address)",
        "- LAN join target: $($Plan.join_targets.lan_address)",
        "- Steam connect URI: $($Plan.join_targets.steam_connect_uri)",
        "- Public status JSON: $($Plan.public_server_status_json_path)",
        "- Public status Markdown: $($Plan.public_server_status_markdown_path)",
        "- Server log path: $($Plan.server_log_path)"
    )
    $lines += @("", "## Steps", "")
    foreach ($step in @($Plan.operator_steps)) {
        $lines += "- $($step)"
    }
    $lines += @("", "## Expected Public States", "")
    foreach ($state in @($Plan.expected_public_states)) {
        $lines += "- $state"
    }
    $lines += @("", "## Artifacts To Save", "")
    foreach ($artifact in @($Plan.artifacts_to_save)) {
        $lines += "- $artifact"
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Ensure-Directory -Path (Join-Path $labRoot ("logs\public_server\external_validation_plans\{0}-public-external-validation-plan-p{1}" -f $stamp, $ServerPort))
}
else {
    $candidate = Resolve-RepoPathMaybe -Path $OutputRoot
    Ensure-Directory -Path $candidate
}

$planJsonPath = Join-Path $resolvedOutputRoot "public_external_validation_plan.json"
$planMarkdownPath = Join-Path $resolvedOutputRoot "public_external_validation_plan.md"

$resolvedPublicServerOutputRoot = Resolve-RepoPathMaybe -Path $PublicServerOutputRoot
$resolvedPublicStatusJsonPath = Resolve-RepoPathMaybe -Path $PublicServerStatusJsonPath
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
$joinInfo = Get-HldsJoinInfo -ServerHost $ServerAddress -Port $ServerPort
$statusMarkdownPath = if (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) { Join-Path $resolvedPublicServerOutputRoot "public_server_status.md" } else { "" }
$serverLogPath = ""
if ($null -ne $publicStatus) {
    $serverLogPath = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $publicStatus -Name "artifacts" -Default $null) -Name "hlds_stdout_log" -Default "")
}

$plan = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    server_address = $ServerAddress
    server_port = $ServerPort
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_server_status_markdown_path = $statusMarkdownPath
    server_log_path = $serverLogPath
    join_targets = [ordered]@{
        loopback_address = [string]$joinInfo.LoopbackAddress
        lan_address = [string]$joinInfo.LanAddress
        steam_connect_uri = [string]$joinInfo.SteamConnectUri
    }
    expected_public_states = @(
        "Before external join: public_server_status.json should show human_player_count=0 and policy_state=bots-active-empty-server or waiting-empty-server-repopulate.",
        "After one real external client joins: human_player_count should become greater than 0.",
        "While the human remains present: policy_state should become bots-disconnected-humans-present and current_bot_target should be 0.",
        "After the human leaves: human_player_count should return to 0, then policy_state should pass through waiting-empty-server-repopulate.",
        "After the bounded delay: bot_player_count should repopulate and policy_state should return to bots-active-empty-server."
    )
    operator_steps = @(
        "Start the public server with scripts\\run_public_crossfire_server.ps1 on crossfire, advanced AI left disabled by default.",
        "From an external real Half-Life client, connect to the LAN/public target shown in public_server_status.md or use the Steam connect URI if appropriate.",
        "Watch public_server_status.json while the external client connects; do not treat client-side launch alone as success.",
        "Confirm the server log records a non-BOT connected line and preferably a non-BOT entered-the-game line.",
        "Confirm bots disconnect while the human remains present by checking current_bot_target=0, bot_player_count, and policy_state=bots-disconnected-humans-present.",
        "Have the external human leave, then wait at least the configured empty-server repopulate delay.",
        "Confirm bots repopulate after human leave through public_server_status.json and the server log."
    )
    artifacts_to_save = @(
        "public_server_status.json",
        "public_server_status.md",
        "HLDS stdout/server log from the public server output root",
        "Any external client console screenshot or notes showing the join target and timing",
        "If running validate_public_human_trigger.ps1 after admission works, save public_human_trigger_validation.json and .md"
    )
    artifacts = [ordered]@{
        public_external_validation_plan_json = $planJsonPath
        public_external_validation_plan_markdown = $planMarkdownPath
    }
}

Write-JsonFile -Path $planJsonPath -Value $plan
$planForMarkdown = Get-Content -LiteralPath $planJsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $planMarkdownPath -Value (Get-PlanMarkdown -Plan $planForMarkdown)

Write-Host "Public external validation plan:"
Write-Host "  Plan JSON: $planJsonPath"
Write-Host "  Plan Markdown: $planMarkdownPath"
