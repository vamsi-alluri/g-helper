# Automatic light/dark theme switching — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give G-Helper a manual Windows light/dark theme toggle on a bindable key and an icon, plus an optional schedule that flips the theme at sun-elevation crossings computed locally.

**Architecture:** A pure static solar layer (`SolarPosition`, `ThemeSchedule`) answers "what should the theme be right now?" and "when is the next crossing?" with no dependency on WinForms, the registry or the clock. A thin `WindowsTheme` writes `HKCU` and broadcasts `WM_SETTINGCHANGE`. `ThemeControl` wires the two together: it evaluates on startup, session switch, resume and clock change, arms exactly one timer for the next crossing, and persists a single value — the UTC time of the last crossing it applied. Between crossings it never writes, which is what makes a manual toggle stand.

**Tech Stack:** C# / .NET 10 (`net10.0-windows`), WinForms, `Microsoft.Win32.Registry`, `SystemEvents`. No new NuGet packages. No test project (see Verification Harness).

**Spec:** `docs/superpowers/specs/2026-10-19-theme-schedule-design.md`

**Branch:** create `feature/theme-schedule` off `main` before Task 1.

## Global Constraints

- **New code lives in new files.** `app/Theme/*.cs` and `app/ThemeSettings.*`. The project is SDK-style, so new `.cs` and `.resx` files need no `.csproj` edit.
- **No designer file may be touched.** Not `Settings.Designer.cs`, not `Extra.Designer.cs`. The icon's image and event handlers are assigned at runtime in `Settings.cs`. `ThemeSettings.Designer.cs` is a new file and is exempt.
- **`app/Properties/Strings.resx` must not be modified.** The two pieces of user-visible text outside the new dialog (the hotkey dropdown label in `Extra.cs`, the icon tooltip in `Settings.cs`) are English literals in this fork. The dialog's own strings live in `app/ThemeSettings.resx`.
- **`SolarPosition` and `ThemeSchedule` take no dependency on WinForms, the registry, `DateTime.Now`, `TimeZoneInfo` or `AppConfig.`** Time in, numbers out. This is what makes them verifiable, and a later real test project an addition rather than a rewrite.
- **Config keys are `theme_schedule`, `theme_lat`, `theme_lon`, `theme_elevation`, `theme_last_crossing`.** The bare key `theme` is already taken by upstream (`RForm.InitColors` reads it for `"flat"`) and must not be reused.
- **`AppConfig` has only `int` and `string` setters** (`app/AppConfig.cs:232-241`). Latitude, longitude and the crossing timestamp are stored as strings; the threshold and the enable flag as ints.
- **All persisted and computed times are UTC.** `theme_last_crossing` is round-trip format (`"O"`), parsed with `DateTimeStyles.RoundtripKind`. All string↔number conversion uses `CultureInfo.InvariantCulture`.
- **Default threshold is 10°.** Default enable flag is off.
- **Registry:** `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, values `SystemUsesLightTheme` and `AppsUseLightTheme`, written together, `1` = light.
- **Broadcast:** `WM_SETTINGCHANGE` = `0x001A` to `HWND_BROADCAST` = `0xFFFF`, `wParam` = `IntPtr.Zero`, `lParam` = `"ImmersiveColorSet"`, via `SendMessageTimeout` with `SMTO_ABORTIFHUNG` = `0x0002` and a 5000 ms timeout.
- **This feature ignores `ui_mode` entirely.** Do not read it, do not write it, do not consult `RForm.IsDarkTheme()` to decide the system theme.

## Review Focus

Input classes the spec implies that no task's happy path exercises. Each has a test, in the task named.

1. **Garbage or absent coordinates in config** — blank on first run, or hand-edited to `"abc"`, `"91"`, or `"30,5052"` on a comma-decimal locale. Expected: fall back to the timezone seed and keep running, never throw. *(Task 3)*
2. **No crossing in the next 24 hours** — polar latitude, or a threshold the sun never reaches at this latitude (e.g. 10° at 70°N in December). Expected: `NextCrossing`/`PreviousCrossing` return `null`, the level test still decides the theme, and the controller re-arms at local midnight rather than not at all. *(Tasks 2 and 5)*
3. **Elevation exactly at the threshold.** Expected: `>=` counts as light, so the predicate has no undefined point and a crossing instant is itself "light". *(Task 2)*
4. **First run, no `theme_last_crossing` persisted.** Expected: apply immediately to the correct theme and record the most recent crossing — not "do nothing until the next crossing", which would leave a fresh install wrong for up to 12 hours. *(Task 5)*
5. **`AppsUseLightTheme` missing from the registry.** Expected: read as light (Windows' own default), matching `RForm.IsDarkTheme()`'s treatment at `app/UI/RForm.cs:106`. A missing value must not be read as dark and must not throw. *(Task 4)*

---

## File Structure

| File | Responsibility |
|---|---|
| `app/Theme/SolarPosition.cs` (new) | NOAA solar elevation. One public function. Pure. |
| `app/Theme/ThemeSchedule.cs` (new) | Level test and crossing search over `SolarPosition`. Pure. |
| `app/Theme/ThemeConfig.cs` (new) | Reads/writes the five config keys; seeds coordinates from the timezone table; validates. |
| `app/Theme/TimezoneCoordinates.cs` (new) | IANA zone → representative lat/lon table. |
| `app/Theme/WindowsTheme.cs` (new) | Registry read/write + `WM_SETTINGCHANGE` broadcast. |
| `app/Theme/ThemeControl.cs` (new) | Orchestration: evaluation, the single armed timer, persisted crossing, manual toggle. |
| `app/ThemeSettings.cs` + `.Designer.cs` + `.resx` (new) | The settings dialog and all of its strings. |
| `app/Settings.cs` (modify) | `pictureGamma` image swap, left-click toggle, right-click dialog, tooltip. |
| `app/Extra.cs` (modify) | One `customActions` entry. |
| `app/Input/InputDispatcher.cs` (modify) | One `case "theme":`. |
| `app/Program.cs` (modify) | `TimeChanged` subscription and `ThemeControl` wiring. |
| `app/Properties/Resources.resx` + `app/Resources/icons8-moon-32.png` (modify/new) | Moon icon, one appended entry. |

## Verification Harness

The repository has no test project and the spec keeps it that way. The pure layer is verified by a throwaway console harness **outside the repository**, which compiles the real source files by absolute path. Create it once in Task 1 and extend it in Task 2.

Harness root: `<scratchpad>/solarcheck/` where `<scratchpad>` is this session's scratchpad directory.

`<scratchpad>/solarcheck/solarcheck.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>annotations</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <AssemblyName>solarcheck</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="Program.cs" />
    <Compile Include="C:\Users\vamsi\source\repos\vamsi-alluri\g-helper\app\Theme\SolarPosition.cs" />
    <!-- Task 2 appends ThemeSchedule.cs here -->
  </ItemGroup>
</Project>
```

`Program.cs` in the harness holds the checks as plain code, prints one line per check, and exits non-zero if any failed:

```csharp
static int failed = 0;
static void Check(string name, bool ok, string detail)
{
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {name} — {detail}");
    if (!ok) failed++;
}
// ... checks ...
return failed == 0 ? 0 : 1;
```

Run with `dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`. Everything else in this feature is I/O or UI and is verified by running the app, including the one thing that cannot be asserted: **the taskbar actually repainting**, because a failed broadcast looks exactly like a successful registry write.

The whole-repo build check used throughout is:

```bash
dotnet build app/GHelper.csproj -c Debug
```

---

### Task 1: Solar elevation

**Files:**
- Create: `app/Theme/SolarPosition.cs`
- Create: `<scratchpad>/solarcheck/solarcheck.csproj`, `<scratchpad>/solarcheck/Program.cs`

**Interfaces:**
- Consumes: nothing.
- Produces: `namespace GHelper.Theme; public static class SolarPosition` with
  `public static double Elevation(DateTime utc, double latitude, double longitude)` — returns the sun's elevation angle in degrees above the horizon (negative below). `utc` must be `DateTimeKind.Utc`; latitude and longitude in signed decimal degrees, east and north positive.

- [ ] **Step 1: Write the failing checks**

In `<scratchpad>/solarcheck/Program.cs`, the three reference rows from the spec at the owner's coordinates (30.5052, −97.8203). Local times are US Central: CDT (UTC−5) in June and October, CST (UTC−6) in December. Tolerance 0.2°, which the spec's own rounding needs.

```csharp
const double Lat = 30.5052, Lon = -97.8203;
static void Row(string label, DateTime utc, double expected)
{
    double el = SolarPosition.Elevation(utc, Lat, Lon);
    Check(label, Math.Abs(el - expected) < 0.2, $"got {el:F2}, expected {expected:F1}");
}
Row("2026-06-21 07:30 CDT", new DateTime(2026, 6, 21, 12, 30, 0, DateTimeKind.Utc), 10.9);
Row("2026-10-19 08:36 CDT", new DateTime(2026, 10, 19, 13, 36, 0, DateTimeKind.Utc), 11.6);
Row("2026-12-21 08:24 CST", new DateTime(2026, 12, 21, 14, 24, 0, DateTimeKind.Utc), 10.2);
Check("solar noon is high", SolarPosition.Elevation(new DateTime(2026, 6, 21, 18, 0, 0, DateTimeKind.Utc), Lat, Lon) > 80, "June solar noon above 80 deg");
Check("midnight is below horizon", SolarPosition.Elevation(new DateTime(2026, 6, 21, 6, 0, 0, DateTimeKind.Utc), Lat, Lon) < 0, "local midnight below 0 deg");
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`
Expected: compile error — `SolarPosition` does not exist.

- [ ] **Step 3: Implement `SolarPosition.Elevation` in `app/Theme/SolarPosition.cs`**

Standard NOAA solar-position chain, roughly 40 lines, in this order: Julian day from `utc` → Julian century `t` → geometric mean longitude and mean anomaly of the sun → eccentricity → equation of the center → apparent longitude (with the −0.00569 and −0.00478·sin(Ω) nutation/aberration terms) → mean obliquity corrected by +0.00256·cos(Ω) → declination → equation of time → true solar time from `utc`, the equation of time and 4·longitude → hour angle → elevation as 90° − zenith.

Two details the formula does not make obvious and the checks will not catch on their own:
- Clamp the cosine of the zenith to [−1, 1] before `Math.Acos`; floating error puts it outside at the poles.
- Take true solar time modulo 1440 minutes so the hour angle stays in range across the UTC day boundary.

No atmospheric refraction correction: the threshold is a configurable preference, not an astronomical event, and refraction near 10° is under 0.1°.

- [ ] **Step 4: Run the harness to verify it passes**

Run: `dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`
Expected: five `PASS` lines, exit code 0.

- [ ] **Step 5: Verify the app still builds**

Run: `dotnet build app/GHelper.csproj -c Debug`
Expected: `Build succeeded`, 0 errors.

- [ ] **Step 6: Commit**

```bash
git add app/Theme/SolarPosition.cs
git commit -m "feat(theme): add NOAA solar elevation calculation"
```

---

### Task 2: Level test and crossing search

**Files:**
- Create: `app/Theme/ThemeSchedule.cs`
- Modify: `<scratchpad>/solarcheck/solarcheck.csproj` (add `ThemeSchedule.cs` to `<ItemGroup>`), `<scratchpad>/solarcheck/Program.cs`

**Interfaces:**
- Consumes: `SolarPosition.Elevation(DateTime utc, double latitude, double longitude)` from Task 1.
- Produces: `namespace GHelper.Theme;`
  - `public readonly record struct SolarSite(double Latitude, double Longitude, double ThresholdDegrees)`
  - `public static class ThemeSchedule` with
    - `public static bool IsLight(DateTime utc, SolarSite site)` — elevation `>=` threshold.
    - `public static DateTime? NextCrossing(DateTime utc, SolarSite site)` — the first instant after `utc` where `IsLight` differs from `IsLight(utc, site)`, searched up to 24 hours ahead; `null` if there is none.
    - `public static DateTime? PreviousCrossing(DateTime utc, SolarSite site)` — the most recent instant at or before `utc` where the value changed to what it is now, searched up to 24 hours back; `null` if there is none.
  - Both crossings are returned truncated to whole seconds, `DateTimeKind.Utc`.

- [ ] **Step 1: Write the failing checks**

Append to the harness. The owner's 2026-10-19 crossings at a 10° threshold are 08:28 CDT (13:28 UTC) and 18:04 CDT (23:04 UTC) — confirmed against an independent implementation while writing this plan, and matching the spec.

```csharp
var site = new SolarSite(Lat, Lon, 10.0);
var noon = new DateTime(2026, 10, 19, 17, 0, 0, DateTimeKind.Utc);      // 12:00 CDT
Check("noon is light", ThemeSchedule.IsLight(noon, site), "12:00 CDT above 10 deg");
Check("3am is dark", !ThemeSchedule.IsLight(new DateTime(2026, 10, 19, 8, 0, 0, DateTimeKind.Utc), site), "03:00 CDT below 10 deg");

var next = ThemeSchedule.NextCrossing(noon, site);
Check("next crossing is the evening one", next is not null && next.Value.Hour == 23 && next.Value.Minute == 4, $"got {next:HH:mm:ss}, expected 23:04");
var prev = ThemeSchedule.PreviousCrossing(noon, site);
Check("previous crossing is the morning one", prev is not null && prev.Value.Hour == 13 && prev.Value.Minute == 28, $"got {prev:HH:mm:ss}, expected 13:28");
Check("crossings sit on the threshold", next is not null && Math.Abs(SolarPosition.Elevation(next.Value, Lat, Lon) - 10.0) < 0.05, "elevation at the crossing is 10 deg");

// Review Focus 3: the threshold itself counts as light
Check("threshold is light", next is not null && ThemeSchedule.IsLight(prev!.Value, site), "the morning crossing instant is light");

// Review Focus 2: no crossing within 24h
var polar = new SolarSite(78.2, 15.6, 10.0);                             // Svalbard
var polarWinter = new DateTime(2026, 12, 21, 12, 0, 0, DateTimeKind.Utc);
Check("polar winter has no crossing", ThemeSchedule.NextCrossing(polarWinter, polar) is null, "null, not an exception or a wrong instant");
Check("polar winter is dark", !ThemeSchedule.IsLight(polarWinter, polar), "dark all day");
var polarSummer = new DateTime(2026, 6, 21, 12, 0, 0, DateTimeKind.Utc);
Check("polar summer has no crossing", ThemeSchedule.NextCrossing(polarSummer, polar) is null, "null");
Check("polar summer is light", ThemeSchedule.IsLight(polarSummer, polar), "light all day");
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`
Expected: compile error — `ThemeSchedule` does not exist.

- [ ] **Step 3: Implement `ThemeSchedule` in `app/Theme/ThemeSchedule.cs`**

Crossing search: scan in one-minute steps (forward or backward) from `utc` up to 24 hours for the first step where `IsLight` flips, then bisect that one-minute bracket about 6 times to land within a second. One minute cannot hide a crossing — elevation near 10° moves monotonically and far slower than that at any latitude where a crossing exists.

- [ ] **Step 4: Run the harness to verify it passes**

Run: `dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`
Expected: all `PASS`, exit code 0.

- [ ] **Step 5: Verify the app still builds**

Run: `dotnet build app/GHelper.csproj -c Debug`
Expected: `Build succeeded`.

- [ ] **Step 6: Commit**

```bash
git add app/Theme/ThemeSchedule.cs
git commit -m "feat(theme): add sun elevation level test and crossing search"
```

---

### Task 3: Config and coordinate seeding

**Files:**
- Create: `app/Theme/TimezoneCoordinates.cs`, `app/Theme/ThemeConfig.cs`
- Modify: `<scratchpad>/solarcheck/solarcheck.csproj`, `<scratchpad>/solarcheck/Program.cs`

**Interfaces:**
- Consumes: `SolarSite` from Task 2; `AppConfig.Get/GetString/Set/Is` (`app/AppConfig.cs:198-241`).
- Produces: `namespace GHelper.Theme;`
  - `public static class TimezoneCoordinates` with `public static (double Latitude, double Longitude) ForIanaZone(string? ianaId)` — table lookup, falling back to `(0, 0)` for an unknown or null zone.
  - `public static class ThemeConfig` with
    - `public static bool ScheduleEnabled { get; set; }` — key `theme_schedule`, default `false`.
    - `public static SolarSite Site { get; }` — reads `theme_lat`, `theme_lon`, `theme_elevation`; seeds and persists coordinates on first read if absent or invalid.
    - `public static void SetSite(double latitude, double longitude, int thresholdDegrees)` — validates and persists.
    - `public static DateTime? LastCrossing { get; set; }` — key `theme_last_crossing`, `"O"` format UTC.
    - `public static bool TryParseCoordinate(string? text, double limit, out double value)` — `InvariantCulture`, rejects NaN, infinity and `|value| > limit`. Used by both the config reader and the dialog's validation.

- [ ] **Step 1: Write the failing checks for the pure parts**

`ThemeConfig` reads `AppConfig`, which drags in the rest of the app, so it stays out of the harness; only `TimezoneCoordinates.cs` is linked in. `TryParseCoordinate` is exercised through the dialog's validation in Task 7 and through the Review Focus 1 cases in Step 5.

```csharp
var chicago = TimezoneCoordinates.ForIanaZone("America/Chicago");
Check("Chicago seeds plausibly", chicago.Latitude > 40 && chicago.Latitude < 43 && chicago.Longitude < -86 && chicago.Longitude > -89, $"got {chicago}");
var unknown = TimezoneCoordinates.ForIanaZone("Mars/Olympus_Mons");
Check("unknown zone falls back", unknown == (0.0, 0.0), $"got {unknown}");
Check("null zone falls back", TimezoneCoordinates.ForIanaZone(null) == (0.0, 0.0), "null is not an exception");
```

- [ ] **Step 2: Run the harness to verify it fails**

Run: `dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`
Expected: compile error — `TimezoneCoordinates` does not exist.

- [ ] **Step 3: Implement `TimezoneCoordinates.ForIanaZone`**

A `static readonly Dictionary<string, (double, double)>` of IANA zone → representative coordinate, ordinal-ignore-case. Cover the zones a user of this app plausibly sits in: the North American zones, the Western and Central European ones, the UK, the main Asian and Australian ones, and Brazil — roughly 30 entries. The spec is explicit that the seed is deliberately rough and exists only so the feature does something sensible before the dialog is opened; do not chase coverage.

- [ ] **Step 4: Implement `ThemeConfig` in `app/Theme/ThemeConfig.cs`**

`Site` reads `theme_lat`/`theme_lon` through `TryParseCoordinate`. If either is absent or fails to parse — Review Focus 1 — seed from `TimeZoneInfo.Local.Id` → `TimeZoneInfo.TryConvertWindowsIdToIanaId` → `TimezoneCoordinates.ForIanaZone`, persist the seeded pair, and return it. Never throw out of `Site`. Threshold: `AppConfig.Get("theme_elevation", 10)`, clamped to 0..20. Coordinates persist with `value.ToString(CultureInfo.InvariantCulture)`. `LastCrossing` parses with `DateTimeStyles.RoundtripKind | DateTimeStyles.AdjustToUniversal` and returns `null` on any parse failure.

- [ ] **Step 5: Verify parsing and seeding by eye**

Run the harness (`dotnet run --project <scratchpad>/solarcheck/solarcheck.csproj`) — expected all `PASS`.
Then run: `dotnet build app/GHelper.csproj -c Debug` — expected `Build succeeded`.
Then confirm the Review Focus 1 cases in the running app at the end of Task 5, where config is live: set `theme_lat` to `"abc"`, then to `"91"`, then to `"30,5052"`, restart G-Helper, and confirm each time that it starts, logs the fallback, and rewrites the key with the seeded value.

- [ ] **Step 6: Commit**

```bash
git add app/Theme/TimezoneCoordinates.cs app/Theme/ThemeConfig.cs
git commit -m "feat(theme): add schedule config with timezone coordinate seeding"
```

---

### Task 4: Writing the Windows theme

**Files:**
- Create: `app/Theme/WindowsTheme.cs`

**Interfaces:**
- Consumes: `Logger.WriteLine` (`app/Helpers/Logger.cs`).
- Produces: `namespace GHelper.Theme; public static class WindowsTheme` with
  - `public static bool IsLight()` — reads `AppsUseLightTheme`; a missing or non-int value reads as **light** (Review Focus 5), matching `app/UI/RForm.cs:106`.
  - `public static void Apply(bool light)` — writes both registry values and broadcasts. Logs and swallows any exception; never throws.
  - `public static bool Toggle()` — `Apply(!IsLight())`, returns the theme it set (`true` = light).

- [ ] **Step 1: Implement `WindowsTheme`**

Port of `theme_manager.ps1`, which the spec records as already correct:

1. `Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")`, then `SetValue` both `SystemUsesLightTheme` and `AppsUseLightTheme` to `light ? 1 : 0` as `RegistryValueKind.DWord`.
2. Broadcast, with the P/Invoke declared in this file:

```csharp
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
```

called as `SendMessageTimeout((IntPtr)0xFFFF, 0x001A, IntPtr.Zero, "ImmersiveColorSet", 0x0002, 5000, out _)`.

Log one line per apply: the theme set and whether the broadcast returned non-zero. The spec's warning is the reason: **if the broadcast does not go out, the registry write looks like it did nothing** — and the log is the only trace of that distinction.

- [ ] **Step 2: Verify the app builds**

Run: `dotnet build app/GHelper.csproj -c Debug`
Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add app/Theme/WindowsTheme.cs
git commit -m "feat(theme): write Windows theme registry values and broadcast the change"
```

---

### Task 5: The controller and its wiring

**Files:**
- Create: `app/Theme/ThemeControl.cs`
- Modify: `app/Program.cs:152-156` (subscriptions), and the startup block above it

**Interfaces:**
- Consumes: `ThemeSchedule`, `ThemeConfig`, `WindowsTheme`, `SolarSite`.
- Produces: `namespace GHelper.Theme; public class ThemeControl` with
  - `public void Init()` — first evaluation and timer arm. Called once at startup.
  - `public void Evaluate()` — the whole mechanism (below). Safe to call from any of the system-event handlers.
  - `public bool Toggle()` — manual toggle; calls `WindowsTheme.Toggle()`, does **not** touch `LastCrossing`, returns the theme set.
  - `public DateTime? NextSwitchLocal { get; }` — the armed crossing in local time, or `null` when the schedule is off or there is no crossing. The icon's tooltip and the dialog both read it.
  - `public event Action? ThemeApplied` — raised after any apply, manual or scheduled, so `Settings.cs` can refresh the icon.

`Evaluate()` is exactly this:

1. If `!ThemeConfig.ScheduleEnabled`: disarm the timer, clear `NextSwitchLocal`, return. Nothing is written.
2. `site = ThemeConfig.Site`; `now = DateTime.UtcNow`.
3. `last = ThemeSchedule.PreviousCrossing(now, site)`.
4. If `ThemeConfig.LastCrossing is null` — first run, Review Focus 4 — apply `ThemeSchedule.IsLight(now, site)` and set `LastCrossing` to `last ?? now`.
5. Else if `last is not null && last > ThemeConfig.LastCrossing`: apply `ThemeSchedule.IsLight(now, site)` and set `LastCrossing = last`.
6. Else: write nothing. This is the clause that makes a manual toggle stand.
7. Arm one timer: `ThemeSchedule.NextCrossing(now, site)` → interval = that instant − now, plus 2 seconds of slack. If it is `null` (Review Focus 2), arm for the next local midnight instead. Disarm any previous timer first; there is never more than one.

The timer is a `System.Windows.Forms.Timer` created on the UI thread, so its `Tick` lands there and the icon refresh needs no marshalling. On `Tick`: stop, `Evaluate()`.

- [ ] **Step 1: Implement `ThemeControl`**

Follow the seven steps above literally. Log each evaluation: whether it applied, the theme, the crossing it recorded, and the next armed instant. These log lines are how the behaviour is verified in Step 3, since none of it can be asserted.

- [ ] **Step 2: Wire it into `Program.cs`**

- Add `public static ThemeControl themeControl = new ThemeControl();` beside the other static controls.
- After `SetAutoModes(init: true)`, call `themeControl.Init()`.
- Add `SystemEvents.TimeChanged += SystemEvents_TimeChanged;` next to the existing subscriptions at `app/Program.cs:152-156`, with a handler that logs and calls `themeControl.Evaluate()`.
- Call `themeControl.Evaluate()` from the existing `SystemEvents_SessionSwitch` logon/unlock/console-connect branch (`app/Program.cs:241`) and from `SystemEvents_PowerModeChanged` on resume — that is, after the `PowerModes.Suspend` early return at `app/Program.cs:397-405`. Per the spec's usage data, **resume is the normal path for the morning switch, not an edge case.**
- Do **not** add anything to `SystemEvents_UserPreferenceChanged`. The spec deletes provenance tracking deliberately.

- [ ] **Step 3: Verify by running the app**

Run: `dotnet build app/GHelper.csproj -c Debug` — expected `Build succeeded`.

Then start the built `GHelper.exe` and work through these, reading `app/logs/` after each:

1. Schedule off (the default): nothing is logged as applied, no timer armed, and the registry is untouched across a restart.
2. Set `theme_schedule` to 1 and remove `theme_last_crossing`: on start, the theme is applied immediately and matches whether the sun is currently above 10° (Review Focus 4). The log names the recorded crossing and the next armed one.
3. Restart with that crossing recorded: nothing is applied and the same next crossing is armed.
4. Toggle the theme by hand through Windows Settings, then restart: G-Helper leaves it alone (step 6 of `Evaluate`).
5. Set `theme_elevation` to a value the sun has already passed today so the previous crossing moves ahead of the recorded one, restart, and confirm the theme is applied and the crossing recorded.
6. Review Focus 1, from Task 3 Step 5: `theme_lat` = `"abc"`, `"91"`, `"30,5052"` — each starts cleanly and reseeds.
7. Sleep the machine, wake it: the resume log line appears and the evaluation reaches the same answer as the timer would.
8. **Watch the taskbar repaint** on an apply. The spec: a failed broadcast looks exactly like a successful registry write.

- [ ] **Step 4: Commit**

```bash
git add app/Theme/ThemeControl.cs app/Program.cs
git commit -m "feat(theme): evaluate the schedule on startup, session, resume and clock change"
```

---

### Task 6: Bindable hotkey

**Files:**
- Modify: `app/Extra.cs:30-54` (the `customActions` dictionary), `app/Input/InputDispatcher.cs:630-726` (the `switch (action)`)

**Interfaces:**
- Consumes: `Program.themeControl.Toggle()` from Task 5.
- Produces: the action key `"theme"`, bindable to M1–M5, the Fn row and the paddle through the existing Extra window dropdowns.

- [ ] **Step 1: Add the dictionary entry**

In `app/Extra.cs`, after `{"visual", Properties.Strings.VisualMode},`, add `{"theme", "Light / Dark Theme"},`. An English literal, deliberately: `Strings.resx` is off limits (Global Constraints), and this becomes a `Properties.Strings` entry only on an upstream PR branch.

- [ ] **Step 2: Add the dispatcher case**

In `app/Input/InputDispatcher.cs`, in the `switch (action)` alongside `case "visual":`, add:

```csharp
case "theme":
    Program.settingsForm.BeginInvoke(() => Program.themeControl.Toggle());
    break;
```

`BeginInvoke` matches how `"visual"`, `"aura"` and `"overlay"` already hop to the UI thread, and keeps the `ThemeApplied` handler added in Task 8 on that thread.

- [ ] **Step 3: Verify by running the app**

Run: `dotnet build app/GHelper.csproj -c Debug` — expected `Build succeeded`.
Then: open the Extra window, confirm "Light / Dark Theme" appears in the M4 dropdown, bind it, press M4, and confirm the theme flips **and the taskbar repaints**. Press it again with the schedule enabled and confirm from the log that no crossing was recorded — a manual toggle must not move `theme_last_crossing`.

- [ ] **Step 4: Commit**

```bash
git add app/Extra.cs app/Input/InputDispatcher.cs
git commit -m "feat(theme): add a bindable theme toggle hotkey action"
```

---

### Task 7: The settings dialog

**Files:**
- Create: `app/ThemeSettings.cs`, `app/ThemeSettings.Designer.cs`, `app/ThemeSettings.resx`

**Interfaces:**
- Consumes: `ThemeConfig`, `ThemeSchedule`, `Program.themeControl`.
- Produces: `namespace GHelper; public partial class ThemeSettings : RForm` with a parameterless constructor. Opened with `Show()` by Task 8.

**Contents**, per the spec:

- A checkbox enabling automatic location-based switching — the feature's on/off switch, and the only place it exists.
- Latitude and longitude text boxes, pre-filled from `ThemeConfig.Site`.
- Elevation threshold, defaulting to 10.
- A read-only label showing today's resolved crossings, so the math is visible without waiting for it to fire.

- [ ] **Step 1: Build the form**

`ThemeSettings.Designer.cs` is a new file, so hand-writing its `InitializeComponent()` is fine; follow `app/Updates.Designer.cs` for the shape. Inherit `RForm` and call `InitTheme()` in the constructor, as the other forms do, so the dialog follows G-Helper's own chrome. Every string in this dialog goes in `app/ThemeSettings.resx` or in the designer — never `Strings.resx`.

Validation on save, using `ThemeConfig.TryParseCoordinate`: latitude −90..90, longitude −180..180, threshold 0..20. On a rejected value, keep the dialog open and mark the offending field; do not persist a partial change.

- [ ] **Step 2: Show the resolved crossings**

A label reading e.g. `Today: light 08:28, dark 18:04` — from `ThemeSchedule.PreviousCrossing`/`NextCrossing` against the values **currently in the boxes**, converted to local time, recomputed as the user edits. When there is no crossing in 24 hours, say so rather than showing an empty line. This is the spec's "the math is visible and verifiable without waiting for it to fire", and it is also how a wrong coordinate gets noticed.

- [ ] **Step 3: Apply on save**

Persist through `ThemeConfig.SetSite` and `ThemeConfig.ScheduleEnabled`, then call `Program.themeControl.Evaluate()` so a change takes effect at once instead of at the next event. Enabling the schedule here must land the correct theme immediately; disabling it must disarm the timer and write nothing further.

- [ ] **Step 4: Verify by running the app**

Run: `dotnet build app/GHelper.csproj -c Debug` — expected `Build succeeded`.
Then, with the dialog opened from the icon (Task 8) or a temporary call site: the pre-filled values match config; the crossing line updates as coordinates change and shows plausible times for a distant latitude; latitude `91`, longitude `181`, threshold `50` and `abc` are each rejected without closing the dialog or writing config; enabling applies the right theme at once; disabling stops the schedule.

- [ ] **Step 5: Commit**

```bash
git add app/ThemeSettings.cs app/ThemeSettings.Designer.cs app/ThemeSettings.resx
git commit -m "feat(theme): add the theme schedule settings dialog"
```

---

### Task 8: The sun/moon icon

**Files:**
- Create: `app/Resources/icons8-moon-32.png`
- Modify: `app/Properties/Resources.resx` (one appended entry), `app/Settings.cs` (the handler block around `app/Settings.cs:297-307`, and `InitVisual` at `app/Settings.cs:381-430`)

**Interfaces:**
- Consumes: `Program.themeControl` (`Toggle`, `NextSwitchLocal`, `ThemeApplied`), `WindowsTheme.IsLight()`, `ThemeSettings` from Task 7.
- Produces: `public void VisualiseTheme()` on `Settings` — sets `pictureGamma.BackgroundImage` and the tooltip from the current theme. Safe to call repeatedly.

- [ ] **Step 1: Add the moon resource**

Source a 32×32 icons8 moon PNG matching the existing set's style and licensing, save it as `app/Resources/icons8-moon-32.png`, and append one `ResXFileRef` entry named `icons8_moon_32` to `app/Properties/Resources.resx`, in the form used at `app/Properties/Resources.resx:124-131`. One appended entry is the whole merge surface here.

- [ ] **Step 2: Wire the icon in `Settings.cs`**

In `InitVisual()`, where `panelGamma` is made visible, call `VisualiseTheme()` and attach:

```csharp
pictureGamma.Cursor = Cursors.Hand;
pictureGamma.MouseUp += PictureGamma_MouseUp;
```

with a handler that toggles on `MouseButtons.Left` (`Program.themeControl.Toggle()`) and opens `ThemeSettings` on `MouseButtons.Right`. Keep a single form instance in a field and reuse it, the way `extraForm` and `updatesForm` are handled, so right-clicking twice does not stack windows.

Subscribe `Program.themeControl.ThemeApplied += VisualiseTheme` so the icon follows a scheduled or hotkey switch, not just a click here.

The image is assigned at runtime, in `Settings.cs`, never in the designer — Global Constraints.

- [ ] **Step 3: Implement `VisualiseTheme()`**

`pictureGamma.BackgroundImage` = `Properties.Resources.icons8_brightness_32` when `WindowsTheme.IsLight()`, the moon otherwise. Tooltip through the designer's existing `toolTip` field (`app/Settings.Designer.cs:2197`), as `app/Settings.cs:1916` already does for `pictureGPU`: name both actions and the next scheduled switch, e.g. `Click: toggle light/dark · Right-click: settings · Next switch 18:04`, dropping the last clause when `NextSwitchLocal` is `null`. English literals, per Global Constraints.

No highlight, no ring, no border. The spec is explicit: the icon changes, nothing else does.

- [ ] **Step 4: Verify by running the app**

Run: `dotnet build app/GHelper.csproj -c Debug` — expected `Build succeeded`.
Then, in the running app: the icon shows a sun in light and a moon in dark; left-click flips the theme **and the taskbar repaints**; the icon updates with it; right-click opens the dialog, twice in a row opens one window; the tooltip names both actions and the next switch; changing the theme from Windows Settings and reopening the G-Helper window shows the icon matching; a scheduled apply updates the icon without a click.

- [ ] **Step 5: Commit**

```bash
git add app/Resources/icons8-moon-32.png app/Properties/Resources.resx app/Settings.cs
git commit -m "feat(theme): show and toggle the theme from the sun/moon icon"
```

---

## Out of scope, recorded

Carried from the spec so they are not rediscovered mid-build:

- **No entry point on machines without `panelGamma`.** `InitVisual` shows that panel only on OLED panels, where gamut modes exist, or where colour profiles can be installed, and never with `hide_visual` set. Elsewhere there is no icon, so no toggle and no way to reach the dialog. The owner's G16 is OLED. This is the one genuine blocker for an upstream PR and is deferred with it.
- **No tray context menu entry.** The owner's muscle memory there is quit/exit.
- **No fixed clock-time scheduling, no camera or IR sensing, no "don't switch while gaming" guard, no separate scopes for chrome and apps.**
- **`ui_mode` is untouched.** If G-Helper's own chrome is pinned light or dark, the icon will sit in a window whose colours contradict it. That is a deliberate choice about a different thing.
