param(
    [string]$Map = "crossfire",
    [int]$BotCount = 4,
    [int]$BotSkill = 3,
    [int]$ControlPort = 27016,
    [int]$TreatmentPort = 27017,
    [string]$LabRoot = "",
    [ValidateSet("conservative", "default", "responsive")]
    [string]$TreatmentProfile = "conservative",
    [string]$Configuration = "Release",
    [string]$Platform = "Win32",
    [string]$PythonPath = "",
    [string]$ClientExePath = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

function Add-Message {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $List.Add($Message) | Out-Null
    }
}

function Read-PortConflictDetails {
    param(
        [ValidateSet("TCP", "UDP")]
        [string]$Protocol,
        [int]$Port
    )

    try {
        if ($Protocol -eq "TCP") {
            $entries = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
        }
        else {
            $entries = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction Stop
        }

        if ($null -eq $entries) {
            return ""
        }

        $descriptions = @()
        foreach ($entry in @($entries)) {
            $owningProcess = $entry.OwningProcess
            $processLabel = "PID $owningProcess"
            if ($owningProcess) {
                $process = Get-Process -Id $owningProcess -ErrorAction SilentlyContinue
                if ($process) {
                    $processLabel = "$($process.ProcessName) (PID $owningProcess)"
                }
            }

            $localAddress = if ($entry.PSObject.Properties["LocalAddress"]) { [string]$entry.LocalAddress } else { "*" }
            $descriptions += "${localAddress}:$Port by $processLabel"
        }

        return ($descriptions | Select-Object -Unique) -join "; "
    }
    catch {
        return ""
    }
}

function Test-PortAvailability {
    param([int]$Port)

    $tcpAvailable = $true
    $udpAvailable = $true
    $tcpNote = ""
    $udpNote = ""

    $tcpListener = $null
    try {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $tcpListener.Server.ExclusiveAddressUse = $true
        $tcpListener.Start()
    }
    catch {
        $tcpAvailable = $false
        $tcpNote = $_.Exception.Message
    }
    finally {
        if ($null -ne $tcpListener) {
            $tcpListener.Stop()
        }
    }

    $udpClient = $null
    try {
        $udpClient = [System.Net.Sockets.UdpClient]::new($Port)
    }
    catch {
        $udpAvailable = $false
        $udpNote = $_.Exception.Message
    }
    finally {
        if ($null -ne $udpClient) {
            $udpClient.Dispose()
        }
    }

    $tcpConflict = if (-not $tcpAvailable) { Read-PortConflictDetails -Protocol "TCP" -Port $Port } else { "" }
    $udpConflict = if (-not $udpAvailable) { Read-PortConflictDetails -Protocol "UDP" -Port $Port } else { "" }
    $available = $tcpAvailable -and $udpAvailable

    return [pscustomobject]@{
        Port = $Port
        Available = $available
        TcpAvailable = $tcpAvailable
        UdpAvailable = $udpAvailable
        TcpConflict = $tcpConflict
        UdpConflict = $udpConflict
        TcpNote = $tcpNote
        UdpNote = $udpNote
    }
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { $LabRoot }
$resolvedLabRoot = Ensure-Directory -Path $resolvedLabRoot
$logsRoot = Ensure-Directory -Path (Get-LogsRootDefault -LabRoot $resolvedLabRoot)
$pairOutputRoot = Ensure-Directory -Path (Join-Path $logsRoot "eval\pairs")
$hldsRoot = Get-HldsRootDefault -LabRoot $resolvedLabRoot
$modRoot = Get-ServerModRoot -HldsRoot $hldsRoot
$bootstrapLogPath = Get-PluginBootstrapLogPath -HldsRoot $hldsRoot
$controlConfigPath = Get-BotTestConfigPath -ModRoot $modRoot -Map $Map
$controlJoinInfo = Get-HldsJoinInfo -Port $ControlPort
$treatmentJoinInfo = Get-HldsJoinInfo -Port $TreatmentPort
$buildOutputPath = Get-BuildOutputPath -Configuration $Configuration -Platform $Platform
$buildScriptPath = Join-Path $PSScriptRoot "build_vs2022.ps1"
$pairScriptPath = Join-Path $PSScriptRoot "run_control_treatment_pair.ps1"
$standardScriptPath = Join-Path $PSScriptRoot "run_standard_bots_crossfire.ps1"
$mixedScriptPath = Join-Path $PSScriptRoot "run_mixed_balance_eval.ps1"
$reviewScriptPath = Join-Path $PSScriptRoot "review_latest_pair_run.ps1"
$setupScriptPath = Join-Path $PSScriptRoot "setup_test_stand.ps1"
$clientHelperPath = Join-Path $PSScriptRoot "launch_local_hldm_client.ps1"

$warnings = [System.Collections.Generic.List[string]]::new()
$blockers = [System.Collections.Generic.List[string]]::new()
$notes = [System.Collections.Generic.List[string]]::new()

$requiredScripts = @(
    $buildScriptPath,
    $setupScriptPath,
    $standardScriptPath,
    $mixedScriptPath,
    $pairScriptPath,
    $reviewScriptPath
)

foreach ($scriptPath in $requiredScripts) {
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Add-Message -List $blockers -Message "Required script missing: $scriptPath"
    }
}

$msbuildPath = ""
try {
    $msbuildPath = Get-MSBuildPath
}
catch {
    Add-Message -List $blockers -Message $_.Exception.Message
}

$pythonExe = ""
try {
    $pythonExe = Get-PythonPath -PreferredPath $PythonPath
}
catch {
    Add-Message -List $blockers -Message $_.Exception.Message
}

$resolvedProfile = $null
try {
    $resolvedProfile = Get-TuningProfileDefinition -Name $TreatmentProfile
}
catch {
    Add-Message -List $blockers -Message $_.Exception.Message
}

$buildStatus = "present"
if (-not (Test-Path -LiteralPath $buildOutputPath)) {
    $buildStatus = "missing"
    if (Test-Path -LiteralPath $buildScriptPath) {
        try {
            & $buildScriptPath -Configuration $Configuration -Platform $Platform
            if (-not (Test-Path -LiteralPath $buildOutputPath)) {
                throw "Build completed without producing $buildOutputPath"
            }
            $buildStatus = "rebuilt"
        }
        catch {
            Add-Message -List $blockers -Message "Build output was missing and rebuild failed: $($_.Exception.Message)"
        }
    }
}

if ($ControlPort -eq $TreatmentPort) {
    Add-Message -List $blockers -Message "ControlPort and TreatmentPort must be different. Both were set to $ControlPort."
}

$controlPortStatus = Test-PortAvailability -Port $ControlPort
$treatmentPortStatus = Test-PortAvailability -Port $TreatmentPort

foreach ($portStatus in @($controlPortStatus, $treatmentPortStatus)) {
    if (-not $portStatus.Available) {
        $details = @()
        if ($portStatus.TcpConflict) { $details += "TCP $($portStatus.TcpConflict)" }
        elseif (-not $portStatus.TcpAvailable -and $portStatus.TcpNote) { $details += "TCP $($portStatus.TcpNote)" }
        if ($portStatus.UdpConflict) { $details += "UDP $($portStatus.UdpConflict)" }
        elseif (-not $portStatus.UdpAvailable -and $portStatus.UdpNote) { $details += "UDP $($portStatus.UdpNote)" }

        $detailText = if ($details.Count -gt 0) { " Details: " + ($details -join " | ") } else { "" }
        Add-Message -List $blockers -Message "Port $($portStatus.Port) is not available for a live lane.$detailText"
    }
}

$deploymentState = $null
if (Test-Path -LiteralPath $hldsRoot) {
    try {
        $deploymentState = Test-JKBottiLabDeployment -HldsRoot $hldsRoot -Configuration $Configuration -Platform $Platform
    }
    catch {
        Add-Message -List $warnings -Message "Current lab deployment is not yet aligned with the staged build: $($_.Exception.Message)"
    }
}
else {
    Add-Message -List $warnings -Message "HLDS lab root does not exist yet: $hldsRoot. The pair workflow will need to prepare it."
}

if (-not (Test-Path -LiteralPath $bootstrapLogPath)) {
    Add-Message -List $warnings -Message "Bootstrap log is not present yet: $bootstrapLogPath"
}

$clientHelperState = "not-checked"
$clientHelperMessage = ""
if (Test-Path -LiteralPath $clientHelperPath) {
    try {
        $clientDryRun = & $clientHelperPath -ClientExePath $ClientExePath -Port $ControlPort -DryRun
        $clientHelperState = "available"
        $clientHelperMessage = "Client helper resolved $($clientDryRun.ClientExePath)"
    }
    catch {
        $clientHelperState = "warning"
        $clientHelperMessage = $_.Exception.Message
        Add-Message -List $warnings -Message "Local client helper is not ready: $clientHelperMessage"
    }
}
else {
    $clientHelperState = "missing"
    $clientHelperMessage = "Optional client helper script was not found."
    Add-Message -List $warnings -Message $clientHelperMessage
}

if ($resolvedProfile) {
    Add-Message -List $notes -Message "Treatment profile '$($resolvedProfile.name)' remains the default first live treatment because it is the safest bounded profile for the first human pair."
}
if ($deploymentState) {
    Add-Message -List $notes -Message "Current deployed DLL matches the staged build."
}
if ($buildStatus -eq "rebuilt") {
    Add-Message -List $notes -Message "Build output was missing and was rebuilt during preflight."
}

$verdict = if ($blockers.Count -gt 0) {
    "blocked"
}
elseif ($warnings.Count -gt 0) {
    "ready-with-warnings"
}
else {
    "ready-for-human-pair-session"
}

$resolvedProfileName = if ($resolvedProfile) { $resolvedProfile.name } else { $TreatmentProfile }

Write-Host "Real human pair-session preflight:"
Write-Host "  Repo root: $repoRoot"
Write-Host "  Pair launcher: $pairScriptPath"
Write-Host "  Review helper: $reviewScriptPath"
Write-Host "  Build output: $buildOutputPath"
Write-Host "  Build status: $buildStatus"
Write-Host "  MSBuild: $msbuildPath"
Write-Host "  Python: $pythonExe"
Write-Host "  Pair output root: $pairOutputRoot"
Write-Host "  Bootstrap log path: $bootstrapLogPath"
Write-Host "  Control lane: $($controlJoinInfo.LoopbackAddress) ($controlConfigPath)"
Write-Host "  Treatment lane: $($treatmentJoinInfo.LoopbackAddress)"
Write-Host "  Treatment profile: $resolvedProfileName"
Write-Host "  Client helper: $clientHelperState"
if ($clientHelperMessage) {
    Write-Host "    $clientHelperMessage"
}

if ($notes.Count -gt 0) {
    Write-Host "Notes:"
    foreach ($message in $notes) {
        Write-Host "  - $message"
    }
}

if ($warnings.Count -gt 0) {
    Write-Host "Warnings:"
    foreach ($message in $warnings) {
        Write-Host "  - $message"
    }
}

if ($blockers.Count -gt 0) {
    Write-Host "Blockers:"
    foreach ($message in $blockers) {
        Write-Host "  - $message"
    }
}

Write-Host "Final operator-facing verdict: $verdict"

[pscustomobject]@{
    Verdict = $verdict
    RepoRoot = $repoRoot
    LabRoot = $resolvedLabRoot
    HldsRoot = $hldsRoot
    PairOutputRoot = $pairOutputRoot
    BuildOutputPath = $buildOutputPath
    BuildStatus = $buildStatus
    BootstrapLogPath = $bootstrapLogPath
    ControlConfigPath = $controlConfigPath
    ControlJoinTarget = $controlJoinInfo.LoopbackAddress
    TreatmentJoinTarget = $treatmentJoinInfo.LoopbackAddress
    TreatmentProfile = $resolvedProfileName
    ClientHelperState = $clientHelperState
    ClientHelperMessage = $clientHelperMessage
    Warnings = @($warnings)
    Blockers = @($blockers)
    Notes = @($notes)
    ControlPortStatus = $controlPortStatus
    TreatmentPortStatus = $treatmentPortStatus
}
