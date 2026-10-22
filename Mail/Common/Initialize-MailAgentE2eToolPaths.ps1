#Requires -Version 5.1
<#
.SYNOPSIS
  Finds SimpleMailServer and SendBulkAttachmentMail on this machine and sets E2E tool environment variables.

.DESCRIPTION
  Sets for the current PowerShell session:
    MAIL_E2E_SIMPLE_MAIL_SERVER_EXE
    MAIL_E2E_SEND_BULK_ATTACHMENT_MAIL_EXE

  Search order per tool: existing env (unless -Force), repo build outputs (Debug/Release, x64, publish single-file), then PATH.

.EXAMPLE
  . .\Mail\Common\Initialize-MailAgentE2eToolPaths.ps1

.EXAMPLE
  .\Initialize-MailAgentE2eToolPaths.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonRoot = $PSScriptRoot
. (Join-Path $commonRoot 'MailAgentE2ePaths.ps1')

$testTreeRoot = Split-Path $commonRoot -Parent
$callingScriptRoot = Join-Path $testTreeRoot 'P0'
if (-not (Test-Path -LiteralPath $callingScriptRoot)) {
    $callingScriptRoot = $testTreeRoot
}

Set-MailAgentE2eToolEnvironment -CallingScriptRoot $callingScriptRoot -Force:$Force -Quiet:$Quiet | Out-Null
