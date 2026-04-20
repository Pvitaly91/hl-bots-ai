[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ClientExePath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [switch]$DryRun,
    [switch]$PrintOnly
)

. (Join-Path $PSScriptRoot "common.ps1")

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Path $Path -Parent
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

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Get-DiscoveryMarkdown {
    param([object]$Report)

    $lines = @(
        "# Local Half-Life Client Discovery",
        "",
        "- Discovery verdict: $($Report.discovery_verdict)",
        "- Client path: $($Report.client_path)",
        "- Launchable for local lane join: $($Report.launchable_for_local_lane_join)",
        "- Explanation: $($Report.explanation)",
        "",
        "## Sources Checked",
        ""
    )

    foreach ($source in @($Report.discovery_sources_checked)) {
        $lines += "- $($source.source_name): kind=$($source.check_kind); exists=$($source.exists); path=$($source.path_checked); details=$($source.details)"
    }

    if ($Report.launch_example_command) {
        $lines += @(
            "",
            "## Launch Example",
            "",
            '```powershell',
            $Report.launch_example_command,
            '```'
        )
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Resolve-NormalizedPathCandidate -Path $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-RegistryRootDefault -LabRoot $resolvedLabRoot) "local_client_discovery")
}
else {
    Ensure-Directory -Path (Resolve-NormalizedPathCandidate -Path $OutputRoot)
}

$jsonPath = Join-Path $resolvedOutputRoot "local_client_discovery.json"
$markdownPath = Join-Path $resolvedOutputRoot "local_client_discovery.md"

$discovery = Get-HalfLifeClientDiscovery -PreferredPath $ClientExePath
$launchExampleCommand = if ($discovery.launchable_for_local_lane_join) {
    "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\join_live_pair_lane.ps1 -Lane Control -UseLatest -ClientExePath {0} -DryRun" -f (Format-ProcessArgumentText -Value $discovery.client_path)
}
else {
    ""
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    discovery_verdict = [string]$discovery.discovery_verdict
    client_path = [string]$discovery.client_path
    launchable_for_local_lane_join = [bool]$discovery.launchable_for_local_lane_join
    explanation = [string]$discovery.explanation
    discovery_sources_checked = @($discovery.discovery_sources_checked)
    launch_example_command = $launchExampleCommand
    output_json_path = $jsonPath
    output_markdown_path = $markdownPath
    discovery_mode = if ($PrintOnly) { "print-only" } elseif ($DryRun) { "dry-run" } else { "default" }
}

Write-JsonFile -Path $jsonPath -Value $report
$reportForMarkdown = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $markdownPath -Value (Get-DiscoveryMarkdown -Report $reportForMarkdown)

Write-Host "Local Half-Life client discovery:"
Write-Host "  Discovery verdict: $($report.discovery_verdict)"
Write-Host "  Client path: $($report.client_path)"
Write-Host "  Launchable for local lane join: $($report.launchable_for_local_lane_join)"
Write-Host "  Explanation: $($report.explanation)"
Write-Host "  Discovery JSON: $jsonPath"
Write-Host "  Discovery Markdown: $markdownPath"
if ($launchExampleCommand) {
    Write-Host "  Join-helper dry-run example: $launchExampleCommand"
}

[pscustomobject]@{
    DiscoveryVerdict = $report.discovery_verdict
    ClientPath = $report.client_path
    LaunchableForLocalLaneJoin = $report.launchable_for_local_lane_join
    LocalClientDiscoveryJsonPath = $jsonPath
    LocalClientDiscoveryMarkdownPath = $markdownPath
}
