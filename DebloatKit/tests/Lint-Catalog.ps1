<#
.SYNOPSIS
    Lints tweak-catalog.json and the engine's handlers (read-only, no admin, changes nothing).

.DESCRIPTION
    Runs DebloatKit.ps1 -Lint -AsJson and prints the findings. Exit code 0 = no errors, 1 = errors.
    Checks: unique ids, schemaVersion, every step type has a handler in the engine, registry path and
    value type rules (HKLM:/HKCU: only, DWord/String, no .DEFAULT hive, no IFEO Debugger), no
    reduces-security / appx / irreversible entry in the safe preset, effectiveness above 1 only with a
    measured figure, managedSkip / appliesTo / migrations well-formed, and that every native handler
    reads back what it writes and undoes to the exact starting state (run against an in-memory fake of
    fsutil / powercfg / compact / dism / wevtutil / bcdedit / MMAgent / execution policy).

.PARAMETER CatalogPath
    Catalog to lint. Default: ..\tweak-catalog.json

.PARAMETER ShowInfo
    Also print the informational findings (for example, command steps the engine always skips).

.PARAMETER SelfTest
    Checks this tool: the real catalog lints clean and the report has the expected fields, and a temporary
    catalog with a deliberate defect (duplicate id) is reported as an error with exit code 1. Changes nothing
    except a temporary file that is deleted again. Exit 0 = pass.
#>
[CmdletBinding()]
param(
    [string]$CatalogPath,
    [switch]$ShowInfo,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\DebloatKit.ps1'
if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot '..\tweak-catalog.json' }
$host_ = if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

if ($SelfTest) {
    $fails = 0
    function Check([string]$Name, [bool]$Ok) { if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green } else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:fails++ } }
    function Invoke-Lint([string]$Cat) {
        $ErrorActionPreference = 'Continue'
        $o = & $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -Lint -AsJson -CatalogPath $Cat 2>$null | Out-String
        $j = $null; try { $j = $o | ConvertFrom-Json } catch { }
        [pscustomobject]@{ Code = $LASTEXITCODE; Json = $j }
    }
    Write-Host 'Lint-Catalog self-test'
    $real = Invoke-Lint $CatalogPath
    Check 'real catalog: engine returns parseable JSON' ($null -ne $real.Json)
    Check 'real catalog: report has errors / warnings / info / findings / tweaks / schemaVersion' ($real.Json -and -not (@('errors', 'warnings', 'info', 'findings', 'tweaks', 'schemaVersion') | Where-Object { $real.Json.PSObject.Properties.Name -notcontains $_ }))
    Check 'real catalog: 0 errors, exit 0' ($real.Json -and $real.Json.errors -eq 0 -and $real.Code -eq 0)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('LintSelfTest-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $one = '{ "id": "dup", "category": "o", "implementation": { "type": "registry", "path": "HKCU:\\Software\\DebloatKitTest", "name": "a", "valueType": "DWord", "value": 1 }, "revert": "snapshot", "risk": "safe", "preset": "safe" }'
        Set-Content -LiteralPath $tmp -Value ('{ "schemaVersion": 2, "tweaks": [ ' + $one + ', ' + $one + ' ] }') -Encoding UTF8
        $bad = Invoke-Lint $tmp
        Check 'defective catalog (duplicate id): reported as an error' ($bad.Json -and $bad.Json.errors -ge 1 -and @($bad.Json.findings | Where-Object { $_.rule -eq 'id' -and $_.severity -eq 'error' }).Count -ge 1)
        Check 'defective catalog: exit code 1' ($bad.Code -eq 1)
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Check 'temporary catalog deleted' (-not (Test-Path -LiteralPath $tmp))
    if ($fails) { Write-Host "SELFTEST FAILED: $fails check(s) failed" -ForegroundColor Red; exit 1 }
    Write-Host 'SELFTEST PASSED' -ForegroundColor Green
    exit 0
}

$ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns a child's stderr into a terminating error
$out = & $host_ -NoProfile -ExecutionPolicy Bypass -File $engine -Lint -AsJson -CatalogPath $CatalogPath 2>&1 | Out-String
$code = $LASTEXITCODE
try { $doc = $out | ConvertFrom-Json } catch { Write-Host "Lint did not return JSON (exit $code):`n$out" -ForegroundColor Red; exit 1 }

$shown = @($doc.findings | Where-Object { $ShowInfo -or $_.severity -ne 'info' })
if ($shown.Count) { $shown | Select-Object severity, tweakId, rule, message | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
$msg = 'Lint-Catalog: {0} tweak(s), {1} migration(s), schemaVersion {2}, {3} error(s), {4} warning(s), {5} info' -f $doc.tweaks, $doc.migrations, $doc.schemaVersion, $doc.errors, $doc.warnings, $doc.info
if ($doc.errors) { Write-Host $msg -ForegroundColor Red; exit 1 }
Write-Host $msg -ForegroundColor Green
exit 0
