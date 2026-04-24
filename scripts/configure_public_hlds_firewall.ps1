[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [string]$HldsExePath = "",
    [string]$RuleName = "",
    [string]$OutputRoot = "",
    [switch]$DryRun,
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

function Format-CommandArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Test-PortSpecCoversPort {
    param([object]$LocalPort, [int]$Port)
    if ($null -eq $LocalPort) { return $true }
    foreach ($entry in @($LocalPort)) {
        $text = ([string]$entry).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "Any" -or $text -eq "*") { return $true }
        foreach ($part in @($text -split ",")) {
            $part = $part.Trim()
            if ($part -eq "Any" -or $part -eq "*") { return $true }
            if ($part -match '^(\d+)-(\d+)$') {
                if ($Port -ge [int]$matches[1] -and $Port -le [int]$matches[2]) { return $true }
            }
            elseif ($part -match '^\d+$' -and [int]$part -eq $Port) {
                return $true
            }
        }
    }
    return $false
}

function Test-ProtocolCoversUdp {
    param([object]$Protocol)
    if ($null -eq $Protocol) { return $true }
    foreach ($entry in @($Protocol)) {
        $text = ([string]$entry).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "Any" -or $text -eq "*" -or $text -eq "UDP" -or $text -eq "17") {
            return $true
        }
    }
    return $false
}

function Test-ProgramCoversHlds {
    param([object[]]$Programs, [string]$ResolvedHldsExePath)
    if (@($Programs).Count -eq 0) { return $true }
    foreach ($program in @($Programs)) {
        $text = ([string]$program).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "Any" -or $text -eq "*") { return $true }
        if ($text -match 'hlds\.exe$') { return $true }
        if (-not [string]::IsNullOrWhiteSpace($ResolvedHldsExePath) -and $text.Equals($ResolvedHldsExePath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Convert-FirewallRuleToSnapshot {
    param([object]$Rule, [int]$Port, [string]$ResolvedHldsExePath)
    if ($null -eq $Rule) { return $null }
    $portFilters = @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $Rule -ErrorAction SilentlyContinue)
    $appFilters = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $Rule -ErrorAction SilentlyContinue)
    $programs = @($appFilters | ForEach-Object { [string]$_.Program } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $ports = @($portFilters | ForEach-Object { [string]$_.LocalPort } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $protocols = @($portFilters | ForEach-Object { [string]$_.Protocol } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $portMatches = $false
    if (@($portFilters).Count -eq 0) {
        $portMatches = $true
    }
    else {
        foreach ($filter in $portFilters) {
            if ((Test-ProtocolCoversUdp -Protocol $filter.Protocol) -and (Test-PortSpecCoversPort -LocalPort $filter.LocalPort -Port $Port)) {
                $portMatches = $true
                break
            }
        }
    }

    $programMatches = Test-ProgramCoversHlds -Programs $programs -ResolvedHldsExePath $ResolvedHldsExePath
    $enabled = ([string]$Rule.Enabled) -eq "True"
    $allow = ([string]$Rule.Action) -eq "Allow"

    return [ordered]@{
        display_name = [string]$Rule.DisplayName
        name = [string]$Rule.Name
        enabled = $enabled
        direction = [string]$Rule.Direction
        action = [string]$Rule.Action
        profile = [string]$Rule.Profile
        protocol = ($protocols -join ",")
        local_port = ($ports -join ",")
        program = ($programs -join ",")
        port_matches = $portMatches
        program_matches_hlds = $programMatches
        matching_allow_rule = $enabled -and $allow -and $portMatches -and $programMatches
    }
}

function Get-FirewallInspection {
    param([int]$Port, [string]$RuleName, [string]$ResolvedHldsExePath, [bool]$CanInspect)
    if (-not $CanInspect) {
        return [ordered]@{
            attempted = $false
            query_successful = $false
            query_error = "Firewall inspection requires an elevated PowerShell session."
            matching_allow_rule_exists = $false
            exact_rule_found = $false
            exact_rule = $null
            relevant_rules = @()
        }
    }

    $rulesByName = @{}
    $queryError = ""
    $exactRule = $null

    try {
        $exactRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $exactRule) {
            $snapshot = Convert-FirewallRuleToSnapshot -Rule $exactRule -Port $Port -ResolvedHldsExePath $ResolvedHldsExePath
            if ($null -ne $snapshot) { $rulesByName[[string]$snapshot.name] = $snapshot }
        }

        foreach ($filter in @(Get-NetFirewallPortFilter -ErrorAction Stop | Where-Object { (Test-ProtocolCoversUdp -Protocol $_.Protocol) -and (Test-PortSpecCoversPort -LocalPort $_.LocalPort -Port $Port) })) {
            foreach ($rule in @(Get-NetFirewallRule -AssociatedNetFirewallPortFilter $filter -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq "Inbound" })) {
                $snapshot = Convert-FirewallRuleToSnapshot -Rule $rule -Port $Port -ResolvedHldsExePath $ResolvedHldsExePath
                if ($null -ne $snapshot) { $rulesByName[[string]$snapshot.name] = $snapshot }
            }
        }

        foreach ($filter in @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Program) -match 'hlds\.exe$' -or ((-not [string]::IsNullOrWhiteSpace($ResolvedHldsExePath)) -and ([string]$_.Program).Equals($ResolvedHldsExePath, [System.StringComparison]::OrdinalIgnoreCase)) })) {
            foreach ($rule in @(Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $filter -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq "Inbound" })) {
                $snapshot = Convert-FirewallRuleToSnapshot -Rule $rule -Port $Port -ResolvedHldsExePath $ResolvedHldsExePath
                if ($null -ne $snapshot) { $rulesByName[[string]$snapshot.name] = $snapshot }
            }
        }
    }
    catch {
        $queryError = $_.Exception.Message
    }

    $relevantRules = @($rulesByName.Values | Sort-Object display_name)
    $matchingAllow = @($relevantRules | Where-Object { [bool]$_.matching_allow_rule }).Count -gt 0
    $exactSnapshot = $null
    if ($null -ne $exactRule) {
        $exactSnapshot = Convert-FirewallRuleToSnapshot -Rule $exactRule -Port $Port -ResolvedHldsExePath $ResolvedHldsExePath
    }

    return [ordered]@{
        attempted = $true
        query_successful = [string]::IsNullOrWhiteSpace($queryError)
        query_error = $queryError
        matching_allow_rule_exists = $matchingAllow
        exact_rule_found = $null -ne $exactRule
        exact_rule = $exactSnapshot
        relevant_rules = @($relevantRules)
    }
}

function Get-CheckMarkdown {
    param([object]$Report)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# Public HLDS Firewall Check",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Verdict: $($Report.verdict)",
        "- Explanation: $($Report.explanation)",
        "- Running as admin: $($Report.running_as_admin)",
        "- Inspection attempted: $($Report.firewall_inspection_attempted)",
        "- Inspection successful: $($Report.firewall_query_successful)",
        "- Matching allow rule exists: $($Report.matching_allow_rule_exists)",
        "- Apply requested: $($Report.apply_requested)",
        "- Apply attempted: $($Report.apply_attempted)",
        "- Apply succeeded: $($Report.apply_succeeded)",
        "- Rule name: $($Report.rule_name)",
        "- Protocol: $($Report.protocol)",
        "- Port: $($Report.port)",
        "- HLDS path: $($Report.hlds_exe_path)",
        "- Elevated apply command: $($Report.elevated_apply_command)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Relevant Rules") | Out-Null
    if (@($Report.relevant_rules).Count -eq 0) {
        $lines.Add("- No relevant rules were verified.") | Out-Null
    }
    foreach ($rule in @($Report.relevant_rules)) {
        $lines.Add("- $($rule.display_name): enabled=$($rule.enabled), action=$($rule.action), protocol=$($rule.protocol), port=$($rule.local_port), program=$($rule.program), matching_allow=$($rule.matching_allow_rule)") | Out-Null
    }

    if ($Report.warning) {
        $lines.Add("") | Out-Null
        $lines.Add("## Warning") | Out-Null
        $lines.Add("- $($Report.warning)") | Out-Null
    }

    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

if ($Apply.IsPresent -and $DryRun.IsPresent) {
    throw "Use either -Apply or -DryRun, not both."
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

$scriptPath = Join-Path $PSScriptRoot "configure_public_hlds_firewall.ps1"
$elevatedApplyCommand = ("powershell -NoProfile -ExecutionPolicy Bypass -File {0} -Port {1} -RuleName {2} -HldsExePath {3} -Apply" -f `
    (Format-CommandArgument -Value $scriptPath), `
    $Port, `
    (Format-CommandArgument -Value $RuleName), `
    (Format-CommandArgument -Value $resolvedHldsExePath))

$runningAsAdmin = Test-IsAdministrator
$canInspectFirewall = $runningAsAdmin
$applyAttempted = $false
$applySucceeded = $false
$actionTaken = if ($Apply.IsPresent) { "apply-requested" } else { "dry-run" }
$warning = ""

$beforeInspection = Get-FirewallInspection -Port $Port -RuleName $RuleName -ResolvedHldsExePath $resolvedHldsExePath -CanInspect:$canInspectFirewall

if ($Apply.IsPresent) {
    if (-not $runningAsAdmin) {
        $actionTaken = "apply-blocked-not-elevated"
        $warning = "Apply was requested, but this PowerShell session is not elevated. Re-run the elevated apply command."
    }
    else {
        $applyAttempted = $true
        $newRuleArgs = @{
            DisplayName = $RuleName
            Direction = "Inbound"
            Action = "Allow"
            Protocol = "UDP"
            LocalPort = $Port
            Profile = "Any"
            Enabled = "True"
        }
        $hasProgramScope = -not [string]::IsNullOrWhiteSpace($resolvedHldsExePath) -and (Test-Path -LiteralPath $resolvedHldsExePath -PathType Leaf)
        if ($hasProgramScope) {
            $newRuleArgs.Program = $resolvedHldsExePath
        }
        else {
            $warning = "No hlds.exe path was found, so the applied rule would be port-scoped only. Prefer passing -HldsExePath for a narrower rule."
        }

        try {
            $existingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $existingRule) {
                New-NetFirewallRule @newRuleArgs | Out-Null
                $actionTaken = "created-firewall-allow-rule"
            }
            else {
                Set-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Profile Any -Enabled True | Out-Null
                $updatedRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction Stop | Select-Object -First 1
                Get-NetFirewallPortFilter -AssociatedNetFirewallRule $updatedRule -ErrorAction Stop | Set-NetFirewallPortFilter -Protocol UDP -LocalPort $Port | Out-Null
                if ($hasProgramScope) {
                    Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $updatedRule -ErrorAction Stop | Set-NetFirewallApplicationFilter -Program $resolvedHldsExePath | Out-Null
                }
                $actionTaken = "updated-existing-firewall-allow-rule"
            }
            $applySucceeded = $true
        }
        catch {
            $actionTaken = "apply-failed"
            $warning = "Firewall apply failed: $($_.Exception.Message)"
        }
    }
}

$afterInspection = Get-FirewallInspection -Port $Port -RuleName $RuleName -ResolvedHldsExePath $resolvedHldsExePath -CanInspect:$canInspectFirewall
$matchingAllow = [bool]$afterInspection.matching_allow_rule_exists

$verdict = "firewall-check-not-verified-not-elevated"
$explanation = "This session is not elevated, so the helper did not verify Windows Firewall rules. Use the elevated apply command to inspect or apply the narrow UDP rule."
if ($runningAsAdmin -and -not [bool]$afterInspection.query_successful) {
    $verdict = "firewall-check-query-failed"
    $explanation = "The helper was elevated but could not complete firewall inspection: $($afterInspection.query_error)"
}
elseif ($runningAsAdmin -and $matchingAllow -and -not $Apply.IsPresent) {
    $verdict = "firewall-rule-verified"
    $explanation = "An enabled inbound allow rule covers UDP $Port for hlds.exe or the selected port."
}
elseif ($runningAsAdmin -and $matchingAllow -and $Apply.IsPresent -and $applySucceeded) {
    $verdict = "firewall-rule-applied-and-verified"
    $explanation = "The narrow inbound UDP allow rule was applied and verified."
}
elseif ($runningAsAdmin -and -not $matchingAllow -and -not $Apply.IsPresent) {
    $verdict = "firewall-rule-not-found"
    $explanation = "No enabled inbound allow rule was verified for UDP $Port / hlds.exe. Review the dry-run output before applying."
}
elseif ($runningAsAdmin -and $Apply.IsPresent -and -not $applySucceeded) {
    $verdict = "firewall-apply-failed"
    $explanation = "Apply was requested but did not succeed."
}
elseif (-not $runningAsAdmin -and $Apply.IsPresent) {
    $verdict = "firewall-apply-blocked-not-elevated"
    $explanation = "Apply was requested, but this shell is not elevated. No firewall change was made."
}

$jsonPath = Join-Path $resolvedOutputRoot "public_hlds_firewall_check.json"
$markdownPath = Join-Path $resolvedOutputRoot "public_hlds_firewall_check.md"
$legacyJsonPath = Join-Path $resolvedOutputRoot "public_hlds_firewall_rule.json"
$legacyMarkdownPath = Join-Path $resolvedOutputRoot "public_hlds_firewall_rule.md"

$report = [ordered]@{
    schema_version = 2
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    verdict = $verdict
    explanation = $explanation
    running_as_admin = $runningAsAdmin
    dry_run_requested = $DryRun.IsPresent -or -not $Apply.IsPresent
    apply_requested = $Apply.IsPresent
    apply_attempted = $applyAttempted
    apply_succeeded = $applySucceeded
    action_taken = $actionTaken
    rule_name = $RuleName
    port = $Port
    protocol = "UDP"
    hlds_exe_path = $resolvedHldsExePath
    executable_scoped = -not [string]::IsNullOrWhiteSpace($resolvedHldsExePath)
    firewall_inspection_attempted = [bool]$afterInspection.attempted
    firewall_query_successful = [bool]$afterInspection.query_successful
    firewall_query_error = [string]$afterInspection.query_error
    matching_allow_rule_exists = $matchingAllow
    exact_rule_found = [bool]$afterInspection.exact_rule_found
    exact_rule = $afterInspection.exact_rule
    relevant_rules = @($afterInspection.relevant_rules)
    before_inspection = $beforeInspection
    elevated_apply_command = $elevatedApplyCommand
    warning = $warning
    artifacts = [ordered]@{
        public_hlds_firewall_check_json = $jsonPath
        public_hlds_firewall_check_markdown = $markdownPath
        legacy_public_hlds_firewall_rule_json = $legacyJsonPath
        legacy_public_hlds_firewall_rule_markdown = $legacyMarkdownPath
    }
}

Write-JsonFile -Path $jsonPath -Value $report
$markdownReport = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
$markdownText = Get-CheckMarkdown -Report $markdownReport
Write-TextFile -Path $markdownPath -Value $markdownText

# Keep the prompt-77 filenames as compatibility aliases for operators who already have them bookmarked.
Write-JsonFile -Path $legacyJsonPath -Value $report
Write-TextFile -Path $legacyMarkdownPath -Value $markdownText

Write-Host "Public HLDS firewall check:"
Write-Host "  Verdict: $verdict"
Write-Host "  Rule: $RuleName"
Write-Host "  JSON: $jsonPath"
Write-Host "  Markdown: $markdownPath"
if (-not $runningAsAdmin) {
    Write-Host "  Elevated command: $elevatedApplyCommand"
}

if ($Apply.IsPresent -and -not $runningAsAdmin) {
    exit 2
}
if ($Apply.IsPresent -and $runningAsAdmin -and -not $applySucceeded) {
    exit 3
}
