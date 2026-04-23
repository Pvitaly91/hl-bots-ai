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
    [string[]]$PreferredPaths = @(),
    [int]$AdmissionWaitSeconds = 45,
    [int]$StatusPollSeconds = 2
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

function Normalize-PreferredPaths {
    param([string[]]$Values)

    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        foreach ($part in @($value -split ",")) {
            $candidate = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }

            switch ($candidate.ToLowerInvariant()) {
                "steam" { $normalized.Add("steam-native-applaunch") | Out-Null }
                "steam-native" { $normalized.Add("steam-native-applaunch") | Out-Null }
                "steam-native-applaunch" { $normalized.Add("steam-native-applaunch") | Out-Null }
                "steam-uri" { $normalized.Add("steam-connect-uri") | Out-Null }
                "steam-connect-uri" { $normalized.Add("steam-connect-uri") | Out-Null }
                "direct" { $normalized.Add("direct-hl-exe-connect") | Out-Null }
                "direct-hl-exe" { $normalized.Add("direct-hl-exe-connect") | Out-Null }
                "direct-hl-exe-connect" { $normalized.Add("direct-hl-exe-connect") | Out-Null }
                default { $normalized.Add($candidate) | Out-Null }
            }
        }
    }

    return @($normalized.ToArray())
}

function Get-PathAvailability {
    param(
        [string]$PathId,
        [object]$AdmissionPlan
    )

    switch ($PathId) {
        "steam-native-applaunch" {
            return -not [string]::IsNullOrWhiteSpace([string]$AdmissionPlan.steam_exe_path)
        }
        "steam-connect-uri" {
            return -not [string]::IsNullOrWhiteSpace([string]$AdmissionPlan.steam_exe_path) -and -not [string]::IsNullOrWhiteSpace([string]$AdmissionPlan.steam_connect_uri)
        }
        "direct-hl-exe-connect" {
            return [bool](Get-ObjectPropertyValue -Object $AdmissionPlan.direct_launch_plan -Name "launchable" -Default $false)
        }
        default {
            return $false
        }
    }
}

function Get-PathScore {
    param([object]$Result)

    if ($null -eq $Result) {
        return -1
    }

    if ([bool](Get-ObjectPropertyValue -Object $Result -Name "authoritative_human_seen" -Default $false)) {
        return 60
    }
    if ([bool](Get-ObjectPropertyValue -Object $Result -Name "entered_the_game_seen" -Default $false)) {
        return 50
    }
    if ([bool](Get-ObjectPropertyValue -Object $Result -Name "server_connect_seen" -Default $false)) {
        return 40
    }
    if ([bool](Get-ObjectPropertyValue -Object $Result -Name "client_process_started" -Default $false)) {
        return 20
    }
    if ([bool](Get-ObjectPropertyValue -Object $Result -Name "launcher_process_started" -Default $false)) {
        return 10
    }

    return 0
}

function Get-ComparisonMarkdown {
    param([object]$Comparison)

    $lines = @(
        "# Public Admission Path Comparison",
        "",
        "- Generated at UTC: $($Comparison.generated_at_utc)",
        "- Prompt ID: $($Comparison.prompt_id)",
        "- Comparison verdict: $($Comparison.comparison_verdict)",
        "- Explanation: $($Comparison.explanation)",
        "- Server address: $($Comparison.server_address)",
        "- Server port: $($Comparison.server_port)",
        "- Best path: $($Comparison.best_path)",
        "- Best path score: $($Comparison.best_path_score)",
        "- Dry run: $($Comparison.dry_run)"
    )

    if ($Comparison.path_results) {
        $lines += @("", "## Path Results", "")
        foreach ($entry in @($Comparison.path_results)) {
            $lines += "- $($entry.path_id): available=$($entry.path_available); stage=$($entry.narrowest_failure_stage); client_process_started=$($entry.client_process_started); server_connect_seen=$($entry.server_connect_seen); entered_the_game_seen=$($entry.entered_the_game_seen); authoritative_human_seen=$($entry.authoritative_human_seen); explanation=$($entry.explanation)"
            $lines += "  command=$($entry.command_text)"
        }
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Ensure-Directory -Path (Join-Path $labRoot ("logs\public_server\admission_path_comparisons\{0}-public-admission-path-comparison-p{1}" -f $stamp, $ServerPort))
}
else {
    $candidate = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
    Ensure-Directory -Path $candidate
}

$comparisonJsonPath = Join-Path $resolvedOutputRoot "public_admission_path_comparison.json"
$comparisonMarkdownPath = Join-Path $resolvedOutputRoot "public_admission_path_comparison.md"

$resolvedPublicServerOutputRoot = ""
if (-not [string]::IsNullOrWhiteSpace($PublicServerOutputRoot)) {
    $resolvedPublicServerOutputRoot = if ([System.IO.Path]::IsPathRooted($PublicServerOutputRoot)) { $PublicServerOutputRoot } else { Join-Path $repoRoot $PublicServerOutputRoot }
}

$resolvedPublicStatusJsonPath = ""
if (-not [string]::IsNullOrWhiteSpace($PublicServerStatusJsonPath)) {
    $resolvedPublicStatusJsonPath = if ([System.IO.Path]::IsPathRooted($PublicServerStatusJsonPath)) { $PublicServerStatusJsonPath } else { Join-Path $repoRoot $PublicServerStatusJsonPath }
}
elseif (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}

$publicStatus = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$resolvedServerLogPath = ""
if (-not [string]::IsNullOrWhiteSpace($ServerLogPath)) {
    $resolvedServerLogPath = if ([System.IO.Path]::IsPathRooted($ServerLogPath)) { $ServerLogPath } else { Join-Path $repoRoot $ServerLogPath }
}
elseif ($null -ne $publicStatus) {
    $resolvedServerLogPath = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $publicStatus -Name "artifacts" -Default $null) -Name "hlds_stdout_log" -Default "")
}

$admissionPlan = Get-PublicHldmClientAdmissionPlan -PreferredSteamPath $SteamExePath -PreferredClientPath $ClientExePath -ServerAddress $ServerAddress -ServerPort $ServerPort
$pathOrder = if (@($PreferredPaths).Count -gt 0) { Normalize-PreferredPaths -Values $PreferredPaths } else { @("steam-native-applaunch", "steam-connect-uri", "direct-hl-exe-connect") }
$seenPaths = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
$effectivePaths = New-Object System.Collections.Generic.List[string]
foreach ($pathId in @($pathOrder)) {
    if ($seenPaths.Add($pathId)) {
        $effectivePaths.Add($pathId) | Out-Null
    }
}

$launchScriptPath = Join-Path $PSScriptRoot "launch_public_hldm_client.ps1"
$diagnoseScriptPath = Join-Path $PSScriptRoot "diagnose_public_client_admission.ps1"
$pathResults = New-Object System.Collections.Generic.List[object]
$bestResult = $null
$bestScore = -1

foreach ($pathId in @($effectivePaths.ToArray())) {
    $pathAvailable = Get-PathAvailability -PathId $pathId -AdmissionPlan $admissionPlan
    $attemptOutputRoot = Ensure-Directory -Path (Join-Path $resolvedOutputRoot ("attempt_{0}" -f ($pathId -replace "[^A-Za-z0-9._-]", "_")))

    if (-not $pathAvailable) {
        $result = [pscustomobject]@{
            path_id = $pathId
            path_available = $false
            command_text = ""
            launcher_process_started = $false
            client_process_started = $false
            steam_admission_succeeded = $false
            server_connect_seen = $false
            entered_the_game_seen = $false
            authoritative_human_seen = $false
            narrowest_failure_stage = "path-unavailable"
            explanation = "This public admission path was not available on this machine."
            artifacts = [ordered]@{
                attempt_root = $attemptOutputRoot
            }
        }
        $pathResults.Add($result) | Out-Null
        continue
    }

    $launchParams = @{
        ServerAddress = $ServerAddress
        ServerPort = $ServerPort
        OutputRoot = $attemptOutputRoot
        AdmissionWaitSeconds = $AdmissionWaitSeconds
        StatusPollSeconds = $StatusPollSeconds
    }
    if (-not [string]::IsNullOrWhiteSpace($SteamExePath)) {
        $launchParams["SteamExePath"] = $SteamExePath
    }
    if (-not [string]::IsNullOrWhiteSpace($ClientExePath)) {
        $launchParams["ClientExePath"] = $ClientExePath
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
        $launchParams["PublicServerOutputRoot"] = $resolvedPublicServerOutputRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
        $launchParams["PublicServerStatusJsonPath"] = $resolvedPublicStatusJsonPath
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedServerLogPath)) {
        $launchParams["ServerLogPath"] = $resolvedServerLogPath
    }
    if ($DryRun) {
        $launchParams["DryRun"] = $true
    }

    switch ($pathId) {
        "steam-native-applaunch" { $launchParams["UseSteamLaunchPath"] = $true }
        "steam-connect-uri" { $launchParams["UseSteamUriLaunchPath"] = $true }
        "direct-hl-exe-connect" { $launchParams["UseDirectClientLaunchPath"] = $true }
    }

    & $launchScriptPath @launchParams | Out-Null
    $attemptJsonPath = Join-Path $attemptOutputRoot "public_client_admission_attempt.json"
    $attempt = Read-JsonFile -Path $attemptJsonPath

    $diagnosis = $null
    $diagnosisJsonPath = Join-Path $attemptOutputRoot "public_client_admission_diagnosis.json"
    if (-not $DryRun -and $null -ne $attempt) {
        & $diagnoseScriptPath -AttemptJsonPath $attemptJsonPath -OutputRoot $attemptOutputRoot | Out-Null
        $diagnosis = Read-JsonFile -Path $diagnosisJsonPath
    }

    $clientProcessStarted = $false
    $launcherProcessStarted = $false
    $serverConnectSeen = $false
    $enteredGameSeen = $false
    $authoritativeHumanSeen = $false
    $commandText = ""
    $failureStage = if ($DryRun) { "dry-run-not-executed" } else { "inconclusive-manual-review" }
    $explanation = if ($DryRun) { "Recorded the resolved launch shape without executing the admission path." } else { "No diagnosis output was produced." }
    $steamAdmissionSucceeded = $false

    if ($null -ne $attempt) {
        $launcherProcessStarted = [bool](Get-ObjectPropertyValue -Object $attempt -Name "launcher_process_started" -Default $false)
        $clientProcessStarted = $launcherProcessStarted -or @((Get-ObjectPropertyValue -Object $attempt -Name "launched_hl_process_ids" -Default @())).Count -gt 0
        $serverConnectSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_connect_seen" -Default $false)
        $enteredGameSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "server_entered_game_seen" -Default $false)
        $authoritativeHumanSeen = [bool](Get-ObjectPropertyValue -Object $attempt -Name "authoritative_human_seen" -Default $false)
        $commandText = [string](Get-ObjectPropertyValue -Object $attempt -Name "command_text" -Default "")
    }
    if ($null -ne $diagnosis) {
        $failureStage = [string](Get-ObjectPropertyValue -Object $diagnosis -Name "stage_verdict" -Default $failureStage)
        $explanation = [string](Get-ObjectPropertyValue -Object $diagnosis -Name "explanation" -Default $explanation)
    }
    $steamAdmissionSucceeded = ($pathId -ne "direct-hl-exe-connect") -and ($serverConnectSeen -or $enteredGameSeen -or $authoritativeHumanSeen)

    $result = [pscustomobject]@{
        path_id = $pathId
        path_available = $true
        command_text = $commandText
        launcher_process_started = $launcherProcessStarted
        client_process_started = $clientProcessStarted
        steam_admission_succeeded = $steamAdmissionSucceeded
        server_connect_seen = $serverConnectSeen
        entered_the_game_seen = $enteredGameSeen
        authoritative_human_seen = $authoritativeHumanSeen
        narrowest_failure_stage = $failureStage
        explanation = $explanation
        artifacts = [ordered]@{
            attempt_root = $attemptOutputRoot
            public_client_admission_attempt_json = $attemptJsonPath
            public_client_admission_diagnosis_json = if ($DryRun) { "" } else { $diagnosisJsonPath }
        }
    }

    $pathResults.Add($result) | Out-Null

    $score = Get-PathScore -Result $result
    if ($score -gt $bestScore) {
        $bestScore = $score
        $bestResult = $result
    }
}

$comparisonVerdict = ""
$comparisonExplanation = ""
if ($null -ne $bestResult -and [bool]$bestResult.authoritative_human_seen) {
    $comparisonVerdict = "public-admission-path-succeeded"
    $comparisonExplanation = "At least one public admission path crossed the authoritative human-admission boundary."
}
elseif ($null -ne $bestResult -and [bool]$bestResult.entered_the_game_seen) {
    $comparisonVerdict = "public-admission-reaches-entered-game"
    $comparisonExplanation = "The best public admission path reached entered-the-game, but authoritative human admission still was not preserved in the compared outputs."
}
elseif ($null -ne $bestResult -and [bool]$bestResult.server_connect_seen) {
    $comparisonVerdict = "public-admission-reaches-server-connect-only"
    $comparisonExplanation = "The best public admission path reached server connect, but it still did not clear entered-the-game."
}
elseif ($null -ne $bestResult -and [bool]$bestResult.client_process_started) {
    $comparisonVerdict = "public-admission-client-starts-but-never-connects"
    $comparisonExplanation = "At least one path started a local client process, but none reached server-side connect."
}
else {
    $comparisonVerdict = "public-admission-paths-still-blocked-before-server-connect"
    $comparisonExplanation = "None of the compared public admission paths reached server-side connect."
}

$comparison = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    server_address = $ServerAddress
    server_port = $ServerPort
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    server_log_path = $resolvedServerLogPath
    dry_run = [bool]$DryRun
    comparison_verdict = $comparisonVerdict
    explanation = $comparisonExplanation
    best_path = if ($null -ne $bestResult) { [string]$bestResult.path_id } else { "" }
    best_path_score = $bestScore
    path_results = @($pathResults.ToArray())
    artifacts = [ordered]@{
        public_admission_path_comparison_json = $comparisonJsonPath
        public_admission_path_comparison_markdown = $comparisonMarkdownPath
    }
}

Write-JsonFile -Path $comparisonJsonPath -Value $comparison
$comparisonForMarkdown = Read-JsonFile -Path $comparisonJsonPath
Write-TextFile -Path $comparisonMarkdownPath -Value (Get-ComparisonMarkdown -Comparison $comparisonForMarkdown)

Write-Host "Public admission path comparison:"
Write-Host "  Verdict: $comparisonVerdict"
Write-Host "  Explanation: $comparisonExplanation"
Write-Host "  Best path: $($comparison.best_path)"
Write-Host "  Comparison JSON: $comparisonJsonPath"
Write-Host "  Comparison Markdown: $comparisonMarkdownPath"
