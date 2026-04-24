[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ServerAddress = "127.0.0.1",
    [string]$AdvertisedAddress = "",
    [int]$Port = 27015,
    [string]$LabRoot = "",
    [string]$HldsExePath = "",
    [string]$PublicServerOutputRoot = "",
    [string]$PublicServerStatusJsonPath = "",
    [string]$OutputRoot = ""
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
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 16
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

function Get-LocalIPv4Addresses {
    $items = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -and $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)' } | Sort-Object InterfaceMetric, SkipAsSource)) {
            $items.Add([ordered]@{
                interface_alias = [string]$address.InterfaceAlias
                ip_address = [string]$address.IPAddress
                prefix_length = [int]$address.PrefixLength
            }) | Out-Null
        }
    }
    catch {
        foreach ($address in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
            if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ($address.IPAddressToString -match '^(127\.|169\.254\.|0\.)') { continue }
            $items.Add([ordered]@{ interface_alias = ""; ip_address = [string]$address.IPAddressToString; prefix_length = 0 }) | Out-Null
        }
    }
    return @($items.ToArray())
}

function Get-HldsProcesses {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name "hlds" -ErrorAction SilentlyContinue | Sort-Object Id)) {
        $path = ""
        $startTime = ""
        try { $path = [string]$process.Path } catch { $path = "" }
        try { $startTime = $process.StartTime.ToUniversalTime().ToString("o") } catch { $startTime = "" }
        $items.Add([ordered]@{ pid = [int]$process.Id; path = $path; start_time_utc = $startTime }) | Out-Null
    }
    return @($items.ToArray())
}

function Get-UdpEndpoints {
    param([int]$Port)
    $items = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($endpoint in @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop | Sort-Object LocalAddress, OwningProcess)) {
            $items.Add([ordered]@{
                local_address = [string]$endpoint.LocalAddress
                local_port = [int]$endpoint.LocalPort
                owning_process_id = [int]$endpoint.OwningProcess
            }) | Out-Null
        }
    }
    catch {
    }
    return @($items.ToArray())
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

function Get-FirewallRuleSnapshot {
    param([int]$Port, [string]$ResolvedHldsExePath)
    $rulesByName = @{}
    $matchingAllow = $false
    $queryError = ""
    function Add-FirewallRuleEntry {
        param([object]$Rule)
        if ($null -eq $Rule) { return }
        $key = [string]$Rule.Name
        if ([string]::IsNullOrWhiteSpace($key)) { $key = [string]$Rule.DisplayName }
        if ($rulesByName.ContainsKey($key)) { return }

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
        $isMatch = $enabled -and $allow -and $portMatches -and $programMatches
        if ($isMatch) { $script:matchingAllowForSnapshot = $true }
        $rulesByName[$key] = [ordered]@{
            display_name = [string]$Rule.DisplayName
            enabled = $enabled
            direction = [string]$Rule.Direction
            action = [string]$Rule.Action
            profile = [string]$Rule.Profile
            protocol = ($protocols -join ",")
            local_port = ($ports -join ",")
            program = ($programs -join ",")
            port_matches = $portMatches
            program_matches_hlds = $programMatches
            matching_allow_rule = $isMatch
        }
    }

    $script:matchingAllowForSnapshot = $false
    try {
        foreach ($filter in @(Get-NetFirewallPortFilter -ErrorAction Stop | Where-Object { (Test-ProtocolCoversUdp -Protocol $_.Protocol) -and (Test-PortSpecCoversPort -LocalPort $_.LocalPort -Port $Port) })) {
            foreach ($rule in @(Get-NetFirewallRule -AssociatedNetFirewallPortFilter $filter -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq "Inbound" })) {
                Add-FirewallRuleEntry -Rule $rule
            }
        }

        foreach ($filter in @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Program) -match 'hlds\.exe$' -or ((-not [string]::IsNullOrWhiteSpace($ResolvedHldsExePath)) -and ([string]$_.Program).Equals($ResolvedHldsExePath, [System.StringComparison]::OrdinalIgnoreCase)) })) {
            foreach ($rule in @(Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $filter -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq "Inbound" })) {
                Add-FirewallRuleEntry -Rule $rule
            }
        }

        foreach ($rule in @(Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue | Where-Object { ([string]$_.DisplayName) -match '(?i)hlds|half-life|half life|goldsrc|hldm|jk_botti|crossfire' })) {
            Add-FirewallRuleEntry -Rule $rule
        }
    }
    catch {
        $queryError = $_.Exception.Message
    }
    $matchingAllow = $script:matchingAllowForSnapshot
    return [ordered]@{
        query_successful = [string]::IsNullOrWhiteSpace($queryError)
        query_error = $queryError
        matching_allow_rule_exists = $matchingAllow
        relevant_rules = @($rulesByName.Values | Sort-Object display_name)
    }
}

function Get-FirewallProfiles {
    $items = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($profile in @(Get-NetFirewallProfile -ErrorAction Stop | Sort-Object Name)) {
            $items.Add([ordered]@{
                name = [string]$profile.Name
                enabled = [bool]$profile.Enabled
                default_inbound_action = [string]$profile.DefaultInboundAction
                default_outbound_action = [string]$profile.DefaultOutboundAction
            }) | Out-Null
        }
    }
    catch {
    }
    return @($items.ToArray())
}

function Get-Markdown {
    param([object]$Report)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# Public Network Exposure Preflight",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Verdict: $($Report.verdict)",
        "- Readiness classification: $($Report.readiness_classification)",
        "- Explanation: $($Report.explanation)",
        "- Port: $($Report.port)",
        "- Protocol: $($Report.protocol)",
        "- Advertised address: $($Report.advertised_address)",
        "- External join target: $($Report.external_join_target)",
        "- HLDS path considered: $($Report.hlds_exe_path)",
        "- Public server process detected: $($Report.public_server_process_detected)",
        "- UDP listener observed locally: $($Report.udp_listener_observed_locally)",
        "- Public status/RCON local evidence: $($Report.local_authoritative_status_usable)",
        "- Matching firewall allow rule exists: $($Report.firewall.matching_allow_rule_exists)",
        "- Internet reachability proven: $($Report.internet_reachability_proven)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Local LAN IP Candidates") | Out-Null
    foreach ($address in @($Report.local_ipv4_addresses)) {
        $lines.Add(("- {0} {1}/{2}" -f $address.interface_alias, $address.ip_address, $address.prefix_length).Trim()) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Relevant Firewall Rules") | Out-Null
    if (@($Report.firewall.relevant_rules).Count -eq 0) {
        $lines.Add("- No relevant inbound firewall rules were found or firewall rule enumeration was unavailable.") | Out-Null
    }
    foreach ($rule in @($Report.firewall.relevant_rules)) {
        $lines.Add("- $($rule.display_name): enabled=$($rule.enabled), action=$($rule.action), protocol=$($rule.protocol), port=$($rule.local_port), program=$($rule.program), matching_allow=$($rule.matching_allow_rule)") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Warnings") | Out-Null
    foreach ($warning in @($Report.warnings)) {
        $lines.Add("- $warning") | Out-Null
    }

    return ($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path $resolvedLabRoot ("logs\public_server\network_exposure_preflights\{0}-public-network-exposure-p{1}" -f $stamp, $Port))
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

$resolvedHldsExePath = Resolve-RepoPathMaybe -Path $HldsExePath
if ([string]::IsNullOrWhiteSpace($resolvedHldsExePath)) {
    $candidate = Join-Path $resolvedHldsRoot "hlds.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $resolvedHldsExePath = (Resolve-Path -LiteralPath $candidate).Path
    }
}

$statusPayload = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$statusAgeSeconds = $null
if (-not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and (Test-Path -LiteralPath $resolvedPublicStatusJsonPath -PathType Leaf)) {
    $statusAgeSeconds = [Math]::Round(((Get-Date).ToUniversalTime() - [System.IO.File]::GetLastWriteTimeUtc($resolvedPublicStatusJsonPath)).TotalSeconds, 2)
}

$statusReportsRconSuccess = $false
$serverReady = $false
$statusServerPid = 0
if ($null -ne $statusPayload) {
    $statusReportsRconSuccess = [bool](Get-ObjectPropertyValue -Object $statusPayload -Name "last_query_successful" -Default $false)
    $serverReady = [bool](Get-ObjectPropertyValue -Object $statusPayload -Name "server_ready" -Default $false)
    $statusServerPid = [int](Get-ObjectPropertyValue -Object $statusPayload -Name "server_pid" -Default 0)
}

$hldsProcesses = @(Get-HldsProcesses)
if ([string]::IsNullOrWhiteSpace($resolvedHldsExePath)) {
    $firstProcessWithPath = @($hldsProcesses | Where-Object { -not [string]::IsNullOrWhiteSpace($_.path) } | Select-Object -First 1)
    if ($firstProcessWithPath.Count -gt 0) {
        $resolvedHldsExePath = [string]$firstProcessWithPath[0].path
    }
}

$udpEndpoints = @(Get-UdpEndpoints -Port $Port)
$matchingHldsProcesses = @($hldsProcesses | Where-Object {
    (($statusServerPid -gt 0) -and ([int]$_.pid -eq $statusServerPid)) -or
    ((-not [string]::IsNullOrWhiteSpace($resolvedHldsExePath)) -and (-not [string]::IsNullOrWhiteSpace([string]$_.path)) -and ([string]$_.path).Equals($resolvedHldsExePath, [System.StringComparison]::OrdinalIgnoreCase))
})
$localAddresses = @(Get-LocalIPv4Addresses)
$firewall = Get-FirewallRuleSnapshot -Port $Port -ResolvedHldsExePath $resolvedHldsExePath
$firewallProfiles = @(Get-FirewallProfiles)
$joinInfo = Get-HldsJoinInfo -ServerHost $ServerAddress -Port $Port
$externalJoinTarget = if (-not [string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
    if ($AdvertisedAddress -match ':\d+$') { $AdvertisedAddress.Trim() } else { "{0}:{1}" -f $AdvertisedAddress.Trim(), $Port }
}
elseif (-not [string]::IsNullOrWhiteSpace([string]$joinInfo.LanAddress)) {
    [string]$joinInfo.LanAddress
}
else {
    [string]$joinInfo.LoopbackAddress
}

$freshStatus = ($null -ne $statusAgeSeconds -and $statusAgeSeconds -le 45)
$publicServerProcessDetected = @($matchingHldsProcesses).Count -gt 0
$udpListenerObserved = @($udpEndpoints).Count -gt 0
$localAuthoritativeStatusUsable = $statusReportsRconSuccess -and $serverReady -and ($freshStatus -or $publicServerProcessDetected)

$warnings = New-Object System.Collections.Generic.List[string]
if (-not $localAuthoritativeStatusUsable) {
    $warnings.Add("Fresh local public status/RCON evidence was not available. Start or attach to public mode before treating exposure as ready.") | Out-Null
}
if (-not [bool]$firewall.matching_allow_rule_exists) {
    $warnings.Add("No matching enabled inbound Windows Firewall allow rule was found for UDP $Port / hlds.exe. Use configure_public_hlds_firewall.ps1 in dry-run first, then apply only if appropriate.") | Out-Null
}
if (-not [bool]$firewall.query_successful) {
    $warnings.Add("Windows Firewall rule enumeration did not complete: $($firewall.query_error)") | Out-Null
}
if ([string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
    $warnings.Add("No advertised address was supplied; LAN candidates are listed, but the helper cannot know what address an external tester should use.") | Out-Null
}
$warnings.Add("This is a local-only preflight. It cannot prove router NAT, ISP filtering, remote-client routing, or Internet reachability without an actual external check.") | Out-Null

$verdict = "public-network-exposure-inconclusive-local-only"
$explanation = "Local checks were collected, but Internet reachability was not externally proven."
if (-not [bool]$firewall.query_successful) {
    $verdict = "public-network-exposure-firewall-query-blocked"
    $explanation = "Local public status/RCON evidence was collected, but Windows Firewall rule enumeration was blocked or incomplete: $($firewall.query_error)"
}
elseif ($localAuthoritativeStatusUsable -and [bool]$firewall.matching_allow_rule_exists) {
    $verdict = "public-network-exposure-local-prereqs-ready"
    $explanation = "Local public status/RCON is usable and an enabled inbound firewall allow rule appears to cover UDP $Port / hlds.exe. External Internet reachability still requires NAT/router/remote-client proof."
}
elseif ($localAuthoritativeStatusUsable -and -not [bool]$firewall.matching_allow_rule_exists) {
    $verdict = "public-network-exposure-firewall-allow-not-found"
    $explanation = "The public server is locally queryable, but no matching enabled inbound firewall allow rule was found for UDP $Port / hlds.exe."
}
elseif (-not $localAuthoritativeStatusUsable -and [bool]$firewall.matching_allow_rule_exists) {
    $verdict = "public-network-exposure-server-not-confirmed"
    $explanation = "A matching firewall allow rule appears present, but local public server status/RCON was not confirmed."
}

$readinessClassification = "blocked"
if ($localAuthoritativeStatusUsable -and $udpListenerObserved -and [bool]$firewall.matching_allow_rule_exists -and -not [string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
    $readinessClassification = "ready-for-external-test"
}
elseif ($localAuthoritativeStatusUsable -and $udpListenerObserved) {
    $readinessClassification = "ready-with-warnings"
}

$jsonPath = Join-Path $resolvedOutputRoot "public_network_exposure_preflight.json"
$markdownPath = Join-Path $resolvedOutputRoot "public_network_exposure_preflight.md"
$report = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    verdict = $verdict
    readiness_classification = $readinessClassification
    explanation = $explanation
    port = $Port
    protocol = "UDP"
    server_address = $ServerAddress
    advertised_address = $AdvertisedAddress
    external_join_target = $externalJoinTarget
    external_connect_command = "connect $externalJoinTarget"
    lan_join_target = [string]$joinInfo.LanAddress
    lan_connect_command = [string]$joinInfo.LanConsoleCommand
    loopback_join_target = [string]$joinInfo.LoopbackAddress
    hlds_exe_path = $resolvedHldsExePath
    lab_root = $resolvedLabRoot
    output_root = $resolvedOutputRoot
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_server_status_age_seconds = $statusAgeSeconds
    public_server_process_detected = $publicServerProcessDetected
    hlds_processes = @($hldsProcesses)
    matching_hlds_processes = @($matchingHldsProcesses)
    udp_listener_observed_locally = $udpListenerObserved
    udp_listener_evidence = @($udpEndpoints)
    udp_endpoints = @($udpEndpoints)
    local_authoritative_status_usable = $localAuthoritativeStatusUsable
    local_rcon_status_result = if ($localAuthoritativeStatusUsable) { "success" } elseif ($statusReportsRconSuccess) { "partial" } else { "not-confirmed" }
    status_artifact_reports_rcon_success = $statusReportsRconSuccess
    status_artifact_reports_server_ready = $serverReady
    local_ipv4_addresses = @($localAddresses)
    firewall_profiles = @($firewallProfiles)
    firewall = $firewall
    internet_reachability_proven = $false
    nat_router_isp_caveat = "Local checks cannot prove router NAT/port forwarding, ISP inbound UDP filtering, or real Internet reachability without an external client."
    cannot_be_proven_locally = @(
        "Router/NAT port forwarding",
        "ISP inbound UDP filtering",
        "Remote-client path to the advertised address",
        "Steam/GoldSrc master-server visibility",
        "Whether a real external client can complete Half-Life admission"
    )
    warnings = @($warnings.ToArray())
    artifacts = [ordered]@{
        public_network_exposure_preflight_json = $jsonPath
        public_network_exposure_preflight_markdown = $markdownPath
    }
}

Write-JsonFile -Path $jsonPath -Value $report
$markdownReport = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $markdownPath -Value (Get-Markdown -Report $markdownReport)

Write-Host "Public network exposure preflight:"
Write-Host "  Verdict: $verdict"
Write-Host "  Readiness: $readinessClassification"
Write-Host "  JSON: $jsonPath"
Write-Host "  Markdown: $markdownPath"
