// Which private folders in the Disk panel can be opened with a Grant button, and the set
// of folders the scan may open. The rules look at the path only; nothing here touches
// the file system, so deciding never causes a macOS privacy prompt.

import Foundation

/// How a private row at some path is treated: `dialog` when opening the folder once makes
/// macOS ask, and a yes lets MacStats measure it from then on; `none` when it stays private
/// whatever the person answers; `notPrivate` when the path is not a private one.
enum GrantKind: String { case dialog, none, notPrivate = "not private" }

/// The folders MacStats may open, as canonical paths, and whether it may open the
/// removable and network disks.
struct GrantSet: Equatable {
    var folders: Set<String> = []
    var removableVolumes = false
    var networkVolumes = false
}

/// The path without the Data volume's prefix, so a folder spelled with it and spelled
/// without it is the same key. The scan walks the long spelling and the remembered grants
/// keep the short one.
func canonicalPath(_ path: String) -> String {
    let prefix = "/System/Volumes/Data"
    if path == prefix { return "/" }
    return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
}

/// The folders directly in a home that macOS asks about once and then remembers.
private let grantableHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Music", "Movies"]

/// Whether a private row at `path` gets a Grant button: `dialog` for Desktop, Documents,
/// Downloads, Music and Movies directly in a home under `users`, and for a mount point
/// under /Volumes; `none` for every other private path; `notPrivate` otherwise.
func grantKind(for path: String, users: String = "/Users") -> GrantKind {
    func parts(_ path: String) -> [String] {
        canonicalPath(path).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
    let path = parts(path)
    let homes = parts(users)

    if path.count == 2, path[0] == "Volumes" { return .dialog }

    // Below a home: its name, then the folder inside it.
    if path.count > homes.count + 1, Array(path.prefix(homes.count)) == homes {
        let inHome = Array(path.dropFirst(homes.count + 1))
        if inHome.count == 1, grantableHomeFolders.contains(inHome[0]) { return .dialog }
        let relative = inHome.joined(separator: "/")
        if privateHomeFolders.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return .none }
    }
    if path.contains(where: { privatePackageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
        return .none
    }
    return .notPrivate
}
