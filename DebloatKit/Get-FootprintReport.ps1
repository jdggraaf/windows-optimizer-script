<#
.SYNOPSIS
    Read-only footprint report: disk, component store, system files, AppX, processes, services, startup items.

.DESCRIPTION
    Turns "it feels lighter" into numbers. Run it before and after a DebloatKit run (or any other change),
    save the first report with -Baseline and diff against it with -Compare. It reads:
      1. Disk: total / used / free of the system drive.
      2. Component store (WinSxS): with -Deep and an elevated prompt, the real figures from
         DISM /Online /Cleanup-Image /AnalyzeComponentStore (read-only analysis: Explorer-reported size,
         actual size, backups and disabled features = the reclaimable part). Without -Deep or without
         elevation the section says why it was skipped; the folder is never walked (hard links make
         that number wrong).
      3. System files: hiberfil.sys, pagefile.sys (all configured pagefiles), swapfile.sys sizes.
      4. Reserved storage state, Compact OS state (compact.exe query, read-only).
      5. AppX: installed packages for the current user, and provisioned packages (needs elevation).
      6. Running process count, service count (total / running / automatic), startup entries
         (Run / RunOnce values and Startup-folder files; not the enabled state, see Get-BootReport.ps1).
      7. Memory in use and commit charge, after an optional -SettleSeconds wait.

    The tool is READ-ONLY. It changes no setting, service, task, package or file on the system. The only
    file it can write is the baseline JSON given by -Baseline, at a path you choose (never under the
    Windows folder, and an existing file is only replaced with -Force).

    Works on Windows PowerShell 5.1 and PowerShell 7. Kept ASCII-only on purpose.

.PARAMETER Baseline
    Save this report as JSON at the given path (parent folder is created if missing).

.PARAMETER Force
    With -Baseline: replace an existing file.

.PARAMETER Compare
    Path of an earlier report (a -Baseline file). Prints the differences between it and the current
    system, or between it and the report given by -With.

.PARAMETER With
    With -Compare: a second saved report to compare against instead of measuring the system now.
    No system reads are done in that case.

.PARAMETER Deep
    Also run DISM /Online /Cleanup-Image /AnalyzeComponentStore (takes about a minute, needs elevation).

.PARAMETER SettleSeconds
    Wait this many seconds (0-600, default 0) before measuring, so memory figures are taken at idle.

.PARAMETER AsJson
    Write only JSON to stdout (the report, or the comparison with -Compare).

.PARAMETER SelfTest
    No system reads: tests the parsers, the formatting and the comparison and scans this file for
    forbidden write commands. Prints SELFTEST PASSED or SELFTEST FAILED; exit 0 or 1.

.EXAMPLE
    .\Get-FootprintReport.ps1 -Deep -Baseline D:\Notes\before.json

.EXAMPLE
    .\Get-FootprintReport.ps1 -Deep -Compare D:\Notes\before.json
#>
[CmdletBinding()]
param(
    [string]$Baseline,
    [switch]$Force,
    [string]$Compare,
    [string]$With,
    [switch]$Deep,
    [ValidateRange(0, 600)][int]$SettleSeconds = 0,
    [switch]$AsJson,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:SchemaVersion = 1

# ---------------------------------------------------------------- pure helpers (no system access)

function Write-Diag {
    # Diagnostics go to stderr so -AsJson keeps stdout clean.
    param([string]$Message)
    [Console]::Error.WriteLine('WARNING: ' + $Message)
}

# '7.64 GB' / '7,64 GB' / '1,234.5 MB' / '512 bytes' -> bytes (long) or $null
function ConvertTo-DismBytes {
    param([string]$Number, [string]$Unit)
    $n = $Number.Trim()
    $hasDot = $n.Contains('.'); $hasComma = $n.Contains(',')
    if ($hasDot -and $hasComma) {
        if ($n.LastIndexOf('.') -gt $n.LastIndexOf(',')) { $n = $n.Replace(',', '') } else { $n = $n.Replace('.', '').Replace(',', '.') }
    }
    elseif ($hasComma) {
        if ($n -match ',\d{1,2}$') { $n = $n.Replace(',', '.') } else { $n = $n.Replace(',', '') }
    }
    $d = 0.0
    if (-not [double]::TryParse($n, [System.Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $null }
    $mult = switch -Regex ($Unit.ToLowerInvariant()) {
        '^bytes?$' { 1.0 }
        '^kb$' { 1KB }
        '^mb$' { 1MB }
        '^gb$' { 1GB }
        '^tb$' { 1TB }
        default { $null }
    }
    if ($null -eq $mult) { return $null }
    return [long][math]::Round($d * $mult)
}

# Parses the text of DISM /AnalyzeComponentStore. The labels are localized, so the five size lines are read by
# position (Explorer reported, actual, shared with Windows, backups and disabled features, cache and temporary data).
function ConvertFrom-ComponentStoreText {
    param([string]$Text)
    $sizes = New-Object System.Collections.Generic.List[long]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match ':\s*([\d.,]+)\s*(bytes|KB|MB|GB|TB)\s*$') {
            $b = ConvertTo-DismBytes -Number $Matches[1] -Unit $Matches[2]
            if ($null -ne $b) { $sizes.Add($b) }
        }
    }
    $rec = $null
    # Best effort: this label is read in English only, so cleanupRecommended stays null on other Windows languages.
    if ($Text -match '(?im)Cleanup Recommended\s*:\s*(Yes|No)\s*$') { $rec = ($Matches[1] -eq 'Yes') }
    $at = { param([int]$i) if ($sizes.Count -gt $i) { return $sizes[$i] } else { return $null } }
    $r = [ordered]@{
        explorerReportedBytes = & $at 0
        actualBytes           = & $at 1
        sharedBytes           = & $at 2
        reclaimableBytes      = & $at 3
        cacheBytes            = & $at 4
        cleanupRecommended    = $rec
    }
    $r['parsed'] = ($sizes.Count -ge 4)
    return $r
}

function Format-Bytes {
    param($Bytes, [switch]$Signed)
    if ($null -eq $Bytes) { return 'n/a' }
    $b = [double]$Bytes
    $a = [math]::Abs($b)
    $sign = if ($b -lt 0) { '-' } elseif ($Signed -and $b -gt 0) { '+' } else { '' }
    if ($a -ge 1GB) { return $sign + ($a / 1GB).ToString('0.00', $script:Inv) + ' GB' }
    if ($a -ge 1MB) { return $sign + ($a / 1MB).ToString('0.0', $script:Inv) + ' MB' }
    if ($a -ge 1KB) { return $sign + ($a / 1KB).ToString('0', $script:Inv) + ' KB' }
    return $sign + $a.ToString('0', $script:Inv) + ' B'
}

# Reads 'a.b' from a PSCustomObject (a report round-tripped through JSON); $null when any part is missing.
function Get-ReportValue {
    param($Report, [string]$Path)
    $cur = $Report
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $p = $cur.PSObject.Properties[$part]
        if ($null -eq $p) { return $null }
        $cur = $p.Value
    }
    return $cur
}

# The numeric metrics of a report. Good = which direction counts as better.
function Get-FootprintMetricDefs {
    return @(
        @{ Key = 'disk.usedBytes';                   Label = 'System drive used';             Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'disk.freeBytes';                   Label = 'System drive free';             Kind = 'bytes'; Good = 'higher' },
        @{ Key = 'componentStore.actualBytes';       Label = 'WinSxS actual size';            Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'componentStore.explorerReportedBytes'; Label = 'WinSxS as Explorer reports'; Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'componentStore.reclaimableBytes';  Label = 'WinSxS backups and disabled features'; Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'systemFiles.hiberfilBytes';        Label = 'hiberfil.sys';                  Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'systemFiles.pagefileBytes';        Label = 'pagefile.sys';                  Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'systemFiles.swapfileBytes';        Label = 'swapfile.sys';                  Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'appx.userCount';                   Label = 'AppX packages (current user)';  Kind = 'count'; Good = 'lower' },
        @{ Key = 'appx.provisionedCount';            Label = 'AppX packages (provisioned)';   Kind = 'count'; Good = 'lower' },
        @{ Key = 'processes.count';                  Label = 'Running processes';             Kind = 'count'; Good = 'lower' },
        @{ Key = 'services.total';                   Label = 'Services (total)';              Kind = 'count'; Good = 'lower' },
        @{ Key = 'services.running';                 Label = 'Services (running)';            Kind = 'count'; Good = 'lower' },
        @{ Key = 'services.automatic';               Label = 'Services (automatic start)';    Kind = 'count'; Good = 'lower' },
        @{ Key = 'startupItems.count';               Label = 'Startup entries';               Kind = 'count'; Good = 'lower' },
        @{ Key = 'memory.usedBytes';                 Label = 'RAM in use';                    Kind = 'bytes'; Good = 'lower' },
        @{ Key = 'memory.commitBytes';               Label = 'Commit charge';                 Kind = 'bytes'; Good = 'lower' }
    )
}

# Text states that are compared as a change, not as a number.
function Get-FootprintStateDefs {
    return @(
        @{ Key = 'compactOs';        Label = 'Compact OS' },
        @{ Key = 'reservedStorage';  Label = 'Reserved storage' },
        @{ Key = 'os.build';         Label = 'OS build' },
        @{ Key = 'os.edition';       Label = 'Edition' }
    )
}

function Test-FootprintReport {
    param($Report)
    if ($null -eq $Report) { return 'not a footprint report (empty)' }
    $v = Get-ReportValue $Report 'schemaVersion'
    if ($null -eq $v) { return 'not a footprint report (no schemaVersion)' }
    if ([int]$v -gt $script:SchemaVersion) { return ('report schema {0} is newer than this tool understands ({1})' -f $v, $script:SchemaVersion) }
    if ($null -eq (Get-ReportValue $Report 'timestamp')) { return 'not a footprint report (no timestamp)' }
    return $null
}

# Windows PowerShell 5.1 keeps a JSON date as text, PowerShell 7 turns it into a DateTime; show both the same way.
function Format-Stamp {
    param($Value)
    if ($null -eq $Value) { return '' }
    $d = [datetime]::MinValue
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv) }
    if ([datetime]::TryParse([string]$Value, $script:Inv, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv) }
    return [string]$Value
}

# Differences between two reports (both PSCustomObjects). Returns metric rows, state rows and notes.
function Compare-Footprint {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    $rows = @()
    foreach ($d in Get-FootprintMetricDefs) {
        $b = Get-ReportValue $Before $d.Key
        $a = Get-ReportValue $After $d.Key
        if ($null -eq $b -and $null -eq $a) { continue }
        $delta = $null; $pct = $null; $verdict = 'n/a'
        if ($null -ne $b -and $null -ne $a) {
            $delta = [double]$a - [double]$b
            if ([double]$b -ne 0) { $pct = [math]::Round($delta / [double]$b * 100, 1) }
            if ($delta -eq 0) { $verdict = 'same' }
            elseif (($d.Good -eq 'lower' -and $delta -lt 0) -or ($d.Good -eq 'higher' -and $delta -gt 0)) { $verdict = 'better' }
            else { $verdict = 'worse' }
        }
        $rows += [pscustomobject]@{ key = $d.Key; label = $d.Label; kind = $d.Kind; before = $b; after = $a; delta = $delta; percent = $pct; verdict = $verdict }
    }
    $states = @()
    foreach ($s in Get-FootprintStateDefs) {
        $b = Get-ReportValue $Before $s.Key
        $a = Get-ReportValue $After $s.Key
        if ($null -eq $b -and $null -eq $a) { continue }
        # A state that could not be read ('unknown', for example on a non-English Windows) is not reported as a change.
        $states += [pscustomobject]@{ key = $s.Key; label = $s.Label; before = $b; after = $a; changed = ("$b" -ne "$a" -and "$b" -ne 'unknown' -and "$a" -ne 'unknown') }
    }
    $notes = @()
    $unreadable = @($states | Where-Object { "$($_.before)" -eq 'unknown' -or "$($_.after)" -eq 'unknown' } | ForEach-Object { $_.label })
    if ($unreadable.Count -gt 0) { $notes += ('Could not be read in one report, so no change is claimed: ' + ($unreadable -join ', ') + '.') }
    $bb = Get-ReportValue $Before 'os.build'; $ab = Get-ReportValue $After 'os.build'
    if ($null -ne $bb -and $null -ne $ab -and "$bb" -ne "$ab") {
        $notes += ('OS build changed ({0} -> {1}); size differences may come from the update, not from your changes.' -f $bb, $ab)
    }
    $be = Get-ReportValue $Before 'isAdmin'; $ae = Get-ReportValue $After 'isAdmin'
    if ($null -ne $be -and $null -ne $ae -and [bool]$be -ne [bool]$ae) {
        $notes += 'One report was taken elevated and the other not; provisioned AppX and WinSxS figures exist only in the elevated one.'
    }
    $missing = @($rows | Where-Object { $_.verdict -eq 'n/a' } | ForEach-Object { $_.label })
    if ($missing.Count -gt 0) { $notes += ('Not compared (missing in one report): ' + ($missing -join ', ') + '.') }
    $freed = $rows | Where-Object { $_.key -eq 'disk.usedBytes' } | Select-Object -First 1
    if ($freed -and $null -ne $freed.delta -and $freed.delta -lt 0) { $notes += ('System drive used space went down by ' + (Format-Bytes (-$freed.delta)) + '.') }
    return [pscustomobject]@{
        before  = Format-Stamp (Get-ReportValue $Before 'timestamp')
        after   = Format-Stamp (Get-ReportValue $After 'timestamp')
        metrics = $rows
        states  = $states
        notes   = $notes
    }
}

# A baseline must not be written into the Windows folder; the engine's own state folder is also off limits.
function Test-BaselinePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'empty path' }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return 'invalid path' }
    $bad = @($env:SystemRoot, (Join-Path $env:ProgramData 'DebloatKit')) | Where-Object { $_ }
    foreach ($b in $bad) {
        $bf = [System.IO.Path]::GetFullPath($b).TrimEnd('\') + '\'
        if ($full.StartsWith($bf, [System.StringComparison]::OrdinalIgnoreCase)) { return ('refusing to write under ' + $b) }
    }
    if ($full.EndsWith('\')) { return 'path must be a file, not a folder' }
    return $null
}

# ---------------------------------------------------------------- data collection (read-only)

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs a read-only console tool and returns @{ ExitCode; Output }. Never throws for a non-zero exit.
function Invoke-ReadTool {
    param([string]$File, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        # Both streams are read asynchronously so the timeout also applies to a tool that prints nothing and hangs.
        $errTask = $p.StandardError.ReadToEndAsync()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill() } catch { }; return @{ ExitCode = -1; Output = '' } }
        $p.WaitForExit()
        return @{ ExitCode = $p.ExitCode; Output = ($outTask.Result + $errTask.Result) }
    }
    catch { return @{ ExitCode = -1; Output = '' } }
}

function Get-DiskFootprint {
    $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $di = New-Object System.IO.DriveInfo($drive)
    return [ordered]@{ drive = $drive; totalBytes = $di.TotalSize; freeBytes = $di.AvailableFreeSpace; usedBytes = ($di.TotalSize - $di.AvailableFreeSpace) }
}

function Get-FileBytes {
    param([string]$Path)
    try { $fi = New-Object System.IO.FileInfo($Path); if ($fi.Exists) { return [long]$fi.Length } } catch { }
    return $null
}

function Get-SystemFileFootprint {
    param([string]$Drive)
    $pf = 0L; $pfFound = $false
    try {
        foreach ($u in @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)) {
            $len = Get-FileBytes ([string]$u.Name)
            if ($null -eq $len) { $len = [long]$u.AllocatedBaseSize * 1MB }
            $pf += $len; $pfFound = $true
        }
    } catch { }
    if (-not $pfFound) { $len = Get-FileBytes (Join-Path ($Drive + '\') 'pagefile.sys'); if ($null -ne $len) { $pf = $len; $pfFound = $true } }
    $hib = Get-FileBytes (Join-Path ($Drive + '\') 'hiberfil.sys')
    $swap = Get-FileBytes (Join-Path ($Drive + '\') 'swapfile.sys')
    return [ordered]@{
        hiberfilBytes = if ($null -ne $hib) { $hib } else { 0L }
        pagefileBytes = if ($pfFound) { $pf } else { 0L }
        swapfileBytes = if ($null -ne $swap) { $swap } else { 0L }
    }
}

function Get-ComponentStoreFootprint {
    param([bool]$DeepRequested, [bool]$IsAdmin)
    if (-not $DeepRequested) { return [ordered]@{ status = 'skipped'; note = 'Run with -Deep (elevated) for the WinSxS actual size.' } }
    if (-not $IsAdmin) { return [ordered]@{ status = 'needsElevation'; note = 'DISM /AnalyzeComponentStore needs an elevated prompt.' } }
    $r = Invoke-ReadTool -File 'dism.exe' -Arguments @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore')
    if ($r.ExitCode -ne 0) { return [ordered]@{ status = 'failed'; note = $(if ($r.ExitCode -eq -1) { 'DISM did not finish in time (or could not start); try again after pending servicing is done.' } else { 'DISM exit code ' + $r.ExitCode }) } }
    $p = ConvertFrom-ComponentStoreText -Text $r.Output
    if (-not $p.parsed) { return [ordered]@{ status = 'unparsed'; note = 'DISM output could not be read.' } }
    $p['status'] = 'ok'
    return $p
}

function Get-CompactOsFootprint {
    $r = Invoke-ReadTool -File 'compact.exe' -Arguments @('/CompactOS:query') -TimeoutSeconds 60
    return (ConvertFrom-CompactOsQuery -ExitCode $r.ExitCode -Text $r.Output)
}

# compact /CompactOS:query: exit code 0 = compact, 102 = not compact (the same on every Windows language). The English text is only the
# fallback for any other exit code. Anything else is 'unknown'.
function ConvertFrom-CompactOsQuery {
    param([int]$ExitCode, [string]$Text)
    if ($ExitCode -eq 0) { return 'compact' }
    if ($ExitCode -eq 102) { return 'not-compact' }
    if ($Text -match 'is not in the Compact state') { return 'not-compact' }
    if ($Text -match 'is in the Compact state') { return 'compact' }
    return 'unknown'
}

function Get-ReservedStorageFootprint {
    param([bool]$IsAdmin)
    # Only the live DISM answer counts (English text). The ShippedWithReserves value is what the PC shipped with, not the current
    # state, so it is no fallback: after perf-reserved-storage-off it would still say 'enabled'. Unrecognised text is 'unknown'.
    if (-not $IsAdmin) { return 'unknown' }
    $r = Invoke-ReadTool -File 'dism.exe' -Arguments @('/Online', '/Get-ReservedStorageState') -TimeoutSeconds 120
    if ($r.ExitCode -eq 0) {
        if ($r.Output -match '\bdisabled\b') { return 'disabled' }
        if ($r.Output -match '\benabled\b') { return 'enabled' }
    }
    return 'unknown'
}

function Get-AppxFootprint {
    param([bool]$IsAdmin)
    $userCount = $null; $provCount = $null; $notes = @()
    try { $userCount = @(Get-AppxPackage -ErrorAction Stop).Count } catch { $notes += 'Get-AppxPackage failed: ' + $_.Exception.Message }
    if ($IsAdmin) {
        try {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                # The DISM-backed cmdlet fails in PowerShell 7 ("Class not registered") after a long wait; ask Windows PowerShell.
                $r = Invoke-ReadTool -File "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile', '-NonInteractive', '-Command', '@(Get-AppxProvisionedPackage -Online -ErrorAction Stop).Count')
                $n = 0
                if ($r.ExitCode -eq 0 -and [int]::TryParse($r.Output.Trim(), [ref]$n)) { $provCount = $n } else { $notes += 'Provisioned package count failed in Windows PowerShell.' }
            }
            else { $provCount = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop).Count }
        }
        catch { $notes += 'Get-AppxProvisionedPackage failed: ' + $_.Exception.Message }
    }
    else { $notes += 'Provisioned packages need an elevated prompt.' }
    return [ordered]@{ userCount = $userCount; provisionedCount = $provCount; notes = $notes }
}

function Get-StartupEntryCount {
    $n = 0
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($k in $keys) {
        try { if (Test-Path -LiteralPath $k) { $n += @((Get-Item -LiteralPath $k).GetValueNames() | Where-Object { $_ }).Count } } catch { }
    }
    foreach ($f in 'Startup', 'CommonStartup') {
        try {
            $dir = [Environment]::GetFolderPath($f)
            if ($dir -and (Test-Path -LiteralPath $dir)) { $n += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop | Where-Object { $_.Extension -in '.lnk', '.exe' }).Count }
        } catch { }
    }
    return $n
}

function Get-FootprintReport {
    param([bool]$DeepRequested, [int]$Settle)
    if ($Settle -gt 0) { Start-Sleep -Seconds $Settle }
    $admin = Test-IsAdmin
    $disk = Get-DiskFootprint
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $svc = @(Get-CimInstance -ClassName Win32_Service)
    $usedRam = ([double]$os.TotalVisibleMemorySize - [double]$os.FreePhysicalMemory) * 1KB
    $commit = ([double]$os.TotalVirtualMemorySize - [double]$os.FreeVirtualMemory) * 1KB
    $ed = $null
    try { $ed = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID } catch { }
    $report = [ordered]@{
        schemaVersion  = $script:SchemaVersion
        timestamp      = (Get-Date).ToString('o')
        isAdmin        = $admin
        deep           = $DeepRequested
        settleSeconds  = $Settle
        os             = [ordered]@{ build = [string]$os.BuildNumber; edition = $ed; caption = [string]$os.Caption }
        disk           = $disk
        componentStore = Get-ComponentStoreFootprint -DeepRequested $DeepRequested -IsAdmin $admin
        systemFiles    = Get-SystemFileFootprint -Drive $disk.drive
        reservedStorage = Get-ReservedStorageFootprint -IsAdmin $admin
        compactOs      = Get-CompactOsFootprint
        appx           = Get-AppxFootprint -IsAdmin $admin
        processes      = [ordered]@{ count = @(Get-Process).Count }
        services       = [ordered]@{
            total = $svc.Count
            running = @($svc | Where-Object { $_.State -eq 'Running' }).Count
            automatic = @($svc | Where-Object { $_.StartMode -eq 'Auto' }).Count
        }
        startupItems   = [ordered]@{ count = Get-StartupEntryCount }
        memory         = [ordered]@{ usedBytes = [long]$usedRam; commitBytes = [long]$commit }
    }
    # Round-trip through JSON so a live report and a loaded one have the same shape.
    return (ConvertTo-Json -InputObject $report -Depth 6 | ConvertFrom-Json)
}

# ---------------------------------------------------------------- output

function Write-FootprintHuman {
    param($R)
    Write-Host ('Footprint report  {0}  (build {1}, {2})' -f (Format-Stamp $R.timestamp), $R.os.build, $(if ($R.isAdmin) { 'elevated' } else { 'not elevated' }))
    Write-Host ('System drive {0}  used {1} of {2}, free {3}' -f $R.disk.drive, (Format-Bytes $R.disk.usedBytes), (Format-Bytes $R.disk.totalBytes), (Format-Bytes $R.disk.freeBytes))
    $c = $R.componentStore
    if ($c.status -eq 'ok') {
        Write-Host ('WinSxS             actual {0}, Explorer reports {1}, backups and disabled features {2}{3}' -f (Format-Bytes $c.actualBytes), (Format-Bytes $c.explorerReportedBytes), (Format-Bytes $c.reclaimableBytes),
            $(if ($null -ne $c.cleanupRecommended) { ', cleanup recommended: ' + $(if ($c.cleanupRecommended) { 'yes' } else { 'no' }) } else { '' }))
    }
    else { Write-Host ('WinSxS             {0}: {1}' -f $c.status, $c.note) }
    Write-Host ('hiberfil.sys       {0}' -f (Format-Bytes $R.systemFiles.hiberfilBytes))
    Write-Host ('pagefile.sys       {0}' -f (Format-Bytes $R.systemFiles.pagefileBytes))
    Write-Host ('swapfile.sys       {0}' -f (Format-Bytes $R.systemFiles.swapfileBytes))
    Write-Host ('Reserved storage   {0}' -f $R.reservedStorage)
    Write-Host ('Compact OS         {0}' -f $R.compactOs)
    Write-Host ('AppX packages      {0} for this user, {1} provisioned' -f $(if ($null -ne $R.appx.userCount) { $R.appx.userCount } else { 'n/a' }), $(if ($null -ne $R.appx.provisionedCount) { $R.appx.provisionedCount } else { 'n/a' }))
    foreach ($n in @($R.appx.notes)) { if ($n) { Write-Host ('                   ' + $n) } }
    Write-Host ('Processes          {0}' -f $R.processes.count)
    Write-Host ('Services           {0} total, {1} running, {2} automatic' -f $R.services.total, $R.services.running, $R.services.automatic)
    Write-Host ('Startup entries    {0}' -f $R.startupItems.count)
    Write-Host ('Memory             {0} in use, commit charge {1}' -f (Format-Bytes $R.memory.usedBytes), (Format-Bytes $R.memory.commitBytes))
}

function Write-CompareHuman {
    param($C)
    Write-Host ('Footprint comparison  before {0}  ->  after {1}' -f $C.before, $C.after)
    foreach ($m in $C.metrics) {
        $fmt = { param($v) if ($null -eq $v) { 'n/a' } elseif ($m.kind -eq 'bytes') { Format-Bytes $v } else { ([double]$v).ToString('0', $script:Inv) } }
        $d = 'n/a'
        if ($null -ne $m.delta) { $d = if ($m.kind -eq 'bytes') { Format-Bytes $m.delta -Signed } else { ([double]$m.delta).ToString('+0;-0;0', $script:Inv) } }
        Write-Host ('{0,-38} {1,12} -> {2,12}   {3,12}   {4}' -f $m.label, (& $fmt $m.before), (& $fmt $m.after), $d, $m.verdict)
    }
    foreach ($s in $C.states) {
        Write-Host ('{0,-38} {1,12} -> {2,12}   {3}' -f $s.label, $s.before, $s.after, $(if ($s.changed) { 'changed' } else { 'same' }))
    }
    foreach ($n in $C.notes) { Write-Host ('  - ' + $n) }
}

function Read-FootprintFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('report file not found: ' + $Path) }
    $obj = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath) | ConvertFrom-Json
    $err = Test-FootprintReport $obj
    if ($err) { throw ($Path + ': ' + $err) }
    return $obj
}

# ---------------------------------------------------------------- self-test

function Invoke-SelfTest {
    $script:stFails = 0
    $check = {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('PASS  ' + $Name) } else { Write-Host ('FAIL  ' + $Name); $script:stFails++ }
    }

    # DISM text parsing (English, then a decimal-comma locale with translated labels)
    $en = @'
Deployment Image Servicing and Management tool
Version: 10.0.26100.1

Image Version: 10.0.26100.1

[===========================99.9%==========================]

Component Store (WinSxS) information:

Windows Explorer Reported Size of Component Store : 9.28 GB

Actual Size of Component Store : 8.51 GB

    Shared with Windows : 5.98 GB
    Backups and Disabled Features : 2.30 GB
    Cache and Temporary Data : 232.40 MB

Date of Last Cleanup : 2026-10-01 08:11:22

Number of Reclaimable Packages : 3
Component Store Cleanup Recommended : Yes

The operation completed successfully.
'@
    $p = ConvertFrom-ComponentStoreText -Text $en
    & $check 'DISM parse: explorer reported 9.28 GB' ($p.explorerReportedBytes -eq [long][math]::Round(9.28 * 1GB))
    & $check 'DISM parse: actual 8.51 GB' ($p.actualBytes -eq [long][math]::Round(8.51 * 1GB))
    & $check 'DISM parse: reclaimable (backups and disabled features) 2.30 GB' ($p.reclaimableBytes -eq [long][math]::Round(2.30 * 1GB))
    & $check 'DISM parse: cache 232.40 MB' ($p.cacheBytes -eq [long][math]::Round(232.40 * 1MB))
    & $check 'DISM parse: cleanup recommended yes, parsed true' ($p.cleanupRecommended -eq $true -and $p.parsed)
    $nl = "Grootte van het onderdelenarchief volgens Verkenner : 7,64 GB`r`nWerkelijke grootte van het onderdelenarchief : 6,90 GB`r`n    Gedeeld met Windows : 4,10 GB`r`n    Back-ups en uitgeschakelde functies : 1,25 GB`r`n    Cache en tijdelijke gegevens : 120,5 MB`r`n"
    $q = ConvertFrom-ComponentStoreText -Text $nl
    & $check 'DISM parse: decimal comma and translated labels' ($q.actualBytes -eq [long][math]::Round(6.90 * 1GB) -and $q.reclaimableBytes -eq [long][math]::Round(1.25 * 1GB) -and $null -eq $q.cleanupRecommended)
    $bad = ConvertFrom-ComponentStoreText -Text 'Error: 740. Elevated permissions are required.'
    & $check 'DISM parse: error text is not parsed' ($bad.parsed -eq $false -and $null -eq $bad.actualBytes)
    & $check 'bytes: 1,234.5 MB' ((ConvertTo-DismBytes '1,234.5' 'MB') -eq [long][math]::Round(1234.5 * 1MB))
    & $check 'bytes: 1.234,5 MB (European)' ((ConvertTo-DismBytes '1.234,5' 'MB') -eq [long][math]::Round(1234.5 * 1MB))
    & $check 'bytes: 1,234 KB (thousands comma)' ((ConvertTo-DismBytes '1,234' 'KB') -eq 1234 * 1KB)
    & $check 'bytes: unknown unit -> null' ($null -eq (ConvertTo-DismBytes '5' 'furlongs'))

    & $check 'Format-Bytes: 1.5 GB / 512 MB / -2 GB signed / null' (
        (Format-Bytes (1.5 * 1GB)) -eq '1.50 GB' -and (Format-Bytes (512MB)) -eq '512.0 MB' -and (Format-Bytes (-2GB) -Signed) -eq '-2.00 GB' -and (Format-Bytes 3GB -Signed) -eq '+3.00 GB' -and (Format-Bytes $null) -eq 'n/a')

    # comparison
    $mk = {
        param($o)
        $r = [ordered]@{
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
        foreach ($k in $o.Keys) { $r[$k] = $o[$k] }
        return (ConvertTo-Json -InputObject $r -Depth 6 | ConvertFrom-Json)
    }
    $b1 = & $mk @{}
    $a1 = & $mk @{
        disk = [ordered]@{ usedBytes = 92GB; freeBytes = 158GB; totalBytes = 250GB }
        componentStore = [ordered]@{ status = 'ok'; actualBytes = 6GB; explorerReportedBytes = 7GB; reclaimableBytes = 0 }
        systemFiles = [ordered]@{ hiberfilBytes = 0; pagefileBytes = 3GB; swapfileBytes = 256MB }
        compactOs = 'compact'; appx = [ordered]@{ userCount = 60; provisionedCount = 70 }; processes = [ordered]@{ count = 210 }
    }
    $c = Compare-Footprint -Before $b1 -After $a1
    $row = { param($k) $c.metrics | Where-Object { $_.key -eq $k } | Select-Object -First 1 }
    & $check 'compare: used space down 8 GB is better' ((& $row 'disk.usedBytes').delta -eq -8GB -and (& $row 'disk.usedBytes').verdict -eq 'better')
    & $check 'compare: free space up is better' ((& $row 'disk.freeBytes').verdict -eq 'better')
    & $check 'compare: hiberfil 6 GB -> 0 is better, -100 %' ((& $row 'systemFiles.hiberfilBytes').verdict -eq 'better' -and (& $row 'systemFiles.hiberfilBytes').percent -eq -100)
    & $check 'compare: unchanged pagefile is same' ((& $row 'systemFiles.pagefileBytes').verdict -eq 'same')
    & $check 'compare: more processes is worse' ((& $row 'processes.count').verdict -eq 'worse' -and (& $row 'processes.count').delta -eq 10)
    & $check 'compare: AppX 80 -> 60 delta -20' ((& $row 'appx.userCount').delta -eq -20)
    & $check 'compare: Compact OS state change is reported' (@($c.states | Where-Object { $_.key -eq 'compactOs' -and $_.changed }).Count -eq 1 -and @($c.states | Where-Object { $_.key -eq 'reservedStorage' -and -not $_.changed }).Count -eq 1)
    & $check 'compact query: exit 0 = compact, 102 = not compact (any language), text only as fallback, else unknown' ((ConvertFrom-CompactOsQuery -ExitCode 0 -Text 'Das System ist komprimiert') -eq 'compact' -and (ConvertFrom-CompactOsQuery -ExitCode 102 -Text 'Das System ist nicht komprimiert') -eq 'not-compact' -and (ConvertFrom-CompactOsQuery -ExitCode 1 -Text 'The system is not in the Compact state because x') -eq 'not-compact' -and (ConvertFrom-CompactOsQuery -ExitCode -1 -Text '') -eq 'unknown')
    $cu = Compare-Footprint -Before (& $mk @{ reservedStorage = 'unknown' }) -After (& $mk @{ reservedStorage = 'disabled' })
    & $check 'compare: a state that could not be read is not reported as a change and is noted' (@($cu.states | Where-Object { $_.key -eq 'reservedStorage' -and -not $_.changed }).Count -eq 1 -and ($cu.notes -join ' ') -match 'Could not be read')
    & $check 'compare: note says used space went down by 8.00 GB' (($c.notes -join ' ') -match '8\.00 GB')
    $nb = & $mk @{ componentStore = [ordered]@{ status = 'skipped' }; isAdmin = $false; os = [ordered]@{ build = '26200'; edition = 'Professional' } }
    $c2 = Compare-Footprint -Before $nb -After $a1
    & $check 'compare: missing WinSxS in one report is n/a and listed in the notes' ((($c2.metrics | Where-Object { $_.key -eq 'componentStore.actualBytes' }).verdict -eq 'n/a') -and (($c2.notes -join ' ') -match 'Not compared'))
    & $check 'compare: build change and elevation mismatch are noted' (($c2.notes -join ' ') -match 'build changed' -and ($c2.notes -join ' ') -match 'elevated')
    $cj = $c | ConvertTo-Json -Depth 6
    & $check 'compare: result serializes to JSON' ($cj.TrimStart().StartsWith('{') -and (($cj | ConvertFrom-Json).metrics.Count -eq $c.metrics.Count))

    & $check 'stamp: ISO text and DateTime render the same' ((Format-Stamp '2026-10-17T10:00:05.0000000+02:00') -eq (Format-Stamp ([datetime]'2026-10-17T10:00:05.0000000+02:00')))
    & $check 'compare: before/after stamps are formatted' ($c.before -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$')

    # report validation
    & $check 'validate: good report passes' ($null -eq (Test-FootprintReport $b1))
    & $check 'validate: empty object, missing timestamp and newer schema are rejected' (
        ($null -ne (Test-FootprintReport ([pscustomobject]@{ a = 1 }))) -and ($null -ne (Test-FootprintReport ([pscustomobject]@{ schemaVersion = 1 }))) -and ($null -ne (Test-FootprintReport ([pscustomobject]@{ schemaVersion = 99; timestamp = 'x' }))))

    # baseline path rules
    & $check 'baseline path: under the Windows folder is refused' ($null -ne (Test-BaselinePath (Join-Path $env:SystemRoot 'Temp\x.json')))
    & $check 'baseline path: the DebloatKit state folder is refused' ($null -ne (Test-BaselinePath (Join-Path $env:ProgramData 'DebloatKit\x.json')))
    & $check 'baseline path: a normal user path and empty path' (($null -eq (Test-BaselinePath (Join-Path $env:TEMP 'before.json'))) -and ($null -ne (Test-BaselinePath '')) -and ($null -ne (Test-BaselinePath 'C:\x\')))

    # static scan: no change-making commands (the literal list itself is excluded)
    $path = $PSCommandPath
    if (-not $path) { $path = $MyInvocation.MyCommand.Path }
    $text = [System.IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?s)# BEGIN-FORBIDDEN.*?# END-FORBIDDEN', '')
    # BEGIN-FORBIDDEN
    $forbidden = @(
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Service', 'sc.exe', 'Register-ScheduledTask',
        'schtasks', 'powercfg', 'bcdedit', 'fsutil', 'Remove-AppxPackage', 'Add-AppxPackage', 'Remove-AppxProvisionedPackage',
        'StartComponentCleanup', 'ResetBase', 'Set-ReservedStorageState', 'Enable-WindowsOptionalFeature',
        'Disable-WindowsOptionalFeature', 'Remove-WindowsCapability', 'Add-WindowsCapability', 'CompactOS:always',
        'CompactOS:never', 'Set-CimInstance', 'Remove-Item', 'Stop-Process', 'Stop-Service'
    )
    # END-FORBIDDEN
    $hits = @($forbidden | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    & $check ('static scan: no forbidden write operations' + $(if ($hits.Count) { ' (found: ' + ($hits -join ', ') + ')' } else { '' })) ($hits.Count -eq 0)

    if ($script:stFails -eq 0) { Write-Host 'SELFTEST PASSED'; return 0 }
    Write-Host 'SELFTEST FAILED'
    return 1
}

# ---------------------------------------------------------------- main

try {
    if ($SelfTest) { exit (Invoke-SelfTest) }

    if ($Baseline -and $Compare) { throw '-Baseline and -Compare cannot be combined.' }
    if ($With -and -not $Compare) { throw '-With only works with -Compare.' }
    if ($Force -and -not $Baseline) { throw '-Force only works with -Baseline.' }

    if ($Compare) {
        $before = Read-FootprintFile $Compare
        $after = if ($With) { Read-FootprintFile $With } else { Get-FootprintReport -DeepRequested ([bool]$Deep) -Settle $SettleSeconds }
        $cmp = Compare-Footprint -Before $before -After $after
        if ($AsJson) { Write-Output (ConvertTo-Json -InputObject $cmp -Depth 6) } else { Write-CompareHuman $cmp }
        exit 0
    }

    if ($Baseline) {
        $perr = Test-BaselinePath $Baseline
        if ($perr) { throw ('-Baseline: ' + $perr) }
        $full = [System.IO.Path]::GetFullPath($Baseline)
        if ((Test-Path -LiteralPath $full) -and -not $Force) { throw ('-Baseline: ' + $full + ' already exists (use -Force to replace it).') }
    }

    $report = Get-FootprintReport -DeepRequested ([bool]$Deep) -Settle $SettleSeconds
    if ($Baseline) {
        $dir = [System.IO.Path]::GetDirectoryName($full)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        [System.IO.File]::WriteAllText($full, (ConvertTo-Json -InputObject $report -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        if (-not $AsJson) { Write-Host ('Baseline saved: ' + $full) }
    }
    if ($AsJson) { Write-Output (ConvertTo-Json -InputObject $report -Depth 6) } else { Write-FootprintHuman $report }
    exit 0
}
catch {
    [Console]::Error.WriteLine('Get-FootprintReport failed: ' + $_.Exception.Message)
    exit 1
}
