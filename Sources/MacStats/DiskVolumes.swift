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
