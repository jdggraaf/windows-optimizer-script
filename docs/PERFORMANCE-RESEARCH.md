# Windows 11 performance and RAM: research review

Date: 2026-10-17. Input: six raw research sets (browsers/apps, memory pressure, CPU/power, startup/boot, storage/IO, Windows 2026 news) gathered by fast agents, about 190 source entries. This document judges that material, separates measured effects from placebo, and maps the result onto `DebloatKit` (139 catalog entries, `safe` preset only).

Confidence labels: **High** = Microsoft/Google primary documentation or a reproducible benchmark; **Medium** = vendor telemetry or several independent single-machine tests that agree; **Low** = one anecdote, vendor marketing ("up to"), or an AI-written forum answer.

## TL;DR

- **On a 32 GB PC the bottleneck is commit, not physical RAM.** Commit limit = RAM + pagefile. With a 2.7 GB system-managed pagefile the limit is about 34.7 GB, and 85-87 % commit puts the machine right below the 90 % point where Windows starts growing the pagefile (and where freezes and Event 2004 begin). Free "RAM" in Task Manager is the wrong number to watch. (High, Microsoft Learn.)
- **The only levers that measurably cut memory on this profile are in the browsers and Electron/WebView2 apps**, not in Windows registry tweaks. Edge sleeping tabs: Microsoft telemetry 39.1 MB saved per slept tab on average (Medium). Chrome Memory Saver: one independent test 7.5 % lower after 40 min, 83 % lower after a long idle (Low, n=1); Google "up to 40 %" (vendor).
- **Raising the commit limit is the real fix for 85-87 % commit**: a larger pagefile minimum, not a smaller pagefile and not standby purging. This is a manual action, it is in the advice section below, and it is *not* automated by this repo.
- **Boot:** disabling startup apps saved 7 s (SSD) to 19 s (HDD) in the only measured test found (Medium). Fast Startup off costs about 2 s on SSD (Low, single author). msconfig "Number of processors" is a myth (High, Microsoft moderators).
- **Storage:** Dev Drive gives 14-28 % faster builds in Microsoft's own tests (Medium), but most of that comes from Defender asynchronous scanning. It needs a new volume and is a security trade-off on a managed device. NTFS last-access and 8.3 are already cataloged; their effect is too small to measure.
- **CPU/power:** EcoQoS and power throttling are app opt-in or Windows-managed. Core-parking and boost-mode tweaks are anecdotal, cost power, and the engine cannot snapshot them. Rejected.
- **Repo actions:** (1) a read-only commit/memory-pressure monitor, (2) documented Chrome and Edge memory policies as new catalog entries, (3) a catalog recalibration (SysMain and Storage Sense out of `safe`, new measured figures), (4) a read-only boot and startup baseline report. Nothing here changes pagefile, services or power settings on the owner's machine.

## How to read memory pressure correctly

| Signal | What it means | Threshold (source) |
|---|---|---|
| `% Committed Bytes In Use` (commit / commit limit) | Demand for RAM + pagefile backing. At 100 % allocations fail and apps crash or freeze. | Healthy 0-50 %, warning 60-80 %, critical 80-100 % (Microsoft performance scenario guide, Server). Exchange guidance: >80 % = stressed. System-managed pagefile grows at **90 %**. |
| `Available MBytes` | RAM that is free or standby (re-usable). | Warning <10 % of RAM; critical <1 % or <500 MB (Microsoft). Not a reliable stand-alone indicator. |
| `Pages Output/sec` (hard writes to pagefile) | Real paging pressure. | "If low or zero most of the time, no significant RAM problem even if Committed Bytes exceeds RAM" (Microsoft). |
| `Pages/sec` | Includes mapped-file reads. | Microsoft: often misread, a high value is not by itself a RAM shortage. |
| `Paging File % Usage` + `Modified Page List Bytes` | Whether the pagefile is too small. | Enlarge the pagefile only when Available is low **and** the Modified list is large **and** Paging File %Usage >90 (Microsoft pagefile sizing article). |
| Event 2004, `Microsoft-Windows-Resource-Exhaustion-Detector` | Commit reached a critical level; lists the top 3 commit consumers. | Treat as a real warning (VM freezes follow it in the 2024 Q&A thread). The listed processes are often victims, not the cause. The Server 2008 R2 page calls it "normal", which is dated. |
| Per-process **Private Bytes** (not Working Set) | What a process really commits. Task Manager's default column is the working set. | A steady rise over hours = leak (Microsoft PerfMon leak guide: sample every 600 s for 24 h). |

Measurement note: `Get-Counter` paths are **localized** (they differ on a Dutch Windows install). Scripts must use the CIM classes `Win32_PerfFormattedData_PerfOS_Memory` and `Win32_OperatingSystem`, whose property names are always English.

## Per area: what measurably helps vs placebo

### 1. Browsers and apps (largest lever for this owner)

| Change | Effect | Confidence | Verdict |
|---|---|---|---|
| Edge sleeping tabs (`SleepingTabsEnabled`, `SleepingTabsTimeout`) | Microsoft telemetry: 6 billion slept tabs saved 273.7 PB in 28 days, about **39.1 MB per tab**. Edge 100 claim: 85 % memory per slept tab. The default timeout is **900 s** (verified on the live Learn page; one indexed copy said 7200 s). | Medium (vendor telemetry, large n) | **Implement.** It is on by default, so the gain comes from enforcing it and shortening the timeout. Use the *Recommended* registry path so the user can still override it. |
| Edge `TotalMemoryLimitMb` | Discards tabs above the limit (minimum 1024 MB). Microsoft gives no figure and "no guarantee browser stays under limit". | High that it exists; effect unmeasured | Catalog as `balanced` (tabs reload aggressively). |
| Edge `EfficiencyModeEnabled` / `EfficiencyMode` | Mainly CPU and battery. Microsoft warns of "visible slowdowns". Disabled by default on devices without a battery. | High (docs); no RAM figure | Catalog as `balanced` at most. Low priority. |
| Edge `StartupBoostEnabled=0`, `BackgroundModeEnabled=0` | Fewer resident processes when Edge is closed. | High that it exists; no figure | **Already in** `edge-debloat-policies`. |
| Chrome Memory Saver (`HighEfficiencyModeEnabled`, bool, Chrome 108+; `MemorySaverModeSavings` 0/1/2, Chrome 126+) | Benchmark.pl: 1414 MB at start, -7.5 % after 40 min, -83 % after a long idle (n=1). Google: "up to 40 %" (vendor). One tester says it only reacts above about 20 tabs. Not discarded: audio/video, screen share, forms, pinned tabs, downloads. | Low-Medium | **Implement.** Enable it as `safe`. The **Maximum** savings level is a separate `balanced` entry (more reloads). Policy names verified in the Chromium source YAML. |
| Chrome `BackgroundModeEnabled=0` (HKLM\SOFTWARE\Policies\Google\Chrome) | Stops Chrome from staying resident after the last window closes. Unset = off at first, but the user and some extensions can turn it on. | High (Chrome Enterprise page + Chromium YAML) | **Implement** as `safe` (it mirrors the Edge entry that is already there). |
| Discord/Slack/Teams/VS Code (Electron/WebView2) | Every app carries its own Chromium. New WhatsApp: 213 MB → 1.4 GB (reported). New Teams: "up to 50 % less" (vendor). VS Code: fewer extensions is the only real cut. A VS Code developer says telemetry off and `search.exclude` do nothing for memory. | Low-Medium | Advice only. Close or quit unused Electron apps. Not a registry tweak. |
| `LetAppsRunInBackground=2` | UWP background apps. Measured 100-200 MB total in debloat tests. | Low | **Already in** `perf-background-apps-off` (balanced, it breaks notifications). |
| Copilot app | About 500 MB in the background, about 1 GB active (press measurement). | Low-Medium | `ai-copilot-app-remove` already exists. The `RemoveMicrosoftCopilotApp` policy does **not** apply to Pro/Business. |

### 2. Memory management

| Claim | Evidence | Verdict |
|---|---|---|
| Purge standby / working sets on a timer | Prior research: harmful (it throws away cache, which is then re-read from disk). RAMMap's Empty Standby is a diagnostic. | **Placebo or harmful.** Not implemented. |
| Disable memory compression | Q&A: about 1 GB held by compression on a 16 GB machine. Disabling it **increases pagefile use** (thread caveat; Microsoft answer: leave it on). | Placebo-to-harmful under commit pressure. Keep `perf-memory-compression-off` at balanced/e0. |
| Disable SysMain/Prefetch | One Tech Community anecdote (60-70 % → 33 % "RAM use", which is standby and therefore free). Engadget and HelpDeskGeek: worth trying only on HDD or under 4 GB of RAM. | Placebo on SSD. Move `svc-sysmain-disable` out of `safe`. |
| Pagefile 1.5-2x RAM capped at 8-16 GB (how7o) | Unsourced. Microsoft: size from **peak commit** and the crash-dump setting. | Use Microsoft's method (see owner advice). |
| Disable or remove the pagefile | Commit limit then falls below installed RAM. | Rejected (it was already settled earlier). |
| Registry "RAM tweaks" (LargeSystemCache, DisablePagingExecutive, ...) | No measured benefit. | Myth (prior research). |

### 3. CPU and power

| Change | Evidence | Verdict |
|---|---|---|
| EcoQoS / power throttling | Applications opt in via `SetProcessInformation`. Microsoft claims "up to 11 % CPU power" and "14-76 % responsiveness" (vendor). Edge and Chrome already use it. | Nothing to tweak. Windows and apps handle it. |
| `PowerThrottlingOff` policy, `DisableUserPresenceQos` | Documented. Microsoft recommends `DisableUserPresenceQos` only for **benchmarking on battery**. It raises power use and does nothing for RAM. | Rejected for the catalog. |
| Core parking `CPMINCORES=100`, `PERFBOOSTMODE` | One forum anecdote. The setting is hidden, needs powercfg, sources disagree on the default, and it costs power on laptops. | Rejected. The engine has no snapshot-able native handler, and adding one is not justified by the evidence. |
| Ultimate/High performance plan | Already cataloged (`pwr-ultra-performance-plan`, balanced). | No change. |
| msconfig "Number of processors" / `numproc` | Microsoft moderators: "No." It can cause boot problems. | **Myth.** |

### 4. Startup and boot

| Change | Evidence | Verdict |
|---|---|---|
| Disable unneeded startup apps | How-To Geek: SSD 27 → 20 s (all disabled) / 23 s (selective); HDD 70 → 51 / 59 s. Microsoft WEG goal: fewer than 10 Run-key processes. One Q&A user saw under 1 s difference. | **Real, 7-19 s.** It works best on machines with many startup items. Advice plus a read-only audit; there is no generic catalog tweak. |
| Delay non-critical apps (Task Scheduler logon delay, `delayed-auto` services) | Microsoft WEG recommends it. No measured figure. | Advice only. The owner's PC must not get scheduled tasks or service changes from this work. |
| Fast Startup off | MakeUseOf: 11 → 13 s on SSD. Another single test: 4 → 9-10 s on NVMe (already in the catalog). It can fix BitLocker, WSL2 and update glitches. | Correctly scored e0. Update the measured figure. |
| `DelayedDesktopSwitchTimeout=1` | It only moves the delay to the taskbar (Super User). | Placebo. Rejected. |
| Measure first | Event 100 in `Microsoft-Windows-Diagnostics-Performance/Operational` (BootTime, MainPathBootTime, BootPostBootTime in ms); events 101/102 name slow apps and drivers. WPR `-boottrace` for depth. | **Implement** a read-only report. |

### 5. Storage and IO

| Change | Evidence | Verdict |
|---|---|---|
| Dev Drive (ReFS + Defender performance mode) | Microsoft: 14 % faster builds, 28 % with CopyOnWrite. VS team: about 25 % average. Third-party tests: 22-project rebuild 32.4 → 19.8 s; npm install 58 → 21 s (anecdote). One test showed NTFS with RTP off is close to Dev Drive, so **the gain is mostly asynchronous AV**. | Real for node/build workloads, but it needs a format (it cannot convert C:) and Defender trust, and on an Intune device Defender settings belong to IT. Advice only. |
| TRIM / Retrim | On by default (`DisableDeleteNotify=0`). The weekly retrim does no harm. | Nothing to do. |
| NTFS last access off, 8.3 off | Microsoft: last access "improves speed" with no figure. 8.3: theoretical, and it carries a compatibility risk. | Already cataloged. Effect not measurable. |
| Write-cache buffer flushing off | Risk of data loss on power failure. | Rejected. |
| Windows Search index | Microsoft: more than 400 k items causes problems. Normal memory use is a few hundred MB. 12 GB means a corrupt index, so rebuild it. | Advice: rebuild first. `svc-wsearch-manual` stays balanced. |
| Storage Sense off | It runs only when disk space is low (default cadence 0). Turning it off brings no performance gain. | Move `perf-storage-sense-off` out of `safe` (it is counter-productive and has e0). |

### 6. Windows in 2026

- Microsoft has committed to lowering the idle memory footprint and to "memory optimization for 8GB and above" through the end of 2026. No numbers have been published. Secondary press only.
- 25H2 vs 24H2: no performance difference across 41 workloads (Phoronix). Feature updates are not a performance lever.
- No memory-related known issue is listed in official release health for 24H2, 25H2 or 26H1. Forum reports (SearchIndexer/MsMpEng after KB5063060, 24H2 DWM spikes) are anecdotes.
- `TurnOffWindowsCopilot` is "subject to near-term deprecation". AppLocker is Microsoft's replacement. `ai-copilot-disable` should mention this in its tradeoff text.

## Advice for the owner's PC (32 GB, Win11 Business, Entra-joined, commit 85-87 %)

1. **Measure before changing anything.** Run the monitor (work item 1) for a working day. If `Pages Output/sec` stays near 0 and there is no Event 2004, then 85 % commit is uncomfortable but harmless. If commit goes past 90 % with Event 2004 or hard-fault bursts, the commit limit is too low.
2. **Raise the commit limit, do not shrink usage by force.** With commit around 30 GB and a peak above it, a 2.7 GB pagefile leaves about 4 GB of headroom. Microsoft's method is to size from peak commit. A custom pagefile with a minimum of about 8-16 GB (maximum: system managed or 32 GB) gives a commit limit of 40-48 GB and costs only disk space. **This is the single biggest fix, and it is a manual System Properties change** (on a managed device, check with IT first). This repo deliberately does not automate it.
3. **Browsers first:** 131 Chrome processes at 4.2 GB and Edge at 3 GB are about 7 GB. Turn on Chrome Memory Saver (Balanced, or Maximum if reloads are acceptable), set Edge sleeping tabs to 5-15 min, and turn off background mode in both. Expect 0.5-2 GB back after an hour of idle tabs (extrapolated from 39 MB/tab and the Benchmark.pl curve; low confidence).
4. **Check extensions** in Chrome and Edge (Shift+Esc task manager). Microsoft's first troubleshooting step is a single heavy extension.
5. **node (1.9 GB) and Claude (3.6 GB):** these are working sets of tools in active use. Close idle node dev servers and watch Private Bytes over hours for leaks (Microsoft PerfMon method). For heavy node builds, a Dev Drive for repositories and package caches is the measured storage win, but agree on Defender trust with IT first.
6. **Do not:** purge standby, disable the pagefile or memory compression, disable SysMain on an SSD, or run "RAM cleaner" loops.

## Rejected recommendations

| Recommendation | Why rejected |
|---|---|
| Timer-based standby or working-set purge | It throws away cache and causes re-reads. Prior research showed harm. |
| Disable or shrink the pagefile | It lowers the commit limit, which is exactly what is too low on the owner's PC. |
| Disable memory compression | It increases paging under pressure (Microsoft Q&A). There is no measured benefit. |
| Disable SysMain/Prefetch (as `safe`) | The single anecdote measures standby as "used". It slows launches on HDD. Moved to `balanced`. |
| msconfig Number of processors / `bcdedit numproc` | Myth, with a risk of boot problems. |
| Core parking off, hidden boost modes, `PowerThrottlingOff`, `DisableUserPresenceQos` | Anecdotal or benchmarking-only, costs power, does nothing for RAM. powercfg settings would need new native handlers. |
| Dev Drive automation | It needs a format. The gain is mostly Defender asynchronous scanning, which is a security setting owned by Intune. Advice only. |
| Broad Defender folder or process exclusions | Microsoft: exclusions "block scans altogether". Performance mode is the better option. Reduces security. |
| Write-cache buffer flushing off | Data-loss risk. |
| `DelayedDesktopSwitchTimeout` | It moves the delay instead of removing it. |
| `RemoveMicrosoftCopilotApp` policy | Not supported on Pro/Business. |
| Edge `EfficiencyMode` AlwaysActive in `safe` | Microsoft warns of visible slowdowns. It is a CPU lever, not RAM. Balanced at most. |
| Edge `SleepingTabsBlockedForUrls` | A list policy (subkey with numbered values). It is a per-site exception list, not a tweak. |
| Disable Storage Sense (as `safe`) | It runs only on low disk space by default, so there is no performance gain. Moved to `balanced`. |
| Toast via BurntToast | An external module dependency. Native WinRT is enough. |
| Third-party tray RAM monitors | None combines open source, tray and a commit-charge alert. Several "free RAM" by purging. |
| Pagefile "1.5-2x RAM" rules | Unsourced. Microsoft sizes from peak commit and the dump setting. |

## Implementation plan (summary)

1. `DebloatKit\Get-MemoryPressure.ps1`: read-only commit and paging monitor with optional toast alerting, `-AsJson` and `-SelfTest`. No scheduled task, no purge.
2. Catalog: browser memory policies (Chrome Memory Saver, Chrome savings Maximum, Chrome background mode off, Edge sleeping tabs Recommended + 300 s timeout, Edge TotalMemoryLimitMb). All `new-unverified`. Edge efficiency mode is left out: it is a CPU lever with a documented slowdown, and no RAM figure was found.
   Note: Edge sleeping-tabs policies do not apply to profiles signed in with a personal Microsoft account (Learn: "Applies to a profile that is signed in with a Microsoft account: No"). Work and school (Entra) profiles are covered.
3. Catalog recalibration: SysMain and Storage Sense move to `balanced`; measured figures added to Fast Startup, WSearch, memory compression and Copilot; README counts updated.
4. `DebloatKit\Get-BootReport.ps1`: read-only Event 100/101/102 boot history plus a startup inventory (Run keys, Startup folders, StartupApproved state, logon tasks), with `-AsJson` and `-SelfTest`.

## Sources (deduplicated)

Microsoft primary
- https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/how-to-determine-the-appropriate-page-file-size-for-64-bit-versions-of-windows
- https://learn.microsoft.com/troubleshoot/windows-client/performance/introduction-to-the-page-file
- https://learn.microsoft.com/troubleshoot/windows-server/performance/troubleshoot-performance-problems-in-windows
- https://learn.microsoft.com/troubleshoot/windows-server/performance/ram-virtual-memory-pagefile-management
- https://learn.microsoft.com/windows/win32/memory/memory-performance-information
- https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-creatememoryresourcenotification
- https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/using-performance-monitor-to-find-a-user-mode-memory-leak
- https://learn.microsoft.com/exchange/exchange-2013-performance-counters-exchange-2013-help#memory-counters
- https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2008-r2-and-2008/cc774731(v=ws.10)
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/sleepingtabsenabled
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/sleepingtabstimeout
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/sleepingtabsblockedforurls
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/totalmemorylimitmb
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/ramresourcecontrolsenabled
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/efficiencymodeenabled
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/efficiencymode
- https://learn.microsoft.com/deployedge/microsoft-edge-policies/efficiencymodeonpowerenabled
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/startupboostenabled
- https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/backgroundmodeenabled
- https://learn.microsoft.com/en-us/troubleshoot/microsoft-edge/performance/edge-high-cpu-memory
- https://learn.microsoft.com/en-us/intune/solutions/edge-data-security/settings-catalog-step-5
- https://learn.microsoft.com/deployedge/microsoft-edge-relnote-archive-stable-channel
- https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy
- https://support.microsoft.com/topic/4f32dffe-b97c-40e8-a790-3ca10373a1ef
- https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service
- https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-power
- https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/customize-power-slider
- https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-core-parking-cpmincores
- https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/power-performance-tuning
- https://learn.microsoft.com/en-us/windows-hardware/test/weg/delivering-a-great-startup-and-shutdown-experience
- https://learn.microsoft.com/en-us/windows-hardware/test/assessments/post-on-off-duration
- https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options
- https://learn.microsoft.com/en-us/windows/compatibility/startup-apps
- https://learn.microsoft.com/en-us/windows/win32/api/winsvc/ns-winsvc-service_delayed_auto_start_info
- https://learn.microsoft.com/en-us/windows/win32/taskschd/logontrigger-delay
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-wininit
- https://learn.microsoft.com/en-us/windows/dev-drive
- https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-antivirus-performance-mode
- https://learn.microsoft.com/en-us/powershell/module/storage/optimize-volume
- https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-behavior
- https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/windows-search-performance-issues
- https://learn.microsoft.com/troubleshoot/outlook/performance/performance-issues-if-uselowpriorityconfiguration-is-0
- https://learn.microsoft.com/en-us/windows/configuration/storage/storage-sense
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-storage
- https://learn.microsoft.com/windows/client-management/mdm/policy-csp-windowsai#removemicrosoftcopilotapp
- https://learn.microsoft.com/windows/client-management/manage-windows-copilot
- https://learn.microsoft.com/windows/client-management/copilot-update-policy-control#uninstall-copilot
- https://learn.microsoft.com/windows/release-health/status-windows-11-25h2
- https://learn.microsoft.com/en-us/sysinternals/downloads/rammap
- https://devblogs.microsoft.com/engineering-at-microsoft/dev-drive-and-copy-on-write-for-developer-performance
- https://devblogs.microsoft.com/visualstudio/devdrive/
- https://github.com/microsoft/CopyOnWrite/blob/main/BenchmarkData/BenchmarkData.md

Google / Chromium primary
- https://chromeenterprise.google/policies/high-efficiency-mode-enabled/
- https://chromeenterprise.google/policies/memory-saver-mode-savings
- https://chromeenterprise.google/policies/background-mode-enabled/
- https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/HighEfficiencyModeEnabled.yaml
- https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/MemorySaverModeSavings.yaml
- https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/BackgroundModeEnabled.yaml
- https://support.google.com/chrome/answer/12929150

Microsoft Q&A / community (anecdotal; used only as flagged)
- https://learn.microsoft.com/en-us/answers/questions/2185908/windows-successfully-diagnosed-a-low-virtual-memor
- https://learn.microsoft.com/en-us/answers/questions/5513382/mem-compression-turns-to-a-power-hog
- https://learn.microsoft.com/en-us/answers/questions/4338197/windows-11-standby-list-and-memory-compression
- https://learn.microsoft.com/answers/a/12253077
- https://learn.microsoft.com/en-us/answers/questions/5683569/what-does-number-of-processors-mean-in-advanced-op
- https://learn.microsoft.com/en-us/answers/questions/2594567/if-i-enable-2-processors-in-msconfig-will-it-incre
- https://learn.microsoft.com/en-us/answers/questions/3864717/pc-taking-much-longer-to-boot-than-normal
- https://learn.microsoft.com/en-us/answers/questions/2803730/boot-duration
- https://learn.microsoft.com/en-us/answers/questions/1184305/how-to-turn-off-efficiency-mode-for-edge
- https://techcommunity.microsoft.com/discussions/windowsinsiderprogram/system-windows-ram-problem-fix/4506405
- https://superuser.com/questions/1877066/why-am-i-experiencing-slow-login-with-windows-11
- https://superuser.com/questions/1374293/does-stripping-8dot3name-entries-on-ntfs-os-partition-on-windows-10-on-an-m-2-ss

Press and independent tests
- https://www.benchmark.pl/google-chrome-memory-saver-sprawdzam-jak-dziala-7268406578017345a
- https://www.ghacks.net/?p=179016
- https://www.ghacks.net/?p=190177
- https://windowslatest.com/2025/12/07/ram-prices-soar-but-popular-windows-11-apps-are-using-more-ram-due-to-electron-web-components
- https://windowslatest.com/2026/04/05/new-copilot-for-windows-11-includes-a-full-microsoft-edge-package-uses-more-ram
- https://www.windowslatest.com/2026/10/04/rising-cost-of-memory-microsoft-explains-why-windows-11-will-use-less-ram/
- https://windowslatest.com/2026/08/01/microsoft-confirms-windows-11-is-a-memory-hog-promises-8gb-ram-pc-optimization-by-end-of-2026/
- https://www.howtogeek.com/disabling-startup-apps-improve-boot-time
- https://www.makeuseof.com/turned-off-windows-fast-startup-boot-time-barely-changed-bugs-disappeared/
- https://www.engadget.com/2273348/why-windows-11-using-so-much-ram/
- https://www.guru3d.com/story/windows-11-25h2-benchmarks-show-no-performance-gains-over-24h2
- https://koskila.net/dev-drive-performance-increase-in-real-life-scenarios
- https://www.bleepingcomputer.com/news/microsoft/microsoft-defender-antivirus-gets-performance-mode-for-dev-drives
- https://www.howtogeek.com/stop-using-this-windows-setting-it-can-destroy-your-files
- https://helgeklein.com/blog/why-disabling-the-creation-of-83-dos-file-names-will-not-improve-performance-or-will-it
- https://dev.to/claudiodavi/reducing-vscode-memory-consumption-527k
- https://eventlogxp.com/blog/windows-boot-performance-diagnostics-1
- https://www.techtarget.com/it-infrastructure/tip/Using-RamMap-and-VMMap-Tools-to-Troubleshoot-Windows-Memory-Issues

Discarded as unreliable (vendor or affiliate, AI-generated, or contradicted): superchargebrowser.com review, help.swif.ai (Chrome BackgroundMode default), how7o.com pagefile rules, visioncomputers.com boot claims, Samsung Internet policy pages (superseded by Chromium YAML), the AI-generated Q&A answer 12748515, neatnettricks.com estimates.
