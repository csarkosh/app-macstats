// The disks plugged in besides the startup disk (a USB SSD, say): their names and how
// full they are, read through resource keys, which macOS lets any app read. A disk's
// folders are opened only after a Grant click on it (macOS asks once for all removable
// disks, and once for all network disks), and from then on only while that permission is
// remembered; each disk's last folder list is kept so a replug shows it at once.

import Cocoa

struct ExternalVolume {
    let name: String
    let mountPoint: String
    let uuid: String
    let total: Int64
    let used: Int64
    let isNetwork: Bool
}

/// Mounted volumes that are browsable, not the root file system and not internal, in mount order.
func externalVolumes() -> [ExternalVolume] {
    let keys: [URLResourceKey] = [
        .volumeIsBrowsableKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return urls.compactMap { url in
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.volumeIsBrowsable ?? false,
              !(values.volumeIsRootFileSystem ?? false),
              !(values.volumeIsInternal ?? false),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let name = values.volumeName ?? url.lastPathComponent
        let available = values.volumeAvailableCapacity ?? 0
        return ExternalVolume(name: name, mountPoint: url.path, uuid: values.volumeUUIDString ?? name,
                              total: Int64(total), used: Int64(total - available),
                              isNetwork: !(values.volumeIsLocal ?? true))
    }
}

// MARK: - Remembering a disk's folders

/// What is kept between runs for one external disk: its last folder list, or that macOS
/// refused to let MacStats open it.
struct SavedVolume: Codable {
    var measurement: SavedMeasurement?
    var refused = false
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
    /// The list's height: a row per top-level folder, at least one and at most eight.
    private(set) var listHeight: NSLayoutConstraint!
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
        listHeight.constant = Panel.row * CGFloat(min(max(folders.count, 1), 8))
    }

    override func mouseEntered(with event: NSEvent) { hovered?(true) }
    override func mouseExited(with event: NSEvent) { hovered?(false) }
}

// MARK: - The panel's disks

extension DiskPanel {
    /// Reads the external disks off the main thread (a stalled network share can hang the
    /// read) and shows a section per disk mounted now, in mount order. Then each disk whose
    /// kind MacStats may open and whose list is missing or at least `age` seconds old is
    /// measured, queued behind whatever `measureQueue` holds already.
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
    /// its folders while MacStats may open its kind of disk, `no access` when macOS refused
    /// it. Opens no disk.
    private func showVolumes(_ volumes: [ExternalVolume]) {
        var sections: [String: VolumeSection] = [:]
        var inOrder: [VolumeSection] = []
        for volume in volumes where sections[volume.uuid] == nil {
            let section = volumeSections[volume.uuid] ?? newSection(volume)
            section.update(volume: volume)
            sections[volume.uuid] = section
            inOrder.append(section)
        }
        volumeSections = sections  // a disk no longer mounted loses its section
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
        if saved?.refused == true {
            section.state = .refused
        } else if let measurement = saved?.measurement, mayOpen(volume) {
            // A rebuilt app may open no disk, so its disks show private until granted again.
            section.state = .measured
            section.folders = measurement.folders.sorted(by: isLarger)
            section.measuredAt = measurement.measuredAt
        }
        section.refresh()
        section.outline.reloadData()
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

    /// Whether the person has let MacStats open this kind of disk (removable or network).
    private func mayOpen(_ volume: ExternalVolume) -> Bool {
        volume.isNetwork ? granted.networkVolumes : granted.removableVolumes
    }

    private func setMayOpen(_ volume: ExternalVolume, _ allowed: Bool) {
        if volume.isNetwork { grants.set(networkVolumes: allowed) } else { grants.set(removableVolumes: allowed) }
        granted = grants.load()
    }

    /// Grant on a disk's `Folders` row: MacStats may open that kind of disk from now on, and
    /// the disk is measured, macOS showing its dialog the first time. After a refusal it opens
    /// System Settings instead, since macOS never asks twice; the permission is still noted,
    /// so the next opening of the panel measures the disk if the person allows it there.
    @objc func volumeGrantClicked(_ sender: NSButton) {
        guard let section = volumeSections.values.first(where: { $0.grantCell.button === sender }),
              section.canGrant else { return }
        setMayOpen(section.volume, true)
        if section.state == .refused {
            orderOut(nil)
            openPrivacySettings(.filesAndFolders)
            return
        }
        measureVolume(section, clicked: true)
    }

    /// Measures a disk's folders three levels deep on `measureQueue`, its `Folders` row
    /// spinning, or "Remeasuring…" showing over a list already shown. Called only on a Grant
    /// click or while MacStats may open that kind of disk. A refusal, or after a click a disk
    /// that would not open, takes that back, so no disk opens again without a click.
    private func measureVolume(_ section: VolumeSection, clicked: Bool) {
        guard !section.measuring else { return }
        section.measuring = true
        section.refresh()
        let volume = section.volume
        let target = GrantTarget(path: volume.mountPoint, depth: folderDepth, users: nil)
        let granted = granted
        measureQueue.async { [weak self] in
            let measurement = measureGranted(target, granted: granted)
            DispatchQueue.main.async { self?.showMeasurement(measurement, of: volume, clicked: clicked) }
        }
    }

    private func showMeasurement(_ measurement: GrantMeasurement, of volume: ExternalVolume, clicked: Bool) {
        switch measurement {
        case .refused: setMayOpen(volume, false)
        case .unchanged where clicked: setMayOpen(volume, false)
        default: break
        }
        // A disk ejected meanwhile keeps what was saved for it before.
        guard let section = volumeSections[volume.uuid] else { return }
        section.measuring = false
        switch measurement {
        case .refused:
            section.state = .refused
            section.folders = []
            section.measuredAt = nil
            saveVolume(SavedVolume(refused: true), uuid: volume.uuid)
        case let .measured(_, _, _, children):
            let now = Date()
            section.state = .measured
            section.folders = children.sorted(by: isLarger)
            section.measuredAt = now
            saveVolume(SavedVolume(measurement: SavedMeasurement(measuredAt: now, folders: section.folders)), uuid: volume.uuid)
        case .unchanged:
            break  // gone, say: what was shown stays
        }
        section.refresh()
        section.outline.reloadData()
        fitToContents()
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
