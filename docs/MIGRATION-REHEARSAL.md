# Migration Rehearsal & Ship Runbook — Rebecca's Real Data

> The highest-ceremony step of the rebuild. Rebecca's data exists in exactly one place —
> the legacy app's sandbox on her iPad — and it cannot be lost. Nothing in this procedure
> ever mutates the original: every step operates on **copies**, and every step has a
> rollback. Do not improvise around this document; if a step fails, stop and reassess.

**Prime rules**

1. **Never run any tool against the live sandbox.** Copies only.
2. **Capture the raw Documents folder, not the in-app export.** The export blob never
   included `MiniBoss.json` (it isn't in `DataStore.dataFileNames`).
3. Every phase below ends with a **verifiable checkpoint**. Don't proceed past a failed one.

---

## Phase 1 — Capture (on the Mac, iPad connected)

1. Xcode → **Window ▸ Devices and Simulators** → select the iPad → under *Installed Apps*
   select **PianoAppv2** → ⚙︎ → **Download Container…** → save the `.xcappdata`.
   (Works because the legacy app is a development install.)
2. Right-click the `.xcappdata` → *Show Package Contents* → copy
   `AppData/Documents/` to a working folder, e.g. `~/piano-rehearsal/capture-YYYY-MM-DD/`.
3. Expected files (some may legitimately be absent):
   `monsterDeck.json`, `teamDeck.json`, `battleDeck.json`, `students.json`,
   `MiniBoss.json`, any `.bak1/.bak2` rotations, and the monster image files.
4. **Zip the whole capture** and store it in TWO places (e.g. the Mac + iCloud/Drive).
   This zip is the permanent pre-migration archive and the ultimate rollback.

**Checkpoint 1:** the four deck JSONs open as valid JSON; counts eyeballed against what
Rebecca sees in the app (roughly N students, M teams). Archive exists in two places.

---

## Phase 2 — Off-device dry run (no device, no risk)

Run the real migration code against a **copy** of the capture, via the gated test in
PianoCore (`RealDataRehearsalTests` — it is skipped unless the env var is set):

```sh
cd PianoCore
PIANO_REHEARSAL_DIR="$HOME/piano-rehearsal/capture-YYYY-MM-DD" swift test \
  --filter RealDataRehearsalTests 2>&1 | tee ../docs/rehearsal-output.txt
```

The test: loads the legacy files exactly as first launch will → runs `Migration.migrate`
→ asserts structural invariants (nothing dropped without a warning; persistence
round-trips) → **prints the full MigrationReport and a human-readable summary** (teams,
students + team links, battles with HP/damage, seeds). It writes only to a temp dir.

**Checkpoint 2:** test passes; the printed summary matches reality (right students on the
right teams, HP bars plausible); every warning in the report is understood.

---

## Phase 3 — Client review (with Rebecca)

Walk the dry-run report with her:

1. **Warnings** — orphaned students, duplicate team/monster names, drift between student
   scores and battle totals. If names collide: fix them **in the legacy app** (rename),
   then **re-capture (Phase 1) and re-run (Phase 2)**. Never hand-edit the captured JSON.
2. **Seeding decision (decision #6, needs her final word):** seed the boards from current
   scores (`seedLeaderboardsFromLegacyScore = true`, the default) or start blank. Explain:
   seeds show on the leaderboards immediately but do NOT count toward daily averages, so
   the first natively-spawned monsters will have low HP until ~2 weeks of real practice
   accrues (manual first-monster HP covers the gap — decision #2).
3. Set expectations in writing: **daily averages start at 0** (no dated history exists),
   the **all-time board starts at the rebuild** (old scores were reset on every kill), and
   past-monster boards begin empty.

**Checkpoint 3:** zero unexplained warnings; seeding flag decided; expectations agreed.

---

## Phase 4 — On-device rehearsal (dev build, dev bundle id)

Still zero risk to the live app — PianoApp runs under `Becca.PianoApp`, its own sandbox.

1. Install PianoApp (dev) on the iPad. Launch once, confirm the empty state, delete
   nothing — then upload the captured legacy files into **PianoApp's** container:
   Devices & Simulators → PianoApp → ⚙︎ → *Replace Container…* with a container whose
   `AppData/Documents/` holds a **copy** of the capture (no `appState.json` present).
2. Launch PianoApp. First-launch migration runs for real. Verify:
   - The migration report screen matches the Phase-2 dry run (same counts, same warnings).
   - Side-by-side with the legacy app: same students/teams; each team's monster + HP bar
     matches; boards look right.
3. Lesson-shaped smoke test on the migrated data: attack → undo; backdoor HP ±;
   kill-target change; Backup → **Export** succeeds.
4. Relaunch the app: state persists; migration does NOT re-run (appState.json exists).

**Checkpoint 4:** report identical to dry run; side-by-side matches; smoke test clean;
relaunch idempotent.

---

## Phase 5 — Ship day (the only phase that touches the real sandbox — additively)

Precondition: Phases 1–4 all green **on a capture taken within the last few days**, and
the Phase-1 zip archive is verified restorable.

1. **Fresh capture first** (repeat Phase 1 on ship day — the archive must reflect the
   latest data). Re-run Phase 2 against it. Any new warnings → stop.
2. Archive the legacy app build (keep the last known-good `.xcarchive`/IPA of PianoAppv2 —
   this is the reinstall path if anything goes wrong).
3. Flip PianoApp's bundle identifier to **`Becca.PianoAppv2`** (decision #10), bump the
   build number above the legacy app's, archive, and install onto the iPad **as an update**
   (Xcode run / TestFlight). iOS preserves the Documents directory across the update, so
   the legacy JSONs are in place when the new app first launches.
4. First launch: migration runs against the real files (read-only — legacy files are never
   deleted or modified; `appState.json` is written beside them). Verify the report matches
   the ship-day dry run.
5. **Immediately export a backup** from the new app (Backup → Export → save to iCloud
   Drive). Now three recovery layers exist: the untouched legacy JSONs in the sandbox, the
   Phase-1 zip, and the new-format export.
6. Hand the iPad back with a 10-minute walkthrough: attack flow, undo, admin gear,
   backdoor controls, backup habit (weekly export).

**Rollback at any point:** reinstall the archived legacy build over the app (same bundle
id) — its Documents (including all original JSONs, untouched) are still there; or restore
the Phase-1 zip via Replace Container. Data loss requires *every* layer to fail.

---

## Who does what

| Phase | Machine | Notes |
|---|---|---|
| 1 Capture | Mac + iPad | Xcode container download |
| 2 Dry run | Mac | `PIANO_REHEARSAL_DIR=… swift test --filter RealDataRehearsalTests` |
| 3 Client review | Human + either session | report walk-through; decisions recorded in REBUILD.md |
| 4 Device rehearsal | Mac + iPad | dev bundle id; Replace Container with a copy |
| 5 Ship | Mac + iPad | fresh capture → bundle-id flip → update install → verify → export |
