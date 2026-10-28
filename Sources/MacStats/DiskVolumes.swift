// The disks plugged in besides the startup disk (a USB SSD, say): their names and how
// full they are. Only the volume's own figures are read, through resource keys, which
// macOS lets any app read; nothing inside a volume is ever listed or opened.

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

/// One external disk's section at the bottom of the Disk panel: its name as a caption,
/// how much of it is used, a bar, and its folders, which stay private until granted.
final class VolumeSection: NSView {
    private(set) var volume: ExternalVolume
    let usedRow = PanelRow("Used:")
    let bar = SpaceBar()
    let foldersRow = PanelRow("Folders")

    init(volume: ExternalVolume) {
        self.volume = volume
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        foldersRow.value.stringValue = "private"
        foldersRow.value.textColor = .tertiaryLabelColor
        // Top to bottom: caption 30, Used 22, bar 14, Folders 22.
        let parts = [separatorView(volume.name), usedRow, bar, foldersRow]
        for part in parts { addSubview(part) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Panel.width),
            parts[0].topAnchor.constraint(equalTo: topAnchor),
            parts[1].topAnchor.constraint(equalTo: parts[0].bottomAnchor),
            parts[2].topAnchor.constraint(equalTo: parts[1].bottomAnchor),
            parts[3].topAnchor.constraint(equalTo: parts[2].bottomAnchor),
            parts[3].bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + parts.map { $0.leadingAnchor.constraint(equalTo: leadingAnchor) })
        update(volume: volume)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the volume's figures as they are now.
    func update(volume: ExternalVolume) {
        self.volume = volume
        usedRow.value.stringValue = "\(formatSize(volume.used)) of \(formatSize(volume.total))"
        usedRow.hoverTip = twoLines("\(formatSize(volume.total - volume.used)) free. Space on this disk, not the startup disk.")
        bar.parts = [(Double(volume.used) / Double(volume.total), .systemBlue)]
    }
}
