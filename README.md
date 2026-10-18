# Windows Optimizer Script

> Use at your own risk. Test on a VM or a spare machine first.

This repository holds **DebloatKit**, a reversible Windows 11 tuning kit, plus a few legacy launchers from the first version of the project. The old behaviour (disable Windows Update, loop every 10 seconds, kill apps, purge standby memory) has been retired. See [Legacy scripts](#legacy-scripts-retired).

## Quick start

1. [Download the ZIP](https://github.com/PriyomSaha/windows-optimizer-script/archive/refs/heads/main.zip) and extract it.
2. Right-click `setup.ps1` and choose **Run with PowerShell**. It unblocks the downloaded files and opens the GUI. It does not change your execution policy and does not apply anything.
3. In the GUI pick a profile or tick tweaks, press **Preview changes**, then **Apply selected**. Windows asks for administrator rights (UAC) only at that moment.

Or from a PowerShell prompt, in the `DebloatKit` folder:

```powershell
.\DebloatKit.ps1 -List        # what is already in effect (read-only)
.\DebloatKit.ps1 -WhatIf      # what would change; writes nothing, no admin needed
.\DebloatKit.ps1              # apply (elevated PowerShell)
.\DebloatKit.ps1 -Undo latest # put everything back
```

`run_invisible.vbs` starts the same GUI without a console window.

## What DebloatKit is

A JSON-driven engine (`DebloatKit\tweak-catalog.json`) with a WPF front end:

- **Catalog**: every tweak has a plain explanation, an effectiveness rating, an evidence level, its trade-off, what it can break and how it is reverted. Tweaks are grouped in presets (`safe`, `balanced`, `aggressive`, `never-default`). Only `safe` can be applied in this version.
- **Engine** (`DebloatKit.ps1`): preflight gates, restore point, a snapshot before every step, verification after every step, exact undo, per-tweak revert and drift detection (what did a Windows update change back).
- **GUI** (`DebloatKit-GUI.ps1`): filter and sort the catalog, preview, apply, undo, per-row Apply/Revert, profiles (work PC, personal desktop or laptop, gaming desktop), a drift tab and a footprint tab. It never writes settings itself; every change goes through the engine in a separate elevated process.
- **Monitors** (read-only, they change nothing):
  - `Get-MemoryPressure.ps1`: tells you whether the machine is really short of memory (commit charge, paging, pagefile advice). Use it instead of a RAM "cleaner".
  - `Get-BootReport.ps1`: boot history from the Windows event log, what slowed boot, startup items. A before/after baseline for startup changes.
  - `Get-FootprintReport.ps1`: processes, services, AppX packages, disk and memory numbers. Save one before and one after a run and compare them with `-Compare`, so a claim is a measured number.
- **Image builder** (`DebloatKit-Image.ps1`): builds a slimmed install ISO from an official Microsoft ISO you supply (SHA-256 verified, exact-name AppX removal, the safe registry tweaks applied offline, optional Compact OS). It keeps Windows Update, Defender, WinRE and servicing, never downloads anything and prints the full command plan with `-WhatIf`. For personal machines, not for a managed work PC.

All details, parameters and the test suite are in [DebloatKit/README.md](DebloatKit/README.md).

## Safety model

- **Safe by default.** The `safe` preset holds only tweaks that do not reduce security, do not break servicing and can be reversed exactly. Disabling Defender, Windows Update, virtualization-based security or recovery is never part of it; those entries sit in `never-default` and the engine refuses them.
- **Preflight.** Applying is refused with a reason when a reboot or servicing is pending, the device is on battery or the disk is nearly full.
- **Restore point and snapshots.** A restore point is created first, and every step is snapshotted before it changes, so even a crashed run can be undone.
- **No arbitrary commands.** Catalog command strings are never executed. A small allowlist of native handlers (power plan, hibernation type, Compact OS and similar) has a snapshot and an exact undo each.
- **Irreversible steps need an explicit switch.** AppX removal and component-store cleanup are skipped unless `-AllowIrreversible` is passed, and the GUI never passes it.
- **Managed devices.** On Entra ID joined, domain joined or MDM enrolled PCs the engine warns, needs `-Force`, and skips every tweak that would fight Intune or Group Policy (updates, time sync, telemetry services, Delivery Optimization and so on).
- **Protected targets.** Security and servicing components are on a denylist that no catalog step can touch.

## Research

- [DebloatKit/RESEARCH.md](DebloatKit/RESEARCH.md): the research behind the catalog (ReviOS, AtlasOS, Tiny11, winutil, Win11Debloat, O&O ShutUp10++, privacy.sexy, Sophia Script), what was kept, what was rejected and why.
- [docs/PERFORMANCE-RESEARCH.md](docs/PERFORMANCE-RESEARCH.md): which performance tweaks have measured evidence and which are placebo. Includes why purging standby memory and trimming working sets are counterproductive.

## Legacy scripts (retired)

| File | Now |
|------|-----|
| `clear_ram_loop.bat` | Prints why it was retired and opens the DebloatKit GUI. It no longer disables anything, loops, kills processes or runs RAMMap. |
| `run_invisible.vbs` | Opens the DebloatKit GUI without a console window. It no longer runs the bat elevated. |
| `setup.ps1` | Unblocks the files and opens the GUI. It no longer changes the execution policy. |
| `revert.bat` | Kept on purpose, for anyone who ran the old script. Run it as Administrator to put `wuauserv` (manual), `UsoSvc` (automatic, delayed) and `BITS` (manual) back to the Windows defaults, start them, remove the `NoAutoUpdate` and `AUOptions` policy values and re-enable the three Windows Update scheduled tasks. `revert.bat /noop` prints the commands without running them. |

Why the old behaviour went: disabling Windows Update, UsoSvc and BITS stops security patches and breaks Intune, Defender signature updates and Delivery Optimization (BITS is used by all three); the working-set trim and the 10 second standby purge only throw away useful cache, so the machine pages in the same data again. Killing OneDrive, Teams and vendor helpers every 10 seconds is what startup settings are for (see `Get-BootReport.ps1`).

### RAMMap binaries

`RAMMap64.exe` in the root and the `RAMMap\` folder are copies of the Microsoft Sysinternals tool that the old loop used. Nothing in this repository calls them any more, and the bat pointed at a hard-coded path on another drive anyway. They are left in place for now and are not covered by the repository license (see the Sysinternals EULA in `RAMMap\Eula.txt`). If you want RAMMap, download it from Microsoft; removing the copies from the repository is a separate decision.

## Disclaimer

Use it on systems you own or are allowed to change. On a work device check with your IT admin first; the managed-device guard reduces conflicts but does not replace that conversation.

## License

[MIT License](LICENSE)
