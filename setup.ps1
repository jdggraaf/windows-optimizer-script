<#
.SYNOPSIS
    Unblocks the downloaded files and opens the DebloatKit GUI.

.DESCRIPTION
    Removes the "downloaded from the internet" mark from the scripts in this folder and in DebloatKit,
    then starts DebloatKit-GUI.ps1. It does not change the execution policy (the GUI is started with a
    process-only bypass) and it does not apply any tweak. Use -WhatIf to see what it would do.
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'

$kit = Join-Path $PSScriptRoot 'DebloatKit'
$gui = Join-Path $kit 'DebloatKit-GUI.ps1'
if (-not (Test-Path -LiteralPath $gui)) { throw "DebloatKit-GUI.ps1 was not found in $kit" }

$files = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '*') -File -Include '*.ps1', '*.bat', '*.vbs')
$files += Get-ChildItem -LiteralPath $kit -Recurse -File -Include '*.ps1', '*.json'
$files | Unblock-File

if ($PSCmdlet.ShouldProcess($gui, 'Start the DebloatKit GUI')) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$gui`"")
}
