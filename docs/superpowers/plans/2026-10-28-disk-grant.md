# Disk Grant and External Disks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `Grant` button on hovered private rows of the Disk panel that opens that folder once (macOS asks) and shows its size from then on, and a section per external disk with its used space and, after a grant, its folders; plus the menu bar items' order shipped in the app.

**Architecture:** `Disk.swift` keeps the sampler, the spaces, `scanFolders` and `DiskPanel`; two new files hold what is new: `DiskGrants.swift` (which paths get a button, the remembered grants tied to the build's signature, the splice that puts a freshly measured folder into the tree) and `DiskVolumes.swift` (finding external volumes, the per-volume section view and its saved measurement). `scanFolders` learns a `GrantSet` of paths it may open; everything else about privacy stays as it is. Each new piece of logic gets a command-line flag so the tests (a program driving the binary) can pin it without a dialog ever appearing.

**Tech Stack:** Swift 5, AppKit, Foundation (`FileManager`, `URLResourceKey`, `UserDefaults`), Security (`SecCodeCopySelf` for the build's cdhash), the Command Line Tools only. Tests: `Tests/MacStatsTests/main.swift`, run by `make test`.

**Spec:** `docs/superpowers/specs/2026-10-28-disk-grant-design.md`

## Global Constraints

- macOS 13 and later; no sandbox, no entitlements; builds with `swift build` and the Command Line Tools alone (no XCTest).
- **No prompt the user did not ask for.** Nothing but a click on `Grant` may cause a privacy dialog: not launch, not opening the panel, not plugging in a drive, not a remeasurement, not any command-line flag, not `make test`. Check with `log show --last 10m --predicate 'process == "tccd" AND eventMessage CONTAINS "sh.csarko.MacStats"'`.
- Command-line flags and tests **never open a folder macOS guards**; they open only folders the test created or a path the caller names explicitly.
- Plain words in panel text, tooltips and comments; every tooltip through `twoLines` (at most two short lines).
- Fixed-width menu bar items and the one-second samplers are untouched.
- Motion: enter 150 ms, exit 75 ms, timing `CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)`; immediate when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- Work on a branch `disk-grant` off `main`; one commit per task; `make test` green before each commit.
- The Mac is a 16 GB MacBook Air: one `swift build` at a time.

## Review Focus

1. A private folder that is granted but whose *parent* is still partial: the parent's `≥` must stay while any other unmeasured folder remains below it, and go only when none does. (Task 4 test `clears ≥ only when nothing unmeasured is left`.)
2. A folder granted in one build, read by a rebuilt (re-signed) app: no automatic open may happen; the rows must show `private` with buttons again. (Task 5 test `forgets grants made by another build`.)
3. The `/Volumes` folder itself must no longer appear in the startup-disk tree, and a scan must still not cross onto an external disk. (Task 3 test `lists no Volumes row`.)
4. A saved `folders.json` written by the current release (no `refused` key) must still load after the `Entry` change. (Task 4 test `reads a saved measurement without the new keys`.)
5. A refusal (Don't Allow) must show as `no access` and drop the grant, so the next remeasurement does not try again. (Task 4 test `shows a refused folder as no access`; Task 7 hand check.)

---

### Task 1: Ship the menu bar items' order

The five items must sit CPU, GPU, RAM, Temp, Disk from left to right on a fresh install. macOS places each item by `NSStatusItem Preferred Position <autosaveName>` in the app's defaults (a larger number sits further left); today only the `menubar-stats` setup script writes them, so a fresh install lands them in creation order. Registering them as defaults ships the order while a place the user dragged to (a set value) still wins.

**Files:**
- Modify: `Sources/MacStats/main.swift` (the `UserDefaults.standard.register` line near the bottom, and the flags block)
- Test: `Tests/MacStatsTests/main.swift`

**Interfaces:**
- Produces: `let itemPositions: [(name: String, position: Double)]` in `main.swift`, in menu bar order: `("MacStatsCPU", 1300), ("MacStatsGPU", 1250), ("MacStatsRAM", 1200), ("MacStatsTemp", 1150), ("MacStatsDisk", 1100)`; flag `--item-positions` printing `name\tposition` per line in that order, from `UserDefaults.standard` after registration.

- [ ] **Step 1: Write the failing test**

```swift
test("ships the menu bar items' order, CPU to Disk from the left") {
    let rows = try macStats("--item-positions").lines.map { $0.components(separatedBy: "\t") }
    checkEqual(rows.map { $0[0] }, ["MacStatsCPU", "MacStatsGPU", "MacStatsRAM", "MacStatsTemp", "MacStatsDisk"], "the names")
    let positions = rows.compactMap { Double($0[1]) }
    check(positions == positions.sorted(by: >), "a larger number sits further left, so they descend")
    checkEqual(positions.count, 5, "every item has a position")
}
```

- [ ] **Step 2: Run it to see it fail**: `make test 2>&1 | grep -A3 "menu bar items' order"` → `FAIL` (the flag is unknown, so the binary starts the app and the run times out or exits non-zero).

- [ ] **Step 3: Register the positions and add the flag.** In `main.swift`, next to the `NSInitialToolTipDelay` registration, register `["NSStatusItem Preferred Position \(name)": position]` for every entry of `itemPositions`; put the registration *before* the flags block so `--item-positions` sees it; the flag prints `name\t<position as %.0f>` for each entry read back from `UserDefaults.standard.double(forKey:)` and exits 0. Comment: why registered, not set (a user's own drag wins).

- [ ] **Step 4: Run the tests**: `make test` → the new test `ok`, nothing else changed.

- [ ] **Step 5: Hand check**: `make app && pkill -x MacStats; defaults delete sh.csarko.MacStats 2>/dev/null; open build/MacStats.app` → the items read CPU GPU RAM Temp Disk left to right. Then `open -a ~/Applications/MacStats.app` to restore the installed copy (the `menubar-stats` script's values return on its next run; they are the same numbers).

- [ ] **Step 6: Commit**: `git commit -am "Ship the menu bar items' order as registered defaults"`

---

### Task 2: External volumes and `--volumes`

**Files:**
- Create: `Sources/MacStats/DiskVolumes.swift`
- Modify: `Sources/MacStats/Disk.swift` (`formatSize`), `Sources/MacStats/main.swift` (flags)
- Test: `Tests/MacStatsTests/main.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ExternalVolume { let name: String; let mountPoint: String; let uuid: String; let total: Int64; let used: Int64; let isNetwork: Bool }
  /// Mounted volumes that are browsable, not the root file system and not internal, in mount order.
  func externalVolumes() -> [ExternalVolume]
  ```
  `formatSize` returns `"1.8 TB"` for 1_800_000_000_000 (one decimal above 1 TB, as GB has).
  Flag `--volumes`: one line per volume, `name\tused\ttotal\tmountPoint\tstate` with bytes as integers and `state` fixed to `private` until Task 5; prints nothing and exits 0 with no external disk.

- [ ] **Step 1: Write the failing test**

```swift
test("lists external volumes with their used and total bytes") {
    let rows = try macStats("--volumes").lines.filter { !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
    for row in rows {
        checkEqual(row.count, 5, "name, used, total, mount point, state: \(row)")
        let used = Int64(row[1]) ?? -1, total = Int64(row[2]) ?? -1
        check(used >= 0 && total > 0 && used <= total, "\(row[0]) used \(used) of \(total)")
        check(FileManager.default.fileExists(atPath: row[3]), "\(row[3]) is mounted")
        check(["granted", "private", "no access"].contains(row[4]), "a known state, got \(row[4])")
    }
    // With no external disk the flag prints nothing; that is a pass too.
}
```

- [ ] **Step 2: Run it to see it fail**: `make test 2>&1 | grep -A3 "external volumes"` → `FAIL`.

- [ ] **Step 3: Implement `externalVolumes()` in `DiskVolumes.swift`** with `FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:options: [.skipHiddenVolumes])` and the keys `volumeIsBrowsableKey`, `volumeIsRootFileSystemKey`, `volumeIsInternalKey`, `volumeIsLocalKey`, `volumeNameKey`, `volumeUUIDStringKey`, `volumeTotalCapacityKey`, `volumeAvailableCapacityKey`; `used = total - available`; `uuid` falls back to the name; `isNetwork = !(volumeIsLocal ?? true)`. Extend `formatSize` with a TB branch. Add the `--volumes` flag in `main.swift` beside `--spaces`.

- [ ] **Step 4: Run the tests**: `make test` → `ok`. With the SSD plugged in, `swift build && .build/debug/MacStats --volumes` prints one `CyrusExtSSD` line whose numbers match `df -k /Volumes/CyrusExtSSD`; `tccd` log shows nothing for MacStats.

- [ ] **Step 5: Commit**: `git add -A Sources Tests && git commit -m "Find external volumes; --volumes prints them"`

---

### Task 3: Which paths get Grant, and a scan that opens granted folders

**Files:**
- Create: `Sources/MacStats/DiskGrants.swift`
- Modify: `Sources/MacStats/Disk.swift:190-265` (`scanFolders`), `Sources/MacStats/main.swift` (flags)
- Test: `Tests/MacStatsTests/main.swift`

**Interfaces:**
- Produces, in `DiskGrants.swift`:
  ```swift
  enum GrantKind: String { case dialog, none, notPrivate = "not private" }
  /// Whether a private row at `path` gets a Grant button: `dialog` for Desktop, Documents,
  /// Downloads, Music and Movies directly in a home under `users`, and for a mount point
  /// under /Volumes; `none` for every other private path; `notPrivate` otherwise.
  func grantKind(for path: String, users: String = "/Users") -> GrantKind
  struct GrantSet: Equatable { var folders: Set<String> = []; var removableVolumes = false; var networkVolumes = false }
  ```
  In `Disk.swift`: `func scanFolders(_ root: String, depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes, granted: GrantSet = GrantSet()) -> [Entry]`: a path in `granted.folders` is listed like any folder (not skipped, no `private` note); `<root>/Volumes` is skipped **and not listed** (no row at all; `FTS_XDEV` already keeps the walk off other devices). Paths are compared as the scan walks them, so the caller passes paths under the same root spelling (`/System/Volumes/Data/Users/…` when scanning `dataVolume`; the store in Task 5 canonicalises).
  Flags: `--grantable <path>` prints the `GrantKind` raw value; `--report <dir> --granted <path>` (repeatable) scans with those paths granted.

- [ ] **Step 1: Write the failing tests**

```swift
test("says which private rows can be granted") {
    let home = "/Users/" + NSUserName()
    checkEqual(try macStats("--grantable", home + "/Downloads").lines, ["dialog"], "Downloads")
    checkEqual(try macStats("--grantable", home + "/Music").lines, ["dialog"], "Music")
    checkEqual(try macStats("--grantable", "/Volumes/Some Disk").lines, ["dialog"], "a volume")
    checkEqual(try macStats("--grantable", home + "/Library/Mail").lines, ["none"], "Mail")
    checkEqual(try macStats("--grantable", home + "/Library/Containers").lines, ["none"], "containers")
    checkEqual(try macStats("--grantable", try tempDir("plain").path).lines, ["not private"], "a plain folder")
}

test("counts a granted private folder and still skips the others") {
    let dir = try tempDir("granted")
    for (path, mb) in [("Users/alice/Documents/a.bin", 4.0), ("Users/alice/Downloads/b.bin", 2.0), ("Users/alice/Code/c.bin", 1.0)] {
        /* write as tree() does */
    }
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--granted", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Documents | 4 MB", "    Code | 1 MB", "    Downloads | private"], "the rows")
}

test("lists no Volumes row") {
    let lines = try tree([("Volumes/Disk/x.bin", 3), ("Stuff/y.bin", 2)])
    checkEqual(lines, ["Stuff | 2 MB"], "Volumes is neither counted nor listed")
}
```
(Lift the file-writing loop of `tree()` into a helper `writeTree(_ dir: URL, _ files: [(String, Double)])` so both tests use it.)

- [ ] **Step 2: Run them to see them fail**: `make test 2>&1 | grep -E "^(FAIL|ok) .*(granted|Volumes row)"` → three `FAIL`.

- [ ] **Step 3: Implement.** `grantKind(for:)` in `DiskGrants.swift` (string rules only, no file access). In `scanFolders`, add the `granted` parameter, consult it before the `privatePaths` check, and replace the `/Volumes` entry in `privatePaths` with a skip that also removes the just-appended `Entry` (or never appends it). Add the two flags in `main.swift`; `--granted` collects every value following that flag.

- [ ] **Step 4: Run the tests**: `make test` → all `ok`, including the existing `lists private folders by name` test unchanged.

- [ ] **Step 5: Commit**: `git add -A Sources Tests && git commit -m "Grant rules, and a scan that opens granted folders"`

---

### Task 4: The splice: measure one folder and put it into the tree

**Files:**
- Modify: `Sources/MacStats/DiskGrants.swift`, `Sources/MacStats/Disk.swift:47-68` (`Entry`), `Sources/MacStats/main.swift`
- Test: `Tests/MacStatsTests/main.swift`

**Interfaces:**
- `Entry` gains `var refused = false` (true when `no access` came from macOS refusing a granted folder) and decodes a JSON without `refused` or `partial` (`decodeIfPresent`, default false).
- Produces, in `DiskGrants.swift`:
  ```swift
  enum GrantOutcome { case measured, refused }
  /// Measures `path` on its own, to the depth left under it, and splices the result into
  /// `folders` in place: the entry loses its note and gains bytes and children, every ancestor
  /// grows by the same bytes, and each ancestor's `partial` is recomputed from what is still
  /// unmeasured below it. A root that cannot be opened leaves the entry as `no access`,
  /// `refused`, and returns `.refused`.
  @discardableResult
  func grant(_ path: String, in folders: [Entry], depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes, granted: GrantSet) -> GrantOutcome
  /// True when any entry below has a note (private or no access).
  func hasUnmeasured(_ entry: Entry) -> Bool
  ```
  Flag: `--report <dir> --then-grant <path>` scans, then calls `grant(path, in:)` with `path` added to the grant set, then prints the tree.

- [ ] **Step 1: Write the failing tests**

```swift
test("grants one folder: its size appears and reaches its parents") {
    let dir = try tempDir("splice")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Downloads/b.bin", 2), ("Users/alice/Code/c.bin", 1)])
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Documents | 4 MB", "    Code | 1 MB", "    Downloads | private"], "the rows")
}

test("clears ≥ only when nothing unmeasured is left") {
    let dir = try tempDir("splice-clear")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Code/c.bin", 1)])
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | 5 MB", "  alice | 5 MB", "    Documents | 4 MB", "    Code | 1 MB"], "no ≥ remains")
}

test("shows a refused folder as no access") {
    let dir = try tempDir("refused")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Code/c.bin", 1)])
    let documents = dir.path + "/Users/alice/Documents"
    chmod(documents, 0)
    defer { chmod(documents, 0o755) }
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", documents).lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 1 MB", "  alice | ≥ 1 MB", "    Code | 1 MB", "    Documents | no access"], "the rows")
}

test("reads a saved measurement without the new keys") {
    let json = #"{"measuredAt":0,"folders":[{"title":"Users","bytes":5,"partial":false,"children":[]}]}"#
    checkEqual(try macStats("--read-measurement", "-", stdin: json).lines, ["Users\t5 MB"], "decodes the old shape")
}
```
For the last test add a `stdin:` parameter to `run`/`macStats` (pipe the string in) and the flag `--read-measurement <file|->` that decodes a `SavedMeasurement` and prints the tree as `--report` does. Note the `Users | ≥ 7 MB` style sums use allocated blocks, as the existing `tree` test does; 4 + 1 = 5 MB files round to `5 MB`.

- [ ] **Step 2: Run them to see them fail**: four `FAIL`.

- [ ] **Step 3: Implement.** `grant(_:in:)`: find the entry by `path` (depth-first), compute `remaining = depth - entryLevel`, call `scanFolders(path, depth: remaining, minimumBytes:, granted:)`; if the root could not be read (detect with `opendir`/`contentsOfDirectory` failing with `EACCES`/`EPERM` *on the test's chmod'd folder*, which is the same failure macOS gives) set `note = "no access"`, `refused = true`, return `.refused`; else fill the entry, walk the ancestors adding `bytes` and setting `partial = hasUnmeasured(ancestor)`. Move `SavedMeasurement` out of `DiskPanel` to file scope so the flag can decode it; make `Entry` decode missing keys. Add the flags.

- [ ] **Step 4: Run the tests**: `make test` → all `ok`.

- [ ] **Step 5: Commit**: `git add -A Sources Tests && git commit -m "Measure one granted folder and splice it into the tree"`

---

### Task 5: Remembering grants, tied to the build

**Files:**
- Modify: `Sources/MacStats/DiskGrants.swift`, `Sources/MacStats/main.swift` (`--volumes` state column; a `--grants` flag)
- Test: `Tests/MacStatsTests/main.swift`

**Interfaces:**
- Produces, in `DiskGrants.swift`:
  ```swift
  final class GrantStore {
      static let suite = "sh.csarko.MacStats"
      /// The running code's cdhash as hex (SecCodeCopySelf + SecCodeCopySigningInformation, kSecCodeInfoUnique); "unsigned" when there is none.
      static func buildIdentity() -> String
      init(defaults: UserDefaults = UserDefaults(suiteName: GrantStore.suite)!, build: String = GrantStore.buildIdentity())
      /// Empty when the stored build differs from this one.
      func load() -> GrantSet
      func add(folder: String)      // canonical path: "/System/Volumes/Data" prefix removed, symlinks not resolved
      func remove(folder: String)
      func set(removableVolumes: Bool)
      func set(networkVolumes: Bool)
      /// Every write also stores this build's identity under `grantsBuild`.
  }
  ```
  Keys: `grantedFolders` (array of strings), `removableVolumesGranted`, `networkVolumesGranted`, `grantsBuild`.
  `--volumes` state column: `granted` when `removableVolumesGranted` (or `networkVolumesGranted` for a network volume), else `private`; `no access` is set by Task 8b.
  Flag `--grants [--defaults-suite <name>] [--as-build <id>]`: prints `build\t<identity>` then the loaded set as `folder\t<path>` lines and `removable\ttrue|false`, `network\ttrue|false`; the two options exist for the tests (a throwaway suite, a pretend build).

- [ ] **Step 1: Write the failing tests**

```swift
test("knows which build it is") {
    let build = try fields(try macStats("--grants").lines, "build")?.first ?? ""
    check(matches(build, "^[0-9a-f]{40,}$") || build == "unsigned", "a cdhash or unsigned, got \(build)")
}

test("forgets grants made by another build") {
    let suite = "sh.csarko.MacStats.tests.\(UUID().uuidString.prefix(8))"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    try macStats("--grants", "--defaults-suite", suite, "--as-build", "aaa", "--add-folder", "/Users/alice/Downloads", "--set-removable", "true")
    let same = try macStats("--grants", "--defaults-suite", suite, "--as-build", "aaa").lines
    checkEqual(fields(same, "folder")?.first, "/Users/alice/Downloads", "remembered in the same build")
    checkEqual(fields(same, "removable")?.first, "true", "removable remembered")
    let other = try macStats("--grants", "--defaults-suite", suite, "--as-build", "bbb").lines
    check(fields(other, "folder") == nil, "a different build starts with no folder grants")
    checkEqual(fields(other, "removable")?.first, "false", "nor volume grants")
}
```
(`--add-folder <path>` and `--set-removable <bool>` are write options of `--grants`, for the tests.)

- [ ] **Step 2: Run them to see them fail**: two `FAIL`.

- [ ] **Step 3: Implement `GrantStore`** and the flag. `load()` compares `grantsBuild` to `build` and returns `GrantSet()` on a mismatch (it does not erase; the next write overwrites). Canonicalise in `add`/`remove` by stripping a leading `/System/Volumes/Data`. Wire `--volumes` to `GrantStore().load()`.

- [ ] **Step 4: Run the tests**: `make test` → all `ok`.

- [ ] **Step 5: Commit**: `git add -A Sources Tests && git commit -m "Remember grants per build of the app"`

---

### Task 6: The Grant button on a hovered row

**Files:**
- Modify: `Sources/MacStats/Disk.swift` (`DiskPanel.build`, `outlineView(_:viewFor:item:)`, new hover code), `Sources/MacStats/MenuKit.swift` (a shared `fade(_:in:)` helper if Task 8 reuses it)

**Interfaces:**
- Produces, in `Disk.swift`:
  ```swift
  /// The size column's cell: the size or note, and a Grant button shown over the note on hover.
  final class SizeCell: NSTableCellView {
      let button: NSButton   // title "Grant", bezel .inline or .rounded, controlSize .small, font 11 semibold, alphaValue 0, isHidden true
      var showsGrant: Bool   // whether this row can carry a button (set per row)
      func setGrantVisible(_ visible: Bool, animated: Bool)   // 150 ms in / 75 ms out, standard curve; text fades the other way
  }
  ```
  `DiskPanel`: `private var hoveredRow = -1`; a tracking area on `outline` (`mouseMoved`, `mouseEnteredAndExited`, `activeAlways`, `inVisibleRect`) whose owner is the panel; `mouseMoved` finds `outline.row(at:)` and, when it changes, hides the old row's button and shows the new one if its entry's `grantKind == .dialog && note == "private"` (or `refused`, Task 7). `mouseExited` and `outline.reloadData()` reset `hoveredRow`. The button's `target` is the panel, `action` `#selector(grantClicked(_:))` (a stub until Task 7 that logs nothing and does nothing). Tooltips, through `twoLines`: on the button "Opens this folder once; macOS asks you to allow it. MacStats remembers your answer."; on a `private` size cell with no button "macOS has no dialog for this folder; Finder's Get Info gives its size.".

- [ ] **Step 1: Pin the tooltips in the tests.** Extend the existing tooltip test: `--tooltips` output is every tooltip of a freshly built `DiskPanel`, which has no rows; so add to `tooltipsReport` a fixed sample tree (one `dialog` private row, one `none` private row, loaded through `show(_:at:)`) when the panel is built for the report, and assert:

```swift
let diskOther = tips.filter { $0[0] == "Disk" && $0[1] == "other" }.map { $0[5] }
check(diskOther.contains { $0.hasPrefix("Opens this folder once") }, "the Grant button's tooltip")
check(diskOther.contains { $0.hasPrefix("macOS has no dialog for this folder") }, "the no-button tooltip")
```
Run: `make test` → that test `FAIL`.

- [ ] **Step 2: Implement `SizeCell`, the tracking area and the hover bookkeeping.** Use `NSAnimationContext.runAnimationGroup` with `context.duration` 0.15 / 0.075 and `context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)`, animating `animator().alphaValue` of the button and the text field, plus a 1 pt rise of the button's frame on enter; skip the animation when Reduce Motion is on. Hide the button (`isHidden`) once faded out so it never takes clicks. Cells are reused by the outline: set `showsGrant`, the texts and the tooltips on every `viewFor` call, and reset the button to hidden.

- [ ] **Step 3: Run the tests**: `make test` → all `ok` (the two-line rule holds for the new tooltips).

- [ ] **Step 4: Hand check.** `make app && pkill -x MacStats; open build/MacStats.app`; open Disk: hovering Documents/Downloads/Desktop/Movies/Music swaps `private` for `Grant` with a visible fade and back; moving straight from one to the next shows one button at a time; scrolling the list while hovering leaves no stray button; Mail-style rows (none visible at depth 3 today, so check `Library`'s `≥` row shows nothing) show no button; `.Trash`'s `no access` row shows no button. System Settings › Accessibility › Display › Reduce Motion on: the swap is immediate. `tccd` log: nothing.

- [ ] **Step 5: Commit**: `git add -A Sources Tests && git commit -m "A Grant button fades in on a hovered private row"`

---

### Task 7: Clicking Grant on a home folder

**Files:**
- Modify: `Sources/MacStats/Disk.swift` (`DiskPanel`: `grantClicked`, `measureFolders`, `loadSavedMeasurement`), `Sources/MacStats/DiskGrants.swift` (System Settings URLs)

**Interfaces:**
- Consumes: `grant(_:in:depth:minimumBytes:granted:)`, `GrantStore`, `SizeCell`.
- Produces: `DiskPanel.grants = GrantStore()`; `private var granted: GrantSet` loaded in `init` and before every scan; `measureFolders()` passes `granted` to `scanFolders`; `@objc func grantClicked(_ sender: NSButton)`; in `DiskGrants.swift`:
  ```swift
  enum PrivacyPane { case filesAndFolders, mediaLibrary }
  /// Opens System Settings at the pane, falling back to Privacy & Security.
  func openPrivacySettings(_ pane: PrivacyPane)
  ```
  Candidate URLs to try in order, each with `NSWorkspace.shared.open` returning true: Files and Folders `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`, then `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders`; Media `…?Privacy_Media`; fallback `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension`. Keep whichever opens on this Mac first in the list and leave the rest as fallbacks.

- [ ] **Step 1: Implement the click.** `grantClicked`: row → `Entry`; if `entry.refused` → `orderOut(nil)`, `openPrivacySettings(grantKind pane: media for Music/Movies, else filesAndFolders)`, return. Else: `grants.add(folder: entry.path)`, `granted = grants.load()`, swap the button for a small `NSProgressIndicator` (spinning, `.small`) in the cell, then on `DispatchQueue.global(qos: .userInitiated)`: `let outcome = grant(path, in: folders, granted: granted)`; back on main: if `.refused` → `grants.remove(folder:)`; reload the outline (`reloadItem(_:reloadChildren:)` on the entry and its ancestors, or `reloadData` + re-expand as `show` does), `saveMeasurement()`, `fitToContents()`. A refused row's tooltip (on its size cell) becomes "Allowed in System Settings › Privacy & Security › Files and Folders" (media rows: "› Media & Apple Music"), and hovering it shows the Grant button again (Task 6's rule includes `refused`).
- Also: the `privacy` sentence in `updateStatus()` and the status-line tooltip change to "Private folders stay closed unless you grant one; ≥ means at least." (through `twoLines` where it is a tooltip).

- [ ] **Step 2: `make test`** → all `ok` (the tooltip test picks up the changed status tooltip; keep it to two lines).

- [ ] **Step 3: Hand check, from the bundle.** `make app && pkill -x MacStats; tccutil reset SystemPolicyDownloadsFolder sh.csarko.MacStats; open build/MacStats.app`. Disk → hover Downloads → Grant: the spinner shows, macOS asks about Downloads, **Allow** → the row shows a size within a second or two, `alice`/`Users` rows grow and keep or lose `≥` correctly, no full remeasurement starts. Quit and reopen the app: the size is still there; wait for or force a remeasurement (Measure again): no dialog, the size stays. Then `tccutil reset SystemPolicyDesktopFolder sh.csarko.MacStats`, Grant on Desktop → **Don't Allow** → `no access`, hover shows Grant, click opens System Settings at Files and Folders; turn MacStats on there, Measure again → the size appears. Music: Grant → the media dialog appears during the measurement; Allow → size. `log show --last 30m --predicate 'process == "tccd" AND eventMessage CONTAINS "sh.csarko.MacStats"'` shows only the prompts you clicked for. Rebuild (`make app`), relaunch: the rows are `private` again with buttons, and no dialog appeared on launch.

- [ ] **Step 4: Commit**: `git add -A Sources && git commit -m "Grant opens a private folder once and keeps its size"`

---

### Task 8a: An external disk's section, before any grant

**Files:**
- Modify: `Sources/MacStats/DiskVolumes.swift` (`VolumeSection`), `Sources/MacStats/Disk.swift` (`DiskPanel.build`, `willOpen`, `refreshSpaces`), `Sources/MacStats/main.swift` (`--report` with no folder also prints a line per volume)

**Interfaces:**
- Produces, in `DiskVolumes.swift`:
  ```swift
  final class VolumeSection: NSView {
      let volume: ExternalVolume
      let usedRow: PanelRow          // "Used:" / "85.2 GB of 1.8 TB"
      let bar: SpaceBar              // used in spaceRoles' "my apps / files" blue over the bar's grey
      let foldersRow: PanelRow       // "Folders" / "private", hoverTip and a Grant button (Task 8b)
      init(volume: ExternalVolume)
      func update(volume: ExternalVolume)   // new used/total figures
  }
  ```
  Height: separator 30 + row 22 + bar 14 + row 22. `usedRow.hoverTip = twoLines("<free> free. Space on this disk, not the startup disk.")`.
  `DiskPanel`: `private var volumeSections: [String: VolumeSection]` keyed by uuid; `private let volumesStack = NSStackView()` (vertical, after `folderArea` in `body`); `willOpen` calls `refreshVolumes()`, which reads `externalVolumes()` on a background queue and, on main, adds a section per new volume, updates existing ones, removes sections for volumes no longer mounted, then `fitToContents()`.
  `--report` with no folder prints, after the startup tree, `<name>\t<used formatted> of <total formatted>` per external volume.

- [ ] **Step 1: Pin `--report`'s volume lines**:

```swift
test("--report ends with a line per external volume") {
    let volumes = try macStats("--volumes").lines.filter { !$0.isEmpty }
    if volumes.isEmpty { try skip("no external disk attached") }
    let report = try macStats("--report", timeout: 600).lines
    for volume in volumes {
        let name = volume.components(separatedBy: "\t")[0]
        check(report.contains { $0.hasPrefix(name + "\t") && $0.contains(" of ") }, "a line for \(name)")
    }
}
```
Run: with the SSD attached, `FAIL`; without, `skip`.

- [ ] **Step 2: Implement `VolumeSection`, `refreshVolumes()` and the report line.** Build the section from `separatorView(volume.name)`, a `PanelRow("Used:")`, a `SpaceBar` with one part, and a `PanelRow("Folders")` whose `value` reads `private` in `.tertiaryLabelColor`. Sections are added to `volumesStack` in mount order.

- [ ] **Step 3: `make test`** → `ok` (or `skip`).

- [ ] **Step 4: Hand check.** Bundle, SSD attached: the Disk panel ends with `CYRUSEXTSSD`, `Used: 85.2 GB of 1.8 TB`, a bar about 5% blue, `Folders  private`. Eject the SSD, close and reopen the panel: the section is gone. Plug it back, reopen: it is back. `tccd` log: nothing.

- [ ] **Step 5: Commit**: `git add -A Sources Tests && git commit -m "A section per external disk with its used space"`

---

### Task 8b: Granting an external disk, its folders and their memory

**Files:**
- Modify: `Sources/MacStats/DiskVolumes.swift`, `Sources/MacStats/Disk.swift` (`DiskPanel`: the serial measuring queue, grant for volumes)

**Interfaces:**
- `VolumeSection` gains: `let status = NSTextField` ("Last measured at …" / "Remeasuring…" like the startup disk's line), `let outline = NSOutlineView` in an `NSScrollView` with the same two columns, cells (`SizeCell`) and double-click as the startup disk's, `var folders: [Entry]`, `var measuredAt: Date?`, `var state: VolumeState` where `enum VolumeState { case ungranted, measured, refused }`; `var listHeight: NSLayoutConstraint` (`Panel.row × min(max(topLevelRows, 1), 8)` until Task 8c).
- `DiskPanel` gains `private let measureQueue = DispatchQueue(label: "sh.csarko.MacStats.measure", qos: .utility)`: every `scanFolders` call of the panel (startup disk and volumes) runs on it, so they never compete; `measureFolders()` and the volumes' measurements are enqueued in that order from `willOpen`.
- Saved per volume at `Caches/sh.csarko.MacStats/volumes/<uuid>.json` as a `SavedMeasurement`; loaded when a section is created; remeasured on open when older than ten minutes and the volume is granted; also on the header's Measure-again button.
- Grant on `foldersRow`: `grants.set(removableVolumes: true)` (or `networkVolumes` for a network volume), spinner, then on `measureQueue`: `scanFolders(volume.mountPoint, granted:)`; a mount point that cannot be opened → `state = .refused`, the flag is set back to false, `foldersRow.value` reads `no access` with the Files-and-Folders tooltip and Grant opens that pane. Success → `state = .measured`, the outline shows, `foldersRow` is hidden, `status` shows the time.
- `--volumes` state column reads `no access` when the volume's saved file records a refusal (store `refused` in the per-volume JSON).

- [ ] **Step 1: Implement** as above. A second removable disk plugged in after one grant is measured without a click (the flag covers all).

- [ ] **Step 2: `make test`** → all `ok` (no new automated test: the dialog is macOS's).

- [ ] **Step 3: Hand check.** Bundle; `tccutil reset SystemPolicyRemovableVolumes sh.csarko.MacStats`; SSD attached. Grant on `Folders` → the removable-volume dialog → Allow → within a minute the SSD's folders list (sdd-archive, dayhike-lab, …), biggest first, `Last measured at` shows, the panel refits. Double-click a folder → Finder. Quit, relaunch: the list shows at once from the cache, then remeasures after ten minutes with no dialog. Eject and replug: the section returns measured. Reset the permission and Don't Allow: `no access`, Grant → System Settings. `tccd` log: only the clicks.

- [ ] **Step 4: Commit**: `git add -A Sources && git commit -m "Grant an external disk and list its folders"`

---

### Task 8c: The panel fits the screen

**Files:**
- Modify: `Sources/MacStats/MenuKit.swift:628-635` (`StatsPanel.fitToContents`), `Sources/MacStats/Disk.swift` (`DiskPanel`'s list height constraints)

**Interfaces:**
- `StatsPanel` gains `func maximumHeight() -> CGFloat`: the `visibleFrame.height` of the screen the panel is on (or `NSScreen.main`) minus 6, and `func heightNeeded() -> CGFloat` (`contentView.fittingSize.height`). `fitToContents()` is unchanged in behaviour for the other panels.
- `DiskPanel` overrides `fitToContents()`: set every list to its preferred height (startup 15 rows; each volume `min(rows, 8)`), measure `heightNeeded()`; while it exceeds `maximumHeight()`, take one row off the tallest volume list above 3 rows; then, still over, one row off the startup list down to 8; then `super.fitToContents()`. `foldersHeight` becomes the startup list's constraint constant rather than a fixed layout value.

- [ ] **Step 1: Implement.**

- [ ] **Step 2: `make test`** → all `ok`.

- [ ] **Step 3: Hand check.** With the SSD granted and its list at 8 rows, the panel's bottom stays on screen on the Air's built-in display; the startup list keeps 15 rows if room allows, otherwise shrinks last; every shortened list scrolls. `System Settings › Displays › More Space` (smaller UI) and back: the panel refits on the next open.

- [ ] **Step 4: Commit**: `git add -A Sources && git commit -m "Keep the Disk panel on screen with external disks"`

---

### Task 9: Docs, previews, version

**Files:**
- Modify: `README.md` (intro lines 11-16, Disk section lines 156-168, command-line list lines 179-187), `AGENTS.md` (Layout table, the "No permission prompts" convention lines 30-34), `scripts/previews.sh` (line 73: launch the bundle as an app), `VERSION`
- Regenerate: `docs/previews/disk-dark.png`, `docs/previews/disk-light.png`

- [ ] **Step 1: README.** Intro: "MacStats asks for no permissions on its own and causes no privacy prompts: the only one it ever causes is the one you ask for by clicking Grant on a private folder." Disk section: a sentence each on Grant (which rows, what happens, Don't Allow → System Settings), external disks (own section, used space without a grant, folders after one), and that Mail-style folders stay private (Finder's Get Info). Command-line list: add `MacStats --volumes` and `--grantable <path>`; the test-only flags (`--granted`, `--then-grant`, `--read-measurement`, `--grants`, `--item-positions`) are listed in `main.swift`'s header comment, not the README.

- [ ] **Step 2: AGENTS.md.** Layout table: `DiskGrants.swift` and `DiskVolumes.swift` rows. Convention: "**No prompts the user did not ask for.** The one allowed trigger is a click on Grant in the Disk panel; nothing else MacStats does may cause a privacy dialog (…list as today…); command-line flags and tests never open a guarded folder. Check a change with the `tccd` log command." Add the hand-test notes from the spec (run the bundle, `tccutil reset …`).

- [ ] **Step 3: previews.sh.** Replace the direct `"$APP" … &` launch with `open -n -W "$ROOT/build/MacStats.app" --args --appearance "$look" --show-panel … &` so granted folders open under the app's identity; keep `PID` handling working (`pgrep -x MacStats` for the kill). Comment why.

- [ ] **Step 4: Previews.** With the SSD attached and Downloads and the SSD granted: `scripts/previews.sh` (needs Screen Recording for the terminal); check `disk-dark.png` and `disk-light.png` show the SSD section and a granted size; commit them.

- [ ] **Step 5: VERSION** → `1.1.0`. `make test` → all `ok`.

- [ ] **Step 6: Commit**: `git add -A && git commit -m "Document Grant and external disks; 1.1.0"`

---

## Self-review notes

- Spec coverage: Grant rows (3, 6), click flow and refusal (4, 7), remembering per build (5), CLI never opens granted folders (3–5: flags open only named or test paths), external disks (2, 8a, 8b), height (8c), motion (6), tooltips (6, 7, 8a), docs/previews/version (9), menu bar order (1, Cyrus's addition). `grantKind` returns `dialog` for Music/Movies even though the dialog comes from a subfolder: the spec defines Grant as "measure now", so the row still gets the button.
- Names used across tasks: `GrantSet`, `GrantStore`, `grant(_:in:…)`, `GrantOutcome`, `grantKind(for:)`, `SizeCell`, `VolumeSection`, `ExternalVolume`, `externalVolumes()`, `measureQueue`, `openPrivacySettings`. Checked for consistency.
- Not automated, by design: the hover animation, the dialogs, the per-volume cache, the height clamp; each has a hand check with the `tccd` log command.
