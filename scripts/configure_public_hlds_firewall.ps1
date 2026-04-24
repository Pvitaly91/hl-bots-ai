[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [string]$HldsExePath = "",
    [string]$RuleName = "",
    [string]$OutputRoot = "",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$repoRoot = Get-RepoRoot
$promptId = Get-RepoPromptId
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$resolvedHldsRoot = Get-HldsRootDefault -LabRoot $resolvedLabRoot

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Directory -Path $parent | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 12
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

function Resolve-RepoPathMaybe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $repoRoot $Path
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Markdown {
    param([object]$Report)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# Public HLDS Firewall Rule",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Action taken: $($Report.action_taken)",
        "- Apply requested: $($Report.apply_requested)",
        "- Admin: $($Report.running_as_admin)",
        "- Rule name: $($Report.rule_name)",
        "- Port: $($Report.port)",
        "- Protocol: $($Report.protocol)",
        "- HLDS path: $($Report.hlds_exe_path)",
        "- Existing rule found: $($Report.existing_rule_found)",
        "- Command preview: $($Report.command_preview)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }
    if ($Report.warning) {
        $lines.Add("") | Out-Null
        $lines.Add("## Warning") | Out-Null
        $lines.Add("- $($Report.warning)") | Out-Null
    }
    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedLabRoot ("logs\public_server\firewall\{0}-public-hlds-firewall-p{1}" -f $stamp, $Port))
}
else {
    Ensure-Directory -Path (Resolve-RepoPathMaybe -Path $OutputRoot)
}

$resolvedHldsExePath = Resolve-RepoPathMaybe -Path $HldsExePath
if ([string]::IsNullOrWhiteSpace($resolvedHldsExePath)) {
    $candidate = Join-Path $resolvedHldsRoot "hlds.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $resolvedHldsExePath = (Resolve-Path -LiteralPath $candidate).Path
    }
}
if ([string]::IsNullOrWhiteSpace($RuleName)) {
    $RuleName = "HLDM Public Crossfire UDP $Port"
}

$existingRule = $null
try {
    $existingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Select-Object -First 1
}
catch {
    $existingRule = $null
}

$programArg = ""
$warning = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedHldsExePath) -and (Test-Path -LiteralPath $resolvedHldsExePath -PathType Leaf)) {
    $programArg = '-Program "{0}" ' -f $resolvedHldsExePath
}
else {
    $warning = "No hlds.exe path was found, so the proposed rule is port-scoped only. Prefer passing -HldsExePath when applying."
}

$commandPreview = 'New-NetFirewallRule -DisplayName "{0}" -Direction Inbound -Action Allow -Protocol UDP -LocalPort {1} {2}-Profile Any' -f $RuleName, $Port, $programArg
$runningAsAdmin = Test-IsAdministrator
$actionTaken = "dry-run"
$createdRule = $false

if ($Apply.IsPresent) {
    if (-not $runningAsAdmin) {
        $actionTaken = "apply-blocked-not-admin"
        $warning = "Apply was requested, but this PowerShell session is not elevated. Re-run as Administrator to create the firewall rule."
    }
    elseif ($null -ne $existingRule) {
        $actionTaken = "existing-rule-left-unchanged"
    }
    else {
        $newRuleArgs = @{
            DisplayName = $RuleName
            Direction = "Inbound"
            Action = "Allow"
            Protocol = "UDP"
            LocalPort = $Port
            Profile = "Any"
        }
        if (-not [string]::IsNullOrWhiteSpace($programArg)) {
            $newRuleArgs.Program = $resolvedHldsExePath
        }
        New-NetFirewallRule @newRuleArgs | Out-Null
        $createdRule = $true
        $actionTaken = "created-firewall-allow-rule"
    }
}

$jsonPath = Join-Path $resolvedOutputRoot "public_hlds_firewall_rule.json"
$markdownPath = Join-Path $resolvedOutputRoot "public_hlds_firewall_rule.md"
$report = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    apply_requested = $Apply.IsPresent
    running_as_admin = $runningAsAdmin
    action_taken = $actionTaken
    rule_name = $RuleName
    port = $Port
    protocol = "UDP"
    hlds_exe_path = $resolvedHldsExePath
    existing_rule_found = $null -ne $existingRule
    created_rule = $createdRule
    command_preview = $commandPreview
    warning = $warning
    artifacts = [ordered]@{
        public_hlds_firewall_rule_json = $jsonPath
        public_hlds_firewall_rule_markdown = $markdownPath
    }
}

Write-JsonFile -Path $jsonPath -Value $report
$markdownReport = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $markdownPath -Value (Get-Markdown -Report $markdownReport)

Write-Host "Public HLDS firewall helper:"
Write-Host "  Action: $actionTaken"
Write-Host "  Rule: $RuleName"
Write-Host "  JSON: $jsonPath"
Write-Host "  Markdown: $markdownPath"

if ($Apply.IsPresent -and -not $runningAsAdmin) {
    exit 2
}
