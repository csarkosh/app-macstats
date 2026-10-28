// The disks plugged in besides the startup disk (a USB SSD, say): their names and how
// full they are, read from the list of mounted disks, which macOS lets any app read. A
// disk's folders are opened only after a Grant click on that disk, and from then on only
// while this build remembers that disk; each disk's last folder list is kept so a replug
// shows it at once.

import Cocoa

struct ExternalVolume {
    let name: String
    let mountPoint: String
    /// The volume's UUID, or its name and mount point (`name@/Volumes/name`) when it has none
    /// (a network share, some memory cards), so two unnamed cards do not share one.
    let uuid: String
    let total: Int64
    let used: Int64
    let isNetwork: Bool
}

/// The mounted file systems, from the kernel's own list. `MNT_NOWAIT` returns what the kernel
/// already knows, so a stalled network share cannot hang the call.
private func mountedFileSystems() -> [statfs] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0 else { return [] }
    var buffer: [statfs] = Array(repeating: statfs(), count: Int(count))
    let filled = buffer.withUnsafeMutableBufferPointer {
        getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    }
    return Array(buffer.prefix(Int(max(filled, 0))))
}

/// A fixed-size C string field of `statfs` as a Swift string.
private func text<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// The external disk mounted as `fs`, or nil when it is not one: the startup disk, its
/// `/System/Volumes` parts and anything not mounted under /Volumes are skipped, and so are
/// local disks that are hidden or internal. A local disk's name and UUID come from resource
/// keys; a network share's from its mount point alone, since reading anything from a share
/// that stopped answering can hang.
private func externalVolume(_ fs: statfs) -> ExternalVolume? {
    let mountPoint = text(fs.f_mntonname)
    guard mountPoint != "/", !mountPoint.hasPrefix("/System/Volumes/"), mountPoint.hasPrefix("/Volumes/"),
          text(fs.f_fstypename) != "autofs", fs.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
    let total = Int64(fs.f_blocks) * Int64(fs.f_bsize)
    let available = Int64(fs.f_bavail) * Int64(fs.f_bsize)
    guard total > 0 else { return nil }
    let used = max(0, total - available)
    let fallbackName = (mountPoint as NSString).lastPathComponent
    guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else {
        return ExternalVolume(name: fallbackName, mountPoint: mountPoint, uuid: "\(fallbackName)@\(mountPoint)",
                              total: total, used: used, isNetwork: true)
    }
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsBrowsableKey, .volumeIsInternalKey]
    guard let values = try? URL(fileURLWithPath: mountPoint, isDirectory: true).resourceValues(forKeys: keys),
          values.volumeIsBrowsable ?? false, !(values.volumeIsInternal ?? false) else { return nil }
    let name = values.volumeName ?? fallbackName
    return ExternalVolume(name: name, mountPoint: mountPoint, uuid: values.volumeUUIDString ?? "\(name)@\(mountPoint)",
                          total: total, used: used, isNetwork: false)
}

/// The external disks mounted now, in mount order.
func externalVolumes() -> [ExternalVolume] {
    mountedFileSystems().compactMap(externalVolume)
}

/// The external disk mounted at `mountPoint` now, if any: to check that a disk measured a
/// moment ago is still the one there, and was not unplugged or swapped meanwhile.
func externalVolume(mountedAt mountPoint: String) -> ExternalVolume? {
    mountedFileSystems().first { text($0.f_mntonname) == mountPoint }.flatMap(externalVolume)
}

// MARK: - Remembering a disk's folders

/// What is kept between runs for one external disk: its last folder list, or that macOS
/// refused to let MacStats open it, and the build that measured it. macOS ties its answer to
/// the build, so a refusal another build got says nothing about this one.
struct SavedVolume: Codable {
    var measurement: SavedMeasurement?
    var refused = false
    var build: String?

    /// Whether macOS refused this disk to `build`.
    func isRefused(for build: String) -> Bool { refused && self.build == build }
}

extension SavedVolume {
    // A file saved before a key existed lacks it, so each one has a default.
    enum CodingKeys: String, CodingKey { case measurement, refused, build }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        measurement = try values.decodeIfPresent(SavedMeasurement.self, forKey: .measurement)
        refused = try values.decodeIfPresent(Bool.self, forKey: .refused) ?? false
        build = try values.decodeIfPresent(String.self, forKey: .build)
    }
}

/// Where a disk's folder list is kept: `Caches/sh.csarko.MacStats/volumes/<uuid>.json`.
func savedVolumeURL(_ uuid: String) -> URL? {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("sh.csarko.MacStats/volumes")
        .appendingPathComponent(uuid.replacingOccurrences(of: "/", with: "_") + ".json")
}

/// Reads the app's own cache file for a disk; the disk itself is not opened.
func loadSavedVolume(_ uuid: String) -> SavedVolume? {
    guard let url = savedVolumeURL(uuid), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SavedVolume.self, from: data)
}

func saveVolume(_ saved: SavedVolume, uuid: String) {
    guard let url = savedVolumeURL(uuid), let data = try? JSONEncoder().encode(saved) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

// MARK: - A disk's section

/// Whether a disk's folders are listed: not yet granted (`private`), measured, or refused by
/// macOS (`no access`, and Grant opens System Settings).
enum VolumeState { case ungranted, measured, refused }

/// One external disk's section at the bottom of the Disk panel: its name as a caption, how
/// much of it is used, a bar, and its folders. Until they are granted a `Folders` row says
/// `private` and offers Grant on hover; once measured, the time of the measurement and the
/// folder list take its place.
final class VolumeSection: NSView {
    private(set) var volume: ExternalVolume
    let usedRow = PanelRow("Used:")
    let bar = SpaceBar()
    let foldersRow = PanelRow("Folders")
    /// The `Folders` row's note, `private` or `no access`, with the Grant button and the
    /// spinner of the folder lists' size column.
    let grantCell: SizeCell
    let status = NSTextField(labelWithString: "")
    let remeasuring = NSTextField(labelWithString: "Remeasuring…")
    let outline = NSOutlineView()
    /// The list's height. The panel sets it: `preferredHeight`, or less when the screen is short.
    private(set) var listHeight: NSLayoutConstraint!
    /// Asks the panel to fit itself again; set once the section is in the panel.
    var refit: (() -> Void)?
    var state = VolumeState.ungranted
    var folders: [Entry] = []
    var measuredAt: Date?
    /// Whether a measurement of this disk is queued or running.
    var measuring = false
    /// Called with true when the mouse comes onto the `Folders` row and false when it leaves.
    var hovered: ((Bool) -> Void)?
    private var measuredLine: NSView!
    private var scroll: NSScrollView!

    /// `panel` serves the list's rows and takes the Grant clicks and double-clicks.
    init(volume: ExternalVolume, panel: DiskPanel) {
        self.volume = volume
        grantCell = SizeCell(identifier: .init("size"), target: panel, action: #selector(DiskPanel.volumeGrantClicked(_:)))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        foldersRow.value.isHidden = true  // the cell shows the note
        grantCell.translatesAutoresizingMaskIntoConstraints = false
        grantCell.textField?.textColor = .tertiaryLabelColor
        foldersRow.addSubview(grantCell)
        foldersRow.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        measuredLine = statusLine(status, remeasuring)
        scroll = folderList(outline, source: panel, target: panel, doubleAction: #selector(DiskPanel.revealInFinder(_:)))
        listHeight = scroll.heightAnchor.constraint(equalToConstant: Panel.row)

        // Top to bottom: caption 30, Used 22, bar 14, then Folders 22, or the time 14 and the list.
        let stack = NSStackView(views: [separatorView(volume.name), usedRow, bar, foldersRow, measuredLine, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(6, after: measuredLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Panel.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            grantCell.trailingAnchor.constraint(equalTo: foldersRow.trailingAnchor),
            grantCell.topAnchor.constraint(equalTo: foldersRow.topAnchor),
            grantCell.bottomAnchor.constraint(equalTo: foldersRow.bottomAnchor),
            grantCell.widthAnchor.constraint(equalToConstant: 72),
            scroll.widthAnchor.constraint(equalToConstant: Panel.width),
            listHeight,
        ])
        update(volume: volume)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the volume's figures as they are now.
    func update(volume: ExternalVolume) {
        self.volume = volume
        usedRow.value.stringValue = "\(formatSize(volume.used)) of \(formatSize(volume.total))"
        usedRow.hoverTip = twoLines("\(formatSize(volume.total - volume.used)) free. Space on this disk, not the startup disk.")
        bar.parts = [(Double(volume.used) / Double(volume.total), .systemBlue)]
    }

    /// The rows the list would like: one per top-level folder, at least one and at most eight.
    var topLevelRows: Int { min(max(folders.count, 1), 8) }
    var preferredHeight: CGFloat { Panel.row * CGFloat(topLevelRows) }

    /// Whether the `Folders` row offers Grant now: before a grant or after a refusal, while
    /// nothing is being measured, for a disk mounted where macOS asks about it.
    var canGrant: Bool {
        state != .measured && !measuring && grantKind(for: volume.mountPoint) == .dialog
    }

    /// Shows the state: the `Folders` row, or the time and the list. The list's rows are
    /// reloaded by the panel, which serves them.
    func refresh() {
        let measured = state == .measured
        foldersRow.isHidden = measured
        measuredLine.isHidden = !measured
        scroll.isHidden = !measured
        grantCell.textField?.stringValue = state == .refused ? "no access" : "private"
        grantCell.showsGrant = canGrant
        // macOS asks only once; after a no, Grant opens System Settings, where it is allowed.
        // No break inside "Privacy & Security".
        let refusedTip = twoLines("Allowed in System Settings › Privacy\u{00A0}&\u{00A0}Security › "
                                  + PrivacyPane.filesAndFolders.title)
        grantCell.hoverTip = state == .refused ? refusedTip : nil
        if grantCell.showsGrant {
            grantCell.button.hoverTip = state == .refused ? refusedTip
                : twoLines("Opens this disk once; macOS asks you to allow it. MacStats remembers your answer.")
        }
        grantCell.measuring = measuring && !measured  // hides the button too
        status.stringValue = lastMeasuredText(measuredAt)
        remeasuring.isHidden = !(measuring && measured)
        listHeight.constant = preferredHeight
        refit?()  // the panel cuts the list again if the screen is short
    }

    override func mouseEntered(with event: NSEvent) { hovered?(true) }
    override func mouseExited(with event: NSEvent) { hovered?(false) }
}

// MARK: - The panel's disks

extension DiskPanel {
    /// Reads the external disks off the main thread and shows a section per disk mounted now,
    /// in mount order. Then each disk granted with a click on this build whose list is missing
    /// or at least `age` seconds old is measured, one after another on `volumeQueue`.
    func refreshVolumes(remeasuringOlderThan age: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = externalVolumes()
            DispatchQueue.main.async {
                self.granted = self.grants.load()
                self.showVolumes(volumes)
                let inOrder = self.volumesStack.arrangedSubviews.compactMap { $0 as? VolumeSection }
                for section in inOrder where self.mayOpen(section.volume) {
                    let stale = section.measuredAt.map { Date().timeIntervalSince($0) >= age } ?? true
                    if section.state != .measured || stale { self.measureVolume(section, clicked: false) }
                }
            }
        }
    }

    /// Shows a section per disk in `volumes`, keeping the sections of disks still mounted. A
    /// new section (a disk just plugged in, or plugged in again) shows what was kept for it:
    /// its folders while this build remembers its grant, `no access` when macOS refused it.
    /// Opens no disk.
    private func showVolumes(_ volumes: [ExternalVolume]) {
        var sections: [String: VolumeSection] = [:]
        var inOrder: [VolumeSection] = []
        var added: [VolumeSection] = []
        for volume in volumes where sections[volume.uuid] == nil {
            let section = volumeSections[volume.uuid] ?? newSection(volume)
            if volumeSections[volume.uuid] == nil { added.append(section) }
            section.update(volume: volume)
            sections[volume.uuid] = section
            inOrder.append(section)
        }
        volumeSections = sections  // a disk no longer mounted loses its section
        // Only now does the panel serve the new sections' lists, so a kept list shows at once.
        for section in added { section.outline.reloadData() }
        volumesStack.setViews(inOrder, in: .top)
        fitToContents()
    }

    private func newSection(_ volume: ExternalVolume) -> VolumeSection {
        let section = VolumeSection(volume: volume, panel: self)
        section.hovered = { [weak self, weak section] inside in
            guard let self, let section else { return }
            self.volumeHovered(section, inside: inside)
        }
        let saved = loadSavedVolume(volume.uuid)
        if saved?.isRefused(for: grants.build) == true {
            section.state = .refused
        } else if let measurement = saved?.measurement, mayOpen(volume) {
            // A rebuilt app remembers no disk, so its disks show private until granted again,
            // and a refusal another build got shows private too: a click asks macOS afresh.
            section.state = .measured
            section.folders = measurement.folders.sorted(by: isLarger)
            section.measuredAt = measurement.measuredAt
        }
        section.refresh()  // `showVolumes` reloads the list once the panel serves it
        section.refit = { [weak self] in self?.fitToContents() }
        return section
    }

    /// Shows made-up disks' sections, so `--tooltips` lists their tooltips on any Mac; those
    /// whose UUID is in `refused` show as macOS refused them. Nothing is measured.
    func showSampleVolumes(_ volumes: [ExternalVolume], refused: Set<String> = []) {
        showVolumes(volumes)
        for (uuid, section) in volumeSections where refused.contains(uuid) {
            section.state = .refused
            section.refresh()
        }
    }

    /// Whether this build remembers a Grant click on this very disk.
    private func mayOpen(_ volume: ExternalVolume) -> Bool {
        granted.volumes.contains(volume.uuid)
    }

    /// Grant on a disk's `Folders` row: this disk, and no other, may be opened from now on,
    /// and it is measured at once, macOS showing its dialog the first time. macOS's permission
    /// covers every removable disk (or every network disk), but each disk is granted on its
    /// own here: a disk macOS never asks about (a disk image) must not lead to the next USB
    /// disk being opened without a click. A second disk's click shows no dialog, since macOS
    /// already has the answer. After a refusal it opens System Settings instead, since macOS
    /// never asks twice; the grant is noted, so the next opening of the panel measures the
    /// disk if the person allows it there.
    @objc func volumeGrantClicked(_ sender: NSButton) {
        guard let section = volumeSections.values.first(where: { $0.grantCell.button === sender }),
              section.canGrant else { return }
        grants.add(volume: section.volume.uuid)
        granted = grants.load()
        if section.state == .refused {
            orderOut(nil)
            openPrivacySettings(.filesAndFolders)
            return
        }
        measureVolume(section, clicked: true)
    }

    /// Measures a disk's folders three levels deep, its `Folders` row spinning, or
    /// "Remeasuring…" showing over a list already shown. After a Grant click it runs at once on
    /// its own queue, so macOS's dialog follows the click; otherwise it waits its turn on
    /// `volumeQueue` and, when its turn comes, runs only if this build still remembers the
    /// disk's grant. A refusal, or after a click a disk that would not open, forgets the grant,
    /// so the disk never opens again without a click. A measurement is kept only if the same
    /// disk is still mounted at the end (not unplugged, or swapped for another, meanwhile).
    private func measureVolume(_ section: VolumeSection, clicked: Bool) {
        guard !section.measuring else { return }
        section.measuring = true
        section.refresh()
        let volume = section.volume
        let target = GrantTarget(path: volume.mountPoint, depth: folderDepth, users: nil)
        let store = grants
        let queue = clicked ? DispatchQueue.global(qos: .userInitiated) : volumeQueue
        queue.async { [weak self] in
            let granted = store.load()
            var measurement: GrantMeasurement?
            if clicked {
                measurement = measureGranted(target, granted: granted)
            } else if granted.volumes.contains(volume.uuid) {
                // The job may have waited behind another disk, and a different disk at the same mount point was never granted.
                measurement = externalVolume(mountedAt: volume.mountPoint)?.uuid == volume.uuid
                    ? measureGranted(target, granted: granted) : .unchanged
            }
            if case .measured? = measurement, externalVolume(mountedAt: volume.mountPoint)?.uuid != volume.uuid {
                measurement = nil
            }
            DispatchQueue.main.async { self?.showMeasurement(measurement, of: volume, clicked: clicked) }
        }
    }

    /// Shows what measuring a disk found; nil when it was skipped (the grant gone) or thrown
    /// away (the disk gone).
    private func showMeasurement(_ measurement: GrantMeasurement?, of volume: ExternalVolume, clicked: Bool) {
        guard let measurement else {
            granted = grants.load()
            volumeSections[volume.uuid]?.measuring = false
            volumeSections[volume.uuid]?.refresh()
            return
        }
        // A refusal forgets the grant; so does a disk that would not open after a click.
        var forget = false
        if case .refused = measurement { forget = true }
        if case .unchanged = measurement, clicked { forget = true }
        if forget {
            grants.remove(volume: volume.uuid)
            granted = grants.load()
        }
        // A disk ejected meanwhile keeps what was saved for it before.
        guard let section = volumeSections[volume.uuid] else { return }
        section.measuring = false
        switch measurement {
        case .refused:
            section.state = .refused
            section.folders = []
            section.measuredAt = nil
            saveVolume(SavedVolume(refused: true, build: grants.build), uuid: volume.uuid)
        case let .measured(scan):
            let now = Date()
            section.state = .measured
            section.folders = scan.folders.sorted(by: isLarger)
            section.measuredAt = now
            saveVolume(SavedVolume(measurement: SavedMeasurement(measuredAt: now, folders: section.folders), build: grants.build),
                       uuid: volume.uuid)
        case .unchanged:
            break  // gone, say: what was shown stays
        }
        section.refresh()  // fits the panel again
        section.outline.reloadData()
    }

    /// The mouse came onto or left a disk's `Folders` row: its button fades in or out, and any
    /// other button in the panel goes, so one shows at a time.
    private func volumeHovered(_ section: VolumeSection, inside: Bool) {
        if inside {
            hover(-1)
            for other in volumeSections.values where other !== section { other.grantCell.setGrantVisible(false, animated: true) }
            if section.canGrant { section.grantCell.setGrantVisible(true, animated: true) }
        } else {
            section.grantCell.setGrantVisible(false, animated: true)
        }
    }

    /// Hides every disk's Grant button.
    func hideVolumeGrants(animated: Bool) {
        for section in volumeSections.values { section.grantCell.setGrantVisible(false, animated: animated) }
    }
}
