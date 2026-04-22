[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$MissionPath = "",
    [string]$MissionMarkdownPath = "",
    [string]$LabRoot = "",
    [Alias("EvalRoot")]
    [string]$OutputRoot = "",
    [string]$ClientExePath = "",
    [ValidateSet("ControlThenTreatment", "ControlOnly", "TreatmentOnly", "ManualOnly")]
    [string]$JoinSequence = "ControlThenTreatment",
    [switch]$AutoJoinControl,
    [switch]$AutoJoinTreatment,
    [switch]$AutoSwitchWhenControlReady,
    [switch]$AutoFinishWhenTreatmentGroundedReady,
    [int]$ControlJoinDelaySeconds = 5,
    [int]$TreatmentJoinDelaySeconds = 5,
    [int]$ControlGatePollSeconds = 5,
    [int]$TreatmentGatePollSeconds = 5,
    [int]$ControlStaySecondsMinimum = -1,
    [int]$TreatmentStaySecondsMinimum = -1,
    [int]$ControlStaySeconds = -1,
    [int]$TreatmentStaySeconds = -1,
    [int]$JoinAdmissionPollSeconds = 2,
    [int]$JoinRetryGraceSeconds = 18,
    [int]$JoinRetrySpacingSeconds = 3,
    [int]$MaxJoinAttempts = 2
)

. (Join-Path $PSScriptRoot "common.ps1")

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 24
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

function Resolve-ExistingPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-AbsolutePath {
    param(
        [string]$Path,
        [string]$BasePath = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    if (-not [string]::IsNullOrWhiteSpace($BasePath)) {
        return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) $Path))
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) {
            return $Object[$Name]
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Resolve-MissionArtifacts {
    param(
        [string]$ExplicitMissionPath,
        [string]$ExplicitMissionMarkdownPath,
        [string]$ResolvedLabRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionPath)) {
        $resolvedMissionPath = Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionPath)
        if (-not $resolvedMissionPath) {
            throw "Mission JSON was not found: $ExplicitMissionPath"
        }

        $resolvedMissionMarkdownPath = if (-not [string]::IsNullOrWhiteSpace($ExplicitMissionMarkdownPath)) {
            Resolve-ExistingPath -Path (Get-AbsolutePath -Path $ExplicitMissionMarkdownPath)
        }
        else {
            Resolve-ExistingPath -Path ([System.IO.Path]::ChangeExtension($resolvedMissionPath, ".md"))
        }

        return [pscustomobject]@{
            JsonPath = $resolvedMissionPath
            MarkdownPath = $resolvedMissionMarkdownPath
        }
    }

    $prepareScriptPath = Join-Path $PSScriptRoot "prepare_next_live_session_mission.ps1"
    $preparedMission = & $prepareScriptPath -LabRoot $ResolvedLabRoot
    $resolvedMissionPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionJsonPath" -Default ""))
    $resolvedMissionMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $preparedMission -Name "MissionMarkdownPath" -Default ""))
    if (-not $resolvedMissionPath) {
        throw "The current mission brief could not be prepared."
    }

    return [pscustomobject]@{
        JsonPath = $resolvedMissionPath
        MarkdownPath = $resolvedMissionMarkdownPath
    }
}

function Find-NewPairRoot {
    param(
        [string]$Root,
        [datetime]$NotBeforeUtc
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) {
        return ""
    }

    $candidates = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTimeUtc -ge $NotBeforeUtc.AddMinutes(-1) -and (
                (Test-Path -LiteralPath (Join-Path $_.FullName "control_join_instructions.txt")) -or
                (Test-Path -LiteralPath (Join-Path $_.FullName "pair_join_instructions.txt")) -or
                (Test-Path -LiteralPath (Join-Path $_.FullName "guided_session"))
            )
        } |
        Sort-Object LastWriteTimeUtc -Descending

    $candidate = $candidates | Select-Object -First 1
    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Wait-ForPairRoot {
    param(
        [string]$Root,
        [datetime]$NotBeforeUtc,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$TimeoutSeconds = 180
    )

    $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        $pairRoot = Find-NewPairRoot -Root $Root -NotBeforeUtc $NotBeforeUtc
        if ($pairRoot) {
            return $pairRoot
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    break
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds 2
    }

    return Find-NewPairRoot -Root $Root -NotBeforeUtc $NotBeforeUtc
}

function Test-LocalPortActive {
    param([int]$Port)

    $udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
    if ($null -ne $udp) {
        return $true
    }

    $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $tcp
}

function Wait-ForPortActive {
    param(
        [int]$Port,
        [string]$Label,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$TimeoutSeconds = 180
    )

    $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        if (Test-LocalPortActive -Port $Port) {
            return [pscustomobject]@{
                Ready = $true
                Explanation = "Detected an active listener on port $Port for the $Label lane."
            }
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    return [pscustomobject]@{
                        Ready = $false
                        Explanation = "The background conservative attempt exited before port $Port became active for the $Label lane."
                    }
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds 2
    }

    return [pscustomobject]@{
        Ready = $false
        Explanation = "Timed out waiting for port $Port to become active for the $Label lane."
    }
}

function Stop-ClientProcessIfRunning {
    param(
        [int]$ProcessId,
        [string]$Reason
    )

    if ($ProcessId -le 0) {
        return $false
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $false
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Host "  Stopped client PID $ProcessId ($Reason)."
        return $true
    }
    catch {
        Write-Warning "Could not stop client PID $ProcessId ($Reason): $($_.Exception.Message)"
        return $false
    }
}

function Invoke-LaneJoinHelper {
    param(
        [string]$Lane,
        [string]$PairRoot,
        [string]$ResolvedClientExePath,
        [int]$Port,
        [string]$Map
    )

    $joinScriptPath = Join-Path $PSScriptRoot "join_live_pair_lane.ps1"
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\join_live_pair_lane.ps1",
        "-Lane",
        $Lane
    )
    $joinArgs = [ordered]@{
        Lane = $Lane
    }

    $pairSummaryPath = if ($PairRoot) { Join-Path $PairRoot "pair_summary.json" } else { "" }
    if ($pairSummaryPath -and (Test-Path -LiteralPath $pairSummaryPath)) {
        $commandParts += @("-PairRoot", $PairRoot)
        $joinArgs.PairRoot = $PairRoot
    }
    else {
        $commandParts += @("-Port", [string]$Port, "-Map", $Map)
        $joinArgs.Port = $Port
        $joinArgs.Map = $Map
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedClientExePath)) {
        $commandParts += @("-ClientExePath", $ResolvedClientExePath)
        $joinArgs.ClientExePath = $ResolvedClientExePath
    }

    $commandText = @($commandParts | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "

    try {
        $result = & $joinScriptPath @joinArgs
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = ""
            Result = $result
        }
    }
    catch {
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = $_.Exception.Message
            Result = $null
        }
    }
}

function Invoke-ControlSwitchGuide {
    param(
        [string]$PairRoot,
        [string]$MissionPath,
        [int]$PollSeconds
    )

    $guideScriptPath = Join-Path $PSScriptRoot "guide_control_to_treatment_switch.ps1"
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\guide_control_to_treatment_switch.ps1",
        "-PairRoot",
        $PairRoot,
        "-Once",
        "-PollSeconds",
        [string]$PollSeconds
    )
    $guideArgs = [ordered]@{
        PairRoot = $PairRoot
        Once = $true
        PollSeconds = $PollSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionPath)) {
        $commandParts += @("-MissionPath", $MissionPath)
        $guideArgs.MissionPath = $MissionPath
    }

    $commandText = @($commandParts | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "

    try {
        $result = & $guideScriptPath @guideArgs
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = ""
            Result = $result
        }
    }
    catch {
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = $_.Exception.Message
            Result = $null
        }
    }
}

function Wait-ForControlReadySwitch {
    param(
        [string]$PairRoot,
        [string]$MissionPath,
        [int]$PollSeconds,
        [int]$MinimumStaySeconds,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$TimeoutSeconds = 600
    )

    $startedAtUtc = (Get-Date).ToUniversalTime()
    $minimumStayMetAtUtc = $startedAtUtc.AddSeconds([Math]::Max(0, $MinimumStaySeconds))
    $deadlineUtc = $startedAtUtc.AddSeconds([Math]::Max(60, $TimeoutSeconds))
    $lastPrintKey = ""
    $lastExecution = $null

    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        $execution = Invoke-ControlSwitchGuide -PairRoot $PairRoot -MissionPath $MissionPath -PollSeconds $PollSeconds
        $lastExecution = $execution
        $guideResult = Get-ObjectPropertyValue -Object $execution -Name "Result" -Default $null
        $guideError = [string](Get-ObjectPropertyValue -Object $execution -Name "Error" -Default "")

        if ($null -eq $guideResult) {
            return [pscustomobject]@{
                ReadyToSwitch = $false
                GuideExecution = $execution
                Terminal = $true
                Explanation = if ($guideError) { $guideError } else { "The control-first switch helper did not produce a readable result." }
            }
        }

        $controlLane = Get-ObjectPropertyValue -Object $guideResult -Name "control_lane" -Default $null
        $treatmentLane = Get-ObjectPropertyValue -Object $guideResult -Name "treatment_lane" -Default $null
        $verdict = [string](Get-ObjectPropertyValue -Object $guideResult -Name "current_switch_verdict" -Default "")
        $controlSafeToLeave = [bool](Get-ObjectPropertyValue -Object $controlLane -Name "safe_to_leave" -Default $false)
        $minimumStaySatisfied = (Get-Date).ToUniversalTime() -ge $minimumStayMetAtUtc

        $printKey = @(
            $verdict
            [string](Get-ObjectPropertyValue -Object $controlLane -Name "actual_human_snapshots" -Default 0)
            [string](Get-ObjectPropertyValue -Object $controlLane -Name "actual_human_presence_seconds" -Default 0)
            [string](Get-ObjectPropertyValue -Object $controlLane -Name "remaining_human_snapshots" -Default 0)
            [string](Get-ObjectPropertyValue -Object $controlLane -Name "remaining_human_presence_seconds" -Default 0)
            [string]$minimumStaySatisfied
        ) -join "|"

        if ($printKey -ne $lastPrintKey) {
            Write-Host "  Control-first verdict: $verdict"
            Write-Host "    Control snapshots / seconds: $($controlLane.actual_human_snapshots) / $($controlLane.actual_human_presence_seconds)"
            Write-Host "    Control remaining snapshots / seconds: $($controlLane.remaining_human_snapshots) / $($controlLane.remaining_human_presence_seconds)"
            if (-not $minimumStaySatisfied) {
                $remainingMinimum = [Math]::Ceiling(($minimumStayMetAtUtc - (Get-Date).ToUniversalTime()).TotalSeconds)
                Write-Host "    Minimum control stay still active for about $remainingMinimum second(s)."
            }
            Write-Host "    Explanation: $($guideResult.explanation)"
            $lastPrintKey = $printKey
        }

        if ($controlSafeToLeave -and $minimumStaySatisfied) {
            return [pscustomobject]@{
                ReadyToSwitch = $true
                GuideExecution = $execution
                Terminal = $false
                Explanation = [string](Get-ObjectPropertyValue -Object $guideResult -Name "explanation" -Default "")
            }
        }

        if ($verdict -in @("insufficient-timeout", "blocked-no-active-pair")) {
            return [pscustomobject]@{
                ReadyToSwitch = $false
                GuideExecution = $execution
                Terminal = $true
                Explanation = [string](Get-ObjectPropertyValue -Object $guideResult -Name "explanation" -Default "")
            }
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    return [pscustomobject]@{
                        ReadyToSwitch = $false
                        GuideExecution = $execution
                        Terminal = $true
                        Explanation = "The background conservative attempt exited before the control-first switch gate cleared."
                    }
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return [pscustomobject]@{
        ReadyToSwitch = $false
        GuideExecution = $lastExecution
        Terminal = $true
        Explanation = "Timed out waiting for the control-first switch gate to clear within $TimeoutSeconds second(s)."
    }
}

function Invoke-TreatmentPatchGuide {
    param(
        [string]$PairRoot,
        [string]$MissionPath,
        [int]$PollSeconds
    )

    $guideScriptPath = Join-Path $PSScriptRoot "guide_treatment_patch_window.ps1"
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\guide_treatment_patch_window.ps1",
        "-PairRoot",
        $PairRoot,
        "-Once",
        "-PollSeconds",
        [string]$PollSeconds
    )
    $guideArgs = [ordered]@{
        PairRoot = $PairRoot
        Once = $true
        PollSeconds = $PollSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionPath)) {
        $commandParts += @("-MissionPath", $MissionPath)
        $guideArgs.MissionPath = $MissionPath
    }

    $commandText = @($commandParts | ForEach-Object { Format-ProcessArgumentText -Value ([string]$_) }) -join " "

    try {
        $result = & $guideScriptPath @guideArgs
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = ""
            Result = $result
        }
    }
    catch {
        return [pscustomobject]@{
            Attempted = $true
            CommandText = $commandText
            Error = $_.Exception.Message
            Result = $null
        }
    }
}

function Invoke-ConservativePhaseFlowGuide {
    param(
        [string]$PairRoot,
        [string]$MissionPath,
        [int]$PollSeconds
    )

    $guideScriptPath = Join-Path $PSScriptRoot "guide_conservative_phase_flow.ps1"
    $commandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ".\scripts\guide_conservative_phase_flow.ps1",
        "-PairRoot",
        $PairRoot,
        "-Once",
        "-PollSeconds",
        [string]$PollSeconds
    )

    if (-not [string]::IsNullOrWhiteSpace($MissionPath)) {
        $commandParts += @("-MissionPath", $MissionPath)
    }

    $commandText = ($commandParts | ForEach-Object {
            if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
        }) -join ' '

    $invokeParams = @{
        PairRoot = $PairRoot
        Once = $true
        PollSeconds = $PollSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace($MissionPath)) {
        $invokeParams["MissionPath"] = $MissionPath
    }

    try {
        $result = & $guideScriptPath @invokeParams
        return [pscustomobject]@{
            CommandText = $commandText
            Result = $result
            Error = ""
        }
    }
    catch {
        return [pscustomobject]@{
            CommandText = $commandText
            Result = $null
            Error = $_.Exception.Message
        }
    }
}

function Wait-ForTreatmentGroundedReady {
    param(
        [string]$PairRoot,
        [string]$MissionPath,
        [int]$PollSeconds,
        [int]$MinimumStaySeconds,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$TimeoutSeconds = 900
    )

    $startedAtUtc = (Get-Date).ToUniversalTime()
    $minimumStayMetAtUtc = $startedAtUtc.AddSeconds([Math]::Max(0, $MinimumStaySeconds))
    $deadlineUtc = $startedAtUtc.AddSeconds([Math]::Max(60, $TimeoutSeconds))
    $lastPrintKey = ""
    $lastExecution = $null

    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        $execution = Invoke-TreatmentPatchGuide -PairRoot $PairRoot -MissionPath $MissionPath -PollSeconds $PollSeconds
        $lastExecution = $execution
        $guideResult = Get-ObjectPropertyValue -Object $execution -Name "Result" -Default $null
        $guideError = [string](Get-ObjectPropertyValue -Object $execution -Name "Error" -Default "")

        if ($null -eq $guideResult) {
            return [pscustomobject]@{
                ReadyToFinish = $false
                GuideExecution = $execution
                Terminal = $true
                Explanation = if ($guideError) { $guideError } else { "The treatment-hold helper did not produce a readable result." }
            }
        }

        $treatmentLane = Get-ObjectPropertyValue -Object $guideResult -Name "treatment_lane" -Default $null
        $verdict = [string](Get-ObjectPropertyValue -Object $guideResult -Name "current_verdict" -Default "")
        $treatmentSafeToLeave = [bool](Get-ObjectPropertyValue -Object $guideResult -Name "treatment_safe_to_leave" -Default $false)
        $minimumStaySatisfied = (Get-Date).ToUniversalTime() -ge $minimumStayMetAtUtc

        $printKey = @(
            $verdict
            [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_human_snapshots" -Default 0)
            [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_human_presence_seconds" -Default 0)
            [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_patch_while_human_present_events" -Default 0)
            [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "actual_post_patch_observation_seconds" -Default 0)
            [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_patch_while_human_present_events" -Default 0)
            [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "remaining_post_patch_observation_seconds" -Default 0)
            [string]$minimumStaySatisfied
        ) -join "|"

        if ($printKey -ne $lastPrintKey) {
            Write-Host "  Treatment-hold verdict: $verdict"
            Write-Host "    Treatment snapshots / seconds: $($treatmentLane.actual_human_snapshots) / $($treatmentLane.actual_human_presence_seconds)"
            Write-Host "    Treatment patch events / remaining: $($treatmentLane.actual_patch_while_human_present_events) / $($treatmentLane.remaining_patch_while_human_present_events)"
            Write-Host "    Treatment post-patch seconds / remaining: $($treatmentLane.actual_post_patch_observation_seconds) / $($treatmentLane.remaining_post_patch_observation_seconds)"
            if (-not $minimumStaySatisfied) {
                $remainingMinimum = [Math]::Ceiling(($minimumStayMetAtUtc - (Get-Date).ToUniversalTime()).TotalSeconds)
                Write-Host "    Minimum treatment stay still active for about $remainingMinimum second(s)."
            }
            Write-Host "    Explanation: $($guideResult.explanation)"
            $lastPrintKey = $printKey
        }

        if ($treatmentSafeToLeave -and $minimumStaySatisfied) {
            return [pscustomobject]@{
                ReadyToFinish = $true
                GuideExecution = $execution
                Terminal = $false
                Explanation = [string](Get-ObjectPropertyValue -Object $guideResult -Name "explanation" -Default "")
            }
        }

        if ($verdict -in @("insufficient-timeout", "blocked-no-active-pair")) {
            return [pscustomobject]@{
                ReadyToFinish = $false
                GuideExecution = $execution
                Terminal = $true
                Explanation = [string](Get-ObjectPropertyValue -Object $guideResult -Name "explanation" -Default "")
            }
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    return [pscustomobject]@{
                        ReadyToFinish = $false
                        GuideExecution = $execution
                        Terminal = $true
                        Explanation = "The background conservative attempt exited before the treatment-hold gate cleared."
                    }
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return [pscustomobject]@{
        ReadyToFinish = $false
        GuideExecution = $lastExecution
        Terminal = $true
        Explanation = "Timed out waiting for the treatment-hold gate to clear within $TimeoutSeconds second(s)."
    }
}

function Find-LatestLaneRootForPair {
    param(
        [string]$PairRoot,
        [string]$Lane
    )

    if ([string]::IsNullOrWhiteSpace($PairRoot) -or [string]::IsNullOrWhiteSpace($Lane)) {
        return ""
    }

    $laneParent = Resolve-ExistingPath -Path (Join-Path (Join-Path $PairRoot "lanes") $Lane.ToLowerInvariant())
    if (-not $laneParent) {
        return ""
    }

    $candidate = Get-ChildItem -LiteralPath $laneParent -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $candidate) {
        return ""
    }

    return $candidate.FullName
}

function Get-ConnectionEvidence {
    param([string[]]$LogLines)

    $connectedLines = New-Object System.Collections.Generic.List[string]
    $enteredLines = New-Object System.Collections.Generic.List[string]
    $matchedEnteredLines = New-Object System.Collections.Generic.List[string]
    $connectedPlayers = New-Object System.Collections.Generic.List[object]

    foreach ($line in @($LogLines)) {
        if ($line -match 'connected, address') {
            $connectedLines.Add($line) | Out-Null
            if ($line -match '"(?<name>[^"<]+)<\d+><(?<steam>[^>]*)><[^>]*>" connected, address "(?<address>[^"]+)"') {
                $connectedPlayers.Add([pscustomobject]@{
                        name = [string]$Matches["name"]
                        steam = [string]$Matches["steam"]
                        address = [string]$Matches["address"]
                    }) | Out-Null
            }
        }

        if ($line -match 'entered the game') {
            $enteredLines.Add($line) | Out-Null
        }
    }

    foreach ($enteredLine in @($enteredLines.ToArray())) {
        foreach ($player in @($connectedPlayers.ToArray())) {
            $name = [string](Get-ObjectPropertyValue -Object $player -Name "name" -Default "")
            $steam = [string](Get-ObjectPropertyValue -Object $player -Name "steam" -Default "")
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $nameMatched = $enteredLine -match ('"{0}<\d+><' -f [regex]::Escape($name))
            $steamMatched = if ([string]::IsNullOrWhiteSpace($steam)) { $true } else { $enteredLine -match [regex]::Escape($steam) }
            if ($nameMatched -and $steamMatched) {
                $matchedEnteredLines.Add($enteredLine) | Out-Null
                break
            }
        }
    }

    return [pscustomobject]@{
        connected_lines = @($connectedLines.ToArray())
        entered_game_lines = @($matchedEnteredLines.ToArray())
        raw_entered_game_lines = @($enteredLines.ToArray())
        connected_players = @($connectedPlayers.ToArray())
    }
}

function Get-ConnectionEvidenceFromLogPath {
    param([string]$Path)

    $resolvedPath = Resolve-ExistingPath -Path $Path
    if (-not $resolvedPath) {
        return [pscustomobject]@{
            connected_lines = @()
            entered_game_lines = @()
            raw_entered_game_lines = @()
            connected_players = @()
        }
    }

    return Get-ConnectionEvidence -LogLines @(Get-Content -LiteralPath $resolvedPath)
}

function Get-HldsLineTimestampUtcString {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return ""
    }

    if ($Line -match '^L\s+(?<month>\d{2})/(?<day>\d{2})/(?<year>\d{4})\s+-\s+(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}):') {
        try {
            $localTime = Get-Date -Year ([int]$Matches["year"]) -Month ([int]$Matches["month"]) -Day ([int]$Matches["day"]) `
                -Hour ([int]$Matches["hour"]) -Minute ([int]$Matches["minute"]) -Second ([int]$Matches["second"])
            return $localTime.ToUniversalTime().ToString("o")
        }
        catch {
            return ""
        }
    }

    return ""
}

function Wait-ForLaneJoinAdmission {
    param(
        [string]$PairRoot,
        [string]$Lane,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$ClientProcessId,
        [string]$JoinStartedAtUtc,
        [int]$GraceSeconds,
        [int]$PollSeconds
    )

    $startedAtUtc = if (-not [string]::IsNullOrWhiteSpace($JoinStartedAtUtc)) {
        try {
            [datetime]$JoinStartedAtUtc
        }
        catch {
            (Get-Date).ToUniversalTime()
        }
    }
    else {
        (Get-Date).ToUniversalTime()
    }

    $deadlineUtc = $startedAtUtc.AddSeconds([Math]::Max(5, $GraceSeconds))
    $probePollSeconds = [Math]::Max(1, $PollSeconds)
    $laneRoot = ""
    $hldsStdoutPath = ""
    $firstServerConnectionSeenAtUtc = ""
    $firstEnteredTheGameSeenAtUtc = ""
    $processObservedRunning = $false
    $processAliveFirstSeenAtUtc = ""
    $processAliveLastSeenAtUtc = ""
    $processExitObservedAtUtc = ""
    $processRuntimeSeconds = $null
    $latestConnectedLine = ""
    $latestEnteredGameLine = ""

    while ((Get-Date).ToUniversalTime() -lt $deadlineUtc) {
        if (-not $laneRoot) {
            $laneRoot = Find-LatestLaneRootForPair -PairRoot $PairRoot -Lane $Lane
        }

        if ($laneRoot -and -not $hldsStdoutPath) {
            $hldsStdoutPath = Resolve-ExistingPath -Path (Join-Path $laneRoot "hlds.stdout.log")
        }

        $connectionEvidence = Get-ConnectionEvidenceFromLogPath -Path $hldsStdoutPath
        if (@($connectionEvidence.connected_lines).Count -gt 0) {
            $latestConnectedLine = [string]$connectionEvidence.connected_lines[0]
            if (-not $firstServerConnectionSeenAtUtc) {
                $firstServerConnectionSeenAtUtc = Get-HldsLineTimestampUtcString -Line $latestConnectedLine
            }
        }

        if (@($connectionEvidence.entered_game_lines).Count -gt 0) {
            $latestEnteredGameLine = [string]$connectionEvidence.entered_game_lines[0]
            if (-not $firstEnteredTheGameSeenAtUtc) {
                $firstEnteredTheGameSeenAtUtc = Get-HldsLineTimestampUtcString -Line $latestEnteredGameLine
            }
        }

        if ($ClientProcessId -gt 0) {
            $runningClientProcess = Get-Process -Id $ClientProcessId -ErrorAction SilentlyContinue
            if ($null -ne $runningClientProcess) {
                $processObservedRunning = $true
                if (-not $processAliveFirstSeenAtUtc) {
                    $processAliveFirstSeenAtUtc = (Get-Date).ToUniversalTime().ToString("o")
                }
                $processAliveLastSeenAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
            elseif (-not $processExitObservedAtUtc) {
                $processExitObservedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
        }

        if ($latestEnteredGameLine) {
            break
        }

        if ($null -ne $AttemptProcess) {
            try {
                if ($AttemptProcess.HasExited) {
                    break
                }
            }
            catch {
            }
        }

        Start-Sleep -Seconds $probePollSeconds
    }

    if ($null -eq $processRuntimeSeconds -and $JoinStartedAtUtc) {
        $endRuntimeAtUtc = if ($processExitObservedAtUtc) { [datetime]$processExitObservedAtUtc } elseif ($processAliveLastSeenAtUtc) { [datetime]$processAliveLastSeenAtUtc } else { $null }
        if ($null -ne $endRuntimeAtUtc) {
            try {
                $processRuntimeSeconds = [Math]::Round(($endRuntimeAtUtc - ([datetime]$JoinStartedAtUtc)).TotalSeconds, 1)
            }
            catch {
                $processRuntimeSeconds = $null
            }
        }
    }

    return [pscustomobject]@{
        lane_root = $laneRoot
        hlds_stdout_log = $hldsStdoutPath
        server_connection_seen = [bool]$latestConnectedLine
        entered_the_game_seen = [bool]$latestEnteredGameLine
        first_server_connection_seen_at_utc = $firstServerConnectionSeenAtUtc
        first_entered_the_game_seen_at_utc = $firstEnteredTheGameSeenAtUtc
        client_process_observed_running = $processObservedRunning
        process_alive_first_seen_at_utc = $processAliveFirstSeenAtUtc
        process_alive_last_seen_at_utc = $processAliveLastSeenAtUtc
        process_exit_observed_at_utc = $processExitObservedAtUtc
        process_runtime_seconds = $processRuntimeSeconds
        exited_before_server_connect = [bool]$processExitObservedAtUtc -and -not [bool]$latestConnectedLine
        exited_before_entered_game = [bool]$processExitObservedAtUtc -and -not [bool]$latestEnteredGameLine
    }
}

function Invoke-ValidatedLaneJoin {
    param(
        [string]$Lane,
        [string]$PairRoot,
        [string]$ResolvedClientExePath,
        [int]$Port,
        [string]$Map,
        [System.Diagnostics.Process]$AttemptProcess,
        [int]$GraceSeconds,
        [int]$RetrySpacingSeconds,
        [int]$MaxAttempts,
        [int]$AdmissionPollSeconds
    )

    $attemptRecords = New-Object System.Collections.Generic.List[object]
    $joinExecution = $null
    $joinAttemptCount = 0
    $joinRetryUsed = $false
    $joinRetryReason = ""
    $joinRetryTriggeredAtUtc = ""
    $latestAdmissionEvidence = $null

    $maxAttemptsResolved = [Math]::Max(1, $MaxAttempts)
    for ($attemptIndex = 1; $attemptIndex -le $maxAttemptsResolved; $attemptIndex++) {
        $joinExecution = Invoke-LaneJoinHelper -Lane $Lane -PairRoot $PairRoot -ResolvedClientExePath $ResolvedClientExePath -Port $Port -Map $Map
        $joinAttemptCount = $attemptIndex
        $joinResult = Get-ObjectPropertyValue -Object $joinExecution -Name "Result" -Default $null
        $joinProcessId = [int](Get-ObjectPropertyValue -Object $joinResult -Name "ProcessId" -Default 0)
        $joinStartedAtUtc = [string](Get-ObjectPropertyValue -Object $joinResult -Name "LaunchStartedAtUtc" -Default "")
        $joinVerdict = [string](Get-ObjectPropertyValue -Object $joinResult -Name "ResultVerdict" -Default "")

        $admissionEvidence = Wait-ForLaneJoinAdmission `
            -PairRoot $PairRoot `
            -Lane $Lane `
            -AttemptProcess $AttemptProcess `
            -ClientProcessId $joinProcessId `
            -JoinStartedAtUtc $joinStartedAtUtc `
            -GraceSeconds $GraceSeconds `
            -PollSeconds $AdmissionPollSeconds
        $latestAdmissionEvidence = $admissionEvidence

        $attemptRecords.Add([pscustomobject]@{
                attempt_index = $attemptIndex
                helper_result_verdict = $joinVerdict
                process_id = $joinProcessId
                launched_at_utc = $joinStartedAtUtc
                launch_command = [string](Get-ObjectPropertyValue -Object $joinResult -Name "LaunchCommand" -Default "")
                client_working_directory = [string](Get-ObjectPropertyValue -Object $joinResult -Name "ClientWorkingDirectory" -Default "")
                server_connection_seen = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "server_connection_seen" -Default $false)
                entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "entered_the_game_seen" -Default $false)
                first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "first_server_connection_seen_at_utc" -Default "")
                first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "first_entered_the_game_seen_at_utc" -Default "")
                process_observed_running = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "client_process_observed_running" -Default $false)
                process_alive_first_seen_at_utc = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "process_alive_first_seen_at_utc" -Default "")
                process_alive_last_seen_at_utc = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "process_alive_last_seen_at_utc" -Default "")
                process_exit_observed_at_utc = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "process_exit_observed_at_utc" -Default "")
                process_runtime_seconds = Get-ObjectPropertyValue -Object $admissionEvidence -Name "process_runtime_seconds" -Default $null
                exited_before_server_connect = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "exited_before_server_connect" -Default $false)
                exited_before_entered_game = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "exited_before_entered_game" -Default $false)
                lane_root = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "lane_root" -Default "")
                hlds_stdout_log = [string](Get-ObjectPropertyValue -Object $admissionEvidence -Name "hlds_stdout_log" -Default "")
            }) | Out-Null

        $serverConnectionSeen = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "server_connection_seen" -Default $false)
        $enteredTheGameSeen = [bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "entered_the_game_seen" -Default $false)
        if ($serverConnectionSeen -or $enteredTheGameSeen -or $attemptIndex -ge $maxAttemptsResolved) {
            break
        }

        $joinRetryUsed = $true
        if ([bool](Get-ObjectPropertyValue -Object $admissionEvidence -Name "exited_before_server_connect" -Default $false)) {
            $joinRetryReason = "client-process-exited-before-server-connect"
        }
        else {
            $joinRetryReason = "no-server-connect-within-retry-grace-window"
        }
        $joinRetryTriggeredAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Stop-ClientProcessIfRunning -ProcessId $joinProcessId -Reason ("{0} lane join retry" -f $Lane.ToLowerInvariant()) | Out-Null
        if ($RetrySpacingSeconds -gt 0) {
            Start-Sleep -Seconds $RetrySpacingSeconds
        }
    }

    return [pscustomobject]@{
        JoinExecution = $joinExecution
        JoinAttemptCount = $joinAttemptCount
        JoinRetryUsed = $joinRetryUsed
        JoinRetryReason = $joinRetryReason
        JoinRetryTriggeredAtUtc = $joinRetryTriggeredAtUtc
        JoinAttempts = @($attemptRecords.ToArray())
        AdmissionEvidence = $latestAdmissionEvidence
    }
}

function Get-ReportPaths {
    param(
        [string]$PairRoot,
        [string]$ResolvedRegistryRoot,
        [string]$Stamp
    )

    if (-not [string]::IsNullOrWhiteSpace($PairRoot)) {
        return [ordered]@{
            JsonPath = Join-Path $PairRoot "human_participation_conservative_attempt.json"
            MarkdownPath = Join-Path $PairRoot "human_participation_conservative_attempt.md"
        }
    }

    $fallbackRoot = Ensure-Directory -Path (Join-Path $ResolvedRegistryRoot "human_participation_conservative_attempt")
    return [ordered]@{
        JsonPath = Join-Path $fallbackRoot ("attempt-{0}.json" -f $Stamp)
        MarkdownPath = Join-Path $fallbackRoot ("attempt-{0}.md" -f $Stamp)
    }
}

function Get-DiscoverySourceName {
    param([object]$DiscoveryReport)

    $checked = @($DiscoveryReport.discovery_sources_checked)
    foreach ($source in $checked) {
        if ([bool](Get-ObjectPropertyValue -Object $source -Name "exists" -Default $false)) {
            return [string](Get-ObjectPropertyValue -Object $source -Name "source_name" -Default "")
        }
    }

    return ""
}

function Get-HumanAttemptVerdict {
    param(
        [bool]$ClientLaunchable,
        [bool]$ManualReviewRequired,
        [bool]$CountsTowardPromotion,
        [bool]$CreatedFirstGroundedConservativeSession,
        [bool]$ReducedPromotionGap,
        [bool]$InterruptedAndRecovered,
        [bool]$ControlHumanSignal,
        [bool]$TreatmentHumanSignal,
        [string]$JoinSequence,
        [string]$MissionVerdict
    )

    if (-not $ClientLaunchable) {
        return "no-client-available"
    }

    if ($ManualReviewRequired) {
        return "manual-review-required"
    }

    if ($CountsTowardPromotion -and $CreatedFirstGroundedConservativeSession) {
        return "conservative-session-grounded-first-capture"
    }

    if ($CountsTowardPromotion -and $ReducedPromotionGap) {
        return "conservative-session-grounded-gap-reduced"
    }

    if ($InterruptedAndRecovered) {
        return "conservative-session-interrupted-and-recovered"
    }

    if (-not $ControlHumanSignal -and -not $TreatmentHumanSignal) {
        return "client-launchable-but-no-meaningful-human-signal"
    }

    if ($ControlHumanSignal -and -not $TreatmentHumanSignal) {
        return "control-only-human-signal"
    }

    if (-not $ControlHumanSignal -and $TreatmentHumanSignal) {
        return "treatment-only-human-signal"
    }

    if ($ControlHumanSignal -and $TreatmentHumanSignal -and $JoinSequence -eq "ControlThenTreatment") {
        return "sequential-human-signal-insufficient"
    }

    if ($MissionVerdict -eq "mission-failed-insufficient-signal") {
        return "conservative-session-insufficient-human-signal"
    }

    return "conservative-session-insufficient-human-signal"
}

function Get-HumanAttemptExplanation {
    param(
        [string]$AttemptVerdict,
        [object]$DiscoveryReport,
        [object]$FirstAttemptReport,
        [object]$MissionAttainment,
        [object]$PairSummary,
        [string[]]$MissingTargetDetails
    )

    $firstAttemptExplanation = [string](Get-ObjectPropertyValue -Object $FirstAttemptReport -Name "explanation" -Default "")
    $missionExplanation = [string](Get-ObjectPropertyValue -Object $MissionAttainment -Name "explanation" -Default "")
    $controlLane = Get-ObjectPropertyValue -Object $PairSummary -Name "control_lane" -Default $null
    $treatmentLane = Get-ObjectPropertyValue -Object $PairSummary -Name "treatment_lane" -Default $null
    $comparison = Get-ObjectPropertyValue -Object $PairSummary -Name "comparison" -Default $null
    $comparisonExplanation = [string](Get-ObjectPropertyValue -Object $comparison -Name "comparison_explanation" -Default (Get-ObjectPropertyValue -Object $comparison -Name "comparison_reason" -Default ""))
    $pairOperatorNote = [string](Get-ObjectPropertyValue -Object $PairSummary -Name "operator_note" -Default "")
    $controlSeconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0.0)
    $treatmentSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)

    switch ($AttemptVerdict) {
        "no-client-available" {
            return "The local Half-Life client could not be discovered for automatic lane joins. {0}" -f [string](Get-ObjectPropertyValue -Object $DiscoveryReport -Name "explanation" -Default "")
        }
        "conservative-session-grounded-first-capture" {
            return "The local client joined both lanes sequentially, both lanes cleared the grounded human-signal threshold, treatment patched while humans were present, and the pair became the first certified grounded conservative session."
        }
        "conservative-session-grounded-gap-reduced" {
            return "The local client produced grounded human participation and the resulting pair counted toward promotion, reducing the conservative evidence gap."
        }
        "conservative-session-interrupted-and-recovered" {
            return $firstAttemptExplanation
        }
        "client-launchable-but-no-meaningful-human-signal" {
            return "The local client was launchable, but the saved pair evidence still shows no human presence in either lane. {0}" -f $missionExplanation
        }
        "control-only-human-signal" {
            return "The local client produced human signal only in the control lane ({0:0.#}s). The treatment lane still missed grounded human participation. {1}" -f $controlSeconds, $missionExplanation
        }
        "treatment-only-human-signal" {
            return "The local client produced human signal only in the treatment lane ({0:0.#}s). The control baseline still missed grounded human participation. {1}" -f $treatmentSeconds, $missionExplanation
        }
        "sequential-human-signal-insufficient" {
            if ($MissingTargetDetails.Count -gt 0) {
                return "Sequential control-then-treatment participation was observed, but the run still missed grounded conservative criteria: {0}" -f ($MissingTargetDetails -join " ")
            }

            if (-not [string]::IsNullOrWhiteSpace($comparisonExplanation)) {
                return "Sequential control-then-treatment participation was observed, but the grounded pair still failed because: $comparisonExplanation"
            }

            if (-not [string]::IsNullOrWhiteSpace($pairOperatorNote)) {
                return $pairOperatorNote
            }

            return $missionExplanation
        }
        "manual-review-required" {
            if (-not [string]::IsNullOrWhiteSpace($firstAttemptExplanation)) {
                return $firstAttemptExplanation
            }

            return "The client-assisted attempt needs manual review before any grounded conservative claim can be made."
        }
        default {
            if ($MissingTargetDetails.Count -gt 0) {
                return "The client-assisted attempt stayed non-grounded because it still missed: {0}" -f ($MissingTargetDetails -join " ")
            }

            if (-not [string]::IsNullOrWhiteSpace($comparisonExplanation)) {
                return $comparisonExplanation
            }

            if (-not [string]::IsNullOrWhiteSpace($pairOperatorNote)) {
                return $pairOperatorNote
            }

            if (-not [string]::IsNullOrWhiteSpace($missionExplanation)) {
                return $missionExplanation
            }

            return $firstAttemptExplanation
        }
    }
}

function Get-HumanAttemptMarkdown {
    param([object]$Report)

    $missingTargets = @($Report.human_signal.missing_grounding_target_details)
    $lines = @(
        "# Human Participation Conservative Attempt",
        "",
        "- Attempt verdict: $($Report.attempt_verdict)",
        "- Explanation: $($Report.explanation)",
        "- Mission path used: $($Report.mission_path_used)",
        "- Mission execution path: $($Report.mission_execution_path)",
        "- Pair root: $($Report.pair_root)",
        "- First-grounded helper verdict: $($Report.first_grounded_attempt_verdict)",
        "- Client discovery verdict: $($Report.client_discovery.discovery_verdict)",
        "- Client path used: $($Report.client_discovery.client_path_used)",
        "- Client path source: $($Report.client_discovery.client_path_source)",
        "- Sequential participation: $($Report.participation.sequential)",
        "- Overlapping participation: $($Report.participation.overlapping)",
        "- Control-first gate used: $($Report.participation.control_first_gate_used)",
        "- Control-first gate auto-switch enabled: $($Report.participation.auto_switch_when_control_ready)",
        "- Treatment-hold gate used: $($Report.participation.treatment_hold_gate_used)",
        "- Treatment-hold auto-finish enabled: $($Report.participation.auto_finish_when_treatment_grounded_ready)",
        "",
        "## Sequential Phase Guidance",
        "",
        "- Helper command: $($Report.phase_flow_guidance.helper_command)",
        "- Current phase: $($Report.phase_flow_guidance.current_phase)",
        "- Current phase verdict: $($Report.phase_flow_guidance.current_phase_verdict)",
        "- Next operator action: $($Report.phase_flow_guidance.next_operator_action)",
        "- Switch to treatment allowed: $($Report.phase_flow_guidance.switch_to_treatment_allowed)",
        "- Finish grounded session allowed: $($Report.phase_flow_guidance.finish_grounded_session_allowed)",
        "- Phase explanation: $($Report.phase_flow_guidance.explanation)",
        "",
        "## Lane Participation",
        "",
        "- Control attempted: $($Report.control_lane_join.attempted)",
        "- Control helper command: $($Report.control_lane_join.helper_command)",
        "- Control launch command: $($Report.control_lane_join.launch_command)",
        "- Control client working directory: $($Report.control_lane_join.client_working_directory)",
        "- Control qconsole path: $($Report.control_lane_join.qconsole_path)",
        "- Control debug log path: $($Report.control_lane_join.debug_log_path)",
        "- Control join attempts: $($Report.control_lane_join.join_attempt_count)",
        "- Control join retry used: $($Report.control_lane_join.join_retry_used)",
        "- Control port ready: $($Report.control_lane_join.port_ready)",
        "- Control server connection seen: $($Report.control_lane_join.server_connection_seen)",
        "- Control entered the game seen: $($Report.control_lane_join.entered_the_game_seen)",
        "- Control join succeeded: $($Report.control_lane_join.join_succeeded)",
        "- Control human snapshots: $($Report.control_lane_join.human_snapshots_count)",
        "- Control human seconds: $($Report.control_lane_join.seconds_with_human_presence)",
        "- Treatment attempted: $($Report.treatment_lane_join.attempted)",
        "- Treatment helper command: $($Report.treatment_lane_join.helper_command)",
        "- Treatment launch command: $($Report.treatment_lane_join.launch_command)",
        "- Treatment client working directory: $($Report.treatment_lane_join.client_working_directory)",
        "- Treatment qconsole path: $($Report.treatment_lane_join.qconsole_path)",
        "- Treatment debug log path: $($Report.treatment_lane_join.debug_log_path)",
        "- Treatment join attempts: $($Report.treatment_lane_join.join_attempt_count)",
        "- Treatment join retry used: $($Report.treatment_lane_join.join_retry_used)",
        "- Treatment port ready: $($Report.treatment_lane_join.port_ready)",
        "- Treatment server connection seen: $($Report.treatment_lane_join.server_connection_seen)",
        "- Treatment entered the game seen: $($Report.treatment_lane_join.entered_the_game_seen)",
        "- Treatment join succeeded: $($Report.treatment_lane_join.join_succeeded)",
        "- Treatment human snapshots: $($Report.treatment_lane_join.human_snapshots_count)",
        "- Treatment human seconds: $($Report.treatment_lane_join.seconds_with_human_presence)",
        "",
        "## Control-First Switch Guidance",
        "",
        "- Switch helper command: $($Report.control_switch_guidance.helper_command)",
        "- Switch verdict at handoff: $($Report.control_switch_guidance.verdict_at_handoff)",
        "- Safe to leave control at handoff: $($Report.control_switch_guidance.safe_to_leave_control)",
        "- Control remaining snapshots at handoff: $($Report.control_switch_guidance.control_remaining_human_snapshots)",
        "- Control remaining seconds at handoff: $($Report.control_switch_guidance.control_remaining_human_presence_seconds)",
        "- Switch explanation: $($Report.control_switch_guidance.explanation)",
        "",
        "## Treatment-Hold Guidance",
        "",
        "- Helper command: $($Report.treatment_patch_guidance.helper_command)",
        "- Verdict at release: $($Report.treatment_patch_guidance.verdict_at_release)",
        "- Safe to leave treatment: $($Report.treatment_patch_guidance.safe_to_leave_treatment)",
        "- Treatment remaining snapshots at release: $($Report.treatment_patch_guidance.treatment_remaining_human_snapshots)",
        "- Treatment remaining seconds at release: $($Report.treatment_patch_guidance.treatment_remaining_human_presence_seconds)",
        "- Treatment remaining patch events at release: $($Report.treatment_patch_guidance.treatment_remaining_patch_while_human_present_events)",
        "- Treatment remaining post-patch seconds at release: $($Report.treatment_patch_guidance.treatment_remaining_post_patch_observation_seconds)",
        "- First counted human-present patch timestamp: $($Report.treatment_patch_guidance.first_human_present_patch_timestamp_utc)",
        "- First patch apply during human window timestamp: $($Report.treatment_patch_guidance.first_patch_apply_during_human_window_timestamp_utc)",
        "- Treatment-hold explanation: $($Report.treatment_patch_guidance.explanation)",
        "",
        "## Evidence Result",
        "",
        "- Control lane verdict: $($Report.control_lane_verdict)",
        "- Treatment lane verdict: $($Report.treatment_lane_verdict)",
        "- Pair classification: $($Report.pair_classification)",
        "- Certification verdict: $($Report.certification_verdict)",
        "- Counts toward promotion: $($Report.counts_toward_promotion)",
        "- Became first grounded conservative session: $($Report.became_first_grounded_conservative_session)",
        "- Reduced promotion gap: $($Report.reduced_promotion_gap)",
        "- Mission attainment verdict: $($Report.mission_attainment_verdict)",
        "- Monitor verdict: $($Report.monitor_verdict)",
        "- Final recovery verdict: $($Report.final_recovery_verdict)",
        "- Grounded consistency review required: $($Report.grounded_consistency_review_required)",
        "",
        "## Grounding Gaps",
        "",
        "- Treatment patched while humans present: $($Report.human_signal.treatment_patched_while_humans_present)",
        "- Meaningful post-patch observation window exists: $($Report.human_signal.meaningful_post_patch_observation_window_exists)",
        "- Minimum human signal thresholds met: $($Report.human_signal.minimum_human_signal_thresholds_met)"
    )

    if ($missingTargets.Count -gt 0) {
        $lines += ""
        $lines += "### Missing Target Details"
        $lines += ""
        foreach ($item in $missingTargets) {
            $lines += "- $item"
        }
    }

    $lines += @(
        "",
        "## Artifacts",
        "",
        "- Discovery JSON: $($Report.artifacts.local_client_discovery_json)",
        "- Sequential phase flow JSON: $($Report.artifacts.conservative_phase_flow_json)",
        "- Control-first switch JSON: $($Report.artifacts.control_to_treatment_switch_json)",
        "- Treatment patch window JSON: $($Report.artifacts.treatment_patch_window_json)",
        "- First grounded attempt JSON: $($Report.artifacts.first_grounded_conservative_attempt_json)",
        "- Pair summary JSON: $($Report.artifacts.pair_summary_json)",
        "- Grounded evidence certificate JSON: $($Report.artifacts.grounded_evidence_certificate_json)",
        "- Session outcome dossier JSON: $($Report.artifacts.session_outcome_dossier_json)",
        "- Mission attainment JSON: $($Report.artifacts.mission_attainment_json)",
        "- Final session docket JSON: $($Report.artifacts.final_session_docket_json)",
        "- Attempt stdout log: $($Report.artifacts.attempt_stdout_log)",
        "- Attempt stderr log: $($Report.artifacts.attempt_stderr_log)"
    )

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

$repoRoot = Get-RepoRoot
$resolvedLabRoot = if ([string]::IsNullOrWhiteSpace($LabRoot)) { Get-LabRootDefault } else { Get-AbsolutePath -Path $LabRoot -BasePath $repoRoot }
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Ensure-Directory -Path (Join-Path (Get-EvalRootDefault -LabRoot $resolvedLabRoot) "human_participation_live")
}
else {
    Ensure-Directory -Path (Get-AbsolutePath -Path $OutputRoot -BasePath $repoRoot)
}
$phaseFlowPollSeconds = [Math]::Max($ControlGatePollSeconds, $TreatmentGatePollSeconds)
$resolvedRegistryRoot = Get-RegistryRootDefault -LabRoot $resolvedLabRoot
$attemptStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$attemptStartUtc = (Get-Date).ToUniversalTime()
$attemptStdoutLog = Join-Path $resolvedOutputRoot ("human_participation_attempt-{0}.stdout.log" -f $attemptStamp)
$attemptStderrLog = Join-Path $resolvedOutputRoot ("human_participation_attempt-{0}.stderr.log" -f $attemptStamp)
$discoveryScriptPath = Join-Path $PSScriptRoot "discover_hldm_client.ps1"
$firstAttemptScriptPath = Join-Path $PSScriptRoot "run_first_grounded_conservative_attempt.ps1"
$missionArtifacts = Resolve-MissionArtifacts -ExplicitMissionPath $MissionPath -ExplicitMissionMarkdownPath $MissionMarkdownPath -ResolvedLabRoot $resolvedLabRoot
$mission = Read-JsonFile -Path $missionArtifacts.JsonPath
if ($null -eq $mission) {
    throw "Mission JSON could not be read: $($missionArtifacts.JsonPath)"
}

$controlPresenceTarget = [int][Math]::Ceiling([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_control_human_presence_seconds" -Default 60.0))
$treatmentPresenceTarget = [int][Math]::Ceiling([double](Get-ObjectPropertyValue -Object $mission -Name "target_minimum_treatment_human_presence_seconds" -Default 60.0))
if ($TreatmentStaySeconds -lt 1) {
    $TreatmentStaySeconds = [Math]::Max(15, $treatmentPresenceTarget + 10)
}

$controlPort = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "control_lane_configuration" -Default $null) -Name "port" -Default 27016)
$treatmentPort = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "treatment_lane_configuration" -Default $null) -Name "port" -Default 27017)
$missionMap = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $mission -Name "live_session_run_shape" -Default $null) -Name "map" -Default "crossfire")

$autoJoinControlEnabled = if ($PSBoundParameters.ContainsKey("AutoJoinControl")) {
    [bool]$AutoJoinControl
}
else {
    $JoinSequence -in @("ControlThenTreatment", "ControlOnly")
}
$autoJoinTreatmentEnabled = if ($PSBoundParameters.ContainsKey("AutoJoinTreatment")) {
    [bool]$AutoJoinTreatment
}
else {
    $JoinSequence -in @("ControlThenTreatment", "TreatmentOnly")
}
$autoSwitchControlEnabled = if ($PSBoundParameters.ContainsKey("AutoSwitchWhenControlReady")) {
    [bool]$AutoSwitchWhenControlReady
}
else {
    $JoinSequence -eq "ControlThenTreatment" -and $autoJoinControlEnabled -and $autoJoinTreatmentEnabled
}
$autoFinishTreatmentEnabled = if ($PSBoundParameters.ContainsKey("AutoFinishWhenTreatmentGroundedReady")) {
    [bool]$AutoFinishWhenTreatmentGroundedReady
}
else {
    $JoinSequence -eq "ControlThenTreatment" -and $autoJoinTreatmentEnabled
}
$resolvedControlStayMinimum = if ($ControlStaySecondsMinimum -gt 0) {
    $ControlStaySecondsMinimum
}
elseif ($ControlStaySeconds -gt 0) {
    $ControlStaySeconds
}
elseif (-not $autoSwitchControlEnabled) {
    [Math]::Max(15, $controlPresenceTarget + 10)
}
else {
    0
}
$resolvedTreatmentStayMinimum = if ($TreatmentStaySecondsMinimum -gt 0) {
    $TreatmentStaySecondsMinimum
}
elseif ($autoFinishTreatmentEnabled -and $TreatmentStaySeconds -gt 0) {
    $TreatmentStaySeconds
}
elseif (-not $autoFinishTreatmentEnabled -and $TreatmentStaySeconds -gt 0) {
    $TreatmentStaySeconds
}
elseif (-not $autoFinishTreatmentEnabled) {
    [Math]::Max(15, $treatmentPresenceTarget + 10)
}
else {
    0
}

$discoveryResult = & $discoveryScriptPath -ClientExePath $ClientExePath -LabRoot $resolvedLabRoot
$discoveryReportJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $discoveryResult -Name "LocalClientDiscoveryJsonPath" -Default ""))
$discoveryReportMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $discoveryResult -Name "LocalClientDiscoveryMarkdownPath" -Default ""))
$discoveryReport = Read-JsonFile -Path $discoveryReportJsonPath
if ($null -eq $discoveryReport) {
    throw "Local client discovery did not produce a readable discovery report."
}

$resolvedClientExePath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $discoveryReport -Name "client_path" -Default ""))
$clientLaunchable = [bool](Get-ObjectPropertyValue -Object $discoveryReport -Name "launchable_for_local_lane_join" -Default $false)
$clientPathSource = Get-DiscoverySourceName -DiscoveryReport $discoveryReport

$attemptProcess = $null
$pairRoot = ""
$firstAttemptResult = $null
$firstAttemptJsonPath = ""
$firstAttemptMarkdownPath = ""
$firstAttemptReport = $null
$pairSummary = $null
$certificate = $null
$missionAttainment = $null
$finalDocket = $null
$controlSwitchExecution = $null
$controlSwitchReport = $null
$controlSwitchReadyToLeave = $false
$controlSwitchExplanation = ""
$treatmentPatchExecution = $null
$treatmentPatchReport = $null
$treatmentPatchReadyToLeave = $false
$treatmentPatchExplanation = ""
$controlJoinExecution = $null
$treatmentJoinExecution = $null
$controlProcessId = 0
$treatmentProcessId = 0
$controlJoinAttempts = @()
$treatmentJoinAttempts = @()
$controlJoinAttemptCount = 0
$treatmentJoinAttemptCount = 0
$controlJoinRetryUsed = $false
$treatmentJoinRetryUsed = $false
$controlJoinRetryReason = ""
$treatmentJoinRetryReason = ""
$controlJoinRetryTriggeredAtUtc = ""
$treatmentJoinRetryTriggeredAtUtc = ""
$controlAdmissionEvidence = $null
$treatmentAdmissionEvidence = $null
$controlPortWait = $null
$treatmentPortWait = $null
$controlPortWaitFinishedAtUtc = ""
$treatmentPortWaitFinishedAtUtc = ""
$launchBlockedReason = ""

if (-not $clientLaunchable) {
    $launchBlockedReason = [string](Get-ObjectPropertyValue -Object $discoveryReport -Name "explanation" -Default "")
}
else {
    $attemptCommandParts = @(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $firstAttemptScriptPath,
        "-LabRoot",
        $resolvedLabRoot,
        "-OutputRoot",
        $resolvedOutputRoot
    )

    if ($missionArtifacts.JsonPath) {
        $attemptCommandParts += @("-MissionPath", $missionArtifacts.JsonPath)
    }
    if ($missionArtifacts.MarkdownPath) {
        $attemptCommandParts += @("-MissionMarkdownPath", $missionArtifacts.MarkdownPath)
    }

    try {
        $attemptProcess = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $attemptCommandParts[1..($attemptCommandParts.Count - 1)] `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $attemptStdoutLog `
            -RedirectStandardError $attemptStderrLog `
            -PassThru

        Write-Host "Human-participation conservative attempt:"
        Write-Host "  Mission path: $($missionArtifacts.JsonPath)"
        Write-Host "  Output root: $resolvedOutputRoot"
        Write-Host "  Background first-grounded helper PID: $($attemptProcess.Id)"
        Write-Host "  Local client discovery: $($discoveryReport.discovery_verdict)"
        Write-Host "  Client path: $resolvedClientExePath"
    }
    catch {
        $launchBlockedReason = "Could not start the first-grounded helper in the background: $($_.Exception.Message)"
    }
}

if ($attemptProcess) {
    $pairRoot = Wait-ForPairRoot -Root $resolvedOutputRoot -NotBeforeUtc $attemptStartUtc -AttemptProcess $attemptProcess -TimeoutSeconds 240
    if ($pairRoot) {
        Write-Host "  Pair root discovered: $pairRoot"
        $phaseFlowExecution = Invoke-ConservativePhaseFlowGuide -PairRoot $pairRoot -MissionPath $missionArtifacts.JsonPath -PollSeconds $phaseFlowPollSeconds
        $phaseFlowReport = Get-ObjectPropertyValue -Object $phaseFlowExecution -Name "Result" -Default $null
        if ($phaseFlowExecution.CommandText) {
            Write-Host "  Sequential phase-director: $($phaseFlowExecution.CommandText)"
        }
        if ($phaseFlowReport) {
            Write-Host "  Sequential phase verdict: $($phaseFlowReport.current_phase_verdict)"
        }
    }
    else {
        Write-Warning "The pair root was not discovered before the background attempt exited or timed out."
    }

    if ($pairRoot -and $autoJoinControlEnabled) {
        if ($ControlJoinDelaySeconds -gt 0) {
            Start-Sleep -Seconds $ControlJoinDelaySeconds
        }

        $controlPortWait = Wait-ForPortActive -Port $controlPort -Label "control" -AttemptProcess $attemptProcess -TimeoutSeconds 180
        $controlPortWaitFinishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Write-Host "  Control lane port wait: $($controlPortWait.Explanation)"
        if ($controlPortWait.Ready) {
            $controlSwitchPreview = Invoke-ControlSwitchGuide -PairRoot $pairRoot -MissionPath $missionArtifacts.JsonPath -PollSeconds $ControlGatePollSeconds
            $controlSwitchExecution = $controlSwitchPreview
            $controlSwitchReport = Get-ObjectPropertyValue -Object $controlSwitchPreview -Name "Result" -Default $null
            if ($controlSwitchExecution.CommandText) {
                Write-Host "  Control-first switch helper: $($controlSwitchExecution.CommandText)"
            }

            $controlJoinValidated = Invoke-ValidatedLaneJoin `
                -Lane "Control" `
                -PairRoot $pairRoot `
                -ResolvedClientExePath $resolvedClientExePath `
                -Port $controlPort `
                -Map $missionMap `
                -AttemptProcess $attemptProcess `
                -GraceSeconds $JoinRetryGraceSeconds `
                -RetrySpacingSeconds $JoinRetrySpacingSeconds `
                -MaxAttempts $MaxJoinAttempts `
                -AdmissionPollSeconds $JoinAdmissionPollSeconds
            $controlJoinExecution = Get-ObjectPropertyValue -Object $controlJoinValidated -Name "JoinExecution" -Default $null
            $controlJoinAttempts = @(Get-ObjectPropertyValue -Object $controlJoinValidated -Name "JoinAttempts" -Default @())
            $controlJoinAttemptCount = [int](Get-ObjectPropertyValue -Object $controlJoinValidated -Name "JoinAttemptCount" -Default 0)
            $controlJoinRetryUsed = [bool](Get-ObjectPropertyValue -Object $controlJoinValidated -Name "JoinRetryUsed" -Default $false)
            $controlJoinRetryReason = [string](Get-ObjectPropertyValue -Object $controlJoinValidated -Name "JoinRetryReason" -Default "")
            $controlJoinRetryTriggeredAtUtc = [string](Get-ObjectPropertyValue -Object $controlJoinValidated -Name "JoinRetryTriggeredAtUtc" -Default "")
            $controlAdmissionEvidence = Get-ObjectPropertyValue -Object $controlJoinValidated -Name "AdmissionEvidence" -Default $null
            if ($controlJoinExecution.Result) {
                $controlProcessId = [int](Get-ObjectPropertyValue -Object $controlJoinExecution.Result -Name "ProcessId" -Default 0)
                $controlJoinVerdict = [string](Get-ObjectPropertyValue -Object $controlJoinExecution.Result -Name "ResultVerdict" -Default "")
                Write-Host "  Control lane join helper verdict: $controlJoinVerdict"
                if ($controlJoinRetryUsed) {
                    Write-Host "  Control lane join retry used: $controlJoinRetryReason"
                }
                if ($controlAdmissionEvidence) {
                    Write-Host "  Control server connection seen: $([bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name 'server_connection_seen' -Default $false))"
                    Write-Host "  Control entered the game seen: $([bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name 'entered_the_game_seen' -Default $false))"
                }
            }
            elseif ($controlJoinExecution.Error) {
                Write-Warning "Control lane join failed: $($controlJoinExecution.Error)"
            }

            if ($controlProcessId -gt 0) {
                if ($autoSwitchControlEnabled) {
                    $controlSwitchWait = Wait-ForControlReadySwitch `
                        -PairRoot $pairRoot `
                        -MissionPath $missionArtifacts.JsonPath `
                        -PollSeconds $ControlGatePollSeconds `
                        -MinimumStaySeconds $resolvedControlStayMinimum `
                        -AttemptProcess $attemptProcess
                    $controlSwitchExecution = Get-ObjectPropertyValue -Object $controlSwitchWait -Name "GuideExecution" -Default $controlSwitchExecution
                    $controlSwitchReport = Get-ObjectPropertyValue -Object $controlSwitchExecution -Name "Result" -Default $null
                    $controlSwitchReadyToLeave = [bool](Get-ObjectPropertyValue -Object $controlSwitchWait -Name "ReadyToSwitch" -Default $false)
                    $controlSwitchExplanation = [string](Get-ObjectPropertyValue -Object $controlSwitchWait -Name "Explanation" -Default "")

                    if ($controlSwitchReadyToLeave) {
                        Stop-ClientProcessIfRunning -ProcessId $controlProcessId -Reason "control-first gate cleared" | Out-Null
                    }
                    else {
                        Write-Warning "Control-first gate did not clear before the control lane ended or timed out: $controlSwitchExplanation"
                        Stop-ClientProcessIfRunning -ProcessId $controlProcessId -Reason "control lane gate blocked" | Out-Null
                    }

                    if ($pairRoot) {
                        $phaseFlowExecution = Invoke-ConservativePhaseFlowGuide -PairRoot $pairRoot -MissionPath $missionArtifacts.JsonPath -PollSeconds $phaseFlowPollSeconds
                        $phaseFlowReport = Get-ObjectPropertyValue -Object $phaseFlowExecution -Name "Result" -Default $phaseFlowReport
                    }
                }
                elseif ($resolvedControlStayMinimum -gt 0) {
                    Start-Sleep -Seconds $resolvedControlStayMinimum
                    Stop-ClientProcessIfRunning -ProcessId $controlProcessId -Reason "control lane stay complete" | Out-Null
                }
            }
        }
        else {
            $controlJoinExecution = [pscustomobject]@{
                Attempted = $true
                CommandText = ""
                Error = $controlPortWait.Explanation
                Result = $null
            }
        }
    }

    if ($pairRoot -and $autoJoinTreatmentEnabled -and (-not $autoSwitchControlEnabled -or $controlSwitchReadyToLeave -or $JoinSequence -ne "ControlThenTreatment")) {
        if ($TreatmentJoinDelaySeconds -gt 0) {
            Start-Sleep -Seconds $TreatmentJoinDelaySeconds
        }

        $treatmentPortWait = Wait-ForPortActive -Port $treatmentPort -Label "treatment" -AttemptProcess $attemptProcess -TimeoutSeconds 300
        $treatmentPortWaitFinishedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Write-Host "  Treatment lane port wait: $($treatmentPortWait.Explanation)"
        if ($treatmentPortWait.Ready) {
            $treatmentPatchPreview = Invoke-TreatmentPatchGuide -PairRoot $pairRoot -MissionPath $missionArtifacts.JsonPath -PollSeconds $TreatmentGatePollSeconds
            $treatmentPatchExecution = $treatmentPatchPreview
            $treatmentPatchReport = Get-ObjectPropertyValue -Object $treatmentPatchPreview -Name "Result" -Default $null
            if ($treatmentPatchExecution.CommandText) {
                Write-Host "  Treatment-hold helper: $($treatmentPatchExecution.CommandText)"
            }

            $treatmentJoinValidated = Invoke-ValidatedLaneJoin `
                -Lane "Treatment" `
                -PairRoot $pairRoot `
                -ResolvedClientExePath $resolvedClientExePath `
                -Port $treatmentPort `
                -Map $missionMap `
                -AttemptProcess $attemptProcess `
                -GraceSeconds $JoinRetryGraceSeconds `
                -RetrySpacingSeconds $JoinRetrySpacingSeconds `
                -MaxAttempts $MaxJoinAttempts `
                -AdmissionPollSeconds $JoinAdmissionPollSeconds
            $treatmentJoinExecution = Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "JoinExecution" -Default $null
            $treatmentJoinAttempts = @(Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "JoinAttempts" -Default @())
            $treatmentJoinAttemptCount = [int](Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "JoinAttemptCount" -Default 0)
            $treatmentJoinRetryUsed = [bool](Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "JoinRetryUsed" -Default $false)
            $treatmentJoinRetryReason = [string](Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "JoinRetryReason" -Default "")
            $treatmentJoinRetryTriggeredAtUtc = [string](Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "JoinRetryTriggeredAtUtc" -Default "")
            $treatmentAdmissionEvidence = Get-ObjectPropertyValue -Object $treatmentJoinValidated -Name "AdmissionEvidence" -Default $null
            if ($treatmentJoinExecution.Result) {
                $treatmentProcessId = [int](Get-ObjectPropertyValue -Object $treatmentJoinExecution.Result -Name "ProcessId" -Default 0)
                $treatmentJoinVerdict = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution.Result -Name "ResultVerdict" -Default "")
                Write-Host "  Treatment lane join helper verdict: $treatmentJoinVerdict"
                if ($treatmentJoinRetryUsed) {
                    Write-Host "  Treatment lane join retry used: $treatmentJoinRetryReason"
                }
                if ($treatmentAdmissionEvidence) {
                    Write-Host "  Treatment server connection seen: $([bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name 'server_connection_seen' -Default $false))"
                    Write-Host "  Treatment entered the game seen: $([bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name 'entered_the_game_seen' -Default $false))"
                }
            }
            elseif ($treatmentJoinExecution.Error) {
                Write-Warning "Treatment lane join failed: $($treatmentJoinExecution.Error)"
            }

            if ($treatmentProcessId -gt 0) {
                if ($autoFinishTreatmentEnabled) {
                    $treatmentPatchWait = Wait-ForTreatmentGroundedReady `
                        -PairRoot $pairRoot `
                        -MissionPath $missionArtifacts.JsonPath `
                        -PollSeconds $TreatmentGatePollSeconds `
                        -MinimumStaySeconds $resolvedTreatmentStayMinimum `
                        -AttemptProcess $attemptProcess
                    $treatmentPatchExecution = Get-ObjectPropertyValue -Object $treatmentPatchWait -Name "GuideExecution" -Default $treatmentPatchExecution
                    $treatmentPatchReport = Get-ObjectPropertyValue -Object $treatmentPatchExecution -Name "Result" -Default $null
                    $treatmentPatchReadyToLeave = [bool](Get-ObjectPropertyValue -Object $treatmentPatchWait -Name "ReadyToFinish" -Default $false)
                    $treatmentPatchExplanation = [string](Get-ObjectPropertyValue -Object $treatmentPatchWait -Name "Explanation" -Default "")

                    if ($treatmentPatchReadyToLeave) {
                        Stop-ClientProcessIfRunning -ProcessId $treatmentProcessId -Reason "treatment-hold gate cleared" | Out-Null
                    }
                    else {
                        Write-Warning "Treatment-hold gate did not clear before the treatment lane ended or timed out: $treatmentPatchExplanation"
                        Stop-ClientProcessIfRunning -ProcessId $treatmentProcessId -Reason "treatment lane gate blocked" | Out-Null
                    }

                    if ($pairRoot) {
                        $phaseFlowExecution = Invoke-ConservativePhaseFlowGuide -PairRoot $pairRoot -MissionPath $missionArtifacts.JsonPath -PollSeconds $phaseFlowPollSeconds
                        $phaseFlowReport = Get-ObjectPropertyValue -Object $phaseFlowExecution -Name "Result" -Default $phaseFlowReport
                    }
                }
                elseif ($resolvedTreatmentStayMinimum -gt 0) {
                    Start-Sleep -Seconds $resolvedTreatmentStayMinimum
                    Stop-ClientProcessIfRunning -ProcessId $treatmentProcessId -Reason "treatment lane stay complete" | Out-Null
                }
            }
        }
        else {
            $treatmentJoinExecution = [pscustomobject]@{
                Attempted = $true
                CommandText = ""
                Error = $treatmentPortWait.Explanation
                Result = $null
            }
        }
    }
    elseif ($pairRoot -and $autoJoinTreatmentEnabled -and $autoSwitchControlEnabled -and -not $controlSwitchReadyToLeave -and $JoinSequence -eq "ControlThenTreatment") {
        Write-Warning "Skipping automatic treatment join because the control-first switch gate never cleared."
    }

    try {
        Wait-Process -Id $attemptProcess.Id -Timeout 1800 -ErrorAction Stop
    }
    catch {
        throw "The background conservative attempt did not finish inside the safety timeout: $($_.Exception.Message)"
    }

    Stop-ClientProcessIfRunning -ProcessId $controlProcessId -Reason "final control cleanup" | Out-Null
    Stop-ClientProcessIfRunning -ProcessId $treatmentProcessId -Reason "final treatment cleanup" | Out-Null
}

if (-not $pairRoot) {
    $pairRoot = Find-NewPairRoot -Root $resolvedOutputRoot -NotBeforeUtc $attemptStartUtc
}

if ($pairRoot) {
    $firstAttemptJsonPath = Resolve-ExistingPath -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.json")
    $firstAttemptMarkdownPath = Resolve-ExistingPath -Path (Join-Path $pairRoot "first_grounded_conservative_attempt.md")
    if ($firstAttemptJsonPath) {
        $firstAttemptReport = Read-JsonFile -Path $firstAttemptJsonPath
    }

    $pairSummary = Read-JsonFile -Path (Join-Path $pairRoot "pair_summary.json")
    $certificate = Read-JsonFile -Path (Join-Path $pairRoot "grounded_evidence_certificate.json")
    $missionAttainment = Read-JsonFile -Path (Join-Path $pairRoot "mission_attainment.json")
    $finalDocket = Read-JsonFile -Path (Join-Path $pairRoot "guided_session\final_session_docket.json")
}

$outputPaths = Get-ReportPaths -PairRoot $pairRoot -ResolvedRegistryRoot $resolvedRegistryRoot -Stamp $attemptStamp
$promotionGapDelta = if ($pairRoot) { Read-JsonFile -Path (Join-Path $pairRoot "promotion_gap_delta.json") } else { $null }
$pairSummaryPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "pair_summary.json") } else { "" }
$certificatePath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "grounded_evidence_certificate.json") } else { "" }
$dossierPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "session_outcome_dossier.json") } else { "" }
$missionAttainmentPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "mission_attainment.json") } else { "" }
$finalDocketPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "guided_session\final_session_docket.json") } else { "" }
$missionExecutionPath = if ($pairRoot) { Resolve-ExistingPath -Path (Join-Path $pairRoot "guided_session\mission_execution.json") } else { "" }
$controlLane = Get-ObjectPropertyValue -Object $pairSummary -Name "control_lane" -Default $null
$treatmentLane = Get-ObjectPropertyValue -Object $pairSummary -Name "treatment_lane" -Default $null
$comparison = Get-ObjectPropertyValue -Object $pairSummary -Name "comparison" -Default $null
$controlHumanSnapshots = [int](Get-ObjectPropertyValue -Object $controlLane -Name "human_snapshots_count" -Default 0)
$treatmentHumanSnapshots = [int](Get-ObjectPropertyValue -Object $treatmentLane -Name "human_snapshots_count" -Default 0)
$controlHumanSeconds = [double](Get-ObjectPropertyValue -Object $controlLane -Name "seconds_with_human_presence" -Default 0.0)
$treatmentHumanSeconds = [double](Get-ObjectPropertyValue -Object $treatmentLane -Name "seconds_with_human_presence" -Default 0.0)
$controlHumanSignal = $controlHumanSnapshots -gt 0 -or $controlHumanSeconds -gt 0.0
$treatmentHumanSignal = $treatmentHumanSnapshots -gt 0 -or $treatmentHumanSeconds -gt 0.0
$countsTowardPromotion = [bool](Get-ObjectPropertyValue -Object $certificate -Name "counts_toward_promotion" -Default $false)
$createdFirstGrounded = [bool](Get-ObjectPropertyValue -Object $promotionGapDelta -Name "created_first_grounded_conservative_session" -Default $false)
$reducedPromotionGap = [bool](Get-ObjectPropertyValue -Object $promotionGapDelta -Name "reduced_promotion_gap" -Default $false)
$finalRecoveryVerdict = [string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "final_recovery_verdict" -Default "")
$manualReviewRequired = $finalRecoveryVerdict -eq "session-manual-review-needed"
$interruptedAndRecovered = [bool](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "interrupted_and_recovered" -Default $false)
$missionVerdict = [string](Get-ObjectPropertyValue -Object $missionAttainment -Name "mission_verdict" -Default "")
$finalDocketMonitor = Get-ObjectPropertyValue -Object $finalDocket -Name "monitor" -Default $null
$monitorVerdict = [string](Get-ObjectPropertyValue -Object $finalDocketMonitor -Name "last_verdict" -Default "")

$missingTargetDetails = New-Object System.Collections.Generic.List[string]
$targetResults = Get-ObjectPropertyValue -Object $missionAttainment -Name "target_results" -Default $null
if (-not $countsTowardPromotion -and $null -ne $targetResults) {
    foreach ($property in $targetResults.PSObject.Properties) {
        $target = $property.Value
        if (-not [bool](Get-ObjectPropertyValue -Object $target -Name "met" -Default $false)) {
            $explanation = [string](Get-ObjectPropertyValue -Object $target -Name "explanation" -Default "")
            if (-not [string]::IsNullOrWhiteSpace($explanation)) {
                $missingTargetDetails.Add($explanation) | Out-Null
            }
        }
    }
}

$attemptVerdict = Get-HumanAttemptVerdict `
    -ClientLaunchable $clientLaunchable `
    -ManualReviewRequired $manualReviewRequired `
    -CountsTowardPromotion $countsTowardPromotion `
    -CreatedFirstGroundedConservativeSession $createdFirstGrounded `
    -ReducedPromotionGap $reducedPromotionGap `
    -InterruptedAndRecovered $interruptedAndRecovered `
    -ControlHumanSignal $controlHumanSignal `
    -TreatmentHumanSignal $treatmentHumanSignal `
    -JoinSequence $JoinSequence `
    -MissionVerdict $missionVerdict

$explanation = Get-HumanAttemptExplanation `
    -AttemptVerdict $attemptVerdict `
    -DiscoveryReport $discoveryReport `
    -FirstAttemptReport $firstAttemptReport `
    -MissionAttainment $missionAttainment `
    -PairSummary $pairSummary `
    -MissingTargetDetails @($missingTargetDetails)

$controlSwitchGuidanceExplanation = if (-not [string]::IsNullOrWhiteSpace($controlSwitchExplanation)) {
    $controlSwitchExplanation
}
else {
    [string](Get-ObjectPropertyValue -Object $controlSwitchReport -Name "explanation" -Default "")
}
$controlSwitchArtifacts = Get-ObjectPropertyValue -Object $controlSwitchReport -Name "artifacts" -Default $null
$controlSwitchJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlSwitchArtifacts -Name "control_to_treatment_switch_json" -Default ""))
$controlSwitchMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $controlSwitchArtifacts -Name "control_to_treatment_switch_markdown" -Default ""))
$treatmentPatchGuidanceExplanation = if (-not [string]::IsNullOrWhiteSpace($treatmentPatchExplanation)) {
    $treatmentPatchExplanation
}
else {
    [string](Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "explanation" -Default "")
}
$treatmentPatchArtifacts = Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "artifacts" -Default $null
$treatmentPatchJsonFallback = if ($pairRoot) { Join-Path $pairRoot "treatment_patch_window.json" } else { "" }
$treatmentPatchMarkdownFallback = if ($pairRoot) { Join-Path $pairRoot "treatment_patch_window.md" } else { "" }
$treatmentPatchJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentPatchArtifacts -Name "treatment_patch_window_json" -Default $treatmentPatchJsonFallback))
$treatmentPatchMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $treatmentPatchArtifacts -Name "treatment_patch_window_markdown" -Default $treatmentPatchMarkdownFallback))
if (-not $treatmentPatchReport -and $treatmentPatchJsonPath) {
    $treatmentPatchReport = Read-JsonFile -Path $treatmentPatchJsonPath
    $treatmentPatchArtifacts = Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "artifacts" -Default $null
}
$phaseFlowJsonFallback = if ($pairRoot) { Join-Path $pairRoot "conservative_phase_flow.json" } else { "" }
$phaseFlowMarkdownFallback = if ($pairRoot) { Join-Path $pairRoot "conservative_phase_flow.md" } else { "" }
if (-not $phaseFlowReport -and $pairRoot) {
    $phaseFlowExecution = Invoke-ConservativePhaseFlowGuide -PairRoot $pairRoot -MissionPath $missionArtifacts.JsonPath -PollSeconds $phaseFlowPollSeconds
    $phaseFlowReport = Get-ObjectPropertyValue -Object $phaseFlowExecution -Name "Result" -Default $null
}
$phaseFlowArtifacts = Get-ObjectPropertyValue -Object $phaseFlowReport -Name "artifacts" -Default $null
$phaseFlowJsonPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $phaseFlowArtifacts -Name "conservative_phase_flow_json" -Default $phaseFlowJsonFallback))
$phaseFlowMarkdownPath = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $phaseFlowArtifacts -Name "conservative_phase_flow_markdown" -Default $phaseFlowMarkdownFallback))
if (-not $phaseFlowReport -and $phaseFlowJsonPath) {
    $phaseFlowReport = Read-JsonFile -Path $phaseFlowJsonPath
    $phaseFlowArtifacts = Get-ObjectPropertyValue -Object $phaseFlowReport -Name "artifacts" -Default $null
}
$phaseFlowExplanation = [string](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "explanation" -Default "")
$phaseFlowFinishAllowed = [bool](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "finish_grounded_session_allowed" -Default $false)
$phaseFlowVerdict = [string](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "current_phase_verdict" -Default "")
$groundedConsistencyIssues = New-Object System.Collections.Generic.List[string]
if ($countsTowardPromotion -and -not $phaseFlowFinishAllowed) {
    $groundedConsistencyIssues.Add("Phase-director finish gate stayed closed with verdict '$phaseFlowVerdict'.") | Out-Null
}
if ($countsTowardPromotion -and $monitorVerdict -notin @("sufficient-for-tuning-usable-review", "sufficient-for-scorecard")) {
    $groundedConsistencyIssues.Add("Live monitor never reached a sufficient stop verdict and ended as '$monitorVerdict'.") | Out-Null
}
if ($countsTowardPromotion -and $missionVerdict -like "mission-failed*") {
    $groundedConsistencyIssues.Add("Mission-attainment still reports '$missionVerdict'.") | Out-Null
}
$groundedConsistencyReviewRequired = $groundedConsistencyIssues.Count -gt 0
if ($groundedConsistencyReviewRequired) {
    $manualReviewRequired = $true
    $attemptVerdict = "manual-review-required"
    $explanation = "The client-assisted attempt produced evidence that certification counted toward promotion, but the mission/phase evidence is still inconsistent: $($groundedConsistencyIssues -join ' ') Manual review is required before treating this as a clean grounded conservative capture."
}

$report = [ordered]@{
    schema_version = 1
    prompt_id = Get-RepoPromptId
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    source_commit_sha = Get-RepoHeadCommitSha
    attempt_verdict = $attemptVerdict
    explanation = $explanation
    mission_path_used = $missionArtifacts.JsonPath
    mission_markdown_path_used = $missionArtifacts.MarkdownPath
    mission_execution_path = Resolve-ExistingPath -Path ([string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "mission_execution_path" -Default ""))
    pair_root = $pairRoot
    first_grounded_attempt_verdict = [string](Get-ObjectPropertyValue -Object $firstAttemptReport -Name "attempt_verdict" -Default "")
    client_discovery = [ordered]@{
        discovery_verdict = [string](Get-ObjectPropertyValue -Object $discoveryReport -Name "discovery_verdict" -Default "")
        client_path_used = $resolvedClientExePath
        client_path_source = $clientPathSource
        launchable_for_local_lane_join = $clientLaunchable
        client_working_directory = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ClientWorkingDirectory" -Default "")
        qconsole_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "QConsolePath" -Default "")
        debug_log_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "DebugLogPath" -Default "")
        explanation = [string](Get-ObjectPropertyValue -Object $discoveryReport -Name "explanation" -Default "")
        discovery_json = $discoveryReportJsonPath
        discovery_markdown = $discoveryReportMarkdownPath
    }
    participation = [ordered]@{
        join_sequence = $JoinSequence
        sequential = $JoinSequence -eq "ControlThenTreatment" -and $autoJoinControlEnabled -and $autoJoinTreatmentEnabled
        overlapping = $false
        local_client_launch_bounded_test_only = $false
        control_first_gate_used = $autoSwitchControlEnabled
        auto_switch_when_control_ready = $autoSwitchControlEnabled
        treatment_hold_gate_used = $autoFinishTreatmentEnabled
        auto_finish_when_treatment_grounded_ready = $autoFinishTreatmentEnabled
    }
    phase_flow_guidance = [ordered]@{
        helper_command = [string](Get-ObjectPropertyValue -Object $phaseFlowExecution -Name "CommandText" -Default "")
        current_phase = [string](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "current_phase" -Default "")
        current_phase_verdict = [string](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "current_phase_verdict" -Default "")
        next_operator_action = [string](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "next_operator_action" -Default "")
        switch_to_treatment_allowed = [bool](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "switch_to_treatment_allowed" -Default $false)
        finish_grounded_session_allowed = [bool](Get-ObjectPropertyValue -Object $phaseFlowReport -Name "finish_grounded_session_allowed" -Default $false)
        explanation = $phaseFlowExplanation
        poll_seconds = $phaseFlowPollSeconds
    }
    control_lane_join = [ordered]@{
        attempted = [bool]($null -ne $controlJoinExecution)
        auto_launch = $autoJoinControlEnabled
        helper_command = [string](Get-ObjectPropertyValue -Object $controlJoinExecution -Name "CommandText" -Default "")
        helper_result_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ResultVerdict" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "LaunchCommand" -Default "")
        launch_started_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "LaunchStartedAtUtc" -Default "")
        client_working_directory = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ClientWorkingDirectory" -Default "")
        qconsole_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "QConsolePath" -Default "")
        debug_log_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "DebugLogPath" -Default "")
        launch_started = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0) -gt 0
        join_succeeded = $controlHumanSignal
        join_target = [string](Get-ObjectPropertyValue -Object $controlLane -Name "join_target" -Default ("127.0.0.1:{0}" -f $controlPort))
        process_id = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0)
        join_attempt_count = $controlJoinAttemptCount
        join_retry_used = $controlJoinRetryUsed
        join_retry_reason = $controlJoinRetryReason
        join_retry_triggered_at_utc = $controlJoinRetryTriggeredAtUtc
        join_attempts = @($controlJoinAttempts)
        port_ready = [bool](Get-ObjectPropertyValue -Object $controlPortWait -Name "Ready" -Default $false)
        port_wait_finished_at_utc = $controlPortWaitFinishedAtUtc
        port_wait_explanation = [string](Get-ObjectPropertyValue -Object $controlPortWait -Name "Explanation" -Default "")
        lane_root = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "lane_root" -Default ([string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_root" -Default "")))
        hlds_stdout_log = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "hlds_stdout_log" -Default "")
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "server_connection_seen" -Default $false)
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "entered_the_game_seen" -Default $false)
        first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "first_server_connection_seen_at_utc" -Default "")
        first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "first_entered_the_game_seen_at_utc" -Default "")
        client_process_observed_running = [bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "client_process_observed_running" -Default $false)
        process_alive_first_seen_at_utc = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "process_alive_first_seen_at_utc" -Default "")
        process_alive_last_seen_at_utc = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "process_alive_last_seen_at_utc" -Default "")
        process_exit_observed_at_utc = [string](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "process_exit_observed_at_utc" -Default "")
        process_runtime_seconds = Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "process_runtime_seconds" -Default $null
        exited_before_server_connect = [bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "exited_before_server_connect" -Default $false)
        exited_before_entered_game = [bool](Get-ObjectPropertyValue -Object $controlAdmissionEvidence -Name "exited_before_entered_game" -Default $false)
        stay_seconds = $resolvedControlStayMinimum
        human_snapshots_count = $controlHumanSnapshots
        seconds_with_human_presence = $controlHumanSeconds
        error = [string](Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Error" -Default "")
    }
    treatment_lane_join = [ordered]@{
        attempted = [bool]($null -ne $treatmentJoinExecution)
        auto_launch = $autoJoinTreatmentEnabled
        helper_command = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "CommandText" -Default "")
        helper_result_verdict = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ResultVerdict" -Default "")
        launch_command = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "LaunchCommand" -Default "")
        launch_started_at_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "LaunchStartedAtUtc" -Default "")
        client_working_directory = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ClientWorkingDirectory" -Default "")
        qconsole_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "QConsolePath" -Default "")
        debug_log_path = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "DebugLogPath" -Default "")
        launch_started = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0) -gt 0
        join_succeeded = $treatmentHumanSignal
        join_target = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "join_target" -Default ("127.0.0.1:{0}" -f $treatmentPort))
        process_id = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Result" -Default $null) -Name "ProcessId" -Default 0)
        join_attempt_count = $treatmentJoinAttemptCount
        join_retry_used = $treatmentJoinRetryUsed
        join_retry_reason = $treatmentJoinRetryReason
        join_retry_triggered_at_utc = $treatmentJoinRetryTriggeredAtUtc
        join_attempts = @($treatmentJoinAttempts)
        port_ready = [bool](Get-ObjectPropertyValue -Object $treatmentPortWait -Name "Ready" -Default $false)
        port_wait_finished_at_utc = $treatmentPortWaitFinishedAtUtc
        port_wait_explanation = [string](Get-ObjectPropertyValue -Object $treatmentPortWait -Name "Explanation" -Default "")
        lane_root = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "lane_root" -Default ([string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_root" -Default "")))
        hlds_stdout_log = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "hlds_stdout_log" -Default "")
        server_connection_seen = [bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "server_connection_seen" -Default $false)
        entered_the_game_seen = [bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "entered_the_game_seen" -Default $false)
        first_server_connection_seen_at_utc = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "first_server_connection_seen_at_utc" -Default "")
        first_entered_the_game_seen_at_utc = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "first_entered_the_game_seen_at_utc" -Default "")
        client_process_observed_running = [bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "client_process_observed_running" -Default $false)
        process_alive_first_seen_at_utc = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "process_alive_first_seen_at_utc" -Default "")
        process_alive_last_seen_at_utc = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "process_alive_last_seen_at_utc" -Default "")
        process_exit_observed_at_utc = [string](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "process_exit_observed_at_utc" -Default "")
        process_runtime_seconds = Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "process_runtime_seconds" -Default $null
        exited_before_server_connect = [bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "exited_before_server_connect" -Default $false)
        exited_before_entered_game = [bool](Get-ObjectPropertyValue -Object $treatmentAdmissionEvidence -Name "exited_before_entered_game" -Default $false)
        stay_seconds = $TreatmentStaySeconds
        human_snapshots_count = $treatmentHumanSnapshots
        seconds_with_human_presence = $treatmentHumanSeconds
        error = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Error" -Default "")
    }
    control_switch_guidance = [ordered]@{
        helper_command = [string](Get-ObjectPropertyValue -Object $controlSwitchExecution -Name "CommandText" -Default "")
        verdict_at_handoff = [string](Get-ObjectPropertyValue -Object $controlSwitchReport -Name "current_switch_verdict" -Default "")
        safe_to_leave_control = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSwitchReport -Name "control_lane" -Default $null) -Name "safe_to_leave" -Default $false)
        control_remaining_human_snapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSwitchReport -Name "control_lane" -Default $null) -Name "remaining_human_snapshots" -Default 0)
        control_remaining_human_presence_seconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $controlSwitchReport -Name "control_lane" -Default $null) -Name "remaining_human_presence_seconds" -Default 0.0)
        explanation = $controlSwitchGuidanceExplanation
        minimum_stay_seconds = $resolvedControlStayMinimum
        poll_seconds = $ControlGatePollSeconds
    }
    treatment_patch_guidance = [ordered]@{
        helper_command = [string](Get-ObjectPropertyValue -Object $treatmentPatchExecution -Name "CommandText" -Default "")
        verdict_at_release = [string](Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "current_verdict" -Default "")
        safe_to_leave_treatment = [bool](Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_safe_to_leave" -Default $false)
        treatment_remaining_human_snapshots = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_lane" -Default $null) -Name "remaining_human_snapshots" -Default 0)
        treatment_remaining_human_presence_seconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_lane" -Default $null) -Name "remaining_human_presence_seconds" -Default 0.0)
        treatment_remaining_patch_while_human_present_events = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_lane" -Default $null) -Name "remaining_patch_while_human_present_events" -Default 0)
        treatment_remaining_post_patch_observation_seconds = [double](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_lane" -Default $null) -Name "remaining_post_patch_observation_seconds" -Default 0.0)
        first_human_present_patch_timestamp_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_lane" -Default $null) -Name "first_human_present_patch_timestamp_utc" -Default "")
        first_patch_apply_during_human_window_timestamp_utc = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $treatmentPatchReport -Name "treatment_lane" -Default $null) -Name "first_patch_apply_during_human_window_timestamp_utc" -Default "")
        explanation = $treatmentPatchGuidanceExplanation
        minimum_stay_seconds = $resolvedTreatmentStayMinimum
        poll_seconds = $TreatmentGatePollSeconds
    }
    control_lane_verdict = [string](Get-ObjectPropertyValue -Object $controlLane -Name "lane_verdict" -Default "")
    treatment_lane_verdict = [string](Get-ObjectPropertyValue -Object $treatmentLane -Name "lane_verdict" -Default "")
    pair_classification = [string](Get-ObjectPropertyValue -Object $pairSummary -Name "operator_note_classification" -Default "")
    certification_verdict = [string](Get-ObjectPropertyValue -Object $certificate -Name "certification_verdict" -Default "")
    counts_toward_promotion = $countsTowardPromotion
    became_first_grounded_conservative_session = $createdFirstGrounded
    reduced_promotion_gap = $reducedPromotionGap
    mission_attainment_verdict = $missionVerdict
    monitor_verdict = $monitorVerdict
    final_recovery_verdict = $finalRecoveryVerdict
    grounded_consistency_review_required = $groundedConsistencyReviewRequired
    grounded_consistency_issues = @([string[]]$groundedConsistencyIssues.ToArray())
    human_signal = [ordered]@{
        control_human_snapshots_count = $controlHumanSnapshots
        control_seconds_with_human_presence = $controlHumanSeconds
        treatment_human_snapshots_count = $treatmentHumanSnapshots
        treatment_seconds_with_human_presence = $treatmentHumanSeconds
        treatment_patched_while_humans_present = [bool](Get-ObjectPropertyValue -Object $comparison -Name "treatment_patched_while_humans_present" -Default $false)
        meaningful_post_patch_observation_window_exists = [bool](Get-ObjectPropertyValue -Object $comparison -Name "meaningful_post_patch_observation_window_exists" -Default $false)
        minimum_human_signal_thresholds_met = [bool](Get-ObjectPropertyValue -Object $certificate -Name "minimum_human_signal_thresholds_met" -Default $false)
        missing_grounding_targets = @([string[]](Get-ObjectPropertyValue -Object $missionAttainment -Name "targets_missed" -Default @()))
        missing_grounding_target_details = @($missingTargetDetails)
    }
    closeout_stack_reused = Get-ObjectPropertyValue -Object $firstAttemptReport -Name "closeout_stack_reused" -Default $null
    artifacts = [ordered]@{
        human_participation_conservative_attempt_json = $outputPaths.JsonPath
        human_participation_conservative_attempt_markdown = $outputPaths.MarkdownPath
        local_client_discovery_json = $discoveryReportJsonPath
        local_client_discovery_markdown = $discoveryReportMarkdownPath
        conservative_phase_flow_json = $phaseFlowJsonPath
        conservative_phase_flow_markdown = $phaseFlowMarkdownPath
        control_to_treatment_switch_json = $controlSwitchJsonPath
        control_to_treatment_switch_markdown = $controlSwitchMarkdownPath
        treatment_patch_window_json = $treatmentPatchJsonPath
        treatment_patch_window_markdown = $treatmentPatchMarkdownPath
        first_grounded_conservative_attempt_json = $firstAttemptJsonPath
        first_grounded_conservative_attempt_markdown = $firstAttemptMarkdownPath
        pair_summary_json = $pairSummaryPath
        grounded_evidence_certificate_json = $certificatePath
        session_outcome_dossier_json = $dossierPath
        mission_attainment_json = $missionAttainmentPath
        final_session_docket_json = $finalDocketPath
        mission_execution_json = $missionExecutionPath
        attempt_stdout_log = Resolve-ExistingPath -Path $attemptStdoutLog
        attempt_stderr_log = Resolve-ExistingPath -Path $attemptStderrLog
    }
    errors = [ordered]@{
        launch_blocked_reason = $launchBlockedReason
        control_join_error = [string](Get-ObjectPropertyValue -Object $controlJoinExecution -Name "Error" -Default "")
        treatment_join_error = [string](Get-ObjectPropertyValue -Object $treatmentJoinExecution -Name "Error" -Default "")
    }
}

Write-JsonFile -Path $outputPaths.JsonPath -Value $report
$reportForMarkdown = Read-JsonFile -Path $outputPaths.JsonPath
Write-TextFile -Path $outputPaths.MarkdownPath -Value (Get-HumanAttemptMarkdown -Report $reportForMarkdown)

Write-Host "Human-participation conservative attempt:"
Write-Host "  Attempt verdict: $($report.attempt_verdict)"
Write-Host "  Pair root: $($report.pair_root)"
Write-Host "  Control join succeeded: $($report.control_lane_join.join_succeeded)"
Write-Host "  Control-first switch verdict: $($report.control_switch_guidance.verdict_at_handoff)"
Write-Host "  Treatment join succeeded: $($report.treatment_lane_join.join_succeeded)"
Write-Host "  Treatment-hold verdict: $($report.treatment_patch_guidance.verdict_at_release)"
Write-Host "  Certification verdict: $($report.certification_verdict)"
Write-Host "  Counts toward promotion: $($report.counts_toward_promotion)"
Write-Host "  Attempt report JSON: $($outputPaths.JsonPath)"
Write-Host "  Attempt report Markdown: $($outputPaths.MarkdownPath)"

[pscustomobject]@{
    PairRoot = $pairRoot
    HumanParticipationConservativeAttemptJsonPath = $outputPaths.JsonPath
    HumanParticipationConservativeAttemptMarkdownPath = $outputPaths.MarkdownPath
    AttemptVerdict = $report.attempt_verdict
    CertificationVerdict = $report.certification_verdict
    CountsTowardPromotion = $report.counts_toward_promotion
}
