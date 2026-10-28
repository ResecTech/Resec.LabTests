#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook helpers for SA E2E policy lab setup (pushpolicystate, importpolicies, poppolicystate).

.NOTES
  Requires Core AppSettings EnableDebugInterface = True.
  Default hook URL: env SCANAGENT_CORE_DEBUG_HOOK_URL, else https://localhost:4504/debug/hook
#>
Set-StrictMode -Version Latest

# Default SA-05 lab policy names (importpolicies + agent policy.list resolution).
$script:Sa05DefaultPolicyNameA = 'Test5-a'
$script:Sa05DefaultPolicyNameB = 'Test5-b'

$script:ScanAgentCoreDebugTlsBypassEnabled = $false

function Enable-ScanAgentCoreDebugTlsBypass {
    if ($script:ScanAgentCoreDebugTlsBypassEnabled) {
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not ('ScanAgentCoreDebugTrustAllCerts' -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class ScanAgentCoreDebugTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object ScanAgentCoreDebugTrustAllCerts
    $script:ScanAgentCoreDebugTlsBypassEnabled = $true
}

function Get-ScanAgentCoreDebugHookUrl {
    param([string] $Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:SCANAGENT_CORE_DEBUG_HOOK_URL)) {
        return $env:SCANAGENT_CORE_DEBUG_HOOK_URL.Trim()
    }

    return 'https://localhost:4504/debug/hook'
}

function ConvertTo-ScanAgentCoreDebugHookHttpErrorMessage {
    param(
        [Parameter(Mandatory)]
        [string] $Command,
        $ErrorRecord
    )

    $detail = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        $detail = $ErrorRecord.ErrorDetails.Message.Trim()
    }
    elseif ($ErrorRecord.Exception -is [System.Net.WebException]) {
        $web = $ErrorRecord.Exception
        if ($null -ne $web.Response) {
            try {
                $stream = $web.Response.GetResponseStream()
                if ($null -ne $stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($body)) {
                        $detail = $body.Trim()
                    }
                }
            }
            catch {
                # Keep exception message.
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        try {
            $parsed = $detail | ConvertFrom-Json
            if ($parsed.PSObject.Properties.Name -contains 'error' -and -not [string]::IsNullOrWhiteSpace([string]$parsed.error)) {
                return "Core debug hook $Command failed: $($parsed.error)"
            }
        }
        catch {
            # Body was not JSON; use raw text.
        }
        return "Core debug hook $Command failed: $detail"
    }

    return "Core debug hook $Command failed: $($ErrorRecord.Exception.Message)"
}

function Invoke-ScanAgentCoreDebugHook {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Command,
        $BodyObject,
        [int] $TimeoutSec = 180
    )

    Enable-ScanAgentCoreDebugTlsBypass

    try {
        if ($BodyObject) {
            $payload = @{}
            foreach ($key in $BodyObject.Keys) {
                $payload[$key] = $BodyObject[$key]
            }
            $payload['command'] = $Command
            $json = $payload | ConvertTo-Json -Depth 60 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $separator = if ($HookUrl.Contains('?')) { '&' } else { '?' }
            $uri = '{0}{1}command={2}' -f $HookUrl, $separator, [uri]::EscapeDataString($Command)
            return Invoke-RestMethod -Uri $uri -Method Post -Body $bytes `
                -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec
        }

        $separator = if ($HookUrl.Contains('?')) { '&' } else { '?' }
        $uri = '{0}{1}command={2}' -f $HookUrl, $separator, [uri]::EscapeDataString($Command)
        return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec
    }
    catch {
        throw (ConvertTo-ScanAgentCoreDebugHookHttpErrorMessage -Command $Command -ErrorRecord $_)
    }
}

function Assert-ScanAgentCoreDebugHookResponse {
    param(
        [Parameter(Mandatory)]
        $Response,
        [Parameter(Mandatory)]
        [string] $Step
    )

    if ($null -eq $Response) {
        throw "Core debug hook $Step returned no response."
    }

    if ($Response.PSObject.Properties.Name -contains 'error' -and -not [string]::IsNullOrWhiteSpace([string]$Response.error)) {
        throw "Core debug hook $Step failed: $($Response.error)"
    }
}

function Resolve-ScanAgentSa05PolicyTemplateXml {
    param([string] $OverridePath)

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $full = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Policy template XML not found: $full"
        }
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:SCANAGENT_SA05_POLICY_TEMPLATE_XML)) {
        $full = [System.IO.Path]::GetFullPath($env:SCANAGENT_SA05_POLICY_TEMPLATE_XML.Trim())
        if (Test-Path -LiteralPath $full) {
            return $full
        }
    }

    $candidates = @(
        'C:\resec\ImportExport\ImportExport_2026-07-09_1.xml'
    )
    $importDir = 'C:\resec\ImportExport'
    if (Test-Path -LiteralPath $importDir) {
        $latest = Get-ChildItem -LiteralPath $importDir -Filter 'ImportExport_*.xml' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            $candidates = @($latest.FullName) + $candidates
        }
    }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw 'SA-05 Core policy setup needs a WebMC export XML with a Scan Agent template policy (Local Source facet). Set -PolicyTemplateXml or SCANAGENT_SA05_POLICY_TEMPLATE_XML, or place ImportExport_*.xml under C:\resec\ImportExport.'
}

function Resolve-Sa05TemplatePolicyFromXml {
    param(
        [Parameter(Mandatory)]
        $PolicyNodes,
        [string] $TemplatePolicyName
    )

    $policies = @($PolicyNodes)
    if ($policies.Count -eq 0) {
        throw 'Policy template XML contains no policies.'
    }

    $nameCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($TemplatePolicyName)) {
        $nameCandidates += $TemplatePolicyName.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SCANAGENT_SA05_TEMPLATE_POLICY_NAME)) {
        $nameCandidates += $env:SCANAGENT_SA05_TEMPLATE_POLICY_NAME.Trim()
    }
    $nameCandidates += @('ScanAgent', 'clean agent', 'Agent')
    foreach ($candidate in ($nameCandidates | Select-Object -Unique)) {
        $match = @($policies | Where-Object { $_.Name -eq $candidate } | Select-Object -First 1)
        if ($match) {
            return $match
        }
    }

    $withLocalSource = @($policies | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.PolicyRawData) -and
            [string]$_.PolicyRawData -match 'Facet Local Source:Local Source'
        })
    if ($withLocalSource.Count -ge 1) {
        return $withLocalSource[0]
    }

    $available = ($policies | ForEach-Object { [string]$_.Name }) -join ', '
    throw "Policy template XML has no usable Scan Agent template policy (need Local Source facet). Tried names: $(($nameCandidates | Select-Object -Unique) -join ', '). Available policies: $available"
}

function Remove-Sa05PolicyFacetBlock {
    param(
        [Parameter(Mandatory)]
        [string] $PolicyRawData,
        [Parameter(Mandatory)]
        [string] $FacetHeader
    )

    $escaped = [regex]::Escape($FacetHeader)
    $pattern = "(?s);Facet $escaped\r?\n.*?(?=;Facet |\z)"
    return [regex]::Replace($PolicyRawData, $pattern, '')
}

function New-Sa05SmbSourceFacet {
    param(
        [Parameter(Mandatory)]
        [string] $StoreName,
        [Parameter(Mandatory)]
        [string] $RootFolder,
        [int] $SortOrder = 1
    )

    return @"
;Facet SMB Source:SMB Source
StrPropType_ScannedFileLocationName=$StoreName
StrPropType_ScannedFileSmbLocationRootFolder=$RootFolder
StrPropType_ScannedFileSmbLocationRelayComputer=
NumPropType_ScannedFileLocationSortOrder=$SortOrder

"@
}

function New-Sa05SmbDestinationFacet {
    param(
        [Parameter(Mandatory)]
        [string] $StoreName,
        [Parameter(Mandatory)]
        [string] $RootFolder,
        [int] $SortOrder = 2
    )

    return @"
;Facet SMB Destination:SMB Destination
StrPropType_ScannedFileLocationName=$StoreName
StrPropType_ScannedFileSmbLocationRootFolder=$RootFolder
NumPropType_ScannedFileSmbLocationNumOfHoursToKeepFiles=0
NumPropType_ScannedFileSmbLocationUserQuota=0
StrPropType_ScannedFileSmbLocationRelayComputer=
NumPropType_ScannedFileSmbLocationOverwriteExistingFile=False
NumPropType_ScannedFileLocationSortOrder=$SortOrder

"@
}

function New-Sa05SmbInOutFacetBlock {
    param(
        [Parameter(Mandatory)]
        [string] $SourceStoreName,
        [Parameter(Mandatory)]
        [string] $SourceRootFolder,
        [Parameter(Mandatory)]
        [string] $DestinationStoreName,
        [Parameter(Mandatory)]
        [string] $DestinationRootFolder
    )

    $source = New-Sa05SmbSourceFacet -StoreName $SourceStoreName -RootFolder $SourceRootFolder -SortOrder 1
    $dest = New-Sa05SmbDestinationFacet -StoreName $DestinationStoreName -RootFolder $DestinationRootFolder -SortOrder 2
    return $source + $dest
}

function Remove-Sa05LocationFacetsFromPolicyRaw {
    param([Parameter(Mandatory)][string] $PolicyRawData)

    $headers = @(
        'Local Source:Local Source'
        'Local Destination:Local Destination'
        'SMB Source:SMB Source'
        'SMB Destination:SMB Destination'
        'Scanned Files SMB Location:Scanned Files SMB Location'
    )
    $raw = $PolicyRawData
    foreach ($header in $headers) {
        $raw = Remove-Sa05PolicyFacetBlock -PolicyRawData $raw -FacetHeader $header
    }
    return $raw
}

function Get-Sa07LabAllowedFileTypesValue {
    <#
      Modern WebMC AllowedFileTypes line (all categories allowed) so encrypted lab fixtures
      (7z, rar, office, zip, etc.) are not blocked as SevenZip / Archives subtypes.
    #>
    return 'Archives=True|CAD=True|Databases=True|Documents (Common)=True|Documents (Uncommon)=True|Email=True|Embedded Office Objects=True|Executables=True|Images=True|Media Files=True|Model=True|Others=True|Scripts=True|Unknown File=True|Unsafe=True'
}

function Set-Sa07PolicyRawAllowAllFileTypes {
    param([Parameter(Mandatory)][string] $PolicyRawData)

    $allowedLine = 'StrPropType_AllowedFileTypes=' + (Get-Sa07LabAllowedFileTypesValue)
    if ($PolicyRawData -match '(?m)^StrPropType_AllowedFileTypes=.*$') {
        return [regex]::Replace($PolicyRawData, '(?m)^StrPropType_AllowedFileTypes=.*$', $allowedLine)
    }

    if ($PolicyRawData -match ';Facet Basic Settings:Basic Settings') {
        return [regex]::Replace(
            $PolicyRawData,
            ';Facet Basic Settings:Basic Settings',
            ";Facet Basic Settings:Basic Settings`r`n$allowedLine")
    }

    if ($PolicyRawData -match ';Facet Basic:Basic') {
        return [regex]::Replace(
            $PolicyRawData,
            ';Facet Basic:Basic',
            ";Facet Basic:Basic`r`n$allowedLine")
    }

    return "$allowedLine`r`n" + $PolicyRawData
}

function New-Sa07LabScannersFacet {
    return @"
;Facet Scanners:Scanners
NumPropType_EnableScanner_Email Reputation Checker=False
NumPropType_EnableScanner_ICAP Client=False
NumPropType_EnableScanner_Regular Expression Scanner=False
NumPropType_EnableScanner_Third-Party Signature Validator=False
NumPropType_EnableScanner_XML validation Scanner=False
NumPropType_EnableScanner_SigFile Validator=False
NumPropType_EnableScanner_Avira(Win)=False
NumPropType_EnableScanner_ClamAv=False
NumPropType_EnableScanner_Sophos antivirus=False
NumPropType_EnableScanner_Windows Defender=False
NumPropType_EnableScanner_Microsoft Security Essentials=False
NumPropType_EnableScanner_CAPE Sandbox=False
NumPropType_EnableScanner_Folder scanner=False

"@
}

function Set-Sa07PolicyRawPermissiveLabScanAgentPolicy {
    <#
      SA-07 lab policy: allow all file categories and disable optional scanners so fixture
      sanitization is not blocked by policy or CAPE/sandbox failures on archive contents.
    #>
    param([Parameter(Mandatory)][string] $PolicyRawData)

    $raw = Set-Sa07PolicyRawAllowAllFileTypes -PolicyRawData $PolicyRawData
    $raw = Remove-Sa05PolicyFacetBlock -PolicyRawData $raw -FacetHeader 'Scanners:Scanners'
    $raw = Remove-Sa05PolicyFacetBlock -PolicyRawData $raw -FacetHeader 'System Health:System Health'
    $raw += @"
;Facet System Health:System Health
NumPropType_MinNumberOfValidScanners=0
NumPropType_MaxScannersDefinitionAge=168

"@
    $raw += New-Sa07LabScannersFacet
    return $raw
}

function New-SaLabDisabledFormatTransformationsFacet {
    return @"
;Facet Format Transformations:Format Transformations
NumPropType_OfficeTransformation=0
NumPropType_PdfTransformation=0
NumPropType_ImageTransformation=0
NumPropType_HtmlTransformation=0
NumPropType_VisioTransformation=0
NumPropType_ImagePixelThreshold=0

"@
}

function New-SaLabDisabledTransformationActionsFacet {
    <#
      Disables CDR / reconstruction action tiers (lab pass-through sanitization).
    #>
    return @"
;Facet Transformation Actions:Transformation Actions
Actions Settings=Pdf:Critical=False|Pdf:High=False|Pdf:Medium=False|Pdf:Low=False|Word:Critical=False|Word:High=False|Word:Medium=False|Word:Low=False|Spreadsheet:Critical=False|Spreadsheet:High=False|Spreadsheet:Medium=False|Spreadsheet:Low=False|Presentation:Critical=False|Presentation:High=False|Presentation:Medium=False|Presentation:Low=False|Visio:High=False|Visio:Medium=False|Visio:Low=False|Image:High=False|Image:Medium=False|Image:Low=False|Html:Critical=False|Html:High=False|Html:Medium=False|Html:Low=False|Email:Critical=False|Email:High=False|Email:Medium=False|Email:Low=False|Svg:Critical=False|Svg:High=False|Svg:Medium=False|MetafileImage=False|Multitiff=False|Csv:Critical=False|Csv:Medium=False|Chm=False|Ichitaro:Critical=False|Ichitaro:High=False|Ichitaro:Medium=False|JSON=False|Mp3=False|OpenOfficeText:High=False|OpenOfficeText:Medium=False|OpenOfficeSpreadsheet:High=False|OpenOfficeSpreadsheet:Medium=False|OpenOfficePresentation:High=False|OpenOfficePresentation:Medium=False|OpenOfficeGraphics=False|AutoCad=False
NumPropType_VerifySignatureWhenIgnoringSignedFile=False
NumPropType_ExtractPdfImages=False
NumPropType_ProcessJtdc=False
BoolPropType_RetainOriginalFile=False

"@
}

function Set-SaLabPolicyRawDisableCdrAndTransformations {
    param([Parameter(Mandatory)][string] $PolicyRawData)

    $raw = Remove-Sa05PolicyFacetBlock -PolicyRawData $PolicyRawData -FacetHeader 'Format Transformations:Format Transformations'
    $raw = Remove-Sa05PolicyFacetBlock -PolicyRawData $raw -FacetHeader 'Transformation Actions:Transformation Actions'
    $raw += New-SaLabDisabledFormatTransformationsFacet
    $raw += New-SaLabDisabledTransformationActionsFacet
    return $raw
}

function Set-Sa09PolicyRawLabSanitizePolicy {
    param([Parameter(Mandatory)][string] $PolicyRawData)

    $raw = Set-Sa07PolicyRawPermissiveLabScanAgentPolicy -PolicyRawData $PolicyRawData
    $raw = Set-SaLabPolicyRawDisableCdrAndTransformations -PolicyRawData $raw
    return $raw
}

function Set-Sa05PolicyRawRemainConnected {
    <#
      Scan Agent idle disconnect (30s) and gateway auto-reconnect follow NumPropType_AutoReconnect on the current policy.
      WebMC templates often ship False; SA-05 needs True on lab policies so commdown/commup and long E2E waits stay connected.
    #>
    param([Parameter(Mandatory)][string] $PolicyRawData)

    if ($PolicyRawData -match 'NumPropType_AutoReconnect=False') {
        return [regex]::Replace($PolicyRawData, 'NumPropType_AutoReconnect=False', 'NumPropType_AutoReconnect=True')
    }

    if ($PolicyRawData -notmatch 'NumPropType_AutoReconnect=') {
        return "NumPropType_AutoReconnect=True`r`n" + $PolicyRawData
    }

    return $PolicyRawData
}

function Ensure-Sa05SmbLabFolders {
    param(
        [Parameter(Mandatory)]
        [string[]] $FolderPaths,
        [string] $MarkerPrefix = 'SA-05'
    )

    foreach ($path in ($FolderPaths | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $full = [System.IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $full)) {
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
        $marker = Join-Path $full "$MarkerPrefix-lab-folder.txt"
        if (-not (Test-Path -LiteralPath $marker)) {
            Set-Content -LiteralPath $marker -Value "SA-05 lab SMB folder: $full" -Encoding UTF8
        }
    }
}

function New-Sa05CorePolicyImportBody {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = '',
        [string] $PolicyNameA = 'Test5-a',
        [string] $PolicyNameB = 'Test5-b',
        [string] $SourceRootA = 'c:\temp\SA-05-in-a',
        [string] $DestRootA = 'c:\test\SA-05-out-a',
        [string] $SourceRootB = 'c:\test\SA-05-in-b',
        [string] $DestRootB = 'c:\temp\SA-05-out-b',
        [string] $SourceStoreName = 'sa05-smb-in',
        [string] $DestinationStoreName = 'sa05-smb-out',
        [string] $AssignmentRuleName = 'debug-scan-agents-smb'
    )

    Ensure-Sa05SmbLabFolders -FolderPaths @($SourceRootA, $DestRootA, $SourceRootB, $DestRootB)

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $baseRaw = Remove-Sa05LocationFacetsFromPolicyRaw -PolicyRawData $resolvedBase.BaseRaw

    $rawA = New-Sa05SmbInOutFacetBlock `
        -SourceStoreName $SourceStoreName -SourceRootFolder $SourceRootA `
        -DestinationStoreName $DestinationStoreName -DestinationRootFolder $DestRootA
    $rawA += Set-Sa05PolicyRawRemainConnected -PolicyRawData $baseRaw

    $rawB = New-Sa05SmbInOutFacetBlock `
        -SourceStoreName $SourceStoreName -SourceRootFolder $SourceRootB `
        -DestinationStoreName $DestinationStoreName -DestinationRootFolder $DestRootB
    $rawB += Set-Sa05PolicyRawRemainConnected -PolicyRawData $baseRaw

    # Placeholder policy ids must match the assignment rule policies array (Core remaps to DB ids on import).
    $policyIdA = 9101
    $policyIdB = 9102

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id             = $policyIdA
                name           = $PolicyNameA
                displayName    = "Debug SMB A ($SourceRootA -> $DestRootA)"
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $rawA
            },
            @{
                id             = $policyIdB
                name           = $PolicyNameB
                displayName    = "Debug SMB B ($SourceRootB -> $DestRootB)"
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $rawB
            }
        )
        policyAssociations = @(
            @{
                name       = $AssignmentRuleName
                enabled    = $true
                policies   = @(
                    [string]$policyIdA
                    [string]$policyIdB
                )
                conditions = @(
                    @{
                        item      = 'agent_type'
                        condition = 'is_one_of'
                        target    = 'scan_agent'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Invoke-ScanAgentDebugReconnect {
    param([Parameter(Mandatory)][string] $Exe)

    $result = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('ui.invoke', '--action', 'reconnect')
    if ($result.ok -ne $true) {
        throw "Scan Agent ui.invoke reconnect failed: $($result.error)"
    }
    return $result
}

function Wait-ScanAgentGatewayConnected {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [int] $TimeoutSec = 120,
        [string] $Context = 'gateway connect',
        [switch] $NudgeReconnect,
        [int] $PollMs = 400
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $reconnectNudged = $false
    $lastProgressLog = [DateTimeOffset]::MinValue
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        # Gateway connect is independent of UI spinner / source folder load — poll status first.
        $gateway = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('gateway.status')
        if ($gateway.ok -eq $true -and $gateway.isConnected -eq $true) {
            return $gateway
        }

        $now = [DateTimeOffset]::UtcNow
        if (($now - $lastProgressLog).TotalSeconds -ge 10) {
            $statusText = if ($gateway.connectionStatus) { [string]$gateway.connectionStatus } else { 'not connected' }
            $remainingSec = [Math]::Max(0, [int]($deadline - $now).TotalSeconds)
            Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Waiting for gateway.status isConnected ($Context): $statusText (${remainingSec}s left)"
            $lastProgressLog = $now
        }

        if ($NudgeReconnect -and -not $reconnectNudged) {
            $reconnectNudged = $true
            try {
                Invoke-ScanAgentDebugReconnect -Exe $Exe | Out-Null
            }
            catch {
                Write-Warning "Reconnect nudge returned before gateway was up ($Context); continuing gateway.status poll. $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 500
            continue
        }

        Start-Sleep -Milliseconds $PollMs
    }

    throw "Timed out after ${TimeoutSec}s waiting for gateway.status isConnected ($Context)."
}

function Disconnect-AllCoreAgentsForRefresh {
    <#
    .SYNOPSIS
      Blocks Core agent admissions (commdown), drops connected sessions, waits, then commup.
      Forces agents to reconnect and reload policies after importpolicies. See Core docs/core-debug-api.md.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [int] $DisconnectHoldSec = 5,
        [int] $GatewayWaitSec = 120
    )

    $down = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'agentcommblockon'
    Assert-ScanAgentCoreDebugHookResponse -Response $down -Step 'agentcommblockon (commdown)'
    $dropped = if ($down.PSObject.Properties.Name -contains 'droppedSessions') { $down.droppedSessions } else { '?' }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core commdown: all agent sessions disconnected (droppedSessions=$dropped); holding ${DisconnectHoldSec}s before commup."

    if ($DisconnectHoldSec -gt 0) {
        Start-Sleep -Seconds $DisconnectHoldSec
    }

    $up = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'agentcommblockoff'
    Assert-ScanAgentCoreDebugHookResponse -Response $up -Step 'agentcommblockoff (commup)'
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core commup: agent admissions re-enabled; waiting for Scan Agent gateway reconnect."

    Start-Sleep -Milliseconds 500
    $null = Wait-ScanAgentGatewayConnected -Exe $Exe -TimeoutSec $GatewayWaitSec `
        -Context 'after Core commdown/commup' -NudgeReconnect
}

function Restart-ScanAgentSa05CoreAgentSessions {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [int] $CommDownHoldSec = 5,
        [int] $GatewayWaitSec = 120
    )

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe `
        -DisconnectHoldSec $CommDownHoldSec -GatewayWaitSec $GatewayWaitSec
}

function Push-ScanAgentSa05CorePolicyState {
    param([string] $CoreDebugHookUrl)

    $hookUrl = Get-ScanAgentCoreDebugHookUrl -Override $CoreDebugHookUrl
    $push = Invoke-ScanAgentCoreDebugHook -HookUrl $hookUrl -Command 'pushpolicystate'
    Assert-ScanAgentCoreDebugHookResponse -Response $push -Step 'pushpolicystate'

    return [pscustomobject]@{
        HookUrl      = $hookUrl
        PushResponse = $push
    }
}

function Import-ScanAgentSa05CoreDebugPolicies {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyNameA = 'Test5-a',
        [string] $PolicyNameB = 'Test5-b',
        [string] $SourceRootA = 'c:\temp\SA-05-in-a',
        [string] $DestRootA = 'c:\test\SA-05-out-a',
        [string] $SourceRootB = 'c:\test\SA-05-in-b',
        [string] $DestRootB = 'c:\temp\SA-05-out-b',
        [int] $AgentPolicyWaitSec = 180,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $UiWaitMs = 120000
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core importpolicies policy base: $($resolvedBase.Source)"
    $importBody = New-Sa05CorePolicyImportBody `
        -PolicyBaseRaw $resolvedBase.BaseRaw -PolicyTemplateXml '' `
        -TemplatePolicyName $TemplatePolicyName `
        -PolicyNameA $PolicyNameA -PolicyNameB $PolicyNameB `
        -SourceRootA $SourceRootA -DestRootA $DestRootA `
        -SourceRootB $SourceRootB -DestRootB $DestRootB

    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $importBody
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe -DisconnectHoldSec $AgentDisconnectHoldSec

    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames @($PolicyNameA, $PolicyNameB) `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    if ($policyList.ok -ne $true) {
        throw 'policy.list failed after Core import and agent reconnect.'
    }
    $listedNames = @($policyList.policies | ForEach-Object { [string]$_.name })
    $missing = @($PolicyNameA, $PolicyNameB | Where-Object { $listedNames -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Agent policy.list is missing policies $($PolicyNameA) and $($PolicyNameB): missing $($missing -join ', '). Listed: $($listedNames -join ', ')."
    }
    if ((Get-CollectionCount $policyList.policies) -lt 2) {
        throw "Agent policy.list must include at least two policies for SA-05; count=$($policyList.count)."
    }

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Agent policy.list includes $($PolicyNameA) and $($PolicyNameB)."

    return [pscustomobject]@{
        PolicyBaseSource  = $resolvedBase.Source
        PolicyNameA       = $PolicyNameA
        PolicyNameB       = $PolicyNameB
        ImportResponse    = $import
        AgentPolicyList   = $policyList
    }
}

function Initialize-ScanAgentSa05CoreTestPolicies {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyNameA = 'Test5-a',
        [string] $PolicyNameB = 'Test5-b',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $imported = Import-ScanAgentSa05CoreDebugPolicies -HookUrl $pushed.HookUrl -Exe $Exe `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
        -PolicyNameA $PolicyNameA -PolicyNameB $PolicyNameB `
        -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl          = $pushed.HookUrl
        PolicyBaseSource = $imported.PolicyBaseSource
        PolicyNameA      = $imported.PolicyNameA
        PolicyNameB      = $imported.PolicyNameB
        PushResponse     = $pushed.PushResponse
        ImportResponse   = $imported.ImportResponse
    }
}

function Export-ScanAgentCorePolicyState {
    <#
    .SYNOPSIS
      GET exportpolicystate — current Core policies + policyAssociations (does not push the in-memory stack).
    #>
    param([string] $CoreDebugHookUrl)

    $hookUrl = Get-ScanAgentCoreDebugHookUrl -Override $CoreDebugHookUrl
    $export = Invoke-ScanAgentCoreDebugHook -HookUrl $hookUrl -Command 'exportpolicystate'
    Assert-ScanAgentCoreDebugHookResponse -Response $export -Step 'exportpolicystate'
    return $export
}

function Restore-ScanAgentSa05CorePolicyStack {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    $pop = Invoke-ScanAgentCoreDebugHook -HookUrl $hookUrl -Command 'poppolicystate'
    Assert-ScanAgentCoreDebugHookResponse -Response $pop -Step 'poppolicystate'
    return $pop
}

function Restore-ScanAgentCorePolicyLabAndAgent {
    <#
    .SYNOPSIS
      poppolicystate, then commdown/commup so the agent reloads policies from Core, then optional policy.select by name.

    .NOTES
      Policy database ids change when Core wipe-restores from the push snapshot; always restore the UI selection by name.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $OriginalPolicyName = '',
        [int] $UiWaitMs = 120000,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $GatewayWaitSec = 120
    )

    $pop = Restore-ScanAgentSa05CorePolicyStack -HookUrl $HookUrl
    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe `
        -DisconnectHoldSec $AgentDisconnectHoldSec -GatewayWaitSec $GatewayWaitSec

    if ([string]::IsNullOrWhiteSpace($OriginalPolicyName)) {
        return $pop
    }

    $name = $OriginalPolicyName.Trim()
    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames @($name) -UiWaitMs $UiWaitMs
    $select = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @(
        'policy.select', '--name', $name, '--wait-ms', "$UiWaitMs"
    )
    if ($select.ok -ne $true) {
        throw "policy.select by name '$name' failed after Core pop: $($select.error)"
    }

    return $pop
}

function Wait-ScanAgentPolicyListContainsNames {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [Parameter(Mandatory)]
        [string[]] $PolicyNames,
        [int] $TimeoutSec = 180,
        [int] $UiWaitMs = 120000,
        [int] $PollMs = 2000
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSec)
    $expected = @($PolicyNames | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $gateway = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('gateway.status')
        if ($gateway.ok -ne $true -or $gateway.isConnected -ne $true) {
            Start-Sleep -Milliseconds $PollMs
            continue
        }

        $list = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
        if ($list.ok -eq $true) {
            $names = @($list.policies | ForEach-Object { [string]$_.name })
            $missing = @($expected | Where-Object { $names -notcontains $_ })
            if ($missing.Count -eq 0) {
                return $list
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }

    throw "Timed out after ${TimeoutSec}s waiting for policy.list to include: $($expected -join ', ')."
}

function Resolve-TwoPolicyIdsFromList {
    param(
        [Parameter(Mandatory)]
        $PolicyList,
        [int] $OverrideA,
        [int] $OverrideB,
        [string] $PolicyNameA,
        [string] $PolicyNameB
    )

    $policies = @($PolicyList.policies)
    if ((Get-CollectionCount $policies) -lt 2) {
        throw "Need at least two policies in policy.list; found $(Get-CollectionCount $policies)."
    }

    if ($OverrideA -gt 0 -and $OverrideB -gt 0) {
        if ($OverrideA -eq $OverrideB) {
            throw '-PolicyIdA and -PolicyIdB must be different policy ids.'
        }
        $ids = @($policies | ForEach-Object { [int]$_.id })
        if ($ids -notcontains $OverrideA) {
            throw "PolicyIdA $OverrideA is not in policy.list."
        }
        if ($ids -notcontains $OverrideB) {
            throw "PolicyIdB $OverrideB is not in policy.list."
        }
        return [pscustomobject]@{ PolicyA = $OverrideA; PolicyB = $OverrideB }
    }

    if (-not [string]::IsNullOrWhiteSpace($PolicyNameA) -and -not [string]::IsNullOrWhiteSpace($PolicyNameB)) {
        $matchA = @($policies | Where-Object { [string]$_.name -eq $PolicyNameA })
        $matchB = @($policies | Where-Object { [string]$_.name -eq $PolicyNameB })
        if ($matchA.Count -lt 1) {
            throw "Policy '$PolicyNameA' not found in policy.list."
        }
        if ($matchB.Count -lt 1) {
            throw "Policy '$PolicyNameB' not found in policy.list."
        }
        $idA = [int]$matchA[0].id
        $idB = [int]$matchB[0].id
        if ($idA -eq $idB) {
            throw "Policy names '$PolicyNameA' and '$PolicyNameB' resolved to the same id $idA."
        }
        return [pscustomobject]@{ PolicyA = $idA; PolicyB = $idB }
    }

    $sorted = @($policies | Sort-Object { [int]$_.id })
    $idA = [int]$sorted[0].id
    $idB = [int]$sorted[1].id
    if ($idA -eq $idB) {
        throw 'Could not pick two distinct policies from policy.list.'
    }

    return [pscustomobject]@{ PolicyA = $idA; PolicyB = $idB }
}

# Default SA-08 lab policy (single SMB in/out policy for abort mid-job E2E).
$script:Sa08DefaultPolicyName = 'Test8-abort'
$script:Sa08DefaultSourceRoot = 'c:\test\SA-08-in'
$script:Sa08DefaultDestRoot = 'c:\test\SA-08-out'
$script:Sa08DefaultSourceStoreName = 'sa08-smb-in'
$script:Sa08DefaultDestStoreName = 'sa08-smb-out'

function New-Sa08CorePolicyImportBody {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test8-abort',
        [string] $SourceRoot = 'c:\test\SA-08-in',
        [string] $DestRoot = 'c:\test\SA-08-out',
        [string] $SourceStoreName = 'sa08-smb-in',
        [string] $DestinationStoreName = 'sa08-smb-out',
        [string] $AssignmentRuleName = 'debug-scan-agents-sa08'
    )

    Ensure-Sa05SmbLabFolders -FolderPaths @($SourceRoot, $DestRoot) -MarkerPrefix 'SA-08'

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $baseRaw = Remove-Sa05LocationFacetsFromPolicyRaw -PolicyRawData $resolvedBase.BaseRaw
    $raw = New-Sa05SmbInOutFacetBlock `
        -SourceStoreName $SourceStoreName -SourceRootFolder $SourceRoot `
        -DestinationStoreName $DestinationStoreName -DestinationRootFolder $DestRoot
    $raw += Set-Sa05PolicyRawRemainConnected -PolicyRawData $baseRaw

    $policyId = 9108

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id             = $policyId
                name           = $PolicyName
                displayName    = "Debug SMB SA-08 ($SourceRoot -> $DestRoot)"
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $raw
            }
        )
        policyAssociations = @(
            @{
                name       = $AssignmentRuleName
                enabled    = $true
                policies   = @([string]$policyId)
                conditions = @(
                    @{
                        item      = 'agent_type'
                        condition = 'is_one_of'
                        target    = 'scan_agent'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-ScanAgentSa08CoreDebugPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test8-abort',
        [string] $SourceRoot = 'c:\test\SA-08-in',
        [string] $DestRoot = 'c:\test\SA-08-out',
        [int] $AgentPolicyWaitSec = 180,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $UiWaitMs = 120000
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $importBody = New-Sa08CorePolicyImportBody `
        -PolicyBaseRaw $resolvedBase.BaseRaw -PolicyTemplateXml '' `
        -TemplatePolicyName $TemplatePolicyName -PolicyName $PolicyName `
        -SourceRoot $SourceRoot -DestRoot $DestRoot

    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $importBody
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies (SA-08)'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe -DisconnectHoldSec $AgentDisconnectHoldSec

    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames @($PolicyName) `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    if ($policyList.ok -ne $true) {
        throw 'policy.list failed after SA-08 Core import and agent reconnect.'
    }

    $listedNames = @($policyList.policies | ForEach-Object { [string]$_.name })
    if ($listedNames -notcontains $PolicyName) {
        throw "Agent policy.list is missing policy '$PolicyName'. Listed: $($listedNames -join ', ')."
    }

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Agent policy.list includes $PolicyName."

    return [pscustomobject]@{
        PolicyBaseSource  = $resolvedBase.Source
        PolicyName        = $PolicyName
        SourceRoot        = $SourceRoot
        DestRoot          = $DestRoot
        ImportResponse    = $import
        AgentPolicyList   = $policyList
    }
}

function Initialize-ScanAgentSa08CoreTestPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test8-abort',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $imported = Import-ScanAgentSa08CoreDebugPolicy -HookUrl $pushed.HookUrl -Exe $Exe `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
        -PolicyName $PolicyName -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl          = $pushed.HookUrl
        PolicyBaseSource = $imported.PolicyBaseSource
        PolicyName       = $imported.PolicyName
        SourceRoot       = $imported.SourceRoot
        DestRoot         = $imported.DestRoot
        PushResponse     = $pushed.PushResponse
        ImportResponse   = $imported.ImportResponse
        AgentPolicyList  = $imported.AgentPolicyList
    }
}

# Default SA-07 lab policy (Local Source + Local Destination on Scan Agent template).
$script:Sa07DefaultPolicyName = 'Test7-password'

function Get-Sa07LocalLocationTypesLine {
    return 'Location Type=CdRom=True|Desktop=True|Fixed=True|Floppy=True|MobileDevice=True|MyDocuments=True|MyDownloads=True|Network=True|Removable=True'
}

function New-Sa07LocalSourceFacet {
    return @"
;Facet Local Source:Local Source
StrPropType_ScannedFileLocationName=In
$(Get-Sa07LocalLocationTypesLine)

"@
}

function New-Sa07LocalDestinationFacet {
    return @"
;Facet Local Destination:Local Destination
StrPropType_ScannedFileLocationName=Out
$(Get-Sa07LocalLocationTypesLine)
NumPropType_ScannedFileSmbLocationOverwriteExistingFile=True

"@
}

function New-Sa07LocalInOutFacetBlock {
    return (New-Sa07LocalSourceFacet) + (New-Sa07LocalDestinationFacet)
}

function New-Sa07CorePolicyImportBody {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test7-password',
        [string] $AssignmentRuleName = 'debug-scan-agents-sa07'
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $baseRaw = Remove-Sa05LocationFacetsFromPolicyRaw -PolicyRawData $resolvedBase.BaseRaw
    $baseRaw = Set-Sa07PolicyRawPermissiveLabScanAgentPolicy -PolicyRawData $baseRaw
    $raw = New-Sa07LocalInOutFacetBlock
    $raw += Set-Sa05PolicyRawRemainConnected -PolicyRawData $baseRaw

    $policyId = 9107

    return @{
        command            = 'importpolicies'
        policies           = @(
            @{
                id             = $policyId
                name           = $PolicyName
                displayName    = 'Debug local SA-07 (encrypted password dialog)'
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $raw
            }
        )
        policyAssociations = @(
            @{
                name       = $AssignmentRuleName
                enabled    = $true
                policies   = @([string]$policyId)
                conditions = @(
                    @{
                        item      = 'agent_type'
                        condition = 'is_one_of'
                        target    = 'scan_agent'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-ScanAgentSa07CoreDebugPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test7-password',
        [int] $AgentPolicyWaitSec = 180,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $UiWaitMs = 120000
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core importpolicies policy base: $($resolvedBase.Source)"
    $importBody = New-Sa07CorePolicyImportBody `
        -PolicyBaseRaw $resolvedBase.BaseRaw -PolicyTemplateXml '' `
        -TemplatePolicyName $TemplatePolicyName -PolicyName $PolicyName

    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $importBody
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies (SA-07)'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe -DisconnectHoldSec $AgentDisconnectHoldSec

    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames @($PolicyName) `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    if ($policyList.ok -ne $true) {
        throw 'policy.list failed after SA-07 Core import and agent reconnect.'
    }

    $listedNames = @($policyList.policies | ForEach-Object { [string]$_.name })
    if ($listedNames -notcontains $PolicyName) {
        throw "Agent policy.list is missing policy '$PolicyName'. Listed: $($listedNames -join ', ')."
    }

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Agent policy.list includes $PolicyName."

    return [pscustomobject]@{
        PolicyBaseSource = $resolvedBase.Source
        PolicyName       = $PolicyName
        ImportResponse   = $import
        AgentPolicyList  = $policyList
    }
}

function Initialize-ScanAgentSa07CoreTestPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test7-password',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $imported = Import-ScanAgentSa07CoreDebugPolicy -HookUrl $pushed.HookUrl -Exe $Exe `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
        -PolicyName $PolicyName -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl           = $pushed.HookUrl
        PolicyBaseSource  = $imported.PolicyBaseSource
        PolicyName        = $imported.PolicyName
        PushResponse      = $pushed.PushResponse
        ImportResponse    = $imported.ImportResponse
        AgentPolicyList   = $imported.AgentPolicyList
    }
}

# Default SA-09 lab policy (Local + SMB sources and destinations; same Core SMB folder mapping as lab agent host).
$script:Sa09DefaultPolicyName = 'Test9-smb-local'
$script:Sa09SmbInFolder = 'c:\test\SA-09-smb-in'
$script:Sa09SmbOutFolder = 'c:\test\SA-09-smb-out'
$script:Sa09LocalOutFolder = 'c:\test\SA-09-local-out'
$script:Sa09SmbStoreIn = 'sa09-smb-in'
$script:Sa09SmbStoreOut = 'sa09-smb-out'

function New-Sa09LocalAndSmbLocationBlock {
    param(
        [Parameter(Mandatory)]
        [string] $SmbInFolder,
        [Parameter(Mandatory)]
        [string] $SmbOutFolder,
        [Parameter(Mandatory)]
        [string] $SmbStoreIn,
        [Parameter(Mandatory)]
        [string] $SmbStoreOut
    )

    $block = New-Sa07LocalSourceFacet
    $block += New-Sa05SmbSourceFacet -StoreName $SmbStoreIn -RootFolder $SmbInFolder -SortOrder 2
    $block += New-Sa07LocalDestinationFacet
    $block += New-Sa05SmbDestinationFacet -StoreName $SmbStoreOut -RootFolder $SmbOutFolder -SortOrder 4
    return $block
}

function New-Sa09CorePolicyImportBody {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test9-smb-local',
        [string] $SmbInFolder = 'c:\test\SA-09-smb-in',
        [string] $SmbOutFolder = 'c:\test\SA-09-smb-out',
        [string] $SmbStoreIn = 'sa09-smb-in',
        [string] $SmbStoreOut = 'sa09-smb-out',
        [string] $AssignmentRuleName = 'debug-scan-agents-sa09'
    )

    Ensure-Sa05SmbLabFolders -FolderPaths @($SmbInFolder, $SmbOutFolder) -MarkerPrefix 'SA-09'
    $localOut = [System.IO.Path]::GetFullPath('c:\test\SA-09-local-out')
    if (-not (Test-Path -LiteralPath $localOut)) {
        New-Item -ItemType Directory -Path $localOut -Force | Out-Null
    }

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    $baseRaw = Remove-Sa05LocationFacetsFromPolicyRaw -PolicyRawData $resolvedBase.BaseRaw
    $baseRaw = Set-Sa09PolicyRawLabSanitizePolicy -PolicyRawData $baseRaw
    $raw = New-Sa09LocalAndSmbLocationBlock `
        -SmbInFolder $SmbInFolder -SmbOutFolder $SmbOutFolder `
        -SmbStoreIn $SmbStoreIn -SmbStoreOut $SmbStoreOut
    $raw += Set-Sa05PolicyRawRemainConnected -PolicyRawData $baseRaw

    $policyId = 9109

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id             = $policyId
                name           = $PolicyName
                displayName    = 'Debug SA-09 Local+SMB (same Core SMB path)'
                agentType      = 'General'
                isPredefined   = $false
                policyRawData  = $raw
            }
        )
        policyAssociations = @(
            @{
                name       = $AssignmentRuleName
                enabled    = $true
                policies   = @([string]$policyId)
                conditions = @(
                    @{
                        item      = 'agent_type'
                        condition = 'is_one_of'
                        target    = 'scan_agent'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-ScanAgentSa09CoreDebugPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test9-smb-local',
        [int] $AgentPolicyWaitSec = 180,
        [int] $AgentDisconnectHoldSec = 5,
        [int] $UiWaitMs = 120000
    )

    $resolvedBase = Resolve-ScanAgentSa05PolicyBaseRaw `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Core importpolicies policy base: $($resolvedBase.Source)"
    $importBody = New-Sa09CorePolicyImportBody `
        -PolicyBaseRaw $resolvedBase.BaseRaw -PolicyTemplateXml '' `
        -TemplatePolicyName $TemplatePolicyName -PolicyName $PolicyName

    $import = Invoke-ScanAgentCoreDebugHook -HookUrl $HookUrl -Command 'importpolicies' -BodyObject $importBody
    Assert-ScanAgentCoreDebugHookResponse -Response $import -Step 'importpolicies (SA-09)'

    Disconnect-AllCoreAgentsForRefresh -HookUrl $HookUrl -Exe $Exe -DisconnectHoldSec $AgentDisconnectHoldSec

    $null = Wait-ScanAgentPolicyListContainsNames -Exe $Exe -PolicyNames @($PolicyName) `
        -TimeoutSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    $policyList = Invoke-ScanAgentDebugJson -Exe $Exe -Arguments @('policy.list')
    if ($policyList.ok -ne $true) {
        throw 'policy.list failed after SA-09 Core import and agent reconnect.'
    }

    $listedNames = @($policyList.policies | ForEach-Object { [string]$_.name })
    if ($listedNames -notcontains $PolicyName) {
        throw "Agent policy.list is missing policy '$PolicyName'. Listed: $($listedNames -join ', ')."
    }

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [STEP] Agent policy.list includes $PolicyName."

    return [pscustomobject]@{
        PolicyBaseSource = $resolvedBase.Source
        PolicyName       = $PolicyName
        SmbInFolder      = $script:Sa09SmbInFolder
        SmbOutFolder     = $script:Sa09SmbOutFolder
        LocalOutFolder   = $script:Sa09LocalOutFolder
        SmbStoreIn       = $script:Sa09SmbStoreIn
        SmbStoreOut      = $script:Sa09SmbStoreOut
        ImportResponse   = $import
        AgentPolicyList  = $policyList
    }
}

function Initialize-ScanAgentSa09CoreTestPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $Exe,
        [string] $CoreDebugHookUrl,
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = 'Test9-smb-local',
        [int] $AgentPolicyWaitSec = 180,
        [int] $UiWaitMs = 120000
    )

    $pushed = Push-ScanAgentSa05CorePolicyState -CoreDebugHookUrl $CoreDebugHookUrl
    $imported = Import-ScanAgentSa09CoreDebugPolicy -HookUrl $pushed.HookUrl -Exe $Exe `
        -PolicyBaseRaw $PolicyBaseRaw -PolicyTemplateXml $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName `
        -PolicyName $PolicyName -AgentPolicyWaitSec $AgentPolicyWaitSec -UiWaitMs $UiWaitMs

    return [pscustomobject]@{
        HookUrl          = $pushed.HookUrl
        PolicyBaseSource = $imported.PolicyBaseSource
        PolicyName       = $imported.PolicyName
        SmbInFolder      = $imported.SmbInFolder
        SmbOutFolder     = $imported.SmbOutFolder
        LocalOutFolder   = $imported.LocalOutFolder
        SmbStoreIn       = $imported.SmbStoreIn
        SmbStoreOut      = $imported.SmbStoreOut
        PushResponse     = $pushed.PushResponse
        ImportResponse   = $imported.ImportResponse
        AgentPolicyList  = $imported.AgentPolicyList
    }
}
