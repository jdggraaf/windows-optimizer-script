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

function RunJson([string[]]$EngineArgs) {
    # stdout only (must be pure JSON); stderr goes to a file so warnings cannot pollute it.
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    $out = (& $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -CatalogPath $catalog -StateDir $stateDir @EngineArgs 2>$errFile | Out-String)
    $code = $LASTEXITCODE
    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    $parsed = $null; $ok = $true
    try { $parsed = $out | ConvertFrom-Json } catch { $ok = $false }
    [pscustomobject]@{ Code = $code; Out = $out; Err = $err; Json = $parsed; Parsed = $ok }
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
    Check 'unverified tweak skipped with reason' ($r.Out -match 'unverified new tweak; use -IncludeUnverified')

    Write-Host '-WhatIf -IncludeUnverified'
    $r = Run @('-WhatIf', '-NoRestorePoint', '-IncludeUnverified')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'reports 4 changes' ($r.Out -match '4 to change')
    Check 'no unverified skip reason' ($r.Out -notmatch 'unverified new tweak')
    Check 'nothing changed' ($null -eq (Val $key 'Unverified'))

    Write-Host '-WhatIf -AsJson'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'stdout is valid JSON' $r.Parsed
    $steps = @($r.Json)
    Check 'plan has tweakId/type/target/current/desired/action/reason' ($steps.Count -gt 0 -and -not (@('tweakId','type','target','current','desired','action','reason') | Where-Object { $steps[0].PSObject.Properties.Name -notcontains $_ }))
    Check 'plan: 3 Change steps' (@($steps | Where-Object action -EQ 'Change').Count -eq 3)
    Check 'plan: unverified step is Skip with reason' (@($steps | Where-Object { $_.tweakId -eq 'test-unverified' -and $_.action -eq 'Skip' -and $_.reason -match 'IncludeUnverified' }).Count -eq 1)
    Check 'no human text before JSON' ($r.Out.TrimStart().StartsWith('['))
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-IncludeUnverified')
    Check 'plan with -IncludeUnverified: 4 Change steps' ($r.Parsed -and @(@($r.Json) | Where-Object action -EQ 'Change').Count -eq 4)
    $r = Run @('-AsJson', '-NoRestorePoint')
    Check '-AsJson without -List/-WhatIf refused' ($r.Code -ne 0 -and $r.Out -match 'AsJson')

    Write-Host '-List'
    $r = Run @('-List')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'balanced tweak ignored' ($r.Out -notmatch 'test-balanced-ignored')
    Check 'already-set reported Applied' ($r.Out -match 'test-already-set\s+other\s+Applied')
    Check 'default order unchanged (by id)' ($r.Out.IndexOf('test-already-set') -lt $r.Out.IndexOf('test-existing-dword') -and $r.Out.IndexOf('test-existing-dword') -lt $r.Out.IndexOf('test-unverified'))

    Write-Host '-List -SortBy effectiveness'
    $r = Run @('-List', '-SortBy', 'effectiveness')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'highest effectiveness listed first' ($r.Out.IndexOf('test-unverified') -ge 0 -and $r.Out.IndexOf('test-unverified') -lt $r.Out.IndexOf('test-already-set'))

    Write-Host '-List -AsJson'
    $r = RunJson @('-List', '-AsJson')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'stdout is valid JSON' $r.Parsed
    Check 'has managed object' ($r.Parsed -and $null -ne $r.Json.managed -and $r.Json.managed.PSObject.Properties.Name -contains 'isManaged')
    $tw = if ($r.Parsed) { @($r.Json.tweaks) } else { @() }
    Check 'tweaks array has the 6 safe entries' ($tw.Count -eq 6)
    Check 'tweak fields present' ($tw.Count -gt 0 -and -not (@('id','category','preset','status','steps','note','effectiveness','evidenceQuality','verification') | Where-Object { $tw[0].PSObject.Properties.Name -notcontains $_ }))
    $u = $tw | Where-Object id -EQ 'test-unverified'
    Check 'unverified: Skipped, effectiveness 4, verification new-unverified' ($u -and $u.status -eq 'Skipped' -and $u.effectiveness -eq 4 -and $u.verification -eq 'new-unverified')
    Check 'already-set reported Applied in JSON' (@($tw | Where-Object { $_.id -eq 'test-already-set' -and $_.status -eq 'Applied' }).Count -eq 1)
    $r = RunJson @('-List', '-AsJson', '-SortBy', 'effectiveness')
    Check 'JSON sorted by effectiveness desc' ($r.Parsed -and @($r.Json.tweaks)[0].id -eq 'test-unverified')
    $r = RunJson @('-List', '-AsJson', '-IncludeUnverified')
    $u = if ($r.Parsed) { @($r.Json.tweaks) | Where-Object id -EQ 'test-unverified' } else { $null }
    Check '-IncludeUnverified: unverified listed as NotApplied' ($u -and $u.status -eq 'NotApplied')

    Write-Host 'Apply as a different user than the GUI user (-ExpectedSid mismatch)'
    $r = Run @('-NoRestorePoint', '-Force', '-ExpectedSid', 'S-1-5-18-0-0')
    Check 'refused with exit 1' ($r.Code -eq 1)
    Check 'refusal reason is on stdout/host stream (visible to *>&1 capture)' ($r.Out -match 'different user')
    Check 'nothing changed' ((Val $key 'Existing') -eq 5 -and $null -eq (Val $key 'Created'))
    Check 'no state folder written' (-not (Test-Path $stateDir))

    Write-Host 'Apply'
    $r = Run @('-NoRestorePoint', '-Force')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'existing value changed to 1' ((Val $key 'Existing') -eq 1)
    Check 'new value created' ((Val $key 'Created') -eq 0)
    Check 'nested key + string created' ((Val "$key\Sub\Deep" 'Text') -eq 'hello')
    Check 'command string not executed' (-not (Test-Path "$key\ShouldNotExist"))
    Check 'balanced value untouched' ($null -eq (Val $key 'Balanced'))
    Check 'unverified value untouched by default' ($null -eq (Val $key 'Unverified'))
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
    $r = Run @('-Undo', 'latest')
    $viaHostStream = (& $host_ -NoProfile -ExecutionPolicy Bypass -Command "& '$engine' -CatalogPath '$catalog' -StateDir '$stateDir' -Undo latest *>&1 | Out-String" 2>$null) -join ''
    Check 'engine refusal text is captured by *>&1 (GUI elevated log)' ($viaHostStream -match 'No snapshot')

    Write-Host 'Apply with -IncludeUnverified, then undo'
    $r = Run @('-NoRestorePoint', '-Force', '-IncludeUnverified', '-Only', 'test-unverified')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'unverified value applied' ((Val $key 'Unverified') -eq 1)
    $r = Run @('-Undo', 'latest')
    Check 'undo removes unverified value' ($r.Code -eq 0 -and $null -eq (Val $key 'Unverified'))

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
