#Requires -Version 5.1
<#
.SYNOPSIS
  Core /debug/hook importpolicies helpers for DirWatcher lab E2E (NCP-7340, NCP-7343).
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
        [bool] $EnablePeriodicFileCheck = $false
    )

    $incoming = [System.IO.Path]::GetFullPath($IncomingRoot)
    $temp = [System.IO.Path]::GetFullPath($TempRoot)
    $rejected = [System.IO.Path]::GetFullPath($RejectedRoot)
    $processEmptyFoldersValue = if ($ProcessEmptyFolders) { 1 } else { 0 }
    $periodicFileCheckValue = if ($EnablePeriodicFileCheck) { 1 } else { 0 }

    return @"
;Facet Directory Watcher Settings:Directory Watcher Settings
ListPropType_DirectoryWatcherRootFolder=$incoming
ListPropType_DirectoryWatcherFileStoreName=$DestinationStoreName
IntPropType_DirectoryWatcherRejectedBehavior=1
ListPropType_DirectoryWatcherRejectedFolder=$rejected
ListPropType_DirectoryWatcherTempFolder=$temp
ListPropType_DirectoryWatcherIncludeFolderMask=
ListPropType_DirectoryWatcherExcludeFolderMask=
NumPropType_DirectoryWatcherProcessPreExistingFiles=0
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
