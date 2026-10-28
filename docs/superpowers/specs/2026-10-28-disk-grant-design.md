# Disk panel: Grant for private folders, and external disks

Design, 2026-10-28. Agreed with Cyrus in conversation; the mockup he approved is
`.superpowers/brainstorm/32158-1793212106/content/panel-grant.html` (option A).

## Intent

The Disk panel lists folders it never opens as grey `private`, with no size. That hides the
figures Cyrus wants most: how big Documents or Downloads are, and above all what is on the
external SSD he just bought, which appears only as `Volumes — private` under "my apps / files".

Two changes:

1. **Grant.** Hovering a private row that macOS guards with a one-time dialog shows a `Grant`
   button where the word `private` was. Clicking it makes MacStats open that folder once, macOS
   shows its usual permission dialog, and on Allow the folder's size appears and stays measured
   from then on.
2. **External disks.** Every external volume gets its own section at the bottom of the panel,
   named after the volume: its used and total space (readable with no permission at all) and,
   after a grant, its folders three levels deep like the startup disk's. The `Volumes` row leaves
   the startup-disk tree: nothing on an external disk is on the startup disk, so it never belonged
   in that sum.

**The promise changes.** Today the README and `AGENTS.md` promise "no permission prompts". From
now on the promise is: MacStats never causes a privacy prompt on its own; the only prompt it ever
causes is the one you ask for by clicking Grant. Both files say so.

## Goals, non-goals, anti-goals

Goals:
- A granted folder shows its real size, in the row and summed into its parents, and keeps doing
  so across restarts and remeasurements without asking again.
- The external SSD's used/free space shows immediately, with no grant; its folders after one.
- The button's appearance and disappearance follow Material Design's motion rules (below).
- Nothing changes for someone who never clicks Grant: no prompt, ever, and the panel looks as it
  does today apart from the external-disk sections and the missing `Volumes` row.

Non-goals (Cyrus, 2026-10-28):
- **No Full Disk Access.** Rows whose folder macOS never asks about with a dialog (Mail, Messages,
  Safari, other apps' containers and group containers, cloud-storage folders, the Trash, anything
  else in `privateHomeFolders` not listed under "which rows get Grant") get no Grant button. They
  stay grey `private` or `no access`, and their size column's tooltip says Finder's Get Info gives
  the size. MacStats never opens System Settings' Full Disk Access list.
- No revoking from inside MacStats. Permissions are taken away in System Settings; MacStats
  notices when the next open fails (below).

Anti-goals:
- Any prompt the user did not ask for with a click. Opening the panel, starting the app, plugging
  in a drive, a remeasurement: none of these may cause a dialog, even after grants (a granted
  folder opens silently; a revoked one fails silently).
- A grant that triggers the whole startup-disk measurement again (about a minute) before the
  folder's size appears. Only that folder is measured on the click.

## Which rows get Grant

Grant appears on a `private` row whose folder macOS guards with a **dialog** for this app:

| Row | The dialog macOS shows |
|---|---|
| `Desktop`, `Documents`, `Downloads` in a home | "MacStats would like to access files in your Documents folder." (Files and Folders), when the folder itself is opened |
| `Music`, `Movies` in a home | the media library dialog (Media & Apple Music). The folder itself opens silently; the dialog comes when the scan reaches the guarded part inside (`~/Music/Music`, `~/Movies/TV`), so it appears during the measurement, still on the click |
| An external volume's `Folders` row | "MacStats would like to access files on a removable volume." (one permission for all removable volumes) |
| A network volume's `Folders` row, if it is listed | the same, for network volumes |

Those six are the only private rows that can carry a button: the tree is three levels deep, so
`Library/Mail`, `Library/Containers`, `Library/Photos`, a Photos library in `Pictures` and the
rest of `privateHomeFolders` sit at level 4 or deeper and are never rows. The guard sets stay as
they are, so a folder that is both granted and private-by-list (a library package inside a
granted Music, say) is still skipped. The builder confirms each dialog by trying it on this Mac
from the built, bundled app (see Testing) and moves a row to the no-button group if macOS in fact
shows no dialog for it. `grantKind(for:)` is the one function that says which paths get a
button, so the command line and the tests can pin it.

## What happens on Grant

Grant means "measure this folder now, opening whatever is inside it": there is no separate
probe, the measurement is the open, and macOS shows its dialog whenever the scan first reaches
the guarded part (the folder itself for Downloads, a subfolder for Music).

1. The button shows a small spinner in its place (the row otherwise unchanged). The path is
   added to the remembered grants (below) before the scan, so the scan opens it.
2. Off the main thread, the folder is measured on its own with `scanFolders(path, depth: …)` to
   the depth left under it (a level-2 folder gets one more level, a volume gets three). The first
   time, the scan blocks while macOS shows the dialog; MacStats does nothing special to show it.
3. The result is spliced into the tree: the entry's `note` becomes nil, its `bytes` and
   `children` fill in, every ancestor's `bytes` grows by the folder's bytes, and each ancestor's
   `partial` is recomputed from what is still unmeasured below it. The row then shows its size,
   the ancestors update, and the measurement is saved as usual.
4. **Don't Allow** shows up inside that result as macOS's refusal: the scan's root cannot be
   opened (Downloads: the whole row becomes `no access`, the grant is dropped) or a part inside it
   cannot (Music: the row gets a `≥` size and the refused part shows as a `no access` child). A
   `no access` row or child that came from a refusal gets the tooltip "Allowed in System Settings
   › Privacy & Security › Files and Folders" (or "› Media & Apple Music" for the media rows), and
   the Grant button on such a row opens System Settings at that pane, because macOS never shows
   the dialog a second time. The builder finds the working `x-apple.systempreferences:` URLs for
   those panes on macOS 13–26 and falls back to the Privacy & Security pane.
5. Clicking Grant never closes the panel. If the panel is dismissed while the dialog is up
   (it loses key), the work still completes and the result shows next time it opens.

## Remembering grants

- `UserDefaults` under the app's domain: `grantedFolders`, an array of absolute paths (home
  folders, library packages), and `removableVolumesGranted` / `networkVolumesGranted` booleans,
  because macOS grants those as one permission for every such volume, not per drive. A second
  drive is measured without asking again.
- `scanFolders` takes the set of granted paths (and the two flags) and does **not** skip those; it
  lists them like any folder. Everything else in the private sets is skipped exactly as today.
- Revocation: when a folder MacStats believes granted cannot be listed, it is shown as
  `no access` (not `private`), and its entry in `grantedFolders` is dropped so the panel does not
  keep trying. Grant on that row opens System Settings as in step 4.
- Grants survive the ten-minute remeasurement and app restarts; the saved measurement
  (`folders.json`) already stores sizes, so a restart shows the granted sizes at once.
- **Grants belong to one build of the app.** macOS ties a permission to the app's code
  signature; an ad-hoc signed build (`make install`, the Homebrew tap) gets a new signature every
  time it is built, and macOS then asks again the next time that folder is opened. An automatic
  remeasurement after a rebuild would therefore prompt without a click, which the anti-goals
  forbid. So the grants are stored with the signature of the build that made them (the running
  code's `cdhash`, from `SecCodeCopySelf` + `SecCodeCopySigningInformation`), and a build whose
  signature differs treats every grant as not given: the rows show `private` with their Grant
  buttons again, and nothing is opened until one is clicked. A Developer-ID-signed MacStats (the
  release zip, `install.sh`) keeps the same designated requirement from version to version, so
  its grants carry over; the tap and `make install` re-ask after each build. `make install` may
  sign with `CODESIGN_IDENTITY` when the Developer ID is in the keychain, which makes a checkout
  build keep its grants too; the builder's call whether to wire that in now.
- **Only the app, launched as an app, opens granted folders.** macOS attributes a folder access
  to the process responsible for it, so the same binary started from a terminal would cause the
  dialog for the terminal, and a test run would too. Every command-line flag that prints
  (`--report`, `--volumes`, `--tooltips`, …) therefore treats every private folder as private,
  grants or not; the grants take effect only when the app runs its panel. The store is an
  explicit `UserDefaults(suiteName: "sh.csarko.MacStats")` so the bundled app and the bare binary
  read the same file when they need to (`--volumes` prints the remembered state without opening
  anything).

## External disks

- **Which volumes:** every mounted volume that is browsable, not the root file system, and not
  internal (`URLResourceKey`s `volumeIsBrowsable`, `volumeIsRootFileSystem`, `volumeIsInternal`;
  from `FileManager.mountedVolumeURLs`), so USB/Thunderbolt drives and SD cards. Network volumes
  are listed too when mounted. Disk images and Time Machine volumes: the builder's call; leaning
  to listing anything browsable so the rule is simple to explain.
- **One section per volume**, after "My apps / files", in mount order:
  - a separator with the volume's name, uppercase like the other separators (`CYRUSEXTSSD`);
  - a `Used:` row whose value reads `85.2 GB of 1.8 TB` (`formatSize` learns TB), and the bar
    with used in the "my apps / files" blue over the grey free rest; its tooltip:
    "`1.7 TB free. Space on this disk, not the startup disk.`" (two lines through `twoLines`).
  - before a grant: one row `Folders` with grey `private` and the Grant button on hover;
  - after: a status line `Last measured at 1:52 PM.` (and `Remeasuring…` while it measures) and an
    outline of the volume's folders, depth 3, 100 MB and over, biggest first, same cells, same
    double-click to Finder. The list is as tall as its top-level rows up to 8 rows (`Panel.row × 8`)
    and scrolls beyond; the panel refits.
- **The panel must fit the screen.** Today it is about 672 pt tall; one granted volume adds up to
  about 260 pt, and a 13.6" Air has about 920 pt under the menu bar, so one SSD can already
  overflow and two disks certainly would. `fitToContents` clamps the panel to the screen's
  visible frame under the menu bar. When it would overflow, the volume lists give way first,
  shrinking equally down to 3 rows each; if that is not enough, the startup disk's list shrinks
  from 15 rows down to 8; every list scrolls for what it no longer shows. Nothing is ever hidden
  without a scroller, and the other panels are untouched.
- Used/total come from `volumeTotalCapacity` and `volumeAvailableCapacity` of the mount point,
  which need no permission; refreshed with `refreshSpaces` every time the panel opens.
- The folder measurement of a granted volume runs when the panel opens and the last one is older
  than ten minutes, like the startup disk's, and on the header's Measure-again button. It runs
  after the startup disk's so the two never compete. `scanFolders` already stays on one device
  (`FTS_XDEV`), so a volume's scan is just `scanFolders(mountPoint)`.
- The measurement is saved per volume, keyed by volume UUID (`volumeUUIDString`, falling back to
  the name), in the same cache folder (`volumes/<uuid>.json`), so replugging shows the last figures
  at once and remeasures in the background.
- Unmount: the section disappears the next time the panel opens (`willOpen` rebuilds the list of
  sections from the mounted volumes). No live watching of mounts is needed.
- The startup-disk tree no longer lists `/Volumes` at all (it is skipped, not shown as a row).

## The Grant button

- Lives in the size column's cell, over the grey `private` text, right-aligned where the text is.
  A small rounded button (`NSButton`, `.inline` or `.rounded` bezel at small control size, title
  `Grant`, accent colour as the mockup's blue pill), 11 pt semibold, about 18 pt tall.
- **Hover:** the row under the mouse is tracked with an `NSTrackingArea` on the outline
  (`mouseMoved`, `activeAlways`, `inVisibleRect`, like `HoverTracker`). Entering a Grant-eligible
  row fades its `private` text out and the button in; leaving does the reverse. Only one row shows
  a button at a time. The row gets no other highlight.
- **Motion, Material Design** (Cyrus asked for Material's duration and timing rules; the numbers
  are my call within them): enter 150 ms, exit 75 ms, both on the standard curve
  `cubic-bezier(0.4, 0.0, 0.2, 1)` (`CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)`), with
  `NSAnimationContext` animating `alphaValue`, and a 1 pt upward settle on enter as in the mockup
  (`transform`/frame origin). Reduce Motion on: no fade, the swap is immediate.
- Tooltip on the button: "`Opens this folder once; macOS asks you to allow it. MacStats remembers your answer.`".
- Tooltip on a `private` size cell with no button: "`macOS has no dialog for this folder; Finder's Get Info gives its size.`"
- Click target is the button only; a click elsewhere on the row still does nothing (double-click
  reveals in Finder as today).

## Command line and tests

- `MacStats --volumes` prints one line per external volume, tab-separated: name, used bytes,
  total bytes, mount point, and `granted`/`private`/`no access` for its folders, from the
  remembered state; it opens nothing. On a Mac with no external disk it prints nothing, exit 0.
- `MacStats --report <folder>` is unchanged; `--report` with no folder also prints a line per
  external volume (name, used, total) after the startup disk's tree. Neither opens a granted
  folder (see "Only the app, launched as an app").
- `MacStats --grantable <path>` prints `dialog`, `none` or `not private` for a path: the rule from
  "Which rows get Grant" as one function (`grantKind(for:)`), so the tests pin it without a UI.
- Tests (in `Tests/MacStatsTests/main.swift`, run by `make test`, headless, never triggering a
  dialog): `--volumes` has the right columns and parses; `--grantable` gives `dialog` for
  `/Users/<me>/Downloads`, `none` for `/Users/<me>/Library/Mail`, `not private` for a temp folder;
  the splice (a measured folder's bytes reach its ancestors and clear `partial` when nothing else
  below is unmeasured) through `--report` on a temp tree with a fake private folder, if the builder
  can make one without touching real guarded folders; otherwise unit-style through a flag that
  reads a saved measurement and splices a given subtree. The dialog flow itself is checked by hand
  (below). The existing tooltip test keeps passing (new tooltips go through `twoLines`).

## Testing by hand

- Run the **bundled** app (`make app && open build/MacStats.app`) and quit the installed copy
  first. A binary started from a terminal inherits the terminal's permissions, so dialogs would be
  attributed to the terminal, not MacStats.
- Reset permissions between tries: `tccutil reset SystemPolicyDownloadsFolder sh.csarko.MacStats`
  (likewise `SystemPolicyDesktopFolder`, `SystemPolicyDocumentsFolder`,
  `SystemPolicyRemovableVolumes`, `SystemPolicyNetworkVolumes`, `MediaLibrary`, `Photos`).
- Confirm no unasked-for prompt: `log show --last 10m --predicate 'process == "tccd" AND
  eventMessage CONTAINS "sh.csarko.MacStats"'` after opening the panel, plugging a drive,
  restarting the app with grants in place.
- Check with the SSD (`/Volumes/CyrusExtSSD`, ExFAT): section appears, `Used` reads without a
  grant, Grant shows the removable-volume dialog, Allow lists its folders, unplug removes the
  section, replug restores it measured.

## Docs and release

- README: the intro's "asks for no permissions and causes no privacy prompts" becomes the new
  promise; the Disk section describes Grant and external disks; the command-line list gains
  `--volumes` and `--grantable`. Retake `docs/previews/disk-{dark,light}.png` with the SSD
  attached and one folder granted, so the pictures show the feature. `scripts/previews.sh` runs
  the binary straight from the shell today; for the Disk capture it must launch the bundle as an
  app (`open -a build/MacStats.app --args …`, waiting for it as the script does now) so that the
  granted folders open under MacStats's own identity and not the terminal's.
- `AGENTS.md`: the "No permission prompts" convention becomes "No prompts the user did not ask
  for": the only allowed trigger is the Grant click; everything else keeps the old rule and the
  `tccd` log check.
- `VERSION` to `1.1.0`; the release itself is Cyrus's step (the `release` workflow).

## Constraints

- Swift/AppKit, one module, the existing `Entry`/`scanFolders`/`DiskPanel` structure; what two
  panels share goes in `MenuKit.swift`. Plain words in panel text and comments (the repo's rule).
- macOS 13 and later (the bundle's minimum). Works ad-hoc signed and Developer-ID signed with the
  hardened runtime; no sandbox, no entitlements, no `Info.plist` usage strings are required for
  these dialogs (the builder adds `NSDesktopFolderUsageDescription`-style strings only if a dialog
  turns out to need one, with the same plain wording).
- The fixed-width menu bar item and the one-second samplers are untouched.

## Left to the builder

- The exact hover bookkeeping on `NSOutlineView` (cell reuse, scrolling while hovered, the button
  outliving a reload), and how the splice recomputes `partial`.
- Canonical spelling of paths in the grant store (`/Users/…` rather than the
  `/System/Volumes/Data/Users/…` the scan walks), so a remembered grant matches the path the
  scan sees.
- Whether `make install` signs with the Developer ID when it is in the keychain.
- The cache file names, the `UserDefaults` key names, the spinner in the button.
- Whether disk images and Time Machine volumes are listed.
- The System Settings URL for Files and Folders.
- Order of work; a reasonable one is: volumes section without Grant (visible value, no prompt) →
  `grantKind` + `--grantable` → hover button → the grant flow and splice → remembering grants →
  docs and previews.
