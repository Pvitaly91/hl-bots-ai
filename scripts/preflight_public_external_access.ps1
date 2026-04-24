[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ServerAddress = "127.0.0.1",
    [string]$AdvertisedAddress = "",
    [int]$Port = 27015,
    [string]$LabRoot = "",
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

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 14
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

function Get-LocalIPv4Addresses {
    $addresses = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($item in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -and $_.IPAddress -ne "127.0.0.1" })) {
            $addresses.Add([ordered]@{
                interface_alias = [string]$item.InterfaceAlias
                ip_address = [string]$item.IPAddress
                prefix_length = [int]$item.PrefixLength
            }) | Out-Null
        }
    }
    catch {
        foreach ($address in [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())) {
            if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            if ($address.IPAddressToString -eq "127.0.0.1") { continue }
            $addresses.Add([ordered]@{
                interface_alias = ""
                ip_address = [string]$address.IPAddressToString
                prefix_length = 0
            }) | Out-Null
        }
    }
    return @($addresses.ToArray())
}

function Get-HldsProcessSnapshot {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name "hlds" -ErrorAction SilentlyContinue | Sort-Object Id)) {
        $path = ""
        $startTime = ""
        try { $path = [string]$process.Path } catch { $path = "" }
        try { $startTime = $process.StartTime.ToUniversalTime().ToString("o") } catch { $startTime = "" }
        $items.Add([ordered]@{
            pid = [int]$process.Id
            process_name = [string]$process.ProcessName
            path = $path
            start_time_utc = $startTime
        }) | Out-Null
    }
    return @($items.ToArray())
}

function Get-UdpEndpointSnapshot {
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

function Get-FirewallProfileSnapshot {
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

function Get-PreflightMarkdown {
    param([object]$Report)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(
        "# Public External Access Preflight",
        "",
        "- Generated at UTC: $($Report.generated_at_utc)",
        "- Prompt ID: $($Report.prompt_id)",
        "- Verdict: $($Report.verdict)",
        "- Explanation: $($Report.explanation)",
        "- Selected server address: $($Report.server_address)",
        "- Advertised address: $($Report.advertised_address)",
        "- Port: $($Report.port)",
        "- External join target: $($Report.external_join_target)",
        "- Public status JSON: $($Report.public_server_status_json_path)",
        "- Public server process detected: $($Report.public_server_process_detected)",
        "- UDP listener observed locally: $($Report.udp_listener_observed_locally)",
        "- Local authoritative status usable: $($Report.local_authoritative_status_usable)",
        "- Authoritative count source: $($Report.authoritative_count_source)",
        "- NAT warning: $($Report.nat_port_forward_warning)"
    )) {
        $lines.Add([string]$line) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## Local Addresses") | Out-Null
    foreach ($address in @($Report.local_ipv4_addresses)) {
        $lines.Add(("- {0} {1}/{2}" -f $address.interface_alias, $address.ip_address, $address.prefix_length).Trim()) | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("## UDP Endpoints") | Out-Null
    if (@($Report.udp_endpoints).Count -eq 0) {
        $lines.Add("- No UDP listener was detected locally for the selected port.") | Out-Null
    }
    foreach ($endpoint in @($Report.udp_endpoints)) {
        $lines.Add("- $($endpoint.local_address):$($endpoint.local_port) pid=$($endpoint.owning_process_id)") | Out-Null
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
    Ensure-Directory -Path (Join-Path $resolvedLabRoot ("logs\public_server\external_access_preflights\{0}-public-external-access-preflight-p{1}" -f $stamp, $Port))
}
else {
    $candidate = Resolve-RepoPathMaybe -Path $OutputRoot
    Ensure-Directory -Path $candidate
}

$resolvedPublicServerOutputRoot = Resolve-RepoPathMaybe -Path $PublicServerOutputRoot
$resolvedPublicStatusJsonPath = Resolve-RepoPathMaybe -Path $PublicServerStatusJsonPath
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and -not [string]::IsNullOrWhiteSpace($resolvedPublicServerOutputRoot)) {
    $resolvedPublicStatusJsonPath = Join-Path $resolvedPublicServerOutputRoot "public_server_status.json"
}
if ([string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath)) {
    $resolvedPublicStatusJsonPath = Get-LatestPublicServerStatusJsonPath -Port $Port
}

$statusPayload = Read-JsonFile -Path $resolvedPublicStatusJsonPath
$statusWriteTimeUtc = ""
$statusAgeSeconds = $null
if (-not [string]::IsNullOrWhiteSpace($resolvedPublicStatusJsonPath) -and (Test-Path -LiteralPath $resolvedPublicStatusJsonPath -PathType Leaf)) {
    $writeUtc = [System.IO.File]::GetLastWriteTimeUtc($resolvedPublicStatusJsonPath)
    $statusWriteTimeUtc = $writeUtc.ToString("o")
    $statusAgeSeconds = [Math]::Round(((Get-Date).ToUniversalTime() - $writeUtc).TotalSeconds, 2)
}

$localAddresses = @(Get-LocalIPv4Addresses)
$hldsProcesses = @(Get-HldsProcessSnapshot)
$udpEndpoints = @(Get-UdpEndpointSnapshot -Port $Port)
$firewallProfiles = @(Get-FirewallProfileSnapshot)
$joinInfo = Get-HldsJoinInfo -ServerHost $ServerAddress -Port $Port
$externalJoinTarget = if (-not [string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
    if ($AdvertisedAddress -match ':\d+$') { $AdvertisedAddress.Trim() } else { "{0}:{1}" -f $AdvertisedAddress.Trim(), $Port }
}
elseif (-not [string]::IsNullOrWhiteSpace($joinInfo.LanAddress)) {
    [string]$joinInfo.LanAddress
}
else {
    [string]$joinInfo.LoopbackAddress
}

$statusReportsRconSuccess = $false
$serverReady = $false
$statusSource = "none"
if ($null -ne $statusPayload) {
    $statusReportsRconSuccess = [bool](Get-ObjectPropertyValue -Object $statusPayload -Name "last_query_successful" -Default $false)
    $serverReady = [bool](Get-ObjectPropertyValue -Object $statusPayload -Name "server_ready" -Default $false)
    $statusSource = [string](Get-ObjectPropertyValue -Object $statusPayload -Name "human_count_source" -Default "")
}

$freshStatus = ($null -ne $statusAgeSeconds -and $statusAgeSeconds -le 30)
$publicServerProcessDetected = @($hldsProcesses).Count -gt 0
$udpListenerObserved = @($udpEndpoints).Count -gt 0
$localAuthoritativeStatusUsable = $false
if ($statusReportsRconSuccess -and $serverReady -and ($freshStatus -or $publicServerProcessDetected)) {
    $localAuthoritativeStatusUsable = $true
}

$warnings = New-Object System.Collections.Generic.List[string]
if (-not $publicServerProcessDetected) {
    $warnings.Add("No local hlds.exe process is currently visible.") | Out-Null
}
if (-not $udpListenerObserved) {
    $warnings.Add("No local UDP listener was detected on the selected port. This can be normal before the public server starts, but external clients cannot join until HLDS is listening.") | Out-Null
}
if (-not $localAuthoritativeStatusUsable) {
    $warnings.Add("Fresh local GoldSrc status/RCON evidence was not available from public_server_status.json.") | Out-Null
}
if ([string]::IsNullOrWhiteSpace($AdvertisedAddress)) {
    $warnings.Add("No advertised public address was supplied; the helper can list local/LAN targets but cannot prove Internet-side NAT or port-forward reachability from inside this machine.") | Out-Null
}
$warnings.Add("External UDP reachability through NAT, ISP filtering, and router port-forwarding cannot be proven by this local-only preflight.") | Out-Null

$verdict = "public-external-access-inconclusive"
$explanation = "The local preflight produced partial external-access evidence but cannot prove Internet reachability from inside this host."
if ($localAuthoritativeStatusUsable -and $publicServerProcessDetected) {
    $verdict = "public-server-rcon-ready"
    $explanation = "The public server process is visible and the public status artifact reports fresh GoldSrc RCON status."
}
elseif ($null -ne $statusPayload -and $statusReportsRconSuccess) {
    $verdict = "public-server-status-ready"
    $explanation = "A public status artifact reports successful GoldSrc RCON status, but the local process or freshness check did not fully prove current reachability."
}
elseif ($publicServerProcessDetected -or $udpListenerObserved) {
    $verdict = "public-server-process-detected-no-rcon"
    $explanation = "A local HLDS process or UDP listener exists, but the helper did not find usable public status/RCON evidence."
}
elseif ($null -eq $statusPayload) {
    $verdict = "public-server-not-running-locally"
    $explanation = "No local HLDS process and no matching public status artifact were found for this port."
}

$reportJsonPath = Join-Path $resolvedOutputRoot "public_external_access_preflight.json"
$reportMarkdownPath = Join-Path $resolvedOutputRoot "public_external_access_preflight.md"

$report = [ordered]@{
    schema_version = 1
    prompt_id = $promptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    verdict = $verdict
    explanation = $explanation
    server_address = $ServerAddress
    advertised_address = $AdvertisedAddress
    port = $Port
    external_join_target = $externalJoinTarget
    external_connect_command = "connect $externalJoinTarget"
    steam_connect_uri = "steam://connect/$externalJoinTarget"
    lab_root = $resolvedLabRoot
    output_root = $resolvedOutputRoot
    public_server_output_root = $resolvedPublicServerOutputRoot
    public_server_status_json_path = $resolvedPublicStatusJsonPath
    public_server_status_write_time_utc = $statusWriteTimeUtc
    public_server_status_age_seconds = $statusAgeSeconds
    authoritative_count_source = "GoldSrc status over RCON via scripts/run_public_crossfire_server.ps1 public_server_status.json"
    status_artifact_found = $null -ne $statusPayload
    status_artifact_reports_rcon_success = $statusReportsRconSuccess
    status_artifact_reports_server_ready = $serverReady
    status_artifact_human_count_source = $statusSource
    local_authoritative_status_usable = $localAuthoritativeStatusUsable
    public_server_process_detected = $publicServerProcessDetected
    hlds_processes = @($hldsProcesses)
    udp_listener_observed_locally = $udpListenerObserved
    udp_endpoints = @($udpEndpoints)
    local_ipv4_addresses = @($localAddresses)
    firewall_profiles = @($firewallProfiles)
    nat_port_forward_warning = "Local checks cannot prove inbound Internet reachability. Confirm router/NAT UDP forwarding for the selected port and any Windows firewall allow rule before treating an external join failure as a repo bug."
    warnings = @($warnings.ToArray())
    artifacts = [ordered]@{
        public_external_access_preflight_json = $reportJsonPath
        public_external_access_preflight_markdown = $reportMarkdownPath
    }
}

Write-JsonFile -Path $reportJsonPath -Value $report
$reportForMarkdown = Get-Content -LiteralPath $reportJsonPath -Raw | ConvertFrom-Json
Write-TextFile -Path $reportMarkdownPath -Value (Get-PreflightMarkdown -Report $reportForMarkdown)

Write-Host "Public external access preflight:"
Write-Host "  Verdict: $verdict"
Write-Host "  JSON: $reportJsonPath"
Write-Host "  Markdown: $reportMarkdownPath"
