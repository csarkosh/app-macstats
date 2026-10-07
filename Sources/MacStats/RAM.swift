// The RAM menu bar item: "RAM" over the share of memory in use, and a panel like
// Stats' RAM panel: Usage (a history chart whose bands are coloured like the rows
// below it, App, Wired and Compressed stacked from the bottom with Free on top, then
// Used, the bar and a row per part, then Swap) and Top Processes. The figures are
// Stats' (Modules/RAM/readers.swift, MIT; see LICENSE-stats.txt at the repository root).

import Cocoa

struct MemoryUsage {
    let total: Double
    let used: Double
    let app: Double
    let wired: Double
    let compressed: Double
    let free: Double
    let swap: Double
    /// What macOS has set aside for swap so far; it grows as needed.
    let swapTotal: Double
}

/// Memory as Stats counts it: used is active, inactive, speculative, wired and
/// compressed pages less purgeable and file-backed ones; App is what is left of used
/// after Wired and Compressed; Free is the rest.
func memoryUsage() -> MemoryUsage? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = Double(vm_kernel_page_size)
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    let active = Double(stats.active_count) * page
    let inactive = Double(stats.inactive_count) * page
    let speculative = Double(stats.speculative_count) * page
    let wired = Double(stats.wire_count) * page
    let compressed = Double(stats.compressor_page_count) * page
    let purgeable = Double(stats.purgeable_count) * page
    let external = Double(stats.external_page_count) * page
    let used = active + inactive + speculative + wired + compressed - purgeable - external

    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

    return MemoryUsage(total: total, used: used, app: max(0, used - wired - compressed), wired: wired,
                       compressed: compressed, free: max(0, total - used), swap: Double(swap.xsu_used),
                       swapTotal: Double(swap.xsu_total))
}

/// Memory in the units macOS uses for it (binary, shown as GB and MB), as Stats does.
func formatMemory(_ bytes: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(bytes))
}

/// The Usage rows and the chart's bands, bottom to top, with their colours.
let memoryParts: [(title: String, color: NSColor, value: (MemoryUsage) -> Double)] = [
    ("App", .systemBlue, { $0.app }),
    ("Wired", .systemOrange, { $0.wired }),
    ("Compressed", .systemPink, { $0.compressed }),
    ("Free", .lightGray, { $0.free }),
]

/// Swap is disk space macOS uses as overflow when memory runs short. It is not part of
/// the physical memory the bands divide up, so it has a strip of its own under them, in
/// its row's colour.
let swapColor = NSColor.systemPurple

/// What the RAM item shows: the share of memory in use.
func ramItemText(_ usage: MemoryUsage) -> (value: String, tooltip: String) {
    (String(format: "%.0f%%", usage.used / usage.total * 100),
     "\(formatMemory(usage.used)) of \(formatMemory(usage.total)) in use. Click for what is using it.")
}

// MARK: - Top processes

struct ProcessMemory {
    let pid: Int32
    let name: String
    let bytes: Double
}

/// The processes using the most memory, from `top`, as Stats reads them. `top` can see
/// every process (WindowServer, system services) without any permission.
func topProcesses(_ count: Int = 8) -> [ProcessMemory] {
    guard let data = runTool("/usr/bin/top", ["-l", "1", "-o", "mem", "-n", String(count), "-stats", "pid,command,mem"])
    else { return [] }
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    guard let header = lines.firstIndex(where: { $0.hasPrefix("PID") }) else { return [] }
    return lines[(header + 1)...].compactMap { line in
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 3, let pid = Int32(words[0]), let bytes = topBytes(String(words[words.count - 1])) else { return nil }
        let command = words[1..<(words.count - 1)].joined(separator: " ")
        return ProcessMemory(pid: pid, name: NSRunningApplication(processIdentifier: pid)?.localizedName ?? command, bytes: bytes)
    }
}

/// `top`'s memory column: "2449M", "726M+", "9600K", "1.2G".
func topBytes(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
    guard let unit = trimmed.last, let number = Double(trimmed.dropLast()) else { return Double(trimmed) }
    switch unit {
    case "B": return number
    case "K": return number * 1024
    case "M": return number * 1024 * 1024
    case "G": return number * 1024 * 1024 * 1024
    default: return nil
    }
}

/// An app's own icon, or the plain executable icon Stats shows for everything else.
func processIcon(_ pid: Int32) -> NSImage {
    NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(forFile: "/bin/bash")
}

// MARK: - The panel

/// The last three minutes of memory use, one sample a second, as Stats' chart keeps.
final class MemoryHistory {
    private(set) var samples: [MemoryUsage] = []
    let capacity = 180

    func add(_ usage: MemoryUsage) {
        samples.append(usage)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// Stats' usage history chart, with a band per part instead of one for used: App,
/// Wired and Compressed stacked from the bottom, Free on top, newest at the right. Free
/// is labelled at the top right with its size now, and a time axis runs underneath.
final class MemoryChart: NSView {
    var history: MemoryHistory?
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
        drawAxis()
        let frame = NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6)
        NSColor.lightGray.withAlphaComponent(0.1).setFill()
        frame.fill()
        guard let history, history.samples.count > 1, let latest = history.samples.last else { return }
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let samples = history.samples
        let step = plot.width / CGFloat(history.capacity - 1)
        let x = { (index: Int) in plot.maxX - CGFloat(samples.count - 1 - index) * step }
        let y = { (fraction: Double) in plot.minY + CGFloat(fraction) * plot.height }
        // Cumulative tops, one per band, as fractions of all memory.
        var below = [Double](repeating: 0, count: samples.count)
        for (band, part) in memoryParts.enumerated() {
            let isFree = band == memoryParts.count - 1
            let above = samples.indices.map { index in
                isFree ? 1 : below[index] + part.value(samples[index]) / samples[index].total
            }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x(0), y: y(below[0])))
            for index in samples.indices { path.line(to: CGPoint(x: x(index), y: y(above[index]))) }
            for index in samples.indices.reversed() { path.line(to: CGPoint(x: x(index), y: y(below[index]))) }
            path.close()
            // The same colours as the rows' squares, so each band reads as its row.
            (isFree ? part.color.withAlphaComponent(0.5) : part.color).setFill()
            path.fill()
            below = above
        }
        // Free's size and share now, "Free: 2.1 GB (13%)", at the top right, against the top edge.
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let text = NSAttributedString(
            string: "Free: \(formatMemory(latest.free)) (\(Int((latest.free / latest.total * 100).rounded()))%)",
            attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: right])
        let height = ceil(text.size().height)
        text.draw(with: NSRect(x: plot.minX, y: plot.maxY - height, width: plot.width - 10, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// "3 min ago" under the left edge and "now" under the right.
    private func drawAxis() {
        let attributes = { (alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] in
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            return [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        }
        let span = (history?.capacity ?? 180) / 60
        let row = NSRect(x: 2, y: 0, width: bounds.width - 4, height: axisHeight - 2)
        NSAttributedString(string: "\(span) min ago", attributes: attributes(.left)).draw(with: row)
        NSAttributedString(string: "now", attributes: attributes(.right)).draw(with: row)
    }
}

/// A Top Processes row: the process's icon, its name and its memory, as in Stats.
final class ProcessRow: NSView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        value.font = .systemFont(ofSize: 12)
        value.alignment = .right
        for view in [icon, name, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Panel.row),
            widthAnchor.constraint(equalToConstant: Panel.width),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class RAMPanel: StatsPanel {
    private let history: MemoryHistory
    private let chart = MemoryChart()
    private let usedRow = PanelRow("Used:")
    private let bar = SpaceBar()
    private let partRows = memoryParts.map { PanelRow($0.title + ":", color: $0.color.withAlphaComponent($0.title == "Free" ? 0.5 : 1)) }
    private let swapRow = PanelRow("Swap:", color: swapColor)
    // Swap over the last three minutes, scaled to the Mac's physical memory: its height
    // is how far memory demand has spilled past it. (Swap has no fixed maximum to scale
    // to: macOS adds 1 GB swap files as it needs them while the disk has room.)
    private let swapSparkline = Sparkline(color: swapColor)
    private let processRows = (0..<8).map { _ in ProcessRow() }
    private var processTimer: Timer?

    init(history: MemoryHistory) {
        self.history = history
        super.init(title: "RAM")
        setHeaderButtons(leading: headerButton("chart.bar.fill", "Open Activity Monitor", #selector(openActivityMonitor)),
                         trailing: nil)
        chart.history = history

        body.addArrangedSubview(separatorView("Usage"))
        body.addArrangedSubview(chart)
        body.setCustomSpacing(6, after: chart)
        body.addArrangedSubview(usedRow)
        body.addArrangedSubview(bar)
        for row in partRows { body.addArrangedSubview(row) }
        // Swap is always last: it is not part of the memory above.
        let tips = [
            "App": "Memory apps use for their own data: documents, web pages, images.",
            "Wired": "Memory macOS keeps for itself and never moves: kernel, drivers, GPU buffers.",
            "Compressed": "App memory packed down to make room, rather than moved to disk.",
            "Free": "Unused memory, plus caches macOS drops when needed. Little free is normal.",
        ]
        for (row, part) in zip(partRows, memoryParts) { row.hoverTip = tips[part.title].map(twoLines) }
        body.addArrangedSubview(swapRow)
        swapRow.hoverTip = twoLines("Disk used as overflow when memory runs short. Its graph is scaled to your RAM.")
        swapSparkline.capacity = history.capacity
        swapSparkline.place(in: swapRow)

        body.addArrangedSubview(separatorView("Top processes"))
        let heading = ProcessRow()
        heading.name.stringValue = "Process"
        heading.value.stringValue = "Usage"
        for field in [heading.name, heading.value] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .tertiaryLabelColor
        }
        body.addArrangedSubview(heading)
        for row in processRows { body.addArrangedSubview(row) }
        if let latest = history.samples.last { update(latest) }
    }

    /// Shows the latest sample: the chart, Used and its bar, the rows and Swap.
    func update(_ usage: MemoryUsage) {
        chart.needsDisplay = true
        swapSparkline.fractions = history.samples.map { $0.swap / usage.total }
        usedRow.value.stringValue = formatMemory(usage.used)
        bar.parts = memoryParts.dropLast().map { ($0.value(usage) / usage.total, $0.color) }
        for (row, part) in zip(partRows, memoryParts) { row.value.stringValue = formatMemory(part.value(usage)) }
        swapRow.value.stringValue = formatMemory(usage.swap)
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

    /// `top` takes a fraction of a second, so it runs off the main thread, and only
    /// while the panel is open.
    private func refreshProcesses() {
        DispatchQueue.global(qos: .userInitiated).async {
            let processes = topProcesses(self.processRows.count)
            DispatchQueue.main.async {
                for (index, row) in self.processRows.enumerated() {
                    guard index < processes.count else { row.isHidden = true; continue }
                    let process = processes[index]
                    row.isHidden = false
                    row.icon.image = processIcon(process.pid)
                    row.name.stringValue = process.name
                    row.value.stringValue = formatMemory(process.bytes)
                }
            }
        }
    }

    @objc private func openActivityMonitor() {
        dismiss()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

/// Prints what the panel shows: Usage, then Top processes.
func memoryReport() -> Int32 {
    guard let usage = memoryUsage() else {
        FileHandle.standardError.write("Could not read memory use.\n".data(using: .utf8)!)
        return 1
    }
    print("Usage")
    print("Used\t" + formatMemory(usage.used) + "\t" + String(Int64(usage.used)))
    for part in memoryParts {
        print(part.title + "\t" + formatMemory(part.value(usage)) + "\t" + String(Int64(part.value(usage))))
    }
    print("Swap\t" + formatMemory(usage.swap) + "\t" + String(Int64(usage.swap)))
    print("Total\t" + formatMemory(usage.total) + "\t" + String(Int64(usage.total)))
    print("Top processes")
    for process in topProcesses() {
        print(process.name + "\t" + formatMemory(process.bytes) + "\t" + String(Int64(process.bytes)))
    }
    return 0
}
