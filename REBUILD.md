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
| 2 | HP behavior | **Freeze inputs at spawn** — each monster stores `spawnAverages`; HP recomputes only when the kill-target changes (or via the backdoor delta). Prevents the moving-target bug and stops the sliding window corrupting past monsters. Manual-to-auto transition confirmed: manual first-monster HP (`legacyFixedHP`), engine takes over as real practice accrues. |
| 3 | Daily-average window | **Rolling 90 days** (literal last-90-days, not calendar months), as the single constant `AverageWindow.windowDays`. Inclusive lower bound. |
| 4 | Undo model | **One unified action history.** Teacher admin actions (HP adjust, autokill, miniboss spawn) are undoable actions, not just attacks. |
| 5 | Overkill damage | **CARRIES OVER** (client reversed the earlier default 2026-06-26) — the killing entry is capped at the dying monster's remaining HP; the leftover rolls onto the freshly spawned successor as its own entry, chaining if it kills the successor too. The whole chain is ONE action; a single undo reverses all of it (entries, spawns, defeats, lock-ins). Leftover with no successor is discarded. |
| 6 | Day-one seeding | Built as a flippable flag `seedLeaderboardsFromLegacyScore`; migration seeds are excluded from average math. |
| 7 | All-time membership | **Active students only** (removed students keep history but are hidden). Client hasn't decided vs hall-of-fame — keep this default. |
| 8 | Leaderboard ties | **Tied students share the placement; next distinct total gets the NEXT number** (her example: two tied at 439 are both 1st, next student is 2nd — 1-1-2). Applied to all three boards. ⚠️ Her verbal formula ("1 + number strictly ahead") contradicts her example (would give 1-1-3); built to the example. `Leaderboards.ranked` is the one place to change. |
| 9 | Entry editing | **Only the single most recent entry is editable/deletable**; older entries lock. Deletion is top-down only = LIFO undo. `deleteMostRecentEntry` IS `undoLast` (one code path, can never diverge); `editMostRecentAttack` = undo + re-apply at the original timestamp so kill/carryover consequences recompute exactly. Structurally enforced: `CombatLogEntry` fields are `let`, `CombatLog.entries` is private(set), only mutators are append + remove-by-id. |
| 10 | **New-app bundle identifier (ship decision, LOCKED)** | Migration reads the OLD app's Documents files, so it only works if the rebuilt **PianoApp ships under PianoAppv2's bundle id (`Becca.PianoAppv2`)** — same app sandbox → legacy files present. Until release the rebuild uses a **separate** id (`Becca.PianoApp`) so both apps coexist on the dev iPad; a **DEBUG-only** exerciser (`GameStore.debugSeedFromSampleLegacyData`) writes fixture legacy JSON into the *dev* sandbox to test migration **without ever touching Rebecca's real data**. At release, PianoApp assumes the `Becca.PianoAppv2` id and retires the legacy target. |

### Miniboss flow (client spec 2026-06-26 — model approved by user, **BUILT**)
- Minibosses sit **in the regular monster lineup** — a team encounters one as the next
  monster in their sequence.
- **Auto-triggered** by the FIRST team to reach it (by defeating the monster before it);
  NOT started manually by the teacher.
- At trigger, **ALL teams pause** their current battles; each team's in-progress state
  (monster, remaining HP, current-monster leaderboard) must be frozen and preserved.
- Everyone fights the miniboss together. Miniboss HP = Σ(ALL students' daily averages) ×
  miniboss kill-target (default 6, configurable), **inputs frozen at trigger time**.
- On miniboss defeat, every team **resumes exactly** the battle they were paused on —
  unless the teacher edited the lineup during the pause.
- **Lineup editing during the pause is an intended feature** (inventory management,
  catch-up for lagging teams): delete/add monsters, adjust what a team will face next;
  teams resume per the updated lineup.
- The defeated miniboss gets its **own past-leaderboard slot**, distinct from the per-team
  past-monster boards.

**Boundary rule (user default, 2026-06-26): overkill does NOT cross the miniboss
boundary in either direction** — no carry into a triggered miniboss, no carry out of a
defeated one; the leftover is discarded.

### Still OPEN (pending client) — not blocking
- All-time hall-of-fame vs active-only (decision 7 above).
- Whether lowering the kill-target below current damage should auto-defeat (current
  behavior: does **not** auto-defeat; remainingHP clamps to 0).

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
6. ✅ **UI phase** — PianoApp target on PianoCore: GameStore (typed engine bridge,
   atomic persist, first-launch migration), teacher admin (NavigationSplitView: roster/
   teams/catalog/lineup/averages/backdoor/backup), immersive battle view (attack flow,
   HP bar, boards incl. past-miniboss slot, combat log, undo, congrats overlay,
   miniboss takeover). Reviewed by the Windows session; fixes applied.
   **XCUITest harness authored** (`PianoApp/Testing/UITestSupport.swift` fixtures +
   `PianoAppUITests/BattleFlowUITests.swift`): attack→HP/log, kill→congrats→spawn→undo,
   miniboss trigger→takeover→undo, overkill carryover — all seeded through PianoCore
   state in a temp sandbox via `-uiTestFixture`; no production-data paths.
   ⚠️ Mac must create the "PianoAppUITests" UI Testing Bundle target in Xcode (target
   under test = PianoApp), attach BattleFlowUITests.swift, and run. Remaining UI: image
   picker for monster art.
7. ✅ **Data migration** — `LegacyLoader` (tolerant per-element parsing of the legacy
   files) + pure `Migration.migrate` (id reuse, name-join with collision/orphan
   flagging, `legacyFixedHP` pinning, optional `.migration` seeding, drift check,
   `MigrationReport`). Tests in `MigrationTests`. First-launch wiring lands with
   GameStore in the app target.
8. ◐ **On-device test pass.** Ran on iOS 18.6 simulators (no iOS 16.7 runtime on Xcode
   26.4; the two physical devices are on iOS 26.x and offline): PianoCore 64 ✅ ·
   PianoAppTests 5/5 ✅ · XCUITests **4/4 on BOTH iPhone and iPad** ✅ · build ✅. This
   surfaced and fixed a universal-app layout bug (see "Device test pass" below). ⬜ Still
   pending: the pass on a real **iOS 16.7** device (the deployment-target floor), which
   isn't available here.

Plus: ✅ persistence layer (atomic JSON + backups) written + tested.

**~33 unit tests** across daily-average, HP, leaderboards, game engine, persistence — all
pure/injectable. Verified by adversarial review (compile + logic + test-assertion lenses);
the **real green light is `swift test` on the Mac** (no Swift toolchain on the Windows dev
box).

### 🏁 FEATURE-COMPLETE (2026-07-09, `aec04a2`)
Every client-requested feature and fix is implemented and gate-verified against origin:
xcodebuild ✅ · PianoCore 64 ✅ · PianoAppTests 5/5 ✅ · XCUITests 4/4 ✅ (iPad-only run —
an iPhone run later found a layout bug; see "Device test pass" below).
Remaining before ship: (1) five quick visual tap-throughs next iPad-in-hand session
(all-time markers, fix-last-entry, miniboss admin section, settings persistence,
picker cancel); (2) the migration rehearsal (docs/MIGRATION-REHEARSAL.md, Phases 1–5);
(3) client sign-offs: seeding on/off + hall-of-fame vs active-only; (4) ship-day
bundle-id flip (decision #10).

### Device test pass (2026-07-09, iOS 18.6 sim) — iPhone battle-layout bug found & fixed
The "XCUITests 4/4 ✅" above was an **iPad-only** run. Running the same suite on an
**iPhone** (18.6 sim) surfaced a real universal-app bug (`TARGETED_DEVICE_FAMILY = "1,2"`):
`BattleScreen`'s fixed two-column layout (flexible battle column + hard-coded 400pt boards
column) overflows iPhone-portrait width, pushing the battle column — including the **Undo**
button — off the left edge, untappable. Confirmed three ways: the XCUITest negative-x
failure on iPhone, the same two tests passing on iPad, and a screenshot.
Fix: `BattleScreen` is now **size-class adaptive** — two side-by-side columns on regular
width (iPad/landscape, unchanged), boards stacked beneath the battle column in a scroll
view on compact width (iPhone portrait). XCUITests now **4/4 on both iPhone and iPad**.
Testing note: always run `PianoAppUITests` on BOTH form factors — the layout is size-class
dependent, so an iPad-only pass hides iPhone regressions.

### Spec-compliance audit (2026-07-09) — four gaps found, ALL FIXED
Full audit of the built system against every client ask. Everything else verified
present; these were missing and are now implemented:
1. **All-time top-5 distinction** — board now gives 1st–5th placement markers (🥇🥈🥉/4th/5th);
   ranks 6+ listed plainly with no marker (spec: "without distinction").
2. **Edit-most-recent-entry UI** — "Fix the last entry" section in Backdoor Controls
   (per-team; global during a miniboss): shows the entry, edit amount (engine
   undo+re-apply), delete (same op as Undo, confirm-gated). Backed by a new engine
   query `GameEngine.mostRecentAttack(in:teamScope:)` so the UI can never disagree
   with what undo/edit will touch. **Engine guard added:** editing a paused team's
   entry mid-miniboss refuses (`minibossActive`) instead of silently deleting (the
   re-apply would have hit the pause gate after the undo); editing the trigger
   attack itself remains legal. Tested.
3. **Miniboss admin reachability** — Backdoor Controls now shows an Active Miniboss
   section (stats, HP ±, kill-target, "End miniboss early" = autokill, confirm-gated);
   previously an alive miniboss was unreachable (team-picker-only UI). Paused team
   monsters remain HP/kill-target-editable with an explanatory note.
4. **Game Settings admin section** — defaults for regular/miniboss kill-targets
   (spec: "configurable"), minimum monster HP, and the migration seeding flag.
   Defaults apply to future spawns only (alive monsters froze theirs at spawn).

### CURRENT STATE (2026-06-26)
`swift test` **passed on the Mac** for the foundation + items 2–5. Migration (step 7) is
now built too — the Mac `swift test` run is the gate for it (new `MigrationTests`).
Remaining: GameStore + UI (step 6, in a NEW app target depending on PianoCore — see
below), first-launch migration wiring, on-device pass.

**UI phase decision (2026-06-26):** UI/UX work lands in a **fresh SwiftUI app target
that depends on PianoCore**, on a feature branch — NOT in the legacy `PianoAppv2/`
target, which stays untouched (it's Rebecca's live app and the migration data source;
its views are welded to the legacy name-keyed classes and will be retired after
migration is proven).

### Miniboss implementation (approved model, as built)
1. **No snapshot machinery.** All battle state (remaining HP, boards) is DERIVED from the
   log, so pausing stores nothing: while a miniboss is alive, `attack()`/`autokill()`
   reject any other target (`EngineError.minibossActive`). `state.aliveMiniboss != nil`
   IS the pause flag; resume = the gate lifts. `adjustHP`/`setKillTarget` on paused
   monsters stay allowed (no spawn risk, undoable).
2. **Lineup as data**: `AppState.lineup: [LineupSlot]` (slot = own UUID + templateID;
   shared by all teams) + per-team `Team.nextLineupIndex` (read modulo count, edit-safe).
   Empty lineup falls back to the legacy cyclic-next-template rule. `GameEngine.setLineup`
   replaces the whole array — undoable (global scope), validated against the catalog,
   allowed mid-miniboss (the client's catch-up window).
3. **Trigger inside resolveDefeat**: a team's defeat whose next unspent lineup slot is a
   miniboss spawns the GLOBAL miniboss (teamID nil, `triggeredByTeamID` set, ALL students'
   averages frozen at trigger, miniboss kill-target) as that kill's DefeatOutcome
   successor. The pointer is deliberately NOT advanced — the slot is consumed by the
   **spent rule** (a slot is spent iff a MonsterRecord carries its `lineupSlotID`), so
   undoing the trigger deletes the record and un-spends the slot with zero pointer surgery.
4. **Resume on miniboss defeat**: the triggering team gets its next regular monster from
   the (possibly edited) lineup — spent miniboss slots are skipped — as the miniboss's
   DefeatOutcome successor (its pointer move is recorded in `TeamPointerChange` and
   restored on undo). Other teams just become attackable again, exactly where they were.
5. **Past-miniboss board**: `Leaderboards.pastMiniboss(state:)` — most-recently-defeated
   miniboss record's frozen finalLeaderboard. Zero new storage.
6. **Boundaries**: no overkill carry into or out of a miniboss (leftover discarded).
   `MinibossSpawnAction` was removed — minibosses only enter via lineup auto-trigger.

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
