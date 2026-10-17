# DebloatKit

A reversible Windows 11 debloat engine driven by `tweak-catalog.json`. The catalog was built from research into ReviOS, AtlasOS, Tiny11, Chris Titus winutil, Win11Debloat and privacy tools (O&O ShutUp10++, privacy.sexy, Sophia Script). See [RESEARCH.md](RESEARCH.md) for the findings and sources.

Only the **`safe`** preset (62 tweaks) is enabled. The catalog also holds `balanced`, `aggressive` and `never-default` tweaks, but the engine refuses to run them in this version.

## Quick start

```powershell
.\DebloatKit.ps1 -List      # what is already in effect (read-only)
.\DebloatKit.ps1 -WhatIf    # what would change; writes nothing, no admin needed
.\DebloatKit.ps1            # apply (elevated PowerShell)
.\DebloatKit.ps1 -Undo latest
```

Apply only some tweaks with `-Only id1,id2`, or leave some out with `-Skip id1,id2`. Tweak ids are shown by `-List`.

## How it stays reversible

1. **Restore point** before anything changes. The 24-hour limit is lifted for that one call, and the run aborts if no new point appears. Turn this off with `-NoRestorePoint`.
2. **Snapshot before every step** to `%ProgramData%\DebloatKit\state-<time>.json`. It records the registry value, or the fact that the value or key was absent, the service start type, the scheduled task state, the power plan, and so on. The file is saved before each change, so even a run that crashes partway can be undone.
3. **Verify after every step.** The new state is read back and the step is marked `Verified`, `Unverified` or `Failed`.
4. **`-Undo latest`** restores the snapshot in reverse order. It brings back the exact previous values, deletes values and keys the run created, and re-enables tasks it disabled. It does not reset to Windows defaults. The snapshot is then renamed `*.reverted.json`.
5. **Log** of every step as JSON lines in `run-<time>.log.jsonl` (and `undo-<time>.log.jsonl` for undo runs).

## Safety rules in the engine

- **Catalog command strings are never executed.** Only 3 command tweaks are implemented natively with a snapshot: power plan, NTFS last-access and execution policy. The others are skipped with a reason.
- **AppX removal is skipped** unless you pass `-AllowIrreversible`, because it has no exact undo (you have to reinstall from the Store).
- **Managed devices** (Entra ID joined, domain joined or MDM enrolled) show a warning, and applying needs `-Force`. Update and time-sync tweaks are always skipped on these devices.
- **Browser policies** (Chrome and Edge memory tweaks) are written to HKLM policy keys under `Software\Policies`. On managed devices they may conflict with Intune or Group Policy, which can overwrite them or lock the setting; the managed-device guard above applies to them as well.
- Applying needs an elevated PowerShell. `-List` and `-WhatIf` don't.
- Steps that are already at the desired value are left alone, so it is safe to run again.

## GUI

```powershell
.\DebloatKit-GUI.ps1            # opens the window (Windows PowerShell 5.1 or PowerShell 7)
.\DebloatKit-GUI.ps1 -SelfTest  # no window: loads XAML + data, tests filter/sort/select, prints counts and the top 10, exit 0 = pass
```

The GUI is a front end only. It never writes the registry or services; every change goes through `DebloatKit.ps1` in a separate process. If the thread is not STA it relaunches itself with `-STA`.

- **Data**: runs `DebloatKit.ps1 -List -AsJson -IncludeUnverified` in a child process (no admin needed, off the UI thread, "Loading..." overlay) and joins it with `tweak-catalog.json` for the explanations. All 144 catalog entries are shown.
- **Layout**: filters on the left (search, category, preset, risk, status, "Only proven (evidence strong/mixed)", group and sort), the tweak grid in the middle (checkbox, name/id, category, 0-5 stars, evidence badge, preset/risk badge, status, "unverified" badge), and a detail pane on the right. The default view is grouped and sorted **most effective first**. The panes are resizable.
- **Detail pane**: plain explanation, measured effect, who benefits, trade-off, what it can break, the exact changes (implementation steps), how it is reverted, and evidence links that open in your default browser.
- **Banner**: managed-device warning from the engine (Entra / domain / MDM, tenant) and whether the GUI is elevated.
- **Presets other than safe** are listed, but their checkboxes are disabled ("Preset not enabled in this version"). Unverified tweaks are never checked by default and carry a purple badge. Tweaks the engine would skip (status Skipped) cannot be ticked either.
- **Select recommended** ticks tweaks that are safe preset, effectiveness 2 or higher, evidence not "none", not unverified, and not already applied. **Clear** unticks everything.
- **Preview changes** runs the engine with `-WhatIf -AsJson -Only <ids>` and shows the plan in a table. It writes nothing.
- **Apply selected** always asks for confirmation first (lists the ids and the restore-point note), then starts an elevated engine process (UAC) with `-Only <ids>`. `-Force` is added only when the device is managed **and** you ticked "I understand this is a managed device"; `-IncludeUnverified` is added only when you selected an unverified tweak. The exit code and engine output are shown afterwards and the list refreshes.
- **Undo last run** asks for confirmation, then runs the elevated engine with `-Undo latest`. **Refresh** reloads the status. **Open log folder** opens `%ProgramData%\DebloatKit`.

The effectiveness score (0-5) comes from the catalog and is based on measured evidence only. A 0 means no measurable speed gain was found, not that the tweak is harmful or useless (many are privacy tweaks).

## Memory pressure monitor

`Get-MemoryPressure.ps1` is a separate, read-only tool. It tells you whether the system is really short of memory, so you can decide on the one fix that matters (a larger pagefile minimum) with numbers instead of guesses. It also gives before/after figures when you change browser settings.

```powershell
.\Get-MemoryPressure.ps1                                   # one report: commit, paging, verdict, top 10 processes, pagefile advice
.\Get-MemoryPressure.ps1 -AsJson                           # JSON only on stdout (warnings go to stderr)
.\Get-MemoryPressure.ps1 -Watch -IntervalSeconds 60        # one line per minute until Ctrl+C
.\Get-MemoryPressure.ps1 -Watch -Count 60 -LogPath $env:TEMP\mp.csv -Toast
.\Get-MemoryPressure.ps1 -SelfTest                         # no system access; tests the logic and scans its own source
```

**Watch commit %, not "RAM in use".** Windows uses free RAM as cache on purpose, so a full RAM bar is normal. Commit charge (what programs have promised to use, against RAM + pagefile) is the number that runs out. The report shows it in GB and as a percentage, next to Pages Output/sec, which says whether Windows is really writing memory to disk.

| Condition | Status |
|---|---|
| commit >= 90 % | Critical (the system-managed pagefile grows here; allocations fail at 100 %) |
| commit >= 80 % and Pages Output/sec >= 100 | Critical |
| commit >= 80 % and Pages Output/sec < 100 | Warning (high commit, little paging yet) |
| Available < 500 MB or < 1 % of RAM | Critical |
| Available < 10 % of RAM | Warning |
| Event 2004 (Resource-Exhaustion-Detector) in the last `-EventDays` days | at least Warning |
| Any pagefile more than 90 % used | Warning |

The thresholds and their Microsoft sources are in [docs/PERFORMANCE-RESEARCH.md](../docs/PERFORMANCE-RESEARCH.md). The pagefile advice suggests `ceil(peak commit x 1.25 - RAM)` GB as a minimum (capped at 3 x RAM) and says "no change needed" when the current pagefile is already that large. It is a manual change in System Properties > Advanced > Performance > Virtual memory; on a managed device ask IT first.

**The tool never purges memory and never changes the pagefile.** It does not empty working sets or the standby list, and it does not write the registry, services, scheduled tasks, power settings or the event log. The only file it can write is the CSV from `-LogPath`. There is no install option. If you want it to run periodically, you can create a scheduled task yourself, for example an action of `powershell.exe -NoProfile -File "C:\path\to\Get-MemoryPressure.ps1" -Watch -IntervalSeconds 300 -LogPath "C:\path\to\mp.csv"` started at logon.

Exit code: 0 on success (also for Warning or Critical status), 1 on a script error. `-Toast` uses the Windows toast API on Windows PowerShell; on PowerShell 7 it falls back to a console warning and a beep.

## Boot and startup baseline

`Get-BootReport.ps1` is a separate, read-only tool that gives you a before/after baseline for startup changes. Disabling startup apps is the only boot change with a measured gain (about 7 s on an SSD and 19 s on an HDD in published tests), and Task Manager's "Startup impact" column often reads "Not measured", so this report uses the objective boot timings Windows already records.

```powershell
.\Get-BootReport.ps1                  # boot history, degradations, startup items, logon tasks, Fast Startup, findings
.\Get-BootReport.ps1 -Boots 5 -Days 14
.\Get-BootReport.ps1 -AsJson          # JSON only on stdout
.\Get-BootReport.ps1 -SelfTest        # no system reads; tests the parsers and scans its own source
```

It shows the last `-Boots` boots from Event 100 (Diagnostics-Performance/Operational) with the median, the apps, drivers and services that slowed boot (events 101/102/103 in the last `-Days` days), every Run / RunOnce / Startup-folder item with its enabled state from `Explorer\StartupApproved`, enabled non-Microsoft logon tasks with their delay, and the Fast Startup setting. Microsoft's goal is fewer than 10 Run-key processes; the report says so when you go over.

Reading the Diagnostics-Performance log may require an elevated prompt or Event Log Readers membership. Without it the boot and degradation sections are skipped (reported as `needsElevation`) and the rest of the report still runs.

To measure a change: run the report, change **one** thing in Settings > Apps > Startup or Task Manager > Startup apps, restart (not Shut down, because Fast Startup makes a normal shutdown boot differently), and compare Event 100 before and after. The tool writes nothing and changes no setting, service, scheduled task or boot option.

## Tests

```powershell
.\tests\Test-Engine.ps1
```

This runs apply, re-apply and undo against a throwaway key (`HKCU:\Software\DebloatKitTest`) using `tests\test-catalog.json`, then deletes the key. It covers changing an existing value, creating values and nested keys, idempotency, exact undo, skipping command strings, and the preset gate. It passes on Windows PowerShell 5.1 and PowerShell 7.

## Caveats

- 23 catalog entries (16 of them in `safe`) are marked as not verified against the source projects (see the `verification` field). Test on a Windows 11 VM before applying them to a real machine.
- HKCU tweaks apply to the account running the elevated PowerShell. Run it from the account you want to change.
- Some changes, such as Explorer settings, policies and Fast Startup, take effect after you sign out or restart.
