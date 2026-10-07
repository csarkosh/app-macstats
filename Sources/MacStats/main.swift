// MacStats: menu bar items drawn like the Stats app's "mini" widgets: CPU (usage, with
// gauges, history, load, clock speeds, details and top processes in its panel),
// GPU (utilization, with gauges, history, details and top GPU apps in its panel),
// RAM (memory in use, with its history and top processes in its panel),
// Temp (the hottest part, with every sensor in its panel) and Disk (free space,
// with where the rest goes in its panel). Each item lives in its own file; MenuKit.swift
// holds what they share.
//
//   make app                                # builds it into build/MacStats.app (see the Makefile)
//   MacStats                                # runs the menu bar items
//   MacStats --version                      # prints the app's version and exits
//   MacStats --show-panel cpu|gpu|ram|temp|disk[,…]  # runs, opening those panels in turn, as clicks would
//   MacStats --render cpu|gpu|ram|temp|disk out.png  # draws that menu bar item to a PNG and exits
//                                           # (with --alert, Temp as it looks when hot)
//   MacStats --write-icon <dir>.iconset     # draws the app icon at iconutil's sizes and exits
//   MacStats --tooltips                     # prints every panel's tooltips, legend keys first
//   MacStats --cpu                          # prints the CPU panel and exits
//   MacStats --gpu                          # prints the GPU panel and exits
//   MacStats --memory                       # prints the RAM panel and exits
//   MacStats --sensors                      # prints the Temp panel and exits
//   MacStats --weigh 49.8 53.0 …            # prints those temperatures' hot-weighted value
//   MacStats --heat "<row name>" <°C>       # prints the colour a Temperature row would get
//   MacStats --power-level <W>              # prints the power tier: normal, moderate or high
//   MacStats --spaces                       # prints the disk's five volume spaces
//   MacStats --legend                       # prints the Disk panel's Spaces rows, in order
//   MacStats --report [folder] [--min-mb N] # prints the Disk panel's folders

import Cocoa

/// The widest values the items show, which fix their widths so neighbours never shift:
/// a percentage, and a three-digit temperature in the Mac's unit.
let percentWidest = "100%"
let temperatureWidest = degrees(100)
let diskWidest = "888 GB"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cpu: MenuBarItem!
    private let cpuSampler = CPUSampler()
    private let cpuHistory = CPUHistory()
    private lazy var cpuPanel = CPUPanel(history: cpuHistory, reader: reader)
    private var gpu: MenuBarItem!
    private let gpuSampler = GPUSampler()
    private let gpuHistory = GPUHistory()
    private lazy var gpuPanel = GPUPanel(history: gpuHistory, reader: reader)
    private var ram: MenuBarItem!
    private let memoryHistory = MemoryHistory()
    private lazy var ramPanel = RAMPanel(history: memoryHistory)
    private var temp: MenuBarItem!
    private var disk: MenuBarItem!
    private let reader = SensorReader()
    private lazy var tempPanel = TempPanel(reader: reader)
    private lazy var diskPanel = DiskPanel()
    private let diskSampler = DiskSampler()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        cpu = MenuBarItem(autosaveName: "MacStatsCPU", label: "CPU", widest: percentWidest) { [unowned self] in cpuPanel.toggle(under: $0) }
        gpu = MenuBarItem(autosaveName: "MacStatsGPU", label: "GPU", widest: percentWidest) { [unowned self] in gpuPanel.toggle(under: $0) }
        ram = MenuBarItem(autosaveName: "MacStatsRAM", label: "RAM", widest: percentWidest) { [unowned self] in ramPanel.toggle(under: $0) }
        temp = MenuBarItem(autosaveName: "MacStatsTemp", label: "Temp", widest: temperatureWidest) { [unowned self] in tempPanel.toggle(under: $0) }
        disk = MenuBarItem(autosaveName: "MacStatsDisk", label: "Disk free", widest: diskWidest) { [unowned self] in diskPanel.toggle(under: $0) }
        refresh()
        // Every second, like Stats' CPU and GPU.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
        // "--show-panel disk,temp" opens each in turn, two seconds apart, as clicks would.
        for (index, which) in (argument(after: "--show-panel") ?? "").split(separator: ",").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 2 * Double(index)) { [unowned self] in
                if which == "cpu", let button = cpu.button { cpuPanel.toggle(under: button) }
                if which == "gpu", let button = gpu.button { gpuPanel.toggle(under: button) }
                if which == "ram", let button = ram.button { ramPanel.toggle(under: button) }
                if which == "temp", let button = temp.button { tempPanel.toggle(under: button) }
                if which == "disk", let button = disk.button { diskPanel.toggle(under: button) }
            }
        }
    }

    private func refresh() {
        if let sample = cpuSampler.sample() {
            cpuHistory.add(sample)
            let cpuText = cpuItemText(sample)
            cpu.show(cpuText.value, tooltip: cpuText.tooltip)
            if cpuPanel.isVisible { cpuPanel.update(sample) }
        }
        if let sample = gpuSampler.sample() {
            gpuHistory.add(sample)
            let gpuText = gpuItemText(sample)
            gpu.show(gpuText.value, tooltip: gpuText.tooltip)
            if gpuPanel.isVisible { gpuPanel.update(sample) }
        }
        if let usage = memoryUsage() {
            memoryHistory.add(usage)
            let ramText = ramItemText(usage)
            ram.show(ramText.value, tooltip: ramText.tooltip)
            if ramPanel.isVisible { ramPanel.update(usage) }
        }
        let readings = reader.read()
        let tempText = tempItemText(readings)
        temp.show(tempText.value, tooltip: tempText.tooltip, alert: tempText.alert)
        if tempPanel.isVisible { tempPanel.update(readings) }
        if let diskText = diskItemText(diskSampler) { disk.show(diskText.value, tooltip: diskText.tooltip) }
    }
}

// MARK: - Command line

let arguments = CommandLine.arguments
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--") else { return nil }
    return arguments[index + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

if arguments.contains("--render") {
    guard let index = arguments.firstIndex(of: "--render"), index + 2 < arguments.count else {
        fail("usage: MacStats --render cpu|gpu|ram|temp|disk <out.png>")
    }
    let path = arguments[index + 2]
    switch arguments[index + 1] {
    case "cpu":
        let sampler = CPUSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.5)
        guard let sample = sampler.sample() else { fail("Could not read the CPU.") }
        exit(renderMiniView(label: "CPU", value: cpuItemText(sample).value, widest: percentWidest, to: path))
    case "gpu":
        guard let sample = GPUSampler().sample() else { fail("Could not read the GPU.") }
        exit(renderMiniView(label: "GPU", value: gpuItemText(sample).value, widest: percentWidest, to: path))
    case "ram":
        guard let usage = memoryUsage() else { fail("Could not read memory use.") }
        exit(renderMiniView(label: "RAM", value: ramItemText(usage).value, widest: percentWidest, to: path))
    case "temp":
        let text = tempItemText(SensorReader().read())
        exit(renderMiniView(label: "Temp", value: text.value, widest: temperatureWidest, alert: text.alert || arguments.contains("--alert"), to: path))
    case "disk":
        guard let text = diskItemText(DiskSampler()) else { fail("Could not read the startup disk's capacity.") }
        exit(renderMiniView(label: "Disk free", value: text.value, widest: diskWidest, to: path))
    default: fail("usage: MacStats --render cpu|gpu|ram|temp|disk <out.png>")
    }
}
/// Every tooltip in every panel, as "<panel>\t<key or other>\t<name>\t<lines>\t<widest line>\t<text>":
/// legend keys (rows with a coloured square, and chart legend lines) and every other view
/// with one, so a test can see every key has one and none runs past two lines.
func tooltipsReport() -> Int32 {
    _ = NSApplication.shared
    let reader = SensorReader()
    let temp = TempPanel(reader: reader)
    temp.update(reader.read())
    let gpu = GPUPanel(history: GPUHistory(), reader: reader)
    if let sample = GPUSampler().sample() { gpu.update(sample) }
    let panels: [(String, StatsPanel)] = [
        ("CPU", CPUPanel(history: CPUHistory(), reader: reader)), ("GPU", gpu),
        ("RAM", RAMPanel(history: MemoryHistory())), ("Temp", temp), ("Disk", DiskPanel()),
    ]
    func tips(in view: NSView) -> [(kind: String, name: String, tip: String)] {
        if let row = view as? PanelRow, row.isKey {
            return [("key", row.label.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: ":")), row.hoverTip ?? "")]
        }
        if let line = view as? LegendLine { return [("key", line.title, line.hoverTip ?? "")] }
        let own: [(kind: String, name: String, tip: String)] = view.hoverTip.map { tip in
            [("other", (view as? PanelRow)?.label.stringValue ?? String(describing: type(of: view)), tip)]
        } ?? []
        return own + view.subviews.flatMap(tips)
    }
    for (name, panel) in panels {
        for tip in tips(in: panel.contentView!) {
            let lines = tip.tip.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let widest = Int((lines.map(tooltipWidth).max() ?? 0).rounded(.up))
            print([name, tip.kind, tip.name, String(lines.count), String(widest),
                   tip.tip.replacingOccurrences(of: "\n", with: " / ")].joined(separator: "\t"))
        }
    }
    return 0
}

if arguments.contains("--version") {
    // Stamped into Info.plist by scripts/bundle.sh from VERSION; a bare binary has none.
    print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unbundled")
    exit(0)
}
if arguments.contains("--tooltips") {
    exit(tooltipsReport())
}
if let directory = argument(after: "--write-icon") {
    exit(writeIconSet(to: directory))
}
if arguments.contains("--cpu") {
    exit(cpuReport())
}
if arguments.contains("--gpu") {
    exit(gpuReport())
}
if arguments.contains("--memory") {
    exit(memoryReport())
}
if arguments.contains("--sensors") {
    exit(sensorsReport())
}
if let index = arguments.firstIndex(of: "--power-level") {
    guard index + 1 < arguments.count, let watts = Double(arguments[index + 1]) else {
        fail("usage: MacStats --power-level <W>")
    }
    print(powerLevel(watts: watts).rawValue)
    exit(0)
}
if let index = arguments.firstIndex(of: "--heat") {
    guard index + 2 < arguments.count, let celsius = Double(arguments[index + 2]) else {
        fail("usage: MacStats --heat <row name> <°C>")
    }
    print(heat(of: arguments[index + 1], celsius: celsius).rawValue)
    exit(0)
}
if let index = arguments.firstIndex(of: "--weigh") {
    let values = arguments[(index + 1)...].compactMap(Double.init)
    guard !values.isEmpty else { fail("usage: MacStats --weigh <°C> <°C> …") }
    print(String(format: "%.2f", hotWeighted(values)))
    exit(0)
}
if arguments.contains("--legend") {
    guard let now = spaceRowsNow() else { exit(1) }
    for row in now.rows { print([row.title, row.colorName, String(row.bytes)].joined(separator: "\t")) }
    exit(0)
}
if arguments.contains("--spaces") {
    let spaces = volumeSpaces()
    for space in spaces { print(space.title + "\t" + formatSize(space.bytes)) }
    exit(spaces.isEmpty ? 1 : 0)
}
if arguments.contains("--report") {
    let minimumBytes = argument(after: "--min-mb").flatMap(Int64.init).map { $0 * 1_000_000 } ?? defaultMinimumBytes
    exit(diskReport(folder: argument(after: "--report"), minimumBytes: minimumBytes))
}

// Tooltips appear after 0.75 s rather than AppKit's 1.5 s. Registered, not set, so a
// delay the user chose themselves (NSInitialToolTipDelay, in ms) still wins.
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 750])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
