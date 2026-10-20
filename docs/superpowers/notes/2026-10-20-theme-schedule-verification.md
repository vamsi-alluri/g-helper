# Theme schedule — outstanding verification

Written 2026-10-20, ~01:00 local, before the laptop was shut down for the night.
The feature is merged to `main` (PR #4), released as `v0.288.26`, and documented in
[`docs/README.fork.md`](../../README.fork.md). What follows is the one scenario
that was never exercised during implementation, and how to tell whether it worked.

## State at shutdown

| | |
| --- | --- |
| Desktop theme | **dark** (`AppsUseLightTheme` and `SystemUsesLightTheme` both `0`) |
| `theme_schedule` | `1` (enabled) |
| `theme_last_crossing` | `2026-10-19T23:03:35Z` — the evening dark crossing, 18:03 local |
| Site | 30.5052, −97.8203, elevation 10° |
| `m4` | `theme` |
| Armed for | `2026-10-20 08:29:11` local |

## What should happen on the next cold boot

The laptop is off across the 08:29 light crossing, so that crossing is **missed**
rather than fired by the timer. This is the path that matters: the schedule has to
notice on startup that a crossing happened while the machine was down.

Booting after 10:30 local, `Evaluate()` should find the previous crossing
(2026-10-20 ~08:29 local) newer than the recorded one (2026-10-19 18:03 local),
apply **light**, and arm the evening crossing at roughly 18:02 local.

Expect in `%APPDATA%\GHelper\log.txt`:

```
Theme: schedule is enabled
Theme: crossing is newer than the recorded 2026-10-19T23:03:35.0000000Z, applied light, recorded crossing 2026-10-20T13:29:…Z
Theme: applied light, broadcast acknowledged
Theme: armed for the next crossing at 2026-10-20 18:0…:… local
```

The desktop should go dark → light a moment after G-Helper starts. The registry
write is immediate; the `WM_SETTINGCHANGE` broadcast that makes the shell repaint
takes 1.5–5 s, so a short delay before the taskbar follows is expected, not a fault.

### What would indicate a problem

- `no unapplied crossing … leaving the theme alone` — the missed crossing was not
  detected. That is the bug this scenario exists to catch.
- `recorded crossing … is in the future, discarding it` — only correct if the clock
  actually moved; otherwise the recorded value is wrong.
- No `Theme:` lines at all — `Init()` did not run.
- Theme applied but no `broadcast acknowledged` — the write landed and the shell did
  not repaint; log out and back in to confirm the registry is right.

## Still unverified after this

**Sleep / wake.** Never run. Suspending the machine would have ended the session that
implemented the feature. A cold boot exercises `Evaluate()` with the same inputs and
reaches the same answer, but it does *not* exercise the resume path
(`PowerModes.Resume` → `Evaluate()`), and that path is the one the thread-marshalling
fix in `f2a26ae5` targets: `Evaluate()` used to drive a UI-thread `System.Windows.Forms.Timer`
from the `SystemEvents` thread. To test it, sleep the machine across a crossing and
wake it — the same log lines above should appear on wake.

## Release

**`v0.288.26` is published and installed**, built through the **Release (fork)**
workflow and picked up by auto-update from `0.288.14`. It contains every code commit
of this feature, up to and including `579bab12`.

The commits after it are documentation only — the design docs, the ignore rules and
this note — so they change nothing in the binary and need no rebuild. The next
release is only required when code changes again, at which point derive the version
with `bash .github/scripts/fork-version.sh upstream/main` rather than reusing a
number from this file.

Note that merging to `main` never builds a release on its own: `release.yml` is gated
to `seerge/g-helper`, and `sync-upstream.yml` only tags when upstream is ahead. The
**Release (fork)** workflow has to be dispatched by hand, with `ref: main`.
