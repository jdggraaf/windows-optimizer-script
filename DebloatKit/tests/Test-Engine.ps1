<#
.SYNOPSIS
    End-to-end test of the DebloatKit engine against a throwaway registry key.

.DESCRIPTION
    Uses tests\test-catalog.json, which only touches HKCU:\Software\DebloatKitTest, and a temporary
    state folder. Applies, checks the result, undoes, checks that the exact previous state is back,
    then deletes the test key and the temporary folder. Nothing outside that key is changed.
    Run from an elevated PowerShell (the engine requires admin to apply).

    Also covers the v2 catalog format (tests\test-catalog-v2.json), managedSkip, appliesTo, migrations
    and -Lint. Managed state, OS edition/build and fsutil / powercfg / execution policy come from a fake
    -TestEnvironment file, so none of that touches the real system (the real fsutil value is compared
    before and after).

    WP2 checks (tests\test-catalog-wp2.json): preflight gates, applicability (requiresLaptop / requiresDesktop /
    build range), step policy (order, weight, onError), protected targets and the matching lint rules. The
    preflight readings, chassis and injected step failures come from the -TestEnvironment file; the real
    preflight is only read. Applies on the real system pass -SkipPreflight (a reboot may be pending).

    WP3 checks (tests\test-catalog-wp3.json): the native disk and system handlers (Compact OS, hibernation
    type, reserved storage, component store cleanup, performance power plan, memory compression, 8.3 names,
    Sleep Study channels, boot menu policy). Their read functions run against the REAL system (-WhatIf, read
    only); every apply and undo runs against the fake compact / dism / powercfg / fsutil / wevtutil / bcdedit /
    MMAgent state in the -TestEnvironment file. The real state of every setting is captured before and compared
    after the whole run.

    WP4 checks (tests\test-catalog-wp4.json, tests\test-appx-profiles.json): capability and optional feature steps
    (plan, apply, re-apply, undo, the update-source gate), AppX keep profiles with the reinstall manifest, the removal
    ladder, the framework check and its repair, managed-device keeps, LTSC handling and the matching lint rules. The real
    capability / feature / AppX inventories are only read (compared before and after); every change runs against the fake
    capability / optionalfeature / appx / wusource tools in the -TestEnvironment file.

    WP5 checks (tests\test-catalog-wp5.json): per-tweak -Revert (WhatIf, JSON, marks the steps reverted inside the snapshot,
    oldest before-state across runs, -Undo skipping reverted steps, AppX never reverted, SID and managed rules), -Drift (read-only
    comparison of the live state with the applied steps, build before/after, appliesTo against the new build, JSON) and
    -Drift -Reapply (preview, preflight, managed device, only the drifted tweaks, newest snapshot supersedes the old record).
    Registry steps use the throwaway key HKCU:\Software\DebloatKitTest\WP5; everything else uses the fake tools.

    WP6 checks (Get-FootprintReport.ps1, crash-dump section of Get-MemoryPressure.ps1): both tools' -SelfTest, the footprint comparison
    and its argument / path / schema rules on saved report files, and one live read-only -Baseline run. Nothing is changed on the system.

    WP7 checks (DebloatKit-GUI.ps1, profiles.json): profiles.json against the real catalog (ids exist, nothing never-default or
    reduces-security, work-managed stays inside the safe set), the GUI's own -SelfTest (per-row toggle, profiles, drift and footprint
    tabs, command construction; reads, -WhatIf, fixtures and temp files only) and a sandbox -SelfTest that runs the GUI-built -Revert,
    -Drift and -Drift -Reapply -WhatIf commands against the throwaway key and the fake -TestEnvironment.
    WP8 checks (repo root: clear_ram_loop.bat, revert.bat, run_invisible.vbs, setup.ps1, README.md): the retired loop no longer
    disables Windows Update, UsoSvc or BITS, loops, kills processes or runs RAMMap; revert.bat restores the three service start
    types and removes the policy values; the launchers point at the GUI. Everything runs in its no-change mode (/noop, /check,
    -WhatIf) plus static scans of the file text.

    WP9 checks (DebloatKit-Image.ps1): the image builder's own -SelfTest (key mapping, catalog selection, AppX resolution, a whole build
    against a recording fake of DISM / reg.exe / the file system, failure cleanup, flags that must stay off by default, static scans), the
    protected AppX list compared with the engine's, and the real script in -WhatIf and refusal modes (JSON plan, no work folder created,
    no hash / missing ISO / unsafe work folder refused). DISM, reg.exe and oscdimg are never run.
#>
$ErrorActionPreference = 'Stop'
# The engine only accepts -TestEnvironment for real (non-preview) runs when the test runner sets this; every child process inherits it.
$env:DEBLOATKIT_TESTENV = '1'
$engine = Join-Path $PSScriptRoot '..\DebloatKit.ps1'
$catalog = Join-Path $PSScriptRoot 'test-catalog.json'
$key = 'HKCU:\Software\DebloatKitTest'
$stateDir = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-" + [guid]::NewGuid().ToString('N'))
$host_ = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
$fail = 0
$v2Catalog = Join-Path $PSScriptRoot 'test-catalog-v2.json'
$envFile = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTestEnv-" + [guid]::NewGuid().ToString('N') + '.json')
$tmpFiles = New-Object System.Collections.Generic.List[string]

function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green } else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:fail++ }
}
function Val([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { return $null }
    $k = Get-Item $Path
    if ($k.GetValueNames() -contains $Name) { $k.GetValue($Name) } else { $null }
}
function Run([string[]]$EngineArgs, [string]$Cat = $catalog) {
    # Windows PowerShell 5.1 turns a child's stderr into a terminating error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $out =& $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -CatalogPath $Cat -StateDir $stateDir @EngineArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function RunJson([string[]]$EngineArgs, [string]$Cat = $catalog) {
    # stdout only (must be pure JSON); stderr goes to a file so warnings cannot pollute it.
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    $out = (& $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -CatalogPath $Cat -StateDir $stateDir @EngineArgs 2>$errFile | Out-String)
    $code = $LASTEXITCODE
    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    $parsed = $null; $ok = $true
    try { $parsed = $out | ConvertFrom-Json } catch { $ok = $false }
    [pscustomobject]@{ Code = $code; Out = $out; Err = $err; Json = $parsed; Parsed = $ok }
}

function New-TestEnv([bool]$Managed, [string]$Edition = 'Professional', [int]$Build = 26200, [string]$Chassis = 'Unknown', [hashtable]$Extra = @{}, [hashtable]$Tools = @{}) {
    # Fake managed flag, OS edition/build/chassis and fsutil / powercfg / execution policy state for -TestEnvironment.
    # $Extra adds top-level keys: preflight = @{ rebootPending = @('x'); servicingBusy = $true; onBattery = $true; freeDiskMB = 100 },
    # protectedServiceKeys = @('Spooler'), failSteps = @('tweakId|target*'). $Tools overrides or adds fake tool state
    # (the WP3 handlers fall back to the engine's built-in defaults for every key not listed).
    $o = [ordered]@{ managed = $Managed; os = [ordered]@{ editionId = $Edition; build = $Build; ubr = 1; chassis = $Chassis }
        tools = [ordered]@{ 'fsutil:disablelastaccess' = '2'; 'fsutil:disable8dot3' = '0'; 'powercfg:activescheme' = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; 'executionpolicy' = 'Restricted' } }
    foreach ($k in $Tools.Keys) { $o.tools[$k] = $Tools[$k] }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    $o | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $envFile -Encoding UTF8
}
function Get-Fake([string]$Name) { (Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json).tools.PSObject.Properties[$Name].Value }
function Step($Plan, [string]$Id) { @($Plan) | Where-Object { $_.tweakId -eq $Id } | Select-Object -First 1 }
function New-TempFile([string]$Text, [string]$Ext = '.json') {
    $f = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-" + [guid]::NewGuid().ToString('N') + $Ext)
    Set-Content -LiteralPath $f -Value $Text -Encoding UTF8
    $tmpFiles.Add($f); $f
}
function Get-RealLastAccess { $o = & fsutil.exe behavior query disablelastaccess 2>$null; "$o" }

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
    $r = Run @('-NoRestorePoint', '-Force', '-SkipPreflight', '-ExpectedSid', 'S-1-5-18-0-0')
    Check 'refused with exit 1' ($r.Code -eq 1)
    Check 'refusal reason is on stdout/host stream (visible to *>&1 capture)' ($r.Out -match 'different user')
    Check 'nothing changed' ((Val $key 'Existing') -eq 5 -and $null -eq (Val $key 'Created'))
    Check 'no state folder written' (-not (Test-Path $stateDir))

    Write-Host 'Apply'
    $r = Run @('-NoRestorePoint', '-Force', '-SkipPreflight')
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
    $r = Run @('-NoRestorePoint', '-Force', '-SkipPreflight')
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
    $r = Run @('-NoRestorePoint', '-Force', '-SkipPreflight', '-IncludeUnverified', '-Only', 'test-unverified')
    Check 'exit code 0' ($r.Code -eq 0)
    Check 'unverified value applied' ((Val $key 'Unverified') -eq 1)
    $r = Run @('-Undo', 'latest')
    Check 'undo removes unverified value' ($r.Code -eq 0 -and $null -eq (Val $key 'Unverified'))

    Write-Host 'Disabled preset'
    $r = Run @('-Preset', 'aggressive', '-WhatIf')
    Check 'refused' ($r.Code -ne 0 -and $r.Out -match 'not enabled')

    # ======================= catalog format, managedSkip, appliesTo, migrations, lint =======================
    $realBefore = Get-RealLastAccess

    Write-Host 'Legacy catalog (bare array = schemaVersion 1) still loads'
    $v1 = New-TempFile '[{"id":"old-upd","category":"updates","description":"x","implementation":{"type":"registry","path":"HKCU:\\Software\\DebloatKitTest\\V1","name":"U","valueType":"DWord","value":1},"revert":"snapshot","risk":"safe","preset":"safe"},{"id":"net-ntp-pool","category":"network","description":"x","implementation":{"type":"registry","path":"HKCU:\\Software\\DebloatKitTest\\V1","name":"N","valueType":"DWord","value":1},"revert":"snapshot","risk":"safe","preset":"safe"},{"id":"old-plain","category":"other","description":"x","implementation":{"type":"registry","path":"HKCU:\\Software\\DebloatKitTest\\V1","name":"P","valueType":"DWord","value":1},"revert":"snapshot","risk":"safe","preset":"safe"}]'
    $r = Run @('-Lint') $v1
    Check '-Lint on a v1 catalog: exit 0' ($r.Code -eq 0)
    Check '-Lint reports the v1 -> v2 migration as a warning' ($r.Out -match 'schemaVersion 1' -and $r.Out -match '0 error')
    $r = Run @('-Lint')
    Check '-Lint on the engine test catalog: it finds its deliberate unsupported/irreversible safe entry' ($r.Code -eq 1 -and $r.Out -match 'test-unsupported-command')

    Write-Host 'v1 -> v2 schema migration adds managedSkip to updates and the NTP pool'
    New-TestEnv $true
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $v1
    Check 'v1 catalog: updates category skipped on a managed device' ($r.Parsed -and (Step $r.Json 'old-upd').action -eq 'Skip' -and (Step $r.Json 'old-upd').reason -match 'managed device')
    Check 'v1 catalog: net-ntp-pool skipped on a managed device' ($r.Parsed -and (Step $r.Json 'net-ntp-pool').action -eq 'Skip')
    Check 'v1 catalog: ordinary tweak still planned' ($r.Parsed -and (Step $r.Json 'old-plain').action -eq 'Change')

    Write-Host 'Newer catalog schema is refused'
    $v9 = New-TempFile '{"schemaVersion":9,"tweaks":[]}'
    $r = Run @('-List') $v9
    Check 'schemaVersion 9: exit 1 with a clear message' ($r.Code -eq 1 -and $r.Out -match 'newer than this engine')
    $v0 = New-TempFile '{"tweaks":[]}'
    $r = Run @('-List') $v0
    Check 'object without schemaVersion: refused' ($r.Code -eq 1 -and $r.Out -match 'schemaVersion')

    Write-Host 'v2 catalog: not managed, Professional build 26200'
    New-TestEnv $false
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    Check 'exit 0 and valid JSON' ($r.Code -eq 0 -and $r.Parsed)
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'plain tweak: Change' ((Step $pl 'v2-plain').action -eq 'Change')
    Check 'managedSkip tweak: Change when the device is not managed' ((Step $pl 'v2-managed-skip').action -eq 'Change')
    Check 'appliesTo editions (skip): Skip with reason and edition' ((Step $pl 'v2-edition-skip').action -eq 'Skip' -and (Step $pl 'v2-edition-skip').reason -match 'not applicable: test: Enterprise only' -and (Step $pl 'v2-edition-skip').reason -match "edition 'Professional'")
    Check 'appliesTo editions (note): still Change, reason carries the note' ((Step $pl 'v2-edition-note').action -eq 'Change' -and (Step $pl 'v2-edition-note').reason -match 'honoured on Enterprise only')
    Check 'appliesTo notEditions: Skip on Professional' ((Step $pl 'v2-not-edition').action -eq 'Skip')
    Check 'appliesTo minBuild: Skip below the build' ((Step $pl 'v2-min-build').action -eq 'Skip' -and (Step $pl 'v2-min-build').reason -match 'build 26200')
    Check 'native handler id runs against the fake: Change 2 -> 1' ((Step $pl 'perf-ntfs-lastaccess').action -eq 'Change' -and (Step $pl 'perf-ntfs-lastaccess').current -eq '2' -and (Step $pl 'perf-ntfs-lastaccess').desired -eq '1')
    Check 'pending migrations are not part of a normal plan' (@($pl | Where-Object { $_.tweakId -like 'migration:*' }).Count -eq 0)

    Write-Host 'v2 catalog: managed device skips managedSkip tweaks'
    New-TestEnv $true
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'managedSkip tweak: Skip "managed device: <reason>"' ((Step $pl 'v2-managed-skip').action -eq 'Skip' -and (Step $pl 'v2-managed-skip').reason -eq 'managed device: test reason: the organisation owns this')
    Check 'other tweaks unaffected' ((Step $pl 'v2-plain').action -eq 'Change')
    Check 'stdout stays pure JSON with a warning on stderr' ($r.Parsed -and $r.Out.TrimStart().StartsWith('[') -and $r.Err -match 'Managed device detected')
    $r = Run @('-NoRestorePoint', '-TestEnvironment', $envFile) $v2Catalog
    Check 'apply on a managed device needs -Force' ($r.Code -eq 1 -and $r.Out -match 'Managed device')
    Check 'nothing written by the refused apply' ($null -eq (Val "$key\V2" 'Plain'))
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    $tw = if ($r.Parsed) { @($r.Json.tweaks) } else { @() }
    Check '-List -AsJson: managed.isManaged true' ($r.Parsed -and $r.Json.managed.isManaged -eq $true)
    Check '-List -AsJson: managedSkip tweak Skipped, reason in note, managedSkip field exposed' ((@($tw | Where-Object { $_.id -eq 'v2-managed-skip' -and $_.status -eq 'Skipped' -and $_.note -match 'managed device' -and $_.managedSkip -match 'organisation owns' }).Count -eq 1))
    Check '-List -AsJson: catalog schema info' ($r.Parsed -and $r.Json.catalog.schemaVersion -eq 2 -and $r.Json.catalog.currentSchemaVersion -eq 2)
    Check '-List -AsJson: tweaks without managedSkip expose null' ((@($tw | Where-Object { $_.id -eq 'v2-plain' -and $null -eq $_.managedSkip }).Count -eq 1))

    Write-Host 'v2 catalog: Enterprise edition'
    New-TestEnv $false 'Enterprise' 26200
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'Enterprise: edition-only tweak planned' ((Step $pl 'v2-edition-skip').action -eq 'Change')
    Check 'Enterprise: note-only tweak has no note' ((Step $pl 'v2-edition-note').action -eq 'Change' -and -not (Step $pl 'v2-edition-note').reason)
    Check 'Enterprise: notEditions tweak planned' ((Step $pl 'v2-not-edition').action -eq 'Change')

    Write-Host 'Migrations are offered by -List, never applied by a normal run'
    if (Test-Path "$key\V2") { Remove-Item "$key\V2" -Recurse -Force }
    New-Item "$key\V2" -Force | Out-Null
    New-ItemProperty "$key\V2" -Name MigOld -PropertyType DWord -Value ([int]-1) | Out-Null
    New-ItemProperty "$key\V2" -Name MigStr -PropertyType String -Value 'old' | Out-Null
    New-ItemProperty "$key\V2" -Name Other -PropertyType DWord -Value 6 | Out-Null
    New-TestEnv $false
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    $mg = if ($r.Parsed) { @($r.Json.migrations) } else { @() }
    Check '-List -AsJson: 2 pending migrations (the non-matching one is not offered)' ($mg.Count -eq 2 -and ($mg.id -contains 'mig-restore') -and ($mg.id -contains 'mig-rewrite') -and ($mg.id -notcontains 'mig-nomatch'))
    $r = Run @('-List', '-TestEnvironment', $envFile) $v2Catalog
    Check '-List text: tells the user how many values are no longer recommended' ($r.Out -match '2 value\(s\) set by an older DebloatKit version')
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'v2-plain', '-TestEnvironment', $envFile) $v2Catalog
    Check 'normal apply leaves migration values alone' ($r.Code -eq 0 -and (Val "$key\V2" 'MigOld') -eq -1 -and (Val "$key\V2" 'MigStr') -eq 'old')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $v2Catalog
    Check 'undo of that run' ($r.Code -eq 0 -and $null -eq (Val "$key\V2" 'Plain'))

    Write-Host '-Migrate -WhatIf'
    $r = RunJson @('-Migrate', '-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check '-Migrate -WhatIf: plan is the 2 migration steps only' ($r.Code -eq 0 -and $pl.Count -eq 2 -and @($pl | Where-Object { $_.tweakId -like 'migration:*' -and $_.action -eq 'Change' }).Count -eq 2)
    Check '-Migrate -WhatIf: restore-default shows <absent> as desired, rewrite shows the new value' ((Step $pl 'migration:mig-restore').desired -eq '<absent>' -and (Step $pl 'migration:mig-rewrite').desired -eq 'new (String)')
    Check '-Migrate -WhatIf: nothing changed' ((Val "$key\V2" 'MigOld') -eq -1 -and (Val "$key\V2" 'MigStr') -eq 'old')

    Write-Host '-Migrate applies through the snapshot, then undo restores the old values'
    $r = Run @('-Migrate', '-NoRestorePoint', '-Force', '-TestEnvironment', $envFile) $v2Catalog
    Check '-Migrate: exit 0, steps Verified' ($r.Code -eq 0 -and $r.Out -match 'Verified' -and $r.Out -notmatch 'Failed|Unverified')
    Check '-Migrate: restore-default removed the value' ($null -eq (Val "$key\V2" 'MigOld'))
    Check '-Migrate: rewrite wrote the new value' ((Val "$key\V2" 'MigStr') -eq 'new')
    Check '-Migrate: non-matching value untouched' ((Val "$key\V2" 'Other') -eq 6)
    $snap = Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1
    $sj = Get-Content $snap.FullName -Raw | ConvertFrom-Json
    Check 'snapshot records catalog schema, catalog version, migrate flag and OS build' ($sj.catalogSchemaVersion -eq 2 -and $sj.catalogVersion -eq 'test-1' -and $sj.migrate -eq $true -and $sj.os.Build -eq 26200 -and $sj.os.EditionId -eq 'Professional')
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $v2Catalog
    Check 'after -Migrate nothing is pending' ($r.Parsed -and @($r.Json.migrations).Count -eq 0)
    $r = Run @('-Migrate', '-NoRestorePoint', '-Force', '-TestEnvironment', $envFile) $v2Catalog
    Check 'second -Migrate: nothing to change' ($r.Out -match 'Nothing to change')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $v2Catalog
    Check 'undo brings the old values back exactly' ($r.Code -eq 0 -and (Val "$key\V2" 'MigOld') -eq -1 -and (Val "$key\V2" 'MigStr') -eq 'old')
    Check 'undo restored MigOld as a DWord' ((Get-Item "$key\V2").GetValueKind('MigOld') -eq 'DWord')

    Write-Host 'Apply on the v2 catalog: DWord above Int32.MaxValue, native handler on the fake tools'
    New-TestEnv $false
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile) $v2Catalog
    Check 'apply: exit 0' ($r.Code -eq 0)
    Check 'apply: all steps Verified (no Failed / Unverified)' ($r.Out -match 'Verified' -and $r.Out -notmatch 'Failed|Unverified')
    Check 'DWord 4294967295 written as the 32-bit pattern and verified' ((Val "$key\V2" 'Big') -eq -1 -and (Get-Item "$key\V2").GetValueKind('Big') -eq 'DWord')
    Check 'edition-skip / min-build / not-edition tweaks not written' ($null -eq (Val "$key\V2" 'EditionOnly') -and $null -eq (Val "$key\V2" 'FutureBuild') -and $null -eq (Val "$key\V2" 'NotPro'))
    Check 'edition note tweak written' ((Val "$key\V2" 'EditionNote') -eq 1)
    Check 'native handler wrote the FAKE fsutil (2 -> 1)' ((Get-Fake 'fsutil:disablelastaccess') -eq '1')
    Check 'the real fsutil setting was not touched' ((Get-RealLastAccess) -eq $realBefore)
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile) $v2Catalog
    Check 'apply again: nothing to change (DWord compare is idempotent)' ($r.Out -match 'Nothing to change')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $v2Catalog
    Check 'undo: exit 0, fake fsutil back to 2, DWord removed' ($r.Code -eq 0 -and (Get-Fake 'fsutil:disablelastaccess') -eq '2' -and $null -eq (Val "$key\V2" 'Big'))
    Check 'undo: the real fsutil setting still untouched' ((Get-RealLastAccess) -eq $realBefore)

    # ======================= WP2: preflight, applicability, step policy, protected targets =======================
    $wp2 = Join-Path $PSScriptRoot 'test-catalog-wp2.json'
    $P = "$key\P"
    function Reset-P { if (Test-Path $P) { Remove-Item $P -Recurse -Force }; New-Item $P -Force | Out-Null }
    function Last-Snapshot { $f = Get-ChildItem $stateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1; if ($f) { Get-Content $f.FullName -Raw | ConvertFrom-Json } else { $null } }
    function Remove-StateDir { if (Test-Path $stateDir) { Remove-Item $stateDir -Recurse -Force } }
    function HasF([string]$Id, [string]$Rule, [string]$Sev = 'error') { @($fi | Where-Object { $_.tweakId -eq $Id -and $_.rule -eq $Rule -and $_.severity -eq $Sev }).Count -ge 1 }
    Remove-StateDir
    Reset-P

    Write-Host 'Preflight: real system, read-only (-List -AsJson without a test environment)'
    $r = RunJson @('-List', '-AsJson') $wp2
    $pfIds = if ($r.Parsed) { @($r.Json.preflight.checks | ForEach-Object { $_.id }) } else { @() }
    Check 'exit 0, valid JSON, preflight + os blocks present' ($r.Code -eq 0 -and $r.Parsed -and $null -ne $r.Json.preflight -and $null -ne $r.Json.os)
    Check 'real preflight reports the four gates' (($pfIds -contains 'pending-reboot') -and ($pfIds -contains 'servicing-idle') -and ($pfIds -contains 'ac-power') -and ($pfIds -contains 'free-disk'))
    Check 'every check has status, blocking, title and detail' ($r.Parsed -and @($r.Json.preflight.checks | Where-Object { $_.status -in 'ok', 'blocked', 'warning', 'unknown' -and $null -ne $_.blocking -and $_.title -and $_.detail }).Count -eq 4)
    Check 'real OS info: numeric build, buildFull "<build>.<ubr>", chassis one of Laptop/Desktop/Unknown' ($r.Parsed -and $r.Json.os.build -gt 0 -and $r.Json.os.buildFull -eq ('{0}.{1}' -f $r.Json.os.build, $r.Json.os.ubr) -and $r.Json.os.chassis -in 'Laptop', 'Desktop', 'Unknown')
    Check 'List JSON tweaks carry a weight' ($r.Parsed -and @($r.Json.tweaks | Where-Object { $null -eq $_.PSObject.Properties['weight'] }).Count -eq 0)
    $r = Run @('-List') $wp2
    Check '-List text shows the build and a preflight verdict' ($r.Code -eq 0 -and $r.Out -match 'Windows build \d+\.\d+' -and $r.Out -match 'Preflight: (ready to apply|an apply would be refused)')

    Write-Host 'Preflight: all gates clear (fake)'
    New-TestEnv $false 'Professional' 26200 'Unknown'
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $wp2
    Check 'clear: blocked is false and all four checks ok' ($r.Parsed -and $r.Json.preflight.blocked -eq $false -and @($r.Json.preflight.checks | Where-Object status -EQ 'ok').Count -eq 4)
    Check 'fake OS block: edition, build, ubr, chassis' ($r.Parsed -and $r.Json.os.editionId -eq 'Professional' -and $r.Json.os.build -eq 26200 -and $r.Json.os.ubr -eq 1 -and $r.Json.os.buildFull -eq '26200.1' -and $r.Json.os.chassis -eq 'Unknown')

    Write-Host 'Preflight: each gate refuses an apply before anything is written'
    $gates = @(
        @{ Name = 'pending reboot (CBS)'; Pf = @{ rebootPending = @('Component Based Servicing: RebootPending') }; Id = 'pending-reboot'; Text = 'restart is pending' },
        @{ Name = 'pending reboot (Windows Update)'; Pf = @{ rebootPending = @('Windows Update: RebootRequired') }; Id = 'pending-reboot'; Text = 'RebootRequired' },
        @{ Name = 'servicing busy'; Pf = @{ servicingBusy = $true }; Id = 'servicing-idle'; Text = 'TrustedInstaller' },
        @{ Name = 'on battery'; Pf = @{ onBattery = $true }; Id = 'ac-power'; Text = 'on battery' },
        @{ Name = 'low disk'; Pf = @{ freeDiskMB = 100 }; Id = 'free-disk'; Text = 'only 100 MB free' }
    )
    foreach ($g in $gates) {
        New-TestEnv $false 'Professional' 26200 'Unknown' @{ preflight = $g.Pf }
        Remove-StateDir; Reset-P
        $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
        Check "$($g.Name): apply refused (exit 1, reason shown, -SkipPreflight hinted)" ($r.Code -eq 1 -and $r.Out -match 'Preflight check failed' -and $r.Out -match $g.Text -and $r.Out -match 'SkipPreflight')
        Check "$($g.Name): nothing written (no value, no state folder)" ($null -eq (Val $P 'Plain') -and -not (Test-Path $stateDir))
        $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $wp2
        $c = if ($r.Parsed) { @($r.Json.preflight.checks) | Where-Object id -EQ $g.Id } else { $null }
        Check "$($g.Name): -List JSON flags the gate as blocked" ($r.Parsed -and $r.Json.preflight.blocked -eq $true -and $c -and $c.status -eq 'blocked' -and $c.blocking -eq $true)
    }

    Write-Host 'Preflight: -WhatIf only reports, -SkipPreflight overrides, -Undo is never gated'
    New-TestEnv $false 'Professional' 26200 'Unknown' @{ preflight = @{ rebootPending = @('Component Based Servicing: RebootPending'); onBattery = $true } }
    Remove-StateDir; Reset-P
    $r = Run @('-WhatIf', '-NoRestorePoint', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    Check '-WhatIf with failing gates: exit 0 and says an apply would be refused' ($r.Code -eq 0 -and $r.Out -match 'would be refused' -and $r.Out -match 'BLOCKED')
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    Check '-WhatIf -AsJson stays a bare plan array (no preflight rows mixed in)' ($r.Code -eq 0 -and $r.Parsed -and $r.Out.TrimStart().StartsWith('[') -and @($r.Json).Count -eq 1 -and @($r.Json)[0].tweakId -eq 'p-plain')
    $r = Run @('-NoRestorePoint', '-Force', '-SkipPreflight', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    Check '-SkipPreflight: applies, with a warning naming the failing gates' ($r.Code -eq 0 -and (Val $P 'Plain') -eq 1 -and $r.Out -match 'Preflight skipped' -and $r.Out -match 'restart is pending' -and $r.Out -match 'on battery')
    $snap = Last-Snapshot
    Check 'snapshot records that the preflight was skipped and which gates failed' ($snap -and $snap.preflight.skipped -eq $true -and $snap.preflight.blocked -eq $true -and @($snap.preflight.checks | Where-Object status -EQ 'blocked').Count -eq 2)
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp2
    Check '-Undo works while the preflight gates fail' ($r.Code -eq 0 -and $null -eq (Val $P 'Plain'))

    Write-Host 'Preflight: PendingFileRenameOperations is only a warning'
    New-TestEnv $false 'Professional' 26200 'Unknown' @{ preflight = @{ pendingFileRename = $true } }
    Remove-StateDir; Reset-P
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $wp2
    $c = if ($r.Parsed) { @($r.Json.preflight.checks) | Where-Object id -EQ 'pending-reboot' } else { $null }
    Check 'pending file rename: status warning, not blocking, preflight not blocked' ($r.Parsed -and $c.status -eq 'warning' -and $c.blocking -eq $false -and $r.Json.preflight.blocked -eq $false)
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    Check 'pending file rename: the apply goes ahead' ($r.Code -eq 0 -and (Val $P 'Plain') -eq 1)
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp2

    Write-Host 'Preflight: free-disk threshold depends on the restore point'
    New-TestEnv $false 'Professional' 26200 'Unknown' @{ preflight = @{ freeDiskMB = 1000 } }
    Remove-StateDir; Reset-P
    $r = Run @('-WhatIf', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    Check 'with a restore point 1000 MB is too little (2048 MB needed)' ($r.Code -eq 0 -and $r.Out -match 'would be refused' -and $r.Out -match '2048 MB needed')
    $r = Run @('-WhatIf', '-NoRestorePoint', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    Check 'without a restore point 1000 MB is enough (needs 512 MB)' ($r.Code -eq 0 -and $r.Out -match 'ready to apply' -and $r.Out -match 'needs 512 MB')

    Write-Host 'Snapshot records the OS build, edition, UBR and chassis'
    New-TestEnv $false 'Enterprise' 26200 'Laptop'
    Remove-StateDir; Reset-P
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-plain', '-TestEnvironment', $envFile) $wp2
    $snap = Last-Snapshot
    Check 'snapshot os: EditionId, Build, Ubr, BuildFull, Chassis' ($r.Code -eq 0 -and $snap.os.EditionId -eq 'Enterprise' -and $snap.os.Build -eq 26200 -and $snap.os.Ubr -eq 1 -and $snap.os.BuildFull -eq '26200.1' -and $snap.os.Chassis -eq 'Laptop' -and $snap.os.PSObject.Properties.Name -contains 'DisplayVersion')
    Check 'snapshot preflight: not skipped, not blocked, four checks' ($snap.preflight.skipped -eq $false -and $snap.preflight.blocked -eq $false -and @($snap.preflight.checks).Count -eq 4)
    New-TestEnv $false 'Enterprise' 26300 'Laptop'
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp2
    Check 'undo after a Windows update: tells which build the snapshot came from' ($r.Code -eq 0 -and $r.Out -match 'snapshot was taken on Windows build 26200\.1' -and $r.Out -match 'now on build 26300\.1')

    Write-Host 'Applicability: requiresLaptop / requiresDesktop / build range'
    foreach ($case in @(@('Laptop', 'Change', 'Skip'), @('Desktop', 'Skip', 'Change'), @('Unknown', 'Change', 'Change'))) {
        New-TestEnv $false 'Professional' 26200 $case[0]
        $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $wp2
        $pl = if ($r.Parsed) { @($r.Json) } else { @() }
        Check "chassis $($case[0]): laptop-only tweak -> $($case[1]), desktop-only tweak -> $($case[2])" ((Step $pl 'p-laptop').action -eq $case[1] -and (Step $pl 'p-desktop').action -eq $case[2])
    }
    New-TestEnv $false 'Professional' 26200 'Desktop'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $wp2
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'skip reason says "not applicable", names the test reason and the chassis' ((Step $pl 'p-laptop').reason -match 'not applicable: test: battery setting' -and (Step $pl 'p-laptop').reason -match 'desktop')
    Check 'maxBuild: build 26200 is above 26100 -> Skip with the build in the reason' ((Step $pl 'p-buildrange').action -eq 'Skip' -and (Step $pl 'p-buildrange').reason -match 'build 26200')
    foreach ($b in @(@(26100, 'Change'), @(22000, 'Change'), @(21999, 'Skip'))) {
        New-TestEnv $false 'Professional' $b[0] 'Unknown'
        $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $wp2
        Check "build range 22000-26100 at build $($b[0]) -> $($b[1])" ($r.Parsed -and (Step $r.Json 'p-buildrange').action -eq $b[1])
    }
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $wp2
    $bt = if ($r.Parsed) { @($r.Json.tweaks) | Where-Object id -EQ 'p-buildrange' } else { $null }
    Check '-List JSON: a not-applicable tweak is Skipped with the reason in note' ($bt -and $bt.status -eq 'Skipped' -and $bt.note -match 'not applicable')

    Write-Host 'Step policy: order, weight, onError in the plan'
    New-TestEnv $false 'Professional' 26200 'Unknown'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-Only', 'p-plain,p-late,p-early,p-weight,p-stop', '-TestEnvironment', $envFile) $wp2
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    $ids = @($pl | ForEach-Object { $_.tweakId })
    Check 'plan fields: order, weight and onError present on every step' ($pl.Count -gt 0 -and -not (@('order', 'weight', 'onError') | Where-Object { $pl[0].PSObject.Properties.Name -notcontains $_ }))
    Check 'plan is in execution order: order 10 first, then 100s in catalog order, order 200 last' ($ids[0] -eq 'p-early' -and $ids[-1] -eq 'p-late' -and $ids.IndexOf('p-plain') -lt $ids.IndexOf('p-weight'))
    Check 'default order is 100, explicit orders are reported' ((Step $pl 'p-plain').order -eq 100 -and (Step $pl 'p-early').order -eq 10 -and (Step $pl 'p-late').order -eq 200)
    Check 'registry step weight 1 by default, 7 when the catalog says so' ((Step $pl 'p-plain').weight -eq 1 -and (Step $pl 'p-weight').weight -eq 7)
    Check 'onError defaults to continue; stop-tweak is reported' ((Step $pl 'p-plain').onError -eq 'continue' -and @($pl | Where-Object { $_.tweakId -eq 'p-stop' -and $_.onError -eq 'stop-tweak' }).Count -eq 1)
    $r2 = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-Only', 'p-plain,p-late,p-early,p-weight,p-stop', '-TestEnvironment', $envFile) $wp2
    Check 'the plan order is identical on a second run (deterministic)' ($r2.Parsed -and (@($r2.Json | ForEach-Object { "$($_.tweakId)|$($_.target)" }) -join ',') -eq (@($pl | ForEach-Object { "$($_.tweakId)|$($_.target)" }) -join ','))
    $r = RunJson @('-List', '-AsJson', '-Only', 'p-plain,p-weight,p-stop', '-TestEnvironment', $envFile) $wp2
    $wmap = @{}; if ($r.Parsed) { foreach ($t in @($r.Json.tweaks)) { $wmap[$t.id] = $t.weight } }
    Check '-List JSON weight = sum of the steps still to do (1, 7, 3)' ($wmap['p-plain'] -eq 1 -and $wmap['p-weight'] -eq 7 -and $wmap['p-stop'] -eq 3)
    $r = Run @('-WhatIf', '-NoRestorePoint', '-Only', 'p-plain,p-weight', '-TestEnvironment', $envFile) $wp2
    Check '-WhatIf text reports the total weight' ($r.Out -match 'Work to do: 8 weight unit\(s\) in 2 step\(s\)')

    Write-Host 'Apply order follows the order hints'
    Remove-StateDir; Reset-P
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-plain,p-late,p-early', '-TestEnvironment', $envFile) $wp2
    $snap = Last-Snapshot
    Check 'apply ran early (10), plain (100), late (200) in that order' ($r.Code -eq 0 -and (@($snap.steps | ForEach-Object { $_.tweakId }) -join ',') -eq 'p-early,p-plain,p-late')
    Check 'apply prints weighted progress ending at 100%' ($r.Out -match '\[progress\] 33% - p-early' -and $r.Out -match '\[progress\] 100% - p-late')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp2

    Write-Host 'Error policy: continue (default) and stop-tweak'
    New-TestEnv $false 'Professional' 26200 'Unknown' @{ failSteps = @('p-stop|*StopB', 'p-cont|*ContB') }
    Remove-StateDir; Reset-P
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-stop,p-cont,p-plain', '-TestEnvironment', $envFile) $wp2
    $snap = Last-Snapshot
    $res = @{}; if ($snap) { foreach ($s in @($snap.steps)) { $res[($s.target -split '\\')[-1]] = $s.result } }
    Check 'exit code 2 (a step failed)' ($r.Code -eq 2)
    Check 'stop-tweak: step before the failure applied, failing step not written, step after it not run' ((Val $P 'StopA') -eq 1 -and $null -eq (Val $P 'StopB') -and $null -eq (Val $P 'StopC'))
    Check 'stop-tweak: snapshot results Verified / Failed / NotRun' ($res['StopA'] -eq 'Verified' -and $res['StopB'] -eq 'Failed' -and $res['StopC'] -eq 'NotRun')
    Check 'continue (default): the step after the failure still runs' ((Val $P 'ContA') -eq 1 -and $null -eq (Val $P 'ContB') -and (Val $P 'ContC') -eq 1 -and $res['ContC'] -eq 'Verified')
    Check 'other tweaks are unaffected by a stopped tweak' ((Val $P 'Plain') -eq 1)
    Check 'output explains the not-run step and the injected failure' ($r.Out -match 'not run because an earlier step' -and $r.Out -match 'Failed')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp2
    Check 'undo reverts what was applied (a Failed step is only restored to its before-state, a NotRun step is left alone)' ($r.Code -eq 0 -and $null -eq (Val $P 'StopA') -and $null -eq (Val $P 'ContA') -and $null -eq (Val $P 'ContC') -and $null -eq (Val $P 'Plain'))

    Write-Host 'Error policy: abort-run'
    New-TestEnv $false 'Professional' 26200 'Unknown' @{ failSteps = @('p-abort|*') }
    Remove-StateDir; Reset-P
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-early,p-plain,p-abort,p-late', '-TestEnvironment', $envFile) $wp2
    $snap = Last-Snapshot
    $res = @{}; if ($snap) { foreach ($s in @($snap.steps)) { $res[$s.tweakId] = $s.result } }
    Check 'exit code 2 and the run says it was aborted' ($r.Code -eq 2 -and $r.Out -match 'Run aborted at p-abort')
    Check 'steps ordered before the failing one ran (early, plain); later ones (late) did not' ((Val $P 'Early') -eq 1 -and (Val $P 'Plain') -eq 1 -and $null -eq (Val $P 'Late') -and $null -eq (Val $P 'AbortStep'))
    Check 'snapshot results: Verified, Verified, Failed, Aborted' ($res['p-early'] -eq 'Verified' -and $res['p-plain'] -eq 'Verified' -and $res['p-abort'] -eq 'Failed' -and $res['p-late'] -eq 'Aborted')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp2
    Check 'undo reverts the two applied steps and restores the failed one (an interrupted step may have changed something); the aborted one is untouched' ($r.Code -eq 0 -and $r.Out -match 'Reverting 3 step' -and $r.Out -match 'restore of an interrupted step' -and $null -eq (Val $P 'Early') -and $null -eq (Val $P 'Plain'))

    Write-Host 'Protected targets are skipped by the engine'
    New-TestEnv $false 'Professional' 26200 'Unknown' @{ protectedServiceKeys = @('Spooler') }
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-Only', 'p-prot-svc,p-prot-svc-locked,p-prot-appx,p-prot-reg-defender,p-prot-reg-vbs,p-prot-reg-svckey,p-prot-task', '-TestEnvironment', $envFile) $wp2
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'exit 0 and valid JSON' ($r.Code -eq 0 -and $r.Parsed)
    Check 'no step of the protected tweaks is a Change' (@($pl | Where-Object action -EQ 'Change').Count -eq 0)
    Check 'service AppXSvc: Skip, "protected target ... not supported by design"' ((Step $pl 'p-prot-svc').action -eq 'Skip' -and (Step $pl 'p-prot-svc').reason -match 'protected target: AppX Deployment Service' -and (Step $pl 'p-prot-svc').reason -match 'not supported by design')
    Check 'service with a write-protected key (fake ACL): Skip with the TrustedInstaller-style reason' ((Step $pl 'p-prot-svc-locked').action -eq 'Skip' -and (Step $pl 'p-prot-svc-locked').reason -match 'Windows protects this service key')
    Check 'AppX Microsoft.WindowsStore: Skip, protected' (@($pl | Where-Object { $_.tweakId -eq 'p-prot-appx' -and $_.action -eq 'Skip' -and $_.reason -match 'protected target' }).Count -ge 1 -and @($pl | Where-Object { $_.tweakId -eq 'p-prot-appx' -and $_.action -eq 'Change' }).Count -eq 0)
    Check 'registry Defender DisableAntiSpyware: Skip, protected' ((Step $pl 'p-prot-reg-defender').action -eq 'Skip' -and (Step $pl 'p-prot-reg-defender').reason -match 'Defender')
    Check 'registry DeviceGuard (VBS): Skip, protected' ((Step $pl 'p-prot-reg-vbs').action -eq 'Skip' -and (Step $pl 'p-prot-reg-vbs').reason -match 'virtualization-based security')
    Check 'registry Services\WinDefend\Start: Skip, protected' ((Step $pl 'p-prot-reg-svckey').action -eq 'Skip' -and (Step $pl 'p-prot-reg-svckey').reason -match 'Defender')
    Check 'Update Orchestrator tasks: Skip, protected' ((Step $pl 'p-prot-task').action -eq 'Skip' -and (Step $pl 'p-prot-task').reason -match 'protected target')
    $r = Run @('-NoRestorePoint', '-Force', '-Only', 'p-prot-svc,p-prot-reg-defender,p-prot-svc-locked', '-TestEnvironment', $envFile) $wp2
    Check 'applying only protected tweaks changes nothing ("Nothing to change")' ($r.Code -eq 0 -and $r.Out -match 'Nothing to change')
    New-TestEnv $false 'Professional' 26200 'Unknown'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-Only', 'p-prot-svc-locked', '-TestEnvironment', $envFile) $wp2
    Check 'the same service is a normal Change when its key is not write-protected' ($r.Parsed -and (Step $r.Json 'p-prot-svc-locked').action -eq 'Change')

    Write-Host '-Lint: step policy, new appliesTo keys and protected targets'
    $r = RunJson @('-Lint', '-AsJson') $wp2
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: protected service / appx / registry / task in the safe preset are errors' ((HasF 'p-prot-svc' 'protected-target') -and (HasF 'p-prot-appx' 'protected-target') -and (HasF 'p-prot-reg-defender' 'protected-target') -and (HasF 'p-prot-reg-vbs' 'protected-target') -and (HasF 'p-prot-reg-svckey' 'protected-target') -and (HasF 'p-prot-task' 'protected-target'))
    Check 'lint: ordinary tweaks with order / onError / requires* / build range are clean' (@($fi | Where-Object { $_.tweakId -in 'p-plain', 'p-late', 'p-early', 'p-weight', 'p-stop', 'p-abort', 'p-laptop', 'p-desktop', 'p-buildrange' -and $_.severity -eq 'error' }).Count -eq 0)
    $badPol = New-TempFile @'
{ "schemaVersion": 2, "tweaks": [
  { "id": "b-onerror", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1, "onError": "explode" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "b-order", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1, "order": "first" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "b-weight", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1, "weight": -3 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "b-both", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "appliesTo": { "requiresLaptop": true, "requiresDesktop": true, "reason": "r" } },
  { "id": "b-type", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "appliesTo": { "requiresLaptop": "yes", "reason": "r" } },
  { "id": "b-range", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "appliesTo": { "minBuild": 26200, "maxBuild": 22000, "reason": "r" } },
  { "id": "b-build", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "appliesTo": { "minBuild": "new", "reason": "r" } },
  { "id": "b-nonsafe-protected", "category": "o", "implementation": { "type": "service", "name": "WaaSMedicSvc", "startType": "Disabled" }, "revert": "snapshot", "risk": "breaks-features", "preset": "balanced" }
] }
'@
    $r = RunJson @('-Lint', '-AsJson') $badPol
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: unknown onError value' (HasF 'b-onerror' 'step-policy')
    Check 'lint: non-integer order' (HasF 'b-order' 'step-policy')
    Check 'lint: negative weight' (HasF 'b-weight' 'step-policy')
    Check 'lint: requiresLaptop together with requiresDesktop' (@($fi | Where-Object { $_.tweakId -eq 'b-both' -and $_.rule -eq 'appliesTo' -and $_.message -match 'never be satisfied' }).Count -eq 1)
    Check 'lint: requiresLaptop must be a boolean' (@($fi | Where-Object { $_.tweakId -eq 'b-type' -and $_.rule -eq 'appliesTo' -and $_.message -match 'true or false' }).Count -eq 1)
    Check 'lint: minBuild above maxBuild' (@($fi | Where-Object { $_.tweakId -eq 'b-range' -and $_.rule -eq 'appliesTo' -and $_.message -match 'can never apply' }).Count -eq 1)
    Check 'lint: non-numeric minBuild' (@($fi | Where-Object { $_.tweakId -eq 'b-build' -and $_.rule -eq 'appliesTo' -and $_.message -match 'positive integer' }).Count -eq 1)
    Check 'lint: a protected target outside the safe preset is only informational' (@($fi | Where-Object { $_.tweakId -eq 'b-nonsafe-protected' -and $_.rule -eq 'protected-target' -and $_.severity -eq 'info' }).Count -eq 1)

    Write-Host 'Real catalog: protected targets and safe-preset guarantees'
    $realLint = RunJson @('-Lint', '-AsJson') (Join-Path $PSScriptRoot '..\tweak-catalog.json')
    Check 'real catalog: no protected target anywhere in the safe preset (lint rule protected-target)' ($realLint.Parsed -and @($realLint.Json.findings | Where-Object { $_.rule -eq 'protected-target' -and $_.severity -eq 'error' }).Count -eq 0)
    Check 'real catalog: lint step-policy and appliesTo rules report nothing' ($realLint.Parsed -and @($realLint.Json.findings | Where-Object { $_.rule -in 'step-policy', 'appliesTo' }).Count -eq 0)
    $realCat2 = Get-Content (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json
    $defOff = @($realCat2.tweaks | Where-Object { $_.preset -in 'safe', 'balanced' -and $_.id -match 'defender-disable|vbs|smart-app|wuauserv' })
    Check 'real catalog: nothing that disables Defender, VBS or Windows Update is in safe or balanced' ($defOff.Count -eq 0)
    Check 'real catalog: a tweak that would disable Defender by policy is skipped by the engine (never-default id, protected value)' (@($realCat2.tweaks | Where-Object { $_.id -eq 'sec-defender-disable-policy' }).Count -eq 1)

    # ======================= WP3: native disk and system handlers =======================
    # Read functions are exercised live (read-only); set and undo only ever run against the fake tools.
    $wp3 = Join-Path $PSScriptRoot 'test-catalog-wp3.json'
    function Get-RealWp3State {
        # Everything the WP3 handlers can change, read without changing anything.
        $ErrorActionPreference = 'Continue'
        $pw = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
        $rs = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -ErrorAction SilentlyContinue
        $mm = try { [string](Get-MMAgent).MemoryCompression } catch { 'unreadable' }
        $ch = foreach ($c in 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic') { & wevtutil.exe gl $c 2>$null | Select-String '^\s*enabled:' }
        @(
            "compact: $(& compact.exe /CompactOS:query 2>$null)"
            "hibernate: $($pw.HibernateEnabled)/$($pw.HiberFileType)"
            "reserved: $($rs.ShippedWithReserves) / $(& dism.exe /Online /Get-ReservedStorageState 2>$null | Select-String 'Reserved storage')"
            "plans: $(& powercfg.exe /l 2>$null) active: $(& powercfg.exe /getactivescheme 2>$null)"
            "mmagent: $mm"
            "8dot3: $(& fsutil.exe behavior query disable8dot3 2>$null) $(& fsutil.exe 8dot3name query C: 2>$null)"
            "channels: $ch"
            "bootmenu: $(& bcdedit.exe /enum '{current}' 2>$null | Select-String 'bootmenupolicy')"
        ) -join "`n"
    }
    $realWp3Before = Get-RealWp3State
    $wp3Ids = 'disk-compactos-on', 'pwr-hibernate-off', 'pwr-hiberfile-reduced', 'perf-reserved-storage-off', 'disk-component-cleanup', 'pwr-ultra-performance-plan', 'perf-memory-compression-off', 'perf-ntfs-8dot3-off', 'perf-ntfs-8dot3-volume-off', 'perf-sleepstudy-off', 'perf-bootmenu-legacy'
    $dkPlan = 'deb10a7c-17a1-4e2d-9c3f-5a6b7c8d9e01'
    $sleepChannels = 'Microsoft-Windows-SleepStudy/Diagnostic', 'Microsoft-Windows-Kernel-Processor-Power/Diagnostic', 'Microsoft-Windows-UserModePowerService/Diagnostic'
    function WpPlan([string[]]$More = @()) {
        $r = RunJson (@('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) + $More) $wp3
        if ($r.Parsed) { @($r.Json) } else { @() }
    }

    Write-Host 'WP3: read functions against the REAL system (-WhatIf only, nothing is written)'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-AllowIrreversible') $wp3
    Check 'real -WhatIf -AsJson: exit 0 and stdout is pure JSON' ($r.Code -eq 0 -and $r.Parsed -and $r.Out.TrimStart().StartsWith('['))
    $live = if ($r.Parsed) { @($r.Json) } else { @() }
    foreach ($id in $wp3Ids) {
        $rows = @($live | Where-Object { $_.tweakId -eq $id })
        Check "real: $id has plan rows and every Get returned a value (no 'could not read')" ($rows.Count -ge 1 -and @($rows | Where-Object { $_.reason -match 'could not read current state' }).Count -eq 0)
    }
    Check 'real: sleep study plans three channels' (@($live | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' }).Count -eq 3)
    Check 'real: the 8.3 per-volume handler found at least one NTFS volume' (@($live | Where-Object { $_.tweakId -eq 'perf-ntfs-8dot3-volume-off' -and $_.target -match '^[A-Za-z]:$' }).Count -ge 1)
    Check 'real: compact state reads as compact or not-compact' ((Step $live 'disk-compactos-on').current -in 'compact', 'not-compact')
    Check 'real: hibernation reads as off, reduced or full' ((Step $live 'pwr-hiberfile-reduced').current -in 'off', 'reduced', 'full')
    Check 'real: reserved storage reads as enabled or disabled' ((Step $live 'perf-reserved-storage-off').current -in 'enabled', 'disabled')
    Check 'real: the active power scheme reads as a GUID' ((Step $live 'pwr-ultra-performance-plan').current -match '^[0-9a-f]{8}-')
    Check 'real: memory compression reads as enabled or disabled' ((Step $live 'perf-memory-compression-off').current -in 'enabled', 'disabled')
    Check 'real: boot menu policy reads' ((Step $live 'perf-bootmenu-legacy').current -in 'legacy', 'standard', 'absent')
    Check 'real: the component cleanup plan did not run the (slow) analysis' ((Step $live 'disk-component-cleanup').current -eq 'pending')
    Check 'real system: nothing changed by the read-only plan' ((Get-RealWp3State) -eq $realWp3Before)

    Write-Host 'WP3: plan against the fake tools'
    New-TestEnv $false 'Professional' 26200 'Desktop'
    $pl = WpPlan
    Check 'fake plan: exit parse ok and all native rows present' ($pl.Count -ge 12)
    Check 'compact OS: not-compact -> compact' ((Step $pl 'disk-compactos-on').action -eq 'Change' -and (Step $pl 'disk-compactos-on').current -eq 'not-compact' -and (Step $pl 'disk-compactos-on').desired -eq 'compact')
    Check 'hibernate off: full -> off on a desktop' ((Step $pl 'pwr-hibernate-off').action -eq 'Change' -and (Step $pl 'pwr-hibernate-off').current -eq 'full' -and (Step $pl 'pwr-hibernate-off').desired -eq 'off')
    Check 'reduced hiberfile in the same plan as hibernate-off: skipped, conflicts with pwr-hibernate-off (both write the hibernation setting)' ((Step $pl 'pwr-hiberfile-reduced').action -eq 'Skip' -and (Step $pl 'pwr-hiberfile-reduced').reason -match 'conflicts with pwr-hibernate-off')
    $plH = WpPlan @('-Only', 'pwr-hiberfile-reduced')
    Check 'reduced hiberfile on its own: full -> reduced' ((Step $plH 'pwr-hiberfile-reduced').action -eq 'Change' -and (Step $plH 'pwr-hiberfile-reduced').current -eq 'full' -and (Step $plH 'pwr-hiberfile-reduced').desired -eq 'reduced')
    $plH2 = WpPlan @('-Only', 'pwr-hibernate-off,pwr-hiberfile-reduced')
    Check '-Only pwr-hibernate-off,pwr-hiberfile-reduced: exactly one of them is planned as a change (the second would silently undo the first)' (@($plH2 | Where-Object { $_.tweakId -in 'pwr-hibernate-off', 'pwr-hiberfile-reduced' -and $_.action -eq 'Change' }).Count -eq 1)
    Check 'reserved storage: enabled -> disabled' ((Step $pl 'perf-reserved-storage-off').action -eq 'Change' -and (Step $pl 'perf-reserved-storage-off').current -eq 'enabled' -and (Step $pl 'perf-reserved-storage-off').desired -eq 'disabled')
    Check 'power plan: active scheme -> DebloatKit plan GUID' ((Step $pl 'pwr-ultra-performance-plan').action -eq 'Change' -and (Step $pl 'pwr-ultra-performance-plan').desired -eq $dkPlan)
    Check 'memory compression: enabled -> disabled, no warning at 40 % commit' ((Step $pl 'perf-memory-compression-off').action -eq 'Change' -and (Step $pl 'perf-memory-compression-off').desired -eq 'disabled' -and -not (Step $pl 'perf-memory-compression-off').reason)
    Check '8.3 system-wide: 0 -> 1' ((Step $pl 'perf-ntfs-8dot3-off').action -eq 'Change' -and (Step $pl 'perf-ntfs-8dot3-off').current -eq '0' -and (Step $pl 'perf-ntfs-8dot3-off').desired -eq '1')
    $v8 = Step $pl 'perf-ntfs-8dot3-volume-off'
    Check '8.3 per volume: skipped while the system-wide setting is not 2, with the reason' ($v8.action -eq 'Skip' -and $v8.target -eq 'C:' -and $v8.reason -match 'system-wide setting is 0')
    $sl = @($pl | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' })
    Check 'sleep study: one Change row per channel, target is the channel' ($sl.Count -eq 3 -and @($sl | Where-Object { $_.action -eq 'Change' -and $_.current -eq 'true' -and $_.desired -eq 'false' }).Count -eq 3 -and -not (Compare-Object @($sl.target | Sort-Object) @($sleepChannels | Sort-Object)))
    Check 'boot menu: absent -> legacy when BitLocker is off' ((Step $pl 'perf-bootmenu-legacy').action -eq 'Change' -and (Step $pl 'perf-bootmenu-legacy').current -eq 'absent' -and (Step $pl 'perf-bootmenu-legacy').desired -eq 'legacy')
    Check 'component cleanup: Skip without -AllowIrreversible' ((Step $pl 'disk-component-cleanup').action -eq 'Skip' -and (Step $pl 'disk-component-cleanup').reason -match 'AllowIrreversible')
    $pl = WpPlan @('-AllowIrreversible')
    Check 'component cleanup: Change with -AllowIrreversible, labelled irreversible' ((Step $pl 'disk-component-cleanup').action -eq 'Change' -and (Step $pl 'disk-component-cleanup').reason -match 'irreversible')
    $rj = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-AllowIrreversible', '-TestEnvironment', $envFile) $wp3
    $ord = @($rj.Json | Where-Object { $_.action -eq 'Change' })
    Check 'plan JSON carries order and weight from the catalog step (compact OS 300/30, reserved storage 200/6)' ((Step $ord 'disk-compactos-on').order -eq 300 -and (Step $ord 'disk-compactos-on').weight -eq 30 -and (Step $ord 'perf-reserved-storage-off').order -eq 200 -and (Step $ord 'perf-reserved-storage-off').weight -eq 6)
    Check 'plan JSON runs the heavy steps last (compact OS and cleanup after every default-order step)' (@($ord | Where-Object { $_.order -eq 100 }).Count -ge 6 -and (@($ord).IndexOf((Step $ord 'disk-compactos-on')) -gt @($ord).IndexOf((Step $ord 'perf-bootmenu-legacy'))))

    Write-Host 'WP3: Check rules (skip and note)'
    New-TestEnv $false 'Professional' 26200 'Laptop'
    $pl = WpPlan
    Check 'laptop: hibernate off is not applicable' ((Step $pl 'pwr-hibernate-off').action -eq 'Skip' -and (Step $pl 'pwr-hibernate-off').reason -match 'not applicable')
    Check 'laptop: reduced hiberfile is still planned' ((Step $pl 'pwr-hiberfile-reduced').action -eq 'Change')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'commit:percent' = '90' }
    $pl = WpPlan
    Check 'commit 90 %: memory compression stays a Change but carries a warning' ((Step $pl 'perf-memory-compression-off').action -eq 'Change' -and (Step $pl 'perf-memory-compression-off').reason -match 'note: commit charge is 90 %')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'bitlocker:protection' = 'on' }
    $pl = WpPlan
    Check 'BitLocker on: boot menu change skipped' ((Step $pl 'perf-bootmenu-legacy').action -eq 'Skip' -and (Step $pl 'perf-bootmenu-legacy').reason -match 'BitLocker')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'bitlocker:protection' = 'unknown' }
    $pl = WpPlan
    Check 'BitLocker state unreadable: boot menu change skipped (fail safe)' ((Step $pl 'perf-bootmenu-legacy').action -eq 'Skip' -and (Step $pl 'perf-bootmenu-legacy').reason -match 'could not tell')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'powercfg:hibernate' = 'off' }
    $pl = WpPlan
    Check 'hibernation already off: reduced is skipped (nothing to reduce), hibernate-off is InSync' ((Step $pl 'pwr-hiberfile-reduced').action -eq 'Skip' -and (Step $pl 'pwr-hiberfile-reduced').reason -match 'no hibernation file' -and (Step $pl 'pwr-hibernate-off').action -eq 'InSync')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{ preflight = @{ rebootPending = @('Component Based Servicing: RebootPending') } }
    $pl = WpPlan @('-AllowIrreversible')
    Check 'restart pending: compact OS, reserved storage and component cleanup are skipped' ((Step $pl 'disk-compactos-on').action -eq 'Skip' -and (Step $pl 'perf-reserved-storage-off').action -eq 'Skip' -and (Step $pl 'disk-component-cleanup').action -eq 'Skip' -and (Step $pl 'perf-reserved-storage-off').reason -match 'restart is pending')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{ preflight = @{ servicingBusy = $true } }
    $pl = WpPlan @('-AllowIrreversible')
    Check 'servicing busy: component cleanup skipped with the 0x800F0806 reason' ((Step $pl 'disk-component-cleanup').action -eq 'Skip' -and (Step $pl 'disk-component-cleanup').reason -match '0x800F0806')
    # the real catalog carries managedSkip on this tweak (checked below); here the same flag is added to the test copy
    $wp3Managed = New-TempFile ((Get-Content $wp3 -Raw) -replace '("id": "perf-reserved-storage-off",)', '$1 "managedSkip": "test: update reliability is the organisations area",')
    New-TestEnv $true
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $wp3Managed
    $pl = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'managed device: reserved storage skipped' ((Step $pl 'perf-reserved-storage-off').action -eq 'Skip' -and (Step $pl 'perf-reserved-storage-off').reason -match 'managed device')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'fsutil:disable8dot3' = '2' }
    $pl = WpPlan
    $v8 = Step $pl 'perf-ntfs-8dot3-volume-off'
    Check '8.3 per volume: Change on C: when the system-wide setting is 2' ($v8.action -eq 'Change' -and $v8.target -eq 'C:' -and $v8.current -eq '0' -and $v8.desired -eq '1')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'wevtutil:microsoft-windows-sleepstudy/diagnostic' = 'false' }
    $pl = WpPlan
    $sl1 = @($pl | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' -and $_.target -eq 'Microsoft-Windows-SleepStudy/Diagnostic' })
    Check 'sleep study: a channel that is already off is InSync' ($sl1.Count -eq 1 -and $sl1[0].action -eq 'InSync')

    Write-Host 'WP3: targets are allowlisted'
    $badTargets = New-TempFile @'
{ "schemaVersion": 2, "tweaks": [
  { "id": "perf-sleepstudy-off", "category": "o", "implementation": { "type": "multi", "steps": [
      { "type": "command", "run": "x", "undo": "x", "target": "Security" },
      { "type": "command", "run": "x", "undo": "x" },
      { "type": "command", "run": "x", "undo": "x", "target": "*" } ] }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "perf-ntfs-8dot3-volume-off", "category": "o", "implementation": { "type": "command", "run": "x", "undo": "x", "target": "C:\\Windows" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "perf-ntfs-lastaccess", "category": "o", "implementation": { "type": "command", "run": "x", "undo": "x", "target": "C:" }, "revert": "snapshot", "risk": "safe", "preset": "safe" }
] }
'@
    New-TestEnv $false 'Professional' 26200 'Desktop'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $badTargets
    $bt = if ($r.Parsed) { @($r.Json) } else { @() }
    Check 'a channel that is not on the allowlist is skipped, never run' (@($bt | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' -and $_.action -eq 'Skip' -and $_.reason -match "not on this handler's allowlist" }).Count -eq 1)
    Check 'a targeted step without a target is skipped' (@($bt | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' -and $_.action -eq 'Skip' -and $_.reason -match 'no target' }).Count -eq 1)
    Check "'*' is refused by a handler that cannot expand it" (@($bt | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' -and $_.action -eq 'Skip' -and $_.reason -match "'\*' is not supported" }).Count -eq 1)
    Check 'a volume path that is not a drive letter is skipped' (@($bt | Where-Object { $_.tweakId -eq 'perf-ntfs-8dot3-volume-off' -and $_.action -eq 'Skip' -and $_.reason -match 'allowlist' }).Count -eq 1)
    $r = RunJson @('-Lint', '-AsJson') $badTargets
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: unlisted target, missing target and "*" without Expand are native-target errors' (@($fi | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' -and $_.rule -eq 'native-target' }).Count -eq 3)
    Check 'lint: bad volume target and a target on an untargeted handler are errors' ((HasF 'perf-ntfs-8dot3-volume-off' 'native-target') -and (HasF 'perf-ntfs-lastaccess' 'native-target'))

    Write-Host 'WP3: apply and undo on the fake tools (the real system is only read)'
    $sch = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c,381b4222-f694-41f0-9685-ff5bb260df2e"
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'fsutil:disable8dot3' = '2'; 'powercfg:schemes' = $sch }
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Skip', 'pwr-hibernate-off') $wp3
    Check 'apply: exit 0, no Failed / Unverified' ($r.Code -eq 0 -and $r.Out -match 'Verified' -and $r.Out -notmatch 'Failed|Unverified')
    Check 'apply: compact OS on' ((Get-Fake 'compactos:state') -eq 'compact')
    Check 'apply: hibernation file reduced' ((Get-Fake 'powercfg:hibernate') -eq 'reduced')
    Check 'apply: reserved storage disabled' ((Get-Fake 'dism:reservedstorage') -eq 'disabled')
    Check 'apply: DebloatKit power plan created, named, and active' ((Get-Fake 'powercfg:activescheme') -eq $dkPlan -and (Get-Fake 'powercfg:schemes') -match $dkPlan)
    Check 'apply: memory compression disabled' ((Get-Fake 'mmagent:memorycompression') -eq 'False')
    Check 'apply: 8.3 system-wide setting 1 and the C: volume flag 1 (the volume step ran because the system-wide value was 2 when it was planned)' ((Get-Fake 'fsutil:disable8dot3') -eq '1' -and (Get-Fake 'fsutil:8dot3name:c:') -eq '1')
    Check 'apply: all three Sleep Study channels disabled' (@($sleepChannels | Where-Object { (Get-Fake ('wevtutil:' + $_.ToLower())) -eq 'false' }).Count -eq 3)
    Check 'apply: boot menu policy legacy' ((Get-Fake 'bcdedit:bootmenupolicy') -eq 'legacy')
    Check 'apply: component cleanup was not run (irreversible, no switch)' ($null -eq (Get-Fake 'dism:lastcleanup'))
    Check 'apply: free disk space is printed before and after for the disk steps' ($r.Out -match 'measured: before')
    $logTxt = (Get-ChildItem $stateDir -Filter 'run-*.log.jsonl' | Sort-Object Name | Select-Object -Last 1 | Get-Content -Raw)
    Check 'run log records the free-disk metric' ($logTxt -match 'freeDiskMB')
    $snap = Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1
    $snapJson = Get-Content $snap.FullName -Raw | ConvertFrom-Json
    $planStep = @($snapJson.steps | Where-Object { $_.tweakId -eq 'pwr-ultra-performance-plan' })[0]
    Check 'snapshot: power plan records the prior scheme and that the plan did not exist' ($planStep.before.value -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' -and $planStep.before.planExisted -eq $false)
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Skip', 'pwr-hibernate-off') $wp3
    Check 'apply again: nothing to change' ($r.Out -match 'Nothing to change')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp3
    Check 'undo: exit 0' ($r.Code -eq 0)
    Check 'undo: compact OS back to not-compact' ((Get-Fake 'compactos:state') -eq 'not-compact')
    Check 'undo: hibernation type back to full' ((Get-Fake 'powercfg:hibernate') -eq 'full')
    Check 'undo: reserved storage back to enabled' ((Get-Fake 'dism:reservedstorage') -eq 'enabled')
    Check 'undo: prior power scheme active again and the DebloatKit plan deleted' ((Get-Fake 'powercfg:activescheme') -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' -and (Get-Fake 'powercfg:schemes') -eq $sch)
    Check 'undo: memory compression back on' ((Get-Fake 'mmagent:memorycompression') -eq 'True')
    Check 'undo: C: 8.3 flag back to 0, system-wide setting back to 2' ((Get-Fake 'fsutil:8dot3name:c:') -eq '0' -and (Get-Fake 'fsutil:disable8dot3') -eq '2')
    Check 'undo: Sleep Study channels back on' (@($sleepChannels | Where-Object { (Get-Fake ('wevtutil:' + $_.ToLower())) -eq 'true' }).Count -eq 3)
    Check 'undo: boot menu policy element removed again (it did not exist before)' ($null -eq (Get-Fake 'bcdedit:bootmenupolicy'))

    Write-Host 'WP3: undo keeps what already existed (plan that existed, boot policy that was set, 8.3 prior value)'
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'powercfg:schemes' = "$sch,$dkPlan"; 'bcdedit:bootmenupolicy' = 'standard' }
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Only', 'pwr-ultra-performance-plan,perf-bootmenu-legacy') $wp3
    Check 'apply on existing plan / standard boot policy: exit 0' ($r.Code -eq 0 -and (Get-Fake 'powercfg:activescheme') -eq $dkPlan -and (Get-Fake 'bcdedit:bootmenupolicy') -eq 'legacy')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp3
    Check 'undo: the plan that existed before is kept, the old scheme is active, boot policy back to standard' ($r.Code -eq 0 -and (Get-Fake 'powercfg:schemes') -match $dkPlan -and (Get-Fake 'powercfg:activescheme') -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' -and (Get-Fake 'bcdedit:bootmenupolicy') -eq 'standard')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'fsutil:disable8dot3' = '3' }
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Only', 'perf-ntfs-8dot3-off') $wp3
    Check 'apply 8.3 system-wide: 3 -> 1' ($r.Code -eq 0 -and (Get-Fake 'fsutil:disable8dot3') -eq '1')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp3
    Check 'undo 8.3 system-wide restores the exact prior value 3 (not a fixed 2)' ($r.Code -eq 0 -and (Get-Fake 'fsutil:disable8dot3') -eq '3')

    Write-Host 'WP3: hibernate off on a desktop, then undo from reduced'
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'powercfg:hibernate' = 'reduced' }
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Only', 'pwr-hibernate-off') $wp3
    Check 'hibernate off: reduced -> off' ($r.Code -eq 0 -and (Get-Fake 'powercfg:hibernate') -eq 'off')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp3
    Check 'undo: back to reduced (hibernation turned on, then the type set)' ($r.Code -eq 0 -and (Get-Fake 'powercfg:hibernate') -eq 'reduced')

    Write-Host 'WP3: component store cleanup (irreversible)'
    New-TestEnv $false 'Professional' 26200 'Desktop'
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Only', 'disk-component-cleanup', '-AllowIrreversible') $wp3
    Check 'apply with -AllowIrreversible: exit 0, Verified' ($r.Code -eq 0 -and $r.Out -match 'Verified' -and $r.Out -notmatch 'Failed')
    Check 'cleanup ran StartComponentCleanup WITHOUT /ResetBase' ((Get-Fake 'dism:lastcleanup') -eq '/online /cleanup-image /startcomponentcleanup')
    $logTxt = (Get-ChildItem $stateDir -Filter 'run-*.log.jsonl' | Sort-Object Name | Select-Object -Last 1 | Get-Content -Raw)
    Check 'run log: component store size and free disk recorded before and after' ($logTxt -match '7\.00 GB' -and $logTxt -match '5\.50 GB' -and $logTxt -match 'cleanupRecommended' -and $logTxt -match 'freeDiskMB')
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp3
    Check 'undo is refused with the reason (exit 2), nothing is changed' ($r.Code -eq 2 -and $r.Out -match 'cannot be undone automatically' -and (Get-Fake 'dism:componentstore:recommended') -eq 'No')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'dism:cleanupfails' = 'servicing' }
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-Only', 'disk-component-cleanup', '-AllowIrreversible') $wp3
    $logTxt = (Get-ChildItem $stateDir -Filter 'run-*.log.jsonl' | Sort-Object Name | Select-Object -Last 1 | Get-Content -Raw)
    Check 'servicing pending (0x800F0806): the step fails with a clear message' ($r.Code -eq 2 -and $logTxt -match 'servicing is pending')
    $engineSrc = Get-Content -LiteralPath $engine -Raw
    Check 'engine source: /ResetBase is never part of a tool call' ($engineSrc -notmatch "Invoke-Tool[^\r\n]*ResetBase")

    Write-Host 'WP3: -List -AsJson stays clean JSON with the new handlers'
    New-TestEnv $false 'Professional' 26200 'Desktop'
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile) $wp3
    Check '-List -AsJson: pure JSON, all 11 ids listed' ($r.Parsed -and $r.Out.TrimStart().StartsWith('{') -and @($r.Json.tweaks).Count -eq 11)

    Write-Host 'WP3: lint'
    $r = RunJson @('-Lint', '-AsJson') $wp3
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: an irreversible native handler in the safe preset is an error' (HasF 'disk-component-cleanup' 'safe-preset')
    Check 'lint: every handler round trip passes (all 11 WP3 handlers plus the three existing ones)' (@($fi | Where-Object { $_.severity -eq 'error' -and $_.rule -in 'native-roundtrip', 'native-handler' -and $_.tweakId -notin 'disk-component-cleanup' }).Count -eq 0)
    $badIrrev = New-TempFile @'
{ "schemaVersion": 2, "tweaks": [
  { "id": "disk-component-cleanup", "category": "o", "implementation": { "type": "command", "run": "x", "undo": null }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" }
] }
'@
    $r = RunJson @('-Lint', '-AsJson') $badIrrev
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: an irreversible handler whose catalog revert does not say "not reversible" is an error' (HasF 'disk-component-cleanup' 'native-handler')
    # deliberate engine defects
    $engSrc3 = Get-Content -LiteralPath $engine -Raw
    $dir3 = Join-Path ([IO.Path]::GetTempPath()) ('DebloatKitLint3-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $dir3 | Out-Null; $tmpFiles.Add($dir3)
    $mutant3 = Join-Path $dir3 'DebloatKit.ps1'
    function LintMutant3([string]$Old, [string]$New) {
        $src = $engSrc3.Replace($Old, $New)
        if ($src -eq $engSrc3) { return $null }
        [IO.File]::WriteAllText($mutant3, $src, [Text.UTF8Encoding]::new($false))
        $o = & $host_ -NoProfile -ExecutionPolicy Bypass -File $mutant3 -Lint -AsJson -CatalogPath $wp3 2>&1 | Out-String
        try { $o | ConvertFrom-Json } catch { $null }
    }
    $fj = LintMutant3 "Assert-ToolOk (Invoke-Tool 'powercfg.exe' @('/delete', `$DebloatKitPlanGuid)) 'powercfg /delete'" "'$null = 1'"
    Check 'lint: an undo that leaves the created power plan behind is an error' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'pwr-ultra-performance-plan' -and $_.rule -eq 'native-roundtrip' -and $_.message -match 'differ from where they started' }).Count -eq 1)
    $fj = LintMutant3 "@('/set', '{current}', 'bootmenupolicy', `$Policy)" "@('/set', '{current}', 'bootmenupolicy', 'standard')"
    Check 'lint: a Set that writes another value than Get reads back is an error (boot menu)' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'perf-bootmenu-legacy' -and $_.rule -eq 'native-roundtrip' }).Count -eq 1)
    $fj = LintMutant3 "@('sl', `$Channel, `"/e:`$State`")" "@('sl', `$Channel, '/e:true')"
    Check 'lint: an event channel Set that cannot disable is an error (Sleep Study)' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'perf-sleepstudy-off' -and $_.rule -eq 'native-roundtrip' }).Count -eq 1)
    $fj = LintMutant3 "@('8dot3name', 'set', `$t, [string]`$v)" "@('8dot3name', 'query', `$t)"
    Check 'lint: a per-volume Set that changes nothing is an error (8.3)' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'perf-ntfs-8dot3-volume-off' -and $_.rule -eq 'native-roundtrip' }).Count -eq 1)

    Write-Host 'WP3: real catalog wiring'
    $rc = Get-Content (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json
    function RcTweak([string]$Id) { @($rc.tweaks | Where-Object id -EQ $Id)[0] }
    Check 'real catalog: all 11 WP3 ids exist' (@($wp3Ids | Where-Object { RcTweak $_ }).Count -eq 11)
    Check 'real catalog: none of the WP3 disk/system tweaks is in the safe preset' (@($wp3Ids | Where-Object { (RcTweak $_).preset -eq 'safe' }).Count -eq 0)
    Check 'real catalog: component cleanup is balanced and "not reversible", /ResetBase variant is aggressive' ((RcTweak 'disk-component-cleanup').preset -eq 'balanced' -and (RcTweak 'disk-component-cleanup').revert -match 'not reversible' -and (RcTweak 'perf-dism-cleanup-resetbase').preset -eq 'aggressive' -and (RcTweak 'disk-component-cleanup').implementation.run -notmatch 'ResetBase')
    Check 'real catalog: the /ResetBase entry quotes the Microsoft warning' ((RcTweak 'perf-dism-cleanup-resetbase').tradeoff -match "All existing update packages can't be uninstalled")
    Check 'real catalog: hibernate off and the performance power plan are desktop-only' ((RcTweak 'pwr-hibernate-off').appliesTo.requiresDesktop -eq $true -and (RcTweak 'pwr-ultra-performance-plan').appliesTo.requiresDesktop -eq $true)
    Check 'real catalog: reserved storage is still a managed-device skip' ([bool](RcTweak 'perf-reserved-storage-off').managedSkip)
    $sleepSteps = @((RcTweak 'perf-sleepstudy-off').implementation.steps)
    Check 'real catalog: Sleep Study has three steps, each with a channel target' ($sleepSteps.Count -eq 3 -and -not (Compare-Object @($sleepSteps.target | Sort-Object) @($sleepChannels | Sort-Object)))
    Check 'real catalog: boot menu uses {current} and the 8.3 volume entry targets all volumes' ((RcTweak 'perf-bootmenu-legacy').implementation.run -match '\{current\}' -and (RcTweak 'perf-ntfs-8dot3-volume-off').implementation.target -eq '*')
    Check 'real catalog: catalogVersion was bumped' ($rc.catalogVersion -ne '2026.10.17.1')
    Check 'real catalog: hiberfile 40 % -> 20 % figure present for the effectiveness 2 rating' ((RcTweak 'pwr-hiberfile-reduced').effectiveness -eq 2 -and (RcTweak 'pwr-hiberfile-reduced').measuredEffect -match '\d')

    # ======================= WP4: capabilities, optional features, AppX profiles =======================
    # The real system is only read (-WhatIf plans, inventories before and after). Every apply and undo runs against the
    # fake capability / optionalfeature / appx / wusource tools in the -TestEnvironment file.
    $wp4 = Join-Path $PSScriptRoot 'test-catalog-wp4.json'
    $wp4Prof = Join-Path $PSScriptRoot 'test-appx-profiles.json'
    function Get-RealWp4State {
        $ErrorActionPreference = 'Continue'
        $cap = try { @(Get-WindowsCapability -Online -ErrorAction Stop | ForEach-Object { "$($_.Name)=$($_.State)" }) -join "`n" } catch { 'unreadable' }
        $feat = try { @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | ForEach-Object { "$($_.FeatureName)=$($_.State)" }) -join "`n" } catch { 'unreadable' }
        # names only: a Store or Intune app update between the two reads changes the version in the full name, which is not what is being tested
        $apps = try { @(Get-AppxPackage -AllUsers -ErrorAction Stop | ForEach-Object { $_.Name } | Sort-Object -Unique) -join "`n" } catch { 'unreadable' }
        $prov = try { @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName } | Sort-Object -Unique) -join "`n" } catch { 'unreadable' }
        "$cap`n$feat`n$apps`n$prov"
    }
    $realWp4Before = Get-RealWp4State
    function W4Plan([string[]]$More = @(), [string]$Cat = $wp4) {
        $r = RunJson (@('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) + $More) $Cat
        if ($r.Parsed) { @($r.Json) } else { @() }
    }
    function Rows($Plan, [string]$Id) { @($Plan | Where-Object { $_.tweakId -eq $Id }) }
    function W4Apply([string[]]$More = @(), [string]$Cat = $wp4) { Run (@('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) + $More) $Cat }
    function W4Undo { Run @('-Undo', 'latest', '-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) $wp4 }
    function Fk([string]$Name) { $p = (Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json).tools.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null } }
    $capKeys = @{ wordpad = 'capability:microsoft.windows.wordpad~~~~0.0.1.0'; steps = 'capability:app.stepsrecorder~~~~0.0.1.0'; wmp = 'capability:media.windowsmediaplayer~~~~0.0.12.0'; lang = 'capability:language.basic~~~en-us~~~0.0.1.0'; ie = 'feature:internet-explorer-optional-amd64' }
    # the seed every WP4 apply test starts from (the state keys must be in the file so Fk can read them)
    $w4Seed = @{
        'capability:microsoft.windows.wordpad~~~~0.0.1.0' = 'Microsoft.Windows.WordPad~~~~0.0.1.0|Installed'
        'capability:app.stepsrecorder~~~~0.0.1.0'         = 'App.StepsRecorder~~~~0.0.1.0|Installed'
        'capability:media.windowsmediaplayer~~~~0.0.12.0' = 'Media.WindowsMediaPlayer~~~~0.0.12.0|NotPresent'
        'feature:internet-explorer-optional-amd64'        = 'Internet-Explorer-Optional-amd64|Enabled'
        'appx:microsoft.bingnews'                         = 'Microsoft.BingNews;4.55.0.0;8wekyb3d8bbwe;UP'
        'appx:microsoft.paint'                            = 'Microsoft.Paint;11.2401.0.0;8wekyb3d8bbwe;UP'
        'appx:microsoft.vclibs.140.00'                    = 'Microsoft.VCLibs.140.00;14.0.33519.0;8wekyb3d8bbwe;UF'
        'appx:microsoft.ui.xaml.2.8'                      = 'Microsoft.UI.Xaml.2.8;8.2310.30001.0;8wekyb3d8bbwe;UF'
    }
    function W4Env([bool]$Managed = $false, [string]$Edition = 'Professional', [hashtable]$Tools = @{}) {
        $t = @{}; foreach ($k in $w4Seed.Keys) { $t[$k] = $w4Seed[$k] }; foreach ($k in $Tools.Keys) { $t[$k] = $Tools[$k] }
        New-TestEnv $Managed $Edition 26200 'Desktop' @{} $t
    }

    Write-Host 'WP4: the real system is only READ (-WhatIf plan against the real inventory)'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-AllowIrreversible', '-ProfilesPath', $wp4Prof) $wp4
    Check 'real -WhatIf -AsJson: exit 0, stdout is pure JSON' ($r.Code -eq 0 -and $r.Parsed -and $r.Out.TrimStart().StartsWith('['))
    $live = if ($r.Parsed) { @($r.Json) } else { @() }
    $w4Tweaks = 'w4-cap-wordpad', 'w4-cap-multi', 'w4-cap-lang', 'w4-feat-ie', 'w4-feat-protected', 'w4-feat-missing', 'w4-appx-work', 'w4-appx-min', 'w4-appx-names', 'w4-appx-badprofile'
    Check 'real: every WP4 tweak has plan rows' (@($w4Tweaks | Where-Object { (Rows $live $_).Count -eq 0 }).Count -eq 0)
    $okReason = '^(|undo re-adds .*|the payload stays on disk.*|irreversible: .*|.*not present on this edition or build.*|protected target: .*|could not read .*|state is .*|no exact undo.*|managed device: .*|AppX profile .*|LTSC edition.*|nothing to remove.*|.*profile .* keeps .*|.*reinstall manifest.*|engine: .*)$'
    Check 'real: every capability / feature / appx row is a state, "not present", protected, profile or admin note (never an error)' (@($live | Where-Object { $_.type -in 'capability', 'optionalfeature', 'appx' -and $_.reason -notmatch $okReason }).Count -eq 0)
    Check 'real: capability and feature rows read a state (Installed / NotPresent / Enabled / Disabled ...) when the inventory is readable' (@($live | Where-Object { $_.type -in 'capability', 'optionalfeature' -and $_.action -in 'Change', 'InSync' -and -not $_.current }).Count -eq 0)
    Check 'real: Language.Basic and Hyper-V are protected' ((Rows $live 'w4-cap-lang')[0].reason -match 'protected target' -and (Rows $live 'w4-feat-protected')[0].reason -match 'protected target')
    Check 'real: the Store is never planned for removal' (@(Rows $live 'w4-appx-names' | Where-Object { $_.action -eq 'Change' -and $_.target -match 'WindowsStore' }).Count -eq 0)
    Check 'real: an undefined profile is a Skip with the reason' ((Rows $live 'w4-appx-badprofile')[0].action -eq 'Skip' -and (Rows $live 'w4-appx-badprofile')[0].reason -match "profile 'nope' is not defined")
    Check 'real: -List -AsJson reports os.isLtsc as a boolean' ((RunJson @('-List', '-AsJson', '-ProfilesPath', $wp4Prof) $wp4).Json.os.isLtsc -is [bool])

    Write-Host 'WP4: plan against the fake tools'
    W4Env
    $pl = W4Plan @('-AllowIrreversible')
    Check 'fake plan: exit parse ok' ($pl.Count -ge 12)
    Check 'capability WordPad: Installed -> NotPresent (Change, name resolved from the part before ~~~~)' ((Rows $pl 'w4-cap-wordpad')[0].action -eq 'Change' -and (Rows $pl 'w4-cap-wordpad')[0].current -eq 'Installed' -and (Rows $pl 'w4-cap-wordpad')[0].target -eq 'Microsoft.Windows.WordPad~~~~0.0.1.0' -and (Rows $pl 'w4-cap-wordpad')[0].desired -eq 'NotPresent')
    Check 'capability Steps Recorder: Change; legacy Media Player (NotPresent): InSync; unknown capability: Skip "not present"' ((Rows $pl 'w4-cap-multi')[0].action -eq 'Change' -and (Rows $pl 'w4-cap-multi')[1].action -eq 'InSync' -and (Rows $pl 'w4-cap-multi')[2].action -eq 'Skip' -and (Rows $pl 'w4-cap-multi')[2].reason -match 'not present on this edition or build')
    Check 'capability Language.* is protected (Skip)' ((Rows $pl 'w4-cap-lang')[0].action -eq 'Skip' -and (Rows $pl 'w4-cap-lang')[0].reason -match 'protected target: language features')
    Check 'optional feature IE: Enabled -> Disabled (Change); Hyper-V protected; unknown feature Skip' ((Rows $pl 'w4-feat-ie')[0].action -eq 'Change' -and (Rows $pl 'w4-feat-ie')[0].current -eq 'Enabled' -and (Rows $pl 'w4-feat-protected')[0].reason -match 'protected target: Hyper-V' -and (Rows $pl 'w4-feat-missing')[0].reason -match 'not present on this edition or build')
    Check 'feature reason says the payload stays (no -Remove), so undo is offline' ((Rows $pl 'w4-feat-ie')[0].reason -match 'payload stays on disk')
    Check 'capability reason says undo needs Windows Update / Features on Demand' ((Rows $pl 'w4-cap-wordpad')[0].reason -match 'Windows Update or Features on Demand')
    $wk = Rows $pl 'w4-appx-work'
    $wkc = @($wk | Where-Object action -EQ 'Change')[0]
    Check 'AppX profile test-work: one Change row; kept Paint is not in the target list; the rest of the list is' ($wkc -and $wkc.target -notmatch 'Microsoft\.Paint' -and $wkc.target -match 'Microsoft\.BingNews' -and $wkc.target -match 'Clipchamp')
    Check 'AppX profile: reason names the profile and how many it keeps, and says a manifest is saved' ($wkc.reason -match 'profile test-work keeps 1 app' -and $wkc.reason -match 'reinstall manifest')
    Check 'AppX profile: package "Not.Installed.App" is simply not matched (skipped, no failure)' ($wkc.current -notmatch 'Not.Installed.App')
    $nm = Rows $pl 'w4-appx-names'
    Check 'AppX names: Store -> protected Skip row; BingNews and ZuneMusic -> one Change row' (@($nm | Where-Object { $_.action -eq 'Skip' -and $_.reason -match 'protected target' }).Count -eq 1 -and @($nm | Where-Object { $_.action -eq 'Change' -and $_.target -match 'BingNews' }).Count -eq 1)
    Check 'AppX unknown profile: Skip with the reason' ((Rows $pl 'w4-appx-badprofile')[0].action -eq 'Skip' -and (Rows $pl 'w4-appx-badprofile')[0].reason -match "profile 'nope' is not defined")
    $fc = @($pl | Where-Object { $_.tweakId -eq 'engine-appx-framework-check' })
    Check 'engine adds one framework-check record, last (order 900, weight 2, type appxcheck, Change)' ($fc.Count -eq 1 -and $fc[0].type -eq 'appxcheck' -and $fc[0].order -eq 900 -and $fc[0].weight -eq 2 -and $fc[0].action -eq 'Change' -and $pl[-1].tweakId -eq 'engine-appx-framework-check')
    Check 'weights: capability 12, optional feature 10, AppX 20' ((Rows $pl 'w4-cap-wordpad')[0].weight -eq 12 -and (Rows $pl 'w4-feat-ie')[0].weight -eq 10 -and $wkc.weight -eq 20)
    $pl2 = W4Plan @('-AllowIrreversible', '-Only', 'w4-cap-wordpad,w4-feat-ie')
    Check 'no AppX change in the plan -> no framework-check record' (@($pl2 | Where-Object { $_.tweakId -eq 'engine-appx-framework-check' }).Count -eq 0)
    $pl3 = W4Plan @()
    Check 'without -AllowIrreversible: AppX is a Skip ("no exact undo"); capabilities and features still plan (their undo is conditional, not impossible)' ((Rows $pl3 'w4-appx-min')[0].action -eq 'Skip' -and (Rows $pl3 'w4-appx-min')[0].reason -match 'use -AllowIrreversible' -and (Rows $pl3 'w4-cap-wordpad')[0].action -eq 'Change' -and @($pl3 | Where-Object { $_.tweakId -eq 'engine-appx-framework-check' }).Count -eq 0)
    W4Env $true
    $plm = W4Plan @('-AllowIrreversible', '-Only', 'w4-appx-work')
    $kept = @($plm | Where-Object { $_.action -eq 'Skip' -and $_.reason -match 'managed device: kept by default' })
    $chg = @($plm | Where-Object { $_.tweakId -eq 'w4-appx-work' -and $_.action -eq 'Change' })[0]
    Check 'managed device: Teams and Outlook get a Skip row ("kept by default") and are not in the removal target' ($kept.Count -eq 1 -and $kept[0].target -match 'MSTeams' -and $kept[0].target -match 'OutlookForWindows' -and $chg.target -notmatch 'MSTeams|Outlook')
    W4Env $false
    $pln = W4Plan @('-AllowIrreversible', '-Only', 'w4-appx-work')
    Check 'not managed: Teams and Outlook are in the removal target' (@($pln | Where-Object { $_.tweakId -eq 'w4-appx-work' -and $_.action -eq 'Change' -and $_.target -match 'MSTeams' -and $_.target -match 'Outlook' }).Count -eq 1)
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) $wp4
    Check '-List -AsJson: pure JSON, all 10 WP4 ids listed, framework-check record not listed as a tweak' ($r.Parsed -and $r.Out.TrimStart().StartsWith('{') -and @($r.Json.tweaks).Count -eq 10)

    Write-Host 'WP4: capability and optional feature apply, re-apply and undo (fake tools)'
    W4Env
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-cap-wordpad,w4-cap-multi,w4-feat-ie')
    Check 'apply: exit 0, steps Verified' ($r.Code -eq 0 -and $r.Out -match 'Verified' -and $r.Out -notmatch 'Failed')
    Check 'apply: WordPad and Steps Recorder NotPresent, IE feature Disabled, legacy Media Player still NotPresent' ((Fk $capKeys.wordpad) -match 'NotPresent' -and (Fk $capKeys.steps) -match 'NotPresent' -and (Fk $capKeys.ie) -match 'Disabled' -and (Fk $capKeys.wmp) -match 'NotPresent')
    $snap = Last-Snapshot
    $cs = @($snap.steps | Where-Object { $_.type -eq 'capability' })
    Check 'snapshot: capability steps record state Installed and the full name' ($cs.Count -eq 2 -and $cs[0].before.state -eq 'Installed' -and $cs[0].name -match '~~~~' -and @($snap.steps | Where-Object { $_.type -eq 'optionalfeature' })[0].before.state -eq 'Enabled')
    $r = W4Apply @('-Only', 'w4-cap-wordpad,w4-cap-multi,w4-feat-ie')
    Check 're-apply is idempotent ("Nothing to change")' ($r.Code -eq 0 -and $r.Out -match 'Nothing to change')
    $r = W4Undo
    Check 'undo: exit 0; WordPad and Steps Recorder Installed again, IE feature Enabled again' ($r.Code -eq 0 -and (Fk $capKeys.wordpad) -match 'Installed' -and (Fk $capKeys.steps) -match 'Installed' -and (Fk $capKeys.ie) -match 'Enabled')
    Check 'undo: a capability that was already NotPresent is left alone' ((Fk $capKeys.wmp) -match 'NotPresent')
    # failing capability removal follows the error policy and does not look like success
    W4Env
    Remove-StateDir
    New-TestEnv $false 'Professional' 26200 'Desktop' @{ failSteps = @('w4-cap-wordpad|*') } $w4Seed
    $r = W4Apply @('-Only', 'w4-cap-wordpad,w4-feat-ie')
    Check 'injected capability failure: exit 2, the capability is untouched, the feature step still ran' ($r.Code -eq 2 -and (Fk $capKeys.wordpad) -match 'Installed' -and (Fk $capKeys.ie) -match 'Disabled')
    $r = W4Undo
    Check 'undo after a failed step reverts only what ran' ($r.Code -eq 0 -and (Fk $capKeys.ie) -match 'Enabled')
    # undo of a capability when the source is not reachable
    W4Env
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-cap-wordpad,w4-feat-ie')
    New-TestEnv $false 'Professional' 26200 'Desktop' @{} @{ 'capability:microsoft.windows.wordpad~~~~0.0.1.0' = (Fk $capKeys.wordpad); 'feature:internet-explorer-optional-amd64' = (Fk $capKeys.ie); 'source:blocked' = 'true' }
    $r = W4Undo
    Check 'undo with no reachable source: capability reported Failed with an actionable message (exit 2); the feature still comes back offline' ($r.Code -eq 2 -and $r.Out -match 'Failed' -and $r.Out -match 'Features on Demand' -and (Fk $capKeys.wordpad) -match 'NotPresent' -and (Fk $capKeys.ie) -match 'Enabled')

    Write-Host 'WP4: update-source gate (WSUS without a repair source makes a capability removal irreversible)'
    foreach ($case in @(@{ n = 'WSUS, no repair source'; t = @{ 'wusource:wsus' = '1' }; blocked = $true }, @{ n = 'WSUS with RepairContentServerSource=2'; t = @{ 'wusource:wsus' = '1'; 'wusource:repair' = '2' }; blocked = $false }, @{ n = 'WSUS with LocalSourcePath'; t = @{ 'wusource:wsus' = '1'; 'wusource:local' = 'D:\sxs' }; blocked = $false }, @{ n = 'no WSUS'; t = @{ 'wusource:wsus' = '0' }; blocked = $false })) {
        W4Env $false 'Professional' $case.t
        $a = (Rows (W4Plan @('-Only', 'w4-cap-wordpad,w4-feat-ie')) 'w4-cap-wordpad')[0]
        $b = (Rows (W4Plan @('-Only', 'w4-cap-wordpad,w4-feat-ie', '-AllowIrreversible')) 'w4-cap-wordpad')[0]
        if ($case.blocked) { Check "$($case.n): Skip without -AllowIrreversible ('no reliable undo'), Change with it ('irreversible')" ($a.action -eq 'Skip' -and $a.reason -match 'no reliable undo' -and $b.action -eq 'Change' -and $b.reason -match 'irreversible: WSUS') }
        else { Check "$($case.n): plain Change, no gate" ($a.action -eq 'Change' -and $b.action -eq 'Change' -and $a.reason -notmatch 'irreversible') }
    }
    W4Env $false 'Professional' @{ 'wusource:wsus' = '1' }
    Check 'the optional feature is never gated by the source (its payload stays on disk)' ((Rows (W4Plan @('-Only', 'w4-feat-ie')) 'w4-feat-ie')[0].action -eq 'Change')

    Write-Host 'WP4: AppX removal ladder, reinstall manifest, framework check'
    W4Env
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    Check 'apply profile test-min: exit 0, BingNews and Paint gone for the user and deprovisioned' ($r.Code -eq 0 -and -not (Fk 'appx:microsoft.bingnews') -and -not (Fk 'appx:microsoft.paint'))
    Check 'frameworks untouched' ((Fk 'appx:microsoft.vclibs.140.00') -match 'UF' -and (Fk 'appx:microsoft.ui.xaml.2.8') -match 'UF')
    $snap = Last-Snapshot
    $ax = @($snap.steps | Where-Object { $_.type -eq 'appx' })[0]
    $mf = @($ax.before.manifest)
    Check 'snapshot (written before the removal): reinstall manifest with name, full name, family, version' ($mf.Count -eq 2 -and $mf[0].packageFullName -match '^Microsoft\.BingNews_4\.55\.0\.0_x64__8wekyb3d8bbwe$' -and $mf[0].packageFamilyName -eq 'Microsoft.BingNews_8wekyb3d8bbwe' -and $mf[0].version -eq '4.55.0.0')
    Check 'manifest: known Store id -> "winget install --id 9WZDNCRFHVFW -s msstore"; unknown -> winget search hint, no invented id' ($mf[0].storeProductId -eq '9WZDNCRFHVFW' -and $mf[0].command -match 'winget install --id 9WZDNCRFHVFW -s msstore' -and $null -eq $mf[1].storeProductId -and $mf[1].command -match 'winget search')
    Check 'manifest: Store available on a non-LTSC edition' ($ax.before.storeAvailable -eq $true -and $ax.before.profile -eq 'test-min')
    $ck = @($snap.steps | Where-Object { $_.type -eq 'appxcheck' })
    Check 'framework check ran last and passed (Verified), nothing missing' ($ck.Count -eq 1 -and $ck[0].result -eq 'Verified' -and @($ck[0].repair.missing).Count -eq 0 -and $ck[0].repair.checked -ge 2)
    $r = W4Undo
    Check 'undo: AppX cannot be reverted by the engine (exit 2) and prints the reinstall command; nothing is downloaded' ($r.Code -eq 2 -and $r.Out -match 'winget install --id 9WZDNCRFHVFW' -and $r.Out -match 'cannot be undone automatically' -and -not (Fk 'appx:microsoft.bingnews'))
    Check 'undo: the framework-check record is not listed as a revert' ($r.Out -notmatch 'engine-appx-framework-check')

    W4Env $false 'Professional' @{ 'appx:failallusers' = 'true' }
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    Check 'ladder: removal for all users fails -> retried for the current user, then deprovisioned: exit 0, both gone' ($r.Code -eq 0 -and -not (Fk 'appx:microsoft.bingnews') -and -not (Fk 'appx:microsoft.paint'))
    W4Env $false 'Professional' @{ 'appx:failremove:microsoft.paint' = 'true' }
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    $snap = Last-Snapshot
    $ax = @($snap.steps | Where-Object { $_.type -eq 'appx' })[0]
    Check 'ladder: a package that cannot be removed is collected and reported (step Failed, exit 2, error printed, nothing scheduled)' ($r.Code -eq 2 -and $ax.result -eq 'Failed' -and @($ax.failures).Count -ge 1 -and $r.Out -match 'FAILED w4-appx-min .*could not remove')
    Check 'a failed step still has its manifest in the snapshot' (@($ax.before.manifest).Count -eq 2)
    W4Env $false 'Professional' @{ 'appx:breaks:microsoft.paint' = 'Microsoft.VCLibs.140.00|O' }
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    $ck = @((Last-Snapshot).steps | Where-Object { $_.type -eq 'appxcheck' })[0]
    Check 'framework check: a framework left registered only for other users is re-registered (Verified, exit 0)' ($r.Code -eq 0 -and $ck.result -eq 'Verified' -and @($ck.repair.reRegistered) -contains 'Microsoft.VCLibs.140.00' -and (Fk 'appx:microsoft.vclibs.140.00') -match 'U')
    W4Env $false 'Professional' @{ 'appx:breaks:microsoft.paint' = 'Microsoft.VCLibs.140.00|gone' }
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    $ck = @((Last-Snapshot).steps | Where-Object { $_.type -eq 'appxcheck' })[0]
    Check 'framework check: a framework that is gone -> Failed (exit 2) with the Store product ids needed to restore it' ($r.Code -eq 2 -and $ck.result -eq 'Failed' -and @($ck.repair.missing) -contains 'Microsoft.VCLibs.140.00' -and $r.Out -match '9NBLGGH3FRZM' -and $r.Out -match '9NBLGGH4RV3K' -and $r.Out -match 'FAILED engine-appx-framework-check')
    W4Env $false 'Professional' @{ 'appx:breaks:microsoft.paint' = 'Microsoft.UI.Xaml.2.8|gone' }
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    Check 'framework check: a missing framework without a known Store id still fails, with a generic restore hint' ($r.Code -eq 2 -and $r.Out -match 'Microsoft\.UI\.Xaml\.2\.8' -and $r.Out -match 'Microsoft Store or winget')

    Write-Host 'WP4: LTSC-aware handling'
    W4Env $false 'EnterpriseS' @{ 'capability:microsoft.windows.wordpad~~~~0.0.1.0' = ''; 'appx:microsoft.bingnews' = '' }
    $r = RunJson @('-List', '-AsJson', '-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) $wp4
    Check '-List -AsJson: os.isLtsc is true for EnterpriseS and false for Professional' ($r.Parsed -and $r.Json.os.isLtsc -eq $true)
    W4Env $false 'IoTEnterpriseS' @{ 'capability:microsoft.windows.wordpad~~~~0.0.1.0' = ''; 'appx:microsoft.bingnews' = '' }
    $pl = W4Plan @('-AllowIrreversible', '-Only', 'w4-cap-wordpad,w4-appx-min')
    Check 'LTSC: a capability that is not part of the edition is skipped with an LTSC note' ((Rows $pl 'w4-cap-wordpad')[0].action -eq 'Skip' -and (Rows $pl 'w4-cap-wordpad')[0].reason -match 'LTSC edition')
    $lt = @(Rows $pl 'w4-appx-min' | Where-Object action -EQ 'Change')[0]
    Check 'LTSC: packages that are not installed are skipped (BingNews absent), the rest is planned' ($lt -and $lt.current -notmatch 'BingNews' -and $lt.current -match 'Microsoft.Paint' -and $lt.reason -match 'LTSC')
    Remove-StateDir
    $r = W4Apply @('-Only', 'w4-appx-min', '-AllowIrreversible')
    $ax = @((Last-Snapshot).steps | Where-Object { $_.type -eq 'appx' })[0]
    Check 'LTSC: the reinstall manifest says there is no Store and does not offer winget msstore' ($r.Code -eq 0 -and $ax.before.storeAvailable -eq $false -and @($ax.before.manifest)[0].command -match 'no Microsoft Store on this edition' -and @($ax.before.manifest)[0].command -notmatch 'msstore')
    Check 'LTSC: the snapshot records the edition' ((Last-Snapshot).os.EditionId -eq 'IoTEnterpriseS' -and (Last-Snapshot).os.IsLtsc -eq $true)
    W4Env $false 'Professional' @{}
    $pl = W4Plan @('-AllowIrreversible', '-Only', 'w4-appx-min')
    Check 'Professional: no LTSC wording in the AppX plan row' (@(Rows $pl 'w4-appx-min' | Where-Object { $_.reason -match 'LTSC' }).Count -eq 0)

    Write-Host 'WP4: lint'
    $badW4 = New-TempFile @'
{ "schemaVersion": 2, "tweaks": [
  { "id": "l-cap-safe", "category": "o", "implementation": { "type": "capability", "name": "App.StepsRecorder" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l-feat-safe", "category": "o", "implementation": { "type": "optionalfeature", "name": "Internet-Explorer-Optional-amd64" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l-cap-lang", "category": "o", "implementation": { "type": "capability", "name": "Language.Speech" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l-feat-hv", "category": "o", "implementation": { "type": "optionalfeature", "name": "VirtualMachinePlatform" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l-cap-wild", "category": "o", "implementation": { "type": "capability", "name": "Language.*" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" },
  { "id": "l-cap-noname", "category": "o", "implementation": { "type": "capability" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" },
  { "id": "l-feat-wild", "category": "o", "implementation": { "type": "optionalfeature", "name": "Windows-*" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" },
  { "id": "l-appx-none", "category": "o", "implementation": { "type": "appx" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" },
  { "id": "l-appx-badprof", "category": "o", "implementation": { "type": "appx", "profile": "nope" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" },
  { "id": "l-appx-goodprof", "category": "o", "implementation": { "type": "appx", "profile": "test-work" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" }
] }
'@
    $r = RunJson @('-Lint', '-AsJson', '-ProfilesPath', $wp4Prof) $badW4
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: capability and optional feature in the safe preset are errors' ((HasF 'l-cap-safe' 'safe-preset') -and (HasF 'l-feat-safe' 'safe-preset'))
    Check 'lint: a protected capability (Language.*) and a protected feature (VirtualMachinePlatform) in safe are errors' ((HasF 'l-cap-lang' 'protected-target') -and (HasF 'l-feat-hv' 'protected-target'))
    Check 'lint: wildcard capability / feature names and a missing name are errors' ((HasF 'l-cap-wild' 'capability') -and (HasF 'l-cap-noname' 'capability') -and (HasF 'l-feat-wild' 'optionalfeature'))
    Check 'lint: an appx step with neither names nor profile, and one with an undefined profile, are errors; a defined profile is clean' ((HasF 'l-appx-none' 'appx') -and (HasF 'l-appx-badprof' 'appx') -and -not (HasF 'l-appx-goodprof' 'appx'))
    $badProf = New-TempFile @'
{ "schemaVersion": 1, "managedKeep": [ "MS*" ],
  "packages": { "Some.App": { "display": "x", "storeId": "not-an-id" } },
  "profiles": {
    "p-protected": { "description": "d", "keep": [ "Keep*" ], "remove": [ "Microsoft.WindowsStore", "Microsoft.VCLibs.140.00", "Bad Name" ] },
    "p-empty": { "description": "d", "keep": [], "remove": [] },
    "p-nodesc": { "keep": [], "remove": [ "A.B" ] }
  },
  "optionProfiles": {
    "work-managed": { "description": "d", "appxProfile": null, "tweakIds": [ "l-cap-wild" ] },
    "other": { "description": "d", "appxProfile": "missing", "tweakIds": [ "ghost" ] }
  } }
'@
    $r = RunJson @('-Lint', '-AsJson', '-ProfilesPath', $badProf) $badW4
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: profile removing a protected package (Store, VCLibs) is an error' (@($fi | Where-Object { $_.tweakId -eq 'profile:p-protected' -and $_.rule -eq 'protected-target' }).Count -eq 2)
    Check 'lint: wildcard keep entry, odd package name, empty remove list and missing description are errors' ((HasF 'profile:p-protected' 'profiles') -and (HasF 'profile:p-empty' 'profiles') -and (HasF 'profile:p-nodesc' 'profiles'))
    Check 'lint: bad Store id, wildcard managedKeep are errors' ((HasF 'package:Some.App' 'profiles') -and @($fi | Where-Object { $_.rule -eq 'profiles' -and $_.message -match 'managedKeep' }).Count -eq 1)
    Check 'lint: option profile with an unknown appxProfile is an error, an unknown tweak id a warning, a non-safe tweak in work-managed an error' ((HasF 'option-profile:other' 'profiles') -and (HasF 'option-profile:other' 'profiles' 'warning') -and (HasF 'option-profile:work-managed' 'profiles'))
    $r = RunJson @('-Lint', '-AsJson', '-ProfilesPath', (Join-Path $PSScriptRoot 'no-such-profiles.json')) $wp4
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: a catalog that uses a profile while the profiles file is missing is an error (not a crash)' ($r.Parsed -and @($fi | Where-Object { $_.rule -eq 'appx' -and $_.message -match 'missing or unreadable' }).Count -ge 1)
    $fj = LintMutant3 "'capability' {`n            if (`$Rec.before.state -eq 'Installed')" "'capabilityx' {`n            if (`$Rec.before.state -eq 'Installed')"
    Check 'lint: a mutating step type (capability) without an Undo-Step branch is an error' ($fj -and @($fj.findings | Where-Object { $_.rule -eq 'handler' -and $_.message -match "'capability'.*Undo-Step" }).Count -eq 1)
    $engineSrc4 = Get-Content -LiteralPath $engine -Raw
    Check 'engine source: Disable-WindowsOptionalFeature is never called with -Remove (the payload stays, undo is offline)' ($engineSrc4 -notmatch 'Disable-WindowsOptionalFeature[^\r\n]*-Remove\b')
    Check 'engine source: no RunOnce, scheduled task or winget execution anywhere in the engine' (@(($engineSrc4 -split "`n") | Where-Object { $_ -match 'RunOnce' -and $_ -notmatch '^\s*#' }).Count -eq 0 -and $engineSrc4 -notmatch 'Register-ScheduledTask|schtasks' -and $engineSrc4 -notmatch '&\s*winget' -and $engineSrc4 -notmatch "Invoke-Tool\s+'winget")

    Write-Host 'WP4: real catalog and profiles file wiring'
    $rc4 = Get-Content (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json
    $pf4 = Get-Content (Join-Path $PSScriptRoot '..\appx-profiles.json') -Raw | ConvertFrom-Json
    $legacy = @($rc4.tweaks | Where-Object id -EQ 'comp-optional-features-legacy')[0]
    $lsteps = @($legacy.implementation.steps)
    Check 'real catalog: comp-optional-features-legacy is explicit capability / optionalfeature steps (WordPad, Steps Recorder, Math Recognizer, legacy Media Player, IE)' ($legacy.implementation.type -eq 'multi' -and @($lsteps | Where-Object type -EQ 'capability').Count -eq 4 -and @($lsteps | Where-Object type -EQ 'optionalfeature').Count -eq 2 -and ($lsteps.name -contains 'Microsoft.Windows.WordPad') -and ($lsteps.name -contains 'App.StepsRecorder') -and ($lsteps.name -contains 'MathRecognizer') -and ($lsteps.name -contains 'Internet-Explorer-Optional-amd64') -and $legacy.preset -eq 'balanced')
    Check 'real catalog: no language feature, Defender or Hyper-V step in it' (-not ($lsteps.name -match '^Language\.|Defender|Hyper-V'))
    Check 'real catalog: three AppX profile tweaks, balanced, never in safe, each uses a profile defined in appx-profiles.json' (@('keep-work', 'keep-personal', 'minimal' | Where-Object { $n = $_; $t = @($rc4.tweaks | Where-Object id -EQ "appx-profile-$n")[0]; $t -and $t.preset -eq 'balanced' -and $t.implementation.steps[0].profile -eq $n -and $null -ne $pf4.profiles.PSObject.Properties[$n] }).Count -eq 3)
    Check 'real catalog: no capability / optionalfeature / appx step in the safe preset' (@($rc4.tweaks | Where-Object { $_.preset -eq 'safe' -and (($_.implementation | ConvertTo-Json -Depth 6) -match '"type":\s*"(capability|optionalfeature|appx)"') }).Count -eq 0)
    Check 'real profiles file: keep-work keeps Teams, Outlook, Terminal, Paint, Snipping Tool, Camera and Calculator' (@('MSTeams', 'Microsoft.OutlookForWindows', 'Microsoft.WindowsTerminal', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.WindowsCamera', 'Microsoft.WindowsCalculator' | Where-Object { $pf4.profiles.'keep-work'.keep -notcontains $_ }).Count -eq 0)
    Check 'real profiles file: no profile removes a protected package (Store, App Installer, VCLibs, UI.Xaml, WebView2, SecHealthUI, ...)' (@($pf4.profiles.PSObject.Properties | ForEach-Object { $_.Value.remove } | Where-Object { $_ -match '^Microsoft\.(WindowsStore|StorePurchaseApp|DesktopAppInstaller|VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime|WebView2|SecHealthUI)' }).Count -eq 0)
    Check 'real profiles file: every Store product id is a 12-character id; VCLibs framework hint carries the two ReviOS ids' (@($pf4.packages.PSObject.Properties | Where-Object { $_.Value.storeId -and $_.Value.storeId -notmatch '^[A-Z0-9]{12}$' }).Count -eq 0 -and (@($pf4.frameworks | Where-Object pattern -EQ 'Microsoft.VCLibs*')[0].storeIds -contains '9NBLGGH3FRZM') -and (@($pf4.frameworks | Where-Object pattern -EQ 'Microsoft.VCLibs*')[0].storeIds -contains '9NBLGGH4RV3K'))
    $op = $pf4.optionProfiles
    $allIds = @($rc4.tweaks.id)
    Check 'real profiles file: four option profiles (work-managed, personal-desktop, personal-laptop, gaming-desktop), every tweak id exists in the catalog' (@('work-managed', 'personal-desktop', 'personal-laptop', 'gaming-desktop' | Where-Object { $null -eq $op.PSObject.Properties[$_] }).Count -eq 0 -and @($op.PSObject.Properties | ForEach-Object { $_.Value.tweakIds } | Where-Object { $allIds -notcontains $_ }).Count -eq 0)
    Check 'real profiles file: work-managed has no AppX profile and no tweaks; the laptop profile has no hibernate-off or power plan; none contains a never-default id' ($null -eq $op.'work-managed'.appxProfile -and @($op.'work-managed'.tweakIds).Count -eq 0 -and $op.'personal-laptop'.tweakIds -notcontains 'pwr-hibernate-off' -and $op.'personal-laptop'.tweakIds -notcontains 'pwr-ultra-performance-plan' -and @($op.PSObject.Properties | ForEach-Object { $_.Value.tweakIds } | Where-Object { $i = $_; @($rc4.tweaks | Where-Object { $_.id -eq $i -and $_.preset -eq 'never-default' }).Count }).Count -eq 0)
    Check 'real catalog: catalogVersion bumped for WP4' ($rc4.catalogVersion -ne '2026.10.17.2')
    $realWp4After = Get-RealWp4State
    if ($realWp4After -ne $realWp4Before) { Compare-Object ($realWp4Before -split "`n") ($realWp4After -split "`n") | ForEach-Object { Write-Host "    differs: $($_.SideIndicator) $($_.InputObject)" } }
    Check 'real system: capabilities, optional features, AppX package names and provisioned package names never changed during the WP4 tests' ($realWp4After -eq $realWp4Before)

    # ======================= WP5: per-tweak revert, drift detection, re-apply =======================
    # Registry steps use the throwaway key HKCU:\Software\DebloatKitTest\WP5; the native, capability, optional feature and AppX
    # steps run against the fake tools in the -TestEnvironment file. Drift is read-only; -Reapply and -Revert go through the
    # normal apply / undo path (the real system is only read).
    $wp5 = Join-Path $PSScriptRoot 'test-catalog-wp5.json'
    $pdBefore5 = Test-Path (Join-Path $env:ProgramData 'DebloatKit')
    $w5 = "$key\WP5"
    function W5Reset { if (Test-Path $w5) { Remove-Item $w5 -Recurse -Force }; New-Item $w5 -Force | Out-Null; New-ItemProperty $w5 -Name A -PropertyType DWord -Value 5 | Out-Null; Remove-StateDir }
    function W5Env([int]$Build = 26100) { $t = @{}; foreach ($k in $w4Seed.Keys) { $t[$k] = $w4Seed[$k] }; New-TestEnv $false 'Professional' $Build 'Desktop' @{} $t }
    function W5Edit([scriptblock]$Fn) { $o = Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json; & $Fn $o; $o | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $envFile -Encoding UTF8 }
    function W5Fake([string]$Name, $Value) { W5Edit ({ param($o) $o.tools | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }.GetNewClosure()) }
    function W5Run([string[]]$More) { Run (@('-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) + $More) $wp5 }
    function W5Json([string[]]$More) { RunJson (@('-TestEnvironment', $envFile, '-ProfilesPath', $wp4Prof) + $More) $wp5 }
    # two applies in the same second would share a run id (and a snapshot file name)
    function W5Apply([string[]]$More) { Start-Sleep -Milliseconds 1100; W5Run (@('-NoRestorePoint', '-Force', '-SkipPreflight') + $More) }
    function StateListing { (@(Get-ChildItem $stateDir -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Length)" })) -join ';' }
    function RevMarks([string]$Id) {
        # how many step records of the tweak carry the reverted marker, across every snapshot file (also *.reverted.json)
        $n = 0
        foreach ($f in @(Get-ChildItem $stateDir -Filter 'state-*.json' -ErrorAction SilentlyContinue)) {
            $n += @((Get-Content $f.FullName -Raw | ConvertFrom-Json).steps | Where-Object { $_.tweakId -eq $Id -and $_.PSObject.Properties['reverted'] -and $_.reverted -eq $true }).Count
        }
        $n
    }
    function DriftTweak($Doc, [string]$Id) { @($Doc.tweaks) | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

    Write-Host 'WP5: -Revert undoes chosen tweaks only and marks their steps reverted in the snapshot'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-b,w5-multi,perf-ntfs-lastaccess')
    Check 'setup: apply exit 0; A=1, B=2, new key C=3, D=four, fake last-access 1' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and (Val $w5 'B') -eq 2 -and (Val "$w5\Deep" 'C') -eq 3 -and (Val $w5 'D') -eq 'four' -and (Get-Fake 'fsutil:disablelastaccess') -eq '1')
    $listing = StateListing
    $r = W5Run @('-Revert', 'w5-a', '-WhatIf')
    Check '-Revert -WhatIf: exit 0, WouldRevert, nothing changed, nothing written to the state folder' ($r.Code -eq 0 -and $r.Out -match 'WouldRevert' -and (Val $w5 'A') -eq 1 -and (StateListing) -eq $listing)
    $r = W5Json @('-Revert', 'w5-a', '-WhatIf', '-AsJson')
    Check '-Revert -WhatIf -AsJson: pure JSON, mode revert, dryRun, one WouldRevert result that restores 5' ($r.Parsed -and $r.Out.TrimStart().StartsWith('{') -and $r.Json.mode -eq 'revert' -and $r.Json.dryRun -eq $true -and @($r.Json.results).Count -eq 1 -and $r.Json.results[0].result -eq 'WouldRevert' -and $r.Json.results[0].restoredTo -match '^5' -and (StateListing) -eq $listing)
    $r = W5Run @('-Revert', 'w5-a')
    Check '-Revert w5-a: exit 0, A restored to 5' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5 -and $r.Out -match 'Reverted')
    Check 'other tweaks untouched by the revert (B, C, D, last-access)' ((Val $w5 'B') -eq 2 -and (Val "$w5\Deep" 'C') -eq 3 -and (Val $w5 'D') -eq 'four' -and (Get-Fake 'fsutil:disablelastaccess') -eq '1')
    Check 'the step of w5-a is marked reverted inside the snapshot; the file is kept (other steps are still applied)' ((RevMarks 'w5-a') -eq 1 -and (RevMarks 'w5-b') -eq 0 -and @(Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json').Count -eq 1 -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 0)
    Check 'the revert is logged (revert-*.log.jsonl)' (@(Get-ChildItem $stateDir -Filter 'revert-*.log.jsonl').Count -eq 1)
    $r = W5Run @('-Revert', 'w5-a')
    Check 'reverting the same tweak again: refused, exit 1, nothing to revert' ($r.Code -eq 1 -and $r.Out -match 'Nothing to revert')
    $r = W5Run @('-Revert', 'no-such-tweak')
    Check 'reverting an id that was never applied: refused, exit 1' ($r.Code -eq 1 -and $r.Out -match 'Nothing to revert')
    $r = W5Json @('-Revert', 'w5-b,w5-multi,w5-a', '-AsJson')
    Check '-Revert a,b -AsJson: pure JSON; B and both multi steps reverted, w5-a (already reverted) reported as not found' ($r.Parsed -and $r.Json.mode -eq 'revert' -and $r.Json.dryRun -eq $false -and $r.Json.summary.reverted -eq 3 -and @($r.Json.notFound) -contains 'w5-a' -and $null -eq (Val $w5 'B') -and $null -eq (Val $w5 'D'))
    Check 'a key the run created is removed again by the revert (exact undo)' (-not (Test-Path "$w5\Deep") -and (Val $w5 'A') -eq 5 -and (Get-Fake 'fsutil:disablelastaccess') -eq '1')
    Check 'the snapshot is not renamed while the native step is still applied' (@(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 0)
    New-ItemProperty $w5 -Name A -PropertyType DWord -Value 9 -Force | Out-Null
    $r = Run @('-Undo', 'latest', '-TestEnvironment', $envFile) $wp5
    Check '-Undo latest afterwards skips steps that were reverted per tweak: only the last-access step is undone, A (changed by hand to 9) is left alone' ($r.Code -eq 0 -and $r.Out -match 'Reverting 1 step' -and (Get-Fake 'fsutil:disablelastaccess') -eq '2' -and (Val $w5 'A') -eq 9)
    Check 'the fully undone snapshot is renamed *.reverted.json' (@(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 1)

    Write-Host 'WP5: -Revert across runs (re-apply after the tweak was reverted or changed back)'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a')
    $r = W5Run @('-Revert', 'w5-a')
    Check 'apply, revert: A back to 5 and the snapshot (all steps reverted) is renamed *.reverted.json' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5 -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 1)
    $r = W5Apply @('-Only', 'w5-a')
    Check 're-apply after a revert: a new snapshot, A=1 again' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and @(Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json').Count -eq 1)
    $r = W5Run @('-Revert', 'w5-a')
    Check 'revert after the re-apply restores 5 from the new snapshot only (the old, reverted one is not used)' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5 -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 2)
    # a target changed by two unreverted runs: the OLDEST before-state wins
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a')
    New-ItemProperty $w5 -Name A -PropertyType DWord -Value 7 -Force | Out-Null
    $r = W5Apply @('-Only', 'w5-a')
    Check 'second run over a changed-back value: snapshot 2 has before = 7' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and @((Last-Snapshot).steps)[0].before.value -eq 7)
    $r = W5Json @('-Revert', 'w5-a', '-AsJson')
    Check 'revert with two unreverted runs for the target: restores the value from before the FIRST run (5, not 7), one target, two runs marked' ($r.Parsed -and $r.Json.summary.reverted -eq 1 -and $r.Json.results[0].runs -eq 2 -and (Val $w5 'A') -eq 5 -and (RevMarks 'w5-a') -eq 2)
    # several tweaks, reverse order
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-b')
    $r = W5Run @('-Revert', 'w5-b,w5-a')
    Check 'reverting every tweak of a snapshot renames it *.reverted.json' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5 -and $null -eq (Val $w5 'B') -and @(Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json').Count -eq 0)
    $r = W5Run @('-Undo', 'latest')
    Check '-Undo latest has nothing left after that' ($r.Code -ne 0 -and $r.Out -match 'No snapshot')

    Write-Host 'WP5: -Revert safety (SID mismatch, AppX, managed device)'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-appx', '-AllowIrreversible')
    Check 'setup: apply with AppX removal, exit 0' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and -not (Get-Fake 'appx:microsoft.bingnews'))
    $r = W5Run @('-Revert', 'w5-a', '-ExpectedSid', 'S-1-5-18-0-0')
    Check '-Revert as a different user than the GUI user: refused before changing anything' ($r.Code -eq 1 -and $r.Out -match 'different user' -and (Val $w5 'A') -eq 1 -and (RevMarks 'w5-a') -eq 0)
    $r = W5Json @('-Revert', 'w5-appx', '-AsJson')
    Check 'AppX is never reverted: NotRevertible, exit 2, reinstall hint, not marked reverted, nothing reinstalled' ($r.Code -eq 2 -and $r.Parsed -and $r.Json.results[0].result -eq 'NotRevertible' -and $r.Json.results[0].error -match 'cannot be undone automatically' -and (RevMarks 'w5-appx') -eq 0 -and -not (Get-Fake 'appx:microsoft.bingnews'))
    $r = W5Json @('-Revert', 'w5-appx', '-WhatIf', '-AsJson')
    Check '-Revert -WhatIf for AppX already says NotRevertible' ($r.Parsed -and $r.Json.results[0].result -eq 'NotRevertible' -and $r.Json.summary.wouldRevert -eq 0)
    W5Edit { param($o) $o.managed = $true }
    $r = W5Run @('-Revert', 'w5-a')
    Check 'on a managed device a revert is not gated (like -Undo, reverting must stay possible)' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5)
    $r = W5Run @('-Revert', 'w5-a', '-Drift')
    Check '-Revert and -Drift cannot be combined' ($r.Code -ne 0)

    Write-Host 'WP5: -Drift is read-only and compares the live state with what was applied'
    W5Reset; W5Env 26100
    $r = W5Apply @('-Only', 'w5-a,w5-b,w5-na,perf-ntfs-lastaccess,w5-cap,w5-feat,w5-appx', '-AllowIrreversible')
    Check 'setup: seven tweaks applied on build 26100 (registry, native, capability, optional feature, AppX)' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and (Val $w5 'E') -eq 5 -and (Get-Fake 'fsutil:disablelastaccess') -eq '1' -and (Get-Fake $capKeys.wordpad) -match 'NotPresent' -and (Get-Fake $capKeys.ie) -match 'Disabled' -and -not (Get-Fake 'appx:microsoft.bingnews'))
    Check 'snapshot records the build the tweaks were applied on' ((Last-Snapshot).os.BuildFull -eq '26100.1')
    $listing = StateListing
    $r = W5Json @('-Drift', '-AsJson')
    $dr = $r.Json
    Check '-Drift -AsJson (nothing changed yet): pure JSON, 7 tweaks, none drifted, build unchanged, no banner' ($r.Code -eq 0 -and $r.Parsed -and $r.Out.TrimStart().StartsWith('{') -and $dr.mode -eq 'drift' -and $dr.summary.tweaks -eq 7 -and $dr.summary.drifted -eq 0 -and $dr.summary.inSync -eq 7 -and $dr.buildChanged -eq $false -and $dr.banner -eq '' -and $dr.snapshots -eq 1)
    $r = W5Run @('-Drift')
    Check '-Drift (text): exit 0 and says nothing has drifted' ($r.Code -eq 0 -and $r.Out -match 'Nothing has drifted')
    # a feature update changes the build and Windows reverts things
    New-ItemProperty $w5 -Name A -PropertyType DWord -Value 0 -Force | Out-Null
    Remove-ItemProperty $w5 -Name B
    New-ItemProperty $w5 -Name E -PropertyType DWord -Value 0 -Force | Out-Null
    W5Edit { param($o) $o.os.build = 26200 }
    W5Fake 'fsutil:disablelastaccess' '2'
    W5Fake $capKeys.wordpad 'Microsoft.Windows.WordPad~~~~0.0.1.0|Installed'
    W5Fake 'appx:microsoft.bingnews' 'Microsoft.BingNews;4.55.0.0;8wekyb3d8bbwe;UP'
    $r = W5Json @('-Drift', '-AsJson')
    $dr = $r.Json
    Check '-Drift after a feature update: 6 of 7 tweaks drifted, only the optional feature is still in effect' ($r.Code -eq 0 -and $r.Parsed -and $dr.summary.drifted -eq 6 -and $dr.summary.inSync -eq 1 -and (DriftTweak $dr 'w5-feat').status -eq 'InSync' -and @('w5-a', 'w5-b', 'w5-na', 'perf-ntfs-lastaccess', 'w5-cap', 'w5-appx' | Where-Object { (DriftTweak $dr $_).status -ne 'Drifted' }).Count -eq 0)
    Check 'drift ties the revert to the Windows build: applied on 26100.1, now 26200.1, banner says so' ($dr.buildChanged -eq $true -and @($dr.appliedBuilds) -contains '26100.1' -and $dr.os.buildFull -eq '26200.1' -and $dr.banner -match 'Windows reverted 6 tweak' -and $dr.banner -match '26100\.1' -and $dr.banner -match '26200\.1' -and (DriftTweak $dr 'w5-a').buildChanged -eq $true)
    $sa = @((DriftTweak $dr 'w5-a').steps)[0]; $sb = @((DriftTweak $dr 'w5-b').steps)[0]; $sn = @((DriftTweak $dr 'perf-ntfs-lastaccess').steps)[0]; $sc = @((DriftTweak $dr 'w5-cap').steps)[0]; $sx = @((DriftTweak $dr 'w5-appx').steps)[0]
    Check 'step detail: registry now/desired, removed value shows <absent>, native 2 vs 1, capability Installed, AppX package back' ($sa.current -eq '0 (DWord)' -and $sa.desired -eq '1 (DWord)' -and $sa.state -eq 'Drifted' -and $sb.current -eq '<absent>' -and $sn.current -eq '2' -and $sn.desired -eq '1' -and $sc.current -eq 'Installed' -and $sx.current -match 'Microsoft\.BingNews' -and $sa.appliedBuild -eq '26100.1')
    Check 'appliesTo is compared with the new build: w5-na (max build 26100) is flagged not applicable, the others are not' ((DriftTweak $dr 'w5-na').notApplicable -match 'only up to build 26100' -and (DriftTweak $dr 'w5-a').notApplicable -eq '')
    Check '-Drift changed nothing: values as Windows left them, state folder untouched' ((Val $w5 'A') -eq 0 -and $null -eq (Val $w5 'B') -and (Get-Fake 'fsutil:disablelastaccess') -eq '2' -and (StateListing) -eq $listing)
    $r = W5Run @('-Drift')
    Check '-Drift (text): lists the drifted steps with wanted/now, the build change and how to re-apply; exit 0' ($r.Code -eq 0 -and $r.Out -match 'w5-a' -and $r.Out -match 'Drifted' -and $r.Out -match '26100\.1' -and $r.Out -match '26200\.1' -and $r.Out -match 'Reapply')
    $r = W5Json @('-Drift', '-AsJson', '-Only', 'w5-a,w5-feat')
    Check '-Drift -Only limits the report to those tweaks' ($r.Parsed -and $r.Json.summary.tweaks -eq 2 -and $r.Json.summary.drifted -eq 1)
    # a feature update that adds a tweak id this engine does not know any more
    $r = W5Json @('-Drift', '-AsJson', '-Skip', 'w5-a')
    Check '-Drift -Skip leaves tweaks out' ($r.Parsed -and $r.Json.summary.tweaks -eq 6)

    Write-Host 'WP5: -Drift -Reapply (preview, preflight, managed device, only the drifted tweaks)'
    $r = W5Json @('-Drift', '-Reapply', '-WhatIf', '-AsJson')
    $dr = $r.Json
    $plan = if ($r.Parsed -and $dr.reapply) { @($dr.reapply.plan) } else { @() }
    Check '-Drift -Reapply -WhatIf -AsJson: one JSON document (drift report + reapply plan + preflight), dryRun, nothing written' ($r.Code -eq 0 -and $r.Parsed -and $dr.mode -eq 'drift' -and $dr.reapply.dryRun -eq $true -and $null -ne $dr.reapply.preflight -and $plan.Count -gt 0 -and (StateListing) -eq $listing -and (Val $w5 'A') -eq 0)
    Check 'plan: re-applies the drifted tweaks that apply here (A, B, last-access, capability); AppX is planned but gated by -AllowIrreversible; the optional feature (in effect) is not touched' (@($plan | Where-Object { $_.tweakId -in 'w5-a', 'w5-b', 'perf-ntfs-lastaccess', 'w5-cap' -and $_.action -eq 'Change' }).Count -eq 4 -and @($plan | Where-Object { $_.tweakId -eq 'w5-appx' -and $_.action -eq 'Skip' -and $_.reason -match 'AllowIrreversible' }).Count -eq 1 -and @($plan | Where-Object tweakId -EQ 'w5-feat').Count -eq 0)
    Check 'a drifted tweak that no longer applies to this build is listed as skipped with the reason, not planned' (@($dr.reapply.skipped | Where-Object { $_.id -eq 'w5-na' -and $_.reason -match 'not applicable' }).Count -eq 1 -and @($plan | Where-Object tweakId -EQ 'w5-na').Count -eq 0)
    W5Edit { param($o) $o | Add-Member -NotePropertyName preflight -NotePropertyValue ([pscustomobject]@{ rebootPending = @('Windows Update') }) -Force }
    $r = W5Run @('-Drift', '-Reapply', '-NoRestorePoint', '-Force')
    Check 're-apply goes through the preflight: a pending reboot refuses it before anything is written' ($r.Code -eq 1 -and $r.Out -match 'Preflight check failed' -and (Val $w5 'A') -eq 0 -and (StateListing) -eq $listing)
    $r = W5Json @('-Drift', '-Reapply', '-WhatIf', '-AsJson')
    Check '-WhatIf reports the blocked preflight in the JSON' ($r.Parsed -and $r.Json.reapply.preflight.blocked -eq $true)
    W5Edit { param($o) $o.PSObject.Properties.Remove('preflight') }
    W5Edit { param($o) $o.managed = $true }
    $r = W5Run @('-Drift', '-Reapply', '-NoRestorePoint', '-SkipPreflight')
    Check 're-apply on a managed device needs -Force (same as an apply); nothing written' ($r.Code -eq 1 -and $r.Out -match 'Managed device' -and (Val $w5 'A') -eq 0)
    $r = W5Run @('-Drift')
    Check '-Drift itself is not gated on a managed device (read-only)' ($r.Code -eq 0)
    W5Edit { param($o) $o.managed = $false }
    $r = W5Run @('-Drift', '-Reapply', '-NoRestorePoint', '-SkipPreflight', '-Force', '-ExpectedSid', 'S-1-5-18-0-0')
    Check 're-apply as a different user than the GUI user: refused before anything is written' ($r.Code -eq 1 -and $r.Out -match 'different user' -and (Val $w5 'A') -eq 0)
    Start-Sleep -Milliseconds 1100
    $r = W5Json @('-Drift', '-Reapply', '-NoRestorePoint', '-SkipPreflight', '-Force', '-AsJson')
    $dr = $r.Json
    Check '-Drift -Reapply -AsJson: pure JSON with the drift report and the results, exit 0' ($r.Code -eq 0 -and $r.Parsed -and $r.Out.TrimStart().StartsWith('{') -and $dr.reapply.dryRun -eq $false -and @($dr.reapply.results | Where-Object { $_.result -eq 'Verified' }).Count -eq @($dr.reapply.results).Count -and @($dr.reapply.results).Count -ge 4)
    Check 're-apply put back exactly the drifted tweaks: A=1, B=2, last-access 1, WordPad removed again' ((Val $w5 'A') -eq 1 -and (Val $w5 'B') -eq 2 -and (Get-Fake 'fsutil:disablelastaccess') -eq '1' -and (Get-Fake $capKeys.wordpad) -match 'NotPresent')
    Check 're-apply left everything else alone: E (not applicable here) still 0, AppX not removed again without -AllowIrreversible, the optional feature untouched' ((Val $w5 'E') -eq 0 -and (Get-Fake 'appx:microsoft.bingnews') -match 'UP' -and (Get-Fake $capKeys.ie) -match 'Disabled')
    $snap = Last-Snapshot
    Check 'the re-apply snapshot records the new build, that it was a re-apply, and only the drifted steps' ($snap.os.BuildFull -eq '26200.1' -and $snap.reapply -eq $true -and @($snap.steps | Where-Object { $_.tweakId -in 'w5-feat', 'w5-na', 'w5-appx' }).Count -eq 0 -and @($snap.steps).Count -eq 4)
    Check 'the first run of drift/re-apply (preview, refusals) did not create extra snapshots; the re-apply created exactly one more' (@(Get-ChildItem $stateDir -Filter 'state-*.json').Count -eq 2)
    $r = W5Json @('-Drift', '-AsJson')
    $dr = $r.Json
    Check 'after the re-apply the newest snapshot supersedes the old record: only AppX and the not-applicable tweak still drift' ($r.Parsed -and $dr.summary.drifted -eq 2 -and (DriftTweak $dr 'w5-appx').status -eq 'Drifted' -and (DriftTweak $dr 'w5-na').status -eq 'Drifted' -and (DriftTweak $dr 'w5-a').status -eq 'InSync' -and @((DriftTweak $dr 'w5-a').appliedBuilds) -contains '26200.1' -and @((DriftTweak $dr 'w5-a').appliedBuilds) -notcontains '26100.1')
    $r = W5Run @('-Drift', '-Reapply', '-NoRestorePoint', '-SkipPreflight', '-Force', '-AllowIrreversible', '-Only', 'w5-appx')
    Check '-Reapply -AllowIrreversible -Only: removes the re-provisioned AppX package again' ($r.Code -eq 0 -and -not (Get-Fake 'appx:microsoft.bingnews'))
    $r = W5Run @('-Drift', '-Reapply', '-NoRestorePoint', '-SkipPreflight', '-Force')
    Check '-Reapply when only a not-applicable tweak drifted: nothing to re-apply, exit 0, nothing written' ($r.Code -eq 0 -and $r.Out -match 'None of the drifted tweaks can be re-applied' -and $r.Out -match 'w5-na')
    $r = W5Json @('-Drift', '-Reapply', '-AsJson')
    Check '-Reapply -AsJson with nothing eligible: JSON with empty ids and the skipped reason' ($r.Code -eq 0 -and $r.Parsed -and @($r.Json.reapply.ids).Count -eq 0 -and @($r.Json.reapply.skipped).Count -eq 1)

    Write-Host 'WP5: revert after drift and re-apply restores what was there before DebloatKit'
    $r = W5Run @('-Revert', 'w5-a')
    Check 'revert w5-a (applied on 26100, drifted, re-applied on 26200): back to 5, the original value, not the 0 Windows left; both runs marked' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5 -and (RevMarks 'w5-a') -eq 2)
    $r = W5Json @('-Drift', '-AsJson')
    Check 'a reverted tweak is no longer tracked for drift' ($r.Parsed -and $null -eq (DriftTweak $r.Json 'w5-a'))
    $r = W5Run @('-Revert', 'w5-cap')
    Check 'revert the capability (fake): Installed again' ($r.Code -eq 0 -and (Get-Fake $capKeys.wordpad) -match 'Installed')

    Write-Host 'WP5: -Drift with no snapshots and against the real system (read-only)'
    Remove-StateDir
    $r = RunJson @('-Drift', '-AsJson') $wp5
    Check 'real system, empty state folder: exit 0, valid JSON, zero tweaks, the real build is reported, nothing created' ($r.Code -eq 0 -and $r.Parsed -and $r.Json.summary.tweaks -eq 0 -and $r.Json.snapshots -eq 0 -and $r.Json.os.build -gt 0 -and -not (Test-Path $stateDir))
    $r = Run @('-Drift') $wp5
    Check 'text mode with no snapshots: exit 0' ($r.Code -eq 0 -and $r.Out -match '0 applied tweak')
    $r = Run @('-Drift', '-Reapply', '-WhatIf') $wp5
    Check '-Reapply -WhatIf with no snapshots: nothing to re-apply' ($r.Code -eq 0 -and $r.Out -match 'nothing to re-apply')
    $r = Run @('-Drift', '-Preset', 'aggressive') $wp5
    Check '-Drift honours the enabled-preset rule' ($r.Code -ne 0 -and $r.Out -match 'not enabled')

    Write-Host 'WP5: the real catalog and the state folder'
    $r = RunJson @('-Drift', '-AsJson') (Join-Path $PSScriptRoot '..\tweak-catalog.json')
    Check 'real catalog + empty state folder: -Drift works (read-only)' ($r.Code -eq 0 -and $r.Parsed -and $r.Json.summary.tweaks -eq 0)
    Check 'the default state folder (ProgramData\DebloatKit) was neither created nor changed by these tests' ((Test-Path (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdBefore5)

    # ======================= WP10: review fixes =======================
    # Same sandbox as WP5 (throwaway key HKCU:\Software\DebloatKitTest\WP5, fake tools in the -TestEnvironment file).
    Write-Host 'WP10: -Revert -WhatIf never runs an undo (a capability record with an irreversible note)'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-cap')
    Check 'setup: capability removed (fake WordPad NotPresent)' ($r.Code -eq 0 -and (Get-Fake $capKeys.wordpad) -match 'NotPresent')
    # make the record look like one planned with WSUS and no repair source
    $sf10 = Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1
    $sj10 = Get-Content $sf10.FullName -Raw | ConvertFrom-Json
    foreach ($st in @($sj10.steps)) { $st | Add-Member -NotePropertyName irreversible -NotePropertyValue 'WSUS is configured without a repair content source' -Force }
    $sj10 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sf10.FullName -Encoding UTF8
    $listing = StateListing
    $r = W5Json @('-Revert', 'w5-cap', '-WhatIf', '-AsJson')
    Check '-Revert -WhatIf -AsJson on an irreversible capability record: WouldRevert, the fake capability stays NotPresent, nothing written' ($r.Parsed -and $r.Code -eq 0 -and $r.Json.results[0].result -eq 'WouldRevert' -and $r.Json.summary.wouldRevert -eq 1 -and (Get-Fake $capKeys.wordpad) -match 'NotPresent' -and (StateListing) -eq $listing)
    $r = W5Run @('-Revert', 'w5-cap', '-WhatIf')
    Check '-Revert -WhatIf (text): WouldRevert, still NotPresent, "nothing was changed" is true' ($r.Code -eq 0 -and $r.Out -match 'WouldRevert' -and $r.Out -match 'nothing was changed' -and (Get-Fake $capKeys.wordpad) -match 'NotPresent')
    $r = W5Run @('-Revert', 'w5-cap')
    Check 'the real -Revert of that record still runs the undo (Add-WindowsCapability on the fake)' ($r.Code -eq 0 -and $r.Out -match 'Reverted' -and (Get-Fake $capKeys.wordpad) -match 'Installed')

    Write-Host 'WP10: a failed -Undo keeps the snapshot (successful steps are marked, failures can be retried)'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-cap')
    W5Fake 'source:blocked' 'true'
    $r = W5Run @('-Undo', 'latest')
    Check '-Undo with a capability that cannot be added back: exit 2, the registry step is restored and marked, the snapshot is NOT renamed' ($r.Code -eq 2 -and (Val $w5 'A') -eq 5 -and (RevMarks 'w5-a') -eq 1 -and (RevMarks 'w5-cap') -eq 0 -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 0 -and @(Get-ChildItem $stateDir -Filter 'state-*.json').Count -eq 1)
    $r = W5Json @('-Drift', '-AsJson')
    Check 'the kept snapshot is still read by -Drift (the capability step is tracked, the reverted registry step is not)' ($r.Parsed -and $null -ne (DriftTweak $r.Json 'w5-cap') -and $null -eq (DriftTweak $r.Json 'w5-a'))
    W5Fake 'source:blocked' 'false'
    $r = W5Run @('-Undo', 'latest')
    Check 'retry after fixing the cause: only the failed step is undone, exit 0, then the snapshot is renamed' ($r.Code -eq 0 -and $r.Out -match 'Reverting 1 step' -and (Get-Fake $capKeys.wordpad) -match 'Installed' -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 1 -and @(Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json').Count -eq 0)

    W5Reset; W5Env
    W5Edit { param($o) $o | Add-Member -NotePropertyName failSteps -NotePropertyValue @('w5-cap|*') -Force }
    $r = W5Apply @('-Only', 'w5-cap')
    W5Fake 'source:blocked' 'true'
    $r2 = W5Run @('-Undo', 'latest')
    Check 'a capability removal that Failed without changing anything is not "restored" by a download: -Undo exits 0 even with the source blocked, the capability stays Installed' ($r.Code -eq 2 -and $r2.Code -eq 0 -and $r2.Out -match 'restore of an interrupted step' -and (Get-Fake $capKeys.wordpad) -match 'Installed' -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 1)

    Write-Host 'WP10: -Undo with an AppX removal (terminal NotRevertible) still retires the snapshot'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-appx', '-AllowIrreversible')
    $r = W5Run @('-Undo', 'latest')
    Check '-Undo: registry restored, AppX reported NotRevertible with the reinstall hint (exit 2), the snapshot is renamed (nothing more can be retried)' ($r.Code -eq 2 -and (Val $w5 'A') -eq 5 -and $r.Out -match 'NotRevertible' -and @(Get-ChildItem $stateDir -Filter '*.reverted.json').Count -eq 1)

    Write-Host 'WP10: interrupted (Pending) and Failed steps are restorable'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-multi,w5-appx', '-AllowIrreversible')
    Check 'setup: A=1, new key Deep created, AppX removed' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and (Val "$w5\Deep" 'C') -eq 3)
    $sf10 = Get-ChildItem $stateDir -Filter 'state-*.json' | Where-Object Name -NotLike '*.reverted.json' | Sort-Object Name | Select-Object -Last 1
    $sj10 = Get-Content $sf10.FullName -Raw | ConvertFrom-Json
    foreach ($st in @($sj10.steps)) {
        # a crash before the result was written: Pending, and no createdKeys yet on the step that would have created the key
        $st.result = 'Pending'
        if ($st.PSObject.Properties['createdKeys']) { $st.PSObject.Properties.Remove('createdKeys') }
    }
    $sj10 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sf10.FullName -Encoding UTF8
    $r = W5Json @('-Revert', 'w5-a', '-WhatIf', '-AsJson')
    Check '-Revert -WhatIf offers a Pending step, marked as a restore of an interrupted step' ($r.Parsed -and $r.Json.results[0].result -eq 'WouldRevert' -and $r.Json.results[0].note -match 'interrupted step' -and (Val $w5 'A') -eq 1)
    $r = W5Run @('-Undo', 'latest', '-WhatIf')
    Check '-Undo -WhatIf lists the Pending registry steps and leaves the Pending AppX step out (3 steps)' ($r.Code -eq 0 -and $r.Out -match 'Reverting 3 step' -and $r.Out -match 'interrupted step' -and (Val $w5 'A') -eq 1)
    $r = W5Run @('-Revert', 'w5-a,w5-multi')
    Check '-Revert restores Pending steps (A back to 5, C and D removed) even though createdKeys was never written; exit 0' ($r.Code -eq 0 -and (Val $w5 'A') -eq 5 -and $null -eq (Val "$w5\Deep" 'C') -and $null -eq (Val $w5 'D'))
    $r = W5Json @('-Revert', 'w5-appx', '-AsJson')
    Check 'a Pending AppX step has nothing to restore: -Revert finds nothing (exit 1)' ($r.Code -eq 1)
    $r = W5Json @('-Drift', '-AsJson')
    Check '-Drift does not compare Pending / Failed steps (they are not "applied")' ($r.Parsed -and $r.Json.summary.tweaks -eq 0)

    Write-Host 'WP10: snapshot writes are atomic (no leftover temp file, readable JSON)'
    Check 'no *.tmp file is left in the state folder and the newest snapshot parses' (@(Get-ChildItem $stateDir -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -eq 0 -and $null -ne (Get-ChildItem $stateDir -Filter 'state-*.json' | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }))

    Write-Host 'WP10: -TestEnvironment cannot lift the managed-device and preflight guards outside the test runner'
    W5Reset; W5Env
    $keepEnv = $env:DEBLOATKIT_TESTENV
    try {
        $env:DEBLOATKIT_TESTENV = $null
        $r = W5Run @('-NoRestorePoint', '-Force', '-SkipPreflight', '-Only', 'w5-a')
        Check 'apply with -TestEnvironment and no DEBLOATKIT_TESTENV: refused (exit 1), nothing written, the real key untouched' ($r.Code -eq 1 -and $r.Out -match 'only accepted with -WhatIf' -and (Val $w5 'A') -eq 5 -and -not (Test-Path $stateDir))
        $r = W5Run @('-Undo', 'latest')
        Check '-Undo with -TestEnvironment and no DEBLOATKIT_TESTENV: refused' ($r.Code -eq 1 -and $r.Out -match 'only accepted with -WhatIf')
        $r = W5Run @('-Revert', 'w5-a')
        Check '-Revert with -TestEnvironment and no DEBLOATKIT_TESTENV: refused' ($r.Code -eq 1 -and $r.Out -match 'only accepted with -WhatIf')
        $r = W5Run @('-Drift', '-Reapply', '-NoRestorePoint', '-Force')
        Check '-Drift -Reapply with -TestEnvironment and no DEBLOATKIT_TESTENV: refused' ($r.Code -eq 1 -and $r.Out -match 'only accepted with -WhatIf')
        $r = W5Json @('-WhatIf', '-NoRestorePoint', '-AsJson', '-Only', 'w5-a')
        Check '-WhatIf with -TestEnvironment is always allowed (it writes nothing)' ($r.Code -eq 0 -and $r.Parsed)
        $r = W5Json @('-List', '-AsJson')
        Check '-List with -TestEnvironment is always allowed' ($r.Code -eq 0 -and $r.Parsed)
        $r = W5Json @('-Drift', '-AsJson')
        Check '-Drift (read-only) with -TestEnvironment is always allowed' ($r.Code -eq 0 -and $r.Parsed)
        Check 'the refusals created no state folder' (-not (Test-Path $stateDir))
    } finally { $env:DEBLOATKIT_TESTENV = $keepEnv }

    Write-Host 'WP10: more protected targets (update service and policy, firewall, UAC, SmartScreen, BitLocker policy)'
    $protCat10 = New-TempFile @'
{ "schemaVersion": 2, "catalogVersion": "t10", "migrations": [], "tweaks": [
  { "id": "w10-p-wu-noauto", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "name": "NoAutoUpdate", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-wu-server", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate", "name": "WUServer", "valueType": "String", "value": "http://x" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-fw", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\WindowsFirewall\\DomainProfile", "name": "EnableFirewall", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-fw2", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\SharedAccess\\Parameters\\FirewallPolicy\\StandardProfile", "name": "EnableFirewall", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-uac", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", "name": "EnableLUA", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-uac2", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", "name": "ConsentPromptBehaviorAdmin", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-ss", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System", "name": "EnableSmartScreen", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-fve", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\FVE", "name": "UseAdvancedStartup", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-svc-wu", "category": "o", "implementation": { "type": "service", "name": "wuauserv", "startType": "Disabled" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-svc-bits", "category": "o", "implementation": { "type": "service", "name": "BITS", "startType": "Disabled" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-svc-uso", "category": "o", "implementation": { "type": "service", "name": "UsoSvc", "startType": "Disabled" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-p-svc-do", "category": "o", "implementation": { "type": "service", "name": "DoSvc", "startType": "Disabled" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "w10-ok", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\DebloatKitTest\\WP5", "name": "A", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" }
] }
'@
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-TestEnvironment', $envFile) $protCat10
    $pp = if ($r.Parsed) { @($r.Json) } else { @() }
    $protIds10 = 'w10-p-wu-noauto', 'w10-p-wu-server', 'w10-p-fw', 'w10-p-fw2', 'w10-p-uac', 'w10-p-uac2', 'w10-p-ss', 'w10-p-fve', 'w10-p-svc-wu', 'w10-p-svc-bits', 'w10-p-svc-uso', 'w10-p-svc-do'
    Check 'every protected target is planned as a Skip with a "protected target" reason' ($r.Code -eq 0 -and @($protIds10 | Where-Object { $i = $_; @($pp | Where-Object { $_.tweakId -eq $i -and $_.action -eq 'Skip' -and $_.reason -match 'protected target' }).Count -ne 1 }).Count -eq 0)
    Check 'an ordinary value in the same run is still planned as a Change' (@($pp | Where-Object { $_.tweakId -eq 'w10-ok' -and $_.action -eq 'Change' }).Count -eq 1)
    $r = Run @('-NoRestorePoint', '-Force', '-TestEnvironment', $envFile) $protCat10
    Check 'an apply of those targets skips them: only the ordinary value is written, protected ones are not even in the snapshot as Verified' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and @((Last-Snapshot).steps).Count -eq 1)
    # the image builder mirrors the engine's lists
    $engText10 = Get-Content -LiteralPath $engine -Raw
    $imgText10 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\DebloatKit-Image.ps1') -Raw
    $engSvc10 = @([regex]::Matches([regex]::Match($engText10, '(?s)Services\s*=\s*\[ordered\]@\{(.*?)\n    \}').Groups[1].Value, "(?m)^\s*(\w+)\s*=\s*'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $imgSvc10 = @([regex]::Matches([regex]::Match($imgText10, '(?s)\$script:ProtectedServices = \[ordered\]@\{(.*?)\n\}').Groups[1].Value, "(?m)^\s*(\w+)\s*=\s*'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Check ("protected services: the image builder's $($imgSvc10.Count) entries equal the engine's $($engSvc10.Count) (and include wuauserv, UsoSvc, BITS, DoSvc)") ($engSvc10.Count -gt 15 -and (($engSvc10 -join '|') -eq ($imgSvc10 -join '|')) -and (@('wuauserv', 'UsoSvc', 'BITS', 'DoSvc' | Where-Object { $imgSvc10 -notcontains $_ }).Count -eq 0))
    $engRules10 = @([regex]::Matches([regex]::Match($engText10, '(?s)RegistryRules\s*=\s*@\((.*?)\n    \)').Groups[1].Value, "Path = '([^']+)'; Names = @\(([^)]*)\)") | ForEach-Object { $_.Groups[1].Value + ' => ' + $_.Groups[2].Value })
    $imgRules10 = @([regex]::Matches([regex]::Match($imgText10, '(?s)\$script:ProtectedRegistryRules = @\((.*?)\n\)').Groups[1].Value, "Path = '([^']+)'; Names = @\(([^)]*)\)") | ForEach-Object { $_.Groups[1].Value + ' => ' + $_.Groups[2].Value })
    Check ("protected registry rules: the image builder's $($imgRules10.Count) rules equal the engine's $($engRules10.Count)") ($engRules10.Count -ge 8 -and (($engRules10 -join '|') -eq ($imgRules10 -join '|')))
    $engDef10 = [regex]::Match($engText10, "DefenderValues\s*=\s*@\(([^)]*)\)").Groups[1].Value
    $imgDef10 = [regex]::Match($imgText10, "ProtectedDefenderValues\s*=\s*@\(([^)]*)\)").Groups[1].Value
    Check 'protected Defender value names: the image builder equals the engine' ($engDef10 -and $engDef10 -eq $imgDef10)

    Write-Host 'WP10: the safe preset holds nothing that weakens serviceability or the visibility of security state'
    $rc10 = Get-Content (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json
    function Tw10([string]$Id) { @($rc10.tweaks | Where-Object id -EQ $Id)[0] }
    $tt10 = (Tw10 'task-telemetry-set').implementation | ConvertTo-Json -Depth 6
    Check 'task-telemetry-set (safe) no longer touches the Compatibility Appraiser; ProgramDataUpdater, CEIP, Chkdsk Proxy and QueueReporting stay' ($tt10 -notmatch 'Compatibility Appraiser' -and $tt10 -match 'ProgramDataUpdater' -and $tt10 -match 'Customer Experience' -and $tt10 -match 'Chkdsk' -and $tt10 -match 'QueueReporting' -and (Tw10 'task-telemetry-set').preset -eq 'safe')
    $ta10 = Tw10 'task-compat-appraiser-off'
    Check 'task-compat-appraiser-off: balanced, moderate risk, has a managedSkip reason, disables only the Appraiser task' ($ta10 -and $ta10.preset -eq 'balanced' -and $ta10.risk -eq 'moderate' -and $ta10.managedSkip -and $ta10.implementation.name -eq 'Microsoft Compatibility Appraiser')
    Check 'priv-security-maintenance-toast-off moved to balanced / moderate' ((Tw10 'priv-security-maintenance-toast-off').preset -eq 'balanced' -and (Tw10 'priv-security-maintenance-toast-off').risk -eq 'moderate')
    Check 'priv-firewall-block-diagtrack moved to balanced / moderate (its own text says it can break update diagnostics)' ((Tw10 'priv-firewall-block-diagtrack').preset -eq 'balanced' -and (Tw10 'priv-firewall-block-diagtrack').risk -eq 'moderate')
    Check 'svc-remoteregistry-disable has a managedSkip reason (ConfigMgr / RMM read the registry remotely)' ((Tw10 'svc-remoteregistry-disable').managedSkip -match 'ConfigMgr')
    Check 'drv-netbt-gpuenergy-telemetry: the ReviOS sentences are separated' ((Tw10 'drv-netbt-gpuenergy-telemetry').breaks -match 'ReviOS\. NetBT' -and (Tw10 'drv-netbt-gpuenergy-telemetry').tradeoff -match 'ReviOS\. Undo is exact')
    Check 'no safe tweak touches the Appraiser task, the Security and Maintenance toast or a protected update / firewall / UAC target' (@($rc10.tweaks | Where-Object { $_.preset -eq 'safe' -and (($_.implementation | ConvertTo-Json -Depth 8) -match 'Compatibility Appraiser|SystemToast\.SecurityAndMaintenance|"wuauserv"|"UsoSvc"|"BITS"|"DoSvc"|NoAutoUpdate|EnableLUA|EnableFirewall') }).Count -eq 0)
    $lintBad10 = New-TempFile @'
{ "schemaVersion": 2, "migrations": [], "tweaks": [
  { "id": "l10-appraiser", "category": "o", "implementation": { "type": "task", "path": "\\Microsoft\\Windows\\Application Experience\\", "name": "Microsoft Compatibility Appraiser", "state": "Disabled" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l10-toast", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\Windows.SystemToast.SecurityAndMaintenance", "name": "Enabled", "valueType": "DWord", "value": 0 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l10-wu", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU", "name": "NoAutoUpdate", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "l10-balanced-ok", "category": "o", "implementation": { "type": "task", "path": "\\Microsoft\\Windows\\Application Experience\\", "name": "Microsoft Compatibility Appraiser", "state": "Disabled" }, "revert": "snapshot", "risk": "moderate", "preset": "balanced" }
] }
'@
    $r = RunJson @('-Lint', '-AsJson') $lintBad10
    $fi10 = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    Check 'lint: a safe tweak that disables the Compatibility Appraiser is an error; the same step in balanced is not' (@($fi10 | Where-Object { $_.tweakId -eq 'l10-appraiser' -and $_.rule -eq 'safe-preset' -and $_.severity -eq 'error' -and $_.message -match 'Appraiser' }).Count -eq 1 -and @($fi10 | Where-Object { $_.tweakId -eq 'l10-balanced-ok' -and $_.severity -eq 'error' }).Count -eq 0)
    Check 'lint: a safe tweak that hides the Security and Maintenance toasts is an error' (@($fi10 | Where-Object { $_.tweakId -eq 'l10-toast' -and $_.rule -eq 'safe-preset' -and $_.severity -eq 'error' }).Count -eq 1)
    Check 'lint: a safe tweak on a protected update policy value is an error (protected-target)' (@($fi10 | Where-Object { $_.tweakId -eq 'l10-wu' -and $_.rule -eq 'protected-target' -and $_.severity -eq 'error' }).Count -eq 1)

    Write-Host 'WP10: managed-device AppX keep list comes from the profiles file'
    $pf10 = Get-Content (Join-Path $PSScriptRoot '..\appx-profiles.json') -Raw | ConvertFrom-Json
    Check 'real profiles file: managedKeep has Teams, Outlook, Quick Assist and the Microsoft 365 app; keep-work keeps Quick Assist and the Microsoft 365 app' (@('MSTeams', 'MicrosoftTeams', 'Microsoft.OutlookForWindows', 'MicrosoftCorporationII.QuickAssist', 'Microsoft.MicrosoftOfficeHub' | Where-Object { $pf10.managedKeep -notcontains $_ }).Count -eq 0 -and $pf10.profiles.'keep-work'.keep -contains 'MicrosoftCorporationII.QuickAssist' -and $pf10.profiles.'keep-work'.keep -contains 'Microsoft.MicrosoftOfficeHub')
    Check 'real profiles file: every managedKeep entry is in the remove list of at least one profile' (@($pf10.managedKeep | Where-Object { $m = $_; @($pf10.profiles.PSObject.Properties | Where-Object { $_.Value.remove -contains $m }).Count -eq 0 }).Count -eq 0)
    # a profiles file whose managedKeep keeps one extra package: the engine honours the file
    $wp4pf10 = Get-Content -LiteralPath $wp4Prof -Raw | ConvertFrom-Json
    $wp4pf10.managedKeep = @('Microsoft.BingNews')
    $pfEdit10 = New-TempFile ($wp4pf10 | ConvertTo-Json -Depth 8)
    W4Env $true
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson', '-AllowIrreversible', '-Only', 'w4-appx-work', '-TestEnvironment', $envFile, '-ProfilesPath', $pfEdit10) $wp4
    $kept10 = @($r.Json | Where-Object { $_.tweakId -eq 'w4-appx-work' -and $_.action -eq 'Skip' -and $_.reason -match 'kept by default' })
    $chg10 = @($r.Json | Where-Object { $_.tweakId -eq 'w4-appx-work' -and $_.action -eq 'Change' })
    Check 'editing managedKeep in the profiles file changes what a managed device keeps (BingNews kept, Teams no longer kept)' ($r.Parsed -and $kept10.Count -ge 1 -and $kept10[0].target -match 'Microsoft\.BingNews' -and $kept10[0].target -notmatch 'MSTeams' -and ($chg10.Count -eq 0 -or $chg10[0].target -match 'MSTeams'))

    Write-Host 'WP10: execution policy handler is pinned to Windows PowerShell and records that'
    $ep10 = Get-Content -LiteralPath $engine -Raw
    Check 'engine source: the execution-policy tool calls Windows PowerShell 5.1 when run under pwsh 7, and the handler records the host in the snapshot' ($ep10 -match 'WindowsPowerShell\\v1\.0\\powershell\.exe"\s+if \(\$Arguments\[0\] -eq ''get''\)' -and $ep10 -match "Get-ExecutionPolicy -Scope LocalMachine'" -and $ep10 -match "Before  = \{ @\{ host = 'Windows PowerShell 5\.1")
    $epCat10 = New-TempFile '{ "schemaVersion": 2, "catalogVersion": "t", "migrations": [], "tweaks": [ { "id": "sec-powershell-remotesigned", "category": "o", "implementation": { "type": "command", "run": "x", "undo": "y" }, "revert": "snapshot", "risk": "safe", "preset": "safe" } ] }'
    $r = RunJson @('-WhatIf', '-NoRestorePoint', '-AsJson') $epCat10
    $want10 = ((& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command 'Get-ExecutionPolicy -Scope LocalMachine') | Out-String).Trim()
    Check "real read (this host, read-only): the handler reports the Windows PowerShell machine policy ($want10)" ($r.Parsed -and (Step $r.Json 'sec-powershell-remotesigned').current -eq $want10)

    Write-Host '-Lint on the real catalog (Lint-Catalog.ps1)'
    $lintScript = Join-Path $PSScriptRoot 'Lint-Catalog.ps1'
    $out = & $host_ -NoProfile -ExecutionPolicy Bypass -File $lintScript 2>&1 | Out-String
    Check 'Lint-Catalog.ps1 passes on tweak-catalog.json (exit 0, 0 errors)' ($LASTEXITCODE -eq 0 -and $out -match ', 0 error')
    $realCat = Get-Content (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json
    Check 'real catalog is schemaVersion 2 with a catalogVersion and migrations' ($realCat.schemaVersion -eq 2 -and $realCat.catalogVersion -and @($realCat.migrations).Count -ge 1)
    $managedIds = @($realCat.tweaks | Where-Object { $_.PSObject.Properties.Name -contains 'managedSkip' } | ForEach-Object { $_.id })
    foreach ($want in 'svc-diagtrack-disable', 'priv-firewall-block-diagtrack', 'priv-autologgers-off', 'net-delivery-optimization-off', 'perf-reserved-storage-off', 'task-office-telemetry-off', 'svc-dmwappushservice-disable', 'telemetry-limit-collection', 'net-ntp-pool') {
        Check "real catalog: $want has a managedSkip reason" ($managedIds -contains $want)
    }
    Check 'real catalog: every updates-category tweak has managedSkip' (@($realCat.tweaks | Where-Object { $_.category -eq 'updates' -and $_.PSObject.Properties.Name -notcontains 'managedSkip' }).Count -eq 0)
    Check 'real catalog: AllowTelemetry policy carries an edition note' (@($realCat.tweaks | Where-Object { $_.id -eq 'telemetry-allowtelemetry-policy' -and $_.appliesTo.onMismatch -eq 'note' }).Count -eq 1)
    Check 'real catalog: svchost split threshold entry removed, migration present' (@($realCat.tweaks | Where-Object id -EQ 'perf-svchost-split-threshold').Count -eq 0 -and @($realCat.migrations | Where-Object id -EQ 'svchost-split-forced').Count -eq 1)
    Check 'real catalog: ultra performance plan no longer uses the legacy ReviOS GUID' (@($realCat.tweaks | Where-Object { $_.id -eq 'pwr-ultra-performance-plan' -and ($_.implementation.run -match '3ff9831b') }).Count -eq 0)
    $safe = @($realCat.tweaks | Where-Object preset -EQ 'safe')
    Check 'real catalog: no reduces-security / breaks-features / appx / not-reversible entry in safe' (@($safe | Where-Object { $_.risk -ne 'safe' -or ($_.revert -is [string] -and $_.revert -match 'not reversible') -or ($_.implementation.type -eq 'appx') }).Count -eq 0)
    Check 'real catalog: effectiveness above 1 only with a measured figure' (@($realCat.tweaks | Where-Object { $_.effectiveness -gt 1 -and ($_.measuredEffect -match '^\s*not measured' -or $_.measuredEffect -notmatch '\d') }).Count -eq 0)
    Check 'real catalog: unique ids' ((@($realCat.tweaks.id | Select-Object -Unique)).Count -eq @($realCat.tweaks).Count)
    $newV10 = 'search-respect-power-modes', 'telemetry-limit-collection', 'ifeo-searchindexer-belownormal', 'logon-first-animation-off'
    Check 'real catalog: the four V10 items exist and start new-unverified' (@($realCat.tweaks | Where-Object { $newV10 -contains $_.id -and $_.verification -eq 'new-unverified' }).Count -eq 4)

    Write-Host '-Lint finds deliberate catalog defects'
    $badCat = New-TempFile @'
{ "schemaVersion": 2, "migrations": [
    { "id": "m1", "path": "HKU:\\x", "name": "n", "valueType": "Binary", "oldValue": 1, "action": "delete" },
    { "id": "m1", "path": "HKLM:\\SOFTWARE\\x", "name": "n", "oldValue": 1, "action": "rewrite" } ],
  "tweaks": [
  { "id": "dup", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\DebloatKitTest", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "dup", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\DebloatKitTest", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-hive", "category": "o", "implementation": { "type": "registry", "path": "HKU:\\.DEFAULT\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-default", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\x\\.DEFAULT\\y", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-ifeo", "category": "o", "implementation": { "type": "registry", "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\x.exe", "name": "Debugger", "valueType": "String", "value": "taskkill.exe" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-type", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "Binary", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-dword", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": "abc" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-big", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 99999999999 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-step", "category": "o", "implementation": { "type": "frobnicate" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-risk", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "reduces-security", "preset": "safe" },
  { "id": "bad-appx", "category": "o", "implementation": { "type": "appx", "names": [ "x" ] }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-irrev", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "not reversible", "risk": "safe", "preset": "safe" },
  { "id": "bad-cmd", "category": "o", "implementation": { "type": "command", "run": "x", "undo": null }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad-eff", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "effectiveness": 3, "measuredEffect": "not measured" },
  { "id": "bad-preset", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "turbo" },
  { "id": "bad-ms", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "managedSkip": "" },
  { "id": "bad-ap", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe", "appliesTo": { "editions": [ "x" ], "onMismatch": "explode", "color": "red" } },
  { "id": "bad-task", "category": "o", "implementation": { "type": "task", "path": "\\NoTrailingSlash", "name": "t", "state": "Enabled" }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "bad id!", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" },
  { "id": "perf-ntfs-lastaccess", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\x", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" }
] }
'@
    $r = RunJson @('-Lint', '-AsJson') $badCat
    $fi = if ($r.Parsed) { @($r.Json.findings) } else { @() }
    function HasF([string]$Id, [string]$Rule, [string]$Sev = 'error') { @($fi | Where-Object { $_.tweakId -eq $Id -and $_.rule -eq $Rule -and $_.severity -eq $Sev }).Count -ge 1 }
    Check 'lint: exit 1 and valid JSON with an error count' ($r.Code -eq 1 -and $r.Parsed -and $r.Json.errors -gt 10)
    Check 'lint: duplicate id' (HasF 'dup' 'id')
    Check 'lint: HKU hive path' (HasF 'bad-hive' 'registry')
    Check 'lint: .DEFAULT hive path' (HasF 'bad-default' 'registry')
    Check 'lint: IFEO Debugger value' (@($fi | Where-Object { $_.tweakId -eq 'bad-ifeo' -and $_.message -match 'Debugger' }).Count -ge 1)
    Check 'lint: unsupported valueType' (@($fi | Where-Object { $_.tweakId -eq 'bad-type' -and $_.message -match 'valueType' }).Count -ge 1)
    Check 'lint: non-numeric DWord' (@($fi | Where-Object { $_.tweakId -eq 'bad-dword' -and $_.message -match '32-bit' }).Count -ge 1)
    Check 'lint: DWord above 32 bits' (@($fi | Where-Object { $_.tweakId -eq 'bad-big' -and $_.message -match '32-bit' }).Count -ge 1)
    Check 'lint: step type without a handler' (HasF 'bad-step' 'step')
    Check 'lint: reduces-security in safe' (HasF 'bad-risk' 'safe-preset')
    Check 'lint: appx step in safe' (HasF 'bad-appx' 'safe-preset')
    Check 'lint: not reversible in safe' (HasF 'bad-irrev' 'safe-preset')
    Check 'lint: command without undo in safe' (HasF 'bad-cmd' 'safe-preset')
    Check 'lint: effectiveness above 1 without a measured figure' (HasF 'bad-eff' 'effectiveness')
    Check 'lint: unknown preset' (HasF 'bad-preset' 'preset')
    Check 'lint: empty managedSkip' (HasF 'bad-ms' 'managedSkip')
    Check 'lint: appliesTo unknown key, bad onMismatch, missing reason' (@($fi | Where-Object { $_.tweakId -eq 'bad-ap' -and $_.rule -eq 'appliesTo' }).Count -ge 3)
    Check 'lint: task path without trailing backslash and unsupported state' (@($fi | Where-Object { $_.tweakId -eq 'bad-task' -and $_.rule -eq 'task' }).Count -ge 2)
    Check 'lint: invalid id characters' (HasF 'bad id!' 'id')
    Check 'lint: native handler id whose catalog entry has no command step' (HasF 'perf-ntfs-lastaccess' 'native-handler')
    Check 'lint: duplicate migration id, bad migration path/type/action, missing fields' ((HasF 'm1' 'migration') -and @($fi | Where-Object { $_.rule -eq 'migration' }).Count -ge 6)

    Write-Host '-Lint finds deliberate engine defects (handler round trip, missing step handler)'
    $engSrc = Get-Content -LiteralPath $engine -Raw
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('DebloatKitLint-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $dir | Out-Null; $tmpFiles.Add($dir)
    $mutant = Join-Path $dir 'DebloatKit.ps1'
    function LintMutant([string]$Old, [string]$New) {
        # Writes a copy of the engine with one text replaced and lints it; returns $null when the text was not found.
        $src = $engSrc.Replace($Old, $New)
        if ($src -eq $engSrc) { return $null }
        [IO.File]::WriteAllText($mutant, $src, [Text.UTF8Encoding]::new($false))
        $o = & $host_ -NoProfile -ExecutionPolicy Bypass -File $mutant -Lint -AsJson -CatalogPath $catalog 2>&1 | Out-String
        try { $o | ConvertFrom-Json } catch { $null }
    }
    # 1. Get reads a different setting than Set writes (the Revision Tool last-access status bug)
    $fj = LintMutant "@('behavior', 'query', 'disablelastaccess')" "@('behavior', 'query', 'disable8dot3')"
    Check 'lint: Get that reads another setting than Set writes is an error' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'perf-ntfs-lastaccess' -and $_.rule -eq 'native-roundtrip' -and $_.severity -eq 'error' }).Count -eq 1)
    # 2. Set writes a different setting than Get reads
    $fj = LintMutant "@('behavior', 'set', 'disablelastaccess', [string]`$v)" "@('behavior', 'set', 'disable8dot3', [string]`$v)"
    Check 'lint: Set that writes another setting than Get reads is an error' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'perf-ntfs-lastaccess' -and $_.rule -eq 'native-roundtrip' -and $_.severity -eq 'error' }).Count -eq 1)
    # 3. a handler that calls a tool the fake does not model
    $fj = LintMutant "Invoke-Tool 'powercfg.exe' @('/getactivescheme')" "Invoke-Tool 'powercfg.exe' @('/list')"
    Check 'lint: a handler using a tool call the fake does not model is an error' ($fj -and @($fj.findings | Where-Object { $_.tweakId -eq 'pwr-balanced-plan' -and $_.rule -eq 'native-roundtrip' }).Count -eq 1)
    # 4. a mutating step type with no Undo-Step branch
    $fj = LintMutant "'task' { if (`$Rec.before.state -ne 'Disabled')" "'taskx' { if (`$Rec.before.state -ne 'Disabled')"
    Check 'lint: a mutating step type without an Undo-Step branch is an error' ($fj -and @($fj.findings | Where-Object { $_.rule -eq 'handler' -and $_.message -match "'task'.*Undo-Step" }).Count -eq 1)
    # 5. the unmodified engine is clean
    $o = & $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -Lint -AsJson -CatalogPath $catalog 2>&1 | Out-String
    $fj = try { $o | ConvertFrom-Json } catch { $null }
    Check 'lint: the real engine has no handler errors' ($fj -and @($fj.findings | Where-Object { $_.severity -eq 'error' -and $_.rule -in 'handler', 'native-roundtrip', 'native-handler' }).Count -eq 0)
    Check 'lint: -Lint -AsJson stdout is pure JSON' ($o.TrimStart().StartsWith('{'))
    # ---- WP6: measurement tools (Get-FootprintReport.ps1, crash-dump section of Get-MemoryPressure.ps1) ----
    # The comparison, the path rules and the argument checks run on saved report files (no system reads);
    # one live run (read-only) proves -Baseline writes a loadable file. Nothing on the system is changed.
    $fpTool = Join-Path $PSScriptRoot '..\Get-FootprintReport.ps1'
    $mpTool = Join-Path $PSScriptRoot '..\Get-MemoryPressure.ps1'
    # Windows PowerShell 5.1 wraps redirected stderr at 80 columns, so Err has all whitespace removed: match it without spaces.
    function RunTool([string]$Tool, [string[]]$ToolArgs) {
        $ErrorActionPreference = 'Continue'
        $errFile = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-err-" + [guid]::NewGuid().ToString('N') + '.txt')
        $tmpFiles.Add($errFile)
        $o = (& $host_ -NoProfile -ExecutionPolicy Bypass -File $Tool @ToolArgs 2>$errFile | Out-String)
        $c = $LASTEXITCODE
        [pscustomobject]@{ Code = $c; Out = $o; Err = $(if (Test-Path $errFile) { (Get-Content $errFile -Raw) -replace '\s', '' } else { '' }) }
    }
    $r = RunTool $fpTool @('-SelfTest')
    Check 'footprint: -SelfTest passes' ($r.Code -eq 0 -and $r.Out -match 'SELFTEST PASSED')
    $r = RunTool $mpTool @('-SelfTest')
    Check 'memory pressure: -SelfTest passes (includes the crash-dump vs pagefile checks)' ($r.Code -eq 0 -and $r.Out -match 'SELFTEST PASSED' -and $r.Out -match 'crash dump')

    $fpDir = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTestFp-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $fpDir)
    $tmpFiles.Add($fpDir)
    function New-FpReport([string]$Name, [hashtable]$Over) {
        $rep = [ordered]@{
            schemaVersion = 1; timestamp = '2026-10-17T10:00:00.0000000+02:00'; isAdmin = $true
            os = [ordered]@{ build = '26100'; edition = 'Professional' }
            disk = [ordered]@{ usedBytes = 100GB; freeBytes = 150GB; totalBytes = 250GB }
            componentStore = [ordered]@{ status = 'ok'; actualBytes = 8GB; explorerReportedBytes = 9GB; reclaimableBytes = 2GB }
            systemFiles = [ordered]@{ hiberfilBytes = 6GB; pagefileBytes = 3GB; swapfileBytes = 256MB }
            reservedStorage = 'enabled'; compactOs = 'not-compact'
            appx = [ordered]@{ userCount = 80; provisionedCount = 90 }
            processes = [ordered]@{ count = 200 }; services = [ordered]@{ total = 300; running = 120; automatic = 90 }
            startupItems = [ordered]@{ count = 12 }; memory = [ordered]@{ usedBytes = 10GB; commitBytes = 14GB }
        }
        foreach ($k in $Over.Keys) { $rep[$k] = $Over[$k] }
        $f = Join-Path $fpDir $Name
        [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $rep -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $f
    }
    $fpBefore = New-FpReport 'before.json' @{}
    $fpAfter = New-FpReport 'after.json' @{
        disk = [ordered]@{ usedBytes = 90GB; freeBytes = 160GB; totalBytes = 250GB }
        componentStore = [ordered]@{ status = 'ok'; actualBytes = 6GB; explorerReportedBytes = 7GB; reclaimableBytes = 0 }
        systemFiles = [ordered]@{ hiberfilBytes = 0; pagefileBytes = 3GB; swapfileBytes = 256MB }
        compactOs = 'compact'; processes = [ordered]@{ count = 150 }
    }
    $r = RunTool $fpTool @('-Compare', $fpBefore, '-With', $fpAfter, '-AsJson')
    $cj = try { $r.Out | ConvertFrom-Json } catch { $null }
    Check 'footprint: -Compare -With -AsJson stdout is pure JSON, exit 0' ($r.Code -eq 0 -and $cj -and $r.Out.TrimStart().StartsWith('{'))
    $mrow = { param($k) @($cj.metrics | Where-Object { $_.key -eq $k })[0] }
    Check 'footprint: used space delta -10 GB is better' ($cj -and (& $mrow 'disk.usedBytes').delta -eq -10GB -and (& $mrow 'disk.usedBytes').verdict -eq 'better')
    Check 'footprint: hiberfil 6 GB -> 0 and processes 200 -> 150' ($cj -and (& $mrow 'systemFiles.hiberfilBytes').after -eq 0 -and (& $mrow 'processes.count').delta -eq -50)
    Check 'footprint: Compact OS change is reported' ($cj -and @($cj.states | Where-Object { $_.key -eq 'compactOs' -and $_.changed }).Count -eq 1)
    $r = RunTool $fpTool @('-Compare', $fpBefore, '-With', $fpAfter)
    Check 'footprint: human comparison prints and exits 0' ($r.Code -eq 0 -and $r.Out -match 'Footprint comparison' -and $r.Out -match 'better')
    $r = RunTool $fpTool @('-Baseline', (Join-Path $env:SystemRoot 'Temp\dk-footprint-test.json'))
    Check 'footprint: -Baseline under the Windows folder is refused and nothing is written' ($r.Code -eq 1 -and $r.Err -match 'refusing' -and -not (Test-Path (Join-Path $env:SystemRoot 'Temp\dk-footprint-test.json')))
    $r = RunTool $fpTool @('-Baseline', (Join-Path $fpDir 'x.json'), '-Compare', $fpBefore)
    Check 'footprint: -Baseline with -Compare is refused' ($r.Code -eq 1 -and -not (Test-Path (Join-Path $fpDir 'x.json')))
    $r = RunTool $fpTool @('-With', $fpAfter)
    Check 'footprint: -With without -Compare is refused' ($r.Code -eq 1)
    $r = RunTool $fpTool @('-Compare', (Join-Path $fpDir 'missing.json'), '-With', $fpAfter)
    Check 'footprint: -Compare with a missing file fails with exit 1' ($r.Code -eq 1 -and $r.Err -match 'notfound')
    $fpNew = New-FpReport 'newer.json' @{ schemaVersion = 99 }
    $r = RunTool $fpTool @('-Compare', $fpNew, '-With', $fpAfter)
    Check 'footprint: a report with a newer schema is refused' ($r.Code -eq 1 -and $r.Err -match 'newer')
    $notReport = Join-Path $fpDir 'other.json'
    [IO.File]::WriteAllText($notReport, '{ "hello": 1 }')
    $r = RunTool $fpTool @('-Compare', $notReport, '-With', $fpAfter)
    Check 'footprint: a JSON file that is not a footprint report is refused' ($r.Code -eq 1 -and $r.Err -match 'notafootprintreport')
    # one live, read-only run: -Baseline writes a loadable report; a second run needs -Force
    $live = Join-Path $fpDir 'live\base.json'
    $r = RunTool $fpTool @('-Baseline', $live)
    $lj = try { Get-Content -LiteralPath $live -Raw | ConvertFrom-Json } catch { $null }
    Check 'footprint: live -Baseline writes a loadable report (creates the parent folder)' ($r.Code -eq 0 -and $lj -and $lj.schemaVersion -eq 1 -and $lj.disk.totalBytes -gt 0 -and $lj.processes.count -gt 0)
    $r = RunTool $fpTool @('-Baseline', $live)
    Check 'footprint: -Baseline over an existing file needs -Force' ($r.Code -eq 1 -and $r.Err -match 'alreadyexists')
    $r = RunTool $fpTool @('-Baseline', $live, '-Force', '-AsJson')
    $lj2 = try { $r.Out | ConvertFrom-Json } catch { $null }
    Check 'footprint: -Baseline -Force -AsJson keeps stdout pure JSON' ($r.Code -eq 0 -and $lj2 -and $lj2.schemaVersion -eq 1)
    $r = RunTool $fpTool @('-Compare', $live, '-With', $live, '-AsJson')
    $lc = try { $r.Out | ConvertFrom-Json } catch { $null }
    Check 'footprint: a live report compared with itself shows no change' ($r.Code -eq 0 -and $lc -and @($lc.metrics | Where-Object { $_.verdict -in 'better', 'worse' }).Count -eq 0)
    Check 'footprint: running it never created the DebloatKit state folder' (-not (Test-Path (Join-Path $env:ProgramData 'DebloatKit')))

    # ======================= WP7: GUI (per-row toggle, profiles, drift tab, footprint tab) =======================
    # profiles.json is checked against the real catalog; the GUI's own -SelfTest runs (reads, -WhatIf, fixtures and temp files only);
    # a sandbox -SelfTest runs the GUI's revert / drift / re-apply command paths against the throwaway key and the fake environment.
    $guiScript = Join-Path $PSScriptRoot '..\DebloatKit-GUI.ps1'
    $profFile = Join-Path $PSScriptRoot '..\profiles.json'
    $laBefore = Test-Path (Join-Path $env:LOCALAPPDATA 'DebloatKit')
    $pdBefore7 = Test-Path (Join-Path $env:ProgramData 'DebloatKit')
    Write-Host 'WP7: profiles.json against the real catalog'
    $realCat7 = @((Get-Content (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json).tweaks)
    $cat7 = @{}; foreach ($t in $realCat7) { $cat7[$t.id] = $t }
    $profDoc = Get-Content $profFile -Raw | ConvertFrom-Json
    $appxDoc = Get-Content (Join-Path $PSScriptRoot '..\appx-profiles.json') -Raw | ConvertFrom-Json
    Check 'profiles.json: version 1, four profiles, at least five questions with an id, a text and yes / no effects' ($profDoc.schemaVersion -eq 1 -and @($profDoc.profiles.PSObject.Properties).Count -eq 4 -and @($profDoc.questions).Count -ge 5 -and @($profDoc.questions | Where-Object { -not $_.id -or -not $_.text -or $null -eq $_.yes -or $null -eq $_.no }).Count -eq 0)
    Check 'profiles.json: every profile maps to an optionProfile of appx-profiles.json, answers cover every question' (@($profDoc.profiles.PSObject.Properties | Where-Object { $pp = $_; $null -eq $appxDoc.optionProfiles.PSObject.Properties[$pp.Value.optionProfile] -or @($profDoc.questions | Where-Object { $null -eq $pp.Value.answers.PSObject.Properties[$_.id] }).Count -gt 0 }).Count -eq 0)
    $ids7 = New-Object System.Collections.Generic.List[string]
    foreach ($p in $profDoc.profiles.PSObject.Properties) { foreach ($id in @($appxDoc.optionProfiles.($p.Value.optionProfile).tweakIds)) { $ids7.Add([string]$id) } }
    foreach ($q in $profDoc.questions) { foreach ($side in 'yes', 'no') { foreach ($k in 'addIds', 'removeIds') { $e = $q.$side; if ($e -and $e.PSObject.Properties[$k]) { foreach ($id in @($e.$k)) { $ids7.Add([string]$id) } } } } }
    $miss7 = @($ids7 | Select-Object -Unique | Where-Object { -not $cat7.ContainsKey($_) })
    Check 'profiles.json: every tweak id a profile or question uses exists in the catalog' ($miss7.Count -eq 0)
    $bad7 = @($ids7 | Select-Object -Unique | Where-Object { $cat7.ContainsKey($_) -and ($cat7[$_].preset -eq 'never-default' -or $cat7[$_].risk -eq 'reduces-security') })
    Check 'profiles.json: no never-default and no reduces-security tweak in any profile or question' ($bad7.Count -eq 0)
    Check 'profiles.json: work-managed plans nothing outside the safe preset and no app removal (its answers force app removal off and remove the extras)' ($profDoc.profiles.'work-managed'.minEffectiveness -ge 2 -and $profDoc.profiles.'work-managed'.answers.work -eq $true -and $profDoc.profiles.'work-managed'.answers.appx -eq $false -and $profDoc.questions[0].yes.force.appx -eq $false -and @($profDoc.questions[0].yes.removeIds) -contains 'disk-component-cleanup')

    Write-Host 'WP7: DebloatKit-GUI.ps1 -SelfTest (real engine -List / -Drift / -Revert -WhatIf, footprint report, fixtures)'
    $ErrorActionPreference = 'Continue'
    $gOut = & $host_ -NoProfile -ExecutionPolicy Bypass -File $guiScript -SelfTest 2>&1 | Out-String
    $gCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'GUI -SelfTest: exit 0, SELFTEST PASSED, no failed check' ($gCode -eq 0 -and $gOut -match 'SELFTEST PASSED' -and $gOut -notmatch '\n\s+FAIL ')
    Check 'GUI -SelfTest ran the WP7 checks (tabs, toggle, profiles, drift, footprint)' ($gOut -match 'WP7 checks' -and $gOut -match "XAML element 'tabs' present" -and $gOut -match 'revert command: -Revert' -and $gOut -match 'Profiles tab preselects' -and $gOut -match 'Drift tab shows the rows' -and $gOut -match 'Footprint tab header names the report')
    Check 'GUI -SelfTest: did not create the state folder or the footprint folder' ((Test-Path (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdBefore7 -and (Test-Path (Join-Path $env:LOCALAPPDATA 'DebloatKit')) -eq $laBefore)

    Write-Host 'WP7: the GUI revert / drift / re-apply command paths against the sandbox (throwaway key, fake environment)'
    W5Reset; W5Env
    $r = W5Apply @('-Only', 'w5-a,w5-b,w5-multi')
    Check 'sandbox setup: apply exit 0 (A=1, B=2)' ($r.Code -eq 0 -and (Val $w5 'A') -eq 1 -and (Val $w5 'B') -eq 2)
    Set-ItemProperty -LiteralPath $w5 -Name B -Value 99
    $ErrorActionPreference = 'Continue'
    $sbOut = & $host_ -NoProfile -ExecutionPolicy Bypass -File $guiScript -SelfTest -CatalogPath $wp5 -StateDir $stateDir -TestEnvironment $envFile -ProfilesPath $wp4Prof 2>&1 | Out-String
    $sbCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'GUI sandbox -SelfTest: exit 0 and SELFTEST PASSED (revert preview, drift rows, re-apply preview, real revert)' ($sbCode -eq 0 -and $sbOut -match 'SELFTEST PASSED' -and $sbOut -match 'sandbox self-test')
    if ($sbCode -ne 0) { Write-Host $sbOut }
    Check 'sandbox: the GUI-built -Revert restored A to its value from before the apply (5) and left the hand-changed B alone' ((Val $w5 'A') -eq 5 -and (Val $w5 'B') -eq 99)
    Check 'sandbox: the revert marked only w5-a inside the snapshot' ((RevMarks 'w5-a') -eq 1 -and (RevMarks 'w5-b') -eq 0)
    Check 'WP7 real system: no tweak, snapshot or footprint file written outside the throwaway key and the temp state folder' ((Test-Path (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdBefore7 -and (Test-Path (Join-Path $env:LOCALAPPDATA 'DebloatKit')) -eq $laBefore)
    W5Reset
    if (Test-Path $w5) { Remove-Item $w5 -Recurse -Force }

    Write-Host 'WP8: repo root launchers (retired clear_ram_loop.bat, revert.bat, run_invisible.vbs, setup.ps1, README.md), no-change modes only'
    $rootDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $guiPath = Join-Path $rootDir 'DebloatKit\DebloatKit-GUI.ps1'
    $txt = @{}
    foreach ($n in 'clear_ram_loop.bat', 'revert.bat', 'run_invisible.vbs', 'setup.ps1', 'README.md') { $txt[$n] = Get-Content -LiteralPath (Join-Path $rootDir $n) -Raw }
    # Code lines only: drop batch rem / :: comment lines, VBS and PowerShell comments before scanning for forbidden commands.
    $code = @{}
    foreach ($n in 'clear_ram_loop.bat', 'run_invisible.vbs', 'setup.ps1') {
        $code[$n] = (($txt[$n] -split "`r?`n") | Where-Object { $_ -notmatch ('^\s*(rem\b|::|#|' + [char]39 + ')') }) -join "`n"
    }
    $ps1Err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'setup.ps1'), [ref]$null, [ref]$ps1Err)
    Check 'setup.ps1 parses' (-not $ps1Err)

    $retired = $code['clear_ram_loop.bat']
    Check 'clear_ram_loop.bat: no sc config / sc stop, no registry or schtasks change' ($retired -notmatch '(?im)\bsc(\.exe)?\s+(config|stop|start)\b' -and $retired -notmatch '(?i)\breg(\.exe)?\s+(add|delete)\b' -and $retired -notmatch '(?i)\bschtasks\b')
    Check 'clear_ram_loop.bat: no loop, no taskkill, no temp purge, no DNS flush, no RAMMap, no working-set trim' ($retired -notmatch '(?i):loop|goto\s+loop|taskkill|\bdel\s|flushdns|rammap|MinWorkingSet|timeout\s')
    Check 'clear_ram_loop.bat: does not disable anything (no "start= disabled", no NoAutoUpdate)' ($retired -notmatch '(?i)start=\s*disabled|NoAutoUpdate|AUOptions')
    Check 'clear_ram_loop.bat: launches the GUI and points to revert.bat and Get-MemoryPressure.ps1' ($retired -match 'DebloatKit-GUI\.ps1' -and $retired -match 'revert\.bat' -and $retired -match 'Get-MemoryPressure\.ps1')
    $o = (& cmd.exe /c ('"{0}" /noop' -f (Join-Path $rootDir 'clear_ram_loop.bat'))) -join "`n"
    Check 'clear_ram_loop.bat /noop: exit 0, prints the deprecation text and the GUI launch command, starts nothing' ($LASTEXITCODE -eq 0 -and $o -match 'has been retired' -and $o -match '\[noop\] would run: powershell .*-STA -File ".*DebloatKit-GUI\.ps1"')
    Check 'the GUI script the launchers point at exists' (Test-Path -LiteralPath $guiPath)

    $rv = $txt['revert.bat']
    Check 'revert.bat: needs admin rights unless /noop (net session check)' ($rv -match 'net session' -and $rv -match '/noop')
    $o = (& cmd.exe /c ('"{0}" /noop' -f (Join-Path $rootDir 'revert.bat'))) -join "`n"
    Check 'revert.bat /noop: exit 0 and nothing is run (no sc / reg / schtasks output, every action line is prefixed [noop])' ($LASTEXITCODE -eq 0 -and $o -notmatch '(?m)^(SUCCESS|\[SC\]|ERROR:)' -and ([regex]::Matches($o, '(?m)^\[noop\] ')).Count -eq 12)
    Check 'revert.bat /noop: wuauserv demand, UsoSvc delayed-auto, BITS demand (Windows defaults)' ($o -match '\[noop\] sc config wuauserv start= demand' -and $o -match '\[noop\] sc config UsoSvc start= delayed-auto' -and $o -match '\[noop\] sc config bits start= demand')
    Check 'revert.bat /noop: starts the three services' ($o -match '\[noop\] sc start wuauserv' -and $o -match '\[noop\] sc start UsoSvc' -and $o -match '\[noop\] sc start bits')
    Check 'revert.bat /noop: removes NoAutoUpdate, AUOptions and ToastEnabled and re-enables the three tasks' ($o -match 'reg delete ".*WindowsUpdate\\AU" /v NoAutoUpdate /f' -and $o -match 'reg delete ".*WindowsUpdate\\AU" /v AUOptions /f' -and $o -match 'PushNotifications" /v ToastEnabled /f' -and ([regex]::Matches($o, 'schtasks /Change /TN "Microsoft\\Windows\\WindowsUpdate\\(Scheduled Start|sih|sihboot)" /Enable')).Count -eq 3)
    Check 'revert.bat: never disables or adds anything (no "disabled", no /Disable, no reg add)' ($rv -notmatch '(?i)start=\s*disabled|/Disable\b|\breg\s+add\b')

    $vb = $code['run_invisible.vbs']
    Check 'run_invisible.vbs: no elevation, no bat; runs the GUI hidden and STA' ($vb -notmatch '(?i)runas|clear_ram_loop|\.bat' -and $vb -match 'DebloatKit-GUI\.ps1' -and $vb -match '-WindowStyle Hidden' -and $vb -match '-STA')
    if (Get-Command cscript.exe -ErrorAction SilentlyContinue) {
        $o = (& cscript.exe //nologo (Join-Path $rootDir 'run_invisible.vbs') /check) -join "`n"
        Check 'run_invisible.vbs /check: exit 0, prints the GUI command, starts nothing' ($LASTEXITCODE -eq 0 -and $o -match 'would run: powershell\.exe .*-File ".*DebloatKit-GUI\.ps1"')
    } else { Write-Host '  SKIP  run_invisible.vbs /check (cscript.exe not found)' -ForegroundColor Yellow }

    $su = $code['setup.ps1']
    Check 'setup.ps1: does not change the execution policy, supports -WhatIf, launches the GUI' ($su -notmatch '(?i)Set-ExecutionPolicy' -and $txt['setup.ps1'] -match 'SupportsShouldProcess' -and $su -match 'DebloatKit-GUI\.ps1' -and $su -match 'Start-Process')
    $ErrorActionPreference = 'Continue'
    $o = (& $host_ -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rootDir 'setup.ps1') -WhatIf 2>&1) | Out-String
    $suCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Check 'setup.ps1 -WhatIf: exit 0, plans Unblock-File and exactly one Start-Process of the GUI, runs nothing' ($suCode -eq 0 -and $o -match 'Unblock-File' -and ([regex]::Matches($o, 'Start the DebloatKit GUI')).Count -eq 1 -and $o -match 'DebloatKit-GUI\.ps1')

    $rd = $txt['README.md']
    Check 'README.md: no advice to pause Defender or real-time protection' ($rd -notmatch '(?i)pause (real-time|windows defender|defender)|disable defender|turn off defender|temporarily pause')
    Check 'README.md: describes DebloatKit, the GUI, the three monitors, the safety model and both research docs' ($rd -match 'DebloatKit-GUI\.ps1' -and $rd -match 'Get-MemoryPressure\.ps1' -and $rd -match 'Get-BootReport\.ps1' -and $rd -match 'Get-FootprintReport\.ps1' -and $rd -match '(?m)^## Safety model' -and $rd -match 'DebloatKit/RESEARCH\.md' -and $rd -match 'docs/PERFORMANCE-RESEARCH\.md')
    Check 'README.md: marks the legacy scripts as retired, keeps revert.bat, documents the RAMMap binaries' ($rd -match '(?m)^## Legacy scripts \(retired\)' -and $rd -match 'revert\.bat' -and $rd -match '(?m)^### RAMMap binaries')
    Check 'README.md: no longer advertises the kill list, the loop or disabling Windows Update as a feature' ($rd -notmatch '(?i)Processes It Kills|Loops automatically|Disables Windows Updates')
    $badLinks = @([regex]::Matches($rd, '\]\(((?!http)[^)#]+)\)') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $rootDir $_.Groups[1].Value)) })
    Check 'README.md: relative links point at files that exist' ($badLinks.Count -eq 0)
    Check 'WP8: the launcher tests created no state folder' ((Test-Path (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdBefore7)


    Write-Host 'WP9: offline image builder (DebloatKit-Image.ps1), plan and refusal modes only; DISM is never run'
    $imgScript = Join-Path $PSScriptRoot '..\DebloatKit-Image.ps1'
    $imgWork = Join-Path ([IO.Path]::GetTempPath()) ('DbkImgNone-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $imgWorkOk = 'C:\DbkImgPlanNone' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $fakeIso = 'C:\NoSuchFolder\Win11_Fake.iso'
    $fakeHash = ('ab' * 32)
    function RunImage([string[]]$ImgArgs) {
        $ErrorActionPreference = 'Continue'
        $errFile = Join-Path ([IO.Path]::GetTempPath()) ("DebloatKitTest-err-" + [guid]::NewGuid().ToString('N') + '.txt')
        $out = (& $host_ -NoProfile -ExecutionPolicy Bypass -File $imgScript @ImgArgs 2>$errFile | Out-String)
        $code = $LASTEXITCODE
        $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        $parsed = $null; $ok = $true
        try { $parsed = $out | ConvertFrom-Json } catch { $ok = $false }
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Code = $code; Out = $out; Err = $err; Json = $parsed; Parsed = $ok }
    }
    $imgErr = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $imgScript).Path, [ref]$null, [ref]$imgErr)
    Check 'DebloatKit-Image.ps1 parses' (-not $imgErr)

    $r = RunImage @('-SelfTest')
    Check 'image builder -SelfTest: exit 0, SELFTEST PASSED, no failed check' ($r.Code -eq 0 -and $r.Out -match 'SELFTEST PASSED' -and $r.Out -notmatch '(?m)^FAIL ')
    if ($r.Code -ne 0) { Write-Host $r.Out }
    Check 'image builder -SelfTest ran the mapping, selection, AppX, build, failure and static-scan checks' ($r.Out -match 'map: HKCU Software\\Classes' -and $r.Out -match 'catalog: every safe tweak is either selected or skipped' -and $r.Out -match 'appx: protected, wildcard and kept names' -and $r.Out -match 'build \(default\): the order is' -and $r.Out -match 'failure \(registry write\)' -and $r.Out -match 'static scan: file is ASCII only')

    # the protected AppX list mirrors the engine's
    $engText = Get-Content -LiteralPath $engine -Raw
    $imgText = Get-Content -LiteralPath $imgScript -Raw
    $engBlock = [regex]::Match($engText, '(?s)Appx\s*=\s*\[ordered\]@\{(.*?)\n    \}').Groups[1].Value
    $imgBlock = [regex]::Match($imgText, '(?s)\$script:ProtectedAppx = \[ordered\]@\{(.*?)\n\}').Groups[1].Value
    $engKeys = @([regex]::Matches($engBlock, "(?m)^\s*'([^']+)'\s*=") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $imgKeys = @([regex]::Matches($imgBlock, "(?m)^\s*'([^']+)'\s*=") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Check ("protected AppX list: the image builder's $($imgKeys.Count) entries equal the engine's $($engKeys.Count)") ($engKeys.Count -gt 10 -and (($engKeys -join '|') -eq ($imgKeys -join '|')))

    # -WhatIf -AsJson: the plan is pure JSON, nothing is created
    $r = RunImage @('-WhatIf', '-AsJson', '-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-Index', '6', '-WorkDir', $imgWorkOk)
    Check '-WhatIf -AsJson: exit 0, stdout is valid JSON starting with {' ($r.Code -eq 0 -and $r.Parsed -and $r.Out.TrimStart().StartsWith('{'))
    $pj = $r.Json
    Check '-WhatIf -AsJson: mode plan, steps carry n / phase / description / command, 100+ steps' ($pj.mode -eq 'plan' -and @($pj.steps).Count -gt 100 -and -not (@('n', 'phase', 'description', 'command') | Where-Object { @($pj.steps)[0].PSObject.Properties.Name -notcontains $_ }))
    $cmds = @($pj.steps | ForEach-Object { $_.command })
    Check '-WhatIf: the plan names the ordered DISM and reg steps (export, mount, load, unload, cleanup, commit, final export)' (
        @($cmds | Where-Object { $_ -match '^dism\.exe /Export-Image' }).Count -eq 2 -and @($cmds | Where-Object { $_ -match '^dism\.exe /Mount-Image' }).Count -eq 1 -and
        @($cmds | Where-Object { $_ -match '^reg\.exe load' }).Count -eq @($cmds | Where-Object { $_ -match '^reg\.exe unload' }).Count -and @($cmds | Where-Object { $_ -match '/StartComponentCleanup$' }).Count -eq 1 -and @($cmds | Where-Object { $_ -match '/Unmount-Image .*/Commit$' }).Count -eq 1)
    Check '-WhatIf: component cleanup has no reset, nothing touches WinRE, Defender, Windows Update or servicing, no bypass and no Compact OS by default' (-not ($cmds | Where-Object { $_ -match '(?i)ResetBase|winre|Defender|wuauserv|WaaSMedic|UsoSvc|LabConfig|MoSetup|Compact|autounattend' }))
    Check '-WhatIf: the plan never includes the Store, frameworks or Windows Security in the AppX removals' (-not ($cmds | Where-Object { $_ -match 'Remove-ProvisionedAppxPackage' -and $_ -match '(?i)WindowsStore|VCLibs|UI\.Xaml|NET\.Native|DesktopAppInstaller|SecHealthUI|WebView2|WindowsAppRuntime' }))
    Check '-WhatIf: tweaks are safe-preset registry tweaks only, with reasons for the rest' (@($pj.tweaks.applied).Count -gt 20 -and @($pj.tweaks.skipped).Count -gt 5 -and -not @($pj.tweaks.skipped | Where-Object { -not $_.reason }).Count)
    Check '-WhatIf: warns that the edition is assumed, and reports the missing fake ISO as a blocker' (@($pj.warnings | Where-Object { $_ -match 'assumed' }).Count -eq 1 -and @($pj.blockers | Where-Object { $_ -match 'ISO not found' }).Count -eq 1)
    Check '-WhatIf: the work folder and the output were not created, the engine state folder is untouched' (-not (Test-Path $imgWorkOk) -and (Test-Path (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdBefore7)

    # opt-in flags appear only when asked
    $r = RunImage @('-WhatIf', '-AsJson', '-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-Index', '1', '-WorkDir', $imgWorkOk, '-CompactOS', '-AllowUnsupportedHardware', '-RecoveryEsd', '-AppxProfile', 'minimal', '-ExcludeId', 'ai-copilot-disable')
    $c2 = @($r.Json.steps | ForEach-Object { $_.command })
    Check '-WhatIf with flags: autounattend (Compact), LabConfig / MoSetup and boot.wim index 2 appear' ($r.Code -eq 0 -and @($c2 | Where-Object { $_ -match 'autounattend\.xml.*Compact' }).Count -eq 1 -and @($c2 | Where-Object { $_ -match 'LabConfig' }).Count -ge 10 -and @($c2 | Where-Object { $_ -match 'MoSetup' }).Count -eq 1 -and @($c2 | Where-Object { $_ -match 'boot\.wim /Index:2' }).Count -eq 1)
    Check '-WhatIf with flags: final export is /Compress:recovery into install.esd, warnings name the bypass and the ESD limits' (@($c2 | Where-Object { $_ -match '/Compress:recovery' -and $_ -match 'install\.esd' }).Count -eq 1 -and @($r.Json.warnings | Where-Object { $_ -match 'not guarantee' }).Count -eq 1 -and @($r.Json.warnings | Where-Object { $_ -match 'cannot be serviced' }).Count -eq 1)
    Check '-WhatIf with flags: the minimal AppX profile and -ExcludeId are honoured' ($r.Json.appx.profile -eq 'minimal' -and @($r.Json.tweaks.applied | Where-Object { $_.id -eq 'ai-copilot-disable' }).Count -eq 0 -and @($r.Json.tweaks.skipped | Where-Object { $_.id -eq 'ai-copilot-disable' }).Count -eq 1)
    $r = RunImage @('-WhatIf', '-AsJson', '-IsoPath', $fakeIso, '-SkipHashCheck', '-Index', '1', '-WorkDir', $imgWorkOk, '-AppxProfile', 'none', '-SkipCleanup', '-EditionHint', 'Enterprise')
    $c3 = @($r.Json.steps | ForEach-Object { $_.command })
    Check '-WhatIf (-SkipHashCheck, AppX none, -SkipCleanup, Enterprise): no hash step, no AppX step, no cleanup, AllowTelemetry applied, unverified warning' ($r.Code -eq 0 -and -not ($c3 | Where-Object { $_ -match 'Get-FileHash.*Win11_Fake|Remove-ProvisionedAppxPackage|StartComponentCleanup' }) -and @($r.Json.tweaks.applied | Where-Object { $_.id -eq 'telemetry-allowtelemetry-policy' }).Count -eq 1 -and @($r.Json.warnings | Where-Object { $_ -match 'UNVERIFIED' }).Count -eq 1)
    $r = RunImage @('-WhatIf', '-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-Index', '6', '-WorkDir', $imgWorkOk)
    Check '-WhatIf (human): exit 0, prints the plan header, numbered DISM commands and the tweak summary' ($r.Code -eq 0 -and $r.Out -match 'plan \(-WhatIf\): nothing below was run' -and $r.Out -match '\[image\] export index 6' -and $r.Out -match 'Tweaks applied offline: \d+')

    # refusals: nothing runs, nothing is created
    $r = RunImage @('-IsoPath', $fakeIso, '-Index', '6', '-WorkDir', $imgWork)
    Check 'refusal: a real run with a missing ISO and no hash exits 1 and names both problems' ($r.Code -eq 1 -and $r.Err -match 'ISO not found' -and $r.Err -match 'No ISO hash given')
    $r = RunImage @('-IsoPath', $fakeIso, '-ExpectedSha256', 'notahash', '-Index', '6', '-WorkDir', $imgWork)
    Check 'refusal: a malformed hash is refused' ($r.Code -eq 1 -and $r.Err -match '64 hex')
    $r = RunImage @('-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-Index', '6', '-WorkDir', (Join-Path $env:SystemRoot 'DbkImg'))
    Check 'refusal: a work folder inside the Windows folder is refused' ($r.Code -eq 1 -and $r.Err -match 'Windows folder')
    $r = RunImage @('-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-Index', '6', '-WorkDir', 'C:\Work Space')
    Check 'refusal: a work folder with a space is refused (oscdimg boot data needs a plain path)' ($r.Code -eq 1 -and $r.Err -match 'WorkDir must be a local absolute path')
    $r = RunImage @('-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-WorkDir', $imgWork)
    Check 'refusal: a missing -Index is refused' ($r.Code -eq 1 -and $r.Err -match 'Index is required')
    $r = RunImage @('-IsoPath', $fakeIso, '-ExpectedSha256', $fakeHash, '-Index', '1', '-WorkDir', $imgWork, '-AppxProfile', 'no-such-profile', '-WhatIf')
    Check 'refusal: an unknown AppX profile fails the plan with exit 1' ($r.Code -eq 1 -and ($r.Err -match 'no-such-profile' -or $r.Out -match 'no-such-profile'))
    Check 'WP9: no work folder created by any refusal, no state folder created' (-not (Test-Path $imgWork) -and -not (Test-Path $imgWorkOk) -and (Test-Path (Join-Path $env:ProgramData 'DebloatKit')) -eq $pdBefore7)

    # the catalog and the builder agree: every id the builder applies exists, is safe and has registry steps only
    $cat9 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\tweak-catalog.json') -Raw | ConvertFrom-Json
    $byId9 = @{}; foreach ($t in $cat9.tweaks) { $byId9[[string]$t.id] = $t }
    $r = RunImage @('-WhatIf', '-AsJson', '-IsoPath', $fakeIso, '-SkipHashCheck', '-Index', '1', '-WorkDir', $imgWorkOk, '-IncludeManagedSensitive')
    $ids9 = @($r.Json.tweaks.applied | ForEach-Object { [string]$_.id })
    $bad9 = @($ids9 | Where-Object { -not $byId9.ContainsKey($_) -or $byId9[$_].preset -ne 'safe' -or $byId9[$_].risk -ne 'safe' -or ($byId9[$_].implementation.type -eq 'multi' -and @($byId9[$_].implementation.steps | Where-Object { $_.type -ne 'registry' }).Count) -or ($byId9[$_].implementation.type -ne 'multi' -and $byId9[$_].implementation.type -ne 'registry') })
    Check "builder/catalog: all $($ids9.Count) applied ids exist, are safe-preset, risk safe and registry-only (also with -IncludeManagedSensitive)" ($ids9.Count -gt 30 -and $bad9.Count -eq 0)
    $unv9 = @($ids9 | Where-Object { $byId9[$_].verification -eq 'new-unverified' })
    $skipUnv9 = @($r.Json.tweaks.skipped | Where-Object { $_.reason -match 'use -IncludeUnverified' })
    Check "builder: unverified catalog tweaks are NOT applied by default ($($skipUnv9.Count) skipped with the reason) and options.includeUnverified is false in the manifest" ($unv9.Count -eq 0 -and $skipUnv9.Count -gt 5 -and $r.Json.options.includeUnverified -eq $false)
    $rU = RunImage @('-WhatIf', '-AsJson', '-IsoPath', $fakeIso, '-SkipHashCheck', '-Index', '1', '-WorkDir', $imgWorkOk, '-IncludeManagedSensitive', '-IncludeUnverified')
    $idsU9 = @($rU.Json.tweaks.applied | ForEach-Object { [string]$_.id })
    Check "builder: -IncludeUnverified applies the unverified tweaks too ($($idsU9.Count - $ids9.Count) more) and records it" ($idsU9.Count -gt $ids9.Count -and @($idsU9 | Where-Object { $byId9[$_].verification -eq 'new-unverified' }).Count -gt 0 -and $rU.Json.options.includeUnverified -eq $true)
    Check 'builder: no value on a protected target (update policy, firewall, UAC, SmartScreen, BitLocker, update services) is applied, also with every opt-in' (@($idsU9 | ForEach-Object { $t9 = $byId9[$_]; if ($t9.implementation.type -eq 'multi') { $t9.implementation.steps } else { $t9.implementation } } | Where-Object { $_.path -match '(?i)\\WindowsUpdate(\\AU)?$|\\WindowsFirewall|\\FVE|\\Services\\(wuauserv|UsoSvc|BITS|DoSvc)$|Policies\\System$' -and $_.name -match '(?i)^(NoAutoUpdate|UseWUServer|WUServer|EnableFirewall|EnableLUA|ConsentPromptBehaviorAdmin|EnableSmartScreen|Start|UseAdvancedStartup)$' }).Count -eq 0 -and $idsU9.Count -gt 40)

    Check 'real system: fsutil last-access setting never changed during these tests' ((Get-RealLastAccess) -eq $realBefore)
    Check 'real system: Compact OS, hibernation, reserved storage, power plans, memory compression, 8.3 names, Sleep Study channels and boot menu policy never changed during these tests' ((Get-RealWp3State) -eq $realWp3Before)
} finally {
    if (Test-Path $key) { Remove-Item $key -Recurse -Force }
    if (Test-Path $stateDir) { Remove-Item $stateDir -Recurse -Force }
    if (Test-Path $envFile) { Remove-Item $envFile -Force }
    foreach ($f in $tmpFiles) { if (Test-Path $f) { Remove-Item $f -Recurse -Force -ErrorAction SilentlyContinue } }
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
