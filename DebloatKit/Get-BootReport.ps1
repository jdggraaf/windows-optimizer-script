<#
.SYNOPSIS
    Read-only boot and startup baseline: boot times, slow-boot culprits, startup items, logon tasks.

.DESCRIPTION
    Gives a before/after baseline for startup changes without changing anything. It reads:
      1. Boot history: Event 100 in Microsoft-Windows-Diagnostics-Performance/Operational
         (BootTime, MainPathBootTime, BootPostBootTime in ms; shown in seconds, with the median).
      2. Degradations: events 101 (app), 102 (driver), 103 (service) in the last -Days days,
         grouped by name with count and the largest degradation time.
      3. Startup inventory: Run / RunOnce values (HKLM, HKCU, WOW6432Node) and the user and common
         Startup folders, with the enabled state from Explorer\StartupApproved (first byte odd =
         disabled; even or missing = enabled).
      4. Logon tasks: enabled scheduled tasks with a logon trigger outside \Microsoft\.
      5. Fast Startup (HiberbootEnabled).
      6. Findings and advice.

    The tool is READ-ONLY. It writes no registry value, no service, no scheduled task, no boot
    setting and no file. Reading the Diagnostics-Performance log may need an elevated prompt or
    Event Log Readers membership; without it the boot sections report 'needsElevation' and the
    rest of the report still runs.

    Works on Windows PowerShell 5.1 and PowerShell 7. Kept ASCII-only on purpose.

.PARAMETER Boots
    Number of most recent boots (Event 100) to read (default 10).

.PARAMETER Days
    Days back for degradation events 101/102/103 (default 30).

.PARAMETER AsJson
    Write only JSON to stdout: {boots, medianBootSec, degradations, startupItems, logonTasks,
    fastStartup, notes}.

.PARAMETER SelfTest
    No system reads: tests the parsing helpers and scans this file for forbidden write commands.
    Prints SELFTEST PASSED or SELFTEST FAILED; exit 0 or 1.

.EXAMPLE
    .\Get-BootReport.ps1

.EXAMPLE
    .\Get-BootReport.ps1 -Boots 5 -AsJson
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 200)][int]$Boots = 10,
    [ValidateRange(1, 365)][int]$Days = 30,
    [switch]$AsJson,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PerfLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- pure helpers

# Reads <Data Name="x">value</Data> pairs of an event XML string into an ordered hashtable of strings.
function ConvertFrom-EventDataXml {
    param([string]$Xml)
    $result = [ordered]@{}
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    foreach ($d in $doc.GetElementsByTagName('Data')) {
        $name = $d.GetAttribute('Name')
        if ($name) { $result[$name] = [string]$d.InnerText }
    }
    return $result
}

function ConvertTo-LongOrNull {
    param($Value)
    $n = 0L
    if ($null -ne $Value -and [long]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Integer, $script:Inv, [ref]$n)) { return $n }
    return $null
}

# Event 100 XML -> BootTime / MainPathBootTime / BootPostBootTime (ms, $null when missing).
function ConvertFrom-BootEventXml {
    param([string]$Xml)
    $data = ConvertFrom-EventDataXml -Xml $Xml
    $get = { param($k) if ($data.Contains($k)) { $data[$k] } else { $null } }
    $isDeg = $false
    if ($data.Contains('IsDegradation')) { $isDeg = ([string]$data['IsDegradation'] -match '^(?i:true|1)$') }
    [pscustomobject]@{
        BootTime         = ConvertTo-LongOrNull (& $get 'BootTime')
        MainPathBootTime = ConvertTo-LongOrNull (& $get 'MainPathBootTime')
        BootPostBootTime = ConvertTo-LongOrNull (& $get 'BootPostBootTime')
        IsDegradation    = $isDeg
        BootStartTime    = [string](& $get 'BootStartTime')
    }
}

# StartupApproved value: first byte with bit 0 set (0x03) = disabled; 0x02/0x06/missing = enabled.
function Get-StartupApprovedState {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return 'Enabled' }
    if (($Bytes[0] -band 1) -eq 1) { return 'Disabled' }
    return 'Enabled'
}

function Get-Median {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    $mid = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return [double]$s[$mid] }
    return ([double]$s[$mid - 1] + [double]$s[$mid]) / 2
}

# ---------------------------------------------------------------- readers (read-only)

function Test-NoEventsError {
    param($ErrorRecord)
    return (($ErrorRecord.FullyQualifiedErrorId -match 'NoMatchingEventsFound') -or ($ErrorRecord.Exception.Message -match 'No events were found'))
}

function Get-PerfEvents {
    param([hashtable]$Filter, [int]$Max)
    try {
        return @{ Status = 'ok'; Events = @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
    }
    catch {
        if (Test-NoEventsError $_) { return @{ Status = 'noData'; Events = @() } }
        if (($_.Exception -is [System.UnauthorizedAccessException]) -or ($_.Exception.Message -match '(?i)denied|unauthorized|privilege')) {
            return @{ Status = 'needsElevation'; Events = @() }
        }
        return @{ Status = 'error'; Events = @(); Message = $_.Exception.Message }
    }
}

function Get-BootHistory {
    param([int]$Count)
    $r = Get-PerfEvents -Filter @{ LogName = $script:PerfLog; Id = 100 } -Max $Count
    $rows = @()
    foreach ($e in $r.Events) {
        try {
            $p = ConvertFrom-BootEventXml -Xml $e.ToXml()
            $rows += [pscustomobject]@{
                bootStart     = if ($p.BootStartTime) { $p.BootStartTime } else { $e.TimeCreated.ToString('o') }
                bootSec       = if ($null -ne $p.BootTime) { [math]::Round($p.BootTime / 1000, 1) } else { $null }
                mainPathSec   = if ($null -ne $p.MainPathBootTime) { [math]::Round($p.MainPathBootTime / 1000, 1) } else { $null }
                postBootSec   = if ($null -ne $p.BootPostBootTime) { [math]::Round($p.BootPostBootTime / 1000, 1) } else { $null }
                isDegradation = $p.IsDegradation
            }
        } catch { }
    }
    @{ Status = $r.Status; Message = if ($r.ContainsKey('Message')) { $r.Message } else { $null }; Rows = $rows }
}

function Get-Degradations {
    param([int]$LookbackDays)
    $filter = @{ LogName = $script:PerfLog; Id = @(101, 102, 103); StartTime = (Get-Date).AddDays(-$LookbackDays) }
    $r = Get-PerfEvents -Filter $filter -Max 2000
    $kinds = @{ 101 = 'app'; 102 = 'driver'; 103 = 'service' }
    $groups = @{}
    foreach ($e in $r.Events) {
        try {
            $d = ConvertFrom-EventDataXml -Xml $e.ToXml()
            $name = $null
            foreach ($k in 'Name', 'FileName', 'FriendlyName') {
                if (-not $name -and $d.Contains($k) -and $d[$k]) { $name = $d[$k] }
            }
            if (-not $name) { continue }
            $ms = $null
            foreach ($k in 'DegradationTime', 'TotalTime') {
                if ($null -eq $ms -and $d.Contains($k)) { $ms = ConvertTo-LongOrNull $d[$k] }
            }
            if ($null -eq $ms) { $ms = 0 }
            $key = [string]$e.Id + '|' + $name
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [pscustomobject]@{ type = $kinds[[int]$e.Id]; name = $name; count = 0; maxDegradationMs = 0L }
            }
            $g = $groups[$key]
            $g.count++
            if ($ms -gt $g.maxDegradationMs) { $g.maxDegradationMs = [long]$ms }
        } catch { }
    }
    @{ Status = $r.Status; Message = if ($r.ContainsKey('Message')) { $r.Message } else { $null }
       Rows = @($groups.Values | Sort-Object -Property @{ Expression = 'maxDegradationMs'; Descending = $true }, name) }
}

function Get-ApprovedMap {
    param([string]$Hive, [string]$Sub)
    $map = @{}
    $path = $Hive + ':\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\' + $Sub
    try {
        if (Test-Path -LiteralPath $path) {
            $key = Get-Item -LiteralPath $path
            foreach ($n in $key.GetValueNames()) {
                $v = $key.GetValue($n)
                if ($v -is [byte[]]) { $map[$n] = $v }
            }
        }
    } catch { }
    return $map
}

function Get-StartupInventory {
    $items = @()
    $runKeys = @(
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Loc = 'HKLM Run';           Approved = 'Run';   Once = $false },
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';         Loc = 'HKLM RunOnce';       Approved = $null;   Once = $true },
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Loc = 'HKLM Run (32-bit)';  Approved = 'Run32'; Once = $false },
        @{ Hive = 'HKCU'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Loc = 'HKCU Run';           Approved = 'Run';   Once = $false },
        @{ Hive = 'HKCU'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';         Loc = 'HKCU RunOnce';       Approved = $null;   Once = $true }
    )
    foreach ($rk in $runKeys) {
        try {
            if (-not (Test-Path -LiteralPath $rk.Path)) { continue }
            $approved = @{}
            if ($rk.Approved) { $approved = Get-ApprovedMap -Hive $rk.Hive -Sub $rk.Approved }
            $key = Get-Item -LiteralPath $rk.Path
            foreach ($n in $key.GetValueNames()) {
                $state = 'Enabled'
                if ($approved.ContainsKey($n)) { $state = Get-StartupApprovedState -Bytes $approved[$n] }
                $items += [pscustomobject]@{
                    name    = if ($n) { $n } else { '(Default)' }
                    location = $rk.Loc
                    command = [string]$key.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                    enabled = ($state -eq 'Enabled')
                    runOnce = $rk.Once
                }
            }
        } catch { }
    }
    $folders = @(
        @{ Hive = 'HKCU'; Special = 'Startup';       Loc = 'Startup folder (user)' },
        @{ Hive = 'HKLM'; Special = 'CommonStartup'; Loc = 'Startup folder (all users)' }
    )
    foreach ($f in $folders) {
        try {
            $dir = [Environment]::GetFolderPath($f.Special)
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
            $approved = Get-ApprovedMap -Hive $f.Hive -Sub 'StartupFolder'
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop | Where-Object { $_.Extension -in '.lnk', '.exe' })) {
                $state = 'Enabled'
                if ($approved.ContainsKey($file.Name)) { $state = Get-StartupApprovedState -Bytes $approved[$file.Name] }
                $items += [pscustomobject]@{
                    name     = $file.Name
                    location = $f.Loc
                    command  = $file.FullName
                    enabled  = ($state -eq 'Enabled')
                    runOnce  = $false
                }
            }
        } catch { }
    }
    return $items
}

function Get-LogonTasks {
    $rows = @()
    $status = 'ok'
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            if ([string]$t.State -eq 'Disabled') { continue }
            if ($t.TaskPath -like '\Microsoft\*') { continue }
            $logon = @($t.Triggers | Where-Object { $_ -and $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
            if ($logon.Count -eq 0) { continue }
            $delay = ''
            $dp = $logon[0].PSObject.Properties['Delay']
            if ($dp -and $dp.Value) { $delay = [string]$dp.Value }
            $rows += [pscustomobject]@{ taskPath = $t.TaskPath; taskName = $t.TaskName; delay = $delay }
        }
    }
    catch { $status = 'error: ' + $_.Exception.Message }
    @{ Status = $status; Rows = $rows }
}

function Get-FastStartupState {
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled
        return [pscustomobject]@{ enabled = ([int]$v -eq 1); value = [int]$v }
    }
    catch { return [pscustomobject]@{ enabled = $null; value = $null } }
}

# ---------------------------------------------------------------- findings

function Get-Findings {
    param($Boot, $Deg, $Items, $Tasks, $Fast)
    $notes = @()
    switch ($Boot.Status) {
        'needsElevation' { $notes += 'Boot history skipped (needsElevation): the Diagnostics-Performance log needs an elevated prompt or Event Log Readers membership.' }
        'noData'         { $notes += 'Boot history: no Event 100 found (noData). The log may be disabled or cleared.' }
        'error'          { $notes += 'Boot history could not be read: ' + $Boot.Message }
    }
    if ($Deg.Status -eq 'needsElevation') { $notes += 'Degradation events skipped (needsElevation).' }
    if ($Tasks.Status -ne 'ok') { $notes += 'Logon tasks could not be read (' + $Tasks.Status + ').' }
    $enabled = @($Items | Where-Object { $_.enabled -and -not $_.runOnce })
    if ($enabled.Count -gt 10) {
        $notes += ('{0} enabled Run/Startup items; Microsoft''s Windows Experience Guide goal is fewer than 10 Run-key processes.' -f $enabled.Count)
    }
    $noDelay = @($Tasks.Rows | Where-Object { -not $_.delay })
    if ($noDelay.Count -gt 0) {
        $notes += ('{0} logon task(s) outside \Microsoft\ start without a delay: {1}' -f $noDelay.Count, (($noDelay | Select-Object -First 5 | ForEach-Object { $_.taskPath + $_.taskName }) -join '; '))
    }
    foreach ($d in @($Deg.Rows | Select-Object -First 3)) {
        $notes += ('Slow at boot ({0}): {1}, {2}x, worst {3} s.' -f $d.type, $d.name, $d.count, [math]::Round($d.maxDegradationMs / 1000, 1))
    }
    if ($null -ne $Fast.enabled -and $Fast.enabled) {
        $notes += 'Fast Startup is on: Shut down is a partial hibernate, so Event 100 timings only reflect a full restart.'
    }
    $notes += 'Advice: disable non-essential items via Settings > Apps > Startup or Task Manager > Startup apps, change one thing at a time, and compare Event 100 before and after (use Restart for comparable boots).'
    return $notes
}

# ---------------------------------------------------------------- output

function Write-HumanReport {
    param($R)
    Write-Host '== Boot history (Event 100) =='
    if ($R.bootStatus -ne 'ok') { Write-Host ('  ' + $R.bootStatus) }
    elseif (@($R.boots).Count -gt 0) {
        Write-Host ('  {0,-32} {1,8} {2,10} {3,10}' -f 'Boot start', 'Boot s', 'MainPath s', 'PostBoot s')
        foreach ($b in $R.boots) { Write-Host ('  {0,-32} {1,8} {2,10} {3,10}' -f $b.bootStart, $b.bootSec, $b.mainPathSec, $b.postBootSec) }
        Write-Host ('  Median boot time: {0} s' -f $R.medianBootSec)
    }
    Write-Host ''
    Write-Host '== Degradations (Events 101/102/103) =='
    if ($R.degradationStatus -ne 'ok') { Write-Host ('  ' + $R.degradationStatus) }
    foreach ($d in @($R.degradations | Select-Object -First 15)) {
        Write-Host ('  {0,-8} {1,-40} x{2,-4} max {3} ms' -f $d.type, $d.name, $d.count, $d.maxDegradationMs)
    }
    Write-Host ''
    Write-Host '== Startup inventory =='
    foreach ($i in $R.startupItems) {
        $flag = if ($i.enabled) { 'on ' } else { 'off' }
        Write-Host ('  [{0}] {1,-26} {2,-26} {3}' -f $flag, $i.name, $i.location, $i.command)
    }
    Write-Host ''
    Write-Host '== Logon tasks (non-Microsoft, enabled) =='
    foreach ($t in $R.logonTasks) {
        Write-Host ('  {0}{1}  delay: {2}' -f $t.taskPath, $t.taskName, $(if ($t.delay) { $t.delay } else { '(none)' }))
    }
    Write-Host ''
    Write-Host '== Fast Startup =='
    $fs = if ($null -eq $R.fastStartup.enabled) { 'unknown' } elseif ($R.fastStartup.enabled) { 'on' } else { 'off' }
    Write-Host ('  ' + $fs)
    Write-Host ''
    Write-Host '== Findings =='
    foreach ($n in $R.notes) { Write-Host ('  - ' + $n) }
}

# ---------------------------------------------------------------- self-test

function Invoke-SelfTest {
    $script:stFails = 0
    $check = {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('PASS  ' + $Name) } else { Write-Host ('FAIL  ' + $Name); $script:stFails++ }
    }

    $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><EventID>100</EventID></System><EventData>' +
        '<Data Name="BootStartTime">2026-01-05T08:00:00.000000000Z</Data><Data Name="BootTime">81158</Data>' +
        '<Data Name="MainPathBootTime">64858</Data><Data Name="BootPostBootTime">16300</Data><Data Name="IsDegradation">true</Data></EventData></Event>'
    $p = ConvertFrom-BootEventXml -Xml $xml
    & $check 'Event 100 parse: BootTime 81158' ($p.BootTime -eq 81158)
    & $check 'Event 100 parse: MainPathBootTime 64858' ($p.MainPathBootTime -eq 64858)
    & $check 'Event 100 parse: BootPostBootTime 16300' ($p.BootPostBootTime -eq 16300)
    & $check 'Event 100 parse: IsDegradation true' ($p.IsDegradation -eq $true)
    $empty = ConvertFrom-BootEventXml -Xml '<Event><EventData></EventData></Event>'
    & $check 'Event 100 parse: missing fields give null' ($null -eq $empty.BootTime)

    & $check 'StartupApproved 0x02 -> Enabled'  ((Get-StartupApprovedState -Bytes ([byte[]](2,0,0,0,0,0,0,0,0,0,0,0))) -eq 'Enabled')
    & $check 'StartupApproved 0x03 -> Disabled' ((Get-StartupApprovedState -Bytes ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0))) -eq 'Disabled')
    & $check 'StartupApproved 0x06 -> Enabled'  ((Get-StartupApprovedState -Bytes ([byte[]](6,0,0,0,0,0,0,0,0,0,0,0))) -eq 'Enabled')
    & $check 'StartupApproved null -> Enabled'  ((Get-StartupApprovedState -Bytes $null) -eq 'Enabled')

    & $check 'median of 3 values (81, 60, 70) = 70' ((Get-Median -Values @(81, 60, 70)) -eq 70)
    & $check 'median of 4 values = 2.5' ((Get-Median -Values @(1, 2, 3, 4)) -eq 2.5)

    # Static scan of this file for forbidden write commands (the literal list itself is excluded).
    $path = $PSCommandPath
    if (-not $path) { $path = $MyInvocation.MyCommand.Path }
    $text = [System.IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?s)# BEGIN-FORBIDDEN.*?# END-FORBIDDEN', '')
    # BEGIN-FORBIDDEN
    $forbidden = @(
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Set-Service', 'sc.exe',
        'Disable-ScheduledTask', 'Register-ScheduledTask', 'schtasks', 'bcdedit', 'wpr', 'xbootmgr', 'powercfg'
    )
    # END-FORBIDDEN
    $hits = @($forbidden | Where-Object { $text.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    & $check ('static scan: no forbidden write commands' + $(if ($hits.Count) { ' (found: ' + ($hits -join ', ') + ')' } else { '' })) ($hits.Count -eq 0)

    if ($script:stFails -eq 0) { Write-Host 'SELFTEST PASSED'; return 0 }
    Write-Host 'SELFTEST FAILED'
    return 1
}

# ---------------------------------------------------------------- main

try {
    if ($SelfTest) { exit (Invoke-SelfTest) }

    $boot = Get-BootHistory -Count $Boots
    $deg = Get-Degradations -LookbackDays $Days
    $items = @(Get-StartupInventory)
    $tasks = Get-LogonTasks
    $fast = Get-FastStartupState

    $secs = @($boot.Rows | Where-Object { $null -ne $_.bootSec } | ForEach-Object { [double]$_.bootSec })
    $median = Get-Median -Values $secs
    if ($null -ne $median) { $median = [math]::Round($median, 1) }
    $notes = @(Get-Findings -Boot $boot -Deg $deg -Items $items -Tasks $tasks -Fast $fast)

    $report = [ordered]@{
        boots         = @($boot.Rows)
        medianBootSec = $median
        degradations  = @($deg.Rows)
        startupItems  = $items
        logonTasks    = @($tasks.Rows)
        fastStartup   = $fast
        notes         = $notes
    }
    if ($AsJson) {
        Write-Output (ConvertTo-Json -InputObject $report -Depth 6)
    }
    else {
        $report['bootStatus'] = $boot.Status
        $report['degradationStatus'] = $deg.Status
        Write-HumanReport ([pscustomobject]$report)
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine('Get-BootReport failed: ' + $_.Exception.Message)
    exit 1
}
