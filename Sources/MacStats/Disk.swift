// The Disk menu bar item: the startup disk's free space as "Disk free" over "75 GB",
// and a panel listing where the space goes: the APFS volumes as
// coloured rows and a line bar like Stats' RAM panel, then my apps / files broken
// down into folders three levels deep. Private folders (Desktop, Documents,
// Downloads, Music, Movies, other apps' data, Mail, Photos and the like) are never
// opened, so macOS never asks for access to them.

import Cocoa

/// The figures Stats uses: free is the space available for important usage (it
/// counts purgeable space as free), used is total minus free. Decimal gigabytes.
///
/// Read every second, like Stats' CPU and GPU. The plain free space costs next to
/// nothing; the important-usage figure costs about 10 ms of CPU, so it is read
/// every 30 seconds and the purgeable space it adds is carried between reads.
final class DiskSampler {
    private var purgeable: Int64 = 0
    private var lastFullRead = Date.distantPast

    func sample() -> (total: Int64, free: Int64)? {
        let full = Date().timeIntervalSince(lastFullRead) >= 30
        var keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        if full { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity.map(Int64.init),
              let plain = values.volumeAvailableCapacity.map(Int64.init) else { return nil }
        if full, let important = values.volumeAvailableCapacityForImportantUsage {
            purgeable = max(0, important - plain)
            lastFullRead = Date()
        }
        return (total, min(total, plain + purgeable))
    }
}

/// What the Disk item shows: the free space in whole GB (as Finder counts it, purgeable
/// space included), and the exact figures for its tooltip.
func diskItemText(_ sampler: DiskSampler) -> (value: String, tooltip: String)? {
    guard let figures = sampler.sample() else { return nil }
    let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000_000) }
    return ("\(Int((Double(figures.free) / 1_000_000_000).rounded())) GB",
            "\(gb(figures.free)) GB free of \(gb(figures.total)) GB. Click for where the space goes.")
}

// MARK: - The five spaces

/// A row in the panel: one of the five spaces, or a folder inside the last.
final class Entry: Codable {
    let title: String
    let path: String?
    var bytes: Int64
    /// "private" for a folder MacStats does not open, "no access" for one macOS
    /// would not let it read. Either way its size is unknown.
    var note: String?
    /// True when a folder inside this one was not counted, so the size is a minimum.
    var partial = false
    var children: [Entry] = []

    init(title: String, path: String? = nil, bytes: Int64 = 0) {
        self.title = title
        self.path = path
        self.bytes = bytes
    }

    var sizeText: String {
        if let note { return note }
        return (partial ? "≥ " : "") + formatSize(bytes)
    }
}

/// The startup disk's APFS volumes, by role, in the order the panel lists them.
/// Colours follow Stats' RAM panel: blue for what you put there (as its App),
/// orange for macOS (as Wired), pink for swap (as Compressed), grey for free.
let spaceRoles: [(title: String, roles: [String], color: NSColor, colorName: String)] = [
    ("macOS system", ["System"], .systemOrange, "orange"),
    ("update/boot", ["Preboot", "Update"], .systemYellow, "yellow"),
    ("recovery", ["Recovery"], .systemPurple, "purple"),
    ("swap", ["VM"], .systemPink, "pink"),
    ("my apps / files", ["Data"], .systemBlue, "blue"),
]

/// Every row of the panel's Spaces section under Used, in order, with its colour.
/// The rows and the bar are both built from this one list, so no row can appear
/// without a colour, and the rows add up to Used. After the volumes: other (APFS's
/// own bookkeeping and any volume not listed), Purgeable (the part of my apps /
/// files macOS frees on its own, shown next to free space) and Free.
let spaceLegend: [(title: String, color: NSColor, colorName: String)] =
    spaceRoles.map { ($0.title, $0.color, $0.colorName) } + [
        ("other", .systemBrown, "brown"),
        ("Purgeable", .systemTeal, "teal"),
        ("Free", NSColor.lightGray.withAlphaComponent(0.5), "light grey"),
    ]

func plist(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}

/// The space each role uses on the startup disk's APFS container, and the
/// container's size and free space, as diskutil reports them. Reads no folders
/// and needs no administrator rights.
func containerSpaces() -> (spaces: [(title: String, bytes: Int64)], total: Int64, free: Int64)? {
    guard let info = plist(runTool("/usr/sbin/diskutil", ["info", "-plist", "/"])),
          let reference = info["APFSContainerReference"] as? String,
          let list = plist(runTool("/usr/sbin/diskutil", ["apfs", "list", "-plist", reference])),
          let container = (list["Containers"] as? [[String: Any]])?.first,
          let volumes = container["Volumes"] as? [[String: Any]]
    else { return nil }
    let spaces = spaceRoles.map { space in
        let bytes = volumes
            .filter { ($0["Roles"] as? [String] ?? []).contains(where: space.roles.contains) }
            .reduce(Int64(0)) { $0 + (($1["CapacityInUse"] as? NSNumber)?.int64Value ?? 0) }
        return (space.title, bytes)
    }
    let number = { (key: String) in (container[key] as? NSNumber)?.int64Value ?? 0 }
    return (spaces, number("CapacityCeiling"), number("CapacityFree"))
}

func volumeSpaces() -> [(title: String, bytes: Int64)] {
    containerSpaces()?.spaces ?? []
}

/// Space macOS can free on its own (caches, iCloud copies, snapshots). The menu
/// bar, like Finder, counts it as free; the panel's volumes count it as used.
/// One row of the Spaces section under Used, as it stands now.
struct SpaceRow {
    let title: String
    let color: NSColor
    let colorName: String
    let bytes: Int64
    /// What the row's piece of the bar shows: my apps / files less its purgeable
    /// part, which has a piece of its own.
    let barBytes: Int64
}

/// The Spaces rows under Used, measured now: biggest first, Free always last. The
/// panel and `--legend` both use this, so they cannot disagree.
func spaceRowsNow() -> (used: Int64, total: Int64, rows: [SpaceRow])? {
    guard let disk = containerSpaces(), disk.total > 0 else { return nil }
    let purgeable = purgeableBytes()
    let used = disk.total - disk.free
    let volumes = disk.spaces.map(\.bytes)
    let other = max(0, used - volumes.reduce(0, +))
    let sizes = volumes + [other, purgeable, disk.free]  // one per spaceLegend entry
    let data = spaceRoles.firstIndex { $0.roles.contains("Data") }
    let rows = zip(spaceLegend, sizes).enumerated().map { index, entry in
        SpaceRow(title: entry.0.title, color: entry.0.color, colorName: entry.0.colorName, bytes: entry.1,
                 barBytes: index == data ? max(0, entry.1 - purgeable) : entry.1)
    }
    // Free is the legend's last entry; the rest go biggest first, ties in legend order.
    let order = rows.indices.dropLast().sorted { (rows[$0].bytes, $1) > (rows[$1].bytes, $0) }
    return (used, disk.total, order.map { rows[$0] } + [rows[rows.count - 1]])
}

func purgeableBytes() -> Int64 {
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]), let plain = values.volumeAvailableCapacity, let important = values.volumeAvailableCapacityForImportantUsage
    else { return 0 }
    return max(0, important - Int64(plain))
}

// MARK: - Folders, without opening private ones

/// The Data volume's root: everything installed or saved since macOS shipped.
let dataVolume = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
let folderDepth = 3
let defaultMinimumBytes: Int64 = 100_000_000

/// Folders in each home that macOS guards with a privacy prompt, or that hold a
/// person's private data. MacStats never opens them: it lists them by name, and
/// a folder holding one shows its size as a minimum (≥).
let privateHomeFolders = [
    "Desktop", "Documents", "Downloads",
    "Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support/FileProvider",
    "Library/Containers", "Library/Group Containers", "Library/Daemon Containers",
    "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Reminders",
    "Library/HomeKit", "Library/Cookies", "Library/Suggestions", "Library/IdentityServices",
    "Library/Accounts", "Library/Sharing", "Library/Biome", "Library/Metadata/CoreSpotlight",
    "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
    "Library/Application Support/CallHistoryTransactions", "Library/Application Support/Knowledge",
    "Library/Application Support/com.apple.TCC", "Library/Application Support/com.apple.sharedfilelist",
    // Listing anything inside Music or Movies makes macOS ask for the media library.
    "Library/Photos", "Library/Caches/com.apple.Music", "Music", "Movies",
]
/// Library packages of the Photos, Music and TV apps, wherever they are kept.
let privatePackageExtensions: Set<String> = [
    "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
]

/// Folders under `root`, down to `depth` levels, each at least `minimumBytes`,
/// biggest first. Counts allocated blocks like du (a cloned file counts in full,
/// a hard-linked one once) and stays on root's volume. Private folders are listed
/// but never opened, so measuring causes no privacy prompt.
func scanFolders(_ root: String, depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes) -> [Entry] {
    let rootPath = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    let base = rootPath == "/" ? "" : rootPath
    var privatePaths: Set<String> = [base + "/Volumes"]  // removable and network volumes
    let users = base + "/Users"
    // Listing the folder of homes names them without opening any.
    for name in (try? FileManager.default.contentsOfDirectory(atPath: users)) ?? [] {
        for folder in privateHomeFolders { privatePaths.insert("\(users)/\(name)/\(folder)") }
    }

    var top: [Entry] = []
    var ancestors = [Entry?](repeating: nil, count: depth + 1)
    var counted = Set<UInt64>()  // hard-linked files already counted, by inode

    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(rootPath), nil]
    defer { free(argv[0]) }
    guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return [] }
    defer { fts_close(fts) }

    func add(_ bytes: Int64, through level: Int) {
        for k in stride(from: 1, through: min(level, depth), by: 1) { ancestors[k]?.bytes += bytes }
    }
    func markAncestorsPartial(below level: Int) {
        for k in stride(from: 1, to: min(level, depth + 1), by: 1) { ancestors[k]?.partial = true }
    }

    while let entry = fts_read(fts) {
        let level = Int(entry.pointee.fts_level)
        switch Int32(entry.pointee.fts_info) {
        case FTS_D:
            let path = String(cString: entry.pointee.fts_path)
            if level >= 1 && level <= depth {
                let folder = Entry(title: (path as NSString).lastPathComponent, path: path)
                ancestors[level] = folder
                if level == 1 {
                    top.append(folder)
                } else if let parent = ancestors[level - 1], !(parent.path ?? "").hasSuffix(".app") {
                    parent.children.append(folder)  // an app is one row
                }
            }
            if privatePaths.contains(path)
                || privatePackageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                fts_set(fts, entry, FTS_SKIP)
                if level >= 1 && level <= depth { ancestors[level]?.note = "private" }
                markAncestorsPartial(below: level)
                continue
            }
            add(Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512, through: level)
        case FTS_DNR:
            if level >= 1 && level <= depth { ancestors[level]?.note = "no access" }
            markAncestorsPartial(below: level)
        case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
            let stat = entry.pointee.fts_statp.pointee
            if stat.st_nlink > 1 && !counted.insert(UInt64(stat.st_ino)).inserted { continue }
            add(Int64(stat.st_blocks) * 512, through: level - 1)
        default:
            break
        }
    }

    // Keep what is big enough, every private folder, and unreadable folders in a
    // home (the Trash, say); a folder unreadable elsewhere belongs to the system.
    func keep(_ list: [Entry]) -> [Entry] {
        list.filter { entry in
            entry.bytes >= minimumBytes || entry.note == "private"
                || (entry.note != nil && (entry.path ?? "").hasPrefix(users + "/"))
        }
        .sorted { ($0.bytes, $1.title) > ($1.bytes, $0.title) }
        .map { entry in entry.children = keep(entry.children); return entry }
    }
    return keep(top)
}

func formatSize(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000
        ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        : String(format: "%.0f MB", Double(bytes) / 1_000_000)
}

// MARK: - The panel

let foldersHeight: CGFloat = 22 * 15

final class DiskPanel: StatsPanel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    /// Shown at the top of the empty folder list while measuring.
    private let measuring = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let measuringNote = NSStackView()
    /// "Last measured at 9:41 PM." at the left of the line above the folder list, and
    /// "Remeasuring…" in italics at its right while it measures again.
    private let status = NSTextField(labelWithString: "")
    private let remeasuring = NSTextField(labelWithString: "Remeasuring…")
    private let usedRow = PanelRow("Used:")
    private let bar = SpaceBar()
    private let spaceRows: [String: PanelRow] = Dictionary(uniqueKeysWithValues: spaceLegend.map {
        ($0.title, PanelRow($0.title + ":", color: $0.color))
    })
    private let spaceList = NSStackView()
    private var folders: [Entry] = []
    private(set) var scanning = false
    private var measuredAt: Date?

    init() {
        super.init(title: "Disk")
        setHeaderButtons(leading: headerButton("arrow.clockwise", "Measure again", #selector(refreshAll)),
                         trailing: headerButton("internaldrive", "Open Storage settings", #selector(openStorageSettings)))
        build()
        loadSavedMeasurement()
    }

    var isMeasured: Bool { measuredAt != nil && !scanning }

    private func build() {
        // Laid out like Stats' RAM details: Used, the bar, then a coloured row per
        // part of the bar, in the bar's order.
        body.addArrangedSubview(separatorView("Spaces"))
        body.addArrangedSubview(usedRow)
        body.addArrangedSubview(bar)
        spaceList.orientation = .vertical
        spaceList.alignment = .leading
        spaceList.spacing = 0
        spaceList.setViews(spaceLegend.compactMap { spaceRows[$0.title] }, in: .top)
        body.addArrangedSubview(spaceList)
        let tips = [
            "my apps / files": "Your apps, files, settings and caches. The list below breaks it down.",
            "macOS system": "macOS itself, on a sealed read-only volume. Only updates change it.",
            "update/boot": "Start-up files, and macOS updates waiting to install.",
            "recovery": "macOS Recovery, for repairing the disk or reinstalling macOS.",
            "swap": "Memory moved to disk when RAM runs short, and the sleep image.",
            "other": "Space APFS keeps for its bookkeeping, and any other volume.",
            "Purgeable": "Caches and copies macOS frees when it needs room; free in the menu bar.",
            "Free": "Space left for new files.",
        ]
        for (title, row) in spaceRows { row.hoverTip = tips[title].map(twoLines) }
        for row in Array(spaceRows.values) + [usedRow] { row.value.stringValue = "…" }
        body.addArrangedSubview(separatorView("My apps / files"))

        // The name column takes whatever the fixed size column leaves.
        let name = NSTableColumn(identifier: .init("name"))
        name.width = Panel.width - 90
        name.resizingMask = .autoresizingMask
        let size = NSTableColumn(identifier: .init("size"))
        size.width = 72
        size.resizingMask = []
        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.outlineTableColumn = name
        outline.style = .plain
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .custom
        outline.rowHeight = Panel.row
        outline.indentationPerLevel = 10
        outline.intercellSpacing = NSSize(width: 4, height: 0)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.selectionHighlightStyle = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(revealInFinder)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // The time of the last measurement sits at the top, under the caption, above the
        // list. Before the first measurement the list is empty and the measuring note
        // fills its top instead.
        spinner.style = .spinning
        spinner.controlSize = .small
        for text in [measuring, status, remeasuring] {
            text.font = .systemFont(ofSize: 10)
            text.textColor = .tertiaryLabelColor
            text.hoverTip = twoLines("Private folders are never opened; ≥ means at least. Double-click to show in Finder.")
        }
        measuring.preferredMaxLayoutWidth = Panel.width - 24
        remeasuring.font = NSFontManager.shared.convert(.systemFont(ofSize: 10), toHaveTrait: .italicFontMask)
        remeasuring.alignment = .right
        measuringNote.setViews([spinner, measuring], in: .leading)
        measuringNote.alignment = .top
        measuringNote.translatesAutoresizingMaskIntoConstraints = false
        let folderArea = NSView()
        folderArea.translatesAutoresizingMaskIntoConstraints = false
        folderArea.addSubview(scroll)
        folderArea.addSubview(measuringNote)
        let statusLine = NSView()
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        for text in [status, remeasuring] {
            text.translatesAutoresizingMaskIntoConstraints = false
            statusLine.addSubview(text)
        }
        body.addArrangedSubview(statusLine)
        body.setCustomSpacing(6, after: statusLine)
        body.addArrangedSubview(folderArea)

        NSLayoutConstraint.activate([
            folderArea.widthAnchor.constraint(equalToConstant: Panel.width),
            folderArea.heightAnchor.constraint(equalToConstant: foldersHeight),
            scroll.leadingAnchor.constraint(equalTo: folderArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: folderArea.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: folderArea.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: folderArea.bottomAnchor),
            measuringNote.leadingAnchor.constraint(equalTo: folderArea.leadingAnchor),
            measuringNote.trailingAnchor.constraint(equalTo: folderArea.trailingAnchor),
            measuringNote.topAnchor.constraint(equalTo: folderArea.topAnchor),
            // Room for its line, kept while measuring, so the panel does not jump.
            statusLine.widthAnchor.constraint(equalToConstant: Panel.width),
            statusLine.heightAnchor.constraint(equalToConstant: 14),
            status.leadingAnchor.constraint(equalTo: statusLine.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: statusLine.centerYAnchor),
            remeasuring.trailingAnchor.constraint(equalTo: statusLine.trailingAnchor),
            remeasuring.centerYAnchor.constraint(equalTo: statusLine.centerYAnchor),
            remeasuring.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 8),
        ])
        updateStatus()
    }

    override func willOpen() {
        refreshSpaces()
        if measuredAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { measureFolders() }
    }

    func refreshSpaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let now = spaceRowsNow() else { return }
            DispatchQueue.main.async {
                self.usedRow.value.stringValue = formatSize(now.used)
                for row in now.rows { self.spaceRows[row.title]?.value.stringValue = formatSize(row.bytes) }
                self.spaceList.setViews(now.rows.compactMap { self.spaceRows[$0.title] }, in: .top)
                // The bar follows the rows' order; Free is the rest of the line.
                self.bar.parts = now.rows.dropLast().map { (Double($0.barBytes) / Double(now.total), $0.color) }
            }
        }
    }

    /// Measures the folders again. The last measurement stays on screen until the new
    /// one replaces it; only with none to show does the list wait, empty, for the first.
    func measureFolders() {
        guard !scanning else { return }
        scanning = true
        spinner.startAnimation(nil)
        updateStatus()
        DispatchQueue.global(qos: .utility).async {
            let measured = scanFolders(dataVolume)
            DispatchQueue.main.async {
                self.scanning = false
                self.spinner.stopAnimation(nil)
                self.show(measured, at: Date())
                self.saveMeasurement()
            }
        }
    }

    private func show(_ measured: [Entry], at time: Date) {
        folders = measured
        measuredAt = time
        outline.reloadData()
        // Open the biggest branch, so its third level shows.
        var next = folders.first
        while let folder = next, !folder.children.isEmpty {
            outline.expandItem(folder)
            next = folder.children.first
        }
        updateStatus()
    }

    // The last measurement is kept in the app's cache folder, so a restart (a login,
    // an update) opens with it instead of measuring from nothing.
    private struct SavedMeasurement: Codable {
        let measuredAt: Date
        let folders: [Entry]
    }

    private static let savedMeasurementURL: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("sh.csarko.MacStats/folders.json")

    private func saveMeasurement() {
        guard let url = Self.savedMeasurementURL, let measuredAt,
              let data = try? JSONEncoder().encode(SavedMeasurement(measuredAt: measuredAt, folders: folders)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func loadSavedMeasurement() {
        guard let url = Self.savedMeasurementURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedMeasurement.self, from: data) else { return }
        show(saved.folders, at: saved.measuredAt)
    }

    private func updateStatus() {
        let privacy = "Private folders are never opened; ≥\u{00A0}means at least."
        // The measuring note fills the list only while there is nothing to show yet.
        measuringNote.isHidden = !(scanning && folders.isEmpty)
        measuring.stringValue = "Measuring folders, about a minute… " + privacy
        if let measuredAt {
            let time = DateFormatter.localizedString(from: measuredAt, dateStyle: .none, timeStyle: .short)
            status.stringValue = "Last measured at \(time)."
        } else {
            status.stringValue = ""
        }
        // Before the first measurement the measuring note says so instead.
        remeasuring.isHidden = !(scanning && measuredAt != nil)
        fitToContents()
    }

    @objc private func refreshAll() {
        refreshSpaces()
        measureFolders()
    }

    @objc private func openStorageSettings() {
        orderOut(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealInFinder() {
        guard let entry = outline.item(atRow: outline.clickedRow) as? Entry, let path = entry.path else { return }
        orderOut(nil)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Entry)?.children.count ?? folders.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Entry)?.children[index] ?? folders[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Entry)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? Entry, let id = tableColumn?.identifier else { return nil }
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        if id.rawValue == "size" {
            cell.textField?.stringValue = entry.sizeText
            cell.textField?.alignment = .right
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = entry.note == nil ? .labelColor : .tertiaryLabelColor
        } else {
            cell.textField?.stringValue = entry.title
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .secondaryLabelColor
            cell.hoverTip = entry.path
        }
        return cell
    }
}

// MARK: - Command line

// Prints what the panel lists, as an indented tree. With a folder, prints only
// that folder's tree, which keeps tests fast.
func diskReport(folder: String?, minimumBytes: Int64) -> Int32 {
    func printTree(_ entries: [Entry], indent: Int) {
        for entry in entries {
            print(String(repeating: "  ", count: indent) + entry.title + "\t" + entry.sizeText)
            printTree(entry.children, indent: indent + 1)
        }
    }
    if let folder {
        printTree(scanFolders(folder, minimumBytes: minimumBytes), indent: 0)
        return 0
    }
    let spaces = volumeSpaces()
    guard !spaces.isEmpty else {
        FileHandle.standardError.write("Could not read the startup disk's volumes from diskutil.\n".data(using: .utf8)!)
        return 1
    }
    for space in spaces {
        print(space.title + "\t" + formatSize(space.bytes))
    }
    printTree(scanFolders(dataVolume, minimumBytes: minimumBytes), indent: 1)
    return 0
}

