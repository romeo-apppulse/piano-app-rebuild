# PianoAppv2 — Rebuild Spec, Decisions & Status

> Single source of truth for the rebuild. A paid-client project: a clean, well-architected
> rebuild of an offline SwiftUI iPad app after earlier emergency bug-fix patches.
> Last updated: **2026-06-26**.

---

## 1. What the app is

A gamified piano-practice tracker for a piano teacher. Students log practice "damage"
against **monsters** in **teams**; **leaderboards** track damage. Runs **fully offline on
one 12.9" iPad Pro, iOS 16.7**. Kids aged 5–16 → big bold buttons. **No visual redesign in
scope** — functional and clean only.

Repo: `github.com/romeo-apppulse/piano-app-rebuild`. The old (fragile, self-built) app and
the rebuild live in the same repo. Earlier we shipped emergency patches (atomic writes,
crash guards, corrupt-team recovery, rolling backups, export/restore) — those are on
`origin/main`. This rebuild replaces the fragile foundation properly.

---

## 2. The client spec (authoritative)

### Foundation principle
The **COMBAT LOG is the single source of truth.** Every attack is one entry: who, how much
damage, what date, which monster. Daily averages, HP, all three leaderboards, and undo are
all **computed from the log**. Do not scatter state.

### HP engine
- **Daily average** per student = (sum of their damage in the window) ÷ (number of
  **distinct days** they logged in the window). Multiple entries on the same date = **one
  day**. Window = **rolling 90 days** (see decisions). Worked example: 15 & 6 on 1/5 plus 25
  on 3/12 = 46 over 2 days = **23**. Zero days → 0 (no divide-by-zero).
- **Regular monster HP** = ceil( Σ(team members' daily averages) × **kill-target weeks**,
  default 3 ). Auto-spawns, no manual input. Example: 20.5+13+8.25 = 41.75 × 3 = 125.25 →
  **126**.
- **Miniboss HP** = same but Σ over **all** students × a higher kill-target (default **6**).
- Isolate the daily-average and HP formulas each in **one** well-named function (client may
  refine "daily average"). HP must be **recalculable from stored inputs**, not stored as a
  final number (kill-target is configurable mid-battle).
- Edge cases to test: brand-new student (0/1 entry), non-adjacent same-day entries, entry
  exactly at the window boundary.

### Backdoor controls (teacher admin, in settings) — build all three
1. Add/subtract the current monster's HP **without** a combat-log entry.
2. Change kill-target weeks mid-battle and **auto-recalculate** HP.
3. **Autokill**: end the current monster, spawn the next, lock in the current leaderboard as
   the past-monster leaderboard.

### Combat log display
`"[name] does [amount] dmg to the monster!"`, most recent first; students can log multiple
times/day and interleave on the same date.

### Undo
Delete the **most recent** combat-log entry and update HP. If that entry **killed** a
monster, undo must reverse the kill, the spawn, and the leaderboard lock-in.

### Three distinct leaderboards
1. **Current-monster** — damage vs the current monster only; resets each new monster.
2. **Past-monster** — frozen snapshot of the immediately previous monster; **top 3 only**;
   keep **only one** monster back.
3. **All-time** — cumulative damage per student since added; **top 5** get 1st–5th
   distinctions, others listed plainly. One gesture to access; a scrollview is fine.

### Two monster types
Regular (a team) and miniboss (all students, higher HP). The old code had a `MiniBoss`
class that was written but **never used** — build the miniboss flow properly.

### Congrats moment
Kid-friendly celebration when a monster dies (confetti / "YOU WON!" fade) so students see
the defeat before the next spawn. Client flexible on form.

### Other
- Each student's daily average viewable on a settings page (replaces a separate
  practice-tracking feature; how the teacher tracks trends).
- **Preserve/migrate her existing live data** — real students, teams, combat history. She
  cannot lose data.

### Dev-imposed constraints
Stable IDs (not name strings); clean value-type models; observable data layer with atomic
writes + backups; **no force-unwraps**; real unit tests, especially the calc logic.

---

## 3. Decisions locked with the client

| # | Decision | Choice |
|---|---|---|
| 1 | Monster scope | **Per-team, concurrent** — each team fights its own monster. Leaderboards + undo are team-scoped. |
| 2 | HP behavior | **Freeze inputs at spawn** — each monster stores `spawnAverages`; HP recomputes only when the kill-target changes (or via the backdoor delta). Prevents the moving-target bug and stops the sliding window corrupting past monsters. |
| 3 | Daily-average window | **Rolling 90 days** (literal last-90-days, not calendar months), as the single constant `AverageWindow.windowDays`. Inclusive lower bound. |
| 4 | Undo model | **One unified action history.** Teacher admin actions (HP adjust, autokill, miniboss spawn) are undoable actions, not just attacks. |
| 5 | Overkill damage | **Discarded** — the killing student is credited their full hit; the successor spawns fresh at full HP. |
| 6 | Day-one seeding | Built as a flippable flag `seedLeaderboardsFromLegacyScore`; migration seeds are excluded from average math. |
| 7 | All-time membership | **Active students only** (removed students keep history but are hidden). ⚠️ flagged — confirm vs hall-of-fame. |

### Still OPEN (pending client) — not blocking
- **Miniboss targeting flow**: coexist-and-pick-target vs pause-team-monsters. The engine
  takes an explicit target id so nothing is blocked; the miniboss *lifecycle* is a marked
  TODO (the `.spawnMiniboss` action + `MinibossSpawnAction` exist but are inert until this
  is decided).
- All-time hall-of-fame vs active-only (item 7 above).
- Exact rounding confirmations, tie-handling beyond top-N, whether the teacher needs to
  edit/backdate older entries, and whether lowering the kill-target below current damage
  should auto-defeat (current behavior: does **not** auto-defeat; remainingHP clamps to 0).

---

## 4. Architecture

- **`PianoCore/`** — a UI-free, cross-platform SwiftPM module holding the domain model, the
  calc engine, the game engine, and persistence. Pure Foundation (no SwiftUI/Combine) so it
  builds and unit-tests anywhere with `swift test`. Kept separate from the old Xcode target
  so the new value types don't collide with the legacy classes during transition.
- **Persistence**: hand-rolled Codable JSON, **one atomic document** `appState.json` +
  rolling `.bak1/.bak2`. NOT SwiftData (needs iOS 17). Chosen over Core Data because a single
  whole-state atomic write gives consistency for free and fixes the old torn-multi-file-write
  bug (the real cause of the "won't load, re-download" symptom). UUID foreign keys give
  referential integrity without an object graph.
- **`GameStore`** (not built yet) — a thin `@MainActor ObservableObject` in the **app
  target** (needs Combine) wrapping the engine + persistence and publishing to SwiftUI.

### Key types (in `PianoCore/Sources/PianoCore/`)
- `Student`, `Team` (value types, stable UUIDs; `Student.teamID` FK, `createdAt`, `isActive`).
- `MonsterTemplate` (deck art/name), `MonsterRecord` (one spawned instance: frozen
  `spawnAverages`, mutable `killTargetWeeks` + `backdoorHPDelta`, `legacyFixedHP`,
  `defeatedAt`/`finalLeaderboard`), `MonsterKind`, `StudentAverage`, `LeaderboardSnapshotRow`.
- `CombatLogEntry` (dual `timestamp` for day-bucketing + monotonic `sequence` for
  ordering/undo), `EntryOrigin` (`live`/`migration`), `CombatLog`.
- `GameAction` (unified undo history: `attack`/`adjustHP`/`setKillTarget`/`autokill`/
  `spawnMiniboss`), `DefeatOutcome`, the per-action payloads.
- `GameSettings` (kill targets, min HP, timezone, seeding flag; forward-compatible decoder).
- `AppState` (the single serialized root + derived helpers: `damageDealt`, `effectiveHP`,
  `remainingHP`, `nextSpawnSequence`, lookups).
- Calc: `AverageWindow` (the 90-day constant), `PracticeMath.dailyAverage`,
  `MonsterMath.baseHP/effectiveHP`, `Leaderboards` (dense ranking + the three boards).
- `GameEngine` (spawn / attack / defeat / 3 backdoor controls / unified team-scoped undo).
- `JSONFilePersistence` (atomic single-file save/load + backup rotation).

---

## 5. Build order & status

1. ✅ **Foundation model + combat log** — done, adversarially verified.
2. ✅ **HP engine** (90-day average, monster HP) + priority tests — done, verified.
3. ✅ **Leaderboards** — done, verified.
4. ✅ **Spawn/defeat + backdoor controls** (+ miniboss HP; lifecycle deferred) — done, verified.
5. ✅ **Undo** (incl. kill reversal, team-scoped) — done, verified.
6. ⬜ **Congrats moment + settings views** — not started.
7. ⬜ **Data migration** — NEXT once the foundation is green on the Mac.
8. ⬜ **Full on-device iOS 16.7 test pass.**

Plus: ✅ persistence layer (atomic JSON + backups) written + tested.

**~33 unit tests** across daily-average, HP, leaderboards, game engine, persistence — all
pure/injectable. Verified by adversarial review (compile + logic + test-assertion lenses);
the **real green light is `swift test` on the Mac** (no Swift toolchain on the Windows dev
box).

### ⏸ CURRENT HOLD (2026-06-26)
User is running `swift test` in `PianoCore/` on the Mac to confirm the foundation compiles
and passes. **When it's green → build migration (step 7).** If failures, fix them first.

---

## 6. Migration plan (step 7)

### Legacy on-disk source (the OLD app's Documents files)
- `monsterDeck.json` — array of `StandardMonster {name, img, artist, damage}`; **no id**
  (identity = name).
- `teamDeck.json` — array of `Team {id?, name, minHP, maxHP}`.
- `battleDeck.json` — array of `Codable_Battle {id, monsterName, teamName, hp, dmg}`
  (references by **name**).
- `students.json` — array of `Student {id, name, teamName, score}` (`score` is
  per-current-monster, **reset to 0 on every kill**).
- `MiniBoss.json` — a **single object** (not an array); **not** in `DataStore.dataFileNames`
  so the export/restore path drops it → must read raw Documents, not an app export.

### THE critical constraint
There is **no dated per-attack history** in the legacy data — only cumulative scalars with
no timestamps. So the new combat log starts empty: daily averages = 0, auto-spawned HP floors
near minimum for weeks, and true all-time totals are unrecoverable. **A day-one bootstrap is
required** (see decisions 5–6).

### Mapping
- **Teams** → reuse existing `id`, keep name, drop minHP/maxHP. Build `name→Team.ID` map.
- **Students** → reuse `id`, resolve `teamName`→`teamID`, `createdAt = now`, `isActive = true`.
  Orphaned `teamName` (no match) → `teamID = nil` + migration-report flag.
- **Monster templates** → mint UUIDs (legacy has none), carry name/img/artist, `kind:
  .regular`. `MiniBoss.json` → a `kind: .miniboss` template.
- **In-flight monster per battle** → one alive `MonsterRecord` with `legacyFixedHP =
  battle.hp` so the HP bar matches day one; `spawnAverages = []`.
- **Standings** → one `origin: .migration` seed entry per student (`amount = score`) when the
  seeding flag is on; feeds leaderboards, excluded from averages.
- **Name collisions / renames** → flag in a migration report, never silently attach to a
  placeholder (kills the old `?? StandardMonster()` resurrection bug).

### Cannot be reconstructed (document for client)
Dated history / true daily averages; true all-time totals (legacy score was reset per kill);
past-monster boards (never existed). All-time starts fresh, optionally seeded.

---

## 7. How to build & test

```sh
# The pure logic core (no Xcode needed):
cd PianoAppv2/PianoCore
swift test
```
On Windows there is no Swift toolchain, so the core is written carefully + adversarially
reviewed; the Mac `swift test` is authoritative. The iOS app target will depend on
`PianoCore` (as a local Swift package or an added group) and add the `GameStore`, the SwiftUI
views, and the migration wiring on top.

---

## 8. Working agreement / notes
- Don't force-unwrap in app code (tests may).
- Keep the daily-average and HP formulas each in one isolated function — the client may
  refine "daily average".
- Ask before expensive-to-reverse assumptions.
- Adversarially verify new logic (no compiler on the dev box) before calling it done.
