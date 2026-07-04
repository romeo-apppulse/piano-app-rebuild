# PianoApp Rebuild — Handoff & Context

> **Read this first after cloning.** It's the map; `REBUILD.md` is the authoritative
> domain spec and decision log. Together they give a fresh clone the full picture.
> Last updated: 2026-07-04.

---

## TL;DR

A gamified piano-practice tracker for one teacher, running **fully offline on a 12.9″
iPad Pro (iOS 16.7)**. Kids log practice "damage" against **monsters** per **team**;
leaderboards track it. We are doing a clean rebuild of a fragile self-built app.

Three top-level pieces live side by side in this repo:

| Path | What it is | Status |
|---|---|---|
| `PianoAppv2/` + `PianoAppv2.xcodeproj` | The **legacy live app** Rebecca uses today (with emergency patches). Also the **migration data source**. | **Untouched — do not modify.** |
| `PianoCore/` | UI-free **SwiftPM library**: domain model, calc/game engines, persistence, legacy migration. No `@main`, no views. | Foundation + migration **done**, 61 tests green. |
| `PianoApp/` + `PianoApp.xcodeproj` | The **new SwiftUI app** built on PianoCore (the rebuild's UI). | In progress on `experiment/ui-ux`. |

`PianoCore` deliberately sits beside the legacy target (not inside it) so the new
value-type `Student`/`Team`/etc. don't collide with the legacy classes of the same name
during the transition.

---

## Branches & tags

| Ref | Points at | Meaning |
|---|---|---|
| `main` | legacy app + emergency patches | Rebecca's shipped line. |
| `rebuild/pianocore-foundation` | `50b82a4` | PianoCore foundation + HP/leaderboard/miniboss engines + **legacy migration**. |
| `experiment/ui-ux` | latest | **The new UI work** (this is where active development is). |
| tag `ui-baseline` | `ea8c206` | Restore point taken before the UI-phase experiments began. |

The UI branch was intentionally started fresh from the migration-updated core, with **no
edits riding along into the legacy `PianoAppv2` target**.

---

## Build & test

```sh
# 1. The pure logic core (no Xcode needed) — the authoritative pass/fail gate:
cd PianoCore && swift test            # 61 tests across avg/HP/leaderboards/engine/persistence/migration

# 2. The new app (needs Xcode):
open PianoApp.xcodeproj                # scheme: PianoApp
#   or headless:
xcodebuild build -project PianoApp.xcodeproj -scheme PianoApp \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'
```

- **Device class:** the client runs a **12.9″ iPad Pro**; its modern simulator equivalent
  is **iPad Pro 13-inch** (Apple renamed 12.9″ → 13″ in the M4 generation).
- **OS gap:** installed simulator runtimes here are iOS 18.6 / 26.x, **not 16.7**. Fine for
  UI dev (deployment target is 16.6); the true 16.7 pass needs the real device or a
  downloaded iOS 16 runtime (see roadmap).

### Exercising migration in the simulator (DEBUG only)
The teacher admin has a **DEBUG-only** bar: **Seed legacy** writes fixture legacy JSON into
*this build's own sandbox* and re-runs the real migration; **Reset** wipes to empty. It
**never touches real data** and is compiled out of release. See `PianoApp/Debug/`.

---

## What's built in the UI phase (`experiment/ui-ux`)

| Commit | Delivered |
|---|---|
| `ecaa614` | PianoApp app target + local PianoCore dependency; **GameStore** (mutations → `GameEngine`, atomic save, `saveError`); first-launch migration wiring; skeleton root. |
| `6af70f0` | Teacher admin **`NavigationSplitView`**: Roster, Teams, Monster Catalog, Lineup, Daily Averages, Backdoor Controls, Backup. |
| `1097c92` | Review fixes: catalog multi-delete index safety, restore confirmation gate, orphan-lineup cleanup, lineup stale-copy resync. |
| `4fee5e8` | Immersive **battle view**: team selector, monster + HP bar, current/past boards, combat log, big-target attack flow, **congrats moment**, miniboss takeover; admin moved behind a gear gate. |

---

## Architecture invariants (keep these true)

- **The combat log is the single source of truth.** HP, all three leaderboards, undo, and
  daily averages are *derived*, never stored.
- **Gameplay mutations go through the typed `GameEngine` methods only** (attack, adjustHP,
  setKillTarget, autokill, setLineup, spawn, undo). `GameStore.apply(_:)` is reserved
  **strictly** for roster/team/catalog CRUD the engine doesn't own.
- **Persistence is one atomic document** (`appState.json` + rolling `.bak1/.bak2`).
- **No force-unwraps / force-index in app code.**
- Key product decisions (overkill carryover, tie ranking, most-recent-only editing,
  miniboss flow, and **#10 the ship bundle-ID**) are in `REBUILD.md §3`.

---

## Remaining roadmap

1. **XCUITest harness** for PianoApp — seed through PianoCore state (no production-data
   paths); headline coverage is **attack → kill → congrats → undo** end-to-end.
2. **Image picker** for monster art (catalog references images by filename today).
3. **On-device migration rehearsal** with a copy of Rebecca's real data — the
   highest-ceremony step; treat carefully before any ship talk.

**Ship note (locked):** for migration to see the legacy files in production, PianoApp must
ultimately ship under the legacy bundle id **`Becca.PianoAppv2`** (same sandbox). During dev
it uses a separate id (`Becca.PianoApp`) so both coexist. See `REBUILD.md` decision #10.
