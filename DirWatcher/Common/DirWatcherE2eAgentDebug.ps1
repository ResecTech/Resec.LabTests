#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-DirWatcherE2eDebugBaseUrl {
    param([string] $Override = '')

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:DIRWATCHER_E2E_DEBUG_BASE_URL)) {
        return $env:DIRWATCHER_E2E_DEBUG_BASE_URL.TrimEnd('/')
    }

    if (Get-Command Get-LabOptionalPath -ErrorAction SilentlyContinue) {
        $fromConfig = Get-LabOptionalPath -SettingName 'dirWatcherDebugBaseUrl' -EnvironmentVariable 'DIRWATCHER_E2E_DEBUG_BASE_URL'
        if (-not [string]::IsNullOrWhiteSpace($fromConfig)) {
            return $fromConfig.TrimEnd('/')
        }
    }

    return 'http://127.0.0.1:4506'
}

function Invoke-DirWatcherE2eDebugHook {
    param(
        [Parameter(Mandatory)]
        [string] $Command,
        [string] $Message = '',
        [string] $BaseUrl = ''
    )

    $root = Get-DirWatcherE2eDebugBaseUrl -Override $BaseUrl
    $query = 'command=' + [Uri]::EscapeDataString($Command)
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $query += '&message=' + [Uri]::EscapeDataString($Message)
    }

    $uri = '{0}/debug/hook?{1}' -f $root, $query

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($attempt in @('rest', 'curl')) {
        try {
            if ($attempt -eq 'rest') {
                return Invoke-RestMethod -Uri $uri -Method Get -UseBasicParsing
            }

            $curlJson = Invoke-DirWatcherE2eDebugHookViaCurl -Uri $uri
            if ($null -ne $curlJson) {
                return $curlJson
            }
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
    }

    $hint = 'Ensure DirWatcher runs with debug enabled (appsettings EnableDebugInterface or env DIRWATCHER_ENABLE_DEBUG_INTERFACE=true) on port 4506.'
    throw "DirWatcher debug hook failed (command=$Command, url=$root): $($errors -join '; '). $hint"
}

function Invoke-DirWatcherE2eDebugHookViaCurl {
    param([Parameter(Mandatory)][string] $Uri)

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        return $null
    }

    $raw = & curl.exe -sS -f $Uri 2>$null
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function Test-DirWatcherE2eDebugHookReachable {
    param([string] $BaseUrl = '')

    try {
        $r = Invoke-DirWatcherE2eDebugHook -Command 'commands' -BaseUrl $BaseUrl
        return ($null -ne $r.commands -and @($r.commands).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Normalize-DirWatcherE2ePathKey {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $full = [System.IO.Path]::GetFullPath($Path.Trim())
    return $full.TrimEnd('\')
}

function Format-DirWatcherE2eDebugConnectionSummary {
    param($Status)

    if ($null -eq $Status) {
        return '(no debug status)'
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(
            'connectionState', 'coreConnectionStatus', 'coreConnected', 'coreConnecting',
            'directoryWatcherRunning', 'directoryWatcherWatchersArmed', 'directoryWatcherPhase', 'monitoringRootFolders',
            'processingSlotsAvailable', 'processingSlotsTaken', 'processingSlotsWaiting', 'processingSlotsMaxParallel'
        )) {
        $val = Get-DirWatcherE2eDebugStatusProperty -Status $Status -Name $name
        if ($null -eq $val) {
            continue
        }
        if ($val -is [System.Array] -or ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string]))) {
            $val = @($val) -join '; '
        }

        $parts.Add("$name=$val")
    }

    return ($parts -join ', ')
}

function Get-DirWatcherE2eDebugStatusProperty {
    param(
        $Status,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $Status) {
        return $null
    }

    foreach ($candidate in @($Name, ($Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1)))) {
        $prop = $Status.PSObject.Properties[$candidate]
        if ($null -ne $prop) {
            return $prop.Value
        }
    }

    foreach ($prop in $Status.PSObject.Properties) {
        if ($prop.Name -ieq $Name) {
            return $prop.Value
        }
    }

    return $null
}

function Test-DirWatcherE2eDebugStatusBool {
    param(
        $Status,
        [Parameter(Mandatory)]
        [string] $Name
    )

    $raw = Get-DirWatcherE2eDebugStatusProperty -Status $Status -Name $Name
    if ($null -eq $raw) {
        return $false
    }

    if ($raw -is [bool]) {
        return $raw
    }

    switch ([string]$raw) {
        { $_ -match '^(?i:true|1)$' } { return $true }
        { $_ -match '^(?i:false|0)$' } { return $false }
    }

    return $false
}

function Get-DirWatcherE2eDebugMonitoringRootFolders {
    param($Status)

    $raw = Get-DirWatcherE2eDebugStatusProperty -Status $Status -Name 'monitoringRootFolders'
    if ($null -eq $raw) {
        return @()
    }

    $roots = New-Object System.Collections.Generic.List[string]
    if ($raw -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $roots.Add($raw.Trim()) | Out-Null
        }
        return @($roots)
    }

    foreach ($item in @($raw)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $roots.Add($item.Trim()) | Out-Null
            }
            continue
        }

        foreach ($nested in @($item)) {
            if ($null -eq $nested) {
                continue
            }

            $text = [string]$nested
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $roots.Add($text.Trim()) | Out-Null
            }
        }
    }

    return @($roots)
}

function Test-DirWatcherE2eDebugCoreReady {
    param($Status)

    if (Test-DirWatcherE2eDebugStatusBool -Status $Status -Name 'coreConnected') {
        return $true
    }

    $coreStatus = [string](Get-DirWatcherE2eDebugStatusProperty -Status $Status -Name 'coreConnectionStatus')
    if ($coreStatus -eq 'Authenticated') {
        return $true
    }

    $labState = [string](Get-DirWatcherE2eDebugStatusProperty -Status $Status -Name 'connectionState')
    return ($labState -eq 'Connected')
}

function Test-DirWatcherE2eDebugMonitoringIncoming {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [string] $BaseUrl = '',
        $Status = $null
    )

    if ($null -eq $Status) {
        $Status = Invoke-DirWatcherE2eDebugHook -Command 'connection.state' -BaseUrl $BaseUrl
    }

    if (-not (Test-DirWatcherE2eDebugCoreReady -Status $Status)) {
        return $false
    }

    $phase = [string](Get-DirWatcherE2eDebugStatusProperty -Status $Status -Name 'directoryWatcherPhase')
    if ($phase -eq 'GoingOverPreExistingFiles') {
        return $false
    }

    if (-not (Test-DirWatcherE2eDebugStatusBool -Status $Status -Name 'directoryWatcherRunning')) {
        return $false
    }

    $watchersArmed = Test-DirWatcherE2eDebugStatusBool -Status $Status -Name 'directoryWatcherWatchersArmed'
    if (-not $watchersArmed) {
        return $false
    }

    $phaseReady = ($phase -eq 'Monitoring') -or ($phase -eq 'Starting')
    if (-not $phaseReady) {
        return $false
    }

    $incomingKey = Normalize-DirWatcherE2ePathKey -Path $IncomingRoot

    $roots = @(Get-DirWatcherE2eDebugMonitoringRootFolders -Status $Status)
    if ($roots.Length -eq 0) {
        return $false
    }

    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) {
            continue
        }

        $rootKey = Normalize-DirWatcherE2ePathKey -Path ([string]$root)
        if ([string]::Equals($rootKey, $incomingKey, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Write-DirWatcherE2eDebugLogMark {
    param(
        [Parameter(Mandatory)]
        [string] $Message,
        [string] $BaseUrl = ''
    )

    try {
        $r = Invoke-DirWatcherE2eDebugHook -Command 'logmark' -Message $Message -BaseUrl $BaseUrl
        if (-not [string]::IsNullOrWhiteSpace([string]$r.logMarkMessage)) {
            Write-DwTestStep "DirWatcher logmark: $($r.logMarkMessage)"
        }
    }
    catch {
        # Debug hook optional when monitoring falls back to log tail.
    }
}

function Get-DirWatcherE2eDebugLogPathEvidence {
    param([string] $BaseUrl = '')

    try {
        $r = Invoke-DirWatcherE2eDebugHook -Command 'logpath' -BaseUrl $BaseUrl
        $paths = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$r.currentLogFilePath)) {
            $paths += [string]$r.currentLogFilePath
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$r.logFolder)) {
            $paths += [string]$r.logFolder
        }

        return @($paths | Select-Object -Unique)
    }
    catch {
        return @()
    }
}

function Add-DirWatcherE2eDebugEvidencePaths {
    param(
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]] $EvidencePaths,
        [string] $BaseUrl = ''
    )

    if ($null -eq $EvidencePaths) {
        return
    }
    foreach ($p in Get-DirWatcherE2eDebugLogPathEvidence -BaseUrl $BaseUrl) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) {
            continue
        }

        $EvidencePaths.Add($p) | Out-Null
        Write-DwTestStep "DirWatcher log for evidence: $p"
    }

    try {
        $status = Invoke-DirWatcherE2eDebugHook -Command 'connection.state' -BaseUrl $BaseUrl
        Write-DwTestStep "DirWatcher debug at failure: $(Format-DirWatcherE2eDebugConnectionSummary -Status $status)"
    }
    catch {
        # optional
    }
}
