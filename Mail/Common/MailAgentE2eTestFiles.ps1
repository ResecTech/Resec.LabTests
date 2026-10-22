#Requires -Version 5.1
Set-StrictMode -Version Latest

function Resolve-MailAgentE2eTestFilesRoot {
    <#
    .SYNOPSIS
      Root folder for Mail-specific fixtures (attachments under Mail\E2eAttach).
    .DESCRIPTION
      1) MAILAGENT_TEST_FILES_ROOT (semicolon-separated; may point at Fixtures root or Mail\E2eAttach parent)
      2) Resec.LabTests\Fixtures (default shared tree)
    #>
    param(
        [Parameter(Mandatory)]
        [string] $CallingScriptRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($env:MAILAGENT_TEST_FILES_ROOT)) {
        foreach ($part in $env:MAILAGENT_TEST_FILES_ROOT.Split(';')) {
            $trimmed = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            $full = [System.IO.Path]::GetFullPath($trimmed)
            if ([System.IO.Directory]::Exists($full)) {
                return $full
            }
        }
    }

    return Get-LabFixturesRoot
}

function Get-MailAgentE2eAttachmentFolder {
    param(
        [string] $TestFilesRoot = '',
        [string] $Subfolder = 'Mail\E2eAttach'
    )

    if ([string]::IsNullOrWhiteSpace($TestFilesRoot)) {
        return Get-LabMailAttachmentFolder
    }

    $path = Join-Path $TestFilesRoot $Subfolder
    if (-not [System.IO.Directory]::Exists($path)) {
        $path = Join-Path $TestFilesRoot 'E2eAttach'
    }
    if (-not [System.IO.Directory]::Exists($path)) {
        throw "Attachment folder not found under '$TestFilesRoot' (expected Mail\E2eAttach or E2eAttach)."
    }

    return [System.IO.Path]::GetFullPath($path)
}
