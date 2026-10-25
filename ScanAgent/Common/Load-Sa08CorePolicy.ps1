#Requires -Version 5.1
<#
.SYNOPSIS
  Loads SA-08 Core lab policy (push + import + commdown/commup). Does not pop.
.PARAMETER PopFirst
  One poppolicystate before push (optional cleanup).
#>
[CmdletBinding()]
param(
    [switch] $PopFirst,
    [string] $CoreDebugHookUrl = '',
    [string] $PolicyName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonRoot = $PSScriptRoot
$p0Root = Join-Path (Split-Path $commonRoot -Parent) 'P0'

. (Join-Path $commonRoot 'ScanAgentE2ePs51.ps1')
. (Join-Path $commonRoot 'ScanAgentE2eDebug.ps1')
. (Join-Path $commonRoot 'ScanAgentE2eCorePolicy.ps1')

if ([string]::IsNullOrWhiteSpace($PolicyName)) {
    $PolicyName = $script:Sa08DefaultPolicyName
}

function Invoke-ScanAgentDebug {
    param([string] $Exe, [string[]] $Arguments)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($line in @(& $Exe @Arguments 2>&1)) {
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                $stdoutLines.Add($line.Exception.Message)
            }
            else {
                $stdoutLines.Add([string] $line)
            }
        }
    }
    catch {
        $stdoutLines.Add($_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $savedEap
    }
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    $stdout = ($stdoutLines -join [Environment]::NewLine).TrimEnd()
    return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout }
}

function Invoke-ScanAgentDebugJson {
    param([string] $Exe, [string[]] $Arguments)
    $result = Invoke-ScanAgentDebug -Exe $Exe -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "ScanAgentDebug failed: $($result.StdOut)"
    }
    return ($result.StdOut | ConvertFrom-Json)
}

$exe = Resolve-ScanAgentDebugPath -CallingScriptRoot $p0Root
$hook = Get-ScanAgentCoreDebugHookUrl -Override $CoreDebugHookUrl

if ($PopFirst) {
    try {
        Restore-ScanAgentSa05CorePolicyStack -HookUrl $hook | Out-Null
        Write-Host 'poppolicystate OK'
    }
    catch {
        Write-Warning "poppolicystate skipped: $($_.Exception.Message)"
    }
}

$setup = Initialize-ScanAgentSa08CoreTestPolicy -Exe $exe -CoreDebugHookUrl $hook -PolicyName $PolicyName

$list = Invoke-ScanAgentDebugJson -Exe $exe -Arguments @('policy.list')
Write-Host ''
Write-Host "Loaded policy: $PolicyName" -ForegroundColor Green
foreach ($p in @($list.policies)) {
    Write-Host "  id=$($p.id) name=$($p.name)"
}
