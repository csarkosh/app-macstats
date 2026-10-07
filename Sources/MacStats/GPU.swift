// The GPU menu bar item: "GPU" over its utilization, and a panel with two gauges
// (utilization, and GPU temperature on the chip's limits), Usage (a history chart
// and the GPU's figures, then Framerate, ML engine and Memory each with a small graph) and Top GPU
// apps. The figures are
// the ones the Stats app reads (Modules/GPU/reader.swift, MIT; see LICENSE-stats.txt
// at the repository root): the accelerator's PerformanceStatistics, and on Apple silicon
// the ML engine's power and the displays' frame swaps from IOReport.

import Cocoa
import IOKit
import Metal

// MARK: - The accelerator

struct GPUSample {
    let utilization: Double  // 0...1
    let renderer: Double
    let tiler: Double
    let memoryInUse: Double  // bytes
    let memoryAllocated: Double
    let neuralEngine: Double?  // 0...1, Apple silicon only
    let fps: Double?
}

struct GPUInfo {
    let model: String
    let cores: Int?
}

/// The accelerator's registry entry, as an owned object to release.
private func acceleratorEntry() -> io_object_t? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    let entry = IOIteratorNext(iterator)
    return entry == 0 ? nil : entry
}

private func properties(of entry: io_object_t) -> [String: Any]? {
    var dictionary: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &dictionary, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return dictionary?.takeRetainedValue() as? [String: Any]
}

func gpuInfo() -> GPUInfo? {
    guard let entry = acceleratorEntry() else { return nil }
    defer { IOObjectRelease(entry) }
    guard let props = properties(of: entry) else { return nil }
    let model = (props["model"] as? String)
        ?? (props["model"] as? Data).flatMap { String(data: $0, encoding: .ascii)?.replacingOccurrences(of: "\0", with: "") }
        ?? "GPU"
    return GPUInfo(model: model, cores: (props["gpu-core-count"] as? NSNumber)?.intValue)
}

// MARK: - The ML engine's energy and the displays' frames, from IOReport

/// The ML engine's peak power by chip, as Stats has it, so its power reads as a share.
private func neuralEnginePeakWatts() -> Double {
    switch Chip.current {
    case .m1, .m1Pro, .m1Max: return 2
    case .m1Ultra: return 4
    case .m2, .m2Pro, .m2Max: return 2.5
    case .m2Ultra: return 5
    case .m3, .m3Pro, .m3Max: return 3
    case .m3Ultra: return 6
    case .m4, .m4Pro, .m4Max: return 6
    case .m4Ultra: return 12
    case .m5, .m5Pro, .m5Max: return 8
    case .m5Ultra: return 16
    default: return 8
    }
}

/// Reads the GPU once a second: utilization and memory from the accelerator, and on
/// Apple silicon the ML engine's share (its energy over the last interval, against
/// its peak power) and frames per second (displays' frame swaps over the interval).
final class GPUSampler {
    private let energy = ReportSubscription(groups: ["Energy Model"], subGroup: nil)
    private let frames = ReportSubscription(groups: ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"], subGroup: "swap")
    private var last: (time: Date, joules: Double?, frames: Int64?)?

    func sample() -> GPUSample? {
        guard let entry = acceleratorEntry() else { return nil }
        defer { IOObjectRelease(entry) }
        guard let stats = properties(of: entry)?["PerformanceStatistics"] as? [String: Any] else { return nil }
        let percent = { (key: String) in ((stats[key] as? NSNumber)?.doubleValue ?? 0) / 100 }
        let bytes = { (key: String) in (stats[key] as? NSNumber)?.doubleValue ?? 0 }

        let now = Date()
        let joules = energy.map { report -> Double in
            report.sample().filter { $0.group == "Energy Model" && $0.name.hasPrefix("ANE") }.reduce(0) { total, channel in
                let scale: Double
                switch channel.unit.lowercased() {
                case "mj": scale = 1e-3
                case "uj", "µj": scale = 1e-6
                case "pj": scale = 1e-12
                default: scale = 1e-9
                }
                return total + Double(channel.value) * scale
            }
        }
        let frameCount = frames.map { report in
            report.sample().filter { $0.group.hasPrefix("DCP") && $0.subGroup == "swap" }.reduce(0) { $0 + $1.value }
        }
        var neuralEngine: Double?, fps: Double?
        if let last, case let elapsed = now.timeIntervalSince(last.time), elapsed > 0 {
            if let joules, let before = last.joules { neuralEngine = min(1, max(0, (joules - before) / elapsed / neuralEnginePeakWatts())) }
            if let frameCount, let before = last.frames, frameCount >= before { fps = Double(frameCount - before) / elapsed }
        }
        last = (now, joules, frameCount)

        return GPUSample(utilization: percent("Device Utilization %"), renderer: percent("Renderer Utilization %"),
                         tiler: percent("Tiler Utilization %"), memoryInUse: bytes("In use system memory"),
                         memoryAllocated: bytes("Alloc system memory"), neuralEngine: neuralEngine, fps: fps)
    }
}

/// The most memory macOS lets the GPU use (Metal's recommended working set: 11.84 GB of
/// a 16 GB Mac), or all of the Mac's memory if Metal cannot say.
let gpuMemoryLimit: Double = {
    let limit = MTLCreateSystemDefaultDevice().map { Double($0.recommendedMaxWorkingSetSize) } ?? 0
    return limit > 0 ? limit : Double(ProcessInfo.processInfo.physicalMemory)
}()

// MARK: - Apps using the GPU

struct GPUApp {
    let pid: Int32
    let name: String
    let share: Double  // 0...1 of the GPU's time
}

/// The apps using the GPU, as Activity Monitor's "% GPU" counts it: each app's GPU
/// time (summed over its connections to the GPU) since the last look, as a share of
/// the time passed.
final class GPUAppSampler {
    private var last: (time: Date, gpuTime: [Int32: Double])?

    func sample(_ count: Int = 8) -> [GPUApp] {
        guard let accelerator = acceleratorEntry() else { return [] }
        defer { IOObjectRelease(accelerator) }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        var gpuTime: [Int32: Double] = [:], names: [Int32: String] = [:]
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard let props = properties(of: child), let creator = props["IOUserClientCreator"] as? String,
                  let usage = props["AppUsage"] as? [[String: Any]] else { continue }
            // "pid 601, WindowServer"
            let parts = creator.dropFirst(4).split(separator: ",", maxSplits: 1)
            guard let first = parts.first, let pid = Int32(first) else { continue }
            gpuTime[pid, default: 0] += usage.reduce(0) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.doubleValue) ?? 0) }
            names[pid] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "pid \(pid)"
        }
        let now = Date()
        defer { last = (now, gpuTime) }
        guard let last, case let elapsed = now.timeIntervalSince(last.time) * 1e9, elapsed > 0 else { return [] }
        return gpuTime.compactMap { pid, time -> GPUApp? in
            let share = (time - (last.gpuTime[pid] ?? time)) / elapsed
            guard share > 0.0005 else { return nil }
            let short = names[pid] ?? "pid \(pid)"
            // The registry's name is cut to 16 characters; the executable's file name
            // gives it in full, used only where it starts with the cut one (a file can
            // be named otherwise, such as by a version number).
            let full = executableName(pid).flatMap { $0.hasPrefix(short) ? $0 : nil }
            return GPUApp(pid: pid, name: NSRunningApplication(processIdentifier: pid)?.localizedName ?? full ?? short,
                          share: min(1, share))
        }
        .sorted { $0.share > $1.share }
        .prefix(count).map { $0 }
    }
}

/// A process's executable name in full: the registry cuts names to 16 characters
/// ("Google Chrome He"), and helpers have no app to name them.
func executableName(_ pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: path)).lastPathComponent
}

// MARK: - The panel

/// Stats' green, yellow and red zones for utilization: from 60% and 80%.
let utilizationLimits = (warm: 0.6, hot: 0.8)

func utilizationWord(_ value: Double) -> String {
    value < utilizationLimits.warm ? "Normal" : value < utilizationLimits.hot ? "Busy" : "Heavy"
}

func formatPercent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

/// Bytes as gigabytes in the units macOS counts memory in (1 GB = 1024³ bytes), two places.
func formatGB(_ bytes: Double) -> String { String(format: "%.2f", bytes / 1_073_741_824) }

/// The chart's series and the rows coloured like them.
let gpuSeries: [(title: String, color: NSColor, value: (GPUSample) -> Double)] = [
    ("Utilization", .systemBlue, { $0.utilization }),
    ("Renderer", .systemOrange, { $0.renderer }),
    ("Tiler", .systemPink, { $0.tiler }),
]

/// The Memory sparkline's colour. The row itself has no colour dot: the dots key the
/// rows to the chart, and memory is not in it.
let gpuMemoryColor = NSColor.systemTeal
/// The ML engine and FPS sparklines' colours.
let gpuEngineColor = NSColor.systemPurple
let gpuFramesColor = NSColor.systemGreen

/// The widest value beside a graph, "120 Hz", so the graphs line up in one column.
let graphValueColumn = ceil(NSAttributedString(string: "120 Hz", attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width)

/// The fastest any display redraws (60, or 120 with ProMotion): the framerate graph's top.
var displayMaxFPS: Double { Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60) }

/// The last three minutes, a sample a second.
final class GPUHistory {
    private(set) var samples: [GPUSample] = []
    let capacity = 180

    func add(_ sample: GPUSample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// Utilization over three minutes as a blue area, with Renderer and Tiler as lines in
/// their rows' colours, newest at the right, and a time axis underneath.
final class GPUChart: NSView {
    var history: GPUHistory?
    private let plotHeight: CGFloat = 90
    private let axisHeight: CGFloat = 13

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: plotHeight + axisHeight),
            widthAnchor.constraint(equalToConstant: Panel.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 0, y: axisHeight, width: bounds.width, height: plotHeight)
        drawTimeAxis(in: NSRect(x: 2, y: 0, width: bounds.width - 4, height: axisHeight - 2), minutes: (history?.capacity ?? 180) / 60)
        let frame = NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6)
        NSColor.lightGray.withAlphaComponent(0.1).setFill()
        frame.fill()
        guard let history, history.samples.count > 1, let latest = history.samples.last else { return }
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let samples = history.samples
        let step = plot.width / CGFloat(history.capacity - 1)
        let point = { (index: Int, value: Double) in
            CGPoint(x: plot.maxX - CGFloat(samples.count - 1 - index) * step, y: plot.minY + CGFloat(min(1, value)) * plot.height)
        }
        for (index, series) in gpuSeries.enumerated() {
            let path = NSBezierPath()
            for (sampleIndex, sample) in samples.enumerated() {
                let p = point(sampleIndex, series.value(sample))
                if sampleIndex == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            if index == 0 {
                let area = path.copy() as! NSBezierPath
                area.line(to: point(samples.count - 1, 0))
                area.line(to: point(0, 0))
                area.close()
                series.color.withAlphaComponent(0.7).setFill()
                area.fill()
            } else {
                path.lineWidth = 1.5
                series.color.setStroke()
                path.stroke()
            }
        }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let text = NSAttributedString(string: "Utilization: \(formatPercent(latest.utilization))", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: right,
        ])
        let height = ceil(text.size().height)
        text.draw(with: NSRect(x: plot.minX, y: plot.maxY - height, width: plot.width - 10, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// "N min ago" at the left and "now" at the right, as the RAM chart has.
func drawTimeAxis(in row: NSRect, minutes: Int) {
    let attributes = { (alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] in
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        return [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
    }
    NSAttributedString(string: "\(minutes) min ago", attributes: attributes(.left)).draw(with: row)
    NSAttributedString(string: "now", attributes: attributes(.right)).draw(with: row)
}

/// What the GPU item shows: its utilization.
func gpuItemText(_ sample: GPUSample) -> (value: String, tooltip: String) {
    (formatPercent(sample.utilization),
     "GPU \(formatPercent(sample.utilization)) busy (\(utilizationWord(sample.utilization).lowercased())). Click for more.")
}

final class GPUPanel: StatsPanel {
    private let history: GPUHistory
    private let reader: SensorReader
    private let info = gpuInfo()
    private let utilizationGauge = GaugeView()
    private let heatGauge = GaugeView()
    private let chart = GPUChart()
    private let seriesRows = gpuSeries.map { PanelRow($0.title + ":", color: $0.color) }
    private let neuralRow = PanelRow("ML engine:")
    private let fpsRow = PanelRow("Framerate:")
    private let memoryRow = PanelRow("Memory:")
    // GPU memory in use over the last three minutes, scaled to the most macOS lets the
    // GPU use, so the bar shows how close it is to its limit.
    private let memorySparkline = Sparkline(color: gpuMemoryColor)
    // The ML engine's use over the last three minutes, 0 to 100%, and the frames the
    // displays showed, up to the fastest they redraw.
    private let engineSparkline = Sparkline(color: gpuEngineColor)
    private let framesSparkline = Sparkline(color: gpuFramesColor)
    /// "0.49 / 11.84 GB" under the Memory row: in use and the limit, right-aligned.
    private let memoryDetail = NSTextField(labelWithString: "")
    private let appRows = (0..<8).map { _ in ProcessRow() }
    private let noApps = NSTextField(labelWithString: "Measuring…")
    private let appSampler = GPUAppSampler()
    private var appTimer: Timer?

    init(history: GPUHistory, reader: SensorReader) {
        self.history = history
        self.reader = reader
        super.init(title: "GPU")
        setHeaderButtons(leading: headerButton("chart.bar.fill", "Open Activity Monitor", #selector(openActivityMonitor)),
                         trailing: nil)

        let dashboard = NSStackView(views: [utilizationGauge, heatGauge])
        dashboard.orientation = .horizontal
        dashboard.distribution = .fillEqually
        dashboard.spacing = 0
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dashboard.widthAnchor.constraint(equalToConstant: Panel.width),
            dashboard.heightAnchor.constraint(equalToConstant: 108),
        ])
        utilizationGauge.heading = "Utilization"
        heatGauge.heading = "Temperature"
        utilizationGauge.hoverTip = twoLines("How busy the GPU is: normal under 60%, busy under 80%, heavy above.")
        heatGauge.hoverTip = twoLines("The GPU's temperature, coloured on the chip's limits as in the Temp menu.")
        body.addArrangedSubview(dashboard)

        body.addArrangedSubview(separatorView("Usage"))
        chart.history = history
        body.addArrangedSubview(chart)
        body.setCustomSpacing(6, after: chart)
        // Two groups: the chart's rows, then the rows with their own small graphs
        // (Framerate, ML engine, and Memory with its GB line under it), 8 pt apart.
        for row in seriesRows { body.addArrangedSubview(row) }
        if let tiler = seriesRows.last { body.setCustomSpacing(8, after: tiler) }
        body.addArrangedSubview(fpsRow)
        body.addArrangedSubview(neuralRow)
        body.addArrangedSubview(memoryRow)
        seriesRows[0].hoverTip = twoLines("Time the GPU was busy with any work: the screen, games, video, compute.")
        seriesRows[1].hoverTip = twoLines("Time spent colouring pixels, the last step in drawing each frame.")
        seriesRows[2].hoverTip = twoLines("Time spent sorting each frame's shapes into screen tiles, before colouring them.")
        neuralRow.hoverTip = twoLines("How busy the machine-learning cores are, from their power against their peak.")
        fpsRow.hoverTip = twoLines("Frames shown per second. The graph tops out at "
            + "\(Int(displayMaxFPS)) Hz, the display's fastest.")
        for (sparkline, row) in [(engineSparkline, neuralRow), (framesSparkline, fpsRow), (memorySparkline, memoryRow)] {
            sparkline.capacity = history.capacity
            sparkline.place(in: row, valueColumn: graphValueColumn)
        }
        memoryDetail.font = .systemFont(ofSize: 10)
        memoryDetail.textColor = .labelColor
        memoryDetail.alignment = .right
        memoryDetail.translatesAutoresizingMaskIntoConstraints = false
        memoryDetail.widthAnchor.constraint(equalToConstant: Panel.width).isActive = true
        body.addArrangedSubview(memoryDetail)
        body.setCustomSpacing(2, after: memoryDetail)

        body.addArrangedSubview(separatorView("Top GPU apps"))
        let heading = ProcessRow()
        heading.name.stringValue = "App"
        heading.value.stringValue = "GPU"
        for field in [heading.name, heading.value] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .tertiaryLabelColor
        }
        body.addArrangedSubview(heading)
        noApps.font = .systemFont(ofSize: 11)
        noApps.textColor = .secondaryLabelColor
        body.addArrangedSubview(noApps)
        for row in appRows {
            row.isHidden = true
            body.addArrangedSubview(row)
        }
        if let latest = history.samples.last { update(latest) }
    }

    func update(_ sample: GPUSample) {
        chart.needsDisplay = true
        utilizationGauge.fraction = gaugeFraction(sample.utilization, low: 0, warm: utilizationLimits.warm,
                                                  hot: utilizationLimits.hot, high: 1)
        utilizationGauge.title = "\(utilizationWord(sample.utilization)) · \(formatPercent(sample.utilization))"
        utilizationGauge.subtitle = info.map { "\($0.model)\($0.cores.map { ", \($0) cores" } ?? "")" } ?? ""
        if let gpu = cpuAndGPU(reader.read()).gpu {
            heatGauge.fraction = heatFraction(of: "GPU", celsius: gpu)
            heatGauge.title = "\(heat(of: "GPU", celsius: gpu).word) · \(degrees(gpu))"
            heatGauge.subtitle = "GPU"
        }
        for (row, series) in zip(seriesRows, gpuSeries) { row.value.stringValue = formatPercent(series.value(sample)) }
        neuralRow.value.stringValue = sample.neuralEngine.map(formatPercent) ?? "–"
        fpsRow.value.stringValue = sample.fps.map { String(format: "%.0f Hz", $0) } ?? "–"
        memoryRow.value.stringValue = formatPercent(sample.memoryInUse / gpuMemoryLimit)
        memoryDetail.stringValue = "\(formatGB(sample.memoryInUse)) / \(formatGB(gpuMemoryLimit)) GB"
        memorySparkline.fractions = history.samples.map { $0.memoryInUse / gpuMemoryLimit }
        engineSparkline.fractions = history.samples.map { $0.neuralEngine ?? 0 }
        let maxFPS = displayMaxFPS
        framesSparkline.fractions = history.samples.map { ($0.fps ?? 0) / maxFPS }
        let tooltip = twoLines("GPU memory in use, of the \(formatMemory(gpuMemoryLimit)) macOS lets it use. "
            + "It holds \(formatMemory(sample.memoryAllocated)) set aside.")
        memoryRow.hoverTip = tooltip
        memoryDetail.hoverTip = tooltip
    }

    override func willOpen() {
        if let latest = history.samples.last { update(latest) }
        // GPU use is measured between two looks: the first sets the baseline, the list
        // fills a second later and refreshes every two seconds while the panel is open.
        _ = appSampler.sample()
        noApps.stringValue = "Measuring…"
        noApps.isHidden = false
        for row in appRows { row.isHidden = true }
        appTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isVisible else { return }
            self.refreshApps()
            self.appTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.isVisible { self.refreshApps() } else { self.appTimer?.invalidate() }
            }
        }
    }

    func refreshApps() {
        let apps = appSampler.sample(appRows.count)
        noApps.stringValue = "No app is using the GPU."
        noApps.isHidden = !apps.isEmpty
        for (index, row) in appRows.enumerated() {
            guard index < apps.count else { row.isHidden = true; continue }
            row.isHidden = false
            row.icon.image = processIcon(apps[index].pid)
            row.name.stringValue = apps[index].name
            row.value.stringValue = String(format: "%.1f%%", apps[index].share * 100)
        }
        if isVisible { fitToContents() }
    }

    @objc private func openActivityMonitor() {
        dismiss()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

/// Prints what the panel shows, from two looks a second apart.
func gpuReport() -> Int32 {
    let sampler = GPUSampler(), apps = GPUAppSampler()
    _ = sampler.sample()
    _ = apps.sample()
    Thread.sleep(forTimeInterval: 1)
    guard let sample = sampler.sample() else {
        FileHandle.standardError.write("Could not read the GPU.\n".data(using: .utf8)!)
        return 1
    }
    print("Usage")
    for series in gpuSeries { print(series.title + "\t" + formatPercent(series.value(sample))) }
    print("ML engine\t" + (sample.neuralEngine.map(formatPercent) ?? "–"))
    print("FPS\t" + (sample.fps.map { String(format: "%.0f", $0) } ?? "–"))
    print("Memory\t" + String(Int64(sample.memoryInUse)) + "\t" + String(Int64(sample.memoryAllocated)) + "\t" + String(Int64(gpuMemoryLimit)))
    print("Details")
    let info = gpuInfo()
    print("Model\t" + (info?.model ?? "Unknown"))
    print("Cores\t" + (info?.cores.map(String.init) ?? "Unknown"))
    print("Top GPU apps")
    for app in apps.sample() { print(app.name + "\t" + String(format: "%.1f%%", app.share * 100)) }
    return 0
}
