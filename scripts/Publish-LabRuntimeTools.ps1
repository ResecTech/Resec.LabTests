#Requires -Version 5.1
<#
.SYNOPSIS
  Refreshes Tools\runtime\win-x64 from local dotnet publish outputs (maintainers with SDK).

.PARAMETER MailRepoRoot
  Resec.Agent.Mail git root (SendBulkAttachmentMail, SendEml). Default: ..\Resec.Agent.Mail under ResecTech.

.PARAMETER ScanAgentRepoRoot
  Resec.Agent.ScanAgent git root. Default: ..\Resec.Agent.ScanAgent under ResecTech.
#>
[CmdletBinding()]
param(
    [string] $MailRepoRoot = '',
    [string] $ScanAgentRepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$labTestsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeDir = Join-Path $labTestsRoot 'Tools\runtime\win-x64'
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

$resecTech = [System.IO.Path]::GetFullPath((Join-Path $labTestsRoot '..'))
if ([string]::IsNullOrWhiteSpace($MailRepoRoot)) {
    $MailRepoRoot = Join-Path $resecTech 'Resec.Agent.Mail'
}
if ([string]::IsNullOrWhiteSpace($ScanAgentRepoRoot)) {
    $ScanAgentRepoRoot = Join-Path $resecTech 'Resec.Agent.ScanAgent'
}

function Copy-PublishedFile {
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $DisplayName
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Missing $DisplayName at $SourcePath"
    }

    $dest = Join-Path $runtimeDir ([System.IO.Path]::GetFileName($SourcePath))
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    Write-Host "Copied $DisplayName -> $dest"
}

Write-Host 'Publishing SimpleMailServer (Release, single-file)...'
dotnet publish (Join-Path $labTestsRoot 'Tools\SimpleMailServer\SimpleMailServer.csproj') -c Release -p:PublishProfile=FolderProfile | Out-Null
$smsPublish = Join-Path $labTestsRoot 'Tools\SimpleMailServer\bin\publish\single-file'
Copy-PublishedFile -SourcePath (Join-Path $smsPublish 'SimpleMailServer.exe') -DisplayName 'SimpleMailServer.exe'

Write-Host 'Publishing SendBulkAttachmentMail...'
$bulkProj = Join-Path $MailRepoRoot 'SendBulkAttachmentMail\SendBulkAttachmentMail.csproj'
dotnet publish $bulkProj -c Release -p:PublishProfile=FolderProfile | Out-Null
$bulkPublish = Join-Path $MailRepoRoot 'SendBulkAttachmentMail\bin\publish\single-file'
Copy-PublishedFile -SourcePath (Join-Path $bulkPublish 'SendBulkAttachmentMail.exe') -DisplayName 'SendBulkAttachmentMail.exe'

Write-Host 'Publishing SendEml (self-contained)...'
$emlProj = Join-Path $MailRepoRoot 'SendEml\SendEml.csproj'
dotnet publish $emlProj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true | Out-Null
$emlPublish = Join-Path $MailRepoRoot 'SendEml\bin\Release\net11.0\win-x64\publish'
Copy-PublishedFile -SourcePath (Join-Path $emlPublish 'SendEml.exe') -DisplayName 'SendEml.exe'
$emlConfig = Join-Path $emlPublish 'BulkMailConfig.json'
if (Test-Path -LiteralPath $emlConfig) {
    Copy-PublishedFile -SourcePath $emlConfig -DisplayName 'SendEml BulkMailConfig.json'
}

Write-Host 'Publishing ScanAgentDebug (self-contained)...'
$dbgProj = Join-Path $ScanAgentRepoRoot 'src\Resec.Agent.ScanAgent.DebugClient\Resec.Agent.ScanAgent.DebugClient.csproj'
$dbgOut = Join-Path $ScanAgentRepoRoot 'src\Resec.Agent.ScanAgent.DebugClient\bin\publish\win-x64'
New-Item -ItemType Directory -Force -Path $dbgOut | Out-Null
dotnet publish $dbgProj -c Release -p:Platform=x64 -r win-x64 --self-contained true -p:PublishSingleFile=true -o $dbgOut | Out-Null
Copy-PublishedFile -SourcePath (Join-Path $dbgOut 'ScanAgentDebug.exe') -DisplayName 'ScanAgentDebug.exe'

$names = Get-ChildItem -LiteralPath $runtimeDir -File | Sort-Object Name
$manifestEntries = @()
foreach ($file in $names) {
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestEntries += [PSCustomObject]@{
        fileName = $file.Name
        bytes    = $file.Length
        sha256   = $hash
    }
}

$manifest = [ordered]@{
    updatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    runtimeId  = 'win-x64'
    files      = $manifestEntries
}
$manifestPath = Join-Path $runtimeDir 'lab-tools.manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "Wrote $manifestPath"
Write-Host 'Done. Commit Tools\runtime\win-x64 when hashes look right.'