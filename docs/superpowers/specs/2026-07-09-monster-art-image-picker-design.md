# Monster Art Image Picker — Design

> Spec for the "image picker for monster art" roadmap item (HANDOFF.md §2).
> Branch: `experiment/ui-ux`. Date: 2026-07-09.

## Problem

`MonsterTemplate.imageFileName: String?` (PianoCore) references an image file in the
app's Documents directory. Today the only way to set it is to **type a raw filename** in
`CatalogView`'s add form — there is no mechanism to get image *bytes* onto the device, and
migrated monsters carry a filename whose bytes do not exist yet, so they render as the
crown/pawprint placeholder forever.

Goal: let the teacher pick an image file, land its bytes in our Documents directory under a
name we control, and set the template's `imageFileName` — for both new and existing
templates.

## Non-goals / out of scope (flagged, not hidden)

- **Orphaned-file cleanup.** On replace (and on pick-then-cancel), the previous/unreferenced
  image file is intentionally *left on disk*. The rolling `appState.json` `.bak1/.bak2`
  backups may still reference the previous filename, so an eager delete could break a
  restore-from-backup. A cleanup pass is deliberate future work, not part of this slice.
- **UI-test automation of the picker.** `UIDocumentPickerViewController` is system UI that
  XCUITest cannot reliably drive. The image-store *logic* gets real unit coverage instead;
  the picker wiring is deliberately thin. This is the correct testing boundary — we cover
  the part that can actually break silently.

## Architecture invariants respected

- **No PianoCore change.** Art is stored by reference (a filename), not embedded in
  `appState.json`. This feature is entirely app-layer: write bytes to disk, set one string
  field through existing catalog CRUD (`GameStore.apply`, never the engine).
- **Never delete-and-re-add** to fix a template's art. A template `id` is referenced by
  `LineupSlot`s and historical `MonsterRecord`s; re-adding mints a new UUID and orphans them.
  Art is (re)assigned in place via a new `setTemplateImage` that mutates only `imageFileName`.
- **No force-unwrap / force-index** in app code (the guarded `documentsDirectory` pattern).

## Components

### 1. `MonsterImageStore` (new, app layer) — the testable core

Stateless helper (a caseless `enum`) that owns writing image bytes to disk and reading them
back bounded. No SwiftUI, no `GameStore`; takes a directory, returns a filename. This is the
unit-tested surface.

```swift
enum MonsterImageStore {
    enum StoreError: Error { case notAnImage, writeFailed }

    /// Copy a picked image into `directory` under a fresh <uuid>.<ext>.
    /// - Validates it decodes (CGImageSource) → else throws .notAnImage.
    /// - count <= maxBytes: copy bytes as-is, preserving a sanitized lowercase extension.
    /// - count >  maxBytes: downscale (longest edge <= maxPixel) + re-encode → <uuid>.<ext>.
    /// Returns the generated filename (never a path).
    static func store(pickedFileAt sourceURL: URL,
                      into directory: URL,
                      maxBytes: Int = 15_000_000,
                      maxPixel: CGFloat = 1600) throws -> String

    /// Bounded thumbnail decode via CGImageSourceCreateThumbnailAtIndex, so display
    /// memory is capped regardless of source resolution. Filename-keyed NSCache.
    static func thumbnail(filename: String, in directory: URL, maxPixel: CGFloat) -> UIImage?
}
```

Design notes to encode as code comments:

- **`maxPixel = 1600` is not arbitrary.** The battle view renders art at ~360 pt, i.e.
  ~720 px on a 2× display; 1600 px on the longest edge is already >2× display needs. The
  comment prevents someone "helpfully" raising it later.
- **Alpha on the re-encode path.** JPEG drops transparency. If a >15 MB source has an alpha
  channel, the downscale path re-encodes as **PNG** (not JPEG) so a transparent background
  isn't composited onto black. Rare case, one branch, saves a confusing "why is the
  background black" report.
- **The NSCache is invalidation-free by construction.** Because every write mints a fresh
  `<uuid>` filename and never overwrites in place, a given filename's bytes are immutable for
  life — so a filename-keyed cache never needs invalidating. A comment must record this so
  nobody "fixes" it by introducing overwrite-in-place, which would reintroduce a stale-image
  bug.

### 2. `MonsterImagePicker` (new, app layer) — thin SwiftUI wrapper

`UIViewControllerRepresentable` over
`UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)`,
single-selection.

`asCopy: true` supersedes the manual security-scope dance: the system hands us a temp copy
we can read directly (no `startAccessingSecurityScopedResource`), which we immediately pass
to `MonsterImageStore.store(...)` to land under a fresh name in our own directory. Same end
state (bytes fully in our control, offline), less to go wrong. Delegate reports the resulting
filename on success or a `StoreError`/cancel on failure.

### 3. `GameStore` — two small additions

- `func setTemplateImage(_ id: UUID, fileName: String?)` — `apply { … imageFileName = … }`
  (catalog CRUD → `apply` is the correct channel, not the typed engine).
- Expose `var imageDirectory: URL` (the directory the store was initialized with).
  **Correctness fix folded in:** `MonsterArt` currently reads from the *static*
  `GameStore.documentsDirectory`, but a seeded/UITest store uses a temp dir — a real latent
  bug. Both the picker (write) and `MonsterArt` (read) will use `store.imageDirectory`. This
  also makes picker-assigned art exercisable in future UI tests.

### 4. `CatalogView` — reuse the picker in two places

- **Add form:** replace the free-text "Image filename" `TextField` with a **"Choose image…"**
  button plus a small preview of the chosen art. If the teacher picks and then abandons the
  add form, the `<uuid>.<ext>` bytes are already written with no template referencing them —
  **intentional and harmless** (same class as the deferred orphan cleanup); a comment records
  this so the file isn't later mistaken for a leak.
- **Existing rows:** each row shows a thumbnail (`MonsterImageStore.thumbnail`, falling back
  to the current SF Symbol) and a trailing **photo button** to assign/replace art →
  `setTemplateImage`. No delete-and-re-add.
- Errors surface via a local `.alert`.

### 5. `MonsterArt` — bounded decode

Swap `UIImage(data:)` for `MonsterImageStore.thumbnail(filename:in:maxPixel:)`, reading from
`store.imageDirectory`. Placeholder behavior unchanged.

## Testing

New `PianoAppTests` unit target (`com.apple.product-type.bundle.unit-test`), wired into the
shared scheme — same shape as the `PianoAppUITests` target added last session, and the home
for all future app-layer unit tests. Covers `MonsterImageStore`:

- small PNG → filename returned, file exists, decodes, extension preserved;
- garbage bytes → throws `.notAnImage`;
- oversized source (small test `maxBytes`) → re-encoded, longest edge ≤ cap, still decodes;
- oversized source **with alpha** → re-encoded as PNG, alpha preserved;
- `thumbnail` returns a bounded image, and `nil` for a missing file.

Full gate for the slice:
1. `PianoAppTests` (new) — green.
2. `PianoAppUITests` (existing 4 battle-flow tests) — still green.
3. `PianoCore` `swift test` (61) — still green.
4. App builds for iPad Pro 13-inch.

## Files touched

| File | Change |
|---|---|
| `PianoApp/Battle/MonsterImageStore.swift` | **new** — store + thumbnail helper |
| `PianoApp/Admin/MonsterImagePicker.swift` | **new** — document-picker wrapper |
| `PianoApp/GameStore.swift` | `setTemplateImage`, `imageDirectory` |
| `PianoApp/Admin/CatalogView.swift` | picker in add form + per-row assign/replace + thumbnails |
| `PianoApp/Battle/MonsterArt.swift` | bounded decode via `MonsterImageStore`, read from `store.imageDirectory` |
| `PianoAppTests/MonsterImageStoreTests.swift` | **new** — unit tests |
| `PianoApp.xcodeproj/project.pbxproj` | **new** `PianoAppTests` unit-test target + scheme wiring |
