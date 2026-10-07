# app-macstats — working context

MacStats, a macOS menu bar app (Swift, AppKit) with five items, CPU, GPU, RAM, Temp and Disk,
each dropping down a panel. [`README.md`](README.md) says what each shows and how to install
it; this file says how the code is arranged and how to change and release it.

## Layout

| Path | What |
|---|---|
| `Sources/MacStats/` | The app, one Swift module. One file per item (`CPU.swift`, `GPU.swift`, `RAM.swift`, `Temp.swift` with `Sensors.swift`, `SMC.swift`, `SensorCatalog.swift` and `Battery.swift`, `Disk.swift`), `MenuKit.swift` (the menu bar item, the panel window, rows, bars, gauges, sparklines, `twoLines`), `HoverTip.swift` (the panels' tooltips), `IOReport.swift` (the private counters the CPU and GPU readers use), `AppIcon.swift` (the icon, drawn in code), `main.swift` (the app delegate and the command line). |
| `Tests/MacStatsTests/main.swift` | The tests: a program that runs the built `MacStats` through its command-line flags. `make test`. |
| `docs/previews/` | The README's screenshots, taken by `scripts/previews.sh`: each panel in dark and light (real captures of the built app, with `--appearance` and `--show-panel --after --each`, the flags for screenshots), and `menubar.png`, the hero: the real menu bar from the notch to the screen's edge and the real CPU panel under its item, composed by `scripts/compose-hero.swift` over the real wallpaper (captured from macOS's wallpaper window, which sits behind every other window) and faded at the bottom (a bare strip of the bar never reads as a menu bar; the screen's top edge, the system icons and a dropdown do). Retake them when a panel's look changes. |
| `scripts/bundle.sh` | Assembles `build/MacStats.app` from the built binary: Info.plist with the version from `VERSION`, the icon, an ad-hoc signature. |
| `install.sh` | The `curl \| sh` installer and uninstaller; also what `make install` runs from a checkout. |
| `Makefile` | `app`, `install`, `uninstall`, `test`, `clean`. |
| `VERSION` | The version, `x.y.z`; stamped into the bundle and printed by `MacStats --version`. |
| `.github/workflows/test.yml` | Builds and tests on a macOS runner on every push and pull request. |
| `LICENSE`, `LICENSE-stats.txt` | MIT, and the MIT licence of Stats, from which two files are adapted. |

The Homebrew formula lives in [`csarkosh/homebrew-tap`](https://github.com/csarkosh/homebrew-tap)
(`Formula/macstats.rb`): it builds a tagged release with `make app` and installs the bundle.

## Conventions

- **Each item is one file**, with its sampler (what it reads), its item text (what the menu
  bar shows) and its panel (what drops down). What two items share goes in `MenuKit.swift`.
  A command-line flag in `main.swift` prints what each panel shows, so a change can be checked
  from a terminal and the tests can read it.
- **No permission prompts.** Nothing MacStats reads may trigger a macOS privacy prompt: no
  guarded folders (Desktop, Documents, Downloads, Music, Movies, cloud folders, other apps'
  containers, Mail, Messages, Photos), no screen recording, no input monitoring. Check a
  change with `log show --predicate 'process == "tccd" AND eventMessage CONTAINS
  "sh.csarko.MacStats"'` after running it.
- **Tooltips** are at most two short lines (`twoLines`), on every legend key; `MacStats
  --tooltips` lists them and a test fails a key without one.
- **Fixed-width items**: each menu bar item is as wide as its widest value (`100%`,
  `888 GB`, a three-digit temperature) in digits of one width, so neighbours never shift.
- **Figures are Stats'** where Stats has them (CPU ticks, memory pages, GPU statistics), so
  MacStats and Stats agree; credit Stats in a file that adapts its code.
- **Prose**: plain words in the panels and comments; no jargon a non-developer would not know
  without a tooltip explaining it.

## Changing it

```sh
make test                     # builds a debug MacStats and runs the tests against it
make app && open build/MacStats.app   # try it; quit the installed copy first (pkill -x MacStats)
make install                  # replace the installed copy with this checkout
```

A panel can be rendered off-screen without opening it: build a small `main.swift` that makes
the panel, calls `fitToContents()` and `cacheDisplay` on its `contentView`, and compile it
with every file in `Sources/MacStats/` except `main.swift`.

## Releasing

1. Bump `VERSION`, commit, tag `v<version>`, push both; create a GitHub release for the tag.
2. In `csarkosh/homebrew-tap`, point `Formula/macstats.rb` at the new tag's tarball
   (`https://github.com/csarkosh/app-macstats/archive/refs/tags/v<version>.tar.gz`) with its
   `sha256` (`curl -fsSL <url> | shasum -a 256`), and push.
3. `install.sh` installs the latest release by itself; nothing to update there.
