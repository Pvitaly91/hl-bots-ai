[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$SteamExePath = "",
    [string]$ClientExePath = "",
    [string]$ServerAddress = "127.0.0.1",
    [int]$ServerPort = 27015,
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
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

function Get-LatestPublicValidationJsonPath {
    $root = Join-Path $labRoot "logs\public_server\human_trigger_validations"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return ""
    }

    $latest = Get-ChildItem -LiteralPath $root -Recurse -Filter "public_human_trigger_validation.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        return ""
    }

    return $latest.FullName
}

function Get-PublicSteamEnvironmentMarkdown {
    param([object]$Audit)

    $steamTailText = [string](Get-ObjectPropertyValue -Object $Audit -Name "steam_connection_log_tail" -Default "")
    $lines = @(
        "# Public Steam Environment Audit",
        "",
        "- Generated at UTC: $($Audit.generated_at_utc)",
        "- Prompt ID: $($Audit.prompt_id)",
        "- Conclusion: $($Audit.conclusion)",
        "- Explanation: $($Audit.explanation)",
        "- Steam executable: $($Audit.steam_exe_path)",
        "- Steam install root: $($Audit.steam_install_root)",
        "- Half-Life client: $($Audit.client_exe_path)",
        "- Steam running: $($Audit.steam_running)",
        "- steamwebhelper running: $($Audit.steamwebhelper_running)",
        "- App manifest present: $($Audit.half_life_app_manifest_present)",
        "- Steam-backed working directory: $($Audit.public_launch_plan.steam_working_directory)",
        "- Direct launch working directory: $($Audit.public_launch_plan.direct_working_directory)",
        "- Preferred launch path: $($Audit.public_launch_plan.preferred_launch_path)",
        "- Steam-native command: $($Audit.public_launch_plan.steam_native_command)",
        "- Steam URI command: $($Audit.public_launch_plan.steam_uri_command)",
        "- Direct command: $($Audit.public_launch_plan.direct_command)",
        "- Steam connection log path: $($Audit.steam_connection_log_path)",
        "- Steam connection log present: $($Audit.steam_connection_log_present)",
        "- Steam CM failure seen: $($Audit.steam_connection_log_contains_cm_failure)",
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

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Ensure-Directory -Path (Join-Path $labRoot ("logs\public_server\steam_environment_audits\{0}-public-steam-environment-p{1}" -f $stamp, $ServerPort))
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
    Ensure-Directory -Path $candidate
}

$auditJsonPath = Join-Path $resolvedOutputRoot "public_steam_environment_audit.json"
$auditMarkdownPath = Join-Path $resolvedOutputRoot "public_steam_environment_audit.md"

$resolvedPublicServerOutputRoot = Resolve-JsonPathMaybe -Path $PublicServerOutputRoot
$resolvedPublicStatusJsonPath = Resolve-JsonPathMaybe -Path $PublicServerStatusJsonPath
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}

$resolvedPublicValidationJsonPath = Resolve-JsonPathMaybe -Path $PublicValidationJsonPath
if ([string]::IsNullOrWhiteSpace($resolvedPublicValidationJsonPath)) {
    $resolvedPublicValidationJsonPath = Get-LatestPublicValidationJsonPath
}

$publicStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$validation = Read-JsonFile -Path $resolvedPublicValidationJsonPath
$admissionPlan = Get-PublicHldmClientAdmissionPlan -PreferredSteamPath $SteamExePath -PreferredClientPath $ClientExePath -ServerAddress $ServerAddress -ServerPort $ServerPort
$clientDiscovery = Get-HalfLifeClientDiscovery -PreferredPath $ClientExePath

$resolvedSteamExePath = [string]$admissionPlan.steam_exe_path
$steamInstallRoot = if ([string]::IsNullOrWhiteSpace($resolvedSteamExePath)) { "" } else { Split-Path -Path $resolvedSteamExePath -Parent }
$resolvedClientExePath = [string]$clientDiscovery.client_path
$steamLogsRoot = Get-SteamLogsRoot
$steamConnectionLogPath = Get-SteamConnectionLogPath -Port $ServerPort
$steamConnectionLogPresent = -not [string]::IsNullOrWhiteSpace($steamConnectionLogPath) -and (Test-Path -LiteralPath $steamConnectionLogPath -PathType Leaf)
$steamConnectionLogTail = Get-FileTailText -Path $steamConnectionLogPath -LineCount 120
$steamWebApiFailureSeen = $steamConnectionLogTail -match "GetCMListForConnect -- web API call failed"
$steamCmFailureSeen = $steamConnectionLogTail -match "failed talking to cm|ConnectFailed\(|StartAutoReconnect"
$steamRunning = [bool](Get-Process -Name "steam" -ErrorAction SilentlyContinue)
$steamWebHelperRunning = [bool](Get-Process -Name "steamwebhelper" -ErrorAction SilentlyContinue)

$libraryRoots = New-Object System.Collections.Generic.List[string]
foreach ($steamRoot in @(Get-SteamInstallRoots)) {
    if ([string]::IsNullOrWhiteSpace($steamRoot)) {
        continue
    }

    $libraryRoots.Add($steamRoot) | Out-Null
    $libraryFoldersPath = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
    foreach ($libraryRoot in @(Get-SteamLibraryRootsFromVdf -LibraryFoldersPath $libraryFoldersPath)) {
        if (-not [string]::IsNullOrWhiteSpace($libraryRoot)) {
            $libraryRoots.Add($libraryRoot) | Out-Null
        }
    }
}
$libraryRoots = @($libraryRoots | Select-Object -Unique)

$appManifestCandidates = New-Object System.Collections.Generic.List[string]
foreach ($libraryRoot in @($libraryRoots)) {
    if ([string]::IsNullOrWhiteSpace($libraryRoot)) {
        continue
    }

    if (-not (Test-Path -LiteralPath $libraryRoot -PathType Container -ErrorAction SilentlyContinue)) {
        continue
    }

    $appManifestCandidates.Add((Join-Path $libraryRoot "steamapps\appmanifest_70.acf")) | Out-Null
}
$appManifestCandidates = @($appManifestCandidates | Select-Object -Unique)
$existingAppManifest = $appManifestCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

$evidenceFound = New-Object System.Collections.Generic.List[string]
$evidenceMissing = New-Object System.Collections.Generic.List[string]

if (-not [string]::IsNullOrWhiteSpace($resolvedSteamExePath) -and (Test-Path -LiteralPath $resolvedSteamExePath -PathType Leaf)) {
    $evidenceFound.Add("steam.exe path resolved") | Out-Null
}
else {
    $evidenceMissing.Add("steam.exe path") | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($resolvedClientExePath) -and (Test-Path -LiteralPath $resolvedClientExePath -PathType Leaf)) {
    $evidenceFound.Add("hl.exe path resolved") | Out-Null
}
else {
    $evidenceMissing.Add("hl.exe path") | Out-Null
}

if ($steamRunning) { $evidenceFound.Add("Steam client process is running") | Out-Null } else { $evidenceMissing.Add("running Steam client process") | Out-Null }
if ($steamWebHelperRunning) { $evidenceFound.Add("steamwebhelper process is running") | Out-Null } else { $evidenceMissing.Add("running steamwebhelper process") | Out-Null }
if ($existingAppManifest) { $evidenceFound.Add("Half-Life app manifest exists") | Out-Null } else { $evidenceMissing.Add("Half-Life app manifest") | Out-Null }
if ($steamConnectionLogPresent) { $evidenceFound.Add("per-port Steam connection log exists") | Out-Null } else { $evidenceMissing.Add("per-port Steam connection log") | Out-Null }
if ($steamWebApiFailureSeen) { $evidenceFound.Add("Steam connection log shows CM list web API failure") | Out-Null }
if ($steamCmFailureSeen) { $evidenceFound.Add("Steam connection log shows CM reconnect failure before server admission") | Out-Null }

$publicValidatorVerdict = [string](Get-ObjectPropertyValue -Object $validation -Name "validation_verdict" -Default "")
$publicValidatorRemainingBlocker = [string](Get-ObjectPropertyValue -Object $validation -Name "remaining_blocker" -Default "")
$authoritativeHumanCount = [int](Get-ObjectPropertyValue -Object $publicStatus -Name "human_player_count" -Default -1)
$authoritativeBotCount = [int](Get-ObjectPropertyValue -Object $publicStatus -Name "bot_player_count" -Default -1)

$conclusion = ""
$explanation = ""
if ([string]::IsNullOrWhiteSpace($resolvedSteamExePath) -or -not (Test-Path -LiteralPath $resolvedSteamExePath -PathType Leaf) -or
    [string]::IsNullOrWhiteSpace($resolvedClientExePath) -or -not (Test-Path -LiteralPath $resolvedClientExePath -PathType Leaf)) {
    $conclusion = "steam-environment-blocked-before-admission"
    $explanation = "The local public admission environment is missing a required executable path, so repo-side public admission cannot reach server admission yet."
}
elseif ($steamCmFailureSeen -or $steamWebApiFailureSeen) {
    $conclusion = "steam-environment-blocked-before-admission"
    $explanation = "The local Steam + HL environment is configured well enough to launch, but the per-port Steam connection log shows CM admission failure before any public server connect. That narrows the remaining blocker to the local Steam admission environment rather than the repo-side public bot policy."
}
elseif (-not $steamRunning) {
    $conclusion = "steam-environment-ready-with-warnings"
    $explanation = "The required Steam and Half-Life paths are present, but Steam was not already running when the audit ran. Public admission may still work because the Steam launch path can start Steam on demand."
}
elseif (-not $steamConnectionLogPresent) {
    $conclusion = "steam-environment-ready-with-warnings"
    $explanation = "The required Steam and Half-Life paths are present, but there is no per-port Steam connection log yet for this server port. Run one admission attempt to confirm whether the local Steam admission chain fails or succeeds."
}
elseif ($publicValidatorVerdict -eq "public-human-trigger-blocked-before-server-admission") {
    $conclusion = "steam-environment-ready-with-warnings"
    $explanation = "The local Steam and Half-Life paths look present, but the latest validator still blocked before server admission. The saved validator artifacts should be compared with a fresh Steam-backed attempt."
}
elseif ($authoritativeHumanCount -ge 0) {
    $conclusion = "steam-environment-ready"
    $explanation = "The local Steam and Half-Life public admission environment looks ready for another public human-trigger run."
}
else {
    $conclusion = "steam-environment-inconclusive"
    $explanation = "The audit did not find enough fresh local Steam admission evidence to classify the environment more precisely."
}

$audit = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    server_address = $ServerAddress
    server_port = $ServerPort
    conclusion = $conclusion
    explanation = $explanation
    steam_exe_path = $resolvedSteamExePath
    steam_install_root = $steamInstallRoot
    steam_install_roots_checked = @((Get-SteamInstallRoots))
    steam_logs_root = $steamLogsRoot
    steam_running = $steamRunning
    steamwebhelper_running = $steamWebHelperRunning
    client_exe_path = $resolvedClientExePath
    client_discovery_explanation = [string](Get-ObjectPropertyValue -Object $clientDiscovery -Name "explanation" -Default "")
    client_discovery_sources = @((Get-ObjectPropertyValue -Object $clientDiscovery -Name "sources_checked" -Default @()))
    half_life_app_manifest_present = [bool](-not [string]::IsNullOrWhiteSpace($existingAppManifest))
    half_life_app_manifest_path = if ($existingAppManifest) { $existingAppManifest } else { "" }
    half_life_app_manifest_candidates = @($appManifestCandidates)
    public_launch_plan = [ordered]@{
        preferred_launch_path = [string]$admissionPlan.preferred_launch_path
        steam_working_directory = [string]$admissionPlan.steam_working_directory
        direct_working_directory = [string](Get-ObjectPropertyValue -Object $admissionPlan.direct_launch_plan -Name "client_working_directory" -Default "")
        steam_native_command = [string]$admissionPlan.steam_launch_command_text
        steam_uri_command = [string]$admissionPlan.steam_connect_uri_command_text
        direct_command = [string](Get-ObjectPropertyValue -Object $admissionPlan.direct_launch_plan -Name "command_text" -Default "")
    }
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_validation_json_path = $resolvedPublicValidationJsonPath
    authoritative_human_count = $authoritativeHumanCount
    authoritative_bot_count = $authoritativeBotCount
    public_validator_verdict = $publicValidatorVerdict
    public_validator_remaining_blocker = $publicValidatorRemainingBlocker
    steam_connection_log_path = $steamConnectionLogPath
    steam_connection_log_present = $steamConnectionLogPresent
    steam_connection_log_contains_webapi_failure = $steamWebApiFailureSeen
    steam_connection_log_contains_cm_failure = $steamCmFailureSeen
    steam_connection_log_tail = $steamConnectionLogTail
    evidence_found = @($evidenceFound.ToArray())
    evidence_missing = @($evidenceMissing.ToArray())
    artifacts = [ordered]@{
        public_steam_environment_audit_json = $auditJsonPath
        public_steam_environment_audit_markdown = $auditMarkdownPath
    }
}

Write-JsonFile -Path $auditJsonPath -Value $audit
$auditForMarkdown = Read-JsonFile -Path $auditJsonPath
Write-TextFile -Path $auditMarkdownPath -Value (Get-PublicSteamEnvironmentMarkdown -Audit $auditForMarkdown)

Write-Host "Public Steam environment audit:"
Write-Host "  Conclusion: $conclusion"
Write-Host "  Explanation: $explanation"
Write-Host "  Audit JSON: $auditJsonPath"
Write-Host "  Audit Markdown: $auditMarkdownPath"
