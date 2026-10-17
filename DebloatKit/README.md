# DebloatKit

A reversible Windows 11 debloat engine driven by `tweak-catalog.json`. The catalog was built from research into ReviOS, AtlasOS, Tiny11, Chris Titus winutil, Win11Debloat and privacy tools (O&O ShutUp10++, privacy.sexy, Sophia Script). See [RESEARCH.md](RESEARCH.md) for the findings and sources.

Only the **`safe`** preset (52 tweaks) is enabled. The catalog also holds `balanced`, `aggressive` and `never-default` tweaks, but the engine refuses to run them in this version.

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
- Applying needs an elevated PowerShell. `-List` and `-WhatIf` don't.
- Steps that are already at the desired value are left alone, so it is safe to run again.

## GUI

```powershell
.\DebloatKit-GUI.ps1            # opens the window (Windows PowerShell 5.1 or PowerShell 7)
.\DebloatKit-GUI.ps1 -SelfTest  # no window: loads XAML + data, tests filter/sort/select, prints counts and the top 10, exit 0 = pass
```

The GUI is a front end only. It never writes the registry or services; every change goes through `DebloatKit.ps1` in a separate process. If the thread is not STA it relaunches itself with `-STA`.

- **Data**: runs `DebloatKit.ps1 -List -AsJson -IncludeUnverified` in a child process (no admin needed, off the UI thread, "Loading..." overlay) and joins it with `tweak-catalog.json` for the explanations. All 139 catalog entries are shown.
- **Layout**: filters on the left (search, category, preset, risk, status, "Only proven (evidence strong/mixed)", group and sort), the tweak grid in the middle (checkbox, name/id, category, 0-5 stars, evidence badge, preset/risk badge, status, "unverified" badge), and a detail pane on the right. The default view is grouped and sorted **most effective first**. The panes are resizable.
- **Detail pane**: plain explanation, measured effect, who benefits, trade-off, what it can break, the exact changes (implementation steps), how it is reverted, and evidence links that open in your default browser.
- **Banner**: managed-device warning from the engine (Entra / domain / MDM, tenant) and whether the GUI is elevated.
- **Presets other than safe** are listed, but their checkboxes are disabled ("Preset not enabled in this version"). Unverified tweaks are never checked by default and carry a purple badge. Tweaks the engine would skip (status Skipped) cannot be ticked either.
- **Select recommended** ticks tweaks that are safe preset, effectiveness 2 or higher, evidence not "none", not unverified, and not already applied. **Clear** unticks everything.
- **Preview changes** runs the engine with `-WhatIf -AsJson -Only <ids>` and shows the plan in a table. It writes nothing.
- **Apply selected** always asks for confirmation first (lists the ids and the restore-point note), then starts an elevated engine process (UAC) with `-Only <ids>`. `-Force` is added only when the device is managed **and** you ticked "I understand this is a managed device"; `-IncludeUnverified` is added only when you selected an unverified tweak. The exit code and engine output are shown afterwards and the list refreshes.
- **Undo last run** asks for confirmation, then runs the elevated engine with `-Undo latest`. **Refresh** reloads the status. **Open log folder** opens `%ProgramData%\DebloatKit`.

The effectiveness score (0-5) comes from the catalog and is based on measured evidence only. A 0 means no measurable speed gain was found, not that the tweak is harmful or useless (many are privacy tweaks).

## Tests

```powershell
.\tests\Test-Engine.ps1
```

This runs apply, re-apply and undo against a throwaway key (`HKCU:\Software\DebloatKitTest`) using `tests\test-catalog.json`, then deletes the key. It covers changing an existing value, creating values and nested keys, idempotency, exact undo, skipping command strings, and the preset gate. It passes on Windows PowerShell 5.1 and PowerShell 7.

## Caveats

- 13 catalog entries (4 of them in `safe`) are marked as not verified against the source projects (see the `verification` field). Test on a Windows 11 VM before applying them to a real machine.
- HKCU tweaks apply to the account running the elevated PowerShell. Run it from the account you want to change.
- Some changes, such as Explorer settings, policies and Fast Startup, take effect after you sign out or restart.
