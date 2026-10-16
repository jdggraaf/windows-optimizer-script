# Clean-Memory.ps1

A RAM cleaner for Windows 10/11 that uses only built-in Windows APIs. There is no RAMMap, no third-party binary and no driver. It calls `NtSetSystemInformation(SystemMemoryListInformation)` and `SetSystemFileCacheSize`, the same mechanisms RAMMap and Mem Reduct use. It runs on 64-bit Windows PowerShell 5.1 and PowerShell 7.

## What it does

It moves pages between the kernel's memory lists (working sets, modified, standby, free) and prints a before and after report. It can run on demand, or as a threshold-gated scheduled task that only cleans when available RAM is low.

## Areas

| Area | What it does |
|---|---|
| `LowPriorityStandby` | Purges only the lowest-priority standby sub-list. This is the gentlest standby purge. |
| `Standby` | Purges the whole standby list. The cache refills from disk afterwards. |
| `Modified` | Writes the modified page list to disk so those pages become reclaimable standby pages. |
| `WorkingSets` | Trims every process's working set. This is the most disruptive area, because programs fault their pages back in. |
| `FileCache` | Flushes the system file cache working set. |
| `Combined` | Runs `WorkingSets`, `FileCache`, `Modified` and `Standby`, in that order. |

The execution order is always WorkingSets, FileCache, Modified, Standby. If both `Standby` and `LowPriorityStandby` are given, only `Standby` runs.

The default is `LowPriorityStandby` plus `Modified`. These are the least harmful actions and they do not touch live working sets.

## Usage

```powershell
.\Clean-Memory.ps1 -Report                         # read-only memory state, no admin needed
.\Clean-Memory.ps1                                 # default safe clean (run elevated)
.\Clean-Memory.ps1 -Area Combined -WhatIf          # dry run, works without elevation
.\Clean-Memory.ps1 -Area WorkingSets,Modified,Standby
.\Clean-Memory.ps1 -Auto -ThresholdPercent 10 -CooldownMinutes 15
.\Clean-Memory.ps1 -Auto -Force                    # scheduler mode, ignoring threshold and cooldown
Get-Help .\Clean-Memory.ps1 -Full
```

The exit code is 0 on success, 1 on a usage or elevation error, and 2 if any area failed.

## Install and uninstall (elevated 64-bit PowerShell)

```powershell
.\Clean-Memory.ps1 -Install -IntervalMinutes 10 -ThresholdPercent 12 -CooldownMinutes 30
.\Clean-Memory.ps1 -Uninstall            # removes the task and keeps the data folder
.\Clean-Memory.ps1 -Uninstall -Purge     # also deletes the data folder
```

`-Install` does the following:

- It copies the script to `%ProgramData%\RamCleaner\Clean-Memory.ps1`. The SYSTEM task runs that copy, never the original.
- It locks the `%ProgramData%\RamCleaner` folder so only SYSTEM and Administrators have access, and inheritance is disabled. Standard users therefore cannot change the code that runs as SYSTEM, and cannot plant links to redirect the log or state files.
- It registers a hidden task named `RamCleaner` that runs as SYSTEM at the highest run level, with `-Auto`. It only cleans when available RAM is below the threshold and the cooldown has passed.
- If the current host is a Store or MSIX PowerShell, which SYSTEM cannot execute, it falls back to Windows PowerShell.

Re-run `-Install` after you edit the script, so the locked copy is refreshed. `-Install` and `-Uninstall` cannot be combined.

Logs go to `%ProgramData%\RamCleaner\log.txt`. They rotate at 1 MB to `log.txt.old`. The last-clean time is in `last.txt`.

## Caveats

- **Cleaning RAM does not make a PC faster.** Standby pages are free, already-useful cache. Dropping them means the next access reads from disk. Trimming working sets forces running programs to fault pages back in.
- **"Available" memory already includes standby.** A standby purge shifts memory from standby to free and barely changes Available. The report shows Free+Zero and Standby separately for this reason.
- **It cannot help when the shortage is committed memory.** If RAM is low because programs hold it privately, close or fix those programs. This is why `-CooldownMinutes` defaults to 30, so a low-RAM condition that purging cannot fix does not trigger repeated purges.
- **Use it on demand**, for example before a game or VM or after a leaky process. Do not run it on a very short timer.
- **Elevation is required** to clean, and for `-Install` and `-Uninstall`. `-Report` and `-WhatIf` need no elevation.
- **A 32-bit PowerShell on 64-bit Windows is refused.** WOW64 does not reliably translate the file cache calls.
- **The memory list interface is undocumented.** It has been stable for many Windows versions, but Microsoft could change it. Failures show up as NTSTATUS hex, for example `0xC0000061` for a missing privilege.
- **Security tools may flag it.** Some EDR products flag programs that call `NtSetSystemInformation`. The script compiles a small C# helper with `Add-Type` on each run.
- **Native type versioning:** the helper type is named `RamCleaner.NativeV1`. Bump the suffix when the C# changes, so long-lived sessions don't reuse a stale compiled copy.
