// Which private folders in the Disk panel can be opened with a Grant button, and the set
// of folders and disks the scan may open. The rules look at the path only, so deciding never
// causes a macOS privacy prompt. A private folder is opened only by `measureGranted` after a
// Grant click, and afterwards by the panel's own measurements of exactly what a click opened,
// for as long as this build of the app remembers it.

import AppKit
import Security

/// How a private row at some path is treated: `dialog` when opening the folder once makes
/// macOS ask, and a yes lets MacStats measure it from then on; `none` when it stays private
/// whatever the person answers; `notPrivate` when the path is not a private one.
enum GrantKind: String { case dialog, none, notPrivate = "not private" }

/// What MacStats may open, as the person granted it with clicks: folders as canonical paths,
/// disks by volume UUID, and what a Music or Movies folder held when it was granted.
struct GrantSet: Equatable {
    var folders: Set<String> = []
    /// Each disk is granted on its own: a disk macOS never asks about (a disk image, say) must
    /// not let the next USB disk be opened without a click.
    var volumes: Set<String> = []
    /// For a granted Music or Movies folder, the names of the folders directly inside it at
    /// the last Grant click. macOS guards a part inside those (`Music/Music`, `Movies/TV`)
    /// that the Music and TV apps make the first time they run; one made after the click was
    /// never asked about, so a measurement leaves out any folder not named here until the
    /// next click on the row.
    var snapshots: [String: [String]] = [:]
    /// Folders macOS refused to this build after a Grant click, as canonical paths: their rows
    /// show `no access` and their Grant button opens System Settings, since macOS never asks
    /// twice.
    var refused: Set<String> = []
}

/// The path without the Data volume's prefix, so a folder spelled with it and spelled
/// without it is the same key. The scan walks the long spelling and the remembered grants
/// keep the short one.
func canonicalPath(_ path: String) -> String {
    let prefix = "/System/Volumes/Data"
    if path == prefix { return "/" }
    return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
}

/// The canonical path's parts, without empty ones.
private func pathParts(_ path: String) -> [String] {
    canonicalPath(path).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

/// The folders directly in a home that macOS asks about once and then remembers.
private let grantableHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Music", "Movies"]

/// Whether a private row at `path` gets a Grant button: `dialog` for Desktop, Documents,
/// Downloads, Music and Movies directly in a home under `users`, and for a mount point
/// under /Volumes; `none` for every other private path; `notPrivate` otherwise.
func grantKind(for path: String, users: String = "/Users") -> GrantKind {
    let path = pathParts(path)
    let homes = pathParts(users)

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

/// Whether `path` is Music or Movies directly in a home under `users`: a row whose dialog is
/// the media library's, which macOS shows when a scan reaches a guarded part inside the folder
/// rather than the folder itself. A Grant click on one records the folders inside it
/// (`GrantSet.snapshots`), and a refusal inside it marks the row refused.
func isMediaFolder(_ path: String, users: String = "/Users") -> Bool {
    let path = pathParts(path)
    let homes = pathParts(users)
    return path.count == homes.count + 2 && Array(path.prefix(homes.count)) == homes
        && ["Music", "Movies"].contains(path[homes.count + 1])
}

/// The names of the folders and files directly in `path`, for a media folder's snapshot.
/// Read on the Grant click; Music and Movies themselves open without a dialog.
func folderNames(in path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

// MARK: - Measuring one granted folder

enum GrantOutcome { case measured, refused, unchanged }

/// What measuring one granted folder found, before it is spliced into the tree.
enum GrantMeasurement {
    /// The folder opened; what the scan of it found. Its `refusedBelow` names the folder when
    /// it is a granted Music or Movies in which macOS refused a part (the person said Don't
    /// Allow to the media library).
    case measured(ScanResult)
    /// macOS would not let the folder be opened (EACCES or EPERM).
    case refused
    /// The folder could not be opened for another reason (it is gone, say), or is not listed.
    case unchanged
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
    return .measured(scanTree(target.path, depth: target.depth, minimumBytes: minimumBytes, granted: granted, users: target.users))
}

/// Splices a measurement into `folders` in place, at the entry listed at `path`, but only while
/// that entry is still unmeasured (it has a note) or is a media folder that left out something
/// new (`leftOut`), measured again after a click. A measured folder loses its note and gains
/// bytes and children. Every ancestor grows by the same bytes, and each ancestor's `partial` is
/// recomputed from what is still unmeasured below it (a listed note, or a small folder the scan
/// dropped with something unmeasured inside). A refusal leaves the entry `no access` and
/// `refused`; a media folder refused inside keeps its `≥` size and is marked `refused`.
/// Anything else (not listed, already measured, `.unchanged`) changes nothing and returns
/// `.unchanged`. The top level of `folders` keeps its order: a caller that wants it sorted
/// again sorts with `isLarger`.
@discardableResult
func splice(_ measurement: GrantMeasurement, at path: String, in folders: [Entry]) -> GrantOutcome {
    guard let chain = grantChain(path, in: folders), let entry = chain.last, entry.note != nil || entry.leftOut else {
        return .unchanged
    }
    switch measurement {
    case .unchanged:
        return .unchanged
    case .refused:
        // A folder measured before keeps its size; either way its Grant opens System Settings.
        if entry.note != nil { entry.note = "no access" }
        entry.refused = true
        return .refused
    case let .measured(scan):
        let added = scan.bytes - entry.bytes
        entry.note = nil
        entry.refused = scan.refusedBelow.contains(canonicalPath(path))
        entry.leftOut = scan.leftOut
        entry.bytes = scan.bytes
        entry.partial = scan.partial
        entry.droppedUnmeasured = scan.droppedUnmeasured
        entry.children = scan.folders

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
            entry.leftOut = false
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

/// Marks the rows of the folders in `refused` (the store's, for this build) as macOS refused
/// them, on load and after each measurement, so the first Grant click on one opens System
/// Settings instead of opening the folder again, which macOS would refuse without a word. A
/// private row becomes `no access`; a measured media folder keeps its size.
func markRefused(_ folders: [Entry], refused: Set<String>) {
    for path in refused {
        guard let entry = grantChain(path, in: folders)?.last else { continue }
        if entry.note == "private" { entry.note = "no access" }
        if entry.note != nil || isMediaFolder(path) { entry.refused = true }
    }
}

/// Leaves out a top-level `Volumes` row, which a measurement saved by 1.0.0 lists: the
/// external disks have their own sections now.
func droppingVolumesRow(_ folders: [Entry]) -> [Entry] {
    folders.filter { canonicalPath($0.path ?? "") != "/Volumes" }
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

/// The pane that allows a private folder: Media & Apple Music for Music and Movies in a home,
/// whose dialog is the media library's; Files and Folders for the rest.
func privacyPane(for path: String) -> PrivacyPane {
    isMediaFolder(path) ? .mediaLibrary : .filesAndFolders
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
/// tied to the build that asked. macOS ties a permission to the app's designated requirement:
/// for a build signed on this Mac (ad hoc) that is its exact code, so after a rebuild macOS
/// asks again the next time a folder is opened; for the signed release it is the app's name
/// and developer, which every version shares. Grants made by another build therefore count as
/// not given: the next measurement skips those folders instead of prompting without a click.
final class GrantStore {
    static let suite = "sh.csarko.MacStats"

    /// Every key the store writes (AGENTS.md's hand-testing reset deletes them).
    enum Key {
        static let folders = "grantedFolders"
        static let volumes = "grantedVolumes"
        static let snapshots = "grantSnapshots"
        static let refused = "refusedFolders"
        static let build = "grantsBuild"
    }

    private let defaults: UserDefaults
    /// The build whose grants this store counts.
    let build: String

    /// The app's own defaults. The bundled app's identifier is exactly `suite`, and macOS
    /// refuses to open a suite named like the app itself, so the app uses its standard
    /// defaults; the bare binary opens the suite. Both read and write the same
    /// `sh.csarko.MacStats` domain. The environment's `MACSTATS_DEFAULTS_SUITE` names another
    /// suite instead, for the tests; one that will not open stops the program, so a typo never
    /// reads or writes the real grants.
    static var defaultDefaults: UserDefaults {
        if let name = ProcessInfo.processInfo.environment["MACSTATS_DEFAULTS_SUITE"], !name.isEmpty {
            guard let defaults = UserDefaults(suiteName: name) else {
                FileHandle.standardError.write("MACSTATS_DEFAULTS_SUITE: cannot open \(name)\n".data(using: .utf8)!)
                exit(2)
            }
            return defaults
        }
        if Bundle.main.bundleIdentifier == suite { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// The running code's designated requirement as text, the rule macOS matches a permission
    /// against: `cdhash H"…"` for a build signed on this Mac, its identifier and developer for
    /// a Developer ID build, so the signed release keeps its grants from version to version.
    /// "unsigned" when there is none, and an unsigned build remembers no grant.
    static func buildIdentity() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let text else { return "unsigned" }
        let identity = text as String
        return identity.isEmpty ? "unsigned" : identity
    }

    init(defaults: UserDefaults = GrantStore.defaultDefaults, build: String = GrantStore.buildIdentity()) {
        self.defaults = defaults
        self.build = build
    }

    /// Empty when the stored build differs from this one, or this one is unsigned. Nothing is
    /// erased: the next write stores this build's identity and replaces the old grants. A
    /// media folder remembered without a snapshot has an empty one, so nothing inside it opens.
    func load() -> GrantSet {
        guard build != "unsigned", defaults.string(forKey: Key.build) == build else { return GrantSet() }
        var granted = GrantSet(
            folders: Set(defaults.stringArray(forKey: Key.folders) ?? []),
            volumes: Set(defaults.stringArray(forKey: Key.volumes) ?? []),
            snapshots: defaults.dictionary(forKey: Key.snapshots) as? [String: [String]] ?? [:],
            refused: Set(defaults.stringArray(forKey: Key.refused) ?? []))
        for folder in granted.folders where isMediaFolder(folder) && granted.snapshots[folder] == nil {
            granted.snapshots[folder] = []
        }
        return granted
    }

    /// Remembers a granted folder; `snapshot`, for a media folder, replaces what was recorded
    /// as inside it.
    func add(folder: String, snapshot: [String]? = nil) {
        let folder = key(for: folder)
        update {
            $0.folders.insert(folder)
            if let snapshot { $0.snapshots[folder] = snapshot }
        }
    }

    func remove(folder: String) {
        let folder = key(for: folder)
        update {
            $0.folders.remove(folder)
            $0.snapshots[folder] = nil
        }
    }

    func add(volume uuid: String) { update { $0.volumes.insert(uuid) } }
    func remove(volume uuid: String) { update { $0.volumes.remove(uuid) } }

    func add(refused folder: String) {
        let folder = key(for: folder)
        update { $0.refused.insert(folder) }
    }

    func remove(refused folder: String) {
        let folder = key(for: folder)
        update { $0.refused.remove(folder) }
    }

    /// The canonical path without a trailing slash ("/" stays).
    private func key(for folder: String) -> String {
        var path = canonicalPath(folder)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func update(_ change: (inout GrantSet) -> Void) {
        var current = load()
        change(&current)
        save(current)
    }

    /// Stores the whole set and this build's identity, so a write after a rebuild starts clean.
    private func save(_ granted: GrantSet) {
        defaults.set(granted.folders.sorted(), forKey: Key.folders)
        defaults.set(granted.volumes.sorted(), forKey: Key.volumes)
        defaults.set(granted.snapshots, forKey: Key.snapshots)
        defaults.set(granted.refused.sorted(), forKey: Key.refused)
        defaults.set(build, forKey: Key.build)
    }
}
