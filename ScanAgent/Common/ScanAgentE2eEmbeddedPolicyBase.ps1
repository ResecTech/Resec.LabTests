#Requires -Version 5.1
<#
.SYNOPSIS
  Embedded Scan Agent policy PolicyRawData base for Core debug importpolicies (no WebMC XML).

.NOTES
  Location facets (SMB Source/Destination, Local Source, etc.) are added by ScanAgentE2eCorePolicy.ps1 helpers.
  Override per run with -PolicyBaseRaw on SA-05/SA-08 or SCANAGENT_SA05_POLICY_BASE_RAW env (full base string).
  Legacy WebMC export: -PolicyTemplateXml or SCANAGENT_SA05_POLICY_TEMPLATE_XML.
#>
Set-StrictMode -Version Latest

function Get-ScanAgentE2eEmbeddedPolicyBaseRaw {
    <#
    .SYNOPSIS
      Lab-minimal policy base shared by SA-05, SA-08, and NCP7328 Core hook imports.
    #>
    return @'
;Facet Basic Settings:Basic Settings
StrPropType_ConfigVersion=Auto
StrPropType_AllowedFileTypes=Executable=True|Document=True|Encrypted=True|Archive=True|Database=True|Image=True|Script=True|XML=True|Video=True|Model=True|Movie=True|Audio=True|Other=True|Unknown=True
StrPropType_SignFiles=False
NumPropType_MaxArchiveRecursionLevels=5
NumPropType_DisallowedFilesInArchivesBehaviour=1
NumPropType_MaxUploadSize=0
NumPropType_BlockIncorrectUploadExtension=False
;Facet Advanced:Advanced
NumPropType_CheckServerCertificate=False
NumPropType_KeepAliveSec=10
NumPropType_CopyLocalFiles=True
NumPropType_HashAlgorithm=1
NumPropType_DisconnectSec=30
NumPropType_AutoReconnect=True
NumPropType_StoreBlockedFileReport=True
;Facet System Health:System Health
NumPropType_MinNumberOfValidScanners=0
NumPropType_MaxScannersDefinitionAge=168
;Facet Agent Settings:Agent Settings
StrPropType_StatusMessage=$(server)
StrPropType_DetailsMessage=Lab E2E embedded policy
NumPropType_CommunicationUploadLimitKbps=0
NumPropType_DeleteInfectedFromSource=False
NumPropType_RebootOnExit=False
NumPropType_OpenUIOnExit=0
NumPropType_InactivityTimeout=0
NumPropType_ShowPreview=True
NumPropType_LoginFailAttemptsNo=5
NumPropType_LoginFailAttemptsLockTimeout=60
NumPropType_RebootOnInfectedResult=False
NumPropType_RebootWaitTimeout=30
NumPropType_IsAgentDisabled=0
StrPropType_DisabledReasonMessage=
NumPropType_EnforceScanComment=False
NumPropType_AllowOneScanOnly=False
;Facet Format Transformations:Format Transformations
NumPropType_OfficeTransformation=0
NumPropType_PdfTransformation=2
NumPropType_ImageTransformation=2
NumPropType_HtmlTransformation=1
NumPropType_VisioTransformation=1
NumPropType_ImagePixelThreshold=0
'@
}

function Get-ScanAgentSa05PolicyBaseRawFromTemplateXml {
    param(
        [Parameter(Mandatory)]
        [string] $TemplateXmlPath,
        [string] $TemplatePolicyName = ''
    )

    $full = [System.IO.Path]::GetFullPath($TemplateXmlPath)
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Policy template XML not found: $full"
    }

    [xml]$doc = Get-Content -LiteralPath $full -Encoding UTF8
    $templatePolicy = Resolve-Sa05TemplatePolicyFromXml `
        -PolicyNodes $doc.ImportExportContainer.Policies.Policy `
        -TemplatePolicyName $TemplatePolicyName

    $baseRaw = [string]$templatePolicy.PolicyRawData
    if ([string]::IsNullOrWhiteSpace($baseRaw)) {
        throw "Template policy '$($templatePolicy.Name)' in $full has empty PolicyRawData."
    }

    return $baseRaw
}

function Resolve-ScanAgentSa05PolicyBaseRaw {
    param(
        [string] $PolicyBaseRaw = '',
        [string] $PolicyTemplateXml = '',
        [string] $TemplatePolicyName = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($PolicyBaseRaw)) {
        return @{
            BaseRaw = $PolicyBaseRaw
            Source  = 'parameter:PolicyBaseRaw'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:SCANAGENT_SA05_POLICY_BASE_RAW)) {
        return @{
            BaseRaw = $env:SCANAGENT_SA05_POLICY_BASE_RAW
            Source  = 'env:SCANAGENT_SA05_POLICY_BASE_RAW'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PolicyTemplateXml)) {
        $fromFile = Get-ScanAgentSa05PolicyBaseRawFromTemplateXml `
            -TemplateXmlPath $PolicyTemplateXml -TemplatePolicyName $TemplatePolicyName
        return @{
            BaseRaw = $fromFile
            Source  = "xml:$([System.IO.Path]::GetFullPath($PolicyTemplateXml))"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:SCANAGENT_SA05_POLICY_TEMPLATE_XML)) {
        $envPath = $env:SCANAGENT_SA05_POLICY_TEMPLATE_XML.Trim()
        $fromEnv = Get-ScanAgentSa05PolicyBaseRawFromTemplateXml `
            -TemplateXmlPath $envPath -TemplatePolicyName $TemplatePolicyName
        return @{
            BaseRaw = $fromEnv
            Source  = "xml:$([System.IO.Path]::GetFullPath($envPath))"
        }
    }

    return @{
        BaseRaw = Get-ScanAgentE2eEmbeddedPolicyBaseRaw
        Source  = 'embedded:ScanAgentE2eEmbeddedPolicyBase.ps1'
    }
}
