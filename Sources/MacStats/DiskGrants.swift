// Which private folders in the Disk panel can be opened with a Grant button, and the set
// of folders the scan may open. The rules look at the path only, so deciding never causes
// a macOS privacy prompt; only `measureGranted`, run on a Grant click, opens a private folder.

import AppKit
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

/// What measuring one granted folder found, before it is spliced into the tree.
enum GrantMeasurement {
    case measured(bytes: Int64, partial: Bool, droppedUnmeasured: Bool, children: [Entry])
    /// macOS would not let the folder be opened (EACCES or EPERM).
    case refused
    /// The folder could not be opened for another reason (it is gone, say), or is not listed.
    case unchanged

    /// Whether the folder opened and was measured.
    var opened: Bool {
        if case .measured = self { return true }
        return false
    }
}

/// Where a listed folder is measured from. It is read from the tree by whoever owns the
/// tree, so the measuring itself never touches a listed entry.
struct GrantTarget {
    /// The tree's own spelling of the path, the one the scan walks, so its children match
    /// `keep()`'s rules.
    let path: String
    /// The levels left under the folder.
    let depth: Int
    /// The folder of homes, from the top of the tree.
    let users: String?
}

/// The listed entries from the top level down to the one at `path`, in either spelling.
func grantChain(_ path: String, in folders: [Entry]) -> [Entry]? {
    let wanted = canonicalPath(path)
    func chain(_ entries: [Entry]) -> [Entry]? {
        for entry in entries {
            if let entryPath = entry.path, canonicalPath(entryPath) == wanted { return [entry] }
            if let below = chain(entry.children) { return [entry] + below }
        }
        return nil
    }
    return chain(folders)
}

/// What `measureGranted` needs to measure the folder listed at `path`; nil when it is not listed.
func grantTarget(_ path: String, in folders: [Entry], depth: Int = folderDepth) -> GrantTarget? {
    guard let chain = grantChain(path, in: folders), let entry = chain.last else { return nil }
    return GrantTarget(path: entry.path ?? path, depth: depth - chain.count,
                       users: folders.first { $0.title == "Users" }?.path)
}

/// Measures one folder on its own, to the depth left under it. It reads no listed entry, so it
/// can run off the main thread while the tree is on screen. macOS answers a refused folder
/// with "not permitted" when it is opened.
func measureGranted(_ target: GrantTarget, minimumBytes: Int64 = defaultMinimumBytes, granted: GrantSet) -> GrantMeasurement {
    guard let handle = opendir(target.path) else { return errno == EACCES || errno == EPERM ? .refused : .unchanged }
    closedir(handle)
    let scan = scanTree(target.path, depth: target.depth, minimumBytes: minimumBytes, granted: granted, users: target.users)
    return .measured(bytes: scan.bytes, partial: scan.partial, droppedUnmeasured: scan.droppedUnmeasured, children: scan.folders)
}

/// Splices a measurement into `folders` in place, at the entry listed at `path`, but only while
/// that entry is still unmeasured (it has a note). A measured folder loses its note and gains
/// bytes and children. Every ancestor grows by the same bytes, and each ancestor's `partial` is
/// recomputed from what is still unmeasured below it (a listed note, or a small folder the scan
/// dropped with something unmeasured inside). A refusal leaves the entry `no access` and
/// `refused`. Anything else (not listed, already measured, `.unchanged`) changes nothing and
/// returns `.unchanged`. The top level of `folders` keeps its order: a caller that wants it
/// sorted again sorts with `isLarger`.
@discardableResult
func splice(_ measurement: GrantMeasurement, at path: String, in folders: [Entry]) -> GrantOutcome {
    guard let chain = grantChain(path, in: folders), let entry = chain.last, entry.note != nil else { return .unchanged }
    switch measurement {
    case .unchanged:
        return .unchanged
    case .refused:
        entry.note = "no access"
        entry.refused = true
        return .refused
    case let .measured(bytes, partial, droppedUnmeasured, children):
        let added = bytes - entry.bytes
        entry.note = nil
        entry.refused = false
        entry.bytes = bytes
        entry.partial = partial
        entry.droppedUnmeasured = droppedUnmeasured
        entry.children = children

        // From the entry's parent up: grow, re-sort the children, and recompute the minimum mark.
        for ancestor in chain.dropLast().reversed() {
            ancestor.bytes += added
            ancestor.children.sort(by: isLarger)
            ancestor.partial = hasUnmeasured(ancestor) || ancestor.droppedUnmeasured || ancestor.children.contains { $0.partial }
        }
        return .measured
    }
}

/// Measures `path` on its own and splices the result into `folders` in place, in one go:
/// `measureGranted`, then `splice`. The command line uses it; the panel runs the two steps on
/// different threads.
@discardableResult
func grant(
    _ path: String, in folders: [Entry], depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes,
    granted: GrantSet
) -> GrantOutcome {
    guard let target = grantTarget(path, in: folders, depth: depth) else { return .unchanged }
    return splice(measureGranted(target, minimumBytes: minimumBytes, granted: granted), at: path, in: folders)
}

/// True when the entry or anything below it has a note (private or no access).
func hasUnmeasured(_ entry: Entry) -> Bool {
    entry.note != nil || entry.children.contains(where: hasUnmeasured)
}

/// Puts back as `private` each grantable folder that a saved measurement shows measured or
/// refused but that `granted` no longer opens (after a rebuild, whose grants start empty), so
/// the list never shows what the next measurement would not take without a click. Its size
/// leaves its ancestors, which become minimums. The top level keeps its order, as with `grant`.
func closeUngranted(_ folders: [Entry], granted: GrantSet) {
    func walk(_ entries: [Entry], below ancestors: [Entry]) {
        for entry in entries {
            guard entry.note == nil || entry.refused, let path = entry.path, grantKind(for: path) == .dialog,
                  !granted.folders.contains(canonicalPath(path)) else {
                walk(entry.children, below: ancestors + [entry])
                continue
            }
            for ancestor in ancestors {
                ancestor.bytes -= entry.bytes
                ancestor.partial = true
            }
            entry.note = "private"
            entry.refused = false
            entry.bytes = 0
            entry.partial = false
            entry.droppedUnmeasured = false
            entry.children = []
            for ancestor in ancestors { ancestor.children.sort(by: isLarger) }
        }
    }
    walk(folders, below: [])
}

/// The granted folders a measurement could not open, because the person never allowed them or
/// turned them off in System Settings: each is marked refused, so its Grant button opens
/// System Settings, and returned so its grant can be dropped and later measurements skip it.
func refusedGrants(_ folders: [Entry], granted: GrantSet) -> [String] {
    var refused: [String] = []
    func walk(_ entries: [Entry]) {
        for entry in entries {
            if entry.note == "no access", let path = entry.path, granted.folders.contains(canonicalPath(path)) {
                entry.refused = true
                refused.append(path)
            }
            walk(entry.children)
        }
    }
    walk(folders)
    return refused
}

// MARK: - System Settings

/// The Privacy & Security panes where a folder macOS refused can be allowed.
enum PrivacyPane {
    case filesAndFolders, mediaLibrary

    /// The pane's name in System Settings.
    var title: String { self == .mediaLibrary ? "Media & Apple Music" : "Files and Folders" }

    /// Addresses of the pane, tried in order: the older form, then the newer one.
    fileprivate var addresses: [String] {
        let anchor = self == .mediaLibrary ? "Privacy_Media" : "Privacy_FilesAndFolders"
        return ["x-apple.systempreferences:com.apple.preference.security?" + anchor,
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?" + anchor]
    }
}

/// The pane that allows a private folder: Media & Apple Music for Music and Movies, whose
/// dialog is the media library's; Files and Folders for the rest.
func privacyPane(for path: String) -> PrivacyPane {
    ["Music", "Movies"].contains((path as NSString).lastPathComponent) ? .mediaLibrary : .filesAndFolders
}

/// Opens System Settings at the pane, falling back to Privacy & Security.
func openPrivacySettings(_ pane: PrivacyPane) {
    let fallback = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    for address in pane.addresses + [fallback] {
        if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
    }
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
    /// The build whose grants this store counts.
    let build: String

    /// The app's own defaults. The bundled app's identifier is exactly `suite`, and macOS
    /// refuses to open a suite named like the app itself, so the app uses its standard
    /// defaults; the bare binary opens the suite. Both read and write the same
    /// `sh.csarko.MacStats` domain.
    static var defaultDefaults: UserDefaults {
        if Bundle.main.bundleIdentifier == suite { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }

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

    init(defaults: UserDefaults = GrantStore.defaultDefaults, build: String = GrantStore.buildIdentity()) {
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
