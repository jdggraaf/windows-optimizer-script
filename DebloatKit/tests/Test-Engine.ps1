<#
.SYNOPSIS
    End-to-end test of the DebloatKit engine against a throwaway registry key.

.DESCRIPTION
    Uses tests\test-catalog.json, which only touches HKCU:\Software\DebloatKitTest, and a temporary
    state folder. Applies, checks the result, undoes, checks that the exact previous state is back,
    then deletes the test key and the temporary folder. Nothing outside that key is changed.
    Run from an elevated PowerShell (the engine requires admin to apply).
#>
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\DebloatKit.ps1'
$catalog = Join-Path $PSScriptRoot 'test-catalog.json'
$key = 'HKCU:\Software\DebloatKitTest'
$stateDir = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-" + [guid]::NewGuid().ToString('N'))
$host_ = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$fail = 0

function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green } else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:fail++ }
}
function Val([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { return $null }
    $k = Get-Item $Path
    if ($k.GetValueNames() -contains $Name) { $k.GetValue($Name) } else { $null }
}
function Run([string[]]$EngineArgs) {
    # Windows PowerShell 5.1 turns a child's stderr into a terminating error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $out =& $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -CatalogPath $catalog -StateDir $stateDir @EngineArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

try {
    if (Test-Path $key) { Remove-Item $key -Recurse -Force }
    New-Item $key -Force | Out-Null
    New-ItemProperty $key -Name Existing -PropertyType DWord -Value 5 | Out-Null
    New-ItemProperty $key -Name AlreadyOk -PropertyType DWord -Value 7 | Out-Null

    Write-Host '-WhatIf'
    $r = Run @('-WhatIf', '-NoRestorePoint')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'reports 3 changes' ($r.Out -match '3 to change')
    Check 'nothing changed' ((Val $key 'Existing') -eq 5 -and $null -eq (Val $key 'Created') -and -not (Test-Path "$key\Sub"))
    Check 'no state folder written' (-not (Test-Path $stateDir))

    Write-Host '-List'
    $r = Run @('-List')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'balanced tweak ignored' ($r.Out -notmatch 'test-balanced-ignored')
    Check 'already-set reported Applied' ($r.Out -match 'test-already-set\s+other\s+Applied')

    Write-Host 'Apply'
    $r = Run @('-NoRestorePoint', '-Force')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'existing value changed to 1' ((Val $key 'Existing') -eq 1)
    Check 'new value created' ((Val $key 'Created') -eq 0)
    Check 'nested key + string created' ((Val "$key\Sub\Deep" 'Text') -eq 'hello')
    Check 'command string not executed' (-not (Test-Path "$key\ShouldNotExist"))
    Check 'balanced value untouched' ($null -eq (Val $key 'Balanced'))
    Check 'snapshot written' (@(Get-ChildItem $stateDir -Filter 'state-*.json').Count -eq 1)
    Check 'all steps Verified' ($r.Out -match 'Verified' -and $r.Out -notmatch 'Failed|Unverified')

    Write-Host 'Apply again (idempotent)'
    $r = Run @('-NoRestorePoint', '-Force')
    Check 'nothing to change' ($r.Out -match 'Nothing to change')

    Write-Host 'Undo latest'
    $r = Run @('-Undo', 'latest')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'existing value restored to 5' ((Val $key 'Existing') -eq 5)
    Check 'created value removed' ($null -eq (Val $key 'Created'))
    Check 'created nested keys removed' (-not (Test-Path "$key\Sub"))
    Check 'pre-existing key kept' (Test-Path $key)
    Check 'untouched value kept' ((Val $key 'AlreadyOk') -eq 7)
    Check 'snapshot marked reverted' (@(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 1)

    Write-Host 'Undo latest again'
    $r = Run @('-Undo', 'latest')
    Check 'refuses: no snapshot left' ($r.Code -ne 0 -and $r.Out -match 'No snapshot')

    Write-Host 'Disabled preset'
    $r = Run @('-Preset', 'aggressive', '-WhatIf')
    Check 'refused' ($r.Code -ne 0 -and $r.Out -match 'not enabled')
} finally {
    if (Test-Path $key) { Remove-Item $key -Recurse -Force }
    if (Test-Path $stateDir) { Remove-Item $stateDir -Recurse -Force }
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
