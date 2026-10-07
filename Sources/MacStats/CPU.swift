// The CPU menu bar item: "CPU" over its usage, and a panel with two gauges (usage,
// and CPU temperature on the chip's limits), Usage (System and User stacked over three
// minutes, and each core type), Load & frequency (two small charts) and Top processes. The figures are the ones the Stats app reads
// (Modules/CPU/readers.swift and Kit/plugins/SystemKit.swift, MIT; see
// LICENSE-stats.txt at the repository root).

import Cocoa
import IOKit

// MARK: - The cores

/// A kind of core on Apple silicon, its cores' numbers and its clock steps in MHz.
struct CoreType {
    let name: String  // "Efficiency cores"
    let short: String  // "E", for the frequency chart's key
    let channel: String  // its IOReport channels' prefix, "ECPU"
    let color: NSColor  // Stats' colour for it
    let about: String  // what these cores are, for the legend's tooltip: "fast cores, for the work you wait on"
    let cores: [Int]
    let steps: [Double]
}

private func registryData(_ entry: io_object_t, _ key: String) -> Data? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
}

private func registryName(_ entry: io_object_t) -> String {
    var name = [CChar](repeating: 0, count: 128)
    IORegistryEntryGetName(entry, &name)
    return String(cString: name)
}

private var isM5OrNewer: Bool { [Chip.m5, .m5Pro, .m5Max, .m5Ultra].contains(Chip.current) }
private var isM4OrNewer: Bool { isM5OrNewer || [Chip.m4, .m4Pro, .m4Max, .m4Ultra].contains(Chip.current) }

/// The core types of this Mac, efficiency first; empty on an Intel Mac. Each core's
/// type is its cluster's letter in the registry. From M5 on, Apple renamed them: E is
/// efficiency, M performance and P the "super" cores.
let coreTypes: [CoreType] = {
    var clusters: [String: [Int]] = [:]
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            let name = registryName(child)
            guard name.hasPrefix("cpu"), let id = Int(name.dropFirst(3)),
                  let letter = registryData(child, "cluster-type").flatMap({ String(data: $0, encoding: .utf8) })?
                    .trimmingCharacters(in: .controlCharacters.union(.whitespaces)) else { continue }
            clusters[letter, default: []].append(id)
        }
    }

    // The clock steps of each cluster, from the power manager's voltage tables: each
    // step is 8 bytes, its first four the frequency (in kHz from M4 on, in Hz before).
    var tables: [String: Data] = [:]
    if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS {
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard registryName(device) == "pmgr" else { continue }
            for key in ["voltage-states1-sram", "voltage-states5-sram", "voltage-states22-sram"] {
                tables[key] = registryData(device, key)
            }
        }
        IOObjectRelease(iterator)
    }
    let steps = { (key: String) -> [Double] in
        guard let data = tables[key] else { return [] }
        let divisor: Double = isM4OrNewer ? 1_000 : 1_000_000
        return stride(from: 0, to: data.count - 3, by: 8).map { offset in
            Double(data[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }) / divisor
        }
    }

    let efficiency = ("E", "Efficiency cores", "E", "ECPU", NSColor.systemTeal, "voltage-states1-sram",
                      "low-power cores, for background work")
    let performance = "fast cores, for the work you wait on"
    let kinds: [(letter: String, name: String, short: String, channel: String, color: NSColor, table: String, about: String)] =
        isM5OrNewer
        ? [efficiency, ("M", "Performance cores", "P", "MCPU", .systemIndigo, "voltage-states22-sram", performance),
           ("P", "Super cores", "S", "PCPU", .systemOrange, "voltage-states5-sram",
            "fastest cores, for the heaviest work")]
        : [efficiency, ("P", "Performance cores", "P", "PCPU", .systemIndigo, "voltage-states5-sram", performance)]
    return kinds.compactMap { kind in
        guard let cores = clusters[kind.letter] else { return nil }
        return CoreType(name: kind.name, short: kind.short, channel: kind.channel, color: kind.color, about: kind.about,
                        cores: cores.sorted(), steps: steps(kind.table))
    }
}()

// MARK: - Reading the CPU

struct CPUSample {
    let system: Double  // 0...1
    let user: Double
    let idle: Double
    /// Each core type's usage, in `coreTypes`' order.
    let coreUsage: [Double]
    /// Each core type's average clock speed over the last interval in MHz, in
    /// `coreTypes`' order; nil until there are two readings, or without IOReport.
    let frequencies: [Double]?
    /// The 1-minute load average when read.
    let load: Double?

    var usage: Double { system + user }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return String(cString: value)
}

/// "Apple M4".
let cpuModel = sysctlString("machdep.cpu.brand_string") ?? "CPU"

/// The 1, 5 and 15 minute load averages: how many tasks wanted a core, on average.
func loadAverages() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) == 3 ? loads : []
}

/// Reads the CPU once a second, as Stats does: System, User and Idle from all the
/// cores' tick counts since the last reading (User without "nice" time, as Stats has
/// it), each core type's usage from its cores' ticks, and each core type's clock
/// speed from the time its cluster spent at each clock step.
final class CPUSampler {
    private var lastCores: [[UInt32]] = []
    private let clockStates = ReportSubscription([("CPU Stats", "CPU Complex Performance States"),
                                                  ("CPU Stats", "CPU Core Performance States")])
    private var lastResidencies: [String: [Int64]] = [:]

    func sample() -> CPUSample? {
        let cores = coreTicks()
        guard !cores.isEmpty else { return nil }
        defer { lastCores = cores }
        let frequencies = clockSpeeds()
        guard lastCores.count == cores.count else { return nil }

        // System, User and Idle from the cores' ticks added up. macOS's whole-CPU counts
        // (HOST_CPU_LOAD_INFO, which Stats reads) are the same sum, but it updates them in
        // bursts, at times not for 0.9 s, so two readings close together could match and
        // give nothing; each core's counts move with every reading.
        let difference = { (state: Int) in
            zip(cores, self.lastCores).reduce(0.0) { $0 + Double($1.0[state] &- $1.1[state]) }
        }
        let user = difference(0), system = difference(1), idle = difference(2), nice = difference(3)
        let ticks = user + system + idle + nice
        guard ticks > 0 else { return nil }

        // A core's usage: its user, system and nice ticks over all its ticks.
        let coreUsage = { (index: Int) -> Double? in
            guard index < cores.count, index < self.lastCores.count else { return nil }
            let now = cores[index], then = self.lastCores[index]
            let delta = (0..<4).map { Double(now[$0] &- then[$0]) }
            let total = delta.reduce(0, +)
            return total > 0 ? min(1, (delta[0] + delta[1] + delta[3]) / total) : nil
        }
        let typeUsage = coreTypes.map { type -> Double in
            let usages = type.cores.compactMap(coreUsage)
            return usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
        }
        return CPUSample(system: system / ticks, user: user / ticks, idle: idle / ticks,
                         coreUsage: typeUsage, frequencies: frequencies, load: loadAverages().first)
    }

    /// Each core's user, system, idle and nice ticks so far, by core number.
    private func coreTicks() -> [[UInt32]] {
        var processors: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(processors)).map { core in
            [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map { UInt32(bitPattern: info[core * states + Int($0)]) }
        }
    }

    /// Each core type's average clock speed since the last reading. A channel's time at
    /// each clock step, after its idle and off states, weights that step's speed, as
    /// Stats computes it; a cluster that was idle throughout reads its lowest step.
    private func clockSpeeds() -> [Double]? {
        guard let clockStates, !coreTypes.isEmpty else { return nil }
        var speeds: [String: [Double]] = [:]
        var residencies: [String: [Int64]] = [:]
        for channel in clockStates.sample() where channel.group == "CPU Stats" && !channel.states.isEmpty {
            let key = channel.subGroup + "/" + channel.name
            let now = channel.states.map(\.residency)
            residencies[key] = now
            guard let then = lastResidencies[key], then.count == now.count,
                  let type = coreTypes.first(where: { channel.name.hasPrefix($0.channel) }), !type.steps.isEmpty,
                  let offset = channel.states.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.name) }) else { continue }
            let delta = zip(now, then).map { Double($0 - $1) }
            let active = delta[offset...].reduce(0, +)
            var speed = 0.0
            if active > 0 {
                for (step, mhz) in type.steps.enumerated() where offset + step < delta.count {
                    speed += delta[offset + step] / active * mhz
                }
            }
            speeds[type.channel, default: []].append(max(speed, type.steps.min() ?? 0))
        }
        defer { lastResidencies = residencies }
        guard !lastResidencies.isEmpty else { return nil }
        let result = coreTypes.map { type -> Double in
            let list = speeds[type.channel] ?? []
            return list.isEmpty ? 0 : list.reduce(0, +) / Double(list.count)
        }
        return result.contains(where: { $0 > 0 }) ? result : nil
    }
}

/// All cores' average clock speed: each core type's, weighted by its number of cores.
func allCoresSpeed(_ speeds: [Double]) -> Double {
    let counts = coreTypes.map { Double($0.cores.count) }
    let total = counts.reduce(0, +)
    return total > 0 ? zip(speeds, counts).reduce(0) { $0 + $1.0 * $1.1 } / total : 0
}

// MARK: - Top processes

struct CPUProcess {
    let pid: Int32
    let name: String
    let usage: Double  // percent of one core, as ps reports it
}

/// The processes using the CPU most, as Stats lists them: `ps`'s %CPU, which macOS
/// averages over the last minute or so, highest first.
func topCPUProcesses(_ count: Int = 8) -> [CPUProcess] {
    guard let data = runTool("/bin/ps", ["-Aceo", "pid,pcpu,comm", "-r"]), let output = String(data: data, encoding: .utf8)
    else { return [] }
    return output.split(separator: "\n").dropFirst().prefix(count).compactMap { line in
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let usage = Double(fields[1].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? String(fields[2])
        return CPUProcess(pid: pid, name: name, usage: usage)
    }
}

// MARK: - The panel

/// The chart's bands, bottom to top, and the rows coloured like them: Stats' colours.
let cpuParts: [(title: String, color: NSColor, value: (CPUSample) -> Double)] = [
    ("System", .systemRed, { $0.system }),
    ("User", .systemBlue, { $0.user }),
]
let cpuIdleColor = NSColor.lightGray.withAlphaComponent(0.5)

/// The last three minutes, a sample a second.
final class CPUHistory {
    private(set) var samples: [CPUSample] = []
    let capacity = 180

    func add(_ sample: CPUSample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// System and User stacked over three minutes, newest at the right, Idle the space
/// above them, with a time axis underneath.
final class CPUChart: NSView {
    var history: CPUHistory?
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
        let x = { (index: Int) in plot.maxX - CGFloat(samples.count - 1 - index) * step }
        let y = { (fraction: Double) in plot.minY + CGFloat(min(1, fraction)) * plot.height }
        var below = [Double](repeating: 0, count: samples.count)
        for part in cpuParts {
            let above = zip(below, samples).map { $0 + part.value($1) }
            let band = NSBezierPath()
            band.move(to: CGPoint(x: x(0), y: y(below[0])))
            for index in samples.indices { band.line(to: CGPoint(x: x(index), y: y(above[index]))) }
            for index in samples.indices.reversed() { band.line(to: CGPoint(x: x(index), y: y(below[index]))) }
            band.close()
            part.color.withAlphaComponent(0.8).setFill()
            band.fill()
            below = above
        }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let text = NSAttributedString(string: "Usage: \(formatPercent(latest.usage))", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: right,
        ])
        let height = ceil(text.size().height)
        text.draw(with: NSRect(x: plot.minX, y: plot.maxY - height, width: plot.width - 10, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A small chart of the last three minutes, half the panel wide, under a small heading;
/// its legend and values are rows below it, as the Usage chart's are. Each series is a
/// filled area or a line, on one scale; a missing sample leaves a gap.
final class MiniChart: NSView {
    /// The heading above the chart ("Load").
    var title = ""
    var series: [(values: [Double?], color: NSColor, filled: Bool)] = [] { didSet { needsDisplay = true } }
    var scale = 1.0
    /// A dashed line across the chart at this value, labelled at its right ("100%").
    var marker: (value: Double, label: String)?
    var capacity = 180
    private let titleHeight: CGFloat = 15

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: 84)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(with: NSRect(x: 2, y: bounds.maxY - titleHeight + 2, width: bounds.width - 4, height: titleHeight - 2))
        let plot = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - titleHeight)
        let frame = NSBezierPath(roundedRect: plot, xRadius: 5, yRadius: 5)
        NSColor.lightGray.withAlphaComponent(0.1).setFill()
        frame.fill()
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let step = plot.width / CGFloat(capacity - 1)
        for series in self.series {
            let values = series.values
            let point = { (index: Int, value: Double) in
                CGPoint(x: plot.maxX - CGFloat(values.count - 1 - index) * step,
                        y: plot.minY + CGFloat(min(1, max(0, value / self.scale))) * plot.height)
            }
            // Runs of samples without a gap, each drawn on its own.
            var runs: [[(Int, Double)]] = [[]]
            for (index, value) in values.enumerated() {
                if let value { runs[runs.count - 1].append((index, value)) } else if !runs[runs.count - 1].isEmpty { runs.append([]) }
            }
            for run in runs where run.count > 1 {
                let path = NSBezierPath()
                path.move(to: point(run[0].0, run[0].1))
                for (index, value) in run.dropFirst() { path.line(to: point(index, value)) }
                if series.filled {
                    path.line(to: point(run[run.count - 1].0, 0))
                    path.line(to: point(run[0].0, 0))
                    path.close()
                    series.color.withAlphaComponent(0.75).setFill()
                    path.fill()
                } else {
                    path.lineWidth = 1.5
                    series.color.setStroke()
                    path.stroke()
                }
            }
        }
        if let marker {
            let y = min(plot.maxY - 1, plot.minY + CGFloat(marker.value / scale) * plot.height)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.line(to: CGPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            line.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke()
            line.stroke()
            let label = NSAttributedString(string: marker.label, attributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: plot.maxX - size.width - 4, y: y - size.height - 1))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The load chart's colour.
let loadColor = NSColor.systemPink

/// What the CPU item shows: its usage.
func cpuItemText(_ sample: CPUSample) -> (value: String, tooltip: String) {
    (formatPercent(sample.usage),
     "CPU \(formatPercent(sample.usage)) busy (\(utilizationWord(sample.usage).lowercased())). Click for more.")
}

func formatMHz(_ mhz: Double) -> String { "\(Int(mhz.rounded())) MHz" }

/// MHz as GHz, without the unit: "3.68".
func formatGHz(_ mhz: Double) -> String { String(format: "%.2f", mhz / 1000) }

final class CPUPanel: StatsPanel {
    private let history: CPUHistory
    private let reader: SensorReader
    private let usageGauge = GaugeView()
    private let heatGauge = GaugeView()
    private let chart = CPUChart()
    private let partRows = cpuParts.map { PanelRow($0.title + ":", color: $0.color) }
    private let idleRow = PanelRow("Idle:", color: cpuIdleColor)
    /// Load and frequency share the panel's width, each chart with its legend under it.
    private static let halfWidth = (Panel.width - 10) / 2
    private let loadChart = MiniChart(width: halfWidth)
    private let frequencyChart = MiniChart(width: halfWidth)
    private let loadLegend = LegendLine("Load", color: loadColor, width: halfWidth)
    private let speedLegends = coreTypes.map { LegendLine("\($0.short)-cores", color: $0.color, width: halfWidth) }
    private let processRows = (0..<8).map { _ in ProcessRow() }
    private var processTimer: Timer?

    init(history: CPUHistory, reader: SensorReader) {
        self.history = history
        self.reader = reader
        super.init(title: "CPU")
        setHeaderButtons(leading: headerButton("chart.bar.fill", "Open Activity Monitor", #selector(openActivityMonitor)),
                         trailing: nil)

        let dashboard = NSStackView(views: [usageGauge, heatGauge])
        dashboard.orientation = .horizontal
        dashboard.distribution = .fillEqually
        dashboard.spacing = 0
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dashboard.widthAnchor.constraint(equalToConstant: Panel.width),
            dashboard.heightAnchor.constraint(equalToConstant: 108),
        ])
        usageGauge.heading = "Usage"
        heatGauge.heading = "Temperature"
        usageGauge.subtitle = "\(cpuModel), \(ProcessInfo.processInfo.processorCount) cores"
        usageGauge.hoverTip = twoLines("How busy the CPU is: normal under 60%, busy under 80%, heavy above.")
        heatGauge.hoverTip = twoLines("The CPU's temperature, coloured on the chip's limits as in the Temp menu.")
        body.addArrangedSubview(dashboard)

        body.addArrangedSubview(separatorView("Usage"))
        chart.history = history
        body.addArrangedSubview(chart)
        body.setCustomSpacing(6, after: chart)
        for row in partRows + [idleRow] { body.addArrangedSubview(row) }
        partRows[0].hoverTip = twoLines("Time spent running macOS itself: the kernel and drivers working for apps.")
        partRows[1].hoverTip = twoLines("Time spent running apps. Top processes below shows which ones.")
        idleRow.hoverTip = twoLines("Time with nothing to run. Idle cores sleep, saving heat and battery.")

        body.addArrangedSubview(separatorView("Load & frequency"))
        let column = { (chart: MiniChart, legend: [LegendLine]) -> NSStackView in
            let stack = NSStackView(views: [chart] + legend)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.setCustomSpacing(5, after: chart)
            return stack
        }
        let charts = NSStackView(views: [column(loadChart, [loadLegend]), column(frequencyChart, speedLegends)])
        charts.orientation = .horizontal
        charts.alignment = .top
        charts.spacing = 10
        charts.translatesAutoresizingMaskIntoConstraints = false
        charts.widthAnchor.constraint(equalToConstant: Panel.width).isActive = true
        body.addArrangedSubview(charts)
        loadChart.title = "Core load"
        frequencyChart.title = "Core frequency"
        loadChart.capacity = history.capacity
        frequencyChart.capacity = history.capacity
        let cores = ProcessInfo.processInfo.processorCount
        loadChart.hoverTip = twoLines("The last 3 minutes of core load. Above the dashed 100% line, tasks had to wait.")
        frequencyChart.hoverTip = twoLines("Each core type's speed over the last 3 minutes, against its top speed.")
        loadLegend.hoverTip = twoLines("Tasks running on or waiting for the \(cores) cores, as a share of them. Over 100%, tasks wait.")
        for (legend, type) in zip(speedLegends, coreTypes) {
            legend.hoverTip = twoLines("The \(type.cores.count) \(type.about). Speed now, of their top speed.")
        }

        body.addArrangedSubview(separatorView("Top processes"))
        let heading = ProcessRow()
        heading.name.stringValue = "Process"
        heading.value.stringValue = "CPU"
        for field in [heading.name, heading.value] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .tertiaryLabelColor
        }
        body.addArrangedSubview(heading)
        for row in processRows { body.addArrangedSubview(row) }
        if let latest = history.samples.last { update(latest) }
    }

    func update(_ sample: CPUSample) {
        chart.needsDisplay = true
        usageGauge.fraction = gaugeFraction(sample.usage, low: 0, warm: utilizationLimits.warm, hot: utilizationLimits.hot, high: 1)
        usageGauge.title = "\(utilizationWord(sample.usage)) · \(formatPercent(sample.usage))"
        if let cpu = cpuAndGPU(reader.read()).cpu {
            heatGauge.fraction = heatFraction(of: "CPU", celsius: cpu)
            heatGauge.title = "\(heat(of: "CPU", celsius: cpu).word) · \(degrees(cpu))"
            heatGauge.subtitle = "CPU"
        }
        for (row, part) in zip(partRows, cpuParts) { row.value.stringValue = formatPercent(part.value(sample)) }
        idleRow.value.stringValue = formatPercent(sample.idle)
        updateCharts(sample)
    }

    /// Load and frequency: the charts from the history, their legends from now.
    private func updateCharts(_ sample: CPUSample) {
        let samples = history.samples
        // A load average counts the tasks running on a core or waiting for one, so it
        // reads as a share of the cores: 100% means every core was wanted, above it tasks
        // were queuing. The chart reaches a little past 100%, or past the peak if higher,
        // so the dashed 100% line sits inside it.
        let cores = Double(ProcessInfo.processInfo.processorCount)
        let loads = loadAverages()
        let shares = samples.map { $0.load.map { $0 / cores } }
        loadChart.scale = max(1, shares.compactMap { $0 }.max() ?? 0) * 1.15
        loadChart.marker = (1, "100%")
        loadChart.series = [(shares, loadColor, true)]
        loadLegend.value.stringValue = loads.first.map { formatPercent($0 / cores) + " of cores" } ?? "–"

        // Each core type against its own top speed, so a line near the top is flat out
        // (the chart reaches a little past it, so that line does not sit on the edge).
        frequencyChart.scale = 1.08
        frequencyChart.series = coreTypes.enumerated().map { index, type in
            let top = type.steps.max() ?? 0
            return (samples.map { sample in sample.frequencies.flatMap { top > 0 ? $0[index] / top : nil } }, type.color, false)
        }
        for (index, (legend, type)) in zip(speedLegends, coreTypes).enumerated() {
            let top = type.steps.max().map(formatGHz) ?? "–"
            legend.value.stringValue = (sample.frequencies.map { formatGHz($0[index]) } ?? "–") + " of \(top) GHz"
        }
    }

    override func willOpen() {
        if let latest = history.samples.last { update(latest) }
        refreshProcesses()
        processTimer?.invalidate()
        processTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isVisible { self.refreshProcesses() } else { self.processTimer?.invalidate() }
        }
    }

    func refreshProcesses() {
        let processes = topCPUProcesses(processRows.count)
        for (index, row) in processRows.enumerated() {
            guard index < processes.count else { row.isHidden = true; continue }
            row.isHidden = false
            row.icon.image = processIcon(processes[index].pid)
            row.name.stringValue = processes[index].name
            row.value.stringValue = String(format: "%.1f%%", processes[index].usage)
        }
        if isVisible { fitToContents() }
    }

    @objc private func openActivityMonitor() {
        dismiss()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

/// Prints what the panel shows, from two readings a second apart.
func cpuReport() -> Int32 {
    let sampler = CPUSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    guard let sample = sampler.sample() else {
        FileHandle.standardError.write("Could not read the CPU.\n".data(using: .utf8)!)
        return 1
    }
    print("Usage")
    for part in cpuParts { print(part.title + "\t" + formatPercent(part.value(sample))) }
    print("Idle\t" + formatPercent(sample.idle))
    for (type, usage) in zip(coreTypes, sample.coreUsage) { print(type.name + "\t" + formatPercent(usage)) }
    print("Average load")
    for (title, load) in zip(["1 minute", "5 minutes", "15 minutes"], loadAverages()) { print(title + "\t" + String(format: "%.2f", load)) }
    print("Frequency")
    if let speeds = sample.frequencies {
        print("All cores\t" + formatMHz(allCoresSpeed(speeds)))
        for (type, speed) in zip(coreTypes, speeds) { print(type.name + "\t" + formatMHz(speed)) }
    }
    // Not in the panel: each core type's cores and clock steps, the frequency chart's scale.
    print("Cores")
    for type in coreTypes { print(type.name + "\t" + String(type.cores.count) + "\t" + type.steps.map { formatMHz($0) }.joined(separator: ",")) }
    print("Top processes")
    for process in topCPUProcesses() { print(process.name + "\t" + String(format: "%.1f%%", process.usage)) }
    return 0
}
