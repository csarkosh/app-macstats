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
    /// True when "no access" is macOS refusing a folder the person granted, as opposed to
    /// a folder the scan could not read on its own.
    var refused = false
    /// True when the scan dropped a folder inside this one (too small to list) that held
    /// something unmeasured, so this folder's size stays a minimum whatever is granted.
    var droppedUnmeasured = false
    var children: [Entry] = []

    init(title: String, path: String? = nil, bytes: Int64 = 0) {
        self.title = title
        self.path = path
        self.bytes = bytes
    }

    // A measurement saved by an earlier release lacks the newer keys, so each one has a default.
    enum CodingKeys: String, CodingKey { case title, path, bytes, note, partial, refused, droppedUnmeasured, children }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        bytes = try values.decode(Int64.self, forKey: .bytes)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        partial = try values.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        refused = try values.decodeIfPresent(Bool.self, forKey: .refused) ?? false
        droppedUnmeasured = try values.decodeIfPresent(Bool.self, forKey: .droppedUnmeasured) ?? false
        children = try values.decodeIfPresent([Entry].self, forKey: .children) ?? []
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
/// but never opened, so measuring causes no privacy prompt, except those in `granted`,
/// which are measured like any other. `Volumes` is neither opened nor listed. A walked
/// path is compared to `granted.folders` in its canonical form.
func scanFolders(
    _ root: String, depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes, granted: GrantSet = GrantSet()
) -> [Entry] {
    scanTree(root, depth: depth, minimumBytes: minimumBytes, granted: granted).folders
}

/// What `scanFolders` finds, plus the size of `root` itself and whether something inside it
/// was left uncounted. `users` is the folder of homes; it is `root`'s `Users` unless the
/// scan is of one folder inside a tree measured from higher up.
func scanTree(
    _ root: String, depth: Int, minimumBytes: Int64, granted: GrantSet, users usersFolder: String? = nil
) -> (folders: [Entry], bytes: Int64, partial: Bool, droppedUnmeasured: Bool) {
    let rootPath = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    let base = rootPath == "/" ? "" : rootPath
    let volumes = base + "/Volumes"  // removable and network disks
    var privatePaths: Set<String> = []
    let users = usersFolder ?? base + "/Users"
    // Listing the folder of homes names them without opening any.
    for name in (try? FileManager.default.contentsOfDirectory(atPath: users)) ?? [] {
        for folder in privateHomeFolders { privatePaths.insert("\(users)/\(name)/\(folder)") }
    }

    var top: [Entry] = []
    var ancestors = [Entry?](repeating: nil, count: depth + 1)
    var counted = Set<UInt64>()  // hard-linked files already counted, by inode
    var rootBytes: Int64 = 0
    var rootPartial = false

    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(rootPath), nil]
    defer { free(argv[0]) }
    guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return ([], 0, false, false) }
    defer { fts_close(fts) }

    func add(_ bytes: Int64, through level: Int) {
        rootBytes += bytes
        for k in stride(from: 1, through: min(level, depth), by: 1) { ancestors[k]?.bytes += bytes }
    }
    func markAncestorsPartial(below level: Int) {
        if level >= 1 { rootPartial = true }
        for k in stride(from: 1, to: min(level, depth + 1), by: 1) { ancestors[k]?.partial = true }
    }

    while let entry = fts_read(fts) {
        let level = Int(entry.pointee.fts_level)
        switch Int32(entry.pointee.fts_info) {
        case FTS_D:
            let path = String(cString: entry.pointee.fts_path)
            if level == 1 && path == volumes {
                fts_set(fts, entry, FTS_SKIP)  // not listed: the disks have their own rows
                continue
            }
            if level >= 1 && level <= depth {
                let folder = Entry(title: (path as NSString).lastPathComponent, path: path)
                ancestors[level] = folder
                if level == 1 {
                    top.append(folder)
                } else if let parent = ancestors[level - 1], !(parent.path ?? "").hasSuffix(".app") {
                    parent.children.append(folder)  // an app is one row
                }
            }
            if !granted.folders.contains(canonicalPath(path))
                && (privatePaths.contains(path)
                    || privatePackageExtensions.contains((path as NSString).pathExtension.lowercased())) {
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
    // A folder dropped while something unmeasured is inside it is remembered on its parent
    // (`parent` is nil at the top), so a later splice can keep the parent's ≥.
    var droppedAtTop = false
    func keep(_ list: [Entry], in parent: Entry?) -> [Entry] {
        list.filter { entry in
            let kept = entry.bytes >= minimumBytes || entry.note == "private"
                || (entry.note != nil && (entry.path ?? "").hasPrefix(users + "/"))
            // `partial` covers a private folder below the listed depth, which has no row.
            if !kept && (hasUnmeasured(entry) || entry.partial) {
                if let parent { parent.droppedUnmeasured = true } else { droppedAtTop = true }
            }
            return kept
        }
        .sorted(by: isLarger)
        .map { entry in entry.children = keep(entry.children, in: entry); return entry }
    }
    let folders = keep(top, in: nil)
    return (folders, rootBytes, rootPartial, droppedAtTop)
}

/// The order of rows in a list: bytes descending, then title.
func isLarger(_ a: Entry, _ b: Entry) -> Bool {
    (a.bytes, b.title) > (b.bytes, a.title)
}

func formatSize(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000_000
        ? String(format: "%.1f TB", Double(bytes) / 1_000_000_000_000)
        : bytes >= 1_000_000_000
        ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        : String(format: "%.0f MB", Double(bytes) / 1_000_000)
}

/// The folder list as it is kept between runs.
struct SavedMeasurement: Codable {
    let measuredAt: Date
    let folders: [Entry]
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
    /// A section per external disk, keyed by the volume's UUID, under the folder list.
    var volumeSections: [String: VolumeSection] = [:]
    let volumesStack = NSStackView()
    private var folders: [Entry] = []
    private(set) var scanning = false
    private var measuredAt: Date?
    /// The row under the mouse, or -1, and the tracking area that follows it.
    private var hoveredRow = -1
    private var rowHover: NSTrackingArea?
    /// The folders the person has granted, remembered for this build of the app.
    let grants = GrantStore()
    /// What `grants` held when last read: in `init`, before each measurement and on each click.
    var granted = GrantSet()
    /// The folders being measured after a Grant click, as canonical paths; their rows spin.
    private var granting: Set<String> = []
    /// Every measurement that walks a disk (the startup disk's folders, each external disk's)
    /// runs here, one after another, so two never compete for the disk. A Grant click on a
    /// home folder measures on its own queue instead, since the person is waiting for it.
    let measureQueue = DispatchQueue(label: "sh.csarko.MacStats.measure", qos: .utility)

    init() {
        super.init(title: "Disk")
        setHeaderButtons(leading: headerButton("arrow.clockwise", "Measure again", #selector(refreshAll)),
                         trailing: headerButton("internaldrive", "Open Storage settings", #selector(openStorageSettings)))
        build()
        granted = grants.load()
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

        let scroll = folderList(outline, source: self, target: self, doubleAction: #selector(revealInFinder(_:)))
        // The row under the mouse, for the Grant button. HoverTracker's area on the content
        // view goes on following it for the tooltips.
        let hover = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        outline.addTrackingArea(hover)
        rowHover = hover
        // Rows scrolled under a still mouse move the button to the row now under it.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        // The time of the last measurement sits at the top, under the caption, above the
        // list. Before the first measurement the list is empty and the measuring note
        // fills its top instead.
        spinner.style = .spinning
        spinner.controlSize = .small
        let measuredLine = statusLine(status, remeasuring)
        measuring.font = .systemFont(ofSize: 10)
        measuring.textColor = .tertiaryLabelColor
        for text in [measuring, status, remeasuring] {
            text.hoverTip = twoLines("Private folders stay closed unless you grant one; ≥ means at least.")
        }
        measuring.preferredMaxLayoutWidth = Panel.width - 24
        measuringNote.setViews([spinner, measuring], in: .leading)
        measuringNote.alignment = .top
        measuringNote.translatesAutoresizingMaskIntoConstraints = false
        let folderArea = NSView()
        folderArea.translatesAutoresizingMaskIntoConstraints = false
        folderArea.addSubview(scroll)
        folderArea.addSubview(measuringNote)
        body.addArrangedSubview(measuredLine)
        body.setCustomSpacing(6, after: measuredLine)
        body.addArrangedSubview(folderArea)
        volumesStack.orientation = .vertical
        volumesStack.alignment = .leading
        volumesStack.spacing = 0
        body.addArrangedSubview(volumesStack)

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
        ])
        updateStatus()
    }

    /// The startup disk's measurement is queued first; the external disks', read once their
    /// list arrives, queue behind it.
    override func willOpen() {
        refreshSpaces()
        if measuredAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { measureFolders() }
        refreshVolumes(remeasuringOlderThan: 600)
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
    /// The private folders it opens are the granted ones, read again now: a rebuilt app's
    /// grants start empty, so it opens none until one is clicked. It runs on `measureQueue`.
    func measureFolders() {
        guard !scanning else { return }
        scanning = true
        granted = grants.load()
        let granted = granted
        spinner.startAnimation(nil)
        updateStatus()
        measureQueue.async {
            let measured = scanFolders(dataVolume, granted: granted)
            DispatchQueue.main.async {
                self.scanning = false
                self.spinner.stopAnimation(nil)
                // A granted folder it could not open offers System Settings, and its grant is dropped.
                for path in refusedGrants(measured, granted: granted) { self.grants.remove(folder: path) }
                self.granted = self.grants.load()
                // A folder granted while this measurement ran is not in it. One clicked from a
                // refused row waits, still refused, for Measure again once it is allowed in
                // System Settings; any other is measured into the new list.
                let grantedSince = self.granted.folders.subtracting(granted.folders)
                let waiting = grantedSince.filter { grantChain($0, in: self.folders)?.last?.refused == true }
                for path in waiting {
                    guard let entry = grantChain(path, in: measured)?.last, entry.note != nil else { continue }
                    entry.note = "no access"
                    entry.refused = true
                }
                self.show(measured, at: Date())
                self.saveMeasurement()
                for path in grantedSince.subtracting(waiting) { self.measureGrant(path) }
            }
        }
    }

    func show(_ measured: [Entry], at time: Date) {
        folders = measured
        measuredAt = time
        endHover()
        outline.reloadData()
        expandBiggestBranch()
        updateStatus()
    }

    /// Opens the biggest branch, so its third level shows.
    private func expandBiggestBranch() {
        var next = folders.first
        while let folder = next, !folder.children.isEmpty {
            outline.expandItem(folder)
            next = folder.children.first
        }
    }

    // The last measurement is kept in the app's cache folder, so a restart (a login,
    // an update) opens with it instead of measuring from nothing.
    private static let savedMeasurementURL: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("sh.csarko.MacStats/folders.json")

    private func saveMeasurement() {
        guard let url = Self.savedMeasurementURL, let measuredAt,
              let data = try? JSONEncoder().encode(SavedMeasurement(measuredAt: measuredAt, folders: folders)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// A folder the saved measurement shows open but this build has no grant for (after a
    /// rebuild) shows as private again, as the next measurement will show it.
    private func loadSavedMeasurement() {
        guard let url = Self.savedMeasurementURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedMeasurement.self, from: data) else { return }
        closeUngranted(saved.folders, granted: granted)
        show(saved.folders.sorted(by: isLarger), at: saved.measuredAt)
    }

    private func updateStatus() {
        let privacy = "Private folders stay closed unless you grant one; ≥\u{00A0}means at least."
        // The measuring note fills the list only while there is nothing to show yet.
        measuringNote.isHidden = !(scanning && folders.isEmpty)
        measuring.stringValue = "Measuring folders, about a minute… " + privacy
        status.stringValue = lastMeasuredText(measuredAt)
        // Before the first measurement the measuring note says so instead.
        remeasuring.isHidden = !(scanning && measuredAt != nil)
        fitToContents()
    }

    @objc private func refreshAll() {
        refreshSpaces()
        measureFolders()
        refreshVolumes(remeasuringOlderThan: 0)
    }

    @objc private func openStorageSettings() {
        orderOut(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A double-click in any folder list, the startup disk's or an external disk's.
    @objc func revealInFinder(_ list: NSOutlineView) {
        guard let entry = list.item(atRow: list.clickedRow) as? Entry, let path = entry.path else { return }
        orderOut(nil)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // The panel serves every folder list: the startup disk's and each external disk's. They
    // differ only in their top level; rows, cells and double-clicks are the same.
    private func topLevel(of list: NSOutlineView) -> [Entry] {
        list === outline ? folders : volumeSections.values.first { $0.outline === list }?.folders ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Entry)?.children.count ?? topLevel(of: outlineView).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Entry)?.children[index] ?? topLevel(of: outlineView)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Entry)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? Entry, let id = tableColumn?.identifier else { return nil }
        if id.rawValue == "size" {
            // Reused for row after row: everything is set again, and the button starts hidden.
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SizeCell
                ?? SizeCell(identifier: id, target: self, action: #selector(grantClicked(_:)))
            let measuring = entry.path.map { granting.contains(canonicalPath($0)) } ?? false
            cell.textField?.stringValue = entry.sizeText
            cell.textField?.textColor = entry.note == nil ? .labelColor : .tertiaryLabelColor
            cell.showsGrant = canGrant(entry) && !measuring
            if entry.refused {
                // macOS asks only once; after a no, Grant opens System Settings, where it is allowed.
                // No break inside "Privacy & Security".
                cell.hoverTip = twoLines("Allowed in System Settings › Privacy\u{00A0}&\u{00A0}Security › "
                                         + privacyPane(for: entry.path ?? "").title)
                if cell.showsGrant { cell.button.hoverTip = cell.hoverTip }
            } else {
                cell.hoverTip = entry.note == "private" && !canGrant(entry)
                    ? twoLines("macOS has no dialog for this folder; Finder's Get Info gives its size.") : nil
            }
            cell.measuring = measuring  // hides the button too
            return cell
        }
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
        cell.textField?.stringValue = entry.title
        cell.textField?.font = .systemFont(ofSize: 12)
        cell.textField?.textColor = .secondaryLabelColor
        cell.hoverTip = entry.path
        return cell
    }

    // Only the startup disk's rows carry Grant buttons, so only its list's moves matter.
    func outlineViewItemDidExpand(_ notification: Notification) {
        if notification.object as? NSOutlineView === outline { rowsMoved() }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if notification.object as? NSOutlineView === outline { rowsMoved() }
    }

    // MARK: The Grant button on the hovered row

    /// Whether a row can carry a Grant button: a private folder, or one macOS refused after
    /// a grant, that opening once makes macOS ask about.
    private func canGrant(_ entry: Entry) -> Bool {
        entry.note != nil && (entry.note == "private" || entry.refused) && grantKind(for: entry.path ?? "") == .dialog
    }

    /// Grant means "measure this folder now": the folder is remembered as granted and measured
    /// on its own, and macOS shows its dialog the first time. On a folder macOS refused, it
    /// opens System Settings instead, since macOS never asks twice; the folder stays granted,
    /// so the next measurement opens it if the person allows it there. The panel stays open,
    /// except for System Settings.
    @objc private func grantClicked(_ sender: NSButton) {
        guard let entry = outline.item(atRow: outline.row(for: sender)) as? Entry, let path = entry.path,
              canGrant(entry) else { return }
        grants.add(folder: path)
        granted = grants.load()
        if entry.refused {
            orderOut(nil)
            openPrivacySettings(privacyPane(for: path))
            return
        }
        measureGrant(path)
    }

    /// Measures a granted folder on its own, off the main thread, its row spinning meanwhile.
    /// The background step only measures and touches no listed entry. The splice runs back on
    /// the main thread, into whatever list is shown by then, and only while the folder is still
    /// unmeasured there, so two grants in flight, or a full measurement that lands meanwhile,
    /// never undo each other. If the panel closes first, the result shows when it next opens.
    private func measureGrant(_ path: String) {
        let key = canonicalPath(path)
        guard !granting.contains(key), let entry = grantChain(key, in: folders)?.last, entry.note == "private",
              let target = grantTarget(key, in: folders) else { return }
        granting.insert(key)
        sizeCell(at: outline.row(forItem: entry))?.measuring = true
        let granted = granted
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let measurement = measureGranted(target, granted: granted)
            DispatchQueue.main.async {
                guard let self else { return }
                self.granting.remove(key)
                // A refusal, or a folder that is gone, keeps no grant.
                if !measurement.opened {
                    self.grants.remove(folder: key)
                    self.granted = self.grants.load()
                }
                splice(measurement, at: key, in: self.folders)
                self.showSplice(at: key)
                self.saveMeasurement()
                self.fitToContents()
            }
        }
    }

    /// Shows a splice at `path`: its row and the rows above it are reloaded, so open branches
    /// and the hover stay. Only when the top level's order changes is the whole list reloaded,
    /// with the biggest branch opened as after a measurement.
    private func showSplice(at path: String) {
        let order = folders.map(ObjectIdentifier.init)
        folders.sort(by: isLarger)
        guard folders.map(ObjectIdentifier.init) == order else {
            endHover()
            outline.reloadData()
            expandBiggestBranch()
            return
        }
        // Each ancestor's children were re-sorted, so each reloads with its children.
        for item in (grantChain(path, in: folders) ?? []).reversed() { outline.reloadItem(item, reloadChildren: true) }
        rowsMoved()
    }

    // The tracking area on the outline sends its events to the panel; other entered and
    // exited events go on as before.
    override func mouseEntered(with event: NSEvent) {
        guard let rowHover, event.trackingArea === rowHover else { return super.mouseEntered(with: event) }
        hover(rowAt: event.locationInWindow)
    }

    // Moves carry no tracking area, but only the outline's can send them here: HoverTracker's
    // has its own owner, and the panel never sets acceptsMouseMovedEvents.
    override func mouseMoved(with event: NSEvent) {
        hover(rowAt: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard let rowHover, event.trackingArea === rowHover else { return super.mouseExited(with: event) }
        hover(-1)
    }

    override func orderOut(_ sender: Any?) {
        endHover()
        super.orderOut(sender)
    }

    private func hover(rowAt point: NSPoint) {
        let local = outline.convert(point, from: nil)
        hover(outline.visibleRect.contains(local) ? outline.row(at: local) : -1)
    }

    /// Fades the old row's button out and the new row's in, if it can carry one. One button
    /// shows at a time in the whole panel, so an external disk's goes.
    func hover(_ row: Int) {
        guard row != hoveredRow else { return }
        if let cell = sizeCell(at: hoveredRow) { cell.setGrantVisible(false, animated: true) }
        hoveredRow = row
        if let cell = sizeCell(at: row), cell.showsGrant {
            hideVolumeGrants(animated: true)
            cell.setGrantVisible(true, animated: true)
        }
    }

    /// Hides any button at once, an external disk's too, and forgets the hovered row: before
    /// the rows are reloaded, and when the panel closes.
    private func endHover() {
        outline.enumerateAvailableRowViews { rowView, _ in
            for case let cell as SizeCell in rowView.subviews { cell.setGrantVisible(false, animated: false) }
        }
        hoveredRow = -1
        hideVolumeGrants(animated: false)
    }

    /// The list scrolled under a still mouse: the button goes to the row now under it.
    @objc private func scrolled() {
        if isVisible { hover(rowAt: mouseLocationOutsideOfEventStream) }
    }

    /// A folder opened or closed, so the rows below it moved and the hovered row's number
    /// no longer names it: start again from the row under the mouse.
    private func rowsMoved() {
        endHover()
        scrolled()
    }

    private func sizeCell(at row: Int) -> SizeCell? {
        guard row >= 0, row < outline.numberOfRows else { return nil }
        return outline.view(atColumn: outline.column(withIdentifier: .init("size")), row: row, makeIfNecessary: false) as? SizeCell
    }
}

// MARK: - Command line

func printTree(_ entries: [Entry], indent: Int) {
    for entry in entries {
        print(String(repeating: "  ", count: indent) + entry.title + "\t" + entry.sizeText)
        printTree(entry.children, indent: indent + 1)
    }
}

// Prints what the panel lists, as an indented tree. With a folder, prints only
// that folder's tree, which keeps tests fast.
func diskReport(folder: String?, minimumBytes: Int64, granted: GrantSet = GrantSet(), thenGrant: String? = nil) -> Int32 {
    /// Scans, then measures `thenGrant` on its own and splices it in, as the Grant button does.
    func scanned(_ root: String) -> [Entry] {
        var tree = scanFolders(root, minimumBytes: minimumBytes, granted: granted)
        if let thenGrant {
            var opened = granted
            opened.folders.insert(canonicalPath(thenGrant))
            grant(thenGrant, in: tree, minimumBytes: minimumBytes, granted: opened)
            tree.sort(by: isLarger)  // the ancestors grew, which grant leaves to its caller
        }
        return tree
    }
    if let folder {
        printTree(scanned(folder), indent: 0)
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
    printTree(scanned(dataVolume), indent: 1)
    // Then each external disk, as its section's Used row reads; nothing on it is opened.
    for volume in externalVolumes() {
        print(volume.name + "\t" + formatSize(volume.used) + " of " + formatSize(volume.total))
    }
    return 0
}

