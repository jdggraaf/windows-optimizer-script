<#
.SYNOPSIS
    Read-only memory-pressure monitor: watches commit charge, not "RAM in use".

.DESCRIPTION
    Reports how close the system is to its commit limit (RAM + pagefile), whether Windows is
    really paging, which processes hold the most private memory, and whether a larger pagefile
    minimum would be worth asking for.

    The tool is READ-ONLY. It reads CIM/WMI classes, the System event log and the process list.
    It changes no system setting and releases no memory. The only file it may write is the CSV
    given by -LogPath. There is no install or scheduling option; if you want a periodic run,
    schedule it yourself (see README.md).

    Data comes from CIM only (not performance-counter paths, which are localized). Formatted rate
    counters need warm-up, so each report takes 5 samples 1 s apart and averages samples 2-5 for
    the rates; byte values come from the last sample.

    Thresholds (see docs/PERFORMANCE-RESEARCH.md):
      commit >= 90 %                      Critical (system-managed pagefile grows here; fails at 100 %)
      commit >= 80 % and pages out >= 100/s  Critical (high commit with sustained hard page writes)
      commit >= 80 % and pages out <  100/s  Warning  (little paging yet)
      available < 500 MB or < 1 % of RAM    Critical;  < 10 % of RAM  Warning
      Resource-Exhaustion-Detector 2004     at least Warning
      any pagefile > 90 % used              Warning

.PARAMETER Watch
    Loop instead of a single report; one compact line per interval.

.PARAMETER IntervalSeconds
    Seconds between samples with -Watch (5-3600, default 60).

.PARAMETER Count
    With -Watch: stop after this many samples (0 = until Ctrl+C).

.PARAMETER Toast
    With -Watch: show a Windows toast when the status moves up to Warning or Critical.
    Falls back to a console warning and beep when WinRT is unavailable (PowerShell 7).

.PARAMETER LogPath
    With -Watch: append one CSV row per sample (header is written if the file is missing).

.PARAMETER Top
    Number of process groups in the table (default 10).

.PARAMETER EventDays
    Days of System log to search for Resource-Exhaustion-Detector event 2004 (default 7).

.PARAMETER AsJson
    One-shot only: write only JSON to stdout; warnings go to stderr.

.PARAMETER SelfTest
    No CIM calls, no system access: tests the pure functions and scans this file for forbidden
    write operations. Exit 0 = pass, 1 = fail.

.EXAMPLE
    .\Get-MemoryPressure.ps1

.EXAMPLE
    .\Get-MemoryPressure.ps1 -Watch -IntervalSeconds 30 -LogPath $env:TEMP\mp.csv -Toast
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [ValidateRange(5, 3600)][int]$IntervalSeconds = 60,
    [int]$Count = 0,
    [switch]$Toast,
    [string]$LogPath,
    [int]$Top = 10,
    [int]$EventDays = 7,
    [switch]$AsJson,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StatusRank = @{ OK = 0; Warning = 1; Critical = 2 }
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- pure functions (no CIM)

function Get-SampleValue {
    param($Sample, [string]$Name)
    if ($Sample -is [System.Collections.IDictionary] -and $Sample.Contains($Name)) { return $Sample[$Name] }
    return $null
}

function Get-PressureVerdict {
    param([Parameter(Mandatory)]$Sample)

    $commit  = Get-SampleValue $Sample 'CommitPct'
    $out     = Get-SampleValue $Sample 'PagesOutputPerSec'
    $avail   = Get-SampleValue $Sample 'AvailableMB'
    $ramMB   = Get-SampleValue $Sample 'RamMB'
    $events  = Get-SampleValue $Sample 'Event2004Count'
    $days    = Get-SampleValue $Sample 'EventDays'
    $files   = Get-SampleValue $Sample 'Pagefiles'
    if ($null -eq $days) { $days = 7 }

    $state = @{ Rank = 0 }
    $reasons = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Status, [string]$Reason)
        if ($script:StatusRank[$Status] -gt $state.Rank) { $state.Rank = $script:StatusRank[$Status] }
        $reasons.Add($Reason)
    }

    if ($null -ne $commit) {
        if ($commit -ge 90) {
            & $add 'Critical' 'commit >= 90% (system-managed pagefile grows here; allocations fail at 100%)'
        }
        elseif ($commit -ge 80) {
            if ($null -ne $out -and $out -ge 100) {
                & $add 'Critical' 'high commit with sustained hard page writes'
            }
            else {
                & $add 'Warning' 'commit high but little paging yet'
            }
        }
    }

    if ($null -ne $avail) {
        $onePct = $null; $tenPct = $null
        if ($null -ne $ramMB -and $ramMB -gt 0) { $onePct = $ramMB * 0.01; $tenPct = $ramMB * 0.10 }
        if ($avail -lt 500 -or ($null -ne $onePct -and $avail -lt $onePct)) {
            & $add 'Critical' 'available memory critically low'
        }
        elseif ($null -ne $tenPct -and $avail -lt $tenPct) {
            & $add 'Warning' 'available memory below 10% of RAM'
        }
    }

    if ($null -ne $events -and $events -gt 0) {
        & $add 'Warning' ('Resource-Exhaustion-Detector event 2004 in last {0} days' -f $days)
    }

    if ($null -ne $files) {
        foreach ($pf in @($files)) {
            $alloc = Get-SampleValue $pf 'AllocatedBaseSize'
            $used  = Get-SampleValue $pf 'CurrentUsage'
            if ($null -ne $alloc -and $null -ne $used -and $alloc -gt 0 -and ($used / $alloc) -gt 0.9) {
                & $add 'Warning' 'pagefile more than 90% used'
                break
            }
        }
    }

    $names = @('OK', 'Warning', 'Critical')
    return @{ Status = $names[$state.Rank]; Reasons = [string[]]$reasons.ToArray() }
}

function Get-PagefileAdvice {
    param(
        [Parameter(Mandatory)][double]$RamGB,
        [Parameter(Mandatory)][double]$PeakCommitGB,
        [Parameter(Mandatory)][double]$PagefileGB,
        [Parameter(Mandatory)][bool]$AutoManaged
    )
    $suggest = [math]::Ceiling([math]::Max(0, $PeakCommitGB * 1.25 - $RamGB))
    $suggest = [int][math]::Min($suggest, 3 * $RamGB)

    if ($suggest -le $PagefileGB) {
        return @{ SuggestedMinGB = $suggest; Text = 'no change needed' }
    }
    $mode = if ($AutoManaged) { 'system-managed' } else { 'fixed' }
    $text = ('Peak commit {0:N1} GB against {1:N0} GB RAM and a {2:N1} GB {3} pagefile. A pagefile minimum of about {4} GB ' -f $PeakCommitGB, $RamGB, $PagefileGB, $mode, $suggest) +
            'would leave headroom. This is a manual change in System Properties > Advanced > Performance > Virtual memory. ' +
            'On a managed device ask IT first. This script never applies it.'
    return @{ SuggestedMinGB = $suggest; Text = $text }
}

function Test-ToastDue {
    param(
        [string]$Previous,
        [Parameter(Mandatory)][string]$Current,
        $LastToastTime,
        [datetime]$Now = (Get-Date)
    )
    $p = 0
    if ($Previous -and $script:StatusRank.ContainsKey($Previous)) { $p = $script:StatusRank[$Previous] }
    $c = $script:StatusRank[$Current]
    if ($c -gt $p) { return $true }
    if ($c -eq 2 -and $p -eq 2) {
        if ($null -eq $LastToastTime) { return $true }
        return (($Now - [datetime]$LastToastTime).TotalMinutes -ge 15)
    }
    return $false
}

# ---------------------------------------------------------------- data collection (CIM only)

function Get-CimValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-MemorySamples {
    # 5 samples 1 s apart; rates = mean of samples 2-5, byte values = last sample.
    $samples = @()
    for ($i = 0; $i -lt 5; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds 1 }
        $samples += , (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory)
    }
    $last = $samples[-1]
    $rate = {
        param([string]$Name)
        $vals = @()
        for ($i = 1; $i -lt $samples.Count; $i++) {
            $v = Get-CimValue $samples[$i] $Name
            if ($null -ne $v) { $vals += [double]$v }
        }
        if ($vals.Count -eq 0) { return $null }
        return ($vals | Measure-Object -Average).Average
    }
    $peak = 0.0
    foreach ($s in $samples) {
        $cb = Get-CimValue $s 'CommittedBytes'
        if ($null -ne $cb -and [double]$cb -gt $peak) { $peak = [double]$cb }
    }
    return @{
        CommittedBytes    = Get-CimValue $last 'CommittedBytes'
        CommitLimit       = Get-CimValue $last 'CommitLimit'
        PercentCommitted  = Get-CimValue $last 'PercentCommittedBytesInUse'
        AvailableMBytes   = Get-CimValue $last 'AvailableMBytes'
        ModifiedBytes     = Get-CimValue $last 'ModifiedPageListBytes'
        PagesOutputPerSec = & $rate 'PagesOutputPersec'
        PagesInputPerSec  = & $rate 'PagesInputPersec'
        PeakCommittedBytes = $peak
    }
}

function Get-Event2004 {
    param([int]$Days)
    $result = @{ Count = 0; Last = $null; Message = $null }
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'
                Id           = 2004
                StartTime    = (Get-Date).AddDays(-$Days)
            } -ErrorAction SilentlyContinue)
        if ($ev.Count -gt 0) {
            $result.Count = $ev.Count
            $newest = $ev | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $result.Last = $newest.TimeCreated.ToString('o')
            $msg = [string]$newest.Message
            $result.Message = $msg.Substring(0, [math]::Min(300, $msg.Length))
        }
    }
    catch {
        if ($_.Exception.Message -notmatch 'No events were found') { Write-Diag ('event log: ' + $_.Exception.Message) }
    }
    return $result
}

function Get-TopProcesses {
    param([int]$TopN)
    $groups = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
        $priv = 0.0; $ws = 0.0
        foreach ($p in $_.Group) { $priv += [double]$p.PrivateMemorySize64; $ws += [double]$p.WorkingSet64 }
        [pscustomobject]@{
            Name         = $_.Name
            Count        = $_.Count
            PrivateGB    = [math]::Round($priv / 1GB, 2)
            WorkingSetGB = [math]::Round($ws / 1GB, 2)
            _priv        = $priv
        }
    }
    return @($groups | Sort-Object _priv -Descending | Select-Object -First $TopN -Property Name, Count, PrivateGB, WorkingSetGB)
}

function Get-PressureSnapshot {
    param([int]$TopN, [int]$Days, [bool]$IncludeProcesses = $true, [bool]$IncludeEvents = $true)

    $m  = Get-MemorySamples
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $ramKB = [double](Get-CimValue $os 'TotalVisibleMemorySize')
    $ramGB = $ramKB / 1MB
    $ramMB = $ramKB / 1KB

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $auto = [bool](Get-CimValue $cs 'AutomaticManagedPagefile')

    $files = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object {
            @{
                Name              = Get-CimValue $_ 'Name'
                AllocatedBaseSize = [double](Get-CimValue $_ 'AllocatedBaseSize')
                CurrentUsage      = [double](Get-CimValue $_ 'CurrentUsage')
                PeakUsage         = [double](Get-CimValue $_ 'PeakUsage')
            }
        })

    # Configured size (read-only). A change made in System Properties only takes effect after a restart,
    # so the configured minimum can be larger than the allocated file.
    $configuredMB = @{}
    $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $paging = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles
    foreach ($line in @($paging)) {
        if ("$line" -match '^\s*(\S+)\s+(\d+)\s+(\d+)') { $configuredMB[$Matches[1].ToLowerInvariant()] = @([double]$Matches[2], [double]$Matches[3]) }
    }
    foreach ($f in $files) {
        $cfg = $configuredMB["$($f.Name)".ToLowerInvariant()]
        $f.ConfiguredMinMB = if ($cfg) { $cfg[0] } else { $null }
        $f.ConfiguredMaxMB = if ($cfg) { $cfg[1] } else { $null }
        $f.PendingRestart = [bool]($cfg -and -not $auto -and $cfg[0] -gt $f.AllocatedBaseSize)
    }

    $usedGB  = if ($null -ne $m.CommittedBytes) { [double]$m.CommittedBytes / 1GB } else { 0.0 }
    $limitGB = if ($null -ne $m.CommitLimit) { [double]$m.CommitLimit / 1GB } else { 0.0 }
    $pct = $null
    if ($limitGB -gt 0) { $pct = $usedGB / $limitGB * 100 }
    elseif ($null -ne $m.PercentCommitted) { $pct = [double]$m.PercentCommitted }

    $ev = if ($IncludeEvents) { Get-Event2004 -Days $Days } else { @{ Count = 0; Last = $null; Message = $null } }
    $availMB = $null
    if ($null -ne $m.AvailableMBytes) { $availMB = [double]$m.AvailableMBytes }

    $sample = @{
        CommitPct         = $pct
        PagesOutputPerSec = $m.PagesOutputPerSec
        AvailableMB       = $availMB
        RamMB             = $ramMB
        Event2004Count    = $ev.Count
        EventDays         = $Days
        Pagefiles         = $files
    }
    $verdict = Get-PressureVerdict -Sample $sample

    $pfGB = 0.0
    # Advise against the size that will be in effect after a restart, not a file that is about to grow.
    foreach ($f in $files) { $pfGB += [math]::Max($f.AllocatedBaseSize, [double]$f.ConfiguredMinMB) / 1024 }
    $advice = Get-PagefileAdvice -RamGB $ramGB -PeakCommitGB ([double]$m.PeakCommittedBytes / 1GB) -PagefileGB $pfGB -AutoManaged $auto

    $modMB = $null
    if ($null -ne $m.ModifiedBytes) { $modMB = [double]$m.ModifiedBytes / 1MB }

    return @{
        Timestamp = Get-Date
        RamGB = $ramGB; UsedGB = $usedGB; LimitGB = $limitGB; CommitPct = $pct
        AvailableMB = $availMB; PagesOut = $m.PagesOutputPerSec; PagesIn = $m.PagesInputPerSec
        ModifiedMB = $modMB; Pagefiles = $files; PagefileGB = $pfGB; Auto = $auto
        Event = $ev; Verdict = $verdict; Advice = $advice
        PeakCommitGB = [double]$m.PeakCommittedBytes / 1GB
        Top = if ($IncludeProcesses) { Get-TopProcesses -TopN $TopN } else { @() }
    }
}

# ---------------------------------------------------------------- output

function Write-Diag {
    # Diagnostics go to stderr so -AsJson keeps stdout clean.
    param([string]$Message)
    [Console]::Error.WriteLine('WARNING: ' + $Message)
}

function Format-Num {
    param($Value, [string]$Fmt = '0.0')
    if ($null -eq $Value) { return 'n/a' }
    return ([double]$Value).ToString($Fmt, $script:Inv)
}

function ConvertTo-JsonReport {
    param($Snap)
    $obj = [ordered]@{
        timestamp         = $Snap.Timestamp.ToString('o')
        ramGB             = [math]::Round($Snap.RamGB, 2)
        commit            = [ordered]@{
            usedGB  = [math]::Round($Snap.UsedGB, 2)
            limitGB = [math]::Round($Snap.LimitGB, 2)
            pct     = if ($null -ne $Snap.CommitPct) { [math]::Round($Snap.CommitPct, 1) } else { $null }
        }
        availableMB       = $Snap.AvailableMB
        pagesOutputPerSec = if ($null -ne $Snap.PagesOut) { [math]::Round($Snap.PagesOut, 1) } else { $null }
        pagesInputPerSec  = if ($null -ne $Snap.PagesIn) { [math]::Round($Snap.PagesIn, 1) } else { $null }
        modifiedListMB    = if ($null -ne $Snap.ModifiedMB) { [math]::Round($Snap.ModifiedMB, 0) } else { $null }
        pagefiles         = @($Snap.Pagefiles | ForEach-Object {
                [ordered]@{ name = $_.Name; allocatedMB = $_.AllocatedBaseSize; currentUsageMB = $_.CurrentUsage; peakUsageMB = $_.PeakUsage
                    configuredMinMB = $_.ConfiguredMinMB; configuredMaxMB = $_.ConfiguredMaxMB; pendingRestart = $_.PendingRestart }
            })
        autoManagedPagefile = $Snap.Auto
        event2004         = [ordered]@{ count = $Snap.Event.Count; last = $Snap.Event.Last; message = $Snap.Event.Message }
        verdict           = [ordered]@{ status = $Snap.Verdict.Status; reasons = @($Snap.Verdict.Reasons) }
        topProcesses      = @($Snap.Top)
        pagefileAdvice    = [ordered]@{ suggestedMinGB = $Snap.Advice.SuggestedMinGB; text = $Snap.Advice.Text }
    }
    return ($obj | ConvertTo-Json -Depth 6)
}

function Write-HumanReport {
    param($Snap)
    Write-Host ('Memory pressure report  {0}' -f $Snap.Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ('RAM:               {0} GB' -f (Format-Num $Snap.RamGB))
    Write-Host ('Commit:            {0} / {1} GB  ({2} %)' -f (Format-Num $Snap.UsedGB), (Format-Num $Snap.LimitGB), (Format-Num $Snap.CommitPct))
    Write-Host ('Available:         {0} MB' -f (Format-Num $Snap.AvailableMB '0'))
    Write-Host ('Pages Output/sec:  {0}' -f (Format-Num $Snap.PagesOut))
    Write-Host ('Pages Input/sec:   {0}' -f (Format-Num $Snap.PagesIn))
    Write-Host ('Modified list:     {0} MB' -f (Format-Num $Snap.ModifiedMB '0'))
    $mode = if ($Snap.Auto) { 'system-managed' } else { 'fixed size' }
    if ($Snap.Pagefiles.Count -eq 0) { Write-Host 'Pagefiles:         none' }
    foreach ($f in $Snap.Pagefiles) {
        Write-Host ('Pagefile:          {0}  allocated {1} MB, in use {2} MB, peak {3} MB ({4})' -f $f.Name, $f.AllocatedBaseSize, $f.CurrentUsage, $f.PeakUsage, $mode)
        if ($f.PendingRestart) {
            Write-Host ('                   configured {0}-{1} MB, takes effect after a restart' -f $f.ConfiguredMinMB, $f.ConfiguredMaxMB)
        }
    }
    Write-Host ''
    Write-Host ('Verdict: {0}' -f $Snap.Verdict.Status)
    foreach ($r in $Snap.Verdict.Reasons) { Write-Host ('  - {0}' -f $r) }
    Write-Host ''
    if ($Snap.Event.Count -gt 0) {
        Write-Host ('Event 2004 (Resource-Exhaustion-Detector): {0} in last {1} days, last {2}' -f $Snap.Event.Count, $EventDays, $Snap.Event.Last)
        Write-Host ('  ' + $Snap.Event.Message)
    }
    else {
        Write-Host ('Event 2004 (Resource-Exhaustion-Detector): none in last {0} days' -f $EventDays)
    }
    Write-Host ''
    Write-Host ('Top {0} processes by private bytes:' -f $Top)
    ($Snap.Top | Format-Table Name, Count, PrivateGB, WorkingSetGB -AutoSize | Out-String).TrimEnd() | Write-Host
    Write-Host ''
    Write-Host ('Pagefile advice (suggested minimum {0} GB, peak commit this run {1} GB):' -f $Snap.Advice.SuggestedMinGB, (Format-Num $Snap.PeakCommitGB))
    Write-Host ('  ' + $Snap.Advice.Text)
}

function Get-CompactLine {
    param($Snap)
    return ('{0}  commit {1,5}%  avail {2,6} MB  pagesOut {3,7}/s  {4}' -f
        $Snap.Timestamp.ToString('HH:mm:ss'), (Format-Num $Snap.CommitPct), (Format-Num $Snap.AvailableMB '0'),
        (Format-Num $Snap.PagesOut), $Snap.Verdict.Status)
}

function Add-CsvRow {
    param([string]$Path, $Snap)
    $header = 'timestamp,commitPct,commitUsedGB,commitLimitGB,availableMB,pagesOutputPerSec,pagesInputPerSec,modifiedListMB,status'
    $row = @(
        $Snap.Timestamp.ToString('o'), (Format-Num $Snap.CommitPct), (Format-Num $Snap.UsedGB '0.00'), (Format-Num $Snap.LimitGB '0.00'),
        (Format-Num $Snap.AvailableMB '0'), (Format-Num $Snap.PagesOut), (Format-Num $Snap.PagesIn), (Format-Num $Snap.ModifiedMB '0'),
        $Snap.Verdict.Status
    ) -join ','
    $enc = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path -LiteralPath $Path)) { [System.IO.File]::AppendAllText($Path, $header + "`r`n", $enc) }
    [System.IO.File]::AppendAllText($Path, $row + "`r`n", $enc)
}

function Send-PressureToast {
    param([string]$Status, [string]$Detail)
    $title = 'Memory pressure: ' + $Status
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($xml.CreateTextNode($title))
        [void]$nodes.Item(1).AppendChild($xml.CreateTextNode($Detail))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        $notifier.Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    }
    catch {
        # WinRT is not available (PowerShell 7): console fallback.
        Write-Warning ($title + ' - ' + $Detail)
        try { [Console]::Beep() } catch { }
    }
}

# ---------------------------------------------------------------- self-test

function Invoke-SelfTest {
    $fails = 0
    $check = {
        param([string]$Name, [bool]$Ok)
        if ($Ok) { Write-Host ('PASS  ' + $Name) } else { Write-Host ('FAIL  ' + $Name); $script:stFails++ }
    }
    $script:stFails = 0

    $base = { param($o) $s = @{ RamMB = 32768; CommitPct = 50; PagesOutputPerSec = 0; AvailableMB = 12000; Event2004Count = 0; EventDays = 7; Pagefiles = @() }; foreach ($k in $o.Keys) { $s[$k] = $o[$k] }; $s }
    $cases = @(
        @{ N = 'commit 50%, avail 12000 -> OK';            O = @{}; E = 'OK' },
        @{ N = 'commit 87%, pagesOut 0, avail 6000 -> Warning'; O = @{ CommitPct = 87; AvailableMB = 6000 }; E = 'Warning' },
        @{ N = 'commit 92% -> Critical';                   O = @{ CommitPct = 92 }; E = 'Critical' },
        @{ N = 'commit 85%, pagesOut 300 -> Critical';     O = @{ CommitPct = 85; PagesOutputPerSec = 300 }; E = 'Critical' },
        @{ N = 'avail 300 -> Critical';                    O = @{ AvailableMB = 300 }; E = 'Critical' },
        @{ N = 'commit 60%, event 2004 x1 -> Warning';     O = @{ CommitPct = 60; Event2004Count = 1 }; E = 'Warning' },
        @{ N = 'pagefile 2700/2600 MB used -> Warning';    O = @{ Pagefiles = @(@{ AllocatedBaseSize = 2600; CurrentUsage = 2700 }) }; E = 'Warning' }
    )
    foreach ($c in $cases) {
        $v = Get-PressureVerdict -Sample (& $base $c.O)
        & $check ($c.N + ' (got ' + $v.Status + ')') ($v.Status -eq $c.E)
    }

    $a = Get-PagefileAdvice -RamGB 32 -PeakCommitGB 31 -PagefileGB 2.7 -AutoManaged $true
    & $check ('pagefile advice RAM 32, peak 31, pf 2.7 -> 7 GB (got ' + $a.SuggestedMinGB + ')') ($a.SuggestedMinGB -eq 7)
    & $check 'advice text mentions manual change and IT' (($a.Text -match 'Virtual memory') -and ($a.Text -match 'IT'))
    $b = Get-PagefileAdvice -RamGB 32 -PeakCommitGB 20 -PagefileGB 8 -AutoManaged $false
    & $check 'pagefile advice RAM 32, peak 20, pf 8 -> no change needed' ($b.Text -eq 'no change needed')

    $now = Get-Date
    & $check 'toast OK->Warning -> true'   ((Test-ToastDue -Previous 'OK' -Current 'Warning' -LastToastTime $null -Now $now) -eq $true)
    & $check 'toast Warning->Warning -> false' ((Test-ToastDue -Previous 'Warning' -Current 'Warning' -LastToastTime $null -Now $now) -eq $false)
    & $check 'toast Critical->Critical after 5 min -> false' ((Test-ToastDue -Previous 'Critical' -Current 'Critical' -LastToastTime $now.AddMinutes(-5) -Now $now) -eq $false)
    & $check 'toast Critical->Critical after 16 min -> true' ((Test-ToastDue -Previous 'Critical' -Current 'Critical' -LastToastTime $now.AddMinutes(-16) -Now $now) -eq $true)

    # Static scan of this file for forbidden write operations (the literal list itself is excluded).
    $path = $PSCommandPath
    if (-not $path) { $path = $MyInvocation.MyCommand.Path }
    $text = [System.IO.File]::ReadAllText($path)
    $text = [regex]::Replace($text, '(?s)# BEGIN-FORBIDDEN.*?# END-FORBIDDEN', '')
    # BEGIN-FORBIDDEN
    $forbidden = @(
        'Register-ScheduledTask', 'schtasks', 'Set-Service', 'sc.exe', 'powercfg', 'Set-ItemProperty',
        'New-ItemProperty', 'Remove-ItemProperty', 'EmptyWorkingSet', 'SetSystemFileCacheSize',
        'NtSetSystemInformation', 'Win32_PageFileSetting', 'Set-CimInstance', 'Write-EventLog', 'New-EventLog'
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

    if ($AsJson -and $Watch) { throw '-AsJson is one-shot only and cannot be combined with -Watch.' }
    if ($Count -lt 0) { throw '-Count must be 0 or greater.' }
    if ($Top -lt 1) { throw '-Top must be 1 or greater.' }
    if (-not $Watch) {
        foreach ($n in 'Count', 'Toast', 'LogPath') {
            if ($PSBoundParameters.ContainsKey($n)) { throw ('-' + $n + ' only works with -Watch.') }
        }
    }

    if (-not $Watch) {
        $snap = Get-PressureSnapshot -TopN $Top -Days $EventDays
        if ($AsJson) { Write-Output (ConvertTo-JsonReport $snap) } else { Write-HumanReport $snap }
        exit 0
    }

    $previous = 'OK'; $lastToast = $null; $n = 0
    while ($true) {
        $started = Get-Date
        $snap = Get-PressureSnapshot -TopN 1 -Days $EventDays -IncludeProcesses $false
        Write-Host (Get-CompactLine $snap)
        if ($LogPath) { Add-CsvRow -Path $LogPath -Snap $snap }
        $status = $snap.Verdict.Status
        if ($Toast -and (Test-ToastDue -Previous $previous -Current $status -LastToastTime $lastToast -Now (Get-Date))) {
            Send-PressureToast -Status $status -Detail (($snap.Verdict.Reasons -join '; '))
            $lastToast = Get-Date
        }
        $previous = $status
        $n++
        if ($Count -gt 0 -and $n -ge $Count) { break }
        $wait = $IntervalSeconds - ((Get-Date) - $started).TotalSeconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
    exit 1
}
