#Requires -Version 5.1
<#
.SYNOPSIS
  PowerShell 5.1 helpers for Scan Agent E2E scripts (scalar vs collection, JSON arrays).
#>
Set-StrictMode -Version Latest

function Get-CollectionCount {
    param([object] $Value)

    if ($null -eq $Value) {
        return 0
    }

    return @($Value).Count
}

function ConvertTo-FileInfoArray {
    param([object] $Value)

    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if ($null -eq $Value) {
        return [System.IO.FileInfo[]]@()
    }

    foreach ($item in @($Value)) {
        if ($item -is [System.IO.FileInfo]) {
            $list.Add($item)
            continue
        }
        if ($item -is [System.Array]) {
            foreach ($inner in $item) {
                if ($inner -is [System.IO.FileInfo]) {
                    $list.Add($inner)
                }
            }
        }
    }

    return [System.IO.FileInfo[]]$list.ToArray()
}

function Get-SanitizationFileEntries {
    <#
    .SYNOPSIS
      Normalizes sanitization.status files (single object or array from JSON) for foreach.
    #>
    param($FilesProperty)

    if ($null -eq $FilesProperty) {
        return ,@()
    }

    return ,@($FilesProperty)
}
