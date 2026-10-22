#Requires -Version 5.1
<#
.SYNOPSIS
  Builds importpolicies payload for NCP-7330 QR image lab policy (single policy, no agent locations required).
#>
Set-StrictMode -Version Latest

$script:Ncp7330LabPolicyName = 'NCP7330-qr-lab'
$script:Ncp7330LabPolicyPlaceholderId = 9330

function Resolve-CoreE2ePolicyTemplateXml {
    param([string] $OverridePath)

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $full = [System.IO.Path]::GetFullPath($OverridePath)
        if (-not (Test-Path -LiteralPath $full)) {
            throw "Policy template XML not found: $full"
        }
        return $full
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_POLICY_TEMPLATE_XML)) {
        $full = [System.IO.Path]::GetFullPath($env:CORE_E2E_POLICY_TEMPLATE_XML.Trim())
        if (Test-Path -LiteralPath $full) {
            return $full
        }
    }

    $importDir = 'C:\resec\ImportExport'
    if (Test-Path -LiteralPath $importDir) {
        $latest = Get-ChildItem -LiteralPath $importDir -Filter 'ImportExport_*.xml' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latest) {
            return $latest.FullName
        }
    }

    throw @'
Core E2E policy import needs a WebMC export XML with a Scan Agent-style template (Local Source facet).
Set -PolicyTemplateXml, CORE_E2E_POLICY_TEMPLATE_XML, or place ImportExport_*.xml under C:\resec\ImportExport.
'@
}

function Resolve-CoreE2eTemplatePolicyFromXml {
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
    if (-not [string]::IsNullOrWhiteSpace($env:CORE_E2E_TEMPLATE_POLICY_NAME)) {
        $nameCandidates += $env:CORE_E2E_TEMPLATE_POLICY_NAME.Trim()
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
    throw "Policy template XML has no usable template policy. Available: $available"
}

function Remove-CoreE2ePolicyFacetBlock {
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

function Remove-CoreE2eLocationFacetsFromPolicyRaw {
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
        $raw = Remove-CoreE2ePolicyFacetBlock -PolicyRawData $raw -FacetHeader $header
    }
    return $raw
}

function Set-CoreE2ePolicyRawRemainConnected {
    param([Parameter(Mandatory)][string] $PolicyRawData)

    if ($PolicyRawData -match 'NumPropType_AutoReconnect=False') {
        return [regex]::Replace($PolicyRawData, 'NumPropType_AutoReconnect=False', 'NumPropType_AutoReconnect=True')
    }

    if ($PolicyRawData -notmatch 'NumPropType_AutoReconnect=') {
        return "NumPropType_AutoReconnect=True`r`n" + $PolicyRawData
    }

    return $PolicyRawData
}

function New-Ncp7330QrLabPolicyImportBody {
    param(
        [Parameter(Mandatory)]
        [string] $TemplateXmlPath,
        [string] $TemplatePolicyName = '',
        [string] $PolicyName = $script:Ncp7330LabPolicyName
    )

    [xml]$doc = Get-Content -LiteralPath $TemplateXmlPath -Encoding UTF8
    $templatePolicy = Resolve-CoreE2eTemplatePolicyFromXml `
        -PolicyNodes $doc.ImportExportContainer.Policies.Policy `
        -TemplatePolicyName $TemplatePolicyName

    $baseRaw = [string]$templatePolicy.PolicyRawData
    if ([string]::IsNullOrWhiteSpace($baseRaw)) {
        throw "Template policy '$($templatePolicy.Name)' has empty PolicyRawData."
    }

    $baseRaw = Remove-CoreE2eLocationFacetsFromPolicyRaw -PolicyRawData $baseRaw
    $baseRaw = Set-CoreE2ePolicyRawRemainConnected -PolicyRawData $baseRaw

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:Ncp7330LabPolicyPlaceholderId
                name          = $PolicyName
                displayName   = 'NCP-7330 QR image lab (debug sanitize)'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $baseRaw
            }
        )
        policyAssociations = @()
    }
}
