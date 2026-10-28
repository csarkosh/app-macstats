// Which private folders in the Disk panel can be opened with a Grant button, and the set
// of folders the scan may open. The rules look at the path only; nothing here touches
// the file system, so deciding never causes a macOS privacy prompt.

import Foundation
import Security

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

// MARK: - Measuring one granted folder

enum GrantOutcome { case measured, refused, unchanged }

/// Measures `path` on its own, to the depth left under it, and splices the result into
/// `folders` in place: the entry loses its note and gains bytes and children, every ancestor
/// grows by the same bytes, and each ancestor's `partial` is recomputed from what is still
/// unmeasured below it (a listed note, or a small folder the scan dropped with something
/// unmeasured inside). A root macOS refuses to open (EACCES or EPERM) leaves the entry as
/// `no access`, `refused`, and returns `.refused`. A path that is not in the tree, or that
/// cannot be opened for another reason (it is gone, say), changes nothing and returns
/// `.unchanged`. The top level of `folders` keeps its order: a caller that wants it sorted
/// again sorts with `isLarger`.
@discardableResult
func grant(
    _ path: String, in folders: [Entry], depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes,
    granted: GrantSet
) -> GrantOutcome {
    let wanted = canonicalPath(path)
    /// The entries from the top level down to the one at `wanted`.
    func chain(_ entries: [Entry]) -> [Entry]? {
        for entry in entries {
            if let entryPath = entry.path, canonicalPath(entryPath) == wanted { return [entry] }
            if let below = chain(entry.children) { return [entry] + below }
        }
        return nil
    }
    guard let found = chain(folders), let entry = found.last else { return .unchanged }

    // macOS answers a refused folder with "not permitted" when it is opened.
    // The tree's own spelling is the one the scan walks, so its children match `keep()`'s rules.
    let walked = entry.path ?? path
    guard let handle = opendir(walked) else {
        guard errno == EACCES || errno == EPERM else { return .unchanged }
        entry.note = "no access"
        entry.refused = true
        return .refused
    }
    closedir(handle)

    let users = folders.first { $0.title == "Users" }?.path
    let scan = scanTree(walked, depth: depth - found.count, minimumBytes: minimumBytes, granted: granted, users: users)
    let added = scan.bytes - entry.bytes
    entry.note = nil
    entry.refused = false
    entry.bytes = scan.bytes
    entry.partial = scan.partial
    entry.droppedUnmeasured = scan.droppedUnmeasured
    entry.children = scan.folders

    // From the entry's parent up: grow, re-sort the children, and recompute the minimum mark.
    for ancestor in found.dropLast().reversed() {
        ancestor.bytes += added
        ancestor.children.sort(by: isLarger)
        ancestor.partial = hasUnmeasured(ancestor) || ancestor.droppedUnmeasured || ancestor.children.contains { $0.partial }
    }
    return .measured
}

/// True when the entry or anything below it has a note (private or no access).
func hasUnmeasured(_ entry: Entry) -> Bool {
    entry.note != nil || entry.children.contains(where: hasUnmeasured)
}

// MARK: - Remembering grants

/// The folders and disks the person has let MacStats open, kept in the app's defaults and
/// tied to the build that asked. macOS ties a permission to the app's code signature, and an
/// ad-hoc signed build gets a new signature every time it is built, so after a rebuild macOS
/// asks again the next time a folder is opened. Grants made by another build therefore count
/// as not given: the next measurement skips those folders instead of prompting without a click.
final class GrantStore {
    static let suite = "sh.csarko.MacStats"

    private enum Key {
        static let folders = "grantedFolders"
        static let removable = "removableVolumesGranted"
        static let network = "networkVolumesGranted"
        static let build = "grantsBuild"
    }

    private let defaults: UserDefaults
    private let build: String

    /// The running code's cdhash as hex; "unsigned" when there is none.
    static func buildIdentity() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0)  /* kSecCSDefaultFlags */, &info) == errSecSuccess,
              let values = info as? [String: Any],
              let unique = values[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else { return "unsigned" }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    init(defaults: UserDefaults = UserDefaults(suiteName: GrantStore.suite)!, build: String = GrantStore.buildIdentity()) {
        self.defaults = defaults
        self.build = build
    }

    /// Empty when the stored build differs from this one. Nothing is erased: the next write
    /// stores this build's identity and replaces the old grants.
    func load() -> GrantSet {
        guard defaults.string(forKey: Key.build) == build else { return GrantSet() }
        return GrantSet(
            folders: Set(defaults.stringArray(forKey: Key.folders) ?? []),
            removableVolumes: defaults.bool(forKey: Key.removable),
            networkVolumes: defaults.bool(forKey: Key.network))
    }

    func add(folder: String) {
        var current = load()
        current.folders.insert(key(for: folder))
        save(current)
    }

    func remove(folder: String) {
        var current = load()
        current.folders.remove(key(for: folder))
        save(current)
    }

    func set(removableVolumes: Bool) {
        var current = load()
        current.removableVolumes = removableVolumes
        save(current)
    }

    func set(networkVolumes: Bool) {
        var current = load()
        current.networkVolumes = networkVolumes
        save(current)
    }

    /// The canonical path without a trailing slash ("/" stays).
    private func key(for folder: String) -> String {
        var path = canonicalPath(folder)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Stores the whole set and this build's identity, so a write after a rebuild starts clean.
    private func save(_ granted: GrantSet) {
        defaults.set(granted.folders.sorted(), forKey: Key.folders)
        defaults.set(granted.removableVolumes, forKey: Key.removable)
        defaults.set(granted.networkVolumes, forKey: Key.network)
        defaults.set(build, forKey: Key.build)
    }
}
