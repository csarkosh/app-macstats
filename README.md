# MacStats

Five menu bar items for a Mac, each a small label over a value, each dropping down a panel
that explains it:

| CPU | GPU | RAM | Temp | Disk free |
|---|---|---|---|---|
| `12%` usage | `84%` utilization | `89%` of memory in use | `185°` the hottest part | `75 GB` free |

They keep one width whatever they show, so nothing beside them shifts as values change. Every
item updates every second, together for well under 1% of one core. MacStats asks for no
permissions and causes no privacy prompts: it never opens the folders macOS guards (Desktop,
Documents, Downloads, Photos, Mail, other apps' data), and reads sensors and the GPU through
public APIs plus the same private ones the [Stats](https://github.com/exelban/stats) app reads.

Built for Apple silicon (Macs with an M1 or later); an Intel Mac gets the same items from the
sensors its chip reports, untested.

## Install

With the Xcode Command Line Tools (`xcode-select --install`), either:

```sh
curl -fsSL https://raw.githubusercontent.com/csarkosh/app-macstats/main/install.sh | sh
```

which builds MacStats on your Mac, puts it in `~/Applications`, and starts it now and at
every login (a "Background Items Added" notice from macOS is information only), or:

```sh
brew install csarkosh/tap/macstats
brew services start macstats
```

Use one or the other, or two copies run. To remove: `install.sh --uninstall` (the script
again with that flag), or `brew services stop macstats && brew uninstall macstats`.

Right-click any item for Quit. Menu bar positions are macOS's: drag an item with ⌘ held to
move it. The items are named `MacStatsCPU`, `MacStatsGPU`, `MacStatsRAM`, `MacStatsTemp` and
`MacStatsDisk` for anyone scripting their places.

## The panels

Each panel opens at menu level, above every window whichever app is in front; opening one
closes any other, and a click anywhere outside closes it. Every legend key (a row with a
coloured square, or a chart's legend) has a tooltip saying what it is; tooltips appear after
0.75 s, stay as long as the pointer stays on the item, and are at most two short lines.

**CPU.** Two gauges: usage (normal under 60%, busy under 80%, heavy above) and the CPU's
temperature on the chip's limits. *Usage*: a three-minute chart with System (red) and User
(blue) stacked and Idle the space above, then those rows. *Load & frequency*: two small
three-minute charts, "Core load" (the 1-minute load average as a share of the cores, a dashed
line at 100%: above it tasks were queuing) and "Core frequency" (each core type's clock speed
against its own top speed, so a line near the top means those cores ran flat out), each with
its legend under it, `Load 31% of cores`, `P-cores 3.68 of 4.46 GHz`. *Top processes*: the
eight busiest, as `ps` counts them, refreshed every two seconds; the header's icon opens
Activity Monitor.

**GPU.** The same two gauges for the GPU. *Usage*: a three-minute chart of utilization with
Renderer and Tiler as lines, those three rows, then Framerate (`62 Hz`, the frames the
displays showed), ML engine (how busy the machine-learning cores are) and Memory (the GPU's
memory in use as a share of the most macOS lets it use, `0.49 / 11.84 GB`), each with a small
three-minute graph. *Top GPU apps*: each app's share of GPU time over the last two seconds,
as Activity Monitor's "% GPU" counts it.

**RAM.** *Usage*: a three-minute chart with App, Wired and Compressed stacked and Free on top,
in the same colours as the rows under it, then Used with a bar, a row per part, and Swap with
a small graph of the last three minutes against the Mac's memory. The figures are the ones
Activity Monitor and Stats show. *Top processes*: the eight using the most memory.

**Temp.** Two gauges: the hottest part on that part's own limits, and the Mac's power draw in
tiers sized to the Mac (for an M4 MacBook Air: normal under 10 W, moderate under 20 W, high
above). *Temperature*: one row per part of the Mac, hottest first, with the numbered sensors
grouped ("CPU performance core 1" to "4" are one row, weighted toward the hottest); each
row's square turns yellow and red at limits set per part, because parts differ: chips from
85 °C and 100 °C, the battery from 35 °C and 40 °C, the SSD from 50 °C and 70 °C, anything else
from 60 °C and 80 °C. *Power*: Total, Battery, Charger (while connected), the internal supply,
and Battery left (`42.1/53.3 Wh (79%)`). *Fans*, on a Mac with any.

**Disk.** *Spaces*: Used with a bar split by colour, then a row for each part, biggest first
and Free last: macOS system, update/boot, recovery, swap, my apps / files, other, Purgeable
(space macOS frees on its own, counted as free in the menu bar as Finder does) and Free, from
`diskutil`'s APFS volumes. *My apps / files*: that space broken down into folders three levels
deep (100 MB and over, biggest first, an app as one row), measured by allocated blocks like
`du -x`; that takes about a minute, so the panel keeps the last measurement for ten minutes
and shows it (with "Remeasuring…") while it measures again. Private folders are listed by
name but never opened, so they show no size and a folder holding one shows `≥`; double-click
a folder to show it in Finder, where Get Info gives a private folder's size.

## From a terminal

`MacStats` (in `~/Applications/MacStats.app/Contents/MacOS/`) also prints what the panels
show, for scripts and agents:

```
MacStats --cpu | --gpu | --memory | --sensors    # a panel's figures, tab-separated
MacStats --spaces | --legend | --report [folder]  # the Disk panel's spaces, rows, folders
MacStats --render cpu|gpu|ram|temp|disk out.png   # draws that menu bar item
MacStats --tooltips                                # every panel's tooltips
MacStats --heat "<row>" <°C> | --weigh <°C …> | --power-level <W>
MacStats --show-panel cpu,disk                     # runs, opening those panels as clicks would
MacStats --version
```

## Building

A Swift package that needs only the Command Line Tools:

```sh
make app        # build/MacStats.app
make install    # the same as the curl script, from this checkout
make test       # builds a debug MacStats and runs Tests/MacStatsTests against it
```

The tests are a program rather than XCTest, which the Command Line Tools do not ship. Each
feature is one file in `Sources/MacStats/` (`CPU.swift`, `GPU.swift`, `RAM.swift`,
`Temp.swift`, `Disk.swift`), with `MenuKit.swift` for what the items and panels share and
`HoverTip.swift` for the tooltips; `main.swift` starts the items and holds the command line.
See [AGENTS.md](AGENTS.md) for how the pieces fit.

## Credits and licence

MIT; see [LICENSE](LICENSE). `SMC.swift` and `SensorCatalog.swift` are adapted from
[Stats](https://github.com/exelban/stats) by Serhiy Mytrovtsiy (MIT,
[LICENSE-stats.txt](LICENSE-stats.txt)), and the CPU, GPU and memory figures are read the way
Stats reads them. The menu bar items are drawn like Stats' "mini" widgets, and the panels in
its style, because Stats is the app this grew out of: it shows the pieces Stats could not show
as wanted (free disk space over a label, temperatures grouped by part, memory and GPU charts
with every part its own colour).
