#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook importpolicies helpers for DirWatcher lab E2E (NCP-7340, NCP-7343, NCP-7361).
.NOTES
  Uses valid facet template names (see core-lab-policy-injection rule). Association target: dir_watcher.
#>
Set-StrictMode -Version Latest

$script:DwNcp7340LabPolicyName = 'NCP7340-dw-lab'
$script:DwNcp7340LabPolicyPlaceholderId = 9340
$script:DwNcp7340DefaultAssignmentRuleName = 'debug-dir-watcher-ncp7340'

$script:DwNcp7343LabPolicyName = 'NCP7343-dw-lab'
$script:DwNcp7343LabPolicyPlaceholderId = 9343
$script:DwNcp7343DefaultAssignmentRuleName = 'debug-dir-watcher-ncp7343'

$script:DwNcp7361LabPolicyName = 'NCP7361-dw-rejected-save-lab'
$script:DwNcp7361LabPolicyPlaceholderId = 9361
$script:DwNcp7361DefaultAssignmentRuleName = 'debug-dir-watcher-ncp7361'

$script:DwNcp7377LabPolicyName = 'NCP7377-dw-periodic-stop-regex-lab'
$script:DwNcp7377LabPolicyPlaceholderId = 9377
$script:DwNcp7377DefaultAssignmentRuleName = 'debug-dir-watcher-ncp7377'

function New-DwNcp7340DirectoryWatcherFacetBlock {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $DestinationStoreName,
        [bool] $ProcessEmptyFolders = $false,
        [int] $DeleteProcessedFoldersAfterMinutes = 0,
        [bool] $EnablePeriodicFileCheck = $false,
        [bool] $ProcessPreExistingFiles = $false,
        [string] $PeriodicFileCheckStopRegex = '',
        [string] $IncludeFolderMask = '',
        [string] $ExcludeFolderMask = '',
        [ValidateSet(0, 1, 2)]
        [int] $RejectedBehavior = 1
    )

    $incoming = [System.IO.Path]::GetFullPath($IncomingRoot)
    $temp = [System.IO.Path]::GetFullPath($TempRoot)
    $rejected = [System.IO.Path]::GetFullPath($RejectedRoot)
    $processEmptyFoldersValue = if ($ProcessEmptyFolders) { 1 } else { 0 }
    $periodicFileCheckValue = if ($EnablePeriodicFileCheck) { 1 } else { 0 }
    $processPreExistingFilesValue = if ($ProcessPreExistingFiles) { 1 } else { 0 }

    return @"
;Facet Directory Watcher Settings:Directory Watcher Settings
ListPropType_DirectoryWatcherRootFolder=$incoming
ListPropType_DirectoryWatcherFileStoreName=$DestinationStoreName
IntPropType_DirectoryWatcherRejectedBehavior=$RejectedBehavior
ListPropType_DirectoryWatcherRejectedFolder=$rejected
ListPropType_DirectoryWatcherTempFolder=$temp
ListPropType_DirectoryWatcherIncludeFolderMask=$IncludeFolderMask
ListPropType_DirectoryWatcherExcludeFolderMask=$ExcludeFolderMask
StrPropType_DirectoryWatcherPeriodicFileCheckRegex=$PeriodicFileCheckStopRegex
NumPropType_DirectoryWatcherProcessPreExistingFiles=$processPreExistingFilesValue
NumPropType_DirectoryWatcherProcessPreExistingTempFiles=0
NumPropType_DirectoryWatcherIgnoreEmptyFiles=1
NumPropType_DirectoryWatcherIgnoreEmptyFolders=$processEmptyFoldersValue
NumPropType_DirectoryWatcherDoNotDeleteSourceFiles=0
NumPropType_DirectoryWatcherProcessOnlyNonArchivedFiles=0
NumPropType_DirectoryWatcherOsHookTestInterval=0
NumPropType_DirectoryWatcherEnablePeriodicFileCheck=$periodicFileCheckValue
NumPropType_DirectoryWatcherDeleteProcessedFolders=$DeleteProcessedFoldersAfterMinutes

"@
}

function New-DwNcp7340CorePolicyImportBody {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [string] $PolicyName = '',
        [string] $DestinationStoreName = 'dw7340-out',
        [string] $AssignmentRuleName = ''
    )

    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $PolicyName = $script:DwNcp7340LabPolicyName
    }
    if ([string]::IsNullOrWhiteSpace($AssignmentRuleName)) {
        $AssignmentRuleName = $script:DwNcp7340DefaultAssignmentRuleName
    }

    $baseRaw = Get-Ncp7344OfficeNoCdrLabPolicyRawData
    $dwRaw = New-DwNcp7340DirectoryWatcherFacetBlock `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot `
        -DestinationStoreName $DestinationStoreName
    $destRaw = New-Sa05SmbDestinationFacet -StoreName $DestinationStoreName -RootFolder $CleanRoot -SortOrder 2
    $policyRaw = $baseRaw + $dwRaw + $destRaw

    $policyId = $script:DwNcp7340LabPolicyPlaceholderId

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $policyId
                name          = $PolicyName
                displayName   = "NCP-7340 DirWatcher lab ($IncomingRoot -> $CleanRoot)"
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $policyRaw
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
                        target    = 'dir_watcher'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-DwNcp7340LabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [string] $PolicyName = ''
    )

    $body = New-DwNcp7340CorePolicyImportBody `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot -CleanRoot $CleanRoot `
        -PolicyName $PolicyName
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}

function New-DwNcp7343CorePolicyImportBody {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [string] $PolicyName = '',
        [string] $DestinationStoreName = 'dw7343-out',
        [string] $AssignmentRuleName = '',
        [int] $DeleteProcessedFoldersAfterMinutes = 0,
        [bool] $EnablePeriodicFileCheck = $false
    )

    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $PolicyName = $script:DwNcp7343LabPolicyName
    }
    if ([string]::IsNullOrWhiteSpace($AssignmentRuleName)) {
        $AssignmentRuleName = $script:DwNcp7343DefaultAssignmentRuleName
    }

    $baseRaw = Get-Ncp7344OfficeNoCdrLabPolicyRawData
    $dwRaw = New-DwNcp7340DirectoryWatcherFacetBlock `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot `
        -DestinationStoreName $DestinationStoreName -ProcessEmptyFolders:$true `
        -DeleteProcessedFoldersAfterMinutes $DeleteProcessedFoldersAfterMinutes `
        -EnablePeriodicFileCheck:$EnablePeriodicFileCheck
    $destRaw = New-Sa05SmbDestinationFacet -StoreName $DestinationStoreName -RootFolder $CleanRoot -SortOrder 2
    $policyRaw = $baseRaw + $dwRaw + $destRaw

    $policyId = $script:DwNcp7343LabPolicyPlaceholderId

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $policyId
                name          = $PolicyName
                displayName   = "NCP-7343 DirWatcher lab ($IncomingRoot -> $CleanRoot)"
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $policyRaw
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
                        target    = 'dir_watcher'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-DwNcp7343LabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [string] $PolicyName = '',
        [int] $DeleteProcessedFoldersAfterMinutes = 0,
        [bool] $EnablePeriodicFileCheck = $false
    )

    $body = New-DwNcp7343CorePolicyImportBody `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot -CleanRoot $CleanRoot `
        -PolicyName $PolicyName `
        -DeleteProcessedFoldersAfterMinutes $DeleteProcessedFoldersAfterMinutes `
        -EnablePeriodicFileCheck:$EnablePeriodicFileCheck
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}

function Get-Ncp7361DwLabPolicyRawData {
    $raw = Get-Ncp7344OfficeNoCdrLabPolicyRawData
    # Unknown File=False (same as NCP-7352/7360 lab) so a non-FTD payload is blocked by policy, not Scripts=.
    $allowed = 'Archives=True|CAD=True|Databases=True|Documents (Common)=True|Documents (Uncommon)=True|Email=True|Embedded Office Objects=True|Executables=True|Images=True|Media Files=True|Model=True|Others=True|Scripts=True|Unknown File=False|Unsafe=True'
    if ($raw -match '(?m)^StrPropType_AllowedFileTypes=.*$') {
        return [regex]::Replace($raw, '(?m)^StrPropType_AllowedFileTypes=.*$', "StrPropType_AllowedFileTypes=$allowed")
    }

    throw 'NCP-7361 lab policy: could not patch StrPropType_AllowedFileTypes on NCP7344 base raw data.'
}

function New-DwNcp7361CorePolicyImportBody {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [ValidateSet(0, 1)]
        [int] $RejectedBehavior = 0,
        [string] $PolicyName = '',
        [string] $DestinationStoreName = 'dw7361-out',
        [string] $AssignmentRuleName = ''
    )

    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $PolicyName = $script:DwNcp7361LabPolicyName
    }
    if ([string]::IsNullOrWhiteSpace($AssignmentRuleName)) {
        $AssignmentRuleName = $script:DwNcp7361DefaultAssignmentRuleName
    }

    $baseRaw = Get-Ncp7361DwLabPolicyRawData
    $dwRaw = New-DwNcp7340DirectoryWatcherFacetBlock `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot `
        -DestinationStoreName $DestinationStoreName -RejectedBehavior $RejectedBehavior `
        -ProcessPreExistingFiles $true
    $destRaw = New-Sa05SmbDestinationFacet -StoreName $DestinationStoreName -RootFolder $CleanRoot -SortOrder 2
    $policyRaw = $baseRaw + $dwRaw + $destRaw

    $policyId = $script:DwNcp7361LabPolicyPlaceholderId

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $policyId
                name          = $PolicyName
                displayName   = "NCP-7361 DirWatcher rejected save ($IncomingRoot -> rejected=$RejectedRoot)"
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $policyRaw
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
                        target    = 'dir_watcher'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-DwNcp7361LabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [ValidateSet(0, 1)]
        [int] $RejectedBehavior = 0,
        [string] $PolicyName = ''
    )

    $body = New-DwNcp7361CorePolicyImportBody `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot -CleanRoot $CleanRoot `
        -RejectedBehavior $RejectedBehavior -PolicyName $PolicyName
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}

function New-DwNcp7377CorePolicyImportBody {
    param(
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [string] $PeriodicFileCheckStopRegex = '.*\stop',
        [string] $PolicyName = '',
        [string] $DestinationStoreName = 'dw7377-out',
        [string] $AssignmentRuleName = ''
    )

    if ([string]::IsNullOrWhiteSpace($PolicyName)) {
        $PolicyName = $script:DwNcp7377LabPolicyName
    }
    if ([string]::IsNullOrWhiteSpace($AssignmentRuleName)) {
        $AssignmentRuleName = $script:DwNcp7377DefaultAssignmentRuleName
    }

    $baseRaw = Get-Ncp7344OfficeNoCdrLabPolicyRawData
    $dwRaw = New-DwNcp7340DirectoryWatcherFacetBlock `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot `
        -DestinationStoreName $DestinationStoreName `
        -ProcessPreExistingFiles:$false `
        -EnablePeriodicFileCheck:$true `
        -PeriodicFileCheckStopRegex $PeriodicFileCheckStopRegex
    $destRaw = New-Sa05SmbDestinationFacet -StoreName $DestinationStoreName -RootFolder $CleanRoot -SortOrder 2
    $policyRaw = $baseRaw + $dwRaw + $destRaw

    $policyId = $script:DwNcp7377LabPolicyPlaceholderId

    return [ordered]@{
        command            = 'importpolicies'
        policies           = @(
            @{
                id            = $policyId
                name          = $PolicyName
                displayName   = "NCP-7377 DirWatcher periodic stop regex ($IncomingRoot -> $CleanRoot)"
                agentType     = 'General'
                isPredefined  = $false
                policyRawData = $policyRaw
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
                        target    = 'dir_watcher'
                        op        = 'AND'
                    }
                )
            }
        )
    }
}

function Import-DwNcp7377LabPolicy {
    param(
        [Parameter(Mandatory)]
        [string] $HookUrl,
        [Parameter(Mandatory)]
        [string] $IncomingRoot,
        [Parameter(Mandatory)]
        [string] $TempRoot,
        [Parameter(Mandatory)]
        [string] $RejectedRoot,
        [Parameter(Mandatory)]
        [string] $CleanRoot,
        [string] $PeriodicFileCheckStopRegex = '.*\stop',
        [string] $PolicyName = ''
    )

    $body = New-DwNcp7377CorePolicyImportBody `
        -IncomingRoot $IncomingRoot -TempRoot $TempRoot -RejectedRoot $RejectedRoot -CleanRoot $CleanRoot `
        -PeriodicFileCheckStopRegex $PeriodicFileCheckStopRegex -PolicyName $PolicyName
    return Import-CoreE2ePolicies -HookUrl $HookUrl -ImportBody $body
}
