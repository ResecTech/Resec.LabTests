#Requires -Version 5.1
<#
.SYNOPSIS
  NCP-7365 lab policies and policy assignment rules covering every PolicyConditions schema field.

.NOTES
  Uses debug importpolicies (push/import/pop). Facet raw data matches NCP-7344 no-CDR lab shape.
#>
Set-StrictMode -Version Latest

$script:Ncp7365LabPolicyName = 'NCP7365-lab-baseline'
$script:Ncp7365LargeFilePolicyName = 'NCP7365-large-file-policy'
$script:Ncp7365LabPolicyPlaceholderId = 7365
$script:Ncp7365LargeFilePolicyPlaceholderId = 7366
$script:Ncp7365FiveHundredMbBytes = 524288000
$script:Ncp7365SanitizeFileSizeThresholdBytes = 4096

. (Join-Path $PSScriptRoot 'CoreE2eNcp7344Policy.ps1')
. (Join-Path $PSScriptRoot 'CoreE2eWmcApi.ps1')

function New-Ncp7365PolicyConditionRule {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Item,
        [Parameter(Mandatory)]
        [string] $Condition,
        [Parameter(Mandatory)]
        [string] $Target,
        [string] $Unit = '',
        [string[]] $PolicyNames = @($script:Ncp7365LabPolicyName)
    )

    $conditionRow = [ordered]@{
        item      = $Item
        condition = $Condition
        target    = $Target
        op        = 'AND'
    }
    # WebMC persists file_size as magnitude + unit (e.g. target=10, unit=KB). Core must honor unit.
    if (-not [string]::IsNullOrWhiteSpace($Unit)) {
        $conditionRow['unit'] = $Unit
    }

    return [ordered]@{
        name       = $Name
        enabled    = $true
        policies   = @($PolicyNames)
        conditions = @($conditionRow)
    }
}

function Get-Ncp7365PolicyAssignmentRules {
    $largePolicy = $script:Ncp7365LargeFilePolicyName

    return @(
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-agent-scan' -Item 'agent_type' -Condition 'is_one_of' -Target 'scan_agent')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-agent-dir-watcher' -Item 'agent_type' -Condition 'is_one_of' -Target 'dir_watcher')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-agent-kiosk' -Item 'agent_type' -Condition 'is_one_of' -Target 'kiosk')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-agent-mail' -Item 'agent_type' -Condition 'is_one_of' -Target 'mail_agent')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-agent-rest' -Item 'agent_type' -Condition 'is_one_of' -Target 'rest_api')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-encrypted' -Item 'file_encrypted' -Condition 'eq' -Target 'true')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-path' -Item 'file_path' -Condition 'matches' -Target 'NCP7365-path-marker')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-mail-body-html' -Item 'mail_body_format' -Condition 'is_one_of' -Target 'html')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-mail-from' -Item 'email_from' -Condition 'matches' -Target '.*@ncp7365\.example$')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-mail-has-attachment' -Item 'mail_has_attachment' -Condition 'eq' -Target 'true')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-mail-has-header' -Item 'mail_has_header' -Condition 'eq' -Target 'X-NCP7365-Lab')
        # starts_with compiles as regex ^(?:target) — brackets are a character class, so use a literal-safe prefix.
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-mail-subject' -Item 'email_subject' -Condition 'starts_with' -Target 'NCP7365:')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-mail-to' -Item 'email_to' -Condition 'matches' -Target 'recipient@ncp7365\.example')
        # NCP-7365: WebMC shape (magnitude + unit), not pre-expanded byte strings.
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-size-gt-500mb' -Item 'file_size' -Condition 'gt' -Target '500' -Unit 'MB')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-size-lt-100' -Item 'file_size' -Condition 'lt' -Target '100' -Unit 'bytes')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-size-eq-7777' -Item 'file_size' -Condition 'eq' -Target '7777' -Unit 'bytes')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-user-group' -Item 'user_group' -Condition 'is_one_of' -Target 'NCP7365-LabGroupA,NCP7365-LabGroupB')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-user-name' -Item 'user_name' -Condition 'is_one_of' -Target 'resec.cloud/ncp7365-user')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-organizational-unit' -Item 'organizational_unit' -Condition 'is_one_of' -Target 'resec.cloud/NCP7365-OU')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-computer-name' -Item 'computer_name' -Condition 'is_one_of' -Target 'NCP7365-PC01')
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-size-gt-4k' -Item 'file_size' -Condition 'gt' -Target '4' -Unit 'KB' -PolicyNames @($largePolicy))
    )
}

function New-Ncp7365PolicyAssignmentImportBody {
    param(
        [string] $BaselinePolicyName = $script:Ncp7365LabPolicyName,
        [string] $LargeFilePolicyName = $script:Ncp7365LargeFilePolicyName,
        [object[]] $PolicyAssociations = $null
    )

    $raw = Get-Ncp7344OfficeNoCdrLabPolicyRawData
    if ($null -eq $PolicyAssociations) {
        $PolicyAssociations = @(Get-Ncp7365PolicyAssignmentRules)
    }

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $script:Ncp7365LabPolicyPlaceholderId
                name          = $BaselinePolicyName
                displayName   = 'NCP-7365 lab baseline (policy assignment E2E)'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $raw
            }
            @{
                id            = $script:Ncp7365LargeFilePolicyPlaceholderId
                name          = $LargeFilePolicyName
                displayName   = 'NCP-7365 large-file assignment target'
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $raw
            }
        )
        policyAssociations = @($PolicyAssociations)
    }
}

function Get-Ncp7365SanitizeFileSizeAssignmentRules {
    $largePolicy = $script:Ncp7365LargeFilePolicyName
    return @(
        # Same WebMC shape as Size > 10KB (target magnitude + unit), not raw byte string.
        (New-Ncp7365PolicyConditionRule -Name 'NCP7365-file-size-gt-4k' -Item 'file_size' -Condition 'gt' -Target '4' -Unit 'KB' -PolicyNames @($largePolicy))
    )
}

function Import-Ncp7365PolicyAssignmentLabPolicies {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    $body = New-Ncp7365PolicyAssignmentImportBody
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}

function Import-Ncp7365SanitizeFileSizeLabPolicies {
    <#
    .SYNOPSIS
      Re-import baseline + large-file policies with only the file_size > 4 KiB rule.
    .NOTES
      Full assignment set includes agent_type rules that match first on real deployments, so the
      sanitize size rule would never be evaluated. Isolate it for the debug-sanitize phase.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl
    )

    $body = New-Ncp7365PolicyAssignmentImportBody -PolicyAssociations @(Get-Ncp7365SanitizeFileSizeAssignmentRules)
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}

function Invoke-CoreE2ePolicyConditionsSimulate {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [hashtable] $BodyObject
    )

    return Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
        -Path '/v1/policies/conditions/simulate' -Method Post -BodyObject $BodyObject
}

function Assert-CoreE2ePolicyConditionSimulateMatch {
    param(
        [Parameter(Mandatory)]
        $Response,
        [Parameter(Mandatory)]
        [string] $ExpectedRuleName,
        [string] $ScenarioLabel = ''
    )

    $matched = [bool](Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('matched', 'Matched'))
    if (-not $matched) {
        $label = if ([string]::IsNullOrWhiteSpace($ScenarioLabel)) { $ExpectedRuleName } else { $ScenarioLabel }
        throw "Policy condition simulate expected match for rule '$ExpectedRuleName' ($label) but matched=false."
    }

    $ruleName = [string](Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('ruleName', 'RuleName'))
    if ($ruleName -ne $ExpectedRuleName) {
        throw "Policy condition simulate expected rule '$ExpectedRuleName' but got '$ruleName'."
    }
}

function Assert-CoreE2ePolicyConditionSimulateNoMatch {
    param(
        [Parameter(Mandatory)]
        $Response,
        [string] $ScenarioLabel = ''
    )

    $matched = [bool](Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('matched', 'Matched'))
    if ($matched) {
        $ruleName = [string](Get-CoreE2eWmcRestPropertyValue -Object $Response -Names @('ruleName', 'RuleName'))
        $label = if ([string]::IsNullOrWhiteSpace($ScenarioLabel)) { 'negative case' } else { $ScenarioLabel }
        throw "Policy condition simulate expected no match ($label) but matched rule '$ruleName'."
    }
}

function New-Ncp7365SimulateBody {
    <#
    .SYNOPSIS
      Simulate request with a full context that matches none of the imported NCP-7365 rules,
      then overlay field overrides for the case under test.
    .NOTES
      Omitted fields default in Core (fileSize=0, bools=false, strings empty). fileSize=0 matches
      the imported lt-100 rule, so every request must set a neutral baseline.
    #>
    param([hashtable] $Overrides = @{})

    $body = @{
        agentType           = 'ncp7365_uncovered_agent'
        userName            = 'resec.cloud/ncp7365-neutral-user'
        userGroups          = @('NCP7365-NeutralGroup')
        organizationalUnit  = 'resec.cloud/NCP7365-Neutral-OU'
        computerName        = 'NCP7365-NEUTRAL-PC'
        filePath            = 'C:\lab\neutral\sample.bin'
        fileSize            = 2000
        fileEncrypted       = $false
        emailFrom           = 'neutral@other.example'
        emailTo             = 'neutral-to@other.example'
        emailSubject        = 'Neutral subject'
        mailHasAttachment   = $false
        mailHeaderNames     = @('From')
        mailBodyFormat      = 'text'
    }

    foreach ($key in @($Overrides.Keys)) {
        $body[$key] = $Overrides[$key]
    }

    return $body
}

function Get-Ncp7365PolicyConditionSimulateCases {
    $mb500 = $script:Ncp7365FiveHundredMbBytes
    $above500Mb = $mb500 + 1
    $neutralBody = New-Ncp7365SimulateBody

    return @(
        @{
            Label            = 'Agent: Type (scan_agent)'
            ExpectedRuleName = 'NCP7365-agent-scan'
            MatchBody        = New-Ncp7365SimulateBody @{ agentType = 'scan_agent' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Agent: Type (dir_watcher)'
            ExpectedRuleName = 'NCP7365-agent-dir-watcher'
            MatchBody        = New-Ncp7365SimulateBody @{ agentType = 'dir_watcher' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Agent: Type (kiosk)'
            ExpectedRuleName = 'NCP7365-agent-kiosk'
            MatchBody        = New-Ncp7365SimulateBody @{ agentType = 'kiosk' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Agent: Type (mail_agent)'
            ExpectedRuleName = 'NCP7365-agent-mail'
            MatchBody        = New-Ncp7365SimulateBody @{ agentType = 'mail_agent' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Agent: Type (rest_api)'
            ExpectedRuleName = 'NCP7365-agent-rest'
            MatchBody        = New-Ncp7365SimulateBody @{ agentType = 'rest_api' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'File: Encrypted'
            ExpectedRuleName = 'NCP7365-file-encrypted'
            MatchBody        = New-Ncp7365SimulateBody @{ fileEncrypted = $true }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'File: Path'
            ExpectedRuleName = 'NCP7365-file-path'
            MatchBody        = New-Ncp7365SimulateBody @{ filePath = 'C:\lab\NCP7365-path-marker\sample.bin' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Mail: Body Format'
            ExpectedRuleName = 'NCP7365-mail-body-html'
            MatchBody        = New-Ncp7365SimulateBody @{ mailBodyFormat = 'html' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Mail: From'
            ExpectedRuleName = 'NCP7365-mail-from'
            MatchBody        = New-Ncp7365SimulateBody @{ emailFrom = 'sender@ncp7365.example' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Mail: Has Attachment'
            ExpectedRuleName = 'NCP7365-mail-has-attachment'
            MatchBody        = New-Ncp7365SimulateBody @{ mailHasAttachment = $true }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Mail: Has Header'
            ExpectedRuleName = 'NCP7365-mail-has-header'
            MatchBody        = New-Ncp7365SimulateBody @{ mailHeaderNames = @('From', 'X-NCP7365-Lab') }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Mail: Subject'
            ExpectedRuleName = 'NCP7365-mail-subject'
            MatchBody        = New-Ncp7365SimulateBody @{ emailSubject = 'NCP7365: lab subject' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'Mail: To'
            ExpectedRuleName = 'NCP7365-mail-to'
            MatchBody        = New-Ncp7365SimulateBody @{ emailTo = 'recipient@ncp7365.example' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'File: Size > 500 MB (NCP-7365 ticket threshold)'
            ExpectedRuleName = 'NCP7365-file-size-gt-500mb'
            MatchBody        = New-Ncp7365SimulateBody @{ fileSize = $above500Mb }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'File: Size < 100 bytes'
            ExpectedRuleName = 'NCP7365-file-size-lt-100'
            MatchBody        = New-Ncp7365SimulateBody @{ fileSize = 50 }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'File: Size = 7777 bytes'
            ExpectedRuleName = 'NCP7365-file-size-eq-7777'
            MatchBody        = New-Ncp7365SimulateBody @{ fileSize = 7777 }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'User: Group'
            ExpectedRuleName = 'NCP7365-user-group'
            MatchBody        = New-Ncp7365SimulateBody @{ userGroups = @('NCP7365-LabGroupB', 'Other') }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'User: Name'
            ExpectedRuleName = 'NCP7365-user-name'
            MatchBody        = New-Ncp7365SimulateBody @{ userName = 'resec.cloud/ncp7365-user' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'User: Organizational Unit'
            ExpectedRuleName = 'NCP7365-organizational-unit'
            MatchBody        = New-Ncp7365SimulateBody @{ organizationalUnit = 'resec.cloud/NCP7365-OU' }
            NegativeBody     = $neutralBody
        }
        @{
            Label            = 'User: Computer Name'
            ExpectedRuleName = 'NCP7365-computer-name'
            MatchBody        = New-Ncp7365SimulateBody @{ computerName = 'NCP7365-PC01' }
            NegativeBody     = $neutralBody
        }
    )
}

function Get-CoreE2eSanitizationLogHistory {
    param(
        [Parameter(Mandatory)]
        [string] $BaseUrl,
        [Parameter(Mandatory)]
        [string] $ApiToken,
        [Parameter(Mandatory)]
        [int] $SanitizationId
    )

    $path = '/v1/sanitizations/details?sanitizationId={0}' -f $SanitizationId
    $response = Invoke-CoreE2eWmcRestMethod -BaseUrl $BaseUrl -ApiToken $ApiToken `
        -Path $path -Method Get

    $logHistory = [string](Get-CoreE2eWmcRestPropertyValue -Object $response -Names @('logHistory', 'LogHistory'))
    return $logHistory
}
