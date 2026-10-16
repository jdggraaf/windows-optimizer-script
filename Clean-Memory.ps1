<#
.SYNOPSIS
    On-demand / threshold-gated RAM cleaner for Windows 10/11 using only built-in APIs (no RAMMap, no third-party binaries).

.DESCRIPTION
    Frees memory through the undocumented-but-stable NtSetSystemInformation(SystemMemoryListInformation)
    interface (the same mechanism RAMMap, Mem Reduct and similar tools use), plus the system file cache flush.

    Areas (see -Area):
      LowPriorityStandby  Purge only the lowest-priority standby sub-list (command 5). Least harmful standby purge.
      Standby             Purge the whole standby list (command 4). Cache refills from disk afterwards.
      Modified            Write the modified page list to disk so those pages become standby (command 3).
      WorkingSets         Trim every process working set (command 2). Most disruptive: causes soft/hard page-fault churn.
      FileCache           Flush the system file cache working set (SetSystemFileCacheSize(-1,-1), falls back to
                          NtSetSystemInformation class 81 then 21).
      Combined            WorkingSets, FileCache, Modified, Standby (Mem Reduct-style full clean).

    Execution order is always: WorkingSets -> FileCache -> Modified -> Standby, because trimmed pages land on the
    modified/standby lists and must be handled afterwards. If both Standby and LowPriorityStandby are given, only
    Standby runs (it is a superset).

    DEFAULT AREA = LowPriorityStandby + Modified. Justification: these two are the least harmful actions. Flushing
    the modified list only forces already-dirty pages to disk (they would be written eventually) and turns them into
    reclaimable standby pages; purging only the lowest-priority standby sub-list discards the pages the memory
    manager itself values least. Neither touches live working sets, so no fault storm. WorkingSets and a full
    Standby purge are opt-in.

    -Auto makes the script safe to run from a scheduler: it only cleans when available memory is below a threshold
    AND the cooldown since the last clean has elapsed. -Install registers a hidden SYSTEM scheduled task that
    runs the script with -Auto.

    NTSTATUS handling: success is status >= 0 (signed). Failures are reported as hex, e.g. 0xC0000061 =
    STATUS_PRIVILEGE_NOT_HELD.

    HONEST NOTE: Purging caches does not make a PC faster. Standby pages are free, already-useful cache; dropping
    them means the next access reads from disk. Trimming working sets makes running programs fault their memory
    back in. Running this often (or from a short-interval timer) will usually HURT performance. Use it on demand
    (before a game or VM, or after a leaky process) or threshold-gated with a sensible cooldown. Also note that
    "Available" memory already includes standby, so a standby purge shifts memory from standby to free but barely
    changes Available; the report therefore shows Free+Zero and Standby separately. If RAM is low because of
    committed (private) memory, none of these areas can help; close the offending program instead.

    Requires: 64-bit Windows PowerShell 5.1 or PowerShell 7. An elevated session is needed for cleaning, -Install
    and -Uninstall. -Report works without admin, and so does a -WhatIf dry run of a clean.

    SECURITY: -Install copies this script to $env:ProgramData\RamCleaner\Clean-Memory.ps1 and the SYSTEM task runs
    that copy, never the original. The folder gets an ACL with inheritance disabled and only SYSTEM and
    Administrators allowed (FullControl), so standard users cannot alter the code or redirect the log/state files.

.PARAMETER Area
    One or more of LowPriorityStandby, Standby, Modified, WorkingSets, FileCache, Combined.
    Comma-separated list is accepted (also when passed through -File, e.g. by the scheduled task).

.PARAMETER Auto
    Threshold-gated mode: clean only if available memory is below -ThresholdPercent (or -ThresholdMB when > 0)
    and -CooldownMinutes have passed since the last clean. Intended for the scheduled task.

.PARAMETER ThresholdPercent
    Auto mode: clean when available memory is below this percent of total RAM. Default 15.

.PARAMETER ThresholdMB
    Auto mode: also clean when available memory is below this many MB. 0 disables. Default 0.

.PARAMETER CooldownMinutes
    Auto mode: minimum minutes between cleans (state in $env:ProgramData\RamCleaner\last.txt). Default 30.
    Kept high on purpose: if RAM is low because of committed memory, cache purges gain little and repeating
    them only throws away useful cache.

.PARAMETER Force
    Auto mode: ignore threshold and cooldown.

.PARAMETER Install
    Register hidden scheduled task 'RamCleaner' (SYSTEM, highest privileges) that runs a locked-down copy of this
    script with -Auto every -IntervalMinutes. Cannot be combined with -Uninstall.

.PARAMETER Uninstall
    Remove the scheduled task. Cannot be combined with -Install.

.PARAMETER Purge
    With -Uninstall: also delete the data folder $env:ProgramData\RamCleaner (script copy, log, state).

.PARAMETER IntervalMinutes
    Scheduled task repetition interval for -Install. 5 to 1440, default 5.

.PARAMETER Report
    Print the current memory state only. No admin needed, nothing is changed.

.EXAMPLE
    .\Clean-Memory.ps1 -Report
    Show total / available / free+zero / standby / modified memory.

.EXAMPLE
    .\Clean-Memory.ps1
    Default safe clean (LowPriorityStandby + Modified) with before/after report. Run elevated.

.EXAMPLE
    .\Clean-Memory.ps1 -Area Combined -WhatIf
    Show what a full clean would do without doing it (works without elevation).

.EXAMPLE
    .\Clean-Memory.ps1 -Area WorkingSets,Modified,Standby

.EXAMPLE
    .\Clean-Memory.ps1 -Auto -ThresholdPercent 10 -CooldownMinutes 15
    Clean only if less than 10% of RAM is available and the last clean was 15+ minutes ago.

.EXAMPLE
    .\Clean-Memory.ps1 -Install -IntervalMinutes 10 -ThresholdPercent 12
    Register the scheduled task (elevated). Remove it later with -Uninstall (add -Purge to delete the data folder).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ArgumentCompleter({
        param($cmd, $param, $word)
        'LowPriorityStandby', 'Standby', 'Modified', 'WorkingSets', 'FileCache', 'Combined' |
            Where-Object { $_ -like "$word*" }
    })]
    [string[]]$Area = @('LowPriorityStandby', 'Modified'),

    [switch]$Auto,

    [ValidateRange(1, 99)]
    [int]$ThresholdPercent = 15,

    [ValidateRange(0, 1048576)]
    [int]$ThresholdMB = 0,

    [ValidateRange(1, 10080)]
    [int]$CooldownMinutes = 30,

    [switch]$Force,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Purge,

    [ValidateRange(5, 1440)]
    [int]$IntervalMinutes = 5,

    [switch]$Report
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:DataDir  = Join-Path $env:ProgramData 'RamCleaner'
$script:LogFile  = Join-Path $script:DataDir 'log.txt'
$script:StateFile = Join-Path $script:DataDir 'last.txt'
$script:TaskName = 'RamCleaner'
$script:LogMaxBytes = 1MB

# ---------------------------------------------------------------- native code
# C# 5 compatible (Windows PowerShell 5.1 compiler). Guarded so re-running in one session is safe.
# The type name carries a version (NativeV1): bump it whenever the C# below changes, otherwise a long-lived
# session (ISE, dot-sourced host) keeps using the stale compiled type.
if (-not ('RamCleaner.NativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace RamCleaner {
  public static class NativeV1 {
    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES { public uint Count; public LUID Luid; public uint Attr; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX {
      public uint dwLength; public uint dwMemoryLoad;
      public ulong ullTotalPhys; public ulong ullAvailPhys;
      public ulong ullTotalPageFile; public ulong ullAvailPageFile;
      public ulong ullTotalVirtual; public ulong ullAvailVirtual;
      public ulong ullAvailExtendedVirtual;
    }

    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int cls, IntPtr buf, int len);

    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetSystemFileCacheSize(UIntPtr min, UIntPtr max, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX b);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr tok);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValueW(string sys, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TOKEN_PRIVILEGES np, int len, IntPtr prev, IntPtr retLen);

    // Enables a privilege on the current process token. Returns false if it could not be assigned.
    // win32Error is the Win32 error at the failing step (1300 = ERROR_NOT_ALL_ASSIGNED: privilege not in token).
    // AdjustTokenPrivileges returns TRUE even for 1300, so the last error is checked after a TRUE return.
    public static bool EnablePrivilege(string name, out int win32Error) {
      win32Error = 0;
      IntPtr tok;
      if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) { win32Error = Marshal.GetLastWin32Error(); return false; } // ADJUST | QUERY
      try {
        LUID luid;
        if (!LookupPrivilegeValueW(null, name, out luid)) { win32Error = Marshal.GetLastWin32Error(); return false; }
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.Count = 1; tp.Luid = luid; tp.Attr = 2; // SE_PRIVILEGE_ENABLED
        if (!AdjustTokenPrivileges(tok, false, ref tp, Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), IntPtr.Zero, IntPtr.Zero)) { win32Error = Marshal.GetLastWin32Error(); return false; }
        win32Error = Marshal.GetLastWin32Error();
        return win32Error == 0;
      } finally { CloseHandle(tok); }
    }

    // SystemMemoryListInformation = 80. cmd: 2 EmptyWorkingSets, 3 FlushModifiedList,
    // 4 PurgeStandbyList, 5 PurgeLowPriorityStandbyList. Returns raw NTSTATUS (success >= 0).
    public static int MemoryListCommand(int cmd) {
      IntPtr p = Marshal.AllocHGlobal(4);
      try { Marshal.WriteInt32(p, cmd); return NtSetSystemInformation(80, p, 4); }
      finally { Marshal.FreeHGlobal(p); }
    }

    // SystemFileCacheInformation (21) / SystemFileCacheInformationEx (81): set min = max = (SIZE_T)-1, flags 0.
    static int FileCacheNt(int cls) {
      bool x64 = IntPtr.Size == 8;
      int size = x64 ? 0x40 : 0x24;
      int offMin = x64 ? 0x18 : 0x0C;
      int offMax = x64 ? 0x20 : 0x10;
      IntPtr p = Marshal.AllocHGlobal(size);
      try {
        for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteIntPtr(p, offMin, new IntPtr(-1));
        Marshal.WriteIntPtr(p, offMax, new IntPtr(-1));
        return NtSetSystemInformation(cls, p, size);
      } finally { Marshal.FreeHGlobal(p); }
    }

    // Documented route first; falls back to the Nt classes. Returns NTSTATUS-style int (>= 0 success).
    // via = which route produced the result. If every route fails, the status of the last route (class 21) is returned.
    public static int FlushFileCache(out string via) {
      UIntPtr all = UIntPtr.Size == 8 ? new UIntPtr(ulong.MaxValue) : new UIntPtr(uint.MaxValue);
      if (SetSystemFileCacheSize(all, all, 0)) { via = "SetSystemFileCacheSize"; return 0; }
      int win32 = Marshal.GetLastWin32Error();
      int st = FileCacheNt(81);
      if (st >= 0) { via = "NtSetSystemInformation(81)"; return st; }
      int st2 = FileCacheNt(21);
      if (st2 >= 0) { via = "NtSetSystemInformation(21)"; return st2; }
      via = "all routes failed (Win32 error " + win32 + ", class 81 status 0x" + st.ToString("X8") + ")";
      return st2;
    }

    public static bool GetTotals(out ulong total, out ulong avail) {
      MEMORYSTATUSEX m = new MEMORYSTATUSEX();
      m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
      bool ok = GlobalMemoryStatusEx(ref m);
      total = m.ullTotalPhys; avail = m.ullAvailPhys;
      return ok;
    }
  }
}
'@
}

# ------------------------------------------------------------------- helpers
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-64Bit {
    # A 32-bit host on 64-bit Windows goes through WOW64, which does not reliably thunk the
    # SystemFileCacheInformation structs or SetSystemFileCacheSize.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'This is a 32-bit PowerShell process on 64-bit Windows. Run it in 64-bit PowerShell (not the x86 shortcut/ISE).'
    }
}

function Stop-WithError([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

function Format-Status([int]$s) { '0x{0:X8}' -f $s }

# Culture-independent formatting, so the log reads the same in PowerShell 5.1 and 7 on any locale.
function Format-Inv([string]$Format, [object[]]$Values) {
    [string]::Format([Globalization.CultureInfo]::InvariantCulture, $Format, $Values)
}

function Test-ReparsePoint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Creates the data folder. When newly created while elevated (or with -Secure) the ACL is locked to
# SYSTEM + Administrators with inheritance disabled, so standard users cannot plant junctions/hardlinks
# or replace the script copy.
function Initialize-DataDir([switch]$Secure) {
    $created = $false
    if (Test-Path -LiteralPath $script:DataDir) {
        if (Test-ReparsePoint $script:DataDir) { throw "Refusing to use '$($script:DataDir)': it is a reparse point (junction/symlink)." }
    } else {
        # Never create the folder unelevated: it would inherit the permissive ProgramData ACL.
        if (-not (Test-Elevated)) { throw 'Data folder does not exist and the session is not elevated; not creating it.' }
        New-Item -ItemType Directory -Path $script:DataDir -Force -WhatIf:$false | Out-Null
        $created = $true
    }
    if ($Secure -or ($created -and (Test-Elevated))) {
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        foreach ($sidText in 'S-1-5-18', 'S-1-5-32-544') {
            $sid  = New-Object System.Security.Principal.SecurityIdentifier($sidText)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $sec.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $script:DataDir -AclObject $sec -WhatIf:$false
    }
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    if ($WhatIfPreference) { Write-Verbose "[$Level] $Message"; return }   # a dry run writes nothing to disk
    try {
        Initialize-DataDir
        if (Test-ReparsePoint $script:LogFile) { return }
        if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt $script:LogMaxBytes)) {
            Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.old') -Force -WhatIf:$false
        }
        $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false
    } catch {
        Write-Verbose ("Logging failed: " + $_.Exception.Message)
    }
}

function Get-MemSnapshot {
    $WhatIfPreference = $false   # read-only; stops -WhatIf leaking into module auto-import (alias noise)
    [uint64]$total = 0; [uint64]$avail = 0
    if (-not [RamCleaner.NativeV1]::GetTotals([ref]$total, [ref]$avail)) { throw 'GlobalMemoryStatusEx failed.' }

    $freeZero = $null; $standby = $null; $modified = $null
    try {
        $c = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        $names = @($c.PSObject.Properties.Name)
        $get = {
            param($n)
            if ($names -contains $n -and $null -ne $c.$n) { [uint64]$c.$n } else { $null }
        }
        $freeZero = & $get 'FreeAndZeroPageListBytes'
        $modified = & $get 'ModifiedPageListBytes'
        $sb = 0; $any = $false
        foreach ($n in 'StandbyCacheNormalPriorityBytes', 'StandbyCacheReserveBytes', 'StandbyCacheCoreBytes') {
            $v = & $get $n
            if ($null -ne $v) { $sb += $v; $any = $true }
        }
        if ($any) { $standby = [uint64]$sb }
    } catch {
        Write-Verbose ("Perf class unavailable: " + $_.Exception.Message)
    }
    if ($null -eq $freeZero) {
        # Fallback: Win32_OperatingSystem reports KB, free list only.
        try { $freeZero = [uint64]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory) * 1KB } catch { }
    }

    $mb = { param($b) if ($null -eq $b) { $null } else { [math]::Round([double]$b / 1MB, 0) } }
    [pscustomobject]@{
        TotalMB     = & $mb $total
        AvailableMB = & $mb $avail
        FreeZeroMB  = & $mb $freeZero
        StandbyMB   = & $mb $standby
        ModifiedMB  = & $mb $modified
    }
}

function Show-Snapshot([string]$Title, $Snap) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    $fmt = { param($v) if ($null -eq $v) { 'n/a' } else { Format-Inv '{0:N0} MB' $v } }
    '  Total       : ' + (& $fmt $Snap.TotalMB)
    '  Available   : ' + (& $fmt $Snap.AvailableMB) + '  (free + zero + standby)'
    '  Free + Zero : ' + (& $fmt $Snap.FreeZeroMB)
    '  Standby     : ' + (& $fmt $Snap.StandbyMB)
    '  Modified    : ' + (& $fmt $Snap.ModifiedMB)
}

function Format-SnapshotLine($s) {
    'Total={0}MB Avail={1}MB FreeZero={2}MB Standby={3}MB Modified={4}MB' -f $s.TotalMB, $s.AvailableMB, $s.FreeZeroMB, $s.StandbyMB, $s.ModifiedMB
}

function Get-Delta($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return 'n/a' }
    $d = $b - $a
    Format-Inv '{0}{1:N0} MB' @($(if ($d -ge 0) { '+' } else { '-' }), [math]::Abs($d))
}

function Resolve-Areas([string[]]$Raw) {
    $valid = 'LowPriorityStandby', 'Standby', 'Modified', 'WorkingSets', 'FileCache', 'Combined'
    $set = @{}
    foreach ($item in $Raw) {
        foreach ($part in ($item -split '[,;\s]+')) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $match = $valid | Where-Object { $_ -ieq $part }
            if (-not $match) { throw "Invalid -Area '$part'. Valid: $($valid -join ', ')." }
            if ($match -eq 'Combined') { foreach ($x in 'WorkingSets', 'FileCache', 'Modified', 'Standby') { $set[$x] = $true } }
            else { $set[[string]$match] = $true }
        }
    }
    if ($set.Count -eq 0) { throw 'No -Area specified.' }
    if ($set.ContainsKey('Standby')) { $set.Remove('LowPriorityStandby') }
    # fixed execution order
    @('WorkingSets', 'FileCache', 'Modified', 'Standby', 'LowPriorityStandby') | Where-Object { $set.ContainsKey($_) }
}

function Invoke-Area([string]$Name) {
    $via = ''
    [int]$st = -1
    switch ($Name) {
        'WorkingSets'        { $st = [RamCleaner.NativeV1]::MemoryListCommand(2) }
        'Modified'           { $st = [RamCleaner.NativeV1]::MemoryListCommand(3) }
        'Standby'            { $st = [RamCleaner.NativeV1]::MemoryListCommand(4) }
        'LowPriorityStandby' { $st = [RamCleaner.NativeV1]::MemoryListCommand(5) }
        'FileCache'          { $st = [RamCleaner.NativeV1]::FlushFileCache([ref]$via) }
        default              { throw "Unknown area '$Name'." }
    }
    [pscustomobject]@{
        Area    = $Name
        Success = ($st -ge 0)               # NT_SUCCESS
        Status  = Format-Status $st
        Detail  = $via
    }
}

function Get-LastCleanTime {
    try {
        if (Test-Path -LiteralPath $script:StateFile) {
            $txt = (Get-Content -LiteralPath $script:StateFile -Raw).Trim()
            return [datetime]::Parse($txt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
    } catch { }
    return [datetime]::MinValue
}

function Set-LastCleanTime {
    Initialize-DataDir
    if (Test-ReparsePoint $script:StateFile) { throw "Refusing to write '$($script:StateFile)': it is a reparse point." }
    Set-Content -LiteralPath $script:StateFile -Value (Get-Date).ToUniversalTime().ToString('o') -Encoding ASCII -WhatIf:$false
}

# ------------------------------------------------------------------- Report
if ($Report) {
    Show-Snapshot 'Current memory state' (Get-MemSnapshot)
    return
}

# --------------------------------------------------------- Install/Uninstall
if ($Install -and $Uninstall) { Stop-WithError '-Install and -Uninstall cannot be used together.' }
if ($Purge -and -not $Uninstall) { Stop-WithError '-Purge is only valid together with -Uninstall.' }

if ($Install -or $Uninstall) {
    if (-not (Test-Elevated)) {
        Stop-WithError 'Install/Uninstall requires an elevated (Run as administrator) PowerShell session.'
    }
    if ($Uninstall) {
        if ($PSCmdlet.ShouldProcess($script:TaskName, 'Unregister scheduled task')) {
            if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
                if (-not $Purge) { Write-Log "Scheduled task '$($script:TaskName)' removed." }
                Write-Host "Scheduled task '$($script:TaskName)' removed."
            } else {
                Write-Host "Scheduled task '$($script:TaskName)' not found."
            }
        }
        if ($Purge -and (Test-Path -LiteralPath $script:DataDir)) {
            if (Test-ReparsePoint $script:DataDir) {
                Write-Warning "Not deleting '$($script:DataDir)': it is a reparse point. Remove it manually."
            } elseif ($PSCmdlet.ShouldProcess($script:DataDir, 'Delete data folder (script copy, log, state)')) {
                Remove-Item -LiteralPath $script:DataDir -Recurse -Force -Confirm:$false -WhatIf:$false
                Write-Host "Deleted '$($script:DataDir)'."
            }
        } elseif (-not $Purge -and (Test-Path -LiteralPath $script:DataDir)) {
            Write-Host "Data folder kept: $($script:DataDir) (use -Uninstall -Purge to delete it)."
        }
        return
    }

    Assert-64Bit
    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { Stop-WithError 'Cannot determine script path; run it from a saved .ps1 file.' }
    $areas = Resolve-Areas $Area

    # Host executable: whatever runs this, unless it is a Store/MSIX pwsh (SYSTEM cannot execute WindowsApps paths).
    $exe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrEmpty($exe) -or $exe -match '\\WindowsApps\\') {
        $fallback = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Write-Warning "Current host '$exe' is not runnable by SYSTEM (Store/MSIX install). Using $fallback instead."
        $exe = $fallback
    }

    # The task must not run a script that standard users can edit: run a locked-down copy.
    $runScript = Join-Path $script:DataDir 'Clean-Memory.ps1'
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Auto -Area {1} -ThresholdPercent {2} -ThresholdMB {3} -CooldownMinutes {4}' -f $runScript, ($areas -join ','), $ThresholdPercent, $ThresholdMB, $CooldownMinutes
    if ($PSCmdlet.ShouldProcess($script:TaskName, "Copy script to $runScript and register scheduled task every $IntervalMinutes min: $exe $argLine")) {
        Initialize-DataDir -Secure
        if ($self -ne $runScript) {
            if (Test-Path -LiteralPath $runScript) { Remove-Item -LiteralPath $runScript -Force -Confirm:$false -WhatIf:$false }
            Copy-Item -LiteralPath $self -Destination $runScript -Force -Confirm:$false -WhatIf:$false
        }
        $action    = New-ScheduledTaskAction -Execute $exe -Argument $argLine
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Threshold-gated RAM cleaner (Clean-Memory.ps1 -Auto)' -Force | Out-Null
        Write-Log "Scheduled task installed: every $IntervalMinutes min, areas=$($areas -join ','), threshold=$ThresholdPercent% / ${ThresholdMB}MB, cooldown=${CooldownMinutes}min, script=$runScript."
        Write-Host "Scheduled task '$($script:TaskName)' installed (hidden, SYSTEM, every $IntervalMinutes min, -Auto)."
        Write-Host "It runs the locked-down copy $runScript (re-run -Install after editing this script)."
        Write-Host "It only cleans when available RAM < $ThresholdPercent% and $CooldownMinutes min have passed since the last clean."
    }
    return
}

# --------------------------------------------------------------------- Clean
# A -WhatIf dry run changes nothing, so it does not need elevation.
$dryRun = [bool]$WhatIfPreference
if (-not $dryRun -and -not (Test-Elevated)) {
    Stop-WithError 'Cleaning memory requires an elevated (Run as administrator) PowerShell session. Use -Report for a read-only view, or -WhatIf for a dry run.'
}
Assert-64Bit

$areas = Resolve-Areas $Area
$failed = $false

# single-instance guard
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, 'Global\RamCleanerMutex', [ref]$createdNew)
$hasLock = $false
try {
    try { $hasLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasLock = $true }
    if (-not $hasLock) { Write-Warning 'Another RamCleaner run is in progress; exiting.'; exit 0 }

    $before = Get-MemSnapshot

    if ($Auto -and -not $Force) {
        $availPct = 100.0 * $before.AvailableMB / $before.TotalMB
        $low = ($availPct -lt $ThresholdPercent) -or ($ThresholdMB -gt 0 -and $before.AvailableMB -lt $ThresholdMB)
        if (-not $low) {
            $msg = Format-Inv 'Auto: skipped, memory ok ({0:N1}% available, threshold {1}%).' $availPct, $ThresholdPercent
            Write-Log ($msg + ' ' + (Format-SnapshotLine $before))
            Write-Host $msg
            return
        }
        $last = Get-LastCleanTime
        $age = ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalMinutes
        if ($age -lt $CooldownMinutes) {
            $msg = Format-Inv 'Auto: skipped, cooldown ({0:N1} of {1} min elapsed since the last clean).' $age, $CooldownMinutes
            Write-Log $msg
            Write-Host $msg
            return
        }
    }

    $tag = if ($dryRun) { ' (WhatIf)' } else { '' }
    Write-Log ("Clean start$tag. Areas=$($areas -join ',') Auto=$($Auto.IsPresent) Force=$($Force.IsPresent). Before: " + (Format-SnapshotLine $before))

    # Enable privileges. SeProfileSingleProcessPrivilege is required for the memory list commands;
    # SeIncreaseQuotaPrivilege for working set / file cache operations. Skipped in a dry run.
    $privOk = @{}
    if (-not $dryRun) {
        foreach ($p in 'SeProfileSingleProcessPrivilege', 'SeIncreaseQuotaPrivilege') {
            [int]$werr = 0
            $privOk[$p] = [RamCleaner.NativeV1]::EnablePrivilege($p, [ref]$werr)
            if (-not $privOk[$p]) {
                $why = if ($werr -eq 1300) { 'privilege not held by this token (1300)' } else { "Win32 error $werr" }
                Write-Warning "Could not enable ${p}: $why. Related areas may fail with 0xC0000061."
                Write-Log "Could not enable ${p}: $why" 'WARN'
            }
        }
    }

    Show-Snapshot 'Before' $before

    $results = @()
    foreach ($a in $areas) {
        if ($PSCmdlet.ShouldProcess("memory area $a", 'Clean')) {
            try { $r = Invoke-Area $a }
            catch { $r = [pscustomobject]@{ Area = $a; Success = $false; Status = $_.Exception.Message; Detail = '' } }
            $results += $r
            $msg = '{0}: {1} ({2}){3}' -f $a, $(if ($r.Success) { 'OK' } else { 'FAILED' }), $r.Status, $(if ($r.Detail) { ' via ' + $r.Detail } else { '' })
            if ($r.Success) { Write-Log $msg } else { Write-Log $msg 'ERROR'; Write-Warning $msg }
            if ($a -eq 'Modified' -or $a -eq 'WorkingSets') { Start-Sleep -Milliseconds 500 } # let lists settle
        }
    }

    if ($results.Count -gt 0) {
        Start-Sleep -Milliseconds 500
        $after = Get-MemSnapshot
        Show-Snapshot 'After' $after

        Write-Host ''
        Write-Host 'Results' -ForegroundColor Cyan
        $results | Format-Table Area, Success, Status, Detail -AutoSize | Out-String | Write-Host

        Write-Host 'Change' -ForegroundColor Cyan
        $standbyRan = @($results | Where-Object { $_.Area -in 'Standby', 'LowPriorityStandby' }).Count -gt 0
        '  Available   : ' + (Get-Delta $before.AvailableMB $after.AvailableMB) + $(if ($standbyRan) { '  (barely moves after a standby purge: standby counts as available)' } else { '' })
        '  Free + Zero : ' + (Get-Delta $before.FreeZeroMB $after.FreeZeroMB)
        '  Standby     : ' + (Get-Delta $before.StandbyMB $after.StandbyMB)
        '  Modified    : ' + (Get-Delta $before.ModifiedMB $after.ModifiedMB)

        Write-Log ("Clean done. After: " + (Format-SnapshotLine $after) + ' | AvailableDelta=' + (Get-Delta $before.AvailableMB $after.AvailableMB) + ' FreeZeroDelta=' + (Get-Delta $before.FreeZeroMB $after.FreeZeroMB))

        if (@($results | Where-Object { $_.Success }).Count -gt 0) { Set-LastCleanTime }
        if (@($results | Where-Object { -not $_.Success }).Count -gt 0) { $failed = $true }
    }
}
finally {
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
# The exit code must be set with 'exit': $global:LASTEXITCODE is ignored by powershell -File.
if ($failed) { exit 2 }
