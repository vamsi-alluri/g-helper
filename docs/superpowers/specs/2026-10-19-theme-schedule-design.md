# Automatic light/dark theme switching in G-Helper

**Status:** design, approved for planning
**Date:** 2026-10-19
**Repo:** `vamsi-alluri/g-helper` (fork of `seerge/g-helper`)
**Related:** `docs/superpowers/specs/2026-10-15-fork-release-pipeline-design.md` — the release pipeline that this feature depends on, now merged. That spec listed this feature as explicitly out of scope.

---

## Intent

Windows has no easy way to switch the system theme. There is no toggle in the
Action Center, no built-in schedule, and no keyboard shortcut — changing it
means opening Settings and clicking through to Personalization → Colors. That
is the actual grievance this feature answers.

The owner currently solves it outside G-Helper with two PowerShell scripts and
a Task Scheduler job:

- `theme_manager.ps1` — writes `SystemUsesLightTheme` and `AppsUseLightTheme`,
  then broadcasts `WM_SETTINGCHANGE`/`ImmersiveColorSet` so the shell and
  running apps repaint without a logout. Runs at logon and at two scheduled
  instants.
- `auto_light_dark_theme.ps1` — calls `api.sunrise-sunset.org` for sunrise and
  sunset at a hardcoded latitude/longitude, applies `+1h` / `-1h` offsets, and
  rewrites the scheduled task's triggers. Runs about once a week.

This moves that into G-Helper, which is already an always-running elevated tray
app on this machine, and adds the thing the scripts cannot give: an instant
manual toggle on a physical key.

**Two capabilities, in priority order:**

1. **A manual toggle** — one keypress, no window, no menu. This is the primary
   feature.
2. **A schedule** — flips the theme automatically at the right times of day, so
   the toggle is rarely needed.

### Why the offsets, and why not offsets

The owner's `+1h` / `-1h` offsets exist because sunrise and sunset are the wrong
events: at the moment of sunrise the sun is at the horizon and almost no light
reaches into a windowed room. The offsets approximate "the sun is high enough to
light the room."

That approximation is **sun elevation angle**, so the feature triggers on
elevation directly. Computed against the owner's coordinates (30.5052, -97.8203)
with the NOAA solar-position formula, the existing `+1h` rule corresponds to:

| Date | Sunrise | Owner's rule (+1h) | Elevation at that moment |
|---|---|---|---|
| 2026-06-21 | 06:30 | 07:30 | 10.9° |
| 2026-10-19 | 07:36 | 08:36 | 11.6° |
| 2026-12-21 | 07:24 | 08:24 | 10.2° |

A **10° threshold** reproduces the current behaviour to within 1–8 minutes all
year.

Be honest about what this buys: at this latitude the fixed-hour rule only drifts
about 15 minutes across the year, so elevation is not fixing a problem the owner
has today. It is adopted because it expresses the real intent, needs no
per-season tuning, and stays correct if the machine moves to a different
latitude, where a fixed hour would not.

---

## Goals

- Toggle the Windows theme from a bindable physical key (the owner will use M4).
- Show the current theme at a glance inside the G-Helper window.
- Switch automatically at sun-elevation crossings, computed locally.
- Survive sleep, hibernate, clock changes and DST without catch-up logic.
- A manual toggle is respected and not silently reverted.
- Enter and set up through a UI, not by hand-editing `config.json`.
- Be shaped so it can be offered upstream as a PR.

## Non-goals

- Measuring actual room brightness. Camera, IR camera, phone-as-sensor and
  Wi-Fi-derived location were all considered and shelved; see
  [Rejected approaches](#rejected-approaches).
- Per-room or per-location behaviour.
- Fixed clock-time scheduling as an alternative to sun elevation. Considered for
  PowerToys parity, never wanted, and useless for a user with no working day.
  Easy to add later if asked for.
- Separate scopes for system chrome versus apps. Both registry values are
  written together, matching the existing script.
- Any "do not switch while gaming" guard.
- **Detecting or attributing who changed the theme.** G-Helper does not care
  whether a change came from its own hotkey, its icon, the Windows Settings app
  or another tool. It sets the theme when the schedule says to, and otherwise
  leaves it alone. This is the owner's call and it removes a whole mechanism;
  see [State](#state).
- Shipping this upstream in the first version; see
  [Upstream PR](#upstream-pr-deferred).

## Anti-goals

Things that would make this a failure even if it worked:

- **Surprise flips.** The theme changing when the owner did not ask and does not
  expect it. PowerToys shipped Light Switch enabled by default in 0.95 and had
  to reverse course after users saw themes flip "randomly."
- **Stomping a manual choice.** If the owner sets a theme, nothing may override
  it until the schedule genuinely disagrees.
- **Visible wrong-theme flashes**, however brief.
- **Recurring merge conflicts.** The fork must keep syncing cleanly from
  upstream with no manual work; see [Merge surface](#merge-surface).
- **A resident cost.** No new process, no new dependency, no polling loop.

---

## Constraints

**Elevated, but only after logon.** `Startup.Schedule()`
(`app/Helpers/Startup.cs:177-195`) registers a task with a `LogonTrigger` and a
`SessionStateChangeTrigger` on `ConsoleConnect`, with
`TaskLogonType.InteractiveToken` and `RunLevel = Highest`. Verified against the
live task on the machine: principal `vamsi`, `LogonType=Interactive`,
`RunLevel=Highest`. "Highest" skips the UAC prompt; it does not mean SYSTEM, and
an interactive token only exists once a session does. This costs nothing here —
the theme lives in `HKCU`, so before logon there is no hive to write and no
shell to notify.

**No ambient light sensor.** The machine (ROG Zephyrus G16 GU605MI) reports an
empty `Sensor` PnP class. `Windows.Devices.Sensors.LightSensor` is not an
option.

**The app already has every system hook needed.** `app/Program.cs:152-156`
subscribes `PowerModeChanged`, `UserPreferenceChanged`, `SessionSwitch` and
`SessionEnding`. `SystemEvents.TimeChanged` is not yet subscribed and must be
added — one line.

**Upstream edits generated designer files constantly.** `Settings.Designer.cs`
and `Extra.Designer.cs` churn on most upstream releases. Anything this feature
puts in them conflicts on every sync until a PR merges.

**Upstream translates through Crowdin.** User-visible text goes in
`Properties.Strings` and the `.resx`, never as a literal. Recent upstream commit
`6a49e421` is a Crowdin sync.

**Owner's usage has no working day.** Derived from 45 days of Kernel-Power
modern-standby events, filtered to human-caused wakes (lid, keyboard, mouse,
touchpad, power button) and merged across gaps under 20 minutes:

- Every hour of the clock is in use on at least 44% of days; 11.8 h/day total.
- The busiest single hour is **midnight** (78% of days). 02:00–05:00 runs 51–56%.
- Long idle gaps (median 5.4 h) start mostly 00:00–03:00 and end 10:00–12:00.
- Median usage block 1.8 h; 79% are under 6 h.

Two design consequences:

- **The morning crossing almost always happens while the machine is asleep or
  the owner is away** — in use at 08:28 on only 26% of days, against a median
  return around 11:00. The *resume* path is the normal path for the morning
  switch, not an edge case. A design that only armed a timer would be wrong most
  mornings.
- **The evening crossing is the one that gets watched** — in use at 18:04 on 42%
  of days, the highest of any crossing.

*Caveat on the method: "in use" means awake following a human wake, so idle time
at the desk counts, and occasional multi-day blocks in the raw data are missed
sleep events rather than real sessions.*

---

## Design

### Deciding the theme

Every evaluation answers **"what should the theme be right now?"** — never "is
it time to switch?". Given the current time, compute the sun's elevation; above
the threshold means light, below means dark.

This makes every evaluation idempotent and self-healing. A late evaluation after
a four-hour sleep lands on the correct theme instead of flipping the wrong way,
and no catch-up logic is needed for sleep, hibernate, clock changes or DST.

Write only on a mismatch with the current registry value.

### When evaluation happens

No polling loop. The app already has the hooks, so evaluation is event-driven
plus a single armed timer:

- At startup, and on `SessionSwitch` (logon, unlock, console connect),
  `PowerModeChanged` (resume), and `TimeChanged`.
- After each evaluation, compute the next elevation crossing and arm **one**
  timer for it. When it fires: evaluate, apply, recompute, re-arm.

That is roughly four or five evaluations a day, each a few lines of arithmetic
and a registry read.

An earlier draft of this design used PowerToys' 60-second poll. It was dropped:
PowerToys polls because it is a standalone service with no good hooks, and
G-Helper has all of them. The *level-based decision* is worth keeping from that
design; the tick is not.

.NET timers do not advance while the machine is in standby, so a timer armed
across a sleep fires late. The resume handler normally beats it, and both reach
the same answer.

**No crossing in the next 24 hours** (possible at high latitude, not at the
owner's): re-arm at local midnight and leave the theme as the level test says.
Polar winter correctly means "dark all day."

### State

**Persisted state is one value: the time of the last crossing applied**, in
`AppConfig`, in UTC.

At every evaluation, find the most recent crossing at or before now. If it is
newer than the recorded one, apply the level answer and record it. Otherwise do
nothing.

That is the entire mechanism, and it produces the intended behaviour without
anything else existing:

- **Between crossings G-Helper never writes.** A manual change therefore simply
  stands — from the hotkey, from the icon, from the Windows Settings app, from
  another tool. No provenance tracking, no `UserPreferenceChanged` handler, no
  record of what G-Helper itself last applied.
- **A manual toggle stands until the schedule next disagrees with it**, which is
  the rule the owner asked for, as a consequence rather than as a feature.
- **A crossing missed during sleep still lands**, because resume re-evaluates
  and sees an unapplied crossing behind it. Given the usage data above, this is
  the normal path for the morning switch.

It survives restart because it is persisted, and it is immune to DST because it
is UTC. On first run, initialise it to the most recent crossing and apply
immediately, so a fresh install lands on the right theme.

An earlier draft of this design tracked a manual-override timestamp, handled
`UserPreferenceChanged`, persisted the last theme G-Helper applied, and inferred
external changes at startup to avoid stomping them. All of it is deleted. The
owner's framing — G-Helper should not care where a change came from, only that
it sets the theme when it is meant to — collapses the state model to a single
timestamp.

Worked examples, using the owner's crossings for 2026-10-19 (light 08:28, dark
18:04):

| Situation | Behaviour |
|---|---|
| Evening click to light at 20:30 | Light through the night. The 08:28 crossing agrees, so nothing happens. Schedule first disagrees at 18:04 the next evening — about 21 hours later. |
| Blinds closed, click to dark at 12:00 | The 18:04 dark crossing agrees and does nothing. Dark runs straight through to 08:28 tomorrow. |
| Morning click to dark at 10:00 | Both remaining crossings agree. Holds 22 hours, until 08:28 tomorrow. |

The last row is the honest cost: nothing ends a manual choice early except the
owner toggling again. This was chosen deliberately over a 6-hour expiry window, which
was designed in full and then discarded — it added an expiry timer, a persisted
expiry, UTC/DST handling, a configurable duration, and a 30-minute guard against
a real defect it introduced (a noon click expiring at 18:00, four minutes before
the 18:04 crossing, produced a four-minute light flash). None of that machinery
exists in this design, and the defect it guarded against cannot occur.

### Writing the theme

Port of `theme_manager.ps1`, which is already correct and carries a hard-won
detail:

1. Set `SystemUsesLightTheme` and `AppsUseLightTheme` under
   `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`.
2. Broadcast `WM_SETTINGCHANGE` (`0x001A`) to `HWND_BROADCAST` with
   `lParam = "ImmersiveColorSet"` via `SendMessageTimeout`, flags
   `SMTO_ABORTIFHUNG` (`0x0002`), 5 s timeout.

The script carries a comment recording that `wParam` must be a genuine zero
pointer — in PowerShell 5.1, `[UIntPtr]0` throws a cast error that silently
kills the broadcast and leaves the taskbar painted in the old theme. The C# port
does not inherit that specific bug, but the lesson stands: **if the broadcast
does not go out, the registry write looks like it did nothing.** Verify the
taskbar actually repaints, not just that the registry changed.

G-Helper's own windows normally follow — `RForm.IsDarkTheme()` reads
`AppsUseLightTheme` and `InitTheme()` restyles (`app/UI/RForm.cs:84-134`).

**Exception:** `IsDarkTheme()` honours a `ui_mode` config value of `dark` or
`light` ahead of the registry (`app/UI/RForm.cs:86-98`). If the user has pinned
G-Helper's own chrome that way, it will not follow the system theme, and the
sun/moon icon will sit in a window whose colours contradict it. **This feature
ignores `ui_mode` entirely** — pinning it is a deliberate choice about
G-Helper's own windows, and this feature controls the Windows theme, which is a
different thing.

### The control surface

**1. Sun/moon icon — status and toggle.** `pictureGamma`, the 32×32 PictureBox
left of "Flicker-free Dimming / Visual Mode"
(`app/Settings.Designer.cs:1923-1932`), currently shows
`Properties.Resources.icons8_brightness_32` as a static decoration.

- Sun when light, moon when dark. No highlight, no ring, no border — the owner
  was explicit: the icon changes, nothing else does.
- **Left-click** toggles the theme.
- **Right-click** opens the settings dialog.
- Tooltip names both and shows the next scheduled switch.

The image is assigned at runtime in `Settings.cs`, not in the designer, so the
designer file is not touched. Requires one new moon icon resource; match the
existing icons8 style and licensing.

Overloading a decorative icon with behaviour is consistent with this codebase,
not a deviation from it — `labelCharge` swaps its own text to battery health on
`MouseEnter` and fires `BatteryControl.BatteryReport()` on `Click`
(`Settings.cs:254-298`), and `labelMidFan` reuses one label for mid-fan speed or
GPU temperature (`Settings.cs:1688-1691`).

**Where this icon is not available.** `InitVisual()` (`app/Settings.cs:383-430`)
shows `panelGamma` only on OLED panels, or where colour gamut modes exist, or
where colour profiles can be installed — and never when `hide_visual` is set. On
any other machine there is no icon, therefore no status display, no left-click
toggle, and **no way to open the settings dialog**. The owner's G16 is OLED, so
the panel is always present for him.

`panelVersion` was considered as a universally-visible alternative — it is never
conditionally hidden and already collects loose global toggles
(`buttonEnergySaver`, `buttonAmdOled`, `buttonArmoury`). **Rejected on misclick
cost:** that panel is also where `labelVersion.Click` fires
`updateControl.Update()` (`Settings.cs:976-979`) and `buttonArmoury` opens a
prompt that runs the Armoury Crate uninstaller (`Settings.cs:310-314`). A
control the owner uses several times a day does not belong beside actions that
launch an updater or an uninstaller on a slip.

So the icon's placement is chosen for this machine. Finding a universal home is
an upstream problem, deferred with the PR.

**2. Bindable hotkey.** Add `{"theme", <localized string>}` to the custom-action
dictionary at `app/Extra.cs:30-54` and a `case "theme":` to the dispatcher in
`app/Input/InputDispatcher.cs:632-724`. It then appears in the Extra window's
dropdowns and can be bound to M1–M5, the Fn row or the paddle. The owner will
bind M4.

**3. Settings dialog.** A **new form**, opened by right-clicking the sun/moon
icon. A new file cannot conflict with upstream, ever — which is why this was
chosen over adding fields to the Extra window, whose designer file churns.

Contents:

- **A toggle enabling or disabling automatic location-based switching.** With it
  off, nothing is scheduled and nothing is written on its own; the icon and the
  hotkey still toggle the theme by hand. This is the feature's on/off switch and
  the only place it exists.
- Latitude and longitude, with the seeded values pre-filled and editable.
- Elevation threshold, defaulting to 10°.
- A read-only line showing today's resolved crossings — "next switch at 18:04" —
  so the math is visible and verifiable without waiting for it to fire.

A new WinForms form carries its own `.resx` for its own controls, so every
string in this dialog lives in a file upstream has never touched and cannot
conflict with.

**The tray context menu is deliberately not used.** The owner's muscle memory
for right-clicking the tray icon is quit/exit, and retraining it is a cost with
no benefit here.

### Location

Latitude and longitude live in `AppConfig`. On first run, seed from the system
timezone's representative coordinate: `TimeZoneInfo.Local` →
`TryConvertWindowsIdToIanaId` → a small embedded zone-to-coordinate table.

The seed is deliberately rough. A timezone says little about latitude —
`America/Chicago` spans south Texas to North Dakota, and its representative
coordinate (~41.85°N, −87.6°W) is about 11° of latitude from the owner's 30.5°N,
which is roughly an hour of error at the solstices. The seed exists so the
feature does something sensible before anyone opens the dialog, not so it is
accurate. The dialog is how it becomes accurate.

Sunrise/sunset is computed locally with the NOAA solar-position formula — no
network call, no TLS negotiation, no offline failure path. A reference
implementation used to produce the tables in this document is in the design
conversation; it is about 40 lines.

### Defaults

- **The schedule ships disabled** in code. It writes system settings, and a
  feature that starts moving the theme on its own without being asked is the
  first anti-goal.
- **The owner enables it once, in the dialog**, and sets his coordinates there.
  That is persisted config, not a code change — so the fork carries **no
  app-code delta for its own defaults**, and `AutoUpdateControl.cs` remains the
  only place this fork differs from upstream in `app/`.
- The manual toggle and the hotkey work regardless of the schedule's state.

---

## Merge surface

The fork must keep syncing cleanly from upstream. Every placement decision above
was made with that in mind:

| Change | File | Conflict risk |
|---|---|---|
| Theme controller, solar math, schedule state | new files | none |
| Settings dialog, and all of its strings | new form + its own `.resx` | none |
| Moon icon | new file + one `Resources.resx` entry | one appended entry |
| Icon behaviour and image swap | `Settings.cs` | low — hand-written, additive |
| Hotkey action | `Extra.cs`, `InputDispatcher.cs` | low — one dictionary entry, one case |
| `TimeChanged` subscription | `Program.cs` | low — one line |
| **`Strings.resx`** | — | **none — see below** |
| **Designer files** | — | **none — nothing goes in them** |

`Strings.resx` is deliberately untouched. Upstream modifies it in **103 of the
last 200 commits**, between feature work and Crowdin syncs, so new entries there
would conflict on roughly every other sync. The dialog avoids it by owning its
`.resx`; the only two remaining pieces of user-visible text — the hotkey's
dropdown label in `Extra.cs` and the icon tooltip — are English literals in this
fork, and become `Properties.Strings` entries on the PR branch if that happens.

---

## Upstream PR (deferred)

The owner intends to offer this upstream eventually, and has decided to **build
it for himself first and cross that bridge later**. Nothing in this version is
shaped around the PR. The design happens to be close to PR-ready anyway, because
the choices that keep the fork conflict-free are the same ones upstream would
want.

Known gaps to close if and when a PR happens, recorded so they are not
rediscovered:

- **Entry point on machines without `panelGamma`.** The dialog is unreachable
  there, and the schedule ships disabled, so such a user could only enable it by
  hand-editing `config.json`. This is the one genuine blocker. It needs a home
  that is always visible and is not `panelVersion` — see the rejection above.
- **Strings.** The two literals move into `Properties.Strings`; translations
  follow through Crowdin.
- **The icon's meaning.** A sun on a row labelled "Flicker-free Dimming / Visual
  Mode" reads as brightness. Defensible here, likely a review objection there.
- **Tests.** See below.

---

## Rejected approaches

**Camera-based room brightness.** The owner's preferred idea, and the one that
actually matches the intent — what matters is light in the room, not light
outside it. Rejected for v1 on four findings: the built-in RGB camera was
disabled at the device level when this was investigated (it has since been
re-enabled); the privacy LED and the Windows camera indicator fire on every
sample, which at any useful cadence means a light blinking all day; auto-exposure
actively defeats the measurement, since a webcam's AGC drives mean frame
brightness toward mid-grey regardless of actual scene luminance, so a true
reading requires either locking exposure and gain or reading them back and
computing an EV; and the camera is unavailable during video calls, with the lid
shut, or when docked, so the sun math is needed as a fallback regardless.

A hybrid — sun elevation as the baseline, camera sampled only within ~45 minutes
of a predicted crossing — was designed and is the natural v2. It bounds the LED
blinking to a handful of samples around dawn and dusk and corrects for weather
for free.

**IR camera as a sunlight detector.** Genuinely interesting: sunlight is rich in
infrared and LED room lighting is not, so ambient IR is close to a direct
measurement of "is real daylight in this room." Always available, never
conflicts with a video call. Rejected as unproven and undocumented for this use,
with the same exposure problem.

**Phone as a light sensor.** Rejected by the owner on the obvious grounds: it
only works when the phone and the laptop are in the same room, which cannot be
assumed.

**Dock and power state, or Wi-Fi-derived location.** Both are free and need no
sensor, but both answer "where am I", not "how bright is it". Wi-Fi location
remains worth considering later for keeping coordinates correct while
travelling.

**Everything above shares one limitation worth stating plainly:** no sun model
can know the blinds are shut at noon. That case is handled by the manual toggle,
by design.

---

## Testing

The repository has a solution file (`app/GHelper.sln`) but **no test project and
no test directory**, and never has had one. Adding one means a new project plus
a CI step — scope the owner did not ask for, on a build surface an upstream
maintainer may not want changed.

So: keep the solar math in a **pure static class with no dependencies on
WinForms, the registry or the clock** — time in, elevation out — and verify it
against the three reference rows in this document with a throwaway script. The
purity is the part that matters; it keeps a real test project a later addition
rather than a rewrite.

Everything else in this feature is I/O or UI and gets verified by running it.
The one thing that must be checked by eye rather than by assertion: **the
taskbar actually repainting**, because a failed broadcast looks exactly like a
successful registry write.

---

## Left to the builder

- Class and file layout.
- How the timezone-to-coordinate table is embedded and how many zones it covers.
- Dialog layout and validation (latitude −90..90, longitude −180..180, threshold
  within a sane range).
- Exact tooltip and string wording.
- Which icons8 moon asset, at what size, matching the existing set.
